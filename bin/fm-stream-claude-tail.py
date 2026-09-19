#!/usr/bin/env python3
"""fm-stream-claude-tail.py - publish a Claude Code session transcript's token usage to the stream hub.

A Claude Code worker that firstmate did not launch through the `stream`
backend is invisible to the fleet's hub (bin/fm-stream-hub.py): no agent
owns its pseudoterminal, so nothing registers it and the Bridge feed -
built from the hub's task listing by bin/fm-stream-bridge.py - shows
nothing for it.  Claude Code itself, though, writes a continuously-updating
session transcript: the JSONL under ~/.claude/projects/<slug>/ that grows
as the session streams, one JSON object per line, with every assistant
message carrying the API answer's token usage.

This shim is the join.  It tails that transcript and publishes to the hub
exactly the way the per-endpoint agent (bin/fm-stream-agent.py) does: it
registers one endpoint under a machine/label identity, then publishes
state frames carrying cumulative token counters.  It owns no pseudoterminal
and no process - the worker it shadows is not launched, steered, or touched
by it - so it is observability only.  docs/stream-backend.md owns the hub's
protocol, security, and limits; this header owns what the shim adds.

What it publishes, and the rules that keep those numbers honest:

  * Identity.  One shim is one hub endpoint: machine + label, exactly the
    two fields a leaf is listed under, so "<machine>/<label>" is the Bridge
    leaf id.  The endpoint id is random 32-hex at startup and held for the
    shim's whole life, so a hub restart is answered by re-registering the
    SAME id - the rejoin behaviour bin/fm-stream-agent.py implements - and
    the worker reappears in the fleet listing rather than as a stranger.
  * Cumulative counters, from real records only.  Assistant messages in the
    transcript carry usage objects (input_tokens, output_tokens,
    cache_creation_input_tokens, cache_read_input_tokens).  The counters are
    the sum over UNIQUE assistant messages: Claude Code appends several
    lines per API answer (one per streamed block) all carrying the message
    id and the same usage, and a resumed session rewrites prior messages
    into a new session file, so anything but id-deduplication would
    multiply-count.  For one id the counters take the LARGEST value seen,
    so a partially written usage line that grows on its next append counts
    once, at its final size.  A heartbeat never moves a counter: when the
    transcript is idle the shim republishes the same cumulative numbers on
    its heartbeat cadence, and counters move only when a real record does.
  * Sequence.  Every published state frame carries "seq", a strictly
    increasing per-process counter, so a reader can tell a fresh frame from
    a replayed one however the frame reached them.
  * Rotation.  Given --project-dir (the ~/.claude/projects/<slug> directory)
    the shim follows the NEWEST session file by modification time, so a new
    session id - a fresh session, a resume, a compaction - is picked up
    mid-run and its usage accumulates onto the same leaf's counters, with
    the id set absorbing the history a resume copies in.  Given
    --transcript it follows that one file.  A file that shrinks is re-read
    from the start; the id set makes that idempotent.

The state frame's shape rides the hub's own state contract (the hub stores
the last state frame verbatim): "alive" is true while the shim is running,
"foreground" and "cwd" are empty because the shim owns no process, and
"tokens" plus "messages" carry the cumulative usage.  No output frames are
ever published, so the endpoint's screen and ring stay empty.

Commands:

  fm-stream-claude-tail.py serve [options]     tail a transcript and publish
  fm-stream-claude-tail.py summarize [opts]    print one transcript's counters
  fm-stream-claude-tail.py --protocol          print the hub protocol it speaks
  fm-stream-claude-tail.py --version           print the shim version

serve options:

  --transcript PATH      one session JSONL to follow (exclusive with
                         --project-dir)
  --project-dir DIR      the projects/<slug> directory; follow the newest
                         session file and rotate with new session ids
  --label NAME           the leaf's label, as the fleet spells the task
  --hub URL              hub base URL.  Resolved, when not passed, the way
                         bin/fm-stream.sh resolves it: FM_STREAM_HUB, then
                         config/stream-hub under FM_HOME, then a hub this
                         home started itself, then http://127.0.0.1:7717
  --token-file PATH      file whose first line is a publish-class token.
                         Otherwise FM_STREAM_TOKEN, then config/stream-token
                         under FM_HOME.  It never publishes unauthenticated.
  --machine NAME         this machine's name in the fleet.  Otherwise
                         FM_STREAM_MACHINE, then config/stream-machine under
                         FM_HOME, then the hostname
  --cwd DIR              the directory recorded on the endpoint (default:
                         the transcript's own directory)
  --heartbeat-secs N     republish cadence when idle (default 5, capped at
                         the hub's staleness window / 3 unless explicit)
  --poll-secs N          how often the transcript is checked for new lines
                         (default 0.5)
  --ready-file PATH      write "<machine> <endpoint-id>" once registered
  --state-file PATH      write the last published state frame there, so the
                         numbers are observable without the hub

summarize takes --transcript or --project-dir and prints the cumulative
counters as JSON on stdout, computing exactly what serve would publish for
the same input: every complete line of the file (or of every session file
in the directory), deduplicated by assistant message id.

Exit status: 0 on success, 2 on a usage or configuration error, 3 when the
hub says another endpoint holds this machine and label (the shim stands
down; there is no worker behind it to keep alive), 1 otherwise.  SIGTERM
and SIGINT close the endpoint out with an agent-attributed close, exactly
like the per-endpoint agent, so the Bridge renders the leaf Stopped rather
than aging it out stale.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import signal
import socket
import sys
import threading
import time
import urllib.error
import urllib.request

SHIM_VERSION = "1.0.0"

# The hub wire protocol this shim speaks. Anything else is refused rather
# than driven on guessed routes, exactly like the agent and the adapter.
HUB_PROTOCOL = 2

MACHINE_RE = re.compile(r"\A[A-Za-z0-9._-]{1,128}\Z")
LABEL_RE = re.compile(r"\A[A-Za-z0-9._@%+-]{1,128}\Z")
DEFAULT_HUB_URL = "http://127.0.0.1:7717"

# The transcript's usage fields, and the counter names they are published
# under. Nothing outside this mapping is counted, so a new field Claude Code
# adds to the usage object is ignored rather than half-parsed.
TOKEN_FIELDS = (
    ("input", "input_tokens"),
    ("output", "output_tokens"),
    ("cache_creation", "cache_creation_input_tokens"),
    ("cache_read", "cache_read_input_tokens"),
)

# Re-registration pacing, mirroring the agent's ladder and for the same
# reasons: a hub restart strands every publisher at once, so attempts are
# spaced, backed off while the hub cannot take them, and jittered so the
# fleet does not return as one burst against a hub that only just came up.
REREGISTER_BACKOFF_MIN = 2.0
REREGISTER_BACKOFF_MAX = 60.0
REREGISTER_JITTER = 0.25

# How long a failed publish holds back the next attempt against a hub that
# is not answering. A dead hub would otherwise be retried on every idle
# heartbeat for the shim's whole life.
PUBLISH_BACKOFF_MIN = 2.0
PUBLISH_BACKOFF_MAX = 60.0

HTTP_TIMEOUT = 30.0


def _now() -> float:
    return time.time()


# --- transcript parsing ------------------------------------------------------


class Counters:
    """Cumulative token usage over unique assistant messages.

    Two transcript behaviours make naive summation wrong, and both are
    load-bearing here:

      * Claude Code appends one line per streamed block, all carrying the
        same message id and the same usage, so a session's real usage is
        the sum over unique ids, not over lines.
      * A resumed or continued session rewrites prior messages into the new
        session file under their original ids, so an id seen before is not
        new usage no matter which file it appears in.

    For one id the per-field counters take the LARGEST value seen: usage is
    a property of the finished API answer, and a line appended mid-stream
    can only grow into it.
    """

    def __init__(self) -> None:
        self.totals = {name: 0 for name, _ in TOKEN_FIELDS}
        self.messages = 0
        self._per_message: dict = {}

    def feed(self, message_id: str, usage: dict) -> bool:
        """Count one assistant message's usage. True when a total moved."""
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
        return dict(self.totals)


def usage_from_line(record: object) -> tuple:
    """One parsed JSONL record -> (message id, usage dict) or None.

    Only assistant messages carry usage. Anything else - user turns, mode
    markers, file-history snapshots, records yet to grow a field - is not
    usage and is skipped rather than guessed at.
    """
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
    """One session JSONL, followed incrementally from the last read offset.

    A line is counted only once its terminating newline has arrived, so a
    record Claude Code is writing right now is neither misparsed nor
    half-counted.  A file that shrank beneath the offset - rewritten,
    rotated in place, or simply replaced - is re-read from the start; the
    message-id set makes the re-read count nothing twice.
    """

    def __init__(self, path: str) -> None:
        self.path = path
        self.offset = 0

    def poll(self, counters: Counters) -> bool:
        """Read new complete lines. True when any counter moved."""
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
        # The bytes after the last newline are a record still being written,
        # so the offset advances only past COMPLETE lines: held-back bytes
        # stay unread, and the newline that completes them brings the whole
        # line back on the next poll.
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
    """The transcript a shim follows: one file, or a session directory.

    Directory mode is the rotation rule. Claude Code gives a new session id
    its own file in the same project directory, so the newest session file
    by modification time is the live session: the shim switches to it when
    it becomes newer than the one followed, and the counters keep
    accumulating on the same leaf - the message-id set absorbs the history
    a resume copies into the new file, so nothing is counted twice.
    """

    def __init__(self, transcript: str = "", project_dir: str = "") -> None:
        self.transcript = transcript
        self.project_dir = project_dir
        self._current: TranscriptFile = None  # type: ignore[assignment]
        if transcript:
            self._current = TranscriptFile(transcript)
        else:
            newest = self._newest_session()
            if newest is not None:
                self._adopt(newest[1])

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

    def _adopt(self, path: str) -> None:
        self._current = TranscriptFile(path)

    def followed_path(self) -> str:
        return self._current.path if self._current is not None else ""

    def poll(self, counters: Counters) -> bool:
        if self.project_dir:
            newest = self._newest_session()
            if newest is not None and newest[1] != self.followed_path():
                try:
                    current_mtime = os.stat(self.followed_path()).st_mtime
                except OSError:
                    current_mtime = 0.0
                if newest[0] > current_mtime:
                    self._adopt(newest[1])
        if self._current is None:
            return False
        return self._current.poll(counters)


# --- hub access --------------------------------------------------------------


class Superseded(RuntimeError):
    """Another live endpoint holds this machine and label.

    There is no coming back from this one, and - unlike the agent, which
    keeps the worker's pseudoterminal alive - this shim has nothing behind
    it to protect, so it reports and exits rather than standing down in
    place.
    """


class Forgotten(RuntimeError):
    """The hub has no record of this endpoint, so the shim takes it back.

    A restarted hub has never heard of any endpoint it served, and this is
    the one refusal a re-registration answers. Silence from an unreachable
    hub is not it, and never acts as it.
    """


SUPERSEDING_REFUSALS = frozenset(("endpoint_superseded", "duplicate_label"))


class HubClient:
    """Outbound authenticated calls to the fleet's hub, as the agent makes them."""

    def __init__(self, base_url: str, token: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token

    def call(self, method: str, path: str, payload=None, timeout: float = HTTP_TIMEOUT):
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
        except (urllib.error.URLError, OSError, ValueError) as exc:
            reason = getattr(exc, "reason", exc)
            raise RuntimeError("cannot reach the hub at %s: %s"
                               % (self.base_url, reason))
        if not body:
            return {}
        try:
            return json.loads(body)
        except json.JSONDecodeError as exc:
            raise RuntimeError("hub returned malformed JSON for %s %s: %s"
                               % (method, path, exc))


# --- configuration resolution -------------------------------------------------


def home_root() -> str:
    home = os.environ.get("FM_HOME", "")
    if home:
        return home
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def config_line(name: str) -> str:
    """The first non-empty line of <home>/config/<name>, or empty."""
    path = os.path.join(home_root(), "config", name)
    try:
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
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
        raise SystemExit("fm-stream-claude-tail: cannot read --token-file %s: %s"
                         % (path, exc))
    raise SystemExit("fm-stream-claude-tail: the token file %s holds no token" % path)


def resolve_hub(explicit: str) -> str:
    """The hub URL, resolved the way bin/fm-stream.sh resolves it.

    An explicit flag wins, then the environment, then this home's config,
    then a hub this home started itself, then the loopback default. The
    self-started read exists because `hub start --port N` otherwise leaves
    the shim resolving the default port while a hub it could use is up.
    """
    if explicit:
        url = explicit
    else:
        url = os.environ.get("FM_STREAM_HUB", "") or config_line("stream-hub")
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
        raise SystemExit("fm-stream-claude-tail: hub URL %r must start with "
                         "http:// or https://" % url)
    return url.rstrip("/")


def resolve_token(explicit_file: str) -> str:
    """A publish-class credential: an explicit file, the environment, or config.

    The shim never publishes unauthenticated, and never guesses a class it
    was not granted: a token without the publish class is refused by the
    hub on the first call and reported as what it is.
    """
    if explicit_file:
        return read_token_file(explicit_file)
    token = os.environ.get("FM_STREAM_TOKEN", "")
    if token:
        return token
    configured = config_line("stream-token")
    if configured:
        return configured
    raise SystemExit("fm-stream-claude-tail: no publish token; pass --token-file, "
                     "set FM_STREAM_TOKEN, or write config/stream-token under FM_HOME")


def resolve_machine(explicit: str) -> str:
    if explicit:
        name = explicit
    else:
        name = (os.environ.get("FM_STREAM_MACHINE", "")
                or config_line("stream-machine"))
    if not name:
        name = socket.gethostname() or "unknown"
    name = re.sub(r"[^A-Za-z0-9._-]", "-", name)
    if not MACHINE_RE.match(name):
        raise SystemExit("fm-stream-claude-tail: --machine must be 1-128 "
                         "characters of [A-Za-z0-9._-]")
    return name


# --- the publisher -------------------------------------------------------------


class Publisher:
    """One shim's endpoint on the hub: identity, frames, and the rejoin ladder.

    Registration and publishing are the agent's own shapes, and the rejoin
    behaviour is the agent's too: a hub that says `no_such_endpoint` has
    restarted and is re-registered under the SAME endpoint id, paced and
    jittered so a fleet of shims returns as a spread rather than a burst,
    while a hub that merely does not answer is waited out on a backoff.
    """

    def __init__(self, options: argparse.Namespace, hub: HubClient,
                 endpoint_id: str, counters: Counters) -> None:
        self.options = options
        self.hub = hub
        self.endpoint_id = endpoint_id
        self.counters = counters
        self.seq = 0
        self._register_not_before = 0.0
        self._register_backoff = REREGISTER_BACKOFF_MIN
        self._fail_not_before = 0.0
        self._fail_backoff = PUBLISH_BACKOFF_MIN

    def publish_blocked(self) -> bool:
        """True while a failed publish is holding back the next attempt."""
        return time.monotonic() < self._fail_not_before

    def note_published(self) -> None:
        self._fail_not_before = 0.0
        self._fail_backoff = PUBLISH_BACKOFF_MIN

    def note_publish_failed(self) -> float:
        """Record a delivery failure; return how long to hold the next attempt.

        A hub that is not answering would otherwise be retried on every
        idle heartbeat for the shim's whole life, so failures back off - and
        a success resets the ladder, so a hub that flapped once is not
        punished for it for minutes afterwards.
        """
        wait = self._fail_backoff
        self._fail_not_before = time.monotonic() + wait
        self._fail_backoff = min(self._fail_backoff * 2, PUBLISH_BACKOFF_MAX)
        return wait

    def registration(self) -> dict:
        return {
            "endpoint_id": self.endpoint_id,
            "machine": self.options.machine,
            "label": self.options.label,
            "cwd": self.options.cwd,
            # The endpoint owns no terminal, and the hub allocates a screen
            # per row and column, so the geometry is the smallest honest one.
            "rows": 1,
            "cols": 1,
        }

    def state_frame(self, alive: bool = True) -> dict:
        self.seq += 1
        return {
            "endpoint_id": self.endpoint_id,
            "state": {
                "alive": alive,
                "foreground": [],
                "cwd": "",
                "published_at": _now(),
                "seq": self.seq,
                "tokens": self.counters.snapshot(),
                "messages": self.counters.messages,
            },
        }

    def closing_frame(self) -> dict:
        frame = self.state_frame(alive=False)
        frame["closed"] = True
        frame["exit_code"] = 0
        return frame

    def register(self) -> None:
        self.hub.call("POST", "/v1/agent/endpoints", self.registration(), timeout=15.0)

    def re_register(self, final: bool = False) -> bool:
        """Take the identity back from a hub that forgot it, on the pace.

        A FINAL recovery ignores the pace, mirroring the agent: it carries
        the closing frame, which nothing afterwards would retry, so there
        is no next attempt to space out. It is still ONE attempt, and a hub
        still down ends the shim's teardown rather than holding it open.
        """
        now = time.monotonic()
        if not final and now < self._register_not_before:
            return False
        self._register_not_before = now + self._register_backoff * (
            1.0 + REREGISTER_JITTER * random.random())
        try:
            self.register()
        except Superseded:
            raise
        except RuntimeError as exc:
            sys.stderr.write("fm-stream-claude-tail: could not re-register endpoint "
                             "%s: %s\n" % (self.endpoint_id, exc))
            self._register_backoff = min(self._register_backoff * 2,
                                         REREGISTER_BACKOFF_MAX)
            return False
        self._register_backoff = REREGISTER_BACKOFF_MIN
        sys.stderr.write("fm-stream-claude-tail: re-registered endpoint %s with the "
                         "hub at %s after the hub lost it\n"
                         % (self.endpoint_id, self.hub.base_url))
        return True

    def publish(self, frame: dict) -> bool:
        """Post one frame, re-registering once if the hub forgot the endpoint.

        True when the hub took it. False when it could not be delivered -
        the counters are cumulative, so a lost frame costs nothing but a
        moment of unreadability; the next publish carries the same truth.
        Superseded propagates: that answer ends the shim.
        """
        try:
            self.hub.call("POST", "/v1/agent/frames",
                          {"machine": self.options.machine, "frames": [frame]})
            return True
        except Forgotten:
            if not self.re_register():
                return False
            try:
                self.hub.call("POST", "/v1/agent/frames",
                              {"machine": self.options.machine, "frames": [frame]})
                return True
            except (Forgotten, RuntimeError) as exc:
                sys.stderr.write("fm-stream-claude-tail: publish failed after "
                                 "re-registering: %s\n" % exc)
                return False
        except RuntimeError as exc:
            sys.stderr.write("fm-stream-claude-tail: publish failed: %s\n" % exc)
            return False


def write_state_file(path: str, frame: dict) -> None:
    """The local mirror of the last published frame, atomically."""
    if not path:
        return
    body = json.dumps(frame.get("state") or {}, sort_keys=True) + "\n"
    tmp = path + ".tmp"
    try:
        with open(tmp, "w", encoding="utf-8") as handle:
            handle.write(body)
        os.replace(tmp, path)
    except OSError as exc:
        sys.stderr.write("fm-stream-claude-tail: could not write %s: %s\n" % (path, exc))
        try:
            os.unlink(tmp)
        except OSError:
            pass


# --- commands -----------------------------------------------------------------


def build_source(options: argparse.Namespace, require_existing: bool) -> TranscriptSource:
    if bool(options.transcript) == bool(options.project_dir):
        raise SystemExit("fm-stream-claude-tail: pass exactly one of --transcript "
                         "and --project-dir")
    if options.transcript:
        if require_existing and not os.path.isfile(options.transcript):
            raise SystemExit("fm-stream-claude-tail: --transcript %s is not a file"
                             % options.transcript)
        return TranscriptSource(transcript=options.transcript)
    if not os.path.isdir(options.project_dir):
        raise SystemExit("fm-stream-claude-tail: --project-dir %s is not a directory"
                         % options.project_dir)
    source = TranscriptSource(project_dir=options.project_dir)
    if require_existing and not source.followed_path():
        raise SystemExit("fm-stream-claude-tail: no session transcript (*.jsonl) in %s"
                         % options.project_dir)
    return source


def cmd_summarize(options: argparse.Namespace) -> int:
    source = build_source(options, require_existing=True)
    counters = Counters()
    if options.transcript:
        source.poll(counters)
    else:
        # Every session file in the directory, oldest first, through the
        # same id-deduplicating counters: what serve would have accumulated
        # had it followed this worker from the first session.
        try:
            names = sorted(os.listdir(options.project_dir))
        except OSError as exc:
            raise SystemExit("fm-stream-claude-tail: cannot read %s: %s"
                             % (options.project_dir, exc))
        for name in names:
            if name.endswith(".jsonl"):
                TranscriptFile(os.path.join(options.project_dir, name)).poll(counters)
    print(json.dumps({
        "transcript": options.transcript or options.project_dir,
        "messages": counters.messages,
        "tokens": counters.snapshot(),
    }, sort_keys=True))
    return 0


def cmd_serve(options: argparse.Namespace) -> int:
    source = build_source(options, require_existing=True)
    if not LABEL_RE.match(options.label):
        raise SystemExit("fm-stream-claude-tail: --label must be 1-128 characters "
                         "of [A-Za-z0-9._@%+-]")
    options.machine = resolve_machine(options.machine)
    if not options.cwd:
        options.cwd = (os.path.dirname(os.path.abspath(options.transcript))
                       if options.transcript else os.path.abspath(options.project_dir))
    if not os.path.isabs(options.cwd):
        raise SystemExit("fm-stream-claude-tail: --cwd must be an absolute path")

    hub = HubClient(resolve_hub(options.hub), resolve_token(options.token_file))
    try:
        health = hub.call("GET", "/v1/health", timeout=12.0)
    except RuntimeError as exc:
        raise SystemExit("fm-stream-claude-tail: %s" % exc)
    if health.get("protocol") != HUB_PROTOCOL:
        raise SystemExit("fm-stream-claude-tail: the hub at %s speaks protocol %r "
                         "but this shim implements %d; update both ends"
                         % (hub.base_url, health.get("protocol"), HUB_PROTOCOL))

    # The heartbeat is what keeps this endpoint readable, so an unpinned one
    # is derived from the hub's own staleness window rather than configured
    # apart from it, exactly as the agent derives its own.
    if not options.heartbeat_explicit:
        try:
            max_age = float(health.get("state_max_age_secs") or 0.0)
        except (TypeError, ValueError):
            max_age = 0.0
        if max_age > 0:
            options.heartbeat_secs = max(0.5, min(options.heartbeat_secs, max_age / 3.0))

    # The baseline is the whole transcript as it stands: cumulative counters
    # are the point, not the delta since the shim happened to start.
    counters = Counters()
    source.poll(counters)

    endpoint_id = os.urandom(16).hex()
    publisher = Publisher(options, hub, endpoint_id, counters)
    try:
        publisher.register()
    except Superseded:
        # The name belongs to another endpoint: this is the stand-down path,
        # not an error report, so it reaches the caller's exit-3 handling.
        raise
    except RuntimeError as exc:
        raise SystemExit("fm-stream-claude-tail: could not register endpoint: %s" % exc)

    stop = threading.Event()

    def _signalled(signum, frame) -> None:  # noqa: ARG001
        stop.set()

    signal.signal(signal.SIGTERM, _signalled)
    signal.signal(signal.SIGINT, _signalled)

    def publish_now(frame: dict) -> bool:
        if publisher.publish(frame):
            publisher.note_published()
            write_state_file(options.state_file, frame)
            return True
        publisher.note_publish_failed()
        return False

    # The first frame goes out before readiness is announced, so anything
    # told the endpoint exists can already read it.
    publish_now(publisher.state_frame())
    if options.ready_file:
        try:
            with open(options.ready_file, "w", encoding="utf-8") as handle:
                handle.write("%s %s\n" % (options.machine, endpoint_id))
        except OSError as exc:
            raise SystemExit("fm-stream-claude-tail: cannot write --ready-file %s: %s"
                             % (options.ready_file, exc))
    sys.stderr.write("fm-stream-claude-tail %s endpoint %s following %s -> %s\n"
                     % (SHIM_VERSION, endpoint_id, source.followed_path() or
                        options.project_dir, hub.base_url))
    sys.stderr.flush()

    last_publish = time.monotonic()
    while not stop.is_set():
        changed = source.poll(counters)
        now = time.monotonic()
        heartbeat_due = now - last_publish >= options.heartbeat_secs
        if (changed or heartbeat_due) and not publisher.publish_blocked():
            if publish_now(publisher.state_frame()):
                last_publish = time.monotonic()
        # Never sleep past the next heartbeat: an idle transcript's only
        # duty is that cadence, and a slow poll interval must not delay it.
        # While a failed publish holds the next attempt, sleep in small
        # chunks instead of spinning, but never longer than the poll itself.
        sleep_for = options.poll_secs
        until_heartbeat = options.heartbeat_secs - (time.monotonic() - last_publish)
        if until_heartbeat > 0:
            sleep_for = min(sleep_for, until_heartbeat)
        else:
            sleep_for = min(sleep_for, 0.05)
        if publisher.publish_blocked():
            sleep_for = min(max(sleep_for, 0.25), max(0.25, options.poll_secs))
        stop.wait(max(0.02, sleep_for))

    # Close the record out the way the agent does, so the Bridge renders
    # this leaf Stopped with an exit code rather than aging it out stale.
    # One attempt, with one unpaced re-register behind it: a hub still down
    # ends the teardown rather than holding it open.
    try:
        # The closing frame is one attempt, with one unpaced re-register
        # behind it: a hub still down ends the teardown rather than holding
        # it open.
        publish_now(publisher.closing_frame())
    except Superseded:
        pass
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-stream-claude-tail.py",
        description="publish a Claude Code session transcript's token usage to the stream hub")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--protocol", action="store_true")
    commands = parser.add_subparsers(dest="command")

    def source_options(sub) -> None:
        sub.add_argument("--transcript", default="",
                         help="one session JSONL to follow")
        sub.add_argument("--project-dir", default="",
                         help="projects/<slug> directory; follow the newest session")

    serve = commands.add_parser("serve", help="tail a transcript and publish")
    source_options(serve)
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
    serve.add_argument("--state-file", default="",
                       help="mirror the last published state frame there")

    summarize = commands.add_parser(
        "summarize", help="print one transcript's cumulative counters as JSON")
    source_options(summarize)
    return parser


def main(argv: list) -> int:
    parser = build_parser()
    options = parser.parse_args(argv)
    options.heartbeat_explicit = any(
        a == "--heartbeat-secs" or a.startswith("--heartbeat-secs=") for a in argv)
    if options.version:
        print(SHIM_VERSION)
        return 0
    if options.protocol:
        print(HUB_PROTOCOL)
        return 0
    if options.command == "serve":
        if not options.label:
            raise SystemExit("fm-stream-claude-tail: --label is required for serve")
        if options.poll_secs <= 0:
            raise SystemExit("fm-stream-claude-tail: --poll-secs must be positive")
        if options.heartbeat_secs <= 0:
            raise SystemExit("fm-stream-claude-tail: --heartbeat-secs must be positive")
        try:
            return cmd_serve(options)
        except Superseded as exc:
            sys.stderr.write("fm-stream-claude-tail: %s\n" % exc)
            return 3
    if options.command == "summarize":
        return cmd_summarize(options)
    parser.print_help(sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
