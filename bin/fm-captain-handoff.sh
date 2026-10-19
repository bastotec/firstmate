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
# A second mate's hand-off prints supervisor=failing count=<n> since=<utc> told=<yes|no> error=<text>
# while its health record exists; told=yes means the keyed parent blocker was published, not order pickup.
# Otherwise it prints supervisor=<busy|idle> (empty if no busy record exists).
#
# After durable enqueue, native publication has a two-second best-effort budget;
# timeout leaves the source for the existing driver fallback, not a resend.
# Phase timings go to stderr without source paths, identities or message text.
# Exit: mate lane 0 recorded, 1 write failed, 2 no text; else fm-send's status.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
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
  enqueue_started=$(python3 -c 'import time; print(time.monotonic())')
  rec=$(FM_TASK_INBOX_STREAM=monologue fm_task_inbox_write "$FM_CAPTAIN_LANE_STATE" "$FM_CAPTAIN_LANE_ID" "${FM_CAPTAIN_THREAD_MARK}$*") || {
    echo "error: the hand-over could not be recorded in $FM_CAPTAIN_LANE_STATE/$FM_CAPTAIN_LANE_ID.inbox" >&2
    exit 1
  }
  # Enqueue is already success. Bound the whole optional child, including its
  # lifecycle lock and history scan; subprocess.run kills and reaps on expiry.
  python3 - "$SCRIPT_DIR/fm_stream_deck.py" "$FM_CAPTAIN_LANE_STATE" "$FM_CAPTAIN_LANE_ID" "$enqueue_started" <<'PY' || true
import subprocess
import sys
import time

started = time.monotonic()
print('handoff enqueue elapsed_ms=%.1f' % ((started - float(sys.argv[4])) * 1000), file=sys.stderr, flush=True)
try:
    result = subprocess.run([sys.executable, sys.argv[1], 'captain', sys.argv[2], sys.argv[3], '--timings'],
                            stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=2)
    diagnostic = result.stderr
    outcome = 'completed' if result.returncode == 0 else 'failed'
except subprocess.TimeoutExpired as error:
    diagnostic = error.stderr or b''
    outcome = 'timeout'
# Forward only phase diagnostics, not exception traces containing private paths.
for line in diagnostic.decode('utf-8', errors='replace').splitlines():
    if line.startswith(('handoff lifecycle-lock ', 'handoff projection ')):
        print(line, file=sys.stderr, flush=True)
print('handoff native-publication outcome=%s elapsed_ms=%.1f' % (outcome, (time.monotonic() - started) * 1000),
      file=sys.stderr, flush=True)
PY
  printf 'handed-over=%s\n' "$rec"
  # The supervisor's real state, so the conversation never says "queued" when
  # it is failing (bin/fm-deck-worker.sh "SUPERVISOR HEALTH").
  health="$FM_CAPTAIN_LANE_STATE/$FM_CAPTAIN_LANE_ID.supervisor-failing"
  if [ -f "$health" ]; then
    told=no
    [ "$(sed -n 's/^escalated=//p' "$health")" != 1 ] || told=yes
    printf 'supervisor=failing count=%s since=%s told=%s error=%s\n' "$(sed -n 's/^count=//p' "$health")" \
      "$(sed -n 's/^since=//p' "$health")" "$told" "$(sed -n 's/^error=//p' "$health")"
  else
    printf 'supervisor=%s\n' "$(sed -n 's/.* state=\([a-z]*\).*/\1/p' "$FM_CAPTAIN_LANE_STATE/$FM_CAPTAIN_LANE_ID.busy-state" 2>/dev/null || true)"
  fi
  exit 0
fi
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
FM_HOME=$FM_HOME exec "$SCRIPT_DIR/fm-send.sh" supervisor "$*"
