#!/usr/bin/env bash
# Attach geometry, detach backpressure, resize and writer interleave regressions.
# Real disposable executables, loopback HTTP and local sockets; no live services.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v cargo >/dev/null 2>&1 || { echo 'skip: cargo is required'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 is required'; exit 0; }
LAB=$(fm_test_tmproot fm-stream-attach-boundaries)
trap 'fm_test_reap_helper_pids; fm_test_cleanup' EXIT INT TERM
(cd "$ROOT" && cargo build --locked --quiet -p fm-stream-hub -p fm-stream-agent) || fail 'native build failed'
python3 "$ROOT/tests/assets/stream-attach-boundaries.py" "$ROOT" "${CARGO_TARGET_DIR:-$ROOT/target}/debug" "$LAB" \
  || fail 'attach boundary regressions failed'
pass 'attach geometry, detach backpressure, resize and writer interleave'
