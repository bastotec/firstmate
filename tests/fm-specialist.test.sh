#!/usr/bin/env bash
# tests/fm-specialist.test.sh - persistent specialists: one Deck session resumed
# across jobs, memory read at start and required before finishing, own skills
# dir, history, wake on finish, retire.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-specialist-tests)
HOME_DIR="$TMP_ROOT/home"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data"
export FM_HOME="$HOME_DIR" FM_DECK_BIN="$ROOT/tests/assets/deck-crew-stub.py"
export DECK_STATE="$TMP_ROOT/deck" FM_CREW_WORK_ROOT="$TMP_ROOT/work"
SPEC="$ROOT/bin/fm-specialist.sh"
REC="$HOME_DIR/state/specialists/amigo-tech.json"

out=$("$SPEC" create amigo-tech --subject "Amigo Tech, a Docana customer" --project docana 2>&1) \
  || fail "create failed: $out"
assert_contains "$out" "created specialist amigo-tech" "create reports the specialist"
session=$(jq -r .session "$REC")
assert_equals true "$(jq -r .persistent "$REC")" "a specialist record is marked persistent"
assert_equals idle "$(jq -r .status "$REC")" "a new specialist is idle"
assert_present "$HOME_DIR/data/specialists/amigo-tech/memory.md" "create seeds the memory file"
assert_present "$HOME_DIR/data/specialists/amigo-tech/skills" "create makes the own-skills dir"
workdir=$(jq -r .workdir "$REC")
mkdir -p "$HOME_DIR/data/specialists/amigo-tech/skills/crew-owned-test"
printf '%s\n' '---' 'name: crew-owned-test' 'description: Specialist discovery fixture' '---' 'A specialist-owned skill.' \
  > "$HOME_DIR/data/specialists/amigo-tech/skills/crew-owned-test/SKILL.md"
assert_present "$workdir/.agents/skills/crew-owned-test/SKILL.md" "the supported discovery path exposes the owned skill"
if command -v deck >/dev/null 2>&1; then
  discovered=$(cd "$workdir" && env -u DECK_SKILLS_DIRS deck skills 2>&1) || fail "Deck skill discovery failed: $discovered"
  assert_contains "$discovered" "crew-owned-test" "the real Deck loader discovers the specialist skill"
fi
expect_code 3 "$("$SPEC" create amigo-tech --subject x >/dev/null 2>&1; echo $?)" "create refuses a duplicate"
pass "create writes a persistent idle record, memory and skills dir"

out=$("$SPEC" job amigo-tech --brief "Map their WhatsApp flow." --wait 2>&1) || fail "job 1 failed: $out"
job1=$(jq -r .last_job.id "$REC")
res1=$(cat "$(jq -r .last_job.result "$REC")")
assert_contains "$res1" "turns-in-session: 1" "first job opens the session"
assert_grep "learned in $job1" "$HOME_DIR/data/specialists/amigo-tech/memory.md" "job 1 updated memory"
pass "first job runs on the specialist session and updates memory"

out=$("$SPEC" job amigo-tech --brief-file <(printf 'Why did their bot stop replying?\n') --wait 2>&1) \
  || fail "job 2 failed: $out"
job2=$(jq -r .last_job.id "$REC")
res2=$(cat "$(jq -r .last_job.result "$REC")")
assert_not_equals "$job1" "$job2" "the second job is a new job"
assert_contains "$res2" "turns-in-session: 2" "second job resumed the same deck session"
assert_contains "$res2" "earlier-jobs: $job1" "second job sees the first job's turn in context"
assert_contains "$res2" "memory-seen-at-start: yes" "second job read the memory the first job wrote"
assert_grep "learned in $job2" "$HOME_DIR/data/specialists/amigo-tech/memory.md" "job 2 updated memory"
sessions=$(jq -r 'select(.ephemeral == false) | .session' "$DECK_STATE/argv.jsonl" | sort -u)
assert_equals "$session" "$sessions" "every job used the one recorded session"
skills=$(jq -r .skills "$DECK_STATE/argv.jsonl" | sort -u)
assert_equals "$HOME_DIR/data/specialists/amigo-tech/skills" "$skills" "jobs load the specialist's own skills dir"
cwd=$(jq -r .cwd "$DECK_STATE/argv.jsonl" | sort -u)
assert_contains "$cwd" "$TMP_ROOT/work/" "jobs run in a neutral workdir outside the home repo"
pass "second job resumes the session, sees job 1 and its memory"

assert_equals 2 "$(jq -r .jobs "$REC")" "the record counts both jobs"
assert_equals idle "$(jq -r .status "$REC")" "the specialist is idle between jobs"
assert_equals null "$(jq -r .current_job "$REC")" "no job is attached while idle"
assert_contains "$(jq -r .memory_summary "$REC")" "learned in" "the record carries a memory summary"
hist=$("$SPEC" history amigo-tech --json)
assert_equals "$job1 $job2" "$(printf '%s' "$hist" | jq -r 'map(.job) | join(" ")')" "history lists both jobs in order"
assert_equals "done done" "$(printf '%s' "$hist" | jq -r 'map(.outcome) | join(" ")')" "both jobs are done"
assert_grep "specialist:amigo-tech:$job1" "$HOME_DIR/state/.wake-queue" "job 1 woke the owner"
assert_grep "check: specialist amigo-tech finished job $job2 (done)" "$HOME_DIR/state/.wake-queue" "job 2 woke the owner"
status=$("$SPEC" status amigo-tech)
assert_contains "$status" "last job: $job2 done" "status shows the last job"
pass "record, history, status and owner wakes reflect both jobs"

out=$(STUB_MODE=lazy "$SPEC" job amigo-tech --brief "Do nothing." --wait 2>&1) && fail "a job that wrote nothing must fail"
assert_equals failed "$(jq -r .last_job.outcome "$REC")" "a refused job is recorded as failed"
assert_equals idle "$(jq -r .status "$REC")" "a failed job leaves the specialist idle"
pass "a job that skips its result and memory is refused and recorded as failed"

STUB_MODE=hang "$SPEC" job amigo-tech --brief "Hang." >/dev/null 2>&1 || fail "starting a hanging job failed"
expect_code 3 "$("$SPEC" job amigo-tech --brief again >/dev/null 2>&1; echo $?)" "a busy specialist refuses a second job"
expect_code 3 "$("$SPEC" retire amigo-tech >/dev/null 2>&1; echo $?)" "retire refuses a running job"
pid=$(jq -r .current_job.pid "$REC")
fm_test_kill_tree "$pid" >/dev/null 2>&1 || kill -9 "$pid" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
assert_equals idle "$("$SPEC" status amigo-tech --json | jq -r .status)" "a dead runner is reconciled to idle"
assert_equals interrupted "$(jq -r .last_job.outcome "$REC")" "the killed job is recorded as interrupted"
pass "one job at a time; a dead runner is reconciled"

"$SPEC" retire amigo-tech >/dev/null || fail "retire failed"
assert_equals retired "$(jq -r .status "$REC")" "retire marks the record"
assert_present "$HOME_DIR/data/specialists/amigo-tech/memory.md" "retire keeps the memory"
assert_equals "" "$("$SPEC" list)" "list hides retired specialists"
expect_code 3 "$("$SPEC" job amigo-tech --brief x >/dev/null 2>&1; echo $?)" "a retired specialist takes no jobs"
pass "retire keeps memory and stops new jobs"
assert_present "$DECK_STATE/sessions/$session.json" "retirement keeps the conversation"
expect_code 2 "$("$SPEC" retire amigo-tech --purge-session >/dev/null 2>&1; echo $?)" "retirement cannot delete the conversation"

"$SPEC" create memory-check --subject "memory enforcement" >/dev/null || fail "create memory-check"
MEM_REC="$HOME_DIR/state/specialists/memory-check.json"
out=$(STUB_MODE=result-only "$SPEC" job memory-check --brief "Write only a result" --wait 2>&1) && fail "seeded memory must not satisfy the first job's update check"
assert_equals failed "$(jq -r .last_job.outcome "$MEM_REC")" "a result without a memory write fails immediately after create"
"$SPEC" job memory-check --brief "Update both" --wait >/dev/null 2>&1 || fail "memory-check successful job"
out=$(STUB_MODE=result-only "$SPEC" job memory-check --brief "Write only a result again" --wait 2>&1) && fail "the previous job's memory must not satisfy this job"
assert_equals failed "$(jq -r .last_job.outcome "$MEM_REC")" "each job requires its own memory update"
pass "unchanged memory cannot satisfy a new job"
"$SPEC" job memory-check --brief "Successful predecessor" --wait >/dev/null 2>&1 || fail "the timeout regression needs a successful previous result"

out=$(STUB_MODE=hang "$SPEC" job memory-check --brief "Wait timeout" --wait --wait-timeout 1 2>&1) && fail "a timed-out wait must fail"
assert_contains "$out" "wait timed out" "a timeout is explicit"
assert_equals running "$(jq -r .status "$MEM_REC")" "timeout does not claim the old result or end the job"
pid=$(jq -r .current_job.pid "$MEM_REC")
fm_test_kill_tree "$pid" >/dev/null 2>&1 || kill -9 "$pid" 2>/dev/null
"$SPEC" status memory-check >/dev/null || fail "reconcile timed-out job"
pass "a hanging job cannot reuse an earlier completion"

before=$(jq -c . "$MEM_REC")
expect_code 2 "$(FM_DECK_BIN="$TMP_ROOT/missing-deck" "$SPEC" job memory-check --brief x >/dev/null 2>&1; echo $?)" "missing Deck is refused synchronously"
assert_equals "$before" "$(jq -c . "$MEM_REC")" "launch preflight leaves the specialist unchanged"
printf '%s\n' 'not an executable format' > "$TMP_ROOT/broken-deck"
chmod +x "$TMP_ROOT/broken-deck"
out=$(FM_DECK_BIN="$TMP_ROOT/broken-deck" "$SPEC" job memory-check --brief "Launch exception" --wait 2>&1) && fail "a runtime launch exception must fail"
failed_job=$(jq -r .last_job.id "$MEM_REC")
assert_equals idle "$(jq -r .status "$MEM_REC")" "launch exceptions leave the specialist idle"
assert_equals failed "$(jq -r .last_job.outcome "$MEM_REC")" "launch exceptions finalize failed history"
assert_grep "specialist:memory-check:$failed_job" "$HOME_DIR/state/.wake-queue" "launch exceptions wake the owner"
pass "preflight and runtime launch failure keep owned records coherent"

for command in create job status history list retire; do
  args=("$command")
  [ "$command" = list ] || args+=(memory-check)
  [ "$command" != create ] || args+=(--subject x)
  expect_code 3 "$(NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 "$SPEC" "${args[@]}" \
    >/dev/null 2>&1; echo $?)" "gate agents cannot invoke specialist $command"
done
pass "the gate boundary covers reconciliation and specialist mutations"
