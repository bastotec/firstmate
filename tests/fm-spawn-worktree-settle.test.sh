#!/usr/bin/env bash
# Allocation-path regressions: foreground cwd telemetry is never allocation
# authority. Machine-readable durable allocation chooses the exact initial cwd
# and emitted Deck launch rechecks it with an inert runtime (no model calls).
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-settle)

# make_settle_fakebin <dir> builds the spawn fakebin. The endpoint is a fake
# stream endpoint (tests/fixtures.sh): after `treehouse get` its first
# <stale_reads> cwd reads report the stale path, then the settled worktree -
# reproducing a pane that transiently reports a stale cwd before settling.
make_settle_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  fm_fake_exit0 "$fakebin" deck
  fm_test_fake_treehouse "$fakebin"
  printf '%s\n' "$fakebin"
}

# make_settle_case <name> <id> <stale_reads> builds a home, a primary project
# with a real worktree (the eventual settled path), and a separate real git
# repo standing in for the stale path (a real checkout of something else
# entirely, distinct from both the project and the worktree - mirroring the
# live incident where the stale read was another real firstmate home).
make_settle_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home proj wt stale fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  stale="$case_dir/stale-other-checkout"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  mkdir -p "$home/data" "$home/projects" "$home/state" "$home/config"
  printf 'deck\n' > "$home/config/crew-harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_git_init_commit "$stale"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise settled-worktree detection for $id.

## Firstmate spec
Record only the pane's stable worktree.
EOF
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$stale|$fakebin|$countfile|$stale_reads"
}

read_settle_record() {
  IFS='|' read -r _ HOME_DIR PROJ_DIR WT_DIR STALE_DIR FAKEBIN_DIR COUNTFILE STALE_READS <<EOF
$1
EOF
}

# Spawn onto the fake hub, then leave the count of cwd reads the settle loop
# made after `treehouse get` in COUNTFILE.
run_settle_spawn() {
  local id=$1 rc
  fm_test_fake_stream_ensure || return 1
  curl -fsS -m 10 --config <(printf 'header = "Authorization: Bearer %s"\n' "$FM_STREAM_TOKEN") -X POST -H 'Content-Type: application/json' \
    --data-binary "$(jq -nc --arg t "$WT_DIR" --arg s "$STALE_DIR" --argjson n "$STALE_READS" \
      '{treehouse_cwd: $t, stale_cwd: $s, stale_cwd_reads: $n}')" \
    "$FM_TEST_STREAM_URL/v1/test/config" >/dev/null || return 1
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT_DIR" \
    PATH="$FAKEBIN_DIR:$PATH" \
    "$SPAWN" "$id" "$PROJ_DIR" --mode no-mistakes --yolo off 2>&1
  rc=$?
  fm_test_fake_stream_endpoints | jq -r --arg l "fm-$id" \
    '[.endpoints[] | select(.label == $l)] | last | .cwd_reads // 0' > "$COUNTFILE"
  return "$rc"
}

# A single stale first read (the exact incident) must not be accepted: the
# loop should keep polling until two consecutive reads agree, landing on the
# real settled worktree instead.
test_single_stale_first_read_is_not_accepted() {
  local rec id out status
  id=settle-single-stale-z1
  rec=$(make_settle_case settle-single "$id" 1)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane settles"
  assert_contains "$out" "spawned $id" "spawn did not report success"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the transient stale path as the worktree"
  pass "a single transient stale pane_current_path read is not accepted as the worktree"
}

# A pane that reports the real worktree from the very first read costs exactly
# one confirming read - not a whole extra polling cycle on top of it. Counting
# the pane reads measures the loop itself; wall-clock time would fold in every
# other cost of a spawn (fetch, trust registration) and drift with the machine.
test_already_settled_pane_costs_one_confirm_read() {
  local rec id out status reads
  id=settle-already-settled-z2
  rec=$(make_settle_case settle-already-settled "$id" 0)
  read_settle_record "$rec"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed when the pane is already settled"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the already-settled worktree"
  reads=$(cat "$COUNTFILE")
  [ "$reads" -eq 0 ] || fail "fresh allocation depended on $reads foreground cwd reads"
  pass "an already-settled pane confirms on the next read, not a whole extra cycle"
}

# make_primary_case <name> <id> <stale_reads> builds the linked-home shape: the
# spawning project is itself a LINKED worktree of the repository, and the path
# the pane transiently reports is that repository's PRIMARY checkout. `treehouse
# get` reports the repository it is preparing a slot from as its own cwd while
# it is still fetching and checking out, so the pane reads the primary for the
# first seconds. The primary is not the spawning project, so a poll that only
# compares against the project accepts it as the worktree, and the isolation
# guard then refuses the launch even though treehouse went on to enter a real
# slot. The settled path is a second linked worktree of the same repository.
make_primary_case() {
  local name=$1 id=$2 stale_reads=$3 case_dir home primary proj wt fakebin countfile
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  primary="$case_dir/primary"
  proj="$case_dir/mate"
  wt="$case_dir/slot"
  countfile="$case_dir/pane-call-count"
  fakebin=$(make_settle_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" deck
  fm_git_worktree "$primary" "$proj" "mate-$name"
  git -C "$primary" worktree add --quiet -b "slot-$name" "$wt"
  fm_test_spawn_brief "$home" "$id" "Exercise primary-checkout transient detection for $id."
  printf '%s\n' "$case_dir|$home|$proj|$wt|$primary|$fakebin|$countfile|$stale_reads"
}

# The exact incident: the pane reports the repository primary for the first
# reads, then settles into the slot treehouse actually created. The primary must
# never be adopted as the worktree, so the spawn lands on the settled slot.
test_transient_primary_checkout_is_not_accepted() {
  local rec id out status
  id=settle-primary-transient-z3
  rec=$(make_primary_case settle-primary-transient "$id" 3)
  read_settle_record "$rec"
  fm_test_fake_sleep_noop "$FAKEBIN_DIR"

  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "spawn should succeed once the pane leaves the primary checkout"$'\n'"$out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" \
    "meta did not record the settled worktree"
  assert_no_grep "worktree=$STALE_DIR" "$HOME_DIR/state/$id.meta" \
    "meta wrongly recorded the repository primary checkout as the worktree"
  pass "a transient primary-checkout pane read is not accepted as the worktree"
}

# A pane that never leaves the primary checkout must still fail at the deadline
# rather than waiting forever or recording the primary.
test_primary_checkout_that_never_settles_fails_at_the_deadline() {
  local rec id out status
  id=settle-primary-stuck-z4
  rec=$(make_primary_case settle-primary-stuck "$id" 100000)
  read_settle_record "$rec"
  WT_DIR=$STALE_DIR
  out=$(run_settle_spawn "$id")
  status=$?
  [ "$status" -ne 0 ] || fail "spawn accepted a primary allocation: $out"
  assert_contains "$out" "did not yield an isolated worktree" "missing isolation refusal"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "refused allocation published metadata"
  pass "an allocator returning primary refuses before endpoint creation"
}

# Repeated inventory readings are not a shell placement proof, even for a
# sibling copy of the same repository. The actual consumer must agree before
# any slot claim or base refresh is allowed.
test_two_stale_reads_refuse_before_mutation() {
  local rec id out status before
  id=settle-repeated-foreign
  rec=$(make_settle_case repeated-foreign "$id" 2)
  read_settle_record "$rec"
  STALE_DIR="$PROJ_DIR-sibling"
  git -C "$PROJ_DIR" worktree add --quiet --detach "$STALE_DIR" HEAD
  before=$(git -C "$STALE_DIR" reflog)
  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "stale telemetry should not affect authoritative allocation: $out"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "stale telemetry became allocation"
  [ "$(git -C "$STALE_DIR" reflog)" = "$before" ] || fail "foreign reflog changed"
  assert_equals 0 "$(cat "$COUNTFILE")" "allocation read foreground telemetry"
  pass "repeated stale inventory cannot authorize writes or choose the launch copy"
}

# Execute the delivered Deck launch from the wrong directory, replacing only
# the final bash runtime with an inert cwd recorder. No Deck/model is run.
test_delivered_launch_pins_recorded_copy() {
  local rec id out status launch
  id=settle-effective-launch
  rec=$(make_settle_case effective-launch "$id" 0)
  read_settle_record "$rec"
  fm_test_fake_stream_ensure || fail "fake stream did not start"
  out=$(run_settle_spawn "$id")
  status=$?
  expect_code 0 "$status" "inert Deck launch should succeed: $out"
  launch=$(fm_test_fake_stream_endpoints | jq -r --arg l "fm-$id" \
    '[.endpoints[] | select(.label == $l)] | last | .submitted[-1]')
  cat > "$FAKEBIN_DIR/bash" <<'STUB'
#!/bin/sh
case "$1" in
  -c) pwd -P > "$FM_RUNTIME_CWD_LOG" ;;
  *) exec /bin/bash "$@" ;;
esac
STUB
  chmod +x "$FAKEBIN_DIR/bash"
  (cd "$STALE_DIR" && FM_RUNTIME_CWD_LOG="$HOME_DIR/runtime-cwd" \
    PATH="$FAKEBIN_DIR:$PATH" /bin/bash -c "$launch") || fail "delivered command failed"
  assert_equals "$(cd "$WT_DIR" && pwd -P)" "$(cat "$HOME_DIR/runtime-cwd")" "runtime used another directory"
  assert_grep "worktree=$WT_DIR" "$HOME_DIR/state/$id.meta" "metadata differs from runtime"
  rm "$HOME_DIR/runtime-cwd"
  git -C "$PROJ_DIR" worktree move "$WT_DIR" "$WT_DIR-moved"
  if (cd "$STALE_DIR" && FM_RUNTIME_CWD_LOG="$HOME_DIR/runtime-cwd" \
    PATH="$FAKEBIN_DIR:$PATH" /bin/bash -c "$launch") 2>/dev/null; then
    fail "launch reported success after its recorded copy disappeared"
  fi
  [ ! -e "$HOME_DIR/runtime-cwd" ] || fail "runtime launched after placement verification failed"
  assert_grep 'failed: worker launch directory does not match its recorded copy' \
    "$HOME_DIR/state/$id.status" "missing placement failure status"
  pass "delivered launch executes in exactly its recorded copy despite cwd drift"
}

test_two_stale_reads_refuse_before_mutation
test_delivered_launch_pins_recorded_copy
test_single_stale_first_read_is_not_accepted
test_already_settled_pane_costs_one_confirm_read
test_transient_primary_checkout_is_not_accepted
test_primary_checkout_that_never_settles_fails_at_the_deadline

echo "# all fm-spawn-worktree-settle tests passed"
