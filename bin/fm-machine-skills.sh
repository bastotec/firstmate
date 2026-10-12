#!/usr/bin/env bash
# Per-machine skill inventory and skill-aware placement.
#
# Usage:
#   fm-machine-skills.sh refresh [<machine>[:<root>]...]
#   fm-machine-skills.sh roots
#   fm-machine-skills.sh list [<machine>]
#   fm-machine-skills.sh where <skill>...
#   fm-machine-skills.sh check <machine|secondmate-id> <skill>...
#   fm-machine-skills.sh brief-check <brief> <project-dir>
#
# A machine is `local` (the machine this home runs on) or an ssh alias: every
# alias in data/machines.md (bin/fm-machine.sh register) and every host a
# remote route in data/secondmates.md names. Its code root is the recorded
# root (machines.md first, then the first secondmates.md route on that host).
#
# refresh runs `deck skills` in the machine's Firstmate checkout (this home's
# root for local; `ssh <alias>` in the code root, with the remote runtime's
# operator PATH, for a remote) and replaces
# state/machine-skills/<machine>.tsv atomically. The file starts with one
# `# machine=<m> root=<root> refreshed=<UTC ISO time> count=<n>` line, then one
# `<name>\t<scope>\t<path>` line per skill (scope is deck's repo|global).
# list, where and check read only these recorded files, not live discovery;
# they impose no age limit, so consult refreshed before relying on a result.
# With no machine named, refresh attempts all of them; an unreachable machine
# or failed or empty discovery keeps its previous file and prints
# `refresh <m>=failed: <reason>`. Other machines are still attempted, but any
# failure makes refresh exit 1.
# `<alias>:<root>` refreshes a machine not registered yet (bin/fm-machine.sh
# setup runs before register). bin/fm-machine.sh setup and bin/fm-update.sh
# call it. roots prints `<machine>\t<root>` for every known machine.
#
# list prints the recorded inventory: `machine=<m> count=<n> refreshed=<t>`
# per machine, followed by `skill <name> <scope>` lines when one is named.
# where prints `has <machine>` for each machine whose inventory holds every
# named skill, or `has none`.
#
# check answers whether work needing <skill>... may be placed on <machine>, or
# on the machine a secondmate id's route runs on. It prints `place=ok
# machine=<m>` and exits 0, or `place=refuse: <m> lacks <skills>; <where>` and
# exits 1, where <where> names the machines that have them all, or says none
# does. A machine with no recorded inventory is refused (refresh it first).
# A machine whose bridge does not allow placement (bin/fm-bridge.py) is refused
# by check and left out of where.
# A target that names both a known machine and a secondmate on a different
# machine is refused as ambiguous; coincident bindings remain usable.
#
# brief-check reads the brief's first unindented `Skills: <a>, <b>` line
# (absent or empty means none required). Names are comma-separated plain skill
# names; spaces, tabs and backticks are stripped. It checks them against a live
# `deck skills` run in <project-dir>, not the recorded Firstmate inventory.
# It exits 0 when nothing is required or missing, else prints `refuse: ...`
# and exits 1. Missing-skill diagnostics include the inventory's `where` answer;
# invalid names or failed discovery refuse without suggesting a placement.
# A home with no inventory of its own answers where from
# $FM_SECONDMATE_PARENT_HOME's, when set, else asks the primary.
# bin/fm-spawn.sh runs this for ship/scout launches and relaunches using the
# resolved worker Deck executable in the actual task worktree, after allocation
# and any fresh-spawn base refresh, before worker launch. This applies in both
# primary and secondmate homes; it does not check a secondmate charter launch.
#
# FM_DECK_BIN overrides deck and FM_SSH_BIN overrides ssh (tests).
# Usage errors exit 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INV="$STATE/machine-skills"
DECK_BIN=${FM_DECK_BIN:-deck}
SSH_BIN=${FM_SSH_BIN:-ssh}

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() { sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

valid_name() { case "$1" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
sq() {
  printf "'"
  printf '%s' "$1" | sed "s/'/'\\\\''/g"
  printf "'"
}

# Print "<machine>\t<root>" for every known machine, local first.
machines() {
  local line alias root seen=' local '
  printf 'local\t%s\n' "$FM_ROOT"
  if [ -f "$DATA/machines.md" ]; then
    while IFS= read -r line; do
      case "$line" in "- "*) ;; *) continue ;; esac
      alias=$(printf '%s\n' "$line" | awk '{ print $2 }')
      root=$(printf '%s\n' "$line" | sed -n 's/^.*(root: \([^;]*\);.*$/\1/p')
      valid_name "$alias" && [ -n "$root" ] || continue
      case "$seen" in *" $alias "*) continue ;; esac
      seen="$seen$alias "
      printf '%s\t%s\n' "$alias" "$root"
    done < "$DATA/machines.md"
  fi
  if [ -f "$DATA/secondmates.md" ]; then
    while IFS= read -r line; do
      case "$line" in "- "*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" 2>/dev/null || continue
      [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || continue
      alias=$SECONDMATE_REGISTRY_HOST
      valid_name "$alias" || continue
      case "$seen" in *" $alias "*) continue ;; esac
      seen="$seen$alias "
      printf '%s\t%s\n' "$alias" "$SECONDMATE_REGISTRY_ROOT"
    done < "$DATA/secondmates.md"
  fi
}

machine_root() { machines | awk -F '\t' -v m="$1" '$1 == m { print $2; exit }'; }

# `deck skills` lines (name, scope, description, path) -> name\tscope\tpath.
to_tsv() { awk -F '\t' 'NF >= 3 && $1 != "" { print $1 "\t" $2 "\t" $NF }'; }

# Run `deck skills` on <machine> in <root>; prints deck's lines.
deck_skills_on() { # <machine> <root>
  if [ "$1" = local ]; then
    (cd "$2" && "$DECK_BIN" skills < /dev/null)
  else
    # shellcheck disable=SC2029 # quoted for the remote shell on purpose.
    {
      cat "$SCRIPT_DIR/fm-remote-job-lib.sh"
      # shellcheck disable=SC2016 # Expanded by the remote shell, not this one.
      printf '\n%s\n' 'PATH=$(fm_remote_job_compose_operator_path "$HOME") && exec env -i HOME="$HOME" PATH="$PATH" deck skills < /dev/null'
    } | "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=8 -o ForwardAgent=no \
      -o ClearAllForwardings=yes -o 'SendEnv=-*' -o UpdateHostKeys=no \
      -o StrictHostKeyChecking=yes "$1" "cd $(sq "$2") && bash -s"
  fi
}

cmd_refresh() {
  local -a want=() extra=()
  local m root out tmp count failed=0 w arg
  mkdir -p "$INV"
  for arg in "$@"; do
    m=${arg%%:*}
    valid_name "$m" || { printf 'refuse: not a machine name: %s\n' "$m"; exit 2; }
    if [ "$arg" != "$m" ]; then
      root=${arg#*:}
      case "$root" in /*) ;; *) printf 'refuse: root must be absolute: %s\n' "$root"; exit 2 ;; esac
      case "$root" in *$'\n'*|*$'\r'*|*$'\t'*) printf 'refuse: root contains control characters: %s\n' "$root"; exit 2 ;; esac
      extra+=("$m"$'\t'"$root")
    elif [ -z "$(machine_root "$m")" ]; then
      printf 'refresh %s=failed: not a known machine (data/machines.md or a remote route in data/secondmates.md)\n' "$m"
      failed=1
    fi
    want+=("$m")
  done
  while IFS=$'\t' read -r m root; do
    if [ "${#want[@]}" -gt 0 ]; then
      w=" ${want[*]} "
      case "$w" in *" $m "*) ;; *) continue ;; esac
    fi
    if ! out=$(deck_skills_on "$m" "$root" 2>&1); then
      printf 'refresh %s=failed: %s\n' "$m" "$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -n 1)"
      failed=1
      continue
    fi
    out=$(printf '%s\n' "$out" | to_tsv)
    count=$(printf '%s\n' "$out" | grep -c . || true)
    if [ "$count" -eq 0 ]; then
      printf 'refresh %s=failed: deck skills listed nothing in %s\n' "$m" "$root"
      failed=1
      continue
    fi
    tmp=$(mktemp "$INV/.$m.tsv.XXXXXX")
    {
      printf '# machine=%s root=%s refreshed=%s count=%s\n' "$m" "$root" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$count"
      printf '%s\n' "$out"
    } > "$tmp"
    mv -f -- "$tmp" "$INV/$m.tsv"
    printf 'refresh %s=done: %s skills\n' "$m" "$count"
  done < <({ [ "${#extra[@]}" -eq 0 ] || printf '%s\n' "${extra[@]}"; machines; } | awk -F '\t' '!seen[$1]++')
  return "$failed"
}

header_field() { # <file> <key>
  head -n 1 "$1" | tr ' ' '\n' | awk -v k="$2=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'
}

has_skill() { # <machine> <skill>
  [ -f "$INV/$1.tsv" ] && awk -F '\t' -v s="$2" '$1 == s { found = 1 } END { exit found ? 0 : 1 }' "$INV/$1.tsv"
}

cmd_list() {
  local f m
  for f in "$INV"/*.tsv; do
    [ -f "$f" ] || continue
    m=$(basename "$f" .tsv)
    [ -z "${1:-}" ] || [ "$1" = "$m" ] || continue
    printf 'machine=%s count=%s refreshed=%s\n' "$m" "$(header_field "$f" count)" "$(header_field "$f" refreshed)"
    [ -z "${1:-}" ] || awk -F '\t' '!/^#/ { print "skill " $1 " " $2 }' "$f"
  done
}

# Machines whose inventory has every named skill, space-separated.
# Placement must cross an allowed bridge (bin/fm-bridge.py): local always may.
placement_allowed() { # <machine>
  [ "$1" = local ] || FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-bridge.sh" check "$1" placement >/dev/null 2>&1
}

machines_with() {
  local f m s ok found=
  for f in "$INV"/*.tsv; do
    [ -f "$f" ] || continue
    m=$(basename "$f" .tsv)
    ok=1
    placement_allowed "$m" || continue
    for s in "$@"; do has_skill "$m" "$s" || { ok=0; break; }; done
    [ "$ok" -eq 0 ] || found="$found $m"
  done
  printf '%s\n' "${found# }"
}

where_text() {
  local found
  if ! ls "$INV"/*.tsv >/dev/null 2>&1; then
    printf 'this home has no skill inventory; the primary answers with bin/fm-machine-skills.sh where %s' "$*"
    return 0
  fi
  found=$(machines_with "$@")
  if [ -n "$found" ]; then printf 'they are on: %s' "$found"; else printf 'no machine in the inventory has them all'; fi
}

cmd_where() {
  local found m
  found=$(machines_with "$@")
  [ -n "$found" ] || { printf 'has none\n'; return 0; }
  for m in $found; do printf 'has %s\n' "$m"; done
}

cmd_check() { # <machine|secondmate-id> <skill>...
  local target=$1 m missing='' s
  shift
  valid_name "$target" || { printf 'place=refuse: invalid machine or secondmate id: %s\n' "$target"; return 1; }
  m=$target
  if secondmate_registry_line_for_id "$DATA/secondmates.md" "$target" 2>/dev/null; then
    if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then m=$SECONDMATE_REGISTRY_HOST; else m=local; fi
    if [ "$m" != "$target" ] && [ -n "$(machine_root "$target")" ]; then
      printf 'place=refuse: %s is ambiguous: machine %s or secondmate on %s\n' "$target" "$target" "$m"
      return 1
    fi
  fi
  [ -f "$INV/$m.tsv" ] || { printf 'place=refuse: %s has no recorded skill inventory; run bin/fm-machine-skills.sh refresh %s\n' "$m" "$m"; return 1; }
  placement_allowed "$m" || { printf 'place=refuse: the bridge to %s does not allow placement; the captain allows it with bin/fm-bridge.sh allow %s placement or in Fleet Town\n' "$m" "$m"; return 1; }
  for s in "$@"; do has_skill "$m" "$s" || missing="${missing:+$missing, }$s"; done
  if [ -z "$missing" ]; then
    printf 'place=ok machine=%s\n' "$m"
    return 0
  fi
  printf 'place=refuse: %s lacks %s; %s\n' "$m" "$missing" "$(where_text "$@")"
  return 1
}

# The skills a brief's "Skills:" line names, one per line.
brief_skills() { # <brief>
  sed -n 's/^Skills:[[:space:]]*//p' "$1" | head -n 1 | tr ',' '\n' | tr -d ' \t\r`' | grep . || true
}

cmd_brief_check() { # <brief> <project-dir>
  local brief=$1 dir=$2 out s missing=''
  local -a need=()
  [ -f "$brief" ] || { printf 'refuse: no brief at %s\n' "$brief"; return 1; }
  while IFS= read -r s; do
    valid_name "$s" || { printf 'refuse: the Skills line names an invalid skill: %s\n' "$s"; return 1; }
    need+=("$s")
  done < <(brief_skills "$brief")
  [ "${#need[@]}" -gt 0 ] || return 0
  if ! out=$(cd "$dir" && "$DECK_BIN" skills < /dev/null 2>&1); then
    printf 'refuse: deck skills failed in %s, so the skills the brief needs (%s) cannot be confirmed\n' "$dir" "${need[*]}"
    return 1
  fi
  out=$(printf '%s\n' "$out" | to_tsv | cut -f1)
  for s in "${need[@]}"; do
    printf '%s\n' "$out" | grep -qxF -- "$s" || missing="${missing:+$missing, }$s"
  done
  [ -n "$missing" ] || return 0
  # A local secondmate answers "where" from its primary's inventory.
  if ! ls "$INV"/*.tsv >/dev/null 2>&1 && [ -n "${FM_SECONDMATE_PARENT_HOME:-}" ]; then
    INV="$FM_SECONDMATE_PARENT_HOME/state/machine-skills"
  fi
  printf 'refuse: this machine lacks the skills the brief needs (%s); %s\n' "$missing" "$(where_text "${need[@]}")"
  return 1
}

main() {
  [ "$#" -ge 1 ] || usage
  local sub=$1
  shift
  case "$sub" in
    refresh) cmd_refresh "$@" ;;
    roots) [ "$#" -eq 0 ] || usage; machines ;;
    list) [ "$#" -le 1 ] || usage; cmd_list "$@" ;;
    where) [ "$#" -ge 1 ] || usage; cmd_where "$@" ;;
    check) [ "$#" -ge 2 ] || usage; cmd_check "$@" ;;
    brief-check) [ "$#" -eq 2 ] || usage; cmd_brief_check "$@" ;;
    *) usage ;;
  esac
}

main "$@"
