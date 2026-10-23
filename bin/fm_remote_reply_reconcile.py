#!/usr/bin/env python3
"""Prove a stale captured delta's ancestry without mutation.

Called under the adapter's lifecycle and ingest locks. Only canonical captured
results with remote-reply sidecars participate. Receipt-backed successors must
connect the pending end identity (or a byte-proven covering capture) to the
current cursor. Mirror text alone is never evidence of ingestion.
"""

import hashlib
import pathlib
import re
import sys


def digest(data):
    return hashlib.sha256(data).hexdigest()


def regular(path):
    if path.is_symlink() or not path.is_file():
        raise ValueError("unsafe or missing evidence")
    return path.read_bytes()


def delta(path):
    raw = regular(path)
    header, payload = raw.split(b"\n\n", 1)
    fields = {}
    for line in header.decode("ascii").splitlines():
        key, value = line.split("=", 1)
        if key in fields:
            raise ValueError("ambiguous header")
        fields[key] = value
    if (fields["schema"] != "fm-remote-delta.v1"
            or fields["status"] != "delta"
            or fields["path"] != "state/parent-replies.status"):
        raise ValueError("not a reply delta")
    for key in ("from_offset", "to_offset", "payload_bytes"):
        if not re.fullmatch(r"[0-9]+", fields[key]):
            raise ValueError("invalid offset")
        fields[key] = int(fields[key])
    for key in ("from_prefix_sha256", "to_prefix_sha256", "payload_sha256"):
        if not re.fullmatch(r"[0-9a-f]{64}", fields[key]):
            raise ValueError("invalid digest")
    if (not payload or not payload.endswith(b"\n")
            or len(payload) != fields["payload_bytes"]
            or fields["to_offset"] - fields["from_offset"] != len(payload)
            or digest(payload) != fields["payload_sha256"]):
        raise ValueError("invalid payload")
    if fields["from_offset"] == 0 and (
            fields["from_prefix_sha256"] != digest(b"")
            or fields["to_prefix_sha256"] != digest(payload)):
        raise ValueError("invalid whole-prefix digest")
    return fields, payload, raw


def point(fields, end=False):
    prefix = "to" if end else "from"
    return fields[prefix + "_offset"], fields[prefix + "_prefix_sha256"]


def successors(reachable, accepted):
    while True:
        expanded = reachable | {point(fields, True) for fields, _ in accepted
                                if point(fields) in reachable}
        if expanded == reachable:
            return reachable
        reachable = expanded


def covering_points(old, payload, receipts, accepted):
    candidates = [(fields, data) for fields, data in accepted
                  if fields["from_offset"] <= old["from_offset"]
                  and fields["to_offset"] >= old["to_offset"]]
    if not candidates:
        return set()
    needed = {point(fields) for fields, _ in candidates}
    ordered = sorted(receipts, key=lambda receipt: receipt[1]["to_offset"])
    for _, fields, _ in reversed(ordered):
        if point(fields, True) in needed:
            needed.add(point(fields))
    prefixes = {(0, digest(b"")): hashlib.sha256()}
    for _, fields, data in ordered:
        if point(fields, True) not in needed:
            continue
        prefix = prefixes.get(point(fields))
        if prefix is not None:
            full = prefix.copy()
            full.update(data)
            if full.hexdigest() == fields["to_prefix_sha256"]:
                prefixes[point(fields, True)] = full
    covered = set()
    for fields, data in candidates:
        prefix = prefixes.get(point(fields))
        start = old["from_offset"] - fields["from_offset"]
        end = old["to_offset"] - fields["from_offset"]
        if prefix is None or data[start:end] != payload:
            continue
        full = prefix.copy()
        full.update(data)
        before = prefix.copy()
        before.update(data[:start])
        through = before.copy()
        through.update(payload)
        if (full.hexdigest() == fields["to_prefix_sha256"]
                and before.hexdigest() == old["from_prefix_sha256"]
                and through.hexdigest() == old["to_prefix_sha256"]):
            covered.add(point(fields, True))
    return covered


def prove(state, mate, sequence, result, offset, prefix_hash):
    inbox = state / "procevent-inbox"
    canonical = inbox / f"remote-reply-{mate}.{sequence}.result"
    # An arbitrary caller-supplied file cannot borrow a capture's identity.
    if result.absolute() != canonical.absolute():
        return False
    if regular(canonical.with_suffix(".adapter")) != b"remote-reply\n":
        return False
    old, payload, _ = delta(canonical)
    receipts = []
    for path in inbox.glob(f"remote-reply-{mate}.*.result"):
        match = re.fullmatch(r"remote-reply-" + re.escape(mate) + r"\.([0-9]+)\.result", path.name)
        if not match:
            continue
        try:
            fields, data, raw = delta(path)
            if regular(path.with_suffix(".adapter")) != b"remote-reply\n":
                continue
            receipt = state / "remote-replies" / f"{mate}.{match[1]}.ingested"
            if regular(receipt) != f"result_sha256={digest(raw)}\n".encode():
                continue
            receipts.append((int(match[1]), fields, data))
        except (OSError, ValueError, KeyError, UnicodeError):
            continue
    accepted = [(fields, data) for seq, fields, data in receipts
                if seq > int(sequence)]
    # The captured delta itself commits its bytes and boundary identities, just
    # as on normal ingest. A receipt-backed successor anchored at its exact end
    # proves this generation belongs before current progress, not to a rewrite.
    # Ingest still applies every pending line; a successor receipt alone is NOT
    # a receipt for the pending generation.
    target = (int(offset), prefix_hash)
    reachable = successors({point(old, True)}, accepted)
    if target in reachable:
        return True
    reachable.update(covering_points(old, payload, receipts, accepted))
    return target in successors(reachable, accepted)


if __name__ == "__main__":
    try:
        ok = prove(pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3],
                   pathlib.Path(sys.argv[4]), sys.argv[5], sys.argv[6])
    except (OSError, ValueError, KeyError, UnicodeError):
        ok = False
    sys.exit(0 if ok else 1)
