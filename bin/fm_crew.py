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
                                         result.md started memory-before.json runner.log
  data/specialists/<name>/memory.md      its memory: read at every job start,
                                         updated before every job may finish
  data/specialists/<name>/skills/        linked at workdir/.agents/skills

A task group is one parent's ephemeral fan-out: N members share a brief and
each gets its own angle; each member is one `deck run --ephemeral`. A detached
orchestrator runs at most two members on this machine at once, merges their
results with one more ephemeral run, then cleans the whole group up in one step.
A cleanup that cannot prove every member process gone requests a captain-held task;
if that request fails, a separate cleanup escalation wake names the failure.

  state/groups/<gid>.json                the record (0600, atomic)
      {"version":1,"kind":"group","id","title","home","status",
       "created","finished","orchestrator_pid","orchestrator_identity",
       "work_outcome","merge_succeeded","members":[{"key","angle","placement","status","pid","identity",
       "started","finished","result"}],"report","summary","cleanup":{...}|null}
      normal status: running -> merging -> cleaning -> done | failed | cleanup-failed
      requested cleanup: running | merging -> cleaning -> cancelled | cleanup-failed
      cleanup retries restore work_outcome (done, failed, or cancelled) on success
  state/groups/<gid>/                    run files (removed only on proven cleanup)
  data/groups/<gid>/report.md            merged report or merge-failure evidence,
                                         kept after cleanup when produced
  data/groups/<gid>/members/<key>.md     retained completed member results

Both raise one `check:` wake in the owning home when a job or group ends.
The CLI headers own reconciliation, waiting, and explicit cleanup behavior.
All generated Deck prompts use stdin, not argv, so report size is not limited
by the operating system's per-argument bound.

FM_HOME is required; state, data, and project paths are always rooted there.
Only FM_CONFIG_OVERRIDE selects a different config directory; state, data, and
project directory overrides used by endpoint scripts do not apply here.
FM_DECK_BIN overrides the deck executable (default: deck on PATH).
FM_CREW_WORK_ROOT overrides ~/.local/state/firstmate-crew; each home's neutral
workdirs live below its hashed home key (specialists use empty repositories for
owned skill discovery). Choose this root before creating a specialist: its
workdir is persisted, and retirement removes it only within the current root.
FM_CREW_MAX_TURNS defaults to 200 for specialists and members; the merger uses 60.
FM_CREW_DEADLINE_SECS defaults to 3600 for each Deck run; CLI wait timeouts are
independent of this override. docs/configuration.md owns launch environment grants.
Regression entrypoints: tests/fm-specialist.test.sh and tests/fm-group.test.sh.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import importlib.util
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

PROCESS_SPEC = importlib.util.spec_from_file_location("fm_deck_stop", SCRIPT_DIR / "fm-deck-stop.py")
PROCESS_API = importlib.util.module_from_spec(PROCESS_SPEC)
PROCESS_SPEC.loader.exec_module(PROCESS_API)


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


def deck_env() -> dict:
    env = os.environ.copy()
    key = Path.home() / ".config" / "proxai" / "client.key"
    if not env.get("PROXAI_API_KEY_FILE") and not env.get("PROXAI_API_KEY") and key.is_file():
        env["PROXAI_API_KEY_FILE"] = str(key)
    config = os.environ.get("FM_CONFIG_OVERRIDE") or str(home() / "config")
    policy = subprocess.run(
        ["bash", "-c", '. "$1/fm-config-inherit-lib.sh"; . "$1/fm-launch-env-lib.sh"; '
         'fm_launch_env_read "$2" || exit 1; '
         'printf "%s\\n%s\\n%s\\n" "$LAUNCH_ENV_ENABLED" "$FM_LAUNCH_ENV_FLOOR" "$LAUNCH_ENV_NAMES"',
         "fm-crew", str(SCRIPT_DIR), config],
        capture_output=True, text=True, check=False,
    )
    if policy.returncode:
        die(policy.stderr.strip() or "worker launch environment configuration is invalid")
    enabled, floor, names = policy.stdout.split("\n", 2)
    if enabled == "1":
        allowed = set(floor.split()) | set(names.split())
        env = {name: value for name, value in env.items() if name in allowed}
    return env


def deck_bin() -> str:
    requested = os.environ.get("FM_DECK_BIN") or "deck"
    found = shutil.which(requested)
    if not found:
        die(f"deck executable is unavailable: {requested} (set FM_DECK_BIN)")
    return found


def refuse_gate() -> None:
    rc = subprocess.run(
        ["bash", "-c", '. "$1"; fm_refuse_if_gate_agent', "fm-crew", str(SCRIPT_DIR / "fm-gate-refuse-lib.sh")],
        check=False,
    ).returncode
    if rc:
        sys.exit(rc)


def process_identity(pid: int, deck: bool = False) -> dict | None:
    try:
        arguments = None

        def read_arguments():
            nonlocal arguments
            arguments = PROCESS_API.process_arguments(pid)
            return bool(arguments) or not pid_alive(pid)

        # An interpreter's exec can briefly leave its argument snapshot empty.
        # Do not permanently register a live child with an unknown identity.
        if not wait_for(read_arguments, 1) or not arguments:
            return None
        out = subprocess.run(["ps", "-o", "lstart=,pgid=", "-p", str(pid)], capture_output=True, text=True,
                             env=dict(os.environ, LC_ALL="C"))
    except (OSError, subprocess.SubprocessError):
        return None
    fields = out.stdout.strip().rsplit(None, 1)
    if len(fields) != 2 or fields[1] != str(pid):
        return None
    if deck and "run" in arguments:
        arguments = arguments[arguments.index("run"):]
    return {"arguments": hashlib.sha256(json.dumps(arguments).encode()).hexdigest(),
            "started": fields[0], "deck": deck}


def target_state(pid, identity) -> str:
    if not pid_alive(pid):
        return "unknown" if group_alive(pid) else "stopped"
    actual = process_identity(pid, bool(identity and identity.get("deck")))
    if not actual or not identity:
        return "unknown"
    if actual == identity:
        return "owned"
    return "unknown" if actual["started"] == identity.get("started") else "unrelated"


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


def run_deck(argv: list[str], cwd: Path, events: Path, stderr_log: Path, env: dict,
             prompt_file: Path, new_group: bool = False):
    with open(events, "w") as out, open(stderr_log, "a") as err, open(prompt_file, "r") as prompt:
        return subprocess.Popen(
            argv,
            cwd=cwd,
            stdout=out,
            stderr=err,
            stdin=prompt,
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
            if rec.get("status") == "running" and cur and not self.runner_alive(cur):
                pid = cur.get("pid")
                if isinstance(pid, int) and pid > 0 and not pid_alive(pid):
                    hook = specialist_hook(self.job_dir(cur["id"]), Path(rec["memory"]))
                    for child, _, pgid, stat in PROCESS_API.processes():
                        if pgid != pid or stat.startswith("Z"):
                            continue
                        arguments = PROCESS_API.process_arguments(child) or []
                        if ("--session" in arguments and "--hook" in arguments
                                and arguments[arguments.index("--session") + 1:][:1] == [rec["session"]]
                                and arguments[arguments.index("--hook") + 1:][:1] == [hook]):
                            with contextlib.suppress(ProcessLookupError, PermissionError):
                                os.killpg(pid, signal.SIGKILL)
                            break
                self._finish_locked(rec, cur["id"], "interrupted", None)
                rec = self.record()
            return rec

    def runner_alive(self, cur: dict) -> bool:
        pid = cur.get("pid")
        if not pid_alive(pid):
            return False
        arguments = PROCESS_API.process_arguments(pid) or []
        expected = [str(Path(__file__).resolve()), "_spec-run", self.name, cur["id"], "--home", str(self.h)]
        return arguments[1:] == expected

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
        wake(self.h, f"specialist:{self.name}:{job}",
             f"check: specialist {self.name} finished job {job} ({outcome}) - result: {result}")
        return entry


def specialist_workdir(rec: dict) -> Path:
    workdir = Path(rec["workdir"])
    workdir.mkdir(parents=True, exist_ok=True)
    env = {k: v for k, v in os.environ.items() if not k.startswith("GIT_")}
    subprocess.run(["git", "-c", "init.templateDir=", "init", "--quiet", str(workdir)], env=env, check=True)
    skills_link = workdir / ".agents" / "skills"
    skills_link.parent.mkdir(exist_ok=True)
    if not skills_link.exists():
        skills_link.symlink_to(Path(rec["skills_dir"]), target_is_directory=True)
    return workdir


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
        specialist_workdir(rec)
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


def memory_metadata(memory: Path) -> list[int] | None:
    try:
        stat = memory.stat()
        return [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]
    except FileNotFoundError:
        return None


def memory_updated(jdir: Path, memory: Path) -> bool:
    current = memory_metadata(memory)
    return current is not None and current != json.loads((jdir / "memory-before.json").read_text())


def specialist_hook(jdir: Path, memory: Path) -> str:
    command = [sys.executable, str(Path(__file__).resolve()), "_spec-check", str(jdir), str(memory)]
    return "pre_complete=" + shlex.join(command)


def cmd_spec_check(args) -> None:
    jdir = Path(args.job_dir)
    result = jdir / "result.md"
    if not result.is_file() or not result.stat().st_size:
        die(f"Write your result to {result} before finishing.")
    if not memory_updated(jdir, Path(args.memory)):
        die(f"Update your memory file {args.memory} before finishing.")


def cmd_spec_job(args) -> None:
    h = home()
    sp = Specialist(h, args.name)
    brief = brief_text(args)
    deck_bin()
    deck_env()
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
        (jdir / "memory-before.json").write_text(json.dumps(memory_metadata(Path(rec["memory"]))))
        pid = detach(
            [sys.executable, str(Path(__file__).resolve()), "_spec-run", args.name, job, "--home", str(h)],
            jdir / "runner.log",
        )
        rec["status"] = "running"
        rec["current_job"] = {"id": job, "pid": pid, "started": now()}
        sp.save(rec)
    print(f"started job {job} for specialist {args.name}")
    if args.wait:
        if not wait_for(lambda: not sp.runner_alive({"pid": pid, "id": job}), args.wait_timeout):
            die(f"job {job} wait timed out; the job is still running", 1)
        rec = sp.reconcile()
        last = rec.get("last_job") or {}
        if last.get("id") != job:
            die(f"job {job} has no matching completion record", 1)
        print(f"job {job} {last.get('outcome', 'unknown')} result={last.get('result')}")
        if last.get("outcome") != "done":
            sys.exit(1)


def cmd_spec_run(args) -> None:
    """Detached runner for one job: one deck turn on the persistent session."""
    h = home()
    sp = Specialist(h, args.name)
    jdir = sp.job_dir(args.job)
    result = jdir / "result.md"
    rc = 1
    outcome = "failed"
    try:
        with locked(sp.lock_path):
            rec = sp.record()
            if (rec.get("current_job") or {}).get("id") != args.job:
                return
        memory = Path(rec["memory"])
        workdir = specialist_workdir(rec)
        argv = [
            deck_bin(), "run", "-", "--session", rec["session"],
            "--max-turns", str(int(os.environ.get("FM_CREW_MAX_TURNS", DEFAULT_MAX_TURNS))),
            "--deadline-secs", str(int(os.environ.get("FM_CREW_DEADLINE_SECS", DEFAULT_DEADLINE))),
            "--hook", specialist_hook(jdir, memory),
        ]
        rc = run_deck(argv, workdir, jdir / "events.ndjson", jdir / "stderr.log",
                      deck_env(), jdir / "prompt.md").wait()
        if rc == 0 and result.is_file() and result.stat().st_size > 0 and memory_updated(jdir, memory):
            outcome = "done"
    except (Exception, SystemExit) as error:
        print(f"specialist job failed: {error}", file=sys.stderr)
    with locked(sp.lock_path):
        rec = sp.record()
        cur = rec.get("current_job") or {}
        if cur.get("id") != args.job:
            return
        sp._finish_locked(rec, args.job, outcome, rc)


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
        self.cleanup_lock_path = h / "state" / "groups" / f".{gid}.cleanup.lock"

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


def merge_prompt(rec: dict, brief: str, members: list[dict], merged: Path) -> str:
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
    deck_bin()
    deck_env()
    with locked(g.lock_path):
        if g.exists():
            die(f"task group {args.gid!r} already exists; pick a new id", 3)
        g.run_dir.mkdir(parents=True, exist_ok=True)
        (g.run_dir / "brief.md").write_text(brief)
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
            "members": members,
            "merge_succeeded": False,
            "work_outcome": None,
            "report": None,
            "cleanup": None,
        }
        g.save(rec)
        try:
            pid = detach(
                [sys.executable, str(Path(__file__).resolve()), "_group-run", args.gid, "--home", str(h)],
                g.run_dir / "orchestrator.log",
            )
        except OSError as error:
            rec.update(status="failed", work_outcome="failed", failure=str(error), finished=now())
            for m in rec["members"]:
                m["status"] = "cancelled"
            g.save(rec)
            wake(h, f"group:{g.gid}", f"check: task group {g.gid} failed to start: {error}")
            die(f"task group {g.gid} failed to start: {error}", 1)
        rec["orchestrator_pid"] = pid
        rec["orchestrator_identity"] = process_identity(pid)
        g.save(rec)
    print(f"started task group {args.gid} with {len(angles)} members")
    if args.wait:
        if not wait_for(lambda: not pid_alive(pid), args.wait_timeout):
            die(f"task group {args.gid} wait timed out; the group is still running", 1)
        rec = g.record()
        print(f"task group {args.gid} {rec['status']} report={rec.get('report')}")
        if rec["status"] != "done":
            sys.exit(1)


def start_member(g: Group, rec: dict, m: dict, brief: str, total: int) -> subprocess.Popen:
    mdir = g.member_dir(m["key"])
    result = mdir / "result.md"
    n = int(m["key"][1:])
    work = work_root(g.h) / "groups" / g.gid / m["key"]
    work.mkdir(parents=True, exist_ok=True)
    prompt = member_prompt(rec, brief, m["angle"], result, n, total)
    (mdir / "prompt.md").write_text(prompt)
    argv = [
        deck_bin(), "run", "-", "--ephemeral",
        "--max-turns", str(int(os.environ.get("FM_CREW_MAX_TURNS", DEFAULT_MAX_TURNS))),
        "--deadline-secs", str(int(os.environ.get("FM_CREW_DEADLINE_SECS", DEFAULT_DEADLINE))),
        "--hook", result_hook(result),
    ]
    return run_deck(argv, work, mdir / "events.ndjson", mdir / "stderr.log",
                    deck_env(), mdir / "prompt.md", new_group=True)


def cmd_group_run(args) -> None:
    """Detached orchestrator: schedule members, merge, clean up, wake the owner."""
    h = home()
    g = Group(h, args.gid)
    try:
        completed = run_group(g)
    except (Exception, SystemExit) as error:
        print(f"task group failed: {error}", file=sys.stderr)
        with locked(g.cleanup_lock_path):
            with locked(g.lock_path):
                rec = g.record()
                if rec["status"] not in ("running", "merging", "cleaning"):
                    return
                rec.update(status="cleaning", work_outcome="failed", failure=str(error))
                g.save(rec)
            try:
                ok = cleanup_group(g, reason="failed")
            except Exception as cleanup_error:
                print(f"task group cleanup failed: {cleanup_error}", file=sys.stderr)
                g.update(lambda r: r.update(cleanup={"at": now(), "reason": "failed",
                                                     "survivors": [], "error": str(cleanup_error)}))
                ok = False
            g.update(lambda r: r.update(status="failed" if ok else "cleanup-failed", finished=now()))
        completed = True
    if completed:
        rec = g.record()
        done = sum(1 for m in rec["members"] if m["status"] == "done")
        wake(h, f"group:{g.gid}", f"check: task group {g.gid} {rec['status']} ({done}/{len(rec['members'])} members) - report: {rec.get('report')}")


def run_group(g: Group) -> bool:
    with locked(g.lock_path):
        rec = g.record()
    brief = read_text(g.run_dir / "brief.md")
    total = len(rec["members"])
    procs: dict[str, subprocess.Popen] = {}

    while True:
        with locked(g.lock_path):
            rec = g.record()
            if rec["status"] != "running":
                return False
            for key, proc in list(procs.items()):
                rc = proc.poll()
                if rc is None:
                    continue
                del procs[key]
                result = g.member_dir(key) / "result.md"
                m = Group.member(rec, key)
                ok = rc == 0 and result.is_file() and result.stat().st_size > 0
                m.update(status="done" if ok else "failed", finished=now(),
                         result=str(result) if result.is_file() else None)
            queued = [m for m in rec["members"] if m["status"] == "queued"]
            for m in queued:
                if len(procs) >= 2:
                    break
                proc = start_member(g, rec, m, brief, total)
                procs[m["key"]] = proc
                m.update(status="running", placement="local", pid=proc.pid,
                         identity=process_identity(proc.pid, deck=True), started=now())
                g.save(rec)
            g.save(rec)
            if not procs and all(m["status"] != "queued" for m in rec["members"]):
                rec["status"] = "merging"
                g.save(rec)
                merged = g.run_dir / "merged.md"
                work = work_root(g.h) / "groups" / g.gid / "merge"
                work.mkdir(parents=True, exist_ok=True)
                prompt = merge_prompt(rec, brief, rec["members"], merged)
                prompt_file = g.run_dir / "merge-prompt.md"
                prompt_file.write_text(prompt)
                argv = [deck_bin(), "run", "-", "--ephemeral", "--max-turns", "60",
                        "--deadline-secs", str(int(os.environ.get("FM_CREW_DEADLINE_SECS", DEFAULT_DEADLINE))),
                        "--hook", result_hook(merged)]
                merger = run_deck(argv, work, g.run_dir / "merge-events.ndjson",
                                  g.run_dir / "merge-stderr.log", deck_env(), prompt_file)
                break
        time.sleep(0.3)

    merge_rc = merger.wait()
    with locked(g.cleanup_lock_path):
        with locked(g.lock_path):
            rec = g.record()
            if rec["status"] != "merging":
                return False
            g.data.mkdir(parents=True, exist_ok=True)
            report = g.data / "report.md"
            done = sum(1 for m in rec["members"] if m["status"] == "done")
            merge_ok = merge_rc == 0 and merged.is_file() and merged.stat().st_size > 0
            lines = [f"# Task group {rec['title']}\n", f"{done} of {total} members finished with a result.\n"]
            if merge_ok:
                lines.append("## Merged report\n\n" + read_text(merged).strip() + "\n")
            else:
                lines.append("## Merge failed\n\nMember evidence is retained below.\n")
            lines.append("## Member results\n")
            for m in rec["members"]:
                body = read_text(Path(m["result"])) if m.get("result") else ""
                lines.append(f"### {m['key']} - {m['angle']} ({m['status']}, {m['placement']})\n\n{body.strip() or '(no result)'}\n")
            report.write_text("\n".join(lines))
            # The start of the merged result rides on the record for Fleet Town.
            rec["summary"] = first_lines(read_text(merged), 400) if merge_ok else f"{done} of {total} members finished; merge failed"
            rec.update(report=str(report), status="cleaning", merge_succeeded=bool(merge_ok),
                       work_outcome="done" if done == total and merge_ok else "failed")
            g.save(rec)
        ok = cleanup_group(g, reason="finished")
        g.update(lambda r: r.update(status=r["work_outcome"] if ok else "cleanup-failed", finished=now()))
    return True


def cleanup_group(g: Group, reason: str) -> bool:
    """Kill every member process group, remove run files, prove nothing is left."""
    rec = g.record()
    targets = {m["pid"]: m.get("identity") for m in rec["members"] if isinstance(m.get("pid"), int)}
    orch = rec.get("orchestrator_pid")
    if isinstance(orch, int) and orch != os.getpid():
        targets[orch] = rec.get("orchestrator_identity")
    states = {pid: target_state(pid, identity) for pid, identity in targets.items()}
    owned = {pid for pid, state in states.items() if state == "owned"}
    unknown = {pid for pid, state in states.items() if state == "unknown"}
    for sig in (signal.SIGTERM, signal.SIGKILL):
        for pid in list(owned):
            state = target_state(pid, targets[pid])
            if state in ("unrelated", "stopped"):
                owned.discard(pid)
                continue
            with contextlib.suppress(ProcessLookupError, PermissionError):
                os.killpg(pid, sig)
        if wait_for(lambda: not any(group_alive(p) or pid_alive(p) for p in owned), 5):
            break
    survivors = [p for p in owned | unknown if group_alive(p) or pid_alive(p)]
    if orch == os.getpid():
        remaining = [pid for pid, _, pgid, stat in PROCESS_API.processes()
                     if pgid == orch and pid != orch and not stat.startswith("Z") and pid_alive(pid)]
        if remaining:
            survivors.append(orch)
    if os.environ.get("FM_CREW_TEST_SURVIVOR"):
        survivors.append(int(os.environ["FM_CREW_TEST_SURVIVOR"]))
    for m in rec["members"]:
        keep = g.data / "members" / f"{m['key']}.md"
        if m.get("result") and Path(m["result"]).is_file() and Path(m["result"]) != keep:
            keep.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(m["result"], keep)
    work = work_root(g.h) / "groups" / g.gid
    if not survivors:
        shutil.rmtree(work, ignore_errors=True)
        shutil.rmtree(g.run_dir, ignore_errors=True)

    def note(r):
        r["cleanup"] = {"at": now(), "reason": reason, "survivors": survivors}
        if orch not in survivors:
            r["orchestrator_pid"] = None
            r["orchestrator_identity"] = None
        for m in r["members"]:
            if m.get("pid") not in survivors:
                m["pid"] = None
                m["identity"] = None
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
            "situation": first_lines(f"Cleanup could not stop member processes {survivors}. They may still be using the model."),
            "options": [
                {"key": "1", "label": "Retry cleanup", "instruction": f"Run FM_HOME={shlex.quote(str(g.h))} bin/fm-group.sh cleanup {g.gid}."},
                {"key": "2", "label": "Inspect first", "instruction": f"Inspect pids {survivors} before retrying the cleanup."},
            ],
            "recommended": "1",
        }
        card_file = g.h / "state" / "groups" / f".{g.gid}.card.json"
        write_json(card_file, card)
        rc = subprocess.run(
            [str(SCRIPT_DIR / "fm-captain-hold.sh"), "hold", f"group-{g.gid}",
             "--title", card["title"], "--repo", "firstmate", "--reason", card["situation"],
             "--card-file", str(card_file)],
            env=dict(os.environ, FM_HOME=str(g.h), FM_STATE_OVERRIDE=str(g.h / "state"),
                     FM_DATA_OVERRIDE=str(g.h / "data"), FM_CONFIG_OVERRIDE=str(g.h / "config")),
            check=False,
        ).returncode
        if rc != 0:
            wake(g.h, f"group-cleanup:{g.gid}", f"check: task group {g.gid} cleanup left processes {survivors} and its captain hold failed")
        card_file.unlink(missing_ok=True)
        return False
    return True


def cmd_group_cleanup(args) -> None:
    h = home()
    g = Group(h, args.gid)
    with locked(g.cleanup_lock_path):
        with locked(g.lock_path):
            rec = g.record()
            if not rec.get("work_outcome"):
                if any(m["status"] == "cancelled" for m in rec["members"]):
                    rec["work_outcome"] = "cancelled"
                elif rec.get("merge_succeeded") and rec.get("report") and all(m["status"] == "done" for m in rec["members"]):
                    rec["work_outcome"] = "done"
                elif rec["status"] in ("running", "merging"):
                    rec["work_outcome"] = "cancelled"
                else:
                    rec["work_outcome"] = "failed"
            rec["status"] = "cleaning"
            g.save(rec)
        ok = cleanup_group(g, reason="requested")
        g.update(lambda r: r.update(status=r["work_outcome"] if ok else "cleanup-failed",
                                    finished=r.get("finished") or now()))
    rec = g.record()
    wake(h, f"group-cleanup:{g.gid}", f"check: task group {g.gid} cleanup {rec['status']} - survivors: {rec['cleanup']['survivors']}")
    if not ok:
        print(f"cleanup of task group {args.gid} left processes {rec['cleanup']['survivors']}; captain hold requested", file=sys.stderr)
        sys.exit(1)
    print(f"cleaned up task group {args.gid}: no member processes left")


def cmd_group_status(args) -> None:
    h = home()
    g = Group(h, args.gid)
    rec = g.record()
    live = [m["key"] for m in rec["members"] if target_state(m.get("pid"), m.get("identity")) in ("owned", "unknown")]
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
    s.add_argument("--home", required=True)
    s.set_defaults(fn=cmd_spec_run)

    s = sub.add_parser("_spec-check")
    s.add_argument("job_dir")
    s.add_argument("memory")
    s.set_defaults(fn=cmd_spec_check)

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
    s.set_defaults(fn=cmd_spec_retire)

    s = sub.add_parser("group-start")
    s.add_argument("gid")
    s.add_argument("--title")
    s.add_argument("--brief")
    s.add_argument("--brief-file")
    s.add_argument("--angle", action="append")
    s.add_argument("--angles-file")
    s.add_argument("--wait", action="store_true")
    s.add_argument("--wait-timeout", type=float, default=2 * DEFAULT_DEADLINE + 120)
    s.set_defaults(fn=cmd_group_start)

    s = sub.add_parser("_group-run")
    s.add_argument("gid")
    s.add_argument("--home", required=True)
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

    args = p.parse_args()
    if args.cmd not in ("_spec-check", "group-status", "group-list"):
        refuse_gate()
    if args.cmd in ("_spec-run", "_group-run"):
        os.environ["FM_HOME"] = args.home
    args.fn(args)


if __name__ == "__main__":
    main()
