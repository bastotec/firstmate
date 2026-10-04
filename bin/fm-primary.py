#!/usr/bin/env python3
"""Opt-in primary lifecycle owner, separate from task metadata.

Usage:
  fm-primary.py launch --home HOME --machine NAME --label NAME --hub URL
      --token-file FILE --adapter deck|pi|pi-signed [--model MODEL] --prompt TEXT
  fm-primary.py discover --home HOME
  fm-primary.py control --home HOME --execution-id ID ACTION
      [--order-id ID --text TEXT]
Actions: interrupt, exit, relaunch, recover-missing, steer.

Launch stays in the foreground and owns only the PTY child it creates through
fm-stream-agent. Do not launch this against a home with an existing primary.
The caller selects the adapter explicitly; executable paths and the allowlisted
launch environment are captured once, never inferred from labels/processes.
One owner per home is permitted. Exit ends the primary, not the owner, so its
capability still supports relaunch. Recover-missing requires the owned child to
have ended and its publisher to have drained. Relaunch starts a fresh session.
SIGTERM/SIGINT to this launcher ends its owned child and then retires its record.
A crashed/missing owner is an honest refusal, not authority to adopt a process.

state/primary-owner/registration.json is an owned single-link 0600 record:
version, home, machine, label, hub, socket, capability, profile, execution_id,
endpoint_generation, status_path, state. profile captures adapter, executable,
driver, model, prompt and environment. Each execution gets its own status and
receiver directory, never a task id or .meta. The endpoint id is the actual id
registered with the stream hub. The capability authenticates a host-only Unix
socket; no browser sees it. discover emits the host owner-target registry shape
(machine, label, fm_home, task_id:null, primary_registration); the authorized UI
router must strip host-only paths before browser presentation. control resolves
that private record, never accepts a process id, executable, command or argv.
Every request binds both capability and execution id. Native steer accepts only
Deck's registered receiver, retains its normal pending/handled semantics and
never falls back to PTY input. Repeat an order id to reconcile application.
"""
import argparse
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import signal
import socket
import stat
import sys
import tempfile
import threading
from types import SimpleNamespace

BIN = Path(__file__).resolve().parent
spec = importlib.util.spec_from_file_location('fm_primary_stream', BIN / 'fm-stream-agent.py')
stream = importlib.util.module_from_spec(spec)
spec.loader.exec_module(stream)

ENV_KEYS = ('PATH', 'HOME', 'USER', 'LOGNAME', 'LANG', 'LC_ALL', 'TMPDIR',
            'PROXAI_BASE_URL', 'PROXAI_MODEL', 'PROXAI_API_KEY_FILE', 'PROXAI_API_KEY',
            'FM_DECK_MAX_TURNS', 'FM_DECK_DEADLINE_SECS')
NAME = re.compile(r'[A-Za-z0-9._-]{1,128}\Z')


class Refused(ValueError):
    pass


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refused('duplicate primary record/request field')
        result[key] = value
    return result


def private_dir(path):
    path.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = path.lstat()
    if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o700):
        raise Refused('primary owner directory must be owned and mode 0700, not a symlink')
    return path


def record_path(home):
    return Path(home) / 'state' / 'primary-owner' / 'registration.json'


def read_record(path):
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError as exc:
        raise Refused('unregistered_primary: launch this home through fm-primary.py first') from exc
    with os.fdopen(fd) as file:
        info = os.fstat(file.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise Refused('primary registration must be owned, single-link regular 0600')
        body = file.read(131073)
        if len(body) > 131072:
            raise Refused('primary registration exceeds size limit')
        record = json.loads(body, object_pairs_hook=unique_fields)
    required = {'version', 'home', 'machine', 'label', 'hub', 'socket', 'capability',
                'profile', 'execution_id', 'endpoint_generation', 'status_path', 'state'}
    if not isinstance(record, dict) or set(record) != required or record['version'] != 1:
        raise Refused('malformed primary registration')
    return record


def write_record(path, record):
    fd, tmp = tempfile.mkstemp(prefix='.registration-', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as file:
            json.dump(record, file, sort_keys=True)
            file.write('\n')
            file.flush()
            os.fsync(file.fileno())
        os.replace(tmp, path)
        directory = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def profile(args):
    executable = shutil.which(args.adapter)
    if not executable:
        raise Refused('selected primary adapter is unavailable: ' + args.adapter)
    if args.adapter == 'deck' and not shutil.which('jq'):
        raise Refused('Deck primary requires jq')
    return {'adapter': args.adapter, 'executable': os.path.abspath(executable),
            'driver': str(BIN / 'fm-deck-worker.sh') if args.adapter == 'deck' else None,
            'model': args.model, 'prompt': args.prompt,
            'environment': {key: os.environ[key] for key in ENV_KEYS if key in os.environ}}


def launch_argv(captured, state):
    adapter = captured['adapter']
    if adapter == 'deck':
        import subprocess
        gen = subprocess.check_output([str(BIN / 'fm-busy-event.sh'), 'arm', str(state),
                                       'primary', '--source', 'managed-primary'], text=True).strip()
        argv = ['bash', '-c', 'exec -a fm-deck-worker bash "$@"', 'fm-deck-worker',
                captured['driver'], '--primary', '--id', 'primary', '--state', str(state),
                '--gen', gen, '--deck', captured['executable']]
    elif adapter in ('pi', 'pi-signed'):
        argv = [captured['executable']]
    else:
        raise Refused('unsupported captured primary adapter')
    if captured['model']:
        argv += ['--model', captured['model']]
    argv += ['--', captured['prompt']]
    return argv


class Owner:
    """The capability owns live Python Pty objects, never reconstructed PIDs."""
    def __init__(self, args):
        self.args = args
        self.home = str(Path(args.home).resolve())
        if not Path(self.home).is_dir():
            raise Refused('primary home does not exist')
        self.root = private_dir(Path(self.home) / 'state' / 'primary-owner')
        self.path = record_path(self.home)
        self.agent = None
        self.thread = None
        self.record = None
        self.lock = None
        self.socket = None
        self.socket_path = None
        self.saved_record = None
        self.stopping = False

    def publish(self):
        if self.saved_record is not None and read_record(self.path) != self.saved_record:
            raise Refused('primary registration changed; publication refused')
        write_record(self.path, self.record)
        self.saved_record = json.loads(json.dumps(self.record))

    def reserve(self):
        fd = os.open(self.root / '.owner.lock', os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        self.lock = os.fdopen(fd, 'r+')
        info = os.fstat(fd)
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or info.st_nlink != 1 or stat.S_IMODE(info.st_mode) != 0o600):
            raise Refused('unsafe primary owner lock')
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise Refused('duplicate_primary_registration: this home already has an owner') from exc
        if self.path.exists() or self.path.is_symlink():
            raise Refused('duplicate_primary_registration: existing registration is not adoptable')
        # Unix paths have short platform limits. Keep the capability socket in a
        # per-uid private directory, not in a potentially long home path.
        directory = private_dir(Path('/tmp') / ('fm-primary-' + str(os.getuid())))
        socket_path = directory / (hashlib.sha256(self.home.encode()).hexdigest()[:24] + '.sock')
        if socket_path.exists() or socket_path.is_symlink():
            raise Refused('primary owner socket already exists; no adoption or replacement')
        captured = profile(self.args)
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.bind(str(socket_path))
        self.socket_path = socket_path
        os.chmod(socket_path, 0o600)
        self.socket.listen(4)
        self.socket.settimeout(0.2)
        self.record = {'version': 1, 'home': self.home, 'machine': self.args.machine,
                       'label': self.args.label, 'hub': self.args.hub,
                       'socket': str(socket_path), 'capability': secrets.token_hex(32),
                       'profile': captured, 'execution_id': '',
                       'endpoint_generation': '', 'status_path': '', 'state': 'starting'}
        self.publish()

    def start(self):
        if self.thread and self.thread.is_alive():
            raise Refused('primary publisher is still draining; replacement refused')
        endpoint = secrets.token_hex(16)
        state = private_dir(self.root / 'executions' / endpoint)
        status_path = str(state / 'primary.status')
        captured = self.record['profile']
        command = launch_argv(captured, state)
        options = SimpleNamespace(hub=self.args.hub, token_file=self.args.token_file,
                                  machine=self.args.machine, label=self.args.label,
                                  cwd=self.home, rows=40, cols=200, status_path=status_path,
                                  state_interval=1.0, poll_secs=1,
                                  primary_native_only=True, primary_adapter=captured['adapter'])
        hub = stream.HubClient(options.hub, stream.read_token(options))
        hub.begin_startup()
        health = hub.call('GET', '/v1/health')
        if (health.get('protocol') != stream.AGENT_PROTOCOL
                or stream.IDEMPOTENT_RESULT_CAPABILITY not in health.get('capabilities', [])):
            raise Refused('stream hub protocol/capability mismatch')
        max_age = float(health.get('state_max_age_secs') or 3)
        options.state_interval = max(0.1, min(1.0, max_age / 3))
        env = dict(captured['environment'])
        env.update(FM_HOME=self.home, FM_STREAM_HUB=options.hub,
                   FM_STREAM_ENDPOINT_ID=endpoint, TERM='xterm-256color')
        if captured['adapter'] == 'pi-signed':
            env['FM_PI_HARNESS'] = 'pi-signed'
        child = stream.Pty(self.home, command, options.rows, options.cols, env)
        try:
            if child.exited_within(0.4):
                raise Refused('managed primary exited before registration')
            hub.call('POST', '/v1/agent/endpoints', stream.registration(options, endpoint))
            agent = stream.Agent(options, hub, child, endpoint)
            agent.publish_initial_state()
        except BaseException:
            stream._abandon_startup(child, hub, options, endpoint)
            raise
        hub.end_startup()
        self.agent = agent
        self.record.update(execution_id=endpoint, endpoint_generation=endpoint,
                           status_path=status_path, state='running')
        self.publish()
        self.thread = threading.Thread(target=agent.run, kwargs={'install_signals': False}, daemon=True)
        self.thread.start()

    def end_child(self):
        if self.agent is not None:
            self.agent.halt()
            self.agent.pty.close()
        if self.thread is not None:
            self.thread.join(timeout=120)
            if self.thread.is_alive():
                raise Refused('primary publisher did not drain; replacement refused')
        if self.agent is not None and self.agent.pty.alive():
            raise Refused('owned primary child has not exited; replacement refused')
        self.record['state'] = 'exited'
        self.publish()

    def dispatch(self, request):
        if read_record(self.path) != self.record:
            raise Refused('primary registration changed; capability refused')
        if not isinstance(request, dict):
            raise Refused('invalid primary control request')
        required = {'capability', 'execution_id', 'kind'}
        kind = request.get('kind')
        extra = {'order_id', 'text'} if kind == 'steer' else set()
        if set(request) != required | extra:
            raise Refused('unsupported primary control fields')
        if not secrets.compare_digest(str(request['capability']), self.record['capability']):
            raise Refused('invalid primary control capability')
        if request['execution_id'] != self.record['execution_id']:
            raise Refused('stale_primary_execution: refresh discovery before control')
        if kind == 'steer':
            if self.record['profile']['adapter'] != 'deck':
                raise Refused('primary_adapter_has_no_native_receiver: no PTY fallback')
            if (not isinstance(request['order_id'], str) or not NAME.fullmatch(request['order_id'])
                    or not isinstance(request['text'], str) or not request['text'].strip()):
                raise Refused('native steering requires an order id and nonblank text')
            if not self.agent:
                raise Refused('primary native receiver unavailable; no PTY fallback')
            ok, error = self.agent.apply_command({
                'kind': 'steer', 'endpoint_id': self.record['execution_id'],
                'command_id': request['order_id'], 'payload': {
                    'execution_id': request['execution_id'], 'order_id': request['order_id'],
                    'text': request['text']}})
            return {'state': 'accepted' if ok is True else 'pending' if ok is None else 'refused',
                    'message': error, 'execution_id': self.record['execution_id']}
        if kind == 'interrupt':
            if not self.agent or not self.agent.pty.alive():
                raise Refused('managed primary child is not running')
            # Lifecycle interrupt, not native steering: adapter-explicit key,
            # delivered to this owner's own PTY, never to an inferred process.
            key = b'\x03' if self.record['profile']['adapter'] == 'deck' else b'\x1b'
            self.agent.pty.write(key)
        elif kind in ('exit', 'relaunch', 'recover-missing'):
            if kind == 'recover-missing' and self.agent and self.agent.pty.alive():
                raise Refused('registered_primary_is_alive: recover-missing refused')
            self.end_child()
            if kind != 'exit':
                self.start()
        else:
            raise Refused('unsupported primary action')
        return {'state': 'accepted', 'execution_id': self.record['execution_id']}

    def serve(self):
        try:
            self.reserve()
            self.start()
            while not self.stopping:
                if self.thread and not self.thread.is_alive() and self.record['state'] == 'running':
                    self.record['state'] = 'failed' if self.agent.pty.alive() else 'exited'
                    self.publish()
                try:
                    connection, _ = self.socket.accept()
                except socket.timeout:
                    continue
                with connection:
                    connection.settimeout(5)
                    try:
                        with connection.makefile('rb') as file:
                            line = file.readline(131073)
                            if len(line) > 131072 or not line.endswith(b'\n'):
                                raise Refused('invalid/oversized primary command')
                            answer = self.dispatch(json.loads(line, object_pairs_hook=unique_fields))
                    except (ValueError, OSError, RuntimeError) as exc:
                        answer = {'state': 'refused', 'message': str(exc)}
                    try:
                        connection.sendall((json.dumps(answer) + '\n').encode())
                    except OSError:
                        pass  # Lost reply is not authority to repeat a lifecycle action.
        finally:
            try:
                if self.saved_record is not None:
                    self.end_child()
            finally:
                if self.socket is not None:
                    self.socket.close()
                if self.socket_path is not None:
                    self.socket_path.unlink(missing_ok=True)
                # Never retire a different/replaced record, even on shutdown.
                if self.saved_record is not None:
                    try:
                        if read_record(self.path) == self.saved_record:
                            self.path.unlink()
                    except (ValueError, OSError):
                        pass
                if self.lock is not None:
                    self.lock.close()


def discover(home):
    record = read_record(record_path(Path(home).resolve()))
    if record['home'] != str(Path(home).resolve()):
        raise Refused('primary registration belongs to a different home')
    return {'machine': record['machine'], 'label': record['label'],
            'fm_home': record['home'], 'task_id': None,
            'primary_registration': str(record_path(record['home']))}


def control(home, execution, action, order_id=None, text=None):
    record = read_record(record_path(Path(home).resolve()))
    if record['home'] != str(Path(home).resolve()):
        raise Refused('primary registration belongs to a different home')
    request = {'capability': record['capability'], 'execution_id': execution, 'kind': action}
    if action == 'steer':
        request.update(order_id=order_id, text=text)
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(125)
        try:
            client.connect(record['socket'])
        except OSError as exc:
            raise Refused('primary_owner_unreachable: no adoption, PID kill or PTY fallback') from exc
        try:
            client.sendall((json.dumps(request) + '\n').encode())
            with client.makefile('rb') as file:
                return json.loads(file.readline(131073), object_pairs_hook=unique_fields)
        except (ValueError, OSError):
            return {'state': 'pending', 'message':
                    'primary owner result unconfirmed; inspect registration before retrying lifecycle',
                    'execution_id': execution}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest='command', required=True)
    launch = sub.add_parser('launch')
    for field in ('home', 'machine', 'label', 'hub', 'token-file', 'prompt'):
        launch.add_argument('--' + field, required=True)
    launch.add_argument('--adapter', choices=('deck', 'pi', 'pi-signed'), required=True)
    launch.add_argument('--model', default='')
    show = sub.add_parser('discover')
    show.add_argument('--home', required=True)
    call = sub.add_parser('control')
    call.add_argument('--home', required=True)
    call.add_argument('--execution-id', required=True)
    call.add_argument('action', choices=('interrupt', 'exit', 'relaunch', 'recover-missing', 'steer'))
    call.add_argument('--order-id')
    call.add_argument('--text')
    args = parser.parse_args()
    try:
        if args.command == 'launch':
            if not NAME.fullmatch(args.machine) or not NAME.fullmatch(args.label):
                raise Refused('invalid managed primary machine or label')
            if not args.prompt.strip():
                raise Refused('managed primary prompt must not be blank')
            owner = Owner(args)
            def stop(signum, frame):
                owner.stopping = True
            signal.signal(signal.SIGTERM, stop)
            signal.signal(signal.SIGINT, stop)
            owner.serve()
            return 0
        answer = discover(args.home) if args.command == 'discover' else control(
            args.home, args.execution_id, args.action, args.order_id, args.text)
        print(json.dumps(answer, sort_keys=True))
        return 1 if answer.get('state') == 'refused' else 0
    except (ValueError, OSError, RuntimeError) as exc:
        print(json.dumps({'state': 'refused', 'message': str(exc)}))
        return 1


if __name__ == '__main__':
    sys.exit(main())
