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
#   fm-specialist.sh job <name> --brief "<text>" | --brief-file <file> [--wait]
#   fm-specialist.sh status <name> [--json]
#   fm-specialist.sh history <name> [-n N] [--json]
#   fm-specialist.sh list [--all] [--json]
#   fm-specialist.sh retire <name>
#
# `job` starts one detached Deck turn and returns; when it ends the home gets a
# `check: specialist <name> finished job <job> (<outcome>) - result: <path>`
# wake. One job runs at a time per specialist. Skills placed in
# data/specialists/<name>/skills/ are linked into its workdir's .agents/skills/.
# Jobs produce knowledge, not project changes: hand a change
# a job recommends to a ship. Retire keeps the memory and Deck session.
set -eu
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd -P)
case "${1:-}" in
  create|job|status|history|list|retire) exec python3 "$SCRIPT_DIR/fm_crew.py" "$@" ;;
  -h|--help|'') awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; [ -n "${1:-}" ] ;;
  *) printf 'fm-specialist.sh: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
