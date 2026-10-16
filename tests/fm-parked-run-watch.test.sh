#!/usr/bin/env bash
# bin/fm-parked-run-watch.sh: a worker run parked at a review gate is nudged to
# its own mate, then escalated once beyond it, and cleared when it moves.
# Hermetic: bin/ is copied with bin/fm-crew-state.sh replaced by a stub that
# publishes state/<id>.crew-state from a fixture the test controls.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-parked-run-watch)

new_home() {  # <name> -> echoes a home with a code copy beside it
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/home/config"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
id=$2
state=${FM_STATE_OVERRIDE:-$FM_HOME/state}
if [ -f "$FM_HOME/fake-$id.crew-state" ]; then
  cp "$FM_HOME/fake-$id.crew-state" "$state/$id.crew-state"
else
  rm -f "$state/$id.crew-state"
fi
SH
  chmod +x "$dir/bin/fm-crew-state.sh"
  printf 'kind=ship\nharness=deck\n' > "$dir/home/state/w1.meta"
  printf '%s\n' "$dir"
}

parked() {  # <dir> <run>
  printf 'verdict=parked\nstep=review\nstep_status=awaiting_approval\nrun=%s\n' "$2" > "$1/home/fake-w1.crew-state"
}

scan() {  # <dir>
  FM_HOME="$1/home" FM_PARKED_RUN_SECS=0 "$1/bin/fm-parked-run-watch.sh" scan
}

wakes() {  # <dir> <pattern>
  local n
  n=$(grep -c "$2" "$1/home/state/.wake-queue" 2>/dev/null) || n=0
  printf '%s' "${n:-0}"
}

test_first_mate_home_nudges_then_raises_once_and_clears() {
  local dir
  dir=$(new_home main)
  parked "$dir" run-a
  scan "$dir"
  [ "$(wakes "$dir" 'parked-run:')" = 0 ] || fail "a run just seen parked must not be raised yet"
  scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:run-a')" = 1 ] || fail "a run parked past the limit nudges its mate once"
  assert_grep "worker w1's validation run run-a has been parked at review" "$dir/home/state/.wake-queue" "the nudge names the worker, run and step"
  scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:escalate')" = 1 ] || fail "a run still parked after the nudge is raised once"
  scan "$dir"; scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:escalate')" = 1 ] || fail "the escalation is never repeated"
  printf 'verdict=working\nstep=test\nrun=run-a\n' > "$dir/home/fake-w1.crew-state"
  scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:resolved')" = 1 ] || fail "a run that moved on clears its blocker"
  [ ! -e "$dir/home/state/w1.parked-run" ] || fail "a moving run keeps no record"
  pass "parked-run watch: the first mate's own worker is nudged, raised once, and cleared"
}

test_second_mate_home_raises_to_its_parent_channel() {
  local dir parent channel
  dir=$(new_home mate)
  parent="$TMP_ROOT/parent-home"
  mkdir -p "$parent/state"
  printf 'docana\n' > "$dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$dir/home/.fm-secondmate-parent"
  channel="$parent/state/docana.status"
  parked "$dir" run-b
  scan "$dir"; scan "$dir"; scan "$dir"
  assert_grep "blocked [key=parked-run-docana-w1]: worker w1's validation run run-b has been parked at review" "$channel" \
    "a second mate raises a parked run to the first mate"
  [ "$(grep -c '^blocked \[key=parked-run-docana-w1\]' "$channel")" = 1 ] || fail "the blocker is raised once"
  parked "$dir" run-c
  scan "$dir"
  [ "$(grep -c '^blocked' "$channel")" = 1 ] || fail "a new run starts its own clock"
  assert_grep 'resolved [key=parked-run-docana-w1]' "$channel" "the old run's blocker is resolved"
  rm -f "$dir/home/fake-w1.crew-state"
  scan "$dir"
  pass "parked-run watch: a second mate raises its parked worker to the first mate once"
}

test_an_unavailable_reading_never_resolves_a_parked_run() {
  local dir
  dir=$(new_home unknown)
  parked "$dir" run-d
  scan "$dir"; scan "$dir"; scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:escalate')" = 1 ] || fail "setup: the run was not escalated"
  printf 'verdict=unknown\nstep=\nrun=\n' > "$dir/home/fake-w1.crew-state"
  scan "$dir"
  rm -f "$dir/home/fake-w1.crew-state"
  scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:resolved')" = 0 ] || fail "an unavailable reading must not clear a parked run"
  [ -f "$dir/home/state/w1.parked-run" ] || fail "an unavailable reading must keep the parked record"
  pass "parked-run watch: an unknown or missing reading keeps a parked run's record and blocker"
}

test_a_run_that_parks_again_or_at_another_gate_starts_over() {
  local dir
  dir=$(new_home repark)
  parked "$dir" run-e
  scan "$dir"; scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:run-e:')" = 1 ] || fail "setup: the first nudge is missing"
  printf 'verdict=working\nstep=test\nrun=run-e\n' > "$dir/home/fake-w1.crew-state"
  scan "$dir"
  parked "$dir" run-e
  sleep 1
  scan "$dir"; scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:run-e:')" = 2 ] || fail "the same run parking again must nudge again"
  printf 'verdict=parked\nstep=ci\nstep_status=awaiting_approval\nrun=run-e\n' > "$dir/home/fake-w1.crew-state"
  scan "$dir"
  assert_grep 'step=ci' "$dir/home/state/w1.parked-run" "a new gate starts its own clock"
  assert_grep 'nudged=0' "$dir/home/state/w1.parked-run" "a new gate is not treated as already nudged"
  pass "parked-run watch: a run parked again, or at another gate, gets its own nudge"
}

test_a_worker_leaving_closes_its_escalation() {
  local dir
  dir=$(new_home leaving)
  parked "$dir" run-f
  scan "$dir"; scan "$dir"; scan "$dir"
  FM_HOME="$dir/home" "$dir/bin/fm-parked-run-watch.sh" close w1
  [ "$(wakes "$dir" 'parked-run:w1:resolved')" = 1 ] || fail "a worker leaving must resolve its escalated parked run"
  [ ! -e "$dir/home/state/w1.parked-run" ] || fail "a worker leaving keeps no parked record"
  pass "parked-run watch: a worker cleaned up while escalated resolves its blocker"
}

test_first_mate_home_nudges_then_raises_once_and_clears
test_second_mate_home_raises_to_its_parent_channel
test_a_worker_leaving_closes_its_escalation
test_an_unavailable_reading_never_resolves_a_parked_run
test_a_run_that_parks_again_or_at_another_gate_starts_over
