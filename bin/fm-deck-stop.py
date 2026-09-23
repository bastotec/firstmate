#!/usr/bin/env python3
"""Stop local Deck drivers for one exact task before control-plane relaunch.

Usage: fm-deck-stop.py STATE TASK TIMEOUT
Matches the driver's launch prefix, never brief text, generation, or pane output.
Only a driver leading its own process group may be stopped. The driver receives
TERM without its active tools, then a surviving group is killed after TIMEOUT.
Replacement is refused until every member has exited; zombies cannot write.
Legacy drivers need no PID registration, so older generations are covered.
The backend's endpoint proof remains required by fm-control.sh.
"""
import os
import re
import signal
import subprocess
import sys
import time


def processes():
    output = subprocess.check_output(
        ["ps", "-axww", "-o", "pid=,pgid=,stat=,args="], text=True
    )
    rows = []
    for line in output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            pid, group, stat, args = fields
            rows.append((int(pid), int(group), stat, args))
    return rows


def stop(state, task, timeout):
    state = os.path.realpath(state)
    if not os.path.isdir(state):
        raise RuntimeError(f"state directory is unavailable: {state}")
    prefix = re.compile(
        r"^(?:fm-deck-worker|(?:\S*/)?bash) (?:\S*/)?fm-deck-worker\.sh "
        + re.escape(f"--id {task} --state {state} --gen ")
        + r"\S+ --deck "
    )
    drivers = [
        (pid, group)
        for pid, group, stat, args in processes()
        if not stat.startswith("Z") and prefix.match(args)
    ]
    for pid, group in drivers:
        if pid != group or group == os.getpgrp():
            raise RuntimeError(
                f"Deck driver {pid} does not lead an isolated process group"
            )
    groups = {group for _, group in drivers}
    for pid, group in drivers:
        try:
            if any(
                p == pid and g == group and prefix.match(args)
                for p, g, _, args in processes()
            ):
                os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
    deadline = time.monotonic() + timeout
    while True:
        rows = processes()
        remaining = [
            pid
            for pid, group, stat, args in rows
            if not stat.startswith("Z") and (group in groups or prefix.match(args))
        ]
        if not remaining:
            return
        if time.monotonic() >= deadline:
            break
        time.sleep(0.1)
    for group in groups:
        try:
            os.killpg(group, signal.SIGKILL)
        except ProcessLookupError:
            pass
    kill_deadline = time.monotonic() + max(0.1, min(timeout, 1.0))
    while True:
        rows = processes()
        remaining = [
            pid
            for pid, group, stat, args in rows
            if not stat.startswith("Z") and (group in groups or prefix.match(args))
        ]
        if not remaining:
            return
        if time.monotonic() >= kill_deadline:
            raise RuntimeError(f"Deck driver group has not stopped: {remaining}")
        time.sleep(0.05)


if __name__ == "__main__":
    try:
        stop(sys.argv[1], sys.argv[2], float(sys.argv[3]))
    except (
        IndexError,
        ValueError,
        OSError,
        subprocess.SubprocessError,
        RuntimeError,
    ) as error:
        print(f"fm-deck-stop: {error}", file=sys.stderr)
        sys.exit(1)
