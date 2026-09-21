#!/usr/bin/env bash
# Behavior tests for the Deck crewmate/scout adapter.
#
# Deck (bastotec/deck) is headless: one `deck run` per turn, NDJSON on stdout.
# bin/fm-deck-worker.sh is the pane-resident driver that makes it a supervised
# worker, so most of what could go wrong is Firstmate's own code and is pinned
# here against a fake deck binary:
#   1. The driver runs the brief as the first turn and every later prompt line
#      as the next turn of the SAME Deck session, with the evidence gate and the
#      progress hook attached to every run.
#   2. It is the task's semantic busy source (deck-wrapper): a turn opens busy
#      and closes idle, a finished turn touches the turn-end notification, and
#      /quit records session-end.
#   3. The evidence gate refuses a turn that appended nothing to the status log
#      and lets one through that did.
#   4. Ctrl+C cancels the running turn and returns to the prompt.
#   5. Pane liveness reads the driver (argv[0] fm-deck-worker) and deck as an
#      agent, never as an idle shell; unrelated names stay unclaimed.
#   6. Control, busy-source, and delivery tables name deck, and a secondmate
#      launch on deck is refused.
#   7. The spawn launches the driver with the resolved deck binary, the task's
#      busy gen, and the model, records effort without passing it, and arms
#      the busy contract.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset CLAUDECODE PI_CODING_AGENT FM_PI_HARNESS GROK_AGENT CURSOR_AGENT CURSOR_INVOKED_AS \
  ATLASSIAN_AGENT_TYPE ROVODEV_CLI GEMINI_CLI AGENT FM_OMP_HARNESS

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"

WORKER="$ROOT/bin/fm-deck-worker.sh"
BUSY_EVENT="$ROOT/bin/fm-busy-event.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-deck-harness)

# A fake deck: logs its argv, honours --session, runs the pre_complete hook the
# way Deck does (exit 2 = refused), and optionally writes a status line or
# sleeps (to be interrupted). Never contacts a model.
make_fake_deck() {  # <dir>
  local dir=$1
  mkdir -p "$dir"
  cat > "$dir/deck" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$0")
printf '%s\n' "$*" >> "$dir/argv.log"
prompt=$2; session=''; gate=''
while [ $# -gt 0 ]; do
  case "$1" in
    --session) session=$2; shift 2 ;;
    --hook) case "$2" in pre_complete=*) gate=${2#pre_complete=} ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$session" ] || session="s-fake-$$"
printf '{"type":"run_started","session":"%s","model":"m"}\n' "$session"
printf '{"type":"text_delta","text":"echo: %s"}\n' "$prompt"
case "$prompt" in
  *write-status*) printf 'done: wrote evidence\n' >> "$FM_TEST_STATUS" ;;
  *sleep*) sleep 30 ;;
esac
if [ -n "$gate" ]; then
  if bash -c "$gate" </dev/null 2>>"$dir/gate.err"; then echo pass >> "$dir/gate.log"; else echo refused >> "$dir/gate.log"; fi
fi
printf '{"type":"run_finished","output":"x","turns":1}\n'
SH
  chmod +x "$dir/deck"
}

# run_worker <case-dir> <input-lines> -> runs the driver to completion
run_worker() {
  local dir=$1 input=$2 gen
  mkdir -p "$dir/state"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  printf '%s' "$gen" > "$dir/gen"
  printf '%s' "$input" | FM_TEST_STATUS="$dir/state/t1.status" \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" --turnend "$dir/state/t1.turn-ended" \
      --deck "$dir/deck" --model codex/gpt-5.6-luna -- "the brief" > "$dir/pane.out" 2>&1
}

test_turns_share_one_session_and_carry_the_hooks() {
  local dir="$TMP_ROOT/session"
  make_fake_deck "$dir"
  run_worker "$dir" $'first\nsecond\n/exit\n/quit\n' || fail "the driver did not exit cleanly on /quit"
  [ "$(wc -l < "$dir/argv.log" | tr -d ' ')" = 4 ] || fail "expected four deck runs (brief + three prompts): $(cat "$dir/argv.log")"
  head -1 "$dir/argv.log" | grep -q -- '--session' && fail "the first turn must start a new Deck session"
  local sid
  sid=$(sed -n 2p "$dir/argv.log" | sed -E 's/.*--session ([^ ]+).*/\1/')
  case "$sid" in s-fake-*) ;; *) fail "the second turn did not resume the first turn's session: $(sed -n 2p "$dir/argv.log")" ;; esac
  sed -n 3p "$dir/argv.log" | grep -q -- "--session $sid" || fail "the third turn changed session"
  sed -n 4p "$dir/argv.log" | grep -q -- "--session $sid" || fail "the fourth turn changed session"
  grep -c -- '--hook pre_complete=' "$dir/argv.log" | grep -qx 4 || fail "every run must carry the evidence gate"
  grep -c -- '--hook post_tool_use=' "$dir/argv.log" | grep -qx 4 || fail "every run must carry the progress hook"
  grep -c -- '--model codex/gpt-5.6-luna' "$dir/argv.log" | grep -qx 4 || fail "every run must carry the model"
  assert_grep 'echo: /exit' "$dir/pane.out" "/exit must be delivered as an ordinary Deck prompt"
  assert_grep 'echo: second' "$dir/pane.out" "the pane did not render the turn's text"
  pass "fm-deck-worker: the brief and later prompts are turns of one Deck session with hooks and model"
}

test_turns_drive_the_busy_record_and_turn_end() {
  local dir="$TMP_ROOT/busy" rec
  make_fake_deck "$dir"
  run_worker "$dir" $'/quit\n' || fail "the driver did not exit cleanly"
  [ -f "$dir/state/t1.turn-ended" ] || fail "a finished turn did not touch the turn-end notification"
  rec=$(cat "$dir/state/t1.busy-state")
  assert_contains "$rec" "source=deck-wrapper" "the busy record was not written by the deck driver"
  assert_contains "$rec" "state=idle" "the busy record did not close idle"
  assert_contains "$rec" "event=session-end" "/quit did not record session-end"
  [ "$(fm_busy_classify tmux fake deck t1 "$dir/state")" = "idle deck-wrapper" ] \
    || fail "busy-lib does not trust the deck driver's record: $(fm_busy_classify tmux fake deck t1 "$dir/state")"
  [ "$(fm_busy_classify tmux fake agy t1 "$dir/state")" = "unknown source-mismatch" ] \
    || fail "the deck driver's record must not classify another adapter"
  pass "fm-deck-worker: turns open and close the deck-wrapper busy record and touch turn-end"
}

test_evidence_gate_refuses_a_turn_without_a_status_line() {
  local dir="$TMP_ROOT/gate"
  make_fake_deck "$dir"
  run_worker "$dir" $'write-status please\n/quit\n' || fail "the driver did not exit cleanly"
  [ "$(sed -n 1p "$dir/gate.log")" = refused ] || fail "a turn that wrote no status line passed the evidence gate"
  [ "$(sed -n 2p "$dir/gate.log")" = pass ] || fail "a turn that appended a status line was refused"
  assert_grep 'append one line to' "$dir/gate.err" "the refusal did not tell the worker what evidence to write"
  pass "fm-deck-worker: the evidence gate refuses a silent turn and passes one that reported"
}

test_ctrl_c_cancels_the_turn_and_returns_to_the_prompt() {
  local dir="$TMP_ROOT/interrupt" gen pid
  make_fake_deck "$dir"
  mkdir -p "$dir/state"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  mkfifo "$dir/in"
  ( exec 3>"$dir/in"; sleep 8 ) &
  # A terminal's Ctrl+C signals the pane's whole foreground process group, so
  # the driver gets a group of its own (job control) and the group is signalled.
  set -m
  FM_TEST_STATUS="$dir/state/t1.status" "$WORKER" --id t1 --state "$dir/state" --gen "$gen" \
    --turnend "$dir/state/t1.turn-ended" --deck "$dir/deck" -- "please sleep" < "$dir/in" > "$dir/pane.out" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 50); do grep -q 'state=busy' "$dir/state/t1.busy-state" 2>/dev/null && pgrep -f "$dir/deck" >/dev/null && break; sleep 0.1; done
  sleep 0.3
  kill -INT -- -"$pid" 2>/dev/null
  for _ in $(seq 50); do grep -q 'event=interrupted' "$dir/state/t1.busy-state" 2>/dev/null && break; sleep 0.1; done
  assert_grep 'event=interrupted' "$dir/state/t1.busy-state" "Ctrl+C did not close the turn as interrupted"
  kill -0 "$pid" 2>/dev/null || fail "the driver exited on Ctrl+C instead of returning to its prompt"
  assert_grep 'Interrupted.' "$dir/pane.out" "the pane did not show the cancelled turn"
  kill -TERM -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  pass "fm-deck-worker: Ctrl+C cancels the running turn and keeps the worker at its prompt"
}

test_liveness_reads_the_driver_as_an_agent() {
  [ "$(fm_agent_process_classify bash fm-deck-worker '')" = agent ] || fail "the driver's argv[0] must read as an agent"
  [ "$(fm_agent_process_classify fm-deck-worker fm-deck-worker '')" = agent ] || fail "the driver's macOS process name must read as an agent"
  [ "$(fm_agent_process_classify deck deck '')" = agent ] || fail "the deck binary must read as an agent"
  [ "$(fm_agent_process_classify decker decker '')" = other ] || fail "an unrelated name containing deck was claimed"
  [ "$(fm_agent_process_classify bash bash '')" = shell ] || fail "a plain shell must still read as a shell"
  pass "liveness: the deck driver and binary are agents, unrelated names are not"
}

test_control_busy_and_delivery_tables_name_deck() {
  fm_control_harness_supported deck || fail "deck is not a supported control harness"
  [ "$(fm_control_harness_family deck)" = deck ] || fail "deck family"
  fm_control_harness_supports_kind deck ship || fail "deck must run ship tasks"
  fm_control_harness_supports_kind deck secondmate && fail "deck must not run a secondmate"
  [ "$(fm_control_interrupt_key deck)" = C-c ] || fail "deck interrupts on Ctrl+C"
  [ "$(fm_control_interrupt_repeat deck)" = 1 ] || fail "deck interrupt repeat"
  [ "$(fm_control_exit_command deck)" = /quit ] || fail "deck exits with /quit"
  fm_busy_source_trusted deck deck-wrapper || fail "busy-lib must trust deck-wrapper for deck"
  fm_busy_source_trusted claude deck-wrapper && fail "deck-wrapper must not be trusted for claude"
  printf '⛵ deck working - ctrl+c to stop\n' | fm_busy_lines_match deck || fail "the driver's working line must acknowledge delivery"
  printf 'echo: deck working on it\n' | fm_busy_lines_match deck && fail "free text must not acknowledge delivery"
  pass "control, busy-source, and delivery tables carry deck's verified mechanics"
}

# --- spawn ------------------------------------------------------------------
make_deck_spawn_case() {  # <name> <id> -> "<case>|<home>|<proj>|<wt>|<fakebin>"
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"; home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  fakebin=$(fm_fakebin "$case_dir/fake")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "$FM_FAKE_PANE_PATH"; exit 0 ;;
  *"#{cursor_y}"*) printf '1\n'; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    prev=; for arg in "$@"; do [ "$prev" = -l ] && printf '%s\n' "$arg" >> "$FM_FAKE_LAUNCH_LOG"; prev=$arg; done
    exit 0 ;;
  capture-pane) printf '⛵ deck working - ctrl+c to stop\n'; exit 0 ;;
esac
exit 0
SH
  printf '#!/usr/bin/env bash\necho "fake deck must never execute" >&2; exit 9\n' > "$fakebin/deck"
  chmod +x "$fakebin/tmux" "$fakebin/deck"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '# Task\n## Captain'"'"'s intent\nExercise Deck dispatch.\n\n## Firstmate spec\nVerify launch.\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"; : > "$case_dir/tmux-calls.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

JQ_DIR=$(dirname "$(command -v jq)")
run_deck_spawn() {  # <case> <home> <proj> <wt> <fakebin> <id> [args...]
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" TMUX="fake,1,0" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" FM_FAKE_TMUX_CALL_LOG="$case_dir/tmux-calls.log" \
    PATH="$fakebin:$JQ_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$proj" --harness deck --mode no-mistakes --yolo off "$@" 2>&1
}

test_spawn_launches_the_driver_with_binary_gen_and_model() {
  local id rec out rc launch meta case_dir home proj wt fakebin
  id="deck-launch-$$"
  rec=$(make_deck_spawn_case launch "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_deck_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" --model codex/gpt-5.6-luna --effort high)
  rc=$?
  expect_code 0 "$rc" "deck spawn should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" "exec -a fm-deck-worker bash" "the driver must run under its own argv[0]"
  assert_contains "$launch" "$ROOT/bin/fm-deck-worker.sh" "the launch did not run the deck driver"
  assert_contains "$launch" "--deck '$fakebin/deck'" "the launch did not pin the resolved deck binary"
  assert_contains "$launch" "--model 'codex/gpt-5.6-luna'" "the launch did not carry the model"
  assert_contains "$launch" "--id '$id'" "the launch did not name the task"
  assert_not_contains "$launch" "--effort" "deck has no effort control; effort must not be passed"
  assert_not_contains "$launch" "__DECK" "the launch left a deck placeholder unsubstituted"
  meta="$home/state/$id.meta"
  assert_grep 'harness=deck' "$meta" "meta did not record the deck harness"
  assert_grep 'effort=high' "$meta" "meta did not record the requested effort"
  [ -s "$home/state/$id.busy-gen" ] || fail "the spawn did not arm the busy contract"
  assert_contains "$launch" "--gen '$(cat "$home/state/$id.busy-gen")'" "the launch did not carry the armed busy gen"
  pass "fm-spawn: deck launches the driver with the binary, busy gen, and model; effort recorded only"
}

test_spawn_refuses_a_deck_secondmate() {
  local out rc
  out=$(HOME="$TMP_ROOT" FM_HOME="$TMP_ROOT" FM_STATE_OVERRIDE="$TMP_ROOT/sm-state" FM_CONFIG_OVERRIDE="$TMP_ROOT/sm-config" \
    "$SPAWN" deck-sm-$$ "$TMP_ROOT" --secondmate --harness deck 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "a deck secondmate launch must be refused"
  assert_contains "$out" "crewmate/scout adapter only" "the refusal must say why"
  pass "fm-spawn: a secondmate on deck is refused"
}

test_turns_share_one_session_and_carry_the_hooks
test_turns_drive_the_busy_record_and_turn_end
test_evidence_gate_refuses_a_turn_without_a_status_line
test_ctrl_c_cancels_the_turn_and_returns_to_the_prompt
test_liveness_reads_the_driver_as_an_agent
test_control_busy_and_delivery_tables_name_deck
test_spawn_launches_the_driver_with_binary_gen_and_model
test_spawn_refuses_a_deck_secondmate
echo "fm-deck-harness: all cases passed"
