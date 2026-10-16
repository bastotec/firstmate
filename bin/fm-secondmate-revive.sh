#!/usr/bin/env bash
# fm-secondmate-revive.sh - notice a dead second mate and bring it back without
# waiting for the first mate's next turn.
#
# Usage: fm-secondmate-revive.sh scan [--help]
#
# The home's watcher (bin/fm-watch.sh) owns the detached scan cadence through
# FM_SECONDMATE_REVIVE_INTERVAL; this script owns what a scan does.
# docs/stream-backend.md "Secondmate lifecycle" owns operator behavior and
# startup-recovery limits; tests/fm-secondmate-revive.test.sh pins this path.
#
# One scan, for every kind=secondmate record with a window in THIS home's state
# (a home never reads or acts on another home's records, so only the owning home
# revives a mate):
#   - read the endpoint the same way the control plane does: the local backend's
#     agent-state classifier, or the configured host's `state` verb for a remote
#     route (an unreachable host or unreadable answer is unknown, never dead);
#   - `alive` clears the mate's revive record and any deliberate-stop marker,
#     then checks its lane-failure keys (the LANE HEALTH block below owns it);
#   - `dead` (endpoint present, no agent) is revived with
#     `bin/fm-control.sh <id> relaunch`, local or remote;
#   - `missing` (endpoint gone), local or remote, is revived with
#     `bin/fm-control.sh <id> recover-missing`, whose own guard refuses while the
#     mate's agent process is still running (on this machine, or on the mate's
#     host for a remote route), so a hub that merely forgot a live endpoint is
#     never duplicated;
#   - anything else (ambiguous, unreadable, unknown) is left alone.
# A down reading is acted on only after it has been seen on two scans at least
# FM_SECONDMATE_REVIVE_CONFIRM_SECS apart. fm-control refuses a second lifecycle
# action while the mate's control lock is held; that refusal consumes no failure
# and starts a fresh confirmation window. A fresh alive reading at automatic
# admission clears the revive record without a failure.
#
# bin/fm-control.sh's header owns deliberate-stop marker semantics.
# A down mate carrying that marker is skipped.
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
# Escalated records with failures below the current attempt budget restart
# confirmation, admitting legacy remote-missing escalations that tried no
# recovery. Deliberate-stop markers and spent budgets remain protected;
# tests/fm-secondmate-revive.test.sh pins this compatibility boundary.
#
# Both automatic recovery verbs pass --unless-held-stopped for fm-control's
# locked admission guard. This scan withdraws a stale deliberate-stop marker
# only under that same control lock after a fresh alive reading.
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
. "$SCRIPT_DIR/fm-classify-lib.sh"

CONFIRM_SECS=${FM_SECONDMATE_REVIVE_CONFIRM_SECS:-45}
case "$CONFIRM_SECS" in ''|*[!0-9]*) CONFIRM_SECS=45 ;; esac
ATTEMPTS=${FM_SECONDMATE_REVIVE_ATTEMPTS:-2}
case "$ATTEMPTS" in ''|*[!0-9]*|0) ATTEMPTS=2 ;; esac
LOG="$STATE/secondmate-revive.log"
NOTE="Restarted automatically after this second mate was found down. Read your inbox in order and answer anything the captain is waiting on."

log() {  # <line>
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

# The first error line when there is one, else the first line that is not a
# warning: control-plane output can open with banners before its refusal.
one_line() {  # <text>
  local line
  line=$(printf '%s\n' "$1" | sed -n '/^error: /{p;q;}')
  [ -n "$line" ] || line=$(printf '%s\n' "$1" | sed -n '/^[Ww][Aa][Rr][Nn][Ii][Nn][Gg]: /d;/./{p;q;}')
  printf '%s\n' "$line" | sed 's/^error: //;s/[[:space:]]\{1,\}/ /g' | cut -c1-300
}

# Revive record fields: down_state first_seen failures escalated last.
# `last` retains the deciding failure if escalation must be retried.
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
  local meta=$1 id=$2 state now verb out rc failures reason
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
      lane_heal "$id"
      return 0
      ;;
    dead|missing) ;;
    *) return 0 ;;
  esac
  [ ! -e "$STATE/$id.held-stopped" ] || return 0
  if [ "$REC_ESCALATED" = 1 ] && [ "$REC_FAILURES" -lt "$ATTEMPTS" ]; then
    REC_ESCALATED=0
    REC_SEEN=0
  fi
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

# LANE HEALTH. A live mate can still be stuck: its own host reports a run of
# failed turns on a lane by appending a keyed blocker to the parent channel
# (this home's state/<id>.status, mirrored there for a remote mate):
# "blocked [key=supervisor-failing-<id>]: ..." from bin/fm-deck-worker.sh, or
# "blocked [key=conversation-failing-<id>]: ..." from bin/fm-captain-lane.sh,
# each later closed by "resolved [key=...]". While such a key is open this scan
# first tries the safe fix once per episode, a `bin/fm-control.sh <id> relaunch`
# that resumes the mate's recorded sessions, and records it in
# state/<id>.lane-heal-<supervisor|conversation>, one record per lane. If the
# key is still open FM_LANE_HEAL_GRACE_SECS (900) after that relaunch, or the relaunch fails, it queues one `check:` wake for
# the first mate to raise with the captain, naming the mate, the lane, its error
# and since when. A resolved key removes the record, and a recovery after an
# escalation queues one "recovered" wake, so the blocker clears.
HEAL_GRACE=${FM_LANE_HEAL_GRACE_SECS:-900}
case "$HEAL_GRACE" in ''|*[!0-9]*) HEAL_GRACE=900 ;; esac
HEAL_NOTE="Restarted automatically because one of your lanes kept failing. Read your inbox in order and pick up what was waiting."

# Each lane is healed on its own (state/<id>.lane-heal-<lane>), so a mate with
# both lanes failing has each raised, and one recovering never clears the
# other. Both lanes share one relaunch per scan.
lane_heal() {  # <id>
  local id=$1 lane_tag open key verb note supervisor_line='' conversation_line=''
  local LANE_RELAUNCHED_AT='' LANE_RELAUNCH_RC=0 LANE_RELAUNCH_OUT=''
  open=$(status_open_decisions_incremental "$STATE/$id.status")
  while IFS=$'\t' read -r key verb note; do
    [ "$verb" = blocked ] || continue
    case "$key" in
      "supervisor-failing-$id") supervisor_line="blocked [key=$key]: $note" ;;
      "conversation-failing-$id") conversation_line="blocked [key=$key]: $note" ;;
    esac
  done <<EOF
$open
EOF
  for lane_tag in supervisor conversation; do
    case "$lane_tag" in
      supervisor) lane_heal_one "$id" "$lane_tag" "$supervisor_line" || return 0 ;;
      conversation) lane_heal_one "$id" "$lane_tag" "$conversation_line" || return 0 ;;
    esac
  done
}

# Returns 1 only when the mate was stopped on purpose meanwhile, so the caller
# leaves its other lane alone too.
lane_heal_one() {  # <id> <supervisor|conversation>
  local id=$1 tag=$2 rec="$STATE/$1.lane-heal-$2" key="$2-failing-$1" line=$3 now first relaunched escalated out rc lane episode relaunch_error
  now=$(date +%s)
  case "$tag" in supervisor) lane="inner monologue (supervisor)" ;; *) lane="conversation lane" ;; esac
  if [ -z "$line" ]; then
    [ -f "$rec" ] || return 0
    if [ "$(sed -n 's/^escalated=//p' "$rec")" = 1 ]; then
      fm_wake_append check "lane-heal:$id:$tag:$now" \
        "check: second mate $id recovered: its $lane is working again; clear its blocker" || return 0
    fi
    rm -f "$rec"
    log "$id $lane recovered"
    return 0
  fi
  # An episode is the exact blocked event (it carries its since), so a lane
  # that recovered and failed again is a new episode, never the old one.
  episode=$(printf '%s' "$line" | cksum | cut -d' ' -f1)
  if [ "$(sed -n 's/^episode=//p' "$rec" 2>/dev/null)" != "$episode" ]; then
    printf 'key=%s\nepisode=%s\nlane=%s\nfirst_seen=%s\nrelaunched=0\nescalated=0\n' "$key" "$episode" "$lane" "$now" > "$rec.tmp" && mv -f "$rec.tmp" "$rec"
  fi
  first=$(sed -n 's/^first_seen=//p' "$rec"); relaunched=$(sed -n 's/^relaunched=//p' "$rec")
  escalated=$(sed -n 's/^escalated=//p' "$rec")
  [ "$escalated" != 1 ] || return 0
  relaunch_error=$(sed -n 's/^relaunch_error=//p' "$rec")
  if [ "$relaunched" = 0 ]; then
    if [ -z "$LANE_RELAUNCHED_AT" ]; then
      LANE_RELAUNCHED_AT=$now
      LANE_RELAUNCH_OUT=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --unless-held-stopped --replace-live --note "$HEAL_NOTE" < /dev/null 2>&1) || LANE_RELAUNCH_RC=$?
    fi
    rc=$LANE_RELAUNCH_RC
    out=$LANE_RELAUNCH_OUT
    if [ "$rc" -ne 0 ]; then
      case "$out" in
        *"another lifecycle action is already running"*) return 0 ;;
        *"was stopped on purpose"*) rm -f "$STATE/$id.lane-heal-supervisor" "$STATE/$id.lane-heal-conversation"; return 1 ;;
      esac
      relaunch_error=$(one_line "$out")
      [ -n "$relaunch_error" ] || relaunch_error="exit $rc"
      log "relaunch of $id for its failing $lane failed: $relaunch_error"
    else
      log "relaunched $id because its $lane kept failing"
    fi
    relaunched=$LANE_RELAUNCHED_AT
    printf 'key=%s\nepisode=%s\nlane=%s\nfirst_seen=%s\nrelaunched=%s\nescalated=0\nrelaunch_error=%s\n' \
      "$key" "$episode" "$lane" "$first" "$relaunched" "$relaunch_error" > "$rec.tmp" && mv -f "$rec.tmp" "$rec"
    [ "$rc" -ne 0 ] || return 0
  elif [ -z "$relaunch_error" ] && [ $((now - relaunched)) -lt "$HEAL_GRACE" ]; then
    return 0
  fi
  [ -z "$relaunch_error" ] || line="$line (an automatic relaunch failed: $relaunch_error)"
  if fm_wake_append check "lane-heal:$id:$episode" \
      "check: second mate $id is stuck: its $lane keeps failing after an automatic relaunch; tell the captain. Its report: ${line#blocked }"; then
    log "escalated $id: its $lane is still failing"
    printf 'key=%s\nepisode=%s\nlane=%s\nfirst_seen=%s\nrelaunched=%s\nescalated=1\n' "$key" "$episode" "$lane" "$first" "$relaunched" > "$rec.tmp" \
      && mv -f "$rec.tmp" "$rec"
  fi
  return 0
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
