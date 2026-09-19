# shellcheck shell=bash
# The single owner of config/claude-permission-mode resolution: which
# permission flag a claude launch carries. bin/fm-spawn.sh's header owns the
# contract (docs/configuration.md "Claude permission mode" is its operator
# page); this file owns only the resolution, so the launch that puts the flag on
# the command line and bin/fm-remote-secondmate-control.sh, which proves a
# relaunched remote agent actually carries it, can never disagree about it.
#
# Usage: . bin/fm-claude-permission-lib.sh   (no FM_* setup required)

# shellcheck source=bin/fm-config-inherit-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-config-inherit-lib.sh"
# shellcheck source=bin/fm-agent-process-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-agent-process-lib.sh"

# fm_claude_permission_flag: print the flag config/claude-permission-mode under
# <config-dir> selects. A malformed or unreadable file prints the refusal on
# stderr and returns 1, so a caller refuses instead of launching, or accepting,
# a permission posture the captain did not choose.
fm_claude_permission_flag() {  # <config-dir>
  local config=$1 present mode
  present=$(fm_config_source_present "$config/claude-permission-mode") || return 1
  mode=bypass
  if [ "$present" = 1 ]; then
    if [ ! -f "$config/claude-permission-mode" ] || [ ! -r "$config/claude-permission-mode" ]; then
      echo "error: config/claude-permission-mode must be a readable regular file holding one of: bypass, auto" >&2
      return 1
    fi
    mode=$(tr -d '[:space:]' < "$config/claude-permission-mode" || true)
    case "$mode" in
      bypass|auto) ;;
      *)
        echo "error: config/claude-permission-mode holds '$mode'; accepted values are: bypass (--dangerously-skip-permissions, the default when the file is absent), auto (--permission-mode auto)" >&2
        return 1
        ;;
    esac
  fi
  case "$mode" in
    auto) printf '%s\n' '--permission-mode auto' ;;
    *) printf '%s\n' '--dangerously-skip-permissions' ;;
  esac
}

# fm_claude_permission_endpoint_verdict: whether the live claude agent in a
# recorded endpoint carries <flag> (fm_claude_permission_flag's output), read
# from the process's own arguments, never from a name or a rendered surface.
# Prints one line:
#   ok <pid>             the agent process carries the flag
#   mismatch <pid>       the agent process was read and lacks it - for example
#                        a session some other launcher resumed without it
#   unverified <reason>  no agent process could be read, so nothing is claimed
# The caller must already have sourced bin/fm-backend.sh.
fm_claude_permission_endpoint_verdict() {  # <backend> <target> <flag>
  local backend=$1 target=$2 flag=$3 pids pid rc lacking=
  local -a flag_args
  read -r -a flag_args <<< "$flag"
  if ! pids=$(fm_backend_agent_pids "$backend" "$target" 2>/dev/null); then
    printf 'unverified the endpoint processes cannot be read on backend %s\n' "$backend"
    return 0
  fi
  [ -n "$pids" ] || { printf 'unverified no agent process in the endpoint\n'; return 0; }
  for pid in $pids; do
    rc=0
    fm_agent_process_has_args "$pid" "${flag_args[@]}" || rc=$?
    case "$rc" in
      0) printf 'ok %s\n' "$pid"; return 0 ;;
      1) [ -n "$lacking" ] || lacking=$pid ;;
    esac
  done
  if [ -n "$lacking" ]; then
    printf 'mismatch %s\n' "$lacking"
  else
    printf 'unverified the agent process arguments cannot be read\n'
  fi
}
