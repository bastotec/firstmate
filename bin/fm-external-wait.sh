#!/usr/bin/env bash
# fm-external-wait.sh - the one owner of the SUPERVISOR-declared external-wait
# record: its schema, the declare/clear lifecycle, the expiry verdict, and the
# read helpers the watcher uses instead of parsing the file.
#
# WHY. The watcher relieves a bounded external wait only when the WORKER writes
# its own `paused:` status line (bin/fm-classify-lib.sh owns that verb). A worker
# that cannot generate at all - a provider outage that stops generation entirely
# is exactly this condition - cannot write one, and its healthy parked pane then
# escalates as a possible wedge every FM_STALE_ESCALATE_SECS, each alarm risking
# a wrong recovery action against preserved, unlanded work. This record lets a
# SUPERVISOR declare that wait per task, with a reason and an expected clear
# time, so monitoring absorbs the pane's stale timer and re-surfaces it on the
# ordinary pause cadence instead. It is deliberately NOT a mute button and NOT a
# captain hold: a hold asserts a genuine captain question (bin/fm-captain-hold.sh
# owns those), and using one to silence an external dependency fans one wait into
# N holds. Out of scope on purpose: the optional possible-wedge wake gate
# (bin/fm-wake-gate.sh), which stays unconfigured.
#
# RECORD (state/<id>.external-wait; written only by this script):
#   version: 1
#   task: <task-id>
#   declared: <UTC ISO 8601>
#   declared_epoch: <seconds>
#   declared_by: <who declared the wait, verbatim>
#   reason: <why the wait holds, one line, verbatim>
#   until: <UTC ISO 8601>            the expected clear time
#   until_epoch: <seconds>
# A declaration in force is the file's existence plus a live clock: readers treat
# a record whose until_epoch has passed as EXPIRED and stop absorbing, so an
# expired declaration restores ordinary escalation without anyone needing to
# clean up first. The file is archived (below) when the wait is cleared or
# replaced, so an audit can always tell who declared a wait and why, and that
# record is never confused with a worker-authored `paused:` line.
#
# AUTHORITY AND BOUNDS.
# - This record is supervision state, never worker progress: the script writes
#   only this file and its archive, and never touches state/<id>.status.
# - It never suppresses a genuinely new event. Only the watcher's stale/wedge
#   absorb paths read it (bin/fm-watch.sh); the status-signal scan, check
#   results, terminal outcomes, and PR-merge polls never do, so all of those
#   still wake the supervisor immediately while the wait holds.
# - It must not outlive the wait: it expires at its stated time, and `clear`
#   removes it the moment the external condition clears. Both restore ordinary
#   escalation.
# - Bounded by construction: `declare` refuses a missing reason, a malformed
#   expected clear time, or one that is not in the future, so no record can be
#   written without a bound.
#
# USAGE:
#   fm-external-wait.sh declare <task> --reason <text> --until <UTC ISO 8601>
#       [--by <text>]
#     Record (or replace) the supervisor-declared wait for <task> and print the
#     record path. --by names the declarer for the audit trail (default
#     "firstmate"). Exit 0 on success, 2 on a usage error (missing or malformed
#     field, past expected clear time), 1 when the record could not be written.
#   fm-external-wait.sh clear <task> [--by <text>]
#     Remove the declaration now that the external condition cleared (or after
#     expiry); the record is archived under state/external-waits/ with the clear
#     time and who cleared it appended. Exit 0 whether or not a record existed,
#     1 when an existing record could not be archived away.
#   fm-external-wait.sh show <task>
#     Print the record's fields, plus verdict: active|expired|absent.
#   fm-external-wait.sh active <task>
#     Exit 0 iff a live (present and unexpired) declaration exists.
#   fm-external-wait.sh list
#     One line per recorded task: <task> <active|expired> until=<until> <reason>.
#
# LOCK (state/<id>.external-wait.lock; this script is its one owner). The
# record-mutating subcommands (declare, clear) hold it across their mutation so a
# concurrent declare and clear cannot interleave; the read subcommands never take
# it. The acquire is bounded (30s) and a bound that is hit refuses and names the
# live holder rather than racing. A lock left by a killed process is reclaimed by
# the ordinary stale-owner recovery in bin/fm-wake-lib.sh, which owns the lock
# primitive itself.
#
# SOURCEABLE: with the BASH_SOURCE guard, other scripts get the path,
# liveness, and field helpers (fm_external_wait_path, fm_external_wait_active,
# fm_external_wait_field) without running main.
# fm_external_wait_active sets FM_EXTERNAL_WAIT_AGE (seconds since declare),
# FM_EXTERNAL_WAIT_SCOPE (the declaration identity a re-surface throttle binds
# to), FM_EXTERNAL_WAIT_REASON, FM_EXTERNAL_WAIT_BY, and FM_EXTERNAL_WAIT_UNTIL
# when it succeeds, and clears them when it fails.
set -u

FM_EXTERNAL_WAIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_EXTERNAL_WAIT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_EXTERNAL_WAIT_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-classify-lib.sh
. "$FM_EXTERNAL_WAIT_DIR/fm-classify-lib.sh"

FM_EXTERNAL_WAIT_VERSION=1
FM_EXTERNAL_WAIT_LOCK_HELD=
_FM_EXTERNAL_WAIT_LOCK_TIMEOUT=30

# The live-declaration facts a reader consumes. Cleared on every failed read so a
# stale value can never survive a declaration that has expired or been cleared.
FM_EXTERNAL_WAIT_AGE=
FM_EXTERNAL_WAIT_SCOPE=
FM_EXTERNAL_WAIT_REASON=
FM_EXTERNAL_WAIT_BY=
FM_EXTERNAL_WAIT_UNTIL=

fm_external_wait_log() { printf 'fm-external-wait: %s\n' "$*" >&2; }

fm_external_wait_usage() {
  sed -n '/^# USAGE:/,/^# LOCK/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

fm_external_wait_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

fm_external_wait_now_epoch() {
  date +%s
}

fm_external_wait_path() {  # <task> [state-dir]
  printf '%s/%s.external-wait' "${2:-$FM_EXTERNAL_WAIT_STATE}" "$1"
}

fm_external_wait_archive_dir() {  # [state-dir]
  printf '%s/external-waits' "${1:-$FM_EXTERNAL_WAIT_STATE}"
}

fm_external_wait_lock_path() {  # <task> [state-dir]
  printf '%s/.%s.external-wait.lock' "${2:-$FM_EXTERNAL_WAIT_STATE}" "$1"
}

# Lazily reach the lock primitive. bin/fm-wake-lib.sh is a canonical lint root in
# its own right, so keep this an analysis boundary for the same reason
# bin/fm-afk-contract.sh's fm_afk_contract_lock_helpers does.
fm_external_wait_lock_helpers() {
  command -v fm_lock_acquire_wait_bounded >/dev/null 2>&1 && return 0
  # shellcheck source=/dev/null
  . "$FM_EXTERNAL_WAIT_DIR/fm-wake-lib.sh"
}

fm_external_wait_lock_hold() {  # <task>
  local lock rc=0 timeout
  lock=$(fm_external_wait_lock_path "$1")
  timeout=${FM_TEST_EXTERNAL_WAIT_LOCK_TIMEOUT:-$_FM_EXTERNAL_WAIT_LOCK_TIMEOUT}
  fm_external_wait_lock_helpers || {
    fm_external_wait_log "could not load the lock primitive for $lock"
    return 1
  }
  fm_lock_acquire_wait_bounded "$lock" "$timeout" || rc=$?
  if [ "$rc" -ne 0 ]; then
    if [ "$rc" -eq 124 ] && [ -n "${FM_LOCK_HELD_PID:-}" ]; then
      fm_external_wait_log "the external-wait record for $1 is locked by live process $FM_LOCK_HELD_PID; nothing was changed"
    else
      fm_external_wait_log "could not take the external-wait record lock at $lock; nothing was changed"
    fi
    return 1
  fi
  FM_EXTERNAL_WAIT_LOCK_HELD=$lock
}

fm_external_wait_lock_release() {
  local lock=$FM_EXTERNAL_WAIT_LOCK_HELD
  [ -n "$lock" ] || return 0
  FM_EXTERNAL_WAIT_LOCK_HELD=
  fm_external_wait_lock_helpers || return 1
  fm_lock_release "$lock"
}

# fm_external_wait_field <file> <key>: the value of that record field (empty when
# absent). Values are single lines, so a plain anchored read is the whole parser.
fm_external_wait_field() {  # <file> <key>
  [ -f "$1" ] || return 0
  sed -n "s/^$2: //p" "$1" | head -1
}

# fm_external_wait_active <task> [state-dir]: 0 while a live declaration exists.
# EXPIRED (past its stated expected clear time) is NOT active: an expired
# declaration restores ordinary escalation by simply not answering here, so the
# reader never has to clean up before alarming. Sets the FM_EXTERNAL_WAIT_*
# reader facts on success and clears them on failure.
fm_external_wait_active() {  # <task> [state-dir]
  local task=$1 state=${2:-$FM_EXTERNAL_WAIT_STATE} record declared until_epoch now
  FM_EXTERNAL_WAIT_AGE=
  FM_EXTERNAL_WAIT_SCOPE=
  FM_EXTERNAL_WAIT_REASON=
  FM_EXTERNAL_WAIT_BY=
  FM_EXTERNAL_WAIT_UNTIL=
  [ -n "$task" ] || return 1
  record=$(fm_external_wait_path "$task" "$state")
  [ -f "$record" ] || return 1
  declared=$(fm_external_wait_field "$record" declared_epoch)
  until_epoch=$(fm_external_wait_field "$record" until_epoch)
  case "$declared" in ''|*[!0-9]*) return 1 ;; esac
  case "$until_epoch" in ''|*[!0-9]*) return 1 ;; esac
  now=$(fm_external_wait_now_epoch)
  [ "$now" -lt "$until_epoch" ] || return 1
  FM_EXTERNAL_WAIT_AGE=$(( now - declared ))
  [ "$FM_EXTERNAL_WAIT_AGE" -ge 0 ] || FM_EXTERNAL_WAIT_AGE=0
  FM_EXTERNAL_WAIT_REASON=$(fm_external_wait_field "$record" reason)
  FM_EXTERNAL_WAIT_BY=$(fm_external_wait_field "$record" declared_by)
  FM_EXTERNAL_WAIT_UNTIL=$(fm_external_wait_field "$record" until)
  # The declaration identity a re-surface throttle binds to: any new declaration
  # replaces it, so a replacement starts its own cadence window instead of
  # inheriting the silence of the one it replaced.
  FM_EXTERNAL_WAIT_SCOPE="${task}:${declared}:${until_epoch}"
}

fm_external_wait_task_valid() {  # <task>
  case "$1" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

# The one-line field check every declare flag passes: a field must be present,
# single-line, and non-blank after trimming, so no record line can be forged from
# a value and no field can be written empty.
fm_external_wait_line_value_ok() {  # <text>
  case "$1" in
    ''|*$'\n'*|*$'\r'*) return 1 ;;
  esac
  [ -n "$(printf '%s' "$1" | tr -d '[:space:]')" ]
}

fm_external_wait_declare() {  # <task> --reason <text> --until <UTC ISO 8601> [--by <text>]
  local task=$1 reason= until= by=firstmate until_epoch now record tmp declared
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --reason) [ "$#" -ge 2 ] || { fm_external_wait_log "declare: --reason needs a value"; return 2; }
        reason=$2; shift 2 ;;
      --until) [ "$#" -ge 2 ] || { fm_external_wait_log "declare: --until needs a value"; return 2; }
        until=$2; shift 2 ;;
      --by) [ "$#" -ge 2 ] || { fm_external_wait_log "declare: --by needs a value"; return 2; }
        by=$2; shift 2 ;;
      *) fm_external_wait_log "declare: unknown argument: $1"; return 2 ;;
    esac
  done
  fm_external_wait_task_valid "$task" \
    || { fm_external_wait_log "declare: invalid task id: $task"; return 2; }
  fm_external_wait_line_value_ok "$reason" \
    || { fm_external_wait_log "declare: a non-empty single-line --reason is required"; return 2; }
  fm_external_wait_line_value_ok "$by" \
    || { fm_external_wait_log "declare: --by must be a non-empty single line"; return 2; }
  [ -n "$until" ] || { fm_external_wait_log "declare: --until <UTC ISO 8601> is required"; return 2; }
  until_epoch=$(fm_utc_iso_to_epoch "$until") \
    || { fm_external_wait_log "declare: --until must be a UTC ISO 8601 time (YYYY-MM-DDTHH:MM[:SS]Z), got: $until"; return 2; }
  now=$(fm_external_wait_now_epoch)
  [ "$until_epoch" -gt "$now" ] \
    || { fm_external_wait_log "declare: --until must be in the future (a declaration is bounded by its expected clear time), got: $until"; return 2; }
  fm_external_wait_lock_hold "$task" || return 1
  record=$(fm_external_wait_path "$task")
  if [ -f "$record" ]; then
    fm_external_wait_archive "$task" replaced "$by" || { fm_external_wait_lock_release; return 1; }
  fi
  declared=$(fm_external_wait_now_iso)
  tmp="$record.tmp.$$"
  if ! {
    printf 'version: %s\n' "$FM_EXTERNAL_WAIT_VERSION"
    printf 'task: %s\n' "$task"
    printf 'declared: %s\n' "$declared"
    printf 'declared_epoch: %s\n' "$now"
    printf 'declared_by: %s\n' "$by"
    printf 'reason: %s\n' "$reason"
    printf 'until: %s\n' "$until"
    printf 'until_epoch: %s\n' "$until_epoch"
  } > "$tmp" || ! mv "$tmp" "$record"; then
    rm -f "$tmp"
    fm_external_wait_lock_release
    fm_external_wait_log "could not write the external-wait record at $record"
    return 1
  fi
  fm_external_wait_lock_release
  printf '%s\n' "$record"
}

# Move the current record into the archive, appending who ended it and when. The
# archive is the audit trail: a declared wait never disappears without a trace of
# who declared it, why, and how it ended.
fm_external_wait_archive() {  # <task> <outcome: cleared|replaced> [by]
  local task=$1 outcome=$2 by=${3:-firstmate} record dir archive declared n
  record=$(fm_external_wait_path "$task")
  [ -f "$record" ] || return 0
  dir=$(fm_external_wait_archive_dir)
  mkdir -p "$dir" || return 1
  declared=$(fm_external_wait_field "$record" declared_epoch)
  case "$declared" in ''|*[!0-9]*) declared=$(fm_external_wait_now_epoch) ;; esac
  archive="$dir/$declared-$task.external-wait"
  n=0
  while [ -e "$archive" ]; do
    n=$(( n + 1 ))
    archive="$dir/$declared-$task.$n.external-wait"
  done
  {
    printf 'ended: %s\n' "$(fm_external_wait_now_iso)"
    printf 'ended_epoch: %s\n' "$(fm_external_wait_now_epoch)"
    printf 'ended_by: %s\n' "$by"
    printf 'outcome: %s\n' "$outcome"
  } >> "$record" || return 1
  mv "$record" "$archive"
}

fm_external_wait_clear() {  # <task> [--by <text>]
  local task=$1 by=firstmate
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --by) [ "$#" -ge 2 ] || { fm_external_wait_log "clear: --by needs a value"; return 2; }
        by=$2; shift 2 ;;
      *) fm_external_wait_log "clear: unknown argument: $1"; return 2 ;;
    esac
  done
  fm_external_wait_task_valid "$task" \
    || { fm_external_wait_log "clear: invalid task id: $task"; return 2; }
  fm_external_wait_line_value_ok "$by" \
    || { fm_external_wait_log "clear: --by must be a non-empty single line"; return 2; }
  fm_external_wait_lock_hold "$task" || return 1
  if [ -f "$(fm_external_wait_path "$task")" ]; then
    if ! fm_external_wait_archive "$task" cleared "$by"; then
      fm_external_wait_lock_release
      fm_external_wait_log "could not archive the external-wait record for $task; nothing was removed"
      return 1
    fi
  fi
  fm_external_wait_lock_release
  printf 'cleared: %s\n' "$task"
}

fm_external_wait_verdict() {  # <task> -> active|expired|absent
  local task=$1 record until_epoch now
  record=$(fm_external_wait_path "$task")
  [ -f "$record" ] || { printf 'absent\n'; return 0; }
  until_epoch=$(fm_external_wait_field "$record" until_epoch)
  now=$(fm_external_wait_now_epoch)
  case "$until_epoch" in
    ''|*[!0-9]*) printf 'expired\n'; return 0 ;;
  esac
  if [ "$now" -lt "$until_epoch" ]; then printf 'active\n'; else printf 'expired\n'; fi
}

fm_external_wait_show() {  # <task>
  local task=$1 record
  fm_external_wait_task_valid "$task" \
    || { fm_external_wait_log "show: invalid task id: $task"; return 2; }
  record=$(fm_external_wait_path "$task")
  if [ -f "$record" ]; then
    cat "$record"
    printf 'verdict: %s\n' "$(fm_external_wait_verdict "$task")"
  else
    printf 'verdict: absent\n'
  fi
}

fm_external_wait_list() {  # [state-dir]
  local state=${1:-$FM_EXTERNAL_WAIT_STATE} record task verdict until_epoch reason
  for record in "$state"/*.external-wait; do
    [ -f "$record" ] || continue
    task=$(fm_external_wait_field "$record" task)
    [ -n "$task" ] || task=$(basename "$record" .external-wait)
    verdict=$(fm_external_wait_verdict "$task")
    until_epoch=$(fm_external_wait_field "$record" until)
    reason=$(fm_external_wait_field "$record" reason)
    printf '%s %s until=%s %s\n' "$task" "$verdict" "$until_epoch" "$reason"
  done
}

fm_external_wait_main() {
  local cmd=${1:-}
  case "$cmd" in
    declare) shift; [ "$#" -ge 1 ] || { fm_external_wait_usage >&2; return 2; }
      fm_external_wait_declare "$@" ;;
    clear) shift; [ "$#" -ge 1 ] || { fm_external_wait_usage >&2; return 2; }
      fm_external_wait_clear "$@" ;;
    show) shift; [ "$#" -eq 1 ] || { fm_external_wait_usage >&2; return 2; }
      fm_external_wait_show "$1" ;;
    active) shift; [ "$#" -eq 1 ] || { fm_external_wait_usage >&2; return 2; }
      fm_external_wait_active "$1" ;;
    list) shift; fm_external_wait_list ;;
    -h|--help|help) fm_external_wait_usage ;;
    *) fm_external_wait_usage >&2; return 2 ;;
  esac
}

# Sourceable: run main only when executed.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_external_wait_main "$@"
fi
