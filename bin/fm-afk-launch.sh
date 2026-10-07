#!/usr/bin/env bash
# fm-afk-launch.sh - the single owner of away-mode ENTRY and EXIT: the
# read-back-and-confirm entry that writes the away-posture record through
# bin/fm-afk-contract.sh, and the away-mode daemon endpoint lifecycle where a
# daemon still runs: launch it as a detached process, record its exact
# identity, tear it down by that identity, and reconcile a leaked process
# after a crash.
#
# ENTRY (the posture record). `/afk [words]` is two steps so the captain hears
# the mandate back before it binds: `propose` compiles the words and clauses
# into a proposal and prints the read-back (bin/fm-afk-contract.sh owns the
# clause fields, the never-set, the refusal wording, and the record schema); `confirm` promotes it
# into state/.afk-contract and prints the entry announcement (hold-for-return
# only: no phone channel exists). `start` and `start-native` require the
# confirmed record before they launch the daemon.
# `stop` (the return, driven by bin/fm-afk-return.sh) shuts the daemon down,
# clears state/.afk last, and archives the record under state/afk-contracts/.
#
# Why the daemon lifecycle exists: bin/fm-afk-start.sh execs the supervise
# daemon in the FOREGROUND of its host, and a plain fire-and-forget shell child
# can be reaped with the shell that started it. start-native covers a harness
# with its own tracked background tool; otherwise this launches the daemon as a
# detached session leader and records its exact identity.
#
# Correct supervisor targeting: capture the primary's stream endpoint or
# steer-only target before detaching, using discover_supervisor_target, and
# pass FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND explicitly so delivery stays
# bound to that primary.
#
# Usage:
#   fm-afk-launch.sh propose [--words-file <path> | --words <text>]
#                            [--action <verb> --object <text> --when <text> [--stop <text>]]...
#                            [--expected-return <UTC ISO 8601>] [--spend <n>]
#                            [--grant <task-id>]...
#                              Record the captain's away words and mandate
#                              clause fields into a proposal and print the
#                              read-back. Exit 3 when a clause was refused (its
#                              missing part is named in the read-back); the
#                              proposal still records it as refused.
#                              Repeatable --grant records captain-named task
#                              ids that may merge-when-green while away.
#   fm-afk-launch.sh confirm   Promote the required proposal and print the entry
#                              announcement.
#   fm-afk-launch.sh start     Capture the primary target, then (unless the daemon
#                              is already running) launch and record a detached
#                              daemon process. Idempotent: an already-running
#                              daemon just refreshes state/.afk; a recorded-but-
#                              dead process is reconciled first.
#   fm-afk-launch.sh start-native
#                              Prepare lifecycle state for a harness-native
#                              background job and record that no terminal exists.
#   fm-afk-launch.sh stop      Correct-ordered exit: SIGTERM the daemon so its
#                              cleanup flushes WHILE state/.afk is still present,
#                              wait for it, confirm the recorded process is gone,
#                              clear state/.afk, then archive the record last.
#   fm-afk-launch.sh reconcile Reconcile a recorded-but-dead daemon process and
#                              drop its record (recovery after a crash).
#
# The primary is a deck-chat host, usually on a stream endpoint, so there is no
# local pane to put a hidden terminal next to: the daemon runs as a detached
# process in its own session (setsid, the same detach the stream adapter uses
# for its agents), with output in state/.afk-daemon.out.
# state/.afk-daemon-terminal is a single three-field TAB record:
# none<TAB>-<TAB>native, or process<TAB><pid><TAB><fm_pid_identity>. A record
# naming the retired tmux or herdr backends is refused with an instruction to
# stop that daemon by hand. The process record is refreshed with
# the post-readiness identity after the entry execs the daemon. Process
# liveness, close, and absence require that identity to match and the pid to
# lead its own process group; a mismatch reads as gone and is never signalled.
# tests/fm-afk-launch.test.sh covers detached launch, shutdown, and mismatches.
#
# Test seam: FM_AFK_LAUNCH_ENTRY overrides the detached entry command (default
# bin/fm-afk-start.sh), so a lifecycle test can run a harmless placeholder
# instead of a real daemon. FM_SUPERVISOR_TARGET/FM_SUPERVISOR_BACKEND override
# the captured primary target/backend (an isolated stream endpoint in tests).
# FM_AFK_MODE (away|quiet, default away) declares which mode a `start` entry
# requests; leave it unset for a plain refresh of an already-running daemon
# so its current mode is preserved (bin/fm-afk-start.sh fm_afk_flag_write).
set -u

FM_AFK_LAUNCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$FM_AFK_LAUNCH_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
case "$FM_HOME" in
  /*) ;;
  *)
    FM_AFK_LAUNCH_HOME_INPUT=$FM_HOME
    FM_HOME=$(CDPATH='' cd -- "$FM_AFK_LAUNCH_HOME_INPUT" 2>/dev/null && pwd -P) || {
      echo "error: FM_HOME directory cannot be resolved: $FM_AFK_LAUNCH_HOME_INPUT" >&2
      exit 1
    }
    ;;
esac
if [ -n "${FM_STATE_OVERRIDE:-}" ]; then
  case "$FM_STATE_OVERRIDE" in
    /*) ;;
    *)
      FM_AFK_LAUNCH_STATE_INPUT=$FM_STATE_OVERRIDE
      FM_STATE_OVERRIDE=$(CDPATH='' cd -- "$FM_AFK_LAUNCH_STATE_INPUT" 2>/dev/null && pwd -P) || {
        echo "error: FM_STATE_OVERRIDE directory cannot be resolved: $FM_AFK_LAUNCH_STATE_INPUT" >&2
        exit 1
      }
      ;;
  esac
fi
FM_AFK_LAUNCH_STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
FM_AFK_LAUNCH_RECORD="$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal"
FM_AFK_LAUNCH_LOCK="$FM_AFK_LAUNCH_STATE/.afk-launch.lock"

# shellcheck source=bin/fm-backend.sh
. "$FM_AFK_LAUNCH_DIR/fm-backend.sh"
# shellcheck source=bin/fm-supervisor-target-lib.sh
. "$FM_AFK_LAUNCH_DIR/fm-supervisor-target-lib.sh"
# fm-afk-start.sh provides the daemon-lock liveness helpers and
# fm_afk_clear_stale_artifacts; it is sourceable (BASH_SOURCE guard) and its
# main does not run on source. It sets `set -eu`, so turn errexit back off for
# this script's best-effort flow immediately after.
# shellcheck source=bin/fm-afk-start.sh
. "$FM_AFK_LAUNCH_DIR/fm-afk-start.sh"
set +e
# The away-posture record owner; sourced for its path helpers, driven as a
# command for every record mutation so its output reaches the captain.
# shellcheck source=bin/fm-afk-contract.sh
. "$FM_AFK_LAUNCH_DIR/fm-afk-contract.sh"
FM_AFK_CONTRACT_CMD="$FM_AFK_LAUNCH_DIR/fm-afk-contract.sh"

fm_afk_launch_log() { printf 'fm-afk-launch: %s\n' "$*" >&2; }

fm_afk_launch_lock_owned() {
  local pid expected actual
  [ -d "$FM_AFK_LAUNCH_LOCK" ] || return 1
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null) || return 1
  expected=$(cat "$FM_AFK_LAUNCH_LOCK/pid-identity" 2>/dev/null) || return 1
  actual=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ -n "$expected" ] && [ "$actual" = "$expected" ]
}

fm_afk_launch_lock_acquire() {
  local attempt=0 incomplete=0 identity
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  while [ "$attempt" -lt 200 ]; do
    attempt=$((attempt + 1))
    if mkdir "$FM_AFK_LAUNCH_LOCK" 2>/dev/null; then
      if ! printf '%s' "$$" > "$FM_AFK_LAUNCH_LOCK/pid"; then
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      fi
      identity=$(fm_pid_identity "$$" 2>/dev/null) || {
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      }
      if [ -z "$identity" ] || ! printf '%s' "$identity" > "$FM_AFK_LAUNCH_LOCK/pid-identity"; then
        rm -rf "$FM_AFK_LAUNCH_LOCK"
        return 1
      fi
      return 0
    fi
    if [ ! -s "$FM_AFK_LAUNCH_LOCK/pid" ] || [ ! -s "$FM_AFK_LAUNCH_LOCK/pid-identity" ]; then
      incomplete=$((incomplete + 1))
      if [ "$incomplete" -lt 20 ]; then
        sleep 0.05
        continue
      fi
    else
      incomplete=0
    fi
    if ! fm_afk_launch_lock_owned; then
      rm -rf "$FM_AFK_LAUNCH_LOCK" 2>/dev/null || return 1
      incomplete=0
      continue
    fi
    sleep 0.05
  done
  fm_afk_launch_log "timed out waiting for launcher lock"
  return 1
}

fm_afk_launch_lock_release() {
  local pid
  pid=$(cat "$FM_AFK_LAUNCH_LOCK/pid" 2>/dev/null || true)
  [ "$pid" = "$$" ] || return 0
  rm -rf "$FM_AFK_LAUNCH_LOCK"
}

fm_afk_launch_usage() {
  sed -n '/^# Usage:/,/^# Supported backends:/p' "${BASH_SOURCE[0]}" | sed '$d' | sed 's/^# \{0,1\}//'
}

fm_afk_launch_catchup_pending() {
  if [ -e "$FM_AFK_LAUNCH_STATE/.afk-return-catchup" ]; then
    fm_afk_launch_log "return catch-up is still pending; run bin/fm-afk-return.sh check before re-entering away mode"
    return 0
  fi
  return 1
}

fm_afk_launch_record_require() {
  local record
  record=$(fm_afk_contract_path "$FM_AFK_LAUNCH_STATE")
  if ! fm_afk_contract_present "$FM_AFK_LAUNCH_STATE"; then
    fm_afk_launch_log "a confirmed away-posture record is required; run propose and confirm before starting the daemon"
    return 1
  fi
  fm_afk_contract_validate "$record" 1 || {
    fm_afk_launch_log "the away-posture record is not confirmed; run confirm before starting the daemon"
    return 1
  }
}

fm_afk_launch_propose() {
  fm_afk_launch_catchup_pending && return 1
  "$FM_AFK_CONTRACT_CMD" propose "$@"
}

fm_afk_launch_confirm() {
  fm_afk_launch_catchup_pending && return 1
  "$FM_AFK_CONTRACT_CMD" confirm
}

# The command run inside the created terminal. Real launch runs the shared
# daemon entry; a test overrides it with a harmless placeholder.
fm_afk_launch_entry_cmd() {
  printf '%s' "${FM_AFK_LAUNCH_ENTRY:-$FM_ROOT/bin/fm-afk-start.sh}"
}

fm_afk_launch_record_write() {  # <backend> <target> <extra>
  local pending
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  pending=$(mktemp "$FM_AFK_LAUNCH_STATE/.afk-daemon-terminal.pending.XXXXXX") || return 1
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" > "$pending" || { rm -f "$pending"; return 1; }
  mv "$pending" "$FM_AFK_LAUNCH_RECORD" || { rm -f "$pending"; return 1; }
}

fm_afk_launch_flag_write() {
  # FM_AFK_MODE is the ONE place a caller declares which mode this entry
  # requests (away, the unset default, or quiet - kunchenguid/firstmate#2356);
  # fm_afk_flag_write itself preserves the on-disk mode when it is unset, so
  # a plain /afk refresh of an already-quiet daemon never resets it.
  fm_afk_flag_write "$FM_AFK_LAUNCH_STATE" "${FM_AFK_MODE:-}"
}

fm_afk_launch_record_read() {
  local record
  FM_AFK_REC_BACKEND=""; FM_AFK_REC_TARGET=""; FM_AFK_REC_EXTRA=""
  [ -f "$FM_AFK_LAUNCH_RECORD" ] || return 1
  record=$(cat "$FM_AFK_LAUNCH_RECORD" 2>/dev/null) || record=""
  IFS=$'\t' read -r FM_AFK_REC_BACKEND FM_AFK_REC_TARGET FM_AFK_REC_EXTRA \
    < "$FM_AFK_LAUNCH_RECORD" || true
  if ! printf '%s\n' "$record" | awk -F '\t' 'NF != 3 { bad=1 } END { exit !(NR == 1 && !bad) }' \
    || [ -z "$FM_AFK_REC_BACKEND" ] || [ -z "$FM_AFK_REC_TARGET" ]; then
    fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"
    return 2
  fi
  case "$FM_AFK_REC_BACKEND" in
    tmux|herdr)
      fm_afk_launch_log "daemon terminal record names the retired '$FM_AFK_REC_BACKEND' backend; stop that daemon by hand, then delete $FM_AFK_LAUNCH_RECORD"
      return 2 ;;
    process)
      case "$FM_AFK_REC_TARGET" in ''|*[!0-9]*) false ;; *) [ -n "$FM_AFK_REC_EXTRA" ] ;; esac ;;
    none) [ "$FM_AFK_REC_TARGET" = - ] && [ "$FM_AFK_REC_EXTRA" = native ] ;;
    *) return 2 ;;
  esac || { fm_afk_launch_log "daemon terminal record is malformed; refusing to act on it"; return 2; }
}

fm_afk_launch_record_validate_if_present() {
  local result
  fm_afk_launch_record_read
  result=$?
  [ "$result" -ne 2 ]
}

# Close a recorded daemon by EXACT id (never a broad sweep).
fm_afk_launch_close_terminal() {  # <backend> <target>
  local backend=$1 target=$2 identity=${3:-${FM_AFK_REC_EXTRA:-}}
  case "$backend" in
    process)
      fm_afk_launch_process_alive "$target" "$identity" || return 0
      kill -TERM "$target" 2>/dev/null || return 1
      local waited=0
      while [ "$waited" -lt 40 ] && fm_afk_launch_process_alive "$target" "$identity"; do
        sleep 0.1
        waited=$((waited + 1))
      done
      ;;
    none)
      return 0
      ;;
    *)
      fm_afk_launch_log "cannot close unknown recorded backend '$backend'"
      return 1
      ;;
  esac
}

fm_afk_launch_terminal_absent() {  # <backend> <target>
  local backend=$1 target=$2 identity=${3:-${FM_AFK_REC_EXTRA:-}}
  case "$backend" in
    process)
      ! fm_afk_launch_process_alive "$target" "$identity"
      ;;
    none)
      return 0
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_process_alive() {
  local pid=$1 identity=${2:-} current
  [ -n "$identity" ] || return 1
  current=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  [ "$current" = "$identity" ] || return 1
  fm_afk_launch_process_started "$pid"
}

fm_afk_launch_process_started() {
  local pid=$1 pgid
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d ' ') || return 1
  [ "$pgid" = "$pid" ]
}

fm_afk_launch_close_recorded() {
  local close_result=0
  fm_afk_launch_close_terminal "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET" || close_result=$?
  if fm_afk_launch_terminal_absent "$FM_AFK_REC_BACKEND" "$FM_AFK_REC_TARGET"; then
    rm -f "$FM_AFK_LAUNCH_RECORD" || return 1
    [ "$close_result" -eq 0 ] || fm_afk_launch_log "terminal close command failed, but exact absence was confirmed"
    return 0
  fi
  fm_afk_launch_log "recorded terminal teardown is unconfirmed; preserving exact id"
  return 1
}

fm_afk_launch_terminal_alive() {  # <backend> <target>
  local backend=$1 target=$2 identity=${3:-${FM_AFK_REC_EXTRA:-}}
  case "$backend" in
    process)
      fm_afk_launch_process_alive "$target" "$identity"
      ;;
    *) return 1 ;;
  esac
}

fm_afk_launch_wait_ready() {  # <backend> <target>
  local backend=$1 target=$2 attempt=0
  if [ -n "${FM_AFK_LAUNCH_ENTRY:-}" ]; then
    if [ "$backend" = process ]; then
      fm_afk_launch_process_started "$target"
    else
      fm_afk_launch_terminal_alive "$backend" "$target"
    fi
    return
  fi
  while [ "$attempt" -lt 100 ]; do
    attempt=$((attempt + 1))
    daemon_lock_held_by_live_daemon && return 0
    if [ "$backend" = process ]; then
      fm_afk_launch_process_started "$target" || return 1
    else
      fm_afk_launch_terminal_alive "$backend" "$target" || return 1
    fi
    sleep 0.05
  done
  return 1
}

fm_afk_launch_commit_terminal() {  # <backend> <target> <extra> [already-recorded]
  local backend=$1 target=$2 extra=$3 already_recorded=${4:-0}
  if [ "$already_recorded" -ne 1 ] && ! fm_afk_launch_record_write "$backend" "$target" "$extra"; then
    fm_afk_launch_log "failed to persist daemon terminal record; closing $backend:$target"
    fm_afk_launch_close_terminal "$backend" "$target"
    return 1
  fi
  if ! fm_afk_launch_wait_ready "$backend" "$target"; then
    fm_afk_launch_log "daemon did not become ready; closing $backend:$target"
    FM_AFK_REC_BACKEND=$backend
    FM_AFK_REC_TARGET=$target
    FM_AFK_REC_EXTRA=$extra
    fm_afk_launch_close_recorded
    return 1
  fi
  if [ "$backend" = process ]; then
    extra=$(fm_pid_identity "$target" 2>/dev/null) || return 1
    fm_afk_launch_process_alive "$target" "$extra" || return 1
    if ! fm_afk_launch_record_write "$backend" "$target" "$extra"; then
      FM_AFK_REC_BACKEND=$backend
      FM_AFK_REC_TARGET=$target
      FM_AFK_REC_EXTRA=$extra
      fm_afk_launch_close_recorded
      return 1
    fi
  fi
}

# Reconcile a recorded-but-dead terminal: if a record exists and no live daemon
# owns it, close the leaked terminal by exact id and drop the record.
fm_afk_launch_reconcile() {
  local read_result
  if daemon_lock_held_by_live_daemon; then
    return 0
  fi
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_log "reconciling leaked daemon terminal ${FM_AFK_REC_BACKEND}:${FM_AFK_REC_TARGET}"
    fm_afk_launch_close_recorded
  elif [ "$read_result" -eq 2 ]; then
    return 1
  fi
}

fm_afk_launch_restore_backup() {  # <backup> <had-afk>
  local backup=$1 had_afk=$2 artifact result=0
  rm -f "$FM_AFK_LAUNCH_STATE/.afk" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-escalations.since" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-inject-wedged" \
    "$FM_AFK_LAUNCH_STATE/.subsuper-steer-pending" || result=1
  if [ "$had_afk" -eq 1 ]; then
    cp "$backup/.afk" "$FM_AFK_LAUNCH_STATE/.afk" || result=1
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged .subsuper-steer-pending; do
    if [ -e "$backup/$artifact" ]; then
      cp -p "$backup/$artifact" "$FM_AFK_LAUNCH_STATE/$artifact" || result=1
    fi
  done
  if [ "$result" -eq 0 ]; then
    rm -rf "$backup" || return 1
  else
    fm_afk_launch_log "rollback restoration incomplete; backup retained at $backup"
  fi
  return "$result"
}

# Replace the calling (background) process with <cmd> as a new session leader:
# the detach bin/backends/stream.sh's fm_backend_stream_detached uses, but with
# exec, so the background job's pid ($!) IS the daemon's pid.
fm_afk_launch_exec_detached() {  # <cmd...>
  if command -v setsid >/dev/null 2>&1; then
    exec setsid "$@"
  fi
  exec perl -MPOSIX -e 'my $r = POSIX::setsid(); (defined $r && $r != -1) or die "setsid: $!\n"; exec @ARGV or die "exec: $!\n"' "$@"
}

# Launch the daemon for a stream-hosted primary as a detached process in its
# own session. There is no local pane to sit beside, and the daemon reaches the
# primary through the steer dir or the hub, so no terminal is created at all.
fm_afk_launch_create_stream() {  # <captain-target> <captain-backend>
  local captain_target=$1 captain_backend=$2 entry out pid identity
  entry=$(fm_afk_launch_entry_cmd)
  out="$FM_AFK_LAUNCH_STATE/.afk-daemon.out"
  fm_afk_launch_exec_detached env FM_HOME="$FM_HOME" FM_SUPERVISOR_TARGET="$captain_target" \
    FM_SUPERVISOR_BACKEND="$captain_backend" "$entry" >>"$out" 2>&1 </dev/null &
  pid=$!
  # setsid runs inside the child, so it leads its own group only a moment later.
  local waited=0
  while [ "$waited" -lt 50 ] && ! fm_afk_launch_process_started "$pid"; do
    kill -0 "$pid" 2>/dev/null || break
    sleep 0.05
    waited=$((waited + 1))
  done
  if ! fm_afk_launch_process_started "$pid"; then
    fm_afk_launch_log "detached daemon process $pid did not start in its own session; see $out"
    kill -TERM "$pid" 2>/dev/null || true
    return 1
  fi
  identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
  if ! fm_afk_launch_record_write process "$pid" "$identity"; then
    fm_afk_launch_log "failed to persist daemon process record; stopping pid $pid"
    fm_afk_launch_close_terminal process "$pid" "$identity"
    return 1
  fi
  fm_afk_launch_commit_terminal process "$pid" "$identity" 1 || return 1
  fm_afk_launch_log "daemon launched as detached process $pid (log $out), supervising stream primary $captain_target"
}

fm_afk_launch_start() {
  local captain_target captain_backend backup artifact had_afk=0 result
  fm_afk_launch_catchup_pending && return 1
  fm_afk_launch_record_require || return 1
  # Capture the captain pane FIRST, before creating anything.
  # A stream primary may have no endpoint ("-"): the steer path needs none, and
  # the daemon's startup check refuses when neither a deck-chat primary nor an
  # endpoint answers, which rolls this launch back.
  captain_target=$(discover_supervisor_target) || true
  captain_backend=$(discover_supervisor_backend) || true

  mkdir -p "$FM_AFK_LAUNCH_STATE"

  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to refresh away-mode flag"
      return 1
    fi
    fm_afk_launch_log "daemon already running; refreshed away-mode flag (no new terminal)"
    return 0
  fi

  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged .subsuper-steer-pending; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  if ! fm_afk_launch_reconcile; then
    result=1
  else
    if fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      result=0
    else
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_launch_flag_write; then
      fm_afk_launch_log "failed to write away-mode flag"
      result=1
    fi
  fi

  if [ "$result" -eq 0 ]; then
    case "$captain_backend" in
      stream) fm_afk_launch_create_stream "$captain_target" "$captain_backend"; result=$? ;;
      *)
        fm_afk_launch_log "no daemon-launch primitive for backend '$captain_backend' (supported: stream)"
        result=1
        ;;
    esac
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_start_native() {
  local backup artifact had_afk=0 result=0
  mkdir -p "$FM_AFK_LAUNCH_STATE" || return 1
  fm_afk_launch_catchup_pending && return 1
  fm_afk_launch_record_require || return 1
  if daemon_lock_held_by_live_daemon; then
    fm_afk_launch_record_validate_if_present || return 1
    fm_afk_launch_flag_write || return 1
    fm_afk_launch_log "daemon already running; refreshed away-mode flag"
    return 0
  fi
  backup=$(mktemp -d "$FM_AFK_LAUNCH_STATE/.afk-launch-backup.XXXXXX") || return 1
  if [ -f "$FM_AFK_LAUNCH_STATE/.afk" ]; then
    had_afk=1
    cp "$FM_AFK_LAUNCH_STATE/.afk" "$backup/.afk" || { rm -rf "$backup"; return 1; }
  fi
  for artifact in .subsuper-escalations .subsuper-escalations.since .subsuper-inject-wedged .subsuper-steer-pending; do
    if [ -e "$FM_AFK_LAUNCH_STATE/$artifact" ]; then
      cp -p "$FM_AFK_LAUNCH_STATE/$artifact" "$backup/$artifact" || { rm -rf "$backup"; return 1; }
    fi
  done
  fm_afk_launch_reconcile || result=1
  if [ "$result" -eq 0 ]; then
    if ! fm_afk_clear_stale_artifacts "$FM_AFK_LAUNCH_STATE"; then
      fm_afk_launch_log "failed to clear stale away-mode artifacts"
      result=1
    elif ! fm_afk_launch_flag_write; then
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_record_write none - native || result=1
  fi
  if [ "$result" -ne 0 ]; then
    fm_afk_launch_restore_backup "$backup" "$had_afk" || result=1
  else
    rm -rf "$backup" || result=1
  fi
  return "$result"
}

fm_afk_launch_stop() {
  local pid pid_identity current_identity result=0 read_result archived
  fm_afk_launch_record_read
  read_result=$?
  if [ "$read_result" -eq 2 ]; then
    fm_afk_launch_log "malformed daemon terminal record; refusing to stop away mode"
    return 1
  fi
  # (1) SIGTERM the daemon so its cleanup trap flushes buffered escalations
  # WHILE state/.afk is still present (the exit-ordering fix: clearing .afk
  # first would make that flush a no-op via inject_msg's presence gate).
  pid=""
  pid_identity=""
  if daemon_lock_held_by_live_daemon; then
    pid=$(daemon_lock_pid 2>/dev/null) || return 1
    if [ "$read_result" -eq 0 ] && [ "$FM_AFK_REC_BACKEND" = process ]; then
      if [ "$pid" != "$FM_AFK_REC_TARGET" ] || ! fm_afk_launch_process_alive "$pid" "$FM_AFK_REC_EXTRA"; then
        pid=""
      fi
    fi
    if [ -n "$pid" ]; then
      pid_identity=$(fm_pid_identity "$pid" 2>/dev/null) || return 1
    fi
  fi
  if [ -n "$pid" ]; then
    if ! kill -TERM "$pid" 2>/dev/null; then
      fm_afk_launch_log "failed to signal away-mode daemon pid=$pid"
      result=1
    fi
    for _ in $(seq 1 40); do
      fm_pid_alive "$pid" || break
      sleep 0.25
    done
  fi
  if [ -n "$pid" ] && fm_pid_alive "$pid"; then
    current_identity=$(fm_pid_identity "$pid" 2>/dev/null) || {
      fm_afk_launch_log "could not confirm away-mode daemon exit; preserving lifecycle state"
      return 1
    }
    if [ "$current_identity" = "$pid_identity" ]; then
      fm_afk_launch_log "away-mode daemon did not exit after SIGTERM; preserving lifecycle state"
      return 1
    fi
  fi
  # (2) Close the daemon's own terminal by exact id.
  if [ "$read_result" -eq 0 ]; then
    fm_afk_launch_close_recorded || result=1
  fi
  # (3) Clear the away-mode flag, then (4) archive the posture record LAST so the
  # posture ends only once every daemon-side artifact is down.
  if ! rm -f "$FM_AFK_LAUNCH_STATE/.afk"; then
    fm_afk_launch_log "failed to clear away-mode flag"
    result=1
  fi
  if [ "$result" -eq 0 ] && fm_afk_contract_present "$FM_AFK_LAUNCH_STATE"; then
    if archived=$("$FM_AFK_CONTRACT_CMD" archive); then
      fm_afk_launch_log "away-posture record archived at $archived"
    else
      fm_afk_launch_log "failed to archive the away-posture record; it still stands"
      result=1
    fi
  fi
  if [ "$result" -eq 0 ]; then
    fm_afk_launch_log "away mode stopped; daemon terminal torn down, .afk cleared, and the posture record archived"
  else
    fm_afk_launch_log "away mode stopped; terminal teardown or the record archive remains recorded for retry"
  fi
  return "$result"
}

fm_afk_launch_main() {
  local result
  # Traps first, lock second. Acquiring before the handlers exist leaves a
  # window where a signal terminates this process by default action and leaks
  # the lock directory, which then blocks the next away-mode launch until the
  # stale-owner reclaim path clears it. fm_afk_launch_lock_release only removes
  # a lock this process owns, so arming it before acquisition is safe.
  trap fm_afk_launch_lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  fm_afk_launch_lock_acquire || return 1
  case "${1:-start}" in
    propose) shift; fm_afk_launch_propose "$@" ;;
    confirm) fm_afk_launch_confirm ;;
    start) fm_afk_launch_start ;;
    start-native) fm_afk_launch_start_native ;;
    stop) fm_afk_launch_stop ;;
    reconcile) fm_afk_launch_reconcile ;;
    -h|--help|help) fm_afk_launch_usage ;;
    *) fm_afk_launch_usage >&2; return 2 ;;
  esac
  result=$?
  fm_afk_launch_lock_release || result=1
  trap - EXIT INT TERM
  return "$result"
}

if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  fm_afk_launch_main "$@"
fi
