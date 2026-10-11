#!/usr/bin/env bash
# Behavior tests for the PR completion-claim gate and recorded outcomes outside teardown:
#   - bin/fm-tasks-axi.sh done refuses to close a row whose PR (its --pr, else
#     the row's own PR link) is open, closed without a recorded supersession,
#     or unreadable, and lets a merged or superseded one through;
#   - a gated close records the PR's real outcome, so a superseded row reads
#     as done rather than merged;
#   - bin/fm-pr-record-audit.sh flags Done rows whose PR is open, closed
#     unmerged without a supersession reason, or superseded but still shown as
#     merged, read-only unless --migrate records the real outcome.
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

test_completion_command_forms() {
  local home out rc verb
  home=$(make_home completion-noun)
  printf 'OPEN\n' > "$home/states/1"
  for verb in "done" close; do
    add_row "$home" "noun-$verb" in_flight
    out=$(in_home "$home" "$WRAPPER" task "$verb" "noun-$verb" \
      --pr https://github.com/example/repo/pull/1 2>&1); rc=$?
    expect_code 2 "$rc" "task $verb with an open PR"
    assert_contains "$out" 'is still open' "task $verb bypassed the live-state check"
    [ "$(row_state "$home" "noun-$verb")" = in_flight ] || fail "task $verb closed an open PR"
    printf 'MERGED\n' > "$home/states/1"
    in_home "$home" "$WRAPPER" task "$verb" "noun-$verb" \
      --pr https://github.com/example/repo/pull/1 >/dev/null 2>&1 || fail "task $verb refused a merged PR"
    [ "$(row_state "$home" "noun-$verb")" = "done" ] || fail "task $verb did not close a merged PR"
    printf 'OPEN\n' > "$home/states/1"
  done
  pass "optional task noun gates both completion verbs"
}

test_completion_backend_flags() {
  local home out rc form id
  local -a args
  home=$(make_home completion-backend)
  printf 'OPEN\n' > "$home/states/1"
  for form in separated equals after-id repeated; do
    id="backend-$form"
    add_row "$home" "$id" in_flight 1
    case "$form" in
      separated) args=("done" --backend markdown "$id" --pr https://github.com/example/repo/pull/1) ;;
      equals) args=(close --backend=markdown "$id") ;;
      after-id) args=(task "done" "$id" --backend markdown) ;;
      repeated) args=(task close --backend=unused "$id" --backend markdown) ;;
    esac
    out=$(TASKS_AXI_BACKEND=unused in_home "$home" "$WRAPPER" "${args[@]}" 2>&1); rc=$?
    expect_code 2 "$rc" "$form backend flag with an open PR"
    assert_contains "$out" 'is still open' "$form backend flag checked the wrong task or backend"
    [ "$(row_state "$home" "$id")" = in_flight ] || fail "$form backend flag closed an open PR"
    printf 'MERGED\n' > "$home/states/1"
    TASKS_AXI_BACKEND=unused in_home "$home" "$WRAPPER" "${args[@]}" >/dev/null 2>&1 \
      || fail "$form backend flag refused a merged PR"
    [ "$(row_state "$home" "$id")" = "done" ] || fail "$form backend flag did not close a merged PR"
    printf 'OPEN\n' > "$home/states/1"
  done
  pass "completion reads and mutations use the same effective backend and task ID"
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
  out=$(FM_STATE_OVERRIDE="$state_dir" in_home "$home" "$WRAPPER" "done" meta-pr 2>&1); rc=$?
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
  out=$(in_home "$home" "$WRAPPER" "done" meta-pr 2>&1); rc=$?
  expect_code 2 "$rc" "done when reading the row fails"
  assert_contains "$out" "cannot read the task row" "failed read did not explain the refusal"
  assert_absent "$home/mutations" "a failed read reached the close mutation"
  [ "$(row_state "$home" meta-pr)" = in_flight ] || fail "unreadable row was closed"

  out=$(in_home "$home" "$WRAPPER" "done" missing-row 2>&1); rc=$?
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
    out=$(in_home "$home" "$WRAPPER" "done" "$id" 2>&1); rc=$?
    expect_code 2 "$rc" "$id supersession false positive"
    [ "$(row_state "$home" "$id")" = in_flight ] || fail "$id was closed as superseded"
    tasks-axi "done" "$id" --file "$home/data/backlog.md" >/dev/null
  done
  body=$'Prior context\nSuperseded: "substituído" by a smaller change\nOther context'
  add_row "$home" body-line in_flight 1 "$body"
  in_home "$home" "$WRAPPER" "done" body-line >/dev/null 2>&1 || fail "decoded supersession line was refused"
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
    [ "$(row_state "$home" "$id")" != "done" ] || fail "captain answer closed an open $source PR"
    assert_present "$home/state/cards/$id.json" "refused answer removed its card"
  done
  printf 'MERGED\n' > "$home/states/1"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer held-meta --decision-file "$home/answer.txt" >/dev/null \
    || fail "merged PR did not permit the interrupted answer to finish"
  [ "$(row_state "$home" held-meta)" = "done" ] || fail "merged captain answer did not close"
  rm "$home/states/1"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer held-meta --decision-file "$home/answer.txt" >/dev/null \
    || fail "closed answer replay required forge access"
  pass "captain answers gate metadata and row PRs while closed replays remain offline"
}

test_audit_metadata_only_prs() {
  local home out rc before real_tasks id mode state_dir
  home=$(make_home audit-metadata)
  printf 'OPEN\n' > "$home/states/1"
  printf 'MERGED\n' > "$home/states/2"
  printf 'CLOSED\n' > "$home/states/3"
  add_row "$home" metadata-open "done"
  add_row "$home" metadata-merged "done"
  add_row "$home" metadata-superseded "done" '' 'Superseded: replaced by another change'
  add_row "$home" row-first "done" 2
  add_row "$home" review-metadata in_flight
  add_row "$home" no-pr "done"
  for id in metadata-open row-first review-metadata; do
    printf 'pr=https://github.com/example/repo/pull/1\n' > "$home/state/$id.meta"
  done
  printf 'pr=https://github.com/example/repo/pull/2\n' > "$home/state/metadata-merged.meta"
  printf 'pr=https://github.com/example/repo/pull/3\n' > "$home/state/metadata-superseded.meta"
  real_tasks=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<SH
#!/usr/bin/env bash
case "\${1:-}" in
  list) echo list >> "$home/reads" ;;
  show) echo "show:\${2:-}" >> "$home/reads" ;;
  add|update|start|done|close) echo mutation >> "$home/reads" ;;
esac
exec "$real_tasks" "\$@"
SH
  chmod +x "$home/fakebin/tasks-axi"
  for mode in default override; do
    state_dir="$home/state"
    if [ "$mode" = override ]; then
      state_dir="$home/alternate-state"
      mkdir -p "$state_dir"
      mv "$home/state/"*.meta "$state_dir/"
    fi
    before=$(cksum "$home/data/backlog.md" "$state_dir/"*.meta)
    : > "$home/reads"
    if [ "$mode" = override ]; then
      out=$(FM_STATE_OVERRIDE="$state_dir" in_home "$home" "$AUDIT" 2>"$home/stderr"); rc=$?
    else
      out=$(in_home "$home" "$AUDIT" 2>"$home/stderr"); rc=$?
    fi
    expect_code 0 "$rc" "audit metadata-only PRs ($mode)"
    assert_equals 'task metadata-open is recorded done but PR https://github.com/example/repo/pull/1 is open - reconcile' \
      "$out" "audit missed a metadata-only PR or ignored row-link precedence ($mode)"
    assert_equals 'list
show:metadata-merged
show:metadata-open
show:metadata-superseded
show:no-pr
show:row-first' "$(head -1 "$home/reads"; sed 1d "$home/reads" | sort)" \
      "audit read more than one listing or did not read exactly the Done rows ($mode)"
    assert_equals "$before" "$(cksum "$home/data/backlog.md" "$state_dir/"*.meta)" \
      "audit rewrote backlog or metadata records ($mode)"
  done
  pass "audit finds metadata-only Done PRs with one listing and one read per Done row"
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
task done-open is recorded done but PR https://github.com/example/repo/pull/1 is open - reconcile
task done-superseded shows as merged but PR https://github.com/example/repo/pull/4 was superseded - run with --migrate" \
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

done_line() {  # <home> <id>
  grep -E "^- \[x\] $2 - " "$1/data/backlog.md"
}

body_of() {  # <home> <id>
  tasks-axi show "$2" --full --file "$1/data/backlog.md" | sed -n 's/^  body: //p'
}

test_close_records_explicit_outcome() {
  local home merged superseded out rc
  home=$(make_home close-outcome)
  printf 'MERGED\n' > "$home/states/3"
  printf 'CLOSED\n' > "$home/states/4"
  add_row "$home" merged-pr in_flight 3
  add_row "$home" superseded-pr in_flight 4 "Superseded: replaced by a smaller change"
  add_row "$home" plain in_flight
  in_home "$home" "$WRAPPER" "done" merged-pr >/dev/null 2>&1 || fail "done refused a merged PR"
  in_home "$home" "$WRAPPER" "done" superseded-pr >/dev/null 2>&1 || fail "done refused a superseded PR"
  in_home "$home" "$WRAPPER" "done" plain >/dev/null 2>&1 || fail "done refused a row with no PR"

  merged=$(done_line "$home" merged-pr)
  assert_contains "$merged" "(merged " "a merged close did not read as merged"
  assert_contains "$(body_of "$home" merged-pr)" "Outcome: merged https://github.com/example/repo/pull/3" \
    "a merged close did not record its outcome"

  superseded=$(done_line "$home" superseded-pr)
  assert_contains "$superseded" "(done " "a superseded close did not read as done"
  assert_not_contains "$superseded" "(merged " "a superseded close still reads as merged"
  assert_not_contains "$superseded" "/pull/4" "a superseded close left its PR link on the row"
  assert_contains "$(body_of "$home" superseded-pr)" "Outcome: superseded https://github.com/example/repo/pull/4" \
    "a superseded close did not keep its PR as the recorded outcome"
  assert_not_contains "$(body_of "$home" plain)" "Outcome:" "a close with no PR recorded an outcome"

  out=$(in_home "$home" "$AUDIT" 2>&1); rc=$?
  expect_code 0 "$rc" "audit after outcome-recording closes"
  assert_equals '' "$out" "the audit flagged rows whose outcome is recorded and true"
  pass "closes record merged or superseded explicitly, and a superseded row no longer reads as merged"
}

test_audit_flags_and_migrates_legacy_rows() {
  local home out rc before
  home=$(make_home audit-legacy)
  printf 'MERGED\n' > "$home/states/2"
  printf 'CLOSED\n' > "$home/states/3"
  printf 'CLOSED\n' > "$home/states/4"
  printf 'OPEN\n' > "$home/states/1"
  add_row "$home" legacy-merged "done" 2
  add_row "$home" legacy-closed "done" 3
  add_row "$home" legacy-superseded "done" 4 "Superseded: folded into legacy-merged"
  add_row "$home" legacy-open "done" 1
  before=$(cat "$home/data/backlog.md")

  out=$(in_home "$home" "$AUDIT" 2>&1); rc=$?
  expect_code 0 "$rc" "audit of legacy rows"
  assert_contains "$out" "task legacy-superseded shows as merged but PR https://github.com/example/repo/pull/4 was superseded - run with --migrate" \
    "the audit did not flag a superseded row that reads as merged"
  assert_contains "$out" "task legacy-closed is recorded done but PR https://github.com/example/repo/pull/3 was closed without merging" \
    "the audit lost the unexplained closed-PR mismatch"
  assert_not_contains "$out" "legacy-merged" "the audit flagged a row whose PR merged"
  assert_equals "$before" "$(cat "$home/data/backlog.md")" "the audit without --migrate changed the backlog"

  out=$(in_home "$home" "$AUDIT" --migrate 2>&1); rc=$?
  expect_code 0 "$rc" "audit --migrate"
  assert_contains "$(done_line "$home" legacy-merged)" "(merged " "migration changed a merged row's label"
  assert_contains "$(body_of "$home" legacy-merged)" "Outcome: merged https://github.com/example/repo/pull/2" \
    "migration did not record a merged outcome"
  assert_contains "$(done_line "$home" legacy-superseded)" "(done " "migration left a superseded row reading as merged"
  assert_contains "$(body_of "$home" legacy-superseded)" "Outcome: superseded https://github.com/example/repo/pull/4" \
    "migration did not record a superseded outcome"
  assert_contains "$(done_line "$home" legacy-closed)" "(done " "migration left an unmerged row reading as merged"
  assert_contains "$(body_of "$home" legacy-closed)" "Outcome: closed-unmerged https://github.com/example/repo/pull/3" \
    "migration did not record a closed-unmerged outcome"
  assert_contains "$(done_line "$home" legacy-open)" "/pull/1" "migration rewrote a row whose PR is still open"
  assert_not_contains "$(body_of "$home" legacy-open)" "Outcome:" "migration recorded an outcome for an open PR"
  assert_contains "$out" "task legacy-open is recorded done but PR https://github.com/example/repo/pull/1 is open - reconcile" \
    "migration hid the open-PR mismatch"

  out=$(in_home "$home" "$AUDIT" 2>&1); rc=$?
  assert_equals 'task legacy-open is recorded done but PR https://github.com/example/repo/pull/1 is open - reconcile' \
    "$out" "after migration only the open PR should still need a hand"
  printf 'MERGED\n' > "$home/states/3"
  out=$(in_home "$home" "$AUDIT" 2>&1)
  assert_contains "$out" "task legacy-closed records closed-unmerged but PR https://github.com/example/repo/pull/3 merged - reconcile" \
    "the audit did not check a recorded outcome against the forge"
  pass "the audit flags legacy rows that read as merged and --migrate records their real outcome"
}

test_embedded_pr_links_are_removed() {
  local home form mode id title line detail
  home=$(make_home embedded-pr-links)
  printf 'CLOSED\n' > "$home/states/4"
  printf 'CLOSED\n' > "$home/states/5"
  for mode in close migrate; do
    for form in markdown parentheses multiple; do
      id="$mode-$form"
      case "$form" in
        markdown) title='Fix [PR](https://github.com/example/repo/pull/4)' ;;
        parentheses) title='Fix (https://github.com/example/repo/pull/4)' ;;
        multiple) title='Fix [PR](https://github.com/example/repo/pull/4),[old](https://github.com/example/repo/pull/5)' ;;
      esac
      add_row "$home" "$id" in_flight '' 'Superseded: replaced by a smaller change' "$title"
      detail=$(tasks-axi show "$id" --full --file "$home/data/backlog.md" | sed -n 's/^  links: //p')
      assert_contains "$detail" 'pr:https://' "tasks-axi did not recognize the $form PR fixture"
      if [ "$mode" = close ]; then
        in_home "$home" "$WRAPPER" "done" "$id" >/dev/null 2>&1 \
          || fail "$form PR close failed"
      else
        tasks-axi "done" "$id" --file "$home/data/backlog.md" >/dev/null
        in_home "$home" "$AUDIT" --migrate >/dev/null 2>&1 || fail "$form PR migration failed"
      fi
      line=$(done_line "$home" "$id")
      assert_contains "$line" '(done ' "$mode left the $form PR fixture labeled merged"
      detail=$(tasks-axi show "$id" --full --file "$home/data/backlog.md" | sed -n 's/^  links: //p')
      assert_not_contains "$detail" 'pr:https://' "$mode left a $form PR link on the title"
      assert_contains "$(body_of "$home" "$id")" 'Outcome: superseded' "$mode lost the $form PR outcome"
      assert_contains "$(body_of "$home" "$id")" 'https://github.com/example/repo/pull/4' "$mode lost the $form PR reference"
      if [ "$form" = multiple ]; then
        assert_contains "$(body_of "$home" "$id")" 'https://github.com/example/repo/pull/5' "$mode lost the other embedded PR"
      fi
    done
  done
  pass "close and migration remove embedded PR links recognized by tasks-axi and preserve them in the body"
}

test_merged_outcome_owns_pr_identity() {
  local home out
  home=$(make_home replacement-pr)
  printf 'CLOSED\n' > "$home/states/1"
  printf 'MERGED\n' > "$home/states/2"
  add_row "$home" replacement in_flight 1
  in_home "$home" "$WRAPPER" update replacement --pr https://github.com/example/repo/pull/2 >/dev/null \
    || fail "could not record the replacement PR"
  in_home "$home" "$WRAPPER" "done" replacement --pr https://github.com/example/repo/pull/2 >/dev/null \
    || fail "could not close the replacement PR"
  assert_contains "$(done_line "$home" replacement)" '/pull/1' "fixture lost its original title PR"
  assert_contains "$(body_of "$home" replacement)" 'Outcome: merged https://github.com/example/repo/pull/2' \
    "replacement PR close recorded the wrong outcome"
  out=$(in_home "$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "replacement snapshot failed"
  printf '%s' "$out" | jq -e '
    .backlog.records | any(.id == "replacement" and .outcome == "merged"
      and .pr_url == "https://github.com/example/repo/pull/2" and .completion.verb == "merged")
  ' >/dev/null || fail "snapshot paired the merged verdict with the original PR"
  out=$(in_home "$home" "$ROOT/bin/fm-bearings-snapshot.sh" --json --all-landed) || fail "replacement bearings failed"
  printf '%s' "$out" | jq -e '
    .landed | any(.id == "replacement" and .artifact == "https://github.com/example/repo/pull/2")
  ' >/dev/null || fail "Recently Landed delivered the original unmerged PR"
  pass "the recorded merged outcome owns PR identity in the snapshot and Recently Landed"
}

test_reopened_outcome_pr_is_gated() {
  local home mode id out rc
  home=$(make_home reopened-outcome)
  printf 'Drop the superseded work.\n' > "$home/answer.txt"
  for mode in done answer; do
    id="reopened-$mode"
    printf 'CLOSED\n' > "$home/states/4"
    add_row "$home" "$id" in_flight 4 'Superseded: replaced by a smaller change'
    in_home "$home" "$WRAPPER" "done" "$id" >/dev/null || fail "initial superseded close failed"
    in_home "$home" "$WRAPPER" reopen "$id" >/dev/null || fail "could not reopen the superseded row"
    in_home "$home" "$WRAPPER" start "$id" >/dev/null || fail "could not restart the superseded row"
    assert_absent "$home/state/$id.meta" "outcome-only fixture unexpectedly has metadata"
    assert_contains "$(body_of "$home" "$id")" 'Outcome: superseded' "reopen did not preserve the outcome"
    printf 'OPEN\n' > "$home/states/4"
    if [ "$mode" = done ]; then
      out=$(in_home "$home" "$WRAPPER" "done" "$id" 2>&1); rc=$?
      expect_code 2 "$rc" "done on a reopened outcome-only PR"
    else
      in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold "$id" --reason 'Decide whether to drop it' >/dev/null \
        || fail "could not hold the reopened row"
      out=$(in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$home/answer.txt" 2>&1); rc=$?
      expect_code 1 "$rc" "captain answer on a reopened outcome-only PR"
    fi
    assert_contains "$out" 'is still open' "$mode bypassed the preserved PR's live-state check"
    [ "$(row_state "$home" "$id")" != "done" ] || fail "$mode closed a reopened open PR"
    printf 'MERGED\n' > "$home/states/4"
    if [ "$mode" = done ]; then
      in_home "$home" "$WRAPPER" "done" "$id" >/dev/null || fail "reopened merged PR could not close"
    else
      in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer "$id" --decision-file "$home/answer.txt" >/dev/null \
        || fail "reopened merged PR could not finish its answer"
    fi
    [ "$(row_state "$home" "$id")" = "done" ] || fail "$mode did not close after the PR merged"
    assert_contains "$(body_of "$home" "$id")" 'Outcome: merged https://github.com/example/repo/pull/4' \
      "$mode kept the stale superseded outcome"
  done
  pass "reopened outcome-only PRs pass the live completion gate for done and captain answer"
}

test_captain_answer_records_outcome() {
  local home line
  home=$(make_home captain-outcome)
  printf 'CLOSED\n' > "$home/states/4"
  printf 'Drop it, the smaller change replaced it.\n' > "$home/answer.txt"
  add_row "$home" held-superseded in_flight 4 "Superseded: replaced by a smaller change"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" hold held-superseded --reason 'Decide whether to drop it' >/dev/null \
    || fail "could not hold held-superseded"
  in_home "$home" "$ROOT/bin/fm-captain-hold.sh" answer held-superseded --decision-file "$home/answer.txt" >/dev/null \
    || fail "a superseded PR did not let the answer close the task"
  line=$(done_line "$home" held-superseded)
  assert_not_contains "$line" "(merged " "an answered superseded call reads as merged"
  assert_contains "$(body_of "$home" held-superseded)" "Outcome: superseded https://github.com/example/repo/pull/4" \
    "an answered superseded call did not record its outcome"
  pass "a captain answer that closes a superseded PR records it as superseded"
}

if command -v tasks-axi >/dev/null 2>&1; then
  test_done_gate
  test_completion_command_forms
  test_completion_backend_flags
  test_metadata_and_read_failure_gates
  test_supersession_body_boundary
  test_captain_answer_pr_gate
  test_audit_metadata_only_prs
  test_audit_flags_mismatches_read_only
  test_close_records_explicit_outcome
  test_audit_flags_and_migrates_legacy_rows
  test_embedded_pr_links_are_removed
  test_merged_outcome_owns_pr_identity
  test_reopened_outcome_pr_is_gated
  test_captain_answer_records_outcome
else
  echo "skip: tasks-axi not found; PR completion-claim cases not run"
fi
