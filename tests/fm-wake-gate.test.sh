#!/usr/bin/env bash
# tests/fm-wake-gate.test.sh - the fail-open Jev gate for possible-wedge alarms
# (bin/fm-wake-gate.sh stale-verdict, commit-look). Every case runs against a
# stub Jev helper and stub evidence over a synthetic state dir; nothing reaches
# the network and no model is called. The load-bearing guarantees: the verdict
# is escalate unless the evidence rule proves the alarm needs no model turn;
# waiting, unexplained, and newly failed or finished evidence always reach the
# model; shadow mode never absorbs; and every error escalates (fail-open).
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

GATE="$ROOT/bin/fm-wake-gate.sh"
TMP_ROOT=$(fm_test_tmproot fm-wake-gate-tests)

# new_state <name> -> echoes a fresh empty state dir
new_state() {
  local d="$TMP_ROOT/$1"; mkdir -p "$d"; printf '%s' "$d"
}

configure_gate() {  # <state> <mode>
  mkdir -p "$1/config"
  printf 'DUMMY_KEY\n' > "$1/config/wake-gate-key-var"
  printf '%s\n' "$2" > "$1/config/wake-gate-mode"
}

# --- stale-verdict: the evidence rule (stub helper and stub evidence; no network) ---
# The stub helper prints the four probabilities from FM_TEST_ANSWERS
# (working waiting failure finished), or an error row when it is "error".
STUB="$TMP_ROOT/wg-stub"
cat > "$STUB" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
[ "${FM_TEST_ANSWERS:-}" = preflight ] && { printf 'error\tno-key\n'; exit 3; }
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
TIMEOUT_BIN="$TMP_ROOT/timeout-bin"
TIMEOUT_LOG="$TMP_ROOT/timeout.log"
mkdir -p "$TIMEOUT_BIN"
cat > "$TIMEOUT_BIN/timeout" <<'SH'
#!/usr/bin/env bash
if [ "${1-}" = -k ]; then shift 2; fi
printf '%s\n' "${1-}" >> "$FM_TEST_TIMEOUT_LOG"
shift
exec "$@"
SH
chmod +x "$TIMEOUT_BIN/timeout"
WEDGE='stale: w:fm-t1 (idle 300s, possible wedge)'
raw_verdict() {  # <state> <mode> <answers> [reason] -> verdict and optional look flags
  configure_gate "$1" "$2"
  FM_STATE_DIR="$1" FM_CONFIG_OVERRIDE="$1/config" \
    FM_WAKE_GATE_HELPER="$STUB" FM_WAKE_GATE_EVIDENCE_CMD="$EVID" FM_TEST_ANSWERS="$3" \
    "$GATE" stale-verdict t1 w:fm-t1 "${4:-$WEDGE}" --with-look 2>/dev/null
}
config_verdict() {  # <state> <answers> -> verdict from that state's config files
  FM_STATE_DIR="$1" FM_CONFIG_OVERRIDE="$1/config" FM_WAKE_GATE_HELPER="$STUB" \
    FM_WAKE_GATE_EVIDENCE_CMD="$EVID" FM_TEST_ANSWERS="$2" \
    "$GATE" stale-verdict t1 w:fm-t1 "$WEDGE" --with-look 2>/dev/null
}
verdict() {  # <state> <mode> <answers> [reason] -> verdict line after simulated durable queueing
  local state=$1 result flags
  result=$(raw_verdict "$@")
  case "$result" in
    escalate$'\t'*)
      flags=${result#*$'\t'}
      FM_STATE_DIR="$state" "$GATE" commit-look t1 "$flags" 2>/dev/null \
        || fail "committing a granted model look failed"
      printf 'escalate\n'
      ;;
    *) printf '%s\n' "$result" ;;
  esac
}
last_decision() { tail -1 "$1/wake-gate/shadow.log" | cut -f4,5; }
WORKING='0.92 0.05 0.06 0.04'

s=$(new_state sv-zero-evidence-timeout)
configure_gate "$s" shadow
: > "$TIMEOUT_LOG"
FM_TEST_TIMEOUT_LOG="$TIMEOUT_LOG" PATH="$TIMEOUT_BIN:$PATH" FM_STATE_DIR="$s" \
  FM_CONFIG_OVERRIDE="$s/config" FM_WAKE_GATE_HELPER="$STUB" FM_WAKE_GATE_EVIDENCE_CMD="$EVID" \
  FM_TEST_ANSWERS="$WORKING" FM_WAKE_GATE_EVIDENCE_TIMEOUT=0 \
  "$GATE" stale-verdict t1 w:fm-t1 "$WEDGE" >/dev/null 2>&1
[ "$(head -1 "$TIMEOUT_LOG")" = 8 ] \
  || fail "a zero evidence timeout did not fall back to the positive default"
pass "zero cannot disable the evidence timeout"

s=$(new_state sv-preflight-cost)
[ "$(verdict "$s" enforce preflight)" = escalate ] \
  || fail "SAFETY: a helper preflight failure must escalate"
[ "$(FM_STATE_DIR="$s" "$GATE" cost)" = 'calls=0 input_tokens=0 output_tokens=0' ] \
  || fail "a preflight failure was counted as a Jev request"
pass "preflight failures record zero Jev calls"

s=$(new_state sv-inert)
[ "$(FM_STATE_DIR="$s" FM_CONFIG_OVERRIDE="$s/config" FM_WAKE_GATE_HELPER="$STUB" \
  FM_WAKE_GATE_EVIDENCE_CMD="$EVID" FM_TEST_ANSWERS="$WORKING" \
  FM_WAKE_GATE_KEY_VAR=DUMMY_KEY FM_WAKE_GATE_MODE=enforce \
  "$GATE" stale-verdict t1 w:fm-t1 "$WEDGE" 2>/dev/null)" = escalate ] \
  || fail "without the opt-in config file the gate must escalate"
[ ! -e "$s/wake-gate/shadow.log" ] || fail "environment aliases activated the inert gate"
pass "only the config files can opt in and enable enforcement"

s=$(new_state sv-config-trim)
mkdir -p "$s/config" "$s/wake-gate"
printf ' \tDUMMY_KEY \r\n' > "$s/config/wake-gate-key-var"
printf ' \tenforce \r\n' > "$s/config/wake-gate-mode"
printf '%s\t\n' "$(date +%s)" > "$s/wake-gate/t1.look"
[ "$(config_verdict "$s" "$WORKING")" = absorb:jev-working ] \
  || fail "outer whitespace around valid wake-gate config tokens was not trimmed"
pass "wake-gate config trims outer whitespace without weakening exact tokens"

s=$(new_state sv-config-malformed-mode)
mkdir -p "$s/config" "$s/wake-gate"
printf 'DUMMY_KEY\n' > "$s/config/wake-gate-key-var"
printf 'en force\n' > "$s/config/wake-gate-mode"
printf '%s\t\n' "$(date +%s)" > "$s/wake-gate/t1.look"
[ "$(config_verdict "$s" "$WORKING")" = escalate ] \
  || fail "SAFETY: malformed mode whitespace enabled wake absorption"
[ "$(tail -1 "$s/wake-gate/shadow.log" | cut -f3)" = shadow ] \
  || fail "a malformed mode did not default to shadow"
pass "malformed wake-gate mode remains shadow"

s=$(new_state sv-config-malformed-key)
mkdir -p "$s/config" "$s/wake-gate"
printf 'DUMMY KEY\n' > "$s/config/wake-gate-key-var"
printf 'enforce\n' > "$s/config/wake-gate-mode"
printf '%s\t\n' "$(date +%s)" > "$s/wake-gate/t1.look"
[ "$(config_verdict "$s" "$WORKING")" = escalate ] \
  || fail "SAFETY: internal key-variable whitespace activated the wake gate"
[ ! -e "$s/wake-gate/shadow.log" ] || fail "a malformed key-variable name reached Jev decision handling"
printf '9DUMMY_KEY\n' > "$s/config/wake-gate-key-var"
[ "$(config_verdict "$s" "$WORKING")" = escalate ] \
  || fail "SAFETY: a key-variable name beginning with a digit activated the wake gate"
[ ! -e "$s/wake-gate/shadow.log" ] || fail "an invalid key-variable identifier reached Jev decision handling"
pass "malformed key-variable names leave the wake gate inert"

s=$(new_state sv-first-look)
first_result=$(raw_verdict "$s" enforce "$WORKING")
[ "$first_result" = "$(printf 'escalate\tnone')" ] || fail "SAFETY: a worker never looked at must request a committed model look first"
[ ! -e "$s/wake-gate/t1.look" ] || fail "SAFETY: stale-verdict persisted a look before the wake was durably queued"
[ "$(raw_verdict "$s" enforce "$WORKING")" = "$(printf 'escalate\tnone')" ] \
  || fail "SAFETY: an uncommitted look suppressed a retry"
FM_STATE_DIR="$s" "$GATE" commit-look t1 none || fail "committing the queued look failed"
[ "$(last_decision "$s")" = "$(printf 'call\tsilence-backstop')" ] || fail "the first look must be recorded as the silence backstop"
[ "$(verdict "$s" enforce "$WORKING")" = absorb:jev-working ] || fail "a visibly working worker already looked at must absorb in enforce mode"
pass "looks count only after queue commit; later working alarms absorb"

s=$(new_state sv-invalid-look)
mkdir -p "$s/wake-gate"
printf '%s\t\n' "$(( $(date +%s) + 3600 ))" > "$s/wake-gate/t1.look"
[ "$(verdict "$s" enforce "$WORKING")" = escalate ] \
  || fail "SAFETY: a future last-look epoch must force a model look"
[ "$(last_decision "$s")" = "$(printf 'call\tsilence-backstop')" ] \
  || fail "a future last-look epoch was not treated as invalid"
printf '%s\tgarbage\n' "$(date +%s)" > "$s/wake-gate/t1.look"
[ "$(verdict "$s" enforce "$WORKING")" = escalate ] \
  || fail "SAFETY: malformed last-look flags must force a model look"
[ "$(last_decision "$s")" = "$(printf 'call\tsilence-backstop')" ] \
  || fail "malformed last-look flags were not treated as invalid"
pass "future and malformed look records fail open"

s=$(new_state sv-oversized-look)
mkdir -p "$s/wake-gate"
awk 'BEGIN { for (i = 0; i < 1024; i++) printf "1" }' > "$s/wake-gate/t1.look"
if python3 "$ROOT/bin/fm-state-io.py" read "$s" t1.look > "$s/read-output" 2>/dev/null; then
  fail "SAFETY: the state helper accepted an oversized look record"
fi
[ ! -s "$s/read-output" ] || fail "the state helper emitted bytes from an oversized look record"
[ "$(raw_verdict "$s" enforce "$WORKING")" = escalate ] \
  || fail "SAFETY: an oversized look record did not force a model look"
pass "oversized look records are rejected without unbounded reads"

s=$(new_state sv-shadow)
verdict "$s" shadow "$WORKING" >/dev/null
[ "$(verdict "$s" shadow "$WORKING")" = escalate ] || fail "shadow mode must never absorb"
[ "$(last_decision "$s")" = "$(printf 'skip\tsame-working')" ] || fail "shadow mode must still log the would-skip decision"
pass "shadow mode logs the would-skip decision and changes nothing"

s=$(new_state sv-log-failure)
verdict "$s" enforce "$WORKING" >/dev/null
rm -f "$s/wake-gate/shadow.log"
mkdir "$s/wake-gate/shadow.log"
[ "$(verdict "$s" enforce "$WORKING")" = escalate ] \
  || fail "SAFETY: an unrecordable skip decision must escalate"
pass "enforce mode fails open when its decision log cannot be written"

s=$(new_state sv-usage-log-failure)
mkdir -p "$s/wake-gate/usage.log"
printf '%s\t\n' "$(date +%s)" > "$s/wake-gate/t1.look"
[ "$(raw_verdict "$s" enforce "$WORKING")" = escalate ] \
  || fail "SAFETY: an unrecordable usage row allowed an absorb decision"
[ ! -e "$s/wake-gate/shadow.log" ] || fail "a decision was applied after its usage write failed"
pass "enforce mode fails open when usage cannot be recorded"

s=$(new_state sv-log-symlinks)
mkdir -p "$s/wake-gate"
printf 'protected\n' > "$s/protected"
printf '%s\t\n' "$(date +%s)" > "$s/wake-gate/t1.look"
ln -s ../protected "$s/wake-gate/shadow.log"
ln -s ../protected "$s/wake-gate/usage.log"
[ "$(raw_verdict "$s" enforce "$WORKING")" = escalate ] \
  || fail "SAFETY: symlinked wake-gate logs allowed an absorb decision"
[ "$(cat "$s/protected")" = protected ] || fail "SAFETY: a wake-gate log append followed its symlink target"
pass "wake-gate log appends refuse symlinked targets"

s=$(new_state sv-log-hardlinks)
mkdir -p "$s/wake-gate"
printf 'protected\n' > "$s/protected"
printf '%s\t\n' "$(date +%s)" > "$s/wake-gate/t1.look"
ln "$s/protected" "$s/wake-gate/shadow.log"
ln "$s/protected" "$s/wake-gate/usage.log"
[ "$(raw_verdict "$s" enforce "$WORKING")" = escalate ] \
  || fail "SAFETY: hard-linked wake-gate logs allowed an absorb decision"
[ "$(cat "$s/protected")" = protected ] || fail "SAFETY: a wake-gate log append modified a hard-linked file"
pass "wake-gate log appends refuse hard-linked targets"

s=$(new_state sv-log-race)
mkdir -p "$s/wake-gate"
printf 'protected\n' > "$s/protected"
printf '%s\t\n' "$(date +%s)" > "$s/wake-gate/t1.look"
(
  while :; do
    rm -f "$s/wake-gate/shadow.log"
    ln -s ../protected "$s/wake-gate/shadow.log" 2>/dev/null || true
    rm -f "$s/wake-gate/shadow.log"
    : > "$s/wake-gate/shadow.log"
  done
) &
racer=$!
for _ in {1..30}; do raw_verdict "$s" enforce "$WORKING" >/dev/null; done
kill "$racer" 2>/dev/null || true
wait "$racer" 2>/dev/null || true
[ "$(cat "$s/protected")" = protected ] || fail "SAFETY: a raced wake-gate append followed a swapped symlink"
pass "wake-gate log appends withstand target replacement races"

s=$(new_state sv-log-parent-symlink)
mkdir -p "$s/redirected"
printf '%s\t\n' "$(date +%s)" > "$s/redirected/t1.look"
ln -s redirected "$s/wake-gate"
[ "$(raw_verdict "$s" enforce "$WORKING")" = escalate ] \
  || fail "SAFETY: a symlinked wake-gate parent allowed an absorb decision"
[ ! -e "$s/redirected/shadow.log" ] && [ ! -e "$s/redirected/usage.log" ] \
  || fail "SAFETY: wake-gate logs were written through a symlinked parent"
pass "wake-gate log appends refuse an unsafe parent"

s=$(new_state sv-log-parent-mode)
mkdir -p "$s/wake-gate"
printf '%s\t\n' "$(date +%s)" > "$s/wake-gate/t1.look"
chmod 777 "$s/wake-gate"
[ "$(raw_verdict "$s" enforce "$WORKING")" = escalate ] \
  || fail "SAFETY: a writable wake-gate state directory allowed an absorb decision"
[ ! -e "$s/wake-gate/shadow.log" ] && [ ! -e "$s/wake-gate/usage.log" ] \
  || fail "SAFETY: wake-gate logs were written beneath an unsafe directory"
chmod 700 "$s/wake-gate"
pass "wake-gate writes refuse an unsafe directory"

s=$(new_state sv-look-symlink)
mkdir -p "$s/wake-gate"
printf 'protected\n' > "$s/protected"
ln -s ../protected "$s/wake-gate/t1.look"
if FM_STATE_DIR="$s" "$GATE" commit-look t1 none 2>/dev/null; then
  fail "SAFETY: commit-look accepted a symlinked destination"
fi
[ "$(cat "$s/protected")" = protected ] || fail "SAFETY: commit-look followed its symlink target"
[ -L "$s/wake-gate/t1.look" ] || fail "a refused commit-look replaced the unsafe destination"
pass "wake-gate look commits refuse symlinked targets"

s=$(new_state sv-look-hardlink)
mkdir -p "$s/wake-gate"
printf 'protected\n' > "$s/protected"
ln "$s/protected" "$s/wake-gate/t1.look"
if FM_STATE_DIR="$s" "$GATE" commit-look t1 none 2>/dev/null; then
  fail "SAFETY: commit-look accepted a hard-linked destination"
fi
[ "$(cat "$s/protected")" = protected ] || fail "SAFETY: commit-look modified a hard-linked file"
[ "$s/protected" -ef "$s/wake-gate/t1.look" ] || fail "a refused commit-look replaced the hard-linked destination"
pass "wake-gate look commits refuse hard-linked targets"

s=$(new_state sv-waiting)
verdict "$s" enforce "$WORKING" >/dev/null
[ "$(verdict "$s" enforce '0.10 0.86 0.05 0.04')" = escalate ] || fail "SAFETY: a worker waiting on someone must reach the model"
[ "$(verdict "$s" enforce '0.30 0.20 0.25 0.20')" = escalate ] || fail "SAFETY: evidence nothing explains must reach the model"
[ "$(last_decision "$s")" = "$(printf 'call\tunexplained')" ] || fail "an unexplained alarm must be logged as such"
pass "waiting and unexplained evidence always reach the model"

s=$(new_state sv-terminal)
verdict "$s" enforce "$WORKING" >/dev/null
[ "$(verdict "$s" enforce '0.90 0.05 0.80 0.10')" = escalate ] || fail "SAFETY: failure evidence must not be hidden by a stronger working answer"
[ "$(verdict "$s" enforce '0.90 0.05 0.80 0.75')" = escalate ] || fail "SAFETY: a newly present finished flag must reach the model independently"
[ "$(verdict "$s" enforce '0.90 0.05 0.80 0.75')" = absorb:jev-working ] || fail "terminal flags already looked at must not repeatedly escalate"
[ "$(tail -1 "$s/wake-gate/t1.look" | cut -f2)" = 'failure,finished' ] || fail "the look record did not retain both terminal flags"
pass "independent new failure and finished flags each get a model look"

s=$(new_state sv-terminal-switch)
verdict "$s" enforce "$WORKING" >/dev/null
[ "$(verdict "$s" enforce '0.05 0.05 0.95 0.10')" = escalate ] || fail "SAFETY: a new failure must reach the model"
[ "$(verdict "$s" enforce '0.05 0.05 0.95 0.10')" = absorb:jev-failure ] || fail "the same failure already looked at must absorb"
[ "$(verdict "$s" enforce '0.05 0.05 0.10 0.93')" = escalate ] || fail "SAFETY: a newly finished worker must reach the model once"
pass "a new failed or finished state gets exactly one model look"

s=$(new_state sv-backstop)
verdict "$s" enforce "$WORKING" >/dev/null
printf '%s\t\n' "$(( $(date +%s) - 4000 ))" > "$s/wake-gate/t1.look"
[ "$(FM_WAKE_GATE_MAX_SILENCE_SECS=999999 verdict "$s" enforce "$WORKING")" = escalate ] || fail "SAFETY: a look older than the fixed silence bound must reach the model"
[ "$(FM_WAKE_GATE_WAIT_THRESHOLD=1 verdict "$s" enforce '0.10 0.86 0.05 0.04')" = escalate ] || fail "SAFETY: environment must not weaken the fixed waiting threshold"
[ "$(FM_WAKE_GATE_EXPLAIN_THRESHOLD=0 verdict "$s" enforce '0.30 0.20 0.25 0.20')" = escalate ] || fail "SAFETY: environment must not weaken the fixed unexplained threshold"
pass "calibrated thresholds and silence bound cannot be overridden"

s=$(new_state sv-invalid-probabilities)
invalid_answers=(
  '2 0 0 0'
  '-0.1 0 0 0'
  '0 1.5 0 0'
  '0 0 0..5 0'
  '0.9 0 0'
)
for answers in "${invalid_answers[@]}"; do
  mkdir -p "$s/wake-gate"
  printf '%s\t\n' "$(date +%s)" > "$s/wake-gate/t1.look"
  [ "$(raw_verdict "$s" enforce "$answers")" = escalate ] \
    || fail "SAFETY: invalid Jev probability '$answers' did not escalate"
  [ "$(last_decision "$s")" = "$(printf 'call\tjev-error')" ] \
    || fail "invalid Jev probability '$answers' was not recorded as a helper error"
done
pass "malformed and out-of-range probabilities fail open"

s=$(new_state sv-failopen)
verdict "$s" enforce "$WORKING" >/dev/null
[ "$(verdict "$s" enforce error)" = escalate ] || fail "SAFETY: a Jev failure must escalate"
[ "$(verdict "$s" enforce "$WORKING" 'stale: w:fm-t1 (unread firstmate instruction: x.msg still unhandled)')" = escalate ] \
  || fail "SAFETY: an unread-instruction alarm is never gate-able"
[ "$(FM_STATE_DIR="$s" FM_CONFIG_OVERRIDE="$s/config" FM_WAKE_GATE_HELPER="$STUB" \
  FM_WAKE_GATE_EVIDENCE_CMD=/nonexistent FM_TEST_ANSWERS="$WORKING" \
  "$GATE" stale-verdict t1 w:fm-t1 "$WEDGE" 2>/dev/null)" = escalate ] \
  || fail "SAFETY: missing evidence must escalate"

partial="$TMP_ROOT/partial-evidence"
mkdir -p "$partial/bin" "$partial/config" "$partial/state/wake-gate"
printf 'DUMMY_KEY\n' > "$partial/config/wake-gate-key-var"
printf 'enforce\n' > "$partial/config/wake-gate-mode"
cp "$GATE" "$partial/bin/fm-wake-gate.sh"
cp "$ROOT/bin/fm-state-io.py" "$partial/bin/fm-state-io.py"
cat > "$partial/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: stale cached state\n'
exit 7
SH
cat > "$partial/bin/fm-peek.sh" <<'SH'
#!/usr/bin/env bash
printf 'pane: visibly working\n'
SH
chmod +x "$partial/bin/"*.sh
printf '%s\t\n' "$(date +%s)" > "$partial/state/wake-gate/t1.look"
[ "$(FM_STATE_DIR="$partial/state" FM_CONFIG_OVERRIDE="$partial/config" FM_WAKE_GATE_HELPER="$STUB" \
  FM_TEST_ANSWERS="$WORKING" "$partial/bin/fm-wake-gate.sh" stale-verdict t1 w:fm-t1 "$WEDGE" 2>/dev/null)" = escalate ] \
  || fail "SAFETY: one failed evidence read must invalidate the other read"
[ "$(FM_STATE_DIR="$s" FM_CONFIG_OVERRIDE="$s/config" "$GATE" stale-verdict '../x' w "$WEDGE" 2>/dev/null)" = escalate ] \
  || fail "SAFETY: an invalid task id must escalate"
pass "helper errors, non-wedge alarms, missing evidence, and bad ids escalate (fail-open)"

echo "fm-wake-gate: all cases passed"
