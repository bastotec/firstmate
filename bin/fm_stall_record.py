#!/usr/bin/env python3
"""Conservative stalled-task timing shared by idle scans and recovery snapshots.

Usage: fm_stall_record.py RECORD META CURRENT_LINE OPEN_DECISIONS [--observe|--ack|--reported-run] [--now EPOCH]
OPEN_DECISIONS is the fm-classify-lib.sh status_open_decisions TSV contract.
Read mode has no side effects; the idle sweep uses --observe and the parked-run
publication owner uses --ack under the idle sweep's scan and admission locks.
RECORD lives in state/idle-sweep/<id>.stall.json.
The JSON projection reports state=stalled strictly after 7200 seconds of
implementation without an attributed validation run, or 3600 seconds of an open
needs-decision reconciled with a parked current state across task kinds and modes.
--state-dir and --task-id select existing timing evidence, including for captured
metadata in recovery snapshots. Matching gate/parked-run records supply decision
entry time; otherwise a matching last decision event supplies a lower bound.
Implementation timing applies only to no-mistakes ships working from pane,
status-log, or the state owner's proven replacement evidence, never to genuinely
running validation. It starts at spawn epoch (or metadata mtime), bounded below
by attributed run creation evidence, including retained historical validation
that finished between observations. The state owner emits last-run-created only
for a terminal same-branch run whose head is an ancestor of the task's current
head; it does not relax current-state attribution or add timing persistence.
last_run_seen retains attributed creation timing across observations; reconciling
the same run from minute- and second-precision sources preserves its wait and
acknowledgment rather than creating another episode. Ledger aliases identify a
commit, so only matching creation minutes reconcile them; a demonstrably newer
same-head retry starts another validation clock.
Unknown observations withhold notification without discarding episode evidence.
Declared waits end observation.
Missing, corrupt, future or generation-mismatched observation records recover
from valid entry evidence when available, otherwise start a fresh observation.
Episode identity includes metadata contents, phase, folded pending questions and,
for decisions, the attributed run, step and current gate's parked_since.
First publication of matching gate timing enriches the existing parked episode;
a changed already-known gate timestamp identifies a recreated gate.
A proven phase transition or new question starts another episode; removing only
some pending questions preserves the surviving questions' wait and acknowledgment.
The first question after a parked-only observation recovers entry evidence;
a new or reopened question after an observed decision in the same parked episode
starts its own observation clock. Current gate timing takes precedence over a
legacy parked-run clock; legacy delivery is imported only when consistent with
the current gate and saved observation evidence.
--ack records delivery only for the currently matching stalled episode and retains
parked-episode delivery identity when its question closes before the run resumes.
Atomic owner-only writes refuse symlinks. No worker ledger, hold, gate or approval
record is changed.
The digest routes questions for mate triage, never infers captain authority from
age or an ask-user label, and never invents a question for implementation stalls.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import time


def digest(value):
    return hashlib.sha256(value.encode()).hexdigest()


def episode_signature(identity, phase, pending, run, step, gate_since):
    return digest(json.dumps([identity, phase, pending if phase == 'needs-decision' else [],
                              run if phase == 'needs-decision' else '',
                              step if phase == 'needs-decision' else '',
                              gate_since if phase == 'needs-decision' else None]))


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


def fields_file(path):
    try:
        if not path.is_symlink():
            return dict(line.split('=', 1) for line in path.read_text().splitlines() if '=' in line)
    except OSError:
        pass
    return {}


def evidence(current, key):
    reference = next((f for f in current.split(' · ') if f.startswith('evidence: ')), '')
    match = re.search(r'(?:^|; )' + key + r'=([^;]+)', reference.removeprefix('evidence: '))
    return match[1] if match else ''


def matching_stamp(record, key, run, step, now):
    if run and step and record.get('run') == run and record.get('step') == step:
        try:
            stamp = int(record.get(key, 0))
        except (ValueError, TypeError):
            return None
        if epoch(stamp, now):
            return stamp
    return None


def initial_since(phase, meta, path, pending, decision_since, now):
    if phase == 'needs-decision':
        if decision_since is not None:
            return decision_since
        status = path.with_suffix('.status')
        try:
            if not status.is_symlink():
                last = next((line for line in reversed(status.read_text().splitlines()) if line.strip()), '')
                if re.match(r'^needs-decision(?:\s|:)', last) and any(last.endswith(q) for q in pending):
                    stamp = int(status.stat().st_mtime)
                    if epoch(stamp, now):
                        return stamp
        except OSError:
            pass
    elif phase == 'implementation':
        match = re.fullmatch(r's(\d+)\.[^.]+\.[^.]+', meta.get('spawn_gen', ''))
        try:
            stamp = int(match[1]) if match else int(path.stat().st_mtime)
        except OSError:
            return now
        if epoch(stamp, now):
            return stamp
    return now


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('record', type=Path)
    parser.add_argument('meta', type=Path)
    parser.add_argument('current')
    parser.add_argument('decisions')
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument('--observe', action='store_true')
    mode.add_argument('--ack', action='store_true')
    mode.add_argument('--reported-run', action='store_true',
                      help='read whether this parked run/step already received a decision digest')
    parser.add_argument('--now', type=int, default=int(time.time()))
    parser.add_argument('--state-dir', type=Path)
    parser.add_argument('--task-id')
    parser.add_argument('--delivery-log', type=Path)
    args = parser.parse_args()
    timing_meta = args.state_dir / (args.task_id + '.meta') if args.state_dir and args.task_id else args.meta
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
    receipt = args.record.with_name(args.record.name.removesuffix('.json') + '-delivered')
    delivered = []
    try:
        if not receipt.is_symlink():
            delivered = receipt.read_text().splitlines()
    except OSError:
        pass
    if args.delivery_log and not args.delivery_log.is_symlink():
        try:
            delivered.extend(re.findall(r'\[stall-episode=([a-f0-9]{64})\]',
                                        args.delivery_log.read_text()))
        except OSError:
            pass
    if old.get('episode') in delivered:
        old['reported'] = old['episode']
    if state in ('', 'unknown'):
        result = dict(old, state='ineligible', notify=False)
        print(json.dumps(False if args.reported_run else result))
        return
    keyed_pending = []
    for row in args.decisions.splitlines():
        cells = row.split('\t', 2)
        if len(cells) == 3 and cells[1] == 'needs-decision':
            keyed_pending.append((cells[0], cells[2]))
    keyed_pending = sorted(set(keyed_pending))
    pending = sorted(question for _, question in keyed_pending)
    question_labels = {digest(json.dumps(item)): item[1] for item in keyed_pending}
    eligible = (bool(identity) and not meta.get('remote_host')
                and 'declared-wait: active' not in fields)
    run = evidence(args.current, 'run') if source == 'run-step' else ''
    step = evidence(args.current, 'step') if source == 'run-step' else ''
    gate_since = matching_stamp(load(timing_meta.with_suffix('.gate')),
                                'parked_since', run, step, args.now)
    parked = fields_file(timing_meta.with_suffix('.parked-run'))
    parked_since = matching_stamp(parked, 'since', run, step, args.now)
    parked_episode = dict(run=run, step=step, gate_since=gate_since)
    previous_parked = old.get('parked_episode')
    enriching_gate = bool(state == 'parked' and run and step and gate_since is not None
                          and isinstance(previous_parked, dict)
                          and previous_parked == dict(run=run, step=step, gate_since=None))
    same_parked_run = (enriching_gate or previous_parked == parked_episode
                       or (old.get('phase') == 'needs-decision'
                           and old.get('signature') == episode_signature(
                               identity, 'needs-decision', old.get('question_ids', []),
                               run, step, gate_since)))
    decision_seen = bool(same_parked_run and (
        old.get('decision_seen') or old.get('phase') == 'needs-decision'))
    reported_parked = old.get('reported_parked')
    if ((enriching_gate and reported_parked == previous_parked)
            or (same_parked_run and old.get('episode')
                and old.get('reported') == old.get('episode'))):
        reported_parked = parked_episode
    if (state != 'parked' or not run or not step
            or reported_parked != parked_episode):
        reported_parked = None
    if args.reported_run:
        print(json.dumps(bool(eligible and reported_parked)))
        return
    phase = ''
    if eligible and state == 'parked' and pending:
        phase = 'needs-decision'
    elif (eligible and meta.get('kind') == 'ship'
          and meta.get('mode', '') in ('', 'ship', 'no-mistakes')
          and state == 'working' and (source in ('pane', 'status-log')
                                     or (source == 'run-step' and evidence(args.current, 'implementation') == 'replacement'))):
        phase = 'implementation'
    question_ids = sorted(question_labels) if phase == 'needs-decision' else []
    signature = episode_signature(identity, phase, question_ids, run, step, gate_since)
    last_run = old.get('last_run_seen')
    last_run_id = old.get('last_run_id', '')
    last_run_head = old.get('last_run_head', '')
    if not epoch(last_run, args.now):
        last_run = None
        last_run_id = last_run_head = ''
    for key in ('last-run-created', 'run-created'):
        if key == 'run-created' and not run:
            continue
        try:
            stamp = int(evidence(args.current, key))
        except ValueError:
            continue
        if not epoch(stamp, args.now):
            continue
        run_id = run if key == 'run-created' else evidence(args.current, 'last-run')
        run_head = evidence(args.current, 'last-run-head') if key == 'last-run-created' else ''
        ledger_alias = run_id.startswith('ledger-') or last_run_id.startswith('ledger-')
        same_run = bool(run_id and last_run_id and (
            (run_id == last_run_id and not ledger_alias) or (
                ledger_alias and (run_id == last_run_id or (
                    run_head and run_head == last_run_head))
                and last_run is not None and stamp // 60 == last_run // 60)))
        if same_run:
            if last_run_id.startswith('ledger-') and not run_id.startswith('ledger-'):
                last_run_id = run_id
            last_run_head = run_head or last_run_head
        elif stamp >= (last_run or 0):
            last_run, last_run_id, last_run_head = stamp, run_id, run_head
    continuing = (old.get('signature') == signature or (
        phase == 'needs-decision' and old.get('phase') == phase and same_parked_run
        and set(question_ids).issubset(old.get('question_ids', []))))
    since = old.get('since') if continuing else None
    if not continuing or not epoch(since, old.get('observed_at', 0)):
        since = args.now if phase else None
        if phase and not (phase == 'needs-decision' and decision_seen):
            since = initial_since(phase, meta, timing_meta, pending,
                                  gate_since or parked_since, args.now)
    question_states = {}
    notify_question_ids = []
    if phase == 'needs-decision':
        previous_questions = old.get('question_states', {}) if same_parked_run else {}
        if not isinstance(previous_questions, dict):
            previous_questions = {}
        entry = args.now if decision_seen else initial_since(
            phase, meta, timing_meta, pending, gate_since or parked_since, args.now)
        for question_id in question_ids:
            previous = previous_questions.get(question_id, {})
            if ('question_states' not in old and same_parked_run
                    and old.get('phase') == phase and question_labels[question_id] in old.get('questions', [])
                    and pending.count(question_labels[question_id]) == 1
                    and epoch(old.get('since'), old.get('observed_at', 0))):
                previous = dict(since=old['since'], reported=old.get('reported') == old.get('episode'),
                                episode=digest(f"{old.get('episode')}:{question_id}"))
            if (not isinstance(previous, dict)
                    or not epoch(previous.get('since'), old.get('observed_at', 0))
                    or type(previous.get('reported')) is not bool
                    or not re.fullmatch(r'[a-f0-9]{64}', str(previous.get('episode', '')))):
                previous = dict(since=entry, reported=False, episode=digest(
                    f'{identity}:{json.dumps(parked_episode)}:{question_id}:{entry}'))
            question_states[question_id] = dict(previous)
            if previous.get('episode') in delivered:
                question_states[question_id]['reported'] = True
        waiting = [q['since'] for q in question_states.values() if not q.get('reported')]
        since = min(waiting or [q['since'] for q in question_states.values()])
        notify_question_ids = [key for key, q in question_states.items()
                               if not q.get('reported') and args.now - q['since'] > 3600]
    if phase == 'implementation' and last_run:
        since = max(since, last_run)
    age = args.now - since if since is not None else None
    threshold = 3600 if phase == 'needs-decision' else 7200
    stalled = bool(phase and age is not None and age > threshold)
    outstanding = [(key, q['since']) for key, q in question_states.items() if not q.get('reported')]
    episode_seed = f'{signature}:{since}' + (json.dumps(outstanding) if question_states else '')
    episode = (old.get('episode') if continuing and since == old.get('since')
               and not (outstanding and old.get('reported') == old.get('episode'))
               else digest(episode_seed)) if phase else None
    reported = episode if episode in delivered else old.get('reported')
    legacy_reported = False
    if (phase == 'needs-decision' and not old.get('episode') and parked_since
            and (gate_since is None or parked_since >= gate_since)
            and (not old or parked_since >= old['observed_at'])):
        try:
            delivered = int(parked.get('nudged', 0))
        except ValueError:
            delivered = 0
        if epoch(delivered, args.now) and delivered >= parked_since:
            legacy_reported = True
    if phase == 'needs-decision':
        if legacy_reported:
            for question_state in question_states.values():
                question_state['reported'] = True
        if args.ack and stalled:
            for question_id in notify_question_ids:
                question_states[question_id]['reported'] = True
        notify_question_ids = [key for key in notify_question_ids
                               if not question_states[key].get('reported')]
        reported = episode if all(q.get('reported') for q in question_states.values()) else None
    result = dict(version=1, identity=identity, observed_at=args.now,
                  signature=signature, since=since, phase=phase or None,
                  age_seconds=age, last_run_seen=last_run,
                  last_run_id=last_run_id, last_run_head=last_run_head,
                  seconds_since_last_run=args.now-last_run if last_run else None,
                  state='stalled' if stalled else 'observing' if phase else 'ineligible',
                  questions=pending if phase == 'needs-decision' else [],
                  question_ids=question_ids, question_states=question_states,
                  notify_questions=sorted(question_labels[key] for key in notify_question_ids),
                  delivery_episodes=([episode] + [question_states[key]['episode']
                                                for key in notify_question_ids]) if phase else [],
                  route='mate-triage' if phase == 'needs-decision' else 'mate-repair',
                  episode=episode, reported=reported, reported_parked=reported_parked,
                  parked_episode=parked_episode if state == 'parked' else None,
                  decision_seen=state == 'parked' and (phase == 'needs-decision' or decision_seen),
                  notify=stalled and (bool(notify_question_ids) if phase == 'needs-decision'
                                      else reported != episode))
    if args.ack and stalled:
        result.update(reported=episode, notify=False)
        if phase == 'needs-decision' and run and step:
            result['reported_parked'] = parked_episode
    if args.observe or args.ack:
        write(args.record, result)
    print(json.dumps(result))


if __name__ == '__main__':
    main()
