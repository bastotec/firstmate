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
assert_equals working "$(python3 "$ROOT/bin/fm_crew.py" _spec-rows | jq -r '.[0].current_state.state')" "a live runner is working"
fm_test_kill_tree "$pid" >/dev/null 2>&1 || kill -9 "$pid" 2>/dev/null
for _ in $(seq 1 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
python3 - "$ROOT" "$HOME_DIR" <<'PY' || fail "dead-runner rows must report stopped without reconciling"
import calendar
import json
import stat
import subprocess
import sys
import time
from pathlib import Path
root, home = map(Path, sys.argv[1:])
def snapshot():
    return {str(p): (p.read_bytes() if p.is_file() else None, stat.S_IMODE(p.stat().st_mode), p.stat().st_mtime_ns)
            for directory in (home / "state", home / "data") for p in directory.rglob("*")}
before = snapshot()
started = time.time()
rows = json.loads(subprocess.check_output([sys.executable, str(root / "bin/fm_crew.py"), "_spec-rows"]))
row = next(r for r in rows if r["name"] == "amigo-tech")
assert row["status"] == "running" and row["current_job"]["pid"] > 0
assert row["current_state"]["state"] == "stopped", row
assert "runner ended" in row["current_state"]["detail"]
assert "next specialist command reconciles" in row["current_state"]["detail"]
observed = calendar.timegm(time.strptime(row["current_state"]["observed_at"], "%Y-%m-%dT%H:%M:%SZ"))
assert int(started) <= observed <= time.time()
assert snapshot() == before, "_spec-rows changed persisted state or permissions"
PY
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
expect_code 2 "$("$SPEC" suspend amigo-tech --reason "x" --since '' >/dev/null 2>&1; echo $?)" "an explicitly empty --since is refused"
assert_equals idle "$(jq -r .status "$REC")" "invalid --since leaves the specialist idle"
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

rm -f "$DECK_STATE/models.log"
"$SPEC" job amigo-tech --brief "Before a model choice." --wait >/dev/null || fail "job before model choice failed"
assert_absent "$DECK_STATE/models.log" "a job without a model choice passed --model"
"$SPEC" model amigo-tech zai/glm-5.3 >/dev/null || fail "model failed"
"$SPEC" job amigo-tech --brief "On the chosen model." --wait >/dev/null || fail "job on the chosen model failed"
assert_equals zai/glm-5.3 "$(cat "$DECK_STATE/models.log")" "the chosen model was not passed to the job"
view=$("$SPEC" status amigo-tech --json)
assert_equals 'true deck zai/glm-5.3 zai/glm-5.3 null' "$(printf '%s' "$view" | jq -r '"\(.persistent) \(.harness) \(.model) \(.model_choice) \(.effort)"')" \
  "status --json lacks the worker-shaped fields"
"$SPEC" model amigo-tech default >/dev/null || fail "model default failed"
assert_equals null "$(jq -r '.model // null' "$REC")" "model default did not clear the choice"
expect_code 2 "$("$SPEC" model amigo-tech 'two words' >/dev/null 2>&1; echo $?)" "a malformed model route was accepted"
rows=$(python3 "$ROOT/bin/fm_crew.py" _spec-rows)
assert_equals 'specialist true idle deck' "$(printf '%s' "$rows" | jq -r '.[] | select(.id == "spec-amigo-tech") | "\(.kind) \(.persistent) \(.current_state.state) \(.harness)"')" \
  "the fleet row is not worker-shaped"
assert_contains "$(printf '%s' "$rows" | jq -r '.[] | select(.id == "spec-amigo-tech") | .actions.model')" "fm-specialist.sh model amigo-tech" "the fleet row lacks the model action"
pass "a specialist has a model choice its jobs run on, and status and fleet rows carry worker-shaped fields"

python3 - "$ROOT" "$TMP_ROOT" "$session" <<'PY' || fail "session models must follow Deck state-directory precedence"
import json
import os
import subprocess
import sys
from pathlib import Path
root, tmp = map(Path, sys.argv[1:3])
session = sys.argv[3]
session_file = Path(os.environ["DECK_STATE"]) / "sessions" / f"{session}.json"
original_session = session_file.read_bytes()
env = dict(os.environ, HOME=str(tmp / "model-home"), XDG_STATE_HOME=str(tmp / "xdg-state"))
for directory, model in ((Path(env["DECK_STATE"]), "explicit/model"),
                         (Path(env["XDG_STATE_HOME"]) / "deck", "xdg/model"),
                         (Path(env["HOME"]) / ".local/state/deck", "home/model")):
    directory = directory / "sessions"
    directory.mkdir(parents=True, exist_ok=True)
    (directory / f"{session}.json").write_text(json.dumps({"model": model}))
def model():
    rows = json.loads(subprocess.check_output([sys.executable, str(root / "bin/fm_crew.py"), "_spec-rows"], env=env))
    return next(r["model"] for r in rows if r["name"] == "amigo-tech")
assert model() == "explicit/model"
env.pop("DECK_STATE")
assert model() == "xdg/model"
env.pop("XDG_STATE_HOME")
assert model() == "home/model"
(Path(env["HOME"]) / ".local/state/deck/sessions" / f"{session}.json").write_text("[]")
assert model() is None
session_file.write_bytes(original_session)
PY
pass "session model lookup follows DECK_STATE, XDG_STATE_HOME and HOME, tolerating non-object sessions"

python3 - "$ROOT" "$TMP_ROOT" "$REC" <<'PY' || fail "legacy jobs must report stream activity, never the reader's working directory"
import json
import os
import subprocess
import sys
from pathlib import Path
root, tmp, original = map(Path, sys.argv[1:])
home = tmp / "legacy-activity"
records = home / "state/specialists"
records.mkdir(parents=True)
rec = json.loads(original.read_text())
rec.update(home=str(home), status="running", current_job={"id": "legacy-job", "pid": 99999999})
record = records / "amigo-tech.json"
events = records / "amigo-tech/jobs/legacy-job/events.ndjson"
events.parent.mkdir(parents=True)
events.write_text('{"type":"turn-start"}\n')
os.utime(events, (1234567890, 1234567890))
env = dict(os.environ, FM_HOME=str(home))
def current_job():
    record.write_text(json.dumps(rec))
    rows = json.loads(subprocess.check_output([sys.executable, str(root / "bin/fm_crew.py"), "_spec-rows"], env=env, timeout=15))
    return rows[0]["current_job"]
cur = current_job()
assert cur["events"] == str(events) and cur["last_activity"] == 1234567890, cur
events.unlink()
assert current_job()["last_activity"] is None
rec.pop("home")
assert current_job()["last_activity"] is None
rec["home"] = str(home)
rec["current_job"].pop("id")
assert current_job()["last_activity"] is None
PY
pass "legacy job activity derives its stream path and stays null when unavailable"

out=$("$ROOT/bin/fm-control.sh" spec-amigo-tech model zai/glm-5.3) || fail "fm-control model on a specialist failed: $out"
assert_equals zai/glm-5.3 "$(jq -r .model "$REC")" "fm-control model did not switch the specialist"
out=$("$ROOT/bin/fm-control.sh" spec-amigo-tech relaunch --model default --note x) || fail "fm-control relaunch on a specialist failed: $out"
assert_contains "$out" "has no process between jobs" "relaunch did not explain the no-op"
assert_equals null "$(jq -r '.model // null' "$REC")" "relaunch --model did not set the model"
expect_code 2 "$("$ROOT/bin/fm-control.sh" spec-amigo-tech watch >/dev/null 2>&1; echo $?)" "an unsupported verb was accepted"
jobs_before=$(jq -r .jobs "$REC")
"$ROOT/bin/fm-send.sh" spec-amigo-tech -- "Check the evals." >/dev/null || fail "fm-send to a specialist failed"
for _ in $(seq 1 100); do [ "$(jq -r .status "$REC")" = idle ] && break; sleep 0.1; done
assert_equals $((jobs_before + 1)) "$(jq -r .jobs "$REC")" "fm-send did not start a job"
assert_grep "Check the evals." "$HOME_DIR/state/specialists/amigo-tech/jobs/$(jq -r .last_job.id "$REC")/brief.md" "fm-send text is not the brief"
"$ROOT/bin/fm-send.sh" spec-amigo-tech --from-captain -- "Is it healthy?" >/dev/null || fail "captain fm-send to a specialist failed"
for _ in $(seq 1 100); do [ "$(jq -r .status "$REC")" = idle ] && break; sleep 0.1; done
assert_equals captain "$(jq -r .last_job.from "$REC")" "--from-captain did not mark the job"
expect_code 2 "$("$ROOT/bin/fm-send.sh" spec-amigo-tech --resolve-key k -- x >/dev/null 2>&1; echo $?)" "an inapplicable fm-send option was accepted"
STUB_MODE=hang "$SPEC" job amigo-tech --brief "Long sweep." >/dev/null || fail "starting a hanging job failed"
out=$("$ROOT/bin/fm-control.sh" spec-amigo-tech interrupt) || fail "interrupt failed: $out"
assert_equals idle "$(jq -r .status "$REC")" "interrupt left the specialist running"
assert_equals interrupted "$(jq -r .last_job.outcome "$REC")" "the stopped job was not recorded as interrupted"
expect_code 3 "$("$SPEC" stop amigo-tech >/dev/null 2>&1; echo $?)" "stopping an idle specialist was accepted"
pass "fm-send and fm-control drive a specialist by its spec-<name> id like any worker"

cat > "$TMP_ROOT/deck-term-child" <<'PY'
#!/usr/bin/env python3
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
state = Path(os.environ["STUB_STOP_DIR"])
if len(sys.argv) > 1 and sys.argv[1] == "child":
    def term(signum, frame):
        (state / "term").write_text(str(time.monotonic()))
    signal.signal(signal.SIGTERM, term)
    (state / "ready.json").write_text(json.dumps({"pid": os.getpid(), "pgid": os.getpgrp()}))
    time.sleep(120)
else:
    subprocess.Popen([sys.executable, __file__, "child"])
    time.sleep(120)
PY
chmod +x "$TMP_ROOT/deck-term-child"
python3 - "$ROOT" "$TMP_ROOT" "$REC" <<'PY' || fail "stop must give TERM-resistant descendants the grace period and prove their exit"
import importlib.util
import json
import os
import signal
import subprocess
import sys
import time
from pathlib import Path
root, tmp, record = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("fm_crew", root / "bin/fm_crew.py")
crew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crew)
state = tmp / "stop-child"
state.mkdir()
env = dict(os.environ, FM_DECK_BIN=str(tmp / "deck-term-child"), STUB_STOP_DIR=str(state))
cli = [str(root / "bin/fm-specialist.sh")]
pid = None
stopping = status = None
try:
    subprocess.run([*cli, "job", "amigo-tech", "--brief", "Stop the full group"], env=env, check=True, timeout=15)
    rec = json.loads(record.read_text())
    pid = rec["current_job"]["pid"]
    assert crew.wait_for(lambda: (state / "ready.json").is_file(), 10), "child never became ready"
    child = json.loads((state / "ready.json").read_text())
    assert child["pgid"] == pid and child["pid"] != pid
    job = rec["current_job"]["id"]
    jobs_before = rec["jobs"]
    stopping = subprocess.Popen([*cli, "stop", "amigo-tech"], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert crew.wait_for(lambda: (state / "term").is_file() and not crew.pid_alive(pid), 5), "runner did not exit after TERM"
    status = subprocess.Popen([*cli, "status", "amigo-tech", "--json"], env=env,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        status.communicate(timeout=0.5)
        raise AssertionError("status reconciled during stop's grace period")
    except subprocess.TimeoutExpired:
        pass
    assert crew.pid_alive(child["pid"]), "concurrent status killed the child before grace elapsed"
    assert json.loads(record.read_text())["current_job"]["id"] == job
    output, errors = stopping.communicate(timeout=60)
    finished = time.monotonic()
    assert stopping.returncode == 0, (output, errors)
    status_output, status_errors = status.communicate(timeout=15)
    assert status.returncode == 0, status_errors
    assert json.loads(status_output)["last_job"]["outcome"] == "interrupted", status_output
    assert (state / "term").is_file(), "child did not receive TERM"
    assert finished - float((state / "term").read_text()) >= 9.8, "child did not get the ten-second grace period"
    assert not crew.group_alive(pid), "stop reported success while non-zombie group members survived"
    rec = json.loads(record.read_text())
    assert rec["status"] == "idle" and rec["last_job"]["outcome"] == "interrupted", rec
    assert rec["jobs"] == jobs_before + 1, rec
    history = record.parent / "amigo-tech/history.jsonl"
    assert sum(json.loads(line)["job"] == job for line in history.read_text().splitlines()) == 1
finally:
    for process in (stopping, status):
        if process is not None:
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)
    if pid and crew.group_alive(pid):
        os.killpg(pid, signal.SIGKILL)
        assert crew.wait_for(lambda: not crew.group_alive(pid), 5), "fixture group survived cleanup"
PY
pass "stop serializes concurrent status through the full process-group grace period and finalizes once"

assert_equals null "$(tail -1 "$DECK_STATE/argv.jsonl" | jq -r .tool_concurrency)" "unguarded jobs override Deck tool concurrency"
rm -f "$DECK_STATE/gate.log"
"$SPEC" configure amigo-tech --stop-on-tool-failure on >/dev/null || fail "configure failed"
assert_equals true "$(jq -r .stop_on_tool_failure "$REC")" "configure did not record the setting"
STUB_MODE=tool-fail "$SPEC" job amigo-tech --brief "Health sweep." --wait >/dev/null 2>&1 && fail "a job stopped at a failed tool call reported success"
assert_equals failed "$(jq -r .last_job.outcome "$REC")" "a stopped job was not recorded as failed"
assert_equals 1 "$(tail -1 "$DECK_STATE/argv.jsonl" | jq -r .tool_concurrency)" "guarded jobs must serialize tool calls"
assert_equals 2 "$(cat "$DECK_STATE/gate.log")" "the tool call after the failure was not refused"
assert_contains "$(jq -r .last_job.stopped "$REC")" "stopped at the first failed tool call (run_command)" "last_job does not say it stopped"
assert_contains "$(jq -r .last_job.stopped "$REC")" "42703" "the stop note lost the failure"
assert_contains "$("$SPEC" result amigo-tech)" "Stopped at the first failed tool call" "firstmate did not write the stopped result"
assert_contains "$(tail -1 "$HOME_DIR/state/specialists/amigo-tech/history.jsonl" | jq -r .stopped)" "first failed tool call" "history does not say it stopped"
out=$("$SPEC" job amigo-tech --brief "Healthy sweep." --wait 2>&1) || fail "a clean job failed with the setting on: $out"
assert_equals "done" "$(jq -r .last_job.outcome "$REC")" "a clean job did not finish with the setting on"
assert_equals null "$(jq -r .last_job.stopped "$REC")" "a clean job carried a stop note"
"$SPEC" configure amigo-tech --stop-on-tool-failure off >/dev/null || fail "configure off failed"
assert_equals false "$(jq -r .stop_on_tool_failure "$REC")" "configure off did not clear the setting"
pass "stop-on-tool-failure refuses every tool after the first failed call, records why, and leaves clean jobs alone"

ev_ok='{"tool_name":"run_command","tool_output":"{\"exit_code\":0,\"stdout\":\"x\",\"stderr\":\"\",\"timed_out\":false}"}'
ev_err='{"tool_name":"read_file","tool_output":"the tool failed"}'
ev_timeout='{"tool_name":"run_command","tool_output":"{\"exit_code\":null,\"stdout\":\"\",\"stderr\":\"\",\"timed_out\":true}"}'
ev_read='{"tool_name":"read_file","tool_output":"{\"exit_code\":1}"}'
ev_read_timeout='{"tool_name":"read_file","tool_output":"{\"exit_code\":null,\"timed_out\":true}"}'
ev_nonzero='{"tool_name":"run_command","tool_output":"{\"exit_code\":1}"}'
ev_null='{"tool_name":"run_command","tool_output":"{\"exit_code\":null}"}'
for case in ok err timeout read read_timeout nonzero null; do
  jd="$TMP_ROOT/observe-$case"; mkdir -p "$jd"
  case "$case" in
    ok) ev=$ev_ok ;;
    err) ev=$ev_err ;;
    timeout) ev=$ev_timeout ;;
    read) ev=$ev_read ;;
    read_timeout) ev=$ev_read_timeout ;;
    nonzero) ev=$ev_nonzero ;;
    null) ev=$ev_null ;;
  esac
  printf '%s' "$ev" | python3 "$ROOT/bin/fm_crew.py" _spec-tool-observe "$jd"
done
assert_absent "$TMP_ROOT/observe-ok/tool-failure.json" "a successful command counted as a failure"
assert_absent "$TMP_ROOT/observe-read/tool-failure.json" "reading saved command failure JSON counted as a failure"
assert_absent "$TMP_ROOT/observe-read_timeout/tool-failure.json" "reading saved timeout JSON counted as a failure"
assert_present "$TMP_ROOT/observe-err/tool-failure.json" "a tool error was not recorded"
assert_present "$TMP_ROOT/observe-timeout/tool-failure.json" "a timed-out command was not recorded"
assert_present "$TMP_ROOT/observe-nonzero/tool-failure.json" "a nonzero command was not recorded"
assert_present "$TMP_ROOT/observe-null/tool-failure.json" "a command with null exit code was not recorded"
pass "only commands use exit metadata; tool errors count for every tool"

python3 - "$ROOT" "$TMP_ROOT" <<'PY' || fail "presentation failure classification"
import json
import subprocess
import sys
from pathlib import Path
root, tmp = map(Path, sys.argv[1:])
def preview(tool, size=20000, stored=None):
    label = f"full output ({size} bytes)" if stored is None else f"output truncated before storing; retained output ({stored} bytes)"
    return "a" * 4096 + f"\n[... {size - 8192} bytes not shown: {label} is stored as `{tool}-012345abcdef`; call read_tool_output with that handle and a start_byte/byte_count range or a query to read the rest ...]\n" + "z" * 4096
note = "\n[... truncated ...]\n"
budget = 256 * 1024 - len(note)
hard = "a" * (budget // 2) + note + "z" * (budget - budget // 2)
cases = [
    ("clean-read", "read_file", "clean text\n", False),
    ("literal-marker", "read_file", "Historical text: " + note + "not current status", False),
    ("quoted-preview", "read_file", "Historical text:\n" + preview("read_file"), False),
    ("short-preview", "read_file", preview("read_file").replace("a" * 4096, "a"), False),
    ("wrong-size", "read_file", preview("read_file").replace("20000 bytes", "20001 bytes"), False),
    ("wrong-tool", "read_file", preview("run_command"), False),
    ("preview", "read_file", preview("read_file"), True),
    ("cut-storage", "read_file", preview("read_file", 9000000, 8388651), True),
    ("bad-storage-size", "read_file", preview("read_file", 9000000, 10), False),
    ("unicode-preview", "read_file", preview("read_file").replace("a" * 4096, "é" * 2048), True),
    ("unicode-hard-cut", "read_file", "é" * (budget // 4) + note + "z" * (budget - budget // 2), True),
    ("hard-cut", "read_file", hard, True),
    ("saved-status", "read_file", "[exit_code] 1\n[timed_out] true\n", False),
    ("historical-command", "run_command", "[exit_code] 1\n[timed_out] true\nmore output\n", False),
]
for code, timeout, failed in [("0", "false", False), ("1", "false", True), ("null", "false", True), ("0", "true", True)]:
    text = "a" * 20000 + f"\n[exit_code] {code}\n[timed_out] {timeout}\n"
    cases.append((f"rendered-{code}-{timeout}", "run_command", text, failed))
    cases.append((f"stored-{code}-{timeout}", "run_command", preview("run_command")[:-4096] + text[-4096:], True))
for name, tool, output, failed in cases:
    job = tmp / ("presentation-" + name)
    job.mkdir()
    event = {"tool_name": tool, "args": {"fixture": name}, "tool_output": output}
    subprocess.run([sys.executable, str(root / "bin/fm_crew.py"), "_spec-tool-observe", str(job)],
                   input=json.dumps(event), text=True, check=True, timeout=15)
    marker = job / "tool-failure.json"
    assert marker.exists() == failed, name
    if failed:
        assert json.loads(marker.read_text())["output"] == " ".join(output.split())[:600], name
        gate = subprocess.run([sys.executable, str(root / "bin/fm_crew.py"), "_spec-tool-gate", str(job)],
                              capture_output=True, timeout=15)
        assert gate.returncode == 2, name
PY
pass "actual presentation envelopes and rendered command statuses latch; historical content stays inert"

python3 - "$ROOT" "$TMP_ROOT" <<'PY' || fail "observers must atomically preserve the first failure"
import importlib.util
import io
import json
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
from unittest.mock import patch
root, tmp = map(Path, sys.argv[1:])
jdir = tmp / "observe-race"
jdir.mkdir()
script = root / "bin/fm_crew.py"
argv = [str(script), "_spec-tool-observe", str(jdir)]
def observe(index):
    event = {"tool_name": "run_command", "args": {"command": f"exit {index}"},
             "tool_output": json.dumps({"exit_code": index})}
    subprocess.run([sys.executable, *argv], input=json.dumps(event), text=True,
                   check=True, timeout=15)
with ThreadPoolExecutor(max_workers=8) as pool:
    list(pool.map(observe, range(1, 17)))
record = jdir / "tool-failure.json"
first = record.read_bytes()
note = json.loads(first)
code = json.loads(note["output"])["exit_code"]
assert code in range(1, 17)
assert json.loads(note["args"])["command"] == f"exit {code}"
spec = importlib.util.spec_from_file_location("fm_crew", script)
crew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crew)
late = {"tool_name": "read_file", "tool_output": "the tool failed: later failure"}
with patch.object(crew, "read_tool_failure", return_value=None), \
     patch.object(sys, "stdin", io.StringIO(json.dumps(late))), \
     patch.object(sys, "argv", argv):
    crew.main()
assert record.read_bytes() == first
assert sorted(p.name for p in jdir.iterdir()) == ["tool-failure.json"]
PY
pass "concurrent observers and stale reads preserve one complete first failure"

expect_code 2 "$("$SPEC" ask amigo-tech -- "hello" >/dev/null 2>&1; echo $?)" "ask without --from-captain was accepted"
out=$("$SPEC" ask amigo-tech --from-captain --wait -- "How is Amigo doing this week?" 2>&1) || fail "captain ask failed: $out"
assert_equals null "$(tail -1 "$DECK_STATE/argv.jsonl" | jq -r .tool_concurrency)" "disabling the setting did not restore default tool concurrency"
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

python3 - "$ROOT" "$HOME_DIR" "$TMP_ROOT" <<'PY' || fail "captain messages must be prepared before launch and retained exactly"
import fcntl
import importlib.util
import json
import sys
from pathlib import Path
from unittest.mock import patch
root, home, tmp = map(Path, sys.argv[1:])
spec = importlib.util.spec_from_file_location("fm_crew", root / "bin/fm_crew.py")
crew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crew)
sp = crew.Specialist(home, "amigo-tech")
real_detach = crew.detach
for source, text in (("argv", "  How is Amigo?  "), ("file", "  Check this snippet:\r\n    code\r\n\r\n")):
    def launch(argv, log):
        job = argv[4]
        assert (sp.job_dir(job) / "message.md").read_bytes() == text.encode()
        assert f"specialist-captain:amigo-tech:{job}" in (home / "state/.wake-queue").read_text()
        with open(sp.lock_path, "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                raise AssertionError("job preparation must retain the specialist lock")
        return real_detach(argv, log)
    argv = ["fm_crew.py", "ask", "amigo-tech", "--from-captain", "--wait"]
    if source == "file":
        message = tmp / "captain-message.txt"
        message.write_bytes(text.encode())
        argv += ["--text-file", str(message)]
    else:
        argv += ["--", text]
    with patch.object(sys, "argv", argv), patch.object(crew, "detach", side_effect=launch):
        crew.main()
    rec = json.loads(sp.record_path.read_text())
    last = rec["last_job"]
    history = json.loads(sp.history_path.read_text().splitlines()[-1])
    assert last["message"] == history["message"] == text
    job = last["id"]
    assert (sp.job_dir(job) / "message.md").read_bytes() == text.encode()
    queue = (home / "state/.wake-queue").read_text()
    assert queue.index(f"specialist-captain:amigo-tech:{job}") < queue.index(f"specialist:amigo-tech:{job}")
PY
pass "captain words and owner notification are prepared under lock before the runner starts"

PRIMARY="$TMP_ROOT/primary"
mkdir -p "$PRIMARY/state"
printf 'kind=secondmate\nhome=%s\n' "$HOME_DIR" > "$PRIMARY/state/mate-local.meta"
out=$(env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$PRIMARY" "$SPEC" status amigo-tech --mate mate-local) \
  || fail "status through a local mate failed: $out"
assert_contains "$out" "specialist amigo-tech (idle)" "--mate did not run in the local mate's home"
assert_contains "$("$SPEC" status amigo-tech --mate primary)" "specialist amigo-tech (idle)" "--mate primary must select the current home"
ROUTE_BIN="$TMP_ROOT/route-bin"
mkdir -p "$ROUTE_BIN"
cp "$ROOT/bin/fm-specialist.sh" "$ROUTE_BIN/"
ln -s "$ROOT/bin/fm-gate-refuse-lib.sh" "$ROUTE_BIN/fm-gate-refuse-lib.sh"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$@" > "%s/fm-on.args"\n' "$TMP_ROOT" > "$ROUTE_BIN/fm-on.sh"
chmod +x "$ROUTE_BIN/fm-on.sh"
printf 'kind=secondmate\nremote_host=workload\nhome=/remote/home\n' > "$PRIMARY/state/mate-remote.meta"
env -u FM_STATE_OVERRIDE FM_HOME="$PRIMARY" "$ROUTE_BIN/fm-specialist.sh" ask linkana --mate mate-remote --from-captain -- "any new errors?" \
  || fail "a remote ask did not route"
assert_equals $'mate-remote\nfm-specialist.sh\nask\nlinkana\n--from-captain\n--\nany new errors?' "$(cat "$TMP_ROOT/fm-on.args")" \
  "a remote mate's ask was not sent through fm-on.sh"
expect_code 2 "$(env -u FM_STATE_OVERRIDE FM_HOME="$PRIMARY" "$ROUTE_BIN/fm-specialist.sh" ask linkana --mate mate-remote --from-captain --text-file /tmp/x >/dev/null 2>&1; echo $?)" \
  "--text-file was sent to a remote mate"
rm "$TMP_ROOT/fm-on.args"
for command in ask result status history; do
  expect_code 3 "$(NO_MISTAKES_GATE=1 FM_GATE_REFUSE_BYPASS=0 env -u FM_STATE_OVERRIDE FM_HOME="$PRIMARY" \
    "$ROUTE_BIN/fm-specialist.sh" "$command" linkana --mate mate-remote >/dev/null 2>&1; echo $?)" \
    "gate agents cannot route $command to a remote home"
done
assert_absent "$TMP_ROOT/fm-on.args" "gate refusal must happen before fm-on"
rc=0
out=$(env -u FM_STATE_OVERRIDE FM_HOME="$PRIMARY" "$ROUTE_BIN/fm-specialist.sh" ask linkana --mate mate-remote --from-captain --wait -- "hello" 2>&1) || rc=$?
expect_code 2 "$rc" "remote --wait must be refused"
assert_contains "$out" "poll status/result" "remote wait refusal must explain how to read the result"
assert_absent "$TMP_ROOT/fm-on.args" "remote wait refusal must happen before transport"
env -u FM_STATE_OVERRIDE FM_HOME="$PRIMARY" "$ROUTE_BIN/fm-specialist.sh" ask linkana --mate mate-remote --from-captain -- "--wait" \
  || fail "message text is not a remote wait option"
assert_equals --wait "$(tail -1 "$TMP_ROOT/fm-on.args")" "the remote message tail must remain text"
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

# A host just back from a reboot hands its processes a bare system PATH; deck
# installed only in ~/.local/bin must still resolve without FM_DECK_BIN.
REBOOT_HOME="$TMP_ROOT/reboot-home"
REBOOT_TOOLS="$TMP_ROOT/reboot-tools"
mkdir -p "$REBOOT_HOME/.local/bin" "$REBOOT_TOOLS"
ln -s "$ROOT/tests/assets/deck-crew-stub.py" "$REBOOT_HOME/.local/bin/deck"
ln -s "$(command -v jq)" "$REBOOT_TOOLS/jq"
out=$(env -u FM_DECK_BIN HOME="$REBOOT_HOME" PATH="$REBOOT_TOOLS:/usr/bin:/bin" \
  "$SPEC" job memory-check --brief "After a reboot" --wait 2>&1) || fail "a bare-PATH job could not find deck in ~/.local/bin: $out"
assert_equals "done" "$(jq -r .last_job.outcome "$MEM_REC")" "the bare-PATH job did not run on the ~/.local/bin deck"
pass "deck resolves from ~/.local/bin when the caller has a bare system PATH"

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
  before=$(cat "$MEM_REC")
  assert_equals stopped "$(python3 "$ROOT/bin/fm_crew.py" _spec-rows | jq -r '.[] | select(.name == "memory-check") | .current_state.state')" "a reused pid must not report working in read-only rows"
  assert_equals "$before" "$(cat "$MEM_REC")" "read-only reused-pid health must not reconcile"
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
