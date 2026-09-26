#!/usr/bin/env bash
# fm-model-chain-launch-lib.sh - the launch owner's chain resolver, shared by
# fm-spawn.sh and fm-control.sh so a spawn and a relaunch resolve chained
# model surfaces under one contract. Parsing and cooldown semantics live in
# fm-model-chain-lib.sh (the supervision branch idiom); this file only owns
# the launch-side surface handling. Requires the caller to have sourced
# fm-model-chain-lib.sh and to hold STATE set to the home's state directory.
#
# fm_model_chain_resolve_for_launch <lane> <what> <model-surface>
#
# Resolves one model surface, on stdout, to a single "<provider>/<model-id>"
# label: a single-label surface is an exact pin and is returned untouched, a
# comma-separated surface is a fallback chain resolved through <lane>'s
# durable cooldown state, and a malformed chain is a loud refusal. Discloses
# on stderr (never stdout, which carries the resolved model) which label was
# selected and which entries were skipped and why; an exhausted chain refuses
# with that reason. The caller owns recording <lane> in the task's meta when
# the surface it passed was chained.
fm_model_chain_resolve_for_launch() {  # <lane> <what> <model-surface>
  local lane=$1 what=$2 surface=$3 state chosen
  case "$surface" in
    ''|default|*,*) : ;;
    *) printf '%s\n' "$surface"; return 0 ;; # exact pin: no lane, no cooldowns
  esac
  case "$surface" in
    '') return 0 ;; # no model: the caller's default fills in unchanged
    default) return 0 ;;
  esac
  fm_model_chain_is_chained "$surface" || {
    echo "error: $what model chain '$surface' is not a comma-separated list of <provider>/<model-id> labels; refusing" >&2
    return 1
  }
  state="$STATE/model-chain/$lane.state"
  mkdir -p "$STATE/model-chain" 2>/dev/null || true
  chosen=$(fm_model_chain_select "$state" "$(fm_model_chain_chain_to_lines "$surface")") || return 1
  # The lane exists from its first use: an empty file records "nothing is
  # cooling down yet", and the refusal recorder appends to this same path.
  : >> "$state" 2>/dev/null || true
  echo "model chain ($what, lane $lane): selected $chosen" >&2
  printf '%s\n' "$chosen"
}
