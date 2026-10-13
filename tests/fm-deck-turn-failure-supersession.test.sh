#!/usr/bin/env bash
# tests/fm-deck-turn-failure-supersession.test.sh - executable regressions for
# ordered, recovery-bound Deck turn-failure supersession.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deck-turn-failure-supersession)

new_case() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s' "$d"
}

failure_line() {  # <generation> <record-id>
  printf 'failed: deck turn ended without a status line (turn-failed recovery-gen=%s id=%s)' "$1" "$2"
}

append_failure() {  # <status-file> <generation> <record-id>
  printf '%s\n' "$(failure_line "$2" "$3")" >> "$1"
}

test_later_working_in_the_same_recovery_generation_supersedes() {
  local dir status generation record failure endpoint
  dir=$(new_case same-generation)
  status="$dir/state/task.status"
  generation=deck-same
  record='record-one'
  append_failure "$status" "$generation" "$record"
  failure=$(failure_line "$generation" "$record")
  printf 'working: replay resumed\n' >> "$status"
  printf 'working [recovery-gen=%s]: deck turn reported working\n' "$generation" >> "$status"
  endpoint=$(wc -c < "$status" | tr -d '[:space:]')

  fm_turn_failed_superseded_line "$status" "$failure" "$endpoint" \
    || fail "later same-generation working evidence did not supersede the turn failure"
  status_span_has_actionable "$status" 0 \
    && fail "the superseded turn failure remained actionable"
  pass "a later same-generation working record supersedes the turn failure"
}

test_original_turn_state_cannot_supersede_before_replay() {
  local dir status generation record failure
  dir=$(new_case no-replay)
  status="$dir/state/task.status"
  generation=deck-original
  record='record-original'
  printf 'working: original turn started\n' > "$status"
  append_failure "$status" "$generation" "$record"
  failure=$(failure_line "$generation" "$record")

  fm_turn_failed_superseded_line "$status" "$failure" \
    && fail "working evidence before the failure superseded it"
  status_span_has_actionable "$status" 0 \
    || fail "the unsuperseded turn failure was not actionable"
  pass "working evidence before the failure cannot supersede it"
}

test_unbound_and_different_generation_working_lines_do_not_supersede() {
  local dir status generation record failure
  dir=$(new_case mismatched-working)
  status="$dir/state/task.status"
  generation=deck-mismatch
  record='record-mismatch'
  append_failure "$status" "$generation" "$record"
  failure=$(failure_line "$generation" "$record")
  printf 'working: unbound replay line\n' >> "$status"
  printf 'working [recovery-gen=other-generation]: unrelated recovery\n' >> "$status"

  fm_turn_failed_superseded_line "$status" "$failure" \
    && fail "an unbound or different-generation working line superseded the failure"
  status_span_has_actionable "$status" 0 \
    || fail "a generation-mismatched failure was absorbed"
  pass "only recovery-bound working evidence can supersede a failure"
}

test_supersession_is_independent_of_watcher_recovery_state() {
  local dir status generation record failure
  dir=$(new_case task-local)
  status="$dir/state/task.status"
  generation=deck-local
  record='record-local'
  append_failure "$status" "$generation" "$record"
  failure=$(failure_line "$generation" "$record")
  printf 'working [recovery-gen=%s]: replay stayed healthy\n' "$generation" >> "$status"

  [ ! -e "$dir/state/.watcher-down" ] \
    || fail "the task-local fixture unexpectedly created watcher recovery state"
  fm_turn_failed_superseded_line "$status" "$failure" \
    || fail "supersession depended on watcher recovery state"
  status_span_has_actionable "$status" 0 \
    && fail "the task-local superseded failure resurfaced"
  pass "Deck recovery identity stays task-local"
}

test_only_exact_turn_failed_records_participate() {
  local dir status generation line
  dir=$(new_case exact-event)
  status="$dir/state/task.status"
  generation=deck-exact

  for line in \
    'failed: deck turn ended without a status line (turn-end)' \
    'failed: deck turn ended without a status line (interrupted)' \
    "failed: deck turn ended without a status line (turn-end recovery-gen=$generation id=record)" \
    "failed: deck turn ended without a status line (arbitrary recovery-gen=$generation id=record)" \
    "failed: deck turn ended without a status line (turn-failed recovery-gen=$generation at=0)" \
    'failed: deck turn ended without a status line (turn-failed)' \
    'failed: tests failed'; do
    printf '%s\nworking [recovery-gen=%s]: later work\n' "$line" "$generation" > "$status"
    fm_turn_failed_superseded_line "$status" "$line" \
      && fail "a non-stamped exact turn-failed record was superseded: $line"
  done
  pass "turn-end, interrupted, legacy, and foreign failures stay failed"
}

test_record_identity_disambiguates_repeated_failures() {
  local dir status generation first second
  dir=$(new_case repeated)
  status="$dir/state/task.status"
  generation=deck-repeated
  append_failure "$status" "$generation" record-first
  first=$(failure_line "$generation" record-first)
  printf 'working [recovery-gen=%s]: first replay resumed\n' "$generation" >> "$status"
  append_failure "$status" "$generation" record-second
  second=$(failure_line "$generation" record-second)

  fm_turn_failed_superseded_line "$status" "$first" \
    || fail "the first repeated failure lost its later working evidence"
  fm_turn_failed_superseded_line "$status" "$second" \
    && fail "the later repeated failure borrowed the first failure's evidence"
  pass "record identities keep repeated failures independently ordered"
}

test_captured_endpoint_bounds_supersession_evidence() {
  local dir status generation record failure failure_endpoint full_endpoint
  dir=$(new_case endpoint)
  status="$dir/state/task.status"
  generation=deck-endpoint
  record='record-endpoint'
  append_failure "$status" "$generation" "$record"
  failure=$(failure_line "$generation" "$record")
  failure_endpoint=$(wc -c < "$status" | tr -d '[:space:]')
  printf 'working [recovery-gen=%s]: replay resumed\n' "$generation" >> "$status"
  full_endpoint=$(wc -c < "$status" | tr -d '[:space:]')

  fm_turn_failed_superseded_line "$status" "$failure" "$failure_endpoint" \
    && fail "working evidence beyond the captured endpoint changed the snapshot"
  fm_turn_failed_superseded_line "$status" "$failure" "$full_endpoint" \
    || fail "the full captured endpoint did not include its working evidence"
  pass "supersession respects the classifier's captured endpoint"
}

test_working_binding_is_atomic_with_status_append() {
  local dir status offset turn_offset failure endpoint
  dir=$(new_case binding-order)
  status="$dir/state/task.status"
  append_failure "$status" deck-bind record-bind
  failure=$(failure_line deck-bind record-bind)
  turn_offset=$(wc -c < "$status" | tr -d '[:space:]')
  printf 'working: replay resumed\ndone: replay completed\n' \
    | FM_DECK_STATUS_NAME=task.status FM_DECK_STATUS_TURN_OFFSET="$turn_offset" \
      FM_DECK_STATUS_DRIVER_GEN=deck-bind \
      python3 "$ROOT/bin/fm-state-io.py" root-append "$dir/state" task.status \
    || fail "the working and terminal burst was not appended"
  [ "$(sed -n '2p' "$status")" = 'working: replay resumed' ] \
    || fail "the worker-authored working line was not preserved"
  [ "$(sed -n '3p' "$status")" = 'working [recovery-gen=deck-bind]: deck turn reported working' ] \
    || fail "the recovery marker was not written in the working append"
  [ "$(sed -n '4p' "$status")" = 'done: replay completed' ] \
    || fail "the terminal status did not remain last"
  endpoint=$(wc -c < "$status" | tr -d '[:space:]')
  fm_turn_failed_superseded_line "$status" "$failure" "$endpoint" \
    || fail "the atomic working append did not supersede its failure"

  status="$dir/state/late.status"
  append_failure "$status" deck-late record-late
  turn_offset=$(wc -c < "$status" | tr -d '[:space:]')
  printf 'done: replay completed\n' \
    | python3 "$ROOT/bin/fm-state-io.py" root-append "$dir/state" late.status \
    || fail "the terminal status was not appended"
  offset=$(wc -c < "$status" | tr -d '[:space:]')
  printf 'working: stale replay update\n' \
    | FM_DECK_STATUS_NAME=late.status FM_DECK_STATUS_TURN_OFFSET="$turn_offset" \
      FM_DECK_STATUS_DRIVER_GEN=deck-late \
      python3 "$ROOT/bin/fm-state-io.py" root-append "$dir/state" late.status \
    || fail "the late working append boundary failed"
  [ "$(wc -c < "$status" | tr -d '[:space:]')" = "$offset" ] \
    || fail "a working record was appended after the terminal truth"
  [ "$(tail -1 "$status")" = 'done: replay completed' ] \
    || fail "late recovery binding displaced the terminal status"

  printf 'working: next turn resumed\n' \
    | FM_DECK_STATUS_NAME=late.status FM_DECK_STATUS_TURN_OFFSET="$offset" \
      FM_DECK_STATUS_DRIVER_GEN=deck-late \
      python3 "$ROOT/bin/fm-state-io.py" root-append "$dir/state" late.status \
    || fail "the next turn working append boundary failed"
  [ "$(tail -1 "$status")" = 'working: next turn resumed' ] \
    || fail "the closed recovery episode discarded later working evidence"
  [ "$(wc -l < "$status" | tr -d '[:space:]')" = 3 ] \
    || fail "the next turn fabricated a recovery marker"
  pass "working supersession shares the locked status append"
}

test_new_driver_cannot_bind_an_older_failure() {
  local dir status turn_offset failure
  dir=$(new_case driver-incarnation)
  status="$dir/state/task.status"
  append_failure "$status" old-driver record-old
  failure=$(failure_line old-driver record-old)
  turn_offset=$(wc -c < "$status" | tr -d '[:space:]')

  printf 'working: fresh driver started\n' \
    | FM_DECK_STATUS_NAME=task.status FM_DECK_STATUS_TURN_OFFSET="$turn_offset" \
      FM_DECK_STATUS_DRIVER_GEN=new-driver \
      python3 "$ROOT/bin/fm-state-io.py" root-append "$dir/state" task.status \
    || fail "the fresh driver working append failed"
  [ "$(tail -1 "$status")" = 'working: fresh driver started' ] \
    || fail "the fresh driver lost its working status"
  [ "$(wc -l < "$status" | tr -d '[:space:]')" = 2 ] \
    || fail "the fresh driver bound an older incarnation's failure"
  fm_turn_failed_superseded_line "$status" "$failure" \
    && fail "the fresh driver superseded an older incarnation's failure"
  status_span_has_actionable "$status" 0 \
    || fail "the older incarnation's failure stopped being actionable"
  pass "a fresh driver cannot bind an older recovery episode"
}

test_later_working_in_the_same_recovery_generation_supersedes
test_original_turn_state_cannot_supersede_before_replay
test_unbound_and_different_generation_working_lines_do_not_supersede
test_supersession_is_independent_of_watcher_recovery_state
test_only_exact_turn_failed_records_participate
test_record_identity_disambiguates_repeated_failures
test_captured_endpoint_bounds_supersession_evidence
test_working_binding_is_atomic_with_status_append
test_new_driver_cannot_bind_an_older_failure

echo "fm-deck-turn-failure-supersession: all cases passed"
