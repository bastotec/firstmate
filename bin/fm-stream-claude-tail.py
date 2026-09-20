#!/usr/bin/env python3
"""fm-stream-claude-tail.py - publish Claude Code transcript usage to the stream hub.

A Claude Code worker that firstmate did not launch through the `stream`
backend is invisible to the fleet hub. Claude Code does write a continuously
updated JSONL transcript under ~/.claude/projects/<slug>/, with assistant
messages carrying the API answer's token usage. This observability-only shim
follows that project directory and publishes its cumulative usage as one hub
endpoint. It does not own, steer, stop, or make liveness claims about the
worker.

The shim follows the newest session file by modification time. A new session
id, resume, or compaction is adopted during the run. Assistant records are
deduplicated by message id across files because streamed blocks repeat usage
and resumed sessions copy prior messages. For one id, each counter takes the
largest value seen so a usage record that grows is counted once at its final
size. A file that shrinks is read again from the beginning, with message-id
deduplication keeping the cumulative totals monotonic.

The shared publisher in bin/fm_stream_tail_lib.py owns registration, state
sequencing, hub-restart re-registration, and supersession. The endpoint id is
created once and retained across hub restarts. If another endpoint takes the
same machine and label, this shim stands down with exit status 3. Stopping the
shim publishes no closing frame because observer exit is not evidence that the
observed Claude worker stopped.

Commands:

  fm-stream-claude-tail.py serve [options]     follow and publish one project
  fm-stream-claude-tail.py --protocol          print the hub protocol it speaks
  fm-stream-claude-tail.py --version           print the shim version

serve options:

  --project-dir DIR      a projects/<slug> directory; follow its newest JSONL
  --label NAME           the leaf's label, as the fleet spells the task
  --hub URL              hub base URL. Resolved, when omitted, from
                         FM_STREAM_HUB, config/stream-hub under FM_HOME, a hub
                         this home started, then http://127.0.0.1:7717
  --token-file PATH      file whose first non-empty line is a publish token.
                         Otherwise FM_STREAM_TOKEN, then config/stream-token
                         under FM_HOME
  --machine NAME         this machine's fleet name. Otherwise
                         FM_STREAM_MACHINE, config/stream-machine under
                         FM_HOME, then the hostname
  --cwd DIR              directory recorded on the endpoint (default: project)
  --heartbeat-secs N     idle republish cadence (default 5, capped at the
                         hub's staleness window / 3 unless explicit)
  --poll-secs N          transcript poll interval (default 0.5)
  --ready-file PATH      write "<machine> <endpoint-id>" once registered

Exit status: 0 on success, 2 on a usage or configuration error, 3 when another
endpoint holds this machine and label, and 1 otherwise.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import signal
import socket
import sys
import threading
import time

import fm_stream_tail_lib as tail

SHIM_VERSION = "1.0.0"
HUB_PROTOCOL = 2
LABEL_RE = re.compile(r"\A[A-Za-z0-9._@%+-]{1,128}\Z")
DEFAULT_HUB_URL = "http://127.0.0.1:7717"

TOKEN_FIELDS = (
    ("input", "input_tokens"),
    ("output", "output_tokens"),
    ("cache_creation", "cache_creation_input_tokens"),
    ("cache_read", "cache_read_input_tokens"),
)


class Counters:
    """Cumulative token usage over unique assistant message ids."""

    def __init__(self) -> None:
        self.totals = {name: 0 for name, _ in TOKEN_FIELDS}
        self.messages = 0
        self._per_message: dict = {}

    def feed(self, message_id: str, usage: dict) -> bool:
        known = self._per_message.get(message_id)
        if known is None:
            self.messages += 1
            known = {name: 0 for name, _ in TOKEN_FIELDS}
            self._per_message[message_id] = known
        changed = False
        for name, field in TOKEN_FIELDS:
            value = usage.get(field)
            if (isinstance(value, int) and not isinstance(value, bool)
                    and value > known[name]):
                self.totals[name] += value - known[name]
                known[name] = value
                changed = True
        return changed

    def snapshot(self) -> dict:
        return {
            "tokens": dict(self.totals),
            "messages": self.messages,
        }


def usage_from_line(record: object):
    if not isinstance(record, dict) or record.get("type") != "assistant":
        return None
    message = record.get("message")
    if not isinstance(message, dict):
        return None
    message_id = message.get("id")
    usage = message.get("usage")
    if not isinstance(message_id, str) or not message_id:
        return None
    if not isinstance(usage, dict):
        return None
    return (message_id, usage)


class TranscriptFile:
    """One JSONL file followed incrementally from its last complete line."""

    def __init__(self, path: str) -> None:
        self.path = path
        self.offset = 0

    def poll(self, counters: Counters) -> bool:
        try:
            size = os.stat(self.path).st_size
        except OSError:
            return False
        if size < self.offset:
            self.offset = 0
        if size == self.offset:
            return False
        try:
            with open(self.path, "rb") as handle:
                handle.seek(self.offset)
                data = handle.read()
        except OSError:
            return False
        last_newline = data.rfind(b"\n")
        if last_newline < 0:
            return False
        chunk = data[:last_newline + 1]
        self.offset += last_newline + 1
        changed = False
        for line in chunk.splitlines():
            if not line.strip():
                continue
            try:
                record = json.loads(line.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            found = usage_from_line(record)
            if found is not None and counters.feed(*found):
                changed = True
        return changed


class TranscriptSource:
    """The newest JSONL session in one Claude project directory."""

    def __init__(self, project_dir: str) -> None:
        self.project_dir = project_dir
        self._current = None
        newest = self._newest_session()
        if newest is not None:
            self._current = TranscriptFile(newest[1])

    def _newest_session(self):
        try:
            names = os.listdir(self.project_dir)
        except OSError:
            return None
        best = None
        for name in names:
            if not name.endswith(".jsonl"):
                continue
            path = os.path.join(self.project_dir, name)
            try:
                mtime = os.stat(path).st_mtime
            except OSError:
                continue
            if best is None or mtime > best[0]:
                best = (mtime, path)
        return best

    def followed_path(self) -> str:
        return self._current.path if self._current is not None else ""

    def poll(self, counters: Counters) -> bool:
        newest = self._newest_session()
        if newest is not None and newest[1] != self.followed_path():
            try:
                current_mtime = os.stat(self.followed_path()).st_mtime
            except OSError:
                current_mtime = 0.0
            if newest[0] > current_mtime:
                self._current = TranscriptFile(newest[1])
        if self._current is None:
            return False
        return self._current.poll(counters)


def home_root() -> str:
    home = os.environ.get("FM_HOME", "")
    if home:
        return home
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def fail_usage(message: str) -> None:
    sys.stderr.write(message + "\n")
    raise SystemExit(2)


def config_line(name: str) -> str:
    path = os.path.join(home_root(), "config", name)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line and not line.startswith("#"):
                    return line
    except OSError:
        pass
    return ""


def read_token_file(path: str) -> str:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    return line
    except OSError as exc:
        fail_usage("fm-stream-claude-tail: cannot read --token-file %s: %s"
                   % (path, exc))
    fail_usage("fm-stream-claude-tail: the token file %s holds no token" % path)


def resolve_hub(explicit: str) -> str:
    url = explicit or os.environ.get("FM_STREAM_HUB", "") or config_line("stream-hub")
    if not url:
        ready = os.path.join(home_root(), "state", ".stream-hub.ready")
        try:
            with open(ready, "r", encoding="utf-8") as handle:
                parts = handle.read().split()
            if len(parts) >= 2:
                url = "http://%s:%s" % (parts[0], parts[1])
        except OSError:
            pass
    if not url:
        url = DEFAULT_HUB_URL
    if not url.startswith(("http://", "https://")):
        fail_usage("fm-stream-claude-tail: hub URL %r must start with http:// or https://"
                   % url)
    return url.rstrip("/")


def resolve_token(explicit_file: str) -> str:
    if explicit_file:
        return read_token_file(explicit_file)
    token = os.environ.get("FM_STREAM_TOKEN", "") or config_line("stream-token")
    if token:
        return token
    fail_usage("fm-stream-claude-tail: no publish token; pass --token-file, set "
               "FM_STREAM_TOKEN, or write config/stream-token under FM_HOME")


def resolve_machine(explicit: str) -> str:
    name = (explicit or os.environ.get("FM_STREAM_MACHINE", "")
            or config_line("stream-machine") or socket.gethostname() or "unknown")
    name = re.sub(r"[^A-Za-z0-9._-]", "-", name)
    if not tail.MACHINE_RE.match(name):
        fail_usage("fm-stream-claude-tail: --machine must be 1-128 characters of "
                   "[A-Za-z0-9._-]")
    return name


def build_source(project_dir: str) -> TranscriptSource:
    if not project_dir:
        fail_usage("fm-stream-claude-tail: --project-dir is required for serve")
    if not os.path.isdir(project_dir):
        fail_usage("fm-stream-claude-tail: --project-dir %s is not a directory"
                   % project_dir)
    source = TranscriptSource(project_dir)
    if not source.followed_path():
        fail_usage("fm-stream-claude-tail: no session transcript (*.jsonl) in %s"
                   % project_dir)
    return source


def claude_state(payload: dict) -> dict:
    return {
        "foreground": [],
        "tokens": payload["tokens"],
        "messages": payload["messages"],
    }


def cmd_serve(options: argparse.Namespace) -> int:
    source = build_source(options.project_dir)
    if not LABEL_RE.match(options.label):
        fail_usage("fm-stream-claude-tail: --label must be 1-128 characters of "
                   "[A-Za-z0-9._@%+-]")
    options.machine = resolve_machine(options.machine)
    options.cwd = options.cwd or os.path.abspath(options.project_dir)
    if not os.path.isabs(options.cwd):
        fail_usage("fm-stream-claude-tail: --cwd must be an absolute path")

    hub = tail.HubClient(resolve_hub(options.hub), resolve_token(options.token_file),
                         "fm-stream-claude-tail")
    publisher = tail.TailPublisher(
        hub, options.machine, options.label, options.cwd, os.urandom(16).hex(),
        "claude", rows=1, cols=1, program="fm-stream-claude-tail",
        state_adapter=claude_state)
    try:
        health = publisher.check_protocol(HUB_PROTOCOL)
        options.heartbeat_secs = publisher.derive_state_interval(
            health, options.heartbeat_secs, options.heartbeat_explicit)
        publisher.register()
    except tail.Superseded:
        raise
    except RuntimeError as exc:
        raise SystemExit("fm-stream-claude-tail: %s" % exc)

    counters = Counters()
    source.poll(counters)
    publisher.publish(True, counters.snapshot())
    if publisher.stood_down.is_set():
        return 3

    if options.ready_file:
        try:
            with open(options.ready_file, "w", encoding="utf-8") as handle:
                handle.write("%s %s\n" % (options.machine, publisher.endpoint_id))
        except OSError as exc:
            raise SystemExit("fm-stream-claude-tail: cannot write --ready-file %s: %s"
                             % (options.ready_file, exc))

    sys.stderr.write("fm-stream-claude-tail %s endpoint %s following %s -> %s\n"
                     % (SHIM_VERSION, publisher.endpoint_id,
                        source.followed_path(), hub.base_url))
    sys.stderr.flush()

    stop = threading.Event()

    def _signalled(signum, frame) -> None:  # noqa: ARG001
        stop.set()

    signal.signal(signal.SIGTERM, _signalled)
    signal.signal(signal.SIGINT, _signalled)

    last_publish = time.monotonic()
    while not stop.is_set():
        changed = source.poll(counters)
        now = time.monotonic()
        if changed or now - last_publish >= options.heartbeat_secs:
            if publisher.publish(True, counters.snapshot()):
                last_publish = time.monotonic()
            if publisher.stood_down.is_set():
                return 3
        sleep_for = options.poll_secs
        until_heartbeat = options.heartbeat_secs - (time.monotonic() - last_publish)
        if until_heartbeat > 0:
            sleep_for = min(sleep_for, until_heartbeat)
        else:
            sleep_for = min(sleep_for, 0.05)
        stop.wait(max(0.02, sleep_for))
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-stream-claude-tail.py",
        description="publish Claude Code transcript usage to the stream hub")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--protocol", action="store_true")
    commands = parser.add_subparsers(dest="command")
    serve = commands.add_parser("serve", help="follow one project and publish")
    serve.add_argument("--project-dir", default="",
                       help="projects/<slug> directory; follow the newest session")
    serve.add_argument("--label", default="", help="the leaf's label in the fleet")
    serve.add_argument("--hub", default="", help="hub base URL")
    serve.add_argument("--token-file", default="", help="publish-class token file")
    serve.add_argument("--machine", default="", help="this machine's fleet name")
    serve.add_argument("--cwd", default="", help="directory recorded on the endpoint")
    serve.add_argument("--heartbeat-secs", type=float, default=5.0,
                       help="idle republish cadence (default 5)")
    serve.add_argument("--poll-secs", type=float, default=0.5,
                       help="transcript poll interval (default 0.5)")
    serve.add_argument("--ready-file", default="",
                       help="write '<machine> <endpoint-id>' once registered")
    return parser


def main(argv: list) -> int:
    parser = build_parser()
    options = parser.parse_args(argv)
    if options.version:
        print(SHIM_VERSION)
        return 0
    if options.protocol:
        print(HUB_PROTOCOL)
        return 0
    if options.command != "serve":
        parser.print_help(sys.stderr)
        return 2
    if not options.label:
        fail_usage("fm-stream-claude-tail: --label is required for serve")
    if options.poll_secs <= 0:
        fail_usage("fm-stream-claude-tail: --poll-secs must be positive")
    if options.heartbeat_secs <= 0:
        fail_usage("fm-stream-claude-tail: --heartbeat-secs must be positive")
    options.heartbeat_explicit = any(
        arg == "--heartbeat-secs" or arg.startswith("--heartbeat-secs=")
        for arg in argv)
    try:
        return cmd_serve(options)
    except tail.Superseded as exc:
        sys.stderr.write("fm-stream-claude-tail: %s\n" % exc)
        return 3


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
