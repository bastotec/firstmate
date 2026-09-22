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
#     until the worker has appended a line to its status log during that turn;
#     the driver backstops failed, refused, and interrupted turns with a failure
#     status when Deck exits without growing the log;
#   - Ctrl+C cancels the running turn and returns to the prompt; `/quit` at the
#     prompt ends the worker.
#
# USAGE (bin/fm-spawn.sh builds this; the brief arrives already encoded)
#   fm-deck-worker.sh --id <task-id> --state <state-dir> --gen <busy-gen>
#       --turnend <file> --deck <deck-binary> [--model <route>] -- <first-prompt>
#
# ENVIRONMENT
#   FM_DECK_MAX_TURNS       model calls per turn (default 200; Deck's own 24 is
#                           sized for a single question, not a coding task)
#   FM_DECK_DEADLINE_SECS   wall-clock bound per turn (default 3600)
#   PROXAI_BASE_URL, PROXAI_MODEL, PROXAI_API_KEY_FILE, PROXAI_API_KEY
#                           Deck's own endpoint settings, passed through. When
#                           neither key variable is set and
#                           ~/.config/proxai/client.key exists, that file is used.
#
# Exit: 0 on /quit or end of input; 2 on a usage error.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
BUSY_EVENT="$SCRIPT_DIR/fm-busy-event.sh"

ID='' STATE='' GEN='' TURNEND='' DECK='' MODEL=''
while [ $# -gt 0 ]; do
  case "$1" in
    --id) ID=${2-}; shift 2 ;;
    --state) STATE=${2-}; shift 2 ;;
    --gen) GEN=${2-}; shift 2 ;;
    --turnend) TURNEND=${2-}; shift 2 ;;
    --deck) DECK=${2-}; shift 2 ;;
    --model) MODEL=${2-}; shift 2 ;;
    --) shift; break ;;
    *) echo "fm-deck-worker: unknown argument: $1" >&2; exit 2 ;;
  esac
done
PROMPT=${1-}
if [ -z "$ID" ] || [ -z "$STATE" ] || [ -z "$DECK" ] || [ -z "$PROMPT" ]; then
  echo "fm-deck-worker: --id, --state, --deck, and a first prompt are required" >&2
  exit 2
fi
command -v jq >/dev/null 2>&1 || { echo "fm-deck-worker: jq is required to render Deck's event stream" >&2; exit 2; }

STATUS_FILE="$STATE/$ID.status"
MAX_TURNS=${FM_DECK_MAX_TURNS:-200}
DEADLINE=${FM_DECK_DEADLINE_SECS:-3600}
case "$MAX_TURNS" in ''|*[!0-9]*) MAX_TURNS=200 ;; esac
case "$DEADLINE" in ''|*[!0-9]*) DEADLINE=3600 ;; esac
if [ -z "${PROXAI_API_KEY_FILE:-}${PROXAI_API_KEY:-}" ] && [ -f "$HOME/.config/proxai/client.key" ]; then
  export PROXAI_API_KEY_FILE="$HOME/.config/proxai/client.key"
fi

WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-deck-worker.XXXXXX") || exit 2
TURN_MARK="$WORK/turn-start"
EVENTS="$WORK/events.ndjson"
cleanup() { rm -rf -- "$WORK"; }
trap cleanup EXIT
# Ctrl+C reaches the whole foreground group: Deck and the renderer stop, this
# driver survives, records the cancelled turn, and returns to the prompt.
INTERRUPTED=0
trap 'INTERRUPTED=1' INT

busy_event() {  # <busy|idle> <event>
  [ -n "$GEN" ] || return 0
  "$BUSY_EVENT" apply "$STATE" "$ID" "$1" --gen "$GEN" --source deck-wrapper --event "$2" >/dev/null 2>&1 || true
}

status_size() {
  { { wc -c < "$STATUS_FILE"; } 2>/dev/null || printf '0\n'; } | tr -d '[:space:]'
}

q() { printf '%q' "$1"; }

# The evidence gate: the turn may finish only after it appended to the status
# log, proven by the log having grown past its size at turn start (a size, not
# an mtime: bash 3.2's -nt compares whole seconds, so a fast turn would be
# refused). Deck feeds this stderr back to the model and fails the run after
# its own bounded number of refusals.
EVIDENCE_HOOK="[ \"\$(wc -c < $(q "$STATUS_FILE") 2>/dev/null || echo 0)\" -gt \"\$(cat $(q "$TURN_MARK") 2>/dev/null || echo 0)\" ] || { echo $(q "Before you finish, append one line to $STATUS_FILE as your instructions' status protocol describes (done:, needs-decision:, blocked:, failed:, or working:), stating what you did and the evidence. Then finish.") >&2; exit 2; }"
PROGRESS_HOOK=''
[ -z "$GEN" ] || PROGRESS_HOOK="$(q "$BUSY_EVENT") progress $(q "$STATE") $(q "$ID") --gen $(q "$GEN") >/dev/null 2>&1 || true"

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
  local prompt=$1 rc event status_before status_after
  local -a args=(run "$prompt" --max-turns "$MAX_TURNS" --deadline-secs "$DEADLINE" --hook "pre_complete=$EVIDENCE_HOOK")
  [ -z "$PROGRESS_HOOK" ] || args+=(--hook "post_tool_use=$PROGRESS_HOOK")
  [ -z "$MODEL" ] || args+=(--model "$MODEL")
  [ -z "$SESSION" ] || args+=(--session "$SESSION")
  INTERRUPTED=0
  status_size > "$TURN_MARK"
  busy_event busy turn-start
  # The delivery acknowledgement token (bin/fm-composer-lib.sh) for a submitted line.
  printf '\n⛵ deck working - ctrl+c to stop\n'
  "$DECK" "${args[@]}" 2>&1 </dev/null | tee "$EVENTS" | jq --unbuffered -rj "$RENDER" 2>/dev/null
  rc=${PIPESTATUS[0]}
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
  status_before=$(cat "$TURN_MARK" 2>/dev/null || printf '0\n')
  status_after=$(status_size)
  if [ "$status_after" -le "$status_before" ]; then
    printf 'failed: deck turn ended without a status line (%s)\n' "$event" >> "$STATUS_FILE" || {
      printf 'fm-deck-worker: could not append required turn evidence to %s\n' "$STATUS_FILE" >&2
      exit 1
    }
  fi
  busy_event idle "$event"
  [ -z "$TURNEND" ] || touch "$TURNEND" 2>/dev/null || true
}

run_turn "$PROMPT"
while :; do
  printf '\n❯ '
  INTERRUPTED=0
  if ! IFS= read -r line; then
    [ "$INTERRUPTED" = 1 ] && continue
    busy_event idle session-end
    exit 0
  fi
  case "$line" in
    '') continue ;;
    /quit)
      busy_event idle session-end
      exit 0
      ;;
  esac
  run_turn "$line"
done
