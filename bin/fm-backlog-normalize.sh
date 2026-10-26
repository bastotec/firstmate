#!/usr/bin/env bash
# fm-backlog-normalize.sh - move checked In flight and Queued rows into Done.
#
# Usage: fm-backlog-normalize.sh [--check] [--quiet] [<backlog.md>]
#        fm-backlog-normalize.sh --help
#
# tasks-axi cannot find checked rows outside "## Done" (show, unhold and done
# answer NOT_FOUND), so a captain call on a misplaced row cannot be resolved.
# This command moves checked rows ("- [x]", also "*" and uppercase "X") under
# "## In flight" or "## Queued" to the top of "## Done", creating it if missing.
# Indented body lines move with the row, including blank separators only when
# the next non-blank line is indented; trailing blanks stay in place.
# Rows under other headings, rows before the first heading, and all other lines
# stay untouched. A bare "Done" line is not restored to a heading: it may be
# legitimate text.
#
# The default file is this home's markdown backlog,
# ${FM_DATA_OVERRIDE:-$FM_HOME/data}/backlog.md. A missing file is not an error;
# a final-component symlink is refused.
# Reads and rewrites hold tasks-axi's <backlog>.lock, created exclusively with
# a unique token. Lock contention retries for about 2.5 seconds, then skips
# quietly; cleanup removes the lock only while its token still matches.
# A lock whose token names a process that no longer exists is reclaimed: both
# this command's token and tasks-axi's start with the writer's pid, and a writer
# killed while holding the lock (a timeout's KILL, or a SIGKILL'd caller) would
# otherwise refuse every later backlog write in this home ("backlog lock looks
# stale") until someone removed it by hand.
# The rewrite preserves the file mode and uses an atomic temporary-file rename.
# A checksum guard also skips publication if the file changed during the read.
# A skipped run leaves repair to a later invocation, not a clean-file guarantee.
#
# Automatic invocation is owned by bin/fm-backlog-transition-lib.sh's ADDRESSING
# contract and bin/fm-idle-sweep.sh's scan contract; those callers validate the
# authorized data directory before invoking this command.
#
# Output: one line per repair, "normalized <path>: moved <n> done row(s) into
# Done: <id>[, <id>...]". --quiet suppresses repair and checksum-skip output.
# --check reports misplaced rows without rewriting the backlog and exits 1 when
# any exist; it still acquires the lock and creates a temporary file.
#
# Exit: 0 after repair, no-op, or skip; 1 when --check found misplaced rows or
# a file operation failed (including symlink refusal); 2 on invalid use.
set -u

usage() {
  awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "$0"
}

CHECK=0
QUIET=0
FILE=
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --check) CHECK=1 ;;
    --quiet) QUIET=1 ;;
    -*) usage >&2; exit 2 ;;
    *) [ -z "$FILE" ] || { usage >&2; exit 2; }; FILE=$1 ;;
  esac
  shift
done

if [ -z "$FILE" ]; then
  if [ -n "${FM_DATA_OVERRIDE:-}" ]; then
    FILE="$FM_DATA_OVERRIDE/backlog.md"
  elif [ -n "${FM_HOME:-}" ]; then
    FILE="$FM_HOME/data/backlog.md"
  else
    echo "error: FM_HOME is required when no backlog file is given" >&2
    exit 2
  fi
fi
[ -f "$FILE" ] || exit 0
if [ -L "$FILE" ]; then
  echo "error: $FILE is a symlink; refusing to replace it" >&2
  exit 1
fi

LOCK="$FILE.lock"
LOCK_TOKEN="$$:$(date +%s):$RANDOM:$RANDOM"
tmp=
# shellcheck disable=SC2329 # Invoked by the EXIT trap.
cleanup() {
  [ -z "$tmp" ] || rm -f -- "$tmp"
  if [ "$(cat "$LOCK" 2>/dev/null)" = "$LOCK_TOKEN" ]; then
    rm -f -- "$LOCK"
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Removes the lock when its writer's pid is gone; the token is re-read right
# before removal so a lock taken over meanwhile is left alone.
reclaim_dead_lock() {
  local token pid
  token=$(cat "$LOCK" 2>/dev/null) || return 1
  pid=${token%%:*}
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  [ "$pid" != "$$" ] || return 1
  kill -0 "$pid" 2>/dev/null && return 1
  ps -p "$pid" >/dev/null 2>&1 && return 1
  [ "$(cat "$LOCK" 2>/dev/null)" = "$token" ] || return 1
  rm -f -- "$LOCK"
}
attempt=0
reclaimed=0
until (set -C; printf '%s\n' "$LOCK_TOKEN" > "$LOCK") 2>/dev/null; do
  if [ "$reclaimed" = 0 ] && reclaim_dead_lock; then
    reclaimed=1
    continue
  fi
  attempt=$((attempt + 1))
  [ "$attempt" -lt 26 ] || exit 0
  sleep 0.1
done

# Prints the rewritten backlog on stdout and "<count> <ids>" on fd 3.
rewrite() {  # <file>
  awk '
    function section_of(line,   s) {
      s = line
      sub(/^##[[:space:]]+/, "", s)
      sub(/[[:space:]]+$/, "", s)
      return s
    }
    function row_id(line,   r) {
      r = line
      sub(/^[-*][[:space:]]+\[[xX]\][[:space:]]+/, "", r)
      sub(/[[:space:]].*/, "", r)
      return r
    }
    { line[NR] = $0 }
    END {
      section = ""
      n = 0
      moved = 0
      ids = ""
      done_at = 0
      for (i = 1; i <= NR; i++) {
        l = line[i]
        if (l ~ /^##[[:space:]]+/) {
          section = section_of(l)
          if (section == "Done" && done_at == 0) done_at = i
          keep[i] = 1
          continue
        }
        if ((section == "In flight" || section == "Queued") && l ~ /^[-*][[:space:]]+\[[xX]\][[:space:]]+[^[:space:]]/) {
          moved++
          ids = ids (ids == "" ? "" : ", ") row_id(l)
          block[++n] = l
          j = i + 1
          while (j <= NR) {
            if (line[j] ~ /^[[:space:]]*$/) {
              k = j + 1
              while (k <= NR && line[k] ~ /^[[:space:]]*$/) k++
              if (k > NR || line[k] !~ /^[[:space:]]+[^[:space:]]/) break
              j = k
            } else if (line[j] !~ /^[[:space:]]+[^[:space:]]/) break
            j++
          }
          for (k = i + 1; k < j; k++) block[++n] = line[k]
          i = j - 1
          continue
        }
        keep[i] = 1
      }
      for (i = 1; i <= NR; i++) {
        if (!(i in keep)) continue
        print line[i]
        if (i == done_at) for (k = 1; k <= n; k++) print block[k]
      }
      if (moved > 0 && done_at == 0) {
        print ""
        print "## Done"
        for (k = 1; k <= n; k++) print block[k]
      }
      printf "%d %s\n", moved, ids > "/dev/fd/3"
    }
  ' "$1"
}

before=$(cksum < "$FILE") || exit 1
tmp=$(mktemp "$FILE.normalize.XXXXXX") || exit 1
summary=$(rewrite "$FILE" 3>&1 >"$tmp") || { rm -f "$tmp"; exit 1; }
count=${summary%% *}
ids=${summary#* }
if [ "$count" = 0 ]; then
  rm -f "$tmp"
  exit 0
fi
if [ "$CHECK" = 1 ]; then
  rm -f "$tmp"
  printf 'misplaced %s: %s done row(s) outside Done: %s\n' "$FILE" "$count" "$ids"
  exit 1
fi
if [ "$(cksum < "$FILE")" != "$before" ]; then
  rm -f "$tmp"
  [ "$QUIET" = 1 ] || printf 'skipped %s: it changed while being normalized; the next run repairs it\n' "$FILE"
  exit 0
fi
if ! mode=$(stat -f '%Lp' "$FILE" 2>/dev/null); then
  mode=$(stat -c '%a' "$FILE") || exit 1
fi
chmod "$mode" "$tmp" || exit 1
mv -f "$tmp" "$FILE" || { rm -f "$tmp"; exit 1; }
[ "$QUIET" = 1 ] || printf 'normalized %s: moved %s done row(s) into Done: %s\n' "$FILE" "$count" "$ids"
exit 0
