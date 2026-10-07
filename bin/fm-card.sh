#!/usr/bin/env bash
# fm-card.sh - decision cards: the captain-facing summary of each captain hold.
#
# A card is the record a captain surface (the Fleet app, Ziggy) reads to show
# one pending captain call: what is going on in at most two lines, the options
# with the exact instruction each sends to the first mate, and the first mate's
# recommendation.
# It lives at state/cards/<task-id>.json, mode 0600, written atomically.
# The backlog hold stays the authority on whether a call is open; a card never
# opens or closes one, and bin/fm-captain-hold.sh owns every hold and close.
#
# Usage:
#   fm-card.sh validate --file <card.json>
#   fm-card.sh write <task-id> --file <card.json>
#   fm-card.sh show <task-id>
#   fm-card.sh remove <task-id>
#   fm-card.sh draft <task-id> --title <title> --project <project> --situation <text>
#   fm-card.sh backfill
#   fm-card.sh stale
#   fm-card.sh clear <task-id> --why <text>
#   fm-card.sh restore <task-id>
#
# Input JSON for write is exactly one object carrying project, title,
# situation, options and recommended; the script adds version, task, draft,
# created and updated.
# Limits: title <= 120 chars; situation <= 280 chars and <= 2 lines; 1-9
# options keyed "1".."9" in order; label <= 40 chars; instruction <= 1000
# chars; recommended names one option; no control characters except newlines
# in instruction and the single newline allowed in situation.
# A draft card (draft: true, no options, recommended null) stands in for a
# hold whose holder could not write a judgment; `draft` never replaces a full
# card, and the first mate replaces drafts with full cards at its next review.
# `backfill` drafts a card for every captain-held task in this home that has
# none, using its title, repo and hold reason.
# `stale` is read-only and prints "<task-id>\t<kind>\t<why>" per candidate:
# `orphan` (a card with no open captain hold), `pr-merged` (the task's
# recorded PR has a matching merge notification), or `idle` (held 3+ days,
# with no status-log change since the cutoff, no worker record at
# state/<task-id>.meta, and no hold_until date, past or future).
# An unreadable backlog refuses classification or clearing rather than being
# treated as proof that the card is orphaned.
# These are candidates for the first mate to verify, not automatic closes;
# there is no closed-PR rule because no closed-PR state is recorded locally.
# `clear` removes an orphan card, or closes a stale call through
# `fm-captain-hold.sh stale-clear` with the why as evidence; either way it
# appends one JSON line to state/cards-cleared.log carrying the prior hold
# reason and card. Each line has at (UTC timestamp), event (cleared or
# restored), task, kind (orphan or stale), why (evidence or restore note),
# reason (prior hold reason), and card (prior card object or null).
# `restore` undoes the newest clear of a task only while it is still Done with
# newest resolution mode stale-cleared: it reopens and re-holds with the prior
# reason and full card, or a draft when no full card was saved.
# It refuses after a newer captain answer, after other work has reopened the
# task, when already held again, after a restore, or for an orphan card.
# Restore starts a new hold lifecycle and does not restore a deferral date.
# `show` exits 1 when the task has no card and 2 when its card is invalid.
# FM_CARD_NOW overrides the UTC timestamp for tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CARDS="$STATE/cards"
CLEAR_LOG="$STATE/cards-cleared.log"
HOLD="$SCRIPT_DIR/fm-captain-hold.sh"
TASKS="$SCRIPT_DIR/fm-tasks-axi.sh"

# shellcheck source=bin/fm-pr-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() { awk '/^# Usage:/{on=1; next} on && /^#$/{exit} on{sub(/^#   /, ""); print}' "${BASH_SOURCE[0]}"; }
die() { printf 'fm-card: %s\n' "$1" >&2; exit "${2:-2}"; }
now() { printf '%s' "${FM_CARD_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

require_slug() {  # <task-id>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*|.|..) die "task id must be a privacy-safe slug: ${1:-}" ;;
  esac
}

card_path() { printf '%s/%s.json\n' "$CARDS" "$1"; }

# Prints the first validation error as "<field>: <why>", or nothing when valid.
# Works on the input shape and on stored full cards alike.
card_error() {  # <path>
  jq -rs '
    def ctl: test("[\u0000-\u0009\u000b-\u001f\u007f]");
    def oneline: test("[\u0000-\u001f\u007f]");
    if length != 1 then "card: exactly one JSON object required"
    else .[0] |
    if type != "object" then "card: not a JSON object"
    elif (.title|type) != "string" or (.title|length) == 0 or (.title|length) > 120 or (.title|oneline) then "title: required, one line, at most 120 characters"
    elif (.project|type) != "string" or (.project|test("^[A-Za-z0-9._-]+$")|not) then "project: required slug"
    elif (.situation|type) != "string" or (.situation|length) == 0 or (.situation|length) > 280 or (.situation|ctl) or ((.situation|split("\n")|length) > 2) then "situation: required, at most 280 characters and 2 lines"
    elif (.options|type) != "array" or (.options|length) < 1 or (.options|length) > 9 then "options: 1 to 9 options required"
    elif ([.options|to_entries[]|select((.value|type) != "object" or .value.key != ((.key+1)|tostring))]|length) > 0 then "options: keys must be \"1\"..\"9\" in order"
    elif ([.options[]|select((.label|type) != "string" or (.label|length) == 0 or (.label|length) > 40 or (.label|oneline))]|length) > 0 then "options: each label is one line of at most 40 characters"
    elif ([.options[]|select((.instruction|type) != "string" or (.instruction|length) == 0 or (.instruction|length) > 1000 or (.instruction|ctl))]|length) > 0 then "options: each instruction is at most 1000 characters"
    elif (.recommended|type) != "string" or (.recommended as $r | [.options[].key] | index($r)) == null then "recommended: must name one option key"
    else empty end end
  ' "$1" 2>/dev/null || printf 'card: not valid JSON\n'
}

cmd_validate() {
  local file='' err
  while [ "$#" -gt 0 ]; do
    case "$1" in --file) shift; file=${1:-} ;; *) usage >&2; exit 2 ;; esac
    shift
  done
  [ -f "$file" ] || die "--file must name a readable card file"
  err=$(card_error "$file")
  [ -z "$err" ] || die "invalid card: $err"
}

# Atomic, owner-only write of a complete stored card read from stdin.
store_card() {  # <task-id>
  local dest tmp
  dest=$(card_path "$1")
  (umask 077; mkdir -p "$CARDS")
  tmp=$(umask 077; mktemp "$CARDS/.$1.XXXXXX") || die "cannot stage card for $1"
  if ! cat > "$tmp"; then rm -f -- "$tmp"; die "cannot stage card for $1"; fi
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; die "cannot publish card for $1"; }
  printf '%s\n' "$dest"
}

existing_created() {  # <task-id>
  local p
  p=$(card_path "$1")
  [ -f "$p" ] || return 0
  jq -r '.created // empty' "$p" 2>/dev/null || true
}

cmd_write() {
  local id=${1:-} file='' created ts
  [ "$#" -ge 1 ] && shift
  require_slug "$id"
  while [ "$#" -gt 0 ]; do
    case "$1" in --file) shift; file=${1:-} ;; *) usage >&2; exit 2 ;; esac
    shift
  done
  cmd_validate --file "$file"
  ts=$(now)
  created=$(existing_created "$id")
  [ -n "$created" ] || created=$ts
  jq -c --arg task "$id" --arg created "$created" --arg updated "$ts" '
    {version: 1, task: $task, project, title, situation, options, recommended,
     draft: false, created: $created, updated: $updated}' "$file" | store_card "$id"
}

cmd_show() {
  local id=${1:-} p
  require_slug "$id"
  p=$(card_path "$id")
  [ -f "$p" ] || exit 1
  if [ "$(jq -r '.draft // false' "$p" 2>/dev/null)" = true ]; then
    jq -e '(.task|type) == "string" and (.title|type) == "string" and (.situation|type) == "string"' "$p" >/dev/null 2>&1 \
      || die "invalid card: $id"
  else
    [ -z "$(card_error "$p")" ] || die "invalid card: $id"
  fi
  cat "$p"
}

cmd_remove() {
  local id=${1:-}
  require_slug "$id"
  rm -f -- "$(card_path "$id")"
}

tasks() { FM_HOME="$FM_HOME" "$TASKS" "$@"; }

# A tasks-axi show field arrives either bare or as a JSON-encoded string.
shown_value() {  # <show-output> <field>
  local v
  v=$(printf '%s\n' "$1" | sed -n "s/^  $2: //p" | head -1)
  case "$v" in
    \"*\") v=$(printf '%s' "$v" | jq -r . 2>/dev/null) || v='' ;;
  esac
  [ "$v" != '-' ] || v=''
  printf '%s' "$v"
}

# Situation for a draft: first two lines, at most 280 characters, as JSON.
clip_situation() {  # <text>
  printf '%s' "$1" | awk 'NR<=2' | jq -Rs 'rtrimstr("\n") | .[0:280]'
}

cmd_draft() {
  local id=${1:-} title='' project='' situation='' p ts
  [ "$#" -ge 1 ] && shift
  require_slug "$id"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --title) shift; title=${1:-} ;;
      --project) shift; project=${1:-} ;;
      --situation) shift; situation=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [ -n "$title" ] && [ -n "$situation" ] || die "draft needs --title and --situation"
  case "$project" in ''|*[!A-Za-z0-9._-]*) project=firstmate ;; esac
  p=$(card_path "$id")
  if [ -f "$p" ] && [ "$(jq -r '.draft // false' "$p" 2>/dev/null)" = false ]; then
    printf 'kept: %s\n' "$p"
    return 0
  fi
  ts=$(now)
  jq -cn --arg task "$id" --arg project "$project" --arg title "$title" \
    --argjson situation "$(clip_situation "$situation")" --arg ts "$ts" '
    {version: 1, task: $task, project: $project, title: ($title | .[0:120]),
     situation: $situation, options: [], recommended: null, draft: true,
     created: $ts, updated: $ts}' | store_card "$id"
}

# Ids of tasks held for the captain: the last column of each listed row is
# its hold kind, and an id is a slug, so neither needs CSV decoding.
captain_held_ids() {
  tasks list --state held --fields hold_kind 2>/dev/null \
    | sed -n 's/^  \([A-Za-z0-9._-][A-Za-z0-9._-]*\),.*,captain$/\1/p'
}

cmd_backfill() {
  local id show title repo reason
  for id in $(captain_held_ids); do
    [ -f "$(card_path "$id")" ] && continue
    show=$(tasks show "$id" --full 2>/dev/null) || continue
    title=$(shown_value "$show" title)
    repo=$(shown_value "$show" repo)
    reason=$(shown_value "$show" hold_reason)
    cmd_draft "$id" --title "${title:-$id}" --project "${repo:-firstmate}" --situation "${reason:-${title:-$id}}" >/dev/null
    printf 'drafted: %s\n' "$id"
  done
}

hold_tool() { FM_HOME="$FM_HOME" "$HOLD" "$@"; }

# 0 when the task is an open captain call, 1 when it is not; anything else
# means the backlog could not answer, which is never read as "not held".
held_state() {  # <task-id>
  local rc=0
  hold_tool open "$1" >/dev/null 2>&1 || rc=$?
  case "$rc" in
    0|1) return "$rc" ;;
    *) die "cannot tell whether $1 is held for the captain; refusing to act" ;;
  esac
}

is_captain_held() { held_state "$1"; }

epoch_of() {  # <UTC YYYY-MM-DDTHH:MM:SSZ or YYYY-MM-DD>
  local t=$1
  case "$t" in ????-??-??) t="${t}T00:00:00Z" ;; esac
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$t" +%s 2>/dev/null || date -u -d "$t" +%s 2>/dev/null
}

mtime_of() {  # <path>
  case "$(uname -s)" in
    Darwin) /usr/bin/stat -f %m "$1" ;;
    *) stat -c %Y "$1" ;;
  esac
}

meta_get() {  # <task-id> <key>
  [ -f "$STATE/$1.meta" ] || return 0
  sed -n "s/^$2=//p" "$STATE/$1.meta" | tail -1
}

cmd_stale() {
  local p id now_s cutoff set set_s show until pr
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  now_s=$(epoch_of "$(now)") || die "cannot read the current time"
  cutoff=$(( now_s - 3 * 86400 ))
  [ -d "$CARDS" ] || return 0
  for p in "$CARDS"/*.json; do
    [ -f "$p" ] || continue
    id=$(basename "$p" .json)
    if ! is_captain_held "$id"; then
      printf '%s\torphan\tcard has no open captain hold\n' "$id"
      continue
    fi
    show=$(tasks show "$id" --full 2>/dev/null) || die "cannot read task $id"
    pr=$(meta_get "$id" pr)
    if fm_pr_url_parse "$pr" \
      && fm_pr_poll_merge_already_notified "$STATE" "$id" "$FM_PR_PROVIDER" "$FM_PR_HOST" "$FM_PR_PATH" "$FM_PR_NUMBER"; then
      printf '%s\tpr-merged\t%s merged\n' "$id" "$pr"
      continue
    fi
    # A hold that gates a tracked worker, or that the captain deferred to a
    # date, is not idle; those leave through their own paths.
    [ ! -f "$STATE/$id.meta" ] || continue
    until=$(shown_value "$show" hold_until)
    [ -z "$until" ] || continue
    set=$(shown_value "$show" body | sed -n '1s/^Captain hold set: \([0-9TZ:-]*\)$/\1/p')
    [ -n "$set" ] || continue
    set_s=$(epoch_of "$set") || continue
    [ "$set_s" -le "$cutoff" ] || continue
    if [ -f "$STATE/$id.status" ] && [ "$(mtime_of "$STATE/$id.status")" -ge "$cutoff" ]; then
      continue
    fi
    printf '%s\tidle\theld since %s with no activity for 3 days\n' "$id" "$set"
  done
}

log_line() {  # <event> <task> <kind> <why> <reason> <card-json-or-null>
  (umask 077; touch "$CLEAR_LOG")
  jq -cn --arg at "$(now)" --arg event "$1" --arg task "$2" --arg kind "$3" \
    --arg why "$4" --arg reason "$5" --argjson card "$6" \
    '{at: $at, event: $event, task: $task, kind: $kind, why: $why, reason: $reason, card: $card}' >> "$CLEAR_LOG"
}

cmd_clear() {
  local id=${1:-} why='' p card='null' show reason ev
  [ "$#" -ge 1 ] && shift
  require_slug "$id"
  while [ "$#" -gt 0 ]; do
    case "$1" in --why) shift; why=${1:-} ;; *) usage >&2; exit 2 ;; esac
    shift
  done
  [ -n "$why" ] || die "--why is required"
  p=$(card_path "$id")
  if [ -f "$p" ]; then
    card=$(jq -c . "$p" 2>/dev/null) || card='null'
  fi
  if ! is_captain_held "$id"; then
    [ -f "$p" ] || die "task $id is not a captain call and has no card"
    rm -f -- "$p"
    log_line cleared "$id" orphan "$why" "" "$card"
    printf 'cleared: %s (orphan card)\n' "$id"
    return 0
  fi
  show=$(tasks show "$id" --full 2>/dev/null) || die "cannot read task $id"
  reason=$(shown_value "$show" hold_reason)
  ev=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-card-evidence.XXXXXX") || die "cannot stage evidence"
  printf '%s\n' "$why" > "$ev"
  if ! hold_tool stale-clear "$id" --evidence-file "$ev" >/dev/null; then
    rm -f -- "$ev"
    die "could not clear $id"
  fi
  rm -f -- "$ev"
  log_line cleared "$id" stale "$why" "$reason" "$card"
  printf 'cleared: %s\n' "$id"
}

cmd_restore() {
  local id=${1:-} line reason card input show mode
  require_slug "$id"
  [ -f "$CLEAR_LOG" ] || die "nothing was cleared"
  line=$(jq -c --arg id "$id" 'select(.task == $id)' "$CLEAR_LOG" | tail -n 1)
  [ -n "$line" ] || die "no clear recorded for $id"
  [ "$(printf '%s' "$line" | jq -r .event)" = cleared ] || die "$id was already restored"
  ! is_captain_held "$id" || die "$id is already held again; nothing to restore"
  reason=$(printf '%s' "$line" | jq -r .reason)
  [ -n "$reason" ] || die "$id was an orphan card; there is no hold to restore"
  # Only undo the clear itself: the task must still be closed by it, with no
  # newer answer or work on top.
  show=$(tasks show "$id" --full 2>/dev/null) || die "cannot read task $id"
  [ "$(shown_value "$show" state)" = "done" ] || die "$id has moved on since it was cleared; nothing to restore"
  mode=$(shown_value "$show" body | sed -n 's/^Resolution mode: //p' | head -1)
  [ "$mode" = stale-cleared ] || die "$id was resolved again after the clear; refusing to undo that"
  card=$(printf '%s' "$line" | jq -c .card)
  tasks reopen "$id" >/dev/null || die "could not reopen $id"
  if [ "$card" != null ] && [ "$(printf '%s' "$card" | jq -r .draft)" = false ]; then
    input=$(umask 077; mktemp "${TMPDIR:-/tmp}/fm-card-restore.XXXXXX") || die "cannot stage the card"
    printf '%s' "$card" | jq '{project, title, situation, options, recommended}' > "$input"
    if ! hold_tool hold "$id" --reason "$reason" --card-file "$input" >/dev/null; then
      rm -f -- "$input"
      die "could not re-hold $id"
    fi
    rm -f -- "$input"
  else
    hold_tool hold "$id" --reason "$reason" >/dev/null || die "could not re-hold $id"
  fi
  log_line restored "$id" "$(printf '%s' "$line" | jq -r .kind)" "restored on request" "$reason" "$card"
  printf 'restored: %s\n' "$id"
}

case "${1:-}" in
  validate) shift; cmd_validate "$@" ;;
  write) shift; cmd_write "$@" ;;
  show) shift; cmd_show "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  draft) shift; cmd_draft "$@" ;;
  backfill) shift; cmd_backfill "$@" ;;
  stale) shift; cmd_stale "$@" ;;
  clear) shift; cmd_clear "$@" ;;
  restore) shift; cmd_restore "$@" ;;
  -h|--help|help) awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}" ;;
  *) usage >&2; exit 2 ;;
esac
