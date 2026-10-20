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
#   fm-specialist.sh ask <name> --from-captain [--wait] [--wait-timeout <s>] [--mate <id>] -- <text>
#   fm-specialist.sh result <name> [<job>] [--mate <id>]
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
# `ask --from-captain` is the captain's direct route to a specialist: one job on
# its persistent session whose brief carries his words, marks the job "from":
# "captain" in its record and history, keeps the specialist's bounds (knowledge
# only; a read-only monitor stays read-only), and at start queues a `check:`
# wake telling the owning home what he asked. Its result is read with `result`,
# which prints a job's result.md (default: the last finished job; exit 1 when
# none was written, 3 while that job is still running).
# A captain job keeps his exact words in its job directory's message.md and as
# "message" on its history line and last_job.
# `--mate <id>` on ask, result, status and history runs the command in that second
# mate's home from the primary home: a local mate through its recorded home=,
# a remote one through bin/fm-on.sh (where --text-file is refused).
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
# Strip `--mate <id>` and run the command in that mate's home instead.
route_to_mate() {  # <command> <args...>
  local cmd=$1 mate='' arg meta home
  local -a rest=()
  shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --) rest+=("$@"); break ;;
      --mate) [ $# -ge 2 ] || { echo "fm-specialist.sh: --mate needs a second mate id" >&2; exit 2; }; mate=$2; shift 2 ;;
      --mate=*) mate=${1#--mate=}; shift ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  if [ -z "$mate" ] || [ "$mate" = primary ]; then
    exec python3 "$SCRIPT_DIR/fm_crew.py" "$cmd" ${rest[@]+"${rest[@]}"}
  fi
  case "$mate" in *[!A-Za-z0-9._-]*) echo "fm-specialist.sh: invalid second mate id: $mate" >&2; exit 2 ;; esac
  [ -n "${FM_HOME:-}" ] || { echo "fm-specialist.sh: FM_HOME must name the primary home for --mate" >&2; exit 2; }
  meta="${FM_STATE_OVERRIDE:-$FM_HOME/state}/$mate.meta"
  grep -qx 'kind=secondmate' "$meta" 2>/dev/null || { echo "fm-specialist.sh: $mate is not a second mate of this home" >&2; exit 2; }
  if grep -q '^remote_host=.' "$meta"; then
    for arg in ${rest[@]+"${rest[@]}"}; do
      case "$arg" in --text-file|--text-file=*) echo "fm-specialist.sh: --text-file cannot reach a remote mate; pass the text" >&2; exit 2 ;; esac
    done
    exec "$SCRIPT_DIR/fm-on.sh" "$mate" fm-specialist.sh "$cmd" ${rest[@]+"${rest[@]}"}
  fi
  home=$(sed -n 's/^home=//p' "$meta" | tail -1)
  [ -n "$home" ] && [ -d "$home" ] || { echo "fm-specialist.sh: $mate has no readable home" >&2; exit 2; }
  exec env -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE FM_HOME="$home" \
    python3 "$SCRIPT_DIR/fm_crew.py" "$cmd" ${rest[@]+"${rest[@]}"}
}

case "${1:-}" in
  ask|result|status|history) route_to_mate "$@" ;;
  create|job|list|retire|suspend|resume) exec python3 "$SCRIPT_DIR/fm_crew.py" "$@" ;;
  -h|--help|'') awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; [ -n "${1:-}" ] ;;
  *) printf 'fm-specialist.sh: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
