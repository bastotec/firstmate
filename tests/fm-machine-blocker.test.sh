#!/usr/bin/env bash
# tests/fm-machine-blocker.test.sh - a machine check with human items becomes a
# "Blocked on you:" reply, a needs-you card on a captain hold, a pending machine
# record and a re-check watch; a passing re-check closes the card on its own.
# Check output is a fixture fed through --from, so no machine is contacted.
set -u

# shellcheck source=tests/fixtures.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

BLOCKER="$ROOT/bin/fm-machine-blocker.sh"
TMP_ROOT=$(fm_test_tmproot fm-machine-blocker-tests)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  fm_fake_exit0 "$fakebin" tmux treehouse no-mistakes gh gh-axi
  printf '%s\n' "$home"
}

run_in() {  # <home> <command> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CARD_NOW=2026-10-12T16:21:00Z \
    FM_MACHINE_BLOCKER_NOW=2026-10-12T16:21:00Z "$@"
}

# The check that blocked Inter Graal: three steps only the captain can do.
check_output() {  # <path> [<items to leave out or pass>...]
  cat > "$1" <<'EOF'
action=check
alias=Automattic
root=/Users/bruno/Projects/firstmate
reach=ok
item ssh-login=present: key login as bruno works without a prompt
item firstmate-clone=present: /Users/bruno/Projects/firstmate
item gh-auth=human: run gh auth login, then gh auth setup-git, on the machine
item model-gateway=human: make http://127.0.0.1:8329/v1 answer on the machine: run proxai there
item stream-hub=human: make http://127.0.0.1:7717 reachable from the machine
item shared-skills=will-install: setup ships origin/main of the skills repo
EOF
}

test_summary_leads_with_blocked_on_you() {
  local home out
  home=$(make_home summary)
  check_output "$home/check.txt"
  out=$("$BLOCKER" summary --alias Automattic --then "I create Inter Graal there." < "$home/check.txt") \
    || fail "summary refused a check with human items"
  assert_equals "Blocked on you: 3 steps on Automattic before I can continue." "$(printf '%s\n' "$out" | head -n 1)" "reply leads with Blocked on you"
  assert_contains "$out" "1. gh-auth: run gh auth login, then gh auth setup-git, on the machine" "first step quotes the exact command"
  assert_contains "$out" "2. model-gateway: make http://127.0.0.1:8329/v1 answer" "second step numbered"
  assert_contains "$out" "3. stream-hub: make http://127.0.0.1:7717 reachable" "third step numbered"
  assert_equals "Then: I create Inter Graal there." "$(printf '%s\n' "$out" | tail -n 1)" "reply ends with what happens next"
  assert_not_contains "$out" "shared-skills" "automatic items are not the captain's steps"
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  out=$("$BLOCKER" summary --alias Automattic < "$home/pass.txt") && fail "summary claimed a block with nothing human"
  assert_equals "" "$out" "nothing printed when nothing waits on the captain"
  pass "fm-machine-blocker: summary turns human items into numbered steps"
}

test_raise_writes_card_hold_record_and_watch() {
  local home out card rec
  home=$(make_home raise)
  check_output "$home/check.txt"
  out=$(run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" \
    --secondmate "inter-graal=Inter Graal" --from "$home/check.txt") || fail "raise failed: $out"
  assert_contains "$out" "Blocked on you: 3 steps on Automattic" "raise prints the reply block"
  card=$(run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic) || fail "no card for the hold"
  assert_equals false "$(jq -r .draft <<<"$card")" "the card is a full card"
  assert_equals "Automattic needs you before I can create Inter Graal" "$(jq -r .title <<<"$card")" "card title names machine and action"
  assert_contains "$(jq -r .situation <<<"$card")" "Blocked on you: 3 steps on Automattic - gh-auth, model-gateway, stream-hub." "card quotes the human items"
  assert_contains "$(jq -r '.options[1].instruction' <<<"$card")" "gh auth login" "card carries the exact steps"
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open machine-automattic >/dev/null || fail "hold is not open"
  rec=$(run_in "$home" "$BLOCKER" show Automattic) || fail "no pending record"
  assert_equals needs-you "$(jq -r .state <<<"$rec")" "record waits on the captain"
  assert_equals "done you you you todo" "$(jq -r '[.items[] | select(.name != "ssh-login") | .state] | join(" ")' <<<"$rec")" "item states map to done, you, todo"
  assert_equals "Inter Graal" "$(jq -r '.planned[0].name' <<<"$rec")" "planned second mate recorded"
  assert_equals /Users/bruno/Projects/firstmate "$(jq -r .root <<<"$rec")" "root taken from the check"
  assert_present "$home/state/when/when-machine-automattic.spec" "re-check watch armed"
  pass "fm-machine-blocker: raise holds the call with a card, a record and a watch"
}

test_recheck_updates_then_resolves_itself() {
  local home out rc
  home=$(make_home recheck)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null \
    || fail "raise failed"
  grep -v 'gh-auth=' "$home/check.txt" > "$home/two.txt"
  rc=0
  run_in "$home" "$BLOCKER" ready Automattic --from "$home/two.txt" || rc=$?
  assert_equals 1 "$rc" "ready is false while steps remain"
  assert_contains "$(run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic | jq -r .situation)" \
    "2 steps on Automattic - model-gateway, stream-hub" "card follows the remaining steps"
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  run_in "$home" "$BLOCKER" ready Automattic --from "$home/pass.txt" || fail "ready is false with nothing human"
  out=$(run_in "$home" "$BLOCKER" resolve Automattic) || fail "resolve failed: $out"
  assert_contains "$out" "carry on with: create Inter Graal" "resolve names the next action"
  if run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open machine-automattic >/dev/null 2>&1; then
    fail "hold still open after a passing re-check"
  fi
  if run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic >/dev/null 2>&1; then
    fail "card still shown after a passing re-check"
  fi
  assert_contains "$(cat "$home/data/backlog.md")" "reported no step left for the captain" "close records check evidence"
  assert_equals ready "$(run_in "$home" "$BLOCKER" show Automattic | jq -r .state)" "record marked ready"
  pass "fm-machine-blocker: a passing re-check closes the card on its own"
}

test_resolve_refuses_while_steps_remain() {
  local home
  home=$(make_home refuse)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null \
    || fail "raise failed"
  if run_in "$home" "$BLOCKER" resolve Automattic >/dev/null 2>&1; then
    fail "resolve closed a call with steps still waiting"
  fi
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open machine-automattic >/dev/null || fail "hold was closed"
  pass "fm-machine-blocker: resolve refuses while steps remain"
}

test_raise_with_nothing_human_holds_nothing() {
  local home out
  home=$(make_home ready)
  check_output "$home/check.txt"
  sed -i.bak 's/=human:/=present:/' "$home/check.txt"
  out=$(run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt") \
    || fail "raise failed"
  assert_equals "ready: Automattic" "$out" "nothing to hold"
  if run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic >/dev/null 2>&1; then
    fail "card written with nothing waiting"
  fi
  assert_absent "$home/state/when/when-machine-automattic.spec" "no watch armed"
  pass "fm-machine-blocker: a ready machine raises no card"
}

test_clear_removes_record_and_watch() {
  local home
  home=$(make_home clear)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null \
    || fail "raise failed"
  run_in "$home" "$BLOCKER" clear Automattic >/dev/null || fail "clear failed"
  assert_absent "$home/state/machine-pending/Automattic.json" "record removed"
  assert_absent "$home/state/when/when-machine-automattic.spec" "watch retired"
  pass "fm-machine-blocker: clear removes the record and the watch"
}

test_summary_leads_with_blocked_on_you
test_raise_writes_card_hold_record_and_watch
test_recheck_updates_then_resolves_itself
test_resolve_refuses_while_steps_remain
test_raise_with_nothing_human_holds_nothing
test_clear_removes_record_and_watch
