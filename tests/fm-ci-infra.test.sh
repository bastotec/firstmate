#!/usr/bin/env bash
# Behavior tests for bin/fm-ci-infra.sh: a check that never ran (billing,
# spending limit, no runner, zero steps) is infrastructure, anything else that
# failed is code, and classify reads a pull request's failed checks through gh.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CI="$ROOT/bin/fm-ci-infra.sh"
TMP_ROOT=$(fm_test_tmproot fm-ci-infra)
BILLING="The job was not started because recent account payments have failed or your spending limit needs to be increased. Please check the 'Billing & plans' section in your settings"
UBUNTU_NOTICE='"The ubuntu-latest label will migrate to Ubuntu 26 beginning October 19, 2026. For more information, see https://github.com/actions/runner-images/issues/14748"'

classify_json() {  # <json>; prints output, then "rc=<n>"
  local out rc=0
  out=$(printf '%s' "$1" | "$CI" classify-json -) || rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}

test_billing_annotation_is_infra() {
  local out
  out=$(classify_json "$(jq -cn --arg b "$BILLING" --arg n "$UBUNTU_NOTICE" \
    '{repo_private: true, checks: [{name: "verify", steps: 7, annotations: [
      {level: "failure", message: $b}, {level: "notice", message: $n}]}]}')")
  assert_contains "$out" "infra verify: The job was not started because recent account payments have failed" \
    "the billing annotation was not classified as infrastructure"
  assert_contains "$out" "verdict: infra" "the verdict was not infra"
  assert_contains "$out" "runs-on: [self-hosted, linux, workload]" "a private repository was not told to move to the workload runner"
  assert_contains "$out" "rc=0" "an all-infra result did not exit 0"
  pass "the GitHub billing annotation marks a failed check as infrastructure with the workload-runner fix"
}

test_other_never_ran_signals_are_infra() {
  local out
  out=$(classify_json '{"repo_private": false, "checks": [
    {"name": "silent", "steps": 0, "annotations": []},
    {"name": "limit", "steps": null, "annotations": ["You have reached your spending limit for Actions"]},
    {"name": "runner", "steps": null, "annotations": ["No runner matching the specified labels was found: gpu-xl"]}]}')
  assert_contains "$out" "infra silent: the job ran zero steps" "a zero-step job was not infrastructure"
  assert_contains "$out" "infra limit:" "a spending-limit annotation was not infrastructure"
  assert_contains "$out" "infra runner:" "a no-runner annotation was not infrastructure"
  assert_contains "$out" "fix: public repository - keep hosted runners" "a public repository was moved off hosted runners"
  pass "zero steps, a spending limit, and a missing runner are all infrastructure"
}

test_code_failures_stay_code() {
  local out
  out=$(classify_json "$(jq -cn --arg n "$UBUNTU_NOTICE" '{repo_private: true, checks: [
    {name: "unit", steps: 7, annotations: ["Process completed with exit code 1.", $n]},
    {name: "verify", steps: 0, annotations: []}]}')")
  assert_contains "$out" "code unit" "a failing test step was not a code failure"
  assert_contains "$out" "infra verify:" "the zero-step check lost its infra label"
  assert_contains "$out" "verdict: code" "one code failure did not make the verdict code"
  assert_contains "$out" "rc=1" "a code verdict did not exit 1"
  case "$out" in *"fix:"*) fail "a code verdict offered a runner fix: $out" ;; esac
  pass "a check that ran and failed stays a code failure, even beside an infra one and a runner notice"
}

test_annotation_levels_control_infra_evidence() {
  local out level
  for level in notice unknown; do
    out=$(classify_json "$(jq -cn --arg level "$level" '{repo_private: true, checks: [
      {name: "unit", steps: 7, annotations: [{level: $level, message: "Actions spending limit remaining: $20"}]}]}')")
    assert_contains "$out" "code unit" "$level was used as infrastructure evidence"
    assert_contains "$out" "verdict: code" "$level suppressed a code failure"
    assert_contains "$out" "rc=1" "$level did not preserve the code exit status"
  done
  out=$(classify_json '{"checks": [
    {"name": "warning", "steps": 7, "annotations": [{"level": "warning", "message": "No runner available"}]},
    {"name": "zero", "steps": 0, "annotations": [{"level": "notice", "message": "Actions spending limit remaining: $20"}]}]}')
  assert_contains "$out" "infra warning: No runner available" "warning-level evidence was ignored"
  assert_contains "$out" "infra zero: the job ran zero steps" "a notice overrode independent zero-step evidence"
  assert_contains "$out" "rc=0" "valid infrastructure evidence did not exit 0"
  pass "only failure and warning annotations count, independently of zero steps"
}

test_nothing_failed_and_bad_input() {
  local out rc=0
  out=$(classify_json '{"repo_private": true, "checks": []}')
  assert_contains "$out" "verdict: none" "no failed checks was not reported"
  assert_contains "$out" "rc=3" "no failed checks did not exit 3"
  printf 'not json' | "$CI" classify-json - >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "unreadable input was not refused"
  rc=0
  "$CI" classify https://example.com/not-a-pr >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a non-GitHub URL was not refused"
  pass "no failures and unreadable input have their own exit codes"
}

test_classify_reads_the_pull_request_through_gh() {
  local dir out rc=0
  dir="$TMP_ROOT/gh"
  mkdir -p "$dir/bin"
  jq -cn --arg b "$BILLING" '[{annotation_level: "failure", message: $b}]' > "$dir/billing.json"
  cat > "$dir/bin/gh" <<EOF
#!/usr/bin/env bash
args="\$*"
case "\$args" in
  *"repos/o/r/pulls/7 "*) echo abc123 ;;
  *"repos/o/r --jq"*) echo true ;;
  *"commits/abc123/check-runs"*) printf '901\tverify\tgithub-actions\n' ;;
  *"check-runs/901/annotations"*)
    [ "\${GH_FAIL_READ:-}" != annotations ] || exit 1
    jq -c --arg level "\${GH_ANNOTATION_LEVEL:-failure}" 'map(.annotation_level = \$level)' "$dir/billing.json" | jq -c "\${!#}"
    ;;
  *"actions/jobs/901"*)
    [ "\${GH_FAIL_READ:-}" != steps ] || exit 1
    echo "\${GH_JOB_STEPS:-0}"
    ;;
  *) echo "unexpected gh call: \$args" >&2; exit 1 ;;
esac
EOF
  chmod +x "$dir/bin/gh"
  out=$(PATH="$dir/bin:$PATH" "$CI" classify https://github.com/o/r/pull/7) || rc=$?
  assert_equals 0 "$rc" "classify did not report an all-infra pull request: $out"
  assert_contains "$out" "infra verify: The job was not started" "the pull request's billing failure was not read"
  assert_contains "$out" "runs-on: [self-hosted, linux, workload]" "the private repository fix was missing"
  rc=0
  out=$(PATH="$dir/bin:$PATH" GH_ANNOTATION_LEVEL=notice GH_JOB_STEPS=7 "$CI" classify https://github.com/o/r/pull/7) || rc=$?
  assert_equals 1 "$rc" "a fetched notice suppressed a code failure: $out"
  assert_contains "$out" "code verify" "annotation levels were not preserved through gh"
  pass "classify reads a pull request's failed checks, annotation levels and steps through gh"
}

test_unreadable_check_evidence_is_refused() {
  local out evidence rc
  for evidence in annotations steps; do
    rc=0
    out=$(PATH="$TMP_ROOT/gh/bin:$PATH" GH_FAIL_READ="$evidence" "$CI" classify https://github.com/o/r/pull/7 2>&1) || rc=$?
    assert_equals 2 "$rc" "unreadable $evidence did not exit 2: $out"
    assert_contains "$out" "error: unreadable" "unreadable $evidence did not explain the evidence failure"
    case "$out" in *"verdict:"*) fail "unreadable $evidence produced a verdict: $out" ;; esac
  done
  pass "unreadable annotations or job steps prevent classification"
}

test_billing_annotation_is_infra
test_other_never_ran_signals_are_infra
test_code_failures_stay_code
test_annotation_levels_control_infra_evidence
test_nothing_failed_and_bad_input
test_classify_reads_the_pull_request_through_gh
test_unreadable_check_evidence_is_refused
