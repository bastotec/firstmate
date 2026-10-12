#!/usr/bin/env bash
# fm-bridge.sh - which flows may cross the bridge between this machine and another.
#
# Usage: fm-bridge.sh show|check|allow|deny|set|block|audit ...
#
# Thin entry point; bin/fm-bridge.py's header owns the whole contract: the bridge
# record (config/bridges.json, seeded from today's routes on first use, deny by
# default for machines connected later), the six flows, the audit log
# (state/bridges.log) and the refused-flow request bin/fm-on.sh files.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$SCRIPT_DIR/fm-bridge.py" "$@"
