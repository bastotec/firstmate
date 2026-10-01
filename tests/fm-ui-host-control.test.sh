#!/usr/bin/env bash
# Public executable tests of host owner routing, intent-only notes and refusal.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-ui-host-control)
mkdir -p "$TMP_ROOT"
trap 'fm_test_cleanup' EXIT
python3 - "$ROOT" "$TMP_ROOT" <<'PY'
import json
import os
from pathlib import Path
import subprocess
import sys

root, temp = map(Path, sys.argv[1:])
router = root / 'bin/fm-ui-host-control.py'
home = temp / 'owner'
wrong = temp / 'wrong'
for directory in (home, wrong):
    (directory / 'state').mkdir(parents=True)
    (directory / 'config').mkdir()
(home / 'config/stream-machine').write_text('fixture-host\n')
registry = temp / 'registry'
primary = dict(machine='fixture-host', label='supervisor', fm_home=str(home), task_id=None)
task = dict(machine='fixture-host', label='fm-sample', fm_home=str(home), task_id='sample')

def write(rows):
    registry.write_text(json.dumps(rows))
    registry.chmod(0o600)


def run(label, *args):
    env = os.environ.copy()
    env.update(FM_HOME=str(wrong), FM_STATE_OVERRIDE=str(wrong / 'state'),
               FM_DATA_OVERRIDE=str(wrong / 'data'), FM_CONFIG_OVERRIDE=str(wrong / 'config'))
    return subprocess.run([str(router), '--registry', str(registry), '--machine',
                           'fixture-host', '--label', label, *args], env=env,
                          capture_output=True, text=True)


def refused(label, reason, *args):
    result = run(label, *args)
    assert result.returncode != 0 and reason in result.stderr, result

write([primary])
registry.write_text('[{"machine":"fixture-host","machine":"other"}]')
refused('supervisor', 'ambiguous registry field', 'note', '--text', 'fixture intent')
write([primary])
link = temp / 'registry-link'
os.link(registry, link)
refused('supervisor', 'single-link', 'note', '--text', 'fixture intent')
link.unlink()
registry.rename(link)
registry.symlink_to(link)
refused('supervisor', 'REFUSED', 'note', '--text', 'fixture intent')
registry.unlink()
link.rename(registry)
refused('missing', 'unknown or ambiguous', 'note', '--text', 'fixture intent')
refused('supervisor', 'primary lifecycle is unsupported', 'exit')
refused('supervisor', 'note must not be blank', 'note', '--text', ' ')
registry.chmod(0o644)
refused('supervisor', '0600', 'note', '--text', 'fixture intent')
write([primary, primary])
refused('supervisor', 'ambiguous registry', 'note', '--text', 'fixture intent')
write([dict(primary, label='alias'), primary])
refused('supervisor', 'ambiguous registry', 'note', '--text', 'fixture intent')
write([primary])
(home / 'config/stream-machine').write_text('different-host\n')
refused('supervisor', 'disagrees', 'note', '--text', 'fixture intent')
(home / 'config/stream-machine').write_text('fixture-host\n')
result = run('supervisor', 'note', '--text', 'fixture intent, not a decision closure')
assert result.returncode == 0, result
assert list((home / 'state/inbox').glob('*.note')), result
assert not list((wrong / 'state').iterdir())
assert not list((home / 'state').glob('*.status'))
write([task])
refused('fm-sample', 'no regular owner metadata', 'interrupt')
(home / 'state/sample.meta').write_text('remote_host=fixture-remote\n')
# This is the real fm-control refusal, not a replacement shim: remote ownership
# checks remain authoritative behind the host binding.
refused('fm-sample', 'remotely placed secondmate', 'interrupt')
write([dict(task, task_id='../sample')])
refused('fm-sample', 'invalid exact task id', 'interrupt')
write([dict(task, label='sample')])
refused('sample', 'publisher label', 'interrupt')
write([primary])
refused('supervisor', 'invalid choice', 'resolve-key')
print('host routing: owner inbox, unknown/ambiguous/stale bindings, primary and remote lifecycle refusal passed')
PY
