#!/usr/bin/env bash
# The machine-readable part of this machine's binding instructions.
#
# Usage:
#   fm-machine-rules.sh check <merge|comment|publish>
#   fm-machine-rules.sh list
#
# A machine's ~/.agents/AGENTS.md (bin/fm-machine-instructions.sh) is the
# captain's standing instruction for that machine and outranks Firstmate's own
# standing rules there, including merge, comment and publish authority and
# yolo (AGENTS.md section 4). Most of it is prose every agent reads; a line
#   firstmate: ask before <action>[, <action>...]
# (case-insensitive, actions merge, comment, publish) also makes this script
# refuse that action for any agent on the machine until the captain approves
# it. Run it on the machine the agent runs on, before the action.
#
# check prints `allow` and exits 0, or prints
#   ask: this machine's ~/.agents/AGENTS.md says "<line>"; ask the captain (a decision card) instead of acting
# and exits 4. An unreadable file refuses the same way. list prints each
# `ask <action>` the file sets. FM_MACHINE_INSTRUCTIONS overrides the file
# (tests). bin/fm-pr-merge.sh runs `check merge`.
# Usage errors exit 2.
set -eu

FILE=${FM_MACHINE_INSTRUCTIONS:-$HOME/.agents/AGENTS.md}

usage() { sed -n '4,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }

# Print "<action>\t<line>" for each asked-for action.
asks() {
  [ -e "$FILE" ] || return 0
  [ -r "$FILE" ] || { printf '*\tunreadable\n'; return 0; }
  awk '
    { l = tolower($0); sub(/^[[:space:]>*-]+/, "", l) }
    l ~ /^firstmate:[[:space:]]*ask before[[:space:]]/ {
      rest = l; sub(/^firstmate:[[:space:]]*ask before[[:space:]]+/, "", rest)
      n = split(rest, a, /[[:space:]]*(,|and)[[:space:]]*/)
      for (i = 1; i <= n; i++) { w = a[i]; gsub(/[^a-z]/, "", w); if (w != "") print w "\t" $0 }
    }' "$FILE"
}

case "${1:-}" in
  check)
    [ "$#" -eq 2 ] || usage
    case "$2" in merge|comment|publish) ;; *) usage ;; esac
    hit=$(asks | awk -F '\t' -v a="$2" '$1 == a || $1 == "*" { print $2; exit }')
    if [ -z "$hit" ]; then printf 'allow\n'; exit 0; fi
    [ "$hit" != unreadable ] || hit="$FILE could not be read"
    printf 'ask: this machine'"'"'s ~/.agents/AGENTS.md says "%s"; ask the captain (a decision card) instead of acting\n' "$(printf '%s' "$hit" | sed 's/^[[:space:]]*//')"
    exit 4
    ;;
  list)
    [ "$#" -eq 1 ] || usage
    asks | cut -f1 | sort -u | sed 's/^/ask /'
    ;;
  *) usage ;;
esac
