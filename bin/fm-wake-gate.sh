#!/usr/bin/env bash
# fm-wake-gate.sh - fail-open gate deciding whether a supervision wake needs a model turn.
#
# PURPOSE
#   Most stuck-worker alarms end with the supervisor looking at the worker and
#   doing nothing. This gate makes that look cheaply, so the expensive model is
#   called only when the look finds something: a worker waiting on someone, a new
#   failure, a newly finished worker, or evidence nothing explains. Code owns the
#   decision; Jev (typesafe-ai/jev) only answers four narrow questions about the
#   evidence, asked together in one request.
#
# FAIL-OPEN IS THE CONTRACT, NOT A DEFAULT
#   The verdict is `escalate` unless a narrow, positive rule returns `absorb`.
#   Any error, timeout, missing key, missing runtime, unreadable evidence,
#   unparseable row, or answer no question explains escalates. Swallowing a real
#   escalation is the only unacceptable failure.
#
# USAGE
#   fm-wake-gate.sh stale-verdict <task-id> <window> <reason> [--with-look]
#       Watcher-side, called before a possible-wedge alarm is queued. Print
#       `escalate` or `absorb:jev-<class>`. With `--with-look`, an escalate
#       decision that should count as a model look also carries its terminal
#       flags after a tab for the watcher to commit after queueing. Inert
#       (escalate, nothing logged)
#       unless the key variable is named. Gate-able alarms are only the
#       possible-wedge ones; every other stale reason escalates without a call.
#       Gathers the worker's current state and pane tail, asks Jev, and applies
#       the rule below. In shadow mode it logs the decision and always prints
#       `escalate`; only enforce mode may print `absorb`.
#   fm-wake-gate.sh commit-look <task-id> <none|failure|finished|failure,finished>
#       Record a granted model look after its wake has been durably queued.
#   fm-wake-gate.sh report
#       Summarize shadow decisions, and when state/branch-outcomes.jsonl exists
#       list every would-skip alarm whose supervision outcome went to the captain.
#   fm-wake-gate.sh cost
#       Print measured Jev usage so far.
#
# THE STALE RULE (call the model iff any line holds; otherwise skip)
#   - waiting_on_someone >= 0.40
#   - no answer reaches 0.50: unexplained
#   - shows_failure or finished_idle reaches 0.50 and that terminal flag was not
#     present at this task's last model look: each new terminal state gets one look
#   - the last model look is older than 3600 seconds: no worker is left
#     unexamined longer than one hour
#   The watcher records a `call` decision only after its wake is durably queued;
#   a skip does not update the look.
#
# STATE (all under state/, private runtime state)
#   wake-gate/<task-id>.look "<epoch>\t<failure,finished flags>" - the last model look the rule granted, removed by teardown
#   wake-gate/shadow.log     "<epoch>\t<task>\t<mode>\t<call|skip>\t<why>\t<working>\t<waiting>\t<failure>\t<finished>"
#   wake-gate/usage.log      "<epoch>\t<calls>\t<in-tok>\t<out-tok>\t<ms>\t<outcome>"
#
# ENVIRONMENT
#   FM_WAKE_GATE_KEY_VAR     secrets var naming the gateway key (opt-in); else the
#                            first line of config/wake-gate-key-var
#   FM_WAKE_GATE_MODE        shadow (default) or enforce; else the first line of
#                            config/wake-gate-mode
#   FM_WAKE_GATE_SECRETS     secrets file (default ~/.secrets)
#   FM_WAKE_GATE_TIMEOUT     seconds bound on the Jev call (default 6)
#   FM_WAKE_GATE_EVIDENCE_TIMEOUT  seconds bound on each evidence command (default 8)
#   FM_WAKE_GATE_HELPER      replace the Jev helper command (tests); it receives
#                            the evidence JSON on stdin and prints the same rows
#   FM_WAKE_GATE_EVIDENCE_CMD  replace evidence gathering (tests); receives the
#                            task id and prints the evidence text
#   FM_STATE_DIR             state dir (else FM_STATE_OVERRIDE, else <home>/state)
#   FM_CONFIG_OVERRIDE       config dir (default: config/ beside the state dir)
#
# This script only checks that the key VARIABLE is named; the helper reads the
# value at call time and nothing here prints, logs, or passes the key.
set -u

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
FM_ROOT=$(dirname "$SCRIPT_DIR")
HOME_ROOT=${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}
STATE=${FM_STATE_DIR:-${FM_STATE_OVERRIDE:-$HOME_ROOT/state}}
# Config sits beside the state dir, so a synthetic state dir (tests) never reads
# the real home's opt-in.
CONFIG=${FM_CONFIG_OVERRIDE:-$STATE/../config}

log_usage() {  # <calls> <in> <out> <ms> <outcome>
  mkdir -p "$STATE/wake-gate" 2>/dev/null || return 0
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" "$3" "$4" "$5" \
    >> "$STATE/wake-gate/usage.log" 2>/dev/null || true
}

# bounded <secs> <cmd...>: run a command under a wall-clock bound, best effort.
bounded() {
  local secs=$1; shift
  if command -v timeout >/dev/null 2>&1; then timeout -k 1 "$secs" "$@"
  elif command -v gtimeout >/dev/null 2>&1; then gtimeout -k 1 "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
  fi
}

first_line_trimmed() {  # <file>
  LC_ALL=C sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "$1" 2>/dev/null
}

gate_key_var() {
  local v=${FM_WAKE_GATE_KEY_VAR:-}
  if [ -z "$v" ] && [ -f "$CONFIG/wake-gate-key-var" ]; then
    v=$(first_line_trimmed "$CONFIG/wake-gate-key-var")
  fi
  case "$v" in
    ''|[!A-Za-z_]*|*[!A-Za-z0-9_]*) return 0 ;;
    *) printf '%s' "$v" ;;
  esac
}

gate_mode() {
  local m=${FM_WAKE_GATE_MODE:-}
  if [ -z "$m" ] && [ -f "$CONFIG/wake-gate-mode" ]; then
    m=$(first_line_trimmed "$CONFIG/wake-gate-mode")
  fi
  case "$m" in enforce) printf 'enforce' ;; *) printf 'shadow' ;; esac
}

log_shadow() {  # <task> <mode> <decision> <why> <working> <waiting> <failure> <finished>
  mkdir -p "$STATE/wake-gate" 2>/dev/null || return 1
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$@" \
    >> "$STATE/wake-gate/shadow.log" 2>/dev/null
}

# gather_evidence <task>: print a JSON array of {command, output}; empty on failure.
gather_evidence() {
  local task=$1 tmo=${FM_WAKE_GATE_EVIDENCE_TIMEOUT:-8} state_out pane_out
  case "$tmo" in
    ''|*[!0-9]*) tmo=8 ;;
    *) [ "$tmo" -gt 0 ] 2>/dev/null || tmo=8 ;;
  esac
  if [ -n "${FM_WAKE_GATE_EVIDENCE_CMD:-}" ]; then
    state_out=$(bounded "$tmo" "$FM_WAKE_GATE_EVIDENCE_CMD" "$task" 2>/dev/null </dev/null) || return 1
    pane_out=''
  else
    state_out=$(FM_HOME="$HOME_ROOT" bounded "$tmo" "$SCRIPT_DIR/fm-crew-state.sh" "$task" 2>&1 </dev/null) || return 1
    pane_out=$(FM_HOME="$HOME_ROOT" bounded "$tmo" "$SCRIPT_DIR/fm-peek.sh" "$task" 40 2>/dev/null </dev/null) || return 1
  fi
  jq -cn --arg s "$state_out" --arg p "$pane_out" \
    '[{command:"current state",output:$s},{command:"pane tail",output:$p}] | map(select(.output|test("\\S")))' 2>/dev/null
}

cmd_stale_verdict() {
  local task=${1-} reason=${3-} with_look=${4-}  # $2 is the window, already named inside the reason
  local keyvar mode evidence hout answers aw wt fl fn why='' decision cls conf look_file look_record='' look_invalid=0 last_epoch='' last_flags='' terminal_flags='' flag now tmo helper_status=0 helper_error='' failure_calls=1
  case "$task" in ''|*/*|*" "*) printf 'escalate\n'; return 0 ;; esac
  keyvar=$(gate_key_var)
  [ -n "$keyvar" ] || { printf 'escalate\n'; return 0; }
  # Only the possible-wedge alarm is gate-able; an unread instruction, unwritable
  # bookkeeping, or any other stale reason always reaches the model.
  case "$reason" in *'possible wedge'*) : ;; *) printf 'escalate\n'; return 0 ;; esac
  command -v jq >/dev/null 2>&1 || { printf 'escalate\n'; return 0; }
  mode=$(gate_mode)
  tmo=${FM_WAKE_GATE_TIMEOUT:-6}
  case "$tmo" in ''|*[!0-9]*) tmo=6 ;; esac

  evidence=$(gather_evidence "$task") || evidence=''
  case "$evidence" in ''|'[]') log_shadow "$task" "$mode" call no-evidence - - - -; printf 'escalate\n'; return 0 ;; esac

  local -a run
  if [ -n "${FM_WAKE_GATE_HELPER:-}" ]; then
    run=( "$FM_WAKE_GATE_HELPER" )
  else
    [ -f "$SCRIPT_DIR/wake-gate/jev-stale.mjs" ] || { printf 'escalate\n'; return 0; }
    run=( node "$SCRIPT_DIR/wake-gate/jev-stale.mjs" )
  fi
  hout=$(jq -cn --arg a "$reason" --argjson e "$evidence" '{alarm:$a,evidence:$e}' \
    | FM_WAKE_GATE_KEY_VAR="$keyvar" \
      FM_WAKE_GATE_SECRETS="${FM_WAKE_GATE_SECRETS:-$HOME/.secrets}" \
      FM_WAKE_GATE_TIMEOUT_MS=$(( tmo * 1000 )) \
      bounded $(( tmo + 2 )) "${run[@]}" 2>/dev/null)
  helper_status=$?
  helper_error=$(printf '%s\n' "$hout" | awk -F'\t' '$1=="error"{print $2; exit}')
  if [ "$helper_status" -ne 0 ]; then
    case "$helper_error" in no-key|no-runtime|bad-input|no-evidence) failure_calls=0 ;; esac
    log_usage "$failure_calls" 0 0 0 "error-${helper_error:-unknown}"
    log_shadow "$task" "$mode" call jev-error - - - -
    printf 'escalate\n'
    return 0
  fi
  answers=$(printf '%s\n' "$hout" | awk -F'\t' '$1=="answers"{print; exit}')
  IFS=$'\t' read -r _ aw wt fl fn <<EOF_ANSWERS
$answers
EOF_ANSWERS
  local p
  for p in "${aw:-}" "${wt:-}" "${fl:-}" "${fn:-}"; do
    case "$p" in ''|*[!0-9.]*) log_usage 1 0 0 0 error; log_shadow "$task" "$mode" call jev-error - - - -; printf 'escalate\n'; return 0 ;; esac
  done
  printf '%s\n' "$hout" | awk -F'\t' '$1=="usage"{print $2"\t"$3"\t"$4"\t"$5}' | {
    IFS=$'\t' read -r u_calls u_in u_out u_ms || true
    log_usage "${u_calls:-1}" "${u_in:-0}" "${u_out:-0}" "${u_ms:-0}" ok
  }

  look_file="$STATE/wake-gate/$task.look"
  now=$(date +%s)
  if [ -f "$look_file" ]; then
    if IFS= read -r look_record < "$look_file"; then
      case "$look_record" in
        *$'\t'*)
          last_epoch=${look_record%%$'\t'*}
          last_flags=${look_record#*$'\t'}
          case "$last_flags" in ''|failure|finished|failure,finished) ;; *) look_invalid=1 ;; esac
          ;;
        *) look_invalid=1 ;;
      esac
      case "$last_epoch" in ''|*[!0-9]*) look_invalid=1 ;; esac
      if [ "$look_invalid" -eq 0 ] \
        && ! awk -v e="$last_epoch" -v n="$now" 'BEGIN { exit !(e + 0 <= n + 0) }'; then
        look_invalid=1
      fi
    else
      look_invalid=1
    fi
    if [ "$look_invalid" -ne 0 ]; then
      last_epoch=''
      last_flags=''
    fi
  fi
  read -r cls conf <<EOF_CLS
$(awk -v a="$aw" -v w="$wt" -v f="$fl" -v n="$fn" 'BEGIN{c="working";m=a+0; if(w+0>m){c="waiting";m=w+0} if(f+0>m){c="failure";m=f+0} if(n+0>m){c="finished";m=n+0} print c, m}')
EOF_CLS
  if awk -v f="$fl" 'BEGIN{exit !(f+0 >= 0.50)}'; then terminal_flags=failure; fi
  if awk -v n="$fn" 'BEGIN{exit !(n+0 >= 0.50)}'; then
    if [ -n "$terminal_flags" ]; then terminal_flags="$terminal_flags,finished"; else terminal_flags=finished; fi
  fi
  if awk -v w="$wt" 'BEGIN{exit !(w+0 >= 0.40)}'; then why=waiting
  elif awk -v m="$conf" 'BEGIN{exit !(m+0 < 0.50)}'; then why=unexplained
  elif [ -n "$terminal_flags" ]; then
    for flag in failure finished; do
      case ",$terminal_flags," in
        *,$flag,*) case ",$last_flags," in *,$flag,*) ;; *) why="new-$flag"; break ;; esac ;;
      esac
    done
  fi
  if [ -z "$why" ] && { [ -z "$last_epoch" ] || [ $(( now - last_epoch )) -ge 3600 ]; }; then why=silence-backstop; fi
  if [ -n "$why" ]; then
    decision=call
  else
    decision=skip; why="same-$cls"
  fi
  if ! log_shadow "$task" "$mode" "$decision" "$why" "$aw" "$wt" "$fl" "$fn"; then
    printf 'escalate\n'
    return 0
  fi
  if [ "$decision" = skip ] && [ "$mode" = enforce ]; then
    printf 'absorb:jev-%s\n' "$cls"
  elif [ "$decision" = call ] && [ "$with_look" = --with-look ]; then
    printf 'escalate\t%s\n' "${terminal_flags:-none}"
  else
    printf 'escalate\n'
  fi
  return 0
}

cmd_commit_look() {
  local task=${1-} flags=${2-} now tmp look_file
  case "$task" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  case "$flags" in
    none) flags='' ;;
    failure|finished|failure,finished) ;;
    *) return 1 ;;
  esac
  now=$(date +%s) || return 1
  mkdir -p "$STATE/wake-gate" 2>/dev/null || return 1
  tmp=$(mktemp "$STATE/wake-gate/.look.XXXXXX") || return 1
  look_file="$STATE/wake-gate/$task.look"
  if ! (umask 077; printf '%s\t%s\n' "$now" "$flags" > "$tmp") \
    || ! mv -f -- "$tmp" "$look_file"; then
    rm -f -- "$tmp"
    return 1
  fi
}

cmd_report() {
  local f="$STATE/wake-gate/shadow.log" o="$STATE/branch-outcomes.jsonl"
  [ -f "$f" ] || { echo "no gate decisions recorded"; return 0; }
  awk -F'\t' '{n++; d[$4]++; w[$4" "$5]++} END {printf "alarms=%d call=%d skip=%d\n", n, d["call"], d["skip"]; for (k in w) printf "  %s: %d\n", k, w[k]}' "$f" | sort
  [ -f "$o" ] && command -v jq >/dev/null 2>&1 || return 0
  echo "would-skip alarms whose supervision outcome went to the captain (within 20 min):"
  awk -F'\t' '$4=="skip"{print $1"\t"$2}' "$f" | while IFS=$'\t' read -r epoch task; do
    jq -r --arg t "$task" --argjson e "$epoch" \
      'select(.task==$t and (.wake|startswith("stale")) and .verdict=="captain" and .epoch>=$e and .epoch<=($e+1200)) | "  \($e)\t\($t)\t\(.summary[0:160])"' "$o" 2>/dev/null | head -1
  done
}

cmd_cost() {
  local f="$STATE/wake-gate/usage.log"
  [ -f "$f" ] || { echo "no Jev usage recorded (layer inert)"; return 0; }
  awk -F'\t' '{c+=$2; i+=$3; o+=$4} END {printf "calls=%d input_tokens=%d output_tokens=%d\n", c, i, o}' "$f"
}

verb=${1-}; shift || true
case "$verb" in
  stale-verdict) cmd_stale_verdict "$@" ;;
  commit-look) cmd_commit_look "$@" ;;
  report)     cmd_report "$@" ;;
  cost)       cmd_cost "$@" ;;
  *) cat >&2 <<EOF
fm-wake-gate.sh - fail-open worthiness gate for supervision wakes
Usage:
  fm-wake-gate.sh stale-verdict <task-id> <window> <reason> [--with-look]
  fm-wake-gate.sh commit-look <task-id> <none|failure|finished|failure,finished>
  fm-wake-gate.sh report
  fm-wake-gate.sh cost
Verdict is 'escalate' unless a narrow rule proves the wake needs no model turn; fail-open.
EOF
    exit 2 ;;
esac
