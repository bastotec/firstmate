#!/usr/bin/env bash
# fm-idle-sweep.sh - guarded cleanup and mate referrals for this home's
# eligible idle workers, without waiting for a model turn.
#
# Usage:
#   fm-idle-sweep.sh scan [--now]
#   fm-idle-sweep.sh summary
#
# The home's watcher (bin/fm-watch.sh) runs `scan` detached on its own cadence,
# so finished-worker cleanup and referrals do not wait for a model turn reaching
# .agents/skills/task-delivery's finished-work sweep; the mate still owns the
# retry or retirement assessment.
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
#   - an evidence-only withdrawn-parked disposition on the worker or follow-up
#     stays with its mate, never another retry card or automatic cleanup.
#     The first observation records the evidence; subsequent changes to the
#     ledger, metadata, crew-state result or local Git head/status wake the mate
#     once per change, without reopening the captain call.
#   - working or parked, or done with its PR (recorded, or the last PR link in
#     its ledger) still open or unreadable: left alone;
#   - a done ship with no PR, or a done worker with a closed-unmerged PR,
#     is referred to the owning mate to assess landing or documented supersession
#     through bin/fm-pr-lib.sh's completion-claim gate and guarded retirement,
#     once per evidence change, without automatic cleanup or a captain card;
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
#     for a fresh scan; a remaining refusal on the unchanged record is referred
#     to the owning mate for investigation, once per evidence change;
#   - failed, blocked, paused, or unknown with its endpoint or copy gone,
#     quiet for 6 hours: refer to the owning mate to decide retry or guarded
#     retirement, once per evidence change, without a captain card; an
#     unavailable backend without evidence that the endpoint or copy is gone
#     is left alone.
#   Then this home's record-less live endpoints are listed through
#   bin/fm-retire-endpoint.sh --list-orphans. Before --orphan closure, holds
#   and settled deferrals on idle-orphan-<task> (or its follow-up), durable
#   mate waits on those or the original task, and an unchanged raised
#   fingerprint of the actual task's ledger, leave the endpoint alone;
#   otherwise a refused close is referred to the owning mate under
#   idle-orphan-<task>, without a captain card or another close attempt until
#   the task ledger or endpoint identity changes.
# Metadata-less pending backlog closes also appear as unhandled on every scan
# until the lifecycle owner clears them; the sweep reports but never retries
# or changes those recovery records.
# Existing captain holds, settled deferrals, and legacy raised fingerprints
# remain admission guards; this sweep never creates a captain call.
# Mate referrals queue `check:` rows keyed idle-sweep-mate:<id>:<epoch>:<digest>.
# state/idle-sweep/<marker>.mate-review stores the last successfully queued
# referral evidence; <marker>.mate-wait stores the last observed durable wait.
# A worker's marker is its task ID; orphan markers add a SHA-256 endpoint suffix
# so endpoints belonging to the same task never overwrite each other's evidence.
# The evidence digest includes metadata, ledger, crew-state (excluding its
# observed timestamp), local Git head/status when available, and any probed
# withdrawal identity; closed-unmerged PR referrals also include the backlog row.
# Legacy <id>.raised markers contain the ledger byte count and are read only.
# tests/fm-idle-sweep.test.sh covers referrals, parked waits, cleanup guards,
# and watcher delivery.
# A main home has no parent audit, so a scan that leaves workers unhandled
# queues ONE `check:` wake keyed idle-sweep-unhandled:<epoch>, naming those ids.
# state/idle-sweep/.unhandled stores the sorted id set after a successful queue
# append; unchanged sets suppress repeat wakes, changed sets queue a new one,
# and a scan with no unhandled workers clears the marker so recurrence wakes again.
# Secondmate homes leave unhandled workers to the parent audit below.
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
# {id, class, age_seconds, detail, action, hold_id}); hold_id is null;
# action is one of none, cleaned, referred (to the owning mate), or unhandled.
# Refused orphan closes
# are included even when their referral fails; held or unchanged raised orphans
# appear with action none.
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
  wc -c < "$1" 2>/dev/null | tr -d ' ' || printf 0
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

mate_evidence() {
  local id=$1 worktree=$2 line=$3
  {
    cat "$STATE/$id.meta" "$STATE/$id.status" 2>/dev/null
    printf '%s\n' "${line%; observed=*}" "${4:-}"
    if [ -n "$worktree" ] && [ -d "$worktree" ]; then
      git -C "$worktree" rev-parse HEAD 2>/dev/null
      GIT_OPTIONAL_LOCKS=0 git -C "$worktree" status --porcelain 2>/dev/null
    fi
  } | shasum -a 256
}

notify_mate() {
  local id=$1 evidence=$2 mode=$3 previous marker
  marker="$RAISED_DIR/${4:-$id}.$mode"
  mkdir -p "$RAISED_DIR" || return 1
  previous=$(cat "$marker" 2>/dev/null) || previous=
  if [ "$previous" != "$evidence" ] && { [ "$mode" = mate-review ] || [ -n "$previous" ]; }; then
    fm_wake_append check "idle-sweep-mate:$id:$NOW:${evidence%% *}" \
      "check: mate must reassess worker $id; decide retry for still-wanted unfinished work or guarded retirement for completed, merged, superseded or abandoned work; preserve leftovers and escalate uncertainty to the parent mate" || return 1
  fi
  printf '%s\n' "$evidence" > "$marker"
}

mate_disposition() {
  local id=$1 ledger_id=$2 worktree=$3 line=$4 marker_id=$5 call_id disposition rc
  shift 5
  for call_id in "$@"; do
    rc=0
    disposition=$("$SCRIPT_DIR/fm-captain-hold.sh" withdrawn-parked "$call_id" 2>/dev/null) || rc=$?
    case "$rc" in
      0)
        if notify_mate "$id" "$(mate_evidence "$ledger_id" "$worktree" "$line" "$call_id:$disposition")" mate-wait "$marker_id"; then
          CLASS="mate-wait"
        else
          CLASS=unknown; DETAIL="could not notify mate of changed evidence"
        fi
        return 0 ;;
      1) ;;
      *) CLASS=unknown; DETAIL="mate disposition could not be read"; return 0 ;;
    esac
  done
  return 1
}

# classify <id>: sets CLASS, DETAIL, AGE
classify() {
  local id=$1 line verb worktree row pr pr_state hold_rc=0
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
  mate_disposition "$id" "$id" "$worktree" "$line" "$id" "$id" "idle-$id" && return
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
          closed)
            CLASS="mate-review"
            DETAIL="$pr closed without merging; owning mate must assess supersession or unfinished work"
            MATE_EVIDENCE=$(mate_evidence "$id" "$worktree" "$line" "$row")
            return
            ;;
          *) CLASS=settling; DETAIL="cannot read whether $pr merged"; return ;;
        esac
      elif [ "$(fm_meta_get "$STATE/$id.meta" kind)" != scout ]; then
        CLASS="mate-review"
        MATE_EVIDENCE=$(mate_evidence "$id" "$worktree" "$line")
        return
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
  if [ "$CLASS" = finished ] && already_raised "$id"; then
    CLASS=raised
  fi
  case "$CLASS" in
    failed|stalled|dead) MATE_EVIDENCE=$(mate_evidence "$id" "$worktree" "$line") ;;
  esac
}

hours() {  # <secs>
  printf '%s hours' $(($1 / 3600))
}

# cleanup <id>: guarded teardown of a finished worker. 0 = cleaned; else
# CLEANUP_WHY holds the refusal.
cleanup() {
  local id=$1 out rc=0 args
  args=("$id" --keep-commits)
  [ -z "$MERGED_PR_URL" ] || args+=(--merged-pr "$MERGED_PR_URL")
  CLEANUP_WHY=
  # --keep-commits: leftover local commits after a merged PR are saved on a
  # kept/ branch rather than raised (housekeeping is never a captain call).
  out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-teardown.sh" "${args[@]}" </dev/null 2>&1) || rc=$?
  [ "$rc" -eq 0 ] && return 0
  if printf '%s' "$out" | grep -q "on the retired '"; then
    rc=0
    args=(--finished "$id")
    [ -z "$MERGED_PR_URL" ] || args+=(--merged-pr "$MERGED_PR_URL")
    out=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-retire-endpoint.sh" "${args[@]}" </dev/null 2>&1) || rc=$?
    [ "$rc" -eq 0 ] && return 0
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
  classify "$id"
  action=none
  HOLD_ID=
  case "$CLASS" in
    finished)
      if cleanup "$id"; then
        action=cleaned
        log "cleaned up $id"
      elif [ ! -e "$meta" ] && [ ! -L "$meta" ] && [ -e "$STATE/$id.backlog-close" ]; then
        action=unhandled
        DETAIL="its record is gone but its backlog close is still pending: $CLEANUP_WHY"
      elif [ ! -e "$meta" ] && [ ! -L "$meta" ]; then
        action=cleaned
        DETAIL="worker record already removed"
      elif [ "$(cat "$meta" 2>/dev/null)" != "$record" ]; then
        CLASS=unknown
        DETAIL="worker record changed during scan"
      elif printf '%s' "$CLEANUP_WHY" | grep -Eq '^another lifecycle action is already running for task |^another Treehouse slot allocation or return is in progress for '; then
        CLASS=settling
        DETAIL="another cleanup or lifecycle action holds it: $CLEANUP_WHY"
      else
        worktree=$(fm_meta_get "$meta" worktree)
        if notify_mate "$id" "$(mate_evidence "$id" "$worktree" "$CLEANUP_WHY")" mate-review; then
          action=referred
        else
          action=unhandled
        fi
        DETAIL=$CLEANUP_WHY
      fi
      ;;
    mate-review|failed|stalled|dead)
      if notify_mate "$id" "$MATE_EVIDENCE" mate-review; then
        action=referred
      else
        action=unhandled
        DETAIL="could not notify owning mate: $DETAIL"
      fi
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
  hold_settled "$otask" "idle-$otask" "idle-orphan-$otask" "idle-idle-orphan-$otask" || hold_rc=$?
  case "$hold_rc" in
    0) add_row "idle-orphan-$otask" held "$detail" none; continue ;;
    1) ;;
    *) add_row "idle-orphan-$otask" unknown "$detail; captain hold could not be read" none; continue ;;
  esac
  DETAIL=$detail
  # Each endpoint keeps its own evidence marker while referrals name the task.
  endpoint_marker=$(printf '%s' "$oeid" | shasum -a 256)
  orphan_marker="idle-orphan-$otask.${endpoint_marker%% *}"
  if mate_disposition "idle-orphan-$otask" "$otask" "" "$oeid" "$orphan_marker" \
    "$otask" "idle-$otask" "idle-orphan-$otask" "idle-idle-orphan-$otask"; then
    add_row "idle-orphan-$otask" "$CLASS" "$DETAIL" none
    continue
  fi
  if already_raised "idle-orphan-$otask" "$otask"; then
    add_row "idle-orphan-$otask" raised "$detail" none
    continue
  fi
  orphan_evidence=$(mate_evidence "$otask" "" "$oeid")
  if [ "$(cat "$RAISED_DIR/$orphan_marker.mate-review" 2>/dev/null)" = "$orphan_evidence" ]; then
    add_row "idle-orphan-$otask" dead "$detail; awaiting mate assessment" referred
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
  if notify_mate "idle-orphan-$otask" "$orphan_evidence" mate-review "$orphan_marker"; then
    action=referred
  else
    action=unhandled
    detail="could not notify owning mate: $detail"
  fi
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
exit 0
