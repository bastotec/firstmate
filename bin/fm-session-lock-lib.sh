#!/usr/bin/env bash
# Shared session-lock harness identity.
#
# ONE owner of the "which verified-harness process holds this home's session
# lock, and does the current process descend from that same harness?" decision.
# bin/fm-lock.sh uses it to acquire and inspect state/.lock;
# bin/fm-deck-worker.sh uses it to prove each turn still runs inside the
# lock-owning session.
# This file is sourced by scripts and has no side effects on source.

# Cursor is no longer a primary harness, so it never owns a session lock. Its
# process identity stays available here only for worker liveness
# (bin/fm-agent-process-lib.sh sources this file); bin/fm-cursor-lib.sh owns it.
# shellcheck source=bin/fm-cursor-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-cursor-lib.sh"

# Primary harness command names that may own a home session lock. pi is
# anchored: a substring match would claim unrelated commands.
# Deck binds its persistent Firstmate host, never the Deck child: the
# fm-deck-worker driver owns the lock across transient `deck run` turns,
# while a `deck chat` primary binds bin/fm-deck-chat.sh (argv[0] fm-deck-chat)
# for the host's complete startup, supervision and cleanup lifetime.
FM_HARNESS_RE='^pi$|^pi-signed$|^fm-deck-worker$|^fm-deck-chat$'

# Harness executable names for the stricter path evidence below, where a loose
# regex would also match ordinary firstmate paths. Worker liveness
# (bin/fm-agent-process-lib.sh) reads this list too, so it is wider than
# FM_HARNESS_RE; a session-lock match still has to pass FM_HARNESS_RE.
FM_HARNESS_NAMES=(claude codex opencode grok kimi pi-signed pi omp fm-deck-worker fm-deck-chat)

# Print the exact harness name carried by executable path $1 - its own basename
# or any directory component - or return 1.
#
# This exists because some installers name the executable by its version
# (~/.local/share/claude/versions/2.1.220), so the basename identifies nothing
# while the install path still names the harness. Matching whole path
# components only is what keeps that widening safe: an ordinary path such as
# ~/.claude/hooks/notify.sh has no "claude" component and is correctly not a
# harness process.
fm_harness_path_name() {  # <path>
  local path=$1 name
  [ -n "$path" ] || return 1
  for name in "${FM_HARNESS_NAMES[@]}"; do
    case "/$path/" in
      */"$name"/*) printf '%s' "$name"; return 0 ;;
    esac
  done
  return 1
}

# True when the process described by command name $1 and full argument string $2
# is a verified primary harness.
#
# Evidence, in order:
#   1. the basename of the reported command name, against FM_HARNESS_RE.
#   2. an exact harness component in that command path or in argv[0]. Both are
#      needed because the two platforms report different things: macOS reports
#      argv[0] in `ps -o comm=`, while procps on Linux reports the kernel exec
#      name and ignores argv[0] entirely.
fm_harness_process_matches() {  # <comm> <args>
  local comm=$1 args=$2 base argv0 name
  base=$(basename -- "$comm")
  printf '%s' "$base" | grep -qE "$FM_HARNESS_RE" && return 0
  argv0=${args%% *}
  if name=$(fm_harness_path_name "$comm") || name=$(fm_harness_path_name "$argv0"); then
    printf '%s' "$name" | grep -qE "$FM_HARNESS_RE" && return 0
  fi
  return 1
}

# Walk the current process ancestry (up to 16 hops) and print this session's
# verified-harness pid: the innermost harness ancestor. The walk climbs freely
# until that first match, because the caller is normally an ordinary shell
# several levels below its session, and stops there, so it can never cross into
# an unrelated harness further up the real process tree - for example the live
# session that launched a test as its own subprocess. The innermost match is
# also where e.g. Pi's shared signed-wrapper ancestry actually holds the lock: a
# "pi-signed" launcher can be the direct parent of the inner "pi" engine pid that
# owns the lock, and the wrapper pid above it is not that owner.
fm_harness_ancestry_pids() {
  local pid=$$ comm args
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    args=$(ps -o args= -p "$pid" 2>/dev/null)
    if fm_harness_process_matches "$comm" "$args"; then
      printf '%s\n' "$pid"
      return 0
    fi
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Examine the top of the chain before stopping. Inside a PID namespace the
    # harness itself is pid 1, so stopping as soon as the next pid is 1 hides the
    # very process this walk exists to find. A host's real pid 1 (init, systemd,
    # launchd) is not harness-shaped, so fm_harness_process_matches rejects it.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  return 1
}

# Print the one pid that identifies this session when the session lock is being
# WRITTEN.
fm_harness_ancestry_pid() {
  fm_harness_ancestry_pids
}

# True if $1 is a live process that looks like a verified harness.
fm_harness_pid_alive() {
  local pid=$1 comm args
  kill -0 "$pid" 2>/dev/null || return 1
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 1
  args=$(ps -o args= -p "$pid" 2>/dev/null)
  fm_harness_process_matches "$comm" "$args"
}

# True when state dir $1 holds a session lock whose pid is this process's
# harness ancestor: this script runs inside the session that owns the home's
# fleet lock. A missing lock, a malformed lock, a lock held by a harness outside
# this ancestry, or an ancestry that cannot be resolved all fail closed.
fm_session_lock_owned_by_self() {
  local state=$1 lock_pid pids pid
  lock_pid=$(cat "$state/.lock" 2>/dev/null || true)
  case "$lock_pid" in
    ''|*[!0-9]*) return 1 ;;
  esac
  pids=$(fm_harness_ancestry_pids) || return 1
  while IFS= read -r pid; do
    [ "$pid" = "$lock_pid" ] && return 0
  done <<EOF
$pids
EOF
  return 1
}
