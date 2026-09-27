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
#      launches use the same driver with home-host supervision. A persistent
#      secondmate records a failed turn and returns to its prompt with its
#      session and watcher intact, on the first turn as well as later ones,
#      repeats its launch brief once when a failure left it with no session at
#      all, and stops when that repeat opens no session either, while a crewmate
#      keeps its own behavior and a failure the driver cannot publish still
#      stops it.
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
prompt=$2; session=''; gate=''; progress=''
while [ $# -gt 0 ]; do
  case "$1" in
    --session) session=$2; shift 2 ;;
    --hook) case "$2" in pre_complete=*) gate=${2#pre_complete=} ;; post_tool_use=*) progress=${2#post_tool_use=} ;; esac; shift 2 ;;
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
  *legacy-finish-write-status*) printf 'done: wrote evidence\n' >> "$FM_TEST_STATUS" ;;
  *write-status*) printf 'done: wrote evidence\n' >> "$FM_TEST_STATUS" ;;
  *resolve-only*) printf 'resolved [key=choice]: answered: yes\n' >> "$FM_TEST_STATUS" ;;
  *sleep*)
    bash -c 'printf "%s\n" "$$" > "$1/interrupt-ready"; exec sleep 30' _ "$dir"
    ;;
esac
[ -z "$progress" ] || bash -c "$progress" </dev/null || true
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
  *legacy-finish*) printf '{"type":"run_finished","output":"x","turns":1}\n' ;;
  *) printf '{"type":"run_finished","output":"x","turns":1,"finished_at":1790269292}\n' ;;
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

  assert_grep 'stale busy-state gen for t1' "$start/state/t1.status" \
    "the underlying busy-event stderr was discarded from status"
  assert_grep 'stale busy-state gen for t1' "$start/pane.out" \
    "the underlying busy-event stderr was discarded from the pane"
  make_fake_deck "$close"
  rc=0
  run_worker "$close" $'/quit\n' 'write-status replace-busy-gen' || rc=$?
  [ "$rc" -ne 0 ] || fail "a stale turn-end busy event was ignored"
  assert_grep 'done: wrote evidence' "$close/state/t1.status" \
    "the close-event fixture did not publish its normal turn evidence"
  assert_grep 'failed: deck wrapper could not record busy-state event (turn-end)' "$close/state/t1.status" \
    "a refused turn-end did not publish a failure status"
  assert_grep 'failed: deck wrapper could not refresh progress: error: stale busy-state gen' "$close/state/t1.status" \
    "the progress hook discarded its failure diagnostic"
  assert_grep 'stale busy-state gen for t1' "$close/pane.out" \
    "the progress hook discarded stderr from the pane"
  assert_grep 'could not record busy-state event turn-end' "$close/pane.out" \
    "a refused turn-end was not surfaced in the worker pane"
  pass "fm-deck-worker: busy-state failures stop turns and publish status evidence"
}

test_finished_turn_renders_the_utc_completion_time() {
  local dir="$TMP_ROOT/finish-time" legacy="$TMP_ROOT/finish-time-legacy"
  make_fake_deck "$dir"
  run_worker "$dir" $'/quit\n' write-status || fail "the driver did not exit cleanly"
  assert_grep 'turn finished 2026-09-24T17:01Z (1 model calls)' "$dir/pane.out" \
    "the finished turn did not carry the UTC completion time from run_finished.finished_at"
  assert_no_grep 'turn finished (' "$dir/pane.out" \
    "the finished turn rendered the timestamp-less legacy wording while finished_at was present"

  make_fake_deck "$legacy"
  run_worker "$legacy" $'/quit\n' legacy-finish-write-status || fail "the legacy driver run did not exit cleanly"
  assert_grep 'turn finished (1 model calls)' "$legacy/pane.out" \
    "a run_finished without finished_at did not fall back to the timestamp-less wording"
  assert_no_grep 'turn finished 2026-' "$legacy/pane.out" \
    "a run_finished without finished_at invented a completion time"
  pass "fm-deck-worker: the finished-turn line carries the UTC completion time and degrades safely without it"
}

test_idle_prompt_notes_the_utc_idle_instant() {
  local dir="$TMP_ROOT/idle-note" before after note stamp last
  make_fake_deck "$dir"
  before=$(date -u +%Y-%m-%dT%H:%MZ)
  run_worker "$dir" $'/quit\n' write-status || fail "the driver did not exit cleanly"
  after=$(date -u +%Y-%m-%dT%H:%MZ)
  note=$(grep -E '^idle since [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$' "$dir/pane.out" | tail -1)
  [ -n "$note" ] || fail "the idle prompt did not note when the worker went idle"
  stamp=${note#idle since }
  [ "$stamp" = "$before" ] || [ "$stamp" = "$after" ] \
    || fail "the idle-since note did not carry the turn's UTC end instant: $stamp (turn ran between $before and $after)"
  last=$(tail -1 "$dir/pane.out")
  case "$last" in
    '❯'|'❯ ') ;;
    *) fail "the prompt row is no longer the bare ❯ glyph row the shared composer contract reads: $last" ;;
  esac
  [ "$(tail -2 "$dir/pane.out" | sed -n 1p)" = "$note" ] \
    || fail "the idle-since note does not sit on the line beside the ❯ prompt"
  pass "fm-deck-worker: the idle prompt notes the UTC idle instant beside the bare ❯ prompt"
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
  assert_grep 'turn finished 2026-09-24T17:01Z (1 model calls)' "$dir/pane.out" "the recovered turn did not render its completion with the UTC finish time"
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
  assert_not_contains "$(cat "$failed/pane.out")" 'waiting at the prompt for the next wake' \
    "a crewmate turn failure took the persistent secondmate's survival path"
  pass "fm-deck-worker: silent and failed turns gain status evidence before turn-end"
}

test_idle_interrupt_does_not_echo_fake_input() {
  local dir="$TMP_ROOT/idle-interrupt" gen
  make_fake_deck "$dir"
  mkdir -p "$dir/state"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  python3 - "$ROOT" "$dir" "$gen" <<'PY' || fail "idle terminal control-echo regression failed"
import importlib.util, os, pathlib, select, sys, termios, time
root, directory, gen = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
spec = importlib.util.spec_from_file_location('stream_agent', root / 'bin/fm-stream-agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
env = dict(os.environ, FM_TEST_STATUS=str(directory/'state/t1.status'), FM_TEST_EXTERNAL='')
p = agent.Pty(str(directory), [str(root/'bin/fm-deck-worker.sh'), '--id', 't1',
    '--state', str(directory/'state'), '--gen', gen, '--deck', str(directory/'deck'),
    '--', 'write-status'], 40, 200, env)
def read_ready():
    return p.read() if select.select([p.master_fd], [], [], .1)[0] else b''
try:
    output = b''
    for _ in range(100):
        output += read_ready()
        if '❯ '.encode() in output: break
        time.sleep(.1)
    assert '❯ '.encode() in output, repr(output)
    flags = termios.tcgetattr(p.master_fd)[3]
    assert flags & termios.ISIG, 'Ctrl+C must still deliver SIGINT'
    assert flags & termios.ECHO, 'ordinary typed input must remain visible'
    assert not flags & termios.ECHOCTL, 'control-key echo would masquerade as pending input'
    p.write(b'\x03')
    echoed = b''.join(read_ready() for _ in range(10))
    assert b'^C' not in echoed, repr(echoed)
    assert p.alive(), 'idle interrupt stopped the driver'
    p.write(b'visible partial input')
    echoed = b''
    for _ in range(50):
        echoed += read_ready()
        if b'visible partial input' in echoed: break
        time.sleep(.1)
    assert b'visible partial input' in echoed, repr(echoed)
finally:
    p.close('TERM')
    p.close('KILL')
    p.release()
PY
  pass "Deck idle Ctrl+C stays a signal, not fake input, while partial input remains visible"
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

test_driver_stop_terminates_active_deck_and_resolves_spaced_paths() {
  local dir="$TMP_ROOT/stop graceful with spaces" install physical alias deck worker stop pid gen rc
  install="$dir/install with spaces/bin"
  physical="$dir/physical state"
  alias="$dir/state alias"
  deck="$dir/deck binary"
  worker="$install/fm-deck-worker.sh"
  stop="$install/fm-deck-stop.py"
  mkdir -p "$install" "$physical"
  cp "$WORKER" "$BUSY_EVENT" "$ROOT/bin/fm-busy-lib.sh" \
    "$ROOT/bin/fm-state-io.py" "$ROOT/bin/fm-deck-stop.py" "$install/"
  ln -s "$physical" "$alias"
  cat > "$deck" <<'PY'
#!/usr/bin/env python3
import json
import os
import time

print(json.dumps({"type": "run_started", "session": "stop-session"}), flush=True)
print(json.dumps({"type": "tool_call", "id": "a", "name": "run_command", "arguments": {"command": "tool-a"}}), flush=True)
open(os.environ["FM_DECK_READY"], "w").close()
time.sleep(10)
open(os.environ["FM_DECK_TOOL_A_COMPLETED"], "w").close()
print(json.dumps({"type": "tool_result", "id": "a", "name": "run_command", "duration_ms": 10000, "output": "tool-a complete"}), flush=True)
open(os.environ["FM_DECK_TOOL_B_STARTED"], "w").close()
print(json.dumps({"type": "tool_call", "id": "b", "name": "run_command", "arguments": {"command": "tool-b"}}), flush=True)
time.sleep(10)
PY
  chmod +x "$deck"
  gen=$("$install/fm-busy-event.sh" arm "$physical" owned)
  FM_DECK_READY="$dir/ready" FM_DECK_TOOL_A_COMPLETED="$dir/tool-a-completed" \
    FM_DECK_TOOL_B_STARTED="$dir/tool-b-started" \
    python3 -c \
      'import os,sys; os.setsid(); os.execv("/bin/bash", ["fm-deck-worker"] + sys.argv[1:])' \
      "$worker" --id owned --state "$(cd "$physical" && pwd -P)" --gen "$gen" \
      --deck "$deck" -- old-brief </dev/null > "$dir/pane.out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [ ! -e "$dir/ready" ] || break; sleep 0.05; done
  [ -e "$dir/ready" ] || fail "post-tool stop fixture did not start"
  python3 "$stop" "$alias" owned 2 \
    || fail "spaced physical paths did not identify and stop the Deck driver"
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "the abruptly TERM-stopped driver reported success"
  [ ! -e "$dir/tool-a-completed" ] || fail "Deck TERM unexpectedly let the active in-process tool complete"
  [ ! -e "$dir/tool-b-started" ] || fail "Deck started another tool after TERM"
  pass "Deck stop: physical aliases and spaced paths stop the active Deck process"
}

test_stale_secondmate_driver_is_stopped_at_relaunch_boundary() {
  local dir="$TMP_ROOT/stop-secondmate" install state worker stop pid
  install="$dir/install/bin"
  state="$dir/state"
  worker="$install/fm-deck-worker.sh"
  stop="$install/fm-deck-stop.py"
  mkdir -p "$install" "$state"
  cp "$ROOT/bin/fm-deck-stop.py" "$stop"
  cat > "$worker" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM
: > "$FM_DECK_READY"
while :; do :; done
SH
  chmod +x "$worker"
  FM_DECK_READY="$dir/ready" python3 -c \
    'import os,sys; os.setsid(); os.execv("/bin/bash", ["fm-deck-worker"] + sys.argv[1:])' \
    "$worker" --secondmate --id stale-host --state "$state" --gen stale-generation \
    --deck "$dir/deck" -- old-charter </dev/null > "$dir/pane.out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [ ! -e "$dir/ready" ] || break; sleep 0.05; done
  [ -e "$dir/ready" ] || fail "stale secondmate driver fixture did not start"
  python3 "$stop" "$state" stale-host 1 \
    || fail "the relaunch boundary refused to stop a stale secondmate driver"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- -"$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the relaunch boundary skipped a stale secondmate driver"
  fi
  wait "$pid" 2>/dev/null || true
  : > "$dir/replacement-armed"
  [ -e "$dir/replacement-armed" ] || fail "replacement was not armed after the secondmate stop proof"
  pass "Deck stop: stale secondmate drivers stop before replacement arming"
}

test_driver_stop_is_scoped_and_escalates_after_timeout() {
  local dir="$TMP_ROOT/stop-escalation" pid gen
  mkdir -p "$dir/state"
  cat > "$dir/deck" <<'PY'
#!/usr/bin/env python3
import json
import os
import signal
import time

def term(*_):
    open(os.environ["FM_DECK_SIGNALLED"], "a").close()


signal.signal(signal.SIGTERM, term)
print(json.dumps({"type": "run_started", "session": "stuck-session"}), flush=True)
open(os.environ["FM_DECK_READY"], "w").close()
while True:
    time.sleep(60)
PY
  chmod +x "$dir/deck"
  gen=$("$BUSY_EVENT" arm "$dir/state" owned)
  FM_DECK_READY="$dir/ready" FM_DECK_SIGNALLED="$dir/signalled" python3 -c \
    'import os,sys; os.setsid(); os.execv("/bin/bash", ["fm-deck-worker"] + sys.argv[1:])' \
    "$WORKER" --id owned --state "$dir/state" --gen "$gen" --deck "$dir/deck" -- old-brief \
    </dev/null > "$dir/pane.out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [ ! -e "$dir/ready" ] || break; sleep 0.1; done
  [ -e "$dir/ready" ] || fail "stop escalation fixture did not start"
  python3 - "$ROOT/bin/fm-deck-stop.py" "$dir/state" owned <<'PY' \
    || fail "non-finite stop timeouts were not rejected promptly"
import subprocess
import sys

helper, state, task = sys.argv[1:]
for timeout in ("nan", "inf", "-inf"):
    result = subprocess.run(
        [sys.executable, helper, state, task, timeout],
        capture_output=True,
        text=True,
        timeout=2,
    )
    assert result.returncode != 0, timeout
    assert "timeout must be finite" in result.stderr, (timeout, result.stderr)
PY
  [ ! -e "$dir/signalled" ] || fail "a non-finite timeout signalled the Deck process before refusal"
  python3 "$ROOT/bin/fm-deck-stop.py" "$dir/state" other 1 || fail "unrelated task stop refused"
  kill -0 "$pid" 2>/dev/null || fail "stopping another task killed this driver"
  python3 "$ROOT/bin/fm-deck-stop.py" "$dir/state" owned 0.3 \
    || fail "the timed-out driver group was not escalated"
  wait "$pid" 2>/dev/null || true
  kill -0 "$pid" 2>/dev/null && fail "the timed-out driver survived escalation"
  pass "Deck stop: exact task scope and bounded escalation remove survivors"
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

# Recovery uses a real pane-resident driver and real process identities; only
# the Herdr transport and the model endpoint are shimmed. No terminal server.
test_herdr_deck_recovery() {
  local dir="$TMP_ROOT/herdr-recovery" gen shell_pid driver out record
  mkdir -p "$dir/state" "$dir/bin"
  make_fake_deck "$dir"
  sleep 300 & shell_pid=$!
  fm_test_track_helper_pid "$shell_pid"
  printf '%s\n' "$shell_pid" > "$dir/shell"
  cat > "$dir/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'status --json') printf '{"client":{"protocol":14},"server":{"running":true}}' ;;
  'pane get')
    case "$(cat "$FM_TEST_HERDR/presence" 2>/dev/null)" in
      error) echo 'socket error'; exit 1 ;;
      missing) echo '{"error":{"code":"pane_not_found"}}' ;;
      *) echo '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
    esac ;;
  'pane process-info')
    [ ! -e "$FM_TEST_HERDR/process-error" ] || exit 1
    shell=$(cat "$FM_TEST_HERDR/shell")
    driver=$(cat "$FM_TEST_HERDR/driver" 2>/dev/null || true)
    if [ -n "$driver" ]; then
      fg="{\"pid\":$driver,\"name\":\"bash\",\"argv0\":\"fm-deck-worker\"}"
    else
      fg="{\"pid\":$shell,\"name\":\"zsh\",\"argv0\":\"zsh\"}"
    fi
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_processes":[%s]}}}' "$shell" "$fg" ;;
  'agent get')
    echo registry >> "$FM_TEST_HERDR/registry.log"
    case "$(cat "$FM_TEST_HERDR/registry" 2>/dev/null)" in
      empty) ;;
      error) echo 'socket error'; exit 1 ;;
      live) echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
      *) echo '{"error":{"code":"agent_not_found"}}' ;;
    esac ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/bin/herdr"
  printf 'backend=herdr\nwindow=fmtest:w1:p2\nharness=deck\nkind=secondmate\n' > "$dir/state/t1.meta"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  "$BUSY_EVENT" progress "$dir/state" t1 --gen "$gen" || fail "progress fixture failed"
  herdr_deck_verdict() {
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$dir/state" FM_TEST_HERDR="$dir" PATH="$dir/bin:$PATH" \
      bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state herdr fmtest:w1:p2' _ "$ROOT"
  }
  # Dead FIRST: stale busy/progress records cannot resurrect an absent driver.
  out=$(herdr_deck_verdict)
  [ "$out" = dead ] || fail "absent Deck driver with stale busy/progress must be dead: $out"
  mkfifo "$dir/input"
  exec 8<> "$dir/input"
  FM_TEST_STATUS="$dir/state/t1.status" bash -c 'exec -a fm-deck-worker bash "$@"' _ \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" --deck "$dir/deck" -- write-status \
    < "$dir/input" > "$dir/pane.out" 2>&1 &
  driver=$!
  fm_test_track_helper_pid "$driver"
  printf '%s\n' "$driver" > "$dir/driver"
  for _ in $(seq 1 100); do
    record=$(fm_busy_record_read "$dir/state" t1)
    case "$record" in 'idle deck-wrapper '*) break ;; esac
    sleep 0.1
  done
  case "$record" in 'idle deck-wrapper '*) ;; *) fail "driver did not reach idle: $record" ;; esac
  : > "$dir/registry.log"
  out=$(herdr_deck_verdict)
  [ "$out" = alive ] || fail "live Deck driver must bypass agent_not_found: $out"
  [ ! -s "$dir/registry.log" ] || fail "Deck recovery consulted unsupported registry"
  "$BUSY_EVENT" apply "$dir/state" t1 busy --gen "$gen" --source deck-wrapper --event turn-start
  "$BUSY_EVENT" progress "$dir/state" t1 --gen "$gen"
  [ "$(herdr_deck_verdict)" = alive ] || fail "busy Deck driver was not alive"
  printf 'error\n' > "$dir/presence"
  [ "$(herdr_deck_verdict)" = unreadable ] || fail "erroring pane inventory became alive"
  printf 'missing\n' > "$dir/presence"
  [ "$(herdr_deck_verdict)" = missing ] || fail "missing pane became alive"
  rm "$dir/presence"
  touch "$dir/process-error"
  [ "$(herdr_deck_verdict)" = unreadable ] || fail "erroring process inventory became alive"
  rm "$dir/process-error"
  # Exact task identity, not any Deck process in the pane, is required.
  mv "$dir/state/t1.meta" "$dir/state/t2.meta"
  [ "$(herdr_deck_verdict)" != alive ] || fail "another task's driver was claimed"
  mv "$dir/state/t2.meta" "$dir/state/t1.meta"
  printf 'backend=herdr\nwindow=fmtest:w1:p2\nharness=pi\nkind=secondmate\n' > "$dir/state/t1.meta"
  for record in missing empty error live; do
    printf '%s\n' "$record" > "$dir/registry"
    out=$(herdr_deck_verdict)
    case "$record:$out" in missing:dead|empty:unreadable|error:unreadable|live:alive) ;;
      *) fail "non-Deck registry behavior changed: $record -> $out" ;;
    esac
  done
  # A Deck crewmate's driver carries the same identity arguments, so its
  # liveness comes from the same evidence rather than the registry.
  printf 'backend=herdr\nwindow=fmtest:w1:p2\nharness=deck\nkind=ship\n' > "$dir/state/t1.meta"
  printf 'missing\n' > "$dir/registry"
  : > "$dir/registry.log"
  [ "$(herdr_deck_verdict)" = alive ] || fail "a live Deck crewmate was not alive"
  [ ! -s "$dir/registry.log" ] || fail "Deck crewmate recovery consulted the registry"
  printf '/quit\n' >&8
  wait "$driver" || fail "driver did not exit cleanly"
  rm "$dir/driver"
  for kind in secondmate ship scout; do
    printf 'backend=herdr\nwindow=fmtest:w1:p2\nharness=deck\nkind=%s\n' "$kind" > "$dir/state/t1.meta"
    for record in missing empty error; do
      printf '%s\n' "$record" > "$dir/registry"
      out=$(herdr_deck_verdict)
      [ "$out" = dead ] || fail "absent Deck $kind driver became $out with registry $record"
    done
  done
  printf 'backend=herdr\nwindow=fmtest:w1:p2\nharness=deck\nkind=secondmate\n' > "$dir/state/t1.meta"
  # A supervised restart replaces the PID and generation, not the pane.
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  FM_TEST_STATUS="$dir/state/t1.status" bash -c 'exec -a fm-deck-worker bash "$@"' _ \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" --deck "$dir/deck" -- write-status \
    < "$dir/input" > "$dir/restarted.out" 2>&1 &
  driver=$!
  fm_test_track_helper_pid "$driver"
  printf '%s\n' "$driver" > "$dir/driver"
  for _ in $(seq 1 100); do
    out=$(herdr_deck_verdict)
    [ "$out" != alive ] || break
    sleep 0.1
  done
  [ "$out" = alive ] || fail "replacement driver on the same pane was not alive: $out"
  printf '/quit\n' >&8
  wait "$driver" || fail "replacement driver did not exit cleanly"
  exec 8>&-
  kill "$shell_pid" 2>/dev/null || true
  wait "$shell_pid" 2>/dev/null || true
  pass "Herdr Deck recovery proves driver identity; dead and non-Deck paths remain conservative"
}

# A home whose code root or state root holds a space - a macOS account such as
# /Users/John Smith, or an operator-chosen root: in data/secondmates.md - still
# attributes its live driver, because the match reads the boundary-preserving
# argv Herdr's process report carries rather than a whitespace-split `ps` line.
# Real driver, real busy records; only the Herdr transport is shimmed, and its
# argv comes from the live process wherever the platform exposes one.
test_herdr_deck_recovery_spaced_paths() {
  local dir="$TMP_ROOT/herdr-spaced" shell_pid
  mkdir -p "$dir/bin"
  make_fake_deck "$dir"
  ln -sfn "$ROOT" "$TMP_ROOT/spaced code root"
  sleep 300 & shell_pid=$!
  fm_test_track_helper_pid "$shell_pid"
  printf '%s\n' "$shell_pid" > "$dir/shell"
  cat > "$dir/bin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'status --json') printf '{"client":{"protocol":14},"server":{"running":true}}' ;;
  'pane get') echo '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
  'pane process-info')
    shell=$(cat "$FM_TEST_HERDR/shell")
    driver=$(cat "$FM_TEST_HERDR/driver" 2>/dev/null || true)
    if [ -n "$driver" ] && kill -0 "$driver" 2>/dev/null; then
      if [ -r "/proc/$driver/cmdline" ]; then
        argv=$(tr '\0' '\n' < "/proc/$driver/cmdline" | jq -R . | jq -sc .)
      else
        argv=$(cat "$FM_TEST_HERDR/argv.json")
      fi
      fg="{\"pid\":$driver,\"name\":\"bash\",\"argv0\":\"fm-deck-worker\",\"argv\":$argv}"
    else
      fg="{\"pid\":$shell,\"name\":\"zsh\",\"argv0\":\"zsh\",\"argv\":[\"zsh\"]}"
    fi
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_processes":[%s]}}}' "$shell" "$fg" ;;
  'agent get')
    echo registry >> "$FM_TEST_HERDR/registry.log"
    echo '{"error":{"code":"agent_not_found"}}' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/bin/herdr"
  spaced_verdict() {  # <fm-root> <state-dir>
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$1" FM_STATE_OVERRIDE="$2" FM_TEST_HERDR="$dir" PATH="$dir/bin:$PATH" \
      bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state herdr fmtest:w1:p2' _ "$1"
  }
  spaced_case() {  # <label> <fm-root> <state-dir>
    local label=$1 root=$2 state=$3 gen driver record out
    local -a argv
    mkdir -p "$state"
    printf 'backend=herdr\nwindow=fmtest:w1:p2\nharness=deck\nkind=secondmate\n' > "$state/t1.meta"
    gen=$("$BUSY_EVENT" arm "$state" t1)
    "$BUSY_EVENT" progress "$state" t1 --gen "$gen" || fail "$label: progress fixture failed"
    rm -f "$dir/driver"
    [ "$(spaced_verdict "$root" "$state")" = dead ] \
      || fail "$label: an absent driver with stale busy records was not dead"
    argv=(fm-deck-worker "$root/bin/fm-deck-worker.sh"
      --id t1 --state "$state" --gen "$gen" --deck "$dir/deck" -- write-status)
    printf '%s\n' "${argv[@]}" | jq -R . | jq -sc . > "$dir/argv.json"
    rm -f "$dir/input"
    mkfifo "$dir/input"
    exec 8<> "$dir/input"
    FM_TEST_STATUS="$state/t1.status" bash -c 'exec -a fm-deck-worker bash "$@"' _ "${argv[@]:1}" \
      < "$dir/input" > "$dir/pane.out" 2>&1 &
    driver=$!
    fm_test_track_helper_pid "$driver"
    printf '%s\n' "$driver" > "$dir/driver"
    record=
    for _ in $(seq 1 100); do
      record=$(fm_busy_record_read "$state" t1)
      case "$record" in 'idle deck-wrapper '*) break ;; esac
      sleep 0.1
    done
    case "$record" in
      'idle deck-wrapper '*) ;;
      *) fail "$label: driver did not reach idle: $record"$'\n'"$(cat "$dir/pane.out")" ;;
    esac
    : > "$dir/registry.log"
    out=$(spaced_verdict "$root" "$state")
    [ "$out" = alive ] || fail "$label: a live Deck driver read '$out'"
    [ ! -s "$dir/registry.log" ] || fail "$label: Deck recovery consulted the unsupported registry"
    printf '/quit\n' >&8
    wait "$driver" || fail "$label: driver did not exit cleanly"
    exec 8>&-
    rm -f "$dir/driver" "$dir/input"
  }
  spaced_case 'spaced state root' "$ROOT" "$TMP_ROOT/spaced state"
  spaced_case 'spaced code root' "$TMP_ROOT/spaced code root" "$TMP_ROOT/spaced mate state"
  kill "$shell_pid" 2>/dev/null || true
  wait "$shell_pid" 2>/dev/null || true
  pass "Herdr Deck recovery attributes a live driver across a spaced code root and state root"
}

# The steering doorbell for a remote Deck secondmate rings for a LIVE driver
# even though Herdr's registry answers agent_not_found for it: the ring's
# liveness read resolves the task's metadata in the SUPPLIED state directory
# (the parent-route root), never in the ambient home state, so it never falls
# back to the registry and never maps a live mate to dead. Real driver, real
# ring library, real process identities; only the Herdr transport is shimmed.
test_herdr_deck_ring_rings_live_driver() {
  local dir="$TMP_ROOT/herdr-ring" gen shell_pid driver record rec rc
  local first_registry first_send
  local route="$TMP_ROOT/herdr-ring-route" ambient="$TMP_ROOT/herdr-ring-home/state"
  mkdir -p "$dir/state" "$dir/bin" "$route" "$ambient"
  make_fake_deck "$dir"
  sleep 300 & shell_pid=$!
  fm_test_track_helper_pid "$shell_pid"
  printf '%s\n' "$shell_pid" > "$dir/shell"
  cat > "$dir/bin/herdr" <<'SH'
#!/usr/bin/env bash
LOG="$FM_TEST_HERDR/commands.log"
printf '%s\n' "$*" >> "$LOG"
case "$1 $2" in
  'status --json') printf '{"client":{"protocol":14},"server":{"running":true}}' ;;
  'pane get')
    case "$(cat "$FM_TEST_HERDR/presence" 2>/dev/null)" in
      error) echo 'socket error'; exit 1 ;;
      missing) echo '{"error":{"code":"pane_not_found"}}' ;;
      *) echo '{"result":{"pane":{"pane_id":"w1:p2"}}}' ;;
    esac ;;
  'pane process-info')
    [ ! -e "$FM_TEST_HERDR/process-error" ] || exit 1
    shell=$(cat "$FM_TEST_HERDR/shell")
    driver=$(cat "$FM_TEST_HERDR/driver" 2>/dev/null || true)
    if [ -n "$driver" ] && kill -0 "$driver" 2>/dev/null; then
      fg="{\"pid\":$driver,\"name\":\"bash\",\"argv0\":\"fm-deck-worker\"}"
    else
      fg="{\"pid\":$shell,\"name\":\"zsh\",\"argv0\":\"zsh\"}"
    fi
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p2","shell_pid":%s,"foreground_processes":[%s]}}}' "$shell" "$fg" ;;
  'pane read') printf '\n' ;;
  'pane send-text')
    [ ! -e "$FM_TEST_HERDR/send-fail" ] || exit 1
    shift 2
    printf 'typed: %s\n' "$*" >> "$FM_TEST_HERDR/typed.log" ;;
  'pane send-keys') exit 0 ;;
  'agent get')
    echo registry >> "$FM_TEST_HERDR/registry.log"
    case "$(cat "$FM_TEST_HERDR/registry" 2>/dev/null)" in
      empty) ;;
      error) echo 'socket error'; exit 1 ;;
      live) echo '{"result":{"agent":{"agent_status":"idle"}}}' ;;
      *) echo '{"error":{"code":"agent_not_found"}}' ;;
    esac ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$dir/bin/herdr"
  # The meta lives ONLY in the parent-route root; the ambient home state that a
  # caller forgetting the supplied directory would search holds nothing.
  printf 'backend=herdr\nwindow=fmtest:w1:p2\nharness=deck\nkind=secondmate\n' > "$route/t1.meta"
  gen=$("$BUSY_EVENT" arm "$route" t1)
  "$BUSY_EVENT" progress "$route" t1 --gen "$gen" || fail "progress fixture failed"
  ring() {  # -> ring return code
    local rc=0
    FM_HOME="$TMP_ROOT/herdr-ring-home" FM_ROOT_OVERRIDE="$ROOT" \
      FM_TEST_HERDR="$dir" PATH="$dir/bin:$PATH" \
      bash -c '. "$1/bin/fm-task-inbox-lib.sh"
        rec=$2 state=$3
        fm_task_inbox_ring herdr fmtest:w1:p2 "$rec" fm-t1 deck "$state" t1' \
      _ "$ROOT" "$(find "$route/t1.inbox" -maxdepth 1 -name '*.msg' | sort | head -1)" "$route" || rc=$?
    return "$rc"
  }
  # The inbox record the doorbell announces must exist under the route root.
  rec=$(FM_STATE_OVERRIDE="$route" bash -c '
    . "$1/bin/fm-task-inbox-lib.sh"
    fm_task_inbox_write_idempotent "$2" t1 "please continue"' _ "$ROOT" "$route") \
    || fail "ring fixture: inbox record could not be written"
  case "$rec" in "$route"/*) ;; *) fail "ring fixture: record landed outside the route root: $rec" ;; esac
  : > "$dir/typed.log"
  : > "$dir/registry.log"
  # DEAD FIRST, with the driver absent but its stale busy/progress in place: a
  # registry that cannot know Deck must not turn that into an alive verdict,
  # and nothing may be typed.
  printf 'missing\n' > "$dir/registry"
  rm -f "$dir/driver"
  ring; rc=$?
  [ "$rc" = 3 ] || fail "absent driver must skip the doorbell (rc 3), got $rc"
  [ ! -s "$dir/typed.log" ] || fail "the doorbell typed into a dead endpoint:"$'\n'"$(cat "$dir/typed.log")"
  # A live driver with the same stale registry answer: the doorbell RINGS.
  mkfifo "$dir/input"
  exec 9<> "$dir/input"
  FM_TEST_STATUS="$route/t1.status" bash -c 'exec -a fm-deck-worker bash "$@"' _ \
    "$WORKER" --id t1 --state "$route" --gen "$gen" --deck "$dir/deck" -- write-status \
    < "$dir/input" > "$dir/pane.out" 2>&1 &
  driver=$!
  fm_test_track_helper_pid "$driver"
  printf '%s\n' "$driver" > "$dir/driver"
  record=
  for _ in $(seq 1 100); do
    record=$(fm_busy_record_read "$route" t1)
    case "$record" in 'idle deck-wrapper '*) break ;; esac
    sleep 0.1
  done
  case "$record" in 'idle deck-wrapper '*) ;; *) fail "ring fixture: driver did not reach idle: $record" ;; esac
  : > "$dir/registry.log"
  ring; rc=$?
  [ "$rc" = 0 ] || fail "a live remote Deck driver must be rung, got rc $rc"
  grep -q 'Firstmate instruction waiting' "$dir/typed.log" \
    || fail "the doorbell text never reached the live driver's pane:"$'\n'"$(cat "$dir/typed.log")"
  grep -q "$route/t1.inbox" "$dir/typed.log" \
    || fail "the doorbell announced a path outside the parent-route root:"$'\n'"$(cat "$dir/typed.log")"
  # Delivery confirmation may read the registry AFTER typing; liveness may not
  # read it BEFORE, because that is the read that maps a live mate to dead.
  if [ -s "$dir/registry.log" ] && grep -q '^pane send-text' "$dir/commands.log"; then
    first_registry=$(grep -n '^agent get' "$dir/commands.log" | head -1 | cut -d: -f1)
    first_send=$(grep -n '^pane send-text' "$dir/commands.log" | head -1 | cut -d: -f1)
    if [ -n "$first_registry" ] && [ -n "$first_send" ] && [ "$first_registry" -lt "$first_send" ]; then
      fail "the ring used the registry for liveness before typing: $(cat "$dir/commands.log")"
    fi
  fi
  # The driver consumes the doorbell as an ordinary prompt turn and exits
  # cleanly, proving the pane content was semantically deliverable.
  printf '/quit\n' >&9
  wait "$driver" || fail "ring fixture: driver did not exit cleanly after the ring"
  exec 9>&-
  kill "$shell_pid" 2>/dev/null || true
  wait "$shell_pid" 2>/dev/null || true
  pass "the steering doorbell rings a live remote Deck driver and skips an absent one"
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


# A secondmate host fixture: a stub home, a stub session start, a stub watcher
# arm whose result is released by a trigger file, and a fake deck that records
# each turn's prompt, session, resumption, and drained inbox. A `fail-turn` file
# makes the next turn fail the way a gateway or quota refusal does, a
# `no-session` file makes it fail before Deck creates a session at all, the way
# a missing gateway key does, and an `unsafe-status` file additionally makes the
# parent status unwritable so the driver cannot record that failure.
make_secondmate_host_fixture() {  # <dir>
  local dir=$1
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/parent" "$dir/bin"
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
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ] && [ ! -f "$FM_HOME/generationless-next-watch" ]; then
  printf 'watcher: started pid=%s (beacon fresh) recovery-generation=deck-%s\n' "$$" "$FM_WATCH_PREDECESSOR_ARM_PID"
else
  rm -f "$FM_HOME/generationless-next-watch"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
fi
while [ ! -f "$FM_HOME/trigger" ]; do sleep 0.1; done
rm "$FM_HOME/trigger"
printf 'check: example\n'
[ "${FM_TEST_WATCH_FAIL:-0}" = 0 ]
SH
  cat > "$dir/home/config/x-mode.env" <<'SH'
if [ -f "$FM_HOME/block-next-watch" ]; then
  : > "$FM_HOME/watch-start-blocked"
  while [ ! -f "$FM_HOME/release-watch-start" ]; do sleep 0.05; done
  rm -f "$FM_HOME/block-next-watch" "$FM_HOME/release-watch-start" "$FM_HOME/watch-start-blocked"
fi
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
    (home / 'wake-turn-active').touch()
    time.sleep(2)
    successor = int((home / 'watch-starts').read_text().splitlines()[-1])
    if not (home / 'watch-start-blocked').exists():
        os.kill(successor, 0)
with (home / 'turns').open('a') as f:
    f.write(json.dumps({'prompt': prompt, 'session': session,
                        'resumed': '--session' in args, 'inbox': body}) + '\n')
for record in records:
    record.rename(inbox / 'handled' / record.name)
if not (home / 'no-session').exists():
    print(json.dumps({'type': 'run_started', 'session': session}), flush=True)
if (home / 'fail-turn').exists():
    if (home / 'unsafe-status').exists():
        status = pathlib.Path(__file__).parent / 'parent/host.status'
        status.unlink(missing_ok=True)
        status.symlink_to(home / 'external-status')
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
}

test_secondmate_host_serializes_wakes_and_steering() {
  local dir="$TMP_ROOT/host"
  make_secondmate_host_fixture "$dir"
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
def watcher_starts():
    path = home/'watch-starts'
    return path.read_text().splitlines() if path.exists() else []
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
        wait_for(lambda: (home/'wake-turn-active').exists(), 'deferred wake turn start')
        deliveries_before_block = (home/'handling-delivered').read_text().splitlines()
        (home/'block-next-watch').touch()
        (home/'trigger').touch()
        wait_for(lambda: (home/'watch-start-blocked').exists(), 'blocked mid-turn watcher successor')
        wait_for(lambda: len(rows()) == 3, 'long handling turn completion')
        deadline = time.time() + 2
        while time.time() < deadline:
            assert (home/'handling-delivered').read_text().splitlines() == deliveries_before_block, 'predecessor handoff was accepted as the blocked successor'
            time.sleep(.05)
        (home/'wake-turn-active').unlink()
        (home/'release-watch-start').touch()
        wait_for(lambda: len(watcher_starts()) >= 3, 'blocked mid-turn watcher successor release')
        wait_for(lambda: (home/'wake-turn-active').exists(), 'queued wake turn start')
        (home/'trigger').touch()
        wait_for(lambda: len(watcher_starts()) >= 4, 'queued-turn watcher successor')
        assert len(rows()) == 3, 'mid-turn watcher wake ran a concurrent Deck turn'
        assert 'Firstmate instruction waiting:' in rows()[2]['prompt']
        assert 'actionable wake' in rows()[2]['inbox']
        assert list((root/'parent/host.inbox/handled').glob('*.msg'))
        assert 'predecessor=none' not in (home/'watch-arms').read_text().splitlines()[1], 'successor lost its predecessor arm'
        wait_for(lambda: len(rows()) == 5, 'queued mid-turn wakes')
        assert 'Firstmate instruction waiting:' in rows()[3]['prompt']
        assert 'Firstmate instruction waiting:' in rows()[4]['prompt']
        deliveries = (home/'handling-delivered').read_text().splitlines()
        assert len(deliveries) >= 3, 'latest handling successor was not confirmed'
        assert deliveries[-1].split(' watcher=', 1)[1] == watcher_starts()[-1], 'predecessor handoff was accepted instead of the current successor'
        assert not (root/'parent/host.turn-ended').exists(), 'watch handling emitted a parent turn-end wake'
        deliveries_before_generationless = list(deliveries)
        (home/'generationless-next-watch').touch()
        (home/'trigger').touch()
        wait_for(lambda: len(watcher_starts()) >= 5, 'generationless watcher successor')
        wait_for(lambda: len(rows()) == 6, 'generationless successor wake')
        assert p.poll() is None, 'generationless watcher successor stopped the host'
        assert (home/'handling-delivered').read_text().splitlines() == deliveries_before_generationless, 'generationless successor attempted a recovery delivery handshake'
        p.stdin.write('split-'); p.stdin.flush()
        time.sleep(1.3)
        p.stdin.write('steer\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 7, 'partial input retained')
        assert rows()[6]['prompt'] == 'split-steer'
        (home/'trigger').touch()
        wait_for(lambda: len(rows()) == 8, 'watcher rearmed')
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
        wait_for(lambda: len(rows()) == 10, 'driver survived interrupt')
        assert rows()[9]['prompt'] == 'after-interrupt'
        assert 'turn interrupted' in (root/'parent/host.status').read_text()
        (home/'trigger').touch()
        wait_for(lambda: len(rows()) == 11, 'watcher survived interrupt')
        rows_before_exit = len(rows())
        starts_before_exit = len(watcher_starts())
        (home/'in-turn').unlink()
        p.stdin.write('slow-steer\n'); p.stdin.flush()
        wait_for(lambda: (home/'in-turn').exists(), 'exit-race turn start')
        assert len(rows()) == rows_before_exit + 1
        (home/'trigger').touch()
        wait_for(lambda: len(watcher_starts()) > starts_before_exit, 'exit-race watcher successor')
        p.stdin.write('/quit\n'); p.stdin.flush()
        time.sleep(.3)
        (home/'release').touch()
        assert p.wait(timeout=15) == 0
        assert len(rows()) == rows_before_exit + 1, 'queued exit ran a watcher turn before stopping the host'
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
for key in ['FM_TEST_START_FAIL', 'FM_TEST_WATCH_FAIL']:
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

test_secondmate_survives_a_failed_turn() {
  local dir="$TMP_ROOT/host-failed-turn"
  make_secondmate_host_fixture "$dir"
  python3 - "$dir" <<'PYTHON' || fail "a Deck secondmate did not survive a failed turn"
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
home = root / 'home'
status = root / 'parent/host.status'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
def rows():
    path = home/'turns'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
def failures():
    lines = status.read_text().splitlines() if status.exists() else []
    return [x for x in lines if x.startswith('failed: Deck secondmate turn failed')]
def wait_for(check, label):
    for _ in range(200):
        if check(): return
        if p.poll() is not None: raise AssertionError(label+' - host exited: '+(root/'pane').read_text())
        time.sleep(.1)
    raise AssertionError(label+': '+(root/'pane').read_text())
# A mate launched into a provider outage must reach its prompt, not die there.
(home/'fail-turn').touch()
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env, text=True, start_new_session=True)
    try:
        wait_for(lambda: len(rows()) == 1, 'failed first turn')
        wait_for(lambda: len(failures()) == 1, 'first-turn failure record')
        wait_for(lambda: 'event=turn-failed' in (root/'parent/host.busy-state').read_text(), 'first-turn busy record')
        record = (root/'parent/host.busy-state').read_text()
        assert 'state=idle' in record, record
        time.sleep(.5)
        assert p.poll() is None, 'the driver exited on a failed first turn: '+(root/'pane').read_text()
        (home/'fail-turn').unlink()
        p.stdin.write('after-first-failure\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 2, 'turn after a failed first turn')
        assert rows()[1]['prompt'] == 'after-first-failure'
        assert rows()[1]['resumed'], 'the surviving driver started a new Deck session'
        assert rows()[1]['session'] == rows()[0]['session'], 'the surviving driver lost its session identity'
        # A later turn fails the same way, and every failure stays published.
        (home/'fail-turn').touch()
        p.stdin.write('later-failure\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 3, 'failed later turn')
        wait_for(lambda: len(failures()) == 2, 'later-turn failure record')
        time.sleep(.5)
        assert p.poll() is None, 'the driver exited on a failed later turn: '+(root/'pane').read_text()
        # Staying at the prompt is only useful if the watcher still rings.
        (home/'fail-turn').unlink()
        (home/'trigger').touch()
        wait_for(lambda: len(rows()) == 4, 'watcher wake after a failed turn')
        assert 'Firstmate instruction waiting:' in rows()[3]['prompt']
        assert 'actionable wake' in rows()[3]['inbox']
        assert rows()[3]['resumed'], 'the watcher wake turn lost the session'
        p.stdin.write('/quit\n'); p.stdin.flush()
        assert p.wait(timeout=20) == 0, 'the surviving driver did not stop on /quit'
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
PYTHON
  pass "fm-deck-worker: a secondmate records a failed turn and waits at its prompt for the next wake"
}

test_secondmate_repeats_its_launch_brief_after_a_session_less_failure() {
  local dir="$TMP_ROOT/host-no-session"
  make_secondmate_host_fixture "$dir"
  python3 - "$dir" <<'PYTHON' || fail "a Deck secondmate lost its launch brief when a failure opened no session"
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
home = root / 'home'
status = root / 'parent/host.status'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
def rows():
    path = home/'turns'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
def failures():
    lines = status.read_text().splitlines() if status.exists() else []
    return [x for x in lines if x.startswith('failed: Deck secondmate turn failed')]
def wait_for(check, label):
    for _ in range(200):
        if check(): return
        if p.poll() is not None: raise AssertionError(label+' - host exited: '+(root/'pane').read_text())
        time.sleep(.1)
    raise AssertionError(label+': '+(root/'pane').read_text())
# Deck fails before it creates a session, the way a missing gateway key does, so
# nothing carries the launch brief into a conversation.
(home/'no-session').touch()
(home/'fail-turn').touch()
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env, text=True, start_new_session=True)
    try:
        wait_for(lambda: len(rows()) == 1, 'failed first turn with no session')
        wait_for(lambda: len(failures()) == 1, 'session-less failure record')
        wait_for(lambda: 'event=turn-failed' in (root/'parent/host.busy-state').read_text(), 'session-less busy record')
        assert 'complete startup digest marker' in rows()[0]['prompt'], rows()[0]['prompt']
        assert not rows()[0]['resumed']
        time.sleep(.5)
        assert p.poll() is None, 'the driver exited on a session-less first turn: '+(root/'pane').read_text()
        (home/'fail-turn').unlink()
        (home/'no-session').unlink()
        p.stdin.write('first-wake\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 2, 'turn after a session-less failure')
        # The parked mate still takes the helm: the retained launch brief travels
        # with the wake, and the session that turn opens is the one kept.
        assert 'complete startup digest marker' in rows()[1]['prompt'], rows()[1]['prompt']
        assert 'first-wake' in rows()[1]['prompt'], rows()[1]['prompt']
        assert not rows()[1]['resumed'], 'the driver resumed a session Deck never opened'
        assert rows()[1]['session'] == 'host-session', rows()[1]
        p.stdin.write('second-wake\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 3, 'turn after the repeated launch brief')
        assert rows()[2]['resumed'], 'the session opened by the repeated launch brief was not kept'
        assert rows()[2]['session'] == rows()[1]['session'], rows()[2]
        assert rows()[2]['prompt'] == 'second-wake', 'the launch brief was repeated after it reached a session'
        assert len(failures()) == 1, status.read_text()
        p.stdin.write('/quit\n'); p.stdin.flush()
        assert p.wait(timeout=20) == 0, 'the surviving driver did not stop on /quit'
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
PYTHON
  pass "fm-deck-worker: a secondmate with no session repeats its launch brief on the next wake"
}

test_secondmate_stops_when_a_repeated_launch_brief_opens_no_session() {
  local dir="$TMP_ROOT/host-no-session-twice"
  make_secondmate_host_fixture "$dir"
  python3 - "$dir" <<'PYTHON' || fail "a Deck secondmate parked forever without ever opening a session"
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
home = root / 'home'
status = root / 'parent/host.status'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
def rows():
    path = home/'turns'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
def wait_for(check, label):
    for _ in range(200):
        if check(): return
        if p.poll() is not None: raise AssertionError(label+' - host exited: '+(root/'pane').read_text())
        time.sleep(.1)
    raise AssertionError(label+': '+(root/'pane').read_text())
(home/'no-session').touch()
(home/'fail-turn').touch()
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env, text=True)
    try:
        wait_for(lambda: len(rows()) == 1, 'failed first turn with no session')
        time.sleep(.5)
        assert p.poll() is None, 'the driver exited before repeating its launch brief: '+(root/'pane').read_text()
        p.stdin.write('next-wake\n'); p.stdin.flush()
        assert p.wait(timeout=30) != 0, 'the driver kept parking with no session at all'
    finally:
        if p.poll() is None:
            p.terminate(); p.wait(timeout=15)
pane = (root/'pane').read_text()
turns = rows()
assert len(turns) == 2, turns
assert 'next-wake' in turns[1]['prompt'], turns[1]['prompt']
assert 'complete startup digest marker' in turns[1]['prompt'], 'the repeated turn lost the launch digest'
lines = status.read_text().splitlines()
assert len([x for x in lines if x.startswith('failed: Deck secondmate turn failed')]) == 2, lines
assert any(x.startswith('failed: Deck secondmate opened no Deck session') for x in lines), lines
assert 'event=turn-failed' in (root/'parent/host.busy-state').read_text(), 'the stopping failure skipped its busy record'
assert 'stopping for a guarded relaunch' in pane, pane
PYTHON
  pass "fm-deck-worker: a secondmate that cannot open a session stops for the guarded relaunch"
}

test_secondmate_stops_when_a_failed_turn_cannot_be_recorded() {
  local dir="$TMP_ROOT/host-unrecordable-failure"
  make_secondmate_host_fixture "$dir"
  python3 - "$dir" <<'PYTHON' || fail "a Deck secondmate kept running without recording its failure"
import os, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
home = root / 'home'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
(home/'fail-turn').touch()
(home/'unsafe-status').touch()
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env, text=True)
    try:
        assert p.wait(timeout=30) != 0, 'the driver kept running on a failure it could not record'
    finally:
        if p.poll() is None:
            p.terminate(); p.wait(timeout=15)
pane = (root/'pane').read_text()
assert 'failed to publish secondmate failure' in pane, pane
assert not (home/'external-status').exists(), 'the failure publisher followed a symlink out of the state root'
assert 'event=turn-failed' in (root/'parent/host.busy-state').read_text(), 'the unrecordable failure skipped its busy record'
PYTHON
  pass "fm-deck-worker: a secondmate that cannot publish a failed turn stops instead of looping"
}

test_herdr_deck_recovery
test_herdr_deck_recovery_spaced_paths
test_herdr_deck_ring_rings_live_driver
test_idle_interrupt_does_not_echo_fake_input
test_secondmate_host_serializes_wakes_and_steering
test_secondmate_survives_a_failed_turn
test_secondmate_repeats_its_launch_brief_after_a_session_less_failure
test_secondmate_stops_when_a_repeated_launch_brief_opens_no_session
test_secondmate_stops_when_a_failed_turn_cannot_be_recorded
test_turns_share_one_session_and_carry_the_hooks
test_turns_drive_the_busy_record_and_turn_end
test_busy_state_failures_stop_turns_and_publish_status
test_turnend_signal_refuses_unsafe_paths
test_evidence_gate_refuses_a_turn_without_a_status_line
test_stderr_before_completion_blocked_does_not_break_rendering
test_bookkeeping_lines_do_not_satisfy_turn_evidence
test_finished_turn_renders_the_utc_completion_time
test_idle_prompt_notes_the_utc_idle_instant
test_status_checks_and_fallbacks_refuse_unsafe_paths
test_driver_backstops_silent_and_failed_turns
test_ctrl_c_cancels_the_turn_and_returns_to_the_prompt
test_completed_turn_removes_busy_ack_before_the_next_steer
test_driver_stop_terminates_active_deck_and_resolves_spaced_paths
test_stale_secondmate_driver_is_stopped_at_relaunch_boundary
test_driver_stop_is_scoped_and_escalates_after_timeout
test_liveness_reads_the_driver_as_an_agent
test_tmux_liveness_uses_the_deck_driver_argv0
test_control_busy_and_delivery_tables_name_deck
test_deck_supervision_model_is_scoped_to_secondmate_launches
test_spawn_launches_the_driver_with_binary_gen_and_model
test_spawn_refuses_deck_effort
echo "fm-deck-harness: all cases passed"
