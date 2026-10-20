#!/usr/bin/env bash
# Real Deck with a loopback scripted provider, no remote model or credentials.
# The binary is fingerprint-pinned; a new build needs an explicit new pin and
# refreshed verification evidence, not a silent version-string match.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_SPECIALIST_DECK_LIVE deck python3
LAB=$(fm_test_tmproot fm-specialist-deck-live)
python3 "$ROOT/tests/fm-specialist-deck-live.py" "$ROOT" "$LAB" "$(command -v deck)"
pass "pinned Deck stops queued and later calls after actual incomplete output"
