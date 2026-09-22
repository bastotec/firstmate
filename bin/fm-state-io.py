#!/usr/bin/env python3
"""Descriptor-bound I/O for wake-gate records and root-level status files."""

import errno
import os
import re
import secrets
import stat
import sys


class UnsafeStatePath(Exception):
    pass


MAX_READ_BYTES = 256
MAX_STATUS_DELTA_BYTES = 65536
WORKER_STATUS_RE = re.compile(
    rb"^(?:done|needs-decision|blocked|failed|working)(?::|[ \t][^:\r\n]*:)"
)


def require_nofollow() -> int:
    value = getattr(os, "O_NOFOLLOW", 0)
    if not value:
        raise UnsafeStatePath("O_NOFOLLOW is unavailable")
    return value


def open_safe_directory(path: str, parent_fd=None) -> int:
    flags = os.O_RDONLY | require_nofollow()
    flags |= getattr(os, "O_DIRECTORY", 0)
    flags |= getattr(os, "O_CLOEXEC", 0)
    fd = os.open(path, flags, dir_fd=parent_fd)
    info = os.fstat(fd)
    if not stat.S_ISDIR(info.st_mode):
        os.close(fd)
        raise UnsafeStatePath("state path is not a directory")
    if info.st_uid not in (os.geteuid(), 0) or info.st_mode & 0o022:
        os.close(fd)
        raise UnsafeStatePath("state directory permissions are unsafe")
    return fd


def open_state_dir(path: str, create: bool = True):
    root_fd = open_safe_directory(path)
    try:
        if create:
            try:
                os.mkdir("wake-gate", 0o700, dir_fd=root_fd)
            except FileExistsError:
                pass
        try:
            return open_safe_directory("wake-gate", root_fd)
        except FileNotFoundError:
            if create:
                raise
            return None
    finally:
        os.close(root_fd)


def validate_name(name: str) -> None:
    if name in ("", ".", "..") or not re.fullmatch(r"[A-Za-z0-9._-]+", name):
        raise UnsafeStatePath("invalid state filename")


def require_regular_single_link(fd: int) -> None:
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise UnsafeStatePath("state target is not a single-linked regular file")


def write_all(fd: int, payload: bytes) -> None:
    view = memoryview(payload)
    while view:
        written = os.write(fd, view)
        if written <= 0:
            raise OSError("short state write")
        view = view[written:]


def append_record(dir_fd: int, name: str, payload: bytes) -> None:
    flags = os.O_WRONLY | os.O_APPEND | os.O_CREAT | os.O_NONBLOCK | require_nofollow()
    flags |= getattr(os, "O_CLOEXEC", 0)
    fd = os.open(name, flags, 0o600, dir_fd=dir_fd)
    try:
        require_regular_single_link(fd)
        if os.write(fd, payload) != len(payload):
            raise OSError("short state append")
        os.fsync(fd)
    finally:
        os.close(fd)


def read_record(dir_fd: int, name: str) -> bytes:
    flags = os.O_RDONLY | os.O_NONBLOCK | require_nofollow()
    flags |= getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(name, flags, dir_fd=dir_fd)
    except FileNotFoundError:
        return b""
    try:
        require_regular_single_link(fd)
        if os.fstat(fd).st_size > MAX_READ_BYTES:
            raise UnsafeStatePath("state record is too large")
        payload = bytearray()
        while len(payload) <= MAX_READ_BYTES:
            chunk = os.read(fd, MAX_READ_BYTES + 1 - len(payload))
            if not chunk:
                return bytes(payload)
            payload.extend(chunk)
        raise UnsafeStatePath("state record is too large")
    finally:
        os.close(fd)


def record_size(dir_fd: int, name: str) -> int:
    flags = os.O_RDONLY | os.O_NONBLOCK | require_nofollow()
    flags |= getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(name, flags, dir_fd=dir_fd)
    except FileNotFoundError:
        return 0
    try:
        require_regular_single_link(fd)
        return os.fstat(fd).st_size
    finally:
        os.close(fd)


def has_worker_status_after(dir_fd: int, name: str, offset: int) -> bool:
    flags = os.O_RDONLY | os.O_NONBLOCK | require_nofollow()
    flags |= getattr(os, "O_CLOEXEC", 0)
    try:
        fd = os.open(name, flags, dir_fd=dir_fd)
    except FileNotFoundError:
        return False
    try:
        require_regular_single_link(fd)
        size = os.fstat(fd).st_size
        if offset < 0 or offset > size:
            raise UnsafeStatePath("invalid status offset")
        delta_size = size - offset
        if delta_size > MAX_STATUS_DELTA_BYTES:
            return False
        os.lseek(fd, offset, os.SEEK_SET)
        payload = bytearray()
        while len(payload) < delta_size:
            chunk = os.read(fd, delta_size - len(payload))
            if not chunk:
                break
            payload.extend(chunk)
        return any(WORKER_STATUS_RE.match(line) for line in bytes(payload).split(b"\n")[:-1])
    finally:
        os.close(fd)


def touch_record(dir_fd: int, name: str) -> None:
    flags = os.O_RDONLY | os.O_CREAT | os.O_NONBLOCK | require_nofollow()
    flags |= getattr(os, "O_CLOEXEC", 0)
    fd = os.open(name, flags, 0o600, dir_fd=dir_fd)
    try:
        require_regular_single_link(fd)
        os.utime(fd, None)
        os.fsync(fd)
    finally:
        os.close(fd)


def remove_record(dir_fd: int, name: str) -> None:
    try:
        os.unlink(name, dir_fd=dir_fd)
    except FileNotFoundError:
        pass


def existing_target_is_safe(dir_fd: int, name: str) -> None:
    try:
        info = os.stat(name, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return
    if not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
        raise UnsafeStatePath("state target is not a single-linked regular file")


def replace_record(dir_fd: int, name: str, payload: bytes) -> None:
    existing_target_is_safe(dir_fd, name)
    temp_name = f".look.{os.getpid()}.{secrets.token_hex(8)}"
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | require_nofollow()
    flags |= getattr(os, "O_CLOEXEC", 0)
    fd = os.open(temp_name, flags, 0o600, dir_fd=dir_fd)
    try:
        write_all(fd, payload)
        os.fsync(fd)
    except BaseException:
        os.close(fd)
        try:
            os.unlink(temp_name, dir_fd=dir_fd)
        except OSError:
            pass
        raise
    else:
        os.close(fd)
    try:
        existing_target_is_safe(dir_fd, name)
        os.replace(temp_name, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
        try:
            os.fsync(dir_fd)
        except OSError as error:
            if error.errno not in (errno.EINVAL, errno.ENOTSUP):
                raise
    except BaseException:
        try:
            os.unlink(temp_name, dir_fd=dir_fd)
        except OSError:
            pass
        raise


def main() -> int:
    operations = (
        "append",
        "read",
        "replace",
        "remove",
        "root-append",
        "root-size",
        "root-touch",
        "root-worker-status-after",
    )
    if len(sys.argv) not in (4, 5) or sys.argv[1] not in operations:
        return 2
    operation, directory, name = sys.argv[1:4]
    if (operation == "root-worker-status-after") != (len(sys.argv) == 5):
        return 2
    validate_name(name)
    if operation.startswith("root-"):
        dir_fd = open_safe_directory(directory)
    else:
        dir_fd = open_state_dir(directory, create=operation != "remove")
        if dir_fd is None:
            return 0
    try:
        if operation == "read":
            sys.stdout.buffer.write(read_record(dir_fd, name))
        elif operation == "root-size":
            print(record_size(dir_fd, name))
        elif operation == "root-worker-status-after":
            try:
                offset = int(sys.argv[4])
            except ValueError:
                return 2
            return 0 if has_worker_status_after(dir_fd, name, offset) else 1
        elif operation == "root-touch":
            touch_record(dir_fd, name)
        elif operation == "remove":
            remove_record(dir_fd, name)
        else:
            payload = sys.stdin.buffer.read()
            if operation in ("append", "root-append"):
                append_record(dir_fd, name, payload)
            else:
                replace_record(dir_fd, name, payload)
        return 0
    finally:
        os.close(dir_fd)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, UnsafeStatePath) as error:
        print(f"fm-state-io refused: {error}", file=sys.stderr)
        raise SystemExit(1)
