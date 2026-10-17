#!/usr/bin/env bash
# Evidence-only call withdrawal never completes or restarts its underlying work.
set -eu
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-withdrawal)
command -v tasks-axi >/dev/null || { echo 'skip: tasks-axi not found'; exit 0; }
REAL_TASKS_AXI=$(command -v tasks-axi)
REAL_PYTHON=$(command -v python3)

make_home() {
  local home="$TMP_ROOT/$1" fakebin
  mkdir -p "$home"/{data,state,config,projects}
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '## In flight\n\n## Queued\n\n## Done\n' > "$home/data/backlog.md"
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/tasks.log"
if [ "${1:-}" = unhold ] && [ -f "$FM_HOME/interrupt" ]; then
  rm "$FM_HOME/interrupt"
  echo 'injected unhold interruption' >&2
  exit 1
fi
exec "$REAL_TASKS_AXI" "$@"
SH
  cat > "$fakebin/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_HOME/python.log"
exec "$REAL_PYTHON" "$@"
SH
  chmod +x "$fakebin/"*
  printf '%s\n' "$home"
}
export REAL_TASKS_AXI REAL_PYTHON

tasks_in() { local home=$1; shift; (cd "$home" && "$REAL_TASKS_AXI" "$@"); }
run_captain() {
  local home=$1; shift
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}
prepare() {
  local home=$1
  tasks_in "$home" add work 'Unfinished work' --repo sample --kind ship --start >/dev/null
  tasks_in "$home" add other 'Other question' --repo sample >/dev/null
  run_captain "$home" hold work --reason 'Erroneous cleanup question' >/dev/null
  run_captain "$home" hold other --reason 'Independent question' >/dev/null
  printf 'The question was based on a false completion claim; work remains unpublished.\n' > "$home/evidence"
  printf 'branch=preserved\nrun=preserved\nprovider=preserved\npermission=no-resume\n' > "$home/state/work.meta"
  printf 'needs-decision [key=preserved]: independent wait\n' > "$home/state/work.status"
  cp "$home/state/work.meta" "$home/meta.before"
  cp "$home/state/work.status" "$home/status.before"
  tasks_in "$home" show other --full > "$home/other.before"
  cp "$home/state/cards/other.json" "$home/other-card.before"
  : > "$home/tasks.log"
  : > "$home/python.log"
}
assert_preserved() {
  local home=$1 show
  show=$(tasks_in "$home" show work --full)
  assert_contains "$show" 'state: in_flight' 'withdrawal completed unfinished work'
  assert_not_contains "$show" 'Captain decision:' 'withdrawal invented captain speech'
  assert_not_contains "$show" 'Resolution mode: answered' 'withdrawal recorded an answer'
  assert_not_contains "$show" 'Resolution mode: deferred' 'withdrawal recorded a deferral'
  assert_contains "$show" 'Withdrawal evidence:' 'withdrawal lost its evidence provenance'
  assert_not_contains "$(cat "$home/tasks.log")" 'done work' 'withdrawal requested a done transition'
  assert_not_contains "$(cat "$home/python.log")" 'fm_captain_memory.py capture' 'withdrawal captured captain memory'
  cmp "$home/meta.before" "$home/state/work.meta" || fail 'withdrawal changed branch/run/provider permissions'
  cmp "$home/status.before" "$home/state/work.status" || fail 'withdrawal resumed or changed the worker'
  tasks_in "$home" show other --full > "$home/other.after"
  cmp "$home/other.before" "$home/other.after" || fail 'withdrawal changed another hold'
  cmp "$home/other-card.before" "$home/state/cards/other.json" || fail 'withdrawal removed another card'
}
refuses() {
  local home=$1 expected=$2 out; shift 2
  if out=$(run_captain "$home" "$@" 2>&1); then fail "unexpected success: $*"; fi
  assert_contains "$out" "$expected" "withdrawal refusal did not name $expected"
}

test_release_retry() {
  local home show before
  home=$(make_home release)
  prepare "$home"
  : > "$home/interrupt"
  refuses "$home" 'could not release' withdraw work --evidence-file "$home/evidence" --release
  assert_preserved "$home"
  [ -f "$home/state/cards/work.json" ] || fail 'interruption removed the card before release'
  run_captain "$home" withdraw work --evidence-file "$home/evidence" --release >/dev/null
  assert_preserved "$home"
  show=$(tasks_in "$home" show work --full)
  assert_contains "$show" 'held: no' 'withdrawal did not release the call'
  assert_absent "$home/state/cards/work.json" 'withdrawal left the card'
  before=$show
  run_captain "$home" withdraw work --evidence-file "$home/evidence" --release >/dev/null
  [ "$before" = "$(tasks_in "$home" show work --full)" ] || fail 'exact retry duplicated the evidence'
  refuses "$home" 'withdrawal retry mismatch' withdraw work --evidence-file "$home/evidence" --park 'Wait for tooling'
  printf 'Different evidence\n' > "$home/different"
  refuses "$home" 'withdrawal retry mismatch' withdraw work --evidence-file "$home/different" --release
  FM_CAPTAIN_HOLD_NOW=2030-01-01T00:00:00Z run_captain "$home" hold work --reason 'A new independent question' >/dev/null
  cp "$home/state/cards/work.json" "$home/new-card.before"
  before=$(tasks_in "$home" show work --full)
  refuses "$home" 'withdrawal ownership mismatch' withdraw work --evidence-file "$home/evidence" --release
  [ "$before" = "$(tasks_in "$home" show work --full)" ] || fail 'old retry changed a new call'
  cmp "$home/new-card.before" "$home/state/cards/work.json" || fail 'old retry removed a new call'
  : > "$home/interrupt"
  refuses "$home" 'could not release' withdraw work --evidence-file "$home/different" --release
  run_captain "$home" withdraw work --evidence-file "$home/different" --release >/dev/null
  assert_preserved "$home"
  show=$(tasks_in "$home" show work --full)
  assert_contains "$show" 'held: no' 'fresh withdrawal did not release the new call'
  assert_contains "$show" 'Different evidence' 'fresh withdrawal lost its new evidence'
  [ "$(printf '%s\n' "$show" | grep -o 'Withdrawal evidence:' | wc -l | tr -d ' ')" = 2 ] \
    || fail 'fresh withdrawal did not record exactly one new occurrence'
  assert_absent "$home/state/cards/work.json" 'fresh withdrawal left the new card'
  run_captain "$home" withdraw work --evidence-file "$home/different" --release >/dev/null
  [ "$show" = "$(tasks_in "$home" show work --full)" ] || fail 'fresh withdrawal retry duplicated evidence'
  pass 'evidence-only release preserves unfinished work across fresh calls and exact retries'
}

test_park_and_refusals() {
  local home show
  home=$(make_home parked)
  prepare "$home"
  run_captain "$home" withdraw work --evidence-file "$home/evidence" --park 'Wait for tooling (no resume)' >/dev/null
  assert_preserved "$home"
  show=$(tasks_in "$home" show work --full)
  assert_contains "$show" 'hold_kind: parked' 'withdrawal lost caller-directed preservation wait'
  assert_contains "$show" 'hold_reason: "Wait for tooling [no resume]"' 'withdrawal changed parked reason'
  assert_absent "$home/state/cards/work.json" 'parked withdrawal left a card'
  run_captain "$home" withdraw work --evidence-file "$home/evidence" --park 'Wait for tooling (no resume)' >/dev/null
  refuses "$home" 'withdrawal retry mismatch' withdraw work --evidence-file "$home/evidence" --park 'Different wait'
  tasks_in "$home" add unheld 'Not held' --repo sample >/dev/null
  refuses "$home" 'not held for the captain' withdraw unheld --evidence-file "$home/evidence" --release
  run_captain "$home" stale-clear other --evidence-file "$home/evidence" >/dev/null
  refuses "$home" 'already closed' withdraw other --evidence-file "$home/evidence" --release
  show=$(tasks_in "$home" show other --full)
  assert_contains "$show" 'state: done' 'ordinary stale-clear no longer closes question-only tasks'
  assert_contains "$show" 'Resolution mode: stale-cleared' 'stale-clear mode changed'
  pass 'withdrawal parks only on caller direction and loudly refuses inconsistent ownership'
}

test_parent_finalization_retry() {
  local home parent channel before
  home=$(make_home parent-retry)
  parent="$home/parent"
  mkdir -p "$parent/state"
  printf '# Synthetic home\n' > "$home/AGENTS.md"
  printf 'fixture-peer\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
  prepare "$home"
  channel="$parent/state/fixture-peer.status"
  run_captain "$home" bind board >/dev/null
  printf 'work\nother\n' | run_captain "$home" reconcile-requests --source-id board --source 'Synthetic board' >/dev/null
  cp "$home/state/reconcile-requests/other.request" "$home/other-request.before"
  mv "$channel" "$channel.saved"
  mkdir "$channel"
  refuses "$home" 'could not publish' withdraw work --evidence-file "$home/evidence" --release
  assert_preserved "$home"
  assert_absent "$home/state/cards/work.json" 'durable withdrawal did not retire its card'
  [ -f "$home/state/reconcile-requests/work.request" ] || fail 'failed publication lost the pending request'
  before=$(tasks_in "$home" show work --full)
  rmdir "$channel"
  mv "$channel.saved" "$channel"
  run_captain "$home" withdraw work --evidence-file "$home/evidence" --release >/dev/null
  run_captain "$home" withdraw work --evidence-file "$home/evidence" --release >/dev/null
  [ "$before" = "$(tasks_in "$home" show work --full)" ] || fail 'finalization retry duplicated the evidence'
  assert_absent "$home/state/reconcile-requests/work.request" 'retry did not retire the settled request'
  cmp "$home/other-request.before" "$home/state/reconcile-requests/other.request" || fail 'retry retired an unrelated request'
  [ "$(grep -c 'resolved \[key=captain-hold-work-1\]' "$channel")" = 1 ] || fail 'retry did not resolve exactly its own parent key'
  assert_no_grep 'resolved [key=captain-hold-other-' "$channel" 'withdrawal settled an unrelated key'
  pass 'withdrawal retries parent/key/request finalization after the card is already removed'
}

test_cardless_withdrawal() {
  local home show mode
  for mode in release park; do
    home=$(make_home "cardless-$mode")
    prepare "$home"
    rm "$home/state/cards/work.json"
    if [ "$mode" = release ]; then
      run_captain "$home" withdraw work --evidence-file "$home/evidence" --release >/dev/null
    else
      run_captain "$home" withdraw work --evidence-file "$home/evidence" --park 'Wait for tooling' >/dev/null
    fi
    assert_preserved "$home"
    show=$(tasks_in "$home" show work --full)
    if [ "$mode" = release ]; then
      assert_contains "$show" 'held: no' 'cardless withdrawal did not release the call'
    else
      assert_contains "$show" 'hold_kind: parked' 'cardless withdrawal did not park the call'
      assert_contains "$show" 'hold_reason: Wait for tooling' 'cardless withdrawal changed the wait'
    fi
    assert_absent "$home/state/cards/work.json" 'cardless withdrawal created a card'
  done
  pass 'cardless captain-held work withdraws on authoritative backlog state'
}

test_release_retry
test_park_and_refusals
test_parent_finalization_retry
test_cardless_withdrawal
