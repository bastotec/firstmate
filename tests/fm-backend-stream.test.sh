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
HUB_PID=""
SLOW_URL=""

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
  HUB_PID=$pid
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

# start_slow_stand_in <stall-spec> -> sets SLOW_URL
# A forwarder in front of THIS case's hub that stalls the connections the spec
# names, so a case can make the hub answer too late on exactly the call it
# cares about while everything else behaves normally.
start_slow_stand_in() {  # <stall-spec>
  start_slow_stand_in_delay 25 "$1"
}

start_slow_stand_in_delay() {  # <delay-secs> <stall-spec>
  local delay=$1 spec=$2 ready hostport host port waited=0 pid
  ready="$CASE_DIR/proxy-$delay-$spec.ready"
  hostport=${URL#http://}
  python3 "$ROOT/tests/assets/slow-tcp-proxy.py" 127.0.0.1 \
    "${hostport%%:*}" "${hostport##*:}" "$delay" "$spec" > "$ready" 2>"$CASE_DIR/proxy.log" &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 100 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "the slow stand-in never reported ready: $(cat "$CASE_DIR/proxy.log" 2>/dev/null)"
  read -r host port < "$ready"
  SLOW_URL="http://$host:$port"
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

test_the_composer_capture_frames_a_blank_screen_apart_from_the_cursor() {
  # The composer reads the cursor row and the screen out of one captured
  # string. A blank screen is nothing but newlines, and a caller's command
  # substitution eats every trailing one, so without framing that survives it
  # the cursor digits arrive as the screen's only row and every verdict on a
  # quiet endpoint is read off them.
  start_case_hub composerframe
  local target raw cursor screen
  target=$(create_endpoint "fm-frame-$$")
  raw=$(with_stream_env fm_backend_stream_composer_capture "$target") \
    || fail "the composer capture should answer for a live endpoint"
  cursor=${raw%%$'\n'*}
  screen=${raw#*$'\n'}
  screen=${screen#|}
  case "$cursor" in
    ''|*[!0-9]*) fail "the first line should be the cursor row, got '$cursor'" ;;
  esac
  assert_not_equals "$screen" "$cursor" \
    "a blank screen must not read back as the cursor row"
  pass "stream: the composer capture keeps a blank screen apart from the cursor row"
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

# restart_case_hub - stop this case's hub and bring one back at the SAME
# address, which is what a restart means to an agent that never moved. The
# agents keep running: outliving the hub is the property under test.
restart_case_hub() {
  local port=${URL##*:} waited=0 ready="$CASE_DIR/ready" pid host bound
  kill "$HUB_PID" 2>/dev/null
  while [ "$waited" -lt 100 ]; do
    [ -e "$ready" ] || break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -e "$ready" ] && fail "the hub did not stop when asked"
  python3 "$HUB" serve --bind 127.0.0.1 --port "$port" \
    --token-file "$CASE_DIR/tokens" --ready-file "$ready" >> "$CASE_DIR/log" 2>&1 &
  pid=$!
  HUB_PID=$pid
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  waited=0
  while [ "$waited" -lt 150 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "the hub did not come back: $(cat "$CASE_DIR/log" 2>/dev/null)"
  read -r host bound < "$ready"
  URL="http://$host:$bound"
}

test_a_restarting_hub_never_reads_as_a_missing_worker() {
  # The hub keeps its endpoint registry in memory, so between a restart and
  # each agent registering itself again, every endpoint answers 404. That
  # window is a recovery, not a verdict: `missing` folds into `dead` for every
  # caller of fm_backend_agent_alive, and the steer paths escalate `dead|missing`
  # by dropping a pending steer - on a worker that is alive and coming back.
  start_case_hub restart-not-missing
  local target before after waited=0
  # The adapter's own spawn, with the state heartbeat every agent ships with:
  # that heartbeat is what discovers the restart, so a case that shortened it
  # would be measuring the grace window against a worker nobody runs.
  target=$(create_endpoint "fm-restart-$$")
  before=$(with_stream_env fm_backend_agent_state stream "$target")
  [ "$before" != missing ] || fail "the endpoint should be known before the restart"
  [ "$before" != unreadable ] || fail "the endpoint should be readable before the restart"

  restart_case_hub

  # Read it repeatedly across the whole recovery, because the defect is a
  # verdict taken DURING the window, not the one it settles on afterwards.
  while [ "$waited" -lt 30 ]; do
    after=$(with_stream_env fm_backend_agent_state stream "$target")
    [ "$after" != missing ] \
      || fail "a worker re-registering with its hub must never read missing"
    [ "$after" = "$before" ] && break
    sleep 0.5
    waited=$((waited + 1))
  done
  assert_equals "$after" "$before" \
    "the worker should read exactly as it did before, under the endpoint id it kept"
  # The half an operator notices: a steer aimed at a worker that lived through
  # the restart still reaches its terminal.
  with_stream_env fm_backend_send_text_submit stream "$target" 'echo AFTER-RESTART' 3 0.2 0.2 >/dev/null \
    || fail "the dispatcher refused to steer a worker that came back"
  wait_for_capture "$target" AFTER-RESTART \
    || fail "a steer for a worker that returns in seconds must not be dropped"
  pass "stream: a hub restart is waited out rather than reported as a missing worker"
}

test_the_fleet_listing_never_calls_a_rejoining_worker_absent() {
  # The listing an operator reads has two endpoint reads per row: the cheap
  # presence probe, which answers from the first reply, and the recovery-grade
  # agent-state verdict, which waits out a hub that restarted. During a rejoin
  # they disagree, and the row must not be rendered from the cheap one - an
  # `absent` row for a worker that is alive and back within seconds is exactly
  # the report this change exists to eliminate, and `alive` plus `absent` in
  # one row is a snapshot contradicting itself.
  start_case_hub snapshot-rejoin
  local id label target home out
  id="snapshotrejoin-$$"
  label="fm-$id"
  target=$(create_endpoint "$label")
  home="$CASE_DIR/home"
  mkdir -p "$home/state" "$home/data" "$home/projects/$id"
  fm_write_meta "$home/state/$id.meta" \
    "backend=stream" \
    "window=$target" \
    "worktree=$home/projects/$id" \
    "project=alpha" \
    "harness=claude" \
    "kind=ship" \
    "mode=ship"

  restart_case_hub

  # The precondition this case is about: the hub has forgotten the endpoint and
  # the presence probe says so, while the agent is still running and about to
  # register itself again.
  with_stream_env fm_backend_target_exists stream "$target" "$label" >/dev/null 2>&1 \
    && fail "the restarted hub should not know the endpoint yet; the rejoin window was missed"

  out=$(FM_HOME="$home" FM_ROOT="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STREAM_HUB="$URL" FM_STREAM_TOKEN="$TOKEN" FM_STREAM_MACHINE=box-test \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "the fleet snapshot failed while a worker was rejoining"
  printf '%s' "$out" | jq -e --arg id "$id" '
    [.tasks[] | select(.id == $id)] | length == 1
  ' >/dev/null || fail "the snapshot should carry exactly one row for the rejoining task: $out"
  local state status exists
  state=$(printf '%s' "$out" | jq -r --arg id "$id" '.tasks[] | select(.id == $id) | .endpoint.agent_state')
  status=$(printf '%s' "$out" | jq -r --arg id "$id" '.tasks[] | select(.id == $id) | .endpoint.status')
  exists=$(printf '%s' "$out" | jq -r --arg id "$id" '.tasks[] | select(.id == $id) | .endpoint.exists')
  assert_not_equals missing "$state" \
    "a worker re-registering with its hub must never read missing"
  [ "$status" != absent ] \
    || fail "a worker rejoining its restarted hub must not be listed absent: $out"
  [ "$exists" != false ] \
    || fail "the row must not claim absence the settled verdict does not support: $out"
  case "$state" in
    alive|dead|ambiguous)
      assert_equals true "$exists" \
        "a verdict the hub gave from a held record means the endpoint is there" ;;
  esac
  # And the worker is still steerable under the identity it kept, which is what
  # the listing is read to decide.
  with_stream_env fm_backend_send_text_submit stream "$target" 'echo LISTED-AFTER-RESTART' 3 0.2 0.2 >/dev/null \
    || fail "the dispatcher refused to steer the worker the listing kept"
  wait_for_capture "$target" LISTED-AFTER-RESTART \
    || fail "a steer for the worker the listing kept must reach its terminal"
  pass "stream: the fleet listing waits out a rejoin rather than calling the worker absent"
}

test_an_agent_reported_exit_still_reads_dead_once_the_state_is_stale() {
  # Staleness governs live READINGS. An agent-reported close carries the exit
  # code the owning agent watched the worker produce, so it is a recorded event
  # and does not expire - otherwise every finished stream task reads
  # `unreadable` for the whole retention hour and fm-control exit and relaunch
  # refuse a worker that provably ended.
  start_case_hub closedstate --state-max-age-secs 2
  local label target endpoint state waited=0
  label="fm-closedstate-$$"
  target=$(create_endpoint "$label")
  endpoint=${target##*:}
  # The worker exits on its own, the way a finished task does, and its agent
  # reports that exit and stops publishing.
  with_stream_env fm_backend_send_text_submit stream "$target" 'exit' 3 0.2 0.2 >/dev/null 2>&1 || true
  while [ "$waited" -lt 150 ]; do
    [ "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$endpoint")" \
      | jq -r '.task.closed_by // empty')" = agent ] && break
    sleep 0.2
    waited=$((waited + 1))
  done
  assert_equals "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$endpoint")" \
    | jq -r '.task.closed_by // empty')" agent \
    "the agent should have reported the worker's exit"
  # Past the freshness window: before it the answer is already `dead` from the
  # last live reading, so only this side of it tests anything.
  waited=0
  while [ "$waited" -lt 100 ]; do
    [ "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$endpoint/processes")" \
      | jq -r '.stale')" = true ] && break
    sleep 0.2
    waited=$((waited + 1))
  done
  assert_equals "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$endpoint/processes")" \
    | jq -r '.stale')" true \
    "the last state frame should have aged out of the freshness window"
  state=$(with_stream_env fm_backend_agent_state stream "$target")
  assert_equals "$state" dead \
    "a worker its own agent watched exit must keep reading dead past the staleness window"

  # And the boundary: a record the HUB closed by itself is an unacknowledged
  # kill that says nothing about the worker, so it must still withhold a
  # verdict rather than be laundered into a confirmed death.
  local forced
  forced=$(python3 -c 'import os; print(os.urandom(16).hex())')
  with_stream_env fm_backend_stream_api POST /v1/agent/endpoints \
    "$(jq -nc --arg id "$forced" --arg l "fm-forcedstate-$$" \
      '{endpoint_id: $id, machine: "box-test", label: $l, cwd: "/tmp"}')" >/dev/null \
    || fail "the endpoint with no agent should register"
  with_stream_env fm_backend_stream_api DELETE "/v1/tasks/$forced" >/dev/null \
    || fail "the hub should close a record whose agent never answers"
  assert_equals "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$forced")" \
    | jq -r '.task.closed_by // empty')" hub \
    "that close should be recorded as the hub's own"
  state=$(with_stream_env fm_backend_agent_state stream \
    "$(with_stream_env fm_backend_stream_hub_tag):$forced")
  assert_equals "$state" unreadable \
    "a close the hub made by itself is no evidence the worker stopped"
  pass "stream: an agent-reported exit stays dead past staleness, a forced close does not"
}

test_a_forced_close_gives_way_to_the_agents_own_later_report() {
  # A hub close is a presumption - the hub stopped carrying a record it could
  # not steer. An agent close is a fact. When the partition heals and the
  # owning agent later reports the exit it watched, the fact must take the
  # attribution, or the record carries a real exit code under a close the hub
  # invented and every consumer reads it as no evidence at all.
  # A short acknowledgement window, because the signal this case needs is the
  # hub giving up on a kill the paused agent cannot take.
  start_case_hub forcedthenagent --state-max-age-secs 2 --command-ack-secs 2
  local label target endpoint agent child out state waited=0
  label="fm-forcedthenagent-$$"
  target=$(create_endpoint "$label")
  endpoint=${target##*:}
  agent=$(agent_pid_for "$label")
  [ -n "$agent" ] || fail "the publishing agent should be running"
  child=$(pgrep -P "$agent" 2>/dev/null | head -1)
  [ -n "$child" ] || fail "the agent should own a worker"
  # The agent is partitioned. Its worker runs on; the hub simply cannot reach
  # the agent that holds it.
  kill -STOP "$agent" || fail "could not pause the agent"
  out=$(with_stream_env fm_backend_stream_api DELETE "/v1/tasks/$endpoint") || {
    kill -CONT "$agent"
    fail "the hub should close a record it cannot steer"
  }
  assert_equals "$(printf '%s' "$out" | jq -r '.delivered')" false     "a kill the paused agent never took must not be reported as delivered"
  assert_equals "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$endpoint")" \
    | jq -r '.task.closed_by // empty')" hub \
    "that close should first be recorded as the hub's own presumption"
  kill -CONT "$agent" || fail "could not resume the agent"
  # The partition heals, the worker ends, and its agent reports the exit it
  # watched - after the forced close, which is the ordering that matters.
  kill -KILL "$child" || fail "could not end the worker"
  while [ "$waited" -lt 250 ]; do
    [ "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$endpoint")" \
      | jq -r '.task.closed_by // empty')" = agent ] && break
    sleep 0.2
    waited=$((waited + 1))
  done
  assert_equals "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$endpoint")" \
    | jq -r '.task.closed_by // empty')" agent \
    "the owning agent's report must take the attribution from the hub's presumption"
  state=$(with_stream_env fm_backend_agent_state stream "$target")
  assert_equals "$state" dead \
    "a worker its own agent watched exit must read dead, whatever closed the record first"
  out=$(with_stream_env fm_backend_kill stream "$target" "" "$label" 2>&1) \
    || fail "a worker the owning agent watched exit is a confirmed stop: $out"
  assert_equals "$out" "" "a confirmed stop should say nothing"
  pass "stream: an agent's own close outranks a forced one that landed first"
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

test_only_a_close_the_agent_reported_counts_as_a_stop() {
  # The one confirmed stop there is: the endpoint's own agent watched the
  # worker exit and brought its exit code back. A record the hub closed on its
  # own knows nothing about that process, and calling it a stop would let a
  # task be treated as finished while it is still running.
  start_case_hub killverdict
  local label target endpoint out waited=0
  label="fm-exited-$$"
  target=$(create_endpoint "$label")
  endpoint=${target##*:}
  # The worker exits on its own, the way a finished task does.
  with_stream_env fm_backend_send_text_submit stream "$target" 'exit' 3 0.2 0.2 >/dev/null 2>&1 || true
  while [ "$waited" -lt 150 ]; do
    [ "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$endpoint")" \
      | jq -r '.task.closed_by // empty')" = agent ] && break
    sleep 0.2
    waited=$((waited + 1))
  done
  assert_equals "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$endpoint")" \
    | jq -r '.task.closed_by // empty')" agent \
    "the agent should have reported the worker's exit"
  out=$(with_stream_env fm_backend_kill stream "$target" "" "$label" 2>&1) \
    || fail "a worker the hub watched exit is a confirmed stop: $out"
  assert_equals "$out" "" "a confirmed stop should say nothing"
  # And a record the hub closed by itself is NOT a stop, even though the
  # endpoint reads closed exactly the same way from a listing.
  label="fm-forced-$$"
  endpoint=$(python3 -c 'import os; print(os.urandom(16).hex())')
  with_stream_env fm_backend_stream_api POST /v1/agent/endpoints \
    "$(jq -nc --arg id "$endpoint" --arg l "$label" \
      '{endpoint_id: $id, machine: "box-test", label: $l, cwd: "/tmp"}')" >/dev/null \
    || fail "the endpoint with no agent should register"
  with_stream_env fm_backend_stream_api DELETE "/v1/tasks/$endpoint" >/dev/null \
    || fail "the hub should close a record whose agent never answers"
  assert_equals "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET "/v1/tasks/$endpoint")" \
    | jq -r '.task.closed_by // empty')" hub \
    "that close should be recorded as the hub's own"
  out=$(with_stream_env fm_backend_kill stream "$(with_stream_env fm_backend_stream_hub_tag):$endpoint" \
    "" "$label" 2>&1) \
    && fail "a close the hub made by itself must not report a confirmed stop"
  assert_contains "$out" "may still be running" \
    "a forced close should say the worker may still be running"
  pass "stream: only a close the endpoint's own agent reported counts as a stop"
}

test_a_kill_the_hub_cannot_answer_is_never_a_confirmed_stop() {
  # The hub forgets an endpoint it has not heard from for long enough, and a
  # worker whose agent died outlives that. So an endpoint the hub does not have
  # is not evidence the worker stopped, and a kill against one must read the
  # same as any other kill the hub could not deliver.
  start_case_hub unknownkill
  local target out
  # A target the hub has never had, shaped exactly like a real one.
  target="$(with_stream_env fm_backend_stream_hub_tag):$(python3 -c 'import os; print(os.urandom(16).hex())')"
  # With the expected label, exactly as fm-teardown and fm-spawn call it.
  out=$(with_stream_env fm_backend_kill stream "$target" "" "fm-gone-$$" 2>&1) \
    && fail "a kill the hub could not answer must not report a confirmed stop"
  assert_contains "$out" "may still be running" \
    "an unanswerable kill should say the worker may still be running"
  pass "stream: a kill the hub cannot answer is reported as unconfirmed"
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

test_a_spawned_agents_diagnostics_stop_accumulating_once_it_registers() {
  # The adapter keeps the agent's output only to carry a refusal out of a spawn
  # that never registered, and unlinks it the moment registration succeeds. If
  # the agent kept writing there, every failed publish during a hub outage would
  # grow a file nobody can read, in a $TMPDIR that is often RAM.
  local target pid before after
  start_case_hub agentlog
  [ -r /proc/self/fd ] || { pass "stream: no /proc on this host to read a spawned agent's descriptors"; return; }
  target=$(create_endpoint "fm-agentlog-$$")
  pid=$(agent_pid_for "fm-agentlog-$$")
  [ -n "$pid" ] || fail "the spawned agent should be running"
  # Make the worker talk and take the hub away, which is what drives the agent's
  # per-failure diagnostics.
  with_stream_env fm_backend_send_text_submit stream "$target" \
    'while true; do echo diagnostic-pressure; done' 3 0.2 0.2 >/dev/null 2>&1 || true
  kill "$HUB_PID" 2>/dev/null || true
  sleep 1
  before=$(stat -L -c %s "/proc/$pid/fd/2" 2>/dev/null) || fail "could not read the agent's diagnostic descriptor"
  sleep 2
  after=$(stat -L -c %s "/proc/$pid/fd/2" 2>/dev/null) || fail "could not re-read the agent's diagnostic descriptor"
  assert_equals "$after" "$before" \
    "a registered agent's diagnostics must not keep growing (grew from $before to $after bytes)"
  kill "$pid" 2>/dev/null || true
  pass "stream: a spawned agent's diagnostics stop accumulating once it has registered"
}

test_a_create_that_times_out_leaves_nothing_behind() {
  # The hard shape: the hub takes the registration and THEN stalls, so the
  # attempt is abandoned with an endpoint already registered and no budget left
  # to close it. Nothing on the worker's side can clean that up - the agent is
  # gone - so the hub itself has to stop carrying a record no agent stands
  # behind, or the task id is unusable for as long as the hub runs.
  # Shipped defaults, deliberately: the guarantee is that an operator who
  # retries a refused spawn gets a working task, and a hub tuned for the test
  # would prove that about a configuration nobody runs. If the window the hub
  # waits before giving up on a silent endpoint ever grows past the budget an
  # agent gives its own startup, this case fails, which is the point of it.
  start_case_hub createtimeout
  local label out real_url target
  label="fm-slowhub-$$"
  start_slow_stand_in 3
  real_url=$URL
  URL=$SLOW_URL
  if out=$(with_stream_env fm_backend_stream_create_task "$label" "$CASE_DIR/cwd" 2>&1); then
    URL=$real_url
    fail "a create against a hub that answers too late should be refused, got '$out'"
  fi
  URL=$real_url
  assert_equals "$(agent_pid_for "$label")" "" \
    "an abandoned create must leave no agent holding a shell: $out"
  # The registration landed before the budget ran out, so the attempt owns a
  # record - and it closes it on the way out. An open endpoint with no agent
  # behind it is a worker the fleet listing reports and nobody can find.
  assert_equals "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET /v1/tasks)" \
    | jq -r '[.tasks[] | select(.closed_at | not)] | length')" 0 \
    "an abandoned create must leave no open endpoint behind it"
  # The record the abandoned attempt left behind no longer owns the task id,
  # so the obvious next thing an operator does works rather than colliding
  # with a worker that never came up.
  target=$(create_endpoint "$label")
  case "$target" in
    *:[0-9a-f]*) ;;
    *) fail "retrying the same task after a timed-out create should succeed, got '$target'" ;;
  esac
  pass "stream: a create that times out leaves no agent and no endpoint, and the retry succeeds"
}

test_a_failed_create_leaves_another_homes_endpoint_alone() {
  # The machine name defaults to the hostname, so two homes on one box share
  # it, and a task id can be spawned from either. A create that fails must
  # never reach for an endpoint by machine and label: the one it would find is
  # the OTHER home's running worker, with its own agent behind it.
  start_case_hub otherhome
  local label target endpoint out
  label="fm-shared-$$"
  target=$(create_endpoint "$label")
  endpoint=${target##*:}
  # This home now fails to create the same task: the hub refuses the duplicate
  # label, so the agent abandons before it ever owns an endpoint.
  out=$(with_stream_env fm_backend_stream_create_task "$label" "$CASE_DIR/cwd" 2>&1) \
    && fail "a create colliding with a live endpoint should be refused, got '$out'"
  assert_equals "$(printf '%s' "$(with_stream_env fm_backend_stream_api GET /v1/tasks)" \
    | jq -r --arg id "$endpoint" '[.tasks[] | select(.endpoint_id==$id and (.closed_at | not))] | length')" \
    1 "a failed create must leave the other home's live endpoint running"
  # And that worker is still steerable, not merely listed.
  with_stream_env fm_backend_send_text_submit stream "$target" 'echo STILL-MINE' 3 0.2 0.2 >/dev/null \
    || fail "the surviving endpoint should still take input"
  wait_for_capture "$target" STILL-MINE \
    || fail "the surviving endpoint should still be running its own worker"
  pass "stream: a failed create never closes another home's endpoint under the same label"
}

test_a_hub_that_stays_slow_does_not_outlive_the_spawn() {
  # A hub that is prompt for the health check and the registration and then
  # goes slow, on the last call before the ready file and on everything after
  # it. An abandonment that borrowed a fresh budget would still be calling the
  # hub long after fm-spawn refused the task, holding a shell nobody is
  # watching. The frame that closes a half-registered endpoint is always
  # attempted - an agent can always close the record it holds - but it is
  # bounded tightly enough that a hub which never answers cannot stretch the
  # attempt past the window. Giving up inside that window is what has to hold.
  start_case_hub staysslow
  local label out real_url
  label="fm-staysslow-$$"
  start_slow_stand_in 3+
  real_url=$URL
  URL=$SLOW_URL
  if out=$(with_stream_env fm_backend_stream_create_task "$label" "$CASE_DIR/cwd" 2>&1); then
    URL=$real_url
    fail "a create against a hub that stays slow should be refused, got '$out'"
  fi
  URL=$real_url
  # The adapter has refused by now. Nothing of the attempt may still be running.
  assert_equals "$(agent_pid_for "$label")" "" \
    "an agent whose startup ran out must be gone by the time the spawn is refused: $out"
  pass "stream: a startup against a permanently slow hub gives up inside its own budget"
}

test_a_slow_but_answering_hub_still_spawns() {
  # The agent must give up before the adapter does - and no sooner. A hub that
  # answers every startup call slowly but well inside the adapter's window is a
  # spawn that works; refusing it would be the budget failing in the other
  # direction, turning a working link into a refused task.
  start_case_hub slowbutfine
  local label target real_url
  label="fm-slowfine-$$"
  start_slow_stand_in_delay 2.5 ""
  real_url=$URL
  URL=$SLOW_URL
  target=$(with_stream_env fm_backend_stream_create_task "$label" "$CASE_DIR/cwd") \
    || { URL=$real_url; fail "a hub that answers slowly but inside the window should still spawn"; }
  URL=$real_url
  fm_test_track_helper_pid "$(agent_pid_for "$label")"
  case "$target" in
    *\ [0-9a-f]*) ;;
    *) fail "the slow-but-answering create should return a durable endpoint, got '$target'" ;;
  esac
  pass "stream: a hub that answers slowly but inside the window still spawns"
}

test_a_hung_process_probe_cannot_outlive_the_startup_budget() {
  # The agent reads its endpoint's foreground processes before announcing
  # readiness, and that read is a subprocess: a wedged ps, or lsof on a dead
  # network mount, blocks for as long as the box does. It is on the startup
  # path, so it spends the same clock every hub call does - the attempt is
  # decided inside the adapter's window either way, and never left running
  # behind a spawn that has already been refused.
  start_case_hub hungprobe
  local label out bin
  label="fm-hungprobe-$$"
  bin="$CASE_DIR/hung-bin"
  mkdir -p "$bin"
  printf '#!/bin/sh\nsleep 120\n' > "$bin/ps"
  chmod +x "$bin/ps"
  if out=$( (export PATH="$bin:$PATH"; with_stream_env fm_backend_stream_create_task \
      "$label" "$CASE_DIR/cwd") 2>&1 ); then
    # Answering inside the window is the good outcome, and the endpoint it
    # returned has to be real.
    fm_test_track_helper_pid "$(agent_pid_for "$label")"
    case "$out" in
      *\ [0-9a-f]*) ;;
      *) fail "the create should return a durable endpoint, got '$out'" ;;
    esac
  else
    # Giving up is the other good outcome - but nothing may still be running
    # against a probe that never returns.
    assert_equals "$(agent_pid_for "$label")" "" \
      "an agent whose probe hung must not outlive the refused spawn: $out"
  fi
  pass "stream: a hung process probe cannot outlive the startup budget"
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
test_the_composer_capture_frames_a_blank_screen_apart_from_the_cursor
test_agent_state_reads_the_foreground_process_not_the_screen
test_agent_state_separates_missing_unreachable_and_partitioned
test_a_restarting_hub_never_reads_as_a_missing_worker
test_the_fleet_listing_never_calls_a_rejoining_worker_absent
test_an_agent_reported_exit_still_reads_dead_once_the_state_is_stale
test_a_forced_close_gives_way_to_the_agents_own_later_report
test_kill_closes_the_exact_endpoint_and_leaves_its_sibling
test_only_a_close_the_agent_reported_counts_as_a_stop
test_a_kill_the_hub_cannot_answer_is_never_a_confirmed_stop
test_status_return_channel_appends_on_the_owning_machine
test_a_target_from_another_hub_is_refused
test_a_spawn_whose_shell_cannot_start_reports_the_shells_own_error
test_a_spawned_agents_diagnostics_stop_accumulating_once_it_registers
test_a_create_that_times_out_leaves_nothing_behind
test_a_failed_create_leaves_another_homes_endpoint_alone
test_a_hub_that_stays_slow_does_not_outlive_the_spawn
test_a_slow_but_answering_hub_still_spawns
test_a_hung_process_probe_cannot_outlive_the_startup_budget
test_an_unreachable_hub_refuses_and_names_the_start_command
test_hub_url_prefers_configuration_then_a_locally_started_hub
test_a_rejected_token_refuses_instead_of_retrying_unauthenticated
test_a_hub_speaking_another_protocol_is_refused
test_a_missing_dependency_refuses_and_names_the_tool
test_a_missing_token_reports_it_without_crashing
test_spawn_refuses_a_secondmate_on_stream
test_cleanup_validation_binds_a_record_to_the_hub_that_made_it
test_the_key_vocabulary_is_only_what_the_control_plane_permits
