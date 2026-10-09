#!/usr/bin/env bash
# Executable command application regressions for Deck's stream receiver.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-stream-deck)
trap fm_test_cleanup EXIT
python3 - "$ROOT" "$LAB" <<'PY'
import contextlib, errno, importlib.util, json, pathlib, subprocess, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
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
message = projection/(str(int(sources[0].stem))+'.msg')
assert message.read_text().startswith('change course\n\nAfter handling')
assert agent.apply_command(command()) == (None, 'Deck application pending')
assert len(list((lab/'task.inbox').glob('*.msg')))==1
(projection/'handled').mkdir(); message.rename(projection/'handled'/message.name)
sources[0].rename(lab/'task.inbox/handled'/sources[0].name)
r.end()
assert agent.apply_command(command()) == (True, '')
next_projection = pathlib.Path(r.start('next', True))
assert agent.apply_command(command()) == (True, '')
assert not list(next_projection.glob('*.msg'))
assert agent.apply_command(command(text='different'))[0] is False
assert agent.apply_command(command('race'))[0] is None
r.end(); newer = pathlib.Path(r.start('newer', True))
assert agent.apply_command(command('race'))[0] is None
assert not list(newer.glob('*.msg'))
r.enqueue({'execution':agent.endpoint_id,'turn':'newer','order_id':'crash'}, 'crash-safe')
assert agent.apply_command(command('following','later'))[0] is None
projected=sorted(newer.glob('*.msg'),key=lambda p:int(p.stem))
assert [p.read_text().split('\n\nAfter handling')[0] for p in projected]==['crash-safe','later']
(newer/'rejected').mkdir(); projected[-1].rename(newer/'rejected'/projected[-1].name)
assert agent.apply_command(command('following','later'))[0] is False
assert before == {p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in lab.glob('task.*') if p.is_file()}
for number, text in enumerate(('first\r\nsecond', 'first\rsecond\r', 'α\r\nβ\n\n')):
    cmd = command('bytes-%s' % number, text)
    assert agent.apply_command(cmd)[0] is None
    source, binding, persisted = r.find(cmd['command_id'])
    assert persisted == text, ('durable source changed steering bytes', persisted, text)
    projected = newer/(str(int(source.stem))+'.msg')
    assert projected.read_bytes().startswith(text.encode('utf-8') + b'\n\nAfter handling')
    (newer/'handled').mkdir(exist_ok=True)
    projected.rename(newer/'handled'/projected.name)
    source.rename(r.inbox/'handled'/source.name)
    assert agent.apply_command(cmd) == (True, '')
    assert r.find(cmd['command_id'])[2] == text
    print(json.dumps({'order_id': cmd['command_id'], 'source_text': r.find(cmd['command_id'])[2],
                      'handled_projection': projected.name,
                      'duplicate_result': agent.apply_command(cmd)}, ensure_ascii=False))
print('PASS active-turn delivery, duplicate/lost-ack reconciliation, stale execution, finish race, ordered recovery, byte-exact sources, and untouched evidence')

for executable in ('fm-stream-bridge.py', 'fm-test-run.sh'):
    result = subprocess.run([str(root/'bin'/executable), '--help'],
                            capture_output=True, text=True, timeout=10)
    assert result.returncode == 0, (executable, result.stderr)
class OrdinaryPty:
    def __init__(self): self.writes = []
    def alive(self): return True
    def write(self, data): self.writes.append(data)
    def foreground_processes(self): return []
agent.pty = OrdinaryPty(); r.end()
long_text = 'x' * 70000
assert agent.apply_command(command('ordinary', long_text)) == (True, '')
assert agent.pty.writes == [long_text.encode()]
assert agent.apply_command(command()) == (True, '')
assert agent.pty.writes == [long_text.encode()]
agent.status_path = str(lab/'other.status')
assert agent.apply_command(command('no-history', long_text)) == (True, '')
agent.status_path = str(lab/'task.status'); r.start('size-check', True)
assert agent.apply_command(command('too-large', long_text))[0] is False
assert len(agent.pty.writes) == 2
r.end()

for stage in ('lookup', 'source', 'reservation'):
    for successor in (False, True):
        agent.status_path = str(lab/('prepare-%s-%s.status' % (stage, successor)))
        receiver = agent.deck_receiver()
        original = pathlib.Path(receiver.start('original', True))
        fresh = command('prepare-%s-%s' % (stage, successor))
        publish, find, enqueue = deck.atomic_write, Receiver.find, Receiver.enqueue
        faults = []
        def fail_lookup(instance, order_id):
            if instance.task == receiver.task and not faults:
                faults.append('lookup'); raise OSError(errno.EIO, 'temporary source lookup failure')
            return find(instance, order_id)
        def fail_source(instance, binding, text):
            if instance.task == receiver.task and not faults:
                faults.append('source'); raise OSError(errno.ENOSPC, 'temporary source publication failure')
            return enqueue(instance, binding, text)
        def fail_reservation(path, body):
            if path.name.startswith('order-') and not faults:
                faults.append('reservation'); raise OSError(errno.ENOSPC, 'temporary reservation publication failure')
            return publish(path, body)
        if stage == 'lookup': Receiver.find = fail_lookup
        if stage == 'source': Receiver.enqueue = fail_source
        if stage == 'reservation': deck.atomic_write = fail_reservation
        try:
            try: agent.apply_command(fresh)
            except OSError: pass
            else: raise AssertionError('preparation failure did not occur')
        finally:
            Receiver.find, Receiver.enqueue, deck.atomic_write = find, enqueue, publish
        assert faults == [stage]
        assert not list(receiver.inbox.glob('*.msg'))
        if stage != 'reservation':
            saved = json.loads(next(receiver.root.glob('order-*.json')).read_text())
            assert saved['binding'] == {'order_id':fresh['command_id'],
                                        'execution':agent.endpoint_id, 'turn':'original'}
            fresh.pop('_steering_reservation')
        if successor:
            receiver.end(); receiver.start('successor', True)
        assert agent.apply_command(fresh, reconcile_only=True)[0] is None
        assert len(list(receiver.inbox.glob('*.msg'))) == int(not successor)
        saved = json.loads(next(receiver.root.glob('order-*.json')).read_text())
        assert saved['binding']['turn'] == 'original'
        if successor:
            assert not list((receiver.root/'successor').glob('*.msg'))
        else:
            message = next(original.glob('*.msg')); (original/'handled').mkdir()
            message.rename(original/'handled'/message.name)
            assert agent.apply_command(fresh, reconcile_only=True) == (True, '')
            assert agent.apply_command(command(fresh['command_id'], 'conflict'))[0] is False
            assert len(list(receiver.inbox.glob('*.msg'))) == 1

module.STEERING_APPLY_POLL_SECS = .01
module.STEERING_RECONCILE_SECS = .1
module.POLL_BACKOFF_MIN = .02
module.POLL_BACKOFF_MAX = .1
module.RESULT_RETRY_SHUTDOWN_SECS = .8
module.RESULT_POST_TIMEOUT_SECS = .4

def new_agent(name, hub):
    options = SimpleNamespace(machine='test', label=name, cwd=str(lab), rows=40, cols=200,
                              status_path=str(lab/(name+'.status')), poll_secs=1, state_interval=1)
    return module.Agent(options, hub, OrdinaryPty(), 'e'*32)

@contextlib.contextmanager
def running(target):
    errors = []
    def run():
        try: target.command_loop()
        except Exception as exc: errors.append(exc)
    thread = threading.Thread(target=run)
    thread.start()
    def wait_for(predicate):
        end = time.monotonic() + 4
        while time.monotonic() < end:
            assert not errors, errors
            if predicate(): return
            assert thread.is_alive(), 'command scheduler exited unexpectedly'
            time.sleep(.005)
        raise AssertionError('timed out waiting for observable scheduler state')
    try:
        yield wait_for
    finally:
        target.halt(); thread.join(3)
        assert not thread.is_alive(), 'scheduler did not drain bounded network work'
        assert not errors, errors

class ScriptHub:
    def __init__(self, get, post=None):
        self.get = get; self.post = post; self.gets = 0; self.posts = []
    def call(self, method, path, payload=None, timeout=30):
        if method == 'GET':
            self.gets += 1
            assert timeout == 16, 'destructive takes must retain the full HTTP timeout'
            return self.get(self.gets)
        assert method == 'POST' and path == '/v1/agent/results'
        assert timeout == module.RESULT_POST_TIMEOUT_SECS
        self.posts.append(dict(payload))
        return self.post(payload) if self.post else {}

def handle(receiver, projection, order_id):
    found = receiver.find(order_id)
    assert found is not None
    message = projection/(str(int(found[0].stem))+'.msg')
    assert message.is_file()
    (projection/'handled').mkdir(exist_ok=True)
    message.rename(projection/'handled'/message.name)

for successor, stage in ((False, 'source'), (True, 'source'), (False, 'lookup'), (True, 'lookup')):
    storage = threading.Event(); failed = threading.Event(); taken_again = threading.Event()
    def get(number):
        if number == 1: return {'commands':[command('reserve-gate')]}
        assert receiver.find('reserve-gate') is not None, 'another take preceded durable source reservation'
        taken_again.set(); time.sleep(.01); return {'commands':[]}
    hub = ScriptHub(get); target = new_agent('gate-%s-%s' % (successor, stage), hub)
    receiver = target.deck_receiver(); original = pathlib.Path(receiver.start('original', True))
    enqueue, find = Receiver.enqueue, Receiver.find
    def unavailable(instance, binding, text):
        if instance.task == receiver.task and not storage.is_set():
            failed.set(); raise OSError(errno.ENOSPC, 'source storage temporarily unavailable')
        return enqueue(instance, binding, text)
    def unreadable(instance, order_id):
        if instance.task == receiver.task and not storage.is_set():
            failed.set(); raise OSError(errno.EIO, 'source reads temporarily unavailable')
        return find(instance, order_id)
    if stage == 'source': Receiver.enqueue = unavailable
    else: Receiver.find = unreadable
    try:
        with running(target) as wait_for:
            wait_for(failed.is_set); time.sleep(.03)
            assert hub.gets == 1
            if successor:
                receiver.end(); receiver.start('successor', True)
            storage.set(); wait_for(taken_again.is_set)
            source, binding, text = receiver.find('reserve-gate')
            assert binding['turn'] == 'original' and text == 'change course'
            if successor:
                assert not list(original.glob('*.msg'))
                assert not list((receiver.root/'successor').glob('*.msg'))
                assert not hub.posts
            else:
                wait_for(lambda: list(original.glob('*.msg')))
                handle(receiver, original, 'reserve-gate')
                wait_for(lambda: any(post['command_id']=='reserve-gate' for post in hub.posts))
            assert not target.pty.writes
    finally:
        Receiver.enqueue, Receiver.find = enqueue, find

spec = importlib.util.spec_from_file_location('stream_hub', root/'bin/fm-stream-hub.py')
hub_module = importlib.util.module_from_spec(spec); spec.loader.exec_module(hub_module)
wire_hub = hub_module.Hub(SimpleNamespace(command_ack_secs=2), {})
options = SimpleNamespace(machine='test', label='wire', cwd=str(lab), rows=40, cols=200)
endpoint = wire_hub.register_endpoint(module.registration(options, 'e'*32))
wire_commands = [hub_module.Command(endpoint.endpoint_id, 'test', 'steer',
                 {'order_id':'wire-'+name, 'execution_id':endpoint.endpoint_id, 'text':'wire '+name})
                 for name in ('A','B')]
wire_hub.machines['test'].queue.extend(wire_commands)
second_taken = threading.Event(); release_second = threading.Event(); http_errors = []
class WireHandler(BaseHTTPRequestHandler):
    gets = 0
    def log_message(self, *args): pass
    def reply(self, body):
        data = json.dumps(body).encode()
        self.send_response(200); self.send_header('Content-Length', str(len(data))); self.end_headers()
        try: self.wfile.write(data)
        except BrokenPipeError: pass
    def do_GET(self):
        try:
            WireHandler.gets += 1
            if WireHandler.gets == 2:
                assert receiver.find('wire-A') is not None
            if WireHandler.gets >= 3:
                assert receiver.find('wire-B') is not None
            commands = wire_hub.take_commands('test', endpoint.endpoint_id, .02,
                                             self.headers.get('X-Endpoint-Capability', ''))
            if WireHandler.gets == 2:
                assert len(commands) == 1 and commands[0] is wire_commands[1]
                second_taken.set(); time.sleep(.2); release_second.wait(2)
            self.reply({'commands':[command.describe() for command in commands]})
        except Exception as exc:
            http_errors.append(exc); self.reply({'commands':[]})
    def do_POST(self):
        payload = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
        wire_hub.complete_command('test', payload['command_id'], payload['ok'], payload['error'],
                                 self.headers.get('X-Endpoint-Capability', ''))
        self.reply({})
server = ThreadingHTTPServer(('127.0.0.1', 0), WireHandler)
server_thread = threading.Thread(target=server.serve_forever); server_thread.start()
client = module.HubClient('http://127.0.0.1:%s' % server.server_port, 'test-token')
client.command_capability = endpoint.command_capability
target = new_agent('wire', client); receiver = target.deck_receiver()
original = pathlib.Path(receiver.start('original', True))
try:
    with running(target) as wait_for:
        wait_for(second_taken.is_set)
        assert wire_commands[1].taken_at and not wire_commands[1].done.is_set()
        handle(receiver, original, 'wire-A')
        wait_for(wire_commands[0].done.is_set)
        assert not release_second.is_set(), 'local acknowledgement waited for the destructive GET'
        release_second.set()
        wait_for(lambda: receiver.find('wire-B') is not None and len(list(original.glob('*.msg')))==1)
        handle(receiver, original, 'wire-B'); wait_for(wire_commands[1].done.is_set)
        assert all(command.ok for command in wire_commands)
        assert len(list(receiver.inbox.glob('*.msg'))) == 2
        assert not target.pty.writes and not http_errors
    saved_results = receiver.recover()[1]
    assert receiver.apply('wire-A', target.endpoint_id, 'wire A', target.pty.alive,
                          command_id='same-order-new-command', reserve_only=True)[0] is None
    recovered, still_saved = receiver.recover()
    assert [item['command_id'] for item in recovered] == ['same-order-new-command']
    assert still_saved == saved_results
    assert len(list(receiver.inbox.glob('*.msg'))) == 2
finally:
    release_second.set(); server.shutdown(); server.server_close(); server_thread.join(2)

post_entered = threading.Event(); release_post = threading.Event(); release_take = threading.Event()
faults = []
def get(number):
    if number == 1: return {'commands':[command('A','message A'), command('B','message B')]}
    if number == 2:
        assert len(list(receiver.inbox.glob('*.msg'))) == 2
        release_take.wait(.5); return {'commands':[command('C','message C')]}
    assert receiver.find('C') is not None
    time.sleep(.01); return {'commands':[]}
def post(payload):
    if payload['command_id'] == 'A' and sum(row['command_id']=='A' for row in hub.posts) == 1:
        saved = receiver.recover()[1]['A']
        assert saved['result'] == payload and not saved['settled']
        post_entered.set(); release_post.wait(.5)
        raise RuntimeError('result connection temporarily unavailable')
    return {}
hub = ScriptHub(get, post); target = new_agent('independent', hub)
receiver = target.deck_receiver(); original = pathlib.Path(receiver.start('original', True))
publish = deck.atomic_write
def projection_failure(path, body):
    if path.suffix == '.msg' and body.startswith('message B') and not faults:
        faults.append(path); raise OSError(errno.ENOSPC, 'temporary projection failure')
    return publish(path, body)
deck.atomic_write = projection_failure
try:
    with running(target) as wait_for:
        wait_for(lambda: faults and receiver.find('A') is not None)
        handle(receiver, original, 'A'); wait_for(post_entered.is_set)
        wait_for(lambda: any(path.read_bytes().startswith(b'message B') for path in original.glob('*.msg')))
        assert not release_post.is_set(), 'native B publication waited for result A'
        handle(receiver, original, 'B'); wait_for(lambda: 'B' in receiver.recover()[1])
        release_take.set()
        wait_for(lambda: receiver.find('C') is not None and any(
            path.read_bytes().startswith(b'message C') for path in original.glob('*.msg')))
        assert not release_post.is_set(), 'command C take waited for result A'
        handle(receiver, original, 'C'); release_post.set()
        wait_for(lambda: len(receiver.recover()[1]) == 3 and all(
            record['settled'] for record in receiver.recover()[1].values()))
        attempts = [row for row in hub.posts if row['command_id']=='A']
        assert len(attempts) == 2 and attempts[0] == attempts[1]
        assert len(list(receiver.inbox.glob('*.msg'))) == 3 and not target.pty.writes
finally:
    release_post.set(); release_take.set(); deck.atomic_write = publish

for successor in (False, True):
    hub = ScriptHub(lambda number: (time.sleep(.01) or {'commands':[]}))
    target = new_agent('recovered-%s' % successor, hub); receiver = target.deck_receiver()
    original = pathlib.Path(receiver.start('original', True))
    assert receiver.apply('recovered', target.endpoint_id, 'durable recovery', target.pty.alive,
                          command_id='recovered', reserve_only=True)[0] is None
    if successor:
        receiver.end(); receiver.start('successor', True)
    with running(target) as wait_for:
        if successor:
            time.sleep(.15)
            assert not list((receiver.root/'successor').glob('*.msg'))
            assert not hub.posts
            source = receiver.find('recovered')[0]
            (original/'handled').mkdir()
            (original/'handled'/(str(int(source.stem))+'.msg')).write_bytes(b'late native proof')
        else:
            wait_for(lambda: list(original.glob('*.msg')))
            handle(receiver, original, 'recovered')
        wait_for(lambda: any(post['command_id']=='recovered' and post['ok'] for post in hub.posts))
        assert len(list(receiver.inbox.glob('*.msg'))) == 1 and not target.pty.writes

hub = ScriptHub(lambda number: (time.sleep(.01) or {'commands':[]}))
target = new_agent('saved-result', hub); receiver = target.deck_receiver()
record = {'order_id':'saved-result', 'result':{'machine':'test','command_id':'saved-result',
          'ok':True,'error':''}, 'expires_at':time.time()+10, 'retry_at':time.time(),
          'backoff':.02, 'settled':False}
receiver.save_result('saved-result', 'saved-result', record)
def no_application(*args, **kwargs): raise AssertionError('result recovery reapplied a command')
target.apply_command = no_application
with running(target) as wait_for:
    wait_for(lambda: receiver.recover()[1]['saved-result']['settled'])
    assert hub.posts == [record['result']]
    assert receiver.recover()[1]['saved-result']['expires_at'] == record['expires_at']
attempt_times = []
def retry_get(number):
    if number == 1:
        return {'commands':[{'command_id':'retry-status', 'kind':'status',
                             'payload':{'state':'working', 'note':'retry once'}}]}
    time.sleep(.01); return {'commands':[]}
def retry_post(payload):
    attempt_times.append(time.time())
    raise RuntimeError('result outage until retry expiry')
hub = ScriptHub(retry_get, retry_post); target = new_agent('retry-expiry', hub)
receiver = target.deck_receiver()
with running(target) as wait_for:
    wait_for(lambda: receiver.recover()[1].get('retry-status', {}).get('settled', False))
    saved = receiver.recover()[1]['retry-status']
    assert len(attempt_times) >= 2 and attempt_times[-1] >= saved['expires_at']
    assert pathlib.Path(target.status_path).read_bytes() == b'working: retry once\n'
    assert all(post == saved['result'] for post in hub.posts)

rejected = []
def reject_get(number):
    if number <= 2:
        return {'commands':[{'command_id':'reject-%s' % number, 'kind':'status',
                             'payload':{'state':'working', 'note':'accepted local effect'}}]}
    time.sleep(.01); return {'commands':[]}
def reject_post(payload):
    if payload['command_id'] == 'reject-1':
        rejected.append(payload['command_id']); raise module.ResultRejected('result capability revoked')
    return {}
hub = ScriptHub(reject_get, reject_post); target = new_agent('definitive-rejection', hub)
receiver = target.deck_receiver()
with running(target) as wait_for:
    wait_for(lambda: len(receiver.recover()[1]) == 2 and all(
        record['settled'] for record in receiver.recover()[1].values()))
    assert rejected == ['reject-1']
    assert pathlib.Path(target.status_path).read_bytes().count(b'working: accepted local effect\n') == 2

late_taken = threading.Event(); release_late = threading.Event()
def late_get(number):
    assert number == 1
    late_taken.set(); release_late.wait(.5)
    return {'commands':[{'command_id':'late-status', 'kind':'status',
                         'payload':{'state':'working', 'note':'late taken command'}}]}
def late_post(payload):
    if len(hub.posts) == 2:
        with target._result_retry_condition:
            target._result_retry_deadline = time.monotonic() + .03
    if len(hub.posts) <= 2:
        raise RuntimeError('late taken result needs a final shutdown attempt')
    return {}
hub = ScriptHub(late_get, late_post); target = new_agent('late-take', hub)
receiver = target.deck_receiver()
with running(target) as wait_for:
    wait_for(late_taken.is_set)
    target.halt(); release_late.set()
    wait_for(lambda: receiver.recover()[1].get('late-status', {}).get('settled', False))
    assert pathlib.Path(target.status_path).read_bytes() == b'working: late taken command\n'
    assert len(hub.posts) == 3 and all(post['ok'] for post in hub.posts)
print('PASS durable take barriers, full-timeout delayed destructive HTTP, independent application/take/result responsibilities, bounded retry expiry, shutdown drain, and durable recovery')

hub = hub_module.Hub(SimpleNamespace(command_ack_secs=2), {})
retained = {'endpoint_id':'a'*32, 'machine':'old', 'label':'task',
            'protocol':3, 'capabilities':['idempotent_command_results']}
old = hub.register_endpoint(retained)
assert hub.register_endpoint(retained, old.command_capability) is old
try: hub.place_order('old/task', old.endpoint_id, 'change course', 'old-order')
except hub_module.HubError as exc:
    assert exc.code == 'endpoint_not_orderable'
    assert hub.orders['old-order'].describe()['delivered'] is False
else: raise AssertionError('retained receiver was treated as native')
assert not hub.machines['old'].queue and not old.closed_at
try:
    hub.register_endpoint(dict(retained, capabilities=retained['capabilities']+
                          ['native_steering_receiver']), old.command_capability)
except hub_module.HubError as exc: assert exc.code == 'endpoint_capabilities_changed'
else: raise AssertionError('receiver capabilities changed on retained endpoint')
native = hub.register_endpoint(module.registration(SimpleNamespace(machine='new', label='task',
                               cwd=str(lab), rows=40, cols=200), 'b'*32))
assert hub.register_endpoint(module.registration(SimpleNamespace(machine='new', label='task',
       cwd=str(lab), rows=40, cols=200), 'b'*32), native.command_capability) is native
def deliver(endpoint, place, expected_kind):
    answers, failures = [], []
    def run():
        try: answers.append(place())
        except Exception as exc: failures.append(exc)
    thread = threading.Thread(target=run); thread.start()
    commands = hub.take_commands(endpoint.machine, endpoint.endpoint_id, 1, endpoint.command_capability)
    assert len(commands)==1 and commands[0].kind == expected_kind
    hub.complete_command(endpoint.machine, commands[0].command_id, True, '', endpoint.command_capability)
    thread.join(3)
    assert not thread.is_alive() and not failures and len(answers)==1
    return answers[0]
order = deliver(native, lambda: hub.place_order('new/task', native.endpoint_id,
                'native course', 'native-order'), 'steer')
assert order.describe()['delivered'] is True
assert hub.place_order('new/task', native.endpoint_id, 'native course', 'native-order') is order
assert not hub.machines['new'].queue
for kind, payload in (('input', {'text':'legacy input'}), ('status', {'state':'working','note':'legacy'}),
                      ('kill', {'signal':'TERM'})):
    assert deliver(old, lambda: hub.submit_command(old, kind, payload), kind).ok
assert not old.closed_at
print('PASS executable entry points, per-endpoint negotiation, retained-agent compatibility, and native-only text limits')
PY
python3 - "$ROOT" "$LAB/captain" <<'PY'
import json, pathlib, subprocess, sys
root, lab = map(pathlib.Path, sys.argv[1:])
lab.mkdir()
cli = [sys.executable, str(root/'bin/fm_stream_deck.py')]
inbox = lab/'task.inbox'; (inbox/'handled').mkdir(parents=True)
def record(n, body):
    (inbox/('%03d.msg' % n)).write_text('schema=fm-task-inbox.v1\nat=x\n--\n' + body)
def captain():
    return int(subprocess.check_output(cli + ['captain', str(lab), 'task']).decode())
mark = '⁣'
record(1, '[fm-captain-direct]' + mark + 'note\n\nfirst words')
record(2, 'an ordinary firstmate steer')
record(3, '[fm-from-firstmate]' + mark + 'corr=abc [fm-captain-direct]' + mark + 'note\n\nsecond words')
assert captain() == 0, 'no live turn: nothing is published'
idle = pathlib.Path(subprocess.check_output(cli + ['start', str(lab), 'task', 'a'*32, 'idle', '0']).decode().strip())
assert captain() == 0 and not list(idle.glob('*.msg')), 'a turn without --steer-dir gets nothing'
subprocess.check_call(cli + ['end', str(lab), 'task', 'a'*32])
turn = pathlib.Path(subprocess.check_output(cli + ['start', str(lab), 'task', 'b'*32, 'live', '1']).decode().strip())
assert captain() == 2
names = sorted(p.name for p in turn.glob('*.msg'))
assert names == ['1.msg', '3.msg'], names
first = (turn/'1.msg').read_text()
assert first.startswith('[fm-captain-direct]' + mark + 'note\n\nfirst words\n\nAfter handling this native steer')
assert str(inbox/'001.msg') in first and str(inbox/'handled'/'001.msg') in first
assert captain() == 0, 'publishing is idempotent'
(turn/'handled').mkdir(); (turn/'3.msg').rename(turn/'handled'/'3.msg')
record(4, json.dumps({}) and '[stream-order ' + json.dumps({'order_id': 'o', 'execution': 'b'*32, 'turn': 'live'}) + ']\nnative\nfix it')
record(5, '[fm-captain-direct]' + mark + 'note\n\nthird words')
assert captain() == 0, 'never above an unprojected stream order bound to the turn'
(turn/'4.msg').write_text('fix it')
assert captain() == 1 and (turn/'5.msg').exists()
record(6, '[fm-captain-direct]' + mark + 'note\n\nlate')
(turn/'7.msg').write_text('newer order')
record(2, '[fm-captain-direct]' + mark + 'note\n\nlower')
assert captain() == 0, 'never below a sequence already visible'
subprocess.check_call(cli + ['end', str(lab), 'task', 'b'*32])
assert captain() == 0, 'an ended turn gets nothing'
print('PASS captain-direct records reach live steerable turns in sequence order only')
PY
