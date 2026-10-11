#!/usr/bin/env bash
# fm-pr-record-audit.sh - flag Done backlog rows whose recorded PR outcome is wrong.
#
# Usage: fm-pr-record-audit.sh [--migrate]
#        fm-pr-record-audit.sh --help
#
# Lists this home's Done rows (FM_HOME, through bin/fm-tasks-axi.sh's
# addressing), reads each one, and asks the forge for the live state of its PR
# with bin/fm-pr-lib.sh's fm_pr_live_state. The PR is the one on the row's
# `Outcome:` line (fm_pr_task_outcome), else its PR link, else metadata pr=.
# It prints one line per mismatch on stdout:
#   task <id> is recorded done but PR <url> is open - reconcile
#   task <id> is recorded done but PR <url> was closed without merging - reconcile
#   task <id> shows as merged but PR <url> was superseded - run with --migrate
#   task <id> records <outcome> but PR <url> <merged|is open|was closed without merging> - reconcile
#   task <id> records <outcome> but still shows as merged - run with --migrate
# Rows with no recorded outcome use bin/fm-pr-lib.sh's completion-claim gate,
# including its decoded-body supersession rule; merged rows stay silent.
# Without --migrate it is read-only. --migrate records the real outcome on rows
# closed before outcomes were recorded, through bin/fm-backlog-transition-lib.sh's
# fm_backlog_record_pr_outcome: merged, superseded (a "Superseded:" line), or
# closed-unmerged, and re-records a non-merged row that still shows as merged.
# It prints `task <id>: recorded <outcome> for PR <url>` per row it changes,
# never touches a row whose PR is open, and never changes a recorded outcome.
# Only the backlog is covered; rows already pruned to the archive keep their label.
# A PR whose state cannot be read prints
#   task <id>: cannot check PR <url> - reconcile by hand
# on stderr and makes the exit status 2, as does a failed row read or migration.
# Otherwise the exit status is 0 with or without mismatches, so the printed
# lines are the whole answer.
# The heartbeat finished-work sweep runs it (task-delivery skill).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

MIGRATE=0
case "${1:-}" in
  -h|--help)
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
    exit 0
    ;;
  --migrate) MIGRATE=1 ;;
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

migrate() {  # <id> <outcome> <url>
  if fm_backlog_record_pr_outcome "$DATA" "$1" "$2" "$3"; then
    printf 'task %s: recorded %s for PR %s\n' "$1" "$2" "$3"
  else
    printf 'task %s: cannot record %s for PR %s: %s\n' "$1" "$2" "$3" "$FM_BACKLOG_TRANSITION_ERROR" >&2
    status=2
  fi
}

while read -r id fields; do
  [ -n "$id" ] || continue
  if ! row=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" --full 2>/dev/null) \
      || ! body=$(fm_pr_task_body "$row" 2>/dev/null); then
    printf 'task %s: cannot read the row - reconcile by hand\n' "$id" >&2
    status=2
    continue
  fi
  linked=no
  case "$fields" in *pr:https://*) linked=yes ;; esac
  recorded=$(fm_pr_task_outcome "$body")
  if [ -n "$recorded" ]; then
    outcome=${recorded%% *}
    url=${recorded#* }
  else
    outcome=
    url=$(fm_pr_task_url "  links: $fields" "$STATE/$id.meta")
  fi
  [ -n "$url" ] || continue
  if ! state=$(fm_pr_live_state "$url"); then
    printf 'task %s: cannot check PR %s - reconcile by hand\n' "$id" "$url" >&2
    status=2
    continue
  fi
  if [ -n "$outcome" ]; then
    case "$outcome:$state" in
      merged:merged|superseded:closed|closed-unmerged:closed|closed-unmerged:open) ;;
      *:merged) printf 'task %s records %s but PR %s merged - reconcile\n' "$id" "$outcome" "$url"; continue ;;
      *:open) printf 'task %s records %s but PR %s is open - reconcile\n' "$id" "$outcome" "$url"; continue ;;
      *) printf 'task %s records %s but PR %s was closed without merging - reconcile\n' "$id" "$outcome" "$url"; continue ;;
    esac
    if [ "$outcome" != merged ] && [ "$linked" = yes ]; then
      if [ "$MIGRATE" = 1 ]; then
        migrate "$id" "$outcome" "$url"
      else
        printf 'task %s records %s but still shows as merged - run with --migrate\n' "$id" "$outcome"
      fi
    fi
    continue
  fi
  case "$state" in
    merged)
      [ "$MIGRATE" = 0 ] || migrate "$id" merged "$url"
      ;;
    open)
      printf 'task %s is recorded done but PR %s is open - reconcile\n' "$id" "$url"
      ;;
    closed)
      if fm_pr_superseded_recorded "$body"; then
        if [ "$MIGRATE" = 1 ]; then
          migrate "$id" superseded "$url"
        elif [ "$linked" = yes ]; then
          printf 'task %s shows as merged but PR %s was superseded - run with --migrate\n' "$id" "$url"
        fi
      elif [ "$MIGRATE" = 1 ]; then
        migrate "$id" closed-unmerged "$url"
      else
        printf 'task %s is recorded done but PR %s was closed without merging - reconcile\n' "$id" "$url"
      fi
      ;;
  esac
done < <(printf '%s\n' "$listing" \
  | sed -n 's/^  \([^,]*\),done,\(.*\)/\1 \2/p')
exit "$status"
