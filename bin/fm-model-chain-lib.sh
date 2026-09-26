#!/usr/bin/env bash
# fm-model-chain-lib.sh - the spawn-side model fallback chain, a literal reuse
# of the supervision branch's approved model-chain idiom
# (.pi/extensions/lib/fm-branch-model-chain.ts): one "<provider>/<model-id>"
# entry per line in preference order, blank lines and "#" comments skipped,
# a split at the FIRST "/" so a provider-qualified model id survives, any
# malformed or duplicate non-comment line is a loud refusal naming that line
# instead of a silent selection around it, a failed model sits out for five
# minutes doubling to an hour, and an expired cooldown restores the head of
# the chain. docs/configuration.md "Model fallback chains" owns the
# operator-facing format and the chain sources; the branch extension file
# remains the origin of the idiom. The deliberate divergences are
# shell-vs-TypeScript and the cooldowns living in durable home-local files
# (state/model-chain-<lane>) instead of the branch's memory, so a refused
# model is not retried immediately on the next launch.
#
# The pure choice functions here print their results or one diagnostic line
# and never mutate anything but their own cooldown state file; callers own
# refusing on a diagnostic exit.
#
# Functions:
#   fm_model_chain_parse <text>          parse stored chain text; print one
#                                        "<provider>|<model-id>" line per
#                                        entry, or print one diagnostic to
#                                        stderr and return 1
#   fm_model_chain_parse_file <path>     parse a chain file the same way; an
#                                        absent file parses as empty
#   fm_model_chain_head <text>           print the first entry's label, or
#                                        nothing for an empty chain (parse
#                                        errors still refuse)
#   fm_model_chain_select <state-path> <text>
#                                        print the first entry whose cooldown
#                                        has expired, after one
#                                        "chain skip: <label> <reason>" line
#                                        per entry passed over on stderr; on
#                                        an exhausted chain print one
#                                        diagnostic to stderr and return 1
#   fm_model_chain_record_refusal <state-path> <label> <now-seconds>
#                                        put <label> into cooldown with the
#                                        branch backoff (five minutes,
#                                        doubling to an hour)
#   fm_model_chain_clear <state-path> <label>
#                                        drop <label>'s cooldown record so a
#                                        later launch reads it ready again
#
# Cooldown state file, one record per line ("<label><TAB><retry-epoch>"):
# written by fm_model_chain_record_refusal and fm_model_chain_clear under the
# lock below, read by fm_model_chain_select. An entry whose retry epoch has
# passed is simply ready again, exactly like the branch's in-memory cooldowns.
set -u

FM_MODEL_CHAIN_COOLDOWN_BASE_SECS=$((5 * 60))
FM_MODEL_CHAIN_COOLDOWN_MAX_SECS=$((60 * 60))

fm_model_chain__parse_stream() {
  # Reads the stored chain from stdin; prints "ok" and the entries, or a
  # diagnostic. Internal: the public wrappers own the plumbing.
  local line trimmed prefix separator bad byte
  local -a chain_seen=()
  while IFS= read -r line || [ -n "$line" ]; do
    trimmed="${line#"${line%%[![:space:]]*}"}"
    trimmed="${trimmed%"${trimmed##*[![:space:]]}"}"
    [ -n "$trimmed" ] || continue
    case "$trimmed" in '#'*) continue ;; esac
    # A model reference contains no whitespace or control characters: the
    # branch chain tests the raw line for \s and U+0000-U+001F, U+007F-U+009F,
    # which over UTF-8 bytes is exactly the set below (space through control,
    # DEL, and the C1 range).
    bad=0
    for byte in $(printf '%s' "$line" | LC_ALL=C od -An -tu1 | tr -s ' \n' '  '); do
      if [ "$byte" -le 32 ] || [ "$byte" -eq 127 ] || { [ "$byte" -ge 128 ] && [ "$byte" -le 159 ]; }; then
        bad=1
        break
      fi
    done
    prefix=${line%%/*}
    separator=${#prefix}
    if [ "$bad" -eq 1 ] || [ "$prefix" = "$line" ] || [ "$separator" -eq 0 ] || [ "$separator" -ge $(( ${#line} - 1 )) ]; then
      printf 'invalid model chain line: %s\n' "$(printf '%s' "$line" | head -c 120)" >&2
      return 1
    fi
    case " ${chain_seen[*]-} " in
      *" $line "*)
        printf 'duplicate model chain line: %s\n' "$(printf '%s' "$line" | head -c 120)" >&2
        return 1
        ;;
    esac
    chain_seen+=("$line")
    printf '%s|%s\n' "${line%%/*}" "${line#*/}"
  done
  return 0
}

fm_model_chain_parse_file() {
  local path=$1 out rc
  if [ ! -f "$path" ]; then
    return 0
  fi
  out=$(fm_model_chain__parse_stream < "$path")
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out"
}

fm_model_chain_parse() {
  local stored=$1 out rc
  out=$(printf '%s' "$stored" | fm_model_chain__parse_stream)
  rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  printf '%s' "$out"
}

fm_model_chain_head() {
  local stored=$1 parsed
  parsed=$(fm_model_chain_parse "$stored") || return 1
  [ -n "$parsed" ] || return 0
  printf '%s\n' "${parsed%%$'\n'*}" | tr '|' '/'
}

fm_model_chain__state_lookup() {
  # Print the retry epoch recorded for $2 in the state file at $1, or nothing.
  local state=$1 label=$2 row
  [ -f "$state" ] || return 0
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    [ "${row%%$'\t'*}" = "$label" ] && { printf '%s\n' "${row#*$'\t'}"; return 0; }
  done < "$state"
}

fm_model_chain_select() {
  # Print the label of the first entry that is not sitting out, after one
  # "chain skip:" line per entry passed over on stderr. Driven by the parsed
  # entries so the refusal contract stays single-owner in the parser.
  local state=$1 stored=$2 parsed row_labels label retry skipped_first=1
  parsed=$(fm_model_chain_parse "$stored") || return 1
  [ -n "$parsed" ] || return 1
  while IFS= read -r row_labels; do
    [ -n "$row_labels" ] || continue
    label=$(printf '%s\n' "$row_labels" | tr '|' '/')
    retry=$(fm_model_chain__state_lookup "$state" "$label")
    if [ -n "$retry" ] && [ "$retry" -gt "$(date +%s)" ]; then
      if [ "$skipped_first" -eq 1 ]; then
        printf 'chain skip: %s in cooldown until %s\n' "$label" \
          "$(fm_model_chain__fmt_epoch "$retry")" >&2
        skipped_first=0
      else
        printf 'chain skip: %s in cooldown\n' "$label" >&2
      fi
      continue
    fi
    printf '%s\n' "$label"
    return 0
  done <<< "$parsed"
  printf 'model chain exhausted: every entry is in cooldown; refusing rather than substituting an out-of-chain model\n' >&2
  return 1
}

fm_model_chain__fmt_epoch() {
  # Print <epoch> as an ISO-8601 UTC instant, portable across BSD and GNU date,
  # falling back to the raw epoch when neither form works.
  date -u -r "$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -d "@$1" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || printf '%s' "$1"
}

fm_model_chain_record_refusal() {
  # Put <label> into cooldown with the branch backoff: five minutes on the
  # first refusal of a streak, then each prior cooldown doubled, capped at an
  # hour - the arithmetic of the branch's nextBranchModelCooldown. The stored
  # retry epoch alone carries the streak: while the old entry is still in the
  # future the failure is part of the same streak (doubling), while an expired
  # or absent entry starts a fresh streak at the base. One label per line, so
  # the newest record wins and older entries for the same label are pruned.
  local state=$1 label=$2 now=$3 row epoch previous
  [ -f "$state" ] || { : > "$state" || return 1; }
  previous=$(fm_model_chain__state_lookup "$state" "$label")
  case "$previous" in
    ''|*[!0-9]*) previous= ;;
  esac
  if [ -n "$previous" ] && [ "$previous" -gt "$now" ]; then
    epoch=$(( previous + previous - now ))
    [ "$epoch" -le $(( now + FM_MODEL_CHAIN_COOLDOWN_MAX_SECS )) ] || \
      epoch=$(( now + FM_MODEL_CHAIN_COOLDOWN_MAX_SECS ))
  else
    epoch=$(( now + FM_MODEL_CHAIN_COOLDOWN_BASE_SECS ))
  fi
  fm_model_chain__state_lock "$state" || return 1
  if {
    printf '%s\t%s\n' "$label" "$epoch"
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      if [ "${row%%$'\t'*}" != "$label" ]; then
        printf '%s\n' "$row"
      fi
    done < "$state"
  } > "$state.tmp.$$"; then
    mv "$state.tmp.$$" "$state"
  else
    rm -f "$state.tmp.$$"
    fm_model_chain__state_unlock "$state"
    return 1
  fi
  fm_model_chain__state_unlock "$state"
}

fm_model_chain_clear() {
  # Drop every record for <label>: a launch that succeeded on the model clears
  # its streak, exactly like the branch clearing a backoff after a turn that
  # settles cleanly.
  local state=$1 label=$2
  [ -f "$state" ] || return 0
  fm_model_chain__state_lock "$state" || return 1
  if {
    while IFS= read -r row; do
      [ -n "$row" ] || continue
      if [ "${row%%$'\t'*}" != "$label" ]; then
        printf '%s\n' "$row"
      fi
    done < "$state"
  } > "$state.tmp.$$"; then
    mv "$state.tmp.$$" "$state"
  else
    rm -f "$state.tmp.$$"
    fm_model_chain__state_unlock "$state"
    return 1
  fi
  fm_model_chain__state_unlock "$state"
}

# Best-effort mkdir lock serializing the read-modify-write of one lane's
# cooldown file ("<lane>.state.lock" beside it); contention waits briefly and
# then gives up, so a rare lost update costs one immediate retry at worst.
fm_model_chain__state_lock() {
  local dir="${1%/*}.lock" waited=0
  mkdir "$dir" 2>/dev/null && return 0
  while ! mkdir "$dir" 2>/dev/null; do
    waited=$(( waited + 1 ))
    [ "$waited" -ge 100 ] && return 1
    sleep 0.1
  done
}

fm_model_chain__state_unlock() {
  local dir="${1%/*}.lock"
  rmdir "$dir" 2>/dev/null || true
}
