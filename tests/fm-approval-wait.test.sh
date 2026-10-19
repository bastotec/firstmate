#!/usr/bin/env bash
# Parent approval disposition binding, refusal and release through the real CLI.
set -u
# shellcheck source=tests/fm-idle-sweep.test.sh
FM_IDLE_SWEEP_TEST_SKIP_RUN=1 . "$(dirname "${BASH_SOURCE[0]}")/fm-idle-sweep.test.sh"

dir=$(new_case approval-binding)
add_worker "$dir" subject 'state: blocked · source: status-log · waiting' 90000
printf 'Parent prohibits recovery until explicit approval release.\n' > "$dir/instruction"
printf 'Parent explicitly releases the approval exclusion.\n' > "$dir/release"
meta=$(cat "$dir/home/state/subject.meta")
run_wait() { FM_HOME="$dir/home" "$dir/bin/fm-approval-wait.sh" "$@"; }
rc=0
run_wait declare subject --key approval --expected-record "$meta" --instruction-file "$dir/instruction" >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" 'declaration must bind a currently open exact key'
assert_absent "$dir/home/state/subject.approval-wait" 'missing-key refusal published a wait'
printf 'blocked [key=approval]: Parent approval pending\n' >> "$dir/home/state/subject.status"
rc=0
run_wait declare subject --key approval --expected-record stale --instruction-file "$dir/instruction" >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" 'a stale metadata snapshot must refuse'
run_wait declare subject --key approval --expected-record "$meta" --instruction-file "$dir/instruction" || fail 'bound declaration failed'
record=$(run_wait show subject) || fail 'show failed'
assert_equals approval "$(printf '%s' "$record" | jq -r .decision_key)" 'wrong key binding'
assert_equals subject "$(printf '%s' "$record" | jq -r .task)" 'wrong task binding'
assert_equals "$(cd "$dir/home" && pwd -P)" "$(printf '%s' "$record" | jq -r .home)" 'wrong owning-home binding'
digest=$(printf '%s' "$record" | jq -r .instruction_sha256)
assert_equals "$(shasum -a 256 "$dir/instruction" | cut -d' ' -f1)" "$digest" 'wrong instruction digest'
run_wait declare subject --key approval --expected-record "$meta" --instruction-file "$dir/instruction" || fail 'idempotent declaration failed'
assert_equals "$record" "$(run_wait show subject)" 'idempotent declaration replaced custody evidence'
rc=0
run_wait release subject --instruction-sha256 "$(printf '%064d' 0)" --release-file "$dir/release" >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" 'a mismatched original instruction must not release'
mkdir -p "$dir/foreign/state"
cp "$dir/home/state/subject.approval-wait" "$dir/foreign/state/subject.approval-wait"
rc=0
FM_HOME="$dir/foreign" "$dir/bin/fm-approval-wait.sh" release subject \
  --instruction-sha256 "$digest" --release-file "$dir/release" >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" 'another home must not release the copied disposition'
run_wait release subject --instruction-sha256 "$digest" --release-file "$dir/release" || fail 'bound explicit release failed'
assert_absent "$dir/home/state/subject.approval-wait" 'release left the active exclusion'
assert_equals 1 "$(find "$dir/home/state/approval-waits" -type f | wc -l | tr -d ' ')" 'release was not archived exactly once'
archive=$(find "$dir/home/state/approval-waits" -type f)
assert_equals "$digest" "$(jq -r .instruction_sha256 "$archive")" 'release archive lost original custody'
assert_equals "$(shasum -a 256 "$dir/release" | cut -d' ' -f1)" "$(jq -r .release_sha256 "$archive")" 'release archive lost release evidence'
assert_equals "$meta" "$(cat "$dir/home/state/subject.meta")" 'disposition changed worker metadata'
assert_absent "$dir/home/state/.control-subject.lock" 'disposition leaked its lifecycle lock'
pass 'fm-approval-wait: exact open key, snapshot, home and instruction bindings; explicit audited release without worker mutation'
