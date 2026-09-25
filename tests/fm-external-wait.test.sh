#!/usr/bin/env bash
# tests/fm-external-wait.test.sh - the supervisor-declared external-wait record
# (bin/fm-external-wait.sh) and the watcher absorb it buys (bin/fm-watch.sh).
# Covers the declaration lifecycle the task brief names: declare (attributable,
# bounded, never touching the worker's status log), absorb (the wedge timer and
# its escalation counter clear like a worker-authored pause, no wedge alarm),
# expiry (ordinary escalation restored), new-event pass-through (a status line
# still wakes immediately), and audit distinguishability from a worker-authored
# `paused:`.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-classify-lib.sh"

WATCH="$ROOT/bin/fm-watch.sh"
EXT="$ROOT/bin/fm-external-wait.sh"

TMP_ROOT=$(fm_test_tmproot fm-external-wait-tests)

# --- small watcher-drive helpers (the shape fm-watch-triage.test.sh uses) ----

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

file_mtime() {
  if [ "$(uname)" = Darwin ]; then /usr/bin/stat -f %m "$1" 2>/dev/null; else stat -c %Y "$1" 2>/dev/null; fi
}

size_of() { LC_ALL=C wc -c < "$1" | tr -d '[:space:]'; }

seen_sig() {
  local reported size ident
  case "$1" in
    *.status)
      reported=$(status_observed_signature "$1")
      size=$(size_of "$1")
      ident=$(_fm_open_decisions_file_ident "$1")
      printf 'v2\t%s\t%s@%s' "$reported" "$size" "$ident"
      ;;
    *)
      if [ "$(uname)" = Darwin ]; then stat -f '%z:%Fm' "$1" 2>/dev/null; else stat -c '%s:%Y' "$1" 2>/dev/null; fi
      ;;
  esac
}

wait_poll_cycle() {  # <state> <pid> [limit-ticks]
  local state=$1 pid=$2 limit=${3:-300} beat first now i=0
  beat="$state/.last-watcher-beat"
  rm -f "$beat"
  first=""
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat")
    [ -n "$first" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat")
    if [ -n "$now" ] && [ "$now" != "$first" ]; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

# future_iso [offset-seconds]: a UTC ISO 8601 time in the future on either date.
future_iso() {
  local off=${1:-7200} target
  target=$(( $(date +%s) + off ))
  if date -u -r "$target" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null; then return 0; fi
  date -u -d "@$target" +%Y-%m-%dT%H:%M:%SZ
}

# ext <home> <args...>: run the record owner against a case's state dir.
ext() {
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" "$EXT" "$@"
}

# backdate_declaration <record> <seconds>: age the declaration without waiting,
# keeping its expected clear time as written (so it stays live) unless the caller
# asks for expiry by also passing the until offset.
backdate_declaration() {
  local record=$1 seconds=$2 until_off=${3:-7200} declared_epoch until_epoch now
  now=$(date +%s)
  declared_epoch=$(( now - seconds ))
  until_epoch=$(( now + until_off ))
  sed -i.bak \
    -e "s/^declared_epoch: .*/declared_epoch: $declared_epoch/" \
    -e "s/^until_epoch: .*/until_epoch: $until_epoch/" \
    -e "s/^until: .*/until: $(future_iso "$until_off")/" \
    "$record"
  rm -f "$record.bak"
}

# --- record lifecycle -------------------------------------------------------

test_declare_records_attribution_without_touching_the_status_log() {
  local dir state out record
  dir="$TMP_ROOT/declare-attribution"; state="$dir/state"; mkdir -p "$state"
  printf 'working: parked on the provider\n' > "$state/task1.status"
  out=$(ext "$dir" declare task1 \
    --reason "provider outage, generation stopped" \
    --until "$(future_iso 7200)" --by "firstmate (supervisor)") || fail "declare failed: $out"
  record="$state/task1.external-wait"
  [ -f "$record" ] || fail "declare did not write the record at $record"
  assert_equals "firstmate (supervisor)" "$(sed -n 's/^declared_by: //p' "$record")" \
    "the record does not attribute the declaration"
  assert_equals "provider outage, generation stopped" "$(sed -n 's/^reason: //p' "$record")" \
    "the record does not carry the reason"
  [ -n "$(sed -n 's/^until_epoch: //p' "$record")" ] || fail "the record carries no expected clear time"
  ext "$dir" active task1 || fail "a live declaration did not read as active"
  assert_equals "active" "$(ext "$dir" show task1 | sed -n 's/^verdict: //p')" \
    "show did not report a live declaration as active"
  assert_equals "working: parked on the provider" "$(cat "$state/task1.status")" \
    "the supervisor record fabricated or altered the worker's status log"
  assert_no_grep "^paused:" "$state/task1.status" "the declaration wrote a fake worker pause line"
  pass "declare records who and why, with a bound, and never touches the worker's status log"
}

test_declare_refuses_unbounded_or_malformed_input() {
  local dir state rc
  dir="$TMP_ROOT/declare-refusals"; state="$dir/state"; mkdir -p "$state"
  expect_refusal() {  # <label> <args...>
    local label=$1 code
    shift
    set +e
    ext "$dir" "$@" >/dev/null 2>&1
    code=$?
    set -e
    [ "$code" -eq 2 ] || fail "expected a usage refusal (exit 2) for $label, got $code"
  }
  expect_refusal "a missing reason" declare t --until "$(future_iso 60)"
  expect_refusal "an empty reason" declare t --reason "" --until "$(future_iso 60)"
  expect_refusal "a multi-line reason" declare t --reason "$(printf 'two\nlines')" --until "$(future_iso 60)"
  expect_refusal "a malformed expected clear time" declare t --reason x --until not-a-time
  expect_refusal "an expected clear time in the past" declare t --reason x --until "$(future_iso -60)"
  expect_refusal "an invalid task id" declare 'bad id' --reason x --until "$(future_iso 60)"
  [ ! -e "$state/t.external-wait" ] || fail "a refused declare still wrote a record"
  pass "declare refuses a missing or malformed field and any expected clear time that is not in the future"
}

test_clear_archives_the_record_and_replacement_archives_the_prior_one() {
  local dir state record archive
  dir="$TMP_ROOT/clear-archive"; state="$dir/state"; mkdir -p "$state"
  ext "$dir" declare t1 --reason "rate-limit reset window" --until "$(future_iso 600)" --by "firstmate" >/dev/null \
    || fail "declare failed"
  record="$state/t1.external-wait"
  ext "$dir" clear t1 --by "firstmate" >/dev/null || fail "clear failed"
  [ ! -e "$record" ] || fail "clear left the live record in place"
  ext "$dir" active t1 && fail "a cleared declaration still read as active"
  archive=$(ls "$state/external-waits/"*-t1.external-wait 2>/dev/null | head -1)
  [ -n "$archive" ] && [ -f "$archive" ] || fail "clear did not archive the record for the audit trail"
  assert_equals "cleared" "$(sed -n 's/^outcome: //p' "$archive")" "the archive does not record how the wait ended"
  assert_equals "firstmate" "$(sed -n 's/^ended_by: //p' "$archive")" "the archive does not record who ended the wait"
  assert_equals "rate-limit reset window" "$(sed -n 's/^reason: //p' "$archive")" \
    "the archive lost the declaration's reason"
  ext "$dir" clear t1 >/dev/null || fail "clearing an already-cleared task must be a no-op success"
  ext "$dir" declare t1 --reason "second wait" --until "$(future_iso 600)" >/dev/null || fail "redeclare failed"
  ext "$dir" declare t1 --reason "third wait" --until "$(future_iso 900)" --by "the supervisor" >/dev/null || fail "replace failed"
  archive=$(grep -l '^outcome: replaced$' "$state/external-waits/"*-t1*.external-wait 2>/dev/null | head -1)
  [ -n "$archive" ] && [ -f "$archive" ] || fail "replacing a declaration did not archive the prior record"
  assert_equals "the supervisor" "$(sed -n 's/^ended_by: //p' "$archive")" \
    "the replace archive does not attribute who ended the wait"
  assert_equals "second wait" "$(sed -n 's/^reason: //p' "$archive")" \
    "the replace archive lost the replaced declaration's reason"
  pass "clear and replace archive the record with who ended it and why, and clear is idempotent"
}

test_same_named_archives_keep_both_records() {
  local dir state record declared_epoch first second
  dir="$TMP_ROOT/archive-collision"; state="$dir/state"; mkdir -p "$state"
  ext "$dir" declare t1 --reason "first wait" --until "$(future_iso 600)" >/dev/null || fail "declare failed"
  record="$state/t1.external-wait"
  declared_epoch=$(sed -n 's/^declared_epoch: //p' "$record")
  ext "$dir" clear t1 >/dev/null || fail "clear failed"
  first="$state/external-waits/$declared_epoch-t1.external-wait"
  [ -f "$first" ] || fail "clear did not archive at the canonical name"
  ext "$dir" declare t1 --reason "second wait" --until "$(future_iso 600)" >/dev/null || fail "redeclare failed"
  # Two declarations of one task inside the same clock second: the redeclared
  # record is stamped with the archived declaration's epoch so the next replace
  # would land on the very same archive name.
  sed -i.bak "s/^declared_epoch: .*/declared_epoch: $declared_epoch/" "$record"
  rm -f "$record.bak"
  ext "$dir" declare t1 --reason "third wait" --until "$(future_iso 900)" >/dev/null || fail "replace failed"
  second=$(ls "$state/external-waits/" | grep -v -F "$(basename "$first")" | head -1)
  [ -n "$second" ] && [ -f "$state/external-waits/$second" ] \
    || fail "a same-second replace destroyed the prior archive instead of taking a unique name"
  assert_equals "cleared" "$(sed -n 's/^outcome: //p' "$first")" \
    "the first archive lost its outcome to the collision"
  assert_equals "first wait" "$(sed -n 's/^reason: //p' "$first")" \
    "the first archive lost its reason to the collision"
  assert_equals "replaced" "$(sed -n 's/^outcome: //p' "$state/external-waits/$second")" \
    "the colliding archive lost its outcome"
  assert_equals "second wait" "$(sed -n 's/^reason: //p' "$state/external-waits/$second")" \
    "the colliding archive lost its reason"
  pass "two archives that would share one name keep both audit records"
}

test_expiry_is_a_reader_verdict_not_a_cleanup_step() {
  local dir state record
  dir="$TMP_ROOT/expiry"; state="$dir/state"; mkdir -p "$state"
  ext "$dir" declare t2 --reason "scheduled window" --until "$(future_iso 60)" >/dev/null || fail "declare failed"
  record="$state/t2.external-wait"
  backdate_declaration "$record" 7200 -60
  ext "$dir" active t2 && fail "an expired declaration still read as active"
  assert_equals "expired" "$(ext "$dir" show t2 | sed -n 's/^verdict: //p')" "show did not report an expired declaration"
  assert_equals "scheduled window" "$(sed -n 's/^reason: //p' "$record")" \
    "expiry dropped the attribution an audit needs"
  pass "an expired declaration reads as expired (ordinary escalation restored) while the attribution stays readable"
}

# --- watcher behavior -------------------------------------------------------

# One stale parked pane fixture shared by the watcher cases: a static capture, a
# non-terminal status line, and the .hash/.count state that makes the next poll
# see the pane as already-stale.
stale_case() {  # <name> <window> <status-line> -> prints the case dir
  local name=$1 window=$2 status_line=$3 dir state capture_file key
  dir=$(make_case "$name"); state="$dir/state"
  capture_file="$dir/pane.txt"
  printf 'idle parked output' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/parked.meta"
  printf '%s\n' "$status_line" > "$state/parked.status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "idle parked output")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  printf '%s\n' "$dir"
}

run_watcher() {  # <dir> <pid-var> [extra env assignments...]
  local dir=$1 pidvar=$2
  shift 2
  env PATH="$dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW="${FM_FAKE_TMUX_WINDOW:-test:fm-parked}" \
    FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" \
    FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" &
  eval "$pidvar=\$!"
}

test_live_declaration_absorbs_the_wedge_ladder_and_clears_the_counter() {
  local dir state key pane_hash sig pid since_now
  dir=$(stale_case absorb-wedge "test:fm-parked" "working: parked on the provider")
  state="$dir/state"
  sig=$(seen_sig "$state/parked.status"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "test:fm-parked" | tr ':/.' '___')
  pane_hash=$(cat "$state/.hash-$key")
  ext "$dir" declare parked --reason "provider outage, generation stopped" \
    --until "$(future_iso 7200)" --by "firstmate" >/dev/null || fail "declare failed"
  # The pane already escalated twice before the declaration; the ladder is due.
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'
  run_watcher "$dir" pid FM_STALE_ESCALATE_SECS=240
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "the watcher died instead of absorbing: $(cat "$dir/watch.out" "$dir/watch.err")"; }
  reap "$pid"
  [ ! -s "$dir/watch.out" ] || fail "a live declaration still produced a wake: $(cat "$dir/watch.out")"
  [ ! -s "$state/.wake-queue" ] || fail "a live declaration still queued a wake: $(cat "$state/.wake-queue")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the wedge escalation counter outlived the declaration (a worker-authored pause clears it)"
  since_now=$(cat "$state/.stale-since-$key" 2>/dev/null || echo 0)
  [ "$since_now" -ge $(( $(date +%s) - 120 )) ] || fail "the stale timer was not absorbed (reset) under the declaration"
  pass "a live supervisor declaration absorbs the wedge ladder and clears its escalation counter"
}

test_expired_declaration_restores_ordinary_escalation() {
  local dir state key pane_hash sig pid
  dir=$(stale_case expired-escalate "test:fm-parked" "working: parked on the provider")
  state="$dir/state"
  sig=$(seen_sig "$state/parked.status"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "test:fm-parked" | tr ':/.' '___')
  pane_hash=$(cat "$state/.hash-$key")
  ext "$dir" declare parked --reason "provider outage, generation stopped" \
    --until "$(future_iso 60)" >/dev/null || fail "declare failed"
  backdate_declaration "$state/parked.external-wait" 7200 -60
  printf '%s' "$pane_hash" > "$state/.stale-$key"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'
  run_watcher "$dir" pid FM_STALE_ESCALATE_SECS=240
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "an expired declaration kept suppressing the wedge ladder"; }
  grep -F "possible wedge" "$dir/watch.out" >/dev/null \
    || fail "an expired declaration did not restore ordinary escalation: $(cat "$dir/watch.out")"
  grep "supervisor-declared external wait" "$state/.wake-queue" >/dev/null 2>&1 \
    && fail "an expired declaration still absorbed a wake"
  pass "an expired declaration restores ordinary wedge escalation"
}

test_re_surface_names_the_declaration_and_is_distinguishable_from_a_pause() {
  local dir state key pid sig
  dir=$(stale_case resurface-attribution "test:fm-parked" "working: parked on the provider")
  state="$dir/state"
  sig=$(seen_sig "$state/parked.status"); printf '%s' "$sig" > "$state/.seen-parked_status"
  key=$(printf '%s' "test:fm-parked" | tr ':/.' '___')
  ext "$dir" declare parked --reason "provider outage, generation stopped" \
    --until "$(future_iso 7200)" --by "firstmate (supervisor)" >/dev/null || fail "declare failed"
  # The wait has held longer than the pause cadence: its bounded recheck is due.
  backdate_declaration "$state/parked.external-wait" 20000 7200
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  run_watcher "$dir" pid FM_STALE_ESCALATE_SECS=240
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "the bounded recheck of a long-held declaration never surfaced"; }
  grep -F "supervisor-declared external wait" "$dir/watch.out" >/dev/null \
    || fail "the recheck did not identify itself as a supervisor declaration: $(cat "$dir/watch.out")"
  grep -F "declared by firstmate (supervisor)" "$dir/watch.out" >/dev/null \
    || fail "the recheck did not attribute the declaration"
  grep -F "provider outage, generation stopped" "$dir/watch.out" >/dev/null \
    || fail "the recheck did not carry the declared reason"
  grep -F "until " "$dir/watch.out" >/dev/null \
    || fail "the recheck did not carry the expected clear time"
  grep -F "possible wedge" "$dir/watch.out" >/dev/null \
    && fail "a declared wait's recheck was dressed up as a possible wedge"
  grep -F "awaiting external - declared pause" "$dir/watch.out" >/dev/null \
    && fail "a supervisor declaration borrowed the worker-pause wording an audit must distinguish"
  grep "supervisor-declared external wait" "$state/.wake-queue" >/dev/null \
    || fail "the bounded recheck was not durably queued"
  assert_no_grep "^paused:" "$state/parked.status" "the watcher fabricated a worker pause line for a supervisor declaration"
  pass "the bounded recheck names the declarer, reason, and expected clear time, distinct from a worker pause"
}

test_a_new_status_event_still_wakes_under_a_live_declaration() {
  local dir state pid
  dir=$(stale_case new-event-pass "test:fm-parked" "done: PR https://example.test/pull/7 checks green")
  state="$dir/state"
  ext "$dir" declare parked --reason "provider outage, generation stopped" \
    --until "$(future_iso 7200)" >/dev/null || fail "declare failed"
  # No .seen-* priming: this status event is genuinely new and must surface.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  run_watcher "$dir" pid FM_STALE_ESCALATE_SECS=240
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a new status event was swallowed by a live declaration"; }
  grep -E '^signal:' "$dir/watch.out" >/dev/null \
    || fail "a new status event did not surface as a signal wake: $(cat "$dir/watch.out")"
  grep "supervisor-declared external wait" "$dir/watch.out" >/dev/null \
    && fail "the new-event wake was replaced by the declaration's absorb wording"
  pass "a genuinely new status event still wakes immediately while a declaration is in force"
}

test_declare_records_attribution_without_touching_the_status_log
test_declare_refuses_unbounded_or_malformed_input
test_clear_archives_the_record_and_replacement_archives_the_prior_one
test_same_named_archives_keep_both_records
test_expiry_is_a_reader_verdict_not_a_cleanup_step
test_live_declaration_absorbs_the_wedge_ladder_and_clears_the_counter
test_expired_declaration_restores_ordinary_escalation
test_re_surface_names_the_declaration_and_is_distinguishable_from_a_pause
test_a_new_status_event_still_wakes_under_a_live_declaration
