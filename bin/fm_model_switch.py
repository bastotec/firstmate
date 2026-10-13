#!/usr/bin/env python3
"""In-place model switches for Deck agents (bin/fm-control.sh `model`).

A Deck driver (bin/fm-deck-worker.sh) reads state/<id>.model before every turn,
and a live turn takes Deck's `deck-control: set_model <route>` steering control
at its next safe point, so a switch needs no restart. bin/fm-control.sh's header
owns the public contract; this file owns the checks and the live publication.

  check ROUTE --policy FILE
      exit 0 when ROUTE is a plain gateway route the captain's model policy
      permits (config/model-policy.json, the same globs Fleet Town writes) and
      the gateway lists in /models; else exit 1 with the reason on stderr.
  supported STATE ID
      exit 0 when the task's live Deck driver advertises in-place switching
      (state/<id>.deck-caps names model_switch=1 and a live pid), else exit 3.
  publish STATE ID WAS ROUTE
      reserve a handled task-inbox switch record under the receiver locks, save
      state/<id>.model for the next turn, then put the control into every live
      Deck turn of the task whose Deck accepts it, at that sequence. Prints
      `live` when a running turn will take it at its next safe point, else
      `next-turn`; reservation failure exits 1.
"""
import contextlib
import fnmatch
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import urllib.request

sys.path.insert(0, str(Path(__file__).resolve().parent))
from fm_stream_deck import Receiver, atomic_write  # noqa: E402

ROUTE_RE = re.compile(r'\A[A-Za-z0-9][A-Za-z0-9._:@-]{0,63}(?:/[A-Za-z0-9][A-Za-z0-9._:@-]{0,127}){1,3}\Z')


def policy_permits(route, path):
    """config/model-policy.json semantics: blocked wins; empty allowed allows the rest.
    A missing file blocks nothing; an unreadable one blocks everything."""
    try:
        raw = json.loads(Path(path).read_text(encoding='utf-8'))
        blocked, allowed = raw.get('blocked', []), raw.get('allowed', [])
        if set(raw) - {'blocked', 'allowed'} or not all(
                isinstance(x, list) and all(isinstance(p, str) for p in x) for x in (blocked, allowed)):
            raise ValueError
    except FileNotFoundError:
        return True
    except (OSError, ValueError, AttributeError):
        return False

    def hit(pattern):
        return fnmatch.fnmatchcase(route.lower(), pattern.strip().lower())
    if any(hit(p) for p in blocked):
        return False
    return not allowed or any(hit(p) for p in allowed)


def gateway_routes():
    base = (os.environ.get('PROXAI_BASE_URL') or 'http://127.0.0.1:8329/v1').rstrip('/')
    key = os.environ.get('PROXAI_API_KEY', '').strip()
    if not key:
        path = os.environ.get('PROXAI_API_KEY_FILE') or str(Path.home() / '.config/proxai/client.key')
        key = Path(path).read_text().strip()
    request = urllib.request.Request(base + '/models', headers={'Authorization': 'Bearer ' + key})
    with urllib.request.urlopen(request, timeout=5) as response:
        listing = json.load(response)
    return {entry.get('id') for entry in listing.get('data', []) if isinstance(entry, dict)}


def check(route, policy):
    if not ROUTE_RE.match(route):
        return 'not a model route: %s' % route
    if not policy_permits(route, policy):
        return '%s is blocked by the model policy' % route
    try:
        routes = gateway_routes()
    except (OSError, ValueError) as exc:
        return "the gateway's route list is unavailable (%s)" % type(exc).__name__
    if route not in routes:
        return 'the gateway does not serve %s' % route
    return None


def pid_alive(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def supported(state, task):
    try:
        caps = dict(line.split('=', 1) for line in
                    (Path(state) / (task + '.deck-caps')).read_text().splitlines() if '=' in line)
        return caps.get('model_switch') == '1' and pid_alive(int(caps['pid']))
    except (OSError, ValueError, KeyError):
        return False


def publish(state, task, was, route):
    body = 'deck-control: set_model %s\n' % route
    live = False
    inbox = Path(state) / (task + '.inbox')
    receivers = [Receiver(state, task, root.name[len('deck-'):])
                 for root in sorted(inbox.glob('deck-*'))]
    with contextlib.ExitStack() as locks:
        for receiver in receivers:
            locks.enter_context(receiver.locked())
        library = str(Path(__file__).with_name('fm-task-inbox-lib.sh'))
        result = subprocess.run(['bash', '-c',
            '. "$1"; fm_task_inbox_write_handled "$2" "$3" "$4"',
            'model-switch', library, str(state), task,
            '[fm-control] model switch: %s -> %s' % (was or 'default', route)],
            capture_output=True, text=True, check=True)
        seq = int(Path(result.stdout.strip()).stem)
        atomic_write(Path(state) / (task + '.model'), route + '\n')
        for receiver in receivers:
            active = receiver.active()
            if not (active and active.get('active') and active.get('supported') and active.get('set_model')):
                continue
            projection = receiver.root / active['turn']
            if not projection.is_dir():
                continue
            receiver.publish(active, before=seq)
            atomic_write(projection / ('%d.msg' % seq), body)
            receiver.publish(active)
            live = True
    return 'live' if live else 'next-turn'


def main(argv):
    if argv[:1] == ['check'] and len(argv) == 4 and argv[2] == '--policy':
        reason = check(argv[1], argv[3])
        if reason:
            print('error: %s' % reason, file=sys.stderr)
            return 1
        return 0
    if argv[:1] == ['supported'] and len(argv) == 3:
        return 0 if supported(argv[1], argv[2]) else 3
    if argv[:1] == ['publish'] and len(argv) == 5:
        try:
            print(publish(argv[1], argv[2], argv[3], argv[4]))
        except (OSError, ValueError, subprocess.CalledProcessError) as exc:
            print('error: model switch could not be published (%s)' % exc, file=sys.stderr)
            return 1
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
