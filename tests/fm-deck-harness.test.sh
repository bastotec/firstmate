#!/usr/bin/env bash
# Behavior tests for the Deck crewmate/scout adapter.
#
# Deck (bastotec/deck) is headless: one `deck run` per turn, NDJSON on stdout.
# bin/fm-deck-worker.sh is the pane-resident driver that makes it a supervised
# worker, so most of what could go wrong is Firstmate's own code and is pinned
# here against a fake deck binary:
#   1. The driver runs the brief as the first turn and every later prompt line
#      as the next turn of the SAME Deck session, with the evidence gate and the
#      progress hook attached to every run, plus the home's config/deck-mcp.json
#      as `--mcp-config` unless FM_DECK_MCP_CONFIG overrides or disables it.
#   2. It is the task's semantic busy source (deck-wrapper): a turn opens busy
#      and closes idle, a finished turn touches the turn-end notification, and
#      /quit records session-end.
#   3. The evidence gate refuses a turn without a worker-status line and lets
#      one through that has one, while the driver gives every completed,
#      failed, or interrupted turn a status line before its turn-end signal.
#   4. Ctrl+C cancels the running turn and returns to the prompt.
#   5. Endpoint liveness reads the driver (argv[0] fm-deck-worker) and deck as
#      an agent, never as an idle shell; unrelated names stay unclaimed, and
#      stale busy records never stand in for an absent driver.
#   6. Control, busy-source, and delivery tables name deck, and a secondmate
#      launches use the same driver with home-host supervision. A persistent
#      secondmate records a failed turn and returns to its prompt with its
#      session and watcher intact, on the first turn as well as later ones,
#      repeats its launch brief once when a failure left it with no session at
#      all, and stops when that repeat opens no session either, while a crewmate
#      keeps its own behavior and a failure the driver cannot publish still
#      stops it.
#   7. Ordinary Deck dispatch launches the driver with the resolved deck
#      binary, busy gen, and model, records effort without passing it, and arms
#      the busy contract.
#   8. A ship worker whose turn ends while its no-mistakes run is still working
#      gets exactly one next turn, naming the run id and state, when the run
#      leaves working; a run that stays parked never re-wakes, typed input is
#      still taken immediately while the driver waits, and the wait is bounded.
set -u

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh" || exit 1

unset FM_DECK_MCP_CONFIG FM_CONFIG_OVERRIDE

# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-busy-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-composer-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-agent-process-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source stream || fail "could not load the stream backend"

WORKER=${FM_TEST_DECK_WORKER:-"$ROOT/bin/fm-deck-worker.sh"}
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
python3 - "$dir/argv.jsonl" "$@" <<'PYTHON'
import json, sys
with open(sys.argv[1], 'a') as output:
    output.write(json.dumps(sys.argv[2:]) + '\n')
PYTHON
prompt=$2; session=''; gate=''; progress=''; pre_tool=''
while [ $# -gt 0 ]; do
  case "$1" in
    --session) session=$2; shift 2 ;;
    --hook) case "$2" in pre_complete=*) gate=${2#pre_complete=} ;; pre_tool_use=*) pre_tool=${2#pre_tool_use=} ;; post_tool_use=*) progress=${2#post_tool_use=} ;; esac; shift 2 ;;
    *) shift ;;
  esac
done
[ -n "$session" ] || session="s-fake-$$"
case "$prompt" in *slow*) sleep 0.8 ;; esac
printf '{"type":"run_started","session":"%s","model":"m"}\n' "$session"
printf '{"type":"text_delta","text":"echo: %s"}\n' "$prompt"
[ -z "$pre_tool" ] || printf '%s' "${FM_TEST_HOOK_EVENT:-}" | bash -c "$pre_tool" || true
[ -z "${FM_TEST_TOOL_COMMAND:-}" ] || bash -c "$FM_TEST_TOOL_COMMAND" || exit 1
case "$prompt" in
  *replace-status*)
    rm -f -- "$FM_TEST_STATUS"
    ln -s "$FM_TEST_EXTERNAL" "$FM_TEST_STATUS"
    ;;
  *write-status*replace-busy-gen*)
    printf 'done: wrote evidence\n' >> "$FM_TEST_STATUS"
    "$FM_TEST_BUSY_EVENT" arm "$(dirname "$FM_TEST_STATUS")" t1 >/dev/null
    ;;
  *legacy-finish-write-status*) printf 'done: wrote evidence\n' >> "$FM_TEST_STATUS" ;;
  *write-status*|*'changed state while this session was idle'*) printf 'done: wrote evidence\n' >> "$FM_TEST_STATUS" ;;
  *resolve-only*) printf 'resolved [key=choice]: answered: yes\n' >> "$FM_TEST_STATUS" ;;
  *sleep*)
    bash -c 'printf "%s\n" "$$" > "$1/interrupt-ready"; exec sleep 30' _ "$dir"
    ;;
esac
[ -z "$progress" ] || printf '%s' "${FM_TEST_HOOK_EVENT:-}" | bash -c "$progress" || true
if [ -n "$gate" ]; then
  if bash -c "$gate" </dev/null 2>>"$dir/gate.err"; then
    echo pass >> "$dir/gate.log"
  else
    echo refused >> "$dir/gate.log"
    printf 'pre_complete hook rejected completion\n' >&2
    printf '{"type":"completion_blocked","attempt":1,"reason":"status evidence required"}\n'
    case "$prompt" in
      *recover-after-refusal*)
        printf 'done: recovered after refusal\n' >> "$FM_TEST_STATUS"
        if bash -c "$gate" </dev/null 2>>"$dir/gate.err"; then echo pass >> "$dir/gate.log"; fi
        ;;
    esac
  fi
fi
case "$prompt" in
  *fail-turn*) printf '{"type":"run_failed","error":"provider failed"}\n'; exit 9 ;;
  *legacy-finish*) printf '{"type":"run_finished","output":"x","turns":1}\n' ;;
  *) printf '{"type":"run_finished","output":"x","turns":1,"finished_at":1790269292}\n' ;;
esac
SH
  chmod +x "$dir/deck"
}

# run_worker <case-dir> <input-lines> [first-prompt] -> runs the driver to completion
run_worker() {
  local dir=$1 input=$2 prompt=${3:-the brief} gen
  mkdir -p "$dir/state"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  printf '%s' "$gen" > "$dir/gen"
  printf '%s' "$input" | FM_TEST_STATUS="$dir/state/t1.status" FM_TEST_EXTERNAL="${FM_TEST_EXTERNAL:-}" \
    FM_TEST_BUSY_EVENT="$BUSY_EVENT" \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" \
      --deck "$dir/deck" --model codex/gpt-5.6-luna -- "$prompt" > "$dir/pane.out" 2>&1
}

test_turns_share_one_session_and_carry_the_hooks() {
  local dir="$TMP_ROOT/session"
  make_fake_deck "$dir"
  run_worker "$dir" $'first\nsecond\n/exit\n/quit\n' || fail "the driver did not exit cleanly on /quit: $(cat "$dir/pane.out")"
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

test_turns_carry_the_home_mcp_config() {
  local dir="$TMP_ROOT/mcp" home
  home="$dir/home"
  mkdir -p "$home/config"
  printf '{"servers":{}}\n' > "$home/config/deck-mcp.json"
  make_fake_deck "$dir/present"
  FM_HOME="$home" run_worker "$dir/present" $'next\n/quit\n' \
    || fail "the driver did not exit cleanly with a home MCP config"
  grep -c -- "--mcp-config $home/config/deck-mcp.json" "$dir/present/argv.log" | grep -qx 2 \
    || fail "every turn must carry the home's deck-mcp.json: $(cat "$dir/present/argv.log")"
  make_fake_deck "$dir/absent"
  FM_HOME="$dir/absent" run_worker "$dir/absent" $'/quit\n' \
    || fail "the driver did not exit cleanly without a home MCP config"
  assert_not_contains "$(cat "$dir/absent/argv.log")" '--mcp-config' "a home without deck-mcp.json passed --mcp-config"
  make_fake_deck "$dir/override"
  FM_HOME="$home" FM_DECK_MCP_CONFIG="$dir/other.json" run_worker "$dir/override" $'/quit\n' \
    || fail "the driver did not exit cleanly with an MCP config override"
  assert_grep "--mcp-config $dir/other.json" "$dir/override/argv.log" "FM_DECK_MCP_CONFIG did not override the home file"
  make_fake_deck "$dir/disabled"
  FM_HOME="$home" FM_DECK_MCP_CONFIG='' run_worker "$dir/disabled" $'/quit\n' \
    || fail "the driver did not exit cleanly with MCP disabled"
  assert_not_contains "$(cat "$dir/disabled/argv.log")" '--mcp-config' "an empty FM_DECK_MCP_CONFIG did not disable MCP"
  # Inspect the argv protocol, not the implementation, including argument
  # boundaries when the explicit path contains spaces and does not exist.
  make_fake_deck "$dir/spaced"
  FM_HOME="$home" FM_DECK_MCP_CONFIG='relative missing config.json' run_worker "$dir/spaced" $'next\n/quit\n' \
    || fail "the driver did not exit cleanly with a spaced relative override"
  python3 - "$dir" <<'PYTHON' || fail "MCP argv boundaries or precedence changed"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
expected = {'present': str(root / 'home/config/deck-mcp.json'),
            'absent': None, 'override': str(root / 'other.json'),
            'disabled': None, 'spaced': 'relative missing config.json'}
for case, path in expected.items():
    rows = [json.loads(line) for line in (root / case / 'argv.jsonl').read_text().splitlines()]
    for args in rows:
        values = [args[i + 1] for i, arg in enumerate(args) if arg == '--mcp-config']
        assert values == ([] if path is None else [path]), (case, values, path)
        print(json.dumps({'case': case, 'mcp_config_arguments': values}))
PYTHON
  pass "fm-deck-worker: every turn carries the home's deck-mcp.json unless FM_DECK_MCP_CONFIG overrides or disables it"
}

test_mcp_config_directory_precedence_and_scout_scope() {
  local dir="$TMP_ROOT/mcp-resolution" home config code variant
  home="$dir/home"; config="$dir/custom config"; code="$dir/code"
  mkdir -p "$home/config" "$config" "$code/bin" "$code/config"
  printf '{"servers":{}}\n' > "$home/config/deck-mcp.json"
  printf '{"servers":{}}\n' > "$config/deck-mcp.json"
  printf '{"servers":{}}\n' > "$code/config/deck-mcp.json"
  cp -R "$ROOT/bin/." "$code/bin/"
  for variant in config-dir missing-config-dir empty-config-dir code-root scout; do
    make_fake_deck "$dir/$variant"
  done
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$config" run_worker "$dir/config-dir" $'next\n/quit\n' \
    || fail "FM_CONFIG_OVERRIDE launch failed"
  FM_HOME="$home" FM_CONFIG_OVERRIDE="$dir/missing" run_worker "$dir/missing-config-dir" $'/quit\n' \
    || fail "missing FM_CONFIG_OVERRIDE launch failed"
  FM_HOME="$home" FM_CONFIG_OVERRIDE='' run_worker "$dir/empty-config-dir" $'/quit\n' \
    || fail "empty FM_CONFIG_OVERRIDE launch failed"
  (unset FM_HOME FM_CONFIG_OVERRIDE; WORKER="$code/bin/fm-deck-worker.sh" run_worker "$dir/code-root" $'/quit\n') \
    || fail "code-root fallback launch failed"
  mkdir -p "$dir/scout/state"
  fm_write_meta "$dir/scout/state/t1.meta" "kind=scout"
  FM_HOME="$home" run_worker "$dir/scout" $'next\n/quit\n' \
    || fail "scout with its own home MCP config failed"
  python3 - "$dir" <<'PYTHON' || fail "MCP config directory resolution changed"
import json, pathlib, sys
root = pathlib.Path(sys.argv[1])
expected = {'config-dir': str(root / 'custom config/deck-mcp.json'),
            'missing-config-dir': None,
            'empty-config-dir': str(root / 'home/config/deck-mcp.json'),
            'code-root': str(root / 'code/config/deck-mcp.json'),
            'scout': str(root / 'home/config/deck-mcp.json')}
for case, path in expected.items():
    rows = [json.loads(line) for line in (root / case / 'argv.jsonl').read_text().splitlines()]
    assert len(rows) == (2 if case in ['config-dir', 'scout'] else 1), case
    for args in rows:
        values = [args[i + 1] for i, arg in enumerate(args) if arg == '--mcp-config']
        assert values == ([] if path is None else [path]), (case, values, path)
        print(json.dumps({'case': case, 'mcp_config_arguments': values}))
PYTHON
  pass "Deck MCP config follows config override, home, and code-root precedence for workers and scouts"
}

test_mcp_config_is_not_inherited_into_secondmate_homes() (
  local dir="$TMP_ROOT/mcp-inheritance" src home
  src="$dir/primary/config"; home="$dir/secondmate"
  mkdir -p "$src" "$home/config"
  git init -q "$home" || fail "could not initialize the secondmate config fixture"
  printf 'config/\n' > "$home/.gitignore"
  printf 'deck\n' > "$src/crew-harness"
  printf '{"servers":{"primary-only":{}}}\n' > "$src/deck-mcp.json"
  unset FM_INHERITABLE_CONFIG
  # shellcheck source=bin/fm-config-inherit-lib.sh
  . "$ROOT/bin/fm-config-inherit-lib.sh"
  propagate_inheritable_config "$src" "$home/config" || fail "config propagation failed"
  [ -f "$home/config/crew-harness" ] || fail "the shared config did not propagate"
  [ ! -e "$home/config/deck-mcp.json" ] || fail "the primary MCP config was inherited"
  printf '{"servers":{"secondmate-only":{}}}\n' > "$home/config/deck-mcp.json"
  cp "$home/config/deck-mcp.json" "$dir/local-before.json"
  propagate_inheritable_config "$src" "$home/config" || fail "config re-propagation failed"
  cmp -s "$dir/local-before.json" "$home/config/deck-mcp.json" \
    || fail "propagation overwrote the secondmate's local MCP config"
  rm "$src/deck-mcp.json"
  propagate_inheritable_config "$src" "$home/config" || fail "config absence propagation failed"
  cmp -s "$dir/local-before.json" "$home/config/deck-mcp.json" \
    || fail "primary MCP absence removed the secondmate's local config"
  printf '{"case":"mcp-inheritance","empty_home_received_mcp":false,"local_mcp_preserved_after_push_and_primary_removal":true}\n'
  pass "Deck MCP config stays home-local during config propagation and absence mirroring"
)

test_turns_drive_the_busy_record_and_turn_end() {
  local dir="$TMP_ROOT/busy" rec
  make_fake_deck "$dir"
  run_worker "$dir" $'/quit\n' || fail "the driver did not exit cleanly"
  [ -f "$dir/state/t1.turn-ended" ] || fail "a finished turn did not touch the turn-end notification"
  rec=$(cat "$dir/state/t1.busy-state")
  assert_contains "$rec" "source=deck-wrapper" "the busy record was not written by the deck driver"
  assert_contains "$rec" "state=idle" "the busy record did not close idle"
  assert_contains "$rec" "event=session-end" "/quit did not record session-end"
  [ "$(fm_busy_classify stream fake deck t1 "$dir/state")" = "idle deck-wrapper" ] \
    || fail "busy-lib does not trust the deck driver's record: $(fm_busy_classify stream fake deck t1 "$dir/state")"
  [ "$(fm_busy_classify stream fake pi t1 "$dir/state")" = "unknown source-mismatch" ] \
    || fail "the deck driver's record must not classify another adapter"
  pass "fm-deck-worker: turns open and close the deck-wrapper busy record and touch turn-end"
}

test_busy_state_failures_stop_turns_and_publish_status() {
  local start="$TMP_ROOT/busy-start-failure" close="$TMP_ROOT/busy-close-failure" old_gen rc
  make_fake_deck "$start"
  mkdir -p "$start/state"
  old_gen=$("$BUSY_EVENT" arm "$start/state" t1)
  "$BUSY_EVENT" arm "$start/state" t1 >/dev/null
  rc=0
  printf '/quit\n' | FM_TEST_STATUS="$start/state/t1.status" FM_TEST_EXTERNAL='' \
    FM_TEST_BUSY_EVENT="$BUSY_EVENT" \
    "$WORKER" --id t1 --state "$start/state" --gen "$old_gen" \
      --deck "$start/deck" -- the-brief > "$start/pane.out" 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a turn started after its busy-state event was refused"
  [ ! -e "$start/argv.log" ] || fail "Deck ran before the wrapper recorded turn-start"
  assert_grep 'failed: deck wrapper could not record busy-state event (turn-start)' "$start/state/t1.status" \
    "a refused turn-start did not publish a failure status"

  assert_grep 'stale busy-state gen for t1' "$start/state/t1.status" \
    "the underlying busy-event stderr was discarded from status"
  assert_grep 'stale busy-state gen for t1' "$start/pane.out" \
    "the underlying busy-event stderr was discarded from the pane"
  make_fake_deck "$close"
  rc=0
  run_worker "$close" $'/quit\n' 'write-status replace-busy-gen' || rc=$?
  [ "$rc" -ne 0 ] || fail "a stale turn-end busy event was ignored"
  assert_grep 'done: wrote evidence' "$close/state/t1.status" \
    "the close-event fixture did not publish its normal turn evidence"
  assert_grep 'failed: deck wrapper could not record busy-state event (turn-end)' "$close/state/t1.status" \
    "a refused turn-end did not publish a failure status"
  assert_grep 'failed: deck wrapper could not refresh progress: error: stale busy-state gen' "$close/state/t1.status" \
    "the progress hook discarded its failure diagnostic"
  assert_grep 'stale busy-state gen for t1' "$close/pane.out" \
    "the progress hook discarded stderr from the pane"
  assert_grep 'could not record busy-state event turn-end' "$close/pane.out" \
    "a refused turn-end was not surfaced in the worker pane"
  pass "fm-deck-worker: busy-state failures stop turns and publish status evidence"
}

test_finished_turn_renders_the_utc_completion_time() {
  local dir="$TMP_ROOT/finish-time" legacy="$TMP_ROOT/finish-time-legacy"
  make_fake_deck "$dir"
  run_worker "$dir" $'/quit\n' write-status || fail "the driver did not exit cleanly"
  assert_grep 'turn finished 2026-09-24T17:01Z (1 model calls)' "$dir/pane.out" \
    "the finished turn did not carry the UTC completion time from run_finished.finished_at"
  assert_no_grep 'turn finished (' "$dir/pane.out" \
    "the finished turn rendered the timestamp-less legacy wording while finished_at was present"

  make_fake_deck "$legacy"
  run_worker "$legacy" $'/quit\n' legacy-finish-write-status || fail "the legacy driver run did not exit cleanly"
  assert_grep 'turn finished (1 model calls)' "$legacy/pane.out" \
    "a run_finished without finished_at did not fall back to the timestamp-less wording"
  assert_no_grep 'turn finished 2026-' "$legacy/pane.out" \
    "a run_finished without finished_at invented a completion time"
  pass "fm-deck-worker: the finished-turn line carries the UTC completion time and degrades safely without it"
}

test_idle_prompt_notes_the_utc_idle_instant() {
  local dir="$TMP_ROOT/idle-note" before after note stamp last
  make_fake_deck "$dir"
  before=$(date -u +%Y-%m-%dT%H:%MZ)
  run_worker "$dir" $'/quit\n' write-status || fail "the driver did not exit cleanly"
  after=$(date -u +%Y-%m-%dT%H:%MZ)
  note=$(grep -E '^idle since [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}Z$' "$dir/pane.out" | tail -1)
  [ -n "$note" ] || fail "the idle prompt did not note when the worker went idle"
  stamp=${note#idle since }
  [ "$stamp" = "$before" ] || [ "$stamp" = "$after" ] \
    || fail "the idle-since note did not carry the turn's UTC end instant: $stamp (turn ran between $before and $after)"
  last=$(tail -1 "$dir/pane.out")
  case "$last" in
    '❯'|'❯ ') ;;
    *) fail "the prompt row is no longer the bare ❯ glyph row the shared composer contract reads: $last" ;;
  esac
  [ "$(tail -2 "$dir/pane.out" | sed -n 1p)" = "$note" ] \
    || fail "the idle-since note does not sit on the line beside the ❯ prompt"
  pass "fm-deck-worker: the idle prompt notes the UTC idle instant beside the bare ❯ prompt"
}

test_turnend_signal_refuses_unsafe_paths() {
  local linked="$TMP_ROOT/turnend-symlink" irregular="$TMP_ROOT/turnend-directory" rc
  make_fake_deck "$linked"
  mkdir -p "$linked/state"
  ln -s "$linked/external-signal" "$linked/state/t1.turn-ended"
  rc=0
  run_worker "$linked" $'/quit\n' write-status || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked turn-end signal was accepted"
  [ ! -e "$linked/external-signal" ] || fail "the turn-end publisher followed a symlink target"
  [ -L "$linked/state/t1.turn-ended" ] || fail "the unsafe turn-end symlink was replaced"
  assert_grep 'could not safely publish turn-end signal' "$linked/pane.out" \
    "the turn-end symlink refusal was not reported"

  make_fake_deck "$irregular"
  mkdir -p "$irregular/state/t1.turn-ended"
  rc=0
  run_worker "$irregular" $'/quit\n' write-status || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-regular turn-end signal was accepted"
  [ -d "$irregular/state/t1.turn-ended" ] || fail "the non-regular turn-end target was replaced"
  pass "fm-deck-worker: turn-end publication refuses unsafe targets"
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

test_stderr_before_completion_blocked_does_not_break_rendering() {
  local dir="$TMP_ROOT/stderr-before-blocked"
  make_fake_deck "$dir"
  run_worker "$dir" $'/quit\n' recover-after-refusal || fail "the refused turn did not recover and finish"
  [ "$(sed -n 1p "$dir/gate.log")" = refused ] || fail "the fixture did not refuse the first completion attempt"
  [ "$(sed -n 2p "$dir/gate.log")" = pass ] || fail "the recovered completion attempt did not pass"
  assert_grep 'pre_complete hook rejected completion' "$dir/pane.out" "Deck stderr was not preserved outside the event stream"
  assert_grep 'finish refused (attempt 1)' "$dir/pane.out" "the completion_blocked event did not render after Deck wrote stderr"
  assert_grep 'turn finished 2026-09-24T17:01Z (1 model calls)' "$dir/pane.out" "the recovered turn did not render its completion with the UTC finish time"
  [ "$(cat "$dir/state/t1.status")" = 'done: recovered after refusal' ] \
    || fail "the recovered turn was replaced with failure evidence"
  pass "fm-deck-worker: Deck stderr cannot break completion-blocked rendering"
}

test_bookkeeping_lines_do_not_satisfy_turn_evidence() {
  local dir="$TMP_ROOT/bookkeeping-evidence"
  make_fake_deck "$dir"
  run_worker "$dir" $'/quit\n' resolve-only || fail "the bookkeeping-only turn did not return to /quit"
  [ "$(cat "$dir/gate.log")" = refused ] || fail "a resolved line satisfied Deck's pre-complete evidence gate"
  [ "$(sed -n 1p "$dir/state/t1.status")" = 'resolved [key=choice]: answered: yes' ] \
    || fail "the fixture did not append its Firstmate-owned bookkeeping line"
  [ "$(sed -n 2p "$dir/state/t1.status")" = 'failed: deck turn ended without a status line (turn-end)' ] \
    || fail "the wrapper postcondition treated a resolved line as worker evidence"
  pass "fm-deck-worker: Firstmate bookkeeping cannot satisfy worker evidence"
}

test_status_checks_and_fallbacks_refuse_unsafe_paths() {
  local linked="$TMP_ROOT/status-symlink" replaced="$TMP_ROOT/status-replaced" irregular="$TMP_ROOT/status-directory" rc
  make_fake_deck "$linked"
  mkdir -p "$linked/state"
  printf 'protected\n' > "$linked/external"
  ln -s "$linked/external" "$linked/state/t1.status"
  rc=0
  run_worker "$linked" $'/quit\n' > /dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a symlinked Deck status path was accepted"
  if printf 'failed: fallback must not land\n' | python3 "$ROOT/bin/fm-state-io.py" \
    root-append "$linked/state" t1.status >/dev/null 2>&1; then
    fail "the Deck fallback append accepted a symlinked status path"
  fi
  [ "$(cat "$linked/external")" = protected ] || fail "a status check or fallback append touched a symlink target"
  [ ! -e "$linked/argv.log" ] || fail "Deck ran after the initial status path failed validation"

  make_fake_deck "$replaced"
  mkdir -p "$replaced/state"
  printf 'protected\n' > "$replaced/external"
  ln -s "$replaced/external-signal" "$replaced/state/t1.turn-ended"
  rc=0
  FM_TEST_EXTERNAL="$replaced/external" run_worker "$replaced" $'/quit\n' replace-status || rc=$?
  [ "$rc" -ne 0 ] || fail "a status path replaced by a symlink during the turn was accepted"
  [ "$(cat "$replaced/external")" = protected ] || fail "the evidence fallback followed a replacement symlink"
  [ ! -e "$replaced/external-signal" ] || fail "the failed-evidence path followed a turn-end symlink"
  assert_grep 'could not safely publish turn-end signal' "$replaced/pane.out" \
    "the failed-evidence path did not report its turn-end refusal"

  make_fake_deck "$irregular"
  mkdir -p "$irregular/state/t1.status"
  rc=0
  run_worker "$irregular" $'/quit\n' > /dev/null 2>&1 || rc=$?
  [ "$rc" -ne 0 ] || fail "a non-regular Deck status path was accepted"
  pass "fm-deck-worker: status evidence never follows symlinked or non-regular paths"
}

test_doorbell_for_an_empty_own_inbox_starts_no_turn() {
  local dir="$TMP_ROOT/doorbell" bell other
  make_fake_deck "$dir"
  mkdir -p "$dir/state/t1.inbox/handled" "$dir/other.inbox"
  bell=": Firstmate instruction waiting: list '$dir/state/t1.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '$dir/state/t1.inbox'/handled/."
  other=": Firstmate instruction waiting: list '$dir/other.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '$dir/other.inbox'/handled/."
  run_worker "$dir" "$bell"$'\n'"$other"$'\nwrite-status\n/quit\n' "write-status brief" \
    || fail "the driver did not exit cleanly: $(cat "$dir/pane.out")"
  [ "$(wc -l < "$dir/argv.log" | tr -d ' ')" = 3 ] \
    || fail "an empty own-inbox doorbell must start no turn, while another inbox's doorbell and a steer do: $(cat "$dir/argv.log")"
  assert_not_contains "$(cat "$dir/argv.log")" "$dir/state/t1.inbox'" "the empty own-inbox doorbell became a turn"
  make_fake_deck "$dir/pending"
  mkdir -p "$dir/pending/state/t1.inbox/handled"
  printf 'schema=fm-task-inbox.v1\nat=x\n--\nhello\n' > "$dir/pending/state/t1.inbox/001.msg"
  bell=": Firstmate instruction waiting: list '$dir/pending/state/t1.inbox'/*.msg and, in numeric order, read and act on each, then mv each handled file to '$dir/pending/state/t1.inbox'/handled/."
  run_worker "$dir/pending" "$bell"$'\n/quit\n' "write-status brief" \
    || fail "the driver did not exit cleanly with a pending record: $(cat "$dir/pending/pane.out")"
  [ "$(wc -l < "$dir/pending/argv.log" | tr -d ' ')" = 2 ] \
    || fail "a doorbell with a pending record must start a turn: $(cat "$dir/pending/argv.log")"
  pass "fm-deck-worker: a doorbell for its own empty inbox starts no turn; any other doorbell still does"
}

test_driver_backstops_silent_and_failed_turns() {
  local silent="$TMP_ROOT/postcondition-silent" failed="$TMP_ROOT/postcondition-failed"
  make_fake_deck "$silent"
  run_worker "$silent" $'/quit\n' || fail "the silent-turn driver did not exit cleanly"
  [ "$(cat "$silent/state/t1.status")" = 'failed: deck turn ended without a status line (turn-end)' ] \
    || fail "a silently completed turn did not receive the exact fallback status: $(cat "$silent/state/t1.status")"
  assert_not_contains "$(cat "$silent/pane.out")" "No such file or directory" "a missing status log leaked a turn-start read error into the pane"
  [ -f "$silent/state/t1.turn-ended" ] || fail "the silent turn did not publish turn-ended after its fallback status"

  make_fake_deck "$failed"
  run_worker "$failed" $'/quit\n' 'fail-turn' || fail "the failed-turn driver did not remain available for /quit"
  [ "$(cat "$failed/state/t1.status")" = 'failed: deck turn ended without a status line (turn-failed)' ] \
    || fail "a provider-failed turn did not receive the exact fallback status: $(cat "$failed/state/t1.status")"
  [ -f "$failed/state/t1.turn-ended" ] || fail "the provider-failed turn did not publish turn-ended after its fallback status"
  assert_not_contains "$(cat "$failed/pane.out")" 'waiting at the prompt for the next wake' \
    "a crewmate turn failure took the persistent secondmate's survival path"
  pass "fm-deck-worker: silent and failed turns gain status evidence before turn-end"
}

test_idle_interrupt_does_not_echo_fake_input() {
  local dir="$TMP_ROOT/idle-interrupt" gen
  make_fake_deck "$dir"
  mkdir -p "$dir/state"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  python3 - "$ROOT" "$dir" "$gen" <<'PY' || fail "idle terminal control-echo regression failed"
import importlib.util, os, pathlib, select, sys, termios, time
root, directory, gen = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
spec = importlib.util.spec_from_file_location('stream_agent', root / 'bin/fm-stream-agent.py')
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)
env = dict(os.environ, FM_TEST_STATUS=str(directory/'state/t1.status'), FM_TEST_EXTERNAL='')
p = agent.Pty(str(directory), [str(root/'bin/fm-deck-worker.sh'), '--id', 't1',
    '--state', str(directory/'state'), '--gen', gen, '--deck', str(directory/'deck'),
    '--', 'write-status'], 40, 200, env)
def read_ready():
    return p.read() if select.select([p.master_fd], [], [], .1)[0] else b''
try:
    output = b''
    for _ in range(100):
        output += read_ready()
        if '❯ '.encode() in output: break
        time.sleep(.1)
    assert '❯ '.encode() in output, repr(output)
    flags = termios.tcgetattr(p.master_fd)[3]
    assert flags & termios.ISIG, 'Ctrl+C must still deliver SIGINT'
    assert flags & termios.ECHO, 'ordinary typed input must remain visible'
    assert not flags & termios.ECHOCTL, 'control-key echo would masquerade as pending input'
    p.write(b'\x03')
    echoed = b''.join(read_ready() for _ in range(10))
    assert b'^C' not in echoed, repr(echoed)
    assert p.alive(), 'idle interrupt stopped the driver'
    p.write(b'visible partial input')
    echoed = b''
    for _ in range(50):
        echoed += read_ready()
        if b'visible partial input' in echoed: break
        time.sleep(.1)
    assert b'visible partial input' in echoed, repr(echoed)
finally:
    p.close('TERM')
    p.close('KILL')
    p.release()
PY
  pass "Deck idle Ctrl+C stays a signal, not fake input, while partial input remains visible"
}

test_ctrl_c_cancels_the_turn_and_returns_to_the_prompt() {
  local dir="$TMP_ROOT/interrupt" gen pid sleeper ready=0 pgid
  make_fake_deck "$dir"
  mkdir -p "$dir/state"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  mkfifo "$dir/in"
  # Hold stdin open without a timer: after cancellation the driver must remain
  # at its prompt until this test deliberately closes the writer.
  exec 3<>"$dir/in"
  # A terminal's Ctrl+C signals the pane's whole foreground process group, so
  # the driver gets a group of its own (job control) and the group is signalled.
  # Reset SIGINT before exec because a bounded test runner may itself have been
  # launched asynchronously, while a real terminal-launched pane is not.
  set -m
  FM_TEST_STATUS="$dir/state/t1.status" python3 -c \
    'import os, signal, sys; signal.signal(signal.SIGINT, signal.SIG_DFL); os.execv(sys.argv[1], sys.argv[1:])' \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" \
      --deck "$dir/deck" -- "please sleep" < "$dir/in" > "$dir/pane.out" 2>&1 &
  pid=$!
  set +m
  for _ in $(seq 50); do
    sleeper=$(cat "$dir/interrupt-ready" 2>/dev/null || true)
    pgid=$(ps -o pgid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
    if grep -q 'state=busy' "$dir/state/t1.busy-state" 2>/dev/null \
      && [ "$pgid" = "$pid" ] && kill -0 "$sleeper" 2>/dev/null; then
      ready=1
      break
    fi
    sleep 0.1
  done
  [ "$ready" -eq 1 ] || fail "the Deck turn never reached its interruptible child process"
  kill -INT -- -"$pid" 2>/dev/null || fail "could not signal the Deck worker process group"
  for _ in $(seq 50); do grep -q 'event=interrupted' "$dir/state/t1.busy-state" 2>/dev/null && break; sleep 0.1; done
  assert_grep 'event=interrupted' "$dir/state/t1.busy-state" "Ctrl+C did not close the turn as interrupted"
  [ "$(cat "$dir/state/t1.status")" = 'failed: deck turn ended without a status line (interrupted)' ] \
    || fail "an interrupted turn did not receive the exact fallback status: $(cat "$dir/state/t1.status")"
  for _ in $(seq 50); do [ -f "$dir/state/t1.turn-ended" ] && break; sleep 0.1; done
  [ -f "$dir/state/t1.turn-ended" ] || fail "the interrupted turn did not publish turn-ended after its fallback status"
  kill -0 "$pid" 2>/dev/null || fail "the driver exited on Ctrl+C instead of returning to its prompt"
  assert_grep 'Interrupted.' "$dir/pane.out" "the pane did not show the cancelled turn"
  kill -TERM -- -"$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  exec 3>&-
  pass "fm-deck-worker: Ctrl+C records evidence and returns the worker to its prompt"
}

# real_stream_env <dir> <command...>: run <command> with the dispatcher sourced
# against the case's REAL hub (start_real_hub) and the real stream agent, so a
# driver runs in a real pseudoterminal the way a spawned worker does.
real_stream_env() {  # <dir> <command...>
  local dir=$1
  shift
  (
    FM_STREAM_HUB=$(cat "$dir/hub.url")
    FM_STREAM_TOKEN=$(cat "$dir/hub.token")
    export FM_STREAM_HUB FM_STREAM_TOKEN FM_STREAM_MACHINE=deck-box FM_HOME="$dir" FM_ROOT="$ROOT"
    unset FM_STREAM_AGENT_BIN
    # shellcheck source=bin/fm-backend.sh
    . "$ROOT/bin/fm-backend.sh"
    fm_backend_source stream || exit 90
    # The suite sourced the adapter against the fake hub's agent stub; this
    # endpoint is a real one.
    # shellcheck disable=SC2034 # Read by the sourced stream adapter.
    FM_BACKEND_STREAM_AGENT_BIN="$ROOT/bin/fm-stream-agent.py"
    "$@"
  )
}

start_real_hub() {  # <dir>
  local dir=$1 waited=0 host port pid token="deck-hub-$$-$RANDOM"
  printf 'publish,subscribe,control:%s\n' "$token" > "$dir/hub.tokens"
  chmod 600 "$dir/hub.tokens"
  printf '%s\n' "$token" > "$dir/hub.token"
  python3 "$ROOT/bin/fm-stream-hub.py" serve --bind 127.0.0.1 --port 0 \
    --token-file "$dir/hub.tokens" --ready-file "$dir/hub.ready" > "$dir/hub.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ "$waited" -lt 100 ]; do
    [ -s "$dir/hub.ready" ] && break
    sleep 0.1
    waited=$((waited + 1))
  done
  [ -s "$dir/hub.ready" ] || return 1
  read -r host port < "$dir/hub.ready"
  printf 'http://%s:%s\n' "$host" "$port" > "$dir/hub.url"
}

test_completed_turn_removes_busy_ack_before_the_next_steer() {
  local dir="$TMP_ROOT/second-steer" target command capture last rc gen pair url agent
  make_fake_deck "$dir"
  mkdir -p "$dir/state" "$dir/cwd"
  start_real_hub "$dir" || fail "the real stream hub never became ready: $(cat "$dir/hub.log" 2>/dev/null)"
  url=$(cat "$dir/hub.url")
  pair=$(real_stream_env "$dir" fm_backend_stream_create_task fm-t1 "$dir/cwd" "$dir/state/t1.status") \
    || fail "could not create the Deck endpoint on the real hub"
  target="${pair%% *}:${pair##* }"
  agent=$(ps -eo pid,args 2>/dev/null | awk -v u="$url" -v l="--label fm-t1" \
    'index($0, "fm-stream-agent") && index($0, " serve ") && index($0, u) && index($0, l) && !index($0, "awk") {print $1; exit}')
  fm_test_track_helper_pid "$agent"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  printf -v command 'exec env FM_TEST_STATUS=%q %q --id t1 --state %q --gen %q --deck %q -- %q' \
    "$dir/state/t1.status" "$WORKER" "$dir/state" "$gen" "$dir/deck" 'write-status prior ctrl+c to stop'
  real_stream_env "$dir" fm_backend_send_text_submit stream "$target" "$command" 3 0.2 0.2 >/dev/null \
    || fail "could not start the Deck driver in its endpoint"
  printf 'window=%s\nbackend=stream\nstream_hub=%s\nstream_endpoint_id=%s\nendpoint_task_id=t1\nharness=deck\nkind=ship\n' \
    "$target" "$url" "${pair##* }" > "$dir/state/t1.meta"
  for _ in $(seq 160); do
    capture=$(real_stream_env "$dir" fm_backend_capture stream "$target" 30 2>/dev/null || true)
    last=$(printf '%s\n' "$capture" | awk 'NF { line=$0 } END { print line }')
    [ "$last" = '❯' ] && break
    sleep 0.05
  done
  [ "$last" = '❯' ] || fail "the Deck fixture never reached its first idle prompt: $capture"
  assert_not_contains "$capture" '⛵ deck working - ctrl+c to stop' "a completed Deck turn left a stale busy acknowledgement"
  assert_contains "$capture" 'echo: write-status prior ctrl+c to stop' \
    "the fixture did not retain rendered text containing the generic busy token"

  # The stream adapter confirms a submit only from the endpoint's rendered
  # composer, and a Deck turn renders no composer until it ends, so the
  # read-back waits out the fake deck's slow (0.8s) turn, with room for a loaded
  # host, rather than reading the screen mid-turn.
  rc=0
  real_stream_env "$dir" env FM_STATE_OVERRIDE="$dir/state" FM_SEND_SETTLE=0 FM_SEND_SLEEP=4 \
    "$ROOT/bin/fm-send.sh" "$target" 'write-status slow first steer' >/dev/null 2>"$dir/first.err" || rc=$?
  expect_code 0 "$rc" "the first Deck steer was not confirmed: $(cat "$dir/first.err")"
  for _ in $(seq 160); do
    capture=$(real_stream_env "$dir" fm_backend_capture stream "$target" 30 2>/dev/null || true)
    last=$(printf '%s\n' "$capture" | awk 'NF { line=$0 } END { print line }')
    if [ "$(grep -c '^done: wrote evidence$' "$dir/state/t1.status" 2>/dev/null || true)" -ge 2 ] \
      && [ "$last" = '❯' ]; then
      break
    fi
    sleep 0.05
  done
  [ "$last" = '❯' ] || fail "the first Deck steer did not return to its idle prompt: $capture"
  assert_not_contains "$capture" 'deck working - ctrl+c to stop' "the first steer left its busy acknowledgement in the idle pane"

  rc=0
  real_stream_env "$dir" env FM_STATE_OVERRIDE="$dir/state" FM_SEND_SETTLE=0 FM_SEND_SLEEP=4 \
    "$ROOT/bin/fm-send.sh" "$target" 'write-status slow second steer' >/dev/null 2>"$dir/second.err" || rc=$?
  real_stream_env "$dir" fm_backend_send_text_submit stream "$target" /quit 1 0.2 0.2 >/dev/null 2>&1 || true
  real_stream_env "$dir" fm_backend_kill stream "$target" >/dev/null 2>&1 || true
  [ -z "$agent" ] || kill "$agent" 2>/dev/null || true
  expect_code 0 "$rc" "the second Deck steer was not confirmed from an idle baseline: $(cat "$dir/second.err")"
  pass "fm-deck-worker: each completed turn leaves the next steer an idle baseline"
}

test_driver_stop_terminates_active_deck_and_resolves_spaced_paths() {
  local dir="$TMP_ROOT/stop graceful with spaces" install physical alias deck worker stop pid gen rc
  install="$dir/install with spaces/bin"
  physical="$dir/physical state"
  alias="$dir/state alias"
  deck="$dir/deck binary"
  worker="$install/fm-deck-worker.sh"
  stop="$install/fm-deck-stop.py"
  mkdir -p "$install" "$physical"
  cp "$WORKER" "$BUSY_EVENT" "$ROOT/bin/fm-busy-lib.sh" \
    "$ROOT/bin/fm-session-lock-lib.sh" "$ROOT/bin/fm-cursor-lib.sh" "$ROOT/bin/fm-nm-run-lib.sh" \
    "$ROOT/bin/fm-state-io.py" "$ROOT/bin/fm-deck-stop.py" "$install/"
  ln -s "$physical" "$alias"
  cat > "$deck" <<'PY'
#!/usr/bin/env python3
import json
import os
import time

print(json.dumps({"type": "run_started", "session": "stop-session"}), flush=True)
print(json.dumps({"type": "tool_call", "id": "a", "name": "run_command", "arguments": {"command": "tool-a"}}), flush=True)
open(os.environ["FM_DECK_READY"], "w").close()
time.sleep(10)
open(os.environ["FM_DECK_TOOL_A_COMPLETED"], "w").close()
print(json.dumps({"type": "tool_result", "id": "a", "name": "run_command", "duration_ms": 10000, "output": "tool-a complete"}), flush=True)
open(os.environ["FM_DECK_TOOL_B_STARTED"], "w").close()
print(json.dumps({"type": "tool_call", "id": "b", "name": "run_command", "arguments": {"command": "tool-b"}}), flush=True)
time.sleep(10)
PY
  chmod +x "$deck"
  gen=$("$install/fm-busy-event.sh" arm "$physical" owned)
  FM_DECK_READY="$dir/ready" FM_DECK_TOOL_A_COMPLETED="$dir/tool-a-completed" \
    FM_DECK_TOOL_B_STARTED="$dir/tool-b-started" \
    python3 -c \
      'import os,sys; os.setsid(); os.execv("/bin/bash", ["fm-deck-worker"] + sys.argv[1:])' \
      "$worker" --id owned --state "$(cd "$physical" && pwd -P)" --gen "$gen" \
      --deck "$deck" -- old-brief </dev/null > "$dir/pane.out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [ ! -e "$dir/ready" ] || break; sleep 0.05; done
  [ -e "$dir/ready" ] || fail "post-tool stop fixture did not start"
  python3 "$stop" "$alias" owned 2 \
    || fail "spaced physical paths did not identify and stop the Deck driver"
  rc=0
  wait "$pid" 2>/dev/null || rc=$?
  [ "$rc" -ne 0 ] || fail "the abruptly TERM-stopped driver reported success"
  [ ! -e "$dir/tool-a-completed" ] || fail "Deck TERM unexpectedly let the active in-process tool complete"
  [ ! -e "$dir/tool-b-started" ] || fail "Deck started another tool after TERM"
  pass "Deck stop: physical aliases and spaced paths stop the active Deck process"
}

test_stale_secondmate_driver_is_stopped_at_relaunch_boundary() {
  local dir="$TMP_ROOT/stop-secondmate" install state worker stop pid
  install="$dir/install/bin"
  state="$dir/state"
  worker="$install/fm-deck-worker.sh"
  stop="$install/fm-deck-stop.py"
  mkdir -p "$install" "$state"
  cp "$ROOT/bin/fm-deck-stop.py" "$stop"
  cat > "$worker" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM
: > "$FM_DECK_READY"
while :; do :; done
SH
  chmod +x "$worker"
  FM_DECK_READY="$dir/ready" python3 -c \
    'import os,sys; os.setsid(); os.execv("/bin/bash", ["fm-deck-worker"] + sys.argv[1:])' \
    "$worker" --secondmate --id stale-host --state "$state" --gen stale-generation \
    --deck "$dir/deck" -- old-charter </dev/null > "$dir/pane.out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [ ! -e "$dir/ready" ] || break; sleep 0.05; done
  [ -e "$dir/ready" ] || fail "stale secondmate driver fixture did not start"
  python3 "$stop" "$state" stale-host 1 \
    || fail "the relaunch boundary refused to stop a stale secondmate driver"
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL -- -"$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    fail "the relaunch boundary skipped a stale secondmate driver"
  fi
  wait "$pid" 2>/dev/null || true
  : > "$dir/replacement-armed"
  [ -e "$dir/replacement-armed" ] || fail "replacement was not armed after the secondmate stop proof"
  pass "Deck stop: stale secondmate drivers stop before replacement arming"
}

test_driver_stop_is_scoped_and_escalates_after_timeout() {
  local dir="$TMP_ROOT/stop-escalation" pid gen
  mkdir -p "$dir/state"
  cat > "$dir/deck" <<'PY'
#!/usr/bin/env python3
import json
import os
import signal
import time

def term(*_):
    open(os.environ["FM_DECK_SIGNALLED"], "a").close()


signal.signal(signal.SIGTERM, term)
print(json.dumps({"type": "run_started", "session": "stuck-session"}), flush=True)
open(os.environ["FM_DECK_READY"], "w").close()
while True:
    time.sleep(60)
PY
  chmod +x "$dir/deck"
  gen=$("$BUSY_EVENT" arm "$dir/state" owned)
  FM_DECK_READY="$dir/ready" FM_DECK_SIGNALLED="$dir/signalled" python3 -c \
    'import os,sys; os.setsid(); os.execv("/bin/bash", ["fm-deck-worker"] + sys.argv[1:])' \
    "$WORKER" --id owned --state "$dir/state" --gen "$gen" --deck "$dir/deck" -- old-brief \
    </dev/null > "$dir/pane.out" 2>&1 &
  pid=$!
  for _ in $(seq 100); do [ ! -e "$dir/ready" ] || break; sleep 0.1; done
  [ -e "$dir/ready" ] || fail "stop escalation fixture did not start"
  python3 - "$ROOT/bin/fm-deck-stop.py" "$dir/state" owned <<'PY' \
    || fail "non-finite stop timeouts were not rejected promptly"
import subprocess
import sys

helper, state, task = sys.argv[1:]
for timeout in ("nan", "inf", "-inf"):
    result = subprocess.run(
        [sys.executable, helper, state, task, timeout],
        capture_output=True,
        text=True,
        timeout=2,
    )
    assert result.returncode != 0, timeout
    assert "timeout must be finite" in result.stderr, (timeout, result.stderr)
PY
  [ ! -e "$dir/signalled" ] || fail "a non-finite timeout signalled the Deck process before refusal"
  python3 "$ROOT/bin/fm-deck-stop.py" "$dir/state" other 1 || fail "unrelated task stop refused"
  kill -0 "$pid" 2>/dev/null || fail "stopping another task killed this driver"
  python3 "$ROOT/bin/fm-deck-stop.py" "$dir/state" owned 0.3 \
    || fail "the timed-out driver group was not escalated"
  wait "$pid" 2>/dev/null || true
  kill -0 "$pid" 2>/dev/null && fail "the timed-out driver survived escalation"
  pass "Deck stop: exact task scope and bounded escalation remove survivors"
}

test_liveness_reads_the_driver_as_an_agent() {
  [ "$(fm_agent_process_classify bash fm-deck-worker '')" = agent ] || fail "the driver's argv[0] must read as an agent"
  [ "$(fm_agent_process_classify fm-deck-worker fm-deck-worker '')" = agent ] || fail "the driver's macOS process name must read as an agent"
  [ "$(fm_agent_process_classify deck deck '')" = agent ] || fail "the deck binary must read as an agent"
  [ "$(fm_agent_process_classify decker decker '')" = other ] || fail "an unrelated name containing deck was claimed"
  [ "$(fm_agent_process_classify bash bash '')" = shell ] || fail "a plain shell must still read as a shell"
  pass "liveness: the deck driver and binary are agents, unrelated names are not"
}

test_stream_liveness_uses_the_deck_driver_argv0() {
  local dir="$TMP_ROOT/stream-argv0" target state
  mkdir -p "$dir/state"
  target=$(fm_test_stream_task "$dir/state" t1 | sed -n 's/^window=//p') \
    || fail "could not register the Deck endpoint"
  # The endpoint's agent reports Linux's comm (bash) with the driver's argv[0].
  fm_test_fake_stream_set "$target" \
    '{"foreground": [{"pid": "", "name": "bash", "argv0": "fm-deck-worker", "args": "fm-deck-worker"}]}'
  state=$(fm_backend_agent_state stream "$target")
  [ "$state" = alive ] || fail "stream reported comm=bash with argv[0]=fm-deck-worker as $state"
  fm_test_fake_stream_set "$target" '{"foreground": [{"pid": "", "name": "bash", "argv0": "bash", "args": "bash"}]}'
  state=$(fm_backend_agent_state stream "$target")
  [ "$state" = dead ] || fail "a bare shell with no driver argv[0] read as $state"
  pass "stream liveness: Deck's Linux comm and argv0 classify alive"
}

test_control_busy_and_delivery_tables_name_deck() {
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$ROOT/bin/fm-session-lock-lib.sh"
  fm_harness_process_matches fm-deck-worker fm-deck-worker || fail "driver comm cannot own a lock"
  fm_harness_process_matches bash 'fm-deck-worker script' || fail "driver argv0 cannot own a lock"
  fm_harness_process_matches deck deck && fail "transient Deck run must not own a home lock"
  fm_control_harness_supported deck || fail "deck is not a supported control harness"
  [ "$(fm_control_harness_family deck)" = deck ] || fail "deck family"
  fm_control_harness_supports_kind deck ship || fail "deck must run ship tasks"
  fm_control_harness_supports_kind deck secondmate || fail "deck must run secondmates"
  [ "$(fm_control_interrupt_key deck)" = C-c ] || fail "deck interrupts on Ctrl+C"
  [ "$(fm_control_interrupt_repeat deck)" = 1 ] || fail "deck interrupt repeat"
  [ "$(fm_control_exit_command deck)" = /quit ] || fail "deck exits with /quit"
  fm_busy_source_trusted deck deck-wrapper || fail "busy-lib must trust deck-wrapper for deck"
  fm_busy_source_trusted claude deck-wrapper && fail "deck-wrapper must not be trusted for claude"
  printf '⛵ deck working - ctrl+c to stop\n' | fm_busy_lines_match deck \
    && fail "rendered Deck output was accepted as delivery evidence"
  pass "control and busy-source tables carry Deck mechanics without rendered delivery evidence"
}

# Recovery reads a Deck task's liveness from the foreground process its
# endpoint's agent reports; stale busy and progress records never stand in for
# a driver. A real driver writes the records; the endpoint is a fake one.
test_stream_deck_recovery() {
  local dir="$TMP_ROOT/stream-deck-recovery" gen driver record target out
  mkdir -p "$dir/state"
  make_fake_deck "$dir"
  { fm_test_stream_task "$dir/state" t1; printf 'harness=deck\nkind=secondmate\n'; } > "$dir/state/t1.meta" \
    || fail "could not register the Deck endpoint"
  target=$(sed -n 's/^window=//p' "$dir/state/t1.meta")
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  "$BUSY_EVENT" progress "$dir/state" t1 --gen "$gen" || fail "progress fixture failed"
  deck_verdict() {
    FM_STATE_OVERRIDE="$dir/state" fm_backend_agent_state stream "$target"
  }
  driver_foreground() {  # <present|absent>
    if [ "$1" = present ]; then
      fm_test_fake_stream_set "$target" \
        '{"foreground": [{"pid": "", "name": "bash", "argv0": "fm-deck-worker", "args": "fm-deck-worker"}]}'
    else
      fm_test_fake_stream_set "$target" '{"foreground": [{"pid": "", "name": "zsh", "argv0": "zsh", "args": "zsh"}]}'
    fi
  }
  # Dead FIRST: stale busy/progress records cannot resurrect an absent driver.
  driver_foreground absent
  out=$(deck_verdict)
  [ "$out" = dead ] || fail "absent Deck driver with stale busy/progress must be dead: $out"
  mkfifo "$dir/input"
  exec 8<> "$dir/input"
  FM_TEST_STATUS="$dir/state/t1.status" bash -c 'exec -a fm-deck-worker bash "$@"' _ \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" --deck "$dir/deck" -- write-status \
    < "$dir/input" > "$dir/pane.out" 2>&1 &
  driver=$!
  fm_test_track_helper_pid "$driver"
  for _ in $(seq 1 100); do
    record=$(fm_busy_record_read "$dir/state" t1)
    case "$record" in 'idle deck-wrapper '*) break ;; esac
    sleep 0.1
  done
  case "$record" in 'idle deck-wrapper '*) ;; *) fail "driver did not reach idle: $record" ;; esac
  driver_foreground present
  out=$(deck_verdict)
  [ "$out" = alive ] || fail "live Deck driver was not alive: $out"
  "$BUSY_EVENT" apply "$dir/state" t1 busy --gen "$gen" --source deck-wrapper --event turn-start
  "$BUSY_EVENT" progress "$dir/state" t1 --gen "$gen"
  [ "$(deck_verdict)" = alive ] || fail "busy Deck driver was not alive"
  fm_test_fake_stream_set "$target" '{"stale": true}'
  [ "$(deck_verdict)" = unreadable ] || fail "a stale endpoint reading became alive"
  fm_test_fake_stream_set "$target" '{"stale": false}'
  printf '/quit\n' >&8
  wait "$driver" || fail "driver did not exit cleanly"
  exec 8>&-
  # The driver exited and its shell is back: busy records left behind by its
  # last turn do not make the task alive, whatever kind it is.
  driver_foreground absent
  for kind in secondmate ship scout; do
    { grep -v '^kind=' "$dir/state/t1.meta"; printf 'kind=%s\n' "$kind"; } > "$dir/t1.meta" \
      && mv "$dir/t1.meta" "$dir/state/t1.meta"
    out=$(deck_verdict)
    [ "$out" = dead ] || fail "absent Deck $kind driver became $out"
  done
  fm_test_fake_stream_set "$target" '{"forget": true}'
  [ "$(deck_verdict)" = missing ] || fail "a forgotten endpoint became alive"
  pass "stream Deck recovery reads the reported driver; stale busy records never make it alive"
}

# The steering doorbell for a remote Deck secondmate rings for a LIVE driver
# and skips an absent one: the ring's liveness read resolves the task's
# metadata in the SUPPLIED state directory (the parent-route root), never in
# the ambient home state. Real ring library, real inbox record; the endpoint is
# a fake stream endpoint whose reported foreground is the driver or a shell.
test_stream_deck_ring_rings_live_driver() {
  local dir="$TMP_ROOT/stream-ring" rec rc target
  local route="$TMP_ROOT/stream-ring-route" ambient="$TMP_ROOT/stream-ring-home/state"
  mkdir -p "$dir" "$route" "$ambient"
  : > "$dir/typed.log"
  # The meta lives ONLY in the parent-route root; the ambient home state that a
  # caller forgetting the supplied directory would search holds nothing.
  { fm_test_stream_task "$route" t1 "$dir/typed.log"; printf 'harness=deck\nkind=secondmate\n'; } > "$route/t1.meta" \
    || fail "could not register the Deck endpoint"
  target=$(sed -n 's/^window=//p' "$route/t1.meta")
  ring() {  # -> ring return code
    local rc=0
    FM_HOME="$TMP_ROOT/stream-ring-home" FM_ROOT_OVERRIDE="$ROOT" \
      bash -c '. "$1/bin/fm-task-inbox-lib.sh"
        rec=$2 state=$3 target=$4
        fm_task_inbox_ring stream "$target" "$rec" fm-t1 deck "$state" t1' \
      _ "$ROOT" "$(find "$route/t1.inbox" -maxdepth 1 -name '*.msg' | sort | head -1)" "$route" "$target" || rc=$?
    return "$rc"
  }
  # The inbox record the doorbell announces must exist under the route root.
  rec=$(FM_STATE_OVERRIDE="$route" bash -c '
    . "$1/bin/fm-task-inbox-lib.sh"
    fm_task_inbox_write_idempotent "$2" t1 "please continue"' _ "$ROOT" "$route") \
    || fail "ring fixture: inbox record could not be written"
  case "$rec" in "$route"/*) ;; *) fail "ring fixture: record landed outside the route root: $rec" ;; esac
  # DEAD FIRST: the endpoint's foreground is its shell, so nothing may be typed.
  fm_test_fake_stream_set "$target" '{"foreground": [{"pid": "", "name": "zsh", "argv0": "zsh", "args": "zsh"}]}'
  ring; rc=$?
  [ "$rc" = 3 ] || fail "absent driver must skip the doorbell (rc 3), got $rc"
  [ ! -s "$dir/typed.log" ] || fail "the doorbell typed into a dead endpoint:"$'\n'"$(cat "$dir/typed.log")"
  # A live driver: the doorbell RINGS, naming the parent-route inbox.
  fm_test_fake_stream_set "$target" \
    '{"foreground": [{"pid": "", "name": "bash", "argv0": "fm-deck-worker", "args": "fm-deck-worker"}]}'
  ring; rc=$?
  [ "$rc" = 0 ] || fail "a live remote Deck driver must be rung, got rc $rc"
  grep -q 'Firstmate instruction waiting' "$dir/typed.log" \
    || fail "the doorbell text never reached the live driver's endpoint:"$'\n'"$(cat "$dir/typed.log")"
  grep -q "$route/t1.inbox" "$dir/typed.log" \
    || fail "the doorbell announced a path outside the parent-route root:"$'\n'"$(cat "$dir/typed.log")"
  # A captain-direct record also reaches the driver's live, steerable Deck turn.
  local turn number
  turn=$(python3 "$ROOT/bin/fm_stream_deck.py" start "$route" t1 "$(printf '%032d' 0)" live 1) \
    || fail "ring fixture: no live turn"
  rec=$(bash -c '. "$1/bin/fm-task-inbox-lib.sh"
    fm_task_inbox_write "$2" t1 "$(printf "[fm-captain-direct]\342\201\243note\n\nhello from the captain")"' _ "$ROOT" "$route") \
    || fail "ring fixture: captain record could not be written"
  ring; rc=$?
  [ "$rc" = 0 ] || fail "a live Deck driver must still be rung for a captain record, got rc $rc"
  number=$(basename "$rec" .msg); number=$((10#$number))
  grep -q 'hello from the captain' "$turn/$number.msg" 2>/dev/null \
    || fail "the captain's record did not reach the live Deck turn: $(ls "$turn")"
  pass "the steering doorbell rings a live remote Deck driver and skips an absent one"
}

test_deck_supervision_model_is_scoped_to_secondmate_launches() {
  local bin="$TMP_ROOT/named-model" out
  mkdir -p "$bin"
  ln -sf /bin/bash "$bin/deck"
  # shellcheck disable=SC2016 # the quoted body expands inside the named shell
  out=$(env -u FM_SUPERVISION_MODEL "$bin/deck" -c '. "$1"; fm_supervision_model; :' \
    _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = persistent ] || fail "a Deck-named main process received the secondmate supervision model: $out"
  out=$(FM_SUPERVISION_MODEL=autoarm bash -c '. "$1"; fm_supervision_model' \
    _ "$ROOT/bin/fm-wake-lib.sh")
  [ "$out" = autoarm ] || fail "the scoped Deck secondmate supervision override was ignored: $out"
  pass "Deck supervision autoarm remains scoped to secondmate launches"
}

# --- spawn ------------------------------------------------------------------
make_deck_spawn_case() {  # <name> <id> -> "<case>|<home>|<proj>|<wt>|<fakebin>"
  local name=$1 id=$2 case_dir home proj wt fakebin
  case_dir="$TMP_ROOT/$name"; home="$case_dir/home"; proj="$case_dir/project"; wt="$case_dir/wt"
  # The task's endpoint comes from the suite's fake stream hub; its agent stub
  # logs every typed text to launch.log (FM_FAKE_LAUNCH_LOG).
  fakebin=$(fm_test_make_spawn_fakebin "$case_dir/fake") || fail "the fake stream hub did not start"
  printf '#!/usr/bin/env bash\necho "fake deck must never execute" >&2; exit 9\n' > "$fakebin/deck"
  chmod +x "$fakebin/deck"
  fm_fake_exit0 "$fakebin" treehouse gh-axi gh
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf '# Task\n## Captain'"'"'s intent\nExercise Deck dispatch.\n\n## Firstmate spec\nVerify launch.\n' > "$home/data/$id/brief.md"
  fm_git_worktree "$proj" "$wt" "wt-$name"
  touch "$home/state/.last-watcher-beat"
  : > "$case_dir/launch.log"
  printf '%s\n' "$case_dir|$home|$proj|$wt|$fakebin"
}

JQ_DIR=$(dirname "$(command -v jq)")
run_deck_spawn() {  # <case> <home> <proj> <wt> <fakebin> <id> [args...]
  local case_dir=$1 home=$2 proj=$3 wt=$4 fakebin=$5 id=$6
  shift 6
  HOME="$home" FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$wt" \
    FM_FAKE_LAUNCH_LOG="$case_dir/launch.log" \
    PATH="$fakebin:$JQ_DIR:$(dirname "$(command -v python3)"):$(dirname "$(command -v curl)"):/usr/bin:/bin:/usr/sbin:/sbin" \
    "$SPAWN" "$id" "$proj" --harness deck --mode no-mistakes --yolo off "$@" 2>&1
}

test_spawn_launches_the_driver_with_binary_gen_and_model() {
  local id rec out rc launch meta case_dir home proj wt fakebin
  id="deck-launch-$$"
  rec=$(make_deck_spawn_case launch "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_deck_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" --model codex/gpt-5.6-luna)
  rc=$?
  expect_code 0 "$rc" "ordinary Deck spawn should succeed: $out"
  launch=$(cat "$case_dir/launch.log")
  assert_contains "$launch" "exec -a fm-deck-worker bash" "the driver must run under its own argv[0]"
  assert_contains "$launch" "$ROOT/bin/fm-deck-worker.sh" "the launch did not run the deck driver"
  assert_contains "$launch" "--deck '$fakebin/deck'" "the launch did not pin the resolved deck binary"
  assert_contains "$launch" "--model 'codex/gpt-5.6-luna'" "the launch did not carry the model"
  assert_contains "$launch" "--id '$id'" "the launch did not name the task"
  assert_not_contains "$launch" "--turnend" "the launch passed a redundant turn-end path"
  assert_not_contains "$launch" "--effort" "deck has no effort control; effort must not be passed"
  assert_not_contains "$launch" "__DECK" "the launch left a deck placeholder unsubstituted"
  meta="$home/state/$id.meta"
  assert_grep 'harness=deck' "$meta" "meta did not record the deck harness"
  assert_grep 'effort=default' "$meta" "meta must not imply Deck applies an effort"
  [ -s "$home/state/$id.busy-gen" ] || fail "the spawn did not arm the busy contract"
  assert_contains "$launch" "--gen '$(cat "$home/state/$id.busy-gen")'" "the launch did not carry the armed busy gen"
  pass "fm-spawn: ordinary Deck dispatch records only default effort"
}

test_spawn_refuses_deck_effort() {
  local id rec out rc case_dir home proj wt fakebin
  id="deck-effort-$$"
  rec=$(make_deck_spawn_case effort "$id")
  IFS='|' read -r case_dir home proj wt fakebin <<EOF
$rec
EOF
  out=$(run_deck_spawn "$case_dir" "$home" "$proj" "$wt" "$fakebin" "$id" --effort high)
  rc=$?
  [ "$rc" -ne 0 ] || fail "Deck spawn accepted unsupported effort control"
  assert_contains "$out" "deck has no effort control" "the Deck effort refusal must explain the unsupported axis"
  [ ! -s "$case_dir/launch.log" ] || fail "Deck effort refusal launched a worker"
  [ ! -e "$home/state/$id.meta" ] || fail "Deck effort refusal wrote misleading task metadata"
  pass "fm-spawn: Deck refuses unsupported effort before launch metadata"
}


# A secondmate host fixture: a stub home, a stub session start, a stub watcher
# arm whose result is released by a trigger file, and a fake deck that records
# each turn's prompt, session, resumption, and drained inbox. A `fail-turn` file
# makes the next turn fail the way a gateway or quota refusal does, a
# `no-session` file makes it fail before Deck creates a session at all, the way
# a missing gateway key does, and an `unsafe-status` file additionally makes the
# parent status unwritable so the driver cannot record that failure.
make_secondmate_host_fixture() {  # <dir>
  local dir=$1
  mkdir -p "$dir/home/state" "$dir/home/config" "$dir/parent" "$dir/bin"
  cp -R "$ROOT/bin/." "$dir/bin/"
  cat > "$dir/bin/fm-session-start.sh" <<'SH'
#!/usr/bin/env bash
printf 'startup\n' >> "$FM_HOME/startups"
[ "${FM_TEST_START_FAIL:-0}" = 0 ] || exit 7
"$(dirname "$0")/fm-lock.sh"
cat "$FM_HOME/state/.lock" > "$FM_HOME/state/.session-start-complete"
printf 'complete startup digest marker\n'
SH
  cat > "$dir/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  if [ -f "$FM_HOME/refuse-next-handling" ]; then
    rm -f "$FM_HOME/refuse-next-handling"
    printf 'generation=%s watcher=%s\n' "$2" "$4" >> "$FM_HOME/handling-refused"
    exit 1
  fi
  printf 'generation=%s watcher=%s\n' "$2" "$4" >> "$FM_HOME/handling-delivered"
  exit 0
fi
trap 'exit 143' TERM INT
printf '%s\n' "$$" >> "$FM_HOME/watch-starts"
printf 'arm=%s predecessor=%s\n' "$$" "${FM_WATCH_PREDECESSOR_ARM_PID:-none}" >> "$FM_HOME/watch-arms"
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ] && [ ! -f "$FM_HOME/generationless-next-watch" ]; then
  printf 'watcher: started pid=%s (beacon fresh) recovery-generation=deck-%s\n' "$$" "$FM_WATCH_PREDECESSOR_ARM_PID"
else
  rm -f "$FM_HOME/generationless-next-watch"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
fi
while [ ! -f "$FM_HOME/trigger" ]; do sleep 0.1; done
rm "$FM_HOME/trigger"
printf 'check: example\n'
[ "${FM_TEST_WATCH_FAIL:-0}" = 0 ]
SH
  cat > "$dir/home/config/x-mode.env" <<'SH'
if [ -f "$FM_HOME/block-next-watch" ]; then
  : > "$FM_HOME/watch-start-blocked"
  while [ ! -f "$FM_HOME/release-watch-start" ]; do sleep 0.05; done
  rm -f "$FM_HOME/block-next-watch" "$FM_HOME/release-watch-start" "$FM_HOME/watch-start-blocked"
fi
SH
  cat > "$dir/deck" <<'PYTHON'
#!/usr/bin/env python3
import json, os, pathlib, subprocess, sys, time
home = pathlib.Path(os.environ['FM_HOME'])
args = sys.argv[1:]
prompt = args[1]
session = args[args.index('--session') + 1] if '--session' in args else 'host-session'
inbox = pathlib.Path(__file__).parent / 'parent/host.inbox'
records = list(sorted(inbox.glob('*.msg'))) if 'Firstmate instruction waiting:' in prompt else []
body = ''.join(record.read_text() for record in records)
if records:
    deadline = time.time() + 2
    while time.time() < deadline:
        starts = (home / 'watch-starts').read_text().splitlines() if (home / 'watch-starts').exists() else []
        delivered = (home / 'handling-delivered').read_text().splitlines() if (home / 'handling-delivered').exists() else []
        if len(starts) >= 2 and delivered:
            break
        time.sleep(.05)
    assert len(starts) >= 2, 'next watcher cycle did not start before wake handling'
    assert delivered or (home / 'handling-refused').exists(), 'successor watcher handling was not confirmed before wake handling'
    (home / 'wake-turn-active').touch()
    time.sleep(2)
    successor = int((home / 'watch-starts').read_text().splitlines()[-1])
    if not (home / 'watch-start-blocked').exists():
        os.kill(successor, 0)
with (home / 'turns').open('a') as f:
    f.write(json.dumps({'prompt': prompt, 'session': session,
                        'resumed': '--session' in args, 'inbox': body,
                        'mcp_config_arguments': [args[i + 1] for i, arg in enumerate(args)
                                                 if arg == '--mcp-config']}) + '\n')
for record in records:
    record.rename(inbox / 'handled' / record.name)
if not (home / 'no-session').exists():
    print(json.dumps({'type': 'run_started', 'session': session}), flush=True)
if (home / 'fail-turn').exists():
    if (home / 'unsafe-status').exists():
        status = pathlib.Path(__file__).parent / 'parent/host.status'
        status.unlink(missing_ok=True)
        status.symlink_to(home / 'external-status')
    print(json.dumps({'type': 'run_failed', 'error': 'injected'}), flush=True)
    sys.exit(9)
if prompt == 'slow-steer':
    (home / 'in-turn').touch()
    while not (home / 'release').exists():
        time.sleep(.1)
for i, arg in enumerate(args):
    if arg == '--hook' and args[i+1].startswith('pre_complete='):
        result = subprocess.run(args[i+1].split('=', 1)[1], shell=True)
        if result.returncode:
            sys.exit(result.returncode)
print(json.dumps({'type': 'run_finished', 'turns': 1}), flush=True)
PYTHON
  chmod +x "$dir/bin/fm-session-start.sh" "$dir/bin/fm-watch-arm.sh" "$dir/deck"
}

test_secondmate_mcp_config_on_startup_steer_and_wake() {
  local dir="$TMP_ROOT/host-mcp"
  make_secondmate_host_fixture "$dir"
  printf '{"servers":{}}\n' > "$dir/home/config/deck-mcp.json"
  python3 - "$dir" <<'PYTHON' || fail "Deck secondmate MCP config integration failed"
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
home = root / 'home'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker',
       str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'),
       '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
def rows():
    path = home/'turns'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
def idle():
    path = root/'parent/host.busy-state'
    return path.exists() and 'state=idle' in path.read_text()
def wait_for(check, label):
    deadline = time.monotonic() + 240
    while time.monotonic() < deadline:
        if check(): return
        if p.poll() is not None: raise AssertionError(label+': '+(root/'pane').read_text())
        time.sleep(.1)
    raise AssertionError(label+': '+(root/'pane').read_text())
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT,
                         env=env, text=True, start_new_session=True)
    try:
        wait_for(lambda: len(rows()) == 1 and idle(), 'startup turn')
        p.stdin.write('ordinary-steer\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 2 and idle(), 'steer turn')
        (home/'trigger').touch()
        wait_for(lambda: len(rows()) == 3 and idle(), 'watcher turn')
        assert rows()[1]['prompt'] == 'ordinary-steer'
        assert 'Firstmate instruction waiting:' in rows()[2]['prompt']
        assert all(row['mcp_config_arguments'] == [str(home/'config/deck-mcp.json')] for row in rows()), rows()
        for kind, row in zip(['startup', 'steer', 'watcher-wake'], rows()):
            print(json.dumps({'case': 'secondmate-'+kind, 'resumed': row['resumed'],
                              'mcp_config_arguments': row['mcp_config_arguments']}))
        p.stdin.write('/quit\n'); p.stdin.flush()
        assert p.wait(timeout=60) == 0
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try: p.wait(timeout=30)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
PYTHON
  pass "Deck secondmate uses its own MCP config on startup, ordinary steering, and watcher turns"
}

test_secondmate_host_serializes_wakes_and_steering() {
  local dir="$TMP_ROOT/host"
  make_secondmate_host_fixture "$dir"
  # A working ship record must not opt a home-host driver into worker polling.
  make_pipeline_case "$dir/pipeline"
  fm_write_meta "$dir/parent/host.meta" "window=fm:fm-host" "worktree=$dir/pipeline/wt" "kind=ship"
  cp "$dir/pipeline/fakebin/no-mistakes" "$dir/bin/no-mistakes"
  python3 - "$dir" <<'PYTHON' || fail "Deck secondmate host integration failed"
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
home = root / 'home'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='',
           FM_TEST_NM_RUN=str(root/'pipeline/nm-run'), PATH=str(root/'bin')+os.pathsep+os.environ['PATH'])
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
def rows():
    path = home/'turns'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
def watcher_starts():
    path = home/'watch-starts'
    return path.read_text().splitlines() if path.exists() else []
def wait_for(check, label):
    for _ in range(200):
        if check(): return
        if p.poll() is not None: raise AssertionError('host exited: '+(root/'pane').read_text())
        time.sleep(.1)
    raise AssertionError(label+': '+(root/'pane').read_text())
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env, text=True, start_new_session=True, preexec_fn=lambda: signal.signal(signal.SIGINT, signal.SIG_DFL))
    try:
        wait_for(lambda: len(rows()) == 1, 'first turn')
        assert 'complete startup digest marker' in rows()[0]['prompt']
        assert not (root/'parent/host.turn-ended').exists(), 'silent startup emitted a parent turn-end wake'
        p.stdin.write('slow-steer\n'); p.stdin.flush()
        wait_for(lambda: (home/'in-turn').exists(), 'steer start')
        (home/'trigger').touch()
        time.sleep(.5)
        assert len(rows()) == 2, 'watcher ran a concurrent turn'
        (home/'release').touch()
        wait_for(lambda: (home/'wake-turn-active').exists(), 'deferred wake turn start')
        deliveries_before_block = (home/'handling-delivered').read_text().splitlines()
        (home/'block-next-watch').touch()
        (home/'trigger').touch()
        wait_for(lambda: (home/'watch-start-blocked').exists(), 'blocked mid-turn watcher successor')
        wait_for(lambda: len(rows()) == 3, 'long handling turn completion')
        deadline = time.time() + 2
        while time.time() < deadline:
            assert (home/'handling-delivered').read_text().splitlines() == deliveries_before_block, 'predecessor handoff was accepted as the blocked successor'
            time.sleep(.05)
        (home/'wake-turn-active').unlink()
        (home/'release-watch-start').touch()
        wait_for(lambda: len(watcher_starts()) >= 3, 'blocked mid-turn watcher successor release')
        wait_for(lambda: (home/'wake-turn-active').exists(), 'queued wake turn start')
        (home/'trigger').touch()
        wait_for(lambda: len(watcher_starts()) >= 4, 'queued-turn watcher successor')
        assert len(rows()) == 3, 'mid-turn watcher wake ran a concurrent Deck turn'
        assert 'Firstmate instruction waiting:' in rows()[2]['prompt']
        assert 'actionable wake' in rows()[2]['inbox']
        assert list((root/'parent/host.inbox/handled').glob('*.msg'))
        assert 'predecessor=none' not in (home/'watch-arms').read_text().splitlines()[1], 'successor lost its predecessor arm'
        wait_for(lambda: len(rows()) == 5, 'queued mid-turn wakes')
        assert 'Firstmate instruction waiting:' in rows()[3]['prompt']
        assert 'Firstmate instruction waiting:' in rows()[4]['prompt']
        deliveries = (home/'handling-delivered').read_text().splitlines()
        assert len(deliveries) >= 3, 'latest handling successor was not confirmed'
        assert deliveries[-1].split(' watcher=', 1)[1] == watcher_starts()[-1], 'predecessor handoff was accepted instead of the current successor'
        assert not (root/'parent/host.turn-ended').exists(), 'watch handling emitted a parent turn-end wake'
        deliveries_before_generationless = list(deliveries)
        (home/'generationless-next-watch').touch()
        (home/'trigger').touch()
        wait_for(lambda: len(watcher_starts()) >= 5, 'generationless watcher successor')
        wait_for(lambda: len(rows()) == 6, 'generationless successor wake')
        assert p.poll() is None, 'generationless watcher successor stopped the host'
        assert (home/'handling-delivered').read_text().splitlines() == deliveries_before_generationless, 'generationless successor attempted a recovery delivery handshake'
        p.stdin.write('split-'); p.stdin.flush()
        time.sleep(1.3)
        p.stdin.write('steer\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 7, 'partial input retained')
        assert rows()[6]['prompt'] == 'split-steer'
        (home/'trigger').touch()
        wait_for(lambda: len(rows()) == 8, 'watcher rearmed')
        assert all(x['session'] == 'host-session' for x in rows())
        assert (home/'startups').read_text() == 'startup\n'
        assert (home/'state/.lock').read_text().strip() == str(p.pid), 'lock is not driver-owned'
        assert not (root/'parent/host.status').exists(), 'idle supervisor manufactured status'
        assert not (root/'pipeline/nm-queries.log').exists(), 'home-host driver polled a worker pipeline'
        (home/'in-turn').unlink()
        (home/'release').unlink()
        p.stdin.write('slow-steer\n'); p.stdin.flush()
        wait_for(lambda: (home/'in-turn').exists(), 'interruptible steer')
        os.killpg(p.pid, signal.SIGINT)
        p.stdin.write('after-interrupt\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 10, 'driver survived interrupt')
        assert rows()[9]['prompt'] == 'after-interrupt'
        assert 'turn interrupted' in (root/'parent/host.status').read_text()
        (home/'trigger').touch()
        wait_for(lambda: len(rows()) == 11, 'watcher survived interrupt')
        rows_before_exit = len(rows())
        starts_before_exit = len(watcher_starts())
        (home/'in-turn').unlink()
        p.stdin.write('slow-steer\n'); p.stdin.flush()
        wait_for(lambda: (home/'in-turn').exists(), 'exit-race turn start')
        assert len(rows()) == rows_before_exit + 1
        (home/'trigger').touch()
        wait_for(lambda: len(watcher_starts()) > starts_before_exit, 'exit-race watcher successor')
        p.stdin.write('/quit\n'); p.stdin.flush()
        time.sleep(.3)
        (home/'release').touch()
        assert p.wait(timeout=15) == 0
        assert len(rows()) == rows_before_exit + 1, 'queued exit ran a watcher turn before stopping the host'
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
for key in ['FM_TEST_START_FAIL', 'FM_TEST_WATCH_FAIL']:
    failure_env = dict(env, **{key: '1'})
    (root/'parent/host.status').unlink(missing_ok=True)
    (home/'trigger').touch()
    with (root/'failure-pane').open('w') as output:
        p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=failure_env, text=True)
        try:
            assert p.wait(timeout=20) != 0, key+' was swallowed'
            assert 'failed: Deck secondmate' in (root/'parent/host.status').read_text(), key+' not reported'
        finally:
            if p.poll() is None:
                p.terminate(); p.wait(timeout=15)
PYTHON
  pass "Deck host preserves handling-successor supervision without parent turn-end wakes"
}

test_secondmate_survives_a_failed_turn() {
  local dir="$TMP_ROOT/host-failed-turn"
  make_secondmate_host_fixture "$dir"
  python3 - "$dir" <<'PYTHON' || fail "a Deck secondmate did not survive a failed turn"
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
home = root / 'home'
status = root / 'parent/host.status'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
def rows():
    path = home/'turns'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
def failures():
    lines = status.read_text().splitlines() if status.exists() else []
    return [x for x in lines if x.startswith('failed: Deck secondmate turn failed')]
def wait_for(check, label):
    for _ in range(200):
        if check(): return
        if p.poll() is not None: raise AssertionError(label+' - host exited: '+(root/'pane').read_text())
        time.sleep(.1)
    raise AssertionError(label+': '+(root/'pane').read_text())
# A mate launched into a provider outage must reach its prompt, not die there.
(home/'fail-turn').touch()
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env, text=True, start_new_session=True)
    try:
        wait_for(lambda: len(rows()) == 1, 'failed first turn')
        wait_for(lambda: len(failures()) == 1, 'first-turn failure record')
        wait_for(lambda: 'event=turn-failed' in (root/'parent/host.busy-state').read_text(), 'first-turn busy record')
        record = (root/'parent/host.busy-state').read_text()
        assert 'state=idle' in record, record
        time.sleep(.5)
        assert p.poll() is None, 'the driver exited on a failed first turn: '+(root/'pane').read_text()
        (home/'fail-turn').unlink()
        p.stdin.write('after-first-failure\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 2, 'turn after a failed first turn')
        assert rows()[1]['prompt'] == 'after-first-failure'
        assert rows()[1]['resumed'], 'the surviving driver started a new Deck session'
        assert rows()[1]['session'] == rows()[0]['session'], 'the surviving driver lost its session identity'
        # A later turn fails the same way, and every failure stays published.
        (home/'fail-turn').touch()
        p.stdin.write('later-failure\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 3, 'failed later turn')
        wait_for(lambda: len(failures()) == 2, 'later-turn failure record')
        time.sleep(.5)
        assert p.poll() is None, 'the driver exited on a failed later turn: '+(root/'pane').read_text()
        # Staying at the prompt is only useful if the watcher still rings.
        (home/'fail-turn').unlink()
        (home/'trigger').touch()
        wait_for(lambda: len(rows()) == 4, 'watcher wake after a failed turn')
        assert 'Firstmate instruction waiting:' in rows()[3]['prompt']
        assert 'actionable wake' in rows()[3]['inbox']
        assert rows()[3]['resumed'], 'the watcher wake turn lost the session'
        p.stdin.write('/quit\n'); p.stdin.flush()
        assert p.wait(timeout=20) == 0, 'the surviving driver did not stop on /quit'
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
PYTHON
  pass "fm-deck-worker: a secondmate records a failed turn and waits at its prompt for the next wake"
}

test_secondmate_survives_a_refused_handling_confirmation() {
  local dir="$TMP_ROOT/host-refused-handling"
  make_secondmate_host_fixture "$dir"
  python3 - "$dir" <<'PYTHON' || fail "a Deck secondmate did not survive a refused handling confirmation"
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
home = root / 'home'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
def rows():
    path = home/'turns'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
def arms():
    path = home/'watch-arms'
    return path.read_text().splitlines() if path.exists() else []
def wait_for(check, label):
    for _ in range(200):
        if check(): return
        if p.poll() is not None: raise AssertionError(label+' - host exited: '+(root/'pane').read_text())
        time.sleep(.1)
    raise AssertionError(label+': '+(root/'pane').read_text())
with (root/'pane').open('w') as output, (root/'stderr').open('w') as errors:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=errors, env=env, text=True, start_new_session=True)
    try:
        wait_for(lambda: len(rows()) == 1, 'first turn')
        # The successor watcher of the next wake refuses its handoff, the way
        # a watcher that died or a recovery episode that moved on does: the
        # driver must replace its watcher and still handle the queued wake.
        (home/'refuse-next-handling').touch()
        (home/'trigger').touch()
        wait_for(lambda: (home/'handling-refused').exists(), 'refused handling confirmation')
        wait_for(lambda: len(rows()) == 2, 'wake turn after a refused confirmation')
        assert 'Firstmate instruction waiting:' in rows()[1]['prompt']
        assert 'actionable wake' in rows()[1]['inbox']
        assert p.poll() is None, 'the driver exited on a refused confirmation: '+(root/'pane').read_text()
        assert 'replacing the watcher' in (root/'stderr').read_text(), 'the refusal was not logged to stderr'
        assert 'replacing the watcher' not in (root/'pane').read_text(), 'the refusal leaked into stdout'
        assert arms()[-1].endswith('predecessor=none'), 'the replacement watcher claimed the refused predecessor'
        refused_pid = int((home/'handling-refused').read_text().split('watcher=', 1)[1].strip())
        try:
            os.kill(refused_pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError('the refused watcher was left running beside its replacement')
        status = (root/'parent/host.status').read_text() if (root/'parent/host.status').exists() else ''
        assert not any(x.startswith('failed:') for x in status.splitlines()), 'a recovered refusal was published as a failure'
        # The replacement still rings and the driver retains its Deck session.
        (home/'trigger').touch()
        wait_for(lambda: len(rows()) == 3, 'wake through the replacement watcher')
        assert 'actionable wake' in rows()[2]['inbox'], 'the replacement wake was not delivered'
        assert all(x['resumed'] and x['session'] == rows()[0]['session'] for x in rows()[1:]), 'the refusal lost the Deck session'
        p.stdin.write('/quit\n'); p.stdin.flush()
        assert p.wait(timeout=20) == 0, 'the surviving driver did not stop on /quit'
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
PYTHON
  pass "fm-deck-worker: a secondmate replaces its watcher when the successor refuses its handoff"
}

test_secondmate_repeats_its_launch_brief_after_a_session_less_failure() {
  local dir="$TMP_ROOT/host-no-session"
  make_secondmate_host_fixture "$dir"
  python3 - "$dir" <<'PYTHON' || fail "a Deck secondmate lost its launch brief when a failure opened no session"
import json, os, pathlib, signal, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
home = root / 'home'
status = root / 'parent/host.status'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
def rows():
    path = home/'turns'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
def failures():
    lines = status.read_text().splitlines() if status.exists() else []
    return [x for x in lines if x.startswith('failed: Deck secondmate turn failed')]
def wait_for(check, label):
    for _ in range(200):
        if check(): return
        if p.poll() is not None: raise AssertionError(label+' - host exited: '+(root/'pane').read_text())
        time.sleep(.1)
    raise AssertionError(label+': '+(root/'pane').read_text())
# Deck fails before it creates a session, the way a missing gateway key does, so
# nothing carries the launch brief into a conversation.
(home/'no-session').touch()
(home/'fail-turn').touch()
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env, text=True, start_new_session=True)
    try:
        wait_for(lambda: len(rows()) == 1, 'failed first turn with no session')
        wait_for(lambda: len(failures()) == 1, 'session-less failure record')
        wait_for(lambda: 'event=turn-failed' in (root/'parent/host.busy-state').read_text(), 'session-less busy record')
        assert 'complete startup digest marker' in rows()[0]['prompt'], rows()[0]['prompt']
        assert not rows()[0]['resumed']
        time.sleep(.5)
        assert p.poll() is None, 'the driver exited on a session-less first turn: '+(root/'pane').read_text()
        (home/'fail-turn').unlink()
        (home/'no-session').unlink()
        p.stdin.write('first-wake\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 2, 'turn after a session-less failure')
        # The parked mate still takes the helm: the retained launch brief travels
        # with the wake, and the session that turn opens is the one kept.
        assert 'complete startup digest marker' in rows()[1]['prompt'], rows()[1]['prompt']
        assert 'first-wake' in rows()[1]['prompt'], rows()[1]['prompt']
        assert not rows()[1]['resumed'], 'the driver resumed a session Deck never opened'
        assert rows()[1]['session'] == 'host-session', rows()[1]
        p.stdin.write('second-wake\n'); p.stdin.flush()
        wait_for(lambda: len(rows()) == 3, 'turn after the repeated launch brief')
        assert rows()[2]['resumed'], 'the session opened by the repeated launch brief was not kept'
        assert rows()[2]['session'] == rows()[1]['session'], rows()[2]
        assert rows()[2]['prompt'] == 'second-wake', 'the launch brief was repeated after it reached a session'
        assert len(failures()) == 1, status.read_text()
        p.stdin.write('/quit\n'); p.stdin.flush()
        assert p.wait(timeout=20) == 0, 'the surviving driver did not stop on /quit'
    finally:
        if p.poll() is None:
            os.killpg(p.pid, signal.SIGTERM)
            try:
                p.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(p.pid, signal.SIGKILL); p.wait()
PYTHON
  pass "fm-deck-worker: a secondmate with no session repeats its launch brief on the next wake"
}

test_secondmate_stops_when_a_repeated_launch_brief_opens_no_session() {
  local dir="$TMP_ROOT/host-no-session-twice"
  make_secondmate_host_fixture "$dir"
  python3 - "$dir" <<'PYTHON' || fail "a Deck secondmate parked forever without ever opening a session"
import json, os, pathlib, subprocess, sys, time
root = pathlib.Path(sys.argv[1])
home = root / 'home'
status = root / 'parent/host.status'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
def rows():
    path = home/'turns'
    return [json.loads(x) for x in path.read_text().splitlines()] if path.exists() else []
def wait_for(check, label):
    for _ in range(200):
        if check(): return
        if p.poll() is not None: raise AssertionError(label+' - host exited: '+(root/'pane').read_text())
        time.sleep(.1)
    raise AssertionError(label+': '+(root/'pane').read_text())
(home/'no-session').touch()
(home/'fail-turn').touch()
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env, text=True)
    try:
        wait_for(lambda: len(rows()) == 1, 'failed first turn with no session')
        time.sleep(.5)
        assert p.poll() is None, 'the driver exited before repeating its launch brief: '+(root/'pane').read_text()
        p.stdin.write('next-wake\n'); p.stdin.flush()
        assert p.wait(timeout=30) != 0, 'the driver kept parking with no session at all'
    finally:
        if p.poll() is None:
            p.terminate(); p.wait(timeout=15)
pane = (root/'pane').read_text()
turns = rows()
assert len(turns) == 2, turns
assert 'next-wake' in turns[1]['prompt'], turns[1]['prompt']
assert 'complete startup digest marker' in turns[1]['prompt'], 'the repeated turn lost the launch digest'
lines = status.read_text().splitlines()
assert len([x for x in lines if x.startswith('failed: Deck secondmate turn failed')]) == 2, lines
assert any(x.startswith('failed: Deck secondmate opened no Deck session') for x in lines), lines
assert 'event=turn-failed' in (root/'parent/host.busy-state').read_text(), 'the stopping failure skipped its busy record'
assert 'stopping for a guarded relaunch' in pane, pane
PYTHON
  pass "fm-deck-worker: a secondmate that cannot open a session stops for the guarded relaunch"
}

test_secondmate_stops_when_a_failed_turn_cannot_be_recorded() {
  local dir="$TMP_ROOT/host-unrecordable-failure"
  make_secondmate_host_fixture "$dir"
  python3 - "$dir" <<'PYTHON' || fail "a Deck secondmate kept running without recording its failure"
import os, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
home = root / 'home'
env = dict(os.environ, FM_HOME=str(home), FM_ROOT_OVERRIDE='', FM_STATE_OVERRIDE='', FM_CONFIG_OVERRIDE='')
gen = subprocess.check_output([str(root/'bin/fm-busy-event.sh'), 'arm', str(root/'parent'), 'host'], text=True).strip()
cmd = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker', str(root/'bin/fm-deck-worker.sh'), '--secondmate', '--id', 'host', '--state', str(root/'parent'), '--gen', gen, '--deck', str(root/'deck'), '--', 'charter']
(home/'fail-turn').touch()
(home/'unsafe-status').touch()
with (root/'pane').open('w') as output:
    p = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=output, stderr=subprocess.STDOUT, env=env, text=True)
    try:
        assert p.wait(timeout=30) != 0, 'the driver kept running on a failure it could not record'
    finally:
        if p.poll() is None:
            p.terminate(); p.wait(timeout=15)
pane = (root/'pane').read_text()
assert 'failed to publish secondmate failure' in pane, pane
assert not (home/'external-status').exists(), 'the failure publisher followed a symlink out of the state root'
assert 'event=turn-failed' in (root/'parent/host.busy-state').read_text(), 'the unrecordable failure skipped its busy record'
PYTHON
  pass "fm-deck-worker: a secondmate that cannot publish a failed turn stops instead of looping"
}

# A ship task bound to a real worktree, with a fake no-mistakes whose `axi
# status` serves the run object in <dir>/nm-run (rewritten mid-test), so the
# driver's pipeline wake reads the run through the real bin/fm-crew-state.sh.
make_pipeline_case() {  # <dir>
  local dir=$1 head
  make_fake_deck "$dir"
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/wt"
  fm_git_identity
  git -C "$dir/wt" init -q
  git -C "$dir/wt" commit -q --allow-empty -m init
  git -C "$dir/wt" checkout -q -b fm/t1
  fm_write_meta "$dir/state/t1.meta" "window=fm:fm-t1" "worktree=$dir/wt" "kind=ship"
  cat > "$dir/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
dir=$(dirname "$FM_TEST_NM_RUN")
printf '%s\n' "$*" >> "$dir/nm-queries.log"
[ ! -f "$dir/nm-unreadable" ] || exit 1
case "$1 ${2:-}" in
  'axi status')
    if [ -f "$dir/nm-delay" ]; then
      delay=$(cat "$dir/nm-delay")
      rm "$dir/nm-delay"
      : > "$dir/nm-probe-started"
      sleep "$delay"
    fi
    cat "$FM_TEST_NM_RUN" ;;
  'runs '*) [ ! -f "$(dirname "$FM_TEST_NM_RUN")/nm-runs" ] || cat "$(dirname "$FM_TEST_NM_RUN")/nm-runs" ;;
esac
exit 0
SH
  chmod +x "$dir/fakebin/no-mistakes"
  head=$(git -C "$dir/wt" rev-parse HEAD)
  printf '%s' "$head" > "$dir/head"
  pipeline_run "$dir" running
}

pipeline_run() {  # <dir> <running|parked|passed|failed>
  local dir=$1 head extra=''
  head=$(cat "$dir/head")
  case "$2" in
    running) extra='  status: running' ;;
    parked) extra='  status: awaiting_approval
  awaiting_agent: parked 0m1s
gate: review' ;;
    passed) extra='  status: completed
outcome: passed' ;;
    failed) extra='  status: failed
outcome: failed' ;;
  esac
  printf 'run:\n  id: "01PIPE"\n  branch: fm/t1\n  head: "%s"\n  pr: ""\n  findings: none\n%s\n' \
    "$head" "$extra" > "$dir/nm-run.tmp"
  mv -f "$dir/nm-run.tmp" "$dir/nm-run"
}

start_pipeline_worker() {  # <dir> <poll-secs> <wait-secs>
  local dir=$1 gen
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  mkfifo "$dir/in"
  exec 3<>"$dir/in"
  # The validation record's follower would race these cases for the fake's
  # one-shot probe delay; the follower has its own case.
  PATH="$dir/fakebin:$PATH" FM_TEST_NM_RUN="$dir/nm-run" FM_TEST_STATUS="$dir/state/t1.status" \
    FM_DECK_PIPELINE_POLL_SECS=$2 FM_DECK_PIPELINE_WAIT_SECS=$3 FM_CREW_STATE_FOLLOW_MAX_SECS=0 \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" \
      --deck "$dir/deck" -- write-status < "$dir/in" > "$dir/pane.out" 2>&1 &
  PIPELINE_WORKER_PID=$!
  fm_test_track_helper_pid "$PIPELINE_WORKER_PID"
}

deck_runs() {  # <dir>
  wc -l < "$1/argv.log" 2>/dev/null | tr -d ' ' || printf '0'
}

wait_deck_runs() {  # <dir> <count>
  local _
  for _ in $(seq 300); do [ "$(deck_runs "$1")" -ge "$2" ] && return 0; sleep 0.1; done
  return 1
}

wait_pane_count() {  # <dir> <pattern> <count>
  local _
  for _ in $(seq 300); do [ "$(grep -c -- "$2" "$1/pane.out" 2>/dev/null)" -ge "$3" ] && return 0; sleep 0.1; done
  return 1
}

pipeline_evidence() {  # <dir>
  local dir=$1 evidence=${FM_TEST_DECK_EVIDENCE_DIR:-} file
  [ -n "$evidence" ] || return 0
  mkdir -p "$evidence/$(basename "$dir")"
  for file in pane.out argv.log nm-queries.log nm-run inconclusive-state.out state/t1.busy-state; do
    [ ! -f "$dir/$file" ] || cp "$dir/$file" "$evidence/$(basename "$dir")/$(basename "$file")"
  done
}

stop_pipeline_worker() {  # <dir>
  printf '/quit\n' >&3
  wait "$PIPELINE_WORKER_PID" 2>/dev/null
  exec 3>&-
  pipeline_evidence "$1"
}

test_pipeline_state_change_wakes_an_idle_worker_once() {
  local dir="$TMP_ROOT/pipeline-wake" wake
  make_pipeline_case "$dir"
  start_pipeline_worker "$dir" 1 600
  wait_pane_count "$dir" 'no-mistakes run 01PIPE still working' 1 \
    || fail "a turn that ended with its run working did not arm the pipeline wait: $(cat "$dir/pane.out")"
  [ "$(deck_runs "$dir")" = 1 ] || fail "the driver started a turn while the run was still working"
  pipeline_run "$dir" parked
  wait_deck_runs "$dir" 2 || fail "a run parked at a gate did not wake the idle worker: $(cat "$dir/pane.out")"
  wake=$(sed -n 2p "$dir/argv.log")
  assert_grep 'verdict=parked' "$dir/state/t1.crew-state" "the pipeline read did not publish the parked run"
  assert_contains "$wake" 'Your no-mistakes run 01PIPE changed state' "the wake did not name the run id"
  assert_contains "$wake" 'state: parked · source: run-step · parked at review' "the wake did not carry the run state"
  assert_contains "$wake" '--session s-fake-' "the wake did not resume the worker's Deck session"
  # The run stays parked: no working -> other transition, so no second wake.
  wait_pane_count "$dir" 'idle since' 2 || fail "the wake turn did not return to the prompt"
  sleep 3
  [ "$(deck_runs "$dir")" = 2 ] || fail "a run that stayed parked woke the worker again: $(cat "$dir/argv.log")"
  # A steer that leaves the run working re-arms, and the next change wakes once.
  pipeline_run "$dir" running
  printf 'answer write-status\n' >&3
  wait_deck_runs "$dir" 3 || fail "the steer did not start a turn"
  wait_pane_count "$dir" 'no-mistakes run 01PIPE still working' 2 || fail "the steer turn did not re-arm the wait"
  pipeline_run "$dir" passed
  wait_deck_runs "$dir" 4 || fail "a finished run did not wake the idle worker"
  assert_contains "$(sed -n 4p "$dir/argv.log")" 'state: done · source: run-step' "the second wake did not carry the done state"
  wait_pane_count "$dir" 'idle since' 4 || fail "the second wake turn did not return to the prompt"
  sleep 2
  [ "$(deck_runs "$dir")" = 4 ] || fail "a finished run woke the worker more than once"
  stop_pipeline_worker "$dir"
  pass "fm-deck-worker: a run leaving working wakes the idle worker once per change, naming run id and state"
}

test_a_no_mistakes_tool_call_publishes_the_validation_record() {
  local dir="$TMP_ROOT/pipeline-hook" gen _
  make_pipeline_case "$dir"
  cp "$dir/nm-run" "$dir/running-run"
  : > "$dir/nm-run"
  cat > "$dir/tool" <<'SH'
#!/usr/bin/env bash
set -eu
dir=$1
for _ in $(seq 100); do
  [ "$(grep -c 'axi status' "$dir/nm-queries.log" 2>/dev/null || true)" -ge 3 ] && break
  sleep 0.1
done
[ -d "$dir/state/.t1.crew-state-follow" ]
[ ! -f "$dir/state/t1.crew-state" ]
cp "$dir/running-run" "$dir/nm-run.tmp"
mv "$dir/nm-run.tmp" "$dir/nm-run"
for _ in $(seq 100); do
  if grep -q 'verdict=working' "$dir/state/t1.crew-state" 2>/dev/null; then
    : > "$dir/published-during-tool"
    exit 0
  fi
  sleep 0.1
done
exit 1
SH
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  printf '/quit\n' | PATH="$dir/fakebin:$PATH" FM_TEST_NM_RUN="$dir/nm-run" \
    FM_TEST_STATUS="$dir/state/t1.status" FM_DECK_PIPELINE_WAIT_SECS=0 \
    FM_CREW_STATE_FOLLOW_SECS=1 FM_CREW_STATE_FOLLOW_GRACE_SECS=3 FM_CREW_STATE_FOLLOW_MAX_SECS=20 \
    FM_TEST_TOOL_COMMAND="bash '$dir/tool' '$dir'" \
    FM_TEST_HOOK_EVENT='{"tool":"shell","input":{"command":"no-mistakes axi run --intent x"}}' \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" --deck "$dir/deck" -- write-status \
    > "$dir/pane.out" 2>&1 || fail "the driver did not exit cleanly: $(cat "$dir/pane.out")"
  [ -f "$dir/published-during-tool" ] || fail "the pre hook did not publish a delayed run during the blocking tool call"
  pipeline_run "$dir" passed
  for _ in $(seq 100); do grep -q 'verdict=done' "$dir/state/t1.crew-state" 2>/dev/null && [ ! -d "$dir/state/.t1.crew-state-follow" ] && break; sleep 0.1; done
  assert_grep 'run=01PIPE' "$dir/state/t1.crew-state" "a no-mistakes tool call did not publish the run's record"
  assert_grep 'verdict=done' "$dir/state/t1.crew-state" "the follower did not publish the finished run"
  [ ! -d "$dir/state/.t1.crew-state-follow" ] || fail "the follower outlived the run it followed"
  pass "fm-deck-worker: the pre hook follows a delayed run during a blocking tool call"
}

test_turn_end_follows_validation_with_automatic_wakes_disabled() {
  local dir="$TMP_ROOT/pipeline-follow-no-wake" gen _
  make_pipeline_case "$dir"
  gen=$("$BUSY_EVENT" arm "$dir/state" t1)
  mkfifo "$dir/in"
  exec 3<>"$dir/in"
  PATH="$dir/fakebin:$PATH" FM_TEST_NM_RUN="$dir/nm-run" FM_TEST_STATUS="$dir/state/t1.status" \
    FM_TEST_HOOK_EVENT='' FM_DECK_PIPELINE_WAIT_SECS=0 FM_CREW_STATE_FOLLOW_SECS=1 \
    FM_CREW_STATE_FOLLOW_GRACE_SECS=0 FM_CREW_STATE_FOLLOW_MAX_SECS=20 \
    "$WORKER" --id t1 --state "$dir/state" --gen "$gen" \
      --deck "$dir/deck" -- write-status < "$dir/in" > "$dir/pane.out" 2>&1 &
  PIPELINE_WORKER_PID=$!
  fm_test_track_helper_pid "$PIPELINE_WORKER_PID"
  wait_pane_count "$dir" 'idle since' 1 || fail "the turn never reached its idle prompt"
  for _ in $(seq 100); do
    [ -d "$dir/state/.t1.crew-state-follow" ] && break
    sleep 0.1
  done
  [ -d "$dir/state/.t1.crew-state-follow" ] || fail "turn end did not start the follower with automatic wakes disabled"
  assert_grep 'verdict=working' "$dir/state/t1.crew-state" "turn end did not publish the working run"
  pipeline_run "$dir" parked
  for _ in $(seq 100); do
    grep -q 'verdict=parked' "$dir/state/t1.crew-state" 2>/dev/null \
      && [ ! -d "$dir/state/.t1.crew-state-follow" ] && break
    sleep 0.1
  done
  assert_grep 'verdict=parked' "$dir/state/t1.crew-state" "the turn-end follower did not publish the returned gate"
  [ ! -d "$dir/state/.t1.crew-state-follow" ] || fail "the follower did not stop at the gate"
  [ "$(deck_runs "$dir")" = 1 ] || fail "the follower enabled an automatic next turn"
  assert_not_contains "$(cat "$dir/pane.out")" 'still working; the next turn' "a disabled wait armed an automatic wake"
  stop_pipeline_worker "$dir"
  pass "fm-deck-worker: turn end publishes and follows validation without enabling automatic wakes"
}

test_pipeline_omits_terminal_id_when_a_live_successor_is_working() {
  local dir="$TMP_ROOT/pipeline-successor" head successor wake
  make_pipeline_case "$dir"
  head=$(cat "$dir/head")
  git -C "$dir/wt" commit -q --allow-empty -m successor
  successor=$(git -C "$dir/wt" rev-parse HEAD)
  git -C "$dir/wt" reset -q --hard "$head"
  printf 'run:\n  id: "01STALE"\n  branch: fm/t1\n  head: "%s"\n  status: failed\noutcome: failed\n' \
    "$head" > "$dir/nm-run"
  printf 'failed fm/t1 %s 2026-08-05 11:20\nrunning fm/t1 %s 2026-08-05 10:05\n' \
    "$head" "$successor" > "$dir/nm-runs"
  start_pipeline_worker "$dir" 1 600
  wait_pane_count "$dir" 'no-mistakes run (id unavailable) still working' 1 \
    || fail "the live successor was not watched without the terminal run's id: $(cat "$dir/pane.out")"
  assert_not_contains "$(cat "$dir/pane.out")" 'run 01STALE still working' "the terminal run was named as working"
  pipeline_run "$dir" parked
  wait_deck_runs "$dir" 2 || fail "the successor parking did not wake the worker"
  wake=$(sed -n 2p "$dir/argv.log")
  assert_contains "$wake" 'Your no-mistakes run 01PIPE changed state' "the matching active run id was omitted"
  assert_contains "$wake" 'state: parked · source: run-step' "the wake lost the authoritative parked state"
  stop_pipeline_worker "$dir"
  pass "fm-deck-worker: a terminal run id is omitted when a live successor is working"
}

test_pipeline_wait_takes_input_immediately_and_is_bounded() {
  local dir="$TMP_ROOT/pipeline-steer" bounded="$TMP_ROOT/pipeline-bound"
  make_pipeline_case "$dir"
  start_pipeline_worker "$dir" 600 21600
  wait_pane_count "$dir" 'no-mistakes run 01PIPE still working' 1 || fail "the pipeline wait was not armed"
  printf 'steer write-status\n' >&3
  wait_deck_runs "$dir" 2 || fail "a steer waited behind the pipeline poll instead of starting a turn"
  assert_contains "$(sed -n 2p "$dir/argv.log")" 'steer write-status' "the steer was not delivered as typed"
  stop_pipeline_worker "$dir"
  kill -0 "$PIPELINE_WORKER_PID" 2>/dev/null && fail "/quit did not end a worker waiting on its pipeline"

  make_pipeline_case "$bounded"
  start_pipeline_worker "$bounded" 4 1
  wait_pane_count "$bounded" 'no-mistakes run 01PIPE still working' 1 || fail "the bounded wait was not armed"
  sleep 3
  pipeline_run "$bounded" parked
  sleep 3
  [ "$(deck_runs "$bounded")" = 1 ] || fail "the pipeline wait outlived its bound: $(cat "$bounded/argv.log")"
  stop_pipeline_worker "$bounded"
  pass "fm-deck-worker: typed input preempts the pipeline wait, /quit still exits, and the wait is bounded"
}

test_pipeline_failed_run_wakes_once() {
  local dir="$TMP_ROOT/pipeline-failed"
  make_pipeline_case "$dir"
  start_pipeline_worker "$dir" 1 30
  wait_pane_count "$dir" 'no-mistakes run 01PIPE still working' 1 || fail "the wait was not armed"
  pipeline_run "$dir" failed
  wait_deck_runs "$dir" 2 || fail "a failed run did not wake its worker"
  assert_contains "$(sed -n 2p "$dir/argv.log")" 'state: failed · source: run-step' "the wake omitted the failure state"
  wait_pane_count "$dir" 'idle since' 2 || fail "the failed-run wake did not finish"
  sleep 2
  [ "$(deck_runs "$dir")" = 2 ] || fail "a failed run re-woke without a working transition"
  stop_pipeline_worker "$dir"
  pass "fm-deck-worker: a failed run wakes once and stays idle afterward"
}

test_pipeline_inconclusive_read_keeps_watching() {
  local dir="$TMP_ROOT/pipeline-unreadable" before after line
  make_pipeline_case "$dir"
  start_pipeline_worker "$dir" 1 30
  wait_pane_count "$dir" 'no-mistakes run 01PIPE still working' 1 || fail "the wait was not armed"
  before=$(wc -l < "$dir/nm-queries.log")
  touch "$dir/nm-unreadable"
  line=$(PATH="$dir/fakebin:$PATH" FM_TEST_NM_RUN="$dir/nm-run" FM_STATE_OVERRIDE="$dir/state" "$ROOT/bin/fm-crew-state.sh" t1)
  assert_not_contains "$line" 'source: run-step' "the unreadable fixture still yielded a run-step"
  printf '%s\n' "$line" > "$dir/inconclusive-state.out"
  # At least three more polls (1s apart), however slow a loaded host makes each
  # state read; a watch that stopped never gets there.
  for _ in $(seq 100); do
    after=$(wc -l < "$dir/nm-queries.log")
    [ "$after" -gt "$((before + 2))" ] && break
    sleep 0.1
  done
  [ "$after" -gt "$((before + 2))" ] || fail "polling stopped after the inconclusive sample"
  [ "$(deck_runs "$dir")" = 1 ] || fail "an inconclusive sample woke the worker"
  pipeline_run "$dir" parked
  rm "$dir/nm-unreadable"
  wait_deck_runs "$dir" 2 || fail "the watch was lost when the reader recovered"
  wait_pane_count "$dir" 'idle since' 2 || fail "the recovered wake did not finish"
  stop_pipeline_worker "$dir"
  pass "fm-deck-worker: inconclusive reads neither wake nor abandon the watch"
}

test_pipeline_input_wins_during_state_probe() {
  local dir command _
  for command in /quit 'steer write-status'; do
    case "$command" in /quit) dir="$TMP_ROOT/pipeline-probe-quit" ;; *) dir="$TMP_ROOT/pipeline-probe-steer" ;; esac
    make_pipeline_case "$dir"
    start_pipeline_worker "$dir" 1 30
    wait_pane_count "$dir" 'no-mistakes run 01PIPE still working' 1 || fail "the wait was not armed"
    pipeline_run "$dir" parked
    printf '2\n' > "$dir/nm-delay"
    for _ in $(seq 100); do [ ! -f "$dir/nm-probe-started" ] || break; sleep 0.05; done
    [ -f "$dir/nm-probe-started" ] || fail "the delayed state probe never started"
    printf '%s\n' "$command" >&3
    if [ "$command" = /quit ]; then
      for _ in $(seq 100); do kill -0 "$PIPELINE_WORKER_PID" 2>/dev/null || break; sleep 0.05; done
      kill -0 "$PIPELINE_WORKER_PID" 2>/dev/null && fail "queued /quit did not exit after the probe"
      wait "$PIPELINE_WORKER_PID" || fail "queued /quit exited with a failure"
      exec 3>&-
      [ "$(deck_runs "$dir")" = 1 ] || fail "an automatic wake ran before queued /quit"
      pipeline_evidence "$dir"
    else
      wait_deck_runs "$dir" 2 || fail "the queued steer was not delivered"
      assert_contains "$(sed -n 2p "$dir/argv.log")" "$command" "an automatic wake took priority over the queued steer"
      wait_pane_count "$dir" 'idle since' 2 || fail "the steer did not finish"
      stop_pipeline_worker "$dir"
    fi
  done
  pass "fm-deck-worker: input queued during a state probe takes priority over an automatic wake"
}

test_pipeline_deadline_expiring_during_probe_does_not_wake() {
  local dir="$TMP_ROOT/pipeline-probe-bound" _
  make_pipeline_case "$dir"
  start_pipeline_worker "$dir" 1 4
  wait_pane_count "$dir" 'no-mistakes run 01PIPE still working' 1 || fail "the wait was not armed"
  pipeline_run "$dir" parked
  printf '5\n' > "$dir/nm-delay"
  for _ in $(seq 100); do [ ! -f "$dir/nm-probe-started" ] || break; sleep 0.05; done
  [ -f "$dir/nm-probe-started" ] || fail "the delayed state probe never started"
  sleep 6
  [ "$(deck_runs "$dir")" = 1 ] || fail "a state probe completing after the bound triggered a wake"
  stop_pipeline_worker "$dir"
  pass "fm-deck-worker: a state probe that outlives the deadline cannot trigger a turn"
}

test_pipeline_clear_and_doorbell_preempt_polling() {
  local dir="$TMP_ROOT/pipeline-clear-doorbell"
  make_pipeline_case "$dir"
  start_pipeline_worker "$dir" 600 21600
  wait_pane_count "$dir" 'no-mistakes run 01PIPE still working' 1 || fail "the wait was not armed"
  printf 'discard write-status\025\n' >&3
  wait_pane_count "$dir" 'idle since' 2 || fail "composer clear did not repaint immediately"
  [ "$(deck_runs "$dir")" = 1 ] || fail "composer clear submitted the discarded text"
  printf 'FIRSTMATE_OP: v1 inbox-doorbell write-status\n' >&3
  wait_deck_runs "$dir" 2 || fail "the inbox doorbell waited behind the poll interval"
  assert_contains "$(sed -n 2p "$dir/argv.log")" 'FIRSTMATE_OP: v1 inbox-doorbell write-status' "the doorbell prompt was changed"
  wait_pane_count "$dir" 'no-mistakes run 01PIPE still working' 2 || fail "the doorbell turn did not re-arm"
  stop_pipeline_worker "$dir"
  pass "fm-deck-worker: composer clear discards input and the doorbell preempts polling"
}

test_pipeline_disabled_scout_and_already_parked_do_not_wake() {
  local dir variant wait
  for variant in disabled scout parked; do
    dir="$TMP_ROOT/pipeline-no-watch-$variant"
    make_pipeline_case "$dir"
    wait=30
    case "$variant" in
      disabled) wait=0 ;;
      scout) fm_write_meta "$dir/state/t1.meta" "window=fm:fm-t1" "worktree=$dir/wt" "kind=scout" ;;
      parked) pipeline_run "$dir" parked ;;
    esac
    start_pipeline_worker "$dir" 1 "$wait"
    wait_pane_count "$dir" 'idle since' 1 || fail "$variant never reached its idle prompt"
    sleep 1
    pipeline_run "$dir" passed
    sleep 2
    [ "$(deck_runs "$dir")" = 1 ] || fail "$variant woke without arming a working transition"
    assert_not_contains "$(cat "$dir/pane.out")" 'still working; the next turn' "$variant armed a pipeline watch"
    stop_pipeline_worker "$dir"
  done
  pass "fm-deck-worker: disabled waits, scouts, and initially parked runs never arm a wake"
}

# Optional named cases and worker override support focused regressions against
# a previous executable without creating a second test rig.
if [ -n "${FM_TEST_DECK_CASES:-}" ]; then
  for test_case in $FM_TEST_DECK_CASES; do
    case "$test_case" in test_*) ;; *) fail "invalid test case: $test_case" ;; esac
    declare -F "$test_case" >/dev/null || fail "unknown test case: $test_case"
    "$test_case"
  done
  exit 0
fi

test_stream_deck_recovery
test_stream_deck_ring_rings_live_driver
test_idle_interrupt_does_not_echo_fake_input
test_secondmate_host_serializes_wakes_and_steering
test_secondmate_mcp_config_on_startup_steer_and_wake
test_secondmate_survives_a_failed_turn
test_secondmate_survives_a_refused_handling_confirmation
test_secondmate_repeats_its_launch_brief_after_a_session_less_failure
test_secondmate_stops_when_a_repeated_launch_brief_opens_no_session
test_secondmate_stops_when_a_failed_turn_cannot_be_recorded
test_turns_share_one_session_and_carry_the_hooks
test_turns_carry_the_home_mcp_config
test_mcp_config_directory_precedence_and_scout_scope
test_mcp_config_is_not_inherited_into_secondmate_homes
test_turns_drive_the_busy_record_and_turn_end
test_busy_state_failures_stop_turns_and_publish_status
test_turnend_signal_refuses_unsafe_paths
test_evidence_gate_refuses_a_turn_without_a_status_line
test_stderr_before_completion_blocked_does_not_break_rendering
test_bookkeeping_lines_do_not_satisfy_turn_evidence
test_finished_turn_renders_the_utc_completion_time
test_idle_prompt_notes_the_utc_idle_instant
test_status_checks_and_fallbacks_refuse_unsafe_paths
test_driver_backstops_silent_and_failed_turns
test_doorbell_for_an_empty_own_inbox_starts_no_turn
test_ctrl_c_cancels_the_turn_and_returns_to_the_prompt
test_completed_turn_removes_busy_ack_before_the_next_steer
test_driver_stop_terminates_active_deck_and_resolves_spaced_paths
test_stale_secondmate_driver_is_stopped_at_relaunch_boundary
test_driver_stop_is_scoped_and_escalates_after_timeout
test_liveness_reads_the_driver_as_an_agent
test_stream_liveness_uses_the_deck_driver_argv0
test_control_busy_and_delivery_tables_name_deck
test_deck_supervision_model_is_scoped_to_secondmate_launches
test_spawn_launches_the_driver_with_binary_gen_and_model
test_spawn_refuses_deck_effort
test_pipeline_state_change_wakes_an_idle_worker_once
test_a_no_mistakes_tool_call_publishes_the_validation_record
test_turn_end_follows_validation_with_automatic_wakes_disabled
test_pipeline_omits_terminal_id_when_a_live_successor_is_working
test_pipeline_wait_takes_input_immediately_and_is_bounded
test_pipeline_failed_run_wakes_once
test_pipeline_inconclusive_read_keeps_watching
test_pipeline_input_wins_during_state_probe
test_pipeline_deadline_expiring_during_probe_does_not_wake
test_pipeline_clear_and_doorbell_preempt_polling
test_pipeline_disabled_scout_and_already_parked_do_not_wake
echo "fm-deck-harness: all cases passed"
