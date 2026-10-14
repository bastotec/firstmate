#!/usr/bin/env bash
# fm-captain-handoff.sh - a captain thread hands the captain's order or question
# to its own supervisor (split homes, config/primary-split).
#
# Usage: fm-captain-handoff.sh <text...>
#        fm-captain-handoff.sh --help
#
# The first mate's captain thread publishes into the supervisor host through
# `bin/fm-send.sh supervisor`. A split second mate's captain thread runs inside
# its home host (bin/fm-deck-worker.sh, captain lane), which exports
# FM_CAPTAIN_LANE_STATE and FM_CAPTAIN_LANE_ID: the text then becomes one
# "[fm-captain-thread]" record in that host's steering inbox, which reaches the
# supervisor's running turn at its next safe point or wakes it when idle
# (bin/fm_stream_deck.py).
#
# Exit: 0 handed over; 2 no text; 1 the record or publication failed.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
  '') echo "error: fm-captain-handoff.sh needs the text to hand over" >&2; exit 2 ;;
esac
if [ -n "${FM_CAPTAIN_LANE_STATE:-}" ] && [ -n "${FM_CAPTAIN_LANE_ID:-}" ]; then
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
  rec=$(fm_task_inbox_write "$FM_CAPTAIN_LANE_STATE" "$FM_CAPTAIN_LANE_ID" "${FM_CAPTAIN_THREAD_MARK}$*") || {
    echo "error: the hand-over could not be recorded in $FM_CAPTAIN_LANE_STATE/$FM_CAPTAIN_LANE_ID.inbox" >&2
    exit 1
  }
  printf 'handed-over=%s\n' "$rec"
  exit 0
fi
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=$FM_HOME exec "$SCRIPT_DIR/fm-send.sh" supervisor "$*"
