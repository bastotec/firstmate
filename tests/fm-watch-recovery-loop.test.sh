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

publish_stall_digest() {
  FM_HOME="$1" FM_STATE_OVERRIDE="$1/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$STATE/.control-worker.lock" || exit 1
    trap '\''fm_lock_release "$STATE/.control-worker.lock"'\'' EXIT
    "$1/bin/fm-parked-run-watch.sh" digest < "$2/candidate.json"
  ' _ "$ROOT" "$1"
}

test_handling_successor_delivers_stall_digest() {
  local dir state now old current decisions episode fifo reader child status
  dir=$(make_case stall-digest-successor)
  state="$dir/state"
  mkdir -p "$dir/data" "$dir/config" "$state/idle-sweep"
  touch "$state/.last-parked-run-watch" "$state/home-summary.json"
  printf 'kind=ship\nmode=no-mistakes\nspawn_gen=fixture\n' > "$state/worker.meta"
  now=$(date +%s)
  old=$((now - 8000))
  printf '{"run":"run-one","step":"review","parked_since":%s}\n' "$old" > "$state/worker.gate"
  current='state: parked · source: run-step · evidence: run=run-one; step=review'
  decisions=$'choice\tneeds-decision\tWhich behavior should be retained?'
  python3 "$ROOT/bin/fm_stall_record.py" "$state/idle-sweep/worker.stall.json" \
    "$state/worker.meta" "$current" "$decisions" --observe > "$dir/stall.json" || fail 'seed stall episode'
  episode=$(jq -r .episode "$dir/stall.json")
  [ "$(jq -r .notify "$dir/stall.json")" = true ] || fail 'seed episode not overdue'
  cp "$state/worker.meta" "$state/worker-two.meta"
  cp "$state/worker.gate" "$state/worker-two.gate"
  cp "$state/idle-sweep/worker.stall.json" "$state/idle-sweep/worker-two.stall.json"
  jq -nc --arg current "$current" --arg decisions "$decisions" --slurpfile stall "$dir/stall.json" \
    '{id:"worker", current:$current, decisions:$decisions, stall:$stall[0]} | ., (.id="worker-two")' > "$dir/candidate.json"
  mkdir "$state/.wake-queue"
  if publish_stall_digest "$dir"; then
    fail 'digest publication unexpectedly succeeded with unavailable queue'
  fi
  [ "$(jq -r .notify "$state/idle-sweep/worker.stall.json")" = true ] || fail 'failed publication suppressed retry'
  [ ! -e "$state/idle-sweep/worker.stall-delivered" ] || fail 'failed publication recorded delivery'
  rmdir "$state/.wake-queue"
  publish_stall_digest "$dir" || fail 'digest retry publication'
  [ "$(jq -r .notify "$state/idle-sweep/worker.stall.json")" = false ] || fail 'successful publication not acknowledged'
  grep -Fqx "$episode" "$state/idle-sweep/worker.stall-delivered" || fail 'episode receipt lost'
  grep -Fqx "$episode" "$state/idle-sweep/worker-two.stall-delivered" || fail 'batched episode receipt lost'
  cp "$state/.wake-queue" "$dir/queued"
  fifo="$dir/output.fifo"
  mkfifo "$fifo"
  sh -c ': < "$1"' _ "$fifo" &
  reader=$!
  fm_test_track_helper_pid "$reader"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$fifo" 2> "$dir/failed.err" &
  child=$!
  fm_test_track_helper_pid "$child"
  wait_for_exit "$reader" 100 || fail 'failed-output reader did not finish'
  status=0
  wait_for_exit "$child" 100 || status=$?
  [ "$status" -ne 0 ] && [ "$status" -ne 124 ] || fail 'successor did not attempt the digest doorbell'
  [ ! -s "$state/.watch-deliveries.log" ] || fail 'failed doorbell recorded delivery'
  [ "$(find "$state" -name '.seen-procevent-*' -type f | wc -l | tr -d '[:space:]')" = 0 ] \
    || fail 'failed doorbell suppressed replay'
  cmp -s "$dir/queued" "$state/.wake-queue" || fail 'failed doorbell changed queued episode'
  publish_stall_digest "$dir" || fail 'publication retry after doorbell failure'
  cmp -s "$dir/queued" "$state/.wake-queue" || fail 'publication retry duplicated queued episode'
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_STATE_OVERRIDE="$state" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" > "$dir/watch.out" 2> "$dir/watch.err" &
  child=$!
  fm_test_track_helper_pid "$child"
  wait_for_exit "$child" 100 || fail "successor did not deliver queued digest: $(cat "$dir/watch.out")"
  grep -Fx 'check: stalled tasks digest: inspect pending questions and repair stalled implementation' "$dir/watch.out" >/dev/null \
    || fail "successor did not deliver an actionable digest reason: $(cat "$dir/watch.out")"
  [ "$(wc -l < "$dir/watch.out" | tr -d '[:space:]')" = 1 ] || fail 'successor emitted unrelated notifications'
  awk -F '\t' -v pid="$child" '$1==pid && $3=="check: stalled tasks digest: inspect pending questions and repair stalled implementation" { found=1 } END { exit !found }' \
    "$state/.watch-deliveries.log" || fail 'digest bypassed real watcher delivery owner'
  [ "$(find "$state" -name '.seen-procevent-*' -type f | wc -l | tr -d '[:space:]')" = 1 ] \
    || fail 'batched digest did not persist duplicate suppression'
  cmp -s "$dir/queued" "$state/.wake-queue" || fail 'doorbell changed episode-bearing queue'
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-wake-drain.sh" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail 'digest drain'
  grep -F 'Which behavior should be retained?' "$dir/drain.out" >/dev/null || fail 'digest question lost at delivery'
  ack_drain_err "$state" "$dir/drain.err" || fail 'digest post-handling acknowledgment'
  [ ! -s "$state/.wake-queue" ] || fail 'handled digest remained queued'
  publish_stall_digest "$dir" || fail 'publication retry after handling'
  [ ! -s "$state/.wake-queue" ] || fail 'handled episode republished on restart'
  grep -Fqx "$episode" "$state/idle-sweep/worker.stall-delivered" || fail 'handling lost episode receipt'
  pass 'handling successor delivers the real stalled-task doorbell across publication and output retries'
}

test_handling_successor_does_not_go_blind
test_foreign_queue_successor_continuity_window
test_handling_successor_delivers_stall_digest
