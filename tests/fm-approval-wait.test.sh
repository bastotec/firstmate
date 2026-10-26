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
run_wait() { (cd "$dir" && FM_HOME="$dir/home" "$dir/bin/fm-approval-wait.sh" "$@"); }
normal_wait() { (unset NO_MISTAKES_GATE; FM_GATE_REFUSE_BYPASS=0 run_wait "$@"); }
validate_wait() {
  FM_HOME="$dir/home" bash -c '. "$1"; fm_approval_wait_validate "$2" subject' \
    _ "$dir/bin/fm-approval-wait.sh" "$dir/home/state"
}
rc=0
run_wait declare subject --key approval --expected-record "$meta" --instruction-file "$dir/instruction" >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" 'declaration must bind a currently open exact key'
assert_absent "$dir/home/state/subject.approval-wait" 'missing-key refusal published a wait'
printf 'blocked [key=approval]: Parent approval pending\n' >> "$dir/home/state/subject.status"
rc=0
run_wait declare subject --key approval --expected-record stale --instruction-file "$dir/instruction" >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" 'a stale metadata snapshot must refuse'
for marker in review ''; do
  rc=0
  FM_GATE_REFUSE_BYPASS=0 NO_MISTAKES_GATE="$marker" run_wait declare subject \
    --key approval --expected-record "$meta" --instruction-file "$dir/instruction" > "$dir/gate-declare.err" 2>&1 || rc=$?
  assert_equals 3 "$rc" 'gate context must refuse a valid declaration before mutation'
  assert_grep 'gate agent must not drive the fleet' "$dir/gate-declare.err" 'declaration must report the existing authority refusal'
  assert_absent "$dir/home/state/subject.approval-wait" 'gate declaration published an exclusion'
  assert_absent "$dir/home/state/.control-subject.lock" 'gate declaration acquired a lifecycle lock'
done
normal_wait declare subject --key approval --expected-record "$meta" --instruction-file "$dir/instruction" || fail 'bound declaration failed without the test bypass'
record=$(run_wait show subject) || fail 'show failed'
assert_equals approval "$(printf '%s' "$record" | jq -r .decision_key)" 'wrong key binding'
assert_equals subject "$(printf '%s' "$record" | jq -r .task)" 'wrong task binding'
assert_equals "$(cd "$dir/home" && pwd -P)" "$(printf '%s' "$record" | jq -r .home)" 'wrong owning-home binding'
digest=$(printf '%s' "$record" | jq -r .instruction_sha256)
assert_equals "$(shasum -a 256 "$dir/instruction" | cut -d' ' -f1)" "$digest" 'wrong instruction digest'
run_wait declare subject --key approval --expected-record "$meta" --instruction-file "$dir/instruction" || fail 'idempotent declaration failed'
assert_equals "$record" "$(run_wait show subject)" 'idempotent declaration replaced custody evidence'
validate_wait || fail 'intact prohibition did not validate'
rc=0
run_wait validate subject >/dev/null 2>&1 || rc=$?
assert_equals 2 "$rc" 'validation must not expose an extra public subcommand'
for field in schema task home metadata_sha256 instruction_sha256 instruction_file decision_key declared; do
  printf '%s\n' "$record" | jq --arg field "$field" '.[$field]="!invalid"' > "$dir/home/state/subject.approval-wait"
  rc=0
  validate_wait >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "invalid $field was trusted as an untimed prohibition"
done
printf '%s\n' "$record" > "$dir/home/state/subject.approval-wait"
printf 'spawn_gen=new\n' >> "$dir/home/state/subject.meta"
rc=0
validate_wait >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" 'new worker incarnation inherited untimed suppression'
printf '%s\n' "$meta" > "$dir/home/state/subject.meta"
printf 'changed instruction\n' >> "$dir/instruction"
rc=0
validate_wait >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" 'changed instruction was still trusted'
printf 'Parent prohibits recovery until explicit approval release.\n' > "$dir/instruction"
validate_wait || fail 'restored binding did not validate'
assert_equals "$record" "$(FM_GATE_REFUSE_BYPASS=0 NO_MISTAKES_GATE=review run_wait show subject)" 'gate read-only show must remain available'
for marker in review ''; do
  rc=0
  FM_GATE_REFUSE_BYPASS=0 NO_MISTAKES_GATE="$marker" run_wait release subject \
    --instruction-sha256 "$digest" --release-file "$dir/release" > "$dir/gate-release.err" 2>&1 || rc=$?
  assert_equals 3 "$rc" 'gate context must refuse release even with the exact digest'
  assert_grep 'gate agent must not drive the fleet' "$dir/gate-release.err" 'release must report the existing authority refusal'
  assert_equals "$record" "$(run_wait show subject)" 'gate release changed the protected record'
  assert_absent "$dir/home/state/approval-waits" 'gate release wrote an archive'
  assert_absent "$dir/home/state/.control-subject.lock" 'gate release acquired a lifecycle lock'
done
# The existing path backstop must still refuse when the environment marker is absent.
mkdir -p "$dir/.no-mistakes/repos"
git init -q "$dir/gate-seed"
git -C "$dir/gate-seed" -c user.name=Fixture -c user.email=fixture@example.invalid \
  commit -q --allow-empty -m fixture || fail 'gate fixture seed failed'
git clone -q --bare "$dir/gate-seed" "$dir/.no-mistakes/repos/approval.git" || fail 'gate fixture clone failed'
git --git-dir="$dir/.no-mistakes/repos/approval.git" worktree add -q --detach "$dir/gate-cwd" HEAD \
  || fail 'gate fixture worktree failed'
path_wait() {
  (cd "$dir/gate-cwd" && env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=0 \
    FM_HOME="$dir/home" "$dir/bin/fm-approval-wait.sh" "$@")
}
assert_equals "$record" "$(path_wait show subject)" 'gate path must retain read-only access'
for operation in declare release; do
  rc=0
  if [ "$operation" = declare ]; then
    path_wait declare subject --key approval --expected-record "$meta" \
      --instruction-file "$dir/instruction" > "$dir/gate-path.err" 2>&1 || rc=$?
  else
    path_wait release subject --instruction-sha256 "$digest" \
      --release-file "$dir/release" > "$dir/gate-path.err" 2>&1 || rc=$?
  fi
  assert_equals 3 "$rc" 'gate path must refuse mutation with the marker unset'
  assert_grep 'refusing fleet lifecycle from inside a no-mistakes gate worktree' "$dir/gate-path.err" 'wrong path authority refusal'
  assert_equals "$record" "$(run_wait show subject)" 'gate path mutation changed the protected record'
  assert_absent "$dir/home/state/approval-waits" 'gate path mutation archived a release'
  assert_absent "$dir/home/state/.control-subject.lock" 'gate path mutation acquired a lifecycle lock'
done
rc=0
run_wait release subject --instruction-sha256 "$(printf '%064d' 0)" --release-file "$dir/release" >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" 'a mismatched original instruction must not release'
mkdir -p "$dir/foreign/state"
cp "$dir/home/state/subject.approval-wait" "$dir/foreign/state/subject.approval-wait"
rc=0
FM_HOME="$dir/foreign" "$dir/bin/fm-approval-wait.sh" release subject \
  --instruction-sha256 "$digest" --release-file "$dir/release" >/dev/null 2>&1 || rc=$?
assert_equals 1 "$rc" 'another home must not release the copied disposition'
normal_wait release subject --instruction-sha256 "$digest" --release-file "$dir/release" || fail 'bound explicit release failed without the test bypass'
assert_absent "$dir/home/state/subject.approval-wait" 'release left the active exclusion'
assert_equals 1 "$(find "$dir/home/state/approval-waits" -type f | wc -l | tr -d ' ')" 'release was not archived exactly once'
archive=$(find "$dir/home/state/approval-waits" -type f)
assert_equals "$digest" "$(jq -r .instruction_sha256 "$archive")" 'release archive lost original custody'
assert_equals "$(shasum -a 256 "$dir/release" | cut -d' ' -f1)" "$(jq -r .release_sha256 "$archive")" 'release archive lost release evidence'
assert_equals "$meta" "$(cat "$dir/home/state/subject.meta")" 'disposition changed worker metadata'
assert_absent "$dir/home/state/.control-subject.lock" 'disposition leaked its lifecycle lock'
pass 'fm-approval-wait: exact open key, snapshot, home and instruction bindings; explicit audited release without worker mutation'
