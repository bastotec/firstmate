#!/usr/bin/env bash
# tests/fm-stream-attach-rust.test.sh - `fm-stream.sh attach --interactive`
# against a disposable native hub and agent, driven from a real PTY: the screen
# is painted on connect, keystrokes and resizes reach the child, and the detach
# key leaves the endpoint running. Loopback only; nothing deployed is touched.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v cargo >/dev/null 2>&1 || { echo 'skip: cargo is required'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 is required'; exit 0; }
command -v jq >/dev/null 2>&1 || { echo 'skip: jq is required'; exit 0; }
LAB=$(fm_test_tmproot fm-stream-attach-rust)
trap 'fm_test_reap_helper_pids; fm_test_cleanup' EXIT INT TERM
(cd "$ROOT" && cargo build --locked --quiet -p fm-stream-hub -p fm-stream-agent) || fail 'native build failed'
out=$(python3 "$ROOT/tests/assets/stream-attach-pty.py" "$ROOT" "${CARGO_TARGET_DIR:-$ROOT/target}/debug" "$LAB" 2>&1) \
  || fail "interactive attach: $out"
pass 'stream attach --interactive: paints the screen, forwards keystrokes and resizes, detaches without closing the endpoint'
