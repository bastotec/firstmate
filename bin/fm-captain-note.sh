#!/usr/bin/env bash
# fm-captain-note.sh - the supervisor's way to reach the captain in a split
# primary home (config/primary-split).
#
# Usage: fm-captain-note.sh <text...>
#        fm-captain-note.sh --help
#
# In split mode the supervisor's own chat reaches no one: the captain talks to
# the captain thread. This publishes "[fm-supervisor-note] <text>" into the
# captain thread's steering inbox (bin/fm-primary-steer.sh, role captain), and
# the thread relays it to the captain in its own words
# (.agents/skills/captain-thread/SKILL.md). Write the note for the captain:
# the outcome, its evidence and any decision he owns, as you would say it to him.
#
# Outside split mode there is no captain thread, so it refuses (exit 2): say it
# in your own reply instead.
#
# Exit: 0 published (prints seq= and session=); 2 not split mode or no text;
# 3 no live captain thread (the note was not sent; raise a card instead).
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
case "${1:-}" in
  -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
  '') echo "error: fm-captain-note.sh needs the note text" >&2; exit 2 ;;
esac
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
if [ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/primary-split" ]; then
  echo "error: this home is not split (no config/primary-split); say it to the captain in your own reply" >&2
  exit 2
fi
FM_CHAT_ROLE=captain exec "${FM_PRIMARY_STEER_BIN:-$SCRIPT_DIR/fm-primary-steer.sh}" publish \
  --home "$FM_HOME" --kind captain --text "[fm-supervisor-note] $*"
