#!/usr/bin/env bash
# Pin the recovery-loop fix: a handling successor keeps supervising instead of
# going blind.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-watch-recovery-loop)

# T2: a handling successor must enter its poll loop and surface a real crew
# event within a bounded startup-and-poll budget instead of sitting in a
# pre-loop wait that refreshes the liveness beacon and then exits with a
# synthetic rearm-resurface.
test_handling_successor_does_not_go_blind() {
  local dir home state fakebin child event_start now out
  dir=$(make_case recovery-gap-successor)
  home="$dir/home"
  state="$dir/state"
  fakebin="$dir/fakebin"
  mkdir -p "$home/data"
  : > "$state/crew.meta"
  printf 'pending:downtime:gap.1.aaa\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=600 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$out" 2>&1 &
  child=$!
  now=0
  while [ "$now" -lt 40 ]; do
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] && break
    sleep 0.1
    now=$((now + 1))
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not take the watcher lock"; }
  sleep 0.4
  printf 'done: crew finished its task\n' >> "$state/crew.status"
  event_start=$(date +%s)
  now=0
  while [ "$now" -lt 20 ]; do
    if grep -q '^signal:' "$out" 2>/dev/null; then
      break
    fi
    sleep 0.5
    now=$((now + 1))
  done
  if ! grep -q '^signal:' "$out" 2>/dev/null; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
    fail "handling successor did not surface the crew event within the bounded startup-and-poll budget (waited $(( $(date +%s) - event_start ))s): $(cat "$out")"
  fi
  grep -F 'crew.status' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not name the crew status file: $(cat "$out")"; }
  grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor did not enqueue a durable row for the crew event"; }
  ! grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || { kill -TERM "$child" 2>/dev/null || true; fail "handling successor emitted synthetic recovery instead of supervising: $(cat "$out")"; }
  if [ "${FM_TEST_EVIDENCE:-0}" = 1 ]; then
    printf 'T2_WATCH_OUTPUT=%s\n' "$(tr '\n' ' ' < "$out")"
    printf 'T2_QUEUE_ROW=%s\n' "$(grep "$(printf '\tsignal\tcrew.status\t')" "$state/.wake-queue" | tail -1)"
  fi
  kill -TERM "$child" 2>/dev/null || true
  wait "$child" 2>/dev/null || true
  pass "a resurfacing handling successor stays alive and supervises instead of going blind"
}

# T3: the foreign no-progress shape must stay observable in a handling
# successor across multiple poll cycles, even when its observation clock is
# unrelated to filesystem mtimes. A single lock sample cannot prove this.
test_foreign_queue_successor_continuity_window() {
  local dir state sub fakebin real_date child out i progress
  dir=$(make_case foreign-successor-window)
  state="$dir/state"
  sub="$dir/secondmate"
  fakebin="$dir/fakebin"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  printf 'acked:handling:window.1\n' > "$state/.watcher-down"
  chmod 600 "$state/.watcher-down"
  printf '1000\n' > "$dir/now"
  printf '100\t7\tcheck\trouted\tcheck: routed row\n' > "$sub/state/.wake-queue"
  real_date=$(command -v date)
  cat > "$fakebin/date" <<SH
#!/usr/bin/env bash
if [ "\${1:-}" = +%s ]; then
  cat "\${FM_FAKE_NOW_FILE:?}"
else
  exec "$real_date" "\$@"
fi
SH
  chmod +x "$fakebin/date"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_FAKE_NOW_FILE="$dir/now" FM_HOME="$dir" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_HANDLING_SUCCESSOR=1 \
    "$WATCH" > "$out" 2>&1 &
  child=$!
  fm_test_track_helper_pid "$child"
  i=0
  while [ "$i" -lt 40 ]; do
    progress=$(cat "$state/.secondmate-wake-progress-mate" 2>/dev/null || true)
    [ "$progress" = $'1000\t100-7' ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$progress" = $'1000\t100-7' ] || fail "successor never observed the foreign queue"
  if ! { printf '100\t8\tcheck\thealthy\tcheck: healthy progress\n' > "$sub/state/.wake-queue.tmp" \
    && mv "$sub/state/.wake-queue.tmp" "$sub/state/.wake-queue"; }; then
    fail "could not publish foreign drain progress"
  fi
  i=0
  while [ "$i" -lt 40 ]; do
    progress=$(cat "$state/.secondmate-wake-progress-mate" 2>/dev/null || true)
    [ "$progress" = $'1000\t100-8' ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$progress" = $'1000\t100-8' ] || fail "successor did not recognize foreign drain progress"
  # Sample an entire two-second window, not just startup presence.
  i=0
  while [ "$i" -lt 20 ]; do
    is_live_non_zombie "$child" || fail "successor stopped inside the continuity window"
    [ "$(cat "$state/.watch.lock/pid" 2>/dev/null || true)" = "$child" ] \
      || fail "successor lost singleton ownership inside the continuity window"
    [ "$(cat "$state/.watcher-down")" = 'acked:handling:window.1' ] \
      || fail "successor reopened an acknowledged recovery episode"
    [ ! -s "$out" ] && [ ! -s "$state/.wake-queue" ] \
      || fail "healthy progress caused a duplicate or synthetic model wake"
    sleep 0.1
    i=$((i + 1))
  done
  if ! { printf '1002\n' > "$dir/now.tmp" && mv "$dir/now.tmp" "$dir/now"; }; then
    fail "could not publish the stalled clock"
  fi
  wait_for_exit "$child" 40 || fail "foreign no-progress episode stayed hidden after the window"
  grep -Fx 'check: secondmate wake-loop stalled: mate=mate row=8 idle=2s' "$out" >/dev/null \
    || fail "successor did not surface the exact foreign no-progress episode"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] \
    || fail "successor delivered more than one model wake"
  [ "$(grep -c 'secondmate-wake-loop-mate-100-8' "$state/.wake-queue")" = 1 ] \
    || fail "foreign stall delivery was not bound to exactly one durable row"
  grep -Fx $'100\t8\tcheck\thealthy\tcheck: healthy progress' "$sub/state/.wake-queue" >/dev/null \
    || fail "successor modified the foreign queue"
  pass "one handling successor preserves acknowledged recovery and foreign queue observation across a poll window"
}

test_handling_successor_does_not_go_blind
test_foreign_queue_successor_continuity_window
