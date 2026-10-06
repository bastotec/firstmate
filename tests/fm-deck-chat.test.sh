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
  local home rc=0 out pid
  home=$(new_home steer-contract)
  "$STEER" publish --home "$home" --text 'hello' >/dev/null 2>&1 || rc=$?
  expect_code 3 "$rc" "publish with no registered primary"
  rc=0; out=$("$STEER" status --home "$home") || rc=$?
  expect_code 3 "$rc" "status with no registered primary"
  assert_contains "$out" '"present": false' "status reports absence"
  rc=0; "$STEER" delivered 1 --home "$home" || rc=$?
  expect_code 3 "$rc" "delivered with no registered primary"

  # A registered host: any live process whose argv carries fm-deck-chat.
  bash -c 'exec -a fm-deck-chat sleep 300' &
  pid=$!
  fm_test_track_helper_pid "$pid"
  python3 "$BIN/fm_primary_chat.py" prepare --home "$home" --session s1 >/dev/null
  python3 "$BIN/fm_primary_chat.py" record write --home "$home" --session s1 --host-pid "$pid"
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
  rc=0; FM_GATE_REFUSE_BYPASS='' NO_MISTAKES_GATE=1 "$BIN/fm-deck-chat.sh" stop --home "$home" 2>/dev/null || rc=$?
  expect_code 3 "$rc" "a gate agent cannot stop the primary"
  alive "$pid" || fail "a refused stop leaves the host running"

  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null || true
  rc=0; "$STEER" publish --home "$home" --text 'late' 2>/dev/null || rc=$?
  expect_code 3 "$rc" "a dead host is not present"
  pass "fm-primary-steer.sh: publish/status/delivered semantics, ordering and exit codes"
}

test_host_lifecycle() {
  local home host second rc=0 out first_watch session
  home=$(new_home host)
  echo 'export FM_CHECK_INTERVAL=30' > "$home/config/x-mode.env"
  FAKE_DECK_LOG="$LAB/deck.log" "$BIN/fm-deck-chat.sh" --home "$home" --model fake/route \
    < /dev/null > "$LAB/host.out" 2>&1 &
  host=$!
  fm_test_track_helper_pid "$host"
  wait_for 10 "the host registers" "$STEER" status --home "$home"
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
  "$STEER" publish --home "$home" --text 'SLOW captain question' >/dev/null
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
  "$BIN/fm-deck-chat.sh" stop --home "$home" >/dev/null
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
  assert_contains "$out" "attach: bin/fm-stream.sh attach $target" "--stream prints the read-only attach command"
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

test_steer_contract_without_a_host
test_startup_completion_required
test_startup_handoff
test_host_lifecycle
test_oversized_watcher_output
test_stream_endpoint_host
test_away_mode_pauses_the_watcher
