#!/usr/bin/env bash
# fm-primary-steer.sh - publish to and read the steering inbox of a `deck chat`
# primary hosted by bin/fm-deck-chat.sh. The inbox is deck's --steer-dir
# (~/Projects/deck docs/steering.md); bin/fm_primary_chat.py owns the layout.
#
# Usage (every subcommand takes --home H; default FM_HOME, else this checkout):
#   fm-primary-steer.sh publish (--text TEXT | --file F) [--kind wake|away|captain|other]
#       Atomically publish the next <seq>.msg (tmp name + rename, strictly
#       increasing per session under a lock). Prints seq=<n>.
#       Exit 0 published; 2 refused (blank, over 65536 bytes, unreadable file);
#       3 no live deck-chat primary registered - the caller falls back.
#   fm-primary-steer.sh status
#       One JSON line: present, state (idle|busy|stopped|unknown, from the tail
#       of the events file), last_event, last_event_at, acked_seq,
#       published_seq, pending, endpoint. Exit 3 when no live primary.
#   fm-primary-steer.sh delivered <seq>
#       Exit 0 delivered (steer_acked >= seq or handled/<seq>.msg); 1 pending;
#       2 rejected (rejected/<seq>.msg or steer_rejected); 3 no live primary.
# Callers that shell out to this script honor FM_PRIMARY_STEER_BIN, so tests
# can substitute it.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  publish|status|delivered) exec python3 "$SCRIPT_DIR/fm_primary_chat.py" steer "$@" ;;
  -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
  *) echo "usage: fm-primary-steer.sh publish|status|delivered [--home H] ..." >&2; exit 2 ;;
esac
