#!/usr/bin/env bash
# Stalled episode timing, conservative evidence, batched delivery and dedup.
set -u
FM_IDLE_SWEEP_TEST_SKIP_RUN=1
export FM_IDLE_SWEEP_TEST_SKIP_RUN
# shellcheck source=tests/fm-idle-sweep.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-idle-sweep.test.sh"

python3 - "$ROOT/bin/fm_stall_record.py" "$TMP_ROOT" <<'PY' || fail 'timing classifier'
import json, pathlib, subprocess, sys
cli, root = sys.argv[1], pathlib.Path(sys.argv[2])
meta, record = root/'timing.meta', root/'timing.json'
meta.write_text('kind=ship\nmode=no-mistakes\nspawn_gen=one\n')
working = 'state: working · source: pane · harness busy'
run = 'attributed-run'
parked = f'state: parked · source: run-step · review gate · evidence: run={run}; step=review; run-created=9000'
question = 'review\tneeds-decision\tWhich behavior should be retained?'
def call(now, current=working, decisions='', mode='--observe'):
    args = [sys.executable, cli, str(record), str(meta), current, decisions, '--now', str(now)]
    if mode:
        args.append(mode)
    return json.loads(subprocess.check_output(args))
assert call(10000)['state'] == 'observing'
assert call(17200)['state'] == 'observing'  # strictly more than two hours
r = call(17201)
assert r['state'] == 'stalled' and r['notify'] and not r['questions']
assert r['route'] == 'mate-repair' and r['age_seconds'] == 7201
assert not call(17202, mode='--ack')['notify']
assert not call(18000)['notify']
assert call(18001, 'state: working · source: run-step · review running')['state'] == 'ineligible'
assert call(18002)['age_seconds'] == 0
assert call(18003, parked, question)['state'] == 'observing'
assert call(21603, parked, question)['state'] == 'observing'
r = call(21604, parked, question)
assert r['notify'] and r['questions'] == ['Which behavior should be retained?']
assert r['seconds_since_last_run'] == 12604 and r['route'] == 'mate-triage'
assert call(21605, parked, question)['last_run_seen'] == 9000
assert not call(21605, parked, question, '--ack')['notify']
assert call(21606, parked, 'new\tneeds-decision\tNew question')['age_seconds'] == 0
assert call(21607, parked, '')['state'] == 'ineligible'  # resolution removes ask
for invalid in ['{broken', '{}', '[]', '{"since": -3}', '{"since": "100"}']:
    record.write_text(invalid)
    assert call(25000)['age_seconds'] == 0
r = call(25001)
r['since'] = 999999
record.write_text(json.dumps(r))
assert call(25002)['age_seconds'] == 0
r = call(25003)
r['observed_at'] = 999999
record.write_text(json.dumps(r))
assert call(25004)['age_seconds'] == 0
before = record.read_bytes()
assert call(35000, mode='')['state'] == 'stalled'
assert record.read_bytes() == before  # recovery traversal is read-only
meta.write_text('kind=ship\nmode=no-mistakes\nspawn_gen=two\n')
assert call(35001)['age_seconds'] == 0
assert call(35002, 'state: unknown · source: run-step · lookup failed')['state'] == 'ineligible'
assert call(45000)['age_seconds'] == 9999
assert call(45001, working+' · declared-wait: active')['state'] == 'ineligible'
for contents in ['kind=scout\n', 'kind=secondmate\n', 'kind=ship\nmode=direct-PR\n', 'kind=ship\nmode=local-only\n']:
    meta.write_text(contents)
    assert call(45002)['state'] == 'ineligible'
    status = meta.with_suffix('.status')
    status.write_text('needs-decision [key=review]: Which behavior should be retained?\n')
    import os
    os.utime(status, (40000, 40000))
    r = call(45002, 'state: parked · source: status-log · waiting', question)
    assert r['state'] == 'stalled' and r['age_seconds'] == 5002
    assert r['notify'] and r['route'] == 'mate-triage'
    assert not call(45003, 'state: parked · source: status-log · waiting', question, '--ack')['notify']
status.unlink()
meta.write_text('kind=ship\nmode=no-mistakes\nspawn_gen=s40000.1.one\n')
record.unlink()
assert call(50000, mode='')['age_seconds'] == 10000
assert not record.exists()
meta.write_text('kind=ship\nmode=no-mistakes\n')
os.utime(meta, (40000, 40000))
assert call(50000, mode='')['state'] == 'stalled'
for owner in ('gate', 'parked-run'):
    timing = meta.with_suffix('.' + owner)
    if owner == 'gate':
        timing.write_text(json.dumps(dict(run=run, step='review', parked_since=40000)))
    else:
        timing.write_text(f'run={run}\nstep=review\nsince=40000\nnudged=0\nescalated=0\n')
    r = call(50000, parked, question, mode='')
    assert r['state'] == 'stalled' and r['age_seconds'] == 10000 and r['notify']
    assert not record.exists()
    assert call(50000, parked.replace('step=review', 'step=test'), question, mode='')['age_seconds'] == 0
    assert call(50000, parked.replace(run, 'another-run'), question, mode='')['age_seconds'] == 0
    assert call(45000, 'state: working · source: run-step · test running')['state'] == 'ineligible'
    before = record.read_bytes()
    r = call(50000, parked, question, mode='')
    assert r['state'] == 'stalled' and r['age_seconds'] == 10000 and r['notify']
    assert record.read_bytes() == before
    assert call(50000, parked, question)['age_seconds'] == 10000
    assert not call(50000, parked, question, '--ack')['notify']
    assert call(50001, parked, '', '--reported-run')
    assert call(50001, parked, '')['state'] == 'ineligible'
    before = record.read_bytes()
    assert call(50002, parked, '', '--reported-run')
    assert not call(50002, parked.replace('step=review', 'step=test'), '', '--reported-run')
    assert not call(50002, parked.replace(run, 'another-run'), '', '--reported-run')
    assert not call(50002, working, '', '--reported-run')
    assert record.read_bytes() == before
    call(50003, working)
    assert not call(50004, parked, '', '--reported-run')
    record.unlink()
    timing.unlink()
timing.write_text(f'run={run}\nstep=review\nsince=40000\nnudged=44000\nescalated=1\n')
r = call(50000, parked, question)
assert r['state'] == 'stalled' and not r['notify']
assert not call(55000, parked, question)['notify']
assert call(55001, parked, 'other\tneeds-decision\tAnother question')['age_seconds'] == 0
timing.unlink()
record.unlink()
meta.write_text('kind=ship\nmode=no-mistakes\nspawn_gen=s10000.1.recovery\n')
assert call(11000)['since'] == 10000
before = record.read_bytes()
for current in ('', 'state: unknown · source: run-step · unavailable'):
    r = call(17000, current)
    assert r['state'] == 'ineligible' and not r['notify']
    assert record.read_bytes() == before
r = call(18001)
assert r['since'] == 10000 and r['notify']
call(18002, mode='--ack')
before = record.read_bytes()
assert not call(18003, '')['notify']
assert record.read_bytes() == before
assert not call(19000)['notify']
assert call(19001, parked, question)['since'] == 19001
assert call(23002, parked, question)['notify']
call(23003, parked, question, '--ack')
assert not call(23004, '')['notify']
assert not call(23005, parked, question)['notify']
assert call(23006, parked, 'new\tneeds-decision\tA genuinely new question')['since'] == 23006
assert call(27007, parked, 'new\tneeds-decision\tA genuinely new question')['notify']
record.unlink()
running = parked.replace('state: parked', 'state: working').replace('run-created=9000', 'run-created=12000')
assert call(12000, running)['last_run_seen'] == 12000
r = call(20001, mode='')
assert r['state'] == 'stalled' and r['since'] == 12000 and r['notify']
assert call(20001)['since'] == 12000
assert not call(20002, mode='--ack')['notify']
assert not call(21000)['notify']
record.unlink()
gate = meta.with_suffix('.gate')
legacy = meta.with_suffix('.parked-run')
gate.write_text(json.dumps(dict(run=run, step='review', parked_since=10000)))
legacy.write_text(f'run={run}\nstep=review\nsince=10000\nnudged=14000\nescalated=1\n')
assert not call(15000, parked, question)['notify']
assert call(15001, parked, '', '--reported-run')
assert call(16000, running)['state'] == 'ineligible'
gate.write_text(json.dumps(dict(run=run, step='review', parked_since=17000)))
assert not call(21001, parked, '', '--reported-run')
r = call(21001, parked, question, mode='')
assert r['since'] == 17000 and r['notify'] and r['reported'] != r['episode']
r = call(21001, parked, question)
assert r['since'] == 17000 and r['notify']
assert call(21002, parked, question)['notify']
call(21003, parked, question, '--ack')
assert not call(21004, parked, question)['notify']
assert call(21005, parked, '', '--reported-run')
call(21006, parked, '')
assert call(21007, parked, '', '--reported-run')
gate.write_text(json.dumps(dict(run=run, step='review', parked_since=22000)))
r = call(26001, parked, question)
assert r['since'] == 22000 and r['notify']
call(26002, parked, question, '--ack')
gate.write_text(json.dumps(dict(run=run, step='review', parked_since=27000)))
assert not call(31001, parked, '', '--reported-run')
r = call(31001, parked, question)
assert r['since'] == 27000 and r['notify']
gate.unlink()
legacy.unlink()
record.unlink()
gate.write_text(json.dumps(dict(run=run, step='review', parked_since=10000)))
question_a = 'a\tneeds-decision\tQuestion A?'
question_b = 'b\tneeds-decision\tQuestion B?'
questions = question_a + '\n' + question_b
r = call(14001, parked, questions)
assert r['since'] == 10000 and r['notify']
original_episode = r['episode']
r = call(14002, parked, question_b + '\n' + question_a)
assert r['since'] == 10000 and r['episode'] == original_episode and r['notify']
call(14003, parked, questions, '--ack')
r = call(15000, parked, question_b + '\n' + question_a)
assert r['since'] == 10000 and r['episode'] == original_episode and not r['notify']
r = call(15000, parked, question_b)
assert r['since'] == 10000 and r['episode'] == original_episode and not r['notify']
before = record.read_bytes()
r = call(20000, parked, question_b, mode='')
assert r['since'] == 10000 and r['episode'] == original_episode and not r['notify']
assert record.read_bytes() == before
assert not call(15000, parked, question_b)['notify']
call(15001, parked, '')
r = call(15002, parked, 'new\tneeds-decision\tQuestion C?')
assert r['since'] == 15002 and r['state'] == 'observing' and not r['notify']
assert call(18603, parked, 'new\tneeds-decision\tQuestion C?')['notify']
call(18604, parked, 'new\tneeds-decision\tQuestion C?', '--ack')
assert not call(18605, parked, 'new\tneeds-decision\tQuestion C?')['notify']
gate.write_text(json.dumps(dict(run=run, step='review', parked_since=19000)))
r = call(23001, parked, questions)
assert r['since'] == 19000 and r['notify']
gate.unlink()
record.unlink()
for current in (parked, 'state: parked · source: status-log · waiting'):
    r = call(30000, current, questions)
    since, original_episode = r['since'], r['episode']
    r = call(34001, current, question_b)
    assert r['since'] == since and r['episode'] == original_episode and r['notify']
    assert not call(34002, current, question_b, '--ack')['notify']
    assert not call(38000, current, question_b)['notify']
    r = call(38001, current, question_b + '\nnew\tneeds-decision\tQuestion D?')
    assert r['since'] == 38001 and not r['notify']
    assert call(42002, current, question_b + '\nnew\tneeds-decision\tQuestion D?')['notify']
    record.unlink()
for owner in ('gate', 'parked-run', 'status'):
    current = parked if owner != 'status' else 'state: parked · source: status-log · waiting'
    timing = meta.with_suffix('.' + owner)
    if owner == 'gate':
        timing.write_text(json.dumps(dict(run=run, step='review', parked_since=10000)))
    elif owner == 'parked-run':
        timing.write_text(f'run={run}\nstep=review\nsince=10000\nnudged=0\nescalated=0\n')
    for now in (10001, 10005):
        assert call(now, current)['phase'] is None
    before = record.read_bytes()
    assert not call(10006, '')['notify']
    assert record.read_bytes() == before
    if owner == 'status':
        timing.write_text('needs-decision [key=review]: Which behavior should be retained?\n')
        os.utime(timing, (10010, 10010))
    entry = 10010 if owner == 'status' else 10000
    r = call(15000, current, question, mode='')
    assert r['since'] == entry and r['age_seconds'] == 15000 - entry and r['notify']
    assert record.read_bytes() == before
    r = call(15001, current, question)
    original_episode = r['episode']
    assert r['since'] == entry and r['notify']
    assert call(15002, current, question)['episode'] == original_episode
    call(15003, current, question, '--ack')
    assert not call(15004, current, question)['notify']
    assert call(15005, current)['phase'] is None
    assert call(15006, current)['phase'] is None
    r = call(15007, current, 'new\tneeds-decision\tA reopened question?')
    assert r['since'] == 15007 and not r['notify']
    assert call(18608, current, 'new\tneeds-decision\tA reopened question?')['notify']
    call(18609, current, 'new\tneeds-decision\tA reopened question?', '--ack')
    assert not call(18610, current, 'new\tneeds-decision\tA reopened question?')['notify']
    timing.unlink()
    record.unlink()
# A watcher publishing gate timing later enriches, rather than reopens, an ask.
status = meta.with_suffix('.status')
status.write_text('needs-decision [key=review]: Which behavior should be retained?\n')
os.utime(status, (10000, 10000))
r = call(15000, parked, question)
original_episode = r['episode']
assert r['since'] == 10000 and r['notify']
call(15001, parked, question, '--ack')
gate.write_text(json.dumps(dict(run=run, step='review', parked_since=15002)))
before = record.read_bytes()
r = call(20000, parked, question, mode='')
assert r['since'] == 10000 and r['episode'] == original_episode and not r['notify']
assert record.read_bytes() == before
assert call(20001, parked, '', '--reported-run')
r = call(20002, parked, question)
assert r['since'] == 10000 and r['episode'] == original_episode and not r['notify']
assert not call(24000, parked, question)['notify']
# Once both gate stamps are known, a new stamp proves a genuinely recreated gate.
gate.write_text(json.dumps(dict(run=run, step='review', parked_since=24001)))
r = call(28002, parked, question)
assert r['since'] == 24001 and r['episode'] != original_episode and r['notify']
gate.unlink()
status.unlink()
record.unlink()
for delivery in ('ack', 'receipt'):
    status.write_text('needs-decision [key=review]: Which behavior should be retained?\n')
    os.utime(status, (10000, 10000))
    r = call(14001, parked, question)
    if delivery == 'ack':
        call(14002, parked, question, '--ack')
    else:
        receipt = record.with_name(record.stem + '-delivered')
        receipt.write_text('\n'.join(r['delivery_episodes']) + '\n')
    call(14003, parked, '')
    gate.write_text(json.dumps(dict(run=run, step='review', parked_since=14004)))
    before = record.read_bytes()
    assert call(15000, parked, '', '--reported-run')
    assert record.read_bytes() == before
    call(15001, parked, '')
    assert call(15002, parked, '', '--reported-run')
    gate.write_text(json.dumps(dict(run=run, step='review', parked_since=15003)))
    assert not call(19000, parked, '', '--reported-run')
    if delivery == 'receipt':
        receipt.unlink()
    gate.unlink()
    status.unlink()
    record.unlink()
for current in (parked, 'state: parked · source: status-log · waiting'):
    for acknowledged in (False, True):
        r = call(10000, current, question_a)
        if acknowledged:
            r = call(14001, current, question_a, '--ack')
        for field in ('question_ids', 'question_states', 'notify_questions', 'delivery_episodes'):
            r.pop(field, None)
        record.write_text(json.dumps(r))
        r = call(15000, current, question_a)
        assert r['since'] == 10000 and r['notify'] != acknowledged
        record.unlink()
    for malformed in ([], {'since': 999999, 'reported': True, 'episode': 'a' * 64},
                      {'since': 10000, 'reported': 'false', 'episode': 'a' * 64},
                      {'since': 10000, 'reported': False}):
        r = call(10000, current, question_a)
        key = r['question_ids'][0]
        r['question_states'] = {key: malformed}
        record.write_text(json.dumps(r))
        r = call(15000, current, question_a)
        assert r['since'] == 15000 and not r['notify']
        record.unlink()
    for b in (question_b, 'b\tneeds-decision\tQuestion A?'):
        call(10000, current, question_a)
        call(14001, current, question_a, '--ack')
        call(15000, current, question_a + '\n' + b)
        assert not call(15010, current, question_a)['notify']
        r = call(18601, current, question_a)
        assert r['since'] == 10000 and not r['notify']
        assert not r['notify_questions']
        r = call(18602, current, question_a + '\n' + b)
        assert r['since'] == 18602 and not r['notify']
        r = call(22203, current, question_a + '\n' + b)
        assert r['notify'] and r['notify_questions'] == [b.split('\t')[2]]
        assert call(22204, current, question_a + '\n' + b)['episode'] == r['episode']
        call(22205, current, question_a + '\n' + b, '--ack')
        assert not call(26000, current, question_a + '\n' + b)['notify']
        call(26001, current, question_a)
        assert call(26002, current, question_a + '\n' + b)['since'] == 26002
        assert call(29603, current, question_a + '\n' + b)['notify_questions'] == [b.split('\t')[2]]
        record.unlink()
    call(10000, current, question_a)
    call(11000, current, questions)
    assert call(13601, current, questions)['notify_questions'] == ['Question A?']
    call(13602, current, questions, '--ack')
    assert call(14601, current, questions)['notify_questions'] == ['Question B?']
    call(14602, current, questions, '--ack')
    assert not call(18000, current, questions)['notify']
    record.unlink()
head = 'a' * 40
# Ledger fallback aliases identify a head, not a unique run on that head.
ledger_retry = working + f' · evidence: last-run=ledger-{head}; last-run-created=10000; last-run-head={head}'
assert call(18001, ledger_retry)['notify']
call(18002, ledger_retry, mode='--ack')
newer_retry = ledger_retry.replace('created=10000;', 'created=20000;')
r = call(20300, newer_retry)
assert r['last_run_seen'] == 20000 and r['since'] == 20000 and not r['notify']
assert call(20301, ledger_retry)['last_run_seen'] == 20000  # stale fallback cannot roll back
assert call(27200, newer_retry)['state'] == 'observing'
assert call(27201, newer_retry)['notify']
call(27202, newer_retry, mode='--ack')
assert not call(28000, newer_retry)['notify']
record.unlink()
ledger = working + f' · evidence: last-run=ledger-{head}; last-run-created=21960; last-run-head={head}'
primary = working + f' · evidence: last-run=terminal-run; last-run-created=22000; last-run-head={head}'
replacement = primary.replace(working, 'state: working · source: run-step · resumed') + \
    '; run=terminal-run; step=review; run-created=22000; implementation=replacement'
for first, second, since in ((ledger, primary, 21960), (primary, ledger, 22000),
                             (ledger, replacement, 21960), (replacement, ledger, 22000)):
    r = call(30000, first)
    original_episode = r['episode']
    assert r['since'] == since and r['notify']
    call(30001, first, mode='--ack')
    for now, current in ((30002, second), (30003, first), (30004, second)):
        r = call(now, current)
        assert r['since'] == since and r['episode'] == original_episode and not r['notify']
    before = record.read_bytes()
    assert not call(40000, second, mode='')['notify']
    assert record.read_bytes() == before
    newer = primary.replace('terminal-run;', 'another-terminal-run;').replace('22000;', '22020;')
    r = call(40001, newer)
    assert r['since'] == 22020 and r['episode'] != original_episode and r['notify']
    record.unlink()
record.symlink_to(root/'untouched')
p = subprocess.run([sys.executable, cli, str(record), str(meta), working, '', '--observe'], capture_output=True)
assert p.returncode != 0 and not (root/'untouched').exists()
print('ok: strict thresholds, transitions, timing validation, read-only traversal and symlink refusal')
PY

for route in main parent; do
  dir=$(new_case "stall-$route")
  [ "$route" != parent ] || make_secondmate_home "$dir" mate
  add_worker "$dir" implementation 'state: working · source: pane · busy' 90000
  add_worker "$dir" decision 'state: parked · source: status-log · pending choice' 90000
  printf 'needs-decision [key=choice]: Keep the old behavior?\n' > "$dir/home/state/decision.status"
  old=$(( $(date +%s) - 8000 ))
  python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/implementation.stall.json" \
    "$dir/home/state/implementation.meta" "$(cat "$dir/home/crew/implementation")" '' --observe --now "$old" >/dev/null
  python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/decision.stall.json" \
    "$dir/home/state/decision.meta" "$(cat "$dir/home/crew/decision")" \
    $'choice\tneeds-decision\tKeep the old behavior?' --observe --now "$old" >/dev/null
  sweep "$dir" scan --now || fail 'stall scan'
  [ "$(summary_of "$dir" implementation)" = 'stalled none' ] || fail "implementation not stalled: $(cat "$dir/home/state/idle-sweep.json") $(cat "$dir/home/state/idle-sweep/implementation.stall.json")"
  [ "$(summary_of "$dir" decision)" = 'stalled none' ] || fail 'decision not stalled'
  target="$dir/home/state/.wake-queue"
  [ "$route" != parent ] || target="$dir/parent/state/mate.status"
  [ "$(grep -c 'stalled tasks digest:' "$target")" = 1 ] || fail 'not one batched digest'
  assert_contains "$(cat "$target")" 'Keep the old behavior?' 'question missing'
  assert_contains "$(cat "$target")" 'mate repair:' 'repair not distinguished'
  sweep "$dir" scan --now || fail 'repeat scan'
  [ "$(grep -c 'stalled tasks digest:' "$target")" = 1 ] || fail 'duplicate digest'
  [ ! -s "$dir/home/control-calls" ] || fail 'stall caused relaunch'
  [ ! -s "$dir/home/teardown-calls" ] || fail 'stall caused cleanup'
  assert_no_captain_call "$dir" 'stall digest'
  touch "$dir/home/held/decision"
  sweep "$dir" scan --now || fail 'held scan'
  [ "$(summary_of "$dir" decision)" = 'held none' ] || fail 'hold overridden'
  pass "stalled tasks batch and deduplicate on $route route without changing authority"
done

dir=$(new_case stall-redelivery)
add_worker "$dir" implementation 'state: working · source: pane · busy' 90000
old=$(( $(date +%s) - 8000 ))
python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/implementation.stall.json" \
  "$dir/home/state/implementation.meta" "$(cat "$dir/home/crew/implementation")" '' --observe --now "$old" >/dev/null
mkdir "$dir/home/state/.wake-queue"
sweep "$dir" scan --now || fail 'failed-delivery scan'
[ "$(jq -r .notify "$dir/home/state/idle-sweep/implementation.stall.json")" = true ] || fail 'failed delivery acknowledged'
rmdir "$dir/home/state/.wake-queue"
sweep "$dir" scan --now || fail 'redelivery scan'
[ "$(wake_count "$dir" 'stalled tasks digest:')" = 1 ] || fail 'redelivery missing'
[ "$(jq -r .reported "$dir/home/state/idle-sweep/implementation.stall.json")" != null ] || fail 'delivery not acknowledged'
pass 'failed digest publication leaves the episode eligible for redelivery'

for route in main parent; do
  dir=$(new_case "stall-question-receipts-$route")
  [ "$route" != parent ] || make_secondmate_home "$dir" mate
  current='state: parked · source: run-step · evidence: run=run-one; step=review'
  add_worker "$dir" decision "$current" 90000
  real_date=$(command -v date)
  printf '%s\n' "$real_date" > "$dir/home/real-date"
  cat > "$dir/bin/date" <<'SH'
#!/usr/bin/env bash
if [ "$*" = +%s ]; then
  cat "$FM_HOME/test-clock"
else
  exec "$(cat "$FM_HOME/real-date")" "$@"
fi
SH
  chmod +x "$dir/bin/date"
  question_a=$'a\tneeds-decision\tProceed?'
  question_b=$'b\tneeds-decision\tProceed?'
  question_c=$'c\tneeds-decision\tAnother question?'
  record="$dir/home/state/idle-sweep/decision.stall.json"
  target="$dir/home/state/.wake-queue"
  [ "$route" != parent ] || target="$dir/parent/state/mate.status"
  observe_questions() {
    printf '%s\n' "$1" > "$dir/home/test-clock"
    decisions=$2
    stall=$(python3 "$dir/bin/fm_stall_record.py" "$record" \
      "$dir/home/state/decision.meta" "$current" "$decisions" --observe --now "$1") || fail 'question observation'
  }
  publish_questions() {
    jq -cn --arg id decision --arg current "$current" --arg decisions "$decisions" --argjson stall "$stall" \
      '{id:$id,current:$current,decisions:$decisions,stall:$stall}' \
      | PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$dir/bin/fm-parked-run-watch.sh" digest
  }
  observe_questions 10000 "$question_a"
  observe_questions 14001 "$question_a"
  publish_questions || fail 'first question publication'
  observe_questions 15000 "$question_a"$'\n'"$question_b"
  observe_questions 15010 "$question_a"
  observe_questions 18601 "$question_a"
  publish_questions || fail 'surviving question reconciliation'
  [ "$(grep -c 'stalled tasks digest:' "$target")" = 1 ] || fail 'transient expansion repeated delivered A'
  observe_questions 18602 "$question_a"$'\n'"$question_b"$'\n'"$question_c"
  observe_questions 22203 "$question_a"$'\n'"$question_b"$'\n'"$question_c"
  mv "$target" "$target.saved"
  mkdir "$target"
  if publish_questions; then fail 'question publication unexpectedly succeeded'; fi
  [ "$(jq -r .notify "$record")" = true ] || fail 'failed question publication suppressed retry'
  rmdir "$target"
  mv "$target.saved" "$target"
  touch "$dir/home/interrupt-after-publication"
  if [ "$route" = parent ]; then
    cat >> "$dir/bin/fm-parent-channel-lib.sh" <<'SH'
eval "$(declare -f fm_parent_channel_report | sed '1s/fm_parent_channel_report/fm_test_real_report/')"
fm_parent_channel_report() {
  fm_test_real_report "$@" || return $?
  if [ -f "$FM_HOME/interrupt-after-publication" ]; then
    rm "$FM_HOME/interrupt-after-publication"
    kill -TERM "$$"
    exit 143
  fi
}
SH
  else
    cat >> "$dir/bin/fm-wake-lib.sh" <<'SH'
eval "$(declare -f fm_wake_append_locked | sed '1s/fm_wake_append_locked/fm_test_real_append/')"
fm_wake_append_locked() {
  fm_test_real_append "$@" || return $?
  if [ -f "$FM_HOME/interrupt-after-publication" ]; then
    rm "$FM_HOME/interrupt-after-publication"
    kill -TERM "$$"
    exit 143
  fi
}
SH
  fi
  if publish_questions; then fail 'publication interruption did not execute'; fi
  [ "$(grep -c 'stalled tasks digest:' "$target")" = 2 ] || fail 'new keyed questions not published'
  observe_questions 22204 "$question_a"$'\n'"$question_c"
  publish_questions || fail 'surviving question receipt recovery'
  observe_questions 22205 "$question_a"$'\n'"$question_c"
  publish_questions || fail 'surviving question receipt retry'
  [ "$(jq -r .notify "$record")" = false ] || fail 'surviving delivered C remained eligible'
  [ "$(grep -c 'stalled tasks digest:' "$target")" = 2 ] || fail 'restart repeated delivered survivor C'
  python3 - "$target" <<'PY' || fail 'digest repeated already-delivered question A'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text()
assert text.count('Proceed?') == 2 and text.count('Another question?') == 1
PY
  observe_questions 22206 "$question_a"$'\n'"$question_b"$'\n'"$question_c"
  [ "$(jq -r .since "$record")" = 22206 ] || fail 'reopened B inherited old delivery'
  observe_questions 25807 "$question_a"$'\n'"$question_b"$'\n'"$question_c"
  publish_questions || fail 'reopened B publication'
  observe_questions 25808 "$question_a"$'\n'"$question_b"$'\n'"$question_c"
  publish_questions || fail 'reopened B publication retry'
  [ "$(grep -c 'stalled tasks digest:' "$target")" = 3 ] || fail 'reopened keyed question missing or duplicated'
  pass "keyed receipts preserve survivors, failed publication and restart retry on $route route"
done

for recovery in queued consumed parent parent-closed; do
  dir=$(new_case "stall-interrupted-$recovery")
  case "$recovery" in parent*) make_secondmate_home "$dir" mate ;; esac
  add_worker "$dir" decision 'state: parked · source: run-step · evidence: run=run-one; step=review' 90000
  printf 'needs-decision [key=choice]: Original question?\n' > "$dir/home/state/decision.status"
  old=$(( $(date +%s) - 8000 ))
  python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/decision.stall.json" \
    "$dir/home/state/decision.meta" "$(cat "$dir/home/crew/decision")" \
    $'choice\tneeds-decision\tOriginal question?' --observe --now "$old" >/dev/null
  touch "$dir/home/interrupt-after-publication"
  if [[ "$recovery" = parent* ]]; then
    cat >> "$dir/bin/fm-parent-channel-lib.sh" <<'SH'
eval "$(declare -f fm_parent_channel_report | sed '1s/fm_parent_channel_report/fm_test_real_report/')"
fm_parent_channel_report() {
  fm_test_real_report "$@" || return $?
  if [ -f "$FM_HOME/interrupt-after-publication" ]; then
    rm "$FM_HOME/interrupt-after-publication"
    kill -TERM "$$"
    exit 143
  fi
}
SH
  else
    cat >> "$dir/bin/fm-wake-lib.sh" <<'SH'
eval "$(declare -f fm_wake_append_locked | sed '1s/fm_wake_append_locked/fm_test_real_append/')"
fm_wake_append_locked() {
  fm_test_real_append "$@" || return $?
  if [ -f "$FM_HOME/interrupt-after-publication" ]; then
    rm "$FM_HOME/interrupt-after-publication"
    kill -TERM "$$"
    exit 143
  fi
}
SH
  fi
  sweep "$dir" scan --now || fail 'interrupted publication scan'
  target="$dir/home/state/.wake-queue"
  case "$recovery" in parent*) target="$dir/parent/state/mate.status" ;; esac
  [ "$(grep -c 'Original question?' "$target")" = 1 ] || fail 'interrupted publication was not delivered'
  [ "$(jq -r .reported "$dir/home/state/idle-sweep/decision.stall.json")" = null ] || fail 'interruption did not precede acknowledgment'
  [ ! -e "$dir/home/state/idle-sweep/decision.stall-delivered" ] || fail 'interruption did not precede queue reconciliation'
  if [ "$recovery" = parent-closed ]; then
    printf 'resolved [key=choice]: Keep the old behavior.\n' >> "$dir/home/state/decision.status"
    printf 'run=run-one\nstep=review\nsince=%s\nnudged=0\nescalated=0\n' "$old" > "$dir/home/state/decision.parked-run"
    cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = --publish ]; then
  shift
  printf 'verdict=parked\nrun=run-one\nstep=review\n' > "$FM_HOME/state/$1.crew-state"
fi
cat "$FM_HOME/crew/$1"
SH
    chmod +x "$dir/bin/fm-crew-state.sh"
    for _ in 1 2; do
      sweep "$dir" scan --now || fail 'closed interrupted publication recovery'
      [ "$(jq -r .episode "$dir/home/state/idle-sweep/decision.stall.json")" = null ] || fail 'resolved question kept an active episode'
      [ "$(python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/decision.stall.json" \
        "$dir/home/state/decision.meta" "$(cat "$dir/home/crew/decision")" '' --reported-run)" = true ] \
        || fail 'closed question lost successful parent publication suppression'
      PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown FM_HOME="$dir/home" FM_PARKED_RUN_SECS=0 \
        "$dir/bin/fm-parked-run-watch.sh" scan || fail 'closed interrupted publication watchdog'
      [ ! -s "$dir/home/state/.wake-queue" ] || fail 'watchdog repeated delivered closed question'
      [ "$(grep -c 'stalled tasks digest:' "$target")" = 1 ] || fail 'closed question duplicated on parent channel'
    done
    pass 'parent publication survives publisher death and question resolution before idle observation and watchdog'
    continue
  fi
  if [ "$recovery" = consumed ]; then
    seq=$(cat "$dir/home/state/.wake-queue.seq")
    generation=$(cat "$dir/home/state/.watcher-down")
    mkdir "$dir/home/state/idle-sweep/decision.stall-delivered"
    if PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$dir/bin/fm-wake-drain.sh" \
      --ack-through "$seq" --recovery-generation "${generation##*:}"; then
      fail 'drain consumed a digest without a durable delivery receipt'
    fi
    [ -s "$target" ] || fail 'failed receipt consumed the queue row'
    rmdir "$dir/home/state/idle-sweep/decision.stall-delivered"
    PATH="$dir/bin:$PATH" FM_HOME="$dir/home" "$dir/bin/fm-wake-drain.sh" \
      --ack-through "$seq" --recovery-generation "${generation##*:}" || fail 'digest queue acknowledgment'
    [ ! -s "$target" ] || fail 'digest queue row not consumed'
    episode=$(jq -r .episode "$dir/home/state/idle-sweep/decision.stall.json")
    grep -Fqx "$episode" "$dir/home/state/idle-sweep/decision.stall-delivered" || fail 'consumed digest lost delivery evidence'
    [ "$(python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/decision.stall.json" \
      "$dir/home/state/decision.meta" "$(cat "$dir/home/crew/decision")" '' --reported-run)" = true ] \
      || fail 'consumed digest did not suppress legacy publisher'
  fi
  add_worker "$dir" later 'state: working · source: pane · busy' 90000
  python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/later.stall.json" \
    "$dir/home/state/later.meta" "$(cat "$dir/home/crew/later")" '' --observe --now "$old" >/dev/null
  sweep "$dir" scan --now || fail 'interrupted publication recovery'
  count=$(grep -c 'Original question?' "$target") || count=0
  expected=1
  [ "$recovery" != consumed ] || expected=0
  [ "$count" = "$expected" ] || fail 'interrupted publication repeated the old question in a changed batch'
  [ "$(grep -c 'later: mate repair:' "$target")" = 1 ] || fail 'new episode lost during publication recovery'
  sweep "$dir" scan --now || fail 'interrupted publication repeat recovery'
  [ "$(grep -c 'later: mate repair:' "$target")" = 1 ] || fail 'recovered new episode duplicated'
  [ "$(jq -r .notify "$dir/home/state/idle-sweep/decision.stall.json")" = false ] || fail 'original episode not acknowledged on recovery'
  pass "successful publication interrupted before acknowledgment reconciles on $recovery recovery"
done

for transition in validation completed-validation unknown new-question; do
  dir=$(new_case "stall-admission-$transition")
  current='state: working · source: pane · busy'
  decisions=''
  if [ "$transition" = new-question ]; then
    current='state: parked · source: run-step · evidence: run=run-one; step=review'
    decisions=$'choice\tneeds-decision\tOld question?'
  fi
  add_worker "$dir" worker "$current" 90000
  [ -z "$decisions" ] || printf 'needs-decision [key=choice]: Old question?\n' > "$dir/home/state/worker.status"
  old=$(( $(date +%s) - 8000 ))
  python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/worker.stall.json" \
    "$dir/home/state/worker.meta" "$current" "$decisions" --observe --now "$old" >/dev/null
  cp "$dir/home/state/idle-sweep/worker.stall.json" "$dir/before.json"
  printf '%s\n' "$transition" > "$dir/home/transition"
  if [ "$transition" = completed-validation ]; then
    date +%s > "$dir/home/test-clock"
    # shellcheck disable=SC2016 # Expand variables in the generated child script, not here.
    printf '#!/usr/bin/env bash\nif [ "$*" = +%%s ]; then cat "$FM_HOME/test-clock"; else exec %s "$@"; fi\n' \
      "$(command -v date)" > "$dir/bin/date"
    chmod +x "$dir/bin/date"
  fi
  cat > "$dir/home/on-crew-state" <<'SH'
#!/usr/bin/env bash
[ -d "$FM_HOME/state/.control-$1.lock" ] || exit 0
printf '%s\n' "$1" >> "$FM_HOME/admission-reads"
case "$(cat "$FM_HOME/transition")" in
  validation) printf 'state: working · source: run-step · evidence: run=run-new; step=test\n' > "$FM_HOME/crew/$1" ;;
  completed-validation)
    now=$(cat "$FM_HOME/test-clock")
    printf '%s\n' "$((now + 10))" > "$FM_HOME/test-clock"
    printf 'state: working · source: pane · evidence: last-run=run-new; last-run-created=%s\n' "$((now + 5))" > "$FM_HOME/crew/$1"
    ;;
  unknown) printf 'state: unknown · source: run-step · read unavailable\n' > "$FM_HOME/crew/$1" ;;
  new-question) printf 'needs-decision [key=choice]: New question?\n' >> "$FM_HOME/state/$1.status" ;;
esac
SH
  chmod +x "$dir/home/on-crew-state"
  sweep "$dir" scan --now || fail 'publication recheck scan'
  [ -s "$dir/home/admission-reads" ] || fail 'current state not read at admission'
  count=$(wake_count "$dir" 'stalled tasks digest:')
  [ "${count:-0}" = 0 ] || fail 'stale episode published'
  [ "$(jq -r .reported "$dir/home/state/idle-sweep/worker.stall.json")" = null ] || fail 'stale episode acknowledged'
  if [ "$transition" = completed-validation ]; then
    expected=$(( $(cat "$dir/home/test-clock") - 5 ))
    [ "$(jq -r .since "$dir/home/state/idle-sweep/worker.stall.json")" = "$expected" ] \
      || fail 'admission rejected validation completed after scan start'
  fi
  if [ "$transition" = unknown ]; then
    [ "$(jq -r .since "$dir/home/state/idle-sweep/worker.stall.json")" = \
      "$(jq -r .since "$dir/before.json")" ] || fail 'unknown reset original timing'
    rm "$dir/home/on-crew-state"
    printf '%s\n' "$current" > "$dir/home/crew/worker"
    sweep "$dir" scan --now || fail 'healthy retry scan'
    [ "$(wake_count "$dir" 'stalled tasks digest:')" = 1 ] || fail 'healthy retry not delivered'
    sweep "$dir" scan --now || fail 'healthy duplicate scan'
    [ "$(wake_count "$dir" 'stalled tasks digest:')" = 1 ] || fail 'healthy retry duplicated'
  fi
  assert_no_captain_call "$dir" 'publication recheck'
  pass "publication admission reconciles $transition without acknowledging stale work"
done

for route in main parent; do
  for first in watcher sweep legacy; do
    dir=$(new_case "cross-owner-$route-$first")
    [ "$route" != parent ] || make_secondmate_home "$dir" mate
    add_worker "$dir" decision 'state: parked · source: run-step · evidence: run=run-one; step=review' 90000
    printf 'needs-decision [key=choice]: Keep the old behavior?\n' > "$dir/home/state/decision.status"
    old=$(( $(date +%s) - 8000 ))
    nudged=0
    [ "$first" != legacy ] || nudged=$((old + 4000))
    printf 'run=run-one\nstep=review\nsince=%s\nnudged=%s\nescalated=0\n' "$old" "$nudged" > "$dir/home/state/decision.parked-run"
    mkdir -p "$dir/home/published"
    printf 'verdict=parked\nrun=run-one\nstep=review\n' > "$dir/home/published/decision"
    cat > "$dir/bin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = --publish ]; then
  shift
  cp "$FM_HOME/published/$1" "$FM_HOME/state/$1.crew-state"
fi
cat "$FM_HOME/crew/$1"
SH
    chmod +x "$dir/bin/fm-crew-state.sh"
    if [ "$first" = sweep ]; then
      sweep "$dir" scan --now || fail 'initial cross-owner sweep'
    fi
    for _ in 1 2; do
      before_lifecycle=$(calls "$dir" retire-calls)
      PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown FM_HOME="$dir/home" FM_PARKED_RUN_SECS=0 \
        "$dir/bin/fm-parked-run-watch.sh" scan || fail 'cross-owner watcher scan'
      [ "$(calls "$dir" retire-calls)" = "$before_lifecycle" ] || fail 'parked scan forced lifecycle traversal'
      sweep "$dir" scan --now || fail 'cross-owner idle scan'
    done
    target="$dir/home/state/.wake-queue"
    [ "$route" != parent ] || target="$dir/parent/state/mate.status"
    expected=1
    [ "$first" != legacy ] || expected=0
    count=$(grep -c 'stalled tasks digest:' "$target" 2>/dev/null) || count=0
    [ "$count" = "$expected" ] || fail "cross-owner digest count: $route $first $count"
    if [ -f "$target" ]; then
      assert_not_contains "$(cat "$target")" 'parked-run:' 'independent parked wake or escalation'
    fi
    [ "$(summary_of "$dir" decision)" = 'stalled none' ] || fail 'aged parked recovery not stalled'
    if [ "$first" != legacy ]; then
      [ "$(jq -r .reported "$dir/home/state/idle-sweep/decision.stall.json")" = \
        "$(jq -r .episode "$dir/home/state/idle-sweep/decision.stall.json")" ] || fail 'digest not acknowledged'
      printf 'resolved [key=choice]: Retain the old behavior.\n' >> "$dir/home/state/decision.status"
      for _ in 1 2; do
        PATH="$dir/bin:$PATH" TASKS_AXI_BACKEND=markdown FM_HOME="$dir/home" FM_PARKED_RUN_SECS=0 \
          "$dir/bin/fm-parked-run-watch.sh" scan || fail 'answered parked watcher scan'
        sweep "$dir" scan --now || fail 'answered parked idle scan'
      done
      [ "$(grep -c 'stalled tasks digest:' "$target")" = 1 ] || fail 'answered question republished'
      for channel in "$dir/home/state/.wake-queue" "$target"; do
        [ ! -f "$channel" ] || assert_not_contains "$(cat "$channel")" 'parked-run:' 'answered episode independently published'
      done
    fi
    assert_no_captain_call "$dir" 'cross-owner digest'
    pass "parked publication and idle sweep share one $route episode ($first first)"
  done
  dir=$(new_case "non-nm-$route")
  [ "$route" != parent ] || make_secondmate_home "$dir" mate
  for kind in scout direct-PR local-only; do
    add_worker "$dir" "$kind" 'state: parked · source: status-log · waiting for a decision' 90000
    # Retain the fixture's local copy: an empty path resolves to the caller's
    # slot claim in a real task lane, not to this synthetic worker.
    if [ "$kind" = scout ]; then
      printf 'kind=scout\nworktree=%s/pool/1/firstmate\n' "$dir" > "$dir/home/state/$kind.meta"
    else
      printf 'kind=ship\nmode=%s\nworktree=%s/pool/1/firstmate\n' "$kind" "$dir" > "$dir/home/state/$kind.meta"
    fi
    printf 'needs-decision [key=choice]: Which option for %s?\n' "$kind" > "$dir/home/state/$kind.status"
    age_file "$dir/home/state/$kind.status" 4000
  done
  sweep "$dir" scan --now || fail 'non-no-mistakes scan'
  target="$dir/home/state/.wake-queue"
  [ "$route" != parent ] || target="$dir/parent/state/mate.status"
  [ "$(grep -c 'stalled tasks digest:' "$target")" = 1 ] || fail 'non-no-mistakes batch missing'
  for kind in scout direct-PR local-only; do
    [ "$(summary_of "$dir" "$kind")" = 'stalled none' ] || fail "non-no-mistakes decision omitted: $kind"
    assert_contains "$(cat "$target")" "Which option for $kind?" 'non-no-mistakes question missing'
  done
  pass "all delivery modes and scout decisions batched on $route route"
done
