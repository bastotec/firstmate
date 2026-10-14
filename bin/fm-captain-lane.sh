#!/usr/bin/env bash
# fm-captain-lane.sh - a split second mate's captain thread, run as a child of
# its home host (bin/fm-deck-worker.sh --secondmate).
#
# Usage (the host starts it; FM_HOME is the mate's home):
#   fm-captain-lane.sh --state <task-state-dir> --id <task-id> --deck <deck>
#       [--model <route>] [--model-file <file>] [--mcp-config <file>]
#
# With the mate's home split (config/primary-split), the captain's own words
# ([fm-captain-direct] records in <state>/<id>.inbox) are this lane's alone:
# bin/fm_stream_deck.py keeps them out of the supervisor's turns while
# <state>/<id>.captain-lane exists, which the host writes before starting this
# lane and removes when it stops. The lane takes them one at a time in inbox
# order and runs each as one `deck run` turn of the mate's existing Deck
# session (<state>/<id>.deck-session, so the conversation Fleet Town shows and
# its history are the captain thread's), concurrently with whatever the
# supervisor is doing, so his answer never waits behind supervision:
#   - the turn reads no project context (--no-project-context) and has no
#     session-lock hook: the host holds the lock for the supervisor;
#   - the first turn of each lane process carries
#     .agents/skills/captain-thread/SKILL.md as its contract;
#   - FM_CAPTAIN_LANE_STATE/FM_CAPTAIN_LANE_ID let bin/fm-captain-handoff.sh hand
#     his orders to the supervisor;
#   - a finished turn moves the record to handled/ itself; a failed turn keeps
#     it and retries after 30 s, doubling to 300 s.
# The lane writes its Deck events to <work>/events.ndjson and its own log lines
# to stderr. It exits when the host goes away, and a TERM stops its running
# Deck turn first (bounded), so a replacement lane never runs beside it.
# Attachments map to Deck image parts as on the native path
# (bin/fm_stream_deck.py with_deck_images).
set -u
SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
STATE='' ID='' DECK='' MODEL='' MODEL_FILE='' MCP_CONFIG=''
while [ $# -gt 0 ]; do
  case "$1" in
    --state) STATE=${2-}; shift 2 ;;
    --id) ID=${2-}; shift 2 ;;
    --deck) DECK=${2-}; shift 2 ;;
    --model) MODEL=${2-}; shift 2 ;;
    --model-file) MODEL_FILE=${2-}; shift 2 ;;
    --mcp-config) MCP_CONFIG=${2-}; shift 2 ;;
    *) printf 'fm-captain-lane: unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
done
[ -n "$STATE" ] && [ -n "$ID" ] && [ -n "$DECK" ] && [ -n "${FM_HOME:-}" ] || {
  echo 'fm-captain-lane: needs --state, --id, --deck and FM_HOME' >&2; exit 2; }
cd "$FM_HOME" || exit 2
HOST_PID=$PPID
POLL=0.5 RETRY=30 DEADLINE=900
INBOX="$STATE/$ID.inbox"
RECORD="$STATE/$ID.deck-session"
DECK_SESSIONS="${XDG_STATE_HOME:-$HOME/.local/state}/deck/sessions"
CONTRACT="$SCRIPT_DIR/../.agents/skills/captain-thread/SKILL.md"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-captain-lane.XXXXXX") || exit 1
DECK_PID=''
stop_deck() {
  [ -n "$DECK_PID" ] || return 0
  kill -TERM "$DECK_PID" 2>/dev/null || true
  local i=0
  while kill -0 "$DECK_PID" 2>/dev/null && [ "$i" -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  kill -KILL "$DECK_PID" 2>/dev/null || true
  wait "$DECK_PID" 2>/dev/null || true
  DECK_PID=''
}
trap 'stop_deck; rm -rf -- "$WORK"' EXIT
trap 'exit 143' TERM HUP
export FM_CAPTAIN_LANE_STATE=$STATE FM_CAPTAIN_LANE_ID=$ID
# Ctrl+C in the host's pane stops the supervisor's turn, never the captain's.
trap '' INT
log() { printf 'fm-captain-lane: %s\n' "$*" >&2; }

# The mate's recorded session, if it belongs to this home and Deck still has it.
session_of() {
  local id home
  id=$(head -n 1 "$RECORD" 2>/dev/null || true)
  home=$(sed -n '2p' "$RECORD" 2>/dev/null || true)
  case "$id" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "$home" = "$FM_HOME" ] && [ -f "$DECK_SESSIONS/$id.json" ] || return 1
  printf '%s' "$id"
}

# The oldest pending record that carries the captain's own words.
next_record() {
  python3 - "$SCRIPT_DIR" "$INBOX" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from fm_stream_deck import CAPTAIN_ONLY
found = []
for source in Path(sys.argv[2]).glob('*.msg'):
    if not source.stem.isdigit():
        continue
    try:
        body = source.read_bytes().decode('utf-8').split('\n--\n', 1)[1]
    except (OSError, IndexError, UnicodeDecodeError):
        continue
    if CAPTAIN_ONLY.match(body):
        found.append((int(source.stem), str(source)))
if found:
    print(min(found)[1])
PY
}

contract_sent=0
retry_at=0 backoff=0
while kill -0 "$HOST_PID" 2>/dev/null; do
  rec=$(next_record) || rec=''
  if [ -z "$rec" ] || [ "$(date +%s)" -lt "$retry_at" ]; then
    sleep "$POLL"
    continue
  fi
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$SCRIPT_DIR/fm-task-inbox-lib.sh" "$rec" 2>/dev/null) || body=''
  [ -n "$body" ] || { log "could not read $rec"; sleep "$POLL"; continue; }
  if imaged=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from fm_stream_deck import with_deck_images; sys.stdout.write(with_deck_images(sys.argv[2]))' "$SCRIPT_DIR" "$body" 2>/dev/null) \
      && [ -n "$imaged" ]; then
    body=$imaged
  fi
  prompt="The captain wrote to this second mate directly (record $rec):

$body"
  if [ "$contract_sent" = 0 ] && [ -r "$CONTRACT" ]; then
    prompt="You are the captain thread of this second mate, run beside its supervisor by bin/fm-captain-lane.sh. Your contract follows; it replaces any earlier role in this conversation.

$(awk 'seen >= 2 { print } /^---$/ { seen++ }' "$CONTRACT")

$prompt"
  fi
  model=$MODEL
  switched=$(head -1 "$MODEL_FILE" 2>/dev/null || true)
  case "$switched" in ''|*[!A-Za-z0-9._:@/-]*) ;; *) model=$switched ;; esac
  args=(run "$prompt" --no-project-context --max-turns 60 --deadline-secs "$DEADLINE")
  [ -z "$model" ] || args+=(--model "$model")
  [ -z "$MCP_CONFIG" ] || args+=(--mcp-config "$MCP_CONFIG")
  if session=$(session_of); then args+=(--session "$session"); else session=''; fi
  : > "$WORK/events.ndjson"
  rc=0
  "$DECK" "${args[@]}" </dev/null > "$WORK/events.ndjson" 2>"$WORK/deck.err" &
  DECK_PID=$!
  wait "$DECK_PID" || rc=$?
  DECK_PID=''
  if [ -z "$session" ]; then
    started=$(jq -r 'select(.type == "run_started") | .session' "$WORK/events.ndjson" 2>/dev/null | head -1)
    case "$started" in
      ''|*[!A-Za-z0-9._-]*) ;;
      *) printf '%s\n%s\n' "$started" "$FM_HOME" > "$RECORD.tmp.$$" && mv -f "$RECORD.tmp.$$" "$RECORD" ;;
    esac
  fi
  if [ "$rc" -eq 0 ] && jq -es 'any(.[]; .type == "run_finished") and all(.[]; .type != "run_failed")' \
      "$WORK/events.ndjson" >/dev/null 2>&1; then
    contract_sent=1
    backoff=0 retry_at=0
    if [ -f "$rec" ]; then
      if ! { mkdir -p "$INBOX/handled" && mv -f "$rec" "$INBOX/handled/${rec##*/}"; }; then
        log "could not acknowledge $rec"
      fi
    fi
  else
    backoff=$(( backoff ? backoff * 2 : RETRY ))
    [ "$backoff" -le 300 ] || backoff=300
    retry_at=$(( $(date +%s) + backoff ))
    log "turn for ${rec##*/} failed (exit $rc); retrying in ${backoff}s: $(tail -n 1 "$WORK/deck.err" 2>/dev/null)"
  fi
done
