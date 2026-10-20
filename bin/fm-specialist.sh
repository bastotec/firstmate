#!/usr/bin/env bash
# fm-specialist.sh - persistent specialists owned by one home.
#
# A specialist is a named worker for recurring subject matter (one customer, a
# subsystem, an integration). It keeps one Deck session that every job resumes,
# its own memory file it reads at job start and must update before a job may
# finish, optional own skills, and its own job history. No process runs between
# jobs; an idle specialist is a record under state/specialists/, not a leak.
# bin/fm_crew.py's docstring owns the record layout.
#
# Usage (FM_HOME must name the owning home):
#   fm-specialist.sh create <name> --subject "<subject>" [--project <p>]...
#   fm-specialist.sh job <name> --brief "<text>" | --brief-file <file>
#       [--wait] [--wait-timeout <seconds>]
#   fm-specialist.sh status <name> [--json]
#   fm-specialist.sh history <name> [-n N] [--json]
#   fm-specialist.sh list [--all] [--json]
#   fm-specialist.sh retire <name>
#   fm-specialist.sh suspend <name> --reason "<plain reason>" [--since <UTC like 2026-10-17T10:40:02Z>] [--by <who>]
#   fm-specialist.sh resume <name> [--by <who>]
#
# `job` starts one detached Deck turn and returns; when it ends the home gets a
# `check: specialist <name> finished job <job> (<outcome>) - result: <path>`
# wake, using `none written` when no result file exists.
# One job runs at a time per specialist. Skills placed in
# data/specialists/<name>/skills/ are linked into its workdir's .agents/skills/.
# Jobs produce knowledge, not project changes: hand a change
# a job recommends to a ship. Retire refuses a running job and keeps its record,
# memory, history, and Deck session while removing its neutral workdir.
# Suspend marks an idle specialist "suspended" with its reason, since and by in
# the record (a running job must end first); job then refuses with exit 4 until
# resume returns it to idle and keeps the ended suspension as last_suspension.
# A scheduler that dispatches a specialist relies on that refusal to skip runs.
# Status, history, list, job, and retire reconcile interrupted runners using
# bin/fm_crew.py's liveness rules and emit completion wakes; they are not read-only.
# --wait exits nonzero on failure or timeout (default 3660 seconds); a timeout
# does not cancel the job. Inspect it with status before submitting another.
# bin/fm_crew.py's docstring owns runtime tuning and workdir placement;
# docs/configuration.md "Worker launch environment" owns environment grants.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
case "${1:-}" in
  create|job|status|history|list|retire|suspend|resume) exec python3 "$SCRIPT_DIR/fm_crew.py" "$@" ;;
  -h|--help|'') awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; [ -n "${1:-}" ] ;;
  *) printf 'fm-specialist.sh: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
