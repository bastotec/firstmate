#!/usr/bin/env bash
# tests/fm-meta-backfill.test.sh - bin/fm-meta-backfill.sh writes the backend
# every reader already resolves for a record without backend=, refuses records
# whose shape contradicts that, and changes nothing on a second run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-meta-backfill-tests)
trap fm_test_cleanup EXIT INT TERM
BACKFILL="$ROOT/bin/fm-meta-backfill.sh"

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s' "$home"
}

backend_of() {  # <meta>
  (
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_of_meta "$1"
  )
}

test_legacy_tmux_records_become_explicit_and_rerun_is_a_noop() {
  local home out before
  home=$(new_home legacy)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "endpoint_task_id=alpha" "harness=deck" "kind=ship"
  # A record whose last line has no newline must not get its last value glued
  # onto the new line.
  printf 'window=ghostty:fm-beta\nendpoint_task_id=beta\nkind=secondmate' > "$home/state/beta.meta"
  fm_write_meta "$home/state/gamma.meta" "window=fm-remote:w1:p2" "backend=herdr" "herdr_session=fm-remote" "herdr_pane_id=w1:p2"
  fm_write_meta "$home/state/delta.meta" "window=remote:delta" "kind=secondmate" "remote_host=workload" "remote_backend=herdr"
  before=$(cat "$home/state/gamma.meta" "$home/state/delta.meta")

  out=$("$BACKFILL" --home "$home" 2>&1) || fail "backfill refused a clean home: $out"
  assert_contains "$out" "backfilled alpha backend=tmux" "alpha was not reported"
  assert_contains "$out" "backfilled beta backend=tmux" "beta was not reported"
  assert_not_contains "$out" gamma "an explicit herdr record was touched"
  assert_not_contains "$out" delta "a remote second mate record was touched"
  assert_equals tmux "$(backend_of "$home/state/alpha.meta")" "alpha no longer resolves to tmux"
  assert_equals backend=tmux "$(tail -n 1 "$home/state/beta.meta")" "beta did not get its own line"
  grep -qx 'kind=secondmate' "$home/state/beta.meta" || fail "beta's unterminated last line was damaged"
  assert_equals "$before" "$(cat "$home/state/gamma.meta" "$home/state/delta.meta")" "skipped records changed"

  before=$(cat "$home/state"/*.meta)
  out=$("$BACKFILL" --home "$home" 2>&1) || fail "second run failed: $out"
  assert_contains "$out" "nothing to backfill" "second run was not a no-op"
  assert_equals "$before" "$(cat "$home/state"/*.meta)" "second run changed records"
  [ "$(grep -c '^backend=' "$home/state/alpha.meta")" = 1 ] || fail "alpha got a duplicate backend= line"
  pass "fm-meta-backfill: legacy tmux records get backend=tmux once; explicit and remote records are left alone"
}

test_dry_run_writes_nothing() {
  local home out
  home=$(new_home dry)
  fm_write_meta "$home/state/alpha.meta" "window=firstmate:fm-alpha" "kind=ship"
  out=$("$BACKFILL" --home "$home" --dry-run 2>&1) || fail "dry run failed: $out"
  assert_contains "$out" "would backfill alpha backend=tmux" "dry run did not report its plan"
  assert_no_grep 'backend=' "$home/state/alpha.meta" "dry run wrote a record"
  pass "fm-meta-backfill: --dry-run prints the plan and writes nothing"
}

test_a_record_it_cannot_classify_refuses_the_whole_run() {
  local home out rc case_meta
  for case_meta in \
    "herdr-keys|window=fm-remote:w1:p2|herdr_pane_id=w1:p2|herdr_pane_id" \
    "herdr-window|window=fm-remote:w1:p2|kind=ship|not a tmux session:window" \
    "stream-keys|window=hub-7717:abc123|stream_endpoint_id=abc123|stream_endpoint_id" \
    "no-window|kind=ship|harness=deck|no window" \
    "empty-backend|window=firstmate:fm-x|backend=|empty backend" \
    "remote-unknown|window=remote:x|remote_host=workload|no remote_backend"; do
    IFS='|' read -r name l1 l2 why <<EOF
$case_meta
EOF
    home=$(new_home "refuse-$name")
    fm_write_meta "$home/state/good.meta" "window=firstmate:fm-good" "kind=ship"
    fm_write_meta "$home/state/odd.meta" "$l1" "$l2"
    out=$("$BACKFILL" --home "$home" 2>&1); rc=$?
    expect_code 1 "$rc" "$name: an unclassifiable record must refuse the run"$'\n'"$out"
    assert_contains "$out" "refused odd" "$name: refusal did not name the record"
    assert_contains "$out" "$why" "$name: refusal did not give its reason"
    assert_no_grep 'backend=' "$home/state/good.meta" "$name: a refused run still wrote another record"
  done
  pass "fm-meta-backfill: foreign backend keys, herdr-shaped or missing windows, empty backend= and unknown remote records refuse with nothing written"
}

test_usage_errors() {
  local out rc
  out=$("$BACKFILL" --home "$TMP_ROOT/does-not-exist" 2>&1); rc=$?
  expect_code 2 "$rc" "a missing home must be a usage error"
  assert_contains "$out" "is not a directory" "missing home not explained"
  out=$("$BACKFILL" --bogus 2>&1); rc=$?
  expect_code 2 "$rc" "an unknown flag must be a usage error"
  pass "fm-meta-backfill: a missing home or unknown flag is a usage error"
}

test_legacy_tmux_records_become_explicit_and_rerun_is_a_noop
test_dry_run_writes_nothing
test_a_record_it_cannot_classify_refuses_the_whole_run
test_usage_errors
