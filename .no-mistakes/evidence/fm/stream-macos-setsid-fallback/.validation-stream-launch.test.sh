#!/usr/bin/env bash
# Temporary targeted execution using the repository suite's real hub fixtures.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/.validation-stream-selected.test.sh"

assert_leader() {
  local pid=$1 role=$2 got
  got=$(python3 - "$pid" <<'PY'
import os, sys
pid = int(sys.argv[1])
pgid, sid = os.getpgid(pid), os.getsid(pid)
print(f'pid={pid} pgid={pgid} sid={sid}')
assert pid == pgid == sid
PY
  ) || fail "$role did not lead its own session: $got"
  printf '%s: %s\n' "$role" "$got"
}

operator() {
  FM_HOME="$CASE_DIR/home" FM_ROOT_OVERRIDE="$ROOT" \
    FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" FM_STATE_OVERRIDE="$CASE_DIR/home/state" \
    FM_STREAM_HUB= FM_STREAM_TOKEN="$TOKEN" "$ROOT/bin/fm-stream.sh" "$@"
}

exercise_operator() {
  local credential=$1 target pid capture
  start_case_hub "operator-$credential"
  cleanup_helpers
  printf '%s\n' "$TOKEN" > "$CASE_DIR/home/config/stream-token"
  chmod 600 "$CASE_DIR/home/config/stream-token"
  if [ "$credential" = classes ]; then
    printf 'publish,subscribe,control:%s\n' "$TOKEN" > "$CASE_DIR/home/config/stream-hub-tokens"
    chmod 600 "$CASE_DIR/home/config/stream-hub-tokens"
  fi
  operator hub start --port 0 || fail "operator could not start $credential hub"
  URL=$(operator url)
  read -r pid < "$CASE_DIR/home/state/.stream-hub.pid"
  fm_test_track_helper_pid "$pid"
  assert_leader "$pid" "hub-$credential"
  operator status || fail "hub status failed"
  target=$(create_endpoint "fm-launch-$credential-$$")
  pid=$(agent_pid_for "fm-launch-$credential-$$")
  assert_leader "$pid" "endpoint-$credential"
  with_stream_env fm_backend_send_text_submit stream "$target" \
    "printf '%s%s\\n' DETACHED- EXECUTED; stty size" 3 0.2 0.2 >/dev/null || fail "steer failed"
  wait_for_capture "$target" DETACHED-EXECUTED || fail "steer did not execute"
  capture=$(with_stream_env fm_backend_capture stream "$target" 12)
  assert_contains "$capture" '40 200' 'the endpoint PTY must have a nonzero grid'
  printf 'capture from %s:\n%s\n' "$target" "$capture"
  operator tasks || fail "operator task listing failed"
  with_stream_env fm_backend_kill stream "$target" || fail "endpoint kill failed"
  operator hub stop || fail "hub stop failed"
  [ ! -e "$CASE_DIR/home/state/.stream-hub.ready" ] || fail "hub left readiness behind"
  pass "operator $credential credentials: detached hub and endpoint start, steer, capture, close, stop"
}

exercise_exec_contract() {
  local out rc=0
  out=$(with_stream_env fm_backend_stream_detached python3 -c '
import json, os, sys
p = os.getpid()
print(json.dumps({"pid":p,"pgid":os.getpgrp(),"sid":os.getsid(0),"argv":sys.argv[1:]}), flush=True)
assert p == os.getpgrp() == os.getsid(0)
assert sys.argv[1:] == ["two words", "", "*", "-leading"]
sys.exit(37)
' 'two words' '' '*' '-leading') || rc=$?
  assert_equals "$rc" 37 'detached execution must preserve the command exit status'
  printf 'exec contract (exit %s): %s\n' "$rc" "$out"
}

exercise_native_setsid_refusal() {
  local out rc=0 count
  start_case_hub fail-closed
  # Run the real Perl interpreter as an existing session leader. Its second
  # setsid call must get EPERM from the kernel; no POSIX return is fabricated.
  perl() {
    command python3 -c 'import os, sys; os.setsid(); os.execv(sys.argv[1], sys.argv[1:])' \
      /usr/bin/perl "$@"
  }
  export -f perl
  out=$(with_stream_env fm_backend_stream_create_task "fm-refused-$$" "$CASE_DIR/cwd" 2>&1) || rc=$?
  printf 'endpoint refusal exit=%s: %s\n' "$rc" "$out"
  [ "$rc" -ne 0 ] || fail 'a failed setsid must not launch an endpoint'
  assert_contains "$out" 'setsid: Operation not permitted' 'the caller must see the detachment error'
  count=$(with_stream_env fm_backend_stream_api GET /v1/tasks | jq '.tasks | length')
  assert_equals "$count" 0 'no endpoint may register after failed detachment'
  printf 'hub registry after refused detachment: %s endpoints\n' "$count"
  printf '%s\n' "$TOKEN" > "$CASE_DIR/home/config/stream-token"
  chmod 600 "$CASE_DIR/home/config/stream-token"
  rc=0
  out=$(operator hub start --port 0 2>&1) || rc=$?
  printf 'hub refusal exit=%s: %s\n' "$rc" "$out"
  [ "$rc" -ne 0 ] || fail 'a failed setsid must not start a hub'
  [ ! -s "$CASE_DIR/home/state/.stream-hub.ready" ] || fail 'refused hub announced ready'
  [ ! -s "$CASE_DIR/home/state/.stream-hub.pid" ] || fail 'refused hub wrote a PID'
  printf 'hub detachment diagnostic: '; tail -n 1 "$CASE_DIR/home/state/.stream-hub.log"
  unset -f perl
  pass 'actual kernel detachment refusal launches neither endpoint nor hub'
}

exercise_exec_contract
exercise_operator classes
exercise_operator single
if ! command -v setsid >/dev/null 2>&1; then
  exercise_native_setsid_refusal
fi
