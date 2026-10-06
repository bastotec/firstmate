#!/usr/bin/env bash
# Behavior tests for the per-adapter semantic busy-state wiring that
# bin/fm-spawn.sh installs under the contract owned by bin/fm-busy-lib.sh.
#
# These tests run the REAL fm-spawn against a fake tmux pane and an isolated
# git worktree, then drive the generated adapter artifact (for Deck, the gen
# fm-spawn hands bin/fm-deck-worker.sh on its launch line), so the wiring, the
# real bin/fm-busy-event.sh writer, and
# the real classifier are exercised together with no live harness session.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-busy-adapter-wiring)

make_spawn_case() {  # <name> <harness> <id>
  local name=$1 harness=$2 id=$3 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  fakebin=$(make_spawn_fakebin "$case_dir/fake" gemini)
  fm_test_fake_deck "$fakebin"
  fm_test_spawn_home "$home" "$harness"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

run_spawn() {  # <home> <wt> <fakebin> <spawn-args...>
  # Every case here is a ship spawn, which carries an explicit delivery contract
  # (AGENTS.md section 7); these tests are about busy-state wiring, so they pass a
  # fixed valid one.
  local home=$1 wt=$2 fakebin=$3
  shift 3
  fm_test_run_spawn "$home" "$wt" "$fakebin" "$@" --mode no-mistakes --yolo off
}

read_case_record() {
  # shellcheck disable=SC2034 # CASE_DIR is part of the shared record shape
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR <<EOF
$1
EOF
}

classify() {  # <harness> <id> <state-dir>
  fm_busy_classify tmux fake:w "$1" "$2" "$3"
}

# launched_gen <launch-log>: the --gen value fm-spawn typed onto the Deck
# worker's launch line (shell-quoted by fm-spawn, so strip the quotes).
launched_gen() {
  sed -n "s/.* --gen '\([^']*\)' .*/\1/p" "$1" | head -n 1
}

test_deck_spawn_arms_gen_and_passes_it_to_the_wrapper() {
  local rec id=busy-deck-1 out state log gen
  rec=$(make_spawn_case deck-lifecycle deck "$id")
  read_case_record "$rec"
  log="$CASE_DIR/launch.log"
  : > "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "deck spawn should succeed: $out"
  assert_contains "$out" "spawned $id harness=deck" "deck spawn did not complete normally"
  state="$HOME_DIR/state"
  assert_present "$state/$id.busy-gen" "deck spawn did not arm a busy generation"
  assert_absent "$WT_DIR/.claude/settings.local.json" "deck spawn must not write hook settings into the worktree"

  out=$(classify deck "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after deck spawn must be 'busy fm-spawn', got '$out'"

  assert_contains "$(cat "$log")" 'fm-deck-worker' "deck launch did not run the deck worker wrapper"
  gen=$(launched_gen "$log")
  [ -n "$gen" ] || fail "deck launch line carries no --gen: $(cat "$log")"
  [ "$gen" = "$(cat "$state/$id.busy-gen")" ] \
    || fail "deck launch --gen '$gen' does not match the armed sidecar $(cat "$state/$id.busy-gen")"

  # The wrapper writes deck-wrapper events under the gen it was launched with.
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" --source deck-wrapper --event turn-end \
    || fail "an event under the launched gen was refused"
  out=$(classify deck "$id" "$state")
  [ "$out" = "idle deck-wrapper" ] || fail "turn-end under the launched gen must classify 'idle deck-wrapper', got '$out'"
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" busy --gen "$gen" --source deck-wrapper --event turn-start \
    || fail "turn-start under the launched gen was refused"
  out=$(classify deck "$id" "$state")
  [ "$out" = "busy deck-wrapper" ] || fail "turn-start must classify 'busy deck-wrapper', got '$out'"
  pass "deck spawn arms the busy gen, hands the same gen to the wrapper, and trusts deck-wrapper events under it"
}

test_deck_wrapper_stale_incarnation_rejected() {
  local rec id=busy-deck-2 out state log gen
  rec=$(make_spawn_case deck-stale deck "$id")
  read_case_record "$rec"
  log="$CASE_DIR/launch.log"
  : > "$log"
  out=$(FM_FAKE_LAUNCH_LOG="$log" run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR")
  expect_code 0 $? "deck spawn should succeed: $out"
  state="$HOME_DIR/state"
  gen=$(launched_gen "$log")
  [ -n "$gen" ] || fail "deck launch line carries no --gen"
  # A re-arm supersedes the gen the old wrapper was launched with.
  "$ROOT/bin/fm-busy-event.sh" arm "$state" "$id" >/dev/null
  if "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" idle --gen "$gen" --source deck-wrapper --event turn-end 2>/dev/null; then
    fail "an event from a superseded deck wrapper must be refused"
  fi
  out=$(classify deck "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "a stale deck-wrapper event must not change state, got '$out'"
  pass "deck-wrapper events from a superseded incarnation are rejected as stale"
}

test_deck_secondmate_arms_busy_gen() {
  local rec id=busy-deck-sm out state log gen sm
  rec=$(make_spawn_case deck-secondmate deck "$id")
  read_case_record "$rec"
  sm="$CASE_DIR/secondmate-home"
  mkdir -p "$sm/bin" "$sm/data"
  printf '# Firstmate\n' > "$sm/AGENTS.md"
  printf '%s\n' "$id" > "$sm/.fm-secondmate-home"
  printf 'charter for %s\n' "$id" > "$sm/data/charter.md"
  sm=$(cd "$sm" && pwd -P)
  log="$CASE_DIR/launch.log"
  : > "$log"
  # A secondmate spawn carries no delivery contract, so this one deliberately
  # bypasses run_spawn's ship-only --mode/--yolo arguments.
  out=$(FM_FAKE_LAUNCH_LOG="$log" fm_test_run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$sm" --secondmate deck)
  expect_code 0 $? "deck secondmate spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_present "$state/$id.busy-gen" "deck secondmate spawn did not arm a busy generation"
  out=$(classify deck "$id" "$state")
  [ "$out" = "busy fm-spawn" ] || fail "seed after deck secondmate spawn must be 'busy fm-spawn', got '$out'"
  assert_contains "$(cat "$log")" "--secondmate --id '$id'" "deck secondmate launch omitted host mode"
  gen=$(launched_gen "$log")
  [ "$gen" = "$(cat "$state/$id.busy-gen")" ] \
    || fail "deck secondmate launch --gen '$gen' does not match the armed sidecar"
  pass "a deck secondmate arms the busy gen and passes it to its host wrapper"
}

test_raw_launch_has_no_semantic_wiring() {
  local rec id=busy-raw out state
  rec=$(make_spawn_case raw-launch deck "$id")
  read_case_record "$rec"
  out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" 'gemini --debug')
  expect_code 0 $? "raw launch spawn should succeed: $out"
  state="$HOME_DIR/state"
  assert_absent "$state/$id.busy-gen" "a raw launch must not arm a busy generation"
  out=$(classify gemini "$id" "$state")
  [ "$out" = "unknown missing" ] || fail "a raw launch must classify unknown, got '$out'"
  pass "a raw launch command remains unwired and classifies unknown"
}

test_removed_adapter_is_refused() {
  local rec id out state harness
  for harness in claude pi; do
    id="busy-$harness"
    rec=$(make_spawn_case "$harness-refused" deck "$id")
    read_case_record "$rec"
    out=$(run_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$id" "$PROJ_DIR" "$harness") && {
      fail "a bare $harness worker harness must be refused: $out"
    }
    assert_contains "$out" "unknown harness '$harness'" "$harness refusal did not name the unknown harness: $out"
    state="$HOME_DIR/state"
    assert_absent "$state/$id.busy-gen" "a refused spawn must not arm a busy generation"
  done
  pass "a worker harness with no busy adapter is refused before anything is armed"
}

test_deck_spawn_arms_gen_and_passes_it_to_the_wrapper
test_deck_wrapper_stale_incarnation_rejected
test_deck_secondmate_arms_busy_gen
test_raw_launch_has_no_semantic_wiring
test_removed_adapter_is_refused

echo "all fm-busy-adapter-wiring tests passed"
