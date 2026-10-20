#!/usr/bin/env bash
# fm-specialist.sh - persistent specialists owned by one home.
#
# A specialist is a named worker for recurring subject matter (one customer, a
# subsystem, an integration). It keeps one Deck session that every job resumes,
# its own memory file it reads at job start and normally must update before a job
# may finish (see the stop-on-tool-failure exception below), optional own skills,
# and its own job history. No process runs between
# jobs; an idle specialist is a record under state/specialists/, not a leak.
# bin/fm_crew.py's docstring owns the record layout.
#
# Usage (FM_HOME must name the owning home):
#   fm-specialist.sh create <name> --subject "<subject>" [--project <p>]...
#   fm-specialist.sh job <name> --brief "<text>" | --brief-file <file>
#       [--wait] [--wait-timeout <seconds>]
#   fm-specialist.sh status <name> [--json] [--mate <id>]
#   fm-specialist.sh history <name> [-n N] [--json] [--mate <id>]
#   fm-specialist.sh list [--all] [--json]
#   fm-specialist.sh retire <name>
#   fm-specialist.sh ask <name> --from-captain [--wait] [--wait-timeout <s>] [--mate <id>]
#       -- <text> | --text-file <file>
#   fm-specialist.sh result <name> [<job>] [--mate <id>]
#   fm-specialist.sh suspend <name> --reason "<plain reason>" [--since <UTC like 2026-10-17T10:40:02Z>] [--by <who>]
#   fm-specialist.sh resume <name> [--by <who>]
#   fm-specialist.sh configure <name> --stop-on-tool-failure on|off
#   fm-specialist.sh model <name> <route|default>
#   fm-specialist.sh stop <name>
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
# its persistent session whose brief carries his words and reminds it of its
# standing bounds (a read-only monitor stays read-only). The owning home gets a
# `check:` wake with his message excerpt before the runner starts, followed by
# the usual completion wake. Without --from-captain or with an empty message,
# ask refuses with exit 2. --text-file reads the message instead of the text tail.
# Record fields and exact-message retention are owned by bin/fm_crew.py's docstring.
# `result` prints a job's result.md (default: the last finished job; exit 1 when
# none was written, 3 while the explicitly selected job is still running).
# `--mate <id>` on ask, result, status and history runs the command in that second
# mate's home from the primary home: a local mate through its recorded home=,
# a remote one through bin/fm-on.sh (where --text-file and --wait are refused;
# poll status/result instead). Omit --mate or use --mate primary for the current home.
# A specialist is a persistent worker that specializes in one subject; it
# differs from other workers only in persisting between jobs, so finished-work
# cleanup never retires it. `model` sets the Deck model route its next jobs run
# on (default clears it, so the session keeps its own model). status --json and
# list --json add the worker-shaped fields a feed reads: persistent, harness
# (deck), model (the chosen route or the session's last model), model_choice,
# effort, and on a running job current_job.events (its live Deck event stream)
# and current_job.last_activity (that stream's last write, epoch seconds).
# `stop` ends the running job (TERM, then KILL after 10 seconds); it is recorded
# as interrupted. Its worker id is spec-<name>: bin/fm-send.sh spec-<name> starts
# a job (a captain one with --from-captain), and bin/fm-control.sh spec-<name>
# model|interrupt|relaunch|recover-missing switch its model, stop its job, or,
# since it has no process between jobs, succeed with nothing to restart.
# `configure --stop-on-tool-failure on` opts later jobs into stopping at the first
# failed tool call; `off` (the default) restores normal behavior. Configure before
# launching a job; it does not change a Deck run already in progress and refuses
# retired specialists with exit 3. Failure means a run_command result with a
# non-zero or null exit_code or timed_out true, or any tool's output starting with
# "the tool failed". Every non-zero exit counts, even grep finding no match;
# exit-code/timeout JSON read by another tool is not command failure metadata.
# Guarded jobs serialize tool calls; Deck hooks record the first failure and
# refuse every further tool call, asking the model to reply briefly and finish.
# The stopped job may finish without its usual result and memory checks;
# firstmate writes a result naming the failed call when the specialist wrote
# none, and records the job as failed with the stop note described in
# bin/fm_crew.py's record layout. Use it for read-only monitors that must not
# continue past a failure; clean jobs still require a result and memory update.
# Suspend marks a specialist "suspended" with a plain reason and start time;
# retired specialists and running jobs are refused with exit 3. An empty reason
# or malformed --since (including an empty value) is refused with exit 2.
# Omit --since to use now, or supply its real UTC start to backfill a suspension.
# --by defaults to firstmate for both suspend and resume.
# While suspended, job and ask refuse with exit 4 naming the start and reason;
# a scheduler dispatching through job relies on that refusal to skip runs.
# Resume returns a suspended specialist to idle and retains the ended suspension;
# it refuses any other state with exit 3. Retired or running specialists also
# refuse job and ask with exit 3.
# Status, history, list, job, ask, result, suspend, resume, configure, and retire reconcile
# interrupted runners using bin/fm_crew.py's liveness rules and emit completion
# wakes; they are not read-only.
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
  # shellcheck source=bin/fm-gate-refuse-lib.sh
  . "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
  fm_refuse_if_gate_agent
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
      case "$arg" in
        --) break ;;
        --text-file|--text-file=*) echo "fm-specialist.sh: --text-file cannot reach a remote mate; pass the text" >&2; exit 2 ;;
        --wait) echo "fm-specialist.sh: --wait is unavailable for a remote mate; poll status/result instead" >&2; exit 2 ;;
      esac
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
  create|job|list|retire|suspend|resume|configure|model|stop) exec python3 "$SCRIPT_DIR/fm_crew.py" "$@" ;;
  -h|--help|'') awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$0"; [ -n "${1:-}" ] ;;
  *) printf 'fm-specialist.sh: unknown command: %s\n' "$1" >&2; exit 2 ;;
esac
