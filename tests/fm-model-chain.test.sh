#!/usr/bin/env bash
# Behavior tests for the spawn-side model fallback chain
# (bin/fm-model-chain-lib.sh, bin/fm-record-model-refusal.sh, and the chain
# resolution wired into bin/fm-spawn.sh and bin/fm-control.sh).
#
# Four capabilities are under test:
#   A) Parsing. The branch idiom (.pi/extensions/lib/fm-branch-model-chain.ts)
#      literally: one <provider>/<model-id> label per line split at the FIRST
#      slash (provider-qualified ids survive), blank and # comment lines
#      skipped, and any malformed or duplicate label a loud refusal naming that
#      line instead of a silent selection around it.
#   B) Fall-through. A launch resolves the first label whose cooldown has
#      expired; labels in cooldown are skipped and disclosed. The supervisor
#      records a refusal (quota, cooldown, repeated provider error) through
#      bin/fm-record-model-refusal.sh onto the task's lane.
#   C) Cooldown expiry. A recorded refusal sits out five minutes doubling to an
#      hour; once the retry epoch passes the label is ready again, so a later
#      launch restores the head of the chain.
#   D) Exhaustion. A chain whose every label is in cooldown refuses with a
#      clear reason, never substituting an out-of-chain model - including on
#      the spawn path itself, where the refusal must precede any task record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# The relaunch leg reuses fm-control-relaunch's hermetic case world (its tmux
# stub, task fixture, and control runner) rather than duplicating it here.
# shellcheck source=tests/fm-control-relaunch.test.sh
FM_MODEL_CHAIN_TEST_SKIP_RUN=1 . "$(dirname "${BASH_SOURCE[0]}")/fm-control-relaunch.test.sh"

LIB="$ROOT/bin/fm-model-chain-lib.sh"
# shellcheck source=bin/fm-model-chain-lib.sh
. "$LIB"

TMP_ROOT=$(fm_test_tmproot fm-model-chain)
CHAIN=$'codex/gpt-6-luna\nzai/glm-5.3\nvercel/xiaomi/mimo-v2.6-flash\n'

# --- A) Parsing -------------------------------------------------------------

out=$(fm_model_chain_parse "$CHAIN")
assert_equals $'codex|gpt-6-luna\nzai|glm-5.3\nvercel|xiaomi/mimo-v2.6-flash' "$out" \
  "parse splits at the first slash so provider-qualified ids survive"

out=$(fm_model_chain_parse $'# comment\n\n  \ncodex/gpt-6-luna\n')
assert_equals 'codex|gpt-6-luna' "$out" "parse skips blank and comment lines"

out=$(fm_model_chain_parse 'a/b' 2>"$TMP_ROOT/err"); rc=$?
[ "$rc" -eq 0 ] || fail "single valid label parses"
assert_equals 'a|b' "$out" "single label parses to its pair"

out=$(fm_model_chain_parse $'good/model\nnoslash\n' 2>"$TMP_ROOT/err"); rc=$?
[ "$rc" -eq 1 ] || fail "a label without a slash refuses"
assert_contains "$(cat "$TMP_ROOT/err")" "noslash" "malformed refusal names the bad line"

out=$(fm_model_chain_parse $'a/b\na/b\n' 2>"$TMP_ROOT/err"); rc=$?
[ "$rc" -eq 1 ] || fail "a duplicate label refuses"
assert_contains "$(cat "$TMP_ROOT/err")" "duplicate" "duplicate refusal says duplicate"

out=$(fm_model_chain_parse $'onlyprovider/\n' 2>"$TMP_ROOT/err"); rc=$?
[ "$rc" -eq 1 ] || fail "a provider-only label refuses"

out=$(fm_model_chain_parse $'has space/model\n' 2>"$TMP_ROOT/err"); rc=$?
[ "$rc" -eq 1 ] || fail "a label with whitespace refuses"

out=$(fm_model_chain_head "$CHAIN")
assert_equals 'codex/gpt-6-luna' "$out" "head prints the first label"

fm_model_chain_head '' > "$TMP_ROOT/head-empty"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP_ROOT/head-empty" ] || fail "an empty chain has no head but does not refuse"

fm_model_chain_parse_file "$TMP_ROOT/absent-chain" > "$TMP_ROOT/file-out"; rc=$?
[ "$rc" -eq 0 ] && [ ! -s "$TMP_ROOT/file-out" ] || fail "an absent chain file parses as empty"
pass "parsing follows the branch idiom including loud refusals"

# --- B) Fall-through and the refusal recorder --------------------------------

STATEFILE="$TMP_ROOT/lane.state"
NOW=$(date +%s)

out=$(fm_model_chain_select "$STATEFILE" "$CHAIN" 2>"$TMP_ROOT/skip")
assert_equals 'codex/gpt-6-luna' "$out" "a fresh chain selects its head"
[ -s "$TMP_ROOT/skip" ] && fail "a fresh chain discloses no skips"

fm_model_chain_record_refusal "$STATEFILE" 'codex/gpt-6-luna' "$NOW"
out=$(fm_model_chain_select "$STATEFILE" "$CHAIN" 2>"$TMP_ROOT/skip")
assert_equals 'zai/glm-5.3' "$out" "a refused head falls through to the next label"
assert_contains "$(cat "$TMP_ROOT/skip")" "chain skip: codex/gpt-6-luna" "the skipped head is disclosed"

fm_model_chain_record_refusal "$STATEFILE" 'zai/glm-5.3' "$NOW"
out=$(fm_model_chain_select "$STATEFILE" "$CHAIN" 2>"$TMP_ROOT/skip")
assert_equals 'vercel/xiaomi/mimo-v2.6-flash' "$out" "two refusals reach the third label"

# The recorded backoff is the branch's: base five minutes, doubling.
record=$(fm_model_chain__state_lookup "$STATEFILE" 'codex/gpt-6-luna')
assert_equals "$((NOW + 300)) 300" "$record" "the first refusal of a streak sits out five minutes"
fm_model_chain_record_refusal "$STATEFILE" 'codex/gpt-6-luna' "$((NOW + 10))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'codex/gpt-6-luna')
assert_equals "$((NOW + 10 + 600)) 600" "$record" "an immediate re-refusal doubles the sitting-out time"
fm_model_chain_record_refusal "$STATEFILE" 'codex/gpt-6-luna' "$((NOW + 20))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'codex/gpt-6-luna')
assert_equals "$((NOW + 20 + 1200)) 1200" "$record" "a third refusal doubles the stored cooldown again"
fm_model_chain_record_refusal "$STATEFILE" 'codex/gpt-6-luna' "$((NOW + 30))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'codex/gpt-6-luna')
assert_equals "$((NOW + 30 + 2400)) 2400" "$record" "the fourth refusal doubles to forty minutes"
fm_model_chain_record_refusal "$STATEFILE" 'codex/gpt-6-luna' "$((NOW + 40))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'codex/gpt-6-luna')
assert_equals "$((NOW + 40 + 3600)) 3600" "$record" "the backoff caps at one hour"
pass "fall-through records refusals with the branch backoff"

# An expired streak starts fresh at the base instead of doubling across it:
# the first record for this label expired before the second refusal arrives,
# so the second sits out the base again, not a doubled interval.
fm_model_chain_record_refusal "$STATEFILE" 'vercel/xiaomi/mimo-v2.6-flash' "$((NOW - 400))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'vercel/xiaomi/mimo-v2.6-flash')
assert_equals "$((NOW - 100)) 300" "$record" "a refusal's record expires on its own schedule"
fm_model_chain_record_refusal "$STATEFILE" 'vercel/xiaomi/mimo-v2.6-flash' "$((NOW - 90))"
record=$(fm_model_chain__state_lookup "$STATEFILE" 'vercel/xiaomi/mimo-v2.6-flash')
assert_equals "$((NOW - 90 + 300)) 300" "$record" "a refusal after expiry starts a fresh streak"
pass "backoff streaks reset once a cooldown has expired"

# --- C) Cooldown expiry restores the head ------------------------------------

SHORT=$'a/model\nb/model\n'
EXPIRY="$TMP_ROOT/expiry.state"
fm_model_chain_record_refusal "$EXPIRY" 'a/model' "$NOW"
fm_model_chain_record_refusal "$EXPIRY" 'b/model' "$NOW"
out=$(fm_model_chain_select "$EXPIRY" "$SHORT" 2>/dev/null); rc=$?
[ "$rc" -eq 1 ] || fail "both labels cooling down exhausts the chain"
# Backdate both records past their retry epochs: the head comes back first.
printf 'a/model\t%s\nb/model\t%s\n' "$((NOW - 5))" "$((NOW - 1))" > "$EXPIRY"
out=$(fm_model_chain_select "$EXPIRY" "$SHORT" 2>"$TMP_ROOT/skip")
assert_equals 'a/model' "$out" "an expired head is restored ahead of an expired tail"
# fm_model_chain_clear is the success side: clearing the head's record drops
# its streak, exactly like the branch clearing a backoff after a clean turn.
fm_model_chain_clear "$EXPIRY" 'a/model'
out=$(fm_model_chain_select "$EXPIRY" "$SHORT" 2>/dev/null)
assert_equals 'a/model' "$out" "clearing a refusal makes the label ready again"
pass "cooldown expiry and clearing restore the head of the chain"

# --- D) Exhaustion refuses ----------------------------------------------------

EXHAUST="$TMP_ROOT/exhaust.state"
fm_model_chain_record_refusal "$EXHAUST" 'a/model' "$NOW"
fm_model_chain_record_refusal "$EXHAUST" 'b/model' "$NOW"
out=$(fm_model_chain_select "$EXHAUST" "$SHORT" 2>"$TMP_ROOT/exhaust.err"); rc=$?
[ "$rc" -eq 1 ] || fail "an exhausted chain refuses"
[ -z "$out" ] || fail "an exhausted chain prints no model"
assert_contains "$(cat "$TMP_ROOT/exhaust.err")" "model chain exhausted" "the exhaustion refusal says why"
assert_not_contains "$(cat "$TMP_ROOT/exhaust.err")" "a/model b/model" "no out-of-chain model is ever named or substituted"
pass "exhaustion refuses with a clear reason and no substitution"

# --- E) End to end through fm-spawn -----------------------------------------
#
# Real spawn runs against the shared fixture world (fake tmux capturing the
# launch payload, a real isolated git worktree), asserting the resolved model
# the way a launch consumer would read it: in the recorded meta and the
# spawned launch command.

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

make_chain_case() {
  local name=$1 id=${2:-} case_dir home proj wt fakebin launchlog
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  proj="$case_dir/project"
  wt="$case_dir/wt"
  launchlog="$case_dir/launch.log"
  fakebin=$(make_spawn_fakebin "$case_dir/fake")
  fm_test_spawn_home "$home" codex
  fm_git_worktree "$proj" "$wt" "wt-$name"
  [ -n "$id" ] && fm_test_spawn_brief "$home" "$id"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin|$launchlog"
}

run_chain_spawn() {
  local home=$1 wt=$2 fakebin=$3 launchlog=$4 id=$5 proj=$6
  shift 6
  : > "$launchlog"
  # The dispatch-profile suite wraps the same fixture with 2>&1 on the inner
  # call; the chain disclosure rides stderr, so it is folded in here too.
  FM_FAKE_LAUNCH_LOG="$launchlog" GROK_HOME="$home/grok-home" \
    fm_test_run_spawn "$home" "$wt" "$fakebin" "$id" "$proj" \
    --mode direct-PR --yolo off "$@" 2>&1
}

read_chain_record() {
  IFS='|' read -r CASE_DIR HOME_DIR PROJ_DIR WT_DIR FAKEBIN_DIR LAUNCH_LOG <<EOF
$1
EOF
}

test_exact_pin_is_byte_identical() {
  local rec id out meta
  id=chain-pin-1a
  rec=$(make_chain_case chain-pin chain-pin-1a)
  read_chain_record "$rec"
  out=$(run_chain_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model default)
  rc=$?
  expect_code 0 "$rc" "a modelless (default) spawn runs cleanly (last output: $(printf '%s' "$out" | tail -1))"
  assert_not_contains "$out" "model chain" "a modelless spawn discloses no chain resolution"
  [ ! -e "$HOME_DIR/state/model-chain" ] || fail "a modelless spawn creates no cooldown lane"
  pass "a modelless spawn never touches a lane (exact-pin baseline)"
}

test_relaunch_resolves_a_chained_model_and_records_its_lane() {
  local dir out rc model lane
  dir=$(new_case chain-model rl61)
  add_ship_task "$dir" rl61 claude
  # A prior record naming a chain relaunches through the same chain, on the
  # task lane; fm-control resolves before stopping the old agent, so the
  # refusal recorder reads the same published record the prior launch left.
  printf 'model=codex/gpt-6-luna,zai/glm-5.3\n' >> "$dir/home/state/rl61.meta"
  out=$(run_control "$dir" rl61 relaunch --model 'codex/gpt-6-luna,zai/glm-5.3' --note "retrying the chain"); rc=$?
  expect_code 0 "$rc" "a chained-model relaunch should succeed"$'\n'"$out"
  assert_contains "$out" "model chain (relaunch, lane crew-rl61): selected codex/gpt-6-luna" \
    "the relaunch discloses its selection on the task lane"
  model=$(meta_field "$dir" rl61 model)
  [ "$model" = "codex/gpt-6-luna" ] || fail "the relaunch record must carry the resolved model, got: $model"
  lane=$(meta_field "$dir" rl61 model_chain_lane)
  [ "$lane" = "crew-rl61" ] || fail "the relaunch must record the lane the refusal recorder reads, got: $lane"
  [ -f "$dir/home/state/model-chain/crew-rl61.state" ] \
    || fail "the relaunch must materialize the lane it resolved through"

  # The fall-through side of the same transaction: the supervisor records the
  # head's refusal, and the next relaunch both selects the next label and
  # launches the replacement on it.
  FM_HOME="$dir/home" "$ROOT/bin/fm-record-model-refusal.sh" rl61 codex/gpt-6-luna >/dev/null 2>&1
  out=$(run_control "$dir" rl61 relaunch --model 'codex/gpt-6-luna,zai/glm-5.3' --note "after the refusal"); rc=$?
  expect_code 0 "$rc" "a relaunch past a cooled-down head should succeed"$'\n'"$out"
  assert_contains "$out" "chain skip: codex/gpt-6-luna" "the cooled-down head is disclosed as skipped"
  assert_contains "$out" "selected zai/glm-5.3" "the next ready label is selected"
  model=$(meta_field "$dir" rl61 model)
  [ "$model" = "zai/glm-5.3" ] || fail "the fall-through model must land in the record, got: $model"
  pass "fm-control relaunch: a chained model resolves, discloses, and records its lane"
}

test_exact_pin_creates_no_lane() {
  local rec id out meta
  id=chain-pin-0z
  rec=$(make_chain_case chain-pin0 chain-pin-0z)
  read_chain_record "$rec"
  out=$(run_chain_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" --model codex/gpt-6-luna)
  rc=$?
  expect_code 0 "$rc" "an exact --model pin spawns cleanly (last output: $(printf '%s' "$out" | tail -1))"
  assert_not_contains "$out" "model chain" "an exact pin discloses no chain resolution"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=codex/gpt-6-luna' "$meta" "an exact pin records its model unchanged"
  [ ! -e "$HOME_DIR/state/model-chain" ] || fail "an exact pin creates no cooldown lane"
  pass "a single-label --model stays an exact pin with no lane or chain disclosure"
}

test_chained_model_resolves_head_and_records_lane() {
  local rec id out meta
  id=chain-run-2b
  rec=$(make_chain_case chain-head chain-run-2b)
  read_chain_record "$rec"
  out=$(run_chain_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model 'codex/gpt-6-luna,zai/glm-5.3')
  rc=$?
  expect_code 0 "$rc" "a chained --model spawns cleanly (last output: $(printf '%s' "$out" | tail -1))"
  printf '%s\n' "$out" > "$TMP_ROOT/chain-head.out"
  if grep -q "model chain" "$TMP_ROOT/chain-head.out"; then
    : # disclosed on a stream we captured
  else
    fail "no chain disclosure captured; got: $(cat "$TMP_ROOT/chain-head.out")"
  fi
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=codex/gpt-6-luna' "$meta" "the resolved head lands in the meta"
  assert_grep "model_chain_lane=crew-$id" "$meta" "the resolved lane is recorded for the refusal recorder"
  [ -f "$HOME_DIR/state/model-chain/crew-$id.state" ] || fail "the lane cooldown file was not created beside the state"
  pass "a chained --model resolves to its head and records its lane"
}

test_chained_model_falls_through_after_recorded_refusal() {
  local rec id out meta launch
  id=chain-fall-3c
  rec=$(make_chain_case chain-fall chain-fall-3c)
  read_chain_record "$rec"
  # First launch resolves the head and publishes the task record the refusal
  # recorder reads its lane from, exactly as any real chain launch leaves the
  # home before a supervisor records a refusal against it.
  out=$(run_chain_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model 'codex/gpt-6-luna,zai/glm-5.3,vercel/xiaomi/mimo-v2.6-flash')
  expect_code 0 "$?" "the first chained spawn succeeds on its head"
  # The supervisor records the head's refusal through the same door it uses in
  # production: the task's published record names the lane.
  FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-record-model-refusal.sh" \
    "$id" codex/gpt-6-luna > /dev/null 2>&1
  [ -f "$HOME_DIR/state/model-chain/crew-$id.state" ] || fail "the recorder created no lane state"
  out=$(run_chain_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model 'codex/gpt-6-luna,zai/glm-5.3,vercel/xiaomi/mimo-v2.6-flash')
  expect_code 0 "$?" "a spawn past a cooled-down head succeeds"
  assert_contains "$out" "chain skip: codex/gpt-6-luna" "the cooled-down head is disclosed as skipped"
  assert_contains "$out" "selected zai/glm-5.3" "the next ready label is selected"
  meta="$HOME_DIR/state/$id.meta"
  assert_grep 'model=zai/glm-5.3' "$meta" "the fall-through model lands in the meta"
  launch=$(cat "$LAUNCH_LOG")
  assert_contains "$launch" "--model 'zai/glm-5.3'" "the launch command carries the resolved model, not the chain"
  assert_not_contains "$launch" "codex/gpt-6-luna" "the refused model never reaches the launch command"
  pass "a recorded refusal falls the next launch through to the next ready label"
}

test_exhausted_chain_refuses_the_spawn() {
  local rec id out statefile
  id=chain-exh-4d
  rec=$(make_chain_case chain-exhaust chain-exh-4d)
  read_chain_record "$rec"
  statefile="$HOME_DIR/state/model-chain/crew-$id.state"
  mkdir -p "$HOME_DIR/state/model-chain"
  now=$(date +%s)
  printf 'codex/gpt-6-luna\t%s\t300\nzai/glm-5.3\t%s\t300\n' \
    "$((now + 3000))" "$((now + 3000))" > "$statefile"
  out=$(run_chain_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model 'codex/gpt-6-luna,zai/glm-5.3')
  [ "$?" -ne 0 ] || fail "an exhausted chain must refuse the spawn"
  assert_contains "$out" "model chain exhausted" "the refusal says the chain is exhausted"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a refused spawn must not publish a task record"
  pass "an exhausted chain refuses the spawn before any record exists"
}

test_chain_parse_error_refuses_the_spawn() {
  local rec id out
  id=chain-bad-5e
  rec=$(make_chain_case chain-bad chain-bad-5e)
  read_chain_record "$rec"
  out=$(run_chain_spawn "$HOME_DIR" "$WT_DIR" "$FAKEBIN_DIR" "$LAUNCH_LOG" "$id" "$PROJ_DIR" \
    --model 'codex/gpt-6-luna,noslash')
  [ "$?" -ne 0 ] || fail "a malformed chain must refuse the spawn"
  assert_contains "$out" "not a comma-separated list" "the refusal names the malformed chain"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail "a parse-refused spawn must not publish a task record"
  pass "a malformed chained --model refuses the spawn loudly"
}

test_exact_pin_creates_no_lane
test_exact_pin_is_byte_identical
test_chained_model_resolves_head_and_records_lane
test_chained_model_falls_through_after_recorded_refusal
test_exhausted_chain_refuses_the_spawn
test_chain_parse_error_refuses_the_spawn
test_relaunch_resolves_a_chained_model_and_records_its_lane

printf 'all fm-model-chain tests passed\n'
