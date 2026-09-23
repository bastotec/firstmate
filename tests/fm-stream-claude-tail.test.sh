#!/usr/bin/env bash
# tests/fm-stream-claude-tail.test.sh - executable tests for the Claude Code
# transcript tail shim against a real stream hub.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the stream backend)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found (required by the stream backend)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the stream backend)"; exit 0; }

unset FM_STREAM_HUB FM_STREAM_TOKEN FM_STREAM_MACHINE

TMP_ROOT=$(fm_test_tmproot fm-stream-claude-tail-tests)
SHIM="$ROOT/bin/fm-stream-claude-tail.py"
HUB="$ROOT/bin/fm-stream-hub.py"
PUBLISH_TOKEN="pub-$$"
VIEW_TOKEN="view-$$"
CASE_DIR=""
URL=""
HUB_PID=""
SHIM_PID=""
SHIM_READY=""

cleanup_helpers() {
  [ -n "$SHIM_PID" ] && kill "$SHIM_PID" 2>/dev/null
  fm_test_reap_helper_pids
}
trap 'cleanup_helpers; fm_test_cleanup' EXIT INT TERM

start_hub() {
  local name=$1 port=${2:-0} ready waited=0 host pid
  [ -n "$SHIM_PID" ] && { kill "$SHIM_PID" 2>/dev/null; SHIM_PID=""; }
  if [ -n "${HUB_PID:-}" ]; then
    kill "$HUB_PID" 2>/dev/null
    while [ "$waited" -lt 50 ] && kill -0 "$HUB_PID" 2>/dev/null; do
      sleep 0.1
      waited=$((waited + 1))
    done
    kill -9 "$HUB_PID" 2>/dev/null
  fi
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR"
  printf 'publish:%s\nsubscribe,control:%s\n' "$PUBLISH_TOKEN" "$VIEW_TOKEN" > "$CASE_DIR/tokens"
  printf '%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/publish-token"
  chmod 600 "$CASE_DIR/tokens" "$CASE_DIR/publish-token"
  ready="$CASE_DIR/hub.ready"
  rm -f "$ready"
  python3 "$HUB" serve --bind 127.0.0.1 --port "$port" \
    --state-max-age-secs 1 --token-file "$CASE_DIR/tokens" \
    --ready-file "$ready" > "$CASE_DIR/hub.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  HUB_PID=$pid
  waited=0
  while [ "$waited" -lt 100 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "hub did not report ready for case $name: $(cat "$CASE_DIR/hub.log" 2>/dev/null)"
  read -r host port < "$ready"
  URL="http://$host:$port"
}

assistant_line() {
  jq -nc --arg id "$1" --argjson i "$2" --argjson o "$3" --argjson c "$4" --argjson r "$5" \
    '{type: "assistant", uuid: ("u-" + $id), message: {id: $id, usage: {
       input_tokens: $i, output_tokens: $o,
       cache_creation_input_tokens: $c, cache_read_input_tokens: $r}}}'
}

user_line() {
  jq -nc '{type: "user", message: {role: "user", content: "hello"}}'
}

start_shim() {
  SHIM_READY="$CASE_DIR/shim.ready"
  python3 "$SHIM" serve --hub "$URL" --token-file "$CASE_DIR/publish-token" \
    --machine tailmachine --heartbeat-secs 0.5 --poll-secs 0.1 "$@" \
    > "$CASE_DIR/shim.log" 2>&1 &
  SHIM_PID=$!
  disown "$SHIM_PID" 2>/dev/null || true
  fm_test_track_helper_pid "$SHIM_PID"
}

wait_for() {
  local what=$1 timeout=$2 waited=0
  shift 2
  while [ "$waited" -lt $((timeout * 10)) ]; do
    "$@" && return 0
    sleep 0.1
    waited=$((waited + 1))
  done
  fail "$what (waited ${timeout}s)"
}

shim_exited() {
  ! kill -0 "$1" 2>/dev/null
}

wait_for_shim_ready() {
  wait_for "the shim never registered" 15 test -s "$SHIM_READY"
}

hub_json() {
  curl -sS -m 10 -H "Authorization: Bearer $VIEW_TOKEN" "$URL$1"
}

publish_json() {
  curl -sS -m 10 -X "$1" -H "Authorization: Bearer $PUBLISH_TOKEN" \
    -H 'Content-Type: application/json' --data-binary "$3" "$URL$2"
}

endpoint_of() {
  cut -d' ' -f2 "$SHIM_READY"
}

state_json() {
  hub_json "/v1/tasks/$(endpoint_of)/processes"
}

state_field() {
  state_json | jq -r "$1" 2>/dev/null
}

tokens_of() {
  state_json | jq -cS .tokens 2>/dev/null
}

tokens_reached() {
  [ "$(tokens_of)" = "$1" ]
}

state_is_stale() {
  [ "$(state_field .stale)" = true ]
}

test_serve_publishes_cumulative_counters_from_real_records_only() {
  start_hub counters
  mkdir -p "$CASE_DIR/proj"
  {
    user_line
    assistant_line msg-a 10 100 5 1000
    assistant_line msg-a 10 100 5 1000
    assistant_line msg-b 20 200 6 2000
    assistant_line msg-b 20 350 6 2000
  } > "$CASE_DIR/proj/session.jsonl"
  printf '%s' "$(assistant_line msg-c 1 1 1 1)" >> "$CASE_DIR/proj/session.jsonl"
  start_shim --project-dir "$CASE_DIR/proj" --label task-counters \
    --ready-file "$CASE_DIR/shim.ready"
  wait_for_shim_ready
  assert_equals '{"cache_creation":11,"cache_read":3000,"input":30,"output":450}' \
    "$(tokens_of)" "the hub exposes deduplicated cumulative usage"
  assert_equals 2 "$(state_field .messages)" \
    "each message id counts once at its largest usage"
  local cwd_state
  cwd_state=$(hub_json "/v1/tasks/$(endpoint_of)/cwd")
  assert_equals "$CASE_DIR/proj" "$(printf '%s' "$cwd_state" | jq -r .cwd)" \
    "the cwd route still returns the endpoint directory"
  if printf '%s' "$cwd_state" | jq -e \
      'has("seq") or has("tokens") or has("messages") or has("tail")' >/dev/null; then
    fail "the cwd route exposed usage state: $cwd_state"
  fi
  local seq_before
  seq_before=$(state_field .seq)
  sleep 1.5
  assert_equals '{"cache_creation":11,"cache_read":3000,"input":30,"output":450}' \
    "$(tokens_of)" "idle heartbeats never change usage"
  [ "$(state_field .seq)" -gt "$seq_before" ] \
    || fail "the idle heartbeats never republished"
  printf '\n' >> "$CASE_DIR/proj/session.jsonl"
  wait_for "the completed record was never counted" 10 tokens_reached \
    '{"cache_creation":12,"cache_read":3001,"input":31,"output":451}'
  assert_equals 3 "$(state_field .messages)" \
    "a record counts once its terminating newline arrives"
}

test_observer_exit_leaves_worker_state_unknown() {
  start_hub observer-exit
  mkdir -p "$CASE_DIR/proj"
  assistant_line msg-a 1 2 3 4 > "$CASE_DIR/proj/session.jsonl"
  start_shim --project-dir "$CASE_DIR/proj" --label task-observed \
    --ready-file "$CASE_DIR/shim.ready"
  wait_for_shim_ready
  local endpoint
  endpoint=$(endpoint_of)
  kill -TERM "$SHIM_PID"
  wait_for "the shim never exited" 15 shim_exited "$SHIM_PID"
  wait "$SHIM_PID" 2>/dev/null
  SHIM_PID=""
  assert_equals null "$(hub_json "/v1/tasks/$endpoint" | jq -r '.task.closed_at')" \
    "observer exit must not report that the Claude worker stopped"
  wait_for "the observer's last reading never became stale" 5 state_is_stale
  assert_equals false "$(state_field .closed)" \
    "loss of the observer remains stale rather than closed"
}

test_serve_rotates_to_a_new_session_id() {
  start_hub rotate
  mkdir -p "$CASE_DIR/proj"
  assistant_line msg-a 10 100 5 1000 > "$CASE_DIR/proj/aaaa.jsonl"
  start_shim --project-dir "$CASE_DIR/proj" --label task-rotate \
    --ready-file "$CASE_DIR/shim.ready"
  wait_for_shim_ready
  sleep 0.1
  {
    assistant_line msg-a 10 100 5 1000
    assistant_line msg-b 50 500 50 5000
  } > "$CASE_DIR/proj/bbbb.jsonl"
  sleep 1
  assert_equals '{"cache_creation":5,"cache_read":1000,"input":10,"output":100}' \
    "$(tokens_of)" "session discovery runs independently of active-file polling"
  wait_for "the rotated session was never followed" 10 tokens_reached \
    '{"cache_creation":55,"cache_read":6000,"input":60,"output":600}'
  assert_equals 2 "$(state_field .messages)" \
    "history copied into the new session is not counted twice"
}

test_serve_survives_a_truncated_rewrite() {
  start_hub truncate
  mkdir -p "$CASE_DIR/proj"
  {
    assistant_line msg-a 10 100 5 1000
    assistant_line msg-b 20 200 6 2000
  } > "$CASE_DIR/proj/session.jsonl"
  start_shim --project-dir "$CASE_DIR/proj" --label task-truncate \
    --ready-file "$CASE_DIR/shim.ready"
  wait_for_shim_ready
  local before
  before=$(tokens_of)
  assistant_line msg-a 10 100 5 1000 > "$CASE_DIR/proj/session.jsonl.tmp"
  mv "$CASE_DIR/proj/session.jsonl.tmp" "$CASE_DIR/proj/session.jsonl"
  sleep 1
  assert_equals "$before" "$(tokens_of)" \
    "a truncated rewrite keeps cumulative counters monotonic"
  assistant_line msg-c 1 1 1 1 >> "$CASE_DIR/proj/session.jsonl"
  wait_for "the shim stopped following after truncation" 10 tokens_reached \
    '{"cache_creation":12,"cache_read":3001,"input":31,"output":301}'
}

test_serve_rejoins_after_the_hub_restarts() {
  start_hub rejoin
  local transcript="$CASE_DIR/proj/session.jsonl"
  mkdir -p "$CASE_DIR/proj"
  assistant_line msg-a 10 100 5 1000 > "$transcript"
  start_shim --project-dir "$CASE_DIR/proj" --label task-rejoin \
    --ready-file "$CASE_DIR/shim.ready"
  wait_for_shim_ready
  local port ready="$CASE_DIR/shim.ready"
  port=$(printf '%s' "$URL" | sed 's|.*:||')
  kill "$HUB_PID"
  wait_for "the hub never went down" 15 shim_exited "$HUB_PID"
  HUB_PID=""
  SHIM_PID=""
  start_hub rejoin-back "$port"
  sleep 1
  assistant_line msg-b 20 200 6 2000 >> "$transcript"
  wait_for "the shim never rejoined the restarted hub" 20 tokens_reached \
    '{"cache_creation":11,"cache_read":3000,"input":30,"output":300}'
  local listed
  listed=$(hub_json /v1/tasks | jq -r '.tasks[] | select(.label == "task-rejoin") | .endpoint_id')
  assert_equals "$(cut -d' ' -f2 "$ready")" "$listed" \
    "the shim rejoined under its original endpoint id"
}

test_second_shim_on_one_label_stands_down() {
  start_hub superseded
  mkdir -p "$CASE_DIR/proj"
  assistant_line msg-a 10 100 5 1000 > "$CASE_DIR/proj/session.jsonl"
  start_shim --project-dir "$CASE_DIR/proj" --label task-one \
    --ready-file "$CASE_DIR/shim.ready"
  wait_for_shim_ready
  ( python3 "$SHIM" serve --hub "$URL" --token-file "$CASE_DIR/publish-token" \
      --machine tailmachine --label task-one --project-dir "$CASE_DIR/proj" \
      --heartbeat-secs 0.5 --poll-secs 0.1; echo $? > "$CASE_DIR/shim-two.exit" \
      ) > "$CASE_DIR/shim-two.log" 2>&1 &
  local second=$!
  disown "$second" 2>/dev/null || true
  fm_test_track_helper_pid "$second"
  wait_for "the second shim never exited over the held label" 15 \
    test -s "$CASE_DIR/shim-two.exit"
  assert_equals 3 "$(cat "$CASE_DIR/shim-two.exit")" \
    "a shim that lost its name exits rather than shadowing the holder"
  kill -0 "$SHIM_PID" 2>/dev/null || fail "the first shim stopped when the second was refused"
}

test_serve_resolves_the_hub_from_home_config() {
  start_hub config-home
  mkdir -p "$CASE_DIR/proj" "$CASE_DIR/home/config" "$CASE_DIR/home/state"
  assistant_line msg-a 9 90 4 900 > "$CASE_DIR/proj/session.jsonl"
  printf '%s\n' "$URL" > "$CASE_DIR/home/config/stream-hub"
  printf '%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/home/config/stream-token"
  SHIM_READY="$CASE_DIR/shim.ready"
  FM_HOME="$CASE_DIR/home" \
    python3 "$SHIM" serve --project-dir "$CASE_DIR/proj" --label task-config \
      --machine tailmachine --heartbeat-secs 0.5 --poll-secs 0.1 \
      --ready-file "$CASE_DIR/shim.ready" > "$CASE_DIR/shim.log" 2>&1 &
  SHIM_PID=$!
  disown "$SHIM_PID" 2>/dev/null || true
  fm_test_track_helper_pid "$SHIM_PID"
  wait_for_shim_ready
  assert_equals '{"cache_creation":4,"cache_read":900,"input":9,"output":90}' \
    "$(tokens_of)" "home configuration resolves a publishing endpoint"
}

test_state_routes_preserve_the_opencode_response_shape() {
  start_hub state-shape
  local endpoint registration frame processes cwd_state
  endpoint=$(python3 -c 'import os; print(os.urandom(16).hex())')
  registration=$(jq -nc --arg id "$endpoint" \
    '{endpoint_id: $id, machine: "tailmachine", label: "opencode-shape", cwd: "/tmp/opencode", protocol: 3}')
  publish_json POST /v1/agent/endpoints "$registration" >/dev/null
  frame=$(jq -nc --arg id "$endpoint" \
    '{machine: "tailmachine", frames: [{endpoint_id: $id, state: {
      alive: true, foreground: [], cwd: "/tmp/opencode", seq: 7,
      tail: {source: "opencode", session_id: "ses-test", cost: 1.25}}}]}')
  publish_json POST /v1/agent/frames "$frame" >/dev/null
  processes=$(hub_json "/v1/tasks/$endpoint/processes")
  assert_equals true "$(printf '%s' "$processes" | jq -r .alive)" \
    "the opencode-shaped endpoint is readable through processes"
  if printf '%s' "$processes" | jq -e \
      'has("seq") or has("tokens") or has("messages") or has("tail")' >/dev/null; then
    fail "the processes route exposed opencode tail state: $processes"
  fi
  cwd_state=$(hub_json "/v1/tasks/$endpoint/cwd")
  assert_equals /tmp/opencode "$(printf '%s' "$cwd_state" | jq -r .cwd)" \
    "the opencode-shaped endpoint keeps its cwd response"
  if printf '%s' "$cwd_state" | jq -e \
      'has("seq") or has("tokens") or has("messages") or has("tail")' >/dev/null; then
    fail "the cwd route exposed opencode tail state: $cwd_state"
  fi
}

test_only_rotating_serve_mode_is_public() {
  local dir="$TMP_ROOT/removed-surfaces" out status
  mkdir -p "$dir"
  assistant_line msg-a 1 2 3 4 > "$dir/session.jsonl"
  if out=$(python3 "$SHIM" summarize --project-dir "$dir" 2>&1); then
    fail "the removed summarize command unexpectedly succeeded"
  else
    status=$?
  fi
  assert_equals 2 "$status" "the offline summarize command is not accepted"
  assert_contains "$out" "invalid choice" "the removed summarize command is rejected by the CLI"
  if out=$(python3 "$SHIM" serve --transcript "$dir/session.jsonl" --label task 2>&1); then
    fail "the removed transcript option unexpectedly succeeded"
  else
    status=$?
  fi
  assert_equals 2 "$status" "fixed-file serve mode is not accepted"
  assert_contains "$out" "unrecognized arguments" "the removed transcript option is rejected by the CLI"
}

test_serve_publishes_cumulative_counters_from_real_records_only
test_observer_exit_leaves_worker_state_unknown
test_serve_rotates_to_a_new_session_id
test_serve_survives_a_truncated_rewrite
test_serve_rejoins_after_the_hub_restarts
test_second_shim_on_one_label_stands_down
test_serve_resolves_the_hub_from_home_config
test_state_routes_preserve_the_opencode_response_shape
test_only_rotating_serve_mode_is_public
pass "the Claude Code transcript tail shim holds its contracts"
