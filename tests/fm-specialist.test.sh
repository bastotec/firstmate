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
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/config"
export FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data"
export FM_HOME="$HOME_DIR" FM_DECK_BIN="$ROOT/tests/assets/deck-crew-stub.py"
export DECK_STATE="$TMP_ROOT/deck" FM_CREW_WORK_ROOT="$TMP_ROOT/work"
SPEC="$ROOT/bin/fm-specialist.sh"
REC="$HOME_DIR/state/specialists/amigo-tech.json"

assert_specialist_private() {
  python3 - "$HOME_DIR" "$1" <<'PY' || fail "existing specialist permissions must be private"
import stat
import sys
from pathlib import Path
home = Path(sys.argv[1])
state = home / "state/specialists" / sys.argv[2]
data = home / "data/specialists" / sys.argv[2]
for path, mode in ((state, 0o700), (data, 0o700),
                   (state / "history.jsonl", 0o600), (data / "memory.md", 0o600)):
    assert stat.S_IMODE(path.stat().st_mode) == mode, path
PY
}

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
python3 - "$HOME_DIR/state/specialists/amigo-tech/jobs/$job1" <<'PY' || fail "specialist job artifacts must be private"
import stat
import sys
from pathlib import Path
for name in ("brief.md", "prompt.md", "result.md"):
    path = Path(sys.argv[1]) / name
    assert stat.S_IMODE(path.stat().st_mode) == 0o600, path
PY
pass "specialist briefs, prompts and results are private"

chmod 755 "$HOME_DIR/state/specialists/amigo-tech" "$HOME_DIR/data/specialists/amigo-tech"
chmod 644 "$HOME_DIR/state/specialists/amigo-tech/history.jsonl" "$HOME_DIR/data/specialists/amigo-tech/memory.md"
out=$("$SPEC" job amigo-tech --brief-file <(printf 'Why did their bot stop replying?\n') --wait 2>&1) \
  || fail "job 2 failed: $out"
assert_specialist_private amigo-tech
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
chmod 755 "$HOME_DIR/state/specialists/amigo-tech" "$HOME_DIR/data/specialists/amigo-tech"
chmod 644 "$HOME_DIR/state/specialists/amigo-tech/history.jsonl" "$HOME_DIR/data/specialists/amigo-tech/memory.md"
assert_equals idle "$("$SPEC" status amigo-tech --json | jq -r .status)" "a dead runner is reconciled to idle"
assert_specialist_private amigo-tech
assert_equals interrupted "$(jq -r .last_job.outcome "$REC")" "the killed job is recorded as interrupted"
interrupted_job=$(jq -r .last_job.id "$REC")
assert_grep "specialist:amigo-tech:$interrupted_job" "$HOME_DIR/state/.wake-queue" "reconciliation wakes the owner of the interrupted job"
"$SPEC" history amigo-tech >/dev/null || fail "history after interruption"
"$SPEC" list >/dev/null || fail "list after interruption"
assert_equals 1 "$(grep -c "specialist:amigo-tech:$interrupted_job" "$HOME_DIR/state/.wake-queue")" "repeated reconciliation emits only one interruption wake"
assert_equals 1 "$(grep -c "specialist:amigo-tech:$job1" "$HOME_DIR/state/.wake-queue")" "normal completion emits only one wake"
pass "one job at a time; a dead runner is reconciled and wakes once"

expect_code 2 "$("$SPEC" suspend amigo-tech --reason "x" --since yesterday >/dev/null 2>&1; echo $?)" "a malformed --since is refused"
"$SPEC" suspend amigo-tech --reason "jobs kept calling tools after a failed call" --since 2026-10-17T10:40:02Z --by main >/dev/null \
  || fail "suspend failed"
assert_equals suspended "$(jq -r .status "$REC")" "suspend does not mark the record"
assert_equals "1792233602 jobs kept calling tools after a failed call main" \
  "$(jq -r '"\(.suspension.since) \(.suspension.reason) \(.suspension.by)"' "$REC")" "the suspension's since, reason and by were not recorded"
assert_contains "$("$SPEC" status amigo-tech)" "suspended since 2026-10-17T10:40:02Z by main: jobs kept calling tools" "status hides the suspension"
assert_contains "$("$SPEC" list)" $'amigo-tech\tsuspended' "list hides the suspension"
expect_code 4 "$("$SPEC" job amigo-tech --brief "Scheduled sweep." >/dev/null 2>&1; echo $?)" "a suspended specialist took a job"
out=$("$SPEC" job amigo-tech --brief "Scheduled sweep." 2>&1)
assert_contains "$out" "suspended since 2026-10-17T10:40:02Z: jobs kept calling tools after a failed call" "the refusal does not say why"
"$SPEC" resume amigo-tech --by captain >/dev/null || fail "resume failed"
assert_equals idle "$(jq -r .status "$REC")" "resume does not return the specialist to idle"
assert_equals "null captain" "$(jq -r '"\(.suspension) \(.last_suspension.resumed_by)"' "$REC")" "resume does not keep the ended suspension"
expect_code 3 "$("$SPEC" resume amigo-tech >/dev/null 2>&1; echo $?)" "resuming an idle specialist was accepted"
pass "suspend records why and since when, job refuses while suspended, and resume returns it to idle"

expect_code 2 "$("$SPEC" ask amigo-tech -- "hello" >/dev/null 2>&1; echo $?)" "ask without --from-captain was accepted"
out=$("$SPEC" ask amigo-tech --from-captain --wait -- "How is Amigo doing this week?" 2>&1) || fail "captain ask failed: $out"
ask_job=$(jq -r .last_job.id "$REC")
assert_equals captain "$(jq -r .last_job.from "$REC")" "the job is not marked as from the captain"
assert_equals captain "$(tail -1 "$HOME_DIR/state/specialists/amigo-tech/history.jsonl" | jq -r .from)" "history does not mark the captain's job"
assert_equals "How is Amigo doing this week?" "$(tail -1 "$HOME_DIR/state/specialists/amigo-tech/history.jsonl" | jq -r .message | tr -d '\n')" "history does not keep his exact words"
assert_equals "How is Amigo doing this week?" "$(jq -r .last_job.message "$REC" | tr -d '\n')" "last_job does not keep his exact words"
assert_grep "How is Amigo doing this week?" "$HOME_DIR/state/specialists/amigo-tech/jobs/$ask_job/brief.md" "the captain's words are not the brief"
assert_grep "read-only monitor stays read-only" "$HOME_DIR/state/specialists/amigo-tech/jobs/$ask_job/brief.md" "the brief drops the specialist's bounds"
assert_grep "specialist-captain:amigo-tech:$ask_job" "$HOME_DIR/state/.wake-queue" "the owning home was not told about the captain's message"
assert_grep "the captain asked specialist amigo-tech directly (job $ask_job): How is Amigo doing this week?" "$HOME_DIR/state/.wake-queue" "the owner's notice lost the question"
assert_equals "$(cat "$(jq -r .last_job.result "$REC")")" "$("$SPEC" result amigo-tech)" "result does not print the last job's result"
assert_equals "$(cat "$(jq -r .last_job.result "$REC")")" "$("$SPEC" result amigo-tech "$ask_job")" "result does not print a named job's result"
"$SPEC" suspend amigo-tech --reason "paused" >/dev/null || fail "suspend failed"
expect_code 4 "$("$SPEC" ask amigo-tech --from-captain -- "still there?" >/dev/null 2>&1; echo $?)" "a suspended specialist took a captain message"
"$SPEC" resume amigo-tech >/dev/null || fail "resume failed"
pass "a captain message runs one job on the specialist's session, marked from him, tells the owner, and its result is readable"

PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY/state"
printf 'kind=secondmate\nhome=%s\n' "$HOME_DIR" > "$PRIMARY/state/mate-local.meta"
out=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$PRIMARY" "$SPEC" status amigo-tech --mate mate-local) \
  || fail "status through a local mate failed: $out"
assert_contains "$out" "specialist amigo-tech (idle)" "--mate did not run in the local mate's home"
ROUTE_BIN="$TMP_ROOT/route-bin"
mkdir -p "$ROUTE_BIN"
cp "$ROOT/bin/fm-specialist.sh" "$ROUTE_BIN/"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/fm-on.args"\n' "$TMP_ROOT" > "$ROUTE_BIN/fm-on.sh"
chmod +x "$ROUTE_BIN/fm-on.sh"
printf 'kind=secondmate\nremote_host=workload\nhome=/remote/home\n' > "$PRIMARY/state/mate-remote.meta"
env -u FM_STATE_OVERRIDE FM_HOME="$PRIMARY" "$ROUTE_BIN/fm-specialist.sh" ask linkana --mate mate-remote --from-captain -- "any new errors?" \
  || fail "a remote ask did not route"
assert_equals $'mate-remote\nfm-specialist.sh\nask\nlinkana\n--from-captain\n--\nany new errors?' "$(cat "$TMP_ROOT/fm-on.args")" \
  "a remote mate's ask was not sent through fm-on.sh"
expect_code 2 "$(env -u FM_STATE_OVERRIDE FM_HOME="$PRIMARY" "$ROUTE_BIN/fm-specialist.sh" ask linkana --mate mate-remote --from-captain --text-file /tmp/x >/dev/null 2>&1; echo $?)" \
  "--text-file was sent to a remote mate"
expect_code 2 "$(env -u FM_STATE_OVERRIDE FM_HOME="$PRIMARY" "$SPEC" status amigo-tech --mate nobody >/dev/null 2>&1; echo $?)" "an unknown mate was accepted"
pass "--mate runs ask, result and status in a local mate's home or through fm-on.sh for a remote one"

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

for identity_case in mismatched-pid reused-nonleader; do
  STUB_MODE=hang "$SPEC" job memory-check --brief "Reused runner pid" >/dev/null 2>&1 || fail "start reused-pid job"
  stale_job=$(jq -r .current_job.id "$MEM_REC")
  pid=$(jq -r .current_job.pid "$MEM_REC")
  fm_test_kill_tree "$pid" >/dev/null 2>&1 || kill -9 "$pid" 2>/dev/null
  unrelated=$(python3 - "$identity_case" <<'PY'
import subprocess
import sys
worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"],
                          start_new_session=sys.argv[1] == "mismatched-pid",
                          stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
print(worker.pid)
PY
)
  fm_test_track_helper_pid "$unrelated"
  jq --argjson pid "$unrelated" --arg identity_case "$identity_case" \
    '.current_job.pid=$pid | if $identity_case == "reused-nonleader" then .current_job.identity.pid=$pid else . end' \
    "$MEM_REC" > "$TMP_ROOT/reused.json"
  mv "$TMP_ROOT/reused.json" "$MEM_REC"
  if [ "$identity_case" = reused-nonleader ]; then
    python3 - "$ROOT" "$MEM_REC" <<'PY' || fail "nonleader reuse must differ from an unreadable snapshot"
import importlib.util
import json
import os
import sys
from pathlib import Path
from unittest.mock import patch
spec = importlib.util.spec_from_file_location("fm_crew", Path(sys.argv[1]) / "bin/fm_crew.py")
crew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crew)
rec = json.loads(Path(sys.argv[2]).read_text())
cur = rec["current_job"]
assert cur["identity"]["pid"] == cur["pid"]
assert os.getpgid(cur["pid"]) != cur["pid"], "the reused process must not lead its group"
specialist = crew.Specialist(Path(rec["home"]), rec["name"])
with patch.object(crew, "process_identity", return_value=None):
    assert crew.target_state(cur["pid"], cur["identity"]) == "unknown"
    assert specialist.runner_alive(cur), "an unreadable live runner must remain busy"
assert crew.target_state(cur["pid"], cur["identity"]) == "unrelated"
assert not specialist.runner_alive(cur), "a nonleader reuse must not remain busy"
PY
  fi
  assert_equals idle "$("$SPEC" list --json | jq -r '.[] | select(.name == "memory-check") | .status')" "a reused live pid cannot keep a specialist busy"
  kill -0 "$unrelated" 2>/dev/null || fail "reconciliation must not signal an unrelated process group"
  assert_equals interrupted "$(jq -r .last_job.outcome "$MEM_REC")" "a reused runner pid finalizes the interrupted job"
  assert_grep "specialist:memory-check:$stale_job" "$HOME_DIR/state/.wake-queue" "reused-pid reconciliation emits a completion wake"
  "$SPEC" job memory-check --brief "Recovery succeeded" --wait >/dev/null 2>&1 || fail "reused pid must not block new work"
  kill "$unrelated" 2>/dev/null || true
  pass "$identity_case cannot block work or authorize signals"
done

STUB_MODE=hang "$SPEC" job memory-check --brief "Orphaned Deck child" >/dev/null 2>&1 || fail "start orphaned-child job"
pid=$(jq -r .current_job.pid "$MEM_REC")
child=
for _ in $(seq 1 50); do
  child=$(ps -ax -o pid=,ppid=,command= | awk -v parent="$pid" '$2 == parent && /deck-crew-stub.py/ {print $1}')
  [ -n "$child" ] && break
  sleep 0.1
done
[ -n "$child" ] || fail "the runner must have launched its Deck child"
kill -9 "$pid" 2>/dev/null || fail "stop the runner without its child"
"$SPEC" history memory-check >/dev/null || fail "reconcile the orphaned job through history"
for _ in $(seq 1 50); do
  child_state=$(ps -o stat= -p "$child" 2>/dev/null)
  case "$child_state" in ''|Z*) break ;; esac
  sleep 0.1
done
case "$child_state" in ''|Z*) ;; *) fail "reconciliation must stop its proven orphaned Deck child" ;; esac
pass "reconciliation retains owned orphan cleanup"

GH_TOKEN=fixture-secret PROXAI_API_KEY=fixture-key "$SPEC" job memory-check --brief "Ambient environment" --wait >/dev/null 2>&1 || fail "unfiltered environment job"
assert_equals true "$(tail -1 "$DECK_STATE/argv.jsonl" | jq -r .environment.gh_token)" "absent allowlist preserves ambient credentials"
: > "$HOME_DIR/config/launch-env-allowlist"
GH_TOKEN=fixture-secret PROXAI_API_KEY=fixture-key "$SPEC" job memory-check --brief "Empty allowlist" --wait >/dev/null 2>&1 || fail "empty allowlist job"
filtered_log="$(jq -r .workdir "$MEM_REC")/deck-state/argv.jsonl"
assert_equals false "$(tail -1 "$filtered_log" | jq -r .environment.gh_token)" "an empty allowlist excludes GH_TOKEN"
assert_equals false "$(tail -1 "$filtered_log" | jq -r .environment.gateway_key)" "gateway credentials cannot bypass filtering"
assert_equals "$HOME" "$(tail -1 "$filtered_log" | jq -r .environment.home)" "filtering keeps the operational home floor"
launch_path=$(python3 -c 'import os; print(os.environ["PATH"])')
assert_equals "$launch_path" "$(tail -1 "$filtered_log" | jq -r .environment.path)" "filtering keeps the Python launcher's operational PATH floor"
printf '%s\n' '# Explicit test names' '' DECK_STATE CREW_ALLOWED_TEST CREW_EMPTY_TEST CREW_UNSET_TEST GH_TOKEN PROXAI_API_KEY > "$HOME_DIR/config/launch-env-allowlist"
unset CREW_UNSET_TEST
GH_TOKEN=fixture-secret PROXAI_API_KEY=fixture-key CREW_ALLOWED_TEST=allowed CREW_EMPTY_TEST='' \
  "$SPEC" job memory-check --brief "Explicit names" --wait >/dev/null 2>&1 || fail "named allowlist job"
environment=$(tail -1 "$DECK_STATE/argv.jsonl" | jq -c .environment)
assert_equals true "$(printf '%s' "$environment" | jq -r .gh_token)" "explicit credential names are passed"
assert_equals true "$(printf '%s' "$environment" | jq -r .gateway_key)" "explicit gateway credential names are passed"
assert_equals allowed "$(printf '%s' "$environment" | jq -r .allowed)" "listed values are preserved"
assert_equals '""' "$(printf '%s' "$environment" | jq -c .empty)" "empty values stay empty"
assert_equals false "$(printf '%s' "$environment" | jq -r .unset)" "unset listed names stay unset"
pass "specialist launches enforce the shared environment policy"

for invalid in assignment directory dangling inaccessible; do
  rm -rf "$HOME_DIR/config/launch-env-allowlist"
  case "$invalid" in
    assignment) printf 'GH_TOKEN=secret\n' > "$HOME_DIR/config/launch-env-allowlist" ;;
    directory) mkdir "$HOME_DIR/config/launch-env-allowlist" ;;
    dangling) ln -s missing "$HOME_DIR/config/launch-env-allowlist" ;;
    inaccessible) ln -s "$HOME_DIR/config/launch-env-allowlist" "$HOME_DIR/config/launch-env-allowlist" ;;
  esac
  before=$(jq -c . "$MEM_REC")
  expect_code 2 "$("$SPEC" job memory-check --brief "Invalid policy" >/dev/null 2>&1; echo $?)" "$invalid allowlist refuses a specialist launch"
  assert_equals "$before" "$(jq -c . "$MEM_REC")" "$invalid policy refuses before specialist mutation"
done
rm "$HOME_DIR/config/launch-env-allowlist"
pass "invalid launch policy fails closed before dispatch"

for command in create job status history list retire; do
  args=("$command")
  [ "$command" = list ] || args+=(memory-check)
  [ "$command" != create ] || args+=(--subject x)
  expect_code 3 "$(NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 "$SPEC" "${args[@]}" \
    >/dev/null 2>&1; echo $?)" "gate agents cannot invoke specialist $command"
done
pass "the gate boundary covers reconciliation and specialist mutations"
