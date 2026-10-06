#!/usr/bin/env bash
# tests/fm-watch-triage-events.test.sh - wake triage, part 5: event sources and
# watcher lifecycle. Process-event results, captain inbox notes, in-place code
# reload, the heartbeat backstop, and away-mode hand-off.
# Shared fixtures and the suite overview: tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

# Wait up to <limit> 0.1s ticks while <pid> stays alive; 0 if still alive, 1 if it died.
wait_live() {
  local pid=$1 limit=${2:-30} i=0
  while [ "$i" -lt "$limit" ]; do
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.1
    i=$((i + 1))
  done
  return 0
}

# --- triage debug log stays size capped -------------------------------------

test_triage_log_size_cap_accepts_spaced_wc_counts() {
  local dir state fakebin out status_file pid lines i
  dir=$(make_case triage-log-spaced-wc); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  i=1
  while [ "$i" -le 3000 ]; do
    printf 'old line %04d\n' "$i" >> "$state/.watch-triage.log"
    i=$((i + 1))
  done
  cat > "$fakebin/wc" <<'SH'
#!/usr/bin/env bash
set -u
if [ "${1:-}" = "-c" ]; then
  printf '   999999\n'
  exit 0
fi
exit 127
SH
  chmod +x "$fakebin/wc"
  status_file="$state/task.status"
  printf 'working: compiling step 2\n' > "$status_file"
  # Provably working so the no-verb signal is absorbed (which is what writes the
  # triage log line under test).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_TRIAGE_LOG_MAX_BYTES=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a benign signal while testing log capping: $(cat "$out")"
  fi
  i=0
  while [ "$i" -lt 30 ]; do
    lines=$(awk 'END { print NR + 0 }' "$state/.watch-triage.log")
    [ "$lines" -le 2000 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$lines" -le 2000 ] || { reap "$pid"; fail "triage log was not capped when wc emitted a spaced byte count (lines=$lines)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "benign signal enqueued a wake while testing log capping"; }
  reap "$pid"
  pass "triage log capping handles wc byte counts with leading spaces"
}

# --- process-event delivery -------------------------------------------------
# A durably captured process-event result publishes an ordinary `check` wake on
# the durable queue. The watcher must deliver that queued wake proactively -
# print an actionable reason and exit into the same rewake path every other
# actionable wake uses - rather than leaving it to be found by a manual drain.

# Run the runner against a case home. FM_ROOT_OVERRIDE (exported by the shared
# wake harness to keep the drain's tangle check inert) would otherwise point the
# runner at a root with no installed adapters, and the claim root must stay
# inside the case so nothing here can observe a real home's source ownership.
pe_case() {  # <dir> <command>...
  local dir=$1
  dir=$(cd "$dir" && pwd -P) || return 1
  shift
  (unset FM_ROOT_OVERRIDE
   FM_PROCEVENT_CLAIM_ROOT="$dir/claims" FM_HOME="$dir" "$ROOT/bin/fm-procevent.sh" "$@")
}

# Capture one real process-event result into <dir>'s home, then retire the
# source so the fixture holds exactly the reported end state: one durably
# captured, unhandled, queued result and no remaining poll work.
seed_captured_procevent_result() {  # <dir>
  local dir=$1 i=0
  pe_case "$dir" register lavish delivery-src -- \
    /bin/sh -c 'printf "session:\n  file: /a.html\n  status: waiting\n"' >/dev/null || return 1
  pe_case "$dir" reconcile >/dev/null || return 1
  while [ "$i" -lt 100 ]; do
    [ -s "$dir/state/.wake-queue" ] && break
    sleep 0.1
    i=$((i + 1))
  done
  # The runner publishes that wake BEFORE it releases its claim and exits, so a
  # retire that lands in that gap reads the exiting runner's ownership as
  # uncertain and refuses with "cannot confirm runner identity" - the pipeline
  # saw exactly that under load. Wait, bounded, for the release the publish
  # promises, so retire meets a source nothing owns instead of racing the
  # runner's last milliseconds. The bound keeps a runner that never releases a
  # real failure at retire rather than a hang here.
  i=0
  while [ "$i" -lt 100 ]; do
    [ -e "$dir/claims/delivery-src.claim" ] || break
    sleep 0.1
    i=$((i + 1))
  done
  pe_case "$dir" retire delivery-src >/dev/null || return 1
  [ -s "$dir/state/.wake-queue" ]
}

# The watcher, scoped by FM_HOME rather than FM_STATE_OVERRIDE, so the
# per-cycle reconcile it launches resolves the same home's state.
procevent_watch_bg() {  # <dir> <out>
  local dir=$1 out=$2
  dir=$(cd "$dir" && pwd -P) || return 1
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
}

test_procevent_captured_result_surfaces_proactively() {
  local dir state out drain_out pid beacon_age
  dir=$(make_case procevent-delivery); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"
  grep -F "procevent lavish delivery-src 1" "$state/.wake-queue" >/dev/null \
    || fail "the captured result was never published to the durable queue"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "a healthy watcher never surfaced a durably captured process-event result: $(cat "$out")"
  grep -F "check:" "$out" >/dev/null \
    || fail "the process-event wake was not reported as an actionable check: $(cat "$out")"
  grep -F "procevent:delivery-src:1" "$out" >/dev/null \
    || fail "the actionable reason did not name the queued result: $(cat "$out")"
  beacon_age=$(FM_STATE_OVERRIDE="$state" bash -c \
    '. "$1/bin/fm-wake-lib.sh"; fm_path_age "$2"' _ "$ROOT" "$state/.last-watcher-beat")
  [ "$beacon_age" -lt 60 ] || fail "the surfacing watcher was not a healthy one (beacon age ${beacon_age}s)"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the process-event wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "procevent lavish delivery-src 1" >/dev/null \
    || fail "the process-event result was not queued for the drain that follows the wake"
  pass "a captured process-event result wakes a healthy watcher proactively, with no manual drain"
}

# A captain inbox note (bin/fm-inbox.sh note) wakes a healthy watcher mid-sleep,
# within a few seconds, and only once. Before this, nothing in the watcher read
# an inbox row: it sat on the queue until an unrelated event closed a cycle,
# which on a quiet fleet was hours.
test_inbox_note_wakes_the_watcher_promptly() {
  local dir state out drain_out drain_err pid began took first_note long_note before after sleep_state
  dir=$(make_case inbox-note); state="$dir/state"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; drain_err="$dir/drain.err"
  dir=$(cd "$dir" && pwd -P)
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=30 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  # Let the first cycle finish and settle into its 30 s sleep.
  for _ in $(seq 1 100); do [ -e "$state/.last-watcher-beat" ] && break; sleep 0.1; done
  sleep 2
  is_live_non_zombie "$pid" || fail "the watcher exited before any note was queued: $(cat "$out")"
  began=$(date +%s)
  printf -v long_note 'what is blocking the release %02048d' 0
  FM_HOME="$dir" "$ROOT/bin/fm-inbox.sh" note "$long_note" >/dev/null 2>&1 \
    || fail "the inbox note could not be queued"
  wait_for_exit "$pid" 100 || fail "a queued inbox note did not wake the sleeping watcher: $(cat "$out")"
  took=$(( $(date +%s) - began ))
  [ "$took" -le 5 ] || fail "the inbox note took ${took}s to wake a watcher sleeping 30 s"
  grep -F "check: captain inbox note:" "$out" >/dev/null \
    || fail "the wake did not name the captain inbox note: $(cat "$out")"
  first_note=$(sed -n 's/.*check: captain inbox note: *\([^ ;]*\).*/\1/p' "$out" | head -1)
  [ -n "$first_note" ] || fail "the wake did not name the note id: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" \
    || fail "drain after the inbox wake failed"
  grep -F "captain inbox note" "$drain_out" >/dev/null \
    || fail "the note was not in the drain that follows the wake: $(cat "$drain_out")"

  sleep_state="$dir/poll-sleep"
  cat > "$dir/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
count=$(cat "$FM_TEST_SLEEP_STATE.count" 2>/dev/null || echo 0)
count=$((count + 1))
printf '%s\n' "$count" > "$FM_TEST_SLEEP_STATE.count"
if [ "$count" -eq 1 ]; then
  : > "$FM_TEST_SLEEP_STATE.ready"
  while [ ! -e "$FM_TEST_SLEEP_STATE.release" ]; do /bin/sleep 0.01; done
  exit 0
fi
exec /bin/sleep "$@"
SH
  chmod +x "$dir/fakebin/sleep"
  : > "$out"
  PATH="$dir/fakebin:$PATH" FM_TEST_SLEEP_STATE="$sleep_state" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_HOME="$dir" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=30 \
    FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  for _ in $(seq 1 100); do
    [ -e "$sleep_state.ready" ] && break
    is_live_non_zombie "$pid" || break
    sleep 0.1
  done
  [ -e "$sleep_state.ready" ] \
    || { reap "$pid"; fail "the successor watcher did not reach its poll sleep: $(cat "$out")"; }
  before=$(size_of "$state/.wake-queue")
  FM_HOME="$dir" "$ROOT/bin/fm-inbox.sh" note "x" >/dev/null 2>&1 \
    || { reap "$pid"; fail "the replacement inbox note could not be queued"; }
  # Read the older note first: its wake is not acknowledged while it is unread.
  FM_HOME="$dir" "$ROOT/bin/fm-inbox.sh" drain --ack "$first_note" >/dev/null \
    || { reap "$pid"; fail "the older note could not be acknowledged"; }
  ack_drain_err "$state" "$drain_err" >/dev/null \
    || { reap "$pid"; fail "the older surfaced note could not be acknowledged"; }
  after=$(size_of "$state/.wake-queue")
  [ "$after" -lt "$before" ] \
    || { reap "$pid"; fail "the concurrent replacement did not shrink the queue ($before to $after bytes)"; }
  : > "$sleep_state.release"
  wait_for_exit "$pid" 50 \
    || fail "an inbox note hidden by concurrent queue shrink waited for the full poll: $(cat "$out")"
  [ "$(cat "$sleep_state.count")" = 1 ] \
    || fail "the queue-shrink note needed more than one poll tick to wake the watcher"
  grep -F "check: captain inbox note:" "$out" >/dev/null \
    || fail "the queue-shrink wake did not name the captain inbox note: $(cat "$out")"
  rm -f "$dir/fakebin/sleep"

  # A note already on the queue when the sleep begins - appended after the
  # cycle's scan, before its baseline - still wakes it at once, not after POLL.
  mkdir -p "$state/inbox"
  printf 'id=raced\n--\nraced\n' > "$state/inbox/raced.note"
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_wake_append check "inbox:raced" "check: captain inbox note raced - fixture"' _ "$ROOT" \
    || fail "could not queue the raced note"
  took=$(FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_POLL=30 bash -c '
    set -e
    . "$1/bin/fm-watch.sh"
    began=$(date +%s); poll_sleep; echo $(( $(date +%s) - began ))' _ "$ROOT") \
    || fail "poll_sleep could not run against the raced note"
  [ "$took" -le 2 ] || fail "a note queued before the sleep's baseline waited ${took}s"

  # Surfaced once: the next watcher does not wake again for the same note.
  : > "$out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    grep -F "$first_note" "$out" >/dev/null \
      && fail "an already-surfaced inbox note woke the watcher again: $(cat "$out")"
  fi
  reap "$pid"
  pass "a captain inbox note wakes a sleeping watcher within seconds, once"
}

# An acknowledgement must not consume the wake of a captain note nobody read.
# The row stays until `fm-inbox.sh drain --ack` proves the note was read, the
# acknowledgement says so on its last line, and the next watcher cycle surfaces
# the note again at once.
test_unread_inbox_note_survives_acknowledgement() {
  local dir state out drain_out drain_err ack_err pid id
  dir=$(make_case inbox-unread-ack); state="$dir/state"
  dir=$(cd "$dir" && pwd -P)
  out="$dir/watch.out"; drain_out="$dir/drain.out"; drain_err="$dir/drain.err"; ack_err="$dir/ack.err"
  id=$(FM_HOME="$dir" "$ROOT/bin/fm-inbox.sh" note "which customer is the document fix for" 2>/dev/null \
    | sed -n 's/^queued //p')
  [ -n "$id" ] || fail "the inbox note could not be queued"

  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "the queued note did not wake the watcher: $(cat "$out")"
  grep -F "$id" "$out" >/dev/null || fail "the wake did not name the note: $(cat "$out")"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" || fail "the drain failed"
  grep -F "inbox:$id" "$drain_out" >/dev/null || fail "the drain did not present the note row: $(cat "$drain_out")"
  ack_drain_err "$state" "$drain_err" 2> "$ack_err" || fail "the acknowledgement failed: $(cat "$ack_err")"
  grep -F "inbox:$id" "$state/.wake-queue" >/dev/null \
    || fail "the acknowledgement consumed the wake of a note nobody read"
  tail -1 "$ack_err" | grep -F "NOT acknowledged - captain inbox note(s) still unread: $id" >/dev/null \
    || fail "the acknowledgement did not end by naming the unread note: $(cat "$ack_err")"

  # The kept row wakes the next cycle at once, not after the re-surface window.
  : > "$out"
  PATH="$dir/fakebin:$PATH" FM_WATCH_HANDLING_SUCCESSOR=1 FM_HOME="$dir" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 50 || fail "the kept note did not wake the next watcher cycle: $(cat "$out")"
  grep -F "captain inbox note: $id" "$out" >/dev/null \
    || fail "the next wake did not name the kept note: $(cat "$out")"

  # Read and acknowledged: the row is consumed and the note never wakes again.
  FM_HOME="$dir" "$ROOT/bin/fm-inbox.sh" drain --ack "$id" >/dev/null || fail "the note could not be acknowledged"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" || fail "the second drain failed"
  ack_drain_err "$state" "$drain_err" 2> "$ack_err" || fail "the second acknowledgement failed: $(cat "$ack_err")"
  grep -F "inbox:$id" "$state/.wake-queue" >/dev/null \
    && fail "the row of a read note survived its acknowledgement"
  grep -F "NOT acknowledged" "$ack_err" >/dev/null && fail "a read note was still reported unread: $(cat "$ack_err")"
  pass "a captain note's wake is not acknowledged until the note is read, and is surfaced again meanwhile"
}

# A note nobody acknowledges is surfaced again after FM_INBOX_RESURFACE_SECS, at
# most FM_INBOX_RESURFACE_MAX more times; after that fm-guard.sh reports it
# overdue instead of the watcher re-waking forever.
test_unread_inbox_note_resurfaces_a_bounded_number_of_times() {
  local dir state out pid id n
  dir=$(make_case inbox-resurface); state="$dir/state"
  dir=$(cd "$dir" && pwd -P)
  out="$dir/watch.out"
  id=$(FM_HOME="$dir" "$ROOT/bin/fm-inbox.sh" note "status please" 2>/dev/null | sed -n 's/^queued //p')
  [ -n "$id" ] || fail "the inbox note could not be queued"
  for n in 1 2 3; do
    : > "$out"
    PATH="$dir/fakebin:$PATH" FM_WATCH_HANDLING_SUCCESSOR=1 FM_HOME="$dir" \
      FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      FM_INBOX_RESURFACE_SECS=1 FM_INBOX_RESURFACE_MAX=1 "$WATCH" > "$out" &
    pid=$!
    if [ "$n" -lt 3 ]; then
      wait_for_exit "$pid" 50 || fail "surfacing $n of the unread note did not wake the watcher: $(cat "$out")"
      grep -F "captain inbox note: $id" "$out" >/dev/null || fail "surfacing $n did not name the note: $(cat "$out")"
      sleep 1.2
    else
      if ! wait_poll_cycle "$state" "$pid"; then
        grep -F "$id" "$out" >/dev/null && fail "the note woke the watcher past FM_INBOX_RESURFACE_MAX: $(cat "$out")"
      fi
      reap "$pid"
    fi
  done
  pass "an unread captain note re-surfaces a bounded number of times"
}

# bash parses the watcher loop once, so a changed bin/ tree otherwise leaves a
# live watcher on its start-time code. A changed bin/*.sh now re-execs the
# watcher in place: same pid, same lock, the arm still waiting on it, one watcher
# for the home, and the new loop live. A change that does not parse keeps the
# running code.
test_watcher_reloads_changed_code_in_place() {
  local dir state copy out pid arm lock_pid lock_owner count ref_mtime
  dir=$(make_case code-reload); state="$dir/state"
  dir=$(cd "$dir" && pwd -P)
  copy="$dir/fmroot"
  mkdir -p "$copy"
  rsync -a --exclude node_modules --exclude __pycache__ "$ROOT/bin" "$copy/" || fail "could not copy bin/"
  out="$dir/arm.out"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_CODE_SETTLE=0 \
    "$copy/bin/fm-watch-arm.sh" > "$out" 2>&1 &
  arm=$!
  for _ in $(seq 1 100); do grep -q '^watcher: started pid=' "$out" && break; sleep 0.1; done
  pid=$(sed -n 's/^watcher: started pid=\([0-9]*\).*/\1/p' "$out")
  [ -n "$pid" ] || { reap "$arm"; fail "the arm did not start a watcher: $(cat "$out")"; }
  lock_owner=$(readlink "$state/.watch.lock")
  [ -n "$lock_owner" ] || { reap "$arm"; fail "the watcher did not publish its singleton lock owner"; }

  # Change the code under the running watcher; the new image records itself.
  perl -0pi -e 's/^(WATCHER_PID=\$\{BASHPID:-\$\$\}\n)/$1echo "\$WATCHER_PID" > "\$STATE\/.test-reloaded"\n/m' \
    "$copy/bin/fm-watch.sh"
  ref_mtime=$(file_mtime "$state/.watch-code-ref")
  set_mtime "$((ref_mtime + 1))" "$copy/bin/fm-watch.sh"
  for _ in $(seq 1 100); do [ -s "$state/.test-reloaded" ] && break; sleep 0.1; done
  [ "$(cat "$state/.test-reloaded" 2>/dev/null)" = "$pid" ] \
    || { reap "$arm"; fail "the watcher did not re-exec in place after its code changed"; }
  is_live_non_zombie "$pid" || { reap "$arm"; fail "the reloaded watcher is not running"; }
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null)
  [ "$lock_pid" = "$pid" ] || { reap "$arm"; fail "the reload changed the lock holder ($lock_pid, not $pid)"; }
  [ "$(readlink "$state/.watch.lock")" = "$lock_owner" ] \
    || { reap "$arm"; fail "the reload replaced the singleton lock instead of adopting it"; }
  # Count watcher processes whose parent is not itself a watcher: bash
  # command-substitution subshells carry the same command line.
  count=$(ps -axo pid=,ppid=,command= | awk -v path="$copy/bin/fm-watch.sh" '
    { cmd = $0; sub(/^ *[0-9]+ +[0-9]+ +/, "", cmd) }
    cmd == "bash " path { pid[$1] = $2 }
    END { n = 0; for (p in pid) if (!(pid[p] in pid)) n++; print n }')
  [ "$count" = 1 ] || { reap "$arm"; fail "the reload left $count watchers for one home"; }
  grep -F "re-executing in place" "$state/.watch-triage.log" >/dev/null \
    || { reap "$arm"; fail "the reload was not logged"; }

  append_wake "$state" check startup-network "check: startup-network fixture after reload" \
    || { reap "$arm"; fail "the generic recovery row could not be queued"; }
  wait_for_exit "$arm" 100 || fail "the reloaded watcher's generic recovery wake did not end the arm: $(cat "$out")"
  grep -F "check: rearm-resurface" "$out" >/dev/null \
    || fail "the reloaded watcher did not relay the generic durable wake: $(cat "$out")"
  grep -F "startup-network fixture after reload" "$state/.wake-queue" >/dev/null \
    || fail "the generic recovery row was not durable after delivery"

  # A change that does not parse keeps the running code.
  rm -f "$state/.test-reloaded" "$state/.last-watcher-beat"
  : > "$out"
  PATH="$dir/fakebin:$PATH" FM_WATCH_HANDLING_SUCCESSOR=1 FM_HOME="$dir" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_CODE_SETTLE=0 \
    FM_INBOX_RESURFACE_SECS=999999 "$copy/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do [ -e "$state/.last-watcher-beat" ] && [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$pid" ] && break; sleep 0.1; done
  printf 'if then fi {\n' >> "$copy/bin/fm-watch.sh"
  for _ in $(seq 1 50); do grep -qF "does not parse" "$state/.watch-triage.log" && break; sleep 0.1; done
  grep -F "does not parse; kept the running code" "$state/.watch-triage.log" >/dev/null \
    || { reap "$pid"; fail "a change that does not parse was not refused: $(cat "$out"; tail -3 "$state/.watch-triage.log")"; }
  wait_poll_cycle "$state" "$pid" || fail "the watcher died on a change that does not parse: $(cat "$out")"
  reap "$pid"
  pass "a changed watcher re-execs in place: same pid and lock, one watcher, live loop"
}

test_watcher_reloads_code_changed_during_startup() {
  local dir state copy out startup_bin gate real_dirname pid i duplicate_out reloads orphan
  dir=$(make_case code-reload-during-startup); state="$dir/state"
  dir=$(cd "$dir" && pwd -P)
  copy="$dir/fmroot"
  startup_bin="$dir/startup-bin"
  gate="$dir/startup-gate"
  out="$dir/watch.out"
  duplicate_out="$dir/duplicate.out"
  real_dirname=$(command -v dirname)
  mkdir -p "$copy" "$startup_bin"
  rsync -a --exclude node_modules --exclude __pycache__ "$ROOT/bin" "$copy/" || fail "could not copy bin/"
  cat > "$startup_bin/dirname" <<'SH'
#!/usr/bin/env bash
if mkdir "${FM_TEST_STARTUP_GATE}.once" 2>/dev/null; then
  : > "${FM_TEST_STARTUP_GATE}.entered"
  i=0
  while [ ! -e "${FM_TEST_STARTUP_GATE}.release" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "${FM_TEST_STARTUP_GATE}.release" ] || exit 1
fi
exec "$FM_TEST_REAL_DIRNAME" "$@"
SH
  chmod +x "$startup_bin/dirname"

  PATH="$startup_bin:$dir/fakebin:$PATH" FM_TEST_STARTUP_GATE="$gate" FM_TEST_REAL_DIRNAME="$real_dirname" \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_HOME="$dir" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_WATCH_CODE_SETTLE=0 "$copy/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "${gate}.entered" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "${gate}.entered" ] || { reap "$pid"; fail "the watcher never reached the startup gate: $(cat "$out")"; }
  [ ! -e "$state/.watch.lock" ] && [ ! -L "$state/.watch.lock" ] \
    || { reap "$pid"; fail "the startup gate did not precede singleton-lock acquisition"; }
  orphan=$(find "$state" -maxdepth 1 -name '.watch-code-start-*' -print -quit)
  [ -z "$orphan" ] || { reap "$pid"; fail "the code-start reference was created before path resolution finished: $orphan"; }
  touch "$copy/bin/fm-inbox.sh"
  : > "${gate}.release"

  i=0
  while [ "$i" -lt 200 ]; do
    grep -F 're-executing in place' "$state/.watch-triage.log" >/dev/null 2>&1 \
      && [ -e "$state/.last-watcher-beat" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
    i=$((i + 1))
  done
  is_live_non_zombie "$pid" || { reap "$pid"; fail "the watcher exited instead of reloading its startup-overlapping change: $(cat "$out")"; }
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$pid" ] \
    || { reap "$pid"; fail "the startup-overlap reload did not retain pid $pid"; }
  reloads=$(grep -Fc 're-executing in place' "$state/.watch-triage.log" 2>/dev/null || true)
  [ "$reloads" -ge 1 ] || { reap "$pid"; fail "the startup-overlapping change caused no reload"; }

  PATH="$startup_bin:$dir/fakebin:$PATH" FM_TEST_STARTUP_GATE="$gate" FM_TEST_REAL_DIRNAME="$real_dirname" \
    FM_WATCH_HANDLING_SUCCESSOR=1 FM_HOME="$dir" "$copy/bin/fm-watch.sh" > "$duplicate_out" 2>&1 \
    || { reap "$pid"; fail "the duplicate watcher did not exit cleanly"; }
  orphan=$(find "$state" -maxdepth 1 -name '.watch-code-start-*' -print -quit)
  [ -z "$orphan" ] || { reap "$pid"; fail "an early watcher exit left its code-start reference: $orphan"; }
  reap "$pid"
  pass "a watcher reloads code changed during startup and cleans early-exit references"
}

test_watcher_waits_for_full_code_tree_to_settle() {
  local dir state copy out parse_bin gate real_bash pid i lock_pid
  dir=$(make_case code-reload-tree-settle); state="$dir/state"
  dir=$(cd "$dir" && pwd -P)
  copy="$dir/fmroot"
  parse_bin="$dir/parse-bin"
  gate="$dir/parse-gate"
  out="$dir/watch.out"
  real_bash=$(command -v bash)
  mkdir -p "$copy" "$parse_bin"
  rsync -a --exclude node_modules --exclude __pycache__ "$ROOT/bin" "$copy/" || fail "could not copy bin/"
  cat > "$parse_bin/bash" <<'SH'
#!/bin/sh
if [ "$1" = -n ] && [ "$2" = "$FM_TEST_WATCH_PATH" ] \
  && mkdir "${FM_TEST_PARSE_GATE}.once" 2>/dev/null; then
  : > "${FM_TEST_PARSE_GATE}.entered"
  i=0
  while [ ! -e "${FM_TEST_PARSE_GATE}.release" ] && [ "$i" -lt 200 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "${FM_TEST_PARSE_GATE}.release" ] || exit 1
  "$FM_TEST_REAL_BASH" "$@"
  rc=$?
  : > "${FM_TEST_PARSE_GATE}.parsed"
  exit "$rc"
fi
exec "$FM_TEST_REAL_BASH" "$@"
SH
  chmod +x "$parse_bin/bash"

  PATH="$parse_bin:$dir/fakebin:$PATH" FM_TEST_WATCH_PATH="$copy/bin/fm-watch.sh" \
    FM_TEST_PARSE_GATE="$gate" FM_TEST_REAL_BASH="$real_bash" FM_WATCH_HANDLING_SUCCESSOR=1 \
    FM_HOME="$dir" FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WATCH_CODE_SETTLE=1 \
    "$real_bash" "$copy/bin/fm-watch.sh" > "$out" 2>&1 &
  pid=$!
  for _ in $(seq 1 100); do
    [ -e "$state/.last-watcher-beat" ] && [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$pid" ] && break
    sleep 0.1
  done
  [ "$(cat "$state/.watch.lock/pid" 2>/dev/null)" = "$pid" ] \
    || { reap "$pid"; fail "the settle fixture watcher did not acquire its lock: $(cat "$out")"; }

  perl -0pi -e 's/^(WATCHER_PID=\$\{BASHPID:-\$\$\}\n)/$1echo "\$WATCHER_PID" > "\$STATE\/\.test-reloaded"\n/m' \
    "$copy/bin/fm-watch.sh"
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "${gate}.entered" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "${gate}.entered" ] || { reap "$pid"; fail "the watcher never reached its pre-exec parse gate: $(cat "$out")"; }
  printf '\n' >> "$copy/bin/fm-inbox.sh"
  : > "${gate}.release"
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "${gate}.parsed" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "${gate}.parsed" ] || { reap "$pid"; fail "the watcher never completed its gated parse"; }

  i=0
  while [ "$i" -lt 15 ]; do
    printf '\n' >> "$copy/bin/fm-inbox.sh"
    sleep 0.1
    ! grep -F 're-executing in place' "$state/.watch-triage.log" >/dev/null 2>&1 \
      || { reap "$pid"; fail "the watcher re-executed while the shell tree was still changing"; }
    i=$((i + 1))
  done

  i=0
  while [ "$i" -lt 100 ]; do
    [ -s "$state/.test-reloaded" ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ "$(cat "$state/.test-reloaded" 2>/dev/null)" = "$pid" ] \
    || { reap "$pid"; fail "the watcher did not reload after the full shell tree settled: $(cat "$out")"; }
  lock_pid=$(cat "$state/.watch.lock/pid" 2>/dev/null)
  if [ "$lock_pid" != "$pid" ] || ! is_live_non_zombie "$pid"; then
    reap "$pid"
    fail "the settled reload did not retain its live watcher and lock"
  fi
  reap "$pid"
  pass "a watcher reloads only after the full shell tree remains unchanged"
}

test_procevent_unacknowledged_result_redrains_until_handled() {
  local dir state out replay_out replay_err pid before after sequence generation
  dir=$(make_case procevent-redrain); state="$dir/state"
  out="$dir/watch.out"; replay_out="$dir/replay.out"; replay_err="$dir/replay.err"
  seed_captured_procevent_result "$dir" || fail "the fixture captured no process-event result"

  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "the first proactive wake never happened: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "drain after the first process-event wake failed"

  # An interrupted handler leaves the captured result durable. The successor
  # must re-surface it through recovery, then its drain must print the same row.
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an unacknowledged process-event result was not re-surfaced on re-arm: $(cat "$out")"
  grep -F 'check: rearm-resurface' "$out" >/dev/null \
    || fail "the successor did not report recovery for the unacknowledged result: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" 2> "$replay_err" \
    || fail "the successor could not re-drain the unacknowledged process-event result"
  grep "$(printf '\tcheck\t')" "$replay_out" | grep -F 'procevent lavish delivery-src 1' >/dev/null \
    || fail "the successor drain did not re-print the durable process-event row"

  pe_case "$dir" handled delivery-src 1 >/dev/null || fail "could not acknowledge the captured result"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "the replay drain omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "completed process-event handling could not acknowledge the replay"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged process-event replay remained durable"

  before=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  : > "$out"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    fail "a handled process-event result woke the watcher: $(cat "$out")"
  fi
  reap "$pid"
  after=$(awk 'END { print NR + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$after" = "$before" ] || fail "a handled result was announced again ($before -> $after queued records)"
  pass "an unacknowledged process-event result re-drains until handling is acknowledged"
}

test_procevent_marker_keys_are_injective() {
  local dir state out pid marker_count
  dir=$(make_case procevent-marker-identity); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:a.b:1" "check: procevent fixture a.b 1"
  append_wake "$state" check "procevent:a_b:1" "check: procevent fixture a_b 1"
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "colliding-looking process-event keys were not surfaced"
  grep -F "procevent:a.b:1" "$out" >/dev/null || fail "the dotted queue key was suppressed"
  grep -F "procevent:a_b:1" "$out" >/dev/null || fail "the underscored queue key was suppressed"
  marker_count=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | awk 'END { print NR + 0 }')
  [ "$marker_count" = 2 ] || fail "distinct queue keys produced $marker_count seen markers"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker identity fixture drain failed"
  pass "complete process-event queue keys map to distinct seen markers"
}

# The reason line is the headline firstmate reads before the payload. Every
# procevent:* key used to surface as "process-event result captured", which
# presents a source that is collecting NOTHING as a healthy capture - the exact
# shape of the incident these wakes exist to expose. These assertions read the
# reason the watcher actually printed, so a typo in either classifying glob
# fails here instead of silently falling back to the healthy-looking headline.
surface_once() {  # <dir> <out> [limit-ticks]: run one watcher to its wake, return its status
  local dir=$1 out=$2 limit=${3:-100} pid
  procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" "$limit"
}

test_procevent_headlines_classify_queue_keys() {
  local dir state out
  dir=$(make_case procevent-headline-captured); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:cap-src:1" "check: procevent lavish cap-src 1"
  surface_once "$dir" "$out" || fail "a captured-result key was not surfaced: $(cat "$out")"
  grep -F "check: process-event result captured: procevent:cap-src:1" "$out" >/dev/null \
    || fail "a captured result did not surface under its own headline: $(cat "$out")"
  ! grep -F "source stranded" "$out" >/dev/null \
    || fail "a captured result was headlined as a strand: $(cat "$out")"
  ! grep -F "failed to start" "$out" >/dev/null \
    || fail "a captured result was headlined as a failed start: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "captured headline fixture drain failed"

  dir=$(make_case procevent-headline-stranded); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:str-src:stranded:tok-1" "check: process-event source str-src is registered but nothing can arm it"
  surface_once "$dir" "$out" || fail "a stranded key was not surfaced: $(cat "$out")"
  grep -F "check: process-event source stranded: procevent:str-src:stranded:tok-1" "$out" >/dev/null \
    || fail "a stranded source did not surface under its own headline: $(cat "$out")"
  ! grep -F "result captured" "$out" >/dev/null \
    || fail "a stranded source was headlined as a captured result: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "stranded headline fixture drain failed"

  dir=$(make_case procevent-headline-joined); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:cap2-src:1" "check: procevent lavish cap2-src 1"
  append_wake "$state" check "procevent:str2-src:stranded:tok-2" "check: process-event source str2-src is registered but nothing can arm it"
  surface_once "$dir" "$out" || fail "a mixed cycle was not surfaced: $(cat "$out")"
  grep -F "check: process-event result captured: procevent:cap2-src:1; process-event source stranded: procevent:str2-src:stranded:tok-2" "$out" >/dev/null \
    || fail "a cycle with a capture and a strand did not carry both headlines joined: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "joined headline fixture drain failed"
  pass "process-event queue keys surface under their own headlines"
}

# Delivery, not queue rows, is what proves a launch-failure episode reaches
# firstmate. The watcher remembers every procevent key it has surfaced for
# good, so reconcile keys each episode with a fresh suffix beyond the
# registration identity: this test would fail if a second episode reused the
# first one's key, because the watcher would keep polling and never wake.
test_procevent_launch_failed_episodes_are_each_delivered() {
  local dir state out status
  dir=$(make_case procevent-launch-failed-episodes); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:lf-src:launch-failed:1-2-100-7" \
    "check: process-event source lf-src is registered but its launch did not prove it took the claim"
  surface_once "$dir" "$out" || fail "a launch-failed key was not surfaced: $(cat "$out")"
  grep -F "check: process-event source failed to start: procevent:lf-src:launch-failed:1-2-100-7" "$out" >/dev/null \
    || fail "a failed launch did not surface under its own headline: $(cat "$out")"
  ! grep -F "result captured" "$out" >/dev/null \
    || fail "a failed launch was headlined as a captured result: $(cat "$out")"
  ack_stopped_cycle "$state" >/dev/null || fail "launch-failed fixture could not be handled and acknowledged"

  # The same key again is what a registration-identity-only key would produce
  # for the next episode: already surfaced, so the process-event surface never
  # delivers it under its headline again. A fresh watcher still recovers the
  # unacknowledged queue row through the generic `check: rearm-resurface`
  # path (the contract test_procevent_unacknowledged_result_redrains_until_handled
  # proves), so what this asserts is the headline, not silence.
  append_wake "$state" check "procevent:lf-src:launch-failed:1-2-100-7" \
    "check: process-event source lf-src is registered but its launch did not prove it took the claim"
  : > "$out"
  status=0
  surface_once "$dir" "$out" 30 || status=$?
  case "$status" in
    124) ;;
    0)
      # The one wake this tolerates is the recovery path named above, by its
      # exact reason line. A wake for any other reason would mean either that
      # the ordinary surface delivered the repeated key after all, or that
      # something unrelated fired inside the window - and both are failures of
      # exactly what this test guards, so neither may pass as "recovery".
      grep -F 'check: rearm-resurface' "$out" >/dev/null \
        || fail "an already-surfaced launch-failed key woke the watcher, and the reason was not the one tolerated recovery path (expected the exact line 'check: rearm-resurface'; if that path was reworded, update this expectation, do not restore the strict silence check): $(cat "$out")"
      ;;
    *) fail "the watcher failed on an already-surfaced launch-failed key (status $status): $(cat "$out")" ;;
  esac
  ! grep -F "failed to start: procevent:lf-src:launch-failed:1-2-100-7" "$out" >/dev/null \
    || fail "an already-surfaced launch-failed key was delivered again under its headline: $(cat "$out")"
  ack_stopped_cycle "$state" >/dev/null || fail "repeated-key fixture could not be handled and acknowledged"

  # A later episode of the same registration carries the same identity under a
  # fresh suffix, and that one must be delivered.
  append_wake "$state" check "procevent:lf-src:launch-failed:1-2-160-9" \
    "check: process-event source lf-src is registered but its launch did not prove it took the claim"
  : > "$out"
  surface_once "$dir" "$out" || fail "a second launch-failure episode was not surfaced: $(cat "$out")"
  grep -F "check: process-event source failed to start: procevent:lf-src:launch-failed:1-2-160-9" "$out" >/dev/null \
    || fail "a second launch-failure episode did not surface under its own headline: $(cat "$out")"
  ack_stopped_cycle "$state" >/dev/null || fail "second episode fixture could not be handled and acknowledged"
  pass "every launch-failure episode is delivered under the failed-to-start headline"
}

install_marker_mv_fault() {  # <dir>
  local dir=$1
  REAL_MV=$(command -v mv)
  export REAL_MV
  cat > "$dir/fakebin/mv" <<'SH'
#!/usr/bin/env bash
dest=${!#}
case "$dest" in
  */.seen-procevent-*)
    case "${FM_MARKER_MV_MODE:-}" in
      pause)
        printf '1\n' > "$FM_MARKER_MV_READY"
        while [ ! -e "$FM_MARKER_MV_RELEASE" ]; do sleep 0.02; done
        ;;
      kill-before) kill -KILL "$PPID"; exit 1 ;;
      kill-after) "$REAL_MV" "$@" || exit; kill -KILL "$PPID"; exit 1 ;;
      fail) exit 1 ;;
    esac
    ;;
esac
exec "$REAL_MV" "$@"
SH
  chmod +x "$dir/fakebin/mv"
}

test_procevent_surface_serializes_with_drain() {
  local dir state out drain_out ready release pid drain_pid
  dir=$(make_case procevent-drain-race); state="$dir/state"; out="$dir/watch.out"
  drain_out="$dir/drain.out"; ready="$dir/marker-ready"; release="$dir/marker-release"
  append_wake "$state" check "procevent:drain-race:1" "check: procevent fixture drain-race 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=pause FM_MARKER_MV_READY="$ready" FM_MARKER_MV_RELEASE="$release" \
    procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_numeric_file "$ready" 100 || fail "the watcher never reached its marker commit boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" &
  drain_pid=$!
  wait_live "$drain_pid" 10 || fail "a concurrent drain split the surfacing transition"
  [ -s "$state/.wake-queue" ] || fail "the concurrent drain consumed the record before marker commit"
  touch "$release"
  wait "$pid" || fail "the paused watcher did not finish surfacing"
  wait "$drain_pid" || fail "the concurrent drain failed after surfacing committed"
  grep -F "procevent:drain-race:1" "$drain_out" >/dev/null \
    || fail "the serialized drain lost the process-event record"
  pass "queue revalidation, proactive output, and marker commit serialize with drain"
}

test_procevent_surface_crash_boundaries() {
  local dir state out fifo pid reader marker exit_status replay_err sequence generation
  dir=$(make_case procevent-output-fail); state="$dir/state"; out="$dir/watch.out"; fifo="$dir/output.fifo"
  append_wake "$state" check "procevent:output-fail:1" "check: procevent fixture output-fail 1"
  mkfifo "$fifo"
  sh -c ': < "$1"' _ "$fifo" & reader=$!
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_PROCEVENT_CLAIM_ROOT="$dir/claims" \
    FM_CREW_STATE_BIN="$dir/fakebin/fm-crew-state.sh" FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$fifo" &
  pid=$!
  wait "$reader" || true
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived a failed actionable output write"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "failed output committed a suppression marker"
  [ -s "$state/.wake-queue" ] || fail "failed output consumed the durable queue record"
  procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100 || fail "the record was not replayable after output failure"
  grep -F "procevent:output-fail:1" "$out" >/dev/null || fail "output failure lost proactive replay"

  dir=$(make_case procevent-before-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:before-marker:1" "check: procevent fixture before-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-before procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected pre-marker crash"
  grep -F "procevent:before-marker:1" "$out" >/dev/null || fail "the pre-marker crash happened before output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "a pre-marker crash committed suppression"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 || fail "a pre-marker crash was not replayable"

  dir=$(make_case procevent-after-marker); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:after-marker:1" "check: procevent fixture after-marker 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=kill-after procevent_watch_bg "$dir" "$out"; pid=$!
  wait_for_exit "$pid" 100
  exit_status=$?
  [ "$exit_status" -ne 124 ] || fail "the watcher survived the injected post-marker crash"
  grep -F "procevent:after-marker:1" "$out" >/dev/null || fail "the post-marker crash lost actionable output"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -n "$marker" ] || fail "the post-marker crash did not reach marker commit"
  : > "$out.replay"
  procevent_watch_bg "$dir" "$out.replay"; pid=$!
  wait_for_exit "$pid" 100 \
    || fail "an unacknowledged delivered record was not re-surfaced on re-arm: $(cat "$out.replay")"
  grep -F 'check: rearm-resurface' "$out.replay" >/dev/null \
    || fail "the successor did not recover the delivered-but-unacknowledged record: $(cat "$out.replay")"
  replay_err="$out.replay.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out.replay.drain" 2> "$replay_err" \
    || fail "post-marker successor drain failed"
  grep "$(printf '\tcheck\t')" "$out.replay.drain" | grep -F 'procevent fixture after-marker 1' >/dev/null \
    || fail "post-marker successor did not re-drain the durable record"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "post-marker replay omitted its post-handling acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "post-marker replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "post-marker acknowledgement left the durable record queued"
  pass "surfacing failures replay until post-handling acknowledgement"
}

test_procevent_marker_failure_exits_and_replays() {
  local dir state out pid marker output_count
  dir=$(make_case procevent-marker-failure); state="$dir/state"; out="$dir/watch.out"
  append_wake "$state" check "procevent:marker-failure:1" "check: procevent fixture marker-failure 1"
  install_marker_mv_fault "$dir"
  FM_MARKER_MV_MODE=fail procevent_watch_bg "$dir" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not end the actionable watcher cycle successfully"
  output_count=$(grep -Fc "procevent:marker-failure:1" "$out" || true)
  [ "$output_count" = 1 ] || fail "marker failure printed the actionable reason $output_count times"
  marker=$(find "$state" -maxdepth 1 -name '.seen-procevent-*' -type f | head -1)
  [ -z "$marker" ] || fail "marker failure committed suppression"
  [ ! -e "$state/.wake-queue.lock" ] && [ ! -L "$state/.wake-queue.lock" ] \
    || fail "marker failure left the queue lock held"
  procevent_watch_bg "$dir" "$out.replay"
  pid=$!
  wait_for_exit "$pid" 100 || fail "marker failure did not leave the durable record replayable"
  grep -F "procevent:marker-failure:1" "$out.replay" >/dev/null \
    || fail "marker failure lost the later proactive replay"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2>&1 || fail "marker-failure fixture drain failed"
  pass "marker failure exits through the shared wake owner, releases its lock, and replays later"
}

# --- heartbeat: no-change absorbed, backstop surfaces a missed status --------

test_heartbeat_no_change_absorbed() {
  local dir state fakebin out pid i sig
  dir=$(make_case heartbeat-absorb); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'working: routine heartbeat history\n' > "$state/routine.status"
  sig=$(seen_sig "$state/routine.status"); printf '%s' "$sig" > "$state/.seen-routine_status"
  # A quiet fleet with a fast heartbeat cadence.
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a no-change heartbeat (should absorb): $(cat "$out")"
  fi
  # The heartbeat fires on the first poll whose .last-heartbeat has aged past
  # FM_HEARTBEAT, which need not be the first completed cycle, so wait for the
  # absorbed heartbeat itself rather than assuming one cycle produced it.
  i=0
  while [ "$i" -lt 200 ]; do
    [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] && break
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    i=$((i + 1))
  done
  [ ! -s "$out" ] || fail "no-change heartbeat printed a wake reason: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "no-change heartbeat enqueued a durable wake record"
  [ "$(cat "$state/.heartbeat-streak" 2>/dev/null || echo 0)" -ge 1 ] || fail "heartbeat backoff streak did not advance while absorbing"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-routine" "$state/routine.status")" = \
    "$(size_of "$state/routine.status")" ] \
    || fail "routine heartbeat classification did not commit its captured endpoint"
  reap "$pid"
  pass "a heartbeat with no captain-relevant change is absorbed and backs off the cadence"
}

test_heartbeat_backstop_surfaces_a_masked_status() {
  local dir state fakebin out sig pid
  dir=$(make_case heartbeat-masked); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"
  # Same miss as below, but the captain-relevant event is followed by a routine
  # append, so its last line reads benign. The backstop must still catch it.
  printf 'working: setup\nneeds-decision: pick A or B\nworking: tidying the branch\n' \
    > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 \
    || fail "heartbeat backstop missed a decision hidden behind a later working: line"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-miss" "$state/miss.status")" = \
    "$(size_of "$state/miss.status")" ] \
    || fail "backstop did not record the masked status as surfaced through its end"
  pass "the heartbeat backstop surfaces a captain event hidden behind a later routine append"
}

test_heartbeat_backstop_surfaces_unsurfaced_status() {
  local dir state fakebin out drain_out sig pid
  dir=$(make_case heartbeat-backstop); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  # A captain-relevant status whose .seen-* signature ALREADY matches (so the
  # per-poll signal scan stays quiet) but which was never surfaced (no
  # .hb-surfaced-* marker). This stands in for a per-wake-path miss; the heartbeat
  # fleet-scan backstop must catch it and wake firstmate.
  printf 'done: PR https://example.test/pr/5\n' > "$state/miss.status"
  sig=$(seen_sig "$state/miss.status"); printf '%s' "$sig" > "$state/.seen-miss_status"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "heartbeat backstop did not surface an unsurfaced captain-relevant status"
  grep -Fx "heartbeat" "$out" >/dev/null || fail "backstop did not exit with a heartbeat wake"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-miss" "$state/miss.status")" = \
    "$(size_of "$state/miss.status")" ] \
    || fail "backstop did not record the status as surfaced through its end (would re-fire next heartbeat)"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the backstop heartbeat failed"
  grep "$(printf '\theartbeat\t')" "$drain_out" >/dev/null || fail "backstop heartbeat was not queued"
  pass "heartbeat backstop fail-safe surfaces a captain-relevant status the per-wake path missed"
}

# --- beacon stays fresh while absorbing -------------------------------------

test_beacon_stays_fresh_while_absorbing() {
  local dir state fakebin out status_file pid m1 m2 now
  dir=$(make_case beacon-fresh); state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  status_file="$state/task.status"
  printf 'working: a\n' > "$status_file"
  # Provably working so the working: notes are absorbed (the path that must keep the
  # beacon fresh).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  # Wait on the beacon itself rather than a fixed liveness budget: the watcher's
  # bounded startup can outlast a short wait, and reading an absent beacon would
  # report a missing beacon that simply had not been written yet.
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher exited while absorbing the first benign signal"; }
  m1=$(file_mtime "$state/.last-watcher-beat")
  # A second benign signal keeps it absorbing; the beacon must keep advancing.
  printf 'working: b\n' >> "$status_file"
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "watcher exited while absorbing a second benign signal"; }
  m2=$(file_mtime "$state/.last-watcher-beat")
  now=$(date +%s)
  if [ -z "$m1" ] || [ -z "$m2" ]; then
    reap "$pid"
    fail "watcher beacon missing while absorbing"
  fi
  [ "$m2" -ge "$m1" ] || { reap "$pid"; fail "beacon mtime regressed while absorbing"; }
  [ "$(( now - m2 ))" -lt 10 ] || { reap "$pid"; fail "beacon went stale while absorbing (age $(( now - m2 ))s)"; }
  [ ! -s "$state/.wake-queue" ] || { reap "$pid"; fail "absorbing benign signals enqueued a wake"; }
  reap "$pid"
  pass "the liveness beacon stays fresh while the watcher absorbs benign wakes (fm-guard never false-alarms)"
}

# --- afk coherence: the daemon owns triage; the watcher does not double-triage ---

test_afk_signal_records_heartbeat_endpoint() {
  local dir state fakebin out status_file pid
  dir=$(make_case afk-heartbeat-endpoint); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; status_file="$state/task.status"
  printf 'needs-decision: choose release target\nworking: preparing both targets\n' > "$status_file"
  date '+%s' > "$state/.afk"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "afk watcher did not hand the actionable signal to the daemon"
  [ "$(status_presentation_marker_offset "$state/.hb-surfaced-task" "$status_file")" = \
    "$(size_of "$status_file")" ] \
    || fail "afk signal did not record the endpoint handed to the daemon"
  unset FM_FAKE_CREW_STATE
  pass "an afk signal records its captured heartbeat endpoint"
}

test_afk_present_reverts_watcher_to_one_shot() {
  local dir state fakebin out drain_out status_file pid
  dir=$(make_case afk-coherence); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"
  status_file="$state/task.status"
  printf 'working: routine note\n' > "$status_file"
  date '+%s' > "$state/.afk"   # away mode: the supervise-daemon owns triage
  # Set a PROVABLY-WORKING verdict: if afk failed to bypass the provably-working
  # check, this no-verb signal would be absorbed (not surfaced). The test asserting
  # a surface therefore also proves afk reverts to one-shot and skips the costly read.
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'
  watch_bg "$state" "$fakebin" "$out"
  pid=$!
  wait_for_exit "$pid" 100 || fail "with .afk present the watcher did not exit one-shot for a benign signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "afk-mode watcher did not surface the signal for the daemon"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the afk-mode signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null \
    || fail "afk-mode benign signal was not queued for the daemon to classify"
  pass "with .afk present the watcher reverts to one-shot so the daemon owns triage (no double-triage)"
}

# A paused pane can first appear as a changed hash. In AFK mode that initial path
# must still hand off the plain window identity to the daemon, rather than running
# the normal-mode pause re-surface and decorating the stale identity.
test_afk_paused_changed_pane_hands_off_plain_stale() {
  local dir state fakebin out drain_out capture_file statusf window key sig pid back
  dir=$(make_case afk-paused-changed-pane); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window="test:fm-afk-held"
  printf 'idle, awaiting upstream\n' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/afk-held.meta"
  statusf="$state/afk-held.status"
  printf 'paused: awaiting the upstream tool release\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-held_status"
  date '+%s' > "$state/.afk"
  key=$(printf '%s' "$window" | tr '.:/' '___')

  # Deliberately do not seed .hash-*: this is the changed-pane path that used to
  # call handle_paused_stale before AFK's one-shot daemon handoff.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · awaiting the upstream tool release' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "AFK paused changed pane did not hand off a stale wake"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "AFK paused stale did not preserve its plain window identity: $(cat "$out")"
  grep -F "awaiting external" "$out" >/dev/null && fail "AFK watcher decorated a stale identity instead of handing it to the daemon"
  [ ! -e "$state/.paused-$key" ] || fail "AFK watcher recorded normal-mode pause tracking instead of handing off"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after AFK paused stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "stale: $window" >/dev/null \
    || fail "AFK paused stale was not queued with the plain window identity"
  pass "AFK changed paused panes hand off plain stale identities for daemon-owned pause triage"
}

write_away_record() {  # <state>
  if ! FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" "$ROOT/bin/fm-afk-contract.sh" propose >/dev/null 2>&1 \
    || ! FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" "$ROOT/bin/fm-afk-contract.sh" confirm >/dev/null 2>&1; then
    fail "could not write the away-posture record in $1"
  fi
}

archive_away_record() {  # <state>
  FM_HOME="$(dirname "$1")" FM_STATE_OVERRIDE="$1" "$ROOT/bin/fm-afk-contract.sh" archive >/dev/null 2>&1 \
    || fail "could not archive the away-posture record in $1"
}

test_captain_held_never_rechecked_while_away_record_exists() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back
  dir=$(make_case away-record-held-secondmate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/secondmate-hold.status"
  window="test:fm-secondmate-hold"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=secondmate\n' "$window" > "$state/secondmate-hold.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-secondmate-hold_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  pane_hash=$(hash_text "idle awaiting the captain")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  write_away_record "$state"
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  # Phase A: the record exists, the hold is well past the cadence, and the
  # watcher still absorbs it across whole poll cycles: no wake, no throttle.
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher rechecked a captain-held item while the away-posture record exists: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a captain-held recheck was printed while the away-posture record exists"
  [ ! -s "$state/.wake-queue" ] || fail "a captain-held recheck was queued while the away-posture record exists"
  [ ! -e "$state/.paused-resurfaced-$key" ] || fail "the recheck throttle was armed for an item that must never be rechecked"
  grep -F 'never rechecked while the away-posture record exists' "$state/.watch-triage.log" >/dev/null \
    || fail "the silent absorb did not name the away-posture rule in the triage log"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A stop"
  # Phase B: archiving the record (the return) restores the bounded recheck.
  archive_away_record "$state"
  : > "$out"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "archiving the away-posture record did not restore the captain-held recheck"; }
  grep -F "awaiting the captain" "$out" >/dev/null || fail "the restored recheck did not name the captain: $(cat "$out")"
  unset FM_FAKE_CREW_STATE
  pass "a captain-held item is never rechecked while the away-posture record exists, and the recheck returns once the record is archived"
}

test_live_captain_held_first_sight_silenced_by_away_record() {
  local dir state fakebin out capture_file statusf window key sig pid
  dir=$(make_case away-record-held-live); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held-live.status"
  window="test:fm-held-live"
  printf 'parked at the decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held-live.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held-live_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  write_away_record "$state"
  # A LIVE agent at the gate: without the record pause_state_class answers none
  # and the first sight surfaces (test_exited_declared_pause_is_bounded_but_live_gate_surfaces).
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=grok \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a live captain-held pane surfaced on first sight while the away-posture record exists: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "a live captain-held pane was queued while the away-posture record exists"
  [ -e "$state/.stale-$key" ] || fail "the silenced first sight did not advance the stale suppressor"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a live captain-held pane is absorbed on first sight while the away-posture record exists"
}

test_backlog_hold_never_rechecked_while_away_record_exists() {
  local dir out capture wakes
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo "skip: tasks-axi not found (away-record backlog hold)"; return 0; }
  dir=$(make_hold_home away-record-backlog-hold 'done: PR https://example.test/pr/9 checks green' hold) \
    || fail "could not build the backlog-hold fixture"
  out="$dir/watch.out"; capture="$dir/pane.txt"
  write_away_record "$dir/state"
  # Without the record the FIRST sight of a held delivery alarms
  # (test_stale_churn_without_a_captain_call_still_alarms and its siblings). With
  # it, even the first sight and every later hash are absorbed.
  hold_watch_churn "$dir" "$out" "$capture" 'held delivery, pane tick' 3 \
    || fail "watcher exited while churning a backlog-held delivery under the away-posture record: $(cat "$out")"
  wakes=$(hold_stale_wakes "$dir/state")
  [ "$wakes" -eq 0 ] || fail "a backlog-held delivery was rechecked $wakes time(s) while the away-posture record exists"
  pass "a delivery the captain already holds is never rechecked while the away-posture record exists"
}

test_afk_one_shot_never_hands_off_captain_held_under_away_record() {
  local dir state fakebin out capture_file statusf window key sig pid
  dir=$(make_case away-record-held-afk-oneshot); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held-afk.status"
  window="test:fm-held-afk"
  printf 'idle awaiting the captain\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=tmux\n' "$window" > "$state/held-afk.meta"
  printf 'captain-held [key=route]: tracked by task-decision-route\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held-afk_status"
  key=$(printf '%s' "$window" | tr '.:/' '___')
  date '+%s' > "$state/.afk"
  write_away_record "$state"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_FAKE_TMUX_CURRENT_COMMAND=zsh \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid" || ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the daemon-owned one-shot handed off a captain-held pane while the away-posture record exists: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "the daemon-owned one-shot queued a captain-held pane while the away-posture record exists"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$(hash_text 'idle awaiting the captain')" ] \
    || fail "the silenced one-shot did not advance the stale suppressor to the pane hash"
  reap "$pid"
  pass "the daemon-owned one-shot never hands off a captain-held pane while the away-posture record exists"
}

test_triage_log_size_cap_accepts_spaced_wc_counts
test_procevent_captured_result_surfaces_proactively
test_inbox_note_wakes_the_watcher_promptly
test_unread_inbox_note_survives_acknowledgement
test_unread_inbox_note_resurfaces_a_bounded_number_of_times
test_watcher_reloads_changed_code_in_place
test_watcher_reloads_code_changed_during_startup
test_watcher_waits_for_full_code_tree_to_settle
test_procevent_unacknowledged_result_redrains_until_handled
test_procevent_marker_keys_are_injective
test_procevent_headlines_classify_queue_keys
test_procevent_launch_failed_episodes_are_each_delivered
test_procevent_surface_serializes_with_drain
test_procevent_surface_crash_boundaries
test_procevent_marker_failure_exits_and_replays
test_heartbeat_no_change_absorbed
test_heartbeat_backstop_surfaces_unsurfaced_status
test_heartbeat_backstop_surfaces_a_masked_status
test_beacon_stays_fresh_while_absorbing
test_afk_signal_records_heartbeat_endpoint
test_afk_present_reverts_watcher_to_one_shot
test_afk_paused_changed_pane_hands_off_plain_stale
test_captain_held_never_rechecked_while_away_record_exists
test_live_captain_held_first_sight_silenced_by_away_record
test_backlog_hold_never_rechecked_while_away_record_exists
test_afk_one_shot_never_hands_off_captain_held_under_away_record
