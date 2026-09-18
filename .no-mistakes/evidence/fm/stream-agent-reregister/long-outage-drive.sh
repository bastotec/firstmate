#!/usr/bin/env bash
# Adversarial live drive against the same real product:
#   (a) a LONG hub outage (~55s), long enough for the agent's command-poll and
#       re-registration backoff ladders to grow, then the hub returns;
#   (b) a steer sent the instant the worker is listed again must be DELIVERED,
#       not refused as undelivered;
#   (c) a SECOND restart moments after that recovery must be met at the pace
#       floor (seconds), not at the wait the first outage had grown.
set -u
ROOT=${ROOT:?}
HOME_DIR=$(mktemp -d /tmp/fm-stream-outage.XXXXXX)
TOKEN="outage-token-$$"
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
  . "$ROOT/bin/fm-backend.sh"; fm_backend_source stream || exit 90; "$@" ); }
agent_pid_for() { ps -eo pid,args 2>/dev/null | awk -v l="--label $1" \
  'index($0,"fm-stream-agent.py") && index($0,l) && !index($0,"awk"){print $1; exit}'; }
say() { printf '\n=== %s ===\n' "$*"; }
LABEL="outage-worker-$$"
cleanup() { pid=$(agent_pid_for "$LABEL"); [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null
  stream hub stop >/dev/null 2>&1; rm -rf "$HOME_DIR"; }
trap cleanup EXIT

wait_listed() {  # -> seconds waited, fails after 120s
  local deadline=$((SECONDS + 120))
  while [ "$SECONDS" -lt "$deadline" ]; do
    case $(stream tasks 2>&1) in *"$ENDPOINT"*) return 0 ;; esac
    sleep 0.2
  done
  return 1
}
ran() {  # <needle>
  local deadline=$((SECONDS + 20)) out
  while [ "$SECONDS" -lt "$deadline" ]; do
    out=$(adapter fm_backend_capture stream "$TARGET" 40 2>/dev/null)
    case $out in *"$1"*) printf '%s\n' "$out" | grep -F "$1" | tail -1; return 0 ;; esac
    sleep 0.3
  done
  return 1
}

stream hub start --port "$PORT" >/dev/null 2>&1 || { echo "FAIL: hub did not start"; exit 1; }
PAIR=$(adapter fm_backend_stream_create_task "$LABEL" "$HOME_DIR/cwd") || { echo "FAIL: spawn"; exit 1; }
TARGET="${PAIR%% *}:${PAIR##* }"; ENDPOINT="${PAIR##* }"
AGENT_PID=$(agent_pid_for "$LABEL")
say "worker up: $TARGET (agent pid $AGENT_PID)"
adapter fm_backend_send_text_submit stream "$TARGET" 'echo BEFORE' 3 0.2 0.2 >/dev/null
ran BEFORE || { echo "FAIL: worker never steerable to begin with"; exit 1; }

say "(a) the hub goes down and STAYS down for 55s"
stream hub stop 2>&1
DOWN_START=$SECONDS
while [ $((SECONDS - DOWN_START)) -lt 55 ]; do sleep 1; done
echo "hub has been gone for $((SECONDS - DOWN_START))s - the agent's poll and re-registration backoff are both grown"
stream hub start --port "$PORT" 2>&1
T0=$SECONDS
wait_listed || { echo "FAIL: the worker never rejoined after the long outage"; exit 1; }
echo "rejoined the listing $((SECONDS - T0))s after the hub returned"
stream tasks 2>&1

say "(b) a steer sent immediately on that listing must be DELIVERED"
T1=$SECONDS
if adapter fm_backend_send_text_submit stream "$TARGET" 'echo AFTER-LONG-OUTAGE' 3 0.2 0.2 >/dev/null; then
  echo "steer accepted after $((SECONDS - T1))s (a steer no agent acknowledges is refused instead)"
else
  echo "FAIL: the steer was refused - the worker was listed but not steerable"; exit 1
fi
ran AFTER-LONG-OUTAGE || { echo "FAIL: the recovered worker never ran the steer"; exit 1; }

say "(c) a SECOND restart right afterwards must be met at the pace floor"
stream hub stop 2>&1
stream hub start --port "$PORT" 2>&1
T2=$SECONDS
wait_listed || { echo "FAIL: the worker did not come back after the second restart"; exit 1; }
SECOND=$((SECONDS - T2))
echo "rejoined the second restart in ${SECOND}s"
[ "$SECOND" -le 20 ] || { echo "FAIL: the second rejoin waited on the spent ladder (${SECOND}s)"; exit 1; }
adapter fm_backend_send_text_submit stream "$TARGET" 'echo AFTER-SECOND-RESTART' 3 0.2 0.2 >/dev/null \
  || { echo "FAIL: steer refused after the second restart"; exit 1; }
ran AFTER-SECOND-RESTART || { echo "FAIL: never ran the steer after the second restart"; exit 1; }
echo "agent pid unchanged throughout: $AGENT_PID -> $(agent_pid_for "$LABEL")"
[ "$AGENT_PID" = "$(agent_pid_for "$LABEL")" ] || { echo "FAIL: agent replaced"; exit 1; }

say "RESULT: PASS - a long outage, an immediate steer, and a second restart all recover"
