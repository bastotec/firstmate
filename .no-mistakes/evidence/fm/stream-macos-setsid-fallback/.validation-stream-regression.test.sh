#!/usr/bin/env bash
set -u
. "$(dirname "${BASH_SOURCE[0]}")/.validation-stream-selected.test.sh"
BASE_CODE=$(fm_test_tmproot fm-stream-base-launch)
cp -R "$ROOT/bin" "$BASE_CODE/bin"
git -C "$ROOT" show 6767f71cc2cc1bc5f7d6e3c4db6f3438c3e6fed5:bin/backends/stream.sh > "$BASE_CODE/bin/backends/stream.sh"
git -C "$ROOT" show 6767f71cc2cc1bc5f7d6e3c4db6f3438c3e6fed5:bin/fm-stream.sh > "$BASE_CODE/bin/fm-stream.sh"

if [ "${VALIDATION_BASE_DECK:-0}" = 1 ]; then
  ROOT=$BASE_CODE
  HUB="$ROOT/bin/fm-stream-hub.py"
  test_spawn_hosts_a_deck_secondmate
  exit
fi

command -v setsid >/dev/null 2>&1 && fail 'this regression requires setsid to be absent'
start_case_hub original-macos-failure
base_call() {
  with_stream_env bash -c '. "$1"; fm_backend_stream_create_task "$2" "$3"' _ \
    "$BASE_CODE/bin/backends/stream.sh" "$1" "$CASE_DIR/cwd"
}
rc=0
out=$(base_call "fm-base-$$" 2>&1) || rc=$?
printf 'base endpoint create exit=%s: %s\n' "$rc" "$out"
[ "$rc" -ne 0 ] || fail 'base unexpectedly started an endpoint without setsid'
assert_contains "$out" 'setsid: command not found' 'original macOS failure must be reproduced'
assert_equals "$(with_stream_env fm_backend_stream_api GET /v1/tasks | jq '.tasks | length')" 0 \
  'original failure must register no endpoint'
target=$(create_endpoint "fm-fixed-$$")
printf 'current endpoint create succeeded: %s\n' "$target"
with_stream_env fm_backend_send_text_submit stream "$target" \
  "printf '%s%s\\n' REGRESSION- FIXED" 3 0.2 0.2 >/dev/null || fail 'fixed endpoint cannot be steered'
wait_for_capture "$target" REGRESSION-FIXED || fail 'fixed endpoint did not execute input'
printf 'current capture:\n%s\n' "$(with_stream_env fm_backend_capture stream "$target" 8)"
with_stream_env fm_backend_kill stream "$target" || fail 'current endpoint cannot be closed'
printf '%s\n' "$TOKEN" > "$CASE_DIR/home/config/stream-token"
chmod 600 "$CASE_DIR/home/config/stream-token"
rc=0
out=$(FM_HOME="$CASE_DIR/home" FM_ROOT_OVERRIDE="$BASE_CODE" \
  FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" FM_STATE_OVERRIDE="$CASE_DIR/home/state" \
  FM_STREAM_HUB= FM_STREAM_TOKEN="$TOKEN" "$BASE_CODE/bin/fm-stream.sh" hub start --port 0 2>&1) || rc=$?
printf 'base hub start exit=%s: %s\n' "$rc" "$out"
[ "$rc" -ne 0 ] || fail 'base hub unexpectedly started without setsid'
assert_grep 'setsid: command not found' "$CASE_DIR/home/state/.stream-hub.log" 'base hub must expose same failure'
printf 'base hub diagnostic: '; tail -n 1 "$CASE_DIR/home/state/.stream-hub.log"
FM_HOME="$CASE_DIR/home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" \
  FM_STATE_OVERRIDE="$CASE_DIR/home/state" FM_STREAM_HUB= FM_STREAM_TOKEN="$TOKEN" \
  "$ROOT/bin/fm-stream.sh" hub start --port 0 || fail 'fixed hub could not start'
read -r pid < "$CASE_DIR/home/state/.stream-hub.pid"
fm_test_track_helper_pid "$pid"
FM_HOME="$CASE_DIR/home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" \
  FM_STATE_OVERRIDE="$CASE_DIR/home/state" FM_STREAM_HUB= FM_STREAM_TOKEN="$TOKEN" \
  "$ROOT/bin/fm-stream.sh" status || fail 'fixed hub not reachable'
FM_HOME="$CASE_DIR/home" FM_ROOT_OVERRIDE="$ROOT" FM_CONFIG_OVERRIDE="$CASE_DIR/home/config" \
  FM_STATE_OVERRIDE="$CASE_DIR/home/state" FM_STREAM_HUB= FM_STREAM_TOKEN="$TOKEN" \
  "$ROOT/bin/fm-stream.sh" hub stop || fail 'fixed hub cannot be stopped'
pass 'original endpoint and hub launch fail without setsid; current endpoint and hub work'
