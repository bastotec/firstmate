#!/usr/bin/env bash
# Behavior tests for bin/fm-worker-keepalive.sh: a worker that is held on its
# mate, blocked, without a live agent, or not making real progress wakes its mate
# with a concrete instruction within minutes, and only a mate that does not or
# cannot unstick it raises one plain line toward the captain.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

KEEPALIVE="$ROOT/bin/fm-worker-keepalive.sh"
TMP_ROOT=$(fm_test_tmproot fm-worker-keepalive)
T0=1800000000  # 2027-01-15T08:00:00Z

at() {  # <epoch> <path>: set a file's mtime to a fixture time
  python3 -c 'import os,sys; t=int(sys.argv[1]); os.utime(sys.argv[2], (t, t))' "$1" "$2"
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
  printf '%s\n' "$dir"
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
  FM_HOME="$1/home" FM_KEEPALIVE_NOW="$2" FM_KEEPALIVE_LIVENESS="$1/bin/liveness" "$KEEPALIVE" scan
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
  assert_contains "$(wakes "$dir")" 'never wait for a release' "the wake allows waiting for a release"
  assert_contains "$(wakes "$dir")" 'bin/fm-spawn.sh --relaunch w1' "the wake does not name the relaunch"
  scan "$dir" $((T0 + 1800))
  assert_equals 1 "$(wake_count "$dir")" "the same episode woke the mate twice"
  assert_absent "$channel" "the captain was reached before the mate had 30 minutes"
  scan "$dir" $((T0 + 1200 + 1800))
  assert_grep "blocked [key=keepalive-bob-helper-w1-$T0]: worker w1 has been stuck (held)" "$channel" "an ignored wake was not escalated"
  assert_grep 'releasing its hold' "$channel" "the escalation does not say what would unstick it"
  assert_equals 1 "$(wc -l < "$channel" | tr -d ' ')" "the escalation is more than one line"
  scan "$dir" $((T0 + 6000))
  assert_equals 1 "$(wc -l < "$channel" | tr -d ' ')" "the escalation repeated"
  status "$dir" $((T0 + 6100)) 'working [key=breadboard-plugin-trial]: hold released - resuming the build'
  scan "$dir" $((T0 + 6200))
  assert_grep "resolved [key=keepalive-bob-helper-w1-$T0]" "$channel" "a resumed worker did not resolve its escalation"
  pass "a worker held on its mate wakes the mate at 20 minutes and escalates once when ignored"
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
# owner". The mate is told to unblock it; a mate that steers but cannot unstick
# it is escalated after the bounded number of tries, from the first mate's own
# home as a check: wake.
test_blocked_worker_is_retried_by_the_mate_then_escalated() {
  local dir i now
  dir=$(make_home blocked ship)
  status "$dir" "$T0" 'blocked [key=nm-publication]: Needs tooling-owner recovery. Waiting for supported tooling-owner continuation through mate'
  scan "$dir" $((T0 + 1200))
  assert_equals 1 "$(wake_count "$dir")" "a blocked worker did not wake its mate"
  assert_contains "$(wakes "$dir")" 'unblock it in this turn' "the blocked wake is not an instruction"
  assert_contains "$(wakes "$dir")" 'retry a transient failure' "the blocked wake does not offer a retry"
  now=$((T0 + 1200))
  for i in 2 3; do
    steer "$dir" $((now + 60))
    scan "$dir" $((now + 120))
    assert_equals $((i - 1)) "$(wake_count "$dir")" "the mate's steer was answered with another wake at once"
    now=$((now + 120 + 1200))
    scan "$dir" "$now"
    assert_equals "$i" "$(wake_count "$dir")" "a worker still blocked after the mate acted was not woken again"
  done
  assert_no_grep 'raise it with the captain' "$dir/home/state/.wake-queue" "escalated before the mate ran out of tries"
  steer "$dir" $((now + 60))
  scan "$dir" $((now + 120))
  assert_grep 'raise it with the captain in one plain line' "$dir/home/state/.wake-queue" "a mate that could not unstick it was not escalated"
  assert_grep 'could not unstick it after 3 tries' "$dir/home/state/.wake-queue" "the escalation does not say the mate tried"
  pass "a blocked worker wakes its mate each episode and escalates after three tries"
}

test_a_steer_the_worker_already_handled_counts_as_the_mate_acting() {
  local dir inbox rec
  dir=$(make_home steer-handled ship)
  make_secondmate "$dir" handled
  status "$dir" "$T0" 'blocked: needs a retry'
  scan "$dir" $((T0 + 1200))
  assert_equals 1 "$(wake_count "$dir")" "setup: a blocked worker did not wake its mate"
  steer "$dir" $((T0 + 1300))
  inbox="$dir/home/state/w1.inbox"
  mkdir -p "$inbox/handled"
  for rec in "$inbox"/*.msg; do mv "$rec" "$inbox/handled/"; done
  scan "$dir" $((T0 + 1400))
  jq -e '.since == '$((T0 + 1400))' and .woke == 0' "$dir/home/state/keepalive/w1.json" >/dev/null \
    || fail "a steer the worker acknowledged before the scan was not counted as the mate acting"
  scan "$dir" $((T0 + 3200))
  [ ! -e "$dir/parent/state/handled.status" ] \
    || assert_no_grep 'did not act on the keep-alive wake' "$dir/parent/state/handled.status" \
      "a mate that steered was reported as ignoring the wake"
  pass "a steer the worker already handled counts as the mate acting"
}

test_inbox_bookkeeping_does_not_count_as_the_mate_acting() {
  local dir inbox file
  dir=$(make_home inbox-bookkeeping ship)
  make_secondmate "$dir" bookkeeping
  status "$dir" "$T0" 'blocked: needs a retry'
  steer "$dir" $((T0 + 1100))
  inbox="$dir/home/state/w1.inbox"
  scan "$dir" $((T0 + 1200))
  assert_equals 1 "$(wake_count "$dir")" "setup: a blocked worker did not wake its mate"
  for file in .ring-state .ring.log .escalated not-a-sequence.msg; do
    echo bookkeeping > "$inbox/$file"
    at $((T0 + 1400)) "$inbox/$file"
  done
  mkdir -p "$inbox/999.msg"
  mv "$inbox/001.msg" "$inbox/handled/001.msg"
  at $((T0 + 1400)) "$inbox/handled/001.msg"
  at $((T0 + 1400)) "$inbox/handled"
  at $((T0 + 1400)) "$inbox"
  scan "$dir" $((T0 + 1500))
  jq -e '.since == '$T0' and .woke == '$((T0 + 1200)) \
    "$dir/home/state/keepalive/w1.json" >/dev/null || fail "bookkeeping restarted the ignored-wake episode"
  scan "$dir" $((T0 + 3000))
  assert_grep 'did not act on the keep-alive wake' "$dir/parent/state/bookkeeping.status" \
    "bookkeeping delayed escalation or was reported as mate action"
  pass "only newly delivered numeric steering records count as mate action"
}

test_legacy_wake_adopts_the_current_steer_baseline() {
  local dir rec channel nudges
  for nudges in 1 3; do
    dir=$(make_home "legacy-wake-$nudges" ship)
    make_secondmate "$dir" legacy
    channel="$dir/parent/state/legacy.status"
    status "$dir" "$T0" 'blocked: needs a retry'
    steer "$dir" $((T0 + 1100))
    scan "$dir" $((T0 + 1200))
    assert_equals 1 "$(wake_count "$dir")" "setup: a blocked worker did not wake its mate"
    rec="$dir/home/state/keepalive/w1.json"
    jq --argjson inbox "$((T0 + 1100))" --argjson nudges "$nudges" \
      'del(.steer) | .inbox = $inbox | .nudges = $nudges' "$rec" > "$rec.tmp"
    mv "$rec.tmp" "$rec"
    mv "$dir/home/state/w1.inbox/001.msg" "$dir/home/state/w1.inbox/handled/001.msg"
    scan "$dir" $((T0 + 1500))
    jq -e --argjson since "$T0" --argjson woke "$((T0 + 1200))" --argjson nudges "$nudges" \
      '.steer == 1 and .since == $since and .woke == $woke and .nudges == $nudges and .escalated == false' \
      "$rec" >/dev/null || fail "an existing steer changed the legacy wake episode"
    assert_absent "$channel" "an existing steer escalated a legacy wake before its deadline"
    scan "$dir" $((T0 + 1800))
    jq -e --argjson woke "$((T0 + 1200))" '.steer == 1 and .woke == $woke' "$rec" >/dev/null \
      || fail "the adopted steer baseline did not survive another scan"
    scan "$dir" $((T0 + 3000))
    assert_grep 'did not act on the keep-alive wake' "$channel" \
      "baseline adoption delayed the ignored-wake escalation or claimed mate action"
    assert_no_grep 'could not unstick it' "$channel" "an existing steer counted as a new attempt"
  done
  pass "legacy wakes adopt existing steer sequences without changing escalation deadlines"
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
    assert_grep 'did not act on the keep-alive wake' "$state/.wake-queue" "override escalation was not delivered"
    rm "$state/w1.meta"
    FM_STATE_OVERRIDE="$state" scan "$dir" $((T0 + 3100))
    assert_absent "$state/keepalive/w1.json" "a departure kept its override episode"
    assert_grep 'left the fleet; clear its blocker' "$state/.wake-queue" "override resolution was not delivered"
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
  scan "$dir" $((T0 + 2699))
  assert_equals 0 "$(wake_count "$dir")" "a finished worker woke the mate before the cleanup cadence"
  scan "$dir" $((T0 + 2700))
  assert_contains "$(wakes "$dir")" 'make sure its result reached whoever waits on it' "an undelivered result did not wake the mate"
  assert_contains "$(wakes "$dir")" 'bin/fm-send.sh --result' "the wake does not name the result resend"
  rm "$dir/home/state/w1.meta"
  scan "$dir" $((T0 + 2800))
  assert_absent "$dir/home/state/keepalive/w1.json" "a cleaned-up worker kept its record"
  pass "a finished worker that lingers wakes its mate to deliver its result"
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
  printf '%s\n' "$dir"
}

ask() {  # <dir> <mate> <line>
  printf '%s\n' "$3" >> "$1/home/state/$2.status"
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
  assert_equals 1 "$(wake_count "$dir")" "an answered question escalated"
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
  assert_equals 1 "$(wakes "$dir" | grep -c 'raise it with the captain in one plain line')" "an ignored question was not escalated once"
  assert_contains "$(wakes "$dir")" 'which month should the new tab cover' "the escalation does not name the question"
  scan "$dir" $((T0 + 1300 + 1800))
  assert_equals 2 "$(wakes "$dir" | grep -c 'raise it with the captain')" "the later question was not escalated in its turn"
  scan "$dir" $((T0 + 6000))
  assert_equals 2 "$(wakes "$dir" | grep -c 'raise it with the captain')" "an escalation repeated"
  ask "$dir" finn 'resolved [key=budget-sheet]: answered: November'
  ask "$dir" finn 'resolved [key=bank-item]: answered: Inter'
  scan "$dir" $((T0 + 6100))
  assert_contains "$(wakes "$dir")" "second mate finn's questions are answered; clear its blocker" "answered questions did not clear the escalation"
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
    assert_equals 1 "$(wakes "$dir" | grep -c 'raise it with the captain')" "a $mode question inherited the previous escalation deadline"
    scan "$dir" $((T0 + 5000))
    scan "$dir" $((T0 + 5100))
    assert_equals 2 "$(wakes "$dir" | grep -c 'raise it with the captain')" "a $mode question did not escalate exactly once"
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

test_held_on_the_mate_wakes_then_escalates_once
test_external_wait_is_left_to_the_declared_wait_cadence
test_blocked_worker_is_retried_by_the_mate_then_escalated
test_inbox_bookkeeping_does_not_count_as_the_mate_acting
test_a_steer_the_worker_already_handled_counts_as_the_mate_acting
test_legacy_wake_adopts_the_current_steer_baseline
test_state_override_owns_scans_locks_records_and_wakes
test_worker_without_a_live_agent_is_relaunched
test_no_real_progress_counts_code_not_reports
test_done_worker_and_departures
test_finished_result_that_never_left_is_raised
test_repeated_episodes_have_distinct_parent_keys
test_supervisor_declared_wait_defers_stalls_until_expiry
test_watcher_keepalive_guard_stays_cheap_and_obeys_cadence
test_unanswered_mate_question_wakes_the_parent
test_a_question_the_parent_never_answers_reaches_the_captain_once
test_reopened_questions_get_fresh_deadlines
test_open_question_reposts_preserve_the_episode
test_escalation_tracks_all_still_open_questions
