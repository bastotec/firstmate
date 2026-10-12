#!/usr/bin/env bash
# Read or change a machine's approval gates (~/.agents/approvals.json) from here.
#
# Usage:
#   fm-machine-approvals.sh show <machine>
#   fm-machine-approvals.sh save <machine> --expect <sha256|none> [--by TEXT] < policy.json
#   fm-machine-approvals.sh audit <machine> [--limit N]
#
# <machine> is `local` or an ssh alias bin/fm-machine-skills.sh knows (roots),
# the same machines bin/fm-machine-instructions.sh accepts. Every verb runs that
# machine's own Firstmate checkout's bin/fm-approval.sh, whose header
# (bin/fm-approval.py) owns the policy format, the locked and audited save, the
# --expect conflict refusal (exit 3) and the JSON shapes:
#   show  -> fm-approval.sh policy-show --json
#   save  -> fm-approval.sh policy-save --expect ... --by ... --json (stdin passes through)
#   audit -> fm-approval.sh policy-audit --json [--limit N]
# Output is that JSON on stdout. A remote machine is reached with
# `ssh -o BatchMode=yes <alias>` (FM_SSH_BIN overrides ssh). Refusals print
# `refuse: <reason>` and exit 1 (3 for a save conflict); usage errors exit 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SSH_BIN=${FM_SSH_BIN:-ssh}

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
refuse() { printf 'refuse: %s\n' "$1"; exit "${2:-1}"; }
sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

root_of() { # <machine> -> that machine's Firstmate code root
  local m=$1
  case "$m" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  if [ "$m" = local ]; then
    printf '%s\n' "$(cd "$SCRIPT_DIR/.." && pwd)"
    return 0
  fi
  "$SCRIPT_DIR/fm-machine-skills.sh" roots 2>/dev/null | awk -F'\t' -v m="$m" '$1 == m { print $2; found = 1; exit } END { exit !found }'
}

run_on() { # <machine> <root> <args...>; stdin passes through
  local m=$1 root=$2 cmd arg
  shift 2
  if [ "$m" = local ]; then
    bash "$root/bin/fm-approval.sh" "$@"
    return
  fi
  cmd="bash $(sq "$root/bin/fm-approval.sh")"
  for arg in "$@"; do cmd="$cmd $(sq "$arg")"; done
  # shellcheck disable=SC2029 # built for the remote shell on purpose.
  "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=8 -o ForwardAgent=no -o ClearAllForwardings=yes "$m" "$cmd"
}

[ "$#" -ge 2 ] || usage
sub=$1 m=$2
shift 2
root=$(root_of "$m") || refuse "not a known machine: $m"
case "$sub" in
  show)
    [ "$#" -eq 0 ] || usage
    out=$(run_on "$m" "$root" policy-show --json < /dev/null 2>&1) || refuse "could not read the approval gates on $m: ${out##*fm-approval: }"
    printf '%s\n' "$out"
    ;;
  save)
    expect='' by='captain (Fleet Town)'
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --expect) [ "$#" -ge 2 ] || usage; expect=$2; shift 2 ;;
        --by) [ "$#" -ge 2 ] || usage; by=$2; shift 2 ;;
        *) usage ;;
      esac
    done
    [ -n "$expect" ] || usage
    set +e
    out=$(run_on "$m" "$root" policy-save --expect "$expect" --by "$by" --json 2>&1)
    rc=$?
    set -e
    case "$rc" in
      0) printf '%s\n' "$out" ;;
      3) refuse "the approval gates on $m changed since they were read; reload them first" 3 ;;
      *) refuse "could not save the approval gates on $m: ${out##*fm-approval: }" ;;
    esac
    ;;
  audit)
    limit=50
    if [ "$#" -gt 0 ]; then
      [ "$#" -eq 2 ] && [ "$1" = --limit ] || usage
      case "$2" in ''|*[!0-9]*) usage ;; esac
      limit=$2
    fi
    out=$(run_on "$m" "$root" policy-audit --json --limit "$limit" < /dev/null 2>&1) || refuse "could not read the approval audit on $m: ${out##*fm-approval: }"
    printf '%s\n' "$out"
    ;;
  *) usage ;;
esac
