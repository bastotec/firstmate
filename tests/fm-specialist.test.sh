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
REC="$HOME_DIR/state/specialists/amigo-tech/record.json"

out=$("$SPEC" create amigo-tech --subject "Amigo Tech, a Docana customer" --project docana 2>&1) \
  || fail "create failed: $out"
assert_contains "$out" "created specialist amigo-tech" "create reports the specialist"
session=$(jq -r .session "$REC")
assert_equals true "$(jq -r .persistent "$REC")" "a specialist record is marked persistent"
assert_equals idle "$(jq -r .status "$REC")" "a new specialist is idle"
assert_present "$HOME_DIR/data/specialists/amigo-tech/memory.md" "create seeds the memory file"
assert_present "$HOME_DIR/data/specialists/amigo-tech/skills" "create makes the own-skills dir"
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
pkill -9 -f "deck-crew-stub.py run .*Hang\." 2>/dev/null || true
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
