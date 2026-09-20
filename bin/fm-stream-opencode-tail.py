#!/usr/bin/env python3
"""fm-stream-opencode-tail.py - publish one opencode session's usage to the stream hub.

opencode keeps its own session storage on disk, so a worker it runs is
invisible to the stream hub's pty-backed agents: no endpoint, no Bridge feed
entry.  This adapter closes that gap the way the Claude Code one does for
Claude workers: it tails opencode's session storage and publishes that
session's cumulative token usage to the fleet hub (bin/fm-stream-hub.py) as a
real endpoint, in the same wire shape bin/fm-stream-agent.py publishes.

What it measures, and what it never does:

  * Cumulative token counters - input, output, reasoning, cache read, cache
    write - and cost, summed ONLY from usage records opencode itself wrote
    into the message table (a message whose data carries a tokens object).
    Nothing is estimated, extrapolated, or synthesized: a session with no
    usage records publishes zeros and usage_records 0, which is a fact about
    the session, not a fabricated counter.
  * Counters are cumulative, so resume is free: a restarted adapter rescans
    the session's messages and converges on the same totals without any
    cursor of its own.  The tail is incremental in that only changed counters
    trigger an immediate publish; idle heartbeats otherwise.
  * One endpoint per tailed session.  The endpoint's label is the task label
    firstmate spells, exactly as for a pty-backed worker, so the Bridge feed
    groups it with the rest of the fleet.

Session storage layout (established from this host's opencode tooling and
docs, not guessed): a SQLite database at ~/.local/share/opencode/opencode.db
(overridable with --db or OPENCODE_DB), holding a session table and a message
table whose data column is JSON with role, tokens, and cost.  The pre-v1.2.0
JSON storage under storage/ is not read: this adapter refuses it rather than
guess at a format nothing on this host still writes.

It owns no pseudoterminal, so the input command is refused - a tail adapter
has nothing to type into.  The kill command stops the tail and closes the
endpoint out; the status command appends to --status-path exactly as the
agent's does, on the machine that owns the record.

The shared wire contract - registration, heartbeats, rejoin after a hub
restart, the state envelope, and the strictly increasing seq - is owned by
bin/fm_stream_tail_lib.py and used by both transcript adapters.
This adapter owns its command poll and command-capable `tail` payload; the
Claude adapter supplies a counter-only payload and remains observability only.

Commands:

  fm-stream-opencode-tail.py serve [options]        tail a session and publish
  fm-stream-opencode-tail.py --protocol             print the wire protocol
  fm-stream-opencode-tail.py --version              print the adapter version

serve options:

  --hub URL              hub base URL (required; or set FM_STREAM_HUB)
  --token-file PATH      file whose first line is the publish-class token
  --machine NAME         this machine's name in the fleet (default: hostname)
  --label NAME           the task label, as firstmate spells it (required)
  --session ID           the opencode session id (ses_...) to tail
  --directory DIR        resolve the newest main session whose directory is
                         DIR when --session is absent
  --db PATH              opencode.db path (default: OPENCODE_DB, then
                         ~/.local/share/opencode/opencode.db)
  --cwd DIR              registration cwd (default: the session's directory)
  --status-path PATH     local state/<id>.status for the status command
  --ready-file PATH      write the durable endpoint id there once registered
  --rows N / --cols N    registration geometry (default 40x200)
  --state-interval SECS  idle heartbeat cadence (default 5, derived from the
                         hub's staleness window unless pinned)
  --tail-interval SECS   how often to poll the session storage (default 1)
  --poll-secs SECS       how long each command long-poll waits (default 25)

The adapter exits when its session is archived or when it is killed through
the hub or by signal, in each case after telling the hub.  Storage that
stops answering never ends the tail: the heartbeat keeps carrying the last
known totals, and no counters at all while it has never answered.
"""

from __future__ import annotations

import argparse
import json
import os
import signal
import sqlite3
import sys
import threading
import time
import urllib.parse

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import fm_stream_tail_lib as tail  # noqa: E402 - beside this script

ADAPTER_VERSION = "1.0.0"
WIRE_PROTOCOL = 2

# The tail block's source name; the Bridge feed's consumer keys on this to
# know which harness a leaf runs, never on the adapter's filename.
SOURCE_NAME = "opencode"

DEFAULT_DB = os.path.join(os.path.expanduser("~"), ".local", "share", "opencode",
                          "opencode.db")


def _open_db(path: str) -> sqlite3.Connection:
    """Open the session storage read-only.

    opencode owns this database; a tail adapter that ever wrote to it could
    corrupt the very storage it measures.  mode=ro refuses a missing or
    unreadable file rather than creating an empty database to tail.
    """
    uri = "file:" + urllib.parse.quote(os.path.abspath(path)) + "?mode=ro"
    conn = sqlite3.connect(uri, uri=True, isolation_level=None, timeout=5.0)
    conn.execute("PRAGMA query_only = 1")
    return conn


def resolve_session(conn: sqlite3.Connection, session_id: str, directory: str,
                    db_path: str) -> dict:
    """Resolve the one session to tail: by id, or the newest main session in a directory.

    Newest by time_updated, main sessions only (parent_id IS NULL): a
    subagent session is a child of the conversation being tailed, so resolving
    to one would tail a fragment of the work.  Unarchived sessions win over
    archived ones, because an archived session is a conversation that ended.
    """
    if session_id:
        row = conn.execute(
            "SELECT id, directory, time_archived FROM session WHERE id = ?",
            (session_id,)).fetchone()
        if row is None:
            raise SystemExit("fm-stream-opencode-tail: session %s is not in %s"
                             % (session_id, db_path))
        return {"id": row[0], "directory": row[1], "archived": bool(row[2])}
    row = conn.execute(
        "SELECT id, directory, time_archived FROM session "
        "WHERE directory = ? AND parent_id IS NULL "
        "ORDER BY (time_archived IS NOT NULL), time_updated DESC LIMIT 1",
        (directory,)).fetchone()
    if row is None:
        raise SystemExit("fm-stream-opencode-tail: no session found in directory %s"
                         % directory)
    return {"id": row[0], "directory": row[1], "archived": bool(row[2])}


def read_usage(conn: sqlite3.Connection, session_id: str, cache: dict) -> dict:
    """Recompute the session's cumulative counters from its usage records.

    Every message row is re-read each poll, but only rows whose time_updated
    moved are re-parsed, and only a message whose data carries a tokens object
    is a usage record: user messages and streaming placeholders hold none, and
    counting anything but the harness's own numbers would be fabrication.
    A message's tokens settle when the turn completes, so a row that updates
    in place is picked up by the same re-read.  The cache belongs to the one
    adapter tailing this session (id -> (time_updated, usage-or-None)); rows
    that leave the session (compaction) leave the cache with it.
    """
    totals = tail.empty_tail(session_id)
    tokens_out = totals["tokens"]
    rows = conn.execute(
        "SELECT id, time_updated, data FROM message WHERE session_id = ?",
        (session_id,)).fetchall()
    for row_id, time_updated, data_json in rows:
        cached = cache.get(row_id)
        if cached is not None and cached[0] == time_updated:
            usage = cached[1]
        else:
            usage = _usage_from_message(data_json)
            cache[row_id] = (time_updated, usage)
        if usage is None:
            continue
        totals["usage_records"] += 1
        for field in tail.TOKEN_FIELDS:
            tokens_out[field] += usage.get(field, 0)
        totals["cost"] += usage.get("cost", 0.0)
    for stale_id in [k for k in cache if k not in {r[0] for r in rows}]:
        del cache[stale_id]
    totals["cost"] = round(totals["cost"], 6)
    return totals


def _usage_from_message(data_json):
    """One message's usage numbers, or None when the message carries none.

    The tokens object and cost live in the message table's data JSON; a usage
    record is exactly a message that has the tokens object.  A malformed row
    is not a usage record, and never stops the tail: it reads as none.
    """
    try:
        data = json.loads(data_json)
    except (TypeError, ValueError):
        return None
    if not isinstance(data, dict):
        return None
    tokens = data.get("tokens")
    if not isinstance(tokens, dict):
        return None
    cache = tokens.get("cache") or {}
    usage = {
        "input": _int_or_zero(tokens.get("input")),
        "output": _int_or_zero(tokens.get("output")),
        "reasoning": _int_or_zero(tokens.get("reasoning")),
        "cache_read": _int_or_zero(cache.get("read") if isinstance(cache, dict) else None),
        "cache_write": _int_or_zero(cache.get("write") if isinstance(cache, dict) else None),
    }
    cost = data.get("cost")
    usage["cost"] = float(cost) if isinstance(cost, (int, float)) else 0.0
    return usage


def _int_or_zero(value) -> int:
    return value if isinstance(value, int) and not isinstance(value, bool) else 0


def session_archived(conn: sqlite3.Connection, session_id: str) -> bool:
    row = conn.execute(
        "SELECT time_archived FROM session WHERE id = ?", (session_id,)).fetchone()
    if row is None:
        # The session row vanished (a reset, a purge).  The messages usually
        # vanish with it, so the tail keeps publishing its last known totals -
        # which read_usage recomputes as zeros only if the messages are gone -
        # and the operator decides when the endpoint ends.
        return False
    return bool(row[0])


class OpencodeTail:
    """The serve loop: tail the storage, publish counters, take commands."""

    def __init__(self, options: argparse.Namespace, hub: tail.HubClient,
                 publisher: tail.TailPublisher, session: dict) -> None:
        self.options = options
        self.hub = hub
        self.publisher = publisher
        self.session = session
        self.conn = None
        self.stop = threading.Event()
        # Set while a command is being applied or acknowledged, so a kill ends
        # this process only after the hub has been told the kill was taken.
        self.command_busy = threading.Event()
        self.last_totals = None
        # Per-message usage cache owned by this adapter; see read_usage.
        self.usage_cache: dict = {}

    # --- storage ----------------------------------------------------------

    def db(self) -> sqlite3.Connection:
        """The storage connection, reopened whenever it stops answering.

        A long-lived read handle can go stale when opencode rotates or
        replaces its database; a fresh one is opened rather than trusting a
        connection whose file may no longer exist.
        """
        if self.conn is None:
            self.conn = _open_db(self.options.db)
        return self.conn

    def poll_storage(self) -> dict:
        """Read the current cumulative totals; None when storage cannot be read.

        Storage that cannot be read is never published as zero usage: the
        last known totals keep flowing on the heartbeat instead, because a
        missing file says nothing about the session's real counters.
        """
        try:
            return read_usage(self.db(), self.session["id"], self.usage_cache)
        except sqlite3.Error as exc:
            sys.stderr.write("fm-stream-opencode-tail: cannot read session storage: %s\n"
                             % exc)
            try:
                self.conn.close()
            except Exception:
                pass
            self.conn = None
            return None

    # --- commands ---------------------------------------------------------

    def apply_command(self, command: dict) -> tuple:
        kind = command.get("kind")
        payload = command.get("payload") or {}
        if kind == "input":
            # A tail adapter owns no terminal, so input is refused rather than
            # silently dropped: the caller learns the delivery failed.
            return (False, "the tail adapter owns no terminal to type into")
        if kind == "kill":
            self.stop.set()
            return (True, "")
        if kind == "status":
            try:
                tail.append_status(self.options.status_path,
                                   str(payload.get("state") or ""),
                                   str(payload.get("note") or ""))
            except (OSError, RuntimeError) as exc:
                return (False, str(exc))
            return (True, "")
        return (False, "unknown command kind %r" % kind)

    def command_loop(self) -> None:
        path = ("/v1/agent/commands?machine=%s&endpoint=%s&wait=%d"
                % (urllib.parse.quote(self.publisher.machine),
                   self.publisher.endpoint_id,
                   int(self.options.poll_secs)))
        backoff = tail.REREGISTER_BACKOFF_MIN
        while not self.stop.is_set():
            if self.publisher.stood_down.is_set():
                return
            try:
                answer = self.hub.call("GET", path,
                                       timeout=self.options.poll_secs + 15)
            except tail.Superseded as exc:
                self.publisher.give_up(exc)
                return
            except RuntimeError as exc:
                sys.stderr.write("fm-stream-opencode-tail: command poll failed: %s\n"
                                 % exc)
                if self.stop.wait(backoff):
                    return
                backoff = min(backoff * 2, tail.REREGISTER_BACKOFF_MAX)
                continue
            backoff = tail.REREGISTER_BACKOFF_MIN
            for command in answer.get("commands") or []:
                self.command_busy.set()
                try:
                    ok, error = False, "the adapter could not apply the command"
                    try:
                        ok, error = self.apply_command(command)
                    except Exception as exc:  # noqa: BLE001 - always answer the hub
                        ok, error = False, str(exc)
                    try:
                        self.hub.call("POST", "/v1/agent/results", {
                            "machine": self.publisher.machine,
                            "command_id": command.get("command_id"),
                            "ok": ok,
                            "error": error,
                        }, timeout=15.0)
                    except RuntimeError as exc:
                        sys.stderr.write("fm-stream-opencode-tail: could not "
                                         "acknowledge: %s\n" % exc)
                finally:
                    self.command_busy.clear()

    # --- loop -------------------------------------------------------------

    def run(self) -> int:
        commands = threading.Thread(target=self.command_loop, name="commands",
                                    daemon=True)
        commands.start()

        def _signalled(signum, frame) -> None:  # noqa: ARG001
            self.stop.set()

        signal.signal(signal.SIGTERM, _signalled)
        signal.signal(signal.SIGINT, _signalled)

        state_interval = self.options.state_interval
        next_heartbeat = time.monotonic()
        # The startup measurement, when storage answered it, so a storage that
        # dies before the first poll still has its known totals flowing.
        last_totals = self.last_totals
        archived = False
        while not self.stop.is_set():
            totals = self.poll_storage()
            if totals is not None:
                last_totals = totals
            now = time.monotonic()
            if last_totals is not None and last_totals != self.last_totals:
                # New usage: publish now, on the record that carries it.
                self.publisher.publish(True, last_totals)
                self.last_totals = last_totals
                next_heartbeat = now + state_interval
            elif now >= next_heartbeat:
                # Explicit heartbeat on a fixed idle cadence: the hub measures
                # staleness against the last state frame, so a silent adapter
                # would read its endpoint stale, never idle.  Storage that has
                # never answered publishes its session with no counters
                # rather than counters no record backs.
                self.publisher.publish(
                    True, last_totals if last_totals is not None
                    else tail.unknown_tail(self.session["id"]))
                next_heartbeat = now + state_interval
            if last_totals is not None and not archived:
                try:
                    archived = session_archived(self.db(), self.session["id"])
                except sqlite3.Error:
                    archived = False
            if archived:
                # The conversation opencode archived is the worker this
                # endpoint stood for; its end is the endpoint's end.
                break
            # Wake for the next poll, the next heartbeat, or the kill.
            wake = min(self.options.tail_interval,
                       max(0.05, next_heartbeat - time.monotonic()))
            self.stop.wait(wake)

        # A kill is applied by the command loop and ends the tail, so let its
        # acknowledgement land before closing the record out.
        deadline = time.monotonic() + 15.0
        while self.command_busy.is_set() and time.monotonic() < deadline:
            time.sleep(0.05)
        if last_totals is None:
            last_totals = tail.unknown_tail(self.session["id"])
        self.publisher.close(False, last_totals, exit_code=0)
        return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=True,
                                     description="tail one opencode session onto the hub")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--protocol", action="store_true")
    sub = parser.add_subparsers(dest="command")
    serve = sub.add_parser("serve")
    serve.add_argument("--hub", default=os.environ.get("FM_STREAM_HUB", ""))
    serve.add_argument("--token-file", default="")
    serve.add_argument("--machine", default="")
    serve.add_argument("--label", default="")
    serve.add_argument("--session", default="")
    serve.add_argument("--directory", default="")
    serve.add_argument("--db", default=os.environ.get("OPENCODE_DB", DEFAULT_DB))
    serve.add_argument("--cwd", default="")
    serve.add_argument("--status-path", default="")
    serve.add_argument("--ready-file", default="")
    serve.add_argument("--rows", type=int, default=40)
    serve.add_argument("--cols", type=int, default=200)
    serve.add_argument("--state-interval", type=float, default=5.0)
    serve.add_argument("--tail-interval", type=float, default=1.0)
    serve.add_argument("--poll-secs", type=float, default=25.0)
    return parser


def main(argv: list) -> int:
    parser = build_parser()
    options = parser.parse_args(argv)
    options.state_interval_explicit = any(
        a == "--state-interval" or a.startswith("--state-interval=") for a in argv)
    if options.version:
        print(ADAPTER_VERSION)
        return 0
    if options.protocol:
        print(WIRE_PROTOCOL)
        return 0
    if options.command != "serve":
        parser.print_help()
        return 2

    if not options.hub:
        raise SystemExit("fm-stream-opencode-tail: --hub is required (or set FM_STREAM_HUB)")
    if not options.label:
        raise SystemExit("fm-stream-opencode-tail: --label is required")
    if not options.machine:
        options.machine = tail.default_machine()
    if not tail.MACHINE_RE.match(options.machine):
        raise SystemExit("fm-stream-opencode-tail: --machine must be 1-128 characters "
                         "of [A-Za-z0-9._-]")
    if not options.session and not options.directory:
        raise SystemExit("fm-stream-opencode-tail: pass --session or --directory so the "
                         "tailed session is the worker's, not a guess")
    if options.directory and not os.path.isabs(options.directory):
        raise SystemExit("fm-stream-opencode-tail: --directory must be absolute")
    if options.status_path and not os.path.isabs(options.status_path):
        raise SystemExit("fm-stream-opencode-tail: --status-path must be absolute")

    if not os.path.isfile(options.db):
        raise SystemExit("fm-stream-opencode-tail: opencode session storage not found at "
                         "%s; pass --db with the opencode.db path" % options.db)
    conn = None
    try:
        conn = _open_db(options.db)
        session = resolve_session(conn, options.session, options.directory, options.db)
    except sqlite3.Error as exc:
        raise SystemExit("fm-stream-opencode-tail: cannot read opencode session storage "
                         "at %s: %s (the pre-v1.2 JSON storage is not supported; point "
                         "--db at an opencode.db)" % (options.db, exc))
    finally:
        if conn is not None:
            conn.close()

    cwd = options.cwd or session["directory"]
    if not os.path.isabs(cwd):
        raise SystemExit("fm-stream-opencode-tail: --cwd must be absolute")

    hub = tail.HubClient(options.hub, tail.read_token(options, "fm-stream-opencode-tail"),
                         "fm-stream-opencode-tail")
    publisher = tail.TailPublisher(
        hub, options.machine, options.label, cwd,
        os.urandom(16).hex(), SOURCE_NAME, options.rows, options.cols,
        program="fm-stream-opencode-tail")
    try:
        health = publisher.check_protocol(WIRE_PROTOCOL)
        options.state_interval = publisher.derive_state_interval(
            health, options.state_interval, options.state_interval_explicit)
        publisher.register()
    except RuntimeError as exc:
        raise SystemExit("fm-stream-opencode-tail: %s" % exc)
    # The first state frame lands BEFORE readiness is announced, so the first
    # thing a spawn may do - ask how the endpoint is - is answerable.
    adapter = OpencodeTail(options, hub, publisher, session)
    first_totals = adapter.poll_storage()
    publisher.publish(True, first_totals if first_totals is not None
                      else tail.unknown_tail(session["id"]))
    adapter.last_totals = first_totals
    if options.ready_file:
        with open(options.ready_file, "w", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (options.machine, publisher.endpoint_id))
    sys.stderr.write("fm-stream-opencode-tail %s endpoint %s on %s tailing session %s\n"
                     % (ADAPTER_VERSION, publisher.endpoint_id, options.machine,
                        session["id"]))
    sys.stderr.flush()
    return adapter.run()


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
