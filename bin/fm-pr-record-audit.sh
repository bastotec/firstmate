#!/usr/bin/env bash
# fm-pr-record-audit.sh - flag Done backlog rows whose recorded PR has not merged.
#
# Usage: fm-pr-record-audit.sh
#        fm-pr-record-audit.sh --help
#
# Read-only. Lists this home's Done rows (FM_HOME, through bin/fm-tasks-axi.sh's
# addressing) with a PR link or metadata pr= and asks the forge for each PR's live state
# with bin/fm-pr-lib.sh's fm_pr_live_state. It prints one line per mismatch on
# stdout and never rewrites a record; the owning mate reconciles it:
#   task <id> is recorded done but PR <url> is open - reconcile
#   task <id> is recorded done but PR <url> was closed without merging - reconcile
# A closed, unmerged PR is not flagged when the row records
# "Superseded: <reason>", the same rule bin/fm-teardown.sh closes by.
# A PR whose state cannot be read prints
#   task <id>: cannot check PR <url> - reconcile by hand
# on stderr and makes the exit status 2. Otherwise the exit status is 0 with or
# without mismatches, so the printed lines are the whole answer.
# The heartbeat finished-work sweep runs it (task-delivery skill).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

case "${1:-}" in
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  '') ;;
  *)
    printf 'fm-pr-record-audit: unexpected argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

if ! listing=$("$SCRIPT_DIR/fm-tasks-axi.sh" list --state "done" --fields links --limit 100000 2>&1); then
  printf 'fm-pr-record-audit: cannot list Done rows: %s\n' "$(printf '%s\n' "$listing" | head -1)" >&2
  exit 2
fi

status=0
while read -r id fields; do
  [ -n "$id" ] || continue
  url=$(fm_pr_task_url "  links: $fields" "$STATE/$id.meta")
  [ -n "$url" ] || continue
  if ! state=$(fm_pr_live_state "$url"); then
    printf 'task %s: cannot check PR %s - reconcile by hand\n' "$id" "$url" >&2
    status=2
    continue
  fi
  case "$state" in
    open)
      printf 'task %s is recorded done but PR %s is open - reconcile\n' "$id" "$url"
      ;;
    closed)
      row=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" --full 2>/dev/null) || row=
      body=$(fm_pr_task_body "$row" 2>/dev/null) || body=
      fm_pr_superseded_recorded "$body" \
        || printf 'task %s is recorded done but PR %s was closed without merging - reconcile\n' "$id" "$url"
      ;;
  esac
done < <(printf '%s\n' "$listing" \
  | sed -n 's/^  \([^,]*\),done,\(.*\)/\1 \2/p')
exit "$status"
