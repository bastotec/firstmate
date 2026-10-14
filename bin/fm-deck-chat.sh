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
#       --stream here - and then attaches as `attach` does. A checkout that
#       is not a firstmate home (no state/ directory: a worktree of this repo,
#       or a clone that has never run) must never grow a primary, so there it
#       runs a local `deck chat` in $DECK_CHAT_CWD instead. Refuses (exit 1)
#       when the live host was started in a terminal of its own (plain
#       `fm-deck-chat.sh`): that terminal is its only screen. `deck chat
#       --local` skips this launcher.
#   fm-deck-chat.sh model [ROUTE] [--home H]
#       Switch the primary to a gateway route after checking syntax and the
#       home's model policy (FM_CONFIG_OVERRIDE, else <home>/config).
#       A policy refusal exits 1 before saving or publishing a choice, on either
#       the in-place or keeper path.
#       When the live host's deck takes `deck-control: set_model` (recorded at
#       start), the route goes to it as a steering control: same process, same session,
#       applied at once while idle or at the turn's next safe point (deck
#       checks it against the gateway and the model policy and reports
#       model_switched or model_switch_refused in its events); prints
#       "switched to ROUTE in place" on publication, not confirmed application.
#       This path needs no keeper. Otherwise, for the serviced primary:
#       once the primary is idle the keeper ends the host and starts it again
#       on the same session, resuming the conversation as any keeper restart
#       does; it never goes through `stop`. Prints whether the switch is
#       requested now or after the turn under way, not a completion receipt.
#       The fallback exits 1 when no keeper serves this home (verified by its
#       singleton lock); restart an unsupported terminal-run host with --model
#       by hand instead. Exit 2 for a
#       malformed route. Without ROUTE, prints the stored choice, else the live
#       keeper's --model, else "default"; this is the configured choice, not
#       necessarily the live host's model while a switch is pending.
#       bin/fm_primary_chat.py owns the model and switch records.
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
#       Re-running replaces the agent; --model is a fallback for keeper starts,
#       overridden by the stored choice from `model ROUTE`.
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
# --role supervisor (every mode, before --home) runs the split home's supervisor
#   instead of the captain's primary: bin/fm_primary_chat.py's header owns split
#   mode (config/primary-split), the role names and what each role holds. A
#   supervisor host refuses to start outside split mode, and its keeper
#   (install-service --role supervisor, label dev.firstmate.supervisor.<hash>)
#   waits for the switch. In split mode the captain role takes no session lock,
#   runs no session start and no watcher, reads no project context, and starts
#   each run with .agents/skills/captain-thread/SKILL.md as its first message.
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
#   DECK_MODEL_POLICY      Deck's policy path; non-empty is passed through,
#                          else use model-policy.json in FM_CONFIG_OVERRIDE
#                          or <home>/config when it exists. This does not
#                          replace the home-policy check by `model ROUTE`.
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

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
OPERATIONAL_PREFIX=$FM_OPERATIONAL_PREFIX

MODE=run
case "${1:-}" in
  stop|attach|open|model|install-service|uninstall-service|service-run|service-alert) MODE=$1; shift ;;
esac
HOME_DIR=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
MODEL='' SESSION='' ENDPOINT='' STREAM=0 SUMMARY='' ROUTE='' ROLE=captain
while [ $# -gt 0 ]; do
  case "$1" in
    --home) HOME_DIR=${2-}; shift 2 || usage ;;
    --model) MODEL=${2-}; shift 2 || usage ;;
    --session) SESSION=${2-}; shift 2 || usage ;;
    --endpoint) ENDPOINT=${2-}; shift 2 || usage ;;
    --summary) SUMMARY=${2-}; shift 2 || usage ;;
    --stream) STREAM=1; shift ;;
    --role) ROLE=${2-}; shift 2 || usage ;;
    -h|--help) usage ;;
    *) if [ "$MODE" = model ] && [ -z "$ROUTE" ]; then ROUTE=$1; shift; continue; fi
       printf 'fm-deck-chat: unknown argument: %s\n' "$1" >&2; usage ;;
  esac
done
[ -n "$HOME_DIR" ] && [ -d "$HOME_DIR" ] || die "home not found: $HOME_DIR" 2
HOME_DIR=$(cd "$HOME_DIR" && pwd -P)
export FM_HOME=$HOME_DIR
STATE="$FM_HOME/state"
# Role names mirror bin/fm_primary_chat.py ROLES: the captain role keeps the
# primary's names; the supervisor role exists only in split mode
# (config/primary-split), where it owns the session lock and every wake.
case "$ROLE" in
  captain) ROOT_NAME=primary-chat RECORD_NAME=primary-chat.json BUSY_NAME=primary SERVICE_KIND=primary ROLE_ARGS=() ;;
  supervisor) ROOT_NAME=supervisor-chat RECORD_NAME=supervisor-chat.json BUSY_NAME=supervisor SERVICE_KIND=supervisor ROLE_ARGS=(--role supervisor) ;;
  *) printf 'fm-deck-chat: unknown role: %s\n' "$ROLE" >&2; usage ;;
esac
export FM_CHAT_ROLE=$ROLE
SPLIT=0
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/primary-split" ] || SPLIT=1
[ "$MODE" = open ] && [ ! -d "$STATE" ] || fm_refuse_if_gate_agent
command -v python3 >/dev/null 2>&1 || die 'python3 is required' 2

STOPPED="$STATE/$ROOT_NAME/stopped"

if [ "$MODE" = model ]; then
  if [ -n "$ROUTE" ]; then exec python3 "$PRIMARY_CHAT" model --home "$FM_HOME" "$ROUTE"; fi
  exec python3 "$PRIMARY_CHAT" model --home "$FM_HOME"
fi

# A start the captain made (not the keeper's) withdraws an earlier stop.
clear_stopped() {
  if [ "${FM_DECK_CHAT_SERVICE:-}" != 1 ]; then
    local start
    mkdir -p "$STATE" || die "cannot create $STATE" 2
    [ -d "$STATE/$ROOT_NAME" ] || mkdir -m 700 "$STATE/$ROOT_NAME" || die "cannot create $STATE/$ROOT_NAME" 2
    start=$(mktemp "$STATE/$ROOT_NAME/.captain-start.XXXXXX") || die 'cannot prepare captain start' 2
    if ! { date +%s > "$start" && mv -f "$start" "$STATE/$ROOT_NAME/captain-start"; }; then
      die 'cannot record captain start' 2
    fi
    rm -f "$STOPPED"
  fi
}

# The live primary's endpoint for this home, or nothing.
live_endpoint() {
  python3 "$PRIMARY_CHAT" steer status --home "$FM_HOME" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("endpoint") or "" if d.get("present") else "")' 2>/dev/null
}

service_label() {
  printf 'dev.firstmate.%s.%s' "$SERVICE_KIND" "$(printf '%s' "$FM_HOME" \
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
  [ -d "$STATE/$ROOT_NAME" ] || mkdir -m 700 "$STATE/$ROOT_NAME" || die "cannot create $STATE/$ROOT_NAME" 2
  python3 - "$PLIST" "$LABEL" "$FM_HOME" "$BASH_BIN" "$SCRIPT_DIR/fm-deck-chat.sh" "$MODEL" "$ROLE" "$ROOT_NAME" <<'PY' \
    || die "could not write $PLIST" 2
import os, plistlib, sys, tempfile
plist, label, home, bash, script, model, role, root = sys.argv[1:9]
args = ([bash, script, 'service-run'] + (['--role', role] if role != 'captain' else [])
        + ['--home', home] + (['--model', model] if model else []))
env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': os.environ.get('HOME', '')}
for name in ('SHELL', 'LANG', 'LC_ALL', 'TMPDIR'):
    if os.environ.get(name):
        env[name] = os.environ[name]
log = os.path.join(home, 'state', root, 'service.out.log')
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
    if "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" 2>"$STATE/$ROOT_NAME/.bootstrap.err"; then ok=1; break; fi
    sleep 0.5
  done
  [ "$ok" = 1 ] || die "launchctl bootstrap $DOMAIN $PLIST failed: $(cat "$STATE/$ROOT_NAME/.bootstrap.err" 2>/dev/null)"
  rm -f "$STATE/$ROOT_NAME/.bootstrap.err"
  "$LAUNCHCTL" print "$DOMAIN/$LABEL" >/dev/null 2>&1 || die "launchd does not list $DOMAIN/$LABEL after bootstrap"
  printf 'service: %s/%s installed from %s\n' "$DOMAIN" "$LABEL" "$PLIST"
  if [ "$ROLE" = supervisor ] && [ "$SPLIT" != 1 ]; then
    printf 'supervisor: split mode is off (no config/primary-split); the keeper waits for it\n'
  elif pid=$(python3 "$PRIMARY_CHAT" record pid --home "$FM_HOME" 2>/dev/null); then
    ep=$(live_endpoint) || ep=''
    printf 'primary: already running (host pid %s%s); the keeper adopts it\n' "$pid" "${ep:+, endpoint $ep}"
  elif [ -e "$STOPPED" ]; then
    printf 'primary: stopped on purpose; start it with bin/fm-deck-chat.sh --stream and the keeper takes over\n'
  else
    printf 'primary: not running; the keeper starts it now\n'
  fi
  printf 'status: launchctl print %s/%s, %s/%s/service.json\n' "$DOMAIN" "$LABEL" "$STATE" "$ROOT_NAME"
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
  keep=(--role "$ROLE" service --home "$FM_HOME" --deck-chat "$SCRIPT_DIR/fm-deck-chat.sh")
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
    LOG="$STATE/$ROOT_NAME/service.log"
    # The daemon's banner title names away-mode escalations; this alert is not one.
    # shellcheck disable=SC2329 # Called through wedge_alarm_notify.
    wedge_alarm_via_osascript() {
      local summary=$1 rc
      wedge_alarm_os_notifier_override osascript "$summary"
      rc=$?
      case "$rc" in 0) return 0 ;; 1) return 1 ;; esac
      command -v osascript >/dev/null 2>&1 || { log "primary alert: osascript not found"; return 1; }
      wedge_alarm_run_bounded osascript osascript -e 'on run argv' \
        -e 'display notification (item 1 of argv) with title "firstmate: '"$SERVICE_KIND"' DOWN" sound name "Basso"' \
        -e 'end run' "$summary" >/dev/null 2>&1 && return 0
      log "primary alert: osascript notification failed"
      return 1
    }
    wedge_alarm_notify "$SUMMARY" "$STATE/$ROOT_NAME/service-down"
  )
  exit $?
fi

if [ "$MODE" = open ]; then
  if [ ! -d "$STATE" ]; then
    cd "${DECK_CHAT_CWD:-$PWD}" || exit 2
    DECK=${FM_DECK_BIN:-deck}
    DECK_NO_LAUNCHER=1 exec "$DECK" chat
  fi
  primary=$(python3 "$PRIMARY_CHAT" steer status --home "$FM_HOME" 2>/dev/null \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); print("absent" if not d.get("present") else "stream" if d.get("endpoint") else "terminal")') \
    || die 'could not read primary status'
  if [ "$primary" = terminal ]; then
    die 'the live primary runs in its own terminal, not a stream endpoint; use that terminal'
  fi
  if [ "$primary" = absent ]; then
    # A held service.lock is the keeper (bin/fm_primary_chat.py service).
    if [ -e "$STATE/$ROOT_NAME/service.lock" ] && ! python3 -c '
import fcntl, sys
fcntl.flock(open(sys.argv[1], "a"), fcntl.LOCK_EX | fcntl.LOCK_NB)' "$STATE/$ROOT_NAME/service.lock" 2>/dev/null; then
      if [ -e "$STOPPED" ]; then
        rm -f "$STOPPED"
        printf 'fm-deck-chat: the primary was stopped on purpose; the keeper starts it again\n' >&2
      fi
    else
      printf 'fm-deck-chat: no live primary and no keeper; starting one in a stream endpoint\n' >&2
      "$SCRIPT_DIR/fm-deck-chat.sh" --stream ${ROLE_ARGS[@]+"${ROLE_ARGS[@]}"} --home "$FM_HOME" >/dev/null || exit $?
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
      && { [ -d "$STATE/$ROOT_NAME" ] || mkdir -m 700 "$STATE/$ROOT_NAME"; } \
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
    "$STATE/$RECORD_NAME" 2>/dev/null) || previous=''
  if [ -n "$previous" ] && fm_backend_stream_parse_target "$previous" >/dev/null 2>&1; then
    for _ in $(seq 1 100); do
      api_rc=0
      task=$(fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT" 2>/dev/null) || api_rc=$?
      [ "$api_rc" = 0 ] || break
      [ -z "$(printf '%s' "$task" | jq -r '.task.closed_at // empty' 2>/dev/null)" ] || break
      sleep 0.1
    done
    if [ "$api_rc" = 0 ] && [ -z "$(printf '%s' "$task" | jq -r '.task.closed_at // empty' 2>/dev/null)" ]; then
      fm_backend_stream_kill "$previous" "" "$ROOT_NAME" >/dev/null 2>&1 || true
    fi
  fi
  clear_stopped
  created=$(fm_backend_stream_create_task "$ROOT_NAME" "$FM_HOME" "" "") || exit 1
  target="${created% *}:${created#* }"
  launch="exec $(q "$SCRIPT_DIR/fm-deck-chat.sh")${ROLE_ARGS[*]:+ ${ROLE_ARGS[*]}} --home $(q "$FM_HOME") --endpoint $(q "$target")"
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
        printf '%s: running in stream endpoint %s\n' "$ROOT_NAME" "$target"
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
  again+=(${ROLE_ARGS[@]+"${ROLE_ARGS[@]}"} --home "$FM_HOME")
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
if [ -z "${DECK_MODEL_POLICY:-}" ]; then
  MODEL_POLICY="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/model-policy.json"
  [ ! -f "$MODEL_POLICY" ] || export DECK_MODEL_POLICY="$MODEL_POLICY"
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
  [ -z "$GEN" ] || "$BUSY_EVENT" apply "$STATE" "$BUSY_NAME" idle --gen "$GEN" --source deck-wrapper \
    --event session-end >/dev/null 2>&1 || true
  [ "$RECORDED" != 1 ] || python3 "$PRIMARY_CHAT" record stop --home "$FM_HOME" --host-pid $$ || true
  # Release only a lock this host holds; a refused start never touches it.
  [ "$(cat "$STATE/.lock" 2>/dev/null)" != "$$" ] || rm -f "$STATE/.lock"
  [ -z "$WORK" ] || rm -rf -- "$WORK"
}
trap cleanup EXIT
trap 'exit 1' HUP TERM

# Split mode (config/primary-split) gives the session lock, session start and
# watcher to the supervisor host; the captain thread holds none of them.
LOCK_BOUND=1
[ "$ROLE" != captain ] || [ "$SPLIT" != 1 ] || LOCK_BOUND=0
[ "$ROLE" != supervisor ] || [ "$SPLIT" = 1 ] \
  || die 'the supervisor runs only in split mode (config/primary-split); not starting'
# The lock comes first: it refuses a second primary of any harness, including
# a second host, before this one changes anything.
# The busy-state id belongs to this host; a task with that id would share its
# records, so the host refuses to start next to one.
[ ! -e "$STATE/$BUSY_NAME.meta" ] || die "a task named $BUSY_NAME exists in this home (state/$BUSY_NAME.meta); not starting"
if [ "$LOCK_BOUND" = 0 ]; then
  # Without the session lock, one captain-thread host per home is enforced by
  # an flock this host keeps on fd 9 for its whole life (the lock belongs to
  # the open file, so it outlives the perl that takes it).
  { [ -d "$STATE/$ROOT_NAME" ] || mkdir -m 700 "$STATE/$ROOT_NAME"; } || die "cannot create $STATE/$ROOT_NAME" 2
  exec 9>>"$STATE/$ROOT_NAME/host.lock" || die "cannot open $STATE/$ROOT_NAME/host.lock" 2
  perl -MFcntl=:flock -e 'open(my $f, "<&=", 9) or exit 2; flock($f, LOCK_EX | LOCK_NB) or exit 1' \
    || die 'another captain-thread host is running for this home; not starting'
fi
if [ "$LOCK_BOUND" = 1 ]; then
  "$SCRIPT_DIR/fm-lock.sh" >&2 || die 'the home session lock is held by another session; not starting'
  if ! FM_STATE_OVERRIDE="$STATE" bash -c '
      # shellcheck disable=SC1090,SC1091
      . "$1"
      fm_recovery_marker_publish_fresh "$STATE/.watcher-down"
    ' _ "$SCRIPT_DIR/fm-wake-lib.sh"; then
    die 'could not publish a fresh recovery generation'
  fi
fi
# Run here by the captain rather than inside an endpoint --stream prepared.
[ -n "$ENDPOINT" ] || clear_stopped
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-deck-chat.XXXXXX") || exit 1
prepared=$(python3 "$PRIMARY_CHAT" prepare --home "$FM_HOME" --session "$SESSION") || die "could not prepare the $ROOT_NAME state" 2
SESSION=$(printf '%s\n' "$prepared" | sed -n 's/^session=//p')
STEER_DIR=$(printf '%s\n' "$prepared" | sed -n 's/^steer_dir=//p')
EVENTS=$(printf '%s\n' "$prepared" | sed -n 's/^events_file=//p')
EVENTS_OFFSET=$(printf '%s\n' "$prepared" | sed -n 's/^events_offset=//p')
LOG="$STATE/$ROOT_NAME/host.log"
if [ "$LOCK_BOUND" = 1 ]; then
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
fi
GEN=$("$BUSY_EVENT" arm "$STATE" "$BUSY_NAME" --state idle --source deck-wrapper --event host-start) \
  || die "could not arm the $BUSY_NAME busy-state record"

if [ "$LOCK_BOUND" = 0 ]; then
  # Input waiting from before this start (an unsplit primary's wakes, say) must
  # not reach the captain thread: known operational input (watcher wakes, with
  # or without a deck-effort header, operational records, peer messages, model
  # controls) moves to split-archived/ beside the inbox, because the durable
  # wake queue, not this preview, owns that work. Everything else is the
  # captain's and stays where it is, in its order.
  ARCHIVED="$STEER_DIR/../split-archived"
  mkdir -p "$ARCHIVED" || die 'cannot prepare the inbox hand-over'
  for msg in $(cd "$STEER_DIR" && find . -maxdepth 1 -name '[1-9]*.msg' | sed 's|^\./||' | grep -E '^[1-9][0-9]*\.msg$' | sort -n); do
    head=$(head -c 160 "$STEER_DIR/$msg")
    case "$head" in 'deck-effort: '*) head=${head#*$'\n'} ;; esac
    case "$head" in
      'The home watcher has an actionable wake'*|"$OPERATIONAL_PREFIX"*|'[fm-from-mate:'*|'deck-control:'*)
        mv -f "$STEER_DIR/$msg" "$ARCHIVED/$msg" || die "cannot archive pending input $msg" ;;
    esac
  done
  # The captain thread's contract is its first message on every start, because
  # it runs without the home's project context (AGENTS.md is the supervisor's).
  CONTRACT="$SCRIPT_DIR/../.agents/skills/captain-thread/SKILL.md"
  [ -r "$CONTRACT" ] || die "the captain thread contract is missing: $CONTRACT"
  {
    printf 'You are the captain thread of the primary firstmate, hosted by bin/fm-deck-chat.sh.\n'
    printf 'This home runs split: a separate supervisor session does all supervision. Your contract follows; it replaces any earlier role in this conversation.\n\n'
    awk 'seen >= 2 { print } /^---$/ { seen++ }' "$CONTRACT"
  } > "$WORK/first"
else
# The digest is the first new steer; older pending input is retained for the
# initial turn. deck's per-message limit is 64 KiB; a larger digest stays in
# a file the first message points at.
{
  if [ "$ROLE" = supervisor ]; then
    printf 'You are the supervisor of the primary firstmate, hosted by bin/fm-deck-chat.sh as a deck chat session.\n'
    printf 'This home runs split (config/primary-split): a separate captain thread talks to the captain, and nobody reads this chat; AGENTS.md section 9 says how you reach the captain.\n'
  else
    printf 'You are the primary firstmate, hosted by bin/fm-deck-chat.sh as a deck chat session.\n'
  fi
  printf 'The host already ran bin/fm-session-start.sh exactly once for this session; do not run it again.\n'
  printf 'The host owns the watcher: wakes and other supervisor input arrive as steering messages. Do not arm a watcher yourself.\n\n'
} > "$WORK/first"
if [ "$(wc -c < "$WORK/startup")" -le 60000 ]; then
  { printf 'Session start digest:\n'; cat "$WORK/startup"; } >> "$WORK/first"
else
  cp "$WORK/startup" "$STATE/$ROOT_NAME/startup-digest.txt"
  printf 'The session start digest is too large for one message. Read all of %s before anything else.\n' \
    "$STATE/$ROOT_NAME/startup-digest.txt" >> "$WORK/first"
fi
fi
record_args=(record write --home "$FM_HOME" --session "$SESSION" --host-pid $$
  --endpoint "$ENDPOINT" --model "$MODEL")
# The captain thread's contract is deck chat's own first prompt (below), so it
# comes before any input already waiting; every other host publishes its
# startup as the next steer.
[ "$LOCK_BOUND" = 0 ] || record_args+=(--startup-file "$WORK/first")
# A deck that takes `deck-control: set_model` lets `model ROUTE` switch in place.
"$DECK" chat --help 2>/dev/null | grep -q set_model && record_args+=(--set-model)
python3 "$PRIMARY_CHAT" "${record_args[@]}" || die "could not publish startup and write state/$RECORD_NAME"
RECORDED=1

sup_args=(supervise --home "$FM_HOME" --host-pid $$ --gen "$GEN" --events-offset "$EVENTS_OFFSET")
# Routine wakes think less when this deck takes per-turn effort (bin/fm-effort-policy.sh).
"$SCRIPT_DIR/fm-effort-policy.sh" supported "$DECK" && sup_args+=(--effort-headers)
python3 "$PRIMARY_CHAT" "${sup_args[@]}" </dev/null >>"$LOG" 2>&1 &
SUP_PID=$!

args=(chat --session "$SESSION" --steer-dir "$STEER_DIR" --events "$EVENTS")
if [ "$LOCK_BOUND" = 1 ]; then
  LOCK_HOOK="bash -c $(q ". $(q "$SCRIPT_DIR/fm-session-lock-lib.sh"); fm_session_lock_owned_by_self $(q "$STATE") || { echo 'Home session lock lost; report the failure and stop.' >&2; exit 2; }")"
  args+=(--hook "pre_complete=$LOCK_HOOK")
else
  # The captain thread reads no project context: AGENTS.md is the supervisor's job.
  args+=(--no-project-context)
fi
[ -z "$MCP_CONFIG" ] || args+=(--mcp-config "$MCP_CONFIG")
[ -z "$MODEL" ] || args+=(--model "$MODEL")
# deck stays in this terminal's foreground process group; explicit stdin keeps
# bash from pointing an asynchronous command at /dev/null.
trap ':' INT
trap '[ -z "$DECK_PID" ] || kill -TERM "$DECK_PID" 2>/dev/null' HUP TERM
# The machine's approval gate (bin/fm-approval.py) files the first mate's blocked calls here.
# Both roles are the first mate to the approval gate.
export FM_APPROVAL_HOME="$FM_HOME" FM_APPROVAL_AGENT=primary
# Its fm-send calls return once a steer is durable; the doorbell rings in the
# background (fm_task_inbox_ring_maybe_async in bin/fm-task-inbox-lib.sh).
export FM_SEND_RING_ASYNC=1
[ "$LOCK_BOUND" = 1 ] || args+=("$(cat "$WORK/first")")
"$DECK" "${args[@]}" <&0 &
DECK_PID=$!
rc=0
while :; do
  wait "$DECK_PID"; rc=$?
  kill -0 "$DECK_PID" 2>/dev/null || break
done
DECK_PID=''
exit "$rc"
