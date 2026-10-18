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
case "$(cat "$FM_HOME/query-mode" 2>/dev/null)" in
  unknown) printf 'state: unknown · source: none\n'; exit 0 ;;
  failed) printf 'state: parked · source: run-step\n'; exit 1 ;;
esac
if [ -f "$FM_HOME/fake-$id.crew-state" ]; then
  cp "$FM_HOME/fake-$id.crew-state" "$state/$id.crew-state"
  printf 'state: %s · source: run-step\n' "$(sed -n 's/^verdict=//p' "$state/$id.crew-state")"
else
  rm -f "$state/$id.crew-state"
  printf 'state: unknown · source: none\n'
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

test_a_busy_worker_quiet_for_hours_gets_one_check_in() {
  local dir
  dir=$(new_home quiet)
  printf 'v1 gen=g1 seq=1 state=busy source=deck-wrapper event=turn-start ts=1\n' > "$dir/home/state/w1.busy-state"
  printf 'working: started\n' > "$dir/home/state/w1.status"
  touch -t 202001010000 "$dir/home/state/w1.status"
  FM_HOME="$dir/home" FM_WORKER_QUIET_SECS=3600 "$dir/bin/fm-parked-run-watch.sh" scan
  FM_HOME="$dir/home" FM_WORKER_QUIET_SECS=3600 "$dir/bin/fm-parked-run-watch.sh" scan
  [ "$(wakes "$dir" 'parked-run:w1:quiet:')" = 1 ] || fail "a busy worker silent past the limit gets exactly one check-in"
  assert_grep "ask it what it is working on and whether its task asked for it" "$dir/home/state/.wake-queue" "the check-in asks the mate to ask the worker"
  printf 'working: still on it\n' >> "$dir/home/state/w1.status"
  touch -t 202001020000 "$dir/home/state/w1.status"
  FM_HOME="$dir/home" FM_WORKER_QUIET_SECS=3600 "$dir/bin/fm-parked-run-watch.sh" scan
  [ "$(wakes "$dir" 'parked-run:w1:quiet:')" = 2 ] || fail "a new quiet stretch gets its own check-in"
  printf 'v1 gen=g1 seq=2 state=idle source=deck-wrapper event=turn-end ts=2\n' > "$dir/home/state/w1.busy-state"
  touch -t 202001030000 "$dir/home/state/w1.status"
  FM_HOME="$dir/home" FM_WORKER_QUIET_SECS=3600 "$dir/bin/fm-parked-run-watch.sh" scan
  [ "$(wakes "$dir" 'parked-run:w1:quiet:')" = 2 ] || fail "an idle worker is not checked in on"
  pass "parked-run watch: a busy worker quiet for hours gets one check-in per quiet stretch"
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

test_a_reading_without_run_identity_keeps_the_parked_episode() {
  local dir verdict record queue
  dir=$(new_home coarse)
  parked "$dir" run-coarse
  scan "$dir"; scan "$dir"; scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:escalate')" = 1 ] || fail "setup: the run was not escalated"
  record=$(cat "$dir/home/state/w1.parked-run")
  queue=$(cat "$dir/home/state/.wake-queue")
  for verdict in working 'done' blocked failed parked; do
    printf 'verdict=%s\nstep=\nrun=\n' "$verdict" > "$dir/home/fake-w1.crew-state"
    scan "$dir"
    [ -f "$dir/home/state/w1.parked-run" ] || fail "$verdict without a run identity removed the parked record"
    [ "$(cat "$dir/home/state/w1.parked-run")" = "$record" ] || fail "$verdict without a run identity changed the parked episode"
    [ "$(cat "$dir/home/state/.wake-queue")" = "$queue" ] || fail "$verdict without a run identity emitted a wake"
  done
  printf 'verdict=working\nstep=test\nrun=run-coarse\n' > "$dir/home/fake-w1.crew-state"
  scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:resolved')" = 1 ] || fail "an attributed moving reading must resolve the blocker"
  [ ! -e "$dir/home/state/w1.parked-run" ] || fail "an attributed moving reading must clear the parked record"
  pass "parked-run watch: identity-free readings preserve the episode until an attributed reading moves it"
}

test_an_unavailable_query_never_uses_a_stale_projection() {
  local dir mode stage record queue
  for mode in unknown failed; do
    dir=$(new_home "stale-$mode")
    parked "$dir" run-stale
    scan "$dir"
    for stage in nudge escalate; do
      record=$(cat "$dir/home/state/w1.parked-run")
      queue=$(cat "$dir/home/state/.wake-queue" 2>/dev/null)
      printf '%s\n' "$mode" > "$dir/home/query-mode"
      scan "$dir"
      [ "$(cat "$dir/home/state/w1.parked-run")" = "$record" ] || fail "$mode query advanced the $stage clock using a stale projection"
      [ "$(cat "$dir/home/state/.wake-queue" 2>/dev/null)" = "$queue" ] || fail "$mode query emitted a $stage wake using a stale projection"
      assert_grep 'verdict=parked' "$dir/home/state/w1.crew-state" "setup: the unavailable query must leave the stale projection intact"
      rm "$dir/home/query-mode"
      scan "$dir"
    done
    [ "$(wakes "$dir" 'parked-run:w1:escalate')" = 1 ] || fail "fresh readings must resume escalation"
  done
  pass "parked-run watch: unknown and failed queries cannot advance a stale parked projection"
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

test_a_close_that_cannot_resolve_keeps_the_record_and_fails() {
  local dir parent rc=0
  dir=$(new_home closefail)
  parent="$TMP_ROOT/closefail-parent"
  mkdir -p "$parent/state"
  printf 'docana\n' > "$dir/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$dir/home/.fm-secondmate-parent"
  parked "$dir" run-g
  scan "$dir"; scan "$dir"; scan "$dir"
  assert_grep 'blocked [key=parked-run-docana-w1]' "$parent/state/docana.status" "setup: the run was escalated"
  chmod a-w "$parent/state" "$parent/state/docana.status"
  FM_HOME="$dir/home" "$dir/bin/fm-parked-run-watch.sh" close w1 2>/dev/null || rc=$?
  chmod u+w "$parent/state" "$parent/state/docana.status"
  [ "$rc" = 1 ] || fail "a close that could not resolve its blocker must fail (rc=$rc)"
  [ -f "$dir/home/state/w1.parked-run" ] || fail "a failed close must keep the record so a retry resolves it"
  FM_HOME="$dir/home" "$dir/bin/fm-parked-run-watch.sh" close w1 || fail "the retried close must succeed"
  assert_grep 'resolved [key=parked-run-docana-w1]' "$parent/state/docana.status" "the retry resolves the blocker"
  pass "parked-run watch: a close that cannot resolve keeps its record and fails, and a retry resolves it"
}

test_a_left_worker_is_never_raised_and_its_record_is_dropped() {
  local dir holder
  dir=$(new_home left)
  parked "$dir" run-h
  scan "$dir"; scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:run-h')" = 1 ] || fail "setup: the nudge is missing"
  # While a close holds the worker, a scan leaves it alone.
  # shellcheck source=/dev/null
  ( . "$dir/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$dir/home/state/.w1.parked-run.lock" && : > "$dir/held"
    sleep 30 ) &
  holder=$!
  for _ in $(seq 1 50); do [ -e "$dir/held" ] && break; sleep 0.1; done
  [ -e "$dir/held" ] || fail "setup: the close's lock was not taken"
  scan "$dir"
  kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
  [ "$(wakes "$dir" 'parked-run:w1:escalate')" = 0 ] || fail "a worker held by a close must not be raised by a scan"
  rm -f "$dir/home/state/w1.meta"
  scan "$dir"
  [ "$(wakes "$dir" 'parked-run:w1:escalate')" = 0 ] || fail "a worker that left must never be raised"
  [ ! -e "$dir/home/state/w1.parked-run" ] || fail "a left worker's record is dropped"
  pass "parked-run watch: a worker being closed or gone is never raised, and its record is dropped"
}

test_first_mate_home_nudges_then_raises_once_and_clears
test_a_busy_worker_quiet_for_hours_gets_one_check_in
test_a_close_that_cannot_resolve_keeps_the_record_and_fails
test_a_left_worker_is_never_raised_and_its_record_is_dropped
test_second_mate_home_raises_to_its_parent_channel
test_a_worker_leaving_closes_its_escalation
test_an_unavailable_reading_never_resolves_a_parked_run
test_a_reading_without_run_identity_keeps_the_parked_episode
test_an_unavailable_query_never_uses_a_stale_projection
test_a_run_that_parks_again_or_at_another_gate_starts_over
