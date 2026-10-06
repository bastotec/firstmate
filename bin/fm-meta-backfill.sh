#!/usr/bin/env bash
# fm-meta-backfill.sh - one-shot: write an explicit backend= line into every
# task record that predates bin/fm-spawn.sh always writing it.
#
# Usage: fm-meta-backfill.sh [--home DIR] [--dry-run]
#
#   --home DIR  the firstmate home whose state/*.meta to backfill (default: this
#               checkout's FM_HOME, else the repository root)
#   --dry-run   print what would change, write nothing
#
# A record without backend= is read as tmux by every reader
# (bin/fm-backend.sh's fm_backend_of_meta), so tmux is the only value this ever
# writes - it records what the fleet already resolves, it never reclassifies.
# Every other backend has always written its own backend= line, so a record that
# carries another backend's identity keys (herdr_*, zellij_*, cmux_*, orca's
# terminal=/orca_worktree_id=, stream_*) or a herdr-shaped window
# (session:workspace:pane) but no backend= line contradicts that default; it is
# refused rather than guessed. So is a record with no window= at all, or an
# empty backend= line.
#
# A remote second mate's parent-side record (remote_host=) is skipped: its
# backend lives in remote_backend= on its host, and its window=remote:<id> is
# not a local endpoint. One without remote_backend= is refused.
#
# Classification runs over every record first. Any refusal prints every reason
# and exits 1 with nothing written. Otherwise each change is applied under the
# record's own meta lock (the lock fm-spawn.sh holds while it publishes a
# record) as an atomic replace, and printed as "backfilled <id> backend=tmux".
# Records that already carry backend= print nothing. Running it again is a
# no-op. Portable: bash 3.2 and BSD tools (macOS) as well as GNU (Linux).
#
# Exit: 0 done (or nothing to do), 1 a record could not be classified or
# written, 2 usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

HOME_DIR=
DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --home) [ $# -ge 2 ] || { echo "error: --home requires a directory" >&2; exit 2; }
            HOME_DIR=$2; shift 2 ;;
    --home=*) HOME_DIR=${1#--home=}; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "error: unknown argument '$1'" >&2; usage >&2; exit 2 ;;
  esac
done

if [ -z "$HOME_DIR" ]; then
  HOME_DIR=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
fi
[ -d "$HOME_DIR" ] || { echo "error: home '$HOME_DIR' is not a directory" >&2; exit 2; }
STATE_DIR="$HOME_DIR/state"
[ -d "$STATE_DIR" ] || { echo "error: home '$HOME_DIR' has no state directory" >&2; exit 2; }

# The lock helpers derive their own paths from FM_HOME/STATE; point them at the
# home being backfilled, never at whichever checkout runs this script.
export FM_HOME="$HOME_DIR"
export FM_STATE_OVERRIDE="$STATE_DIR"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

# classify <meta>: prints "skip", "tmux", or "refuse <reason>".
classify() {
  local meta=$1 line key has_backend=0 backend_value='' window='' remote_host='' remote_backend='' foreign=''
  while IFS= read -r line || [ -n "$line" ]; do
    key=${line%%=*}
    [ "$key" != "$line" ] || continue
    case "$key" in
      backend) has_backend=1; backend_value=${line#*=} ;;
      window) window=${line#*=} ;;
      remote_host) remote_host=${line#*=} ;;
      remote_backend) remote_backend=${line#*=} ;;
      herdr_*|zellij_*|cmux_*|stream_*|orca_worktree_id|terminal)
        [ -n "$foreign" ] || foreign=$key ;;
    esac
  done < "$meta"
  if [ "$has_backend" = 1 ]; then
    if [ -z "$backend_value" ]; then
      printf 'refuse it has an empty backend= line'
    else
      printf 'skip'
    fi
    return 0
  fi
  if [ -n "$remote_host" ]; then
    if [ -n "$remote_backend" ]; then
      printf 'skip'
    else
      printf 'refuse it is a remote second mate on %s with no remote_backend= line' "$remote_host"
    fi
    return 0
  fi
  if [ -n "$foreign" ]; then
    printf 'refuse it carries %s= but no backend= line, so the tmux default contradicts it' "$foreign"
    return 0
  fi
  case "$window" in
    '') printf 'refuse it records no window= endpoint' ;;
    *:*:*) printf "refuse its window '%s' is not a tmux session:window target" "$window" ;;
    *:*) printf 'tmux' ;;
    *) printf "refuse its window '%s' is not a tmux session:window target" "$window" ;;
  esac
}

# apply <meta>: append backend=tmux atomically under the record's meta lock,
# re-checking under the lock so a concurrent writer that added it wins.
apply() {
  local meta=$1 lock tmp rc=0
  lock=$(fm_meta_lock_path "$meta") || { echo "error: $meta has no lockable task id" >&2; return 1; }
  fm_lock_acquire_wait "$lock"
  if [ -n "$(fm_meta_get "$meta" backend)" ]; then
    fm_lock_release "$lock"
    return 0
  fi
  tmp="$meta.backfill.$$"
  if cp -p "$meta" "$tmp" \
    && { [ ! -s "$tmp" ] || [ -z "$(tail -c 1 "$tmp")" ] || printf '\n' >> "$tmp"; } \
    && printf 'backend=tmux\n' >> "$tmp" \
    && mv -f "$tmp" "$meta"; then
    echo "backfilled $(basename "$meta" .meta) backend=tmux"
  else
    rm -f "$tmp"
    echo "error: could not write $meta" >&2
    rc=1
  fi
  fm_lock_release "$lock"
  return "$rc"
}

PENDING=()
REFUSED=0
for meta in "$STATE_DIR"/*.meta; do
  [ -e "$meta" ] || continue
  if [ -L "$meta" ] || [ ! -f "$meta" ]; then
    echo "refused $(basename "$meta" .meta): it is not a regular file" >&2
    REFUSED=1
    continue
  fi
  verdict=$(classify "$meta")
  case "$verdict" in
    skip) ;;
    tmux) PENDING+=("$meta") ;;
    refuse\ *)
      echo "refused $(basename "$meta" .meta): ${verdict#refuse }" >&2
      REFUSED=1
      ;;
  esac
done

if [ "$REFUSED" = 1 ]; then
  echo "error: nothing was written; fix or retire the refused records, then run again" >&2
  exit 1
fi

[ "${#PENDING[@]}" -gt 0 ] || { echo "nothing to backfill in $STATE_DIR"; exit 0; }

STATUS=0
for meta in "${PENDING[@]}"; do
  if [ "$DRY_RUN" = 1 ]; then
    echo "would backfill $(basename "$meta" .meta) backend=tmux"
  else
    apply "$meta" || STATUS=1
  fi
done
exit "$STATUS"
