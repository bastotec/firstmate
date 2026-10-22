#!/usr/bin/env bash
# fm-worker-keepalive.sh - wake a worker's mate when the worker stops making progress.
#
# Usage: fm-worker-keepalive.sh scan          (bin/fm-watch.sh runs it detached)
#        fm-worker-keepalive.sh counts [<since-epoch>]
#
# bin/fm_worker_keepalive.py's docstring owns what counts as stuck, the wake's
# concrete instruction, when the mate acted, and the one plain escalation line.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
case "${1:-}" in
  scan|counts) exec python3 "$SCRIPT_DIR/fm_worker_keepalive.py" "$@" ;;
  -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" ;;
  *) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2; exit 2 ;;
esac
