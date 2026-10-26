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
  [ ! -e "$file.lock" ] || fail "a successful repair left its lock behind"
  out=$("$NORMALIZE" "$file") || fail "a second run failed"
  assert_equals "" "$out" "a clean backlog was reported as repaired"
  [ ! -e "$file.lock" ] || fail "a clean run left its lock behind"
  pass "done rows outside Done move there with their bodies, and nothing else changes"
}

test_multi_paragraph_body_moves_with_internal_blanks() {
  local dir file
  dir="$TMP_ROOT/paragraphs"
  mkdir -p "$dir"
  file="$dir/backlog.md"
  cat > "$file" <<'EOF'
## Queued
- [ ] open - Still queued
- [x] closed - Finished
  First paragraph


  Outcome: merged https://github.com/o/r/pull/2

  Final paragraph


Column-zero text stays here
- [x] another - Also finished
  Another body

- [ ] next - Also queued

## Done
- [x] existing - Previously finished
EOF
  cat > "$dir/expected.md" <<'EOF'
## Queued
- [ ] open - Still queued


Column-zero text stays here

- [ ] next - Also queued

## Done
- [x] closed - Finished
  First paragraph


  Outcome: merged https://github.com/o/r/pull/2

  Final paragraph
- [x] another - Also finished
  Another body
- [x] existing - Previously finished
EOF
  "$NORMALIZE" --quiet "$file" || fail "multi-paragraph normalization failed"
  cmp -s "$dir/expected.md" "$file" || fail "internal paragraphs did not move intact or trailing blanks moved"
  pass "multi-paragraph bodies move whole while trailing blanks and column-zero content stay"
}

test_held_backlog_lock_skips_without_writing() {
  local dir file before out
  dir="$TMP_ROOT/locked"
  mkdir -p "$dir"
  file="$dir/backlog.md"
  write_misplaced "$file"
  before=$(cksum < "$file")
  printf '%s\n' "$$:held-by-tasks-axi" > "$file.lock"
  out=$("$NORMALIZE" "$file" 2>&1) || fail "a held backlog lock was an error: $out"
  assert_equals "" "$out" "a held backlog lock was not skipped quietly"
  assert_equals "$before" "$(cksum < "$file")" "normalization wrote through a held backlog lock"
  assert_equals "$$:held-by-tasks-axi" "$(cat "$file.lock")" "another writer's lock was changed or removed"
  rm "$file.lock"
  "$NORMALIZE" --quiet "$file" || fail "repair after releasing the lock failed"
  assert_equals Done "$(section_of "$file" stale-call)" "the unlocked run did not repair the row"
  [ ! -e "$file.lock" ] || fail "the normalizer left its lock behind"
  pass "a held tasks-axi backlog lock skips repair quietly until a later run"
}

test_dead_writer_lock_is_reclaimed() {
  local dir file dead out
  dir="$TMP_ROOT/dead-lock"
  mkdir -p "$dir"
  file="$dir/backlog.md"
  write_misplaced "$file"
  # a writer killed while holding the lock: its pid no longer exists
  sh -c 'exit 0' &
  dead=$!
  wait "$dead"
  printf '%s\n' "$dead:1792917802:24048:31608" > "$file.lock"
  out=$("$NORMALIZE" --quiet "$file" 2>&1) || fail "a dead writer's lock was an error: $out"
  assert_equals Done "$(section_of "$file" stale-call)" "a dead writer's lock still blocked the repair"
  [ ! -e "$file.lock" ] || fail "the reclaimed lock was left behind"
  printf '%s\n' "$dead:tasks-axi-nonce:1792917802000:1" > "$file.lock"
  "$NORMALIZE" --quiet "$file" || fail "a dead tasks-axi lock was an error"
  [ ! -e "$file.lock" ] || fail "a dead tasks-axi writer's lock was not reclaimed"
  printf '%s\n' "not-a-pid-token" > "$file.lock"
  "$NORMALIZE" --quiet "$file" || fail "an unparsable lock was an error"
  assert_equals "not-a-pid-token" "$(cat "$file.lock")" "a lock without a writer pid was removed"
  rm -f "$file.lock"
  pass "a lock left by a writer that no longer exists is reclaimed; live or unparsable locks are kept"
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

test_normalization_preserves_permissions() {
  local dir file mode
  dir="$TMP_ROOT/permissions"
  mkdir -p "$dir/fakebin"
  file="$dir/backlog.md"
  write_misplaced "$file"
  chmod 644 "$file"
  "$NORMALIZE" --quiet "$file" || fail "normalization failed"
  mode=$(perl -e 'printf "%o", (stat $ARGV[0])[2] & 07777' "$file")
  assert_equals 644 "$mode" "normalization changed the backlog's permissions"
  write_misplaced "$file"
  cat > "$dir/fakebin/stat" <<'SH'
#!/usr/bin/env bash
case "$1" in
  -f) printf 'File: %s\nFilesystem information\n' "$3"; exit 1 ;;
  -c) exec perl -e 'printf "%o\n", (stat $ARGV[0])[2] & 07777' "$3" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/fakebin/stat"
  PATH="$dir/fakebin:$PATH" "$NORMALIZE" --quiet "$file" || fail "stat fallback normalization failed"
  mode=$(perl -e 'printf "%o", (stat $ARGV[0])[2] & 07777' "$file")
  assert_equals 644 "$mode" "failed stat stdout contaminated the fallback mode"
  assert_equals Done "$(section_of "$file" stale-call)" "the fallback did not publish the repaired backlog"
  pass "normalization preserves permissions even when the first stat form fails with stdout"
}

test_automatic_normalization_respects_data_authorization() {
  local home foreign before out
  home="$TMP_ROOT/contained-home"
  foreign="$TMP_ROOT/foreign-home"
  mkdir -p "$home/state" "$foreign/data"
  write_misplaced "$foreign/data/backlog.md"
  ln -s "$foreign/data" "$home/data"
  before=$(cksum < "$foreign/data/backlog.md")
  FM_HOME="$home" "$ROOT/bin/fm-idle-sweep.sh" scan --now >/dev/null 2>&1 || true
  assert_equals "$before" "$(cksum < "$foreign/data/backlog.md")" "the sweep rewrote another home's backlog"
  if [ -f "$home/state/idle-sweep.log" ]; then
    assert_not_contains "$(cat "$home/state/idle-sweep.log")" stale-call "the sweep logged a foreign task ID"
  fi
  out=$(FM_HOME="$home" bash -c '
    . "$1/bin/fm-tasks-axi-lib.sh"
    . "$1/bin/fm-backlog-transition-lib.sh"
    fm_backlog_tasks_axi_addressing "$FM_HOME/data"
  ' _ "$ROOT" 2>&1) || fail "addressing changed its refusal behavior: $out"
  assert_equals "$before" "$(cksum < "$foreign/data/backlog.md")" "the shared boundary normalized through a cross-home symlink"
  FM_HOME="$home" FM_DATA_OVERRIDE="$foreign/data" "$ROOT/bin/fm-idle-sweep.sh" scan --now >/dev/null 2>&1 || true
  assert_equals Done "$(section_of "$foreign/data/backlog.md" stale-call)" "the sweep skipped explicitly authorized relocated data"
  assert_grep 'moved 2 done row(s) into Done' "$home/state/idle-sweep.log" "the relocated repair was not logged"
  pass "automatic repair skips cross-home data symlinks and retains explicitly authorized relocated data"
}

test_captain_answer_heals_before_any_sweep() {
  local home out rc=0 show
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: captain answer regression requires tasks-axi"; return; }
  home="$TMP_ROOT/captain-answer"
  mkdir -p "$home/data" "$home/state" "$home/config"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  write_misplaced "$home/data/backlog.md"
  printf 'Keep the completed outcome.\n' > "$home/decision.txt"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answer stale-call \
    --decision-file "$home/decision.txt" --release 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "--release reopened completed work"
  assert_contains "$out" "already closed; --release cannot reopen it" "the checked row was still reported absent rather than closed"
  assert_equals Done "$(section_of "$home/data/backlog.md" stale-call)" "the captain read did not heal the row"
  out=$(FM_HOME="$home" "$ROOT/bin/fm-captain-hold.sh" answer stale-call \
    --decision-file "$home/decision.txt" 2>&1) || fail "the retroactive captain answer failed: $out"
  assert_contains "$out" "repaired: stale-call" "the answer did not repair the closed captain call"
  show=$(tasks-axi show stale-call --full --file "$home/data/backlog.md") || fail "the answered task disappeared"
  assert_contains "$show" "Resolution mode: repaired" "the captain answer was not persisted"
  assert_contains "$show" "Keep the completed outcome." "the captain's decision was lost"
  pass "captain answers heal misplaced completed rows without weakening the closed-task release refusal"
}

test_lifecycle_transition_heals_before_mutating() {
  local home out
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: lifecycle regression requires tasks-axi"; return; }
  home="$TMP_ROOT/lifecycle"
  mkdir -p "$home/data"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  write_misplaced "$home/data/backlog.md"
  out=$(FM_HOME="$home" bash -c '
    . "$1/bin/fm-tasks-axi-lib.sh"
    . "$1/bin/fm-backlog-transition-lib.sh"
    fm_backlog_done "$FM_HOME/data" stale-flight --note "Completion reconciled"
  ' _ "$ROOT" 2>&1) || fail "lifecycle completion could not find the checked row: $out"
  assert_equals Done "$(section_of "$home/data/backlog.md" stale-flight)" "lifecycle completion left the row outside Done"
  assert_grep 'Completion reconciled' "$home/data/backlog.md" "the lifecycle completion was not persisted"
  pass "lifecycle transitions heal misplaced checked rows before tasks-axi mutations"
}

test_moves_done_rows_with_their_bodies
test_multi_paragraph_body_moves_with_internal_blanks
test_held_backlog_lock_skips_without_writing
test_dead_writer_lock_is_reclaimed
test_check_reports_without_writing
test_missing_done_section_is_created
test_home_default_and_absent_file
test_idle_sweep_scan_heals_its_home
test_normalization_preserves_permissions
test_automatic_normalization_respects_data_authorization
test_captain_answer_heals_before_any_sweep
test_lifecycle_transition_heals_before_mutating
