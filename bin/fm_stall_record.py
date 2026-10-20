#!/usr/bin/env python3
"""Conservative stalled-task timing shared by idle scans and recovery snapshots.

Usage: fm_stall_record.py RECORD META CURRENT_LINE OPEN_DECISIONS [--observe|--ack] [--now EPOCH]
OPEN_DECISIONS is the fm-classify-lib.sh status_open_decisions TSV contract.
Read mode has no side effects; only the idle sweep, under its scan lock, uses
--observe and --ack. RECORD lives in state/idle-sweep/<id>.stall.json.
The JSON projection reports state=stalled strictly after 7200 seconds of observed
implementation without an attributed validation run, or 3600 seconds of an open
needs-decision reconciled with a parked current state. Unknown evidence, declared
waits, other task kinds and delivery modes reset observation instead of guessing.
Timing is a lower bound: since first matching observation, not status-file mtime
(which can change on unrelated events). last_run_seen is the last successful
attributed run observation, not an invented run creation timestamp. Missing,
corrupt, future or generation-mismatched timing starts a fresh observation.
Episode identity includes metadata contents, phase and the folded pending questions;
a resumed state or new question starts another episode. --ack records delivery
only for the currently matching stalled episode. Atomic owner-only writes refuse
symlinks. No worker ledger, hold, gate or approval record is changed.
The digest routes questions for mate triage, never infers captain authority from
age or an ask-user label, and never invents a question for implementation stalls.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import tempfile
import time


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def load(path):
    try:
        if not path.is_symlink():
            value = json.loads(path.read_text())
            if isinstance(value, dict):
                return value
    except (OSError, ValueError):
        pass
    return {}


def epoch(value, now):
    return type(value) is int and 0 < value <= now


def write(path, value):
    if path.is_symlink():
        raise ValueError('refusing symlinked stall record')
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(dir=path.parent, prefix='.stall-')
    try:
        with os.fdopen(fd, 'w') as stream:
            json.dump(value, stream)
            stream.write('\n')
        os.replace(tmp, path)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('record', type=Path)
    parser.add_argument('meta', type=Path)
    parser.add_argument('current')
    parser.add_argument('decisions')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--observe', action='store_true')
    mode.add_argument('--ack', action='store_true')
    parser.add_argument('--now', type=int, default=int(time.time()))
    args = parser.parse_args()
    fields = args.current.split(' · ')
    state = fields[0].removeprefix('state: ')
    source = fields[1].removeprefix('source: ') if len(fields) > 1 else ''
    meta = {}
    identity = ''
    if not args.meta.is_symlink():
        try:
            raw = args.meta.read_text()
            meta = dict(line.split('=', 1) for line in raw.splitlines() if '=' in line)
            identity = digest(raw)
        except OSError:
            pass
    old = load(args.record)
    if old.get('identity') != identity or not epoch(old.get('observed_at'), args.now):
        old = {}
    pending = []
    for row in args.decisions.splitlines():
        cells = row.split('\t', 2)
        if len(cells) == 3 and cells[1] == 'needs-decision':
            pending.append(cells[2])
    eligible = (bool(identity) and meta.get('kind') == 'ship'
                and meta.get('mode', '') in ('', 'ship', 'no-mistakes')
                and not meta.get('remote_host') and 'declared-wait: active' not in fields)
    phase = ''
    if eligible and state == 'parked' and pending:
        phase = 'needs-decision'
    elif eligible and state == 'working' and source in ('pane', 'status-log'):
        phase = 'implementation'
    signature = digest(json.dumps([identity, phase, pending if phase == 'needs-decision' else []]))
    since = old.get('since') if old.get('signature') == signature else None
    if old.get('signature') != signature or not epoch(since, old.get('observed_at', 0)):
        since = args.now if phase else None
    last_run = old.get('last_run_seen')
    if not epoch(last_run, args.now):
        last_run = None
    if eligible and source == 'run-step':
        last_run = args.now
    age = args.now - since if since is not None else None
    threshold = 3600 if phase == 'needs-decision' else 7200
    stalled = bool(phase and age is not None and age > threshold)
    episode = digest(f'{signature}:{since}') if phase else None
    reported = old.get('reported')
    result = dict(version=1, identity=identity, observed_at=args.now,
                  signature=signature, since=since, phase=phase or None,
                  age_seconds=age, last_run_seen=last_run,
                  seconds_since_last_run=args.now-last_run if last_run else None,
                  state='stalled' if stalled else 'observing' if phase else 'ineligible',
                  questions=pending if phase == 'needs-decision' else [],
                  route='mate-triage' if phase == 'needs-decision' else 'mate-repair',
                  episode=episode, reported=reported,
                  notify=stalled and reported != episode)
    if args.ack and stalled:
        result.update(reported=episode, notify=False)
    if args.observe or args.ack:
        write(args.record, result)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
