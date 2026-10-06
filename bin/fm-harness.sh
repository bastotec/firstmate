#!/usr/bin/env bash
# Detect the agent harness this process tree runs on. Deck is the only
# supported harness.
# Usage: fm-harness.sh                  print own harness: deck|unknown
#        fm-harness.sh crew             print the effective CREWMATE harness
#                                        (config/crew-harness; absent or "default" is deck)
#        fm-harness.sh secondmate       print the harness the PRIMARY uses to launch
#                                        SECONDMATE agents: config/secondmate-harness ->
#                                        config/crew-harness -> deck. "default" or absent
#                                        defers to the crew resolution.
#        fm-harness.sh secondmate-model    print the optional MODEL token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh secondmate-effort   print the optional EFFORT token from
#                                        config/secondmate-harness, or empty when absent.
#        fm-harness.sh ancestry [<pid>] print "comm deck" when a Deck process sits at or
#                                        above <pid> (default this process), or nothing
#                                        when the walk finds none.
# config/secondmate-harness format: a single line "<harness> [<model>] [<effort>]",
# whitespace-separated. Only the first non-empty, non-comment line is parsed.
# Model/effort come ONLY from this file - config/crew-harness stays a bare adapter
# name and is never parsed for a model.
# A configured harness other than deck is refused: crew/secondmate print an error
# naming the file and exit 1, so a home still configured for a removed harness
# fails loudly at spawn instead of launching something unsupported.
# Detection is ancestry only: the nearest Deck process in this process's parent
# chain. Deck sets no identity variable of its own, and an inherited marker from
# a removed harness names nothing this file supports, so no marker is read.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# Read argv[0] without flattening it into a whitespace-delimited command line.
# Linux keeps it in /proc/<pid>/cmdline; elsewhere `ps -o comm=` already reports
# argv[0].
harness_argv0_for_pid() {  # <pid> [comm-fallback]
  local pid=$1 fallback=${2:-} proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc} argv0=
  if [ -r "$proc_root/$pid/cmdline" ]; then
    IFS= read -r -d '' argv0 < "$proc_root/$pid/cmdline" || true
    [ -n "$argv0" ] && { printf '%s\n' "$argv0"; return 0; }
  fi
  if [ -z "$fallback" ]; then
    fallback=$(LC_ALL=C ps -p "$pid" -o comm= 2>/dev/null || true)
  fi
  [ -n "$fallback" ] || return 1
  printf '%s\n' "$fallback"
}

# Print "comm deck" when one process identifies Deck, or nothing.
# Deck is a Rust binary whose process name is exactly `deck`; a Deck worker runs
# it under bin/fm-deck-worker.sh, whose argv[0] is `fm-deck-worker`, and a
# `deck chat` primary under bin/fm-deck-chat.sh (argv[0] `fm-deck-chat`). On
# Linux the kernel name of those two hosts is `bash`, so argv[0] is read too.
# All are anchored so unrelated commands containing these words never read as
# this harness.
harness_process_verdict() {  # <pid>
  local pid=$1 comm argv0
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || return 0
  argv0=$(harness_argv0_for_pid "$pid" "$comm" 2>/dev/null || true)
  case "$(basename -- "$argv0")" in
    fm-deck-worker|fm-deck-chat) echo "comm deck"; return ;;
  esac
  case "$(basename -- "$comm")" in
    deck|fm-deck-worker|fm-deck-chat) echo "comm deck"; return ;;
  esac
}

# Print the verdict for the NEAREST Deck process in the parent chain, or
# nothing when the walk finds none.
harness_ancestry() {  # [<pid>]
  local pid=${1:-$$} verdict
  for _ in 1 2 3 4 5 6 7 8; do
    verdict=$(harness_process_verdict "$pid")
    [ -z "$verdict" ] || { echo "$verdict"; return; }
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    # Stop only once the walk has EXAMINED the top of the chain: inside a PID
    # namespace the harness itself can be pid 1. A host's real pid 1 matches
    # no harness name, so examining it can introduce no false positive.
    case "$pid" in '' | *[!0-9]*) break ;; esac
    [ "$pid" -ge 1 ] || break
  done
  return 0
}

detect_own() {
  local ancestry
  ancestry=$(harness_ancestry)
  if [ -n "$ancestry" ]; then echo "${ancestry#* }"; else echo unknown; fi
}

# Refuse a configured harness other than deck, naming the file it came from.
require_deck() {  # <harness> <config-file>
  [ "$1" = deck ] && return 0
  echo "error: $2 names harness '$1'; deck is the only supported harness" >&2
  return 1
}

# Resolve the effective crewmate harness: config/crew-harness (a bare adapter
# name); absent or "default" is deck.
resolve_crew() {
  local crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ -z "$crew" ] || [ "$crew" = "default" ]; then echo deck; return 0; fi
  require_deck "$crew" "$CONFIG/crew-harness" || return 1
  echo "$crew"
}

# Print the first non-empty, non-comment line of config/secondmate-harness
# (leading/trailing whitespace trimmed), or nothing when the file is absent or
# holds only blank/comment lines.
secondmate_line() {
  local line
  [ -f "$CONFIG/secondmate-harness" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue
    case "$line" in
      '#'*) continue ;;
    esac
    printf '%s\n' "$line"
    return 0
  done < "$CONFIG/secondmate-harness"
}

# Print the 1-based whitespace-separated token (1=harness, 2=model, 3=effort) of
# the resolved secondmate_line, or nothing if the line or that field is absent.
secondmate_field() {
  local idx=$1 line
  line=$(secondmate_line)
  [ -n "$line" ] || return 0
  # shellcheck disable=SC2086  # deliberate word-splitting: tokenizing the line into fields
  set -- $line
  case "$idx" in
    1) printf '%s\n' "${1:-}" ;;
    2) printf '%s\n' "${2:-}" ;;
    3) printf '%s\n' "${3:-}" ;;
  esac
}

# Resolve the harness the PRIMARY uses to launch SECONDMATE agents: a fallback
# chain config/secondmate-harness -> config/crew-harness -> deck. An absent or
# "default" secondmate-harness token defers to the crew resolution.
# config/secondmate-harness is the PRIMARY's own setting and is never inherited
# downstream - secondmates do not spawn secondmates.
resolve_secondmate() {
  local sm
  sm=$(secondmate_field 1)
  if [ -z "$sm" ] || [ "$sm" = "default" ]; then resolve_crew; return; fi
  require_deck "$sm" "$CONFIG/secondmate-harness" || return 1
  echo "$sm"
}

# Print the optional model token (2nd field) from config/secondmate-harness, or
# empty when the harness token is absent/"default" or no model token is present.
resolve_secondmate_model() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 2
}

# Print the optional effort token (3rd field) from config/secondmate-harness,
# the same way.
resolve_secondmate_effort() {
  local sm
  sm=$(secondmate_field 1)
  [ -n "$sm" ] && [ "$sm" != "default" ] || return 0
  secondmate_field 3
}

case "${1:-}" in
  ancestry)
    case "${2:-}" in
      ''|*[!0-9]*) [ -z "${2:-}" ] || { echo "error: ancestry takes a numeric pid" >&2; exit 2; } ;;
    esac
    harness_ancestry "${2:-$$}"
    ;;
  crew) resolve_crew ;;
  secondmate) resolve_secondmate ;;
  secondmate-model) resolve_secondmate_model ;;
  secondmate-effort) resolve_secondmate_effort ;;
  *) detect_own ;;
esac
