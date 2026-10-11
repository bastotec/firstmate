#!/usr/bin/env bash
# fm-crew-state.sh - adapter for the owned current-task-state derivation.
# Usage: fm-crew-state.sh [--publish|--follow|--follow-detached] <id>
# bin/fm-task-state-lib.sh owns precedence, attributed evidence and publication.
# Exit 0 on a successful read (including unknown), 2 on usage error, or 1
# when publication cannot acquire its lock.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-task-state-lib.sh
. "$SCRIPT_DIR/fm-task-state-lib.sh"
MODE='read'
case "${1:-}" in
  --publish) MODE=publish; shift ;;
  --follow) MODE=follow; shift ;;
  --follow-detached) MODE=follow-detached; shift ;;
esac
ID=${1:-}
[ -n "$ID" ] || { echo "usage: fm-crew-state.sh [--publish|--follow|--follow-detached] <id>" >&2; exit 2; }
if [ "$MODE" != read ]; then
  case "$ID" in
    .*|*[!A-Za-z0-9._-]*) echo "fm-crew-state.sh: unsafe task id for a published record: $ID" >&2; exit 2 ;;
  esac
fi
fm_task_state_read "$ID" "$MODE"
