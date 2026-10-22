#!/usr/bin/env python3
"""Worker keep-alive: a worker that stops making progress is acted on by its mate.

bin/fm-worker-keepalive.sh is the public entrypoint; bin/fm-watch.sh owns the
detached scan cadence and launch condition. In paths below, state/ denotes
FM_STATE_OVERRIDE when nonempty, otherwise FM_HOME/state; metadata, episode records,
the scan lock and wake queue all use that effective state directory.
A home only watches its own direct workers (state/<id>.meta with kind ship or
scout), so every mate, the first mate included, watches its own. Overlapping
scans of one home exit zero quietly under a non-blocking lock at
state/keepalive/.lock.

Each scan reads one condition per worker, first match wins:
  undelivered  a done: worker without a recorded pr= is still in the fleet
               FM_KEEPALIVE_DONE_SECS (2700) after its done line, past
               bin/fm-idle-sweep.sh's cleanup cadence: its result may never have
               reached whoever waits on it. A done: worker with a PR is left to
               the PR and CI watchers, regardless of agent liveness.
  dead         bin/fm-busy-lib.sh classifies the agent dead (no live agent);
  blocked      the last status line is blocked: or failed: - the mate must act;
  external     an active supervisor declaration from bin/fm-external-wait.sh
               suppresses held and no-progress detection until expiry, but
               never the done, dead or blocked cases above;
  held         the last status line is paused: or captain-held on something the
               mate itself can decide: it awaits a release, hold, approval,
               steer, decision or answer, names the mate ("your", "mate",
               "owner"), or holds a retry or housekeeping step (retry, relaunch,
               re-spawn, install, cleanup). A paused: line that names a UTC
               `until` time, or either pause verb naming none of those keywords,
               is left to bin/fm-watch.sh's declared-wait cadence;
  no-progress  any other live, unfinished worker whose real progress has not
               moved for FM_KEEPALIVE_NO_PROGRESS_SECS (1200). Real progress is
               the worktree's HEAD, the paths, mtimes and sizes of its changed
               files that are not reports (*.md, *.txt, *.log, report/ and notes/
               paths, .superpowers/, .scratch/, .no-mistakes/), the published
               validation run, step and verdict in state/<id>.crew-state,
               and the recorded pr=. Status lines and report edits never count.

A condition reaching its bound queues one `check: worker keep-alive:` wake
keyed keepalive:<id>:<condition>:<epoch> to this home's own supervisor.
Dead uses FM_KEEPALIVE_DEAD_SECS (300) from first observation; blocked and held
use FM_KEEPALIVE_STUCK_SECS (1200), and undelivered uses FM_KEEPALIVE_DONE_SECS,
initially measured from the status file's mtime when the condition is observed.
Later status edits do not restart an unchanged condition's clock. Its text is a
concrete instruction - decide and resume it, relaunch it with
`bin/fm-spawn.sh --relaunch <id>`, replace it, or close it - never "wait".
The mate acted when the highest steer sequence in the worker's inbox
(state/<id>.inbox/NNN.msg written by bin/fm-send.sh, counted in handled/ too, so
a steer the worker already acknowledged still counts; delivery bookkeeping
never does) is above the `steer` baseline saved at the wake, or its spawn_gen=
changes: a still-stuck worker then starts a fresh waiting period and is woken
again after another bound, retaining the episode's first epoch and nudge count.
A woken record without `steer` adopts the current sequence on its first eligible
scan; legacy mtime-valued `inbox` fields are not compared. Baseline adoption
alone leaves the wake time and escalation deadline unchanged.
When the mate did not act within FM_KEEPALIVE_ESCALATE_SECS (1800) of the wake, or the
worker is still stuck after FM_KEEPALIVE_MAX_NUDGES (3) wakes, the scan raises
one plain line naming what is stuck and what would unstick it: a second mate
appends "blocked [key=keepalive-<home>-<id>-<first-epoch>]: ..." to its parent channel
(bin/fm-parent-channel-lib.sh), the first mate's own home queues one check:
wake telling its supervisor to raise it with the captain. When the condition
clears or the worker leaves, an escalated episode is resolved the same way.
A condition change starts a new episode.

Progress lives in state/keepalive/<id>.json.
Regression coverage: tests/fm-worker-keepalive.test.sh.

FM_HOME is required. Tests set FM_KEEPALIVE_NOW (epoch) and FM_KEEPALIVE_LIVENESS
(an executable printing the busy classification for <id>).
"""

from __future__ import annotations

import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent


def env_int(name: str, default: int) -> int:
    try:
        value = int(os.environ.get(name, ""))
        return value if value > 0 else default
    except ValueError:
        return default


NO_PROGRESS = env_int("FM_KEEPALIVE_NO_PROGRESS_SECS", 1200)
STUCK = env_int("FM_KEEPALIVE_STUCK_SECS", 1200)
DEAD = env_int("FM_KEEPALIVE_DEAD_SECS", 300)
DONE = env_int("FM_KEEPALIVE_DONE_SECS", 2700)
ESCALATE = env_int("FM_KEEPALIVE_ESCALATE_SECS", 1800)
MAX_NUDGES = env_int("FM_KEEPALIVE_MAX_NUDGES", 3)
NOW = env_int("FM_KEEPALIVE_NOW", int(time.time()))
LIVENESS = os.environ.get("FM_KEEPALIVE_LIVENESS") or ""

STATUS_RE = re.compile(r"^\s*([a-z][a-z-]*)\s*(\[[^\]]*\])?\s*:?\s*(.*)$")
UNTIL_RE = re.compile(r"\buntil\s+\d{4}-\d{2}-\d{2}T\d{2}:\d{2}", re.I)
MATE_DECIDABLE_RE = re.compile(
    r"\b(your|you|mate|owner|release[ds]?|hold|held|approv\w*|go-ahead|permission|"
    r"steer\w*|decid\w*|decision|confirm\w*|answer|sign-off|instruction\w*|"
    r"retry\w*|relaunch\w*|re-?spawn\w*|re-?run|install\w*|clean-?up|housekeeping)\b",
    re.I)
REPORT_RE = re.compile(
    r"(\.(md|txt|log)$|(^|/)(\.superpowers|\.scratch|\.no-mistakes|reports?|notes?)/)", re.I)


def home() -> Path:
    value = os.environ.get("FM_HOME")
    if not value:
        sys.exit("fm-worker-keepalive: FM_HOME is required")
    return Path(value)


def meta(path: Path) -> dict:
    out = {}
    try:
        for line in path.read_text(errors="replace").splitlines():
            key, sep, value = line.partition("=")
            if sep:
                out[key] = value
    except OSError:
        pass
    return out


def load(path: Path, default):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return default


def save(path: Path, value) -> None:
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, sort_keys=True))
    os.replace(tmp, path)


def mtime(path: Path) -> int:
    try:
        return int(path.stat().st_mtime)
    except OSError:
        return 0


def steer_seq(path: Path) -> int:
    """Highest steer sequence delivered to an inbox, handled or not."""
    best = 0
    for folder in (path, path / "handled"):
        try:
            for child in folder.iterdir():
                if re.fullmatch(r"[0-9]+\.msg", child.name) and child.is_file():
                    best = max(best, int(child.name[:-4]))
        except OSError:
            pass
    return best


def last_status(path: Path):
    """(verb, text) of the status file's last non-empty line, or (None, "")."""
    try:
        lines = [ln for ln in path.read_text(errors="replace").splitlines() if ln.strip()]
    except OSError:
        return None, ""
    if not lines:
        return None, ""
    m = STATUS_RE.match(lines[-1])
    if not m:
        return None, lines[-1]
    return m.group(1), m.group(3)


def mate_decidable(verb: str, text: str) -> bool:
    """A paused:/captain-held line the mate can decide itself (see docstring)."""
    if verb == "paused" and UNTIL_RE.search(text):
        return False
    return bool(MATE_DECIDABLE_RE.search(text))


def git(wt: str, *args) -> str:
    try:
        r = subprocess.run(["git", "-C", wt, *args], capture_output=True, text=True, timeout=30)
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return r.stdout if r.returncode == 0 else ""


def fingerprint(state: Path, wid: str, m: dict) -> str:
    """Hash of the worker's real progress; reports and status lines excluded."""
    parts = []
    wt = m.get("worktree") or ""
    if wt and os.path.isdir(wt):
        parts.append(git(wt, "rev-parse", "HEAD").strip())
        changed = git(wt, "status", "--porcelain=v1", "-z", "--untracked-files=all").split("\0")
        for entry in sorted(e for e in changed if len(e) > 3)[:2000]:
            rel = entry[3:]
            if REPORT_RE.search(rel):
                continue
            st = os.path.join(wt, rel)
            try:
                s = os.stat(st)
                parts.append("%s %d %d" % (rel, int(s.st_mtime), s.st_size))
            except OSError:
                parts.append(rel + " gone")
    crew = meta(state / ("%s.crew-state" % wid))
    parts.append("run=%s step=%s verdict=%s" % (crew.get("run", ""), crew.get("step", ""), crew.get("verdict", "")))
    parts.append("pr=" + m.get("pr", ""))
    return hashlib.sha256("\n".join(parts).encode()).hexdigest()[:16]


def bash(script: str, *args, timeout=60) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", script, "fm-worker-keepalive", *args],
                          capture_output=True, text=True, timeout=timeout)


def liveness(h: Path, state: Path, wid: str) -> str:
    try:
        if LIVENESS:
            r = subprocess.run([LIVENESS, wid], capture_output=True, text=True, timeout=60,
                               env=dict(os.environ, FM_HOME=str(h)))
        else:
            r = bash('d=$1; . "$d/fm-wake-lib.sh"; . "$d/fm-backend.sh"; . "$d/fm-busy-lib.sh"; '
                     'm="$2/$3.meta"; fm_busy_classify_live "$(fm_backend_of_meta "$m")" '
                     '"$(fm_backend_target_of_meta "$m")" "$(fm_meta_get "$m" harness)" "$3" "$2" "fm-$3"',
                     str(SCRIPT_DIR), str(state), wid)
    except (OSError, subprocess.TimeoutExpired):
        return "unknown"
    return (r.stdout.strip().split() or ["unknown"])[0]


def minutes(secs: int) -> int:
    return max(0, secs) // 60


def instruction(wid: str, cond: str, age: int, verb: str, text: str) -> str:
    quote = (text[:160] + "...") if len(text) > 160 else text
    relaunch = "relaunch it (bin/fm-spawn.sh --relaunch %s), replace it, or close it" % wid
    if cond == "dead":
        return ("worker %s has had no live agent for %d minutes: %s now; never leave it waiting"
                % (wid, minutes(age), relaunch))
    if cond == "undelivered":
        return ("worker %s finished %d minutes ago (\"%s\") and is still in the fleet: make sure its result reached "
                "whoever waits on it - resend the report path with bin/fm-send.sh --result if a send was suppressed - "
                "then clean it up" % (wid, minutes(age), quote))
    if cond == "blocked":
        return ("worker %s has been %s for %d minutes (\"%s\"): unblock it in this turn - answer it and send it back "
                "to the deliverable, retry a transient failure, %s; raise a captain call only for a decision "
                "that is truly the captain's" % (wid, verb, minutes(age), quote, relaunch))
    if cond == "held":
        return ("worker %s has been %s for %d minutes on something you can decide (\"%s\"): decide it now - "
                "release it back to the deliverable with bin/fm-send.sh, %s; never wait for a release"
                % (wid, verb, minutes(age), quote, relaunch))
    return ("worker %s has made no real progress for %d minutes (no commits, code changes or validation-run "
            "movement; report and status edits do not count): check what it is doing and steer it back to the "
            "deliverable, %s" % (wid, minutes(age), relaunch))


def unstick(cond: str) -> str:
    return {"dead": "a relaunch or replacement of the worker",
            "blocked": "an answer to its blocker or a relaunch",
            "undelivered": "delivering its finished result and cleaning it up",
            "held": "releasing its hold so it resumes the deliverable",
            }.get(cond, "steering it back to the deliverable, or a relaunch")


class Scan:
    def __init__(self, h: Path, state: Path):
        self.h = h
        self.state = state
        self.dir = self.state / "keepalive"
        self.dir.mkdir(parents=True, exist_ok=True)

    def wake(self, key: str, text: str) -> bool:
        return bash('. "$1/fm-wake-lib.sh"; fm_wake_append check "$2" "$3"', str(SCRIPT_DIR), key,
                    "check: worker keep-alive: " + text).returncode == 0

    def report(self, wid: str, rec: dict, verb: str, text: str) -> bool:
        """Raise (blocked) or resolve one plain line beyond this home."""
        script = ('. "$1/fm-wake-lib.sh"; . "$1/fm-parent-channel-lib.sh"; hid=$(fm_parent_channel_home_id "$2" 2>/dev/null || printf home); '
                  'fm_parent_channel_report "$2" "$3" "$4 [key=keepalive-$hid-$5-$6]: $(fm_parent_channel_clean_note "$7")"')
        rc = bash(script, str(SCRIPT_DIR), str(self.h), str(self.state), verb, wid, str(rec["first"]), text, timeout=120).returncode
        if rc == 1:  # the first mate's own home: tell its supervisor
            if verb == "blocked":
                return self.wake("keepalive:%s:escalate:%d" % (wid, NOW),
                                 text + "; raise it with the captain in one plain line")
            return self.wake("keepalive:%s:resolved:%d" % (wid, NOW), text + "; clear its blocker")
        return rc == 0

    def resolve(self, wid: str, rec: dict, why: str) -> bool:
        if rec.get("escalated") and not self.report(wid, rec, "resolved", "worker %s %s" % (wid, why)):
            return False
        return True

    def condition(self, wid: str, m: dict, rec: dict):
        """(cond, since, verb, text) for this worker now; cond None when healthy."""
        status = self.state / ("%s.status" % wid)
        verb, text = last_status(status)
        if verb == "done":
            return ("done" if m.get("pr") else "undelivered"), min(NOW, mtime(status) or NOW), verb, text
        if liveness(self.h, self.state, wid) == "dead":
            return "dead", NOW, verb or "", text
        opened = min(NOW, mtime(status) or NOW)
        if verb in ("blocked", "failed"):
            return "blocked", opened, verb, text
        if bash('. "$1/fm-external-wait.sh"; keepalive_now=$4; fm_external_wait_now_epoch() { printf "%s\\n" "$keepalive_now"; }; '
                'fm_external_wait_active "$2" "$3"', str(SCRIPT_DIR), wid, str(self.state), str(NOW)).returncode == 0:
            return None, opened, verb or "working", text
        if verb in ("paused", "captain-held"):
            return ("held" if mate_decidable(verb, text) else None), opened, verb, text
        return "no-progress", rec.get("fp_since", NOW), verb or "working", text

    def one(self, wid: str, m: dict) -> None:
        rec_path = self.dir / ("%s.json" % wid)
        rec = load(rec_path, {})
        fp = fingerprint(self.state, wid, m)
        if rec.get("fp") != fp:
            rec["fp"], rec["fp_since"] = fp, NOW
        cond, since, verb, text = self.condition(wid, m, rec)
        if cond == "no-progress" and NOW - since < NO_PROGRESS:
            cond = None
        if cond in (None, "done"):
            if rec.get("cond") and not self.resolve(wid, rec, "is moving again"):
                save(rec_path, rec)
                return
            rec = {"fp": rec["fp"], "fp_since": rec["fp_since"]}
            save(rec_path, rec)
            return
        if rec.get("cond") != cond:
            if rec.get("cond") and not self.resolve(wid, rec, "is no longer %s" % rec["cond"]):
                save(rec_path, rec)
                return
            rec = {"fp": rec["fp"], "fp_since": rec["fp_since"], "cond": cond, "since": since,
                   "woke": 0, "nudges": 0, "escalated": False}
        bound = {"dead": DEAD, "no-progress": NO_PROGRESS, "undelivered": DONE}.get(cond, STUCK)
        age = NOW - rec["since"]
        inbox = steer_seq(self.state / ("%s.inbox" % wid))
        gen = m.get("spawn_gen", "")
        if rec.get("escalated") or age < bound:
            save(rec_path, rec)
            return
        if rec["woke"]:
            rec.setdefault("steer", inbox)
            acted = inbox > rec["steer"] or gen != rec.get("gen", "")
            if acted and rec["nudges"] < MAX_NUDGES:
                # the mate acted and the worker is still stuck: a fresh episode
                rec.update(since=NOW, woke=0, steer=inbox, gen=gen)
                save(rec_path, rec)
                return
            if acted or NOW - rec["woke"] >= ESCALATE:
                line = ("worker %s has been stuck (%s) for %d minutes and its mate %s; it needs %s"
                        % (wid, cond, minutes(NOW - rec["first"]),
                           "could not unstick it after %d tries" % rec["nudges"] if acted
                           else "did not act on the keep-alive wake", unstick(cond)))
                if self.report(wid, rec, "blocked", line):
                    rec["escalated"] = True
            save(rec_path, rec)
            return
        if self.wake("keepalive:%s:%s:%d" % (wid, cond, rec["since"]), instruction(wid, cond, age, verb, text)):
            rec.update(woke=NOW, steer=inbox, gen=gen, nudges=rec["nudges"] + 1)
            rec.setdefault("first", rec["since"])
        save(rec_path, rec)

    def scan(self) -> None:
        live = set()
        for path in sorted(self.state.glob("*.meta")):
            m = meta(path)
            if m.get("kind") not in ("ship", "scout"):
                continue
            live.add(path.stem)
            try:
                self.one(path.stem, m)
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
                print("fm-worker-keepalive: %s: %s" % (path.stem, error), file=sys.stderr)
        for rec_path in sorted(self.dir.glob("*.json")):
            wid = rec_path.stem
            if wid in live:
                continue
            rec = load(rec_path, {})
            if self.resolve(wid, rec, "left the fleet"):
                rec_path.unlink(missing_ok=True)


def main(argv) -> int:
    if argv[:1] == ["scan"]:
        h = home()
        state = Path(os.environ.get("FM_STATE_OVERRIDE") or h / "state")
        if not state.is_dir():
            return 0
        os.environ["FM_STATE_OVERRIDE"] = str(state)
        directory = state / "keepalive"
        directory.mkdir(parents=True, exist_ok=True)
        with open(directory / ".lock", "a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return 0
            Scan(h, state).scan()
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
