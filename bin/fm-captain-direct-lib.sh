#!/usr/bin/env bash
# fm-captain-direct-lib.sh - the parent side of a captain-direct message.
#
# When the captain writes to a second mate himself (bin/fm-send.sh
# --from-captain), the mate already has his words and answers him in its own
# conversation. The parent mate is told so it knows what the captain said to
# its mates, but it must never deliver those words again: a parent steer that
# restates or "reconciles" the captain's message makes the mate answer the
# captain a second time (captain direction 2026-10-13).
#
# This library owns three things:
#   1. A durable ledger of recent captain-direct deliveries in the parent home,
#      state/captain-direct/<corr> (key=value: task_id, epoch) plus
#      <corr>.text (the captain's words), pruned after 7 days.
#   2. The FYI inbox note the parent gets for each delivery
#      (fm_captain_direct_note_text): it names the corr, says the mate already
#      has the message, and says not to forward, steer, or re-ask.
#   3. The echo guard (fm_captain_direct_echo_corr): a parent steer to the same
#      mate that carries that corr within the ledger's 7 days, or within 2 hours
#      shares a 6-word run with the captain's words or talks about the captain's
#      direct message, is an echo. bin/fm-send.sh does not
#      send it unless the caller passes --correction.
# Every guard decision is appended to state/captain-direct.log.
#
# No side effects on source. set -u safe.

FM_CAPTAIN_DIRECT_SHINGLE=6

fm_captain_direct_dir() {  # <state-dir>
  printf '%s/captain-direct' "$1"
}

fm_captain_direct_now() {
  if [ -n "${FM_CAPTAIN_DIRECT_NOW:-}" ]; then
    printf '%s' "$FM_CAPTAIN_DIRECT_NOW"
  else
    date +%s
  fi
}

fm_captain_direct_num() {  # <value> <default>
  case "$1" in
    ''|*[!0-9]*) printf '%s' "$2" ;;
    *) printf '%s' "$1" ;;
  esac
}

# Append one line to the home's captain-direct log, best-effort.
fm_captain_direct_log() {  # <state-dir> <text>
  printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$2" >> "$1/captain-direct.log" 2>/dev/null || true
}

# Record one delivered captain-direct message, then prune old entries.
fm_captain_direct_record() {  # <state-dir> <task-id> <corr> <captain-text>
  local state=$1 task=$2 corr=$3 text=$4 dir now
  dir=$(fm_captain_direct_dir "$state")
  mkdir -p "$dir" 2>/dev/null || return 1
  chmod 700 "$dir" 2>/dev/null || true
  now=$(fm_captain_direct_now)
  printf '%s' "$text" > "$dir/$corr.text.tmp.$$" || return 1
  printf 'task_id=%s\nepoch=%s\n' "$task" "$now" > "$dir/$corr.tmp.$$" || return 1
  mv -f "$dir/$corr.text.tmp.$$" "$dir/$corr.text" || return 1
  mv -f "$dir/$corr.tmp.$$" "$dir/$corr" || return 1
  fm_captain_direct_prune "$state" "$now"
  fm_captain_direct_log "$state" "delivered corr=$corr task=$task"
}

fm_captain_direct_prune() {  # <state-dir> <now>
  local dir now=$2 f epoch
  dir=$(fm_captain_direct_dir "$1")
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.text|*.tmp.*) continue ;; esac
    epoch=$(sed -n 's/^epoch=//p' "$f" | head -1)
    epoch=$(fm_captain_direct_num "$epoch" 0)
    if [ $((now - epoch)) -gt 604800 ]; then
      rm -f "$f" "$f.text"
    fi
  done
}

# The FYI note the parent mate gets for one captain-direct delivery.
fm_captain_direct_note_text() {  # <mate-name> <corr> <captain-text>
  local mate=$1 corr=$2 text=$3
  printf 'Captain steered %s directly (corr=%s). FYI only: %s already has this message and answers him itself. Do not forward it, steer %s about it, or re-ask %s; firstmate will not send a steer that repeats it. Act only if his words ask something of you, or if a later report from %s shows a real gap (then send that one fix with --correction). His words:\n%s' \
    "$mate" "$corr" "$mate" "$mate" "$mate" "$mate" "$text"
}

# Lowercase words, one per line.
_fm_captain_direct_words() {  # <text>
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9' '\n' | grep -v '^$' || true
}

# 0 when <message> shares a run of FM_CAPTAIN_DIRECT_SHINGLE words with <text>.
fm_captain_direct_shares_run() {  # <captain-text> <message>
  local n=$FM_CAPTAIN_DIRECT_SHINGLE
  awk -v n="$n" '
    FNR == 1 { file++ }
    { w[file, ++c[file]] = $0 }
    END {
      if (c[1] < n || c[2] < n) exit 1
      for (i = 1; i + n - 1 <= c[1]; i++) {
        k = ""
        for (j = 0; j < n; j++) k = k " " w[1, i + j]
        seen[k] = 1
      }
      for (i = 1; i + n - 1 <= c[2]; i++) {
        k = ""
        for (j = 0; j < n; j++) k = k " " w[2, i + j]
        if (k in seen) exit 0
      }
      exit 1
    }' <(_fm_captain_direct_words "$1") <(_fm_captain_direct_words "$2")
}

# 0 when <message> talks about the captain writing to the mate directly.
fm_captain_direct_mentions() {  # <message>
  printf '%s' "$1" | grep -Eiq 'captain' || return 1
  printf '%s' "$1" | grep -Eiq '(^|[^a-z])direct(ly)?([^a-z]|$)|captain[^a-z]?s?[- ]direct'
}

# Print the corr of a recent captain-direct delivery to <task-id> that
# <message> echoes, and return 0; return 1 when it is not an echo.
fm_captain_direct_echo_corr() {  # <state-dir> <task-id> <message>
  local state=$1 task=$2 msg=$3 dir now f corr epoch rec_task text
  dir=$(fm_captain_direct_dir "$state")
  [ -d "$dir" ] || return 1
  now=$(fm_captain_direct_now)
  fm_captain_direct_prune "$state" "$now"
  for f in "$dir"/*; do
    [ -f "$f" ] || continue
    case "$f" in *.text|*.tmp.*) continue ;; esac
    corr=${f##*/}
    rec_task=$(sed -n 's/^task_id=//p' "$f" | head -1)
    [ "$rec_task" = "$task" ] || continue
    epoch=$(fm_captain_direct_num "$(sed -n 's/^epoch=//p' "$f" | head -1)" 0)
    [ $((now - epoch)) -le 604800 ] || continue
    # A corr named outright is an echo at any age the ledger still holds.
    case "$msg" in
      *"$corr"*) printf '%s' "$corr"; return 0 ;;
    esac
    [ $((now - epoch)) -le 7200 ] || continue
    text=$(cat "$f.text" 2>/dev/null || true)
    if fm_captain_direct_mentions "$msg" || { [ -n "$text" ] && fm_captain_direct_shares_run "$text" "$msg"; }; then
      printf '%s' "$corr"
      return 0
    fi
  done
  return 1
}
