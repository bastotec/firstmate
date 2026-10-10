#!/usr/bin/env bash
# fm-tasks-axi.sh - run tasks-axi against THIS home's backlog from any working directory.
#
# Usage: fm-tasks-axi.sh [<tasks-axi command> [args...]]
#        fm-tasks-axi.sh --help
#
# Every routine firstmate backlog read or mutation goes through this command
# rather than a bare `tasks-axi`; `fm-tasks-axi.sh <command> --help` prints
# tasks-axi's own help. The optional leading `task` noun is stripped before
# selecting the command, including its done/close gate. Other arguments reach
# tasks-axi as given, apart from path rewriting that keeps file arguments
# meaning what the caller meant: a relative
# value of `--to` or any `--*-file` flag (`--body-file`, `--relation-file`, ...)
# is made absolute against the caller's working directory, because tasks-axi
# starts from the backlog root instead. `--report` stays as given: tasks-axi
# stores it verbatim as a link, which lifecycle transitions record relative to
# that same root.
#
# Why it exists: a bare `tasks-axi` resolves the tracked `.tasks.toml` paths
# against its working directory, so from the code root it forks the queue
# whenever the home lives elsewhere; docs/configuration.md ("Backlog backend")
# owns that rationale.
#
# Addressing is bin/fm-backlog-transition-lib.sh's fm_backlog_tasks_axi_addressing,
# the same resolution the lifecycle transitions use: tasks-axi runs from the
# configured data directory's parent, so that home's own `.tasks.toml` (or
# tasks-axi's built-in defaults, which keep the archive beside the backlog)
# supplies the adapter, done_keep, and the archive path; a markdown backlog is
# additionally pinned to `<data>/backlog.md` through TASKS_AXI_FILE. The
# environment carries the pin rather than a trailing --file so the no-command
# dashboard works too. A configured non-markdown adapter is addressed by that
# root alone, so an inherited TASKS_AXI_FILE is cleared for it.
#
# The data directory is FM_DATA_OVERRIDE, else $FM_HOME/data, else the code
# root's data/ (FM_HOME unset keeps the single-home layout unchanged).
#
# Refusals (exit 2, nothing run):
#   - tasks-axi missing from PATH;
#   - a caller-supplied --file, because this command owns the addressing and
#     tasks-axi would silently let the last --file win;
#   - a data directory that cannot be resolved, or whose backend configuration
#     cannot be read (bin/fm-tasks-axi-lib.sh owns that diagnostic);
#   - a markdown `<data>/backlog.md` that is itself a symlink, because the
#     first write would replace the link with a private copy, exactly the fork
#     this command exists to prevent. Lifecycle transitions refuse the same file.
#   - `done`/`close` when the row cannot be read, or a resolved PR's task body
#     cannot be decoded or bin/fm-pr-lib.sh's fm_pr_close_verdict refuses the
#     completion claim. The row lookup uses the last explicit --backend value,
#     if supplied, so it checks the same backend as the mutation.
#     PR resolution uses --pr first, else fm_pr_task_url (row link, then pr=
#     in ${FM_STATE_OVERRIDE:-$FM_HOME/state}/<id>.meta). A superseded verdict
#     requires dropping --pr. Confirmed NOT_FOUND passes through so tasks-axi
#     reports its own missing-task error.
# Otherwise the exit status is tasks-axi's own.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-tasks-axi: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or run tasks-axi directly for another backlog"
      ;;
    --to|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

if [ "${ARGS[0]:-}" = task ]; then
  ARGS=("${ARGS[@]:1}")
fi

command -v tasks-axi >/dev/null 2>&1 || fail "tasks-axi is not on PATH; run bin/fm-bootstrap.sh for the install command"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA"; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; a tasks-axi write would replace it with a regular file and fork the backlog - make it this home's real file"
  fi
  export TASKS_AXI_FILE="$FM_BACKLOG_AXI_FILE"
else
  unset TASKS_AXI_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"

# Refuse a close that would claim a PR merged when it has not.
done_pr_gate() {
  local id='' pr_flag='' previous='' arg row url body
  local -a backend_args
  backend_args=()
  for arg in "${ARGS[@]:1}"; do
    case "$previous" in
      --pr) pr_flag=$arg; previous=''; continue ;;
      --backend) backend_args=(--backend "$arg"); previous=''; continue ;;
      --report|--note|--keep) previous=''; continue ;;
    esac
    case "$arg" in
      --pr=*) pr_flag=${arg#--pr=} ;;
      --backend=*) backend_args=(--backend "${arg#--backend=}") ;;
      --pr|--report|--note|--keep|--backend) previous=$arg ;;
      -*) ;;
      *) [ -n "$id" ] || id=$arg ;;
    esac
  done
  [ -n "$id" ] || return 0
  if ! row=$(tasks-axi show "$id" --full ${backend_args[@]+"${backend_args[@]}"} 2>&1); then
    printf '%s\n' "$row" | grep -qx 'code: NOT_FOUND' && return 0
    fail "refusing to close $id: cannot read the task row"
  fi
  url=$pr_flag
  if [ -z "$url" ]; then
    url=$(fm_pr_task_url "$row" "${FM_STATE_OVERRIDE:-$FM_HOME/state}/$id.meta")
  fi
  [ -n "$url" ] || return 0
  body=$(fm_pr_task_body "$row") || fail "refusing to close $id: cannot decode the task body"
  if fm_pr_close_verdict "$url" "$body"; then
    [ "$FM_PR_CLOSE_VERDICT" = superseded ] && [ -n "$pr_flag" ] || return 0
    FM_PR_CLOSE_REFUSAL="$url closed without merging, and --pr would record it as merged; drop --pr"
  fi
  fail "refusing to close $id: $FM_PR_CLOSE_REFUSAL"
}
case "${ARGS[0]:-}" in
  done|close) done_pr_gate ;;
esac
exec tasks-axi ${ARGS[@]+"${ARGS[@]}"}
