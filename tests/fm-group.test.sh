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

# Observe durability at the syscall boundary while running the public CLI.
mkdir -p "$TMP_ROOT/instrument"
cat > "$TMP_ROOT/instrument/sitecustomize.py" <<'PY'
import json
import os
import stat

real_sync = os.fsync
real_replace = os.replace

def log(event):
    with open(os.environ["SYNC_LOG"], "a") as fh:
        fh.write(json.dumps(event) + "\n")

def sync(fd):
    log("directory" if stat.S_ISDIR(os.fstat(fd).st_mode) else "file")
    return real_sync(fd)

def replace(src, dst):
    log("replace")
    return real_replace(src, dst)

os.fsync = sync
os.replace = replace
PY
SYNC_LOG="$TMP_ROOT/sync.log" PYTHONPATH="$TMP_ROOT/instrument" \
  "$ROOT/bin/fm-specialist.sh" create durable --subject "private" >/dev/null || fail "durable record creation"
assert_equals '["file","replace","directory"]' "$(jq -sc . "$TMP_ROOT/sync.log")" \
  "record file is synced before rename and parent directory afterward"
pass "record replacement is durable"

python3 - "$ROOT" "$HOME_DIR" <<'PY' || fail "a transiently empty argument snapshot must not strand cleanup"
import importlib.util
import subprocess
import sys
import threading
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("fm_crew", Path(sys.argv[1]) / "bin/fm_crew.py")
crew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crew)
worker = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(120)"], start_new_session=True)
# Reap the child when cleanup signals it, as the normal orchestrator/init does.
reaper = threading.Thread(target=worker.wait)
reaper.start()
try:
    real_arguments = crew.PROCESS_API.process_arguments
    reads = [0]

    def exec_snapshot(pid):
        reads[0] += 1
        # /proc cmdline and the macOS argument API may be empty during exec.
        return None if reads[0] == 1 else real_arguments(pid)

    with patch.object(crew.PROCESS_API, "process_arguments", exec_snapshot):
        identity = crew.process_identity(worker.pid)
    # Exec may change argv without changing the process group or start time.
    with patch.object(crew.PROCESS_API, "process_arguments", return_value=["changed", "argv"]):
        changed = crew.process_identity(worker.pid)
        assert changed["arguments"] != identity["arguments"], "argv snapshots must diverge"
        assert changed["started"] == identity["started"], "the same process must remain alive"
        assert crew.target_state(worker.pid, identity) == "owned", "exec changed ownership"
    group = crew.Group(Path(sys.argv[2]), "identity-exec")
    group.save({"id": "identity-exec", "title": "Exec identity", "status": "running",
                "orchestrator_pid": None, "members": [{"key": "m1", "pid": worker.pid,
                "identity": identity, "status": "running", "result": None}]})
    assert crew.cleanup_group(group, "requested"), "a transient snapshot left a live cleanup survivor"
    assert group.record()["cleanup"]["survivors"] == []
    assert not crew.pid_alive(worker.pid), "cleanup must stop the actual owned process"
finally:
    if worker.poll() is None:
        worker.kill()
    worker.wait()
    reaper.join()
PY
pass "a transiently empty argument snapshot does not leave an unowned cleanup survivor"

live_stubs() {
  [ -f "$DECK_STATE/argv.jsonl" ] || return 0
  jq -r .pid "$DECK_STATE/argv.jsonl" | while read -r pid; do
    command=$(ps -o command= -p "$pid" 2>/dev/null)
    case "$command" in *deck-crew-stub.py\ run*) echo "$pid" ;; esac
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
assert_contains "$(jq -r .summary "$REC")" "merged 5 member results" "the record carries the start of the merged result"
assert_grep "angle: security" "$report" "member results are appended to the report"
assert_grep "angle: docs" "$report" "every angle is in the report"
assert_present "$HOME_DIR/data/groups/pr-review/members/m3.md" "member results are kept after cleanup"
pass "results merge into one report"
python3 - "$report" "$HOME_DIR/data/groups/pr-review/members/m3.md" <<'PY' || fail "retained results must be private"
import stat
import sys
from pathlib import Path
for name in sys.argv[1:]:
    assert stat.S_IMODE(Path(name).stat().st_mode) == 0o600, name
PY
pass "retained report and member results are private"

# A cleanup interrupted while presenting its card must not poison inventory.
printf '{"title":"leftover cleanup card"}\n' > "$HOME_DIR/state/groups/.leftover.card.json"
"$GROUP" list >/dev/null || fail "list with a leftover cleanup card"
assert_equals false "$("$GROUP" list --json | jq 'any(.[]; .title == "leftover cleanup card")')" \
  "JSON inventory excludes cleanup cards"
pass "leftover cleanup cards do not enter the group inventory"

# Run real hooks through Deck's shell boundary with literal shell metacharacters.
export PWN_TARGET="$TMP_ROOT/PWNED"
odd_home="$TMP_ROOT/\$(touch \$PWN_TARGET)-\$HOME-\`touch \$PWN_TARGET\`-'quoted'"
mkdir -p "$odd_home"
FM_HOME="$odd_home" STUB_MODE=lazy "$GROUP" start literal-lazy --brief x --angle a --wait >/dev/null 2>&1 \
  && fail "a missing literal result must refuse completion"
FM_HOME="$odd_home" "$GROUP" start literal-ok --brief x --angle a --wait >/dev/null 2>&1 \
  || fail "literal result paths must pass their hooks"
assert_absent "$TMP_ROOT/PWNED" "hook must not execute command substitution"
[ -z "$(find "$TMP_ROOT/work" -name PWNED -o -name PWNED2)" ] || fail "hook executed a path as shell code"
pass "result hooks quote each argument and refuse missing literal results"

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
python3 - "$HOME_DIR/state/groups/stuck" <<'PY' || fail "active group artifacts must be private"
import stat
import sys
from pathlib import Path
for name in ("brief.md", "members/m1/prompt.md", "members/m2/prompt.md"):
    path = Path(sys.argv[1]) / name
    assert stat.S_IMODE(path.stat().st_mode) == 0o600, path
PY
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
assert_equals 'done' "$(jq -r .status "$HOME_DIR/state/groups/unkillable.json")" "cleanup retry preserves the completed work outcome"
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
orch=$(jq -r .orchestrator_pid "$HANG_REC")
kill -9 "$orch" || fail "stop orchestrator without its merger"
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

printf '%s\n' DECK_STATE STUB_RESULT_BYTES > "$HOME_DIR/config/launch-env-allowlist"
launches=$(wc -l < "$DECK_STATE/argv.jsonl" | tr -d ' ')
GH_TOKEN=fixture-secret PROXAI_API_KEY=fixture-key STUB_RESULT_BYTES=30720 \
  "$GROUP" start large-merge --brief "Review five substantial reports" \
  --angle a --angle b --angle c --angle d --angle e --wait >/dev/null 2>&1 || fail "large member reports must reach the merger"
LARGE_REC="$HOME_DIR/state/groups/large-merge.json"
assert_equals 'done' "$(jq -r .status "$LARGE_REC")" "a large required merge completes"
assert_grep "merged 5 member results" "$HOME_DIR/data/groups/large-merge/report.md" "the large merge consumes all member reports"
new_launches=$(jq -s --argjson start "$launches" '.[$start:]' "$DECK_STATE/argv.jsonl")
assert_equals 6 "$(printf '%s' "$new_launches" | jq length)" "five members and the merger launch through the filtered boundary"
assert_equals true "$(printf '%s' "$new_launches" | jq 'all(.[]; .stdin_prompt)')" "all generated prompts use stdin"
merge_bytes=$(printf '%s' "$new_launches" | jq -r '.[-1].prompt_bytes')
[ "$merge_bytes" -gt 131072 ] || fail "the merger must receive a prompt above Linux's per-argument limit"
assert_equals true "$(printf '%s' "$new_launches" | jq 'all(.[]; .environment.gh_token == false and .environment.gateway_key == false)')" "members and merger exclude unlisted credentials"
pass "large reports merge over stdin with filtered member and merger environments"

printf 'GH_TOKEN=secret\n' > "$HOME_DIR/config/launch-env-allowlist"
expect_code 2 "$("$GROUP" start invalid-policy --brief x --angle a >/dev/null 2>&1; echo $?)" "invalid environment policy refuses group dispatch"
assert_absent "$HOME_DIR/state/groups/invalid-policy.json" "invalid policy creates no group record"
rm "$HOME_DIR/config/launch-env-allowlist"
pass "group environment preflight fails closed before mutation"

python3 - "$ROOT" "$TMP_ROOT" <<'PY' || fail "a result path with shell syntax must never run as shell"
import importlib.util
import os
import shlex
import subprocess
import sys
from pathlib import Path

spec = importlib.util.spec_from_file_location("fm_crew", Path(sys.argv[1]) / "bin/fm_crew.py")
crew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crew)
tmp = Path(sys.argv[2])
odd = tmp / "odd $(touch pwned) dir"
odd.mkdir()
hook = crew.result_hook(odd / "result.md").split("=", 1)[1]
rc = subprocess.run(["bash", "-lc", hook], cwd=tmp, capture_output=True).returncode
assert rc == 2, rc
assert not (tmp / "pwned").exists(), "the hook ran a command substitution from the path"
(odd / "result.md").write_text("found\n")
assert subprocess.run(["bash", "-lc", hook], cwd=tmp, capture_output=True).returncode == 0
PY
pass "the result gate quotes its path, so a home path cannot inject shell"

printf '%s\n' '{"project":"firstmate","title":"t"}' > "$HOME_DIR/state/groups/.stray.card.json"
printf '%s\n' '{"not":"a group"}' > "$HOME_DIR/state/groups/stray.json"
out=$("$GROUP" list 2>&1) || fail "list must survive stray files beside group records: $out"
assert_not_contains "$("$GROUP" list --json)" '"title": "t"' "list leaves out a stray card"
rm -f "$HOME_DIR/state/groups/.stray.card.json" "$HOME_DIR/state/groups/stray.json"
pass "list reads only group records"

: > "$DECK_STATE/concurrency.log"
STUB_RUNNING_DIR="$TMP_ROOT/running-serial" STUB_SLEEP=0.4 FM_GROUP_LOCAL_MAX=1 "$GROUP" start serial --brief x --angle a --angle b --angle c --wait >/dev/null 2>&1 \
  || fail "a capped group must still finish"
assert_equals 1 "$(sort -n "$DECK_STATE/concurrency.log" | tail -1)" "FM_GROUP_LOCAL_MAX=1 runs one member at a time"
pass "the local cap is configurable"

python3 - "$ROOT" <<'PY' || fail "a group left with only a zombie leader must read as gone"
import importlib.util
import subprocess
import sys
import time
from pathlib import Path

spec = importlib.util.spec_from_file_location("fm_crew", Path(sys.argv[1]) / "bin/fm_crew.py")
crew = importlib.util.module_from_spec(spec)
spec.loader.exec_module(crew)
leader = subprocess.Popen([sys.executable, "-c", "pass"], start_new_session=True)
time.sleep(1)  # exited, not yet reaped: a zombie leading an otherwise empty group
try:
    assert not crew.pid_alive(leader.pid), "a zombie is not running"
    assert not crew.group_alive(leader.pid), "macOS answers killpg(0) with EPERM here; that is not a live group"
finally:
    leader.wait()
PY
pass "a zombie-only process group is not mistaken for a survivor"
