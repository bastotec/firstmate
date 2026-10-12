#!/usr/bin/env bash
# fm-group.sh - ephemeral task groups: one parent fans out N short-lived members.
#
# Members share one brief and each covers its own angle (for example five
# adversarial reviewers on one PR). Each member is one ephemeral Deck run with
# no fleet task record. A detached orchestrator runs at most two
# members on this machine at once. When every member
# ends, one more run merges their results into data/groups/<gid>/report.md, and
# the group is cleaned up in the same step: every member process is stopped and
# proven gone and the run files are removed. A cleanup that cannot prove that
# raises a captain-held task with a decision card instead. The home gets one
# `check: task group <gid> <status> (<done>/<total> members) - report: <path>`
# wake. bin/fm_crew.py's docstring owns the record layout.
#
# Usage (FM_HOME must name the owning home):
#   fm-group.sh start <gid> --brief "<text>" | --brief-file <file>
#       --angle "<angle>"... | --angles-file <file> [--title T]
#       [--wait]
#   fm-group.sh status <gid> [--json]
#   fm-group.sh list [--json]
#   fm-group.sh cleanup <gid>      stop and remove the whole group now
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
case "${1:-}" in
  start|status|list|cleanup)
    cmd=$1; shift
    exec python3 "$SCRIPT_DIR/fm_crew.py" "group-$cmd" "$@" ;;
  -h|--help|'') awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; [ -n "${1:-}" ] ;;
  *) printf 'fm-group.sh: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
