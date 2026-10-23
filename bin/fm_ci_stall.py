#!/usr/bin/env python3
"""Stalled CI on this home's worker PRs: re-trigger once, then diagnose.

bin/fm-ci-stall.sh is the public entrypoint; bin/fm-watch.sh owns the detached
scan cadence and launch condition. A scan looks at every worker of this home
(state/<id>.meta, kind ship or scout) whose recorded pr= is an open GitHub pull
request. It reads every page of check runs on the head commit, considering only
checks whose app slug is github-actions. Before each cancel or rerun, it reads
the Actions run in that PR's repository and requires its head_sha to match the
watched head, so check URLs alone cannot authorize workflow mutations.
Overlapping scans of one home exit zero quietly under a non-blocking lock at
state/ci-stall/.lock.

A check is stuck when it is
  queued       longer than FM_CI_STALL_QUEUED_SECS (1200) after started_at;
  in progress  longer than twice its usual duration, the median of the last ten
               distinct successful check-run IDs for that name in the repository
               observed by scans (state/ci-stall/durations.json), or
               FM_CI_STALL_RUNNING_SECS (3600) until three samples are known;
  cancelled    with zero steps reported by the Actions job API.
Queued and in-progress checks without started_at are not timed.

Recovery is once per workflow run per PR head, not once per matrix check: the
scan cancels a run still queued or in progress and reruns it on a later scan
once its checks are completed, or reruns an already completed run at once.
A rejected cancel remains eligible next scan. Pending reruns stay excluded from
stall detection until rerun succeeds; after three failed attempts they are
diagnosed as rerun failures instead. Each confirmed transition is persisted
before the next fallible operation, and the scan's own cancellation is not a
no-runner stall. Changing either the worker's PR binding or its head resets
progress in state/ci-stall/<id>.json.

Still stuck after the re-run, the scan uses `bin/fm-ci-infra.sh classify` for a
PR-wide infrastructure diagnosis, which may reflect any failed job on the head,
or falls back to a hung job or unclaimed queue.
A classifier timeout yields an unavailable diagnosis rather than stopping the
hand-off. bin/fm-send.sh hands it to the owning worker, which fixes it under its
charter (a private repository's workflow moves to the workload runner, an
optional job is skipped by policy) or reports one plain blocker; the scan does
not edit workflows. When delivery fails or times out, the scan raises that
blocker itself: a second mate appends "blocked [key=ci-stall-<id>]" to its parent
channel, the first mate's own home queues one check: wake. At most one confirmed
hand-off or blocker is recorded per PR head: runs that exhaust their re-trigger
later on that head do not cause another. Failed delivery is retried next scan.
A scan re-triggers fresh runs and also handles exhausted runs in the same scan,
subject to that per-head limit, so fresh stalls cannot starve the hand-off.
Only exhausted runs supply the hand-off's check names, stall reasons and
hung-job or unclaimed-queue fallback diagnosis.

Events stalled, retriggered, cancelled-for-rerun, recovered, handed-off and
blocker append to state/ci-stall/events.jsonl with fields
{"ts","id","pr","head","check","event","detail"}. These are event counts, not
unique incidents: each scan emits stalled for each check still detected as stuck.
`counts [<since-epoch>]` prints JSON counts since that epoch (inclusive), defaulting
to the preceding 24 hours. bin/fm_dream.py owns their aggregation into dreaming.
Regression coverage: tests/fm-ci-stall.test.sh.

FM_HOME is required. Tests set FM_CI_STALL_NOW (epoch), FM_CI_STALL_GH (the gh
executable), FM_CI_STALL_SEND (the fm-send executable) and FM_CI_STALL_INFRA
(the fm-ci-infra executable).
"""

from __future__ import annotations

import calendar
import fcntl
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
    if (check.get("app") or {}).get("slug") != "github-actions":
        return None
    m = re.search(r"/actions/runs/(\d+)", check.get("details_url") or "")
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
        samples = self.durations.get(repo, {}).get(name, {})
        if not isinstance(samples, dict):
            return None
        return statistics.median(s["duration"] for s in samples.values()) if len(samples) >= 3 else None

    def learn(self, repo: str, checks: list) -> None:
        for c in checks:
            if c.get("status") == "completed" and c.get("conclusion") == "success" and c.get("id") is not None:
                start, end = utc(c.get("started_at")), utc(c.get("completed_at"))
                if start and end and end > start:
                    names = self.durations.setdefault(repo, {})
                    bucket = names.get(c["name"], {})
                    if not isinstance(bucket, dict):
                        bucket = {}
                    bucket[str(c["id"])] = {"duration": end - start, "completed_at": end}
                    names[c["name"]] = dict(sorted(bucket.items(), key=lambda s: (s[1]["completed_at"], int(s[0])))[-10:])

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
        try:
            r = subprocess.run([INFRA, "classify", pr], capture_output=True,
                               text=True, timeout=180)
        except subprocess.TimeoutExpired:
            return "diagnosis unavailable: infrastructure classifier timed out"
        lines = [ln for ln in (r.stdout or "").splitlines() if ln.startswith(("infra ", "fix:"))]
        return "; ".join(lines)[:400]

    def run_matches_head(self, full, head, rid):
        run = gh_json("repos/%s/actions/runs/%s" % (full, rid))
        return isinstance(run, dict) and run.get("head_sha") == head

    def rerun(self, wid, pr, head, full, rec_path, rec, rid, check, why):
        failures = rec.setdefault("rerun_failures", {})
        if failures.get(rid, 0) >= 3 or not self.run_matches_head(full, head, rid):
            return
        if rid not in rec["pending_rerun"]:
            rec["pending_rerun"].append(rid)
        try:
            rerun = gh("run", "rerun", rid, "--repo", full)
        except subprocess.TimeoutExpired:
            rerun = False
        if rerun:
            rec["pending_rerun"].remove(rid)
            if rid not in rec["retriggered"]:
                rec["retriggered"].append(rid)
            failures.pop(rid, None)
        else:
            failures[rid] = failures.get(rid, 0) + 1
        save(rec_path, rec)
        if rerun:
            self.event(wid, pr, head, check, "retriggered", why)

    def raise_blocker(self, wid: str, text: str) -> bool:
        lib = SCRIPT_DIR / "fm-parent-channel-lib.sh"
        rc = subprocess.run(
            ["bash", "-c", '. "$1"; fm_parent_channel_report "$2" "$3" "$4"', "fm-ci-stall", str(lib),
             str(self.h), str(self.state), "blocked [key=ci-stall-%s]: %s" % (wid, text)],
            capture_output=True, text=True, timeout=120).returncode
        if rc == 1:
            return subprocess.run(
                ["bash", "-c", '. "$1"; fm_wake_append check "$2" "$3"', "fm-ci-stall",
                 str(SCRIPT_DIR / "fm-wake-lib.sh"), "ci-stall:%s:%d" % (wid, NOW), "check: stalled CI: " + text],
                capture_output=True, text=True, timeout=60).returncode == 0
        return rc == 0

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
        pages = gh_json("repos/%s/commits/%s/check-runs?per_page=100" % (full, head),
                        "--paginate", "--slurp")
        checks = [c for page in pages for c in page.get("check_runs", [])
                  if (c.get("app") or {}).get("slug") == "github-actions"]
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
        if rec.get("head") != head or rec.get("pr") != pr:
            rec = {"head": head, "pr": pr, "retriggered": [], "pending_rerun": [], "handed_off": False}
            save(rec_path, rec)
        # a run this scan cancelled is rerun once GitHub reports it completed
        waiting = set()
        rerun_failed = []
        for rid in list(dict.fromkeys(rec["pending_rerun"])):
            waiting.add(rid)
            state = [c for c in checks if run_id(c) == rid]
            if state and all(c.get("status") == "completed" for c in state):
                self.rerun(wid, pr, head, full, rec_path, rec, rid, state[0]["name"], "rerun after cancel")
            if rec.get("rerun_failures", {}).get(rid, 0) >= 3:
                rerun_failed.append((state[0] if state else {"name": "run " + rid},
                                     "rerun failed after 3 attempts for run " + rid))
        # those runs' check rows still show the cancel this scan made, not a stall
        stuck = [(c, self.stuck(full, c)) for c in checks if run_id(c) not in waiting]
        stuck = [(c, why) for c, why in stuck if why] + rerun_failed
        if not stuck:
            if rec["retriggered"] and not waiting and not rec.get("recovered"):
                rec["recovered"] = True
                self.event(wid, pr, head, "", "recovered", "checks moving again after the re-trigger")
            save(rec_path, rec)
            return
        for c, why in stuck:
            self.event(wid, pr, head, c["name"], "stalled", why)
        fresh = {}
        for c, why in stuck:
            rid = run_id(c)
            if rid and rid not in rec["retriggered"] and rid not in rec["pending_rerun"]:
                fresh.setdefault(rid, (c, why))
        # runs that already had their one re-trigger are handed off in the same scan
        exhausted = [(c, why) for c, why in stuck if run_id(c) not in fresh]
        if fresh:
            for rid, (c, why) in fresh.items():
                state = [row for row in checks if run_id(row) == rid]
                if all(row.get("status") == "completed" for row in state):
                    self.rerun(wid, pr, head, full, rec_path, rec, rid, c["name"], why)
                elif self.run_matches_head(full, head, rid) and gh("run", "cancel", rid, "--repo", full):
                    rec["retriggered"].append(rid)
                    rec["pending_rerun"].append(rid)
                    save(rec_path, rec)
                    self.event(wid, pr, head, c["name"], "cancelled-for-rerun", why)
            save(rec_path, rec)
        if not exhausted or rec["handed_off"]:
            save(rec_path, rec)
            return
        names = ", ".join(sorted({c["name"] for c, _ in exhausted}))
        whys = "; ".join(sorted({why for _, why in exhausted}))
        infra = self.classify_infra(pr) if not rerun_failed else ""
        diagnosis = ("rerun failure: GitHub rejected 3 rerun attempts" if rerun_failed else infra) or (
            "a job that keeps running past its usual time (a hung test or step)"
            if any(c.get("status") == "in_progress" for c, _ in exhausted)
            else "checks that stay queued (no runner picks them up)")
        progress = "could not be re-run after 3 attempts" if rerun_failed else "is still stuck after one re-run"
        text = ("CI on %s %s: %s (%s). Diagnosis: %s. Fix it under your charter "
                "(move a private repository's workflow to the workload runner, skip an optional job per policy, "
                "or fix the hung step) and re-run, or report one plain blocker." % (pr, progress, names, whys, diagnosis))
        try:
            sent = subprocess.run([SEND, wid, text], capture_output=True, text=True, timeout=120,
                                  env=dict(os.environ, FM_HOME=str(self.h))).returncode == 0
        except subprocess.TimeoutExpired:
            sent = False
        if sent:
            rec["handed_off"] = True
            save(rec_path, rec)
            self.event(wid, pr, head, names, "handed-off", diagnosis)
        elif self.raise_blocker(wid, "%s for worker %s: %s; %s" % (pr, wid, whys, diagnosis)):
            rec["handed_off"] = True
            save(rec_path, rec)
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
        h = home()
        directory = h / "state" / "ci-stall"
        directory.mkdir(parents=True, exist_ok=True)
        with open(directory / ".lock", "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0
            Scan(h).scan()
        return 0
    if argv[:1] == ["counts"]:
        since = int(argv[1]) if len(argv) > 1 else NOW - 86400
        print(json.dumps(counts(home(), since), sort_keys=True))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
