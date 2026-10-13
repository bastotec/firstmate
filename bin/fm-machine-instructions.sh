#!/usr/bin/env bash
# Read or replace a machine's binding instructions: ~/.agents/AGENTS.md of the
# account Firstmate runs as on that machine.
#
# Usage:
#   fm-machine-instructions.sh show <machine> [--json]
#   fm-machine-instructions.sh save <machine> --expect <sha256|none> [--json] < new-text
#
# <machine> is `local` or an ssh alias bin/fm-machine-skills.sh knows (roots).
# Register a new alias with bin/fm-machine.sh register first, unless a remote
# secondmate route already records it; setup alone does not register it.
# AGENTS.md section 4 owns instruction precedence. Deck composes this file
# first into every session it starts on that machine. The dotfiles skills
# installer never writes it; this script is the only Firstmate writer.
#
# show prints `machine=<m>`, `path=~/.agents/AGENTS.md`, `present=yes|no`,
# `sha=<sha256>|none`, `pickup: <sentence>`, then `---` and the text. --json
# prints {"machine","path","present","sha","text","pickup","mates"} instead.
#
# save replaces the file with stdin (UTF-8 text up to 64 KiB, no NUL bytes) by
# writing a temporary file beside it and renaming it into place, keeping the
# previous version at ~/.agents/AGENTS.md.bak. An empty stdin removes the file
# (the previous version is still kept). --expect refuses the save with exit 3
# when the file changed since it was read (sha) or appeared (none), so concurrent
# saves through this script cannot overwrite a changed version. --expect is
# required; saves serialize on the machine and refuse a busy lock after ten
# seconds. The existing file's permissions are preserved on replacement and
# backup; new files are private (0600). It prints `saved=<sha>|removed` and the
# same pickup sentence: sessions read the file only when they start, so every
# second mate on that machine (and, for local, the primary) picks it up on its
# next restart; new crewmates get it at launch.
#
# A remote machine is reached through fm-on.sh (FM_SSH_BIN overrides ssh).
# Refusals print `refuse: <reason>` and exit 1; usage errors 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
MAX_BYTES=65536

# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() { sed -n '5,6p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
refuse() { printf 'refuse: %s\n' "$1"; exit 1; }

# The file's state on the machine: "present <sha>\n<text>" or "absent".
# shellcheck disable=SC2016 # expanded by the machine's shell.
READ_SH='f=$HOME/.agents/AGENTS.md
if [ -f "$f" ]; then
  s=$(sha256sum "$f" 2>/dev/null || shasum -a 256 "$f") || exit 1
  s=${s%% *}
  [ "${#s}" -eq 64 ] || exit 1
  case "$s" in *[!0-9a-f]*) exit 1 ;; esac
  printf "present %s\n" "$s"
  cat "$f" || exit 1
else printf "absent\n"; fi'

# Replace the file with stdin unless it changed from $1 (sha or none).
# shellcheck disable=SC2016 # expanded by the machine's shell.
WRITE_SH='d=$HOME/.agents f=$d/AGENTS.md expect=$1
sha() {
  s=$(sha256sum "$1" 2>/dev/null || shasum -a 256 "$1") || return 1
  s=${s%% *}
  [ "${#s}" -eq 64 ] || return 1
  case "$s" in *[!0-9a-f]*) return 1 ;; esac
  printf "%s\n" "$s"
}
umask 077
mkdir -p "$d" || { echo "refuse: cannot create $d"; exit 1; }
tmp=$(mktemp "$d/.AGENTS.md.XXXXXX") || { echo "refuse: cannot write in $d"; exit 1; }
locked=no
trap '\''rm -f "$tmp"; [ "$locked" != yes ] || rmdir "$d/.AGENTS.md.lock"'\'' 0
trap '\''exit 1'\'' 1 2 15
cat > "$tmp" || { echo "refuse: could not receive the text"; exit 1; }
n=0
until mkdir "$d/.AGENTS.md.lock" 2>/dev/null; do
  n=$((n + 1))
  [ "$n" -lt 100 ] || { echo "refuse: instructions writer lock is busy"; exit 1; }
  sleep 0.1
done
locked=yes
mode=600
if [ -f "$f" ]; then
  now=$(sha "$f") || { echo "refuse: cannot hash $f"; exit 1; }
  mode=$(stat -c %a "$f" 2>/dev/null || stat -f %Lp "$f") || exit 1
else now=none; fi
[ "$now" = "$expect" ] || { echo "conflict: $now"; exit 3; }
[ ! -f "$f" ] || cp -p "$f" "$f.bak" || { echo "refuse: cannot keep the previous version"; exit 1; }
if [ -s "$tmp" ]; then
  saved=$(sha "$tmp") || { echo "refuse: cannot hash received text"; exit 1; }
  chmod "$mode" "$tmp" && mv -f "$tmp" "$f" || { echo "refuse: cannot replace $f"; exit 1; }
  echo "saved=$saved"
else
  rm -f "$f" || { echo "refuse: cannot remove $f"; exit 1; }
  echo "saved=removed"
fi'

valid_machine() {
  case "$1" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "$1" = local ] || "$SCRIPT_DIR/fm-machine-skills.sh" roots 2>/dev/null | cut -f1 | grep -qxF -- "$1"
}

on_machine() {
  local m=$1 operation=$2 root
  local -a input=()
  shift 2
  if [ "$m" = local ]; then
    case "$operation" in
      read) sh -c "$READ_SH" sh ;;
      write) sh -c "$WRITE_SH" sh "$@" ;;
    esac
  else
    root=$("$SCRIPT_DIR/fm-machine-skills.sh" roots | awk -F '\t' -v m="$m" '$1 == m { print $2; exit }')
    [ "$operation" != write ] || input=(--stdin)
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$SCRIPT_DIR/.." \
      "$SCRIPT_DIR/fm-on.sh" "${input[@]+"${input[@]}"}" --machine-root "$root" "$m" fm-machine-instructions.sh "$operation-local" "$@"
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
  out=$(on_machine "$m" read && printf x) || refuse "could not read ~/.agents/AGENTS.md on $m"
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

cmd_save() { # <machine> --expect <sha|none> [--json]
  local m=$1 expect='' as_json='' out rc
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --expect) [ "$#" -ge 2 ] || usage; expect=$2; shift 2 ;;
      --json) as_json=1; shift ;;
      *) usage ;;
    esac
  done
  [ -n "$expect" ] || usage
  if [ "$expect" != none ]; then
    case "$expect" in *[!0-9a-f]*) refuse "--expect takes a sha256 or none" ;; esac
    [ "${#expect}" -eq 64 ] || refuse "--expect takes a sha256 or none"
  fi
  valid_machine "$m" || refuse "not a known machine: $m"
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-instr.XXXXXX")
  trap 'rm -f "$tmp"' EXIT
  # tmp is global so the EXIT trap still sees it.
  head -c $((MAX_BYTES + 1)) > "$tmp"
  [ "$(wc -c < "$tmp")" -le "$MAX_BYTES" ] || refuse "the instructions are over $MAX_BYTES bytes"
  [ "$(tr -d '\000' < "$tmp" | wc -c)" -eq "$(wc -c < "$tmp")" ] || refuse "the instructions contain a NUL byte"
  set +e
  out=$(on_machine "$m" write "$expect" < "$tmp" 2>&1)
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

[ "$#" -ge 1 ] || usage
sub=$1
shift
case "$sub" in
  read-local) [ "$#" -eq 0 ] || usage; on_machine local read; exit ;;
  write-local) [ "$#" -eq 1 ] || usage; on_machine local write "$1"; exit ;;
esac
[ "$#" -ge 1 ] || usage
case "$sub" in
  show) [ "$#" -le 2 ] || usage; [ "$#" -eq 1 ] || [ "$2" = --json ] || usage; cmd_show "$@" ;;
  save) cmd_save "$@" ;;
  *) usage ;;
esac
