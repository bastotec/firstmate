#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../tests/lib.sh"
HUB="$ROOT/bin/fm-stream-hub.py"
TMP_ROOT=$(fm_test_tmproot repro-brokenshell)
CASE_DIR="$TMP_ROOT/case"
TOKEN="repro-token-$$"
URL=""
HUB_PID=""
cleanup() { fm_test_reap_helper_pids; fm_test_cleanup; }
trap cleanup EXIT INT TERM
mkdir -p "$CASE_DIR/home/config" "$CASE_DIR/home/state" "$CASE_DIR/cwd"
printf 'publish,subscribe,control:%s\n' "$TOKEN" > "$CASE_DIR/tokens"
chmod 600 "$CASE_DIR/tokens"
python3 "$HUB" serve --bind 127.0.0.1 --port 0 --token-file "$CASE_DIR/tokens" --ready-file "$CASE_DIR/ready" > "$CASE_DIR/log" 2>&1 &
HUB_PID=$!
fm_test_track_helper_pid "$HUB_PID"
waited=0
while [ "$waited" -lt 100 ]; do [ -s "$CASE_DIR/ready" ] && break; sleep 0.1; waited=$((waited+1)); done
read -r host port < "$CASE_DIR/ready"
URL="http://$host:$port"
printf '#!/bin/sh\necho "this shell cannot start" >&2\nexit 3\n' > "$CASE_DIR/broken-shell"
chmod +x "$CASE_DIR/broken-shell"
with_stream_env() { (
  export FM_STREAM_HUB="$URL" FM_STREAM_TOKEN="$TOKEN" FM_STREAM_MACHINE=box-test
  export FM_HOME="$CASE_DIR/home" FM_ROOT="$ROOT" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config"
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source stream || exit 90
  "$@"
); }
set -x
out=$(SHELL="$CASE_DIR/broken-shell" with_stream_env fm_backend_stream_create_task "fm-broken-repro" "$CASE_DIR/cwd" 2>&1)
rc=$?
set +x
echo "REPRO rc=$rc out=<<$out>>"
echo "--- tasks on hub:"
with_stream_env fm_backend_stream_api GET /v1/tasks 2>/dev/null | jq -r '[.tasks[] | select(.label | startswith("fm-broken"))] | length'
