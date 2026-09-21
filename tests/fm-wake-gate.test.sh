#!/usr/bin/env bash
# tests/fm-wake-gate.test.sh - the fail-open supervision wake gate
# (bin/fm-wake-gate.sh). The gate's only job is to absorb provable mechanical
# noise (a stale/stall/signal re-ring of a task the captain explicitly stood
# down, with no new durable status) so it is acknowledged without spending a
# model turn. Every case exercises the classify CLI over a synthetic state dir;
# nothing reaches the network and no model is called (stale-verdict runs against
# a stub helper and stub evidence).
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

# --- stale-verdict: the evidence rule (stub helper and stub evidence; no network) ---
# The stub helper prints the four probabilities from FM_TEST_ANSWERS
# (working waiting failure finished), or an error row when it is "error".
STUB="$TMP_ROOT/wg-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
[ "${FM_TEST_ANSWERS:-}" = error ] && { printf 'error\tcall-failed\n'; exit 5; }
printf 'usage\t1\t1200\t0\t400\n'
# shellcheck disable=SC2086 # the four answers are deliberately word-split
printf 'answers\t%s\t%s\t%s\t%s\n' $FM_TEST_ANSWERS
SH
EVID="$TMP_ROOT/wg-evidence"
cat > "$EVID" <<'SH'
#!/usr/bin/env bash
printf 'state: working (run-step: test running) for %s\n' "$1"
SH
chmod +x "$STUB" "$EVID"
WEDGE='stale: w:fm-t1 (idle 300s, possible wedge)'
verdict() {  # <state> <mode> <answers> [reason] -> verdict line
  FM_STATE_DIR="$1" FM_WAKE_GATE_HELPER="$STUB" FM_WAKE_GATE_EVIDENCE_CMD="$EVID" \
    FM_WAKE_GATE_KEY_VAR=DUMMY_KEY FM_WAKE_GATE_MODE="$2" FM_TEST_ANSWERS="$3" \
    "$GATE" stale-verdict t1 w:fm-t1 "${4:-$WEDGE}" 2>/dev/null
}
last_decision() { tail -1 "$1/wake-gate/shadow.log" | cut -f4,5; }
WORKING='0.92 0.05 0.06 0.04'

s=$(new_state sv-inert)
[ "$(FM_STATE_DIR="$s" FM_WAKE_GATE_HELPER="$STUB" FM_WAKE_GATE_EVIDENCE_CMD="$EVID" FM_TEST_ANSWERS="$WORKING" \
  "$GATE" stale-verdict t1 w:fm-t1 "$WEDGE" 2>/dev/null)" = escalate ] || fail "without a key variable the gate must escalate"
[ ! -e "$s/wake-gate/shadow.log" ] || fail "an inert gate must not log a decision"
pass "stale-verdict is inert without the opt-in key variable"

s=$(new_state sv-first-look)
[ "$(verdict "$s" enforce "$WORKING")" = escalate ] || fail "SAFETY: a worker never looked at must get a model look first"
[ "$(last_decision "$s")" = "$(printf 'call\tsilence-backstop')" ] || fail "the first look must be recorded as the silence backstop"
[ "$(verdict "$s" enforce "$WORKING")" = absorb:jev-working ] || fail "a visibly working worker already looked at must absorb in enforce mode"
pass "first alarm gets a model look; later working alarms absorb in enforce mode"

s=$(new_state sv-shadow)
verdict "$s" shadow "$WORKING" >/dev/null
[ "$(verdict "$s" shadow "$WORKING")" = escalate ] || fail "shadow mode must never absorb"
[ "$(last_decision "$s")" = "$(printf 'skip\tsame-working')" ] || fail "shadow mode must still log the would-skip decision"
pass "shadow mode logs the would-skip decision and changes nothing"

s=$(new_state sv-waiting)
verdict "$s" enforce "$WORKING" >/dev/null
[ "$(verdict "$s" enforce '0.10 0.86 0.05 0.04')" = escalate ] || fail "SAFETY: a worker waiting on someone must reach the model"
[ "$(verdict "$s" enforce '0.30 0.20 0.25 0.20')" = escalate ] || fail "SAFETY: evidence nothing explains must reach the model"
[ "$(last_decision "$s")" = "$(printf 'call\tunexplained')" ] || fail "an unexplained alarm must be logged as such"
pass "waiting and unexplained evidence always reach the model"

s=$(new_state sv-terminal)
verdict "$s" enforce "$WORKING" >/dev/null
[ "$(verdict "$s" enforce '0.05 0.05 0.95 0.10')" = escalate ] || fail "SAFETY: a new failure must reach the model"
[ "$(verdict "$s" enforce '0.05 0.05 0.95 0.10')" = absorb:jev-failure ] || fail "the same failure already looked at must absorb"
[ "$(verdict "$s" enforce '0.05 0.05 0.10 0.93')" = escalate ] || fail "SAFETY: a newly finished worker must reach the model once"
pass "a new failed or finished state gets exactly one model look"

s=$(new_state sv-backstop)
verdict "$s" enforce "$WORKING" >/dev/null
printf '%s\tworking\n' "$(( $(date +%s) - 4000 ))" > "$s/wake-gate/t1.look"
[ "$(verdict "$s" enforce "$WORKING")" = escalate ] || fail "SAFETY: a look older than the silence bound must reach the model"
pass "no worker goes unexamined past the silence bound"

s=$(new_state sv-failopen)
verdict "$s" enforce "$WORKING" >/dev/null
[ "$(verdict "$s" enforce error)" = escalate ] || fail "SAFETY: a Jev failure must escalate"
[ "$(verdict "$s" enforce "$WORKING" 'stale: w:fm-t1 (unread firstmate instruction: x.msg still unhandled)')" = escalate ] \
  || fail "SAFETY: an unread-instruction alarm is never gate-able"
[ "$(FM_STATE_DIR="$s" FM_WAKE_GATE_HELPER="$STUB" FM_WAKE_GATE_EVIDENCE_CMD=/nonexistent FM_WAKE_GATE_KEY_VAR=DUMMY_KEY \
  FM_WAKE_GATE_MODE=enforce FM_TEST_ANSWERS="$WORKING" "$GATE" stale-verdict t1 w:fm-t1 "$WEDGE" 2>/dev/null)" = escalate ] \
  || fail "SAFETY: missing evidence must escalate"
[ "$(FM_STATE_DIR="$s" FM_WAKE_GATE_KEY_VAR=DUMMY_KEY "$GATE" stale-verdict '../x' w "$WEDGE" 2>/dev/null)" = escalate ] \
  || fail "SAFETY: an invalid task id must escalate"
pass "helper errors, non-wedge alarms, missing evidence, and bad ids escalate (fail-open)"

echo "fm-wake-gate: all cases passed"
