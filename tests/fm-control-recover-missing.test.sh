#!/usr/bin/env bash
# fm-control.sh recover-missing: the transactional recreate-the-terminal verb.
#
# The verb exists for a task whose recorded terminal is GONE rather than dead:
# `relaunch` refuses a missing endpoint and fm-spawn --relaunch adopts only a
# surviving agent-free one, so neither can bring such a task back. These tests
# drive the real script end to end against a stubbed session provider (no real
# agent), pinning:
#   1. The success path: a missing endpoint is recreated under the recorded
#      handle, the launch is handed to the existing owner, and the task keeps
#      its endpoint, worktree, and instructions - now carrying the note.
#   2. Every refusal the operation promises, each of which must leave the
#      durable record and the instructions byte-identical: a live or ambiguous
#      endpoint, an absent local copy, and a pool slot claimed by another task
#      or carrying an unreadable claim. Uncommitted work is deliberately NOT
#      among them: it is the normal state of a task worth rescuing, and the
#      rescue must leave every such change exactly where it found it.
#   3. The runtime is switchable here only through an explicit replacement
#      profile: --harness/--model/--effort name a replacement runtime in the
#      same transaction, while an unqualified recovery continues the recorded
#      profile.
#   4. The backends recovery refuses, and what it tells the operator when the
#      launch handoff fails after the terminal is already back.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"

TMP_ROOT=$(fm_test_tmproot fm-control-recover-missing)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

recover_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap 'recover_cleanup; fm_test_cleanup' EXIT

# --- fake session provider --------------------------------------------------
#
# Each task is a fake stream endpoint driven by the fake-dir model in
# tests/fixtures.sh (fm_test_fake_dir_*), as in tests/fm-control.test.sh:
# command, becomes, cwd and windows under $dir/fake steer the endpoint, and
# literal and keys record what it received. Emptying windows makes the hub
# forget the endpoint, so it reads `missing`. A stream recovery cannot bring
# that endpoint back: it creates a NEW one (the agent stub registers it, same
# fm-<id> label, the worktree as its cwd) and rebinds the record to it, so
# run_control follows the record's window= afterwards. The new endpoint inherits
# the fake dir through the hub's endpoint defaults: its `becomes`, its cwd, and
# these fault variables:
#   FM_FAKE_SHELL_BUSY_READS  the new endpoint's first n process reads show an
#                             unattributable foreground (busy_reads), a shell
#                             still running its rc files
#   FM_FAKE_META_RACE[_LINE]  the first request made of the new endpoint
#                             appends LINE to that file (on_request), another
#                             writer landing mid-recreation
#   FM_FAKE_NEW_ENDPOINT_FAIL the agent fails to register, so nothing is created
#   FM_FAKE_LOSE_HUB          ...and the hub stops answering task routes too
make_fakebin() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  # Exit-0 stand-ins for every launchable worker harness, so a launch resolves
  # its executable here rather than whatever the developer has installed.
  fm_fake_exit0 "$fb" deck
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

# new_endpoint_defaults <case-dir>: the knobs every endpoint created from now on
# starts with (fm_test_fake_stream_defaults), from the fake dir and the fault
# variables above.
new_endpoint_defaults() {  # <case-dir>
  local dir=$1 hook=''
  if [ -n "${FM_FAKE_META_RACE:-}" ]; then
    hook="$dir/fake/meta-race"
    cat > "$hook" <<SH
#!/usr/bin/env bash
[ -e '$dir/fake/meta-race.done' ] && exit 0
: > '$dir/fake/meta-race.done'
printf '%s\n' '${FM_FAKE_META_RACE_LINE:?}' >> '$FM_FAKE_META_RACE'
SH
    chmod +x "$hook"
  fi
  jq -nc --arg b "$(cat "$dir/fake/becomes" 2>/dev/null)" --arg c "$(cat "$dir/fake/cwd" 2>/dev/null)" \
    --argjson n "${FM_FAKE_SHELL_BUSY_READS:-0}" --arg h "$hook" \
    '{becomes: $b, busy_reads: $n} + (if $c == "" then {} else {cwd: $c} end)
     + (if $h == "" then {} else {on_request: $h} end)'
}

# created_endpoint_count <case-dir> <id>: open endpoints labelled fm-<id> other
# than the one the task was recorded on - the ones a recovery created.
created_endpoint_count() {  # <case-dir> <id>
  fm_test_fake_stream_endpoints | jq --arg l "fm-$2" --arg o "$(cat "$1/fake/orig" 2>/dev/null)" \
    '[.endpoints[] | select(.label == $l and .closed_at == null and .endpoint_id != $o)] | length'
}

assert_created() {  # <case-dir> <id> <message>
  [ "$(created_endpoint_count "$1" "$2")" -ge 1 ] || fail "$3"
}

# record_without_binding <meta>: the record minus the lines naming its stream
# endpoint. A stream recovery binds the record to the endpoint it created as
# soon as that endpoint exists - a later handoff failure leaves the bare shell
# there for 'relaunch' to act on - and the rebind rewrites those lines at the
# end of the record (bin/fm-endpoint-rebind-lib.sh), so "the prior record" is
# everything else, in its order.
record_without_binding() {  # <meta>
  grep -v '^\(window\|backend\|stream_hub\|stream_endpoint_id\)=' "$1"
}

# assert_bound_to_created <case-dir> <id>: the record names an endpoint the
# recovery created, not the one it lost.
assert_bound_to_created() {  # <case-dir> <id>
  local window
  window=$(grep '^window=' "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-)
  [ "$window" != "$FM_TEST_STREAM_TAG:$(cat "$1/fake/orig")" ] \
    || fail "the record still names the lost endpoint after the terminal was recreated"
  [ "$(grep -c '^backend=stream$' "$1/home/state/$2.meta")" = 1 ] \
    || fail "the rebound record must stay on exactly one stream backend line"
  fm_test_fake_stream_endpoints | jq -e --arg e "${window##*:}" --arg l "fm-$2" \
    '.endpoints[] | select(.endpoint_id == $e and .label == $l)' >/dev/null \
    || fail "the record names $window, which is not the endpoint the recovery created"
}

# new_case <name> [id] -> echoes a case dir whose endpoint currently holds a
# live deck agent. A test that wants the MISSING precondition calls
# make_endpoint_missing.
new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'fm-deck-worker' > "$dir/fake/command"
  printf 'fm-deck-worker' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  make_fakebin "$dir"
  printf '%s\n' "$dir"
}

# add_ship_task <case-dir> <id> [worktree]: a deck ship task recorded on its
# fake stream endpoint. The worktree defaults to <case-dir>/wt; a pool case
# passes its slot checkout instead.
add_ship_task() {
  local dir=$1 id=$2 wt=${3:-$1/wt}
  local home="$dir/home" proj="$dir/proj"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise missing-endpoint recovery for $id.

## Firstmate spec
Recreate the terminal without touching the local copy.
EOF
  {
    fm_test_fake_dir_task "$dir/fake" "$home/state" "$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=deck"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$dir/tasktmp"
    echo "model=default"
    echo "effort=default"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  sed 's/.*://' "$dir/fake/target" > "$dir/fake/orig"
  TASK_TMPS+=("$dir/tasktmp")
}

# The hub forgets the recorded endpoint, so it answers 404 for it and the
# recovery-grade classifier reports `missing` once its rejoin grace runs out.
make_endpoint_missing() {  # <case-dir>
  : > "$1/fake/windows"
}

# A Treehouse pool slot, shaped the way fm_treehouse_pool_slot recognizes one:
# <pool>/treehouse-state.json beside <pool>/<slot>/<checkout>, with the slot's
# Firstmate ownership claim at <pool>/<slot>/.fm-slot-owner.
pool_slot_worktree() {  # <case-dir>
  local pool="$1/pool"
  mkdir -p "$pool/1"
  printf '{}\n' > "$pool/treehouse-state.json"
  printf '%s\n' "$pool/1/checkout"
}

run_control() {  # <case-dir> <id> <args...>
  local dir=$1 id=$2 rc window; shift
  # Recovery reaches the launch owner through fm-spawn.sh, so it runs against
  # a throwaway HOME: nothing a launch writes under the user's home may reach
  # the developer's real one.
  mkdir -p "$dir/user-home"
  fm_test_fake_dir_push "$dir/fake"
  fm_test_fake_stream_defaults "$(new_endpoint_defaults "$dir")"
  # A created endpoint logs what it receives to the fake dir's log too, so
  # literal and keys keep recording every text and key sent to the task.
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    HOME="$dir/user-home" \
    FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT="${FM_CONTROL_EXIT_WAIT:-0.05}" \
    FM_CONTROL_LAUNCH_WAIT=0.05 \
    FM_FAKE_LAUNCH_LOG="$dir/fake/log" \
    FM_FAKE_AGENT_REGISTER_FAIL="${FM_FAKE_NEW_ENDPOINT_FAIL:-}" \
    FM_FAKE_AGENT_BREAK_HUB="${FM_FAKE_LOSE_HUB:-}" \
    "$CONTROL" "$@" 2>&1
  rc=$?
  fm_test_fake_stream_defaults '{}'
  # A case that lost the hub (FM_FAKE_LOSE_HUB) gives it back to the next one.
  curl -fsS -m 10 --config <(printf 'header = "Authorization: Bearer %s"\n' "$FM_STREAM_TOKEN") -X POST -H 'Content-Type: application/json' \
    --data-binary '{"task_routes_unavailable": false}' "$FM_TEST_STREAM_URL/v1/test/config" >/dev/null
  # Follow a recovery onto the endpoint it rebound the record to.
  window=$(grep '^window=' "$dir/home/state/$id.meta" 2>/dev/null | tail -1 | cut -d= -f2-)
  if [ -n "$window" ] && [ "$window" != "$(cat "$dir/fake/target" 2>/dev/null)" ]; then
    printf '%s\n' "$window" > "$dir/fake/target"
    printf 'fm-%s\n' "$id" > "$dir/fake/windows"
  fi
  fm_test_fake_dir_pull "$dir/fake"
  return "$rc"
}

meta_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.meta" | tail -1 | cut -d= -f2-
}

journal_field() {  # <case-dir> <id> <key>
  grep "^$3=" "$1/home/state/$2.control-relaunch" | tail -1 | cut -d= -f2-
}

# --- 1. the missing-terminal success path -----------------------------------

test_recover_missing_recreates_the_terminal_and_launches_the_replacement() {
  local dir out rc brief_before
  dir=$(new_case success rm1)
  add_ship_task "$dir" rm1
  brief_before=$(cat "$dir/home/data/rm1/brief.md")
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" rm1 recover-missing --note "the terminal was closed out from under it"); rc=$?
  expect_code 0 "$rc" "recovering a missing endpoint should succeed"$'\n'"$out"
  assert_contains "$out" "recovered rm1 harness=deck from=deck" "the outcome should name the recovered task and its runtime"
  assert_contains "$out" "endpoint=$(meta_field "$dir" rm1 window)" "the outcome should name the recreated endpoint"

  assert_created "$dir" rm1 "the missing terminal should have been recreated under its recorded name"
  assert_grep "encode launch-brief" "$dir/fake/literal" "the launch should have been handed to the existing owner"

  # A stream endpoint cannot be recreated under its old id: the record names
  # the new endpoint, on the same hub, for the same task.
  [ "$(meta_field "$dir" rm1 window)" != "$FM_TEST_STREAM_TAG:$(cat "$dir/fake/orig")" ] \
    || fail "the record must be rebound to the recreated endpoint"
  [ "$(meta_field "$dir" rm1 window)" = "$FM_TEST_STREAM_TAG:$(meta_field "$dir" rm1 stream_endpoint_id)" ] \
    || fail "window= and stream_endpoint_id= must name the same recreated endpoint"
  [ "$(meta_field "$dir" rm1 endpoint_task_id)" = rm1 ] || fail "the task binding must survive recovery"
  [ "$(meta_field "$dir" rm1 worktree)" = "$dir/wt" ] \
    || fail "the local copy must be reused, never reallocated"
  [ "$(meta_field "$dir" rm1 harness)" = deck ] || fail "the recorded harness must survive recovery"
  [ "$(meta_field "$dir" rm1 kind)" = ship ] || fail "kind must survive recovery"
  [ "$(journal_field "$dir" rm1 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  assert_grep "the terminal was closed out from under it" "$dir/home/data/rm1/brief.md" \
    "the progress note must land in the instructions the replacement reads"
  case "$(cat "$dir/home/data/rm1/brief.md")" in
    "$brief_before"*) : ;;
    *) fail "recovery must append to the original instructions, never rewrite them" ;;
  esac
  pass "fm-control recover-missing: a missing terminal is recreated under its recorded handle and relaunched"
}

test_recover_missing_waits_for_the_recreated_shell_to_settle() {
  local dir out rc
  dir=$(new_case cold-start rm21)
  add_ship_task "$dir" rm21
  make_endpoint_missing "$dir"

  # A cold rescue on a real machine: the recreated pane's login shell is still
  # running its rc files, so the endpoint reads `ambiguous` for a while. The
  # launch owner takes ONE un-retried state read and requires `dead`, so
  # handing the terminal over before it settles fails the whole rescue.
  out=$(FM_FAKE_SHELL_BUSY_READS=4 FM_CONTROL_EXIT_WAIT=5 \
    run_control "$dir" rm21 recover-missing --note "the terminal was closed out from under it"); rc=$?
  expect_code 0 "$rc" "a still-starting shell must not fail the rescue"$'\n'"$out"
  assert_contains "$out" "recovered rm21 harness=deck" "the rescue should complete in one command"
  assert_grep "encode launch-brief" "$dir/fake/literal" \
    "the launch should have been handed over only once the terminal read agent-free"
  [ "$(journal_field "$dir" rm21 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  pass "fm-control recover-missing: a recreated terminal whose shell is still starting is waited out, not handed over"
}

test_recover_missing_refuses_a_terminal_that_never_settles() {
  local dir out rc
  dir=$(new_case never-settles rm22)
  add_ship_task "$dir" rm22
  make_endpoint_missing "$dir"

  # The recreated pane never reaches an agent-free shell within the budget.
  out=$(FM_FAKE_SHELL_BUSY_READS=100000 run_control "$dir" rm22 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a terminal that never settles must refuse"$'\n'"$out"
  assert_contains "$out" "did not settle to an agent-free shell" \
    "the refusal should name what it waited for"
  ! grep -Fq "encode launch-brief" "$dir/fake/literal" \
    || fail "an unsettled terminal must never be handed to the launch owner"
  # The terminal IS back - only the handover failed - so the rollback must not
  # tell the operator the recreation never happened. The pane was just measured
  # as NOT agent-free, so the only advice the operator gets is the refusal's own
  # qualified line; the rollback must not duplicate it with an unqualified one.
  assert_created "$dir" rm22 "the terminal should already have been recreated"
  assert_contains "$out" "recreated the terminal but could not hand it over" \
    "the rollback must admit the terminal now exists"
  assert_contains "$out" "once its shell is idle bring the worker up with 'relaunch'" \
    "the refusal should keep the qualified advice for the pane it measured as busy"
  [ "$(grep -c "relaunch'" <<<"$out")" = 1 ] \
    || fail "the rollback must not repeat the refusal's relaunch advice unqualified"
  pass "fm-control recover-missing: a recreated terminal that never goes agent-free refuses instead of launching into it"
}

# --- 2. refusals ------------------------------------------------------------

# assert_nothing_changed <case-dir> <id> <meta-before> <brief-before>
assert_nothing_changed() {
  local dir=$1 id=$2 meta_before=$3 brief_before=$4
  [ "$(cat "$dir/home/state/$id.meta")" = "$meta_before" ] \
    || fail "a refused recovery must leave the durable record byte-identical"
  [ "$(cat "$dir/home/data/$id/brief.md")" = "$brief_before" ] \
    || fail "a refused recovery must leave the instructions byte-identical"
  [ "$(created_endpoint_count "$dir" "$id")" = 0 ] \
    || fail "a refused recovery must not create a terminal"
  ! grep -Fq "encode launch-brief" "$dir/fake/literal" \
    || fail "a refused recovery must not launch an agent"
}

test_recover_missing_verified_deck_recreates_the_endpoint() {
  local dir out rc
  dir=$(new_case deck-recovery rm22)
  add_ship_task "$dir" rm22
  sed -i.bak 's/^harness=.*/harness=deck/' "$dir/home/state/rm22.meta"
  rm -f "$dir/home/state/rm22.meta.bak"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/deck"
  chmod +x "$dir/fakebin/deck"
  printf deck > "$dir/fake/becomes"
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" rm22 recover-missing --note "recover Deck"); rc=$?
  expect_code 0 "$rc" "verified Deck recovery should succeed: $out"
  [ "$(meta_field "$dir" rm22 harness)" = deck ] || fail "Deck recovery changed the recorded harness"
  [ "$(cat "$dir/fake/command")" = deck ] || fail "Deck recovery did not launch the replacement agent"
  assert_created "$dir" rm22 "Deck recovery did not recreate the endpoint"
  pass "fm-control recover-missing: verified Deck recreates and relaunches its endpoint"
}

test_recover_missing_refuses_a_live_endpoint() {
  local dir out rc meta_before brief_before
  dir=$(new_case alive rm2)
  add_ship_task "$dir" rm2
  meta_before=$(cat "$dir/home/state/rm2.meta")
  brief_before=$(cat "$dir/home/data/rm2/brief.md")

  out=$(run_control "$dir" rm2 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a live endpoint must refuse"$'\n'"$out"
  assert_contains "$out" "endpoint reads 'alive'" "the refusal should name the observed state"
  assert_nothing_changed "$dir" rm2 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: a live endpoint refuses and changes nothing"
}

test_recover_missing_refuses_an_ambiguous_endpoint() {
  local dir out rc meta_before brief_before
  dir=$(new_case ambiguous rm3)
  add_ship_task "$dir" rm3
  # A foreground process that is neither a known agent nor a shell: the
  # classifier can prove neither presence nor absence of an agent.
  printf 'mystery' > "$dir/fake/command"
  meta_before=$(cat "$dir/home/state/rm3.meta")
  brief_before=$(cat "$dir/home/data/rm3/brief.md")

  out=$(run_control "$dir" rm3 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "an ambiguous endpoint must refuse"$'\n'"$out"
  assert_contains "$out" "endpoint reads 'ambiguous'" "the refusal should name the observed state"
  assert_nothing_changed "$dir" rm3 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: an ambiguous endpoint refuses and changes nothing"
}

test_recover_missing_refuses_an_absent_local_copy() {
  local dir out rc meta_before brief_before
  dir=$(new_case absent-wt rm4)
  add_ship_task "$dir" rm4
  make_endpoint_missing "$dir"
  meta_before=$(cat "$dir/home/state/rm4.meta")
  brief_before=$(cat "$dir/home/data/rm4/brief.md")
  rm -rf "$dir/wt"

  out=$(run_control "$dir" rm4 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "an absent local copy must refuse"$'\n'"$out"
  assert_contains "$out" "is absent; refusing to recover without the local copy" \
    "the refusal should name the missing local copy"
  assert_nothing_changed "$dir" rm4 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: an unavailable local copy refuses rather than reallocating one"
}

test_recover_missing_refuses_a_pool_slot_owned_by_another_task() {
  local dir wt out rc meta_before brief_before
  dir=$(new_case slot-other rm6)
  wt=$(pool_slot_worktree "$dir")
  add_ship_task "$dir" rm6 "$wt"
  make_endpoint_missing "$dir"
  printf 'task=%s\nhome=%s\n' other-task "$dir/home" > "$(dirname "$wt")/.fm-slot-owner"
  meta_before=$(cat "$dir/home/state/rm6.meta")
  brief_before=$(cat "$dir/home/data/rm6/brief.md")

  out=$(run_control "$dir" rm6 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a reassigned pool slot must refuse"$'\n'"$out"
  assert_contains "$out" "claimed by task other-task" "the refusal should name the claiming task"
  assert_nothing_changed "$dir" rm6 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: a pool slot claimed by another task refuses rather than tangling ownership"
}

test_recover_missing_refuses_an_unreadable_pool_slot_claim() {
  local dir wt out rc meta_before brief_before
  dir=$(new_case slot-unsafe rm7)
  wt=$(pool_slot_worktree "$dir")
  add_ship_task "$dir" rm7 "$wt"
  make_endpoint_missing "$dir"
  # A claim that exists but names no task at all: unreadable, not absent.
  printf 'home=%s\n' "$dir/home" > "$(dirname "$wt")/.fm-slot-owner"
  meta_before=$(cat "$dir/home/state/rm7.meta")
  brief_before=$(cat "$dir/home/data/rm7/brief.md")

  out=$(run_control "$dir" rm7 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "an unreadable pool-slot claim must refuse"$'\n'"$out"
  assert_contains "$out" "unreadable owner claim" "the refusal should name the unreadable claim"
  assert_nothing_changed "$dir" rm7 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: an unreadable pool-slot claim refuses rather than risking a conflict"
}

test_recover_missing_keeps_its_own_pool_slot() {
  local dir wt out rc
  dir=$(new_case slot-mine rm8)
  wt=$(pool_slot_worktree "$dir")
  add_ship_task "$dir" rm8 "$wt"
  make_endpoint_missing "$dir"
  printf 'task=%s\nhome=%s\n' rm8 "$dir/home" > "$(dirname "$wt")/.fm-slot-owner"

  out=$(run_control "$dir" rm8 recover-missing --note "recover"); rc=$?
  expect_code 0 "$rc" "a task's own pool slot should recover"$'\n'"$out"
  [ "$(meta_field "$dir" rm8 worktree)" = "$wt" ] \
    || fail "the recovered task must keep its own pool slot"
  [ "$(cat "$(dirname "$wt")/.fm-slot-owner")" = "$(printf 'task=rm8\nhome=%s' "$dir/home")" ] \
    || fail "recovery must leave the slot's own ownership claim untouched"
  pass "fm-control recover-missing: a task's own pool slot recovers with its claim untouched"
}

test_failed_recreation_rolls_the_progress_note_back() {
  local dir out rc meta_before brief_before
  dir=$(new_case recreate-fail rm11)
  add_ship_task "$dir" rm11
  make_endpoint_missing "$dir"
  meta_before=$(cat "$dir/home/state/rm11.meta")
  brief_before=$(cat "$dir/home/data/rm11/brief.md")

  # The note is appended to the instructions BEFORE the terminal is recreated,
  # and the agent is never touched in any phase of a recovery, so a recreation
  # that fails must put the instructions back. Otherwise every retry after the
  # operator fixes the session provider stacks another progress note.
  out=$(FM_FAKE_NEW_ENDPOINT_FAIL=1 run_control "$dir" rm11 recover-missing --note "first attempt"); rc=$?
  expect_code 1 "$rc" "a failed recreation must refuse"$'\n'"$out"
  assert_contains "$out" "failed while recreating the terminal" "the refusal should name the phase it failed in"
  # Nothing was created here: the window never appeared, so the endpoint still
  # reads missing and the rollback must not claim a terminal is back.
  assert_not_contains "$out" "recreated the terminal" \
    "a recreation that created nothing must not claim a terminal now exists"
  [ "$(cat "$dir/home/data/rm11/brief.md")" = "$brief_before" ] \
    || fail "a failed recreation must roll the progress note back out of the instructions"
  [ "$(cat "$dir/home/state/rm11.meta")" = "$meta_before" ] \
    || fail "a failed recreation must leave the durable record exactly as it found it"

  out=$(run_control "$dir" rm11 recover-missing --note "second attempt"); rc=$?
  expect_code 0 "$rc" "the retry after the provider recovers should succeed"$'\n'"$out"
  [ "$(grep -c '^## Progress note' "$dir/home/data/rm11/brief.md")" = 1 ] \
    || fail "a retry must leave exactly one progress note in the instructions"
  assert_no_grep "first attempt" "$dir/home/data/rm11/brief.md" \
    "the rolled-back attempt's note must not survive into the retry"
  pass "fm-control recover-missing: a failed recreation rolls the progress note back so retries do not stack"
}

test_failed_recreation_keeps_a_concurrent_record_write() {
  local dir out rc
  dir=$(new_case recreate-race rm24)
  add_ship_task "$dir" rm24
  make_endpoint_missing "$dir"

  # The recreating phase writes NOTHING to the durable record - the journal,
  # the progress note and the instructions are separate files, and recreating
  # the window and waiting for its shell to settle write nothing at all - so a
  # rollback that restored a snapshot of it could only ever revert somebody
  # ELSE's write, over a phase that spans window creation plus the settle wait.
  #
  # This is that race, made deterministic: a delivery task's terminal dies, the
  # operator runs recover-missing, and while the recreated shell is settling
  # bin/fm-pr-check.sh arms the merge poll and appends `pr=` under the per-task
  # record lock. The shell never settles, so the rescue refuses - and the line
  # must still be there. A restore would drop it, and the poll's sidecar and
  # registration would keep passing their own identity checks while the merge
  # notification was silently revoked.
  out=$(FM_FAKE_SHELL_BUSY_READS=100000 \
    FM_FAKE_META_RACE="$dir/home/state/rm24.meta" \
    FM_FAKE_META_RACE_LINE='pr=https://github.com/o/r/pull/7' \
    run_control "$dir" rm24 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a terminal that never settles must refuse"$'\n'"$out"
  assert_created "$dir" rm24 \
    "the terminal should have been recreated before the settle wait timed out"
  grep -qxF 'pr=https://github.com/o/r/pull/7' "$dir/home/state/rm24.meta" \
    || fail "a refused recovery must not revert a record write it never made"
  [ "$(journal_field "$dir" rm24 phase)" = failed:recreating ] \
    || fail "the journal must record the phase the rescue failed in"
  [ "$(journal_field "$dir" rm24 rollback)" = instructions-restored ] \
    || fail "the journal must not claim a record rollback the arm does not perform"
  pass "fm-control recover-missing: a failed recreation leaves a concurrent record write alone"
}

test_unreadable_endpoint_after_a_failed_recreation_claims_nothing() {
  local dir out rc
  dir=$(new_case recreate-unreadable rm23)
  add_ship_task "$dir" rm23
  make_endpoint_missing "$dir"

  # The window creation fails and the session provider then goes unreachable,
  # so the rollback's own read comes back `unreadable`. Nothing proves a window
  # exists, so it must not tell the operator one was recreated.
  out=$(FM_FAKE_NEW_ENDPOINT_FAIL=1 FM_FAKE_LOSE_HUB=1 \
    run_control "$dir" rm23 recover-missing --note "first attempt"); rc=$?
  expect_code 1 "$rc" "a failed recreation must refuse"$'\n'"$out"
  assert_contains "$out" "failed while recreating the terminal" \
    "an endpoint that proves nothing must keep the nothing-created wording"
  assert_not_contains "$out" "recreated the terminal" \
    "an unreadable endpoint must not be reported as a recreated terminal"
  pass "fm-control recover-missing: an unreadable endpoint after a failed recreation claims no terminal exists"
}

test_launch_failure_never_claims_an_agent_was_stopped() {
  local dir out rc before
  dir=$(new_case launch-fail rm12)
  add_ship_task "$dir" rm12
  make_endpoint_missing "$dir"
  before=$(record_without_binding "$dir/home/state/rm12.meta")
  # The recreated shell reports a cwd outside the recorded local copy, so the
  # launch owner refuses AFTER the terminal has already been recreated.
  printf '%s' "$dir/proj" > "$dir/fake/cwd"

  out=$(run_control "$dir" rm12 recover-missing --note "carry this forward"); rc=$?
  expect_code 1 "$rc" "a failed launch handoff should fail closed"$'\n'"$out"
  assert_created "$dir" rm12 "the terminal should already have been recreated"
  assert_contains "$out" "no agent was ever stopped" \
    "the failure must not claim a recovery stopped an agent it never touched"
  assert_contains "$out" "retry with 'relaunch'" \
    "the failure should name the verb that acts on the bare shell it left behind"
  assert_contains "$out" "$dir/wt" "the failure should say where the work is preserved"
  [ "$(record_without_binding "$dir/home/state/rm12.meta")" = "$before" ] \
    || fail "a failed launch handoff must keep the prior durable record:"$'\n'"$(diff <(printf '%s\n' "$before") <(record_without_binding "$dir/home/state/rm12.meta"))"
  assert_bound_to_created "$dir" rm12
  [ "$(journal_field "$dir" rm12 phase)" = "failed:launching" ] \
    || fail "the journal should record the failed phase"
  assert_grep "carry this forward" "$dir/home/data/rm12/brief.md" \
    "the progress note must survive a post-recreation failure so the retry still has it"
  pass "fm-control recover-missing: a failed launch handoff reports the bare shell it left, not a stop that never happened"
}

# --- stream: a new hub-assigned endpoint, rebound into the record -----------

# add_stream_deck_task <case-dir> <id>: a Deck ship task recorded on a stream
# endpoint of the fake hub (fm_test_fake_stream) that the hub no longer knows.
add_stream_deck_task() {
  local dir=$1 id=$2 old_id=0123456789abcdef0123456789abcdef
  add_ship_task "$dir" "$id"
  # The record names an endpoint this hub never registered; the one the fake
  # dir registered is forgotten, so the case's hub starts with no endpoints.
  fm_test_fake_stream_set "$(cat "$dir/fake/target")" '{"forget": true}'
  : > "$dir/fake/windows"
  : > "$dir/fake/target"
  sed -i.bak -e "s|^window=.*|window=$FM_TEST_STREAM_TAG:$old_id|" \
    -e "s|^stream_endpoint_id=.*|stream_endpoint_id=$old_id|" -e 's/^harness=.*/harness=deck/' \
    "$dir/home/state/$id.meta"
  rm -f "$dir/home/state/$id.meta.bak"
  echo "spawn_gen=1" >> "$dir/home/state/$id.meta"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/deck"
  chmod +x "$dir/fakebin/deck"
}

test_recover_missing_on_stream_rebinds_a_new_endpoint() {
  local dir out rc window endpoint
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    pass "fm-control recover-missing: stream case skipped (jq/curl unavailable)"
    return 0
  fi
  dir=$(new_case stream-recovery rm31)
  fm_test_fake_stream "$dir/stream" || fail "fake stream hub did not start"
  add_stream_deck_task "$dir" rm31

  out=$(run_control "$dir" rm31 recover-missing --note "the hub lost the endpoint"); rc=$?
  expect_code 0 "$rc" "stream recovery of a missing endpoint should succeed"$'\n'"$out"
  window=$(meta_field "$dir" rm31 window)
  endpoint=$(meta_field "$dir" rm31 stream_endpoint_id)
  assert_not_equals "$FM_TEST_STREAM_TAG:0123456789abcdef0123456789abcdef" "$window" "the record must name the NEW endpoint"
  assert_equals "$FM_TEST_STREAM_TAG:$endpoint" "$window" "window= and stream_endpoint_id= must name the same endpoint"
  assert_equals "$FM_TEST_STREAM_URL" "$(meta_field "$dir" rm31 stream_hub)" "the record must keep the hub it recovered on"
  assert_equals stream "$(meta_field "$dir" rm31 backend)" "the task must stay on stream"
  assert_equals "$dir/wt" "$(meta_field "$dir" rm31 worktree)" "the task must keep its worktree"
  assert_equals rm31 "$(meta_field "$dir" rm31 endpoint_task_id)" "the task binding must survive"
  [ "$(grep -c '^window=' "$dir/home/state/rm31.meta")" = 1 ] || fail "the record must name exactly one window"
  assert_contains "$out" "recovered rm31 harness=deck" "the outcome should name the recovered task"
  assert_contains "$out" "endpoint=$window" "the outcome should name the new endpoint"
  assert_equals "$dir/wt" "$(fm_test_fake_stream_endpoints | jq -r --arg id "$endpoint" '.endpoints[] | select(.endpoint_id == $id) | .cwd')" \
    "the new endpoint must start in the task's worktree"
  [ -n "$(fm_test_fake_stream_submitted "$window")" ] || fail "the replacement was never launched into the new endpoint"
  [ "$(journal_field "$dir" rm31 phase)" = complete ] || fail "the transaction journal should end complete"
  assert_grep "the hub lost the endpoint" "$dir/home/data/rm31/brief.md" "the progress note must reach the instructions"
  pass "fm-control recover-missing: a missing stream endpoint is replaced by a new one rebound into the record"
}

test_recover_missing_on_stream_refuses_while_its_agent_still_runs() {
  local dir out rc meta_before brief_before agent_pid
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    pass "fm-control recover-missing: stream refusal skipped (jq/curl unavailable)"
    return 0
  fi
  dir=$(new_case stream-agent-alive rm32)
  fm_test_fake_stream "$dir/stream" || fail "fake stream hub did not start"
  add_stream_deck_task "$dir" rm32
  meta_before=$(cat "$dir/home/state/rm32.meta")
  brief_before=$(cat "$dir/home/data/rm32/brief.md")
  # A stand-in for the endpoint's own agent, still running here while a
  # restarted hub has forgotten it.
  bash -c 'exec -a fm-stream-agent.py perl -e "sleep 60" serve --label fm-rm32 --status-path "$1"' _ "$dir/home/state/rm32.status" &
  agent_pid=$!
  fm_test_track_helper_pid "$agent_pid"

  out=$(run_control "$dir" rm32 recover-missing --note "recover"); rc=$?
  kill "$agent_pid" 2>/dev/null || true
  expect_code 1 "$rc" "stream recovery must refuse while the endpoint's agent still runs"$'\n'"$out"
  assert_contains "$out" "agent process (pid $agent_pid) is still running" "the refusal should name the live agent"
  [ "$(cat "$dir/home/state/rm32.meta")" = "$meta_before" ] || fail "a refused stream recovery must leave the record byte-identical"
  [ "$(cat "$dir/home/data/rm32/brief.md")" = "$brief_before" ] || fail "a refused stream recovery must leave the instructions alone"
  assert_equals 0 "$(fm_test_fake_stream_endpoints | jq '.endpoints | length')" "a refused stream recovery must not create an endpoint"
  pass "fm-control recover-missing: stream refuses while the missing endpoint's agent still runs on this machine"
}

# The ownership probe reads ps's flattened command line, where a home path
# holding a space spans several fields; it must still find that agent.
test_stream_agent_probe_finds_an_agent_under_a_spaced_home() {
  local dir agent_pid found status_path
  dir="$TMP_ROOT/spaced probe home"
  status_path="$dir/state/rm35.status"
  mkdir -p "$dir/state"
  bash -c 'exec -a fm-stream-agent.py perl -e "sleep 60" serve --label fm-rm35 --status-path "$1" --ready-file x' _ "$status_path" &
  agent_pid=$!
  fm_test_track_helper_pid "$agent_pid"
  probe() {
    bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source stream && fm_backend_stream_local_agent_pid "$2" "$3"' _ "$ROOT" "$1" "$2"
  }
  found=$(probe fm-rm35 "$status_path") || fail "the probe missed an agent whose status path holds a space"
  assert_equals "$agent_pid" "$found" "the probe should name that agent"
  ! probe fm-rm35 "$dir/state/rm3.status" >/dev/null || fail "a status path that is only a prefix must not match"
  ! probe fm-rm35 "$TMP_ROOT/spaced" >/dev/null || fail "a truncated spaced path must not match"
  kill "$agent_pid" 2>/dev/null || true
  pass "fm-control recover-missing: the stream agent probe matches a spaced status path exactly"
}

test_recover_missing_on_stream_ignores_unowned_agents() {
  local dir out rc agent_pid other_pid
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    pass "fm-control recover-missing: stream ownership skipped (jq/curl unavailable)"
    return 0
  fi
  dir=$(new_case stream-agent-other-home rm33)
  fm_test_fake_stream "$dir/stream" || fail "fake stream hub did not start"
  add_stream_deck_task "$dir" rm33
  bash -c 'exec -a fm-stream-agent.py perl -e "sleep 60" serve --label fm-rm33 --status-path "$1"' _ "$dir/other-home/state/rm33.status" &
  agent_pid=$!
  fm_test_track_helper_pid "$agent_pid"
  bash -c 'exec -a fm-stream-agent.py perl -e "sleep 60" serve --label fm-other --status-path "$1"' _ "$dir/home/state/rm33.status" &
  other_pid=$!
  fm_test_track_helper_pid "$other_pid"

  out=$(run_control "$dir" rm33 recover-missing --note "recover"); rc=$?
  expect_code 0 "$rc" "stream recovery must ignore agents without both ownership tokens"$'\n'"$out"
  kill -0 "$agent_pid" 2>/dev/null || fail "recovery must leave the other home's agent running"
  kill -0 "$other_pid" 2>/dev/null || fail "recovery must leave the other label's agent running"
  kill "$agent_pid" "$other_pid" 2>/dev/null || true
  assert_contains "$out" "recovered rm33 harness=deck" "the task should recover beside unrelated agents"
  assert_equals 1 "$(fm_test_fake_stream_endpoints | jq '.endpoints | length')" "recovery must create exactly one owned endpoint"
  pass "fm-control recover-missing: stream recovery matches both label and owning status path"
}

test_recover_missing_on_stream_reports_rebind_cleanup() {
  local dir out rc mode endpoint meta_before brief_before
  if ! command -v jq >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
    pass "fm-control recover-missing: stream cleanup skipped (jq/curl unavailable)"
    return 0
  fi
  for mode in confirmed unconfirmed; do
    dir=$(new_case "stream-rebind-$mode" rm34)
    fm_test_fake_stream "$dir/stream" || fail "fake stream hub did not start"
    add_stream_deck_task "$dir" rm34
    meta_before=$(cat "$dir/home/state/rm34.meta")
    brief_before=$(cat "$dir/home/data/rm34/brief.md")
    printf '#!/usr/bin/env bash\nREAL_MV=%q\n' "$(command -v mv)" > "$dir/fakebin/mv"
    cat >> "$dir/fakebin/mv" <<'SH'
for arg in "$@"; do
  case "$arg" in *.meta.rebind.*) exit 1 ;; esac
done
exec "$REAL_MV" "$@"
SH
    chmod +x "$dir/fakebin/mv"
    if [ "$mode" = unconfirmed ]; then
      printf '#!/usr/bin/env bash\nREAL_CURL=%q\n' "$(command -v curl)" > "$dir/fakebin/curl"
      cat >> "$dir/fakebin/curl" <<'SH'
for arg in "$@"; do
  [ "$arg" != DELETE ] || exit 7
done
exec "$REAL_CURL" "$@"
SH
      chmod +x "$dir/fakebin/curl"
    fi

    out=$(run_control "$dir" rm34 recover-missing --note "recover"); rc=$?
    expect_code 1 "$rc" "a failed stream rebind must refuse recovery"$'\n'"$out"
    endpoint=$(fm_test_fake_stream_endpoints | jq -r '.endpoints[0].endpoint_id')
    [ -n "$endpoint" ] && [ "$endpoint" != null ] || fail "recovery must have created an endpoint before the rebind failed"
    assert_contains "$out" "could not be rebound" "the diagnostic should identify the failed publication"
    if [ "$mode" = confirmed ]; then
      assert_contains "$out" "the new endpoint was closed" "a confirmed kill should be reported as closed"
      assert_equals false "$(fm_test_fake_stream_endpoints | jq '.endpoints[0].alive')" "confirmed cleanup must stop the endpoint"
    else
      assert_contains "$out" "the close was not confirmed" "a failed kill must not be reported as closed"
      assert_contains "$out" "$FM_TEST_STREAM_TAG:$endpoint" "the diagnostic must name the orphan's target"
      assert_not_contains "$out" "the new endpoint was closed" "unconfirmed cleanup must not claim success"
      assert_equals true "$(fm_test_fake_stream_endpoints | jq '.endpoints[0].alive')" "the unclosed endpoint must remain available for reconciliation"
    fi
    assert_equals "$meta_before" "$(cat "$dir/home/state/rm34.meta")" "failed publication must preserve the old binding"
    assert_equals "$brief_before" "$(cat "$dir/home/data/rm34/brief.md")" "failed recovery must roll back the progress note"
  done
  pass "fm-control recover-missing: failed stream rebind reports the actual cleanup verdict"
}

test_recover_missing_refuses_a_record_on_a_retired_backend() {
  local dir out rc meta_before brief_before backend
  for backend in tmux herdr; do
    dir=$(new_case "retired-$backend" rm13)
    add_ship_task "$dir" rm13
    make_endpoint_missing "$dir"
    # The same task recorded on a retired backend's endpoint.
    {
      grep -v '^\(window\|backend\|stream_hub\|stream_endpoint_id\)=' "$dir/home/state/rm13.meta"
      if [ "$backend" = tmux ]; then
        echo "window=fmses:fm-rm13"
      else
        printf '%s\n' window=hses:p1 herdr_session=hses herdr_workspace_id=ws1 herdr_tab_id=t1 herdr_pane_id=p1
      fi
      echo "backend=$backend"
    } > "$dir/rm13.meta" && mv "$dir/rm13.meta" "$dir/home/state/rm13.meta"
    meta_before=$(cat "$dir/home/state/rm13.meta")
    brief_before=$(cat "$dir/home/data/rm13/brief.md")

    out=$(run_control "$dir" rm13 recover-missing --note "recover"); rc=$?
    expect_code 1 "$rc" "a record on the retired $backend backend must refuse"$'\n'"$out"
    assert_contains "$out" "$backend" "the refusal should name the retired $backend backend"
    assert_nothing_changed "$dir" rm13 "$meta_before" "$brief_before"
  done
  pass "fm-control recover-missing: a record on a retired tmux or herdr backend refuses before anything changes"
}


test_recover_missing_refuses_a_removed_adapter_record() {
  local dir out rc meta_before brief_before
  dir=$(new_case removed-harness rm15)
  add_ship_task "$dir" rm15
  make_endpoint_missing "$dir"
  # A record left on a worker adapter that no longer has control mechanics.
  sed -i.bak 's|^harness=.*|harness=claude|' "$dir/home/state/rm15.meta"
  rm -f "$dir/home/state/rm15.meta.bak"
  meta_before=$(cat "$dir/home/state/rm15.meta")
  brief_before=$(cat "$dir/home/data/rm15/brief.md")

  out=$(run_control "$dir" rm15 recover-missing --note "recover"); rc=$?
  expect_code 1 "$rc" "a removed adapter recorded in meta must refuse"$'\n'"$out"
  assert_contains "$out" "has no verified control mechanics" \
    "the refusal should name the unverified recorded adapter"
  assert_nothing_changed "$dir" rm15 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: a task recorded on a removed adapter refuses and changes nothing"
}

test_recover_missing_accepts_an_explicit_replacement_harness() {
  local dir out rc
  dir=$(new_case switch rm-switch-1)
  add_ship_task "$dir" rm-switch-1
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" rm-switch-1 recover-missing --harness deck --note "move to a supported runtime"); rc=$?
  expect_code 0 "$rc" "a recovery onto a named replacement runtime should succeed"$'\n'"$out"
  assert_contains "$out" "recovered rm-switch-1 harness=deck from=deck" \
    "the outcome should name the recorded runtime and the one it launched"
  [ "$(meta_field "$dir" rm-switch-1 harness)" = deck ] \
    || fail "the durable record must name the replacement harness that actually launched"
  [ "$(cat "$dir/fake/command")" = fm-deck-worker ] \
    || fail "the replacement agent should be the named harness"
  assert_created "$dir" rm-switch-1 \
    "the missing terminal should still be recreated under its recorded name"
  [ "$(journal_field "$dir" rm-switch-1 from_harness)" = deck ] \
    || fail "the journal should record the runtime the task ran on"
  [ "$(journal_field "$dir" rm-switch-1 to_harness)" = deck ] \
    || fail "the journal should record the replacement runtime"
  assert_grep "move to a supported runtime" "$dir/home/data/rm-switch-1/brief.md" \
    "the progress note must still land in the instructions the replacement reads"
  pass "fm-control recover-missing: an explicitly named harness recovers a missing terminal in one transaction"
}

test_recover_missing_onto_deck_with_an_explicit_effort_refuses() {
  local dir out rc meta_before brief_before
  dir=$(new_case deck-effort rm-switch-4)
  add_ship_task "$dir" rm-switch-4
  printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/fakebin/deck"
  chmod +x "$dir/fakebin/deck"
  printf deck > "$dir/fake/becomes"
  make_endpoint_missing "$dir"
  meta_before=$(cat "$dir/home/state/rm-switch-4.meta")
  brief_before=$(cat "$dir/home/data/rm-switch-4/brief.md")

  out=$(run_control "$dir" rm-switch-4 recover-missing --harness deck --effort high --note "move onto Deck"); rc=$?
  expect_code 1 "$rc" "an explicit effort on a deck replacement must refuse"$'\n'"$out"
  assert_contains "$out" "deck has no effort control" \
    "the refusal should name the unsupported axis, exactly as a relaunch does"
  assert_nothing_changed "$dir" rm-switch-4 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: an explicit effort for a deck replacement refuses before the terminal is recreated"
}

test_recover_missing_replacement_accepts_a_named_model_and_effort() {
  local dir out rc
  dir=$(new_case switch-named rm-switch-5)
  add_ship_task "$dir" rm-switch-5
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" rm-switch-5 recover-missing --harness deck --model gpt-5.6-luna --note "move with a named model"); rc=$?
  expect_code 0 "$rc" "a named replacement model should be honoured"$'\n'"$out"
  [ "$(meta_field "$dir" rm-switch-5 model)" = gpt-5.6-luna ] \
    || fail "the named replacement model should be recorded"
  [ "$(meta_field "$dir" rm-switch-5 effort)" = default ] \
    || fail "an unnamed effort should stay default"
  pass "fm-control recover-missing: a replacement profile honours the axes the caller names"
}


test_recover_missing_replacement_refuses_an_unverified_harness() {
  local dir out rc meta_before brief_before
  dir=$(new_case switch-unverified rm-switch-7)
  add_ship_task "$dir" rm-switch-7
  make_endpoint_missing "$dir"
  meta_before=$(cat "$dir/home/state/rm-switch-7.meta")
  brief_before=$(cat "$dir/home/data/rm-switch-7/brief.md")

  out=$(run_control "$dir" rm-switch-7 recover-missing --harness someagent --note "move"); rc=$?
  expect_code 1 "$rc" "an unverified replacement harness must refuse"$'\n'"$out"
  assert_contains "$out" "is not a verified harness" \
    "the refusal should name the unverified adapter exactly as a relaunch does"
  assert_nothing_changed "$dir" rm-switch-7 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: an unverified replacement harness refuses before anything is touched"
}


test_recover_missing_held_backlog_row_still_refuses_a_replacement() {
  local dir out rc meta_before brief_before
  command -v tasks-axi >/dev/null 2>&1 || {
    pass "skipped: tasks-axi is not installed, so the backlog transition is inert"
    return 0
  }
  dir=$(new_case switch-held rm-switch-9)
  add_ship_task "$dir" rm-switch-9
  make_endpoint_missing "$dir"
  {
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done'
  } > "$dir/home/data/backlog.md"
  tasks-axi add rm-switch-9 "held fixture task" --kind ship --file "$dir/home/data/backlog.md" >/dev/null
  tasks-axi start rm-switch-9 --file "$dir/home/data/backlog.md" >/dev/null
  tasks-axi hold rm-switch-9 --reason "captain decision pending" --kind captain \
    --file "$dir/home/data/backlog.md" >/dev/null
  meta_before=$(cat "$dir/home/state/rm-switch-9.meta")
  brief_before=$(cat "$dir/home/data/rm-switch-9/brief.md")

  out=$(run_control "$dir" rm-switch-9 recover-missing --harness deck --note "move"); rc=$?
  expect_code 1 "$rc" "a held backlog row must refuse a replacement recovery too"$'\n'"$out"
  assert_contains "$out" "not eligible for relaunch" \
    "the backlog eligibility predicate must gate a replacement recovery exactly as it gates an ordinary one"
  assert_nothing_changed "$dir" rm-switch-9 "$meta_before" "$brief_before"
  pass "fm-control recover-missing: a held backlog row still refuses, replacement profile or not"
}

test_recover_missing_replacement_rolls_back_to_the_recorded_runtime_on_failure() {
  local dir out rc before
  dir=$(new_case switch-fail rm-switch-10)
  add_ship_task "$dir" rm-switch-10
  printf 'deck' > "$dir/fake/becomes"
  make_endpoint_missing "$dir"
  before=$(record_without_binding "$dir/home/state/rm-switch-10.meta")
  # The recreated shell reports a cwd outside the recorded local copy, so the
  # launch owner refuses AFTER the terminal has already been recreated.
  printf '%s' "$dir/proj" > "$dir/fake/cwd"

  out=$(run_control "$dir" rm-switch-10 recover-missing --harness deck --note "carry this forward"); rc=$?
  expect_code 1 "$rc" "a failed replacement handoff should fail closed"$'\n'"$out"
  assert_created "$dir" rm-switch-10 \
    "the terminal should already have been recreated"
  assert_contains "$out" "no agent was ever stopped" \
    "the failure must not claim a recovery stopped an agent it never touched"
  assert_contains "$out" "retry with 'relaunch'" \
    "the failure should name the verb that acts on the bare shell it left behind"
  [ "$(record_without_binding "$dir/home/state/rm-switch-10.meta")" = "$before" ] \
    || fail "a failed replacement handoff must keep the prior durable record, runtime included:"$'\n'"$(diff <(printf '%s\n' "$before") <(record_without_binding "$dir/home/state/rm-switch-10.meta"))"
  assert_bound_to_created "$dir" rm-switch-10
  assert_grep "carry this forward" "$dir/home/data/rm-switch-10/brief.md" \
    "the progress note must survive the failed handoff so the retry still has it"
  pass "fm-control recover-missing: a failed replacement handoff keeps the recorded runtime and never claims a stop"
}


# --- 3. profile-switch flags belong to relaunch and recover-missing only -----

test_profile_switch_flags_are_rejected_on_other_verbs() {
  local dir out rc flag
  dir=$(new_case profile rm9)
  add_ship_task "$dir" rm9
  make_endpoint_missing "$dir"

  for flag in "--harness deck" "--model opus" "--effort high"; do
    # shellcheck disable=SC2086 # the flag pair is deliberately split.
    out=$(run_control "$dir" rm9 exit $flag); rc=$?
    expect_code 1 "$rc" "exit must reject '$flag'"$'\n'"$out"
    assert_contains "$out" "apply to 'relaunch' and 'recover-missing' only" \
      "the refusal should scope the flags to the verbs that own them"
  done
  [ "$(created_endpoint_count "$dir" rm9)" = 0 ] || fail "a rejected flag must not create a terminal"
  pass "fm-control: profile-switch flags belong to relaunch and recover-missing only"
}

test_recover_missing_requires_a_note_for_a_ship_task() {
  local dir out rc
  dir=$(new_case no-note rm10)
  add_ship_task "$dir" rm10
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" rm10 recover-missing); rc=$?
  expect_code 1 "$rc" "a ship recovery without a note must refuse"$'\n'"$out"
  assert_contains "$out" "requires --note" "the refusal should name the missing note"
  [ "$(created_endpoint_count "$dir" rm10)" = 0 ] || fail "a refused recovery must not create a terminal"
  pass "fm-control recover-missing: a ship task's recovery requires the progress note"
}

# --- 5. every identity axis comes from the task's own record ----------------

test_recover_missing_freezes_the_recorded_profile_for_a_secondmate() {
  local dir home out rc
  dir=$(new_case smfreeze sm9)
  home="$dir/home"
  mkdir -p "$home/config" "$home/data/sm9"
  # The durable pin names a DIFFERENT model than the record. A relaunch
  # re-resolves this pin on purpose; a recovery must not, because it continues
  # the same run in the same terminal.
  printf 'deck some-model\n' > "$home/config/secondmate-harness"
  printf '# secondmate brief\n' > "$home/data/sm9/brief.md"
  fm_git_worktree "$dir/proj" "$dir/smhome" sm-branch
  mkdir -p "$dir/smhome/state" "$dir/smhome/data" "$dir/smhome/bin"
  printf 'sm9\n' > "$dir/smhome/.fm-secondmate-home"
  printf '# agents\n' > "$dir/smhome/AGENTS.md"
  # Commit the seeded home so this case exercises the profile freeze against a
  # settled checkout rather than incidental fixture dirt. The identity is inline
  # because tests/git-config-helpers.sh takes the host's global and system
  # config away from every fixture: a bare commit is then left with Git's own
  # <user>@<hostname> guess, which a developer machine supplies and a CI runner
  # whose hostname carries no domain does not.
  git -C "$dir/smhome" add -A
  git -C "$dir/smhome" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit --quiet -m "secondmate home" \
    || fail "the secondmate home fixture could not be committed"
  {
    fm_test_fake_dir_task "$dir/fake" "$home/state" sm9
    echo "worktree=$dir/smhome"
    echo "project=$dir/smhome"
    echo "harness=deck"
    echo "kind=secondmate"
    echo "mode=secondmate"
    echo "yolo=off"
    echo "model=opus"
    echo "effort=default"
    echo "home=$dir/smhome"
  } > "$home/state/sm9.meta"
  printf '%s' "$dir/smhome" > "$dir/fake/cwd"
  make_endpoint_missing "$dir"

  out=$(run_control "$dir" sm9 recover-missing); rc=$?
  expect_code 0 "$rc" "a secondmate with a missing endpoint should recover"$'\n'"$out"
  assert_contains "$out" "harness=deck from=deck" \
    "recovery must continue the RECORDED harness, not the configured pin"
  assert_contains "$out" "model=opus effort=default" \
    "recovery must continue the recorded model and effort, not reset them to the pin's"
  [ "$(journal_field "$dir" sm9 to_harness)" = deck ] \
    || fail "the journal should record the recorded harness, got '$(journal_field "$dir" sm9 to_harness)'"
  [ "$(journal_field "$dir" sm9 to_model)" = opus ] \
    || fail "the journal should record the recorded model, got '$(journal_field "$dir" sm9 to_model)'"
  [ "$(journal_field "$dir" sm9 to_effort)" = default ] \
    || fail "the journal should record the recorded effort, got '$(journal_field "$dir" sm9 to_effort)'"
  pass "fm-control recover-missing: a secondmate's recorded harness, model and effort survive a differing configured pin"
}

# --- 6. the rescue runs on the mid-work copy it exists for -------------------

# The reason this verb exists is a worker whose terminal died mid-task, so its
# local copy is dirty by definition. Recovery only recreates the terminal beside
# that work: it must succeed on every shape of uncommitted change, and every one
# of them must still be there, byte for byte, afterwards.
test_recover_missing_preserves_uncommitted_work() {
  local dir out rc modified_before untracked_before staged_before status_before
  dir=$(new_case uncommitted rm19)
  add_ship_task "$dir" rm19
  make_endpoint_missing "$dir"

  # All three shapes at once: an edited tracked file, brand-new untracked work,
  # and a staged change waiting to be committed.
  printf '# README\nthe worker was halfway through this line\n' > "$dir/wt/README.md"
  printf 'work in progress\nsecond line\n' > "$dir/wt/new-source.sh"
  printf 'staged change\n' > "$dir/wt/staged.txt"
  git -C "$dir/wt" add staged.txt
  modified_before=$(cat "$dir/wt/README.md")
  untracked_before=$(cat "$dir/wt/new-source.sh")
  staged_before=$(cat "$dir/wt/staged.txt")
  status_before=$(git -C "$dir/wt" status --porcelain)

  out=$(run_control "$dir" rm19 recover-missing --note "the terminal died mid-task"); rc=$?
  expect_code 0 "$rc" "a mid-work local copy is exactly what this verb rescues"$'\n'"$out"
  assert_contains "$out" "recovered rm19 harness=deck" "the rescue should complete"
  assert_created "$dir" rm19 "the terminal should have been recreated"
  assert_grep "encode launch-brief" "$dir/fake/literal" \
    "the launch should have been handed to the existing owner"

  [ "$(cat "$dir/wt/README.md")" = "$modified_before" ] \
    || fail "the edited tracked file must survive the rescue unmodified"
  [ "$(cat "$dir/wt/new-source.sh")" = "$untracked_before" ] \
    || fail "untracked work in progress must survive the rescue unmodified"
  [ "$(cat "$dir/wt/staged.txt")" = "$staged_before" ] \
    || fail "a staged change must survive the rescue unmodified"
  [ "$(git -C "$dir/wt" status --porcelain)" = "$status_before" ] \
    || fail "the rescue must leave the index and working tree exactly as it found them"$'\n'"before:"$'\n'"$status_before"$'\n'"after:"$'\n'"$(git -C "$dir/wt" status --porcelain)"
  [ "$(meta_field "$dir" rm19 worktree)" = "$dir/wt" ] \
    || fail "the rescue must reuse the recorded local copy, never reallocate one"
  pass "fm-control recover-missing: a copy full of uncommitted work is rescued with every change left untouched"
}

# The checkpoint no longer gates on dirt, but it still has to SAY what it found,
# so the journal records which state the rescued copy was in.
test_recover_missing_records_the_dirty_state_it_found() {
  local dir out rc
  dir=$(new_case dirty-journal rm20)
  add_ship_task "$dir" rm20
  make_endpoint_missing "$dir"
  printf 'work in progress\n' > "$dir/wt/new-source.sh"

  out=$(run_control "$dir" rm20 recover-missing --note "recover"); rc=$?
  expect_code 0 "$rc" "a dirty copy should recover"$'\n'"$out"
  [ "$(journal_field "$dir" rm20 worktree_dirty)" = yes ] \
    || fail "the journal should record the rescued copy as dirty, got '$(journal_field "$dir" rm20 worktree_dirty)'"
  [ "$(journal_field "$dir" rm20 phase)" = complete ] \
    || fail "the transaction journal should end complete"
  pass "fm-control recover-missing: the checkpoint still records the rescued copy's dirty state"
}



test_recover_missing_freezes_the_recorded_profile_for_a_secondmate
test_recover_missing_preserves_uncommitted_work
test_recover_missing_records_the_dirty_state_it_found
test_recover_missing_recreates_the_terminal_and_launches_the_replacement
test_recover_missing_on_stream_rebinds_a_new_endpoint
test_recover_missing_on_stream_refuses_while_its_agent_still_runs
test_stream_agent_probe_finds_an_agent_under_a_spaced_home
test_recover_missing_on_stream_ignores_unowned_agents
test_recover_missing_on_stream_reports_rebind_cleanup
test_recover_missing_accepts_an_explicit_replacement_harness
test_recover_missing_onto_deck_with_an_explicit_effort_refuses
test_recover_missing_replacement_accepts_a_named_model_and_effort
test_recover_missing_replacement_refuses_an_unverified_harness
test_recover_missing_held_backlog_row_still_refuses_a_replacement
test_recover_missing_replacement_rolls_back_to_the_recorded_runtime_on_failure
test_recover_missing_verified_deck_recreates_the_endpoint
test_recover_missing_waits_for_the_recreated_shell_to_settle
test_recover_missing_refuses_a_terminal_that_never_settles
test_recover_missing_refuses_a_live_endpoint
test_recover_missing_refuses_an_ambiguous_endpoint
test_recover_missing_refuses_an_absent_local_copy
test_recover_missing_refuses_a_pool_slot_owned_by_another_task
test_recover_missing_refuses_an_unreadable_pool_slot_claim
test_recover_missing_keeps_its_own_pool_slot
test_failed_recreation_rolls_the_progress_note_back
test_failed_recreation_keeps_a_concurrent_record_write
test_unreadable_endpoint_after_a_failed_recreation_claims_nothing
test_launch_failure_never_claims_an_agent_was_stopped
test_recover_missing_refuses_a_record_on_a_retired_backend
test_recover_missing_refuses_a_removed_adapter_record
test_profile_switch_flags_are_rejected_on_other_verbs
test_recover_missing_requires_a_note_for_a_ship_task
echo "PASS: fm-control-recover-missing"
