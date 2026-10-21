#!/usr/bin/env python3
"""Stalled CI on this home's worker PRs: re-trigger once, then diagnose.

bin/fm-ci-stall.sh is the public entrypoint and bin/fm-watch.sh runs `scan`
detached every FM_CI_STALL_INTERVAL seconds. A scan looks at every worker of
this home (state/<id>.meta, kind ship or scout) whose recorded pr= is an open
GitHub pull request and reads the check runs on its head commit.

A check is stuck when it is
  queued       longer than FM_CI_STALL_QUEUED_SECS (1200) after it was created;
  in progress  longer than twice its usual duration, the median of the last
               completed successful runs of that check name in this repository
               that earlier scans recorded (state/ci-stall/durations.json), or
               FM_CI_STALL_RUNNING_SECS (3600) until three are known;
  cancelled    with zero steps or an annotation saying no runner was available
               (bin/fm-ci-infra.sh owns that classification).

The first time a PR head has a stuck check, the scan re-triggers it once: it
cancels a run still queued or in progress and reruns it on a later scan once
GitHub reports it completed, or reruns a cancelled one at once. If a check on
the same head is stuck again after that one re-run, the scan diagnoses it with
`bin/fm-ci-infra.sh classify` (billing, a spending limit or no runner) or, for a
run that keeps running, as a hung job, and hands it to the owning worker with
bin/fm-send.sh: the worker fixes it under its charter (a private repository's
workflow moves to the workload runner, an optional job is skipped by policy) or
reports one plain blocker. When the worker cannot be reached, the scan raises
that blocker itself: a second mate appends "blocked [key=ci-stall-<id>]" to its
parent channel, the first mate's own home queues one check: wake. Each PR head
is re-triggered at most once and handed off at most once.

Every stall, re-trigger, recovery, hand-off and blocker is appended to
state/ci-stall/events.jsonl ({"ts","id","pr","head","check","event","detail"}),
which fleet dreaming counts. Per-head progress is state/ci-stall/<id>.json.

FM_HOME is required. Tests set FM_CI_STALL_NOW (epoch), FM_CI_STALL_GH (the gh
executable), FM_CI_STALL_SEND (the fm-send executable) and FM_CI_STALL_INFRA
(the fm-ci-infra executable).
"""

from __future__ import annotations

import calendar
import json
import os
import re
import statistics
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
PR_RE = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)$")


def env_int(name: str, default: int) -> int:
    try:
        value = int(os.environ.get(name, ""))
        return value if value > 0 else default
    except ValueError:
        return default


QUEUED = env_int("FM_CI_STALL_QUEUED_SECS", 1200)
RUNNING = env_int("FM_CI_STALL_RUNNING_SECS", 3600)
NOW = env_int("FM_CI_STALL_NOW", int(time.time()))
GH = os.environ.get("FM_CI_STALL_GH") or "gh"
SEND = os.environ.get("FM_CI_STALL_SEND") or str(SCRIPT_DIR / "fm-send.sh")
INFRA = os.environ.get("FM_CI_STALL_INFRA") or str(SCRIPT_DIR / "fm-ci-infra.sh")


def home() -> Path:
    value = os.environ.get("FM_HOME")
    if not value:
        sys.exit("fm-ci-stall: FM_HOME is required")
    return Path(value)


def utc(stamp):
    """Seconds since the epoch for a GitHub UTC timestamp."""
    if not stamp:
        return None
    try:
        return int(calendar.timegm(time.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ")))
    except ValueError:
        return None


def gh_json(*args):
    r = subprocess.run([GH, "api", *args], capture_output=True, text=True, timeout=60)
    if r.returncode:
        raise RuntimeError(r.stderr.strip() or "gh api failed")
    return json.loads(r.stdout or "null")


def gh(*args) -> bool:
    return subprocess.run([GH, *args], capture_output=True, text=True, timeout=60).returncode == 0


def meta(path: Path) -> dict:
    out = {}
    for line in path.read_text(errors="replace").splitlines():
        key, sep, value = line.partition("=")
        if sep:
            out[key] = value
    return out


def run_id(check: dict):
    m = re.search(r"/actions/runs/(\d+)", check.get("details_url") or check.get("html_url") or "")
    return m.group(1) if m else None


def load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def save(path: Path, value) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True))
    os.replace(tmp, path)


class Scan:
    def __init__(self, h: Path):
        self.h = h
        self.state = h / "state"
        self.dir = self.state / "ci-stall"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.durations = load(self.dir / "durations.json", {})

    def event(self, wid, pr, head, check, kind, detail=""):
        with open(self.dir / "events.jsonl", "a") as fh:
            fh.write(json.dumps({"ts": NOW, "id": wid, "pr": pr, "head": head, "check": check,
                                 "event": kind, "detail": detail[:300]}) + "\n")

    def usual(self, repo: str, name: str):
        samples = self.durations.get(repo, {}).get(name, [])
        return statistics.median(samples) if len(samples) >= 3 else None

    def learn(self, repo: str, checks: list) -> None:
        for c in checks:
            if c.get("status") == "completed" and c.get("conclusion") == "success":
                start, end = utc(c.get("started_at")), utc(c.get("completed_at"))
                if start and end and end > start:
                    bucket = self.durations.setdefault(repo, {}).setdefault(c["name"], [])
                    if (end - start) not in bucket[-1:]:
                        bucket.append(end - start)
                        del bucket[:-10]

    def stuck(self, repo: str, c: dict):
        """A plain reason when this check is stuck, else None."""
        status, start = c.get("status"), utc(c.get("started_at"))
        if status == "queued" and start and NOW - start > QUEUED:
            return "queued %d minutes" % ((NOW - start) // 60)
        if status == "in_progress" and start:
            usual = self.usual(repo, c["name"])
            bound = 2 * usual if usual else RUNNING
            if NOW - start > bound:
                return "running %d minutes (usually %s)" % ((NOW - start) // 60,
                                                            "%d" % (usual // 60) + " minutes" if usual else "unknown")
        if status == "completed" and c.get("conclusion") == "cancelled" and c.get("_no_runner"):
            return "cancelled without a runner"
        return None

    def classify_infra(self, pr: str) -> str:
        r = subprocess.run([INFRA, "classify", pr], capture_output=True,
                           text=True, timeout=180)
        lines = [ln for ln in (r.stdout or "").splitlines() if ln.startswith(("infra ", "fix:"))]
        return "; ".join(lines)[:400]

    def raise_blocker(self, wid: str, text: str) -> None:
        lib = SCRIPT_DIR / "fm-parent-channel-lib.sh"
        rc = subprocess.run(
            ["bash", "-c", '. "$1"; fm_parent_channel_report "$2" "$3" "$4"', "fm-ci-stall", str(lib),
             str(self.h), str(self.state), "blocked [key=ci-stall-%s]: %s" % (wid, text)],
            capture_output=True, text=True, timeout=120).returncode
        if rc == 1:  # this is the first mate's own home
            subprocess.run(
                ["bash", "-c", '. "$1"; fm_wake_append check "$2" "$3"', "fm-ci-stall",
                 str(SCRIPT_DIR / "fm-wake-lib.sh"), "ci-stall:%s:%d" % (wid, NOW), "check: stalled CI: " + text],
                capture_output=True, text=True, timeout=60)

    def one(self, wid: str, pr: str) -> None:
        m = PR_RE.match(pr)
        if not m:
            return
        owner, repo, number = m.groups()
        full = "%s/%s" % (owner, repo)
        pull = gh_json("repos/%s/pulls/%s" % (full, number))
        if not isinstance(pull, dict) or pull.get("state") != "open":
            return
        head = pull["head"]["sha"]
        runs = gh_json("repos/%s/commits/%s/check-runs?per_page=100" % (full, head))
        checks = runs.get("check_runs", []) if isinstance(runs, dict) else []
        for c in checks:
            if c.get("status") == "completed" and c.get("conclusion") == "cancelled":
                job = c.get("id")
                try:
                    steps = gh_json("repos/%s/actions/jobs/%s" % (full, job)).get("steps") or []
                except (RuntimeError, ValueError, AttributeError):
                    steps = None
                c["_no_runner"] = steps == []
        self.learn(full, checks)
        rec_path = self.dir / ("%s.json" % wid)
        rec = load(rec_path, {})
        if rec.get("head") != head:
            rec = {"head": head, "pr": pr, "retriggered": [], "pending_rerun": [], "handed_off": False}
        # a run this scan cancelled is rerun once GitHub reports it completed
        waiting = set()
        for rid in list(rec["pending_rerun"]):
            waiting.add(rid)
            state = [c for c in checks if run_id(c) == rid]
            if state and all(c.get("status") == "completed" for c in state):
                if gh("run", "rerun", rid, "--repo", full):
                    self.event(wid, pr, head, state[0]["name"], "retriggered", "rerun after cancel")
                rec["pending_rerun"].remove(rid)
        # those runs' check rows still show the cancel this scan made, not a stall
        stuck = [(c, self.stuck(full, c)) for c in checks if run_id(c) not in waiting]
        stuck = [(c, why) for c, why in stuck if why]
        if not stuck:
            if rec["retriggered"] and not waiting and not rec.get("recovered"):
                rec["recovered"] = True
                self.event(wid, pr, head, "", "recovered", "checks moving again after the re-trigger")
            save(rec_path, rec)
            return
        for c, why in stuck:
            self.event(wid, pr, head, c["name"], "stalled", why)
        fresh = [(c, why) for c, why in stuck if run_id(c) and run_id(c) not in rec["retriggered"]]
        if fresh:
            for c, why in fresh:
                rid = run_id(c)
                rec["retriggered"].append(rid)
                if c.get("status") == "completed":
                    if gh("run", "rerun", rid, "--repo", full):
                        self.event(wid, pr, head, c["name"], "retriggered", why)
                elif gh("run", "cancel", rid, "--repo", full):
                    rec["pending_rerun"].append(rid)
                    self.event(wid, pr, head, c["name"], "cancelled-for-rerun", why)
            save(rec_path, rec)
            return
        if rec["handed_off"]:
            save(rec_path, rec)
            return
        names = ", ".join(sorted({c["name"] for c, _ in stuck}))
        whys = "; ".join(sorted({why for _, why in stuck}))
        infra = self.classify_infra(pr)
        diagnosis = infra or ("a job that keeps running past its usual time (a hung test or step)"
                              if any(c.get("status") == "in_progress" for c, _ in stuck)
                              else "checks that stay queued (no runner picks them up)")
        text = ("CI on %s is still stuck after one re-run: %s (%s). Diagnosis: %s. Fix it under your charter "
                "(move a private repository's workflow to the workload runner, skip an optional job per policy, "
                "or fix the hung step) and re-run, or report one plain blocker." % (pr, names, whys, diagnosis))
        sent = subprocess.run([SEND, wid, text], capture_output=True, text=True, timeout=120,
                              env=dict(os.environ, FM_HOME=str(self.h))).returncode == 0
        rec["handed_off"] = True
        if sent:
            self.event(wid, pr, head, names, "handed-off", diagnosis)
        else:
            self.raise_blocker(wid, "%s for worker %s: %s; %s" % (pr, wid, whys, diagnosis))
            self.event(wid, pr, head, names, "blocker", diagnosis)
        save(rec_path, rec)

    def scan(self) -> None:
        for path in sorted(self.state.glob("*.meta")):
            m = meta(path)
            if m.get("kind") not in ("ship", "scout") or not m.get("pr"):
                continue
            try:
                self.one(path.stem, m["pr"])
            except (RuntimeError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
                print("fm-ci-stall: %s: %s" % (path.stem, error), file=sys.stderr)
        save(self.dir / "durations.json", self.durations)


def counts(h: Path, since: int) -> dict:
    """Event counts since an epoch, for fleet dreaming."""
    out = {}
    try:
        with open(h / "state" / "ci-stall" / "events.jsonl") as fh:
            for line in fh:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if e.get("ts", 0) >= since:
                    out[e.get("event")] = out.get(e.get("event"), 0) + 1
    except OSError:
        pass
    return out


def main(argv) -> int:
    if argv[:1] == ["scan"]:
        Scan(home()).scan()
        return 0
    if argv[:1] == ["counts"]:
        since = int(argv[1]) if len(argv) > 1 else NOW - 86400
        print(json.dumps(counts(home(), since), sort_keys=True))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
