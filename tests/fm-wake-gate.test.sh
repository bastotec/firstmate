#!/usr/bin/env bash
# tests/fm-wake-gate.test.sh - the fail-open supervision wake gate
# (bin/fm-wake-gate.sh). The gate's only job is to absorb provable mechanical
# noise (a stale/stall/signal re-ring of a task the captain explicitly stood
# down, with no new durable status) so it is acknowledged without spending a
# model turn. Every case exercises the classify CLI over a synthetic state dir;
# nothing reaches the network and no model is called (the Jev layer ships inert).
# The load-bearing guarantees: the default verdict is escalate; a decision,
# blocker, check, heartbeat, or watcher-failure row NEVER absorbs regardless of
# any marker; a stood-down row absorbs only while its status log has not
# advanced; and any malformed input escalates (fail-open).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

GATE="$ROOT/bin/fm-wake-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-gate-tests)

# classify <state> <kind> <key> <payload> -> verdict line
classify() {
  local state=$1; shift
  FM_STATE_DIR="$state" "$GATE" classify "$@" 2>/dev/null
}

# new_state <name> -> echoes a fresh empty state dir
new_state() {
  local d="$TMP_ROOT/$1"; mkdir -p "$d"; printf '%s' "$d"
}

# stand_down <state> <task> <epoch> -> write a marker with an explicit epoch
stand_down() {
  printf '%s\t%s\n' "$3" "test stand-down" > "$1/$2.stooddown"
}

# status_at <state> <task> <YYYYMMDDhhMM> -> a status file with a fixed old mtime
status_at() {
  printf 'working: old line\n' > "$1/$2.status"
  touch -t "$3" "$1/$2.status"
}

# --- the default is escalate: a live (unmarked) task's stale wake passes ---
s=$(new_state live)
[ "$(classify "$s" stale 'firstmate:fm-some-task' 'stale: idle pane')" = escalate ] \
  || fail "an unmarked task's stale wake must escalate"
pass "unmarked task escalates (gate is inert without a stand-down)"

# --- stood-down + status NOT advanced -> absorb (stale, stall check, signal) ---
s=$(new_state down-quiet)
stand_down "$s" docana-delivery "$(date +%s)"
status_at "$s" docana-delivery 202001010000
[ "$(classify "$s" stale 'firstmate:fm-docana-delivery' 'stale: idle pane')" = absorb:stood-down-rering ] \
  || fail "a stood-down task's stale re-ring with no new status must absorb"
[ "$(classify "$s" check 'secondmate-wake-loop-docana-delivery-1789940215-1792' 'check: secondmate wake-loop stalled: mate=docana-delivery')" = absorb:stood-down-rering ] \
  || fail "a stood-down wake-loop stall re-ring must absorb"
pass "stood-down mechanical re-rings absorb (stale + wake-loop stall)"

# --- HARD EXCLUSIONS: never absorb, even when stood down and quiet ---
s=$(new_state down-but-decision)
stand_down "$s" firstmate-runtime "$(date +%s)"
status_at "$s" firstmate-runtime 202001010000
[ "$(classify "$s" signal 'firstmate-runtime.status' 'needs-decision [key=x]: captain hold')" = escalate ] \
  || fail "SAFETY: a needs-decision row must escalate even when stood down"
[ "$(classify "$s" signal 'firstmate-runtime.status' 'blocked [key=y]: pending-reply-missed')" = escalate ] \
  || fail "SAFETY: a blocked row must escalate even when stood down"
[ "$(classify "$s" check 'merged-firstmate-runtime-https://x/pull/26' 'check: merge landed')" = escalate ] \
  || fail "SAFETY: a merge-confirmation check must escalate even when stood down"
[ "$(classify "$s" heartbeat 'fleet' 'heartbeat: review fleet')" = escalate ] \
  || fail "SAFETY: a heartbeat must escalate"
[ "$(classify "$s" stale 'firstmate:fm-firstmate-runtime' 'stale: watcher failure alarm')" = escalate ] \
  || fail "SAFETY: a watcher-failure row must escalate even when stood down"
pass "decisions, blockers, merge checks, heartbeats, watcher failures never absorb"

# --- stood-down but status ADVANCED -> escalate (the task did something new) ---
s=$(new_state down-but-active)
stand_down "$s" docana-delivery 1000000000   # marker far in the past
printf 'done [key=z]: new work landed\n' > "$s/docana-delivery.status"  # mtime = now
[ "$(classify "$s" signal 'docana-delivery.status' 'signal: docana-delivery.status')" = escalate ] \
  || fail "SAFETY: a stood-down task whose status advanced must escalate"
pass "an advanced status log escalates despite the stand-down"

# --- fail-open on malformed input ---
s=$(new_state malformed)
[ "$(classify "$s" '' '' '')" = escalate ] || fail "an empty kind must escalate"
[ "$(classify "$s" stale '../../etc/passwd' 'x')" = escalate ] \
  || fail "an unresolvable task id must escalate, not absorb"
pass "malformed and unresolvable rows escalate (fail-open)"

# --- resume clears the marker -> escalates again ---
s=$(new_state resume)
stand_down "$s" docana-delivery "$(date +%s)"
status_at "$s" docana-delivery 202001010000
[ "$(classify "$s" stale 'firstmate:fm-docana-delivery' 'stale: idle')" = absorb:stood-down-rering ] \
  || fail "precondition: stood-down re-ring should absorb before resume"
"$GATE" resume docana-delivery >/dev/null 2>&1 || true
# resume acts on the script's own state dir, so clear the synthetic marker too
rm -f "$s/docana-delivery.stooddown"
[ "$(classify "$s" stale 'firstmate:fm-docana-delivery' 'stale: idle')" = escalate ] \
  || fail "after resume the same wake must escalate"
pass "resume clears the stand-down and the wake escalates again"

# --- LAYER 2: Jev worthiness (stub helper; opt-in, advisory-by-default, fail-open) ---
s=$(new_state jev)
STUB="$TMP_ROOT/wg-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
printf 'usage\t1\t10\t1\t5\n'
printf '%s\n' "${FM_TEST_PROB:-0.5}"
SH
chmod +x "$STUB"
jclassify() {  # <prob> <enforce> <kind> <key> <payload>
  FM_STATE_DIR="$s" FM_WAKE_GATE_HELPER="$STUB" FM_WAKE_GATE_KEY_VAR=DUMMY_KEY \
    FM_TEST_PROB="$1" FM_WAKE_GATE_ENFORCE="$2" "$GATE" classify "$3" "$4" "$5" 2>/dev/null
}
[ "$(jclassify 0.05 0 signal some-task.status 'signal: routine progress')" = escalate ] \
  || fail "advisory mode must escalate even a low-worthiness row"
[ "$(jclassify 0.05 1 signal some-task.status 'signal: routine progress')" = absorb:jev-noise ] \
  || fail "enforce mode must absorb a low-worthiness row"
[ "$(jclassify 0.80 1 signal some-task.status 'signal: something happened')" = escalate ] \
  || fail "a high-worthiness row must escalate even when enforcing"
[ "$(jclassify '-' 1 signal some-task.status 'signal: x')" = escalate ] \
  || fail "SAFETY: a Jev failure ('-') must escalate (fail-open)"
[ "$(jclassify 0.01 1 signal some-task.status 'needs-decision [key=x]: choose')" = escalate ] \
  || fail "SAFETY: a hard-excluded needs-decision row must escalate before Jev, even at 0.01 enforcing"
pass "Jev layer: advisory-by-default, enforce absorbs only low-worthiness, fail-open, exclusions win"

echo "fm-wake-gate: all cases passed"
