#!/usr/bin/env python3
"""fm_dream.py - the fleet's nightly pass over its own day ("dreaming").

bin/fm-dream.sh is the entry point (run, status, the launchd agent); this file
owns the steps, the run log and the summary bin/fm_report.py shows.

Modelled on Ziggy's dream (~/Projects/ziggy/dream), with no dependency in
either direction: the memory check, the secret scan and the push-with-rebase
loop are small enough to keep a copy of here.

Steps, in order; each has its own time budget, and one that fails or is skipped
is recorded and never stops the next:
  collect  reads the day (local deck sessions of the first mate, the supervisor,
           local mates and their workers; captain-direct; failed or cancelled
           no-mistakes runs; revive and restart results; the idle sweep; power)
           into a private digest under state/dream/ (0600, never committed),
           plus the fleet report for remote mates. Slow fm-* commands come from
           each run_command call joined to its result's duration_ms.
  skills   a deck agent in a fresh ~/dotfiles worktree improves skills/ from
           the digest. Same guards as Ziggy's reflection: only skills/, at most
           MAX_DIFF_LINES changed lines, no secret-like text; committed and
           pushed to main (rebased and retried if main moved).
  triage   a deck agent proposes concrete harness fixes from the digest; each
           is deduplicated against open tasks, open PRs and what dreaming
           raised in the last RAISED_DAYS days, scored by Jev ("worth fixing?")
           when the wake gate's key is configured, and the best MAX_RAISED kept.
  file     files the items triage kept in this run as queued backlog tasks and
           hands each to its owning mate (config/dream.json "owners"; the main home
           otherwise); an item already in raised.jsonl is never filed twice, and an
           owner or repository whose open work could not be read gets nothing.
           Dreaming never pushes to or opens PRs on harness repositories.

Before each step: skipped when the Mac has less than MIN_FREE_GB available, and
never started while Ziggy's own dream is running (it waits up to WAIT_ZIGGY).
Each step's budget (BUDGET) bounds every subprocess it starts, git included.

Files under <home>/state/dream/:
  runs/<date>.json   the run log (every step's status, seconds, details)
  latest.json        the summary bin/fm_report.py reads (schema fm-dream.v1):
                     {schema, date, started, finished, status, steps: {name:
                     {status, seconds, why?}}, skills: [{skill, what, why}],
                     skills_commit, raised: [{title, repo, mate, key, why}],
                     slow_commands: [{command, seconds, count}], counts: {...},
                     summary}
  raised.jsonl       one line per raised item (dedupe across nights)
  digest-<date>.md   the private digest the agents read

Configuration (all optional), <home>/config/dream.json:
  {"owners": {"<repo>": "<mate-id>|primary"}, "exclude_homes": ["<mate-id>"],
   "repos": {"<repo>": "<owner/name on GitHub>|null"}, "model": "<deck model>"}
  A repo is the backlog's project name (proxai's is cli-proxy-native).
Environment: FM_DREAM_DECK (deck binary), FM_DREAM_DOTFILES (~/dotfiles),
FM_DREAM_JEV (Jev helper command), FM_DREAM_MIN_FREE_GB, FM_DREAM_NO_MISTAKES_DB.
Tests only: FM_DREAM_NOW (epoch), FM_DREAM_SKIP_ZIGGY_WAIT=1, and FM_DREAM_TASKS,
FM_DREAM_HANDOFF, FM_DREAM_REPORT, FM_DREAM_ON replacing bin/fm-tasks-axi.sh,
bin/fm-backlog-handoff.sh, bin/fm-report.sh and bin/fm-on.sh.

    fm_dream.py run --home H [--only STEP ...] [--dry-run]
    fm_dream.py status --home H [--json]
"""
import argparse
import csv
import datetime as dt
import glob
import json
import os
import re
import sqlite3
import shlex
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
STEPS = ['collect', 'skills', 'triage', 'file']
BUDGET = {'collect': 300, 'skills': 2700, 'triage': 1200, 'file': 300}
MIN_FREE_GB = float(os.environ.get('FM_DREAM_MIN_FREE_GB', '3'))
WAIT_ZIGGY = 3600
MAX_DIFF_LINES = 600
MAX_SKILLS = 5  # asked of the agent; the changed-line cap is the enforced bound
MAX_RAISED = 3
RAISED_DAYS = 14
SLOW_MS = 20000
RETRY_SECS = int(os.environ.get('FM_DREAM_RETRY_SECS', '30'))  # pause before retrying a failed agent
DIGEST_CHARS = 250000
SESSION_CHARS = 14000
SECRET = re.compile(r'(sk-[A-Za-z0-9]{16,}|ghp_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|AKIA[0-9A-Z]{12,}|'
                    r'BEGIN [A-Z ]*PRIVATE KEY|xox[abp]-[A-Za-z0-9-]{10,})')
DEFAULT_MODEL = 'codex/gpt-6.1-sol'
DEFAULT_REPOS = {'firstmate': 'bastotec/firstmate', 'deck': 'bastotec/deck', 'cli-proxy-native': 'bastotec/proxai',
                 'firstmate-ui': 'bastotec/firstmate-ui', 'no-mistakes': 'bastotec/no-mistakes', 'phone-harness': None}


def now():
    return float(os.environ.get('FM_DREAM_NOW') or time.time())


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def parse_iso(text):
    try:
        return dt.datetime.fromisoformat(str(text).replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None


def read_json(path, default=None):
    try:
        with open(path, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def write_json(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name('.' + path.name + '.tmp')
    with open(tmp, 'w', encoding='utf-8') as fh:
        json.dump(data, fh, indent=1, ensure_ascii=False)
    os.replace(tmp, path)


def write_private(path, text):
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, 'w', encoding='utf-8') as fh:
        fh.write(text)


class ConfigError(Exception):
    pass


def load_config(path):
    """config/dream.json, {} when absent. An unreadable or malformed file stops the
    run: silently dropping it would also drop its exclusions."""
    try:
        with open(path, encoding='utf-8') as fh:
            doc = json.load(fh)
    except FileNotFoundError:
        return {}
    except (OSError, ValueError) as e:
        raise ConfigError('%s is unreadable (%s); fix it or remove it' % (path, e))
    if not isinstance(doc, dict):
        raise ConfigError('%s must hold a JSON object' % path)
    names = doc.get('exclude_homes', [])
    if not isinstance(names, list) or not all(isinstance(n, str) and n.strip() for n in names):
        raise ConfigError('%s: exclude_homes must be a list of mate ids' % path)
    owners, repos = doc.get('owners', {}), doc.get('repos', {})
    if not isinstance(owners, dict) or not all(isinstance(v, str) and v.strip() for v in owners.values()):
        raise ConfigError('%s: owners must map repositories to mate ids' % path)
    if not isinstance(repos, dict) or not all(v is None or isinstance(v, str) for v in repos.values()):
        raise ConfigError('%s: repos must map repositories to owner/name or null' % path)
    if not isinstance(doc.get('model', ''), str):
        raise ConfigError('%s: model must be a string' % path)
    return doc


class Ctx:
    def __init__(self, home, dry_run):
        self.home = Path(home)
        self.state = self.home / 'state'
        self.dir = self.state / 'dream'
        (self.dir / 'runs').mkdir(parents=True, exist_ok=True)
        os.chmod(self.dir, 0o700)
        self.dry_run = dry_run
        self.now = now()
        self.since = self.now - 86400
        self.day = time.strftime('%Y-%m-%d', time.localtime(self.now))
        self.config = load_config(self.home / 'config' / 'dream.json')
        self.digest = self.dir / ('digest-%s.md' % self.day)
        self.facts = {}
        self.excluded = set(self.config.get('exclude_homes') or [])
        self.deadline = None

    def left(self):
        """Seconds left in the running step's budget; TimeoutExpired once it is spent."""
        if self.deadline is None:
            return 600
        remaining = self.deadline - time.time()
        if remaining <= 0:
            raise subprocess.TimeoutExpired('step', 0)
        return remaining

    def run(self, argv, timeout=None, **kw):
        """subprocess.run bounded by the step's remaining budget (and timeout, if
        smaller), in its own process group so a timeout also ends its children."""
        limit = self.left() if timeout is None else min(timeout, self.left())
        kw.setdefault('capture_output', 'stdout' not in kw)
        kw.setdefault('text', True)
        proc = subprocess.Popen(argv, start_new_session=True,
                                stdin=subprocess.PIPE if 'input' in kw else None,
                                stdout=kw.pop('stdout', subprocess.PIPE if kw.pop('capture_output') else None),
                                stderr=kw.pop('stderr', subprocess.PIPE),
                                **{k: v for k, v in kw.items() if k in ('cwd', 'env', 'text')})
        try:
            out, err = proc.communicate(kw.get('input'), timeout=limit)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, 9)
            except OSError:
                pass
            proc.communicate()
            raise
        return subprocess.CompletedProcess(argv, proc.returncode, out, err)

    def model(self):
        if self.config.get('model'):
            return self.config['model']
        try:
            return (self.state / 'primary-chat' / 'model').read_text().strip() or DEFAULT_MODEL
        except OSError:
            return DEFAULT_MODEL


# --- the Mac ----------------------------------------------------------------

def available_gb():
    """Free plus reclaimable memory from vm_stat, or None off macOS."""
    try:
        out = subprocess.run(['vm_stat'], capture_output=True, text=True, timeout=5).stdout
    except (OSError, subprocess.TimeoutExpired):
        return None
    page, pages = 16384, 0
    for line in out.splitlines():
        if 'page size of' in line:
            page = int(line.split('page size of')[1].split()[0])
        name = line.split(':')[0]
        if name in ('Pages free', 'Pages inactive', 'Pages speculative', 'Pages purgeable'):
            pages += int(line.split(':')[1].strip().rstrip('.'))
    return pages * page / 1e9 if pages else None


def ziggy_dreaming():
    if os.environ.get('FM_DREAM_SKIP_ZIGGY_WAIT') == '1':
        return False
    r = subprocess.run(['pgrep', '-f', 'ziggy/dream/dream.py'], capture_output=True)
    return r.returncode == 0


def room_for(step):
    """None when the step may start, else why not."""
    waited = 0
    while ziggy_dreaming():
        if waited >= WAIT_ZIGGY:
            return "Ziggy's dream still running after %d min" % (WAIT_ZIGGY // 60)
        time.sleep(30)
        waited += 30
    free = available_gb()
    if free is not None and free < MIN_FREE_GB:
        return 'only %.1f GB free on the Mac' % free
    return None


# --- collect ----------------------------------------------------------------

def registry(home):
    """[(id, home path or None, host or None)], read by fm_report.registry, which
    uses the registry's own parser (bin/fm-secondmate-registry-lib.sh)."""
    sys.path.insert(0, str(SCRIPT_DIR))
    import fm_report
    fm_report.REGISTRY_ERRORS.clear()
    rows = [(mid, row.get('home') or None, row.get('host') or None) for mid, row in fm_report.registry(home).items()]
    REGISTRY_ERRORS[:] = list(fm_report.REGISTRY_ERRORS)
    return rows


REGISTRY_ERRORS = []  # what the last registry() read could not parse


def deck_state():
    """Where deck keeps sessions, resolved as the worker and captain-lane drivers do."""
    if os.environ.get('DECK_STATE'):
        return Path(os.environ['DECK_STATE'])
    return Path(os.environ.get('XDG_STATE_HOME') or os.path.expanduser('~/.local/state')) / 'deck'


def text_of(content):
    if isinstance(content, str):
        return content
    out = []
    for c in content or []:
        if isinstance(c, dict) and c.get('type') == 'text':
            out.append(c.get('text', ''))
    return ' '.join(out)


def session_lines(path, since, slow, label, hide=lambda line: False):
    """Digest lines for one deck session file, newer than since; slow fm-* calls
    are appended to slow as (command, seconds)."""
    doc = read_json(path)
    if not isinstance(doc, dict):
        return []
    lines, calls = [], {}
    for msg in doc.get('messages') or []:
        at = parse_iso(msg.get('at')) or 0
        content = msg.get('content')
        for c in content if isinstance(content, list) else []:
            if isinstance(c, dict) and c.get('type') == 'toolcall':
                fn = c.get('function') or {}
                cmd = (fn.get('arguments') or {}).get('command') if fn.get('name') == 'run_command' else None
                calls[c.get('id')] = cmd
        if at < since:
            continue
        role = msg.get('role')
        if role == 'user':
            t = ' '.join(text_of(content).split())
            if t and not hide(t):
                who = 'steer' if t.startswith('[') else 'user'
                lines.append('%s: %s' % (who, t[:500]))
            for c in content if isinstance(content, list) else []:
                if not (isinstance(c, dict) and c.get('type') == 'toolresult'):
                    continue
                val = next((x.get('value') for x in c.get('content') or []
                            if isinstance(x, dict) and x.get('type') == 'json'), None)
                if isinstance(val, dict) and (val.get('exit_code') not in (0, None) or val.get('timed_out')):
                    full = ' '.join(str(val.get('stderr') or val.get('stdout') or '').split())
                    cmd = calls.get(c.get('call')) or c.get('name') or ''
                    if not hide(full) and not hide(str(cmd)):
                        lines.append('tool error (%s): %s' % (cmd, full[-240:]))
            for t in msg.get('tools') or []:
                ms = t.get('duration_ms') or 0
                cmd = calls.get(t.get('id')) or ''
                if ms >= SLOW_MS and re.search(r'(^|[ /])(bin/)?fm[-_][A-Za-z0-9_.-]+', cmd) and not hide(cmd):
                    slow.append((cmd, ms / 1000.0))
                    lines.append('slow command (%ds): %s' % (ms // 1000, cmd[:200]))
        elif role == 'assistant':
            t = ' '.join(text_of(content).split())
            if t and not hide(t):
                lines.append('agent: ' + t[:350])
    lines = [l for l in lines if not hide(l)]
    if not lines:
        return []
    body = '\n'.join(lines)
    if len(body) > SESSION_CHARS:
        body = body[:SESSION_CHARS // 3] + '\n[...]\n' + body[-2 * SESSION_CHARS // 3:]
    return ['## %s (%s)' % (label, os.path.basename(path)), body, '']


WORKER_BRIEF = 'FIRSTMATE_OP: v1 launch-brief'


def first_user_text(path, chars=20000):
    doc = read_json(path)
    for msg in (doc or {}).get('messages') or []:
        if msg.get('role') == 'user':
            return text_of(msg.get('content'))[:chars]
    return ''


def local_sessions(ctx):
    """[(label, session file)] touched in the window: the first mate's and the
    supervisor's, every local mate's (<home>/state/<id>.deck-session, or
    .supervisor-session for a split mate's supervisor), and every worker's, which
    no file binds, recognised by the launch brief its conversation opens with.
    Excluded homes stay out: their bindings by name, and any worker whose brief
    names one of them or its home."""
    found, seen, skip = [], set(), set()
    sessions = deck_state() / 'sessions'
    reg = registry(ctx.home)
    ours = [str(ctx.home)] + [h for mid, h, host in reg if h and not host and mid not in ctx.excluded]
    private = set(ctx.excluded) | {h for mid, h, host in reg if mid in ctx.excluded and h}

    def add(label, path):
        if path.is_file() and path not in seen and path not in skip and path.stat().st_mtime >= ctx.since:
            seen.add(path)
            found.append((label, path))

    for chat, label in (('primary-chat', 'first mate, captain thread'), ('supervisor-chat', 'supervisor')):
        try:
            add(label, sessions / ((ctx.state / chat / 'session').read_text().strip() + '.json'))
        except OSError:
            pass
    homes = [('main', ctx.home)] + [(mid, Path(h)) for mid, h, host in reg
                                     if h and not host and mid not in ctx.excluded]
    for mid, h in homes:
        for f in sorted(glob.glob(str(h / 'state' / '*.deck-session')) + glob.glob(str(h / 'state' / '*.supervisor-session'))):
            name, kind = Path(f).name.rsplit('.', 1)
            try:
                sid = Path(f).read_text().split()[0]
            except (OSError, IndexError):
                continue
            if name in ctx.excluded:
                skip.add(sessions / (sid + '.json'))
                continue
            add('%s / %s%s' % (mid, name, ' (supervisor)' if kind == 'supervisor-session' else ''), sessions / (sid + '.json'))
    bound = seen | skip
    for f in sorted(glob.glob(str(sessions / '*.json'))):
        path = Path(f)
        if path in bound or path.stat().st_mtime < ctx.since:
            continue
        brief = first_user_text(path)
        # A worker's brief names its inbox, <home>/state/<task>.inbox: only workers
        # of this home or an included local home count, never another FM_HOME's.
        mine = any(h.rstrip('/') + '/state/' in brief for h in ours)
        if WORKER_BRIEF in brief and mine and not any(word in brief for word in private):
            m = re.search(r'task(?: id)?[:=] *([A-Za-z0-9._-]+)', brief)
            add('worker %s' % (m.group(1) if m else path.stem), path)
    return found


def tail_since(path, since, limit=80, hide=lambda line: False):
    """Lines of a log whose leading epoch or ISO stamp is newer than since (or the
    file is), at most the last limit."""
    try:
        if os.path.getmtime(path) < since:
            return []
        lines = Path(path).read_text(encoding='utf-8', errors='replace').splitlines()
    except OSError:
        return []
    keep = []
    for line in lines:
        m = re.match(r'^\[?(\d{10})|^\[?(\d{4}-\d\d-\d\dT[\d:.]+Z?)', line)
        if m:
            stamp = int(m.group(1)) if m.group(1) else (parse_iso(m.group(2)) or 0)
            if stamp < since:
                continue
        if not hide(line):
            keep.append(line[:300])
    return keep[-limit:]


def no_mistakes_runs(since, fleet_paths, harness, private_paths=()):
    """Failed or cancelled no-mistakes runs that ended (last changed) in the window,
    only for repositories that are the fleet's own: inside the main home or an
    included local home, or a harness repository by name. Anything else (an
    excluded mate's project among them) never reaches the digest."""
    db = Path(os.environ.get('FM_DREAM_NO_MISTAKES_DB') or os.path.expanduser('~/.no-mistakes/state.sqlite'))
    if not db.is_file():
        return [], None
    try:
        con = sqlite3.connect('file:%s?mode=ro' % db, uri=True, timeout=5)
        cols = {r[1] for r in con.execute('PRAGMA table_info(runs)')}
        repo_cols = {r[1] for r in con.execute('PRAGMA table_info(repos)')}
        when = 'updated_at' if 'updated_at' in cols else 'created_at'
        pick = [c for c in ('id', 'status', 'branch', 'error', 'pr_url', 'worktree_dir') if c in cols]
        path = ', repos.working_path' if 'working_path' in repo_cols and 'repo_id' in cols else ", ''"
        join = ' LEFT JOIN repos ON repos.id = runs.repo_id' if path != ", ''" else ''
        rows = con.execute('SELECT %s, runs.%s%s FROM runs%s WHERE runs.status IN (\'failed\', \'cancelled\') '
                           'ORDER BY runs.%s DESC LIMIT 400' % (', '.join('runs.' + c for c in pick), when, path,
                                                                 join, when)).fetchall()
        con.close()
    except sqlite3.Error as e:
        return [], 'no-mistakes state unreadable (%s)' % e
    out = []
    for row in rows:
        r = dict(zip(pick + ['when', 'repo_path'], row))
        stamp = r['when'] / (1000 if r['when'] and r['when'] > 1e12 else 1) if isinstance(r['when'], (int, float)) \
            else parse_iso(r['when']) or 0
        repo = str(r.get('repo_path') or '')
        places = [repo, str(r.get('worktree_dir') or '')]
        if any(place == p or place.startswith(p.rstrip('/') + '/') for p in private_paths for place in places if p):
            continue
        ours = any(repo == p or repo.startswith(p.rstrip('/') + '/') for p in fleet_paths) \
            or os.path.basename(repo) in harness
        if stamp >= since and ours and not any(n in json.dumps(r) for n in private_names()):
            out.append(r)
    return out, None


def tool(name, env_var):
    return os.environ.get(env_var) or str(SCRIPT_DIR / name)


def fleet_report(ctx):
    try:
        # --days 2: a 04:15 run's last 24 hours start on the previous calendar day
        r = ctx.run([tool('fm-report.sh', 'FM_DREAM_REPORT'), 'fleet', '--days', '2', '--json'], timeout=120,
                    env=dict(os.environ, FM_HOME=str(ctx.home)))
        return json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


PRIVATE_NAMES = []


def private_names():
    return PRIVATE_NAMES


def mentions_excluded(ctx, line):
    return any(name in line for name in ctx.excluded | {m.replace('-', ' ') for m in ctx.excluded})


def step_collect(ctx):
    parts, slow = ['# Fleet day digest, %s (since %s)' % (ctx.day, iso(ctx.since)), ''], []
    sessions = local_sessions(ctx)
    for label, path in sessions:
        parts += session_lines(path, ctx.since, slow, label, lambda line: mentions_excluded(ctx, line))
    captain = tail_since(ctx.state / 'captain-direct.log', ctx.since, hide=lambda l: mentions_excluded(ctx, l))
    if captain:
        parts += ['## Captain-direct messages', *captain, '']
    fleet_paths = [str(ctx.home)] + [h for mid, h, host in registry(ctx.home)
                                     if h and not host and mid not in ctx.excluded]
    harness = set(ctx.config.get('repos') or DEFAULT_REPOS) | {'proxai'}
    PRIVATE_NAMES[:] = sorted(ctx.excluded | {m.replace('-', ' ') for m in ctx.excluded})
    private_paths = [h for mid, h, host in registry(ctx.home) if mid in ctx.excluded and h]
    nm, nm_err = no_mistakes_runs(ctx.since, fleet_paths, harness, private_paths)
    if nm:
        parts += ['## Failed or cancelled no-mistakes runs (%d; newest 40)' % len(nm)] + [
            '- %s %s %s: %s' % (r.get('status'), r.get('branch') or '', r.get('pr_url') or '',
                                ' '.join(str(r.get('error') or '').split())[:300]) for r in nm[:40]] + ['']
    revives = tail_since(ctx.state / 'secondmate-revive.log', ctx.since, hide=lambda l: mentions_excluded(ctx, l))
    if revives:
        parts += ['## Revives', *revives, '']
    restarts = []
    for f in sorted(glob.glob(str(ctx.state / 'procevent-inbox' / '*re[ls][oet]a*.result'))):
        if os.path.getmtime(f) >= ctx.since:
            body = Path(f).read_text(encoding='utf-8', errors='replace')
            restarts.append('- %s: %s' % (Path(f).name, ' | '.join(
                l.strip() for l in body.splitlines() if re.match(r'\s*(status|restarted|unreached|failed)', l)
                and not mentions_excluded(ctx, l))[:400]))
    if restarts:
        parts += ['## Restarts and reloads', *restarts, '']
    sweep = tail_since(ctx.state / 'idle-sweep.log', ctx.since, hide=lambda l: mentions_excluded(ctx, l))
    if sweep:
        parts += ['## Idle sweep', *sweep, '']
    rep = fleet_report(ctx)
    if rep:
        parts += ['## Fleet report', rep.get('summary') or '']
        parts += ['- waiting: %s (on %s, %s)' % (w.get('what'), w.get('on'), w.get('mate'))
                  for w in rep.get('waiting', [])
                  if w.get('mate') not in ctx.excluded and not mentions_excluded(ctx, json.dumps(w))]
        parts += ['- gap: ' + g for g in rep.get('gaps', []) if not mentions_excluded(ctx, g)]
        parts += ['- crew %s: %s on %s (%s)' % (c.get('status'), c.get('agent'), c.get('task'), c.get('mate'))
                  for c in rep.get('crew', []) if c.get('status') in ('failed', 'blocked', 'stopped', 'needs-decision')
                  and c.get('mate') not in ctx.excluded and not mentions_excluded(ctx, json.dumps(c))][:30]
        parts += ['- shipped: %s (%s)' % (x.get('title'), x.get('mate')) for x in rep.get('shipped', [])
                  if x.get('mate') not in ctx.excluded and not mentions_excluded(ctx, json.dumps(x))][:30]
        parts += ['- power %s: %s%% left' % (p.get('provider'), p.get('pct_left')) for p in rep.get('power') or []]
        parts.append('')
    text = '\n'.join(parts)
    if len(text) > DIGEST_CHARS:
        text = text[:DIGEST_CHARS] + '\n[digest truncated]\n'
    write_private(ctx.digest, text)
    agg = {}
    for cmd, sec in slow:
        key = re.search(r'(bin/)?fm[-_][A-Za-z0-9_.-]+', cmd).group(0)
        a = agg.setdefault(key, [0, 0.0])
        a[0] += 1
        a[1] = max(a[1], sec)
    ctx.facts['slow_commands'] = [{'command': k, 'count': v[0], 'seconds': round(v[1])}
                                  for k, v in sorted(agg.items(), key=lambda kv: -kv[1][1])][:8]
    ctx.facts['counts'] = {'sessions': len(sessions), 'captain_messages': len(captain),
                           'no_mistakes_failed': len(nm), 'revives': len(revives), 'restarts': len(restarts),
                           'idle_sweep': len(sweep), 'digest_chars': len(text)}
    unread = ['%s: %s' % (m.get('id'), m.get('freshness')) for m in (rep or {}).get('mates', [])
              if m.get('id') not in ctx.excluded and m.get('freshness') not in ('fresh', 'local', 'remote', 'cached', None)]
    if (rep or {}).get('power_error'):
        unread.append('power: %s' % rep['power_error'])
    gaps = ([nm_err] if nm_err else []) + (['fleet report unreadable'] if rep is None else []) + unread[:3]
    result = {'status': 'partial' if gaps else 'done', **ctx.facts['counts']}
    if gaps:
        result['why'] = '; '.join(gaps)
    return result


# --- skills -----------------------------------------------------------------

SKILLS_PROMPT = """You are the firstmate fleet's nightly reflection. The fleet is a first mate (deck \
chat) supervising second mates and short-lived workers for Bruno (the captain). Its agents load the \
skills in {skills} (one folder per skill, SKILL.md with `name:` and `description:` frontmatter).

Read the digest of the fleet's last 24 hours: {digest}
Skills commits already made in the last 24 hours (by Ziggy's own nightly run or anyone else) - do \
not redo them:
{recent}

Look for, in order of value:
1. The captain correcting an agent where a skill would have told it the right way.
2. A procedure agents did by hand several times that a skill could make one step.
3. A failure (tool errors, failed no-mistakes runs, slow or retried commands) caused by a skill
   being wrong, stale or missing a trap.

Make small, targeted edits: fix or extend the relevant SKILL.md, or add a skill when nothing covers
it. Keep each skill's style; be concrete (commands, paths, the trap and its fix). Do not touch
anything outside {skills}. No secrets, keys, account numbers or private personal details. At most
{max_skills} skills changed. If nothing warrants a change, change nothing.

Finally write {summary} as JSON: {{"changes": [{{"skill": "name", "what": "one plain sentence",
"why": "what happened today that called for it"}}]}} - an empty list when you changed nothing."""


def git(ctx, *args, cwd, check=True, timeout=None):
    """git inside the step's budget; output, or CalledProcessError when check."""
    r = ctx.run(['git', *args], cwd=cwd, timeout=timeout)
    if check and r.returncode:
        raise subprocess.CalledProcessError(r.returncode, ['git', *args], r.stdout, r.stderr)
    return r.stdout


def deck_bin():
    return os.environ.get('FM_DREAM_DECK') or os.path.expanduser('~/.local/bin/deck')


def run_agent(ctx, prompt, cwd, log, output):
    """Run one ephemeral deck agent inside the step's budget; None when it
    finished, else why not. A failed attempt (a gateway blip) is tried once more,
    judged only by its own events, while the log keeps both for diagnosis."""
    env = dict(os.environ)
    env.setdefault('PROXAI_API_KEY_FILE', os.path.expanduser('~/.config/proxai/client.key'))
    env['DECK_SKILL_HINTS'] = '0'
    why = None
    for attempt in range(2):
        try:
            Path(output).unlink()  # only the attempt that succeeds may leave its output
        except FileNotFoundError:
            pass
        offset = os.path.getsize(log) if attempt and os.path.exists(log) else 0
        with open(log, 'a' if attempt else 'w') as fh:
            rc = ctx.run([deck_bin(), 'run', '-', '--ephemeral', '--model', ctx.model(),
                          '--deadline-secs', str(max(30, int(ctx.left()) - 60)), '--max-turns', '120'],
                         input=prompt, cwd=cwd, env=env, stdout=fh, stderr=subprocess.STDOUT).returncode
        with open(log, errors='replace') as fh:
            fh.seek(offset)
            failed = [json.loads(l).get('error') for l in fh if l.startswith('{') and '"run_failed"' in l]
        if rc == 0 and not failed:
            return None
        why = 'agent failed: %s' % ((failed[-1] if failed else None) or 'deck exited %d' % rc)
        if ctx.left() < 120:
            break
        time.sleep(RETRY_SECS)
    return why


def quiet(ctx):
    """A missing digest, or one with nothing past its title, is a quiet day."""
    try:
        return '\n## ' not in ctx.digest.read_text(encoding='utf-8')
    except OSError:
        return True


def staged_secret(ctx, tree, paths):
    """The first staged file whose bytes match SECRET, binary files included."""
    for path in paths:
        r = ctx.run(['git', 'show', ':' + path], cwd=tree, text=False)
        if r.returncode == 0 and SECRET.search(r.stdout.decode('latin-1')):
            return path
    return None


def step_skills(ctx):
    if quiet(ctx):
        return {'status': 'quiet day'}
    if ctx.dry_run:
        return {'status': 'dry-run', 'would': 'run the skills agent on the digest in a dotfiles worktree'}
    dotfiles = os.environ.get('FM_DREAM_DOTFILES') or os.path.expanduser('~/dotfiles')
    git(ctx, 'fetch', '-q', 'origin', cwd=dotfiles, timeout=120)
    recent = git(ctx, 'log', '--since=24 hours ago', '--format=- %h %s', 'origin/main', '--', 'skills', cwd=dotfiles).strip()
    branch = 'fleet-dream/%s-%s' % (ctx.day, time.strftime('%H%M%S'))
    tree = ctx.dir / ('dotfiles-' + branch.replace('/', '-'))
    git(ctx, 'worktree', 'add', '-q', '-b', branch, str(tree), 'origin/main', cwd=dotfiles)
    try:
        base = git(ctx, 'rev-parse', 'HEAD', cwd=tree).strip()
        summary = ctx.dir / ('skills-%s.json' % ctx.day)
        if summary.exists():
            summary.unlink()
        prompt = SKILLS_PROMPT.format(skills=tree / 'skills', digest=ctx.digest, recent=recent or '- none',
                                      max_skills=MAX_SKILLS, summary=summary)
        failed = run_agent(ctx, prompt, tree, ctx.dir / ('skills-%s.log' % ctx.day), summary)
        if failed:
            return {'status': 'failed', 'why': failed}
        # Everything the agent left, committed or not, is judged as one change
        # against the starting commit, so a checkpoint commit cannot slip past.
        git(ctx, 'add', '-A', cwd=tree)
        git(ctx, 'reset', '-q', '--soft', base, cwd=tree)
        changed = git(ctx, 'diff', '--cached', '--name-only', '--no-renames', base, cwd=tree).split('\n')
        changed = [p for p in changed if p]
        doc = read_json(summary)
        if not isinstance(doc, dict) or not isinstance(doc.get('changes'), list):
            return {'status': 'failed', 'why': 'the skills agent wrote no valid %s' % summary.name}
        if not changed:
            return {'status': 'no changes'}
        outside = [p for p in changed if not p.startswith('skills/')]
        if outside:
            return {'status': 'rejected', 'why': 'touched %s' % outside[:3]}
        diff = git(ctx, 'diff', '--cached', base, cwd=tree)
        lines = sum(1 for l in diff.splitlines() if l[:1] in '+-' and l[:3] not in ('+++', '---'))
        if lines > MAX_DIFF_LINES:
            return {'status': 'rejected', 'why': '%d changed lines (cap %d)' % (lines, MAX_DIFF_LINES)}
        if not doc['changes']:
            return {'status': 'rejected', 'why': 'the skills agent changed skills but listed none in its summary'}
        changes = doc['changes']
        title = 'Updates skills from the fleet\'s %s sessions (fleet dreaming)' % ctx.day
        body = '\n'.join('- %s: %s (%s)' % (c.get('skill'), c.get('what'), c.get('why')) for c in changes)
        message = title + '\n\n' + body + '\n\nMerged automatically by the fleet\'s nightly reflection (bin/fm-dream.sh), skills only.'
        if SECRET.search(message) or staged_secret(ctx, tree, changed):
            return {'status': 'rejected', 'why': 'secret-like text in a changed file or its summary'}
        git(ctx, 'commit', '-q', '-m', message, cwd=tree)
        pushed = False
        for _ in range(3):
            if ctx.run(['git', 'push', '-q', 'origin', 'HEAD:main'], cwd=tree, timeout=120).returncode == 0:
                pushed = True
                break
            git(ctx, 'fetch', '-q', 'origin', cwd=tree, timeout=120)
            if ctx.run(['git', 'rebase', '-q', 'origin/main'], cwd=tree, timeout=120).returncode:
                ctx.run(['git', 'rebase', '--abort'], cwd=tree, timeout=60)
                break
        if not pushed:
            return {'status': 'failed', 'why': 'could not push to main', 'changes': changes}
        commit = git(ctx, 'rev-parse', '--short', 'HEAD', cwd=tree).strip()
        ctx.facts['skills'] = changes
        ctx.facts['skills_commit'] = commit
        try:
            synced = ctx.run(['git', 'pull', '-q', '--ff-only'], cwd=dotfiles, timeout=120).returncode == 0
        except subprocess.TimeoutExpired:
            synced = False
        return {'status': 'merged', 'commit': commit, 'changes': changes, 'local_checkout_synced': synced}
    finally:
        # Cleanup runs even when the budget is spent, with its own short bound.
        for argv in (['git', 'worktree', 'remove', '--force', str(tree)], ['git', 'branch', '-D', branch]):
            try:
                subprocess.run(argv, cwd=dotfiles, capture_output=True, timeout=60)
            except subprocess.TimeoutExpired:
                pass


# --- triage -----------------------------------------------------------------

TRIAGE_PROMPT = """You are the firstmate fleet's nightly harness review. Read the digest of the \
fleet's last 24 hours: {digest}

Propose concrete improvements to the harness repositories, only where the digest shows evidence: a
bug seen in the logs, a missing guard, a slow path (the slow fm-* commands), a bad default, a
recurring failure. Repositories: {repos}. You may read code under {projects} to make an item precise,
but change nothing anywhere.

Already open or recently raised (do not propose these again):
{open_items}

Write {out} as JSON: {{"items": [{{"repo": "<one of the repositories>", "title": "imperative, under 90
characters", "kind": "bug|guard|slow|default", "evidence": ["exact digest lines, at most 4"],
"why": "one sentence: what it cost today", "fix": "two or three sentences: the change and where"}}]}}.
At most 6 items, best first. An empty list is a fine answer."""

JEV_HELPER = SCRIPT_DIR / 'wake-gate' / 'jev-worth.mjs'


def normalize(title):
    return {w for w in re.findall(r'[a-z0-9]+', title.lower()) if len(w) > 2}


def similar(a, b):
    x, y = normalize(a), normalize(b)
    return bool(x and y) and len(x & y) / min(len(x), len(y)) >= 0.6


def task_titles(out):
    """Titles of open rows in a `tasks-axi list` table, read by its own header."""
    titles, cols = [], None
    for line in out.splitlines():
        head = re.match(r'^tasks\[\d+\]\{([^}]*)\}:', line)
        if head:
            cols = head.group(1).split(',')
            continue
        if not cols or not line.startswith('  '):
            continue
        row = dict(zip(cols, next(csv.reader([line.strip()]), [])))
        if row.get('state') in ('queued', 'in_flight', 'held') and row.get('title'):
            titles.append(row['title'].split('\\n')[0].split('\n')[0])
    return titles


def open_items(ctx, repos, owners):
    """(titles, unchecked): titles of open work to deduplicate against (this
    home's backlog and every included mate's, local ones read in place and remote
    ones over bin/fm-on.sh; open PRs on the harness repositories; what dreaming
    raised lately), and the owners and repositories whose open work could not be
    read, so nothing is filed for them blind."""
    tasks = tool('fm-tasks-axi.sh', 'FM_DREAM_TASKS')
    reads = [('primary', [tasks, 'list', '--limit', '500'], ctx.home)]
    for mid, h, host in registry(ctx.home):
        if mid in ctx.excluded:
            continue
        if host:
            reads.append((mid, [tool('fm-on.sh', 'FM_DREAM_ON'), mid, 'fm-tasks-axi.sh', 'list', '--limit', '500'],
                          ctx.home))
        elif h:
            reads.append((mid, [tasks, 'list', '--limit', '500'], Path(h)))
    titles, unchecked = [], set()
    if REGISTRY_ERRORS:
        unchecked.add('the second-mate registry')
    for mid, argv, home in reads:
        try:
            r = ctx.run(argv, timeout=60, env=dict(os.environ, FM_HOME=str(home)))
            ok = r.returncode == 0 and re.search(r'^tasks\[\d+\]', r.stdout, re.M)
        except (OSError, subprocess.TimeoutExpired):
            r, ok = None, False
        if ok:
            titles += task_titles(r.stdout)
        else:
            unchecked.add(mid)
    for repo, slug in sorted(repos.items()):
        if not slug:
            continue
        try:
            r = ctx.run(['gh', 'pr', 'list', '--repo', slug, '--state', 'open', '--limit', '100',
                         '--json', 'title'], timeout=60)
            titles += [p['title'] for p in json.loads(r.stdout)] if r.returncode == 0 else []
            if r.returncode:
                unchecked.add(repo)
        except (OSError, subprocess.TimeoutExpired, ValueError, TypeError):
            unchecked.add(repo)
    raised = raised_titles(ctx)
    if raised is None:
        unchecked.add('the dreaming ledger (raised.jsonl)')
    return titles + (raised or []), unchecked


def raised_titles(ctx):
    """Titles dreaming raised in the last RAISED_DAYS days; [] before the first
    run, None when the ledger exists but cannot be read whole."""
    cutoff = ctx.now - RAISED_DAYS * 86400
    out = []
    try:
        text = (ctx.dir / 'raised.jsonl').read_text(encoding='utf-8')
    except FileNotFoundError:
        return []
    except OSError:
        return None
    for line in text.splitlines():
        try:
            row = json.loads(line)
        except ValueError:
            return None
        if isinstance(row, dict) and row.get('at', 0) >= cutoff:
            out.append(row.get('title', ''))
    return out


def jev_scores(ctx, items):
    """{index: worth probability} from the Jev helper, or (None, why)."""
    cmd = os.environ.get('FM_DREAM_JEV')
    keyvar = os.environ.get('FM_WAKE_GATE_KEY_VAR')
    if not keyvar:
        try:
            keyvar = (ctx.home / 'config' / 'wake-gate-key-var').read_text().split()[0]
        except (OSError, IndexError):
            keyvar = ''
    if not cmd:
        if not keyvar:
            return None, 'Jev not configured (config/wake-gate-key-var)'
        if not JEV_HELPER.is_file() or not (SCRIPT_DIR / 'wake-gate' / 'node_modules').is_dir():
            return None, 'Jev runtime missing (npm ci --prefix bin/wake-gate --omit=dev)'
        cmd = 'node %s' % shlex.quote(str(JEV_HELPER))
    scores = {}
    for i, it in enumerate(items):
        state = json.dumps({'title': it.get('title'), 'repo': it.get('repo'), 'why': it.get('why'),
                            'fix': it.get('fix'), 'evidence': it.get('evidence', [])[:4]})
        try:
            r = ctx.run(shlex.split(cmd), input=state, timeout=20, env=dict(os.environ, FM_WAKE_GATE_KEY_VAR=keyvar))
        except subprocess.TimeoutExpired:
            return None, 'Jev call timed out'
        row = next((l.split('\t') for l in r.stdout.splitlines() if l.startswith('answers\t')), None)
        if r.returncode or not row:
            return None, 'Jev call failed (%s)' % (r.stdout.strip().split('\t')[-1][:60] or r.returncode)
        try:
            concrete, evidence, worth = (float(x) for x in row[1:4])
        except ValueError:
            return None, 'Jev answer unreadable'
        scores[i] = min(concrete, evidence, worth)
    return scores, None


def step_triage(ctx):
    if quiet(ctx):
        return {'status': 'quiet day'}
    repos = ctx.config.get('repos') or DEFAULT_REPOS
    owners = ctx.config.get('owners') or {}
    titles, unchecked = open_items(ctx, repos, owners)
    out = ctx.dir / ('triage-%s.json' % ctx.day)
    if ctx.dry_run:
        return {'status': 'dry-run', 'open_items': len(titles), 'unchecked': sorted(unchecked)}
    if unchecked:
        ctx.facts['triage'] = []
        return {'status': 'partial', 'why': 'nothing proposed or filed, open work unreadable for %s'
                % ', '.join(sorted(unchecked))}
    if out.exists():
        out.unlink()
    prompt = TRIAGE_PROMPT.format(digest=ctx.digest, repos=', '.join(repos), projects=ctx.home / 'projects',
                                  open_items='\n'.join('- ' + t for t in titles[:300]) or '- none', out=out)
    failed = run_agent(ctx, prompt, ctx.dir, ctx.dir / ('triage-%s.log' % ctx.day), out)
    if failed:
        ctx.facts['triage'] = []
        return {'status': 'failed', 'why': failed}
    doc = read_json(out)
    if not isinstance(doc, dict) or not isinstance(doc.get('items'), list):
        ctx.facts['triage'] = []
        return {'status': 'failed', 'why': 'the triage agent wrote no valid %s' % out.name}
    items = [it for it in doc['items']
             if isinstance(it, dict) and it.get('repo') in repos and it.get('title') and it.get('evidence')]
    proposed = len(items)
    fresh = []
    for it in items:
        if not any(similar(it['title'], t) for t in titles + [f['title'] for f in fresh]):
            fresh.append(it)
    deduped = proposed - len(fresh)
    items = fresh
    scores, why = jev_scores(ctx, items) if items else ({}, None)
    if scores is not None:
        for i, it in enumerate(items):
            it['worth'] = round(scores.get(i, 0), 3)
        items = sorted([it for it in items if it['worth'] >= 0.5], key=lambda it: -it['worth'])
    kept = items[:MAX_RAISED]
    ctx.facts['triage'] = kept
    result = {'status': 'done', 'proposed': proposed, 'duplicates': deduped, 'kept': len(kept)}
    if why:
        result['why'] = why + '; kept the agent\'s own order'
    return result


# --- file -------------------------------------------------------------------

def step_file(ctx):
    items = ctx.facts.get('triage')
    if not items:
        return {'status': 'nothing to file'}
    owners = ctx.config.get('owners') or {}
    already = raised_titles(ctx)
    if already is None:
        return {'status': 'partial', 'why': 'raised.jsonl is unreadable; nothing filed'}
    raised, errors = [], []
    ctx.facts['raised'] = raised  # filled as each item lands, so a later failure keeps them
    for it in items:
        if any(similar(it['title'], t) for t in already):
            continue
        if ctx.deadline and time.time() > ctx.deadline - 30:
            errors.append('out of time before %s' % it['title'][:60])
            break
        mate = owners.get(it['repo'], 'primary')
        body = '\n'.join(['Raised by fleet dreaming (bin/fm-dream.sh) on %s.' % ctx.day, '',
                          'Why: ' + it.get('why', ''), '', 'Suggested fix: ' + it.get('fix', ''), '',
                          'Evidence from the day:'] + ['- ' + e[:300] for e in it.get('evidence', [])[:4]])
        if ctx.dry_run:
            raised.append({'title': it['title'], 'repo': it['repo'], 'mate': mate, 'key': None, 'why': it.get('why')})
            continue
        bf = ctx.dir / '.body.md'
        write_private(bf, body)
        env = dict(os.environ, FM_HOME=str(ctx.home))
        try:
            r = ctx.run([tool('fm-tasks-axi.sh', 'FM_DREAM_TASKS'), 'add', '--mint', '--prefix', 'dream', it['title'],
                         '--kind', 'ship', '--repo', it['repo'], '--body-file', str(bf), '--json'],
                        env=env, timeout=60)
        finally:
            bf.unlink()
        try:
            doc = json.loads(r.stdout)
            key = (doc.get('task') or {}).get('id') or doc.get('id')
        except (ValueError, AttributeError):
            key = None
        if r.returncode or not key:
            errors.append('%s: add failed (%s)' % (it['title'][:60], (r.stderr or r.stdout).strip()[:120]))
            continue
        row = {'title': it['title'], 'repo': it['repo'], 'mate': mate, 'key': key, 'why': it.get('why')}
        if mate != 'primary':
            try:
                h = ctx.run([tool('fm-backlog-handoff.sh', 'FM_DREAM_HANDOFF'), mate, key], env=env, timeout=120)
            except subprocess.TimeoutExpired:
                h = subprocess.CompletedProcess([], 124, '', 'timed out')
            if h.returncode:
                # The move may have happened with only the receiver's wake failing,
                # so the owner is not assumed back; the morning report flags it.
                row['handoff'] = 'unconfirmed'
                errors.append('%s: handoff to %s unconfirmed (%s)' % (key, mate, (h.stderr or h.stdout).strip()[:120]))
        raised.append(row)
        already.append(row['title'])
        with open(ctx.dir / 'raised.jsonl', 'a', encoding='utf-8') as fh:
            fh.write(json.dumps(dict(row, at=ctx.now)) + '\n')
    result = {'status': 'dry-run' if ctx.dry_run else ('partial' if errors else 'done'), 'raised': raised}
    if errors:
        result['why'] = '; '.join(errors)[:400]
    return result


# --- run --------------------------------------------------------------------

CLEAN = ('done', 'merged', 'no changes', 'quiet day', 'nothing to file', 'dry-run')  # anything else is not clean


def summary_line(run):
    skills, raised = run.get('skills') or [], run.get('raised') or []
    bad = [n for n, s in run['steps'].items() if s.get('status') not in CLEAN]
    text = 'Overnight: %s, %s.' % (
        '%d skill%s updated' % (len(skills), '' if len(skills) == 1 else 's') if skills else 'no skill changes',
        '%d fix%s raised' % (len(raised), '' if len(raised) == 1 else 'es') if raised else 'nothing raised')
    if bad:
        text += ' Did not run cleanly: %s.' % ', '.join('%s (%s)' % (n, run['steps'][n]['status']) for n in bad)
    return text


def cmd_run(args):
    try:
        ctx = Ctx(args.home, args.dry_run)
    except ConfigError as e:
        print('fm-dream: %s' % e, file=sys.stderr)
        return 1
    lock = ctx.dir / '.lock'
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
    except FileExistsError:
        try:
            os.kill(int(lock.read_text()), 0)
            print('fm-dream: another run is in progress', file=sys.stderr)
            return 1
        except (ValueError, OSError):
            lock.write_text(str(os.getpid()))
    run = {'schema': 'fm-dream.v1', 'date': ctx.day, 'started': iso(ctx.now), 'dry_run': ctx.dry_run, 'steps': {}}
    log_path = ctx.dir / 'runs' / (ctx.day + ('.dry-run' if ctx.dry_run else '') + '.json')
    try:
        for name in args.only or STEPS:
            began = time.time()
            why = room_for(name)
            if why:
                run['steps'][name] = {'status': 'skipped', 'why': why}
            else:
                ctx.deadline = time.time() + BUDGET[name]
                try:
                    run['steps'][name] = globals()['step_' + name](ctx)
                except subprocess.TimeoutExpired:
                    run['steps'][name] = {'status': 'timed out', 'why': 'over its %d s budget' % BUDGET[name]}
                except Exception as exc:  # noqa: BLE001 - one step never stops the next
                    run['steps'][name] = {'status': 'failed', 'why': '%s: %s' % (type(exc).__name__, str(exc)[:300])}
            ctx.deadline = None
            run['steps'][name]['seconds'] = round(time.time() - began)
            if name == 'triage':
                run['steps'][name]['items'] = ctx.facts.get('triage', [])
            write_json(log_path, run)
        run['finished'] = iso(time.time())
        run['skills'] = ctx.facts.get('skills', [])
        run['skills_commit'] = ctx.facts.get('skills_commit')
        run['raised'] = ctx.facts.get('raised', [])
        run['slow_commands'] = ctx.facts.get('slow_commands', [])
        run['counts'] = ctx.facts.get('counts', {})
        run['status'] = 'done' if all(s.get('status') in CLEAN for s in run['steps'].values()) else 'partial'
        run['summary'] = summary_line(run)
        write_json(log_path, run)
        if not ctx.dry_run and not args.only:
            write_json(ctx.dir / 'latest.json', {k: v for k, v in run.items() if k != 'steps'} | {
                'steps': {n: {k: v for k, v in s.items() if k in ('status', 'seconds', 'why')}
                          for n, s in run['steps'].items()}})
        print(json.dumps({'summary': run['summary'], 'steps': {n: {k: v for k, v in s.items() if k != 'items'}
                                                               for n, s in run['steps'].items()}},
                         indent=1, ensure_ascii=False))
        return 0
    finally:
        try:
            lock.unlink()
        except OSError:
            pass


def latest(home):
    """The last real run's summary, or None (bin/fm_report.py reads this)."""
    doc = read_json(Path(home) / 'state' / 'dream' / 'latest.json')
    return doc if isinstance(doc, dict) and doc.get('schema') == 'fm-dream.v1' else None


def cmd_status(args):
    doc = latest(args.home)
    if args.json:
        print(json.dumps(doc, indent=1, ensure_ascii=False))
        return 0
    if not doc:
        print('no fleet dreaming run recorded yet')
        return 0
    print('%s (%s, %s)' % (doc.get('summary'), doc.get('date'), doc.get('status')))
    for n, s in (doc.get('steps') or {}).items():
        print('  %s: %s%s' % (n, s.get('status'), ' - ' + s['why'] if s.get('why') else ''))
    return 0


def main(argv):
    p = argparse.ArgumentParser(prog='fm_dream.py')
    sub = p.add_subparsers(dest='cmd', required=True)
    r = sub.add_parser('run')
    r.add_argument('--home', required=True)
    r.add_argument('--only', nargs='*', choices=STEPS)
    r.add_argument('--dry-run', action='store_true')
    s = sub.add_parser('status')
    s.add_argument('--home', required=True)
    s.add_argument('--json', action='store_true')
    a = p.parse_args(argv)
    return cmd_run(a) if a.cmd == 'run' else cmd_status(a)


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
