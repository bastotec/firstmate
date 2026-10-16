#!/usr/bin/env bash
# bin/fm_captain_memory.py: the captain's standing instructions are recorded at
# delivery, deduplicated, routed to the right file, and recalled, capped and
# relevant, on every turn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-memory)
MEM="$ROOT/bin/fm_captain_memory.py"
export FM_CAPTAIN_MEMORY_PUSH=0

capture() {  # <home> <text> [mate]
  printf '%s' "$2" | python3 "$MEM" capture --home "$1" --source test --mate "${3:-}"
}

test_standing_instructions_are_recorded_verbatim_once() {
  local home="$TMP_ROOT/primary"
  mkdir -p "$home/data" "$home/state"
  assert_equals 'captured=yes' "$(capture "$home" 'From now on, always open the PR ready for review.' patisserie)" "a standing rule is recorded"
  assert_grep 'From now on, always open the PR ready for review.' "$home/data/captain-shared.md" "the rule is kept word for word"
  assert_grep "in patisserie's chat" "$home/data/captain-shared.md" "the rule names where it was said"
  assert_equals 'captured=duplicate' "$(capture "$home" 'From now on,  always open the PR ready for review.')" "the same rule is not recorded twice"
  assert_equals 'captured=no' "$(capture "$home" 'card api-payments-35: option 1')" "an option pick is not a standing rule"
  assert_equals 'captured=no' "$(capture "$home" 'Merge that one when CI is green.')" "a one-off order is not a standing rule"
  assert_equals 'captured=no' "$(capture "$home" 'Again, please run this test once.')" "a one-off 'again, please' is not a standing rule"
  [ "$(grep -c 'ready for review' "$home/data/captain-shared.md")" = 1 ] || fail "the rule appears exactly once"
  pass "captain memory: a standing rule is recorded verbatim, once, and one-off orders are not"
}

test_a_new_shared_file_can_be_pushed_to_every_mate() {
  local home="$TMP_ROOT/fresh"
  mkdir -p "$home/data"
  capture "$home" 'Never post in public channels.' >/dev/null
  # shellcheck source=bin/fm-config-inherit-lib.sh
  ( . "$ROOT/bin/fm-config-inherit-lib.sh" && shared_captain_header_valid "$home/data/captain-shared.md" ) \
    || fail "a shared file created by a capture must carry the header the push requires"
  pass "captain memory: a shared file a capture creates is accepted by the fleet push"
}

test_rules_are_told_apart_and_kept_word_for_word() {
  local home="$TMP_ROOT/identity"
  mkdir -p "$home/data"
  capture "$home" 'Never merge on red without my approval.' >/dev/null
  assert_equals 'captured=yes' "$(capture "$home" 'Never merge on red.')" "a shorter rule is its own rule"
  assert_equals 'captured=yes' "$(capture "$home" "Don't ask me to approve merges again.")" "a 'don't ... again' rule with several words between is recorded"
  capture "$home" "$(printf 'Always deploy like this:\n\n    make deploy\n    make verify')" >/dev/null
  assert_grep '    make deploy' "$home/data/captain-shared.md" "a multiline rule keeps its own lines and indentation"
  assert_contains "$(python3 "$MEM" recall --home "$home")" 'make verify' "a multiline rule is recalled whole"
  assert_equals 'captured=duplicate' "$(capture "$home" "$(printf 'Always deploy like this:\n\n    make deploy\n    make verify')")" "a multiline rule is not recorded twice"
  pass "captain memory: rules are compared whole, cues span several words, and multiline rules stay verbatim"
}

test_concurrent_captures_and_upkeep_lose_nothing() {
  local home="$TMP_ROOT/concurrent" i
  mkdir -p "$home/data" "$home/state"
  for i in $(seq 1 12); do
    capture "$home" "Always remember concurrent rule number $i." >/dev/null &
    [ $((i % 4)) != 0 ] || python3 "$MEM" upkeep --home "$home" >/dev/null &
  done
  wait
  for i in $(seq 1 12); do
    assert_grep "Always remember concurrent rule number $i." "$home/data/captain-shared.md" "capture $i survives concurrent captures and upkeep"
  done
  [ "$(grep -c '^This file is main-authoritative' "$home/data/captain-shared.md")" = 1 ] || fail "the header is written once"
  pass "captain memory: concurrent captures and upkeep never lose a rule"
}

test_a_restated_rule_counts_as_a_memory_failure() {
  local home="$TMP_ROOT/repeat"
  mkdir -p "$home/data" "$home/state"
  printf '%s' 'I told you, never page me from a worker.' | python3 "$MEM" capture --home "$home" --source 'corr=1' >/dev/null
  printf '%s' 'I told you, never page me from a worker.' | python3 "$MEM" capture --home "$home" --source 'corr=1' >/dev/null
  printf '%s' 'I told you, never page me from a worker.' | python3 "$MEM" capture --home "$home" --source 'corr=2' >/dev/null
  [ "$(grep -c 'never page me from a worker' "$home/state/captain-memory-repeats.log")" = 2 ] \
    || fail "each delivery of a correction counts once, a replay of the same delivery does not"
  pass "captain memory: every time the captain restates a rule is counted, replays are not"
}

test_recordings_share_one_fleet_push() {
  local dir="$TMP_ROOT/push" home="$TMP_ROOT/push/home"
  mkdir -p "$home/data" "$home/state"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-config-push.sh" <<'SH'
#!/usr/bin/env bash
echo pushed >> "$FM_HOME/pushes"
SH
  chmod +x "$dir/bin/fm-config-push.sh"
  for rule in 'Always one.' 'Always two.' 'Always three.'; do
    printf '%s' "$rule" | FM_CAPTAIN_MEMORY_PUSH=1 python3 "$dir/bin/fm_captain_memory.py" capture --home "$home" --source t >/dev/null
  done
  sleep 23
  [ "$(wc -l < "$home/pushes" 2>/dev/null | tr -d ' ')" = 1 ] || fail "three rules within the debounce window must share one push ($(cat "$home/pushes" 2>/dev/null | wc -l))"
  pass "captain memory: rules recorded close together share one fleet push"
}

test_mate_homes_route_to_the_right_file() {
  local parent="$TMP_ROOT/route-parent" local_mate="$TMP_ROOT/route-local" remote_mate="$TMP_ROOT/route-remote"
  mkdir -p "$parent/data" "$local_mate/data" "$remote_mate/data"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$local_mate/.fm-secondmate-parent"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$remote_mate/.fm-secondmate-parent"
  capture "$local_mate" 'Always run the tests before you push.' >/dev/null
  assert_grep 'Always run the tests before you push.' "$parent/data/captain-shared.md" "a local mate's capture reaches the primary's shared file"
  capture "$remote_mate" 'Never post in public channels.' >/dev/null
  assert_grep 'Never post in public channels.' "$remote_mate/data/captain.md" "a remote mate's capture stays in its own file"
  pass "captain memory: captures route to the primary's shared file, or a remote mate's own"
}

test_recall_is_capped_newest_first_and_relevant() {
  local home="$TMP_ROOT/recall" out i
  mkdir -p "$home/data"
  { printf '# Shared captain preferences\n\n'
    printf -- '- 2026-09-01 old rule: the voicemail greeting stays in Portuguese.\n'
    for i in $(seq 1 200); do printf -- '- 2026-10-%02d filler rule number %s about unrelated matters of routine.\n' $((i % 14 + 1)) "$i"; done
    printf -- '- 2026-10-16 the newest shared rule.\n'
  } > "$home/data/captain-shared.md"
  { printf '# Captain preferences - main home\n\n'
    for i in $(seq 1 80); do printf -- '- 2026-08-%02d an old home rule %s that is long enough to fill a lot of the budget.\n' $((i % 28 + 1)) "$i"; done
  } > "$home/data/captain.md"
  out=$(python3 "$MEM" recall --home "$home" --query 'what language is the voicemail greeting in?')
  assert_contains "$out" '[fm-captain-memory]' "the block opens with its marker"
  assert_contains "$out" '[/fm-captain-memory]' "the block closes with its marker"
  assert_contains "$out" 'the newest shared rule' "the newest rule is recalled before older home rules"
  assert_contains "$out" 'voicemail greeting stays in Portuguese' "an old but relevant rule is recalled past the cap"
  assert_contains "$out" 'more on record' "the block says more rules exist"
  [ "${#out}" -lt 8800 ] || fail "the block must respect its cap (${#out} chars)"
  out=$(python3 "$MEM" recall --home "$home" --max-bytes 2000)
  [ "${#out}" -lt 2000 ] || fail "the block must fit the room the turn leaves (${#out} chars)"
  pass "captain memory: recall is capped, newest first across both files, and pulls in relevant older rules"
}

test_upkeep_dedupes_collects_candidates_and_counts_repeats() {
  local home="$TMP_ROOT/upkeep" mate="$TMP_ROOT/upkeep-mate/firstmate" out
  mkdir -p "$home/data" "$home/state" "$mate/data"
  printf '# Shared captain preferences\n\n- rule one\n- rule one\n' > "$home/data/captain-shared.md"
  printf -- '- mate (home: %s; scope: x)\n' "$mate" > "$home/data/secondmates.md"
  printf '# Shared captain preferences\n\n- rule one\n- a rule the mate wrote locally\n' > "$mate/data/.captain-shared.md.quarantine.1"
  printf '2026-10-16T10:00:00Z\tmate\tsrc\tI told you\n' > "$home/state/captain-memory-repeats.log"
  out=$(python3 "$MEM" upkeep --home "$home")
  [ "$(grep -c '^- rule one$' "$home/data/captain-shared.md")" = 1 ] || fail "upkeep must dedupe"
  assert_grep 'a rule the mate wrote locally' "$home/state/captain-memory-candidates.md" "a mate's local rule becomes a candidate"
  grep -q 'a rule the mate wrote locally' "$home/data/captain-shared.md" && fail "a quarantined rule is never imported unreviewed"
  [ -f "$mate/data/captain.md" ] || fail "upkeep seeds a mate home with no captain.md"
  [ -f "$home/data/captain.md" ] || fail "upkeep seeds its own home with no captain.md"
  assert_contains "$out" 'repeats since last upkeep: 1' "upkeep counts memory failures"
  out=$(python3 "$MEM" upkeep --home "$home")
  assert_contains "$out" '0 new candidates' "a reviewed quarantine is not collected again"
  assert_contains "$out" 'repeats since last upkeep: 0' "each repeat is counted once"
  head -c 33000 /dev/zero | tr '\0' 'x' >> "$home/data/captain-shared.md"
  assert_contains "$(python3 "$MEM" upkeep --home "$home")" "$home/data/captain-shared.md" "an oversized shared file is reported"
  pass "captain memory: nightly upkeep dedupes, collects mates' local rules for review, seeds homes and counts repeats"
}

test_upkeep_dedupes_collects_candidates_and_counts_repeats
test_standing_instructions_are_recorded_verbatim_once
test_a_new_shared_file_can_be_pushed_to_every_mate
test_rules_are_told_apart_and_kept_word_for_word
test_concurrent_captures_and_upkeep_lose_nothing
test_a_restated_rule_counts_as_a_memory_failure
test_recordings_share_one_fleet_push
test_mate_homes_route_to_the_right_file
test_recall_is_capped_newest_first_and_relevant
