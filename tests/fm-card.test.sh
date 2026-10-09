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
  case "$(uname -s)" in
    Darwin) mode=$(/usr/bin/stat -f %Lp "$home/state/cards/site-lang-6.json") ;;
    *) mode=$(stat -c %a "$home/state/cards/site-lang-6.json") ;;
  esac
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

test_card_requires_exactly_one_json_object() {
  local home in kind rc before
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home single-object)
  in="$home/in.json"
  mkdir -p "$home/state/cards"
  before=$(tasks_in "$home" list)
  for kind in empty whitespace multiple nonobject; do
    case "$kind" in
      empty) : > "$in" ;;
      whitespace) printf ' \n\t ' > "$in" ;;
      multiple) good_card "$in"; good_card "$home/second.json"; cat "$home/second.json" >> "$in" ;;
      nonobject) printf '[]\n' > "$in" ;;
    esac
    rc=0
    run_card "$home" validate --file "$in" >/dev/null 2>&1 || rc=$?
    assert_equals 2 "$rc" "$kind input is invalid"
    rc=0
    run_card "$home" write "$kind" --file "$in" >/dev/null 2>&1 || rc=$?
    assert_equals 2 "$rc" "$kind input cannot be written"
    assert_absent "$home/state/cards/$kind.json" "invalid write publishes nothing"
    cp "$in" "$home/state/cards/$kind.json"
    rc=0
    run_card "$home" show "$kind" >/dev/null 2>&1 || rc=$?
    assert_equals 2 "$rc" "$kind stored card is invalid"
    rc=0
    run_captain "$home" hold "$kind" --title Invalid --reason r --card-file "$in" >/dev/null 2>&1 || rc=$?
    assert_not_equals 0 "$rc" "$kind card refuses the hold"
    assert_equals "$before" "$(tasks_in "$home" list)" "invalid hold leaves backlog unchanged"
  done
  pass "fm-card: empty, whitespace, multiple documents and nonobjects are refused at every full-card boundary"
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

test_expired_deferral_is_backfilled_and_listed_by_drafts() {
  local home out show
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home expired-backfill)
  tasks_in "$home" add past-a "Deferred call, now due" --repo cadia >/dev/null
  tasks_in "$home" hold past-a --reason "Pick the language rule" --kind captain --until 2000-01-01 >/dev/null
  show=$(tasks_in "$home" show past-a --full)
  assert_contains "$show" "held: no" "the date gate has expired"
  assert_contains "$show" "hold_kind: captain" "the captain call remains annotated"
  run_captain "$home" open past-a || fail "expired deferral must remain an open captain call"
  tasks_in "$home" add closed-b "Already closed" --repo cadia >/dev/null
  tasks_in "$home" hold closed-b --reason "An old call" --kind captain >/dev/null
  tasks_in "$home" 'done' closed-b >/dev/null
  out=$(run_card "$home" drafts) || fail "drafts failed before backfill"
  assert_contains "$out" "past-a" "an expired call without a card is listed"
  assert_not_contains "$out" "closed-b" "a closed captain call is not listed"
  assert_absent "$home/state/cards/past-a.json" "drafts remains read-only"
  out=$(run_card "$home" backfill) || fail "backfill failed"
  assert_contains "$out" "drafted: past-a" "the expired call is backfilled"
  assert_absent "$home/state/cards/closed-b.json" "a closed captain call is not backfilled"
  show=$(run_card "$home" show past-a) || fail "backfilled card is absent"
  assert_equals true "$(printf '%s' "$show" | jq -r .draft)" "backfill writes a draft"
  assert_equals "Pick the language rule" "$(printf '%s' "$show" | jq -r .situation)" "the hold reason is preserved"
  out=$(run_card "$home" drafts) || fail "drafts failed after backfill"
  assert_contains "$out" "past-a"$'\t'"Deferred call, now due" "the expired call's draft is listed with its title"
  assert_not_contains "$out" "closed-b" "a closed captain call stays excluded"
  out=$(run_card "$home" backfill) || fail "repeated backfill failed"
  assert_equals "" "$out" "expired-call backfill is idempotent"
  pass "fm-card: expired captain deferrals remain backfilled and listed while closed calls stay excluded"
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

test_answer_replays_and_repairs_remove_leftover_cards() {
  local home dec id before out flag
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home answer-retry-card)
  dec="$home/dec.txt"
  printf 'Go with option 1.\n' > "$dec"
  for id in close release; do
    flag=''
    [ "$id" != release ] || flag=--release
    run_captain "$home" hold "$id" --title Call --reason r >/dev/null || fail "hold failed"
    chmod 500 "$home/state/cards"
    out=$(run_captain "$home" answer "$id" --decision-file "$dec" ${flag:+"$flag"} 2>&1) || fail "answer failed"
    assert_contains "$out" "could not remove its decision card" "cleanup failure is visible"
    assert_present "$home/state/cards/$id.json" "failed cleanup leaves card for retry"
    before=$(tasks_in "$home" show "$id" --full)
    chmod 700 "$home/state/cards"
    run_captain "$home" answer "$id" --decision-file "$dec" ${flag:+"$flag"} >/dev/null || fail "answer replay failed"
    assert_absent "$home/state/cards/$id.json" "replay removes leftover card"
    assert_equals "$before" "$(tasks_in "$home" show "$id" --full)" "replay does not repeat the backlog transition"
  done
  run_captain "$home" hold repair --title Call --reason r >/dev/null || fail "hold failed"
  tasks_in "$home" "done" repair >/dev/null || fail "external close failed"
  run_captain "$home" answer repair --decision-file "$dec" >/dev/null || fail "answer repair failed"
  assert_absent "$home/state/cards/repair.json" "retroactive repair removes leftover card"
  assert_contains "$(tasks_in "$home" show repair --full)" "Resolution mode: repaired" "repair retains its resolution mode"
  run_captain "$home" hold keyed --title Call --reason r >/dev/null || fail "hold failed"
  chmod 500 "$home/state/cards"
  printf 'keyed\tyes\tYes\n' | run_captain "$home" answers --source test >/dev/null 2>&1 || fail "keyed answer failed"
  assert_present "$home/state/cards/keyed.json" "keyed cleanup failed as intended"
  before=$(tasks_in "$home" show keyed --full)
  chmod 700 "$home/state/cards"
  printf 'keyed\tyes\tYes\n' | run_captain "$home" answers --source test >/dev/null || fail "keyed replay failed"
  assert_absent "$home/state/cards/keyed.json" "keyed replay removes leftover card"
  assert_equals "$before" "$(tasks_in "$home" show keyed --full)" "keyed replay does not repeat the transition"
  pass "fm-captain-hold: answer replays and retroactive repairs retry card cleanup"
}

test_stale_clear_never_reads_as_the_captains_words() {
  local home ev body
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home stale-clear)
  run_captain "$home" hold sc-a --title "Approve PR84" --reason "merge approval" >/dev/null || fail "hold failed"
  ev="$home/ev.txt"
  printf 'PR https://github.com/bastotec/firstmate/pull/84 merged on 2026-10-06.\n' > "$ev"
  run_captain "$home" stale-clear sc-a --evidence-file "$ev" | grep -q '^stale-cleared: sc-a$' \
    || fail "stale-clear did not report"
  body=$(tasks_in "$home" show sc-a --full)
  assert_contains "$body" "Stale-clear evidence:" "evidence label recorded"
  assert_not_contains "$body" "Captain decision:" "never labelled as the captain's words"
  assert_contains "$body" "state: done" "task closed"
  assert_absent "$home/state/cards/sc-a.json" "card removed"
  run_captain "$home" stale-clear sc-a --evidence-file "$ev" | grep -q '^stale-cleared: sc-a$' \
    || fail "an exact retry must be a quiet no-op"
  pass "fm-captain-hold: stale-clear closes on evidence under its own label"
}

test_stale_clear_retry_retains_one_verifiable_resolution() {
  local home ev real before rc=0 body
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home stale-clear-retry)
  hold_it "$home" sc-retry Call waiting
  ev="$home/ev.txt"
  printf 'The premise no longer applies.\n' > "$ev"
  real=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = done ]; then exit 93; fi
exec "$real" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  run_captain "$home" stale-clear sc-retry --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "fixture interrupts after recording evidence but before closing"
  before=$(tasks_in "$home" show sc-retry --full)
  assert_contains "$before" "Stale-clear evidence:" "interrupted clear has durable evidence"
  run_captain "$home" open sc-retry || fail "interrupted clear must leave the hold open"
  rm "$home/fakebin/tasks-axi"
  run_captain "$home" stale-clear sc-retry --evidence-file "$ev" >/dev/null || fail "retry failed"
  body=$(tasks_in "$home" show sc-retry --full)
  assert_equals 1 "$(printf '%s' "$body" | grep -o 'Resolution recorded by fm-captain-hold.' | wc -l | tr -d ' ')" "retry retains exactly one resolution"
  mkdir -p "$home/data/sc-origin"
  printf 'kind=scout\n' > "$home/state/sc-origin.meta"
  run_captain "$home" complete sc-origin sc-retry >/dev/null || fail "complete must recognize stale-clear evidence"
  run_captain "$home" verify sc-origin >/dev/null || fail "verify must recognize stale-clear evidence"
  run_captain "$home" stale-clear sc-retry --evidence-file "$ev" >/dev/null || fail "closed retry failed"
  assert_equals "$body" "$(tasks_in "$home" show sc-retry --full)" "closed retry is idempotent"
  pass "fm-captain-hold: interrupted stale clears retry once and pass completion verification"
}

test_stale_clear_refuses_a_task_not_held_for_the_captain() {
  local home ev rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home stale-refuse)
  tasks_in "$home" add plain "Plain" --repo firstmate >/dev/null
  ev="$home/ev.txt"
  printf 'whatever\n' > "$ev"
  run_captain "$home" stale-clear plain --evidence-file "$ev" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "refused"
  assert_contains "$(tasks_in "$home" show plain --full)" "state: queued" "task untouched"
  pass "fm-captain-hold: stale-clear refuses a task that is not a captain call"
}

hold_it() {  # <home> <id> <title> <reason>
  run_captain "$1" hold "$2" --title "$3" --repo firstmate --reason "$4" >/dev/null || fail "hold $2 failed"
}

test_stale_finds_orphans_merged_and_idle_holds() {
  local home out
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home stale)
  run_card "$home" draft ghost --title Ghost --project firstmate --situation "No task behind me" >/dev/null
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z hold_it "$home" old-one "Old call" "waiting"
  FM_CAPTAIN_HOLD_NOW=2026-10-07T11:00:00Z hold_it "$home" new-one "New call" "waiting"
  FM_CAPTAIN_HOLD_NOW=2026-10-07T11:00:00Z hold_it "$home" merged-one "Merge call" "waiting"
  printf 'pr=https://github.com/o/r/pull/9\n' > "$home/state/merged-one.meta"
  mark_merge "$home" merged-one 9
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z hold_it "$home" busy-one "Busy call" "waiting"
  printf 'working: still at it\n' > "$home/state/busy-one.status"
  out=$(run_card "$home" stale)
  assert_contains "$out" $'ghost\torphan' "orphan found"
  assert_contains "$out" $'old-one\tidle' "idle hold found"
  assert_contains "$out" $'merged-one\tpr-merged' "merged PR found"
  assert_not_contains "$out" "new-one" "fresh hold left alone"
  assert_not_contains "$out" "busy-one" "hold with recent activity left alone"
  pass "fm-card: stale finds orphan cards, merged PRs and holds idle past the threshold"
}

mark_merge() {
  bash -c '. "$1"; fm_pr_poll_merge_mark_notified "$2" "$3" github github.com o/r "$4"' \
    _ "$ROOT/bin/fm-pr-lib.sh" "$1/state" "$2" "$3" || fail "could not record merge notification"
}

test_stale_matches_the_current_pr_identity() {
  local home out
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home stale-pr-identity)
  hold_it "$home" switched Call waiting
  mark_merge "$home" switched 9
  printf 'pr=https://github.com/o/r/pull/10\n' > "$home/state/switched.meta"
  out=$(run_card "$home" stale) || fail "stale failed"
  assert_not_contains "$out" "switched" "PR A's merge does not clear an approval for PR B"
  mark_merge "$home" switched 10
  out=$(run_card "$home" stale) || fail "stale failed"
  assert_contains "$out" $'switched\tpr-merged\thttps://github.com/o/r/pull/10 merged' "matching merge notification is a candidate"
  printf 'pr=https://github.com/o/other/pull/10\n' > "$home/state/switched.meta"
  out=$(run_card "$home" stale) || fail "stale failed"
  assert_not_contains "$out" "switched" "the repository is part of the merge identity"
  printf 'pr=https://gitlab.example/o/r/-/merge_requests/10\n' > "$home/state/switched.meta"
  out=$(run_card "$home" stale) || fail "stale failed"
  assert_not_contains "$out" "switched" "the forge and host are part of the merge identity"
  pass "fm-card: stale reports merged only for the current PR identity"
}

test_stale_uses_the_fixed_three_day_cutoff() {
  local home out rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home stale-cutoff)
  FM_CAPTAIN_HOLD_NOW=2026-10-04T12:00:00Z hold_it "$home" boundary Call waiting
  FM_CAPTAIN_HOLD_NOW=2026-10-04T12:00:01Z hold_it "$home" fresh Call waiting
  out=$(run_card "$home" stale) || fail "stale failed"
  assert_contains "$out" $'boundary\tidle' "a hold idle exactly three days is a candidate"
  assert_not_contains "$out" "fresh" "a hold younger than three days is not idle"
  run_card "$home" stale --days 1 >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "the threshold cannot be overridden"
  pass "fm-card: stale uses a fixed three-day cutoff"
}

test_clear_then_restore_round_trips() {
  local home line card
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home clear)
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z hold_it "$home" old-one "Old call" 'waiting on "quotes" and é'
  card="$home/card.json"
  good_card "$card"
  run_captain "$home" hold old-one --reason 'waiting on "quotes" and é' --card-file "$card" >/dev/null || fail "card hold failed"
  run_card "$home" clear old-one --why "idle 6 days, no activity" >/dev/null || fail "clear failed"
  assert_absent "$home/state/cards/old-one.json" "card gone"
  line=$(tail -n 1 "$home/state/cards-cleared.log")
  assert_equals cleared "$(printf '%s' "$line" | jq -r .event)" "logged as cleared"
  assert_equals 'waiting on "quotes" and é' "$(printf '%s' "$line" | jq -r .reason)" "reason preserved exactly"
  assert_equals "$(jq -r .situation "$card")" "$(printf '%s' "$line" | jq -r .card.situation)" "card preserved exactly"
  run_card "$home" restore old-one >/dev/null || fail "restore failed"
  run_captain "$home" open old-one || fail "task is not held again"
  assert_equals false "$(jq -r .draft "$home/state/cards/old-one.json")" "full card back"
  assert_equals restored "$(tail -n 1 "$home/state/cards-cleared.log" | jq -r .event)" "restore logged"
  pass "fm-card: clear then restore brings back the hold, reason and card"
}

test_clear_removes_an_orphan_card_without_touching_the_backlog() {
  local home
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home clear-orphan)
  run_card "$home" draft ghost --title Ghost --project firstmate --situation "No task behind me" >/dev/null
  run_card "$home" clear ghost --why "no open captain hold" >/dev/null || fail "orphan clear failed"
  assert_absent "$home/state/cards/ghost.json" "orphan card removed"
  assert_equals orphan "$(tail -n 1 "$home/state/cards-cleared.log" | jq -r .kind)" "logged as orphan"
  pass "fm-card: clear removes an orphan card and logs it"
}

test_clear_refuses_a_task_that_is_not_a_captain_call() {
  local home rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home clear-refuse)
  tasks_in "$home" add plain "Plain" --repo firstmate >/dev/null
  run_card "$home" clear plain --why "x" >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "refused"
  assert_absent "$home/state/cards-cleared.log" "nothing logged"
  pass "fm-card: clear refuses a task that is neither orphaned nor captain-held"
}

test_restore_refuses_when_held_again() {
  local home rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home restore-refuse)
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z hold_it "$home" t9 "Call" "waiting"
  run_card "$home" clear t9 --why idle >/dev/null || fail "clear failed"
  tasks_in "$home" reopen t9 >/dev/null
  hold_it "$home" t9 "Call" "a new question"
  run_card "$home" restore t9 >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "restore on a call held again some other way is refused"
  assert_equals "a new question" "$(jq -r .situation "$home/state/cards/t9.json")" "the newer card survives"
  pass "fm-card: restore refuses when the call is already held again"
}

test_restore_refuses_after_the_captain_answered() {
  local home rc=0 dec
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home restore-answered)
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z hold_it "$home" t8 "Call" "waiting"
  run_card "$home" clear t8 --why idle >/dev/null || fail "clear failed"
  tasks_in "$home" reopen t8 >/dev/null
  hold_it "$home" t8 "Call" "a new question"
  dec="$home/dec.txt"
  printf 'Do the new thing.\n' > "$dec"
  run_captain "$home" answer t8 --decision-file "$dec" >/dev/null || fail "answer failed"
  run_card "$home" restore t8 >/dev/null 2>&1 || rc=$?
  assert_equals 2 "$rc" "restore refuses to undo a newer captain answer"
  run_captain "$home" open t8 && fail "the answered call must stay closed"
  pass "fm-card: restore never reopens a call the captain answered after the clear"
}

test_drafts_lists_captain_calls_without_a_full_card() {
  local home in out rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home drafts)
  tasks_in "$home" add draft-a "Needs a real card" --repo cadia >/dev/null
  tasks_in "$home" hold draft-a --reason "why a" --kind captain >/dev/null
  tasks_in "$home" add full-b "Already carded" --repo cadia >/dev/null
  tasks_in "$home" hold full-b --reason "why b" --kind captain >/dev/null
  tasks_in "$home" add bare-c "No card at all" --repo cadia >/dev/null
  tasks_in "$home" hold bare-c --reason "why c" --kind captain >/dev/null
  tasks_in "$home" add other-d "Not the captain's" --repo cadia >/dev/null
  tasks_in "$home" hold other-d --reason "waiting on CI" >/dev/null
  run_card "$home" draft draft-a --title "Needs a real card" --project cadia --situation "why a" >/dev/null
  in="$home/in.json"
  good_card "$in"
  run_card "$home" write full-b --file "$in" >/dev/null
  out=$(run_card "$home" drafts) || fail "drafts failed"
  assert_contains "$out" "draft-a"$'\t'"Needs a real card" "a draft card is listed with its title"
  assert_contains "$out" "bare-c" "a captain call with no card is listed"
  assert_not_contains "$out" "full-b" "a full card is not listed"
  assert_not_contains "$out" "other-d" "a non-captain hold is not listed"
  assert_absent "$home/state/cards/bare-c.json" "drafts writes nothing"
  chmod 000 "$home/data/backlog.md"
  out=$(run_card "$home" drafts 2>&1) || rc=$?
  chmod 600 "$home/data/backlog.md"
  assert_equals 2 "$rc" "drafts refuses when the backlog cannot be listed"
  rc=0
  chmod 000 "$home/data/backlog.md"
  run_card "$home" backfill >/dev/null 2>&1 || rc=$?
  chmod 600 "$home/data/backlog.md"
  assert_equals 2 "$rc" "backfill refuses when the backlog cannot be listed"
  pass "fm-card: drafts lists every captain call still lacking a full card, read-only, and refuses an unreadable backlog"
}

test_unreadable_backlog_never_reads_as_orphan() {
  local home rc=0 out
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home unreadable)
  hold_it "$home" live "Live call" "waiting"
  chmod 000 "$home/data/backlog.md"
  out=$(run_card "$home" stale 2>/dev/null) || rc=$?
  chmod 600 "$home/data/backlog.md"
  assert_not_equals 0 "$rc" "stale fails when holds cannot be read"
  assert_not_contains "$out" "orphan" "an unreadable hold is never called an orphan"
  rc=0
  chmod 000 "$home/data/backlog.md"
  run_card "$home" clear live --why x >/dev/null 2>&1 || rc=$?
  chmod 600 "$home/data/backlog.md"
  assert_equals 2 "$rc" "clear refuses when the hold cannot be read"
  assert_present "$home/state/cards/live.json" "card survives"
  pass "fm-card: a backlog that cannot be read never turns live holds into orphans"
}

test_hold_on_a_task_without_repo_still_gets_a_card() {
  local home rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home norepo)
  tasks_in "$home" add norepo-a "No repo call" >/dev/null
  run_captain "$home" hold norepo-a --reason "waiting" >/dev/null 2>&1 || rc=$?
  assert_equals 0 "$rc" "hold succeeds"
  assert_equals firstmate "$(jq -r .project "$home/state/cards/norepo-a.json")" "draft defaults the project"
  pass "fm-captain-hold: a task with no repo still gets a draft card"
}

test_new_hold_replaces_a_leftover_card() {
  local home card
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home leftover)
  card="$home/card.json"
  good_card "$card"
  run_captain "$home" hold lo-a --title "Old" --repo cadia --reason "old question" --card-file "$card" >/dev/null || fail "hold failed"
  tasks_in "$home" unhold lo-a >/dev/null
  run_captain "$home" hold lo-a --reason "a totally new question" >/dev/null || fail "re-hold failed"
  assert_equals true "$(jq -r .draft "$home/state/cards/lo-a.json")" "new question gets a draft"
  assert_equals "a totally new question" "$(jq -r .situation "$home/state/cards/lo-a.json")" "draft carries the new question"
  pass "fm-captain-hold: a new hold never inherits a leftover card"
}

test_stale_clear_retires_a_pending_reconcile_request() {
  local home ev
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home stale-request)
  hold_it "$home" rq-a "Call" "waiting"
  mkdir -p "$home/state/reconcile-requests"
  printf 'schema=fm-reconcile-request.v1\ntask=rq-a\nrequested=2026-10-06T00:00:00Z\nsource=test\n' > "$home/state/reconcile-requests/rq-a.request"
  ev="$home/ev.txt"
  printf 'stale\n' > "$ev"
  run_captain "$home" stale-clear rq-a --evidence-file "$ev" >/dev/null || fail "stale-clear failed"
  assert_not_contains "$(run_captain "$home" reconcile list)" "rq-a" "the reconcile request is retired"
  pass "fm-captain-hold: stale-clear retires a pending reconcile request"
}

test_idle_skips_deferred_and_worker_tracked_holds() {
  local home out
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home idle-skip)
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z run_captain "$home" hold later-a --title "Later" --repo firstmate \
    --reason "revisit in November" --until 2026-11-01 >/dev/null || fail "dated hold failed"
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z run_captain "$home" hold past-a --title "Past" --repo firstmate \
    --reason "revisit yesterday" --until 2026-10-06 >/dev/null || fail "past dated hold failed"
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z run_captain "$home" hold today-a --title "Today" --repo firstmate \
    --reason "revisit today" --until 2026-10-07 >/dev/null || fail "today dated hold failed"
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z hold_it "$home" work-a "Work" "approve the worker's plan"
  printf 'project=firstmate\n' > "$home/state/work-a.meta"
  out=$(run_card "$home" stale)
  assert_not_contains "$out" "later-a" "a future captain deferral is not stale"
  assert_not_contains "$out" "past-a" "an expired captain deferral is not idle"
  assert_not_contains "$out" "today-a" "a captain deferral due today is not idle"
  assert_not_contains "$out" "work-a" "a hold gating a tracked worker is not idle-cleared"
  pass "fm-card: idle skips captain deferrals and holds that gate a tracked worker"
}

test_stale_with_gnu_coreutils() {
  local home out shim
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  if [ "$(uname -s)" = Darwin ]; then
    if ! command -v gstat >/dev/null 2>&1 || ! command -v gdate >/dev/null 2>&1; then
      echo "skip: GNU stat/date not installed"
      return 0
    fi
  fi
  home=$(make_home gnu)
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z hold_it "$home" busy-one "Busy call" "waiting"
  printf 'working: still at it\n' > "$home/state/busy-one.status"
  shim="$home/gnu"
  mkdir -p "$shim"
  if [ "$(uname -s)" = Darwin ]; then
    ln -s "$(command -v gstat)" "$shim/stat"
    ln -s "$(command -v gdate)" "$shim/date"
  fi
  out=$(PATH="$shim:$PATH" run_card "$home" stale)
  assert_not_contains "$out" "busy-one" "a busy hold is not idle under GNU stat"
  pass "fm-card: stale reads file times correctly with GNU coreutils"
}

full_card_for() {  # <path>
  printf '%s' '{"project":"cadia","title":"Banco plan","situation":"Trial used up.","options":[{"key":"1","label":"Show plans now","instruction":"Show the plans."},{"key":"2","label":"Pay when needed","instruction":"Wait until needed."}],"recommended":"2"}' > "$1"
}

test_deferred_answer_parks_the_call_and_never_cards_it() {
  local home dec show out rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home defer-park)
  full_card_for "$home/card.json"
  run_captain "$home" hold banco --title "Banco plan" --repo cadia --reason "Pay now or later?" \
    --card-file "$home/card.json" >/dev/null || fail "hold failed"
  dec="$home/dec.txt"
  printf "I don't need banco right now so I'll pay when I need it.\n" > "$dec"
  out=$(run_captain "$home" answer banco --decision-file "$dec" --defer "Ask before paying once a routed task needs Banco") \
    || fail "deferred answer failed"
  assert_contains "$out" "deferred: banco" "the answer reports the deferral"
  assert_absent "$home/state/cards/banco.json" "the deferral removed the card"
  show=$(tasks_in "$home" show banco --full)
  assert_contains "$show" "hold_kind: parked" "the call became this home's parked wait"
  assert_contains "$show" "hold_reason: Ask before paying once a routed task needs Banco" "the condition is the hold reason"
  assert_contains "$show" "state: queued" "the work item stays open"
  assert_contains "$show" "Resolution mode: deferred" "the record names the deferral"
  assert_contains "$show" "pay when I need it" "the captain's words are recorded"
  assert_not_contains "$show" "Captain hold set:" "the hold-set stamp is gone with the captain hold"
  run_captain "$home" open banco || rc=$?
  assert_equals 1 "$rc" "a deferred call is not an open captain call"
  assert_equals "" "$(run_card "$home" backfill)" "backfill does not card a deferred call"
  assert_absent "$home/state/cards/banco.json" "backfill wrote no card"
  assert_equals "" "$(run_card "$home" drafts)" "drafts does not list a deferred call"
  assert_equals "" "$(run_card "$home" calls)" "calls does not list a deferred call"
  assert_equals "" "$(run_card "$home" stale)" "stale has nothing to say about a deferred call"
  pass "fm-captain-hold: a deferred answer parks the call, removes its card, and nothing cards it again"
}

test_replayed_answers_never_reopen_a_deferred_call() {
  local home dec other before out rc
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home defer-replay)
  dec="$home/dec.txt"
  other="$home/other.txt"
  printf 'wait until needed\n' > "$dec"
  printf 'keep waiting, restated\n' > "$other"
  run_captain "$home" hold oauth --title "Cumbuca login" --reason "Log in now or later?" >/dev/null || fail "hold failed"
  run_captain "$home" answer oauth --decision-file "$dec" --defer "Raise the login when a routed task needs Cumbuca" >/dev/null \
    || fail "deferral failed"
  before=$(tasks_in "$home" show oauth --full)

  rc=0; out=$(run_captain "$home" hold oauth --reason "Standing answer restated: wait until needed" 2>&1) || rc=$?
  assert_not_equals 0 "$rc" "a plain re-hold of a deferred call is refused"
  assert_contains "$out" "--reopen-deferred" "the refusal names the reopen path"
  rc=0; run_captain "$home" answer oauth --decision-file "$other" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "a different answer does not reopen or close a deferred call"
  rc=0; run_captain "$home" answer oauth --decision-file "$other" --defer "Something else" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "a different deferral is refused"
  rc=0; run_captain "$home" answer oauth --decision-file "$dec" --defer "Raise the login when a routed task needs Banco" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "the same words with a changed condition are refused"
  assert_equals "$before" "$(tasks_in "$home" show oauth --full)" "a changed-condition retry leaves the parked reason unchanged"
  rc=0; run_captain "$home" answer oauth --decision-file "$dec" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "the same words without --defer are refused"
  rc=0; run_captain "$home" answer oauth --decision-file "$dec" --release >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "a release cannot undo a settled deferral"
  rc=0; printf 'oauth\tyes\tLog in now\n' | run_captain "$home" answers --source test >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "a keyed answer on a deferred call is skipped"
  assert_equals "$before" "$(tasks_in "$home" show oauth --full)" "no replay changed the task"
  assert_absent "$home/state/cards/oauth.json" "no replay re-carded the call"

  out=$(run_captain "$home" answer oauth --decision-file "$dec" --defer "Raise the login when a routed task needs Cumbuca") \
    || fail "an exact deferral retry failed"
  assert_contains "$out" "deferred: oauth" "an exact retry is an idempotent no-op"
  assert_equals "$before" "$(tasks_in "$home" show oauth --full)" "an exact retry writes nothing new"

  run_captain "$home" hold oauth --reason "A task needs Cumbuca now - log in?" --reopen-deferred >/dev/null \
    || fail "reopening a deferred call once its condition fired failed"
  run_captain "$home" open oauth || fail "a reopened call is an open captain call again"
  assert_equals true "$(jq -r .draft "$home/state/cards/oauth.json")" "the fresh call gets a fresh draft card"
  assert_equals "A task needs Cumbuca now - log in?" "$(jq -r .situation "$home/state/cards/oauth.json")" "the fresh card carries the new question"
  assert_contains "$(run_card "$home" calls)" "oauth" "the fresh call is listed"

  run_captain "$home" hold plain --title "Plain call" --reason r >/dev/null || fail "hold failed"
  rc=0; run_captain "$home" hold plain --reason r --reopen-deferred >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "--reopen-deferred is refused on a call that was never deferred"
  pass "fm-captain-hold: replayed answers never reopen or re-card a deferred call; only --reopen-deferred does"
}

test_reopened_deferral_records_repeated_words_as_a_fresh_answer() {
  local home parent dec show body before channel open rc=0
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  parent=$(make_home defer-parent)
  home=$(make_home defer-reopened)
  printf 'defer-mate\n' > "$home/.fm-secondmate-home"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$home/.fm-secondmate-parent"
  channel="$parent/state/defer-mate.status"
  dec="$home/dec.txt"
  printf 'keep waiting\n' > "$dec"
  FM_CAPTAIN_HOLD_NOW=2026-10-01T12:00:00Z run_captain "$home" hold retry --title Call --reason "Pay now?" >/dev/null \
    || fail "hold failed"
  run_captain "$home" answer retry --decision-file "$dec" --defer "When Banco is needed" >/dev/null \
    || fail "first deferral failed"
  FM_CAPTAIN_HOLD_NOW=2026-10-07T12:00:00Z run_captain "$home" hold retry --reason "Banco is needed - pay?" --reopen-deferred >/dev/null \
    || fail "reopening failed"
  show=$(tasks_in "$home" show retry --full)
  body=$(printf '%s\n' "$show" | sed -n 's/^  body: //p' | jq -r .)
  assert_equals $'Captain hold set: 2026-10-07T12:00:00Z\nDeferral reopened: 2026-10-07T12:00:00Z' \
    "$(printf '%s\n' "$body" | head -2)" "reopening preserves the leading stamp and marks the fresh lifecycle"
  assert_grep 'needs-decision [key=captain-hold-retry-2]' "$channel" "the parent receives a fresh call"
  rc=0; run_captain "$home" hold retry --reason "Banco is needed - pay?" --reopen-deferred >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "an already reopened call cannot reopen the old deferral twice"
  run_captain "$home" hold retry --reason "Banco is needed - pay?" >/dev/null || fail "repeating the fresh active hold failed"
  run_captain "$home" answer retry --decision-file "$dec" --defer "When Banco is needed again" >/dev/null \
    || fail "the repeated words must answer the fresh call"
  show=$(tasks_in "$home" show retry --full)
  assert_equals 2 "$(printf '%s' "$show" | grep -o 'Resolution mode: deferred' | wc -l | tr -d ' ')" "each fresh call gets its own resolution"
  assert_contains "$show" "hold_kind: parked" "the fresh answer parks the task"
  assert_contains "$show" "hold_reason: When Banco is needed again" "the fresh answer sets its own condition"
  assert_not_contains "$show" "Captain hold set:" "the fresh answer removes its hold stamp"
  assert_absent "$home/state/cards/retry.json" "the fresh answer removes its card"
  assert_grep 'resolved [key=captain-hold-retry-2]' "$channel" "the answer resolves the current parent occurrence"
  open=$(bash -c '. "$1"; status_open_decisions "$2"' _ "$ROOT/bin/fm-classify-lib.sh" "$channel")
  assert_equals "" "$open" "the parent has no unanswered decision after the fresh deferral"
  before=$show
  run_captain "$home" answer retry --decision-file "$dec" --defer "When Banco is needed again" >/dev/null \
    || fail "retry after the fresh deferral failed"
  assert_equals "$before" "$(tasks_in "$home" show retry --full)" "the fresh resolution supersedes the reopening marker for retries"
  pass "fm-captain-hold: repeated words after reopening settle the fresh call and its parent occurrence"
}

test_interrupted_deferral_remains_settled_until_finalized() {
  local home dec other real rc=0 before show out
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home defer-interrupted)
  dec="$home/dec.txt"
  other="$home/other.txt"
  printf 'keep waiting\n' > "$dec"
  printf 'pay now\n' > "$other"
  run_captain "$home" hold waiting --title Call --reason "Pay now?" >/dev/null || fail "hold failed"
  real=$(command -v tasks-axi)
  cat > "$home/fakebin/tasks-axi" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = hold ]; then
  case " \$* " in *" --kind parked "*) exit 93 ;; esac
fi
exec "$real" "\$@"
EOF
  chmod +x "$home/fakebin/tasks-axi"
  run_captain "$home" answer waiting --decision-file "$dec" --defer "When Banco is needed" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "the parked transition is interrupted after recording the answer"
  before=$(tasks_in "$home" show waiting --full)
  assert_contains "$before" "Resolution mode: deferred" "the interrupted deferral durably records the answer"
  assert_contains "$before" "hold_kind: captain" "the interrupted transition leaves the old hold kind"
  assert_contains "$before" "Captain hold set:" "the interrupted transition retains the stamp for finalization"
  assert_present "$home/state/cards/waiting.json" "the interrupted transition leaves the card for finalization"
  rc=0; run_captain "$home" hold waiting --reason "Restating keep waiting" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "an interrupted deferral refuses a plain re-hold"
  rc=0; run_captain "$home" answer waiting --decision-file "$other" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "an interrupted deferral refuses different words"
  rc=0; run_captain "$home" answer waiting --decision-file "$other" --defer "Something else" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "an interrupted deferral refuses a different deferred answer"
  rc=0; run_captain "$home" answer waiting --decision-file "$dec" >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "an interrupted deferral refuses the same words without --defer"
  rc=0; run_captain "$home" answer waiting --decision-file "$dec" --release >/dev/null 2>&1 || rc=$?
  assert_not_equals 0 "$rc" "an interrupted deferral refuses release"
  rc=0; out=$(printf 'waiting\tyes\tPay now\n' | run_captain "$home" answers --source test 2>&1) || rc=$?
  assert_not_equals 0 "$rc" "an interrupted deferral skips a keyed answer"
  assert_contains "$out" "skipped: waiting" "keyed intake reports the refused answer"
  assert_equals "$before" "$(tasks_in "$home" show waiting --full)" "refused inputs leave the settled record and hold unchanged"
  rm "$home/fakebin/tasks-axi"
  run_captain "$home" answer waiting --decision-file "$dec" --defer "When Banco is needed" >/dev/null \
    || fail "an exact retry must finish the interrupted deferral"
  show=$(tasks_in "$home" show waiting --full)
  assert_contains "$show" "hold_kind: parked" "an exact retry finishes parking"
  assert_contains "$show" "hold_reason: When Banco is needed" "an exact retry installs the condition"
  assert_not_contains "$show" "Captain hold set:" "an exact retry removes the stamp"
  assert_absent "$home/state/cards/waiting.json" "an exact retry removes the card"
  assert_equals 1 "$(printf '%s' "$show" | grep -o 'Resolution mode: deferred' | wc -l | tr -d ' ')" "finalization keeps one resolution"
  run_captain "$home" answer waiting --decision-file "$dec" --defer "When Banco is needed" >/dev/null || fail "finalized replay failed"
  assert_equals "$show" "$(tasks_in "$home" show waiting --full)" "the finalized deferral replays without changes"
  pass "fm-captain-hold: interrupted deferrals reject new inputs and finalize only on an exact retry"
}

test_rehold_with_a_new_reason_refreshes_the_card() {
  local home
  command -v tasks-axi >/dev/null 2>&1 || { echo "skip: tasks-axi not found"; return 0; }
  home=$(make_home rehold-refresh)
  full_card_for "$home/card.json"
  run_captain "$home" hold banco --title "Banco plan" --repo cadia --reason "Pay now or later?" \
    --card-file "$home/card.json" >/dev/null || fail "hold failed"
  run_captain "$home" hold banco --reason "Pay now or later?" >/dev/null || fail "same-reason re-hold failed"
  assert_equals false "$(jq -r .draft "$home/state/cards/banco.json")" "a same-reason re-hold keeps the full card"
  run_captain "$home" hold banco --reason "Captain said pay when needed - confirm the plan tier" >/dev/null \
    || fail "new-reason re-hold failed"
  assert_equals true "$(jq -r .draft "$home/state/cards/banco.json")" "a new reason replaces the old options with a draft"
  assert_equals "Captain said pay when needed - confirm the plan tier" "$(jq -r .situation "$home/state/cards/banco.json")" \
    "the refreshed card carries the new reason"
  assert_contains "$(run_card "$home" drafts)" "banco" "the refreshed draft is listed for a full card"
  pass "fm-captain-hold: re-holding with a new reason refreshes the card instead of keeping old options"
}

test_write_and_show_round_trip
test_validate_names_the_broken_field
test_card_requires_exactly_one_json_object
test_show_reports_a_corrupt_card_as_invalid
test_rejects_unsafe_task_ids
test_remove_is_idempotent
test_draft_never_overwrites_a_full_card
test_backfill_drafts_every_uncarded_captain_hold
test_expired_deferral_is_backfilled_and_listed_by_drafts
test_hold_without_card_writes_a_draft
test_hold_with_card_file_writes_the_full_card
test_hold_refuses_an_invalid_card_before_holding
test_answer_removes_the_card
test_answer_replays_and_repairs_remove_leftover_cards
test_stale_clear_never_reads_as_the_captains_words
test_stale_clear_retry_retains_one_verifiable_resolution
test_stale_clear_refuses_a_task_not_held_for_the_captain
test_stale_finds_orphans_merged_and_idle_holds
test_stale_matches_the_current_pr_identity
test_stale_uses_the_fixed_three_day_cutoff
test_clear_then_restore_round_trips
test_clear_removes_an_orphan_card_without_touching_the_backlog
test_clear_refuses_a_task_that_is_not_a_captain_call
test_restore_refuses_when_held_again
test_restore_refuses_after_the_captain_answered
test_unreadable_backlog_never_reads_as_orphan
test_drafts_lists_captain_calls_without_a_full_card
test_hold_on_a_task_without_repo_still_gets_a_card
test_new_hold_replaces_a_leftover_card
test_stale_clear_retires_a_pending_reconcile_request
test_idle_skips_deferred_and_worker_tracked_holds
test_stale_with_gnu_coreutils
test_deferred_answer_parks_the_call_and_never_cards_it
test_replayed_answers_never_reopen_a_deferred_call
test_reopened_deferral_records_repeated_words_as_a_fresh_answer
test_interrupted_deferral_remains_settled_until_finalized
test_rehold_with_a_new_reason_refreshes_the_card
