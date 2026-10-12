#!/usr/bin/env bash
# tests/fm-worker-guard.test.sh - workers never raise captain-facing items: a
# worker's decision lands with its parent mate as a status line, and the
# captain-call and decision-card commands refuse the worker itself.
set -u

# shellcheck source=tests/fixtures.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-classify-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-classify-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-worker-guard)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }
command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; exit 0; }

make_home() {  # <name>: a mate home with one live ship worker, w-1
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  fm_write_meta "$home/state/w-1.meta" kind=ship project=alpha
  printf '%s\n' "$home"
}

# run_as <worker-id|''> <home> <script> <args...>
run_as() {
  local task=$1 home=$2 script=$3
  shift 3
  PATH="$home/fakebin:$PATH" FM_TASK_ID="$task" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_CARD_NOW=2026-10-12T12:00:00Z "$ROOT/bin/$script" "$@"
}

good_card() {  # <path>
  printf '%s' '{"project":"alpha","title":"Pick one","situation":"Two ways.","options":[{"key":"1","label":"A","instruction":"Do A."},{"key":"2","label":"B","instruction":"Do B."}],"recommended":"1"}' > "$1"
}

captain_facing_count() {  # <home>: cards plus captain-held backlog rows
  local cards held
  cards=$(find "$1/state/cards" -name '*.json' 2>/dev/null | wc -l | tr -d ' ')
  held=$(run_as '' "$1" fm-card.sh calls 2>/dev/null | wc -l | tr -d ' ')
  printf '%s\n' "$((cards + held))"
}

test_worker_decision_lands_with_its_parent_only() {
  local home open
  home=$(make_home lands)
  # The worker's only channel: one status line in its parent's home.
  printf '%s\n' 'needs-decision [key=pick-lang]: ship English only or add Portuguese?' >> "$home/state/w-1.status"
  open=$(status_open_decisions "$home/state/w-1.status")
  assert_contains "$open" "pick-lang" "the parent's open-decision fold sees the worker's question"
  assert_equals 0 "$(captain_facing_count "$home")" "a worker decision creates no card and no captain call"
  pass "worker-guard: a worker decision lands with its parent and produces nothing captain-facing"
}

test_worker_cannot_hold_a_captain_call() {
  local home rc=0 err
  home=$(make_home hold)
  err=$(run_as w-1 "$home" fm-captain-hold.sh hold w-1 --title "Ask" --repo alpha --reason "Pick one" 2>&1) || rc=$?
  expect_code 3 "$rc" "worker hold"
  assert_contains "$err" "needs-decision" "refusal points the worker at its status file"
  assert_equals 0 "$(captain_facing_count "$home")" "refused hold left nothing captain-facing"
  assert_no_grep "w-1" "$home/data/backlog.md" "refused hold left the backlog untouched"
  pass "worker-guard: fm-captain-hold.sh refuses a worker of this home"
}

test_worker_cannot_write_a_card() {
  local home rc=0 card="$TMP_ROOT/card.json"
  home=$(make_home card)
  good_card "$card"
  run_as w-1 "$home" fm-card.sh write w-1 --file "$card" >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "worker card write"
  rc=0
  run_as w-1 "$home" fm-card.sh draft w-1 --title t --project alpha --situation s >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "worker card draft"
  assert_absent "$home/state/cards" "no card directory was created"
  run_as w-1 "$home" fm-card.sh calls >/dev/null || fail "read-only calls must still work for a worker"
  pass "worker-guard: fm-card.sh refuses a worker's write and draft but keeps reads"
}

test_mate_still_holds_its_own_call_about_a_worker() {
  local home card="$TMP_ROOT/mate-card.json"
  home=$(make_home mate)
  good_card "$card"
  run_as '' "$home" fm-captain-hold.sh hold ask-w-1 --title "Pick one for w-1" --repo alpha \
    --reason "Pick one" --card-file "$card" >/dev/null || fail "the mate's own hold was refused"
  assert_present "$home/state/cards/ask-w-1.json" "the mate's card is written"
  # A marked shell acting on a home where it is not a worker (a test fixture
  # home, say) is not refused either.
  run_as other-task "$home" fm-card.sh write ask-w-1 --file "$card" >/dev/null \
    || fail "a marker for another home's task must not refuse"
  pass "worker-guard: a mate holds its own call, and only this home's workers are refused"
}

test_worker_decision_lands_with_its_parent_only
test_worker_cannot_hold_a_captain_call
test_worker_cannot_write_a_card
test_mate_still_holds_its_own_call_about_a_worker
