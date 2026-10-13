#!/usr/bin/env bash
# tests/fm-deck-turn-failure-supersession.test.sh - executable regressions for
# ordered, recovery-bound Deck turn-failure supersession.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=bin/fm-wake-lib.sh
. "$ROOT/bin/fm-wake-lib.sh"

# shellcheck source=bin/fm-classify-lib.sh
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-deck-turn-failure-supersession)

new_case() {  # <name>
  local d="$TMP_ROOT/$1"
  mkdir -p "$d/state"
  printf '%s' "$d"
}

failure_line() {  # <generation> <offset>
  printf 'failed: deck turn ended without a status line (turn-failed recovery-gen=%s at=%s)' "$1" "$2"
}

append_failure() {  # <status-file> <generation>
  local offset
  offset=$(wc -c < "$1" 2>/dev/null | tr -d '[:space:]')
  case "$offset" in ''|*[!0-9]*) offset=0 ;; esac
  printf '%s\n' "$(failure_line "$2" "$offset")" >> "$1"
  printf '%s' "$offset"
}

test_later_working_in_the_same_recovery_generation_supersedes() {
  local dir status generation offset failure endpoint
  dir=$(new_case same-generation)
  status="$dir/state/task.status"
  : > "$status"
  generation=$(fm_recovery_marker_reserve_generation "$dir/state/.watcher-down") \
    || fail "could not reserve a recovery generation"
  offset=$(append_failure "$status" "$generation")
  failure=$(failure_line "$generation" "$offset")
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
  local dir status generation offset failure
  dir=$(new_case no-replay)
  status="$dir/state/task.status"
  printf 'working: original turn started\n' > "$status"
  generation=$(fm_recovery_marker_reserve_generation "$dir/state/.watcher-down") \
    || fail "could not reserve a recovery generation"
  offset=$(append_failure "$status" "$generation")
  failure=$(failure_line "$generation" "$offset")

  fm_turn_failed_superseded_line "$status" "$failure" \
    && fail "working evidence before the failure superseded it"
  status_span_has_actionable "$status" 0 \
    || fail "the unsuperseded turn failure was not actionable"
  pass "working evidence before the failure cannot supersede it"
}

test_unbound_and_different_generation_working_lines_do_not_supersede() {
  local dir status generation offset failure other
  dir=$(new_case mismatched-working)
  status="$dir/state/task.status"
  : > "$status"
  generation=$(fm_recovery_marker_reserve_generation "$dir/state/.watcher-down") \
    || fail "could not reserve a recovery generation"
  offset=$(append_failure "$status" "$generation")
  failure=$(failure_line "$generation" "$offset")
  printf 'working: unbound replay line\n' >> "$status"
  printf 'working [recovery-gen=other-generation]: unrelated recovery\n' >> "$status"

  fm_turn_failed_superseded_line "$status" "$failure" \
    && fail "an unbound or different-generation working line superseded the failure"
  status_span_has_actionable "$status" 0 \
    || fail "a generation-mismatched failure was absorbed"

  other=$(fm_recovery_marker_reserve_generation "$dir/state/.other-watcher-down") \
    || fail "could not reserve the comparison generation"
  [ "$other" != "$generation" ] || fail "the fixture did not create distinct generations"
  pass "only recovery-bound working evidence can supersede a failure"
}

test_supersession_survives_idle_and_later_recovery_episodes() {
  local dir status generation offset failure
  dir=$(new_case durable)
  status="$dir/state/task.status"
  : > "$status"
  generation=$(fm_recovery_marker_reserve_generation "$dir/state/.watcher-down") \
    || fail "could not reserve a recovery generation"
  offset=$(append_failure "$status" "$generation")
  failure=$(failure_line "$generation" "$offset")
  printf 'working [recovery-gen=%s]: replay stayed healthy\n' "$generation" >> "$status"

  fm_recovery_marker_ack "$dir/state/.watcher-down" "$generation" \
    || fail "could not close the original recovery episode"
  fm_recovery_marker_reserve_generation "$dir/state/.watcher-down" >/dev/null \
    || fail "could not open a later recovery episode"
  rm -f "$dir/state/.watcher-down"

  fm_turn_failed_superseded_line "$status" "$failure" \
    || fail "supersession depended on the live recovery marker"
  status_span_has_actionable "$status" 0 \
    && fail "the old failure resurfaced after the recovery episode moved"
  pass "ordered status evidence keeps supersession durable"
}

test_only_exact_turn_failed_records_participate() {
  local dir status generation line
  dir=$(new_case exact-event)
  status="$dir/state/task.status"
  generation=$(fm_recovery_marker_reserve_generation "$dir/state/.watcher-down") \
    || fail "could not reserve a recovery generation"

  for line in \
    'failed: deck turn ended without a status line (turn-end)' \
    'failed: deck turn ended without a status line (interrupted)' \
    "failed: deck turn ended without a status line (turn-end recovery-gen=$generation at=0)" \
    "failed: deck turn ended without a status line (arbitrary recovery-gen=$generation at=0)" \
    'failed: deck turn ended without a status line (turn-failed)' \
    'failed: tests failed'; do
    printf '%s\nworking [recovery-gen=%s]: later work\n' "$line" "$generation" > "$status"
    fm_turn_failed_superseded_line "$status" "$line" \
      && fail "a non-stamped exact turn-failed record was superseded: $line"
  done
  pass "turn-end, interrupted, legacy, and foreign failures stay failed"
}

test_failure_offset_identifies_the_exact_repeated_record() {
  local dir status generation first_offset second_offset first second
  dir=$(new_case repeated)
  status="$dir/state/task.status"
  : > "$status"
  generation=$(fm_recovery_marker_reserve_generation "$dir/state/.watcher-down") \
    || fail "could not reserve a recovery generation"
  first_offset=$(append_failure "$status" "$generation")
  first=$(failure_line "$generation" "$first_offset")
  printf 'working [recovery-gen=%s]: first replay resumed\n' "$generation" >> "$status"
  second_offset=$(append_failure "$status" "$generation")
  second=$(failure_line "$generation" "$second_offset")

  fm_turn_failed_superseded_line "$status" "$first" \
    || fail "the first repeated failure lost its later working evidence"
  fm_turn_failed_superseded_line "$status" "$second" \
    && fail "the later repeated failure borrowed the first failure's evidence"
  pass "byte offsets keep repeated failures independently ordered"
}

test_captured_endpoint_bounds_supersession_evidence() {
  local dir status generation offset failure failure_endpoint full_endpoint
  dir=$(new_case endpoint)
  status="$dir/state/task.status"
  : > "$status"
  generation=$(fm_recovery_marker_reserve_generation "$dir/state/.watcher-down") \
    || fail "could not reserve a recovery generation"
  offset=$(append_failure "$status" "$generation")
  failure=$(failure_line "$generation" "$offset")
  failure_endpoint=$(wc -c < "$status" | tr -d '[:space:]')
  printf 'working [recovery-gen=%s]: replay resumed\n' "$generation" >> "$status"
  full_endpoint=$(wc -c < "$status" | tr -d '[:space:]')

  fm_turn_failed_superseded_line "$status" "$failure" "$failure_endpoint" \
    && fail "working evidence beyond the captured endpoint changed the snapshot"
  fm_turn_failed_superseded_line "$status" "$failure" "$full_endpoint" \
    || fail "the full captured endpoint did not include its working evidence"
  pass "supersession respects the classifier's captured endpoint"
}

test_later_working_in_the_same_recovery_generation_supersedes
test_original_turn_state_cannot_supersede_before_replay
test_unbound_and_different_generation_working_lines_do_not_supersede
test_supersession_survives_idle_and_later_recovery_episodes
test_only_exact_turn_failed_records_participate
test_failure_offset_identifies_the_exact_repeated_record
test_captured_endpoint_bounds_supersession_evidence

echo "fm-deck-turn-failure-supersession: all cases passed"
