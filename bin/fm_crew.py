#!/usr/bin/env python3
"""Specialists and task groups: deck runs owned by a home, with no fleet task record.

bin/fm-specialist.sh and bin/fm-group.sh are the public CLIs; their headers own
the usage. This file owns the on-disk layout and the run mechanics.

A specialist is a named, persistent worker of one home. Every job it gets is one
`deck run --session <its session>` turn, so context rolls over between jobs
(deck compacts long sessions). No process stays alive between jobs: an idle
specialist is a record, not an endpoint, and is intentionally persistent.

  state/specialists/<name>.json          the record (0600, atomic)
      {"version":1,"kind":"specialist","persistent":true,"name","subject",
       "home","session","memory","skills_dir","workdir","projects":[...],
       "status":"idle"|"running"|"retired","created","jobs":N,
       "current_job":{"id","pid","started"}|null,
       "last_job":{"id","brief","started","finished","outcome","result"}|null,
       "memory_summary"}
  state/specialists/<name>/history.jsonl one line per finished job
      {"job","brief","started","finished","outcome","result","exit"}
  state/specialists/<name>/jobs/<job>/   brief.md prompt.md events.ndjson
                                         result.md started runner.log
  data/specialists/<name>/memory.md      its memory: read at every job start,
                                         updated before every job may finish
  data/specialists/<name>/skills/        its own skills (DECK_SKILLS_DIRS)

A task group is one parent's ephemeral fan-out: N members share a brief and
each gets its own angle; each member is one `deck run --ephemeral`. A detached
orchestrator runs at most --local-max members on this machine at once (and up to
--remote-max more through `bin/fm-on.sh` to a remote home route), merges their
results with one more ephemeral run, then cleans the whole group up in one step.
A cleanup that cannot prove every member process gone becomes a decision card.

  state/groups/<gid>.json                the record (0600, atomic)
      {"version":1,"kind":"group","id","title","home","status",
       "created","finished","orchestrator_pid","local_max","remote":route|null,
       "remote_max","members":[{"key","angle","placement","status","pid",
       "started","finished","result"}],"report","cleanup":{...}|null}
      status: running -> merging -> cleaning -> done | failed | cleanup-failed
  state/groups/<gid>/                    run files (removed by cleanup)
  data/groups/<gid>/report.md            merged report, kept after cleanup

Both raise one `check:` wake in the owning home when a job or group ends.
FM_DECK_BIN overrides the deck binary; FM_CREW_WORK_ROOT overrides the neutral
working directory root (outside any repository, so no project AGENTS.md loads).
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

SCRIPT_DIR = Path(__file__).resolve().parent
NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,39}$")
DEFAULT_DEADLINE = 3600
DEFAULT_MAX_TURNS = 200


def die(msg: str, code: int = 2) -> None:
    print(msg, file=sys.stderr)
    sys.exit(code)


def now() -> int:
    return int(time.time())


def home() -> Path:
    raw = os.environ.get("FM_HOME", "")
    if not raw:
        die("FM_HOME must be set explicitly (the owning home)")
    path = Path(raw).resolve()
    if not path.is_dir():
        die(f"FM_HOME is not a directory: {path}")
    return path


def write_json(path: Path, data: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.{os.getpid()}.tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as fh:
        json.dump(data, fh, indent=1, sort_keys=True)
        fh.write("\n")
    os.replace(tmp, path)


def read_json(path: Path) -> dict:
    with open(path) as fh:
        return json.load(fh)


@contextlib.contextmanager
def locked(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "a") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


def pid_alive(pid) -> bool:
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    # A reaped child of ours can linger as a zombie; it is not running.
    try:
        out = subprocess.run(["ps", "-o", "stat=", "-p", str(pid)], capture_output=True, text=True)
        return not out.stdout.strip().startswith("Z") and out.stdout.strip() != ""
    except OSError:
        return True


def group_alive(pgid) -> bool:
    if not isinstance(pgid, int) or pgid <= 0:
        return False
    try:
        os.killpg(pgid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    out = subprocess.run(["ps", "-A", "-o", "pgid=,stat="], capture_output=True, text=True)
    for line in out.stdout.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[0] == str(pgid) and not parts[1].startswith("Z"):
            return True
    return False


def deck_bin() -> str:
    explicit = os.environ.get("FM_DECK_BIN")
    if explicit:
        return explicit
    found = shutil.which("deck")
    if not found:
        die("deck is not on PATH (set FM_DECK_BIN)")
    return found


def work_root(h: Path) -> Path:
    base = os.environ.get("FM_CREW_WORK_ROOT") or str(Path.home() / ".local" / "state" / "firstmate-crew")
    key = hashlib.sha256(str(h).encode()).hexdigest()[:12]
    return Path(base) / key


def wake(h: Path, key: str, payload: str) -> None:
    lib = SCRIPT_DIR / "fm-wake-lib.sh"
    env = dict(os.environ, FM_HOME=str(h), STATE=str(h / "state"))
    env.pop("FM_STATE_OVERRIDE", None)
    subprocess.run(
        ["bash", "-c", '. "$1"; fm_wake_append check "$2" "$3"', "fm-wake", str(lib), key, payload],
        env=env,
        check=False,
    )


def first_lines(text: str, limit: int = 280) -> str:
    keep = []
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        keep.append(line.lstrip("-* ").strip())
        if sum(len(x) for x in keep) >= limit:
            break
    out = " ".join(keep)
    return out if len(out) <= limit else out[: limit - 3].rstrip() + "..."


def read_text(path: Path) -> str:
    try:
        return path.read_text()
    except OSError:
        return ""


def require_name(name: str, what: str) -> None:
    if not NAME_RE.match(name):
        die(f"invalid {what} {name!r}: use lowercase letters, digits and dashes (max 40)")


def brief_text(args) -> str:
    if args.brief_file:
        text = Path(args.brief_file).read_text()
    elif args.brief is not None:
        text = args.brief
    else:
        die("give the job a brief with --brief TEXT or --brief-file FILE")
    if not text.strip():
        die("the brief is empty")
    return text.strip() + "\n"


def run_deck(argv: list[str], cwd: Path, events: Path, stderr_log: Path, env: dict, new_group: bool = False):
    with open(events, "w") as out, open(stderr_log, "a") as err:
        return subprocess.Popen(
            argv,
            cwd=cwd,
            stdout=out,
            stderr=err,
            stdin=subprocess.DEVNULL,
            env=env,
            start_new_session=new_group,
        )


def detach(argv: list[str], log: Path, env: dict | None = None) -> int:
    log.parent.mkdir(parents=True, exist_ok=True)
    with open(log, "a") as fh:
        proc = subprocess.Popen(
            argv,
            stdout=fh,
            stderr=fh,
            stdin=subprocess.DEVNULL,
            start_new_session=True,
            env=env or os.environ.copy(),
        )
    return proc.pid


def wait_for(pred, timeout: float) -> bool:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if pred():
            return True
        time.sleep(0.2)
    return pred()


# ------------------------------------------------------------------ specialists


class Specialist:
    def __init__(self, h: Path, name: str):
        require_name(name, "specialist name")
        self.h = h
        self.name = name
        self.state = h / "state" / "specialists" / name
        self.data = h / "data" / "specialists" / name
        self.record_path = h / "state" / "specialists" / f"{name}.json"
        self.history_path = self.state / "history.jsonl"
        self.lock_path = h / "state" / "specialists" / f".{name}.lock"

    def exists(self) -> bool:
        return self.record_path.is_file()

    def record(self) -> dict:
        if not self.exists():
            die(f"no specialist {self.name!r} in this home", 3)
        return read_json(self.record_path)

    def save(self, rec: dict) -> None:
        write_json(self.record_path, rec)

    def job_dir(self, job: str) -> Path:
        return self.state / "jobs" / job

    def reconcile(self) -> dict:
        """Close a job whose runner died without finishing it."""
        with locked(self.lock_path):
            rec = self.record()
            cur = rec.get("current_job")
            if rec.get("status") == "running" and cur and not pid_alive(cur.get("pid")):
                # The runner leads its own process group; a Deck child left
                # behind by a killed runner must not keep working unowned.
                with contextlib.suppress(ProcessLookupError, PermissionError):
                    os.killpg(cur["pid"], signal.SIGKILL)
                self._finish_locked(rec, cur["id"], "interrupted", None)
                rec = self.record()
            return rec

    def _finish_locked(self, rec: dict, job: str, outcome: str, exit_code) -> dict:
        jdir = self.job_dir(job)
        result = jdir / "result.md"
        cur = rec.get("current_job") or {}
        entry = {
            "job": job,
            "brief": first_lines(read_text(jdir / "brief.md"), 160),
            "started": cur.get("started"),
            "finished": now(),
            "outcome": outcome,
            "result": str(result) if result.is_file() else None,
            "exit": exit_code,
        }
        with open(self.history_path, "a") as fh:
            fh.write(json.dumps(entry, sort_keys=True) + "\n")
        rec["status"] = "idle"
        rec["current_job"] = None
        rec["last_job"] = {k: entry[k] for k in ("brief", "started", "finished", "outcome", "result")}
        rec["last_job"]["id"] = job
        rec["last_job"]["summary"] = first_lines(read_text(result), 200)
        rec["jobs"] = int(rec.get("jobs", 0)) + 1
        rec["memory_summary"] = first_lines(read_text(Path(rec["memory"])))
        self.save(rec)
        return entry


def cmd_spec_create(args) -> None:
    h = home()
    sp = Specialist(h, args.name)
    with locked(sp.lock_path):
        if sp.exists():
            die(f"specialist {args.name!r} already exists", 3)
        sp.data.mkdir(parents=True, exist_ok=True)
        skills = sp.data / "skills"
        skills.mkdir(exist_ok=True)
        memory = sp.data / "memory.md"
        if not memory.exists():
            memory.write_text(
                f"# {args.name} memory\n\n"
                f"Subject: {args.subject}\n\n"
                "## Summary\n\n- (nothing learned yet)\n\n## Facts\n\n## Open threads\n"
            )
        workdir = work_root(h) / "specialists" / args.name
        workdir.mkdir(parents=True, exist_ok=True)
        session = f"fm-spec-{args.name}-{secrets.token_hex(4)}"
        rec = {
            "version": 1,
            "kind": "specialist",
            "persistent": True,
            "name": args.name,
            "subject": args.subject,
            "home": str(h),
            "session": session,
            "memory": str(memory),
            "skills_dir": str(skills),
            "workdir": str(workdir),
            "projects": args.project or [],
            "status": "idle",
            "created": now(),
            "jobs": 0,
            "current_job": None,
            "last_job": None,
            "memory_summary": first_lines(memory.read_text()),
        }
        sp.save(rec)
    print(f"created specialist {args.name} session={session} memory={memory} skills={skills}")


def specialist_prompt(rec: dict, job: str, jdir: Path, brief: str) -> str:
    memory = Path(rec["memory"])
    projects = ", ".join(rec.get("projects") or []) or "none recorded"
    home_projects = Path(rec["home"]) / "projects"
    return f"""You are {rec['name']}, a persistent firstmate specialist.
Your subject: {rec['subject']}
Your owner is the firstmate home at {rec['home']}; it hands you jobs and reads your results.
This conversation persists across jobs: earlier jobs above are your own past work.
Projects you may read: {projects} (clones under {home_projects}). Do not edit project files; report what should change.

Job: {job}
RESULT_FILE: {jdir / 'result.md'}
MEMORY_FILE: {memory}

## Your memory as of this job start

{read_text(memory).strip() or '(empty)'}

## Job brief

{brief.strip()}

## Before you finish

1. Write your result for the owner to RESULT_FILE: the answer or findings first, then evidence.
2. Update MEMORY_FILE in place: keep the "## Summary" section to a few lines about the subject, add durable facts you learned, prune what is wrong or stale. Keep it short; it is read at the start of every job.
Your turn cannot finish until both files are written during this job.
"""


def specialist_hook(jdir: Path, memory: Path) -> str:
    started = jdir / "started"
    result = jdir / "result.md"
    script = (
        f'[ -s "{result}" ] || {{ echo "Write your result to {result} before finishing." >&2; exit 2; }}; '
        f'[ "{memory}" -nt "{started}" ] || {{ echo "Update your memory file {memory} before finishing." >&2; exit 2; }}'
    )
    return "pre_complete=bash -c " + shlex.quote(script)


def cmd_spec_job(args) -> None:
    h = home()
    sp = Specialist(h, args.name)
    brief = brief_text(args)
    rec = sp.reconcile()
    with locked(sp.lock_path):
        rec = sp.record()
        if rec.get("status") == "retired":
            die(f"specialist {args.name!r} is retired", 3)
        if rec.get("status") == "running":
            die(f"specialist {args.name!r} is already on job {rec['current_job']['id']}; wait for it", 3)
        job = time.strftime("j%Y%m%dT%H%M%S", time.gmtime()) + "-" + secrets.token_hex(2)
        jdir = sp.job_dir(job)
        jdir.mkdir(parents=True)
        (jdir / "brief.md").write_text(brief)
        (jdir / "prompt.md").write_text(specialist_prompt(rec, job, jdir, brief))
        (jdir / "started").write_text(str(now()))
        # The memory check compares mtimes; make sure a write in this same
        # second still counts as newer than the start marker.
        past = time.time() - 2
        os.utime(jdir / "started", (past, past))
        pid = detach(
            [sys.executable, str(Path(__file__).resolve()), "_spec-run", args.name, job],
            jdir / "runner.log",
        )
        rec["status"] = "running"
        rec["current_job"] = {"id": job, "pid": pid, "started": now()}
        sp.save(rec)
    print(f"started job {job} for specialist {args.name}")
    if args.wait:
        wait_for(lambda: not pid_alive(pid), args.wait_timeout)
        rec = sp.reconcile()
        last = rec.get("last_job") or {}
        print(f"job {job} {last.get('outcome', 'unknown')} result={last.get('result')}")
        if last.get("outcome") != "done":
            sys.exit(1)


def cmd_spec_run(args) -> None:
    """Detached runner for one job: one deck turn on the persistent session."""
    h = home()
    sp = Specialist(h, args.name)
    rec = sp.record()
    jdir = sp.job_dir(args.job)
    memory = Path(rec["memory"])
    workdir = Path(rec["workdir"])
    workdir.mkdir(parents=True, exist_ok=True)
    env = os.environ.copy()
    skills = rec.get("skills_dir")
    if skills:
        env["DECK_SKILLS_DIRS"] = skills
    argv = [
        deck_bin(),
        "run",
        (jdir / "prompt.md").read_text(),
        "--session",
        rec["session"],
        "--max-turns",
        str(int(os.environ.get("FM_CREW_MAX_TURNS", DEFAULT_MAX_TURNS))),
        "--deadline-secs",
        str(int(os.environ.get("FM_CREW_DEADLINE_SECS", DEFAULT_DEADLINE))),
        "--hook",
        specialist_hook(jdir, memory),
    ]
    rc = run_deck(argv, workdir, jdir / "events.ndjson", jdir / "stderr.log", env).wait()
    result = jdir / "result.md"
    outcome = "done" if rc == 0 and result.is_file() and result.stat().st_size > 0 else "failed"
    with locked(sp.lock_path):
        rec = sp.record()
        cur = rec.get("current_job") or {}
        if cur.get("id") != args.job:
            return
        sp._finish_locked(rec, args.job, outcome, rc)
    wake(
        h,
        f"specialist:{args.name}:{args.job}",
        f"check: specialist {args.name} finished job {args.job} ({outcome}) - result: {result}",
    )


def cmd_spec_status(args) -> None:
    h = home()
    sp = Specialist(h, args.name)
    rec = sp.reconcile()
    if args.json:
        print(json.dumps(rec, sort_keys=True))
        return
    last = rec.get("last_job") or {}
    print(f"specialist {rec['name']} ({rec['status']}) - {rec['subject']}")
    print(f"  session: {rec['session']}  jobs: {rec.get('jobs', 0)}")
    if rec.get("current_job"):
        print(f"  on job: {rec['current_job']['id']}")
    if last:
        print(f"  last job: {last.get('id')} {last.get('outcome')} - {last.get('brief')}")
        print(f"  result: {last.get('result')}")
    print(f"  memory: {rec['memory']}")
    print(f"  memory summary: {rec.get('memory_summary', '')}")


def cmd_spec_history(args) -> None:
    h = home()
    sp = Specialist(h, args.name)
    sp.reconcile()
    lines = read_text(sp.history_path).splitlines()[-args.limit :]
    if args.json:
        print(json.dumps([json.loads(x) for x in lines if x.strip()]))
        return
    for line in lines:
        e = json.loads(line)
        when = time.strftime("%Y-%m-%d %H:%M", time.localtime(e.get("finished") or 0))
        print(f"{when} {e['job']} {e['outcome']} - {e.get('brief', '')}")


def cmd_spec_list(args) -> None:
    h = home()
    root = h / "state" / "specialists"
    out = []
    for rec_path in sorted(root.glob("*.json")):
        rec = Specialist(h, rec_path.stem).reconcile()
        if rec.get("status") == "retired" and not args.all:
            continue
        out.append(rec)
    if args.json:
        print(json.dumps(out, sort_keys=True))
        return
    for rec in out:
        last = (rec.get("last_job") or {}).get("finished")
        when = time.strftime("%Y-%m-%d", time.localtime(last)) if last else "never"
        print(f"{rec['name']}\t{rec['status']}\tjobs={rec.get('jobs', 0)}\tlast={when}\t{rec['subject']}")


def cmd_spec_retire(args) -> None:
    h = home()
    sp = Specialist(h, args.name)
    sp.reconcile()
    with locked(sp.lock_path):
        rec = sp.record()
        if rec.get("status") == "running":
            die(f"specialist {args.name!r} is on a job; retire it after the job ends", 3)
        rec["status"] = "retired"
        rec["retired"] = now()
        sp.save(rec)
    if args.purge_session:
        subprocess.run([deck_bin(), "session", "delete", rec["session"]], check=False)
    workdir = Path(rec.get("workdir", ""))
    if workdir.is_dir() and work_root(h) in workdir.parents:
        shutil.rmtree(workdir, ignore_errors=True)
    print(f"retired specialist {args.name}; memory kept at {rec['memory']}")


# ------------------------------------------------------------------ task groups


class Group:
    def __init__(self, h: Path, gid: str):
        require_name(gid, "group id")
        self.h = h
        self.gid = gid
        self.record_path = h / "state" / "groups" / f"{gid}.json"
        self.run_dir = h / "state" / "groups" / gid
        self.data = h / "data" / "groups" / gid
        self.lock_path = h / "state" / "groups" / f".{gid}.lock"

    def exists(self) -> bool:
        return self.record_path.is_file()

    def record(self) -> dict:
        if not self.exists():
            die(f"no task group {self.gid!r} in this home", 3)
        return read_json(self.record_path)

    def save(self, rec: dict) -> None:
        write_json(self.record_path, rec)

    def update(self, fn) -> dict:
        with locked(self.lock_path):
            rec = self.record()
            fn(rec)
            self.save(rec)
            return rec

    @staticmethod
    def member(rec: dict, key: str) -> dict:
        return rec["members"][int(key[1:]) - 1]

    def member_dir(self, key: str) -> Path:
        return self.run_dir / "members" / key


def read_angles(args) -> list[str]:
    angles = list(args.angle or [])
    if args.angles_file:
        angles += [x.strip() for x in Path(args.angles_file).read_text().splitlines() if x.strip()]
    if not angles:
        die("give each member an angle with --angle (repeatable) or --angles-file")
    return angles


def member_prompt(rec: dict, brief: str, angle: str, result: Path, n: int, total: int) -> str:
    return f"""You are member {n} of {total} in a firstmate task group "{rec['title']}".
Every member gets the same brief; you cover one angle only, and the parent merges all members' results.
Do not edit project files; investigate and report.

RESULT_FILE: {result}

## Shared brief

{brief.strip()}

## Your angle

{angle.strip()}

## Before you finish

Write your findings to RESULT_FILE: findings first (most important first, each with its evidence), then anything you could not verify.
Your turn cannot finish until RESULT_FILE is written.
"""


def merge_prompt(rec: dict, brief: str, members: list[dict], merged: Path, extra: str) -> str:
    parts = []
    for m in members:
        body = read_text(Path(m["result"])) if m.get("result") else ""
        parts.append(f"### Member {m['key']} - angle: {m['angle']} ({m['status']})\n\n{body.strip() or '(no result)'}\n")
    joined = "\n".join(parts)
    return f"""You merge the results of a firstmate task group "{rec['title']}" into one report for its parent.

RESULT_FILE: {merged}

## Shared brief the members got

{brief.strip()}

## Merge instructions

Deduplicate overlapping findings, keep each finding's evidence and which members raised it, drop what members contradicted with better evidence, and end with one recommended decision.
{extra.strip()}

## Member results

{joined}

Write the merged report to RESULT_FILE. Your turn cannot finish until it is written.
"""


def result_hook(result: Path) -> str:
    script = f'[ -s "{result}" ] || {{ echo "Write your result to {result} before finishing." >&2; exit 2; }}'
    return "pre_complete=bash -c " + shlex.quote(script)


def cmd_group_start(args) -> None:
    h = home()
    g = Group(h, args.gid)
    brief = brief_text(args)
    angles = read_angles(args)
    if args.local_max < 1 and not args.remote:
        die("--local-max must be at least 1 without --remote")
    with locked(g.lock_path):
        if g.exists():
            die(f"task group {args.gid!r} already exists; pick a new id", 3)
        g.run_dir.mkdir(parents=True, exist_ok=True)
        (g.run_dir / "brief.md").write_text(brief)
        (g.run_dir / "merge.md").write_text(args.merge_brief or "")
        members = []
        for i, angle in enumerate(angles, 1):
            key = f"m{i}"
            g.member_dir(key).mkdir(parents=True, exist_ok=True)
            members.append(
                {"key": key, "angle": angle, "placement": None, "status": "queued", "pid": None,
                 "started": None, "finished": None, "result": None}
            )
        rec = {
            "version": 1,
            "kind": "group",
            "id": args.gid,
            "title": args.title or args.gid,
            "home": str(h),
            "status": "running",
            "created": now(),
            "finished": None,
            "orchestrator_pid": None,
            "local_max": args.local_max,
            "remote": args.remote,
            "remote_max": args.remote_max if args.remote else 0,
            "members": members,
            "merge": not args.no_merge_agent,
            "report": None,
            "cleanup": None,
        }
        g.save(rec)
        pid = detach(
            [sys.executable, str(Path(__file__).resolve()), "_group-run", args.gid],
            g.run_dir / "orchestrator.log",
        )
        rec["orchestrator_pid"] = pid
        g.save(rec)
    print(f"started task group {args.gid} with {len(angles)} members")
    if args.wait:
        wait_for(lambda: not pid_alive(pid), args.wait_timeout)
        rec = g.record()
        print(f"task group {args.gid} {rec['status']} report={rec.get('report')}")
        if rec["status"] != "done":
            sys.exit(1)


def remote_ready(route: str) -> bool:
    out = subprocess.run(
        [str(SCRIPT_DIR / "fm-on.sh"), route, "fm-group.sh", "remote-ready"],
        capture_output=True,
        text=True,
        timeout=60,
    )
    return out.returncode == 0 and "ready" in out.stdout


def start_member(g: Group, rec: dict, m: dict, placement: str, brief: str, total: int) -> subprocess.Popen:
    mdir = g.member_dir(m["key"])
    result = mdir / "result.md"
    n = int(m["key"][1:])
    if placement == "local":
        work = work_root(g.h) / "groups" / g.gid / m["key"]
        work.mkdir(parents=True, exist_ok=True)
        prompt = member_prompt(rec, brief, m["angle"], result, n, total)
        (mdir / "prompt.md").write_text(prompt)
        argv = [
            deck_bin(), "run", prompt, "--ephemeral",
            "--max-turns", str(int(os.environ.get("FM_CREW_MAX_TURNS", DEFAULT_MAX_TURNS))),
            "--deadline-secs", str(int(os.environ.get("FM_CREW_DEADLINE_SECS", DEFAULT_DEADLINE))),
            "--hook", result_hook(result),
        ]
        return run_deck(argv, work, mdir / "events.ndjson", mdir / "stderr.log", os.environ.copy(), new_group=True)
    # Remote: the remote home runs the member and prints its result on stdout.
    # The prompt names the remote result path, so it is built there.
    payload = json.dumps({"title": rec["title"], "brief": brief, "angle": m["angle"], "n": n, "total": total})
    (mdir / "prompt.md").write_text(payload)
    with open(mdir / "remote.out", "w") as out, open(mdir / "stderr.log", "a") as err, open(mdir / "prompt.md") as inp:
        return subprocess.Popen(
            [str(SCRIPT_DIR / "fm-on.sh"), "--stdin", rec["remote"], "fm-group.sh", "remote-member"],
            stdin=inp, stdout=out, stderr=err, start_new_session=True,
        )


def cmd_group_run(args) -> None:
    """Detached orchestrator: schedule members, merge, clean up, wake the owner."""
    h = home()
    g = Group(h, args.gid)
    rec = g.record()
    brief = read_text(g.run_dir / "brief.md")
    total = len(rec["members"])
    remote_ok = bool(rec.get("remote")) and rec.get("remote_max", 0) > 0 and remote_ready(rec["remote"])
    procs: dict[str, subprocess.Popen] = {}

    while True:
        rec = g.record()
        if rec["status"] != "running":
            break  # cancelled by cleanup
        for key, proc in list(procs.items()):
            rc = proc.poll()
            if rc is None:
                continue
            del procs[key]
            mdir = g.member_dir(key)
            result = mdir / "result.md"

            def finish(r, key=key, rc=rc, result=result, mdir=mdir):
                m = Group.member(r, key)
                if m["placement"] != "local" and rc == 0:
                    text = read_text(mdir / "remote.out")
                    if text.strip():
                        result.write_text(text)
                ok = rc == 0 and result.is_file() and result.stat().st_size > 0
                m["status"] = "done" if ok else "failed"
                m["finished"] = now()
                m["result"] = str(result) if result.is_file() else None

            g.update(finish)
        rec = g.record()
        queued = [m for m in rec["members"] if m["status"] == "queued"]
        if not queued and not procs:
            break
        for m in queued:
            if sum(1 for k in procs if Group.member(rec, k)["placement"] == "local") < rec["local_max"]:
                placement = "local"
            elif remote_ok and sum(1 for k in procs if Group.member(rec, k)["placement"] != "local") < rec["remote_max"]:
                placement = f"remote:{rec['remote']}"
            else:
                break
            proc = start_member(g, rec, m, placement, brief, total)
            procs[m["key"]] = proc

            def mark(r, key=m["key"], placement=placement, pid=proc.pid):
                mm = Group.member(r, key)
                mm.update(status="running", placement=placement, pid=pid, started=now())

            rec = g.update(mark)
        time.sleep(0.3)

    rec = g.record()
    if rec["status"] != "running":
        return
    g.update(lambda r: r.update(status="merging"))
    rec = g.record()
    g.data.mkdir(parents=True, exist_ok=True)
    merged = g.run_dir / "merged.md"
    if rec.get("merge"):
        work = work_root(h) / "groups" / g.gid / "merge"
        work.mkdir(parents=True, exist_ok=True)
        prompt = merge_prompt(rec, brief, rec["members"], merged, read_text(g.run_dir / "merge.md"))
        argv = [deck_bin(), "run", prompt, "--ephemeral", "--max-turns", "60",
                "--deadline-secs", str(int(os.environ.get("FM_CREW_DEADLINE_SECS", DEFAULT_DEADLINE))),
                "--hook", result_hook(merged)]
        run_deck(argv, work, g.run_dir / "merge-events.ndjson", g.run_dir / "merge-stderr.log",
                 os.environ.copy(), new_group=True).wait()
    report = g.data / "report.md"
    done = sum(1 for m in rec["members"] if m["status"] == "done")
    lines = [f"# Task group {rec['title']}\n", f"{done} of {total} members finished with a result.\n"]
    if merged.is_file() and merged.stat().st_size > 0:
        lines.append("## Merged report\n\n" + read_text(merged).strip() + "\n")
    else:
        lines.append("## Merged report\n\n(no merge run; member results follow unmerged)\n")
    lines.append("## Member results\n")
    for m in rec["members"]:
        body = read_text(Path(m["result"])) if m.get("result") else ""
        lines.append(f"### {m['key']} - {m['angle']} ({m['status']}, {m['placement']})\n\n{body.strip() or '(no result)'}\n")
    report.write_text("\n".join(lines))
    g.update(lambda r: r.update(report=str(report), status="cleaning"))
    outcome = cleanup_group(g, reason="finished")
    rec = g.record()
    final = "done" if done == total and outcome else ("cleanup-failed" if not outcome else "failed")
    g.update(lambda r: r.update(status=final, finished=now()))
    wake(h, f"group:{g.gid}", f"check: task group {g.gid} {final} ({done}/{total} members) - report: {report}")


def member_pids(rec: dict) -> list[int]:
    return [m["pid"] for m in rec["members"] if isinstance(m.get("pid"), int)]


def cleanup_group(g: Group, reason: str) -> bool:
    """Kill every member process group, remove run files, prove nothing is left."""
    rec = g.record()
    targets = member_pids(rec)
    orch = rec.get("orchestrator_pid")
    if reason != "finished" and isinstance(orch, int) and orch != os.getpid():
        targets.append(orch)
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in targets:
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(pid, sig)
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.kill(pid, sig)
        if wait_for(lambda: not any(group_alive(p) or pid_alive(p) for p in targets), 5):
            break
    survivors = [p for p in targets if group_alive(p) or pid_alive(p)]
    # Tests cannot make a process immune to SIGKILL; this stands in for one.
    if os.environ.get("FM_CREW_TEST_SURVIVOR"):
        survivors.append(int(os.environ["FM_CREW_TEST_SURVIVOR"]))
    for m in rec["members"]:
        keep = g.data / "members" / f"{m['key']}.md"
        if m.get("result") and Path(m["result"]).is_file() and Path(m["result"]) != keep:
            keep.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(m["result"], keep)
    work = work_root(g.h) / "groups" / g.gid
    shutil.rmtree(work, ignore_errors=True)
    if not survivors:
        shutil.rmtree(g.run_dir, ignore_errors=True)

    def note(r):
        r["cleanup"] = {"at": now(), "reason": reason, "survivors": survivors}
        for m in r["members"]:
            if m["status"] in ("queued", "running"):
                m["status"] = "cancelled"
            if m.get("result"):
                kept = g.data / "members" / f"{m['key']}.md"
                m["result"] = str(kept) if kept.is_file() else None

    g.update(note)
    if survivors:
        card = {
            "project": "firstmate",
            "title": f"Task group {g.gid} left processes behind",
            "situation": f"Cleanup could not stop member processes {survivors}. They may still be using the model.",
            "options": [
                {"key": "1", "label": "Retry cleanup", "instruction": f"Run FM_HOME={g.h} bin/fm-group.sh cleanup {g.gid}."},
                {"key": "2", "label": "Inspect first", "instruction": f"Inspect pids {survivors} before retrying the cleanup."},
            ],
            "recommended": "1",
        }
        card_file = g.h / "state" / "groups" / f".{g.gid}.card.json"
        write_json(card_file, card)
        rc = subprocess.run(
            [str(SCRIPT_DIR / "fm-card.sh"), "write", f"group-{g.gid}", "--file", str(card_file)],
            env=dict(os.environ, FM_HOME=str(g.h)),
            check=False,
        ).returncode
        if rc != 0:
            wake(g.h, f"group-cleanup:{g.gid}", f"check: task group {g.gid} cleanup left processes {survivors} and its decision card failed")
        card_file.unlink(missing_ok=True)
        return False
    return True


def cmd_group_cleanup(args) -> None:
    h = home()
    g = Group(h, args.gid)
    before = g.record()["status"]
    # Leaving "running" first stops the orchestrator from starting more members.
    g.update(lambda r: r.update(status="cleaning"))
    ok = cleanup_group(g, reason="requested")
    if not ok:
        final = "cleanup-failed"
    elif before in ("running", "merging", "cleaning", "cleanup-failed"):
        final = "cancelled" if before != "cleanup-failed" else "done"
    else:
        final = before
    g.update(lambda r: r.update(status=final, finished=r.get("finished") or now()))
    rec = g.record()
    if not ok:
        print(f"cleanup of task group {args.gid} left processes {rec['cleanup']['survivors']}; raised a decision card", file=sys.stderr)
        sys.exit(1)
    print(f"cleaned up task group {args.gid}: no member processes left")


def cmd_group_status(args) -> None:
    h = home()
    g = Group(h, args.gid)
    rec = g.record()
    live = [m["key"] for m in rec["members"] if pid_alive(m.get("pid")) or group_alive(m.get("pid"))]
    rec["live_members"] = live
    if args.json:
        print(json.dumps(rec, sort_keys=True))
        return
    print(f"task group {rec['id']} ({rec['status']}) - {rec['title']}")
    for m in rec["members"]:
        print(f"  {m['key']} {m['status']:<9} {m['placement'] or '-':<16} {m['angle']}")
    print(f"  live member processes: {len(live)}")
    if rec.get("report"):
        print(f"  report: {rec['report']}")


def cmd_group_list(args) -> None:
    h = home()
    out = [read_json(p) for p in sorted((h / "state" / "groups").glob("*.json"))]
    if args.json:
        print(json.dumps(out, sort_keys=True))
        return
    for rec in out:
        done = sum(1 for m in rec["members"] if m["status"] == "done")
        print(f"{rec['id']}\t{rec['status']}\t{done}/{len(rec['members'])}\t{rec['title']}")


def cmd_remote_ready(args) -> None:
    del args
    deck = shutil.which("deck") or os.environ.get("FM_DECK_BIN")
    if not deck:
        die("deck is not installed on this machine", 3)
    print("ready")


def cmd_remote_member(args) -> None:
    """Run one member here (a remote home) and print its result on stdout."""
    del args
    payload = json.loads(sys.stdin.read())
    h = home()
    work = work_root(h) / "remote-members" / secrets.token_hex(6)
    work.mkdir(parents=True)
    try:
        result = work / "result.md"
        rec = {"title": payload["title"]}
        prompt = member_prompt(rec, payload["brief"], payload["angle"], result, payload["n"], payload["total"])
        argv = [deck_bin(), "run", prompt, "--ephemeral", "--max-turns", str(DEFAULT_MAX_TURNS),
                "--deadline-secs", str(DEFAULT_DEADLINE), "--hook", result_hook(result)]
        proc = run_deck(argv, work, work / "events.ndjson", work / "stderr.log", os.environ.copy())
        rc = proc.wait()
        if rc != 0 or not result.is_file():
            sys.stderr.write(read_text(work / "stderr.log")[-2000:])
            sys.exit(rc or 1)
        sys.stdout.write(result.read_text())
    finally:
        shutil.rmtree(work, ignore_errors=True)


# ------------------------------------------------------------------ CLI


def main() -> None:
    p = argparse.ArgumentParser(prog="fm_crew.py")
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("create")
    s.add_argument("name")
    s.add_argument("--subject", required=True)
    s.add_argument("--project", action="append")
    s.set_defaults(fn=cmd_spec_create)

    s = sub.add_parser("job")
    s.add_argument("name")
    s.add_argument("--brief")
    s.add_argument("--brief-file")
    s.add_argument("--wait", action="store_true")
    s.add_argument("--wait-timeout", type=float, default=DEFAULT_DEADLINE + 60)
    s.set_defaults(fn=cmd_spec_job)

    s = sub.add_parser("_spec-run")
    s.add_argument("name")
    s.add_argument("job")
    s.set_defaults(fn=cmd_spec_run)

    s = sub.add_parser("status")
    s.add_argument("name")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_spec_status)

    s = sub.add_parser("history")
    s.add_argument("name")
    s.add_argument("-n", "--limit", type=int, default=20)
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_spec_history)

    s = sub.add_parser("list")
    s.add_argument("--all", action="store_true")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_spec_list)

    s = sub.add_parser("retire")
    s.add_argument("name")
    s.add_argument("--purge-session", action="store_true")
    s.set_defaults(fn=cmd_spec_retire)

    s = sub.add_parser("group-start")
    s.add_argument("gid")
    s.add_argument("--title")
    s.add_argument("--brief")
    s.add_argument("--brief-file")
    s.add_argument("--angle", action="append")
    s.add_argument("--angles-file")
    s.add_argument("--merge-brief")
    s.add_argument("--no-merge-agent", action="store_true")
    s.add_argument("--local-max", type=int, default=int(os.environ.get("FM_GROUP_LOCAL_MAX", 2)))
    s.add_argument("--remote")
    s.add_argument("--remote-max", type=int, default=3)
    s.add_argument("--wait", action="store_true")
    s.add_argument("--wait-timeout", type=float, default=2 * DEFAULT_DEADLINE + 120)
    s.set_defaults(fn=cmd_group_start)

    s = sub.add_parser("_group-run")
    s.add_argument("gid")
    s.set_defaults(fn=cmd_group_run)

    for name, fn in (("group-status", cmd_group_status), ("group-cleanup", cmd_group_cleanup)):
        s = sub.add_parser(name)
        s.add_argument("gid")
        if name == "group-status":
            s.add_argument("--json", action="store_true")
        s.set_defaults(fn=fn)

    s = sub.add_parser("group-list")
    s.add_argument("--json", action="store_true")
    s.set_defaults(fn=cmd_group_list)

    sub.add_parser("remote-ready").set_defaults(fn=cmd_remote_ready)
    sub.add_parser("remote-member").set_defaults(fn=cmd_remote_member)

    args = p.parse_args()
    args.fn(args)


if __name__ == "__main__":
    main()
