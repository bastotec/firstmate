#!/usr/bin/env bash
# tests/fm-backend-stream.test.sh - adapter tests for the stream
# session-provider backend (bin/backends/stream.sh), driven through the shared
# dispatcher in bin/fm-backend.sh (docs/stream-backend.md).
#
# These run against a REAL hub and REAL agents rather than faked ones. The hub
# and agent are this repository's own services, their lifecycle is already
# proven by tests/fm-stream-hub.test.sh, and the adapter's whole job is to
# speak that protocol - so a fake would only confirm the request shapes this
# test already assumes, while a real one also proves they are accepted.
#
# The refusal cases that cannot use a healthy hub - a missing dependency, a hub
# announcing another protocol - get the narrowest real stand-in that reproduces
# the condition, never a rewritten adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the stream backend)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found (required by the stream backend)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the stream backend)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-backend-stream-tests)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
HUB="$ROOT/bin/fm-stream-hub.py"
TOKEN="adapter-token-$$"
CASE_DIR=""
URL=""

cleanup_helpers() {
  fm_test_reap_helper_pids
}
trap 'cleanup_helpers; fm_test_cleanup' EXIT INT TERM

# with_stream_env: run <command...> with this case's hub and token exported, in
# a subshell that has the dispatcher sourced. Every adapter call in this file
# goes through fm_backend_* so the test proves the dispatcher routing too, not
# just the adapter functions in isolation.
with_stream_env() {
  (
    # shellcheck disable=SC2030  # deliberate: the binding must not outlive the call
    export FM_STREAM_HUB="$URL" FM_STREAM_TOKEN="$TOKEN" FM_STREAM_MACHINE=box-test
    # shellcheck disable=SC2030,SC2031  # deliberate: each case exports its own home into its own subshell
    export FM_HOME="$CASE_DIR/home" FM_ROOT="$ROOT" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config"
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source stream || exit 90
    "$@"
  )
}

start_case_hub() {  # <case-name> [extra hub args...]
  local name=$1
  shift
  local ready waited=0 host port pid
  cleanup_helpers
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR/home/config" "$CASE_DIR/home/state" "$CASE_DIR/cwd"
  printf 'publish,subscribe,control:%s\n' "$TOKEN" > "$CASE_DIR/tokens"
  chmod 600 "$CASE_DIR/tokens"
  ready="$CASE_DIR/ready"
  python3 "$HUB" serve --bind 127.0.0.1 --port 0 \
    --token-file "$CASE_DIR/tokens" --ready-file "$ready" "$@" \
    > "$CASE_DIR/log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 100 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "hub did not report ready for case $name: $(cat "$CASE_DIR/log" 2>/dev/null)"
  read -r host port < "$ready"
  URL="http://$host:$port"
}

# create_endpoint -> "<tag>:<endpoint-id>", the exact target shape a task's
# durable record carries. This starts a real local agent, exactly as a spawn
# would.
create_endpoint() {  # <label> [status-path]
  local label=$1 status=${2:-} pair pid
  pair=$(with_stream_env fm_backend_stream_create_task "$label" "$CASE_DIR/cwd" "$status") \
    || fail "creating endpoint $label failed"
  # The adapter starts the agent DETACHED, exactly as a spawn does, so it is not
  # a job of this shell and the trap would not reap it. Record it by pid.
  pid=$(agent_pid_for "$label")
  fm_test_track_helper_pid "$pid"
  printf '%s:%s' "${pair%% *}" "${pair##* }"
}

# agent_pid_for: the publisher for one label in THIS run. Labels are made
# unique per run, because matching a label alone would find an agent left by an
# earlier run and silence the wrong endpoint.
agent_pid_for() {  # <label>
  ps -eo pid,args 2>/dev/null \
    | awk -v l="--label $1" \
        'index($0, "fm-stream-agent.py") && index($0, l) && !index($0, "awk") {print $1; exit}'
}

wait_for_capture() {  # <target> <needle>
  local target=$1 needle=$2 waited=0 out
  while [ "$waited" -lt 150 ]; do
    out=$(with_stream_env fm_backend_capture stream "$target" 40 2>/dev/null) || out=
    case "$out" in *"$needle"*) return 0 ;; esac
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

test_create_yields_a_hub_bound_target_the_dispatcher_can_read() {
  local target tag endpoint
  start_case_hub create
  target=$(create_endpoint "fm-create-$$")
  tag=${target%%:*}
  endpoint=${target#*:}
  # The tag is the hub's identity, colon-free so the FIRST colon always splits
  # the target, and it must be a legal endpoint atom or cleanup validation would
  # refuse the record this spawn is about to write.
  assert_equals "$tag" "$(with_stream_env fm_backend_stream_hub_tag "$URL")" \
    "the created target should carry the tag of the hub it was created on"
  case "$endpoint" in
    [0-9a-f]*) ;;
    *) fail "the endpoint half should be the hub's durable hex id, got '$endpoint'" ;;
  esac
  with_stream_env fm_backend_target_exists stream "$target" \
    || fail "the dispatcher should see the endpoint it just created"
  pass "stream: create yields a hub-bound target the dispatcher can resolve"
}

test_send_reaches_the_endpoint_and_capture_reads_it_back() {
  local target out
  start_case_hub send
  target=$(create_endpoint "fm-send-$$")
  with_stream_env fm_backend_send_text_submit stream "$target" 'echo ADAPTER-SENT' 3 0.2 0.2 >/dev/null \
    || fail "the dispatcher refused to send text to the endpoint"
  wait_for_capture "$target" ADAPTER-SENT \
    || fail "the endpoint never ran the submitted line"
  out=$(with_stream_env fm_backend_capture stream "$target" 40)
  assert_contains "$out" ADAPTER-SENT "bounded capture should read back what was sent"
  pass "stream: a dispatcher send reaches the endpoint and capture reads it back"
}

test_capture_is_bounded_by_the_requested_line_count() {
  local target few
  start_case_hub capture-bound
  target=$(create_endpoint "fm-capture-$$")
  with_stream_env fm_backend_send_text_submit stream "$target" \
    "printf 'ROW-%s\\n' 1 2 3 4 5 6 7 8 9 10 11 12" 3 0.2 0.2 >/dev/null \
    || fail "the dispatcher refused to send the row generator"
  wait_for_capture "$target" ROW-12 || fail "the endpoint never printed the last row"
  few=$(with_stream_env fm_backend_capture stream "$target" 3)
  [ "$(printf '%s\n' "$few" | wc -l)" -le 3 ] \
    || fail "capture should return at most the requested number of lines"
  pass "stream: capture returns only the requested tail through the dispatcher"
}

test_agent_state_reads_the_foreground_process_not_the_screen() {
  local target state
  start_case_hub agent-state
  target=$(create_endpoint "fm-state-$$")
  # An endpoint sitting at its own shell prompt is a dead worker, not a live
  # one: this is the fleet-wide dead-shell rule, and it must hold here without
  # reading a single rendered byte.
  state=$(with_stream_env fm_backend_agent_state stream "$target")
  assert_equals "$state" dead "a bare shell endpoint should classify as dead"
  pass "stream: agent state reads the endpoint's foreground process"
}

test_agent_state_separates_missing_unreachable_and_partitioned() {
  local target state gone
  start_case_hub agent-state-edges --state-max-age-secs 2
  target=$(create_endpoint "fm-edges-$$")
  gone="${target%%:*}:00000000000000000000000000000000"
  state=$(with_stream_env fm_backend_agent_state stream "$gone")
  assert_equals "$state" missing "an endpoint the hub does not host should classify as missing"

  # A partition: the OWNING AGENT is silenced while the hub stays up. The worker
  # may be perfectly healthy and simply unreachable, and only a positive report
  # of death authorizes recovery - so this must never read dead.
  local pid waited=0
  pid=$(agent_pid_for "fm-edges-$$")
  [ -n "$pid" ] || fail "could not find the publishing agent to silence"
  fm_test_kill_foreign_pid "$pid" "silencing the publishing agent"
  while [ "$waited" -lt 100 ]; do
    state=$(with_stream_env fm_backend_agent_state stream "$target")
    [ "$state" = unreadable ] && break
    sleep 0.2
    waited=$((waited + 1))
  done
  assert_equals "$state" unreadable \
    "a partitioned agent must classify unreadable - never dead, which would authorize recovery"

  # And an unreachable HUB is unreadable too, for the same reason.
  cleanup_helpers
  sleep 0.3
  state=$(with_stream_env fm_backend_agent_state stream "$target")
  assert_equals "$state" unreadable "an unreachable hub should classify as unreadable"
  pass "stream: agent state separates a missing endpoint, a partition, and an unreachable hub"
}

test_kill_closes_the_exact_endpoint_and_leaves_its_sibling() {
  local victim bystander
  start_case_hub kill
  victim=$(create_endpoint "fm-victim-$$")
  bystander=$(create_endpoint "fm-bystander-$$")
  with_stream_env fm_backend_kill stream "$victim" \
    || fail "the dispatcher refused to close the endpoint"
  local waited=0
  while [ "$waited" -lt 100 ]; do
    with_stream_env fm_backend_target_exists stream "$victim" >/dev/null 2>&1 || break
    sleep 0.1
    waited=$((waited + 1))
  done
  with_stream_env fm_backend_target_exists stream "$bystander" \
    || fail "closing one endpoint must not disturb another"
  pass "stream: kill closes the exact endpoint and leaves its sibling running"
}

test_status_return_channel_appends_on_the_owning_machine() {
  local target status_path
  start_case_hub status
  status_path="$CASE_DIR/home/state/fm-status.status"
  target=$(create_endpoint "fm-status-$$" "$status_path")
  with_stream_env fm_backend_stream_report_status "$target" working 'adapter return channel' \
    || fail "the adapter could not report status through the hub"
  assert_grep 'working: adapter return channel' "$status_path" \
    "the owning agent should append an ordinary status line into the task's own record"
  pass "stream: the status return channel appends through the normal status protocol"
}

test_a_spawn_whose_shell_cannot_start_reports_the_shells_own_error() {
  # The endpoint's shell is whatever $SHELL is on the worker's machine, and one
  # that cannot start must fail the spawn visibly: the agent's refusal carries
  # the shell's own error, and this is the only path firstmate takes, so the
  # caller has to see that text rather than a bare timeout.
  local out
  start_case_hub brokenshell
  printf '#!/bin/sh\necho "this shell cannot start" >&2\nexit 3\n' > "$CASE_DIR/broken-shell"
  chmod +x "$CASE_DIR/broken-shell"
  out=$(SHELL="$CASE_DIR/broken-shell" with_stream_env fm_backend_stream_create_task \
    "fm-broken-$$" "$CASE_DIR/cwd" 2>&1) \
    && fail "a spawn whose endpoint shell dies at birth should be refused"
  assert_contains "$out" "this shell cannot start" \
    "the refusal should carry the shell's own error as the reason"
  assert_equals "$(with_stream_env fm_backend_stream_api GET /v1/tasks 2>/dev/null | jq -r '[.tasks[] | select(.label | startswith("fm-broken"))] | length')" \
    0 "a shell that died at birth must leave no endpoint registered on the hub"
  pass "stream: a spawn whose endpoint shell cannot start reports the shell's own error"
}

test_a_target_from_another_hub_is_refused() {
  local target foreign
  start_case_hub foreign-tag
  target=$(create_endpoint "fm-foreign-$$")
  foreign="somewhere-else-9999:${target#*:}"
  # The endpoint id alone is not an address. A record made against one hub must
  # not quietly drive a same-id endpoint on whichever hub this home happens to
  # be configured for now.
  with_stream_env fm_backend_target_exists stream "$foreign" 2>/dev/null \
    && fail "a target tagged for another hub should not resolve against this one"
  # The foreign target carries the SAME endpoint id as the live one, so if the
  # tag guard were missing this kill would close the real endpoint. Kill itself
  # is deliberately idempotent - an already-gone endpoint must not fail a
  # cleanup - so the endpoint surviving is the assertion, not the exit status.
  with_stream_env fm_backend_kill stream "$foreign" 2>/dev/null || true
  with_stream_env fm_backend_target_exists stream "$target" \
    || fail "the endpoint must survive a kill aimed at another hub's tag"
  pass "stream: a target recorded against another hub is refused, not redirected"
}

test_hub_url_prefers_configuration_then_a_locally_started_hub() {
  # `hub start --port N` used to leave every other command resolving the
  # default port: the hub was up, and status, web, and every task command
  # reported it down. Reading the port the hub actually bound beats assuming
  # one - but only below both configured sources, so a home pointed at the
  # fleet's hub still wins even while it runs a hub of its own.
  local home url
  home="$CASE_DIR/url-precedence"
  mkdir -p "$home/config" "$home/state"

  resolve() {  # [env assignments applied by the caller]
    (
      # shellcheck disable=SC2030,SC2031  # deliberate: each tier is scoped to its own subshell
      export FM_HOME="$home" FM_ROOT="$ROOT" \
        FM_CONFIG_OVERRIDE="$home/config" FM_STATE_OVERRIDE="$home/state"
      # shellcheck source=bin/fm-backend.sh
      . "$ROOT/bin/fm-backend.sh"
      fm_backend_source stream || exit 90
      fm_backend_stream_hub_url
    )
  }

  url=$(resolve) || fail "resolution failed with nothing configured"
  assert_equals "http://127.0.0.1:7717" "$url" "with nothing configured it should fall back to the documented default"

  printf '127.0.0.1 7731\n' > "$home/state/.stream-hub.ready"
  url=$(resolve) || fail "resolution failed with a locally started hub"
  assert_equals "http://127.0.0.1:7731" "$url" "a hub this home started should be preferred over the default port it did not bind"

  printf 'http://hub.example:9000\n' > "$home/config/stream-hub"
  url=$(resolve) || fail "resolution failed with config/stream-hub present"
  assert_equals "http://hub.example:9000" "$url" "config/stream-hub should outrank a hub this home happens to run"

  url=$(FM_STREAM_HUB="http://env.example:9100" resolve) || fail "resolution failed with FM_STREAM_HUB set"
  assert_equals "http://env.example:9100" "$url" "FM_STREAM_HUB should outrank every file"

  # A truncated or half-written ready file must not become a hub URL.
  rm -f "$home/config/stream-hub"
  printf '127.0.0.1\n' > "$home/state/.stream-hub.ready"
  url=$(resolve) || fail "resolution failed with a partial ready file"
  assert_equals "http://127.0.0.1:7717" "$url" "a ready file with no port should be ignored rather than built into a broken URL"

  unset -f resolve
  pass "stream: the hub URL prefers configuration, then a hub this home started, then the default"
}

test_an_unreachable_hub_refuses_and_names_the_start_command() {
  local err
  start_case_hub unreachable
  cleanup_helpers
  sleep 0.3
  err=$( (with_stream_env fm_backend_stream_version_check) 2>&1 ) && fail "an unreachable hub should refuse"
  assert_contains "$err" "cannot reach the hub" "the refusal should say the hub is unreachable"
  assert_contains "$err" "fm-stream.sh hub start" "the refusal should name the command that starts one"
  pass "stream: an unreachable hub refuses loudly and names the start command"
}

test_a_rejected_token_refuses_instead_of_retrying_unauthenticated() {
  local err
  start_case_hub bad-token
  err=$( (
    # shellcheck disable=SC2031  # deliberate: the wrong credential is scoped to this call
    export FM_STREAM_HUB="$URL" FM_STREAM_TOKEN="not-the-token"
    # shellcheck disable=SC2030,SC2031  # deliberate: each case exports its own home into its own subshell
    export FM_HOME="$CASE_DIR/home" FM_ROOT="$ROOT" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config"
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source stream || exit 90
    fm_backend_stream_version_check
  ) 2>&1 ) && fail "a rejected token should refuse"
  assert_contains "$err" "token is not accepted" "the refusal should name the rejected credential"
  pass "stream: a rejected token refuses rather than retrying unauthenticated"
}

test_a_hub_speaking_another_protocol_is_refused() {
  local err port waited=0
  # The narrowest real stand-in for a hub from another release: an HTTP server
  # that authenticates exactly like the real one and answers /v1/health with a
  # protocol number this adapter does not implement.
  CASE_DIR="$TMP_ROOT/protocol"
  mkdir -p "$CASE_DIR/home/config"
  cleanup_helpers
  python3 - "$CASE_DIR" "$TOKEN" <<'PY' &
import http.server, json, sys, threading
case_dir, token = sys.argv[1], sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.headers.get("Authorization") != "Bearer " + token:
            self.send_response(401); self.end_headers(); return
        body = json.dumps({"protocol": 99, "version": "impostor"}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
with open(case_dir + "/ready", "w") as fh:
    fh.write("%d\n" % server.server_address[1])
threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait()
PY
  disown $! 2>/dev/null || true
  fm_test_track_helper_pid "$!"
  while [ "$waited" -lt 100 ]; do
    [ -s "$CASE_DIR/ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$CASE_DIR/ready" ] || fail "the stand-in hub never reported a port"
  read -r port < "$CASE_DIR/ready"
  URL="http://127.0.0.1:$port"
  err=$( (with_stream_env fm_backend_stream_version_check) 2>&1 ) \
    && fail "a hub speaking another protocol should be refused"
  assert_contains "$err" "protocol 99" "the refusal should name the protocol the hub announced"
  assert_contains "$err" "update both ends" "the refusal should say both ends must agree"
  cleanup_helpers
  pass "stream: a hub announcing another protocol is refused, not driven on guessed routes"
}

test_a_missing_dependency_refuses_and_names_the_tool() {
  local err without_jq
  # Hiding exactly one tool, with every other required one still resolvable,
  # proves the refusal names the tool that is actually absent rather than the
  # first one the check happens to look at.
  CASE_DIR="$TMP_ROOT/missing-dep"
  mkdir -p "$CASE_DIR/home/config"
  without_jq=$(fm_test_base_path_sans "$BASE_PATH" jq)
  err=$( (
    PATH="$without_jq"
    export PATH
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source stream || exit 90
    fm_backend_stream_tool_check
  ) 2>&1 ) && fail "a missing dependency should refuse"
  assert_contains "$err" "'jq' is not installed" "the refusal should name the missing tool"
  pass "stream: a missing dependency refuses loudly and names the tool"
}

test_a_missing_token_reports_it_without_crashing() {
  local err
  # Regression: the error path ran before any request was made, so the recorded
  # HTTP status was unset and reading it tripped `set -u` instead of reporting
  # the real problem.
  CASE_DIR="$TMP_ROOT/no-token"
  mkdir -p "$CASE_DIR/home/config" "$CASE_DIR/home/state"
  err=$( (
    set -u
    unset FM_STREAM_TOKEN
    # shellcheck disable=SC2030,SC2031  # deliberate: each case exports its own home into its own subshell
    export FM_HOME="$CASE_DIR/home" FM_ROOT="$ROOT" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config"
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source stream || exit 90
    out=$(fm_backend_stream_api GET /v1/health 2>&1) || true
    fm_backend_stream_api_error "$out"
  ) 2>&1 )
  assert_not_contains "$err" "unbound variable" \
    "reporting a missing token must not trip set -u on the unset HTTP status"
  assert_contains "$err" "HTTP" "the error path should still report a status"
  pass "stream: a missing token is reported rather than crashing the caller"
}

test_spawn_refuses_a_secondmate_on_stream() {
  local err
  err=$(FM_BACKEND=stream "$ROOT/bin/fm-spawn.sh" --secondmate mate-x 2>&1) \
    && fail "a stream secondmate spawn should be refused"
  assert_contains "$err" "does not support --secondmate" \
    "the refusal should say secondmate spawns are not supported on stream"
  pass "stream: a secondmate spawn is refused until its launch semantics exist"
}

test_cleanup_validation_binds_a_record_to_the_hub_that_made_it() {
  local state meta target endpoint
  start_case_hub teardown
  target=$(create_endpoint "fm-teardown-$$")
  endpoint=${target#*:}
  state="$CASE_DIR/meta"
  mkdir -p "$state"

  write_meta() {  # <task-id> <window> [extra lines...]
    local id=$1 window=$2
    shift 2
    {
      printf 'backend=stream\n'
      printf 'endpoint_task_id=%s\n' "$id"
      printf 'worktree=%s\n' "$CASE_DIR/cwd"
      printf 'project=%s\n' "$CASE_DIR/cwd"
      printf 'window=%s\n' "$window"
      printf '%s\n' "$@"
    } > "$state/$id.meta"
  }

  meta="$state/t1.meta"
  write_meta t1 "$target" "stream_hub=$URL" "stream_endpoint_id=$endpoint"
  with_stream_env fm_backend_validate_task_endpoint "$meta" t1 \
    || fail "a consistent stream record should validate for cleanup"

  # The RECORDED hub, not the currently configured one, is what the window must
  # agree with: a record validated against the live setting would start refusing
  # the moment an operator repointed this home at another hub.
  write_meta t2 "somewhere-else-9999:$endpoint" "stream_hub=$URL" "stream_endpoint_id=$endpoint"
  with_stream_env fm_backend_validate_task_endpoint "$state/t2.meta" t2 2>/dev/null \
    && fail "a window disagreeing with the recorded hub should be refused"

  write_meta t3 "$target" "stream_hub=$URL"
  with_stream_env fm_backend_validate_task_endpoint "$state/t3.meta" t3 2>/dev/null \
    && fail "a record missing its endpoint id should be refused"

  write_meta t4 "$target" "stream_endpoint_id=$endpoint"
  with_stream_env fm_backend_validate_task_endpoint "$state/t4.meta" t4 2>/dev/null \
    && fail "a record missing its hub should be refused"

  write_meta t5 "$target" "stream_hub=$URL" "stream_endpoint_id=not-hex"
  with_stream_env fm_backend_validate_task_endpoint "$state/t5.meta" t5 2>/dev/null \
    && fail "a record whose endpoint id is not the hub's durable form should be refused"

  unset -f write_meta
  pass "stream: cleanup validation binds a record to the hub that created it"
}

test_the_key_vocabulary_is_only_what_the_control_plane_permits() {
  local key
  start_case_hub keys
  for key in Enter Escape C-c C-u; do
    with_stream_env fm_backend_stream_normalize_key "$key" >/dev/null \
      || fail "stream should deliver $key, which the control plane permits"
  done
  # A key with no control-plane spelling is unreachable through every firstmate
  # path, so claiming it would be a capability nothing can use.
  for key in Backspace Tab C-d F5; do
    with_stream_env fm_backend_stream_normalize_key "$key" >/dev/null 2>&1 \
      && fail "stream should not claim '$key', which no firstmate path can reach"
  done
  pass "stream: the key vocabulary is exactly the control plane's four keys"
}

test_create_yields_a_hub_bound_target_the_dispatcher_can_read
test_send_reaches_the_endpoint_and_capture_reads_it_back
test_capture_is_bounded_by_the_requested_line_count
test_agent_state_reads_the_foreground_process_not_the_screen
test_agent_state_separates_missing_unreachable_and_partitioned
test_kill_closes_the_exact_endpoint_and_leaves_its_sibling
test_status_return_channel_appends_on_the_owning_machine
test_a_target_from_another_hub_is_refused
test_a_spawn_whose_shell_cannot_start_reports_the_shells_own_error
test_an_unreachable_hub_refuses_and_names_the_start_command
test_hub_url_prefers_configuration_then_a_locally_started_hub
test_a_rejected_token_refuses_instead_of_retrying_unauthenticated
test_a_hub_speaking_another_protocol_is_refused
test_a_missing_dependency_refuses_and_names_the_tool
test_a_missing_token_reports_it_without_crashing
test_spawn_refuses_a_secondmate_on_stream
test_cleanup_validation_binds_a_record_to_the_hub_that_made_it
test_the_key_vocabulary_is_only_what_the_control_plane_permits
