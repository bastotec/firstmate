#!/usr/bin/env bash
# Behavior tests for bin/fm-pr-unbind.sh, the guarded clear of a wrong pr=
# from a task's state/<id>.meta:
#   - the clear happens only when the live forge shows no open pull request for
#     the task's own fm/<task-id> branch, resolved from the task worktree's
#     github.com origin;
#   - the armed poll triple armed for that same URL is removed with it, each
#     artifact pinned to the bytes and identity the validated snapshot captured;
#   - every removal is asserted in state/pr-unbinds.log before anything is
#     removed, and a failed append refuses the whole clear;
#   - custom checks, foreign static checks, ambiguous partial poll state, unsafe
#     metadata, and a missing or non-GitHub worktree origin refuse with the meta
#     untouched, while validated interrupted poll removal is rerunnable;
#   - every other line of the meta survives the rewrite byte-for-byte.
# Each case runs in a scratch home whose gh stub answers `pr list` from a
# per-case file, with the poll armed through the real bin/fm-pr-check.sh so the
# artifacts under removal are the authentic ones.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

UNBIND="$ROOT/bin/fm-pr-unbind.sh"
PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-unbind)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

unset FM_HOME FM_ROOT_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE \
  FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

# A scratch home with a fixture worktree whose origin names a github.com
# repository, and a gh stub that answers the unbind's `pr list` guard from
# <home>/open-heads (one headRefName per line, empty file = no open PR) and
# fm-pr-check.sh's `pr view` head read with a fixed head.
make_home() {  # <name>; prints the home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/fakebin" "$home/wt"
  git -C "$home" init -q --bare "$home/bare.git" >/dev/null 2>&1
  git -C "$home/wt" init -q >/dev/null 2>&1
  git -C "$home/wt" remote add origin https://github.com/example/repo_name.git >/dev/null 2>&1
  : > "$home/open-heads"
  cat > "$home/fakebin/gh" <<SH
#!/usr/bin/env bash
case "\${1:-} \${2:-}" in
  "pr list")
    [ "\${FM_TEST_GH_LIST_FAIL:-0}" = 0 ] || exit 1
    if [ -n "\${FM_TEST_GH_LIST_ENTERED:-}" ]; then
      : > "\$FM_TEST_GH_LIST_ENTERED"
      deadline=\$((SECONDS + \${FM_TEST_STUB_MAX_BLOCK_SECONDS:-20}))
      while [ ! -e "\${FM_TEST_GH_LIST_RELEASE:-}" ] && [ "\$SECONDS" -lt "\$deadline" ]; do
        sleep 0.05
      done
      [ -e "\${FM_TEST_GH_LIST_RELEASE:-}" ] || exit 1
    fi
    cat "$home/open-heads"
    exit 0
    ;;
  "pr view")
    printf '%s\\n' "\${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}"
    exit 0
    ;;
esac
exit 1
SH
  chmod +x "$home/fakebin/gh"
  printf '%s\n' "$home"
}

run_unbind() {  # <home> <id> [extra-arg or env assignment...]
  local home=$1 id=$2
  shift 2
  env PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" "$@" "$UNBIND" "$id"
}

run_unbind_extra() {  # <home> <id> <extra-arg>
  local home=$1 id=$2 extra=$3
  env PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" \
    "$UNBIND" "$id" "$extra"
}

run_pr_check() {  # <home> <id> <url>
  local home=$1 id=$2 url=$3
  env PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" \
    FM_TEST_GUARD_LOG=/dev/null FM_TEST_GH_LOG=/dev/null \
    FM_TEST_GH_AXI_LOG=/dev/null FM_TEST_GLAB_LOG=/dev/null \
    "$PR_CHECK" "$id" "$url"
}

write_task_meta() {  # <home> <id>
  local home=$1 id=$2
  fm_write_meta "$home/state/$id.meta" \
    "window=fm-$id" \
    "backend=stream" \
    "worktree=$home/wt" \
    "project=$home/wt" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
}

meta_pr() {  # <meta-file>
  sed -n 's/^pr=//p' "$1" | tail -1
}

wait_for_file() {  # <path>
  local path=$1 attempts=0
  while [ ! -e "$path" ] && [ "$attempts" -lt 200 ]; do
    sleep 0.05
    attempts=$((attempts + 1))
  done
  [ -e "$path" ]
}

# The recorded meta with the poll armed for the given URL through the real
# arming command: the triple under removal is the authentic publication.
armed_home() {  # <name> <id> <url>
  local home id
  home=$(make_home "$1")
  id=$2
  write_task_meta "$home" "$id"
  run_pr_check "$home" "$id" "$3" >/dev/null 2>&1 \
    || fail "could not arm the fixture poll for $id"
  printf '%s\n' "$home"
}

test_happy_path_clears_pr_and_poll_and_logs() {
  local home id meta log out rc
  id=task-clear
  home=$(armed_home happy-path "$id" https://github.com/example/repo_name/pull/7)
  meta="$home/state/$id.meta"
  [ "$(meta_pr "$meta")" = https://github.com/example/repo_name/pull/7 ] \
    || fail "fixture did not record the PR URL"

  out=$(run_unbind "$home" "$id"); rc=$?
  expect_code 0 "$rc" "unbind on a clean forge"
  assert_contains "$out" "unbound: state/$id.meta" "success line did not name the meta"
  assert_absent "$home/state/$id.meta.pr" "meta grew a stray file"
  [ "$(meta_pr "$meta")" = "" ] || fail "pr= survived the clear"
  grep -q '^pr_head=' "$meta" && fail "pr_head= survived the clear"
  assert_absent "$home/state/$id.check.sh" "poll check survived the clear"
  assert_absent "$home/state/$id.pr-poll" "poll sidecar survived the clear"
  assert_absent "$home/state/$id.pr-poll-registration" "poll registration survived the clear"
  log="$home/state/pr-unbinds.log"
  assert_present "$log" "the unbind left no assertion log"
  [ "$(grep -c "asserted.$id.pr=https://github.com/example/repo_name/pull/7.by=" "$log")" = 1 ] \
    || fail "the assertion line did not record task, URL, and author: $(cat "$log")"
  grep -q '^window=fm-' "$meta" || fail "the rewrite dropped an unrelated line"
  grep -q '^kind=ship$' "$meta" || fail "the rewrite dropped an unrelated line"
  grep -q '^mode=no-mistakes$' "$meta" || fail "the rewrite dropped an unrelated line"
  grep -q '^worktree=' "$meta" || fail "the rewrite dropped the worktree line"
  pass "a guarded clear removes pr=, pr_head=, and the poll, and asserts first"
}

test_open_pr_for_own_branch_refuses() {
  local home id meta out rc
  id=task-live
  home=$(armed_home open-pr "$id" https://github.com/example/repo_name/pull/9)
  meta="$home/state/$id.meta"
  printf 'fm/%s\n' "$id" > "$home/open-heads"

  out=$(run_unbind "$home" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "unbind with an open PR for the task's own branch"
  assert_contains "$out" "open pull request exists" "the refusal did not name the live PR"
  [ "$(meta_pr "$meta")" = https://github.com/example/repo_name/pull/9 ] \
    || fail "a refused unbind cleared pr="
  assert_present "$home/state/$id.check.sh" "a refused unbind removed the poll"
  assert_absent "$home/state/pr-unbinds.log" "a refused unbind asserted"
  pass "an open pull request for the task's own branch refuses and preserves everything"
}

test_foreign_branch_head_does_not_block() {
  local home id meta out rc
  id=task-other
  home=$(armed_home other-head "$id" https://github.com/example/repo_name/pull/9)
  meta="$home/state/$id.meta"
  printf 'fm/someone-else\n' > "$home/open-heads"

  out=$(run_unbind "$home" "$id"); rc=$?
  expect_code 0 "$rc" "unbind with an open PR for a different branch"
  [ "$(meta_pr "$meta")" = "" ] || fail "a foreign head blocked the clear"
  assert_absent "$home/state/$id.check.sh" "a foreign head left the poll armed"
  pass "an open pull request for another branch does not block the clear"
}

test_meta_lock_blocks_stale_publication() {
  local home id meta entered release started acquired leak
  local unbind_pid publisher_pid unbind_rc publisher_rc acquired_early=0 attempts=0
  id=task-locked
  home=$(armed_home meta-lock "$id" https://github.com/example/repo_name/pull/12)
  meta="$home/state/$id.meta"
  entered="$home/forge-entered"
  release="$home/forge-release"
  started="$home/publisher-started"
  acquired="$home/publisher-acquired"
  leak="$home/stale-publication"

  run_unbind "$home" "$id" \
    FM_TEST_GH_LIST_ENTERED="$entered" FM_TEST_GH_LIST_RELEASE="$release" \
    >"$home/unbind.out" 2>"$home/unbind.err" &
  unbind_pid=$!
  if ! wait_for_file "$entered"; then
    : > "$release"
    kill "$unbind_pid" 2>/dev/null || true
    wait "$unbind_pid" 2>/dev/null || true
    fail "the lock fixture never reached the forge guard"
  fi

  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" bash -c '
    . "$1"
    : > "$3"
    lock=$(fm_meta_lock_path "$2") || exit 1
    fm_lock_acquire_wait "$lock" || exit 1
    : > "$4"
    if grep -q "^pr=" "$2"; then
      printf "stale\n" > "$5"
    fi
    fm_lock_release "$lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$meta" "$started" "$acquired" "$leak" &
  publisher_pid=$!
  if ! wait_for_file "$started"; then
    : > "$release"
    kill "$publisher_pid" "$unbind_pid" 2>/dev/null || true
    wait "$publisher_pid" 2>/dev/null || true
    wait "$unbind_pid" 2>/dev/null || true
    fail "the stale publisher fixture did not start"
  fi

  while [ "$attempts" -lt 20 ]; do
    if [ -e "$acquired" ]; then
      acquired_early=1
      break
    fi
    sleep 0.05
    attempts=$((attempts + 1))
  done
  : > "$release"
  wait "$unbind_pid"; unbind_rc=$?
  wait "$publisher_pid"; publisher_rc=$?

  expect_code 0 "$unbind_rc" "unbind while a stale publisher waits"
  expect_code 0 "$publisher_rc" "stale publisher after unbind"
  [ "$acquired_early" -eq 0 ] || fail "the metadata lock was released before the guarded rewrite"
  assert_absent "$leak" "a concurrent publisher observed the stale pr="
  [ "$(meta_pr "$meta")" = "" ] || fail "the guarded rewrite left pr="
  assert_absent "$home/state/$id.check.sh" "the guarded rewrite left the poll armed"
  pass "the metadata lock excludes stale publication through the guarded rewrite"
}

test_forge_read_failure_refuses() {
  local home id meta out rc
  id=task-offline
  home=$(armed_home forge-down "$id" https://github.com/example/repo_name/pull/3)
  meta="$home/state/$id.meta"

  out=$(run_unbind "$home" "$id" FM_TEST_GH_LIST_FAIL=1 2>&1); rc=$?
  expect_code 1 "$rc" "unbind with an unreadable forge"
  assert_contains "$out" "could not read the forge" "the refusal did not name the forge read"
  [ "$(meta_pr "$meta")" = https://github.com/example/repo_name/pull/3 ] \
    || fail "an offline forge cleared pr="
  assert_present "$home/state/$id.check.sh" "an offline forge removed the poll"
  assert_absent "$home/state/pr-unbinds.log" "an offline forge asserted"
  pass "an unreadable forge refuses with no side effects"
}

test_missing_gh_refuses_before_any_change() {
  local home id meta path out rc
  id=task-nogh
  home=$(armed_home no-gh "$id" https://github.com/example/repo_name/pull/3)
  meta="$home/state/$id.meta"
  path=$(fm_test_base_path_sans "$BASE_PATH" gh)

  out=$(env PATH="$home/fakebin-only:$path" FM_HOME="$home" \
    FM_TEST_GH_LIST_FAIL=0 bash -c 'command -v gh >/dev/null && echo present || echo absent'); rc=$?
  [ "$out" = absent ] || fail "the gh-free fixture still resolved gh"

  rm -f "$home/fakebin/gh"
  out=$(env PATH="$path" FM_HOME="$home" "$UNBIND" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "unbind with gh missing from PATH"
  assert_contains "$out" "requires gh" "the refusal did not name gh"
  [ "$(meta_pr "$meta")" = https://github.com/example/repo_name/pull/3 ] \
    || fail "a missing gh cleared pr="
  assert_present "$home/state/$id.check.sh" "a missing gh removed the poll"
  assert_absent "$home/state/pr-unbinds.log" "a missing gh asserted"
  pass "a missing gh refuses before any change"
}

test_no_pr_meta_refuses() {
  local home id out rc
  id=task-bare
  home=$(make_home no-pr)
  write_task_meta "$home" "$id"

  out=$(run_unbind "$home" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "unbind with no pr= recorded"
  assert_contains "$out" "no single valid pr=" "the refusal did not name the missing pr="
  assert_present "$home/state/$id.meta" "a missing pr= deleted the meta"
  pass "a meta with no pr= refuses"
}

test_non_github_origin_refuses() {
  local home id meta out rc
  id=task-gitlab
  home=$(armed_home gitlab-origin "$id" https://github.com/example/repo_name/pull/4)
  meta="$home/state/$id.meta"
  git -C "$home/wt" remote set-url origin git@gitlab.com:example/repo_name.git >/dev/null 2>&1
  rm -f "$home/fakebin/gh"

  out=$(run_unbind "$home" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "unbind with a non-GitHub worktree origin"
  assert_contains "$out" "PR unbind supports github.com origins only" \
    "the refusal did not name the GitHub-only limitation"
  [ "$(meta_pr "$meta")" = https://github.com/example/repo_name/pull/4 ] \
    || fail "a non-GitHub origin cleared pr="
  assert_present "$home/state/$id.check.sh" "a non-GitHub origin removed the poll"
  pass "a non-GitHub worktree origin refuses"
}

test_missing_worktree_refuses() {
  local home id meta out rc
  id=task-nowt
  home=$(armed_home no-worktree "$id" https://github.com/example/repo_name/pull/4)
  meta="$home/state/$id.meta"
  rm -rf "$home/wt"

  out=$(run_unbind "$home" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "unbind with no worktree"
  assert_contains "$out" "no usable origin" "the refusal did not name the missing origin"
  [ "$(meta_pr "$meta")" = https://github.com/example/repo_name/pull/4 ] \
    || fail "a missing worktree cleared pr="
  pass "a missing worktree refuses"
}

test_poll_mismatch_refuses() {
  local home id meta data out rc
  id=task-mismatch
  home=$(armed_home poll-mismatch "$id" https://github.com/example/repo_name/pull/5)
  meta="$home/state/$id.meta"
  data="$home/state/$id.pr-poll"
  printf 'github\nhttps://github.com/example/repo_name/pull/6\ngithub.com\nexample/repo_name\n6\n' > "$data"
  chmod 0600 "$data"

  out=$(run_unbind "$home" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "unbind with a poll armed for another PR"
  assert_contains "$out" "does not validate" "the refusal did not name the mismatch"
  [ "$(meta_pr "$meta")" = https://github.com/example/repo_name/pull/5 ] \
    || fail "a mismatched poll cleared pr="
  assert_present "$home/state/$id.check.sh" "a mismatched poll removed its check"
  assert_present "$data" "a mismatched poll removed its sidecar"
  assert_absent "$home/state/pr-unbinds.log" "a mismatched poll asserted"
  pass "a poll armed for another PR refuses"
}

test_custom_check_is_left_alone() {
  local home id meta out rc
  id=task-custom
  home=$(make_home custom-check)
  write_task_meta "$home" "$id"
  printf '#!/usr/bin/env bash\nprintf target\n' > "$home/state/$id.check.sh"
  chmod 0700 "$home/state/$id.check.sh"
  FM_HOME="$home" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
    || fail "could not register the custom check"
  printf 'pr=https://github.com/example/repo_name/pull/8\n' >> "$home/state/$id.meta"
  chmod 0600 "$home/state/$id.meta"

  out=$(run_unbind "$home" "$id"); rc=$?
  expect_code 0 "$rc" "unbind beside a custom check"
  [ "$(meta_pr "$home/state/$id.meta")" = "" ] || fail "the clear skipped a custom-check task"
  assert_present "$home/state/$id.check.sh" "the clear removed a custom check"
  assert_present "$home/state/$id.check-trust" "the clear removed a custom check trust"
  pass "a custom check is not a PR poll and survives the clear"
}

test_foreign_static_check_refuses() {
  local home id meta out rc
  id=task-foreign
  home=$(make_home foreign-check)
  write_task_meta "$home" "$id"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$home/state/$id.check.sh"
  chmod 0600 "$home/state/$id.check.sh"
  printf 'pr=https://github.com/example/repo_name/pull/8\n' >> "$home/state/$id.meta"
  chmod 0600 "$home/state/$id.meta"

  out=$(run_unbind "$home" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "unbind with a foreign static check"
  assert_contains "$out" "not a PR poll or a custom check" "the refusal did not name the foreign check"
  [ "$(meta_pr "$home/state/$id.meta")" = https://github.com/example/repo_name/pull/8 ] \
    || fail "a foreign check cleared pr="
  assert_present "$home/state/$id.check.sh" "a foreign check was removed"
  pass "a foreign static check refuses"
}

test_interrupted_poll_removal_is_rerunnable() {
  local home id meta out rc remainder
  for remainder in sidecars registration data; do
    id="task-resume-$remainder"
    home=$(armed_home "resume-$remainder" "$id" https://github.com/example/repo_name/pull/5)
    meta="$home/state/$id.meta"
    rm -f "$home/state/$id.check.sh"
    case "$remainder" in
      registration) rm -f "$home/state/$id.pr-poll" ;;
      data) rm -f "$home/state/$id.pr-poll-registration" ;;
    esac

    out=$(run_unbind "$home" "$id"); rc=$?
    expect_code 0 "$rc" "rerun after poll removal stopped with $remainder remaining"
    assert_contains "$out" "unbound: state/$id.meta" "the resumed unbind did not report success"
    [ "$(meta_pr "$meta")" = "" ] || fail "the resumed unbind left pr= with $remainder remaining"
    assert_absent "$home/state/$id.check.sh" "the resumed unbind restored a poll check"
    assert_absent "$home/state/$id.pr-poll" "the resumed unbind left poll data"
    assert_absent "$home/state/$id.pr-poll-registration" "the resumed unbind left poll registration"
  done
  pass "an interrupted poll-artifact removal is idempotent and rerunnable"
}

test_ambiguous_interrupted_poll_refuses() {
  local home id meta data out rc
  id=task-torn
  home=$(armed_home torn-poll "$id" https://github.com/example/repo_name/pull/5)
  meta="$home/state/$id.meta"
  data="$home/state/$id.pr-poll"
  rm -f "$home/state/$id.check.sh"
  printf 'github\nhttps://github.com/example/repo_name/pull/6\ngithub.com\nexample/repo_name\n6\n' > "$data"
  chmod 0600 "$data"

  out=$(run_unbind "$home" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "unbind with ambiguous remaining poll sidecars"
  assert_contains "$out" "ambiguous" "the refusal did not name the ambiguous state"
  [ "$(meta_pr "$meta")" = https://github.com/example/repo_name/pull/5 ] \
    || fail "ambiguous poll state cleared pr="
  assert_present "$data" "ambiguous poll state removed its sidecar"
  assert_present "$home/state/$id.pr-poll-registration" "ambiguous poll state removed its registration"
  assert_absent "$home/state/pr-unbinds.log" "ambiguous poll state was logged as an unbind"
  pass "ambiguous interrupted poll state refuses"
}

test_unsafe_meta_refuses() {
  local home id out rc
  id=task-unsafe
  home=$(make_home unsafe-meta)
  write_task_meta "$home" "$id"
  mv "$home/state/$id.meta" "$home/outside.meta"
  ln -s "$home/outside.meta" "$home/state/$id.meta"

  out=$(run_unbind "$home" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "unbind on a symlinked meta"
  assert_contains "$out" "task metadata is unavailable" "the refusal did not name the meta"
  assert_present "$home/state/$id.meta" "a symlink refusal removed the symlink"
  assert_present "$home/outside.meta" "a symlink refusal removed the target"
  pass "a symlinked meta refuses"
}

test_failed_log_append_refuses_before_removal() {
  local home id meta out rc
  id=task-logfail
  home=$(armed_home log-fail "$id" https://github.com/example/repo_name/pull/6)
  meta="$home/state/$id.meta"
  mkdir "$home/state/pr-unbinds.log"

  out=$(run_unbind "$home" "$id" 2>&1); rc=$?
  expect_code 1 "$rc" "unbind whose assertion cannot be appended"
  assert_contains "$out" "could not be registered" "the refusal did not name the log"
  [ "$(meta_pr "$meta")" = https://github.com/example/repo_name/pull/6 ] \
    || fail "an unloggable unbind cleared pr="
  assert_present "$home/state/$id.check.sh" "an unloggable unbind removed the poll"
  pass "a failed assertion append refuses before any removal"
}

test_invalid_usage_exits_2() {
  local home out rc
  home=$(make_home usage)
  write_task_meta "$home" task-usage
  out=$(run_unbind_extra "$home" task-usage extra-arg 2>&1); rc=$?
  expect_code 2 "$rc" "unbind with two arguments"
  assert_contains "$out" "error:" "the usage refusal had no stderr"
  out=$(run_unbind "$home" '../escape' 2>&1); rc=$?
  expect_code 2 "$rc" "unbind with a path-escaping id"
  out=$(run_unbind "$home" '' 2>&1); rc=$?
  expect_code 2 "$rc" "unbind with an empty id"
  out=$(env PATH="$home/fakebin:$BASE_PATH" FM_HOME="$home" FM_STATE_OVERRIDE= \
    "$UNBIND" task-usage 2>&1); rc=$?
  expect_code 1 "$rc" "unbind with an explicitly empty state override"
  assert_contains "$out" "state directory is unavailable" "the empty-override refusal was wrong"
  pass "invalid usage exits 2 and an empty state override refuses"
}

test_retirement_receipt_is_finished_first() {
  local home id meta receipt out rc
  id=task-retired
  home=$(armed_home retired "$id" https://github.com/example/repo_name/pull/11)
  meta="$home/state/$id.meta"
  receipt="$home/state/$id.pr-poll-retirement"
  # shellcheck source=bin/fm-pr-lib.sh disable=SC1091
  . "$ROOT/bin/fm-pr-lib.sh"
  fm_pr_poll_snapshot_capture "$home/state" "$id" "$ROOT/bin/fm-pr-poll.sh" \
    || fail "could not capture the poll snapshot for the receipt"
  fm_pr_poll_retirement_publish "$home/state" "$id" "$ROOT/bin/fm-pr-poll.sh" merged \
    || fail "could not publish the retirement receipt"
  assert_present "$receipt" "the fixture published no receipt"
  rm -f "$home/state/$id.check.sh"

  out=$(run_unbind "$home" "$id"); rc=$?
  expect_code 0 "$rc" "unbind with a pending retirement receipt"
  [ "$(meta_pr "$meta")" = "" ] || fail "the receipt path cleared no pr="
  assert_absent "$receipt" "the receipt survived its recovery"
  assert_absent "$home/state/$id.check.sh" "the receipt path left the poll armed"
  assert_absent "$home/state/$id.pr-poll" "the receipt path left the sidecar"
  pass "a pending merge-retirement receipt is finished before the clear"
}

test_happy_path_clears_pr_and_poll_and_logs
test_open_pr_for_own_branch_refuses
test_foreign_branch_head_does_not_block
test_meta_lock_blocks_stale_publication
test_forge_read_failure_refuses
test_missing_gh_refuses_before_any_change
test_no_pr_meta_refuses
test_non_github_origin_refuses
test_missing_worktree_refuses
test_poll_mismatch_refuses
test_custom_check_is_left_alone
test_foreign_static_check_refuses
test_interrupted_poll_removal_is_rerunnable
test_ambiguous_interrupted_poll_refuses
test_unsafe_meta_refuses
test_failed_log_append_refuses_before_removal
test_invalid_usage_exits_2
test_retirement_receipt_is_finished_first
