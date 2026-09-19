#!/usr/bin/env bash
# fm-stream.sh - operate the fleet's stream hub and subscribe to its endpoints.
#
# The hub (bin/fm-stream-hub.py) is ONE service for the whole fleet. Each task's
# pseudoterminal is owned by a thin agent (bin/fm-stream-agent.py) on the
# machine that runs it; bin/backends/stream.sh is the runtime backend that
# creates and drives those endpoints. docs/stream-backend.md owns setup,
# security, and limits.
#
# Usage:
#   fm-stream.sh hub start [--bind ADDR] [--port N] [--foreground]
#   fm-stream.sh hub stop
#   fm-stream.sh status
#   fm-stream.sh url
#   fm-stream.sh token [--ensure]
#   fm-stream.sh web
#   fm-stream.sh machines
#   fm-stream.sh tasks
#   fm-stream.sh order <leaf-worker-id> <execution-id> <text> [--no-submit]
#   fm-stream.sh order-status <order-id>
#   fm-stream.sh attach <endpoint-id|target> [--replay]
#   fm-stream.sh -h | --help
#
# Commands:
#   hub start Launch the hub in the background ON THIS HOST. Most homes never
#             run this: the fleet has one hub, and every other home points at
#             it with config/stream-hub. --foreground runs it in this terminal.
#   hub stop  Signal the recorded hub process and wait for the port to be
#             released. Endpoints survive it - their agents own the ptys - but
#             nothing can be watched or steered until the hub is back.
#   status    Print the recorded process, the reachable health line, or the
#             reason neither answers.
#   url       Print the hub base URL this home resolves.
#   token     Print this home's hub token - the credential this home presents
#             as a client. --ensure creates a fresh 0600 token when none
#             exists. A fleet that wants separate publishing and viewing
#             credentials writes class-scoped "<classes>:<token>" lines to
#             config/stream-hub-tokens instead, which is what `hub start`
#             serves when it is present.
#   web       Print the browser URL for the one central subscriber view, token
#             included as a fragment, which keeps it out of the navigation the
#             browser sends. The viewer's own event stream still carries it in
#             a URL.
#   machines  List the machines the hub has heard from, and how long each has
#             been silent.
#   tasks     List every endpoint the hub hosts, across every machine.
#   order     Send one order to a worker addressed by its leaf id
#             ("<machine>/<label>", as `tasks` and the Bridge feed both spell
#             it), bound to the execution it is aimed at. Both are required:
#             the leaf names the worker across relaunches, and the execution
#             keeps an order composed for one worker out of its replacement.
#             --no-submit types the text without the newline that runs it.
#             Exit 0 accepted, 1 refused, 4 delivery unconfirmed - and
#             unconfirmed is NOT a failure to retry blindly, because the order
#             may already have reached the worker.
#   order-status  Read one order back: what became of it, including an
#             unconfirmed one an agent acknowledged late.
#   attach    Stream one endpoint's live output to stdout until interrupted.
#             --replay starts from the oldest byte still in the ring buffer;
#             the default starts from now.
#
# Selection: FM_STREAM_HUB, then config/stream-hub, then a hub this home
# started itself, then http://127.0.0.1:7717.
# The token comes from FM_STREAM_TOKEN, then config/stream-token.
#
# An endpoint argument may be a bare hub endpoint id or a full
# "<hub-tag>:<endpoint-id>" target as recorded in a task's durable record.
set -eu

FM_STREAM_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$(cd "$(dirname "$FM_STREAM_SCRIPT")/.." && pwd)}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
BIN_DIR="$(cd "$(dirname "$FM_STREAM_SCRIPT")" && pwd)"
unset FM_STREAM_SCRIPT

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
HUB="$BIN_DIR/fm-stream-hub.py"
PID_FILE="$STATE/.stream-hub.pid"
READY_FILE="$STATE/.stream-hub.ready"
LOG_FILE="$STATE/.stream-hub.log"

# shellcheck source=bin/backends/stream.sh
. "$BIN_DIR/backends/stream.sh"

die() {
  printf 'fm-stream.sh: %s\n' "$*" >&2
  exit 1
}

usage() {
  sed -n '2,/^set -eu$/p' "$BIN_DIR/fm-stream.sh" | sed -e 's/^# \{0,1\}//' -e '/^set -eu$/d'
}

need_token() {
  fm_backend_stream_token >/dev/null || exit 1
}

# resolve_target: accept a bare endpoint id or a full recorded target, and
# return the full target this home's configured hub will accept.
resolve_target() {  # <endpoint-or-target>
  local raw=$1 tag
  case "$raw" in
    *:*) printf '%s' "$raw"; return 0 ;;
  esac
  tag=$(fm_backend_stream_hub_tag) || return 1
  printf '%s:%s' "$tag" "$raw"
}

cmd_hub_start() {
  local bind=127.0.0.1 port=7717 foreground=0
  while [ $# -gt 0 ]; do
    case "$1" in
      --bind) bind=${2:?--bind needs an address}; shift 2 ;;
      --port) port=${2:?--port needs a number}; shift 2 ;;
      --foreground) foreground=1; shift ;;
      *) die "unknown option for hub start: $1" ;;
    esac
  done
  fm_backend_stream_tool_check || exit 1
  mkdir -p "$STATE"
  # Two different credentials, deliberately kept apart.
  #
  # config/stream-hub-tokens is the HUB's own file: "<classes>:<token>" lines,
  # which is how a publishing credential is separated from a viewing one across
  # a real fleet.
  #
  # config/stream-token is what THIS home presents as a client. When no hub
  # token file exists, a single-machine trial hands that one token to the hub
  # through the environment, where it holds every class - otherwise a bare
  # token would grant subscribe only and this home's own agents could neither
  # publish to the hub it just started nor steer what they published.
  local hub_tokens="$CONFIG/stream-hub-tokens"
  local token_file="$CONFIG/stream-token"
  if [ -f "$PID_FILE" ]; then
    local existing
    existing=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$existing" ] && kill -0 "$existing" 2>/dev/null; then
      die "a hub is already running for this home (pid $existing); stop it with: $0 hub stop"
    fi
  fi
  rm -f "$READY_FILE"
  if [ -f "$hub_tokens" ]; then
    if [ "$foreground" -eq 1 ]; then
      exec python3 "$HUB" serve --bind "$bind" --port "$port" \
        --token-file "$hub_tokens" --ready-file "$READY_FILE" --pid-file "$PID_FILE"
    fi
    (
      setsid python3 "$HUB" serve --bind "$bind" --port "$port" \
        --token-file "$hub_tokens" --ready-file "$READY_FILE" --pid-file "$PID_FILE" \
        >> "$LOG_FILE" 2>&1 < /dev/null &
    )
  else
    [ -f "$token_file" ] || die "no hub credential; run: $0 token --ensure, or write class-scoped lines to $hub_tokens"
    local single
    single=$(fm_backend_stream_token) || exit 1
    if [ "$foreground" -eq 1 ]; then
      FM_STREAM_TOKEN="$single" exec python3 "$HUB" serve --bind "$bind" --port "$port" \
        --ready-file "$READY_FILE" --pid-file "$PID_FILE"
    fi
    (
      FM_STREAM_TOKEN="$single" setsid python3 "$HUB" serve --bind "$bind" --port "$port" \
        --ready-file "$READY_FILE" --pid-file "$PID_FILE" \
        >> "$LOG_FILE" 2>&1 < /dev/null &
    )
  fi
  local waited=0
  while [ "$waited" -lt 100 ]; do
    [ -s "$READY_FILE" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$READY_FILE" ] || die "the hub did not report ready; see $LOG_FILE"
  local host listening
  read -r host listening < "$READY_FILE"
  printf 'hub listening on http://%s:%s\n' "$host" "$listening"
}

cmd_hub_stop() {
  [ -f "$PID_FILE" ] || die "no hub process is recorded for this home"
  local pid
  pid=$(cat "$PID_FILE" 2>/dev/null || true)
  [ -n "$pid" ] || die "the recorded hub pid file is empty"
  kill "$pid" 2>/dev/null || die "the recorded hub process $pid is not running"
  local waited=0
  while [ "$waited" -lt 100 ]; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.1
    waited=$((waited + 1))
  done
  kill -0 "$pid" 2>/dev/null && die "the hub process $pid did not exit"
  rm -f "$PID_FILE" "$READY_FILE"
  printf 'hub stopped\n'
}

cmd_status() {
  local url out
  url=$(fm_backend_stream_hub_url) || exit 1
  if [ -f "$PID_FILE" ]; then
    local pid
    pid=$(cat "$PID_FILE" 2>/dev/null || true)
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
      printf 'local hub process: %s\n' "$pid"
    else
      printf 'local hub process: recorded as %s but not running\n' "${pid:-none}"
    fi
  else
    printf 'local hub process: none recorded (this home may point at a hub elsewhere)\n'
  fi
  if out=$(fm_backend_stream_api GET /v1/health); then
    printf 'hub at %s: %s\n' "$url" \
      "$(printf '%s' "$out" | jq -r '"protocol \(.protocol) version \(.version) endpoints \(.endpoints)"')"
  else
    printf 'hub at %s: %s\n' "$url" "$(fm_backend_stream_api_error "$out")"
    return 1
  fi
}

cmd_token() {
  local ensure=0
  [ "${1:-}" = "--ensure" ] && ensure=1
  local token_file="$CONFIG/stream-token"
  if [ "$ensure" -eq 1 ] && [ ! -f "$token_file" ]; then
    mkdir -p "$CONFIG"
    umask 077
    python3 -c 'import secrets; print(secrets.token_urlsafe(32))' > "$token_file"
    chmod 600 "$token_file"
    printf 'wrote a new hub token to %s\n' "$token_file" >&2
  fi
  fm_backend_stream_token || exit 1
  printf '\n'
}

cmd_web() {
  local url token
  url=$(fm_backend_stream_hub_url) || exit 1
  token=$(fm_backend_stream_token) || exit 1
  # The token rides in the fragment, which a browser never sends to the server,
  # so this navigation carries no credential. The page's own event stream does
  # put it in a URL, because an EventSource cannot set a header.
  printf '%s/ui#%s\n' "$url" "$token"
}

cmd_machines() {
  need_token
  local out
  out=$(fm_backend_stream_api GET /v1/machines) || {
    die "could not list machines: $(fm_backend_stream_api_error "$out")"
  }
  printf '%s' "$out" | jq -r '.machines[]? | "\(.machine)\tsilent \(.silent_for_secs)s\treachable=\(.reachable)"'
}

cmd_tasks() {
  need_token
  local out
  out=$(fm_backend_stream_api GET /v1/tasks) || {
    die "could not list endpoints: $(fm_backend_stream_api_error "$out")"
  }
  printf '%s' "$out" | jq -r '.tasks[]? | "\(.machine)\t\(.label)\t\(.endpoint_id)\t\(if .closed_at then "closed" else "live" end)"'
}

cmd_order() {
  local leaf=${1:?order needs a leaf id, "<machine>/<label>"}
  local execution=${2:?order needs the execution id it is aimed at}
  local text=${3?order needs the text to send}
  shift 3 || true
  local submit=true out code outcome reason
  while [ $# -gt 0 ]; do
    case "$1" in
      --no-submit) submit=false; shift ;;
      *) die "unknown option for order: $1" ;;
    esac
  done
  need_token
  local body
  body=$(jq -nc --arg leaf "$leaf" --arg execution "$execution" --arg text "$text" \
    --argjson submit "$submit" \
    '{leaf_worker_id: $leaf, execution_id: $execution, text: $text, submit: $submit}') \
    || die "could not build the order"
  out=$(fm_backend_stream_api POST /v1/orders "$body") || true
  code=${FM_BACKEND_STREAM_HTTP_CODE:-000}
  outcome=$(printf '%s' "$out" | jq -r '.outcome // empty' 2>/dev/null)
  case "$outcome" in
    accepted)
      printf 'accepted by %s (order %s)\n' \
        "$(printf '%s' "$out" | jq -r '.execution_id')" \
        "$(printf '%s' "$out" | jq -r '.order_id')"
      return 0
      ;;
    unconfirmed)
      # The one answer that is neither success nor failure. Sending it again
      # could type it twice, so the operator is told what to read rather than
      # nudged to retry.
      printf 'UNCONFIRMED: %s\n' "$(fm_backend_stream_api_error "$out")" >&2
      printf 'read it back with: %s order-status %s\n' \
        "${FM_STREAM_SCRIPT##*/}" "$(printf '%s' "$out" | jq -r '.order_id')" >&2
      return 4
      ;;
    refused)
      reason=$(printf '%s' "$out" | jq -r '.reason // .error // "refused"')
      printf 'refused (%s): %s\n' "$reason" "$(fm_backend_stream_api_error "$out")" >&2
      return 1
      ;;
  esac
  die "the hub did not answer with an order outcome (HTTP $code): $(fm_backend_stream_api_error "$out")"
}

cmd_order_status() {
  local order=${1:?order-status needs an order id}
  need_token
  local out
  out=$(fm_backend_stream_api GET "/v1/orders/$order") || {
    die "could not read order $order: $(fm_backend_stream_api_error "$out")"
  }
  printf '%s' "$out" | jq -r '.order
    | "\(.outcome)\tleaf \(.leaf_worker_id)\texecution \(.execution_id)"
      + "\tdelivered \(if .delivered == null then "unknown" else .delivered end)"
      + "\tworker_gone \(.worker_gone)"
      + (if .reason then "\t\(.reason)" else "" end)'
}

cmd_attach() {
  local raw=${1:?attach needs an endpoint} ; shift || true
  local query="" target endpoint url token
  while [ $# -gt 0 ]; do
    case "$1" in
      --replay) query="?replay=1"; shift ;;
      *) die "unknown option for attach: $1" ;;
    esac
  done
  target=$(resolve_target "$raw") || exit 1
  fm_backend_stream_parse_target "$target" || exit 1
  endpoint=$FM_BACKEND_STREAM_ENDPOINT
  url=$(fm_backend_stream_hub_url) || exit 1
  token=$(fm_backend_stream_token) || exit 1
  curl -sS -N --config <(printf 'header = "Authorization: Bearer %s"\n' "$token") \
    "$url/v1/tasks/$endpoint/stream$query" \
    | python3 -u -c '
import base64, json, sys
for line in sys.stdin:
    if not line.startswith("data: "):
        continue
    record = json.loads(line[6:])
    if "b64" in record:
        sys.stdout.buffer.write(base64.b64decode(record["b64"]))
        sys.stdout.buffer.flush()
    elif record.get("closed"):
        sys.stderr.write("\n[endpoint closed, exit %s]\n" % record.get("exit_code"))
        break
'
}

[ $# -gt 0 ] || { usage; exit 2; }
COMMAND=$1
shift
case "$COMMAND" in
  hub)
    SUB=${1:?hub needs start or stop}
    shift
    case "$SUB" in
      start) cmd_hub_start "$@" ;;
      stop) cmd_hub_stop ;;
      *) die "unknown hub subcommand: $SUB" ;;
    esac
    ;;
  status) cmd_status ;;
  url) fm_backend_stream_hub_url && printf '\n' ;;
  token) cmd_token "$@" ;;
  web) cmd_web ;;
  machines) cmd_machines ;;
  tasks) cmd_tasks ;;
  order) cmd_order "$@" ;;
  order-status) cmd_order_status "$@" ;;
  attach) cmd_attach "$@" ;;
  -h|--help|help) usage ;;
  *) die "unknown command: $COMMAND" ;;
esac
