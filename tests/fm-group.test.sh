#!/usr/bin/env bash
# tests/fm-group.test.sh - ephemeral task groups: fan-out under the local cap,
# merge into one report, single-step cleanup that leaves no member process.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-group-tests)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
export FM_HOME="$HOME_DIR" FM_DECK_BIN="$ROOT/tests/assets/deck-crew-stub.py"
export DECK_STATE="$TMP_ROOT/deck" FM_CREW_WORK_ROOT="$TMP_ROOT/work" STUB_RUNNING_DIR="$TMP_ROOT/running"
GROUP="$ROOT/bin/fm-group.sh"

live_stubs() {  # <home>
  pgrep -f "deck-crew-stub.py run" | while read -r pid; do
    ps -o command= -p "$pid" 2>/dev/null | grep -q -- "$1\|$TMP_ROOT" && echo "$pid"
  done
}

out=$(STUB_SLEEP=0.6 "$GROUP" start pr-review --title "Review PR 12" --brief "Review https://example.test/pr/12" \
  --angle "security" --angle "correctness" --angle "tests" --angle "performance" --angle "docs" --wait 2>&1) \
  || fail "group run failed: $out"
REC="$HOME_DIR/state/groups/pr-review.json"
assert_contains "$out" "task group pr-review done" "the group finished"
assert_equals "done" "$(jq -r .status "$REC")" "the record says done"
assert_equals 5 "$(jq -r '[.members[] | select(.status == "done")] | length' "$REC")" "all five members finished"
assert_equals "local" "$(jq -r '[.members[].placement] | unique | join(",")' "$REC")" "members ran locally without a remote route"
max=$(sort -n "$DECK_STATE/concurrency.log" | tail -1)
[ "$max" -le 2 ] || fail "at most two members may run locally at once (saw $max)"
assert_equals 6 "$(jq -s 'map(select(.ephemeral)) | length' "$DECK_STATE/argv.jsonl")" "five members and one merge ran ephemeral"
pass "five members fan out with at most two local at once"

report=$(jq -r .report "$REC")
assert_equals "$HOME_DIR/data/groups/pr-review/report.md" "$report" "the report is kept in data"
assert_grep "merged 5 member results" "$report" "the merge saw all five results"
assert_grep "angle: security" "$report" "member results are appended to the report"
assert_grep "angle: docs" "$report" "every angle is in the report"
assert_present "$HOME_DIR/data/groups/pr-review/members/m3.md" "member results are kept after cleanup"
pass "results merge into one report"

assert_absent "$HOME_DIR/state/groups/pr-review" "cleanup removed the run files"
[ -z "$(find "$TMP_ROOT/work" -path "*/groups/pr-review" 2>/dev/null)" ] || fail "cleanup removed member workdirs"
assert_equals "[]" "$(jq -c .cleanup.survivors "$REC")" "cleanup proved no survivors"
assert_equals "" "$(live_stubs "$HOME_DIR")" "no member process is left"
assert_equals "" "$("$GROUP" status pr-review --json | jq -r '.live_members | join(",")')" "status reports no live members"
assert_grep "check: task group pr-review done (5/5 members)" "$HOME_DIR/state/.wake-queue" "the owner got one wake"
pass "the group cleans itself up in the same step and wakes the owner"

STUB_MODE=hang "$GROUP" start stuck --brief "Hang" --angle a --angle b --angle c >/dev/null || fail "start stuck group"
REC2="$HOME_DIR/state/groups/stuck.json"
for _ in $(seq 1 50); do
  [ "$(jq '[.members[] | select(.status == "running")] | length' "$REC2")" = 2 ] && break
  sleep 0.1
done
assert_equals 2 "$(jq '[.members[] | select(.status == "running")] | length' "$REC2")" "two members run, one waits"
out=$("$GROUP" cleanup stuck 2>&1) || fail "cleanup of a running group failed: $out"
assert_contains "$out" "no member processes left" "cleanup reports a clean group"
assert_equals cancelled "$(jq -r .status "$REC2")" "a cleaned running group is cancelled"
assert_equals "cancelled cancelled cancelled" "$(jq -r '[.members[].status] | join(" ")' "$REC2")" "every member is cancelled"
orch=$(jq -r .orchestrator_pid "$REC2")
for _ in $(seq 1 30); do kill -0 "$orch" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orch" 2>/dev/null && fail "cleanup must stop the orchestrator"
assert_equals "" "$(live_stubs "$HOME_DIR")" "no hanging member survives cleanup"
assert_absent "$HOME_DIR/state/groups/stuck" "cleanup removed the cancelled group's run files"
pass "cleanup stops a running group in one step with no stragglers"

expect_code 3 "$("$GROUP" start pr-review --brief x --angle y >/dev/null 2>&1; echo $?)" "a group id is single-use"
expect_code 2 "$("$GROUP" start other --brief x >/dev/null 2>&1; echo $?)" "a group needs angles"
pass "start validates its input"

"$GROUP" start unkillable --brief "x" --angle a --no-merge-agent --wait >/dev/null 2>&1 || fail "start unkillable group"
out=$(FM_CREW_TEST_SURVIVOR=999999 "$GROUP" cleanup unkillable 2>&1) && fail "a cleanup with survivors must fail"
assert_contains "$out" "raised a decision card" "cleanup says it raised a decision card"
assert_equals cleanup-failed "$(jq -r .status "$HOME_DIR/state/groups/unkillable.json")" "the group records the failed cleanup"
card="$HOME_DIR/state/cards/group-unkillable.json"
assert_present "$card" "a failed cleanup becomes a decision card"
assert_contains "$(jq -r .title "$card")" "left processes behind" "the card names the problem"
out=$("$GROUP" cleanup unkillable 2>&1) || fail "a retried cleanup should succeed: $out"
pass "a cleanup that cannot prove every member gone raises a decision card"
