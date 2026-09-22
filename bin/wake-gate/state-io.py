#!/usr/bin/env python3
import errno
import os
import re
import secrets
import stat
import sys


class UnsafeStatePath(Exception):
    pass


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


def open_state_dir(path: str) -> int:
    root_fd = open_safe_directory(path)
    try:
        try:
            os.mkdir("wake-gate", 0o700, dir_fd=root_fd)
        except FileExistsError:
            pass
        return open_safe_directory("wake-gate", root_fd)
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
        chunks = []
        while True:
            chunk = os.read(fd, 65536)
            if not chunk:
                return b"".join(chunks)
            chunks.append(chunk)
    finally:
        os.close(fd)


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
    if len(sys.argv) != 4 or sys.argv[1] not in ("append", "read", "replace"):
        return 2
    operation, directory, name = sys.argv[1:]
    validate_name(name)
    dir_fd = open_state_dir(directory)
    try:
        if operation == "read":
            sys.stdout.buffer.write(read_record(dir_fd, name))
            return 0
        payload = sys.stdin.buffer.read()
        if operation == "append":
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
        print(f"fm-wake-gate state I/O refused: {error}", file=sys.stderr)
        raise SystemExit(1)
