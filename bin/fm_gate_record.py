#!/usr/bin/env python3
"""fm_gate_record.py - keep state/<id>.gate: the gate a parked validation run waits at.

Reads one `no-mistakes axi status` (TOON) on stdin, the same read that
bin/fm-task-state-lib.sh's crew_state_publish turns into state/<id>.crew-state,
and keeps the gate it shows as JSON next to it, so Fleet Town and the
parked-run rules read the findings without asking no-mistakes again:

  {"version": 1, "run": "01M...", "step": "review", "status": "awaiting_approval",
   "risk": "high", "risk_rationale": "...", "parked_since": 1792161477,
   "repair_budget_exhausted": false,
   "findings": [{"id": "R1", "severity": "warning", "file": "a.py",
                 "action": "ask-user", "description": "..."}],
   "finding_ids": ["R1"], "recommendation": null}

parked_since is the Unix time in seconds when this run was first seen parked
at this step; it is kept across rewrites and restarts when the run or step changes.
finding_ids contains every finding's id in input order, including findings
omitted from the bounded findings list.
repair_budget_exhausted reports a repair-budget marker finding or help saying
the repair budget or authority is exhausted; it is not permission to repair.
recommendation starts null: a mate's triage may fill it in, and the publisher
keeps it only while the run, step and complete finding_ids list are unchanged.

Publication feeds this writer only a successful full attributed status read.
A gate in that read keeps the record; a run without a gate removes it.
Failed or timed-out queries, no attributed run, and coarse ledger fallbacks
leave an existing gate record alone, unlike the crew-state record.
Current-state verdict overrides do not decide its lifetime.
Readers must match it to a parked crew-state for the same run and step.
The publisher ignores writer failures, so they never fail crew-state publication.

Usage: fm_gate_record.py <gate-file> [--clear]
  --clear, or input without a run id or gate, removes the file.
  Writes use an atomic temp+rename with mode 0600; unchanged records retain mtime.
  The publisher and writer leave symlinks alone, including on --clear.
  bin/fm-teardown.sh removes the path (symlink or not) with <id>.crew-state,
  including when retiring a secondmate home's children.

Regression coverage: tests/fm-gate-record.test.sh and tests/fm-crew-state.test.sh.
"""
import json
import os
import re
import sys
import tempfile
import time

MAX_FINDINGS = 20
MAX_TEXT = 2000


def value(raw):
    """A TOON scalar: a JSON string when quoted, else the bare word."""
    raw = raw.strip()
    if raw.startswith('"'):
        try:
            return json.loads(raw)
        except ValueError:
            return raw.strip('"')
    return raw


def row(line):
    """One tabular TOON row: comma-separated cells, quoted cells JSON-escaped."""
    cells, i, n = [], 0, len(line)
    dec = json.JSONDecoder()
    while i <= n:
        if i < n and line[i] == '"':
            try:
                s, end = dec.raw_decode(line, i)
            except ValueError:
                s, end = line[i + 1:], n
            cells.append(s)
            i = end
            if i < n and line[i] == ',':
                i += 1
            elif i >= n:
                break
            continue
        j = line.find(',', i)
        if j < 0:
            cells.append(line[i:])
            break
        cells.append(line[i:j])
        i = j + 1
    return cells


def table(lines, i, indent):
    """A tabular block whose header is lines[i]: its rows as dicts, and the index after it."""
    m = re.match(r'^\s*\w+\[\d+\]\{([^}]*)\}:\s*$', lines[i])
    names, out = m.group(1).split(','), []
    i += 1
    while i < len(lines) and lines[i].startswith(' ' * indent) and lines[i].strip():
        cells = row(lines[i].strip())
        out.append({k: (cells[n] if n < len(cells) else '') for n, k in enumerate(names)})
        i += 1
    return out, i


def parse(text):
    """The run id and the gate a parked run waits at, or (run, None). Both response shapes are
    read: a `gate:` block (step, status, risk, ...) or a scalar `gate: <step>`, with the findings
    table under `gate:` or under `run:`, and the step status from the gate or the steps table."""
    lines = text.splitlines()
    run, gate, scalar, findings, steps, run_status, budget = '', None, '', [], {}, '', False
    i, block = 0, ''
    while i < len(lines):
        line = lines[i]
        top = re.match(r'^([a-z_]+)(\[\d+\]\{[^}]*\})?:\s*(.*)$', line)
        if top:
            name, tab, rest = top.groups()
            if tab and name == 'steps':
                rows, i = table(lines, i, 2)
                steps = {r.get('step', ''): r.get('status', '') for r in rows}
                continue
            if name == 'gate':
                if rest.strip():
                    scalar = str(value(rest))
                else:
                    gate = gate or {}
            if name == 'help' or line.startswith('help['):
                if re.search(r'repair (budget|authority)[^.]*exhausted', line, re.I):
                    budget = True
            block = name
            i += 1
            continue
        if line.startswith('help[') and re.search(r'repair (budget|authority)[^.]*exhausted', line, re.I):
            budget = True
        sub = re.match(r'^  (\w+)(\[\d+\]\{[^}]*\})?:\s*(.*)$', line)
        if sub and block in ('run', 'gate'):
            key, tab, rest = sub.groups()
            if tab and key == 'steps':
                # a steps table under run: (or gate:) reads like the top-level one
                rows, i = table(lines, i, 4)
                steps.update({r.get('step', ''): r.get('status', '') for r in rows})
                continue
            if tab and key == 'findings':
                rows, i = table(lines, i, 4)
                findings = rows if block == 'gate' or not findings else findings
                continue
            if block == 'run' and key == 'id':
                run = str(value(rest))
            elif block == 'run' and key == 'status':
                run_status = str(value(rest))
            elif block == 'gate' and gate is not None:
                gate[key] = value(rest)
        i += 1
    if gate is None and scalar:
        gate = {'step': scalar}
    if gate is None:
        return run, None
    step = str(gate.get('step', ''))
    if not gate.get('status'):
        gate['status'] = steps.get(step) or run_status
    gate['findings'] = findings
    gate['_budget'] = budget or any(str(f.get('id', '')).startswith('repair-budget') for f in findings)
    return run, gate


def clip(s, n):
    s = str(s or '')
    return s if len(s) <= n else s[:n - 3] + '...'


def record(run, gate, previous, now):
    findings = [{k: clip(f.get(k, ''), MAX_TEXT if k == 'description' else 300) for k in ('id', 'severity', 'file', 'action', 'description')} for f in gate['findings']]
    if len(findings) > MAX_FINDINGS:
        # the repair-budget marker says the review cannot fix more: kept whatever is cut
        marker = [f for f in findings[MAX_FINDINGS:] if f['id'].startswith('repair-budget')]
        findings = findings[:MAX_FINDINGS - len(marker[:1])] + marker[:1]
    step = str(gate.get('step', ''))
    same = isinstance(previous, dict) and previous.get('run') == run and previous.get('step') == step
    # every finding's id, the ones clipped away included: a recommendation holds only for these
    ids = [str(f.get('id', '')) for f in gate['findings']]
    rec = previous.get('recommendation') if same and previous.get('finding_ids') == ids else None
    return {
        'version': 1, 'run': run, 'step': step, 'status': str(gate.get('status', '')),
        'risk': clip(gate.get('risk', ''), 20), 'risk_rationale': clip(gate.get('risk_rationale', ''), 600),
        'parked_since': previous.get('parked_since') if same and previous.get('parked_since') else now,
        'repair_budget_exhausted': bool(gate.get('_budget')),
        'findings': findings, 'finding_ids': ids, 'recommendation': rec,
    }


def write(path, data):
    d = os.path.dirname(path) or '.'
    fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(path) + '.', dir=d)
    try:
        with os.fdopen(fd, 'w') as f:
            json.dump(data, f, sort_keys=True)
            f.write('\n')
        os.replace(tmp, path)
    except BaseException:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def main(argv):
    if not argv or argv[0].startswith('-'):
        sys.stderr.write(__doc__)
        return 2
    path = argv[0]
    # a symlink in its place is not this record: left alone
    if os.path.islink(path):
        return 0
    if '--clear' in argv[1:]:
        run, gate = '', None
    else:
        run, gate = parse(sys.stdin.read())
    if gate is None or not run:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
        return 0
    try:
        with open(path) as f:
            previous = json.load(f)
    except (OSError, ValueError):
        previous = {}
    data = record(run, gate, previous, int(time.time()))
    # unchanged but for nothing: leave the file (and its mtime) alone
    if data == previous:
        return 0
    write(path, data)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
