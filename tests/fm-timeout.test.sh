#!/usr/bin/env bash
set -eu
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
python3 - "${FM_TEST_TIMEOUT_LIB:-$ROOT/bin/fm-timeout-lib.sh}" <<'PY'
import os
import pathlib
import shutil
import signal
import subprocess
import sys
import tempfile
import time

library = sys.argv[1]
bash = shutil.which('bash')
python = sys.executable
leaf_code = '''import os, pathlib, signal, sys, time
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()) + ' ' + str(os.getpgrp()))
time.sleep(15)
'''
command = '''"$1" -c "$2" "$3" &
while [ ! -s "$3" ]; do sleep 0.01; done
printf 'probe-complete\n'
if [ "$4" = wait ]; then wait; else exit "$4"; fi
'''
with tempfile.TemporaryDirectory(prefix='fm-timeout-', dir=os.environ.get('TMPDIR')) as temp:
    root = pathlib.Path(temp)
    outsider = subprocess.Popen([python, '-c', 'import time; time.sleep(30)'], start_new_session=True)
    try:
        for mechanism in ('timeout', 'gtimeout', 'perl', 'bash'):
            tools = root / mechanism
            tools.mkdir()
            for name in ('bash', 'mktemp', 'sleep', 'rm', 'cat'):
                (tools / name).symlink_to(shutil.which(name))
            if mechanism in ('timeout', 'gtimeout'):
                runner = shutil.which(mechanism) or shutil.which('timeout')
                if not runner:
                    continue
                (tools / mechanism).symlink_to(runner)
            elif mechanism == 'perl':
                (tools / 'perl').symlink_to(shutil.which('perl'))
            env = dict(os.environ, PATH=str(tools))
            env.pop('FM_TIMEOUT_MECHANISM_OVERRIDE', None)
            if mechanism == 'bash':
                env['FM_TIMEOUT_MECHANISM_OVERRIDE'] = 'bash'
            for result in ('0', '7', '124', '137', 'wait'):
                pidfile = root / (mechanism + '-' + result)
                proc = subprocess.Popen([
                    bash, '-c', '. "$1"; shift; fm_run_timed 1 "$@"', '_', library,
                    bash, '-c', command, '_', python, leaf_code, str(pidfile), result,
                ], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env, start_new_session=True)
                try:
                    out, err = proc.communicate(timeout=4)
                    expected = 124 if result == 'wait' else int(result)
                    assert proc.returncode == expected, (mechanism, result, proc.returncode, err)
                    assert out == b'probe-complete\n', (mechanism, result, out, err)
                    pid, group = map(int, pidfile.read_text().split())
                    for _ in range(50):
                        stat = subprocess.run(['ps', '-o', 'stat=', '-p', str(pid)], capture_output=True, text=True).stdout.strip()
                        if not stat or stat.startswith('Z'):
                            break
                        time.sleep(0.02)
                    else:
                        raise AssertionError((mechanism, result, 'owned descendant survived'))
                    assert outsider.poll() is None, 'unrelated process was signalled'
                finally:
                    if pidfile.exists():
                        _, group = map(int, pidfile.read_text().split())
                        try:
                            os.killpg(group, signal.SIGKILL)
                        except ProcessLookupError:
                            pass
                    if proc.poll() is None:
                        os.killpg(proc.pid, signal.SIGKILL)
                    proc.communicate(timeout=2)
    finally:
        outsider.terminate()
        outsider.wait(timeout=2)
print('ok - bounded capture closes owned descendant pipes and preserves command status')
PY
