#!/usr/bin/env bash
# tests/fm-deck-turn-failure-supersession.test.sh - the Deck turn-failure
# supersession contract (bin/fm-classify-lib.sh's fm_turn_failed_superseded_line
# and the consumers that reclassify a superseded turn-failure).
#
# A Deck driver turn that ends without appending a status line is backstopped
# with
#   failed: deck turn ended without a status line (<event> gen=<busy-gen>)
# which is evidence the TURN produced no report, not evidence the WORK failed:
# the driver returns to its prompt and replays the turn on the next wake in the
# SAME incarnation (same busy-state generation). The 2026-10-12 incidents
# recorded a false `failed:` wake three times in one evening on a healthy task
# while supervision hand-appended corrections. The cure: when the same
# generation later shows the task working (a busy turn-start from that
# generation), the turn-failed record leaves the actionable span and the
# away-mode terminal path; a genuinely different generation after a driver loss
# keeps the failed semantics.
#
# Both directions are covered: superseded when the same generation resumes,
# still failed when the generation changed, plus the interrupted exclusion (the
# captain's own Ctrl+C is a deliberate stop that needs no cure) and the
# current-state contract (the resumed turn reads working through its busy
# record; a genuine cross-idle failure still reads failed). Hermetic over temp
# dirs; no real agent session is invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deck-turn-failure-supersession)
EV="$ROOT/bin/fm-busy-event.sh"
CREW_STATE="$ROOT/bin/fm-crew-state.sh"

new_case() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s' "$d"
}

# Register a fake stream endpoint for the task and run the current-state reader
# over it, the same hermetic pane source tests/fm-crew-state.test.sh uses: a
# quiet prompt screen, no run lookup (kind=scout), an idle-to-busy record the
# busy arm reads, and the case's status log as the final authority.
run_state() {  # <case-dir> <id>
  local screen="$1/$2.screen"
  printf 'all quiet\n> \n' > "$screen"
  fm_test_fake_stream_set "$(sed -n 's/^window=//p' "$1/state/$2.meta" | tail -1)" \
    "$(jq -nc --arg f "$screen" '{capture_file: $f, stale: false}')" >/dev/null
  FM_STATE_OVERRIDE="$1/state" "$CREW_STATE" "$2"
}

# The failure line exactly as bin/fm-deck-worker.sh appends it.
failure_line() {  # <event> <gen>
  printf 'failed: deck turn ended without a status line (%s gen=%s)' "$1" "$2"
}

test_same_generation_resuming_supersedes_the_failure() {
  local dir state gen
  dir=$(new_case same-gen); state="$dir/state"
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source deck-wrapper --event turn-failed \
    || fail "apply idle turn-failed failed"
  printf 'working: mid-implementation\n' > "$state/t1.status"
  printf '%s\n' "$(failure_line turn-failed "$gen")" >> "$state/t1.status"
  # The driver replays the turn in the same incarnation: the busy record shows
  # that same generation mid-turn again.
  "$EV" apply "$state" t1 busy --gen "$gen" --source deck-wrapper --event turn-start \
    || fail "apply busy turn-start failed"
  fm_turn_failed_superseded_line "$state/t1.status" "$(failure_line turn-failed "$gen")" \
    || fail "a same-generation busy turn-start did not supersede the turn failure"
  status_span_has_actionable "$state/t1.status" 0 \
    && fail "a superseded turn-failure stayed actionable in the status span"
  pass "superseded: the same busy generation resuming reclassifies the failure"
}

test_different_generation_keeps_the_failure() {
  local state old_gen new_gen
  dir=$(new_case diff-gen); state="$dir/state"
  old_gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$old_gen" --source deck-wrapper --event turn-failed \
    || fail "apply idle turn-failed failed"
  printf '%s\n' "$(failure_line turn-failed "$old_gen")" > "$state/t1.status"
  # A genuinely new incarnation after driver loss: arm replaces the generation.
  new_gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$new_gen" --source deck-wrapper --event turn-start \
    || fail "apply busy turn-start failed"
  fm_turn_failed_superseded_line "$state/t1.status" "$(failure_line turn-failed "$old_gen")" \
    && fail "a different generation's busy turn-start superseded an older failure"
  status_span_has_actionable "$state/t1.status" 0 \
    || fail "a genuine cross-generation failure was absorbed"
  pass "still failed: a changed generation keeps the failure semantics"
}

test_interrupted_turn_is_never_superseded() {
  local dir state gen
  dir=$(new_case interrupted); state="$dir/state"
  gen=$("$EV" arm "$state" t1)
  printf '%s\n' "$(failure_line interrupted "$gen")" > "$state/t1.status"
  "$EV" apply "$state" t1 busy --gen "$gen" --source deck-wrapper --event turn-start \
    || fail "apply busy turn-start failed"
  fm_turn_failed_superseded_line "$state/t1.status" "$(failure_line interrupted "$gen")" \
    && fail "an interrupted turn was superseded despite the exclusion"
  status_span_has_actionable "$state/t1.status" 0 \
    || fail "an interrupted turn's failure was absorbed"
  pass "interrupted: the captain's own Ctrl+C is never superseded"
}

test_unstamped_and_foreign_lines_are_untouched() {
  local dir state gen
  dir=$(new_case untouched); state="$dir/state"
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 busy --gen "$gen" --source deck-wrapper --event turn-start \
    || fail "apply busy turn-start failed"
  # Legacy failure line without a gen stamp: no generation to key on, so the
  # failed semantics must hold (honest classification, never silencing).
  printf 'failed: deck turn ended without a status line (turn-failed)\n' > "$state/t1.status"
  fm_turn_failed_superseded_line "$state/t1.status" "$(cat "$state/t1.status")" \
    && fail "an unstamped failure line was superseded"
  status_span_has_actionable "$state/t1.status" 0 \
    || fail "an unstamped failure line was absorbed"
  # An ordinary worker failure is never in scope.
  printf 'failed: tests failed\n' > "$state/t1.status"
  fm_turn_failed_superseded_line "$state/t1.status" "$(cat "$state/t1.status")" \
    && fail "an ordinary failure line was superseded"
  pass "unstamped and ordinary failure lines keep the failed semantics"
}

test_idle_and_missing_busy_records_are_not_superseded() {
  local dir state gen
  dir=$(new_case idle-record); state="$dir/state"
  gen=$("$EV" arm "$state" t1)
  printf '%s\n' "$(failure_line turn-failed "$gen")" > "$state/t1.status"
  # The turn genuinely closed idle and nothing has resumed: not superseded.
  "$EV" apply "$state" t1 idle --gen "$gen" --source deck-wrapper --event turn-end \
    || fail "apply idle turn-end failed"
  fm_turn_failed_superseded_line "$state/t1.status" "$(failure_line turn-failed "$gen")" \
    && fail "an idle record superseded the failure"
  # No busy wiring at all: nothing to key on.
  dir=$(new_case no-record); state="$dir/state"
  printf '%s\n' "$(failure_line turn-failed g1.2.3)" > "$state/t1.status"
  fm_turn_failed_superseded_line "$state/t1.status" "$(cat "$state/t1.status")" \
    && fail "a missing busy record superseded the failure"
  pass "idle and missing busy records keep the failure semantics"
}

test_current_state_reads_a_superseded_failure_as_working() {
  local dir state gen out
  dir=$(new_case current-state); state="$dir/state"
  gen=$("$EV" arm "$state" t1)
  "$EV" apply "$state" t1 idle --gen "$gen" --source deck-wrapper --event turn-failed \
    || fail "apply idle turn-failed failed"
  printf 'working: mid-implementation\n' > "$state/t1.status"
  printf '%s\n' "$(failure_line turn-failed "$gen")" >> "$state/t1.status"
  "$EV" apply "$state" t1 busy --gen "$gen" --source deck-wrapper --event turn-start \
    || fail "apply busy turn-start failed"
  fm_write_meta "$state/t1.meta" $(fm_test_stream_task "$state" t1) \
    "worktree=$dir/wt" "kind=scout" "harness=deck"
  mkdir -p "$dir/wt"
  out=$(run_state "$dir" t1)
  case "$out" in
    'state: working · source: pane'*) ;;
    *) fail "a superseded turn-failure did not read as working once resumed: $out" ;;
  esac
  pass "current state: the replayed turn reads working, never failed"
}

test_current_state_keeps_a_genuine_failure() {
  local dir state gen out
  dir=$(new_case current-state-failed); state="$dir/state"
  gen=$("$EV" arm "$state" t1)
  printf '%s\n' "$(failure_line turn-failed "$gen")" > "$state/t1.status"
  "$EV" apply "$state" t1 idle --gen "$gen" --source deck-wrapper --event turn-end \
    || fail "apply idle turn-end failed"
  fm_write_meta "$state/t1.meta" $(fm_test_stream_task "$state" t1) \
    "worktree=$dir/wt" "kind=scout" "harness=deck"
  mkdir -p "$dir/wt"
  out=$(run_state "$dir" t1)
  case "$out" in
    'state: failed · source: status-log'*) ;;
    *) fail "a genuine failure did not read as failed: $out" ;;
  esac
  pass "current state: a genuine cross-idle failure still reads failed"
}

test_same_generation_resuming_supersedes_the_failure
test_different_generation_keeps_the_failure
test_interrupted_turn_is_never_superseded
test_unstamped_and_foreign_lines_are_untouched
test_idle_and_missing_busy_records_are_not_superseded
test_current_state_reads_a_superseded_failure_as_working
test_current_state_keeps_a_genuine_failure

echo "fm-deck-turn-failure-supersession: all cases passed"
