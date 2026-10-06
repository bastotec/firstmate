#!/usr/bin/env bash
# tests/fm-endpoint-rebind-lib.test.sh - fm_endpoint_rebind_meta moves a task
# record to a new endpoint, keeping every task line, and refuses anything that
# would bind the wrong task or smuggle non-endpoint lines.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-endpoint-rebind-tests)
trap fm_test_cleanup EXIT INT TERM

rebind() {  # <state-dir> <args...>
  local state=$1
  shift
  FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-backend.sh"
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-endpoint-rebind-lib.sh"
    shift
    if [ "${FM_TEST_FAIL_REPLACE:-0}" = 1 ]; then
      mv() { return 1; }
    fi
    fm_endpoint_rebind_meta "$@" || { echo "refused: $FM_ENDPOINT_REBIND_ERROR"; exit 1; }
  ' _ "$ROOT" "$@"
}

test_rebind_replaces_every_endpoint_line_and_keeps_the_task() {
  local state="$TMP_ROOT/move" meta out
  mkdir -p "$state"
  meta="$state/t1.meta"
  fm_write_meta "$meta" "window=fm-remote:w1:p2" "endpoint_task_id=t1" "worktree=/w/t1" \
    "harness=deck" "kind=ship" "backend=herdr" "herdr_session=fm-remote" "herdr_pane_id=w1:p2" \
    "spawn_gen=3" "pr=https://example.invalid/pr/1"
  out=$(rebind "$state" "$meta" t1 stream "hub-7717:abcdef" "stream_hub=http://hub:7717" "stream_endpoint_id=abcdef") \
    || fail "rebind refused a valid move: $out"
  assert_equals "endpoint_task_id=t1
worktree=/w/t1
harness=deck
kind=ship
spawn_gen=3
pr=https://example.invalid/pr/1
window=hub-7717:abcdef
backend=stream
stream_hub=http://hub:7717
stream_endpoint_id=abcdef" "$(cat "$meta")" "the record should name only the new endpoint and keep every task line in order"
  [ ! -e "$state/.meta-t1.lock" ] || fail "the meta lock was left behind"
  pass "fm_endpoint_rebind_meta: drops the old backend's identity lines, appends the new endpoint, keeps the task"
}

test_rebind_refuses_and_leaves_the_record_alone() {
  local state="$TMP_ROOT/refuse" meta before out rc args
  mkdir -p "$state"
  meta="$state/t2.meta"
  fm_write_meta "$meta" "window=s:fm-t2" "endpoint_task_id=t2" "kind=ship"
  before=$(cat "$meta")
  for args in \
    "t9|stream|hub:ab|stream_endpoint_id=ab|not bound to task t9" \
    "t2|warp|hub:ab|stream_endpoint_id=ab|unknown backend" \
    "t2|stream||stream_endpoint_id=ab|empty or malformed" \
    "t2|stream|hub:ab|worktree=/elsewhere|not an endpoint identity line" \
    "t2|stream|hub:ab|backend=tmux|not an endpoint identity line"; do
    IFS='|' read -r id backend window extra why <<EOF
$args
EOF
    out=$(rebind "$state" "$meta" "$id" "$backend" "$window" "$extra"); rc=$?
    expect_code 1 "$rc" "rebind should refuse ($why)"
    assert_contains "$out" "$why" "the refusal should say why"
    assert_equals "$before" "$(cat "$meta")" "a refused rebind changed the record ($why)"
  done
  pass "fm_endpoint_rebind_meta: a foreign task, unknown backend, empty window, or non-endpoint line refuses with the record untouched"
}

test_rebind_replace_failure_preserves_the_record_and_releases_the_lock() {
  local state="$TMP_ROOT/replace-failure" meta before out rc
  mkdir -p "$state"
  meta="$state/t3.meta"
  fm_write_meta "$meta" "window=hub:old" "endpoint_task_id=t3" "backend=stream"
  before=$(cat "$meta")
  out=$(FM_TEST_FAIL_REPLACE=1 rebind "$state" "$meta" t3 stream "hub:new" "stream_endpoint_id=new"); rc=$?
  expect_code 1 "$rc" "a failed atomic replacement must refuse"
  assert_contains "$out" "$meta could not be rewritten" "the failure should expose the rewrite error"
  assert_equals "$before" "$(cat "$meta")" "a failed replacement must preserve the persisted task record"
  [ ! -e "$state/.meta-t3.lock" ] || fail "a failed replacement left the meta lock behind"
  out=$(rebind "$state" "$meta" t3 stream "hub:new" "stream_endpoint_id=new") \
    || fail "a retry after a failed replacement should succeed: $out"
  assert_equals "endpoint_task_id=t3
window=hub:new
backend=stream
stream_endpoint_id=new" "$(cat "$meta")" "the retry must publish the new endpoint in the persisted record"
  pass "fm_endpoint_rebind_meta: replacement failure reports an error, preserves the task, releases the lock, and permits retry"
}

test_rebind_replaces_every_endpoint_line_and_keeps_the_task
test_rebind_refuses_and_leaves_the_record_alone
test_rebind_replace_failure_preserves_the_record_and_releases_the_lock
