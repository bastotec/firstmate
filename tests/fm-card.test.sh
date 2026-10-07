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

test_write_and_show_round_trip
test_validate_names_the_broken_field
test_show_reports_a_corrupt_card_as_invalid
test_rejects_unsafe_task_ids
test_remove_is_idempotent
