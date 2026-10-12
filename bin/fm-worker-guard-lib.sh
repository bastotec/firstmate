#!/usr/bin/env bash
# fm-worker-guard-lib.sh - workers never raise captain-facing items.
#
# Sourced, not run. The captain's standing rule: a ship or scout worker never
# asks the captain for anything. Its decisions, questions, blockers, approval
# needs, and ask-user findings go to its parent mate through its status file
# (needs-decision / blocked); the mate decides within its authority or raises
# its own captain call in its own words.
#
# fm_worker_guard_refuse <state-dir> <action> refuses (exit 3) when the caller
# is a live worker of that home: FM_TASK_ID is set (bin/fm-spawn.sh marks every
# ship and scout pane with it; mates are never marked) and the home records that
# task at <state-dir>/<id>.meta. A marked shell acting on some other home, such
# as a test fixture home, is not that home's worker and passes.

fm_worker_guard_refuse() {  # <state-dir> <action>
  local state=$1 action=$2 id=${FM_TASK_ID:-}
  case "$id" in ''|*[!A-Za-z0-9._-]*|.|..) return 0 ;; esac
  [ -f "$state/$id.meta" ] || return 0
  printf 'refused: worker %s cannot %s; workers never raise captain-facing items.\n' "$id" "$action" >&2
  # shellcheck disable=SC2016 # literal backticks
  printf 'Append `needs-decision [key=<slug>]: <question and options>` (or `blocked:`) to your status file and stop; your mate decides or raises its own call.\n' >&2
  exit 3
}
