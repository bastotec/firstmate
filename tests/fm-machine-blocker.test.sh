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
    FM_MACHINE_BLOCKER_NOW=2026-10-12T16:21:00Z FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims" "$@"
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
  assert_equals 1 "$(jq '.options | length' <<<"$card")" "card offers only the re-check"
  assert_equals "Done - re-check now" "$(jq -r '.options[0].label' <<<"$card")" "card labels the re-check"
  assert_contains "$(jq -r '.options[0].instruction' <<<"$card")" "Do NOT record this option through answer." "delivered instruction forbids recording an answer"
  assert_contains "$(jq -r '.options[0].instruction' <<<"$card")" "ready Automattic; if it passes, run bin/fm-machine-blocker.sh resolve Automattic" "delivered instruction gates closure on readiness"
  assert_contains "$(jq -r '.options[0].instruction' <<<"$card")" "leave the card open" "delivered instruction preserves the failed re-check"
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
  local home row rc
  home=$(make_home clear)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null \
    || fail "raise failed"
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  run_in "$home" "$BLOCKER" clear Automattic --from "$home/pass.txt" >/dev/null || fail "clear failed"
  rc=0
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open machine-automattic >/dev/null || rc=$?
  assert_equals 1 "$rc" "clear closes the hold before cleanup"
  assert_absent "$home/state/cards/machine-automattic.json" "card removed"
  row=$(run_in "$home" "$ROOT/bin/fm-tasks-axi.sh" show machine-automattic --full) || fail "closed row missing"
  assert_contains "$row" "Stale-clear evidence:" "clear uses evidence, not captain words"
  assert_contains "$row" "reported no step left for the captain" "clear records passing re-check evidence"
  assert_absent "$home/state/machine-pending/Automattic.json" "record removed"
  assert_absent "$home/state/when/when-machine-automattic.spec" "watch retired"
  run_in "$home" "$BLOCKER" clear Automattic >/dev/null || fail "clear is not idempotent"
  pass "fm-machine-blocker: clear re-checks and closes the hold before cleanup"
}

test_clear_refuses_while_steps_remain() {
  local home rec card watch rc
  home=$(make_home clear-blocked)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null || fail "raise failed"
  rec=$(run_in "$home" "$BLOCKER" show Automattic)
  card=$(run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic)
  watch=$(cat "$home/state/when/when-machine-automattic.spec")
  rc=0
  run_in "$home" "$BLOCKER" clear Automattic --from "$home/check.txt" >/dev/null || rc=$?
  assert_equals 1 "$rc" "clear refuses while human steps remain"
  assert_equals "$rec" "$(run_in "$home" "$BLOCKER" show Automattic)" "blocked cleanup keeps the pending record"
  assert_equals "$card" "$(run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic)" "blocked cleanup keeps the card"
  assert_equals "$watch" "$(cat "$home/state/when/when-machine-automattic.spec")" "blocked cleanup keeps monitoring"
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open machine-automattic >/dev/null || fail "blocked cleanup closed the hold"
  pass "fm-machine-blocker: clear preserves a hold with human steps remaining"
}

test_clear_refuses_unreadable_hold() {
  local home rec card watch out rc
  home=$(make_home clear-unreadable)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null || fail "raise failed"
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  rec=$(run_in "$home" "$BLOCKER" show Automattic)
  card=$(run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic)
  watch=$(cat "$home/state/when/when-machine-automattic.spec")
  mv "$home/data/backlog.md" "$home/data/backlog.saved"
  mkdir "$home/data/backlog.md"
  rc=0
  out=$(run_in "$home" "$BLOCKER" clear Automattic --from "$home/pass.txt" 2>&1) || rc=$?
  assert_equals 2 "$rc" "unreadable hold refuses cleanup"
  assert_contains "$out" "fm-captain-hold:" "cleanup read error is visible"
  assert_equals "$rec" "$(run_in "$home" "$BLOCKER" show Automattic)" "read failure preserves the pending record"
  assert_equals "$watch" "$(cat "$home/state/when/when-machine-automattic.spec")" "read failure preserves monitoring"
  rmdir "$home/data/backlog.md"
  mv "$home/data/backlog.saved" "$home/data/backlog.md"
  assert_equals "$card" "$(run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic)" "read failure preserves the card"
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open machine-automattic >/dev/null || fail "read failure lost the hold"
  run_in "$home" "$BLOCKER" clear Automattic --from "$home/pass.txt" >/dev/null || fail "clear cannot retry after recovery"
  assert_absent "$home/state/machine-pending/Automattic.json" "retry removes the record"
  assert_absent "$home/state/cards/machine-automattic.json" "retry closes the card"
  pass "fm-machine-blocker: clear keeps unreadable holds retryable"
}

test_clear_closed_hold_needs_no_recheck() {
  local home
  home=$(make_home clear-closed)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null || fail "raise failed"
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  run_in "$home" "$BLOCKER" ready Automattic --from "$home/pass.txt" || fail "ready failed"
  run_in "$home" "$BLOCKER" resolve Automattic >/dev/null || fail "resolve failed"
  run_in "$home" "$BLOCKER" clear Automattic --from "$home/missing.txt" >/dev/null || fail "clear unnecessarily re-checked a closed hold"
  assert_absent "$home/state/machine-pending/Automattic.json" "closed record removed"
  assert_absent "$home/state/when/when-machine-automattic.spec" "closed watch retired"
  pass "fm-machine-blocker: clear skips the re-check for a closed hold"
}

test_raise_preserves_the_waiting_action() {
  local home rec card watch out from
  home=$(make_home preserve-action)
  check_output "$home/check.txt"
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" \
    --secondmate "inter-graal=Inter Graal" --from "$home/check.txt" >/dev/null || fail "raise failed"
  rec=$(run_in "$home" "$BLOCKER" show Automattic)
  card=$(run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic)
  watch=$(cat "$home/state/when/when-machine-automattic.spec")
  for from in "$home/check.txt" "$home/pass.txt"; do
    if out=$(run_in "$home" "$BLOCKER" raise Automattic --for "create another mate" \
      --secondmate "another=Another" --from "$from" 2>&1); then
      fail "raise replaced a different waiting action"
    fi
    assert_contains "$out" "a different action already waits" "conflicting action is reported"
    assert_equals "$rec" "$(run_in "$home" "$BLOCKER" show Automattic)" "rejected raise preserves the record"
    assert_equals "$card" "$(run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic)" "rejected raise preserves the card"
    assert_equals "$watch" "$(cat "$home/state/when/when-machine-automattic.spec")" "rejected raise preserves the watch"
  done
  if run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" \
    --secondmate "another=Another" --from "$home/check.txt" >/dev/null 2>&1; then
    fail "raise replaced planned mates under the same action title"
  fi
  assert_equals "$rec" "$(run_in "$home" "$BLOCKER" show Automattic)" "conflicting planned mates preserve the record"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" \
    --secondmate "inter-graal=Inter Graal" --from "$home/check.txt" >/dev/null || fail "identical raise refused"
  assert_equals "$rec" "$(run_in "$home" "$BLOCKER" show Automattic)" "identical raise keeps the action"
  pass "fm-machine-blocker: conflicting raises preserve the waiting action"
}

test_raise_publishes_only_after_hold_accepts() {
  local home rec out
  home=$(make_home rejected-hold)
  check_output "$home/check.txt"
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" hold machine-automattic \
    --title "Another existing call" --reason "Existing question" --repo firstmate >/dev/null || fail "fixture hold failed"
  if out=$(run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" 2>&1); then
    fail "raise succeeded despite rejected hold"
  fi
  assert_contains "$out" "different title" "hold refusal is visible"
  assert_absent "$home/state/machine-pending/Automattic.json" "rejected hold publishes no record"
  assert_absent "$home/state/when/when-machine-automattic.spec" "rejected hold arms no watch"
  home=$(make_home rejected-refresh)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null || fail "raise failed"
  rec=$(run_in "$home" "$BLOCKER" show Automattic)
  mv "$home/data/backlog.md" "$home/data/backlog.saved"
  mkdir "$home/data/backlog.md"
  grep -v 'gh-auth=' "$home/check.txt" > "$home/two.txt"
  if run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/two.txt" >/dev/null 2>&1; then
    fail "raise refreshed a record despite rejected hold"
  fi
  assert_equals "$rec" "$(run_in "$home" "$BLOCKER" show Automattic)" "hold failure leaves existing record intact"
  pass "fm-machine-blocker: hold acceptance precedes record publication"
}

test_hold_errors_do_not_resolve() {
  local home rec out rc
  home=$(make_home hold-error)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null || fail "raise failed"
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  run_in "$home" "$BLOCKER" ready Automattic --from "$home/pass.txt" || fail "passing re-check failed"
  rec=$(run_in "$home" "$BLOCKER" show Automattic)
  mv "$home/data/backlog.md" "$home/data/backlog.saved"
  mkdir "$home/data/backlog.md"
  rc=0
  out=$(run_in "$home" "$BLOCKER" resolve Automattic 2>&1) || rc=$?
  assert_equals 2 "$rc" "unreadable hold is an error, not a closed hold"
  assert_contains "$out" "fm-captain-hold:" "hold diagnostic is visible"
  assert_not_contains "$out" "carry on with:" "hold error announces no continuation"
  assert_equals "$rec" "$(run_in "$home" "$BLOCKER" show Automattic)" "hold error does not rewrite the record"
  assert_present "$home/state/cards/machine-automattic.json" "hold error leaves the card intact"
  rmdir "$home/data/backlog.md"
  mv "$home/data/backlog.saved" "$home/data/backlog.md"
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open machine-automattic >/dev/null || fail "hold disappeared on error"
  run_in "$home" "$BLOCKER" resolve Automattic >/dev/null || fail "resolve could not retry after recovery"
  run_in "$home" "$BLOCKER" resolve Automattic >/dev/null || fail "already closed hold is not an error"
  pass "fm-machine-blocker: hold read errors fail visibly and remain retryable"
}

test_alias_punctuation_preserves_distinct_identities() {
  local home alias task
  home=$(make_home aliases)
  check_output "$home/check.txt"
  for alias in Build.one Build-one Build_one; do
    task="machine-$(printf '%s' "$alias" | LC_ALL=C tr '[:upper:]' '[:lower:]')"
    run_in "$home" "$BLOCKER" raise "$alias" --for "create $alias mate" --from "$home/check.txt" >/dev/null || fail "raise collided for $alias"
    assert_equals "$task" "$(run_in "$home" "$BLOCKER" show "$alias" | jq -r .task)" "record preserves alias punctuation"
  done
  for task in machine-build.one machine-build-one machine-build_one; do
    run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open "$task" >/dev/null || fail "distinct hold missing: $task"
    run_in "$home" "$ROOT/bin/fm-card.sh" show "$task" >/dev/null || fail "distinct card missing: $task"
    assert_present "$home/state/when/when-$task.spec" "distinct watch exists: $task"
  done
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  run_in "$home" "$BLOCKER" clear Build.one --from "$home/pass.txt" >/dev/null || fail "clear failed"
  assert_absent "$home/state/when/when-machine-build.one.spec" "clear retires the dotted alias watch"
  assert_present "$home/state/when/when-machine-build-one.spec" "clear preserves the hyphenated alias watch"
  assert_present "$home/state/when/when-machine-build_one.spec" "clear preserves the underscored alias watch"
  pass "fm-machine-blocker: dots, hyphens and underscores name distinct holds and watches"
}

test_raise_again_after_passing_recheck() {
  local home task previous=machine-automattic card out rc
  home=$(make_home raise-again)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" \
    --secondmate "inter-graal=Inter Graal" --from "$home/check.txt" >/dev/null || fail "initial raise failed"
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  run_in "$home" "$BLOCKER" ready Automattic --from "$home/pass.txt" || fail "initial re-check failed"
  run_in "$home" "$BLOCKER" resolve Automattic >/dev/null || fail "initial resolve failed"
  printf '%s\n' 'item doctor-stream-survival=human: disable KillUserProcesses on the machine' >> "$home/pass.txt"
  for task in machine-automattic-2 machine-automattic-3; do
    out=$(run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" \
      --secondmate "inter-graal=Inter Graal" --from "$home/pass.txt") || fail "renewed raise failed: $out"
    assert_contains "$out" "Blocked on you: 1 step on Automattic" "new prerequisite is escalated"
    assert_equals "$task" "$(run_in "$home" "$BLOCKER" show Automattic | jq -r .task)" "renewed record names the fresh task"
    assert_equals "Inter Graal" "$(run_in "$home" "$BLOCKER" show Automattic | jq -r '.planned[0].name')" "renewed action preserves the planned mate"
    run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open "$task" >/dev/null || fail "renewed hold is not open"
    if run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open "$previous" >/dev/null 2>&1; then
      fail "renewed raise reopened the closed task"
    fi
    card=$(run_in "$home" "$ROOT/bin/fm-card.sh" show "$task") || fail "renewed card is missing"
    assert_equals false "$(jq -r .draft <<<"$card")" "renewed card is full"
    assert_contains "$(jq -r .situation <<<"$card")" "doctor-stream-survival" "renewed card names the newly discovered prerequisite"
    assert_present "$home/state/when/when-$task.spec" "renewed watch follows the recorded task"
    assert_absent "$home/state/when/when-$previous.spec" "previous watch is retired"
    run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" \
      --secondmate "inter-graal=Inter Graal" --from "$home/pass.txt" >/dev/null || fail "renewed raise retry failed"
    assert_equals "$task" "$(run_in "$home" "$BLOCKER" show Automattic | jq -r .task)" "retry reuses the matching open hold"
    if [ "$task" = machine-automattic-2 ]; then
      sed 's/doctor-stream-survival=/doctor-stream-survival-extra=/' "$home/pass.txt" > "$home/update.txt"
      rc=0
      run_in "$home" "$BLOCKER" ready Automattic --from "$home/update.txt" || rc=$?
      assert_equals 1 "$rc" "new prerequisite still blocks readiness"
      assert_contains "$(run_in "$home" "$ROOT/bin/fm-card.sh" show "$task" | jq -r .situation)" \
        "doctor-stream-survival-extra" "ready refreshes the suffixed card"
      sed 's/=human:/=present:/' "$home/pass.txt" > "$home/complete.txt"
      run_in "$home" "$BLOCKER" ready Automattic --from "$home/complete.txt" || fail "renewed passing re-check failed"
      run_in "$home" "$BLOCKER" resolve Automattic >/dev/null || fail "renewed resolve failed"
      assert_absent "$home/state/cards/$task.json" "resolve removes the suffixed card"
    fi
    previous=$task
  done
  run_in "$home" "$BLOCKER" clear Automattic --from "$home/complete.txt" >/dev/null || fail "renewed clear failed"
  assert_absent "$home/state/when/when-machine-automattic-3.spec" "clear retires the recorded suffixed watch"
  assert_absent "$home/state/machine-pending/Automattic.json" "clear removes the renewed pending record"
  pass "fm-machine-blocker: subsequent prerequisites get fresh holds, cards and watches"
}

test_renewed_raise_skips_another_actions_open_hold() {
  local home card task
  home=$(make_home occupied-suffix)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null || fail "raise failed"
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  run_in "$home" "$BLOCKER" ready Automattic --from "$home/pass.txt" || fail "re-check failed"
  run_in "$home" "$BLOCKER" resolve Automattic >/dev/null || fail "resolve failed"
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" hold machine-automattic-2 \
    --title "Another existing call" --reason "Existing question" --repo firstmate >/dev/null || fail "fixture hold failed"
  card=$(run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic-2)
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null || fail "renewed raise failed"
  task=$(run_in "$home" "$BLOCKER" show Automattic | jq -r .task)
  assert_equals machine-automattic-3 "$task" "renewed raise skips the other action's task"
  assert_equals "$card" "$(run_in "$home" "$ROOT/bin/fm-card.sh" show machine-automattic-2)" "other action's card is preserved"
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open "$task" >/dev/null || fail "fresh hold missing"
  pass "fm-machine-blocker: renewed escalation skips a hold for another action"
}

test_raise_reuses_recorded_hold_after_pruning() {
  local home task=machine-automattic-2 rc
  home=$(make_home pruned-base)
  check_output "$home/check.txt"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null || fail "initial raise failed"
  sed 's/=human:/=present:/' "$home/check.txt" > "$home/pass.txt"
  run_in "$home" "$BLOCKER" ready Automattic --from "$home/pass.txt" || fail "ready failed"
  run_in "$home" "$BLOCKER" resolve Automattic >/dev/null || fail "resolve failed"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null || fail "renewed raise failed"
  assert_equals "$task" "$(run_in "$home" "$BLOCKER" show Automattic | jq -r .task)" "renewal selects the suffixed hold"
  run_in "$home" "$ROOT/bin/fm-tasks-axi.sh" prune --keep 0 >/dev/null || fail "prune failed"
  rc=0
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open machine-automattic --distinguish-absent >/dev/null || rc=$?
  assert_equals 3 "$rc" "retention removes the closed base task"
  run_in "$home" "$BLOCKER" raise Automattic --for "create Inter Graal" --from "$home/check.txt" >/dev/null || fail "repeated raise failed"
  assert_equals "$task" "$(run_in "$home" "$BLOCKER" show Automattic | jq -r .task)" "retry preserves the recorded open hold after pruning"
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open "$task" >/dev/null || fail "recorded hold disappeared"
  run_in "$home" "$ROOT/bin/fm-card.sh" show "$task" >/dev/null || fail "recorded card disappeared"
  assert_present "$home/state/when/when-$task.spec" "recorded hold keeps its monitoring"
  assert_absent "$home/state/when/when-machine-automattic.spec" "retry does not recreate the base watch"
  rc=0
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open machine-automattic --distinguish-absent >/dev/null || rc=$?
  assert_equals 3 "$rc" "retry does not recreate the base hold"
  run_in "$home" "$BLOCKER" clear Automattic --from "$home/pass.txt" >/dev/null || fail "clear failed on the recorded hold"
  rc=0
  run_in "$home" "$ROOT/bin/fm-captain-hold.sh" open "$task" >/dev/null || rc=$?
  assert_equals 1 "$rc" "clear resolves the preserved hold"
  assert_absent "$home/state/cards/$task.json" "clear removes the preserved card"
  assert_absent "$home/state/when/when-$task.spec" "clear retires the preserved watch"
  pass "fm-machine-blocker: retention cannot displace a recorded open hold"
}

test_summary_leads_with_blocked_on_you
test_raise_writes_card_hold_record_and_watch
test_recheck_updates_then_resolves_itself
test_resolve_refuses_while_steps_remain
test_raise_with_nothing_human_holds_nothing
test_clear_removes_record_and_watch
test_clear_refuses_while_steps_remain
test_clear_refuses_unreadable_hold
test_clear_closed_hold_needs_no_recheck
test_raise_reuses_recorded_hold_after_pruning
test_raise_preserves_the_waiting_action
test_raise_publishes_only_after_hold_accepts
test_hold_errors_do_not_resolve
test_alias_punctuation_preserves_distinct_identities
test_raise_again_after_passing_recheck
test_renewed_raise_skips_another_actions_open_hold
