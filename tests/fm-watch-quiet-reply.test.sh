#!/usr/bin/env bash
# tests/fm-watch-quiet-reply.test.sh - a second mate's `done` reply to a request
# whose sender declared it needs no supervisor turn (reply_wake=none), together
# with the pending-reply resolution it causes, is absorbed instead of waking the
# first mate, on the per-wake path and on the heartbeat backstop. The same reply
# to an ordinary request, a non-done answer to a quiet request, and any other
# line in the same span still wake.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-quiet-reply)
QUIET=0123456789abcdef
LOUD=fedcba9876543210

# A second mate with one quiet and one ordinary pending-reply record, both made
# through the pending-reply library, and a status log the watcher has already seen.
make_mate_case() {  # <name> -> case dir
  local dir
  dir=$(make_case "$1")
  printf 'kind=secondmate\n' > "$dir/state/mate.meta"
  : > "$dir/state/mate.status"
  prime_status_seen "$dir/state" "$dir/state/mate.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" QUIET_ID="$QUIET" LOUD_ID="$LOUD" bash -c '
    . "$1"
    fm_pending_reply_new_id() { printf %s "$QUIET_ID"; }
    FM_PENDING_REPLY_WAKE=none fm_pending_reply_create "$2" "$2/state" mate "please persist" >/dev/null || exit 1
    fm_pending_reply_new_id() { printf %s "$LOUD_ID"; }
    fm_pending_reply_create "$2" "$2/state" mate "please answer" >/dev/null
  ' _ "$ROOT/bin/fm-pending-reply-lib.sh" "$dir" >&2 || return 1
  printf '%s\n' "$dir"
}

start_watch() {  # <dir> <out> [heartbeat-secs] -> pid in WATCH_PID
  local dir=$1 out=$2 hb=${3:-999999}
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT="$hb" FM_HEARTBEAT_MAX="$hb" \
    "$WATCH" > "$out" 2>/dev/null &
  WATCH_PID=$!
}

stop_watch() {
  kill "$WATCH_PID" 2>/dev/null || true
  wait "$WATCH_PID" 2>/dev/null || true
}

# Wait until the watcher logs an absorbed signal for the mate, still running.
wait_for_absorb() {  # <dir>
  local dir=$1 i
  for ((i=0; i<100; i++)); do
    grep -F "absorbed benign signal:" "$dir/state/.watch-triage.log" 2>/dev/null | grep -F mate.status >/dev/null && return 0
    is_live_non_zombie "$WATCH_PID" || return 1
    sleep 0.1
  done
  return 1
}

quiet_lines() {  # <dir>
  printf 'done corr=%s: open records persisted, nothing left only in conversation\n' "$QUIET" >> "$1/state/mate.status"
  printf 'resolved [key=pending-reply-%s]: pending-reply-resolved: task=mate pending-reply-id=%s via=status\n' "$QUIET" "$QUIET" >> "$1/state/mate.status"
}

test_quiet_reply_is_absorbed_and_later_lines_still_wake() {
  local dir out
  dir=$(make_mate_case absorbed) || fail "could not create the pending-reply records"
  out="$dir/watch.out"
  start_watch "$dir" "$out"
  sleep 1.5
  quiet_lines "$dir"
  if ! wait_for_absorb "$dir"; then
    stop_watch
    fail "a quiet reply and its resolution must be absorbed with the watcher still running: $(cat "$out")"
  fi
  if [ -s "$dir/state/.wake-queue" ] || [ -s "$out" ]; then
    stop_watch
    fail "an absorbed quiet reply must not enqueue a wake: $(cat "$out")"
  fi
  printf 'done: shipped the fix\n' >> "$dir/state/mate.status"
  wait_for_exit "$WATCH_PID" 100 || fail "a later ordinary line must still wake: $(cat "$out")"
  grep -F "$dir/state/mate.status" "$out" >/dev/null || fail "the later line must name the mate: $(cat "$out")"
  pass "a quiet reply is absorbed and the mate's next ordinary line still wakes"
}

test_ordinary_reply_still_wakes() {
  local dir out
  dir=$(make_mate_case ordinary) || fail "could not create the pending-reply records"
  out="$dir/watch.out"
  start_watch "$dir" "$out"
  sleep 1.5
  printf 'done corr=%s: here is the answer you asked for\n' "$LOUD" >> "$dir/state/mate.status"
  wait_for_exit "$WATCH_PID" 100 || fail "a reply to an ordinary request must wake: $(cat "$out")"
  grep -F "$dir/state/mate.status" "$out" >/dev/null || fail "the ordinary reply must name the mate: $(cat "$out")"
  pass "a done reply to an ordinary request still wakes"
}

test_non_done_answer_to_quiet_request_wakes() {
  local dir out
  dir=$(make_mate_case failed-answer) || fail "could not create the pending-reply records"
  out="$dir/watch.out"
  start_watch "$dir" "$out"
  sleep 1.5
  printf 'failed corr=%s: could not persist the open records\n' "$QUIET" >> "$dir/state/mate.status"
  wait_for_exit "$WATCH_PID" 100 || fail "a failed answer to a quiet request must wake: $(cat "$out")"
  grep -F "$dir/state/mate.status" "$out" >/dev/null || fail "the failed answer must name the mate: $(cat "$out")"
  pass "a non-done answer to a quiet request still wakes"
}

test_other_line_in_the_same_span_wakes() {
  local dir out
  dir=$(make_mate_case mixed-span) || fail "could not create the pending-reply records"
  out="$dir/watch.out"
  start_watch "$dir" "$out"
  sleep 1.5
  { quiet_lines "$dir"; printf 'working: started the follow-up\n' >> "$dir/state/mate.status"; }
  wait_for_exit "$WATCH_PID" 100 || fail "a progress line beside a quiet reply must wake: $(cat "$out")"
  grep -F "$dir/state/mate.status" "$out" >/dev/null || fail "the mixed span must name the mate: $(cat "$out")"
  pass "any other line in the same span still wakes"
}

test_reply_naming_another_corr_wakes() {
  local dir out
  dir=$(make_mate_case two-corrs) || fail "could not create the pending-reply records"
  out="$dir/watch.out"
  start_watch "$dir" "$out"
  sleep 1.5
  printf 'done corr=%s corr=%s: persisted, and the other answer too\n' "$QUIET" "$LOUD" >> "$dir/state/mate.status"
  wait_for_exit "$WATCH_PID" 100 || fail "a reply naming a second correlation must wake: $(cat "$out")"
  pass "a done line naming a second correlation still wakes"
}

test_heartbeat_does_not_resurface_quiet_reply() {
  local dir out i
  dir=$(make_mate_case heartbeat) || fail "could not create the pending-reply records"
  out="$dir/watch.out"
  quiet_lines "$dir"
  rm -f "$dir/state/.heartbeat-streak"
  start_watch "$dir" "$out" 1
  for ((i=0; i<100; i++)); do
    [ -s "$dir/state/.heartbeat-streak" ] && break
    is_live_non_zombie "$WATCH_PID" || break
    sleep 0.1
  done
  if [ ! -s "$dir/state/.heartbeat-streak" ] || ! is_live_non_zombie "$WATCH_PID"; then
    stop_watch
    fail "a due heartbeat must absorb the quiet reply: $(cat "$out")"
  fi
  [ ! -s "$dir/state/.wake-queue" ] && [ ! -s "$out" ] || { stop_watch; fail "the heartbeat must not enqueue the quiet reply: $(cat "$out")"; }
  stop_watch
  pass "the heartbeat backstop does not resurface a quiet reply"
}

test_quiet_reply_is_absorbed_and_later_lines_still_wake
test_ordinary_reply_still_wakes
test_non_done_answer_to_quiet_request_wakes
test_other_line_in_the_same_span_wakes
test_reply_naming_another_corr_wakes
test_heartbeat_does_not_resurface_quiet_reply
