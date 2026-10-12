#!/usr/bin/env bash
# Turn a machine check's human steps into what the captain sees: a "Blocked on
# you:" reply, a needs-you decision card that resolves itself, and the pending
# machine record Fleet Town draws as a pending island.
#
# Usage:
#   fm-machine-blocker.sh summary [--alias <alias>] [--then <text>]   (check output on stdin)
#   fm-machine-blocker.sh raise <alias> --for <what> [--then <text>] [--root <remote-root>]
#       [--secondmate <id>=<Name>]... [--from <check-output-file>]
#   fm-machine-blocker.sh ready <alias> [--from <check-output-file>]
#   fm-machine-blocker.sh resolve <alias>
#   fm-machine-blocker.sh show <alias>
#   fm-machine-blocker.sh clear <alias>
#
# Input is bin/fm-machine.sh check's line protocol (its header owns it); only
# `item <name>=present|will-install|human: <text>` lines are read here.
#
# summary prints the reply block and exits 0 when any item is human:
#   Blocked on you: <n> step(s) on <alias> before I can continue.
#   1. <item>: <exact step from the check>
#   ...
#   Then: <text>
# With no human item it prints nothing and exits 1.
#
# raise is for an action the captain approved that needs the machine (for
# example creating a second mate there). It runs `bin/fm-machine.sh check
# <alias> [<remote-root>]` (or reads --from), writes the pending record, and
# when human items remain it holds machine-<alias, lowercased> (or the first
# available -2, -3, ... task) with a full card via fm-captain-hold.sh hold --card-file,
# arms the re-check watch, and prints the summary to paste into the same reply.
# --for names the approved action in a few words ("create Inter Graal");
# --then says what happens on its own once the steps are done (default: the
# watch re-checks every 5 minutes and the first mate carries on).
# --secondmate records a second mate whose creation waits on this machine, so
# Fleet Town shows it as a planned plot. It prints `ready: <alias>` and exits 0
# with no hold when nothing needs the captain.
#
# The watch is a condition->action pair (bin/fm-procevent-when.sh, source
# when-<record's task>): condition `ready <alias>`, action
# `resolve <alias>`, every 300 seconds for up to 14 days, one stable true.
# ready re-runs the check, rewrites the record and, while the hold is open and
# the human steps changed, the card; it exits 0 when no item is human, 1 when
# some are, 2 when the check could not be read. resolve closes the hold through
# fm-captain-hold.sh stale-clear with the passing check as evidence (never as
# the captain's words), which removes the card, and marks the record ready.
# The watch's fired wake is the first mate's cue to carry on with --for.
#
# show prints the record. clear removes the record and retires the watch; run
# it once the approved action is done (the machine registered and the second
# mate launched).
#
# The record is state/machine-pending/<alias>.json, mode 0600:
#   {"version":1,"alias":"","root":"","task":"machine-<alias>","for":"",
#    "then":"","state":"needs-you|ready","checked":"<UTC>",
#    "planned":[{"id":"","name":""}],
#    "items":[{"name":"","state":"done|you|todo","text":""}]}
# Item state maps check states: present -> done, human -> you (waiting on the
# captain), will-install -> todo (setup does it).
# FM_MACHINE_BLOCKER_NOW overrides the UTC timestamp for tests.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
PENDING="$STATE/machine-pending"
TMP=
trap '[ -z "$TMP" ] || rm -rf -- "$TMP"' EXIT

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,62p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; }
now() { printf '%s\n' "${FM_MACHINE_BLOCKER_NOW:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"; }

command -v jq >/dev/null 2>&1 || die "jq is required"

require_alias() {
  case "${1:-}" in
    ''|-*|*[!A-Za-z0-9._-]*|.|..) die "alias must be a plain ssh name: ${1:-}" ;;
  esac
}
slug() { printf 'machine-%s\n' "$(printf '%s' "$1" | tr 'A-Z' 'a-z')"; }
record_path() { printf '%s/%s.json\n' "$PENDING" "$1"; }
scratch() { [ -n "$TMP" ] || TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-machine-blocker.XXXXXX"); }

# Check output -> JSON array of {name,state,text}, in check order.
items_json() {  # <check-output-file>
  jq -R -s '
    [ split("\n")[]
      | select(startswith("item "))
      | capture("^item (?<name>[^=]+)=(?<st>present|will-install|human)(: (?<text>.*))?$")
      | {name, state: ({"present":"done","human":"you","will-install":"todo"}[.st]), text: (.text // "")} ]
  ' "$1"
}

default_then() {  # <alias>
  printf 'I re-check %s every 5 minutes; once nothing is left for you, this card closes on its own and I carry on.\n' "$1"
}

summary_from_items() {  # <items-json-file> <alias> <then>
  jq -r --arg alias "$2" --arg next "$3" '
    [.[] | select(.state == "you")] as $you
    | if ($you|length) == 0 then empty else
        "Blocked on you: \($you|length) step\(if ($you|length) == 1 then "" else "s" end) on \($alias) before I can continue.",
        ($you | to_entries[] | "\(.key + 1). \(.value.name): \(.value.text)"),
        "Then: \($next)"
      end
  ' "$1"
}

cmd_summary() {
  local alias=the-machine next='' out
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --alias) shift; alias=${1:-}; require_alias "$alias" ;;
      --then) shift; next=${1:-} ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [ -n "$next" ] || next=$(default_then "$alias")
  scratch
  cat > "$TMP/check"
  items_json "$TMP/check" > "$TMP/items"
  out=$(summary_from_items "$TMP/items" "$alias" "$next")
  [ -n "$out" ] || exit 1
  printf '%s\n' "$out"
}

# Runs the check (or copies --from) into $TMP/check; fails when it printed no items.
read_check() {  # <alias> <root-or-empty> <from-or-empty>
  scratch
  if [ -n "$3" ]; then
    [ -f "$3" ] || die "--from must name a readable check output file"
    cat -- "$3" > "$TMP/check"
  else
    if [ -n "$2" ]; then
      "$SCRIPT_DIR/fm-machine.sh" check "$1" "$2" > "$TMP/check" 2>&1 || true
    else
      "$SCRIPT_DIR/fm-machine.sh" check "$1" > "$TMP/check" 2>&1 || true
    fi
  fi
  items_json "$TMP/check" > "$TMP/items"
  [ "$(jq length "$TMP/items")" -gt 0 ] || return 1
}

write_record() {  # <alias> <json>  (atomic, owner-only)
  local path tmp
  path=$(record_path "$1")
  umask 077
  mkdir -p "$PENDING"
  tmp=$(mktemp "$PENDING/.record.XXXXXX")
  printf '%s\n' "$2" > "$tmp"
  chmod 0600 "$tmp"
  mv -f -- "$tmp" "$path"
}

card_json() {  # <record-json-file>
  jq '
    [.items[] | select(.state == "you")] as $you
    | ($you|length) as $n
    | {
        project: "firstmate",
        title: ("\(.alias) needs you before I can \(.for)" | .[0:120]),
        situation: (("Blocked on you: \($n) step\(if $n == 1 then "" else "s" end) on \(.alias) - \([$you[].name] | join(", ")).\n" + .then) | .[0:280]),
        options: [
          {key: "1", label: "Done - re-check now",
           instruction: ("Do NOT record this option through answer. Run bin/fm-machine-blocker.sh ready \(.alias); if it passes, run bin/fm-machine-blocker.sh resolve \(.alias) to stale-clear with evidence, then carry on with: \(.for). Otherwise reply with the remaining Blocked on you steps using bin/fm-machine-blocker.sh show \(.alias), and leave the card open." | .[0:1000])}
        ],
        recommended: "1"
      }
  ' "$1"
}

hold_open() {  # <task>
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$1" >/dev/null
}

hold_title() {
  jq -r '"Set up " + .alias + " so I can " + .for' "$1" | cut -c1-120
}

select_hold_task() {
  local base=$1 rec=$2 task=$1 index=1 rc row title
  while :; do
    if "$SCRIPT_DIR/fm-captain-hold.sh" open "$task" --distinguish-absent >/dev/null; then
      if [ "$index" -eq 1 ]; then
        printf '%s\n' "$task"
        return 0
      fi
      row=$("$SCRIPT_DIR/fm-tasks-axi.sh" show "$task" --full) || return 2
      title=$(printf '%s\n' "$row" | jq -Rrs '
        split("\n") | map(select(startswith("  title: "))) | .[0]
        | ltrimstr("  title: ") | if startswith("\"") then fromjson else . end
      ') || return 2
      if [ "$title" = "$(hold_title "$rec")" ]; then
        printf '%s\n' "$task"
        return 0
      fi
    else
      rc=$?
      case "$rc" in
        3) printf '%s\n' "$task"; return 0 ;;
        1) ;;
        *) return "$rc" ;;
      esac
    fi
    index=$((index + 1))
    task="$base-$index"
  done
}

hold_with_card() {  # <task> <record-json-file>
  local task=$1 rec=$2 reason
  card_json "$rec" > "$TMP/card.json"
  reason=$(jq -r '"Blocked on you: " + ([.items[] | select(.state == "you") | .name] | join(", ")) + " on " + .alias' "$rec")
  "$SCRIPT_DIR/fm-captain-hold.sh" hold "$task" --reason "$reason" \
    --title "$(hold_title "$rec")" \
    --repo firstmate --card-file "$TMP/card.json" >/dev/null
}

arm_watch() {  # <alias> <task>
  local alias=$1 task=$2
  # An earlier watch for this machine (fired or not) is replaced by a fresh one.
  "$SCRIPT_DIR/fm-procevent-when.sh" retire "$task" >/dev/null
  "$SCRIPT_DIR/fm-procevent-when.sh" arm "$task" --interval 300 --stable 1 \
    --deadline 1209600 --condition-timeout 180 --action-timeout 120 \
    --condition "$SCRIPT_DIR/fm-machine-blocker.sh" ready "$alias" \
    --action "$SCRIPT_DIR/fm-machine-blocker.sh" resolve "$alias" >/dev/null
}

cmd_raise() {
  local alias=${1:-} for='' next='' root='' from='' planned='[]' task rec state path old_task=''
  require_alias "$alias"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --for) shift; for=${1:-} ;;
      --then) shift; next=${1:-} ;;
      --root) shift; root=${1:-} ;;
      --from) shift; from=${1:-} ;;
      --secondmate)
        shift
        case "${1:-}" in
          *=*) planned=$(jq -c --arg id "${1%%=*}" --arg name "${1#*=}" '. + [{id: $id, name: $name}]' <<<"$planned") ;;
          *) die "--secondmate takes <id>=<Name>" ;;
        esac ;;
      *) usage >&2; exit 2 ;;
    esac
    shift
  done
  [ -n "$for" ] || die "--for must name the approved action"
  [ -n "$next" ] || next=$(default_then "$alias")
  task=$(slug "$alias")
  read_check "$alias" "$root" "$from" || die "the check for $alias printed no checklist; read its output with bin/fm-machine.sh check $alias"
  [ -n "$root" ] || root=$(sed -n 's/^root=//p' "$TMP/check" | head -n 1)
  [ "$root" != - ] || root=
  state=ready
  if jq -e 'any(.[]; .state == "you")' "$TMP/items" >/dev/null; then state=needs-you; fi
  rec=$(jq -n --arg alias "$alias" --arg root "$root" --arg task "$task" --arg for "$for" \
    --arg next "$next" --arg state "$state" --arg checked "$(now)" \
    --argjson planned "$planned" --slurpfile items "$TMP/items" \
    '{version: 1, alias: $alias, root: $root, task: $task, for: $for, then: $next,
      state: $state, checked: $checked, planned: $planned, items: $items[0]}')
  path=$(record_path "$alias")
  if [ -f "$path" ]; then
    jq -e --arg for "$for" --argjson planned "$planned" \
      '.for == $for and .planned == $planned' "$path" >/dev/null \
      || die "a different action already waits on $alias; finish it before raising another"
    old_task=$(jq -er .task "$path")
    rec=$(jq --arg task "$old_task" '.task = $task' <<<"$rec")
  fi
  if [ "$state" = needs-you ]; then
    printf '%s\n' "$rec" > "$TMP/record.json"
    task=$(select_hold_task "$task" "$TMP/record.json")
    rec=$(jq --arg task "$task" '.task = $task' <<<"$rec")
    printf '%s\n' "$rec" > "$TMP/record.json"
    hold_with_card "$task" "$TMP/record.json"
    if [ -n "$old_task" ] && [ "$old_task" != "$task" ]; then
      "$SCRIPT_DIR/fm-procevent-when.sh" retire "$old_task" >/dev/null
    fi
  fi
  write_record "$alias" "$rec"
  if [ "$state" = ready ]; then
    printf 'ready: %s\n' "$alias"
    return 0
  fi
  arm_watch "$alias" "$task"
  summary_from_items "$TMP/items" "$alias" "$next"
}

cmd_ready() {
  local alias=${1:-} from='' path rec_old you_old you_new state rec rc
  require_alias "$alias"
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in --from) shift; from=${1:-} ;; *) usage >&2; exit 2 ;; esac
    shift
  done
  path=$(record_path "$alias")
  [ -f "$path" ] || die "no pending record for $alias; raise it first"
  rec_old=$(cat -- "$path")
  read_check "$alias" "$(jq -r '.root // ""' <<<"$rec_old")" "$from" || exit 2
  state=ready
  if jq -e 'any(.[]; .state == "you")' "$TMP/items" >/dev/null; then state=needs-you; fi
  rec=$(jq --arg state "$state" --arg checked "$(now)" --slurpfile items "$TMP/items" \
    '.state = $state | .checked = $checked | .items = $items[0]' <<<"$rec_old")
  write_record "$alias" "$rec"
  you_old=$(jq -c '[.items[] | select(.state == "you")]' <<<"$rec_old")
  you_new=$(jq -c '[.[] | select(.state == "you")]' "$TMP/items")
  if [ "$state" = needs-you ]; then
    if [ "$you_old" != "$you_new" ]; then
      if hold_open "$(jq -r .task <<<"$rec")"; then
        hold_with_card "$(jq -r .task <<<"$rec")" "$path"
      else
        rc=$?
        [ "$rc" -eq 1 ] || exit "$rc"
      fi
    fi
    exit 1
  fi
  exit 0
}

cmd_resolve() {
  local alias=${1:-} path task rc
  require_alias "$alias"
  path=$(record_path "$alias")
  [ -f "$path" ] || die "no pending record for $alias"
  task=$(jq -r .task "$path")
  jq -e 'all(.items[]; .state != "you")' "$path" >/dev/null \
    || die "$alias still has steps waiting on the captain"
  scratch
  printf 'bin/fm-machine.sh check %s at %s reported no step left for the captain.\n' \
    "$alias" "$(jq -r .checked "$path")" > "$TMP/evidence"
  if hold_open "$task"; then
    "$SCRIPT_DIR/fm-captain-hold.sh" stale-clear "$task" --evidence-file "$TMP/evidence" >/dev/null
  else
    rc=$?
    [ "$rc" -eq 1 ] || exit "$rc"
  fi
  write_record "$alias" "$(jq '.state = "ready"' "$path")"
  printf 'ready: %s; carry on with: %s\n' "$alias" "$(jq -r .for "$path")"
}

cmd_show() {
  local alias=${1:-} path
  require_alias "$alias"
  path=$(record_path "$alias")
  [ -f "$path" ] || exit 1
  cat -- "$path"
}

cmd_clear() {
  local alias=${1:-} task path
  require_alias "$alias"
  path=$(record_path "$alias")
  task=$(slug "$alias")
  [ ! -f "$path" ] || task=$(jq -er .task "$path")
  "$SCRIPT_DIR/fm-procevent-when.sh" retire "$task" >/dev/null
  rm -f -- "$path"
  printf 'cleared: %s\n' "$alias"
}

case "${1:-}" in
  summary) shift; cmd_summary "$@" ;;
  raise) shift; cmd_raise "$@" ;;
  ready) shift; cmd_ready "$@" ;;
  resolve) shift; cmd_resolve "$@" ;;
  show) shift; cmd_show "$@" ;;
  clear) shift; cmd_clear "$@" ;;
  -h|--help) usage ;;
  *) usage >&2; exit 2 ;;
esac
