#!/usr/bin/env bash
# tests/fm-order.test.sh - order proposal files: validation, atomic owner-only
# write, show/list/remove, and the 24-hour sweep.
set -u

# shellcheck source=tests/fixtures.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

ORDER="$ROOT/bin/fm-order.sh"
TMP_ROOT=$(fm_test_tmproot fm-order-tests)

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

make_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state"
  printf '%s\n' "$home"
}

run_order() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_ORDER_NOW="${NOW:-2026-10-07T12:00:00Z}" "$ORDER" "$@"
}

good_proposal() {  # <path>
  cat > "$1" <<'EOF'
{"request":"cadia: fix the review cases on the site PR and merge when green",
 "lines":[{"project":"cadia","target":"cadia-site #6","action":"fix 2 review cases → merge when green"},
          {"project":"cadia","target":"new task","action":"add a regression test for the \"rejected\" language"}],
 "note":"PR #6 is green; the two cases are from yesterday's review."}
EOF
}

mode_of() {  # <path>
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f %Lp "$1" ;;
    *) stat -c %a "$1" ;;
  esac
}

test_write_and_show_round_trip() {
  local home in out
  home=$(make_home roundtrip)
  in="$home/in.json"
  good_proposal "$in"
  run_order "$home" write o-1-1 --file "$in" >/dev/null || fail "write refused a valid proposal"
  out=$(run_order "$home" show o-1-1) || fail "show failed"
  assert_equals o-1-1 "$(printf '%s' "$out" | jq -r .id)" "id stored"
  assert_equals 1 "$(printf '%s' "$out" | jq -r .version)" "version stamped"
  assert_equals 2 "$(printf '%s' "$out" | jq '.lines|length')" "both lines kept"
  assert_equals "$(jq -r .request "$in")" "$(printf '%s' "$out" | jq -r .request)" "request round-trips"
  assert_equals 2026-10-07T12:00:00Z "$(printf '%s' "$out" | jq -r .created)" "created stamped"
  assert_equals 600 "$(mode_of "$home/state/orders/o-1-1.json")" "proposal is owner-only"
  NOW=2026-10-07T12:05:00Z run_order "$home" write o-1-1 --file "$in" >/dev/null
  out=$(run_order "$home" show o-1-1)
  assert_equals 2026-10-07T12:00:00Z "$(printf '%s' "$out" | jq -r .created)" "a rewrite keeps created"
  assert_equals 2026-10-07T12:05:00Z "$(printf '%s' "$out" | jq -r .updated)" "a rewrite moves updated"
  pass "fm-order: write then show round-trips a proposal at mode 0600"
}

test_validate_names_the_broken_field() {
  local home in err
  home=$(make_home invalid)
  in="$home/in.json"
  for case in \
    '.request=""|request' \
    '.request="two\nlines"|request' \
    '.request=("x"*1001)|request' \
    '.lines=[range(10)|{project:"a",target:"t",action:"a"}]|lines' \
    '.lines[0].project="../etc"|lines' \
    '.lines[0].project="cadia\n"|lines' \
    '.lines[0].project=("p"*129)|lines' \
    '.lines[0].target=("t"*61)|target' \
    '.lines[1].action=""|action' \
    '.lines[1].action="tab\there"|action' \
    '.note="a\nb\nc"|note' \
    '.lines=[]|.note=""|lines'; do
    good_proposal "$in"
    jq "${case%|*}" "$in" > "$in.tmp" && mv "$in.tmp" "$in"
    err=$(run_order "$home" validate --file "$in" 2>&1) && fail "validate accepted: ${case%|*}"
    assert_contains "$err" "${case##*|}" "error names ${case##*|} for ${case%|*}"
  done
  printf '{"request":' > "$in"
  err=$(run_order "$home" validate --file "$in" 2>&1) && fail "validate accepted truncated JSON"
  assert_contains "$err" "invalid proposal" "truncated JSON is reported as invalid"
  printf '{"request":"a","lines":[],"note":"n"}{"request":"b","lines":[],"note":"n"}' > "$in"
  err=$(run_order "$home" validate --file "$in" 2>&1) && fail "validate accepted two objects"
  assert_contains "$err" "exactly one" "two objects are refused"
  pass "fm-order: validate refuses broken proposals and names the field"
}

test_a_note_alone_is_a_proposal() {
  local home in
  home=$(make_home noteonly)
  in="$home/in.json"
  printf '{"request":"firstmate: how many cards are open?","lines":[],"note":"4 cards are open."}' > "$in"
  run_order "$home" write o-2-1 --file "$in" >/dev/null || fail "a note-only answer was refused"
  assert_equals "4 cards are open." "$(run_order "$home" show o-2-1 | jq -r .note)" "note kept"
  pass "fm-order: a question answered in the note needs no lines"
}

test_rejects_unsafe_ids() {
  local home in id
  home=$(make_home ids)
  in="$home/in.json"
  good_proposal "$in"
  for id in '' '.' '..' 'a/b' 'a b' '../x'; do
    run_order "$home" write "$id" --file "$in" >/dev/null 2>&1 && fail "write accepted id '$id'"
  done
  [ ! -e "$home/x.json" ] || fail "an unsafe id escaped state/orders"
  pass "fm-order: unsafe ids are refused"
}

test_show_remove_and_corrupt_files() {
  local home rc
  home=$(make_home show)
  rc=0; run_order "$home" show o-3-1 >/dev/null 2>&1 || rc=$?
  assert_equals 1 "$rc" "show without a proposal exits 1"
  mkdir -p "$home/state/orders"
  printf '{"version":1,"id":"o-3-1"' > "$home/state/orders/o-3-1.json"
  rc=0; run_order "$home" show o-3-1 >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "a corrupt proposal exits 2"
  run_order "$home" remove o-3-1 || fail "remove failed"
  run_order "$home" remove o-3-1 || fail "a second remove failed"
  [ ! -e "$home/state/orders/o-3-1.json" ] || fail "remove left the file"
  pass "fm-order: show reports missing and corrupt proposals; remove is idempotent"
}

test_list_prints_valid_proposals_only() {
  local home in out
  home=$(make_home list)
  in="$home/in.json"
  good_proposal "$in"
  run_order "$home" write o-4-1 --file "$in" >/dev/null
  printf 'not json' > "$home/state/orders/o-4-2.json"
  printf '{' > "$home/state/orders/.o-4-3.Xk2aB9"
  out=$(run_order "$home" list)
  assert_equals 1 "$(printf '%s\n' "$out" | grep -c .)" "one line listed"
  assert_contains "$out" "$(printf 'o-4-1\t2\t2026-10-07T12:00:00Z\tcadia: fix')" "id, line count, updated and request"
  pass "fm-order: list shows each valid proposal on one line"
}

test_sweep_removes_old_and_invalid_proposals() {
  local home in out
  home=$(make_home sweep)
  in="$home/in.json"
  good_proposal "$in"
  NOW=2026-10-06T11:59:59Z run_order "$home" write o-old --file "$in" >/dev/null
  NOW=2026-10-06T12:00:01Z run_order "$home" write o-fresh --file "$in" >/dev/null
  printf '{"version":1' > "$home/state/orders/o-bad.json"
  out=$(run_order "$home" sweep)
  assert_contains "$out" "removed: o-old" "a day-old proposal is swept"
  assert_contains "$out" "removed: o-bad" "an invalid proposal is swept"
  [ -f "$home/state/orders/o-fresh.json" ] || fail "a fresh proposal was swept"
  [ ! -e "$home/state/orders/o-old.json" ] || fail "the old proposal is still there"
  pass "fm-order: sweep removes proposals older than 24 hours and invalid ones"
}

test_write_and_show_round_trip
test_validate_names_the_broken_field
test_a_note_alone_is_a_proposal
test_rejects_unsafe_ids
test_show_remove_and_corrupt_files
test_list_prints_valid_proposals_only
test_sweep_removes_old_and_invalid_proposals
