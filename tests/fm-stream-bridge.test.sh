#!/usr/bin/env bash
# tests/fm-stream-bridge.test.sh - tests for the stream-hub-to-Bridge adapter
# (bin/fm-stream-bridge.py).
#
# Two kinds of input drive it. Recorded hub traffic, replayed through
# `translate`, pins the translation itself: the record shape the Bridge UI's
# own recorded feed uses, the per-leaf sequence, and the one verdict the hub
# can support. A REAL hub on an ephemeral loopback port - published to by hand,
# and in one case by a real agent owning a real pty - proves the adapter reads
# the hub's actual answers rather than the shapes this file assumes.
#
# The comparison harness (`compare`) is exercised against a stand-in for
# bin/fm-crew-state.sh, never the live fleet.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the stream bridge)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found (required by the stream backend)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the stream backend)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-stream-bridge-tests)
HUB="$ROOT/bin/fm-stream-hub.py"
AGENT="$ROOT/bin/fm-stream-agent.py"
BRIDGE="$ROOT/bin/fm-stream-bridge.py"
PUBLISH_TOKEN="pub-$$"
VIEW_TOKEN="view-$$"
CONTROL_TOKEN="ctl-$$"
CASE_DIR=""
URL=""
HUB_PID=""
RUN=$$

cleanup_helpers() {
  fm_test_reap_helper_pids
}
trap 'cleanup_helpers; fm_test_cleanup' EXIT INT TERM

# start_hub <case-name> -> sets CASE_DIR URL. The bridge gets a bare,
# subscribe-only token: the credential it is documented to need, and nothing
# more.
start_hub() {
  local name=$1 ready waited=0 host port pid
  cleanup_helpers
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR/cwd"
  printf 'publish:%s\nsubscribe,control:%s\n%s\n' \
    "$PUBLISH_TOKEN" "$CONTROL_TOKEN" "$VIEW_TOKEN" > "$CASE_DIR/tokens"
  printf '%s\n' "$VIEW_TOKEN" > "$CASE_DIR/view-token"
  printf '%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/publish-token"
  printf '%s\n' "$CONTROL_TOKEN" > "$CASE_DIR/control-token"
  chmod 600 "$CASE_DIR/tokens" "$CASE_DIR/view-token" "$CASE_DIR/publish-token" \
    "$CASE_DIR/control-token"
  ready="$CASE_DIR/ready"
  python3 "$HUB" serve --bind 127.0.0.1 --port 0 \
    --token-file "$CASE_DIR/tokens" --ready-file "$ready" > "$CASE_DIR/log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  HUB_PID=$pid
  while [ "$waited" -lt 100 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "hub did not report ready for case $name: $(cat "$CASE_DIR/log" 2>/dev/null)"
  read -r host port < "$ready"
  URL="http://$host:$port"
}

publish() {  # <method> <path> <body>
  curl -sS -m 30 -X "$1" -H "Authorization: Bearer $PUBLISH_TOKEN" \
    -H 'Content-Type: application/json' --data-binary "$3" -o /dev/null \
    -w '%{http_code}' "$URL$2" 2>/dev/null
}

new_id() {
  python3 -c 'import os; print(os.urandom(16).hex())'
}

register() {  # <endpoint-id> <machine> <label>
  local code
  code=$(publish POST /v1/agent/endpoints "$(jq -nc --arg id "$1" --arg m "$2" --arg l "$3" \
    '{endpoint_id: $id, machine: $m, label: $l, cwd: "/tmp"}')")
  assert_equals "$code" 201 "endpoint $3 should register"
}

close_endpoint() {  # <endpoint-id> <machine> <exit-code-json>
  local code
  code=$(publish POST /v1/agent/frames "$(jq -nc --arg id "$1" --arg m "$2" --argjson c "$3" \
    '{machine: $m, frames: [{endpoint_id: $id, closed: true, exit_code: $c}]}')")
  assert_equals "$code" 200 "the owning agent should close its record"
}

snapshot() {
  python3 "$BRIDGE" snapshot --hub "$URL" --token-file "$CASE_DIR/view-token" --epoch 42
}

state_of() {  # <feed> <endpoint-id>
  printf '%s\n' "$1" | jq -r --arg id "$2" \
    'select(.identity.execution_id == $id) | .state' | tail -1
}

# A recorded session: two hub answers for the same three endpoints, the second
# after one worker's agent reported its exit.
recorded_session() {
  local open=0123456789abcdef0123456789abcdef hub=11111111111111111111111111111111
  local finished=22222222222222222222222222222222
  jq -nc --arg o "$open" --arg h "$hub" --arg d "$finished" '{
    at_ms: 0, received_ms: 0, listing: {ok: true, tasks: [
      {endpoint_id: $o, machine: "box-a", label: "task-open", current_execution: true, closed_by: null, exit_code: null},
      {endpoint_id: $h, machine: "box-a", label: "task-forced", current_execution: true, closed_by: "hub", exit_code: null},
      {endpoint_id: $d, machine: "box-b", label: "task-open", current_execution: true, closed_by: null, exit_code: null}]}}'
  jq -nc --arg o "$open" --arg h "$hub" --arg d "$finished" '{
    at_ms: 500.5, received_ms: 499, listing: {ok: true, tasks: [
      {endpoint_id: $o, machine: "box-a", label: "task-open", current_execution: true, closed_by: null, exit_code: null},
      {endpoint_id: $h, machine: "box-a", label: "task-forced", current_execution: true, closed_by: "hub", exit_code: null},
      {endpoint_id: $d, machine: "box-b", label: "task-open", current_execution: true, closed_by: "agent", exit_code: 0}]}}'
}

test_recorded_traffic_replays_into_the_bridge_record_shape() {
  local out
  out=$(recorded_session | python3 "$BRIDGE" translate --fleet-id fleet-t --epoch 7) \
    || fail "translate refused a well-formed recording: $out"
  assert_equals "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" 6 \
    "every tick should emit one record per leaf"
  # The exact key sets of the UI's recorded leaf_heartbeat line, in its order.
  assert_equals "$(printf '%s\n' "$out" | jq -c 'keys_unsorted' | sort -u)" \
    '["record","identity","sequence","state","clock"]' "record keys should match the UI's feed"
  assert_equals "$(printf '%s\n' "$out" | jq -c '.identity | keys_unsorted' | sort -u)" \
    '["fleet_id","leaf_worker_id","parent_mate_id","execution_id","stream_epoch"]' \
    "identity keys should match the UI's feed"
  assert_equals "$(printf '%s\n' "$out" | jq -c '.clock | keys_unsorted' | sort -u)" \
    '["producer_monotonic_ms","hub_arrival_ms"]' "clock keys should match the UI's feed"
  assert_equals "$(printf '%s\n' "$out" | jq -r '.record' | sort -u)" leaf_heartbeat \
    "the hub carries no token counter, so only heartbeats may be emitted"
  assert_equals "$(printf '%s\n' "$out" | jq -r '[.identity.stream_epoch, .identity.fleet_id] | @tsv' | sort -u)" \
    "$(printf '7\tfleet-t')" "every record should carry the declared epoch and fleet"
  # Compared as numbers: jq releases differ in how they print 0.0.
  assert_equals "$(printf '%s\n' "$out" | jq -r 'select(.clock == {producer_monotonic_ms: 0, hub_arrival_ms: 0}) | .sequence' | tr '\n' ' ')" \
    "1 1 1 " "the first tick's clocks should come from the recording"
  assert_equals "$(printf '%s\n' "$out" | jq -r 'select(.clock == {producer_monotonic_ms: 500.5, hub_arrival_ms: 499}) | .sequence' | tr '\n' ' ')" \
    "2 2 2 " "the second tick's clocks should come from the recording"
  assert_equals "$(printf '%s\n' "$out" | jq -r 'select(.identity.execution_id == "22222222222222222222222222222222") | .identity | [.leaf_worker_id, .parent_mate_id] | @tsv' | sort -u)" \
    "$(printf 'box-b/task-open\tbox-b')" "a leaf should be named by its machine and label"
  assert_equals "$(printf '%s\n' "$out" | jq -r '.identity.leaf_worker_id' | sort -u | wc -l | tr -d ' ')" 3 \
    "one label on two machines should be two leaves"
  assert_equals "$(printf '%s\n' "$out" | jq -r '.sequence' | tr '\n' ' ')" "1 1 1 2 2 2 " \
    "each leaf's sequence should strictly increase across ticks"
  pass "bridge: recorded hub traffic replays into the Bridge UI's record shape"
}

test_only_an_agent_reported_exit_is_a_verdict() {
  local out
  out=$(jq -nc '{at_ms: 1, listing: {tasks: [
      {endpoint_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", machine: "m", label: "open", current_execution: true, closed_by: null, exit_code: null},
      {endpoint_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", machine: "m", label: "forced", current_execution: true, closed_by: "hub", exit_code: null},
      {endpoint_id: "cccccccccccccccccccccccccccccccc", machine: "m", label: "clean", current_execution: true, closed_by: "agent", exit_code: 0},
      {endpoint_id: "dddddddddddddddddddddddddddddddd", machine: "m", label: "signal", current_execution: true, closed_by: "agent", exit_code: -15},
      {endpoint_id: "eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee", machine: "m", label: "nocode", current_execution: true, closed_by: "agent", exit_code: null},
      {endpoint_id: "ffffffffffffffffffffffffffffffff", machine: "m", label: "failing", current_execution: true, closed_by: "agent", exit_code: 3}]}}' \
    | python3 "$BRIDGE" translate) || fail "translate refused the listing: $out"
  assert_equals "$(printf '%s\n' "$out" | jq -r '[.identity.leaf_worker_id, .state] | @tsv' | tr '\n' ' ')" \
    "$(printf 'm/open\tUnknown m/forced\tUnknown m/clean\tStopped m/signal\tStopped m/nocode\tStopped m/failing\tFailed ')" \
    "only the owning agent's reported exit should carry a verdict"
  assert_no_grep '"Idle"' <(printf '%s\n' "$out") "the hub has no idle signal, so no record may claim one"
  pass "bridge: only an exit the owning agent reported becomes Stopped or Failed"
}

test_malformed_input_is_refused_or_left_out() {
  local out code
  out=$(jq -nc '{at_ms: 1, listing: {tasks: [
      {endpoint_id: "not-an-id", machine: "m", label: "bad-id", current_execution: true},
      {endpoint_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", machine: "bad machine", label: "x", current_execution: true},
      {endpoint_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", machine: "m", label: "ok", current_execution: true}]}}' \
    | python3 "$BRIDGE" translate)
  assert_equals "$(printf '%s\n' "$out" | jq -r '.identity.leaf_worker_id')" m/ok \
    "an endpoint the hub would not have registered is not a leaf"
  out=$(printf '%s\n' '{"at_ms":1,"listing":{"tasks":[{"endpoint_id":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","machine":"m","label":"unmarked"}]}}' \
    | python3 "$BRIDGE" translate 2>&1)
  code=$?
  assert_equals "$code" 2 "a valid endpoint without the hub current marker should be refused"
  out=$(printf 'not json\n' | python3 "$BRIDGE" translate 2>&1)
  code=$?
  assert_equals "$code" 2 "a malformed recording should be refused"
  assert_contains "$out" "line 1" "the refusal should name the line"
  out=$(printf '{"at_ms": -1, "listing": {"tasks": []}}\n' | python3 "$BRIDGE" translate 2>&1)
  assert_equals "$?" 2 "a negative clock should be refused"
  out=$(printf '{"at_ms": 5, "received_ms": 9, "listing": {"tasks": []}}\n' | python3 "$BRIDGE" translate 2>&1)
  assert_equals "$?" 2 "an answer received after the record was built should be refused"
  out=$(printf '{"at_ms": 5}\n' | python3 "$BRIDGE" translate 2>&1)
  assert_equals "$?" 2 "a recording with no listing should be refused"
  pass "bridge: malformed recordings are refused and malformed endpoints left out"
}

test_a_relaunched_leaf_is_emitted_once_from_the_hubs_current_execution() {
  local old=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa relaunched=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb out tick
  tick=$(jq -nc --arg o "$old" --arg n "$relaunched" '{listing: {tasks: [
      {endpoint_id: $o, machine: "m", label: "t1", current_execution: true, closed_by: null, exit_code: null},
      {endpoint_id: $n, machine: "m", label: "t1", current_execution: false, closed_by: null, exit_code: null}]}}')
  out=$( { printf '%s\n' "$tick" | jq -c '.at_ms = 0'
           jq -nc --arg o "$old" '{at_ms: 500, listing: {tasks: [
             {endpoint_id: $o, machine: "m", label: "t1", current_execution: true, closed_by: "agent", exit_code: 2}]}}'
           printf '%s\n' "$tick" | jq -c '.at_ms = 1000'; } \
    | python3 "$BRIDGE" translate) || fail "translate refused the relaunch recording: $out"
  assert_equals "$(printf '%s\n' "$out" | jq -r '[.sequence, .identity.execution_id, .state] | @tsv' | tr '\n' ' ')" \
    "$(printf '1\t%s\tUnknown 2\t%s\tFailed 3\t%s\tUnknown ' "$old" "$old" "$old")" \
    "a leaf should get one record per tick from the execution the hub selected"

  start_hub relaunch
  old=$(new_id); relaunched=$(new_id)
  register "$old" box-a "t-$RUN"
  close_endpoint "$old" box-a 2
  register "$relaunched" box-a "t-$RUN"
  out=$(snapshot) || fail "snapshot failed against a healthy hub: $out"
  assert_equals "$(printf '%s\n' "$out" | jq -r --arg l "box-a/t-$RUN" 'select(.identity.leaf_worker_id == $l) | [.identity.execution_id, .state] | @tsv')" \
    "$(printf '%s\tUnknown' "$relaunched")" "the real hub's relaunch should surface only the new execution"
  pass "bridge: a leaf is emitted once from the hub's current execution"
}

test_a_snapshot_reads_the_real_hub() {
  start_hub snapshot
  local open finished forced out
  open=$(new_id); finished=$(new_id); forced=$(new_id)
  register "$open" box-a "open-$RUN"
  register "$finished" box-b "finished-$RUN"
  register "$forced" box-a "failed-$RUN"
  close_endpoint "$finished" box-b 0
  close_endpoint "$forced" box-a 2
  out=$(snapshot) || fail "snapshot failed against a healthy hub: $out"
  assert_equals "$(state_of "$out" "$open")" Unknown "an open endpoint carries no verdict"
  assert_equals "$(state_of "$out" "$finished")" Stopped "a clean agent-reported exit is Stopped"
  assert_equals "$(state_of "$out" "$forced")" Failed "a failing agent-reported exit is Failed"
  assert_equals "$(printf '%s\n' "$out" | jq -r --arg id "$open" 'select(.identity.execution_id == $id) | .identity | [.leaf_worker_id, .parent_mate_id, .stream_epoch] | @tsv')" \
    "$(printf 'box-a/open-%s\tbox-a\t42' "$RUN")" "the identity should come from the hub's registration"
  pass "bridge: a snapshot reads a real hub's registrations and closes"
}

test_a_real_agents_worker_exit_reaches_the_bridge() {
  start_hub realagent
  local ready endpoint waited=0 state=""
  ready="$CASE_DIR/agent.ready"
  python3 "$AGENT" serve --hub "$URL" --token-file "$CASE_DIR/publish-token" \
    --machine box-a --label "real-$RUN" --cwd "$CASE_DIR/cwd" \
    --ready-file "$ready" --state-interval 1 --poll-secs 3 > "$CASE_DIR/agent.log" 2>&1 &
  local pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 150 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "the agent did not register: $(cat "$CASE_DIR/agent.log" 2>/dev/null)"
  read -r _ endpoint < "$ready"
  assert_equals "$(state_of "$(snapshot)" "$endpoint")" Unknown \
    "a running worker carries no verdict: the hub cannot tell working from idle"
  curl -sS -m 30 -X POST -H "Authorization: Bearer $CONTROL_TOKEN" \
    -H 'Content-Type: application/json' --data-binary '{"text":"exit 5","submit":true}' \
    "$URL/v1/tasks/$endpoint/input" >/dev/null 2>&1 || fail "could not type into the worker"
  waited=0
  while [ "$waited" -lt 100 ]; do
    state=$(state_of "$(snapshot)" "$endpoint")
    [ "$state" = Failed ] && break
    sleep 0.2
    waited=$((waited + 1))
  done
  assert_equals "$state" Failed "the worker's own nonzero exit should reach the Bridge as Failed"
  pass "bridge: a real agent's reported worker exit reaches the Bridge"
}

test_serve_streams_ticks_and_goes_silent_without_the_hub() {
  start_hub serve
  local endpoint out err waited=0 lines before after
  endpoint=$(new_id)
  register "$endpoint" box-a "serve-$RUN"
  out="$CASE_DIR/serve.out"
  err="$CASE_DIR/serve.err"
  python3 "$BRIDGE" serve --hub "$URL" --token-file "$CASE_DIR/view-token" \
    --interval-ms 100 --epoch 3 > "$out" 2> "$err" &
  local bridge=$!
  disown "$bridge" 2>/dev/null || true
  fm_test_track_helper_pid "$bridge"
  while [ "$waited" -lt 100 ]; do
    lines=$(wc -l < "$out" | tr -d ' ')
    [ "$lines" -ge 3 ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$lines" -ge 3 ] || fail "serve should emit a heartbeat every tick: $(cat "$err")"
  assert_equals "$(jq -r '.sequence' "$out" | head -3 | tr '\n' ' ')" "1 2 3 " \
    "one leaf's sequence should rise by one each tick"
  assert_equals "$(jq -r '.clock.producer_monotonic_ms' "$out" | head -3 | sort -n -c && echo ordered)" ordered \
    "the producer clock should never go backwards"
  # The hub goes away. Records must stop, not freeze at the last state.
  kill "$HUB_PID" || fail "could not stop this case's hub"
  waited=0
  while [ "$waited" -lt 50 ]; do
    grep -q 'emitting nothing' "$err" && break
    sleep 0.1
    waited=$((waited + 1))
  done
  assert_grep 'emitting nothing' "$err" "an unreachable hub should be reported on stderr"
  before=$(wc -l < "$out" | tr -d ' ')
  sleep 0.5
  after=$(wc -l < "$out" | tr -d ' ')
  assert_equals "$after" "$before" "nothing should be emitted while the hub cannot be read"
  kill -0 "$bridge" 2>/dev/null || fail "an unreachable hub should not end serve"
  kill "$bridge" 2>/dev/null
  pass "bridge: serve streams every tick and goes silent while the hub is gone"
}

test_refusals_end_the_command() {
  start_hub refusals
  local out code fake_dir ready waited=0 host port pid
  out=$(python3 "$BRIDGE" snapshot --hub "$URL" --token-file "$CASE_DIR/publish-token" 2>&1)
  code=$?
  assert_equals "$code" 2 "a credential without the subscribe class should be refused"
  assert_contains "$out" "subscribe class" "the refusal should name the missing class"
  out=$(python3 "$BRIDGE" serve --hub "$URL" --token-file "$CASE_DIR/view-token" --interval-ms 1500 2>&1)
  assert_equals "$?" 2 "a tick at the Bridge's stale threshold should be refused"
  # The narrowest real stand-in for incompatible hub negotiations.
  fake_dir="$CASE_DIR/fake"
  mkdir -p "$fake_dir"
  ready="$fake_dir/ready"
  python3 - "$ready" > "$fake_dir/log" 2>&1 <<'PY' &
import http.server, json, sys
class H(http.server.BaseHTTPRequestHandler):
    health_calls = 0
    def log_message(self, *a): pass
    def do_GET(self):
        if self.path == "/v1/tasks":
            body = json.dumps({"ok": True, "tasks": []}).encode()
        else:
            H.health_calls += 1
            protocol = 99 if H.health_calls == 5 else 2
            if H.health_calls == 1:
                capabilities = []
            elif H.health_calls == 2:
                capabilities = ["current_execution"]
            else:
                capabilities = ["current_execution", "idempotent_command_results"]
            body = json.dumps({"ok": True, "protocol": protocol,
                               "capabilities": capabilities}).encode()
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
server = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write("%s %d\n" % server.server_address)
server.serve_forever()
PY
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 50 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  read -r host port < "$ready"
  out=$(python3 "$BRIDGE" snapshot --hub "http://$host:$port" --token-file "$CASE_DIR/view-token" 2>&1)
  assert_equals "$?" 2 "an older hub without the required capability should be refused"
  assert_contains "$out" "current_execution" "the refusal should name the missing capability"
  assert_contains "$out" "restart or upgrade the hub" \
    "the refusal should tell the operator how to replace the stale running hub"
  out=$(printf '' | python3 "$BRIDGE" command --hub "http://$host:$port" \
    --token-file "$CASE_DIR/view-token" --fleet-id test-fleet 2>&1)
  assert_equals "$?" 2 "the command adapter should reject a hub without result retries"
  assert_contains "$out" "idempotent_command_results" \
    "the command refusal should name the missing acknowledgement capability"
  out=$(printf '' | python3 "$BRIDGE" command --hub "http://$host:$port" \
    --token-file "$CASE_DIR/view-token" --fleet-id test-fleet 2>&1)
  assert_equals "$?" 2 "the command adapter should reject a hub without endpoint gating"
  assert_contains "$out" "result_retry_orderability" \
    "the command refusal should name the missing endpoint-gate generation"
  out=$(python3 "$BRIDGE" snapshot --hub "http://$host:$port" \
    --token-file "$CASE_DIR/view-token" 2>&1)
  assert_equals "$?" 0 "a read-only feed should accept the narrower current-execution capability"
  out=$(python3 "$BRIDGE" snapshot --hub "http://$host:$port" --token-file "$CASE_DIR/view-token" 2>&1)
  assert_equals "$?" 2 "a hub speaking another protocol should be refused"
  assert_contains "$out" "protocol 99" "the refusal should name the protocol it found"
  pass "bridge: wrong credentials and incompatible hubs are refused during negotiation"
}

test_command_rebinds_to_the_active_hub_generation() {
  local fake_dir ready journal waited=0 host port pid out endpoint
  fake_dir="$TMP_ROOT/generation-rebind"
  mkdir -p "$fake_dir"
  ready="$fake_dir/ready"
  journal="$fake_dir/orders"
  python3 - "$ready" "$journal" > "$fake_dir/log" 2>&1 <<'PY' &
import http.server
import json
import sys

class H(http.server.BaseHTTPRequestHandler):
    generation = "generation-a"
    def log_message(self, *args):
        pass
    def reply(self, status, payload):
        body = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def do_GET(self):
        self.reply(200, {"ok": True, "protocol": 2,
                         "capabilities": ["current_execution",
                                          "idempotent_command_results",
                                          "result_retry_orderability"],
                         "generation": H.generation})
    def do_POST(self):
        length = int(self.headers.get("Content-Length") or 0)
        payload = json.loads(self.rfile.read(length))
        with open(sys.argv[2], "a", encoding="utf-8") as handle:
            handle.write(payload.get("hub_generation", "") + "\n")
        if payload.get("hub_generation") == "generation-a":
            H.generation = "generation-b"
            self.reply(409, {"ok": False, "error": "hub_generation_changed",
                             "message": "hub restarted"})
            return
        self.reply(200, {"ok": True, "order_id": payload["order_id"],
                         "leaf_worker_id": payload["leaf_worker_id"],
                         "requested_execution_id": payload["execution_id"],
                         "execution_id": payload["execution_id"],
                         "outcome": "accepted", "delivered": True,
                         "worker_gone": False, "not_registered": False,
                         "requested_at": 1})
server = http.server.HTTPServer(("127.0.0.1", 0), H)
open(sys.argv[1], "w").write("%s %d\n" % server.server_address)
server.serve_forever()
PY
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 50 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "the generation stand-in did not start"
  read -r host port < "$ready"
  endpoint=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  out=$(printf '%s\n' "$(composer_command c-generation box-a/worker \
    'echo GENERATION' "$endpoint")" | python3 "$BRIDGE" command \
    --hub "http://$host:$port" --token-file "$CASE_DIR/control-token" \
    --fleet-id test-fleet 2>/dev/null)
  assert_equals "$(printf '%s' "$out" | jq -r '.state')" accepted \
    "the command should be accepted after renegotiating the replacement hub"
  assert_equals "$(tr '\n' ' ' < "$journal")" "generation-a generation-b " \
    "the retry should bind to the newly negotiated hub generation"
  assert_equals "$(printf '%s' "$out" | jq -r 'has("hub_generation")')" false \
    "internal hub generation must not change the Bridge acknowledgement shape"
  pass "bridge: commands rebind atomically to the active hub generation"
}

# start_real_agent <label> -> endpoint id. A real agent owning a real pty, so
# the command cases drive the same chain a composer would.
start_real_agent() {  # <label>
  local label=$1 ready pid waited=0 endpoint
  ready="$CASE_DIR/agent-$label.ready"
  rm -f "$ready"
  python3 "$AGENT" serve --hub "$URL" --token-file "$CASE_DIR/publish-token" \
    --machine box-a --label "$label-$RUN" --cwd "$CASE_DIR/cwd" \
    --ready-file "$ready" --state-interval 1 --poll-secs 3 \
    > "$CASE_DIR/agent-$label.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 150 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "the agent did not register: $(cat "$CASE_DIR/agent-$label.log" 2>/dev/null)"
  read -r _ endpoint < "$ready"
  printf '%s' "$endpoint"
}

# commander <record> -> the records the adapter emits for it. It gets the
# CONTROL token, which is the whole difference between the two directions.
commander() {  # <json-record>
  printf '%s\n' "$1" | python3 "$BRIDGE" command --hub "$URL" \
    --token-file "$CASE_DIR/control-token" --fleet-id test-fleet 2>/dev/null
}

composer_command() {  # <command-id> <leaf> <text> <execution> [fleet]
  jq -nc --arg id "$1" --arg leaf "$2" --arg text "$3" --arg ex "$4" \
    --arg fleet "${5:-test-fleet}" \
    '{record: "command", command_id: $id, issued_at_utc: "2026-01-01T00:00:00Z",
      issued_by: "captain",
      identity: {fleet_id: $fleet, leaf_worker_id: $leaf, parent_mate_id: "box-a",
                 execution_id: $ex},
      payload: {kind: "steer", text: $text}}'
}

worker_ran() {  # <endpoint> <needle>
  local waited=0
  while [ "$waited" -lt 150 ]; do
    case "$(curl -sS -m 30 -H "Authorization: Bearer $VIEW_TOKEN" \
      "$URL/v1/tasks/$1/capture?lines=40" 2>/dev/null)" in
      *"$2"*) return 0 ;;
    esac
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

test_a_composer_command_reaches_the_worker_and_is_acknowledged() {
  start_hub command-accepted
  local endpoint out
  endpoint=$(start_real_agent ordered)
  out=$(commander "$(composer_command c-accept "box-a/ordered-$RUN" "echo COMPOSER-ORDER" "$endpoint")")
  assert_equals "$(printf '%s' "$out" | jq -r '.record')" command_ack \
    "an order the worker took should be acknowledged"
  assert_equals "$(printf '%s' "$out" | jq -r '.state')" accepted \
    "the acknowledgement should say accepted"
  assert_equals "$(printf '%s' "$out" | jq -r '.command_id')" c-accept \
    "the acknowledgement carries the id the composer issued"
  assert_equals "$(printf '%s' "$out" | jq -r '.leaf_worker_id')" "box-a/ordered-$RUN" \
    "and the leaf it was addressed to"
  worker_ran "$endpoint" COMPOSER-ORDER \
    || fail "accepted must mean the worker actually received it"
  pass "bridge: a composer command reaches the worker and is acknowledged"
}

test_a_duplicate_command_id_keeps_the_leaf_that_received_it() {
  start_hub command-id-leaf
  local first second out command_id=c-reused
  first=$(start_real_agent first)
  second=$(start_real_agent second)
  out=$(commander "$(composer_command "$command_id" "box-a/first-$RUN" \
    "echo FIRST-RECEIVED" "$first")")
  assert_equals "$(printf '%s' "$out" | jq -r '.state')" accepted \
    "the first use of the command id should be accepted"
  worker_ran "$first" FIRST-RECEIVED || fail "the first worker never received its order"
  out=$(commander "$(composer_command "$command_id" "box-a/second-$RUN" \
    "echo SECOND-MUST-NOT-RUN" "$second")")
  assert_equals "$(printf '%s' "$out" | jq -r '.state')" accepted \
    "reusing an accepted command id should report its recorded result"
  assert_equals "$(printf '%s' "$out" | jq -r '.leaf_worker_id')" "box-a/first-$RUN" \
    "the recorded acceptance must name the leaf that actually received it"
  assert_not_contains "$(curl -sS -m 30 -H "Authorization: Bearer $VIEW_TOKEN" \
    "$URL/v1/tasks/$second/capture?lines=40" 2>/dev/null)" SECOND-MUST-NOT-RUN \
    "a reused command id must not fabricate acceptance for another leaf"

  local legacy=cccccccccccccccccccccccccccccccc
  register "$legacy" box-a "legacy-$RUN"
  out=$(commander "$(composer_command c-reused-refusal "box-a/legacy-$RUN" \
    "echo LEGACY-MUST-NOT-RUN" "$legacy")")
  assert_equals "$(printf '%s' "$out" | jq -r '.state')" refused \
    "an endpoint without result retries should refuse an order"
  out=$(commander "$(composer_command c-reused-refusal "box-a/second-$RUN" \
    "echo REFUSED-ID-MUST-NOT-RUN" "$second")")
  assert_equals "$(printf '%s' "$out" | jq -r '.state')" refused \
    "reusing a refused command id should report its recorded result"
  assert_equals "$(printf '%s' "$out" | jq -r '.leaf_worker_id')" "box-a/legacy-$RUN" \
    "a recorded refusal must keep the leaf whose order was actually considered"
  assert_not_contains "$(curl -sS -m 30 -H "Authorization: Bearer $VIEW_TOKEN" \
    "$URL/v1/tasks/$second/capture?lines=40" 2>/dev/null)" REFUSED-ID-MUST-NOT-RUN \
    "a reused refused command id must not resolve another leaf's command"
  pass "bridge: a reused command id keeps its recorded leaf"
}

test_a_command_for_a_worker_its_agent_reported_gone_is_nacked() {
  start_hub command-gone
  local endpoint out waited=0
  endpoint=$(start_real_agent ending)
  curl -sS -m 30 -X DELETE -H "Authorization: Bearer $CONTROL_TOKEN" \
    "$URL/v1/tasks/$endpoint" >/dev/null 2>&1
  while [ "$waited" -lt 150 ]; do
    [ -n "$(curl -sS -m 30 -H "Authorization: Bearer $VIEW_TOKEN" \
      "$URL/v1/tasks/$endpoint" 2>/dev/null | jq -r '.task.closed_at // empty')" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  out=$(commander "$(composer_command c-gone "box-a/ending-$RUN" "echo TOO-LATE" "$endpoint")")
  assert_equals "$(printf '%s' "$out" | jq -r '.record')" command_nack \
    "a worker its own agent reported gone is a membership answer"
  assert_equals "$(printf '%s' "$out" | jq -r '.reason')" no_such_worker \
    "and the reason names the worker being gone"
  pass "bridge: a command for a worker its agent reported gone is nacked"
}

test_a_command_aimed_at_a_replaced_execution_is_refused_without_claiming_absence() {
  # The worker is right there, so this is a refusal, never a membership nack -
  # and the replacement must not receive an order composed for the execution it
  # replaced.
  start_hub command-superseded
  local first second out waited=0
  first=$(start_real_agent relaunched)
  curl -sS -m 30 -X DELETE -H "Authorization: Bearer $CONTROL_TOKEN" \
    "$URL/v1/tasks/$first" >/dev/null 2>&1
  while [ "$waited" -lt 150 ]; do
    [ -n "$(curl -sS -m 30 -H "Authorization: Bearer $VIEW_TOKEN" \
      "$URL/v1/tasks/$first" 2>/dev/null | jq -r '.task.closed_at // empty')" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  second=$(start_real_agent relaunched)
  [ "$second" != "$first" ] || fail "the relaunch should be a new execution"
  out=$(commander "$(composer_command c-old "box-a/relaunched-$RUN" "echo WRONG-WORKER" "$first")")
  assert_equals "$(printf '%s' "$out" | jq -r '.record')" command_ack \
    "a present worker must not be reported as a membership absence"
  assert_equals "$(printf '%s' "$out" | jq -r '.state')" refused \
    "an order aimed at a replaced execution is refused"
  out=$(commander "$(composer_command c-new "box-a/relaunched-$RUN" "echo RIGHT-WORKER" "$second")")
  assert_equals "$(printf '%s' "$out" | jq -r '.state')" accepted \
    "the leaf's current execution still takes orders"
  worker_ran "$second" RIGHT-WORKER || fail "the current execution never ran its order"
  assert_not_contains "$(curl -sS -m 30 -H "Authorization: Bearer $VIEW_TOKEN" \
    "$URL/v1/tasks/$second/capture?lines=40" 2>/dev/null)" WRONG-WORKER \
    "an order composed for a replaced execution must never land in its replacement"
  pass "bridge: a command aimed at a replaced execution is refused without claiming absence"
}

test_a_command_without_a_valid_execution_is_refused() {
  start_hub command-execution
  local endpoint leaf out
  endpoint=$(start_real_agent guarded)
  leaf="box-a/guarded-$RUN"
  out=$(commander "$(jq -nc --arg leaf "$leaf" \
    '{record: "command", command_id: "c-no-execution",
      identity: {fleet_id: "test-fleet", leaf_worker_id: $leaf},
      payload: {kind: "steer", text: "echo UNBOUND"}}')")
  assert_equals "$(printf '%s' "$out" | jq -r '.record')" command_ack \
    "an addressable command missing execution scope should be answered"
  assert_equals "$(printf '%s' "$out" | jq -r '.state')" refused \
    "a command missing execution scope must be refused"
  out=$(commander "$(composer_command c-bad-execution "$leaf" "echo MALFORMED" invalid)")
  assert_equals "$(printf '%s' "$out" | jq -r '.state')" refused \
    "a malformed execution scope must be refused"
  assert_not_contains "$(curl -sS -m 30 -H "Authorization: Bearer $VIEW_TOKEN" \
    "$URL/v1/tasks/$endpoint/capture?lines=40" 2>/dev/null)" UNBOUND \
    "a command missing execution scope must not reach the current worker"
  assert_not_contains "$(curl -sS -m 30 -H "Authorization: Bearer $VIEW_TOKEN" \
    "$URL/v1/tasks/$endpoint/capture?lines=40" 2>/dev/null)" MALFORMED \
    "a malformed execution scope must not reach the current worker"
  pass "bridge: commands require the execution they were composed against"
}

test_a_command_for_another_or_missing_fleet_is_nacked_without_asking_the_hub() {
  start_hub command-fleet
  local endpoint out
  endpoint=$(start_real_agent guarded)
  out=$(commander "$(composer_command c-fleet "box-a/guarded-$RUN" "echo NOPE" "$endpoint" other-fleet)")
  assert_equals "$(printf '%s' "$out" | jq -r '.record')" command_nack \
    "a command for another fleet is a membership answer this adapter owns"
  assert_equals "$(printf '%s' "$out" | jq -r '.reason')" fleet_unknown \
    "and its reason names the fleet"
  out=$(commander "$(jq -nc --arg leaf "box-a/guarded-$RUN" --arg ex "$endpoint" \
    '{record: "command", command_id: "c-no-fleet",
      identity: {leaf_worker_id: $leaf, execution_id: $ex},
      payload: {kind: "steer", text: "echo NO-FLEET"}}')")
  assert_equals "$(printf '%s' "$out" | jq -r '.reason')" fleet_unknown \
    "a command with no fleet identity must also be nacked"
  assert_not_contains "$(curl -sS -m 30 -H "Authorization: Bearer $VIEW_TOKEN" \
    "$URL/v1/tasks/$endpoint/capture?lines=40" 2>/dev/null)" NOPE \
    "a command for another fleet must not reach any worker"
  assert_not_contains "$(curl -sS -m 30 -H "Authorization: Bearer $VIEW_TOKEN" \
    "$URL/v1/tasks/$endpoint/capture?lines=40" 2>/dev/null)" NO-FLEET \
    "a command missing its fleet must not reach any worker"
  pass "bridge: commands for another or missing fleet are nacked"
}

test_an_order_the_hub_cannot_settle_is_left_pending_rather_than_answered() {
  # The contract's reconciliation rule. An unacknowledged command id stays
  # visibly pending, so the one thing the adapter must NOT do here is emit a
  # record - an accepted one would be a fabrication, and a refused one would be
  # just as false.
  start_hub command-pending
  local endpoint agent out
  endpoint=$(start_real_agent frozen)
  agent=$(ps -eo pid,args 2>/dev/null \
    | awk -v l="--label frozen-$RUN" 'index($0, "fm-stream-agent.py") && index($0, l) && !index($0, "awk") {print $1; exit}')
  [ -n "$agent" ] || fail "the agent should be running"
  kill -STOP "$agent" || fail "could not pause the agent"
  out=$(printf '%s\n' "$(composer_command c-pending "box-a/frozen-$RUN" "echo MAYBE" "$endpoint")" \
    | python3 "$BRIDGE" command --hub "$URL" --token-file "$CASE_DIR/control-token" \
        --fleet-id test-fleet 2>/dev/null)
  kill -CONT "$agent" || fail "could not resume the agent"
  assert_equals "$out" "" \
    "an order the hub could not settle must produce no record at all"
  pass "bridge: an order the hub cannot settle is left pending rather than answered"
}

test_a_command_that_names_no_worker_is_left_pending_not_nacked() {
  # The id is addressable but the worker is not: a composer bug that drops
  # identity.leaf_worker_id is not evidence any worker ended, and a nack is a
  # membership verdict - so the id stays pending and the loss lands on stderr,
  # exactly like a record that carries no command_id.
  start_hub command-nameless
  local out err
  out=$(printf '%s\n' "$(jq -nc --arg id c-nameless \
      '{record: "command", command_id: $id, issued_at_utc: "2026-01-01T00:00:00Z",
        issued_by: "captain", identity: {fleet_id: "test-fleet"},
        payload: {kind: "steer", text: "echo NAMELESS"}}')" \
    | python3 "$BRIDGE" command --hub "$URL" --token-file "$CASE_DIR/control-token" \
        --fleet-id test-fleet 2> "$CASE_DIR/nameless.err")
  assert_equals "$out" "" \
    "a command that names no worker must produce no record, least of all a nack"
  assert_contains "$(cat "$CASE_DIR/nameless.err")" "c-nameless" \
    "the stuck command id should be named on stderr so it is not lost silently"
  pass "bridge: a command that names no worker stays pending rather than nacked"
}

test_compare_sets_rendered_states_against_crew_state() {
  local home feed stub out code
  home="$TMP_ROOT/compare-home"
  mkdir -p "$home/state"
  fm_write_meta "$home/state/t-live.meta" backend=stream \
    stream_endpoint_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  fm_write_meta "$home/state/t-exited.meta" backend=stream \
    stream_endpoint_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
  fm_write_meta "$home/state/t-conflict.meta" backend=stream \
    stream_endpoint_id=cccccccccccccccccccccccccccccccc
  fm_write_meta "$home/state/t-gone.meta" backend=stream \
    stream_endpoint_id=dddddddddddddddddddddddddddddddd
  fm_write_meta "$home/state/t-tmux.meta" backend=tmux window=firstmate:fm-t-tmux
  # The stand-in answers in fm-crew-state.sh's one-line shape, and records the
  # home it was asked about so the case can prove the harness passed it on.
  stub="$TMP_ROOT/crew-state-stub"
  cat > "$stub" <<'SH'
#!/bin/sh
printf '%s\n' "$FM_HOME" > "$FM_HOME/asked-home"
case "$1" in
  t-live) echo 'state: working · source: pane · busy' ;;
  t-exited) echo 'state: done · source: status-log · finished' ;;
  t-conflict) echo 'state: working · source: pane · busy' ;;
  t-gone) echo 'state: unknown · source: none · endpoint dead' ;;
  *) echo "unexpected task $1" >&2; exit 2 ;;
esac
SH
  chmod +x "$stub"
  feed="$TMP_ROOT/compare-feed.ndjson"
  jq -nc '{at_ms: 1, listing: {tasks: [
      {endpoint_id: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", machine: "m", label: "t-live", current_execution: true, closed_by: null, exit_code: null},
      {endpoint_id: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", machine: "m", label: "t-exited", current_execution: true, closed_by: "agent", exit_code: 0},
      {endpoint_id: "cccccccccccccccccccccccccccccccc", machine: "m", label: "t-conflict", current_execution: true, closed_by: "agent", exit_code: 1}]}}' \
    | python3 "$BRIDGE" translate > "$feed"
  out=$(python3 "$BRIDGE" compare --home "$home" --feed "$feed" --crew-state "$stub")
  code=$?
  assert_equals "$code" 1 "a conflict or a missing endpoint should fail the comparison"
  assert_equals "$(printf '%s\n' "$out" | awk -F'\t' 'NR > 1 {print $1 "=" $3 "/" $4 "/" $5 "/" $6}' | tr '\n' ' ')" \
    "t-conflict=Failed/working/pane/conflict t-exited=Stopped/done/status-log/consistent t-gone=-/unknown/none/missing t-live=Unknown/working/pane/no-verdict " \
    "each stream-backed task should get the verdict its pair supports"
  assert_equals "$(cat "$home/asked-home")" "$home" "crew state should be read against the compared home"
  rm -f "$home/state/t-conflict.meta" "$home/state/t-gone.meta"
  python3 "$BRIDGE" compare --home "$home" --feed "$feed" --crew-state "$stub" >/dev/null
  assert_equals "$?" 0 "a comparison with no conflict and nothing missing should pass"
  pass "bridge: the comparison harness sets rendered states against crew state"
}

test_recorded_traffic_replays_into_the_bridge_record_shape
test_only_an_agent_reported_exit_is_a_verdict
test_malformed_input_is_refused_or_left_out
test_a_relaunched_leaf_is_emitted_once_from_the_hubs_current_execution
test_a_snapshot_reads_the_real_hub
test_a_real_agents_worker_exit_reaches_the_bridge
test_serve_streams_ticks_and_goes_silent_without_the_hub
test_refusals_end_the_command
test_command_rebinds_to_the_active_hub_generation
test_a_composer_command_reaches_the_worker_and_is_acknowledged
test_a_duplicate_command_id_keeps_the_leaf_that_received_it
test_a_command_for_a_worker_its_agent_reported_gone_is_nacked
test_a_command_aimed_at_a_replaced_execution_is_refused_without_claiming_absence
test_a_command_without_a_valid_execution_is_refused
test_a_command_for_another_or_missing_fleet_is_nacked_without_asking_the_hub
test_an_order_the_hub_cannot_settle_is_left_pending_rather_than_answered
test_a_command_that_names_no_worker_is_left_pending_not_nacked
test_compare_sets_rendered_states_against_crew_state
