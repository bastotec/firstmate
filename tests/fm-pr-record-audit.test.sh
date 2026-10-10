#!/usr/bin/env bash
# Behavior tests for the PR completion-claim gate outside teardown:
#   - bin/fm-tasks-axi.sh done refuses to close a row whose PR (its --pr, else
#     the row's own PR link) is open, closed without a recorded supersession,
#     or unreadable, and lets a merged or superseded one through;
#   - bin/fm-pr-record-audit.sh flags Done rows whose PR is open or closed
#     unmerged without a supersession reason, read-only.
# Each case runs in a scratch home with a stubbed gh that answers a PR's
# state from a per-case file; tests/fm-teardown.test.sh covers teardown's gate.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WRAPPER="$ROOT/bin/fm-tasks-axi.sh"
AUDIT="$ROOT/bin/fm-pr-record-audit.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-record-audit)

unset TASKS_AXI_FILE TASKS_AXI_BACKEND FM_HOME FM_ROOT_OVERRIDE \
  FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE

# A scratch home whose gh stub reads PR <n>'s state from states/<n>; a missing
# file makes the read fail like an offline or unauthenticated gh.
make_home() {  # <name>; prints the home
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/fakebin" "$home/states"
  printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  cat > "$home/fakebin/gh" <<SH
#!/usr/bin/env bash
[ "\${1:-} \${2:-}" = "pr view" ] || exit 1
n=\${3##*/}
[ -f "$home/states/\$n" ] || { echo "error: offline" >&2; exit 1; }
cat "$home/states/\$n"
SH
  chmod +x "$home/fakebin/gh"
  printf '%s\n' "$home"
}

in_home() {  # <home> <command...>
  local home=$1
  shift
  FM_HOME="$home" PATH="$home/fakebin:$PATH" "$@"
}

add_row() {  # <home> <id> <state: in_flight|done> [pr-number] [body]
  local home=$1 id=$2 state=$3 pr=${4:-} body=${5:-}
  tasks-axi add "$id" "fixture $id" --kind ship --file "$home/data/backlog.md" >/dev/null
  [ -z "$body" ] || tasks-axi update "$id" --body "$body" --file "$home/data/backlog.md" >/dev/null
  [ -z "$pr" ] || tasks-axi update "$id" --pr "https://github.com/example/repo/pull/$pr" \
    --file "$home/data/backlog.md" >/dev/null
  tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  [ "$state" = "done" ] && tasks-axi "done" "$id" --file "$home/data/backlog.md" >/dev/null
  return 0
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null | sed -n 's/^  state: *//p' | head -1
}

test_done_gate() {
  local home out rc
  home=$(make_home done-gate)
  printf 'OPEN\n' > "$home/states/1"
  printf 'CLOSED\n' > "$home/states/2"
  printf 'MERGED\n' > "$home/states/3"
  printf 'CLOSED\n' > "$home/states/4"
  add_row "$home" open-pr in_flight 1
  add_row "$home" closed-pr in_flight 2
  add_row "$home" merged-pr in_flight 3
  add_row "$home" superseded-pr in_flight 4 "Superseded: replaced by a smaller change"
  add_row "$home" offline-pr in_flight 5
  add_row "$home" flag-only in_flight

  out=$(in_home "$home" "$WRAPPER" "done" open-pr 2>&1); rc=$?
  expect_code 2 "$rc" "done on an open PR"
  assert_contains "$out" "is still open" "the open-PR refusal did not say so"
  [ "$(row_state "$home" open-pr)" = in_flight ] || fail "an open PR's row left review"

  out=$(in_home "$home" "$WRAPPER" "done" closed-pr 2>&1); rc=$?
  expect_code 2 "$rc" "done on a closed PR with no reason"
  assert_contains "$out" "Superseded: <reason>" "the closed-PR refusal did not name the supersession line"

  out=$(in_home "$home" "$WRAPPER" "done" offline-pr 2>&1); rc=$?
  expect_code 2 "$rc" "done on an unreadable PR"
  assert_contains "$out" "cannot read the live state" "the unreadable-PR refusal did not say so"

  out=$(in_home "$home" "$WRAPPER" "done" flag-only --pr https://github.com/example/repo/pull/1 2>&1); rc=$?
  expect_code 2 "$rc" "done --pr with an open PR"
  [ "$(row_state "$home" flag-only)" = in_flight ] || fail "a refused --pr close changed the row"

  out=$(in_home "$home" "$WRAPPER" "done" superseded-pr --pr https://github.com/example/repo/pull/4 2>&1); rc=$?
  expect_code 2 "$rc" "done --pr on a superseded PR"
  assert_contains "$out" "drop --pr" "the superseded --pr refusal did not explain itself"

  in_home "$home" "$WRAPPER" "done" merged-pr >/dev/null 2>&1 || fail "done refused a merged PR"
  [ "$(row_state "$home" merged-pr)" = "done" ] || fail "a merged PR's row did not close"
  in_home "$home" "$WRAPPER" "done" superseded-pr >/dev/null 2>&1 || fail "done refused a superseded PR"
  [ "$(row_state "$home" superseded-pr)" = "done" ] || fail "a superseded PR's row did not close"
  pass "fm-tasks-axi.sh done refuses an open, unexplained closed, or unreadable PR and passes merged or superseded"
}

test_audit_flags_mismatches_read_only() {
  local home out rc before
  home=$(make_home audit)
  printf 'OPEN\n' > "$home/states/1"
  printf 'MERGED\n' > "$home/states/2"
  printf 'CLOSED\n' > "$home/states/3"
  printf 'CLOSED\n' > "$home/states/4"
  add_row "$home" done-open "done" 1
  add_row "$home" done-merged "done" 2
  add_row "$home" done-closed "done" 3
  add_row "$home" done-superseded "done" 4 "Superseded: folded into done-merged"
  add_row "$home" review-open in_flight 1
  add_row "$home" no-pr "done"
  before=$(cat "$home/data/backlog.md")

  out=$(in_home "$home" "$AUDIT" 2>"$home/stderr"); rc=$?
  expect_code 0 "$rc" "audit with readable PRs"
  assert_equals "task done-closed is recorded done but PR https://github.com/example/repo/pull/3 was closed without merging - reconcile
task done-open is recorded done but PR https://github.com/example/repo/pull/1 is open - reconcile" \
    "$(printf '%s\n' "$out" | sort)" "the audit did not flag exactly the mismatched Done rows"
  assert_equals "$before" "$(cat "$home/data/backlog.md")" "the audit changed the backlog"

  rm "$home/states/2"
  out=$(in_home "$home" "$AUDIT" 2>"$home/stderr"); rc=$?
  expect_code 2 "$rc" "audit with an unreadable PR"
  assert_grep "task done-merged: cannot check PR https://github.com/example/repo/pull/2" "$home/stderr" \
    "the audit did not name the PR it could not read"
  assert_contains "$out" "done-open" "an unreadable PR stopped the audit from flagging the rest"
  pass "fm-pr-record-audit.sh flags Done rows with an open or unexplained closed PR and changes nothing"
}

if command -v tasks-axi >/dev/null 2>&1; then
  test_done_gate
  test_audit_flags_mismatches_read_only
else
  echo "skip: tasks-axi not found; PR completion-claim cases not run"
fi
