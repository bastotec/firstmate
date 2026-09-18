#!/usr/bin/env python3
"""fm-stream-agent.py - the thin per-endpoint publisher behind the `stream` backend.

One agent owns one task's pseudoterminal on the machine where that task runs,
and publishes it to the fleet's single hub (bin/fm-stream-hub.py).  It has no
listening socket: everything it does is an outbound authenticated request to
the hub, so a worker machine needs no inbound reachability, no tunnel, and no
page of its own.  docs/stream-backend.md owns setup, security, and limits.

What it owns, and why each stays here rather than at the hub:

  * The pseudoterminal.  A pty must live on the machine whose process it drives.
    This is the reason the hub owns none, and the reason this file exists.
  * The foreground process group.  Supervision asks whether a real agent is at
    the endpoint, and only this machine's process table can answer.  The agent
    reports IDENTITY; bin/backends/stream.sh classifies it through the
    fleet-wide owner in bin/fm-agent-process-lib.sh, so every backend gives the
    same verdict.
  * The status return channel.  The agent appends to its own home's
    state/<id>.status directly.  That record and its path are local, so no local
    path is ever sent to a remote process - which is also what makes a worker on
    another machine work at all.
  * The endpoint's identity.  The hub's registry is in memory, so a hub that
    restarted has forgotten every endpoint it served.  The agent holds the id
    and registers it again when the hub says it does not know it, which is why
    a restarted hub costs observation rather than every running worker.

Commands:

  fm-stream-agent.py serve [options]                   own a pty and publish it
  fm-stream-agent.py --protocol                        print the wire protocol
  fm-stream-agent.py --version                         print the agent version

serve options:

  --hub URL              hub base URL (required)
  --token-file PATH      file whose first line is the publish-class token
  --machine NAME         this machine's name in the fleet (default: hostname)
  --label NAME           the task label, as firstmate spells it
  --cwd DIR              absolute working directory for the task process
  --status-path PATH     local state/<id>.status to append status lines to
  --ready-file PATH      write the durable endpoint id there once registered
  --rows N / --cols N    pseudoterminal geometry (default 40x200)
  --state-interval SECS  how often to publish a state frame. Unset, it is
                         derived from the hub's own staleness window so the two
                         cannot drift apart; an explicit value is never
                         overridden.
  --poll-secs SECS       how long each command long-poll waits (default 25)

The agent exits when its endpoint's process exits, after telling the hub.
"""

from __future__ import annotations

import argparse
import base64
import errno
import fcntl
import json
import os
import random
import re
import signal
import socket
import struct
import subprocess
import sys
import termios
import threading
import time
import urllib.error
import urllib.parse
import urllib.request

AGENT_VERSION = "2.1.0"
AGENT_PROTOCOL = 2

STATUS_STATES = ("working", "needs-decision", "blocked", "paused", "done",
                 "failed", "resolved")
MACHINE_RE = re.compile(r"\A[A-Za-z0-9._-]{1,128}\Z")


def _now() -> float:
    return time.time()


def _become_session_leader() -> None:
    """Child-side: own a new session and take the pty as controlling terminal.

    Job control is not cosmetic here. The foreground process group is the
    liveness signal supervision reads, and a child with no controlling terminal
    has none. subprocess has already dup'd the pty slave onto fd 0 by now.
    """
    os.setsid()
    try:
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    except OSError:
        pass


def _left(until):
    """Seconds until <until>, or None when nothing is bounding this call.

    Every bounded operation reads the deadline itself rather than a duration
    handed down earlier, so a sequence of them cannot add up past it.
    """
    if until is None:
        return None
    return until - time.monotonic()


def _process_cwd(pid: str, until=None) -> str:
    try:
        return os.readlink("/proc/%s/cwd" % pid)
    except OSError:
        pass
    # Where there is no /proc this is the routine path, and it reads through
    # the filesystem the process is sitting in - a hung mount blocks it for as
    # long as that mount does. Against a deadline it answers "unknown" instead.
    left = _left(until)
    if left is not None and left <= 0:
        return ""
    try:
        proc = subprocess.run(
            ["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=left,
            env={"LC_ALL": "C", "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
    except (OSError, subprocess.TimeoutExpired):
        return ""
    for line in proc.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("n/"):
            return line[1:]
    return ""


def _ps_args(pid: str, until=None) -> str:
    left = _left(until)
    if left is not None and left <= 0:
        return ""
    try:
        proc = subprocess.run(
            ["ps", "-p", pid, "-o", "args="],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            timeout=left,
            env={"LC_ALL": "C", "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
    except (OSError, subprocess.TimeoutExpired):
        return ""
    return proc.stdout.decode("utf-8", "replace").strip()


# Every hub call on the startup path, and every subprocess that reads the
# endpoint's own state for the first frame, runs against ONE clock, so an
# operation of either kind added to that path is bounded by it without anyone
# remembering to bound it. The budget is strictly under the window the adapter
# waits for the ready file, so an agent that cannot come up has already given
# up by the time the spawn abandons it rather than registering an endpoint
# nobody waits for. Two things on the abandonment path sit outside the clock
# and are known to: pty.close() can spend ~5s waiting for the process group to
# go, so an abandonment can finish after the adapter's window; and the frame
# that closes a half-registered endpoint is not refused by a spent budget - an
# agent can always close out the record it holds - and instead runs on a short
# ordinary timeout, so an abandonment still finishes inside the window.
STARTUP_BUDGET = 12.0


def _silence_diagnostics() -> None:
    """Send this process's own output to os.devnull for the rest of its life."""
    sys.stdout.flush()
    sys.stderr.flush()
    devnull = os.open(os.devnull, os.O_WRONLY)
    try:
        os.dup2(devnull, 1)
        os.dup2(devnull, 2)
    finally:
        os.close(devnull)


def _default_shell_command() -> list:
    """The operator's own shell, with rc suppression only where it is understood.

    --norc and --noprofile are bash's spelling. zsh and fish reject them and
    exit at birth, so a shell this cannot classify is started plainly rather
    than handed bash's flags.
    """
    shell = os.environ.get("SHELL", "") or "/bin/bash"
    if os.path.basename(shell) == "bash":
        return [shell, "--norc", "--noprofile", "-i"]
    return [shell, "-i"]


class Pty:
    """The task's pseudoterminal, owned here on the machine that runs it."""

    def __init__(self, cwd: str, command: list, rows: int, cols: int, env: dict) -> None:
        self.rows = rows
        self.cols = cols
        self._closed = threading.Event()
        # Every reap and every signal is taken under this lock, because holding
        # an unreaped child is the only thing that makes its pid safe to name.
        # See _signal_group for why that matters.
        self._reap_lock = threading.RLock()
        self.exit_code = None
        master, slave = os.openpty()
        try:
            fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", rows, cols, 0, 0))
        except OSError:
            pass
        try:
            self.slave_name = os.ttyname(slave)
            self.proc = subprocess.Popen(
                command, cwd=cwd, stdin=slave, stdout=slave, stderr=slave,
                env=env, close_fds=True, preexec_fn=_become_session_leader)
        except Exception:
            os.close(master)
            os.close(slave)
            raise
        os.close(slave)
        self.master_fd = master
        self.pid = self.proc.pid
        # The child called setsid(), so it leads its own process group and that
        # group's id IS the child's pid. Recording it here fixes the signal
        # target at the one moment it is provably ours, rather than asking the
        # kernel again later, when the answer may describe a stranger.
        self.pgid = self.pid

    def exited_within(self, timeout: float) -> bool:
        """True when the child is already gone, waiting at most <timeout>."""
        with self._reap_lock:
            try:
                self.exit_code = self.proc.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                return False
        return True

    def read(self, size: int = 65536) -> bytes:
        """One blocking read of the pty, b"" at end of file."""
        while True:
            try:
                return os.read(self.master_fd, size)
            except OSError as exc:
                if exc.errno == errno.EINTR:
                    continue
                return b""
            except ValueError:
                return b""

    def write(self, data: bytes) -> int:
        return os.write(self.master_fd, data)

    def alive(self) -> bool:
        # poll() REAPS an exited child, which releases its pid for reuse, so it
        # is taken under the same lock as the signal path rather than racing it.
        with self._reap_lock:
            return self.proc.poll() is None

    def foreground_processes(self, until=None) -> list:
        """The pty's foreground process group, as identity records.

        Scoped to the foreground group rather than every descendant, for the
        same reason the tmux adapter is: a harness-named process left running in
        the background of an otherwise idle endpoint must not read as a live
        agent.
        """
        tty = self.slave_name
        if tty.startswith("/dev/"):
            tty = tty[len("/dev/"):]
        left = _left(until)
        if left is not None and left <= 0:
            return []
        try:
            proc = subprocess.run(
                ["ps", "-t", tty, "-o", "pid=,pgid=,tpgid=,comm="],
                check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                timeout=left,
                env={"LC_ALL": "C", "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
        except (OSError, subprocess.TimeoutExpired):
            return []
        out = []
        for line in proc.stdout.decode("utf-8", "replace").splitlines():
            fields = line.split(None, 3)
            if len(fields) < 4:
                continue
            pid, pgid, tpgid, comm = fields
            if pgid != tpgid:
                continue
            args = _ps_args(pid, until)
            argv0 = args.strip().split(" ", 1)[0] if args else ""
            out.append({"pid": pid, "name": comm, "argv0": argv0, "args": args})
        return out

    def foreground_cwd(self, until=None) -> str:
        """The working directory of the endpoint's INNERMOST foreground process.

        Innermost first, with the endpoint's own shell as the last resort. The
        order matters: reading the shell first would answer with the shell's
        directory whenever a foreground process had chdir'd elsewhere, which is
        the one case the caller is asking about.
        """
        for entry in reversed(self.foreground_processes(until)):
            cwd = _process_cwd(entry["pid"], until)
            if cwd:
                return cwd
        return _process_cwd(str(self.pid), until)

    def _signal_group(self, sig) -> bool:
        """Signal the endpoint's process group, but only while it is still ours.

        The liveness check and the signal share one lock, and every reap takes
        the same lock, because that is what makes the group id safe to name. An
        unreaped child - running or zombie - still holds its pid, so the group
        recorded at spawn is still the group we created. Once anything calls
        poll() and reaps it, the kernel may hand that pid to an unrelated
        process, and signalling the group it now leads would kill a stranger.
        On this fleet that stranger can be another worker's harness, so a
        reaped endpoint is never signalled at all.

        The cost is that a grandchild outliving a reaped direct child is not
        signalled here. That is the safe side of the trade: those processes lose
        their controlling terminal when the pty master closes, whereas naming a
        pid we no longer own has no safe failure mode.
        """
        with self._reap_lock:
            if self.proc.poll() is not None:
                return False
            own_pgrp = os.getpgrp()
            own_sid = os.getsid(0)
            if self.pgid in (own_pgrp, own_sid):
                # Unreachable while the child's setsid() works: it moves the
                # child into a brand-new session this agent is not part of. If
                # it is ever reached, that isolation failed and signalling this
                # group would take down this agent and whatever launched it, so
                # refuse and say so rather than deliver it.
                sys.stderr.write(
                    "fm-stream-agent: REFUSING to signal process group %d - it is this "
                    "agent's own process group (%d) or session (%d), so the endpoint's "
                    "setsid did not take effect; the endpoint is not isolated\n"
                    % (self.pgid, own_pgrp, own_sid))
                sys.stderr.flush()
                return False
            try:
                os.killpg(self.pgid, sig)
            except OSError:
                # The group is gone but the child is not yet reaped, so its pid
                # is still ours to name.
                try:
                    self.proc.send_signal(sig)
                except OSError:
                    return False
            return True

    def close(self, signal_name: str = "TERM") -> bool:
        """Signal the process group, wait for the reader, then release the fd.

        The reader is woken and joined BEFORE the descriptor is closed. A reader
        still blocked in os.read() on a closed fd can be handed a later
        endpoint's pty when the kernel reuses that fd number, and would then
        publish one worker's output as another's.
        """
        sig = signal.SIGTERM if signal_name == "TERM" else signal.SIGKILL
        killed = self._signal_group(sig)
        if killed:
            deadline = _now() + 3.0
            while _now() < deadline and self.alive():
                time.sleep(0.05)
            self._signal_group(signal.SIGKILL)
        self._closed.set()
        with self._reap_lock:
            try:
                self.proc.wait(timeout=2)
            except Exception:
                pass
            self.exit_code = self.proc.poll()
        return killed

    def release(self) -> None:
        """Close the master descriptor. Call only once no reader can be in it."""
        try:
            os.close(self.master_fd)
        except OSError:
            pass


# The two types below are refusals the hub STATED. A hub that could not be
# reached is neither of them: it has said nothing, and silence is an ordinary
# transient the retries already handle. The whole of what this agent is allowed
# to act on - take an identity back, stand down, stop for good - turns on the
# difference, so these are distinct types rather than one string an ill-judged
# substring match could confuse. The code the hub named is read once, where the
# call is made, to pick the type; everything downstream dispatches on the type
# alone and catches these by name.


class Superseded(RuntimeError):
    """This endpoint's identity now belongs to another live endpoint.

    The one situation an agent cannot come back from: while it was out of
    touch, the hub gave up on its record AND another endpoint took its machine
    and label. Publishing from here would put two workers behind one name, so
    the agent stops instead.
    """


class Forgotten(RuntimeError):
    """The hub has no record of this endpoint, so the agent can take it back.

    The hub keeps its endpoint registry in memory only, so a hub that restarted
    has never heard of any endpoint it was serving. That is the one refusal a
    re-registration answers, and it is stated only by the hub itself - which is
    why it is read from the hub's own code rather than inferred from a failed
    connection, a state a returning hub passes through on its way back up.
    """


# The refusals that mean another live endpoint answers to this one's identity.
# duplicate_label reaches an agent only on a registration, and it says exactly
# what endpoint_superseded says on a publish: the name is taken.
SUPERSEDING_REFUSALS = frozenset(("endpoint_superseded", "duplicate_label"))

# Re-registration pacing. The floor is short because a hub restart is over in
# seconds and a worker is unwatchable and unsteerable until its agent is back;
# the ceiling is what keeps a hub that is down for an hour from being polled by
# every worker in the fleet. The jitter is what the restart case actually needs:
# one restart strands every agent at once, so agents backing off by identical
# amounts would return in lockstep and arrive as one burst against a hub that
# has just come up.
# The command poll's own pace while the hub cannot be reached. Named because
# the wait an outage leaves the poll parked in is what decides how long after a
# recovery a steer would otherwise be refused, so a test of that gap has to
# derive its outage from the same ladder rather than assume one.
POLL_BACKOFF_MIN = 2.0
POLL_BACKOFF_MAX = 60.0
REREGISTER_BACKOFF_MIN = 2.0
REREGISTER_BACKOFF_MAX = 60.0
REREGISTER_JITTER = 0.25


def registration(options: argparse.Namespace, endpoint_id: str) -> dict:
    """This endpoint's identity, in the one spelling the hub is ever given.

    The first registration and every one after it send exactly this, because
    the endpoint id is what every durable record points at: the task's
    metadata binding, the steering inbox reached through it, and the status
    channel it reports into. A re-registration that varied here would come back
    as a different worker and strand all three.
    """
    return {
        "endpoint_id": endpoint_id,
        "machine": options.machine,
        "label": options.label,
        "cwd": options.cwd,
        "rows": options.rows,
        "cols": options.cols,
    }


class HubClient:
    """Outbound-only authenticated calls to the fleet's hub.

    Nothing here assumes a scheme: the hub URL is used exactly as configured, so
    putting a TLS terminator in front of the hub is a deployment change and
    needs no change in this file.
    """

    def __init__(self, base_url: str, token: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.deadline = None

    def begin_startup(self) -> None:
        """Start the one clock every startup operation is bounded by."""
        self.deadline = time.monotonic() + STARTUP_BUDGET

    def end_startup(self) -> None:
        """Return to ordinary per-call timeouts, once the endpoint is announced."""
        self.deadline = None

    def call(self, method: str, path: str, payload=None, timeout: float = 30.0):
        remaining = _left(self.deadline)
        if remaining is not None:
            if remaining <= 0:
                raise RuntimeError("the hub at %s did not finish %s %s within the "
                                   "startup budget" % (self.base_url, method, path))
            timeout = min(timeout, remaining)
        data = None
        headers = {"Authorization": "Bearer " + self.token}
        if payload is not None:
            data = json.dumps(payload).encode("utf-8")
            headers["Content-Type"] = "application/json"
        request = urllib.request.Request(self.base_url + path, data=data,
                                         headers=headers, method=method)
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                body = response.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as exc:
            body = exc.read().decode("utf-8", "replace")
            try:
                parsed = json.loads(body)
            except json.JSONDecodeError:
                parsed = {"message": body.strip() or ("HTTP %d" % exc.code)}
            code = str(parsed.get("error") or "")
            message = "hub refused %s %s: %s" % (method, path,
                                                 parsed.get("message") or exc.code)
            if code in SUPERSEDING_REFUSALS:
                raise Superseded(message)
            if code == "no_such_endpoint":
                raise Forgotten(message)
            raise RuntimeError(message)
        except urllib.error.URLError as exc:
            raise RuntimeError("cannot reach the hub at %s: %s" % (self.base_url, exc.reason))
        except (TimeoutError, OSError) as exc:
            # A hub that accepts the connection and then says nothing raises
            # here rather than as a URLError, and it must read as a hub that
            # could not be reached - not as a crash that skips the caller's
            # own cleanup.
            raise RuntimeError("the hub at %s did not answer %s %s: %s"
                               % (self.base_url, method, path, exc))
        if not body:
            return {}
        try:
            return json.loads(body)
        except json.JSONDecodeError as exc:
            raise RuntimeError("hub returned malformed JSON for %s %s: %s" % (method, path, exc))


def append_status(status_path: str, state: str, note: str) -> None:
    """The status return channel: an ordinary status line, written locally.

    This never travels through the hub. The record and its path belong to this
    machine's home, so the agent is the only process that can write it without a
    local path leaving the machine.
    """
    if not status_path:
        raise RuntimeError("this endpoint registered no status path")
    if state not in STATUS_STATES:
        raise RuntimeError("unknown status state %r (known: %s)"
                           % (state, ", ".join(STATUS_STATES)))
    line = "%s: %s\n" % (state, " ".join(str(note).split()))
    with open(status_path, "a", encoding="utf-8") as fh:
        fh.write(line)


class Agent:
    """One endpoint: its pty here, its frames and state published to the hub."""

    def __init__(self, options: argparse.Namespace, hub: HubClient,
                 pty: Pty, endpoint_id: str) -> None:
        self.options = options
        self.hub = hub
        self.pty = pty
        self.endpoint_id = endpoint_id
        self.machine = options.machine
        self.status_path = options.status_path
        self.stop = threading.Event()
        self.reader_done = threading.Event()
        # Set while a command is being applied or acknowledged. A kill ends the
        # endpoint, which ends this process, so without this the agent could
        # exit between doing the work and reporting it - and the hub would then
        # tell the caller the kill was never delivered when in fact it was.
        self.command_busy = threading.Event()
        # Set when this agent has lost its name to another endpoint. It goes on
        # draining the pty - a worker whose output nobody reads eventually
        # blocks - but publishes nothing and takes no commands.
        self.stood_down = threading.Event()
        # Owned by the command thread alone: only command_loop reads or writes
        # it, so the pace of the command poll is never a value two threads
        # mutate between them. A recovery on another thread says only THAT the
        # endpoint is back, through the event below, and the command thread
        # decides for itself what that means for its own pace.
        self._backoff = POLL_BACKOFF_MIN
        # Set when this agent is back at an endpoint the hub knows, and when
        # the agent is halting. Either makes a command poll waiting out a
        # failed attempt pointless: the first because there is something to
        # poll again, the second because there is nothing left to poll for.
        self._poll_wake = threading.Event()
        # Re-registration is serialized and paced. Three threads publish, so a
        # forgotten endpoint is discovered several times over, and a hub that is
        # down must see one attempt per backoff window rather than one per
        # frame. The lock is only ever taken without blocking: a thread that
        # finds an attempt already in flight has nothing to add by waiting for
        # it, and the pty reader in particular must never be parked on a hub
        # call it did not make.
        self._register_lock = threading.Lock()
        self._register_not_before = 0.0
        self._register_backoff = REREGISTER_BACKOFF_MIN

    def halt(self) -> None:
        """End this agent, and wake whatever is waiting so it ends promptly.

        The command poll waits out a failed attempt on an event rather than on
        `stop`, so a stop that only set `stop` would leave that thread parked
        for as long as its backoff had grown. Every place that ends the agent
        comes through here, which is what keeps that from being something a
        later stop site has to remember.
        """
        self.stop.set()
        self._poll_wake.set()

    # --- publishing -------------------------------------------------------

    def _post_frames(self, frames: list) -> None:
        # A closing frame is a statement about the record this agent already
        # holds, not a claim on the name, so standing down never swallows it:
        # an endpoint left open with no agent behind it is exactly what the
        # stand-down rule is there to avoid.
        closing = any(f.get("closed") for f in frames)
        if self.stood_down.is_set() and not closing:
            return
        for attempt in (0, 1):
            try:
                self.hub.call("POST", "/v1/agent/frames",
                              {"machine": self.machine, "frames": frames}, timeout=30.0)
                return
            except Forgotten as exc:
                # The hub does not know this endpoint. Take the identity back
                # and deliver these frames to the record that comes with it. A
                # closing frame earns the same trip: a worker that exited while
                # the hub was down still owes the fleet its exit, and without
                # this its task would simply never be accounted for.
                if attempt > 0:
                    # A second refusal after a registration that just succeeded
                    # is a race with another agent, not a hub to keep arguing
                    # with. One retry, never a loop.
                    sys.stderr.write("fm-stream-agent: the hub forgot endpoint %s again: "
                                     "%s\n" % (self.endpoint_id, exc))
                    return
                if not self.recover_registration(exc, final=closing):
                    return
            except Superseded as exc:
                self.give_up(exc)
                return
            except RuntimeError as exc:
                # A hub that cannot be reached must not take the worker down
                # with it: the pty keeps running and the next frame retries. The
                # output that could not be published is lost from the hub's
                # ring, which is a bounded history by design, not a transcript
                # of record.
                sys.stderr.write("fm-stream-agent: publish failed: %s\n" % exc)
                return

    def recover_registration(self, reason: Exception, final: bool = False) -> bool:
        """Take this endpoint's identity back from a hub that forgot it.

        The hub's registry lives in its memory, so a hub that restarted has
        never heard of the endpoint this agent holds. Registering the SAME id
        is what brings the worker back whole: it reappears in the fleet listing
        under the id the task's own records name, which is what makes it
        steerable again and what keeps its status channel and its steering
        inbox pointing somewhere real. A fresh id would produce a listed worker
        and strand every record that refers to it, so this never invents one.

        False means the endpoint is not back and the caller should drop what it
        was publishing: the hub was unreachable, the attempt is inside a backoff
        window, or the answer was one this agent does not come back from.

        A FINAL recovery is the closing frame's, and the pace does not apply to
        it. Pacing exists to stop an agent asking again and again; this is the
        last call the agent will ever make, so there is no next attempt to
        space out and nothing to protect the hub from - while the frame it
        carries is the task's end and its exit code, which nothing afterwards
        would ever ask for again. It is still ONE attempt on ordinary timeouts:
        it never waits for an attempt already in flight, and an agent whose hub
        is still down exits rather than holding its teardown open.
        """
        if self.stood_down.is_set():
            return False
        if not self._register_lock.acquire(blocking=False):
            return False
        try:
            if self.stood_down.is_set():
                return False
            if not final and time.monotonic() < self._register_not_before:
                return False
            self._register_not_before = time.monotonic() + self._register_backoff * (
                1.0 + REREGISTER_JITTER * random.random())
            try:
                self.hub.call("POST", "/v1/agent/endpoints",
                              registration(self.options, self.endpoint_id),
                              timeout=15.0)
            except Superseded as exc:
                # Either the next attempt at this task claimed the name while
                # this agent was out of touch, or the hub answers on terms no
                # further attempt changes. Standing down is the same answer a
                # lost contest gets anywhere else, and for the same reason.
                self.give_up(exc)
                return False
            except RuntimeError as exc:
                sys.stderr.write("fm-stream-agent: could not re-register endpoint %s: %s\n"
                                 % (self.endpoint_id, exc))
                self._register_backoff = min(self._register_backoff * 2,
                                             REREGISTER_BACKOFF_MAX)
                return False
            # A registration the hub took resets the pace itself, not only its
            # growth: the window scheduled above was sized by a ladder this
            # answer has just spent, and leaving it in place would bar the next
            # recovery for as long as the failures before it had earned. Both
            # go back to the floor together, so the case that pays for pacing
            # here - a hub that accepts every registration and still refuses
            # every frame - gets one attempt per floor rather than one per
            # frame, which is the rule this pace exists to enforce.
            self._register_backoff = REREGISTER_BACKOFF_MIN
            self._register_not_before = time.monotonic() + REREGISTER_BACKOFF_MIN * (
                1.0 + REREGISTER_JITTER * random.random())
        finally:
            self._register_lock.release()
        # The command poll may be waiting out a failure of its own, and its
        # wait was sized by an outage that is now over. Telling it the endpoint
        # is back is what makes "steerable again" true at the same moment the
        # fleet listing says so, rather than up to a backoff later.
        self._poll_wake.set()
        try:
            self.publish_initial_state(timeout=15.0)
        except RuntimeError as exc:
            # The heartbeat publishes the next one within seconds, so a state
            # frame lost here costs a moment of unreadability, not the recovery.
            sys.stderr.write("fm-stream-agent: re-registered but could not publish "
                             "state: %s\n" % exc)
        sys.stderr.write("fm-stream-agent: re-registered endpoint %s with the hub at %s "
                         "after: %s\n" % (self.endpoint_id, self.hub.base_url, reason))
        return True

    def read_loop(self) -> None:
        """Publish pty output until the process ends."""
        try:
            while not self.stop.is_set():
                chunk = self.pty.read()
                if not chunk:
                    break
                self._post_frames([{
                    "endpoint_id": self.endpoint_id,
                    "b64": base64.b64encode(chunk).decode("ascii"),
                }])
        finally:
            self.reader_done.set()
            self.halt()

    def state_frame(self) -> dict:
        until = self.hub.deadline
        return {
            "endpoint_id": self.endpoint_id,
            "state": {
                "alive": self.pty.alive(),
                "foreground": self.pty.foreground_processes(until),
                "cwd": self.pty.foreground_cwd(until),
                "published_at": _now(),
            },
        }

    def publish_initial_state(self, timeout: float = 30.0) -> None:
        """Make this endpoint reportable before anything is told it exists.

        This one raises where the heartbeat's publishes do not: a first state
        frame that never lands means startup has not finished, and startup is
        the one moment where giving up cleanly beats carrying on. A recovered
        registration sends the same frame for the same reason - an endpoint
        back in the fleet listing that answers "no state yet" has not really
        come back - and decides for itself what a failure there is worth, on
        the shorter clock it passes in: a recovery runs on the pty reader's own
        thread, and a reader parked on the hub is a worker blocked on writing
        to its own terminal.
        """
        self.hub.call("POST", "/v1/agent/frames",
                      {"machine": self.machine, "frames": [self.state_frame()]},
                      timeout=timeout)

    def state_loop(self) -> None:
        """Publish state on a heartbeat.

        The heartbeat IS the reachability signal: the hub measures how old the
        last state frame is, and refuses to give a verdict from a stale one. An
        agent that stops heartbeating makes its endpoint unreadable, never dead.
        """
        while not self.stop.wait(self.options.state_interval):
            # Building the frame runs ps against the pty, so a stood-down agent
            # must not reach it: it lives on for the worker's whole life, and
            # nothing it builds would be published anyway.
            if self.stood_down.is_set():
                continue
            self._post_frames([self.state_frame()])

    # --- commands ---------------------------------------------------------

    def apply_command(self, command: dict) -> tuple:
        kind = command.get("kind")
        payload = command.get("payload") or {}
        if kind == "input":
            data = b""
            text = payload.get("text")
            if text is not None:
                data += str(text).encode("utf-8")
            if payload.get("submit"):
                data += b"\r"
            for key in payload.get("keys") or []:
                data += KEYS.get(key, b"")
            if not data:
                return (False, "the input carried nothing to type")
            if not self.pty.alive():
                return (False, "the endpoint process has exited")
            try:
                self.pty.write(data)
            except OSError as exc:
                return (False, "writing to the pseudoterminal failed: %s" % exc)
            return (True, "")
        if kind == "kill":
            self.pty.close(str(payload.get("signal") or "TERM"))
            return (True, "")
        if kind == "status":
            # Lifecycle point 5. The write happens HERE, on the machine that
            # owns the record, so the path never crosses the network and a
            # worker on another machine reports exactly like a local one.
            try:
                append_status(self.status_path, str(payload.get("state") or ""),
                              str(payload.get("note") or ""))
            except (OSError, RuntimeError) as exc:
                return (False, str(exc))
            return (True, "")
        return (False, "unknown command kind %r" % kind)

    def give_up(self, reason: Exception) -> None:
        """Stand down: this name is another endpoint's now.

        Two records contesting one identity tell the hub nothing about which
        one holds the real work, and the safe move when that cannot be known is
        to go quiet. It is the ONLY answer an agent stands down on: everything
        else the hub can say, including a credential it will not take right
        now, is a condition that can end without anyone touching this worker,
        and an agent that gave up on those would strand the fleet the next time
        a hub came back wrong.

        Standing down is never stopping the worker. The pty stays exactly as it
        is - unsupervised, which is recoverable, rather than killed, which is
        not.

        Said once, because a stand-down is a state rather than an event and the
        publish path can reach it from several threads at once.
        """
        if self.stood_down.is_set():
            return
        self.stood_down.set()
        sys.stderr.write("fm-stream-agent: %s\n" % reason)
        sys.stderr.flush()

    def command_loop(self) -> None:
        """Long-poll the hub for this endpoint's commands and acknowledge each.

        The acknowledgement is what lets the hub tell a delivered input from one
        that merely sat in a queue, so a failure here is reported rather than
        swallowed.
        """
        path = ("/v1/agent/commands?machine=%s&endpoint=%s&wait=%d"
                % (urllib.parse.quote(self.machine), self.endpoint_id,
                   int(self.options.poll_secs)))
        while not self.stop.is_set():
            if self.stood_down.is_set():
                # Standing down means taking no commands, whichever path
                # reached it. A name this agent has lost and a hub that refuses
                # it both make anything typed through here an act by a worker
                # the fleet no longer believes is at this endpoint - and the
                # publish path can reach either verdict, so this is where the
                # loop notices rather than only where it raised.
                return
            # Cleared BEFORE the attempt, never before the wait below. A
            # recovery can land at any instant, and the only window in which
            # losing its signal would cost anything is between discovering this
            # poll has failed and giving up on waiting. Clearing here puts that
            # window ahead of the attempt instead of inside it: a recovery
            # during the call, or during the wait, is still set when the wait
            # looks. One that lands in the instant before the attempt is not
            # lost either, because the attempt it would have prompted is the
            # one about to be made.
            self._poll_wake.clear()
            try:
                answer = self.hub.call("GET", path, timeout=self.options.poll_secs + 15)
            except Superseded as exc:
                self.give_up(exc)
                return
            except RuntimeError as exc:
                # Back off rather than spin. A hub outage must not take the
                # worker down with it - the pty keeps running and this
                # reconnects - but an agent whose hub is gone for good would
                # otherwise poll a dead socket forever.
                sys.stderr.write("fm-stream-agent: command poll failed: %s\n" % exc)
                if not self._poll_wake.wait(self._backoff):
                    self._backoff = min(self._backoff * 2, POLL_BACKOFF_MAX)
                elif not self.stop.is_set():
                    # The endpoint is back. The wait this poll's own failure
                    # earned was sized by an outage that has ended, so serving
                    # the rest of it would leave the worker listed and healthy
                    # while a steer sent to it came back undelivered. Both the
                    # wait and the growth behind it end here.
                    self._backoff = POLL_BACKOFF_MIN
                continue
            self._backoff = POLL_BACKOFF_MIN
            for command in answer.get("commands") or []:
                self.command_busy.set()
                try:
                    ok, error = False, "the agent could not apply the command"
                    try:
                        ok, error = self.apply_command(command)
                    except Exception as exc:  # noqa: BLE001 - always answer the hub
                        ok, error = False, str(exc)
                    try:
                        self.hub.call("POST", "/v1/agent/results", {
                            "machine": self.machine,
                            "command_id": command.get("command_id"),
                            "ok": ok,
                            "error": error,
                        }, timeout=15.0)
                    except RuntimeError as exc:
                        sys.stderr.write("fm-stream-agent: could not acknowledge: %s\n" % exc)
                finally:
                    self.command_busy.clear()

    # --- lifecycle --------------------------------------------------------

    def run(self) -> int:
        reader = threading.Thread(target=self.read_loop, name="pty-reader", daemon=True)
        state = threading.Thread(target=self.state_loop, name="state", daemon=True)
        commands = threading.Thread(target=self.command_loop, name="commands", daemon=True)
        reader.start()
        state.start()
        commands.start()

        def _signalled(signum, frame) -> None:  # noqa: ARG001
            self.halt()
            self.pty.close()

        signal.signal(signal.SIGTERM, _signalled)
        signal.signal(signal.SIGINT, _signalled)

        self.stop.wait()
        # A kill is applied by the command loop and ends the endpoint, so the
        # reader sees EOF and sets stop while that same command is still being
        # acknowledged. Let the acknowledgement land before tearing down.
        deadline = _now() + 15.0
        while self.command_busy.is_set() and _now() < deadline:
            time.sleep(0.05)
        self.pty.close()
        # Join the reader before releasing the descriptor: see Pty.close.
        self.reader_done.wait(5.0)
        reader.join(timeout=5.0)
        self.pty.release()
        self._post_frames([{
            "endpoint_id": self.endpoint_id,
            "closed": True,
            "exit_code": self.pty.exit_code,
            "state": {"alive": False, "foreground": [], "cwd": "",
                      "published_at": _now()},
        }])
        return 0


# The key vocabulary firstmate's control plane actually permits, and nothing
# more. bin/fm-control-lib.sh is the owner of that set; a key with no adapter
# spelling would be unreachable through every firstmate path.
KEYS = {
    "Enter": b"\r",
    "Escape": b"\x1b",
    "C-c": b"\x03",
    "C-u": b"\x15",
}


# --- entry point ------------------------------------------------------------


def read_token(options: argparse.Namespace) -> str:
    if options.token_file:
        try:
            with open(options.token_file, "r", encoding="utf-8") as fh:
                token = fh.readline().strip()
        except OSError as exc:
            raise SystemExit("fm-stream-agent: cannot read --token-file %s: %s"
                             % (options.token_file, exc))
        if token:
            return token
    token = os.environ.get("FM_STREAM_TOKEN", "")
    if not token:
        raise SystemExit("fm-stream-agent: no publish token; pass --token-file or set "
                         "FM_STREAM_TOKEN. The agent never publishes unauthenticated.")
    return token


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=True, description="publish one pty to the hub")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--protocol", action="store_true")
    sub = parser.add_subparsers(dest="command")
    serve = sub.add_parser("serve")
    serve.add_argument("--hub", default=os.environ.get("FM_STREAM_HUB", ""))
    serve.add_argument("--token-file", default="")
    serve.add_argument("--machine", default="")
    serve.add_argument("--label", default="")
    serve.add_argument("--cwd", default="")
    serve.add_argument("--status-path", default="")
    serve.add_argument("--ready-file", default="")
    serve.add_argument("--rows", type=int, default=40)
    serve.add_argument("--cols", type=int, default=200)
    serve.add_argument("--state-interval", type=float, default=5.0)
    serve.add_argument("--poll-secs", type=float, default=25.0)
    return parser



def _abandon_startup(pty, hub, options, endpoint_id: str) -> None:
    """End a worker whose startup never reached readiness, record and all.

    The registration may have been recorded before startup ran out, which is
    the case this exists for, so the startup clock is put down before the close
    is posted: a budget that is spent by construction would otherwise refuse
    the one call that clears the record. A live endpoint nobody owns would
    refuse the next attempt at the same task with duplicate_label. The close
    gets a short timeout of its own so the abandonment still finishes well
    inside the window the spawn waits.

    The worker is killed outright rather than asked to leave: it never reached
    readiness, so it was never given work to finish, and an interactive shell
    ignores TERM - the grace period would be spent in full, every time, and is
    the whole margin this abandonment has left before the spawn is refused.
    """
    pty.close("KILL")
    pty.release()
    hub.end_startup()
    try:
        hub.call("POST", "/v1/agent/frames", {
            "machine": options.machine,
            "frames": [{"endpoint_id": endpoint_id, "closed": True, "exit_code": None}],
        }, timeout=2.0)
    except RuntimeError:
        pass

def main(argv: list) -> int:
    parser = build_parser()
    options = parser.parse_args(argv)
    # Remember whether the operator pinned the heartbeat, so deriving it from
    # the hub below never overrides an explicit choice.
    options.state_interval_explicit = any(
        a == "--state-interval" or a.startswith("--state-interval=") for a in argv)
    if options.version:
        print(AGENT_VERSION)
        return 0
    if options.protocol:
        print(AGENT_PROTOCOL)
        return 0
    if options.command != "serve":
        parser.print_help()
        return 2

    if not options.hub:
        raise SystemExit("fm-stream-agent: --hub is required (or set FM_STREAM_HUB)")
    if not options.machine:
        options.machine = re.sub(r"[^A-Za-z0-9._-]", "-", socket.gethostname() or "unknown")
    if not MACHINE_RE.match(options.machine):
        raise SystemExit("fm-stream-agent: --machine must be 1-128 characters of [A-Za-z0-9._-]")
    if not options.label:
        raise SystemExit("fm-stream-agent: --label is required")
    if not options.cwd or not os.path.isabs(options.cwd):
        raise SystemExit("fm-stream-agent: --cwd must be an absolute path")
    if not os.path.isdir(options.cwd):
        raise SystemExit("fm-stream-agent: --cwd %s is not a directory" % options.cwd)
    if options.status_path and not os.path.isabs(options.status_path):
        raise SystemExit("fm-stream-agent: --status-path must be absolute")

    command = _default_shell_command()

    hub = HubClient(options.hub, read_token(options))
    hub.begin_startup()
    health = hub.call("GET", "/v1/health")
    protocol = health.get("protocol")
    if protocol != AGENT_PROTOCOL:
        raise SystemExit("fm-stream-agent: the hub at %s speaks protocol %r but this agent "
                         "implements %d; update both ends"
                         % (options.hub, protocol, AGENT_PROTOCOL))

    # The heartbeat is what keeps this endpoint readable, so it is derived from
    # the hub's own staleness window rather than configured separately. Two
    # independent numbers that have to line up eventually will not, and the
    # failure is silent and total: every endpoint reads stale, so supervision
    # refuses every verdict on a fleet that is working perfectly.
    if not options.state_interval_explicit:
        hub_max_age = health.get("state_max_age_secs")
        try:
            hub_max_age = float(hub_max_age)
        except (TypeError, ValueError):
            hub_max_age = 0.0
        if hub_max_age > 0:
            options.state_interval = max(0.5, min(options.state_interval, hub_max_age / 3.0))

    endpoint_id = os.urandom(16).hex()
    env = dict(os.environ)
    env["FM_STREAM_ENDPOINT_ID"] = endpoint_id
    env["FM_STREAM_HUB"] = options.hub
    env.pop("FM_STREAM_TOKEN", None)
    env.setdefault("TERM", "xterm-256color")

    pty = Pty(options.cwd, command, options.rows, options.cols, env)
    # An endpoint whose process is already gone must never be registered: the
    # spawn would record a task against a corpse and every later steer would
    # address nothing. The command's own output is the reason it failed.
    if pty.exited_within(0.4):
        detail = pty.read().decode("utf-8", "replace").strip().splitlines()
        pty.release()
        raise SystemExit("fm-stream-agent: %s exited immediately (status %s): %s"
                         % (command[0], pty.exit_code,
                            detail[-1] if detail else "no output"))

    try:
        hub.call("POST", "/v1/agent/endpoints", registration(options, endpoint_id))
        agent = Agent(options, hub, pty, endpoint_id)
        # Publish the first state frame BEFORE announcing readiness. The ready
        # file is what a spawn waits on, and the very next thing it may do is
        # ask how this endpoint is doing - which would otherwise be answered
        # "no state frame yet", i.e. unreadable, for a worker that is fine.
        agent.publish_initial_state()
    except Superseded as exc:
        # Standing down protects work in progress, and there is none here: the
        # spawn has not returned, nothing has been asked of this worker, and
        # firstmate has never learned the task exists. Leaving the pty alive
        # would leak a process nobody supervises and nobody can find, so this
        # loser stops its worker where a mid-task loser would not.
        _abandon_startup(pty, hub, options, endpoint_id)
        raise SystemExit("fm-stream-agent: %s" % exc)
    except RuntimeError as exc:
        _abandon_startup(pty, hub, options, endpoint_id)
        raise SystemExit("fm-stream-agent: %s" % exc)

    if options.ready_file:
        with open(options.ready_file, "w", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (options.machine, endpoint_id))
    sys.stderr.write("fm-stream-agent %s endpoint %s on %s -> %s\n"
                     % (AGENT_VERSION, endpoint_id, options.machine, options.hub))
    sys.stderr.flush()
    # The caller's capture of this agent's output exists to carry a refusal out
    # of a spawn that never registered. Registration succeeded, so the caller
    # has already unlinked it, and everything written from here - one line per
    # failed publish, for the worker's whole life - would only grow a file
    # nobody can read.
    _silence_diagnostics()
    hub.end_startup()

    return agent.run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
