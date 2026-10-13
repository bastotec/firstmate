#!/usr/bin/env bash
# fm-report.sh - read the fleet's or one mate's report, read-only.
#
# Usage: fm-report.sh <mate-id|fleet|primary> [--days N] [--json]
#
# The same report as Fleet Town's Report button (headline, what's waiting, the
# crew right now, what shipped, time worked, and power for the fleet), computed
# from firstmate's own records by bin/fm_report.py, whose header owns the data
# sources and the --json shape. No agent turn or model token is spent on the
# reported mate. --days 1 is today (the default), --days 7 the last seven days.
#
# Where it runs:
#   - the main home (the first mate, Ziggy, Fleet Town): computed now.
#   - a second mate home on the same machine as the main home: computed now
#     from the main home's records, which it reads but never writes.
#   - a second mate home on another machine: that home cannot reach the main
#     home, so the request rides its parent channel like a peer message
#     (bin/fm-mate-mail-lib.sh) and the first mate's router answers it with the
#     report as an ordinary first-mate message in this home's inbox, usually
#     within a minute. It prints "requested: corr=<corr>" and exits 0. The pull
#     rides the bridge's reports flow and the answer its messages flow.
#
# Exit codes: 0 printed (or requested); 1 refused or failed; 2 usage.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

SCOPE=${1:-}
case "$SCOPE" in ''|-h|--help) usage ;; esac
shift
DAYS=1
JSON=
while [ $# -gt 0 ]; do
  case "$1" in
    --days) [ $# -ge 2 ] || usage; DAYS=$2; shift 2 ;;
    --days=*) DAYS=${1#--days=}; shift ;;
    --json) JSON=--json; shift ;;
    *) usage ;;
  esac
done
case "$DAYS" in ''|*[!0-9]*|0) echo "error: --days must be a positive whole number" >&2; exit 2 ;; esac
case "$SCOPE" in *[!A-Za-z0-9._\ -]*) echo "error: '$SCOPE' is not a mate id, fleet or primary" >&2; exit 1 ;; esac

FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

route_rc=0
fm_parent_channel_destination "$FM_HOME" "$STATE" >/dev/null || route_rc=$?
case "$route_rc" in
  1) exec python3 "$SCRIPT_DIR/fm_report.py" report --home "$FM_HOME" --scope "$SCOPE" --days "$DAYS" ${JSON:+"$JSON"} ;;
  0) ;;
  *) echo "error: this home's parent binding is unreadable; cannot reach the first mate's records" >&2; exit 1 ;;
esac
case "$FM_PARENT_CHANNEL_ROUTE" in
  local)
    exec python3 "$SCRIPT_DIR/fm_report.py" report --home "$FM_SECONDMATE_PARENT_HOME" --scope "$SCOPE" --days "$DAYS" ${JSON:+"$JSON"}
    ;;
  remote)
    out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-mate-send.sh" primary \
      "fm-request report scope=${SCOPE// /-} days=$DAYS${JSON:+ json}") || exit 1
    printf 'requested: %s\nThe report arrives in your inbox as a first-mate message.\n' "${out#queued: }"
    ;;
esac
