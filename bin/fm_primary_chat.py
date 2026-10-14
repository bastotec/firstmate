#!/usr/bin/env python3
"""State, steering and supervision for a `deck chat` primary.

bin/fm-deck-chat.sh is the host; bin/fm-primary-steer.sh is the public steer
CLI. Both call this file, which owns the on-disk layout:

  state/primary-chat.json                 the host record (0600, atomic)
  state/primary-chat/session              the persisted deck session id
  state/primary-chat/.session.lock        per-role session selection lock, shared
                                          by prepare and split-start handover
  state/primary-chat/host.lock            split captain host singleton (flock)
  state/primary-chat/<session>/split-archived/  pending operational input removed
                                          from the captain inbox at split start
  state/primary-chat/<session>/steer/     deck's --steer-dir (one per session,
                                          because deck's seq space is per session)
      .seq  .publish.lock                publisher bookkeeping (deck ignores
                                          every name that is not <digits>.msg)
  state/primary-chat/<session>/events.ndjson  deck's --events file
  state/primary-chat/host.log             supervisor log (watcher, busy, steer)
  state/primary-chat/stopped              "stopped on purpose" marker: written by
                                          `fm-deck-chat.sh stop`, removed by a
                                          captain-started host; the service
                                          keeper never restarts past it
  state/primary-chat/captain-start        epoch of the latest captain start (atomic),
                                          written before clearing stopped, even
                                          when no stopped marker existed
  state/primary-chat/service.json         the keeper's current view (0600, atomic):
                                          {"pid","state","detail","since","home","model"};
                                          state is running|starting|switching|down|waiting|stopped;
                                          model is the keeper's --model fallback,
                                          not the stored choice or live host's route
  state/primary-chat/service.log          keeper log (size-capped, one rotation)
  state/primary-chat/service-down         durable alert marker while the primary
                                          has been down past the alert window
  state/primary-chat/service.lock         keeper singleton (flock)
  state/primary-chat/model                the model route the captain chose for the
                                          primary (`model ROUTE`); the keeper starts
                                          the host on it, over its own --model
  state/primary-chat/switch               "<request epoch> <route>": a fallback switch
                                          waiting for a live, idle primary; the keeper
                                          atomically claims and removes this request
                                          before ending the host, leaving newer requests
                                          pending, and restarts on the claimed route
  state/primary-chat/switches             route changes recorded on in-place control
                                          publication or successful fallback host start:
                                          "<record epoch> <from route|default> <to route>"
                                          (last 1000), for the thread to mark where it was;
                                          in-place entries are not application receipts

Split mode is enabled by the presence of primary-split in FM_CONFIG_OVERRIDE,
else <home>/config; it is intended for primary homes, not secondmates.
Two hosts serve one home:
  - captain (default): keeps all primary names above, the persisted conversation
    and chosen model, the primary busy id, stream label primary-chat and keeper
    dev.firstmate.primary.<hash>. It takes no home session lock, runs no session
    start or watcher, and uses --no-project-context. Its positional first prompt
    on every start is .agents/skills/captain-thread/SKILL.md, the sole captain
    contract, queued ahead of pending steering; the host never moves pending
    captain input. Known operational input is archived in split-archived/;
    peer messages and unconsumed startup digests are handed to the supervisor's
    persisted inbox before archiving, even without a live supervisor host.
  - supervisor (fm-deck-chat.sh --role supervisor): uses supervisor-chat.json,
    supervisor-chat/, supervisor.busy-state, stream label supervisor-chat and
    keeper dev.firstmate.supervisor.<hash>. Its initial session id is
    firstmate-supervisor-<timestamp>. It holds the home session lock, runs
    session start, owns the watcher and reads AGENTS.md.
Each role has its own session and model choice; captain host.lock prevents a
second captain host without competing for the supervisor's home session lock.
Outside split mode operational publishers selecting supervisor resolve to the
one primary. The shell host instead refuses non-keeper supervisor modes, and
a supervisor keeper waits for the switch without starting a host.
FM_CHAT_ROLE or --role (before the subcommand) picks the role in this module;
bin/fm-deck-chat.sh's header owns operator setup and lifecycle commands.

Record (state/primary-chat.json):
  {"version":1,"home":ABS,"session":ID,"steer_dir":ABS,"events_file":ABS,
   "endpoint":"<hub-tag>:<endpoint-id>"|null,"host_pid":N,"started_at":EPOCH,
   "model":ROUTE,"set_model":BOOL}
model is the host's launch route ("" when omitted), updated on in-place control
publication; it is not an application receipt.
set_model records whether this host's `deck chat --help` advertises set_model;
a missing field in an older record means unsupported.
A clean host exit adds "stopped_at". A record is live only when it has no
stopped_at and host_alive(host_pid, home) validates the host identity below.

Subcommands:
  model --home H [ROUTE]
      bin/fm-deck-chat.sh's `model` header owns the public switch/readback contract.
  steer publish: bin/fm-primary-steer.sh's header owns the public publish contract.
  steer status [--home H]       one JSON line; exit 3 when no live host
  steer delivered SEQ [--home H]
      exit 0 delivered (steer_acked >= SEQ or handled/SEQ.msg), 1 pending,
      2 rejected (rejected/SEQ.msg or steer_rejected), 3 no live host
  prepare --home H [--session ID]   create dirs, persist and print the session
  handover --home H --file F   publish F into the role's current session inbox
      without a live host (split-start transfer of peer messages and startup digests)
  record write --home H --session ID --host-pid N [--endpoint T] [--model ROUTE] [--startup-file F]
               [--set-model]   (the host's deck takes `deck-control: set_model`)
      publishes startup before making the host visible, retaining pending messages
  record stop --home H --host-pid N
  record pid --home H        print the live host pid; exit 3 when none
  supervise --home H --host-pid N --gen G --events-offset N [--effort-headers]
      events -> the role's busy-state (source deck-wrapper); only the supervising
      role (see split mode above) runs the watcher child (bin/fm-watch-arm.sh),
      whose wakes become steer publications. A failed watcher is restarted with
      backoff, never fatal. Watching pauses while state/.afk exists (the away
      daemon owns the watcher then).
      With --effort-headers, each wake gets the lowered `deck-effort:` header
      bin/fm-effort-policy.sh classify picks, and a lowered turn's tool output
      goes to its observe check as each tool result is processed.
  service --home H --deck-chat PATH [--model ROUTE]
      the keeper a launchd agent runs (bin/fm-deck-chat.sh install-service):
      adopts a live host; roles bound to the home session lock wait while any
      live harness holds it (see split mode above).
      For ordinary recovery, while captain-start is younger than
      FM_DECK_CHAT_SERVICE_START_GRACE, publishes waiting with detail "captain start
      in progress", even if it never observed the stopped marker. Once grace and
      any backoff expire, starts one with `fm-deck-chat.sh --stream` (resuming the
      persisted session), backing off while it keeps dying soon after start.
      A claimed model switch SIGTERMs the live host, resets crash backoff, and
      restarts on the claimed route without waiting for captain-start grace;
      records the route change after a successful start.
      Honours state/primary-chat/stopped, including hosts that register late.
      Waits for an in-flight --stream launcher even past its expected window;
      logs that delay once and leaves it to finish independently on shutdown.
      After a start attempt returns, or while backing off or waiting for a captain
      start, down past the alert window (default 120s) writes service-down and raises
      `fm-deck-chat.sh service-alert` once per outage, across keeper replacement;
      a stable run or explicit stop clears the marker. Env: FM_DECK_CHAT_SERVICE_POLL (2),
      _BACKOFF (5), _BACKOFF_MAX (300), _STABLE_SECS (120), _ALERT_SECS (120),
      _START_TIMEOUT (200, expected launcher window, not a termination deadline),
      _START_GRACE (60, captain-start grace seconds).
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fm_model_switch import policy_permits

BIN = Path(__file__).resolve().parent
MAX_BODY = 65536
KINDS = ('wake', 'away', 'captain', 'other')
SEQ_NAME = re.compile(r'^([1-9][0-9]*)\.msg$')
SESSION_RE = re.compile(r'^[A-Za-z0-9_-][A-Za-z0-9._-]{0,127}$')
EVENTS_TAIL_BYTES = 1 << 20
EVENTS_ROTATE_BYTES = 8 << 20
IDLE_EVENTS = ('idle', 'run_finished', 'run_stopped', 'run_failed')
BUSY_EVENTS = ('run_started', 'steer_received')
WAKE_PREAMBLE = ('The home watcher has an actionable wake. Drain bin/fm-wake-drain.sh first, '
                 'handle every emitted wake and open decision, and acknowledge only after '
                 'handling. Watcher output:\n')


def default_home():
    return os.environ.get('FM_HOME') or str(BIN.parent)


# Role-dependent names for the layout documented in the module header.
ROLES = {
    'captain': {'record': 'primary-chat.json', 'root': 'primary-chat', 'busy': 'primary',
                'session': 'firstmate-primary', 'label': 'primary-chat'},
    'supervisor': {'record': 'supervisor-chat.json', 'root': 'supervisor-chat', 'busy': 'supervisor',
                   'session': 'firstmate-supervisor', 'label': 'supervisor-chat'},
}
ROLE = 'captain'


def split_mode(home):
    config = Path(os.environ.get('FM_CONFIG_OVERRIDE') or Path(home) / 'config')
    return (config / 'primary-split').exists()


def role_for(home, role=None):
    """The role a call lands on: the supervisor exists only in split mode, so
    outside it the supervisor role is the one primary."""
    role = role or ROLE
    return role if role == 'captain' or split_mode(home) else 'captain'


def names(home, role=None):
    return ROLES[role_for(home, role)]


def paths(home, role=None):
    home = Path(home).resolve()
    state = home / 'state'
    n = names(home, role)
    return home, state, state / n['record'], state / n['root']


def atomic_write(path, data, mode=0o600):
    path = Path(path)
    fd, tmp = tempfile.mkstemp(prefix='.' + path.name + '.', dir=str(path.parent))
    try:
        with os.fdopen(fd, 'w') as handle:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(tmp, mode)
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def read_record(home, role=None):
    _, _, record, _ = paths(home, role)
    try:
        return json.loads(record.read_text())
    except (OSError, ValueError):
        return None


def host_alive(pid, home, role=None):
    """True when pid is a live fm-deck-chat host for exactly this home.

    The host re-execs with argv[0] fm-deck-chat, the physical script path,
    and --home <canonical home> last. A supervisor has --role supervisor
    immediately before --home; its presence must match the resolved role so
    a captain and supervisor in the same home cannot accept each other's pid.
    The terminal home suffix prevents a whitespace-delimited path prefix from
    accepting another home's host;
    resolving the script path keeps symlinked launches consistent with BIN.
    Steering reads, publications and stop all use this identity check.
    Regression coverage: tests/fm-deck-chat.test.sh.
    """
    if not isinstance(pid, int) or pid <= 1:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        pass
    # An exited host can linger as a zombie until its parent (a stream agent)
    # reaps it; that is not a live host.
    out = subprocess.run(['ps', '-o', 'stat=,args=', '-p', str(pid)], capture_output=True, text=True)
    fields = out.stdout.strip().split(None, 1)
    if len(fields) != 2 or fields[0].startswith('Z'):
        return False
    args = fields[1]
    home_path = str(Path(home).resolve())
    supervisor = ' --role supervisor --home ' in args
    return (args.startswith('fm-deck-chat %s ' % (BIN / 'fm-deck-chat.sh'))
            and args.endswith(' --home ' + home_path)
            and supervisor == (role_for(home, role) == 'supervisor'))


def live_record(home, role=None):
    record = read_record(home, role)
    if not record or record.get('stopped_at') or not host_alive(record.get('host_pid'), home, role):
        return None
    return record


def record_pid(args):
    record = live_record(args.home)
    if record is None:
        return 3
    print(record['host_pid'])
    return 0


def msg_seqs(directory):
    try:
        names = os.listdir(directory)
    except OSError:
        return []
    return [int(m.group(1)) for m in map(SEQ_NAME.match, names) if m]


def read_events(path):
    """Parsed events from the tail of the events file, plus its mtime."""
    try:
        with open(path, 'rb') as handle:
            handle.seek(0, os.SEEK_END)
            size = handle.tell()
            handle.seek(max(0, size - EVENTS_TAIL_BYTES))
            data = handle.read()
            mtime = int(os.fstat(handle.fileno()).st_mtime)
    except OSError:
        return [], None
    if size > EVENTS_TAIL_BYTES:
        data = data.split(b'\n', 1)[-1]
    events = []
    for line in data.splitlines():
        try:
            event = json.loads(line)
        except ValueError:
            continue
        if isinstance(event, dict) and isinstance(event.get('type'), str):
            events.append(event)
    return events, mtime


def seq_of(event):
    seq = event.get('seq')
    return seq if isinstance(seq, int) else None


def turn_state(events):
    state = 'unknown'
    for event in events:
        if event['type'] in IDLE_EVENTS:
            state = 'idle'
        elif event['type'] in BUSY_EVENTS:
            state = 'busy'
    return state


def published_seq(steer):
    try:
        return int((Path(steer) / '.seq').read_text().strip() or 0)
    except (OSError, ValueError):
        return 0


# ---------------------------------------------------------------- steer CLI

def read_body(args):
    if args.text is not None:
        body = args.text
    else:
        try:
            body = Path(args.file).read_bytes().decode('utf-8')
        except (OSError, UnicodeDecodeError) as exc:
            print('error: cannot read steer body: %s' % exc, file=sys.stderr)
            return None
    if not body.strip():
        print('error: refusing a blank steer message', file=sys.stderr)
        return None
    if len(body.encode('utf-8')) > MAX_BODY:
        print('error: steer message exceeds %d bytes' % MAX_BODY, file=sys.stderr)
        return None
    return body


def publish_body(steer, body):
    steer.mkdir(parents=True, exist_ok=True)
    with open(steer / '.publish.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        seen = (msg_seqs(steer) + msg_seqs(steer / 'handled') + msg_seqs(steer / 'rejected')
                + [published_seq(steer)])
        seq = max(seen) + 1
        # Persist the counter before the message becomes visible: a crash in
        # between leaves a gap (allowed), never a reused sequence.
        atomic_write(steer / '.seq', '%d\n' % seq)
        atomic_write(steer / ('.%d.msg.tmp' % seq), body, mode=0o600)
        os.replace(steer / ('.%d.msg.tmp' % seq), steer / ('%d.msg' % seq))
    return seq


def steer_publish(args):
    body = read_body(args)
    if body is None:
        return 2
    record = live_record(args.home)
    if record is None:
        print('error: no live deck-chat primary is registered for this home', file=sys.stderr)
        return 3
    from fm_stream_deck import with_deck_images
    imaged = with_deck_images(body)
    if len(imaged.encode('utf-8')) <= MAX_BODY:
        body = imaged
    seq = publish_body(Path(record['steer_dir']), body)
    print('seq=%d' % seq)
    print('session=%s' % record['session'])
    return 0


def steer_status(args):
    record = live_record(args.home)
    if record is None:
        stale = read_record(args.home)
        print(json.dumps({'present': False,
                          'state': 'stopped' if stale and stale.get('stopped_at') else 'unknown',
                          'endpoint': (stale or {}).get('endpoint')}))
        return 3
    steer = Path(record['steer_dir'])
    events, mtime = read_events(record['events_file'])
    acked = [seq_of(e) for e in events if e['type'] == 'steer_acked' and seq_of(e)]
    acked_seq = max(acked + msg_seqs(steer / 'handled') + [0])
    print(json.dumps({
        'present': True,
        'state': turn_state(events),
        'last_event': events[-1]['type'] if events else None,
        'last_event_at': mtime if events else None,
        'acked_seq': acked_seq,
        'published_seq': published_seq(steer),
        'pending': len(msg_seqs(steer)),
        'endpoint': record.get('endpoint'),
    }))
    return 0


def steer_delivered(args):
    seq = args.seq
    record = live_record(args.home)
    if record is None:
        return 3
    steer = Path(record['steer_dir'])
    events, _ = read_events(record['events_file'])
    if (steer / 'rejected' / ('%d.msg' % seq)).exists() or any(
            e['type'] == 'steer_rejected' and seq_of(e) == seq for e in events):
        return 2
    if (steer / 'handled' / ('%d.msg' % seq)).exists() or any(
            e['type'] == 'steer_acked' and (seq_of(e) or 0) >= seq for e in events):
        return 0
    return 1


# ---------------------------------------------------------------- host state

def prepare(args):
    home, state, _, root = paths(args.home)
    state.mkdir(exist_ok=True)
    root.mkdir(mode=0o700, exist_ok=True)
    # A host start and a split-start handover can pick the role's first session
    # at once; one lock makes them agree on it.
    with open(root / '.session.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        return _prepare_locked(args, home, root)


def _prepare_locked(args, home, root):
    session = args.session
    if not session:
        try:
            session = (root / 'session').read_text().strip()
        except OSError:
            session = ''
    if not session:
        session = '%s-%s' % (names(home)['session'], time.strftime('%Y%m%d-%H%M%S'))
    if not SESSION_RE.match(session):
        print('error: invalid deck session id: %s' % session, file=sys.stderr)
        return 2
    atomic_write(root / 'session', session + '\n')
    base = root / session
    (base / 'steer').mkdir(parents=True, exist_ok=True)
    events = base / 'events.ndjson'
    try:
        if events.stat().st_size > EVENTS_ROTATE_BYTES:
            os.replace(events, base / 'events.ndjson.1')
    except OSError:
        pass
    events.touch()
    print('session=%s' % session)
    print('steer_dir=%s' % (base / 'steer'))
    print('events_file=%s' % events)
    print('events_offset=%d' % events.stat().st_size)
    return 0


def record_write(args):
    home, _, record, root = paths(args.home)
    base = root / args.session
    if args.startup_file:
        body = read_body(argparse.Namespace(text=None, file=args.startup_file))
        if body is None:
            return 2
        publish_body(base / 'steer', body)
    atomic_write(record, json.dumps({
        'version': 1, 'home': str(home), 'session': args.session,
        'steer_dir': str(base / 'steer'), 'events_file': str(base / 'events.ndjson'),
        'endpoint': args.endpoint or None, 'host_pid': args.host_pid,
        'model': args.model, 'set_model': bool(getattr(args, 'set_model', False)),
        'started_at': int(time.time())}, sort_keys=True) + '\n')
    return 0


def handover(args):
    """Publish a file into this role's current session inbox, live host or not
    (deck reads waiting input when it starts). Used by the split-start hand-over."""
    _, _, _, root = paths(args.home)
    try:
        session = (root / 'session').read_text().strip()
    except OSError:
        session = ''
    if not session:
        rc = prepare(argparse.Namespace(home=args.home, session=''))
        if rc:
            return rc
        session = (root / 'session').read_text().strip()
    body = read_body(argparse.Namespace(text=None, file=args.file))
    if body is None:
        return 2
    print('seq=%d' % publish_body(root / session / 'steer', body))
    return 0


def record_stop(args):
    _, _, path, _ = paths(args.home)
    record = read_record(args.home)
    if not record or record.get('host_pid') != args.host_pid:
        return 0
    record['stopped_at'] = int(time.time())
    atomic_write(path, json.dumps(record, sort_keys=True) + '\n')
    return 0


# ---------------------------------------------------------------- supervisor

class Supervisor:
    def __init__(self, args):
        self.home, self.state, _, self.root = paths(args.home)
        self.busy_name = names(self.home)['busy']
        # In split mode only the supervisor watches; the captain thread's host
        # keeps its busy-state and nothing else.
        self.watching = role_for(self.home) == 'supervisor' or not split_mode(self.home)
        self.host_pid = args.host_pid
        self.gen = args.gen
        record = read_record(self.home)
        self.events_file = record['events_file']
        self.events_offset = args.events_offset
        self.events_lock = threading.RLock()
        self.events_partial = b''
        self.events_current = 'idle'
        self.effort_start = None
        self.stop = threading.Event()
        self.watch = None
        self.log_lock = threading.Lock()
        self.steer_bin = os.environ.get('FM_PRIMARY_STEER_BIN') or str(BIN / 'fm-primary-steer.sh')
        self.backoff = float(os.environ.get('FM_DECK_CHAT_WATCH_BACKOFF', '2'))
        self.backoff_max = float(os.environ.get('FM_DECK_CHAT_WATCH_BACKOFF_MAX', '60'))
        # Per-turn reasoning effort (bin/fm-effort-policy.sh owns the policy):
        # on only when the host's deck takes the `deck-effort:` header.
        self.effort_headers = args.effort_headers

    def log(self, message):
        line = '%s %s\n' % (time.strftime('%Y-%m-%dT%H:%M:%S'), message)
        with self.log_lock:
            with open(self.root / 'host.log', 'a') as handle:
                handle.write(line)

    def host_gone(self):
        try:
            os.kill(self.host_pid, 0)
        except ProcessLookupError:
            return True
        except PermissionError:
            pass
        return os.getppid() != self.host_pid

    # -- events -> busy-state
    def busy(self, state, event):
        result = subprocess.run(
            [str(BIN / 'fm-busy-event.sh'), 'apply', str(self.state), self.busy_name, state,
             '--gen', self.gen, '--source', 'deck-wrapper', '--event', event],
            capture_output=True, text=True)
        if result.returncode != 0:
            self.log('busy-state %s/%s refused: %s' % (state, event, result.stderr.strip()))

    def process_events(self):
        names = {'run_started': ('busy', 'turn-start'), 'steer_received': ('busy', 'turn-start'),
                 'run_finished': ('idle', 'turn-end'), 'run_stopped': ('idle', 'interrupted'),
                 'run_failed': ('idle', 'turn-failed'), 'idle': ('idle', 'idle')}
        with self.events_lock:
            with open(self.events_file, 'rb') as handle:
                handle.seek(self.events_offset)
                self.events_partial += handle.read()
                self.events_offset = handle.tell()
            *lines, self.events_partial = self.events_partial.split(b'\n')
            for line in lines:
                try:
                    event = json.loads(line)
                    kind = event.get('type')
                except (ValueError, AttributeError):
                    continue
                if kind == 'run_started':
                    self.effort_start = line if event.get('effort') and self.effort_headers else None
                elif kind == 'tool_result' and self.effort_start is not None:
                    self.observe_effort(self.effort_start + b'\n' + line + b'\n')
                elif kind in IDLE_EVENTS:
                    self.effort_start = None
                if kind in names and names[kind][0] != self.events_current:
                    self.events_current = names[kind][0]
                    self.busy(*names[kind])

    def follow_events(self):
        while not self.stop.is_set():
            self.process_events()
            self.stop.wait(0.1)

    # -- per-turn effort
    def effort_for(self, text):
        """The lowered level for a wake, or '' to keep the default effort."""
        if not self.effort_headers:
            return ''
        with self.events_lock:
            self.process_events()
            result = subprocess.run([str(BIN / 'fm-effort-policy.sh'), 'classify', '--home', str(self.home)],
                                    input=text, capture_output=True, text=True)
            if result.stderr.strip():
                self.log('effort policy: %s' % result.stderr.strip())
            level = result.stdout.strip() if result.returncode == 0 else ''
            return level if re.fullmatch(r'[a-z]+', level) else ''

    def observe_effort(self, events):
        result = subprocess.run([str(BIN / 'fm-effort-policy.sh'), 'observe', '--home', str(self.home)],
                                input=events, capture_output=True)
        if result.returncode != 0:
            self.log('effort policy observe failed: %s' % result.stderr.decode('utf-8', 'replace').strip())

    # -- watcher
    def start_watch(self, predecessor=None):
        env = dict(os.environ, FM_HOME=str(self.home))
        argv = ['bash', '-c',
                'if [ -f "$FM_HOME/config/x-mode.env" ]; then '
                '. "$FM_HOME/config/x-mode.env" || exit 1; fi; exec "$@"',
                'fm-deck-chat-watch', str(BIN / 'fm-watch-arm.sh')]
        if predecessor:
            env['FM_WATCH_PREDECESSOR_ARM_PID'] = str(predecessor)
            argv.append('--restart')
        out = tempfile.TemporaryFile()
        proc = subprocess.Popen(argv, stdout=out, stderr=subprocess.STDOUT, stdin=subprocess.DEVNULL,
                                cwd=str(self.home), env=env, start_new_session=True)
        self.watch = proc
        self.log('watcher arm started pid=%d%s' % (proc.pid, ' (restart)' if predecessor else ''))
        return proc, out

    def kill_watch(self):
        proc, self.watch = self.watch, None
        if proc and proc.poll() is None:
            try:
                os.killpg(proc.pid, signal.SIGTERM)
            except OSError:
                pass
            try:
                proc.wait(5)
            except subprocess.TimeoutExpired:
                try:
                    os.killpg(proc.pid, signal.SIGKILL)
                except OSError:
                    pass
                proc.wait()

    def publish(self, output):
        # Reports can exceed Deck's byte limit; the handling instructions must
        # survive because the durable wake queue, not this preview, owns the work.
        preamble = WAKE_PREAMBLE.encode('utf-8')
        level = self.effort_for(WAKE_PREAMBLE + output)
        if level:
            preamble = ('deck-effort: %s\n' % level).encode('utf-8') + preamble
            self.log('wake classified routine; effort %s' % level)
        data = output.encode('utf-8')
        budget = MAX_BODY - len(preamble)
        if len(data) > budget:
            data = data[-budget:].decode('utf-8', 'ignore').encode('utf-8')
        data = preamble + data
        with tempfile.NamedTemporaryFile('wb', delete=False, dir=str(self.root), prefix='.wake.') as tmp:
            tmp.write(data.decode('utf-8', 'ignore').encode('utf-8'))
        try:
            while not self.stop.is_set():
                result = subprocess.run([self.steer_bin, 'publish', '--home', str(self.home),
                                         '--kind', 'wake', '--file', tmp.name],
                                        capture_output=True, text=True)
                if result.returncode == 0:
                    self.log('wake published %s' % result.stdout.strip())
                    return True
                if result.returncode == 2:
                    self.log('wake publish refused: %s' % result.stderr.strip())
                    return False
                self.log('wake publish failed (exit %d): %s; retrying'
                         % (result.returncode, result.stderr.strip()))
                self.stop.wait(2)
            return False
        finally:
            os.unlink(tmp.name)

    def confirm_handling(self, out, deadline=15):
        """After a --restart, confirm the predecessor's wake reached the inbox."""
        end = time.time() + deadline
        while time.time() < end and not self.stop.is_set():
            out.seek(0)
            text = out.read().decode('utf-8', 'replace')
            match = re.search(r'^watcher: started pid=(\d+).* recovery-generation=([A-Za-z0-9._-]+)$',
                              text, re.M)
            if match:
                result = subprocess.run([str(BIN / 'fm-watch-arm.sh'), '--handling-delivered',
                                         match.group(2), '--watcher-pid', match.group(1)],
                                        capture_output=True, text=True, cwd=str(self.home),
                                        env=dict(os.environ, FM_HOME=str(self.home)))
                return result.returncode == 0
            if re.search(r'^watcher: (started|attached) pid=', text, re.M):
                return True
            if self.watch is None or self.watch.poll() is not None:
                return False
            time.sleep(0.05)
        return False

    def run_watch(self):
        delay = self.backoff
        predecessor = None
        while not self.stop.is_set():
            if (self.state / '.afk').exists():
                self.kill_watch()
                self.stop.wait(2)
                continue
            proc, out = self.start_watch(predecessor)
            if predecessor and not self.confirm_handling(out):
                self.log('successor watcher refused handling delivery confirmation; replacing it')
                self.kill_watch()
                predecessor = None
                continue
            predecessor = None
            while proc.poll() is None and not self.stop.is_set():
                if (self.state / '.afk').exists():
                    self.log('away mode active; pausing the host watcher')
                    self.kill_watch()
                    break
                self.stop.wait(0.2)
            if self.stop.is_set() or self.watch is None:
                continue
            self.watch = None
            out.seek(0)
            text = out.read().decode('utf-8', 'replace').strip()
            out.close()
            if proc.returncode != 0 or not text:
                self.log('watcher failed (exit %s): %s; restarting in %.0fs'
                         % (proc.returncode, text.splitlines()[-1] if text else 'no output', delay))
                self.stop.wait(delay)
                delay = min(delay * 2, self.backoff_max)
                continue
            delay = self.backoff
            if self.publish(text + '\n'):
                predecessor = proc.pid

    def run(self):
        signal.signal(signal.SIGINT, signal.SIG_IGN)
        signal.signal(signal.SIGTERM, lambda *_: self.stop.set())
        signal.signal(signal.SIGHUP, lambda *_: self.stop.set())
        threads = [threading.Thread(target=self.follow_events, daemon=True)]
        if self.watching:
            threads.append(threading.Thread(target=self.run_watch, daemon=True))
        for thread in threads:
            thread.start()
        self.log('supervisor started for host pid %d' % self.host_pid)
        while not self.stop.is_set():
            if self.host_gone():
                self.stop.set()
            self.stop.wait(0.5)
        self.kill_watch()
        for thread in threads:
            thread.join(5)
        self.kill_watch()
        self.log('supervisor stopped')
        return 0


# ---------------------------------------------------------------- service keeper

SERVICE_LOG_MAX = 1 << 20
# a gateway route: provider/model[/variant], nothing a shell or a path could abuse
MODEL_RE = re.compile(r'\A[a-z0-9][a-z0-9._-]{0,63}(?:/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}){1,3}\Z')


def chosen_model(root, fallback=''):
    """The configured model for this role's root, else `fallback`."""
    try:
        model = (Path(root) / 'model').read_text().strip()
    except OSError:
        return fallback
    return model if MODEL_RE.match(model) else fallback


def primary_idle(state, busy='primary'):
    """True when state/<busy>.busy-state says the host is between turns."""
    try:
        text = (Path(state) / ('%s.busy-state' % busy)).read_text()
    except OSError:
        return True
    return re.search(r'(?:^|\s)state=idle(?:\s|$)', text) is not None


def keeper_view(root):
    """The serving keeper's view while its singleton lock is held, else None."""
    root = Path(root)
    try:
        with open(root / 'service.lock', 'r') as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                view = json.loads((root / 'service.json').read_text())
                if isinstance(view, dict) and view.get('home') == str(root.parent.parent):
                    return view
    except (OSError, ValueError):
        pass
    return None


def note_switch(root, was, now):
    """Record one route change under this role's root (the thread's divider marks)."""
    path = Path(root) / 'switches'
    try:
        lines = path.read_text().splitlines()[-999:]
    except OSError:
        lines = []
    lines.append('%d %s %s' % (int(time.time()), was or 'default', now or 'default'))
    try:
        atomic_write(path, '\n'.join(lines) + '\n')
    except OSError:
        pass


def switch_in_place(root, record, route):
    """A live host whose deck takes `set_model`: send it the control, keep the
    session and the process. Deck applies it at once while idle, else at its
    next safe point, and checks the route against the gateway and policy itself."""
    atomic_write(Path(root) / 'model', route + '\n')
    try:
        (Path(root) / 'switch').unlink()
    except FileNotFoundError:
        pass
    seq = publish_body(Path(record['steer_dir']), 'deck-control: set_model %s\n' % route)
    was = record.get('model') or ''
    record['model'] = route
    # The record beside the resolved role's directory (<root>.json).
    atomic_write(Path(root).parent / (Path(root).name + '.json'), json.dumps(record, sort_keys=True) + '\n')
    if was != route:
        note_switch(root, was, route)
    return seq


def set_model(args):
    home, state, _, root = paths(args.home)
    if not args.route:
        print(chosen_model(root, (keeper_view(root) or {}).get('model', '')) or 'default')
        return 0
    if not MODEL_RE.match(args.route):
        print('error: not a model route: %s' % args.route, file=sys.stderr)
        return 2
    policy = Path(os.environ.get('FM_CONFIG_OVERRIDE') or home / 'config') / 'model-policy.json'
    if not policy_permits(args.route, policy):
        print('error: %s is blocked by the model policy' % args.route, file=sys.stderr)
        return 1
    if not root.is_dir():
        print('error: no service keeper runs this primary; restart it with --model %s' % args.route,
              file=sys.stderr)
        return 1
    with open(root / '.model.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        record = live_record(home)
        if record and record.get('set_model'):
            seq = switch_in_place(root, record, args.route)
            print('primary: switched to %s in place (steer seq %d)' % (args.route, seq))
            return 0
        if keeper_view(root) is None:
            print('error: no service keeper runs this primary; restart it with --model %s' % args.route,
                  file=sys.stderr)
            return 1
        atomic_write(root / 'model', args.route + '\n')
        atomic_write(root / 'switch', '%d %s\n' % (int(time.time()), args.route))
    print('primary: switching to %s %s' % (args.route, 'now' if primary_idle(state, names(home)['busy'])
                                            else 'after the turn under way'))
    return 0


def env_seconds(name, default):
    try:
        value = float(os.environ.get(name, default))
    except ValueError:
        return float(default)
    return value if value >= 0 else float(default)


class Keeper:
    """Keeps one role's host running; see the `service` docstring entry."""

    def __init__(self, args):
        self.home, self.state, _, _ = paths(args.home)
        # A keeper serves one role for its whole life, whatever the switch says now.
        self.role = ROLE
        self.root = self.state / ROLES[ROLE]['root']
        self.deck_chat = args.deck_chat
        self.model = args.model
        self.stop = threading.Event()
        self.poll = env_seconds('FM_DECK_CHAT_SERVICE_POLL', 2)
        self.backoff = env_seconds('FM_DECK_CHAT_SERVICE_BACKOFF', 5)
        self.backoff_max = env_seconds('FM_DECK_CHAT_SERVICE_BACKOFF_MAX', 300)
        self.stable = env_seconds('FM_DECK_CHAT_SERVICE_STABLE_SECS', 120)
        self.alert_after = env_seconds('FM_DECK_CHAT_SERVICE_ALERT_SECS', 120)
        self.start_timeout = env_seconds('FM_DECK_CHAT_SERVICE_START_TIMEOUT', 200)
        self.start_grace = env_seconds('FM_DECK_CHAT_SERVICE_START_GRACE', 60)
        self.view = None
        self.running = self.model
        self.host_pid = None

    def adopt(self, record):
        if self.host_pid == record['host_pid']:
            return
        self.host_pid = record['host_pid']
        if 'model' in record:
            self.running = record['model']
            return
        out = subprocess.run(['ps', '-o', 'args=', '-p', str(self.host_pid)],
                             capture_output=True, text=True)
        match = re.search(r' --model (\S+)(?: |$)', out.stdout)
        self.running = match.group(1) if match and MODEL_RE.match(match.group(1)) else self.model

    def claim_switch(self):
        claimed = self.root / '.switch-claimed'
        try:
            os.replace(self.root / 'switch', claimed)
        except FileNotFoundError:
            return None
        try:
            fields = claimed.read_text().split()
            return fields[1] if len(fields) == 2 and MODEL_RE.match(fields[1]) else None
        finally:
            claimed.unlink()

    def note_switch(self, was, now):
        note_switch(self.root, was, now)

    def log(self, message):
        path = self.root / 'service.log'
        try:
            if path.stat().st_size > SERVICE_LOG_MAX:
                os.replace(path, self.root / 'service.log.1')
        except OSError:
            pass
        with open(path, 'a') as handle:
            handle.write('%s %s\n' % (time.strftime('%Y-%m-%dT%H:%M:%S'), message))

    def publish(self, state, detail=''):
        if self.view == (state, detail):
            return
        self.view = (state, detail)
        atomic_write(self.root / 'service.json', json.dumps({
            'version': 1, 'home': str(self.home), 'pid': os.getpid(), 'state': state,
            'detail': detail, 'since': int(time.time()), 'model': self.model}, sort_keys=True) + '\n')

    def stopped_on_purpose(self):
        return (self.root / 'stopped').exists()

    def lock_holder(self):
        """The pid of a live harness holding the session lock, else None."""
        result = subprocess.run([str(BIN / 'fm-lock.sh'), 'status'], capture_output=True, text=True,
                                env=dict(os.environ, FM_HOME=str(self.home)), stdin=subprocess.DEVNULL)
        match = re.search(r'held by live harness pid (\d+)', result.stdout)
        return match.group(1) if match else None

    def run_deck_chat(self, argv, timeout):
        """Bound helper commands, but wait for --stream without cancelling it."""
        env = dict(os.environ, FM_HOME=str(self.home), FM_DECK_CHAT_SERVICE='1')
        with tempfile.TemporaryFile() as out:
            proc = subprocess.Popen([self.deck_chat] + argv, stdout=out, stderr=subprocess.STDOUT,
                                    stdin=subprocess.DEVNULL, env=env, start_new_session=True)
            end = time.monotonic() + timeout
            streaming = argv[0] == '--stream'
            overdue = False
            while proc.poll() is None and not self.stop.is_set():
                if time.monotonic() >= end:
                    if not streaming:
                        break
                    if not overdue:
                        self.log('start still running past expected %gs window; waiting for launcher pid=%d'
                                 % (timeout, proc.pid))
                        overdue = True
                self.stop.wait(0.2)
            if proc.poll() is None:
                if streaming:
                    return 125, ''
                proc.terminate()
                try:
                    proc.wait(5)
                except subprocess.TimeoutExpired:
                    proc.kill()
                    proc.wait()
                rc = 124
            else:
                rc = proc.returncode
            out.seek(0)
            return rc, out.read().decode('utf-8', 'replace')

    def start(self, model=None):
        argv = ['--stream'] + (['--role', 'supervisor'] if self.role == 'supervisor' else []) + ['--home', str(self.home)]
        if model is None:
            model = chosen_model(self.root, self.model)
        if model:
            argv += ['--model', model]
        rc, out = self.run_deck_chat(argv, self.start_timeout)
        tail = ' | '.join(line for line in out.strip().splitlines()[-3:])
        self.log('start exit %d: %s' % (rc, tail or 'no output'))
        if rc == 0:
            self.running = model
            record = live_record(self.home)
            self.host_pid = record['host_pid'] if record else None
        return rc == 0

    def alert(self, down_for):
        summary = ('firstmate %s for %s has been down %ds despite the service; '
                   'see %s' % ('supervisor' if self.role == 'supervisor' else 'primary',
                               self.home, down_for, self.root / 'service.log'))
        try:
            (self.root / 'service-down').write_text(
                '%s %s\n' % (time.strftime('%Y-%m-%dT%H:%M:%S%z'), summary))
        except OSError:
            pass
        self.log('ALERT: ' + summary)
        rc, out = self.run_deck_chat(['service-alert'] + (['--role', 'supervisor'] if self.role == 'supervisor' else [])
                                     + ['--home', str(self.home), '--summary', summary], 120)
        if rc != 0:
            self.log('service-alert exit %d: %s' % (rc, out.strip()[-300:]))

    def recovered(self):
        try:
            (self.root / 'service-down').unlink()
        except OSError:
            pass

    def run(self):
        signal.signal(signal.SIGTERM, lambda *_: self.stop.set())
        signal.signal(signal.SIGHUP, lambda *_: self.stop.set())
        signal.signal(signal.SIGINT, lambda *_: self.stop.set())
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        lock = open(self.root / 'service.lock', 'a')
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            self.log('another keeper holds service.lock; waiting for it')
            while not self.stop.is_set():
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except OSError:
                    self.stop.wait(self.poll)
            if self.stop.is_set():
                return 0
        self.log('keeper started pid=%d model=%s' % (os.getpid(), self.model or 'default'))
        outage = time.time() if (self.root / 'service-down').exists() else None
        up_since = None
        last_start = 0.0
        delay = 0.0
        next_try = 0.0
        alerted = outage is not None
        was_down = False
        switch_model = None
        switch_from = None
        while not self.stop.is_set():
            now = time.time()
            if ROLE == 'supervisor' and not split_mode(self.home):
                # Without config/primary-split the one primary supervises; a
                # supervisor keeper waits for the switch instead of starting a
                # second captain-role host.
                self.publish('waiting', 'split mode is off (no config/primary-split)')
                self.stop.wait(self.poll)
                continue
            if self.stopped_on_purpose():
                if live_record(self.home):
                    self.log('stopped on purpose; stopping a late-registered host')
                    self.run_deck_chat(['stop'] + (['--role', 'supervisor'] if self.role == 'supervisor' else [])
                                       + ['--home', str(self.home)], 60)
                if outage is not None or was_down:
                    self.log('stopped on purpose; not restarting')
                self.publish('stopped', 'state/%s/stopped present' % names(self.home)['root'])
                outage, up_since, alerted, was_down, delay = None, None, False, False, 0.0
                switch_model = None
                self.recovered()
                self.stop.wait(self.poll)
                continue
            record = live_record(self.home)
            if record:
                self.adopt(record)
            model = (self.claim_switch() if record and switch_model is None
                     and primary_idle(self.state, names(self.home)['busy']) else None)
            if model is not None:
                switch_model, switch_from = model, self.running
                self.log('switching the primary to %s: restarting its host on the same session' % model)
                self.publish('switching', model)
                try:
                    os.kill(record['host_pid'], signal.SIGTERM)
                except (OSError, KeyError, TypeError):
                    pass
                for _ in range(100):
                    if live_record(self.home) is None or self.stop.is_set():
                        break
                    self.stop.wait(0.1)
                last_start, delay, next_try = 0.0, 0.0, 0.0
                continue
            if record:
                if was_down:
                    self.log('primary is up in endpoint %s' % record.get('endpoint'))
                    was_down = False
                up_since = up_since or now
                if outage is not None and now - up_since >= self.stable:
                    outage, alerted, delay = None, False, 0.0
                    self.recovered()
                self.publish('running', record.get('endpoint') or 'pid %s' % record.get('host_pid'))
                self.stop.wait(self.poll)
                continue
            up_since = None
            # The captain thread of a split home never takes the session lock.
            lock_bound = self.role == 'supervisor' or not split_mode(self.home)
            holder = self.lock_holder() if lock_bound else None
            if holder:
                self.publish('waiting', 'session lock held by live harness pid %s' % holder)
                self.stop.wait(self.poll)
                continue
            if not was_down:
                was_down = True
                crash_loop = bool(last_start) and now - last_start < self.stable
                if not crash_loop:
                    delay = 0.0
                if outage is None:
                    outage = now
                next_try = now + (delay if crash_loop else 0.0)
                self.log('primary is down; restarting %s'
                         % ('in %ds (it died %ds after its last start)' % (delay, now - last_start)
                            if crash_loop else 'now'))
            try:
                captain_start = float((self.root / 'captain-start').read_text())
            except (OSError, ValueError):
                captain_start = 0.0
            if switch_model is None and now - captain_start < self.start_grace:
                self.publish('waiting', 'captain start in progress')
            elif now >= next_try:
                self.publish('starting', 'fm-deck-chat.sh --stream')
                last_start = now
                if self.start(switch_model):
                    if switch_model is not None:
                        if switch_model != switch_from:
                            self.note_switch(switch_from, switch_model)
                        switch_model = None
                    was_down = False
                if self.stop.is_set():
                    break
                delay = min(max(delay * 2, self.backoff), self.backoff_max)
                next_try = time.time() + delay
            else:
                self.publish('down', 'next start at %s' % time.strftime('%H:%M:%S', time.localtime(next_try)))
            if (not alerted and outage is not None and live_record(self.home) is None
                    and time.time() - outage >= self.alert_after):
                alerted = True
                self.alert(int(time.time() - outage))
            self.stop.wait(self.poll)
        self.log('keeper stopped')
        return 0


def main(argv):
    global ROLE
    parser = argparse.ArgumentParser(prog='fm_primary_chat.py')
    parser.add_argument('--role', choices=sorted(ROLES), default=os.environ.get('FM_CHAT_ROLE') or 'captain')
    sub = parser.add_subparsers(dest='cmd', required=True)
    steer = sub.add_parser('steer').add_subparsers(dest='action', required=True)
    publish = steer.add_parser('publish')
    body = publish.add_mutually_exclusive_group(required=True)
    body.add_argument('--text')
    body.add_argument('--file')
    publish.add_argument('--kind', choices=KINDS, default='other', help='informational only')
    status = steer.add_parser('status')
    delivered = steer.add_parser('delivered')
    delivered.add_argument('seq', type=int)
    for command in (publish, status, delivered):
        command.add_argument('--home', default=default_home())
    prep = sub.add_parser('prepare')
    prep.add_argument('--home', required=True)
    prep.add_argument('--session', default='')
    record = sub.add_parser('record').add_subparsers(dest='action', required=True)
    write = record.add_parser('write')
    write.add_argument('--session', required=True)
    write.add_argument('--endpoint', default='')
    write.add_argument('--model', default='')
    write.add_argument('--startup-file')
    write.add_argument('--set-model', action='store_true')
    stop = record.add_parser('stop')
    record.add_parser('pid').add_argument('--home', required=True)
    for command in (write, stop):
        command.add_argument('--home', required=True)
        command.add_argument('--host-pid', type=int, required=True)
    supervise = sub.add_parser('supervise')
    supervise.add_argument('--home', required=True)
    supervise.add_argument('--host-pid', type=int, required=True)
    supervise.add_argument('--gen', required=True)
    supervise.add_argument('--events-offset', type=int, required=True)
    supervise.add_argument('--effort-headers', action='store_true',
                           help='mark routine wakes for a lower reasoning effort (bin/fm-effort-policy.sh)')
    hand = sub.add_parser('handover')
    hand.add_argument('--home', required=True)
    hand.add_argument('--file', required=True)
    model = sub.add_parser('model')
    model.add_argument('--home', default=default_home())
    model.add_argument('route', nargs='?', default='')
    service = sub.add_parser('service')
    service.add_argument('--home', required=True)
    service.add_argument('--deck-chat', required=True)
    service.add_argument('--model', default='')
    args = parser.parse_args(argv)
    ROLE = args.role
    if args.cmd == 'steer':
        if not Path(args.home).is_dir():
            print('error: home not found: %s' % args.home, file=sys.stderr)
            return 3
        return {'publish': steer_publish, 'status': steer_status,
                'delivered': steer_delivered}[args.action](args)
    if args.cmd == 'prepare':
        return prepare(args)
    if args.cmd == 'handover':
        return handover(args)
    if args.cmd == 'record':
        return {'write': record_write, 'stop': record_stop, 'pid': record_pid}[args.action](args)
    if args.cmd == 'service':
        return Keeper(args).run()
    if args.cmd == 'model':
        return set_model(args)
    return Supervisor(args).run()


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
