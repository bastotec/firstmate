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
           local mates and their workers; captain-direct deliveries from every
           included local home's state, not only the main one; failed or cancelled
           no-mistakes runs; revive and restart results; the idle sweep; power)
           into a private digest under state/dream/ (0600, never committed),
           plus two calendar days of fleet reports for remote mates (remote deck
           transcripts are out of scope). Slow fm-* commands come from each
           run_command call joined to its result's duration_ms, at least SLOW_MS.
           Each included mate's current home-summary state is listed. Unreadable
           sessions, no-mistakes state or fleet reports, non-live included-home
           summaries, missing mate states, power errors and report gaps naming
           incomplete summaries or unavailable/unreadable data make collect partial.
           Readable record disagreements go into the digest for triage instead;
           bin/fm_report.py owns the gaps/inconsistencies distinction.
           No-mistakes breakdowns read each included registered host once over
           ssh only when its bridge allows reports; denied or unreadable hosts
           are named in collect's why without the other reasons' three-item cap.
  skills   a deck agent in a fresh ~/dotfiles worktree improves skills/ from
           the digest. Same guards as Ziggy's reflection: only skills/, at most
           MAX_DIFF_LINES changed lines, secret scan of all changed staged bytes
           (including binary files and the agent's commits) and the final commit
           message; committed and pushed to main (rebased and retried if main
           moved). The agent must write a changes list, empty for no change;
           MAX_SKILLS is prompt guidance, not an enforced cap.
  instructions
           a deck agent in a fresh worktree of firstmate's origin/main improves
           the instructions every agent reads - AGENTS.md, .agents/skills/ and
           the brief and charter templates in bin/fm-brief.sh - from the day's
           evidence, within a 90-minute budget and at most MAX_INSTRUCTION_LINES
           changed lines (additions plus deletions, with renames counted as both).
           Every change record must name a changed file, what, why and nonempty
           digest evidence, and every changed file must be listed. The patch is
           secret-scanned, never removing or rewording a line that carries a hard
           stop (HARD_STOPS: money, credentials, production, outward messages,
           destructive or irreversible actions, captain approval). The change
           ships as one PR through the no-mistakes gate (`no-mistakes axi run
           --yes`); auto-land (bin/fm-autoland.sh) merges it under its own
           authority, attestation and risk cap and rolls it out with the firstmate
           deploy hook. A PR above that cap, or a gate --yes cannot pass, is
           reported for the captain, never merged here. A parked gate is reported
           as 'needs a decision'; a spent budget as 'timed out'; other nonzero
           gate replies fail unless they report a bounded wait ending. These
           outcomes and an interrupted gate trigger a separately bounded abort;
           an unconfirmed stop is named in the step reason. The committed branch
           and worktree stay for the gate's CI monitor or human follow-up.
           Later nights prune earlier worktrees once the branch is an ancestor
           of origin/main, its PR is merged (including squash merges), or the
           worktree is a week old. A mate's own charter lives in its private home
           data, so edits to it are proposals in charters-<date>.md, not applied;
           excluded homes' proposals are dropped. 'pr opened' is a clean outcome.
           The morning summary separates the final PR diff's lines and files
           (or its unavailability) from proposed descriptions, and names the PR
           and its risk rating when available.
  triage   a deck agent proposes concrete harness fixes from the digest; each
           is deduplicated against open tasks in the main home and every included
           mate's backlog, open PRs, what dreaming raised in the last RAISED_DAYS
           days, and other proposals. If any open-work read fails or the registry
           has an unparsable entry, the agent does not run and nothing is filed.
           Jev scores proposals when configured; without a usable score, keep
           the agent's order and record why. Keep at most MAX_RAISED items.
  file     files only the items triage kept in this invocation as queued backlog
           tasks and hands each to its configured owning mate; it never replays a
           previous run's proposals. An unreadable raised.jsonl prevents filing,
           and an item already in its dedupe window is not filed twice.
           Dreaming never pushes to or opens PRs on harness repositories,
           except the instructions step's one PR on firstmate, through the gate.
  memory   runs the captain memory's upkeep (bin/fm_captain_memory.py) and adds
           its one line to the summary; skipped on a dry run. Its findings are
           not failures: only an upkeep that cannot run is not clean.

Runs are serialized by a kernel flock held for the whole run.
Before each step (dry runs included): skipped when the Mac has less than
MIN_FREE_GB available, and never started while Ziggy's own dream is running
(it waits up to WAIT_ZIGGY).
Each step's budget (BUDGET) bounds every subprocess it starts, git included;
subprocesses have their own process groups, and worktree cleanup has a separate
short bound. Each agent step uses deck run --ephemeral and retries one failed
attempt while budget remains; a nonzero exit, run_failed event or missing output
fails an attempt, and expected output is cleared before each attempt.
A digest with no sections skips all agent steps.
Only clean step outcomes (CLEAN) yield a done run; other outcomes make it partial.
--only selects steps in the supplied order; --dry-run still collects and reads
open work, but starts no agents, pushes nothing and files nothing.

Files under <home>/state/dream/:
  runs/<date>.json   the run log (every step's status, seconds, details);
                     dry runs use runs/<date>.dry-run.json. A run ended by
                     SIGTERM/SIGHUP is finalized as partial, keeping completed
                     steps, with the step in flight marked interrupted
  latest.json        published by a run without --only or --dry-run, even when
                     interrupted. The summary bin/fm_report.py reads
                     (schema fm-dream.v1):
                     {schema, date, started, finished, dry_run, status, steps: {name:
                     {status, seconds, why?, waited_for_ziggy?, timings?}},
                     skills: [{skill, what, why}], skills_commit,
                     raised: [{title, repo, mate, key, why}],
                     slow_commands: [{command, seconds, count}], counts: {...},
                     disagreements: [<home records read but disagreeing>],
                     instructions: {changes: [{path, what, why, evidence}],
                     proposed_lines (pre-gate additions + deletions),
                     lines, files (final PR diff when a PR exists; null if unread;
                     without a PR, lines is the proposal count and files is null),
                     pr, risk (null if unread)} | null,
                     charter_proposals: [{mate, what}],
                     no_mistakes: {...} or null, summary}
  raised.jsonl       one line per raised item (dedupe across nights)
  digest-<date>.md   the private digest the agents read
  charters-<date>.md private charter-edit proposals, when any are kept

Step timing starts after the pre-step checks; waited_for_ziggy, when nonzero,
is the seconds spent polling for Ziggy's dream before that step.
Collect's timings records elapsed seconds to one decimal place for its phases:
"sessions and local logs" (including the local failed-run read), "no-mistakes"
(the host breakdown), "fleet report", and "digest".
Both timing fields survive publication to latest.json.
The summary names the total recorded wait when it reaches five minutes.
Disagreements carries the fleet report's inconsistencies after excluding lines
naming excluded homes; the summary names their count and the first one's first
120 characters, with an indication when more remain.

no_mistakes (null when collect did not produce a breakdown):
  {date, failed, by_cause, by_step,
   hosts: {host: {reviews, cap_hits, failed, by_cause}}, previous, change}.
Counts cover the preceding 24 hours. Failures are failed/cancelled runs by
updated_at; this Mac uses only the fleet runs kept by no_mistakes_runs, while
remote hosts use their whole database. reviews counts all host review steps by
start time (completion time if absent); cap_hits counts distinct runs with an
exhausted repair-budget decision, dated by the parent step's completion time
or start time, not the decision's time. An absent database yields zero counts;
other read failures omit the host and name it as unread.
Causes, first match wins: repair cap (an exhausted decision at any time),
aborted (cancelled run), timeout, infra (lock/daemon/crash/gateway and similar
errors), finding, other. by_step names the first failed step, else the first
running/fixing/awaiting_approval/fix_review step, else none.
previous is {date, failed, by_cause, hosts}; change is {failed, by_cause, hosts,
coverage_changed}, with signed current-minus-previous counts only for hosts
measured in both runs. Both are null without common hosts. The comparison
source is latest.json at collection time, so a full same-day rerun compares
against the last publication, not necessarily the previous night.
The morning summary names the top three causes and available comparison;
counts.no_mistakes_failed remains the local fleet-only count, not the host total.

Configuration: docs/configuration.md "Fleet dreaming" owns config/dream.json.
Environment: FM_DREAM_DECK (deck binary), FM_DREAM_DOTFILES (~/dotfiles),
FM_DREAM_JEV (Jev helper command), FM_DREAM_MIN_FREE_GB, FM_DREAM_NO_MISTAKES_DB,
FM_DREAM_FIRSTMATE (firstmate checkout, default: this code root),
FM_DREAM_NO_MISTAKES (gate binary, default: no-mistakes), FM_DREAM_GH (gh binary).
Tests only: FM_DREAM_NOW (epoch), FM_DREAM_SKIP_ZIGGY_WAIT=1, FM_DREAM_ZIGGY_POLL (seconds), and FM_DREAM_TASKS,
FM_DREAM_HANDOFF, FM_DREAM_REPORT, FM_DREAM_ON, FM_DREAM_CAPTAIN_MEMORY replacing
bin/fm-tasks-axi.sh, bin/fm-backlog-handoff.sh, bin/fm-report.sh, bin/fm-on.sh and
`bin/fm_captain_memory.py upkeep`; FM_DREAM_BRIDGE
and FM_DREAM_SSH replace bin/fm-bridge.sh and ssh for breakdown reads.

    fm_dream.py run --home H [--only STEP ...] [--dry-run]
    fm_dream.py status --home H [--json]
"""
import argparse
import fcntl
import datetime as dt
import glob
import json
import os
import re
import sqlite3
import shlex
import signal
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
STEPS = ['collect', 'skills', 'instructions', 'triage', 'file', 'memory']
BUDGET = {'collect': 300, 'skills': 2700, 'instructions': 5400, 'triage': 1200, 'file': 300, 'memory': 120}
INSTRUCTION_PATHS = ('AGENTS.md', '.agents/skills/', 'bin/fm-brief.sh')
MAX_INSTRUCTION_LINES = 80
# A changed instruction line matching this is a hard stop: it may be added to, never removed or reworded.
HARD_STOPS = re.compile(r'money|payment|purchase|trade|transfer|bank|credential|password|token|secret|api key|'
                        r'production|\bprod\b|deploy|outward|publish|post(ed|ing)?\b|send(ing)? (a )?message|email|'
                        r'destructive|irreversible|security-sensitive|force|discard|captain.{0,40}(approv|explicit|word)|'
                        r'never merge|hard rule', re.I)
MIN_FREE_GB = float(os.environ.get('FM_DREAM_MIN_FREE_GB', '3'))
WAIT_ZIGGY = 3600
ZIGGY_POLL = float(os.environ.get('FM_DREAM_ZIGGY_POLL', '30'))  # tests shorten the poll
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
        self.private_words = None
        self.deadline = None
        registry(self.home)  # read once, before any step's budget starts
        if REGISTRY_ERRORS and self.excluded:
            raise ConfigError('data/secondmates.md has an entry that cannot be parsed, so excluded homes '
                              'cannot be told apart; fix the registry first')

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
        except BaseException:  # a timeout, or Ctrl+C on a supervised run: never leave the group behind
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


WAITED = {}  # step -> seconds it waited for Ziggy's dream before starting


def room_for(step):
    """None when the step may start, else why not. Time spent waiting for
    Ziggy's dream is recorded in WAITED, never in the step's own seconds."""
    waited = 0
    while ziggy_dreaming():
        if waited >= WAIT_ZIGGY:
            WAITED[step] = round(waited)
            return "Ziggy's dream still running after %d min" % (WAIT_ZIGGY // 60)
        time.sleep(ZIGGY_POLL)
        waited += ZIGGY_POLL
    WAITED[step] = round(waited)
    free = available_gb()
    if free is not None and free < MIN_FREE_GB:
        return 'only %.1f GB free on the Mac' % free
    return None


# --- collect ----------------------------------------------------------------

def registry(home):
    """The registry, read once per run (Ctx caches it before any step starts)."""
    if CACHE.get('registry_home') == str(home):
        return CACHE['registry']
    rows = read_registry(home)
    CACHE.update(registry_home=str(home), registry=rows)
    return rows


CACHE = {}


def read_registry(home):
    """[(id, home path or None, host or None)], read by fm_report.registry, which
    uses the registry's own parser (bin/fm-secondmate-registry-lib.sh)."""
    sys.path.insert(0, str(SCRIPT_DIR))
    import fm_report
    fm_report.REGISTRY_ERRORS.clear()
    rows = [(mid, row.get('home') or None, row.get('host') or None) for mid, row in fm_report.registry(home).items()]
    REGISTRY_ERRORS[:] = list(fm_report.REGISTRY_ERRORS)
    # Any other "- " record the parser skipped silently is unparsable too.
    try:
        records = [l for l in (Path(home) / 'data' / 'secondmates.md').read_text(encoding='utf-8').splitlines()
                   if l.startswith('- ')]
        if len(records) != len(rows) and not REGISTRY_ERRORS:
            REGISTRY_ERRORS.append('%d registry record(s) not parsed' % (len(records) - len(rows)))
    except FileNotFoundError:
        pass
    except OSError:
        REGISTRY_ERRORS.append('registry unreadable')
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


UNREADABLE = []  # session files collect could not parse, a partial collect


def session_lines(path, since, slow, label, hide=lambda line: False):
    """Digest lines for one deck session file, newer than since; slow fm-* calls
    are appended to slow as (command, seconds)."""
    doc = read_json(path)
    if not isinstance(doc, dict):
        UNREADABLE.append(os.path.basename(path))
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


def first_user_text(doc, chars=None):
    for msg in (doc or {}).get('messages') or []:
        if msg.get('role') == 'user':
            return text_of(msg.get('content'))[:chars] if chars else text_of(msg.get('content'))
    return ''


def local_homes(ctx):
    """[('main', home), (mate id, home), ...]: the main home and every included
    local mate's home, shared by session and captain-direct collection."""
    return [('main', ctx.home)] + [(mid, Path(h)) for mid, h, host in registry(ctx.home)
                                   if h and not host and mid not in ctx.excluded]


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

    def add(label, path, bound=False):
        if bound and not path.is_file():
            UNREADABLE.append(path.name)
            return
        if path.is_file() and path not in seen and path not in skip and path.stat().st_mtime >= ctx.since:
            seen.add(path)
            found.append((label, path))

    for chat, label in (('primary-chat', 'first mate, captain thread'), ('supervisor-chat', 'supervisor')):
        try:
            sid = (ctx.state / chat / 'session').read_text().strip()
        except FileNotFoundError:
            continue
        except OSError:
            UNREADABLE.append(chat + '/session')
            continue
        add(label, sessions / (sid + '.json'), bound=True)
    homes = local_homes(ctx)
    for mid, h in homes:
        for f in sorted(glob.glob(str(h / 'state' / '*.deck-session')) + glob.glob(str(h / 'state' / '*.supervisor-session'))):
            name, kind = Path(f).name.rsplit('.', 1)
            try:
                sid = Path(f).read_text().split()[0]
            except (OSError, IndexError):
                if name not in ctx.excluded:
                    UNREADABLE.append(Path(f).name)
                continue
            if name in ctx.excluded:
                skip.add(sessions / (sid + '.json'))
                continue
            add('%s / %s%s' % (mid, name, ' (supervisor)' if kind == 'supervisor-session' else ''),
                sessions / (sid + '.json'), bound=True)
    bound = seen | skip
    for f in sorted(glob.glob(str(sessions / '*.json'))):
        path = Path(f)
        if path in bound or path.stat().st_mtime < ctx.since:
            continue
        doc = read_json(path)
        if doc is None:
            UNREADABLE.append(path.name)  # cannot tell whether it was a worker's
            continue
        brief = first_user_text(doc)
        del doc
        # A worker's brief names its inbox, <home>/state/<task>.inbox: only workers
        # of this home or an included local home count, never another FM_HOME's.
        inbox = re.search(r'Your steering inbox is `([^`]+)/state/[^`/]+\.inbox`', brief)
        mine = bool(inbox) and inbox.group(1).rstrip('/') in {h.rstrip('/') for h in ours}
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
    included local home, or whose GitHub remote is a harness repository (owner/
    name). Anything else (an excluded mate's project, a same-named client repo)
    never reaches the digest."""
    db = Path(os.environ.get('FM_DREAM_NO_MISTAKES_DB') or os.path.expanduser('~/.no-mistakes/state.sqlite'))
    if not db.is_file():
        return [], None
    try:
        con = sqlite3.connect('file:%s?mode=ro' % db, uri=True, timeout=5)
        cols = {r[1] for r in con.execute('PRAGMA table_info(runs)')}
        repo_cols = {r[1] for r in con.execute('PRAGMA table_info(repos)')}
        when = 'updated_at' if 'updated_at' in cols else 'created_at'
        pick = [c for c in ('id', 'status', 'branch', 'error', 'pr_url', 'worktree_dir') if c in cols]
        path = (', repos.working_path, ' + ("COALESCE(repos.upstream_url, '') || ' ' || COALESCE(repos.fork_url, '')"
                                           if {'upstream_url', 'fork_url'} <= repo_cols else "''")
                if 'working_path' in repo_cols and 'repo_id' in cols else ", '', ''")
        join = ' LEFT JOIN repos ON repos.id = runs.repo_id' if path != ", '', ''" else ''
        rows = con.execute('SELECT %s, runs.%s%s FROM runs%s WHERE runs.status IN (\'failed\', \'cancelled\') '
                           'ORDER BY runs.%s DESC LIMIT 400' % (', '.join('runs.' + c for c in pick), when, path,
                                                                 join, when)).fetchall()
        con.close()
    except sqlite3.Error as e:
        return [], 'no-mistakes state unreadable (%s)' % e
    out = []
    for row in rows:
        r = dict(zip(pick + ['when', 'repo_path', 'repo_urls'], row))
        stamp = r['when'] / (1000 if r['when'] and r['when'] > 1e12 else 1) if isinstance(r['when'], (int, float)) \
            else parse_iso(r['when']) or 0
        repo = str(r.get('repo_path') or '')
        places = [repo, str(r.get('worktree_dir') or '')]
        if any(place == p or place.startswith(p.rstrip('/') + '/') for p in private_paths for place in places if p):
            continue
        urls = str(r.pop('repo_urls', '') or '')
        ours = any(repo == p or repo.startswith(p.rstrip('/') + '/') for p in fleet_paths) \
            or any(re.search(r'(https://github\.com/|git@github\.com:|ssh://git@github\.com/)%s(\.git)?/?(\s|$)'
                             % re.escape(slug), urls) for slug in harness)
        if stamp >= since and ours and not any(n in json.dumps(r, ensure_ascii=False, default=str) for n in private_names() + list(private_paths)):
            out.append(r)
    return out, None


# The no-mistakes cause breakdown, run against one host's state database (here
# with python3 directly, on another host over ssh with this text on stdin):
#   python3 - <db-path or ~/...> <since-epoch> [<run ids JSON>]
# prints {reviews, cap_hits, failed, by_step, by_cause}; the module header owns
# counting windows and cause precedence. A run-id list restricts failures only.
NM_BREAKDOWN_PY = r"""
import json, os, re, sqlite3, sys
db, since = os.path.expanduser(sys.argv[1]), int(sys.argv[2])
only = set(json.loads(sys.argv[3])) if len(sys.argv) > 3 else None
CAUSES = (
    ('timeout', r'timed? ?out|timeout|deadline exceeded|wait of .* elapsed'),
    ('infra', r'database is locked|SQLITE_BUSY|\block\b|lock(ed)? |daemon|panic|crash|upstream_error|gateway|'
              r'connection (refused|reset)|\bEOF\b|killed|signal|not initialized|no such file|unreachable|'
              r'context canceled'),
    ('finding', r'finding|non-compliant|refusing|risk|review|test(s)? failed|lint|check(s)? failed'),
)
def ms(v):
    return (v / 1000 if v and v > 1e12 else v) if isinstance(v, (int, float)) else 0
out = {'reviews': 0, 'cap_hits': 0, 'failed': 0, 'by_step': {}, 'by_cause': {}}
if not os.path.isfile(db):
    print(json.dumps(out)); sys.exit(0)
con = sqlite3.connect('file:%s?mode=ro' % db, uri=True, timeout=5)
tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
steps = {}
step_rows = con.execute(
    'SELECT run_id, step_name, step_order, status, started_at, completed_at, error, findings_json FROM step_results'
) if 'step_results' in tables else []
for run_id, name, order, status, started, completed, error, findings in step_rows:
    if name == 'review' and ms(started or completed) >= since:
        out['reviews'] += 1
    steps.setdefault(run_id, []).append((order or 0, name, status, error or '', findings or ''))
capped, capped_ever = set(), set()
if {'repair_budget_decisions', 'step_results'} <= tables:
    for run_id, when in con.execute(
            "SELECT s.run_id, MAX(COALESCE(s.completed_at, s.started_at)) FROM repair_budget_decisions d "
            "JOIN step_results s ON s.id = d.step_result_id WHERE d.source = 'exhausted' GROUP BY s.run_id"):
        capped_ever.add(run_id)  # a run that hit the cap before the window still failed of it
        if ms(when) >= since:
            capped.add(run_id)
out['cap_hits'] = len(capped)
for run_id, status, error, updated in con.execute(
        "SELECT id, status, error, updated_at FROM runs WHERE status IN ('failed', 'cancelled')"):
    if ms(updated) < since or (only is not None and run_id not in only):
        continue
    rows = sorted(steps.get(run_id, []))
    stopped = [r for r in rows if r[2] == 'failed'] or \
        [r for r in rows if r[2] in ('running', 'fixing', 'awaiting_approval', 'fix_review')]
    step = stopped[0][1] if stopped else 'none'
    text = ' '.join([error or ''] + [r[3] for r in stopped])
    if run_id in capped_ever:
        cause = 'repair cap'
    elif status == 'cancelled':
        cause = 'aborted'
    else:
        cause = next((c for c, rx in CAUSES if re.search(rx, text, re.I)), None)
        if cause is None:
            cause = 'finding' if any(r[4] not in ('', '[]', 'null') for r in stopped) else 'other'
    out['failed'] += 1
    out['by_step'][step] = out['by_step'].get(step, 0) + 1
    out['by_cause'][cause] = out['by_cause'].get(cause, 0) + 1
con.close()
print(json.dumps(out))
"""


def nm_breakdown(ctx, nm):
    """Per-cause no-mistakes failures on every fleet machine, read-only. This
    Mac's failures are exactly the runs collect already kept (the fleet's own);
    another machine's database is read whole over ssh when its bridge allows the
    reports flow. Unreachable hosts are named, never guessed."""
    hosts, errors = {}, []
    local_db = os.environ.get('FM_DREAM_NO_MISTAKES_DB') or '~/.no-mistakes/state.sqlite'
    try:
        r = ctx.run(['python3', '-', local_db, str(int(ctx.since)), json.dumps([x.get('id') for x in nm])],
                    input=NM_BREAKDOWN_PY, timeout=60)
        hosts['this Mac'] = json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        hosts['this Mac'] = None
    remote = sorted({h for mid, _home, h in registry(ctx.home) if h and mid not in ctx.excluded})
    env = dict(os.environ, FM_HOME=str(ctx.home))
    for host in remote:
        try:
            gate = ctx.run([tool('fm-bridge.sh', 'FM_DREAM_BRIDGE'), 'check', host, 'reports'], timeout=30, env=env)
            if gate.returncode != 0:
                errors.append('%s: bridge does not allow reports' % host)
                continue
            r = ctx.run([os.environ.get('FM_DREAM_SSH') or 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', host,
                         'python3 - ~/.no-mistakes/state.sqlite %d' % int(ctx.since)], input=NM_BREAKDOWN_PY, timeout=90)
            hosts[host] = json.loads(r.stdout) if r.returncode == 0 else None
        except (OSError, subprocess.TimeoutExpired, ValueError):
            hosts[host] = None
    for host, got in list(hosts.items()):
        if got is None:
            errors.append('%s: no-mistakes state unreadable' % host)
            del hosts[host]
    total = {'failed': 0, 'by_cause': {}, 'by_step': {}}
    for got in hosts.values():
        total['failed'] += got['failed']
        for key in ('by_cause', 'by_step'):
            for k, v in got[key].items():
                total[key][k] = total[key].get(k, 0) + v
    last_night = read_json(ctx.dir / 'latest.json') or {}
    prev = last_night.get('no_mistakes') or {}
    host_view = {h: {k: g[k] for k in ('reviews', 'cap_hits', 'failed', 'by_cause')} for h, g in hosts.items()}
    out = {'failed': total['failed'], 'by_cause': total['by_cause'], 'by_step': total['by_step'],
           'hosts': host_view, 'date': ctx.day, 'previous': None, 'change': None}
    prev_hosts = prev.get('hosts') or {}
    common = sorted(set(host_view) & set(prev_hosts))
    if common:
        # Compare only machines measured both nights, so a host that went
        # unread is never mistaken for an improvement.
        def sums(view):
            causes = {}
            for h in common:
                for c, n in (view[h].get('by_cause') or {}).items():
                    causes[c] = causes.get(c, 0) + n
            return sum(view[h].get('failed', 0) for h in common), causes
        now_failed, now_causes = sums(host_view)
        then_failed, then_causes = sums(prev_hosts)
        out['previous'] = {'date': last_night.get('date'), 'failed': then_failed, 'by_cause': then_causes,
                           'hosts': common}
        out['change'] = {'failed': now_failed - then_failed, 'hosts': common,
                         'by_cause': {c: now_causes.get(c, 0) - then_causes.get(c, 0)
                                      for c in sorted(set(now_causes) | set(then_causes))},
                         'coverage_changed': sorted(set(host_view) ^ set(prev_hosts))}
    return out, errors


def nm_summary(nmb):
    """'no-mistakes: 93 failed (-12 vs 2026-10-15); top: aborted 60, repair cap 20, infra 8'."""
    if not nmb:
        return ''
    top = sorted(nmb['by_cause'].items(), key=lambda kv: -kv[1])[:3]
    change = nmb.get('change') or {}
    delta = '' if not change else ' (%+d vs %s%s)' % (
        change['failed'], (nmb.get('previous') or {}).get('date'),
        ', on ' + ', '.join(change['hosts']) + ' only' if change.get('coverage_changed') else '')
    return 'no-mistakes: %d failed%s%s' % (nmb['failed'], delta,
                                          '; top: ' + ', '.join('%s %d' % kv for kv in top) if top else '')


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
    """True when line names an excluded home by id, spelled id, or registered path."""
    if ctx.private_words is None:
        ctx.private_words = sorted(ctx.excluded | {m.replace('-', ' ') for m in ctx.excluded}
                                   | {h for mid, h, host in registry(ctx.home) if mid in ctx.excluded and h})
    return any(word in line for word in ctx.private_words)


def step_collect(ctx):
    parts, slow = ['# Fleet day digest, %s (since %s)' % (ctx.day, iso(ctx.since)), ''], []
    UNREADABLE.clear()
    timings, mark = {}, [time.time()]

    def lap(phase):  # seconds since the previous phase, so a slow night shows where it went
        now = time.time()
        timings[phase] = round(now - mark[0], 1)
        mark[0] = now

    sessions = local_sessions(ctx)
    for label, path in sessions:
        parts += session_lines(path, ctx.since, slow, label, lambda line: mentions_excluded(ctx, line))
    captain = []
    for _mid, h in local_homes(ctx):  # fm-send.sh records deliveries in the sending home's state
        for line in tail_since(h / 'state' / 'captain-direct.log', ctx.since, hide=lambda l: mentions_excluded(ctx, l)):
            corr = re.search(r'corr=([0-9a-f]+)', line)
            try:
                body = (h / 'state' / 'captain-direct' / (corr.group(1) + '.text')).read_text(errors='replace') if corr else ''
            except OSError:
                body = ''
            body = ' '.join(body.split())
            if not mentions_excluded(ctx, body):
                captain.append('%s: %s' % (line[:120], body[:500]) if body else line)
    if captain:
        parts += ['## Captain-direct messages', *captain, '']
    fleet_paths = [str(h) for _mid, h in local_homes(ctx)]
    harness = {slug for slug in (ctx.config.get('repos') or DEFAULT_REPOS).values() if slug}
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
                l.strip() for l in body.splitlines() if re.match(r'\s*(status|restarted|unreached|nudged|failed)', l)
                and not mentions_excluded(ctx, l))[:400]))
    if restarts:
        parts += ['## Restarts and reloads', *restarts, '']
    sweep = tail_since(ctx.state / 'idle-sweep.log', ctx.since, hide=lambda l: mentions_excluded(ctx, l))
    if sweep:
        parts += ['## Idle sweep', *sweep, '']
    lap('sessions and local logs')
    nmb, nmb_errors = nm_breakdown(ctx, nm)
    lap('no-mistakes')
    ctx.facts['no_mistakes'] = nmb
    if nmb['failed'] or nmb['hosts']:
        parts += ['## No-mistakes failures by cause', nm_summary(nmb)]
        parts += ['- %s: %d reviews, %d hit the repair cap, %d failed (%s)' % (
            h, g['reviews'], g['cap_hits'], g['failed'], ', '.join('%s %d' % kv for kv in sorted(g['by_cause'].items())))
            for h, g in nmb['hosts'].items()]
        parts += ['- by step: ' + ', '.join('%s %d' % kv for kv in sorted(nmb['by_step'].items(), key=lambda kv: -kv[1]))]
        parts += ['- unread: ' + e for e in nmb_errors] + ['']
    rep = fleet_report(ctx)
    lap('fleet report')
    if rep:
        parts += ['## Fleet report', rep.get('summary') or '']
        parts += ['- waiting: %s (on %s, %s)' % (w.get('what'), w.get('on'), w.get('mate'))
                  for w in rep.get('waiting', [])
                  if w.get('mate') not in ctx.excluded and not mentions_excluded(ctx, json.dumps(w, ensure_ascii=False))]
        parts += ['- mate %s (%s): %s; %d working, %d waiting, %d shipped' % (
            m.get('id'), m.get('machine'), m.get('state') or 'no current state', m.get('working', 0),
            m.get('waiting', 0), m.get('shipped', 0))
            for m in rep.get('mates', []) if m.get('id') not in ctx.excluded and not mentions_excluded(ctx, m.get('id') or '')]
        parts += ['- gap: ' + g for g in rep.get('gaps', []) if not mentions_excluded(ctx, g)]
        ctx.facts['disagreements'] = [g for g in rep.get('inconsistencies', []) if not mentions_excluded(ctx, g)]
        parts += ['- records disagree: ' + g for g in ctx.facts['disagreements']]
        parts += ['- crew %s: %s on %s (%s)' % (c.get('status'), c.get('agent'), c.get('task'), c.get('mate'))
                  for c in rep.get('crew', []) if c.get('status') in ('failed', 'blocked', 'stopped', 'needs-decision')
                  and c.get('mate') not in ctx.excluded and not mentions_excluded(ctx, json.dumps(c, ensure_ascii=False))][:30]
        parts += ['- shipped: %s (%s)' % (x.get('title'), x.get('mate')) for x in rep.get('shipped', [])
                  if x.get('mate') not in ctx.excluded and not mentions_excluded(ctx, json.dumps(x, ensure_ascii=False))][:30]
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
                           'no_mistakes_failed': len(nm),
                           # one relaunch is logged as "reviving ..." then
                           # "revived ..." (bin/fm-secondmate-revive.sh), so
                           # only completed relaunches are counted, once each
                           'revives': sum(1 for l in revives if ' revived ' in l or ' relaunched ' in l),
                           'restarts': len(restarts),
                           'idle_sweep': len(sweep), 'digest_chars': len(text)}
    unread = ['%s: %s' % (m.get('id'), m.get('freshness')) for m in (rep or {}).get('mates', [])
              if m.get('id') not in ctx.excluded and m.get('freshness') not in ('fresh', 'local', 'remote', None)]
    # Partial means something could not be read; records that were read but
    # disagree are digest findings for triage, not a partial collect.
    unread += [g for g in (rep or {}).get('gaps', [])
               if re.search(r'summary incomplete|unreadable|unavailable|could not be (read|checked)', g)
               and not mentions_excluded(ctx, g)][:3]
    unread += ['%s: no current state' % m.get('id') for m in (rep or {}).get('mates', [])
               if m.get('id') not in ctx.excluded and not m.get('state')]
    if (rep or {}).get('power_error'):
        unread.append('power: %s' % rep['power_error'])
    if UNREADABLE:
        unread.append('%d session file(s) unreadable' % len(UNREADABLE))
    # Unread machines are always named; other reasons are capped at three.
    gaps = ([nm_err] if nm_err else []) + (['fleet report unreadable'] if rep is None else []) + unread[:3] + nmb_errors
    lap('digest')
    result = {'status': 'partial' if gaps else 'done', **ctx.facts['counts'], 'timings': timings}
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


def git(ctx, *args, cwd, check=True, timeout=None, text=True):
    """git inside the step's budget; output, or CalledProcessError when check."""
    r = ctx.run(['git', *args], cwd=cwd, timeout=timeout, text=text)
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
        if rc == 0 and not failed and Path(output).is_file():
            return None
        why = 'agent failed: %s' % ((failed[-1] if failed else None)
                                    or ('deck exited %d' % rc if rc else 'it wrote no %s' % Path(output).name))
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
        # -z: under the default core.quotePath Git prints a non-ASCII path quoted
        # and escaped, which a skills-only edit like skills/x/ação.md would then
        # fail the skills/ check on: a false rejection.
        raw = git(ctx, 'diff', '--cached', '--name-only', '-z', '--no-renames', base, cwd=tree, text=False)
        changed = [p for p in raw.decode('utf-8', 'surrogateescape').split('\0') if p]
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


# --- instructions -----------------------------------------------------------

INSTRUCTIONS_PROMPT = """You are the firstmate fleet's nightly instructions review. Read the digest of \
the fleet's last 24 hours: {digest}

Every agent in the fleet reads these instructions, all in this checkout ({tree}): AGENTS.md (the
first and second mates' contract), .agents/skills/ (the shared agent-only skills) and bin/fm-brief.sh
(the crewmate brief and second-mate charter templates). Improve them only where the digest shows
evidence that they misled an agent today: a correction the captain had to repeat, a wrong or
misdirected blocker, a confusing decision card, a recurring failure cause that a clearer instruction
would have avoided. Read .agents/skills/firstmate-coding-guidelines/SKILL.md first and follow it
(one owner per rule, prefer rewording over appending, one sentence per line, plain dash).

Hard rules for this change:
- Edit only AGENTS.md, files under .agents/skills/, and the template text in bin/fm-brief.sh. No code.
- At most {max_lines} changed lines in total. Small and evidence-linked beats broad.
- Never remove, reword or weaken a line about money, payments, credentials, production, deploys,
  outward messages (posting, sending, publishing), destructive or irreversible actions, security, or
  what needs the captain's explicit approval. You may only add to those.
- No secrets, keys, account numbers or private personal details; no captain or mate names that are
  not already in these files.
- Do not commit; leave the edits in the working tree.
- If nothing warrants a change, change nothing.

A mate's own charter (its data/charter.md and data/secondmates.md entry) is private and not in this
checkout: propose edits to it instead of making them.

Finally write {out} as JSON: {{"changes": [{{"path": "file", "what": "one plain sentence", "why": "what
happened today", "evidence": ["exact digest lines, at most 3"]}}], "charters": [{{"mate": "<mate id>",
"what": "the edit, in one or two sentences", "why": "...", "evidence": ["..."]}}]}} - empty lists when
there is nothing."""


def firstmate_repo(ctx):
    return Path(os.environ.get('FM_DREAM_FIRSTMATE') or SCRIPT_DIR.parent)


def nm_bin():
    return os.environ.get('FM_DREAM_NO_MISTAKES') or 'no-mistakes'


def stop_run(tree):
    """Stop the owned no-mistakes run in tree with its own short bound, so a
    spent step budget never leaves the daemon publishing on its own. True only
    when the abort says the run is cancelled."""
    try:
        r = subprocess.run([nm_bin(), 'axi', 'abort'], cwd=tree, capture_output=True, text=True, timeout=120)
    except (OSError, subprocess.TimeoutExpired):
        return False
    return r.returncode == 0 and 'cancelled' in (r.stdout or '')


def drive_gate(ctx, tree, intent):
    """Drive one no-mistakes run in tree to its outcome with --yes, within the
    step budget. Returns (outcome, pr_url, detail); outcome is the pipeline's
    word, 'gate' when a gate --yes cannot pass, or 'timed out'. Gates are read
    by bin/fm_gate_record.py's parser, which knows both AXI response shapes."""
    from fm_gate_record import parse as parse_gate
    args = [nm_bin(), 'axi', 'run', '--yes', '--intent', intent]
    pr = None
    while ctx.left() > 180:
        try:
            r = ctx.run(args, cwd=tree, timeout=min(600, ctx.left() - 150))
        except subprocess.TimeoutExpired:
            break
        out = (r.stdout or '') + (r.stderr or '')
        m = re.search(r'https://github\.com/[^\s"\']+/pull/\d+', out)
        pr = m.group(0) if m else pr
        if pr and isinstance(ctx.facts.get('instructions'), dict):
            ctx.facts['instructions']['pr'] = pr  # known even if the night is interrupted next
        outcome = re.search(r'^outcome: (\S+)', out, re.M)
        if outcome:
            return outcome.group(1), pr, ''
        _run, gate = parse_gate(out)
        if gate:
            findings = ', '.join('%s %s' % (f.get('id'), f.get('severity')) for f in gate['findings'][:4])
            return 'gate', pr, '%s gate%s' % (gate.get('step') or 'a', ': ' + findings if findings else '')
        if r.returncode and not re.search(r'wait of \S+ elapsed', out):
            # Anything but the bounded hold ending is an error to report, not to retry.
            last = [l for l in out.splitlines() if l.strip()][-1:] or ['no-mistakes exited %d' % r.returncode]
            return 'failed', pr, last[0][:300]
        args = [nm_bin(), 'axi', 'run', '--yes', '--intent', 'x']  # reattach: the run keeps its intent
    return 'timed out', pr, 'no outcome within the step budget'


def pr_diff(ctx, pr):
    """(changed lines, files) of the PR as finally reviewed, or (None, None)."""
    try:
        r = ctx.run([os.environ.get('FM_DREAM_GH') or 'gh', 'pr', 'view', pr, '--json', 'additions,deletions,files'],
                    timeout=60)
        doc = json.loads(r.stdout)
        return doc['additions'] + doc['deletions'], [f['path'] for f in doc.get('files') or []]
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError):
        return None, None


def pr_risk(ctx, pr):
    """The PR's risk word (Low, Medium, High) from its body, or None."""
    try:
        r = ctx.run([os.environ.get('FM_DREAM_GH') or 'gh', 'pr', 'view', pr, '--json', 'body', '-q', '.body'], timeout=60)
    except (OSError, subprocess.TimeoutExpired):
        return None
    m = re.search(r'## Risk Assessment\s+\S*\s*(Low|Medium|High)\b', r.stdout or '')
    return m.group(1) if m else None


def step_instructions(ctx):
    if quiet(ctx):
        return {'status': 'quiet day'}
    if ctx.dry_run:
        return {'status': 'dry-run', 'would': 'run the instructions agent and open one gated firstmate PR'}
    repo = firstmate_repo(ctx)
    git(ctx, 'fetch', '-q', 'origin', cwd=repo, timeout=120)
    prune_instruction_trees(ctx, repo)
    branch = 'fm/dream-instructions-%s' % ctx.day
    tree = ctx.dir / ('firstmate-' + branch.replace('/', '-'))
    if ctx.run(['git', 'rev-parse', '--verify', '-q', branch], cwd=repo).returncode == 0:
        return {'status': 'rejected', 'why': 'branch %s already exists; tonight already opened one' % branch}
    git(ctx, 'worktree', 'add', '-q', '-b', branch, str(tree), 'origin/main', cwd=repo)
    keep_branch = False
    try:
        base = git(ctx, 'rev-parse', 'HEAD', cwd=tree).strip()
        out = ctx.dir / ('instructions-%s.json' % ctx.day)
        prompt = INSTRUCTIONS_PROMPT.format(digest=ctx.digest, tree=tree, max_lines=MAX_INSTRUCTION_LINES, out=out)
        failed = run_agent(ctx, prompt, tree, ctx.dir / ('instructions-%s.log' % ctx.day), out)
        if failed:
            return {'status': 'failed', 'why': failed}
        doc = read_json(out)
        if not isinstance(doc, dict) or not isinstance(doc.get('changes'), list):
            return {'status': 'failed', 'why': 'the instructions agent wrote no valid %s' % out.name}
        charters = [c for c in doc.get('charters') or [] if isinstance(c, dict) and c.get('mate')
                    and c.get('mate') not in ctx.excluded]
        if charters:
            write_private(ctx.dir / ('charters-%s.md' % ctx.day), '\n'.join(
                ['# Proposed charter edits, %s' % ctx.day, ''] +
                ['- %s: %s (why: %s; evidence: %s)' % (c['mate'], c.get('what'), c.get('why'),
                                                       '; '.join(c.get('evidence') or [])) for c in charters]) + '\n')
            ctx.facts['charter_proposals'] = [{'mate': c['mate'], 'what': c.get('what')} for c in charters]
        git(ctx, 'add', '-A', cwd=tree)
        git(ctx, 'reset', '-q', '--soft', base, cwd=tree)
        raw = git(ctx, 'diff', '--cached', '--name-only', '-z', '--no-renames', base, cwd=tree, text=False)
        changed = [p for p in raw.decode('utf-8', 'surrogateescape').split('\0') if p]
        if not changed:
            return {'status': 'no changes', 'charter_proposals': len(charters)}
        outside = [p for p in changed if not (p in INSTRUCTION_PATHS or p.startswith('.agents/skills/'))]
        if outside:
            return {'status': 'rejected', 'why': 'touched %s' % outside[:3]}
        diff = git(ctx, 'diff', '--cached', '-U0', '--no-renames', base, cwd=tree)  # a move is a removal and an addition
        removed, added = [], []
        in_hunk = False
        for line in diff.splitlines():
            if line.startswith('diff --git '):
                in_hunk = False
            elif line.startswith('@@ '):
                in_hunk = True
            elif in_hunk:
                if line.startswith('-'):
                    removed.append(line[1:])
                elif line.startswith('+'):
                    added.append(line[1:])
        if len(removed) + len(added) > MAX_INSTRUCTION_LINES:
            return {'status': 'rejected', 'why': '%d changed lines (cap %d)' % (len(removed) + len(added), MAX_INSTRUCTION_LINES)}
        stops = [l.strip()[:80] for l in removed if HARD_STOPS.search(l)]
        if stops:
            return {'status': 'rejected', 'why': 'would remove or reword a hard-stop line: %s' % stops[0]}
        changes = doc['changes']
        complete = lambda c: (isinstance(c, dict) and c.get('path') in changed and c.get('what') and c.get('why')
                              and isinstance(c.get('evidence'), list) and any(c['evidence']))
        if not changes or not all(complete(c) for c in changes):
            return {'status': 'rejected', 'why': 'every change must name a changed file, what, why and its digest evidence'}
        unlisted = sorted(set(changed) - {c['path'] for c in changes})
        if unlisted:
            return {'status': 'rejected', 'why': 'changed files the agent did not list: %s' % unlisted[:3]}
        title = 'Improves fleet instructions from the %s sessions (fleet dreaming)' % ctx.day
        body = '\n'.join('- %s: %s (%s)' % (c.get('path'), c.get('what'), c.get('why')) for c in changes)
        message = title + '\n\n' + body + '\n\nProposed by the fleet\'s nightly reflection (bin/fm-dream.sh); shipped through the no-mistakes gate.'
        if SECRET.search(message) or staged_secret(ctx, tree, changed):
            return {'status': 'rejected', 'why': 'secret-like text in a changed file or its summary'}
        git(ctx, 'commit', '-q', '-m', message, cwd=tree)
        keep_branch = True  # from here the gate owns the branch
        intent = ('Nightly fleet dreaming instructions change for %s, proposed from the day\'s digest by '
                  'bin/fm-dream.sh under the captain\'s direction that dreaming improve the instructions all '
                  'agents and charters read. Scope: only AGENTS.md, .agents/skills/ and the brief and charter '
                  'templates in bin/fm-brief.sh; at most %d changed lines; no hard-stop line (money, credentials, '
                  'production, outward messages, destructive or irreversible actions, captain approval) removed '
                  'or reworded. Each change and its evidence:\n%s\nRisk policy: auto-land at its cap; anything '
                  'above it waits for the captain.' % (ctx.day, MAX_INSTRUCTION_LINES, body))
        proposed = len(removed) + len(added)
        # Recorded before the gate runs, so an interrupted night still reports the proposal and its PR.
        summary = {'changes': changes, 'proposed_lines': proposed, 'lines': proposed, 'pr': None,
                   'files': None, 'risk': None}
        ctx.facts['instructions'] = summary

        def read_pr_back():
            pr_now = summary['pr']
            if pr_now:
                # Whatever the outcome, the gate may have repaired the patch: report what the PR holds.
                final_lines, files = pr_diff(ctx, pr_now)
                summary.update(risk=pr_risk(ctx, pr_now), lines=final_lines, files=files)

        try:
            outcome, pr, detail = drive_gate(ctx, tree, intent)
        except KeyboardInterrupt as exc:
            # An interrupted night (SIGTERM, SIGHUP) must not leave the gate publishing alone.
            stopped = stop_run(tree)
            try:
                read_pr_back()
            except Exception:  # noqa: BLE001 - the stop, not the metadata, is what matters here
                pass
            raise KeyboardInterrupt('%s; stopping the gate run was %s' % (exc, 'confirmed' if stopped else 'not confirmed'))
        except BaseException:
            stop_run(tree)
            raise
        if outcome in ('gate', 'timed out', 'failed'):
            # Nothing waits on a parked run overnight: stop it, keep the branch for a person.
            if not stop_run(tree):
                detail = (detail or outcome) + '; stopping the run was not confirmed'
        summary['pr'] = pr
        read_pr_back()
        lines, risk = summary['lines'], summary['risk']
        if outcome in ('checks-passed', 'passed') and pr:
            return {'status': 'pr opened', 'pr': pr, 'risk': risk, 'lines': lines, 'changes': changes}
        return {'status': 'needs a decision' if outcome == 'gate' else outcome, 'why': detail or outcome,
                'pr': pr, 'lines': lines, 'changes': changes}
    finally:
        # Once the gate owns the branch its run keeps using this worktree (its CI
        # monitor watches the PR), so it stays until a later night prunes it.
        if not keep_branch:
            for argv in (['git', 'worktree', 'remove', '--force', str(tree)], ['git', 'branch', '-D', branch]):
                try:
                    subprocess.run(argv, cwd=repo, capture_output=True, timeout=60)
                except subprocess.TimeoutExpired:
                    pass


def prune_instruction_trees(ctx, repo):
    """Remove earlier nights' instruction worktrees once their branch is an
    ancestor of origin/main, their PR is merged, or they are a week old."""
    merged = set(git(ctx, 'branch', '--merged', 'origin/main', '--format=%(refname:short)', cwd=repo, check=False).split())
    for path in sorted(ctx.dir.glob('firstmate-fm-dream-instructions-*')):
        day = path.name.rsplit('-instructions-', 1)[-1]
        branch = 'fm/dream-instructions-' + day
        try:
            old = (ctx.now - path.stat().st_mtime) > 7 * 86400
        except OSError:
            continue
        if day == ctx.day:
            continue
        landed = branch in merged
        if not landed and not old:
            try:
                r = ctx.run([os.environ.get('FM_DREAM_GH') or 'gh', 'pr', 'list', '--head', branch,
                             '--state', 'merged', '--json', 'number'], cwd=repo, timeout=60)
                prs = json.loads(r.stdout)
                landed = r.returncode == 0 and isinstance(prs, list) and bool(prs)
            except (OSError, subprocess.TimeoutExpired, ValueError):
                pass
        if landed or old:
            ctx.run(['git', 'worktree', 'remove', '--force', str(path)], cwd=repo, timeout=60)


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


def toon_row(line):
    """Fields of one TOON table row (comma-separated; quoted fields use backslash
    escapes), or None when the row is malformed."""
    fields, i, n = [], 0, len(line)
    while i <= n:
        if i < n and line[i] == '"':
            i, buf = i + 1, []
            while i < n and line[i] != '"':
                if line[i] == '\\' and i + 1 < n:
                    i += 1
                    buf.append({'n': '\n', 't': '\t'}.get(line[i], line[i]))
                else:
                    buf.append(line[i])
                i += 1
            if i >= n:
                return None
            i += 1
            if i < n and line[i] != ',':
                return None
            fields.append(''.join(buf))
        else:
            j = line.find(',', i)
            j = n if j < 0 else j
            fields.append(line[i:j])
            i = j
        i += 1
    return fields


def task_titles(out):
    """Titles of open rows in a `tasks-axi list` table, read by its own header:
    exactly the N rows `tasks[N]{...}:` announces (a `help[N]:` block follows
    with lines indented the same way). None when the table is short or a row
    cannot be decoded."""
    lines = out.splitlines()
    for i, line in enumerate(lines):
        head = re.match(r'^tasks\[(\d+)\]\{([^}]*)\}:', line)
        if head:
            break
    else:
        return None
    count, cols = int(head.group(1)), head.group(2).split(',')
    rows = lines[i + 1:i + 1 + count]
    if len(rows) != count:
        return None
    titles = []
    for line in rows:
        fields = toon_row(line.strip()) if line.startswith('  ') else None
        if fields is None or len(fields) != len(cols):
            return None
        row = dict(zip(cols, fields))
        if row.get('state') in ('queued', 'in_flight', 'held') and row.get('title'):
            titles.append(row['title'].split('\n')[0])
    return titles


def open_items(ctx, repos, owners):
    """(titles, unchecked): titles of open work to deduplicate against (this
    home's backlog and every included mate's, local ones read in place and remote
    ones over bin/fm-on.sh; open PRs on the harness repositories; what dreaming
    raised lately), and any sources that could not be read. Any unchecked
    source prevents the triage agent from running and nothing is filed blind."""
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
        rows = task_titles(r.stdout) if ok else None
        if rows is None:
            unchecked.add(mid)
        else:
            titles += rows
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
        except OSError as e:
            return None, 'Jev helper could not start (%s)' % e
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
            # strict=False: tasks-axi has been seen printing raw control
            # characters inside string values, and a plain json.loads would
            # reject a successful add.
            doc = json.loads(r.stdout, strict=False)
            key = (doc.get('task') or {}).get('id') or doc.get('id')
        except (ValueError, AttributeError):
            key = re.search(r'"id"\s*:\s*"([^"]+)"', r.stdout) or None
            key = key.group(1) if key else None
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


def step_memory(ctx):
    """The captain memory's nightly upkeep (bin/fm_captain_memory.py owns what it
    does). Its findings - new candidates, oversized files, repeats - go in the
    summary line; only a failure to run is not clean."""
    if ctx.dry_run:
        return {'status': 'dry-run'}
    stub = os.environ.get('FM_DREAM_CAPTAIN_MEMORY')
    argv = [stub] if stub else [sys.executable, str(SCRIPT_DIR / 'fm_captain_memory.py')]
    r = ctx.run(argv + ['upkeep', '--home', str(ctx.home)], timeout=120, env=dict(os.environ, FM_HOME=str(ctx.home)))
    line = next((ln for ln in reversed((r.stdout or '').splitlines()) if ln.startswith('captain-memory:')), '')
    if r.returncode or not line:
        return {'status': 'failed', 'why': ((r.stderr or r.stdout or '').strip() or 'no summary line')[:300]}
    ctx.facts['captain_memory'] = line
    return {'status': 'done', 'summary': line}


# --- run --------------------------------------------------------------------

CLEAN = ('done', 'merged', 'no changes', 'quiet day', 'nothing to file', 'dry-run', 'pr opened')  # anything else is not clean


def summary_line(run):
    skills, raised = run.get('skills') or [], run.get('raised') or []
    bad = [n for n, s in run['steps'].items() if s.get('status') not in CLEAN]
    text = 'Overnight: %s, %s.' % (
        '%d skill%s updated' % (len(skills), '' if len(skills) == 1 else 's') if skills else 'no skill changes',
        '%d fix%s raised' % (len(raised), '' if len(raised) == 1 else 'es') if raised else 'nothing raised')
    waited = sum(s.get('waited_for_ziggy', 0) for s in run['steps'].values())
    if waited >= 300:
        text += " Waited %d min for Ziggy's dream to finish." % round(waited / 60)
    ins = run.get('instructions')
    if ins:
        if ins.get('files') is not None:
            final = 'PR holds %s lines in %s' % (ins['lines'], ', '.join(ins['files'][:4]) or 'no files')
        elif ins.get('pr'):
            final = 'final PR diff unavailable'
        else:
            final = '%d lines' % ins['lines']
        text += ' Instructions: %s; proposed %s%s.' % (
            final, '; '.join('%s: %s' % (c.get('path'), c.get('what')) for c in ins['changes'][:3]),
            ' (PR %s%s)' % (ins['pr'], ', rated %s' % ins['risk'] if ins.get('risk') else '') if ins.get('pr') else '')
    if run.get('charter_proposals'):
        text += ' %d charter edit%s proposed (charters-%s.md).' % (
            len(run['charter_proposals']), '' if len(run['charter_proposals']) == 1 else 's', run['date'])
    odd = run.get('disagreements') or []
    if odd:
        text += ' %d home record%s (%s%s).' % (
            len(odd), ' disagrees' if len(odd) == 1 else 's disagree', odd[0][:120], '; and more' if len(odd) > 1 else '')
    nm = nm_summary(run.get('no_mistakes'))
    if nm:
        text += ' ' + nm[0].upper() + nm[1:] + '.'
    if run.get('captain_memory'):
        text += ' ' + run['captain_memory'][0].upper() + run['captain_memory'][1:] + '.'
    if bad:
        text += ' Did not run cleanly: %s.' % ', '.join('%s (%s)' % (n, run['steps'][n]['status']) for n in bad)
    return text


def raise_on_signal(signum, frame):
    """SIGTERM or SIGHUP becomes an exception, so the running subprocess group is
    ended and the lock released the same way as on Ctrl+C."""
    raise KeyboardInterrupt('signal %d' % signum)


def cmd_run(args):
    signal.signal(signal.SIGTERM, raise_on_signal)
    signal.signal(signal.SIGHUP, raise_on_signal)
    try:
        ctx = Ctx(args.home, args.dry_run)
    except ConfigError as e:
        print('fm-dream: %s' % e, file=sys.stderr)
        return 1
    # The kernel holds this lock for the whole run and drops it if the run dies.
    lock_fd = os.open(ctx.dir / '.lock', os.O_CREAT | os.O_WRONLY, 0o600)
    try:
        fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        os.close(lock_fd)
        print('fm-dream: another run is in progress', file=sys.stderr)
        return 1
    run = {'schema': 'fm-dream.v1', 'date': ctx.day, 'started': iso(ctx.now), 'dry_run': ctx.dry_run, 'steps': {}}
    log_path = ctx.dir / 'runs' / (ctx.day + ('.dry-run' if ctx.dry_run else '') + '.json')

    def finalize(force_partial=False):
        """The run record's final state, written the same way for a completed and
        an interrupted run: latest.json included, so a terminated night still
        leaves the report a summary instead of the previous night's."""
        run['finished'] = iso(time.time())
        run['skills'] = ctx.facts.get('skills', [])
        run['skills_commit'] = ctx.facts.get('skills_commit')
        run['raised'] = ctx.facts.get('raised', [])
        run['slow_commands'] = ctx.facts.get('slow_commands', [])
        run['counts'] = ctx.facts.get('counts', {})
        run['no_mistakes'] = ctx.facts.get('no_mistakes')
        run['disagreements'] = ctx.facts.get('disagreements', [])
        run['instructions'] = ctx.facts.get('instructions')
        run['charter_proposals'] = ctx.facts.get('charter_proposals', [])
        run['captain_memory'] = ctx.facts.get('captain_memory')
        run['status'] = ('done' if all(s.get('status') in CLEAN for s in run['steps'].values()) and not force_partial
                         else 'partial')
        run['summary'] = summary_line(run)
        write_json(log_path, run)
        if not ctx.dry_run and not args.only:
            write_json(ctx.dir / 'latest.json', {k: v for k, v in run.items() if k != 'steps'} | {
                'steps': {n: {k: v for k, v in s.items() if k in ('status', 'seconds', 'why', 'waited_for_ziggy', 'timings')}
                          for n, s in run['steps'].items()}})
        print(json.dumps({'summary': run['summary'], 'steps': {n: {k: v for k, v in s.items() if k != 'items'}
                                                               for n, s in run['steps'].items()}},
                         indent=1, ensure_ascii=False))

    interrupted = {'name': None, 'began': None}
    try:
        for name in args.only or STEPS:
            began = time.time()
            interrupted.update(name=name, began=began)
            why = room_for(name)
            began = time.time()  # the step's own time starts after any wait for Ziggy
            interrupted.update(began=began)
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
            if WAITED.get(name):
                run['steps'][name]['waited_for_ziggy'] = WAITED[name]
            if name == 'triage':
                run['steps'][name]['items'] = ctx.facts.get('triage', [])
            write_json(log_path, run)
        finalize()
        return 0
    except KeyboardInterrupt:
        # SIGTERM or SIGHUP (or Ctrl+C): the subprocess group was ended and the
        # lock released on the way out, but without this the run record would
        # keep its last per-step snapshot only and latest.json would keep the
        # previous night. The step in flight is interrupted; the ones that
        # completed keep what they earned, and the run is partial.
        if interrupted['name'] and interrupted['name'] not in run['steps']:
            run['steps'][interrupted['name']] = {
                'status': 'interrupted', 'seconds': round(time.time() - interrupted['began']),
                'why': str(sys.exc_info()[1])[:120] or 'interrupted'}
        finalize(force_partial=True)
        return 1
    finally:
        os.close(lock_fd)


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
