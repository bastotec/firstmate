#!/usr/bin/env python3
"""Real-watcher fixtures with separate readiness/delivery and owned-tree cleanup.

Usage: watcher-queue-fixture.py checkpoint|edge WATCH BOUND [DIRECTORY]
Checkpoint stages endpoint registration until singleton/first-poll readiness;
edge registers it at the real poll wait. Both record setup and delivery timings.
A private inherited descriptor stays open throughout background publication,
including children in timeout-created process groups. EOF proves those children
finished before the next case; waiting for the watcher PID alone does not.
The existing two-second cleanup allowance covers both PID reaping and EOF.
"""
import fcntl
import os
import pathlib
import selectors
import signal
import subprocess
import sys
import time

mode, watch, bound, *arguments = sys.argv[1:]
assert mode in ("checkpoint", "edge")
bound = float(bound)
assert bound == float(os.environ["FM_POLL"]) + 1
state = pathlib.Path(os.environ["FM_STATE_OVERRIDE"])
selector = selectors.DefaultSelector()
boundary = None
errors = None
registration = state / "mate.meta"
staged = state / ".fixture-mate-registration"
if mode == "edge":
    directory = pathlib.Path(arguments[0])
    sub = directory / "secondmate"
    fifo = directory / "boundary"
    os.mkfifo(fifo)
    boundary = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    selector.register(boundary, selectors.EVENT_READ)
    errors = (directory / "watch.err").open("wb")
else:
    os.replace(registration, staged)
    beacon = state / ".last-watcher-beat"
    beacon.unlink(missing_ok=True)

read_end, write_end = os.pipe()
# Keep clear of the production helpers' reserved low-numbered descriptors.
keeper = fcntl.fcntl(write_end, fcntl.F_DUPFD, 64)
os.close(write_end)
setup_started = time.monotonic()
process = subprocess.Popen(
    [watch], stdout=subprocess.PIPE, stderr=errors, start_new_session=True,
    pass_fds=(keeper,),
)
os.close(keeper)
lifetime = selectors.DefaultSelector()
lifetime.register(read_end, selectors.EVENT_READ)
selector.register(process.stdout, selectors.EVENT_READ)
output = b""
quiet = False


def lock_owner():
    try:
        return (state / ".watch.lock/pid").read_text().strip()
    except FileNotFoundError:
        return ""


def receive(events):
    global output
    for key, _ in events:
        if key.fileobj is process.stdout:
            chunk = os.read(process.stdout.fileno(), 65536)
            assert chunk, "watcher exited without actionable delivery"
            output += chunk
    if b"\n" in output:
        assert output.startswith(b"check: secondmate wake-loop stalled:"), output
        return True
    return False


try:
    ready_until = setup_started + 5
    while True:
        events = selector.select(max(0, min(0.01, ready_until - time.monotonic())))
        if receive(events):
            break
        if mode == "edge":
            if any(key.fd == boundary for key, _ in events):
                sleeper = int(os.read(boundary, 128).strip())
                os.kill(sleeper, 0)
                assert lock_owner() == str(process.pid)
                assert (state / ".last-watcher-beat").exists()
                assert not (state / ".wake-queue").exists(), "wake appeared before foreign registration"
                (state / ".secondmate-wake-progress-mate").write_text("1002\t100-8\n")
                staged.write_text(f"window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome={sub}\n")
                selector.unregister(boundary)
                break
        elif beacon.exists() and lock_owner() == str(process.pid):
            break
        if process.poll() is not None or time.monotonic() >= ready_until:
            raise AssertionError("watcher did not prove singleton/first-poll readiness within 5s")
    ready_at = time.monotonic()
    assert ready_at <= ready_until, "watcher readiness exceeded 5s"
    print(f"fixture: readiness={ready_at - setup_started:.6f}s bound=5s mode={mode}", file=sys.stderr)
    if b"\n" not in output:
        started = time.monotonic()
        os.replace(staged, registration)
        print("fixture: injection=atomic-endpoint-registration", file=sys.stderr)
        deadline = started + bound
        while not receive(selector.select(max(0, deadline - time.monotonic()))):
            if time.monotonic() >= deadline:
                assert mode != "edge", f"no delivery within poll + publication ({bound}s)"
                quiet = True
                process.terminate()
                break
        elapsed = time.monotonic() - started
        if not quiet:
            assert elapsed <= bound, f"actionable delivery exceeded {bound}s: {elapsed}s"
        print(f"fixture: delivery={elapsed:.6f}s bound={bound}s result={'quiet' if quiet else 'actionable'}", file=sys.stderr)
    else:
        print("fixture: delivery=completed-during-readiness", file=sys.stderr)
    if mode == "edge":
        assert output.decode().strip() == "check: secondmate wake-loop stalled: mate=mate row=8 idle=2s", output
finally:
    # One bounded cleanup, never a retry or extra delivery allowance. On success
    # let the watcher's normal EXIT and publication children finish naturally.
    cleanup_until = time.monotonic() + 2
    try:
        if sys.exc_info()[0] is not None and process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
        process.wait(timeout=max(0, cleanup_until - time.monotonic()))
        assert lifetime.select(max(0, cleanup_until - time.monotonic())), "watcher publication descendants outlived fixture cleanup"
        assert os.read(read_end, 1) == b"", "unexpected data on the fixture lifetime pipe"
    except BaseException:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait()
        raise
    finally:
        selector.close()
        lifetime.close()
        os.close(read_end)
        if boundary is not None:
            os.close(boundary)
        if errors is not None:
            errors.close()
        if staged.exists():
            os.replace(staged, registration)

remaining = process.stdout.read()
process.stdout.close()
if quiet:
    assert not output and not remaining, "actionable delivery raced the quiet deadline"
    print(f"checkpoint: no actionable wake within {bound}s")
else:
    assert process.returncode == 0, "watcher failed after delivery"
    delivery = output + remaining
    assert delivery.endswith(b"\n") and delivery.count(b"\n") == 1, "duplicate or synthetic model wake"
    sys.stdout.buffer.write(delivery)
if mode == "edge":
    rows = (state / ".wake-queue").read_text().splitlines()
    assert len(rows) == 1 and rows[0].split("\t")[2:4] == ["check", "secondmate-wake-loop-mate-100-8"]
    assert (sub / "state/.wake-queue").read_text() == "100\t8\tcheck\thealthy\tcheck: healthy progress\n"
