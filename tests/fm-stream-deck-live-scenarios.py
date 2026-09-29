#!/usr/bin/env python3
"""Live receiver scenarios; faults wrap real HTTP and real filesystem operations.

Invoked only by fm-stream-deck-live-e2e.test.sh after its live-capability gate.
No imported application doubles, manual native acknowledgements, shared homes,
or shared stream services. Deck itself consumes every acknowledged projection.
"""
import hashlib
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

root, lab = map(Path, sys.argv[1:3])
deck = sys.argv[3]
lab = lab / 'scenarios'
lab.mkdir()
state = lab / 'state'
state.mkdir()
cwd = lab / 'cwd'
cwd.mkdir()
(cwd / 'AGENTS.md').write_text('Isolated runtime verification: follow the test prompt only. Never inspect other homes, run session start, or spawn agents.\n')
token = 'isolated-native-scenarios'
for name, value in (('token', token), ('hub-token', 'publish,subscribe,control:' + token)):
    (lab / name).write_text(value + '\n')
    (lab / name).chmod(0o600)
children = []
evidence = []
proxy_errors = []
release_take = threading.Event()
release_post = threading.Event()
take_held = threading.Event()
post_held = threading.Event()
post_failed = threading.Event()
result_attempts = []
takes = []
a_command = None
proxy = None
projection = None


def record(scenario, **facts):
    row = dict(scenario=scenario, **facts)
    evidence.append(row)
    print(json.dumps(row, ensure_ascii=False), flush=True)


def launch(args, name, env=None):
    with (lab / (name + '.log')).open('w') as log:
        child = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT,
                                 env=env, start_new_session=True)
    children.append(child)
    return child


def wait_for(predicate, label, seconds=120):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        assert not proxy_errors, proxy_errors
        if predicate():
            return
        assert hub.poll() is None and agent.poll() is None, 'runtime exited: ' + label
        time.sleep(.05)
    raise AssertionError('timeout: ' + label)


def request(path, body=None, method=None, base=None):
    req = urllib.request.Request((base or url) + path,
        data=None if body is None else json.dumps(body).encode(), method=method,
        headers={'Authorization': 'Bearer ' + token, 'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=35) as response:
        return json.load(response)


class Proxy(BaseHTTPRequestHandler):
    """Forward unchanged protocol bytes, delaying selected real hub responses."""
    def log_message(self, *args):
        pass

    def forward(self):
        global a_command
        try:
            body = self.rfile.read(int(self.headers.get('Content-Length', '0')))
            payload = json.loads(body) if body else None
            if self.path == '/v1/agent/results' and payload['command_id'] == a_command:
                result_attempts.append(payload)
                post_held.set()
                if not release_post.wait(10 if len(result_attempts) == 1 else .3):
                    post_failed.set()
                    self.send_response(503)
                    self.send_header('Content-Length', '0')
                    self.end_headers()
                    return
            req = urllib.request.Request(url + self.path, data=body if body else None,
                method=self.command, headers={key: value for key, value in self.headers.items()
                                             if key.lower() not in ('host', 'content-length')})
            try:
                with urllib.request.urlopen(req, timeout=35) as response:
                    code, data = response.status, response.read()
            except urllib.error.HTTPError as exc:
                code, data = exc.code, exc.read()
            if self.path.startswith('/v1/agent/commands'):
                commands = json.loads(data).get('commands', [])
                takes.append([cmd['command_id'] for cmd in commands])
                for cmd in commands:
                    order_id = cmd.get('payload', {}).get('order_id')
                    if order_id == 'native-A':
                        a_command = cmd['command_id']
                    if order_id == 'native-B':
                        # The real hub has already destructively taken B.
                        take_held.set()
                        release_take.wait(12)
            self.send_response(code)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(data)))
            self.end_headers()
            self.wfile.write(data)
        except (BrokenPipeError, ConnectionResetError):
            pass  # An agent may close its final long poll during cleanup.
        except Exception as exc:
            proxy_errors.append(repr(exc))

    do_GET = forward
    do_POST = forward


def bridge_record(order_id, text, target=None, label='worker'):
    return {'record': 'command', 'command_id': order_id,
        'identity': {'fleet_id': 'test', 'leaf_worker_id': 'lab/' + label,
                     'parent_mate_id': 'lab', 'execution_id': target or endpoint},
        'payload': {'kind': 'steer', 'text': text}}


def send(record, name):
    # Bridge uses stdin for its public command envelope, not terminal input.
    with (lab / (name + '.log')).open('w') as log:
        child = subprocess.Popen([sys.executable, str(root / 'bin/fm-stream-bridge.py'),
            'command', '--hub', url, '--token-file', str(lab / 'token'), '--fleet-id', 'test'],
            stdin=subprocess.PIPE, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
    children.append(child)
    child.stdin.write((json.dumps(record) + '\n').encode())
    child.stdin.close()
    return child


def answer(command_record, expected='accepted'):
    result = subprocess.run([sys.executable, str(root / 'bin/fm-stream-bridge.py'), 'command',
        '--hub', url, '--token-file', str(lab / 'token'), '--fleet-id', 'test'],
        input=json.dumps(command_record) + '\n', capture_output=True, text=True, timeout=40)
    ack = json.loads(result.stdout)
    assert ack['record'] == 'command_ack' and ack['state'] == expected, (ack, result.stderr)
    assert ack['command_id'] == command_record['command_id']
    assert ack['leaf_worker_id'] == command_record['identity']['leaf_worker_id']
    record_evidence = dict(ack)
    record_evidence['requested_execution'] = command_record['identity']['execution_id']
    record('bridge-answer', **record_evidence)
    return ack


def reservation(order_id):
    path = receiver / ('order-' + hashlib.sha256(order_id.encode()).hexdigest() + '.json')
    return json.loads(path.read_bytes()) if path.exists() else None


def source(order_id):
    for folder in (inbox, inbox / 'handled'):
        for path in folder.glob('*.msg'):
            if not path.is_file():
                continue
            body = path.read_bytes().decode().split('\n--\n', 1)[1]
            if body.startswith('[stream-order '):
                binding = json.loads(body.split('\n', 1)[0][14:-1])
                if binding['order_id'] == order_id:
                    return path, binding, body.split('\n', 2)[2]
    return None


def native_path(order_id, folder=''):
    found = source(order_id)
    return projection / folder / (str(int(found[0].stem)) + '.msg') if found else lab / 'absent'


def unchanged():
    assert (state / 'worker.busy-state').read_bytes() == before
    assert not (state / 'worker.turn-ended').exists()
    assert not (state / 'worker.status').exists()
    assert json.loads((receiver / 'active.json').read_bytes()) == original
    assert agent.poll() is None


try:
    hub = launch([sys.executable, str(root / 'bin/fm-stream-hub.py'), 'serve', '--bind',
        '127.0.0.1', '--port', '0', '--token-file', str(lab / 'hub-token'),
        '--ready-file', str(lab / 'hub.ready')], 'hub')
    end = time.monotonic() + 15
    while not (lab / 'hub.ready').exists():
        assert hub.poll() is None and time.monotonic() < end
        time.sleep(.05)
    host, port = (lab / 'hub.ready').read_text().split()
    url = 'http://' + host + ':' + port
    proxy = ThreadingHTTPServer(('127.0.0.1', 0), Proxy)
    proxy.daemon_threads = True
    proxy_thread = threading.Thread(target=proxy.serve_forever)
    proxy_thread.start()
    env = dict(os.environ, DECK_STATE=str(lab / 'deck-state'), FM_HOME=str(lab),
               FM_DECK_DEADLINE_SECS='240')
    agent = launch([sys.executable, str(root / 'bin/fm-stream-agent.py'), 'serve', '--hub',
        'http://127.0.0.1:' + str(proxy.server_port), '--token-file', str(lab / 'token'),
        '--machine', 'lab', '--label', 'worker', '--cwd', str(cwd), '--status-path',
        str(state / 'worker.status'), '--ready-file', str(lab / 'agent.ready'),
        '--poll-secs', '3', '--state-interval', '1'], 'agent', env)
    wait_for(lambda: (lab / 'agent.ready').exists(), 'agent registration')
    endpoint = (lab / 'agent.ready').read_text().split()[-1]
    gen = subprocess.check_output([str(root / 'bin/fm-busy-event.sh'), 'arm', str(state),
                                   'worker'], text=True).strip()
    def barrier(name):
        return 'for i in $(seq 1 1000); do [ ! -f ' + name + ' ] || break; sleep 0.1; done; test -f ' + name
    prompt = ('Runtime verification only. First execute exactly: touch started; ' + barrier('initial-gate') +
        '. After that write ORIGINAL to result.txt. If native steering arrives, follow it instead. '
        'Never inspect resources outside this isolated directory and the ordinary inbox explicitly referenced by native guidance. '
        'Do not finish or append any status until the finish-gate file exists. Then append done: verified to ' +
        str(state / 'worker.status') + ' and finish.')
    args = ['bash', str(root / 'bin/fm-deck-worker.sh'), '--id', 'worker', '--state', str(state),
        '--gen', gen, '--deck', deck, '--model', os.environ.get('FM_DECK_LIVE_MODEL', 'codex/gpt-6.1-sol'), '--', prompt]
    launcher = lab / 'launch-worker.sh'
    launcher.write_text('#!/usr/bin/env bash\nexec ' + shlex.join(args) + '\n')
    request('/v1/tasks/' + endpoint + '/input', {'text': 'exec bash ' + shlex.quote(str(launcher)), 'submit': True})
    wait_for(lambda: (cwd / 'started').exists(), 'original tool barrier')
    inbox = state / 'worker.inbox'
    receiver = inbox / ('deck-' + endpoint)
    original = json.loads((receiver / 'active.json').read_bytes())
    projection = receiver / original['turn']
    assert original['active'] and original['supported']
    before = (state / 'worker.busy-state').read_bytes()
    assert b'state=busy' in before

    # The reader raises EISDIR before source publication; the real agent must
    # reserve the original turn before this fallible read, and stop taking.
    blocker = inbox / 'lookup-fault.msg'
    blocker.mkdir()
    projection.chmod(0o500)  # mkstemp/rename fails only for native publication.
    text_a = ('Change course: never write ORIGINAL. Execute: printf CORRECTED > result.txt; '
              'echo A >> applications; touch applied-A; sleep 1. '
              'Use a separate tool call to acknowledge the ordinary source as the native guidance says. '
              'Next use a separate tool call to execute: touch awaiting-finish; ' + barrier('a-gate') +
              '. Honor any further native instructions after that tool returns. '
              'Do not combine their application/source acknowledgement with the final wait. '
              'Finally, in a separate tool call execute: touch ready-to-finish; ' +
              barrier('finish-gate') + '. Only then append done: verified to ' + str(state / 'worker.status') +
              ' and finish. Payload byte probe follows; it is not a shell command:\r\nα\rβ\n\n')
    order_a = bridge_record('native-A', text_a)
    send(order_a, 'bridge-A')
    wait_for(lambda: reservation('native-A'), 'durable original-turn reservation')
    saved = reservation('native-A')
    assert saved['binding'] == {'execution': endpoint, 'turn': original['turn'], 'order_id': 'native-A'}
    assert source('native-A') is None
    take_count = len(takes)
    time.sleep(.4)
    assert len(takes) == take_count, 'another take preceded durable source reservation'
    send(order_a, 'bridge-A-duplicate')
    unchanged()
    record('reservation-and-lookup-fault', binding=saved['binding'], takes_while_unpublished=take_count)
    blocker.rmdir()
    wait_for(lambda: source('native-A'), 'source recovery on original turn')
    assert source('native-A')[2] == text_a
    time.sleep(.5)
    assert not native_path('native-A').exists(), 'native publication ignored the storage fault'

    # B is removed from the real hub queue, but its response stays in flight.
    order_b = bridge_record('native-B', 'Runtime test instruction B: execute echo B >> applications. Acknowledge this source as instructed; preserve CORRECTED and keep the earlier finish-gate requirement.\r\nfirst\rsecond\n')
    send(order_b, 'bridge-B')
    wait_for(take_held.is_set, 'delayed second destructive take')
    held_since = time.monotonic()
    projection.chmod(0o700)
    wait_for(lambda: native_path('native-A').is_file(), 'local A publication during delayed take', seconds=10)
    assert not release_take.is_set() and not source('native-B')
    assert time.monotonic() - held_since > .2
    assert native_path('native-A').read_bytes().startswith(text_a.encode() + b'\n\nAfter handling')
    unchanged()
    record('delayed-destructive-take', original_turn=original['turn'], native_A_published=True,
           B_response_still_in_flight=True, held_seconds=time.monotonic() - held_since)

    # The delayed destructive response must still reach durable reservation.
    projection.chmod(0o500)
    release_take.set()
    wait_for(lambda: source('native-B'), 'B survives delayed response', seconds=5)
    order_c = bridge_record('native-C', 'Runtime test instruction C: execute echo C >> applications. Acknowledge this source as instructed; preserve CORRECTED and keep the earlier finish-gate requirement. Unicode: café λ.\r\n')
    send(order_c, 'bridge-C')
    wait_for(lambda: source('native-C'), 'C reservation despite B projection failure', seconds=5)
    assert not native_path('native-B').exists() and not native_path('native-C').exists()
    projection.chmod(0o700)
    wait_for(lambda: native_path('native-B').is_file() and native_path('native-C').is_file(),
             'B/C local publication recovery', seconds=10)
    unchanged()
    (cwd / 'initial-gate').touch()
    wait_for(lambda: (cwd / 'awaiting-finish').exists(), 'A tool complete; original turn waiting')
    (cwd / 'a-gate').touch()
    wait_for(lambda: all(source(order)[0].parent.name == 'handled' for order in ('native-A', 'native-B', 'native-C')),
             'model acknowledges ordinary sources')
    wait_for(lambda: (cwd / 'ready-to-finish').exists(), 'corrected turn still running')
    assert (cwd / 'result.txt').read_text().strip() == 'CORRECTED'
    assert sorted((cwd / 'applications').read_text().splitlines()) == ['A', 'B', 'C']
    unchanged()
    for order in (order_a, order_b, order_c):
        persisted = source(order['command_id'])
        assert persisted[1]['turn'] == original['turn'] and persisted[2] == order['payload']['text']
        projected = native_path(order['command_id'], 'handled')
        if not projected.exists():
            projected = native_path(order['command_id'])
        assert projected.read_bytes().startswith(persisted[2].encode() + b'\n\nAfter handling')
        record('byte-exact-native-persistence', order_id=order['command_id'], source_text=persisted[2],
               projection=projected.name, binding=persisted[1])
    assert sorted((cwd / 'applications').read_text().splitlines()) == ['A', 'B', 'C']
    record('same-turn-correction-and-duplicates', execution_id=endpoint, turn=original['turn'],
           result='CORRECTED', applications=['A', 'B', 'C'], busy_state_unchanged=True,
           no_turn_end=True, no_manufactured_status=True)

    # Native-only length rejection must neither type into Deck nor fail its turn.
    answer(bridge_record('native-too-large', 'x' * 70000), 'refused')
    assert source('native-too-large') is None
    unchanged()

    # Leave an unpublished reservation stranded across an ordinary finish,
    # then let the same endpoint start a successor. Recovery must never project
    # the old instruction into that successor (nor rewrite its binding).
    blocker.mkdir()
    unresolved = bridge_record('native-ended', 'Do not execute this in a successor: write WRONG to successor-leak.')
    send(unresolved, 'bridge-ended')
    wait_for(lambda: reservation('native-ended'), 'ended-turn reservation')
    (cwd / 'finish-gate').touch()
    wait_for(lambda: (state / 'worker.turn-ended').exists(), 'natural original turn finish')
    assert 'failed:' not in (state / 'worker.status').read_text()
    assert (state / 'worker.status').read_text().strip() == 'done: verified'
    (state / 'worker.turn-ended').unlink()  # Test starts a fresh observation window.
    blocker.rmdir()
    wait_for(lambda: source('native-ended'), 'source reservation completes after original finish')
    wait_for(lambda: post_held.is_set() and reservation('native-A').get('results'), 'native result A queued durably')
    result_state = reservation('native-A')['results'][a_command]
    assert not result_state['settled'] and result_state['result']['ok']
    assert len(list(projection.glob('handled/*.msg'))) == 3
    successor_prompt = ('Runtime test only: first execute touch successor-started; ' + barrier('successor-gate') +
        '. Do not inspect or execute old inbox sources. Honor only new native guidance. '
        'After handling it, use a separate tool call to execute touch successor-waiting; ' + barrier('successor-finish') +
        '. Then append done: successor to ' + str(state / 'worker.status') + ' and finish.')
    # Starting a wrapper turn via stdin is the legacy input contract; its result
    # may queue behind the intentionally unavailable native result A.
    startup_errors = []
    def start_successor():
        try:
            request('/v1/tasks/' + endpoint + '/input', {'text': successor_prompt, 'submit': True})
        except urllib.error.HTTPError as exc:
            if json.loads(exc.read()).get('error') != 'no_agent_ack':
                startup_errors.append(str(exc))
    startup_thread = threading.Thread(target=start_successor)
    startup_thread.start()
    wait_for(lambda: (cwd / 'successor-started').exists(), 'same-endpoint successor turn')
    successor = json.loads((receiver / 'active.json').read_bytes())
    assert successor['turn'] != original['turn'] and successor['active']
    assert source('native-ended')[1]['turn'] == original['turn']
    time.sleep(5.5)  # At least one ended-turn reconciliation cadence.
    assert not list((receiver / successor['turn']).glob('*.msg'))
    assert not native_path('native-ended').exists()
    assert not (cwd / 'successor-leak').exists()
    assert not reservation('native-ended').get('results')
    assert agent.poll() is None and not (state / 'worker.turn-ended').exists()
    record('original-turn-only-recovery', reserved_turn=original['turn'], successor=successor['turn'],
           source_binding=source('native-ended')[1], successor_messages=0, fabricated_result=False)
    # A's native result is still retrying while a second live turn reserves
    # more native orders and recovers actual projection publication failures.
    next_projection = receiver / successor['turn']
    next_projection.chmod(0o500)
    next_orders = [bridge_record('native-' + name,
        'Runtime test instruction ' + name + ': execute echo ' + name +
        ' >> successor-applications; touch successor-corrected. Acknowledge this ordinary source. '
        'Do not execute old sources or change result.txt. Preserve the successor-finish gate requirement.')
        for name in ('D', 'E')]
    for order in next_orders:
        send(order, 'bridge-' + order['command_id'])
        wait_for(lambda: source(order['command_id']), 'source reserved while A result retries')
    assert not list(next_projection.glob('*.msg'))
    next_projection.chmod(0o700)
    wait_for(lambda: len(list(next_projection.glob('*.msg'))) == 2,
             'local successor publication despite A result outage', seconds=10)
    wait_for(post_failed.is_set, 'first native result POST fails')
    assert not release_post.is_set()
    assert not reservation('native-A')['results'][a_command]['settled']
    assert all(row == result_attempts[0] for row in result_attempts)
    record('independent-result-retry', pending_result=result_state,
           attempts=len(result_attempts), native_D_and_E_reserved=True,
           native_D_and_E_published=True, result_connection_unavailable=True)
    release_post.set()
    wait_for(lambda: len(result_attempts) >= 2 and reservation('native-A')['results'][a_command]['settled'],
             'durable result retry settles')
    startup_thread.join(40)
    assert not startup_thread.is_alive() and not startup_errors, startup_errors
    for order in (order_a, order_b, order_c):
        answer(order)
        answer(order)
        assert source(order['command_id'])[2] == order['payload']['text']
        assert source(order['command_id'])[1]['turn'] == original['turn']
    assert len(list(projection.glob('handled/*.msg'))) == 3
    assert sorted((cwd / 'applications').read_text().splitlines()) == ['A', 'B', 'C']
    (cwd / 'successor-gate').touch()
    wait_for(lambda: (cwd / 'successor-waiting').exists(), 'native successor instructions applied')
    assert sorted((cwd / 'successor-applications').read_text().splitlines()) == ['D', 'E']
    assert not (state / 'worker.turn-ended').exists()
    assert not (cwd / 'successor-leak').exists()
    (cwd / 'successor-finish').touch()
    wait_for(lambda: (state / 'worker.turn-ended').exists(), 'natural successor finish')
    assert 'failed:' not in (state / 'worker.status').read_text()
    assert len(list(next_projection.glob('handled/*.msg'))) == 2
    for order in next_orders:
        answer(order)
    assert len([path for path in receiver.iterdir() if path.is_dir()]) == 2
    assert not reservation('native-ended').get('results')
    assert not (cwd / 'successor-leak').exists()
    record('native-result-outage-recovered', attempts=result_attempts,
           successor_native_applications=['D', 'E'], original_unresolved_binding=source('native-ended')[1])

    # Run the actual retained base agent. It remains usable via legacy input,
    # but Bridge native steering is refused before this receiver sees it.
    retained_script = lab / 'retained-agent.py'
    retained_script.write_bytes(subprocess.check_output(['git', 'show',
        'a7595f179c9b5e1bbce1dd381297e5cf3700d8eb:bin/fm-stream-agent.py'], cwd=root))
    retained = launch([sys.executable, str(retained_script), 'serve', '--hub', url,
        '--token-file', str(lab / 'token'), '--machine', 'lab', '--label', 'retained',
        '--cwd', str(cwd), '--ready-file', str(lab / 'retained.ready'), '--poll-secs', '3'], 'retained', env)
    wait_for(lambda: (lab / 'retained.ready').exists(), 'retained base agent')
    retained_endpoint = (lab / 'retained.ready').read_text().split()[-1]
    answer(bridge_record('retained-steer', 'touch retained-WRONG', retained_endpoint, 'retained'), 'refused')
    request('/v1/tasks/' + retained_endpoint + '/input', {'text': 'touch retained-legacy', 'submit': True})
    wait_for(lambda: (cwd / 'retained-legacy').exists(), 'retained legacy input')
    assert not (cwd / 'retained-WRONG').exists() and retained.poll() is None

    # An ordinary current agent consumes the full large text from its real PTY.
    ordinary = launch([sys.executable, str(root / 'bin/fm-stream-agent.py'), 'serve', '--hub', url,
        '--token-file', str(lab / 'token'), '--machine', 'lab', '--label', 'ordinary',
        '--cwd', str(cwd), '--status-path', str(state / 'ordinary.status'),
        '--ready-file', str(lab / 'ordinary.ready'), '--poll-secs', '3'], 'ordinary', env)
    wait_for(lambda: (lab / 'ordinary.ready').exists(), 'ordinary agent')
    ordinary_endpoint = (lab / 'ordinary.ready').read_text().split()[-1]
    reader = lab / 'read-large.py'
    reader.write_text('import os, pathlib, tty\ntty.setraw(0)\npathlib.Path("large-ready").touch()\nb = b""\nwhile len(b) < 70000: b += os.read(0, 70000-len(b))\npathlib.Path("large-received").write_bytes(b)\n')
    request('/v1/tasks/' + ordinary_endpoint + '/input', {'text': 'exec ' + shlex.join([sys.executable, str(reader)]), 'submit': True})
    wait_for(lambda: (cwd / 'large-ready').exists(), 'ordinary raw PTY reader')
    answer(bridge_record('ordinary-large', 'x' * 70000, ordinary_endpoint, 'ordinary'))
    wait_for(lambda: (cwd / 'large-received').exists(), 'ordinary full large text')
    assert (cwd / 'large-received').read_bytes() == b'x' * 70000
    record('retained-compatibility-and-native-only-limits', retained_execution=retained_endpoint,
           legacy_input=True, retained_native_refused=True, native_70000_refused=True,
           ordinary_execution=ordinary_endpoint, ordinary_received_bytes=70000)
    assert not proxy_errors
    print('PASS all seven native live receiver scenarios', flush=True)
finally:
    release_take.set()
    release_post.set()
    if projection and projection.exists():
        projection.chmod(0o700)
    if 'endpoint' in globals():
        try:
            req = urllib.request.Request(url + '/v1/tasks/' + endpoint + '/capture?lines=300',
                                         headers={'Authorization': 'Bearer ' + token})
            with urllib.request.urlopen(req, timeout=10) as response:
                print('worker-capture:\n' + response.read().decode(), file=sys.stderr)
        except Exception as exc:
            print('capture unavailable: ' + str(exc), file=sys.stderr)
    for child in reversed(children):
        if child.poll() is None:
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
    for child in children:
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.wait()
    if proxy:
        proxy.shutdown()
        proxy.server_close()
        proxy_thread.join(5)
    (lab / 'evidence.json').write_text(json.dumps(evidence, ensure_ascii=False, indent=2))
    for log in sorted(lab.glob('*.log')):
        print(log.name + ':\n' + log.read_text(), file=sys.stderr)
