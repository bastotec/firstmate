#!/usr/bin/env bash
# Read or replace a machine's binding instructions: ~/.agents/AGENTS.md of the
# account Firstmate runs as on that machine.
#
# Usage:
#   fm-machine-instructions.sh show <machine> [--json]
#   fm-machine-instructions.sh save <machine> [--expect <sha256>|--expect none] [--json] < new-text
#
# <machine> is `local` or an ssh alias bin/fm-machine-skills.sh knows (roots).
# Deck composes ~/.agents/AGENTS.md first into every session it starts on that
# machine, and AGENTS.md section 4 makes it outrank Firstmate's standing rules
# there. Nothing else writes it: dotfiles' installer never does, and this
# script is the only Firstmate writer.
#
# show prints `machine=<m>`, `path=~/.agents/AGENTS.md`, `present=yes|no`,
# `sha=<sha256>|none`, `pickup: <sentence>`, then `---` and the text. --json
# prints {"machine","path","present","sha","text","pickup","mates"} instead.
#
# save replaces the file with stdin (UTF-8 text up to 64 KiB, no NUL bytes) by
# writing a temporary file beside it and renaming it into place, keeping the
# previous version at ~/.agents/AGENTS.md.bak. An empty stdin removes the file
# (the previous version is still kept). --expect refuses the save with exit 3
# when the file changed since it was read (sha) or appeared (none), so two
# editors never overwrite each other. It prints `saved=<sha>|removed` and the
# same pickup sentence: sessions read the file only when they start, so every
# second mate on that machine (and, for local, the primary) picks it up on its
# next restart; new crewmates get it at launch.
#
# A remote machine is reached with `ssh -o BatchMode=yes <alias>` (FM_SSH_BIN
# overrides ssh). Refusals print `refuse: <reason>` and exit 1; usage errors 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SSH_BIN=${FM_SSH_BIN:-ssh}
MAX_BYTES=65536

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
refuse() { printf 'refuse: %s\n' "$1"; exit 1; }

# The file's state on the machine: "present <sha>\n<text>" or "absent".
# shellcheck disable=SC2016 # expanded by the machine's shell.
READ_SH='f=$HOME/.agents/AGENTS.md
if [ -f "$f" ]; then
  s=$( (sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") | cut -d" " -f1)
  printf "present %s\n" "$s"; cat "$f"
else printf "absent\n"; fi'

# Replace the file with stdin unless it changed from $1 (sha, none, or - for any).
# shellcheck disable=SC2016 # expanded by the machine's shell.
WRITE_SH='d=$HOME/.agents f=$d/AGENTS.md expect=$1
sha() { (sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") | cut -d" " -f1; }
mkdir -p "$d" || { echo "refuse: cannot create $d"; exit 1; }
tmp=$(mktemp "$d/.AGENTS.md.XXXXXX") || { echo "refuse: cannot write in $d"; exit 1; }
cat > "$tmp" || { rm -f "$tmp"; echo "refuse: could not receive the text"; exit 1; }
if [ "$expect" != - ]; then
  if [ -f "$f" ]; then now=$(sha "$f"); else now=none; fi
  [ "$now" = "$expect" ] || { rm -f "$tmp"; echo "conflict: $now"; exit 3; }
fi
[ ! -f "$f" ] || cp -p "$f" "$f.bak" || { rm -f "$tmp"; echo "refuse: cannot keep the previous version"; exit 1; }
if [ -s "$tmp" ]; then
  chmod 644 "$tmp" && mv -f "$tmp" "$f" || { rm -f "$tmp"; echo "refuse: cannot replace $f"; exit 1; }
  echo "saved=$(sha "$f")"
else
  rm -f "$tmp" "$f"; echo "saved=removed"
fi'

valid_machine() {
  case "$1" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "$1" = local ] || "$SCRIPT_DIR/fm-machine-skills.sh" roots 2>/dev/null | cut -f1 | grep -qxF -- "$1"
}

on_machine() { # <machine> <script> [args...]; stdin passes through
  local m=$1 script=$2
  shift 2
  if [ "$m" = local ]; then
    sh -c "$script" sh "$@"
  else
    local b64 arg cmd
    b64=$(printf '%s' "$script" | base64 | tr -d '\n')
    cmd="sh -c \"\$(printf %s $b64 | base64 -d)\" sh"
    for arg in "$@"; do cmd="$cmd '$arg'"; done
    # shellcheck disable=SC2029 # built for the remote shell on purpose.
    "$SSH_BIN" -o BatchMode=yes -o ConnectTimeout=8 -o ForwardAgent=no -o ClearAllForwardings=yes "$m" "$cmd"
  fi
}

# Second mates whose route runs on <machine>, space-separated; local adds primary.
mates_on() {
  local m=$1 line out=''
  [ "$m" != local ] || out=primary
  if [ -f "$DATA/secondmates.md" ]; then
    while IFS= read -r line; do
      case "$line" in "- "*) ;; *) continue ;; esac
      secondmate_registry_parse_line "$line" 2>/dev/null || continue
      if [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ]; then
        [ "$SECONDMATE_REGISTRY_HOST" = "$m" ] || continue
      else
        [ "$m" = local ] || continue
      fi
      out="${out:+$out }$SECONDMATE_REGISTRY_ID"
    done < "$DATA/secondmates.md"
  fi
  printf '%s\n' "$out"
}

pickup() { # <machine>
  local mates
  mates=$(mates_on "$1")
  if [ -n "$mates" ]; then
    printf 'Deck reads it when a session starts: %s pick it up on their next restart (bin/fm-control.sh <id> relaunch); new crewmates on %s get it at launch.' "$(printf '%s' "$mates" | sed 's/ /, /g')" "$1"
  else
    printf 'Deck reads it when a session starts: no second mate runs on %s yet; new sessions there get it at launch.' "$1"
  fi
}

json() { # <machine> <present> <sha> <text-file> <pickup> <mates>
  python3 -c 'import json, sys
m, present, sha, path, pickup, mates = sys.argv[1:7]
text = open(path, encoding="utf-8", errors="replace").read()
print(json.dumps({"machine": m, "path": "~/.agents/AGENTS.md", "present": present == "yes",
  "sha": None if sha == "none" else sha, "text": text, "pickup": pickup, "mates": mates.split()}))' "$@"
}

cmd_show() { # <machine> [--json]
  local m=$1 as_json=${2:-} out head present sha tmp
  valid_machine "$m" || refuse "not a known machine: $m"
  out=$(on_machine "$m" "$READ_SH"; printf x) || refuse "could not read ~/.agents/AGENTS.md on $m"
  out=${out%x}
  head=${out%%$'\n'*}
  case "$head" in
    present\ *) present=yes; sha=${head#present }; out=${out#*$'\n'} ;;
    absent) present=no; sha=none; out= ;;
    *) refuse "unexpected answer from $m" ;;
  esac
  if [ "$as_json" = --json ]; then
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-instr.XXXXXX")
    printf '%s' "$out" > "$tmp"
    json "$m" "$present" "$sha" "$tmp" "$(pickup "$m")" "$(mates_on "$m")"
    rm -f "$tmp"
  else
    printf 'machine=%s\npath=~/.agents/AGENTS.md\npresent=%s\nsha=%s\npickup: %s\n---\n%s' "$m" "$present" "$sha" "$(pickup "$m")" "$out"
  fi
}

cmd_save() { # <machine> [--expect <sha|none>] [--json]
  local m=$1 expect=- as_json='' out rc
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expect) [ "$#" -ge 2 ] || usage; expect=$2; shift 2 ;;
      --json) as_json=1; shift ;;
      *) usage ;;
    esac
  done
  case "$expect" in -|none) ;; *[!0-9a-f]*|'') refuse "--expect takes a sha256 or none" ;; esac
  valid_machine "$m" || refuse "not a known machine: $m"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-instr.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  # tmp is global so the EXIT trap still sees it.
  head -c $((MAX_BYTES + 1)) > "$tmp"
  [ "$(wc -c < "$tmp")" -le "$MAX_BYTES" ] || refuse "the instructions are over $MAX_BYTES bytes"
  [ "$(tr -d '\000' < "$tmp" | wc -c)" -eq "$(wc -c < "$tmp")" ] || refuse "the instructions contain a NUL byte"
  set +e
  out=$(on_machine "$m" "$WRITE_SH" "$expect" < "$tmp" 2>&1)
  rc=$?
  set -e
  case "$out" in
    conflict:*) printf 'refuse: ~/.agents/AGENTS.md on %s changed since it was read (now %s); reload it first\n' "$m" "${out#conflict: }"; exit 3 ;;
  esac
  [ "$rc" -eq 0 ] || refuse "${out#refuse: }"
  out=${out##*saved=}
  if [ -n "$as_json" ]; then
    python3 -c 'import json, sys; print(json.dumps({"machine": sys.argv[1], "saved": sys.argv[2], "pickup": sys.argv[3], "mates": sys.argv[4].split()}))' \
      "$m" "$out" "$(pickup "$m")" "$(mates_on "$m")"
  else
    printf 'saved=%s\npickup: %s\n' "$out" "$(pickup "$m")"
  fi
}

[ "$#" -ge 2 ] || usage
sub=$1
shift
case "$sub" in
  show) [ "$#" -le 2 ] || usage; [ "$#" -eq 1 ] || [ "$2" = --json ] || usage; cmd_show "$@" ;;
  save) cmd_save "$@" ;;
  *) usage ;;
esac
