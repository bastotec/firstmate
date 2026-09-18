#!/usr/bin/env python3
"""fm-stream-bridge.py - translate the stream hub into the Bridge UI's live wire format.

The stream hub (bin/fm-stream-hub.py) knows every worker in the fleet: which
endpoints are registered, which machine publishes each one, when its agent was
last heard from, and whether that agent reported the worker gone.  The Bridge
UI renders a typed live wire format of per-leaf records.  Nothing joined the
two, so the Bridge had no real fleet to show.  This adapter is that join, and
it only reads: hub in, wire records out.  It sends nothing to any worker.

It runs beside the hub, on the host that runs the hub, and holds a
subscribe-class credential.  It writes one wire record per line (NDJSON) to
stdout, so where that stream goes is decided by how the adapter is started,
never by the adapter.  docs/stream-backend.md "Bridge feed" owns deployment and
the open exposure decision.

WHAT THE HUB CARRIES, AND WHAT IT DOES NOT.  The wire format's six-point
contract is answered from hub facts only, and every field the hub does not
carry is emitted in the contract's explicit unknown form rather than invented:

  1. Identity.  fleet_id is the operator's --fleet-id.  parent_mate_id is the
     endpoint's machine: the name the publishing home gives itself on the hub.
     leaf_worker_id is "<machine>/<label>", the task as that home spells it,
     so one label on two homes is two leaves.  execution_id is the hub's
     durable endpoint id, so a relaunch is a new execution of the same leaf.
     The hub keeps a superseded endpoint listed for a while, so only a leaf's
     newest listed endpoint is emitted.
     The wire format has no membership or removal record: a leaf is a member
     from its first record, and an endpoint the hub has dropped simply stops
     being emitted, which the Bridge ages out as stale.
  2. Sequence and epoch.  Every record carries a per-leaf sequence that
     strictly increases for the life of one adapter process.  stream_epoch is
     the adapter's generation, so a restarted adapter starts a new epoch and
     its sequences may begin again at 1.
  3. Token definition.  The hub carries NO token counter of any kind, only raw
     terminal bytes, so no leaf_counter record is ever emitted.  Terminal
     bytes are not tokens, and a declared token kind the hub cannot measure
     would be a synthesized value.
  4. Clocks.  producer_monotonic_ms is the adapter's own monotonic clock, in
     milliseconds since the adapter started, taken when the record is built.
     hub_arrival_ms is the same clock, taken when the hub answer the record is
     built from arrived.  Both restart at 0 with a new stream_epoch.
  5. Heartbeats.  Every tick emits one fresh leaf_heartbeat for EVERY leaf
     the hub lists, which is also the reconnect snapshot and the membership
     coverage.  The hub's only positive verdict is an agent reporting its own
     worker gone, so that alone yields Stopped (exit 0, a signal, or no code)
     or Failed (a positive exit code).  Everything else - a running worker, a
     silent agent, a close the hub made on its own - is Unknown, because the
     hub cannot tell working from idle and never reads silence as death.
     There is no Idle: the hub has no signal that says a worker is idle.
     When the hub cannot be read, nothing is emitted, so every leaf goes stale
     on the Bridge's own clock rather than being held at its last state.
  6. Leaf versus summary.  Only leaf records are emitted.  The adapter never
     sums anything and never emits a summary record.

Commands:

  fm-stream-bridge.py serve [options]      poll the hub and stream records
  fm-stream-bridge.py snapshot [options]   emit one tick of records and exit
  fm-stream-bridge.py translate [options]  replay recorded hub listings
  fm-stream-bridge.py compare [options]    compare against fm-crew-state.sh
  fm-stream-bridge.py --protocol           print the hub protocol it speaks
  fm-stream-bridge.py --version            print the adapter version

serve / snapshot options:

  --hub URL             hub base URL (required)
  --token-file PATH     file whose first line is a token holding the
                        subscribe class (required)
  --fleet-id ID         fleet identity on every record (default firstmate)
  --interval-ms N       serve only: tick length (default 500).  It must stay
                        under the Bridge's 1500 ms stale threshold, or a
                        healthy leaf would flicker stale between ticks.
  --epoch N             stream_epoch to emit (default: the adapter's start
                        time in whole milliseconds since the Unix epoch, so a
                        restart moves forward as long as the host clock does)

translate reads recorded hub traffic on stdin, one JSON object per line:
{"at_ms": <adapter clock ms>, "listing": <a GET /v1/tasks body>},
optionally with "received_ms".  It emits exactly what serve would have
emitted for those answers, so a recorded session replays deterministically.
It takes --fleet-id and --epoch (default 0).

compare is the Phase 2 comparison harness.  It reads this home's task records
(<home>/state/*.meta) for stream-backed tasks, takes the adapter's rendered
state for each endpoint from --feed FILE (recorded NDJSON; the last record per
execution wins) or from one live snapshot (--hub and --token-file), runs
fm-crew-state.sh on each task, and prints one tab-separated row per task:

  task  execution_id  bridge_state  crew_state  crew_source  verdict

verdict is `no-verdict` when the adapter claims nothing (Unknown), `missing`
when the endpoint is absent from the feed, `conflict` when the adapter says
the worker stopped while the pane-sourced crew state says it is working or
parked, and `consistent` otherwise.  It exits 1 when any row is a conflict or
missing, 0 otherwise.  Options: --home DIR (default FM_HOME), --crew-state
CMD (default the fm-crew-state.sh beside this script), --fleet-id.

Exit status: 0 on success; 2 on a usage error, a refused credential, or a hub
speaking another protocol.  An unreachable hub is not an exit for serve: it
says so on stderr once, emits nothing, and retries every tick.
"""

from __future__ import annotations

import argparse
import http.client
import json
import math
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

BRIDGE_VERSION = "1.0.0"

# The hub wire protocol this adapter reads.  Anything else is refused rather
# than read on guessed routes.
HUB_PROTOCOL = 2

DEFAULT_FLEET_ID = "firstmate"
DEFAULT_INTERVAL_MS = 500
# The Bridge ages a leaf out when its newest record is older than this
# (the UI's docs/telemetry.md), so a tick at or past it cannot keep a leaf
# fresh.
BRIDGE_STALE_MS = 1500
MIN_INTERVAL_MS = 50
HTTP_TIMEOUT_SECS = 5.0

ENDPOINT_ID_RE = re.compile(r"\A[0-9a-f]{32}\Z")
MACHINE_RE = re.compile(r"\A[A-Za-z0-9._-]{1,128}\Z")
LABEL_RE = re.compile(r"\A[A-Za-z0-9._@%+-]{1,128}\Z")

STATE_UNKNOWN = "Unknown"
STATE_STOPPED = "Stopped"
STATE_FAILED = "Failed"


class BridgeError(Exception):
    """A refusal that ends the command: bad credential, wrong protocol, bad input."""


def heartbeat_state(task: dict) -> str:
    """The wire heartbeat state one hub endpoint supports, and nothing stronger.

    Only a close the endpoint's OWN agent reported is evidence about the
    worker; a close the hub made by itself is an unacknowledged kill, and an
    open endpoint says nothing about whether the worker is producing or idle.
    """
    if task.get("closed_by") != "agent":
        return STATE_UNKNOWN
    code = task.get("exit_code")
    if isinstance(code, int) and not isinstance(code, bool) and code > 0:
        return STATE_FAILED
    return STATE_STOPPED


class Bridge:
    """Hub listings in, wire records out, with per-leaf sequence bookkeeping."""

    def __init__(self, fleet_id: str, epoch: int) -> None:
        self.fleet_id = fleet_id
        self.epoch = epoch
        self.sequences: dict = {}

    def translate(self, listing: dict, at_ms: float, received_ms: float) -> list:
        """One hub /v1/tasks answer -> one heartbeat per leaf, from its newest endpoint."""
        tasks = listing.get("tasks") if isinstance(listing, dict) else None
        if not isinstance(tasks, list):
            raise BridgeError("the hub listing carries no tasks array")
        newest = {}
        for task in tasks:
            if not isinstance(task, dict):
                continue
            endpoint_id = task.get("endpoint_id")
            machine = task.get("machine")
            label = task.get("label")
            if not (isinstance(endpoint_id, str) and ENDPOINT_ID_RE.match(endpoint_id)
                    and isinstance(machine, str) and MACHINE_RE.match(machine)
                    and isinstance(label, str) and LABEL_RE.match(label)):
                # A record the hub itself would have refused to register is not
                # a leaf, and guessing its identity would be worse than
                # leaving it out.
                continue
            # The hub lists a machine's endpoints oldest first, so a relaunch
            # replaces the record it superseded, which may linger listed.
            newest["%s/%s" % (machine, label)] = task
        records = []
        for leaf, task in newest.items():
            machine = task["machine"]
            endpoint_id = task["endpoint_id"]
            sequence = self.sequences.get(leaf, 0) + 1
            self.sequences[leaf] = sequence
            records.append({
                "record": "leaf_heartbeat",
                "identity": {
                    "fleet_id": self.fleet_id,
                    "leaf_worker_id": leaf,
                    "parent_mate_id": machine,
                    "execution_id": endpoint_id,
                    "stream_epoch": self.epoch,
                },
                "sequence": sequence,
                "state": heartbeat_state(task),
                "clock": {
                    "producer_monotonic_ms": float(at_ms),
                    "hub_arrival_ms": float(received_ms),
                },
            })
        return records


def encode(record: dict) -> str:
    return json.dumps(record, separators=(",", ":"))


# --- hub access -------------------------------------------------------------


def read_token(path: str) -> str:
    try:
        with open(path, encoding="utf-8") as handle:
            for line in handle:
                line = line.strip()
                if line:
                    return line
    except OSError as exc:
        raise BridgeError("cannot read the token file %s: %s" % (path, exc.strerror))
    raise BridgeError("the token file %s holds no token" % path)


class HubUnreachable(Exception):
    """The hub did not answer; the next tick may find it back."""


class HubClient:
    def __init__(self, url: str, token: str) -> None:
        self.url = url.rstrip("/")
        self.token = token

    def get(self, path: str) -> dict:
        request = urllib.request.Request(
            self.url + path, headers={"Authorization": "Bearer " + self.token})
        try:
            with urllib.request.urlopen(request, timeout=HTTP_TIMEOUT_SECS) as response:
                body = response.read()
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise BridgeError(
                    "the hub at %s refused the credential for %s (HTTP %d): the "
                    "bridge needs a token holding the subscribe class"
                    % (self.url, path, exc.code))
            raise HubUnreachable("the hub at %s answered %s with HTTP %d"
                                 % (self.url, path, exc.code))
        except (urllib.error.URLError, OSError, ValueError,
                http.client.HTTPException) as exc:
            reason = getattr(exc, "reason", exc)
            raise HubUnreachable("cannot reach the hub at %s: %s" % (self.url, reason))
        try:
            payload = json.loads(body.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            raise HubUnreachable("the hub at %s answered %s with malformed JSON"
                                 % (self.url, path))
        if not isinstance(payload, dict):
            raise HubUnreachable("the hub at %s answered %s with a non-object"
                                 % (self.url, path))
        return payload

    def check_protocol(self) -> None:
        health = self.get("/v1/health")
        protocol = health.get("protocol")
        if protocol != HUB_PROTOCOL:
            raise BridgeError("the hub at %s speaks protocol %r; this bridge reads protocol %d"
                              % (self.url, protocol, HUB_PROTOCOL))


class Clock:
    """Milliseconds on this process's monotonic clock since it started."""

    def __init__(self) -> None:
        self.start = time.monotonic()

    def ms(self) -> float:
        return round((time.monotonic() - self.start) * 1000.0, 3)


def default_epoch() -> int:
    return int(time.time() * 1000)


def emit(records: list) -> None:
    for record in records:
        sys.stdout.write(encode(record) + "\n")
    sys.stdout.flush()


def tick(client: HubClient, bridge: Bridge, clock: Clock) -> list:
    listing = client.get("/v1/tasks")
    received = clock.ms()
    return bridge.translate(listing, clock.ms(), received)


# --- commands ---------------------------------------------------------------


def cmd_serve(options: argparse.Namespace) -> int:
    interval = options.interval_ms
    if interval < MIN_INTERVAL_MS or interval >= BRIDGE_STALE_MS:
        raise BridgeError("--interval-ms must be at least %d and under %d, the Bridge's "
                          "stale threshold" % (MIN_INTERVAL_MS, BRIDGE_STALE_MS))
    client = HubClient(options.hub, read_token(options.token_file))
    bridge = Bridge(options.fleet_id, default_epoch() if options.epoch is None else options.epoch)
    clock = Clock()
    # The protocol is checked before the first record and again whenever the
    # hub comes back, because a hub that went away may return upgraded.
    verified = False
    last_problem = ""
    while True:
        started = time.monotonic()
        try:
            if not verified:
                client.check_protocol()
                verified = True
            records = tick(client, bridge, clock)
        except HubUnreachable as exc:
            verified = False
            if str(exc) != last_problem:
                print("fm-stream-bridge: %s; emitting nothing until it answers" % exc,
                      file=sys.stderr, flush=True)
                last_problem = str(exc)
        else:
            if last_problem:
                print("fm-stream-bridge: the hub at %s answers again" % client.url,
                      file=sys.stderr, flush=True)
                last_problem = ""
            emit(records)
        remaining = interval / 1000.0 - (time.monotonic() - started)
        if remaining > 0:
            time.sleep(remaining)


def cmd_snapshot(options: argparse.Namespace) -> int:
    client = HubClient(options.hub, read_token(options.token_file))
    bridge = Bridge(options.fleet_id, default_epoch() if options.epoch is None else options.epoch)
    try:
        client.check_protocol()
        emit(tick(client, bridge, Clock()))
    except HubUnreachable as exc:
        print("fm-stream-bridge: %s" % exc, file=sys.stderr)
        return 1
    return 0


def cmd_translate(options: argparse.Namespace) -> int:
    bridge = Bridge(options.fleet_id, 0 if options.epoch is None else options.epoch)
    for number, line in enumerate(sys.stdin, start=1):
        line = line.strip()
        if not line:
            continue
        try:
            entry = json.loads(line)
        except json.JSONDecodeError as exc:
            raise BridgeError("line %d is not JSON: %s" % (number, exc))
        if not isinstance(entry, dict):
            raise BridgeError("line %d is not a JSON object" % number)
        at_ms = entry.get("at_ms")
        received_ms = entry.get("received_ms", at_ms)
        for name, value in (("at_ms", at_ms), ("received_ms", received_ms)):
            if (not isinstance(value, (int, float)) or isinstance(value, bool)
                    or not math.isfinite(value) or value < 0):
                raise BridgeError("line %d: %s must be a finite, non-negative number"
                                  % (number, name))
        if received_ms > at_ms:
            raise BridgeError("line %d: received_ms is later than at_ms" % number)
        try:
            emit(bridge.translate(entry.get("listing"), at_ms, received_ms))
        except BridgeError as exc:
            raise BridgeError("line %d: %s" % (number, exc))
    return 0


def read_meta(path: str) -> dict:
    fields = {}
    try:
        with open(path, encoding="utf-8", errors="replace") as handle:
            for line in handle:
                key, sep, value = line.rstrip("\n").partition("=")
                if sep and key not in fields:
                    fields[key] = value
    except OSError:
        return {}
    return fields


def stream_tasks(home: str) -> list:
    """(task id, endpoint id) for every stream-backed task record in <home>."""
    state_dir = os.path.join(home, "state")
    try:
        names = sorted(os.listdir(state_dir))
    except OSError as exc:
        raise BridgeError("cannot read %s: %s" % (state_dir, exc.strerror))
    tasks = []
    for name in names:
        if not name.endswith(".meta") or name.startswith("."):
            continue
        meta = read_meta(os.path.join(state_dir, name))
        endpoint_id = meta.get("stream_endpoint_id", "")
        if meta.get("backend") != "stream" or not ENDPOINT_ID_RE.match(endpoint_id):
            continue
        tasks.append((name[: -len(".meta")], endpoint_id))
    return tasks


def rendered_states(records: list) -> dict:
    """execution id -> the state its last heartbeat rendered."""
    states = {}
    for record in records:
        if not isinstance(record, dict) or record.get("record") != "leaf_heartbeat":
            continue
        identity = record.get("identity") or {}
        states[identity.get("execution_id")] = record.get("state")
    return states


def crew_state(command: str, task: str, home: str) -> tuple:
    """(state, source) from one fm-crew-state.sh line, or ("unreadable", "none")."""
    env = dict(os.environ, FM_HOME=home)
    try:
        proc = subprocess.run([command, task], capture_output=True, text=True,
                              timeout=120, env=env, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return ("unreadable", "none")
    match = re.match(r"state: (\S+) · source: (\S+)", proc.stdout.strip())
    if proc.returncode != 0 or not match:
        return ("unreadable", "none")
    return (match.group(1), match.group(2))


def verdict(bridge_state, crew: str, source: str) -> str:
    if bridge_state is None:
        return "missing"
    if bridge_state == STATE_UNKNOWN:
        return "no-verdict"
    if (bridge_state in (STATE_STOPPED, STATE_FAILED) and source == "pane"
            and crew in ("working", "parked")):
        return "conflict"
    return "consistent"


def cmd_compare(options: argparse.Namespace) -> int:
    home = options.home or os.environ.get("FM_HOME") or os.path.dirname(
        os.path.dirname(os.path.abspath(__file__)))
    command = options.crew_state or os.path.join(
        os.path.dirname(os.path.abspath(__file__)), "fm-crew-state.sh")
    if options.feed:
        records = []
        try:
            with open(options.feed, encoding="utf-8") as handle:
                for line in handle:
                    if line.strip():
                        records.append(json.loads(line))
        except (OSError, json.JSONDecodeError) as exc:
            raise BridgeError("cannot read the feed %s: %s" % (options.feed, exc))
    elif options.hub and options.token_file:
        client = HubClient(options.hub, read_token(options.token_file))
        try:
            client.check_protocol()
            records = tick(client, Bridge(options.fleet_id, 0), Clock())
        except HubUnreachable as exc:
            raise BridgeError(str(exc))
    else:
        raise BridgeError("compare needs --feed FILE, or --hub and --token-file")
    states = rendered_states(records)
    failed = False
    print("task\texecution_id\tbridge_state\tcrew_state\tcrew_source\tverdict")
    for task, endpoint_id in stream_tasks(home):
        bridge_state = states.get(endpoint_id)
        crew, source = crew_state(command, task, home)
        result = verdict(bridge_state, crew, source)
        failed = failed or result in ("conflict", "missing")
        print("\t".join((task, endpoint_id, bridge_state or "-", crew, source, result)))
    return 1 if failed else 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="fm-stream-bridge.py",
        description="Translate the stream hub into the Bridge UI's live wire format.")
    parser.add_argument("--protocol", action="store_true", help="print the hub protocol")
    parser.add_argument("--version", action="store_true", help="print the adapter version")
    commands = parser.add_subparsers(dest="command")

    def hub_options(sub, required: bool) -> None:
        sub.add_argument("--hub", required=required, help="hub base URL")
        sub.add_argument("--token-file", required=required,
                         help="file whose first line is a subscribe-class token")

    def identity_options(sub) -> None:
        sub.add_argument("--fleet-id", default=DEFAULT_FLEET_ID)
        sub.add_argument("--epoch", type=int, default=None)

    serve = commands.add_parser("serve", help="poll the hub and stream records")
    hub_options(serve, True)
    identity_options(serve)
    serve.add_argument("--interval-ms", type=int, default=DEFAULT_INTERVAL_MS)

    snapshot = commands.add_parser("snapshot", help="emit one tick and exit")
    hub_options(snapshot, True)
    identity_options(snapshot)

    translate = commands.add_parser("translate", help="replay recorded hub listings")
    identity_options(translate)

    compare = commands.add_parser("compare", help="compare against fm-crew-state.sh")
    hub_options(compare, False)
    compare.add_argument("--fleet-id", default=DEFAULT_FLEET_ID)
    compare.add_argument("--feed")
    compare.add_argument("--home")
    compare.add_argument("--crew-state")
    return parser


def main(argv: list) -> int:
    parser = build_parser()
    options = parser.parse_args(argv)
    if options.protocol:
        print(HUB_PROTOCOL)
        return 0
    if options.version:
        print(BRIDGE_VERSION)
        return 0
    handlers = {"serve": cmd_serve, "snapshot": cmd_snapshot,
                "translate": cmd_translate, "compare": cmd_compare}
    handler = handlers.get(options.command)
    if handler is None:
        parser.print_help(sys.stderr)
        return 2
    if getattr(options, "fleet_id", None) is not None and not options.fleet_id:
        print("fm-stream-bridge: --fleet-id must not be empty", file=sys.stderr)
        return 2
    if getattr(options, "epoch", None) is not None and options.epoch < 0:
        print("fm-stream-bridge: --epoch must not be negative", file=sys.stderr)
        return 2
    try:
        return handler(options)
    except BridgeError as exc:
        print("fm-stream-bridge: %s" % exc, file=sys.stderr)
        return 2
    except BrokenPipeError:
        # Whoever was reading the feed went away; that ends the feed.
        try:
            sys.stdout = open(os.devnull, "w")
        except OSError:
            pass
        return 0
    except KeyboardInterrupt:
        return 130


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
