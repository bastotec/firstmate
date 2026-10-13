#!/usr/bin/env bash
# fm-approval.sh - per-machine approval gates for risky agent tool calls.
#
# Usage: see bin/fm-approval.py's header (also printed with no arguments).
#
# Thin entry point; bin/fm-approval.py's header owns the whole contract: the
# machine-local policy at ~/.agents/approvals.json, the Deck pre_tool_use hook
# (`gate`) that blocks matching calls and files a request in the owning home's
# state/approvals/, and `answer` for tool-call and bridge-flow requests.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
if [ "${1:-}" = escalate ] && [ -n "${FM_HOME:-}" ]; then
  # shellcheck source=bin/fm-worker-guard-lib.sh
  . "$SCRIPT_DIR/fm-worker-guard-lib.sh"
  fm_worker_guard_refuse "$FM_HOME/state" 'escalate an approval request'
fi
exec python3 "$SCRIPT_DIR/fm-approval.py" "$@"
