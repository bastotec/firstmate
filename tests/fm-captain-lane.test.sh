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
    f.write(json.dumps({'prompt': prompt}) + '\n')
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
  assert_contains "$(cat "$DIR/turns")" "was interrupted before its end was recorded" "the recovery turn must check the conversation first"
  [ "$(turns_with 'interrupted question')" = 1 ] || fail "the recovery turn ran more than once"
  [ "$(turns_with 'abandoned question')" = 0 ] || fail "a record already in recovery was run again"
  pass "fm-captain-lane: an interrupted turn gets one recovery turn, and never a second"
}

test_unacknowledged_answer_is_never_repeated
test_unwritable_answer_list_takes_no_turn
test_interrupted_turn_gets_one_recovery_turn
