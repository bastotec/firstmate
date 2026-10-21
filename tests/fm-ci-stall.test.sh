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
if [ "\$1" = api ]; then
  case "\$2" in
    repos/o/r/pulls/7) echo '{"state":"open","head":{"sha":"abc"}}' ;;
    repos/o/r/commits/abc/check-runs*) cat "\$fix/checks.json" ;;
    repos/o/r/actions/jobs/*)
      if grep -qx "\${2##*/}" "\$fix/zero-steps"; then echo '{"steps":[]}'; else echo '{"steps":[{"name":"x"}]}'; fi ;;
    *) echo "unexpected api \$2" >&2; exit 1 ;;
  esac
  exit 0
fi
echo "\$*" >> "$dir/calls.log"
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
    '{name: $n, id: $id, status: $s, conclusion: (if $c == "" then null else $c end),
      started_at: $st, completed_at: (if $ct == "" then null else $ct end),
      details_url: ("https://github.com/o/r/actions/runs/" + $run + "/job/" + ($id|tostring))}'
}

checks() { jq -cs '{check_runs: .}' > "$1/fix/checks.json"; }

scan() {  # <dir> <now>
  FM_HOME="$1/home" FM_CI_STALL_NOW="$2" FM_CI_STALL_GH="$1/bin/gh" FM_CI_STALL_SEND="$1/bin/send" \
    FM_CI_STALL_INFRA="$1/bin/infra" "$STALL" scan
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

test_queued_check_is_cancelled_then_rerun_once_and_recovers
test_cancelled_without_runner_is_rerun_at_once
test_stuck_again_is_diagnosed_and_handed_off_once
test_unreachable_worker_raises_a_blocker
test_running_bound_follows_the_usual_duration
test_counts_window_and_usage
