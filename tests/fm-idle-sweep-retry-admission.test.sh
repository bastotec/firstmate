#!/usr/bin/env bash
set -u

# shellcheck source=tests/fm-idle-sweep.test.sh
FM_IDLE_SWEEP_TEST_SKIP_RUN=1 . "$(dirname "${BASH_SOURCE[0]}")/fm-idle-sweep.test.sh"

prepare_retry_case() {
  local dir=$1 target
  add_worker "$dir" stopped 'state: failed · source: status-log · stopped' 90000
  fm_git_init_commit "$dir/pool/1/firstmate"
  fm_test_stream_task "$dir/home/state" stopped "$dir/endpoint-input" >> "$dir/home/state/stopped.meta"
  printf 'harness=deck\nproject=%s\nspawn_gen=original\n' "$dir/pool/1/firstmate" >> "$dir/home/state/stopped.meta"
  target=$(sed -n 's/^window=//p' "$dir/home/state/stopped.meta")
  fm_test_fake_stream_foreground "$target" zsh
  "$dir/bin/fm-busy-event.sh" arm "$dir/home/state" stopped --state idle >/dev/null
  mkdir -p "$dir/home/data/stopped"
  printf '# Continue the task\n' > "$dir/home/data/stopped/brief.md"
  cp "$ROOT/bin/fm-control.sh" "$dir/bin/"
  cat > "$dir/bin/fm-spawn.sh" <<'SPAWN'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$FM_HOME/spawn-calls"
[ ! -f "$FM_HOME/no-publication" ] || exit 1
meta="$FM_HOME/state/$1.meta"
tx=$FM_CONTROL_RELAUNCH_TX
[ ! -f "$FM_HOME/unrelated-replacement" ] || tx=unrelated
awk -F= '$1 != "spawn_gen" && $1 != "control_relaunch_tx"' "$meta" > "$meta.new"
printf 'spawn_gen=%s\ncontrol_relaunch_tx=%s\n' "$tx" "$tx" >> "$meta.new"
mv "$meta.new" "$meta"
if [ -f "$FM_HOME/owner-success" ]; then
  id=$(sed -n 's/^stream_endpoint_id=//p' "$meta")
  curl -fsS -m 10 --config <(printf 'header = "Authorization: Bearer %s"\n' "$FM_STREAM_TOKEN") \
    -X POST -H 'Content-Type: application/json' \
    --data-binary '{"foreground":[{"pid":"","name":"fm-deck-worker","argv0":"fm-deck-worker","args":"fm-deck-worker"}]}' \
    "$FM_TEST_STREAM_URL/v1/test/endpoints/$id" >/dev/null || exit 1
  exit 0
fi
echo 'error: replacement launch delivery failed' >&2
exit 1
SPAWN
  chmod +x "$dir/bin/fm-spawn.sh"
}

test_slot_ownership_guards_relaunch() {
  local dir ownership guarded before out rc target
  local -a args
  for ownership in other unreadable late; do
    for guarded in yes no; do
      [ "$ownership-$guarded" != late-no ] || continue
      dir=$(new_case "ownership-$ownership-$guarded")
      prepare_retry_case "$dir"
      target=$(sed -n 's/^window=//p' "$dir/home/state/stopped.meta")
      fm_test_fake_stream_foreground "$target" fm-deck-worker
      case "$ownership" in
        other) printf 'task=claimant\n' > "$dir/pool/1/.fm-slot-owner" ;;
        unreadable) mkdir "$dir/pool/1/.fm-slot-owner" ;;
        late)
          cat > "$dir/home/on-crew-state" <<'HOOK'
#!/usr/bin/env bash
[ ! -d "$FM_HOME/state/.control-$1.lock" ] || printf 'task=claimant\n' > "$FM_HOME/../pool/1/.fm-slot-owner"
HOOK
          chmod +x "$dir/home/on-crew-state"
          ;;
      esac
      before=$(cat "$dir/home/state/stopped.meta")
      args=(stopped relaunch --note 'Continue the unfinished work')
      [ "$guarded" = no ] || args+=(--expected-record "$before" --if-still-stopped "$(wc -c < "$dir/home/state/stopped.status" | tr -d ' ')")
      rc=0
      out=$(PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown FM_HOME="$dir/home" \
        "$dir/bin/fm-control.sh" "${args[@]}" 2>&1) || rc=$?
      assert_equals 1 "$rc" "$ownership must refuse relaunch: $out"
      assert_contains "$out" 'owner' "the refusal must identify the ownership conflict"
      assert_equals "$before" "$(cat "$dir/home/state/stopped.meta")" "ownership refusal changed the incarnation"
      assert_equals '# Continue the task' "$(cat "$dir/home/data/stopped/brief.md")" "ownership refusal changed the instructions"
      [ ! -s "$dir/endpoint-input" ] || fail "ownership refusal sent lifecycle input"
      assert_absent "$dir/home/spawn-calls" "ownership refusal launched a replacement"
    done
  done
  pass 'fm-control: foreign and unreadable claims refuse guarded and ordinary relaunches before stop'
}

test_failed_published_retries_inherit_the_retry_cap() {
  local dir home attempt prior tx previous_tx=
  for home in main secondmate; do
    dir=$(new_case "published-failure-$home")
    prepare_retry_case "$dir"
    [ "$home" != secondmate ] || make_secondmate_home "$dir" mate
    for attempt in 1 2; do
      prior=$(cat "$dir/home/state/stopped.meta")
      sweep "$dir" scan --now || fail 'failed-after-publication scan failed'
      assert_equals 'failed asked' "$(summary_of "$dir" stopped)" 'a partial launch failure must go to the first mate'
      assert_equals "$attempt" "$(wc -l < "$dir/home/spawn-calls" | tr -d ' ')" 'the launch attempt was not made'
      assert_equals "$prior" "$(cat "$dir/home/state/stopped.control-relaunch.meta-prior")" 'the transaction lost its prior incarnation'
      tx=$(sed -n 's/^control_relaunch_tx=//p' "$dir/home/state/stopped.meta")
      [ -n "$tx" ] && [ "$tx" != "$previous_tx" ] || fail 'a failed launch must retain a new transaction identity'
      assert_equals "$tx" "$(sed -n 's/^relaunch_tx=//p' "$dir/home/state/stopped.control-relaunch")" 'the failed journal lost its transaction identity'
      assert_equals "$(wc -c < "$dir/home/state/stopped.status" | tr -d ' ') $attempt" \
        "$(cat "$dir/home/state/idle-sweep/stopped.retried")" 'the replacement must inherit the consumed retry count'
      assert_present "$dir/home/state/idle-sweep/stopped.raised" 'the partial failure was not handed off'
      if [ "$home" = main ]; then
        assert_contains "$(cat "$dir/home/state/.wake-queue")" 'decide yourself whether to retire or retry stopped' 'the first mate was not woken'
      else
        assert_contains "$(cat "$dir/parent/state/mate.status")" 'needs-decision [key=idle-stopped]' 'the parent mate was not asked'
      fi
      sweep "$dir" scan --now || fail 'unchanged partial-failure scan failed'
      assert_equals 'raised none' "$(summary_of "$dir" stopped)" 'the same failed stretch was retried'
      printf 'failed: replacement stopped after attempt %s\n' "$attempt" >> "$dir/home/state/stopped.status"
      age_file "$dir/home/state/stopped.status" 90000
      previous_tx=$tx
    done
    sweep "$dir" scan --now || fail 'retry-cap scan failed'
    assert_equals 'failed asked' "$(summary_of "$dir" stopped)" 'the exhausted replacement must go to the first mate'
    assert_equals 2 "$(wc -l < "$dir/home/spawn-calls" | tr -d ' ')" 'a replacement received a fresh retry beyond the cap'
    assert_no_captain_call "$dir" 'a failed published replacement'
  done
  pass 'fm-idle-sweep: partial launch failures consume retries across replacement generations and hand off'
}

test_unrelated_replacements_do_not_consume_retries() {
  local dir
  dir=$(new_case unrelated-during-launch)
  prepare_retry_case "$dir"
  touch "$dir/home/unrelated-replacement"
  sweep "$dir" scan --now || fail 'unrelated replacement scan failed'
  assert_equals 'unknown none' "$(summary_of "$dir" stopped)" 'an unrelated replacement must wait for a fresh scan'
  assert_absent "$dir/home/state/idle-sweep/stopped.retried" 'an unrelated replacement consumed a retry'
  assert_absent "$dir/home/state/idle-sweep/stopped.raised" 'an unrelated replacement got a stale handoff'
  [ ! -s "$dir/home/state/.wake-queue" ] || fail 'an unrelated replacement got a stale wake'
  pass 'fm-idle-sweep: unrelated replacement metadata is not charged to the failed retry'
}

test_intervening_owner_relaunch_is_not_attributed_to_the_sweep() {
  local dir home before tx
  for home in main secondmate; do
    dir=$(new_case "intervening-owner-$home")
    prepare_retry_case "$dir"
    [ "$home" != secondmate ] || make_secondmate_home "$dir" mate
    before=$(cat "$dir/home/state/stopped.meta")
    mv "$dir/bin/fm-control.sh" "$dir/bin/fm-control-real.sh"
    cat > "$dir/bin/fm-control.sh" <<'CONTROL'
#!/usr/bin/env bash
printf '%s\n' "$FM_CONTROL_RELAUNCH_TX" > "$FM_HOME/sweep-tx"
touch "$FM_HOME/no-publication"
rc=0
"$FM_HOME/../bin/fm-control-real.sh" "$@" || rc=$?
printf '%s\n' "$rc" > "$FM_HOME/sweep-rc"
[ ! -d "$FM_HOME/state/.control-$1.lock" ] || exit 2
rm "$FM_HOME/no-publication"
touch "$FM_HOME/owner-success"
(
  unset FM_CONTROL_RELAUNCH_TX
  "$FM_HOME/../bin/fm-control-real.sh" "$1" relaunch --note 'Continue the work after the failed automatic launch'
) > "$FM_HOME/owner-out" 2>&1
printf '%s\n' "$?" > "$FM_HOME/owner-rc"
exit "$rc"
CONTROL
    chmod +x "$dir/bin/fm-control.sh"

    sweep "$dir" scan --now || fail 'intervening owner scan failed'

    assert_equals 1 "$(cat "$dir/home/sweep-rc")" 'the automatic relaunch must fail before publication'
    assert_equals 0 "$(cat "$dir/home/owner-rc")" "the owner relaunch must succeed: $(cat "$dir/home/owner-out")"
    assert_equals 2 "$(wc -l < "$dir/home/spawn-calls" | tr -d ' ')" 'both relaunches must reach the launch owner'
    tx=$(sed -n 's/^control_relaunch_tx=//p' "$dir/home/state/stopped.meta")
    [ -n "$tx" ] && [ "$tx" != "$(cat "$dir/home/sweep-tx")" ] || fail 'the owner must publish its own transaction'
    assert_equals "$tx" "$(sed -n 's/^relaunch_tx=//p' "$dir/home/state/stopped.control-relaunch")" 'the owner journal must match its replacement'
    assert_equals complete "$(sed -n 's/^phase=//p' "$dir/home/state/stopped.control-relaunch")" 'the owner transaction must finish'
    assert_equals "$before" "$(cat "$dir/home/state/stopped.control-relaunch.meta-prior")" 'the owner must checkpoint the original incarnation'
    assert_equals 'unknown none' "$(summary_of "$dir" stopped)" 'the recovered replacement must wait for a fresh scan'
    assert_absent "$dir/home/state/idle-sweep/stopped.retried" 'the owner replacement consumed an automatic retry'
    assert_absent "$dir/home/state/idle-sweep/stopped.raised" 'the owner replacement got a stale handoff'
    [ ! -s "$dir/home/state/.wake-queue" ] || fail 'the owner replacement got a stale wake'
    if [ "$home" = secondmate ]; then
      [ ! -s "$dir/parent/state/mate.status" ] || fail 'the owner replacement got a parent handoff'
    fi
    assert_no_captain_call "$dir" 'an intervening owner relaunch'
  done
  pass 'fm-idle-sweep: an intervening owner relaunch is neither counted nor handed off'
}

test_kindless_workers_remain_eligible_for_guarded_retry() {
  local dir
  dir=$(new_case kindless-retry)
  prepare_retry_case "$dir"
  sed '/^kind=/d' "$dir/home/state/stopped.meta" > "$dir/kindless.meta"
  mv "$dir/kindless.meta" "$dir/home/state/stopped.meta"

  sweep "$dir" scan --now || fail 'kindless retry scan failed'

  assert_equals stopped "$(cat "$dir/home/spawn-calls")" 'a kindless worker must reach the launch owner'
  assert_equals 'failed asked' "$(summary_of "$dir" stopped)" 'the published failure must be handed off'
  assert_equals "$(wc -c < "$dir/home/state/stopped.status" | tr -d ' ') 1" \
    "$(cat "$dir/home/state/idle-sweep/stopped.retried")" 'a kindless published failure must consume one retry'
  assert_no_captain_call "$dir" 'a kindless retry'
  pass 'fm-control: guarded relaunch defaults a kindless worker to ship'
}

declare_approval_wait() {  # <dir> [task]
  local dir=$1 id=${2:-stopped}
  printf 'Do not resume any action pending explicit parent approval release.\n' > "$dir/approval-instruction"
  printf 'blocked [key=parent-approval]: Explicit parent release required\n' >> "$dir/home/state/$id.status"
  PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$dir/bin/fm-approval-wait.sh" declare "$id" --key parent-approval \
    --expected-record "$(cat "$dir/home/state/$id.meta")" --instruction-file "$dir/approval-instruction"
}

release_approval_wait() {  # <dir> [task]
  local dir=$1 id=${2:-stopped} digest
  digest=$(jq -r .instruction_sha256 "$dir/home/state/$id.approval-wait")
  printf 'The parent explicitly releases this approval exclusion.\n' > "$dir/release-instruction"
  PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$dir/bin/fm-approval-wait.sh" release "$id" \
    --instruction-sha256 "$digest" --release-file "$dir/release-instruction"
}

test_approval_excludes_actions_until_explicit_release() {
  local dir before attempt digest rc
  dir=$(new_case approval-wait)
  prepare_retry_case "$dir"
  before=$(cat "$dir/home/state/stopped.meta")
  declare_approval_wait "$dir" || fail 'approval declaration failed'
  declare_approval_wait "$dir" || fail 'identical declaration was not idempotent'
  digest=$(jq -r .instruction_sha256 "$dir/home/state/stopped.approval-wait")
  rc=0
  PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$dir/bin/fm-approval-wait.sh" release stopped \
    --instruction-sha256 "$digest" --release-file "$dir/approval-instruction" >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" 'the original prohibition cannot serve as its own release'
  for attempt in 1 2 3; do
    case "$attempt" in
      1) printf 'state: blocked · source: status-log · approval pending\n' > "$dir/home/crew/stopped" ;;
      2) printf 'state: failed · source: run-step · terminal refusal\n' > "$dir/home/crew/stopped" ;;
      3) printf 'state: done · source: run-step · later completion\n' > "$dir/home/crew/stopped" ;;
    esac
    printf 'working: Evidence changed on scan %s\nresolved [key=idle-question]: Idle question settled\n' "$attempt" >> "$dir/home/state/stopped.status"
    age_file "$dir/home/state/stopped.status" 90000
    sweep "$dir" scan --now || fail 'approval scan failed'
    assert_equals 'approval-wait none' "$(summary_of "$dir" stopped)" 'approval must exclude automatic retry and retirement'
    assert_equals "$before" "$(cat "$dir/home/state/stopped.meta")" 'approval changed custody'
    assert_equals '# Continue the task' "$(cat "$dir/home/data/stopped/brief.md")" 'approval changed instructions'
    assert_absent "$dir/home/spawn-calls" 'approval launched a replacement'
    assert_absent "$dir/home/state/idle-sweep/stopped.retried" 'approval consumed a retry'
    assert_absent "$dir/home/state/idle-sweep/stopped.raised" 'approval raised a duplicate retry question'
    assert_absent "$dir/home/teardown-calls" 'approval retired the worker'
    assert_no_captain_call "$dir" 'approval wait'
  done
  release_approval_wait "$dir" || fail 'explicit approval release failed'
  assert_absent "$dir/home/spawn-calls" 'release itself resumed work'
  printf 'state: failed · source: status-log · stopped\n' > "$dir/home/crew/stopped"
  age_file "$dir/home/state/stopped.status" 90000
  sweep "$dir" scan --now || fail 'released scan failed'
  assert_equals stopped "$(cat "$dir/home/spawn-calls")" 'explicit release must restore ordinary recovery'
  pass 'fm-idle-sweep: explicit approval survives changed evidence; supported release restores retry'
}

test_keyed_capability_blocker_remains_retry_eligible() {
  local dir
  dir=$(new_case capability-blocker)
  prepare_retry_case "$dir"
  printf 'blocked [key=capability]: Capability unavailable\n' >> "$dir/home/state/stopped.status"
  printf 'state: blocked · source: status-log · capability unavailable\n' > "$dir/home/crew/stopped"
  age_file "$dir/home/state/stopped.status" 90000
  sweep "$dir" scan --now || fail 'ordinary capability scan failed'
  assert_equals stopped "$(cat "$dir/home/spawn-calls")" 'a keyed capability failure was mistaken for an approval wait'
  pass 'fm-idle-sweep: ordinary keyed capability blockers remain retry-eligible'
}

test_approval_between_scan_and_control_refuses_locked_action() {
  local dir before
  dir=$(new_case late-approval)
  prepare_retry_case "$dir"
  before=$(cat "$dir/home/state/stopped.meta")
  printf 'Parent approval is required before any recovery.\n' > "$dir/approval-instruction"
  printf 'blocked [key=parent-approval]: Explicit parent release required\n' >> "$dir/home/state/stopped.status"
  age_file "$dir/home/state/stopped.status" 90000
  mv "$dir/bin/fm-control.sh" "$dir/bin/fm-control-real.sh"
  cat > "$dir/bin/fm-control.sh" <<'CONTROL'
#!/usr/bin/env bash
"$FM_HOME/../bin/fm-approval-wait.sh" declare "$1" --key parent-approval --expected-record "$(cat "$FM_HOME/state/$1.meta")" \
  --instruction-file "$FM_HOME/../approval-instruction" || exit 1
exec "$FM_HOME/../bin/fm-control-real.sh" "$@"
CONTROL
  chmod +x "$dir/bin/fm-control.sh"
  sweep "$dir" scan --now || fail 'late approval scan failed'
  assert_equals 'unknown none' "$(summary_of "$dir" stopped)" 'late approval must refuse the locked stopped action'
  assert_equals "$before" "$(cat "$dir/home/state/stopped.meta")" 'late approval changed custody'
  assert_equals '# Continue the task' "$(cat "$dir/home/data/stopped/brief.md")" 'late approval changed instructions'
  [ ! -s "$dir/endpoint-input" ] || fail 'late approval sent lifecycle input'
  assert_absent "$dir/home/spawn-calls" 'late approval launched a replacement'
  assert_absent "$dir/home/state/idle-sweep/stopped.retried" 'late approval consumed a retry'
  pass 'fm-control: approval declared after scan admission refuses under the shared control lock'
}

test_recordless_approval_survives_changed_ledger() {
  local dir attempt
  dir=$(new_case recordless-approval)
  prepare_retry_case "$dir"
  declare_approval_wait "$dir" || fail 'approval declaration failed'
  rm "$dir/home/state/stopped.meta"
  printf 'stopped\tfixture-endpoint\n' > "$dir/home/orphans"
  for attempt in 1 2; do
    printf 'failed: Changed evidence %s\n' "$attempt" >> "$dir/home/state/stopped.status"
    sweep "$dir" scan --now || fail 'recordless approval scan failed'
    assert_equals 'approval-wait none' "$(summary_of "$dir" idle-orphan-stopped)" 'recordless approval was not retained'
    assert_equals '--list-orphans' "$(calls "$dir" retire-calls | tail -1)" 'recordless approval attempted retirement'
  done
  release_approval_wait "$dir" || fail 'recordless explicit release failed'
  sweep "$dir" scan --now || fail 'released recordless scan failed'
  assert_equals 'dead cleaned' "$(summary_of "$dir" idle-orphan-stopped)" 'released recordless endpoint did not progress'
  pass 'fm-idle-sweep: recordless approval survives changed ledger and supports explicit release'
}

test_corrupt_approval_record_excludes_actions() {
  local dir
  dir=$(new_case corrupt-approval)
  prepare_retry_case "$dir"
  ln -s "$dir/missing" "$dir/home/state/stopped.approval-wait"
  sweep "$dir" scan --now || fail 'corrupt approval scan failed'
  assert_equals 'approval-wait none' "$(summary_of "$dir" stopped)" 'an unsafe approval object must not imply release'
  assert_absent "$dir/home/spawn-calls" 'unsafe approval launched a replacement'
  assert_absent "$dir/home/teardown-calls" 'unsafe approval retired the worker'
  pass 'fm-idle-sweep: corrupt approval records retain the exclusion'
}

test_approval_excludes_actions_until_explicit_release
test_keyed_capability_blocker_remains_retry_eligible
test_approval_between_scan_and_control_refuses_locked_action
test_corrupt_approval_record_excludes_actions
test_recordless_approval_survives_changed_ledger
test_reassigned_slots_cannot_supply_completion
test_slot_ownership_guards_relaunch
test_failed_published_retries_inherit_the_retry_cap
test_unrelated_replacements_do_not_consume_retries
test_intervening_owner_relaunch_is_not_attributed_to_the_sweep
test_kindless_workers_remain_eligible_for_guarded_retry
test_retired_worker_keeps_ledger_only_merged_mr_without_a_card kindless-done
test_replacements_during_forge_reads_are_left_for_a_fresh_scan
