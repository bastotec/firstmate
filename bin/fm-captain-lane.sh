#!/usr/bin/env bash
# fm-captain-lane.sh - a split second mate's captain thread, run as a child of
# its home host (bin/fm-deck-worker.sh --secondmate).
#
# Usage (the host starts it; FM_HOME is the mate's home):
#   fm-captain-lane.sh --state <task-state-dir> --id <task-id> --deck <deck>
#       [--model <route>] [--model-file <file>] [--mcp-config <file>]
#
# With the mate's home split (config/primary-split), its conversation is this
# lane's alone: every record in <state>/<id>.inbox that
# bin/fm_stream_deck.py record_stream classifies as conversation (the captain's,
# the first mate's or another mate's words, and its supervisor's notes from
# bin/fm-captain-note.sh). fm_stream_deck.py keeps them out of the supervisor's
# turns, its inner monologue, while <state>/<id>.captain-lane exists, which the host writes before starting this
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
#     the conversation's orders to the supervisor;
#   - <state>/<id>.captain-lane.answered is the turn journal; the journal
#     comment below owns recovery, acknowledgement and fail-closed rules;
#   - <state>/<id>.captain-lane.turn names the record whose Deck turn is running;
#     bin/fm_stream_deck.py conversation_busy owns busy-observation semantics.
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
# shellcheck source=bin/fm-process-tree-lib.sh
. "$SCRIPT_DIR/fm-process-tree-lib.sh"
DECK_PID=''
# The host's turn-stop semantics (bin/fm-deck-worker.sh "SECOND MATE TURN
# STOP"): cooperative TERM, the running tool trees cancelled after a one-second
# grace, and Deck itself killed at ten seconds.
stop_deck() {
  [ -n "$DECK_PID" ] || return 0
  kill -TERM "$DECK_PID" 2>/dev/null || true
  local i=0
  while kill -0 "$DECK_PID" 2>/dev/null && [ "$i" -lt 100 ]; do
    [ "$i" -ne 10 ] || fm_cancel_tool_trees "$DECK_PID"
    sleep 0.1
    i=$((i + 1))
  done
  kill -KILL "$DECK_PID" 2>/dev/null || true
  wait "$DECK_PID" 2>/dev/null || true
  DECK_PID=''
}
# Bind a newly created session as soon as Deck has saved it, on every exit too.
# With FM_DECK_FRESH_SESSION=1 the lane ignores the existing binding and
# replaces it with the first session it opens.
fresh=${FM_DECK_FRESH_SESSION:-0}
record_session() {
  local started
  if [ "$fresh" != 1 ]; then [ -z "$(session_of 2>/dev/null)" ] || return 0; fi
  started=$(jq -r 'select(.type == "run_started") | .session' "$WORK/events.ndjson" 2>/dev/null | head -1)
  [ -n "$started" ] || started=${observed:-}
  case "$started" in ''|*[!A-Za-z0-9._-]*) return 0 ;; esac
  [ -f "$DECK_SESSIONS/$started.json" ] || return 0
  printf '%s\n%s\n' "$started" "$FM_HOME" > "$RECORD.tmp.$$" && mv -f "$RECORD.tmp.$$" "$RECORD" && fresh=0
}
trap 'stop_deck; record_session; rm -f "$STATE/$ID.captain-lane.turn"; rm -rf -- "$WORK"' EXIT
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

# The lane's journal: one "<state> <record>" line per step, the last line for a
# record winning: started (its turn is about to run), answered (its turn
# finished), failed (its turn failed), recovering (its one recovery turn after
# an interrupted start). A turn starts only after started/recovering is written;
# a successful result is journaled before acknowledgement or another turn.
# An answered record is never run again; its move to handled/ is retried every
# pass while later records proceed. An unreadable or unwritable journal permits
# no turns, and an answer that cannot be journaled holds later turns until it can.
# A record left started gets one recovery turn; a failed record keeps its inbox
# source and retries after 30 s, doubling to 300 s. Both first ask the model to
# check the conversation for an earlier answer: that check is model-level, not
# deterministic proof of an interrupted answer. A record left recovering by an
# interrupted recovery is never run again. tests/fm-captain-lane.test.sh pins
# these journal transitions and the acknowledgement retry behavior.
ANSWERED="$STATE/$ID.captain-lane.answered"
TURN_MARK="$STATE/$ID.captain-lane.turn"
rm -f "$TURN_MARK"
journal() {  # <state> <record-name>
  printf '%s %s\n' "$1" "$2" >> "$ANSWERED" 2>/dev/null
}
# Move every answered record still in the inbox to handled/, and forget the
# records that are gone.
acknowledge_answered() {
  [ -s "$ANSWERED" ] || return 0
  [ -r "$ANSWERED" ] && [ -w "$ANSWERED" ] || return 1
  python3 - "$ANSWERED" "$INBOX" <<'PY'
import os, sys
from pathlib import Path
journal, inbox = Path(sys.argv[1]), Path(sys.argv[2])
last = {}
for line in journal.read_text().splitlines():
    state, _, name = line.partition(' ')
    if name:
        last[name] = state
keep = []
for name, state in last.items():
    source = inbox / name
    if state == 'answered' and source.is_file():
        try:
            (inbox / 'handled').mkdir(exist_ok=True)
            os.replace(source, inbox / 'handled' / name)
            continue
        except OSError:
            pass
    if source.is_file():
        keep.append('%s %s' % (state, name))
tmp = journal.with_name(journal.name + '.tmp.%d' % os.getpid())
tmp.write_text(''.join(line + '\n' for line in keep))
os.replace(tmp, journal)
PY
}

# "<new|recover|retry> <path>": the oldest pending captain record the journal allows
# to run, or nothing. An unreadable journal allows nothing.
next_record() {
  python3 - "$SCRIPT_DIR" "$INBOX" "$ANSWERED" <<'PY'
import sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
from fm_stream_deck import conversation_record
last = {}
try:
    for line in Path(sys.argv[3]).read_text().splitlines():
        state, _, name = line.partition(' ')
        if name:
            last[name] = state
except FileNotFoundError:
    pass
except OSError:
    sys.exit(3)
found = []
for source in Path(sys.argv[2]).glob('*.msg'):
    state = last.get(source.name)
    if not source.stem.isdigit() or state in ('answered', 'recovering'):
        continue
    try:
        record = source.read_bytes().decode('utf-8')
    except (OSError, UnicodeDecodeError):
        continue
    if conversation_record(record):
        found.append((int(source.stem), {'started': 'recover', 'failed': 'retry'}.get(state, 'new'), str(source)))
if found:
    number, mode, path = min(found)
    print(mode, path)
PY
}

# An order handed to the supervisor that is still unhandled after
# FM_HANDOFF_STALE_SECS (default 600) is reported once in the conversation,
# with the supervisor's state, so a stuck supervisor is never mistaken for a
# busy one. Checked every 30 s.
STALE_SECS=${FM_HANDOFF_STALE_SECS:-600}
case "$STALE_SECS" in ''|*[!0-9]*|0) STALE_SECS=600 ;; esac
STALE_NOTED="$STATE/$ID.captain-lane.stale-noted"
stale_checked=0
report_stale_handoffs() {
  local now names name state health
  now=$(date +%s)
  [ $((now - stale_checked)) -ge 30 ] || return 0
  stale_checked=$now
  names=$(python3 "$SCRIPT_DIR/fm_stream_deck.py" stale-handoffs "$STATE" "$ID" "$STALE_SECS" 2>/dev/null) || return 0
  [ -n "$names" ] || return 0
  health="$STATE/$ID.supervisor-failing"
  if [ -f "$health" ]; then
    state="failing since $(sed -n 's/^since=//p' "$health"): $(sed -n 's/^error=//p' "$health")"
  else
    state=$(sed -n 's/.* state=\([a-z]*\).*/\1/p' "$STATE/$ID.busy-state" 2>/dev/null)
  fi
  for name in $names; do
    FM_SPLIT_MATE_STATE="$STATE" FM_SPLIT_MATE_ID="$ID" "$SCRIPT_DIR/fm-captain-note.sh" \
      "Something I said I would do (record $name) is overdue: I have not finished or acknowledged it after $((STALE_SECS / 60)) minutes; my background work is ${state:-in an unknown state}." \
      >/dev/null 2>&1 && printf '%s\n' "$name" >> "$STALE_NOTED"
  done
}

# A run of failed conversation turns is reported to the first mate, the same
# way the host reports a failing supervisor: at FM_DECK_FAIL_ESCALATE (default
# 3) consecutive failures one keyed blocker
# "blocked [key=conversation-failing-<id>]: ..." with the last error and since
# when, closed by "resolved [key=...]" after the next answered turn. The run is
# kept in <state>/<id>.conversation-failing (since=, count=, escalated=), so a
# lane the first mate relaunched for it still resolves it once it answers. The
# line goes to the home's own parent channel (bin/fm-parent-channel-lib.sh,
# mirrored to the first mate for a remote mate), else, for a home with no
# parent binding, to <state>/<id>.status through the host's status helper. The
# first mate's revive scan acts on it (bin/fm-secondmate-revive.sh "LANE HEALTH").
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
LANE_HEALTH="$STATE/$ID.conversation-failing"
lane_report() {  # <line>
  local rc=0
  fm_parent_channel_report "$FM_HOME" "$FM_HOME/state" "$1" || rc=$?
  if [ "$rc" -eq 1 ]; then
    [ -n "${FM_DECK_STATUS_IO:-}" ] || return 1
    printf '%s\n' "$1" | python3 "$FM_DECK_STATUS_IO" root-append "$STATE" "$ID.status"
    return
  fi
  return "$rc"
}
lane_health_get() { sed -n "s/^$1=//p" "$LANE_HEALTH" 2>/dev/null | tail -1; }
lane_health_put() {  # <since> <count> <escalated>
  printf 'since=%s\ncount=%s\nescalated=%s\n' "$1" "$2" "$3" > "$LANE_HEALTH.tmp" \
    && mv -f "$LANE_HEALTH.tmp" "$LANE_HEALTH"
}
lane_turn_failed() {  # <failure text>
  local error limit=${FM_DECK_FAIL_ESCALATE:-3} since count escalated
  case "$limit" in ''|*[!0-9]*|0) limit=3 ;; esac
  error=$(printf '%s' "${1:-turn failed}" | tr '\n\t' '  ' | cut -c1-200)
  since=$(lane_health_get since); count=$(lane_health_get count); escalated=$(lane_health_get escalated)
  [ -n "$since" ] || since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  count=$((count + 1))
  if [ "$count" -ge "$limit" ] && [ "${escalated:-0}" != 1 ]; then
    lane_report "$(printf 'blocked [key=conversation-failing-%s]: %s conversation is failing every turn (%s consecutive): %s, since %s; messages to it are not being answered' \
      "$ID" "$ID" "$count" "$error" "$since")" && escalated=1
  fi
  lane_health_put "$since" "$count" "${escalated:-0}"
}
lane_turn_ok() {
  [ -f "$LANE_HEALTH" ] || return 0
  if [ "$(lane_health_get escalated)" = 1 ]; then
    lane_report "$(printf 'resolved [key=conversation-failing-%s]: %s conversation is answering again (failing since %s)' \
      "$ID" "$ID" "$(lane_health_get since)")" || return 0
  fi
  rm -f "$LANE_HEALTH"
}

contract_sent=0
retry_at=0 backoff=0 unrecorded='' observed=''
while kill -0 "$HOST_PID" 2>/dev/null; do
  # Fail closed: an answer the journal could not take holds every later turn
  # until it does, and no turn starts unless its start is journaled.
  if [ -n "$unrecorded" ]; then
    if journal answered "$unrecorded"; then unrecorded=''; else sleep "$POLL"; continue; fi
  fi
  acknowledge_answered || true
  if ! { : >> "$ANSWERED"; } 2>/dev/null; then
    log "cannot write $ANSWERED; taking no captain turns until it can"
    sleep 5
    continue
  fi
  report_stale_handoffs
  next=$(next_record) || next=''
  if [ -z "$next" ] || [ "$(date +%s)" -lt "$retry_at" ]; then
    sleep "$POLL"
    continue
  fi
  mode=${next%% *} rec=${next#* }
  name=${rec##*/}
  body=$(bash -c '. "$1"; fm_task_inbox_body "$2"' _ "$SCRIPT_DIR/fm-task-inbox-lib.sh" "$rec" 2>/dev/null) || body=''
  [ -n "$body" ] || { log "could not read $rec"; sleep "$POLL"; continue; }
  if imaged=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from fm_stream_deck import with_deck_images; sys.stdout.write(with_deck_images(sys.argv[2]))' "$SCRIPT_DIR" "$body" 2>/dev/null) \
      && [ -n "$imaged" ]; then
    body=$imaged
  fi
  party=$(python3 -c 'import sys; sys.path.insert(0, sys.argv[1]); from fm_stream_deck import record_party; print(record_party(sys.argv[2]))' \
    "$SCRIPT_DIR" "$body" 2>/dev/null) || party=firstmate
  case "$party" in
    captain) said="The captain wrote to this second mate directly" ;;
    mate:*) said="Another mate, ${party#mate:}, wrote to this second mate" ;;
    monologue) said="Your own background work wrote this for the reader; say it as your own news, in the first person" ;;
    *) said="The first mate wrote to this second mate" ;;
  esac
  prompt="$said (record $rec):

$body"
  if [ "$mode" != new ]; then
    prompt="An earlier turn on this message was interrupted or failed before its end was recorded. Read your last messages in this conversation first: if you already answered it, reply with nothing new and stop.

$prompt"
  fi
  if [ "$contract_sent" = 0 ] && [ -r "$CONTRACT" ]; then
    prompt="You are the captain thread of this second mate, run beside its supervisor by bin/fm-captain-lane.sh. Your contract follows; it replaces any earlier role in this conversation.

$(awk 'seen >= 2 { print } /^---$/ { seen++ }' "$CONTRACT")

$prompt"
  fi
  step=started
  [ "$mode" != recover ] || step=recovering
  journal "$step" "$name" || { log "cannot journal $name; not running its turn"; sleep 5; continue; }
  model=$MODEL
  switched=$(head -1 "$MODEL_FILE" 2>/dev/null || true)
  case "$switched" in ''|*[!A-Za-z0-9._:@/-]*) ;; *) model=$switched ;; esac
  args=(run "$prompt" --no-project-context --max-turns 60 --deadline-secs "$DEADLINE")
  [ -z "$model" ] || args+=(--model "$model")
  [ -z "$MCP_CONFIG" ] || args+=(--mcp-config "$MCP_CONFIG")
  # The bound session, else the one this lane already opened (its binding may
  # not have been written yet).
  session=''
  [ "$fresh" = 1 ] || session=$(session_of) || session=''
  if [ -z "$session" ] && [ -n "$observed" ] && [ -f "$DECK_SESSIONS/$observed.json" ]; then session=$observed; fi
  [ -z "$session" ] || args+=(--session "$session")
  : > "$WORK/events.ndjson"
  rc=0
  # <state>/<id>.captain-lane.turn names the record whose turn is running, so
  # supervision reads a running recovery as busy (fm_stream_deck.conversation_busy).
  printf '%s\n' "$name" > "$TURN_MARK" 2>/dev/null || true
  FM_CONVERSATION_PARTY=$party "$DECK" "${args[@]}" </dev/null > "$WORK/events.ndjson" 2>"$WORK/deck.err" &
  DECK_PID=$!
  # A host that goes away mid-turn takes this turn with it, so its replacement
  # never runs beside it. A new session is bound as soon as Deck saves it, so a
  # kill mid-turn never loses the conversation a recovery turn must check.
  while kill -0 "$DECK_PID" 2>/dev/null; do
    kill -0 "$HOST_PID" 2>/dev/null || exit 0
    [ -n "$session" ] || record_session
    sleep 0.2
  done
  wait "$DECK_PID" || rc=$?
  DECK_PID=''
  rm -f "$TURN_MARK"
  if [ -z "$session" ]; then
    observed=$(jq -r 'select(.type == "run_started") | .session' "$WORK/events.ndjson" 2>/dev/null | head -1)
    case "$observed" in ''|*[!A-Za-z0-9._-]*) observed='' ;; esac
  fi
  record_session
  if [ "$rc" -eq 0 ] && jq -es 'any(.[]; .type == "run_finished") and all(.[]; .type != "run_failed")' \
      "$WORK/events.ndjson" >/dev/null 2>&1; then
    contract_sent=1
    backoff=0 retry_at=0
    lane_turn_ok
    if journal answered "$name"; then
      acknowledge_answered || true
      [ ! -f "$rec" ] || log "answered $rec but could not move it to handled/ yet; retrying"
    else
      log "answered $rec but could not journal it; holding later turns"
      unrecorded=$name
    fi
  else
    journal failed "$name" || true
    lane_turn_failed "$(jq -rs '[.[] | select(.type == "run_failed") | .error // empty] | last // empty' "$WORK/events.ndjson" 2>/dev/null)"
    backoff=$(( backoff ? backoff * 2 : RETRY ))
    [ "$backoff" -le 300 ] || backoff=300
    retry_at=$(( $(date +%s) + backoff ))
    log "turn for $name failed (exit $rc); retrying in ${backoff}s: $(tail -n 1 "$WORK/deck.err" 2>/dev/null)"
  fi
done
