#!/usr/bin/env bash
# fm-mate-route.sh - deliver queued peer messages between second mates.
#
# Usage: fm-mate-route.sh run
#
# Runs in a main home (the first mate's), detached from every watcher poll.
# bin/fm-mate-mail-lib.sh owns the design, spool, and log. For each pending
# message, oldest first:
#   1. The sender must be a recorded second mate of this home, and the target
#      `primary` or another recorded second mate; otherwise it is refused.
#   2. A sender or target on another machine must have the bridge's `messages`
#      flow allowed (bin/fm-bridge.sh check). A blocked flow records the
#      captain's approval request (bin/fm-bridge.sh block) and refuses.
#   3. Delivery: to a mate, bin/fm-send.sh <to> --fire-and-forget <corr>
#      --from-mate <from> (idempotent on the corr, local or remote); to the first
#      mate, bin/fm-send.sh primary with the same tag, or a `check:` wake row when
#      no Deck chat primary is running.
#   4. A delivery that fails is retried on later polls with the same corr, and
#      fails for good after FM_MATE_ROUTE_MAX_TRIES (default 10) attempts or
#      FM_MATE_ROUTE_MAX_AGE seconds (default 1800).
# Every terminal outcome is one line in state/mate-messages.log. A refused or
# failed message is also bounced to its sender as a first-mate message naming
# the corr and reason, and queues one `check:` wake keyed mate-mail:<corr>, so
# nothing is dropped silently. Delivered messages wake nobody: the first mate's
# copy is the log line. Mate messages never page the captain.
#
# Exit 0 after a pass (including an empty one); 1 when this is not a main home
# or the pass could not lock.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${FM_HOME:-}" ] || { echo "error: FM_HOME is required" >&2; exit 1; }
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-mate-mail-lib.sh
. "$SCRIPT_DIR/fm-mate-mail-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

SEND_BIN=${FM_MATE_ROUTE_SEND_BIN:-$SCRIPT_DIR/fm-send.sh}
BRIDGE_BIN=${FM_MATE_ROUTE_BRIDGE_BIN:-$SCRIPT_DIR/fm-bridge.sh}
MAX_TRIES=${FM_MATE_ROUTE_MAX_TRIES:-10}
MAX_AGE=${FM_MATE_ROUTE_MAX_AGE:-1800}

[ "${1:-}" = run ] || { sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
[ ! -e "$FM_HOME/.fm-secondmate-home" ] || { echo "error: mate messages are routed by the main home" >&2; exit 1; }

DIR=$(fm_mate_mail_dir "$STATE")
[ -d "$DIR/pending" ] || exit 0
LOCK="$DIR/.route.lock"
if ! mkdir "$LOCK" 2>/dev/null; then
  # A pass that died mid-way leaves its lock; one older than ten minutes is stale.
  [ -n "$(find "$LOCK" -maxdepth 0 -mmin +10 2>/dev/null)" ] || exit 1
  rm -rf "$LOCK" && mkdir "$LOCK" 2>/dev/null || exit 1
fi
trap 'rm -rf "$LOCK"' EXIT

mate_meta() {  # <id> -> meta path when <id> is a recorded second mate
  local meta="$STATE/$1.meta"
  [ -f "$meta" ] && [ "$(fm_meta_get "$meta" kind)" = secondmate ] || return 1
  printf '%s\n' "$meta"
}

known_mates() {
  local meta out=''
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
    meta=${meta##*/}
    out="$out${out:+, }${meta%.meta}"
  done
  printf '%s' "${out:-none}"
}

# 0 when the bridge to <id>'s machine (if any) allows messages; else sets REASON.
bridge_allows() {  # <id> <what>
  local meta host answer
  [ "$1" != primary ] || return 0
  meta=$(mate_meta "$1") || return 0
  host=$(fm_meta_get "$meta" remote_host)
  [ -n "$host" ] || return 0
  answer=$(FM_HOME="$FM_HOME" "$BRIDGE_BIN" check "$host" messages 2>&1) && return 0
  FM_HOME="$FM_HOME" "$BRIDGE_BIN" block "$host" messages --what "$2" >/dev/null 2>&1 || true
  REASON="bridge-blocked: ${answer#deny: }; the captain must allow messages on the $host bridge"
  return 1
}

bounce_id() {  # <corr>
  printf 'bounce:%s' "$1" | shasum -a 256 | cut -c1-16
}

# Close <record> as <outcome> (refused|failed) with REASON: log, bounce, wake.
close_undelivered() {  # <record> <outcome>
  local record=$1 outcome=$2 name note bounce_note=''
  name=${record##*/}
  note="Your message corr=$FM_MM_CORR to $FM_MM_TO was $outcome: $REASON"
  if mate_meta "$FM_MM_FROM" >/dev/null; then
    FM_HOME="$FM_HOME" "$SEND_BIN" "$FM_MM_FROM" --fire-and-forget "$(bounce_id "$FM_MM_CORR")" \
      "$note" >/dev/null 2>&1 || bounce_note=' (the sender could not be told)'
  else
    bounce_note=' (the sender is not a recorded second mate)'
  fi
  mkdir -p "$DIR/$outcome" && mv "$record" "$DIR/$outcome/$name" || return 1
  rm -f "${record%.msg}.tries"
  fm_mate_mail_log "$STATE" "$outcome" "$REASON$bounce_note" || true
  fm_wake_append check "mate-mail:$FM_MM_CORR" \
    "check: second mate message $FM_MM_CORR from $FM_MM_FROM to $FM_MM_TO was $outcome: $REASON$bounce_note" || true
  printf '%s: %s %s -> %s: %s%s\n' "$outcome" "$FM_MM_CORR" "$FM_MM_FROM" "$FM_MM_TO" "$REASON" "$bounce_note"
}

close_delivered() {  # <record> <how>
  local record=$1 name=${1##*/}
  mkdir -p "$DIR/delivered" && mv "$record" "$DIR/delivered/$name" || return 1
  rm -f "${record%.msg}.tries"
  fm_mate_mail_log "$STATE" delivered "$2" || true
  printf 'delivered: %s %s -> %s\n' "$FM_MM_CORR" "$FM_MM_FROM" "$FM_MM_TO"
}

# Count one failed attempt; 0 when the message should now fail for good.
attempt_exhausted() {  # <record>
  local tries="${1%.msg}.tries" count=0 first now
  now=$(date +%s)
  first=$now
  if [ -f "$tries" ]; then
    read -r count first < "$tries" || true
  fi
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  case "$first" in ''|*[!0-9]*) first=$now ;; esac
  count=$((count + 1))
  printf '%s %s\n' "$count" "$first" > "$tries"
  [ "$count" -ge "$MAX_TRIES" ] || [ $((now - first)) -ge "$MAX_AGE" ]
}

deliver_primary() {
  local tagged rc=0
  fm_message_mark_from_mate "$FM_MM_FROM" "$FM_MM_CORR" "$FM_MM_TEXT" tagged || return 1
  FM_HOME="$FM_HOME" "$SEND_BIN" primary "$tagged" >/dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || { DELIVERED_HOW=chat; return 0; }
  [ "$rc" -eq 3 ] || return 1
  # No Deck chat primary is running: the first mate reads its wake queue.
  fm_wake_append check "mate-mail:$FM_MM_CORR" \
    "check: message from second mate $FM_MM_FROM (corr $FM_MM_CORR${FM_MM_RE:+, re $FM_MM_RE}): $(printf '%s' "$FM_MM_TEXT" | tr '\n\t' '  ' | cut -c1-400)" \
    || return 1
  DELIVERED_HOW=wake
}

# shellcheck disable=SC2010,SC2012 # spool names are <mate-id>@<16 hex>.msg, never odd bytes
ls -tr "$DIR/pending" 2>/dev/null | grep '\.msg$' | while IFS= read -r name; do
  record="$DIR/pending/$name"
  [ -f "$record" ] || continue
  REASON=
  if ! fm_mate_mail_read "$record"; then
    REASON="malformed spool record"
    FM_MM_FROM=${FM_MM_FROM:-unknown} FM_MM_TO=${FM_MM_TO:-unknown} FM_MM_CORR=${FM_MM_CORR:-unknown}
    mkdir -p "$DIR/failed" && mv "$record" "$DIR/failed/" || true
    fm_mate_mail_log "$STATE" failed "$REASON" || true
    continue
  fi
  if ! mate_meta "$FM_MM_FROM" >/dev/null; then
    REASON="the sender $FM_MM_FROM is not a recorded second mate of this fleet"
    close_undelivered "$record" refused; continue
  fi
  if [ "$FM_MM_TO" != primary ] && ! mate_meta "$FM_MM_TO" >/dev/null; then
    REASON="there is no second mate named $FM_MM_TO (second mates: $(known_mates); or primary for the first mate)"
    close_undelivered "$record" refused; continue
  fi
  bridge_allows "$FM_MM_FROM" "mate message from $FM_MM_FROM to $FM_MM_TO" \
    || { close_undelivered "$record" refused; continue; }
  bridge_allows "$FM_MM_TO" "mate message from $FM_MM_FROM to $FM_MM_TO" \
    || { close_undelivered "$record" refused; continue; }
  DELIVERED_HOW=inbox
  err=
  if [ "$FM_MM_TO" = primary ]; then
    deliver_primary && { close_delivered "$record" "$DELIVERED_HOW"; continue; }
    err="the first mate's chat did not accept it"
  else
    if err=$(FM_HOME="$FM_HOME" "$SEND_BIN" "$FM_MM_TO" --fire-and-forget "$FM_MM_CORR" \
      --from-mate "$FM_MM_FROM" "$FM_MM_TEXT" 2>&1 >/dev/null); then
      close_delivered "$record" inbox; continue
    fi
    err=$(printf '%s' "$err" | grep -v '^$' | tail -1)
    case "$err" in
      *bridge-blocked:*)
        REASON=${err#*bridge-blocked: }
        REASON="bridge-blocked: $REASON"
        close_undelivered "$record" refused; continue ;;
    esac
  fi
  if attempt_exhausted "$record"; then
    REASON="delivery kept failing (${err:-unknown error})"
    close_undelivered "$record" failed
  fi
done
exit 0
