#!/usr/bin/env python3
"""Stop local Deck drivers for one exact task before control-plane relaunch.

Usage: fm-deck-stop.py STATE TASK TIMEOUT
Matches the driver's launch prefix, never brief text, generation, or pane output.
Only a driver leading its own process group may be stopped. TERM asks the driver
and its active Deck child to stop, while active tools receive no signal. Deck's
exit confirms the post-tool stop handshake. A surviving group is killed after
TIMEOUT, and replacement is refused until every member has exited; zombies
cannot write. Legacy drivers need no PID registration. The backend's endpoint
proof remains required by fm-control.sh.
"""
import os
import re
import signal
import subprocess
import sys
import time


def processes():
    output = subprocess.check_output(
        ["ps", "-axww", "-o", "pid=,ppid=,pgid=,stat=,comm=,args="], text=True
    )
    rows = []
    for line in output.splitlines():
        fields = line.strip().split(None, 5)
        if len(fields) == 6:
            pid, parent, group, stat, command, args = fields
            rows.append(
                (int(pid), int(parent), int(group), stat, command, args)
            )
    return rows


def deck_processes(rows, group, executable):
    executable_name = os.path.basename(executable)
    matches = []
    for pid, _, process_group, stat, command, args in rows:
        if process_group != group or stat.startswith("Z"):
            continue
        words = args.split()
        leading = words[:3]
        command_name = os.path.basename(command)
        executable_index = leading.index(executable) if executable in leading else -1
        invoked_path = (
            executable_index >= 0
            and words[executable_index + 1 : executable_index + 2] == ["run"]
        )
        invoked_name = command_name == executable_name and words[1:2] == ["run"]
        if invoked_path or invoked_name:
            matches.append(pid)
    return matches


def stop(state, task, timeout):
    state = os.path.realpath(state)
    if not os.path.isdir(state):
        raise RuntimeError(f"state directory is unavailable: {state}")
    prefix = re.compile(
        r"^(?:fm-deck-worker|(?:\S*/)?bash) (?:\S*/)?fm-deck-worker\.sh "
        + re.escape(f"--id {task} --state {state} --gen ")
        + r"\S+ --deck (?P<deck>\S+)(?: |$)"
    )
    drivers = [
        (pid, group, prefix.match(args).group("deck"))
        for pid, _, group, stat, _, args in processes()
        if not stat.startswith("Z") and prefix.match(args)
    ]
    for pid, group, _ in drivers:
        if pid != group or group == os.getpgrp():
            raise RuntimeError(
                f"Deck driver {pid} does not lead an isolated process group"
            )
    groups = {group for _, group, _ in drivers}
    deck_pids = set()
    for pid, group, executable in drivers:
        rows = processes()
        if not any(
            process == pid and process_group == group and prefix.match(args)
            for process, _, process_group, _, _, args in rows
        ):
            continue
        active_decks = deck_processes(rows, group, executable)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        for deck_pid in active_decks:
            try:
                rows = processes()
                if deck_pid in deck_processes(rows, group, executable):
                    os.kill(deck_pid, signal.SIGTERM)
                    deck_pids.add(deck_pid)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + timeout
    while True:
        rows = processes()
        live_decks = {
            pid
            for pid, _, _, stat, _, _ in rows
            if pid in deck_pids and not stat.startswith("Z")
        }
        remaining = [
            pid
            for pid, _, group, stat, _, args in rows
            if not stat.startswith("Z") and (group in groups or prefix.match(args))
        ]
        if not live_decks and not remaining:
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
            for pid, _, group, stat, _, args in rows
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
