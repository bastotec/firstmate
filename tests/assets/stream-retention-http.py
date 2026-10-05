#!/usr/bin/env python3
"""Exercise late results over real HTTP using the existing differential rig."""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
import time

ROOT = Path(sys.argv[1])
# The differential rig's binary argument is unused: this run starts Python.
spec = importlib.util.spec_from_file_location("differential", ROOT / "tests/assets/stream-hub-differential.py")
rig = importlib.util.module_from_spec(spec)
spec.loader.exec_module(rig)


def observe(name, response):
    print(json.dumps({"scenario": name, "response": response}, sort_keys=True), flush=True)


with tempfile.TemporaryDirectory(prefix="fm-retention-http-") as directory:
    lab = Path(directory)
    offset = lab / "clock"
    offset.write_text("0")
    p = rig.Pilot([sys.executable, str(ROOT / "tests/assets/stream-hub-test-clock.py"),
                   os.environ.get("FM_TEST_STREAM_HUB", str(ROOT / "bin/fm-stream-hub.py")), str(offset)], lab / "hub")
    clock = 0
    def advance(seconds):
        global clock
        clock += seconds
        pending = lab / "clock-next"
        pending.write_text(str(clock))
        pending.replace(offset)
        assert p.api("GET", "/v1/tasks")[0] == 200  # Production reap.
    def taken(oid):
        assert p.register(eid)[0] == 201
        with concurrent.futures.ThreadPoolExecutor() as pool:
            future = pool.submit(p.order, eid, oid)
            commands = []
            for _ in range(300):
                commands = p.take(eid)[1].get("commands", [])
                if commands:
                    break
                time.sleep(.005)
            assert len(commands) == 1, commands
            response = future.result()
            assert response[0] == 504 and response[1]["outcome"] == "unconfirmed", response
            return commands[0]["command_id"]
    eid = "a" * 32
    try:
        for age in (899, 901, 1060.5663512, 1061):
            oid = "boundary-" + str(age)
            cid = taken(oid)
            advance(age)
            before = p.api("GET", "/v1/orders/" + oid)
            assert before[1]["outcome"] == "unconfirmed" and before[1]["delivered"] is None, before
            observe(oid + " before native result", before)
            completion = p.result(cid, eid)
            observe(oid + " native result response", completion)
            assert completion[0] == 200, completion
            after = p.api("GET", "/v1/orders/" + oid)
            assert after[1]["outcome"] == "accepted" and after[1]["delivered"] is True, after
            observe(oid + " after native result", after)
            assert p.take(eid)[1]["commands"] == [], "late completion queued input again"
            assert p.result(cid, eid)[0] == 200
            conflict = p.result(cid, eid, False, "different result")
            assert conflict[0] == 409 and conflict[1]["error"] == "result_conflict", conflict
            observe(oid + " conflicting duplicate", conflict)

        cid = taken("ownership")
        advance(901)
        unauthorized = p.result(cid, eid, capability="wrong")
        assert unauthorized[0] == 403 and unauthorized[1]["error"] == "endpoint_unauthorized", unauthorized
        observe("retired wrong capability", unauthorized)
        assert p.api("GET", "/v1/orders/ownership")[1]["outcome"] == "unconfirmed"
        assert p.result(cid, eid)[0] == 200
        observe("retired valid capability", p.api("GET", "/v1/orders/ownership"))

        cid = taken("expiry")
        advance(901)
        advance(99)
        unauthorized = p.result(cid, eid, capability="wrong")
        assert unauthorized[0] == 403, unauthorized
        advance(802)
        expired = p.result(cid, eid)
        assert expired[0] == 404 and expired[1]["error"] == "no_such_command", expired
        assert p.api("GET", "/v1/orders/expiry")[1]["outcome"] == "unconfirmed"
        observe("wrong capability cannot renew expired command", expired)
        observe("expired order stays honestly unconfirmed", p.api("GET", "/v1/orders/expiry"))

        # More real taken orders than the journal can hold, plus commands that
        # have no order at all. Wrong-capability probes expose which ids remain
        # answerable without completing them or mutating their eligibility.
        ids = [taken("cap-" + str(number)) for number in range(517)]
        unrelated = []
        for kind in ("input", "status"):
            with concurrent.futures.ThreadPoolExecutor() as pool:
                payload = {"text": "not an order", "submit": True} if kind == "input" else {"state": "working"}
                future = pool.submit(p.api, "POST", "/v1/tasks/" + eid + "/" + kind, payload)
                commands = []
                for _ in range(300):
                    commands = p.take(eid)[1].get("commands", [])
                    if commands:
                        break
                    time.sleep(.005)
                assert len(commands) == 1, commands
                unrelated.append(commands[0]["command_id"])
                assert future.result()[0] == 504
        advance(901)
        eligible = []
        for cid in ids + unrelated:
            response = p.result(cid, eid, capability="wrong")
            expected = 403 if cid in ids[5:] else 404
            assert response[0] == expected, (cid, expected, response)
            if response[0] == 403:
                eligible.append(cid)
        assert eligible == ids[5:]
        assert p.result(ids[5], eid)[0] == 200
        observe("journal survivor completes after production reap", p.api("GET", "/v1/orders/cap-5"))
        observe("journal-evicted command is refused", p.result(ids[0], eid))
        for number in range(5):
            taken("replacement-" + str(number))
        assert p.api("GET", "/v1/tasks")[0] == 200
        for cid in ids[6:10]:
            response = p.result(cid, eid)
            assert response[0] == 404 and response[1]["error"] == "no_such_command", response
        assert p.result(ids[10], eid)[0] == 200
        observe("retired survivor after further journal eviction", p.api("GET", "/v1/orders/cap-10"))
        observe("bounded journal-only retirement", {"retained_command_ids": eligible,
                                                   "evicted_command_ids": ids[:5],
                                                   "unrelated_command_ids": unrelated})
    finally:
        p.close()
