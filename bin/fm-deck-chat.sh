#!/usr/bin/env bash
# fm-deck-chat.sh - host a `deck chat` primary for one firstmate home.
#
# The captain talks to the primary in deck's own terminal UI; this host is the
# process around it that firstmate's supervision contracts need:
#   - it is the session-lock owner: it runs as argv[0] `fm-deck-chat`, which
#     bin/fm-session-lock-lib.sh accepts as a harness, takes the lock with
#     bin/fm-lock.sh before anything else (so a second primary of ANY harness
#     is refused), and releases it on a clean exit;
#   - it runs bin/fm-session-start.sh exactly once and requires the completion
#     record to name this host before publishing startup input or launching
#     Deck. The digest (or a pointer to its full file when oversized) is the
#     first new steering message, published before registration and launch;
#     older pending messages are retained for the initial turn;
#   - it starts `deck chat --session <persisted id> --steer-dir <dir>
#     --events <file> --hook pre_complete=<lock check> [--mcp-config]
#     [--model]` in the foreground of this terminal (or of the stream endpoint
#     it was launched into);
#   - a supervisor child (bin/fm_primary_chat.py supervise) owns the watcher
#     (bin/fm-watch-arm.sh) and publishes each wake into the steering inbox
#     through bin/fm-primary-steer.sh. A failed watcher is logged and restarted
#     with backoff; the host never exits because the watcher died. While
#     state/.afk exists the away daemon owns the watcher, so the host pauses its
#     own;
#   - the same child maps deck's events (run_started/steer_received -> busy,
#     run_finished/run_stopped/run_failed/idle -> idle) to state/primary.busy-state
#     through bin/fm-busy-event.sh (source deck-wrapper);
#   - it writes state/primary-chat.json (bin/fm_primary_chat.py owns the layout)
#     and marks it stopped on exit.
# The primary's own tool calls run under deck, under this host, so
# fm_session_lock_owned_by_self holds for them exactly as for a Pi primary.
#
# USAGE
#   fm-deck-chat.sh [--home H] [--model ROUTE] [--session ID]
#       Run the host here, in this terminal. Exits when deck chat exits
#       (/quit, Ctrl+D, SIGTERM/SIGHUP).
#   fm-deck-chat.sh --stream [--home H] [--model ROUTE] [--session ID]
#       Start a stream endpoint (label primary-chat) through the stream
#       backend's own agent launcher, run the host inside it, print the
#       endpoint target and return. Attach from any terminal with
#       `bin/fm-stream.sh attach <target>` (read-only); send input through
#       `bin/fm-send.sh primary <text>`. For typing into the TUI, see
#       docs/stream-backend.md "Interactive attach".
#   fm-deck-chat.sh stop [--home H]
#       SIGTERM the registered host: deck quits and the host exits cleanly.
# --home defaults to FM_HOME, else this checkout. --session defaults to the id
# persisted in state/primary-chat/session (created on first run).
#
# ENVIRONMENT
#   FM_DECK_BIN            deck executable (default: deck on PATH)
#   FM_DECK_MCP_CONFIG     as for bin/fm-deck-worker.sh: non-empty = pass as-is,
#                          empty = no MCP; unset = <home>/config/deck-mcp.json
#                          when it exists
#   FM_DECK_CHAT_WATCH_BACKOFF, FM_DECK_CHAT_WATCH_BACKOFF_MAX
#                          watcher restart backoff seconds (default 2, max 60)
#   PROXAI_*               deck's endpoint settings; ~/.config/proxai/client.key
#                          is used when no key is set, as for deck workers
#
# Exit: deck chat's own exit code once it ran; 1 refused (lock held by another
# session, session start failed); 2 usage or missing prerequisite; 3 gate-context
# refusal (bin/fm-gate-refuse-lib.sh).
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PRIMARY_CHAT="$SCRIPT_DIR/fm_primary_chat.py"
BUSY_EVENT="$SCRIPT_DIR/fm-busy-event.sh"

usage() { sed -n '/^# USAGE/,/^# ENVIRONMENT/p' "$SCRIPT_DIR/fm-deck-chat.sh" | sed '$d' >&2; exit 2; }
die() { printf 'fm-deck-chat: %s\n' "$1" >&2; exit "${2:-1}"; }
q() { printf '%q' "$1"; }

# Every mode starts, steers or stops a primary: refuse a no-mistakes gate agent.
# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
fm_refuse_if_gate_agent

MODE=run
case "${1:-}" in
  stop) MODE=stop; shift ;;
esac
HOME_DIR=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
MODEL='' SESSION='' ENDPOINT='' STREAM=0
while [ $# -gt 0 ]; do
  case "$1" in
    --home) HOME_DIR=${2-}; shift 2 || usage ;;
    --model) MODEL=${2-}; shift 2 || usage ;;
    --session) SESSION=${2-}; shift 2 || usage ;;
    --endpoint) ENDPOINT=${2-}; shift 2 || usage ;;
    --stream) STREAM=1; shift ;;
    -h|--help) usage ;;
    *) printf 'fm-deck-chat: unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || die "home not found: $HOME_DIR" 2
HOME_DIR=$(cd "$HOME_DIR" && pwd)
export FM_HOME=$HOME_DIR
STATE="$FM_HOME/state"
command -v python3 >/dev/null 2>&1 || die 'python3 is required' 2

if [ "$MODE" = stop ]; then
  pid=$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); print("" if r.get("stopped_at") else r.get("host_pid",""))' \
    "$STATE/primary-chat.json" 2>/dev/null) || pid=''
  case "$pid" in ''|*[!0-9]*) die 'no deck-chat primary is registered for this home' ;; esac
  case "$(ps -o args= -p "$pid" 2>/dev/null)" in
    *fm-deck-chat*) ;;
    *) die "registered host pid $pid is not running" ;;
  esac
  kill -TERM "$pid" || die "could not signal host pid $pid"
  # A stream agent reaps its child on its own poll, so an exited host can
  # linger as a zombie; that counts as stopped.
  for _ in $(seq 1 300); do
    case "$(ps -o stat= -p "$pid" 2>/dev/null)" in
      ''|Z*) echo "fm-deck-chat: host pid $pid stopped"; exit 0 ;;
    esac
    sleep 0.1
  done
  die "host pid $pid did not stop within 30s"
fi

if [ "$STREAM" = 1 ]; then
  # The endpoint is created by the stream backend's own agent launcher, so a
  # launcher change there (Python or Rust agent) applies to the primary too.
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  fm_backend_source stream || exit 2
  fm_backend_stream_tool_check || exit 2
  fm_backend_stream_container_ensure >/dev/null || exit 1
  created=$(fm_backend_stream_create_task primary-chat "$FM_HOME" "" "") || exit 1
  target="${created% *}:${created#* }"
  launch="exec $(q "$SCRIPT_DIR/fm-deck-chat.sh") --home $(q "$FM_HOME") --endpoint $(q "$target")"
  [ -z "$MODEL" ] || launch="$launch --model $(q "$MODEL")"
  [ -z "$SESSION" ] || launch="$launch --session $(q "$SESSION")"
  fm_backend_stream_send_text_line "$target" "$launch" || {
    fm_backend_stream_kill "$target" >/dev/null 2>&1 || true
    die "could not launch the host in stream endpoint $target"
  }
  # The endpoint's interactive shell reads the operator's rc files first,
  # which can take a while.
  for _ in $(seq 1 900); do
    if status=$("$SCRIPT_DIR/fm-primary-steer.sh" status --home "$FM_HOME" 2>/dev/null) \
        && [ "$(printf '%s' "$status" | jq -r '.endpoint // empty')" = "$target" ]; then
      printf 'primary-chat: running in stream endpoint %s\n' "$target"
      printf 'attach: bin/fm-stream.sh attach %s\n' "$target"
      printf 'input: bin/fm-send.sh primary <text>\n'
      printf 'note: typing into the TUI needs bin/fm-stream.sh attach --interactive (built separately).\n'
      exit 0
    fi
    sleep 0.1
  done
  fm_backend_stream_capture "$target" 40 2>/dev/null | tail -n 20 >&2 || true
  die "the host did not register from stream endpoint $target within 90s; the endpoint is left running for inspection"
fi

# Run mode. Re-exec once under the harness name the session lock recognises.
if [ "${FM_DECK_CHAT_HOST:-}" != "$$" ]; then
  again=(--home "$FM_HOME")
  [ -z "$MODEL" ] || again+=(--model "$MODEL")
  [ -z "$SESSION" ] || again+=(--session "$SESSION")
  [ -z "$ENDPOINT" ] || again+=(--endpoint "$ENDPOINT")
  FM_DECK_CHAT_HOST=$$ exec -a fm-deck-chat bash "$SCRIPT_DIR/fm-deck-chat.sh" "${again[@]}"
fi
unset FM_DECK_CHAT_HOST
# Harness identity markers inherited from a launching session would misdetect
# this primary's harness (bin/fm-harness.sh); deck sets none of its own.
unset CLAUDECODE PI_CODING_AGENT GROK_AGENT FM_PI_HARNESS
cd "$FM_HOME" || exit 2
DECK=${FM_DECK_BIN:-$(command -v deck 2>/dev/null || true)}
[ -n "$DECK" ] && [ -x "$DECK" ] || die 'deck is not installed (set FM_DECK_BIN)' 2
chat_help=$("$DECK" chat --help 2>&1) || die "$DECK has no chat command" 2
case "$chat_help" in *--steer-dir*) ;; *) die "$DECK chat has no --steer-dir" 2 ;; esac
case "$chat_help" in *--events*) ;; *) die "$DECK chat has no --events" 2 ;; esac
if [ "${FM_DECK_MCP_CONFIG+set}" = set ]; then
  MCP_CONFIG=$FM_DECK_MCP_CONFIG
else
  MCP_CONFIG="$FM_HOME/config/deck-mcp.json"
  [ -f "$MCP_CONFIG" ] || MCP_CONFIG=''
fi
if [ -z "${PROXAI_API_KEY_FILE:-}${PROXAI_API_KEY:-}" ] && [ -f "$HOME/.config/proxai/client.key" ]; then
  export PROXAI_API_KEY_FILE="$HOME/.config/proxai/client.key"
fi

WORK='' GEN='' RECORDED=0 SUP_PID='' DECK_PID=''
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  if [ -n "$DECK_PID" ] && kill -0 "$DECK_PID" 2>/dev/null; then
    kill -TERM "$DECK_PID" 2>/dev/null || true
    wait "$DECK_PID" 2>/dev/null || true
  fi
  if [ -n "$SUP_PID" ]; then
    kill -TERM "$SUP_PID" 2>/dev/null || true
    wait "$SUP_PID" 2>/dev/null || true
  fi
  [ -z "$GEN" ] || "$BUSY_EVENT" apply "$STATE" primary idle --gen "$GEN" --source deck-wrapper \
    --event session-end >/dev/null 2>&1 || true
  [ "$RECORDED" != 1 ] || python3 "$PRIMARY_CHAT" record stop --home "$FM_HOME" --host-pid $$ || true
  # Release only a lock this host holds; a refused start never touches it.
  [ "$(cat "$STATE/.lock" 2>/dev/null)" != "$$" ] || rm -f "$STATE/.lock"
  [ -z "$WORK" ] || rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP TERM

# The lock comes first: it refuses a second primary of any harness, including
# a second host, before this one changes anything.
"$SCRIPT_DIR/fm-lock.sh" >&2 || die 'the home session lock is held by another session; not starting'
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-deck-chat.XXXXXX") || exit 1
prepared=$(python3 "$PRIMARY_CHAT" prepare --home "$FM_HOME" --session "$SESSION") || die "could not prepare the primary-chat state" 2
SESSION=$(printf '%s\n' "$prepared" | sed -n 's/^session=//p')
STEER_DIR=$(printf '%s\n' "$prepared" | sed -n 's/^steer_dir=//p')
EVENTS=$(printf '%s\n' "$prepared" | sed -n 's/^events_file=//p')
EVENTS_OFFSET=$(printf '%s\n' "$prepared" | sed -n 's/^events_offset=//p')
LOG="$STATE/primary-chat/host.log"
if ! "$SCRIPT_DIR/fm-session-start.sh" > "$WORK/startup" 2>&1; then
  cat "$WORK/startup" >&2
  die 'session start failed'
fi
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
fm_session_lock_owned_by_self "$STATE" || die 'session start did not leave this host holding the session lock'
if [ "$(cat "$STATE/.session-start-complete" 2>/dev/null)" != "$$" ]; then
  cat "$WORK/startup" >&2
  die 'session start did not publish a complete digest'
fi
GEN=$("$BUSY_EVENT" arm "$STATE" primary --state idle --source deck-wrapper --event host-start) \
  || die 'could not arm the primary busy-state record'

# The digest is the first new steer; older pending input is retained for the
# initial turn. deck's per-message limit is 64 KiB; a larger digest stays in
# a file the first message points at.
{
  printf 'You are the primary firstmate, hosted by bin/fm-deck-chat.sh as a deck chat session.\n'
  printf 'The host already ran bin/fm-session-start.sh exactly once for this session; do not run it again.\n'
  printf 'The host owns the watcher: wakes and other supervisor input arrive as steering messages. Do not arm a watcher yourself.\n\n'
} > "$WORK/first"
if [ "$(wc -c < "$WORK/startup")" -le 60000 ]; then
  { printf 'Session start digest:\n'; cat "$WORK/startup"; } >> "$WORK/first"
else
  cp "$WORK/startup" "$STATE/primary-chat/startup-digest.txt"
  printf 'The session start digest is too large for one message. Read all of %s before anything else.\n' \
    "$STATE/primary-chat/startup-digest.txt" >> "$WORK/first"
fi
python3 "$PRIMARY_CHAT" record write --home "$FM_HOME" --session "$SESSION" --host-pid $$ \
  --endpoint "$ENDPOINT" --startup-file "$WORK/first" || die 'could not publish startup and write state/primary-chat.json'
RECORDED=1

python3 "$PRIMARY_CHAT" supervise --home "$FM_HOME" --host-pid $$ --gen "$GEN" \
  --events-offset "$EVENTS_OFFSET" </dev/null >>"$LOG" 2>&1 &
SUP_PID=$!

LOCK_HOOK="bash -c $(q ". $(q "$SCRIPT_DIR/fm-session-lock-lib.sh"); fm_session_lock_owned_by_self $(q "$STATE") || { echo 'Home session lock lost; report the failure and stop.' >&2; exit 2; }")"
args=(chat --session "$SESSION" --steer-dir "$STEER_DIR" --events "$EVENTS" --hook "pre_complete=$LOCK_HOOK")
[ -z "$MCP_CONFIG" ] || args+=(--mcp-config "$MCP_CONFIG")
[ -z "$MODEL" ] || args+=(--model "$MODEL")
# deck stays in this terminal's foreground process group; explicit stdin keeps
# bash from pointing an asynchronous command at /dev/null.
trap ':' INT
trap '[ -z "$DECK_PID" ] || kill -TERM "$DECK_PID" 2>/dev/null' HUP TERM
"$DECK" "${args[@]}" <&0 &
DECK_PID=$!
rc=0
while :; do
  wait "$DECK_PID"; rc=$?
  kill -0 "$DECK_PID" 2>/dev/null || break
done
DECK_PID=''
exit "$rc"
