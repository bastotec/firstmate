#!/usr/bin/env python3
"""Storage/lease boundary for fm-preserved-result-lib.sh; not a cleanup CLI.

Treehouse v2.3 stores durable leases in treehouse-state.json and serializes all
pool mutations with flock(treehouse-state.lock). Convert only the exact claimed
original slot under that SAME flock; preserve every other entry and unknown key.
A lease is never returned here. Treehouse get/prune/bulk destroy skip leased
slots, including clean slots whose original commits happen to land later.
"""
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import uuid
from datetime import datetime, timezone


def require(condition, message):
    if not condition:
        raise ValueError(message)


def regular(path):
    require(path.is_file() and not path.is_symlink(), f"unsafe or missing file: {path}")
    return path.read_bytes()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def atomic(path, content):
    require(not path.is_symlink(), f"unsafe destination: {path}")
    fd, name = tempfile.mkstemp(prefix=path.name + ".", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        parent = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(parent)
        finally:
            os.close(parent)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def write_json(path, value):
    atomic(path, (json.dumps(value, indent=2, sort_keys=True) + "\n").encode())


def git(wt, *args):
    return subprocess.check_output(["git", "--no-optional-locks", "-C", str(wt), *args])


def main():
    phase, state_arg, data_arg, task, acceptance_arg, snapshot_arg = sys.argv[1:]
    state, data = Path(state_arg).resolve(), Path(data_arg).resolve()
    acceptance_bytes = regular(Path(acceptance_arg))
    a = json.loads(acceptance_bytes)
    fields = ("task", "spawn_gen", "meta_sha256", "head", "outcome", "accepted_by", "summary", "result", "result_sha256")
    require(isinstance(a, dict) and all(isinstance(a.get(k), str) and a[k].strip() for k in fields), "incomplete acceptance")
    require(a["task"] == task and a["outcome"] in ("diagnosis", "superseded"), "wrong task or non-knowledge outcome")
    require(subprocess.check_output(["treehouse", "--version"]).decode().strip() == "v2.3.0",
            "lease conversion requires verified Treehouse v2.3.0 schema; verify integration before upgrading")
    require(isinstance(a.get("allocation"), dict), "acceptance needs the original pool entry as allocation")
    raw = regular(Path(snapshot_arg))
    require(digest(raw) == a["meta_sha256"], "acceptance does not bind original metadata")
    meta = {}
    for line in raw.decode().splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            require(key not in meta, "ambiguous metadata")
            meta[key] = value
    require(meta.get("spawn_gen") == a["spawn_gen"], "wrong original incarnation")
    wt = Path(meta["worktree"]).resolve(strict=True)
    require(git(wt, "rev-parse", "--show-toplevel").decode().strip() == str(wt), "not an original worktree root")
    require(git(wt, "rev-parse", "HEAD").decode().strip() == a["head"], "original head changed")
    archive = data / task / "preserved-result"
    require(not (data / task).is_symlink() and not archive.is_symlink(), "unsafe archive directory")
    marker = state / (task + ".preserved-result")
    receipt = archive / "receipt.json"
    # Hold Treehouse's own lock across admission, receipt publication and lease
    # conversion, so stale evidence refuses before publishing immutable receipts.
    pool = wt.parent.parent
    pool_state, pool_lock = pool / "treehouse-state.json", pool / "treehouse-state.lock"
    require(not pool_lock.is_symlink(), "unsafe pool lock")
    with pool_lock.open("a+b") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        obj = json.loads(regular(pool_state))
        entries = obj.get("worktrees")
        require(isinstance(entries, list) and all(isinstance(e, dict) for e in entries), "invalid pool state")
        matches = [e for e in entries if e.get("path") == str(wt)]
        require(len(matches) == 1, "original slot is absent or ambiguous in pool state")
        entry = matches[0]
        require(entry.get("name") == wt.parent.name and not entry.get("destroying"), "wrong or retiring pool slot")
        require(git(wt, "rev-parse", "HEAD").decode().strip() == a["head"], "original head changed under pool lock")
        holder = "preserved-result:" + str(state.parent) + ":" + task + ":" + a["spawn_gen"]
        if not entry.get("leased"):
            require(phase == "prepare", "retention lease disappeared")
            require(entry == a["allocation"], "original allocation changed since acceptance")
        if receipt.exists():
            r = json.loads(regular(receipt))
            require(r["acceptance_sha256"] == digest(acceptance_bytes), "acceptance changed during retirement")
            require(regular(archive / "original.meta") == raw, "original metadata archive changed")
            require(digest(regular(archive / "result.md")) == a["result_sha256"], "saved result changed")
        else:
            require(phase == "prepare" and not entry.get("leased"), "missing preservation receipt or foreign lease")
            source = Path(a["result"])
            require(source.is_absolute(), "result must be an absolute path")
            result = regular(source)
            require(bool(result.strip()) and digest(result) == a["result_sha256"], "result bytes do not match acceptance")
            report = data / task / "report.md"
            if report.exists() or report.is_symlink():
                require(digest(regular(report)) == a["result_sha256"], "canonical report differs from accepted result; it cannot be overwritten")
            r = {"task": task, "spawn_gen": a["spawn_gen"], "worktree": str(wt),
                 "outcome": a["outcome"], "acceptance_sha256": digest(acceptance_bytes),
                 "lease_id": uuid.uuid4().hex, "phase": "prepared",
                 "head": a["head"], "refs": git(wt, "show-ref").decode(),
                 "commits": git(wt, "rev-list", "--all").decode(),
                 "status": git(wt, "status", "--porcelain=v1", "--untracked-files=all").decode()}
            archive.mkdir(parents=True, exist_ok=True)
            atomic(archive / "original.meta", raw)
            atomic(archive / "acceptance.json", acceptance_bytes)
            atomic(archive / "result.md", result)
            write_json(receipt, r)
        if entry.get("leased"):
            require(entry.get("lease_holder") == holder and entry.get("lease_id") == r["lease_id"], "foreign allocation lease")
        report = data / task / "report.md"
        if report.exists() or report.is_symlink():
            require(digest(regular(report)) == a["result_sha256"], "canonical report differs from accepted result; it cannot be overwritten")
        else:
            atomic(report, regular(archive / "result.md"))
        if marker.exists() or marker.is_symlink():
            require(regular(marker).decode() == str(receipt) + "\n", "foreign retention marker")
        else:
            atomic(marker, (str(receipt) + "\n").encode())
        # No endpoint can be stopped until its ORIGINAL slot is durably retained.
        if not entry.get("leased"):
            entry.update(leased=True, lease_holder=holder, lease_id=r["lease_id"],
                         leased_at=datetime.now(timezone.utc).isoformat(), owner_pid=0, owner_started_at=0)
            write_json(pool_state, obj)
    if phase == "stopped":
        r["phase"] = "endpoint-stopped"
        write_json(receipt, r)
    elif phase in ("verify-stopped", "complete"):
        require(r["phase"] in ("endpoint-stopped", "completed"), "endpoint stop was never confirmed")
        if phase == "complete":
            require(not (state / (task + ".meta")).exists(), "original live record still present")
            r["phase"] = "completed"
            write_json(receipt, r)
    else:
        require(phase == "prepare", "unsupported storage phase")
        # The lifecycle owner must distinguish a new stop from crash replay
        # without depending on the hub retaining its ephemeral endpoint table.
        print(r["phase"])


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, KeyError, subprocess.CalledProcessError) as error:
        print(f"error: preserving accepted result: {error}", file=sys.stderr)
        sys.exit(1)
