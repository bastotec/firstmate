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

Commands:

  fm-stream-agent.py serve [options] -- <command...>   own a pty and publish it
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

AGENT_VERSION = "2.0.0"
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


def _process_cwd(pid: str) -> str:
    try:
        return os.readlink("/proc/%s/cwd" % pid)
    except OSError:
        pass
    try:
        proc = subprocess.run(
            ["lsof", "-a", "-p", pid, "-d", "cwd", "-Fn"],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env={"LC_ALL": "C", "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
    except OSError:
        return ""
    for line in proc.stdout.decode("utf-8", "replace").splitlines():
        if line.startswith("n/"):
            return line[1:]
    return ""


def _ps_args(pid: str) -> str:
    try:
        proc = subprocess.run(
            ["ps", "-p", pid, "-o", "args="],
            check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            env={"LC_ALL": "C", "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
    except OSError:
        return ""
    return proc.stdout.decode("utf-8", "replace").strip()


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

    def foreground_processes(self) -> list:
        """The pty's foreground process group, as identity records.

        Scoped to the foreground group rather than every descendant, for the
        same reason the tmux adapter is: a harness-named process left running in
        the background of an otherwise idle endpoint must not read as a live
        agent.
        """
        tty = self.slave_name
        if tty.startswith("/dev/"):
            tty = tty[len("/dev/"):]
        try:
            proc = subprocess.run(
                ["ps", "-t", tty, "-o", "pid=,pgid=,tpgid=,comm="],
                check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                env={"LC_ALL": "C", "PATH": os.environ.get("PATH", "/usr/bin:/bin")})
        except OSError:
            return []
        out = []
        for line in proc.stdout.decode("utf-8", "replace").splitlines():
            fields = line.split(None, 3)
            if len(fields) < 4:
                continue
            pid, pgid, tpgid, comm = fields
            if pgid != tpgid:
                continue
            args = _ps_args(pid)
            argv0 = args.strip().split(" ", 1)[0] if args else ""
            out.append({"pid": pid, "name": comm, "argv0": argv0, "args": args})
        return out

    def foreground_cwd(self) -> str:
        """The working directory of the endpoint's INNERMOST foreground process.

        Innermost first, with the endpoint's own shell as the last resort. The
        order matters: reading the shell first would answer with the shell's
        directory whenever a foreground process had chdir'd elsewhere, which is
        the one case the caller is asking about.
        """
        for entry in reversed(self.foreground_processes()):
            cwd = _process_cwd(entry["pid"])
            if cwd:
                return cwd
        return _process_cwd(str(self.pid))

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


class HubClient:
    """Outbound-only authenticated calls to the fleet's hub.

    Nothing here assumes a scheme: the hub URL is used exactly as configured, so
    putting a TLS terminator in front of the hub is a deployment change and
    needs no change in this file.
    """

    def __init__(self, base_url: str, token: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, payload=None, timeout: float = 30.0):
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
            raise RuntimeError("hub refused %s %s: %s"
                               % (method, path, parsed.get("message") or exc.code))
        except urllib.error.URLError as exc:
            raise RuntimeError("cannot reach the hub at %s: %s" % (self.base_url, exc.reason))
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
        self._backoff = 2.0

    # --- publishing -------------------------------------------------------

    def _post_frames(self, frames: list) -> None:
        try:
            self.hub.call("POST", "/v1/agent/frames",
                          {"machine": self.machine, "frames": frames}, timeout=30.0)
        except RuntimeError as exc:
            # A hub that cannot be reached must not take the worker down with
            # it: the pty keeps running and the next frame retries. The output
            # that could not be published is lost from the hub's ring, which is
            # a bounded history by design, not a transcript of record.
            sys.stderr.write("fm-stream-agent: publish failed: %s\n" % exc)

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
            self.stop.set()

    def state_frame(self) -> dict:
        return {
            "endpoint_id": self.endpoint_id,
            "state": {
                "alive": self.pty.alive(),
                "foreground": self.pty.foreground_processes(),
                "cwd": self.pty.foreground_cwd(),
                "published_at": _now(),
            },
        }

    def publish_initial_state(self) -> None:
        """Make this endpoint reportable before anything is told it exists."""
        self._post_frames([self.state_frame()])

    def state_loop(self) -> None:
        """Publish state on a heartbeat.

        The heartbeat IS the reachability signal: the hub measures how old the
        last state frame is, and refuses to give a verdict from a stale one. An
        agent that stops heartbeating makes its endpoint unreadable, never dead.
        """
        while not self.stop.wait(self.options.state_interval):
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
            try:
                answer = self.hub.call("GET", path, timeout=self.options.poll_secs + 15)
            except RuntimeError as exc:
                # Back off rather than spin. A hub outage must not take the
                # worker down with it - the pty keeps running and this
                # reconnects - but an agent whose hub is gone for good would
                # otherwise poll a dead socket forever.
                sys.stderr.write("fm-stream-agent: command poll failed: %s\n" % exc)
                self.stop.wait(self._backoff)
                self._backoff = min(self._backoff * 2, 60.0)
                continue
            self._backoff = 2.0
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
            self.stop.set()
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
    serve.add_argument("argv", nargs=argparse.REMAINDER)
    return parser


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

    command = [a for a in (options.argv or []) if a != "--"]
    if not command:
        command = _default_shell_command()

    hub = HubClient(options.hub, read_token(options))
    health = hub.call("GET", "/v1/health", timeout=15.0)
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
        hub.call("POST", "/v1/agent/endpoints", {
            "endpoint_id": endpoint_id,
            "machine": options.machine,
            "label": options.label,
            "cwd": options.cwd,
            "rows": options.rows,
            "cols": options.cols,
        }, timeout=15.0)
    except RuntimeError as exc:
        pty.close()
        pty.release()
        raise SystemExit("fm-stream-agent: %s" % exc)

    agent = Agent(options, hub, pty, endpoint_id)
    # Publish the first state frame BEFORE announcing readiness. The ready file
    # is what a spawn waits on, and the very next thing it may do is ask how
    # this endpoint is doing - which would otherwise be answered "no state frame
    # yet", i.e. unreadable, for a worker that is in fact perfectly fine.
    agent.publish_initial_state()

    if options.ready_file:
        with open(options.ready_file, "w", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (options.machine, endpoint_id))
    sys.stderr.write("fm-stream-agent %s endpoint %s on %s -> %s\n"
                     % (AGENT_VERSION, endpoint_id, options.machine, options.hub))
    sys.stderr.flush()

    return agent.run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
