#!/usr/bin/env bash
# tests/fm-afk-inject-e2e.test.sh - end-to-end test for the afk daemon's
# injection path into the primary's stream endpoint. It runs the real daemon
# (and its real watcher child) against a fake stream hub and covers three
# operator-visible injection contracts:
#
#   Scenario A (human-partial-input): a partial line sits in the supervisor
#     endpoint's composer with NO Enter, then an escalation fires. The daemon
#     must DEFER (not merge the digest into the human's text). After the human
#     submits, the digest arrives as a separate, clean submission.
#
#   Scenario B (swallowed-Enter): the first Enter the daemon sends is dropped.
#     The daemon must retry Enter (NOT retype the digest) and deliver exactly
#     ONE clean submission: no concatenation, no duplicate.
#
#   Scenario C (normal digest): no human input and no swallowed Enter.
#     A captain-relevant status must deliver exactly ONE sentinel-prefixed,
#     single-line digest with no duplicate or spurious user submission.
#
# Isolation: the supervisor is a fake endpoint on this suite's own fake stream
# hub (tests/fixtures.sh, tests/assets/stream-hub-stub.py), whose composer holds
# typed-but-unsubmitted text and records every submitted line. No deck-chat
# primary is registered (FM_PRIMARY_STEER_BIN names no client), so the daemon
# delivers through the endpoint's typed input - the path whose composer guards
# these scenarios pin. The daemon points at a throwaway state dir
# (FM_STATE_OVERRIDE) and the fake endpoint (FM_SUPERVISOR_TARGET). Nothing
# touches the live fleet, and FM_WEDGE_ALARM_EXEC=discard keeps the executed
# daemon from posting a real notification.
#
# Assert on submitted CONTENT (the hub's record of each submitted line), not
# screen appearance.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"

for tool in python3 jq curl; do
  command -v "$tool" >/dev/null 2>&1 || { echo "skip: $tool not found"; exit 0; }
done

STATE_DIR=
DAEMON_PID=
SUPERVISOR=
SUPERVISOR_LOG=

fail() { printf 'not ok - %s\n' "$1" >&2; cleanup_all; exit 1; }
pass() { printf 'ok - %s\n' "$1"; }

cleanup_all() {
  if [ -n "${DAEMON_PID:-}" ]; then
    afk_exit "${STATE_DIR:-}" 2>/dev/null || true
    kill "$DAEMON_PID" 2>/dev/null || true
    wait "$DAEMON_PID" 2>/dev/null || true
    DAEMON_PID=
  fi
  rm -rf "${STATE_DIR:-}" 2>/dev/null || true
  fm_test_cleanup
}
trap cleanup_all EXIT

# --- setup ------------------------------------------------------------------

STATE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fm-afk-e2e.XXXXXX")
mkdir -p "$STATE_DIR/supervisor"
SUPERVISOR_LOG="$STATE_DIR/supervisor.log"
: > "$SUPERVISOR_LOG"

# Source the daemon to get FM_INJECT_MARK, afk_enter, afk_exit, pane_input_pending.
# shellcheck source=/dev/null
. "$DAEMON"

# The supervisor endpoint: a fake shell whose composer box holds what was typed
# and whose submitted lines the hub records.
SUPERVISOR=$(fm_test_stream_task "$STATE_DIR/supervisor" primary "$SUPERVISOR_LOG" | sed -n 's/^window=//p')
[ -n "$SUPERVISOR" ] || fail "could not register the supervisor endpoint on the fake hub"

# submitted_log: every line the supervisor endpoint received with Enter, as
# "<hex>\t<line>\t<injection|user>" - the classification the captain's harness
# makes from the sentinel marker.
submitted_log() {
  local line hex class
  fm_test_fake_stream_submitted "$SUPERVISOR" | while IFS= read -r line; do
    hex=$(printf '%s' "$line" | od -An -tx1 | tr -d ' \n')
    case "$hex" in e281a3*) class=injection ;; *) class=user ;; esac
    printf '%s\t%s\t%s\n' "$hex" "$line" "$class"
  done
}

# human_types <text> / human_submits: the captain at the keyboard, through the
# hub's own input route, so the text lands in the same composer the daemon reads.
endpoint_input() {  # <json>
  curl -fsS -m 10 -X POST -H 'Content-Type: application/json' -H "Authorization: Bearer $FM_STREAM_TOKEN" \
    --data-binary "$1" "$FM_TEST_STREAM_URL/v1/tasks/${SUPERVISOR##*:}/input" >/dev/null
}
human_types() { endpoint_input "$(jq -nc --arg t "$1" '{text: $t}')"; }
human_submits() { endpoint_input '{"keys": ["Enter"]}'; }

start_daemon() {
  FM_STATE_OVERRIDE="$STATE_DIR" \
  FM_SUPERVISOR_TARGET="$SUPERVISOR" \
  FM_SUPERVISOR_BACKEND=stream \
  FM_PRIMARY_STEER_BIN="$STATE_DIR/no-deck-chat-primary" \
  FM_WEDGE_ALARM_EXEC=discard \
  FM_ESCALATE_BATCH_SECS=0 \
  FM_HOUSEKEEPING_TICK=1 \
  FM_POLL=1 \
  FM_SIGNAL_GRACE=1 \
  FM_HEARTBEAT=999999 \
  FM_CHECK_INTERVAL=999999 \
  FM_INJECT_CONFIRM_SLEEP=0.3 \
  FM_INJECT_CONFIRM_RETRIES=5 \
  FM_STALE_ESCALATE_SECS=999999 \
  nohup "$DAEMON" >"$STATE_DIR/daemon.out" 2>"$STATE_DIR/daemon.err" &
  DAEMON_PID=$!
  # Wait for the daemon to start and acquire the lock.
  local i=0
  while [ "$i" -lt 30 ]; do
    [ -f "$STATE_DIR/.supervise-daemon.pid" ] && break
    sleep 0.2
    i=$((i + 1))
  done
  [ -f "$STATE_DIR/.supervise-daemon.pid" ] || {
    echo "daemon stderr:" >&2; cat "$STATE_DIR/daemon.err" >&2
    fail "daemon did not start (no pid file after 6s)"
  }
}

stop_daemon() {
  [ -n "${DAEMON_PID:-}" ] || return 0
  afk_exit "$STATE_DIR" 2>/dev/null || true
  kill "$DAEMON_PID" 2>/dev/null || true
  wait "$DAEMON_PID" 2>/dev/null || true
  DAEMON_PID=""
  sleep 1
}

# A fresh supervisor endpoint per scenario, so each one's submitted lines stand
# alone; re-registering the label closes the previous scenario's endpoint.
reset_state() {
  rm -f "$STATE_DIR"/*.status \
         "$STATE_DIR"/.subsuper-* \
         "$STATE_DIR"/.wake-queue* \
         "$STATE_DIR"/.watch.lock* \
         "$STATE_DIR"/.watcher-down* \
         "$STATE_DIR"/.last-* \
         "$STATE_DIR"/.hash-* \
         "$STATE_DIR"/.count-* \
         "$STATE_DIR"/.stale-* \
         "$STATE_DIR"/.seen-* \
         "$STATE_DIR"/.heartbeat-streak \
         2>/dev/null || true
  rm -rf "$STATE_DIR/supervisor"
  mkdir -p "$STATE_DIR/supervisor/$1"
  : > "$SUPERVISOR_LOG"
  SUPERVISOR=$(fm_test_stream_task "$STATE_DIR/supervisor/$1" primary "$SUPERVISOR_LOG" | sed -n 's/^window=//p')
  [ -n "$SUPERVISOR" ] || fail "could not register the $1 supervisor endpoint"
}

# --- pane_input_pending environment self-check ------------------------------
# Verify that pane_input_pending (the stream adapter's composer read) detects
# typed text on the fake endpoint. If it can't, the e2e cannot prove the
# operator-visible injection contracts it owns.

wait_for_pane_input_pending() {
  local i=0
  while [ "$i" -lt 30 ]; do
    if pane_input_pending "$SUPERVISOR"; then
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

selfcheck_pane_input_pending() {
  pane_input_pending "$SUPERVISOR" \
    && fail "pane_input_pending self-check: an empty composer already reads pending"
  human_types "selfcheck-marker-12345" || fail "pane_input_pending self-check: could not type into the endpoint"
  if wait_for_pane_input_pending; then
    human_submits
    return 0
  fi
  echo "pane_input_pending cannot detect typed text on the fake endpoint" >&2
  curl -sS -m 10 "$FM_TEST_STREAM_URL/v1/tasks/${SUPERVISOR##*:}/screen" >&2 || true
  fail "pane_input_pending self-check failed"
}

selfcheck_pane_input_pending

# --- Scenario A: human-partial-input ----------------------------------------

test_scenario_a() {
  local log human_line digest_line
  reset_state scenario-a
  afk_enter "$STATE_DIR"
  start_daemon

  # Partial text in the supervisor's composer with NO Enter. This simulates the
  # captain returning and starting to type before afk has been cleared.
  human_types "human draft text" || fail "Scenario A: could not type the human draft"
  wait_for_pane_input_pending \
    || fail "Scenario A: human draft text did not become detectable as pending input"

  # Write a captain-relevant status to trigger a real escalation through the
  # real watcher child.
  echo "done: PR https://example.test/pr/100" > "$STATE_DIR/fake-c1.status"

  # Wait for the watcher to detect the change and the daemon to attempt inject.
  sleep 6

  # Assert: the digest was NOT typed or submitted while the composer had pending input.
  grep -q 'Supervisor escalate' "$SUPERVISOR_LOG" \
    && fail "Scenario A: daemon typed while the composer had pending input (merged with human text?)"
  log=$(submitted_log)
  case "$log" in *'Supervisor escalate'*) fail "Scenario A: daemon injected while the composer had pending input" ;; esac

  # Now the human submits their text (Enter). The composer goes empty.
  human_submits || fail "Scenario A: could not submit the human draft"

  # Wait for the daemon to retry injection (housekeeping tick = 1s).
  sleep 6
  log=$(submitted_log)

  # Assert: human text was submitted alone (as a user message).
  printf '%s\n' "$log" | grep -q 'human draft text' \
    || fail "Scenario A: human text not submitted"

  # Assert: digest arrived after the composer went idle.
  printf '%s\n' "$log" | grep -q 'Supervisor escalate' \
    || fail "Scenario A: digest not injected after the composer went idle"

  # Assert: human text and digest are on SEPARATE lines (never merged).
  if printf '%s\n' "$log" | grep -q 'human draft text.*Supervisor escalate' || \
     printf '%s\n' "$log" | grep -q 'Supervisor escalate.*human draft text'; then
    fail "Scenario A: human text and digest merged into one line"
  fi

  # Assert: the human text line is classified as "user", not "injection".
  human_line=$(printf '%s\n' "$log" | grep 'human draft text' | head -1)
  case "$human_line" in
    *user) ;;
    *) fail "Scenario A: human text misclassified (expected user): $human_line" ;;
  esac

  # Assert: the digest line is classified as "injection".
  digest_line=$(printf '%s\n' "$log" | grep 'Supervisor escalate' | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario A: digest misclassified (expected injection): $digest_line" ;;
  esac

  stop_daemon
  pass "Scenario A: partial input defers injection; digest arrives clean after idle"
}

# --- Scenario B: swallowed-Enter --------------------------------------------

test_scenario_b() {
  local log marker_count digest_line digest_hex user_count typed
  reset_state scenario-b
  afk_enter "$STATE_DIR"

  # Arm the swallow: the endpoint drops the daemon's first Enter.
  fm_test_fake_stream_set "$SUPERVISOR" '{"swallow_keys": ["Enter"]}'

  start_daemon

  # Write a captain-relevant status to trigger a real escalation.
  echo "done: PR https://example.test/pr/200" > "$STATE_DIR/fake-c1.status"

  # Wait for the daemon to process the escalation and attempt inject (with the
  # swallowed Enter, the retry path fires).
  sleep 8
  log=$(submitted_log)

  grep -q '^\[key-swallowed\] Enter$' "$SUPERVISOR_LOG.keys" 2>/dev/null \
    || fail "Scenario B: the endpoint never swallowed an Enter, so this pins nothing"

  # Assert: the digest was typed ONCE (Enter-only retries, never a retype).
  typed=$(grep -c 'Supervisor escalate' "$SUPERVISOR_LOG" || true)
  [ "$typed" -eq 1 ] || fail "Scenario B: digest typed $typed times (expected exactly once)"

  # Assert: exactly ONE terminal-safe marker submitted (no duplicate, no loss).
  marker_count=$(printf '%s\n' "$log" | awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }')
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario B: expected exactly 1 U+2063 marker, got $marker_count (duplicate or lost)"

  # Assert: the digest line is classified as "injection" and starts with the
  # terminal-safe sentinel marker (hex starts with e281a3).
  digest_line=$(printf '%s\n' "$log" | grep 'Supervisor escalate' | head -1)
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario B: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # Assert: no user-message line was submitted (no spurious empty lines from
  # extra Enters).
  user_count=$(printf '%s\n' "$log" | grep -c $'\tuser$' || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario B: expected 0 user lines, got $user_count (spurious Enter submitted empty line?)"

  stop_daemon
  pass "Scenario B: swallowed Enter produces exactly one clean digest"
}

# --- Scenario C: normal status, single clean digest -------------------------
# No human input, no swallowed Enter: a captain-relevant status must produce
# exactly ONE sentinel-prefixed, single-line digest, submitted once. This owns
# the marker + single-line + no-duplicate operator contract.

test_scenario_c() {
  local log marker_count digest_line digest_hex user_count
  reset_state scenario-c
  afk_enter "$STATE_DIR"
  start_daemon

  echo "done: PR https://example.test/pr/300" > "$STATE_DIR/fake-c1.status"
  sleep 6
  log=$(submitted_log)

  # Exactly one terminal-safe marker submitted (no duplicate, no loss).
  marker_count=$(printf '%s\n' "$log" | awk -F '\t' '{ hex=$1; count += gsub(/e281a3/, "", hex) } END { print count + 0 }')
  [ "$marker_count" -eq 1 ] \
    || fail "Scenario C: expected exactly 1 U+2063 marker, got $marker_count"

  # The digest is classified as an injection and starts with the sentinel byte.
  digest_line=$(printf '%s\n' "$log" | grep 'Supervisor escalate' | head -1)
  case "$digest_line" in
    *injection) ;;
    *) fail "Scenario C: digest misclassified (expected injection): $digest_line" ;;
  esac
  digest_hex=$(printf '%s' "$digest_line" | cut -f1)
  case "$digest_hex" in
    e281a3*) ;;
    *) fail "Scenario C: digest does not start with sentinel marker (hex: $digest_hex)" ;;
  esac

  # The digest was submitted as ONE line (a multi-line digest would submit >1
  # line), and no spurious user-classified lines were submitted.
  user_count=$(printf '%s\n' "$log" | grep -c $'\tuser$' || true)
  [ "$user_count" -eq 0 ] \
    || fail "Scenario C: expected 0 user lines, got $user_count (spurious submission?)"

  stop_daemon
  pass "Scenario C: a normal captain status injects exactly one clean single-line sentinel digest"
}

test_scenario_a
test_scenario_b
test_scenario_c

echo "all e2e injection tests passed"
