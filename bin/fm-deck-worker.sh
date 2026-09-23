#!/usr/bin/env bash
# fm-deck-worker.sh - the pane-resident driver that makes Deck a Firstmate worker.
#
# Deck (bastotec/deck) is a headless agent: `deck run "<prompt>"` streams NDJSON
# events on stdout and exits when the model finishes. Firstmate supervises
# workers that live in a pane and take steering as typed lines, so this script
# is the pane's foreground process and turns one Deck conversation into that
# shape:
#   - the launch brief is the first turn; every later line typed at the `❯`
#     prompt (a steer, the steering-inbox doorbell) is the next turn of the SAME
#     Deck session (`--session`), so context carries across steers;
#   - each turn's events render as readable text in the pane (fm-peek reads it);
#   - it is the semantic busy source for the task: turn start and turn end are
#     written through bin/fm-busy-event.sh with source `deck-wrapper`, and each
#     finished worker turn touches the task's turn-end notification file;
#   - Deck's own hooks are attached on every run: `post_tool_use` refreshes the
#     task's progress marker, and `pre_complete` refuses to let a turn finish
#     until the worker has appended a worker-status line during that turn;
#     the driver backstops failed, refused, and interrupted turns with a failure
#     status when Deck exits without one;
#   - Ctrl+C cancels the running turn and returns to the prompt; `/quit` at the
#     prompt ends the worker.
#
# USAGE (bin/fm-spawn.sh builds this; the brief arrives already encoded)
#   fm-deck-worker.sh --id <task-id> --state <state-dir> --gen <busy-gen>
#       --deck <deck-binary> [--model <route>] [--secondmate] -- <first-prompt>
# --secondmate requires FM_HOME and hosts that home, leaving --state pointed
# at the parent task state for busy/progress and failure publication.
# Startup runs once before the first turn. A tracked watcher stays armed through
# every turn; its results become later turns, with queued stdin serialized
# alongside them. pre_complete checks lock ownership instead of worker evidence.
# The driver postcondition does not park without an owned watcher or a pending
# result. A failed watcher exits loudly rather than leaving an idle host blind.
#
# SECOND MATE INVARIANTS (--secondmate)
# The driver, not a turn-scoped Deck process, owns the home session lock.
# Watcher results pass through the durable task steering inbox and its ordinary
# doorbell, retained until acknowledged after a serialized next turn;
# the durable wake queue is acknowledged only by the model after handling.
# Exactly one Deck turn runs at a time, including stdin and watcher turns.
# Supervision uses child processes and stdin, never backend-specific injection.
# Startup, watcher, and turn failures publish failure status and stop the driver.
#
# ENVIRONMENT
#   FM_DECK_MAX_TURNS       model calls per turn (default 200; Deck's own 24 is
#                           sized for a single question, not a coding task)
#   FM_DECK_DEADLINE_SECS   wall-clock bound per turn (default 3600).
#   FM_DECK_DEADLINE_ROLLOVERS
#                           maximum validation/CI-wait deadline continuations
#                           per task (default 3); unrelated deadlines never retry.
#   PROXAI_BASE_URL, PROXAI_MODEL, PROXAI_API_KEY_FILE, PROXAI_API_KEY
#                           Deck's own endpoint settings, passed through. When
#                           neither key variable is set and
#                           ~/.config/proxai/client.key exists, that file is used.
#
# Exit: 0 on /quit or end of input; 1 on a runtime or host failure; 2 on a
# usage error or unavailable launch prerequisite.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BUSY_EVENT="$SCRIPT_DIR/fm-busy-event.sh"
STATE_IO="$SCRIPT_DIR/fm-state-io.py"

ID='' STATE='' GEN='' DECK='' MODEL=''
SECONDMATE=0 WATCH_PID='' WATCH_PREDECESSOR_ARM_PID='' INPUT_PID='' TURN_PID='' TURN_RENDER_PID=''
WATCH_HANDLING_GENERATION='' WATCH_HANDLING_WATCHER_PID=''
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
while [ $# -gt 0 ]; do
  case "$1" in
    --secondmate) SECONDMATE=1; shift ;;
    --id) ID=${2-}; shift 2 ;;
    --state) STATE=${2-}; shift 2 ;;
    --gen) GEN=${2-}; shift 2 ;;
    --deck) DECK=${2-}; shift 2 ;;
    --model) MODEL=${2-}; shift 2 ;;
    --) shift; break ;;
    *) echo "fm-deck-worker: unknown argument: $1" >&2; exit 2 ;;
  esac
done
PROMPT=${1-}
if [ -z "$ID" ] || [ -z "$STATE" ] || [ -z "$GEN" ] || [ -z "$DECK" ] || [ -z "$PROMPT" ]; then
  echo "fm-deck-worker: --id, --state, --gen, --deck, and a first prompt are required" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "fm-deck-worker: jq is required to render Deck's event stream" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "fm-deck-worker: python3 is required for safe status I/O" >&2; exit 2; }
[ -f "$STATE_IO" ] && [ ! -L "$STATE_IO" ] || { echo "fm-deck-worker: safe status I/O helper is unavailable" >&2; exit 2; }

STATUS_FILE="$STATE/$ID.status"
TURNEND_FILE="$STATE/$ID.turn-ended"
MAX_TURNS=${FM_DECK_MAX_TURNS:-200}
DEADLINE=${FM_DECK_DEADLINE_SECS:-3600}
DEADLINE_ROLLOVER_LIMIT=${FM_DECK_DEADLINE_ROLLOVERS:-3}
DEADLINE_ROLLOVERS=0
case "$MAX_TURNS" in ''|*[!0-9]*) MAX_TURNS=200 ;; esac
case "$DEADLINE" in ''|*[!0-9]*) DEADLINE=3600 ;; esac
case "$DEADLINE_ROLLOVER_LIMIT" in ''|*[!0-9]*) DEADLINE_ROLLOVER_LIMIT=3 ;; esac
# A zero deadline would turn native continuation into an immediate retry loop.
case "$DEADLINE" in *[1-9]*) ;; *) DEADLINE=3600 ;; esac
if [ -z "${PROXAI_API_KEY_FILE:-}${PROXAI_API_KEY:-}" ] && [ -f "$HOME/.config/proxai/client.key" ]; then
  export PROXAI_API_KEY_FILE="$HOME/.config/proxai/client.key"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-deck-worker.XXXXXX") || exit 2
TURN_MARK="$WORK/turn-start"
EVENTS="$WORK/events.ndjson"
WATCH_PENDING="$WORK/watch.pending"
TURN_STATUS="$WORK/turn-pipeline.status"
TURN_PIPE="$WORK/turn-events.pipe"
mkfifo "$TURN_PIPE" || exit 1
TTY_SETTINGS=''
[ ! -t 0 ] || TTY_SETTINGS=$(stty -g 2>/dev/null || true)
tty_busy() { [ -z "$TTY_SETTINGS" ] || stty icanon 2>/dev/null || true; }
tty_ready() { [ -z "$TTY_SETTINGS" ] || stty -icanon min 1 time 0 2>/dev/null || true; }
cleanup() {
  if [ -n "$TURN_PID" ]; then
    kill -TERM "$TURN_PID" 2>/dev/null || true
    wait "$TURN_PID" 2>/dev/null || true
  fi
  if [ -n "$TURN_RENDER_PID" ]; then
    kill -TERM "$TURN_RENDER_PID" 2>/dev/null || true
    wait "$TURN_RENDER_PID" 2>/dev/null || true
  fi
  if [ -n "$INPUT_PID" ]; then
    kill -TERM "$INPUT_PID" 2>/dev/null || true
    wait "$INPUT_PID" 2>/dev/null || true
  fi
  if [ -n "$WATCH_PID" ]; then
    kill -TERM "$WATCH_PID" 2>/dev/null || true
    wait "$WATCH_PID" 2>/dev/null || true
  fi
  [ -z "$TTY_SETTINGS" ] || stty "$TTY_SETTINGS" 2>/dev/null || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP TERM
# Ctrl+C reaches the whole foreground group: Deck and the renderer stop, this
# driver survives, records the cancelled turn, and returns to the prompt.
INTERRUPTED=0
interrupt_turn() {
  INTERRUPTED=1
  [ -z "$TURN_PID" ] || kill -TERM "$TURN_PID" 2>/dev/null || true
}
trap interrupt_turn INT
trap 'exit 0' TERM

busy_event() {  # <busy|idle> <event>
  "$BUSY_EVENT" apply "$STATE" "$ID" "$1" --gen "$GEN" --source deck-wrapper --event "$2" >/dev/null
}

record_busy_event() {  # <busy|idle> <event>
  local state=$1 event=$2 diagnostic
  diagnostic=$(busy_event "$state" "$event" 2>&1) && return 0
  printf '%s\n' "$diagnostic" >&2
  # A diagnostic is one status event even when the helper writes several lines.
  diagnostic=${diagnostic//$'\n'/; }
  diagnostic=${diagnostic//$'\r'/ }
  if ! printf 'failed: deck wrapper could not record busy-state event (%s): %s\n' "$event" "$diagnostic" | status_append; then
    printf 'fm-deck-worker: busy-state event %s failed and its status could not be published to %s\n' "$event" "$STATUS_FILE" >&2
    return 1
  fi
  printf 'fm-deck-worker: could not record busy-state event %s\n' "$event" >&2
  return 1
}

status_size() {
  python3 "$STATE_IO" root-size "$STATE" "$ID.status"
}

status_append() {
  python3 "$STATE_IO" root-append "$STATE" "$ID.status"
}

status_has_worker_evidence() {
  python3 "$STATE_IO" root-worker-status-after "$STATE" "$ID.status" "$1"
}

publish_turnend() {
  [ "$SECONDMATE" != 1 ] || return 0
  python3 "$STATE_IO" root-touch "$STATE" "$ID.turn-ended" || {
    printf 'fm-deck-worker: could not safely publish turn-end signal %s\n' "$TURNEND_FILE" >&2
    return 1
  }
}

deadline_wait_is_resumable() {
  jq -s -e '
    (to_entries | map(select(.value.type == "tool_call")) | last) as $call
    | (to_entries | map(select(.value.type == "tool_result")) | last) as $result
    | select($call != null and ($result == null or $call.key > $result.key))
    | select($call.value.name == "shell")
    | ($call.value.arguments | if type == "string" then . else tostring end) as $args
    | ($args | test("(^|[^[:alnum:]_-])no-mistakes[[:space:]]+axi[[:space:]]+run([^[:alnum:]_-]|$)"))
      or ($args | test("(^|[^[:alnum:]_-])gh[[:space:]]+run[[:space:]]+watch([^[:alnum:]_-]|$)"))
      or ($args | test("(^|[^[:alnum:]_-])gh[[:space:]]+pr[[:space:]]+checks[^\\n]*[[:space:]]--watch([^[:alnum:]_-]|$)"))
  ' "$EVENTS" >/dev/null 2>&1
}

q() { printf '%q' "$1"; }

host_failure() {
  printf 'fm-deck-worker: %s\n' "$1" >&2
  printf 'failed: Deck secondmate %s\n' "$1" | status_append || {
    printf 'fm-deck-worker: failed to publish secondmate failure\n' >&2
  }
  return 1
}

host_lock_owned() {
  fm_session_lock_owned_by_self "$FM_HOME/state" || host_failure 'lost home session lock'
}

# The arm is a tracked child of this persistent driver, never a background
# tool call. Its output stays in WORK while a turn runs; its actionable reason
# is merely a doorbell for the durable home queue, never an acknowledgement.
watch_wait_handling_successor() {
  local deadline line
  deadline=$(( $(date +%s) + 15 ))
  while [ "$(date +%s)" -lt "$deadline" ]; do
    line=$(sed -n 's/^watcher: started pid=\([0-9][0-9]*\).* recovery-generation=\([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1 \2/p' "$WORK/watch.out" 2>/dev/null | tail -1)
    if [ -n "$line" ]; then
      WATCH_HANDLING_WATCHER_PID=${line%% *}
      WATCH_HANDLING_GENERATION=${line#* }
      WATCH_PREDECESSOR_ARM_PID=''
      return 0
    fi
    line=$(sed -n 's/^watcher: started pid=\([0-9][0-9]*\) (beacon fresh)$/\1/p' "$WORK/watch.out" 2>/dev/null | tail -1)
    if [ -n "$line" ]; then
      WATCH_HANDLING_WATCHER_PID=''
      WATCH_HANDLING_GENERATION=''
      WATCH_PREDECESSOR_ARM_PID=''
      return 0
    fi
    if ! kill -0 "$WATCH_PID" 2>/dev/null; then
      wait "$WATCH_PID" 2>/dev/null || true
      WATCH_PID=''
      cat "$WORK/watch.out"
      host_failure 'successor watcher exited before confirming startup'
      return 1
    fi
    sleep 0.05
  done
  host_failure 'successor watcher did not confirm startup'
  return 1
}

watch_confirm_handling_delivery() {
  [ -n "$WATCH_HANDLING_GENERATION" ] || return 0
  if "$SCRIPT_DIR/fm-watch-arm.sh" --handling-delivered "$WATCH_HANDLING_GENERATION" \
      --watcher-pid "$WATCH_HANDLING_WATCHER_PID" >/dev/null 2>&1; then
    WATCH_HANDLING_GENERATION=''
    WATCH_HANDLING_WATCHER_PID=''
    return 0
  fi
  host_failure 'successor watcher refused handling delivery confirmation'
  return 1
}

watch_start() {
  local predecessor=$WATCH_PREDECESSOR_ARM_PID
  [ -z "$WATCH_PID" ] || return 0
  host_lock_owned || return 1
  if [ -e "$FM_HOME/state/.afk" ]; then
    host_failure 'daemon-owned away/quiet mode is unsupported; clear it through the owning supervisor before relaunch'
    return 1
  fi
  if ! : > "$WORK/watch.out"; then
    host_failure 'could not prepare watcher result capture'
    return 1
  fi
  (
    trap '' INT
    if [ -f "$FM_HOME/config/x-mode.env" ]; then
      # shellcheck source=/dev/null
      . "$FM_HOME/config/x-mode.env" || exit 1
    fi
    if [ -n "$predecessor" ]; then
      FM_WATCH_PREDECESSOR_ARM_PID=$predecessor exec "$SCRIPT_DIR/fm-watch-arm.sh" --restart
    else
      exec "$SCRIPT_DIR/fm-watch-arm.sh"
    fi
  ) >> "$WORK/watch.out" 2>&1 &
  WATCH_PID=$!
  [ -z "$predecessor" ] || watch_wait_handling_successor
}

# Use exactly the ordinary durable steering record and doorbell contract. The
# local host consumes the doorbell directly as a next turn; backend transports
# need no keystroke injection, pane scrape, or special wake implementation.
watch_doorbell() (
  local record
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
  record=$(fm_task_inbox_write "$STATE" "$ID" "The home watcher has an actionable wake. Drain bin/fm-wake-drain.sh first, handle every emitted wake and open decision, and acknowledge only after handling. Watcher output:
$(cat "$WATCH_PENDING")") || exit 1
  fm_task_inbox_doorbell_line "$record"
)

watch_result() {
  local rc predecessor=$WATCH_PID
  wait "$WATCH_PID"; rc=$?
  WATCH_PID=''
  cat "$WORK/watch.out"
  [ "$rc" -eq 0 ] || { host_failure "watcher failed (exit $rc)"; return 1; }
  [ -s "$WORK/watch.out" ] || { host_failure 'watcher ended without a result'; return 1; }
  host_lock_owned || return 1
  {
    cat "$WORK/watch.out"
    printf '\n'
  } >> "$WATCH_PENDING" || { host_failure 'could not retain watcher result for the next turn'; return 1; }
  WATCH_PREDECESSOR_ARM_PID=$predecessor
}

watch_maintain() {
  while [ -n "$WATCH_PID" ] && ! kill -0 "$WATCH_PID" 2>/dev/null; do
    watch_result || return 1
    watch_start || return 1
  done
}

# The evidence gate: the turn may finish only after it appended a worker status
# line after the byte offset recorded at turn start. Deck feeds this stderr back
# to the model and fails the run after its own bounded number of refusals.
EVIDENCE_HOOK="python3 $(q "$STATE_IO") root-worker-status-after $(q "$STATE") $(q "$ID.status") \"\$(cat $(q "$TURN_MARK") 2>/dev/null || echo 0)\" 2>/dev/null || { echo $(q "Before you finish, append one line to $STATUS_FILE as your instructions' status protocol describes (done:, needs-decision:, blocked:, failed:, or working:), stating what you did and the evidence. Then finish.") >&2; exit 2; }"
PROGRESS_HOOK="diagnostic=\$($(q "$BUSY_EVENT") progress $(q "$STATE") $(q "$ID") --gen $(q "$GEN") 2>&1 >/dev/null) || { printf '%s\\n' \"\$diagnostic\" >&2; diagnostic=\$(printf '%s' \"\$diagnostic\" | tr '\\n\\r' '  '); printf 'failed: deck wrapper could not refresh progress: %s\\n' \"\$diagnostic\" | python3 $(q "$STATE_IO") root-append $(q "$STATE") $(q "$ID.status"); exit 1; }"

# Readable pane rendering of Deck's event stream. Reasoning and usage events
# are bookkeeping and stay out of the pane.
RENDER='
  if .type == "text_delta" then .text
  elif .type == "tool_call" then "\n▸ \(.name) \(.arguments | tostring | .[0:160])\n"
  elif .type == "tool_result" then "  ↳ \(.name) (\(.duration_ms) ms) \(.output | if type == "string" then . else tostring end | split("\n")[0] | .[0:160])\n"
  elif .type == "completion_blocked" then "\n⛔ finish refused (attempt \(.attempt)): \(.reason)\n"
  elif .type == "run_finished" then "\n── turn finished (\(.turns) model calls)\n"
  elif .type == "run_failed" then "\n✗ turn failed: \(.error)\n"
  else empty end'

if [ "$SECONDMATE" = 1 ]; then
  [ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || { host_failure 'requires an explicit home'; exit 2; }
  cd "$FM_HOME" || exit 2
  # A persistent stdin reader preserves partial lines across watcher wakes on
  # both Bash 3.2 (timeout and EOF share exit 1) and newer Bash. Atomic files in
  # this private directory keep typed input pending while Deck owns the turn.
  python3 -c '
import os, pathlib, signal, sys
signal.signal(signal.SIGINT, signal.SIG_IGN)
root = pathlib.Path(sys.argv[1])
for seq, line in enumerate(sys.stdin):
    tmp = root / "input.tmp"
    tmp.write_text(line)
    os.replace(tmp, root / ("input." + str(seq)))
(root / "input.eof").touch()
' "$WORK" <&0 &
  INPUT_PID=$!
  # Startup is executed exactly once by the stable host, not by a short-lived
  # Deck run. The complete digest is supplied to the first model turn.
  if ! "$SCRIPT_DIR/fm-session-start.sh" > "$WORK/startup" 2>&1; then
    cat "$WORK/startup" >&2
    host_failure 'session start failed'; exit 1
  fi
  host_lock_owned || exit 1
  if [ "$(cat "$FM_HOME/state/.session-start-complete" 2>/dev/null)" != "$$" ]; then
    cat "$WORK/startup" >&2
    host_failure 'session start did not publish a complete digest'; exit 1
  fi
  PROMPT="$PROMPT

The task steering inbox is $STATE/$ID.inbox. It belongs to this secondmate even outside its home. The host writes watcher instructions there through the ordinary durable steering contract. After reading the digest, handle any pending inbox records in numeric order and move each handled record to handled/.
The Deck host already ran bin/fm-session-start.sh exactly once for this session.
Read the complete digest below; do not run session start again.
$(cat "$WORK/startup")"
  # A persistent supervisor may legitimately finish silently. It is not a
  # ship worker and must not manufacture a parent status on every idle turn.
  EVIDENCE_HOOK="bash -c $(q ". $(q "$SCRIPT_DIR/fm-session-lock-lib.sh"); fm_session_lock_owned_by_self $(q "$FM_HOME/state") || { echo 'Home session lock lost; report the failure and stop.' >&2; exit 2; }")"
fi

SESSION=''
run_turn() {  # <prompt>
  local prompt=$1 rc event status_before monitor_failed=0 deck_rc tee_rc jq_rc
  local -a turn_pipeline
  [ "$SECONDMATE" != 1 ] || host_lock_owned || return 1
  [ "$SECONDMATE" != 1 ] || watch_start || return 1
  [ "$SECONDMATE" != 1 ] || watch_confirm_handling_delivery || return 1
  local -a args=(run "$prompt" --max-turns "$MAX_TURNS" --deadline-secs "$DEADLINE" --hook "pre_complete=$EVIDENCE_HOOK")
  [ -z "$PROGRESS_HOOK" ] || args+=(--hook "post_tool_use=$PROGRESS_HOOK")
  [ -z "$MODEL" ] || args+=(--model "$MODEL")
  [ -z "$SESSION" ] || args+=(--session "$SESSION")
  INTERRUPTED=0
  tty_busy
  if ! status_size > "$TURN_MARK"; then
    printf 'fm-deck-worker: status path is not a safe regular file: %s\n' "$STATUS_FILE" >&2
    return 1
  fi
  record_busy_event busy turn-start || return 1
  # The rendered working row is transient: save its screen position so a
  # completed turn can replace it with the final event rendering. A later steer
  # therefore starts from a genuinely idle pane.
  if [ -t 1 ]; then
    printf '\n\033[s⛵ deck working - ctrl+c to stop\n'
  else
    printf '\n⛵ deck working - ctrl+c to stop\n'
  fi
  if [ "$SECONDMATE" = 1 ]; then
    rm -f "$TURN_STATUS" "$TURN_STATUS.tmp"
    (
      tee_rc=1
      jq_rc=1
      write_status() {
        printf '%s %s\n' "$tee_rc" "$jq_rc" > "$TURN_STATUS.tmp" \
          && mv -f "$TURN_STATUS.tmp" "$TURN_STATUS"
      }
      trap write_status EXIT
      tee "$EVENTS" < "$TURN_PIPE" | jq --unbuffered -rj "$RENDER" 2>/dev/null
      render_pipeline=("${PIPESTATUS[@]}")
      tee_rc=${render_pipeline[0]}
      jq_rc=${render_pipeline[1]}
      write_status
      trap - EXIT
    ) &
    TURN_RENDER_PID=$!
    "$DECK" "${args[@]}" </dev/null > "$TURN_PIPE" &
    TURN_PID=$!
    while kill -0 "$TURN_PID" 2>/dev/null; do
      if ! watch_maintain; then
        monitor_failed=1
        kill -TERM "$TURN_PID" 2>/dev/null || true
        break
      fi
      sleep 0.1
    done
    wait "$TURN_PID" 2>/dev/null
    deck_rc=$?
    TURN_PID=''
    wait "$TURN_RENDER_PID" 2>/dev/null || true
    TURN_RENDER_PID=''
    if [ "$monitor_failed" -eq 0 ]; then
      watch_maintain || monitor_failed=1
    fi
    if ! IFS=' ' read -r tee_rc jq_rc < "$TURN_STATUS"; then
      tee_rc=1
      jq_rc=1
    fi
    turn_pipeline=("$deck_rc" "$tee_rc" "$jq_rc")
    [ "$monitor_failed" -eq 0 ] || return 1
  else
    "$DECK" "${args[@]}" </dev/null | tee "$EVENTS" | jq --unbuffered -rj "$RENDER" 2>/dev/null
    turn_pipeline=("${PIPESTATUS[@]}")
  fi
  rc=${turn_pipeline[0]}
  if [ "$SECONDMATE" = 1 ] && [ "$INTERRUPTED" != 1 ] && { [ "${turn_pipeline[1]}" -ne 0 ] || [ "${turn_pipeline[2]}" -ne 0 ]; }; then
    host_failure 'event capture or rendering failed' || true
    return 1
  fi
  if [ -t 1 ]; then
    printf '\033[u\033[J'
    jq -rj "$RENDER" "$EVENTS" 2>/dev/null
  fi
  if [ -z "$SESSION" ]; then
    SESSION=$(jq -r 'select(.type == "run_started") | .session' "$EVENTS" 2>/dev/null | head -1)
  fi
  if [ "$INTERRUPTED" = 1 ]; then
    printf '\nInterrupted.\n'
    event=interrupted
  elif [ "$rc" -eq 0 ]; then
    event=turn-end
  else
    event=turn-failed
  fi
  if [ "$INTERRUPTED" = 0 ] && [ "$rc" -ne 0 ] && [ -n "$SESSION" ] \
    && jq -e --arg error "run exceeded ${DEADLINE}s deadline" \
      'select(.type == "run_failed" and .error == $error)' "$EVENTS" >/dev/null 2>&1 \
    && deadline_wait_is_resumable; then
    if [ "$DEADLINE_ROLLOVERS" -ge "$DEADLINE_ROLLOVER_LIMIT" ]; then
      printf 'failed: Deck deadline rollover cap reached (%s/%s); validation or CI wait remains unfinished\n' \
        "$DEADLINE_ROLLOVERS" "$DEADLINE_ROLLOVER_LIMIT" | status_append || return 1
      record_busy_event idle turn-deadline-cap || return 1
      publish_turnend || return 1
      return 1
    fi
    DEADLINE_ROLLOVERS=$((DEADLINE_ROLLOVERS + 1))
    printf 'working: Deck deadline reached during validation or CI wait; resuming session (rollover %s/%s)\n' \
      "$DEADLINE_ROLLOVERS" "$DEADLINE_ROLLOVER_LIMIT" | status_append || return 1
    record_busy_event idle turn-deadline || return 1
    publish_turnend || return 1
    return 75
  fi
  status_before=$(cat "$TURN_MARK" 2>/dev/null || printf '0\n')
  if [ "$SECONDMATE" = 1 ]; then
    if [ "$event" = turn-end ] && ! jq -es 'any(.[]; .type == "run_finished") and (all(.[]; .type != "run_failed"))' "$EVENTS" >/dev/null; then
      event=turn-failed
    fi
    if [ "$event" = interrupted ] && [ -n "$SESSION" ]; then
      host_failure 'turn interrupted; returning to supervised prompt' || true
    elif [ "$event" != turn-end ] || [ -z "$SESSION" ]; then
      host_failure "turn failed ($event, exit $rc)" || true
      record_busy_event idle turn-failed || return 1
      publish_turnend || return 1
      return 1
    fi
    host_lock_owned || return 1
  elif ! status_has_worker_evidence "$status_before"; then
    if ! printf 'failed: deck turn ended without a status line (%s)\n' "$event" | status_append; then
      printf 'fm-deck-worker: could not safely append required turn evidence to %s\n' "$STATUS_FILE" >&2
      record_busy_event idle turn-failed || return 1
      publish_turnend || true
      return 1
    fi
  fi
  record_busy_event idle "$event" || return 1
  publish_turnend || return 1
}

run_with_deadline_resume() {
  local prompt=$1 rc
  while :; do
    run_turn "$prompt"
    rc=$?
    [ "$rc" = 75 ] || return "$rc"
    prompt='The previous bounded turn reached its wall-clock deadline during an in-flight no-mistakes validation or CI wait. Continue this same task and session. First inspect the existing run; do not start a duplicate pipeline or replay a state-changing command. Resume supervision from the existing evidence.'
  done
}

run_with_deadline_resume "$PROMPT" || exit 1
input_seq=0
show_prompt=1
while :; do
  if [ "$SECONDMATE" = 1 ]; then
    watch_start || exit 1
    watch_maintain || exit 1
    if [ -f "$WORK/input.$input_seq" ]; then
      if ! line=$(cat "$WORK/input.$input_seq"); then
        host_failure 'could not read queued input'; exit 1
      fi
      if [ "$line" = /quit ]; then
        rm "$WORK/input.$input_seq" || { host_failure 'could not consume queued exit'; exit 1; }
        record_busy_event idle session-end || exit 1
        exit 0
      fi
    fi
    if [ -s "$WATCH_PENDING" ]; then
      if ! doorbell=$(watch_doorbell); then
        host_failure 'could not publish watcher steering doorbell'; exit 1
      fi
      : > "$WATCH_PENDING"
      run_with_deadline_resume "$doorbell" || exit 1
      show_prompt=1
      continue
    fi
  fi
  if [ "$show_prompt" = 1 ]; then
    tty_ready
    printf '\n❯ '
    show_prompt=0
  fi
  INTERRUPTED=0
  if [ "$SECONDMATE" = 1 ]; then
    if [ -f "$WORK/input.$input_seq" ]; then
      line=$(cat "$WORK/input.$input_seq")
      rm "$WORK/input.$input_seq"
      input_seq=$((input_seq + 1))
    elif [ -f "$WORK/input.eof" ]; then
      record_busy_event idle session-end || exit 1
      exit 0
    elif ! kill -0 "$INPUT_PID" 2>/dev/null; then
      host_failure 'stdin reader failed'; exit 1
    else
      sleep 0.1
      continue
    fi
  elif ! IFS= read -r line; then
    [ "$INTERRUPTED" = 1 ] && continue
    record_busy_event idle session-end || exit 1
    exit 0
  fi
  case "$line" in
    '') continue ;;
    /quit)
      record_busy_event idle session-end || exit 1
      exit 0
      ;;
  esac
  run_with_deadline_resume "$line" || exit 1
  show_prompt=1
done
