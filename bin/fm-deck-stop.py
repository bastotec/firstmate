#!/usr/bin/env python3
"""Stop local Deck drivers for one exact task before control-plane relaunch.

Usage: fm-deck-stop.py STATE TASK TIMEOUT
Matches the driver's launch arguments, never brief text, generation, or pane
output. Only a driver leading its own process group may be stopped. TERM asks
the driver and its active Deck child to stop, while active tools receive no
signal. Deck's exit confirms the post-tool stop handshake. A surviving group is
killed after TIMEOUT, and replacement is refused until every member has exited;
zombies cannot write. Legacy drivers need no PID registration. The backend's
endpoint proof remains required by fm-control.sh.
"""
import ctypes
import errno
import os
import signal
import subprocess
import sys
import time


def processes():
    output = subprocess.check_output(
        ["ps", "-ax", "-o", "pid=,ppid=,pgid=,stat="], text=True
    )
    rows = []
    for line in output.splitlines():
        fields = line.strip().split(None, 3)
        if len(fields) == 4:
            pid, parent, group, stat = fields
            rows.append((int(pid), int(parent), int(group), stat))
    return rows


def darwin_process_arguments(pid):
    libc = ctypes.CDLL(None, use_errno=True)
    capacity = ctypes.c_int()
    capacity_size = ctypes.c_size_t(ctypes.sizeof(capacity))
    sysctlbyname = libc.sysctlbyname
    sysctlbyname.argtypes = [
        ctypes.c_char_p,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    if sysctlbyname(
        b"kern.argmax", ctypes.byref(capacity), ctypes.byref(capacity_size), None, 0
    ) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    mib = (ctypes.c_int * 3)(1, 49, pid)
    size = ctypes.c_size_t(capacity.value)
    buffer = ctypes.create_string_buffer(capacity.value)
    sysctl = libc.sysctl
    sysctl.argtypes = [
        ctypes.POINTER(ctypes.c_int),
        ctypes.c_uint,
        ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t),
        ctypes.c_void_p,
        ctypes.c_size_t,
    ]
    if sysctl(mib, 3, buffer, ctypes.byref(size), None, 0) != 0:
        error = ctypes.get_errno()
        if error in (errno.EINVAL, errno.ESRCH, errno.EPERM):
            return None
        raise OSError(error, os.strerror(error))
    data = buffer.raw[: size.value]
    integer_size = ctypes.sizeof(ctypes.c_int)
    if len(data) < integer_size:
        return None
    count = int.from_bytes(data[:integer_size], sys.byteorder, signed=True)
    offset = data.find(b"\0", integer_size)
    if offset < 0:
        return None
    while offset < len(data) and data[offset] == 0:
        offset += 1
    arguments = []
    while len(arguments) < count and offset < len(data):
        end = data.find(b"\0", offset)
        if end < 0:
            break
        arguments.append(os.fsdecode(data[offset:end]))
        offset = end + 1
    return arguments if len(arguments) == count else None


def process_arguments(pid):
    if sys.platform.startswith("linux"):
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as stream:
                return [
                    os.fsdecode(value)
                    for value in stream.read().split(b"\0")
                    if value
                ]
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            return None
    if sys.platform == "darwin":
        return darwin_process_arguments(pid)
    raise RuntimeError(f"unsupported process argument platform: {sys.platform}")


def driver_deck(arguments, worker, state, task):
    if not arguments or len(arguments) < 3:
        return None
    if os.path.basename(arguments[0]) not in ("bash", "fm-deck-worker"):
        return None
    if os.path.realpath(arguments[1]) != worker:
        return None
    options = {}
    position = 2
    while position < len(arguments) and arguments[position] != "--":
        option = arguments[position]
        if option not in ("--id", "--state", "--gen", "--deck", "--model"):
            return None
        if option in options or position + 1 >= len(arguments):
            return None
        options[option] = arguments[position + 1]
        position += 2
    if position >= len(arguments) or arguments[position] != "--":
        return None
    if options.get("--id") != task or not options.get("--gen"):
        return None
    if os.path.realpath(options.get("--state", "")) != state:
        return None
    deck = options.get("--deck")
    return os.path.realpath(deck) if deck else None


def find_drivers(rows, worker, state, task):
    matches = []
    for pid, _, group, stat in rows:
        if pid != group or stat.startswith("Z"):
            continue
        deck = driver_deck(process_arguments(pid), worker, state, task)
        if deck:
            matches.append((pid, group, deck))
    return matches


def deck_processes(rows, driver, group, executable):
    matches = []
    for pid, parent, process_group, stat in rows:
        if parent != driver or process_group != group or stat.startswith("Z"):
            continue
        arguments = process_arguments(pid)
        if not arguments:
            continue
        for index in range(min(2, len(arguments))):
            if (
                os.path.realpath(arguments[index]) == executable
                and arguments[index + 1 : index + 2] == ["run"]
            ):
                matches.append(pid)
                break
    return matches


def stop(state, task, timeout):
    state = os.path.realpath(state)
    worker = os.path.realpath(
        os.path.join(os.path.dirname(__file__), "fm-deck-worker.sh")
    )
    if not os.path.isdir(state):
        raise RuntimeError(f"state directory is unavailable: {state}")
    drivers = find_drivers(processes(), worker, state, task)
    for pid, group, _ in drivers:
        if group == os.getpgrp():
            raise RuntimeError(
                f"Deck driver {pid} does not lead an isolated process group"
            )
    groups = {group for _, group, _ in drivers}
    deck_pids = set()
    for pid, group, executable in drivers:
        rows = processes()
        if (pid, group, executable) not in find_drivers(rows, worker, state, task):
            continue
        active_decks = deck_processes(rows, pid, group, executable)
        try:
            os.kill(pid, signal.SIGTERM)
        except ProcessLookupError:
            continue
        for deck_pid in active_decks:
            try:
                rows = processes()
                if deck_pid in deck_processes(rows, pid, group, executable):
                    os.kill(deck_pid, signal.SIGTERM)
                    deck_pids.add(deck_pid)
            except ProcessLookupError:
                pass
    deadline = time.monotonic() + timeout
    while True:
        rows = processes()
        live_decks = {
            pid
            for pid, _, _, stat in rows
            if pid in deck_pids and not stat.startswith("Z")
        }
        remaining = [
            pid
            for pid, _, group, stat in rows
            if not stat.startswith("Z") and group in groups
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
            for pid, _, group, stat in rows
            if not stat.startswith("Z") and group in groups
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
