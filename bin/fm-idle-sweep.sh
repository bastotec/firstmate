#!/usr/bin/env bash
# fm-idle-sweep.sh - guarded cleanup, retries and first-mate handoffs for this home's
# eligible idle workers, without waiting for a model turn.
#
# Usage:
#   fm-idle-sweep.sh scan [--now]
#   fm-idle-sweep.sh summary
#
# The home's watcher (bin/fm-watch.sh) runs `scan` detached on its own cadence,
# so finished-worker cleanup and idle-worker decisions do not depend on a
# model turn reaching .agents/skills/task-delivery's finished-work sweep.
# `scan --now` bypasses the cadence for an operator-triggered sweep, but not
# the home-scoped scan lock or any eligibility or cleanup guard.
#
# One scan, over THIS home's own non-secondmate records only (a home never
# acts on another home's records; secondmates retire only on a decision):
#   - a record already held for the captain, or parked on a settled deferral
#     (bin/fm-captain-hold.sh open / deferred), is left to that decision;
#     an unreadable hold or deferral probe on the worker or its follow-up
#     leaves it untouched this scan, with summary class unknown/action none;
#     the same fail-closed admission applies to record-less endpoints below;
#   - otherwise the recorded worktree's slot-owner claim is checked first;
#     a claim naming another task classifies this record as dead, never done
#     from the claimant's run; all other records take one bin/fm-crew-state.sh
#     read bounded to 60 seconds; age is the time since the status ledger
#     (else metadata record) changed;
#   - working or parked, or done with its PR (recorded, or the last PR link in
#     its ledger) still open or unreadable: left alone;
#   - a done ship with no PR, or a closed-unmerged PR, is never cleaned up
#     automatically, since a pushed but unmerged branch passes cleanup's checks;
#     it becomes the clean-it-up-or-keep-it decision below;
#   - otherwise done, quiet for 15 minutes (a ship's PR must be merged):
#     cleaned up with bin/fm-teardown.sh --keep-commits, never --force;
#     teardown's header owns committed-work preservation and its limits.
#     The sweep passes the PR/MR URL it verified to teardown and to the
#     bin/fm-retire-endpoint.sh --finished fallback when the only refusal
#     is an endpoint on a retired backend;
#     a refusal because another cleanup or lifecycle action holds the task
#     waits for the next scan; after a refusal, a now-absent worker record is
#     reported as cleaned unless its backlog close is still pending (then
#     unhandled),
#     while a changed record is left untouched with class unknown/action none
#     for a fresh scan; a remaining refusal on the unchanged record goes to
#     the first mate (raise below);
#   - failed, blocked, paused, or unknown with its endpoint or copy gone,
#     quiet for 6 hours: the sweep decides, never the captain (his rule of
#     2026-10-18). It retires the worker when its work is done, merged,
#     superseded or abandoned (backlog item done or superseded, or its PR
#     merged or closed), through the same cleanup that saves leftover commits
#     on a kept/ branch; it retries it once per stopped stretch with
#     bin/fm-control.sh relaunch when the work is still wanted and unfinished;
#     an unavailable backend without evidence that the endpoint or copy is
#     gone is left alone.
#   Then this home's record-less live endpoints are listed through
#   bin/fm-retire-endpoint.sh --list-orphans. Before --orphan closure, holds
#   and settled deferrals on idle-orphan-<task> (or its follow-up), and an
#   unchanged raised fingerprint of the actual task's ledger, leave the
#   endpoint alone; otherwise a refused close goes to the first mate.
# Metadata-less pending backlog closes also appear as unhandled on every scan
# until the lifecycle owner clears them; the sweep reports but never retries
# or changes those recovery records.
# Anything the sweep cannot settle itself (a refused cleanup or retirement, a
# failed retry, a worker that stopped again after its retry, or an unreadable
# full backlog item or PR state) goes to the home's own first mate, never to
# the captain as a card: a second mate appends one
# "needs-decision [key=idle-<id>]" line to its parent channel, including the
# ledger fingerprint as an episode stamp so a resolved earlier handoff cannot
# suppress a new stopped stretch. The first mate's own home lists it in the
# end-of-scan wake below. Each hand-off records
# the worker's ledger byte count under state/idle-sweep/<id>.raised only after
# parent-channel delivery or the main-home wake append succeeds. Each retry is
# recorded under state/idle-sweep/<id>.retried (ledger size and retry count; at
# most two retries per worker); an unchanged size suppresses a repeat. A failed
# relaunch that published its own replacement record also consumes a retry and
# goes to the first mate; its transaction identity distinguishes it from an
# unrelated replacement, which is left for a fresh scan. An
# existing captain hold or settled deferral on the worker or on idle-<id>
# still takes precedence.
# Cleanup and retry pass the classified metadata snapshot to their lifecycle
# owners for a locked check; a changed record is left for a fresh scan with
# class unknown/action none. Both also pass the classified status byte count
# through --if-still-stopped, with --expected-state done for finished-worker
# cleanup; the lifecycle owners' headers own the late activity checks.
# A foreign or unreadable slot owner refuses a
# retry and goes to the first mate, never relaunching into another task's copy.
# A main home has no parent audit, so a scan that leaves workers unhandled
# queues ONE `check:` wake keyed idle-sweep-unhandled:<epoch>, naming those ids.
# state/idle-sweep/.unhandled stores the sorted id set after a successful queue
# append; unchanged sets suppress repeat wakes, changed sets queue a new one,
# and a scan with no unhandled workers clears the marker so recurrence wakes again.
# Secondmate homes leave unhandled workers to the parent audit below.
# In a main home, a scan that retired, retried or handed off any worker queues
# ONE `check:` wake keyed idle-sweep:<epoch>: an FYI for what it settled and the
# list the first mate decides itself, never as a captain card.
#
# A home that records second mates also audits them: each mate's own sweep
# must publish a summary no more than 6 hours old, read from the
# local home's state/idle-sweep.json or over bin/fm-on.sh `summary` for a
# remote one, bounded to 60 seconds. An ssh transport failure (exit 255) or
# read timeout (exit 124) proves nothing and is skipped. A missing local home
# or state directory counts as a missing summary, which escalates only once it
# has stayed missing for 6 hours (state/<mate>.idle-audit-missing marks when the
# audit first saw none), so a mate that has not swept yet after an update is
# not escalated at once. A missing-for-6h or stale summary,
# or one listing a worker the mate could neither clean up nor raise, queues
# ONE `check:` wake keyed
# idle-sweep-audit:<mate>:<epoch> per episode; a fresh clean summary ends it.
#
# `summary` prints the last scan's state/idle-sweep.json
# (schema fm-idle-sweep.v1: generated, generated_epoch, home, workers[] of
# {id, class, age_seconds, detail, action, hold_id}); hold_id is retained for
# compatibility and is always null in new scans; no captain call is created.
# Action is one of none, cleaned, retired, retried, asked (handed to the first
# mate), or unhandled. Refused orphan closes are included even when their
# handoff fails; held or unchanged raised orphans appear with action none.
# Exit 1 when no scan has published a summary yet.
#
# Environment knobs:
#   FM_HOME                        required
#   FM_IDLE_SWEEP_SECS             scan cadence; `scan` without --now is a
#                                  no-op until this long after the last (1800)
#
# Exit: 0 after a scan; 2 on invalid use.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

CMD=${1:-}
case "$CMD" in
  -h|--help) usage; exit 0 ;;
  scan|summary) shift ;;
  *) usage >&2; exit 2 ;;
esac
NOW_FLAG=0
case "${1:-}" in
  '') ;;
  --now) [ "$CMD" = scan ] || { usage >&2; exit 2; }; NOW_FLAG=1 ;;
  *) usage >&2; exit 2 ;;
esac

[ -n "${FM_HOME:-}" ] && [ -d "$FM_HOME" ] || {
  echo "error: FM_HOME must name a firstmate home" >&2
  exit 2
}
export FM_HOME
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
SUMMARY="$STATE/idle-sweep.json"

if [ "$CMD" = summary ]; then
  [ -f "$SUMMARY" ] || exit 1
  cat "$SUMMARY"
  exit 0
fi
[ -d "$STATE" ] || exit 0

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-parent-channel-lib.sh
. "$SCRIPT_DIR/fm-parent-channel-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

num_or() {  # <value> <default>
  case "$1" in ''|*[!0-9]*) printf '%s' "$2" ;; *) printf '%s' "$1" ;; esac
}
SWEEP_SECS=$(num_or "${FM_IDLE_SWEEP_SECS:-}" 1800)
RAISED_DIR="$STATE/idle-sweep"
LOG="$STATE/idle-sweep.log"
LOCK="$STATE/.idle-sweep.lock"
NOW=$(date +%s)

log() {  # <line>
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$LOG" 2>/dev/null || true
}

one_line() {  # <text> -> first meaningful line, folded and bounded
  printf '%s\n' "$1" | sed -n '/^warning: /d;/^A new version of treehouse/d;/^Run "treehouse update"/d;/./{s/[[:space:]]\{1,\}/ /g;p;q;}' | cut -c1-200
}

mtime_of() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    /usr/bin/stat -f %m "$1" 2>/dev/null
  else
    stat -c %Y "$1" 2>/dev/null
  fi
}

size_of() {  # <path>
  local size
  if size=$(wc -c 2>/dev/null < "$1"); then
    printf '%s' "$size" | tr -d '[:space:]'
  else
    printf 0
  fi
}

record_age() {  # <id>
  local t
  t=$(mtime_of "$STATE/$1.status") || t=
  [ -n "$t" ] || t=$(mtime_of "$STATE/$1.meta") || t=
  [ -n "$t" ] || { printf 0; return; }
  printf '%s' $((NOW - t))
}

hold_settled() {  # <id>... -> 0 held/deferred, 1 confirmed absent, 2 unreadable
  local id predicate rc
  for id in "$@"; do
    for predicate in open deferred; do
      rc=0
      FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-captain-hold.sh" "$predicate" "$id" >/dev/null 2>&1 || rc=$?
      [ "$rc" -eq 1 ] || return "$rc"
    done
  done
  return 1
}

fingerprint() {  # <id>
  printf '%s\n' "$(size_of "$STATE/${2:-$1}.status")"
}

already_raised() {  # <id>
  [ -f "$RAISED_DIR/$1.raised" ] && [ "$(cat "$RAISED_DIR/$1.raised" 2>/dev/null)" = "$(fingerprint "$1" "${2:-$1}")" ]
}

# classify <id>: sets CLASS, DETAIL, AGE
classify() {
  local id=$1 line verb worktree row pr pr_state hold_rc=0
  UNPROVEN=0
  MERGED_PR_URL=
  AGE=$(record_age "$id")
  DETAIL=
  hold_settled "$id" "idle-$id" || hold_rc=$?
  case "$hold_rc" in
    0) CLASS=held; return ;;
    1) ;;
    *) CLASS=unknown; DETAIL="captain hold could not be read"; return ;;
  esac
  worktree=$(fm_meta_get "$STATE/$id.meta" worktree)
  fm_treehouse_slot_owner_state "$worktree" "$id"
  if [ "$FM_TREEHOUSE_SLOT_OWNER" = other ]; then
    line="state: unknown · source: none · recorded copy gone: slot reassigned to $FM_TREEHOUSE_SLOT_OWNER_ID"
  else
    line=$(fm_run_timed 60 \
      "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | head -1) || true
  fi
  verb=$(printf '%s' "$line" | sed -n 's/^state: \([a-z]*\).*/\1/p')
  DETAIL=$(printf '%s' "$line" | sed 's/^state: [a-z]* · source: [a-z-]* · //' | cut -c1-200)
  case "$verb" in
    working|parked) CLASS=active; return ;;
    done)
      CLASS=finished
      [ "$AGE" -ge 900 ] || { CLASS=settling; return; }
      row=$(fm_backlog_row_show "${FM_DATA_OVERRIDE:-$FM_HOME/data}" "$id" --full 2>/dev/null) || row=
      pr=$(fm_pr_task_url "$row" "$STATE/$id.meta") || pr=
      # a worker reports its PR in its ledger before firstmate records it
      [ -n "$pr" ] || pr=$(grep -Eo 'https://[^[:space:]]+/(pull|merge_requests)/[0-9]+' \
        "$STATE/$id.status" 2>/dev/null | tail -1) || pr=
      if [ -n "$pr" ]; then
        # shellcheck disable=SC2016 # Positional arguments expand in the child shell.
        pr_state=$(fm_run_timed 60 bash -c '. "$1/fm-pr-lib.sh"; fm_pr_live_state "$2"' \
          _ "$SCRIPT_DIR" "$pr" 2>/dev/null) || pr_state=
        case "$pr_state" in
          merged) MERGED_PR_URL=$pr ;;
          open) CLASS=awaiting-merge; return ;;
          closed) UNPROVEN=1 ;;
          *) CLASS=settling; DETAIL="cannot read whether $pr merged"; return ;;
        esac
      elif [ "$(fm_meta_get "$STATE/$id.meta" kind)" != scout ]; then
        # nothing proves a ship without a PR landed, so it is never cleaned up
        # automatically: a pushed, unmerged branch would pass cleanup's checks
        UNPROVEN=1
      fi
      ;;
    failed) CLASS=failed ;;
    blocked|paused) CLASS=stalled ;;
    unknown)
      case "$DETAIL" in
        *gone*) CLASS=dead ;;
        *) CLASS=settling; return ;;
      esac
      ;;
    *) CLASS=settling; return ;;
  esac
  if [ "$CLASS" != finished ] && [ "$CLASS" != settling ] && [ "$AGE" -lt 21600 ]; then
    CLASS=settling
  fi
  if [ "$CLASS" != settling ] && already_raised "$id"; then
    CLASS=raised
  fi
}

hours() {  # <secs>
  printf '%s hours' $(($1 / 3600))
}

# raise <id> <class> <why> [ledger-id]: hand a worker this
# home could not settle itself to its own first mate, never to the captain (the
# captain's 2026-10-18 rule: "i dont want to make those decisions"). A second
# mate appends one "needs-decision [key=idle-<id>]" line to its parent channel;
# the first mate's own home queues one check: wake for its supervisor, which
# decides retire or retry. Sets RAISED=1 on success; the worker's ledger
# fingerprint suppresses a repeat until the ledger changes.
raise() {
  local id=$1 class=$2 why=$3 ledger_id=${4:-$1} line episode rc=0
  HOLD_ID=
  episode=$(fingerprint "$id" "$ledger_id")
  case "$class" in
    finished) line="worker $id is done, but its cleanup was refused ($why); decide whether to clean it up or keep it" ;;
    *) line="worker $id stopped ($class: $why) and I could not settle it myself; decide whether to retire or retry it" ;;
  esac
  fm_parent_channel_report "$FM_HOME" "$STATE" "needs-decision [key=idle-$id]: [episode=$episode] $(fm_parent_channel_clean_note "$line")" || rc=$?
  case "$rc" in
    0)
      mkdir -p "$RAISED_DIR" 2>/dev/null || true
      printf '%s\n' "$episode" > "$RAISED_DIR/$id.raised" 2>/dev/null || true
      ;;
    1)
      PENDING_RAISED="$PENDING_RAISED$(jq -cn --arg id "$id" --arg fingerprint "$episode" '{id:$id,fingerprint:$fingerprint}')"$'\n'
      ;;
    *) log "could not hand $id to the first mate"; return 0 ;;
  esac
  log "asked the first mate about $id ($class): $why"
  RAISED=1
}

# decide_stopped <id>: the mate's own call on a worker that stopped (failed,
# blocked or paused for 6 hours, or its endpoint gone). Retire it when its work
# is done, merged, superseded or abandoned (its backlog item is done, or its PR
# merged or closed): cleanup saves leftover commits on a kept/ branch first.
# Retry it when the work is still wanted and unfinished: one relaunch per
# stopped stretch through bin/fm-control.sh. Anything it cannot settle goes to
# raise above. Sets STOPPED_ACTION to retired, retried or asked.
decide_stopped() {
  local id=$1 row body pr pr_state retire=0 out rc=0 tries count retry_tx partial=0
  STOPPED_ACTION=
  if ! row=$(fm_backlog_row_show "${FM_DATA_OVERRIDE:-$FM_HOME/data}" "$id" --full 2>/dev/null) \
      || ! printf '%s\n' "$row" | grep -qE '^  state: (queued|in_flight|done)$' \
      || ! body=$(fm_pr_task_body "$row" 2>/dev/null); then
    RAISED=0
    raise "$id" "$CLASS" "the full backlog item could not be read"
    STOPPED_ACTION=asked
    return 0
  fi
  case "$row" in *$'\n'"  state: done"*) retire=1 ;; esac
  if fm_pr_superseded_recorded "$body"; then retire=1; fi
  pr=$(fm_pr_task_url "$row" "$STATE/$id.meta") || pr=
  [ -n "$pr" ] || pr=$(grep -Eo 'https://[^[:space:]]+/(pull|merge_requests)/[0-9]+' "$STATE/$id.status" 2>/dev/null | tail -1) || pr=
  if [ -n "$pr" ]; then
    # shellcheck disable=SC2016 # Positional arguments expand in the child shell.
    pr_state=$(fm_run_timed 60 bash -c '. "$1/fm-pr-lib.sh"; fm_pr_live_state "$2"' _ "$SCRIPT_DIR" "$pr" 2>/dev/null) || pr_state=
    case "$pr_state" in
      merged) retire=1; MERGED_PR_URL=$pr ;;
      closed) retire=1 ;;
      open) ;;
      *)
        RAISED=0
        raise "$id" "$CLASS" "the PR state could not be read: $pr"
        STOPPED_ACTION=asked
        return 0
        ;;
    esac
  fi
  if [ "$retire" = 1 ]; then
    if cleanup "$id" "$stopped_status_size"; then
      STOPPED_ACTION=retired
      log "retired $id: its work is done, merged, superseded or abandoned"
      return 0
    fi
    if [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] && [ -e "$STATE/$id.backlog-close" ]; then
      STOPPED_ACTION=unhandled
      DETAIL="its record is gone but its backlog close is still pending: $CLEANUP_WHY"
      return 0
    fi
    if [ "$CLEANUP_STALE" = 1 ]; then
      CLASS=unknown
      DETAIL="worker record or activity changed during scan"
      return 0
    fi
    RAISED=0
    raise "$id" "$CLASS" "retiring it was refused: $CLEANUP_WHY"
    STOPPED_ACTION=asked
    return 0
  fi
  if [ "$(cat "$STATE/$id.meta" 2>/dev/null)" != "$record" ]; then
    CLASS=unknown
    DETAIL="worker record or activity changed during scan"
    return 0
  fi
  fm_treehouse_slot_owner_state "$(fm_meta_get "$STATE/$id.meta" worktree)" "$id"
  case "$FM_TREEHOUSE_SLOT_OWNER" in
    other|unsafe)
      RAISED=0
      raise "$id" "$CLASS" "its local copy has a conflicting or unreadable slot owner"
      STOPPED_ACTION=asked
      return 0
      ;;
  esac
  # One retry per stopped stretch, and at most two in all: a worker that
  # stops again without progress, or keeps stopping, goes to the first mate.
  tries=$(cat "$RAISED_DIR/$id.retried" 2>/dev/null || true)
  count=${tries#* }
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  if [ "${tries%% *}" = "$(fingerprint "$id")" ] || [ "$count" -ge 2 ]; then
    RAISED=0
    raise "$id" "$CLASS" "it stopped again after $count automatic retries: $DETAIL"
    STOPPED_ACTION=asked
    return 0
  fi
  retry_tx="idle-sweep.${BASHPID:-$$}.$(date -u +%Y%m%dT%H%M%SZ).$RANDOM"
  out=$(FM_HOME="$FM_HOME" FM_CONTROL_RELAUNCH_TX="$retry_tx" "$SCRIPT_DIR/fm-control.sh" "$id" relaunch --expected-record "$record" \
    --if-still-stopped "$stopped_status_size" \
    --note 'Restarted by the idle sweep: your task is still open and unfinished. Read your inbox in order and continue it.' </dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$(fm_meta_get "$STATE/$id.meta" control_relaunch_tx)" = "$retry_tx" ] \
      && [ "$(cat "$STATE/$id.meta" 2>/dev/null)" != "$record" ] \
      && [ "$(fm_meta_get "$STATE/$id.control-relaunch" relaunch_tx)" = "$retry_tx" ] \
      && [ "$(cat "$STATE/$id.control-relaunch.meta-prior" 2>/dev/null)" = "$record" ]; then
      partial=1
    fi
  fi
  if [ "$rc" -eq 0 ] || [ "$partial" = 1 ]; then
    mkdir -p "$RAISED_DIR" 2>/dev/null || true
    printf '%s %s\n' "$(fingerprint "$id")" "$((count + 1))" > "$RAISED_DIR/$id.retried" 2>/dev/null || true
    if [ "$rc" -eq 0 ]; then
      STOPPED_ACTION=retried
      log "retried $id: its work is still wanted and unfinished"
      return 0
    fi
  elif [ "$rc" -eq 3 ] || [ "$(cat "$STATE/$id.meta" 2>/dev/null)" != "$record" ]; then
    CLASS=unknown
    DETAIL="worker record or activity changed during scan"
    return 0
  fi
  RAISED=0
  raise "$id" "$CLASS" "retrying it failed: $(one_line "$out")"
  STOPPED_ACTION=asked
}

# cleanup <id>: guarded teardown of a finished worker. 0 = cleaned; else
# CLEANUP_WHY holds the refusal.
cleanup() {
  local id=$1 out rc=0 args
  args=("$id" --keep-commits --expected-record "$record")
  [ -z "${2:-}" ] || args+=(--if-still-stopped "$2")
  [ "$CLASS" != finished ] || args+=(--expected-state 'done')
  [ -z "$MERGED_PR_URL" ] || args+=(--merged-pr "$MERGED_PR_URL")
  CLEANUP_WHY=
  CLEANUP_STALE=0
  # --keep-commits: leftover local commits after a merged PR are saved on a
  # kept/ branch rather than raised (housekeeping is never a captain call).
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-teardown.sh" "${args[@]}" </dev/null 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if [ "$rc" -eq 3 ] || [ "$(cat "$STATE/$id.meta" 2>/dev/null)" != "$record" ]; then
    CLEANUP_STALE=1
    CLEANUP_WHY="worker record changed during scan"
    return 1
  fi
  if printf '%s' "$out" | grep -q "on the retired '"; then
    rc=0
    args=(--finished "$id" --expected-record "$record")
    [ -z "${2:-}" ] || args+=(--if-still-stopped "$2")
    [ "$CLASS" != finished ] || args+=(--expected-state 'done')
    [ -z "$MERGED_PR_URL" ] || args+=(--merged-pr "$MERGED_PR_URL")
    out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-retire-endpoint.sh" "${args[@]}" </dev/null 2>&1) || rc=$?
    [ "$rc" -eq 0 ] && return 0
    if [ "$rc" -eq 3 ] || [ "$(cat "$STATE/$id.meta" 2>/dev/null)" != "$record" ]; then
      CLEANUP_STALE=1
      CLEANUP_WHY="worker record changed during scan"
      return 1
    fi
  fi
  CLEANUP_WHY=$(printf '%s\n' "$out" | grep -m1 -E '^(REFUSED|error|refus)' || true)
  [ -n "$CLEANUP_WHY" ] || CLEANUP_WHY=$out
  CLEANUP_WHY=$(one_line "$CLEANUP_WHY")
  CLEANUP_WHY=${CLEANUP_WHY#REFUSED: }
  CLEANUP_WHY=${CLEANUP_WHY#error: }
  return 1
}

worker_metas() {
  local m
  for m in "$STATE"/*.meta; do
    [ -f "$m" ] || continue
    [ "$(fm_meta_get "$m" kind)" = secondmate ] && continue
    printf '%s\n' "$m"
  done
}

# --- scan ---------------------------------------------------------------------
if [ "$NOW_FLAG" -eq 0 ] && [ -e "$STATE/.last-idle-sweep" ]; then
  last=$(mtime_of "$STATE/.last-idle-sweep") || last=0
  [ $((NOW - last)) -ge "$SWEEP_SECS" ] || exit 0
fi
fm_lock_try_acquire "$LOCK" || exit 0
trap 'fm_lock_release "$LOCK" >/dev/null 2>&1 || true' EXIT
touch "$STATE/.last-idle-sweep"

RAISED=0
NEW=
PENDING_RAISED=
ROWS=
add_row() {  # <id> <class> <detail> <action>
  ROWS="$ROWS$(jq -cn --arg id "$1" --arg class "$2" --argjson age "$AGE" \
    --arg detail "$3" --arg action "$4" --arg hold_id "${HOLD_ID:-}" \
    '{id:$id,class:$class,age_seconds:$age,detail:$detail,action:$action,
      hold_id:(if $hold_id=="" then null else $hold_id end)}')"$'\n'
}

while IFS= read -r meta; do
  id=$(basename "$meta" .meta)
  record=$(cat "$meta" 2>/dev/null) || continue
  stopped_status_size=$(fingerprint "$id")
  classify "$id"
  action=none
  HOLD_ID=
  case "$CLASS" in
    finished)
      if [ "$UNPROVEN" = 1 ]; then
        CLEANUP_WHY="no merged PR is recorded for it, so nothing proves its work landed"
        RAISED=0
        raise "$id" finished "$CLEANUP_WHY"
        if [ "$RAISED" = 1 ]; then action=asked; NEW="$NEW $id"; else action=unhandled; fi
        DETAIL=$CLEANUP_WHY
      elif cleanup "$id" "$stopped_status_size"; then
        action=cleaned
        log "cleaned up $id"
      elif [ ! -e "$meta" ] && [ ! -L "$meta" ] && [ -e "$STATE/$id.backlog-close" ]; then
        action=unhandled
        DETAIL="its record is gone but its backlog close is still pending: $CLEANUP_WHY"
      elif [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
        action=cleaned
        DETAIL="worker record already removed"
      elif [ "$CLEANUP_STALE" = 1 ]; then
        CLASS=unknown
        DETAIL="worker record or activity changed during scan"
      elif printf '%s' "$CLEANUP_WHY" | grep -Eq '^another lifecycle action is already running for task |^another Treehouse slot allocation or return is in progress for '; then
        CLASS=settling
        DETAIL="another cleanup or lifecycle action holds it: $CLEANUP_WHY"
      else
        RAISED=0
        raise "$id" finished "$CLEANUP_WHY"
        if [ "$RAISED" = 1 ]; then action=asked; NEW="$NEW $id"; else action=unhandled; fi
        DETAIL=$CLEANUP_WHY
      fi
      ;;
    failed|stalled|dead)
      RAISED=0
      decide_stopped "$id"
      case "$STOPPED_ACTION" in
        retired|retried) action=$STOPPED_ACTION; NEW="$NEW $id" ;;
        unhandled) action=unhandled ;;
        asked) if [ "$RAISED" = 1 ]; then action=asked; NEW="$NEW $id"; else action=unhandled; fi ;;
      esac
      ;;
  esac
  add_row "$id" "$CLASS" "$DETAIL" "$action"
done < <(worker_metas)

for marker in "$STATE"/*.backlog-close; do
  [ -e "$marker" ] || [ -L "$marker" ] || continue
  id=$(basename "$marker" .backlog-close)
  [ ! -e "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] || continue
  printf '%s' "$ROWS" | jq -se --arg id "$id" 'any(.[]; .id==$id)' >/dev/null && continue
  AGE=$(record_age "$id")
  HOLD_ID=
  add_row "$id" unknown "its record is gone but its backlog close is still pending" unhandled
done

# Record-less live endpoints: sweep admission precedes the orphan close's
# independent endpoint and work-protection checks.
orphans=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-retire-endpoint.sh" --list-orphans 2>/dev/null) || orphans=
while IFS=$'\t' read -r otask oeid; do
  [ -n "$otask" ] && [ -n "$oeid" ] || continue
  AGE=0
  HOLD_ID=
  detail="endpoint $oeid for $otask has no record"
  hold_rc=0
  hold_settled "idle-orphan-$otask" "idle-idle-orphan-$otask" || hold_rc=$?
  case "$hold_rc" in
    0) add_row "idle-orphan-$otask" held "$detail" none; continue ;;
    1) ;;
    *) add_row "idle-orphan-$otask" unknown "$detail; captain hold could not be read" none; continue ;;
  esac
  if already_raised "idle-orphan-$otask" "$otask"; then
    add_row "idle-orphan-$otask" raised "$detail" none
    continue
  fi
  rc=0
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-retire-endpoint.sh" --orphan "$otask" --endpoint "$oeid" </dev/null 2>&1) || rc=$?
  if [ "$rc" -eq 0 ]; then
    log "closed orphan endpoint $oeid ($otask)"
    add_row "idle-orphan-$otask" dead "$detail" cleaned
    continue
  fi
  detail="$detail and its close refused: $(one_line "$out")"
  RAISED=0
  raise "idle-orphan-$otask" dead "$detail" "$otask"
  if [ "$RAISED" = 1 ]; then action=asked; NEW="$NEW idle-orphan-$otask"; else action=unhandled; fi
  add_row "idle-orphan-$otask" dead "$detail" "$action"
done <<< "$orphans"

# --- second-mate audit ----------------------------------------------------------
audit_mate() {  # <meta>
  local meta=$1 mate home host json rc=0 gen stale='' rec miss first
  mate=$(basename "$meta" .meta)
  rec="$STATE/$mate.idle-audit"
  home=$(fm_meta_get "$meta" home)
  host=$(fm_meta_get "$meta" remote_host)
  if [ -n "$host" ]; then
    json=$(fm_run_timed 60 "$SCRIPT_DIR/fm-on.sh" "$mate" fm-idle-sweep.sh summary 2>/dev/null) || rc=$?
    [ "$rc" -eq 255 ] && return 0
    [ "$rc" -eq 124 ] && return 0
  else
    json=
    if [ -n "$home" ]; then
      json=$(cat "$home/state/idle-sweep.json" 2>/dev/null) || rc=1
    else
      rc=1
    fi
  fi
  miss="$STATE/$mate.idle-audit-missing"
  if [ "$rc" -ne 0 ] || [ -z "$json" ]; then
    # A mate gets one bound to publish its first sweep (it may simply not have
    # run one yet after an update), measured from when this audit first saw none.
    [ -f "$miss" ] || touch "$miss" 2>/dev/null || true
    first=$(mtime_of "$miss") || first=$NOW
    [ $((NOW - first)) -ge 21600 ] || return 0
    stale="it has not published a cleanup sweep in $(hours $((NOW - first)))"
  else
    rm -f "$miss" 2>/dev/null || true
    gen=$(printf '%s' "$json" | jq -r '.generated_epoch // 0' 2>/dev/null) || gen=0
    gen=$(num_or "$gen" 0)
    if [ $((NOW - gen)) -gt 21600 ]; then
      stale="its last cleanup sweep was $(hours $((NOW - gen))) ago"
    else
      local left
      left=$(printf '%s' "$json" | jq -r '[.workers[]? | select(.action=="unhandled") | .id] | join(" ")' 2>/dev/null) || left=
      [ -z "$left" ] || stale="it could neither clean up nor raise: $left"
    fi
  fi
  if [ -z "$stale" ]; then
    rm -f "$rec" 2>/dev/null || true
    return 0
  fi
  [ -f "$rec" ] && return 0
  if fm_wake_append check "idle-sweep-audit:$mate:$NOW" \
    "check: second mate $mate is not cleaning up its idle workers: $stale"; then
    printf 'escalated=%s\nwhy=%s\n' "$NOW" "$stale" > "$rec" 2>/dev/null || true
    log "escalated second mate $mate: $stale"
  fi
}

while IFS= read -r meta; do
  [ -f "$meta" ] || continue
  [ "$(fm_meta_get "$meta" kind)" = secondmate ] || continue
  audit_mate "$meta"
done < <(printf '%s\n' "$STATE"/*.meta)

# --- publish ----------------------------------------------------------------------
generated=$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)
if tmp=$(mktemp "$STATE/.idle-sweep.json.XXXXXX"); then
  if printf '%s' "$ROWS" | jq -s --arg home "$FM_HOME" --argjson epoch "$NOW" --arg generated "$generated" \
    '{schema:"fm-idle-sweep.v1", generated:$generated, generated_epoch:$epoch, home:$home, workers:.}' \
    > "$tmp" && chmod 600 "$tmp" && mv -f "$tmp" "$SUMMARY"; then
    :
  else
    rm -f "$tmp" 2>/dev/null
    log "could not publish $SUMMARY"
  fi
fi

prc=0
fm_parent_channel_destination "$FM_HOME" "$STATE" >/dev/null 2>&1 || prc=$?
# A main home has no parent to audit it, so anything this scan could neither
# clean up nor raise wakes it directly, once per distinct set.
if [ "$prc" -eq 1 ]; then
  left=$(printf '%s' "$ROWS" | jq -rs '[.[] | select(.action=="unhandled") | .id] | sort | join(" ")' 2>/dev/null) || left=
  seen="$RAISED_DIR/.unhandled"
  if [ -z "$left" ]; then
    rm -f "$seen" 2>/dev/null || true
  elif [ "$(cat "$seen" 2>/dev/null)" != "$left" ]; then
    mkdir -p "$RAISED_DIR" 2>/dev/null || true
    if fm_wake_append check "idle-sweep-unhandled:$NOW" "check: idle sweep could neither clean up nor raise: $left"; then
      printf '%s\n' "$left" > "$seen" 2>/dev/null || true
    fi
  fi
fi
if [ -n "$NEW" ]; then
  if [ "$prc" -eq 1 ]; then
    # FYI for what the sweep settled, and the workers only this first mate can
    # settle; the captain never gets a card for either.
    fyi=$(printf '%s' "$ROWS" | jq -rs '
      def ids(a): [.[] | select(.action==a) | .id] | join(" ");
      [ (ids("retired") | select(. != "") | "retired " + .),
        (ids("retried") | select(. != "") | "retried " + .),
        (ids("asked") | select(. != "") | "decide yourself whether to retire or retry " + .) ] | join("; ")' 2>/dev/null) || fyi=
    [ -n "$fyi" ] || fyi="settled:$NEW"
    if fm_wake_append check "idle-sweep:$NOW" "check: idle sweep: $fyi (never send the captain a card for these)"; then
      mkdir -p "$RAISED_DIR" 2>/dev/null || true
      while IFS=$'\t' read -r raised_id raised_fingerprint; do
        [ -n "$raised_id" ] || continue
        printf '%s\n' "$raised_fingerprint" > "$RAISED_DIR/$raised_id.raised" 2>/dev/null || true
      done < <(printf '%s' "$PENDING_RAISED" | jq -rs '.[] | [.id,.fingerprint] | @tsv')
    else
      log "could not queue the idle sweep wake for:$NEW"
    fi
  fi
fi
exit 0
