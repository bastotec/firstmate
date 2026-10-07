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
#
# Input JSON for write carries project, title, situation, options and
# recommended; the script adds version, task, draft, created and updated.
# Limits: title <= 120 chars; situation <= 280 chars and <= 2 lines; 1-9
# options keyed "1".."9" in order; label <= 40 chars; instruction <= 1000
# chars; recommended names one option; no control characters except the one
# newline allowed in situation.
# A draft card (draft: true, no options, recommended null) stands in for a
# hold whose holder could not write a judgment; `draft` never replaces a full
# card, and the first mate replaces drafts with full cards at its next review.
# `backfill` drafts a card for every captain-held task in this home that has
# none, using its title, repo and hold reason.
# `show` exits 1 when the task has no card and 2 when its card is invalid.
# FM_CARD_NOW overrides the UTC timestamp for tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CARDS="$STATE/cards"
TASKS="$SCRIPT_DIR/fm-tasks-axi.sh"

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
  jq -r '
    def ctl: test("[\u0000-\u0009\u000b-\u001f\u007f]");
    def oneline: test("[\u0000-\u001f\u007f]");
    if type != "object" then "card: not a JSON object"
    elif (.title|type) != "string" or (.title|length) == 0 or (.title|length) > 120 or (.title|oneline) then "title: required, one line, at most 120 characters"
    elif (.project|type) != "string" or (.project|test("^[A-Za-z0-9._-]+$")|not) then "project: required slug"
    elif (.situation|type) != "string" or (.situation|length) == 0 or (.situation|length) > 280 or (.situation|ctl) or ((.situation|split("\n")|length) > 2) then "situation: required, at most 280 characters and 2 lines"
    elif (.options|type) != "array" or (.options|length) < 1 or (.options|length) > 9 then "options: 1 to 9 options required"
    elif ([.options|to_entries[]|select((.value|type) != "object" or .value.key != ((.key+1)|tostring))]|length) > 0 then "options: keys must be \"1\"..\"9\" in order"
    elif ([.options[]|select((.label|type) != "string" or (.label|length) == 0 or (.label|length) > 40 or (.label|oneline))]|length) > 0 then "options: each label is one line of at most 40 characters"
    elif ([.options[]|select((.instruction|type) != "string" or (.instruction|length) == 0 or (.instruction|length) > 1000 or (.instruction|ctl))]|length) > 0 then "options: each instruction is at most 1000 characters"
    elif (.recommended|type) != "string" or (.recommended as $r | [.options[].key] | index($r)) == null then "recommended: must name one option key"
    else empty end
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
  [ -n "$title" ] && [ -n "$project" ] && [ -n "$situation" ] \
    || die "draft needs --title, --project and --situation"
  case "$project" in *[!A-Za-z0-9._-]*) project=firstmate ;; esac
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

case "${1:-}" in
  validate) shift; cmd_validate "$@" ;;
  write) shift; cmd_write "$@" ;;
  show) shift; cmd_show "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  draft) shift; cmd_draft "$@" ;;
  backfill) shift; cmd_backfill "$@" ;;
  -h|--help|help) usage ;;
  *) usage >&2; exit 2 ;;
esac
