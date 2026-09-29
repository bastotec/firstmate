#!/usr/bin/env python3
"""Deck's stream-order application seam, not a second transport or command store.

The ordinary task inbox is the durable source and command-id binding. Deck's
per-turn inbox is only its required plain-text/canonical-sequence projection.
An endpoint-scoped lifecycle lock serializes publication with driver start/end.
No projection is ever carried into the next turn. Only Deck's handled file
confirms application; inbox publication, run liveness and PTY writes do not.
Driver CLI: fm_stream_deck.py start|end STATE ID ENDPOINT [TURN SUPPORTED].
start prints the turn projection path; end retires the active descriptor.
"""
import contextlib
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


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

    def start(self, turn, supported):
        with self.locked():
            projection = self.root / turn
            projection.mkdir(mode=0o700)
            atomic_write(self.root / 'active.json', json.dumps({
                'turn': turn, 'supported': supported, 'active': True}))
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
                    body = record.read_text().split('\n--\n', 1)[1]
                except FileNotFoundError:
                    # The ordinary worker may acknowledge concurrently.
                    record = self.inbox / 'handled' / record.name
                    if not record.exists():
                        continue
                    body = record.read_text().split('\n--\n', 1)[1]
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

    def apply(self, order_id, execution, text, alive, reconcile_only=False):
        """None means this is not a Deck driver; all other answers are final facts.

        Unknown application is returned honestly as unconfirmed, never as an
        acceptance. Retrying the same id reconciles its original turn only.
        """
        if execution != self.endpoint:
            return False, 'stale execution; steer was not applied'
        with self.locked():
            found = self.find(order_id)
            if found:
                record, binding, original = found
                if original != text or binding['execution'] != execution:
                    return False, 'steering idempotency conflict'
            else:
                if reconcile_only:
                    return None, 'Deck binding unavailable; application unconfirmed'
                active = self.active()
                if active is None or not active['active']:
                    return None
                limit = 65536 - 2 * len(str(self.inbox).encode('utf-8')) - 400
                if not text.strip() or len(text.encode('utf-8')) > limit:
                    return False, 'Deck steering is blank or exceeds interface size with source reference'
                if not active['supported']:
                    return False, 'Deck has no --steer-dir interface; no PTY fallback'
                if not alive():
                    return False, 'no active Deck turn; steer was not applied'
                binding = {'order_id': order_id, 'execution': execution,
                           'turn': active['turn']}
                record = self.enqueue(binding, text)
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
                # Reconstruct any earlier source-only publication left by a
                # crash before making a larger sequence visible to Deck.
                sources = []
                for directory in (self.inbox, self.inbox / 'handled'):
                    for source in directory.glob('*.msg'):
                        try:
                            body = source.read_text().split('\n--\n', 1)[1]
                        except FileNotFoundError:
                            continue
                        if body.startswith('[stream-order '):
                            prior = json.loads(body.split('\n', 1)[0][14:-1])
                            if prior == binding or (prior['execution'] == execution
                                                   and prior['turn'] == binding['turn']):
                                sources.append((int(source.stem), body.split('\n', 2)[2]))
                for number, body in sorted(sources):
                    name = str(number) + '.msg'
                    if not any((projection / sub / name).exists()
                               for sub in ('', 'handled', 'rejected')):
                        source = self.inbox / ('%03d.msg' % number)
                        guidance = body + '\n\nAfter handling this native steer, acknowledge its ordinary task-inbox source by moving ' + str(source) + ' to ' + str(self.inbox / 'handled' / source.name) + '. Do not apply the same source record twice.'
                        if len(guidance.encode('utf-8')) > 65536:
                            return False, 'Deck steering exceeds interface size after source reference'
                        atomic_write(projection / name, guidance)
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


def main():
    action, state, task, endpoint, *args = sys.argv[1:]
    receiver = Receiver(state, task, endpoint)
    if action == 'start':
        print(receiver.start(args[0], args[1] == '1'))
    elif action == 'end':
        receiver.end()
    else:
        raise SystemExit('expected start or end')


if __name__ == '__main__':
    main()
