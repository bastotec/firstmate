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

test_own_parent_channel_never_wakes_a_remote_mate
test_without_a_parent_record_every_status_file_wakes
