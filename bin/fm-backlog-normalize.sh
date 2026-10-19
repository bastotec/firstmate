#!/usr/bin/env bash
# fm-backlog-normalize.sh - move done rows that sit outside "## Done" into it.
#
# Usage: fm-backlog-normalize.sh [--check] [--quiet] [<backlog.md>]
#        fm-backlog-normalize.sh --help
#
# A markdown backlog row marked done ("- [x] <id> - ...") belongs under
# "## Done". When one ends up under "## In flight" or "## Queued" (a lost
# section heading, a hand edit), tasks-axi no longer finds it (show, unhold and
# done answer NOT_FOUND) while readers that go by section still treat it as
# open work, so a captain call written on it can never be answered or closed.
# This command moves every such row, with its indented body lines, to the top
# of "## Done", creating that section when it is missing. Rows under any other
# heading, rows before the first heading, and every other line stay exactly as
# they are.
#
# The default file is this home's markdown backlog,
# ${FM_DATA_OVERRIDE:-$FM_HOME/data}/backlog.md. A missing file is not an error.
# The rewrite is atomic (temporary file plus rename) and is skipped when the
# file changed while it was being read, so a concurrent tasks-axi write is never
# lost; the next run repairs whatever is still misplaced.
#
# bin/fm-tasks-axi.sh runs this before every tasks-axi command, and
# bin/fm-idle-sweep.sh runs it on every scan, so a misplaced row heals in every
# home on its own.
#
# Output: one line per repair, "normalized <path>: moved <n> done row(s) into
# Done: <id>[, <id>...]". --quiet prints nothing on success.
# --check reports misplaced rows without rewriting and exits 1 when any exist.
#
# Exit: 0 after a check or repair with nothing left misplaced, 1 when --check
# found misplaced rows or the rewrite failed, 2 on invalid use.
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
          while (j <= NR && line[j] ~ /^[[:space:]]+[^[:space:]]/) {
            block[++n] = line[j]
            j++
          }
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
chmod "$(stat -f '%Lp' "$FILE" 2>/dev/null || stat -c '%a' "$FILE")" "$tmp" 2>/dev/null || true
mv -f "$tmp" "$FILE" || { rm -f "$tmp"; exit 1; }
[ "$QUIET" = 1 ] || printf 'normalized %s: moved %s done row(s) into Done: %s\n' "$FILE" "$count" "$ids"
exit 0
