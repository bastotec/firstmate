#!/usr/bin/env bash
# Live operator drive: a stream worker rejoins the hub after the hub restarts.
# Everything here runs the real product: bin/fm-stream.sh (operator CLI),
# bin/fm-stream-hub.py (hub), bin/fm-stream-agent.py (agent owning a real pty),
# and the shared dispatcher (bin/fm-backend.sh -> bin/backends/stream.sh) that
# fm-send/fm-peek/fm-crew-state use.
set -u
ROOT=${ROOT:?}
HOME_DIR=$(mktemp -d /tmp/fm-stream-drive.XXXXXX)
TOKEN="drive-token-$$"
mkdir -p "$HOME_DIR/config" "$HOME_DIR/state" "$HOME_DIR/cwd"
printf 'publish,subscribe,control:%s\n' "$TOKEN" > "$HOME_DIR/config/stream-hub-tokens"
printf '%s\n' "$TOKEN" > "$HOME_DIR/config/stream-token"
chmod 600 "$HOME_DIR/config/stream-hub-tokens" "$HOME_DIR/config/stream-token"
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
printf 'http://127.0.0.1:%s\n' "$PORT" > "$HOME_DIR/config/stream-hub"

stream() {
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-stream.sh" "$@"
}
adapter() {
  (
    export FM_STREAM_HUB="http://127.0.0.1:$PORT" FM_STREAM_TOKEN="$TOKEN" FM_STREAM_MACHINE=box-drive
    export FM_HOME="$HOME_DIR" FM_ROOT="$ROOT" FM_CONFIG_OVERRIDE="$HOME_DIR/config"
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source stream || exit 90
    "$@"
  )
}
agent_pid_for() {
  ps -eo pid,args 2>/dev/null | awk -v l="--label $1" \
    'index($0,"fm-stream-agent.py") && index($0,l) && !index($0,"awk"){print $1; exit}'
}
say() { printf '\n=== %s ===\n' "$*"; }

LABEL="drive-worker-$$"
cleanup() {
  pid=$(agent_pid_for "$LABEL"); [ -n "${pid:-}" ] && kill "$pid" 2>/dev/null
  stream hub stop >/dev/null 2>&1
  rm -rf "$HOME_DIR"
}
trap cleanup EXIT

say "1. operator starts the fleet hub"
stream hub start --port "$PORT" 2>&1
stream status 2>&1

say "2. a task is spawned on the stream backend (real agent, real pty)"
PAIR=$(adapter fm_backend_stream_create_task "$LABEL" "$HOME_DIR/cwd" "$HOME_DIR/state/$LABEL.status") \
  || { echo "FAIL: could not create the endpoint"; exit 1; }
TARGET="${PAIR%% *}:${PAIR##* }"
ENDPOINT="${PAIR##* }"
AGENT_PID=$(agent_pid_for "$LABEL")
echo "target=$TARGET"
echo "agent pid=$AGENT_PID"

say "3. fm-stream.sh tasks - the worker is in the central listing"
stream tasks 2>&1

say "4. the operator steers it before the restart"
adapter fm_backend_send_text_submit stream "$TARGET" 'echo BEFORE-RESTART' 3 0.2 0.2 >/dev/null \
  || { echo "FAIL: pre-restart steer refused"; exit 1; }
for _ in $(seq 60); do
  CAP=$(adapter fm_backend_capture stream "$TARGET" 40 2>/dev/null)
  case $CAP in *BEFORE-RESTART*) break ;; esac
  sleep 0.2
done
printf '%s\n' "$CAP" | grep -F BEFORE-RESTART | tail -2

STATE_BEFORE=$(adapter fm_backend_agent_state stream "$TARGET")

say "5. THE HUB RESTARTS (stop, then start again on the same address)"
stream hub stop 2>&1
stream tasks 2>&1 || true
stream hub start --port "$PORT" 2>&1
RESTART_AT=$(date +%s.%N)

say "6. without anyone touching the worker's machine, it returns to the listing"
LISTED=""
for _ in $(seq 300); do
  OUT=$(stream tasks 2>&1)
  case $OUT in *"$ENDPOINT"*) LISTED=$OUT; break ;; esac
  sleep 0.1
done
BACK_AT=$(date +%s.%N)
if [ -z "$LISTED" ]; then echo "FAIL: the worker never came back to the listing"; exit 1; fi
printf 'rejoined after %.1fs\n' "$(echo "$BACK_AT - $RESTART_AT" | bc)"
printf '%s\n' "$LISTED"

say "7. it is the SAME endpoint id and the SAME agent process (identity kept)"
echo "endpoint before restart: $ENDPOINT"
echo "endpoint in listing:     $(printf '%s\n' "$LISTED" | grep -o "$ENDPOINT" | head -1)"
echo "agent pid before: $AGENT_PID   after: $(agent_pid_for "$LABEL")"
[ "$AGENT_PID" = "$(agent_pid_for "$LABEL")" ] || { echo "FAIL: the agent was replaced"; exit 1; }

say "8. a steer sent the moment it is listed again is DELIVERED"
STEER_AT=$(date +%s.%N)
adapter fm_backend_send_text_submit stream "$TARGET" 'echo AFTER-RESTART' 3 0.2 0.2 >/dev/null \
  || { echo "FAIL: post-restart steer was refused (undelivered)"; exit 1; }
DONE_AT=$(date +%s.%N)
printf 'steer accepted %.1fs after the worker was listed again\n' "$(echo "$STEER_AT - $BACK_AT" | bc)"
printf 'steer round trip %.1fs\n' "$(echo "$DONE_AT - $STEER_AT" | bc)"
CAP=""
for _ in $(seq 80); do
  CAP=$(adapter fm_backend_capture stream "$TARGET" 40 2>/dev/null)
  case $CAP in *AFTER-RESTART*) break ;; esac
  sleep 0.2
done
case $CAP in
  *AFTER-RESTART*) printf '%s\n' "$CAP" | grep -F AFTER-RESTART | tail -2 ;;
  *) echo "FAIL: the recovered worker never ran what was typed into it"; exit 1 ;;
esac

say "9. supervision reads the same verdict it read before the restart"
echo "fm_backend_agent_state before restart -> $STATE_BEFORE"
echo "fm_backend_agent_state after  restart -> $(adapter fm_backend_agent_state stream "$TARGET")"
echo "fm_backend_target_exists -> $(adapter fm_backend_target_exists stream "$TARGET" && echo yes || echo no)"

say "10. its status channel still writes into the task's own record"
adapter fm_backend_stream_report_status "$TARGET" working 'back after the restart' >/dev/null \
  || { echo "FAIL: status refused"; exit 1; }
sleep 1
tail -1 "$HOME_DIR/state/$LABEL.status"

say "RESULT: PASS - worker rejoined, kept its identity, and steers again"
