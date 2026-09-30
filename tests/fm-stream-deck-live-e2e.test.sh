#!/usr/bin/env bash
# Opt-in real Deck course correction through Bridge -> hub -> PTY agent ->
# native Deck safe point. No shared hub, endpoint, or supervisor home is used.
# FM_DECK_LIVE_BINARY selects a compatible executable without changing PATH.
# Gateway configuration is inherited by reference; Deck state stays in the lab.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_DECK_LIVE "${FM_DECK_LIVE_BINARY:-deck}" python3 jq
DECK_BIN=${FM_DECK_LIVE_BINARY:-$(command -v deck)}
"$DECK_BIN" run --help | grep -q -- '--steer-dir' || { echo "FAIL Deck lacks --steer-dir: $DECK_BIN"; exit 1; }
"$DECK_BIN" --version
LAB=$(fm_test_tmproot fm-stream-deck-live)
trap fm_test_cleanup EXIT
python3 "$ROOT/tests/fm-stream-deck-live-scenarios.py" "$ROOT" "$LAB" "$DECK_BIN"
