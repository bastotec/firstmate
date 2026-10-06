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
# Nothing inside the host can notice the host itself is gone, so on macOS a
# launchd user agent (install-service) runs a keeper outside it that restarts
# the host whenever it exits for any reason other than `stop`. deck chat exits 0
# with no event for /quit, Ctrl-D and SIGTERM alike, so a captain /quit cannot
# be told apart from a stray keystroke and is restarted too; `stop` is the only
# way to stop a serviced primary.
# The primary's own tool calls run under deck, under this host, so
# fm_session_lock_owned_by_self holds for them.
#
# USAGE
#   fm-deck-chat.sh [--home H] [--model ROUTE] [--session ID]
#       Run the host here, in this terminal. Exits when deck chat exits
#       (/quit, Ctrl+D, SIGTERM/SIGHUP).
#   fm-deck-chat.sh --stream [--home H] [--model ROUTE] [--session ID]
#       Start a stream endpoint (label primary-chat) through the stream
#       backend's own agent launcher, run the host inside it, print the
#       endpoint target and return. Use the TUI from any terminal with
#       `bin/fm-stream.sh attach --interactive <target>` (Ctrl-] detaches and
#       leaves the host running; docs/stream-backend.md "Interactive attach"
#       owns prerequisites). `bin/fm-send.sh primary <text>` also steers it.
#       Refuses (exit 1) while a live host is already registered for the home.
#       Before creating a new endpoint, waits for the previous recorded endpoint
#       to close and requests its close if still open (one live label per machine).
#       After dispatch, waits up to 150s for host registration and fails fast
#       when the endpoint's agent reports the host exited. A registration
#       timeout leaves the endpoint running for inspection.
#   fm-deck-chat.sh stop [--home H]
#       Write the "stopped on purpose" marker state/primary-chat/stopped, then
#       SIGTERM the live registered host: deck quits and the host exits cleanly.
#       The service keeper never restarts past the marker; a captain-started
#       host (run here, or --stream outside the keeper) removes it. Refuses
#       to signal when bin/fm_primary_chat.py's host_alive identity check fails
#       (the marker still stands).
#   fm-deck-chat.sh attach [--home H]
#       `bin/fm-stream.sh attach --interactive` to the live primary's endpoint,
#       and when that endpoint closes (the host exited), wait for the next one
#       (the keeper's restart) and attach again. Returns when the client
#       detaches (Ctrl-]) or fails while its endpoint is still the live one.
#   fm-deck-chat.sh open [--home H]
#       What a bare `deck chat` runs in this home or any directory under it
#       (deck's project launcher, .agents/deck.chat.json). With no live
#       primary it starts one first - through the running keeper when the
#       service is installed (withdrawing a stopped marker), else with
#       --stream here - and then attaches as `attach` does. In a checkout
#       that has never hosted a primary (no state/primary-chat/session), such
#       as a worktree or clone of this repo, it runs a local `deck chat` in
#       $DECK_CHAT_CWD instead. Refuses (exit 1) when the live host runs in
#       a terminal of its own rather than a stream endpoint. `deck chat
#       --local` skips this launcher.
#   fm-deck-chat.sh install-service [--home H] [--model ROUTE]
#       macOS: generate ~/Library/LaunchAgents/dev.firstmate.primary.<hash>.plist
#       (<hash> = first 12 hex of sha256 of the canonical home) and bootstrap it
#       into gui/<uid>. Its program is `fm-deck-chat.sh service-run` from this
#       code root, with this shell's PATH and SHELL; RunAtLoad and KeepAlive
#       keep the keeper itself up, and AbandonProcessGroup keeps launchd from
#       touching anything the keeper started. An in-flight --stream launcher
#       finishes independently on keeper shutdown. A live host is adopted,
#       never duplicated. New starts always use --stream; configure this home's
#       hub and credentials per docs/stream-backend.md before installing.
#       The generated plist does not capture FM_STREAM_* overrides; use the
#       home's config files for persistent stream settings.
#       Re-running replaces the agent (e.g. to change --model).
#   fm-deck-chat.sh uninstall-service [--home H]
#       Boot the agent out and delete its plist; a running primary keeps running.
#   fm-deck-chat.sh service-run [--home H] [--model ROUTE]
#       The keeper the agent runs: `bin/fm_primary_chat.py service` (its
#       docstring owns the restart, backoff and alert rules; it logs to
#       state/primary-chat/service.log and publishes service.json).
#   fm-deck-chat.sh service-alert [--home H] --summary TEXT
#       Raise the keeper's primary-down alert through the away-mode wedge alarm
#       channels (config/wedge-alarm; docs/wedge-alarm.md), titled
#       "firstmate: primary DOWN".
# --home defaults to FM_HOME, else this checkout. --session defaults to the id
# persisted in state/primary-chat/session (created on first run), so every
# restart resumes the same deck session.
#
# ENVIRONMENT
#   FM_DECK_BIN            deck executable (default: deck on PATH)
#   FM_DECK_MCP_CONFIG     as for bin/fm-deck-worker.sh: non-empty = pass as-is,
#                          empty = no MCP; unset = <home>/config/deck-mcp.json
#                          when it exists
#   FM_DECK_CHAT_WATCH_BACKOFF, FM_DECK_CHAT_WATCH_BACKOFF_MAX
#                          watcher restart backoff seconds (default 2, max 60)
#   FM_DECK_CHAT_SERVICE   1 marks a start made by the keeper, which leaves the
#                          stopped marker alone
#   FM_DECK_CHAT_SERVICE_* keeper cadence, backoff and alert window
#                          (bin/fm_primary_chat.py service)
#   FM_LAUNCHCTL, FM_LAUNCH_AGENTS_DIR
#                          launchctl and LaunchAgents directory (tests); with
#                          FM_LAUNCHCTL set the service commands run off macOS
#   PROXAI_*               deck's endpoint settings; ~/.config/proxai/client.key
#                          is used when no key is set, as for deck workers
#
# Exit: deck chat's own exit code once it ran; 1 refused (lock held by another
# session, a primary already running, task named primary exists, session start
# failed, no live host to stop or stop failed, launchctl failed); 2 usage or
# missing prerequisite (including the service commands off macOS); 3
# gate-context refusal (bin/fm-gate-refuse-lib.sh).
set -u

SCRIPT_DIR=$(CDPATH='' cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
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
  stop|attach|open|install-service|uninstall-service|service-run|service-alert) MODE=$1; shift ;;
esac
HOME_DIR=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
MODEL='' SESSION='' ENDPOINT='' STREAM=0 SUMMARY=''
while [ $# -gt 0 ]; do
  case "$1" in
    --home) HOME_DIR=${2-}; shift 2 || usage ;;
    --model) MODEL=${2-}; shift 2 || usage ;;
    --session) SESSION=${2-}; shift 2 || usage ;;
    --endpoint) ENDPOINT=${2-}; shift 2 || usage ;;
    --summary) SUMMARY=${2-}; shift 2 || usage ;;
    --stream) STREAM=1; shift ;;
    -h|--help) usage ;;
    *) printf 'fm-deck-chat: unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || die "home not found: $HOME_DIR" 2
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
export FM_HOME=$HOME_DIR
STATE="$FM_HOME/state"
command -v python3 >/dev/null 2>&1 || die 'python3 is required' 2

STOPPED="$STATE/primary-chat/stopped"

# A start the captain made (not the keeper's) withdraws an earlier stop.
clear_stopped() {
  [ "${FM_DECK_CHAT_SERVICE:-}" = 1 ] || rm -f "$STOPPED"
}

# The live primary's endpoint for this home, or nothing.
live_endpoint() {
  python3 "$PRIMARY_CHAT" steer status --home "$FM_HOME" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("endpoint") or "" if d.get("present") else "")' 2>/dev/null
}

service_label() {
  printf 'dev.firstmate.primary.%s' "$(printf '%s' "$FM_HOME" \
    | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')"
}

service_prereqs() {
  LAUNCHCTL=${FM_LAUNCHCTL:-}
  if [ -z "$LAUNCHCTL" ]; then
    [ "$(uname)" = Darwin ] || die 'install-service manages a launchd agent and runs only on macOS' 2
    LAUNCHCTL=$(command -v launchctl 2>/dev/null) || die 'launchctl not found' 2
  fi
  AGENTS_DIR=${FM_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
  LABEL=$(service_label) || die 'could not derive the service label' 2
  PLIST="$AGENTS_DIR/$LABEL.plist"
  DOMAIN="gui/$(id -u)"
}

if [ "$MODE" = install-service ]; then
  service_prereqs
  BASH_BIN=$(command -v bash) || die 'bash not found on PATH' 2
  mkdir -p "$AGENTS_DIR" || die "cannot create $AGENTS_DIR" 2
  mkdir -p "$STATE" || die "cannot create $STATE" 2
  [ -d "$STATE/primary-chat" ] || mkdir -m 700 "$STATE/primary-chat" || die "cannot create $STATE/primary-chat" 2
  python3 - "$PLIST" "$LABEL" "$FM_HOME" "$BASH_BIN" "$SCRIPT_DIR/fm-deck-chat.sh" "$MODEL" <<'PY' \
    || die "could not write $PLIST" 2
import os, plistlib, sys, tempfile
plist, label, home, bash, script, model = sys.argv[1:7]
args = [bash, script, 'service-run', '--home', home] + (['--model', model] if model else [])
env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': os.environ.get('HOME', '')}
for name in ('SHELL', 'LANG', 'LC_ALL', 'TMPDIR'):
    if os.environ.get(name):
        env[name] = os.environ[name]
log = os.path.join(home, 'state', 'primary-chat', 'service.out.log')
body = plistlib.dumps({
    'Label': label, 'ProgramArguments': args, 'EnvironmentVariables': env,
    'WorkingDirectory': home, 'RunAtLoad': True, 'KeepAlive': True, 'ThrottleInterval': 10,
    'AbandonProcessGroup': True, 'StandardOutPath': log, 'StandardErrorPath': log})
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(plist) + '.', dir=os.path.dirname(plist))
with os.fdopen(fd, 'wb') as handle:
    handle.write(body)
os.chmod(tmp, 0o644)
os.replace(tmp, plist)
PY
  # Replacing a loaded agent stops only its keeper (AbandonProcessGroup).
  "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  ok=0
  # A replaced keeper can take a few seconds to exit.
  for _ in $(seq 1 60); do
    if "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" 2>"$STATE/primary-chat/.bootstrap.err"; then ok=1; break; fi
    sleep 0.5
  done
  [ "$ok" = 1 ] || die "launchctl bootstrap $DOMAIN $PLIST failed: $(cat "$STATE/primary-chat/.bootstrap.err" 2>/dev/null)"
  rm -f "$STATE/primary-chat/.bootstrap.err"
  "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1 || die "launchd does not list $DOMAIN/$LABEL after bootstrap"
  printf 'service: %s/%s installed from %s\n' "$DOMAIN" "$LABEL" "$PLIST"
  if pid=$(python3 "$PRIMARY_CHAT" record pid --home "$FM_HOME" 2>/dev/null); then
    ep=$(live_endpoint) || ep=''
    printf 'primary: already running (host pid %s%s); the keeper adopts it\n' "$pid" "${ep:+, endpoint $ep}"
  elif [ -e "$STOPPED" ]; then
    printf 'primary: stopped on purpose; start it with bin/fm-deck-chat.sh --stream and the keeper takes over\n'
  else
    printf 'primary: not running; the keeper starts it now\n'
  fi
  printf 'status: launchctl print %s/%s, %s/primary-chat/service.json\n' "$DOMAIN" "$LABEL" "$STATE"
  exit 0
fi

if [ "$MODE" = uninstall-service ]; then
  service_prereqs
  "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
  rm -f "$PLIST"
  # launchd lists the job until the keeper has exited.
  gone=0
  for _ in $(seq 1 60); do
    if ! "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1; then gone=1; break; fi
    sleep 0.5
  done
  [ "$gone" = 1 ] || die "launchd still lists $DOMAIN/$LABEL"
  printf 'service: %s/%s removed; a running primary keeps running\n' "$DOMAIN" "$LABEL"
  exit 0
fi

if [ "$MODE" = service-run ]; then
  keep=(service --home "$FM_HOME" --deck-chat "$SCRIPT_DIR/fm-deck-chat.sh")
  [ -z "$MODEL" ] || keep+=(--model "$MODEL")
  exec python3 "$PRIMARY_CHAT" "${keep[@]}"
fi

if [ "$MODE" = service-alert ]; then
  [ -n "$SUMMARY" ] || usage
  # Reuse the away-mode wedge alarm's channels, seam and bounds. Sourcing the
  # daemon defaults FM_WEDGE_ALARM_EXEC to "discard" (its test guard), so the
  # caller's own setting - unset in production - is restored afterwards.
  (
    exec_was_set=${FM_WEDGE_ALARM_EXEC+x} exec_was=${FM_WEDGE_ALARM_EXEC-}
    # The daemon is a canonical lint root of its own; keep this an analysis
    # boundary, as bin/fm-external-wait.sh does for its lazy lock helpers.
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/fm-supervise-daemon.sh"
    if [ -n "$exec_was_set" ]; then FM_WEDGE_ALARM_EXEC=$exec_was; else unset FM_WEDGE_ALARM_EXEC; fi
    LOG="$STATE/primary-chat/service.log"
    # The daemon's banner title names away-mode escalations; this alert is not one.
    # shellcheck disable=SC2329 # Called through wedge_alarm_notify.
    wedge_alarm_via_osascript() {
      local summary=$1 rc
      wedge_alarm_os_notifier_override osascript "$summary"
      rc=$?
      case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
      command -v osascript >/dev/null 2>&1 || { log "primary alert: osascript not found"; return 1; }
      wedge_alarm_run_bounded osascript osascript -e 'on run argv' \
        -e 'display notification (item 1 of argv) with title "firstmate: primary DOWN" sound name "Basso"' \
        -e 'end run' "$summary" >/dev/null 2>&1 && return 0
      log "primary alert: osascript notification failed"
      return 1
    }
    wedge_alarm_notify "$SUMMARY" "$STATE/primary-chat/service-down"
  )
  exit $?
fi

if [ "$MODE" = open ]; then
  if [ -z "$(live_endpoint)" ]; then
    if pid=$(python3 "$PRIMARY_CHAT" record pid --home "$FM_HOME" 2>/dev/null); then
      die "the live primary (host pid $pid) runs in its own terminal, not a stream endpoint; use that terminal"
    fi
    if [ ! -e "$STATE/primary-chat/session" ]; then
      cd "${DECK_CHAT_CWD:-$PWD}" || exit 2
      DECK=${FM_DECK_BIN:-deck}
      DECK_NO_LAUNCHER=1 exec "$DECK" chat
    fi
    # A held service.lock is the keeper (bin/fm_primary_chat.py service).
    if [ -e "$STATE/primary-chat/service.lock" ] && ! python3 -c '
import fcntl, sys
fcntl.flock(open(sys.argv[1], "a"), fcntl.LOCK_EX | fcntl.LOCK_NB)' "$STATE/primary-chat/service.lock" 2>/dev/null; then
      if [ -e "$STOPPED" ]; then
        rm -f "$STOPPED"
        printf 'fm-deck-chat: the primary was stopped on purpose; the keeper starts it again\n' >&2
      fi
    else
      printf 'fm-deck-chat: no live primary and no keeper; starting one in a stream endpoint\n' >&2
      "$SCRIPT_DIR/fm-deck-chat.sh" --stream --home "$FM_HOME" >/dev/null || exit $?
    fi
  fi
  MODE=attach
fi

if [ "$MODE" = attach ]; then
  waiting=''
  while :; do
    ep=$(live_endpoint) || ep=''
    if [ -z "$ep" ]; then
      if [ -z "$waiting" ]; then
        waiting=1
        if [ -e "$STOPPED" ]; then
          printf 'fm-deck-chat: the primary was stopped on purpose; waiting for a start (Ctrl-C quits)\n' >&2
        else
          printf 'fm-deck-chat: no live primary; waiting for one (Ctrl-C quits)\n' >&2
        fi
      fi
      sleep 1
      continue
    fi
    waiting=''
    rc=0
    "$SCRIPT_DIR/fm-stream.sh" attach --interactive "$ep" || rc=$?
    # Still the live primary's endpoint: the client detached or failed on its own.
    [ "$(live_endpoint)" != "$ep" ] || exit "$rc"
    printf '\nfm-deck-chat: primary endpoint %s closed; attaching to the next one (Ctrl-C quits)\n' "$ep" >&2
  done
fi

if [ "$MODE" = stop ]; then
  # The marker comes first, so a keeper never restarts what this stops.
  if ! { mkdir -p "$STATE" \
      && { [ -d "$STATE/primary-chat" ] || mkdir -m 700 "$STATE/primary-chat"; } \
      && printf '{"stopped_at": %s, "by": "fm-deck-chat.sh stop"}\n' "$(date +%s)" > "$STOPPED"; }; then
    die "could not write $STOPPED"
  fi
  # Only a live host for exactly this home is signalled, never a recycled pid.
  pid=$(python3 "$PRIMARY_CHAT" record pid --home "$FM_HOME") \
    || die 'no live deck-chat primary is registered for this home'
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
  if pid=$(python3 "$PRIMARY_CHAT" record pid --home "$FM_HOME" 2>/dev/null); then
    ep=$(live_endpoint) || ep=''
    die "a primary is already running for this home (host pid $pid${ep:+, endpoint $ep}); not starting a second one"
  fi
  # The endpoint is created by the stream backend's own agent launcher, so a
  # launcher change there (Python or Rust agent) applies to the primary too.
  # shellcheck source=bin/fm-backend.sh
  . "$SCRIPT_DIR/fm-backend.sh"
  fm_backend_source stream || exit 2
  fm_backend_stream_tool_check || exit 2
  fm_backend_stream_container_ensure >/dev/null || exit 1
  # The hub keeps one live endpoint per label and machine, and the last host's
  # endpoint closes only when its agent next polls. No host is alive here, so
  # give that endpoint a moment to close, then close it.
  previous=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("endpoint") or "")' \
    "$STATE/primary-chat.json" 2>/dev/null) || previous=''
  if [ -n "$previous" ] && fm_backend_stream_parse_target "$previous" >/dev/null 2>&1; then
    for _ in $(seq 1 100); do
      api_rc=0
      task=$(fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT" 2>/dev/null) || api_rc=$?
      [ "$api_rc" = 0 ] || break
      [ -z "$(printf '%s' "$task" | jq -r '.task.closed_at // empty' 2>/dev/null)" ] || break
      sleep 0.1
    done
    if [ "$api_rc" = 0 ] && [ -z "$(printf '%s' "$task" | jq -r '.task.closed_at // empty' 2>/dev/null)" ]; then
      fm_backend_stream_kill "$previous" "" primary-chat >/dev/null 2>&1 || true
    fi
  fi
  clear_stopped
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
  deadline=$((SECONDS + 150)) checked=$SECONDS
  while [ "$SECONDS" -lt "$deadline" ]; do
    if status=$("$SCRIPT_DIR/fm-primary-steer.sh" status --home "$FM_HOME" 2>/dev/null); then
      registered=$(printf '%s' "$status" | jq -r '.endpoint // empty')
      if [ "$registered" = "$target" ]; then
        printf 'primary-chat: running in stream endpoint %s\n' "$target"
        printf 'attach: bin/fm-deck-chat.sh attach (follows restarts), or bin/fm-stream.sh attach --interactive %s (Ctrl-] detaches)\n' "$target"
        printf 'input: bin/fm-send.sh primary <text>\n'
        exit 0
      fi
      if [ -n "$registered" ]; then
        fm_backend_stream_kill "$target" >/dev/null 2>&1 || true
        die "another primary registered first, from endpoint $registered"
      fi
    fi
    # A host that exits before registering (refused, or session start failed)
    # closes its endpoint: report that now instead of waiting out the window.
    if [ $((SECONDS - checked)) -ge 2 ] && checked=$SECONDS \
        && fm_backend_stream_parse_target "$target" >/dev/null 2>&1 \
        && [ "$(fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT" 2>/dev/null \
          | jq -r '.task.closed_by // empty' 2>/dev/null)" = agent ]; then
      # A closed endpoint's screen can take the full HTTP timeout to answer.
      FM_STREAM_HTTP_TIMEOUT=5 fm_backend_stream_capture "$target" 40 2>/dev/null | tail -n 20 >&2 || true
      die "the host exited before registering from stream endpoint $target"
    fi
    sleep 0.1
  done
  fm_backend_stream_capture "$target" 40 2>/dev/null | tail -n 20 >&2 || true
  die "the host did not register from stream endpoint $target within 150s; the endpoint is left running for inspection"
fi

# Run mode. Re-exec once under the harness name the session lock recognises.
if [ "${FM_DECK_CHAT_HOST:-}" != "$$" ]; then
  again=()
  [ -z "$MODEL" ] || again+=(--model "$MODEL")
  [ -z "$SESSION" ] || again+=(--session "$SESSION")
  [ -z "$ENDPOINT" ] || again+=(--endpoint "$ENDPOINT")
  again+=(--home "$FM_HOME")
  FM_DECK_CHAT_HOST=$$ exec -a fm-deck-chat bash "$SCRIPT_DIR/fm-deck-chat.sh" "${again[@]}"
fi
unset FM_DECK_CHAT_HOST
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
# The busy-state id `primary` belongs to the primary; a task with that id
# would share its records, so the host refuses to start next to one.
[ ! -e "$STATE/primary.meta" ] || die 'a task named primary exists in this home (state/primary.meta); not starting'
"$SCRIPT_DIR/fm-lock.sh" >&2 || die 'the home session lock is held by another session; not starting'
# Run here by the captain rather than inside an endpoint --stream prepared.
[ -n "$ENDPOINT" ] || clear_stopped
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
