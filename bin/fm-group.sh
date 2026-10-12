#!/usr/bin/env bash
# fm-group.sh - ephemeral task groups: one parent fans out N short-lived members.
#
# Members share one brief and each covers its own angle (for example five
# adversarial reviewers on one PR). They investigate and report, never edit
# project files; put project paths and context in the shared brief.
# Each member is one ephemeral Deck run with no fleet task record.
# A detached orchestrator schedules members under the local concurrency cap
# owned by bin/fm_crew.py's runtime tuning documentation.
# When every member ends, a required merge run combines their results into
# data/groups/<gid>/report.md, keeping member evidence even if the merge fails.
# Success requires every member and the merger to succeed.
# Cleanup covers member process groups and the orchestrator with its merger;
# only proven-stopped run files and neutral workdirs are removed.
# A cleanup that cannot prove that requests a captain-held task with a decision
# card instead, retaining run files for inspection. The home gets one
# `check: task group <gid> <status> (<done>/<total> members) - report: <path>`
# wake. bin/fm_crew.py's docstring owns the record layout.
#
# Usage (FM_HOME must name the owning home):
#   fm-group.sh start <gid> --brief "<text>" | --brief-file <file>
#       --angle "<angle>"... | --angles-file <file> [--title T]
#       [--wait] [--wait-timeout <seconds>]
#   fm-group.sh status <gid> [--json]
#   fm-group.sh list [--json]
#   fm-group.sh cleanup <gid>      stop and remove the whole group now
#
# Group ids are single-use; records and completed results survive cleanup.
# Status and list are read-only; status's live_members includes "merger" when
# its process group is live or uncertain, alongside member keys.
# Cleanup cancels unfinished work and can be retried after cleanup-failed
# without changing the retained work outcome.
# --wait exits nonzero unless the group is done, or on timeout (default 7320
# seconds); a timeout does not cancel the group.
# bin/fm_crew.py's docstring owns runtime tuning and workdir placement;
# docs/configuration.md "Worker launch environment" owns environment grants.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
case "${1:-}" in
  start|status|list|cleanup)
    cmd=$1; shift
    exec python3 "$SCRIPT_DIR/fm_crew.py" "group-$cmd" "$@" ;;
  -h|--help|'') awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; [ -n "${1:-}" ] ;;
  *) printf 'fm-group.sh: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
