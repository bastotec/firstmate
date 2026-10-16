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
RECORDED = re.compile(r'captain instruction \(recorded at delivery[^)]*\): "(.*)"\s*$', re.S)
DATED = re.compile(r'^- (\d{4}-\d{2}-\d{2})\b')
SHARED_HEADER = (
    '# Shared captain preferences\n\n<!-- memory tiers: see the stow skill -->\n\n'
    'This file is main-authoritative and read-only in secondmate homes; it must not be edited there.\n'
    'Route newly discovered shared captain preferences to the main firstmate through marked status or a document pointer.\n\n')
HOME_HEADER = '# Captain preferences - this home\n\n'


def now_utc():
    return datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')


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


def entries(path):
    """The bullets and paragraphs of a preferences file, in file order."""
    try:
        text = path.read_text()
    except (FileNotFoundError, UnicodeDecodeError):
        return []
    out, cur = [], []
    for line in text.splitlines():
        if cur and line.startswith('  '):
            cur.append(line.strip())
            continue
        if line.startswith('#') or line.startswith('<!--') or not line.strip():
            if cur:
                out.append(' '.join(cur))
                cur = []
            continue
        if line.startswith('- ') and cur:
            out.append(' '.join(cur))
            cur = []
        cur.append(line.strip())
    if cur:
        out.append(' '.join(cur))
    return [e for e in out if not e.startswith('This file is main-authoritative')
            and not e.startswith('Route newly discovered')]


def is_standing(text):
    if CARD_PICK.match(text):
        return False
    return bool(STANDING.search(text) or REPEAT.search(text))


def primary_of(home):
    """(home to record in, file) for a capture made in `home`: the primary's
    captain-shared.md, reached through a local mate's parent binding; a remote
    mate's own data/captain.md, since its parent is on another machine."""
    binding = home / '.fm-secondmate-parent'
    try:
        fields = dict(line.split('=', 1) for line in binding.read_text().splitlines() if '=' in line)
    except FileNotFoundError:
        return home, shared(home)
    if fields.get('route') == 'local' and fields.get('parent_home', '').startswith('/'):
        parent = Path(fields['parent_home'])
        return parent, shared(parent)
    return home, home / 'data' / 'captain.md'


def count_repeat(home, mate, source, text):
    state = home / 'state'
    state.mkdir(parents=True, exist_ok=True)
    log = state / 'captain-memory-repeats.log'
    words = ' '.join(text.split())[:300]
    try:
        for line in log.read_text().splitlines():
            parts = line.split('\t')
            if len(parts) >= 4 and parts[2] == source and parts[3] == words:
                return
    except FileNotFoundError:
        pass
    with open(log, 'a') as f:
        f.write('%s\t%s\t%s\t%s\n' % (now_utc(), mate or 'firstmate', source, words))


def schedule_push(home):
    if os.environ.get('FM_CAPTAIN_MEMORY_PUSH', '1') == '0':
        return
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
    if REPEAT.search(text):
        count_repeat(home, args.mate, args.source, text)
    lines = text.splitlines()
    today = datetime.date.today().isoformat()
    where = ', in %s\'s chat' % args.mate if args.mate else ''
    record = '- %s captain instruction (recorded at delivery from %s%s): "%s' % (today, args.source, where, lines[0])
    record += ''.join('\n  ' + line for line in lines[1:]) + '"\n'
    with locked(path):
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


def recall(args):
    home = Path(args.home)
    cap = CAP
    if args.max_bytes is not None:
        cap = min(cap, args.max_bytes - 400)
    items = entries(shared(home)) + entries(home / 'data' / 'captain.md')
    if not items or cap <= 0:
        return 0
    # Newest first by recorded date; undated entries, and ties, by file order.
    def dated(i):
        m = DATED.match(items[i])
        return (m.group(1) if m else '', i)
    order = sorted(range(len(items)), key=dated, reverse=True)
    newest = [items[i] for i in order]
    chosen, size = [], 0
    for e in newest:
        if size + len(e.encode('utf-8')) + 3 > cap // 2:
            break
        chosen.append(e)
        size += len(e.encode('utf-8')) + 3
    rest = newest[len(chosen):]
    if rest:
        query = set(norm(args.query or '').split()) - {'the', 'a', 'to', 'and', 'of', 'is', 'it', 'i', 'you', 'in'}
        ranked = sorted(rest, key=lambda e: -len(query & set(norm(e).split())))
        for e in ranked:
            if size + len(e.encode('utf-8')) + 3 > cap:
                continue
            chosen.append(e)
            size += len(e.encode('utf-8')) + 3
    print(OPEN)
    print("The captain's standing instructions on record (follow them; newest and most relevant first):")
    for e in chosen:
        print(e if e.startswith('- ') else '- ' + e)
    if len(chosen) < len(items):
        print('- (%d more on record in data/captain-shared.md and data/captain.md)' % (len(items) - len(chosen)))
    print(CLOSE)
    return 0


def local_mates(home):
    homes = []
    try:
        for line in (home / 'data' / 'secondmates.md').read_text().splitlines():
            m = re.search(r'\(home: (/[^;)]+)', line)
            if m and not re.search(r'\((?:host|root): ', line):
                homes.append(Path(m.group(1).strip()))
    except FileNotFoundError:
        pass
    return homes


def upkeep(args):
    home = Path(args.home)
    path = shared(home)
    mates = local_mates(home)
    with locked(path):
        text = path.read_text() if path.exists() else ''
        kept, seen, skipping = [], set(), False
        for line in text.splitlines():
            if line.startswith('- '):
                k = key(line)
                skipping = k in seen
                seen.add(k)
            elif not line.startswith('  '):
                skipping = False
            if not skipping:
                kept.append(line)
        new = '\n'.join(kept) + '\n' if kept else ''
        if text and new != text:
            path.write_text(new)
    known = {key(e) for e in entries(path)}
    cand_path = home / 'state' / 'captain-memory-candidates.md'
    known_cands = {key(e) for e in entries(cand_path)}
    added = []
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
                    added.append('%s (from the local copy in %s, %s)' % (e if e.startswith('- ') else '- ' + e, h, q.name))
            q.rename(q.with_name(q.name + '.reviewed'))
        if not (data / 'captain.md').exists():
            (data / 'captain.md').write_text(HOME_HEADER)
    if added:
        cand_path.parent.mkdir(parents=True, exist_ok=True)
        with open(cand_path, 'a') as f:
            if not cand_path.stat().st_size:
                f.write('# Captain memory candidates - mates\' local rules not in the shared file; promote or drop\n\n')
            f.write(''.join(a + '\n' for a in added))
    files = [path, home / 'data' / 'captain.md'] + [m / 'data' / 'captain.md' for m in mates]
    oversized = [str(f) for f in files if f.exists() and f.stat().st_size > OVERSIZED]
    repeats = 0
    log, mark = home / 'state' / 'captain-memory-repeats.log', home / 'state' / '.captain-memory-upkeep'
    since = mark.read_text().strip() if mark.exists() else ''
    if log.exists():
        repeats = sum(1 for line in log.read_text().splitlines() if line.split('\t', 1)[0] > since)
    (home / 'state').mkdir(parents=True, exist_ok=True)
    mark.write_text(now_utc() + '\n')
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
    u = sub.add_parser('upkeep')
    u.add_argument('--home', required=True)
    args = p.parse_args()
    return {'capture': capture, 'recall': recall, 'upkeep': upkeep}[args.cmd](args)


if __name__ == '__main__':
    sys.exit(main())
