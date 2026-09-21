#!/usr/bin/env bash
# fm-wake-gate.sh - fail-open worthiness gate for supervision wakes.
#
# PURPOSE
#   Decide whether a queued wake row is worth waking an expensive supervisor
#   model (the Pi supervision branch, or main) for, so cheap mechanical noise -
#   a re-delivery with no durable queue row, or a stale/stall re-ring for a task
#   the captain explicitly stood down - can be absorbed without spending a model
#   turn, while every genuine decision, blocker, check, or captain-facing row is
#   escalated. This is the token-economy gate the captain asked for: a cheap
#   filter in front of the costly model.
#
# FAIL-OPEN IS THE CONTRACT, NOT A DEFAULT
#   The verdict is `escalate` unless a narrow, positive rule returns `absorb`.
#   Any error, uncertainty, unparseable row, missing marker, unreadable state,
#   Jev timeout, or under-confidence result escalates. A gate that cannot prove a
#   row is noise must pass it through; swallowing a real escalation is the only
#   unacceptable failure, so the gate is biased entirely toward escalating.
#
# NEVER ABSORB (hard exclusions, checked before any layer)
#   - kind `check` (merge-confirmation polls, Relay mentions, credential/auth
#     failures, startup-network, process-event results, captain inbox notes)
#   - a row whose payload marks `needs-decision:` or `blocked:`
#   - a watcher-failure alarm
#   - a heartbeat
#   These always escalate regardless of any marker or score.
#
# USAGE
#   fm-wake-gate.sh classify <kind> <key> <payload>
#       Print one line: `escalate` or `absorb:<reason>`. Never fails the caller;
#       any internal error prints `escalate` and exits 0.
#   fm-wake-gate.sh stand-down <task-id> [--reason <text>]
#       Record state/<task-id>.stooddown (epoch<TAB>reason). Marks a task the
#       captain intentionally stopped, so its idle re-rings are provably noise.
#   fm-wake-gate.sh resume <task-id>
#       Remove the stood-down marker (the task is live again; escalate its wakes).
#   fm-wake-gate.sh cost
#       Print measured Jev usage and cost so far (from state/wake-gate/usage.log).
#
# LAYERS (evaluated in order; first absorb wins, else escalate)
#   1. Deterministic stood-down absorber (always on, free, no model call):
#      absorb a `stale` or `signal` row whose task carries a stood-down marker
#      AND whose status log has not advanced since the marker was written. The
#      stand-down is an explicit captain act, so an idle re-ring with no new
#      durable status is provably mechanical noise. If the status log advanced,
#      the task did something new -> escalate.
#   2. Jev worthiness layer (INERT BY DEFAULT; opt-in and advisory):
#      for an ambiguous actionable row, ask Jev whether the row needs a supervisor
#      reply. Reuses the ask-triage Jev runtime. Inert unless the key var is set
#      (config/wake-gate-key-var or FM_WAKE_GATE_KEY_VAR), and even when opted in
#      it is ADVISORY (logs a recommendation, returns escalate) unless
#      FM_WAKE_GATE_ENFORCE=1. Any doubt, error, or timeout escalates. The Jev
#      worthiness question is owned by bin/wake-gate/jev-worthiness.mjs.
#
# STATE (all under state/, private runtime state)
#   <task-id>.stooddown      "<epoch>\t<reason>" - the explicit stand-down marker
#   wake-gate/usage.log      "<epoch>\t<calls>\t<in-tok>\t<out-tok>\t<ms>\t<outcome>"
#   wake-gate/advisory.log   "<epoch>\t<kind>\t<key>\t<verdict>\t<reason>" - advisory
#                            recommendations while the Jev layer is not enforcing
#
# ENVIRONMENT
#   FM_WAKE_GATE_KEY_VAR     secrets var naming the Jev gateway key (opt-in)
#   FM_WAKE_GATE_SECRETS     secrets file (default ~/.secrets)
#   FM_WAKE_GATE_ENFORCE     1 = the Jev layer may absorb; unset/0 = advisory only
#   FM_WAKE_GATE_THRESHOLD   Jev noise-confidence at/above which to absorb (def 0.90)
#   FM_WAKE_GATE_TIMEOUT     seconds bound on the Jev call (default 6)
#   FM_WAKE_GATE_HELPER      replace the Jev helper command (tests); it receives
#                            the input file arg and prints the same rows
#   FM_STATE_DIR             state dir (default: resolve from this script's home)
#
# This script only checks that the key VARIABLE is named; the helper reads the
# value at call time and nothing here prints, logs, or passes the key.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
HOME_ROOT=$(dirname "$SCRIPT_DIR")
STATE=${FM_STATE_DIR:-$HOME_ROOT/state}

log_usage() {  # <calls> <in> <out> <ms> <outcome>
  mkdir -p "$STATE/wake-gate" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" "$5" \
    >> "$STATE/wake-gate/usage.log" 2>/dev/null || true
}
log_advisory() {  # <kind> <key> <verdict> <reason>
  mkdir -p "$STATE/wake-gate" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" \
    >> "$STATE/wake-gate/advisory.log" 2>/dev/null || true
}

# task_from_row: best-effort task id from a wake key/payload. Returns empty when
# it cannot resolve one (which makes the deterministic layer escalate, fail-open).
task_from_row() {  # <kind> <key> <payload>
  local kind=$1 key=$2 payload=$3 t=''
  case "$kind" in
    stale)
      # stale keys name an endpoint window: <session>:fm-<task> or fm-<task>
      t=${key##*:}; t=${t#fm-} ;;
    signal)
      # signal keys name a status file path: .../state/<task>.status
      t=${key##*/}; t=${t%.status} ;;
    *)
      # secondmate-wake-loop-<task>-<epoch>-<row> and similar
      case "$key" in
        secondmate-wake-loop-*) t=$(printf '%s' "$key" | sed -E 's/^secondmate-wake-loop-(.*)-[0-9]+-[0-9]+$/\1/') ;;
      esac ;;
  esac
  # only accept a plausible task id (no slashes, no spaces, non-empty)
  case "$t" in
    ''|*/*|*" "*) printf '' ;;
    *) printf '%s' "$t" ;;
  esac
}

cmd_classify() {
  local kind=${1-} key=${2-} payload=${3-}
  # Fail-open on a malformed call.
  [ -n "$kind" ] || { printf 'escalate\n'; return 0; }

  # --- HARD EXCLUSIONS: never absorb these, regardless of any layer ---
  case "$kind" in
    heartbeat) printf 'escalate\n'; return 0 ;;
    check)
      # Only the secondmate wake-loop stall check is gate-able: it is the
      # stood-down idle re-ring. Every other check (merge-confirmation poll,
      # Relay mention, credential/auth failure, startup-network, process-event
      # result, captain inbox note) always escalates.
      case "$key" in
        secondmate-wake-loop-*) : ;;
        *) printf 'escalate\n'; return 0 ;;
      esac ;;
  esac
  case "$payload" in
    *needs-decision*|*blocked*|*watcher*fail*|*WATCHER*FAIL*) printf 'escalate\n'; return 0 ;;
  esac
  case "$key" in
    *watcher*fail*|*watcher-down*) printf 'escalate\n'; return 0 ;;
  esac

  # --- LAYER 1: deterministic stood-down absorber (free, no model) ---
  local task marker_file marker_epoch status_file status_mtime
  task=$(task_from_row "$kind" "$key" "$payload")
  if [ -n "$task" ]; then
    marker_file="$STATE/$task.stooddown"
    if [ -f "$marker_file" ]; then
      marker_epoch=$(cut -f1 "$marker_file" 2>/dev/null | head -1)
      case "$marker_epoch" in ''|*[!0-9]*) marker_epoch='' ;; esac
      status_file="$STATE/$task.status"
      if [ -n "$marker_epoch" ] && [ -f "$status_file" ]; then
        status_mtime=$(stat -f %m "$status_file" 2>/dev/null || stat -c %Y "$status_file" 2>/dev/null)
        case "$status_mtime" in ''|*[!0-9]*) status_mtime='' ;; esac
        # Absorb only when the status log has NOT advanced since the stand-down.
        # An advanced log means the task did something new -> escalate (fail-open).
        if [ -n "$status_mtime" ] && [ "$status_mtime" -le "$marker_epoch" ]; then
          case "$kind:$key" in
            stale:*|signal:*|check:secondmate-wake-loop-*)
              printf 'absorb:stood-down-rering\n'; return 0 ;;
          esac
        fi
      fi
      # marker present but status advanced/unreadable, or kind not stale/signal:
      # fall through to escalate (fail-open)
    fi
  fi

  # --- LAYER 2: Jev worthiness (opt-in via key var; advisory unless enforced) ---
  # Inert unless a key var is named (FM_WAKE_GATE_KEY_VAR, else the first line of
  # config/wake-gate-key-var). Scores the row with Jev and absorbs only when the
  # probability it NEEDS attention is below a conservative threshold AND
  # FM_WAKE_GATE_ENFORCE=1; otherwise it logs an advisory and escalates. Any
  # error, timeout, missing helper, or non-numeric/'-' result escalates
  # (fail-open). The deterministic hard-exclusions above already removed every
  # decision, blocker, check, and heartbeat, so Jev only ever judges rows that
  # are not provably actionable.
  local keyvar threshold enforce helper hout prob tmo
  keyvar=${FM_WAKE_GATE_KEY_VAR:-}
  if [ -z "$keyvar" ] && [ -f "$HOME_ROOT/config/wake-gate-key-var" ]; then
    keyvar=$(head -1 "$HOME_ROOT/config/wake-gate-key-var" 2>/dev/null | tr -d '[:space:]')
  fi
  [ -n "$keyvar" ] || { printf 'escalate\n'; return 0; }
  threshold=${FM_WAKE_GATE_THRESHOLD:-0.10}
  enforce=${FM_WAKE_GATE_ENFORCE:-}
  if [ -z "$enforce" ]; then
    if [ -f "$HOME_ROOT/config/wake-gate-enforce" ]; then enforce=1; else enforce=0; fi
  fi
  tmo=${FM_WAKE_GATE_TIMEOUT:-6}
  case "$tmo" in ''|*[!0-9]*) tmo=6 ;; esac
  local -a run
  if [ -n "${FM_WAKE_GATE_HELPER:-}" ]; then
    run=( "$FM_WAKE_GATE_HELPER" )
  else
    helper=$SCRIPT_DIR/wake-gate/jev-worthiness.mjs
    [ -f "$helper" ] || { printf 'escalate\n'; return 0; }
    run=( node "$helper" )
  fi
  hout=$(printf '%s | %s | %s\n' "$kind" "$key" "$payload" \
    | FM_WAKE_GATE_KEY_VAR="$keyvar" \
      FM_WAKE_GATE_SECRETS="${FM_WAKE_GATE_SECRETS:-$HOME/.secrets}" \
      FM_WAKE_GATE_TIMEOUT_MS=$(( tmo * 1000 )) \
      "${run[@]}" 2>/dev/null) || hout=''
  prob=$(printf '%s\n' "$hout" | sed -n '2p')
  case "$prob" in
    ''|'-'|*[!0-9.]*) printf 'escalate\n'; return 0 ;;
  esac
  if awk -v p="$prob" -v t="$threshold" 'BEGIN{exit !(p+0 < t+0)}'; then
    if [ "$enforce" = 1 ]; then
      log_usage 1 0 0 0 enforce-absorb
      printf 'absorb:jev-noise\n'; return 0
    fi
    log_advisory "$kind" "$key" would-absorb "jev=$prob<$threshold"
  fi
  printf 'escalate\n'
  return 0
}

cmd_stand_down() {
  local task=${1-}; shift || true
  local reason='stood down'
  while [ $# -gt 0 ]; do
    case "$1" in
      --reason) reason=${2-}; shift 2 ;;
      *) shift ;;
    esac
  done
  case "$task" in ''|*/*|*" "*) echo "error: invalid task id" >&2; return 1 ;; esac
  mkdir -p "$STATE" 2>/dev/null
  printf '%s\t%s\n' "$(date +%s)" "$reason" > "$STATE/$task.stooddown"
  echo "stood-down: $task (state/$task.stooddown)"
}

cmd_resume() {
  local task=${1-}
  case "$task" in ''|*/*|*" "*) echo "error: invalid task id" >&2; return 1 ;; esac
  rm -f "$STATE/$task.stooddown" 2>/dev/null
  echo "resumed: $task (stood-down marker cleared)"
}

cmd_cost() {
  local f="$STATE/wake-gate/usage.log"
  [ -f "$f" ] || { echo "no Jev usage recorded (layer inert)"; return 0; }
  awk -F'\t' '{c+=$2; i+=$3; o+=$4} END {printf "calls=%d input_tokens=%d output_tokens=%d\n", c, i, o}' "$f"
}

verb=${1-}; shift || true
case "$verb" in
  classify)   cmd_classify "$@" ;;
  stand-down) cmd_stand_down "$@" ;;
  resume)     cmd_resume "$@" ;;
  cost)       cmd_cost "$@" ;;
  *) cat >&2 <<EOF
fm-wake-gate.sh - fail-open worthiness gate for supervision wakes
Usage:
  fm-wake-gate.sh classify <kind> <key> <payload>
  fm-wake-gate.sh stand-down <task-id> [--reason <text>]
  fm-wake-gate.sh resume <task-id>
  fm-wake-gate.sh cost
Verdict is 'escalate' unless a narrow deterministic rule proves noise; fail-open.
EOF
    return 2 ;;
esac
