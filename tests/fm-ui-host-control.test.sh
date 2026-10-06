#!/usr/bin/env bash
# Public executable tests of host owner routing, intent-only notes and refusal.
set -euo pipefail
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-ui-host-control)
mkdir -p "$TMP_ROOT"
trap 'fm_test_cleanup' EXIT
# Task endpoints are fake stream endpoints on this suite's hub; the Python
# below registers them through the hub's own endpoint route.
fm_test_fake_stream_ensure
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
import select
import shutil
from pathlib import Path
import subprocess
import sys
import time

root, temp = map(Path, sys.argv[1:])
router = root / 'bin/fm-ui-host-control.py'
home = temp / 'owner'
wrong = temp / 'wrong'
for directory in (home, wrong):
    (directory / 'state').mkdir(parents=True)
    (directory / 'config').mkdir()
(home / 'config/stream-machine').write_text('fixture-host\n')
registry = temp / 'registry'
primary = dict(machine='fixture-host', label='supervisor', fm_home=str(home), task_id=None)
task = dict(machine='fixture-host', label='fm-sample', fm_home=str(home), task_id='sample')
env = os.environ.copy()
env.pop('FM_STREAM_MACHINE', None)
env.update(FM_HOME=str(wrong), FM_STATE_OVERRIDE=str(wrong / 'state'),
           FM_DATA_OVERRIDE=str(wrong / 'data'), FM_CONFIG_OVERRIDE=str(wrong / 'config'))


# Optional product transcripts for targeted validation; never capture spy owners.
def evidence(surface, result, request=None):
    destination = os.environ.get('FM_TEST_UI_HOST_TRANSCRIPT')
    if destination:
        entry = dict(surface=surface, exit_code=result.returncode,
                     stdout=result.stdout, stderr=result.stderr)
        if request is not None:
            entry['request'] = request
        with open(destination, 'a', encoding='utf-8') as output:
            output.write(json.dumps(entry) + '\n')


# Register task <task_id>'s fake stream endpoint (tests/fixtures.sh's hub) and
# return its record identity lines; every text it is typed lands in typed_log.
def stream_identity(task_id):
    import hashlib
    import urllib.request
    url, tag = os.environ['FM_TEST_STREAM_URL'], os.environ['FM_TEST_STREAM_TAG']
    endpoint_id = hashlib.sha256((str(home) + '/' + task_id).encode()).hexdigest()[:32]
    body = json.dumps(dict(endpoint_id=endpoint_id, machine='fake-box', label='fm-' + task_id,
                           cwd=str(home), status_path=str(home / 'state' / (task_id + '.status')),
                           replace_label=True, foreground=[], launch_log=str(typed_log)))
    request = urllib.request.Request(url + '/v1/agent/endpoints', data=body.encode(), method='POST',
                                     headers={'Content-Type': 'application/json'})
    urllib.request.urlopen(request, timeout=10).read()
    return ('window=%s:%s\nbackend=stream\nstream_hub=%s\nstream_endpoint_id=%s\nendpoint_task_id=%s\n'
            % (tag, endpoint_id, url, endpoint_id, task_id))


typed_log = temp / 'typed-events'


def write(rows):
    registry.write_text(json.dumps(rows))
    registry.chmod(0o600)


def stream_command(label, payload, machine='fixture-host'):
    record = dict(record='command', command_id='fixture-command',
                  identity=dict(parent_mate_id=machine, leaf_worker_id=machine + '/' + label),
                  payload=payload)
    result = subprocess.run([str(router), '--registry', str(registry), 'command'], env=env,
                            input=json.dumps(record) + '\n', text=True, capture_output=True, timeout=20)
    evidence('command', result, record)
    records = [json.loads(line) for line in result.stdout.splitlines()]
    assert result.returncode == 0, result
    for ack in records:
        assert ack['record'] == 'command_ack' and ack['command_id'] == record['command_id'], ack
        assert ack['leaf_worker_id'] == record['identity']['leaf_worker_id'], ack
    return result, records


def refused(label, reason, payload):
    result, records = stream_command(label, payload)
    assert len(records) == 1 and records[0]['state'] == 'refused', result
    assert reason in records[0]['reason'], records


def owner_results(result):
    records = [json.loads(line) for line in result.stderr.splitlines()]
    for record in records:
        assert record['record'] == 'host_owner_result', record
        assert record['command_id'] == 'fixture-command', record
        assert record['leaf_worker_id'] == 'fixture-host/fm-sample', record
    return records


note = dict(kind='note', text='fixture intent')
write([primary])
registry.write_text('[{"machine":"fixture-host","machine":"other"}]')
refused('supervisor', 'ambiguous registry field', note)
write([primary])
link = temp / 'registry-link'
os.link(registry, link)
refused('supervisor', 'single-link', note)
link.unlink()
registry.rename(link)
registry.symlink_to(link)
refused('supervisor', 'host routing unavailable', note)
registry.unlink()
link.rename(registry)
refused('missing', 'unknown or ambiguous', note)
for action in ('interrupt', 'exit', 'relaunch', 'recover-missing', 'steer'):
    payload = dict(kind=action)
    if action in ('relaunch', 'recover-missing'):
        payload['note'] = 'fixture checkpoint'
    if action == 'steer':
        payload['text'] = 'fixture mid-turn intent'
    reason = 'primary-not-stream-registered' if action == 'steer' else 'primary-lifecycle-owner-absent'
    for attempt in range(2):
        refused('supervisor', reason, payload)
    refused('supervisor', 'unsupported action or payload fields', dict(payload, task_id='sample'))
    if action in ('relaunch', 'recover-missing', 'steer'):
        field = 'text' if action == 'steer' else 'note'
        refused('supervisor', 'note or answer must not be blank', dict(payload, **{field: ' '}))
    assert not list((home / 'state').iterdir()), 'primary refusal wrote runtime state'
for action in ('shutdown', 'restart'):
    refused('supervisor', 'unsupported action or payload fields', dict(kind=action))
for action in ('answer', 'release'):
    refused('supervisor', 'exact captain-call id', dict(kind=action, text='Approved'))
refused('supervisor', 'exact task binding', dict(kind='resolve-key', key='fixture-key', text='Approved'))
refused('supervisor', 'note or answer must not be blank', dict(kind='note', text=' '))
registry.chmod(0o644)
refused('supervisor', '0600', note)
write([primary, primary])
refused('supervisor', 'ambiguous registry', note)
write([dict(primary, label='alias'), primary])
refused('supervisor', 'ambiguous registry', note)
write([primary])
(home / 'config/stream-machine').write_text('different-host\n')
refused('supervisor', 'disagrees', note)
(home / 'config/stream-machine').write_text('fixture-host\n')
result, records = stream_command('supervisor', dict(kind='note', text='exact intent\nsecond line'))
assert records[0]['state'] == 'accepted', result
notes = list((home / 'state/inbox').glob('*.note'))
assert len(notes) == 1, result
assert notes[0].read_text().split('\n--\n', 1)[1] == 'exact intent\nsecond line\n'
listed = subprocess.run([str(root / 'bin/fm-inbox.sh'), 'list'],
                        env=dict(env, FM_HOME=str(home), FM_STATE_OVERRIDE=str(home / 'state')),
                        capture_output=True, text=True, timeout=10)
assert listed.returncode == 0 and 'exact intent\n    second line' in listed.stdout, listed
evidence('owning-home-inbox-list', listed)
assert not list((wrong / 'state').iterdir())
assert not list((home / 'state').glob('*.status'))
refused('supervisor', 'unsupported action or payload fields', dict(note, fm_home=str(wrong)))
for args in (['note', '--text', 'intent'], ['--machine', 'fixture-host', '--label', 'supervisor', 'note', '--text', 'intent'],
             ['command', '--text', 'intent'], ['command', '--key', 'fixture-key'], ['command', '--note', 'intent']):
    result = subprocess.run([str(router), '--registry', str(registry), *args], env=env,
                            capture_output=True, text=True)
    assert result.returncode == 2 and not result.stdout, result
assert len(list((home / 'state/inbox').glob('*.note'))) == 1
write([task])
refused('fm-sample', 'no regular owner metadata', dict(kind='interrupt'))
(home / 'state/sample.meta').write_text('remote_host=fixture-remote\n')
result, records = stream_command('fm-sample', dict(kind='interrupt'))
assert not records and 'unconfirmed' in result.stderr, result
# Remote interrupt now routes to its host owner; this incomplete fixture must
# refuse at the remote registry boundary rather than operate on a local pane.
assert 'no safe secondmate registry' in owner_results(result)[0]['stderr'], result
write([dict(task, task_id='../sample')])
refused('fm-sample', 'invalid exact task id', dict(kind='interrupt'))
write([dict(task, label='sample')])
refused('sample', 'publisher label', dict(kind='interrupt'))
write([dict(primary, captain_call_id='../call')])
refused('supervisor', 'exact call id', note)
write([dict(primary, captain_call_id=None)])
refused('supervisor', 'exact call id', note)
write([dict(task, captain_call_id='fixture-call')])
refused('fm-sample', 'primary target', note)
write([dict(primary, captain_call_id='fixture-call'),
       dict(primary, label='alias', captain_call_id='fixture-call')])
refused('supervisor', 'ambiguous registry', note)
write([task])
for words in ('/quit', '--key Enter'):
    refused('fm-sample', 'harness invocation or send option', dict(kind='resolve-key', key='fixture-key', text=words))
(home / 'state/sample.meta').write_text('remote_host=fixture-remote\nharness=deck\n')
result, records = stream_command('fm-sample', dict(kind='resolve-key', key='fixture-key', text='$5/month is approved'))
assert not records and 'unconfirmed' in result.stderr, result
fakebin = temp / 'fakebin'
fakebin.mkdir()
env['PATH'] = str(fakebin) + os.pathsep + env['PATH']
words = '$5/month is approved\nKeep the answer unchanged.'
# A leading `$` is plain text, so the answer rides the inbox byte-exact
# whether or not the record names its harness.
for harness, answer in (('deck', words), ('', words)):
    (home / 'state/sample.meta').write_text(stream_identity('sample') + 'kind=ship\nharness=' + harness + '\n')
    (home / 'state/sample.status').write_text('needs-decision [key=fixture-key]: approve the price\n')
    before = set((home / 'state/sample.inbox').glob('*.msg'))
    result, records = stream_command('fm-sample', dict(kind='resolve-key', key='fixture-key', text=answer))
    assert records and records[0]['state'] == 'accepted', result
    added = set((home / 'state/sample.inbox').glob('*.msg')) - before
    assert len(added) == 1, added
    body = added.pop().read_text().split('\n--\n', 1)[1]
    assert body == answer, (body, answer)
    assert 'resolved [key=fixture-key]: answered:' in (home / 'state/sample.status').read_text()
print('NDJSON routing, exclusive CLI, lifecycle refusals and dollar answers passed')
for action, field in (('note', 'text'), ('answer', 'text'), ('release', 'text'),
                      ('resolve-key', 'text'), ('relaunch', 'note'), ('recover-missing', 'note')):
    for value in (None, 4, [], {}, '', ' \n\t'):
        payload = dict(kind=action, **{field: value})
        if action == 'resolve-key':
            payload['key'] = 'fixture-key'
        refused('fm-sample', 'note or answer must not be blank', payload)
write([primary])
machine_file = home / 'config/stream-machine'
for contents, override in (('# fixture comment\n\nfixture host/@\nignored-host\n', None),
                            ('wrong-host\n', 'command center/@'), (None, None)):
    if contents is None:
        machine_file.unlink()
    else:
        machine_file.write_text(contents)
    if override is None:
        env.pop('FM_STREAM_MACHINE', None)
    else:
        env['FM_STREAM_MACHINE'] = override
    publisher_env = dict(env, FM_HOME=str(home))
    publisher_env.pop('FM_CONFIG_OVERRIDE', None)
    identity = subprocess.run(['bash', '-c', '. "$1"; fm_backend_stream_machine',
                               'fixture', str(root / 'bin/backends/stream.sh')],
                              env=publisher_env, capture_output=True, text=True, check=True).stdout
    write([dict(primary, machine=identity)])
    result, records = stream_command('supervisor', note, machine=identity)
    assert records[0]['state'] == 'accepted', (identity, result)
env.pop('FM_STREAM_MACHINE', None)
machine_file.write_text('fixture-host\n')
write([task])
print('nonnull text and authoritative machine identities passed')
racebin = temp / 'racebin'
racebin.mkdir()
race_router = racebin / 'fm-ui-host-control.py'
shutil.copy2(router, race_router)
(racebin / 'backends').symlink_to(root / 'bin/backends', target_is_directory=True)
race_sender = racebin / 'fm-send.sh'
race_sender.write_text('''#!/usr/bin/env bash
printf '%s\\n' ready > "$FM_TEST_SEND_READY"
while [ ! -e "$FM_TEST_SEND_GO" ]; do /bin/sleep 0.01; done
exec "$FM_TEST_REAL_SEND" "$@"
''')
race_sender.chmod(0o755)
race_env = dict(env, FM_TEST_REAL_SEND=str(root / 'bin/fm-send.sh'))


def await_file(path, process):
    deadline = time.monotonic() + 10
    while not path.exists():
        assert process.poll() is None, process.communicate()
        assert time.monotonic() < deadline, 'timed out awaiting ' + path.name
        time.sleep(0.01)


def race_request(task_id, command_id, text):
    return dict(record='command', command_id=command_id,
                identity=dict(parent_mate_id='fixture-host', leaf_worker_id='fixture-host/fm-' + task_id),
                payload=dict(kind='resolve-key', key='race-key', text=text))


def seed_race(task_id, harness='deck'):
    meta = home / ('state/' + task_id + '.meta')
    meta.write_text(stream_identity(task_id) + 'kind=ship\nharness=' + harness + '\nspawn_gen=old\n')
    status = home / ('state/' + task_id + '.status')
    status.write_text('needs-decision [key=race-key]: approve the price\n')
    typed_log.write_text('')
    return meta, status


for scenario in ('retired-exact',):
    exact = 'fm-sample'
    meta, status = seed_race(exact)
    sibling_meta, sibling_status = seed_race('sample')
    status_bytes, sibling_bytes = status.read_bytes(), sibling_status.read_bytes()
    sibling_inbox = set((home / 'state/sample.inbox').glob('*.msg'))
    write([dict(task, task_id=exact, label='fm-' + exact)])
    ready, go = temp / (scenario + '-ready'), temp / (scenario + '-go')
    answer = '$5/month is approved\nKeep the exact words.'
    request = race_request(exact, scenario, answer)
    process = subprocess.Popen([str(race_router), '--registry', str(registry), 'command'],
                               env=dict(race_env, FM_TEST_SEND_READY=str(ready), FM_TEST_SEND_GO=str(go)),
                               stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        process.stdin.write(json.dumps(request) + '\n')
        process.stdin.close()
        process.stdin = None
        await_file(ready, process)
        meta.unlink()
        go.touch()
        stdout, stderr = process.communicate(timeout=15)
        assert process.returncode == 0 and not stdout, (stdout, stderr)
        diagnostic = json.loads(stderr)
        assert diagnostic['state'] == 'unconfirmed' and diagnostic['command_id'] == scenario, diagnostic
        assert diagnostic['leaf_worker_id'] == request['identity']['leaf_worker_id'], diagnostic
        assert diagnostic['exit_code'] != 0, diagnostic
        assert 'exact task' in diagnostic['stderr'], diagnostic
        assert status.read_bytes() == status_bytes and sibling_status.read_bytes() == sibling_bytes
        assert not (home / ('state/' + exact + '.inbox')).exists()
        assert set((home / 'state/sample.inbox').glob('*.msg')) == sibling_inbox
        assert not typed_log.read_bytes(), typed_log.read_text()
    finally:
        if process.poll() is None:
            go.touch()
            process.kill()
            process.communicate()
write([task])
send_env = dict(race_env, FM_HOME=str(home))
for field in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE'):
    send_env.pop(field, None)
legacy = subprocess.run([str(root / 'bin/fm-send.sh'), 'fm-sample', '--resolve-key', 'race-key', 'Legacy exact words'],
                        env=send_env, cwd=home, capture_output=True, text=True, timeout=15)
assert legacy.returncode == 0, legacy
assert 'resolved [key=race-key]:' in (home / 'state/sample.status').read_text()
assert any(path.read_text().split('\n--\n', 1)[1] == 'Legacy exact words'
           for path in (home / 'state/sample.inbox').glob('*.msg'))
meta, status = seed_race('fm-sample')
sibling_meta, sibling_status = seed_race('sample')
sibling_bytes = sibling_status.read_bytes()
sibling_inbox = set((home / 'state/sample.inbox').glob('*.msg'))
write([dict(task, task_id='fm-sample', label='fm-fm-sample')])
answer = '$5/month is approved\nKeep the exact words.'
result, records = stream_command('fm-fm-sample', dict(kind='resolve-key', key='race-key', text=answer))
assert records and records[0]['state'] == 'accepted', result
messages = list((home / 'state/fm-sample.inbox').glob('*.msg'))
assert len(messages) == 1 and messages[0].read_text().split('\n--\n', 1)[1] == answer, messages
assert 'resolved [key=race-key]:' in status.read_text()
assert sibling_status.read_bytes() == sibling_bytes
assert set((home / 'state/sample.inbox').glob('*.msg')) == sibling_inbox
for args in (['sample', '--resolve-key', 'race-key', '/quit'], ['sample', '--key', 'Enter'],
             [stream_identity('sample').split('\n')[0].split('=', 1)[1], '--resolve-key', 'race-key', 'Approved']):
    typed_log.write_text('')
    refused_send = subprocess.run([str(root / 'bin/fm-send.sh'), '--decision-answer', *args],
                                  env=send_env, cwd=home, capture_output=True, text=True, timeout=15)
    assert refused_send.returncode != 0, refused_send
    assert not typed_log.read_bytes(), typed_log.read_text()
    assert sibling_status.read_bytes() == sibling_bytes
    assert set((home / 'state/sample.inbox').glob('*.msg')) == sibling_inbox
sleep_spy = fakebin / 'sleep'
sleep_spy.write_text('''#!/usr/bin/env bash
if [ "${1:-}" = 0.1 ] && [ -n "${FM_TEST_LOCK_WAIT_READY:-}" ]; then
  printf '%s\\n' waiting > "$FM_TEST_LOCK_WAIT_READY"
fi
exec /bin/sleep "$@"
''')
sleep_spy.chmod(0o755)
for old_gen, new_gen in (('old', 'new'),):
    exact = 'lock-publish-' + new_gen
    meta, status = seed_race(exact)
    before = status.read_bytes()
    staged = meta.with_suffix('.replacement')
    staged.write_text(meta.read_text().replace('spawn_gen=' + old_gen, 'spawn_gen=' + new_gen))
    meta_lock = home / ('state/.meta-' + exact + '.lock')
    holder = subprocess.Popen(['bash', '-c',
                               '. "$1"; fm_lock_acquire_wait "$2"; trap \'fm_lock_release "$2"\' EXIT; '
                               'printf "locked\\n"; IFS= read -r go; mv "$3" "$4"',
                               'fixture-publisher', str(root / 'bin/fm-wake-lib.sh'), str(meta_lock), str(staged), str(meta)],
                              env=dict(env, FM_STATE_OVERRIDE=str(home / 'state')),
                              stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    sender = None
    try:
        assert select.select([holder.stdout], [], [], 5)[0], 'publisher did not acquire metadata lock'
        assert holder.stdout.readline() == 'locked\n'
        wait_ready = temp / (exact + '-waiting')
        answer = '$5/month is approved\nKeep the exact words.'
        sender = subprocess.Popen([str(root / 'bin/fm-send.sh'), '--decision-answer', exact,
                                   '--resolve-key', 'race-key', answer],
                                  env=dict(send_env, FM_TEST_LOCK_WAIT_READY=str(wait_ready),
                                           FM_TASK_INBOX_LOCK_WAIT_SECS='15'),
                                  cwd=home, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        await_file(wait_ready, sender)
        holder.communicate(input='publish\n', timeout=5)
        assert holder.returncode == 0
        stdout, stderr = sender.communicate(timeout=15)
        assert sender.returncode == 0, (stdout, stderr)
        messages = list((home / ('state/' + exact + '.inbox')).glob('*.msg'))
        assert len(messages) == 1 and messages[0].read_text().split('\n--\n', 1)[1] == answer, messages
        assert status.read_bytes() != before and 'resolved [key=race-key]:' in status.read_text()
        assert answer not in typed_log.read_text(), typed_log.read_text()
        assert not meta_lock.exists() and not meta_lock.is_symlink()
    finally:
        if holder.poll() is None:
            holder.kill()
            holder.communicate()
        if sender is not None and sender.poll() is None:
            sender.kill()
            sender.communicate()
print('exact retirement, legacy selector compatibility and locked metadata-publication races passed')
write([task])
spybin = temp / 'spybin'
spybin.mkdir()
spy_router = spybin / 'fm-ui-host-control.py'
shutil.copy2(router, spy_router)
(spybin / 'backends').symlink_to(root / 'bin/backends', target_is_directory=True)
spy_owner = '''#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys
entry = dict(argv=sys.argv[1:], stdin=sys.stdin.read(), home=os.environ['FM_HOME'])
if '--decision-file' in sys.argv:
    entry['answer'] = Path(sys.argv[sys.argv.index('--decision-file') + 1]).read_text()
with open(os.environ['FM_TEST_OWNER_LOG'], 'a') as log:
    log.write(json.dumps(entry) + '\\n')
print('fixture-private-owner-output')
print('fixture-private-owner-warning: preserve the original correlation before retry', file=sys.stderr)
sys.exit(int(os.environ.get('FM_TEST_OWNER_RC', '0')))
'''
for name in ('fm-inbox.sh', 'fm-send.sh', 'fm-control.sh', 'fm-captain-hold.sh'):
    script = spybin / name
    script.write_text(spy_owner)
    script.chmod(0o755)
spy_log = temp / 'owner-invocations'
spy_env = dict(env, FM_TEST_OWNER_LOG=str(spy_log))
process = subprocess.Popen([str(spy_router), '--registry', str(registry), 'command'], env=spy_env,
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                           text=True, bufsize=1)
try:
    malformed = dict(record='command', command_id='null-note',
                     identity=dict(parent_mate_id='fixture-host', leaf_worker_id='fixture-host/fm-sample'),
                     payload=dict(kind='note', text=None))
    process.stdin.write(json.dumps(malformed) + '\n')
    process.stdin.flush()
    assert select.select([process.stdout], [], [], 5)[0], 'null note blocked the command stream'
    ack = json.loads(process.stdout.readline())
    assert ack['command_id'] == 'null-note' and ack['state'] == 'refused', ack
    assert not spy_log.exists(), 'invalid text reached an owner'
    for index, payload in enumerate((dict(kind='interrupt'), dict(kind='note', text='exact note\nsecond line'),
                                     dict(kind='resolve-key', key='fixture-key', text='Exact answer'),
                                     dict(kind='answer', text='Exact captain words'),
                                     dict(kind='relaunch', note='Exact checkpoint'))):
        record = dict(record='command', command_id='open-stream-' + str(index),
                      identity=dict(parent_mate_id='fixture-host', leaf_worker_id='fixture-host/fm-sample'),
                      payload=payload)
        process.stdin.write(json.dumps(record) + '\n')
        process.stdin.flush()
        assert select.select([process.stdout], [], [], 5)[0], 'owner inherited an open command stream'
        ack = json.loads(process.stdout.readline())
        assert ack['state'] == 'accepted' and ack['command_id'] == record['command_id'], ack
        assert ack['leaf_worker_id'] == 'fixture-host/fm-sample', ack
        assert 'fixture-private' not in json.dumps(ack), ack
    process.stdin.close()
    process.stdin = None
    stdout, stderr = process.communicate(timeout=10)
    assert process.returncode == 0 and not stdout, (stdout, stderr)
    diagnostics = [json.loads(line) for line in stderr.splitlines()]
    assert len(diagnostics) == 5, diagnostics
    for index, diagnostic in enumerate(diagnostics):
        assert diagnostic['record'] == 'host_owner_result' and diagnostic['state'] == 'confirmed', diagnostic
        assert diagnostic['command_id'] == 'open-stream-' + str(index), diagnostic
        assert diagnostic['leaf_worker_id'] == 'fixture-host/fm-sample' and diagnostic['exit_code'] == 0, diagnostic
        assert diagnostic['stdout'] == 'fixture-private-owner-output\n', diagnostic
        assert 'preserve the original correlation before retry' in diagnostic['stderr'], diagnostic
finally:
    if process.poll() is None:
        process.kill()
        process.communicate()
invocations = [json.loads(line) for line in spy_log.read_text().splitlines()]
assert [entry['stdin'] for entry in invocations] == ['', 'exact note\nsecond line', '', '', ''], invocations
assert all(entry['home'] == str(home) for entry in invocations), invocations
assert invocations[3]['answer'] == 'Exact captain words', invocations
failure = dict(record='command', command_id='fixture-failure',
               identity=dict(parent_mate_id='fixture-host', leaf_worker_id='fixture-host/fm-sample'),
               payload=dict(kind='interrupt'))
failed = subprocess.run([str(spy_router), '--registry', str(registry), 'command'],
                        env=dict(spy_env, FM_TEST_OWNER_RC='9'), input=json.dumps(failure) + '\n',
                        text=True, capture_output=True, timeout=10)
assert failed.returncode == 0 and not failed.stdout, failed
diagnostic = json.loads(failed.stderr)
assert diagnostic['command_id'] == 'fixture-failure' and diagnostic['state'] == 'unconfirmed', diagnostic
assert diagnostic['leaf_worker_id'] == 'fixture-host/fm-sample' and diagnostic['exit_code'] == 9, diagnostic
assert diagnostic['stdout'] == 'fixture-private-owner-output\n', diagnostic
assert 'preserve the original correlation before retry' in diagnostic['stderr'], diagnostic
print('open command stream stdin isolation and correlated host-only success/failure diagnostics passed')
if shutil.which('tasks-axi'):
    (home / 'data').mkdir(exist_ok=True)
    shutil.copy(root / '.tasks.toml', home / '.tasks.toml')
    (home / 'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    owner_env = dict(os.environ, FM_HOME=str(home))
    for key in ('FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_ROOT_OVERRIDE'):
        owner_env.pop(key, None)
    words = 'Use the selected option exactly.\nKeep the remaining work queued.'
    for action in ('answer', 'release'):
        call = 'fixture-' + action
        held = subprocess.run([str(root / 'bin/fm-captain-hold.sh'), 'hold', call,
                               '--title', 'Fixture choice', '--reason', 'Fixture approval',
                               '--repo', 'fixture'], env=owner_env, cwd=home, capture_output=True, text=True)
        assert held.returncode == 0, held
        write([dict(primary, captain_call_id=call)])
        for field, value in (('captain_call_id', 'different-call'), ('task_id', 'different-call'), ('fm_home', str(wrong))):
            refused('supervisor', 'unsupported action or payload fields', dict(kind=action, text=words, **{field: value}))
        for attempt in range(2):
            result, records = stream_command('supervisor', dict(kind=action, text=words))
            assert records and records[0]['state'] == 'accepted', result
            show = subprocess.run(['tasks-axi', 'show', call, '--full'], cwd=home,
                                  capture_output=True, text=True)
            assert show.returncode == 0 and all(line in show.stdout for line in words.splitlines()), show
            assert ('state: done' in show.stdout) == (action == 'answer'), show
        result, records = stream_command('supervisor', dict(kind=action, text='A different answer'))
        assert not records and 'unconfirmed' in result.stderr, result
        other_mode = 'release' if action == 'answer' else 'answer'
        result, records = stream_command('supervisor', dict(kind=other_mode, text=words))
        assert not records and 'unconfirmed' in result.stderr, result
        refused('supervisor', 'primary-lifecycle-owner-absent', dict(kind='exit'))
        write([dict(task, label='fm-' + call, task_id=call)])
        result, records = stream_command('fm-' + call, dict(kind=action, text=words))
        assert records and records[0]['state'] == 'accepted', result
    write([dict(primary, captain_call_id='fixture-absent')])
    result, records = stream_command('supervisor', dict(kind='answer', text=words))
    assert not records and 'unconfirmed' in result.stderr, result
    assert not list((home / 'state').glob('fixture-*.status'))
    assert not list((wrong / 'state').iterdir())
    print('primary captain-call answer/release: exact words, guarded owner transitions and idempotent replay passed')
else:
    print('skip: tasks-axi not found (primary captain-call owner integration)')

# Discovery is all-or-nothing, browser-safe and independent of the hub feed.
def discover(rows, reason=None):
    write(rows)
    result = subprocess.run([str(router), '--registry', str(registry), 'targets'],
                            env=env, text=True, capture_output=True, timeout=20)
    evidence('targets', result)
    if reason is not None:
        assert result.returncode == 2 and not result.stdout, result
        assert reason in result.stderr, result
        assert str(home) not in result.stderr and str(registry) not in result.stderr, result
        return
    assert result.returncode == 0 and not result.stderr, result
    values = json.loads(result.stdout)
    assert all(set(value) == {'machine', 'label', 'target_class',
                             'supported_operations', 'call_available'} for value in values), values
    assert all(type(value['call_available']) is bool for value in values), values
    assert str(home) not in result.stdout and 'private-call' not in result.stdout, result
    return values

(home / 'state/sample.meta').write_text('kind=ship\n')
(home / 'state/mate.meta').write_text('kind=secondmate\n')
mate = dict(task, label='fm-mate', task_id='mate')
values = discover([primary, task, mate])
assert [value['target_class'] for value in values] == ['primary', 'worker', 'secondmate'], values
assert values[0]['supported_operations'] == ['note'] and not values[0]['call_available'], values
expected = {'note', 'resolve-key', 'interrupt', 'exit', 'relaunch', 'recover-missing', 'answer', 'release'}
assert set(values[1]['supported_operations']) == expected and values[1]['call_available'], values
assert set(values[2]['supported_operations']) == expected - {'answer', 'release'}, values
assert not values[2]['call_available'], values
values = discover([dict(primary, captain_call_id='private-call')])
assert values[0]['supported_operations'] == ['note', 'answer', 'release'], values
assert values[0]['call_available'], values
for kind in ('scout', 'ship'):
    (home / 'state/sample.meta').write_text('kind=' + kind + '\n')
    assert discover([task])[0]['target_class'] == 'worker'
for contents in ('', 'kind=unknown\n', 'kind=ship\nkind=ship\n', 'kind=ship\nkind=secondmate\n'):
    (home / 'state/sample.meta').write_text(contents)
    discover([primary, task], 'target class')
(home / 'state/sample.meta').unlink()
discover([primary, task], 'no regular owner metadata')
(home / 'state/sample.meta').symlink_to(home / 'state/mate.meta')
discover([primary, task], 'no regular owner metadata')
(home / 'state/sample.meta').unlink()
(home / 'state/sample.meta').write_text('kind=ship\n')
for rows in ([primary, primary], [primary, dict(primary, label='alias')],
             [dict(primary, captain_call_id='one'), dict(primary, label='alias', captain_call_id='one')],
             [dict(primary, captain_call_id='sample'), task], [task, task]):
    discover(rows, 'ambiguous registry')
values = discover([primary, dict(primary, label='alias', captain_call_id='private-call'), task])
assert [value['call_available'] for value in values] == [False, True, True], values
primary_calls = [dict(primary, captain_call_id='one'),
                 dict(primary, label='alias', captain_call_id='two')]
values = discover([*primary_calls, task])
assert [value['label'] for value in values] == ['supervisor', 'alias', 'fm-sample'], values
assert all(value['call_available'] for value in values), values
spy_log.write_text('')
write([*primary_calls, task])
for row, action in ((primary_calls[0], 'answer'), (primary_calls[1], 'release'), (task, 'interrupt')):
    payload = dict(kind=action)
    if action in ('answer', 'release'):
        payload['text'] = 'Exact words for ' + row['label']
    record = dict(record='command', command_id='multi-call-' + row['label'],
                  identity=dict(parent_mate_id='fixture-host',
                                leaf_worker_id='fixture-host/' + row['label']), payload=payload)
    result = subprocess.run([str(spy_router), '--registry', str(registry), 'command'],
                            env=spy_env, input=json.dumps(record) + '\n',
                            text=True, capture_output=True, timeout=10)
    assert result.returncode == 0, result
    ack = json.loads(result.stdout)
    assert ack['state'] == 'accepted' and ack['command_id'] == record['command_id'], result
    assert ack['leaf_worker_id'] == record['identity']['leaf_worker_id'], ack
invocations = [json.loads(line) for line in spy_log.read_text().splitlines()]
assert len(invocations) == 3, invocations
for invocation, row in zip(invocations[:2], primary_calls):
    assert invocation['argv'][:2] == ['answer', row['captain_call_id']], invocation
    assert invocation['answer'] == 'Exact words for ' + row['label'], invocation
assert '--release' not in invocations[0]['argv'] and invocations[1]['argv'][-1] == '--release', invocations
assert invocations[2]['argv'] == ['sample', 'interrupt'], invocations
assert all(entry['home'] == str(home) for entry in invocations), invocations
discover([dict(task, label='sample')], 'publisher label')
discover([dict(primary, secret='private-secret')], 'malformed registry')
(home / 'config/stream-machine').write_text('other-machine\n')
discover([primary], 'disagrees')
(home / 'config/stream-machine').write_text('fixture-host\n')
write([primary])
registry.chmod(0o644)
result = subprocess.run([str(router), '--registry', str(registry), 'targets'],
                        env=env, text=True, capture_output=True, timeout=20)
evidence('targets-insecure-registry', result)
assert result.returncode == 2 and not result.stdout and '0600' in result.stderr, result
write([primary])
# Named primary refusals remain explicit while stdin stays open, never invoking owners.
spy_log.write_text('')
process = subprocess.Popen([str(spy_router), '--registry', str(registry), 'command'], env=spy_env,
                           stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
try:
    for action in ('interrupt', 'exit', 'relaunch', 'recover-missing', 'steer'):
        payload = dict(kind=action)
        if action in ('relaunch', 'recover-missing'):
            payload['note'] = 'checkpoint'
        if action == 'steer':
            payload['text'] = 'native intent'
        record = dict(record='command', command_id='duplicate-primary',
                      identity=dict(parent_mate_id='fixture-host', leaf_worker_id='fixture-host/supervisor'),
                      payload=payload)
        for attempt in range(2):
            process.stdin.write(json.dumps(record) + '\n')
            process.stdin.flush()
            assert select.select([process.stdout], [], [], 5)[0], 'primary refusal blocked'
            ack = json.loads(process.stdout.readline())
            assert ack['state'] == 'refused' and ack['command_id'] == 'duplicate-primary', ack
            assert ack['reason'] == ('primary-not-stream-registered' if action == 'steer'
                                     else 'primary-lifecycle-owner-absent'), ack
    process.stdin.close()
    process.stdin = None
    stdout, stderr = process.communicate(timeout=10)
    assert not stdout and not stderr and not spy_log.read_bytes(), (stdout, stderr)
finally:
    if process.poll() is None:
        process.kill()
        process.communicate()
print('browser-safe discovery, fail-closed classification and repeated primary capability refusals passed')
PY
