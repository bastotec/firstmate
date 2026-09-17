#!/usr/bin/env bash
# tests/fm-stream-hub.test.sh - lifecycle tests for the central stream hub
# (bin/fm-stream-hub.py), its agent (bin/fm-stream-agent.py), and the operator
# entry point (bin/fm-stream.sh).
#
# These run a REAL hub over a real loopback socket with real agents owning real
# pseudoterminals, because everything worth asserting here - that a late
# subscriber still sees context, that an input nobody acknowledged is refused,
# that a silent agent is never reported dead, that closing one endpoint leaves
# its sibling alone - is a property of the running system, not of any single
# function.
#
# Each case gets its own hub on an ephemeral port, so nothing depends on a fixed
# port being free and no case can see another's endpoints.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the stream hub)"; exit 0; }
command -v curl >/dev/null 2>&1 || { echo "skip: curl not found (required by the stream backend)"; exit 0; }
command -v jq >/dev/null 2>&1 || { echo "skip: jq not found (required by the stream backend)"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-stream-hub-tests)
HUB="$ROOT/bin/fm-stream-hub.py"
AGENT="$ROOT/bin/fm-stream-agent.py"
PUBLISH_TOKEN="pub-$$"
VIEW_TOKEN="view-$$"
# The bare line in the token file: subscribe alone, no control. This is the
# credential a fleet hands to someone who may watch and nothing else.
VIEW_ONLY_TOKEN="viewonly-$$"
API_CODE_FILE=""
CASE_DIR=""
URL=""
# Labels carry the pid of THIS run. An interrupted run leaves its agents
# behind - they outlive the hub they published to - and a fixed label would
# then let agent_pid_for resolve one of those leftovers, silencing a dead
# endpoint while the live publisher kept heartbeating. The partition case
# would fail claiming the agent it just killed was still fresh.
RUN=$$

cleanup_helpers() {
  fm_test_reap_helper_pids
}
trap 'cleanup_helpers; fm_test_cleanup' EXIT INT TERM

# start_hub <case-name> [extra hub args...] -> sets CASE_DIR URL
# Publishing, operating, and watching get SEPARATE tokens in every case, so a
# test that accidentally used the wrong one fails rather than passing on a
# credential that happened to hold the class it needed.
start_hub() {
  local name=$1
  shift
  local ready waited=0 host port pid
  cleanup_helpers
  CASE_DIR="$TMP_ROOT/$name"
  mkdir -p "$CASE_DIR/state" "$CASE_DIR/cwd"
  printf 'publish:%s\nsubscribe,control:%s\n%s\n' \
    "$PUBLISH_TOKEN" "$VIEW_TOKEN" "$VIEW_ONLY_TOKEN" > "$CASE_DIR/tokens"
  chmod 600 "$CASE_DIR/tokens"
  printf '%s\n' "$PUBLISH_TOKEN" > "$CASE_DIR/publish-token"
  chmod 600 "$CASE_DIR/publish-token"
  ready="$CASE_DIR/ready"
  python3 "$HUB" serve --bind 127.0.0.1 --port 0 \
    --token-file "$CASE_DIR/tokens" --ready-file "$ready" "$@" \
    > "$CASE_DIR/log" 2>&1 &
  pid=$!
  # Disowned so retiring the previous case's hub does not print a job-control
  # "Killed" notice into this suite's output.
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
  API_CODE_FILE="$CASE_DIR/http-code"
}

# api prints the response body and records the HTTP status in a FILE rather than
# a variable: almost every call site reads the body through a command
# substitution, and a status left in a shell variable never leaves that subshell.
api() {  # <token> <method> <path> [body] -> body
  local token=$1 method=$2 path=$3 body=${4:-} raw
  if [ -n "$body" ]; then
    raw=$(printf '%s' "$body" | curl -sS -m 30 -X "$method" \
      -H "Authorization: Bearer $token" -H 'Content-Type: application/json' \
      --data-binary @- -w '\n%{http_code}' "$URL$path" 2>/dev/null)
  else
    raw=$(curl -sS -m 30 -X "$method" -H "Authorization: Bearer $token" \
      -w '\n%{http_code}' "$URL$path" 2>/dev/null)
  fi
  printf '%s' "${raw##*$'\n'}" > "$API_CODE_FILE"
  printf '%s' "${raw%$'\n'*}"
}

view() { api "$VIEW_TOKEN" "$@"; }
view_only() { api "$VIEW_ONLY_TOKEN" "$@"; }
publish() { api "$PUBLISH_TOKEN" "$@"; }

api_code() {
  cat "$API_CODE_FILE" 2>/dev/null || printf 'none'
}

# start_agent <machine> <label> [status-path] -> endpoint id
# A real agent owning a real pty, exactly as a spawn would start it.
AGENT_SEQ=0
start_agent() {  # <machine> <label> [status-path]
  local machine=$1 label=$2 status=${3:-} ready log pid waited=0 got_machine endpoint
  AGENT_SEQ=$((AGENT_SEQ + 1))
  ready="$CASE_DIR/agent-$machine-$label-$AGENT_SEQ.ready"
  log="$CASE_DIR/agent-$machine-$label-$AGENT_SEQ.log"
  rm -f "$ready"
  mkdir -p "$CASE_DIR/cwd"
  python3 "$AGENT" serve --hub "$URL" --token-file "$CASE_DIR/publish-token" \
    --machine "$machine" --label "$label-$RUN" --cwd "$CASE_DIR/cwd" \
    --status-path "$status" --ready-file "$ready" --state-interval 1 --poll-secs 3 \
    > "$log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 150 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "agent did not register for $machine/$label: $(cat "$log" 2>/dev/null)"
  read -r got_machine endpoint < "$ready"
  printf '%s' "$endpoint"
}

# agent_pid_for <endpoint> - the pid of the agent publishing that endpoint, so a
# case can silence exactly one publisher without touching the others.
agent_pid_for() {  # <ready-file-machine> <label>
  local machine=$1 label=$2
  ps -eo pid,args 2>/dev/null \
    | awk -v m="--machine $machine" -v l="--label $label-$RUN" \
        'index($0, "fm-stream-agent.py") && index($0, m) && index($0, l) && !index($0, "awk") {print $1; exit}'
}

wait_for_capture() {  # <endpoint> <needle>
  local endpoint=$1 needle=$2 waited=0 out
  while [ "$waited" -lt 150 ]; do
    out=$(view GET "/v1/tasks/$endpoint/capture?lines=40")
    case "$out" in *"$needle"*) return 0 ;; esac
    sleep 0.1
    waited=$((waited + 1))
  done
  return 1
}

# wait_until_quiet <endpoint> - block until the hub reports it has not heard
# from that endpoint for longer than the window it waits before presuming an
# agent gone. Reading the fleet is what makes the hub notice, so the loop reads
# it rather than sleeping blind.
wait_until_quiet() {  # <endpoint>
  local endpoint=$1 waited=0 silent=""
  while [ "$waited" -lt 150 ]; do
    silent=$(printf '%s' "$(view GET /v1/tasks)" | jq -r --arg id "$endpoint" \
      '.tasks[] | select(.endpoint_id==$id) | .agent_silent_for_secs')
    [ "${silent%%.*}" -ge 11 ] 2>/dev/null && return 0
    sleep 0.2
    waited=$((waited + 1))
  done
  return 1
}

test_every_data_route_requires_a_token() {
  start_hub auth
  local raw
  raw=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$URL/v1/health" 2>/dev/null)
  assert_equals "$raw" 401 "health without a token should be refused"
  raw=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$URL/v1/tasks" 2>/dev/null)
  assert_equals "$raw" 401 "the fleet listing without a token should be refused"
  # The viewer page is the one exception, and it has to be: it is what reads
  # the token out of the URL fragment, which a browser never sends anywhere.
  # So this request is exactly what a browser makes - no Authorization header,
  # no query parameter - and it must return the page.
  raw=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' "$URL/ui" 2>/dev/null)
  assert_equals "$raw" 200 "a browser navigating to the viewer sends no credential and must get the page"
  assert_contains "$(curl -sS -m 10 "$URL/ui" 2>/dev/null)" "EventSource" \
    "the credential-free navigation should return the viewer itself"
  # Only that navigation. A credential-free POST or DELETE to the same path must
  # not reach the unauthenticated branch, so neither may answer with the page.
  local body
  for verb in POST DELETE; do
    body=$(curl -sS -m 10 -X "$verb" -H 'Content-Type: application/json' \
      --data-binary '{"text":"x"}' "$URL/ui" 2>/dev/null)
    assert_not_contains "$body" "EventSource" \
      "a credential-free $verb to the viewer path must not be answered with the page"
    assert_contains "$body" "no_such_route" \
      "a credential-free $verb to the viewer path should be refused as an unknown route"
  done
  view GET /v1/health >/dev/null
  assert_equals "$(api_code)" 200 "a configured viewing token should be accepted"
  pass "hub: every data route requires a bearer token, and only the viewer page does not"
}

test_a_viewing_token_cannot_register_an_endpoint_or_publish() {
  start_hub classes
  local endpoint payload
  endpoint=$(python3 -c 'import os; print(os.urandom(16).hex())')
  payload=$(jq -nc --arg id "$endpoint" '{endpoint_id: $id, machine: "box-a", label: "sneaky", cwd: "/tmp"}')
  view POST /v1/agent/endpoints "$payload" >/dev/null
  assert_equals "$(api_code)" 403 "a viewing credential must never register an endpoint"
  view POST /v1/agent/frames '{"machine":"box-a","frames":[]}' >/dev/null
  assert_equals "$(api_code)" 403 "a viewing credential must never publish frames"
  # And the separation runs both ways, so a publishing credential cannot be
  # used to read the fleet.
  publish GET /v1/tasks >/dev/null
  assert_equals "$(api_code)" 403 "a publishing credential should not read the fleet listing"
  publish POST /v1/agent/endpoints "$payload" >/dev/null
  assert_equals "$(api_code)" 201 "the publishing credential should register the endpoint"
  pass "hub: registering an endpoint needs the publish class, reading needs subscribe"
}

test_a_viewing_token_cannot_steer_or_close_a_worker() {
  # The other half of the split. A link handed to someone who may watch must
  # not let them type into a live terminal or kill the worker behind it, while
  # the operator's own credential still does both.
  start_hub steering
  local endpoint out
  endpoint=$(start_agent box-a steerable "$CASE_DIR/state/steerable.status")
  view_only GET "/v1/tasks/$endpoint/capture?lines=5" >/dev/null
  assert_equals "$(api_code)" 200 "a viewing credential should still read the terminal"
  view_only POST "/v1/tasks/$endpoint/input" '{"text":"echo NEVER-TYPED","submit":true}' >/dev/null
  assert_equals "$(api_code)" 403 "a viewing credential must never type into a worker"
  view_only POST "/v1/tasks/$endpoint/status" '{"state":"done","note":"not yours"}' >/dev/null
  assert_equals "$(api_code)" 403 "a viewing credential must never append to a task's record"
  view_only DELETE "/v1/tasks/$endpoint" >/dev/null
  assert_equals "$(api_code)" 403 "a viewing credential must never close a worker"
  # Nothing was delivered, not merely refused at the door.
  assert_not_contains "$(view GET "/v1/tasks/$endpoint/capture?lines=40")" NEVER-TYPED \
    "a refused input must never reach the pseudoterminal"
  # And the operating credential - subscribe plus control - does all three.
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo OPERATOR-TYPED","submit":true}' >/dev/null
  assert_equals "$(api_code)" 200 "an operating credential should type into a worker"
  wait_for_capture "$endpoint" OPERATOR-TYPED || fail "the operator's line never reached the endpoint"
  view POST "/v1/tasks/$endpoint/status" '{"state":"working","note":"steered"}' >/dev/null
  assert_equals "$(api_code)" 200 "an operating credential should append a status line"
  assert_grep 'working: steered' "$CASE_DIR/state/steerable.status" \
    "the operator's status line should reach the owning agent's record"
  assert_no_grep 'not yours' "$CASE_DIR/state/steerable.status" \
    "a refused status must never reach the record"
  # The viewer holds ONE kept-alive connection: its refused send box must not
  # leave the next poll on that connection parsing the refused request's body.
  local hostport=${URL#http://}
  assert_equals "$(python3 "$ROOT/tests/assets/stream-hub-keepalive-refusal.py" \
    "${hostport%%:*}" "${hostport##*:}" "$endpoint" "$VIEW_ONLY_TOKEN" "$VIEW_TOKEN" 2>&1)" clean \
    "a refused POST must leave the connection usable for the next request"
  out=$(view DELETE "/v1/tasks/$endpoint")
  assert_equals "$(api_code)" 200 "an operating credential should close a worker"
  assert_equals "$(printf '%s' "$out" | jq -r '.delivered')" true \
    "a kill the owning agent took should be reported as delivered"
  pass "hub: steering needs the control class, and a viewing token holds none of it"
}

test_the_screen_read_answers_with_the_live_screen_and_cursor() {
  # fm-send verifies a submit through this route: when it fails, the composer's
  # state answer degrades to "unknown" and every steer reports an unverifiable
  # delivery, so the route answering at all is the assertion that matters.
  start_hub screen
  local endpoint out
  endpoint=$(start_agent box-a onscreen)
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo SCREEN-MARKER-2210","submit":true}' >/dev/null
  wait_for_capture "$endpoint" SCREEN-MARKER-2210 || fail "the endpoint never printed the marker"
  out=$(view GET "/v1/tasks/$endpoint/screen")
  assert_equals "$(api_code)" 200 "the screen read should answer rather than fail: $out"
  assert_contains "$(printf '%s' "$out" | jq -r '.screen')" SCREEN-MARKER-2210 \
    "the screen should carry what the worker just printed"
  [ "$(printf '%s' "$out" | jq -r '.cursor_row')" -ge 0 ] 2>/dev/null \
    || fail "the screen read should report which row the cursor is on"
  pass "hub: the screen read answers with the live screen and its cursor row"
}

test_capture_stays_readable_while_frames_are_arriving() {
  # fm-peek polls capture every 100ms while the worker is talking, so the read
  # and the publish genuinely overlap on a threading server. Rendering the
  # screen without the endpoint's lock made that read fail intermittently with
  # a 500, which fm-peek reports as an unreadable endpoint for a worker that is
  # perfectly healthy. A quiet endpoint can never reach this, so this case
  # keeps frames arriving for the whole read loop.
  start_hub concurrent
  local endpoint out
  endpoint=$(python3 -c 'import os; print(os.urandom(16).hex())')
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$endpoint" \
    '{endpoint_id: $id, machine: "box-a", label: "chatty", cwd: "/tmp", rows: 40, cols: 200}')" >/dev/null
  assert_equals "$(api_code)" 201 "the chatty endpoint should register"
  out=$(python3 "$ROOT/tests/assets/stream-hub-concurrent-capture.py" \
    "$URL" "$endpoint" "$PUBLISH_TOKEN" "$VIEW_TOKEN")
  assert_equals "$out" clean "capture must stay readable while frames arrive: $out"
  pass "hub: capture answers a well-formed screen while frames are still arriving"
}

test_one_hub_lists_endpoints_from_several_machines() {
  start_hub fleet
  local a b out
  a=$(start_agent box-a worker-one)
  b=$(start_agent box-b worker-two)
  out=$(view GET /v1/tasks)
  assert_equals "$(api_code)" 200 "the fleet listing should be readable"
  # The whole point of the hub: one request, every machine.
  assert_equals "$(printf '%s' "$out" | jq -r '[.tasks[].machine] | sort | join(",")')" \
    "box-a,box-b" "one listing should carry endpoints from both machines"
  assert_equals "$(printf '%s' "$out" | jq -r --arg id "$a" '.tasks[] | select(.endpoint_id==$id) | .machine')" \
    box-a "the first endpoint should be attributed to its own machine"
  assert_equals "$(printf '%s' "$out" | jq -r --arg id "$b" '.tasks[] | select(.endpoint_id==$id) | .machine')" \
    box-b "the second endpoint should be attributed to its own machine"
  assert_equals "$(printf '%s' "$out" | jq -r '[.machines[].machine] | sort | join(",")')" \
    "box-a,box-b" "the listing should name every machine for grouping"
  pass "hub: one listing carries every machine's endpoints"
}

test_the_fleet_listing_answers_while_machines_are_joining() {
  # One listing across every machine is the whole point of the hub, and the
  # viewer polls it continuously. A machine joining while that listing is being
  # built must not turn the request into a 500 - which is the fleet view going
  # blank at the exact moment a new worker appears.
  start_hub listing
  local out
  out=$(python3 "$ROOT/tests/assets/stream-hub-listing-under-registration.py" \
    "$URL" "$PUBLISH_TOKEN" "$VIEW_TOKEN")
  assert_equals "$out" clean "the fleet listings must answer while machines register: $out"
  pass "hub: the fleet listing answers while new machines are joining"
}

test_input_reaches_the_endpoint_and_capture_reads_it_back() {
  start_hub input
  local endpoint out
  endpoint=$(start_agent box-a typer)
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo HUB-TYPED","submit":true}' >/dev/null
  assert_equals "$(api_code)" 200 "input acknowledged by the owning agent should be 200"
  wait_for_capture "$endpoint" HUB-TYPED || fail "the endpoint never ran the submitted line"
  out=$(view GET "/v1/tasks/$endpoint/capture?lines=40")
  assert_contains "$out" HUB-TYPED "capture should read back what was typed"
  pass "hub: input reaches the endpoint's pseudoterminal and capture reads it back"
}

test_input_with_no_agent_to_acknowledge_is_refused() {
  # The delivery guarantee. fm-send refuses a steer on this answer, so a
  # command that merely sat in a queue must never report success.
  start_hub no-ack --command-ack-secs 2
  local endpoint payload out
  endpoint=$(python3 -c 'import os; print(os.urandom(16).hex())')
  payload=$(jq -nc --arg id "$endpoint" '{endpoint_id: $id, machine: "ghost", label: "unattended", cwd: "/tmp"}')
  publish POST /v1/agent/endpoints "$payload" >/dev/null
  assert_equals "$(api_code)" 201 "the endpoint should register"
  out=$(view POST "/v1/tasks/$endpoint/input" '{"text":"echo never","submit":true}')
  assert_equals "$(api_code)" 504 "an input no agent acknowledged must be refused, not reported delivered"
  assert_contains "$out" "NOT delivered" "the refusal should say plainly that nothing was delivered"
  pass "hub: an input no agent acknowledged is refused rather than reported delivered"
}

test_state_reads_carry_their_age_and_withhold_a_stale_verdict() {
  start_hub freshness --state-max-age-secs 5
  local endpoint out
  endpoint=$(start_agent box-a fresh)
  out=$(view GET "/v1/tasks/$endpoint/processes")
  assert_equals "$(api_code)" 200 "a state read should answer"
  assert_equals "$(printf '%s' "$out" | jq -r '.stale')" false "a heartbeating agent should read fresh"
  assert_equals "$(printf '%s' "$out" | jq -r '.alive')" true "a fresh read should carry the verdict"
  [ "$(printf '%s' "$out" | jq -r '.state_age_secs')" != null ] \
    || fail "a state read should always report how old its evidence is"
  pass "hub: a fresh state read carries its age and its verdict"
}

test_a_silent_agent_is_unreadable_and_never_dead() {
  # The partition case. An unreachable agent and a dead worker look identical
  # from the hub, and only one of them authorizes recovery, so silence must
  # never produce a verdict at all.
  start_hub partition --state-max-age-secs 3
  local endpoint pid out waited=0
  endpoint=$(start_agent box-a partitioned)
  out=$(view GET "/v1/tasks/$endpoint/processes")
  assert_equals "$(printf '%s' "$out" | jq -r '.stale')" false "the endpoint should start out readable"
  pid=$(agent_pid_for box-a partitioned)
  [ -n "$pid" ] || fail "could not find the publishing agent to silence"
  fm_test_kill_foreign_pid "$pid" "silencing the publishing agent"
  while [ "$waited" -lt 100 ]; do
    out=$(view GET "/v1/tasks/$endpoint/processes")
    [ "$(printf '%s' "$out" | jq -r '.stale')" = true ] && break
    sleep 0.2
    waited=$((waited + 1))
  done
  assert_equals "$(printf '%s' "$out" | jq -r '.stale')" true "a silenced agent should read stale"
  assert_equals "$(printf '%s' "$out" | jq -r 'has("alive")')" false \
    "a stale read must carry NO verdict at all - silence is not evidence of death"
  # Either staleness reason is correct here - the publisher is gone, so its
  # last frame and its last contact age together. What must hold is that the
  # answer explains itself rather than going quiet.
  [ -n "$(printf '%s' "$out" | jq -r '.reason // empty')" ] \
    || fail "a stale answer should say why it cannot be acted on"
  pass "hub: a silent agent reads unreadable and is never reported dead"
}

test_the_stream_replays_the_ring_then_delivers_live_frames() {
  start_hub stream
  local endpoint decoded subscriber
  endpoint=$(start_agent box-a streamer)
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo BEFORE-SUBSCRIBE","submit":true}' >/dev/null
  wait_for_capture "$endpoint" BEFORE-SUBSCRIBE || fail "the endpoint never echoed the early marker"
  # A subscriber that arrives late must still see what it missed: that replay
  # is the whole reason the ring exists.
  curl -sS -N -m 6 -H "Authorization: Bearer $VIEW_TOKEN" \
    "$URL/v1/tasks/$endpoint/stream?replay=1" > "$CASE_DIR/sse" 2>/dev/null &
  subscriber=$!
  sleep 1
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo AFTER-SUBSCRIBE","submit":true}' >/dev/null
  # Wait for THIS subscriber by pid: the hub and every agent are background jobs
  # of this same shell, so a bare wait would block until one of them exits.
  wait "$subscriber" 2>/dev/null || true
  decoded=$(python3 -c '
import base64, json, sys
out = []
for line in open(sys.argv[1]):
    if line.startswith("data: "):
        record = json.loads(line[6:])
        if "b64" in record:
            out.append(base64.b64decode(record["b64"]))
sys.stdout.write(b"".join(out).decode("utf-8", "replace"))
' "$CASE_DIR/sse")
  assert_contains "$decoded" BEFORE-SUBSCRIBE "the stream should replay output produced before the subscriber attached"
  assert_contains "$decoded" AFTER-SUBSCRIBE "the stream should deliver output produced after the subscriber attached"
  # An EventSource cannot set a header, so the stream route - and only it -
  # takes the credential from the query. Everywhere else a steering credential
  # in a request line would land in proxy logs and browser history.
  local code
  code=$(curl -sS -N -m 3 -o /dev/null -w '%{http_code}' \
    "$URL/v1/tasks/$endpoint/stream?access_token=$VIEW_TOKEN" 2>/dev/null || true)
  assert_equals "$code" 200 "the stream route should accept the browser's query credential"
  code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' \
    "$URL/v1/tasks/$endpoint/capture?lines=5&access_token=$VIEW_TOKEN" 2>/dev/null)
  assert_equals "$code" 401 "a read route should refuse a credential spelled into the URL"
  code=$(curl -sS -m 10 -o /dev/null -w '%{http_code}' -X POST \
    -H 'Content-Type: application/json' --data-binary '{"text":"echo URL-TYPED","submit":true}' \
    "$URL/v1/tasks/$endpoint/input?access_token=$VIEW_TOKEN" 2>/dev/null)
  assert_equals "$code" 401 "steering must never be authorized by a credential in the URL"
  assert_not_contains "$(view GET "/v1/tasks/$endpoint/capture?lines=40")" URL-TYPED \
    "an input refused at the door must never reach the pseudoterminal"
  pass "hub: the event stream replays the ring, delivers live frames, and is the only route taking a query credential"
}

test_an_endpoint_runs_the_operators_own_shell_and_a_dead_one_is_refused() {
  # Workers live on machines the hub never chose, so the endpoint's shell is
  # whatever $SHELL is there - a macOS home defaults to zsh, which rejects
  # bash's rc-suppressing flags and exits at birth. Both halves matter: a
  # non-bash shell must actually work, and a shell that cannot start must be
  # refused at creation rather than recorded as a live endpoint.
  start_hub shell
  local other_shell ready endpoint out
  other_shell=""
  for candidate in /bin/dash /usr/bin/dash /bin/zsh /usr/bin/zsh /bin/sh; do
    [ -x "$candidate" ] || continue
    case "$("$candidate" -c 'echo $0' 2>/dev/null)" in *bash*) continue ;; esac
    other_shell=$candidate
    break
  done
  [ -n "$other_shell" ] || { pass "hub: no non-bash shell on this host to run the endpoint shell case"; return; }
  ready="$CASE_DIR/other-shell.ready"
  SHELL="$other_shell" python3 "$AGENT" serve --hub "$URL" \
    --token-file "$CASE_DIR/publish-token" --machine box-a --label othershell-$RUN \
    --cwd "$CASE_DIR/cwd" --ready-file "$ready" --state-interval 1 --poll-secs 3 \
    > "$CASE_DIR/other-shell.log" 2>&1 &
  local agent_pid=$!
  disown "$agent_pid" 2>/dev/null || true
  fm_test_track_helper_pid "$agent_pid"
  local waited=0
  while [ "$waited" -lt 150 ]; do
    [ -s "$ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$ready" ] || fail "an endpoint under $other_shell never registered: $(cat "$CASE_DIR/other-shell.log" 2>/dev/null)"
  read -r _ endpoint < "$ready"
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo OTHER-SHELL-ALIVE","submit":true}' >/dev/null
  assert_equals "$(api_code)" 200 "an endpoint under $other_shell should accept input"
  wait_for_capture "$endpoint" OTHER-SHELL-ALIVE \
    || fail "an endpoint under $other_shell never ran what was typed into it"

  # And a shell that genuinely cannot start is refused, rather than leaving a
  # registered endpoint behind that every later steer would address in vain.
  printf '#!/bin/sh\necho "cannot start here" >&2\nexit 3\n' > "$CASE_DIR/broken-shell"
  chmod +x "$CASE_DIR/broken-shell"
  out=$(SHELL="$CASE_DIR/broken-shell" python3 "$AGENT" serve --hub "$URL" \
    --token-file "$CASE_DIR/publish-token" --machine box-a --label brokenshell-$RUN \
    --cwd "$CASE_DIR/cwd" --ready-file "$CASE_DIR/broken.ready" 2>&1) \
    && fail "an endpoint whose shell died at birth should not report success"
  assert_contains "$out" "cannot start here" "the refusal should carry the shell's own error"
  [ -s "$CASE_DIR/broken.ready" ] && fail "a refused endpoint must never write a ready file"
  assert_equals "$(printf '%s' "$(view GET /v1/tasks)" | jq -r '[.tasks[] | select(.label | startswith("brokenshell"))] | length')" \
    0 "a shell that died at birth must leave no endpoint registered in the fleet"
  pass "hub: an endpoint runs the operator's own shell, and one that cannot start is refused"
}

test_the_status_channel_writes_on_the_owning_machine_only() {
  start_hub status
  local a b out
  a=$(start_agent box-a reporter "$CASE_DIR/state/a.status")
  b=$(start_agent box-b bystander "$CASE_DIR/state/b.status")
  out=$(view POST "/v1/tasks/$a/status" '{"state":"working","note":"through the hub"}')
  assert_equals "$(api_code)" 200 "the status channel should accept a known state: $out"
  assert_grep 'working: through the hub' "$CASE_DIR/state/a.status" \
    "the owning agent should append an ordinary status line to its own record"
  # The record belongs to one machine's home. A status routed to one endpoint
  # must never reach another machine's record.
  assert_absent "$CASE_DIR/state/b.status" \
    "a status for one endpoint must not write another machine's record"
  view POST "/v1/tasks/$a/status" '{"state":"bogus","note":"x"}' >/dev/null
  assert_equals "$(api_code)" 400 "a state outside firstmate's vocabulary should be refused"
  view POST "/v1/tasks/$b/status" '{"state":"done","note":"second machine"}' >/dev/null
  assert_equals "$(api_code)" 200 "the other endpoint's own status should still work"
  assert_grep 'done: second machine' "$CASE_DIR/state/b.status" \
    "each machine's agent writes its own record"
  pass "hub: the status return channel is written locally by the owning agent"
}

test_kill_closes_the_exact_endpoint_and_leaves_its_sibling() {
  start_hub kill
  local victim bystander out
  victim=$(start_agent box-a victim)
  bystander=$(start_agent box-a bystander)
  out=$(view DELETE "/v1/tasks/$victim")
  assert_equals "$(api_code)" 200 "the kill should be acknowledged by the owning agent: $out"
  assert_equals "$(printf '%s' "$out" | jq -r '.closed')" "$victim" \
    "the answer should name the exact endpoint that was closed"
  local waited=0
  while [ "$waited" -lt 100 ]; do
    out=$(view GET "/v1/tasks/$victim")
    [ "$(printf '%s' "$out" | jq -r '.task.closed_at')" != null ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ "$(printf '%s' "$out" | jq -r '.task.closed_at')" != null ] \
    || fail "the closed endpoint should be recorded as closed"
  out=$(view GET "/v1/tasks/$bystander/processes")
  assert_equals "$(printf '%s' "$out" | jq -r '.alive')" true \
    "closing one endpoint must not disturb another on the same machine"
  pass "hub: kill closes the exact endpoint and leaves its sibling running"
}

test_a_kill_closes_an_endpoint_whose_agent_never_answers() {
  # Lifecycle point four is killing the exact endpoint, and an endpoint whose
  # agent is gone is precisely when an operator reaches for it. Answering "the
  # agent did not acknowledge" and leaving the endpoint live kills nothing.
  start_hub deadkill --command-ack-secs 2
  local endpoint payload out
  endpoint=$(python3 -c 'import os; print(os.urandom(16).hex())')
  payload=$(jq -nc --arg id "$endpoint" \
    '{endpoint_id: $id, machine: "box-a", label: "abandoned", cwd: "/tmp"}')
  publish POST /v1/agent/endpoints "$payload" >/dev/null
  assert_equals "$(api_code)" 201 "the endpoint should register"
  out=$(view DELETE "/v1/tasks/$endpoint")
  assert_equals "$(api_code)" 200 "closing an endpoint with no agent behind it should answer"
  # It says what it actually did: the record is closed, the worker is not known
  # to have stopped.
  assert_equals "$(printf '%s' "$out" | jq -r '.delivered')" false \
    "a close the agent never acknowledged must not be reported as a delivered kill"
  out=$(view GET /v1/tasks)
  assert_equals "$(printf '%s' "$out" | jq -r --arg id "$endpoint" \
    '[.tasks[] | select(.endpoint_id==$id and (.closed_at | not))] | length')" \
    0 "the endpoint must be closed rather than left steerable"
  # The label is usable again: a record with no agent behind it is exactly what
  # the next attempt at that task has to be able to replace.
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$(python3 -c 'import os; print(os.urandom(16).hex())')" \
    '{endpoint_id: $id, machine: "box-a", label: "abandoned", cwd: "/tmp"}')" >/dev/null
  assert_equals "$(api_code)" 201 \
    "the next attempt at that task should register once the closed record is gone"
  pass "hub: a kill the agent never answers closes the record and says so"
}

test_a_worker_the_hub_has_not_heard_from_keeps_its_place() {
  # The hub hears from an agent on every frame, heartbeat and command poll, so
  # silence means it has not heard from that agent lately - not that the worker
  # stopped. A brief hiccup must not end a live stream, drop a worker from the
  # fleet listing, or refuse a steer, because the worker may be perfectly fine.
  start_hub silence
  local endpoint agent out waited=0 silent=""
  endpoint=$(start_agent box-a quiet)
  agent=$(agent_pid_for box-a quiet)
  [ -n "$agent" ] || fail "the agent should be running"
  # Silence the agent without touching its worker: the pty keeps running, the
  # hub simply stops hearing about it.
  kill -STOP "$agent" || fail "could not pause the agent"
  while [ "$waited" -lt 150 ]; do
    out=$(view GET /v1/tasks)
    silent=$(printf '%s' "$out" | jq -r --arg id "$endpoint" \
      '.tasks[] | select(.endpoint_id==$id) | .agent_silent_for_secs')
    [ "${silent%%.*}" -ge 11 ] 2>/dev/null && break
    sleep 0.2
    waited=$((waited + 1))
  done
  [ "${silent%%.*}" -ge 11 ] 2>/dev/null \
    || { kill -CONT "$agent"; fail "the hub never went that long without hearing from the agent: $silent"; }
  # Still listed, and still readable.
  assert_equals "$(printf '%s' "$out" | jq -r --arg id "$endpoint" \
    '[.tasks[] | select(.endpoint_id==$id and (.closed_at | not))] | length')" \
    1 "a worker the hub has not heard from must stay listed"
  view GET "/v1/tasks/$endpoint/capture?lines=5" >/dev/null
  assert_equals "$(api_code)" 200 "its transcript must stay readable"
  # And a steer still reaches it rather than being refused as closed. The agent
  # is let go first, because the steer is answered by the agent itself.
  kill -CONT "$agent" || fail "could not resume the agent"
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo STILL-STEERABLE","submit":true}' >/dev/null
  assert_equals "$(api_code)" 200 "it must still take a steer"
  wait_for_capture "$endpoint" STILL-STEERABLE \
    || fail "the steer should reach a worker that never stopped"
  pass "hub: a worker the hub has not heard from keeps its stream, its listing and its steering"
}

test_an_agent_that_speaks_again_takes_the_presumption_back() {
  # Freeing the name is the whole of the presumption, and it is undone the
  # moment the agent speaks: a later attempt at that task must not walk in on a
  # worker that turned out to be fine.
  start_hub revive
  local endpoint out waited=0 silent=""
  endpoint=$(python3 -c 'import os; print(os.urandom(16).hex())')
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$endpoint" \
    '{endpoint_id: $id, machine: "box-a", label: "returning", cwd: "/tmp"}')" >/dev/null
  assert_equals "$(api_code)" 201 "the endpoint should register"
  # Nothing publishes for it, and the fleet is read meanwhile, so the hub
  # reaches its own conclusion about it rather than being told.
  while [ "$waited" -lt 150 ]; do
    out=$(view GET /v1/tasks)
    [ "$(printf '%s' "$out" | jq -r --arg id "$endpoint" \
      '[.tasks[] | select(.endpoint_id==$id)] | length')" = 1 ] || fail "the endpoint vanished"
    silent=$(printf '%s' "$out" | jq -r --arg id "$endpoint" \
      '.tasks[] | select(.endpoint_id==$id) | .agent_silent_for_secs')
    case "$silent" in
      ''|null) ;;
      *) [ "${silent%%.*}" -ge 11 ] 2>/dev/null && break ;;
    esac
    sleep 0.2
    waited=$((waited + 1))
  done
  [ "${silent%%.*}" -ge 11 ] 2>/dev/null || fail "the endpoint never went quiet long enough: $silent"
  # The agent speaks, the way it does after an outage.
  publish POST /v1/agent/frames "$(jq -nc --arg id "$endpoint" \
    '{machine: "box-a", frames: [{endpoint_id: $id, b64: "aGVsbG8K"}]}')" >/dev/null
  assert_equals "$(api_code)" 200 "a returning agent should be allowed to publish"
  # Its name is its own again: the next attempt at that task is refused.
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$(python3 -c 'import os; print(os.urandom(16).hex())')" \
    '{endpoint_id: $id, machine: "box-a", label: "returning", cwd: "/tmp"}')" >/dev/null
  assert_equals "$(api_code)" 409 \
    "an endpoint whose agent has just spoken must hold its label again"
  assert_contains "$(view GET "/v1/tasks/$endpoint/capture?lines=5")" hello \
    "the endpoint should read back what its agent published"
  pass "hub: an agent that speaks again takes the presumption back"
}

test_a_returning_agent_whose_name_was_taken_is_refused() {
  # The one case with no way back. While this agent was out of touch the next
  # attempt at its task claimed the same machine and label, so letting it
  # publish would put two workers behind one identity - the outcome that is
  # worse than any lost endpoint.
  start_hub superseded
  local first second out waited=0
  first=$(python3 -c 'import os; print(os.urandom(16).hex())')
  second=$(python3 -c 'import os; print(os.urandom(16).hex())')
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$first" \
    '{endpoint_id: $id, machine: "box-a", label: "contested", cwd: "/tmp"}')" >/dev/null
  assert_equals "$(api_code)" 201 "the first endpoint should register"
  local silent=""
  while [ "$waited" -lt 150 ]; do
    out=$(view GET /v1/tasks)
    silent=$(printf '%s' "$out" | jq -r --arg id "$first" \
      '.tasks[] | select(.endpoint_id==$id) | .agent_silent_for_secs')
    [ "${silent%%.*}" -ge 11 ] 2>/dev/null && break
    sleep 0.2
    waited=$((waited + 1))
  done
  [ "${silent%%.*}" -ge 11 ] 2>/dev/null \
    || fail "the hub never went that long without hearing from the first agent: $silent"
  # The name is free for the next attempt at that task, which is the whole of
  # what the presumption does.
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$second" \
    '{endpoint_id: $id, machine: "box-a", label: "contested", cwd: "/tmp"}')" >/dev/null
  assert_equals "$(api_code)" 201 "the next attempt should claim the free label"
  # Its agent speaks, which is what makes it a worker the hub has heard from
  # rather than a record that merely exists.
  publish POST /v1/agent/frames "$(jq -nc --arg id "$second" \
    '{machine: "box-a", frames: [{endpoint_id: $id, b64: "aGVsbG8K"}]}')" >/dev/null
  assert_equals "$(api_code)" 200 "the endpoint holding the name should be publishing"
  out=$(publish POST /v1/agent/frames "$(jq -nc --arg id "$first" \
    '{machine: "box-a", frames: [{endpoint_id: $id, b64: "aGVsbG8K"}]}')")
  assert_equals "$(api_code)" 410 "the superseded agent must not be allowed to publish"
  assert_equals "$(printf '%s' "$out" | jq -r '.error')" endpoint_superseded \
    "the refusal should tell that agent its name is served by another endpoint"
  assert_equals "$(printf '%s' "$(view GET /v1/tasks)" | jq -r --arg id "$second" \
    '[.tasks[] | select(.endpoint_id==$id and (.closed_at | not))] | length')" \
    1 "the endpoint that holds the name should be the one still serving it"
  pass "hub: a returning agent whose name was taken is refused rather than revived"
}

test_a_name_contest_is_settled_by_which_agent_is_heard_from() {
  # Two records, one name, and nothing heard from either - the shape a paused
  # hub leaves behind. The name belongs to whichever agent comes back, because
  # a record the hub has not heard from stands for no worker at all.
  start_hub contest
  local first second out
  first=$(python3 -c 'import os; print(os.urandom(16).hex())')
  second=$(python3 -c 'import os; print(os.urandom(16).hex())')
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$first" \
    '{endpoint_id: $id, machine: "box-a", label: "contested", cwd: "/tmp"}')" >/dev/null
  assert_equals "$(api_code)" 201 "the first endpoint should register"
  wait_until_quiet "$first" || fail "the first endpoint never went quiet"
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$second" \
    '{endpoint_id: $id, machine: "box-a", label: "contested", cwd: "/tmp"}')" >/dev/null
  assert_equals "$(api_code)" 201 "the next attempt should claim the free label"
  wait_until_quiet "$second" || fail "the second endpoint never went quiet"
  # The first agent speaks. Nothing has been heard from the second, so it holds
  # no name to take, and the one that is here keeps it.
  publish POST /v1/agent/frames "$(jq -nc --arg id "$first" \
    '{machine: "box-a", frames: [{endpoint_id: $id, b64: "aGVsbG8K"}]}')" >/dev/null
  assert_equals "$(api_code)" 200 "the agent that came back should keep the name"
  # The second one is the loser now, and is told so rather than allowed to
  # publish into a fleet where its name means someone else.
  out=$(publish POST /v1/agent/frames "$(jq -nc --arg id "$second" \
    '{machine: "box-a", frames: [{endpoint_id: $id, b64: "aGVsbG8K"}]}')")
  assert_equals "$(api_code)" 410 "the loser must not publish under a name another agent holds"
  assert_equals "$(printf '%s' "$out" | jq -r '.error')" endpoint_superseded \
    "the losing agent should be told its name is served by another endpoint"
  pass "hub: a name contest is settled by which agent the hub has heard from"
}

test_a_publishing_worker_keeps_its_name_against_an_empty_record() {
  # The dangerous shape: a healthy worker loses contact briefly, the retry for
  # its task registers a second record under the same name, and THAT record is
  # the one with nothing behind it - registered moments ago and never heard
  # from since. The worker that is actually publishing must keep the name, and
  # whatever the contest decides, it must keep its worker.
  start_hub liveness
  local endpoint agent empty out
  endpoint=$(start_agent box-a holder)
  agent=$(agent_pid_for box-a holder)
  [ -n "$agent" ] || fail "the agent should be running"
  kill -STOP "$agent" || fail "could not pause the agent"
  wait_until_quiet "$endpoint" || { kill -CONT "$agent"; fail "the hub kept hearing from the paused agent"; }
  # The retry registers under the same name, then never says another word.
  empty=$(python3 -c 'import os; print(os.urandom(16).hex())')
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$empty" --arg l "holder-$RUN" \
    '{endpoint_id: $id, machine: "box-a", label: $l, cwd: "/tmp"}')" >/dev/null
  assert_equals "$(api_code)" 201 "the retry should claim the freed name"
  # The real worker's agent comes back WHILE that record is still fresh - well
  # inside the window before the hub would presume anything about it. Freshness
  # is not reachability: nothing has ever been heard from it, and a record like
  # that takes no name from a worker that is publishing.
  kill -CONT "$agent" || fail "could not resume the agent"
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo STILL-MINE","submit":true}' >/dev/null
  assert_equals "$(api_code)" 200 "the publishing worker should still take a steer"
  wait_for_capture "$endpoint" STILL-MINE \
    || fail "the worker that holds the name should still be running its own pty"
  assert_equals "$(printf '%s' "$(view GET /v1/tasks)" | jq -r --arg id "$endpoint" \
    '[.tasks[] | select(.endpoint_id==$id and (.closed_at | not))] | length')" \
    1 "the publishing worker should still be listed"
  # Now the mirror of that exchange, which is where two workers behind one
  # identity used to become permanent: the record that never spoke speaks for
  # the FIRST time, with the worker it shares a name with live and publishing.
  # It loses the same contest, decided by the same rule, and the name still has
  # exactly one worker behind it.
  out=$(publish POST /v1/agent/frames "$(jq -nc --arg id "$empty" \
    '{machine: "box-a", frames: [{endpoint_id: $id, b64: "aGVsbG8K"}]}')")
  assert_equals "$(api_code)" 410 \
    "a record speaking for the first time must not publish under a live worker's name"
  assert_equals "$(printf '%s' "$out" | jq -r '.error')" endpoint_superseded \
    "it should be told the name is served by another endpoint"
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$(python3 -c 'import os; print(os.urandom(16).hex())')" \
    --arg l "holder-$RUN" '{endpoint_id: $id, machine: "box-a", label: $l, cwd: "/tmp"}')" >/dev/null
  assert_equals "$(api_code)" 409 \
    "the name should still be held by the worker that won it"
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo STILL-MINE-AFTER","submit":true}' >/dev/null
  assert_equals "$(api_code)" 200 "the winning worker should keep taking steers"
  wait_for_capture "$endpoint" STILL-MINE-AFTER \
    || fail "the worker that won the contest should still own its pty"
  pass "hub: a publishing worker keeps its name against a record nothing stands behind"
}

test_a_worker_that_loses_its_name_keeps_its_worker() {
  # The other ordering, with a real worker on each side: the newer record is
  # the one that has been heard from, and the older agent comes back to find
  # its name taken. The same rule decides it - the name goes to the agent most
  # recently proven reachable - and the agent that loses stands down without
  # taking its pty with it.
  start_hub mirror
  local first second first_agent out waited=0
  first=$(start_agent box-a rival)
  first_agent=$(agent_pid_for box-a rival)
  [ -n "$first_agent" ] || fail "the first agent should be running"
  kill -STOP "$first_agent" || fail "could not pause the first agent"
  wait_until_quiet "$first" || { kill -CONT "$first_agent"; fail "the hub kept hearing from the paused agent"; }
  # The retry for that task brings up a real worker under the same name, and
  # its agent is heard from at once.
  second=$(start_agent box-a rival)
  [ "$second" != "$first" ] || fail "the retry should be a new endpoint"
  kill -CONT "$first_agent" || fail "could not resume the first agent"
  # The returning agent is refused rather than allowed to publish into a fleet
  # where its name means someone else.
  out=$(publish POST /v1/agent/frames "$(jq -nc --arg id "$first" \
    '{machine: "box-a", frames: [{endpoint_id: $id, b64: "aGVsbG8K"}]}')")
  assert_equals "$(api_code)" 410 "the returning agent must not publish under the taken name"
  assert_equals "$(printf '%s' "$out" | jq -r '.error')" endpoint_superseded \
    "it should be told the name is served by another endpoint"
  # Exactly one worker answers to the name, and it is the one that was heard
  # from: it publishes and it steers.
  view POST "/v1/tasks/$second/input" '{"text":"echo NAME-IS-MINE","submit":true}' >/dev/null
  assert_equals "$(api_code)" 200 "the worker that holds the name should take a steer"
  wait_for_capture "$second" NAME-IS-MINE \
    || fail "the worker that holds the name should be running its own pty"
  publish POST /v1/agent/endpoints "$(jq -nc --arg id "$(python3 -c 'import os; print(os.urandom(16).hex())')" \
    --arg l "rival-$RUN" '{endpoint_id: $id, machine: "box-a", label: $l, cwd: "/tmp"}')" >/dev/null
  assert_equals "$(api_code)" 409 "no third record should be able to claim the held name"
  # And the loser's worker is untouched: its agent is still alive and still has
  # its pty child, because standing down is not killing.
  while [ "$waited" -lt 50 ]; do
    kill -0 "$first_agent" 2>/dev/null || break
    [ -n "$(pgrep -P "$first_agent" 2>/dev/null)" ] || break
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$first_agent" 2>/dev/null || fail "the losing agent should stand down, not exit"
  [ -n "$(pgrep -P "$first_agent" 2>/dev/null)" ] \
    || fail "the losing agent should keep its worker rather than close its pty"
  pass "hub: the agent that loses a name contest stands down and keeps its worker"
}

test_no_terminal_content_is_persisted_to_disk() {
  start_hub persistence
  local endpoint hits
  endpoint=$(start_agent box-a secretive)
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo SENSITIVE-MARKER-9137","submit":true}' >/dev/null
  wait_for_capture "$endpoint" SENSITIVE-MARKER-9137 || fail "the endpoint never printed the marker"
  # The hub's only files are its ready and pid files; terminal content lives in
  # a bounded in-memory ring and must not reach disk anywhere under its state.
  hits=$(grep -rl SENSITIVE-MARKER-9137 "$CASE_DIR" 2>/dev/null | grep -cv '/agent-.*\.log$')
  assert_equals "$hits" 0 "terminal content must not be written to disk by the hub"
  pass "hub: terminal content is never persisted outside the in-memory ring"
}

test_malformed_and_unknown_requests_are_refused() {
  start_hub malformed
  local endpoint
  endpoint=$(start_agent box-a picky)
  view POST "/v1/tasks/$endpoint/input" '{not json' >/dev/null
  assert_equals "$(api_code)" 400 "a malformed body should be refused"
  view POST "/v1/tasks/$endpoint/input" '{}' >/dev/null
  assert_equals "$(api_code)" 400 "an input carrying neither text nor keys should be refused"
  view GET /v1/nonsense >/dev/null
  assert_equals "$(api_code)" 404 "an unknown route should be 404"
  view GET /v1/tasks/0000000000000000000000000000dead >/dev/null
  assert_equals "$(api_code)" 404 "an unknown endpoint should be 404"
  view GET /v1/tasks/not-hex/capture >/dev/null
  assert_equals "$(api_code)" 404 "a malformed endpoint id should be 404"
  pass "hub: malformed bodies and unknown routes are refused without acting"
}

test_the_viewer_is_static_and_carries_no_terminal_content() {
  start_hub ui
  local endpoint page
  endpoint=$(start_agent box-a onstage)
  view POST "/v1/tasks/$endpoint/input" '{"text":"echo UI-LEAK-CHECK-4471","submit":true}' >/dev/null
  wait_for_capture "$endpoint" UI-LEAK-CHECK-4471 || fail "the endpoint never printed the marker"
  # Fetched the way a browser navigates: no Authorization header and no query
  # parameter, because the token lives in the fragment this page itself reads.
  page=$(curl -sS -m 10 -w '\n%{http_code}' "$URL/ui" 2>/dev/null)
  assert_equals "${page##*$'\n'}" 200 "the viewer must load for an unauthenticated browser navigation"
  page=${page%$'\n'*}
  assert_not_contains "$page" UI-LEAK-CHECK-4471 "the viewer must not bake in terminal content"
  assert_not_contains "$page" "$endpoint" "the viewer must not bake in an endpoint id"
  assert_contains "$page" "EventSource" "the viewer should subscribe over the event stream"
  pass "hub: the subscriber view is static and carries no terminal content"
}

test_the_viewer_renders_a_character_split_across_two_frames() {
  # Frames are raw pty chunks, so a multi-byte character straddling a frame
  # boundary is ordinary. A viewer that decoded each frame on its own dropped
  # both frames silently - the operator saw a gap and no error, which is the
  # opposite of the live view this exists to give.
  command -v node >/dev/null 2>&1 || { pass "hub: no node on this host to drive the viewer's decode"; return; }
  start_hub uidecode
  local page rendered first second
  page="$CASE_DIR/viewer.html"
  curl -sS -m 10 "$URL/ui" > "$page" 2>/dev/null
  [ -s "$page" ] || fail "the viewer page did not load"
  # "x" then U+2500 split down the middle: the first frame ends mid-character.
  first=$(printf 'x\342\224' | base64 | tr -d '\n')
  second=$(printf '\200 ok\n' | base64 | tr -d '\n')
  rendered=$(node "$ROOT/tests/assets/stream-viewer-harness.mjs" "$page" frames "$first" "$second") \
    || fail "the viewer harness failed: $rendered"
  assert_equals "$rendered" "$(printf 'x\342\224\200 ok\n')" \
    "the viewer should render the character that straddles the frame boundary"
  pass "hub: the viewer renders a character split across two frames"
}

test_the_viewer_reports_a_refused_transcript_rather_than_painting_it() {
  # A worker can be reaped inside the list's refresh window, so clicking it
  # answers 404. That refusal is not something the worker printed, and showing
  # its body in the terminal pane reads exactly as if it were.
  command -v node >/dev/null 2>&1 || { pass "hub: no node on this host to drive the viewer's refusal path"; return; }
  start_hub uirefusal
  local page pane
  page="$CASE_DIR/viewer.html"
  curl -sS -m 10 "$URL/ui" > "$page" 2>/dev/null
  [ -s "$page" ] || fail "the viewer page did not load"
  pane=$(node "$ROOT/tests/assets/stream-viewer-harness.mjs" "$page" capture-refused) \
    || fail "the viewer harness failed: $pane"
  assert_not_contains "$pane" '"ok": false' \
    "a refused transcript must not be painted into the terminal pane"
  assert_contains "$pane" "could not be read" \
    "a refused transcript should be reported as the refusal it is"
  pass "hub: the viewer reports a refused transcript instead of painting it as output"
}

test_the_viewer_keeps_the_send_box_disabled_for_a_closed_worker() {
  # A send in flight for one worker must not re-enable the box after the
  # operator has moved to a closed one: an enabled box under "This worker has
  # closed" is the view contradicting itself.
  command -v node >/dev/null 2>&1 || { pass "hub: no node on this host to drive the viewer's send box"; return; }
  start_hub uisendbox
  local page state
  page="$CASE_DIR/viewer.html"
  curl -sS -m 10 "$URL/ui" > "$page" 2>/dev/null
  [ -s "$page" ] || fail "the viewer page did not load"
  state=$(node "$ROOT/tests/assets/stream-viewer-harness.mjs" "$page" send-then-switch) \
    || fail "the viewer harness failed: $state"
  assert_equals "$state" "send box disabled" \
    "a send that resolves after the operator picked a closed worker must not re-enable the box"
  # Same contradiction from the other side: the worker the send was typed into
  # is the one that closes, and the operator is still looking at it.
  state=$(node "$ROOT/tests/assets/stream-viewer-harness.mjs" "$page" send-then-reselect) \
    || fail "the viewer harness failed: $state"
  assert_equals "$state" "send box disabled" \
    "a send that resolves after its own worker closed must not re-enable the box"
  pass "hub: a resolved send never re-enables the box for a closed worker"
}

test_fm_stream_start_status_stop_round_trip() {
  # The operator path, through the real entry point rather than the API.
  local home out
  home="$TMP_ROOT/operator"
  mkdir -p "$home/config" "$home/state"
  printf 'publish,subscribe,control:%s\n' "$PUBLISH_TOKEN" > "$home/config/stream-hub-tokens"
  chmod 600 "$home/config/stream-hub-tokens"
  printf '%s\n' "$PUBLISH_TOKEN" > "$home/config/stream-token"
  chmod 600 "$home/config/stream-token"
  local port
  port=$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')
  printf 'http://127.0.0.1:%s\n' "$port" > "$home/config/stream-hub"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-stream.sh" hub start --port "$port" 2>&1) \
    || fail "fm-stream.sh hub start failed: $out"
  assert_contains "$out" "hub listening" "starting the hub should report where it listens"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-stream.sh" status 2>&1)
  assert_contains "$out" "protocol 2" "status should report the reachable hub's protocol"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-stream.sh" web 2>&1)
  assert_contains "$out" "/ui#" "the web URL should carry the token in the fragment"
  # The fragment is the point: a token after '#' never reaches the server.
  assert_not_contains "$out" "access_token=" "the web URL must not put the token in the query"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-stream.sh" hub stop 2>&1) \
    || fail "fm-stream.sh hub stop failed: $out"
  assert_contains "$out" "hub stopped" "stopping should confirm the hub is down"
  pass "fm-stream.sh: hub start, status, web, and stop round-trip against a real hub"
}

test_fm_stream_refuses_a_second_hub_for_one_home() {
  local home out port
  home="$TMP_ROOT/operator-single"
  mkdir -p "$home/config" "$home/state"
  printf '%s\n' "$PUBLISH_TOKEN" > "$home/config/stream-token"
  chmod 600 "$home/config/stream-token"
  port=$(python3 -c '
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()')
  printf 'http://127.0.0.1:%s\n' "$port" > "$home/config/stream-hub"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-stream.sh" hub start --port "$port" >/dev/null 2>&1 \
    || fail "the first hub should start"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-stream.sh" hub start --port "$port" 2>&1) \
    && fail "a second hub for the same home should be refused"
  assert_contains "$out" "already running" "the refusal should say a hub is already running"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$home/config" \
    FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-stream.sh" hub stop >/dev/null 2>&1 || true
  pass "fm-stream.sh: a second hub for the same home is refused rather than started"
}

test_every_data_route_requires_a_token
test_a_viewing_token_cannot_register_an_endpoint_or_publish
test_a_viewing_token_cannot_steer_or_close_a_worker
test_the_screen_read_answers_with_the_live_screen_and_cursor
test_capture_stays_readable_while_frames_are_arriving
test_one_hub_lists_endpoints_from_several_machines
test_the_fleet_listing_answers_while_machines_are_joining
test_input_reaches_the_endpoint_and_capture_reads_it_back
test_input_with_no_agent_to_acknowledge_is_refused
test_state_reads_carry_their_age_and_withhold_a_stale_verdict
test_a_silent_agent_is_unreadable_and_never_dead
test_the_stream_replays_the_ring_then_delivers_live_frames
test_an_endpoint_runs_the_operators_own_shell_and_a_dead_one_is_refused
test_the_status_channel_writes_on_the_owning_machine_only
test_kill_closes_the_exact_endpoint_and_leaves_its_sibling
test_a_kill_closes_an_endpoint_whose_agent_never_answers
test_a_worker_the_hub_has_not_heard_from_keeps_its_place
test_an_agent_that_speaks_again_takes_the_presumption_back
test_a_returning_agent_whose_name_was_taken_is_refused
test_a_name_contest_is_settled_by_which_agent_is_heard_from
test_a_publishing_worker_keeps_its_name_against_an_empty_record
test_a_worker_that_loses_its_name_keeps_its_worker
test_no_terminal_content_is_persisted_to_disk
test_malformed_and_unknown_requests_are_refused
test_the_viewer_is_static_and_carries_no_terminal_content
test_the_viewer_renders_a_character_split_across_two_frames
test_the_viewer_reports_a_refused_transcript_rather_than_painting_it
test_the_viewer_keeps_the_send_box_disabled_for_a_closed_worker
test_fm_stream_start_status_stop_round_trip
test_fm_stream_refuses_a_second_hub_for_one_home
