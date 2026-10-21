#!/usr/bin/env bash
# fm-ci-stall.sh - re-trigger stalled CI on this home's worker PRs, then diagnose.
#
# Usage: fm-ci-stall.sh scan          (bin/fm-watch.sh runs it detached)
#        fm-ci-stall.sh counts [<since-epoch>]
#
# bin/fm_ci_stall.py's docstring owns what is stuck, the single re-trigger, the
# diagnosis and hand-off, and the events file fleet dreaming counts.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
case "${1:-}" in
  scan|counts) exec python3 "$SCRIPT_DIR/fm_ci_stall.py" "$@" ;;
  -h|--help) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" ;;
  *) awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0" >&2; exit 2 ;;
esac
