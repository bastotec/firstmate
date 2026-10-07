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
  printf 'fm-pr-poll-merge-notified-v1 github github.com o/r 9\n' > "$home/state/merged-one.pr-poll-merge-notified"
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z hold_it "$home" busy-one "Busy call" "waiting"
  printf 'working: still at it\n' > "$home/state/busy-one.status"
  out=$(run_card "$home" stale --days 3)
  assert_contains "$out" $'ghost\torphan' "orphan found"
  assert_contains "$out" $'old-one\tidle' "idle hold found"
  assert_contains "$out" $'merged-one\tpr-merged' "merged PR found"
  assert_not_contains "$out" "new-one" "fresh hold left alone"
  assert_not_contains "$out" "busy-one" "hold with recent activity left alone"
  pass "fm-card: stale finds orphan cards, merged PRs and holds idle past the threshold"
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
  FM_CAPTAIN_HOLD_NOW=2026-10-01T00:00:00Z hold_it "$home" work-a "Work" "approve the worker's plan"
  printf 'project=firstmate\n' > "$home/state/work-a.meta"
  out=$(run_card "$home" stale --days 3)
  assert_not_contains "$out" "later-a" "a captain deferral is not stale"
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
  out=$(PATH="$shim:$PATH" run_card "$home" stale --days 3)
  assert_not_contains "$out" "busy-one" "a busy hold is not idle under GNU stat"
  pass "fm-card: stale reads file times correctly with GNU coreutils"
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
test_stale_clear_never_reads_as_the_captains_words
test_stale_clear_refuses_a_task_not_held_for_the_captain
test_stale_finds_orphans_merged_and_idle_holds
test_clear_then_restore_round_trips
test_clear_removes_an_orphan_card_without_touching_the_backlog
test_clear_refuses_a_task_that_is_not_a_captain_call
test_restore_refuses_when_held_again
test_restore_refuses_after_the_captain_answered
test_unreadable_backlog_never_reads_as_orphan
test_hold_on_a_task_without_repo_still_gets_a_card
test_new_hold_replaces_a_leftover_card
test_stale_clear_retires_a_pending_reconcile_request
test_idle_skips_deferred_and_worker_tracked_holds
test_stale_with_gnu_coreutils
