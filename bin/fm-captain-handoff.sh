#!/usr/bin/env bash
# fm-captain-handoff.sh - a conversation hands a party's order or question
# to its own supervisor (split homes, config/primary-split).
#
# Usage: fm-captain-handoff.sh [--from <party>] <text...>
#        fm-captain-handoff.sh --help
#
# Every hand-off names who it came from, as "From <party>: <text>", because only
# the captain's own words carry his approval (a merge, anything destructive).
# The party is the conversation turn's sender: FM_CONVERSATION_PARTY, which a
# second mate's conversation lane sets for each turn from the record's delivery
# tags, else --from (captain, firstmate or mate:<id>), else "an unstated sender",
# which the supervisor never takes as his approval.
#
# The first mate's captain thread publishes into the supervisor host through
# `bin/fm-send.sh supervisor`. A split second mate's captain thread runs inside
# its home host (bin/fm-deck-worker.sh, captain lane), which exports
# FM_CAPTAIN_LANE_STATE and FM_CAPTAIN_LANE_ID: the text then becomes one
# "[fm-captain-thread]" record in that host's steering inbox, which reaches the
# supervisor's running turn at its next safe point or wakes it when idle
# (bin/fm_stream_deck.py).
#
# A second mate's hand-off then prints the supervisor's real state:
# "supervisor=failing count=<n> since=<utc> error=<text>" while its turns keep
# failing, else "supervisor=<busy|idle>".
#
# Exit: mate lane 0 recorded, 1 write failed, 2 no text; else fm-send's status.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  -h|--help) sed -n '2,27p' "$0"; exit 0 ;;
  '') echo "error: fm-captain-handoff.sh needs the text to hand over" >&2; exit 2 ;;
esac
party=''
if [ "$1" = --from ]; then
  party=${2:-}
  shift 2 2>/dev/null || { echo "error: --from needs a party" >&2; exit 2; }
fi
[ -z "${FM_CONVERSATION_PARTY:-}" ] || party=$FM_CONVERSATION_PARTY
case "$party" in
  captain) said='the captain' ;;
  firstmate) said='the first mate' ;;
  mate:*) case "${party#mate:}" in ''|*[!A-Za-z0-9._-]*) said='an unstated sender' ;; *) said="the mate ${party#mate:}" ;; esac ;;
  *) said='an unstated sender' ;;
esac
[ -n "$*" ] || { echo "error: fm-captain-handoff.sh needs the text to hand over" >&2; exit 2; }
set -- "From $said: $*"
if [ -n "${FM_CAPTAIN_LANE_STATE:-}" ] && [ -n "${FM_CAPTAIN_LANE_ID:-}" ]; then
  # shellcheck source=bin/fm-operational-input.sh
  . "$SCRIPT_DIR/fm-operational-input.sh"
  # shellcheck source=bin/fm-task-inbox-lib.sh
  . "$SCRIPT_DIR/fm-task-inbox-lib.sh"
  rec=$(FM_TASK_INBOX_STREAM=monologue fm_task_inbox_write "$FM_CAPTAIN_LANE_STATE" "$FM_CAPTAIN_LANE_ID" "${FM_CAPTAIN_THREAD_MARK}$*") || {
    echo "error: the hand-over could not be recorded in $FM_CAPTAIN_LANE_STATE/$FM_CAPTAIN_LANE_ID.inbox" >&2
    exit 1
  }
  # Reach a running supervisor turn at its next safe point now, best-effort; an
  # idle supervisor wakes on the record anyway (bin/fm_stream_deck.py).
  python3 "$SCRIPT_DIR/fm_stream_deck.py" captain "$FM_CAPTAIN_LANE_STATE" "$FM_CAPTAIN_LANE_ID" >/dev/null 2>&1 || true
  printf 'handed-over=%s\n' "$rec"
  # The supervisor's real state, so the conversation never says "queued" when
  # it is failing (bin/fm-deck-worker.sh "SUPERVISOR HEALTH").
  health="$FM_CAPTAIN_LANE_STATE/$FM_CAPTAIN_LANE_ID.supervisor-failing"
  if [ -f "$health" ]; then
    printf 'supervisor=failing count=%s since=%s error=%s\n' "$(sed -n 's/^count=//p' "$health")" \
      "$(sed -n 's/^since=//p' "$health")" "$(sed -n 's/^error=//p' "$health")"
  else
    printf 'supervisor=%s\n' "$(sed -n 's/.* state=\([a-z]*\).*/\1/p' "$FM_CAPTAIN_LANE_STATE/$FM_CAPTAIN_LANE_ID.busy-state" 2>/dev/null || true)"
  fi
  exit 0
fi
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=$FM_HOME exec "$SCRIPT_DIR/fm-send.sh" supervisor "$*"
