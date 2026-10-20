#!/usr/bin/env bash

FM_MERGE_POLICY_LOCK=

fm_merge_policy_lock_hold() {
  local config=$1 tries=0 lock="$1/.merge-policy.lock"
  mkdir -p "$config" || return 1
  until mkdir "$lock" 2>/dev/null; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || return 1
    sleep 0.1
  done
  FM_MERGE_POLICY_LOCK=$lock
}

fm_merge_policy_lock_release() {
  [ -n "${FM_MERGE_POLICY_LOCK:-}" ] || return 0
  rmdir "$FM_MERGE_POLICY_LOCK" 2>/dev/null || return 1
  FM_MERGE_POLICY_LOCK=
}
