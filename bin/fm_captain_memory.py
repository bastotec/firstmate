#!/usr/bin/env python3
"""fm_captain_memory.py - remember the captain's standing instructions.

Usage:
  fm_captain_memory.py capture --home H --source S [--mate M]   (text on stdin)
  fm_captain_memory.py recall --home H [--query Q] [--max-bytes N]
  fm_captain_memory.py upkeep --home H

The captain's standing preferences live in the primary home's
data/captain-shared.md (pushed read-only to every second mate home by
bin/fm-config-inherit-lib.sh) and in each home's own data/captain.md.

capture runs, detached, on delivery of every captain message: a captain-direct
message to any worker or mate through bin/fm-send.sh, a message to the first
mate through its steering inbox, a free-text card answer. A message that states
a standing instruction - "always", "never", "from now on", "going forward",
"stop doing", "don't ... again", "every time", "whenever", or a correction such
as "I told you" or "I already said" - is recorded verbatim (its own line breaks
kept, indented under the bullet), with its date and source, unless the same
instruction is already recorded. Identity is the normalized instruction text,
compared for equality, so a shorter or longer rule is its own rule. A card
answer that only picks an option, or a one-off order without those cues, is not
a standing rule. A local mate records in its parent's captain-shared.md; a remote
mate in its own data/captain.md, since its parent is on another machine.
Recording and upkeep serialize on data/.captain-memory.lock.

Every correction delivery is counted in state/captain-memory-repeats.log as a
memory failure (the captain had to say it again), once per source, whether or
not its words were already recorded.

After a recording in captain-shared.md, bin/fm-config-push.sh pushes the file
to every home 20 seconds later; recordings inside that window share one push
(state/.captain-memory-push-pending), so another mate quotes the rule within
about a minute.

recall prints the block every turn of every lane carries, between the markers
"[fm-captain-memory]" and "[/fm-captain-memory]" (Fleet Town strips it from what
it shows): the home's captain-shared.md and captain.md entries merged by date,
newest first, up to 8000 characters (about 2k tokens), or --max-bytes when the
turn has less room. Past the cap it keeps the newest half and fills the rest
with the entries sharing the most words with --query (the turn's own text).

upkeep (nightly, from dreaming) dedupes captain-shared.md; collects entries
missing from it that a mate wrote into its read-only copy (quarantined by a push
as data/.captain-shared.md.quarantine.* or captain-shared.md.remote-quarantine-*,
in this home or a local mate's) into state/captain-memory-candidates.md for
dreaming to promote or drop - a quarantine can also hold a rule the primary
retired, so nothing is imported unreviewed - and marks each read quarantine
.reviewed; seeds a missing data/captain.md here and in each local mate home; and
prints one summary line: entries, new candidates, oversized files (over 32 KB),
repeats since the last upkeep.
"""
import argparse
import datetime
import fcntl
import os
import re
import subprocess
import sys
import time
from contextlib import contextmanager
from pathlib import Path

BIN = Path(__file__).resolve().parent
OPEN, CLOSE = '[fm-captain-memory]', '[/fm-captain-memory]'
CAP = 8000
PUSH_DELAY = 20
OVERSIZED = 32000
STANDING = re.compile(
    r"\b(always|never|from now on|from here on|going forward|stop (?:doing|using|sending|asking)"
    r"|(?:don'?t|do not)\b[^.!?\n]{0,80}?\b(?:again|anymore)|don'?t ever|do not ever"
    r"|every time|whenever|make sure (?:you|to) always|as a rule)\b", re.I)
REPEAT = re.compile(
    r"\b(i (?:told|said|asked) you|i already (?:said|told|asked)|as i said|how many times"
    r"|i keep (?:saying|telling))\b", re.I)
CARD_PICK = re.compile(r'\A\s*(?:card \S+:\s*)?option \w+\s*\Z', re.I)
RECORDED = re.compile(r'captain instruction \(recorded at delivery from [^"\n]*?\): "(.*)"\s*$', re.S)
DATED = re.compile(r'^- (\d{4}-\d{2}-\d{2})\b')
SHARED_HEADER = (
    '# Shared captain preferences\n\n<!-- memory tiers: see the stow skill -->\n\n'
    'This file is main-authoritative and read-only in secondmate homes; it must not be edited there.\n'
    'Route newly discovered shared captain preferences to the main firstmate through marked status or a document pointer.\n\n')
HOME_HEADER = '# Captain preferences - this home\n\n'


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='microseconds').replace('+00:00', 'Z')


def shared(home):
    return Path(home) / 'data' / 'captain-shared.md'


def norm(text):
    return re.sub(r'\W+', ' ', text.lower()).strip()


def key(entry):
    """An entry's identity: its recorded instruction, or its text without the
    bullet and date."""
    m = RECORDED.search(entry)
    if m:
        return norm(m.group(1))
    return norm(DATED.sub('', entry).lstrip('- '))


@contextmanager
def locked(path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path.parent / '.captain-memory.lock', 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        yield


def entry_blocks(text):
    blocks = []
    for line in text.splitlines(keepends=True):
        if blocks and line.startswith('  '):
            blocks[-1] += line
        else:
            blocks.append(line)
    return blocks


def entries(path):
    """The bullets and paragraphs of a preferences file, in file order."""
    try:
        text = path.read_text()
    except (FileNotFoundError, UnicodeDecodeError):
        return []
    out = []
    for block in entry_blocks(text):
        if block.startswith(('#', '<!--')) or not block.strip():
            continue
        entry = block.strip()
        if not entry.startswith(('This file is main-authoritative', 'Route newly discovered')):
            out.append(entry)
    return out


def is_standing(text):
    if CARD_PICK.match(text):
        return False
    return bool(STANDING.search(text) or REPEAT.search(text))


def primary_of(home):
    """(home to record in, file) for a capture made in `home`: the primary's
    captain-shared.md, reached through a local mate's parent binding; a remote
    mate's own data/captain.md, since its parent is on another machine."""
    seen = set()
    while home not in seen:
        seen.add(home)
        binding = home / '.fm-secondmate-parent'
        try:
            fields = dict(line.split('=', 1) for line in binding.read_text().splitlines() if '=' in line)
        except FileNotFoundError:
            return home, shared(home)
        if fields.get('route') != 'local' or not fields.get('parent_home', '').startswith('/'):
            return home, home / 'data' / 'captain.md'
        home = Path(fields['parent_home']).resolve()
    raise ValueError('cyclic secondmate parent bindings')


def count_repeat(home, mate, source, text):
    state = home / 'state'
    state.mkdir(parents=True, exist_ok=True)
    log = state / 'captain-memory-repeats.log'
    words = ' '.join(text.split())[:300]
    try:
        for line in log.read_text().splitlines():
            parts = line.split('\t')
            if (len(parts) >= 4 and parts[1] == (mate or 'firstmate')
                    and parts[2] == source and parts[3] == words):
                return
    except FileNotFoundError:
        pass
    with open(log, 'a') as f:
        f.write('%s\t%s\t%s\t%s\n' % (now_utc(), mate or 'firstmate', source, words))


def schedule_push(home):
    if os.environ.get('FM_CAPTAIN_MEMORY_PUSH', '1') == '0':
        return
    with locked(shared(home)):
        pending = home / 'state' / '.captain-memory-push-pending'
        try:
            if time.time() - pending.stat().st_mtime < PUSH_DELAY * 3:
                return
        except FileNotFoundError:
            pass
        pending.parent.mkdir(parents=True, exist_ok=True)
        pending.write_text('%d\n' % time.time())
        subprocess.Popen(
            ['bash', '-c', 'sleep "$1"; rm -f "$2"; exec "$3"', 'fm-captain-memory-push',
             str(PUSH_DELAY), str(pending), str(BIN / 'fm-config-push.sh')],
            env=dict(os.environ, FM_HOME=str(home)), stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True)


def capture(args):
    text = sys.stdin.read().strip()
    if not text or not is_standing(text):
        print('captured=no')
        return 0
    home, path = primary_of(Path(args.home))
    lines = text.splitlines()
    today = datetime.date.today().isoformat()
    where = ', in %s\'s chat' % args.mate if args.mate else ''
    record = '- %s captain instruction (recorded at delivery from %s%s): "%s' % (today, args.source, where, lines[0])
    record += ''.join('\n  ' + line for line in lines[1:]) + '"\n'
    with locked(path):
        if REPEAT.search(text):
            count_repeat(home, args.mate, args.source, text)
        if any(key(e) == norm(text) for e in entries(path)):
            print('captured=duplicate')
            return 0
        if not path.exists():
            path.write_text(SHARED_HEADER if path.name == 'captain-shared.md' else HOME_HEADER)
        current = path.read_text()
        with open(path, 'a') as f:
            if current and not current.endswith('\n'):
                f.write('\n')
            f.write(record)
    if path.name == 'captain-shared.md':
        schedule_push(home)
    print('captured=yes')
    return 0


def recall_block(home, query='', max_bytes=None):
    home = Path(home)
    cap = CAP if max_bytes is None else min(CAP, max_bytes)
    items = entries(shared(home)) + entries(home / 'data' / 'captain.md')
    if not items or cap <= 0:
        return ''

    def render(chosen):
        lines = [OPEN, "The captain's standing instructions on record (follow them; newest and most relevant first):"]
        lines.extend(e if e.startswith('- ') else '- ' + e for e in chosen)
        if len(chosen) < len(items):
            lines.append('- (%d more on record in data/captain-shared.md and data/captain.md)' % (len(items) - len(chosen)))
        return '\n'.join(lines + [CLOSE]) + '\n'

    wrapper_size = len(render([]).encode('utf-8'))

    def dated(i):
        m = DATED.match(items[i])
        return (m.group(1) if m else '', i)
    order = sorted(range(len(items)), key=dated, reverse=True)
    newest = [items[i] for i in order]
    complete = render(newest)
    if len(complete.encode('utf-8')) <= cap:
        return complete
    chosen, size = [], 0
    for e in newest:
        cost = len((e if e.startswith('- ') else '- ' + e).encode('utf-8')) + 1
        if size + cost > (cap - wrapper_size) // 2:
            break
        chosen.append(e)
        size += cost
    rest = newest[len(chosen):]
    if rest:
        words = set(norm(query).split()) - {'the', 'a', 'to', 'and', 'of', 'is', 'it', 'i', 'you', 'in'}
        ranked = sorted(rest, key=lambda e: -len(words & set(norm(e).split())))
        for e in ranked:
            if len(render(chosen + [e]).encode('utf-8')) <= cap:
                chosen.append(e)
    block = render(chosen)
    return block if len(block.encode('utf-8')) <= cap else ''


def with_memory(home, body, max_bytes=65536):
    body = re.sub(re.escape(OPEN) + r'.*?(?:' + re.escape(CLOSE) + r'|\Z)', '', body, flags=re.S)
    room = max_bytes - len(body.encode('utf-8')) - 2
    block = recall_block(home, body[:2000], room).rstrip('\n')
    return body + '\n\n' + block if block else body


def recall(args):
    print(recall_block(args.home, args.query or '', args.max_bytes), end='')
    return 0


def prompt(args):
    print(with_memory(args.home, sys.stdin.read()), end='')
    return 0


def local_mates(home):
    from fm_report import registry
    return [Path(row['home']) for row in registry(home).values() if row.get('home') and not row.get('host')]


def upkeep(args):
    home = Path(args.home)
    path = shared(home)
    mates = local_mates(home)
    if not (home / '.fm-secondmate-parent').exists():
        with locked(path):
            text = path.read_bytes().decode('utf-8') if path.exists() else ''
            kept, seen = [], set()
            for block in entry_blocks(text):
                if block.startswith('- '):
                    k = key(block)
                    if k in seen:
                        continue
                    seen.add(k)
                kept.append(block)
            new = ''.join(kept)
            if new != text:
                path.write_bytes(new.encode('utf-8'))
    known = {key(e) for e in entries(path)}
    cand_path = home / 'state' / 'captain-memory-candidates.md'
    known_cands = {key(e) for e in entries(cand_path)}
    added, reviewed = [], []
    for h in [home] + mates:
        data = h / 'data'
        if not data.is_dir():
            continue
        quarantines = [q for q in sorted(data.glob('.captain-shared.md.quarantine.*'))
                       + sorted(data.glob('captain-shared.md.remote-quarantine-*'))
                       if not q.name.endswith('.reviewed')]
        for q in quarantines:
            for e in entries(q):
                k = key(e)
                if k and k not in known and k not in known_cands:
                    known_cands.add(k)
                    added.append('<!-- from the local copy in %s, %s -->\n%s'
                                 % (h, q.name, e if e.startswith('- ') else '- ' + e))
            reviewed.append(q)
        with locked(data / 'captain.md'):
            try:
                with open(data / 'captain.md', 'x') as f:
                    f.write(HOME_HEADER)
            except FileExistsError:
                pass
    if added or (reviewed and cand_path.exists()):
        cand_path.parent.mkdir(parents=True, exist_ok=True)
        with open(cand_path, 'a') as f:
            if not cand_path.stat().st_size:
                f.write('# Captain memory candidates - mates\' local rules not in the shared file; promote or drop\n\n')
            f.write(''.join(a + '\n' for a in added))
            f.flush()
            os.fsync(f.fileno())
    for q in reviewed:
        q.rename(q.with_name(q.name + '.reviewed'))
    files = [path, home / 'data' / 'captain.md'] + [m / 'data' / 'captain.md' for m in mates]
    oversized = [str(f) for f in files if f.exists() and f.stat().st_size > OVERSIZED]
    repeats = 0
    log, mark = home / 'state' / 'captain-memory-repeats.log', home / 'state' / '.captain-memory-upkeep'
    with locked(path):
        checkpoint = now_utc()
        since = mark.read_text().strip() if mark.exists() else ''
        since_time = datetime.datetime.fromisoformat(since.replace('Z', '+00:00')) if since else None
        if log.exists():
            repeats = sum(1 for line in log.read_text().splitlines()
                          if since_time is None or datetime.datetime.fromisoformat(
                              line.split('\t', 1)[0].replace('Z', '+00:00')) > since_time)
        (home / 'state').mkdir(parents=True, exist_ok=True)
        mark.write_text(checkpoint + '\n')
    print('captain-memory: %d entries, %d new candidates in %s, oversized: %s, repeats since last upkeep: %d'
          % (len(entries(path)), len(added), cand_path, ', '.join(oversized) or 'none', repeats))
    return 0


def main():
    p = argparse.ArgumentParser(description=__doc__.split('\n')[0])
    sub = p.add_subparsers(dest='cmd', required=True)
    c = sub.add_parser('capture')
    c.add_argument('--home', required=True)
    c.add_argument('--source', required=True)
    c.add_argument('--mate', default='')
    r = sub.add_parser('recall')
    r.add_argument('--home', required=True)
    r.add_argument('--query', default='')
    r.add_argument('--max-bytes', type=int, default=None)
    t = sub.add_parser('prompt')
    t.add_argument('--home', required=True)
    u = sub.add_parser('upkeep')
    u.add_argument('--home', required=True)
    args = p.parse_args()
    return {'capture': capture, 'recall': recall, 'prompt': prompt, 'upkeep': upkeep}[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())
