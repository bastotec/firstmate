#!/usr/bin/env python3
"""Real-watcher fixtures with separate readiness/delivery and owned-tree cleanup.

Usage: watcher-queue-fixture.py checkpoint|edge WATCH BOUND [DIRECTORY]
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
state = pathlib.Path(os.environ["FM_STATE_OVERRIDE"])
selector = selectors.DefaultSelector()
boundary = None
errors = None
if mode == "edge":
    directory = pathlib.Path(arguments[0])
    sub = directory / "secondmate"
    fifo = directory / "boundary"
    os.mkfifo(fifo)
    boundary = os.open(fifo, os.O_RDWR | os.O_NONBLOCK)
    selector.register(boundary, selectors.EVENT_READ)
    errors = (directory / "watch.err").open("wb")
else:
    beacon = state / ".last-watcher-beat"
    if beacon.exists():
        beacon.unlink()

read_end, write_end = os.pipe()
# Keep clear of the production helpers' reserved low-numbered descriptors.
keeper = fcntl.fcntl(write_end, fcntl.F_DUPFD, 64)
os.close(write_end)
process = subprocess.Popen(
    [watch], stdout=subprocess.PIPE, stderr=errors, start_new_session=True,
    pass_fds=(keeper,),
)
os.close(keeper)
lifetime = selectors.DefaultSelector()
lifetime.register(read_end, selectors.EVENT_READ)
output = b""
quiet = False
try:
    if mode == "edge":
        assert selector.select(5), "watcher did not reach its first real poll wait"
        sleeper = int(os.read(boundary, 128).strip())
        os.kill(sleeper, 0)
        assert (state / ".watch.lock/pid").read_text().strip() == str(process.pid)
        assert (state / ".last-watcher-beat").exists()
        assert not (state / ".wake-queue").exists(), "wake appeared before foreign registration"
        (state / ".secondmate-wake-progress-mate").write_text("1002\t100-8\n")
        metadata = state / "mate.meta.tmp"
        metadata.write_text(f"window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome={sub}\n")
        started = time.monotonic()
        os.replace(metadata, state / "mate.meta")
        selector.unregister(boundary)
    else:
        selector.register(process.stdout, selectors.EVENT_READ)
        ready_until = time.monotonic() + 5
        while True:
            if beacon.exists() and (state / ".watch.lock/pid").read_text().strip() == str(process.pid):
                break
            if process.poll() is not None or time.monotonic() >= ready_until:
                raise AssertionError("watcher did not prove singleton/first-poll readiness")
            selector.select(0.01)
        selector.unregister(process.stdout)
        started = time.monotonic()
    selector.register(process.stdout, selectors.EVENT_READ)
    if selector.select(float(bound)):
        output = process.stdout.readline()
        assert output and time.monotonic() - started <= float(bound), "no bounded actionable delivery"
        if mode == "edge":
            assert output.decode().strip() == "check: secondmate wake-loop stalled: mate=mate row=8 idle=2s", output
    else:
        assert mode != "edge", f"no delivery within poll + publication ({bound}s)"
        quiet = True
        process.terminate()
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

remaining = process.stdout.read()
process.stdout.close()
if mode == "edge":
    assert process.returncode == 0, "watcher failed after delivery"
    assert not remaining, "duplicate or synthetic model wake"
    rows = (state / ".wake-queue").read_text().splitlines()
    assert len(rows) == 1 and rows[0].split("\t")[2:4] == ["check", "secondmate-wake-loop-mate-100-8"]
    assert (sub / "state/.wake-queue").read_text() == "100\t8\tcheck\thealthy\tcheck: healthy progress\n"
elif quiet:
    print(f"checkpoint: no actionable wake within {bound}s")
else:
    assert process.returncode == 0, "watcher failed after delivery"
    sys.stdout.buffer.write(output + remaining)
