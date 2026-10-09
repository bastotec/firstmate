#!/usr/bin/env bash
# fm-secondmate-revive.sh - notice a dead second mate and bring it back without
# waiting for the first mate's next turn.
#
# Usage: fm-secondmate-revive.sh scan [--help]
#
# Session start (bin/fm-bootstrap.sh's liveness sweep) is the only other place a
# dead second mate is relaunched, so a mate that dies mid-session - a turn that
# stops its own driver, a lifecycle exit that lands after its control action
# gave up, a hub that forgot its endpoint - otherwise stays down until somebody
# notices. The home's watcher (bin/fm-watch.sh) runs `scan` detached on a short
# cadence; this script owns what a scan does.
#
# One scan, for every kind=secondmate record in THIS home's state (a home never
# reads or acts on another home's records, so only the owning home revives a
# mate):
#   - read the endpoint the same way the control plane does: the local backend's
#     agent-state classifier, or the configured host's `state` verb for a remote
#     route (an unreachable host or unreadable answer is unknown, never dead);
#   - `alive` clears the mate's revive record and any deliberate-stop marker;
#   - `dead` (endpoint present, no agent) is revived with
#     `bin/fm-control.sh <id> relaunch`, local or remote;
#   - local `missing` (endpoint gone) is revived with
#     `bin/fm-control.sh <id> recover-missing`, whose own guard refuses while the
#     mate's agent process is still running, so a hub that merely forgot a live
#     endpoint is never duplicated;
#   - remote `missing` has no primary-side recovery verb, so it is only
#     escalated, under the same confirmation and budget as a failed revival;
#   - anything else (ambiguous, unreadable, unknown) is left alone.
# A down reading is acted on only after it has been seen on two scans at least
# FM_SECONDMATE_REVIVE_CONFIRM_SECS apart, which keeps a relaunch already in
# flight elsewhere (an update restart, a session-start sweep, an operator) from
# being raced: those hold the mate's control lock, and fm-control refuses a
# second lifecycle action while it is held.
#
# A mate stopped on purpose with `bin/fm-control.sh <id> exit` carries
# state/<id>.held-stopped and is skipped until it is seen alive again or is
# relaunched through fm-control.
#
# Budget and escalation. Each failed revival is counted in state/<id>.revive.
# After FM_SECONDMATE_REVIVE_ATTEMPTS failures (2) the scan appends ONE
# `check:` wake to this home's durable wake queue, keyed
# `secondmate-revive:<id>:<episode>`, which the watcher surfaces on its own, and
# stops trying until the mate is seen alive again, so a broken mate costs a
# bounded number of relaunches and exactly one notification; a spent budget
# whose escalation could not be queued retries only the escalation. A
# successful revival notifies nobody; it is appended to
# state/secondmate-revive.log. Each mate is handled by its own worker under
# state/.secondmate-revive-<id>.lock, so one slow relaunch never delays another.
#
# The automatic relaunch passes --unless-held-stopped, so fm-control re-checks
# the deliberate-stop record under the mate's control lock, and that record is
# withdrawn here only under the same lock after a fresh alive reading.
#
# Environment knobs:
#   FM_HOME                            required
#   FM_SECONDMATE_REVIVE_CONFIRM_SECS  down-reading confirmation window (45)
#   FM_SECONDMATE_REVIVE_ATTEMPTS      failed revivals before escalation (2)
#
# Exit: 0 after a scan; 2 on invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
  scan) ;;
  *) usage >&2; exit 2 ;;
esac

[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || {
  echo "error: FM_HOME must name a firstmate home" >&2
  exit 2
}
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
[ -d "$STATE" ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

CONFIRM_SECS=${FM_SECONDMATE_REVIVE_CONFIRM_SECS:-45}
case "$CONFIRM_SECS" in ''|*[!0-9]*) CONFIRM_SECS=45 ;; esac
ATTEMPTS=${FM_SECONDMATE_REVIVE_ATTEMPTS:-2}
case "$ATTEMPTS" in ''|*[!0-9]*|0) ATTEMPTS=2 ;; esac
LOG="$STATE/secondmate-revive.log"
NOTE="Restarted automatically after this second mate was found down. Read your inbox in order and answer anything the captain is waiting on."

log() {  # <line>
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

one_line() {  # <text>
  printf '%s\n' "$1" | sed -n '/^warning: /d;/./{s/^error: //;s/[[:space:]]\{1,\}/ /g;p;q;}' | cut -c1-300
}

# Revive record fields: down_state first_seen failures escalated
record_read() {  # <id>
  local rec="$STATE/$1.revive"
  REC_STATE=; REC_SEEN=0; REC_FAILURES=0; REC_ESCALATED=0
  [ -f "$rec" ] || return 0
  REC_STATE=$(sed -n 's/^down_state=//p' "$rec" | tail -1)
  REC_SEEN=$(sed -n 's/^first_seen=//p' "$rec" | tail -1)
  REC_FAILURES=$(sed -n 's/^failures=//p' "$rec" | tail -1)
  REC_ESCALATED=$(sed -n 's/^escalated=//p' "$rec" | tail -1)
  case "$REC_SEEN" in ''|*[!0-9]*) REC_SEEN=0 ;; esac
  case "$REC_FAILURES" in ''|*[!0-9]*) REC_FAILURES=0 ;; esac
  case "$REC_ESCALATED" in 1) ;; *) REC_ESCALATED=0 ;; esac
}

record_write() {  # <id> <down-state> <first-seen> <failures> <escalated> [<last-failure>]
  local rec="$STATE/$1.revive"
  printf 'down_state=%s\nfirst_seen=%s\nfailures=%s\nescalated=%s\nlast=%s\n' "$2" "$3" "$4" "$5" "${6:-}" \
    > "$rec.tmp" && mv -f "$rec.tmp" "$rec"
}

escalate() {  # <id> <what-happened>
  local id=$1 reason=$2
  if fm_wake_append check "secondmate-revive:$id:$(date +%s)" \
    "check: secondmate revival failed: second mate $id is down and $reason"; then
    log "escalated $id: $reason"
    return 0
  fi
  log "escalation for $id could not be queued: $reason"
  return 1
}

budget_spent() {  # <last-failure>
  printf '%s automatic revivals did not bring it back: %s' "$ATTEMPTS" "$1"
}

probe() {  # <meta> <id>  -> prints alive|dead|missing|unknown
  local meta=$1 id=$2 out rc backend target
  if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
    rc=0
    out=$(FM_HOME="$FM_HOME" \
      "$SCRIPT_DIR/fm-on.sh" "$id" fm-remote-secondmate-control.sh state "$id" \
      < /dev/null 2>/dev/null) || rc=$?
    [ "$rc" -eq 0 ] || { echo unknown; return 0; }
    case "$(printf '%s\n' "$out" | tail -1)" in
      alive) echo alive ;;
      dead) echo dead ;;
      missing) echo missing ;;
      *) echo unknown ;;
    esac
    return 0
  fi
  backend=$(fm_backend_of_meta "$meta")
  target=$(fm_backend_target_of_meta "$meta")
  [ -n "$target" ] || target=$(fm_meta_get "$meta" window)
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)" in
    alive) echo alive ;;
    dead) echo dead ;;
    missing) echo missing ;;
    *) echo unknown ;;
  esac
}

revive_one() {  # <meta> <id>
  local meta=$1 id=$2 state now verb out rc remote failures reason
  remote=$(fm_meta_get "$meta" remote_host)
  state=$(probe "$meta" "$id")
  now=$(date +%s)
  record_read "$id"
  case "$state" in
    alive)
      if [ -n "$REC_STATE" ]; then
        rm -f "$STATE/$id.revive"
        log "$id is alive again"
      fi
      # Withdraw a stale deliberate-stop record only under the mate's control
      # lock and on a fresh alive reading, so an exit that completes after the
      # first reading keeps its record.
      if [ -e "$STATE/$id.held-stopped" ] && fm_lock_try_acquire "$STATE/.control-$id.lock"; then
        [ "$(probe "$meta" "$id")" != alive ] || rm -f "$STATE/$id.held-stopped"
        fm_lock_release "$STATE/.control-$id.lock" >/dev/null 2>&1 || true
      fi
      return 0
      ;;
    dead|missing) ;;
    *) return 0 ;;
  esac
  [ ! -e "$STATE/$id.held-stopped" ] || return 0
  [ "$REC_ESCALATED" = 0 ] || return 0
  # A spent budget only retries publishing its one escalation, never another
  # revival.
  if [ "$REC_FAILURES" -ge "$ATTEMPTS" ]; then
    reason=$(sed -n 's/^last=//p' "$STATE/$id.revive" | tail -1)
    escalate "$id" "$(budget_spent "$reason")" \
      && record_write "$id" "$REC_STATE" "$REC_SEEN" "$REC_FAILURES" 1 "$reason"
    return 0
  fi
  if [ "$REC_STATE" != "$state" ] || [ "$REC_SEEN" -eq 0 ]; then
    record_write "$id" "$state" "$now" "$REC_FAILURES" 0
    return 0
  fi
  [ $((now - REC_SEEN)) -ge "$CONFIRM_SECS" ] || return 0

  if [ "$state" = missing ] && [ -n "$remote" ]; then
    escalate "$id" "its endpoint on $remote is gone; no automatic revival was tried, because only that host can recover a remote endpoint" \
      && record_write "$id" "$state" "$REC_SEEN" "$REC_FAILURES" 1
    return 0
  fi
  verb=relaunch
  [ "$state" = dead ] || verb=recover-missing
  log "reviving $id ($state endpoint) with $verb"
  rc=0
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" "$verb" --unless-held-stopped \
    --note "$NOTE" < /dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    rm -f "$STATE/$id.revive"
    log "revived $id: $(printf '%s\n' "$out" | grep -E '^(relaunched|recovered) ' | tail -1)"
    return 0
  fi
  case "$out" in
    *"is not down"*)
      rm -f "$STATE/$id.revive"
      log "$id is alive again"
      return 0
      ;;
    *"was stopped on purpose"*)
      rm -f "$STATE/$id.revive"
      log "$id was stopped on purpose; leaving it down"
      return 0
      ;;
    *"another lifecycle action is already running"*)
      # An update restart, a teardown, or an operator owns the mate right now;
      # that is not a failed revival. Look again after a fresh confirmation.
      record_write "$id" "$state" "$now" "$REC_FAILURES" 0
      return 0
      ;;
  esac
  failures=$((REC_FAILURES + 1))
  reason=$(one_line "$out")
  log "revival of $id failed ($failures/$ATTEMPTS): $reason"
  if [ "$failures" -ge "$ATTEMPTS" ]; then
    if escalate "$id" "$(budget_spent "$reason")"; then
      record_write "$id" "$state" "$now" "$failures" 1 "$reason"
      return 0
    fi
  fi
  # Wait another confirmation window before the next attempt.
  record_write "$id" "$state" "$now" "$failures" 0 "$reason"
}

# Each mate gets its own worker under its own lock, so a mate whose probe or
# relaunch is slow skips only its own later scans, never another mate's. The
# scan waits for the workers it started; overlapping scans are expected.
revive_worker() {  # <meta> <id>
  local lock="$STATE/.secondmate-revive-$2.lock"
  fm_lock_try_acquire "$lock" || return 0
  revive_one "$1" "$2"
  fm_lock_release "$lock" >/dev/null 2>&1 || true
}

for meta in "$STATE"/*.meta; do
  [ -f "$meta" ] || continue
  grep -q '^kind=secondmate$' "$meta" 2>/dev/null || continue
  [ -n "$(fm_meta_get "$meta" window)" ] || continue
  revive_worker "$meta" "$(basename "$meta" .meta)" </dev/null >/dev/null 2>&1 &
done
wait
exit 0
