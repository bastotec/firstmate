#!/usr/bin/env bash
# fm-ask-triage.sh - rank plain progress status lines that politely ask the
# supervisor for something, so they gain prominence without anything being hidden.
#
# Usage:
#   fm-ask-triage.sh score     score new working: lines (background only)
#   fm-ask-triage.sh present   print the POSSIBLE ASKS section once, then retire
#                              it; held while state/.afk exists
#   fm-ask-triage.sh cost      print measured usage and cost so far
#
# Scope: only `working:` status lines are ever read, sent, or flagged.
# A done, failed, needs-decision, blocked, resolved, paused, note, or any other
# line is never sent to the vendor and never flagged; every line the drain shows
# today it still shows in full.
# A flag only ADDS a POSSIBLE ASKS row that points at the line.
#
# score runs detached from bin/fm-watch.sh at status-signal time and is never
# waited on; bin/fm-wake-drain.sh calls present, which reads local files only and
# never touches the network.
# score reads each status file from the later of its own per-file byte cursor
# and the drain's presentation cursor, so it scores only lines the supervisor
# has not been shown yet, and only complete newline-terminated lines.
# A file it has never seen, or whose identity changed, starts at the
# presentation cursor alone; with that unreadable too it starts at the file end.
# Per pass it sends at most FM_ASK_TRIAGE_MAX_LINES (default 20) of each status
# file's newest new complete working: lines to bin/ask-triage/jev-rank.mjs;
# older new lines past that cap are skipped, never scored late.
# The helper runs under a hard bound of FM_ASK_TRIAGE_TIMEOUT seconds (default
# 6), and a line is flagged when its probability is at least
# FM_ASK_TRIAGE_THRESHOLD (default 0.60).
# A single non-blocking lock lets one scorer run at a time; a running scorer
# re-scans before it exits, so a line appended during its run is not stranded.
#
# Inert by default: score does nothing, silently, unless Node, the pinned
# runtime (npm ci --prefix bin/ask-triage --omit=dev), and the key are all
# present.
# The key lives in the secrets file (FM_ASK_TRIAGE_SECRETS, default ~/.secrets)
# under the variable named by FM_ASK_TRIAGE_KEY_VAR, else the first line of
# config/ask-triage-key-var; with neither there is no default and the pass is
# inert, so naming the variable is the opt-in to spend.
# This script only checks that the variable is defined there; the helper reads
# the value at call time and nothing prints, logs, or passes it.
# A timeout, error, missing key or runtime, unreadable output, or a probability
# under the threshold leaves the line unflagged, which is exactly today's view.
#
# Files, all under state/ask-triage/ (private runtime state):
#   <task>.cursor       "<status-file identity>\t<byte offset>" scored so far
#   pending/<id>.flag   "<task>\t<probability>\t<status line>" awaiting present
#   presented/<id>.flag retired flags, pruned after seven days
#   usage.log           "<epoch>\t<calls>\t<input tokens>\t<output tokens>\t<ms>\t<outcome>"
#                       per helper run; carries no line text; past 2000 rows
#                       it is trimmed to the newest 1500
#   .score.lock/        the single-scorer lock, holding the owner pid
# cost prices input tokens at FM_ASK_TRIAGE_PRICE_PER_MTOK dollars per million
# (default 0.042, the published Jev rate; output is free).
#
# FM_ASK_TRIAGE_HELPER replaces the Node helper command for tests; it receives
# the same input file argument and must print the same rows.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
DIR="$STATE/ask-triage"
RUNTIME_DIR="$SCRIPT_DIR/ask-triage"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

MAX_LINES=${FM_ASK_TRIAGE_MAX_LINES:-20}
case "$MAX_LINES" in ''|*[!0-9]*|0) MAX_LINES=20 ;; esac
TIMEOUT=${FM_ASK_TRIAGE_TIMEOUT:-6}
case "$TIMEOUT" in ''|*[!0-9]*|0) TIMEOUT=6 ;; esac
THRESHOLD=${FM_ASK_TRIAGE_THRESHOLD:-0.60}
case "$THRESHOLD" in ''|*[!0-9.]*) THRESHOLD=0.60 ;; esac

key_var() {
  local name=${FM_ASK_TRIAGE_KEY_VAR:-}
  if [ -z "$name" ] && [ -f "$CONFIG/ask-triage-key-var" ] && [ ! -L "$CONFIG/ask-triage-key-var" ]; then
    IFS= read -r name < "$CONFIG/ask-triage-key-var" || true
    name=${name//[[:space:]]/}
  fi
  [ -n "$name" ] || return 1
  case "$name" in [A-Za-z_]*) ;; *) return 1 ;; esac
  case "$name" in *[!A-Za-z0-9_]*) return 1 ;; esac
  printf '%s' "$name"
}

# 0 when the helper can run: a key variable defined in the secrets file, and
# either the test helper or Node plus the pinned runtime.
enabled() {
  local name secrets=${FM_ASK_TRIAGE_SECRETS:-$HOME/.secrets}
  name=$(key_var) || return 1
  [ -f "$secrets" ] && [ -r "$secrets" ] || return 1
  grep -Eq "^[[:space:]]*(export[[:space:]]+)?${name}=[^[:space:]]" "$secrets" 2>/dev/null || return 1
  [ -n "${FM_ASK_TRIAGE_HELPER:-}" ] && return 0
  command -v node >/dev/null 2>&1 || return 1
  [ -f "$RUNTIME_DIR/node_modules/ai/package.json" ] || return 1
  [ -f "$RUNTIME_DIR/node_modules/@ai-sdk/gateway/package.json" ] || return 1
}

run_helper() {  # <input-file>
  local name
  name=$(key_var) || return 1
  if [ -n "${FM_ASK_TRIAGE_HELPER:-}" ]; then
    FM_ASK_TRIAGE_KEY_VAR=$name fm_run_timed "$TIMEOUT" "$FM_ASK_TRIAGE_HELPER" "$1"
  else
    FM_ASK_TRIAGE_KEY_VAR=$name FM_ASK_TRIAGE_TIMEOUT_MS=$(( (TIMEOUT - 1) * 1000 + 500 )) \
      fm_run_timed "$TIMEOUT" node "$RUNTIME_DIR/jev-rank.mjs" "$1"
  fi
}

lock_acquire() {
  local pid
  if mkdir "$DIR/.score.lock" 2>/dev/null; then
    printf '%s\n' "$$" > "$DIR/.score.lock/pid"
    return 0
  fi
  pid=$(cat "$DIR/.score.lock/pid" 2>/dev/null) || pid=
  case "$pid" in ''|*[!0-9]*) pid= ;; esac
  # A lock with a live owner, or one just created and not yet stamped, is held.
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then return 1; fi
  if [ -z "$pid" ] && [ -n "$(find "$DIR/.score.lock" -maxdepth 0 -mmin -1 2>/dev/null)" ]; then return 1; fi
  rm -rf -- "$DIR/.score.lock"
  mkdir "$DIR/.score.lock" 2>/dev/null || return 1
  printf '%s\n' "$$" > "$DIR/.score.lock/pid"
}

lock_release() { rm -rf -- "$DIR/.score.lock"; }

log_usage() {  # <calls> <in> <out> <ms> <outcome>
  local log="$DIR/usage.log" tmp
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" "$5" >> "$log" || return 0
  if [ "$(wc -l < "$log" 2>/dev/null || echo 0)" -gt 2000 ]; then
    tmp=$(mktemp "$DIR/.usage.XXXXXX") || return 0
    if ! { tail -n 1500 "$log" > "$tmp" && mv -f -- "$tmp" "$log"; }; then rm -f -- "$tmp"; fi
  fi
}

# Collect new complete working: lines from one status file into $CANDIDATES as
# "<task>\t<id>\t<line>" rows and stage its advanced cursor in $CURSOR_UPDATES.
collect_file() {  # <status-file>
  local f=$1 task cursor ident cur_ident offset presented size span end line id pos file_rows=
  task=${f##*/}; task=${task%.status}
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 0
  cursor="$DIR/$task.cursor"
  cur_ident=$(_fm_open_decisions_file_ident "$f") || return 0
  size=$(_fm_status_file_size "$f") || return 0
  size=${size//[[:space:]]/}
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  ident=; offset=
  if [ -f "$cursor" ]; then IFS=$(printf '\t') read -r ident offset < "$cursor" || true; fi
  case "$offset" in ''|*[!0-9]*) ident= ;; esac
  presented=$(status_presentation_cursor_offset "$f" 2>/dev/null) || presented=
  case "$presented" in *[!0-9]*) presented= ;; esac
  if [ -z "$ident" ] || [ "$ident" != "$cur_ident" ] || [ "$offset" -gt "$size" ]; then
    offset=${presented:-$size}
  elif [ -n "$presented" ] && [ "$presented" -gt "$offset" ]; then
    offset=$presented
  fi
  [ "$offset" -le "$size" ] || offset=$size
  [ "$offset" -lt "$size" ] || return 0
  span=$(_fm_status_read_span "$f" "$offset" "$((size - offset))" && printf x) || return 0
  span=${span%x}
  # Only complete lines: stop at the last newline so a half-written append
  # is read whole on a later pass.
  case "$span" in *$'\n'*) ;; *) return 0 ;; esac
  end=${span%$'\n'*}
  pos=$offset
  while IFS= read -r line; do
    # Zero-padded so a plain sort orders one task's flags by position.
    printf -v id '%s.%015d' "$task" "$pos"
    pos=$((pos + ${#line} + 1))
    line=${line//$'\r'/}
    [ "$(status_line_verb "$line")" = working ] || continue
    file_rows="$file_rows$task"$'\t'"$id"$'\t'"$line"$'\n'
  done <<EOF
$end
EOF
  [ -z "$file_rows" ] || CANDIDATES="$CANDIDATES$(printf '%s' "$file_rows" | tail -n "$MAX_LINES")"$'\n'
  CURSOR_UPDATES="$CURSOR_UPDATES$task"$'\t'"$cur_ident"$'\t'"$((offset + ${#end} + 1))"$'\n'
}

commit_cursors() {
  local task ident offset tmp
  while IFS=$(printf '\t') read -r task ident offset; do
    [ -n "$task" ] || continue
    tmp=$(mktemp "$DIR/.cursor.XXXXXX") || continue
    if ! { printf '%s\t%s\n' "$ident" "$offset" > "$tmp" && mv -f -- "$tmp" "$DIR/$task.cursor"; }; then rm -f -- "$tmp"; fi
  done <<EOF
$CURSOR_UPDATES
EOF
}

score_once() {  # -> 0 when it found lines to score
  local f rows input out usage calls tin tout ms outcome=ok i p task id line tmp
  CANDIDATES=; CURSOR_UPDATES=
  # ${#var} must count bytes to match the byte offsets above.
  local LC_ALL=C
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || continue
    collect_file "$f"
  done
  [ -n "$CURSOR_UPDATES" ] || return 1
  if [ -z "$CANDIDATES" ]; then commit_cursors; return 1; fi
  rows=${CANDIDATES%$'\n'}
  input=$(mktemp "$DIR/.input.XXXXXX") || return 1
  printf '%s\n' "$rows" | cut -f3- > "$input"
  if out=$(run_helper "$input" 2>/dev/null); then :; else
    case $? in 124) outcome=timeout ;; *) outcome=error ;; esac
  fi
  rm -f -- "$input"
  usage=$(printf '%s\n' "$out" | head -n 1)
  case "$usage" in
    usage$'\t'*) IFS=$(printf '\t') read -r _ calls tin tout ms <<< "$usage" ;;
    *) calls=0 tin=0 tout=0 ms=0; [ "$outcome" != ok ] || outcome=error ;;
  esac
  [ "$outcome" = ok ] || out=
  log_usage "$calls" "$tin" "$tout" "$ms" "$outcome"
  if [ -n "$out" ] && mkdir -p "$DIR/pending"; then
    i=0
    while IFS=$(printf '\t') read -r task id line; do
      [ -n "$task" ] || continue
      i=$((i + 1))
      p=$(printf '%s\n' "$out" | sed -n "$((i + 1))p")
      case "$p" in ''|-|*[!0-9.]*) continue ;; esac
      awk -v p="$p" -v t="$THRESHOLD" 'BEGIN { exit !(p + 0 >= t + 0) }' || continue
      # A rescore after an interrupted run must not raise an already-shown flag again.
      [ -e "$DIR/presented/$id.flag" ] && continue
      tmp=$(mktemp "$DIR/pending/.flag.XXXXXX") || continue
      if ! { printf '%s\t%s\t%s\n' "$task" "$p" "$line" > "$tmp" && mv -f -- "$tmp" "$DIR/pending/$id.flag"; }; then rm -f -- "$tmp"; fi
    done <<EOF
$rows
EOF
  fi
  # Advance the cursor whatever the outcome, and only after any flag is
  # written: a failed call means that line is shown exactly as today, and
  # retrying would re-spend on every signal.
  commit_cursors
  return 0
}

cmd_score() {
  local pass
  enabled || exit 0
  [ -d "$STATE" ] || exit 0
  mkdir -p "$DIR" 2>/dev/null && chmod 0700 "$DIR" 2>/dev/null || exit 0
  lock_acquire || exit 0
  trap lock_release EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  for pass in 1 2 3; do
    score_once || break
    : "$pass"
  done
  exit 0
}

cmd_present() {
  local f claimed='' base task p line shown=0
  [ -d "$DIR/pending" ] || exit 0
  # While the away daemon owns the drain, keep flags for firstmate's own first
  # drain after it returns rather than spending them on the daemon.
  [ -e "$STATE/.afk" ] && exit 0
  mkdir -p "$DIR/presented" 2>/dev/null || exit 0
  for f in "$DIR/pending"/*.flag; do
    [ -f "$f" ] || continue
    base=${f##*/}
    # Claim by rename so two concurrent drains never print one flag twice.
    mv -- "$f" "$DIR/presented/$base" 2>/dev/null || continue
    claimed="$claimed$DIR/presented/$base"$'\n'
  done
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    IFS=$(printf '\t') read -r task p line < "$f" || continue
    [ -n "$task" ] && [ -n "$line" ] || continue
    if [ "$shown" -eq 0 ]; then
      printf 'POSSIBLE ASKS (working: lines a model ranked as likely asking firstmate for something; each is also shown wherever the drain shows it today):\n' || exit 1
    fi
    printf '%s [p=%s] %s\n' "$task" "$p" "$line" || exit 1
    shown=$((shown + 1))
  done <<EOF
$(printf '%s' "$claimed" | LC_ALL=C sort)
EOF
  find "$DIR/presented" -name '*.flag' -mtime +7 -delete 2>/dev/null || true
  exit 0
}

cmd_cost() {
  local price=${FM_ASK_TRIAGE_PRICE_PER_MTOK:-0.042}
  [ -f "$DIR/usage.log" ] || { printf 'no usage recorded\n'; exit 0; }
  awk -F '\t' -v price="$price" '
    { runs++; calls += $2; tin += $3; tout += $4; ms += $5; out[$6]++ }
    END {
      printf "runs=%d calls=%d input_tokens=%d output_tokens=%d\n", runs, calls, tin, tout
      if (calls > 0) printf "per_line_input_tokens=%.1f per_line_cost_usd=%.9f\n", tin / calls, tin / calls * price / 1000000
      if (runs > 0) printf "mean_run_ms=%.0f total_cost_usd=%.9f\n", ms / runs, tin * price / 1000000
      for (o in out) printf "outcome_%s=%d\n", o, out[o]
    }' "$DIR/usage.log"
}

case "${1:-}" in
  score) cmd_score ;;
  present) cmd_present ;;
  cost) cmd_cost ;;
  *) printf 'usage: %s score|present|cost\n' "${0##*/}" >&2; exit 2 ;;
esac
