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
meta="$FM_HOME/state/$1.meta"
tx=$FM_CONTROL_RELAUNCH_TX
[ ! -f "$FM_HOME/unrelated-replacement" ] || tx=unrelated
awk -F= '$1 != "spawn_gen" && $1 != "control_relaunch_tx"' "$meta" > "$meta.new"
printf 'spawn_gen=%s\ncontrol_relaunch_tx=%s\n' "$tx" "$tx" >> "$meta.new"
mv "$meta.new" "$meta"
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

test_reassigned_slots_cannot_supply_completion
test_slot_ownership_guards_relaunch
test_failed_published_retries_inherit_the_retry_cap
test_unrelated_replacements_do_not_consume_retries
test_replacements_during_forge_reads_are_left_for_a_fresh_scan
