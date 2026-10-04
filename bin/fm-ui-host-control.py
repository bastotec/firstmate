#!/usr/bin/env python3
"""Host-only owner routing for a same-origin, local UI adapter.

Usage: fm-ui-host-control.py --registry FILE command|targets

targets emits one browser-safe JSON array, with machine, label, target_class
(primary/secondmate/worker), supported_operations and boolean call_available.
It validates the whole registry and owning-home identities before publishing;
no paths, task ids, captain-call ids, credentials or owner output are emitted.
Operations describe routing capability, not current owner eligibility.
call_available means an exact decision target is bound, not that it is held.

command consumes NDJSON command records with command_id, identity containing
parent_mate_id and leaf_worker_id (machine/label), and payload containing kind
plus exactly the fields listed for its kind:
  note: text; resolve-key: key and text; answer/release: text;
  interrupt/exit: no additional fields; relaunch/recover-missing: note.
Required text and note fields must be nonblank strings. No request supplies
a home path, file path, executable, or arbitrary argv. Only pre-authorized
host callers may submit records. Accepted command_ack means the existing
owner returned success, NOT that the worker acted on an inbox answer.
Pre-dispatch refusals
return command_ack refused. Nonzero owner exits may follow partial writes,
so they remain pending (no record), with a host-only diagnostic; reconcile
before retrying. Correlated host_owner_result records on host-only stderr
retain the owner's stdout, stderr and exit code, including successful warnings.
Children never inherit the command stream's stdin. This local plane has no hub
journal or automatic retry.

FILE is an operator-maintained, host-only single-link regular file owned by
this uid with mode 0600, containing a JSON array of bindings:
  {"machine": NAME, "label": NAME, "fm_home": ABSOLUTE_PATH,
   "task_id": EXACT_TASK_ID}
A primary supervisor has task_id null and accepts note, plus answer/release
when its binding includes "captain_call_id": EXACT_CAPTAIN_CALL_ID in that
home's backlog. The browser cannot select or override that id. Task-key
resolve-key actions require a task_id binding in the decision-owning home.
Primary interrupt, exit, relaunch and recover-missing explicitly refuse with
primary-lifecycle-owner-absent; primary steer (text) explicitly refuses with
primary-not-stream-registered. No primary task or endpoint is synthesized.
Every (machine, label) and (fm_home, task_id) must be unique. Unknown, ambiguous,
or malformed bindings refuse before dispatch, as does missing regular task
metadata for actions that require it. Stale captain calls and deeper task
eligibility checks are decided by the owner; nonzero owner exits stay pending
under the result contract above. For a task, label must equal fm-<task_id>,
the stream publisher's label. The home's stream machine identity resolved
by fm_backend_stream_machine must match machine. The host delegates as the main supervision actor, preserving live
branch leases even without a Pi caller environment. Worker actions
require regular owner metadata; answer/release resolve the registered exact
captain-call id through fm-captain-hold's backlog guards instead. fm-control
owns all deeper endpoint, lease, eligibility and remote secondmate checks.
Decision actions delegate to fm-send --decision-answer with --resolve-key or
fm-captain-hold answer (with --release for release), preserving exact words.
fm-send's header owns locked exact-task and inbox-only decision delivery.
This router never appends task status directly and never invokes no-mistakes
axi respond.

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
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timezone


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
        required = {'machine', 'label', 'fm_home', 'task_id'}
        if (not isinstance(row, dict) or not required <= set(row)
                or set(row) - required - {'captain_call_id'}):
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
        if 'captain_call_id' in row:
            call = row['captain_call_id']
            if (task is not None or not isinstance(call, str)
                    or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', call)):
                raise Refused('captain-call binding requires a primary target and exact call id')
        if task is not None and row['label'] != 'fm-' + task:
            raise Refused('task label does not match the stream publisher label')
        leaf = row['machine'], row['label']
        owner = str(Path(home).resolve()), task
        if leaf in leaves or owner in owners:
            raise Refused('ambiguous registry binding')
        leaves.add(leaf)
        owners.add(owner)
    return rows


def owner_context(row):
    home = Path(row['fm_home']).resolve()
    scripts = Path(__file__).resolve().parent
    env = os.environ.copy()
    for key in ('FM_ROOT_OVERRIDE', 'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE'):
        env.pop(key, None)
    env['FM_HOME'] = str(home)
    env['FM_SUPERVISION_ACTOR'] = 'main'
    identity = subprocess.run(['bash', '-c', '. "$1"; fm_backend_stream_machine',
                               'fm-ui-host-control', str(scripts / 'backends/stream.sh')],
                              stdin=subprocess.DEVNULL, text=True, env=env, cwd=home,
                              capture_output=True, check=False)
    if identity.returncode:
        raise Refused('owning home stream machine identity unavailable')
    if identity.stdout != row['machine']:
        raise Refused('registry machine disagrees with owning home')
    return home, scripts, env


def task_metadata(home, task):
    meta = home / 'state' / (task + '.meta')
    if not meta.is_file() or meta.is_symlink():
        raise Refused('registered task has no regular owner metadata')
    return meta


def targets(filename):
    result = []
    for row in bindings(filename):
        home, _, _ = owner_context(row)
        task = row['task_id']
        operations = ['note']
        call = task is not None or 'captain_call_id' in row
        target_class = 'primary'
        if task is not None:
            meta = task_metadata(home, task)
            kinds = [line[5:] for line in meta.read_text(encoding='utf-8').splitlines()
                     if line.startswith('kind=')]
            if len(kinds) != 1 or kinds[0] not in ('ship', 'scout', 'secondmate'):
                raise Refused('registered task has ambiguous or unsupported target class')
            target_class = 'secondmate' if kinds[0] == 'secondmate' else 'worker'
            operations += ['resolve-key', 'interrupt', 'exit', 'relaunch', 'recover-missing']
        if call:
            operations += ['answer', 'release']
        result.append(dict(machine=row['machine'], label=row['label'],
                           target_class=target_class, supported_operations=operations,
                           call_available=call))
    print(json.dumps(result), flush=True)
    return 0


def route(rows, machine, label, payload):
    matches = [row for row in rows if (row['machine'], row['label']) == (machine, label)]
    if len(matches) != 1:
        raise Refused('unknown or ambiguous target')
    row = matches[0]
    home, scripts, env = owner_context(row)
    action = payload.get('kind')
    task = row['task_id']
    fields = {
        'steer': {'kind', 'text'},
        'note': {'kind', 'text'},
        'resolve-key': {'kind', 'key', 'text'},
        'answer': {'kind', 'text'},
        'release': {'kind', 'text'},
        'interrupt': {'kind'},
        'exit': {'kind'},
        'relaunch': {'kind', 'note'},
        'recover-missing': {'kind', 'note'},
    }
    if not isinstance(action, str) or action not in fields or set(payload) != fields[action]:
        raise Refused('unsupported action or payload fields')
    text = payload.get('text', payload.get('note'))
    if fields[action] & {'text', 'note'} and (not isinstance(text, str) or not text.strip()):
        raise Refused('note or answer must not be blank')
    if task is None:
        if action in ('interrupt', 'exit', 'relaunch', 'recover-missing'):
            raise Refused('primary-lifecycle-owner-absent')
        if action == 'steer':
            raise Refused('primary-not-stream-registered')
        if action == 'resolve-key':
            raise Refused('task-key decisions require an exact task binding')
    elif action == 'steer':
        raise Refused('unsupported action or payload fields')
    call = row.get('captain_call_id') if task is None else task
    if action in ('answer', 'release') and call is None:
        raise Refused('primary decision requires an exact captain-call id in the host registry')
    if task is not None and action not in ('answer', 'release'):
        task_metadata(home, task)
    decision_file = None
    if action == 'note':
        argv = [str(scripts / 'fm-inbox.sh'), 'note', '-']
        body = text
    elif action == 'resolve-key':
        key = payload['key']
        if not isinstance(key, str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9._-]*', key):
            raise Refused('invalid decision key')
        if text.lstrip().startswith(('/', '--')):
            raise Refused('decision answer cannot be a harness invocation or send option')
        argv = [str(scripts / 'fm-send.sh'), '--decision-answer', task, '--resolve-key', key, text]
        body = None
    elif action in ('answer', 'release'):
        if len(text.encode('utf-8')) > 8192:
            raise Refused('captain answer exceeds the owner limit')
        # The existing owner consumes a file, never text reinterpreted as flags.
        decision_file = tempfile.NamedTemporaryFile(mode='w', encoding='utf-8',
                                                     prefix='fm-ui-answer-', delete=False)
        decision_file.write(text)
        decision_file.close()
        argv = [str(scripts / 'fm-captain-hold.sh'), 'answer', call,
                '--decision-file', decision_file.name]
        if action == 'release':
            argv.append('--release')
        body = None
    else:
        argv = [str(scripts / 'fm-control.sh'), task, action]
        if action in ('relaunch', 'recover-missing'):
            argv.extend(['--note', text])
        body = None
    try:
        return subprocess.run(argv, input=body if body is not None else '', text=True, env=env, cwd=home,
                              capture_output=True, check=False)
    finally:
        if decision_file is not None:
            os.unlink(decision_file.name)


def command_stream(filename):
    for line in sys.stdin:
        command_id = leaf = None
        try:
            record = json.loads(line, object_pairs_hook=unique_fields)
            if not isinstance(record, dict) or record.get('record') != 'command':
                raise Refused('expected a command record')
            command_id = record.get('command_id')
            identity = record.get('identity')
            if not isinstance(command_id, str) or not command_id or not isinstance(identity, dict):
                raise Refused('command requires its id and identity')
            leaf = identity.get('leaf_worker_id')
            machine = identity.get('parent_mate_id')
            if not isinstance(leaf, str) or not isinstance(machine, str) or not leaf.startswith(machine + '/'):
                raise Refused('leaf and parent identity disagree')
            payload = record.get('payload')
            if not isinstance(payload, dict):
                raise Refused('command requires an action payload')
            result = route(bindings(filename), machine, leaf[len(machine) + 1:], payload)
            if result.stdout or result.stderr or result.returncode:
                print(json.dumps({'record': 'host_owner_result', 'command_id': command_id,
                                  'leaf_worker_id': leaf, 'exit_code': result.returncode,
                                  'state': 'unconfirmed' if result.returncode else 'confirmed',
                                  'stdout': result.stdout, 'stderr': result.stderr}),
                      file=sys.stderr, flush=True)
            if result.returncode:
                continue
            answer = {'record': 'command_ack', 'command_id': command_id,
                      'leaf_worker_id': leaf, 'state': 'accepted',
                      'received_at_utc': datetime.now(timezone.utc).isoformat()}
        except (Refused, OSError, ValueError) as exc:
            if not isinstance(command_id, str) or not command_id or not isinstance(leaf, str):
                print('REFUSED: invalid command framing', file=sys.stderr)
                continue
            answer = {'record': 'command_ack', 'command_id': command_id,
                      'leaf_worker_id': leaf, 'state': 'refused',
                      'reason': str(exc) if isinstance(exc, Refused) else 'host routing unavailable or malformed request',
                      'received_at_utc': datetime.now(timezone.utc).isoformat()}
        print(json.dumps(answer), flush=True)
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--registry', required=True)
    parser.add_argument('action', choices=['command', 'targets'])
    args = parser.parse_args()
    if args.action == 'targets':
        try:
            return targets(args.registry)
        except (Refused, OSError, ValueError) as exc:
            raise Refused(str(exc) if isinstance(exc, Refused)
                          else 'host discovery unavailable or malformed registry') from None
    return command_stream(args.registry)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (Refused, OSError, ValueError) as exc:
        print('REFUSED: %s' % exc, file=sys.stderr)
        sys.exit(2)
