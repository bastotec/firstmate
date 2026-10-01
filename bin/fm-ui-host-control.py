#!/usr/bin/env python3
"""Host-only owner routing for a same-origin, local UI adapter.

Usage: fm-ui-host-control.py --registry FILE --machine NAME --label NAME
                           note --text TEXT
       fm-ui-host-control.py --registry FILE --machine NAME --label NAME
                           interrupt|exit|relaunch|recover-missing [--note TEXT]

FILE is an operator-maintained, host-only regular file owned by this uid with
mode 0600, containing a JSON array of bindings:
  {"machine": NAME, "label": NAME, "fm_home": ABSOLUTE_PATH,
   "task_id": EXACT_TASK_ID}
A primary supervisor has task_id null and accepts only note, not lifecycle
verbs. Every (machine, label) and (fm_home, task_id) must be unique. Unknown,
ambiguous, malformed, or stale bindings refuse before dispatch. For a task,
label must equal fm-<task_id>, the stream publisher's label. The home's
config/stream-machine (default hostname) must match machine; metadata must
exist. fm-control owns all deeper endpoint, lease, eligibility and remote
secondmate checks. This router does not accept paths or arbitrary arguments
from the request, resolve keys, append task status, or respond to gates.

The local UI adapter owns per-launch browser authorization and same-origin
checks BEFORE calling this executable. It keeps registry and hub credentials
host-only; this program is not an HTTP server or a browser authentication gate.
Only an already-authorized host process may invoke it. note queues intent in
the owning supervisor's durable inbox, never closes a decision itself.
"""

import argparse
import json
import os
from pathlib import Path
import re
import socket
import stat
import subprocess
import sys


class Refused(ValueError):
    pass


def unique_fields(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise Refused('ambiguous registry field')
        result[key] = value
    return result


def bindings(filename):
    flags = os.O_RDONLY | getattr(os, 'O_NOFOLLOW', 0)
    with os.fdopen(os.open(filename, flags), encoding='utf-8') as stream:
        info = os.fstat(stream.fileno())
        if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                or stat.S_IMODE(info.st_mode) != 0o600 or info.st_nlink != 1):
            raise Refused('registry must be an owned single-link regular 0600 file')
        rows = json.load(stream, object_pairs_hook=unique_fields)
    if not isinstance(rows, list):
        raise Refused('registry must be an array of bindings')
    leaves, owners = set(), set()
    for row in rows:
        if not isinstance(row, dict) or set(row) != {'machine', 'label', 'fm_home', 'task_id'}:
            raise Refused('malformed registry binding')
        for field in ('machine', 'label'):
            if not isinstance(row[field], str) or not re.fullmatch(r'[A-Za-z0-9._-]+', row[field]):
                raise Refused('invalid registry identity')
        home = row['fm_home']
        if not isinstance(home, str) or not Path(home).is_absolute() or not Path(home).is_dir():
            raise Refused('registry home must be an existing absolute directory')
        task = row['task_id']
        if task is not None and (not isinstance(task, str)
                                 or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', task)):
            raise Refused('invalid exact task id')
        if task is not None and row['label'] != 'fm-' + task:
            raise Refused('task label does not match the stream publisher label')
        leaf = row['machine'], row['label']
        owner = str(Path(home).resolve()), task
        if leaf in leaves or owner in owners:
            raise Refused('ambiguous registry binding')
        leaves.add(leaf)
        owners.add(owner)
    return rows


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--registry', required=True)
    parser.add_argument('--machine', required=True)
    parser.add_argument('--label', required=True)
    commands = parser.add_subparsers(dest='action', required=True)
    commands.add_parser('note').add_argument('--text', required=True)
    for action in ('interrupt', 'exit', 'relaunch', 'recover-missing'):
        command = commands.add_parser(action)
        if action in ('relaunch', 'recover-missing'):
            command.add_argument('--note', required=True)
    args = parser.parse_args()
    rows = bindings(args.registry)
    matches = [row for row in rows if (row['machine'], row['label']) == (args.machine, args.label)]
    if len(matches) != 1:
        raise Refused('unknown or ambiguous target')
    row = matches[0]
    home = Path(row['fm_home']).resolve()
    machine_file = home / 'config/stream-machine'
    machine = machine_file.read_text().strip() if machine_file.exists() else socket.gethostname()
    if machine != args.machine:
        raise Refused('registry machine disagrees with owning home')
    task = row['task_id']
    if task is not None:
        meta = home / 'state' / (task + '.meta')
        if not meta.is_file() or meta.is_symlink():
            raise Refused('registered task has no regular owner metadata')
    scripts = Path(__file__).resolve().parent
    if args.action == 'note':
        if not args.text.strip():
            raise Refused('note must not be blank')
        argv = [str(scripts / 'fm-inbox.sh'), 'note', '-']
        body = args.text
    else:
        if task is None:
            raise Refused('primary lifecycle is unsupported; only supervisor notes exist')
        argv = [str(scripts / 'fm-control.sh'), task, args.action]
        if args.action in ('relaunch', 'recover-missing'):
            argv.extend(['--note', args.note])
        body = None
    env = os.environ.copy()
    # A caller's current home overrides must never redirect the resolved owner.
    for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE'):
        env.pop(key, None)
    env['FM_HOME'] = str(home)
    return subprocess.run(argv, input=body, text=True, env=env, cwd=home, check=False).returncode


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Refused, OSError, ValueError) as exc:
        print('REFUSED: %s' % exc, file=sys.stderr)
        sys.exit(2)
