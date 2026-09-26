#!/usr/bin/env bash
# fm-record-model-refusal.sh - record or clear one model refusal on the lane a
# task's launch resolved through, so the next spawn or relaunch falls through
# the spawn-side model fallback chain (docs/configuration.md "Model fallback
# chains"; bin/fm-model-chain-lib.sh owns the cooldown semantics).
#
# Usage:
#   fm-record-model-refusal.sh <task-id> <provider/model-id>
#       Record that <task-id>'s most recent launch could not run
#       <provider/model-id> (quota refusal, cooldown, or repeated provider
#       error); the model sits out with the branch backoff, five minutes
#       doubling to an hour.
#   fm-record-model-refusal.sh <task-id> --clear <provider/model-id>
#       Drop that label's cooldown record, as the success side of the same
#       contract: a later launch reads the model ready again.
#
# The lane is read from state/<task-id>.meta: kind=secondmate relaunches and
# secondmate-default resolutions use lane "secondmate(-<id>)", everything else
# "crew(-<id>)", matching fm-spawn.sh's resolution. A task whose record is
# missing, or whose recorded model holds no chain, reports that and exits 1
# without touching any state.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}
case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac
[ "$#" -ge 2 ] || { usage >&2; exit 2; }

ID=$1
shift
ACTION=record
case "${1:-}" in
  --clear) ACTION=clear; shift ;;
  -*) { echo "error: unknown option $1" >&2; usage >&2; exit 2; } ;;
esac
LABEL=${1:-}
[ -n "$LABEL" ] || { echo "error: a <provider/model-id> label is required" >&2; exit 2; }
case "$LABEL" in
  *,*) { echo "error: '$LABEL' is a chain, not one <provider>/<model-id> label" >&2; exit 2; } ;;
esac

META="$STATE/$ID.meta"
[ -f "$META" ] || { echo "error: no task record at $META" >&2; exit 1; }
[ ! -L "$META" ] || { echo "error: $META is a symlink; refusing" >&2; exit 1; }

meta_get() {  # <key>
  sed -n "s/^$1=//p" "$META" | tail -1
}

# fm-spawn's lane contract: a default-resolved secondmate surface shares the
# secondmate lane; every crew-side chain (explicit chained --model pins,
# dispatch-profile chains, relaunches) resolves on a task lane. The recorded
# spawn generation only proves which task is meant, so
# the lane defaults to the task lane (the conservative side: a stray record
# cools one task's chain, never the shared default lane).
KIND=$(meta_get kind)
KIND=${KIND:-ship}
LANE=$(meta_get model_chain_lane)
if [ -z "$LANE" ]; then
  case "$KIND" in
    secondmate) LANE=secondmate-$ID ;;
    *)          LANE=crew-$ID ;;
  esac
fi

# shellcheck source=bin/fm-model-chain-lib.sh
. "$SCRIPT_DIR/fm-model-chain-lib.sh"

STATE_PATH="$STATE/model-chain/$LANE.state"
NOW=$(date +%s)
case "$ACTION" in
  record)
    mkdir -p "$STATE/model-chain" 2>/dev/null || true
    fm_model_chain_record_refusal "$STATE_PATH" "$LABEL" "$NOW" || {
      echo "error: could not record the refusal for $LABEL on lane $LANE" >&2
      exit 1
    }
    echo "recorded refusal of $LABEL on lane $LANE (state/model-chain/$LANE.state)"
    ;;
  clear)
    fm_model_chain_clear "$STATE_PATH" "$LABEL" || {
      echo "error: could not clear $LABEL on lane $LANE" >&2
      exit 1
    }
    echo "cleared $LABEL on lane $LANE"
    ;;
esac
