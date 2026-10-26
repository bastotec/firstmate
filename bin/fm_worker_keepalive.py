#!/usr/bin/env python3
"""Keep-alive: mates act on stuck workers and parents answer mate questions.

bin/fm-worker-keepalive.sh is the public entrypoint; bin/fm-watch.sh owns the
detached scan cadence and launch condition. In paths below, state/ denotes
FM_STATE_OVERRIDE when nonempty, otherwise FM_HOME/state; metadata, episode records,
the scan lock and wake queue all use that effective state directory.
A home watches only its own direct workers (state/<id>.meta with kind ship or
scout) and second mates (kind secondmate), so every mate, the first mate included,
watches its own. Overlapping scans of one home exit zero quietly under a
non-blocking lock at state/keepalive/.lock.

Each scan reads one condition per worker, first match wins:
  approval     an approval exclusion record in force for
               FM_KEEPALIVE_APPROVAL_SECS (3600) from its declaration (the
               record object's mtime), regardless of the worker's last status
               or decision key, even if the record is unreadable. While fresh,
               only an exact nonempty decision key on a blocked:, failed:,
               needs-decision: or paused: line takes precedence, parsed by
               bin/fm-classify-lib.sh. This condition retains PR clocks without
               PR observation. The mate is woken at the bound to release the
               wait, fix what it waits on, retire the worker, or put a truly
               captain-owned decision to him in one line; the usual escalation
               follows. No wake releases the automatic-action exclusion:
               bin/fm-approval-wait.sh owns its binding and explicit release.
  undelivered  the worker's backlog item is done (accepted, read once per
               scan through bin/fm-tasks-axi.sh list --state done), or its last
               status line is done: with no recorded pr=, and the worker is
               still in the fleet FM_KEEPALIVE_DONE_SECS (600) later. Backlog
               acceptance takes precedence over agent liveness and recorded
               PRs: deliver and retire an accepted worker, never relaunch it.
               The wake tells the mate to send the result with
               `bin/fm-send.sh <conversation> --result` and then retire the
               worker. It names each conversation recorded in this home's
               state/captain-direct/ task_id fields and its last result-sent
               time in state/captain-direct.log (or "never" if none is recorded).
               This trail is evidence for the mate, not a requester lookup or
               a delivery gate: the scan cannot identify the requester or
               prove delivery, and does not suppress wakes after result-sent.
               A done: worker with a PR not found in the backlog's done set is
               eligible for the PR conditions below; otherwise its done: status
               suppresses the remaining conditions regardless of agent liveness,
               except frozen below.
  frozen       the last status line is done: in a freeze, hold or preserved
               state (freeze, frozen, preserved, read-only, ready-only,
               do-not-merge, DNM, custody, hold, held, parked, "no merge",
               "no edits") while its recorded pr= is still open, read live, for
               FM_KEEPALIVE_DONE_SECS from the status file's mtime; no approval
               wait may be in force. A freeze is never an endpoint: the mate
               lands the PR (removing a hold label it or the worker set) or
               closes it with a reason, then retires the worker. A hold label
               alone on a done: worker with plain wording stays ready-only, as
               below. A merged or closed PR clears it; an unreadable PR retains it;
  unmerged     the worker's recorded pr= is open, not a draft, MERGEABLE, with
               at least one check and every verdict returned by latest_checks
               below SUCCESS, NEUTRAL or SKIPPED (behind or review-required is
               left to bin/fm-pr-merge.sh) for
               FM_KEEPALIVE_PR_GREEN_SECS (1800) since first observed eligible.
               The mate merges it (bin/fm-pr-merge.sh), subject to merge policy,
               or closes it if superseded. Read live through `gh pr view`
               (FM_KEEPALIVE_PR stands in for it in tests);
               Explicit PR-action exclusions: an approval wait in force on the
               task (state/<id>.approval-wait; bin/fm-approval-wait.sh's admission
               predicate is the authority) excludes unmerged and ci-stuck for
               as long as any record object exists, even corrupt or a broken
               symlink. A hold label on the PR (bin/fm-pr-lib.sh's fm_pr_hold_label
               owns the label set) also excludes both demands as an explicit
               ready-only instruction, leaving held-PR reporting to auto-land.
               On scans reaching PR observation, these exclusions do not restart
               either clock: removing the exclusion restores ordinary demands
               subject to the clock maintenance below;
  ci-stuck     scans have observed the worker's validation run in its CI step
               (state/<id>.crew-state step=ci) for FM_KEEPALIVE_CI_STEP_SECS
               (7200), with its PR still open and not meeting the PR-state and
               check criteria above: rerun failed or cancelled checks, recover
               conflicts, then merge once green, or close it if superseded.
               Both PR clocks and any unmerged/ci-stuck episode reset when
               the recorded pr= changes or the saved track has no PR binding.
               A merged or closed PR observation clears both clocks.
               An unreadable PR does not resolve, wake or escalate an existing
               PR episode; its clocks are retained, except that the CI clock
               still resets when a scan observes a step other than ci.
               The green clock also resets on observed ineligibility;
  dead         bin/fm-busy-lib.sh classifies the agent dead (no live agent);
  blocked      the last status line is blocked: or failed: - the mate must act;
  external     an active supervisor declaration from bin/fm-external-wait.sh
               suppresses held and no-progress detection until expiry, but
               never the higher-priority conditions above;
  held         the last status line is paused: or captain-held on something the
               mate itself can decide: it awaits a release, hold, approval,
               steer, decision or answer, names the mate ("your", "mate",
               "owner"), or holds a retry or housekeeping step (retry, relaunch,
               re-spawn, install, cleanup), or mentions custody, evidence,
               authority, waiver or a supported path. A paused: line that names a UTC
               `until` time, or either pause verb naming none of those keywords,
               is left to bin/fm-watch.sh's declared-wait cadence;
  no-progress  any other live, unfinished worker whose real progress has not
               moved for FM_KEEPALIVE_NO_PROGRESS_SECS (1200). A live worker
               without a blocked or failed status is exempt while its CI or
               green clock above is retained, including during failed PR reads.
               Real progress is
               the worktree's HEAD, the paths, mtimes and sizes of its changed
               files that are not reports (*.md, *.txt, *.log, report/ and notes/
               paths, .superpowers/, .scratch/, .no-mistakes/), the published
               validation run, step and verdict in state/<id>.crew-state,
               and the recorded pr=. Status lines and report edits never count.

A condition reaching its bound queues one `check: worker keep-alive:` wake
keyed keepalive:<id>:<condition>:<epoch> to this home's own supervisor
(with an approval identity suffix as described below).
Dead uses FM_KEEPALIVE_DEAD_SECS (300) from first observation; frozen uses
FM_KEEPALIVE_DONE_SECS from the status file's mtime; blocked and held
use FM_KEEPALIVE_STUCK_SECS (1200), initially measured from the status file's
mtime when the condition is observed. Undelivered uses FM_KEEPALIVE_DONE_SECS
from first observation of backlog acceptance, or the status file's mtime for
an unaccepted done: worker without a PR.
Later status edits and transitions between blocked, held and no-progress
retain the episode's clock, wake, escalation state and parent key; a change to
dead, undelivered, frozen, unmerged, ci-stuck or approval resolves the old escalation
and starts a new episode. Approval episodes also reset when the record's
nanosecond mtime or decision key changes, including release and redeclaration
between scans. Approval wake and parent-channel keys append -<approval_id>
to their epoch so replacements have distinct identities.
The wake's text is a concrete instruction - decide and resume it, relaunch it with
`bin/fm-spawn.sh --relaunch <id>`, replace it, or close it - never "wait".
A steer, an acknowledgment or a relay upward is not a fix, so the inbox is not
read. A worker still stuck FM_KEEPALIVE_FOLLOW_SECS (600) after
the wake escalates one plain line to the mate's parent, telling it to act:
a second mate appends "blocked [key=keepalive-<home>-<id>-<first-epoch>]: ..."
to its parent channel (bin/fm-parent-channel-lib.sh). The first mate has no
parent mate, so its own home waits FM_KEEPALIVE_ESCALATE_SECS (1800) after the
wake and then tells the captain (see Captain lines). A stall clears when the
worker resumes with real progress, reports done: with a PR, or enters an
external or non-mate-decidable wait, unless a higher-priority condition applies.
An escalated episode's resolution is published through the same route when it
clears or the worker leaves. A line the parent channel cannot take (unusable
home marker, missing parent binding, unwritable channel) is never dropped: it
falls through to a captain line from this home (see Captain lines). The episode
retains that captain route for its resolution even if the parent channel is
repaired before the work recovers.

Escalations from below: every still-open keepalive- blocked record on a second
mate's channel is this home's to act on. One still open FM_KEEPALIVE_ESCALATE_SECS
after this home first saw it goes one level up: a second mate's home appends its
own blocked line to its parent channel, and the first mate's home tells the
captain. The channel key and fold origin identify the episode: note refreshes
retain its first-seen time and escalation state; closure followed by reopening
starts fresh. It resolves when the record closes or the mate leaves.
A record closed before it went up by anything but the owning watchdog's own
resolution (an "answered" line, the mate resolving its own alarm) is a dropped
escalation, not a fix: this home sends it one level up at once, noting the
closing line, and keeps it until the owning watchdog resolves that key, the key
reopens as a fresh episode, or the mate leaves. A captain-held closure transfers
ownership to the captain: an unraised relay or a dropped record is cleared
quietly, without an escalation or a "moving again" notice. Each asks record
retains the channel's byte offset and inode captured before the fold, and reads
its tail only through that endpoint, so appends during a scan remain for the next
scan. Openings absent from the fold with no tail closure stay pending until the
whole-file closing lookup finds a closure or the normal relay path owns them.
Blocked keepalive keys opened and dismissed entirely between scans also
go up at once; both verb-bracket and note-head keys use the decision fold's
parsers. The first scan (or a legacy record without an offset) starts at the
current end, without backfill.
After truncation or inode replacement, the new file is read from zero, but only
keys never seen by this watcher can seed missed closed episodes.

Auto-land: a home with config/autoland.json but no state/autoland.check.sh
has no armed auto-land check. FM_KEEPALIVE_DEAD_SECS after a scan first sees
that, it wakes this home's supervisor to re-arm it (bin/fm-autoland.sh arm)
and escalates like a stuck worker when it stays disarmed; record
state/keepalive/autoland.json. The wake preserves the captain's authority to
keep auto-land off.
Arming the check or removing the configuration clears this condition.
Regression coverage for these watchdogs: tests/fm-worker-keepalive.test.sh.

Captain lines: the first mate's home publishes one plain notice through
bin/fm-notify.sh (FM_KEEPALIVE_NOTIFY stands in for it in tests) and queues a
check: wake telling its supervisor the captain was told and to keep fixing it;
the resolution is one more notice. Failed publication or wake delivery is
retried; notice text uses episode timestamps rather than the scan's elapsed
minutes so fm-notify can suppress duplicate retries of an unchanged escalation.
Still-open legacy worker and question escalations without captain_notified are
reported through this path on the next scan and marked after successful delivery.

Parent-bound questions: the home also reads each second mate's channel
(state/<id>.status of a kind=secondmate meta, where a remote mate's lines are
ingested) through bin/fm-classify-lib.sh's open-decision fold. Every still-open
needs-decision: or blocked: record there is a question to this home, except the
machine escalations other owners close (keys starting keepalive-,
pending-reply-, parked-run-, ci-stall-, child-outcome-). One unanswered for
FM_KEEPALIVE_ASK_SECS (600) from first observation queues one check: wake per
mate, keyed keepalive:<mate>:asks:<epoch>, listing up to five due questions and
the total due count. It tells this home's supervisor to answer from what it
already knows (the captain's own earlier words beat a relay; housekeeping is its
own call) with `bin/fm-send.sh <mate> --resolve-key <key>`, or to ask the captain in
one plain line, never to leave the mate waiting. A question on a new key gets
its own clock and wake. Identical or reworded reposts of a still-open key retain
its first observation, wake and escalation state. Only a fold closure followed
by reopening starts a fresh episode, even when both happen between scans.
Questions still open FM_KEEPALIVE_ESCALATE_SECS after their wake are raised as
one line per mate (blocked [key=keepalive-<home>-<mate>-ask-<epoch>] from a
second mate's home, a captain line from the first mate's). The line describes the entire escalated-and-still-open set (count and
oldest question); changes to that set or its note text refresh it (under the same
report key on the parent channel). It resolves only when that set empties or
the mate leaves, retaining any captain fallback route on the aggregate episode
through resolution, even after the parent channel is repaired.
A question closes when the fold drops it (an answer sent with --resolve-key,
the mate's own resolved line, or a captain-held transfer). Records live in
state/keepalive/asks/<mate>.json alongside relayed escalation episodes. The record
also caches the fold until the channel's inode, size or mtime changes; legacy
caches without the relays field are recomputed before reuse.

Progress lives in state/keepalive/<id>.json.
Regression coverage: tests/fm-worker-keepalive.test.sh.

FM_HOME is required. Tests set FM_KEEPALIVE_NOW (epoch), FM_KEEPALIVE_LIVENESS
(an executable printing the busy classification for <id>), FM_KEEPALIVE_TASKS
(an executable standing in for bin/fm-tasks-axi.sh) and FM_KEEPALIVE_NOTIFY
(an executable standing in for bin/fm-notify.sh).
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
STALL_CONDITIONS = ("blocked", "held", "no-progress")
DEAD = env_int("FM_KEEPALIVE_DEAD_SECS", 300)
DONE = env_int("FM_KEEPALIVE_DONE_SECS", 600)
ASK = env_int("FM_KEEPALIVE_ASK_SECS", 600)
MACHINE_KEYS = ("keepalive-", "pending-reply-", "parked-run-", "ci-stall-", "child-outcome-")
ESCALATE = env_int("FM_KEEPALIVE_ESCALATE_SECS", 1800)
FOLLOW = env_int("FM_KEEPALIVE_FOLLOW_SECS", 600)
APPROVAL = env_int("FM_KEEPALIVE_APPROVAL_SECS", 3600)
PR_GREEN = env_int("FM_KEEPALIVE_PR_GREEN_SECS", 1800)
CI_STEP = env_int("FM_KEEPALIVE_CI_STEP_SECS", 7200)
NOW = env_int("FM_KEEPALIVE_NOW", int(time.time()))
LIVENESS = os.environ.get("FM_KEEPALIVE_LIVENESS") or ""

STATUS_RE = re.compile(r"^\s*([a-z][a-z-]*)\s*(\[[^\]]*\])?\s*:?\s*(.*)$")
UNTIL_RE = re.compile(r"\buntil\s+\d{4}-\d{2}-\d{2}T\d{2}:\d{2}", re.I)
MATE_DECIDABLE_RE = re.compile(
    r"\b(your|you|mate|owner|release[ds]?|hold|held|approv\w*|go-ahead|permission|"
    r"steer\w*|decid\w*|decision|confirm\w*|answer|sign-off|instruction\w*|"
    r"retry\w*|relaunch\w*|re-?spawn\w*|re-?run|install\w*|clean-?up|housekeeping|"
    r"custody|evidence|authori\w*|waiv\w*|supported)\b",
    re.I)
FROZEN_RE = re.compile(
    r"\b(freez\w*|frozen|preserv\w*|read-only|ready-only|do-not-merge|dnm|custody|hold|held|parked|"
    r"no (edits|merge))\b", re.I)
# The owning watchdog's own resolution notes (Scan.resolve, asks, relays, autoland).
WATCHDOG_RESOLVED_RE = re.compile(
    r"^(worker \S+ (is moving again|left the fleet|is no longer [a-z-]+|moved to another PR)"
    r"|second mate \S+('s questions are answered|'s stuck work is moving again| left the fleet)"
    r"|auto-land is armed again)")
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


def last_line(path: Path) -> str:
    """The status file's last non-empty line verbatim, or ""."""
    try:
        lines = [ln for ln in path.read_text(errors="replace").splitlines() if ln.strip()]
    except OSError:
        return ""
    return lines[-1] if lines else ""


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


def bash(script: str, *args, timeout=60, input=None) -> subprocess.CompletedProcess:
    return subprocess.run(["bash", "-c", script, "fm-worker-keepalive", *args],
                          capture_output=True, text=True, timeout=timeout, input=input)


def keyed_status_lines(text: str):
    if not text:
        return []
    r = bash('. "$1/fm-classify-lib.sh"; while IFS= read -r line; do '
             '_fm_decision_key_into "$line" || continue; '
             '_fm_status_line_verb_into "$line"; _fm_status_line_note_into "$line"; '
             'printf "%s\\t%s\\t%s\\n" "$_FM_KEY" "$_FM_VERB" "$_FM_NOTE"; done',
             str(SCRIPT_DIR), input=text + "\n")
    return [line.split("\t", 2) for line in r.stdout.splitlines() if line.count("\t") >= 2]


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


def backlog_done_ids(h: Path) -> set:
    """Task ids this home's backlog records as done (one tasks-axi read per scan)."""
    try:
        r = subprocess.run([os.environ.get("FM_KEEPALIVE_TASKS") or str(SCRIPT_DIR / "fm-tasks-axi.sh"),
                            "list", "--state", "done", "--limit", "1000"],
                           capture_output=True, text=True, timeout=60, env=dict(os.environ, FM_HOME=str(h)))
    except (OSError, subprocess.TimeoutExpired):
        return set()
    if r.returncode != 0:
        return set()
    return set(re.findall(r"(?m)^\s+([A-Za-z0-9._-]+),done,", r.stdout))


def result_trail(state: Path) -> str:
    """Where the captain is waiting: each captain-direct conversation and its last result sent."""
    targets = {}
    try:
        for entry in (state / "captain-direct").iterdir():
            if entry.is_file() and "." not in entry.name:
                t = meta(entry).get("task_id")
                if t:
                    targets.setdefault(t, "")
    except OSError:
        pass
    if not targets:
        return ""
    try:
        for line in (state / "captain-direct.log").read_text(errors="replace").splitlines():
            m = re.match(r"^(\S+) result-sent .*\btask=(\S+)", line)
            if m and m.group(2) in targets:
                targets[m.group(2)] = m.group(1)
    except OSError:
        pass
    return " (the captain wrote through this home to %s)" % ", ".join(
        "%s, last result sent %s" % (t, when or "never") for t, when in sorted(targets.items()))


def pr_view(url: str):
    """Live PR state, draft flag, mergeability, labels and checks from gh, or None."""
    cmd = [os.environ["FM_KEEPALIVE_PR"], url] if os.environ.get("FM_KEEPALIVE_PR") else [
        "gh", "pr", "view", url, "--json", "state,isDraft,mergeable,labels,statusCheckRollup"]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
        return json.loads(r.stdout) if r.returncode == 0 else None
    except (OSError, subprocess.TimeoutExpired, ValueError):
        return None


def latest_checks(view: dict) -> list:
    """Keep status contexts independent and supersede only completed named runs
    strictly older than a green run of the same name, ordered by startedAt
    (completedAt if absent). Unfinished, tied, unnamed or undated non-green
    runs remain blocking; missing or malformed timestamps cannot prove age.
    """
    runs = {}
    verdicts = []
    for i, c in enumerate(view.get("statusCheckRollup") or []):
        if c.get("__typename") != "CheckRun":
            verdicts.append(c.get("state") or "PENDING")
            continue
        name = c.get("name") or ""
        when = c.get("startedAt") or c.get("completedAt") or ""
        if not re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", when):
            when = ""
        verdict = (c.get("conclusion") or "PENDING") if c.get("status") == "COMPLETED" else "PENDING"
        runs.setdefault((name, -1 if name else i), []).append((when, verdict, c.get("status") == "COMPLETED"))
    for group in runs.values():
        newest_green = max((when for when, verdict, _ in group if verdict in ("SUCCESS", "NEUTRAL", "SKIPPED")), default="")
        verdicts.extend(verdict for when, verdict, completed in group
                        if verdict in ("SUCCESS", "NEUTRAL", "SKIPPED")
                        or not (completed and when and when < newest_green))
    return verdicts


def pr_green(view: dict) -> bool:
    """Eligibility predicate for the unmerged condition documented above."""
    concl = latest_checks(view)
    return (view.get("state") == "OPEN" and not view.get("isDraft") and view.get("mergeable") == "MERGEABLE"
            and bool(concl) and all(c in ("SUCCESS", "NEUTRAL", "SKIPPED") for c in concl))


def pr_summary(view: dict) -> str:
    bad = sorted({c.lower() for c in latest_checks(view)} - {"success", "neutral", "skipped"})
    return "mergeable %s, checks %s" % ((view.get("mergeable") or "unknown").lower(), ", ".join(bad) or "green")


def pr_hold_label(view: dict) -> str:
    """First hold label on the PR, reusing fm-pr-lib.sh's one hold-label rule."""
    r = bash('. "$1/fm-pr-lib.sh"; fm_pr_hold_label "$2"', str(SCRIPT_DIR), json.dumps(view))
    return r.stdout.strip() if r.returncode == 0 else ""


def approval_wait(state: Path, wid: str) -> str | None:
    """None if admitted, otherwise the bound key or "" if the key is unreadable.

    bin/fm-approval-wait.sh owns admission; an empty key still excludes PR actions.
    Reading creates nothing and holds no lock.
    """
    r = bash('. "$1/fm-approval-wait.sh"; fm_approval_wait_admit "$2" "$3" && exit 0; '
             'jq -r ".decision_key // \\"\\"" "$2/$3.approval-wait" 2>/dev/null; exit 1',
             str(SCRIPT_DIR), str(state), wid)
    return None if r.returncode == 0 else r.stdout.strip()


def decision_key(line: str) -> str:
    r = bash('. "$1/fm-classify-lib.sh"; _fm_decision_key "$2"', str(SCRIPT_DIR), line)
    return r.stdout.strip() if r.returncode == 0 else ""


def minutes(secs: int) -> int:
    return max(0, secs) // 60


def timestamp(epoch: int) -> str:
    return time.strftime("%Y-%m-%d %H:%M:%S UTC", time.gmtime(epoch))


def instruction(wid: str, cond: str, age: int, verb: str, text: str, waiting: str = "") -> str:
    quote = (text[:160] + "...") if len(text) > 160 else text
    relaunch = "relaunch it (bin/fm-spawn.sh --relaunch %s), replace it, or close it" % wid
    if cond == "dead":
        return ("worker %s has had no live agent for %d minutes: %s now; never leave it waiting"
                % (wid, minutes(age), relaunch))
    if cond == "approval":
        return ("worker %s has waited %d minutes on your approval wait (\"%s\"): decide it now - release it "
                "(bin/fm-approval-wait.sh release) and send it back to the deliverable, fix what it is waiting on "
                "(a refused PR step is yours to fix: sanitize and retry, or open the PR by hand), or retire it; if the "
                "decision is truly the captain's, raise it in one plain line - an approval wait is never an endpoint"
                % (wid, minutes(age), quote))
    if cond == "unmerged":
        return ("worker %s's PR %s has been green and mergeable for %d minutes and is not merged: merge it now with "
                "bin/fm-pr-merge.sh %s when bin/fm-merge-policy.sh allows, or close it if it is superseded; a PR "
                "auto-land should have taken means auto-land is not running here (bin/fm-autoland.sh status)"
                % (wid, text, minutes(age), wid))
    if cond == "ci-stuck":
        return ("worker %s's validation run has sat in its CI step for %d minutes and its PR is still open (%s): "
                "land it or close it now - rerun failed or cancelled checks, have the worker rebase a conflicting "
                "branch (no-mistakes rerun), merge it once green, or close it if it is superseded"
                % (wid, minutes(age), text))
    if cond == "frozen":
        return ("worker %s finished %d minutes ago in a freeze (\"%s\") but its PR %s is still open: a freeze, "
                "hold or preserved state is never an endpoint - land it now (remove the hold label, have the worker "
                "fix anything failing, then bin/fm-pr-merge.sh %s when bin/fm-merge-policy.sh allows) or close the "
                "PR with a one-line reason, then retire the worker; raise it to the captain in one line only if the "
                "merge is truly his" % (wid, minutes(age), quote, waiting, wid))
    if cond == "undelivered":
        return ("worker %s finished %d minutes ago (\"%s\") and is still in the fleet: send its result to the "
                "conversation that asked for it now with bin/fm-send.sh <conversation> --result '<outcome and report "
                "path>'%s, then retire the worker (cleanup); never leave it idle" % (wid, minutes(age), quote, waiting))
    if cond == "blocked":
        return ("worker %s has been %s for %d minutes (\"%s\"): unblock it in this turn - a refusal from the fleet's "
                "own tooling (a PR guard, a spawn, a pipeline step) is yours to fix: retry it, fix the input, repair the "
                "tool or do the step by hand; answer it and send it back to the deliverable, %s; raise a captain call "
                "only for a decision that is truly the captain's" % (wid, verb, minutes(age), quote, relaunch))
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
            "frozen": "landing or closing its open PR (a freeze is not an endpoint)",
            "approval": "a decision on its approval wait (release, fix, retire, or one captain line)",
            "unmerged": "merging its green PR",
            "ci-stuck": "landing or closing its PR",
            "held": "releasing its hold so it resumes the deliverable",
            }.get(cond, "steering it back to the deliverable, or a relaunch")


class Scan:
    def __init__(self, h: Path, state: Path):
        self.h = h
        self.state = state
        self.dir = self.state / "keepalive"
        self.dir.mkdir(parents=True, exist_ok=True)
        marker = h / ".fm-secondmate-home"
        self.primary = not (marker.exists() or marker.is_symlink())
        self.escalate_after = ESCALATE if self.primary else FOLLOW
        self._approval_keys = {}
        self._approval_ids = {}
        self.wait_bound = set()
        self.pr_open = {}

    def tell_captain(self, key: str, text: str, after: str) -> bool:
        notify = os.environ.get("FM_KEEPALIVE_NOTIFY") or str(SCRIPT_DIR / "fm-notify.sh")
        try:
            r = subprocess.run([notify, "--title", "Stuck work", text], capture_output=True, text=True, timeout=60,
                               env=dict(os.environ, FM_HOME=str(self.h)))
        except (OSError, subprocess.TimeoutExpired):
            return False
        if r.returncode != 0:
            return False
        return self.wake(key, text + after)

    def wake(self, key: str, text: str) -> bool:
        return bash('. "$1/fm-wake-lib.sh"; fm_wake_append check "$2" "$3"', str(SCRIPT_DIR), key,
                    "check: worker keep-alive: " + text).returncode == 0

    def report(self, wid: str, rec: dict, verb: str, text: str) -> bool:
        """Raise (blocked) or resolve one plain line beyond this home."""
        rc = 1
        if rec.get("route") != "captain":
            script = ('. "$1/fm-wake-lib.sh"; . "$1/fm-parent-channel-lib.sh"; hid=$(fm_parent_channel_home_id "$2" 2>/dev/null || printf home); '
                      'fm_parent_channel_report "$2" "$3" "$4 [key=keepalive-$hid-$5-$6]: $(fm_parent_channel_clean_note "$7")"')
            episode = str(rec["first"]) + ("-" + rec["approval_id"] if rec.get("approval_id") else "")
            rc = bash(script, str(SCRIPT_DIR), str(self.h), str(self.state), verb, wid, episode, text, timeout=120).returncode
        if rc == 0:
            return True
        after = "; the captain was told in one line - keep fixing it" if verb == "blocked" else "; the captain was told"
        if rc != 1:
            print("fm-worker-keepalive: %s: parent channel refused the %s line (rc=%d); telling the captain"
                  % (wid, verb, rc), file=sys.stderr)
            text += " (this home's parent channel could not take it, rc=%d)" % rc
            if verb == "blocked":
                after = "; the parent channel is broken, so the captain was told - keep fixing it and repair the channel"
        event = "escalate" if verb == "blocked" else "resolved"
        sent = self.tell_captain("keepalive:%s:%s:%d" % (wid, event, NOW), text, after)
        if sent:
            rec["route"] = "captain"
        return sent

    def resolve(self, wid: str, rec: dict, why: str) -> bool:
        if rec.get("escalated") and not self.report(wid, rec, "resolved", "worker %s %s" % (wid, why)):
            return False
        return True

    def condition(self, wid: str, m: dict, rec: dict):
        """(cond, since, verb, text) for this worker now; cond None when healthy."""
        status = self.state / ("%s.status" % wid)
        verb, text = last_status(status)
        self.wait_bound.discard(wid)
        key = self.approval_key(wid)
        if key is not None:
            try:
                stamp = (self.state / ("%s.approval-wait" % wid)).lstat().st_mtime_ns
            except OSError:
                stamp = NOW * 1_000_000_000
            declared = min(NOW, stamp // 1_000_000_000)
            if NOW - declared >= APPROVAL or (verb in ("blocked", "failed", "needs-decision", "paused")
                                              and key and decision_key(last_line(status)) == key):
                self.wait_bound.add(wid)
                self._approval_ids[wid] = hashlib.sha256(("%d:%s" % (stamp, key)).encode()).hexdigest()[:16]
                return "approval", declared, verb, text
        if wid in self.done_ids:
            return "undelivered", NOW, "accepted", text or "its backlog item is done"
        pr = self.pr_condition(m, rec)
        if pr and (pr[0] != "unknown" or rec.get("cond") in ("unmerged", "ci-stuck", "frozen")):
            return pr
        if verb == "done":
            opened = min(NOW, mtime(status) or NOW)
            if m.get("pr") and self.pr_open.get(wid) and FROZEN_RE.search(text) and self.approval_key(wid) is None:
                return "frozen", opened, verb, text
            return ("done" if m.get("pr") else "undelivered"), opened, verb, text
        if liveness(self.h, self.state, wid) == "dead":
            return "dead", NOW, verb or "", text
        opened = min(NOW, mtime(status) or NOW)
        if verb in ("blocked", "failed"):
            return "blocked", opened, verb, text
        if rec.get("track", {}).get("ci") or rec.get("track", {}).get("green"):
            # waiting on CI or a merge has its own bounds above; it is not a stall
            return None, opened, verb or "working", text
        if bash('. "$1/fm-external-wait.sh"; keepalive_now=$4; fm_external_wait_now_epoch() { printf "%s\\n" "$keepalive_now"; }; '
                'fm_external_wait_active "$2" "$3"', str(SCRIPT_DIR), wid, str(self.state), str(NOW)).returncode == 0:
            return None, opened, verb or "working", text
        if verb in ("paused", "captain-held"):
            return ("held" if mate_decidable(verb, text) else None), opened, verb, text
        return "no-progress", rec.get("fp_since", NOW), verb or "working", text

    def pr_condition(self, m: dict, rec: dict):
        """unmerged or ci-stuck when mature, unknown on a failed PR read, else None."""
        track = rec.setdefault("track", {})
        url = m.get("pr") or ""
        if track.get("pr") != url:
            track.clear()
        track["pr"] = url
        step = meta(self.state / ("%s.crew-state" % m.get("_id", ""))).get("step", "")
        if step == "ci" and url:
            track.setdefault("ci", NOW)
        else:
            track.pop("ci", None)
        view = pr_view(url) if url else None
        self.pr_open[m.get("_id", "")] = bool(view) and view.get("state") == "OPEN"
        if view is None:
            return ("unknown", NOW, "", "") if url else None
        if view.get("state") != "OPEN":
            track.pop("ci", None)
            track.pop("green", None)
            return None
        green = pr_green(view)
        if not green:
            track.pop("green", None)
        else:
            track.setdefault("green", NOW)
        if self.approval_key(m.get("_id", "")) is not None or pr_hold_label(view):
            return None
        if green and NOW - track["green"] >= PR_GREEN:
            return "unmerged", track["green"], "green", url
        if not green and "ci" in track and NOW - track["ci"] >= CI_STEP:
            return "ci-stuck", track["ci"], "ci", "%s, %s" % (url, pr_summary(view))
        return None

    def approval_key(self, wid: str) -> str | None:
        if wid not in self._approval_keys:
            self._approval_keys[wid] = approval_wait(self.state, wid)
        return self._approval_keys[wid]

    def one(self, wid: str, m: dict) -> None:
        rec_path = self.dir / ("%s.json" % wid)
        rec = load(rec_path, {})
        m = dict(m, _id=wid)
        if rec.get("cond") in ("unmerged", "ci-stuck", "frozen") and rec.get("track", {}).get("pr") != (m.get("pr") or ""):
            if not self.resolve(wid, rec, "moved to another PR"):
                return
            rec = {}
        if rec.get("cond") in STALL_CONDITIONS:
            rec.setdefault("episode_fp", rec.get("fp"))
        fp = fingerprint(self.state, wid, m)
        if rec.get("fp") != fp:
            rec["fp"], rec["fp_since"] = fp, NOW
        cond, since, verb, text = self.condition(wid, m, rec)
        if cond == "unknown":
            save(rec_path, rec)
            return
        if cond == "no-progress" and NOW - since < NO_PROGRESS and (
                rec.get("cond") not in STALL_CONDITIONS or fp != rec.get("episode_fp")):
            cond = None
        if cond in (None, "done"):
            if rec.get("cond") and not self.resolve(wid, rec, "is moving again"):
                save(rec_path, rec)
                return
            rec = {"fp": rec["fp"], "fp_since": rec["fp_since"], "track": rec.get("track", {})}
            save(rec_path, rec)
            return
        if rec.get("cond") in STALL_CONDITIONS and cond in STALL_CONDITIONS:
            rec["cond"] = cond
        elif rec.get("cond") != cond or (cond == "approval" and rec.get("approval_id") != self._approval_ids[wid]):
            if rec.get("cond") and not self.resolve(wid, rec, "is no longer %s" % rec["cond"]):
                save(rec_path, rec)
                return
            rec = {"fp": rec["fp"], "fp_since": rec["fp_since"], "episode_fp": rec["fp"], "cond": cond, "since": since,
                   "woke": 0, "nudges": 0, "escalated": False, "track": rec.get("track", {})}
            if cond == "approval":
                rec["approval_id"] = self._approval_ids[wid]
        bound = {"dead": DEAD, "no-progress": NO_PROGRESS, "undelivered": DONE, "frozen": DONE, "unmerged": 0, "ci-stuck": 0,
                 "approval": APPROVAL}.get(cond, STUCK)
        age = NOW - rec["since"]
        if (rec.get("escalated") and (not self.primary or rec.get("captain_notified"))) or (
                not rec["woke"] and age < bound):
            save(rec_path, rec)
            return
        if rec["woke"] or rec.get("escalated"):
            # only the condition clearing counts; a steer or relay is not a fix
            if rec.get("escalated") or NOW - rec["woke"] >= self.escalate_after:
                line = ("worker %s has been stuck (%s) since %s and %s; it needs %s - act on it now: "
                        "steer the mate with the concrete fix or do it yourself; an acknowledgment is not a fix"
                        % (wid, cond, timestamp(rec["first"]),
                           "I could not unstick it" if self.primary
                           else "its mate did not fix it within %d minutes of the keep-alive wake" % minutes(FOLLOW),
                           unstick(cond)))
                if self.report(wid, rec, "blocked", line):
                    rec["escalated"] = True
                    if self.primary:
                        rec["captain_notified"] = True
            save(rec_path, rec)
            return
        waiting = result_trail(self.state) if cond == "undelivered" else m.get("pr", "") if cond == "frozen" else ""
        reminder = (". A steer, acknowledgment or relay is not a fix: if it is still stuck, %s is told in %d minutes"
                    % ("the captain" if self.primary else "your parent mate", minutes(self.escalate_after)))
        episode = str(rec["since"]) + ("-" + rec["approval_id"] if rec.get("approval_id") else "")
        if self.wake("keepalive:%s:%s:%s" % (wid, cond, episode), instruction(wid, cond, age, verb, text, waiting) + reminder):
            rec.update(woke=NOW, nudges=rec["nudges"] + 1)
            rec.setdefault("first", rec["since"])
        save(rec_path, rec)

    def questions(self, mate: str) -> dict:
        """Still-open parent-bound questions in a second mate's channel, by identity."""
        r = bash('. "$1/fm-classify-lib.sh"; _fm_status_open_decision_origins "$2" episode; '
                 'printf "\\n--open--\\n"; status_open_decisions "$2"', str(SCRIPT_DIR),
                 str(self.state / ("%s.status" % mate)))
        origins_text, _, open_text = r.stdout.partition("\n--open--\n")
        origins = dict(line.split("\t", 1) for line in origins_text.splitlines() if "\t" in line)
        out = {}
        for line in open_text.splitlines():
            key, _, rest = line.partition("\t")
            verb, _, note = rest.partition("\t")
            relay = verb == "blocked" and key.startswith("keepalive-")
            if verb not in ("needs-decision", "blocked") or (key.startswith(MACHINE_KEYS) and not relay):
                continue
            identity = origins.get(key, "") if relay else note
            ident = key + "-" + hashlib.sha256(identity.encode()).hexdigest()[:16]
            out[ident] = {"key": key, "note": note, "origin": origins.get(key)}
            if relay:
                out[ident]["relay"] = True
        return out

    def asks(self, mate: str) -> None:
        directory = self.dir / "asks"
        directory.mkdir(exist_ok=True)
        rec_path = directory / ("%s.json" % mate)
        rec = load(rec_path, {"asks": {}})
        try:
            st = (self.state / ("%s.status" % mate)).stat()
            sig = "%d:%d:%d" % (st.st_ino, st.st_size, st.st_mtime_ns)
        except OSError:
            st, sig = None, ""
        # the whole-file fold costs seconds on a long channel; reuse it while the file is unchanged
        if sig and rec.get("sig") == sig and isinstance(rec.get("open"), dict) and "relays" in rec:
            now_open = rec["open"]
        else:
            now_open = self.questions(mate)
            rec["sig"], rec["open"] = sig, now_open
        self.relays(mate, rec, {i: q for i, q in now_open.items() if q.get("relay")}, snapshot=st)
        previous = {a["key"]: a for a in rec.get("asks", {}).values()}
        asks = rec["asks"] = {}
        for ident, q in now_open.items():
            if q.get("relay"):
                continue
            a = previous.get(q["key"])
            if a is None or int(q.get("origin") or 0) > int(a.get("origin") or 0):
                a = {"first": NOW, "woke": 0, "escalated": False}
            asks[ident] = a
            a.update(q)
        due = sorted((a for a in asks.values() if not a["woke"] and NOW - a["first"] >= ASK), key=lambda a: a["first"])
        if due:
            listed = "; ".join("[%s] \"%s\"" % (a["key"], a["note"][:200]) for a in due[:5])
            more = " (and %d more)" % (len(due) - 5) if len(due) > 5 else ""
            text = ("second mate %s has waited %d minutes for your answer to %d question%s: %s%s. Answer each now from what "
                    "you already know - the captain's own earlier words beat a relay, and housekeeping is yours to decide - "
                    "with bin/fm-send.sh %s --resolve-key %s '<answer>'; if one truly needs the captain, ask him in one "
                    "plain line now; never leave the mate waiting"
                    % (mate, minutes(NOW - due[0]["first"]), len(due), "" if len(due) == 1 else "s", listed, more, mate,
                       due[0]["key"] if len(due) == 1 else "<key>"))
            if self.wake("keepalive:%s:asks:%d" % (mate, due[0]["first"]), text):
                for a in due:
                    a["woke"] = NOW
        escalated = {ident: a for ident, a in asks.items()
                     if a["escalated"] or (a["woke"] and NOW - a["woke"] >= ESCALATE)}
        esc_ids = sorted(escalated)
        if escalated and (esc_ids != rec.get("esc_ids") or (self.primary and not rec.get("captain_notified"))):
            pending = sorted(escalated.values(), key=lambda a: a["first"])
            first = rec.get("esc_first") or pending[0]["first"]
            line = ("second mate %s has waited %s for an answer to %d question%s and its parent did not answer; "
                    "it needs an answer to \"%s\"%s"
                    % (mate, "since %s" % timestamp(pending[0]["first"]) if self.primary
                       else "%d minutes" % minutes(NOW - pending[0]["first"]),
                       len(pending), "" if len(pending) == 1 else "s",
                       pending[0]["note"][:200], " and %d more" % (len(pending) - 1) if len(pending) > 1 else ""))
            episode = rec.setdefault("esc_report", {"first": first})
            if self.report(mate + "-ask", episode, "blocked", line):
                rec["esc_first"], rec["esc_ids"] = first, esc_ids
                if self.primary:
                    rec["captain_notified"] = True
                for a in pending:
                    a["escalated"] = True
        elif not escalated and rec.get("esc_first"):
            episode = rec.setdefault("esc_report", {"first": rec["esc_first"]})
            if self.report(mate + "-ask", episode, "resolved",
                           "second mate %s's questions are answered" % mate):
                rec.pop("esc_first")
                rec.pop("esc_report", None)
                rec.pop("esc_ids", None)
                rec.pop("captain_notified", None)
        save(rec_path, rec)

    def relay_tail(self, mate: str, rec: dict, now_open: dict, snapshot):
        seen = set(rec.get("tail_seen", []))
        tracked = {ident[:-17] for ident in rec.get("relays", {})}
        open_keys = {q["key"] for q in now_open.values()}
        seen.update(tracked | open_keys)
        if snapshot is None:
            rec.update(tail_offset=0, tail_inode=None, tail_seen=sorted(seen))
            return {}, {}
        inode = "%d:%d" % (snapshot.st_dev, snapshot.st_ino)
        try:
            with (self.state / ("%s.status" % mate)).open("rb") as channel:
                st = os.fstat(channel.fileno())
                if (st.st_dev, st.st_ino) != (snapshot.st_dev, snapshot.st_ino):
                    return {}, {}
                offset = rec.get("tail_offset", snapshot.st_size)
                restarted = "tail_offset" in rec and (rec.get("tail_inode") != inode or offset > snapshot.st_size)
                if restarted:
                    offset = 0
                channel.seek(offset)
                tail = channel.read(snapshot.st_size - offset)
        except FileNotFoundError:
            return {}, {}
        openings, last = {}, {}
        for index, (key, verb, note) in enumerate(keyed_status_lines(tail.decode(errors="replace"))):
            if not key.startswith("keepalive-"):
                continue
            last[key] = (verb, note)
            if verb == "blocked":
                openings.setdefault(key, (index, note))
        candidates = {}
        pending = rec.setdefault("tail_pending", {})
        for key, (index, note) in openings.items():
            if key in tracked | open_keys or (restarted and key in seen):
                continue
            verb, closing = last[key]
            if verb == "resolved" and not WATCHDOG_RESOLVED_RE.match(closing):
                identity = "%s:%d:%d" % (inode, offset, index)
                ident = key + "-" + hashlib.sha256(identity.encode()).hexdigest()[:16]
                candidates[ident] = {"first": pending.pop(key, NOW), "up": False, "note": note}
            elif verb not in ("resolved", "captain-held"):
                pending.setdefault(key, NOW)
        seen.update(openings)
        rec.update(tail_offset=snapshot.st_size, tail_inode=inode, tail_seen=sorted(seen))
        return candidates, {key: value if value[0] in ("resolved", "captain-held") else None
                            for key, value in last.items()}

    def relays(self, mate: str, rec: dict, now_open: dict, gone: bool = False, snapshot=None) -> None:
        """Keep-alive escalations from a second mate: this home acts, else one level up."""
        previous = dict(rec.get("relays", {}))
        closures = {}
        if gone:
            rec.pop("tail_pending", None)
        else:
            candidates, closures = self.relay_tail(mate, rec, now_open, snapshot)
            previous.update(candidates)
            pending = rec.setdefault("tail_pending", {})
            owned = {q["key"] for q in now_open.values()} | {ident[:-17] for ident in previous}
            for key, first in list(pending.items()):
                if key in owned:
                    del pending[key]
                    continue
                closing = self.closing_note(mate, key)
                if closing is None:
                    continue
                del pending[key]
                if closing[0] == "captain-held" or WATCHDOG_RESOLVED_RE.match(closing[1]):
                    continue
                identity = "pending:%d" % first
                ident = key + "-" + hashlib.sha256(identity.encode()).hexdigest()[:16]
                previous[ident] = {"first": first, "up": False, "note": key}
                closures[key] = closing
        relays = rec["relays"] = {}
        for ident, q in now_open.items():
            r = previous.get(ident) or {"first": NOW, "up": False}
            r["note"] = q["note"]
            relays[ident] = r
            if not r["up"] and NOW - r["first"] >= ESCALATE:
                line = ("second mate %s escalated this (first seen %s) and it is still stuck: %s"
                        % (mate, timestamp(r["first"]), q["note"][:600]))
                if self.report("%s-up-%s" % (mate, ident[-8:]), r, "blocked", line):
                    r["up"] = True
        open_keys = {q["key"] for q in now_open.values()}
        for ident, r in previous.items():
            if ident in relays:
                continue
            key = ident[:-17]  # ident is <key>-<16 hex>
            closing = None
            if not gone and key not in open_keys and (not r.get("up") or r.get("dropped")):
                closing = closures[key] if key in closures else self.closing_note(mate, key)
            if closing is None and r.get("dropped") and not gone and key not in open_keys:
                relays[ident] = r
                continue
            if closing is not None and closing[0] == "captain-held":
                continue
            if closing is not None and not WATCHDOG_RESOLVED_RE.match(closing[1]):
                # closed without the stuck work moving: an answer or the mate's own dismissal is not a fix
                if not r.get("dropped"):
                    line = ("second mate %s's keep-alive escalation (first seen %s) was closed without the stuck work "
                            "moving (closed with \"%s\"), so it comes to you: %s"
                            % (mate, timestamp(r["first"]), closing[1][:300], r.get("note", "")[:600]))
                    if self.report("%s-up-%s" % (mate, ident[-8:]), r, "blocked", line):
                        r["up"] = r["dropped"] = True
                relays[ident] = r
                continue
            if not r.get("up"):
                continue
            if not self.report("%s-up-%s" % (mate, ident[-8:]), r, "resolved",
                               "second mate %s's stuck work is moving again" % mate):
                relays[ident] = r

    def closing_note(self, mate: str, key: str):
        """(Verb, note) of the last line on <key> if that line closed it, else None."""
        try:
            text = (self.state / ("%s.status" % mate)).read_text(errors="replace")
        except OSError:
            return None
        last = None
        for line_key, verb, note in keyed_status_lines(text):
            if line_key == key:
                last = (verb, note)
        return last if last and last[0] in ("resolved", "captain-held") else None

    def autoland(self) -> None:
        """Watchdog for configured but disarmed auto-land; see the module contract."""
        config = Path(os.environ.get("FM_CONFIG_OVERRIDE") or self.h / "config")
        rec_path = self.dir / "autoland.json"
        rec = load(rec_path, {})
        disarmed = (config / "autoland.json").is_file() and not (self.state / "autoland.check.sh").exists()
        if not disarmed:
            if rec.get("escalated"):
                if not self.report("autoland", rec, "resolved", "auto-land is armed again"):
                    return
            rec_path.unlink(missing_ok=True)
            return
        rec.setdefault("first", NOW)
        if not rec.get("woke") and NOW - rec["first"] >= DEAD:
            if self.wake("keepalive:autoland:disarmed:%d" % rec["first"],
                         "auto-land is configured (config/autoland.json) but not armed, so green PRs in its repos are "
                         "not merging: re-arm it now with bin/fm-autoland.sh arm; only the captain's own words keep "
                         "it off"):
                rec["woke"] = NOW
        elif rec.get("woke") and not rec.get("escalated") and NOW - rec["woke"] >= (ESCALATE if self.primary else FOLLOW):
            if self.report("autoland", rec, "blocked", "auto-land has been disarmed for %d minutes, so green PRs are "
                           "not merging; it needs bin/fm-autoland.sh arm" % minutes(NOW - rec["first"])):
                rec["escalated"] = True
        save(rec_path, rec)

    def scan(self) -> None:
        self.wait_bound = set()
        try:
            self.autoland()
        except (OSError, ValueError, subprocess.TimeoutExpired) as error:
            print("fm-worker-keepalive: autoland: %s" % error, file=sys.stderr)
        self.done_ids = backlog_done_ids(self.h) if any(
            meta(p).get("kind") in ("ship", "scout") for p in self.state.glob("*.meta")) else set()
        mates = set()
        for path in sorted(self.state.glob("*.meta")):
            if meta(path).get("kind") != "secondmate":
                continue
            mates.add(path.stem)
            try:
                self.asks(path.stem)
            except (OSError, ValueError, KeyError, subprocess.TimeoutExpired) as error:
                print("fm-worker-keepalive: %s: %s" % (path.stem, error), file=sys.stderr)
        for rec_path in sorted((self.dir / "asks").glob("*.json")):
            if rec_path.stem in mates:
                continue
            rec = load(rec_path, {})
            self.relays(rec_path.stem, rec, {}, gone=True)
            if any(r.get("up") for r in rec["relays"].values()):
                save(rec_path, rec)
                continue
            episode = rec.setdefault("esc_report", {"first": rec.get("esc_first")})
            if not rec.get("esc_first") or self.report(rec_path.stem + "-ask", episode, "resolved",
                                                       "second mate %s left the fleet" % rec_path.stem):
                rec_path.unlink(missing_ok=True)
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
            if wid in live or wid == "autoland":
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
