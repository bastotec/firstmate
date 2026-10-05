#!/usr/bin/env bash
# tests/fm-stream-hub-retention.test.sh - the late-result retention boundary.
#
# A command an agent TOOK but did not acknowledge within the hub's
# unacknowledged-command retention used to be dropped from the command router
# while the order journal still held it, so the real result - arriving after
# the boundary, as a long Deck turn's does - was refused as no_such_command
# and the order stayed unconfirmed for its whole journal life. These cases
# drive the reference hub's in-memory model under a simulated clock so the
# 899/901/>1060-second boundary, the bounded retired set, the ownership
# binding and duplicate handling are all deterministic, no wall clock
# involved. The sibling regressions for the Rust hub live beside its model.
set -eu

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found (required by the stream hub)"; exit 0; }

python3 - "$ROOT/bin/fm-stream-hub.py" <<'PY'
import collections
import importlib.util
import sys
import threading
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("fm_stream_hub", sys.argv[1])
hub_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub_module)

# The simulated clock every age below is measured against. The hub's own
# module-level _now is swapped so reap/complete agree on one instant, exactly
# the way the deployed hub reads them, without waiting any wall time.
CLOCK = {"now": 1_000_000.0}
hub_module._now = lambda: CLOCK["now"]


def advance(seconds):
    CLOCK["now"] += seconds


def build():
    options = SimpleNamespace(command_ack_secs=5)
    hub = hub_module.Hub(options, {})
    machine = hub_module.Machine("box")
    hub.machines["box"] = machine
    endpoint = hub_module.Endpoint("a" * 32, "box", "worker", "/tmp", 24, 80,
                                   4096, 200, result_retry=True,
                                   command_capability="cap-1")
    hub.endpoints[endpoint.endpoint_id] = endpoint
    return hub, machine, endpoint


def place_taken_order(hub, machine, order_id, text="change course"):
    """Place an order whose command the agent has taken but not answered."""
    order = hub_module.Order(order_id, "box/worker", "a" * 32, text, "", None)
    hub.record_order(order)
    command = hub_module.Command("a" * 32, "box", "steer",
                                 {"text": text, "submit": True})
    order.command = command
    machine.pending[command.command_id] = command
    command.taken_at = hub_module._now()
    return order, command


def attempt(hub, machine, command, age, capability="cap-1"):
    """Age the taken command by `age` seconds, reap, then complete it."""
    command.taken_at = hub_module._now() - age
    hub.reap()
    return hub.complete_command("box", command.command_id, True, "", capability)


# --- the boundary itself -------------------------------------------------

hub, machine, endpoint = build()
order, command = place_taken_order(hub, machine, "boundary")
attempt(hub, machine, command, 899)
assert order.describe()["outcome"] == "accepted", order.describe()
assert command.done.is_set()
assert command.command_id not in machine.pending
assert machine.completed[command.command_id][0] is True

hub, machine, endpoint = build()
order, command = place_taken_order(hub, machine, "just-past")
attempt(hub, machine, command, 901)
assert order.describe()["outcome"] == "accepted", order.describe()
assert command.command_id in machine.completed

# The observed real-world case: a result ~1060.57s after placement. This is
# the exact regression the residual diagnosis reproduced offline.
hub, machine, endpoint = build()
order, command = place_taken_order(hub, machine, "uiviolet-timing")
attempt(hub, machine, command, 1060.5663512)
assert order.describe()["outcome"] == "accepted", order.describe()

# --- duplicate and ownership ---------------------------------------------

# A duplicate of an already-completed retired result is idempotent, not a
# conflict: same body, same verdict.
hub.complete_command("box", command.command_id, True, "", "cap-1")
assert order.describe()["outcome"] == "accepted"

# A DIFFERENT body for the same command id is refused, exactly as for a
# prompt completion: retirement never weakens result-conflict detection.
try:
    hub.complete_command("box", command.command_id, False, "changed story", "cap-1")
except hub_module.HubError as exc:
    assert exc.code == "result_conflict", exc.code
else:
    raise AssertionError("a conflicting duplicate result was accepted")

# The capability binding survives retirement: the endpoint's own capability
# is still required, and a wrong one is still refused.
hub, machine, endpoint = build()
order, command = place_taken_order(hub, machine, "owned")
command.taken_at = hub_module._now() - 901
hub.reap()
try:
    hub.complete_command("box", command.command_id, True, "", "not-the-capability")
except hub_module.HubError as exc:
    assert exc.code == "endpoint_unauthorized", exc.code
else:
    raise AssertionError("a wrong capability completed a retired command")

# --- bounded retention ----------------------------------------------------

# Retired entries age out of the retired set after the retention again: the
# answerable window is doubled, not infinite.
hub, machine, endpoint = build()
order, command = place_taken_order(hub, machine, "aged-out")
command.taken_at = hub_module._now() - 901
hub.reap()
assert machine.retired.get(command.command_id) is not None
advance(901)
hub.reap()
assert machine.retired.get(command.command_id) is None
try:
    hub.complete_command("box", command.command_id, True, "", "cap-1")
except hub_module.HubError as exc:
    assert exc.code == "no_such_command", exc.code
else:
    raise AssertionError("a retired entry past its own retention was completed")

# The retired set is capped: it cannot outgrow the journal it serves, and the
# OLDEST entries are the ones evicted.
hub, machine, endpoint = build()
for number in range(hub_module.RETIRED_COMMAND_MAX + 5):
    place_taken_order(hub, machine, "cap-%d" % number)
for command in list(machine.pending.values()):
    command.taken_at = hub_module._now() - 901
hub.reap()
assert len(machine.retired) == hub_module.RETIRED_COMMAND_MAX
first_id = next(iter(machine.retired))
assert first_id not in {"cap-%d" % number
                        for number in range(5)}, "the oldest entries must be evicted first"

# A command whose order has left the journal is not answerable through the
# retired path: the journal entry is what keeps the binding alive.
hub, machine, endpoint = build()
order, command = place_taken_order(hub, machine, "evicted")
command.taken_at = hub_module._now() - 901
hub.reap()
hub.orders.pop("evicted")
try:
    hub.complete_command("box", command.command_id, True, "", "cap-1")
except hub_module.HubError as exc:
    assert exc.code == "no_such_command", exc.code
else:
    raise AssertionError("a command with no journal order was completed")

print("PASS retirement boundary, real-order timing, duplicates, ownership, "
      "bounded retention, and journal binding")
PY
