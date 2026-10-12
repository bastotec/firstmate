#!/usr/bin/env bash
# fm-approval.sh - per-machine approval gates for risky agent tool calls.
#
# Usage: see bin/fm-approval.py's header (also printed with no arguments).
#
# Thin entry point; bin/fm-approval.py's header owns the whole contract: the
# machine-local policy at ~/.agents/approvals.json, the Deck pre_tool_use hook
# (`gate`) that blocks matching calls and files a request in the owning home's
# state/approvals/, and the captain's one-time, exact-match `answer`.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
exec python3 "$SCRIPT_DIR/fm-approval.py" "$@"
