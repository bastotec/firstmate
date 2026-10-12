#!/usr/bin/env bash
# tests/fm-group.test.sh - ephemeral task groups: fan-out under the local cap,
# merge into one report, single-step cleanup that leaves no member process.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-group-tests)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
cat > "$HOME_DIR/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
export FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
mkdir -p "$HOME_DIR/config"
export FM_HOME="$HOME_DIR" FM_DECK_BIN="$ROOT/tests/assets/deck-crew-stub.py"
export DECK_STATE="$TMP_ROOT/deck" FM_CREW_WORK_ROOT="$TMP_ROOT/work" STUB_RUNNING_DIR="$TMP_ROOT/running"
GROUP="$ROOT/bin/fm-group.sh"

live_stubs() {  # <home>
  pgrep -f "deck-crew-stub.py run" | while read -r pid; do
    ps -o command= -p "$pid" 2>/dev/null | grep -q -- "$1\|$TMP_ROOT" && echo "$pid"
  done
}

out=$(STUB_SLEEP=0.6 FM_GROUP_LOCAL_MAX=5 "$GROUP" start pr-review --title "Review PR 12" --brief "Review https://example.test/pr/12" \
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
assert_contains "$(jq -r .summary "$REC")" "merged 5 member results" "the record carries the start of the merged result"
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
orch=$(jq -r .orchestrator_pid "$REC2")
out=$("$GROUP" cleanup stuck 2>&1) || fail "cleanup of a running group failed: $out"
assert_contains "$out" "no member processes left" "cleanup reports a clean group"
assert_equals cancelled "$(jq -r .status "$REC2")" "a cleaned running group is cancelled"
assert_equals "cancelled cancelled cancelled" "$(jq -r '[.members[].status] | join(" ")' "$REC2")" "every member is cancelled"
for _ in $(seq 1 30); do kill -0 "$orch" 2>/dev/null || break; sleep 0.1; done
kill -0 "$orch" 2>/dev/null && fail "cleanup must stop the orchestrator"
assert_equals "" "$(live_stubs "$HOME_DIR")" "no hanging member survives cleanup"
assert_absent "$HOME_DIR/state/groups/stuck" "cleanup removed the cancelled group's run files"
pass "cleanup stops a running group in one step with no stragglers"

expect_code 3 "$("$GROUP" start pr-review --brief x --angle y >/dev/null 2>&1; echo $?)" "a group id is single-use"
expect_code 2 "$("$GROUP" start other --brief x >/dev/null 2>&1; echo $?)" "a group needs angles"
pass "start validates its input"

"$GROUP" start unkillable --brief "x" --angle a --wait >/dev/null 2>&1 || fail "start unkillable group"
out=$(FM_CREW_TEST_SURVIVOR=999999 "$GROUP" cleanup unkillable 2>&1) && fail "a cleanup with survivors must fail"
assert_contains "$out" "captain hold requested" "cleanup says it raised a captain-held task"
assert_equals cleanup-failed "$(jq -r .status "$HOME_DIR/state/groups/unkillable.json")" "the group records the failed cleanup"
card="$HOME_DIR/state/cards/group-unkillable.json"
assert_present "$card" "a failed cleanup has a decision card"
assert_contains "$(jq -r .title "$card")" "left processes behind" "the card names the problem"
"$ROOT/bin/fm-captain-hold.sh" open group-unkillable || fail "the escalation must be held in the authoritative backlog"
assert_contains "$("$ROOT/bin/fm-card.sh" calls)" "group-unkillable" "normal captain-call discovery includes the group escalation"
out=$("$GROUP" cleanup unkillable 2>&1) || fail "a retried cleanup should succeed: $out"
assert_equals done "$(jq -r .status "$HOME_DIR/state/groups/unkillable.json")" "cleanup retry preserves the completed work outcome"
pass "a cleanup that cannot prove every member gone raises a captain-held task"

STUB_MERGE_MODE=fail "$GROUP" start merge-fails --brief x --angle a --wait >/dev/null 2>&1 && fail "a required merge failure must fail the group"
MERGE_REC="$HOME_DIR/state/groups/merge-fails.json"
assert_equals failed "$(jq -r .status "$MERGE_REC")" "a failed required merge is a failed group"
assert_equals false "$(jq -r .merge_succeeded "$MERGE_REC")" "merge success is recorded explicitly"
assert_grep "Merge failed" "$HOME_DIR/data/groups/merge-fails/report.md" "member evidence survives a merge failure"
pass "a missing merged answer cannot be reported as success"

for command in start cleanup; do
  args=("$command" pr-review)
  expect_code 3 "$(NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 "$GROUP" "${args[@]}" >/dev/null 2>&1; echo $?)" \
    "gate agents cannot invoke group $command"
done
pass "the gate boundary covers group lifecycle entrypoints"

before=$(find "$HOME_DIR/state/groups" -type f -print | sort | xargs shasum | shasum | awk '{print $1}')
expect_code 2 "$(FM_DECK_BIN="$TMP_ROOT/missing-deck" "$GROUP" start no-deck --brief x --angle a >/dev/null 2>&1; echo $?)" \
  "missing Deck is refused synchronously"
after=$(find "$HOME_DIR/state/groups" -type f -print | sort | xargs shasum | shasum | awk '{print $1}')
assert_equals "$before" "$after" "group launch preflight leaves no record"
pass "group launch dependencies are checked before mutation"

STUB_MERGE_MODE=hang "$GROUP" start merge-hangs --brief x --angle a >/dev/null 2>&1 || fail "start hanging merger"
HANG_REC="$HOME_DIR/state/groups/merge-hangs.json"
for _ in $(seq 1 80); do
  [ "$(jq -r .status "$HANG_REC")" = merging ] && [ -n "$(live_stubs "$HOME_DIR")" ] && break
  sleep 0.1
done
assert_equals merging "$(jq -r .status "$HANG_REC")" "the merger is active before cancellation"
merger=$(live_stubs "$HOME_DIR")
[ -n "$merger" ] || fail "the hanging merge must have a live process"
"$GROUP" cleanup merge-hangs >/dev/null 2>&1 || fail "cleanup hanging merger"
assert_equals "" "$(live_stubs "$HOME_DIR")" "cleanup stops the merger as well as the orchestrator"
assert_equals cancelled "$(jq -r .status "$HANG_REC")" "an interrupted merge is cancelled"
assert_absent "$HOME_DIR/state/groups/merge-hangs" "no merge files are deleted ahead of a surviving merger"
pass "cleanup covers the active merge process group"

STUB_MODE=hang "$GROUP" start cancelled-retry --brief x --angle a >/dev/null 2>&1 || fail "start cancellation retry"
CANCEL_REC="$HOME_DIR/state/groups/cancelled-retry.json"
for _ in $(seq 1 50); do
  [ "$(jq -r '.members[0].status' "$CANCEL_REC")" = running ] && break
  sleep 0.1
done
FM_CREW_TEST_SURVIVOR=999999 "$GROUP" cleanup cancelled-retry >/dev/null 2>&1 && fail "first cancellation proof must fail"
assert_equals cleanup-failed "$(jq -r .status "$CANCEL_REC")" "initial cancellation cleanup failed"
"$GROUP" cleanup cancelled-retry >/dev/null 2>&1 || fail "retry cancellation cleanup"
assert_equals cancelled "$(jq -r .status "$CANCEL_REC")" "retry does not turn cancelled work into done"
assert_equals null "$(jq -r .report "$CANCEL_REC")" "no successful report is fabricated by cleanup"
pass "cleanup outcome and work outcome stay independent"

unrelated=$(python3 -c 'import subprocess,sys; p=subprocess.Popen([sys.executable,"-c","import time; time.sleep(120)"],start_new_session=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL); print(p.pid)')
jq --argjson pid "$unrelated" '.members[0].pid=$pid | .members[0].identity={arguments:"former-worker",started:"former-start"}' \
  "$REC" > "$TMP_ROOT/reused.json"
mv "$TMP_ROOT/reused.json" "$REC"
"$GROUP" cleanup pr-review >/dev/null 2>&1 || fail "cleanup with a reused unrelated pid"
kill -0 "$unrelated" 2>/dev/null || fail "cleanup must never signal a reused unrelated pid"
kill "$unrelated" 2>/dev/null || true
assert_equals null "$(jq -r '.members[0].pid' "$REC")" "stale process targets are retired"
pass "historical pids cannot authorize signalling unrelated processes"

mkdir -p "$TMP_ROOT/fakebin"
export REAL_PS
REAL_PS=$(command -v ps)
export STUB_PAUSE_FILE="$TMP_ROOT/launch-paused"
cat > "$TMP_ROOT/fakebin/ps" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = 'lstart=,pgid=' ] && [ ! -e "$STUB_PAUSE_FILE" ]; then
  command=$("$REAL_PS" -o command= -p "${4:-0}")
  case "$command" in *deck-crew-stub.py*) touch "$STUB_PAUSE_FILE"; sleep 1 ;; esac
fi
exec "$REAL_PS" "$@"
EOF
chmod +x "$TMP_ROOT/fakebin/ps"
PATH="$TMP_ROOT/fakebin:$PATH" STUB_MODE=hang "$GROUP" start launch-race --brief x --angle a --angle b --angle c \
  >/dev/null 2>&1 || fail "start launch race"
for _ in $(seq 1 80); do [ -e "$STUB_PAUSE_FILE" ] && break; sleep 0.1; done
assert_present "$STUB_PAUSE_FILE" "the member launched before its identity registration paused"
"$GROUP" cleanup launch-race >/dev/null 2>&1 || fail "cleanup across paused registration"
assert_equals "" "$(live_stubs "$HOME_DIR")" "the launch-registration window cannot hide a member from cleanup"
assert_equals cancelled "$(jq -r .status "$HOME_DIR/state/groups/launch-race.json")" "the launch race converges to cancellation"
pass "launch and registration serialize against cancellation"

mkdir -p "$TMP_ROOT/vanishing"
cp "$ROOT/tests/assets/deck-crew-stub.py" "$TMP_ROOT/vanishing/deck-crew-stub.py"
FM_DECK_BIN="$TMP_ROOT/vanishing/deck-crew-stub.py" STUB_REMOVE_LAUNCHER=1 STUB_SLEEP=0.4 \
  "$GROUP" start launch-fails --brief x --angle a --angle b --angle c --wait >/dev/null 2>&1 && fail "a disappeared launcher must fail"
FAIL_REC="$HOME_DIR/state/groups/launch-fails.json"
assert_equals failed "$(jq -r .status "$FAIL_REC")" "a scheduling exception is finalized as failed"
assert_equals "[]" "$(jq -c .cleanup.survivors "$FAIL_REC")" "runtime failure cleans any already-launched members"
assert_equals "" "$(live_stubs "$HOME_DIR")" "runtime failure leaves no live workers"
assert_grep "check: task group launch-fails failed" "$HOME_DIR/state/.wake-queue" "runtime failure wakes the owner"
pass "runtime scheduling failure finalizes, cleans, and wakes"

for option in --remote --local-max --merge-brief --no-merge-agent; do
  args=("$option")
  [ "$option" = --no-merge-agent ] || args+=(3)
  expect_code 2 "$("$GROUP" start extras --brief x --angle a "${args[@]}" >/dev/null 2>&1; echo $?)" "unrequired option $option is not accepted"
done
pass "groups expose only local capped fan-out with a required merge"
