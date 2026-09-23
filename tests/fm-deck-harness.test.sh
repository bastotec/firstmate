#!/usr/bin/env bash
# Behavior tests for the Deck crewmate/scout adapter.
#
# Deck (bastotec/deck) is headless: one `deck run` per turn, NDJSON on stdout.
# bin/fm-deck-worker.sh is the pane-resident driver that makes it a supervised
# worker, so most of what could go wrong is Firstmate's own code and is pinned
# here against a fake deck binary:
#   1. The driver runs the brief as the first turn and every later prompt line
#      as the next turn of the SAME Deck session, with the evidence gate and the
#      progress hook attached to every run.
#   2. It is the task's semantic busy source (deck-wrapper): a turn opens busy
#      and closes idle, a finished turn touches the turn-end notification, and
#      /quit records session-end.
#   3. The evidence gate refuses a turn without a worker-status line and lets
#      one through that has one, while the driver gives every completed,
#      failed, or interrupted turn a status line before its turn-end signal.
#   4. Ctrl+C cancels the running turn and returns to the prompt.
#   5. Pane liveness reads the driver (argv[0] fm-deck-worker) and deck as an
#      agent, never as an idle shell; unrelated names stay unclaimed.
#   6. Control, busy-source, and delivery tables name deck, and a secondmate
#      launches use the same driver with home-host supervision.
#   7. Ordinary Deck dispatch launches the driver with the resolved deck
#      binary, busy gen, and model, records effort without passing it, and arms
#      the busy contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux || fail "could not load the tmux backend"

WORKER="$ROOT/bin/fm-deck-worker.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-deck-harness)

# A fake deck: logs its argv, honours --session, runs the pre_complete hook the
# way Deck does (exit 2 = refused), and optionally writes a status line or
# sleeps (to be interrupted). Never contacts a model.
make_fake_deck() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/deck" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$0")
printf '%s\n' "$*" >> "$dir/argv.log"
prompt=$2; session=''; gate=''
while [ $# -gt 0 ]; do
  case "$1" in
    --session) session=$2; shift 2 ;;
    --hook) case "$2" in pre_complete=*) gate=${2#pre_complete=} ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$session" ] || session="s-fake-$$"
case "$prompt" in *slow*) sleep 0.8 ;; esac
printf '{"type":"run_started","session":"%s","model":"m"}\n' "$session"
printf '{"type":"text_delta","text":"echo: %s"}\n' "$prompt"
case "$prompt" in
  *replace-status*)
    rm -f -- "$FM_TEST_STATUS"
    ln -s "$FM_TEST_EXTERNAL" "$FM_TEST_STATUS"
    ;;
  *write-status*replace-busy-gen*)
    printf 'done: wrote evidence\n' >> "$FM_TEST_STATUS"
    "$FM_TEST_BUSY_EVENT" arm "$(dirname "$FM_TEST_STATUS")" t1 >/dev/null
    ;;
  *write-status*) printf 'done: wrote evidence\n' >> "$FM_TEST_STATUS" ;;
  *resolve-only*) printf 'resolved [key=choice]: answered: yes\n' >> "$FM_TEST_STATUS" ;;
  *sleep*)
    bash -c 'printf "%s\n" "$$" > "$1/interrupt-ready"; exec sleep 30' _ "$dir"
    ;;
esac
if [ -n "$gate" ]; then
  if bash -c "$gate" </dev/null 2>>"$dir/gate.err"; then
    echo pass >> "$dir/gate.log"
  else
    echo refused >> "$dir/gate.log"
    printf 'pre_complete hook rejected completion\n' >&2
    printf '{"type":"completion_blocked","attempt":1,"reason":"status evidence required"}\n'
    case "$prompt" in
      *recover-after-refusal*)
        printf 'done: recovered after refusal\n' >> "$FM_TEST_STATUS"
        if bash -c "$gate" </dev/null 2>>"$dir/gate.err"; then echo pass >> "$dir/gate.log"; fi
        ;;
    esac
  fi
fi
case "$prompt" in
  *fail-turn*) printf '{"type":"run_failed","error":"provider failed"}\n'; exit 9 ;;
  *) printf '{"type":"run_finished","output":"x","turns":1}\n' ;;
esac
SH
  chmod +x "$dir/deck"
}

# run_worker <case-dir> <input-lines> [first-prompt] -> runs the driver to completion
run_worker() {
  local dir=$1 input=$2 prompt=${3:-the brief} gen
  mkdir -p "$dir/state"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  printf '%s' "$gen" > "$dir/gen"
  printf '%s' "$input" | FM_TEST_STATUS="$dir/state/t1.status" FM_TEST_EXTERNAL="${FM_TEST_EXTERNAL:-}" \
    FM_TEST_BUSY_EVENT="$BUSY_EVENT" \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" \
      --deck "$dir/deck" --model codex/gpt-5.6-luna -- "$prompt" > "$dir/pane.out" 2>&1
}

test_turns_share_one_session_and_carry_the_hooks() {
  local dir="$TMP_ROOT/session"
  make_fake_deck "$dir"
  run_worker "$dir" $'first\nsecond\n/exit\n/quit\n' || fail "the driver did not exit cleanly on /quit: $(cat "$dir/pane.out")"
  [ "$(wc -l < "$dir/argv.log" | tr -d ' ')" = 4 ] || fail "expected four deck runs (brief + three prompts): $(cat "$dir/argv.log")"
  head -1 "$dir/argv.log" | grep -q -- '--session' && fail "the first turn must start a new Deck session"
  local sid
  sid=$(sed -n 2p "$dir/argv.log" | sed -E 's/.*--session ([^ ]+).*/\1/')
  case "$sid" in s-fake-*) ;; *) fail "the second turn did not resume the first turn's session: $(sed -n 2p "$dir/argv.log")" ;; esac
  sed -n 3p "$dir/argv.log" | grep -q -- "--session $sid" || fail "the third turn changed session"
  sed -n 4p "$dir/argv.log" | grep -q -- "--session $sid" || fail "the fourth turn changed session"
  grep -c -- '--hook pre_complete=' "$dir/argv.log" | grep -qx 4 || fail "every run must carry the evidence gate"
  grep -c -- '--hook post_tool_use=' "$dir/argv.log" | grep -qx 4 || fail "every run must carry the progress hook"
  grep -c -- '--model codex/gpt-5.6-luna' "$dir/argv.log" | grep -qx 4 || fail "every run must carry the model"
  assert_grep 'echo: /exit' "$dir/pane.out" "/exit must be delivered as an ordinary Deck prompt"
  assert_grep 'echo: second' "$dir/pane.out" "the pane did not render the turn's text"
  pass "fm-deck-worker: the brief and later prompts are turns of one Deck session with hooks and model"
}

test_turns_drive_the_busy_record_and_turn_end() {
  local dir="$TMP_ROOT/busy" rec
  make_fake_deck "$dir"
  run_worker "$dir" $'/quit\n' || fail "the driver did not exit cleanly"
  [ -f "$dir/state/t1.turn-ended" ] || fail "a finished turn did not touch the turn-end notification"
  rec=$(cat "$dir/state/t1.busy-state")
  assert_contains "$rec" "source=deck-wrapper" "the busy record was not written by the deck driver"
  assert_contains "$rec" "state=idle" "the busy record did not close idle"
  assert_contains "$rec" "event=session-end" "/quit did not record session-end"
  [ "$(fm_busy_classify tmux fake deck t1 "$dir/state")" = "idle deck-wrapper" ] \
    || fail "busy-lib does not trust the deck driver's record: $(fm_busy_classify tmux fake deck t1 "$dir/state")"
  [ "$(fm_busy_classify tmux fake agy t1 "$dir/state")" = "unknown source-mismatch" ] \
    || fail "the deck driver's record must not classify another adapter"
  pass "fm-deck-worker: turns open and close the deck-wrapper busy record and touch turn-end"
}

test_busy_state_failures_stop_turns_and_publish_status() {
  local start="$TMP_ROOT/busy-start-failure" close="$TMP_ROOT/busy-close-failure" old_gen rc
  make_fake_deck "$start"
  mkdir -p "$start/state"
  old_gen=$("$BUSY_EVENT" arm "$start/state" t1)
  "$BUSY_EVENT" arm "$start/state" t1 >/dev/null
  rc=0
  printf '/quit\n' | FM_TEST_STATUS="$start/state/t1.status" FM_TEST_EXTERNAL='' \
    FM_TEST_BUSY_EVENT="$BUSY_EVENT" \
    "$WORKER" --id t1 --state "$start/state" --gen "$old_gen" \
      --deck "$start/deck" -- the-brief > "$start/pane.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a turn started after its busy-state event was refused"
  [ ! -e "$start/argv.log" ] || fail "Deck ran before the wrapper recorded turn-start"
  assert_grep 'failed: deck wrapper could not record busy-state event (turn-start)' "$start/state/t1.status" \
    "a refused turn-start did not publish a failure status"

  make_fake_deck "$close"
  rc=0
  run_worker "$close" $'/quit\n' 'write-status replace-busy-gen' || rc=$?
  [ "$rc" -ne 0 ] || fail "a stale turn-end busy event was ignored"
  assert_grep 'done: wrote evidence' "$close/state/t1.status" \
    "the close-event fixture did not publish its normal turn evidence"
  assert_grep 'failed: deck wrapper could not record busy-state event (turn-end)' "$close/state/t1.status" \
    "a refused turn-end did not publish a failure status"
  assert_grep 'could not record busy-state event turn-end' "$close/pane.out" \
    "a refused turn-end was not surfaced in the worker pane"
  pass "fm-deck-worker: busy-state failures stop turns and publish status evidence"
}

test_turnend_signal_refuses_unsafe_paths() {
  local linked="$TMP_ROOT/turnend-symlink" irregular="$TMP_ROOT/turnend-directory" rc
  make_fake_deck "$linked"
  mkdir -p "$linked/state"
  ln -s "$linked/external-signal" "$linked/state/t1.turn-ended"
  rc=0
  run_worker "$linked" $'/quit\n' write-status || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked turn-end signal was accepted"
  [ ! -e "$linked/external-signal" ] || fail "the turn-end publisher followed a symlink target"
  [ -L "$linked/state/t1.turn-ended" ] || fail "the unsafe turn-end symlink was replaced"
  assert_grep 'could not safely publish turn-end signal' "$linked/pane.out" \
    "the turn-end symlink refusal was not reported"

  make_fake_deck "$irregular"
  mkdir -p "$irregular/state/t1.turn-ended"
  rc=0
  run_worker "$irregular" $'/quit\n' write-status || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-regular turn-end signal was accepted"
  [ -d "$irregular/state/t1.turn-ended" ] || fail "the non-regular turn-end target was replaced"
  pass "fm-deck-worker: turn-end publication refuses unsafe targets"
}

test_evidence_gate_refuses_a_turn_without_a_status_line() {
  local dir="$TMP_ROOT/gate"
  make_fake_deck "$dir"
  run_worker "$dir" $'write-status please\n/quit\n' || fail "the driver did not exit cleanly"
  [ "$(sed -n 1p "$dir/gate.log")" = refused ] || fail "a turn that wrote no status line passed the evidence gate"
  [ "$(sed -n 2p "$dir/gate.log")" = pass ] || fail "a turn that appended a status line was refused"
  assert_grep 'append one line to' "$dir/gate.err" "the refusal did not tell the worker what evidence to write"
  pass "fm-deck-worker: the evidence gate refuses a silent turn and passes one that reported"
}

test_stderr_before_completion_blocked_does_not_break_rendering() {
  local dir="$TMP_ROOT/stderr-before-blocked"
  make_fake_deck "$dir"
  run_worker "$dir" $'/quit\n' recover-after-refusal || fail "the refused turn did not recover and finish"
  [ "$(sed -n 1p "$dir/gate.log")" = refused ] || fail "the fixture did not refuse the first completion attempt"
  [ "$(sed -n 2p "$dir/gate.log")" = pass ] || fail "the recovered completion attempt did not pass"
  assert_grep 'pre_complete hook rejected completion' "$dir/pane.out" "Deck stderr was not preserved outside the event stream"
  assert_grep 'finish refused (attempt 1)' "$dir/pane.out" "the completion_blocked event did not render after Deck wrote stderr"
  assert_grep 'turn finished (1 model calls)' "$dir/pane.out" "the recovered turn did not render its completion"
  [ "$(cat "$dir/state/t1.status")" = 'done: recovered after refusal' ] \
    || fail "the recovered turn was replaced with failure evidence"
  pass "fm-deck-worker: Deck stderr cannot break completion-blocked rendering"
}

test_bookkeeping_lines_do_not_satisfy_turn_evidence() {
  local dir="$TMP_ROOT/bookkeeping-evidence"
  make_fake_deck "$dir"
  run_worker "$dir" $'/quit\n' resolve-only || fail "the bookkeeping-only turn did not return to /quit"
  [ "$(cat "$dir/gate.log")" = refused ] || fail "a resolved line satisfied Deck's pre-complete evidence gate"
  [ "$(sed -n 1p "$dir/state/t1.status")" = 'resolved [key=choice]: answered: yes' ] \
    || fail "the fixture did not append its Firstmate-owned bookkeeping line"
  [ "$(sed -n 2p "$dir/state/t1.status")" = 'failed: deck turn ended without a status line (turn-end)' ] \
    || fail "the wrapper postcondition treated a resolved line as worker evidence"
  pass "fm-deck-worker: Firstmate bookkeeping cannot satisfy worker evidence"
}

test_status_checks_and_fallbacks_refuse_unsafe_paths() {
  local linked="$TMP_ROOT/status-symlink" replaced="$TMP_ROOT/status-replaced" irregular="$TMP_ROOT/status-directory" rc
  make_fake_deck "$linked"
  mkdir -p "$linked/state"
  printf 'protected\n' > "$linked/external"
  ln -s "$linked/external" "$linked/state/t1.status"
  rc=0
  run_worker "$linked" $'/quit\n' > /dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked Deck status path was accepted"
  if printf 'failed: fallback must not land\n' | python3 "$ROOT/bin/fm-state-io.py" \
    root-append "$linked/state" t1.status >/dev/null 2>&1; then
    fail "the Deck fallback append accepted a symlinked status path"
  fi
  [ "$(cat "$linked/external")" = protected ] || fail "a status check or fallback append touched a symlink target"
  [ ! -e "$linked/argv.log" ] || fail "Deck ran after the initial status path failed validation"

  make_fake_deck "$replaced"
  mkdir -p "$replaced/state"
  printf 'protected\n' > "$replaced/external"
  ln -s "$replaced/external-signal" "$replaced/state/t1.turn-ended"
  rc=0
  FM_TEST_EXTERNAL="$replaced/external" run_worker "$replaced" $'/quit\n' replace-status || rc=$?
  [ "$rc" -ne 0 ] || fail "a status path replaced by a symlink during the turn was accepted"
  [ "$(cat "$replaced/external")" = protected ] || fail "the evidence fallback followed a replacement symlink"
  [ ! -e "$replaced/external-signal" ] || fail "the failed-evidence path followed a turn-end symlink"
  assert_grep 'could not safely publish turn-end signal' "$replaced/pane.out" \
    "the failed-evidence path did not report its turn-end refusal"

  make_fake_deck "$irregular"
  mkdir -p "$irregular/state/t1.status"
  rc=0
  run_worker "$irregular" $'/quit\n' > /dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-regular Deck status path was accepted"
  pass "fm-deck-worker: status evidence never follows symlinked or non-regular paths"
}

test_driver_backstops_silent_and_failed_turns() {
  local silent="$TMP_ROOT/postcondition-silent" failed="$TMP_ROOT/postcondition-failed"
  make_fake_deck "$silent"
  run_worker "$silent" $'/quit\n' || fail "the silent-turn driver did not exit cleanly"
  [ "$(cat "$silent/state/t1.status")" = 'failed: deck turn ended without a status line (turn-end)' ] \
    || fail "a silently completed turn did not receive the exact fallback status: $(cat "$silent/state/t1.status")"
  assert_not_contains "$(cat "$silent/pane.out")" "No such file or directory" "a missing status log leaked a turn-start read error into the pane"
  [ -f "$silent/state/t1.turn-ended" ] || fail "the silent turn did not publish turn-ended after its fallback status"

  make_fake_deck "$failed"
  run_worker "$failed" $'/quit\n' 'fail-turn' || fail "the failed-turn driver did not remain available for /quit"
  [ "$(cat "$failed/state/t1.status")" = 'failed: deck turn ended without a status line (turn-failed)' ] \
    || fail "a provider-failed turn did not receive the exact fallback status: $(cat "$failed/state/t1.status")"
  [ -f "$failed/state/t1.turn-ended" ] || fail "the provider-failed turn did not publish turn-ended after its fallback status"
  pass "fm-deck-worker: silent and failed turns gain status evidence before turn-end"
}

test_ctrl_c_cancels_the_turn_and_returns_to_the_prompt() {
  local dir="$TMP_ROOT/interrupt" gen pid sleeper ready=0 pgid
  make_fake_deck "$dir"
  mkdir -p "$dir/state"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  mkfifo "$dir/in"
  # Hold stdin open without a timer: after cancellation the driver must remain
  # at its prompt until this test deliberately closes the writer.
  exec 3<>"$dir/in"
  # A terminal's Ctrl+C signals the pane's whole foreground process group, so
  # the driver gets a group of its own (job control) and the group is signalled.
  # Reset SIGINT before exec because a bounded test runner may itself have been
  # launched asynchronously, while a real terminal-launched pane is not.
  set -m
  FM_TEST_STATUS="$dir/state/t1.status" python3 -c \
    'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" \
      --deck "$dir/deck" -- "please sleep" < "$dir/in" > "$dir/pane.out" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 50); do
    sleeper=$(cat "$dir/interrupt-ready" 2>/dev/null || true)
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    if grep -q 'state=busy' "$dir/state/t1.busy-state" 2>/dev/null \
      && [ "$pgid" = "$pid" ] && kill -0 "$sleeper" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.1
  done
  [ "$ready" -eq 1 ] || fail "the Deck turn never reached its interruptible child process"
  kill -INT -- -"$pid" 2>/dev/null || fail "could not signal the Deck worker process group"
  for _ in $(seq 50); do grep -q 'event=interrupted' "$dir/state/t1.busy-state" 2>/dev/null && break; sleep 0.1; done
  assert_grep 'event=interrupted' "$dir/state/t1.busy-state" "Ctrl+C did not close the turn as interrupted"
  [ "$(cat "$dir/state/t1.status")" = 'failed: deck turn ended without a status line (interrupted)' ] \
    || fail "an interrupted turn did not receive the exact fallback status: $(cat "$dir/state/t1.status")"
  for _ in $(seq 50); do [ -f "$dir/state/t1.turn-ended" ] && break; sleep 0.1; done
  [ -f "$dir/state/t1.turn-ended" ] || fail "the interrupted turn did not publish turn-ended after its fallback status"
  kill -0 "$pid" 2>/dev/null || fail "the driver exited on Ctrl+C instead of returning to its prompt"
  assert_grep 'Interrupted.' "$dir/pane.out" "the pane did not show the cancelled turn"
  kill -TERM -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  exec 3>&-
  pass "fm-deck-worker: Ctrl+C records evidence and returns the worker to its prompt"
}

test_completed_turn_removes_busy_ack_before_the_next_steer() {
  local dir="$TMP_ROOT/second-steer" session="fm-deck-second-$$" target command capture last rc gen
  command -v tmux >/dev/null 2>&1 || { pass "fm-deck-worker: second-steer terminal regression skipped without tmux"; return; }
  make_fake_deck "$dir"
  mkdir -p "$dir/state"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  printf -v command 'exec env FM_TEST_STATUS=%q %q --id t1 --state %q --gen %q --deck %q -- %q' \
    "$dir/state/t1.status" "$WORKER" "$dir/state" "$gen" "$dir/deck" 'write-status prior ctrl+c to stop'
  tmux new-session -d -s "$session" -n deck -x 100 -y 30 "$command" || fail "could not start the Deck terminal fixture"
  target="$session:deck"
  printf 'window=%s\nbackend=tmux\nharness=deck\nkind=ship\n' "$target" > "$dir/state/t1.meta"
  for _ in $(seq 80); do
    capture=$(tmux capture-pane -p -t "$target" -S -30 2>/dev/null || true)
    last=$(printf '%s\n' "$capture" | awk 'NF { line=$0 } END { print line }')
    [ "$last" = '❯' ] && break
    sleep 0.05
  done
  if [ "$last" != '❯' ]; then
    tmux kill-session -t "$session" 2>/dev/null
    fail "the Deck fixture never reached its first idle prompt"
  fi
  assert_not_contains "$capture" '⛵ deck working - ctrl+c to stop' "a completed Deck turn left a stale busy acknowledgement"
  assert_contains "$capture" 'echo: write-status prior ctrl+c to stop' \
    "the fixture did not retain rendered text containing the generic busy token"

  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" "$target" 'write-status slow first steer' >/dev/null 2>"$dir/first.err" || rc=$?
  expect_code 0 "$rc" "the first Deck steer was not confirmed: $(cat "$dir/first.err")"
  for _ in $(seq 80); do
    capture=$(tmux capture-pane -p -t "$target" -S -30 2>/dev/null || true)
    last=$(printf '%s\n' "$capture" | awk 'NF { line=$0 } END { print line }')
    if [ "$(grep -c '^done: wrote evidence$' "$dir/state/t1.status" 2>/dev/null || true)" -ge 2 ] \
      && [ "$last" = '❯' ]; then
      break
    fi
    sleep 0.05
  done
  [ "$last" = '❯' ] || fail "the first Deck steer did not return to its idle prompt"
  assert_not_contains "$capture" 'deck working - ctrl+c to stop' "the first steer left its busy acknowledgement in the idle pane"

  rc=0
  FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" FM_SEND_SETTLE=0 FM_SEND_SLEEP=0.05 \
    "$ROOT/bin/fm-send.sh" "$target" 'write-status slow second steer' >/dev/null 2>"$dir/second.err" || rc=$?
  tmux send-keys -t "$target" -l /quit 2>/dev/null || true
  tmux send-keys -t "$target" Enter 2>/dev/null || true
  for _ in $(seq 60); do
    tmux has-session -t "$session" 2>/dev/null || break
    sleep 0.05
  done
  tmux kill-session -t "$session" 2>/dev/null || true
  expect_code 0 "$rc" "the second Deck steer was not confirmed from an idle baseline: $(cat "$dir/second.err")"
  pass "fm-deck-worker: each completed turn leaves the next steer an idle baseline"
}

test_liveness_reads_the_driver_as_an_agent() {
  [ "$(fm_agent_process_classify bash fm-deck-worker '')" = agent ] || fail "the driver's argv[0] must read as an agent"
  [ "$(fm_agent_process_classify fm-deck-worker fm-deck-worker '')" = agent ] || fail "the driver's macOS process name must read as an agent"
  [ "$(fm_agent_process_classify deck deck '')" = agent ] || fail "the deck binary must read as an agent"
  [ "$(fm_agent_process_classify decker decker '')" = other ] || fail "an unrelated name containing deck was claimed"
  [ "$(fm_agent_process_classify bash bash '')" = shell ] || fail "a plain shell must still read as a shell"
  pass "liveness: the deck driver and binary are agents, unrelated names are not"
}

test_tmux_liveness_uses_the_deck_driver_argv0() {
  local state
  state=$(
    # shellcheck disable=SC2329 # Runtime override invoked indirectly by the tmux liveness classifier.
    fm_backend_tmux_window_presence() { printf 'present'; }
    # shellcheck disable=SC2329 # Runtime override invoked indirectly by the tmux liveness classifier.
    fm_backend_tmux_foreground_comms() { printf 'bash\n'; }
    # shellcheck disable=SC2329 # Runtime override invoked indirectly by the tmux liveness classifier.
    fm_backend_tmux_foreground_argv0s() { printf 'fm-deck-worker\n'; }
    # shellcheck disable=SC2329 # Runtime override invoked indirectly by the tmux liveness classifier.
    fm_backend_tmux_foreground_pids() { :; }
    # shellcheck disable=SC2329 # Runtime override invoked indirectly by the tmux liveness classifier.
    fm_backend_tmux_foreground_args() { :; }
    # shellcheck disable=SC2329 # Runtime override invoked indirectly by the tmux liveness classifier.
    fm_backend_tmux_current_command() { printf 'bash\n'; }
    fm_backend_tmux_agent_state session:deck
  )
  [ "$state" = alive ] || fail "tmux reported comm=bash with argv[0]=fm-deck-worker as $state"
  pass "tmux liveness: Deck's Linux comm and argv0 classify alive"
}

test_control_busy_and_delivery_tables_name_deck() {
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_harness_process_matches fm-deck-worker fm-deck-worker || fail "driver comm cannot own a lock"
  fm_harness_process_matches bash 'fm-deck-worker script' || fail "driver argv0 cannot own a lock"
  fm_harness_process_matches deck deck && fail "transient Deck run must not own a home lock"
  fm_control_harness_supported deck || fail "deck is not a supported control harness"
  [ "$(fm_control_harness_family deck)" = deck ] || fail "deck family"
  fm_control_harness_supports_kind deck ship || fail "deck must run ship tasks"
  fm_control_harness_supports_kind deck secondmate || fail "deck must run secondmates"
  [ "$(fm_control_interrupt_key deck)" = C-c ] || fail "deck interrupts on Ctrl+C"
  [ "$(fm_control_interrupt_repeat deck)" = 1 ] || fail "deck interrupt repeat"
  [ "$(fm_control_exit_command deck)" = /quit ] || fail "deck exits with /quit"
  fm_busy_source_trusted deck deck-wrapper || fail "busy-lib must trust deck-wrapper for deck"
  fm_busy_source_trusted claude deck-wrapper && fail "deck-wrapper must not be trusted for claude"
  printf '⛵ deck working - ctrl+c to stop\n' | fm_busy_lines_match deck \
    && fail "rendered Deck output was accepted as delivery evidence"
  pass "control and busy-source tables carry Deck mechanics without rendered delivery evidence"
}

test_deck_supervision_model_is_scoped_to_secondmate_launches() {
  local bin="$TMP_ROOT/named-model" out
  mkdir -p "$bin"
  ln -sf /bin/bash "$bin/deck"
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u CLAUDECODE -u PI_CODING_AGENT -u FM_PI_HARNESS -u GROK_AGENT \
    -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI -u FM_OMP_HARNESS \
    -u FM_SUPERVISION_MODEL "$bin/deck" -c '. "$1"; fm_supervision_model; :' \
    _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = persistent ] || fail "a Deck-named main process received the secondmate supervision model: $out"
  out=$(FM_SUPERVISION_MODEL=autoarm bash -c '. "$1"; fm_supervision_model' \
    _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = autoarm ] || fail "the scoped Deck secondmate supervision override was ignored: $out"
  pass "Deck supervision autoarm remains scoped to secondmate launches"
}

# --- spawn ------------------------------------------------------------------
make_deck_spawn_case() {  # <name> <id> -> "<case>|<home>|<proj>|<wt>|<fakebin>"
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"; home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    prev=; for arg in "$@"; do [ "$prev" = -l ] && printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"; prev=$arg; done
    exit 0 ;;
  capture-pane) printf '⛵ deck working - ctrl+c to stop\n'; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\necho "fake deck must never execute" >&2; exit 9\n' > "$fakebin/deck"
  chmod +x "$fakebin/tmux" "$fakebin/deck"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '# Task\n## Captain'"'"'s intent\nExercise Deck dispatch.\n\n## Firstmate spec\nVerify launch.\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"; : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

JQ_DIR=$(dirname "$(command -v jq)")
run_deck_spawn() {  # <case> <home> <proj> <wt> <fakebin> <id> [args...]
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    PATH="$fakebin:$JQ_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$proj" --harness deck --mode no-mistakes --yolo off "$@" 2>&1
}

test_spawn_launches_the_driver_with_binary_gen_and_model() {
  local id rec out rc launch meta case_dir home proj wt fakebin
  id="deck-launch-$$"
  rec=$(make_deck_spawn_case launch "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_deck_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" --model codex/gpt-5.6-luna)
  rc=$?
  expect_code 0 "$rc" "ordinary Deck spawn should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" "exec -a fm-deck-worker bash" "the driver must run under its own argv[0]"
  assert_contains "$launch" "$ROOT/bin/fm-deck-worker.sh" "the launch did not run the deck driver"
  assert_contains "$launch" "--deck '$fakebin/deck'" "the launch did not pin the resolved deck binary"
  assert_contains "$launch" "--model 'codex/gpt-5.6-luna'" "the launch did not carry the model"
  assert_contains "$launch" "--id '$id'" "the launch did not name the task"
  assert_not_contains "$launch" "--turnend" "the launch passed a redundant turn-end path"
  assert_not_contains "$launch" "--effort" "deck has no effort control; effort must not be passed"
  assert_not_contains "$launch" "__DECK" "the launch left a deck placeholder unsubstituted"
  meta="$home/state/$id.meta"
  assert_grep 'harness=deck' "$meta" "meta did not record the deck harness"
  assert_grep 'effort=default' "$meta" "meta must not imply Deck applies an effort"
  [ -s "$home/state/$id.busy-gen" ] || fail "the spawn did not arm the busy contract"
  assert_contains "$launch" "--gen '$(cat "$home/state/$id.busy-gen")'" "the launch did not carry the armed busy gen"
  pass "fm-spawn: ordinary Deck dispatch records only default effort"
}

test_spawn_refuses_deck_effort() {
  local id rec out rc case_dir home proj wt fakebin
  id="deck-effort-$$"
  rec=$(make_deck_spawn_case effort "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_deck_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" --effort high)
  rc=$?
  [ "$rc" -ne 0 ] || fail "Deck spawn accepted unsupported effort control"
  assert_contains "$out" "deck has no effort control" "the Deck effort refusal must explain the unsupported axis"
  [ ! -s "$case_dir/launch.log" ] || fail "Deck effort refusal launched a worker"
  [ ! -e "$home/state/$id.meta" ] || fail "Deck effort refusal wrote misleading task metadata"
  pass "fm-spawn: Deck refuses unsupported effort before launch metadata"
}


test_secondmate_host_serializes_wakes_and_steering() {
  local dir="$TMP_ROOT/host"
  mkdir -p "$dir/home/state" "$dir/parent" "$dir/bin"
  cp -R "$ROOT/bin/." "$dir/bin/"
  cat > "$dir/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf 'startup\n' >> "$FM_HOME/startups"
[ "${FM_TEST_START_FAIL:-0}" = 0 ] || exit 7
"$(dirname "$0")/fm-lock.sh"
cat "$FM_HOME/state/.lock" > "$FM_HOME/state/.session-start-complete"
printf 'complete startup digest marker\n'
SH
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'generation=%s watcher=%s\n' "$2" "$4" >> "$FM_HOME/handling-delivered"
  exit 0
fi
trap 'exit 143' TERM INT
printf '%s\n' "$$" >> "$FM_HOME/watch-starts"
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "$FM_HOME/watch-arms"
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  printf 'watcher: started pid=%s (beacon fresh) recovery-generation=deck-%s\n' "$$" "$FM_WATCH_PREDECESSOR_ARM_PID"
else
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
fi
while [ ! -f "$FM_HOME/trigger" ]; do sleep 0.1; done
rm "$FM_HOME/trigger"
printf 'check: example\n'
[ "${FM_TEST_WATCH_FAIL:-0}" = 0 ]
SH
  cat > "$dir/deck" <<'PYTHON'
#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
home = pathlib.Path(os.environ['FM_HOME'])
args = sys.argv[1:]
prompt = args[1]
session = args[args.index('--session') + 1] if '--session' in args else 'host-session'
inbox = pathlib.Path(__file__).parent / 'parent/host.inbox'
records = list(sorted(inbox.glob('*.msg'))) if 'Firstmate instruction waiting:' in prompt else []
body = ''.join(record.read_text() for record in records)
if records:
    deadline = time.time() + 2
    while time.time() < deadline:
        starts = (home / 'watch-starts').read_text().splitlines() if (home / 'watch-starts').exists() else []
        delivered = (home / 'handling-delivered').read_text().splitlines() if (home / 'handling-delivered').exists() else []
        if len(starts) >= 2 and delivered:
            break
        time.sleep(.05)
    assert len(starts) >= 2, 'next watcher cycle did not start before wake handling'
    assert delivered, 'successor watcher handling was not confirmed before wake handling'
    successor = int(delivered[-1].split(' watcher=', 1)[1])
    (home / 'wake-turn-active').touch()
    time.sleep(2)
    os.kill(successor, 0)
with (home / 'turns').open('a') as f:
    f.write(json.dumps({'prompt': prompt, 'session': session, 'inbox': body}) + '\n')
for record in records:
    record.rename(inbox / 'handled' / record.name)
print(json.dumps({'type': 'run_started', 'session': session}), flush=True)
if os.environ.get('FM_TEST_TURN_FAIL') == '1':
    print(json.dumps({'type': 'run_failed', 'error': 'injected'}), flush=True)
    sys.exit(9)
if prompt == 'slow-steer':
    (home / 'in-turn').touch()
    while not (home / 'release').exists():
        time.sleep(.1)
for i, arg in enumerate(args):
    if arg == '--hook' and args[i+1].startswith('pre_complete='):
        result = subprocess.run(args[i+1].split('=', 1)[1], shell=True)
        if result.returncode:
            sys.exit(result.returncode)
print(json.dumps({'type': 'run_finished', 'turns': 1}), flush=True)
PYTHON
  chmod +x "$dir/bin/fm-session-start.sh" "$dir/bin/fm-watch-arm.sh" "$dir/deck"
  python3 - "$dir" <<'PYTHON' || fail "Deck secondmate host integration failed"
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
home = root / 'home'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
def rows():
    path = home/'turns'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
def wait_for(check, label):
    for _ in range(200):
        if check(): return
        if p.poll() is not None: raise AssertionError('host exited: '+(root/'pane').read_text())
        time.sleep(.1)
    raise AssertionError(label+': '+(root/'pane').read_text())
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env, text=True, start_new_session=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    try:
        wait_for(lambda: len(rows()) == 1, 'first turn')
        assert 'complete startup digest marker' in rows()[0]['prompt']
        assert not (root/'parent/host.turn-ended').exists(), 'silent startup emitted a parent turn-end wake'
        p.stdin.write('slow-steer\n'); p.stdin.flush()
        wait_for(lambda: (home/'in-turn').exists(), 'steer start')
        (home/'trigger').touch()
        time.sleep(.5)
        assert len(rows()) == 2, 'watcher ran a concurrent turn'
        (home/'release').touch()
        wait_for(lambda: len(rows()) == 3, 'deferred wake')
        assert 'Firstmate instruction waiting:' in rows()[2]['prompt']
        assert 'actionable wake' in rows()[2]['inbox']
        assert list((root/'parent/host.inbox/handled').glob('*.msg'))
        assert 'predecessor=none' not in (home/'watch-arms').read_text().splitlines()[1], 'successor lost its predecessor arm'
        assert not (root/'parent/host.turn-ended').exists(), 'watch handling emitted a parent turn-end wake'
        p.stdin.write('split-'); p.stdin.flush()
        time.sleep(1.3)
        p.stdin.write('steer\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 4, 'partial input retained')
        assert rows()[3]['prompt'] == 'split-steer'
        (home/'trigger').touch()
        wait_for(lambda: len(rows()) == 5, 'watcher rearmed')
        assert all(x['session'] == 'host-session' for x in rows())
        assert (home/'startups').read_text() == 'startup\n'
        assert (home/'state/.lock').read_text().strip() == str(p.pid), 'lock is not driver-owned'
        assert not (root/'parent/host.status').exists(), 'idle supervisor manufactured status'
        (home/'in-turn').unlink()
        (home/'release').unlink()
        p.stdin.write('slow-steer\n'); p.stdin.flush()
        wait_for(lambda: (home/'in-turn').exists(), 'interruptible steer')
        os.killpg(p.pid, signal.SIGINT)
        p.stdin.write('after-interrupt\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 7, 'driver survived interrupt')
        assert rows()[6]['prompt'] == 'after-interrupt'
        assert 'turn interrupted' in (root/'parent/host.status').read_text()
        (home/'trigger').touch()
        wait_for(lambda: len(rows()) == 8, 'watcher survived interrupt')
        p.stdin.write('/quit\n'); p.stdin.flush()
        assert p.wait(timeout=15) == 0
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
for key in ['FM_TEST_START_FAIL', 'FM_TEST_TURN_FAIL', 'FM_TEST_WATCH_FAIL']:
    failure_env = dict(env, **{key: '1'})
    (root/'parent/host.status').unlink(missing_ok=True)
    (home/'trigger').touch()
    with (root/'failure-pane').open('w') as output:
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=failure_env, text=True)
        try:
            assert p.wait(timeout=20) != 0, key+' was swallowed'
            assert 'failed: Deck secondmate' in (root/'parent/host.status').read_text(), key+' not reported'
        finally:
            if p.poll() is None:
                p.terminate(); p.wait(timeout=15)
PYTHON
  pass "Deck host preserves handling-successor supervision without parent turn-end wakes"
}

test_secondmate_host_serializes_wakes_and_steering
test_turns_share_one_session_and_carry_the_hooks
test_turns_drive_the_busy_record_and_turn_end
test_busy_state_failures_stop_turns_and_publish_status
test_turnend_signal_refuses_unsafe_paths
test_evidence_gate_refuses_a_turn_without_a_status_line
test_stderr_before_completion_blocked_does_not_break_rendering
test_bookkeeping_lines_do_not_satisfy_turn_evidence
test_status_checks_and_fallbacks_refuse_unsafe_paths
test_driver_backstops_silent_and_failed_turns
test_ctrl_c_cancels_the_turn_and_returns_to_the_prompt
test_completed_turn_removes_busy_ack_before_the_next_steer
test_liveness_reads_the_driver_as_an_agent
test_tmux_liveness_uses_the_deck_driver_argv0
test_control_busy_and_delivery_tables_name_deck
test_deck_supervision_model_is_scoped_to_secondmate_launches
test_spawn_launches_the_driver_with_binary_gen_and_model
test_spawn_refuses_deck_effort
echo "fm-deck-harness: all cases passed"
