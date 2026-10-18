#!/usr/bin/env python3
"""fm_lifecycle.py - each task's day, from start to deploy, for fleet dreaming.

bin/fm_dream.py's lifecycle step uses this module; it can also be run alone
(`fm_lifecycle.py timeline ...`, below) to print one host's timelines.

A task is one branch of work, measured from the records that carry timestamps:
  - the no-mistakes database on each machine (runs, their step results, fix
    rounds, parked time, CI readiness, PR url, errors), read with HOST_PY;
  - the task records of each firstmate home on that machine: backlog and
    done-archive ids (data/backlog.md, data/done-archive.md) say which branches
    are mate tasks (fm/<task id>), and a live task's state/<id>.meta spawn_gen
    gives its spawn time, its state/<id>.status its current waits (captain-held,
    blocked, needs-decision, paused) and state/<id>.control-relaunch a relaunch;
  - GitHub for each PR's creation, merge and first commit times;
  - the main home's auto-land log for the deploy after a firstmate merge.
When the captain asked for a task is not recorded per task, so a task's start is
the earliest of its spawn, its first commit and its first no-mistakes run, and
the report says so.

Runs on branches that are no mate task (Claude sessions and anything unlisted)
are the benchmark ("session" kind). A run's branch groups with the same name
without a trailing -<n> retry suffix, unless that name is a task id itself.
Only runs created or updated in the window count.

Where a task's time went (seconds), per task and summed by category:
  implementation   start to its first no-mistakes run
  <step>           each pipeline step's recorded duration over all runs
                   (review, test, ci, ...); these include gate waits inside a step
  parked at a gate the runs' parked time
  rework           gaps between one run ending and the next starting
  waiting to merge from CI ready (or the last run's end) to the merge
  deploy           from the merge to the auto-land deploy
Waits without timestamps (holds, blocks, relaunches, model gateway errors) are
counted, not timed.

    fm_lifecycle.py timeline --db DB --home H [--home H ...] --since EPOCH --now EPOCH
                             [--gh BIN] [--autoland-log FILE]
"""
import argparse
import json
import os
import re
import statistics
import subprocess
import sys

# Run on each host with python3: `python3 - <db> <since> <homes JSON>`; prints
# {runs: [...], tasks: {id: {...}}, unread: [...]}. Missing tables or columns
# are read as absent, never guessed.
HOST_PY = r"""
import glob, json, os, re, sqlite3, sys
db, since, homes = os.path.expanduser(sys.argv[1]), int(sys.argv[2]), json.loads(sys.argv[3])
GATEWAY = re.compile(r'upstream_error|gateway|HTTP 5\d\d|429|overloaded|rate.?limit|no project-owned enrollment', re.I)
def sec(v):
    return (v / 1000 if v > 1e12 else v) if isinstance(v, (int, float)) and v else None
out = {'runs': [], 'tasks': {}, 'unread': []}
for home in homes:
    home = os.path.expanduser(home)
    for name in ('backlog.md', 'done-archive.md'):
        try:
            text = open(os.path.join(home, 'data', name), encoding='utf-8', errors='replace').read()
        except FileNotFoundError:
            continue
        except OSError:
            out['unread'].append('%s/data/%s' % (home, name))
            continue
        for m in re.finditer(r'^- \[[ x]\] ([A-Za-z0-9._-]+) ', text, re.M):
            out['tasks'].setdefault(m.group(1), {})
    for meta in glob.glob(os.path.join(home, 'state', '*.meta')):
        tid = os.path.basename(meta)[:-5]
        task = out['tasks'].setdefault(tid, {})
        try:
            body = open(meta, encoding='utf-8', errors='replace').read()
        except OSError:
            continue
        m = re.search(r'^spawn_gen=s(\d{9,})', body, re.M)
        if m:
            task['spawn'] = int(m.group(1))
        try:
            status = open(os.path.join(home, 'state', tid + '.status'), encoding='utf-8', errors='replace').read()
            task['waits'] = sorted({w for w in ('captain-held', 'blocked', 'needs-decision', 'paused')
                                    if re.search(r'^%s\b' % w, status, re.M)})
        except OSError:
            pass
        if os.path.exists(os.path.join(home, 'state', tid + '.control-relaunch')):
            task['relaunches'] = 1
if os.path.isfile(db):
    try:
        con = sqlite3.connect('file:%s?mode=ro' % db, uri=True, timeout=5)
        tables = {r[0] for r in con.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        cols = {r[1] for r in con.execute('PRAGMA table_info(runs)')}
        pick = [c for c in ('id', 'branch', 'status', 'created_at', 'updated_at', 'parked_ms', 'ci_ready_at',
                            'pr_url', 'error', 'repo_id') if c in cols]
        repos = {}
        if 'repos' in tables and 'working_path' in {r[1] for r in con.execute('PRAGMA table_info(repos)')}:
            repos = dict(con.execute('SELECT id, working_path FROM repos'))
        runs = {}
        for row in con.execute('SELECT %s FROM runs WHERE MAX(created_at, updated_at) >= ?' % ', '.join(pick)
                               if {'created_at', 'updated_at'} <= cols else 'SELECT %s FROM runs WHERE 0' % ', '.join(pick),
                               (since,)):
            r = dict(zip(pick, row))
            if max(sec(r.get('created_at')) or 0, sec(r.get('updated_at')) or 0) < since:
                continue
            runs[r['id']] = {'id': r['id'], 'branch': r.get('branch') or '', 'status': r.get('status') or '',
                             'created': sec(r.get('created_at')), 'updated': sec(r.get('updated_at')),
                             'parked': round((r.get('parked_ms') or 0) / 1000), 'ci_ready': sec(r.get('ci_ready_at')),
                             'pr': r.get('pr_url') or None, 'repo': repos.get(r.get('repo_id')) or '',
                             'steps': {}, 'fix_rounds': 0,
                             'gateway_errors': 1 if GATEWAY.search(r.get('error') or '') else 0}
        if 'step_results' in tables and runs:
            ids = list(runs)
            marks = ','.join('?' * len(ids))
            for run_id, name, ms, error in con.execute(
                    'SELECT run_id, step_name, duration_ms, error FROM step_results WHERE run_id IN (%s)' % marks, ids):
                steps = runs[run_id]['steps']
                steps[name] = steps.get(name, 0) + round((ms or 0) / 1000)
                if GATEWAY.search(error or ''):
                    runs[run_id]['gateway_errors'] += 1
            if 'step_rounds' in tables:
                for run_id, n in con.execute(
                        "SELECT s.run_id, COUNT(*) FROM step_rounds r JOIN step_results s ON s.id = r.step_result_id "
                        "WHERE s.run_id IN (%s) AND r.trigger_type != 'initial' GROUP BY s.run_id" % marks, ids):
                    runs[run_id]['fix_rounds'] = n
        con.close()
        out['runs'] = sorted(runs.values(), key=lambda r: r['created'] or 0)
    except sqlite3.Error as e:
        out['unread'].append('no-mistakes state (%s)' % e)
print(json.dumps(out))
"""

WAIT_STEPS = ('implementation', 'parked at a gate', 'rework', 'waiting to merge', 'deploy')


def host_data(db, since, homes, run=None, ssh=None):
    """HOST_PY's output for one machine: run locally, or remotely through the
    `ssh` argv prefix. None when it cannot be read."""
    argv = (ssh or []) + ['python3', '-', db, str(int(since)), json.dumps([str(h) for h in homes])]
    if ssh:  # the remote shell joins arguments, so quote them for it
        argv = ssh + [' '.join(["'%s'" % a.replace("'", "'\\''") for a in argv[len(ssh):]])]
    try:
        r = (run or _run)(argv, input=HOST_PY, timeout=90)
        return json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def _run(argv, input=None, timeout=None):
    return subprocess.run(argv, input=input, capture_output=True, text=True, timeout=timeout)


def task_key(branch, tasks):
    name = branch[3:] if branch.startswith('fm/') else branch
    if name in tasks:
        return name, 'mate'
    base = re.sub(r'-\d+$', '', name)
    return (base, 'mate') if base in tasks else (base, 'session')


def pr_facts(url, gh='gh', run=None):
    """{opened, merged, first_commit, state} for one PR url, or None."""
    try:
        r = (run or _run)([gh, 'pr', 'view', url, '--json', 'createdAt,mergedAt,state,commits'], timeout=30)
        doc = json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None
    if not isinstance(doc, dict):
        return None
    commits = [c.get('authoredDate') or c.get('committedDate') for c in doc.get('commits') or [] if isinstance(c, dict)]
    stamps = [t for t in (parse_iso(c) for c in commits) if t]
    return {'opened': parse_iso(doc.get('createdAt')), 'merged': parse_iso(doc.get('mergedAt')),
            'first_commit': min(stamps) if stamps else None, 'state': doc.get('state')}


def parse_iso(text):
    import datetime as dt
    try:
        return dt.datetime.fromisoformat(str(text).replace('Z', '+00:00')).timestamp() if text else None
    except ValueError:
        return None


def deploys(log_text):
    """{pr url: deploy epoch} from auto-land's report.log: the first 'deployed
    <repo>' line after each 'merged <url>' line for that repository."""
    out, pending = {}, {}
    for line in log_text.splitlines():
        m = re.match(r'^(\S+Z) autoland: (?:merged (https://\S+/([^/\s]+)/pull/\d+)|deployed ([^\s:]+))', line)
        if not m:
            continue
        when = parse_iso(m.group(1))
        if m.group(2):
            pending.setdefault(m.group(3), []).append(m.group(2))
        elif when:
            for url in pending.pop(m.group(4), []):
                out[url] = when
    return out


def timelines(host, data, now, prs=None, deployed=None):
    """One record per task on one host, from HOST_PY output and PR facts."""
    tasks, groups = data.get('tasks') or {}, {}
    for r in data.get('runs') or []:
        key, kind = task_key(r['branch'], tasks)
        groups.setdefault((key, kind), []).append(r)
    out = []
    for (key, kind), runs in groups.items():
        runs.sort(key=lambda r: r['created'] or 0)
        info = tasks.get(key, {}) if kind == 'mate' else {}
        pr = next((r['pr'] for r in reversed(runs) if r.get('pr')), None)
        facts = (prs or {}).get(pr) or {}
        starts = [t for t in (info.get('spawn'), facts.get('first_commit'), runs[0]['created']) if t]
        start = min(starts)
        merged = facts.get('merged')
        end = merged or now
        steps = {}
        for r in runs:
            for name, s in r['steps'].items():
                steps[name] = steps.get(name, 0) + s
        sinks = dict(steps)
        sinks['implementation'] = max(0, (runs[0]['created'] or start) - start)
        sinks['parked at a gate'] = sum(r['parked'] for r in runs)
        sinks['rework'] = sum(max(0, (b['created'] or 0) - (a['updated'] or 0)) for a, b in zip(runs, runs[1:]))
        ready = max([r['ci_ready'] for r in runs if r.get('ci_ready')] or [runs[-1]['updated'] or start])
        if merged:
            sinks['waiting to merge'] = max(0, merged - ready)
        dep = (deployed or {}).get(pr) if pr else None
        if dep and merged:
            sinks['deploy'] = max(0, dep - merged)
        out.append({
            'host': host, 'task': key, 'kind': kind, 'branches': sorted({r['branch'] for r in runs}),
            'start': start, 'start_from': 'spawn' if info.get('spawn') == start else
            ('first commit' if facts.get('first_commit') == start else 'first run'),
            'first_run': runs[0]['created'], 'pr': pr, 'pr_opened': facts.get('opened'),
            'ci_ready': ready if any(r.get('ci_ready') for r in runs) else None, 'merged': merged,
            'deployed': dep, 'open': not merged, 'seconds': round(end - start),
            'runs': len(runs), 'failed_runs': sum(1 for r in runs if r['status'] in ('failed', 'cancelled')),
            'fix_rounds': sum(r['fix_rounds'] for r in runs),
            'gateway_errors': sum(r['gateway_errors'] for r in runs),
            'waits': info.get('waits') or [], 'relaunches': info.get('relaunches', 0),
            'sinks': {k: round(v) for k, v in sorted(sinks.items(), key=lambda kv: -kv[1]) if v >= 1}})
    return out


def pct(values, q):
    """The q-th percentile (nearest rank) of values, or None."""
    vals = sorted(values)
    if not vals:
        return None
    return vals[min(len(vals) - 1, max(0, int(round(q / 100 * len(vals) + 0.5)) - 1))]


def metrics(items):
    """The night's numbers: start to merge for merged mate tasks and the session
    benchmark, the slowest mate tasks and the top time sinks."""
    def merged(kind):
        return [t['seconds'] for t in items if t['kind'] == kind and t['merged']]

    def commit_to_merge(kind):
        return [round(t['merged'] - (t['first_run'] if t['start_from'] == 'spawn' else t['start']))
                for t in items if t['kind'] == kind and t['merged']]
    mates = [t for t in items if t['kind'] == 'mate']
    sinks = {}
    for t in mates:
        for k, v in t['sinks'].items():
            sinks[k] = sinks.get(k, 0) + v
    out = {'tasks': len(mates), 'sessions': sum(1 for t in items if t['kind'] == 'session')}
    for kind, name in (('mate', 'mate'), ('session', 'session')):
        vals = merged(kind)
        out[name] = {'merged': len(vals), 'open': sum(1 for t in items if t['kind'] == kind and not t['merged']),
                     'median': round(statistics.median(vals)) if vals else None, 'p90': pct(vals, 90),
                     'run_to_merge_median': round(statistics.median(commit_to_merge(kind))) if vals else None}
    out['slowest'] = [{'task': t['task'], 'host': t['host'], 'seconds': t['seconds'], 'open': t['open'],
                       'pr': t['pr'], 'top': list(t['sinks'].items())[:3], 'waits': t['waits']}
                      for t in sorted(mates, key=lambda t: -t['seconds'])[:5]]
    out['sinks'] = sorted(sinks.items(), key=lambda kv: -kv[1])[:6]
    out['counted'] = {'fix_rounds': sum(t['fix_rounds'] for t in mates),
                      'failed_runs': sum(t['failed_runs'] for t in mates),
                      'gateway_errors': sum(t['gateway_errors'] for t in items),
                      'relaunches': sum(t['relaunches'] for t in mates),
                      'held_or_blocked': sum(1 for t in mates if t['waits'])}
    return out


def human(seconds):
    if seconds is None:
        return 'n/a'
    seconds = int(seconds)
    if seconds < 3600:
        return '%dm' % round(seconds / 60)
    return '%.1fh' % (seconds / 3600)


def digest(m, items, unread, limit=6000):
    """The bounded text the reflection reads and the night's digest section."""
    lines = ['Mate tasks: %d (%d merged, %d open); start to merge median %s, p90 %s; first run to merge median %s.' % (
        m['tasks'], m['mate']['merged'], m['mate']['open'], human(m['mate']['median']), human(m['mate']['p90']),
        human(m['mate']['run_to_merge_median'])),
        'Benchmark, Claude-session and other branches: %d (%d merged); start to merge median %s, p90 %s.' % (
        m['sessions'], m['session']['merged'], human(m['session']['median']), human(m['session']['p90'])),
        'Start is the earliest of spawn, first commit and first no-mistakes run; when the captain asked is not recorded per task.',
        'Top time sinks over mate tasks: ' + (', '.join('%s %s' % (k, human(v)) for k, v in m['sinks']) or 'none'),
        'Counted: %(fix_rounds)d fix rounds, %(failed_runs)d failed or cancelled runs, %(gateway_errors)d model gateway '
        'errors, %(relaunches)d relaunches, %(held_or_blocked)d tasks held, blocked or waiting on a decision.' % m['counted'],
        'Slowest mate tasks:']
    for s in m['slowest']:
        lines.append('- %s (%s): %s%s; %s%s%s' % (
            s['task'], s['host'], human(s['seconds']), ', still open' if s['open'] else '',
            ', '.join('%s %s' % (k, human(v)) for k, v in s['top']) or 'no recorded stages',
            '; now ' + ', '.join(s['waits']) if s['waits'] else '', '; ' + s['pr'] if s['pr'] else ''))
    lines.append('Every mate task:')
    for t in sorted((t for t in items if t['kind'] == 'mate'), key=lambda t: -t['seconds']):
        lines.append('- %s: %s, %d runs, %d failed, %d fix rounds%s' % (
            t['task'], human(t['seconds']), t['runs'], t['failed_runs'], t['fix_rounds'], ', open' if t['open'] else ''))
    if unread:
        lines.append('Unread: ' + '; '.join(unread))
    text = '\n'.join(lines)
    return text if len(text) <= limit else text[:limit - 20] + '\n[truncated]'


def main(argv):
    p = argparse.ArgumentParser(prog='fm_lifecycle.py')
    sub = p.add_subparsers(dest='cmd', required=True)
    t = sub.add_parser('timeline')
    t.add_argument('--db', required=True)
    t.add_argument('--home', action='append', required=True)
    t.add_argument('--since', type=float, required=True)
    t.add_argument('--now', type=float, required=True)
    t.add_argument('--gh', default='gh')
    t.add_argument('--autoland-log')
    a = p.parse_args(argv)
    data = host_data(a.db, a.since, a.home, run=lambda argv, **kw: _run([sys.executable] + argv[1:], **kw))
    if data is None:
        print('fm_lifecycle: the host data could not be read', file=sys.stderr)
        return 1
    prs = {r['pr']: pr_facts(r['pr'], a.gh) for r in data['runs'] if r.get('pr')}
    dep = {}
    if a.autoland_log and os.path.isfile(a.autoland_log):
        dep = deploys(open(a.autoland_log, encoding='utf-8', errors='replace').read())
    items = timelines('this Mac', data, a.now, prs, dep)
    m = metrics(items)
    print(json.dumps({'timelines': items, 'metrics': m, 'unread': data['unread'],
                      'digest': digest(m, items, data['unread'])}, indent=1))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
