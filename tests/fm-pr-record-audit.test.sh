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
  local home=$1 id=$2 state=$3 pr=${4:-} body=${5:-} title=${6:-fixture $2}
  tasks-axi add "$id" "$title" --kind ship --file "$home/data/backlog.md" >/dev/null
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

test_metadata_and_read_failure_gates() {
  local home out rc real_tasks state_dir
  home=$(make_home metadata-gate)
  printf 'OPEN\n' > "$home/states/1"
  add_row "$home" meta-pr in_flight
  printf 'pr=https://github.com/example/repo/pull/1\n' > "$home/state/meta-pr.meta"
  out=$(in_home "$home" "$WRAPPER" close meta-pr 2>&1); rc=$?
  expect_code 2 "$rc" "close with a metadata-only PR"
  assert_contains "$out" "is still open" "metadata-only PR was not checked"
  [ "$(row_state "$home" meta-pr)" = in_flight ] || fail "metadata-only PR row was closed"

  state_dir="$home/alternate-state"
  mkdir -p "$state_dir"
  mv "$home/state/meta-pr.meta" "$state_dir/meta-pr.meta"
  out=$(FM_STATE_OVERRIDE="$state_dir" in_home "$home" "$WRAPPER" done meta-pr 2>&1); rc=$?
  expect_code 2 "$rc" "done with an overridden state directory"
  assert_contains "$out" "is still open" "overridden metadata was not checked"

  real_tasks=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = show ] && [ "\${2:-}" = meta-pr ]; then
  echo 'code: BACKEND_UNAVAILABLE' >&2
  exit 1
fi
case "\${1:-}" in done|close) echo called >> "$home/mutations" ;; esac
exec "$real_tasks" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  out=$(in_home "$home" "$WRAPPER" done meta-pr 2>&1); rc=$?
  expect_code 2 "$rc" "done when reading the row fails"
  assert_contains "$out" "cannot read the task row" "failed read did not explain the refusal"
  assert_absent "$home/mutations" "a failed read reached the close mutation"
  [ "$(row_state "$home" meta-pr)" = in_flight ] || fail "unreadable row was closed"

  out=$(in_home "$home" "$WRAPPER" done missing-row 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "missing row was reported closed"
  assert_contains "$out" "code: NOT_FOUND" "missing row did not report tasks-axi's error"
  assert_present "$home/mutations" "a confirmed absent row did not pass through to tasks-axi"
  pass "metadata-only PRs and unreadable rows cannot bypass the hand-close gate"
}

test_supersession_body_boundary() {
  local home out rc id body
  home=$(make_home supersession-boundary)
  printf 'CLOSED\n' > "$home/states/1"
  add_row "$home" title-only in_flight 1 '' 'Superseded: title is not a declaration'
  add_row "$home" inline-only in_flight 1 'Require Superseded: reasons before closing PRs'
  add_row "$home" blank-only in_flight 1 $'Superseded: \t\nUnrelated next line'
  for id in title-only inline-only blank-only; do
    out=$(in_home "$home" "$WRAPPER" done "$id" 2>&1); rc=$?
    expect_code 2 "$rc" "$id supersession false positive"
    [ "$(row_state "$home" "$id")" = in_flight ] || fail "$id was closed as superseded"
    tasks-axi done "$id" --file "$home/data/backlog.md" >/dev/null
  done
  body=$'Prior context\nSuperseded: "substituído" by a smaller change\nOther context'
  add_row "$home" body-line in_flight 1 "$body"
  in_home "$home" "$WRAPPER" done body-line >/dev/null 2>&1 || fail "decoded supersession line was refused"
  out=$(in_home "$home" "$AUDIT" 2>&1); rc=$?
  expect_code 0 "$rc" "audit supersession boundary"
  for id in title-only inline-only blank-only; do
    assert_contains "$out" "task $id is recorded done" "audit suppressed $id's mismatch"
  done
  assert_not_contains "$out" 'task body-line' "audit flagged a valid decoded supersession line"
  pass "supersession requires a nonblank marker line in the decoded body"
}

test_captain_answer_pr_gate() {
  local home out rc source id
  home=$(make_home captain-pr-gate)
  printf 'OPEN\n' > "$home/states/1"
  printf 'Leave it for later.\n' > "$home/answer.txt"
  for source in meta row; do
    id="held-$source"
    add_row "$home" "$id" in_flight
    if [ "$source" = meta ]; then
      printf 'pr=https://github.com/example/repo/pull/1\n' > "$home/state/$id.meta"
    else
      tasks-axi update "$id" --pr https://github.com/example/repo/pull/1 --file "$home/data/backlog.md" >/dev/null
    fi
    in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason 'Decide whether to merge' >/dev/null \
      || fail "could not hold $id"
    out=$(in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$home/answer.txt" 2>&1); rc=$?
    expect_code 1 "$rc" "captain answer with an open $source PR"
    assert_contains "$out" 'is still open' "captain answer did not explain PR refusal"
    [ "$(row_state "$home" "$id")" != done ] || fail "captain answer closed an open $source PR"
    assert_present "$home/state/cards/$id.json" "refused answer removed its card"
  done
  printf 'MERGED\n' > "$home/states/1"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer held-meta --decision-file "$home/answer.txt" >/dev/null \
    || fail "merged PR did not permit the interrupted answer to finish"
  [ "$(row_state "$home" held-meta)" = done ] || fail "merged captain answer did not close"
  rm "$home/states/1"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer held-meta --decision-file "$home/answer.txt" >/dev/null \
    || fail "closed answer replay required forge access"
  pass "captain answers gate metadata and row PRs while closed replays remain offline"
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
  test_metadata_and_read_failure_gates
  test_supersession_body_boundary
  test_captain_answer_pr_gate
  test_audit_flags_mismatches_read_only
else
  echo "skip: tasks-axi not found; PR completion-claim cases not run"
fi
