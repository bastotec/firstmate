#!/usr/bin/env bash
# bin/fm-effort-policy.sh - which supervisor turns may think less. Runs the real
# classifier, drain and status libraries over scratch homes; no model, no live
# home. A wake is routine only when every reason in it is; everything else,
# and every failure, keeps the default effort.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

POLICY="$ROOT/bin/fm-effort-policy.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-effort-policy-tests)
PREAMBLE='The home watcher has an actionable wake. Drain bin/fm-wake-drain.sh first, handle every emitted wake and open decision, and acknowledge only after handling. Watcher output:'

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config" "$home/data"
  printf '%s\n' "$home"
}

# The level classify prints for a watcher wake carrying <reason lines>.
wake() {  # <home> <reason>...
  local home=$1
  shift
  printf '%s\nwatcher: started pid=1 (beacon fresh)\n' "$PREAMBLE"
  printf '%s\n' "$@"
}
classify() {  # <home> <reason>...
  local home=$1
  wake "$@" | "$POLICY" classify --home "$home"
}

drain() {  # <home>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" >/dev/null 2>&1 || fail "the scratch drain failed"
}

test_only_routine_watcher_wakes_think_less() {
  local home merged nothing
  home=$(new_home sources)
  merged="check: $home/state/autoland.check.sh: autoland: merged https://github.com/o/r/pull/7 (deploy follows)"
  nothing="check: $home/state/autoland.check.sh: autoland: deployed firstmate-ui 992864d: firstmate-ui: nothing to deploy - no running deployment (local clone refresh: see fleet sync line in the log)"
  assert_equals low "$(classify "$home" "$merged")" "a merge notice is routine"
  assert_equals low "$(classify "$home" "$nothing")" "a nothing-to-deploy notice is routine"
  assert_equals low "$(classify "$home" "${merged}; ${nothing#*autoland: }")" "joined routine notices are routine"
  assert_equals '' "$(classify "$home" "check: $home/state/autoland.check.sh: autoland: deployed firstmate 88751386: homes at 88751386 (0 skipped); finish /updatefirstmate from step 2")" \
    "a deploy that asks for follow-up work keeps the default"
  assert_equals '' "$(classify "$home" "check: $home/state/autoland.check.sh: autoland: green PR not landing: https://github.com/o/r/pull/8 because no CI checks are reported on its head")" \
    "a PR the captain must look at keeps the default"
  assert_equals '' "$(classify "$home" "stale: task-1 (idle 900s, possible wedge, escalation 1)")" "stuck work keeps the default"
  assert_equals '' "$(classify "$home" "needs-decision: $home/state/task-1.status")" "a decision keeps the default"
  assert_equals '' "$(classify "$home" "check: captain inbox note: 1791458533-V6VKLl")" "a captain note keeps the default"
  assert_equals '' "$(classify "$home" "$merged" "stale: task-1")" "one non-routine reason keeps the default"
  assert_equals '' "$(printf 'From the captain, directly: card x: option 1\n' | "$POLICY" classify --home "$home")" \
    "a captain message keeps the default"
  assert_equals '' "$(printf '%s\nwatcher: started pid=1\n' "$PREAMBLE" | "$POLICY" classify --home "$home")" \
    "a wake without a reason keeps the default"
  pass "classify: only merge and nothing-to-deploy notices among checks are routine; captain input, decisions and stale work keep the default"
}

test_signals_follow_the_status_classifier() {
  local home status
  home=$(new_home signals)
  status="$home/state/task-1.status"
  printf 'working: started\n' > "$status"
  assert_equals low "$(classify "$home" "signal: $status $home/state/task-1.turn-ended")" \
    "a progress line is routine"
  printf 'needs-decision: which database?\n' >> "$status"
  assert_equals '' "$(classify "$home" "signal: $status")" "an unpresented decision keeps the default"
  drain "$home"
  printf 'working: carrying on\n' >> "$status"
  assert_equals '' "$(classify "$home" "signal: $status")" \
    "progress keeps the default while that task's decision is still open"
  printf 'resolved: use postgres\n' >> "$status"
  drain "$home"
  printf 'working: carrying on\n' >> "$status"
  assert_equals low "$(classify "$home" "signal: $status")" \
    "progress after the decision was resolved and drained is routine"
  printf 'needs-decision [key=x]: which database?\ndone [key=y]: other work finished\n' >> "$status"
  drain "$home"
  printf 'working: carrying on\n' >> "$status"
  assert_equals '' "$(classify "$home" "signal: $status")" \
    "a drained unrelated completion does not close a keyed decision"
  assert_equals '' "$(classify "$home" "signal: $home/state/task-1.turn-ended")" \
    "a bare turn-ended signal checks the task's open decisions"
  assert_equals '' "$(classify "$home" "signal: $home/state/task-1.note")" \
    "other task signal suffixes also check the task's open decisions"
  printf 'resolved [key=x]: use postgres\n' >> "$status"
  drain "$home"
  assert_equals low "$(classify "$home" "signal: $home/state/task-1.turn-ended")" \
    "a bare turn-ended signal becomes routine after resolution"
  printf 'failed: tests red\n' >> "$status"
  assert_equals '' "$(classify "$home" "signal: $home/state/task-1.turn-ended")" \
    "a bare turn-ended signal checks unpresented outcomes"
  assert_equals '' "$(classify "$home" "signal: $status")" "a failure keeps the default"
  drain "$home"
  printf 'blocked: need a credential\n' >> "$status"
  assert_equals '' "$(classify "$home" "signal: $status")" "a blocker keeps the default"
  pass "classify: signals are routine only when the status classifier finds nothing captain-facing past the drain's cursor"
}

test_heartbeat_is_routine_only_without_change() {
  local home f
  home=$(new_home heartbeat)
  printf 'working: started\n' > "$home/state/task-1.status"
  drain "$home"
  assert_equals '' "$(classify "$home" heartbeat)" "the first heartbeat has nothing to compare and keeps the default"
  assert_equals low "$(classify "$home" heartbeat)" "an unchanged fleet is routine"
  printf 'working: next step\n' >> "$home/state/task-1.status"
  assert_equals '' "$(classify "$home" heartbeat)" "a changed fleet keeps the default"
  assert_equals low "$(classify "$home" heartbeat)" "the fleet is unchanged again"
  for f in "$home/data/backlog.md" "$home/state/cards/card.json" "$home/state/orders/order.json"; do
    mkdir -p "$(dirname "$f")"
    printf '{"option":1}\n' > "$f"
    assert_equals '' "$(classify "$home" heartbeat)" "a new fleet record keeps the default"
    assert_equals low "$(classify "$home" heartbeat)" "an unchanged fleet record is routine"
    cp -p "$f" "$home/mtime-reference"
    printf '{"option":2}\n' > "$f"
    touch -r "$home/mtime-reference" "$f"
    assert_equals '' "$(classify "$home" heartbeat)" "same-size, same-mtime record changes keep the default"
    assert_equals low "$(classify "$home" heartbeat)" "the rewritten record is unchanged again"
  done
  pass "classify: a heartbeat is routine only when nothing changed since the previous one"
}

test_config_sets_the_level_and_kills_the_switch() {
  local home merged err invalid
  home=$(new_home config)
  merged="check: $home/state/autoland.check.sh: autoland: merged https://github.com/o/r/pull/7 (deploy follows)"
  printf '{"classifier": "on", "low": "medium"}\n' > "$home/config/effort-policy.json"
  assert_equals medium "$(classify "$home" "$merged")" "the configured level is used"
  printf '{"classifier": "off"}\n' > "$home/config/effort-policy.json"
  assert_equals '' "$(classify "$home" "$merged")" "off keeps every turn at the default"
  printf '{"low": "high"}\n' > "$home/config/effort-policy.json"
  err=$(classify "$home" "$merged" 2>&1 >/dev/null)
  assert_equals '' "$(classify "$home" "$merged" 2>/dev/null)" "a level that is not lower is refused"
  assert_contains "$err" 'every turn keeps the default effort' "the refusal is reported"
  printf 'not json' > "$home/config/effort-policy.json"
  assert_equals '' "$(classify "$home" "$merged" 2>/dev/null)" "an unreadable config keeps the default"
  printf '{}\n' > "$home/config/effort-policy.json"
  assert_equals low "$(classify "$home" "$merged")" "omitted fields use defaults"
  for invalid in '{"classifier":false}' '{"low":false}' '{"classifier":false,"low":false}' \
    '{"classifier":null}' '{"low":null}' '{"classifier":1}' '{"low":["low"]}' \
    '[]' '"on"' 'null' '{} {}'; do
    printf '%s\n' "$invalid" > "$home/config/effort-policy.json"
    err=$(classify "$home" "$merged" 2>&1 >/dev/null)
    assert_equals '' "$(classify "$home" "$merged" 2>/dev/null)" "present invalid config $invalid keeps the default"
    assert_contains "$err" 'every turn keeps the default effort' "invalid config $invalid reports refusal"
  done
  rm "$home/config/effort-policy.json"
  ln -s "$home/config/missing-policy.json" "$home/config/effort-policy.json"
  err=$(classify "$home" "$merged" 2>&1 >/dev/null)
  assert_equals '' "$(classify "$home" "$merged" 2>/dev/null)" "a dangling configuration symlink keeps the default"
  assert_contains "$err" 'every turn keeps the default effort' "a dangling config reports refusal"
  pass "config/effort-policy.json picks the level, and off or a bad value keeps every turn at the default"
}

test_a_lowered_turn_that_finds_work_escalates_the_next() {
  local home merged
  home=$(new_home escalate)
  merged="check: $home/state/autoland.check.sh: autoland: merged https://github.com/o/r/pull/7 (deploy follows)"
  printf '%s\n' '{"type":"run_started","session":"s","model":"m"}' \
    '{"type":"tool_result","id":"1","name":"run_command","output":"OPEN DECISIONS (still open)","duration_ms":1}' \
    | "$POLICY" observe --home "$home"
  assert_equals low "$(classify "$home" "$merged")" "a default-effort turn never escalates"
  printf '%s\n' '{"type":"run_started","session":"s","model":"m","effort":"low"}' \
    '{"type":"tool_result","id":"1","name":"run_command","output":"wake drain: nothing queued","duration_ms":1}' \
    | "$POLICY" observe --home "$home"
  assert_equals low "$(classify "$home" "$merged")" "a quiet lowered turn does not escalate"
  printf '%s\n' '{"type":"run_started","session":"s","model":"m","effort":"low"}' \
    '{"type":"tool_result","id":"1","name":"run_command","output":"1\t2\tcheck\tk\tcheck: x\nOPEN DECISIONS (still open, folded):\ntask-1 needs-decision: which db","duration_ms":1}' \
    | "$POLICY" observe --home "$home"
  assert_equals low "$(classify "$home" "$merged")" "a decision the drain repeats while it waits is not new work"
  printf '%s\n' '{"type":"run_started","session":"s","model":"m","effort":"low"}' \
    '{"type":"tool_result","id":"1","name":"run_command","output":"1\t2\tsignal\tk\tneeds-decision: /h/state/task-1.status","duration_ms":1}' \
    | "$POLICY" observe --home "$home"
  assert_equals '' "$(classify "$home" "$merged")" "the next turn after a lowered turn drained a decision keeps the default"
  assert_equals low "$(classify "$home" "$merged")" "the escalation is used once"
  printf '%s\n' '{"type":"run_started","session":"s","model":"m","effort":"low"}' \
    '{"type":"tool_result","id":"1","name":"run_command","output":"UNREAD STATUS (new since last drain):\ntask-2 note: captain said REST","duration_ms":1}' \
    | "$POLICY" observe --home "$home"
  assert_equals '' "$(classify "$home" "$merged")" "unread status found by a lowered turn escalates the next"
  pass "observe: a lowered turn whose drain surfaced real work sends the next turn back to the default"
}

test_support_follows_the_deck_binary() {
  local dir="$TMP_ROOT/decks"
  mkdir -p "$dir"
  printf '#!/bin/sh\necho "  --effort <LEVEL>"\n' > "$dir/new"
  printf '#!/bin/sh\necho "  --steer-dir <DIR>"\n' > "$dir/old"
  chmod +x "$dir/new" "$dir/old"
  "$POLICY" supported "$dir/new" || fail "a deck with --effort is supported"
  if "$POLICY" supported "$dir/old"; then fail "a deck without --effort is not supported"; fi
  pass "supported: only a deck that takes --effort gets effort headers"
}

test_only_routine_watcher_wakes_think_less
test_signals_follow_the_status_classifier
test_heartbeat_is_routine_only_without_change
test_config_sets_the_level_and_kills_the_switch
test_a_lowered_turn_that_finds_work_escalates_the_next
test_support_follows_the_deck_binary
