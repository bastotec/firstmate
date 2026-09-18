#!/usr/bin/env bash
# The SAME live drive, run against the PRE-CHANGE agent (bin/fm-stream-agent.py
# at base commit 5547406) with everything else identical. This is the failure
# the change exists to remove: after the hub restarts, the worker keeps running
# but never comes back to the central listing and cannot be steered.
set -u
ROOT=${ROOT:?}; BASE_AGENT=${BASE_AGENT:?}
HOME_DIR=$(mktemp -d /tmp/fm-stream-base.XXXXXX)
TOKEN="base-token-$$"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/cwd"
printf 'publish,subscribe,control:%s\n' "$TOKEN" > "$HOME_DIR/config/stream-hub-tokens"
printf '%s\n' "$TOKEN" > "$HOME_DIR/config/stream-token"
chmod 600 "$HOME_DIR/config/stream-hub-tokens" "$HOME_DIR/config/stream-token"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
printf 'http://127.0.0.1:%s\n' "$PORT" > "$HOME_DIR/config/stream-hub"
stream() { FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-stream.sh" "$@"; }
adapter() { ( export FM_STREAM_HUB="http://127.0.0.1:$PORT" FM_STREAM_TOKEN="$TOKEN" FM_STREAM_MACHINE=box-drive
  export FM_HOME="$HOME_DIR" FM_ROOT="$ROOT" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
  . "$ROOT/bin/fm-backend.sh"; fm_backend_source stream || exit 90
  FM_BACKEND_STREAM_AGENT_BIN="$BASE_AGENT"; "$@" ); }
agent_pid_for() { ps -eo pid,args 2>/dev/null | awk -v l="--label $1" \
  'index($0,"fm-stream-agent.py") && index($0,l) && !index($0,"awk"){print $1; exit}'; }
say() { printf '\n=== %s ===\n' "$*"; }
LABEL="base-worker-$$"
cleanup() { pid=$(pgrep -f "$LABEL" | head -1); [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null
  stream hub stop >/dev/null 2>&1; rm -rf "$HOME_DIR"; }
trap cleanup EXIT

say "pre-change agent: $BASE_AGENT"
stream hub start --port "$PORT" 2>&1
PAIR=$(adapter fm_backend_stream_create_task "$LABEL" "$HOME_DIR/cwd") || { echo "spawn failed"; exit 1; }
TARGET="${PAIR%% *}:${PAIR##* }"; ENDPOINT="${PAIR##* }"
AGENT_PID=$(pgrep -f "$LABEL" | head -1)
say "worker up and steerable before the restart"
stream tasks 2>&1
adapter fm_backend_send_text_submit stream "$TARGET" 'echo BEFORE' 3 0.2 0.2 >/dev/null && echo "steer accepted"

say "THE HUB RESTARTS"
stream hub stop 2>&1; stream hub start --port "$PORT" 2>&1

say "60 seconds later, the fleet listing still has no such worker"
sleep 60
echo "--- fm-stream.sh tasks ---"
stream tasks 2>&1
echo "--- is the worker's endpoint listed? ---"
if stream tasks 2>&1 | grep -q "$ENDPOINT"; then echo "listed"; else echo "NOT LISTED - stranded"; fi
echo "--- the worker's own process is still running: ---"
ps -o pid,stat,args -p "$AGENT_PID" 2>/dev/null | tail -1 | cut -c1-120
echo "--- a steer aimed at it ---"
OUT=$(adapter fm_backend_send_text_submit stream "$TARGET" 'echo AFTER' 3 0.2 0.2 2>&1); RC=$?
echo "send result: '$OUT' (exit $RC)"
case $OUT in *send-failed*|*fail*) echo "STEER NOT DELIVERED - the worker cannot be steered" ;; *) echo "steer delivered" ;; esac
echo "--- supervision verdict ---"
echo "fm_backend_agent_state -> $(adapter fm_backend_agent_state stream "$TARGET")"
