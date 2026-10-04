import json, os, pathlib, shlex, subprocess, sys

root = pathlib.Path.cwd()
source = '. ' + shlex.quote(str(root / 'bin/backends/stream.sh')) + '; '
python = shlex.quote(sys.executable)
arguments = ['two words', 'literal;$(no-command)', '', "quote'"]
probe = ('import os,json,sys,time; time.sleep(.3); '
         'print(json.dumps(dict(pid=os.getpid(), pgid=os.getpgrp(), sid=os.getsid(0), '
         'ppid=os.getppid(), argv=sys.argv[1:], cwd=os.getcwd(), marker=os.getenv("FM_DETACHED_PROBE"))), flush=True)')
env = dict(os.environ, FM_DETACHED_PROBE='detachment preserved')
command = python + ' -c ' + shlex.quote(probe) + ' ' + shlex.join(arguments)
assert subprocess.run(['/bin/bash', '-c', 'command -v setsid'], capture_output=True).returncode != 0

process = subprocess.Popen(['/bin/bash', '-c', source + '(fm_backend_stream_detached ' + command + ' &); exit'], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env)
status = process.wait(timeout=5)
print(f'spawn subshell exited before endpoint observation: pid={process.pid} exit={status}', flush=True)
out, err = process.communicate(timeout=5)
record = json.loads(out)
print(json.dumps(record), flush=True)
assert status == 0 and not err
assert record['pid'] == record['pgid'] == record['sid']
assert record['argv'] == arguments and record['cwd'] == str(root)
assert record['marker'] == 'detachment preserved'
assert record['ppid'] != process.pid
print('PASS real macOS fallback: session leader, PGID==PID, survived spawn caller exit, exact argv/env/cwd preserved')

result = subprocess.run(['/bin/bash', '-c', source + 'fm_backend_stream_detached ' + python + ' -c "raise SystemExit(37)"'], capture_output=True)
assert result.returncode == 37
print('PASS command exit status propagated: 37')
result = subprocess.run(['/bin/bash', '-c', source + 'fm_backend_stream_detached /no/such/fm-detached-command'], capture_output=True)
assert result.returncode and b'exec:' in result.stderr
print('PASS missing command refuses:', result.returncode, result.stderr.decode().strip())

# Force the actual Perl call to run in the already-detached session leader,
# so the kernel, not a mock, rejects a second setsid call with EPERM.
rejection = source + 'perl() { exec /usr/bin/perl "$@"; }; fm_backend_stream_detached /bin/echo COMMAND-MUST-NOT-RUN'
result = subprocess.run(['/bin/bash', '-c', rejection], capture_output=True, preexec_fn=os.setsid)
assert result.returncode and not result.stdout and b'setsid:' in result.stderr and b'Operation not permitted' in result.stderr
print('PASS real kernel setsid rejection:', result.returncode, 'stdout=', repr(result.stdout.decode()), 'stderr=', repr(result.stderr.decode()))

# No setsid(1) is installed on this Mac. This explicitly non-native shim
# exercises selection and argument forwarding while performing real detachment.
shim = 'setsid() { printf "setsid branch selected\\n" >&2; /usr/bin/perl -MPOSIX -e \'POSIX::setsid() >= 0 or die "setsid: $!\\n"; exec @ARGV or die "exec: $!\\n"\' "$@"; }; '
result = subprocess.run(['/bin/bash', '-c', source + shim + 'fm_backend_stream_detached ' + command], capture_output=True, env=env)
record = json.loads(result.stdout)
assert result.returncode == 0 and result.stderr == b'setsid branch selected\n'
assert record['pid'] == record['pgid'] == record['sid'] and record['argv'] == arguments
print('PASS setsid-present selection (non-native function shim):', json.dumps(record), 'stderr=', repr(result.stderr.decode()))

# Exercise both sentinel return values independently; these are fault injections,
# not claims of two live kernel failures.
for sentinel in ['undef', '-1']:
    override = 'BEGIN { no warnings "redefine"; *POSIX::setsid = sub { $! = 1; return ' + sentinel + ' } }'
    shim = 'perl() { /usr/bin/perl -MPOSIX -e ' + shlex.quote(override) + ' "$@"; }; '
    result = subprocess.run(['/bin/bash', '-c', source + shim + 'fm_backend_stream_detached /bin/echo COMMAND-MUST-NOT-RUN'], capture_output=True)
    assert result.returncode and not result.stdout and b'setsid: Operation not permitted' in result.stderr
    print('PASS injected ' + sentinel + ' setsid result:', result.returncode, 'stdout=', repr(result.stdout.decode()), 'stderr=', repr(result.stderr.decode()))
