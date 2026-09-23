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
#     finished turn touches the task's turn-end notification file;
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
#       --deck <deck-binary> [--model <route>] -- <first-prompt>
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
# Exit: 0 on /quit or end of input; 2 on a usage error.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BUSY_EVENT="$SCRIPT_DIR/fm-busy-event.sh"
STATE_IO="$SCRIPT_DIR/fm-state-io.py"

ID='' STATE='' GEN='' DECK='' MODEL=''
while [ $# -gt 0 ]; do
  case "$1" in
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
TTY_SETTINGS=''
[ ! -t 0 ] || TTY_SETTINGS=$(stty -g 2>/dev/null || true)
tty_busy() { [ -z "$TTY_SETTINGS" ] || stty icanon 2>/dev/null || true; }
tty_ready() { [ -z "$TTY_SETTINGS" ] || stty -icanon min 1 time 0 2>/dev/null || true; }
cleanup() {
  [ -z "$TTY_SETTINGS" ] || stty "$TTY_SETTINGS" 2>/dev/null || true
  rm -rf -- "$WORK"
}
trap cleanup EXIT
# Ctrl+C reaches the whole foreground group: Deck and the renderer stop, this
# driver survives, records the cancelled turn, and returns to the prompt.
INTERRUPTED=0
trap 'INTERRUPTED=1' INT
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

SESSION=''
run_turn() {  # <prompt>
  local prompt=$1 rc event status_before
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
  "$DECK" "${args[@]}" </dev/null | tee "$EVENTS" | jq --unbuffered -rj "$RENDER" 2>/dev/null
  rc=${PIPESTATUS[0]}
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
  if ! status_has_worker_evidence "$status_before"; then
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
while :; do
  tty_ready
  printf '\n❯ '
  INTERRUPTED=0
  if ! IFS= read -r line; then
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
done
