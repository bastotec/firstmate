"""fm_stream_tail_lib.py - the shared publisher behind the transcript-tail adapters.

A tail adapter tails a harness's own on-disk session storage and publishes
what it measures to the fleet hub (bin/fm-stream-hub.py) as if it were
bin/fm-stream-agent.py: one endpoint per selected source, state frames on a
heartbeat, and counters only from real usage records the harness itself wrote.
The Bridge feed then sees that worker through the same fleet listing every
other worker appears in.

This module owns the reusable hub publisher used by the opencode and Claude
transcript adapters:

  * The hub wire contract: registration payload, state frames, the closing
    frame, and the protocol handshake against /v1/health.
  * Rejoin after a hub restart.  The hub's endpoint registry lives in its
    memory, so a restarted hub has never heard of this endpoint; the next
    publish is refused with no_such_endpoint and the adapter takes the SAME
    endpoint id back, paced so a fleet of stranded tailers does not return
    against a just-restarted hub in one burst.  docs/stream-backend.md "When
    the hub restarts" owns the contract; this module is its tail-adapter half.
  * The state envelope: alive, cwd, published_at, and a strictly increasing
    per-process seq. Each adapter supplies the counter payload its source can
    prove; the default opencode payload remains the shared "tail" block.

Each adapter owns only its source: where the harness keeps sessions, how to
resolve one, and how to read cumulative usage out of it. It hands the shared
publisher plain numbers and its source-specific state payload.

Adapters supply cumulative payloads, never deltas or estimates.
This publisher persists no counter cursor or state mirror; each adapter owns
how it rebuilds counters after its process restarts.
"""

from __future__ import annotations

import argparse
import json
import os
import random
import re
import socket
import sys
import threading
import time
import urllib.error
import urllib.request

TAIL_LIB_VERSION = "1.0.0"
WIRE_PROTOCOL = 3

# The tail record's token block. Every source fills the same keys so the
# consumer never branches on the source, and cache tokens stay separate from
# billable ones because the harnesses report them separately.
TOKEN_FIELDS = ("input", "output", "reasoning", "cache_read", "cache_write")

STATUS_STATES = ("working", "needs-decision", "blocked", "paused", "done",
                 "failed", "resolved")

MACHINE_RE = re.compile(r"\A[A-Za-z0-9._-]{1,128}\Z")

# Re-registration pacing, shared with the agent: the floor is short because a
# hub restart is over in seconds, the ceiling keeps a long outage from being
# polled forever, and the jitter spreads a whole fleet's return.
REREGISTER_BACKOFF_MIN = 2.0
REREGISTER_BACKOFF_MAX = 60.0
REREGISTER_JITTER = 0.25

# The one frame with no next attempt behind it waits this long on a recovery
# another thread already has in flight, mirroring the agent's rule: a closing
# frame dropped for a lock a sibling thread happens to hold is dropped for
# good, while waiting forever holds teardown open.
FINAL_REGISTER_WAIT_SECS = 3.0


class Superseded(RuntimeError):
    """This endpoint's identity now belongs to another live endpoint.

    The one situation a tail adapter cannot come back from: while it was out
    of touch, another endpoint took its machine and label.  Publishing from
    here would put two workers behind one name, so the adapter stands down -
    it stops publishing, but it is the operator's call whether the tailing
    process keeps running, because tailing writes nothing anywhere.
    """


class Forgotten(RuntimeError):
    """The hub has no record of this endpoint, so the adapter can take it back.

    Stated only by the hub itself (no_such_endpoint), never inferred from a
    failed connection: a hub on its way back up is unreachable too, and
    re-registering against a hub that still holds the record would contest a
    healthy identity.
    """


SUPERSEDING_REFUSALS = frozenset(("endpoint_superseded", "duplicate_label"))


def default_machine() -> str:
    return re.sub(r"[^A-Za-z0-9._-]", "-", socket.gethostname() or "unknown")


def read_token(options: argparse.Namespace, program: str) -> str:
    """The publish-class credential, per docs/stream-backend.md's token layout.

    --token-file's first line, else FM_STREAM_TOKEN.  A tail adapter never
    publishes unauthenticated.
    """
    if options.token_file:
        try:
            with open(options.token_file, "r", encoding="utf-8") as fh:
                token = fh.readline().strip()
        except OSError as exc:
            raise SystemExit("%s: cannot read --token-file %s: %s"
                             % (program, options.token_file, exc))
        if token:
            return token
    token = os.environ.get("FM_STREAM_TOKEN", "")
    if not token:
        raise SystemExit("%s: no publish token; pass --token-file or set "
                         "FM_STREAM_TOKEN" % program)
    return token


def append_status(status_path: str, state: str, note: str) -> None:
    """The status return channel, written locally exactly as the agent does."""
    if not status_path:
        raise RuntimeError("this endpoint registered no status path")
    if state not in STATUS_STATES:
        raise RuntimeError("unknown status state %r (known: %s)"
                           % (state, ", ".join(STATUS_STATES)))
    line = "%s: %s\n" % (state, " ".join(str(note).split()))
    with open(status_path, "a", encoding="utf-8") as fh:
        fh.write(line)


class HubClient:
    """Outbound authenticated calls to the hub, exactly as the agent makes."""

    def __init__(self, base_url: str, token: str, program: str) -> None:
        self.base_url = base_url.rstrip("/")
        self.token = token
        self.command_capability = ""
        self.program = program

    def call(self, method: str, path: str, payload=None, timeout: float = 30.0):
        data = None
        headers = {"Authorization": "Bearer " + self.token}
        if self.command_capability:
            headers["X-Endpoint-Capability"] = self.command_capability
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
            raise RuntimeError("cannot reach the hub at %s: %s"
                               % (self.base_url, exc.reason))
        except (TimeoutError, OSError) as exc:
            raise RuntimeError("the hub at %s did not answer %s %s: %s"
                               % (self.base_url, method, path, exc))
        if not body:
            return {}
        try:
            answer = json.loads(body)
            if method == "POST" and path == "/v1/agent/endpoints":
                self.command_capability = answer.get("command_capability", "")
            return answer
        except json.JSONDecodeError as exc:
            raise RuntimeError("hub returned malformed JSON for %s %s: %s"
                               % (method, path, exc))


class TailPublisher:
    """One tailed source's endpoint on the hub, and its record shape.

    The adapter builds plain counters; this class turns them into the state
    record every tail source shares, keeps its sequence strictly increasing,
    and owns rejoin, heartbeats, and the closing frame.
    """

    def __init__(self, hub: HubClient, machine: str, label: str, cwd: str,
                 endpoint_id: str, source: str, rows: int = 40, cols: int = 200,
                 program: str = "fm-stream-tail", state_adapter=None) -> None:
        self.hub = hub
        self.machine = machine
        self.label = label
        self.cwd = cwd
        self.endpoint_id = endpoint_id
        self.source = source
        self.rows = rows
        self.cols = cols
        self.program = program
        self.state_adapter = state_adapter
        self.stood_down = threading.Event()
        # One publisher at a time: the tail loop and the command thread can
        # both reach the hub, and interleaved frames from one endpoint would
        # publish records out of the order their seq claims.  Reentrant
        # because the publish path itself drives re-registration through
        # _recover_registration, which takes the same lock to keep one
        # recovery in flight per adapter.
        self._publish_lock = threading.RLock()
        self._seq = 0
        self._register_not_before = 0.0
        self._register_backoff = REREGISTER_BACKOFF_MIN

    def registration(self) -> dict:
        """This endpoint's identity, in the one spelling the hub is ever given.

        Its identity fields match the agent's, so the hub, the fleet listing,
        and the Bridge feed treat a tailed worker exactly like a pty-backed one.
        """
        return {
            "endpoint_id": self.endpoint_id,
            "machine": self.machine,
            "label": self.label,
            "cwd": self.cwd,
            "rows": self.rows,
            "cols": self.cols,
            "protocol": WIRE_PROTOCOL,
        }

    def check_protocol(self, expect: int) -> dict:
        """Handshake with the hub; returns the health answer for cadence derivation."""
        health = self.hub.call("GET", "/v1/health")
        protocol = health.get("protocol")
        if protocol != expect:
            raise SystemExit("%s: the hub at %s speaks protocol %r but this "
                             "adapter implements %d; update both ends"
                             % (self.program, self.hub.base_url, protocol, expect))
        return health

    def derive_state_interval(self, health: dict, configured: float,
                              explicit: bool) -> float:
        """Derive the heartbeat from the hub's staleness window unless pinned.

        Two independent numbers that have to line up eventually will not, and
        the failure is silent: every endpoint reads stale on a healthy fleet.
        """
        if explicit:
            return configured
        try:
            hub_max_age = float(health.get("state_max_age_secs") or 0.0)
        except (TypeError, ValueError):
            hub_max_age = 0.0
        if hub_max_age > 0:
            return max(0.5, min(configured, hub_max_age / 3.0))
        return configured

    def register(self) -> None:
        self.hub.call("POST", "/v1/agent/endpoints", self.registration(),
                      timeout=15.0)

    def _recover_registration(self, reason: Exception, final: bool = False) -> bool:
        """Take this endpoint's id back from a hub that forgot it.

        False means the endpoint is not back and the caller drops what it was
        publishing.  A FINAL recovery (the closing frame's) skips the pacing
        for the same reason the agent's does: it is the last call this
        process will ever make, and the frame it carries is not retried.
        """
        if self.stood_down.is_set():
            return False
        if final:
            acquired = self._publish_lock.acquire(timeout=FINAL_REGISTER_WAIT_SECS)
        else:
            acquired = self._publish_lock.acquire(blocking=False)
        if not acquired:
            return False
        try:
            if self.stood_down.is_set():
                return False
            if not final and time.monotonic() < self._register_not_before:
                return False
            self._register_not_before = time.monotonic() + self._register_backoff * (
                1.0 + REREGISTER_JITTER * random.random())
            try:
                self.register()
            except Superseded as exc:
                self.give_up(exc)
                return False
            except RuntimeError as exc:
                sys.stderr.write("%s: could not re-register endpoint %s: %s\n"
                                 % (self.program, self.endpoint_id, exc))
                self._register_backoff = min(self._register_backoff * 2,
                                             REREGISTER_BACKOFF_MAX)
                return False
            # A registration the hub took ends the ladder and the wait behind
            # it together; leaving either would bar the next recovery for as
            # long as the failures before it had earned.
            self._register_backoff = REREGISTER_BACKOFF_MIN
            self._register_not_before = time.monotonic() + REREGISTER_BACKOFF_MIN * (
                1.0 + REREGISTER_JITTER * random.random())
        finally:
            self._publish_lock.release()
        sys.stderr.write("%s: re-registered endpoint %s with the hub at %s after: %s\n"
                         % (self.program, self.endpoint_id, self.hub.base_url, reason))
        return True

    def give_up(self, reason: Exception) -> None:
        if self.stood_down.is_set():
            return
        self.stood_down.set()
        sys.stderr.write("%s: %s\n" % (self.program, reason))
        sys.stderr.flush()

    def build_state(self, alive: bool, payload: dict) -> dict:
        """Build a source-specific state on the shared publisher envelope.

        seq is per-process and strictly increasing, so a consumer can drop
        out-of-order records and a restarted adapter is a new sequence
        starting at 1 - the same pairing of sequence and process identity the
        Bridge feed uses for its own epochs.
        """
        self._seq += 1
        state = {
            "alive": bool(alive),
            "cwd": self.cwd,
            "published_at": time.time(),
            "seq": self._seq,
        }
        if self.state_adapter is None:
            state["tail"] = dict(payload, source=self.source)
        else:
            state.update(self.state_adapter(payload))
        return state

    def publish(self, alive: bool, tail: dict, timeout: float = 30.0) -> bool:
        """Publish one state frame; False when it was dropped or stood down.

        A hub that cannot be reached never takes the tailed session down:
        the harness keeps writing its storage and the next heartbeat retries,
        at the cost of the records the hub's memory never held.
        """
        if self.stood_down.is_set():
            return False
        with self._publish_lock:
            state = self.build_state(alive, tail)
            for attempt in (0, 1):
                try:
                    self.hub.call("POST", "/v1/agent/frames", {
                        "machine": self.machine,
                        "frames": [{"endpoint_id": self.endpoint_id,
                                    "state": state}],
                    }, timeout=timeout)
                    return True
                except Forgotten as exc:
                    if attempt > 0:
                        # A second refusal after a registration that just
                        # succeeded is a race, not a hub to keep arguing with.
                        sys.stderr.write("%s: the hub forgot endpoint %s again: %s\n"
                                         % (self.program, self.endpoint_id, exc))
                        return False
                    # Re-register under the SAME id, then deliver this frame
                    # to the record that comes back with it.
                    if not self._recover_registration(exc):
                        return False
                except Superseded as exc:
                    self.give_up(exc)
                    return False
                except RuntimeError as exc:
                    sys.stderr.write("%s: publish failed: %s\n" % (self.program, exc))
                    return False
            return False

    def close(self, alive: bool, tail: dict, exit_code=0) -> None:
        """The closing frame: this adapter's endpoint ends here.

        A closing frame is a statement about the record this adapter already
        holds, so standing down never swallows it, and it gets its one
        recovery attempt even when the pacing window has not elapsed.
        """
        with self._publish_lock:
            state = self.build_state(alive, tail)
            for attempt in (0, 1):
                try:
                    self.hub.call("POST", "/v1/agent/frames", {
                        "machine": self.machine,
                        "frames": [{"endpoint_id": self.endpoint_id,
                                    "closed": True,
                                    "exit_code": exit_code,
                                    "state": state}],
                    }, timeout=30.0)
                    return
                except Forgotten as exc:
                    if attempt > 0:
                        sys.stderr.write("%s: the hub forgot endpoint %s again: %s\n"
                                         % (self.program, self.endpoint_id, exc))
                        return
                    if not self._recover_registration(exc, final=True):
                        return
                except Superseded as exc:
                    # Even a lost name may close the record it holds out.
                    sys.stderr.write("%s: closing after supersession: %s\n"
                                     % (self.program, exc))
                    return
                except RuntimeError as exc:
                    sys.stderr.write("%s: could not deliver the closing frame: %s\n"
                                     % (self.program, exc))
                    return


def empty_tail(session_id: str) -> dict:
    """A tail block with no usage yet - zeros, never estimates.

    usage_records 0 says "the source holds no usage records", which is a fact
    about the session, not a fabricated counter.
    """
    return {
        "session_id": session_id,
        "usage_records": 0,
        "tokens": {field: 0 for field in TOKEN_FIELDS},
        "cost": 0.0,
    }


def unknown_tail(session_id: str) -> dict:
    """A tail block for storage that has never answered - no counters at all.

    Zeros would claim a read proved the session holds no usage records; the
    block carries only the session it stands for, and the counters come back
    with the first read that answers.
    """
    return {
        "session_id": session_id,
    }
