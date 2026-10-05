#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action, and for
# bin/fm-nm-trusted-test-skip.sh, which lets a Test step skipped by the trusted
# default-branch test.skip satisfy that action and nothing else.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=32d396ac0f29135daf7fcb9964aba9d5f4e796d6
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

SKIP_HELPER="$ROOT/bin/fm-nm-trusted-test-skip.sh"
SKIP_REASON='CI runs the full behavior suite on every PR; see .github/workflows/ci.yml'

write_trusted_config() {  # <path> <skip> <reason>
  printf 'test:\n  skip: %s\n  skip_reason: "%s"\n' "$2" "$3" > "$1"
}

attested_body() {  # <test-status-json-or-empty> <test-line>
  local steps='{"step":"review","status":"completed"}'
  [ -z "$1" ] || steps="$steps,{\"step\":\"test\",\"status\":\"$1\"}"
  steps="$steps,{\"step\":\"document\",\"status\":\"completed\"}"
  printf '%s\n<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"%s","steps":[%s]} -->\n## Pipeline\n<details>\n<summary>%s</summary>\n\n</details>\n' \
    "$SIGNATURE" "$NEW_SHA" "$steps" "$2"
}

# Runs the helper the way the workflow does, then the pinned verifier on its
# output. Prints the helper decision line followed by the verifier output.
run_checked() {  # <config> <body>
  local body_in="$TMP_ROOT/body-in.md" body_out="$TMP_ROOT/body-out.md" decision rc=0 out
  printf '%s' "$2" > "$body_in"
  decision=$("$SKIP_HELPER" "$1" "$body_in" "$body_out") \
    || fail "trusted-skip helper failed"$'\n'"$decision"
  printf '%s\n' "$decision"
  out=$(run_verifier "$(cat "$body_out")" "$NEW_SHA") || rc=$?
  printf '%s\nverifier_rc=%s\n' "$out" "$rc"
}

test_trusted_test_skip_satisfies_the_check() {
  local config="$TMP_ROOT/skip.yaml" output
  write_trusted_config "$config" true "$SKIP_REASON"
  output=$(run_checked "$config" "$(attested_body skipped "⏭️ **Test** - skipped: test.skip: $SKIP_REASON")")
  assert_contains "$output" "trusted-test-skip: accepted" "trusted skip was not accepted"
  assert_contains "$output" "verifier_rc=0" "verifier rejected a Test step skipped by trusted config"
  pass "a Test step skipped by trusted test.skip with its reason satisfies the check"
}

test_skip_without_trusted_config_still_fails() {
  local config="$TMP_ROOT/noskip.yaml" output
  printf 'test:\n  evidence:\n    store_in_repo: true\n' > "$config"
  output=$(run_checked "$config" "$(attested_body skipped "⏭️ **Test** - skipped: test.skip: $SKIP_REASON")")
  assert_contains "$output" "not configured" "helper did not report the missing trusted config"
  assert_contains "$output" "test (status=skipped)" "verifier did not name the skipped Test step"
  assert_not_contains "$output" "verifier_rc=0" "a skipped Test step passed without trusted config"
  rm -f "$TMP_ROOT/absent.yaml"
  output=$(run_checked "$TMP_ROOT/absent.yaml" "$(attested_body skipped "⏭️ **Test** - skipped: test.skip: $SKIP_REASON")")
  assert_not_contains "$output" "verifier_rc=0" "a skipped Test step passed with no trusted config file"
  pass "a skipped Test step still fails when the trusted config does not set test.skip"
}

test_skip_with_other_reason_still_fails() {
  local config="$TMP_ROOT/skip.yaml" output
  write_trusted_config "$config" true "$SKIP_REASON"
  output=$(run_checked "$config" "$(attested_body skipped "⏭️ **Test** - skipped: skipped by --skip")")
  assert_contains "$output" "refused" "helper accepted a skip that did not come from test.skip"
  assert_not_contains "$output" "verifier_rc=0" "a per-run Test skip passed the check"
  output=$(run_checked "$config" "$(attested_body skipped "⏭️ **Test** - skipped: test.skip: some older reason")")
  assert_not_contains "$output" "verifier_rc=0" "a Test skip with a stale reason passed the check"
  output=$(run_checked "$config" "$(attested_body skipped "⏭️ **Test** - skipped: test.skip: $SKIP_REASON and more")")
  assert_not_contains "$output" "verifier_rc=0" "a Test skip with an extended reason passed the check"
  write_trusted_config "$config" true ""
  output=$(run_checked "$config" "$(attested_body skipped "⏭️ **Test** - skipped: test.skip: ")")
  assert_not_contains "$output" "verifier_rc=0" "test.skip without a reason passed the check"
  pass "a Test skip whose reason is not the trusted test.skip reason still fails"
}

test_trusted_examples_do_not_override_the_first_test_summary() {
  local config="$TMP_ROOT/skip.yaml" output body example
  write_trusted_config "$config" true "$SKIP_REASON"
  for example in "\`\`\`html"$'\n'"<summary>⏭️ **Test** - skipped: test.skip: $SKIP_REASON</summary>"$'\n'"\`\`\`" \
    "> <summary>⏭️ **Test** - skipped: test.skip: $SKIP_REASON</summary>"; do
    body="$example"$'\n'"$(attested_body skipped '⏭️ **Test** - skipped: skipped by --skip')"
    output=$(run_checked "$config" "$body")
    assert_contains "$output" "refused" "a trusted example before the attestation was accepted"
    assert_not_contains "$output" "verifier_rc=0" "an earlier trusted example promoted a per-run skip"
    [ "$(cat "$TMP_ROOT/body-out.md")" = "$body" ] || fail "an earlier example changed the body"
  done
  body="$(attested_body skipped '⏭️ **Test** - skipped: test.skip: another reason')"$'\n'"<details>
<summary>⏭️ **Test** - skipped: test.skip: $SKIP_REASON</summary>
</details>"
  output=$(run_checked "$config" "$body")
  assert_contains "$output" "refused" "a later trusted Test summary was accepted"
  assert_not_contains "$output" "verifier_rc=0" "a later trusted summary promoted the first Test skip"
  [ "$(cat "$TMP_ROOT/body-out.md")" = "$body" ] || fail "a later summary changed the body"
  pass "only the first Test summary after the attestation can authorize a trusted skip"
}

test_test_summary_requires_exact_rendering() {
  local config="$TMP_ROOT/skip.yaml" output body line
  write_trusted_config "$config" true "$SKIP_REASON"
  for line in "⏭️ **Test** - skipped: test.skip: $SKIP_REASON<strong>extra</strong>" \
    "✅ **Test** - skipped: test.skip: $SKIP_REASON"; do
    body=$(attested_body skipped "$line")
    output=$(run_checked "$config" "$body")
    assert_contains "$output" "refused" "an inexact Test summary was accepted"
    assert_not_contains "$output" "verifier_rc=0" "an inexact Test summary passed the check"
    [ "$(cat "$TMP_ROOT/body-out.md")" = "$body" ] || fail "an inexact summary changed the body"
  done
  body=$(attested_body skipped "⏭️ **Test** - skipped: test.skip: $SKIP_REASON")
  body=${body/<summary>/$'  <summary>'}
  body=${body/<\/summary>/$'</summary>  '}
  output=$(run_checked "$config" "$body")
  assert_contains "$output" "verifier_rc=0" "surrounding whitespace prevented a trusted skip"
  printf '%s\n' 'test:' '  skip: true' '  skip_reason: "CI & <tests> \"quoted\""' > "$config"
  output=$(run_checked "$config" "$(attested_body skipped '⏭️ **Test** - skipped: test.skip: CI &amp; &lt;tests&gt; &#34;quoted&#34;')")
  assert_contains "$output" "trusted-test-skip: accepted" "HTML-escaped trusted reason was rejected"
  assert_contains "$output" "verifier_rc=0" "HTML-escaped trusted reason did not satisfy the check"
  pass "trusted skips require exact rendered summaries with HTML-escaped reasons"
}

test_failed_or_missing_test_still_fails_with_trusted_skip() {
  local config="$TMP_ROOT/skip.yaml" output
  write_trusted_config "$config" true "$SKIP_REASON"
  output=$(run_checked "$config" "$(attested_body failed "⏭️ **Test** - skipped: test.skip: $SKIP_REASON")")
  assert_contains "$output" "test (status=failed)" "verifier did not report the failed Test step"
  assert_not_contains "$output" "verifier_rc=0" "a failed Test step passed under trusted test.skip"
  output=$(run_checked "$config" "$(attested_body "" "⏭️ **Test** - skipped: test.skip: $SKIP_REASON")")
  assert_contains "$output" "test (missing)" "verifier did not report the missing Test step"
  assert_not_contains "$output" "verifier_rc=0" "a missing Test step passed under trusted test.skip"
  output=$(run_checked "$config" "$(attested_body running "⏳ **Test** - running")")
  assert_not_contains "$output" "verifier_rc=0" "an incomplete Test step passed under trusted test.skip"
  output=$(run_checked "$config" "$(attested_body completed "✅ **Test** - passed")")
  assert_contains "$output" "verifier_rc=0" "a completed Test step stopped passing under trusted test.skip"
  pass "failed, missing, and incomplete Test steps still fail under trusted test.skip"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails
test_trusted_test_skip_satisfies_the_check
test_skip_without_trusted_config_still_fails
test_skip_with_other_reason_still_fails
test_trusted_examples_do_not_override_the_first_test_summary
test_test_summary_requires_exact_rendering
test_failed_or_missing_test_still_fails_with_trusted_skip
