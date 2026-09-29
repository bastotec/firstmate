#!/usr/bin/env bash
# Differential compatibility of isolated Rust/Python hubs and deployed peers.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
command -v cargo >/dev/null 2>&1 || { echo 'skip: cargo not found'; exit 0; }
command -v python3 >/dev/null 2>&1 || { echo 'skip: python3 not found'; exit 0; }
cargo build --manifest-path "$ROOT/Cargo.toml" -p fm-stream-hub --locked
python3 "$ROOT/tests/assets/stream-hub-differential.py" "$ROOT/target/debug/fm-stream-hub"
pass 'Rust hub: HTTP, stream, order and Python peer compatibility'
