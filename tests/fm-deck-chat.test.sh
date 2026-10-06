#!/usr/bin/env bash
# bin/fm-deck-chat.sh (the `deck chat` primary host) and bin/fm-primary-steer.sh.
# A fake `deck chat` honours --steer-dir/--events like the real one: it emits
# idle, turns each arriving <seq>.msg into run_started/steer_received/
# steer_acked/run_finished and moves it to handled/. Session start and the
# watcher arm are stubbed in a copied bin/; the lock, busy-state, steering and
# host lifecycle run unchanged. Never touches a live home.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-deck-chat)
BIN="$LAB/bundle/bin"
mkdir -p "$LAB/bundle" "$LAB/tools"
cp -R "$ROOT/bin" "$BIN"
STEER="$BIN/fm-primary-steer.sh"
export FM_DECK_CHAT_WATCH_BACKOFF=0.2

cat > "$BIN/fm-session-start.sh" <<'EOF'
#!/usr/bin/env bash
"$(dirname "$0")/fm-lock.sh" >/dev/null || exit 1
"$(dirname "$0")/fm-harness.sh" > "$FM_HOME/startup.harness"
case "${FM_TEST_STARTUP_COMPLETION:-complete}" in
  complete) cat "$FM_HOME/state/.lock" > "$FM_HOME/state/.session-start-complete" ;;
  wrong) echo 1 > "$FM_HOME/state/.session-start-complete" ;;
  missing) : ;;
esac
echo "fixture session digest"
[ "${FM_TEST_STARTUP_SLOW:-0}" != 1 ] || echo SLOW
echo started >> "$FM_HOME/session-start.runs"
EOF
cat > "$BIN/fm-watch-arm.sh" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --handling-delivered) exit 0 ;; esac
echo $$ >> "$FM_HOME/watch.pids"
echo "${FM_CHECK_INTERVAL:-300}" >> "$FM_HOME/watch.cadence"
echo "watcher: started pid=$$ (beacon fresh)"
while [ ! -e "$FM_HOME/wake.trigger" ]; do sleep 0.05; done
cat "$FM_HOME/wake.trigger"; rm -f "$FM_HOME/wake.trigger"
EOF
cat > "$LAB/tools/deck" <<'EOF'
#!/usr/bin/env python3
import json, os, pathlib, re, signal, subprocess, sys, time
argv = sys.argv[1:]
if argv[:1] == ['chat'] and '--help' in argv:
    print('--steer-dir <DIR>\n--events <FILE>\n--session <SESSION>')
    sys.exit(0)
assert argv[0] == 'chat', argv
def opt(name):
    return argv[argv.index(name) + 1]
steer, events = pathlib.Path(opt('--steer-dir')), pathlib.Path(opt('--events'))
hook = next(a.split('=', 1)[1] for a in argv if a.startswith('pre_complete='))
log = pathlib.Path(os.environ['FAKE_DECK_LOG'])
log.write_text(json.dumps({'argv': argv, 'pid': os.getpid(), 'cwd': os.getcwd()}))
stop = []
signal.signal(signal.SIGTERM, lambda *_: stop.append(1))
def emit(**event):
    with open(events, 'a') as handle:
        handle.write(json.dumps(event) + '\n')
emit(type='idle')
while not stop:
    for seq in sorted(int(p.name[:-4]) for p in steer.iterdir() if re.fullmatch(r'[1-9][0-9]*\.msg', p.name)):
        source = steer / ('%d.msg' % seq)
        text = source.read_text()
        emit(type='run_started', session=opt('--session'), model='fake')
        emit(type='steer_received', seq=seq, safe_point='run_start')
        if 'fixture session digest' in text and os.environ.get('FM_TEST_STARTUP_SLOW') == '1':
            while not (pathlib.Path(os.environ['FM_HOME']) / 'startup.release').exists() and not stop:
                time.sleep(0.05)
        elif 'SLOW' in text:
            time.sleep(3)
        hook_rc = subprocess.run(['sh', '-c', hook]).returncode
        (steer / 'handled').mkdir(exist_ok=True)
        source.rename(steer / 'handled' / source.name)
        emit(type='steer_acked', seq=seq)
        with open(str(log) + '.turns', 'a') as handle:
            handle.write(json.dumps({'seq': seq, 'text': text, 'hook_rc': hook_rc}) + '\n')
        emit(type='run_finished', turns=1)
        emit(type='idle')
    time.sleep(0.05)
EOF
chmod +x "$BIN/fm-session-start.sh" "$BIN/fm-watch-arm.sh" "$LAB/tools/deck"
export FM_DECK_BIN="$LAB/tools/deck"
REAL_PYTHON=$(command -v python3)
export REAL_PYTHON
cat > "$LAB/tools/python3" <<'EOF'
#!/usr/bin/env bash
if [ "${2:-}" = supervise ] && [ "${FM_TEST_SUPERVISOR_DELAY:-0}" = 1 ]; then
  while [ ! -e "$FM_HOME/supervisor.release" ]; do sleep 0.05; done
fi
exec "$REAL_PYTHON" "$@"
EOF
chmod +x "$LAB/tools/python3"

wait_for() {  # <seconds> <description> <command...>
  local limit=$1 what=$2 i=0
  shift 2
  while ! "$@" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt $((limit * 20)) ] || fail "timed out waiting for: $what"
    sleep 0.05
  done
}
new_home() {
  local home="$LAB/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$home"
}
turns_with() { grep -F -- "$2" "$1.turns"; }
alive() { kill -0 "$1" 2>/dev/null; }
dead() { case "$(ps -o stat= -p "$1" 2>/dev/null)" in ''|Z*) return 0 ;; esac; return 1; }
last_watch_pid() { tail -n 1 "$1/watch.pids"; }
watch_count() { [ "$(wc -l < "$1/watch.pids" | tr -d ' ')" -ge "$2" ]; }
busy_is() { grep -q "state=$2 " "$1/state/primary.busy-state"; }

test_steer_contract_without_a_host() {
  local home rc=0 out pid BIN="$LAB/steer-bin" STEER STOP
  cp -R "$LAB/bundle/bin" "$BIN"
  STEER="$BIN/fm-primary-steer.sh"
  STOP="$BIN/fm-deck-chat-stop.sh"
  cp "$BIN/fm-deck-chat.sh" "$STOP"
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 300; :' > "$BIN/fm-deck-chat.sh"
  home=$(new_home steer-contract)
  "$STEER" publish --home "$home" --text 'hello' >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "publish with no registered primary"
  rc=0; out=$("$STEER" status --home "$home") || rc=$?
  expect_code 3 "$rc" "status with no registered primary"
  assert_contains "$out" '"present": false' "status reports absence"
  rc=0; "$STEER" delivered 1 --home "$home" || rc=$?
  expect_code 3 "$rc" "delivered with no registered primary"

  # shellcheck disable=SC2016 # Expanded by the inner bash.
  bash -c 'exec -a fm-deck-chat bash "$1" --home "$2"' _ "$BIN/fm-deck-chat.sh" "$home" &
  pid=$!
  fm_test_track_helper_pid "$pid"
  python3 "$BIN/fm_primary_chat.py" prepare --home "$home" --session s1 >/dev/null
  python3 "$BIN/fm_primary_chat.py" record write --home "$home" --session s1 --host-pid "$pid"
  # The same pid recorded by another home is not that home's primary (pid reuse).
  local other
  other=$(new_home steer-other)
  python3 "$BIN/fm_primary_chat.py" prepare --home "$other" --session s1 >/dev/null
  python3 "$BIN/fm_primary_chat.py" record write --home "$other" --session s1 --host-pid "$pid"
  rc=0; "$STEER" status --home "$other" >/dev/null || rc=$?
  expect_code 3 "$rc" "a host serving another home is not present"
  rc=0; "$STOP" stop --home "$other" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "stop refuses a host serving another home"
  alive "$pid" || fail "stop never signals another home's host"
  local steer="$home/state/primary-chat/s1/steer" events="$home/state/primary-chat/s1/events.ndjson"
  assert_equals '0o600' "$(python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' \
    "$home/state/primary-chat.json")" "the record is 0600"

  rc=0; "$STEER" publish --home "$home" --text '   ' 2>/dev/null || rc=$?
  expect_code 2 "$rc" "blank text is refused"
  head -c 70000 /dev/zero | tr '\0' x > "$LAB/big"
  rc=0; "$STEER" publish --home "$home" --file "$LAB/big" 2>/dev/null || rc=$?
  expect_code 2 "$rc" "oversized text is refused"

  mkdir "$steer/.published.log"
  assert_equals 'seq=1' "$("$STEER" publish --home "$home" --text 'first')" "publish ignores the obsolete journal"
  printf 'second\nline\n' > "$LAB/body"
  assert_equals 'seq=2' "$("$STEER" publish --home "$home" --file "$LAB/body" --kind captain)" "second publish"
  assert_equals 'first' "$(cat "$steer/1.msg")" "message body is verbatim"
  assert_equals "$(printf 'second\nline')" "$(cat "$steer/2.msg")" "file body is verbatim"
  [ -z "$(find "$steer" -maxdepth 1 -name '*.tmp')" ] || fail "no temporary names are left visible"
  out=$("$STEER" status --home "$home")
  assert_contains "$out" '"published_seq": 2' "status counts published"
  assert_contains "$out" '"pending": 2' "status counts pending"
  assert_contains "$out" '"state": "unknown"' "no events yet is unknown"

  rc=0; "$STEER" delivered 1 --home "$home" || rc=$?
  expect_code 1 "$rc" "an unconsumed message is pending"
  mkdir -p "$steer/handled" && mv "$steer/1.msg" "$steer/handled/"
  "$STEER" delivered 1 --home "$home" || fail "handled/<seq>.msg is delivered"
  printf '%s\n' '{"type":"idle"}' '{"type":"run_started"}' '{"type":"steer_received","seq":2}' >> "$events"
  assert_contains "$("$STEER" status --home "$home")" '"state": "busy"' "run_started after idle is busy"
  printf '%s\n' '{"type":"steer_acked","seq":2}' '{"type":"run_finished"}' >> "$events"
  "$STEER" delivered 2 --home "$home" || fail "steer_acked >= seq is delivered"
  out=$("$STEER" status --home "$home")
  assert_contains "$out" '"state": "idle"' "run_finished is idle"
  assert_contains "$out" '"acked_seq": 2' "status reports the acked watermark"
  assert_contains "$out" '"last_event": "run_finished"' "status reports the last event"

  assert_equals 'seq=3' "$("$STEER" publish --home "$home" --text 'third')" "third publish"
  mkdir -p "$steer/rejected" && mv "$steer/3.msg" "$steer/rejected/"
  rc=0; "$STEER" delivered 3 --home "$home" || rc=$?
  expect_code 2 "$rc" "rejected/<seq>.msg is rejected"
  assert_equals 'seq=4' "$("$STEER" publish --home "$home" --text 'fourth')" "fourth publish"
  printf '%s\n' '{"type":"steer_rejected","seq":4,"reason":"bad"}' >> "$events"
  rc=0; "$STEER" delivered 4 --home "$home" || rc=$?
  expect_code 2 "$rc" "a steer_rejected event is rejected"

  # The sequence never goes back, even when its counter file is lost.
  rm -f "$steer/.seq"
  assert_equals 'seq=5' "$("$STEER" publish --home "$home" --text 'fifth')" "seq survives a lost counter"
  # Concurrent publishers get distinct, gap-free sequences.
  local i pids=''
  for i in 1 2 3 4 5 6 7 8 9 10; do
    "$STEER" publish --home "$home" --text "parallel $i" > "$LAB/par.$i" &
    pids="$pids $!"
  done
  for i in $pids; do wait "$i"; done
  assert_equals "$(seq 6 15)" "$(cat "$LAB"/par.* | sed 's/seq=//' | sort -n)" "parallel publishes are unique and ordered"

  # A no-mistakes gate agent cannot steer or stop the primary; reads stay open.
  local before
  before=$(cat "$steer/.seq")
  rc=0; FM_GATE_REFUSE_BYPASS='' NO_MISTAKES_GATE=1 "$STEER" publish --home "$home" --text 'from a gate' 2>/dev/null || rc=$?
  expect_code 3 "$rc" "a gate agent's publish is refused"
  assert_equals "$before" "$(cat "$steer/.seq")" "a refused publish allocates no sequence"
  FM_GATE_REFUSE_BYPASS='' NO_MISTAKES_GATE=1 "$STEER" status --home "$home" >/dev/null || fail "status stays readable for a gate agent"
  rc=0; FM_GATE_REFUSE_BYPASS='' NO_MISTAKES_GATE=1 "$STOP" stop --home "$home" 2>/dev/null || rc=$?
  expect_code 3 "$rc" "a gate agent cannot stop the primary"
  alive "$pid" || fail "a refused stop leaves the host running"

  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  rc=0; "$STEER" publish --home "$home" --text 'late' 2>/dev/null || rc=$?
  expect_code 3 "$rc" "a dead host is not present"
  pass "fm-primary-steer.sh: publish/status/delivered semantics, ordering and exit codes"
}

test_host_lifecycle() {
  local home other host second rc=0 out first_watch session linked="$LAB/linked-code"
  ln -s "$LAB/bundle" "$linked"
  home=$(new_home 'host backup')
  echo 'export FM_CHECK_INTERVAL=30' > "$home/config/x-mode.env"
  FAKE_DECK_LOG="$LAB/deck.log" "$linked/bin/fm-deck-chat.sh" --home "$home" --model fake/route \
    < /dev/null > "$LAB/host.out" 2>&1 &
  host=$!
  fm_test_track_helper_pid "$host"
  wait_for 10 "the host registers" "$STEER" status --home "$home"
  other=$(new_home host)
  python3 "$BIN/fm_primary_chat.py" prepare --home "$other" --session s1 >/dev/null
  python3 "$BIN/fm_primary_chat.py" record write --home "$other" --session s1 --host-pid "$host"
  assert_equals "$host" "$(python3 "$BIN/fm_primary_chat.py" record pid --home "$home")" "the exact home resolves its host"
  rc=0; out=$(python3 "$BIN/fm_primary_chat.py" record pid --home "$other") || rc=$?
  expect_code 3 "$rc" "a whitespace-delimited home prefix never resolves another home's host"
  assert_equals '' "$out" "the shorter home exposes no host pid"
  rc=0; "$STEER" status --home "$other" >/dev/null || rc=$?
  expect_code 3 "$rc" "the shorter home has no live primary"
  rc=0; "$BIN/fm-deck-chat.sh" stop --home "$other" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "stop refuses the shorter home's stale record"
  alive "$host" || fail "stop leaves the longer home's host alive"
  "$STEER" status --home "$home" >/dev/null || fail "the longer home's primary stays registered"
  assert_equals "$host" "$(cat "$home/state/.lock")" "the host holds the session lock"
  assert_equals "fm-deck-chat" "$(ps -o args= -p "$host" | awk '{print $1}')" "the host runs as fm-deck-chat"
  wait_for 10 "the startup digest turn" turns_with "$LAB/deck.log" 'fixture session digest'
  assert_equals 1 "$(wc -l < "$home/session-start.runs" | tr -d ' ')" "session start ran once"
  assert_equals deck "$(cat "$home/startup.harness")" "startup identifies the host before deck launches"
  out=$(cat "$LAB/deck.log")
  session=$(cat "$home/state/primary-chat/session")
  assert_contains "$out" "\"--session\", \"$session\"" "deck chat resumes the persisted session"
  assert_contains "$out" "\"--steer-dir\", \"$home/state/primary-chat/$session/steer\"" "deck chat gets the steer dir"
  assert_contains "$out" "\"--events\", \"$home/state/primary-chat/$session/events.ndjson\"" "deck chat gets the events file"
  assert_contains "$out" '"--model", "fake/route"' "deck chat gets the model"
  assert_contains "$out" "\"cwd\": \"$home\"" "deck chat runs in the home"
  assert_contains "$(turns_with "$LAB/deck.log" 'fixture session digest')" '"hook_rc": 0' \
    "the pre_complete lock check passes inside the host"

  # A steer while idle starts a new turn; busy-state follows the events.
  wait_for 10 "busy-state idle after the digest turn" busy_is "$home" idle
  "$linked/bin/fm-primary-steer.sh" publish --home "$home" --text 'SLOW captain question' >/dev/null
  wait_for 10 "busy-state busy during the turn" busy_is "$home" busy
  wait_for 10 "the steer turn" turns_with "$LAB/deck.log" 'SLOW captain question'
  wait_for 10 "busy-state idle after the turn" busy_is "$home" idle
  assert_contains "$(cat "$home/state/primary.busy-state")" 'source=deck-wrapper' "busy-state uses the deck source"

  # fm-send to `primary` becomes a steer publish.
  out=$(FM_HOME="$home" "$BIN/fm-send.sh" primary 'note from a scout')
  assert_contains "$out" 'seq=' "fm-send primary publishes a steer"
  wait_for 10 "the fm-send turn" turns_with "$LAB/deck.log" 'note from a scout'

  # A watcher wake is published into the inbox and handled as a turn.
  wait_for 10 "a watcher" watch_count "$home" 1
  assert_equals 30 "$(head -n 1 "$home/watch.cadence")" "initial watcher uses home Relay cadence"
  echo 'wake: fixture reason' > "$home/wake.trigger"
  wait_for 10 "the wake turn" turns_with "$LAB/deck.log" 'wake: fixture reason'
  assert_contains "$(turns_with "$LAB/deck.log" 'wake: fixture reason')" 'Drain bin/fm-wake-drain.sh first' \
    "the wake steer carries the drain instruction"
  wait_for 10 "the watcher re-arms after a wake" watch_count "$home" 2

  # A dead watcher is restarted; the host keeps running.
  assert_equals 30 "$(tail -n 1 "$home/watch.cadence")" "re-arm uses home Relay cadence"
  echo 'export FM_CHECK_INTERVAL=45' > "$home/config/x-mode.env"
  first_watch=$(last_watch_pid "$home")
  kill -9 "$first_watch"
  wait_for 10 "a replacement watcher" watch_count "$home" 3
  alive "$host" || fail "the host survives a dead watcher"
  assert_not_equals "$first_watch" "$(last_watch_pid "$home")" "the watcher was replaced"
  assert_equals 45 "$(tail -n 1 "$home/watch.cadence")" "replacement reloads home Relay cadence"
  assert_grep 'watcher failed' "$home/state/primary-chat/host.log" "the watcher failure is logged"

  # A second host is refused and leaves the first untouched.
  rc=0
  FAKE_DECK_LOG="$LAB/deck2.log" "$BIN/fm-deck-chat.sh" --home "$home" < /dev/null > "$LAB/host2.out" 2>&1 || rc=$?
  expect_code 1 "$rc" "a second host is refused"
  assert_grep 'another live firstmate session holds the lock' "$LAB/host2.out" "the refusal names the lock"
  assert_absent "$LAB/deck2.log" "the refused host never starts deck"
  assert_equals "$host" "$(cat "$home/state/.lock")" "the lock stays with the first host"
  "$STEER" status --home "$home" >/dev/null || fail "the first host stays registered"

  # A clean stop releases everything and marks the record stopped.
  second=$(last_watch_pid "$home")
  "$linked/bin/fm-deck-chat.sh" stop --home "$home" >/dev/null
  wait_for 10 "the host exits" dead "$host"
  wait "$host" 2>/dev/null || true
  assert_absent "$home/state/.lock" "the lock is released"
  assert_grep '"stopped_at"' "$home/state/primary-chat.json" "the record is marked stopped"
  rc=0; out=$("$STEER" status --home "$home") || rc=$?
  expect_code 3 "$rc" "a stopped host is not present"
  assert_contains "$out" '"state": "stopped"' "status says stopped"
  wait_for 10 "the watcher stops with the host" dead "$second"
  wait_for 10 "busy-state settles idle" busy_is "$home" idle

  # A restart resumes the same session and continues its sequence.
  FAKE_DECK_LOG="$LAB/deck3.log" "$BIN/fm-deck-chat.sh" --home "$home" < /dev/null > "$LAB/host3.out" 2>&1 &
  host=$!
  fm_test_track_helper_pid "$host"
  wait_for 10 "the restarted digest turn" turns_with "$LAB/deck3.log" 'fixture session digest'
  assert_contains "$(cat "$LAB/deck3.log")" "\"--session\", \"$session\"" "the restart resumes the session"
  assert_contains "$(turns_with "$LAB/deck3.log" 'fixture session digest')" '"seq": 5' "the sequence continues"
  kill -TERM "$host"
  wait_for 10 "the restarted host exits on SIGTERM" dead "$host"
  assert_absent "$home/state/.lock" "SIGTERM releases the lock"
  pass "fm-deck-chat.sh: lock, digest turn, steer turns, busy-state, fm-send, watcher wake/restart, refusal, stop and resume"
}

test_oversized_watcher_output() {
  local home host encoding count=1
  home=$(new_home oversized-wake)
  FAKE_DECK_LOG="$LAB/deck-oversized.log" "$BIN/fm-deck-chat.sh" --home "$home" \
    < /dev/null > "$LAB/host-oversized.out" 2>&1 &
  host=$!
  fm_test_track_helper_pid "$host"
  wait_for 10 "oversized-wake startup" turns_with "$LAB/deck-oversized.log" 'fixture session digest'
  for encoding in ascii multibyte; do
    wait_for 10 "watcher ready for $encoding wake" watch_count "$home" "$count"
    python3 - "$home" "$encoding" <<'PY'
import os, pathlib, sys
home, encoding = pathlib.Path(sys.argv[1]), sys.argv[2]
body = ('x' if encoding == 'ascii' else '界') * 70000 + '\nwake: oversized ' + encoding + ' reason\n'
(home / 'wake.expected').write_text(body, encoding='utf-8')
(home / 'wake.tmp').write_text(body, encoding='utf-8')
os.replace(home / 'wake.tmp', home / 'wake.trigger')
PY
    wait_for 10 "oversized $encoding wake delivered" turns_with "$LAB/deck-oversized.log" "wake: oversized $encoding reason"
    python3 - "$LAB/deck-oversized.log.turns" "$home/wake.expected" "$encoding" <<'PY'
import json, pathlib, sys
preamble = ('The home watcher has an actionable wake. Drain bin/fm-wake-drain.sh first, '
            'handle every emitted wake and open decision, and acknowledge only after '
            'handling. Watcher output:\n')
marker = 'wake: oversized ' + sys.argv[3] + ' reason'
turns = [json.loads(line) for line in pathlib.Path(sys.argv[1]).read_text().splitlines()]
matches = [turn['text'] for turn in turns if marker in turn['text']]
assert len(matches) == 1, matches
body = matches[0]
output = pathlib.Path(sys.argv[2]).read_bytes()
budget = 65536 - len(preamble.encode('utf-8'))
assert body.startswith(preamble), 'wake handling instructions were truncated'
assert body.endswith(marker + '\n'), 'wake reason was truncated'
assert body == preamble + output[-budget:].decode('utf-8', 'ignore'), 'unexpected bounded watcher output'
assert 65533 <= len(body.encode('utf-8')) <= 65536, 'incorrect UTF-8 byte budget'
PY
    count=$((count + 1))
  done
  wait_for 10 "watcher re-arms after oversized wakes" watch_count "$home" "$count"
  kill -TERM "$host"
  wait_for 10 "oversized-wake host exits" dead "$host"
  wait "$host" 2>/dev/null || true
  pass "fm-deck-chat.sh: oversized ASCII and multibyte wakes retain instructions within the byte limit"
}

test_task_named_primary_blocks_the_host() {
  local home rc=0
  home=$(new_home primary-task)
  printf 'id=primary\n' > "$home/state/primary.meta"
  FAKE_DECK_LOG="$LAB/deck-task.log" "$BIN/fm-deck-chat.sh" --home "$home" < /dev/null > "$LAB/host-task.out" 2>&1 || rc=$?
  expect_code 1 "$rc" "the host refuses a home with a task named primary"
  assert_grep 'a task named primary exists' "$LAB/host-task.out" "the refusal names the task"
  assert_absent "$home/state/.lock" "the refused host takes no lock"
  assert_absent "$LAB/deck-task.log" "the refused host never starts deck"
  pass "fm-deck-chat.sh: a task named primary blocks the host"
}

test_away_mode_pauses_the_watcher() {
  local home host watch
  home=$(new_home away)
  FAKE_DECK_LOG="$LAB/deck-away.log" "$BIN/fm-deck-chat.sh" --home "$home" < /dev/null > "$LAB/host-away.out" 2>&1 &
  host=$!
  fm_test_track_helper_pid "$host"
  wait_for 10 "a watcher" watch_count "$home" 1
  watch=$(last_watch_pid "$home")
  touch "$home/state/.afk"
  wait_for 10 "the watcher stops in away mode" dead "$watch"
  sleep 0.5
  assert_equals 1 "$(wc -l < "$home/watch.pids" | tr -d ' ')" "no watcher runs while state/.afk exists"
  rm -f "$home/state/.afk"
  wait_for 10 "the watcher resumes" watch_count "$home" 2
  kill -TERM "$host"
  wait_for 10 "the host exits" dead "$host"
  pass "fm-deck-chat.sh: away mode pauses the host watcher and resumes it after"
}

test_stream_endpoint_host() {
  local home dir="$LAB/stream" host port pid out target waited=0
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    pass "fm-deck-chat.sh --stream skipped without curl and jq"
    return
  fi
  home=$(new_home stream-home)
  mkdir -p "$dir"
  printf 'publish,subscribe,control:stream-token-%s\n' "$$" > "$dir/tokens"
  chmod 600 "$dir/tokens"
  python3 "$BIN/fm-stream-hub.py" serve --bind 127.0.0.1 --port 0 --token-file "$dir/tokens" \
    --ready-file "$dir/ready" > "$dir/hub.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ ! -s "$dir/ready" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  read -r host port < "$dir/ready" || fail "the disposable hub never became ready"
  out=$(SHELL=/bin/bash FM_STREAM_HUB="http://$host:$port" FM_STREAM_TOKEN="stream-token-$$" FM_STREAM_MACHINE=box-test \
    FAKE_DECK_LOG="$LAB/deck-stream.log" "$BIN/fm-deck-chat.sh" --stream --home "$home" 2>&1) \
    || fail "--stream failed: $out"
  target=$(printf '%s\n' "$out" | sed -n 's/^primary-chat: running in stream endpoint //p')
  [ -n "$target" ] || fail "--stream prints the endpoint target: $out"
  assert_contains "$out" "bin/fm-stream.sh attach --interactive $target (Ctrl-] detaches)" "--stream prints the interactive attach command and detach key"
  assert_contains "$out" 'attach: bin/fm-deck-chat.sh attach (follows restarts)' "--stream names the attach that follows restarts"
  assert_contains "$out" 'input: bin/fm-send.sh primary <text>' "--stream names the input path"
  assert_contains "$("$STEER" status --home "$home")" "\"endpoint\": \"$target\"" "the record carries the endpoint"
  wait_for 10 "the digest turn inside the endpoint" turns_with "$LAB/deck-stream.log" 'fixture session digest'
  host=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["host_pid"])' "$home/state/primary-chat.json")
  "$BIN/fm-deck-chat.sh" stop --home "$home" >/dev/null
  wait_for 10 "the endpoint host exits" dead "$host"
  assert_absent "$home/state/.lock" "the endpoint host releases the lock"
  pass "fm-deck-chat.sh --stream: the host runs inside a stream endpoint and registers it"
}

test_startup_completion_required() {
  local mode home rc
  for mode in missing wrong; do
    home=$(new_home "startup-$mode")
    rc=0
    FM_TEST_STARTUP_COMPLETION=$mode FAKE_DECK_LOG="$LAB/deck-$mode.log" \
      "$BIN/fm-deck-chat.sh" --home "$home" </dev/null > "$LAB/host-$mode.out" 2>&1 || rc=$?
    expect_code 1 "$rc" "startup with $mode completion is refused"
    assert_grep 'session start did not publish a complete digest' "$LAB/host-$mode.out" "refusal names incomplete startup"
    assert_absent "$home/state/primary-chat.json" "incomplete startup never registers"
    assert_absent "$LAB/deck-$mode.log" "incomplete startup never launches deck"
    assert_absent "$home/state/.lock" "incomplete startup releases its lock"
  done
  pass "fm-deck-chat.sh: startup completion must name this host"
}

test_startup_handoff() {
  local home host steer events out
  home=$(new_home startup-handoff)
  python3 "$BIN/fm_primary_chat.py" prepare --home "$home" --session handoff >/dev/null
  steer="$home/state/primary-chat/handoff/steer"
  events="$home/state/primary-chat/handoff/events.ndjson"
  echo 5 > "$steer/.seq"
  echo 'retained captain input' > "$steer/5.msg"
  printf '%s\n' '{"type":"run_started"}' > "$events"
  PATH="$LAB/tools:$PATH" FM_TEST_SUPERVISOR_DELAY=1 FM_TEST_STARTUP_SLOW=1 \
    FAKE_DECK_LOG="$LAB/deck-handoff.log" "$BIN/fm-deck-chat.sh" --home "$home" \
    </dev/null > "$LAB/host-handoff.out" 2>&1 &
  host=$!
  fm_test_track_helper_pid "$host"
  wait_for 10 "handoff registration" "$STEER" status --home "$home"
  out=$(FM_HOME="$home" "$BIN/fm-send.sh" primary 'immediate captain input')
  assert_contains "$out" 'seq=7' "startup reserves the first new sequence before registration"
  wait_for 10 "events emitted before delayed supervisor starts" grep -q 'steer_received' "$events"
  [ ! -s "$home/state/primary-chat/host.log" ] || fail "deck events must precede supervisor readiness"
  touch "$home/supervisor.release"
  wait_for 10 "startup turn busy despite delayed event follower" busy_is "$home" busy
  touch "$home/startup.release"
  wait_for 10 "startup digest delivered" turns_with "$LAB/deck-handoff.log" 'fixture session digest'
  assert_contains "$(turns_with "$LAB/deck-handoff.log" 'fixture session digest')" '"seq": 6' "startup uses the shared sequence counter"
  wait_for 10 "old pending input delivered" turns_with "$LAB/deck-handoff.log" 'retained captain input'
  wait_for 10 "new captain input delivered" turns_with "$LAB/deck-handoff.log" 'immediate captain input'
  wait_for 10 "handoff returns idle" busy_is "$home" idle
  kill -TERM "$host"
  wait_for 10 "handoff host exits" dead "$host"
  wait "$host" 2>/dev/null || true
  pass "fm-deck-chat.sh: startup publication precedes registration, pending inputs survive and early events reach busy-state"
}

# A disposable Python hub for the stream-endpoint cases; sets HUB_URL and
# HUB_TOKEN. Returns 1 (the caller skips) without curl and jq.
start_test_hub() {  # <dir>
  local dir=$1 pid host port waited=0
  command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 || return 1
  mkdir -p "$dir"
  HUB_TOKEN="hub-token-$$-$(basename "$dir")"
  printf 'publish,subscribe,control:%s\n' "$HUB_TOKEN" > "$dir/tokens"
  chmod 600 "$dir/tokens"
  python3 "$BIN/fm-stream-hub.py" serve --bind 127.0.0.1 --port 0 --token-file "$dir/tokens" \
    --ready-file "$dir/ready" > "$dir/hub.log" 2>&1 &
  pid=$!
  disown "$pid" 2>/dev/null || true
  fm_test_track_helper_pid "$pid"
  while [ ! -s "$dir/ready" ] && [ "$waited" -lt 100 ]; do sleep 0.1; waited=$((waited + 1)); done
  read -r host port < "$dir/ready" || fail "the disposable hub never became ready"
  HUB_URL="http://$host:$port"
}
record_field() { python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get(sys.argv[2]) or "")' "$1" "$2" 2>/dev/null; }
dir_mode() { python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.stat(sys.argv[1]).st_mode)))' "$1"; }
service_state_is() { [ "$(record_field "$1/state/primary-chat/service.json" state)" = "$2" ]; }
host_is_not() {  # <home> <pid>: a live host other than <pid> is registered
  local now
  now=$(python3 "$BIN/fm_primary_chat.py" record pid --home "$1" 2>/dev/null) && [ "$now" != "$2" ]
}
runs_are() { [ "$(wc -l < "$1/session-start.runs" | tr -d ' ')" = "$2" ]; }
alarm_recorder() {  # <path>
  # shellcheck disable=SC2016 # Expanded by the recorder.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s|%s\n" "$1" "$2" >> "$ALARM_LOG"' > "$1"
  chmod +x "$1"
}

test_stop_marker() {
  local home empty host rc=0 out
  empty=$(new_home stop-empty)
  "$BIN/fm-deck-chat.sh" stop --home "$empty" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "stop in a fresh home records intent without a host"
  assert_equals 0o700 "$(dir_mode "$empty/state/primary-chat")" "stop creates a private primary-chat directory"
  chmod 710 "$empty/state/primary-chat"
  rc=0; "$BIN/fm-deck-chat.sh" stop --home "$empty" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "repeated stop without a host still refuses"
  assert_equals 0o710 "$(dir_mode "$empty/state/primary-chat")" "stop preserves an existing directory's mode"
  home=$(new_home stop-marker)
  mkdir -p "$home/state/primary-chat"
  echo '{}' > "$home/state/primary-chat/stopped"
  FAKE_DECK_LOG="$LAB/deck-marker.log" "$BIN/fm-deck-chat.sh" --home "$home" < /dev/null > "$LAB/host-marker.out" 2>&1 &
  host=$!
  fm_test_track_helper_pid "$host"
  wait_for 10 "the marker host registers" "$STEER" status --home "$home"
  assert_absent "$home/state/primary-chat/stopped" "a captain-started host withdraws an earlier stop"
  rc=0; out=$(FM_DECK_CHAT_SERVICE=1 "$BIN/fm-deck-chat.sh" --stream --home "$home" 2>&1) || rc=$?
  expect_code 1 "$rc" "--stream refuses while a primary is live"
  assert_contains "$out" 'a primary is already running for this home' "the refusal names the live primary"
  "$BIN/fm-deck-chat.sh" stop --home "$home" >/dev/null
  wait_for 10 "the marker host exits" dead "$host"
  assert_grep '"by": "fm-deck-chat.sh stop"' "$home/state/primary-chat/stopped" "stop leaves the stopped-on-purpose marker"
  rm -f "$home/state/primary-chat/stopped"
  rc=0; "$BIN/fm-deck-chat.sh" stop --home "$home" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "stop with no live host still refuses"
  assert_present "$home/state/primary-chat/stopped" "stop with no live host still records the intent"
  pass "fm-deck-chat.sh: stop leaves a durable marker, a captain start clears it, --stream refuses a second primary"
}

test_service_install() {
  local home canonical out rc=0 plist label uid
  home=$(new_home 'service install')
  canonical=$(cd "$home" && pwd -P)
  uid=$(id -u)
  cat > "$LAB/tools/launchctl" <<'LAUNCHCTL'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FAKE_LAUNCHCTL_LOG"
case "$1" in
  bootstrap) touch "$FAKE_LAUNCHCTL_LOG.loaded" ;;
  bootout) [ -e "$FAKE_LAUNCHCTL_LOG.loaded" ] || exit 3; rm -f "$FAKE_LAUNCHCTL_LOG.loaded" ;;
  print) [ -e "$FAKE_LAUNCHCTL_LOG.loaded" ] ;;
esac
LAUNCHCTL
  chmod +x "$LAB/tools/launchctl"
  export FM_LAUNCHCTL="$LAB/tools/launchctl" FM_LAUNCH_AGENTS_DIR="$LAB/LaunchAgents" FAKE_LAUNCHCTL_LOG="$LAB/launchctl.log"
  out=$("$BIN/fm-deck-chat.sh" install-service --home "$home" --model fake/route) || fail "install-service failed: $out"
  label=dev.firstmate.primary.$(printf '%s' "$canonical" | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')
  plist="$LAB/LaunchAgents/$label.plist"
  assert_present "$plist" "install-service generates the per-home plist"
  assert_contains "$out" "gui/$uid/$label installed" "install-service names the loaded agent"
  assert_contains "$out" 'primary: not running; the keeper starts it now' "install-service says what the keeper will do"
  assert_equals "$(printf 'bootout gui/%s/%s\nbootstrap gui/%s %s\nprint gui/%s/%s' "$uid" "$label" "$uid" "$plist" "$uid" "$label")" \
    "$(cat "$LAB/launchctl.log")" "install-service replaces, bootstraps and verifies the agent"
  python3 - "$plist" "$BIN/fm-deck-chat.sh" "$canonical" "$label" <<'PY' || fail "the generated plist is not the expected service"
import plistlib, sys
plist, script, home, label = sys.argv[1:5]
data = plistlib.load(open(plist, 'rb'))
assert data['Label'] == label, data['Label']
assert data['ProgramArguments'][1:] == [script, 'service-run', '--home', home, '--model', 'fake/route'], data['ProgramArguments']
assert data['RunAtLoad'] is True and data['KeepAlive'] is True and data['AbandonProcessGroup'] is True, data
assert data['WorkingDirectory'] == home and data['EnvironmentVariables']['PATH'], data
PY
  assert_equals 0o700 "$(dir_mode "$home/state/primary-chat")" "install-service creates a private primary-chat directory"
  chmod 710 "$home/state/primary-chat"
  # A second install replaces the first definition in place.
  "$BIN/fm-deck-chat.sh" install-service --home "$home" >/dev/null || fail "reinstall failed"
  assert_equals 0o710 "$(dir_mode "$home/state/primary-chat")" "reinstall preserves an existing directory's mode"
  python3 -c 'import plistlib,sys; sys.exit("--model" in plistlib.load(open(sys.argv[1],"rb"))["ProgramArguments"])' "$plist" \
    || fail "a reinstall without --model drops the old model"
  "$BIN/fm-deck-chat.sh" uninstall-service --home "$home" >/dev/null || fail "uninstall-service failed"
  assert_absent "$plist" "uninstall-service deletes the plist"
  assert_absent "$LAB/launchctl.log.loaded" "uninstall-service boots the agent out"
  unset FM_LAUNCHCTL
  if [ "$(uname)" != Darwin ]; then
    rc=0; "$BIN/fm-deck-chat.sh" install-service --home "$home" 2>/dev/null || rc=$?
    expect_code 2 "$rc" "install-service refuses off macOS"
  fi
  unset FM_LAUNCH_AGENTS_DIR FAKE_LAUNCHCTL_LOG
  pass "fm-deck-chat.sh install-service/uninstall-service: generated per-home launchd agent"
}

test_service_alert() {
  local home
  home=$(new_home alert)
  mkdir -p "$home/state/primary-chat"
  alarm_recorder "$LAB/tools/alarm"
  ALARM_LOG="$LAB/alarm-off.log" FM_WEDGE_ALARM_EXEC="$LAB/tools/alarm" FM_WEDGE_ALARM_CHANNEL=off \
    "$BIN/fm-deck-chat.sh" service-alert --home "$home" --summary 'primary down' || fail "service-alert with off failed"
  assert_absent "$LAB/alarm-off.log" "an off channel raises nothing"
  ALARM_LOG="$LAB/alarm.log" FM_WEDGE_ALARM_EXEC="$LAB/tools/alarm" FM_WEDGE_ALARM_CHANNEL=osascript \
    "$BIN/fm-deck-chat.sh" service-alert --home "$home" --summary 'primary down' || fail "service-alert failed"
  assert_equals 'osascript|primary down' "$(cat "$LAB/alarm.log")" "service-alert goes through the wedge alarm channels"
  pass "fm-deck-chat.sh service-alert: reuses the wedge alarm channels and seam"
}

test_attach_follows_restarts() {
  local home BIN="$LAB/attach-bin" first second attach rc=0
  cp -R "$LAB/bundle/bin" "$BIN"
  cp "$BIN/fm-deck-chat.sh" "$BIN/fm-deck-chat-attach.sh"
  # A stand-in host that takes its sleeper with it when it is killed.
  # shellcheck disable=SC2016 # Written for the stand-in host.
  printf '%s\n' '#!/usr/bin/env bash' 'sleep 300 & trap '"'"'kill $!; exit 0'"'"' TERM; wait' > "$BIN/fm-deck-chat.sh"
  cat > "$BIN/fm-stream.sh" <<'STREAM'
#!/usr/bin/env bash
printf '%s\n' "$3" >> "$ATTACH_LOG"
case "$3" in
  t:aa) kill "$(cat "$ATTACH_LOG.first")"; exit 0 ;;
  *) exit 7 ;;
esac
STREAM
  chmod +x "$BIN/fm-stream.sh"
  home=$(new_home attach)
  # shellcheck disable=SC2016 # Expanded by the inner bash.
  bash -c 'exec -a fm-deck-chat bash "$1" --home "$2"' _ "$BIN/fm-deck-chat.sh" "$home" &
  first=$!
  fm_test_track_helper_pid "$first"
  echo "$first" > "$LAB/attach.log.first"
  python3 "$BIN/fm_primary_chat.py" prepare --home "$home" --session s1 >/dev/null
  python3 "$BIN/fm_primary_chat.py" record write --home "$home" --session s1 --host-pid "$first" --endpoint t:aa
  ATTACH_LOG="$LAB/attach.log" "$BIN/fm-deck-chat-attach.sh" attach --home "$home" > /dev/null 2> "$LAB/attach.err" &
  attach=$!
  fm_test_track_helper_pid "$attach"
  wait_for 10 "the first endpoint closes" dead "$first"
  wait_for 10 "attach waits for the next primary" grep -q 'closed; attaching to the next one' "$LAB/attach.err"
  # shellcheck disable=SC2016 # Expanded by the inner bash.
  bash -c 'exec -a fm-deck-chat bash "$1" --home "$2"' _ "$BIN/fm-deck-chat.sh" "$home" &
  second=$!
  fm_test_track_helper_pid "$second"
  python3 "$BIN/fm_primary_chat.py" record write --home "$home" --session s1 --host-pid "$second" --endpoint t:bb
  wait "$attach" || rc=$?
  expect_code 7 "$rc" "attach returns the client's exit while its endpoint is still live"
  assert_equals "$(printf 't:aa\nt:bb')" "$(cat "$LAB/attach.log")" "attach follows the primary to its new endpoint"
  kill "$second" 2>/dev/null || true
  pass "fm-deck-chat.sh attach: reattaches when the primary's endpoint is replaced"
}

test_open_attaches_or_starts() {
  local home BIN="$LAB/open-bin" OPEN="$LAB/open-bin/fm-deck-chat-open.sh" host keeper open rc=0 out mode
  cp -R "$LAB/bundle/bin" "$BIN"
  cp "$BIN/fm-deck-chat.sh" "$OPEN"
  # A stand-in host; its --stream registers a new one at endpoint t:cc.
  cat > "$BIN/fm-deck-chat.sh" <<'HOST'
#!/usr/bin/env bash
if [ "${1:-}" = --stream ]; then
  printf '%s\n' "$*" >> "$OPEN_LOG"
  # shellcheck disable=SC2016 # Expanded by the inner bash.
  bash -c 'exec -a fm-deck-chat bash "$1" --home "$2"' _ "$0" "$3" </dev/null >/dev/null 2>&1 &
  echo "$!" >> "$OPEN_LOG.hosts"
  python3 "$(dirname "$0")/fm_primary_chat.py" prepare --home "$3" --session s1 >/dev/null
  python3 "$(dirname "$0")/fm_primary_chat.py" record write --home "$3" --session s1 --host-pid "$!" --endpoint t:cc
  exit 0
fi
sleep 300 & trap 'kill $!; exit 0' TERM; wait
HOST
  # shellcheck disable=SC2016 # Expanded by the stubs.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$3" >> "$ATTACH_LOG"; exit 7' > "$BIN/fm-stream.sh"
  # shellcheck disable=SC2016 # Expanded by the stub.
  printf '%s\n' '#!/usr/bin/env bash' 'printf "%s|%s|%s\n" "$PWD" "${DECK_NO_LAUNCHER:-}" "$*" > "$OPEN_LOG.local"' > "$LAB/tools/local-deck"
  chmod +x "$BIN/fm-deck-chat.sh" "$BIN/fm-stream.sh" "$LAB/tools/local-deck"
  export OPEN_LOG="$LAB/open.log" ATTACH_LOG="$LAB/open-attach.log"
  start_host() {  # <home> <endpoint>
    # shellcheck disable=SC2016 # Expanded by the inner bash.
    bash -c 'exec -a fm-deck-chat bash "$1" --home "$2"' _ "$BIN/fm-deck-chat.sh" "$1" &
    host=$!
    fm_test_track_helper_pid "$host"
    python3 "$BIN/fm_primary_chat.py" record write --home "$1" --session s1 --host-pid "$host" ${2:+--endpoint "$2"}
  }

  mkdir -p "$LAB/open-clone/sub"
  home=$(cd "$LAB/open-clone" && pwd -P)
  DECK_CHAT_CWD="$home/sub" FM_DECK_BIN="$LAB/tools/local-deck" "$OPEN" open --home "$home" || fail "open in a checkout that is not a home failed"
  assert_equals "$home/sub|1|chat" "$(cat "$OPEN_LOG.local")" "open runs a local deck chat in a checkout that is not a firstmate home"
  assert_absent "$home/state" "open leaves a checkout that is not a home untouched"
  FM_GATE_REFUSE_BYPASS='' NO_MISTAKES_GATE=1 DECK_CHAT_CWD="$home/sub" FM_DECK_BIN="$LAB/tools/local-deck" \
    "$OPEN" open --home "$home" || fail "a gate marker must not block local chat outside a home"
  assert_equals "$home/sub|1|chat" "$(cat "$OPEN_LOG.local")" "local fallback bypasses the gate marker"

  git init -q "$home"
  git -C "$home" -c user.name=Test -c user.email=test@example.com commit -q --allow-empty -m fixture
  mkdir -p "$LAB/.no-mistakes/repos"
  git clone -q --bare "$home" "$LAB/.no-mistakes/repos/open.git"
  git -C "$LAB/.no-mistakes/repos/open.git" worktree add -q "$LAB/open-gate" HEAD
  home=$(cd "$LAB/open-gate" && pwd -P)
  mkdir "$home/sub"
  (
    cd "$home/sub"
    unset NO_MISTAKES_GATE
    FM_GATE_REFUSE_BYPASS='' DECK_CHAT_CWD="$home/sub" FM_DECK_BIN="$LAB/tools/local-deck" \
      "$OPEN" open --home "$home"
  ) || fail "a no-state gate worktree must get local chat"
  assert_equals "$home/sub|1|chat" "$(cat "$OPEN_LOG.local")" "local fallback bypasses the git-common-dir gate signal"
  assert_absent "$home/state" "local chat in a gate worktree creates no primary state"
  rm -f "$OPEN_LOG.local"
  for mode in '' --stream stop attach install-service uninstall-service service-run service-alert; do
    rc=0
    FM_GATE_REFUSE_BYPASS='' NO_MISTAKES_GATE=1 FM_DECK_BIN="$LAB/tools/local-deck" \
      "$OPEN" ${mode:+"$mode"} --home "$home" 2>/dev/null || rc=$?
    expect_code 3 "$rc" "$mode still refuses gate agents without state"
  done
  assert_absent "$home/state" "refused primary operations create no state"
  mkdir "$home/state"
  rc=0
  FM_GATE_REFUSE_BYPASS='' NO_MISTAKES_GATE=1 "$OPEN" open --home "$home" 2>/dev/null || rc=$?
  expect_code 3 "$rc" "open in a firstmate home still refuses gate agents"
  assert_absent "$OPEN_LOG.local" "refused primary operations never run local chat"

  home=$(new_home open-live)
  home=$(cd "$home" && pwd -P)
  python3 "$BIN/fm_primary_chat.py" prepare --home "$home" --session s1 >/dev/null
  start_host "$home" t:aa
  rc=0; "$OPEN" open --home "$home" 2>/dev/null || rc=$?
  expect_code 7 "$rc" "open returns the interactive client's exit"
  assert_equals t:aa "$(cat "$ATTACH_LOG")" "open attaches to the live primary's endpoint"
  kill "$host"; wait_for 10 "the live stand-in exits" dead "$host"
  start_host "$home" ''
  rc=0; out=$("$OPEN" open --home "$home" 2>&1) || rc=$?
  expect_code 1 "$rc" "open refuses a primary that runs in a terminal of its own"
  assert_contains "$out" 'runs in its own terminal' "the refusal says where the primary runs"
  kill "$host"; wait_for 10 "the terminal stand-in exits" dead "$host"

  rm -f "$ATTACH_LOG"
  echo '{}' > "$home/state/primary-chat/stopped"
  python3 -c 'import fcntl, sys, time
handle = open(sys.argv[1], "a"); fcntl.flock(handle, fcntl.LOCK_EX); open(sys.argv[2], "w").close(); time.sleep(300)' \
    "$home/state/primary-chat/service.lock" "$LAB/open-keeper.ready" &
  keeper=$!
  fm_test_track_helper_pid "$keeper"
  wait_for 10 "the stand-in keeper holds service.lock" test -e "$LAB/open-keeper.ready"
  "$OPEN" open --home "$home" 2>"$LAB/open-keeper.err" &
  open=$!
  fm_test_track_helper_pid "$open"
  wait_for 10 "open withdraws the stopped marker for the keeper" test ! -e "$home/state/primary-chat/stopped"
  wait_for 10 "open waits for the keeper's primary" grep -q 'no live primary; waiting' "$LAB/open-keeper.err"
  start_host "$home" t:bb
  rc=0; wait "$open" || rc=$?
  expect_code 7 "$rc" "open attaches once the keeper's primary registers"
  assert_equals t:bb "$(cat "$ATTACH_LOG")" "open attaches to the keeper-started primary"
  assert_absent "$OPEN_LOG" "open leaves starting to a running keeper"
  kill "$host"; wait_for 10 "the keeper's first stand-in exits" dead "$host"
  rm -f "$ATTACH_LOG"
  # shellcheck disable=SC2016
  bash -c 'exec -a fm-deck-chat bash "$1" --home "$2"' _ "$BIN/fm-deck-chat.sh" "$home" &
  host=$!
  fm_test_track_helper_pid "$host"
  mkdir "$LAB/open-tools"
  cat > "$LAB/open-tools/python3" <<'PYTHON'
#!/usr/bin/env bash
if [ "${2:-}" = steer ] && [ "${3:-}" = status ] && [ ! -e "$OPEN_LOG.snapshot" ]; then
  "$REAL_PYTHON" "$@" > "$OPEN_LOG.snapshot"
  rc=$?
  "$REAL_PYTHON" "$1" record write --home "$FM_HOME" --session s1 --host-pid "$OPEN_REGISTER_PID" --endpoint t:dd || exit 2
  cat "$OPEN_LOG.snapshot"
  exit "$rc"
fi
exec "$REAL_PYTHON" "$@"
PYTHON
  chmod +x "$LAB/open-tools/python3"
  rc=0
  PATH="$LAB/open-tools:$PATH" OPEN_REGISTER_PID="$host" "$OPEN" open --home "$home" 2>"$LAB/open-race.err" || rc=$?
  expect_code 7 "$rc" "open attaches when the keeper registers after the initial status snapshot"
  python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["present"] is False' "$OPEN_LOG.snapshot" \
    || fail "the initial snapshot must precede host registration"
  assert_equals t:dd "$(cat "$ATTACH_LOG")" "a newly registered stream primary is never classified as terminal-hosted"
  assert_absent "$OPEN_LOG" "open never starts beside a keeper registering its primary"
  kill "$host" "$keeper"; wait_for 10 "the keeper stand-ins exit" dead "$host"

  rm -f "$ATTACH_LOG"
  home=$(new_home open-fresh)
  home=$(cd "$home" && pwd -P)
  rc=0; "$OPEN" open --home "$home" 2>/dev/null || rc=$?
  expect_code 7 "$rc" "open attaches to the primary it started"
  assert_equals "--stream --home $home" "$(cat "$OPEN_LOG")" "open starts a fresh home's first primary with --stream when no keeper runs"
  assert_equals t:cc "$(cat "$ATTACH_LOG")" "open attaches to the endpoint --stream registered"
  kill "$(cat "$OPEN_LOG.hosts")" 2>/dev/null || true
  unset OPEN_LOG ATTACH_LOG
  pass "fm-deck-chat.sh open: attaches, starts through the keeper or --stream, local chat outside a firstmate home"
}

test_service_launcher_shutdown() {
  local home keeper launcher
  home=$(new_home keeper-shutdown)
  cat > "$LAB/tools/delayed-start" <<'PY'
#!/usr/bin/env python3
import json, os, pathlib, time
home = pathlib.Path(os.environ['FM_HOME'])
(home / 'launcher.json').write_text(json.dumps({'pid': os.getpid(), 'sid': os.getsid(0)}))
with open(home / 'launcher.attempts', 'a') as handle:
    handle.write('%d\n' % os.getpid())
while not (home / 'launcher.release').exists():
    time.sleep(0.05)
(home / 'launcher.finished').touch()
PY
  chmod +x "$LAB/tools/delayed-start"
  FM_DECK_CHAT_SERVICE_POLL=0.1 FM_DECK_CHAT_SERVICE_START_TIMEOUT=0.2 \
    python3 "$BIN/fm_primary_chat.py" service --home "$home" \
    --deck-chat "$LAB/tools/delayed-start" > "$LAB/keeper-shutdown.out" 2>&1 &
  keeper=$!
  fm_test_track_helper_pid "$keeper"
  wait_for 10 "the in-flight launcher" test -s "$home/launcher.json"
  launcher=$(record_field "$home/launcher.json" pid)
  fm_test_track_helper_pid "$launcher"
  assert_equals 0o700 "$(dir_mode "$home/state/primary-chat")" "the keeper creates a private primary-chat directory"
  assert_equals "$launcher" "$(record_field "$home/launcher.json" sid)" "the launcher runs in its own session"
  wait_for 10 "the keeper notices an overdue launcher" grep -q 'start still running past expected' "$home/state/primary-chat/service.log"
  sleep 0.6
  alive "$launcher" || fail "the expected registration window killed the in-flight launcher"
  assert_equals 1 "$(wc -l < "$home/launcher.attempts" | tr -d ' ')" "an overdue launcher never triggers a concurrent attempt"
  assert_equals 1 "$(grep -c 'start still running past expected' "$home/state/primary-chat/service.log")" "the keeper logs an overdue launcher only once"
  kill -TERM "$keeper"
  wait_for 10 "the keeper exits without waiting for registration" dead "$keeper"
  wait "$keeper"
  alive "$launcher" || fail "keeper shutdown killed its in-flight launcher"
  touch "$home/launcher.release"
  wait_for 10 "the detached launcher finishes" test -e "$home/launcher.finished"
  wait_for 10 "the finished launcher exits" dead "$launcher"
  pass "fm-deck-chat.sh service-run: waits past the launcher window without duplication and leaves it running on shutdown"
}

test_service_late_registration() {
  local home keeper host rc=0
  home=$(new_home keeper-late)
  "$BIN/fm-deck-chat.sh" stop --home "$home" 2>/dev/null || rc=$?
  expect_code 1 "$rc" "stop before registration leaves the marker"
  chmod 710 "$home/state/primary-chat"
  FM_DECK_CHAT_SERVICE_POLL=0.1 "$BIN/fm-deck-chat.sh" service-run --home "$home" \
    > "$LAB/keeper-late.out" 2>&1 &
  keeper=$!
  fm_test_track_helper_pid "$keeper"
  wait_for 10 "the keeper honours stop before registration" service_state_is "$home" stopped
  assert_equals 0o710 "$(dir_mode "$home/state/primary-chat")" "the keeper preserves an existing directory's mode"
  FM_DECK_CHAT_SERVICE=1 FAKE_DECK_LOG="$LAB/deck-late.log" "$BIN/fm-deck-chat.sh" --home "$home" \
    </dev/null > "$LAB/host-late.out" 2>&1 &
  host=$!
  fm_test_track_helper_pid "$host"
  wait_for 10 "the late host is stopped" dead "$host"
  wait "$host" 2>/dev/null || true
  assert_present "$home/state/primary-chat/stopped" "late registration never withdraws stop"
  assert_grep 'stopping a late-registered host' "$home/state/primary-chat/service.log" "the keeper logs the late stop"
  assert_grep '"stopped_at"' "$home/state/primary-chat.json" "the late host's record is retired"
  sleep 0.5
  runs_are "$home" 1 || fail "the keeper restarted the late host despite stop"
  kill -TERM "$keeper"
  wait_for 10 "the late-registration keeper exits" dead "$keeper"
  wait "$keeper"
  pass "fm-deck-chat.sh service-run: stop also retires a host that registers late"
}

test_service_inherited_outage() {
  local home keeper
  home=$(new_home keeper-inherited)
  mkdir -m 700 "$home/state/primary-chat"
  echo 'previously alerted outage' > "$home/state/primary-chat/service-down"
  cat > "$LAB/tools/failed-start" <<'SH'
#!/usr/bin/env bash
case "$1" in
  --stream) echo start >> "$FM_HOME/start.attempts"; exit 1 ;;
  service-alert) echo alert >> "$FM_HOME/alerts" ;;
esac
SH
  chmod +x "$LAB/tools/failed-start"
  FM_DECK_CHAT_SERVICE_POLL=0.1 FM_DECK_CHAT_SERVICE_BACKOFF=0.1 FM_DECK_CHAT_SERVICE_BACKOFF_MAX=0.1 \
    FM_DECK_CHAT_SERVICE_ALERT_SECS=0 python3 "$BIN/fm_primary_chat.py" service --home "$home" \
    --deck-chat "$LAB/tools/failed-start" > "$LAB/keeper-inherited.out" 2>&1 &
  keeper=$!
  fm_test_track_helper_pid "$keeper"
  # shellcheck disable=SC2016 # Expanded by the inner bash.
  wait_for 10 "repeated starts during an inherited outage" bash -c '[ "$(wc -l < "$1")" -ge 3 ]' _ "$home/start.attempts"
  kill -TERM "$keeper"
  wait_for 10 "the inherited-outage keeper exits" dead "$keeper"
  wait "$keeper"
  assert_present "$home/state/primary-chat/service-down" "an ongoing outage retains its alert marker"
  assert_absent "$home/alerts" "a replacement keeper never re-alerts the same outage"
  pass "fm-deck-chat.sh service-run: an inherited outage is already alerted"
}

test_service_keeper() {
  local home keeper first second deck_pid session out
  if ! start_test_hub "$LAB/keeper-hub"; then
    pass "fm-deck-chat.sh service keeper skipped without curl and jq"
    return
  fi
  home=$(new_home keeper)
  local saved_shell=${SHELL-}
  export SHELL=/bin/bash FM_STREAM_HUB="$HUB_URL" FM_STREAM_TOKEN="$HUB_TOKEN" FM_STREAM_MACHINE=box-test
  export FAKE_DECK_LOG="$LAB/deck-keeper.log"
  out=$("$BIN/fm-deck-chat.sh" --stream --home "$home" --model fake/route 2>&1) || fail "--stream failed: $out"
  first=$(python3 "$BIN/fm_primary_chat.py" record pid --home "$home")
  session=$(cat "$home/state/primary-chat/session")
  echo 'previously alerted outage' > "$home/state/primary-chat/service-down"
  alarm_recorder "$LAB/tools/adoption-alarm"
  ALARM_LOG="$LAB/adoption-alarm.log" FM_WEDGE_ALARM_EXEC="$LAB/tools/adoption-alarm" FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_DECK_CHAT_SERVICE_ALERT_SECS=0 FM_DECK_CHAT_SERVICE_POLL=0.2 FM_DECK_CHAT_SERVICE_BACKOFF=0.5 \
    FM_DECK_CHAT_SERVICE_STABLE_SECS=2 \
    "$BIN/fm-deck-chat.sh" service-run --home "$home" --model fake/route > "$LAB/keeper.out" 2>&1 &
  keeper=$!
  fm_test_track_helper_pid "$keeper"
  wait_for 10 "the keeper adopts the live host" service_state_is "$home" running
  sleep 1
  runs_are "$home" 1 || fail "the keeper started a second primary next to a live one"
  assert_equals "$first" "$(python3 "$BIN/fm_primary_chat.py" record pid --home "$home")" "the adopted host is untouched"
  wait_for 10 "an inherited alert marker clears after stable adoption" test ! -e "$home/state/primary-chat/service-down"
  assert_absent "$LAB/adoption-alarm.log" "adoption of a recovered host never re-alerts"

  # Anything but stop is a crash: deck exiting on its own is restarted.
  deck_pid=$(record_field "$FAKE_DECK_LOG" pid)
  kill -TERM "$deck_pid"
  wait_for 10 "the crashed host exits" dead "$first"
  wait_for 30 "the keeper restarts the host" host_is_not "$home" "$first"
  second=$(python3 "$BIN/fm_primary_chat.py" record pid --home "$home")
  runs_are "$home" 2 || fail "one restart runs session start once"
  assert_contains "$(cat "$FAKE_DECK_LOG")" "\"--session\", \"$session\"" "the restart resumes the same deck session"
  assert_contains "$(cat "$FAKE_DECK_LOG")" '"--model", "fake/route"' "the restart keeps the model"
  assert_grep 'primary is down; restarting now' "$home/state/primary-chat/service.log" "the keeper logs the restart"

  # stop is honoured: the marker keeps the keeper from restarting.
  "$BIN/fm-deck-chat.sh" stop --home "$home" >/dev/null
  wait_for 10 "the stopped host exits" dead "$second"
  wait_for 10 "the keeper reports stopped" service_state_is "$home" stopped
  sleep 1.5
  runs_are "$home" 2 || fail "the keeper restarted a primary stopped on purpose"

  # A captain start withdraws the stop and the keeper adopts it.
  out=$("$BIN/fm-deck-chat.sh" --stream --home "$home" --model fake/route 2>&1) || fail "restart --stream failed: $out"
  assert_absent "$home/state/primary-chat/stopped" "a captain --stream clears the marker"
  wait_for 10 "the keeper adopts the captain's host" service_state_is "$home" running
  sleep 1
  runs_are "$home" 3 || fail "the keeper duplicated the captain's start"
  kill -TERM "$keeper"
  wait_for 10 "the keeper exits on SIGTERM" dead "$keeper"
  "$BIN/fm-deck-chat.sh" stop --home "$home" >/dev/null
  unset FM_STREAM_HUB FM_STREAM_TOKEN FM_STREAM_MACHINE FAKE_DECK_LOG
  export SHELL="$saved_shell"
  pass "fm-deck-chat.sh service-run: adopts a live host, restarts a crash on the same session, honours stop"
}

test_service_keeper_alerts() {
  local home keeper
  if ! start_test_hub "$LAB/alert-hub"; then
    pass "fm-deck-chat.sh service alert skipped without curl and jq"
    return
  fi
  home=$(new_home keeper-alert)
  # A task named primary makes every start fail, as a crash loop would.
  printf 'id=primary\n' > "$home/state/primary.meta"
  alarm_recorder "$LAB/tools/keeper-alarm"
  local saved_shell=${SHELL-}
  export SHELL=/bin/bash FM_STREAM_HUB="$HUB_URL" FM_STREAM_TOKEN="$HUB_TOKEN" FM_STREAM_MACHINE=box-test
  FAKE_DECK_LOG="$LAB/deck-alert.log" ALARM_LOG="$LAB/keeper-alarm.log" \
    FM_WEDGE_ALARM_EXEC="$LAB/tools/keeper-alarm" FM_WEDGE_ALARM_CHANNEL=osascript \
    FM_DECK_CHAT_SERVICE_POLL=0.2 FM_DECK_CHAT_SERVICE_BACKOFF=0.5 FM_DECK_CHAT_SERVICE_STABLE_SECS=2 \
    FM_DECK_CHAT_SERVICE_ALERT_SECS=1 \
    "$BIN/fm-deck-chat.sh" service-run --home "$home" > "$LAB/keeper-alert.out" 2>&1 &
  keeper=$!
  fm_test_track_helper_pid "$keeper"
  wait_for 60 "the down alert" grep -q "osascript|firstmate primary for $home has been down" "$LAB/keeper-alarm.log"
  assert_present "$home/state/primary-chat/service-down" "a down alert leaves a durable marker"
  assert_grep 'the host exited before registering' "$home/state/primary-chat/service.log" "a failed start is reported fast"
  rm -f "$home/state/primary.meta"
  wait_for 90 "the keeper recovers the primary" service_state_is "$home" running
  assert_equals 1 "$(wc -l < "$LAB/keeper-alarm.log" | tr -d ' ')" "one alert per outage"
  wait_for 10 "the alert marker clears after a stable run" test ! -e "$home/state/primary-chat/service-down"
  kill -TERM "$keeper"
  wait_for 10 "the alert keeper exits" dead "$keeper"
  "$BIN/fm-deck-chat.sh" stop --home "$home" >/dev/null
  unset FM_STREAM_HUB FM_STREAM_TOKEN FM_STREAM_MACHINE
  export SHELL="$saved_shell"
  pass "fm-deck-chat.sh service-run: a primary that stays down raises one alert and clears it on recovery"
}

test_steer_contract_without_a_host
test_stop_marker
test_service_install
test_service_alert
test_attach_follows_restarts
test_open_attaches_or_starts
test_service_launcher_shutdown
test_service_late_registration
test_service_inherited_outage
test_startup_completion_required
test_startup_handoff
test_host_lifecycle
test_oversized_watcher_output
test_stream_endpoint_host
test_task_named_primary_blocks_the_host
test_away_mode_pauses_the_watcher
test_service_keeper
test_service_keeper_alerts
