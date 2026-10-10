#!/usr/bin/env python3
"""State, steering and supervision for a `deck chat` primary.

bin/fm-deck-chat.sh is the host; bin/fm-primary-steer.sh is the public steer
CLI. Both call this file, which owns the on-disk layout:

  state/primary-chat.json                 the host record (0600, atomic)
  state/primary-chat/session              the persisted deck session id
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
                                          {"pid","state","detail","since","home"};
                                          state is running|starting|down|waiting|stopped
  state/primary-chat/service.log          keeper log (size-capped, one rotation)
  state/primary-chat/service-down         durable alert marker while the primary
                                          has been down past the alert window
  state/primary-chat/service.lock         keeper singleton (flock)

Record (state/primary-chat.json):
  {"version":1,"home":ABS,"session":ID,"steer_dir":ABS,"events_file":ABS,
   "endpoint":"<hub-tag>:<endpoint-id>"|null,"host_pid":N,"started_at":EPOCH}
A clean host exit adds "stopped_at". A record is live only when it has no
stopped_at and host_alive(host_pid, home) validates the host identity below.

Subcommands:
  steer publish (--text T | --file F) [--kind wake|away|captain|other] [--home H]
      kind is informational; prints seq=<n>; exit 2 refused
      (blank/oversized/unreadable), 3 no live host
  steer status [--home H]       one JSON line; exit 3 when no live host
  steer delivered SEQ [--home H]
      exit 0 delivered (steer_acked >= SEQ or handled/SEQ.msg), 1 pending,
      2 rejected (rejected/SEQ.msg or steer_rejected), 3 no live host
  prepare --home H [--session ID]   create dirs, persist and print the session
  record write --home H --session ID --host-pid N [--endpoint T] [--startup-file F]
      publishes startup before making the host visible, retaining pending messages
  record stop --home H --host-pid N
  record pid --home H        print the live host pid; exit 3 when none
  supervise --home H --host-pid N --gen G --events-offset N [--effort-headers]
      events -> busy-state (state/primary.busy-state, source deck-wrapper) and
      the watcher child (bin/fm-watch-arm.sh) whose wakes become steer
      publishes; a failed watcher is restarted with backoff, never fatal.
      Paused while state/.afk exists (the away daemon owns the watcher then).
      With --effort-headers, each wake gets the lowered `deck-effort:` header
      bin/fm-effort-policy.sh classify picks, and a lowered turn's tool output
      goes to its observe check as each tool result is processed.
  service --home H --deck-chat PATH [--model ROUTE]
      the keeper a launchd agent runs (bin/fm-deck-chat.sh install-service):
      adopts a live host and waits while any live harness holds the session lock.
      Otherwise, while captain-start is younger than FM_DECK_CHAT_SERVICE_START_GRACE,
      publishes waiting with detail "captain start in progress", even if it never
      observed the stopped marker. Once grace and any backoff expire, starts one
      with `fm-deck-chat.sh --stream` (resuming the persisted session), backing off
      while it keeps dying soon after start.
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


def paths(home):
    home = Path(home).resolve()
    state = home / 'state'
    return home, state, state / 'primary-chat.json', state / 'primary-chat'


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


def read_record(home):
    _, _, record, _ = paths(home)
    try:
        return json.loads(record.read_text())
    except (OSError, ValueError):
        return None


def host_alive(pid, home):
    """True when pid is a live fm-deck-chat host for exactly this home.

    The host re-execs with argv[0] fm-deck-chat, the physical script path,
    and --home <canonical home> last. The terminal home suffix prevents a
    whitespace-delimited path prefix from accepting another home's host;
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
    home = str(Path(home).resolve())
    return (args.startswith('fm-deck-chat %s ' % (BIN / 'fm-deck-chat.sh'))
            and args.endswith(' --home ' + home))


def live_record(home):
    record = read_record(home)
    if not record or record.get('stopped_at') or not host_alive(record.get('host_pid'), home):
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
    seq = publish_body(Path(record['steer_dir']), body)
    print('seq=%d' % seq)
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
    session = args.session
    if not session:
        try:
            session = (root / 'session').read_text().strip()
        except OSError:
            session = ''
    if not session:
        session = 'firstmate-primary-%s' % time.strftime('%Y%m%d-%H%M%S')
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
        'started_at': int(time.time())}, sort_keys=True) + '\n')
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
            [str(BIN / 'fm-busy-event.sh'), 'apply', str(self.state), 'primary', state,
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
        threads = [threading.Thread(target=self.follow_events, daemon=True),
                   threading.Thread(target=self.run_watch, daemon=True)]
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


def env_seconds(name, default):
    try:
        value = float(os.environ.get(name, default))
    except ValueError:
        return float(default)
    return value if value >= 0 else float(default)


class Keeper:
    """Keeps one home's primary host running; see the `service` docstring entry."""

    def __init__(self, args):
        self.home, self.state, _, self.root = paths(args.home)
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
            'detail': detail, 'since': int(time.time())}, sort_keys=True) + '\n')

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

    def start(self):
        argv = ['--stream', '--home', str(self.home)]
        if self.model:
            argv += ['--model', self.model]
        rc, out = self.run_deck_chat(argv, self.start_timeout)
        tail = ' | '.join(line for line in out.strip().splitlines()[-3:])
        self.log('start exit %d: %s' % (rc, tail or 'no output'))
        return rc == 0

    def alert(self, down_for):
        summary = ('firstmate primary for %s has been down %ds despite the service; '
                   'see %s' % (self.home, down_for, self.root / 'service.log'))
        try:
            (self.root / 'service-down').write_text(
                '%s %s\n' % (time.strftime('%Y-%m-%dT%H:%M:%S%z'), summary))
        except OSError:
            pass
        self.log('ALERT: ' + summary)
        rc, out = self.run_deck_chat(['service-alert', '--home', str(self.home), '--summary', summary], 120)
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
        while not self.stop.is_set():
            now = time.time()
            if self.stopped_on_purpose():
                if live_record(self.home):
                    self.log('stopped on purpose; stopping a late-registered host')
                    self.run_deck_chat(['stop', '--home', str(self.home)], 60)
                if outage is not None or was_down:
                    self.log('stopped on purpose; not restarting')
                self.publish('stopped', 'state/primary-chat/stopped present')
                outage, up_since, alerted, was_down, delay = None, None, False, False, 0.0
                self.recovered()
                self.stop.wait(self.poll)
                continue
            record = live_record(self.home)
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
            holder = self.lock_holder()
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
            if now - captain_start < self.start_grace:
                self.publish('waiting', 'captain start in progress')
            elif now >= next_try:
                self.publish('starting', 'fm-deck-chat.sh --stream')
                last_start = now
                if self.start():
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
    parser = argparse.ArgumentParser(prog='fm_primary_chat.py')
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
    write.add_argument('--startup-file')
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
    service = sub.add_parser('service')
    service.add_argument('--home', required=True)
    service.add_argument('--deck-chat', required=True)
    service.add_argument('--model', default='')
    args = parser.parse_args(argv)
    if args.cmd == 'steer':
        if not Path(args.home).is_dir():
            print('error: home not found: %s' % args.home, file=sys.stderr)
            return 3
        return {'publish': steer_publish, 'status': steer_status,
                'delivered': steer_delivered}[args.action](args)
    if args.cmd == 'prepare':
        return prepare(args)
    if args.cmd == 'record':
        return {'write': record_write, 'stop': record_stop, 'pid': record_pid}[args.action](args)
    if args.cmd == 'service':
        return Keeper(args).run()
    return Supervisor(args).run()


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
