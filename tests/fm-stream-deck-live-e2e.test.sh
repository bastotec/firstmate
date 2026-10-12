#!/usr/bin/env bash
# Opt-in real Deck course correction through Bridge -> hub -> PTY agent ->
# native Deck safe point. No shared hub, endpoint, or supervisor home is used.
# FM_DECK_LIVE_BINARY selects a compatible executable without changing PATH.
# Gateway configuration is inherited by reference; Deck state stays in the lab.
# FM_STREAM_AGENT_LIVE_BINARY selects a separately built native agent for the
# same scenarios without installing it or changing shared services.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_DECK_LIVE "${FM_DECK_LIVE_BINARY:-deck}" python3 jq
DECK_BIN=${FM_DECK_LIVE_BINARY:-$(command -v deck)}
"$DECK_BIN" run --help | grep -q -- '--steer-dir' || { echo "FAIL Deck lacks --steer-dir: $DECK_BIN"; exit 1; }
"$DECK_BIN" --version
if [ -n "${FM_STREAM_AGENT_LIVE_BINARY:-}" ]; then
  command -v "$FM_STREAM_AGENT_LIVE_BINARY" >/dev/null 2>&1 || { echo "FAIL native stream agent absent: $FM_STREAM_AGENT_LIVE_BINARY"; exit 1; }
  "$FM_STREAM_AGENT_LIVE_BINARY" --version
fi
LAB=$(fm_test_tmproot fm-stream-deck-live)
trap fm_test_cleanup EXIT
python3 "$ROOT/tests/fm-stream-deck-live-scenarios.py" "$ROOT" "$LAB" "$DECK_BIN"
