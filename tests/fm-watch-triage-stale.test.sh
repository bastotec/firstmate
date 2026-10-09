#!/usr/bin/env bash
# tests/fm-watch-triage-stale.test.sh - wake triage, part 2: stale panes.
# Terminal and non-terminal stale wakes, wedge escalation, busy-turn age bounds,
# and declared pauses on busy panes.
# Shared fixtures and the suite overview: tests/watch-triage-helpers.sh.
set -u

# shellcheck source=tests/watch-triage-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/watch-triage-helpers.sh"

# Prime <file>'s .seen-* suppressor to its CURRENT signature, so the per-poll
# no-verb signal scan (which watches every *.turn-ended for a size:mtime change)
# treats a just-created or just-backdated turn-ended marker as already seen.
# Busy-turn-age fixtures create/backdate turn-ended directly (there is no real
# harness touching it), so without this the marker's own first sighting would
# fire an unrelated "signal:" wake and mask the busy-turn-age assertion under
# test. Call again after any further touch/set_mtime on the same file.
prime_turnend_seen() {  # <file>
  local f=$1 base
  base=$(basename "$f" | tr '.' '_')
  printf '%s' "$(seen_sig "$f")" > "$(dirname "$f")/.seen-$base"
}

test_terminal_stale_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" "done")
  printf 'finished, awaiting review' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$window" > "$state/done.meta"
  printf 'done: PR https://example.test/pr/3\n' > "$state/done.status"
  sig=$(seen_sig "$state/done.status"); printf '%s' "$sig" > "$state/.seen-done_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "finished, awaiting review")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not exit for a stale pane on a terminal status"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the terminal stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the terminal stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "terminal stale was not queued"
  pass "a stale pane sitting on a terminal status is surfaced (queue + exit)"
}

# --- stale pane, STALE terminal status overridden by an active run: absorbed ---
# Regression for the 2026-07 herdr false-surface incidents: a crew's own status
# log gets no new entry once firstmate hands it to a no-mistakes validation
# (AGENTS.md's sparse status-reporting contract), so the log keeps showing its
# pre-validation "done:" line as the LAST line for the run's entire (possibly
# many-minutes) duration. stale_is_terminal alone has no run-step awareness and
# would treat that leftover as still-current every time the pane goes quiet,
# immediately surfacing a crew that is actively validating. crew_is_provably_working
# must get a chance to override a captain-relevant-but-stale status line, exactly
# as it already does for a plain non-terminal one.
test_stale_terminal_status_overridden_by_active_run() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-overridden); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" validating)
  printf 'no-mistakes axi run: validating...' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$window" > "$state/validating.meta"
  # The crew reported done BEFORE firstmate triggered no-mistakes validation;
  # this line never gets superseded by a newer status-log entry while the
  # pipeline itself runs.
  printf 'done: implementation complete, ready to validate\n' > "$state/validating.status"
  sig=$(seen_sig "$state/validating.status"); printf '%s' "$sig" > "$state/.seen-validating_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "no-mistakes axi run: validating...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Phase A: a high escalation threshold means the first sighting is absorbed,
  # not surfaced, despite the captain-relevant "done:" status-log line.
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a stale terminal-looking status the run-step overrides (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the overridden stale terminal status printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "the overridden stale terminal status enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  [ ! -e "$state/.hb-surfaced-validating" ] || fail "an absorbed wake must not mark the status line as surfaced"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: backdate the idle timer past the threshold; the run genuinely
  # wedges and the next poll escalates exactly like the non-terminal case.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not escalate an overridden stale terminal status past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  unset FM_FAKE_CREW_STATE
  pass "a stale terminal-looking status is overridden and absorbed while a run is actively working, then wedge-escalated"
}

# --- possible-wedge alarm, wake gate enforcing: evidence decides the model turn ---
# bin/fm-wake-gate.sh stale-verdict owns the rule and its own tests; this pins the
# watcher side: an absorb verdict queues nothing and restarts the idle window, any
# other verdict alarms exactly as before, and the gate's model look is recorded
# only after the alarm is queued. Stub helper and evidence only.
test_wedge_alarm_honors_the_wake_gate_verdict() {
  local dir state fakebin out capture_file window key pid stub evid before
  dir=$(make_case wedge-wake-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=$(stream_window "$state" gated)
  stub="$dir/gate-stub"; evid="$dir/gate-evidence"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf 'usage\t1\t10\t0\t5\nanswers\t%s\n' "$FM_TEST_ANSWERS"
SH
  printf '#!/usr/bin/env bash\necho "state: working (run-step: ci running)"\n' > "$evid"
  chmod +x "$stub" "$evid"
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$window" > "$state/gated.meta"
  printf 'working: still compiling\n' > "$state/gated.status"
  printf '%s' "$(seen_sig "$state/gated.status")" > "$state/.seen-gated_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  printf '%s' "$(hash_text "idle building output")" > "$state/.hash-$key"
  printf '%s' "$(hash_text "idle building output")" > "$state/.stale-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'
  mkdir -p "$dir/config" "$state/wake-gate"
  printf 'DUMMY_KEY\n' > "$dir/config/wake-gate-key-var"
  printf 'enforce\n' > "$dir/config/wake-gate-mode"
  printf '%s\t\n' "$(date +%s)" > "$state/wake-gate/gated.look"

  # Working evidence, recently looked at: the alarm is absorbed, nothing is queued.
  before=$(( $(date +%s) - 500 )); echo "$before" > "$state/.stale-since-$key"
  : > "$state/.writing-since-$key"
  : > "$state/.writing-resurfaced-$key"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WAKE_GATE_HELPER="$stub" \
    FM_WAKE_GATE_EVIDENCE_CMD="$evid" FM_TEST_ANSWERS="$(printf '0.92\t0.05\t0.06\t0.04')" "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher alarmed although the wake gate absorbed the wedge: $(cat "$out")"
  fi
  [ ! -s "$state/.wake-queue" ] || fail "an absorbed wedge alarm enqueued a wake"
  [ "$(cat "$state/.stale-since-$key")" -gt "$before" ] || fail "an absorbed wedge alarm did not restart the idle window"
  [ ! -e "$state/.writing-since-$key" ] && [ ! -e "$state/.writing-resurfaced-$key" ] \
    || fail "an absorbed wedge alarm kept the previous write-deferral chain"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional watcher stop"

  # A new failure: the gate escalates, the alarm fires as before, and the look is
  # recorded only after the alarm was queued.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"; : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_WAKE_GATE_HELPER="$stub" \
    FM_WAKE_GATE_EVIDENCE_CMD="$evid" FM_TEST_ANSWERS="$(printf '0.05\t0.05\t0.95\t0.10')" "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not alarm when the wake gate escalated"
  grep -F "possible wedge" "$out" >/dev/null || fail "the escalated alarm lost its possible-wedge reason"
  grep -q "$(printf '\tstale\t')" "$state/.wake-queue" || fail "the escalated wedge alarm was not queued"
  [ "$(cut -f2 "$state/wake-gate/gated.look")" = failure ] || fail "the queued alarm did not commit the gate's failure look"
  unset FM_FAKE_CREW_STATE
  pass "a possible-wedge alarm is absorbed only on the wake gate's absorb verdict and fires otherwise"
}

# --- non-terminal stale, crew provably working: absorbed, then wedge-escalated ---
# A provably-working crew (an actively-running pipeline) legitimately sits on a
# static pane (e.g. waiting on CI), so a non-terminal stale is absorbed and only
# the wedge timer eventually escalates it - the low-churn behavior preserved.

test_nonterminal_stale_provably_working_absorbed_then_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-working); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" quiet)
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$window" > "$state/quiet.meta"
  # Non-terminal status, and prime .seen-* so the signal scan does not pre-empt
  # the stale path.
  printf 'working: still compiling\n' > "$state/quiet.status"
  sig=$(seen_sig "$state/quiet.status"); printf '%s' "$sig" > "$state/.seen-quiet_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · ci running'

  # Phase A: a high escalation threshold means the first sighting is absorbed.
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a fresh provably-working non-terminal stale (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh provably-working stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh provably-working stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on absorb"
  [ -s "$state/.stale-since-$key" ] || fail "stale-since escalation timer was not recorded on absorb"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional phase-A watcher stop"

  # Phase B: backdate the idle timer past the threshold; the next run escalates.
  # (The subsequent-sight timer path does not re-read the crew state.)
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not escalate a provably-working non-terminal stale past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "escalation did not print a stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "escalation did not flag a possible wedge"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer was not cleared after escalation"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the wedge escalation failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "wedge escalation was not queued"
  pass "provably-working non-terminal stale is absorbed on first sight, then wedge-escalated past the threshold"
}

# --- non-terminal stale, crew NOT provably working: surfaced immediately ------
# The key requirement: a crew with no running pipeline that has gone quiet (and is
# not busy) has stopped - it may be done via interactive menus, waiting, or wedged.
# It must surface at once, never wait out the wedge timer, so these users (a
# non-no-mistakes crew, or any crew with no running pipeline) are never left hanging.

test_nonterminal_stale_not_working_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case nonterminal-stale-stopped); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" stopped)
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (the crew never wrote a captain-relevant verb), .seen-*
  # primed so the signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  sig=$(seen_sig "$state/stopped.status"); printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No running pipeline; the pane is idle. NOT provably working.
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'

  # Even with a high wedge threshold, a not-provably-working stale surfaces at once.
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a not-provably-working non-terminal stale at once"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate stopped-crew stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  [ ! -e "$state/.stale-since-$key" ] || fail "stale-since timer should not be set when surfacing immediately"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the immediate stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  pass "a not-provably-working non-terminal stale is surfaced immediately (never left to wait out the timer)"
}

# --- non-terminal stale, crew DECLARED a pause: absorbed, re-surfaced on a long
#     cadence, never wedge-escalated ------------------------------------------
# The live 2026-07-09/10 case: a crew intentionally held awaiting an upstream tool
# release (paused: ...) whose idle pane tripped repeated possible-wedge escalations
# all day. With the paused verb, its stale is absorbed like a working crew but never
# uses the wedge timer; it re-surfaces once past PAUSE_RESURFACE_SECS (anchored on
# the pause's own status-file age, so a churny idle pane cannot reset the cadence)
# for a recheck, so a forgotten pause cannot rot invisibly.
test_nonterminal_stale_paused_absorbed_then_resurfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf
  dir=$(make_case nonterminal-stale-paused); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" held)
  printf 'idle, holding for upstream' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$window" > "$state/held.meta"
  statusf="$state/held.status"
  # A DECLARED pause (not captain-relevant), .seen-* primed so the signal scan does
  # not pre-empt the stale path.
  printf 'paused: holding for the upstream tool release\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, holding for upstream")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # crew_absorb_class reads the declared pause from fm-crew-state.sh.
  export FM_FAKE_CREW_STATE='state: paused · source: status-log · holding for the upstream tool release'

  # Phase A: a fresh pause (status file just written) under a high re-surface
  # threshold is absorbed - no wake, no wedge timer.
  stream_capture "$window" "$capture_file"
  stream_foreground "$window" zsh
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a fresh declared pause (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "fresh paused stale printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "fresh paused stale enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on paused absorb"
  [ -e "$state/.paused-$key" ] || fail "paused flag not recorded on absorb"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused absorb must not start the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional paused phase-A stop"

  # Phase B: age the pause past the (now normal) threshold by backdating its
  # status file, re-prime .seen-* to the new signature so the signal scan stays
  # quiet, and confirm it re-surfaces as a paused recheck - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  : > "$out"
  printf 'idle, holding for upstream (token 2)' > "$capture_file"
  stream_capture "$window" "$capture_file"
  stream_foreground "$window" zsh
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a declared pause past the threshold"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "awaiting external" "$out" >/dev/null || fail "re-surface was not labeled a paused/awaiting-external recheck"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause was mislabeled a possible wedge"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the paused re-surface throttle marker was not recorded"
  [ ! -e "$state/.stale-since-$key" ] || fail "a paused re-surface must not use the wedge timer"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the paused re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "paused re-surface was not queued"
  pass "a declared pause is absorbed on first sight, then re-surfaced as a recheck past the threshold, never wedge-escalated"
}

# --- stale pane, crew reconciled DONE with a recorded PR: absorbed, re-surfaced
#     on the long held-merge cadence, never wedge-escalated -------------------
# The live case behind this bound: a finished worker whose PR sits green and
# ready while the merge authority decides. Its pane is legitimately quiet for
# the whole wait, but every rung of the wedge ladder re-alarmed it - nine
# consecutive possible-wedge escalations on one finished delivery - training
# the supervisor to dismiss exactly the alarm that will one day be real. The
# terminal branch is the canonical shape (the delivery's own done: line is the
# last status entry), and the recorded PR is what makes the quiet pane a
# delivery awaiting merge rather than an unknown state, so it gates the bound:
# done with no PR keeps the ordinary surface-it alarm.
test_done_pr_held_for_merge_stale_absorbed_not_wedge_escalated() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid back statusf pr since
  dir=$(make_case nonterminal-stale-held-merge); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" delivered)
  printf 'idle, waiting on the merge' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$window" > "$state/delivered.meta"
  statusf="$state/delivered.status"
  pr=https://github.com/acme/widget/pull/7
  # The recorded PR plus the delivery's own done: line, .seen-* primed so the
  # signal scan does not pre-empt the stale path.
  printf 'pr=%s\n' "$pr" >> "$state/delivered.meta"
  printf 'done: PR %s checks green\n' "$pr" > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-delivered_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, waiting on the merge")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · checks green: PR ready for review'

  # Phase A: a fresh delivery under a high re-surface threshold is absorbed -
  # no wake, no wedge timer - and the leftover escalation count from any
  # earlier undeclared episode must not outlive the delivery.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  stream_capture "$window" "$capture_file"
  stream_foreground "$window" zsh
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited for a done delivery awaiting merge (should absorb): $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a done delivery awaiting merge printed a wake reason during absorb"
  [ ! -s "$state/.wake-queue" ] || fail "a done delivery awaiting merge enqueued a wake during absorb"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor not advanced on held-merge absorb"
  [ -s "$state/.stale-since-$key" ] || fail "held-merge absorb must keep the wedge timer reset, not drop it"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "an undeclared episode's escalation count outlived the delivery"
  [ ! -e "$state/.paused-$key" ] || fail "a held-merge absorb wrote pause bookkeeping no status line declares"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional held-merge phase-A stop"

  # Phase B: age the delivery past the (now normal) cadence by backdating its
  # status file, re-prime .seen-*, and confirm it re-surfaces once as a
  # held-merge recheck naming the PR - never a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-delivered_status"
  : > "$out"
  printf 'idle, waiting on the merge (token 2)' > "$capture_file"
  stream_capture "$window" "$capture_file"
  stream_foreground "$window" zsh
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not re-surface a done delivery past the held-merge cadence"
  grep -F "stale: $window" "$out" >/dev/null || fail "re-surface did not print a stale wake"
  grep -F "$pr" "$out" >/dev/null || fail "held-merge re-surface did not name the recorded PR"
  grep -F 'awaiting merge' "$out" >/dev/null || fail "re-surface was not labeled a held-merge recheck"
  grep -F 'possible wedge' "$out" >/dev/null && fail "a done delivery awaiting merge was mislabeled a possible wedge"
  [ -s "$state/.held-merge-resurfaced-$key" ] || fail "the held-merge re-surface throttle marker was not recorded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the held-merge re-surface failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "held-merge re-surface was not queued"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional held-merge phase-B stop"

  # Phase C: the exact rung the nine false alarms came from - the ladder is due
  # (idle past STALE_ESCALATE_SECS on the same classified hash) while the crew
  # state still reconciles done with the recorded PR. The wedge_timer_check
  # bound must absorb it and reset the timer rather than escalate, so a
  # long merge wait cannot re-alarm once per escalation window either.
  : > "$out"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  stream_capture "$window" "$capture_file"
  stream_foreground "$window" zsh
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "the wedge ladder escalated a done delivery awaiting merge: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "the due wedge ladder printed a wake for a done delivery awaiting merge: $(cat "$out")"
  [ ! -s "$state/.wake-queue" ] || fail "the due wedge ladder enqueued a wake for a done delivery awaiting merge"
  since=$(cat "$state/.stale-since-$key" 2>/dev/null || true)
  [ "$since" -gt $(( $(date +%s) - 10 )) ] \
    || fail "the held-merge ladder absorb did not reset the wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional held-merge phase-C stop"

  pass "a done delivery with a recorded PR is absorbed, then re-surfaced once per long cadence naming the PR, never wedge-escalated"
}

# The gate on the held-merge bound: a crew whose state reconciles done with NO
# recorded PR - a worker that reported done but whose delivery was never
# recorded, possibly wedged after its status append - keeps the ordinary
# surface-it alarm, so the quiet pane cannot silently absorb it.
test_done_without_pr_record_is_still_surfaced() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig pid
  dir=$(make_case terminal-stale-no-pr); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" finished-no-pr)
  printf 'idle, done but unrecorded' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$window" > "$state/finished-no-pr.meta"
  printf 'done: implementation complete\n' > "$state/finished-no-pr.status"
  sig=$(seen_sig "$state/finished-no-pr.status"); printf '%s' "$sig" > "$state/.seen-finished-no-pr_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle, done but unrecorded")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  export FM_FAKE_CREW_STATE='state: done · source: run-step · run completed'

  # Even with a high wedge threshold, done without a PR surfaces at once.
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface a done crew with no recorded PR"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake for done without a PR"
  grep -F "possible wedge" "$out" >/dev/null && fail "an immediate done-no-PR stale was mislabeled a wedge"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced on surface"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || fail "drain after the done-no-PR stale failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "done-no-PR stale wake was not queued"
  pass "a done crew with no recorded PR keeps the ordinary surface-it alarm"
}

# A captain-held crew can leave a stable backend endpoint after its agent exits.
# fm-crew-state then authoritatively reports stopped rather than paused, but the
# confirmed-dead agent plus the declared wait or captain-held transfer must retain
# bounded pause handling.
# A still-live agent at an external-decision gate is the disconfirming case: it
# must surface once, while the unchanged hash must not append the same wake on
# every watcher re-arm.
test_exited_declared_pause_is_bounded_but_live_gate_surfaces() {
  local dir state fakebin out capture_file statusf window key pane_hash sig pid back round wakes bare
  dir=$(make_case exited-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window=$(stream_window "$state" held)
  printf 'idle bare shell after agent exit\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=stream\n' "$window" > "$state/held.meta"
  printf 'paused: held per captain while an external decision is pending\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after agent exit")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  round=1
  while [ "$round" -le 6 ]; do
    stream_capture "$window" "$capture_file"
    stream_foreground "$window" zsh
    PATH="$fakebin:$PATH" \
      FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    if wait_poll_cycle "$state" "$pid"; then
      reap "$pid"
    elif kill -0 "$pid" 2>/dev/null; then
      reap "$pid"
      fail "dead-agent watcher round $round timed out before completing a poll cycle"
    else
      wait "$pid" || fail "dead-agent watcher round $round failed"
    fi
    round=$((round + 1))
  done
  # A watcher that queues nothing never creates .wake-queue, so these counts
  # read a path that may legitimately be absent. awk aborts on a missing file
  # before END runs, which collapses the count to the empty string and turns the
  # next comparison into an "integer expression expected" error - reported as a
  # flood of an unprintable number of wakes instead of the real contract breach
  # the grep below names. No queue means no wakes, per the drain-count read at
  # the end of this file.
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -le 1 ] || fail "dead-agent declared pause flooded $wakes stale wakes across six unchanged polls"
  [ "$bare" -eq 0 ] || fail "dead-agent declared pause surfaced as $bare bare stopped-crew wakes"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    || fail "dead-agent declared pause did not use the bounded paused recheck"

  dir=$(make_case exited-captain-held); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
  window=$(stream_window "$state" held)
  printf 'idle bare shell after captain-held transfer\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=stream\n' "$window" > "$state/held.meta"
  printf 'captain-held [key=route]: tracked by held-decision-route\n' > "$statusf"
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle bare shell after captain-held transfer")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  stream_capture "$window" "$capture_file"
  stream_foreground "$window" zsh
  PATH="$fakebin:$PATH" \
    FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "captain-held dead-agent pane did not re-surface on the bounded cadence"
  grep -F "awaiting the captain" "$state/.wake-queue" >/dev/null \
    || fail "captain-held dead-agent pane surfaced as a stopped crew instead of a captain-owned recheck: $(cat "$state/.wake-queue")"
  grep -F "awaiting external" "$state/.wake-queue" >/dev/null \
    && fail "captain-held dead-agent pane borrowed the pause verb's external-wait wording"

  dir=$(make_case alive-decision-gate); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/gate.status"
  window=$(stream_window "$state" gate)
  printf 'idle external-decision gate\n' > "$capture_file"
  printf 'window=%s\nkind=ship\nharness=grok\nbackend=stream\n' "$window" > "$state/gate.meta"
  printf 'paused: waiting at an active external-decision gate\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-gate_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle external-decision gate")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  # First sight must surface promptly so a live external-decision gate is not
  # hidden behind the pause cadence.
  stream_capture "$window" "$capture_file"
  stream_foreground "$window" grok
  PATH="$fakebin:$PATH" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "live external-decision gate did not surface immediately"
  ack_stopped_cycle "$state" || fail "could not acknowledge the immediate external-decision surface"

  # Re-arm with the stale timer already beyond the wedge threshold. This is the
  # exact unchanged-hash fallback after the immediate surface: it must retain
  # the pause cadence and discard any residual wedge timer instead of emitting
  # a second possible-wedge wake.
  printf '%s\n' $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  stream_capture "$window" "$capture_file"
  stream_foreground "$window" grok
  PATH="$fakebin:$PATH" \
    FM_FAKE_CREW_STATE='state: paused · source: status-log · waiting at an active external-decision gate' \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"
    fail "live external-decision gate escalated on the wedge timer after its immediate surface: $(cat "$out")"
  fi
  [ -e "$state/.paused-$key" ] || { reap "$pid"; fail "live external-decision gate lost its pause cadence marker"; }
  [ ! -e "$state/.stale-since-$key" ] || { reap "$pid"; fail "live external-decision gate retained the wedge timer"; }
  reap "$pid"
  wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  bare=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w && $5 == "stale: " w { n++ } END { print n + 0 }' "$state/.wake-queue" 2>/dev/null || echo 0)
  [ "$wakes" -eq 0 ] || fail "acknowledged external-decision surface replayed $wakes wakes"
  [ "$bare" -eq 0 ] || fail "acknowledged external-decision bare stale remained queued"
  pass "exited declared-pause and captain-held panes use bounded pause cadence while a live decision gate still surfaces once"
}

# A dead worker reaches handle_paused_stale rather than the live fallback above.
# When one declared wait directly replaces another, the existing
# throttle belongs to the old declaration and must not suppress the new wait's
# first inspection merely because its timestamp is still young.
test_absorbed_replacement_wait_does_not_inherit_the_old_throttle() {
  local spec name initial replacement expected dir state fakebin out capture_file
  local statusf window key sig back pid wakes
  for spec in \
    'paused-replacement|paused: waiting on validation run one|paused: waiting on validation run two|awaiting external' \
    'captain-held-replacement|captain-held [key=route]: awaiting the routing call|captain-held [key=release]: awaiting the release call|awaiting the captain'
  do
    name=${spec%%|*}; spec=${spec#*|}
    initial=${spec%%|*}; spec=${spec#*|}
    replacement=${spec%%|*}; expected=${spec#*|}
    dir=$(make_case "$name"); state="$dir/state"; fakebin="$dir/fakebin"
    out="$dir/watch.out"; capture_file="$dir/pane.txt"; statusf="$state/held.status"
    window=$(stream_window "$state" held)
    printf 'idle after agent exit\n' > "$capture_file"
    printf 'window=%s\nkind=ship\nharness=grok\nbackend=stream\n' "$window" > "$state/held.meta"
    printf '%s\n' "$initial" > "$statusf"
    back=$(( $(date +%s) - 500 ))
    if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
    else touch -m -d "@$back" "$statusf"; fi
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
    key=$(printf '%s' "$window" | tr ':/.' '___')
    printf '%s' "$(hash_text 'idle after agent exit')" > "$state/.hash-$key"
    printf '1\n' > "$state/.count-$key"

    stream_capture "$window" "$capture_file"
    stream_foreground "$window" zsh
    PATH="$fakebin:$PATH" \
      FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "[$name] initial declared wait did not re-surface"
    ack_stopped_cycle "$state" || fail "[$name] could not acknowledge the initial declared wait"

    printf '%s\n' "$replacement" >> "$statusf"
    sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-held_status"
    printf 'idle after replacement wait\n' > "$capture_file"
    stream_capture "$window" "$capture_file"
    stream_foreground "$window" zsh
    PATH="$fakebin:$PATH" \
      FM_FAKE_CREW_STATE='state: stopped · source: pane · bare shell' \
      FM_WATCH_HANDLING_SUCCESSOR=1 \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" >> "$out" &
    pid=$!
    wait_for_exit "$pid" 100 \
      || { reap "$pid"; fail "[$name] replacement declared wait inherited the old throttle"; }
    wakes=$(awk -F '\t' -v w="$window" '$3 == "stale" && $4 == w { n++ } END { print n + 0 }' \
      "$state/.wake-queue" 2>/dev/null || echo 0)
    [ "$wakes" -eq 1 ] || fail "[$name] replacement declared wait produced $wakes wakes instead of one"
    grep -F "$expected" "$state/.wake-queue" >/dev/null \
      || fail "[$name] replacement declared wait used the wrong recheck reason: $(cat "$state/.wake-queue")"
  done
  pass "absorbed paused and captain-held replacements each start their own re-surface cadence"
}

# --- consecutive wedge escalations on the same pane demand deep inspection ----
# Root cause of the PR #252 incident's ~20 minutes of unnoticed green: each
# wedge escalation fires, gets classified as "still validating" one poll later
# (the timer restarts, see wedge_timer_check), and repeats forever on a pane
# that never changes. A single escalation reason looks identical every round,
# so nothing in the payload itself signals "this has now happened N times in a
# row" - that judgment call was left entirely to the supervisor noticing the
# repetition on its own. This is the safety-net fix: past
# FM_WEDGE_DEMAND_INSPECT_COUNT consecutive escalations on the SAME pane, the
# wake reason itself carries a "demand-deep-inspection" marker.

test_wedge_escalation_marks_demand_deep_inspection_after_threshold() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case wedge-escalation); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" wedged)
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$window" > "$state/wedged.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged.status"
  sig=$(seen_sig "$state/wedged.status"); printf '%s' "$sig" > "$state/.seen-wedged_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # The crew's pipeline is actively running: a static pane is normal (waiting on CI).
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # Priming round: first sighting of this stale hash classifies and absorbs it
  # (establishing .stale-$key and starting the wedge timer) without going
  # through wedge_timer_check at all - mirrors the existing wedge tests' Phase A.
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on the priming round (should absorb): $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional wedge priming stop"

  n=1
  while [ "$n" -le 3 ]; do
    # Backdate the wedge timer past the threshold before each round, mirroring
    # the existing wedge-escalation tests' Phase B (the subsequent-sight timer
    # path does not re-read the crew state).
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    stream_capture "$window" "$capture_file"
    PATH="$fakebin:$PATH" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "watcher did not escalate on consecutive wedge round $n: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge wedge escalation round $n"
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "escalation counter did not persist across consecutive rounds"
  unset FM_FAKE_CREW_STATE
  pass "consecutive wedge escalations on the same pane accumulate and demand deep inspection at the threshold"
}

test_wedge_escalation_resets_when_pane_becomes_active() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case wedge-escalation-reset); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"
  window=$(stream_window "$state" wedged-reset)
  printf 'idle building output' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\n' "$window" > "$state/wedged-reset.meta"
  printf 'working: still monitoring ci\n' > "$state/wedged-reset.status"
  sig=$(seen_sig "$state/wedged-reset.status"); printf '%s' "$sig" > "$state/.seen-wedged-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle building output")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # Pre-seed one escalation as if a prior wedge round already fired.
  printf '1\n' > "$state/.wedge-escalations-$key"
  export FM_FAKE_CREW_STATE='state: working · source: run-step · validating (running)'

  # The pane content changes (the crew is active again): the hash no longer
  # matches, so the watcher resets escalation bookkeeping instead of escalating.
  printf 'new output, crew active again' > "$capture_file"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "watcher exited on a fresh (changed) pane hash: $(cat "$out")"
  fi
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a changed pane hash did not reset the wedge-escalation counter"
  reap "$pid"
  unset FM_FAKE_CREW_STATE
  pass "a pane becoming active again resets the consecutive wedge-escalation counter"
}

# --- busy pane duration bound: a completed-turn age gate on top of busy -----
# 2026-07 hibit-agent-focus-nonsteal-r1 incident: a busy pane (herdr "working"
# and/or the harness's rendered busy footer) is unconditional, unbounded proof
# of liveness in every existing classifier, so a genuinely hung foreground tool
# call behind a busy signature ran undetected for 25h. BUSY_TURN_MAX_SECS bounds
# how long a busy pane may run with no completed turn (state/<id>.turn-ended, or
# the task's spawn record before any turn completes); past the bound, panes
# without a declared external wait or verified captain-held transfer take the
# SAME wedge_timer_check already used for a provably-working non-busy stale.
# Escalation reuses the identical stale reason, escalation counter, and
# demand-deep-inspection marker - never an
# automatic interrupt or restart.

test_busy_pane_below_turn_age_bound_is_absorbed() {
  local dir state fakebin out capture_file window key sig pid
  dir=$(make_case busy-below-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=$(stream_window "$state" busy-fresh)
  printf 'Working... (12.3s)' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/busy-fresh.meta"
  record_pi_busy "$state" busy-fresh
  printf 'working: setup complete\n' > "$state/busy-fresh.status"
  sig=$(seen_sig "$state/busy-fresh.status"); printf '%s' "$sig" > "$state/.seen-busy-fresh_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch "$state/busy-fresh.turn-ended"
  prime_turnend_seen "$state/busy-fresh.turn-ended"

  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=999 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a busy pane below the turn-age bound was escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a busy pane below the turn-age bound printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a busy pane below the turn-age bound started a wedge timer"
  reap "$pid"
  pass "a busy worker below the turn-age bound remains working with no escalation"
}

test_busy_pane_stable_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-stable-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=$(stream_window "$state" busy-stable)
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/busy-stable.meta"
  record_pi_busy "$state" busy-stable
  printf 'working: setup complete\n' > "$state/busy-stable.status"
  sig=$(seen_sig "$state/busy-stable.status"); printf '%s' "$sig" > "$state/.seen-busy-stable_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # No completed turn ever recorded for this task: age the spawn record itself.
  touch -t 200001010000 "$state/busy-stable.meta"

  # Phase A: past the bound, the stable-hash busy pane is absorbed but starts
  # the wedge timer (mirrors the existing provably-working-stale Phase A/B).
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a stable-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a stable-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional stable-hash phase-A stop"

  # Phase B: backdate the wedge timer past the threshold; the next poll escalates.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a stable-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation did not flag a possible wedge"
  pass "a busy worker with a stable pane hash still escalates once its completed-turn age reaches the bound"
}

# Regression fixture for the incident's actual masking condition: Pi's rendered
# elapsed-time footer changes every poll, so the pane hash never repeats and the
# watcher always takes the "new hash" branch, never the stable-hash one above.
test_busy_pane_changing_hash_escalates_past_turn_age_bound() {
  local dir state fakebin out capture_file window key pid
  dir=$(make_case busy-changing-hash-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=$(stream_window "$state" busy-ticking)
  printf 'Working... (3600.1s)' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/busy-ticking.meta"
  record_pi_busy "$state" busy-ticking
  printf 'working: setup complete\n' > "$state/busy-ticking.status"
  sig=$(seen_sig "$state/busy-ticking.status"); printf '%s' "$sig" > "$state/.seen-busy-ticking_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/busy-ticking.meta"
  # No pre-seeded .hash-<key>: with a real ticking elapsed footer, every poll
  # lands here (h != prev) - the reproduction's actual masking condition.

  # Phase A: first sight past the bound absorbs and starts the wedge timer,
  # without ever needing the "genuinely stale" hash-match path.
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a changing-hash busy pane past the turn-age bound escalated before the wedge threshold: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a changing-hash busy pane past the turn-age bound did not start a wedge timer"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional changing-hash phase-A stop"

  # Phase B: another tick (still a fresh, never-before-seen hash) plus a
  # backdated wedge timer escalates exactly as the stable-hash case does.
  printf 'Working... (3601.2s)' > "$capture_file"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "a changing-hash busy pane did not wedge-escalate past the turn-age bound"
  grep -F "stale: $window" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not print the stale wake"
  grep -F "possible wedge" "$out" >/dev/null || fail "busy turn-age escalation (changing hash) did not flag a possible wedge"
  pass "a busy worker whose pane hash changes every poll still escalates once its completed-turn age reaches the bound"
}

test_busy_pane_turn_end_touch_resets_age() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-turn-end-resets-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=$(stream_window "$state" busy-reset)
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/busy-reset.meta"
  record_pi_busy "$state" busy-reset
  printf 'working: setup complete\n' > "$state/busy-reset.status"
  sig=$(seen_sig "$state/busy-reset.status"); printf '%s' "$sig" > "$state/.seen-busy-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A wedge is already mid-escalation, as if several over-age polls already ran.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  # The worker's most recent turn just completed: touching turn-ended resets age.
  touch "$state/busy-reset.turn-ended"
  prime_turnend_seen "$state/busy-reset.turn-ended"

  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a freshly completed turn on a busy pane was still escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a freshly completed turn on a busy pane printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a freshly completed turn did not clear the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a freshly completed turn did not clear the escalation counter"
  reap "$pid"
  pass "touching a busy worker's completed-turn marker resets the age and prevents an old-age escalation"
}

test_busy_pane_native_progress_resets_age() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-native-progress-resets-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=$(stream_window "$state" busy-reset)
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/busy-reset.meta"
  record_pi_busy "$state" busy-reset
  printf 'working: setup complete\n' > "$state/busy-reset.status"
  sig=$(seen_sig "$state/busy-reset.status"); printf '%s' "$sig" > "$state/.seen-busy-reset_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # A wedge is already mid-escalation, as if several over-age polls already ran.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '1\n' > "$state/.wedge-escalations-$key"
  # The worker has progressed without completing its long native turn.
  touch "$state/busy-reset.progress"
  touch -t 200001010000 "$state/busy-reset.meta"
  touch -t 200001010000 "$state/busy-reset.turn-ended"
  prime_turnend_seen "$state/busy-reset.turn-ended"

  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=3600 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a fresh native activity on a busy pane was still escalated: $(cat "$out")"
  fi
  [ ! -s "$out" ] || fail "a fresh native activity on a busy pane printed a wake reason"
  [ ! -e "$state/.stale-since-$key" ] || fail "a fresh native activity did not clear the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a fresh native activity did not clear the escalation counter"
  reap "$pid"
  pass "native progress resets busy age without a completed turn or notification"
}

test_busy_pane_repeated_escalation_reaches_demand_deep_inspection() {
  local dir state fakebin out capture_file window key pane_hash sig pid n
  dir=$(make_case busy-turn-age-demand-inspect); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=$(stream_window "$state" busy-demand)
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/busy-demand.meta"
  record_pi_busy "$state" busy-demand
  printf 'working: setup complete\n' > "$state/busy-demand.status"
  sig=$(seen_sig "$state/busy-demand.status"); printf '%s' "$sig" > "$state/.seen-busy-demand_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  touch -t 200001010000 "$state/busy-demand.turn-ended"
  prime_turnend_seen "$state/busy-demand.turn-ended"

  # Priming round: first sighting past the turn-age bound absorbs and starts
  # the wedge timer, mirroring the existing provably-working wedge tests.
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "priming round for busy turn-age escalation was not absorbed: $(cat "$out")"
  fi
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional busy-wedge priming stop"

  n=1
  while [ "$n" -le 3 ]; do
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    : > "$out"
    stream_capture "$window" "$capture_file"
    PATH="$fakebin:$PATH" \
      FM_STATE_OVERRIDE="$state" FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_for_exit "$pid" 100 || fail "busy turn-age escalation round $n did not escalate: $(cat "$out")"
    grep -F "escalation $n" "$out" >/dev/null || fail "busy turn-age round $n did not report escalation count $n: $(cat "$out")"
    if [ "$n" -lt 3 ]; then
      grep -F "demand-deep-inspection" "$out" >/dev/null && fail "busy turn-age round $n escalated to demand-deep-inspection before the threshold: $(cat "$out")"
    else
      grep -F "demand-deep-inspection" "$out" >/dev/null || fail "busy turn-age round $n (threshold) did not demand deep inspection: $(cat "$out")"
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge busy turn-age escalation round $n"
    n=$((n + 1))
  done
  [ "$(cat "$state/.wedge-escalations-$key" 2>/dev/null || echo 0)" = 3 ] || fail "busy turn-age escalation counter did not persist across consecutive rounds"
  pass "repeated busy turn-age escalations reuse the existing escalation counter and demand deep inspection at the threshold"
}

# --- declared pause + busy pane: the busy-turn bound must honor the declaration
# A single foreground call can keep a declared external wait semantically busy
# past the completed-turn bound, bypassing the ordinary stale-pause path.
# This fixture pins all three halves of the contract: the declared pause is
# absorbed instead of wedged (A), it is still rechecked on the long
# PAUSE_RESURFACE_SECS cadence so a forgotten wait cannot rot invisibly (B), and
# lifting the declaration on the SAME busy over-age pane restores the wedge
# escalation, proving the discriminator is the worker's own declaration and not a
# blanket silencing of the escalator (C).
# Drive the due busy-turn ladder with the real backlog predicate. Every round
# starts beyond the alarm threshold; ordinary polls must not consume the hold.
test_busy_backlog_hold_bounds_wedge_ladder() {
  local dir state out capture key mode pid
  command -v tasks-axi >/dev/null 2>&1 \
    || { echo 'skip: tasks-axi not found (busy backlog hold)'; return 0; }
  dir=$(make_hold_home busy-backlog-bound 'working: monitoring progress' hold) \
    || fail 'could not create busy hold fixture'
  state="$dir/state"; out="$dir/watch.out"; capture="$dir/pane.txt"; key=$(hold_key "$state")
  printf 'window=%s\nkind=ship\nharness=deck\nbackend=stream\n' "$(stream_window "$state" held-merge)" > "$state/held-merge.meta"
  record_pi_busy "$state" held-merge
  touch -t 200001010000 "$state/held-merge.meta"
  printf 'Working...\n' > "$capture"
  for mode in first repeat reheld answered absent unreadable; do
    case "$mode" in
      reheld|answered)
        printf 'proceed\n' > "$dir/decision.txt"
        run_hold "$dir" answer held-merge --decision-file "$dir/decision.txt" --release \
          || fail 'could not release busy hold'
        if [ "$mode" = reheld ]; then
          run_hold "$dir" hold held-merge --reason 'another decision' || fail 'could not re-hold busy task'
        fi ;;
      absent) rm "$dir/data/backlog.md" ;;
      unreadable) mkdir "$dir/data/backlog.md" ;;
    esac
    echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
    printf '2\n' > "$state/.wedge-escalations-$key"
    : > "$out"
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 hold_watch_launch "$dir" "$out" "$capture"
    pid=$HOLD_WATCH_PID
    if [ "$mode" = repeat ]; then
      wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "held busy task re-alarmed: $(cat "$out")"; }
      [ ! -s "$out" ] || fail 'held busy task printed a wake'
      [ ! -e "$state/.paused-$key" ] || fail 'backlog-only hold became a declared pause'
      [ ! -e "$state/.wedge-escalations-$key" ] || fail 'held busy task retained escalation count'
      reap "$pid"
    else
      wait_for_exit "$pid" 150 || { reap "$pid"; fail "busy $mode did not wake"; }
      grep -F "stale: $(hold_target "$state")" "$out" >/dev/null || fail "busy $mode lost stale wake"
      case "$mode" in
        first|reheld)
          grep -F 'possible wedge' "$out" >/dev/null && fail "busy $mode call was wedge-escalated"
          [ -s "$state/.paused-resurfaced-$key" ] || fail 'first call wake did not record its throttle' ;;
        *) grep -F 'possible wedge' "$out" >/dev/null || fail "busy $mode stopped alarming" ;;
      esac
    fi
    ack_stopped_cycle "$state" || fail "could not acknowledge busy $mode cycle"
  done
  pass 'busy backlog holds bound the ladder, retain first-sight and call identity, and fail open without a provable hold'
}

test_busy_declared_pause_is_rechecked_not_wedge_escalated() {
  local dir state fakebin out capture_file window key sig pid statusf back
  dir=$(make_case busy-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=$(stream_window "$state" review-scout)
  statusf="$state/review-scout.status"
  printf 'Working... (7200.4s) lavish-axi poll' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=scout\nharness=deck\n' "$window" > "$state/review-scout.meta"
  record_pi_busy "$state" review-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  # No completed turn for hours (the single blocking poll call): age the spawn
  # record itself, exactly as the never-completed-a-turn fixtures above do.
  touch -t 200001010000 "$state/review-scout.meta"
  # No pre-seeded .hash-<key>: a live harness footer ticks, so every poll lands
  # on the changed-hash branch - the review scout's real masking condition.

  # Phase A: past the bound, with the wedge threshold set as low as it goes, the
  # declared pause is absorbed on the long cadence and never starts a wedge.
  # An earlier undeclared phase must not leave its ladder running under the wait.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (deck-wrapper)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a declared pause on a busy review pane was escalated: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "a declared pause on a busy review pane printed a wake reason: $(cat "$out")"
  [ -e "$state/.paused-$key" ] || fail "the busy-turn bound did not apply the declared-pause cadence"
  [ ! -e "$state/.stale-since-$key" ] || fail "a declared pause on a busy pane started the wedge timer"
  [ ! -e "$state/.wedge-escalations-$key" ] || fail "a declared pause on a busy pane incremented the escalation counter"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional declared-pause phase-A stop"

  # Phase B: age the pause past the (now normal) long cadence and let the pane
  # settle on one stable hash, so the still-busy pane takes the repeat-hash
  # branch whose pause bookkeeping the bound must not wipe. It re-surfaces once
  # as a recheck, never as a wedge.
  back=$(( $(date +%s) - 500 ))
  if [ "$(uname)" = Darwin ]; then touch -mt "$(date -r "$back" '+%Y%m%d%H%M.%S')" "$statusf"
  else touch -m -d "@$back" "$statusf"; fi
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  printf '%s' "$(hash_text "$(cat "$capture_file")")" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (deck-wrapper)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=240 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a declared pause past the long cadence was never rechecked"; }
  grep -F "awaiting external" "$out" >/dev/null || fail "the recheck was not labeled a declared-pause recheck: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null && fail "a declared pause on a busy pane was mislabeled a possible wedge: $(cat "$out")"
  [ -e "$state/.paused-resurfaced-$key" ] || fail "the declared-pause re-surface throttle was cleared by the busy-turn bound"
  [ ! -e "$state/.stale-since-$key" ] || fail "a declared-pause recheck used the wedge timer"
  ack_stopped_cycle "$state" || fail "could not acknowledge the declared-pause recheck"

  # Phase C: the pause is lifted on the SAME busy, over-age pane. Nothing else
  # changes, so a still-absorbed pane here would mean the bound was silenced
  # rather than taught the declaration. It must wedge-escalate exactly as before.
  printf 'working: review closed, resuming the sweep\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-review-scout_status"
  : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (deck-wrapper)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=999 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "a lifted pause escalated before the wedge threshold: $(cat "$out")"; }
  reap "$pid"
  [ -s "$state/.stale-since-$key" ] || fail "a lifted pause did not restore the busy-turn wedge timer"
  [ ! -e "$state/.paused-$key" ] || fail "a lifted pause left stale declared-pause bookkeeping behind"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional lifted-pause priming stop"

  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (deck-wrapper)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || { reap "$pid"; fail "a lifted pause on an over-age busy pane no longer wedge-escalates"; }
  grep -F "possible wedge" "$out" >/dev/null || fail "the restored busy-turn escalation did not flag a possible wedge: $(cat "$out")"
  pass "a busy pane under a declared pause is rechecked on the long cadence, and lifting the pause restores the wedge escalation"
}

# --- declared pause + busy pane + AWAY MODE: the bound must hand off, not decorate
# Away mode is daemon-owned: the watcher reverts to one-shot and lets the daemon
# classify. The busy-turn bound used to be the one stale path that ignored that,
# running the wedge timer under afk and handing the daemon a wake already decorated
# as a possible wedge. That decoration outranks the daemon's own pause verdict, so a
# crew that declared the wait itself was wedge-escalated once per
# FM_STALE_ESCALATE_SECS for as long as the wait lasted, with the escalation count
# climbing into demand-deep-inspection on a pane nobody needed to inspect.
# Phase A pins the handoff: the plain window identity, no wedge timer, no escalation
# counter, and no normal-mode pause bookkeeping (the daemon owns that in away mode).
# Phase B re-arms on the same unchanged pane and pins the one-shot: a second wake
# here is what the climbing ladder looked like. Phase C drives the discriminator
# apart on the SAME afk, busy, over-age pane - lifting the declaration restores the
# wedge escalation, so this is the worker's declaration being honored rather than
# away mode silencing the escalator.
test_afk_busy_declared_pause_hands_off_plain_stale() {
  local dir state fakebin out capture_file window key sig pid statusf
  dir=$(make_case afk-busy-declared-pause); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=$(stream_window "$state" afk-review-scout)
  statusf="$state/afk-review-scout.status"
  printf 'Working... (7200.4s) lavish-axi poll' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=scout\nharness=deck\n' "$window" > "$state/afk-review-scout.meta"
  record_pi_busy "$state" afk-review-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-review-scout_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/afk-review-scout.meta"
  date '+%s' > "$state/.afk"

  # Phase A: past the bound, with the wedge threshold as low as it goes, the
  # declaration is handed to the daemon undecorated instead of being wedge-timed.
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (deck-wrapper)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "the away-mode busy-turn bound never handed the declared pause to the daemon"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "the away-mode busy-turn bound did not hand off the plain window identity: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "away mode decorated a declared pause as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "the away-mode handoff started the wedge timer on a declared pause"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the away-mode handoff incremented the wedge escalation count on a declared pause"
  [ ! -e "$state/.paused-$key" ] \
    || fail "the away-mode handoff recorded normal-mode pause tracking instead of leaving it to the daemon"
  ack_stopped_cycle "$state" || fail "could not acknowledge the away-mode declared-pause handoff"

  # Phase B: re-arm on the same unchanged pane. The bound has already handed this
  # stale hash off, so it must stay silent rather than re-waking the daemon - a
  # second wake here is the escalation ladder the wedge timer used to climb.
  : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (deck-wrapper)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "the away-mode bound re-woke on an already-handed-off declared pause: $(cat "$out")"; }
  reap "$pid"
  [ ! -s "$out" ] || fail "the away-mode bound re-surfaced an already-handed-off declared pause: $(cat "$out")"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "re-arming on an unchanged declared pause started a wedge escalation ladder"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional away-mode re-arm stop"

  # Phase C: lift the declaration on the SAME afk, busy, over-age pane. Nothing else
  # changes, so a wedge escalation here proves the declaration was the discriminator.
  printf 'working: resumed the review write-up\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-review-scout_status"
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (deck-wrapper)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=240 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "a lifted pause on an away-mode over-age busy pane no longer wedge-escalates"; }
  grep -F "possible wedge" "$out" >/dev/null \
    || fail "the restored away-mode busy-turn escalation did not flag a possible wedge: $(cat "$out")"
  pass "away mode hands a busy declared pause to the daemon as a plain stale, and lifting the declaration restores the wedge escalation"
}

# --- declared pause + busy pane + AWAY MODE + a TICKING footer: one wake per declaration
# The static-pane case above cannot tell a hash-keyed one-shot from a
# declaration-keyed one, because its capture never changes between polls. The
# incident pane's harness footer ticks on every capture, so a one-shot keyed on the
# pane hash re-fires on every poll, and the daemon, which relaunches the watcher
# after each handled wake, is woken in a loop for the whole declared wait. This
# fixture's fake tmux renders a fresh footer on EVERY capture-pane and asserts that
# divergence outright on every re-arm (.hash-<key> moves, .count-<key> never
# climbs), so the one-wake assertion across five silent re-arms cannot pass
# vacuously on a pane that happened to sit still. Round 1 also starts from an
# undeclared wedge timer and escalation count, which the handoff must clear the
# way the normal-mode absorber does, so lifting the declaration later starts the
# wedge path from a fresh timer rather than resuming a stale count.
test_afk_busy_declared_pause_ticking_pane_hands_off_once() {
  local dir state fakebin out drain_out window key sig pid statusf ticks round prev_hash cur_hash prev_ticks
  dir=$(make_case afk-busy-declared-pause-ticking); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; drain_out="$dir/drain.out"; window=$(stream_window "$state" afk-ticking-scout)
  statusf="$state/afk-ticking-scout.status"; ticks="$dir/ticks"
  # Every screen read renders a new elapsed footer and counts itself in $ticks.
  fm_test_fake_stream_set "$window" "$(jq -nc --arg f "$ticks" \
    '{tick_format: "Working... ({t}.{d}s) lavish-axi poll", tick_base: 7200, tick_file: $f}')"
  printf 'window=%s\nbackend=stream\nkind=scout\nharness=deck\n' "$window" > "$state/afk-ticking-scout.meta"
  record_pi_busy "$state" afk-ticking-scout
  printf 'paused: hosting the Lavish review, awaiting captain feedback\n' > "$statusf"
  sig=$(seen_sig "$statusf"); printf '%s' "$sig" > "$state/.seen-afk-ticking-scout_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  touch -t 200001010000 "$state/afk-ticking-scout.meta"
  date '+%s' > "$state/.afk"
  # An undeclared busy phase already ran the wedge timer and escalated twice
  # before the crew declared the wait.
  echo $(( $(date +%s) - 500 )) > "$state/.stale-since-$key"
  printf '2\n' > "$state/.wedge-escalations-$key"
  date +%s > "$state/.writing-since-$key"

  # Round 1: the declaration is handed off once, undecorated, and the undeclared
  # phase's wedge bookkeeping is cleared with it.
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (deck-wrapper)' \
    FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
    FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 150 || { reap "$pid"; fail "the away-mode busy-turn bound never handed a ticking declared pause to the daemon"; }
  grep -Fx "stale: $window" "$out" >/dev/null \
    || fail "the away-mode busy-turn bound did not hand off the plain window identity for a ticking pane: $(cat "$out")"
  grep -F "possible wedge" "$out" >/dev/null \
    && fail "away mode decorated a ticking declared pause as a possible wedge: $(cat "$out")"
  [ ! -e "$state/.stale-since-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's wedge timer in place"
  [ ! -e "$state/.wedge-escalations-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's escalation count in place"
  [ ! -e "$state/.writing-since-$key" ] \
    || fail "the away-mode handoff left the undeclared phase's write-deferral chain in place"
  [ ! -e "$state/.paused-$key" ] \
    || fail "the away-mode handoff recorded normal-mode pause tracking on a ticking pane"
  ack_stopped_cycle "$state" || fail "could not acknowledge the ticking declared-pause handoff"

  # Rounds 2-6: five consecutive re-arms on the same standing declaration. Every
  # capture renders a new footer, so every poll lands on the changed-hash branch -
  # the exact shape a hash-keyed one-shot re-fires on. Each round proves the pane
  # really moved before it asserts silence, so the case cannot go vacuous.
  round=2
  while [ "$round" -le 6 ]; do
    prev_hash=$(cat "$state/.hash-$key" 2>/dev/null || true)
    prev_ticks=$(cat "$ticks" 2>/dev/null || echo 0)
    : > "$out"
    PATH="$fakebin:$PATH" \
      FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
      FM_FAKE_CREW_STATE='state: working · source: pane · harness busy (deck-wrapper)' \
      FM_BUSY_TURN_MAX_SECS=1 FM_STALE_ESCALATE_SECS=1 FM_PAUSE_RESURFACE_SECS=999 \
      FM_POLL=0.2 FM_SIGNAL_GRACE=1 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
    pid=$!
    wait_poll_cycle "$state" "$pid" || { reap "$pid"; fail "re-arm $round on a ticking declared pause re-woke the daemon: $(cat "$out")"; }
    reap "$pid"
    cur_hash=$(cat "$state/.hash-$key" 2>/dev/null || true)
    [ "$(cat "$ticks" 2>/dev/null || echo 0)" -gt "$prev_ticks" ] \
      || fail "re-arm $round never captured the pane, so its silence proves nothing"
    [ -n "$cur_hash" ] && [ "$cur_hash" != "$prev_hash" ] \
      || fail "re-arm $round saw the same pane hash as the round before, so it cannot tell a hash-keyed one-shot from a declaration-keyed one"
    [ "$(cat "$state/.count-$key" 2>/dev/null || echo missing)" = 0 ] \
      || fail "re-arm $round settled on a stable hash instead of ticking on every poll"
    [ ! -s "$out" ] || fail "re-arm $round re-surfaced a standing declared pause on a ticking pane: $(cat "$out")"
    [ ! -e "$state/.stale-since-$key" ] \
      || fail "re-arm $round started the wedge timer on a standing declared pause"
    [ ! -e "$state/.wedge-escalations-$key" ] \
      || fail "re-arm $round climbed the wedge escalation ladder on a standing declared pause"
    ack_stopped_cycle "$state" || fail "could not acknowledge the intentional re-arm $round stop"
    round=$((round + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2>/dev/null || true
  grep "$(printf '\tstale\t')" "$drain_out" >/dev/null \
    && fail "the silent re-arms still queued a stale row for the standing declaration: $(cat "$drain_out")"
  pass "away mode wakes the daemon once per declaration for a busy pane whose footer ticks on every capture"
}

# Behavioral proof that the production default (no FM_BUSY_TURN_MAX_SECS override
# anywhere in this env) is 3600s: a completed turn 5 minutes old must not start a
# wedge timer, while one 66 minutes old must - bracketing the default around 3600
# without waiting a literal hour.
test_busy_pane_default_turn_age_bound_is_3600s() {
  local dir state fakebin out capture_file window key pane_hash sig pid
  dir=$(make_case busy-default-turn-age); state="$dir/state"; fakebin="$dir/fakebin"
  out="$dir/watch.out"; capture_file="$dir/pane.txt"; window=$(stream_window "$state" busy-default)
  printf 'Working...' > "$capture_file"
  printf 'window=%s\nbackend=stream\nkind=ship\nharness=deck\n' "$window" > "$state/busy-default.meta"
  record_pi_busy "$state" busy-default
  printf 'working: setup complete\n' > "$state/busy-default.status"
  sig=$(seen_sig "$state/busy-default.status"); printf '%s' "$sig" > "$state/.seen-busy-default_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "Working...")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"

  set_mtime $(( $(date +%s) - 300 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 5-minute-old completed turn tripped the default busy-turn-age bound: $(cat "$out")"
  fi
  [ ! -e "$state/.stale-since-$key" ] || fail "a 5-minute-old completed turn started a wedge timer under the default bound"
  reap "$pid"
  ack_stopped_cycle "$state" || fail "could not acknowledge the intentional five-minute-bound stop"

  set_mtime $(( $(date +%s) - 4000 )) "$state/busy-default.turn-ended"
  prime_turnend_seen "$state/busy-default.turn-ended"
  : > "$out"
  stream_capture "$window" "$capture_file"
  PATH="$fakebin:$PATH" \
    FM_STATE_OVERRIDE="$state" FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  pid=$!
  if ! wait_poll_cycle "$state" "$pid"; then
    reap "$pid"; fail "a 66-minute-old completed turn escalated before the wedge threshold under the default bound: $(cat "$out")"
  fi
  [ -s "$state/.stale-since-$key" ] || fail "a 66-minute-old completed turn did not start a wedge timer under the default bound (default is not 3600s)"
  reap "$pid"
  pass "the production default busy-turn-age bound is 3600s (5min under does not wedge, 66min over does)"
}

test_terminal_stale_surfaced
test_stale_terminal_status_overridden_by_active_run
test_nonterminal_stale_provably_working_absorbed_then_escalated
test_wedge_alarm_honors_the_wake_gate_verdict
test_wedge_escalation_marks_demand_deep_inspection_after_threshold
test_wedge_escalation_resets_when_pane_becomes_active
test_busy_pane_below_turn_age_bound_is_absorbed
test_busy_pane_stable_hash_escalates_past_turn_age_bound
test_busy_pane_changing_hash_escalates_past_turn_age_bound
test_busy_pane_turn_end_touch_resets_age
test_busy_pane_native_progress_resets_age
test_busy_pane_repeated_escalation_reaches_demand_deep_inspection
test_busy_pane_default_turn_age_bound_is_3600s
test_busy_backlog_hold_bounds_wedge_ladder
test_busy_declared_pause_is_rechecked_not_wedge_escalated
test_afk_busy_declared_pause_hands_off_plain_stale
test_afk_busy_declared_pause_ticking_pane_hands_off_once
test_nonterminal_stale_not_working_surfaced
test_nonterminal_stale_paused_absorbed_then_resurfaced
test_done_pr_held_for_merge_stale_absorbed_not_wedge_escalated
test_done_without_pr_record_is_still_surfaced
test_exited_declared_pause_is_bounded_but_live_gate_surfaces
test_absorbed_replacement_wait_does_not_inherit_the_old_throttle
