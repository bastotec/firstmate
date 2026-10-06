#!/usr/bin/env bash
# fm-remote-entrypoint.sh installs as a PATH symlink under ~/.local/bin
# (docs/remote-secondmates.md). SCRIPT_DIR must resolve to the real bin/
# directory so it can source its sibling fm-remote-job-lib.sh, not to the
# symlink's own directory.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-remote-entrypoint)
REAL_BIN="$TMP_ROOT/real-root/bin"
LOCAL_BIN="$TMP_ROOT/local-bin"
mkdir -p "$REAL_BIN" "$LOCAL_BIN"
cp "$ROOT/bin/fm-remote-entrypoint.sh" "$ROOT/bin/fm-remote-job-lib.sh" "$REAL_BIN/"
chmod +x "$REAL_BIN/fm-remote-entrypoint.sh"
ln -s "$REAL_BIN/fm-remote-entrypoint.sh" "$LOCAL_BIN/fm-remote-entrypoint.sh"

run_entrypoint() { # <path> <stdout-file> <stderr-file>
  local path=$1 out=$2 err=$3 code
  "$path" >"$out" 2>"$err"
  code=$?
  printf '%s' "$code"
}

test_symlink_invocation_resolves_sibling_lib() {
  local out err code
  out="$TMP_ROOT/symlink.stdout"
  err="$TMP_ROOT/symlink.stderr"
  code=$(run_entrypoint "$LOCAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  # A wrong SCRIPT_DIR fails while sourcing the sibling lib, before argv is
  # even checked, with a "No such file or directory" source error and exit 1.
  # Reaching the die() for missing protocol args proves the sibling lib
  # sourced from the real bin/, not from the symlink's own directory.
  assert_no_grep 'No such file or directory' "$err" \
    "invoking fm-remote-entrypoint.sh through a symlink failed to source its sibling lib"
  expect_code 64 "$code" "symlink invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "symlink invocation did not reach argument validation past sibling-lib sourcing"
  pass "fm-remote-entrypoint.sh invoked via a PATH symlink resolves SCRIPT_DIR to the real bin/ directory"
}

test_direct_invocation_still_works() {
  # Control: the same real script invoked directly (no symlink) must behave
  # identically, so the symlink coverage above is proven by contrast.
  local out err code
  out="$TMP_ROOT/direct.stdout"
  err="$TMP_ROOT/direct.stderr"
  code=$(run_entrypoint "$REAL_BIN/fm-remote-entrypoint.sh" "$out" "$err")

  expect_code 64 "$code" "direct invocation exit code"
  assert_grep 'remote entrypoint expects protocol, root, home, and argv' "$err" \
    "direct invocation did not reach argument validation"
  pass "fm-remote-entrypoint.sh invoked directly still resolves SCRIPT_DIR correctly"
}

test_symlink_invocation_resolves_sibling_lib
test_direct_invocation_still_works

NO_GIT_BIN="$TMP_ROOT/no-git-bin"
DOCTOR_HOME="$TMP_ROOT/doctor-home"
mkdir -p "$NO_GIT_BIN" "$DOCTOR_HOME"
printf 'fixture\n' > "$TMP_ROOT/real-root/AGENTS.md"
cp "$ROOT/bin/fm-remote-doctor.sh" "$ROOT/bin/fm-tasks-axi-lib.sh" \
  "$ROOT/bin/fm-remote-herdr-owner-lib.sh" "$ROOT/bin/fm-tool-version-lib.sh" "$REAL_BIN/"
for tool in bash dirname mktemp python3 base64 wc tr ps shasum realpath id uname sed cat readlink cmp rm sleep grep awk stat find head cut sort tail ls date; do
  resolved=$(command -v "$tool" 2>/dev/null) || continue
  ln -s "$resolved" "$NO_GIT_BIN/$tool"
done
cat >> "$REAL_BIN/fm-remote-job-lib.sh" <<SH
fm_remote_job_compose_operator_path() { FM_REMOTE_JOB_OPERATOR_PATH='$NO_GIT_BIN'; }
fm_remote_job_operator_tool() { PATH='$NO_GIT_BIN' command -v "\$1"; }
fm_remote_job_build_child_path() { FM_REMOTE_JOB_CHILD_PATH='$REAL_BIN:$NO_GIT_BIN'; }
SH
root_b64=$(printf '%s' "$TMP_ROOT/real-root" | base64 | tr -d '\n')
home_b64=$(printf '%s' "$DOCTOR_HOME" | base64 | tr -d '\n')
argv_b64=$(printf '%s\0' fm-remote-doctor.sh | base64 | tr -d '\n')
code=0
FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/doctor-jobs" \
  "$LOCAL_BIN/fm-remote-entrypoint.sh" 1 "$root_b64" "$home_b64" "$argv_b64" \
  > "$TMP_ROOT/doctor.stdout" 2> "$TMP_ROOT/doctor.stderr" || code=$?
expect_code 1 "$code" "missing-git bootstrap must run the doctor and report readiness gaps"
assert_grep 'required git=MISSING' "$TMP_ROOT/doctor.stdout" \
  "the trusted doctor did not report missing git: $(cat "$TMP_ROOT/doctor.stdout" "$TMP_ROOT/doctor.stderr")"
assert_no_grep 'trusted bootstrap identity' "$TMP_ROOT/doctor.stderr" "the current doctor failed bootstrap trust"
assert_absent "$TMP_ROOT/doctor-jobs/jobs" "the doctor bootstrap staged a worker job"
pass "the current trusted doctor executes and reports missing git without a job worker"

printf '\n' >> "$REAL_BIN/fm-remote-doctor.sh"
code=0
FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux FM_REMOTE_JOB_STATE_ROOT="$TMP_ROOT/doctor-jobs" \
  "$LOCAL_BIN/fm-remote-entrypoint.sh" 1 "$root_b64" "$home_b64" "$argv_b64" \
  > "$TMP_ROOT/tampered.stdout" 2> "$TMP_ROOT/tampered.stderr" || code=$?
expect_code 64 "$code" "an altered doctor must fail the missing-git trust check"
assert_grep 'does not match the trusted bootstrap identity' "$TMP_ROOT/tampered.stderr" "altered doctor was not refused by byte identity"
assert_no_grep 'required git=' "$TMP_ROOT/tampered.stdout" "the altered doctor ran despite failed trust"
pass "the missing-git bootstrap refuses a doctor outside the trusted byte contract"
