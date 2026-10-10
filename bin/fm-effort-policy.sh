#!/usr/bin/env bash
# fm-effort-policy.sh - decide, from a turn's source alone, whether a Deck
# supervisor turn may run at a lower reasoning effort.
#
# Routine operational input thinks less so it answers faster; everything else
# keeps the model's default effort. The decision is deterministic code over the
# turn's input and this home's records, never a model guess, and it fails safe:
# anything it cannot prove routine runs at the default.
#
# Usage (every subcommand takes --home H; default FM_HOME, else this checkout):
#   fm-effort-policy.sh classify < turn-input
#       Prints the lowered level (e.g. `low`) when the input is routine, and
#       nothing when the turn keeps the default. Always exits 0 for a decision.
#       Only a watcher wake (the text the hosts publish after "The home watcher
#       has an actionable wake.") can be routine. Every current reason and
#       outstanding state/.wake-queue row payload must meet the same rules:
#         signal: <files>   each named .status file has no captain-relevant
#                           line past the drain's presentation cursor, no open
#                           decision, and no captain-held transfer (the shared
#                           bin/fm-classify-lib.sh status_open_decisions and
#                           status_span_first_actionable_record classifiers);
#                           other named files use their task's .status log
#         heartbeat         the fleet fingerprint (status logs, backlog, cards,
#                           orders) is unchanged since the previous heartbeat
#                           and every status log meets the signal rules above
#         check: .../autoland.check.sh: autoland: <items>
#                           every item is `merged <url> (deploy follows)` or
#                           `deployed <x> <sha>: <x>: nothing to deploy...` /
#                           `nothing deployed automatically...`
#       Captain messages, card answers, orders, stale, needs-decision, other
#       checks and anything unrecognized keep the default. An unreadable or
#       malformed wake queue also keeps the default; classification never
#       mutates the queue. A pending escalation (see observe) keeps the default
#       once, and is consumed.
#   fm-effort-policy.sh observe < turn-events.ndjson
#       During or after a turn: when `run_started.effort` marks lowered effort and
#       its tool output shows new work - a drain section that only prints news
#       (UNREAD STATUS, STATUS OUTCOME BACKSTOP, POSSIBLE ASKS, RECORD
#       DIVERGENCE) or a drained wake row for a decision or stuck work - records
#       an escalation so the next classified turn runs at the default. OPEN
#       DECISIONS repeats on every drain while a captain call is open, so it
#       alone is not new work.
#   fm-effort-policy.sh supported <deck-binary>
#       Exit 0 when that Deck takes `--effort` and the `deck-effort:` header.
#
# Configuration and operator behavior: docs/configuration.md "Turn effort"
# owns config/effort-policy.json, its defaults, accepted values, and refusals.
# Primary: observe before successor classification. Secondmate: after the turn.
#
# State (written only here): state/effort-policy/escalate (pending escalation)
# and state/effort-policy/heartbeat (last heartbeat fingerprint).
set -u
SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

HOME_DIR=${FM_HOME:-$(dirname "$SCRIPT_DIR")}
args=()
while [ $# -gt 0 ]; do
  case "$1" in
    --home) HOME_DIR=${2-}; shift 2 || { echo "error: --home needs a value" >&2; exit 2; } ;;
    *) args+=("$1"); shift ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
CMD=${1-}
[ $# -eq 0 ] || shift

case "$CMD" in
  -h|--help) sed -n '2,48p' "$0"; exit 0 ;;
  supported)
    [ $# -eq 1 ] || { echo "usage: fm-effort-policy.sh supported <deck-binary>" >&2; exit 2; }
    "$1" run --help 2>/dev/null | grep -q -- '--effort'
    exit
    ;;
  classify|observe) ;;
  *) echo "usage: fm-effort-policy.sh classify|observe|supported [--home H]" >&2; exit 2 ;;
esac

export FM_HOME=$HOME_DIR
STATE=$HOME_DIR/state
POLICY_DIR=$STATE/effort-policy
CONFIG=$HOME_DIR/config/effort-policy.json
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

# The lowered level, or empty when the classifier is off.
low_level() {
  local settings mode level
  if [ ! -e "$CONFIG" ] && [ ! -L "$CONFIG" ]; then
    printf 'low'
    return
  fi
  if [ ! -f "$CONFIG" ] || [ ! -r "$CONFIG" ] || ! settings=$(jq -ers '
    if length != 1 then error("expected one object") else .[0] end
    | if type != "object" then error("expected object") else . end
    | (if has("classifier") then .classifier else "on" end) as $mode
    | (if has("low") then .low else "low" end) as $level
    | if ($mode == "on" or $mode == "off") and
         ($level == "none" or $level == "minimal" or $level == "low" or $level == "medium")
      then [$mode, $level] | @tsv else error("invalid effort policy") end
  ' "$CONFIG" 2>/dev/null); then
    echo "fm-effort-policy: config/effort-policy.json is unreadable or invalid; every turn keeps the default effort" >&2
    return
  fi
  IFS=$'\t' read -r mode level <<< "$settings"
  [ "$mode" = on ] || return
  printf '%s' "$level"
}

# 0 when the status log has nothing captain-facing the drain has not shown.
status_quiet() {  # <status-file>
  local f=$1 offset record needs=0 rc open
  case "$f" in /*) ;; *) f=$HOME_DIR/$f ;; esac
  [ -e "$f" ] || { [ ! -L "$f" ]; return; }
  [ -f "$f" ] && [ -r "$f" ] && [ ! -L "$f" ] || return 1
  open=$(status_open_decisions "$f") || return 1
  [ -z "$open" ] || return 1
  offset=$(status_outcome_backstop_cursor_offset "$f") || return 1
  status_span_first_actionable_record "$f" "$offset" record needs
  rc=$?
  [ "$rc" -eq 1 ] && [ "$needs" = 0 ]
}

signal_routine() {  # <files>
  local f
  for f in $1; do
    case "$f" in
      *.status) ;;
      *.*) f=${f%.*}.status ;;
      *) return 1 ;;
    esac
    status_quiet "$f" || return 1
  done
}

fleet_fingerprint() {
  local f records identity
  records=$(
    for f in "$STATE"/*.status "$HOME_DIR/data/backlog.md" "$STATE"/cards/*.json "$STATE"/orders/*.json; do
      [ -e "$f" ] || continue
      if [[ $f = "$STATE"/*.status ]]; then
        identity="$(_fm_status_file_size "$f") $(_fm_status_file_mtime "$f")"
      else
        identity=$(cksum < "$f") || exit 1
      fi
      printf '%s %s\n' "${f#"$HOME_DIR"/}" "$identity"
    done
  ) || return 1
  printf '%s\n' "$records" | cksum
}

heartbeat_routine() {
  local now before='' f quiet=0
  now=$(fleet_fingerprint) || return 1
  [ -f "$POLICY_DIR/heartbeat" ] && before=$(cat "$POLICY_DIR/heartbeat" 2>/dev/null)
  mkdir -p "$POLICY_DIR" && printf '%s\n' "$now" > "$POLICY_DIR/heartbeat.tmp" \
    && mv -f "$POLICY_DIR/heartbeat.tmp" "$POLICY_DIR/heartbeat"
  [ -n "$before" ] && [ "$before" = "$now" ] || return 1
  for f in "$STATE"/*.status; do
    [ -e "$f" ] || continue
    status_quiet "$f" || quiet=1
  done
  [ "$quiet" -eq 0 ]
}

autoland_routine() {  # <text after "autoland: ">
  local rest=$1
  local merged='^merged https://[^ ;]+ \(deploy follows\)(; (.*))?$'
  local nothing='^deployed [^ ;]+ [0-9a-f]+: [^ ;:]+: nothing (to deploy|deployed automatically)[^;]*(; (.*))?$'
  while [ -n "$rest" ]; do
    if [[ $rest =~ $merged ]]; then
      rest=${BASH_REMATCH[2]}
    elif [[ $rest =~ $nothing ]]; then
      rest=${BASH_REMATCH[3]}
    else
      return 1
    fi
  done
}

reason_routine() {
  local line=$1 autoland='^check: [^ ]*/autoland\.check\.sh: autoland: (.+)$'
  case "$line" in
    'signal: '*) [ -n "${line#signal: }" ] && signal_routine "${line#signal: }" ;;
    heartbeat|heartbeat:*) heartbeat_routine ;;
    *)
      [[ $line =~ $autoland ]] || return 1
      autoland_routine "${BASH_REMATCH[1]}"
      ;;
  esac
}

queued_reasons_routine() {
  local queue=$STATE/.wake-queue payloads payload
  [ -e "$queue" ] || { [ ! -L "$queue" ]; return; }
  [ -f "$queue" ] && [ -r "$queue" ] && [ ! -L "$queue" ] || return 1
  payloads=$(awk -F '\t' '
    NF != 5 || $1 !~ /^[0-9]+$/ || $2 !~ /^[0-9]+$/ ||
      $3 !~ /^(signal|stale|check|heartbeat)$/ || $4 == "" || $5 == "" { exit 1 }
    { print $5 }
  ' "$queue" 2>/dev/null) || return 1
  [ -n "$payloads" ] || return 0
  while IFS= read -r payload; do
    reason_routine "$payload" || return 1
  done <<EOF
$payloads
EOF
}

classify() {
  local level body line reasons=0
  level=$(low_level)
  [ -n "$level" ] || return 0
  body=$(cat)
  if [ -e "$POLICY_DIR/escalate" ]; then
    rm -f "$POLICY_DIR/escalate"
    return 0
  fi
  case "$body" in
    'The home watcher has an actionable wake.'*) ;;
    *) return 0 ;;
  esac
  while IFS= read -r line; do
    case "$line" in
      ''|'watcher: '*) continue ;;
      'The home watcher has an actionable wake.'*) continue ;;
    esac
    reasons=$((reasons + 1))
    reason_routine "$line" || return 0
  done <<EOF
$body
EOF
  [ "$reasons" -gt 0 ] || return 0
  queued_reasons_routine || return 0
  printf '%s\n' "$level"
}

observe() {
  local real
  [ -n "$(low_level 2>/dev/null)" ] || { cat > /dev/null; return 0; }
  # shellcheck disable=SC2016 # jq program text.
  real=$(jq -rs '
    (map(select(.type == "run_started")) | first | .effort // empty) as $effort
    | if $effort == null then empty else
        [ .[] | select(.type == "tool_result") | .output | if type == "string" then . else tostring end
          | select(test("UNREAD STATUS \\(|STATUS OUTCOME BACKSTOP \\(|POSSIBLE ASKS|RECORD DIVERGENCE \\(|\\t(stale|needs-decision)(\\t|: )")) ]
        | if length > 0 then "real" else empty end
      end' 2>/dev/null) || real=real
  [ "$real" = real ] || return 0
  mkdir -p "$POLICY_DIR" && : > "$POLICY_DIR/escalate"
}

"$CMD"
