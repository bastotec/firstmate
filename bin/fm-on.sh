#!/usr/bin/env bash
# Execute one tracked Firstmate command in a remote home or machine operation lane.
#
# Usage:
#   fm-on.sh [--stdin] [--machine-root <root>] <secondmate-id|ssh-alias> <fm-command> [args...]
#
# --machine-root selects a machine's code root and its sibling <root>.machine-home
# as the operation lane; machine commands do not require a secondmate route.
# Otherwise routes come from remote records in data/secondmates.md. A record names an
# SSH config alias, remote Firstmate code root, and remote FM_HOME. A host alias
# may be used directly only when exactly one record selects it; an ambiguous
# alias is refused. The command must be a genuine executable in this checkout's
# bin/fm-*.sh namespace; there is no command authorization allowlist.
# The bridge classification table below selects the required flow permissions.
#
# argv is encoded as one NUL-delimited stream and passed through the fixed
# fm-remote-entrypoint.sh. The remote command's stdin is /dev/null by default,
# because remote staging captures stdin to EOF and an open caller stream would
# block staging indefinitely; a payload caller passes --stdin to forward its
# own stream as the job's bounded input. stdout and stderr remain separate, and
# ssh's exit status is returned unchanged. OpenSSH never receives an auto-retry
# instruction here. Exit 255 therefore means unavailable transport or unknown
# remote completion and must be reconciled by the semantic caller, never
# blindly repeated by this layer.
#
# The SSH alias keeps its public-key configuration in ~/.ssh, but every call
# forces StrictHostKeyChecking=yes and UpdateHostKeys=no, including the doctor.
# BatchMode makes a password prompt fail at once instead of asking on the
# controlling terminal, which inside a pane is an agent's composer: a prompt
# there swallows the next typed line. Unknown host keys are refused, and this
# transport never adds or refreshes known_hosts entries.
# Before any ssh, the command's flow (supervision, reports, messages, placement, files,
# maintenance; the readiness doctor is never gated) must be allowed on the bridge to
# that host by bin/fm-bridge.sh check. A refused flow exits 1 with `bridge-blocked:` on
# stderr, nothing sent; bin/fm-bridge.py owns refusal auditing and request publication.
# The classification table below is the single owner of which remote command
# requires which flows; an unlisted command counts as maintenance.
# A command assigned multiple flows must pass every permission check.
# This command explicitly disables agent forwarding, forwarding setup, and
# configured SendEnv patterns. The remote entrypoint executes the selected
# command under an empty environment with only its fixed runtime values.
#
# ServerAliveInterval/ServerAliveCountMax arm dead-peer detection so a vanished
# peer (a reboot, a dropped link) becomes a bounded ssh failure (exit 255)
# instead of an indefinite hang on a half-open TCP connection. The remote
# sshd answers keepalive probes independently of whatever the remote command
# is doing, so a legitimately long-but-alive remote command is never falsely
# killed. FM_SSH_ALIVE_INTERVAL and FM_SSH_ALIVE_COUNT_MAX override the
# defaults; the worst-case detection window is roughly interval * count.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
REG="$DATA/secondmates.md"
PROTOCOL=1

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

encode_base64() {
  base64 | tr -d '\n'
}

STDIN_MODE=closed
MACHINE_ROOT=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --stdin) STDIN_MODE=caller; shift ;;
    --machine-root) [ "$#" -ge 2 ] || usage; MACHINE_ROOT=$2; shift 2 ;;
    *) break ;;
  esac
done
[ "$#" -ge 2 ] || usage
ROUTE=$1
COMMAND=$2
shift 2

case "$ROUTE" in ''|-*|*[!A-Za-z0-9._-]*) die "remote route must be a safe secondmate id or SSH alias: $ROUTE" ;; esac
case "$COMMAND" in
  fm-*.sh) ;;
  *) die "remote command must be a basename in the fm-*.sh namespace: $COMMAND" ;;
esac
case "$COMMAND" in */*|*..*) die "remote command must not contain a path or traversal: $COMMAND" ;; esac
LOCAL_COMMAND="$FM_ROOT/bin/$COMMAND"
[ -f "$LOCAL_COMMAND" ] && [ ! -L "$LOCAL_COMMAND" ] && [ -x "$LOCAL_COMMAND" ] \
  || die "remote command is not a genuine tracked executable in this Firstmate checkout: $COMMAND"
git -C "$FM_ROOT" ls-files --error-unmatch "bin/$COMMAND" >/dev/null 2>&1 \
  || die "remote command is not tracked by this Firstmate checkout: $COMMAND"
MATCHES=0
HOST=
ROOT=
HOME_PATH=
if [ -n "$MACHINE_ROOT" ]; then
  HOST=$ROUTE
  ROOT=$MACHINE_ROOT
  HOME_PATH="${MACHINE_ROOT%/}.machine-home"
else
  [ -f "$REG" ] && [ ! -L "$REG" ] || die "no safe secondmate registry at $REG"
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in '- '*) ;; *) continue ;; esac
    secondmate_registry_parse_line "$line" || die "malformed secondmate registry entry: $line"
    [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
    if [ "$SECONDMATE_REGISTRY_ID" = "$ROUTE" ] || [ "$SECONDMATE_REGISTRY_HOST" = "$ROUTE" ]; then
      MATCHES=$((MATCHES + 1))
      HOST=$SECONDMATE_REGISTRY_HOST
      ROOT=$SECONDMATE_REGISTRY_ROOT
      HOME_PATH=$SECONDMATE_REGISTRY_HOME
    fi
  done < "$REG"
  [ "$MATCHES" -gt 0 ] || die "no remote secondmate or SSH alias matches '$ROUTE'"
  [ "$MATCHES" -eq 1 ] || die "remote route '$ROUTE' is ambiguous across $MATCHES configured secondmates; use a secondmate id"
fi
case "$HOST" in ''|-*|*[!A-Za-z0-9._-]*) die "configured SSH alias is unsafe: $HOST" ;; esac
case "$ROOT" in /*) ;; *) die "configured remote root is not absolute: $ROOT" ;; esac
case "$HOME_PATH" in /*) ;; *) die "configured remote home is not absolute: $HOME_PATH" ;; esac
case "$ROOT$HOME_PATH" in *$'\n'*|*$'\r'*|*$'\t'*) die "configured remote root or home contains control characters" ;; esac
for configured_path in "$ROOT" "$HOME_PATH"; do
  case "/$configured_path/" in */../*|*/./*) die "configured remote root or home contains traversal components" ;; esac
  case "$configured_path" in *'//'*) die "configured remote root or home contains an empty path component" ;; esac
done

# Bridge gate (bin/fm-bridge.py owns flows, defaults and the refused-flow request):
# classify this command's flow and refuse before anything crosses the bridge.
FLOW=maintenance
case "$COMMAND" in
  fm-remote-doctor.sh) FLOW= ;;
  fm-remote-secondmate-control.sh)
    case "${1:-}" in
      send|send-stream|key) FLOW=messages ;;
      launch) FLOW=placement ;;
      sync|update) FLOW=maintenance ;;
      *) FLOW=supervision ;;
    esac ;;
  fm-retire-endpoint.sh|fm-control.sh) FLOW=supervision ;;
  fm-backlog-receive.sh) FLOW=placement ;;
  fm-idle-sweep.sh)
    [ "${1:-}" != summary ] || FLOW=reports ;;
  fm-remote-file.sh)
    FLOW=files
    if [ "${1:-}" = get ] && [ "${2:-}" = state/home-summary.json ]; then
      FLOW='files reports'
    fi ;;
  fm-remote-delta-read.sh|fm-procevent-remote-reply.sh|fm-public-followup-collect.sh|fm-x-followup.sh|fm-crew-state.sh|fm-peek.sh) FLOW=reports ;;
esac
for FLOW in $FLOW; do
  if ! BRIDGE_ANSWER=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-bridge.sh" check "$HOST" "$FLOW" 2>&1); then
    REQUEST=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-bridge.sh" block "$HOST" "$FLOW" --what "$COMMAND ${1:-}" 2>/dev/null) || REQUEST=
    printf 'bridge-blocked: %s; nothing was sent to %s. The captain must allow %s on that bridge%s.\n' \
      "${BRIDGE_ANSWER#deny: }" "$HOST" "$FLOW" "${REQUEST:+ (request $REQUEST is waiting for him in Fleet Town)}" >&2
    exit 1
  fi
done

ROOT_B64=$(printf '%s' "$ROOT" | encode_base64)
HOME_B64=$(printf '%s' "$HOME_PATH" | encode_base64)
ARGV_B64=$(printf '%s\0' "$COMMAND" "$@" | encode_base64)
SSH_BIN=${FM_SSH_BIN:-ssh}
ALIVE_INTERVAL=${FM_SSH_ALIVE_INTERVAL:-15}
ALIVE_COUNT_MAX=${FM_SSH_ALIVE_COUNT_MAX:-3}
case "$ALIVE_INTERVAL" in ''|*[!0-9]*) die "FM_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL" ;; esac
case "$ALIVE_COUNT_MAX" in ''|*[!0-9]*) die "FM_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX" ;; esac
[ "$ALIVE_INTERVAL" -gt 0 ] || die "FM_SSH_ALIVE_INTERVAL must be a positive integer: $ALIVE_INTERVAL"
[ "$ALIVE_COUNT_MAX" -gt 0 ] || die "FM_SSH_ALIVE_COUNT_MAX must be a positive integer: $ALIVE_COUNT_MAX"

SSH_ARGS=(
  -o BatchMode=yes
  -o ForwardAgent=no
  -o ClearAllForwardings=yes
  -o 'SendEnv=-*'
  -o UpdateHostKeys=no
  -o StrictHostKeyChecking=yes
  -o "ServerAliveInterval=$ALIVE_INTERVAL"
  -o "ServerAliveCountMax=$ALIVE_COUNT_MAX"
  -- "$HOST" fm-remote-entrypoint.sh "$PROTOCOL" "$ROOT_B64" "$HOME_B64" "$ARGV_B64"
)
if [ "$STDIN_MODE" = caller ]; then
  exec "$SSH_BIN" "${SSH_ARGS[@]}"
fi
exec "$SSH_BIN" "${SSH_ARGS[@]}" < /dev/null
