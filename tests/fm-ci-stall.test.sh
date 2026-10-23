#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-stall.sh: a worker PR's stuck check is re-triggered
# once, a check still stuck after that is diagnosed and handed to the worker (or
# raised as a blocker when the worker cannot be reached), and every step is
# counted for fleet dreaming.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

STALL="$ROOT/bin/fm-ci-stall.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-stall)
PR=https://github.com/o/r/pull/7
T0=1800000000  # 2027-01-15T08:00:00Z

stamp() { python3 -c 'import sys,time; print(time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(int(sys.argv[1]))))' "$1"; }

# A home with one ship worker on $PR, and stubs for gh, fm-send and fm-ci-infra.
# The gh stub serves $dir/fix/checks.json for the head's check runs, records
# `run rerun|cancel` calls in $dir/calls.log, and serves zero steps for a job
# listed in $dir/fix/zero-steps.
make_home() {
  local dir="$TMP_ROOT/$1"
  mkdir -p "$dir/home/state" "$dir/bin" "$dir/fix"
  printf 'kind=ship\npr=%s\n' "$PR" > "$dir/home/state/w1.meta"
  printf 'kind=ship\n' > "$dir/home/state/no-pr.meta"
  : > "$dir/calls.log"
  : > "$dir/fix/zero-steps"
  cat > "$dir/bin/gh" <<EOF
#!/usr/bin/env bash
fix="$dir/fix"
if [ "\$1 \$2" = 'api repos/o/r/pulls/7' ] && [ -e "\$fix/hold" ]; then
  touch "\$fix/entered"
  for ((i=0; i<200; i++)); do
    [ -e "\$fix/hold" ] || break
    sleep 0.05
  done
  [ ! -e "\$fix/hold" ] || exit 1
fi
if [ "\$1" = api ]; then
  case "\$2" in
    repos/o/*/pulls/7) echo '{"state":"open","head":{"sha":"abc"}}' ;;
    repos/o/*/commits/abc/check-runs*)
      if [[ " \$* " == *' --paginate '* && " \$* " == *' --slurp '* ]]; then
        if [ -e "\$fix/checks-page2.json" ]; then
          jq -s '.' "\$fix/checks.json" "\$fix/checks-page2.json"
        else
          jq -s '.' "\$fix/checks.json"
        fi
      else cat "\$fix/checks.json"; fi ;;
    repos/o/*/actions/runs/*)
      echo "\$2" >> "$dir/validated.log"
      if [ -e "\$fix/run-\${2##*/}.json" ]; then cat "\$fix/run-\${2##*/}.json"; else echo '{"head_sha":"abc"}'; fi ;;
    repos/o/*/actions/jobs/*)
      if grep -qx "\${2##*/}" "\$fix/zero-steps"; then echo '{"steps":[]}'; else echo '{"steps":[{"name":"x"}]}'; fi ;;
    *) echo "unexpected api \$2" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "\$*" >> "$dir/calls.log"
if [ "\$1 \$2" = 'run rerun' ] && [ -e "$dir/rerun-fails" ]; then exit 1; fi
if [ "\$1 \$2" = 'run cancel' ] && [ -e "$dir/cancel-fails" ]; then exit 1; fi
exit 0
EOF
  cat > "$dir/bin/send" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$dir/sent.log"
[ ! -e "$dir/send-fails" ]
EOF
  cat > "$dir/bin/infra" <<EOF
#!/usr/bin/env bash
cat "$dir/fix/infra.out" 2>/dev/null
EOF
  chmod +x "$dir/bin/gh" "$dir/bin/send" "$dir/bin/infra"
  printf '%s\n' "$dir"
}

# check <name> <job id> <run id> <status> <conclusion> <started epoch> [completed epoch]
check() {
  jq -cn --arg n "$1" --argjson id "$2" --arg run "$3" --arg s "$4" --arg c "$5" \
    --arg st "$(stamp "$6")" --arg ct "${7:+$(stamp "${7:-0}")}" \
    '{name: $n, id: $id, app: {slug: "github-actions"}, status: $s, conclusion: (if $c == "" then null else $c end),
      started_at: $st, completed_at: (if $ct == "" then null else $ct end),
      details_url: ("https://github.com/o/r/actions/runs/" + $run + "/job/" + ($id|tostring))}'
}

checks() { jq -cs '{check_runs: .}' > "$1/fix/checks.json"; }

scan() {  # <dir> <now>
  FM_HOME="$1/home" FM_CI_STALL_NOW="$2" FM_CI_STALL_GH="$1/bin/gh" FM_CI_STALL_SEND="$1/bin/send" \
    FM_CI_STALL_INFRA="$1/bin/infra" PATH="$1/bin:$PATH" "$STALL" scan
}

enable_timeouts() {
  printf '#!%s\n' "$(command -v python3)" > "$1/bin/python3"
  cat >> "$1/bin/python3" <<'PY'
import os
from pathlib import Path
import runpy
import subprocess
import sys
from unittest.mock import patch

real_run = subprocess.run
fixture = Path(os.environ['FM_CI_STALL_GH']).parent.parent

def run(args, *pos, **kwargs):
    marker = None
    if args[0] == os.environ['FM_CI_STALL_GH'] and args[1:3] == ['run', 'cancel']:
        marker = 'cancel-timeout-' + args[3]
    elif args[0] == os.environ['FM_CI_STALL_INFRA']:
        marker = 'infra-timeout'
    elif args[0] == os.environ['FM_CI_STALL_SEND']:
        marker = 'send-timeout'
    if marker and (fixture / marker).exists():
        raise subprocess.TimeoutExpired(args, kwargs['timeout'])
    return real_run(args, *pos, **kwargs)

sys.argv = sys.argv[1:]
with patch('subprocess.run', run):
    runpy.run_path(sys.argv[0], run_name='__main__')
PY
  chmod +x "$1/bin/python3"
}

counts() { FM_HOME="$1/home" "$STALL" counts "${2:-0}"; }

test_queued_check_is_cancelled_then_rerun_once_and_recovers() {
  local dir out
  dir=$(make_home queued)
  check verify 11 501 queued "" $((T0 - 600)) | checks "$dir"
  scan "$dir" "$T0"
  assert_equals "" "$(cat "$dir/calls.log")" "a check queued 10 minutes was touched"
  scan "$dir" $((T0 + 900))
  assert_equals "run cancel 501 --repo o/r" "$(cat "$dir/calls.log")" "a check queued 25 minutes was not cancelled for a rerun"
  # GitHub now shows the run cancelled with zero steps: that is the scan's own cancel, not a missing runner
  echo 11 > "$dir/fix/zero-steps"
  check verify 11 501 completed cancelled $((T0 - 600)) $((T0 + 960)) | checks "$dir"
  scan "$dir" $((T0 + 1200))
  assert_contains "$(cat "$dir/calls.log")" "run rerun 501 --repo o/r" "the cancelled run was not rerun"
  assert_equals "" "$(cat "$dir/sent.log" 2>/dev/null)" "the scan's own cancel was handed to the worker as a stall"
  check verify 12 501 in_progress "" $((T0 + 1300)) | checks "$dir"
  scan "$dir" $((T0 + 1500))
  out=$(counts "$dir")
  assert_equals '{"cancelled-for-rerun": 1, "recovered": 1, "retriggered": 1, "stalled": 1}' "$out" "the events were not counted"
  pass "a check queued past the bound is cancelled, rerun once, and counted as recovered"
}

test_cancelled_without_runner_is_rerun_at_once() {
  local dir
  dir=$(make_home norunner)
  echo 21 > "$dir/fix/zero-steps"
  { check build 21 601 completed cancelled $((T0 - 100)) $((T0 - 90)); check lint 22 602 completed cancelled $((T0 - 100)) $((T0 - 90)); } | checks "$dir"
  scan "$dir" "$T0"
  assert_equals "run rerun 601 --repo o/r" "$(cat "$dir/calls.log")" "only the zero-step cancelled run should be rerun"
  pass "a run cancelled without a runner is rerun at once and a run cancelled after it started is left alone"
}

test_stuck_again_is_diagnosed_and_handed_off_once() {
  local dir sent
  dir=$(make_home handoff)
  echo 31 > "$dir/fix/zero-steps"
  check build 31 701 completed cancelled $((T0 - 100)) $((T0 - 90)) | checks "$dir"
  scan "$dir" "$T0"
  printf 'infra build: The job was not started because recent account payments have failed\n' > "$dir/fix/infra.out"
  echo 32 > "$dir/fix/zero-steps"
  check build 32 701 completed cancelled $((T0 + 60)) $((T0 + 70)) | checks "$dir"
  scan "$dir" $((T0 + 600))
  sent=$(cat "$dir/sent.log")
  assert_contains "$sent" "w1 CI on $PR is still stuck after one re-run: build" "the worker was not told which check is stuck"
  assert_contains "$sent" "recent account payments have failed" "the diagnosis did not reach the worker"
  scan "$dir" $((T0 + 1200))
  assert_equals 1 "$(wc -l < "$dir/sent.log" | tr -d ' ')" "the same head was handed off twice"
  assert_equals 1 "$(grep -c rerun "$dir/calls.log")" "the same run was re-triggered twice"
  assert_contains "$(counts "$dir")" '"handed-off": 1' "the hand-off was not counted"
  pass "a check stuck again after its one re-run is diagnosed and handed to the worker once"
}

test_fresh_stalls_do_not_starve_an_exhausted_hand_off() {
  local dir sent
  dir=$(make_home starve)
  echo 31 > "$dir/fix/zero-steps"
  check build 31 701 completed cancelled $((T0 - 100)) $((T0 - 90)) | checks "$dir"
  scan "$dir" "$T0"
  # build's run is stuck again after its one rerun while lint's run is newly stuck
  printf '31\n32\n33\n' > "$dir/fix/zero-steps"
  { check build 32 701 completed cancelled $((T0 + 60)) $((T0 + 70)); check lint 33 702 completed cancelled $((T0 + 60)) $((T0 + 70)); } | checks "$dir"
  scan "$dir" $((T0 + 600))
  assert_contains "$(cat "$dir/calls.log")" "run rerun 702 --repo o/r" "the newly stuck run was not re-triggered"
  sent=$(cat "$dir/sent.log" 2>/dev/null)
  assert_contains "$sent" "is still stuck after one re-run: build (" "the exhausted run was not handed off beside the fresh re-trigger"
  [[ "$sent" != *lint* ]] || fail "the freshly re-triggered run was handed off before its own re-run"
  # another fresh stall on the same head adds no second hand-off
  printf '31\n32\n33\n34\n' > "$dir/fix/zero-steps"
  { check build 32 701 completed cancelled $((T0 + 60)) $((T0 + 70)); check lint 33 702 completed cancelled $((T0 + 60)) $((T0 + 70));
    check test 34 703 completed cancelled $((T0 + 700)) $((T0 + 710)); } | checks "$dir"
  scan "$dir" $((T0 + 1200))
  assert_contains "$(cat "$dir/calls.log")" "run rerun 703 --repo o/r" "a later fresh stall was not re-triggered"
  assert_equals 1 "$(wc -l < "$dir/sent.log" | tr -d ' ')" "the same head was handed off twice"
  pass "a newly stuck run is re-triggered while an exhausted run on the same head is still handed off once"
}

test_unreachable_worker_raises_a_blocker() {
  local dir
  dir=$(make_home blocker)
  : > "$dir/send-fails"
  check e2e 41 801 in_progress "" $((T0 - 4000)) | checks "$dir"
  scan "$dir" "$T0"
  assert_equals "run cancel 801 --repo o/r" "$(cat "$dir/calls.log")" "a run past the fallback bound was not cancelled"
  check e2e 41 801 completed cancelled $((T0 - 4000)) $((T0 + 10)) | checks "$dir"
  scan "$dir" $((T0 + 60))
  check e2e 42 801 in_progress "" $((T0 + 100)) | checks "$dir"
  scan "$dir" $((T0 + 3800))
  assert_contains "$(cat "$dir/sent.log")" "a hung test or step" "a run that keeps running was not diagnosed as hung"
  assert_contains "$(counts "$dir")" '"blocker": 1' "a failed hand-off did not raise a blocker"
  pass "a hung job the worker cannot be told about becomes one blocker"
}

test_running_bound_follows_the_usual_duration() {
  local dir
  dir=$(make_home durations)
  { check unit 51 901 completed success $((T0 - 900)) $((T0 - 600))
    check unit 52 902 completed success $((T0 - 900)) $((T0 - 590))
    check unit 53 903 completed success $((T0 - 900)) $((T0 - 580)); } | checks "$dir"
  scan "$dir" "$T0"
  check unit 54 904 in_progress "" $((T0 - 500)) | checks "$dir"
  scan "$dir" "$T0"
  assert_equals "" "$(cat "$dir/calls.log")" "a run within twice its usual 5 minutes was touched"
  scan "$dir" $((T0 + 200))
  assert_equals "run cancel 904 --repo o/r" "$(cat "$dir/calls.log")" "a run past twice its usual duration was not re-triggered"
  pass "a running check is stuck past twice the median of its last successful runs"
}

test_counts_window_and_usage() {
  local dir rc=0
  dir=$(make_home window)
  check verify 61 1001 queued "" $((T0 - 2000)) | checks "$dir"
  scan "$dir" "$T0"
  assert_contains "$(counts "$dir" $((T0 - 1)))" '"stalled": 1' "an event inside the window was not counted"
  assert_equals "{}" "$(counts "$dir" $((T0 + 1)))" "an event before the window was counted"
  "$STALL" bogus >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "an unknown command did not exit 2"
  pass "counts honour the window and an unknown command is refused"
}

test_duration_samples_identify_distinct_recent_runs() {
  local dir n
  dir=$(make_home distinct-durations)
  { check unit 1 101 completed success $((T0 - 1000)) $((T0 - 940))
    check unit 2 102 completed success $((T0 - 1000)) $((T0 - 400))
    check unit 3 103 in_progress "" $((T0 - 700)); } | checks "$dir"
  for n in 1 2 3 4; do scan "$dir" "$T0"; done
  assert_equals "" "$(cat "$dir/calls.log")" "reobserved successes fabricated a learned bound"
  assert_equals 2 "$(jq '."o/r".unit | length' "$dir/home/state/ci-stall/durations.json")" "duplicate observations became samples"
  for n in 4 5 6; do
    check unit "$n" "$((100 + n))" completed success $((T0 - 100)) $((T0 - 40)) | checks "$dir"
    scan "$dir" "$T0"
  done
  check unit 7 107 in_progress "" $((T0 - 200)) | checks "$dir"
  scan "$dir" "$T0"
  assert_equals 'run cancel 107 --repo o/r' "$(cat "$dir/calls.log")" "distinct equal-duration successes did not teach the median"
  for n in 20 19 18 17 16 15 14 13 12 11 10; do
    check unit "$n" "$((100 + n))" completed success $((T0 + n)) $((T0 + n + 60)) | checks "$dir"
    scan "$dir" "$T0"
  done
  check unit 1 101 completed success $((T0 - 1000)) $((T0 - 940)) | checks "$dir"
  scan "$dir" "$T0"
  jq -e '."o/r".unit | (length == 10) and (keys | map(tonumber) | sort == [11,12,13,14,15,16,17,18,19,20])' \
    "$dir/home/state/ci-stall/durations.json" >/dev/null || fail "samples did not retain the latest ten distinct check runs"
  pass "duration learning counts check identities and retains the latest ten successes"
}

test_failed_reruns_remain_pending_until_success_or_diagnosis() {
  local dir n
  dir=$(make_home retry-rerun)
  check verify 11 501 queued "" $((T0 - 2000)) | checks "$dir"
  scan "$dir" "$T0"
  echo 11 > "$dir/fix/zero-steps"
  check verify 11 501 completed cancelled $((T0 - 2000)) "$T0" | checks "$dir"
  : > "$dir/rerun-fails"
  scan "$dir" "$T0"
  jq -e '.pending_rerun == ["501"] and .rerun_failures["501"] == 1 and (.handed_off | not)' \
    "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "a failed rerun lost cancellation provenance"
  assert_equals "" "$(cat "$dir/sent.log" 2>/dev/null)" "a failed rerun became a no-runner stall"
  rm "$dir/rerun-fails"
  scan "$dir" "$T0"
  jq -e '.pending_rerun == []' "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "successful rerun remained pending"
  assert_equals 1 "$(counts "$dir" | jq '.retriggered')" "only confirmed reruns should be counted"

  dir=$(make_home rerun-exhausted)
  echo 12 > "$dir/fix/zero-steps"
  check verify 12 502 completed cancelled $((T0 - 2000)) "$T0" | checks "$dir"
  : > "$dir/rerun-fails"
  scan "$dir" "$T0"
  jq -e '.retriggered == [] and .pending_rerun == ["502"] and .rerun_failures["502"] == 1' \
    "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "failed immediate rerun was recorded as confirmed"
  for n in 2 3 4 5; do scan "$dir" "$T0"; done
  assert_equals 3 "$(grep -c 'run rerun' "$dir/calls.log")" "rerun failures exceeded the three-attempt limit"
  assert_equals 1 "$(wc -l < "$dir/sent.log" | tr -d ' ')" "exhausted reruns were not handed off exactly once"
  assert_contains "$(cat "$dir/sent.log")" 'Diagnosis: rerun failure' "exhausted attempts were not diagnosed as rerun failure"
  assert_equals 0 "$(counts "$dir" | jq '.retriggered // 0')" "failed requests were recorded as successful reruns"
  jq -e '.pending_rerun == ["502"] and .handed_off' "$dir/home/state/ci-stall/w1.json" >/dev/null \
    || fail "exhausted rerun lost its cancellation provenance"
  pass "reruns retry without reclassifying cancellation, and escalate after three failures"
}

test_blocker_delivery_is_retried_until_confirmed() {
  local dir mode
  for mode in parent wake; do
    dir=$(make_home "blocker-retry-$mode")
    echo 11 > "$dir/fix/zero-steps"
    check verify 11 501 completed cancelled $((T0 - 2000)) "$T0" | checks "$dir"
    scan "$dir" "$T0"
    : > "$dir/send-fails"
    if [ "$mode" = parent ]; then
      echo mate > "$dir/home/.fm-secondmate-home"
    else
      mkdir "$dir/home/state/.wake-queue"
    fi
    scan "$dir" "$T0"
    jq -e '.handed_off | not' "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "failed $mode delivery suppressed retries"
    assert_equals 0 "$(counts "$dir" | jq '.blocker // 0')" "failed $mode delivery counted as a blocker"
    if [ "$mode" = parent ]; then
      printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$dir/home/.fm-secondmate-parent"
      mkdir "$dir/home/state/parent-replies.status"
      scan "$dir" "$T0"
      jq -e '.handed_off | not' "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "failed parent append suppressed retries"
      rmdir "$dir/home/state/parent-replies.status"
    else
      rmdir "$dir/home/state/.wake-queue"
    fi
    scan "$dir" "$T0"
    scan "$dir" "$T0"
    jq -e '.handed_off' "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "confirmed $mode delivery not saved"
    assert_equals 1 "$(counts "$dir" | jq '.blocker')" "confirmed $mode blocker not counted exactly once"
    if [ "$mode" = parent ]; then
      assert_contains "$(cat "$dir/home/state/parent-replies.status")" 'blocked [key=ci-stall-w1]' "parent blocker was not delivered"
    else
      assert_contains "$(cat "$dir/home/state/.wake-queue")" 'check: stalled CI:' "first-mate wake was not delivered"
    fi
  done
  pass "parent binding, parent append and wake failures remain eligible for delivery"
}

test_checks_share_one_workflow_mutation() {
  local dir mode
  for mode in queued completed; do
    dir=$(make_home "group-$mode")
    printf '11\n12\n' > "$dir/fix/zero-steps"
    { check verify 11 501 "$mode" cancelled $((T0 - 2000)) "$T0"
      check unit 12 501 "$mode" cancelled $((T0 - 2000)) "$T0"; } | checks "$dir"
    scan "$dir" "$T0"
    assert_equals 1 "$(wc -l < "$dir/calls.log" | tr -d ' ')" "two checks mutated one workflow twice"
    if [ "$mode" = queued ]; then
      jq -e '.pending_rerun == ["501"] and .retriggered == ["501"]' "$dir/home/state/ci-stall/w1.json" >/dev/null \
        || fail "one workflow was recorded more than once"
      { check verify 11 501 completed cancelled $((T0 - 2000)) "$T0"
        check unit 12 501 completed cancelled $((T0 - 2000)) "$T0"; } | checks "$dir"
      scan "$dir" "$T0"
      assert_equals 1 "$(grep -c 'run rerun' "$dir/calls.log")" "pending workflow was rerun twice"
    fi
  done
  pass "multiple stalled checks trigger one cancel or rerun per workflow"
}

test_overlapping_scans_exit_quietly_without_mutating() {
  local dir
  dir=$(make_home overlapping)
  check verify 11 501 queued "" $((T0 - 2000)) | checks "$dir"
  touch "$dir/fix/hold"
  python3 - "$dir" "$STALL" "$T0" <<'PY' || fail "overlapping scans were not serialized"
import json, os, pathlib, subprocess, sys, time
d, entry, now = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
env = dict(os.environ, FM_HOME=str(d / 'home'), FM_CI_STALL_NOW=now,
           FM_CI_STALL_GH=str(d / 'bin/gh'), FM_CI_STALL_SEND=str(d / 'bin/send'),
           FM_CI_STALL_INFRA=str(d / 'bin/infra'))
first = subprocess.Popen([entry, 'scan'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
try:
    deadline = time.monotonic() + 5
    while not (d / 'fix/entered').exists() and time.monotonic() < deadline:
        time.sleep(.05)
    assert (d / 'fix/entered').exists(), 'first scan never reached GitHub'
    other = subprocess.run([entry, 'scan'], env=env, capture_output=True, timeout=3)
    assert other.returncode == 0 and not other.stdout and not other.stderr, other
    assert not (d / 'calls.log').read_text(), 'overlapping scan mutated GitHub'
    (d / 'fix/hold').unlink()
    out, err = first.communicate(timeout=12)
    assert first.returncode == 0 and not err, (out, err)
    assert (d / 'calls.log').read_text().splitlines() == ['run cancel 501 --repo o/r']
    rec = json.loads((d / 'home/state/ci-stall/w1.json').read_text())
    assert rec['pending_rerun'] == ['501'], rec
    again = subprocess.run([entry, 'scan'], env=env, capture_output=True, timeout=3)
    assert again.returncode == 0 and not again.stderr, again
finally:
    (d / 'fix/hold').unlink(missing_ok=True)
    if first.poll() is None:
        first.kill()
    first.communicate(timeout=12)
PY
  pass "one per-home scan owns GitHub actions and shared state at a time"
}

test_rejected_cancel_remains_eligible() {
  local dir n
  dir=$(make_home rejected-cancel)
  check verify 11 501 queued "" $((T0 - 2000)) | checks "$dir"
  touch "$dir/cancel-fails"
  for n in 1 2; do scan "$dir" "$T0"; done
  assert_equals 2 "$(wc -l < "$dir/calls.log" | tr -d ' ')" "failed cancellation was not retried"
  jq -e '.retriggered == [] and .pending_rerun == [] and (.handed_off | not)' \
    "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "rejected cancellation consumed the retry"
  assert_equals "" "$(cat "$dir/sent.log" 2>/dev/null)" "rejected cancellation caused premature handoff"
  rm "$dir/cancel-fails"
  scan "$dir" "$T0"
  jq -e '.retriggered == ["501"] and .pending_rerun == ["501"]' \
    "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "successful cancellation was not saved"
  pass "a rejected cancellation leaves the workflow eligible for its retry"
}

test_transitions_survive_later_timeouts() {
  local dir mode
  for mode in immediate pending cancel; do
    dir=$(make_home "transition-$mode")
    if [ "$mode" = pending ]; then
      check verify 11 501 queued "" $((T0 - 2000)) | checks "$dir"
      scan "$dir" "$T0"
    fi
    echo 11 > "$dir/fix/zero-steps"
    { if [ "$mode" = cancel ]; then
        check verify 11 501 queued "" $((T0 - 2000))
      else
        check verify 11 501 completed cancelled $((T0 - 2000)) "$T0"
      fi
      check build 12 502 queued "" $((T0 - 2000)); } | checks "$dir"
    enable_timeouts "$dir"
    touch "$dir/cancel-timeout-502"
    scan "$dir" "$T0" 2> "$dir/errors.log"
    assert_contains "$(cat "$dir/errors.log")" 'timed out' "the later workflow did not time out"
    jq -e '.retriggered == ["501"]' "$dir/home/state/ci-stall/w1.json" >/dev/null \
      || fail "confirmed $mode transition was lost to a later timeout"
    if [ "$mode" = cancel ]; then
      jq -e '.pending_rerun == ["501"]' "$dir/home/state/ci-stall/w1.json" >/dev/null \
        || fail "confirmed cancellation lost its pending rerun"
    else
      jq -e '.pending_rerun == []' "$dir/home/state/ci-stall/w1.json" >/dev/null \
        || fail "confirmed rerun remained pending after a later timeout"
    fi
    rm "$dir/cancel-timeout-502"
    scan "$dir" "$T0"
    if [ "$mode" = cancel ]; then
      assert_equals 1 "$(grep -c 'run cancel 501' "$dir/calls.log")" "confirmed cancellation was repeated"
    else
      assert_equals 1 "$(grep -c 'run rerun 501' "$dir/calls.log")" "confirmed rerun was repeated"
    fi
  done
  pass "confirmed workflow transitions survive a later workflow timeout"
}

test_only_actions_checks_are_considered() {
  local dir
  dir=$(make_home provenance)
  echo 12 > "$dir/fix/zero-steps"
  { check queued 11 501 queued "" $((T0 - 2000))
    check cancelled 12 502 completed cancelled $((T0 - 2000)) "$T0"
    check success 13 503 completed success $((T0 - 2000)) "$T0"; } \
    | jq -c '.app.slug = "other-app"' | checks "$dir"
  scan "$dir" "$T0"
  assert_equals "" "$(cat "$dir/calls.log")" "a third-party check mutated Actions"
  assert_equals "{}" "$(counts "$dir")" "a third-party check was treated as stalled"
  assert_equals "{}" "$(cat "$dir/home/state/ci-stall/durations.json")" "third-party durations were learned"
  pass "only GitHub Actions checks can influence stall recovery"
}

test_mutations_require_the_watched_head() {
  local dir mode
  for mode in cancel rerun pending; do
    dir=$(make_home "head-$mode")
    if [ "$mode" = pending ]; then
      check verify 11 501 queued "" $((T0 - 2000)) | checks "$dir"
      scan "$dir" "$T0"
      : > "$dir/calls.log"
    fi
    if [ "$mode" = cancel ]; then
      check verify 11 501 queued "" $((T0 - 2000)) | checks "$dir"
    else
      echo 11 > "$dir/fix/zero-steps"
      check verify 11 501 completed cancelled $((T0 - 2000)) "$T0" | checks "$dir"
    fi
    printf '{"head_sha":"unrelated"}\n' > "$dir/fix/run-501.json"
    scan "$dir" "$T0"
    assert_equals "" "$(cat "$dir/calls.log")" "$mode mutated an unrelated head"
    assert_contains "$(cat "$dir/validated.log")" 'repos/o/r/actions/runs/501' "workflow identity was not fetched"
    assert_equals "" "$(cat "$dir/sent.log" 2>/dev/null)" "unrelated head was handed off"
    rm "$dir/fix/run-501.json"
    scan "$dir" "$T0"
    if [ "$mode" = cancel ]; then
      assert_equals 'run cancel 501 --repo o/r' "$(cat "$dir/calls.log")" "matching head was not cancelled"
    else
      assert_equals 'run rerun 501 --repo o/r' "$(cat "$dir/calls.log")" "matching head was not rerun"
    fi
  done
  pass "cancellation and both rerun paths validate the current workflow head"
}

test_all_check_pages_drive_detection_and_pending_reruns() {
  local dir
  dir=$(make_home pagination)
  check healthy 1 500 completed success $((T0 - 200)) $((T0 - 100)) \
    | jq '. as $c | {check_runs: [range(1;101) as $id | $c + {id: $id}]}' > "$dir/fix/checks.json"
  check verify 101 501 queued "" $((T0 - 2000)) | jq -s '{check_runs: .}' > "$dir/fix/checks-page2.json"
  scan "$dir" "$T0"
  assert_equals 'run cancel 501 --repo o/r' "$(cat "$dir/calls.log")" "a stalled check after the first page was missed"
  echo 101 > "$dir/fix/zero-steps"
  check verify 101 501 completed cancelled $((T0 - 2000)) "$T0" \
    | jq -s '{check_runs: .}' > "$dir/fix/checks-page2.json"
  scan "$dir" "$T0"
  assert_equals 1 "$(grep -c 'run rerun 501' "$dir/calls.log")" "pending check after the first page was not rerun"
  jq -e '.pending_rerun == []' "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "paginated rerun stayed pending"
  pass "all check pages contribute to stall detection and pending completion"
}

test_timeout_escalation_falls_back_once() {
  local dir mode
  for mode in handoff blocker; do
    dir=$(make_home "timeout-$mode")
    echo 11 > "$dir/fix/zero-steps"
    check verify 11 501 completed cancelled $((T0 - 2000)) "$T0" | checks "$dir"
    scan "$dir" "$T0"
    enable_timeouts "$dir"
    touch "$dir/infra-timeout"
    if [ "$mode" = blocker ]; then touch "$dir/send-timeout"; fi
    scan "$dir" "$T0"
    scan "$dir" "$T0"
    jq -e '.handed_off' "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "timeout suppressed escalation"
    if [ "$mode" = handoff ]; then
      assert_contains "$(cat "$dir/sent.log")" 'diagnosis unavailable' "classifier timeout did not reach the worker"
      assert_equals 1 "$(wc -l < "$dir/sent.log" | tr -d ' ')" "timeout diagnosis was handed off twice"
    else
      assert_contains "$(cat "$dir/home/state/.wake-queue")" 'diagnosis unavailable' "send timeout did not raise a blocker"
      assert_equals 1 "$(counts "$dir" | jq '.blocker')" "send timeout did not produce exactly one blocker"
    fi
  done
  pass "classifier and send timeouts preserve the escalation fallback"
}

test_pr_rebinding_resets_progress_on_the_same_head() {
  local dir
  dir=$(make_home rebind)
  echo 11 > "$dir/fix/zero-steps"
  check verify 11 501 completed cancelled $((T0 - 2000)) "$T0" | checks "$dir"
  scan "$dir" "$T0"
  scan "$dir" "$T0"
  jq -e '.handed_off' "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "original PR was not handed off"
  printf 'kind=ship\npr=https://github.com/o/other/pull/7\n' > "$dir/home/state/w1.meta"
  scan "$dir" "$T0"
  jq -e '.pr == "https://github.com/o/other/pull/7" and (.handed_off | not)' \
    "$dir/home/state/ci-stall/w1.json" >/dev/null || fail "PR rebind retained the old handoff"
  assert_contains "$(cat "$dir/calls.log")" 'run rerun 501 --repo o/other' "replacement PR did not get its own retry"
  scan "$dir" "$T0"
  assert_equals 2 "$(wc -l < "$dir/sent.log" | tr -d ' ')" "replacement PR diagnosis was suppressed"
  pass "rebinding a worker PR resets CI progress even on the same head"
}

test_rejected_cancel_remains_eligible
test_transitions_survive_later_timeouts
test_only_actions_checks_are_considered
test_mutations_require_the_watched_head
test_all_check_pages_drive_detection_and_pending_reruns
test_timeout_escalation_falls_back_once
test_pr_rebinding_resets_progress_on_the_same_head
test_duration_samples_identify_distinct_recent_runs
test_failed_reruns_remain_pending_until_success_or_diagnosis
test_blocker_delivery_is_retried_until_confirmed
test_checks_share_one_workflow_mutation
test_overlapping_scans_exit_quietly_without_mutating
test_queued_check_is_cancelled_then_rerun_once_and_recovers
test_cancelled_without_runner_is_rerun_at_once
test_stuck_again_is_diagnosed_and_handed_off_once
test_fresh_stalls_do_not_starve_an_exhausted_hand_off
test_unreachable_worker_raises_a_blocker
test_running_bound_follows_the_usual_duration
test_counts_window_and_usage
