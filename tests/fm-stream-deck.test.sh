#!/usr/bin/env bash
# Executable command application regressions for Deck's stream receiver.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-stream-deck)
trap fm_test_cleanup EXIT
python3 - "$ROOT" "$LAB" <<'PY'
import errno, importlib.util, pathlib, subprocess, sys, threading
from types import SimpleNamespace
root, lab = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(root/'bin'))
import fm_stream_deck as deck
from fm_stream_deck import Receiver
spec = importlib.util.spec_from_file_location('stream_agent', root/'bin/fm-stream-agent.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
class Pty:
    def alive(self): return True
    def write(self, data): raise AssertionError('Deck steer must never write PTY')
    def foreground_processes(self): return [{'args': 'fm-deck-worker bash fm-deck-worker.sh'}]
agent = module.Agent.__new__(module.Agent)
agent.pty = Pty(); agent.endpoint_id = 'e'*32; agent.status_path = str(lab/'task.status')
def command(id='one', text='change course', execution=None):
    return {'kind':'steer','command_id':id,'endpoint_id':execution or agent.endpoint_id,
            'payload':{'order_id':id,'execution_id':execution or agent.endpoint_id,'text':text}}
r = Receiver(str(lab), 'task', agent.endpoint_id)
assert agent.apply_command(command())[0] is False
subprocess.check_call([sys.executable,str(root/'bin/fm_stream_deck.py'),'start',str(lab),
                       'task',agent.endpoint_id,'old','0'], stdout=subprocess.DEVNULL)
assert agent.apply_command(command())[0] is False
r.end(); projection = pathlib.Path(r.start('live', True))
for name in ('task.status','task.turn-ended','task.progress','task.busy-state'):
    (lab/name).write_text('sentinel\n')
before = {p.name:(p.read_bytes(), p.stat().st_mtime_ns) for p in lab.glob('task.*') if p.is_file()}
assert agent.apply_command(command(execution='f'*32))[0] is False
assert not list((lab/'task.inbox').glob('*.msg'))
assert agent.apply_command(command()) == (None, 'Deck application pending')
sources = list((lab/'task.inbox').glob('*.msg')); assert len(sources)==1
seq = str(int(sources[0].stem)); message = projection/(seq+'.msg')
assert message.read_text().startswith('change course\n\nAfter handling')
assert agent.apply_command(command()) == (None, 'Deck application pending')
assert len(list((lab/'task.inbox').glob('*.msg')))==1
# Deck's durable handled proof reconciles a lost response after turn completion.
(projection/'handled').mkdir(); message.rename(projection/'handled'/message.name)
sources[0].rename(lab/'task.inbox/handled'/sources[0].name)
r.end()
assert agent.apply_command(command()) == (True, '')
next_projection = pathlib.Path(r.start('next', True))
assert agent.apply_command(command()) == (True, '')
assert not list(next_projection.glob('*.msg'))
assert agent.apply_command(command(text='different'))[0] is False
# Finish wins: a redelivery cannot cross into another turn.
assert agent.apply_command(command('race'))[0] is None
r.end(); newer = pathlib.Path(r.start('newer', True))
assert agent.apply_command(command('race'))[0] is None
assert not list(newer.glob('*.msg'))
# Crash after source publication: reconstruct all earlier projections first.
binding={'execution':agent.endpoint_id,'turn':'newer','order_id':'crash'}
r.enqueue(binding,'crash-safe')
assert agent.apply_command(command('following','later'))[0] is None
projected=sorted(newer.glob('*.msg'),key=lambda p:int(p.stem))
assert [p.read_text().split('\n\nAfter handling')[0] for p in projected]==['crash-safe','later']
(newer/'rejected').mkdir(); projected[-1].rename(newer/'rejected'/projected[-1].name)
assert agent.apply_command(command('following','later'))[0] is False
assert before == {p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in lab.glob('task.*') if p.is_file()}
print('PASS active-turn delivery, duplicate/lost-ack reconciliation, stale execution, finish race, unavailable interface, ordered recovery, and untouched evidence')

for executable in ('fm-stream-bridge.py', 'fm-test-run.sh'):
    result = subprocess.run([str(root/'bin'/executable), '--help'],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, (executable, result.stderr)

class OrdinaryPty:
    def __init__(self): self.writes = []
    def alive(self): return True
    def write(self, data): self.writes.append(data)
    def foreground_processes(self): return []

agent.pty = OrdinaryPty()
r.end()
long_text = 'x' * 70000
assert agent.apply_command(command('ordinary', long_text)) == (True, '')
assert agent.pty.writes == [long_text.encode()]
assert agent.apply_command(command()) == (True, '')
assert agent.pty.writes == [long_text.encode()]
agent.status_path = str(lab/'other.status')
assert agent.apply_command(command('no-history', long_text)) == (True, '')
assert agent.pty.writes == [long_text.encode()] * 2
agent.status_path = str(lab/'task.status')
r.start('size-check', True)
assert agent.apply_command(command('too-large', long_text))[0] is False
assert len(agent.pty.writes) == 2
r.end()

for successor in (False, True):
    agent.status_path = str(lab/('retry-%s.status' % successor))
    receiver = agent.deck_receiver()
    original = pathlib.Path(receiver.start('original', True))
    agent.stop = threading.Event()
    agent.stood_down = threading.Event()
    agent._poll_wake = threading.Event()
    agent.options = SimpleNamespace(poll_secs=1)
    agent.machine = 'test'
    retry_command = command('retry-%s' % successor)
    results = []
    writes_before = list(agent.pty.writes)
    publish = deck.atomic_write
    faults = []
    def fail_publication(path, body):
        if path.suffix == '.msg' and not faults:
            faults.append(path)
            raise OSError(errno.ENOSPC, 'temporary projection failure')
        return publish(path, body)
    deck.atomic_write = fail_publication
    class PollHub:
        polls = 0
        def call(self, method, path, timeout):
            assert method == 'GET'
            self.polls += 1
            assert self.polls <= 4, 'source-backed command was dropped'
            if self.polls == 1:
                return {'commands': [retry_command]}
            found = receiver.find(retry_command['command_id'])
            assert found is not None and faults
            message = original/(str(int(found[0].stem)) + '.msg')
            if self.polls == 2:
                assert not message.exists()
                if successor:
                    receiver.end()
                    receiver.start('successor', True)
            if self.polls == 3:
                assert message.exists() != successor
                if successor:
                    assert not list((receiver.root/'successor').glob('*.msg'))
                handled = original/'handled'
                handled.mkdir()
                (handled/message.name).write_text('handled proof')
            return {'commands': []}
    agent.hub = PollHub()
    def acknowledge(cmd, ok, error):
        results.append((cmd['command_id'], ok, error))
        agent.stop.set()
    agent.acknowledge_command = acknowledge
    try:
        agent.command_loop()
    finally:
        deck.atomic_write = publish
    assert results == [(retry_command['command_id'], True, '')]
    assert len(list(receiver.inbox.glob('*.msg'))) == 1
    assert agent.pty.writes == writes_before

spec = importlib.util.spec_from_file_location('stream_hub', root/'bin/fm-stream-hub.py')
hub_module = importlib.util.module_from_spec(spec); spec.loader.exec_module(hub_module)
hub = hub_module.Hub(SimpleNamespace(command_ack_secs=2), {})
retained = {'endpoint_id': 'a'*32, 'machine': 'old', 'label': 'task',
            'protocol': 3, 'capabilities': ['idempotent_command_results']}
old = hub.register_endpoint(retained)
assert hub.register_endpoint(retained, old.command_capability) is old
try:
    hub.place_order('old/task', old.endpoint_id, 'change course', 'old-order')
except hub_module.HubError as exc:
    assert exc.code == 'endpoint_not_orderable'
    assert hub.orders['old-order'].describe()['delivered'] is False
else:
    raise AssertionError('retained receiver was treated as native')
assert not hub.machines['old'].queue
assert not old.closed_at
try:
    hub.register_endpoint(dict(retained, capabilities=retained['capabilities'] +
                          ['native_steering_receiver']), old.command_capability)
except hub_module.HubError as exc:
    assert exc.code == 'endpoint_capabilities_changed'
else:
    raise AssertionError('receiver capabilities changed on retained endpoint')

registration = module.registration(SimpleNamespace(machine='new', label='task',
                                   cwd=str(lab), rows=40, cols=200), 'b'*32)
native = hub.register_endpoint(registration)
assert hub.register_endpoint(registration, native.command_capability) is native

def deliver(endpoint, place, expected_kind):
    answers = []
    failures = []
    def run():
        try:
            answers.append(place())
        except Exception as exc:
            failures.append(exc)
    thread = threading.Thread(target=run)
    thread.start()
    commands = hub.take_commands(endpoint.machine, endpoint.endpoint_id, 1,
                                 endpoint.command_capability)
    assert len(commands) == 1 and commands[0].kind == expected_kind
    hub.complete_command(endpoint.machine, commands[0].command_id, True, '',
                         endpoint.command_capability)
    thread.join(3)
    assert not thread.is_alive() and not failures and len(answers) == 1
    return answers[0]

order = deliver(native, lambda: hub.place_order('new/task', native.endpoint_id,
                'native course', 'native-order'), 'steer')
assert order.describe()['delivered'] is True
assert hub.place_order('new/task', native.endpoint_id, 'native course', 'native-order') is order
assert not hub.machines['new'].queue
for kind, payload in (('input', {'text':'legacy input'}),
                      ('status', {'state':'working', 'note':'legacy status'}),
                      ('kill', {'signal':'TERM'})):
    assert deliver(old, lambda: hub.submit_command(old, kind, payload), kind).ok
assert not old.closed_at
print('PASS executable entry points, per-endpoint negotiation, retained-agent compatibility, source-backed retries, original-turn binding, and native-only text limits')
PY
