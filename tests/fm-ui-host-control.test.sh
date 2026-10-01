#!/usr/bin/env bash
# Public executable tests of host owner routing, intent-only notes and refusal.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-ui-host-control)
mkdir -p "$TMP_ROOT"
trap 'fm_test_cleanup' EXIT
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
import shutil
from pathlib import Path
import subprocess
import sys

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
env.update(FM_HOME=str(wrong), FM_STATE_OVERRIDE=str(wrong / 'state'),
           FM_DATA_OVERRIDE=str(wrong / 'data'), FM_CONFIG_OVERRIDE=str(wrong / 'config'))


def write(rows):
    registry.write_text(json.dumps(rows))
    registry.chmod(0o600)


def stream_command(label, payload):
    record = dict(record='command', command_id='fixture-command',
                  identity=dict(parent_mate_id='fixture-host', leaf_worker_id='fixture-host/' + label),
                  payload=payload)
    result = subprocess.run([str(router), '--registry', str(registry), 'command'], env=env,
                            input=json.dumps(record) + '\n', text=True, capture_output=True)
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
for action in ('interrupt', 'exit', 'shutdown', 'relaunch', 'restart', 'recover-missing', 'steer'):
    result, records = stream_command('supervisor', dict(kind=action))
    assert records[0]['state'] == 'refused', result
    for gap in ('interrupt', 'exit/shutdown', 'relaunch/restart', 'recover-missing', 'native mid-turn steering'):
        assert gap in records[0]['reason'], records
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
assert list((home / 'state/inbox').glob('*.note')), result
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
(home / 'state/sample.meta').write_text('remote_host=fixture-remote\nharness=codex\n')
result, records = stream_command('fm-sample', dict(kind='resolve-key', key='fixture-key', text='$5/month is approved'))
assert not records and 'unconfirmed' in result.stderr, result
fakebin = temp / 'fakebin'
fakebin.mkdir()
tmux = fakebin / 'tmux'
tmux.write_text('''#!/usr/bin/env bash
case "$1" in
  display-message) printf '1\n' ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) printf 'fm-sample\n' ;;
esac
exit 0
''')
tmux.chmod(0o755)
env['PATH'] = str(fakebin) + os.pathsep + env['PATH']
words = '$5/month is approved\nKeep the answer unchanged.'
for harness, answer in (('claude', words), ('pi', words), ('opencode', words), ('', words), ('codex', ' ' + words)):
    (home / 'state/sample.meta').write_text('window=fixture:fm-sample\nkind=ship\nharness=' + harness + '\n')
    (home / 'state/sample.status').write_text('needs-decision [key=fixture-key]: approve the price\n')
    before = set((home / 'state/sample.inbox').glob('*.msg'))
    result, records = stream_command('fm-sample', dict(kind='resolve-key', key='fixture-key', text=answer))
    assert records and records[0]['state'] == 'accepted', result
    added = set((home / 'state/sample.inbox').glob('*.msg')) - before
    assert len(added) == 1, added
    body = added.pop().read_text().split('\n--\n', 1)[1]
    assert body == answer, (body, answer)
    assert 'resolved [key=fixture-key]: answered:' in (home / 'state/sample.status').read_text()
for metadata in ('harness=codex\n', 'harness=claude\nharness=codex\n'):
    (home / 'state/sample.meta').write_text('window=fixture:fm-sample\nkind=ship\n' + metadata)
    (home / 'state/sample.status').write_text('needs-decision [key=fixture-key]: approve the price\n')
    before = set((home / 'state/sample.inbox').glob('*.msg'))
    refused('fm-sample', 'harness invocation', dict(kind='resolve-key', key='fixture-key', text=words))
    assert set((home / 'state/sample.inbox').glob('*.msg')) == before
    assert 'resolved' not in (home / 'state/sample.status').read_text()
print('NDJSON routing, exclusive CLI, lifecycle refusals and harness-specific dollar answers passed')
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
        refused('supervisor', 'primary interrupt', dict(kind='exit'))
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
PY
