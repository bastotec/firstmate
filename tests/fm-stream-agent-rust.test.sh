#!/usr/bin/env bash
# Differential agent lifecycle guard. Every endpoint and hub is disposable,
# loopback-only, and credential-isolated; no installed harness is launched.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v cargo >/dev/null 2>&1 || { echo 'skip: cargo is required'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 is required'; exit 0; }
LAB=$(fm_test_tmproot fm-stream-agent-rust)
trap 'fm_test_reap_helper_pids; fm_test_cleanup' EXIT INT TERM
(cd "$ROOT" && cargo build --locked --quiet -p fm-stream-agent) || fail 'Rust agent build failed'
python3 "$ROOT/tests/assets/stream-agent-rust-parity.py" "$ROOT" "$LAB" \
  || fail 'Rust/Python agent lifecycle parity failed'
pass 'Rust/Python agents: PTY I/O, results, restart, capability isolation, contests, exits and shutdown parity'
