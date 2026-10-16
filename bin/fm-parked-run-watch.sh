#!/usr/bin/env bash
# fm-parked-run-watch.sh - never let a worker's validation run sit parked.
#
# Usage: fm-parked-run-watch.sh scan [--help]
#        fm-parked-run-watch.sh close <worker-id>   (bin/fm-teardown.sh, as a
#        worker leaves: resolve an escalated episode, then drop its record)
#
# The home's watcher (bin/fm-watch.sh) runs a scan every
# FM_PARKED_RUN_INTERVAL seconds (600); this script owns what a scan does.
# A home only watches its own direct workers (kind=ship or kind=scout records
# in its state), so every mate, the first mate included, watches its own.
#
# For each worker, `bin/fm-crew-state.sh --publish <id>` refreshes
# state/<id>.crew-state; a verdict of `parked` means its no-mistakes run waits
# at a review gate or at the repair cap. state/<id>.parked-run records the
# parked run (run=, step=, since=, nudged=, escalated=):
#   - parked for FM_PARKED_RUN_SECS (3600): one `check:` wake to this home's own
#     supervisor, which decides it now - one fix round through
#     `no-mistakes axi respond`, or a fresh follow-up run
#     (.agents/skills/ask-user-authority/SKILL.md owns the decision);
#   - still parked FM_PARKED_RUN_SECS after that nudge: one escalation. A second
#     mate appends "blocked [key=parked-run-<mate>-<worker>]: ..." to its parent
#     channel (bin/fm-parent-channel-lib.sh), so the first mate raises it; the
#     first mate queues one `check:` wake to raise it with the captain. Either
#     names the worker, the run, its step and how long it has been parked;
#   - a run that moves on, or a new run, closes the record, and an escalated
#     one is resolved ("resolved [key=...]" on the parent channel, or one more
#     wake in the first mate's home).
#
# Environment knobs:
#   FM_HOME              required
#   FM_PARKED_RUN_SECS   seconds parked before each step (3600)
#
# Exit: 0 after a scan; 2 on invalid use.
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

case "${1:-}" in
  scan|close) ;;
  -h|--help) sed -n '2,34p' "$0"; exit 0 ;;
  *) sed -n '2,34p' "$0" >&2; exit 2 ;;
esac
[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is required" >&2; exit 2; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || exit 0

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

LIMIT=${FM_PARKED_RUN_SECS:-3600}
case "$LIMIT" in ''|*[!0-9]*) LIMIT=3600 ;; esac
NOW=$(date +%s)

field() {  # <file> <key>
  sed -n "s/^$2=//p" "$1" 2>/dev/null | tail -1
}

record_write() {  # <id> <run> <step> <since> <nudged> <escalated>
  local rec="$STATE/$1.parked-run"
  printf 'run=%s\nstep=%s\nsince=%s\nnudged=%s\nescalated=%s\n' "$2" "$3" "$4" "$5" "$6" > "$rec.tmp" \
    && mv -f "$rec.tmp" "$rec"
}

# Escalate (or, with "resolved", close) one parked run beyond this home.
escalate() {  # <id> <blocked|resolved> <text>
  local id=$1 verb=$2 text=$3 key rc=0
  key="parked-run-$(fm_parent_channel_home_id "$FM_HOME" 2>/dev/null || printf 'home')-$id"
  fm_parent_channel_report "$FM_HOME" "$STATE" "$verb [key=$key]: $(fm_parent_channel_clean_note "$text")" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) # The first mate's own home: tell its supervisor to raise it.
      if [ "$verb" = blocked ]; then
        fm_wake_append check "parked-run:$id:escalate:$NOW" "check: worker run parked too long: $text; raise it with the captain"
      else
        fm_wake_append check "parked-run:$id:resolved:$NOW" "check: worker run moving again: $text; clear its blocker"
      fi
      ;;
    *) return 1 ;;
  esac
}

minutes() { printf '%s' "$(( $1 / 60 ))"; }

if [ "$1" = close ]; then
  id=${2:-}
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: close needs a worker id" >&2; exit 2 ;; esac
  rec="$STATE/$id.parked-run"
  [ -f "$rec" ] || exit 0
  if [ "$(field "$rec" escalated)" = 1 ]; then
    escalate "$id" resolved "worker $id's run $(field "$rec" run) left the fleet while parked at $(field "$rec" step) (parked since $(field "$rec" since))" || exit 1
  fi
  rm -f "$rec"
  exit 0
fi

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  grep -qE '^kind=(ship|scout)$' "$meta" 2>/dev/null || continue
  id=$(basename "$meta" .meta)
  rec="$STATE/$id.parked-run"
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-crew-state.sh" --publish "$id" </dev/null >/dev/null 2>&1 || true
  verdict=$(field "$STATE/$id.crew-state" verdict)
  run=$(field "$STATE/$id.crew-state" run)
  step=$(field "$STATE/$id.crew-state" step)
  # Only an affirmative reading moves the clock: an unavailable query (no
  # record, or unknown) keeps the parked record as it is.
  case "$verdict" in
    parked) ;;
    working|done|blocked|failed) ;;
    *) continue ;;
  esac
  if [ "$verdict" != parked ]; then
    [ -f "$rec" ] || continue
    if [ "$(field "$rec" escalated)" = 1 ]; then
      escalate "$id" resolved "worker $id's run $(field "$rec" run) is no longer parked at $(field "$rec" step) (parked since $(field "$rec" since))" || continue
    fi
    rm -f "$rec"
    continue
  fi
  if [ ! -f "$rec" ] || [ "$(field "$rec" run)" != "$run" ] || [ "$(field "$rec" step)" != "$step" ]; then
    # A new run, or the same run parked at another gate, starts its own clock;
    # an escalated old episode is resolved first.
    if [ -f "$rec" ] && [ "$(field "$rec" escalated)" = 1 ]; then
      escalate "$id" resolved "worker $id's run $(field "$rec" run) is no longer parked at $(field "$rec" step) (parked since $(field "$rec" since))" || continue
    fi
    record_write "$id" "$run" "$step" "$NOW" 0 0
    continue
  fi
  since=$(field "$rec" since) nudged=$(field "$rec" nudged) escalated=$(field "$rec" escalated)
  case "$since" in ''|*[!0-9]*) since=$NOW ;; esac
  case "$nudged" in ''|*[!0-9]*) nudged=0 ;; esac
  [ "$escalated" != 1 ] || continue
  if [ "$nudged" = 0 ]; then
    [ $((NOW - since)) -ge "$LIMIT" ] || continue
    if fm_wake_append check "parked-run:$id:$run:$since" \
        "check: worker $id's validation run $run has been parked at ${step:-its gate} for $(minutes $((NOW - since))) minutes: decide it now - one fix round with no-mistakes axi respond, or a fresh follow-up run"; then
      record_write "$id" "$run" "$step" "$since" "$NOW" 0
    fi
    continue
  fi
  [ $((NOW - nudged)) -ge "$LIMIT" ] || continue
  if escalate "$id" blocked "worker $id's validation run $run has been parked at ${step:-its gate} since $(date -u -r "$since" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -d "@$since" +%Y-%m-%dT%H:%MZ) and its mate did not unstick it"; then
    record_write "$id" "$run" "$step" "$since" "$nudged" 1
  fi
done
exit 0
