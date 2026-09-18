#!/usr/bin/env bash
# tests/fm-ask-triage.test.sh - the optional possible-ask pass (bin/fm-ask-triage.sh)
# ranks politely-phrased asks in working: status lines and never hides anything.
# Every case uses synthetic lines and a stub in place of the model call, so the
# suite never reaches the network. It pins: only working: lines are ever sent or
# flagged; the drain's output with flags is its output without them plus a
# POSSIBLE ASKS section; the drain never runs the scorer; every failure mode
# (no key, no runtime, timeout, error, bad output, low probability) leaves the
# view exactly as today; and the watcher starts the scorer without waiting on it.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TRIAGE="$ROOT/bin/fm-ask-triage.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"

TMP_ROOT=$(fm_test_tmproot fm-ask-triage-tests)

# A stub helper with the real helper's contract: it reads the input file named by
# its first argument, logs each line it was sent, and answers per FM_TEST_STUB_MODE.
make_stub() {  # <dir> -> stub path
  local stub="$1/stub-helper"
  cat > "$stub" <<'SH'
#!/usr/bin/env bash
set -u
input=$1
cat "$input" >> "${FM_TEST_STUB_LOG:?}"
n=$(grep -c . "$input")
case "${FM_TEST_STUB_MODE:-say-so}" in
  sleep) sleep 5; exit 0 ;;
  error) printf 'error\tno-key\n'; exit 3 ;;
  garbage) printf 'this is not the protocol\n'; exit 0 ;;
esac
printf 'usage\t%s\t%s\t0\t7\n' "$n" "$((n * 390))"
while IFS= read -r line; do
  case "${FM_TEST_STUB_MODE:-say-so}" in
    all-high) printf '0.9900\n' ;;
    dash) printf -- '-\n' ;;
    low) printf '0.6000\n' ;;
    *) case "$line" in *"say so"*) printf '0.9300\n' ;; *) printf '0.0400\n' ;; esac ;;
  esac
done < "$input"
SH
  chmod +x "$stub"
  printf '%s\n' "$stub"
}

new_case() {  # <name> -> case dir with state/, a secrets file, and a stub
  local dir
  dir=$(make_case "$1")
  printf 'export FM_TEST_GATEWAY_KEY=synthetic-not-a-key\n' > "$dir/secrets"
  make_stub "$dir" >/dev/null
  : > "$dir/sent.log"
  printf '%s\n' "$dir"
}

triage() {  # <dir> <command> [env...]
  local dir=$1 cmd=$2
  shift 2
  env FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_ASK_TRIAGE_SECRETS="$dir/secrets" FM_ASK_TRIAGE_KEY_VAR=FM_TEST_GATEWAY_KEY \
    FM_ASK_TRIAGE_HELPER="$dir/stub-helper" FM_TEST_STUB_LOG="$dir/sent.log" \
    "$@" "$TRIAGE" "$cmd"
}

drain() {  # <dir> <out>
  FM_STATE_OVERRIDE="$1/state" "$DRAIN" > "$2" 2>/dev/null
}

pending_count() {  # <dir>
  find "$1/state/ask-triage/pending" -name '*.flag' 2>/dev/null | wc -l | tr -d ' '
}

every_verb_log() {  # <status-file>
  {
    printf 'working: rebased onto main; if you would rather keep the old flag, say so\n'
    printf 'done: shipped; if you would rather keep the old flag, say so\n'
    printf 'failed: build broke; if you would rather keep the old flag, say so\n'
    printf 'needs-decision [key=q1]: pick one; if you would rather keep the old flag, say so\n'
    printf 'blocked: stuck; if you would rather keep the old flag, say so\n'
    printf 'resolved [key=q1]: answered; if you would rather keep the old flag, say so\n'
    printf 'paused: upstream release; if you would rather keep the old flag, say so\n'
    printf 'note: fyi; if you would rather keep the old flag, say so\n'
    printf 'working: tests pass, opening the PR next\n'
  } > "$1"
}

test_only_working_lines_are_sent_or_flagged() {
  local dir
  dir=$(new_case scope)
  every_verb_log "$dir/state/t1.status"
  triage "$dir" score FM_TEST_STUB_MODE=all-high || fail "score exited nonzero"
  [ "$(grep -c . "$dir/sent.log")" -eq 2 ] \
    || fail "expected exactly the two working: lines to be sent, got: $(cat "$dir/sent.log")"
  if grep -v '^working: ' "$dir/sent.log" >/dev/null; then
    fail "a non-working line reached the model: $(cat "$dir/sent.log")"
  fi
  [ "$(pending_count "$dir")" -eq 2 ] || fail "expected two flags, got $(pending_count "$dir")"
  if cat "$dir/state/ask-triage/pending"/*.flag | cut -f3 | grep -v '^working: ' >/dev/null; then
    fail "a non-working line was flagged"
  fi
  pass "only working: lines are sent or flagged, even when every line reads like an ask"
}

test_drain_adds_a_section_and_hides_nothing() {
  local plain flagged
  plain=$(new_case plain)
  flagged=$(new_case flagged)
  every_verb_log "$plain/state/t1.status"
  every_verb_log "$flagged/state/t1.status"
  append_wake "$plain/state" signal t1.status "signal: t1.status" || fail "queueing the plain wake failed"
  append_wake "$flagged/state" signal t1.status "signal: t1.status" || fail "queueing the flagged wake failed"
  triage "$flagged" score || fail "score exited nonzero"
  [ "$(pending_count "$flagged")" -eq 1 ] || fail "expected one flag, got $(pending_count "$flagged")"

  drain "$plain" "$plain/drain.out" || fail "plain drain failed"
  drain "$flagged" "$flagged/drain.out" || fail "flagged drain failed"
  sed "s#$plain/#CASE/#g" "$plain/drain.out" > "$plain/drain.norm"
  sed "s#$flagged/#CASE/#g" "$flagged/drain.out" > "$flagged/drain.norm"
  grep -F 'signal: t1.status' "$plain/drain.norm" >/dev/null || fail "setup error: the plain drain showed no wake: $(cat "$plain/drain.norm")"
  while IFS= read -r line; do
    grep -Fx -- "$line" "$flagged/drain.norm" >/dev/null \
      || fail "a line the drain shows today was missing once a flag existed: $line"
  done < "$plain/drain.norm"
  grep -F 'POSSIBLE ASKS' "$flagged/drain.norm" >/dev/null \
    || fail "the flagged drain printed no POSSIBLE ASKS section: $(cat "$flagged/drain.norm")"
  grep -Fx 't1 [p=0.9300] working: rebased onto main; if you would rather keep the old flag, say so' \
    "$flagged/drain.norm" >/dev/null || fail "the flagged line was not pointed at: $(cat "$flagged/drain.norm")"
  [ "$(grep -c 'POSSIBLE ASKS' "$plain/drain.norm")" -eq 0 ] || fail "an unscored drain printed POSSIBLE ASKS"
  [ "$(($(wc -l < "$flagged/drain.norm") - $(wc -l < "$plain/drain.norm")))" -eq 2 ] \
    || fail "the flag changed more than the added section: $(diff "$plain/drain.norm" "$flagged/drain.norm")"
  pass "a flag only adds a POSSIBLE ASKS section; every line the drain showed is still shown"
}

test_possible_asks_print_once() {
  local dir
  dir=$(new_case once)
  printf 'working: a choice from you when convenient; if you would rather wait, say so\n' > "$dir/state/t2.status"
  triage "$dir" score || fail "score exited nonzero"
  drain "$dir" "$dir/first.out" || fail "first drain failed"
  grep -F 'POSSIBLE ASKS' "$dir/first.out" >/dev/null || fail "first drain did not present the flag"
  drain "$dir" "$dir/second.out" || fail "second drain failed"
  if grep -F 'POSSIBLE ASKS' "$dir/second.out" >/dev/null; then
    fail "an already-presented flag was presented again: $(cat "$dir/second.out")"
  fi
  triage "$dir" score || fail "rescore exited nonzero"
  [ "$(pending_count "$dir")" -eq 0 ] || fail "a rescore raised an already-scored line again"
  pass "a possible ask is presented once and a rescore does not raise it again"
}

test_drain_never_runs_the_scorer() {
  local dir
  dir=$(new_case drain-offline)
  printf 'working: tests pass; if you would rather squash, say so\n' > "$dir/state/t3.status"
  append_wake "$dir/state" signal t3.status "signal: t3.status" || fail "queueing the wake failed"
  FM_STATE_OVERRIDE="$dir/state" FM_ASK_TRIAGE_SECRETS="$dir/secrets" FM_ASK_TRIAGE_KEY_VAR=FM_TEST_GATEWAY_KEY \
    FM_ASK_TRIAGE_HELPER="$dir/stub-helper" FM_TEST_STUB_LOG="$dir/sent.log" FM_TEST_STUB_MODE=sleep \
    "$DRAIN" > "$dir/drain.out" 2>/dev/null || fail "drain failed"
  [ ! -s "$dir/sent.log" ] || fail "the drain called the model: $(cat "$dir/sent.log")"
  grep -F 'working: tests pass; if you would rather squash, say so' "$dir/drain.out" >/dev/null \
    || fail "the unscored line was not shown as today: $(cat "$dir/drain.out")"
  pass "the drain never calls the model; an unscored line is shown exactly as today"
}

test_failures_leave_the_view_unchanged() {
  local dir mode
  for mode in sleep error garbage dash low; do
    dir=$(new_case "failure-$mode")
    printf 'working: if you would rather I stop here, say so\n' > "$dir/state/t4.status"
    triage "$dir" score FM_TEST_STUB_MODE="$mode" FM_ASK_TRIAGE_TIMEOUT=1 \
      || fail "score exited nonzero on $mode"
    [ "$(pending_count "$dir")" -eq 0 ] || fail "a $mode result produced a flag"
    drain "$dir" "$dir/drain.out" || fail "drain after $mode failed"
    if grep -F 'POSSIBLE ASKS' "$dir/drain.out" >/dev/null; then fail "a $mode result was presented"; fi
  done
  grep -q "$(printf '\ttimeout$')" "$(dirname "$dir")/failure-sleep/state/ask-triage/usage.log" \
    || fail "a timed-out call was not recorded as a timeout"
  pass "timeout, error, bad output, a failed line, and low probability all leave the line unflagged"
}

test_inert_without_key_or_runtime() {
  local dir bin
  dir=$(new_case no-key)
  printf 'working: if you would rather keep it, say so\n' > "$dir/state/t5.status"
  triage "$dir" score FM_ASK_TRIAGE_KEY_VAR=FM_TEST_ABSENT_KEY > "$dir/score.out" 2>&1 \
    || fail "score without a key exited nonzero"
  [ ! -s "$dir/score.out" ] || fail "score without a key made noise: $(cat "$dir/score.out")"
  [ ! -s "$dir/sent.log" ] || fail "score without a key called the model"
  [ ! -e "$dir/state/ask-triage" ] || fail "score without a key wrote state"

  # No key setting at all is inert even when the secrets file holds a key.
  dir=$(new_case no-key-setting)
  printf 'working: if you would rather keep it, say so\n' > "$dir/state/t5.status"
  printf 'export AI_GATEWAY_API_KEY=synthetic-not-a-key\n' >> "$dir/secrets"
  env -u FM_ASK_TRIAGE_KEY_VAR FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_ASK_TRIAGE_SECRETS="$dir/secrets" FM_ASK_TRIAGE_HELPER="$dir/stub-helper" FM_TEST_STUB_LOG="$dir/sent.log" \
    "$TRIAGE" score > "$dir/score.out" 2>&1 || fail "score without a key setting exited nonzero"
  [ ! -s "$dir/sent.log" ] || fail "score without a key setting called the model"
  [ ! -e "$dir/state/ask-triage" ] || fail "score without a key setting wrote state"
  mkdir -p "$dir/config"
  printf 'FM_TEST_GATEWAY_KEY\n' > "$dir/config/ask-triage-key-var"
  env -u FM_ASK_TRIAGE_KEY_VAR FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_ASK_TRIAGE_SECRETS="$dir/secrets" FM_ASK_TRIAGE_HELPER="$dir/stub-helper" FM_TEST_STUB_LOG="$dir/sent.log" \
    "$TRIAGE" score || fail "score with a configured key name exited nonzero"
  [ -s "$dir/sent.log" ] || fail "the configured key name did not enable the pass"

  dir=$(new_case no-runtime)
  printf 'working: if you would rather keep it, say so\n' > "$dir/state/t5.status"
  bin="$dir/bin"
  mkdir -p "$bin"
  cp "$ROOT/bin/fm-ask-triage.sh" "$ROOT/bin/fm-classify-lib.sh" "$ROOT/bin/fm-timeout-lib.sh" "$bin/"
  env FM_STATE_OVERRIDE="$dir/state" FM_ASK_TRIAGE_SECRETS="$dir/secrets" FM_ASK_TRIAGE_KEY_VAR=FM_TEST_GATEWAY_KEY \
    "$bin/fm-ask-triage.sh" score > "$dir/score.out" 2>&1 || fail "score without the runtime exited nonzero"
  [ ! -s "$dir/score.out" ] || fail "score without the runtime made noise: $(cat "$dir/score.out")"
  [ ! -e "$dir/state/ask-triage" ] || fail "score without the runtime wrote state"
  pass "with no key or no runtime the pass does nothing and says nothing"
}

test_scores_only_unpresented_complete_lines() {
  local dir
  dir=$(new_case cursor)
  printf 'working: an old line already shown; if you would rather, say so\n' > "$dir/state/t6.status"
  append_wake "$dir/state" signal t6.status "signal: t6.status" || fail "queueing the priming wake failed"
  drain "$dir" "$dir/prime.out" || fail "priming drain failed"
  grep -F 'an old line already shown' "$dir/prime.out" >/dev/null || fail "setup error: the old line was not presented"
  printf 'working: a new line; if you would rather, say so\nworking: half-writ' >> "$dir/state/t6.status"
  triage "$dir" score || fail "score exited nonzero"
  [ "$(cat "$dir/sent.log")" = 'working: a new line; if you would rather, say so' ] \
    || fail "expected only the new complete line to be sent, got: $(cat "$dir/sent.log")"
  printf 'ten line, say so\n' >> "$dir/state/t6.status"
  : > "$dir/sent.log"
  triage "$dir" score || fail "second score exited nonzero"
  [ "$(cat "$dir/sent.log")" = 'working: half-written line, say so' ] \
    || fail "the completed line was not scored whole: $(cat "$dir/sent.log")"
  pass "the scorer starts at the drain's presentation point and reads only complete lines"
}

test_held_while_away_daemon_owns_the_drain() {
  local dir
  dir=$(new_case away)
  printf 'working: if you would rather pause, say so\n' > "$dir/state/t7.status"
  triage "$dir" score || fail "score exited nonzero"
  printf 'away\n' > "$dir/state/.afk"
  triage "$dir" present > "$dir/away.out" || fail "present while away failed"
  [ ! -s "$dir/away.out" ] || fail "a flag was spent while away: $(cat "$dir/away.out")"
  [ "$(pending_count "$dir")" -eq 1 ] || fail "the flag did not survive the away window"
  rm -f "$dir/state/.afk"
  triage "$dir" present > "$dir/back.out" || fail "present after return failed"
  grep -F 'POSSIBLE ASKS' "$dir/back.out" >/dev/null || fail "the held flag was not presented after return"
  pass "flags are held while the away daemon owns the drain and shown on return"
}

test_watcher_starts_the_scorer_without_waiting() {
  local dir state fakebin out pid started ended
  dir=$(new_case watcher)
  state="$dir/state"; fakebin="$dir/fakebin"; out="$dir/watch.out"
  printf 'done: shipped the fix\n' > "$state/t8.status"
  printf 'working: if you would rather squash, say so\n' >> "$state/t8.status"
  started=$(date +%s)
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_ASK_TRIAGE_SECRETS="$dir/secrets" FM_ASK_TRIAGE_KEY_VAR=FM_TEST_GATEWAY_KEY \
    FM_ASK_TRIAGE_HELPER="$dir/stub-helper" FM_TEST_STUB_LOG="$dir/sent.log" FM_TEST_STUB_MODE=sleep \
    FM_ASK_TRIAGE_TIMEOUT=8 "$WATCH" > "$out" &
  pid=$!
  wait_for_exit "$pid" 100 || fail "watcher did not surface the done: signal"
  ended=$(date +%s)
  grep -F "signal: $state/t8.status" "$out" >/dev/null || fail "watcher did not surface the signal: $(cat "$out")"
  [ $((ended - started)) -lt 5 ] || fail "the watcher waited on the slow scorer ($((ended - started))s)"
  wait_file_nonempty "$dir/sent.log" 50 || fail "the watcher did not start the scorer"
  grep -Fx 'working: if you would rather squash, say so' "$dir/sent.log" >/dev/null \
    || fail "the scorer was not sent the working: line: $(cat "$dir/sent.log")"
  pass "the watcher starts the scorer at signal time and never waits on it"
}

wait_file_nonempty() {  # <file> <ticks>
  local i=0
  while [ "$i" -lt "$2" ]; do
    [ -s "$1" ] && return 0
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

test_only_working_lines_are_sent_or_flagged
test_drain_adds_a_section_and_hides_nothing
test_possible_asks_print_once
test_drain_never_runs_the_scorer
test_failures_leave_the_view_unchanged
test_inert_without_key_or_runtime
test_scores_only_unpresented_complete_lines
test_held_while_away_daemon_owns_the_drain
test_watcher_starts_the_scorer_without_waiting
