#!/usr/bin/env bash
# tests/fm-watch-parent-channel-echo.test.sh - a remote secondmate's own parent
# channel (state/parent-replies.status) carries its outgoing reports, so a line
# it appends there never wakes that same mate, while its children's status
# lines still do. A home with no secondmate parent record keeps waking on every
# status file, including one that happens to share the name.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-parent-channel-echo)

run_watch() {  # <dir> <out> -> watcher exit code
  local dir=$1 out=$2 pid
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100
}

test_own_parent_channel_never_wakes_a_remote_mate() {
  local dir out
  dir=$(make_case remote-mate)
  out="$dir/watch.out"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=example\n' > "$dir/.fm-secondmate-parent"
  printf 'done corr=0123456789abcdef: answered the captain directly\n' > "$dir/state/parent-replies.status"
  printf 'done: shipped the fix\n' > "$dir/state/child.status"
  run_watch "$dir" "$out" || fail "the watcher should surface the child's line: $(cat "$out")"
  grep -F "$dir/state/child.status" "$out" >/dev/null || fail "the child's status line must still wake the mate: $(cat "$out")"
  if grep -F "parent-replies.status" "$out" >/dev/null; then
    fail "the mate's own parent-channel line must not wake it: $(cat "$out")"
  fi
  pass "a remote mate's own parent-channel line never wakes it; a child's line still does"
}

test_without_a_parent_record_every_status_file_wakes() {
  local dir out
  dir=$(make_case no-parent)
  out="$dir/watch.out"
  printf 'done: something\n' > "$dir/state/parent-replies.status"
  run_watch "$dir" "$out" || fail "the watcher should surface the line: $(cat "$out")"
  grep -F "$dir/state/parent-replies.status" "$out" >/dev/null \
    || fail "without a secondmate parent record the file is an ordinary status file: $(cat "$out")"
  pass "a home with no secondmate parent record still wakes on that file"
}

test_heartbeat_ignores_own_parent_channel() {
  local dir out pid i
  dir=$(make_case remote-heartbeat)
  out="$dir/watch.out"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=example\n' > "$dir/.fm-secondmate-parent"
  printf 'done: reported upward\n' > "$dir/state/parent-replies.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 FM_HEARTBEAT_MAX=1 \
    "$WATCH" > "$out" 2>"$dir/watch.err" &
  pid=$!
  for ((i=0; i<100; i++)); do
    [ -s "$dir/state/.heartbeat-streak" ] && break
    is_live_non_zombie "$pid" || break
    sleep 0.1
  done
  if [ ! -s "$dir/state/.heartbeat-streak" ] || ! is_live_non_zombie "$pid"; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the outgoing report must not wake the mate on a due heartbeat: $(cat "$out")"
  fi
  if [ -s "$dir/state/.wake-queue" ] || [ -s "$out" ]; then
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "an absorbed outgoing-channel heartbeat must not enqueue a wake"
  fi
  printf 'done: shipped the fix\n' > "$dir/state/child.status"
  wait_for_exit "$pid" 100 || fail "the child must still wake the mate after an absorbed heartbeat: $(cat "$out")"
  grep -F "$dir/state/child.status" "$out" >/dev/null \
    || fail "the child must still surface after the heartbeat: $(cat "$out")"
  pass "a due heartbeat ignores outgoing reports without suppressing child notifications"
}

test_heartbeat_keeps_parent_mirror() {
  local mate dir out pid
  mate=$(make_case mirrored-mate)
  dir=$(make_case mirror-parent)
  out="$dir/watch.out"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=example\n' > "$mate/.fm-secondmate-parent"
  printf 'done: reported upward\n' > "$mate/state/parent-replies.status"
  ln -s "$mate/state/parent-replies.status" "$dir/state/mate.status"
  prime_status_seen "$dir/state" "$dir/state/mate.status"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
    "$WATCH" > "$out" 2>/dev/null &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the parent's heartbeat must surface its mirrored mate's report: $(cat "$out")"
  grep -Fx heartbeat "$out" >/dev/null || fail "the parent's mirrored report must trigger the backstop: $(cat "$out")"
  [ -s "$dir/state/.wake-queue" ] || fail "the parent's heartbeat must enqueue a wake"
  pass "the parent's heartbeat still surfaces mirrored child reports"
}

test_daemon_catch_all_respects_channel_direction() (
  local dir parent out
  dir=$(make_case remote-catch-all)
  parent=$(make_case parent-catch-all)
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=example\n' > "$dir/.fm-secondmate-parent"
  printf 'done: reported upward\n' > "$dir/state/parent-replies.status"
  export FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_HEARTBEAT_SCAN_SECS=0
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$ROOT/bin/fm-supervise-daemon.sh"
  housekeeping "$dir/state"
  [ ! -s "$dir/state/.subsuper-escalations" ] || fail "the daemon must ignore its home's outgoing report"
  printf 'done: shipped the fix\n' > "$dir/state/child.status"
  housekeeping "$dir/state"
  out=$(cat "$dir/state/.subsuper-escalations")
  assert_contains "$out" 'child.status' "the daemon must keep the child's report"
  assert_not_contains "$out" 'parent-replies.status' "the daemon must not echo its own report"
  ln -s "$dir/state/parent-replies.status" "$parent/state/mate.status"
  FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" housekeeping "$parent/state"
  out=$(cat "$parent/state/.subsuper-escalations")
  assert_contains "$out" 'mate.status' "the parent daemon must keep its mirrored child's report"
  printf 'done: ordinary status\n' > "$parent/state/parent-replies.status"
  FM_HOME="$parent" FM_STATE_OVERRIDE="$parent/state" housekeeping "$parent/state"
  out=$(cat "$parent/state/.subsuper-escalations")
  assert_contains "$out" 'parent-replies.status' "without a parent record the daemon must keep the ordinary status"
  pass "the daemon catch-all ignores only this home's outgoing channel"
)

test_own_parent_channel_never_wakes_a_remote_mate
test_without_a_parent_record_every_status_file_wakes
test_heartbeat_ignores_own_parent_channel
test_heartbeat_keeps_parent_mirror
test_daemon_catch_all_respects_channel_direction
