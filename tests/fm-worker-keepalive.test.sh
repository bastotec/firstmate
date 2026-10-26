#!/usr/bin/env bash
# Behavior tests for bin/fm-worker-keepalive.sh; bin/fm_worker_keepalive.py's
# docstring owns conditions, recovery deadlines, and upward escalation.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEPALIVE="$ROOT/bin/fm-worker-keepalive.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-keepalive)
T0=1800000000  # 2027-01-15T08:00:00Z

at() {  # <epoch> <path>: set a file's mtime to a fixture time
  python3 -c 'import os,sys; t=int(sys.argv[1]); os.utime(sys.argv[2], (t, t), follow_symlinks=False)' "$1" "$2"
}

# A home with one worker w1 of <kind> in a git worktree, and a liveness stub
# that prints the contents of $dir/liveness (default busy).
make_home() {  # <name> <kind>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/bin" "$dir/wt"
  git -C "$dir/wt" init -q
  git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  printf 'kind=%s\nworktree=%s\nspawn_gen=s1\n' "$2" "$dir/wt" > "$dir/home/state/w1.meta"
  echo busy > "$dir/liveness"
  cat > "$dir/bin/liveness" <<EOF
#!/usr/bin/env bash
cat "$dir/liveness"
EOF
  chmod +x "$dir/bin/liveness"
  make_notify "$dir"
  printf '%s\n' "$dir"
}

# A stand-in for bin/fm-notify.sh that records each captain line in $dir/notices.
make_notify() {  # <dir>
  printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s/notices"\n' "$1" > "$1/bin/notify"
  chmod +x "$1/bin/notify"
}

# A second mate home named <mate> whose parent channel is a local parent home.
make_secondmate() {  # <dir> <mate>
  mkdir -p "$1/parent/state"
  printf '%s\n' "$2" > "$1/home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$1/parent" > "$1/home/.fm-secondmate-parent"
}

status() {  # <dir> <epoch> <line>
  printf '%s\n' "$3" >> "$1/home/state/w1.status"
  at "$2" "$1/home/state/w1.status"
}

steer() {  # <dir> <epoch>: the mate writes to the worker's inbox (bin/fm-send.sh)
  local rec
  rec=$(FM_HOME="$1/home" FM_STATE_OVERRIDE="$1/home/state" \
    bash -c '. "$1/bin/fm-task-inbox-lib.sh"; fm_task_inbox_write "$2" w1 "retry now"' \
    _ "$ROOT" "$1/home/state") || fail "could not deliver the steer"
  at "$2" "$rec"
}

scan() {  # <dir> <now>
  FM_HOME="$1/home" FM_KEEPALIVE_NOW="$2" FM_KEEPALIVE_LIVENESS="$1/bin/liveness" \
    FM_KEEPALIVE_NOTIFY="$1/bin/notify" \
    FM_KEEPALIVE_TASKS="${FM_KEEPALIVE_TASKS:-/usr/bin/false}" "$KEEPALIVE" scan
}

notice_count() {  # <dir> <pattern>: captain lines matching <pattern>
  cat "$1/notices" 2>/dev/null | grep -c -- "$2" || true
}

wakes() { cut -f4- "$1/home/state/.wake-queue" 2>/dev/null; }
wake_count() { wakes "$1" | grep -c 'worker keep-alive' || true; }

# Case 1 (bob-helper, 2026-10-22): a scout paused "awaiting your release" while
# it kept rewording its report. Report edits are not progress, the rewording
# does not restart the clock, and a mate that never releases it is escalated.
test_held_on_the_mate_wakes_then_escalates_once() {
  local dir channel
  dir=$(make_home held scout)
  make_secondmate "$dir" bob-helper
  channel="$dir/parent/state/bob-helper.status"
  status "$dir" "$T0" 'paused [key=breadboard-plugin-trial]: implementation paused, awaiting your release of the 005 implementation hold'
  scan "$dir" "$T0"
  echo 'impact report v1' > "$dir/wt/impact-report.md"
  scan "$dir" $((T0 + 1199))
  assert_equals 0 "$(wake_count "$dir")" "a 20-minute bound woke the mate early"
  echo 'impact report v2, reworded' > "$dir/wt/impact-report.md"
  status "$dir" $((T0 + 1150)) 'paused [key=breadboard-plugin-trial]: report reworded; implementation still paused awaiting your release'
  scan "$dir" $((T0 + 1200))
  assert_equals 1 "$(wake_count "$dir")" "a worker held on its mate for 20 minutes did not wake the mate"
  assert_contains "$(wakes "$dir")" 'decide it now' "the wake is not a concrete instruction"
  assert_contains "$(wakes "$dir")" 'your parent mate is told in 10 minutes' "the wake gives the wrong escalation destination or deadline"
  assert_contains "$(wakes "$dir")" 'never wait for a release' "the wake allows waiting for a release"
  assert_contains "$(wakes "$dir")" 'bin/fm-spawn.sh --relaunch w1' "the wake does not name the relaunch"
  scan "$dir" $((T0 + 1799))
  assert_equals 1 "$(wake_count "$dir")" "the same episode woke the mate twice"
  assert_absent "$channel" "the parent was told before the mate had 10 minutes"
  scan "$dir" $((T0 + 1200 + 600))
  assert_grep "blocked [key=keepalive-bob-helper-w1-$T0]: worker w1 has been stuck (held)" "$channel" "an ignored wake was not escalated"
  assert_grep 'act on it now' "$channel" "the escalation does not tell the parent to act"
  assert_grep 'releasing its hold' "$channel" "the escalation does not say what would unstick it"
  assert_equals 1 "$(wc -l < "$channel" | tr -d ' ')" "the escalation is more than one line"
  scan "$dir" $((T0 + 6000))
  assert_equals 1 "$(wc -l < "$channel" | tr -d ' ')" "the escalation repeated"
  status "$dir" $((T0 + 6100)) 'working [key=breadboard-plugin-trial]: hold released - resuming the build'
  echo 'fn build() {}' > "$dir/wt/build.rs"
  scan "$dir" $((T0 + 6200))
  assert_grep "resolved [key=keepalive-bob-helper-w1-$T0]" "$channel" "a resumed worker did not resolve its escalation"
  pass "a worker held on its mate wakes the mate at 20 minutes and tells its parent 10 minutes later"
}

test_external_wait_is_left_to_the_declared_wait_cadence() {
  local dir
  dir=$(make_home external ship)
  status "$dir" "$T0" 'paused: waiting for the upstream release until 2027-01-16T08:00Z'
  scan "$dir" "$T0"
  scan "$dir" $((T0 + 7200))
  assert_equals 0 "$(wake_count "$dir")" "a declared external wait was treated as stuck"
  pass "an external wait with an until time is not a keep-alive stall"
}

# Case 2 (docana-delivery, 2026-10-22): a blocked worker asked for a "runtime
# owner" after a transient spawn refusal. In the first mate's own home the mate
# is told to unblock it, its steers do not count as a fix, and a worker still
# blocked 30 minutes after the wake reaches the captain as one plain line.
test_spawn_refusal_in_the_first_mates_home_reaches_the_captain() {
  local dir
  dir=$(make_home spawn-refusal ship)
  status "$dir" "$T0" 'blocked [key=spawn]: fm-spawn refused (endpoint superseded); waiting for the runtime owner to approve a relaunch'
  scan "$dir" $((T0 + 1200))
  assert_equals 1 "$(wake_count "$dir")" "a blocked worker did not wake its mate"
  assert_contains "$(wakes "$dir")" 'unblock it in this turn' "the blocked wake is not an instruction"
  assert_contains "$(wakes "$dir")" 'the captain is told in 30 minutes' "the wake gives the wrong escalation destination or deadline"
  assert_contains "$(wakes "$dir")" 'is yours to fix: retry it' "the wake does not say the tooling refusal is the mate's to fix"
  assert_contains "$(wakes "$dir")" 'bin/fm-spawn.sh --relaunch w1' "the wake does not name the relaunch"
  assert_contains "$(wakes "$dir")" 'A steer, acknowledgment or relay is not a fix' "the wake lets an acknowledgment pass as a fix"
  steer "$dir" $((T0 + 1300))
  steer "$dir" $((T0 + 2000))
  scan "$dir" $((T0 + 2999))
  assert_equals 1 "$(wake_count "$dir")" "a steer restarted the episode"
  assert_equals 0 "$(notice_count "$dir" .)" "the captain was told before the first mate had 30 minutes"
  scan "$dir" $((T0 + 3000))
  assert_equals 1 "$(notice_count "$dir" 'worker w1 has been stuck (blocked)')" "a worker the first mate only steered did not reach the captain"
  assert_contains "$(wakes "$dir")" 'the captain was told in one line - keep fixing it' "the first mate was not told the captain knows"
  scan "$dir" $((T0 + 6000))
  assert_equals 1 "$(notice_count "$dir" .)" "the captain line repeated"
  status "$dir" $((T0 + 6100)) 'working: relaunched, spawn succeeded'
  echo 'fn spawn() {}' > "$dir/wt/spawn.rs"
  scan "$dir" $((T0 + 6200))
  assert_equals 1 "$(notice_count "$dir" 'worker w1 is moving again')" "the captain was not told it moved again"
  pass "a refused spawn the first mate only steers reaches the captain 30 minutes after the wake"
}

test_captain_notification_retries_a_failed_supervisor_wake() {
  local dir record kind deadline prior_wakes state_filter offset now
  for kind in worker relay question; do
    prior_wakes=1
    case "$kind" in
      worker)
        dir=$(make_home wake-retry-worker ship)
        record="$dir/home/state/keepalive/w1.json"
        state_filter='.escalated'
        deadline=$((T0 + 3000))
        status "$dir" "$T0" 'blocked: spawn refused; needs a relaunch'
        scan "$dir" $((T0 + 1200))
        ;;
      relay|question)
        dir=$(make_parent "wake-retry-$kind" finn)
        record="$dir/home/state/keepalive/asks/finn.json"
        if [ "$kind" = relay ]; then
          state_filter='.relays | all(.[]; .up)'
          deadline=$((T0 + 1800))
          prior_wakes=0
          ask "$dir" finn "blocked [key=keepalive-finn-helper-ask-$T0]: waiting for an answer"
        else
          state_filter='.asks | all(.[]; .escalated)'
          deadline=$((T0 + 2400))
          ask "$dir" finn 'needs-decision [key=budget-sheet]: which month should the new tab cover?'
        fi
        scan "$dir" "$T0"
        scan "$dir" $((T0 + 600))
        ;;
    esac
    printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$ROOT/bin/fm-notify.sh" > "$dir/bin/notify"
    mkdir "$dir/home/state/bad-queue"
    for offset in 0 300 600; do
      now=$((deadline + offset))
      FM_NOTIFY_NOW="$now" FM_WAKE_QUEUE="$dir/home/state/bad-queue" scan "$dir" "$now"
      assert_equals 1 "$(jq -s 'length' "$dir/home/state/notices"/nt-*.json)" "$kind wake retries published duplicate captain notices"
      assert_equals "$prior_wakes" "$(wake_count "$dir")" "the failed $kind wake unexpectedly reached the supervisor"
      jq -e "($state_filter) == false" "$record" >/dev/null || fail "a failed $kind supervisor wake was marked escalated"
    done
    now=$((deadline + 900))
    FM_NOTIFY_NOW="$now" scan "$dir" "$now"
    assert_equals 1 "$(jq -s 'length' "$dir/home/state/notices"/nt-*.json)" "the successful $kind retry duplicated the captain notice"
    assert_equals "$((prior_wakes + 1))" "$(wake_count "$dir")" "the $kind supervisor wake was not retried"
    assert_contains "$(wakes "$dir")" 'the captain was told in one line' "the retry did not tell the supervisor the captain knows"
    jq -e "($state_filter) == true" "$record" >/dev/null || fail "a successful $kind retry was not marked escalated"
    now=$((deadline + 1200))
    FM_NOTIFY_NOW="$now" scan "$dir" "$now"
    assert_equals 1 "$(jq -s 'length' "$dir/home/state/notices"/nt-*.json)" "a successful $kind retry kept notifying the captain"
    assert_equals "$((prior_wakes + 1))" "$(wake_count "$dir")" "a successful $kind retry kept waking the supervisor"
  done
  pass "worker, relay and question escalations retry failed wakes without duplicate captain notices"
}

# Case 6 (bob-helper, 2026-10-23): the worker's PR step was refused by the PR
# guard over an internal run id; the mate answered with seven "hold, preserve
# evidence, no retry" steers and acknowledgments for two hours. Steers are not a
# fix: 10 minutes after the wake the first mate is told to act, and when it does
# not fix it either, the captain gets one plain line 30 minutes later.
test_pr_guard_refusal_the_mate_only_acknowledges_climbs_to_the_captain() {
  local dir channel parent i
  dir=$(make_home sidebar ship)
  make_secondmate "$dir" bob-helper
  channel="$dir/parent/state/bob-helper.status"
  parent="$dir/parent"
  mkdir -p "$parent/bin"
  printf 'kind=secondmate\n' > "$parent/state/bob-helper.meta"
  make_notify "$parent"
  printf '#!/usr/bin/env bash\necho busy\n' > "$parent/bin/liveness"
  chmod +x "$parent/bin/liveness"
  status "$dir" "$T0" 'blocked: HOLD remains at supported terminal boundary. Run 01M5 failed PR guard because its rendered Review history includes the internal run ID; no supported redaction/publication retry established'
  scan "$dir" $((T0 + 1200))
  assert_equals 1 "$(wake_count "$dir")" "the PR-guard refusal did not wake the mate"
  assert_contains "$(wakes "$dir")" 'a PR guard' "the wake does not name a PR-guard refusal as the mate's to fix"
  assert_contains "$(wakes "$dir")" 'do the step by hand' "the wake does not offer doing the step by hand"
  for i in 1 2 3 4 5 6 7; do
    steer "$dir" $((T0 + 1200 + i * 60))
  done
  status "$dir" $((T0 + 1700)) 'blocked: 010 acknowledged; stopped with evidence/current branch preserved'
  scan "$dir" $((T0 + 1799))
  assert_absent "$channel" "the parent was told before the mate had 10 minutes"
  scan "$dir" $((T0 + 1800))
  assert_grep "blocked [key=keepalive-bob-helper-w1-$T0]: worker w1 has been stuck (blocked)" "$channel" "seven steers kept the episode from the parent"
  assert_grep 'its mate did not fix it' "$channel" "the escalation does not say the mate did not fix it"
  assert_grep 'an acknowledgment is not a fix' "$channel" "the escalation lets the parent acknowledge it"
  assert_equals 1 "$(wake_count "$dir")" "the mate was woken again instead of the parent being told"
  FM_HOME="$parent" FM_KEEPALIVE_NOW=$((T0 + 1900)) FM_KEEPALIVE_LIVENESS="$parent/bin/liveness" \
    FM_KEEPALIVE_NOTIFY="$parent/bin/notify" FM_KEEPALIVE_TASKS=/usr/bin/false "$KEEPALIVE" scan
  FM_HOME="$parent" FM_KEEPALIVE_NOW=$((T0 + 1900 + 1799)) FM_KEEPALIVE_LIVENESS="$parent/bin/liveness" \
    FM_KEEPALIVE_NOTIFY="$parent/bin/notify" FM_KEEPALIVE_TASKS=/usr/bin/false "$KEEPALIVE" scan
  assert_equals 0 "$(notice_count "$parent" .)" "the captain was told before the first mate had 30 minutes"
  FM_HOME="$parent" FM_KEEPALIVE_NOW=$((T0 + 1900 + 1800)) FM_KEEPALIVE_LIVENESS="$parent/bin/liveness" \
    FM_KEEPALIVE_NOTIFY="$parent/bin/notify" FM_KEEPALIVE_TASKS=/usr/bin/false "$KEEPALIVE" scan
  assert_equals 1 "$(notice_count "$parent" 'second mate bob-helper escalated this (first seen')" \
    "a stuck worker the first mate did not fix never reached the captain"
  assert_equals 1 "$(notice_count "$parent" 'worker w1 has been stuck (blocked)')" "the captain line does not say what is stuck"
  status "$dir" $((T0 + 4000)) 'working: PR body sanitized; PR opened by hand'
  printf 'pr=https://github.com/o/r/pull/7\n' >> "$dir/home/state/w1.meta"
  scan "$dir" $((T0 + 4100))
  assert_grep "resolved [key=keepalive-bob-helper-w1-$T0]" "$channel" "the fixed worker did not resolve its escalation"
  FM_HOME="$parent" FM_KEEPALIVE_NOW=$((T0 + 4200)) FM_KEEPALIVE_LIVENESS="$parent/bin/liveness" \
    FM_KEEPALIVE_NOTIFY="$parent/bin/notify" FM_KEEPALIVE_TASKS=/usr/bin/false "$KEEPALIVE" scan
  assert_equals 1 "$(notice_count "$parent" "second mate bob-helper's stuck work is moving again")" "the captain was not told it moved again"
  assert_equals 2 "$(notice_count "$parent" .)" "the captain got more than one line each way"
  pass "a PR-guard refusal the mate only acknowledges reaches the first mate in 10 minutes and the captain 30 minutes later"
}

test_state_override_owns_scans_locks_records_and_wakes() {
  local dir state default_state
  for default_state in absent populated; do
    dir=$(make_home "state-override-$default_state" ship)
    status "$dir" "$T0" 'blocked: needs a retry'
    state="$dir/alternate-state"
    mv "$dir/home/state" "$state"
    if [ "$default_state" = populated ]; then
      mkdir -p "$dir/home/state"
      printf 'kind=ship\nspawn_gen=decoy\n' > "$dir/home/state/decoy.meta"
      printf 'blocked: unrelated worker\n' > "$dir/home/state/decoy.status"
      at "$T0" "$dir/home/state/decoy.status"
    fi
    mkdir -p "$state/keepalive"
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$state" FM_KEEPALIVE_NOW=$((T0 + 1200)) \
      FM_KEEPALIVE_LIVENESS="$dir/bin/liveness" python3 - "$KEEPALIVE" "$state" <<'PY'
import fcntl
import subprocess
import sys
from pathlib import Path
with open(Path(sys.argv[2]) / "keepalive" / ".lock", "a") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    subprocess.run([sys.argv[1], "scan"], check=True, timeout=30)
PY
    assert_absent "$state/keepalive/w1.json" "the scan ignored the override lock"
    FM_STATE_OVERRIDE="$state" scan "$dir" $((T0 + 1200))
    assert_present "$state/keepalive/w1.json" "override metadata was not monitored"
    assert_grep 'worker w1 has been blocked' "$state/.wake-queue" "the wake missed the override queue"
    assert_absent "$dir/home/state/keepalive" "the scan used the default state directory"
    assert_absent "$dir/home/state/.wake-queue" "the wake used the default state directory"
    FM_STATE_OVERRIDE="$state" scan "$dir" $((T0 + 3000))
    assert_grep 'I could not unstick it' "$state/.wake-queue" "override escalation was not delivered"
    rm "$state/w1.meta"
    FM_STATE_OVERRIDE="$state" scan "$dir" $((T0 + 3100))
    assert_absent "$state/keepalive/w1.json" "a departure kept its override episode"
    assert_grep 'left the fleet; the captain was told' "$state/.wake-queue" "override resolution was not delivered"
  done
  pass "the effective state directory owns metadata, lock, episode records and wakes"
}

test_worker_without_a_live_agent_is_relaunched() {
  local dir
  dir=$(make_home dead ship)
  status "$dir" "$T0" 'working: running the suite'
  echo 'dead endpoint-gone' > "$dir/liveness"
  scan "$dir" "$T0"
  scan "$dir" $((T0 + 299))
  assert_equals 0 "$(wake_count "$dir")" "a dead agent woke the mate before five minutes"
  scan "$dir" $((T0 + 300))
  assert_contains "$(wakes "$dir")" 'has had no live agent for 5 minutes: relaunch it (bin/fm-spawn.sh --relaunch w1)' "a dead agent's wake does not say relaunch"
  printf 'kind=ship\nworktree=%s\nspawn_gen=s2\n' "$dir/wt" > "$dir/home/state/w1.meta"
  echo busy > "$dir/liveness"
  scan "$dir" $((T0 + 400))
  assert_absent "$dir/home/state/keepalive/w1.json.tmp" "record write left a temp file"
  jq -e '.cond == null' "$dir/home/state/keepalive/w1.json" >/dev/null || fail "a relaunched worker kept its dead episode"
  pass "a worker with no live agent wakes its mate to relaunch it after five minutes"
}

test_no_real_progress_counts_code_not_reports() {
  local dir
  dir=$(make_home progress ship)
  status "$dir" "$T0" 'working: fixing the parser'
  scan "$dir" "$T0"
  mkdir -p "$dir/wt/notes"
  echo a > "$dir/wt/notes/plan.txt"
  echo a > "$dir/wt/REPORT.md"
  status "$dir" $((T0 + 600)) 'working: still fixing the parser'
  scan "$dir" $((T0 + 600))
  scan "$dir" $((T0 + 1199))
  assert_equals 0 "$(wake_count "$dir")" "woke before 20 minutes without progress"
  scan "$dir" $((T0 + 1200))
  assert_contains "$(wakes "$dir")" 'has made no real progress for 20 minutes' "report-only edits counted as progress"
  echo 'fn parse() {}' > "$dir/wt/parser.rs"
  scan "$dir" $((T0 + 1300))
  jq -e '.cond == null and .fp_since == '$((T0 + 1300)) "$dir/home/state/keepalive/w1.json" >/dev/null \
    || fail "a code change was not counted as progress"
  git -C "$dir/wt" add parser.rs && git -C "$dir/wt" -c user.email=t@t -c user.name=t commit -q -m parse
  scan "$dir" $((T0 + 2400))
  jq -e '.fp_since == '$((T0 + 2400)) "$dir/home/state/keepalive/w1.json" >/dev/null || fail "a commit was not counted as progress"
  assert_equals 1 "$(wake_count "$dir")" "progress woke the mate"
  pass "real progress is commits and code changes, never report or status edits"
}

test_done_worker_and_departures() {
  local dir channel
  dir=$(make_home finished ship)
  printf 'pr=https://github.com/o/r/pull/7\n' >> "$dir/home/state/w1.meta"
  status "$dir" "$T0" 'done: PR opened'
  scan "$dir" $((T0 + 9000))
  assert_equals 0 "$(wake_count "$dir")" "a finished worker waiting on its PR was treated as stuck"
  dir=$(make_home departs scout)
  make_secondmate "$dir" docana
  channel="$dir/parent/state/docana.status"
  status "$dir" "$T0" 'blocked: needs the mate to approve the retry'
  scan "$dir" $((T0 + 1200))
  scan "$dir" $((T0 + 3000))
  assert_grep "blocked [key=keepalive-docana-w1-$T0]" "$channel" "setup: the worker was escalated"
  rm "$dir/home/state/w1.meta"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" FM_KEEPALIVE_NOW=$((T0 + 3100)) \
    bash -c '. "$1/bin/fm-watch.sh"; keepalive_detached; wait' _ "$ROOT"
  assert_grep "resolved [key=keepalive-docana-w1-$T0]: worker w1 left the fleet" "$channel" "a departed worker left its escalation open"
  assert_absent "$dir/home/state/keepalive/w1.json" "a departed worker's record was kept"
  pass "a done worker is ignored and a departing worker resolves its escalation"
}

# Case 3 (airtyping, 2026-10-21): a finished scout's report was swallowed on
# its way to the conversation waiting for it. A finished worker still in the
# fleet past the cleanup cadence tells its mate to make sure the result landed.
test_finished_result_that_never_left_is_raised() {
  local dir
  dir=$(make_home undelivered scout)
  status "$dir" "$T0" 'done [key=gapses]: report at data/w1/report.md'
  scan "$dir" $((T0 + 599))
  assert_equals 0 "$(wake_count "$dir")" "a finished worker woke the mate before 10 minutes"
  scan "$dir" $((T0 + 600))
  assert_contains "$(wakes "$dir")" 'send its result to the conversation that asked for it' "an undelivered result did not wake the mate"
  assert_contains "$(wakes "$dir")" '--result' "the wake does not name the result send"
  assert_contains "$(wakes "$dir")" 'then retire the worker' "the wake does not say to retire the worker"
  rm "$dir/home/state/w1.meta"
  scan "$dir" $((T0 + 700))
  assert_absent "$dir/home/state/keepalive/w1.json" "a cleaned-up worker kept its record"
  pass "a finished worker that lingers wakes its mate to deliver its result and retire it"
}

# Case 5 (bob-helper, 2026-10-23): the scout's task was accepted (backlog done)
# while its last status still read working:, the result never reached the
# airtyping conversation (last result sent 03:01Z, before the acceptance), and
# the idle worker sat for 7 hours. The accepted task wakes the mate in 10
# minutes, naming where the captain is waiting and when a result last went there.
test_accepted_task_without_a_delivered_result_wakes_the_mate() {
  local dir
  dir=$(make_home accepted scout)
  status "$dir" "$T0" 'working: 033 handled. The mate declared the deliverable ACCEPTED'
  echo idle > "$dir/liveness"
  printf '#!/usr/bin/env bash\nprintf "tasks[1]{id,state,kind,repo,title}:\\n  w1,done,scout,airtyping,trial\\n"\n' > "$dir/bin/tasks"
  chmod +x "$dir/bin/tasks"
  mkdir -p "$dir/home/state/captain-direct"
  printf 'task_id=airtyping\nepoch=%s\n' "$T0" > "$dir/home/state/captain-direct/4c37f425050f832c"
  printf '2026-10-23T03:01:05Z result-sent corr=2ec8f4ffd797c5df task=airtyping\n' > "$dir/home/state/captain-direct.log"
  FM_KEEPALIVE_TASKS="$dir/bin/tasks" scan "$dir" $((T0 + 100))
  FM_KEEPALIVE_TASKS="$dir/bin/tasks" scan "$dir" $((T0 + 699))
  assert_equals 0 "$(wake_count "$dir")" "an accepted task woke the mate before 10 minutes"
  FM_KEEPALIVE_TASKS="$dir/bin/tasks" scan "$dir" $((T0 + 700))
  assert_equals 1 "$(wake_count "$dir")" "an accepted task still in the fleet did not wake the mate"
  assert_contains "$(wakes "$dir")" 'airtyping, last result sent 2026-10-23T03:01:05Z' "the wake does not say where the captain waits"
  assert_contains "$(wakes "$dir")" 'then retire the worker' "the wake does not say to retire the accepted worker"
  pass "an accepted task whose result was not delivered wakes the mate to deliver it and retire the worker"
}

test_repeated_episodes_have_distinct_parent_keys() {
  local dir channel epoch key
  dir=$(make_home repeated scout)
  make_secondmate "$dir" repeated
  channel="$dir/parent/state/repeated.status"
  for epoch in "$T0" $((T0 + 4000)); do
    status "$dir" "$epoch" 'paused: awaiting your release'
    scan "$dir" $((epoch + 1200))
    scan "$dir" $((epoch + 3000))
    key="keepalive-repeated-w1-$epoch"
    assert_grep "blocked [key=$key]" "$channel" "the episode did not publish its blocker"
    status "$dir" $((epoch + 3100)) 'working: resumed'
    echo "$epoch" > "$dir/wt/parser.rs"
    # Same-size edits may share a wall-clock second on fast runners; use the
    # fixture clock so each episode observes a distinct real-progress mtime.
    at "$((epoch + 3100))" "$dir/wt/parser.rs"
    scan "$dir" $((epoch + 3100))
    assert_grep "resolved [key=$key]: worker w1 is moving again" "$channel" "the episode did not resolve its blocker"
  done
  assert_equals 4 "$(wc -l < "$channel" | tr -d ' ')" "repeated episodes were deduplicated"
  pass "each escalation and resolution pair has its own episode key"
}

test_supervisor_declared_wait_defers_stalls_until_expiry() {
  local dir verb
  for verb in working paused; do
    dir=$(make_home "declared-$verb" ship)
    status "$dir" "$T0" "$verb: awaiting your release after install"
    FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" bash -c '
      . "$1/bin/fm-external-wait.sh"
      fm_external_wait_now_epoch() { echo 1800000000; }
      fm_external_wait_declare w1 --reason "provider outage" --until 2027-01-15T10:00:00Z
    ' _ "$ROOT" >/dev/null || fail "could not declare the external wait"
    scan "$dir" "$T0"
    scan "$dir" $((T0 + 4000))
    assert_equals 0 "$(wake_count "$dir")" "an active supervisor declaration did not defer $verb"
    scan "$dir" $((T0 + 7200))
    assert_equals 1 "$(wake_count "$dir")" "an expired declaration still deferred $verb"
  done
  dir=$(make_home declared-events ship)
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" bash -c '
    . "$1/bin/fm-external-wait.sh"
    fm_external_wait_now_epoch() { echo 1800000000; }
    fm_external_wait_declare w1 --reason "provider outage" --until 2027-01-15T10:00:00Z
  ' _ "$ROOT" >/dev/null || fail "could not declare the external wait"
  status "$dir" "$T0" 'blocked: needs a retry'
  scan "$dir" $((T0 + 1200))
  assert_equals 1 "$(wake_count "$dir")" "a declaration suppressed a new blocker"
  status "$dir" $((T0 + 1300)) 'done: report ready'
  scan "$dir" $((T0 + 4000))
  assert_equals 2 "$(wake_count "$dir")" "a declaration suppressed an undelivered result"
  status "$dir" $((T0 + 4100)) 'working: retrying'
  echo dead > "$dir/liveness"
  scan "$dir" $((T0 + 4100))
  scan "$dir" $((T0 + 4400))
  assert_equals 3 "$(wake_count "$dir")" "a declaration suppressed a dead agent"
  pass "supervisor declarations defer stalls, expire, and preserve new events"
}

test_watcher_keepalive_guard_stays_cheap_and_obeys_cadence() {
  local dir
  dir=$(make_home watcher-guard ship)
  rm "$dir/home/state/w1.meta"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" bash -c '
    . "$1/bin/fm-watch.sh"
    keepalive_detached
    wait
  ' _ "$ROOT"
  assert_absent "$dir/home/state/.last-keepalive" "an empty home launched a scan"
  mkdir -p "$dir/home/state/keepalive"
  echo '{}' > "$dir/home/state/keepalive/w1.json"
  touch "$dir/home/state/.last-keepalive"
  FM_HOME="$dir/home" FM_STATE_OVERRIDE="$dir/home/state" bash -c '
    . "$1/bin/fm-watch.sh"
    keepalive_detached
    wait
  ' _ "$ROOT"
  assert_present "$dir/home/state/keepalive/w1.json" "the watcher ignored its scan cadence"
  pass "the watcher skips empty homes and keeps the scan cadence"
}

# A home whose only record is second mate <mate>, with its parent channel.
make_parent() {  # <name> <mate>
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/bin"
  printf 'kind=secondmate\n' > "$dir/home/state/$2.meta"
  printf '#!/usr/bin/env bash\necho busy\n' > "$dir/bin/liveness"
  chmod +x "$dir/bin/liveness"
  make_notify "$dir"
  printf '%s\n' "$dir"
}

ask() {  # <dir> <mate> <line>
  printf '%s\n' "$3" >> "$1/home/state/$2.status"
}

test_legacy_fold_cache_discovers_keepalive_relays() {
  local dir record
  dir=$(make_parent legacy-cache finn)
  record="$dir/home/state/keepalive/asks/finn.json"
  ask "$dir" finn "blocked [key=keepalive-finn-helper-ask-$T0]: waiting for an answer"
  mkdir -p "$(dirname "$record")"
  python3 - "$dir/home/state/finn.status" "$record" <<'PY'
import json, pathlib, sys
st = pathlib.Path(sys.argv[1]).stat()
pathlib.Path(sys.argv[2]).write_text(json.dumps({
    "sig": f"{st.st_ino}:{st.st_size}:{st.st_mtime_ns}", "open": {}, "asks": {}
}))
PY
  scan "$dir" "$T0"
  jq -e --argjson first "$T0" '
    .relays | length == 1 and all(.[]; .first == $first and .up == false)
  ' "$record" >/dev/null || fail "the legacy fold cache hid an unchanged open relay"
  scan "$dir" $((T0 + 1799))
  assert_equals 0 "$(notice_count "$dir" .)" "the upgraded relay escalated early"
  scan "$dir" $((T0 + 1800))
  assert_equals 1 "$(notice_count "$dir" 'escalated this')" "the upgraded relay did not reach the captain"
  scan "$dir" $((T0 + 2100))
  assert_equals 1 "$(notice_count "$dir" .)" "the upgraded relay escalated repeatedly"
  pass "legacy fold caches are recomputed before tracking unchanged keepalive relays"
}

test_refreshed_keepalive_relays_preserve_the_episode() {
  local dir key record note
  dir=$(make_parent refreshed-relay finn)
  key="keepalive-finn-helper-ask-$T0"
  record="$dir/home/state/keepalive/asks/finn.json"
  ask "$dir" finn "blocked [key=$key]: waiting for an answer to 1 question"
  scan "$dir" "$T0"
  note='waiting for an answer to 2 questions'
  ask "$dir" finn "blocked [key=$key]: $note"
  scan "$dir" $((T0 + 1740))
  scan "$dir" $((T0 + 1799))
  assert_equals 0 "$(notice_count "$dir" .)" "a refreshed relay escalated early"
  scan "$dir" $((T0 + 1800))
  assert_equals 1 "$(notice_count "$dir" 'escalated this (first seen 2027-01-15 08:00:00 UTC)')" "a refreshed relay missed its original deadline"
  assert_equals 1 "$(notice_count "$dir" "$note")" "the escalation omitted the refreshed note"
  note='waiting for an answer to 1 remaining question'
  ask "$dir" finn "blocked [key=$key]: $note"
  scan "$dir" $((T0 + 1900))
  scan "$dir" $((T0 + 4000))
  jq -e --argjson first "$T0" --arg note "$note" '
    .relays | length == 1 and all(.[]; .first == $first and .up == true and .note == $note)
  ' "$record" >/dev/null || fail "a refreshed relay reset its first-seen time or escalation state"
  assert_equals 1 "$(notice_count "$dir" .)" "a note refresh repeated the escalation or falsely resolved it"
  ask "$dir" finn "resolved [key=$key]: answered"
  ask "$dir" finn "blocked [key=$key]: $note"
  scan "$dir" $((T0 + 4100))
  assert_equals 1 "$(notice_count "$dir" 'stuck work is moving again')" "an actual closure between scans did not resolve the old episode"
  jq -e --argjson first "$((T0 + 4100))" '
    .relays | length == 1 and all(.[]; .first == $first and .up == false)
  ' "$record" >/dev/null || fail "a reopened relay inherited the old episode"
  scan "$dir" $((T0 + 5899))
  assert_equals 1 "$(notice_count "$dir" 'escalated this')" "a reopened relay escalated before its fresh deadline"
  scan "$dir" $((T0 + 5900))
  assert_equals 2 "$(notice_count "$dir" 'escalated this')" "a reopened relay did not escalate on its fresh deadline"
  ask "$dir" finn "resolved [key=$key]: all questions answered"
  scan "$dir" $((T0 + 6000))
  scan "$dir" $((T0 + 6100))
  assert_equals 2 "$(notice_count "$dir" 'stuck work is moving again')" "an actual closure did not resolve the reopened relay exactly once"
  jq -e '.relays == {}' "$record" >/dev/null || fail "a closed relay stayed open"
  pass "relay note refreshes preserve deadlines and escalation state while reopenings start fresh episodes"
}

# Case 4 (bob-helper, 2026-10-22): the mate asked its parent which breadboard
# tool the captain meant and sat ~1.5 h unanswered. After 10 minutes the parent
# is woken with the question in front of it; an answer closes it quietly.
test_unanswered_mate_question_wakes_the_parent() {
  local dir
  dir=$(make_parent asked bob-helper)
  ask "$dir" bob-helper 'working [corr=1a]: building the breadboard'
  ask "$dir" bob-helper 'needs-decision [corr=4c37f425050f832c]: which breadboard tool did the captain mean, Fritzing or KiCad Breadboard Builder?'
  ask "$dir" bob-helper 'blocked [key=keepalive-bob-helper-w1-1]: machine escalation the keep-alive owns'
  scan "$dir" "$T0"
  scan "$dir" $((T0 + 599))
  assert_equals 0 "$(wake_count "$dir")" "a question woke the parent before 10 minutes"
  scan "$dir" $((T0 + 600))
  assert_equals 1 "$(wake_count "$dir")" "an unanswered question did not wake the parent"
  assert_contains "$(wakes "$dir")" 'which breadboard tool did the captain mean' "the wake does not show the question"
  assert_contains "$(wakes "$dir")" "the captain's own earlier words beat a relay" "the wake does not say to answer from the captain's words"
  assert_contains "$(wakes "$dir")" 'bin/fm-send.sh bob-helper --resolve-key default' "the wake does not say how to answer"
  assert_not_contains "$(wakes "$dir")" 'machine escalation' "a machine escalation was treated as a question"
  scan "$dir" $((T0 + 900))
  assert_equals 1 "$(wake_count "$dir")" "the same question woke the parent twice"
  ask "$dir" bob-helper 'resolved [key=default]: answered: KiCad Breadboard Builder, per the captain'
  scan "$dir" $((T0 + 3000))
  assert_equals 1 "$(wakes "$dir" | grep -c 'for your answer to')" "an answered question escalated"
  assert_equals 0 "$(notice_count "$dir" 'which breadboard tool')" "an answered question reached the captain"
  jq -e '.asks == {}' "$dir/home/state/keepalive/asks/bob-helper.json" >/dev/null || fail "an answered question stayed open"
  pass "an unanswered second mate question wakes its parent at 10 minutes and an answer closes it"
}

test_a_question_the_parent_never_answers_reaches_the_captain_once() {
  local dir
  dir=$(make_parent ignored finn)
  ask "$dir" finn 'needs-decision [key=budget-sheet]: which month should the new tab cover?'
  scan "$dir" "$T0"
  scan "$dir" $((T0 + 600))
  ask "$dir" finn 'needs-decision [key=bank-item]: Inter or Nubank for the import?'
  scan "$dir" $((T0 + 700))
  scan "$dir" $((T0 + 1300))
  assert_equals 2 "$(wake_count "$dir")" "a later question did not get its own wake"
  scan "$dir" $((T0 + 600 + 1800))
  assert_equals 1 "$(notice_count "$dir" .)" "an ignored question was not escalated once"
  assert_equals 1 "$(notice_count "$dir" 'which month should the new tab cover')" "the escalation does not name the question"
  scan "$dir" $((T0 + 1300 + 1800))
  assert_equals 2 "$(notice_count "$dir" 'has waited')" "the later question was not escalated in its turn"
  scan "$dir" $((T0 + 6000))
  assert_equals 2 "$(notice_count "$dir" 'has waited')" "an escalation repeated"
  ask "$dir" finn 'resolved [key=budget-sheet]: answered: November'
  ask "$dir" finn 'resolved [key=bank-item]: answered: Inter'
  scan "$dir" $((T0 + 6100))
  assert_equals 1 "$(notice_count "$dir" "second mate finn's questions are answered")" "answered questions did not clear the escalation"
  pass "a question the parent never answers reaches the captain as one line and clears when answered"
}

test_reopened_questions_get_fresh_deadlines() {
  local dir mode note
  for mode in same reopened held; do
    dir=$(make_parent "reask-$mode" finn)
    note='which route should I take?'
    ask "$dir" finn "needs-decision [key=route]: $note"
    scan "$dir" "$T0"
    scan "$dir" $((T0 + 600))
    scan "$dir" $((T0 + 2400))
    if [ "$mode" = held ]; then
      ask "$dir" finn 'captain-held [key=route]: the captain must choose the route'
    else
      ask "$dir" finn 'resolved [key=route]: answered: take the local route'
    fi
    if [ "$mode" != same ]; then
      note='the local route failed; which route should I take now?'
    fi
    ask "$dir" finn "needs-decision [key=route]: $note"
    scan "$dir" $((T0 + 2600))
    scan "$dir" $((T0 + 3199))
    assert_equals 1 "$(wakes "$dir" | grep -c 'for your answer to')" "a $mode question did not start a fresh 10-minute clock"
    scan "$dir" $((T0 + 3200))
    assert_equals 2 "$(wakes "$dir" | grep -c 'for your answer to')" "a $mode question inherited the previous wake"
    assert_contains "$(wakes "$dir" | grep 'for your answer to' | tail -1)" "$note" "the fresh wake omitted the current question"
    scan "$dir" $((T0 + 4999))
    assert_equals 1 "$(notice_count "$dir" 'has waited')" "a $mode question inherited the previous escalation deadline"
    scan "$dir" $((T0 + 5000))
    scan "$dir" $((T0 + 5100))
    assert_equals 2 "$(notice_count "$dir" 'has waited')" "a $mode question did not escalate exactly once"
  done
  pass "same-key reopenings between scans get fresh wake and escalation deadlines"
}

test_open_question_reposts_preserve_the_episode() {
  local dir mode note channel folded record
  for mode in identical reworded; do
    dir=$(make_parent "repost-$mode" finn)
    make_secondmate "$dir" parent-mate
    channel="$dir/parent/state/parent-mate.status"
    record="$dir/home/state/keepalive/asks/finn.json"
    note='which route should I take?'
    ask "$dir" finn "needs-decision [key=route]: $note"
    scan "$dir" "$T0"
    if [ "$mode" = reworded ]; then
      note='which local route should I take?'
    fi
    ask "$dir" finn "needs-decision [key=route]: $note"
    scan "$dir" $((T0 + 300))
    scan "$dir" $((T0 + 600))
    assert_equals 1 "$(wake_count "$dir")" "a $mode repost postponed the first wake"
    assert_contains "$(wakes "$dir")" "$note" "the wake omitted the current question"
    scan "$dir" $((T0 + 2400))
    assert_equals 1 "$(grep -c '^blocked ' "$channel")" "the question did not escalate on its original deadline"
    if [ "$mode" = reworded ]; then
      note='which local route should I take next?'
    fi
    ask "$dir" finn "needs-decision [key=route]: $note"
    scan "$dir" $((T0 + 2600))
    scan "$dir" $((T0 + 3200))
    jq -e --argjson first "$T0" --argjson woke "$((T0 + 600))" --arg note "$note" '
      .asks | length == 1 and all(.[];
        .first == $first and .woke == $woke and .escalated == true and .note == $note)
    ' "$record" >/dev/null || fail "a $mode repost reset the episode after escalation"
    assert_equals 1 "$(wake_count "$dir")" "a $mode repost woke the parent again"
    assert_equals 0 "$(grep -c '^resolved ' "$channel" || true)" "a $mode repost falsely reported the question answered"
    folded=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$channel")
    assert_contains "$folded" "$note" "the unanswered question disappeared from the parent blocker"
    ask "$dir" finn 'resolved [key=route]: take the local route'
    scan "$dir" $((T0 + 3300))
    assert_equals 1 "$(grep -c '^resolved ' "$channel")" "an actual answer did not close the escalation"
  done
  pass "identical and reworded open-key reposts preserve wake and escalation state"
}

test_escalation_tracks_all_still_open_questions() {
  local dir closed remaining channel folded key
  for closed in budget-sheet bank-item; do
    dir=$(make_parent "escalation-$closed" finn)
    make_secondmate "$dir" parent-mate
    channel="$dir/parent/state/parent-mate.status"
    key="keepalive-parent-mate-finn-ask-$T0"
    ask "$dir" finn 'needs-decision [key=budget-sheet]: which month should the new tab cover?'
    scan "$dir" "$T0"
    scan "$dir" $((T0 + 600))
    ask "$dir" finn 'needs-decision [key=bank-item]: Inter or Nubank for the import?'
    scan "$dir" $((T0 + 700))
    scan "$dir" $((T0 + 1300))
    scan "$dir" $((T0 + 2400))
    assert_grep "blocked [key=$key]:" "$channel" "the first escalation did not reach the parent channel"
    scan "$dir" $((T0 + 3100))
    folded=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$channel")
    assert_contains "$folded" "$key" "a later batch changed the blocker key"
    assert_equals 1 "$(printf '%s\n' "$folded" | wc -l | tr -d ' ')" "the mate has more than one open blocker"
    assert_contains "$folded" 'answer to 2 questions' "the later batch omitted the earlier escalated question"
    assert_contains "$folded" 'which month should the new tab cover?' "the blocker no longer names the oldest open question"
    ask "$dir" finn "resolved [key=$closed]: answered"
    scan "$dir" $((T0 + 3200))
    scan "$dir" $((T0 + 3300))
    folded=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$channel")
    assert_contains "$folded" "$key" "a partial answer resolved or replaced the blocker key"
    assert_contains "$folded" 'answer to 1 question' "a partial answer did not refresh the outstanding count"
    if [ "$closed" = bank-item ]; then
      remaining=budget-sheet
      assert_contains "$folded" 'which month should the new tab cover?' "answering the newer question hid the older one"
    else
      remaining=bank-item
      assert_contains "$folded" 'Inter or Nubank for the import?' "answering the oldest question left a stale question visible"
    fi
    assert_equals 3 "$(grep -c '^blocked ' "$channel")" "the blocker was not refreshed exactly on set changes"
    assert_equals 0 "$(grep -c '^resolved ' "$channel" || true)" "a partial answer prematurely cleared the blocker"
    ask "$dir" finn "resolved [key=$remaining]: answered"
    scan "$dir" $((T0 + 3400))
    scan "$dir" $((T0 + 3500))
    folded=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$channel")
    assert_equals '' "$folded" "the empty escalation set left an open blocker"
    assert_equals 1 "$(grep -c '^resolved ' "$channel")" "the final answer did not resolve the blocker exactly once"
  done
  pass "escalations keep one current blocker across additions and partial answers"
}

test_stall_condition_changes_keep_the_original_deadline() {
  local dir channel record
  dir=$(make_home stall-transitions ship)
  make_secondmate "$dir" bob-helper
  channel="$dir/parent/state/bob-helper.status"
  record="$dir/home/state/keepalive/w1.json"
  status "$dir" "$T0" 'blocked: PR guard refused the generated text'
  scan "$dir" "$T0"
  status "$dir" $((T0 + 300)) 'working: acknowledged; preserving evidence'
  scan "$dir" $((T0 + 300))
  jq -e --argjson since "$T0" '.cond == "no-progress" and .since == $since and .woke == 0' "$record" >/dev/null \
    || fail "a status-only acknowledgment cleared the stall before its wake"
  status "$dir" $((T0 + 600)) 'blocked: PR guard still refuses the text'
  scan "$dir" $((T0 + 1200))
  status "$dir" $((T0 + 1700)) 'paused: preserving evidence pending your release'
  scan "$dir" $((T0 + 1799))
  assert_equals 1 "$(wake_count "$dir")" "a hold acknowledgment restarted the wake"
  assert_absent "$channel" "a condition change escalated early"
  jq -e --argjson since "$T0" --argjson woke "$((T0 + 1200))" '
    .cond == "held" and .since == $since and .first == $since and .woke == $woke and .escalated == false
  ' "$record" >/dev/null || fail "a hold acknowledgment reset the stall episode"
  scan "$dir" $((T0 + 1800))
  assert_grep "blocked [key=keepalive-bob-helper-w1-$T0]: worker w1 has been stuck (held)" "$channel" "the hold did not escalate on the original deadline"
  status "$dir" $((T0 + 1900)) 'blocked: PR guard still needs corrected text'
  scan "$dir" $((T0 + 1900))
  status "$dir" $((T0 + 2000)) 'working: acknowledged; preserving evidence'
  scan "$dir" $((T0 + 2000))
  jq -e --argjson since "$T0" --argjson woke "$((T0 + 1200))" '
    .cond == "no-progress" and .since == $since and .first == $since and .woke == $woke and .escalated == true
  ' "$record" >/dev/null || fail "a status-only change reset the escalated episode"
  assert_equals 1 "$(wc -l < "$channel" | tr -d ' ')" "a status-only change falsely resolved the parent key"
  echo 'fn corrected() {}' > "$dir/wt/fix.rs"
  scan "$dir" $((T0 + 2100))
  assert_grep "resolved [key=keepalive-bob-helper-w1-$T0]: worker w1 is moving again" "$channel" "real progress did not resolve the original key"
  pass "blocked, held and no-progress transitions preserve the wake deadline and parent key"
}

test_legacy_escalations_notify_the_captain_once() {
  local dir record kind
  for kind in worker question; do
    if [ "$kind" = worker ]; then
      dir=$(make_home legacy-worker ship)
      record="$dir/home/state/keepalive/w1.json"
      status "$dir" "$T0" 'blocked: spawn refused; needs a relaunch'
      scan "$dir" "$T0"
      scan "$dir" $((T0 + 1200))
      jq '.escalated = true | del(.captain_notified)' "$record" > "$record.fixture"
    else
      dir=$(make_parent legacy-question finn)
      record="$dir/home/state/keepalive/asks/finn.json"
      ask "$dir" finn 'needs-decision [key=budget-sheet]: which month should the new tab cover?'
      scan "$dir" "$T0"
      scan "$dir" $((T0 + 600))
      jq --argjson first "$T0" '
        .asks |= with_entries(.value.escalated = true) |
        .esc_ids = (.asks | keys | sort) | .esc_first = $first | del(.captain_notified, .relays)
      ' "$record" > "$record.fixture"
    fi
    mv "$record.fixture" "$record"
    printf '#!/usr/bin/env bash\nexit 1\n' > "$dir/bin/notify"
    scan "$dir" $((T0 + 3300))
    jq -e '.captain_notified != true' "$record" >/dev/null || fail "a failed legacy $kind notification was marked delivered"
    make_notify "$dir"
    scan "$dir" $((T0 + 3600))
    assert_equals 1 "$(notice_count "$dir" .)" "a legacy $kind escalation bypassed captain notification"
    assert_contains "$(wakes "$dir")" 'the captain was told in one line' "the legacy $kind escalation did not wake the supervisor"
    jq -e '.captain_notified == true' "$record" >/dev/null || fail "the legacy $kind escalation was not marked delivered"
    scan "$dir" $((T0 + 3900))
    assert_equals 1 "$(notice_count "$dir" .)" "the migrated $kind escalation repeatedly notified the captain"
  done
  pass "legacy worker and question escalations retry captain notification and migrate once"
}

# A stand-in for `gh pr view` that prints $dir/pr.json for any URL.
make_pr() {  # <dir> <state> <mergeable> <merge-state> <conclusion>
  printf '{"state":"%s","isDraft":false,"mergeable":"%s","mergeStateStatus":"%s","statusCheckRollup":[{"__typename":"CheckRun","status":"COMPLETED","name":"a","conclusion":"%s","startedAt":"2027-01-15T08:00:00Z","completedAt":"2027-01-15T08:10:00Z"},{"__typename":"CheckRun","status":"COMPLETED","name":"b","conclusion":"SUCCESS","startedAt":"2027-01-15T08:00:00Z","completedAt":"2027-01-15T08:10:00Z"}]}\n' \
    "$2" "$3" "$4" "$5" > "$1/pr.json"
  printf '#!/usr/bin/env bash\ncat "%s/pr.json"\n' "$1" > "$1/bin/pr"
  chmod +x "$1/bin/pr"
}

# Case 7 (primary, 2026-10-21..23): bastotec/firstmate#255 sat green and clean
# for two days because nothing merged it. A worker's green, mergeable PR that is
# still open 30 minutes after it went green wakes its mate to merge it, and the
# wake clears once the PR merges.
test_green_pr_left_unmerged_wakes_the_mate_to_merge_it() {
  local dir
  dir=$(make_home green-unmerged ship)
  printf 'pr=https://github.com/o/r/pull/255\n' >> "$dir/home/state/w1.meta"
  status "$dir" "$T0" 'done: PR ready https://github.com/o/r/pull/255'
  make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 1799))
  assert_equals 0 "$(wake_count "$dir")" "a green PR woke the mate before 30 minutes"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 1800))
  assert_equals 1 "$(wake_count "$dir")" "a green PR left open 30 minutes did not wake the mate"
  assert_contains "$(wakes "$dir")" 'green and mergeable for 30 minutes and is not merged: merge it now with bin/fm-pr-merge.sh w1' \
    "the wake does not tell the mate to merge it"
  make_pr "$dir" MERGED UNKNOWN UNKNOWN SUCCESS
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 1900))
  jq -e '.cond == null' "$dir/home/state/keepalive/w1.json" >/dev/null || fail "a merged PR left its episode open"
  pass "a green PR still unmerged 30 minutes later wakes the mate to merge it, and merging clears it"
}

# Case 8 (primary, 2026-10-17..23): bastotec/firstmate#210 went conflicting with
# one cancelled check while its run sat in the CI step for six days. A run in
# its CI step for 2 hours with the PR still open and not green wakes the mate to
# land or close it, naming what is wrong.
test_run_stuck_in_its_ci_step_wakes_the_mate_to_land_or_close() {
  local dir
  dir=$(make_home ci-stuck ship)
  printf 'pr=https://github.com/o/r/pull/210\n' >> "$dir/home/state/w1.meta"
  printf 'run=01M5\nstep=ci\nverdict=\n' > "$dir/home/state/w1.crew-state"
  status "$dir" "$T0" 'working: validation reached CI'
  make_pr "$dir" OPEN CONFLICTING DIRTY CANCELLED
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 7199))
  assert_equals 0 "$(wake_count "$dir")" "a run in its CI step woke the mate before 2 hours"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 7200))
  assert_equals 1 "$(wake_count "$dir")" "a run 2 hours in its CI step did not wake the mate"
  assert_contains "$(wakes "$dir")" 'sat in its CI step for 120 minutes' "the wake does not say how long it sat"
  assert_contains "$(wakes "$dir")" 'mergeable conflicting, checks cancelled' "the wake does not say what is wrong with the PR"
  assert_contains "$(wakes "$dir")" 'rebase a conflicting branch' "the wake does not say to rebase it"
  pass "a run stuck 2 hours in its CI step wakes the mate to land or close its PR"
}

test_mature_pr_conditions_supersede_stale_worker_classifications() {
  local dir fallback cond mature
  for fallback in blocked dead; do
    for cond in unmerged ci-stuck; do
      dir=$(make_home "pr-precedence-$fallback-$cond" ship)
      printf 'pr=https://github.com/o/r/pull/255\n' >> "$dir/home/state/w1.meta"
      printf 'run=01M5\nstep=ci\n' > "$dir/home/state/w1.crew-state"
      status "$dir" "$T0" 'blocked: validation needs a retry'
      [ "$fallback" != dead ] || echo dead > "$dir/liveness"
      make_pr "$dir" OPEN CONFLICTING DIRTY CANCELLED
      FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
      FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 1200))
      FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 3000))
      jq -e --arg cond "$fallback" '.cond == $cond and .escalated' \
        "$dir/home/state/keepalive/w1.json" >/dev/null || fail "setup: $fallback was not escalated"
      if [ "$cond" = unmerged ]; then
        make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
        FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 3001))
        mature=$((T0 + 4801))
      else
        mature=$((T0 + 7200))
      fi
      FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$mature"
      jq -e --arg cond "$cond" --argjson now "$mature" '.cond == $cond and .woke == $now and (.escalated | not)' \
        "$dir/home/state/keepalive/w1.json" >/dev/null || fail "$fallback masked mature $cond"
      if [ "$cond" = unmerged ]; then
        assert_contains "$(wakes "$dir")" 'merge it now with bin/fm-pr-merge.sh w1' "no merge wake replaced $fallback"
      else
        assert_contains "$(wakes "$dir")" 'land it or close it now' "no CI recovery wake replaced $fallback"
      fi
      printf '#!/usr/bin/env bash\nprintf "tasks[1]{id,state,kind,repo,title}:\\n  w1,done,ship,o/r,trial\\n"\n' > "$dir/bin/tasks"
      chmod +x "$dir/bin/tasks"
      FM_KEEPALIVE_TASKS="$dir/bin/tasks" FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((mature + 1))
      jq -e '.cond == "undelivered"' "$dir/home/state/keepalive/w1.json" >/dev/null \
        || fail "a mature PR condition overrode backlog acceptance"
    done
  done
  pass "mature PR conditions replace stale blockers and dead agents but not backlog acceptance"
}

test_green_pr_during_aged_ci_waits_for_its_merge_deadline() {
  local dir
  dir=$(make_home ci-turns-green ship)
  printf 'pr=https://github.com/o/r/pull/255\n' >> "$dir/home/state/w1.meta"
  printf 'run=01M5\nstep=ci\n' > "$dir/home/state/w1.crew-state"
  status "$dir" "$T0" 'working: validation reached CI'
  make_pr "$dir" OPEN MERGEABLE CLEAN PENDING
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
  make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 7140))
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 7200))
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 8939))
  assert_equals 0 "$(wake_count "$dir")" "healthy CI triggered recovery before the green PR deadline"
  jq -e '.cond == null' "$dir/home/state/keepalive/w1.json" >/dev/null \
    || fail "a green PR in aged CI was classified as stuck"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 8940))
  jq -e '.cond == "unmerged"' "$dir/home/state/keepalive/w1.json" >/dev/null \
    || fail "a green PR in aged CI missed its merge deadline"
  assert_equals 1 "$(wake_count "$dir")" "the green PR deadline did not wake the mate once"
  pass "CI turning green before its timeout waits for the green PR deadline"
}

# Case 9 (primary, 2026-10-20..23): auto-land was disarmed after one merge and
# stayed off for three days, so no green PR in its repos merged. A configured
# but unarmed auto-land wakes the home's supervisor to re-arm it and clears
# once it is armed.
test_disarmed_autoland_wakes_the_supervisor_to_rearm_it() {
  local dir
  dir=$(make_home autoland ship)
  rm "$dir/home/state/w1.meta"
  mkdir -p "$dir/home/config"
  printf '{"repos":[]}\n' > "$dir/home/config/autoland.json"
  scan "$dir" "$T0"
  scan "$dir" $((T0 + 299))
  assert_equals 0 "$(wake_count "$dir")" "a disarmed auto-land woke the supervisor before 5 minutes"
  scan "$dir" $((T0 + 300))
  assert_contains "$(wakes "$dir")" 'auto-land is configured (config/autoland.json) but not armed' "a disarmed auto-land did not wake the supervisor"
  assert_contains "$(wakes "$dir")" 'bin/fm-autoland.sh arm' "the wake does not say how to re-arm it"
  assert_not_contains "$(wakes "$dir")" 'remove its config' "the delivered wake directs configuration deletion"
  : > "$dir/home/state/autoland.check.sh"
  scan "$dir" $((T0 + 400))
  assert_absent "$dir/home/state/keepalive/autoland.json" "an armed auto-land kept its record"
  pass "a configured but disarmed auto-land wakes the supervisor to re-arm it"
}


# Review of #267: a rerun that passed replaces the cancelled run GitHub keeps
# beside it, a PR merely behind its base still counts as green, an unreadable
# PR keeps the CI timer instead of turning into a no-progress stall, and a task
# rebound to another PR starts fresh.
test_pr_watchdog_reads_latest_checks_and_survives_read_failures() {
  local dir
  dir=$(make_home pr-latest ship)
  printf 'pr=https://github.com/o/r/pull/1\n' >> "$dir/home/state/w1.meta"
  status "$dir" "$T0" 'done: PR ready'
  make_pr "$dir" OPEN MERGEABLE BEHIND CANCELLED
  python3 - "$dir/pr.json" <<'PY2'
import json, sys
p = sys.argv[1]; v = json.load(open(p))
v["statusCheckRollup"].append({"__typename": "CheckRun", "status": "COMPLETED", "name": "a", "conclusion": "SUCCESS", "startedAt": "2027-01-15T08:05:00Z", "completedAt": "2027-01-15T08:09:00Z"})
json.dump(v, open(p, "w"))
PY2
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 1800))
  assert_contains "$(wakes "$dir")" 'green and mergeable for 30 minutes' "a passed rerun or a behind PR kept a green PR from being raised"
  dir=$(make_home pr-read-failure ship)
  printf 'pr=https://github.com/o/r/pull/2\n' >> "$dir/home/state/w1.meta"
  printf 'run=01M5\nstep=ci\nverdict=\n' > "$dir/home/state/w1.crew-state"
  status "$dir" "$T0" 'working: validation reached CI'
  make_pr "$dir" OPEN CONFLICTING DIRTY FAILURE
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
  FM_KEEPALIVE_PR=/usr/bin/false scan "$dir" $((T0 + 5400))
  assert_equals 0 "$(wake_count "$dir")" "an unreadable PR turned a CI wait into a no-progress stall"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 7200))
  assert_contains "$(wakes "$dir")" 'sat in its CI step for 120 minutes' "a read failure restarted the CI timer"
  sed -i.bak 's#pull/2#pull/3#' "$dir/home/state/w1.meta"
  make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 7300))
  jq -e '.track.pr == "https://github.com/o/r/pull/3" and (.track.green == '$((T0 + 7300))') and (.cond == null)' \
    "$dir/home/state/keepalive/w1.json" >/dev/null || fail "a rebound PR inherited the old PR's episode or timers"
  pass "the PR watchdog reads the newest check runs, survives read failures and resets on a rebound PR"
}


test_pr_checks_preserve_independent_and_unsettled_failures() {
  local dir scenario expected
  for scenario in later-failure context-red context-green running queued tied tied-reversed unnamed undated completed-fallback all-green-undated; do
    dir=$(make_home "pr-check-$scenario" ship)
    printf 'pr=https://github.com/o/r/pull/1\n' >> "$dir/home/state/w1.meta"
    status "$dir" "$T0" 'done: PR ready'
    make_pr "$dir" OPEN MERGEABLE BLOCKED SUCCESS
    python3 - "$dir/pr.json" "$scenario" <<'PY2'
import json, sys
p, scenario = sys.argv[1:]
v = json.load(open(p))
red = dict(v["statusCheckRollup"][0], conclusion="FAILURE")
green = dict(red, conclusion="SUCCESS", startedAt="2027-01-15T08:05:00Z", completedAt="2027-01-15T08:09:00Z")
if scenario == "later-failure":
    red["startedAt"] = "2027-01-15T08:06:00Z"
elif scenario == "context-red":
    red = {"__typename": "StatusContext", "context": "a", "state": "FAILURE"}
elif scenario == "context-green":
    red.pop("startedAt")
    red.pop("completedAt")
    green = {"__typename": "StatusContext", "context": "a", "state": "SUCCESS"}
elif scenario in ("running", "queued"):
    red.update(status="IN_PROGRESS" if scenario == "running" else "QUEUED", conclusion="", completedAt=None)
elif scenario.startswith("tied"):
    red["startedAt"] = green["startedAt"]
elif scenario == "unnamed":
    red.pop("name")
    green.pop("name")
elif scenario == "undated":
    red.pop("startedAt")
    red.pop("completedAt")
elif scenario == "completed-fallback":
    red.pop("startedAt")
    green.pop("startedAt")
    green["completedAt"] = "2027-01-15T08:11:00Z"
elif scenario == "all-green-undated":
    red["conclusion"] = "SUCCESS"
    for run in (red, green):
        run.pop("startedAt")
        run.pop("completedAt")
v["statusCheckRollup"] = [green, red] if scenario == "tied-reversed" else [red, green]
json.dump(v, open(p, "w"))
PY2
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 1800))
    expected=0
    case "$scenario" in completed-fallback|all-green-undated) expected=1 ;; esac
    assert_equals "$expected" "$(wake_count "$dir")" "incorrect check supersession for $scenario"
  done
  pass "PR check supersession preserves independent, unfinished, tied and unnamed failures"
}


test_unreadable_pr_preserves_open_episodes() {
  local dir cond mature record before notices
  for cond in unmerged ci-stuck; do
    dir=$(make_home "pr-unknown-$cond" ship)
    record="$dir/home/state/keepalive/w1.json"
    printf 'pr=https://github.com/o/r/pull/1\n' >> "$dir/home/state/w1.meta"
    printf 'run=01M5\nstep=ci\n' > "$dir/home/state/w1.crew-state"
    status "$dir" "$T0" 'working: validation reached CI'
    if [ "$cond" = unmerged ]; then
      make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
      mature=$((T0 + 1800))
    else
      make_pr "$dir" OPEN CONFLICTING DIRTY FAILURE
      mature=$((T0 + 7200))
    fi
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$mature"
    jq -e --arg cond "$cond" '.cond == $cond and .woke > 0 and (.escalated | not)' "$record" >/dev/null \
      || fail "setup: no $cond episode"
    before=$(jq -S . "$record")
    FM_KEEPALIVE_PR=/usr/bin/false scan "$dir" $((mature + 1))
    FM_KEEPALIVE_PR=/usr/bin/false scan "$dir" $((mature + 1800))
    assert_equals "$before" "$(jq -S . "$record")" "a failed PR read changed the $cond episode or timers"
    assert_equals 1 "$(wake_count "$dir")" "an unknown PR created another wake"
    assert_equals 0 "$(notice_count "$dir" 'worker w1')" "an unknown PR reported recovery or escalation"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((mature + 1801))
    jq -e --argjson woke "$mature" --argjson since "$T0" '.escalated and .woke == $woke and .since == $since' "$record" >/dev/null \
      || fail "the successful read restarted $cond escalation instead of continuing it"
    before=$(jq -S . "$record")
    notices=$(notice_count "$dir" 'worker w1')
    FM_KEEPALIVE_PR=/usr/bin/false scan "$dir" $((mature + 1900))
    assert_equals "$before" "$(jq -S . "$record")" "a failed PR read changed an escalated $cond episode"
    assert_equals "$notices" "$(notice_count "$dir" 'worker w1')" "a failed PR read resolved an escalated $cond episode"
    make_pr "$dir" MERGED UNKNOWN UNKNOWN SUCCESS
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((mature + 2000))
    assert_equals 1 "$(notice_count "$dir" "worker w1 is no longer $cond")" "a confirmed merge did not resolve $cond"
    jq -e --arg cond "$cond" '.cond != $cond' "$record" >/dev/null || fail "a confirmed merge kept its $cond episode"
  done
  pass "unreadable PRs preserve open PR episodes until a positive observation"
}


test_legacy_pr_tracks_start_with_fresh_ownership() {
  local dir cond record mature now
  for cond in unmerged ci-stuck none; do
    dir=$(make_home "pr-legacy-$cond" ship)
    record="$dir/home/state/keepalive/w1.json"
    printf 'pr=https://github.com/o/r/pull/1\n' >> "$dir/home/state/w1.meta"
    printf 'run=01M5\nstep=ci\n' > "$dir/home/state/w1.crew-state"
    status "$dir" "$T0" 'working: validation reached CI'
    if [ "$cond" = ci-stuck ]; then
      make_pr "$dir" OPEN CONFLICTING DIRTY FAILURE
      mature=$((T0 + 7200))
    else
      make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
      mature=$((T0 + 1800))
    fi
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
    if [ "$cond" != none ]; then
      FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$mature"
      FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((mature + 1800))
      jq -e '.escalated' "$record" >/dev/null || fail "setup: legacy episode did not escalate"
    fi
    jq 'del(.track.pr)' "$record" > "$dir/legacy.json"
    mv "$dir/legacy.json" "$record"
    sed -i.bak 's#pull/1#pull/2#' "$dir/home/state/w1.meta"
    now=$((mature + 1900))
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$now"
    jq -e --argjson now "$now" --arg cond "$cond" '
      .track.pr == "https://github.com/o/r/pull/2" and .track.ci == $now and .cond == null
      and .woke == null and .escalated == null
      and (if $cond == "ci-stuck" then .track.green == null else .track.green == $now end)
    ' "$record" >/dev/null || fail "legacy $cond timers or episode were adopted by another PR"
    if [ "$cond" != none ]; then
      assert_equals 1 "$(notice_count "$dir" 'worker w1 moved to another PR')" "a legacy $cond escalation was not resolved on rebinding"
    fi
  done
  pass "legacy unbound PR timers and episodes reset before adopting the recorded PR"
}


test_held_on_the_mate_wakes_then_escalates_once
test_stall_condition_changes_keep_the_original_deadline
test_legacy_escalations_notify_the_captain_once
test_external_wait_is_left_to_the_declared_wait_cadence
test_spawn_refusal_in_the_first_mates_home_reaches_the_captain
test_captain_notification_retries_a_failed_supervisor_wake
test_pr_guard_refusal_the_mate_only_acknowledges_climbs_to_the_captain
test_state_override_owns_scans_locks_records_and_wakes
test_worker_without_a_live_agent_is_relaunched
test_no_real_progress_counts_code_not_reports
test_done_worker_and_departures
test_finished_result_that_never_left_is_raised
test_accepted_task_without_a_delivered_result_wakes_the_mate
test_repeated_episodes_have_distinct_parent_keys
test_supervisor_declared_wait_defers_stalls_until_expiry
test_watcher_keepalive_guard_stays_cheap_and_obeys_cadence
test_legacy_fold_cache_discovers_keepalive_relays
test_refreshed_keepalive_relays_preserve_the_episode
test_unanswered_mate_question_wakes_the_parent
test_a_question_the_parent_never_answers_reaches_the_captain_once
test_reopened_questions_get_fresh_deadlines
test_open_question_reposts_preserve_the_episode
test_escalation_tracks_all_still_open_questions
test_green_pr_left_unmerged_wakes_the_mate_to_merge_it
test_run_stuck_in_its_ci_step_wakes_the_mate_to_land_or_close
test_mature_pr_conditions_supersede_stale_worker_classifications
test_green_pr_during_aged_ci_waits_for_its_merge_deadline
test_disarmed_autoland_wakes_the_supervisor_to_rearm_it
test_pr_watchdog_reads_latest_checks_and_survives_read_failures
test_pr_checks_preserve_independent_and_unsettled_failures
test_unreadable_pr_preserves_open_episodes
test_legacy_pr_tracks_start_with_fresh_ownership

# An approval-wait record as bin/fm-approval-wait.sh writes it, binding the task
# to one exact open decision key. The home path must match the fixture home so
# declare would accept it; the digest fields are opaque to the keep-alive.
make_approval_wait() {  # <dir> <key>
  cat > "$dir/home/state/w1.approval-wait" <<EOF
{
  "schema": "fm-approval-wait.v1",
  "task": "w1",
  "home": "$dir/home",
  "decision_key": "$2",
  "instruction_file": "$dir/instruction",
  "instruction_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "metadata_sha256": "0000000000000000000000000000000000000000000000000000000000000000",
  "declared": "2026-10-19T21:23:00Z"
}
EOF
  at "$T0" "$1/home/state/w1.approval-wait"
}

# bin/fm_worker_keepalive.py's docstring owns approval-wait exclusions,
# action-episode resets and PR-clock behavior.
test_approval_wait_excludes_action_demands_while_bound() {
  local dir record scenario mature before
  for scenario in unmerged ci-stuck; do
    dir=$(make_home "approval-wait-$scenario" ship)
    make_secondmate "$dir" helper
    record="$dir/home/state/keepalive/w1.json"
    printf 'pr=https://github.com/o/r/pull/9\n' >> "$dir/home/state/w1.meta"
    make_approval_wait "$dir" nm-01M5-pr-publication
    if [ "$scenario" = unmerged ]; then
      status "$dir" "$T0" 'done: PR ready; parent excludes merge until the publication key is released'
      make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
      mature=$((T0 + 1800))
    else
      printf 'run=01M5\nstep=ci\nverdict=\n' > "$dir/home/state/w1.crew-state"
      status "$dir" "$T0" 'working: validation reached CI'
      make_pr "$dir" OPEN CONFLICTING DIRTY FAILURE
      mature=$((T0 + 7200))
    fi
    before=$(cksum "$dir/home/state/w1.status" "$dir/home/state/w1.meta" "$dir/home/state/w1.approval-wait")
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 3599))
    assert_equals 0 "$(wake_count "$dir")" "a fresh approval wait demanded $scenario action"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 3600))
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((mature + 3600))
    assert_equals 1 "$(wake_count "$dir")" "an old approval wait left a $scenario worker silent"
    assert_contains "$(wakes "$dir")" 'approval wait is never an endpoint' "the wait did not raise an approval decision"
    assert_not_contains "$(wakes "$dir")" 'merge it now' "an approval wait allowed a merge demand"
    assert_not_contains "$(wakes "$dir")" 'land it or close it now' "an approval wait allowed a CI demand"
    jq -e --argjson first "$T0" '.cond == "approval" and .since == $first and (.track.green // .track.ci) == $first' "$record" >/dev/null \
      || fail "the approval wait cleared or restarted the $scenario clock"
    assert_equals "$before" "$(cksum "$dir/home/state/w1.status" "$dir/home/state/w1.meta" "$dir/home/state/w1.approval-wait")" \
      "keepalive changed the preserved worker or approval record"
    rm "$dir/home/state/w1.approval-wait"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((mature + 3601))
    assert_equals 2 "$(wake_count "$dir")" "releasing the wait did not restore the $scenario demand"
    jq -e --arg cond "$scenario" --argjson first "$T0" '.cond == $cond and .since == $first' "$record" >/dev/null \
      || fail "the released $scenario condition was not re-raised from its preserved clock"
  done
  pass "an approval wait excludes merge and CI demands while bound and restores them on release"
}

test_approval_wait_is_bounded_and_wakes_the_mate_to_decide() {
  local dir record line verb i=0
  for line in \
    'blocked [key=publication-recovery-01M5]: terminal publication refusal preserved' \
    'blocked: [key=publication-recovery-01M5] awaiting approval' \
    'blocked corr=abc123 [key=publication-recovery-01M5]: awaiting approval' \
    'blocked [stage=publication] [key=publication-recovery-01M5]: awaiting approval' \
    'needs-decision [key=publication-recovery-01M5]: awaiting approval'; do
    i=$((i + 1))
    dir=$(make_home "approval-wait-blocked-$i" ship)
    record="$dir/home/state/keepalive/w1.json"
    make_approval_wait "$dir" publication-recovery-01M5
    at "$T0" "$dir/home/state/w1.approval-wait"
    status "$dir" "$T0" "$line"
    scan "$dir" $((T0 + 1200))
    scan "$dir" $((T0 + 3599))
    assert_equals 0 "$(wake_count "$dir")" "an approval wait woke the mate before its one-hour bound: $line"
    jq -e '.cond == "approval"' "$record" >/dev/null || fail "the approval wait was not tracked as its own episode"
    scan "$dir" $((T0 + 3600))
    assert_equals 1 "$(wake_count "$dir")" "an approval wait an hour old did not wake the mate to decide it: $line"
    assert_contains "$(wakes "$dir")" 'an approval wait is never an endpoint' "the wake lets the mate keep waiting"
    assert_contains "$(wakes "$dir")" 'bin/fm-approval-wait.sh release' "the wake does not say how to release it"
  done
  for verb in needs-decision paused; do
    dir=$(make_home "approval-wait-unrelated-$verb" ship)
    make_approval_wait "$dir" publication
    status "$dir" "$T0" "$verb [key=other]: awaiting your release"
    scan "$dir" "$T0"
    scan "$dir" $((T0 + 1200))
    assert_equals 1 "$(wake_count "$dir")" "an unrelated $verb key was excluded by the approval wait"
    scan "$dir" $((T0 + 3000))
    assert_equals 1 "$(notice_count "$dir" 'worker w1 has been stuck')" "an unrelated $verb lost real stuck escalation"
  done
  pass "an approval wait keeps automatic actions away but wakes the mate to decide it after an hour"
}

# A green PR whose forge state carries a hold label (fm-pr-lib's hold-label
# disposition, one owner with fm-autoland.sh) is an explicit ready-only
# instruction: auto-land already refuses to merge it, so the keep-alive must not
# demand the merge behind that disposition. An unlabeled green PR still wakes.
test_hold_labelled_green_pr_is_ready_only_not_an_unmerged_demand() {
  local dir scenario mature
  for scenario in unmerged ci-stuck; do
    dir=$(make_home "hold-label-$scenario" ship)
    printf 'pr=https://github.com/o/r/pull/9\n' >> "$dir/home/state/w1.meta"
    if [ "$scenario" = unmerged ]; then
      status "$dir" "$T0" 'done: PR ready for review only'
      make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
      mature=$((T0 + 1800))
    else
      printf 'run=01M5\nstep=ci\n' > "$dir/home/state/w1.crew-state"
      status "$dir" "$T0" 'working: validation reached CI'
      make_pr "$dir" OPEN CONFLICTING DIRTY FAILURE
      mature=$((T0 + 7200))
    fi
    jq '.labels = [{name: "do-not-merge"}]' "$dir/pr.json" > "$dir/pr-held.json"
    mv "$dir/pr-held.json" "$dir/pr.json"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$mature"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((mature + 3600))
    assert_equals 0 "$(wake_count "$dir")" "a hold-labelled PR demanded $scenario action"
    jq -e --argjson first "$T0" '.cond == null and (.track.green // .track.ci) == $first' \
      "$dir/home/state/keepalive/w1.json" >/dev/null || fail "the hold label changed the $scenario clock"
    jq '.labels = []' "$dir/pr.json" > "$dir/pr-released.json"
    mv "$dir/pr-released.json" "$dir/pr.json"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((mature + 3601))
    assert_equals 1 "$(wake_count "$dir")" "removing the hold label did not restore the $scenario demand"
    jq -e --arg cond "$scenario" '.cond == $cond' "$dir/home/state/keepalive/w1.json" >/dev/null \
      || fail "the released PR did not restore $scenario"
  done
  pass "hold-labelled PRs exclude merge and CI demands until the label is gone"
}

test_exact_approval_wait_survives_endpoint_loss() {
  local dir scenario
  for scenario in no-pr green-pr; do
    dir=$(make_home "dead-approval-$scenario" ship)
    make_approval_wait "$dir" publication
    status "$dir" "$T0" 'blocked: [key=publication] awaiting approval'
    if [ "$scenario" = green-pr ]; then
      printf 'pr=https://github.com/o/r/pull/9\n' >> "$dir/home/state/w1.meta"
      make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
    fi
    at "$T0" "$dir/home/state/w1.approval-wait"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
    echo dead > "$dir/liveness"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 1200))
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 3500))
    assert_equals 0 "$(wake_count "$dir")" "endpoint loss released an exact approval wait"
    assert_equals 0 "$(notice_count "$dir" 'worker w1')" "endpoint loss escalated an exact approval wait"
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 5000))
    assert_equals 1 "$(wake_count "$dir")" "an hour-old approval wait did not wake the mate to decide it"
    assert_contains "$(wakes "$dir")" 'approval wait is never an endpoint' "the wake for a dead worker's wait was not the approval decision"
    assert_not_contains "$(wakes "$dir")" 'merge it now' "an approval wait let a merge demand through"
    status "$dir" $((T0 + 5001)) 'blocked [key=other]: unrelated failure'
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 5001))
    FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 5301))
    assert_equals 1 "$(wake_count "$dir")" "an old approval wait restarted recovery after a status change"
    assert_not_contains "$(wakes "$dir")" 'no live agent' "an old approval wait allowed a recovery demand"
  done
  pass "approval waits bound endpoint loss and unrelated status changes without demanding recovery"
}

test_unreadable_approval_wait_keeps_pr_actions_excluded() {
  local dir scenario kind record mature
  for scenario in unmerged ci-stuck; do
    for kind in corrupt unreadable broken-symlink directory; do
      dir=$(make_home "approval-$scenario-$kind" ship)
      make_secondmate "$dir" helper
      record="$dir/home/state/w1.approval-wait"
      case "$kind" in
        corrupt) printf 'not json\n' > "$record" ;;
        unreadable) make_approval_wait "$dir" publication; chmod 000 "$record" ;;
        broken-symlink) ln -s "$dir/missing" "$record" ;;
        directory) mkdir "$record" ;;
      esac
      at "$T0" "$record"
      printf 'pr=https://github.com/o/r/pull/9\n' >> "$dir/home/state/w1.meta"
      if [ "$scenario" = unmerged ]; then
        status "$dir" "$T0" 'done: PR ready'
        make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
        mature=$((T0 + 1800))
      else
        printf 'run=01M5\nstep=ci\nverdict=\n' > "$dir/home/state/w1.crew-state"
        status "$dir" "$T0" 'working: validation reached CI'
        make_pr "$dir" OPEN CONFLICTING DIRTY FAILURE
        mature=$((T0 + 7200))
      fi
      FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
      FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$mature"
      FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((mature + 3600))
      assert_equals 1 "$(wake_count "$dir")" "an old $kind approval record did not wake its mate"
      assert_contains "$(wakes "$dir")" 'approval wait is never an endpoint' "a $kind record did not raise an approval decision"
      assert_not_contains "$(wakes "$dir")" 'merge it now' "a $kind approval record allowed a merge demand"
      assert_not_contains "$(wakes "$dir")" 'land it or close it now' "a $kind approval record allowed a CI demand"
      jq -e --argjson first "$T0" '.cond == "approval" and (.track.green // .track.ci) == $first' \
        "$dir/home/state/keepalive/w1.json" >/dev/null || fail "the excluded PR clock changed"
      if [ "$kind" = directory ]; then rmdir "$record"; else rm "$record"; fi
      FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((mature + 3601))
      assert_equals 2 "$(wake_count "$dir")" "reconciling a $kind record did not restore the $scenario demand"
    done
  done
  pass "undecodable approval records exclude PR actions until reconciled"
}

test_approval_wait_retires_escalation_and_restarts_recovery() {
  local dir verb initial_verb channel record before
  for verb in blocked needs-decision paused; do
    dir=$(make_home "approval-after-escalation-$verb" ship)
    make_secondmate "$dir" helper
    channel="$dir/parent/state/helper.status"
    record="$dir/home/state/keepalive/w1.json"
    initial_verb=$verb
    [ "$verb" != paused ] || initial_verb=blocked
    status "$dir" "$T0" "$initial_verb [key=publication]: awaiting approval"
    scan "$dir" "$T0"
    scan "$dir" $((T0 + 1200))
    scan "$dir" $((T0 + 1800))
    assert_equals 1 "$(wake_count "$dir")" "setup: $verb did not wake its mate"
    assert_grep "blocked [key=keepalive-helper-w1-$T0]" "$channel" "setup: $verb did not escalate"
    printf 'Preserve this worker until publication is approved.\n' > "$dir/instruction"
    FM_HOME="$dir/home" "$ROOT/bin/fm-approval-wait.sh" declare w1 --key publication \
      --expected-record "$(cat "$dir/home/state/w1.meta")" --instruction-file "$dir/instruction" \
      || fail "could not declare a wait for $verb"
    at $((T0 + 1801)) "$dir/home/state/w1.approval-wait"
    if [ "$verb" = paused ]; then
      status "$dir" $((T0 + 1801)) 'paused [key=publication]: awaiting your release'
    fi
    before=$(cksum "$dir/home/state/w1.status" "$dir/home/state/w1.meta" "$dir/home/state/w1.approval-wait")
    scan "$dir" $((T0 + 1801))
    assert_grep "resolved [key=keepalive-helper-w1-$T0]" "$channel" "entering the wait left the old escalation open"
    jq -e '.cond == "approval" and .woke == 0 and (.escalated | not)' "$record" >/dev/null \
      || fail "entering the wait did not start its own approval episode"
    scan "$dir" $((T0 + 5400))
    assert_equals 1 "$(wake_count "$dir")" "the approval wait woke the mate before its one-hour bound"
    scan "$dir" $((T0 + 5401))
    assert_equals 2 "$(wake_count "$dir")" "declaring an approval wait silenced the watchdog for good"
    assert_contains "$(wakes "$dir")" 'approval wait is never an endpoint' "the approval wake lets the mate keep waiting"
    assert_equals "$before" "$(cksum "$dir/home/state/w1.status" "$dir/home/state/w1.meta" "$dir/home/state/w1.approval-wait")" \
      "keepalive changed preserved worker or approval state"
  done
  pass "declaring an approval wait closes the old episode and opens a bounded approval episode"
}

test_replaced_approval_wait_starts_its_own_episode() {
  local dir phase record channel old_id old_key declared now digest wakes_before new_key
  for phase in pending woke escalated same-time-key; do
    dir=$(make_home "approval-replaced-$phase" ship)
    make_secondmate "$dir" helper
    record="$dir/home/state/keepalive/w1.json"
    channel="$dir/parent/state/helper.status"
    status "$dir" "$T0" 'blocked [key=publication]: awaiting approval'
    printf 'Preserve this worker until publication is approved.\n' > "$dir/instruction"
    FM_HOME="$dir/home" "$ROOT/bin/fm-approval-wait.sh" declare w1 --key publication \
      --expected-record "$(cat "$dir/home/state/w1.meta")" --instruction-file "$dir/instruction" \
      || fail "could not declare the original wait"
    at "$T0" "$dir/home/state/w1.approval-wait"
    scan "$dir" "$T0"
    now=$((T0 + 1200))
    if [ "$phase" != pending ]; then
      scan "$dir" $((T0 + 3600))
      now=$((T0 + 3601))
    fi
    if [ "$phase" = escalated ] || [ "$phase" = same-time-key ]; then
      scan "$dir" $((T0 + 4200))
      now=$((T0 + 4201))
      jq -e '.escalated' "$record" >/dev/null || fail "setup: the original approval episode did not escalate"
    fi
    old_id=$(jq -r '.approval_id' "$record")
    old_key="keepalive-helper-w1-$T0-$old_id"
    wakes_before=$(wake_count "$dir")
    digest=$(jq -r '.instruction_sha256' "$dir/home/state/w1.approval-wait")
    printf 'Release the original wait and reconsider the publication decision.\n' > "$dir/release"
    FM_HOME="$dir/home" "$ROOT/bin/fm-approval-wait.sh" release w1 \
      --instruction-sha256 "$digest" --release-file "$dir/release" || fail "could not release the original wait"
    new_key=publication
    declared=$now
    if [ "$phase" = same-time-key ]; then
      new_key=publication-revised
      declared=$T0
      status "$dir" "$now" "blocked [key=$new_key]: awaiting revised approval"
    fi
    FM_HOME="$dir/home" "$ROOT/bin/fm-approval-wait.sh" declare w1 --key "$new_key" \
      --expected-record "$(cat "$dir/home/state/w1.meta")" --instruction-file "$dir/instruction" \
      || fail "could not declare the replacement wait"
    at "$declared" "$dir/home/state/w1.approval-wait"
    scan "$dir" "$now"
    jq -e --arg old "$old_id" --argjson declared "$declared" \
      '.cond == "approval" and .approval_id != $old and .since == $declared and (.escalated | not)' "$record" >/dev/null \
      || fail "a replacement wait inherited its $phase episode"
    if [ "$phase" = escalated ] || [ "$phase" = same-time-key ]; then
      assert_grep "resolved [key=$old_key]" "$channel" "the replaced wait left its old escalation open"
    fi
    if [ "$phase" != same-time-key ]; then
      jq -e '.woke == 0 and .nudges == 0' "$record" >/dev/null || fail "a fresh replacement inherited a wake"
      scan "$dir" $((declared + 3599))
      assert_equals "$wakes_before" "$(wake_count "$dir")" "the replacement reused the original deadline"
      scan "$dir" $((declared + 3600))
    fi
    assert_equals "$((wakes_before + 1))" "$(wake_count "$dir")" "the replacement wait did not receive its own bounded wake"
    if [ "$phase" = same-time-key ]; then
      assert_equals 2 "$(cut -f4 "$dir/home/state/.wake-queue" | sort -u | wc -l | tr -d ' ')" \
        "same-time replacement wakes reused the old queue identity"
    fi
    scan "$dir" $(( $(jq -r '.woke' "$record") + 600 ))
    new_key="keepalive-helper-w1-$declared-$(jq -r '.approval_id' "$record")"
    assert_grep "blocked [key=$new_key]" "$channel" "the replacement wait did not escalate independently"
    jq -e '.escalated' "$record" >/dev/null || fail "the replacement episode did not escalate"
  done
  pass "release and redeclaration between scans resets approval deadlines, wakes and escalations"
}

test_shared_hold_label_inputs() {
  local input expected actual
  while IFS=$'\t' read -r input expected; do
    actual=$(bash -c '. "$1/bin/fm-pr-lib.sh"; fm_pr_hold_label "$2"' _ "$ROOT" "$input")
    assert_equals "${expected:-}" "$actual" "unexpected hold-label disposition for $input"
  done <<'EOF'
bug,on-hold	on-hold
on hold	on hold
onhold
"hold"
{"labels":{"nodes":[{"name":"hold"}]}}
{"labels":[{"name":"bug"},{"name":"hold"}]}	hold
{"labels":[]}
EOF
  pass "shared hold labels accept CSV and gh-view arrays without extra aliases or input modes"
}

# Case 10 (dave-tools, 2026-10-24..26): workers ended "done: ... ready-only DNM
# freeze preserved; no edits" with their PR open, green and labelled
# do-not-merge, and sat 17-22 h. A hold label alone made the done: worker look
# healthy. A done: line in a freeze with its PR still open is not a finish: the
# mate is woken to land or close it, and its parent hears of it; a freeze
# without any PR stays undelivered; merging the PR clears it.
test_done_in_a_freeze_with_an_open_pr_is_not_healthy() {
  local dir channel
  dir=$(make_home done-frozen ship)
  make_secondmate "$dir" dave-tools
  channel="$dir/parent/state/dave-tools.status"
  printf 'pr=https://github.com/o/r/pull/51\n' >> "$dir/home/state/w1.meta"
  status "$dir" "$T0" 'done: Read-only reattachment confirms PR 51 remains open/non-draft/DNM with 10 passed. Ready-only freeze retained; no edits, responses or recovery.'
  make_pr "$dir" OPEN MERGEABLE CLEAN SUCCESS
  jq '.labels = [{name: "do-not-merge"}]' "$dir/pr.json" > "$dir/pr-held.json"
  mv "$dir/pr-held.json" "$dir/pr.json"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" "$T0"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 599))
  assert_equals 0 "$(wake_count "$dir")" "a frozen done: worker woke its mate early"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 600))
  assert_equals 1 "$(wake_count "$dir")" "a done: worker frozen on an open PR looked healthy"
  assert_contains "$(wakes "$dir")" 'never an endpoint' "the wake lets the freeze stand"
  assert_contains "$(wakes "$dir")" 'https://github.com/o/r/pull/51' "the wake does not name the open PR"
  jq -e '.cond == "frozen"' "$dir/home/state/keepalive/w1.json" >/dev/null || fail "the freeze was not recorded as frozen"
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 1200))
  assert_grep "blocked [key=keepalive-dave-tools-w1-$T0]: worker w1 has been stuck (frozen)" "$channel" "the freeze did not reach the parent"
  assert_grep 'landing or closing its open PR' "$channel" "the escalation does not say what would unstick it"
  make_pr "$dir" MERGED UNKNOWN UNKNOWN SUCCESS
  FM_KEEPALIVE_PR="$dir/bin/pr" scan "$dir" $((T0 + 1300))
  assert_grep "resolved [key=keepalive-dave-tools-w1-$T0]: worker w1 is moving again" "$channel" "merging the PR did not clear the freeze"
  jq -e '.cond == null' "$dir/home/state/keepalive/w1.json" >/dev/null || fail "a merged PR left the frozen episode open"

  dir=$(make_home done-frozen-no-pr ship)
  status "$dir" "$T0" 'done: preserved accepted read-only freeze, no edits, gate responses, monitor resume'
  scan "$dir" "$T0"
  scan "$dir" $((T0 + 600))
  assert_equals 1 "$(wake_count "$dir")" "a frozen done: worker without a PR looked healthy"
  jq -e '.cond == "undelivered"' "$dir/home/state/keepalive/w1.json" >/dev/null || fail "a freeze without a PR was not undelivered"
  pass "a done: worker frozen on an open or missing PR wakes its mate to land or close it"
}

# A second mate whose parent channel cannot take the escalation (here the parent
# binding is gone) must not retry it silently forever: the line falls through to
# a captain notice from this home, once.
test_undeliverable_parent_escalation_falls_through_to_the_captain() {
  local dir
  dir=$(make_home undeliverable ship)
  make_secondmate "$dir" dave-tools
  rm "$dir/home/.fm-secondmate-parent"
  status "$dir" "$T0" 'blocked: the PR guard refused the push'
  scan "$dir" $((T0 + 1200))
  assert_equals 1 "$(wake_count "$dir")" "the blocked worker did not wake its mate"
  scan "$dir" $((T0 + 1800))
  assert_equals 1 "$(notice_count "$dir" 'worker w1 has been stuck (blocked)')" "an undeliverable parent escalation was dropped"
  assert_equals 1 "$(notice_count "$dir" 'parent channel could not take it')" "the captain line does not say the channel is broken"
  jq -e '.escalated == true' "$dir/home/state/keepalive/w1.json" >/dev/null || fail "the fall-through was not recorded"
  scan "$dir" $((T0 + 2400))
  assert_equals 1 "$(notice_count "$dir" .)" "the fall-through repeated"
  pass "an escalation the parent channel cannot take falls through to the captain once"
}

# Case 10 (dave-tools, 2026-10-24): the keep-alive escalations for two frozen
# workers reached the first mate and were closed by an "answered: ... false
# positives" line and the mate's own "False unmerged alarm" line while the
# workers stayed stuck. Closing a relay that never went up is not a fix: the
# captain is told at once, and the record resolves when the owning watchdog does.
test_relay_closed_without_a_fix_goes_up_at_once() {
  local dir key record
  dir=$(make_parent dropped-relay dave-tools)
  key="keepalive-dave-tools-w1-$T0"
  record="$dir/home/state/keepalive/asks/dave-tools.json"
  ask "$dir" dave-tools "blocked [key=$key]: worker w1 has been stuck (unmerged) since 2027-01-15 08:00:00 UTC"
  scan "$dir" "$T0"
  ask "$dir" dave-tools "resolved [key=$key]: answered: false positive, PR 51 must remain unmerged"
  scan "$dir" $((T0 + 60))
  assert_equals 1 "$(notice_count "$dir" 'was closed without the stuck work moving')" "a dismissed relay was dropped"
  assert_equals 1 "$(notice_count "$dir" 'false positive, PR 51 must remain unmerged')" "the captain line omits the closing line"
  scan "$dir" $((T0 + 120))
  scan "$dir" $((T0 + 3600))
  assert_equals 1 "$(notice_count "$dir" .)" "a dismissed relay notified repeatedly"
  ask "$dir" dave-tools "resolved [key=$key]: worker w1 is no longer unmerged"
  scan "$dir" $((T0 + 3700))
  assert_equals 1 "$(notice_count "$dir" 'stuck work is moving again')" "the watchdog's resolution did not close the dropped relay"
  jq -e '.relays == {}' "$record" >/dev/null || fail "a resolved dropped relay stayed open"

  dir=$(make_parent genuine-relay dave-tools)
  ask "$dir" dave-tools "blocked [key=$key]: worker w1 has been stuck (blocked)"
  scan "$dir" "$T0"
  ask "$dir" dave-tools "resolved [key=$key]: worker w1 is moving again"
  scan "$dir" $((T0 + 60))
  scan "$dir" $((T0 + 3600))
  assert_equals 0 "$(notice_count "$dir" .)" "a relay the watchdog resolved reached the captain"
  pass "a relay closed without a fix reaches the captain at once and resolves with the watchdog"
}

test_missing_closing_evidence_retains_only_dropped_relays() {
  local dir key record channel mode phase before
  key="keepalive-dave-tools-w1-$T0"
  for mode in truncate replace missing; do
    for phase in dropped raised; do
      dir=$(make_parent "missing-closure-$mode-$phase" dave-tools)
      record="$dir/home/state/keepalive/asks/dave-tools.json"
      channel="$dir/home/state/dave-tools.status"
      ask "$dir" dave-tools "blocked [key=$key]: worker w1 is frozen"
      scan "$dir" "$T0"
      if [ "$phase" = dropped ]; then
        ask "$dir" dave-tools "resolved [key=$key]: answered: false positive"
        scan "$dir" $((T0 + 60))
        jq -e '.relays | length == 1 and all(.[]; .up and .dropped)' "$record" >/dev/null \
          || fail "setup: the dismissed relay did not escalate"
      else
        scan "$dir" $((T0 + 1800))
        jq -e '.relays | length == 1 and all(.[]; .up and (.dropped | not))' "$record" >/dev/null \
          || fail "setup: the open relay did not escalate normally"
      fi
      before=$(jq -cS '.relays' "$record")
      case "$mode" in
        truncate) : > "$channel" ;;
        replace)
          mv "$channel" "$dir/old-channel"
          ask "$dir" dave-tools 'working: supervising workers' ;;
        missing) rm "$channel" ;;
      esac
      scan "$dir" $((T0 + 1900))
      scan "$dir" $((T0 + 2000))
      if [ "$phase" = raised ]; then
        assert_equals 1 "$(notice_count "$dir" 'stuck work is moving again')" "missing evidence changed an ordinary raised relay's recovery"
        jq -e '.relays == {}' "$record" >/dev/null || fail "an ordinary raised relay stayed open"
        continue
      fi
      assert_equals "$before" "$(jq -cS '.relays' "$record")" "a $mode channel changed the dropped record without recovery evidence"
      assert_equals 1 "$(notice_count "$dir" .)" "a $mode channel emitted a false recovery or repeated escalation"
      case "$mode" in
        truncate) ask "$dir" dave-tools "resolved [key=$key]: worker w1 is moving again" ;;
        replace) ask "$dir" dave-tools "blocked [key=$key]: worker w1 is still frozen" ;;
        missing) rm "$dir/home/state/dave-tools.meta" ;;
      esac
      scan "$dir" $((T0 + 2100))
      scan "$dir" $((T0 + 2200))
      assert_equals 1 "$(notice_count "$dir" 'stuck work is moving again')" "a retained dropped relay did not resolve exactly once on $mode recovery"
      if [ "$mode" = missing ]; then
        assert_absent "$record" "a departed mate retained its dropped relay"
      elif [ "$mode" = replace ]; then
        jq -e '.relays | length == 1 and all(.[]; (.up | not) and (.dropped | not))' "$record" >/dev/null \
          || fail "a reopened key retained its dropped episode"
      else
        jq -e '.relays == {}' "$record" >/dev/null || fail "a watchdog-resolved dropped relay stayed open"
      fi
    done
  done
  pass "missing closing evidence retains dropped relays without changing ordinary raised recovery"
}

test_relays_opened_and_closed_between_scans_are_not_lost() {
  local dir key record form
  for form in verb note-head; do
    dir=$(make_parent "between-scans-$form" dave-tools)
    key="keepalive-dave-tools-w1-$T0"
    record="$dir/home/state/keepalive/asks/dave-tools.json"
    ask "$dir" dave-tools 'working: supervising workers'
    scan "$dir" "$T0"
    ask "$dir" dave-tools "blocked [key=$key]: worker w1 is frozen on its open PR"
    if [ "$form" = note-head ]; then
      ask "$dir" dave-tools "resolved: [key=$key] False unmerged alarm"
    else
      ask "$dir" dave-tools "resolved [key=$key]: answered: false positive"
    fi
    scan "$dir" $((T0 + 300))
    assert_equals 1 "$(notice_count "$dir" 'was closed without the stuck work moving')" "a between-scan $form relay was lost"
    jq -e '.relays | length == 1 and all(.[]; .up and .dropped)' "$record" >/dev/null \
      || fail "the missed relay was not retained as dropped"
    scan "$dir" $((T0 + 600))
    assert_equals 1 "$(notice_count "$dir" .)" "the missed relay was reported twice"
    ask "$dir" dave-tools "resolved: [key=$key] worker w1 is moving again"
    scan "$dir" $((T0 + 900))
    assert_equals 1 "$(notice_count "$dir" 'stuck work is moving again')" "the missed relay did not resolve"
    jq -e '.relays == {}' "$record" >/dev/null || fail "the missed relay remained after recovery"
  done
  pass "relays closed between scans in either key position reach the captain exactly once"
}

test_relay_opened_during_the_fold_is_read_next_scan() {
  local dir key record channel before
  dir=$(make_parent during-fold dave-tools)
  key="keepalive-dave-tools-w1-$T0"
  record="$dir/home/state/keepalive/asks/dave-tools.json"
  channel="$dir/home/state/dave-tools.status"
  ask "$dir" dave-tools 'working: supervising workers'
  scan "$dir" "$T0"
  ask "$dir" dave-tools 'working: checking workers again'
  before=$(wc -c < "$channel" | tr -d ' ')
  FM_HOME="$dir/home" FM_KEEPALIVE_NOW="$((T0 + 60))" FM_KEEPALIVE_NOTIFY="$dir/bin/notify" \
    python3 -B - "$ROOT/bin/fm_worker_keepalive.py" "$key" <<'PY' || fail "the interleaved scan failed"
import runpy
import sys

module = runpy.run_path(sys.argv[1])
Scan = module["Scan"]
questions = Scan.questions

def append_after_fold(self, mate):
    result = questions(self, mate)
    with (self.state / (mate + ".status")).open("a") as channel:
        channel.write("blocked [key=%s]: worker w1 is frozen\n" % sys.argv[2])
    return result

Scan.questions = append_after_fold
module["main"](["scan"])
PY
  jq -e --argjson before "$before" '.tail_offset == $before and .relays == {}' "$record" >/dev/null \
    || fail "the scan consumed an opening absent from its fold"
  ask "$dir" dave-tools "resolved [key=$key]: answered: false positive"
  scan "$dir" $((T0 + 300))
  assert_equals 1 "$(notice_count "$dir" 'was closed without the stuck work moving')" "an opening during the fold was lost"
  scan "$dir" $((T0 + 600))
  assert_equals 1 "$(notice_count "$dir" .)" "the interleaved relay was escalated twice"
  pass "an opening appended after the fold is retained for the next scan"
}

test_relay_answer_straddling_the_snapshot_is_not_lost() {
  local dir key record ending expected
  key="keepalive-dave-tools-w1-$T0"
  for ending in verb note-head watchdog captain-held; do
    dir=$(make_parent "straddling-snapshot-$ending" dave-tools)
    record="$dir/home/state/keepalive/asks/dave-tools.json"
    ask "$dir" dave-tools 'working: supervising workers'
    scan "$dir" "$T0"
    ask "$dir" dave-tools "blocked [key=$key]: worker w1 is frozen"
    FM_HOME="$dir/home" FM_KEEPALIVE_NOW="$((T0 + 60))" FM_KEEPALIVE_NOTIFY="$dir/bin/notify" \
      python3 -B - "$ROOT/bin/fm_worker_keepalive.py" "$key" "$ending" <<'PY' || fail "the snapshot-straddling scan failed"
import runpy
import sys

module = runpy.run_path(sys.argv[1])
Scan = module["Scan"]
questions = Scan.questions
key, ending = sys.argv[2:]
closure = {
    "verb": "resolved [key=%s]: answered: false positive",
    "note-head": "resolved: [key=%s] False unmerged alarm",
    "watchdog": "resolved: [key=%s] worker w1 is moving again",
    "captain-held": "captain-held [key=%s]: tracked by captain task 42",
}[ending] % key

def answer_before_fold(self, mate):
    with (self.state / (mate + ".status")).open("a") as channel:
        channel.write(closure + "\n")
    return questions(self, mate)

Scan.questions = answer_before_fold
module["main"](["scan"])
PY
    expected=0
    if [ "$ending" = verb ] || [ "$ending" = note-head ]; then
      expected=1
    fi
    assert_equals "$expected" "$(notice_count "$dir" 'was closed without the stuck work moving')" "a $ending closure across the snapshot was mishandled"
    jq -e --argjson expected "$expected" '.tail_pending == {} and (.relays | length) == $expected' "$record" >/dev/null \
      || fail "the snapshot-straddling relay was not transferred or cleared"
    scan "$dir" $((T0 + 300))
    scan "$dir" $((T0 + 600))
    assert_equals "$expected" "$(notice_count "$dir" .)" "the snapshot-straddling closure repeated or emitted a false recovery"
  done
  pass "answers straddling the snapshot escalate once, while watchdog and captain-held closures stay quiet"
}

test_pending_relay_openings_survive_until_owned_or_closed() {
  local dir key ending record expected
  key="keepalive-dave-tools-w1-$T0"
  for ending in answered watchdog captain-held reopened gone; do
    dir=$(make_parent "pending-relay-$ending" dave-tools)
    record="$dir/home/state/keepalive/asks/dave-tools.json"
    ask "$dir" dave-tools 'working: supervising workers'
    scan "$dir" "$T0"
    ask "$dir" dave-tools "blocked [key=$key]: worker w1 is frozen"
    FM_HOME="$dir/home" FM_KEEPALIVE_NOW="$((T0 + 60))" FM_KEEPALIVE_NOTIFY="$dir/bin/notify" \
      python3 -B - "$ROOT/bin/fm_worker_keepalive.py" <<'PY' || fail "the pending-opening scan failed"
import runpy
import sys

module = runpy.run_path(sys.argv[1])
module["Scan"].questions = lambda self, mate: {}
module["main"](["scan"])
PY
    jq -e --arg key "$key" --argjson first "$((T0 + 60))" '.tail_pending == {($key): $first} and .relays == {}' "$record" >/dev/null \
      || fail "an opening absent from the fold was not persisted"
    assert_equals 0 "$(notice_count "$dir" .)" "an unclosed pending opening was escalated"
    scan "$dir" $((T0 + 90))
    jq -e --arg key "$key" --argjson first "$((T0 + 60))" '.tail_pending == {($key): $first}' "$record" >/dev/null \
      || fail "an opening without a closure was forgotten on the next scan"
    expected=0
    case "$ending" in
      answered)
        ask "$dir" dave-tools "resolved: [key=$key] answered: false positive"
        expected=1 ;;
      watchdog) ask "$dir" dave-tools "resolved [key=$key]: worker w1 is moving again" ;;
      captain-held) ask "$dir" dave-tools "captain-held [key=$key]: tracked by captain task 42" ;;
      reopened) ask "$dir" dave-tools "blocked [key=$key]: worker w1 is still frozen" ;;
      gone) rm "$dir/home/state/dave-tools.meta" ;;
    esac
    scan "$dir" $((T0 + 120))
    assert_equals "$expected" "$(notice_count "$dir" .)" "pending $ending was mishandled"
    if [ "$ending" = gone ]; then
      assert_absent "$record" "a departed mate kept its pending opening"
    else
      jq -e '.tail_pending == {}' "$record" >/dev/null || fail "an owned or closed opening remained pending"
      if [ "$ending" = answered ]; then
        jq -e --argjson first "$((T0 + 60))" '.relays | length == 1 and all(.[]; .up and .dropped and .first == $first)' "$record" >/dev/null \
          || fail "the pending dismissal lost its first-seen time or dropped escalation"
      elif [ "$ending" = reopened ]; then
        jq -e '.relays | length == 1 and all(.[]; .up == false)' "$record" >/dev/null \
          || fail "the normal relay path did not take ownership"
      fi
    fi
    scan "$dir" $((T0 + 180))
    assert_equals "$expected" "$(notice_count "$dir" .)" "pending $ending was reported twice"
  done
  pass "pending openings persist across scans and clear on normal ownership, authorized closure, or departure"
}

test_relay_tail_baselines_and_channel_replacement() {
  local dir key record mode
  for mode in first legacy truncate replace; do
    dir=$(make_parent "tail-$mode" dave-tools)
    key="keepalive-dave-tools-w1-$T0"
    record="$dir/home/state/keepalive/asks/dave-tools.json"
    ask "$dir" dave-tools "blocked [key=$key]: worker w1 is frozen"
    ask "$dir" dave-tools "resolved [key=$key]: answered: false positive"
    if [ "$mode" = legacy ]; then
      mkdir -p "$(dirname "$record")"
      printf '{"asks":{},"relays":{}}\n' > "$record"
    fi
    scan "$dir" "$T0"
    assert_equals 0 "$(notice_count "$dir" .)" "the first tail scan backfilled historical closures"
    ask "$dir" dave-tools "blocked [key=$key-new]: worker w2 is frozen"
    ask "$dir" dave-tools "resolved [key=$key-new]: answered: false positive"
    scan "$dir" $((T0 + 300))
    assert_equals 1 "$(notice_count "$dir" .)" "an appended closed relay did not escalate"
    ask "$dir" dave-tools "resolved [key=$key-new]: worker w2 is moving again"
    scan "$dir" $((T0 + 600))
    if [ "$mode" = truncate ] || [ "$mode" = replace ]; then
      if [ "$mode" = replace ]; then
        mv "$dir/home/state/dave-tools.status" "$dir/old-channel"
      fi
      printf 'blocked [key=%s-new]: worker w2 is frozen\nresolved [key=%s-new]: answered\n' \
        "$key" "$key" > "$dir/home/state/dave-tools.status"
      ask "$dir" dave-tools "blocked [key=$key-unseen]: worker w3 is frozen"
      ask "$dir" dave-tools "resolved [key=$key-unseen]: answered: false positive"
      scan "$dir" $((T0 + 900))
      assert_equals 2 "$(notice_count "$dir" 'was closed without the stuck work moving')" "a reset channel lost a new key or replayed a seen key"
      scan "$dir" $((T0 + 1200))
      assert_equals 3 "$(notice_count "$dir" .)" "a reset channel repeated a closed relay"
    fi
  done
  pass "tail baselines skip history and reset channels discover only unseen closed keys"
}

test_captain_held_relays_clear_quietly() {
  local dir key record phase expected
  key="keepalive-dave-tools-w1-$T0"
  for phase in observed dropped between-scans; do
    dir=$(make_parent "captain-held-$phase" dave-tools)
    record="$dir/home/state/keepalive/asks/dave-tools.json"
    ask "$dir" dave-tools 'working: supervising workers'
    scan "$dir" "$T0"
    ask "$dir" dave-tools "blocked [key=$key]: worker w1 is frozen"
    if [ "$phase" != between-scans ]; then
      scan "$dir" $((T0 + 60))
    fi
    expected=0
    if [ "$phase" = dropped ]; then
      ask "$dir" dave-tools "resolved [key=$key]: answered: false positive"
      scan "$dir" $((T0 + 120))
      assert_equals 1 "$(notice_count "$dir" .)" "setup: the dropped relay did not escalate"
      expected=1
    fi
    ask "$dir" dave-tools "captain-held [key=$key]: tracked by captain task 42"
    scan "$dir" $((T0 + 180))
    scan "$dir" $((T0 + 3600))
    assert_equals "$expected" "$(notice_count "$dir" .)" "a captain-held closure emitted an escalation or false recovery"
    jq -e '.relays == {}' "$record" >/dev/null || fail "a captain-held relay was not cleared"
  done
  pass "captain-held closures clear unraised and dropped relays without notices"
}

test_repaired_parent_channel_preserves_captain_resolution_route() {
  local dir key record
  dir=$(make_home repaired-worker ship)
  make_secondmate "$dir" dave-tools
  rm "$dir/home/.fm-secondmate-parent"
  status "$dir" "$T0" 'blocked: the PR guard refused the push'
  scan "$dir" $((T0 + 1200))
  scan "$dir" $((T0 + 1800))
  jq -e '.route == "captain" and .escalated' "$dir/home/state/keepalive/w1.json" >/dev/null \
    || fail "the worker fallback route was not retained"
  make_secondmate "$dir" dave-tools
  status "$dir" $((T0 + 1900)) 'done: result delivered'
  scan "$dir" $((T0 + 1900))
  assert_equals 1 "$(notice_count "$dir" 'worker w1 is no longer blocked')" "a repaired channel stole the worker recovery notice"
  assert_absent "$dir/parent/state/dave-tools.status" "the worker resolution changed routes"

  dir=$(make_parent repaired-relay dave-tools)
  make_secondmate "$dir" intermediary
  rm "$dir/home/.fm-secondmate-parent"
  key="keepalive-dave-tools-w1-$T0"
  record="$dir/home/state/keepalive/asks/dave-tools.json"
  ask "$dir" dave-tools "blocked [key=$key]: worker w1 is frozen"
  scan "$dir" "$T0"
  scan "$dir" $((T0 + 1800))
  jq -e '.relays | all(.[]; .up and .route == "captain")' "$record" >/dev/null \
    || fail "the relay fallback route was not retained"
  make_secondmate "$dir" intermediary
  ask "$dir" dave-tools "resolved [key=$key]: worker w1 is moving again"
  scan "$dir" $((T0 + 1900))
  assert_equals 1 "$(notice_count "$dir" 'stuck work is moving again')" "a repaired channel stole the relay recovery notice"
  assert_absent "$dir/parent/state/intermediary.status" "the relay resolution changed routes"
  pass "worker and relay recoveries retain the captain fallback route after channel repair"
}

test_repaired_parent_channel_preserves_question_resolution_route() {
  local dir record ending
  for ending in answered leaves; do
    dir=$(make_parent "repaired-questions-$ending" dave-tools)
    make_secondmate "$dir" intermediary
    rm "$dir/home/.fm-secondmate-parent"
    record="$dir/home/state/keepalive/asks/dave-tools.json"
    ask "$dir" dave-tools 'needs-decision [key=budget]: which month should the new tab cover?'
    scan "$dir" "$T0"
    scan "$dir" $((T0 + 600))
    scan "$dir" $((T0 + 2400))
    assert_equals 1 "$(notice_count "$dir" 'its parent did not answer')" "the unanswered questions did not fall through to the captain"
    jq -e '.esc_report.route == "captain"' "$record" >/dev/null \
      || fail "the question aggregate fallback route was not retained"
    make_secondmate "$dir" intermediary
    if [ "$ending" = answered ]; then
      ask "$dir" dave-tools 'resolved [key=budget]: use January'
    else
      rm "$dir/home/state/dave-tools.meta"
    fi
    scan "$dir" $((T0 + 2500))
    assert_equals 2 "$(notice_count "$dir" .)" "a repaired channel stole the question $ending notice"
    if [ "$ending" = answered ]; then
      assert_equals 1 "$(notice_count "$dir" "questions are answered")" "the captain did not receive the answer resolution"
      jq -e 'has("esc_report") | not' "$record" >/dev/null \
        || fail "a resolved aggregate kept its old route"
    else
      assert_equals 1 "$(notice_count "$dir" 'left the fleet')" "the captain did not receive the departure resolution"
      assert_absent "$record" "the departed mate's aggregate remained"
    fi
    assert_absent "$dir/parent/state/intermediary.status" "the question resolution changed routes"
    scan "$dir" $((T0 + 2800))
    assert_equals 2 "$(notice_count "$dir" .)" "the question recovery repeated"
  done
  pass "question aggregates retain the captain fallback route for answers and departures"
}

test_approval_wait_excludes_action_demands_while_bound
test_approval_wait_is_bounded_and_wakes_the_mate_to_decide
test_hold_labelled_green_pr_is_ready_only_not_an_unmerged_demand
test_exact_approval_wait_survives_endpoint_loss
test_unreadable_approval_wait_keeps_pr_actions_excluded
test_approval_wait_retires_escalation_and_restarts_recovery
test_replaced_approval_wait_starts_its_own_episode
test_shared_hold_label_inputs
test_done_in_a_freeze_with_an_open_pr_is_not_healthy
test_undeliverable_parent_escalation_falls_through_to_the_captain
test_relay_closed_without_a_fix_goes_up_at_once
test_missing_closing_evidence_retains_only_dropped_relays
test_relays_opened_and_closed_between_scans_are_not_lost
test_relay_opened_during_the_fold_is_read_next_scan
test_relay_answer_straddling_the_snapshot_is_not_lost
test_pending_relay_openings_survive_until_owned_or_closed
test_relay_tail_baselines_and_channel_replacement
test_captain_held_relays_clear_quietly
test_repaired_parent_channel_preserves_captain_resolution_route
test_repaired_parent_channel_preserves_question_resolution_route
