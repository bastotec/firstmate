#!/usr/bin/env bash
# fm-mate-send.sh - a second mate messages another second mate, or the first mate.
#
# Usage (from a second mate's own home, FM_HOME set):
#   fm-mate-send.sh <mate-id>|primary [--reply-to <corr>] <text...>
#
# bin/fm-mate-mail-lib.sh owns routing, the parent-channel wire, spool, and log.
# Local homes write the parent spool; remote homes append their parent channel.
# Exit 0 prints "queued: corr=<corr> to=<target>", not confirmation of delivery.
# Each invocation mints a new corr; rerunning sends a new message, not a retry.
# Delivery follows on the parent's next watcher poll, subject to bridge gates.
# The receiver sees "[fm-from-mate:<this-mate>]" and the corr; reply with --reply-to.
# Refused/failed deliveries are bounced with the corr and reason, and logged.
# Cross-machine delivery requires the bridge's "messages" flow (bin/fm-bridge.sh).
# A remote sender also needs "reports" for the existing parent-channel pull.
# A denied reports flow leaves the message queued until allowed; bin/fm-on.sh
# raises the bridge approval request. No messages-gated retrieval path is added.
# Text has a fixed 4000-byte cap; point at a data/*.md file for more.
# A file pointer does not transfer the file (see bin/fm-mate-mail-lib.sh).
# Workers cannot use this path; they report to their own mate instead.
#
# Exit codes: 0 queued; 1 refused (bad target, worker caller, main home,
# empty or oversized text); 2 usage; 4 the queue write failed (resend).
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-mate-mail-lib.sh
. "$SCRIPT_DIR/fm-mate-mail-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

[ -n "${FM_HOME:-}" ] || die "FM_HOME is not set; run this from your own home"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

TARGET=${1:-}
case "$TARGET" in ''|-h|--help) usage ;; esac
shift
REPLY_TO=
if [ "${1:-}" = --reply-to ]; then
  [ $# -ge 2 ] || usage
  REPLY_TO=$2
  shift 2
fi
TEXT=$*

# Workers talk only to their own mate (AGENTS.md hard rule 4).
case "${FM_TASK_ID:-}" in
  ''|*[!A-Za-z0-9._-]*|.|..) ;;
  *)
    if [ -f "$STATE/$FM_TASK_ID.meta" ]; then
      die "worker $FM_TASK_ID cannot message other mates; append a status line for your own mate instead"
    fi ;;
esac

SELF=$(fm_parent_channel_home_id "$FM_HOME") \
  || die "this is not a second mate home; the first mate messages mates with fm-send.sh <mate-id>"
[ "$TARGET" = primary ] || fm_mate_mail_id_valid "$TARGET" || die "'$TARGET' is not a mate id (or primary)"
[ "$TARGET" != "$SELF" ] || die "a mate cannot message itself"
[ -z "$REPLY_TO" ] || fm_mate_mail_corr_valid "$REPLY_TO" || die "--reply-to needs the 16-hex corr of the message you answer"
[ -n "$TEXT" ] || die "message text is empty"
bytes=$(printf '%s' "$TEXT" | LC_ALL=C wc -c | tr -d ' ')
[ "$bytes" -le "$FM_MATE_MAIL_MAX_BYTES" ] \
  || die "message is $bytes bytes; the limit is $FM_MATE_MAIL_MAX_BYTES. Write the detail to a data/*.md file and send a short message pointing at it"

# Called once for the route globals and once for the printed path.
if ! fm_parent_channel_destination "$FM_HOME" "$STATE" >/dev/null \
  || ! DEST=$(fm_parent_channel_destination "$FM_HOME" "$STATE"); then
  die "this home's parent binding is missing or unreadable; cannot reach the first mate" 4
fi
CORR=$(fm_mate_mail_new_corr)
fm_mate_mail_corr_valid "$CORR" || die "could not mint a message corr" 4

case "$FM_PARENT_CHANNEL_ROUTE" in
  local)
    rc=0
    fm_mate_mail_spool "$(dirname "$DEST")" "$SELF" "$TARGET" "$CORR" "$REPLY_TO" "$TEXT" || rc=$?
    [ "$rc" -eq 0 ] || die "could not queue the message in the first mate's home (rc=$rc); resend" 4
    ;;
  remote)
    fm_parent_channel_append_once "$DEST" "$(fm_mate_mail_line "$CORR" "$TARGET" "$REPLY_TO" "$TEXT")" \
      || die "could not append the message to $DEST; resend" 4
    ;;
  *) die "unknown parent route" 4 ;;
esac
printf 'queued: corr=%s to=%s\n' "$CORR" "$TARGET"
