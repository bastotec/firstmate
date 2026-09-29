#!/usr/bin/env bash
# Executable command application regressions for Deck's stream receiver.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-stream-deck)
trap fm_test_cleanup EXIT
python3 - "$ROOT" "$LAB" <<'PY'
import errno, importlib.util, json, pathlib, subprocess, sys, threading
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

class LoopClock:
    def __init__(self): self.now = 0.0
    def monotonic(self): return self.now
    def advance(self, seconds): self.now += seconds

class LoopStop(threading.Event):
    def __init__(self, clock):
        super().__init__()
        self.clock = clock
    def wait(self, timeout=None):
        if not self.is_set():
            self.clock.advance(timeout)
        return self.is_set()

def run_loop(agent, hub):
    hub.clock = LoopClock()
    agent.stop = LoopStop(hub.clock)
    agent.stood_down = threading.Event()
    agent._poll_wake = LoopStop(hub.clock)
    agent._backoff = module.POLL_BACKOFF_MIN
    agent.options = SimpleNamespace(poll_secs=25)
    agent.machine = 'test'
    agent.hub = hub
    monotonic = module.time.monotonic
    module.time.monotonic = hub.clock.monotonic
    try:
        agent.command_loop()
    finally:
        module.time.monotonic = monotonic

for successor in (False, True):
    agent.status_path = str(lab/('retry-%s.status' % successor))
    receiver = agent.deck_receiver()
    original = pathlib.Path(receiver.start('original', True))
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
            self.clock.advance(int(path.rsplit('=', 1)[1]))
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
    def acknowledge(cmd, ok, error):
        results.append((cmd['command_id'], ok, error))
        agent.stop.set()
    agent.acknowledge_command = acknowledge
    try:
        run_loop(agent, PollHub())
    finally:
        deck.atomic_write = publish
    assert results == [(retry_command['command_id'], True, '')]
    assert len(list(receiver.inbox.glob('*.msg'))) == 1
    assert agent.pty.writes == writes_before

for has_source, successor in ((True, False), (True, True), (False, True)):
    agent.status_path = str(lab/('read-%s-%s.status' % (has_source, successor)))
    receiver = agent.deck_receiver()
    original = pathlib.Path(receiver.start('original', True))
    retry_command = command('read-%s-%s' % (has_source, successor))
    record = (receiver.enqueue({'execution':agent.endpoint_id, 'turn':'original',
                               'order_id':retry_command['command_id']}, 'change course')
              if has_source else None)
    results = []
    faults = []
    writes_before = list(agent.pty.writes)
    class ReadHub:
        polls = 0
        def call(self, method, path, timeout):
            assert method == 'GET'
            self.polls += 1
            assert self.polls <= 4, 'read failure lost the reconciliation command'
            if self.polls == 1:
                return {'commands': [retry_command]}
            self.clock.advance(int(path.rsplit('=', 1)[1]))
            if self.polls == 2:
                if successor:
                    receiver.end()
                    receiver.start('successor', True)
                return {'commands': [{'kind':'input', 'command_id':'unrelated',
                                      'payload':{'text':'unrelated input'}}]}
            if self.polls == 4:
                if has_source:
                    message = original/(str(int(record.stem)) + '.msg')
                    assert message.exists() != successor
                    (original/'handled').mkdir()
                    (original/'handled'/message.name).write_text('handled proof')
                else:
                    agent.stop.set()
            return {'commands': []}
    hub = ReadHub()
    glob = pathlib.Path.glob
    def unreadable_inbox(path, pattern):
        if path == receiver.inbox and hub.clock.now < 10:
            faults.append(hub.clock.now)
            raise OSError(errno.EIO, 'temporary inbox read failure')
        return glob(path, pattern)
    def acknowledge(cmd, ok, error):
        results.append((cmd['command_id'], ok, error))
        if cmd['command_id'] == retry_command['command_id']:
            agent.stop.set()
    agent.acknowledge_command = acknowledge
    pathlib.Path.glob = unreadable_inbox
    try:
        run_loop(agent, hub)
    finally:
        pathlib.Path.glob = glob
    assert len(faults) == 2
    assert results == [('unrelated', True, '')] + (
        [(retry_command['command_id'], True, '')] if has_source else [])
    assert agent.pty.writes == writes_before + [b'unrelated input']
    assert len(list(receiver.inbox.glob('*.msg'))) == int(has_source)
    if successor:
        assert not list((receiver.root/'successor').glob('*.msg'))

agent.status_path = str(lab/'cadence.status')
receiver = agent.deck_receiver()
original = pathlib.Path(receiver.start('original', True))
ended_command = command('ended')
attempts = []
results = []
waits = []
apply = agent.apply_command
class CadenceHub:
    polls = 0
    def call(self, method, path, timeout):
        assert method == 'GET'
        self.polls += 1
        assert self.polls < 60, 'late original-turn acknowledgement was lost'
        waits.append(int(path.rsplit('=', 1)[1]))
        if self.polls == 1:
            return {'commands':[ended_command]}
        if self.polls == 2:
            receiver.end()
            receiver.start('successor', True)
        else:
            self.clock.advance(0.25)
        if self.clock.now >= 6:
            message = next(original.glob('*.msg'), None)
            if message is not None:
                (original/'handled').mkdir()
                message.rename(original/'handled'/message.name)
        return {'commands':[{'kind':'input', 'command_id':'ordinary-%s' % self.polls,
                             'payload':{'text':'ordinary'}}]}
hub = CadenceHub()
def observe(cmd, reconcile_only=False):
    if cmd['command_id'] == ended_command['command_id']:
        attempts.append(hub.clock.now)
    return apply(cmd, reconcile_only=reconcile_only)
def acknowledge(cmd, ok, error):
    results.append((cmd['command_id'], ok, error))
    if cmd['command_id'] == ended_command['command_id']:
        agent.stop.set()
agent.apply_command = observe
agent.acknowledge_command = acknowledge
try:
    run_loop(agent, hub)
finally:
    del agent.apply_command
assert len(attempts) == 4, attempts
assert attempts[1] - attempts[0] == module.STEERING_APPLY_POLL_SECS
assert all(right - left >= module.STEERING_RECONCILE_SECS
           for left, right in zip(attempts[1:], attempts[2:])), attempts
assert any(wait >= 4 for wait in waits[2:]), waits
assert hub.polls < 45
assert results.count(('ended', True, '')) == 1
assert len(results) > 30
assert not list((receiver.root/'successor').glob('*.msg'))
assert len(list(receiver.inbox.glob('*.msg'))) == 1
print('PASS guarded read failures, reconciliation-only uncertainty, continued command delivery, and bounded ended-turn reconciliation')

for stage in ('lookup', 'source', 'reservation'):
    for successor in (False, True):
        agent.status_path = str(lab/('prepare-%s-%s.status' % (stage, successor)))
        receiver = agent.deck_receiver()
        original = pathlib.Path(receiver.start('original', True))
        fresh = command('prepare-%s-%s' % (stage, successor))
        publish = deck.atomic_write
        find = Receiver.find
        enqueue = Receiver.enqueue
        faults = []
        def fail_lookup(instance, order_id):
            if instance.task == receiver.task and not faults:
                faults.append('lookup')
                raise OSError(errno.EIO, 'temporary source lookup failure')
            return find(instance, order_id)
        def fail_source(instance, binding, text):
            if instance.task == receiver.task and not faults:
                faults.append('source')
                raise OSError(errno.ENOSPC, 'temporary source publication failure')
            return enqueue(instance, binding, text)
        def fail_reservation(path, body):
            if path.name.startswith('order-') and not faults:
                faults.append('reservation')
                raise OSError(errno.ENOSPC, 'temporary reservation publication failure')
            return publish(path, body)
        if stage == 'lookup': Receiver.find = fail_lookup
        if stage == 'source': Receiver.enqueue = fail_source
        if stage == 'reservation': deck.atomic_write = fail_reservation
        try:
            try:
                agent.apply_command(fresh)
            except OSError:
                pass
            else:
                raise AssertionError('preparation failure did not occur')
        finally:
            Receiver.find = find
            Receiver.enqueue = enqueue
            deck.atomic_write = publish
        assert faults == [stage]
        assert not list(receiver.inbox.glob('*.msg'))
        assert not list(original.glob('*.msg'))
        reservations = list(receiver.root.glob('order-*.json'))
        if stage != 'reservation':
            assert len(reservations) == 1
            saved = json.loads(reservations[0].read_text())
            assert saved['binding'] == {'order_id':fresh['command_id'],
                                        'execution':agent.endpoint_id, 'turn':'original'}
            fresh.pop('_steering_reservation')
        if successor:
            receiver.end()
            receiver.start('successor', True)
        assert agent.apply_command(fresh, reconcile_only=True)[0] is None
        assert len(list(receiver.inbox.glob('*.msg'))) == int(not successor)
        saved = json.loads(next(receiver.root.glob('order-*.json')).read_text())
        assert saved['binding']['turn'] == 'original'
        if successor:
            assert not list((receiver.root/'successor').glob('*.msg'))
        else:
            message = next(original.glob('*.msg'))
            (original/'handled').mkdir()
            message.rename(original/'handled'/message.name)
            assert agent.apply_command(fresh, reconcile_only=True) == (True, '')
            assert agent.apply_command(command(fresh['command_id'], 'conflict'))[0] is False
            assert len(list(receiver.inbox.glob('*.msg'))) == 1

for successor, hanging in ((False, False), (False, True), (True, False), (True, True)):
    agent.status_path = str(lab/('offline-%s-%s.status' % (successor, hanging)))
    receiver = agent.deck_receiver()
    original = pathlib.Path(receiver.start('original', True))
    offline = command('offline-%s' % successor)
    publish = deck.atomic_write
    faults = []
    results = []
    writes_before = list(agent.pty.writes)
    attempts = []
    apply_command = agent.apply_command
    def observe_offline(cmd, reconcile_only=False):
        attempts.append(hub.clock.now)
        return apply_command(cmd, reconcile_only=reconcile_only)
    def fail_projection(path, body):
        if path.suffix == '.msg' and not faults:
            faults.append(path)
            raise OSError(errno.ENOSPC, 'temporary offline projection failure')
        return publish(path, body)
    class OfflineHub:
        polls = 0
        failures = 0
        def call(self, method, path, timeout):
            assert method == 'GET'
            self.polls += 1
            assert self.polls < 10, 'native reconciliation depended on hub recovery'
            if self.polls == 1:
                return {'commands':[offline]}
            self.failures += 1
            assert 0 < timeout <= module.STEERING_RECONCILE_SECS
            assert int(path.rsplit('=', 1)[1]) <= timeout
            if self.failures == 1 and successor:
                receiver.end()
                receiver.start('successor', True)
            if self.failures > 1 and len(attempts) > 1:
                if successor:
                    assert not list(original.glob('*.msg'))
                    assert not list((receiver.root/'successor').glob('*.msg'))
                    agent.stop.set()
                else:
                    message = next(original.glob('*.msg'), None)
                    assert message is not None, 'local publication waited for a successful GET'
                    assert self.clock.now <= module.STEERING_RECONCILE_SECS
                    (original/'handled').mkdir()
                    message.rename(original/'handled'/message.name)
            if hanging:
                self.clock.advance(timeout)
            raise RuntimeError('hub unavailable')
    hub = OfflineHub()
    def acknowledge_offline(cmd, ok, error):
        results.append((cmd['command_id'], ok, error))
        agent.stop.set()
    agent.apply_command = observe_offline
    agent.acknowledge_command = acknowledge_offline
    deck.atomic_write = fail_projection
    try:
        run_loop(agent, hub)
    finally:
        deck.atomic_write = publish
        del agent.apply_command
    assert faults and hub.failures >= 2
    assert len(attempts) >= 2
    assert results == ([] if successor else [(offline['command_id'], True, '')])
    assert len(list(receiver.inbox.glob('*.msg'))) == 1
    assert agent.pty.writes == writes_before
print('PASS durable pre-source turn reservations, unpublished recovery, persistence-failure binding, and hub-independent local reconciliation')

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
