#!/usr/bin/env bash
# Behavior tests for bin/fm-backlog-normalize.sh: done rows stranded outside
# "## Done" move there with their body lines, nothing else changes, --check
# reports without writing, and every idle-sweep scan heals its home.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

NORMALIZE="$ROOT/bin/fm-backlog-normalize.sh"
TMP_ROOT=$(fm_test_tmproot fm-backlog-normalize)

section_of() {  # <file> <id>
  awk -v id="$2" '/^## /{s=substr($0,4)} $0 ~ "^- \\[[ xX]\\] " id " " {print s; exit}' "$1"
}

write_misplaced() {  # <file>
  cat > "$1" <<'EOF'
# Backlog

## In flight
- [ ] live-work - Still running (kind: ship)
- [x] stale-flight - Finished in flight (done 2026-10-15)
  Outcome: merged https://github.com/o/r/pull/1

## Queued

- [ ] open-1 - Still queued
- [x] stale-call - Old call (done 2026-10-16) (hold: Captain call - pick one) (hold-kind: captain)
  Captain hold set: 2026-10-10
  second body line
- [ ] open-2 - Also queued

## Notes
- [x] note-row - A checked row under another heading stays

## Done
- [x] already-done - Done already (done 2026-10-17)
EOF
}

test_moves_done_rows_with_their_bodies() {
  local dir file before out
  dir="$TMP_ROOT/move"
  mkdir -p "$dir"
  file="$dir/backlog.md"
  write_misplaced "$file"
  before=$(sort "$file")
  out=$("$NORMALIZE" "$file") || fail "normalize failed: $out"
  assert_contains "$out" "moved 2 done row(s) into Done: stale-flight, stale-call" "the repair was not reported"
  assert_equals Done "$(section_of "$file" stale-call)" "a done row under Queued was not moved"
  assert_equals Done "$(section_of "$file" stale-flight)" "a done row under In flight was not moved"
  assert_equals Notes "$(section_of "$file" note-row)" "a checked row under another heading moved"
  assert_equals Queued "$(section_of "$file" open-2)" "an open row moved"
  assert_equals "In flight" "$(section_of "$file" live-work)" "an in-flight row moved"
  assert_equals "$before" "$(sort "$file")" "a line was lost or changed"
  assert_equals '  Captain hold set: 2026-10-10' "$(grep -A1 '^- \[x\] stale-call ' "$file" | tail -1)" \
    "the body did not travel with its row"
  assert_equals '- [x] already-done - Done already (done 2026-10-17)' "$(tail -1 "$file")" \
    "moved rows were not placed at the top of Done"
  out=$("$NORMALIZE" "$file") || fail "a second run failed"
  assert_equals "" "$out" "a clean backlog was reported as repaired"
  pass "done rows outside Done move there with their bodies, and nothing else changes"
}

test_check_reports_without_writing() {
  local dir file before rc=0 out
  dir="$TMP_ROOT/check"
  mkdir -p "$dir"
  file="$dir/backlog.md"
  write_misplaced "$file"
  before=$(cat "$file")
  out=$("$NORMALIZE" --check "$file") || rc=$?
  assert_equals 1 "$rc" "--check did not report misplaced rows"
  assert_contains "$out" "2 done row(s) outside Done" "--check did not name the count"
  assert_equals "$before" "$(cat "$file")" "--check rewrote the file"
  pass "--check reports misplaced done rows without rewriting"
}

test_missing_done_section_is_created() {
  local dir file
  dir="$TMP_ROOT/no-done"
  mkdir -p "$dir"
  file="$dir/backlog.md"
  printf '%s\n' '## Queued' '- [x] lone - Lone done row (done 2026-10-01)' '- [ ] open - Open' > "$file"
  "$NORMALIZE" --quiet "$file" || fail "normalize failed"
  assert_equals Done "$(section_of "$file" lone)" "no Done section was created for the row"
  assert_equals Queued "$(section_of "$file" open)" "the open row moved"
  pass "a backlog without a Done section gets one for its stranded done rows"
}

test_home_default_and_absent_file() {
  local home
  home="$TMP_ROOT/home-default"
  mkdir -p "$home/data"
  FM_HOME="$home" "$NORMALIZE" || fail "an absent backlog was an error"
  write_misplaced "$home/data/backlog.md"
  FM_HOME="$home" "$NORMALIZE" --quiet || fail "normalizing the home backlog failed"
  assert_equals Done "$(section_of "$home/data/backlog.md" stale-call)" "the home's own backlog was not normalized"
  pass "the default file is the home's backlog, and an absent one is fine"
}

test_idle_sweep_scan_heals_its_home() {
  local home
  home="$TMP_ROOT/sweep"
  mkdir -p "$home/data" "$home/state"
  write_misplaced "$home/data/backlog.md"
  FM_HOME="$home" "$ROOT/bin/fm-idle-sweep.sh" scan --now >/dev/null 2>&1 || true
  assert_equals Done "$(section_of "$home/data/backlog.md" stale-call)" "a sweep scan did not heal the backlog"
  assert_grep 'moved 2 done row(s) into Done' "$home/state/idle-sweep.log" "the sweep did not log the repair"
  pass "every idle-sweep scan moves this home's stranded done rows back to Done"
}

test_moves_done_rows_with_their_bodies
test_check_reports_without_writing
test_missing_done_section_is_created
test_home_default_and_absent_file
test_idle_sweep_scan_heals_its_home
