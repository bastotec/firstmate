#!/usr/bin/env bash
# bin/fm-captain-lane.sh: a split second mate's captain thread.
# Hermetic (a fake deck): an answered record whose move to handled/ fails is
# never answered again, later records still go on, and the move is retried
# until it lands; a restarted lane keeps that promise.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-lane)
LANE="$ROOT/bin/fm-captain-lane.sh"

setup() {  # -> sets DIR
  DIR="$TMP_ROOT/case-$RANDOM"
  mkdir -p "$DIR/home" "$DIR/state" "$DIR/xdg/deck/sessions"
  cat > "$DIR/deck" <<'PY'
#!/usr/bin/env python3
import json, os, sys
prompt = sys.argv[2]
with open(os.environ['FAKE_TURNS'], 'a') as f:
    f.write(json.dumps({'prompt': prompt, 'args': sys.argv[3:]}) + '\n')
print(json.dumps({'type': 'run_started', 'session': 'cap'}))
print(json.dumps({'type': 'run_finished', 'turns': 1}))
PY
  chmod +x "$DIR/deck"
  : > "$DIR/xdg/deck/sessions/cap.json"
}

write_captain() {  # <text>
  bash -c '. "$1"; fm_task_inbox_write "$2" mate "$3" >/dev/null' _ "$ROOT/bin/fm-task-inbox-lib.sh" \
    "$DIR/state" $'[fm-captain-direct]⁣note\n\n'"$1"
}

record_body() {  # <record>
  bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$ROOT/bin/fm-task-inbox-lib.sh" "$1"
}

# The conversation speaks as one agent: what a lane turn tells the model to
# say, and every note generated for the conversation, never names a supervisor
# or a monologue (the [fm-supervisor-note] delivery tag aside).
assert_one_agent_voice() {  # <turn log>
  local said
  said=$(printf '%s' "$1" | python3 -c '
import json, re, sys
for line in sys.stdin:
    prompt = json.loads(line)["prompt"]
    for m in re.finditer(r"^([^\n]*) \(record [^)\n]*\):\n\n([^\n]*)", prompt, re.M):
        print(m.group(1))
        print(m.group(2).replace("[fm-supervisor-note]", ""))
')
  case "$(printf '%s' "$said" | tr '[:upper:]' '[:lower:]')" in
    *supervisor*|*monologue*|*"captain thread"*) fail "the conversation was told to name its supervisor or monologue: $said" ;;
  esac
}

write_record() {  # <stream|-> <text>: one inbox record as a sender delivers it
  FM_TASK_INBOX_STREAM=${1#-} bash -c '. "$1"; fm_task_inbox_write "$2" mate "$3" >/dev/null' _ \
    "$ROOT/bin/fm-task-inbox-lib.sh" "$DIR/state" "$2"
}

start_lane() {  # -> sets HOST (a parent that keeps the lane alive)
  bash -c 'FM_HOME="$1" XDG_STATE_HOME="$2" FAKE_TURNS="$3" "$4" --state "$5" --id mate --deck "$6" 2>>"$7" & wait' _ \
    "$DIR/home" "$DIR/xdg" "$DIR/turns" "$LANE" "$DIR/state" "$DIR/deck" "$DIR/lane.err" &
  HOST=$!
}

stop_lane() {
  pkill -TERM -P "$HOST" 2>/dev/null || true
  wait "$HOST" 2>/dev/null || true
}

turns_with() { local n; n=$(grep -c -F -- "$1" "$DIR/turns" 2>/dev/null) || n=0; printf '%s' "${n:-0}"; }
deck_gone() { ! pgrep -f "$DIR/deck" >/dev/null; }
answered_at_least() { [ "$(turns_with "$1")" -ge "$2" ]; }

wait_until() {  # <ticks> <command...>
  local n=$1 i=0
  shift
  while [ "$i" -lt "$n" ]; do "$@" && return 0; sleep 0.1; i=$((i + 1)); done
  return 1
}

test_unacknowledged_answer_is_never_repeated() {
  setup
  mkdir -p "$DIR/state/mate.inbox/handled"
  chmod 555 "$DIR/state/mate.inbox/handled"   # the move to handled/ fails
  write_captain 'first question'
  start_lane
  wait_until 100 answered_at_least 'first question' 1 || fail "the lane never answered the first record"
  write_captain 'second question'
  wait_until 100 answered_at_least 'second question' 1 || fail "an unacknowledged answer blocked a later record"
  stop_lane
  assert_contains "$(cat "$DIR/state/mate.captain-lane.answered")" "001.msg" "the answered record must be listed"
  start_lane
  sleep 2
  [ "$(turns_with 'first question')" = 1 ] || fail "a restarted lane answered the first record again"
  chmod 755 "$DIR/state/mate.inbox/handled"
  wait_until 100 test -f "$DIR/state/mate.inbox/handled/001.msg" || fail "the move was not retried once possible"
  wait_until 50 test ! -s "$DIR/state/mate.captain-lane.answered" || fail "an acknowledged record stayed listed"
  stop_lane
  [ "$(turns_with 'first question')" = 1 ] || fail "the first record was answered more than once"
  pass "fm-captain-lane: an answered record is never answered again, and its acknowledgement is retried"
}

test_unwritable_answer_list_takes_no_turn() {
  setup
  : > "$DIR/state/mate.captain-lane.answered"
  chmod 444 "$DIR/state/mate.captain-lane.answered"
  write_captain 'held question'
  start_lane
  sleep 3
  [ "$(turns_with 'held question')" = 0 ] || fail "a turn ran although its answer could not be recorded"
  chmod 644 "$DIR/state/mate.captain-lane.answered"
  wait_until 150 answered_at_least 'held question' 1 || fail "the lane did not resume once it could record"
  sleep 1
  stop_lane
  [ "$(turns_with 'held question')" = 1 ] || fail "the held question was answered more than once"
  pass "fm-captain-lane: no turn runs while its answer cannot be recorded"
}

test_interrupted_turn_gets_one_recovery_turn() {
  setup
  write_captain 'interrupted question'
  write_captain 'abandoned question'
  printf 'started 001.msg\nrecovering 002.msg\n' > "$DIR/state/mate.captain-lane.answered"
  start_lane
  wait_until 100 answered_at_least 'interrupted question' 1 || fail "the interrupted record got no recovery turn"
  sleep 2
  stop_lane
  assert_contains "$(cat "$DIR/turns")" "was interrupted or failed before its end was recorded" "the recovery turn must check the conversation first"
  [ "$(turns_with 'interrupted question')" = 1 ] || fail "the recovery turn ran more than once"
  [ "$(turns_with 'abandoned question')" = 0 ] || fail "a record already in recovery was run again"
  pass "fm-captain-lane: an interrupted turn gets one recovery turn, and never a second"
}

test_failed_turn_retries_with_the_conversation_check() {
  setup
  write_captain 'failed question'
  printf 'recovering 001.msg\nfailed 001.msg\n' > "$DIR/state/mate.captain-lane.answered"
  start_lane
  wait_until 100 answered_at_least 'failed question' 1 || fail "a failed record was not retried"
  stop_lane
  assert_contains "$(cat "$DIR/turns")" "was interrupted or failed before its end was recorded" "a retry must check the conversation first"
  pass "fm-captain-lane: a failed turn, recovery or not, retries with the conversation check"
}

test_host_exit_stops_a_running_captain_turn() {
  setup
  cat > "$DIR/deck" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
with open(os.environ['FAKE_TURNS'], 'a') as f:
    f.write(json.dumps({'prompt': sys.argv[2]}) + '\n')
print(json.dumps({'type': 'run_started', 'session': 'cap'}), flush=True)
time.sleep(60)
PY
  write_captain 'slow question'
  start_lane
  wait_until 100 answered_at_least 'slow question' 1 || fail "the lane never started the turn"
  kill -KILL "$HOST" 2>/dev/null || true
  wait "$HOST" 2>/dev/null || true
  wait_until 50 deck_gone || fail "the captain turn outlived its host"
  pass "fm-captain-lane: a host that goes away mid-turn takes the captain turn with it"
}

test_new_session_is_bound_while_its_turn_runs() {
  setup
  cat > "$DIR/deck" <<'PY'
#!/usr/bin/env python3
import json, os, sys, time
with open(os.environ['FAKE_TURNS'], 'a') as f:
    f.write(json.dumps({'prompt': sys.argv[2]}) + '\n')
print(json.dumps({'type': 'run_started', 'session': 'cap'}), flush=True)
time.sleep(60)
PY
  write_captain 'long question'
  start_lane
  wait_until 100 test -s "$DIR/state/mate.deck-session" || fail "the new session was not bound during its turn"
  assert_contains "$(head -n 1 "$DIR/state/mate.deck-session")" "cap" "the binding must name the opened session"
  stop_lane
  pass "fm-captain-lane: a new captain session is bound while its first turn still runs"
}

test_fresh_session_opt_out_replaces_the_binding() {
  setup
  : > "$DIR/xdg/deck/sessions/old.json"
  printf 'old\n%s\n' "$DIR/home" > "$DIR/state/mate.deck-session"
  write_captain 'fresh question'
  FM_DECK_FRESH_SESSION=1 start_lane
  wait_until 100 answered_at_least 'fresh question' 1 || fail "the lane never answered"
  wait_until 50 grep -q '^cap$' "$DIR/state/mate.deck-session" || fail "the fresh session did not replace the binding"
  write_captain 'next question'
  wait_until 100 answered_at_least 'next question' 1 || fail "the lane never answered the next record"
  stop_lane
  assert_not_contains "$(grep -F 'fresh question' "$DIR/turns")" '"old"' "a fresh lane must not resume the old session"
  assert_contains "$(grep -F 'next question' "$DIR/turns")" '"cap"' "later turns must keep the fresh session"
  pass "fm-captain-lane: FM_DECK_FRESH_SESSION=1 starts a new captain conversation and binds it"
}

test_conversation_takes_every_party_and_leaves_the_monologue() {
  setup
  write_record monologue 'automatic wake text'
  write_record conversation 'first mate question'
  write_record - $'[fm-from-mate:dave]\342\201\243corr=0123456789abcdef peer question'
  write_record conversation '[fm-supervisor-note] the PR merged'
  write_record - 'legacy untagged steer'
  start_lane
  wait_until 150 answered_at_least 'the PR merged' 1 || fail "the conversation did not take every party's record"
  sleep 1
  stop_lane
  turns=$(cat "$DIR/turns")
  assert_contains "$turns" "The first mate wrote to this second mate" "a first-mate record says who wrote"
  assert_contains "$turns" "Another mate, dave, wrote to this second mate" "a peer record names the mate"
  assert_contains "$turns" "Your own background work wrote this for the reader; say it as your own news, in the first person" "a supervisor note is said as the mate's own news"
  assert_one_agent_voice "$turns"
  [ "$(turns_with 'automatic wake text')" = 0 ] || fail "a monologue record reached the conversation"
  [ "$(turns_with 'legacy untagged steer')" = 0 ] || fail "an untagged legacy record reached the conversation"
  [ -f "$DIR/state/mate.inbox/001.msg" ] || fail "the monologue record must stay for the supervisor"
  pass "fm-captain-lane: the conversation takes the captain, first mate, peers and supervisor notes, never the monologue"
}

test_supervisor_note_reaches_the_conversation() {
  setup
  FM_HOME="$DIR/home" FM_SPLIT_MATE_STATE="$DIR/state" FM_SPLIT_MATE_ID=mate \
    "$ROOT/bin/fm-captain-note.sh" 'blocked on the API key' >/dev/null || fail "a mate's supervisor note was refused"
  start_lane
  wait_until 100 answered_at_least 'blocked on the API key' 1 || fail "the supervisor note never reached the conversation"
  stop_lane
  assert_contains "$(cat "$DIR/turns")" "[fm-supervisor-note] blocked on the API key" "the note reaches the conversation as written"
  pass "fm-captain-lane: a mate's supervisor posts to its conversation with fm-captain-note.sh"
}

test_handoff_names_its_sender() {
  setup
  handoff() { FM_CAPTAIN_LANE_STATE="$DIR/state" FM_CAPTAIN_LANE_ID=mate "$ROOT/bin/fm-captain-handoff.sh" "$@" >/dev/null; }
  FM_CONVERSATION_PARTY=mate:dave handoff 'merge the PR' || fail "a peer hand-off was refused"
  FM_CONVERSATION_PARTY=captain handoff --from mate:dave 'ship it' || fail "a captain hand-off was refused"
  handoff --from firstmate 'audit the docs' || fail "an explicit hand-off was refused"
  handoff 'no sender given' || fail "an unnamed hand-off was refused"
  bodies=$(for f in "$DIR/state/mate.inbox"/*.msg; do record_body "$f"; echo; done)
  assert_contains "$bodies" "From the mate dave: merge the PR" "a peer's order names the peer"
  assert_contains "$bodies" "From the captain: ship it" "the conversation turn's sender wins over --from"
  assert_contains "$bodies" "From the first mate: audit the docs" "--from names the sender"
  assert_contains "$bodies" "From an unstated sender: no sender given" "an unnamed hand-off is never the captain's"
  pass "fm-captain-handoff: every hand-off names who it came from"
}

test_handoff_reports_a_failing_supervisor() {
  local out count escalated told health_case
  setup
  for health_case in '1 0 no' '4 0 no' '4 1 yes' '1 missing no'; do
    read -r count escalated told <<EOF
$health_case
EOF
    printf 'since=2026-10-15T23:42:00Z\ncount=%s\nerror=model gateway request failed (HTTP 400)\n' "$count" \
      > "$DIR/state/mate.supervisor-failing"
    [ "$escalated" = missing ] || printf 'escalated=%s\n' "$escalated" >> "$DIR/state/mate.supervisor-failing"
    out=$(FM_CAPTAIN_LANE_STATE="$DIR/state" FM_CAPTAIN_LANE_ID=mate "$ROOT/bin/fm-captain-handoff.sh" --from captain 'ship it')
    assert_contains "$out" "supervisor=failing count=$count since=2026-10-15T23:42:00Z told=$told error=model gateway request failed (HTTP 400)" \
      "a hand-off distinguishes failed turns from a published notification"
  done
  rm -f "$DIR/state/mate.supervisor-failing"
  printf 'v1 gen=g1 seq=1 state=busy source=x event=turn-start ts=1\n' > "$DIR/state/mate.busy-state"
  out=$(FM_CAPTAIN_LANE_STATE="$DIR/state" FM_CAPTAIN_LANE_ID=mate "$ROOT/bin/fm-captain-handoff.sh" --from captain 'ship it')
  assert_contains "$out" "supervisor=busy" "a hand-off reports the supervisor's real state"
  pass "fm-captain-handoff: every hand-off reports the supervisor's real state"
}

test_stale_handoff_is_reported_in_the_conversation() {
  local rec rec2 route status background
  for route in fallback remote; do
    setup
    status="$DIR/state/mate.status"
    if [ "$route" = remote ]; then
      printf 'mate\n' > "$DIR/home/.fm-secondmate-home"
      printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$DIR/home/.fm-secondmate-parent"
      status="$DIR/home/state/parent-replies.status"
    fi
    background='failing since 2026-10-15T23:42:00Z: model gateway request failed (HTTP 400)'
    if [ "$route" = remote ]; then
      background=busy
      printf 'v1 gen=g1 seq=1 state=busy source=x event=turn-start ts=1\n' > "$DIR/state/mate.busy-state"
    else
      printf 'since=2026-10-15T23:42:00Z\ncount=4\nerror=model gateway request failed (HTTP 400)\nescalated=1\n' \
        > "$DIR/state/mate.supervisor-failing"
    fi
    rec=$(FM_CAPTAIN_LANE_STATE="$DIR/state" FM_CAPTAIN_LANE_ID=mate "$ROOT/bin/fm-captain-handoff.sh" --from captain 'dispatch the order' \
      | sed -n 's/^handed-over=//p')
    rec2=$(FM_CAPTAIN_LANE_STATE="$DIR/state" FM_CAPTAIN_LANE_ID=mate "$ROOT/bin/fm-captain-handoff.sh" --from captain 'dispatch another order' \
      | sed -n 's/^handed-over=//p')
    touch -t 202601010000 "$rec" "$rec2"
    FM_DECK_STATUS_IO="$ROOT/bin/fm-state-io.py" FM_HANDOFF_STALE_SECS=60 start_lane
    wait_until 150 answered_at_least "is overdue: I have not finished or acknowledged it" 2 || fail "a stale hand-off was never reported"
    wait_until 100 test -f "$DIR/state/mate.inbox/handled/004.msg" || fail "the overdue notes were not acknowledged"
    stop_lane
    assert_contains "$(cat "$DIR/turns")" "my background work is $background" \
      "the report says why it is stuck"
    assert_contains "$(cat "$status")" "blocked [key=handoff-overdue-mate]: mate has not picked up an order for 1 minutes (record $(basename "$rec")); its background work is $background" \
      "the overdue order reaches the first mate through $route"
    [ "$(grep -c 'blocked \[key=handoff-overdue-mate\]' "$status")" = 2 ] || fail "each overdue record needs one blocker"
    assert_one_agent_voice "$(cat "$DIR/turns")"

    mv "$rec" "$DIR/state/mate.inbox/handled/"
    write_captain 'check with one overdue order remaining'
    FM_DECK_STATUS_IO="$ROOT/bin/fm-state-io.py" FM_HANDOFF_STALE_SECS=60 start_lane
    wait_until 100 answered_at_least 'check with one overdue order remaining' 1 || fail "the restarted lane never checked the remaining hand-off"
    stop_lane
    [ "$(turns_with "is overdue: I have not finished or acknowledged it")" = 2 ] || fail "a stale hand-off must be reported once across restarts"
    [ "$(grep -c 'blocked \[key=handoff-overdue-mate\]' "$status")" = 2 ] || fail "a reported hand-off must not publish another blocker"
    assert_not_contains "$(cat "$status")" 'resolved [key=handoff-overdue-mate]' "one unacknowledged order keeps the blocker open"

    mv "$rec2" "$DIR/state/mate.inbox/handled/"
    FM_DECK_STATUS_IO="$ROOT/bin/fm-state-io.py" FM_HANDOFF_STALE_SECS=60 start_lane
    wait_until 100 grep -q 'resolved \[key=handoff-overdue-mate\]' "$status" || fail "acknowledging every overdue order did not resolve its blocker through $route"
    stop_lane
    [ ! -e "$DIR/state/mate.captain-lane.stale-noted" ] || fail "a resolved hand-off episode kept its reporting record"
    pass "fm-captain-lane: overdue hand-offs notify the conversation and first mate once, and resolve through $route"
  done
}

test_failing_conversation_is_reported_and_cleared() {
  setup
  cp "$DIR/deck" "$DIR/deck-ok"
  cat > "$DIR/deck" <<'PY'
#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_TURNS'], 'a') as f:
    f.write(json.dumps({'prompt': sys.argv[2]}) + '\n')
print(json.dumps({'type': 'run_started', 'session': 'cap'}), flush=True)
print(json.dumps({'type': 'run_failed', 'error': 'model gateway request failed (HTTP 400)'}), flush=True)
sys.exit(9)
PY
  write_captain 'are you there'
  FM_DECK_STATUS_IO="$ROOT/bin/fm-state-io.py" FM_DECK_FAIL_ESCALATE=1 start_lane
  wait_until 100 grep -q 'blocked \[key=conversation-failing-mate\]' "$DIR/state/mate.status" \
    || fail "a failing conversation was not reported to the first mate"
  assert_contains "$(cat "$DIR/state/mate.status")" "model gateway request failed (HTTP 400), since " "the report carries the error and since when"
  cp "$DIR/deck-ok" "$DIR/deck"
  wait_until 450 grep -q 'resolved \[key=conversation-failing-mate\]' "$DIR/state/mate.status" \
    || fail "an answering conversation did not clear its report"
  stop_lane
  pass "fm-captain-lane: a failing conversation is reported to the first mate with its error, and cleared once it answers"
}

test_relaunched_lane_resolves_the_open_blocker() {
  setup
  printf 'since=2026-10-16T10:00:00Z\ncount=3\nescalated=1\n' > "$DIR/state/mate.conversation-failing"
  write_captain 'still there?'
  FM_DECK_STATUS_IO="$ROOT/bin/fm-state-io.py" start_lane
  wait_until 100 grep -q 'resolved \[key=conversation-failing-mate\]' "$DIR/state/mate.status" \
    || fail "a relaunched lane did not resolve the blocker its predecessor raised"
  stop_lane
  assert_contains "$(cat "$DIR/state/mate.status")" "failing since 2026-10-16T10:00:00Z" "the resolution names its episode"
  [ ! -e "$DIR/state/mate.conversation-failing" ] || fail "a recovered lane keeps no failing record"
  pass "fm-captain-lane: a lane relaunched for failing resolves the blocker once it answers"
}

test_remote_lane_reports_through_its_parent_channel() {
  setup
  printf 'mate\n' > "$DIR/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$DIR/home/.fm-secondmate-parent"
  mkdir -p "$DIR/home/state"
  cat > "$DIR/deck" <<'PY'
#!/usr/bin/env python3
import json, os, sys
with open(os.environ['FAKE_TURNS'], 'a') as f:
    f.write(json.dumps({'prompt': sys.argv[2]}) + '\n')
print(json.dumps({'type': 'run_failed', 'error': 'model gateway request failed (HTTP 400)'}), flush=True)
sys.exit(9)
PY
  write_captain 'anyone?'
  FM_DECK_FAIL_ESCALATE=1 start_lane
  wait_until 100 grep -q 'blocked \[key=conversation-failing-mate\]' "$DIR/home/state/parent-replies.status" \
    || fail "a remote mate's lane failure must go to the mirrored parent channel"
  stop_lane
  pass "fm-captain-lane: a remote mate reports a failing conversation through its mirrored parent channel"
}

test_unacknowledged_answer_is_never_repeated
test_relaunched_lane_resolves_the_open_blocker
test_remote_lane_reports_through_its_parent_channel
test_failing_conversation_is_reported_and_cleared
test_handoff_reports_a_failing_supervisor
test_stale_handoff_is_reported_in_the_conversation
test_handoff_names_its_sender
test_supervisor_note_reaches_the_conversation
test_conversation_takes_every_party_and_leaves_the_monologue
test_new_session_is_bound_while_its_turn_runs
test_fresh_session_opt_out_replaces_the_binding
test_unwritable_answer_list_takes_no_turn
test_interrupted_turn_gets_one_recovery_turn
test_failed_turn_retries_with_the_conversation_check
test_host_exit_stops_a_running_captain_turn
