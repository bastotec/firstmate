#!/usr/bin/env bash
# fm-order.sh - order proposals: the first mate's reading of a plain-word order,
# waiting for the captain to launch or cancel it.
#
# A captain surface (the Fleet app's command bar, later Ziggy) sends the first
# mate "order <id>: <words>", or "order <id> replacing <old-id>: <words>" after
# the captain edited an earlier request. The first mate turns the words into
# concrete orders without carrying any of them out and records them here as
# state/orders/<id>.json, mode 0600, written atomically.
# "launch <id>" (optionally "launch <id> without 2, 3") is the captain's go for
# the kept lines, and "cancel <id>" drops the proposal; the captain-hold-lifecycle
# skill owns what the first mate does with each. Nothing in this file runs work.
#
# Usage:
#   fm-order.sh validate --file <proposal.json>
#   fm-order.sh write <id> --file <proposal.json>
#   fm-order.sh show <id>
#   fm-order.sh list
#   fm-order.sh remove <id>
#   fm-order.sh sweep
#
# Input JSON for write is exactly one object carrying request, lines and
# optionally note; the script adds version, id, created and updated, and a
# rewrite of the same id keeps created.
# Limits: request is the captain's words, one line of at most 1000 characters;
# 0-9 lines, each {project, target, action}: project is a slug naming the
# lane, target one line of at most 60 characters (what the order acts on, such
# as "cadia-site #6" or "new task"), action one line of at most 200 characters
# (what happens, in plain words); note at most 280 characters and 2 lines (an
# answer or a caveat); a proposal needs at least one line or a note.
# No control characters anywhere except the one newline note may carry.
# Lines are numbered from 1 in file order; "without 2, 3" names those numbers.
# `list` prints "<id>\t<lines>\t<updated>\t<request>" per valid proposal.
# `sweep` removes every proposal last updated more than 24 hours ago, and every
# invalid one, printing "removed: <id>" for each.
# `show` exits 1 when there is no proposal and 2 when it is invalid.
# FM_ORDER_NOW overrides the UTC timestamp for tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ORDERS="$STATE/orders"

usage() { awk '/^# Usage:/{on=1; next} on && /^#$/{exit} on{sub(/^#   /, ""); print}' "${BASH_SOURCE[0]}"; }
die() { printf 'fm-order: %s\n' "$1" >&2; exit "${2:-2}"; }
now() { printf '%s' "${FM_ORDER_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

require_slug() {  # <id>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*|.|..) die "order id must be a privacy-safe slug: ${1:-}" ;;
  esac
  [ "${#1}" -le 128 ] || die "order id is longer than 128 characters"
}

order_path() { printf '%s/%s.json\n' "$ORDERS" "$1"; }

# The first rule the input breaks as "<field>: <why>", or nothing when valid.
input_error() {  # <path>
  jq -rs '
    def oneline: test("[\u0000-\u001f\u007f]");
    def ctl: test("[\u0000-\u0009\u000b-\u001f\u007f]");
    def str($n): type == "string" and length > 0 and length <= $n and (oneline | not);
    if length != 1 then "proposal: exactly one JSON object required"
    else .[0] |
    if type != "object" then "proposal: not a JSON object"
    elif (.request | str(1000) | not) then "request: required, one line, at most 1000 characters"
    elif (.lines | type) != "array" or (.lines | length) > 9 then "lines: at most 9 lines"
    elif ([.lines[] | select(type != "object" or (.project | type) != "string" or (.project | test("^[A-Za-z0-9._-]+$") | not))] | length) > 0 then "lines: each project is a slug"
    elif ([.lines[] | select(.target | str(60) | not)] | length) > 0 then "lines: each target is one line of at most 60 characters"
    elif ([.lines[] | select(.action | str(200) | not)] | length) > 0 then "lines: each action is one line of at most 200 characters"
    elif ((.note // "") | type) != "string" or ((.note // "") | length) > 280 or ((.note // "") | ctl) or (((.note // "") | split("\n") | length) > 2) then "note: at most 280 characters and 2 lines"
    elif (.lines | length) == 0 and ((.note // "") | length) == 0 then "lines: a proposal needs at least one line or a note"
    else empty end end
  ' "$1" 2>/dev/null || printf 'proposal: not valid JSON\n'
}

# A stored proposal: the input rules plus the fields this script writes.
stored_error() {  # <path> <id>
  local err
  err=$(input_error "$1")
  [ -z "$err" ] || { printf '%s\n' "$err"; return; }
  jq -r --arg id "$2" '
    def utc: type == "string" and test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$");
    if .version != 1 then "version: must be 1"
    elif .id != $id then "id: must match the file name"
    elif (.created | utc | not) or (.updated | utc | not) then "created: and updated: must be UTC times to the second"
    else empty end
  ' "$1" 2>/dev/null || printf 'proposal: not valid JSON\n'
}

cmd_validate() {
  local file='' err
  while [ "$#" -gt 0 ]; do
    case "$1" in --file) shift; file=${1:-} ;; *) usage >&2; exit 2 ;; esac
    shift
  done
  [ -f "$file" ] || die "--file must name a readable proposal file"
  err=$(input_error "$file")
  [ -z "$err" ] || die "invalid proposal: $err"
}

# Atomic, owner-only write of a complete stored proposal read from stdin.
store() {  # <id>
  local dest tmp
  dest=$(order_path "$1")
  (umask 077; mkdir -p "$ORDERS")
  tmp=$(umask 077; mktemp "$ORDERS/.$1.XXXXXX") || die "cannot stage proposal $1"
  if ! cat > "$tmp"; then rm -f -- "$tmp"; die "cannot stage proposal $1"; fi
  chmod 600 "$tmp"
  mv -f -- "$tmp" "$dest" || { rm -f -- "$tmp"; die "cannot publish proposal $1"; }
  printf '%s\n' "$dest"
}

cmd_write() {
  local id=${1:-} file='' created ts p
  [ "$#" -ge 1 ] && shift
  require_slug "$id"
  while [ "$#" -gt 0 ]; do
    case "$1" in --file) shift; file=${1:-} ;; *) usage >&2; exit 2 ;; esac
    shift
  done
  cmd_validate --file "$file"
  ts=$(now)
  p=$(order_path "$id")
  created=''
  [ ! -f "$p" ] || created=$(jq -r '.created // empty' "$p" 2>/dev/null || true)
  [ -n "$created" ] || created=$ts
  jq -c --arg id "$id" --arg created "$created" --arg updated "$ts" '
    {version: 1, id: $id, request,
     lines: [.lines[] | {project, target, action}],
     note: (.note // ""), created: $created, updated: $updated}' "$file" | store "$id"
}

cmd_show() {
  local id=${1:-} p
  require_slug "$id"
  p=$(order_path "$id")
  [ -f "$p" ] || exit 1
  [ -z "$(stored_error "$p" "$id")" ] || die "invalid proposal: $id"
  cat "$p"
}

cmd_remove() {
  local id=${1:-}
  require_slug "$id"
  rm -f -- "$(order_path "$id")"
}

# Each stored proposal file's id (staging files start with a dot and are skipped).
each_id() {
  local p id
  [ -d "$ORDERS" ] || return 0
  for p in "$ORDERS"/*.json; do
    [ -f "$p" ] || continue
    id=$(basename "$p" .json)
    case "$id" in ''|*[!A-Za-z0-9._-]*|.|..) continue ;; esac
    printf '%s\n' "$id"
  done
}

cmd_list() {
  local id p
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  for id in $(each_id); do
    p=$(order_path "$id")
    [ -z "$(stored_error "$p" "$id")" ] || continue
    jq -r '[.id, (.lines | length | tostring), .updated, .request] | @tsv' "$p"
  done
}

epoch_of() {  # <UTC YYYY-MM-DDTHH:MM:SSZ>
  date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$1" +%s 2>/dev/null || date -u -d "$1" +%s 2>/dev/null
}

cmd_sweep() {
  local id p cutoff now_s at
  [ "$#" -eq 0 ] || { usage >&2; exit 2; }
  now_s=$(epoch_of "$(now)") || die "cannot read the current time"
  cutoff=$(( now_s - 86400 ))
  for id in $(each_id); do
    p=$(order_path "$id")
    if [ -z "$(stored_error "$p" "$id")" ]; then
      at=$(epoch_of "$(jq -r .updated "$p")") || at=0
      [ "$at" -lt "$cutoff" ] || continue
    fi
    rm -f -- "$p"
    printf 'removed: %s\n' "$id"
  done
}

case "${1:-}" in
  validate) shift; cmd_validate "$@" ;;
  write) shift; cmd_write "$@" ;;
  show) shift; cmd_show "$@" ;;
  list) shift; cmd_list "$@" ;;
  remove) shift; cmd_remove "$@" ;;
  sweep) shift; cmd_sweep "$@" ;;
  -h|--help|help) awk 'NR == 1 {next} /^#/ {sub(/^# ?/, ""); print; next} {exit}' "${BASH_SOURCE[0]}" ;;
  *) usage >&2; exit 2 ;;
esac
