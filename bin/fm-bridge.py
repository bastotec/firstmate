#!/usr/bin/env python3
"""fm-bridge.py - which flows may cross the bridge between this machine and another.

bin/fm-bridge.sh is the entry point; this file holds the whole contract.

A bridge joins this home's machine to a remote machine (an ssh alias). Each bridge
allows a set of flows; anything else is refused before it leaves this machine.
bin/fm-on.sh, the one path Firstmate uses to act on another machine, asks `check`
before every remote command and calls `block` when the answer is no.

Flow meanings (bin/fm-on.sh's classification table owns command mapping):
  supervision  launch-state reads, relaunch, interrupt/exit, retire, route, capture, observe
  reports      wakes, replies, deltas and follow-ups read back from the remote home
  messages     direct messages or steering sent to a remote mate or specialist
  placement    putting work there: launching a second mate, backlog handoff, skill routing
  files        file and attachment transfer
  maintenance  code, config and inheritance sync, updates, extensions, budget probes
The readiness doctor (fm-remote-doctor.sh) is the connect flow itself and is never gated.

Record: <home>/config/bridges.json, private, written atomically
under a lock:
  {"version": 1, "bridges": {"<alias>": {"allow": [flow...], "seeded": bool,
                                         "updated": "<utc>", "by": "<who>"}}}
When the file does not exist, the first command seeds it from the machines this home
already reaches, via fm-machine-skills.sh roots using <home>/data (not a scratch
FM_DATA_OVERRIDE inventory): each gets every flow, "seeded": true, so existing
bridges keep working and show as configured.
Registration, remote seeding, and migration initialize this record before publishing
new routes; a later machine with no entry allows nothing until the captain allows
flows (`allow`, `set`, bin/fm-machine.sh register --allow, or an approval card).
An existing unreadable or invalid record is refused, never re-seeded.
`local` (this machine) needs no cross-machine permission.

Seed and permission-change events append a JSON line to <home>/state/bridges.log:
{at, by, event: seeded|changed, bridge, before, after}.
Blocked events instead carry {at, by, event: blocked, bridge, flow, what,
request, new_request}; request identifies the pending approval reused or created.
FM_STATE_OVERRIDE selects the audit directory when set.

Usage:
  fm-bridge.sh show [--json]
  fm-bridge.sh check <machine> <flow>            exit 0 allowed, 1 denied
  fm-bridge.sh allow <machine> <flow>... [--by TEXT]
  fm-bridge.sh deny <machine> <flow>... [--by TEXT]
  fm-bridge.sh set <machine> --allow <flow,...|none> [--by TEXT]
  fm-bridge.sh block <machine> <flow> --what <text>
  fm-bridge.sh audit [--limit N] [--json]

show --json prints {flows: [...], bridges: [{machine, allow, deny, seeded, updated,
by, configured}]}, one entry per bridge recorded or machine known; configured is false
for a known machine with no entry (it allows nothing). set replaces a bridge's flows.

block records a refused flow: one audit line, and one pending request in this home's
state/approvals/ (the approval card path Fleet Town already shows; agent `primary`,
tool `bridge`, gate `bridge:<flow>`, args {machine, flow, what}) unless one is already
pending for the same bridge and flow. It prints the request id.
bin/fm-approval.py's header owns bridge approval answers and retry steering.

Exit: 0 ok/allowed; 1 denied or refused; 2 usage.
"""
import hashlib
import json
import os
import re
import secrets
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
FLOWS = ('supervision', 'reports', 'messages', 'placement', 'files', 'maintenance')
NAME_RE = re.compile(r'\A(?!-)[A-Za-z0-9._-]+\Z')


class Refuse(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def iso(t):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'))


def home():
    return Path(os.environ.get('FM_HOME') or SCRIPT_DIR.parent)


def record_path():
    return home() / 'config' / 'bridges.json'


def log_path():
    return Path(os.environ.get('FM_STATE_OVERRIDE') or home() / 'state') / 'bridges.log'


def write_private(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(f'.{path.name}.{secrets.token_hex(4)}')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def audit(entry):
    log = log_path()
    log.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, 'a', encoding='utf-8') as f:
        f.write(canonical(dict(at=iso(time.time()), **entry)) + '\n')


class Lock:
    def __enter__(self):
        self.path = record_path().parent / '.bridges.lock'
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        for _ in range(100):
            try:
                self.path.mkdir()
                return self
            except FileExistsError:
                time.sleep(0.1)
        raise Refuse(f'the bridges lock {self.path} is busy; try again')

    def __exit__(self, *exc):
        try:
            self.path.rmdir()
        except OSError:
            pass


def known_machines():
    env = dict(os.environ, FM_HOME=str(home()), FM_DATA_OVERRIDE=str(home() / 'data'))
    try:
        result = subprocess.run([str(SCRIPT_DIR / 'fm-machine-skills.sh'), 'roots'],
                                env=env, check=True, capture_output=True, text=True)
    except (OSError, subprocess.CalledProcessError) as e:
        raise Refuse(f'cannot read machine inventory: {e}')
    return [line.split('\t', 1)[0] for line in result.stdout.splitlines()
            if line.split('\t', 1)[0] != 'local' and NAME_RE.match(line.split('\t', 1)[0])]


def validate(record):
    if not isinstance(record, dict) or not isinstance(record.get('bridges'), dict):
        raise Refuse(f'{record_path()} must hold {{"bridges": {{...}}}}')
    for name, b in record['bridges'].items():
        if not NAME_RE.match(name) or name == 'local':
            raise Refuse(f'{record_path()}: bad bridge name {name!r}')
        if not isinstance(b, dict) or not isinstance(b.get('allow'), list) \
                or any(f not in FLOWS for f in b['allow']):
            raise Refuse(f'{record_path()}: bridge {name} needs "allow": a list of {", ".join(FLOWS)}')


def load():
    """The record, seeding it on first use. A record that cannot be read refuses."""
    path = record_path()
    if not path.exists():
        with Lock():
            if not path.exists():
                t = iso(time.time())
                record = {'version': 1, 'bridges': {m: {'allow': list(FLOWS), 'seeded': True, 'updated': t,
                                                        'by': 'seeded from existing routes'}
                                                    for m in known_machines()}}
                write_private(path, json.dumps(record, indent=2) + '\n')
                for m in record['bridges']:
                    audit({'event': 'seeded', 'by': 'seeded from existing routes', 'bridge': m,
                           'before': [], 'after': list(FLOWS)})
    try:
        record = json.loads(path.read_text(encoding='utf-8'))
    except (OSError, ValueError) as e:
        raise Refuse(f'cannot read {path}: {e}; every bridge is closed until it is fixed')
    validate(record)
    return record


def allowed(record, machine, flow):
    if machine == 'local':
        return True
    return flow in record['bridges'].get(machine, {}).get('allow', [])


def change(machine, flows, by, operation='set'):
    if not NAME_RE.match(machine) or machine == 'local':
        raise Refuse(f'not a remote machine name: {machine}', 2)
    by = (by or f'{os.environ.get("USER", "unknown")} (cli)').strip()
    if not by or len(by) > 120 or any(ord(c) < 32 for c in by):
        raise Refuse('--by must be one short line of text', 2)
    load()
    with Lock():
        record = json.loads(record_path().read_text(encoding='utf-8'))
        validate(record)
        before = record['bridges'].get(machine, {}).get('allow', [])
        selected = set(flows)
        if operation == 'allow':
            selected |= set(before)
        elif operation == 'deny':
            selected = set(before) - selected
        after = [f for f in FLOWS if f in selected]
        record['bridges'][machine] = {'allow': after, 'seeded': False, 'updated': iso(time.time()), 'by': by}
        write_private(record_path(), json.dumps(record, indent=2) + '\n')
        entry = {'event': 'changed', 'by': by, 'bridge': machine, 'before': before, 'after': after}
        audit(entry)
    return entry


def parse_flows(items):
    flows = []
    for item in items:
        for f in item.split(','):
            if f and f != 'none':
                if f not in FLOWS:
                    raise Refuse(f'unknown flow {f}; flows: {", ".join(FLOWS)}', 2)
                flows.append(f)
    return flows


def take(argv, flag):
    if flag in argv:
        i = argv.index(flag)
        if i + 1 >= len(argv):
            raise Refuse(f'{flag} needs a value', 2)
        value = argv[i + 1]
        del argv[i:i + 2]
        return value
    return None


def file_request(machine, flow, what):
    with Lock():
        return publish_request(machine, flow, what)


def publish_request(machine, flow, what):
    approvals = home() / 'state' / 'approvals'
    gate = f'bridge:{flow}'
    if approvals.is_dir():
        for p in approvals.glob('ap-*.json'):
            try:
                rec = json.loads(p.read_text(encoding='utf-8'))
            except (OSError, ValueError):
                continue
            if rec.get('kind') == 'bridge' and rec.get('gate') == gate and rec.get('args', {}).get('machine') == machine:
                return rec['id'], False
    t = time.time()
    rid = f'ap-{time.strftime("%Y%m%dT%H%M%S", time.gmtime(t))}-{secrets.token_hex(3)}'
    args = {'machine': machine, 'flow': flow, 'what': what}
    rec = {'version': 1, 'id': rid, 'status': 'pending', 'kind': 'bridge', 'machine': machine,
           'home': str(home()), 'agent': 'primary', 'session': None, 'tool': 'bridge', 'args': args,
           'cwd': str(home()), 'gate': gate,
           'gate_description': f'{flow} across the bridge to {machine}',
           'key': hashlib.sha256(f'bridge\0{machine}\0{flow}'.encode()).hexdigest(), 'requested': iso(t)}
    write_private(approvals / f'{rid}.json', json.dumps(rec, indent=2) + '\n')
    return rid, True


def show_record():
    record = load()
    names = list(record['bridges'])
    names += [m for m in known_machines() if m not in names]
    out = []
    for m in names:
        b = record['bridges'].get(m)
        allow = (b or {}).get('allow', [])
        out.append({'machine': m, 'allow': allow, 'deny': [f for f in FLOWS if f not in allow],
                    'seeded': bool((b or {}).get('seeded')), 'updated': (b or {}).get('updated'),
                    'by': (b or {}).get('by'), 'configured': b is not None})
    return {'flows': list(FLOWS), 'bridges': out}


def main(argv):
    if not argv:
        sys.stderr.write(__doc__.split('Usage:')[1].split('show --json')[0])
        return 2
    cmd, rest = argv[0], list(argv[1:])
    try:
        if cmd == 'show':
            rec = show_record()
            if '--json' in rest:
                print(json.dumps(rec))
            else:
                for b in rec['bridges']:
                    state = 'seeded' if b['seeded'] else ('configured' if b['configured'] else 'not configured')
                    print(f'{b["machine"]}\tallow={",".join(b["allow"]) or "none"}\t{state}')
            return 0
        if cmd == 'check':
            if len(rest) != 2 or rest[1] not in FLOWS:
                raise Refuse(f'usage: fm-bridge.sh check <machine> <{"|".join(FLOWS)}>', 2)
            ok = allowed(load(), rest[0], rest[1])
            print('allow' if ok else f'deny: {rest[0]} does not allow {rest[1]}')
            return 0 if ok else 1
        if cmd in ('allow', 'deny'):
            by = take(rest, '--by')
            if len(rest) < 2:
                raise Refuse(f'usage: fm-bridge.sh {cmd} <machine> <flow>...', 2)
            machine, flows = rest[0], parse_flows(rest[1:])
            entry = change(machine, flows, by, cmd)
            print(f'{machine}: allow={",".join(entry["after"]) or "none"}')
            return 0
        if cmd == 'set':
            by, flows = take(rest, '--by'), take(rest, '--allow')
            if len(rest) != 1 or flows is None:
                raise Refuse('usage: fm-bridge.sh set <machine> --allow <flow,...|none>', 2)
            entry = change(rest[0], parse_flows([flows]), by)
            print(f'{rest[0]}: allow={",".join(entry["after"]) or "none"}')
            return 0
        if cmd == 'block':
            what = take(rest, '--what') or ''
            if len(rest) != 2 or rest[1] not in FLOWS:
                raise Refuse('usage: fm-bridge.sh block <machine> <flow> --what <text>', 2)
            machine, flow = rest
            what = what.replace('\n', ' ')[:500]
            rid, new = file_request(machine, flow, what)
            audit({'event': 'blocked', 'by': 'fm-on', 'bridge': machine, 'flow': flow, 'what': what,
                   'request': rid, 'new_request': new})
            print(rid)
            return 0
        if cmd == 'audit':
            limit = int(take(rest, '--limit') or 50)
            entries = []
            try:
                for line in log_path().read_text(encoding='utf-8').splitlines():
                    try:
                        entries.append(json.loads(line))
                    except ValueError:
                        pass
            except FileNotFoundError:
                pass
            entries = entries[-limit:][::-1]
            if '--json' in rest:
                print(json.dumps(entries))
            else:
                for e in entries:
                    print(f'{e.get("at")}\t{e.get("event")}\t{e.get("bridge")}\t{e.get("by")}\t'
                          f'{",".join(e.get("after", [])) if "after" in e else e.get("flow", "")}')
            return 0
        raise Refuse(f'unknown command: {cmd}', 2)
    except Refuse as e:
        sys.stderr.write(f'fm-bridge: {e}\n')
        return e.code


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
