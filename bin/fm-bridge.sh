#!/usr/bin/env bash
# fm-bridge.sh - which flows may cross the bridge between this machine and another.
#
# Usage: fm-bridge.sh show|check|allow|deny|set|block|audit ...
#
# Thin entry point; bin/fm-bridge.py's header owns the bridge record, flow
# definitions, seeding, audit log and refused-flow request contract.
# docs/configuration.md "Bridge gates" owns operator setup and UI boundaries.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$SCRIPT_DIR/fm-bridge.py" "$@"
