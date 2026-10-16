#!/usr/bin/env python3
"""Deck's stream-order application seam, not a second transport or command store.

The ordinary task inbox is the durable message source. Per-order reservations
bind unpublished messages to their original turn and retain hub command IDs
and bounded result-retry metadata. Deck's per-turn inbox is
only its required plain-text/canonical-sequence projection.
An endpoint-scoped lifecycle lock serializes publication with driver start/end.
No projection is ever carried into the next turn. Only Deck's handled file
confirms application; inbox publication, run liveness and PTY writes do not.
Driver CLI: fm_stream_deck.py start|end STATE ID ENDPOINT [TURN SUPPORTED [SET_MODEL [HOME]]].
SET_MODEL 1 records that this turn's Deck takes `deck-control: set_model`
(bin/fm_model_switch.py publishes it only into such a turn).
HOME selects captain recall's operational home; absent, it defaults to STATE's
parent. bin/fm_captain_memory.py owns the recall contract.
start prints the turn projection path; end retires the active descriptor.
fm_stream_deck.py captain STATE ID flushes eligible direct sources and bound
Bridge orders; project_captain owns eligibility and acknowledgement rules.
with_deck_images owns how a captain attachment becomes a Deck image part.
"""
import contextlib
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import time
import subprocess
import sys
import tempfile

try:
    from fm_captain_memory import with_memory
except Exception:
    with_memory = None


ATTACHED_IMAGE = re.compile(r'^Attached: (/.+?) \(image, [^()\n]+\)\s*$')
IMAGE_SUFFIXES = {'.png', '.jpg', '.jpeg', '.webp', '.gif'}


def with_deck_images(text):
    """Follow each Fleet Town image attachment line with a Deck image line.

    Fleet Town names a staged copy as `Attached: <abs path> (image, <size>)`.
    When that path is a file on this host with a png, jpg, jpeg, webp or gif
    suffix (case-insensitive), a `deck-image: <path>` line immediately after it
    makes Deck send the picture itself as an image part of the same message;
    an older Deck shows the line as text.
    An identical directive already immediately after the attachment is retained
    without duplication, so repeated mapping is safe.
    Other lines, missing files and other kinds pass through unchanged.
    """
    lines = text.split('\n')
    out = []
    for index, line in enumerate(lines):
        out.append(line)
        match = ATTACHED_IMAGE.match(line)
        if not match:
            continue
        path = match.group(1)
        directive = 'deck-image: ' + path
        if (Path(path).suffix.lower() in IMAGE_SUFFIXES and Path(path).is_file()
                and lines[index + 1:index + 2] != [directive]):
            out.append(directive)
    return '\n'.join(out)


def atomic_write(path, body):
    """Publish only after file and containing-directory durability."""
    fd, name = tempfile.mkstemp(prefix='.publish.', dir=path.parent)
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(body)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        sync_dir(path.parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def sync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


class Receiver:
    def __init__(self, state, task, endpoint):
        self.state = Path(state)
        self.task = task
        self.endpoint = endpoint
        self.inbox = self.state / (task + '.inbox')
        self.root = self.inbox / ('deck-' + endpoint)

    @contextlib.contextmanager
    def locked(self):
        self.root.mkdir(parents=True, exist_ok=True, mode=0o700)
        with (self.root / '.lifecycle.lock').open('a') as lock:
            fcntl.flock(lock, fcntl.LOCK_EX)
            yield

    def active(self):
        try:
            return json.loads((self.root / 'active.json').read_text())
        except FileNotFoundError:
            return None

    def start(self, turn, supported, set_model=False, home=None):
        with self.locked():
            projection = self.root / turn
            projection.mkdir(mode=0o700)
            atomic_write(self.root / 'active.json', json.dumps({
                'turn': turn, 'supported': supported, 'set_model': set_model, 'active': True,
                'home': str(home or self.state.parent)}))
            return str(projection)

    def end(self):
        with self.locked():
            active = self.active()
            if active:
                active['active'] = False
                atomic_write(self.root / 'active.json', json.dumps(active))

    def find(self, order_id):
        for directory in (self.inbox, self.inbox / 'handled'):
            for record in directory.glob('*.msg'):
                try:
                    body = record.read_bytes().decode('utf-8').split('\n--\n', 1)[1]
                except FileNotFoundError:
                    # The ordinary worker may acknowledge concurrently.
                    record = self.inbox / 'handled' / record.name
                    if not record.exists():
                        continue
                    body = record.read_bytes().decode('utf-8').split('\n--\n', 1)[1]
                if not body.startswith('[stream-order '):
                    continue
                binding = json.loads(body.split('\n', 1)[0][14:-1])
                if binding['order_id'] == order_id:
                    return record, binding, body.split('\n', 2)[2]
        return None

    def enqueue(self, binding, text):
        # Reuse the existing writer, sequence allocator, lock and record format.
        body = '[stream-order ' + json.dumps(binding, sort_keys=True) + ']\nNative Deck delivery only: do not execute this source as ordinary steering. Retain it until native guidance instructs acknowledgement.\n' + text
        library = str(Path(__file__).with_name('fm-task-inbox-lib.sh'))
        result = subprocess.run(['bash', '-c',
            '. "$1"; fm_task_inbox_write_idempotent "$2" "$3" "$4" fire-and-forget',
            'stream-order', library, str(self.state), self.task, body],
            capture_output=True, text=True, check=True)
        record = Path(result.stdout.strip())
        with record.open('rb') as stream:
            os.fsync(stream.fileno())
        sync_dir(record.parent)
        return record

    def publish(self, active, before=None):
        """Flush both native sources in sequence under the lifecycle lock."""
        projection = self.root / active['turn']
        visible = [int(p.stem) for sub in ('', 'handled', 'rejected')
                   for p in (projection / sub).glob('*.msg') if p.stem.isdigit()]
        floor = max(visible, default=0)
        candidates = []
        for directory in (self.inbox, self.inbox / 'handled'):
            for source in directory.glob('*.msg'):
                if not source.stem.isdigit():
                    continue
                try:
                    record = source.read_bytes().decode('utf-8')
                    body = record.split('\n--\n', 1)[1]
                except (FileNotFoundError, IndexError, UnicodeDecodeError):
                    continue
                bridge = body.startswith('[stream-order ')
                if bridge:
                    try:
                        binding = json.loads(body.split('\n', 1)[0][14:-1])
                        if (binding['execution'] != self.endpoint
                                or binding['turn'] != active['turn']):
                            continue
                        body = body.split('\n', 2)[2]
                    except (ValueError, KeyError, IndexError):
                        continue
                elif directory != self.inbox or not supervisor_direct(record, captain_lane(self.state, self.task)):
                    continue
                while True:
                    quoted = re.sub(r'(\[[^\]]*?)fm-captain-memory(?!-quoted)', r'\1fm-captain-memory-quoted', body, flags=re.I | re.A)
                    if quoted == body:
                        break
                    body = quoted
                if not bridge:
                    body = with_deck_images(body)
                ordinary = self.inbox / source.name
                guidance = body + '\n\nAfter handling this native steer, acknowledge its ordinary task-inbox source by moving ' + str(ordinary) + ' to ' + str(self.inbox / 'handled' / source.name) + '. Do not apply the same source record twice.'
                if not bridge and (not body.strip() or len(guidance.encode('utf-8')) > 65536):
                    continue
                if with_memory is not None:
                    try:
                        guidance = with_memory(active.get('home') or self.state.parent, guidance)
                    except Exception:
                        pass
                candidates.append((int(source.stem), body, guidance))
        published = 0
        for number, body, guidance in sorted(candidates):
            if before is not None and number >= before:
                break
            if number <= floor:
                continue
            if not body.strip() or len(guidance.encode('utf-8')) > 65536:
                # Do not let a larger sequence strand an eligible predecessor.
                break
            atomic_write(projection / (str(number) + '.msg'), guidance)
            floor = number
            published += 1
        return published

    def order_path(self, order_id):
        return self.root / ('order-' + hashlib.sha256(
            order_id.encode('utf-8')).hexdigest() + '.json')

    def save_result(self, order_id, command_id, result):
        with self.locked():
            path = self.order_path(order_id)
            try:
                stored = json.loads(path.read_text())
            except FileNotFoundError:
                stored = {}
            results = stored.setdefault('results', {})
            previous = results.get(command_id)
            if previous and previous['result'] != result['result']:
                raise ValueError('command result idempotency conflict')
            results[command_id] = {key: value for key, value in result.items()
                                   if not key.startswith('_')}
            atomic_write(path, json.dumps(stored))

    def recover(self):
        commands, results = [], {}
        with self.locked():
            for path in self.root.glob('order-*.json'):
                stored = json.loads(path.read_text())
                saved = stored.get('results', {})
                results.update(saved)
                binding = stored.get('binding')
                if not binding or binding['execution'] != self.endpoint:
                    continue
                outstanding = [command_id for command_id in stored.get('command_ids', [])
                               if command_id not in saved]
                if not outstanding:
                    continue
                found = self.find(binding['order_id'])
                if not found:
                    continue
                for command_id in outstanding:
                    commands.append({
                        'command_id': command_id, 'endpoint_id': self.endpoint, 'kind': 'steer',
                        'payload': {'order_id': binding['order_id'],
                                    'execution_id': self.endpoint, 'text': found[2]},
                        '_native_prepared': True, '_steering_reservation': stored})
        return commands, results

    def apply(self, order_id, execution, text, alive, reconcile_only=False,
              reservation=None, command_id=None, reserve_only=False):
        """Observe once; the agent's command_loop owns waiting and retry cadence.

        Bare None leaves driver detection to the caller. Tuple ok=True/False
        is a confirmed result; ok=None is reserved, pending or unconfirmed,
        never acceptance. Retrying the same id reconciles its original turn
        only, including handled/rejected proof after that turn ends.
        """
        if execution != self.endpoint:
            return False, 'stale execution; steer was not applied'
        if reservation is None:
            reservation = {}
        with self.locked():
            if not reservation.get('binding') and not reconcile_only:
                active = self.active()
                if active and active['active'] and active['supported']:
                    reservation.update({
                        'binding': {'order_id': order_id, 'execution': execution,
                                    'turn': active['turn']},
                        'text_sha256': hashlib.sha256(text.encode('utf-8')).hexdigest()})
            reserved_path = self.order_path(order_id)
            try:
                stored = json.loads(reserved_path.read_text())
            except FileNotFoundError:
                stored = None
            if stored:
                reservation.update(stored)
            if reservation.get('binding'):
                changed = reservation != stored
                if command_id and command_id not in reservation.setdefault('command_ids', []):
                    reservation['command_ids'].append(command_id)
                    changed = True
                if changed:
                    atomic_write(reserved_path, json.dumps(reservation))
            found = self.find(order_id)
            if found:
                record, binding, original = found
                canonical = {'binding': binding, 'text_sha256': hashlib.sha256(
                    original.encode('utf-8')).hexdigest()}
                changed = any(reservation.get(key) != value for key, value in canonical.items())
                reservation.update(canonical)
                if command_id and command_id not in reservation.setdefault('command_ids', []):
                    reservation['command_ids'].append(command_id)
                    changed = True
                if changed:
                    atomic_write(reserved_path, json.dumps(reservation))
                if original != text or binding['execution'] != execution:
                    return False, 'steering idempotency conflict'
            else:
                if not reservation.get('binding'):
                    if reconcile_only:
                        return None, 'Deck binding unavailable; application unconfirmed'
                    active = self.active()
                    if active and active['active'] and not active['supported']:
                        return False, 'Deck has no --steer-dir interface; no PTY fallback'
                    return None
                binding = reservation['binding']
                if (binding['order_id'] != order_id or binding['execution'] != execution
                        or reservation['text_sha256'] != hashlib.sha256(
                            text.encode('utf-8')).hexdigest()):
                    return False, 'steering idempotency conflict'
                active = self.active()
                if (not reserve_only and (not active or not active['active']
                        or active['turn'] != binding['turn'] or not alive())):
                    return None, 'original Deck turn ended; application unconfirmed'
                limit = 65536 - 2 * len(str(self.inbox).encode('utf-8')) - 400
                if not text.strip() or len(text.encode('utf-8')) > limit:
                    return False, 'Deck steering is blank or exceeds interface size with source reference'
                if active and active['turn'] == binding['turn'] and not active['supported']:
                    return False, 'Deck has no --steer-dir interface; no PTY fallback'
                record = self.enqueue(binding, text)
            if reserve_only:
                with record.open('rb') as stream:
                    os.fsync(stream.fileno())
                sync_dir(record.parent)
                return None, 'Deck application reserved'
            seq = str(int(record.stem))
            projection = self.root / binding['turn']
            message = projection / (seq + '.msg')
            handled = projection / 'handled' / message.name
            rejected = projection / 'rejected' / message.name
            # A crash after source publication is recoverable only while that
            # exact turn is still active, never by publishing into its successor.
            if not (message.exists() or handled.exists() or rejected.exists()):
                active = self.active()
                if not active or not active['active'] or active['turn'] != binding['turn']:
                    return None, 'original Deck turn ended; application unconfirmed'
                self.publish(active)
        if handled.is_file():
            return True, ''
        if rejected.is_file():
            return False, 'Deck rejected the steering message'
        active = self.active()
        if (not active or not active['active'] or active['turn'] != binding['turn']
                or not alive()):
            if handled.is_file():
                return True, ''
            return None, 'Deck application unconfirmed for original turn; retained in task inbox'
        return None, 'Deck application pending'


# Direct sources: text the captain wrote to this agent himself, and peer
# messages from another second mate (bin/fm-operational-input.sh owns both
# carriers). Each wakes an idle agent and reaches a live turn natively.
CAPTAIN_DIRECT = re.compile(
    '\\A(?:(?:\\[fm-from-firstmate\\]⁣(?:corr=\\S+ )?)?\\[fm-captain-direct\\]'
    '|\\[fm-from-mate:[A-Za-z0-9._-]+\\])⁣')


# Delivery tags identify the party independently of the record's stream.
# record_stream and supervisor_direct below own split-lane eligibility.
CAPTAIN_ONLY = re.compile(
    '\\A(?:\\[fm-from-firstmate\\]⁣(?:corr=\\S+ )?)?\\[fm-captain-direct\\]⁣')
HANDOFF = re.compile('\\A\\[fm-captain-thread\\]⁣')


SUPERVISOR_NOTE = re.compile('\\A\\[fm-supervisor-note\\]')


def record_stream(text):
    """('conversation' | 'monologue', body) for one whole inbox record.

    A split agent's conversation takes a party's words (the captain, the first
    mate, another mate) and its own supervisor's notes; everything automatic is
    its inner monologue. The `stream=` header bin/fm-send.sh records at delivery
    decides; a record without one (written before it existed, or by a writer
    that never sets it) is a conversation only when it carries a captain-direct,
    peer-mate or supervisor-note tag, and otherwise monologue."""
    head, sep, body = text.partition('\n--\n')
    if not sep:
        return 'monologue', ''
    for line in head.splitlines():
        if line in ('stream=conversation', 'stream=monologue'):
            return line[7:], body
    if CAPTAIN_DIRECT.match(body) or SUPERVISOR_NOTE.match(body):
        return 'conversation', body
    return 'monologue', body


def captain_lane(state, task):
    return (Path(state) / (task + '.captain-lane')).is_file()


def supervisor_direct(text, lane):
    """Whether the supervisor's turn takes this whole inbox record as a direct
    source: every captain-direct or peer record without a conversation lane;
    with one, the conversation's hand-offs, and a direct record only when it
    was delivered to the monologue."""
    stream, body = record_stream(text)
    if not lane:
        return bool(CAPTAIN_DIRECT.match(body))
    return bool(HANDOFF.match(body)) or (bool(CAPTAIN_DIRECT.match(body)) and stream == 'monologue')


FROM_MATE = re.compile('\\A\\[fm-from-mate:([A-Za-z0-9._-]+)\\]⁣')


def record_party(body):
    """Who wrote a conversation record: 'captain', 'mate:<id>', 'monologue' (its
    own supervisor's note) or 'firstmate', read from its delivery tags."""
    if CAPTAIN_ONLY.match(body):
        return 'captain'
    peer = FROM_MATE.match(body)
    if peer:
        return 'mate:' + peer.group(1)
    if SUPERVISOR_NOTE.match(body):
        return 'monologue'
    return 'firstmate'


def conversation_record(text):
    """A record a split agent's conversation lane takes (never its hand-offs)."""
    stream, body = record_stream(text)
    return stream == 'conversation' and not HANDOFF.match(body)


def project_captain(state, task):
    """Best-effort ordered publication of native sources into live Deck turns.

    The ring and driver turn-start call this independently of terminal input.
    Only active, supported turn descriptors with an existing projection qualify;
    ordinary firstmate steers are not projected. Deck consumes published records
    at its next safe point (run start, after a tool batch, before finishing).
    The ordinary source stays durable: only the model's move of that source into
    the task inbox's handled/ acknowledges it, not publication or movement of the
    native projection. The doorbell remains the fallback for unhandled sources.

    Both publication paths flush eligible direct sources (captain-direct and
    from-mate records) and Bridge orders bound to the active execution and turn
    in sequence under the lifecycle lock.
    No sequence is published below one already visible in that turn, because
    Deck silently drops a late lower sequence. Guidance, including source paths
    and attachment expansion from with_deck_images, must fit Deck's 64 KiB
    UTF-8 byte ceiling. Native-ineligible direct sources
    retain their ordinary inbox fallback without blocking later eligible sources;
    an ineligible bound Bridge order stops the flush rather than being overtaken.
    Prints the total number of native projections published, including Bridge
    orders. tests/fm-stream-deck.test.sh pins eligibility and ordering.
    """
    inbox = Path(state) / (task + '.inbox')
    published = 0
    for root in sorted(inbox.glob('deck-*')):
        endpoint = root.name[len('deck-'):]
        receiver = Receiver(state, task, endpoint)
        with receiver.locked():
            active = receiver.active()
            if not active or not active.get('active') or not active.get('supported'):
                continue
            projection = receiver.root / active['turn']
            if not projection.is_dir():
                continue
            published += receiver.publish(active)
    return published


def idle_captain_sequence(state, task, floor):
    """Newest pending direct source; observation never acknowledges it."""
    newest = int(floor)
    for source in (Path(state) / (task + '.inbox')).glob('*.msg'):
        if not source.stem.isdigit():
            continue
        try:
            record = source.read_bytes().decode('utf-8')
        except (FileNotFoundError, UnicodeDecodeError):
            continue
        if supervisor_direct(record, captain_lane(state, task)):
            newest = max(newest, int(source.stem))
    return newest


def conversation_busy(state, task):
    """True while a split agent's conversation lane has work it has not finished:
    a turn running now (<task>.captain-lane.turn), or a conversation record
    still in the inbox whose turn is not journaled as answered (or abandoned
    after a failed recovery). Supervision that watches
    only the supervisor's endpoint for turn completion asks this too."""
    state = Path(state)
    if not captain_lane(state, task):
        return False
    # A turn the lane is running right now, a recovery turn included.
    if (state / (task + '.captain-lane.turn')).is_file():
        return True
    last = {}
    try:
        for line in (state / (task + '.captain-lane.answered')).read_text().splitlines():
            step, _, name = line.partition(' ')
            if name:
                last[name] = step
    except FileNotFoundError:
        pass
    except OSError:
        return True
    for source in (state / (task + '.inbox')).glob('*.msg'):
        if not source.stem.isdigit() or last.get(source.name) in ('answered', 'recovering'):
            continue
        try:
            if conversation_record(source.read_bytes().decode('utf-8')):
                return True
        except (OSError, UnicodeDecodeError):
            continue
    return False


def stale_handoffs(state, task, age, now=None):
    """Hand-offs ([fm-captain-thread] records) still unhandled in the inbox more
    than `age` seconds after delivery, oldest first."""
    state = Path(state)
    now = time.time() if now is None else now
    found = []
    for source in (state / (task + '.inbox')).glob('*.msg'):
        if not source.stem.isdigit():
            continue
        try:
            text = source.read_bytes().decode('utf-8')
            if not HANDOFF.match(record_stream(text)[1]) or now - source.stat().st_mtime < age:
                continue
        except (OSError, UnicodeDecodeError):
            continue
        found.append((int(source.stem), source.name))
    return [name for _, name in sorted(found)]


def main():
    if sys.argv[1:2] == ['stale-handoffs']:
        print('\n'.join(stale_handoffs(sys.argv[2], sys.argv[3], float(sys.argv[4]))))
        return
    if sys.argv[1:2] == ['conversation-busy']:
        sys.exit(0 if conversation_busy(sys.argv[2], sys.argv[3]) else 1)
    if sys.argv[1:2] == ['captain']:
        _, state, task = sys.argv[1:4]
        print(project_captain(state, task))
        return
    action, state, task, endpoint, *args = sys.argv[1:]
    receiver = Receiver(state, task, endpoint)
    if action == 'start':
        print(receiver.start(args[0], args[1] == '1', args[2:3] == ['1'], args[3] if len(args) > 3 else None))
    elif action == 'end':
        receiver.end()
    else:
        raise SystemExit('expected start, end or captain')


if __name__ == '__main__':
    main()
