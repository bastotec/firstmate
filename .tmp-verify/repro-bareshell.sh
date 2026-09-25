#!/usr/bin/env bash
# Local macOS diagnosis: reproduce the bare-shell classification case and dump
# the raw identity records the classifier saw, plus per-surface verdicts.
set -u
. "$(dirname "${BASH_SOURCE[0]}")/../tests/lib.sh"
HUB="$ROOT/bin/fm-stream-hub.py"
TMP_ROOT=$(fm_test_tmproot repro-bareshell)
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
while [ "$waited" -lt 100 ]; do [ -s "$CASE_DIR/ready" ] && break; sleep 0.1; waited=$((waited + 1)); done
read -r host port < "$CASE_DIR/ready"
URL="http://$host:$port"

with_stream_env() { (
  export FM_STREAM_HUB="$URL" FM_STREAM_TOKEN="$TOKEN" FM_STREAM_MACHINE=box-test
  export FM_HOME="$CASE_DIR/home" FM_ROOT="$ROOT" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config"
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source stream || exit 90
  "$@"
); }

echo "SHELL env: ${SHELL:-unset}"
pair=$(with_stream_env fm_backend_stream_create_task "fm-bare-$$" "$CASE_DIR/cwd") || { echo "create failed"; exit 1; }
target="${pair%%:*}:${pair##* }"
echo "target=$target"
sleep 3
echo "--- raw /processes:"
get_processes() { (
  export FM_STREAM_HUB="$URL" FM_STREAM_TOKEN="$TOKEN" FM_STREAM_MACHINE=box-test
  export FM_HOME="$CASE_DIR/home" FM_ROOT="$ROOT" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config"
  . "$ROOT/bin/fm-backend.sh"
  fm_backend_source stream || exit 90
  fm_backend_stream_parse_target "$target" || echo "PARSE FAILED rc=$? fault=$FM_BACKEND_STREAM_TARGET_FAULT" >&2
  echo "endpoint=[$FM_BACKEND_STREAM_ENDPOINT]" >&2
  fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT/processes"
); }
get_processes
echo
echo "--- classifier verdict:"
with_stream_env fm_backend_agent_state stream "$target"
echo
echo "--- per-record classify (name/argv0/args -> fm_agent_process_classify):"
. "$ROOT/bin/fm-agent-process-lib.sh" 2>/dev/null || true
get_processes 2>/dev/null \
  | jq -r '.foreground[] | "\(.pid) name=<\(.name)> argv0=<\(.argv0)> args=<\(.args)>"'
