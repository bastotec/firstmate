#!/usr/bin/env bash
# tests/fm-stream-agent-kill-safety.test.sh - the stream agent must never
# deliver a signal to a process group it does not own.
#
# The endpoint's pseudoterminal is killed by signalling a whole process group,
# which is the most destructive primitive in this backend: get the target wrong
# and it does not fail, it kills whatever now answers to that id. On this fleet
# the neighbours are other workers' harnesses, so a wrong target costs a live
# worker rather than a test.
#
# Two properties keep the target honest, and both are pinned here.
#
# The first is that a pid is only safe to name while the child is UNREAPED. A
# zombie still holds its pid, so it cannot be recycled; the moment anything
# calls poll() and reaps it, the kernel may hand that pid to an unrelated
# process. The agent reads liveness from several threads at once, and poll() is
# what reads it, so the check and the signal have to be one atomic step rather
# than two racing ones.
#
# The second is that the endpoint must be in a session of its own. That is what
# makes killing its whole group safe at all, and if the child's setsid() ever
# failed, the group the agent would signal would be the agent's own - taking
# down the agent and whatever launched it.
#
# Real pid reuse cannot be provoked portably (this kernel's pid_max is in the
# millions), so these cases point the recorded target at a sentinel the case
# owns and assert the sentinel's survival. The sentinel stands in for the
# stranger a recycled pid would name.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the stream agent kill-safety guard"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE_DIR=$(fm_test_tmproot fm-stream-agent-kill)

cat > "$CASE_DIR/drive.py" <<'PY'
"""Drive the agent's real Pty through each kill-safety property."""
import importlib.util
import os
import select
import signal
import subprocess
import sys
import threading
import time
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("fm_stream_agent", sys.argv[1])
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)

RESULTS = []


def report(name, ok, detail=""):
    RESULTS.append((name, ok, detail))


def sentinel():
    """An innocent bystander in a process group of its own."""
    proc = subprocess.Popen(["sleep", "300"], preexec_fn=os.setsid,
                            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return proc, os.getpgid(proc.pid)


def alive(pid):
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def make_pty(command):
    return agent.Pty(os.getcwd(), command, 40, 200, dict(os.environ))


real_write = os.write
chunks = []


def short_write(fd, data):
    chunk = bytes(data[:3])
    chunks.append(chunk)
    return len(chunk)


partial = object.__new__(agent.Pty)
partial.master_fd = 123
agent.os.write = short_write
try:
    count = partial.write(b"composer-order\r")
finally:
    agent.os.write = real_write
report("partial-write-completes",
       count == len(b"composer-order\r") and b"".join(chunks) == b"composer-order\r",
       "count=%r bytes=%r" % (count, b"".join(chunks)))


class ShutdownPty:
    exit_code = 0

    def __init__(self):
        self.probing = threading.Event()
        self.unblock = threading.Event()
        self.probe_done = threading.Event()
        self.closed = threading.Event()
        self.released = threading.Event()
        self.released_during_probe = None

    def alive(self):
        return not self.closed.is_set()

    def foreground_processes(self, until):
        return []

    def foreground_cwd(self, until):
        assert until is None
        self.probing.set()
        self.unblock.wait()
        self.probe_done.set()
        return ""

    def close(self):
        self.closed.set()

    def release(self):
        self.released_during_probe = not self.probe_done.is_set()
        self.released.set()


class ShutdownHub:
    deadline = None

    def __init__(self):
        self.closing = threading.Event()
        self.frames = []

    def call(self, method, path, payload, timeout):
        self.frames.extend(payload['frames'])
        if any(frame.get('closed') for frame in payload['frames']):
            self.closing.set()
        return {}


class ShutdownAgent(agent.Agent):
    def read_loop(self):
        self.stop.wait()
        self.reader_done.set()

    def command_loop(self):
        self.stop.wait()


for embedded in (False, True):
    mode = 'embedded' if embedded else 'standalone'
    pty = ShutdownPty()
    hub = ShutdownHub()
    options = SimpleNamespace(machine='fixture', status_path='', state_interval=0.01)
    publisher = ShutdownAgent(options, hub, pty, 'fixture-'+mode)

    def stop_during_probe():
        try:
            blocked = pty.probing.wait(2)
            report(mode+'-probe-blocked', blocked)
            publisher.halt()
            report(mode+'-pty-closed', pty.closed.wait(2))
            closed_before_unblock = hub.closing.wait(0.2 if embedded else 2)
            report(mode+'-shutdown-retirement',
                   not closed_before_unblock and not pty.released.is_set() if embedded
                   else closed_before_unblock and pty.released.is_set(),
                   'closed=%r released=%r while state probe blocked' % (
                       closed_before_unblock, pty.released.is_set()))
        finally:
            publisher.halt()
            pty.unblock.set()

    controller = threading.Thread(target=stop_during_probe)
    previous_signals = {sig: signal.getsignal(sig) for sig in (signal.SIGTERM, signal.SIGINT)}
    controller.start()
    try:
        result = publisher.run(install_signals=not embedded)
    finally:
        controller.join(5)
        for sig, disposition in previous_signals.items():
            signal.signal(sig, disposition)
    report(mode+'-shutdown-completes', result == 0 and not controller.is_alive()
           and pty.probe_done.wait(2) and pty.released.is_set()
           and pty.released_during_probe == (not embedded)
           and any(frame.get('closed') and frame['state']['alive'] is False
                   for frame in hub.frames))


class StartupAgent(agent.Agent):
    def command_loop(self):
        self.stop.wait()


for failed_name in ('pty-reader', 'state', 'commands'):
    pty = make_pty(['sleep', '300'])
    descriptor = pty.master_fd
    hub = ShutdownHub()
    options = SimpleNamespace(machine='fixture', status_path='', state_interval=60)
    publisher = StartupAgent(options, hub, pty, 'fixture-startup')
    started = []
    original_start = threading.Thread.start

    def injected_start(thread):
        if thread.name == failed_name:
            raise RuntimeError('fixture internal thread start failure')
        original_start(thread)
        started.append(thread)

    descriptor_open = True
    try:
        threading.Thread.start = injected_start
        error = ''
        try:
            publisher.run(install_signals=False)
        except RuntimeError as exc:
            error = str(exc)
        try:
            os.fstat(descriptor)
        except OSError:
            descriptor_open = False
        expected = {'pty-reader': [], 'state': ['pty-reader'],
                    'commands': ['pty-reader', 'state']}[failed_name]
        report('partial-startup-'+failed_name,
               error == 'fixture internal thread start failure'
               and [thread.name for thread in started] == expected
               and all(not thread.is_alive() for thread in started)
               and publisher.stop.is_set() and not pty.alive()
               and not descriptor_open and hub.closing.is_set(),
               'error=%r threads=%r descriptor_open=%r closed=%r' % (
                   error, [(thread.name, thread.is_alive()) for thread in started],
                   descriptor_open, hub.closing.is_set()))
    finally:
        threading.Thread.start = original_start
        publisher.halt()
        pty.close('KILL')
        for thread in started:
            thread.join(5)
        if descriptor_open:
            pty.release()


def read_until(pty, marker, timeout):
    """Accumulate pty output until <marker> appears or <timeout> expires."""
    output = b""
    deadline = time.monotonic() + timeout
    while marker not in output and time.monotonic() < deadline:
        if select.select([pty.master_fd], [], [], 0.1)[0]:
            output += pty.read()
    return output


# --- ignored launcher SIGINT must not disable the PTY child's trap ---------
# Each case execs a real shell, installs its own interrupt handler, and receives
# Ctrl+C through the terminal rather than by directly signalling the child.
for disposition in (int(signal.SIG_DFL), int(signal.SIG_IGN)):
    previous = signal.signal(signal.SIGINT, disposition)
    pty = None
    try:
        pty = make_pty(["/bin/sh", "-c",
                        "trap 'echo INTERRUPT_HANDLED; exit 0' INT; "
                        "echo CHILD_READY; while :; do sleep 0.1; done"])
        output = read_until(pty, b"CHILD_READY", 5)
        report("child-ready-with-parent-sigint-%s" % disposition,
               b"CHILD_READY" in output,
               "expected CHILD_READY within 5s, got %r" % output)
        pty.write(b"\x03")
        output += read_until(pty, b"INTERRUPT_HANDLED", 5)
        report("child-handles-sigint-with-parent-%s" % disposition,
               b"INTERRUPT_HANDLED" in output,
               "expected INTERRUPT_HANDLED within 5s of Ctrl+C, got %r" % output)
        report("parent-sigint-disposition-unchanged-%s" % disposition,
               signal.getsignal(signal.SIGINT) == disposition)
    finally:
        if pty is not None:
            pty.close("KILL")
            pty.release()
        signal.signal(signal.SIGINT, previous)

# --- the endpoint really is isolated in its own session ---------------------
pty = make_pty(["sleep", "300"])
try:
    own_sid = os.getsid(0)
    child_sid = os.getsid(pty.pid)
    report("endpoint-is-session-leader",
           child_sid == pty.pid and child_sid != own_sid,
           "child sid=%s pid=%s agent sid=%s" % (child_sid, pty.pid, own_sid))
    report("recorded-pgid-matches-kernel",
           pty.pgid == os.getpgid(pty.pid),
           "recorded=%s kernel=%s" % (pty.pgid, os.getpgid(pty.pid)))
finally:
    pty.close("KILL")
    pty.release()

# --- a live endpoint is still killed, so the guard is not vacuous -----------
pty = make_pty(["sleep", "300"])
child = pty.pid
killed = pty.close("KILL")
pty.release()
deadline = time.time() + 5
while time.time() < deadline and alive(child):
    time.sleep(0.05)
report("live-endpoint-is-killed", killed and not alive(child),
       "close() returned %r, child alive=%r" % (killed, alive(child)))

# --- a reaped endpoint is never signalled ----------------------------------
guard, guard_pgid = sentinel()
pty = make_pty(["true"])
deadline = time.time() + 5
while time.time() < deadline and pty.alive():
    time.sleep(0.02)
# alive() above has already reaped it; the pid is now free for the kernel to
# reuse, which is exactly when naming it becomes unsafe.
pty.pgid = guard_pgid
signalled = pty.close("KILL")
pty.release()
time.sleep(0.3)
report("reaped-endpoint-is-not-signalled",
       not signalled and alive(guard.pid),
       "close() returned %r, bystander alive=%r" % (signalled, alive(guard.pid)))
os.killpg(guard_pgid, signal.SIGKILL)
guard.wait()

# --- a concurrent reaper cannot let a signal escape mid-close --------------
escaped = None
for attempt in range(40):
    guard, guard_pgid = sentinel()
    pty = make_pty(["true"])
    pty.pgid = guard_pgid
    # Hammer the liveness read from another thread, which is what reaps the
    # child, while close() decides whether to signal.
    stop = threading.Event()

    def hammer(p=pty, s=stop):
        while not s.is_set():
            p.alive()

    t = threading.Thread(target=hammer, daemon=True)
    t.start()
    pty.close("KILL")
    stop.set()
    t.join(2)
    pty.release()
    time.sleep(0.05)
    if not alive(guard.pid):
        escaped = attempt
    try:
        os.killpg(guard_pgid, signal.SIGKILL)
    except OSError:
        pass
    guard.wait()
    if escaped is not None:
        break
report("concurrent-reap-never-escapes", escaped is None,
       "a signal reached the bystander on attempt %s" % escaped)

# --- the agent refuses to signal its own group ------------------------------
pty = make_pty(["sleep", "300"])
child = pty.pid
pty.pgid = os.getpgrp()
signalled = pty.close("KILL")
report("refuses-own-process-group", not signalled,
       "close() returned %r while targeting this process's own group" % signalled)
pty.pgid = child
pty.close("KILL")
pty.release()

# --- the agent refuses to signal its own session ----------------------------
pty = make_pty(["sleep", "300"])
child = pty.pid
pty.pgid = os.getsid(0)
signalled = pty.close("KILL")
report("refuses-own-session", not signalled,
       "close() returned %r while targeting this process's own session" % signalled)
pty.pgid = child
pty.close("KILL")
pty.release()

for name, ok, detail in RESULTS:
    print("%s %s %s" % ("OK" if ok else "FAIL", name, detail))
PY

out=$(python3 "$CASE_DIR/drive.py" "$ROOT/bin/fm-stream-agent.py" 2>"$CASE_DIR/drive.err")
rc=$?
[ "$rc" -eq 0 ] || fail "the kill-safety driver did not finish: $(head -5 "$CASE_DIR/drive.err" 2>/dev/null)"

for case_name in partial-write-completes \
  partial-startup-pty-reader partial-startup-state partial-startup-commands \
  standalone-probe-blocked standalone-pty-closed standalone-shutdown-retirement standalone-shutdown-completes \
  embedded-probe-blocked embedded-pty-closed embedded-shutdown-retirement embedded-shutdown-completes \
  child-ready-with-parent-sigint-0 child-ready-with-parent-sigint-1 \
  child-handles-sigint-with-parent-0 child-handles-sigint-with-parent-1 \
  parent-sigint-disposition-unchanged-0 parent-sigint-disposition-unchanged-1 \
  endpoint-is-session-leader recorded-pgid-matches-kernel \
  live-endpoint-is-killed reaped-endpoint-is-not-signalled \
  concurrent-reap-never-escapes refuses-own-process-group refuses-own-session; do
  line=$(printf '%s\n' "$out" | grep -E "^(OK|FAIL) $case_name( |$)") \
    || fail "$case_name: the driver reported no verdict at all, so this guard proved nothing"
  case $line in
    OK*) pass "stream agent kill safety: $case_name" ;;
    *) fail "stream agent kill safety: ${line#FAIL }" ;;
  esac
done

# The refusal has to be loud, or an endpoint whose isolation broke would be
# silently left running with no sign that cleanup declined to touch it.
grep -q "REFUSING to signal process group" "$CASE_DIR/drive.err" \
  || fail "the agent refused to signal its own group but said nothing about it on stderr"
pass "stream agent kill safety: the refusal names the group it would not signal"

# --- the suite's own kill guard ---------------------------------------------
#
# The cases above cover the agent. This covers the backstop on the test side:
# a suite that resolves a publisher's pid by matching a command line must refuse
# to signal anything that turns out to be the harness running it. Firstmate
# passes a task's whole brief on the harness command line, so a harness whose
# brief merely quotes a script's filename already matches a pattern built from
# that filename alone.
#
# The refusal cases drive the PREDICATE, never the killer. Asking the killer to
# prove it will not kill this suite's own parent means a broken guard kills this
# suite's own parent, which is exactly the outcome the guard exists to prevent.

why=
if fm_test_pid_is_foreign "$$" why; then
  fail "the kill guard treats this test process itself as safe to signal"
fi
case $why in
  *"this test process"*) pass "stream agent kill safety: the suite's kill guard refuses itself" ;;
  *) fail "the guard refused this test process but gave the wrong reason: $why" ;;
esac

why=
if fm_test_pid_is_foreign "$PPID" why; then
  fail "the kill guard treats this suite's own parent ($PPID) as safe to signal"
fi
case $why in
  *ancestor*) pass "stream agent kill safety: the suite's kill guard refuses an ancestor" ;;
  *) fail "the guard refused this suite's parent but gave the wrong reason: $why" ;;
esac

why=
if fm_test_pid_is_foreign 1 why; then
  fail "the kill guard treats pid 1 as safe to signal"
fi
pass "stream agent kill safety: the suite's kill guard refuses pid 1"

# The guard must still deliver a signal it CAN prove is safe. A non-interactive
# shell has no job control, so a helper a case starts shares this suite's own
# process group - a guard keyed on the process group would refuse every real
# publisher and quietly turn the partition cases into no-ops.
sleep 30 &
helper=$!
disown "$helper" 2>/dev/null || true
helper_pgid=$(ps -o pgid= -p "$helper" 2>/dev/null | tr -d ' ')
own_pgid=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d ' ')
[ -n "$helper_pgid" ] || fail "could not start a helper probe process"
[ "$helper_pgid" = "$own_pgid" ] || fail \
  "this case needs a helper sharing the suite's process group to be meaningful, but got '$helper_pgid' vs '$own_pgid'"
fm_test_kill_foreign_pid "$helper" "helper probe"
waited=0
while [ "$waited" -lt 50 ] && kill -0 "$helper" 2>/dev/null; do
  sleep 0.1
  waited=$((waited + 1))
done
kill -0 "$helper" 2>/dev/null && fail \
  "the kill guard refused a helper this case started, which would turn every partition case into a no-op"
pass "stream agent kill safety: the suite's kill guard still signals a helper it started"
