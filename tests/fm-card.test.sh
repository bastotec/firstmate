#!/usr/bin/env bash
# tests/fm-card.test.sh - decision card files: validation, atomic write,
# show/remove, drafts, backfill, and the stale sweep with clear and restore.
set -u

# shellcheck source=tests/fixtures.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

CARD="$ROOT/bin/fm-card.sh"
TMP_ROOT=$(fm_test_tmproot fm-card-tests)

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

run_card() {  # <home> <args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CARD_NOW=2026-10-07T12:00:00Z "$CARD" "$@"
}

good_card() {  # <path>
  cat > "$1" <<'EOF'
{"project":"cadia","title":"Site language PR #6 - merge?",
 "situation":"Checks green. Review found 2 cases where it picks a language the visitor \"rejected\".\nFix first or merge now?",
 "options":[{"key":"1","label":"Fix, then merge","instruction":"Steer cadia-site: fix both review cases, then merge when green."},
            {"key":"2","label":"Merge now","instruction":"Merge https://github.com/cadia-studio/cadia-site/pull/6 now."}],
 "recommended":"1"}
EOF
}

test_write_and_show_round_trip() {
  local home in out mode
  home=$(make_home roundtrip)
  in="$home/in.json"
  good_card "$in"
  run_card "$home" write site-lang-6 --file "$in" >/dev/null || fail "write refused a valid card"
  out=$(run_card "$home" show site-lang-6) || fail "show failed"
  assert_equals site-lang-6 "$(printf '%s' "$out" | jq -r .task)" "task id stored"
  assert_equals false "$(printf '%s' "$out" | jq -r .draft)" "full card is not a draft"
  assert_equals 2026-10-07T12:00:00Z "$(printf '%s' "$out" | jq -r .created)" "created stamped"
  assert_equals "$(jq -r .situation "$in")" "$(printf '%s' "$out" | jq -r .situation)" "situation round-trips byte for byte"
  mode=$(stat -f %Lp "$home/state/cards/site-lang-6.json" 2>/dev/null || stat -c %a "$home/state/cards/site-lang-6.json")
  assert_equals 600 "$mode" "card is owner-only"
  pass "fm-card: write then show round-trips a valid card at mode 0600"
}

test_validate_names_the_broken_field() {
  local home in err
  home=$(make_home invalid)
  in="$home/in.json"
  good_card "$in"
  jq '.recommended="7"' "$in" > "$in.tmp" && mv "$in.tmp" "$in"
  err=$(run_card "$home" validate --file "$in" 2>&1) && fail "validate accepted a recommendation that names no option"
  assert_contains "$err" "recommended" "error names the recommended field"
  printf '{"title":' > "$in"
  err=$(run_card "$home" validate --file "$in" 2>&1) && fail "validate accepted truncated JSON"
  assert_contains "$err" "invalid card" "truncated JSON is reported as invalid"
  good_card "$in"
  jq '.situation="a\nb\nc"' "$in" > "$in.tmp" && mv "$in.tmp" "$in"
  err=$(run_card "$home" validate --file "$in" 2>&1) && fail "validate accepted a three-line situation"
  assert_contains "$err" "situation" "error names the situation field"
  pass "fm-card: validate refuses broken cards and names the field"
}

test_show_reports_a_corrupt_card_as_invalid() {
  local home rc=0
  home=$(make_home corrupt)
  mkdir -p "$home/state/cards"
  printf '{"task":"x"' > "$home/state/cards/x.json"
  run_card "$home" show x >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a corrupt card exits 2, not 0 or 1"
  pass "fm-card: show reports a corrupt card file as invalid"
}

test_rejects_unsafe_task_ids() {
  local home in rc=0
  home=$(make_home unsafe)
  in="$home/in.json"
  good_card "$in"
  run_card "$home" write '../escape' --file "$in" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a path-like task id is refused"
  assert_absent "$home/state/escape.json" "nothing written outside state/cards"
  pass "fm-card: refuses task ids that are not privacy-safe slugs"
}

test_remove_is_idempotent() {
  local home in
  home=$(make_home remove)
  in="$home/in.json"
  good_card "$in"
  run_card "$home" write t1 --file "$in" >/dev/null
  run_card "$home" remove t1 || fail "remove failed"
  assert_absent "$home/state/cards/t1.json" "card removed"
  run_card "$home" remove t1 || fail "second remove must succeed"
  pass "fm-card: remove is idempotent"
}

tasks_in() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_DATA_OVERRIDE="$home/data" FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-tasks-axi.sh" "$@"
}

test_draft_never_overwrites_a_full_card() {
  local home in out
  home=$(make_home draft)
  run_card "$home" draft d1 --title "Approve PR84?" --project firstmate --situation "Obsolete approval request" >/dev/null \
    || fail "draft failed"
  out=$(run_card "$home" show d1)
  assert_equals true "$(printf '%s' "$out" | jq -r .draft)" "draft flagged"
  assert_equals 0 "$(printf '%s' "$out" | jq '.options|length')" "draft has no options"
  in="$home/in.json"
  good_card "$in"
  run_card "$home" write d1 --file "$in" >/dev/null
  out=$(run_card "$home" draft d1 --title x --project firstmate --situation y)
  assert_contains "$out" "kept:" "draft reports it kept the full card"
  assert_equals false "$(run_card "$home" show d1 | jq -r .draft)" "full card survives a later draft"
  pass "fm-card: a draft never replaces a full card"
}

test_backfill_drafts_every_uncarded_captain_hold() {
  local home out
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home backfill)
  tasks_in "$home" add held-a "Decide A, with a comma" --kind captain --repo cadia >/dev/null
  tasks_in "$home" hold held-a --reason "Line one of the reason" --kind captain >/dev/null
  tasks_in "$home" add plain-b "Not held" --repo cadia >/dev/null
  tasks_in "$home" add other-c "Held, not for the captain" --repo cadia >/dev/null
  tasks_in "$home" hold other-c --reason "waiting on CI" >/dev/null
  out=$(run_card "$home" backfill) || fail "backfill failed"
  assert_contains "$out" "drafted: held-a" "held task drafted"
  assert_not_contains "$out" "plain-b" "unheld task ignored"
  assert_not_contains "$out" "other-c" "non-captain hold ignored"
  assert_equals "Line one of the reason" "$(run_card "$home" show held-a | jq -r .situation)" "reason becomes the situation"
  assert_equals "Decide A, with a comma" "$(run_card "$home" show held-a | jq -r .title)" "full title kept"
  assert_equals cadia "$(run_card "$home" show held-a | jq -r .project)" "repo becomes the project"
  out=$(run_card "$home" backfill)
  assert_not_contains "$out" "drafted: held-a" "backfill is idempotent"
  pass "fm-card: backfill drafts a card for every uncarded captain hold, once"
}

run_captain() {  # <home> <command args...>
  local home=$1
  shift
  PATH="$home/fakebin:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" FM_CARD_NOW=2026-10-07T12:00:00Z \
    "$ROOT/bin/fm-captain-hold.sh" "$@"
}

test_hold_without_card_writes_a_draft() {
  local home
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home hold-draft)
  run_captain "$home" hold card-a --title "Decide A" --repo cadia --reason "Pick a language rule" >/dev/null \
    || fail "hold failed"
  assert_present "$home/state/cards/card-a.json" "hold wrote a card"
  assert_equals true "$(jq -r .draft "$home/state/cards/card-a.json")" "card is a draft"
  assert_equals "Pick a language rule" "$(jq -r .situation "$home/state/cards/card-a.json")" "reason is the draft situation"
  assert_equals cadia "$(jq -r .project "$home/state/cards/card-a.json")" "repo is the draft project"
  pass "fm-captain-hold: a hold without a card gets a draft card"
}

test_hold_with_card_file_writes_the_full_card() {
  local home card
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home hold-card)
  card="$home/card.json"
  printf '%s' '{"project":"cadia","title":"Decide B","situation":"Two ways forward.","options":[{"key":"1","label":"A","instruction":"Do A."},{"key":"2","label":"B","instruction":"Do B."}],"recommended":"2"}' > "$card"
  run_captain "$home" hold card-b --title "Decide B" --repo cadia --reason "r" --card-file "$card" >/dev/null \
    || fail "hold with a card failed"
  assert_equals false "$(jq -r .draft "$home/state/cards/card-b.json")" "full card stored"
  assert_equals 2 "$(jq -r .recommended "$home/state/cards/card-b.json")" "recommendation stored"
  pass "fm-captain-hold: a hold with --card-file stores the full card"
}

test_hold_refuses_an_invalid_card_before_holding() {
  local home bad rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home hold-badcard)
  bad="$home/bad.json"
  printf '{"title":"x"}' > "$bad"
  run_captain "$home" hold card-c --title "Decide C" --reason "r" --card-file "$bad" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "invalid card refuses the hold"
  assert_absent "$home/state/cards/card-c.json" "no card written"
  tasks_in "$home" show card-c >/dev/null 2>&1 && fail "task must not be created when its card is invalid"
  pass "fm-captain-hold: an invalid card refuses the hold before any backlog change"
}

test_answer_removes_the_card() {
  local home dec
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home answer-card)
  run_captain "$home" hold card-d --title "Decide D" --reason "r" >/dev/null || fail "hold failed"
  dec="$home/dec.txt"
  printf 'Go with option 1.\n' > "$dec"
  run_captain "$home" answer card-d --decision-file "$dec" >/dev/null || fail "answer failed"
  assert_absent "$home/state/cards/card-d.json" "answer removed the card"
  run_captain "$home" hold card-e --title "Decide E" --reason "r" >/dev/null || fail "hold failed"
  run_captain "$home" answer card-e --decision-file "$dec" --release >/dev/null || fail "release failed"
  assert_absent "$home/state/cards/card-e.json" "release removed the card"
  pass "fm-captain-hold: answering or releasing a call removes its card"
}

test_write_and_show_round_trip
test_validate_names_the_broken_field
test_show_reports_a_corrupt_card_as_invalid
test_rejects_unsafe_task_ids
test_remove_is_idempotent
test_draft_never_overwrites_a_full_card
test_backfill_drafts_every_uncarded_captain_hold
test_hold_without_card_writes_a_draft
test_hold_with_card_file_writes_the_full_card
test_hold_refuses_an_invalid_card_before_holding
test_answer_removes_the_card
