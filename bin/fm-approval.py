#!/usr/bin/env python3
"""fm-approval.py - per-machine approval gates for risky agent tool calls.

bin/fm-approval.sh is the entry point; this file holds the whole contract.

A machine opts in by listing gates in its own policy file, ~/.agents/approvals.json
(FM_APPROVAL_POLICY overrides). The file is machine-local: dotfiles and Firstmate
home synchronization never overwrite it; only explicit policy management changes it.
An absent file or an omitted or empty "gates" list means nothing is gated.
An empty file is invalid JSON, not an empty policy.
Deck runs `gate` as a global pre_tool_use hook from ~/.agents/deck.hooks.json
(`install-hook` merges it there without touching other entries), so every Deck agent
on the machine passes through it, whatever its AGENTS.md says.

Policy file:
  {"version": 1,
   "machine": "work-mac",            optional; default FM_MACHINE, else the short hostname
   "home": "/abs/firstmate/home",    optional; home for agents Firstmate did not launch
   "grant_ttl_secs": 900,            optional; how long an approval stays usable (60..86400)
   "gates": [{"id": "slack-send", "tool": "run_command", "pattern": "<python regex>",
              "description": "Slack messages via agent-slack"}]}
A gate matches when `tool` equals the tool name (or matches it as a shell glob, so
"mcp__*slack*__*send*" covers MCP tools) and, when `pattern` is present, the regex is
found in the call: in args.command for run_command, else in the call's canonical JSON.
Built-in presets (`presets` lists them) are copied into the file by `enable`, so the
file always shows exactly what is gated.
Matching is not a sandbox: it examines command text or tool names and arguments,
not every way to reach a service; workarounds remain forbidden by the block message.
FM_DECK_HOOKS overrides the hooks file path for install-hook and status.

Usage:
  fm-approval.sh gate                          deck pre_tool_use hook; event JSON on stdin
  fm-approval.sh answer <request-id> --approve|--deny [--no-steer] [--json]
  fm-approval.sh list [--json]                 this home's pending requests
  fm-approval.sh show <request-id>
  fm-approval.sh presets
  fm-approval.sh policy [--json]               this machine's policy (or that none exists)
  fm-approval.sh enable <preset>... [--machine NAME] [--home DIR] [--by TEXT]
  fm-approval.sh disable <gate-id>... [--by TEXT]
  fm-approval.sh install-hook                  merge the gate into ~/.agents/deck.hooks.json
  fm-approval.sh status [--json]               hook installed?, gates, for checklists and UIs
  fm-approval.sh policy-show [--json]          policy, its sha, presets on/off, custom gates
  fm-approval.sh policy-save --expect <sha|none> [--by TEXT] [--json] < policy.json
  fm-approval.sh policy-audit [--limit N] [--json]   who changed the policy, what and when

gate. Reads Deck's event ({"tool_name", "args", "session_id", ...}). A call no gate
matches exits 0 at once. A matching call is allowed only by a grant the captain issued
for exactly this call: same agent, same tool, same arguments, same working directory
(the key is sha256 over tool, canonical args and effective cwd), not yet used and not
expired. Using a grant consumes it (one call, once). Otherwise the call is blocked with
exit 2 and stderr tells the model: blocked pending captain approval, the request id,
do not retry or work around it, wait to be told. A request is filed in the owning home
as state/approvals/<id>.json (mode 0600, atomic) with id, machine, home, agent,
session, tool, args, cwd, gate, key, requested; an identical call already pending
reuses that request instead of filing another. Requests never expire and nothing is
ever approved automatically. A policy that exists but cannot be read, parsed or
validated blocks every call (fail closed) with the reason, and so does a gated call with no home to file
into. Deck runs hooks with a 10 s timeout and by default fails open on a crash or timeout;
the installed entry sets "fail_closed": true, which a Deck with fail-closed hooks honors
by blocking instead (an older Deck ignores the key). The gate never waits: it files and
returns.

The owning home is FM_APPROVAL_HOME (the Deck hosts export it with FM_APPROVAL_AGENT:
the task id, or `primary` for the first mate), else the policy's "home". Agents with
no FM_APPROVAL_AGENT are identified as session:<deck session id>; they can be
approved, but nothing can steer them, so they are told to stop and wait.

answer. Run in the owning home (FM_HOME). --approve writes a one-time grant
(state/approvals/grants/<key>.<id>.json, expiring after grant_ttl_secs, default 900) and
steers the agent through bin/fm-send.sh: "approved: run request <id> now", with the
tool name and complete original arguments as canonical JSON, with the effective cwd
shown separately. Replay those arguments unchanged, including any relative cwd;
the displayed effective cwd is not a replacement for the original cwd argument.
--deny steers "denied". Either way the request leaves the pending set
(moved to state/approvals/answered/). A request already answered is refused (exit 3).
A failed steer leaves the answer recorded and exits 4 with the reason. --no-steer records
only; --json prints {id, status, agent, steer, steered} so a caller with its own route to
the agent (Fleet Town's command service) can deliver the exact steer text itself.
A second mate's agent id names its task in the parent home, so its own home cannot
steer it with fm-send: answer such a request with --no-steer and steer from the parent.

Every event (requested, repeated, approved, denied, used, expired-grant, steer-failed)
is appended to state/approvals.log as one JSON line {at, event, id, agent, machine, tool, key, ...}.

Policy management (enable, disable, policy-save) is one locked read-modify-write of
the policy file and appends one JSON line to ~/.agents/approvals-audit.log with
{at, by, before, after, added, removed, changed}: the policy's sha256 before and
after (or "none") and the sorted gate ids added, removed and edited.
The lock dir is ~/.agents/.approvals.lock, refused after ten seconds busy; both
lock and audit stay beside the policy when FM_APPROVAL_POLICY overrides its path.
`by` is --by TEXT or defaults to "<user>@<short-hostname> (cli)".
A save that leaves gates enabled installs the deck hook when it is missing,
audited as hook_installed: true; an empty-gate save does not remove the hook.
policy-save takes the policy object on stdin and shallow-merges its top-level keys
into the saved policy: supplied values replace saved values without merging nested
objects, while omitted keys such as home, machine and grant_ttl_secs keep their saved values.
It always replaces gates, defaulting gates to [] and version to 1 when omitted.
It refuses with exit 3 when the file's sha is no longer --expect (none = absent),
so a stale editor cannot overwrite a newer policy.
policy-save --json returns the appended audit entry.
policy-show --json prints {machine, path, present, sha, error, policy,
hook_installed, grant_ttl_secs, presets: [{id, description, enabled, gates}],
custom: [gate], gates: [gate]}.
The policy field preserves all stored fields, defaulting an omitted gates to [];
it is null when absent or invalid, with error describing an invalid policy.
A preset is enabled when every one of its gate ids is present, and custom gates
are those no preset names.
policy-audit --json returns an array newest first (empty when no audit exists),
defaulting to the last 50 entries; --limit N is clamped to 1..1000.
bin/fm-machine-approvals.sh's header owns named-machine local/SSH transport and
its attribution default.

Exit: 0 ok/allowed; 2 blocked (gate) or usage error; 1 other failure; 3 already
answered or unknown request, or stale policy-save; 4 answer recorded but steering failed.
FM_APPROVAL_NOW (epoch seconds) overrides the clock and FM_APPROVAL_SEND overrides
the fm-send.sh path, for tests.
"""
import fnmatch
import hashlib
import json
import os
import re
import secrets
import socket
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
ID_RE = re.compile(r'\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\Z')
REQ_RE = re.compile(r'\Aap-[0-9]{8}T[0-9]{6}-[0-9a-f]{6}\Z')
DEFAULT_TTL = 900
HOOK_COMMAND_RE = re.compile(r'fm-approval\.sh["\']?\s+gate\b')

PRESETS = {
    'slack-send': {
        'description': 'Slack messages sent, edited or deleted',
        'gates': [
            {'tool': 'run_command',
             'pattern': r'\bagent-slack\b[^\n]*\bmessage\s+(send|edit|delete|compose)\b'},
            {'tool': 'mcp__*slack*__*send*'},
        ],
    },
    'gh-pr-write': {
        'description': 'PR comments, reviews, merges and closes via gh',
        'gates': [{'tool': 'run_command',
                   'pattern': r'\bgh(-axi)?\b[^\n]*\bpr\s+(comment|review|merge|close)\b'}],
    },
    'gh-issue-comment': {
        'description': 'Issue comments via gh',
        'gates': [{'tool': 'run_command',
                   'pattern': r'\bgh(-axi)?\b[^\n]*\bissue\s+comment\b'}],
    },
    'whatsapp-send': {
        'description': 'WhatsApp messages via wacli',
        'gates': [{'tool': 'run_command', 'pattern': r'\bwacli\b[^\n]*\bsend\b'}],
    },
    'gmail-send': {
        'description': 'Gmail sends, replies and forwards via gog',
        'gates': [{'tool': 'run_command',
                   'pattern': r'\bgog\b[^\n]*\bgmail\b[^\n]*\b(send|reply|reply-all|replyall|forward|fwd)\b'}],
    },
    'git-push-protected': {
        'description': 'git push naming main or master',
        'gates': [{'tool': 'run_command',
                   'pattern': r'\bgit\b[^\n]*\bpush\b[^\n]*[\s:/+](main|master)\b'}],
    },
}


class Refuse(Exception):
    def __init__(self, message, code=1):
        super().__init__(message)
        self.code = code


def now():
    value = os.environ.get('FM_APPROVAL_NOW')
    return float(value) if value else time.time()


def iso(t):
    return time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime(t))


def policy_path():
    return Path(os.environ.get('FM_APPROVAL_POLICY') or Path.home() / '.agents' / 'approvals.json')


def hooks_path():
    return Path(os.environ.get('FM_DECK_HOOKS') or Path.home() / '.agents' / 'deck.hooks.json')


def load_policy():
    """None when the machine has no policy; raises Refuse when it has a bad one."""
    path = policy_path()
    try:
        raw = path.read_text(encoding='utf-8')
    except FileNotFoundError:
        return None
    except OSError as e:
        raise Refuse(f'cannot read {path}: {e.strerror}')
    try:
        policy = json.loads(raw)
    except ValueError as e:
        raise Refuse(f'{path} is not valid JSON: {e}')
    validate_policy(policy, path)
    policy.setdefault('gates', [])
    return policy


def validate_policy(policy, path):
    if not isinstance(policy, dict):
        raise Refuse(f'{path} must hold a JSON object')
    gates = policy.get('gates', [])
    if not isinstance(gates, list):
        raise Refuse(f'{path}: "gates" must be a list')
    seen = set()
    for i, gate in enumerate(gates):
        if not isinstance(gate, dict) or not isinstance(gate.get('tool'), str) or not gate['tool']:
            raise Refuse(f'{path}: gate {i} needs a "tool" name')
        if not isinstance(gate.get('id'), str) or not ID_RE.match(gate['id']):
            raise Refuse(f'{path}: gate {i} needs an "id"')
        if gate['id'] in seen:
            raise Refuse(f'{path}: gate id {gate["id"]} appears twice')
        seen.add(gate['id'])
        if 'pattern' in gate:
            try:
                re.compile(gate['pattern'])
            except (re.error, TypeError) as e:
                raise Refuse(f'{path}: gate {gate["id"]} has a bad pattern: {e}')
    ttl = policy.get('grant_ttl_secs', DEFAULT_TTL)
    if not isinstance(ttl, int) or isinstance(ttl, bool) or not 60 <= ttl <= 86400:
        raise Refuse(f'{path}: "grant_ttl_secs" must be an integer from 60 to 86400')
    for key in ('machine', 'home'):
        if key in policy and not isinstance(policy[key], str):
            raise Refuse(f'{path}: "{key}" must be a string')
    if policy.get('home') and not policy['home'].startswith('/'):
        raise Refuse(f'{path}: "home" must be an absolute path')


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(',', ':'), ensure_ascii=False)


def effective_cwd(tool, args):
    if tool == 'run_command' and isinstance(args, dict) and isinstance(args.get('cwd'), str) and args['cwd']:
        return os.path.normpath(os.path.join(os.getcwd(), os.path.expanduser(args['cwd'])))
    return os.getcwd()


def call_key(tool, args, cwd):
    return hashlib.sha256(f'{tool}\0{canonical(args)}\0{cwd}'.encode()).hexdigest()


def match_gate(policy, tool, args):
    if tool == 'run_command' and isinstance(args, dict) and isinstance(args.get('command'), str):
        subject = args['command']
    else:
        subject = canonical(args)
    for gate in policy.get('gates', []):
        if gate['tool'] != tool and not fnmatch.fnmatchcase(tool, gate['tool']):
            continue
        if 'pattern' in gate and not re.search(gate['pattern'], subject):
            continue
        return gate
    return None


def machine_name(policy):
    return (policy or {}).get('machine') or os.environ.get('FM_MACHINE') or socket.gethostname().split('.')[0]


def write_private(path, data):
    path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    tmp = path.with_name(f'.{path.name}.{secrets.token_hex(4)}')
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as f:
        f.write(data)
        f.flush()
        os.fsync(f.fileno())
    os.replace(tmp, path)


def audit(home, event, record, **extra):
    entry = {'at': iso(now()), 'event': event, 'id': record.get('id'), 'agent': record.get('agent'),
             'machine': record.get('machine'), 'tool': record.get('tool'), 'key': record.get('key')}
    entry.update(extra)
    log = Path(home) / 'state' / 'approvals.log'
    log.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    fd = os.open(log, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
    with os.fdopen(fd, 'a', encoding='utf-8') as f:
        f.write(canonical(entry) + '\n')


def approvals_dir(home):
    return Path(home) / 'state' / 'approvals'


def read_json(path):
    try:
        with open(path, encoding='utf-8') as f:
            return json.load(f)
    except (OSError, ValueError):
        return None


def pending(home):
    out = []
    d = approvals_dir(home)
    if not d.is_dir():
        return out
    for p in sorted(d.glob('ap-*.json')):
        rec = read_json(p)
        if isinstance(rec, dict) and rec.get('id') == p.stem:
            out.append(rec)
    return out


def consume_grant(home, agent, key):
    """Use one unexpired grant for (agent, key); returns its record or None."""
    grants = approvals_dir(home) / 'grants'
    if not grants.is_dir():
        return None
    used = grants / 'used'
    t = now()
    for p in sorted(grants.glob(f'{key}.*.json')):
        grant = read_json(p)
        if not isinstance(grant, dict) or grant.get('key') != key or grant.get('agent') != agent:
            continue
        used.mkdir(mode=0o700, exist_ok=True)
        if grant.get('expires_epoch', 0) <= t:
            try:
                os.rename(p, used / f'expired.{p.name}')
            except FileNotFoundError:
                continue
            audit(home, 'expired-grant', grant)
            continue
        try:
            # The rename is the claim: of two concurrent calls only one wins it.
            os.rename(p, used / p.name)
        except FileNotFoundError:
            continue
        return grant
    return None


def block(message):
    sys.stderr.write(message.rstrip() + '\n')
    return 2


def gate_main():
    raw = sys.stdin.read()
    try:
        policy = load_policy()
    except Refuse as e:
        return block(f'Blocked by this machine\'s approval policy, which cannot be read: {e}. '
                     'Every tool call is blocked until the captain fixes it. Do not work around this; '
                     'report it and wait.')
    if not policy or not policy.get('gates'):
        return 0
    try:
        event = json.loads(raw)
    except ValueError:
        return block('Blocked: the approval gate could not read this tool call. Report it and wait.')
    tool = event.get('tool_name') or ''
    args = event.get('args')
    gate = match_gate(policy, tool, args)
    if gate is None:
        return 0

    agent = os.environ.get('FM_APPROVAL_AGENT') or f'session:{event.get("session_id") or "unknown"}'
    home = os.environ.get('FM_APPROVAL_HOME') or policy.get('home') or ''
    if not home or not (Path(home) / 'state').is_dir():
        return block(f'Blocked: this machine requires the captain\'s approval for "{gate["id"]}" '
                     f'({gate.get("description") or tool}), and no Firstmate home is configured to '
                     'file the request in. Do not retry or work around it; tell your supervisor you '
                     'need the captain to approve this exact call, then stop and wait.')
    cwd = effective_cwd(tool, args)
    key = call_key(tool, args, cwd)
    machine = machine_name(policy)

    grant = consume_grant(home, agent, key)
    if grant is not None:
        audit(home, 'used', grant, request=grant.get('request'))
        return 0

    for rec in pending(home):
        if rec.get('key') == key and rec.get('agent') == agent:
            audit(home, 'repeated', rec)
            return block(blocked_message(rec, again=True))

    t = now()
    rid = f'ap-{time.strftime("%Y%m%dT%H%M%S", time.gmtime(t))}-{secrets.token_hex(3)}'
    rec = {
        'version': 1, 'id': rid, 'status': 'pending', 'machine': machine, 'home': str(home),
        'agent': agent, 'session': event.get('session_id'), 'tool': tool, 'args': args,
        'cwd': cwd, 'gate': gate['id'], 'gate_description': gate.get('description') or '',
        'key': key, 'requested': iso(t),
    }
    write_private(approvals_dir(home) / f'{rid}.json', json.dumps(rec, indent=2, ensure_ascii=False) + '\n')
    audit(home, 'requested', rec, gate=gate['id'])
    return block(blocked_message(rec))


def blocked_message(rec, again=False):
    lead = 'Still blocked' if again else 'Blocked'
    steer = ('You will receive "approved: run request {id} now" or "denied: request {id}" as a message. '
             if not rec['agent'].startswith('session:') else
             'Nothing can message you about it, so end your turn now and say you are waiting on '
             'captain approval for request {id}. ')
    return (f'{lead}: this machine requires the captain\'s approval for this call '
            f'("{rec["gate"]}"). Request {rec["id"]} is waiting for him in Fleet Town. '
            'Do not retry it, rephrase it, or reach the same effect another way. '
            + steer.format(id=rec['id']) +
            'When approved, run exactly the same call once (same command, arguments and working '
            'directory); anything different is blocked again. Meanwhile continue other work that '
            'does not depend on it, or wait.')


def call_text(rec):
    return f'{rec.get("tool")} {canonical(rec.get("args"))}'


def answer_main(argv):
    rid, verdict, steer, as_json = None, None, True, False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ('--approve', '--deny'):
            if verdict:
                raise Refuse('give exactly one of --approve or --deny', 2)
            verdict = a[2:]
        elif a == '--no-steer':
            steer = False
        elif a == '--json':
            as_json = True
        elif rid is None and not a.startswith('-'):
            rid = a
        else:
            raise Refuse(f'unknown argument: {a}', 2)
        i += 1
    if not rid or not verdict:
        raise Refuse('usage: fm-approval.sh answer <request-id> --approve|--deny [--no-steer] [--json]', 2)
    if not REQ_RE.match(rid):
        raise Refuse(f'not a request id: {rid}', 2)
    home = os.environ.get('FM_HOME')
    if not home:
        raise Refuse('answer needs FM_HOME (the home that owns the request)', 2)
    d = approvals_dir(home)
    path = d / f'{rid}.json'
    answered = d / 'answered'
    answered.mkdir(mode=0o700, parents=True, exist_ok=True)
    claimed = answered / f'{rid}.json'
    try:
        os.rename(path, claimed)  # one answer wins
    except FileNotFoundError:
        prior = read_json(claimed)
        if prior:
            raise Refuse(f'request {rid} was already answered: {prior.get("status")}', 3)
        raise Refuse(f'no pending request {rid} in {home}', 3)
    rec = read_json(claimed)
    if not isinstance(rec, dict):
        raise Refuse(f'request {rid} is unreadable', 1)
    t = now()
    rec['status'] = 'approved' if verdict == 'approve' else 'denied'
    rec['answered'] = iso(t)
    if verdict == 'approve':
        policy = None
        try:
            policy = load_policy()
        except Refuse:
            pass
        ttl = (policy or {}).get('grant_ttl_secs', DEFAULT_TTL)
        grant = {'version': 1, 'request': rid, 'agent': rec['agent'], 'key': rec['key'],
                 'tool': rec['tool'], 'issued': iso(t), 'expires': iso(t + ttl), 'expires_epoch': t + ttl}
        rec['grant_expires'] = grant['expires']
        write_private(d / 'grants' / f'{rec["key"]}.{rid}.json', canonical(grant) + '\n')
    write_private(claimed, json.dumps(rec, indent=2, ensure_ascii=False) + '\n')
    audit(home, rec['status'], rec)

    if verdict == 'approve':
        text = (f'approved: run request {rid} now. Run exactly this call once, unchanged '
                f'(effective working directory {rec["cwd"]}):\n{call_text(rec)}\n'
                f'The approval is for one use and expires at {rec["grant_expires"]}.')
    else:
        text = (f'denied: request {rid} ({call_text(rec)}). Do not run it or reach the same effect '
                'another way; carry on without it and say what you did instead.')
    if not steer or rec['agent'].startswith('session:'):
        if as_json:
            print(canonical({'id': rid, 'status': rec['status'], 'agent': rec['agent'], 'steer': text, 'steered': False}))
        else:
            print(f'{rec["status"]} {rid}')
        return 0
    send = os.environ.get('FM_APPROVAL_SEND') or str(SCRIPT_DIR / 'fm-send.sh')
    target = rec['agent']
    r = subprocess.run([send, target, text], env=dict(os.environ, FM_HOME=home),
                       stdin=subprocess.DEVNULL, capture_output=True, text=True)
    if r.returncode != 0:
        audit(home, 'steer-failed', rec, detail=(r.stderr or r.stdout).strip()[:500])
        sys.stderr.write(f'{rec["status"]} {rid}, but steering {target} failed: {(r.stderr or r.stdout).strip()}\n')
        return 4
    if as_json:
        print(canonical({'id': rid, 'status': rec['status'], 'agent': target, 'steer': text, 'steered': True}))
    else:
        print(f'{rec["status"]} {rid}; told {target}')
    return 0


def policy_sha():
    try:
        return hashlib.sha256(policy_path().read_bytes()).hexdigest()
    except FileNotFoundError:
        return 'none'


def audit_path():
    return policy_path().parent / 'approvals-audit.log'


def default_by():
    try:
        user = os.getlogin()
    except OSError:
        user = os.environ.get('USER') or 'unknown'
    return f'{user}@{socket.gethostname().split(".")[0]} (cli)'


class PolicyLock:
    def __init__(self):
        self.path = policy_path().parent / '.approvals.lock'

    def __enter__(self):
        self.path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        for _ in range(100):
            try:
                self.path.mkdir()
                return self
            except FileExistsError:
                time.sleep(0.1)
        raise Refuse(f'the policy lock {self.path} is busy; try again')

    def __exit__(self, *exc):
        try:
            self.path.rmdir()
        except OSError:
            pass


def commit_policy(change, by, expect=None):
    """Locked read-modify-write: change(current_policy_or_None) returns the new policy.
    Returns the audit entry. expect, when given, must equal the sha before the change."""
    by = (by or default_by()).strip()
    if not by or len(by) > 120 or any(ord(c) < 32 for c in by):
        raise Refuse('--by must be one short line of text', 2)
    with PolicyLock():
        before = policy_sha()
        if expect is not None and expect != before:
            raise Refuse(f'the policy changed since it was read (now {before}); reload it first', 3)
        current = load_policy()
        old = {g['id']: canonical(g) for g in (current or {}).get('gates', [])}
        policy = change(current)
        path = policy_path()
        validate_policy(policy, path)
        new = {g['id']: canonical(g) for g in policy.get('gates', [])}
        data = json.dumps(policy, indent=2) + '\n'
        entry = {'at': iso(now()), 'by': by, 'before': before,
                 'after': hashlib.sha256(data.encode('utf-8')).hexdigest(),
                 'added': sorted(set(new) - set(old)), 'removed': sorted(set(old) - set(new)),
                 'changed': sorted(i for i in set(new) & set(old) if new[i] != old[i])}
        backup = path.with_name(f'.{path.name}.rollback.{secrets.token_hex(4)}')
        replaced = False
        rollback_failed = False
        try:
            if before != 'none':
                write_private(backup, path.read_bytes().decode('utf-8'))
            fd = os.open(audit_path(), os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
            with os.fdopen(fd, 'a', encoding='utf-8') as f:
                if new and not hook_installed(read_json(hooks_path()) if hooks_path().exists() else None):
                    install_hook()
                    entry['hook_installed'] = True
                write_private(path, data)
                replaced = True
                f.write(canonical(entry) + '\n')
                f.flush()
                os.fsync(f.fileno())
        except (OSError, Refuse) as e:
            if replaced:
                try:
                    if before == 'none':
                        path.unlink()
                    else:
                        os.replace(backup, path)
                except OSError as rollback_error:
                    rollback_failed = True
                    raise Refuse(f'policy save failed ({e}); restoring {path} also failed: '
                                 f'{rollback_error}; recovery copy: {backup}') from e
            raise Refuse(f'policy save failed; policy unchanged: {e}') from e
        finally:
            if not rollback_failed:
                backup.unlink(missing_ok=True)
    return entry


def take_by(argv):
    """Pull --by TEXT out of argv; returns (by_or_None, remaining)."""
    out, by, i = [], None, 0
    while i < len(argv):
        if argv[i] == '--by':
            if i + 1 >= len(argv):
                raise Refuse('--by needs text', 2)
            by = argv[i + 1]
            i += 2
            continue
        out.append(argv[i])
        i += 1
    return by, out


def preset_gates(name):
    preset = PRESETS[name]
    return [dict(id=name if n == 0 else f'{name}-{n + 1}', description=preset['description'], **rule)
            for n, rule in enumerate(preset['gates'])]


def preset_ids():
    return {g['id'] for name in PRESETS for g in preset_gates(name)}


def enable_main(argv):
    by, argv = take_by(argv)
    names, machine, home = [], None, None
    i = 0
    while i < len(argv):
        if argv[i] in ('--machine', '--home') and i + 1 < len(argv):
            if argv[i] == '--machine':
                machine = argv[i + 1]
            else:
                home = argv[i + 1]
            i += 2
            continue
        names.append(argv[i])
        i += 1
    unknown = [n for n in names if n not in PRESETS]
    if unknown or not names:
        raise Refuse(f'unknown preset(s): {" ".join(unknown) or "(none given)"}; see `fm-approval.sh presets`', 2)

    def change(current):
        policy = current or {'version': 1, 'gates': []}
        policy.setdefault('gates', [])
        if machine:
            policy['machine'] = machine
        if home:
            policy['home'] = home
        ids = {g['id'] for g in policy['gates']}
        for name in names:
            for gate in preset_gates(name):
                if gate['id'] not in ids:
                    policy['gates'].append(gate)
                    ids.add(gate['id'])
        return policy
    commit_policy(change, by)
    print(f'enabled {" ".join(names)} in {policy_path()}')
    return 0


def disable_main(argv):
    by, argv = take_by(argv)
    if not policy_path().exists():
        print('no policy on this machine; nothing is gated')
        return 0
    removed = []

    def change(current):
        policy = current or {'version': 1, 'gates': []}
        gates = policy.get('gates', [])
        drop = set(argv)
        drop |= {g['id'] for g in gates if g['id'].rsplit('-', 1)[0] in drop and g['id'].rsplit('-', 1)[-1].isdigit()}
        policy['gates'] = [g for g in gates if g['id'] not in drop]
        removed.extend(g for g in gates if g['id'] in drop)
        return policy
    commit_policy(change, by)
    print(f'removed {len(removed)} gate(s) from {policy_path()}')
    return 0


def policy_record():
    hooks = read_json(hooks_path()) if hooks_path().exists() else None
    rec = {'machine': None, 'path': str(policy_path()), 'present': policy_path().exists(),
           'sha': policy_sha(), 'error': None, 'policy': None, 'hook_installed': hook_installed(hooks),
           'grant_ttl_secs': DEFAULT_TTL, 'presets': [], 'custom': [], 'gates': []}
    try:
        rec['policy'] = load_policy()
    except Refuse as e:
        rec['error'] = str(e)
    policy = rec['policy'] or {}
    gates = policy.get('gates', [])
    ids = {g['id'] for g in gates}
    rec['machine'] = machine_name(policy)
    rec['grant_ttl_secs'] = policy.get('grant_ttl_secs', DEFAULT_TTL)
    rec['gates'] = gates
    for name, preset in PRESETS.items():
        pg = preset_gates(name)
        rec['presets'].append({'id': name, 'description': preset['description'],
                               'enabled': all(g['id'] in ids for g in pg), 'gates': pg})
    known = preset_ids()
    rec['custom'] = [g for g in gates if g['id'] not in known]
    return rec


def policy_save_main(argv):
    by, argv = take_by(argv)
    expect, as_json = None, False
    i = 0
    while i < len(argv):
        if argv[i] == '--expect' and i + 1 < len(argv):
            expect = argv[i + 1]
            i += 2
        elif argv[i] == '--json':
            as_json = True
            i += 1
        else:
            raise Refuse(f'unknown argument: {argv[i]}', 2)
    if expect is None or not (expect == 'none' or re.fullmatch(r'[0-9a-f]{64}', expect)):
        raise Refuse('policy-save needs --expect <sha256|none> from policy-show', 2)
    raw = sys.stdin.read(256 * 1024 + 1)
    if len(raw) > 256 * 1024:
        raise Refuse('the policy is over 256 KiB', 2)
    try:
        incoming = json.loads(raw)
    except ValueError as e:
        raise Refuse(f'the policy is not valid JSON: {e}', 2)
    if not isinstance(incoming, dict):
        raise Refuse('the policy must be a JSON object', 2)
    incoming.setdefault('version', 1)
    incoming.setdefault('gates', [])
    # Keys the editor did not send (home, machine, grant_ttl_secs) keep their saved values.
    entry = commit_policy(lambda current: {**(current or {}), **incoming}, by, expect=expect)
    if as_json:
        print(canonical(entry))
    else:
        print(f'saved={entry["after"]} added={",".join(entry["added"]) or "-"} '
              f'removed={",".join(entry["removed"]) or "-"} changed={",".join(entry["changed"]) or "-"}')
    return 0


def policy_audit_main(argv):
    limit, as_json = 50, '--json' in argv
    if '--limit' in argv:
        try:
            limit = max(1, min(1000, int(argv[argv.index('--limit') + 1])))
        except (IndexError, ValueError):
            raise Refuse('--limit takes a number', 2)
    entries = []
    try:
        with open(audit_path(), encoding='utf-8') as f:
            for line in f:
                try:
                    entries.append(json.loads(line))
                except ValueError:
                    continue
    except FileNotFoundError:
        pass
    entries = entries[-limit:][::-1]
    if as_json:
        print(json.dumps(entries))
    else:
        for e in entries:
            print(f'{e.get("at")}\t{e.get("by")}\t+{",".join(e.get("added", [])) or "-"}'
                  f'\t-{",".join(e.get("removed", [])) or "-"}\t~{",".join(e.get("changed", [])) or "-"}')
    return 0


def hook_command():
    return f'bash {json.dumps(str(SCRIPT_DIR / "fm-approval.sh"))} gate'


def hook_installed(config):
    if not isinstance(config, dict) or not isinstance(config.get('hooks', {}), dict):
        return False
    hooks = config.get('hooks', {}).get('pre_tool_use', [])
    return isinstance(hooks, list) and any(
        isinstance(h, dict) and HOOK_COMMAND_RE.search(str(h.get('command', ''))) for h in hooks)


def install_hook_main():
    install_hook()
    print(f'installed the approval gate in {hooks_path()}')
    return 0


def install_hook():
    path = hooks_path()
    config = {'hooks': {}}
    if path.exists():
        config = read_json(path)
        if not isinstance(config, dict) or not isinstance(config.get('hooks', {}), dict):
            raise Refuse(f'{path} is not a deck hooks file; fix it by hand first')
        config.setdefault('hooks', {})
    entries = config['hooks'].setdefault('pre_tool_use', [])
    if not isinstance(entries, list):
        raise Refuse(f'{path}: hooks.pre_tool_use must be a list')
    # Replace an older copy (another checkout path) so exactly one gate runs.
    entries[:] = [h for h in entries if not (isinstance(h, dict) and HOOK_COMMAND_RE.search(str(h.get('command', ''))))]
    entries.insert(0, {'command': hook_command(), 'fail_closed': True})
    write_private(path, json.dumps(config, indent=2) + '\n')


def status_record():
    hooks = read_json(hooks_path()) if hooks_path().exists() else None
    try:
        policy = load_policy()
        error = None
    except Refuse as e:
        policy, error = None, str(e)
    return {'machine': machine_name(policy), 'hook_installed': hook_installed(hooks),
            'policy': str(policy_path()), 'policy_present': policy is not None or error is not None,
            'policy_error': error,
            'gates': [{'id': g['id'], 'tool': g['tool'], 'description': g.get('description', '')}
                      for g in (policy or {}).get('gates', [])]}


def main(argv):
    if not argv:
        sys.stderr.write(__doc__.split('Usage:')[1].split('gate.')[0])
        return 2
    cmd, rest = argv[0], argv[1:]
    if cmd == 'gate':
        try:
            return gate_main()
        except Exception as e:  # fail closed: a gated machine never runs a call the gate could not judge
            return block(f'Blocked: the approval gate failed ({type(e).__name__}: {e}). Report it and wait.')
    try:
        if cmd == 'answer':
            return answer_main(rest)
        if cmd == 'list':
            home = os.environ.get('FM_HOME') or ''
            recs = pending(home) if home else []
            if '--json' in rest:
                print(json.dumps(recs, indent=2))
            else:
                for r in recs:
                    print(f'{r["id"]}\t{r["agent"]}\t{r["gate"]}\t{call_text(r)}')
            return 0
        if cmd == 'show':
            home = os.environ.get('FM_HOME') or ''
            if not rest or not REQ_RE.match(rest[0]):
                raise Refuse('usage: fm-approval.sh show <request-id>', 2)
            for p in (approvals_dir(home) / f'{rest[0]}.json', approvals_dir(home) / 'answered' / f'{rest[0]}.json'):
                rec = read_json(p)
                if rec:
                    print(json.dumps(rec, indent=2, ensure_ascii=False))
                    return 0
            raise Refuse(f'no request {rest[0]}', 3)
        if cmd == 'presets':
            for name, p in PRESETS.items():
                print(f'{name}\t{p["description"]}')
            return 0
        if cmd == 'policy':
            policy = load_policy()
            if '--json' in rest:
                print(json.dumps(policy, indent=2))
            elif not policy:
                print(f'no policy at {policy_path()}; nothing is gated')
            else:
                print(f'{policy_path()} (machine {machine_name(policy)})')
                for g in policy.get('gates', []):
                    print(f'{g["id"]}\t{g["tool"]}\t{g.get("pattern", "(any call)")}')
            return 0
        if cmd == 'enable':
            return enable_main(rest)
        if cmd == 'disable':
            return disable_main(rest)
        if cmd == 'policy-show':
            rec = policy_record()
            if '--json' in rest:
                print(json.dumps(rec))
            else:
                print(f'{rec["path"]} sha={rec["sha"]} hook={"installed" if rec["hook_installed"] else "missing"}')
                for p in rec['presets']:
                    print(f'preset {p["id"]}={"on" if p["enabled"] else "off"}\t{p["description"]}')
                for g in rec['custom']:
                    print(f'custom {g["id"]}\t{g["tool"]}\t{g.get("pattern", "(any call)")}')
            return 0
        if cmd == 'policy-save':
            return policy_save_main(rest)
        if cmd == 'policy-audit':
            return policy_audit_main(rest)
        if cmd == 'install-hook':
            return install_hook_main()
        if cmd == 'status':
            rec = status_record()
            if '--json' in rest:
                print(json.dumps(rec))
            else:
                print(f'hook={"installed" if rec["hook_installed"] else "missing"} '
                      f'gates={",".join(g["id"] for g in rec["gates"]) or "none"}'
                      + (f' error={rec["policy_error"]}' if rec['policy_error'] else ''))
            return 0
        raise Refuse(f'unknown command: {cmd}', 2)
    except Refuse as e:
        sys.stderr.write(f'fm-approval: {e}\n')
        return e.code


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
