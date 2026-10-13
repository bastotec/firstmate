#!/usr/bin/env bash
# fm-mates.sh - list the fleet's second mates: id, machine and domain.
#
# Usage: fm-mates.sh list [--json]
#
# Reads the first mate's registry (data/secondmates.md, parsed by
# bin/fm_report.py) from the main home or from a second mate home on the same
# machine. A second mate on another machine cannot reach that registry, so the
# request rides its parent channel and the first mate's router answers with the
# list as a first-mate message in this home's inbox (see bin/fm-report.sh).
# Use the ids with bin/fm-mate-send.sh and bin/fm-report.sh.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

[ "${1:-}" = list ] || { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
JSON=${2:-}
[ -z "$JSON" ] || [ "$JSON" = --json ] || { echo "error: unknown option $JSON" >&2; exit 2; }

FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

list_from() {  # <main-home>
  python3 - "$SCRIPT_DIR" "$1" "$JSON" <<'PY'
import json, sys
sys.path.insert(0, sys.argv[1])
from fm_report import registry
reg = registry(sys.argv[2])
rows = [{'id': k, 'machine': v['machine'], 'domain': v['domain']} for k, v in sorted(reg.items())]
if sys.argv[3]:
    print(json.dumps(rows, indent=1))
else:
    for r in rows:
        print('%s (%s): %s' % (r['id'], r['machine'], r['domain']))
    print('primary (this Mac): the first mate - cross-fleet decisions and anything for the captain')
PY
}

route_rc=0
fm_parent_channel_destination "$FM_HOME" "$STATE" >/dev/null || route_rc=$?
case "$route_rc" in
  1) list_from "$FM_HOME"; exit ;;
  0) ;;
  *) echo "error: this home's parent binding is unreadable; cannot reach the first mate's registry" >&2; exit 1 ;;
esac
case "$FM_PARENT_CHANNEL_ROUTE" in
  local) list_from "$FM_SECONDMATE_PARENT_HOME" ;;
  remote)
    out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-mate-send.sh" primary "fm-request mates${JSON:+ json}") || exit 1
    printf 'requested: %s\nThe list arrives in your inbox as a first-mate message.\n' "${out#queued: }"
    ;;
esac
