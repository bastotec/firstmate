#!/usr/bin/env bash
# Behavior tests for bin/fm-supervision-lib.sh, the shared "supervision missing"
# predicate bin/fm-guard.sh builds its watcher alarms on: which homes need
# supervision (in-flight tasks, the X-mode relay poll, process-event sources,
# registered custom checks) and whether the watcher beacon is fresh.
# All hermetic over temp dirs; no agent session or watcher is started.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-supervision-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-supervision-lib)

test_predicate_healthy_no_inflight() {
  local state="$TMP_ROOT/pred-empty/state"
  mkdir -p "$state"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate reported unhealthy with zero in-flight tasks"
  fi
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "expected zero in-flight, got $FM_SUP_IN_FLIGHT"
  pass "fm_supervision_unhealthy: false with no state/*.meta at all"
}

test_predicate_unhealthy_no_beacon() {
  local state="$TMP_ROOT/pred-nobeat/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon never seen"
  [ "$FM_SUP_IN_FLIGHT" -eq 1 ] || fail "expected 1 in-flight, got $FM_SUP_IN_FLIGHT"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "beacon absent must not read as fresh"
  [ "$FM_SUP_BEACON_DESC" = never ] || fail "beacon description should be 'never', got $FM_SUP_BEACON_DESC"
  pass "fm_supervision_unhealthy: true with in-flight task and no beacon ever"
}

test_predicate_unhealthy_stale_beacon() {
  local state="$TMP_ROOT/pred-stale/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch -t 202001010000 "$state/.last-watcher-beat"
  fm_supervision_unhealthy "$state" 300 || fail "predicate did not fire: in-flight task, beacon far outside grace"
  [ "$FM_SUP_WATCHER_FRESH" = false ] || fail "an ancient beacon must not read as fresh"
  pass "fm_supervision_unhealthy: true with in-flight task and a beacon far outside the grace window"
}

test_predicate_healthy_fresh_beacon() {
  local state="$TMP_ROOT/pred-fresh/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  touch "$state/.last-watcher-beat"
  if fm_supervision_unhealthy "$state" 300; then
    fail "predicate fired despite a fresh beacon"
  fi
  [ "$FM_SUP_WATCHER_FRESH" = true ] || fail "a beacon touched just now must read as fresh"
  pass "fm_supervision_unhealthy: false with in-flight task and a fresh beacon"
}

test_predicate_queue_pending_flag() {
  local state="$TMP_ROOT/pred-queue/state"
  mkdir -p "$state"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = false ] || fail "empty/absent wake queue must not read as pending"
  printf 'record\n' > "$state/.wake-queue"
  fm_supervision_status "$state" 300
  [ "$FM_SUP_QUEUE_PENDING" = true ] || fail "a non-empty wake queue must read as pending"
  pass "fm_supervision_status: FM_SUP_QUEUE_PENDING tracks state/.wake-queue"
}

test_predicate_x_mode_needs_supervision() {
  local state="$TMP_ROOT/pred-x-mode/state"
  mkdir -p "$state"
  : > "$state/x-watch.check.sh"
  fm_supervision_needed "$state" 300 || fail "X-mode relay poll did not register as supervision need"
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "X-mode relay poll must not count as an in-flight task"
  [ "$FM_SUP_NEEDED" = true ] || fail "X-mode relay poll must set FM_SUP_NEEDED"
  fm_supervision_unhealthy "$state" 300 || fail "X-mode relay poll with no beacon must be unhealthy"
  pass "fm_supervision_needed: X-mode relay poll needs supervision"
}

test_predicate_source_needs_supervision() {
  local state="$TMP_ROOT/pred-source/state"
  mkdir -p "$state/procevent"
  : > "$state/procevent/source-only.source"
  fm_supervision_unhealthy "$state" 300 || fail "registered source with no beacon must be unhealthy"
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "a process-event source must not count as a task"
  [ "$FM_SUP_SOURCES" -eq 1 ] || fail "expected one registered process-event source"
  pass "fm_supervision_unhealthy: source-only home needs supervision"
}

# Register a custom check the way an operator does, through the real
# bin/fm-check-register.sh, so these cases bind to the shipped registration
# artifacts rather than to a hand-written imitation of them.
register_custom_check() {
  local state=$1 id=$2
  printf '#!/usr/bin/env bash\nexit 0\n' > "$state/$id.check.sh"
  chmod 700 "$state/$id.check.sh"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" "$id" >/dev/null \
    || fail "fm-check-register.sh could not register $id"
}

test_predicate_registered_check_needs_supervision() {
  local state="$TMP_ROOT/pred-check/state"
  mkdir -p "$state"
  register_custom_check "$state" issue-comments
  fm_supervision_needed "$state" 300 || fail "a registered custom check did not register as supervision need"
  [ "$FM_SUP_IN_FLIGHT" -eq 0 ] || fail "a registered custom check must not count as an in-flight task"
  [ "$FM_SUP_CHECKS" -eq 1 ] || fail "expected one registered custom check, got $FM_SUP_CHECKS"
  fm_supervision_unhealthy "$state" 300 || fail "a registered custom check with no beacon must be unhealthy"
  pass "fm_supervision_needed: a registered custom check needs supervision with no task in flight"
}

test_predicate_registered_check_survives_rebinding_drift() {
  local state="$TMP_ROOT/pred-check-drift/state"
  mkdir -p "$state"
  register_custom_check "$state" issue-comments
  printf '#!/usr/bin/env bash\necho drifted\n' > "$state/issue-comments.check.sh"
  fm_supervision_needed "$state" 300 \
    || fail "an edited registered check must keep supervision on so the sweep can report the rejection"
  [ "$FM_SUP_CHECKS" -eq 1 ] || fail "expected the edited check to stay counted, got $FM_SUP_CHECKS"
  pass "fm_supervision_needed: a registered check whose bytes drifted still needs supervision"
}

test_predicate_unregistered_check_needs_nothing() {
  local state="$TMP_ROOT/pred-check-unregistered/state"
  mkdir -p "$state"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$state/rogue.check.sh"
  chmod 700 "$state/rogue.check.sh"
  if fm_supervision_needed "$state" 300; then
    fail "a check with no trust binding must not arm supervision"
  fi
  [ "$FM_SUP_CHECKS" -eq 0 ] || fail "an unregistered check must not be counted, got $FM_SUP_CHECKS"
  pass "fm_supervision_needed: false for a check.sh with no registration binding"
}

test_predicate_task_pr_poll_is_not_a_custom_check() {
  local state="$TMP_ROOT/pred-pr-poll/state"
  mkdir -p "$state"
  : > "$state/task1.meta"
  printf '#!/usr/bin/env bash\nexit 0\n' > "$state/task1.check.sh"
  chmod 700 "$state/task1.check.sh"
  : > "$state/task1.pr-poll"
  fm_supervision_needed "$state" 300 || fail "the in-flight task itself must need supervision"
  [ "$FM_SUP_IN_FLIGHT" -eq 1 ] || fail "expected the task to be the one in-flight need, got $FM_SUP_IN_FLIGHT"
  [ "$FM_SUP_CHECKS" -eq 0 ] || fail "a task PR poll must not count as a registered custom check"
  pass "fm_supervision_needed: a task PR poll without a trust binding is not a registered custom check"
}

test_predicate_relay_shim_is_not_a_custom_check() {
  local state="$TMP_ROOT/pred-relay-not-custom/state"
  mkdir -p "$state"
  : > "$state/x-watch.check.sh"
  fm_supervision_needed "$state" 300 || fail "the relay poll must still need supervision"
  [ "$FM_SUP_CHECKS" -eq 0 ] || fail "the relay shim keeps its own trust path and must not be counted as a custom check"
  pass "fm_supervision_status: the relay shim is not counted as a registered custom check"
}

test_predicate_healthy_no_inflight
test_predicate_unhealthy_no_beacon
test_predicate_unhealthy_stale_beacon
test_predicate_healthy_fresh_beacon
test_predicate_queue_pending_flag
test_predicate_x_mode_needs_supervision
test_predicate_source_needs_supervision
test_predicate_registered_check_needs_supervision
test_predicate_registered_check_survives_rebinding_drift
test_predicate_unregistered_check_needs_nothing
test_predicate_task_pr_poll_is_not_a_custom_check
test_predicate_relay_shim_is_not_a_custom_check
