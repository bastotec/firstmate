#!/usr/bin/env python3
"""fm_report.py - the fleet and per-mate report, computed from firstmate's own records.

bin/fm-report.sh is the entry point and owns routing between homes; this file
owns the data, the JSON shape and the text rendering. Fleet Town's report
button, a second mate reading a peer's report, and Ziggy all read this one
generator, so a report is the same whether or not Fleet Town is open.

Sources (read-only; no agent turn and no model token is spent):
  - Each home's published state/home-summary.json (bin/fm-home-summary-refresh.sh):
    crew working now, open decisions, holds, and landed work with completion
    dates. A local home's file is read in place; a remote home's is fetched
    once over the existing route (bin/fm-on.sh, bridge files and reports
    flows) with the parent-side cached copy as fallback. The main home's own
    summary gives the first mate's crew and shipped work.
  - state/crew-time.log in every home (bin/fm-busy-event.sh owns its append
    format and best-effort writes). The primary reads its log directly;
    other homes publish busy intervals as crew_time in their home summary.
    Readers never trim the log. Time counts only busy spells, with no smoothing.
  - For the fleet scope only, proxai's quota table on the power host
    (config/power-host, default workload): `proxai quotas --detail --short`,
    gated on the bridge's maintenance flow. Unavailable power is named in
    power_error, separately from home-data gaps.
  - For fleet and primary scopes, state/dream/latest.json, published by
    bin/fm_dream.py; its header owns the fm-dream.v1 summary. The report projects
    the fields named below and renders them as an Overnight section in markdown.
    Only the latest published run is considered, with a six-hour grace period
    before the report window's start so an overnight run belongs to the morning.
    An absent, unreadable, invalid or older summary yields dream: null.

Commands:
  fm_report.py crew-time <state-dir>
      {since, intervals: [[task, start_epoch, end_epoch], ...]} for the last 8
      days, merged and capped at the latest 600 intervals; used by the home
      summary. An absent log is an empty history; any other log read OSError
      adds error (in words) with no intervals and still exits 0 so publication
      continues. Older producers may omit crew_time or publish null. Otherwise,
      intervals must be [str, int, int] triples, since may be absent, null or an
      int, and error may be absent, null or a str; bools are not ints. Reports
      name missing or unreadable crew time, a hit cap, or a window exceeding
      this coverage in gaps; the footer dates the earliest recorded history.
      A malformed crew_time makes its whole summary unreadable; remote reads
      fall back to a valid cached summary, and gaps names the affected home.
  fm_report.py report --home <main-home> --scope <fleet|primary|mate-id> [--days N] [--json]
      The report. --json prints the stable shape below; otherwise markdown.

JSON shape (schema fm-report.v1; new fields may be added, none removed):
  {schema, as_of, scope, scope_name, days, window: {from, to},
   headline, summary,
   shipped: [{title, pr, mate, task, date}],
   waiting: [{what, on, since, mate, task}],
   crew: [{agent, task, status, doing, mate}],
   time_worked: [{agent, task, mate, seconds}],
   crew_seconds, crew_time_since,
   mates: [{id, name, domain, machine, freshness, state, shipped, crew, working, waiting, crew_seconds}]   (fleet;
          state is the home summary's own state word)
   power: [{provider, pct_left, refills_at, tightest}], power_error           (fleet)
   domain, machine                                                       (non-fleet)
   dream: {date, status, summary, skills, skills_commit, raised, slow_commands, finished}
          or null                                                        (fleet, primary)
   gaps: [<what could not be read, in words>],
   inconsistencies: [<records a home read but found disagreeing, in words>]}
"""
import argparse
import datetime as dt
import json
import os
import re
import subprocess
import sys
import time
import hashlib
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
CREW_LOG = 'crew-time.log'
REGISTRY_ERRORS = []
CREW_DAYS = 8  # what each home publishes as crew_time
# Summary invalidities that mean records disagree rather than went unread.
INCONSISTENT_KINDS = ('orphan_in_flight', 'unowned_current', 'terminal_in_flight', 'unstructured_current')
STALE_AFTER = 900  # three home-summary refresh intervals
FETCH_TIMEOUT = int(os.environ.get('FM_REPORT_FETCH_TIMEOUT', '20'))
MAX_INTERVALS = 600  # keeps the published home summary well under its 256 KiB read bound


# --- crew time -------------------------------------------------------------

def read_crew_log(state_dir):
    """(rows, error): an absent log is an empty history; an unreadable one names why."""
    path = Path(state_dir) / CREW_LOG
    rows = []
    try:
        with open(path, encoding='utf-8', errors='replace') as fh:
            for line in fh:
                parts = line.rstrip('\n').split('\t')
                if len(parts) != 3 or not parts[0].isdigit():
                    continue
                rows.append((int(parts[0]), parts[1], parts[2]))
    except FileNotFoundError:
        return [], None
    except OSError as e:
        return [], 'state/%s could not be read (%s)' % (CREW_LOG, e.strerror or type(e).__name__)
    return rows, None


def crew_intervals(rows, start, now):
    """Busy intervals per task, clipped to [start, now]; overlapping or touching ones merge."""
    rows = sorted(rows, key=lambda r: r[0])  # stable: same-second events keep writer order
    open_since = {}
    out = []
    for ts, task, state in rows:
        if state == 'busy':
            open_since.setdefault(task, ts)
        elif task in open_since:
            out.append([task, open_since.pop(task), ts])
    for task, since in open_since.items():
        out.append([task, since, now])
    clipped = []
    for task, a, b in out:
        a, b = max(a, start), min(b, now)
        if b > a:
            clipped.append([task, a, b])
    clipped.sort(key=lambda r: (r[0], r[1]))
    merged = []
    for row in clipped:
        if merged and merged[-1][0] == row[0] and row[1] <= merged[-1][2]:
            merged[-1][2] = max(merged[-1][2], row[2])
        else:
            merged.append(row)
    merged.sort(key=lambda r: r[2])
    return merged[-MAX_INTERVALS:]


def crew_time(state_dir, days=8, now=None):
    now = int(now or time.time())
    start = now - days * 86400
    rows, error = read_crew_log(state_dir)
    since = min((r[0] for r in rows), default=None)
    out = {'since': since, 'intervals': crew_intervals(rows, start, now)}
    if error:
        out['error'] = error
    return out


# --- helpers -----------------------------------------------------------------

def local_midnight(now, days_back):
    day = dt.datetime.fromtimestamp(now).date() - dt.timedelta(days=days_back)
    return int(dt.datetime.combine(day, dt.time()).timestamp()), day


def iso(epoch):
    return dt.datetime.fromtimestamp(epoch, dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


def words_for(seconds):
    m = int(seconds) // 60
    return '%dh%02dm' % (m // 60, m % 60) if m >= 60 else '%dm' % m


def registry(home):
    """{id: {domain, machine, host, home}} from data/secondmates.md, parsed by
    bin/fm-secondmate-registry-lib.sh, the registry's one parser."""
    path = Path(home) / 'data' / 'secondmates.md'
    if not path.is_file():
        return {}
    script = ('. "$1"; while IFS= read -r line || [ -n "$line" ]; do '
              'if ! secondmate_registry_parse_line "$line" 2>/dev/null; then '
              'case "$line" in "- "*" - "*) printf "!\\t%s\\n" "${line:0:80}" ;; esac; continue; fi; '
              'printf "%s\\t%s\\t%s\\t%s\\n" "$SECONDMATE_REGISTRY_ID" "$SECONDMATE_REGISTRY_HOST" '
              '"$SECONDMATE_REGISTRY_HOME" "$SECONDMATE_REGISTRY_SCOPE"; done < "$2"')
    run = subprocess.run(['bash', '-c', script, '_', str(SCRIPT_DIR / 'fm-secondmate-registry-lib.sh'), str(path)],
                         capture_output=True, text=True, timeout=30)
    out = {}
    if run.returncode != 0:
        REGISTRY_ERRORS.append('the second-mate registry could not be read')
    for line in run.stdout.splitlines():
        mid, host, mhome, scope = (line.split('\t') + ['', '', '', ''])[:4]
        if mid == '!':
            REGISTRY_ERRORS.append('unreadable registry record: ' + host)
        elif mid:
            out[mid] = {'domain': scope.strip()[:300], 'machine': host or 'this Mac',
                        'host': host or None, 'home': mhome or None}
    return out


def resolve_scope(raw, mates):
    """fleet, primary, or an exact mate id; spaces read as dashes ("docana delivery")."""
    s = raw.strip().replace(' ', '-')
    if s in ('fleet', 'primary') or s in mates:
        return s
    return None


SUMMARY_LISTS = ('active_children', 'decisions_open', 'holds', 'queued', 'landed', 'endpoints', 'omitted')


def summary_valid(doc, home):
    """Validate report inputs, including the crew-time contract in this file's header."""
    if not (isinstance(doc, dict) and doc.get('schema') == 'fm-secondmate-home-summary.v1'
            and (home is None or doc.get('home') == home)):
        return False
    if not isinstance(doc.get('generated_epoch'), int) or not isinstance(doc.get('counts'), dict):
        return False
    if not all(isinstance(doc.get(k), list) and all(isinstance(r, dict) for r in doc[k]) for k in SUMMARY_LISTS):
        return False
    return crew_time_valid(doc.get('crew_time'))


def is_int(v):
    return isinstance(v, int) and not isinstance(v, bool)


def crew_time_valid(ct):
    """null from older producers, or the shape crew_time() publishes."""
    if ct is None:
        return True
    return (isinstance(ct, dict) and (ct.get('since') is None or is_int(ct['since']))
            and (ct.get('error') is None or isinstance(ct['error'], str))
            and isinstance(ct.get('intervals'), list)
            and all(isinstance(r, list) and len(r) == 3 and isinstance(r[0], str)
                    and is_int(r[1]) and is_int(r[2]) for r in ct['intervals']))


def read_json(path):
    try:
        with open(path, encoding='utf-8') as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def cached_summary(main_home, mid, host, home):
    """The parent-side copy bin/fm-fleet-snapshot.sh keeps of a remote home's summary."""
    key = hashlib.sha256(('%s\n%s\n%s\n' % (mid, host, home)).encode()).hexdigest()
    doc = read_json(Path(main_home) / 'state' / 'secondmate-summary-cache' / (key + '.json'))
    return doc if summary_valid(doc, home) else None


def fetch_summary(main_home, mid, info):
    """(summary, source) for one second mate, read-only; (None, why) when unreadable.

    A local home's own state/home-summary.json is read in place. A remote one is
    fetched once over the existing route (bin/fm-on.sh, bridge files+reports
    flows), falling back to the parent-side cached copy.
    """
    home = info.get('home')
    if not info.get('host'):
        doc = read_json(Path(home or '/nonexistent') / 'state' / 'home-summary.json')
        return (doc, 'local') if summary_valid(doc, home) else (None, 'no readable home summary')
    env = dict(os.environ, FM_HOME=str(main_home))
    env.pop('FM_STATE_OVERRIDE', None)
    try:
        run = subprocess.run([str(SCRIPT_DIR / 'fm-on.sh'), mid, 'fm-remote-file.sh', 'get',
                              'state/home-summary.json', '262144'], env=env, capture_output=True,
                             text=True, timeout=FETCH_TIMEOUT, stdin=subprocess.DEVNULL)
        doc = json.loads(run.stdout) if run.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        doc = None
    if summary_valid(doc, home):
        return doc, 'remote'
    doc = cached_summary(main_home, mid, info.get('host'), home)
    return (doc, 'cached') if doc else (None, 'remote summary unreadable and no cached copy')


# --- power -------------------------------------------------------------------

POWER_ROW = re.compile(
    r'^  (?P<acct>\S+)?\s+(?P<state>[A-Z]+)\s+(?P<used>\d+)%\s+(?P<label>.*?)'
    r'(?:\s{2,}(?P<resets>[A-Z][a-z]{2} \d{1,2} \d{2}:\d{2}Z))?\s*$')


def parse_power(text):
    providers, provider, account = {}, None, None
    for line in text.splitlines():
        if not line.strip() or line.startswith(('proxai', 'ACCOUNT')):
            continue
        if not line.startswith(' '):
            provider = line.strip()
            providers.setdefault(provider, {})
            continue
        lead = re.match(r'^  (\S+)', line)
        if lead:
            account = lead.group(1)
        m = POWER_ROW.match(line)
        if not m or provider is None:
            continue
        if m.group('acct'):
            account = m.group('acct')
        if 'model' in m.group('label'):
            continue
        providers[provider].setdefault(account, []).append(
            (int(m.group('used')), m.group('label').strip(), m.group('resets') or ''))
    out = []
    for name, accounts in providers.items():
        if not accounts:
            continue
        lefts, tight = [], None
        for acct, windows in accounts.items():
            used, label, resets = max(windows, key=lambda w: w[0])
            lefts.append(100 - used)
            if tight is None or 100 - used < tight[0]:
                tight = (100 - used, '%s %s' % (acct, label), resets)
        out.append({'provider': name, 'pct_left': round(sum(lefts) / len(lefts)),
                    'refills_at': tight[2] or None, 'tightest': tight[1]})
    return out


def read_power(home):
    host = 'workload'
    try:
        host = (Path(home) / 'config' / 'power-host').read_text().strip() or host
    except OSError:
        pass
    # A quota read is a budget probe, which bin/fm-bridge.py files under maintenance.
    env = dict(os.environ, FM_HOME=str(home))
    try:
        gate = subprocess.run([str(SCRIPT_DIR / 'fm-bridge.sh'), 'check', host, 'maintenance'],
                              env=env, capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return [], 'could not check the %s bridge' % host
    if gate.returncode != 0:
        return [], 'the %s bridge does not allow maintenance (quota reads)' % host
    try:
        run = subprocess.run(['ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', host,
                              'COLUMNS=200 ~/.local/bin/proxai quotas --detail --short'],
                             capture_output=True, text=True, timeout=40)
    except (OSError, subprocess.TimeoutExpired):
        return [], 'proxai on %s did not answer in time' % host
    power = parse_power(run.stdout)
    return power, (None if power else 'proxai on %s gave no quota table' % host)


# --- the report --------------------------------------------------------------

def landed_rows(rows):
    """Landed rows that pass bin/fm-landed-lib.sh's evidence rule, the same filter
    bin/fm-fleet-snapshot.sh applies to fresh and cached summaries."""
    if not rows:
        return []
    script = '. "$1"; jq -c "$FM_LANDED_JQ_DEFS"\' map(landed_completion | select(landed_summary_record))\''
    try:
        run = subprocess.run(['bash', '-c', script, '_', str(SCRIPT_DIR / 'fm-landed-lib.sh')],
                             input=json.dumps(rows), capture_output=True, text=True, timeout=30)
        return json.loads(run.stdout) if run.returncode == 0 else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def home_rows(rec, mate, start_day, crew_since_holder, gaps):
    """shipped, waiting, crew and crew intervals from one published home summary."""
    shipped, landed = [], landed_rows(rec.get('landed') or [])
    if landed is None:
        gaps.append('%s: shipped work could not be checked against the landed evidence rule' % mate)
    for row in landed or []:
        date = ((row.get('completion') or {}).get('date') or '')
        if date and date >= start_day.isoformat():
            shipped.append({'title': row.get('title') or row.get('id'), 'pr': row.get('pr_url'),
                            'mate': mate, 'task': row.get('id'), 'date': date})
    queued = {q.get('id'): q for q in rec.get('queued') or []}
    names = {c.get('id'): c.get('name') for c in rec.get('active_children') or [] if c.get('name')}
    names.update({h.get('id'): h.get('title') for h in rec.get('holds') or [] if h.get('title')})
    title = lambda tid: names.get(tid) or (queued.get(tid) or {}).get('title') or tid
    states = {e.get('id'): e.get('state') for e in rec.get('endpoints') or []}
    waiting, decided = [], {}

    def wait(tid, what, on):
        waiting.append({'what': what, 'on': on, 'since': (queued.get(tid) or {}).get('since'),
                        'mate': mate, 'task': tid})

    for row in rec.get('decisions_open') or []:
        # A backlog captain hold waits on the captain; a worker's open decision on
        # its own mate. Each key is its own question.
        decided.setdefault(row.get('id'), set()).add(row.get('source'))
        on = 'the captain' if row.get('source') == 'backlog' else mate
        wait(row.get('id'), row.get('summary') or title(row.get('id')), on)
    for row in rec.get('holds') or []:
        tid = row.get('id')
        # A hold is the same question as an open decision only when it waits on
        # that decision: a parked or blocked worker's decision, or a captain hold
        # with no dependency. A dependency or an external pause is its own wait.
        # Endpoints are bounded independently of holds; missing state cannot
        # prove redundancy, so keep that hold even with an open status decision.
        if row.get('source') == 'child-state' and states.get(tid) in ('parked', 'blocked'):
            same = 'status'
        elif row.get('source') == 'backlog' and not row.get('blocked_by'):
            same = 'backlog'
        else:
            same = None
        if same and same in decided.get(tid, ()):
            continue
        if row.get('blocked_by'):
            on = row['blocked_by']
        elif row.get('source') == 'child-state' and states.get(tid) == 'paused':
            on = 'an external wait: ' + (row.get('reason') or 'paused')
        elif row.get('source') == 'child-state':
            on = mate
        else:
            on = 'a hold: ' + (row.get('reason') or 'held')
        wait(tid, row.get('title') or title(tid), on)
    crew = []
    for row in rec.get('endpoints') or []:
        crew.append({'agent': row.get('id'), 'task': title(row.get('id')), 'status': row.get('state'),
                     'doing': next((c.get('doing') for c in rec.get('active_children') or []
                                    if c.get('id') == row.get('id')), None), 'mate': mate})
    ct = rec.get('crew_time') or {}
    if ct.get('since'):
        crew_since_holder.append(ct['since'])
    return shipped, waiting, crew, ct.get('intervals') or []


def worked(intervals, mate, start, now, names):
    totals = {}
    for task, a, b in intervals:
        a, b = max(int(a), start), min(int(b), now)
        if b > a:
            totals[task] = totals.get(task, 0) + (b - a)
    return [{'agent': t, 'task': names.get(t, t), 'mate': mate, 'seconds': s}
            for t, s in sorted(totals.items(), key=lambda kv: -kv[1])]


def build(home, scope_raw, days, now=None):
    now = int(now or time.time())
    days = max(1, int(days))
    start, start_day = local_midnight(now, days - 1)
    reg = registry(home)
    mates = sorted(reg)
    scope = resolve_scope(scope_raw, mates)
    if scope is None:
        raise LookupError('no second mate named %r (second mates: %s; or fleet, primary)' % (scope_raw, ', '.join(mates)))
    gaps, since, inconsistencies = list(REGISTRY_ERRORS), [], []
    wanted = mates if scope == 'fleet' else ([scope] if scope != 'primary' else [])
    with ThreadPoolExecutor(max_workers=8) as pool:
        fetched = dict(zip(wanted, pool.map(lambda m: fetch_summary(home, m, reg[m]), wanted)))

    def part(mid, rec, name, domain, machine, source):
        if rec is None:
            gaps.append('%s: %s' % (name, source))
            rec = {}
        else:
            if source == 'cached':
                gaps.append('%s: live summary unreachable, using the copy from %s' % (name, rec.get('generated')))
            elif now - int(rec.get('generated_epoch') or now) > STALE_AFTER:
                gaps.append('%s: summary is from %s' % (name, rec.get('generated')))
            if rec.get('valid') is False and rec.get('reason'):
                # A summary that could not read part of its home is a gap; one that
                # read everything and found records disagreeing is an inconsistency.
                kind = (rec.get('invalidity') or {}).get('kind')
                legacy_unknown = 'unknown_children' not in rec and rec.get('state') == 'unknown' \
                    and any(e.get('state') == 'unknown' for e in rec.get('endpoints') or [])
                if legacy_unknown:
                    # An older producer does not say which children went unread.
                    gaps.append('%s: summary incomplete (a child state may be unreadable: %s)' % (name, rec['reason']))
                elif rec.get('unknown_children'):
                    # Children whose state could not be read stay a read gap even when
                    # a disagreement was reported first.
                    gaps.append('%s: summary incomplete (child current state unavailable: %s)'
                                % (name, ', '.join(rec['unknown_children'])))
                if kind in INCONSISTENT_KINDS:
                    inconsistencies.append('%s: %s' % (name, rec['reason']))
                else:
                    gaps.append('%s: summary incomplete (%s)' % (name, rec['reason']))
            ct = rec.get('crew_time') or {}
            if rec.get('crew_time') is None:
                gaps.append('%s: crew time unavailable (its firstmate predates crew-time records)' % name)
            elif ct.get('error'):
                gaps.append('%s: crew time unreadable (%s)' % (name, ct['error']))
            elif len(ct.get('intervals') or []) >= MAX_INTERVALS:
                gaps.append('%s: crew time is partial (only its latest %d busy spells are published)' % (name, MAX_INTERVALS))
            elif start < int(rec.get('generated_epoch') or now) - CREW_DAYS * 86400:
                gaps.append('%s: crew time covers only the last %d days' % (name, CREW_DAYS))
            counts = rec.get('counts') or {}
            if counts.get('holds', 0) > len(rec.get('holds') or []):
                gaps.append('%s: %d more holds not listed' % (name, counts['holds'] - len(rec.get('holds') or [])))
            for o in rec.get('omitted') or []:
                if o.get('surface') in ('landed', 'endpoints', 'decisions_open', 'queued'):
                    gaps.append('%s: %d more %s not listed' % (name, o.get('count', 0), o['surface'].replace('_', ' ')))
        s, w, c, iv = home_rows(rec, mid, start_day, since, gaps)
        t = worked(iv, mid, start, now, {x['agent']: x['task'] for x in c})
        age = now - int(rec.get('generated_epoch') or now)
        return {'id': mid, 'name': name, 'domain': domain, 'machine': machine, 'state': rec.get('state'),
                'freshness': source if rec else 'unreadable', 'summary_age_seconds': age if rec else None,
                'shipped': s, 'waiting': w, 'crew': c, 'time_worked': t,
                'crew_seconds': sum(x['seconds'] for x in t)}

    def mate_part(mid):
        doc, source = fetched[mid]
        return part(mid, doc, mid.replace('-', ' '), reg[mid]['domain'], reg[mid]['machine'], source)

    def primary_part():
        doc = read_json(Path(home) / 'state' / 'home-summary.json')
        if not summary_valid(doc, None):
            doc = None
        else:
            doc = dict(doc, crew_time=crew_time(Path(home) / 'state', days=CREW_DAYS, now=now))
        return part('primary', doc, 'first mate', 'the whole fleet', 'this Mac',
                    'local' if doc else 'no readable home summary')

    parts = [primary_part()] + [mate_part(m) for m in mates] if scope == 'fleet' else \
        [primary_part() if scope == 'primary' else mate_part(scope)]
    flat = lambda key: [x for p in parts for x in p[key]]
    rep = {
        'schema': 'fm-report.v1', 'as_of': iso(now), 'scope': scope,
        'scope_name': 'the fleet' if scope == 'fleet' else parts[0]['name'],
        'days': days, 'window': {'from': iso(start), 'to': iso(now)},
        'shipped': flat('shipped'), 'waiting': flat('waiting'), 'crew': flat('crew'),
        'time_worked': sorted(flat('time_worked'), key=lambda x: -x['seconds']),
        'crew_seconds': sum(p['crew_seconds'] for p in parts),
        'crew_time_since': iso(min(since)) if since else None,
        'gaps': gaps, 'inconsistencies': inconsistencies,
    }
    if scope == 'fleet':
        rep['mates'] = [{k: p[k] for k in ('id', 'name', 'domain', 'machine', 'freshness', 'state', 'crew_seconds')}
                        | {'shipped': len(p['shipped']), 'crew': len(p['crew']), 'waiting': len(p['waiting']),
                           'working': sum(1 for c in p['crew'] if c['status'] == 'working')}
                        for p in parts]
        rep['power'], rep['power_error'] = read_power(home)
    else:
        rep['domain'] = parts[0]['domain']
        rep['machine'] = parts[0]['machine']
    if scope in ('fleet', 'primary'):
        rep['dream'] = read_dream(home, start)
    period = 'today' if days == 1 else 'the last %d days' % days
    rep['headline'] = '%s, %s: %d shipped, %d working now, %s crew time, %d waiting.' % (
        rep['scope_name'][0].upper() + rep['scope_name'][1:], period, len(rep['shipped']),
        sum(1 for c in rep['crew'] if c['status'] == 'working'), words_for(rep['crew_seconds']), len(rep['waiting']))
    power = rep.get('power') or []
    low = min(power, key=lambda p: p['pct_left']) if power else None
    rep['summary'] = rep['headline'] + (
        ' Tightest power: %s at %d%%.' % (low['provider'], low['pct_left']) if low else '')
    return rep


def read_dream(home, start):
    """The latest dreaming summary eligible for the report; the module header
    owns the projection and window rules. None when absent or unreadable."""
    try:
        with open(Path(home) / 'state' / 'dream' / 'latest.json', encoding='utf-8') as fh:
            doc = json.load(fh)
    except (OSError, ValueError):
        return None
    if not isinstance(doc, dict) or doc.get('schema') != 'fm-dream.v1':
        return None
    try:
        finished = dt.datetime.fromisoformat(str(doc.get('finished')).replace('Z', '+00:00')).timestamp()
    except ValueError:
        return None
    if finished < start - 6 * 3600:  # an overnight run belongs to the morning's "today"
        return None
    return {k: doc.get(k) for k in ('date', 'status', 'summary', 'skills', 'skills_commit', 'raised',
                                    'slow_commands', 'finished')}


def markdown(rep):
    out = ['# %s report - %s' % (rep['scope_name'], 'today' if rep['days'] == 1 else '%d days' % rep['days']),
           '', rep['headline'], '']
    if rep.get('domain'):
        out += ['Domain: %s (%s)' % (rep['domain'], rep.get('machine')), '']
    if rep.get('mates'):
        out += ['## Mates'] + ['- %s (%s): %d shipped, %d working, %d waiting, %s crew time%s' % (
            m['name'], m['machine'], m['shipped'], m['working'], m['waiting'], words_for(m['crew_seconds']),
            '' if m['freshness'] in ('fresh', None) else ', summary ' + str(m['freshness']))
            for m in rep['mates']] + ['']
    out += ["## What's waiting"] + (['- %s - on %s%s%s' % (
        w['what'], w['on'], ' (%s)' % w['mate'] if rep['scope'] == 'fleet' else '',
        ', since ' + w['since'] if w.get('since') else '') for w in rep['waiting']] or ['- nothing']) + ['']
    out += ['## The crew right now'] + (['- %s: %s - %s%s' % (
        c['agent'], c['task'], c['status'] or 'unknown', ' (%s)' % c['mate'] if rep['scope'] == 'fleet' else '')
        for c in rep['crew']] or ['- nobody working']) + ['']
    out += ['## What shipped'] + (['- %s%s%s' % (s['title'], ' - ' + s['pr'] if s.get('pr') else '',
                                                  ' (%s)' % s['mate'] if rep['scope'] == 'fleet' else '')
                                   for s in rep['shipped']] or ['- nothing yet']) + ['']
    out += ['## Time worked'] + (['- %s: %s' % (t['agent'], words_for(t['seconds'])) for t in rep['time_worked']]
                                 or ['- none recorded']) + ['']
    if rep.get('power') or rep.get('power_error'):
        out += ['## Power'] + ['- %s: %d%% left%s (tightest: %s)' % (
            p['provider'], p['pct_left'], ', refills ' + p['refills_at'] if p['refills_at'] else '', p['tightest'])
            for p in rep.get('power') or []] + (['- unread: ' + rep['power_error']] if rep.get('power_error') else []) + ['']
    if rep.get('dream'):
        d = rep['dream']
        out += ['## Overnight', '- ' + (d.get('summary') or 'fleet dreaming ran')]
        out += ['- skill %s: %s' % (c.get('skill'), c.get('what')) for c in d.get('skills') or []]
        out += ['- raised for %s: %s%s' % (r.get('mate'), r.get('title'), ' (%s)' % r['key'] if r.get('key') else '')
                for r in d.get('raised') or []]
        out += ['- slow: %s up to %ss (%d calls)' % (c['command'], c['seconds'], c['count'])
                for c in (d.get('slow_commands') or [])[:3]] + ['']
    foot = 'Crew time comes from firstmate\'s own busy records%s.' % (
        ' since ' + rep['crew_time_since'] if rep.get('crew_time_since') else ' (none recorded yet)')
    if rep.get('inconsistencies'):
        out += ['## Records that disagree'] + ['- ' + x for x in rep['inconsistencies']] + ['']
    out += ['_As of %s. %s%s_' % (rep['as_of'], foot, (' Unread: ' + '; '.join(rep['gaps'])) if rep['gaps'] else '')]
    return '\n'.join(out) + '\n'


def main(argv):
    p = argparse.ArgumentParser(prog='fm_report.py')
    sub = p.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('crew-time')
    c.add_argument('state')
    r = sub.add_parser('report')
    r.add_argument('--home', required=True)
    r.add_argument('--scope', required=True)
    r.add_argument('--days', type=int, default=1)
    r.add_argument('--json', action='store_true')
    a = p.parse_args(argv)
    if a.cmd == 'crew-time':
        print(json.dumps(crew_time(a.state, CREW_DAYS)))
        return 0
    try:
        rep = build(a.home, a.scope, a.days)
    except LookupError as e:
        print('error: %s' % e.args[0], file=sys.stderr)
        return 1
    except (RuntimeError, subprocess.TimeoutExpired, ValueError) as e:
        print('error: %s' % e, file=sys.stderr)
        return 1
    sys.stdout.write(json.dumps(rep, indent=1) + '\n' if a.json else markdown(rep))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
