#!/usr/bin/env python3
"""Manual live driver: the shipped hybrid relay pipeline with the fast layer on.

Drives the real bin/fm-voice-relay.py HybridSession (real asyncio loop, real
frame protocol, real TurnBudget, real gate wiring) over a scripted local
Realtime server, with the fan-out helper stubbed at the vendor boundary (the
same boundary the shipped offline suite stubs), plus one fully-unstubbed pass
through the real bin/voice-gate/jev-route.mjs against the real network.
"""
import asyncio
import base64
import importlib.util
import json
import os
import pathlib
import sys
import time
import types

WORKTREE = pathlib.Path(
    "/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/"
    "01M3BJZZD5DANB9V3XAPQTW5YS")
BIN = WORKTREE / "bin"
ROOT = pathlib.Path("/tmp/fm-vg-live")

STUB = """#!/usr/bin/env bash
set -u
req=$(cat)
printf 'timeout=%s request=%s\\n' "${FM_VOICE_GATE_TIMEOUT_MS:-}" "$req" >> "${FM_TEST_STUB_LOG:?}"
if [ "${FM_TEST_STUB_MODE:-ok}" = sleep ]; then sleep "${FM_TEST_STUB_SLEEP:-3}"; fi
printf 'usage\\t1\\t%s\\t%s\\t%s\\n' "${FM_TEST_STUB_IN:-713}" "${FM_TEST_STUB_OUT:-112}" "${FM_TEST_STUB_MS:-360}"
printf 'answers\\t%s\\t%s\\t%s\\t%s\\n' "${FM_TEST_STUB_INTENT:-status_query}" \\
  "${FM_TEST_STUB_NR:-0.9000}" "${FM_TEST_STUB_HO:-0.1000}" "${FM_TEST_STUB_AF:-0.2000}"
"""

failures = []


def check(cond, label):
    status = "ok" if cond else "FAIL"
    print("  [{}] {}".format(status, label))
    if not cond:
        failures.append(label)


def make_home(name, gate=True):
    home = ROOT / name
    config = home / "config"
    config.mkdir(parents=True, exist_ok=True)
    (config / "voice-engine").write_text("hybrid\n")
    (config / "voice-local-url").write_text("ws://127.0.0.1:45678/v1/realtime\n")
    (config / "voice-gateway-url").write_text("http://127.0.0.1:8329/v1\n")
    (home / "secrets").write_text("GATE_TEST_KEY=synthetic-not-a-real-key\n")
    if gate:
        (config / "voice-gate-key-var").write_text("GATE_TEST_KEY\n")
    stub = home / "stub-helper"
    stub.write_text(STUB)
    stub.chmod(0o755)
    (home / "stub.log").write_text("")
    return home


def load_relay():
    # Pops every FM_VOICE_* from the environment, so callers set their gate
    # environment AFTER this returns.
    for key in list(os.environ):
        if key.startswith("FM_VOICE_") or key == "FM_CONFIG_OVERRIDE":
            os.environ.pop(key)
    spec = importlib.util.spec_from_file_location("relay", BIN / "fm-voice-relay.py")
    relay = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(relay)
    for name in ("websockets", "websockets.asyncio", "websockets.asyncio.client"):
        sys.modules[name] = types.ModuleType(name)

    class Wire:
        def __init__(self, driver):
            self.events = asyncio.Queue()
            self.events.put_nowait(json.dumps({"type": "session.created"}))
            self.sent = []
            self.closed = False
            self.triggered = False
            self.driver = driver

        async def recv(self):
            return await self.events.get()

        def __aiter__(self):
            return self

        async def __anext__(self):
            return await self.recv()

        def put(self, **event):
            self.events.put_nowait(json.dumps(event))

        async def send(self, raw):
            event = json.loads(raw)
            self.sent.append(event)
            if event["type"] == "session.update":
                self.put(type="session.updated")
            elif event["type"] == "input_audio_buffer.append":
                pcm = base64.b64decode(event["audio"])
                if any(pcm):
                    self.triggered = False
                elif not self.triggered:
                    self.triggered = True
                    self.driver.on_transcript(self)
            elif event["type"] == "response.create":
                self.driver.on_response_create(self)

        async def close(self):
            self.closed = True

    async def connect(url, **kwargs):
        wire = Wire(driver_holder["driver"])
        return wire

    sys.modules["websockets.asyncio.client"].connect = connect
    return relay


driver_holder = {}


class ScriptedServer:
    """The local Realtime server: each spoken turn runs the next script."""

    def __init__(self, scripts):
        self.scripts = list(scripts)

    def on_transcript(self, wire):
        script = self.scripts.pop(0)
        wire.put(type="conversation.item.input_audio_transcription.completed",
                 transcript=script["transcript"])
        if script.get("tool"):
            wire.put(type="response.function_call_arguments.done",
                     name="hand_over_to_firstmate", call_id="call-fixture",
                     arguments=json.dumps({"request": "Please check this."}))
            wire.put(type="response.done", response={"status": "completed"})
        else:
            self.reply(wire)

    def on_response_create(self, wire):
        self.reply(wire)

    def reply(self, wire):
        wire.put(type="response.output_audio.delta",
                 delta=base64.b64encode(b"\x01\x02" * 240).decode())
        wire.put(type="response.output_audio_transcript.done", transcript="A reply.")
        wire.put(type="response.done", response={"status": "completed"})


class Sink:
    def arm_turn(self):
        pass

    def arm_response(self):
        pass

    def send(self, *args):
        pass

    def send_json(self, *args):
        pass

    def first_audio(self):
        return None


def read_rows(home, name):
    path = home / "state" / "voice-gate" / name
    if not path.exists():
        return []
    return [line.split("\t") for line in path.read_text().splitlines() if line.strip()]


async def drive_enabled(home, turn_timeout):
    """One session, four spoken turns, the gate on: the shipped pipeline."""
    relay = load_relay()
    os.environ.update(FM_VOICE_GATE_HELPER=str(home / "stub-helper"),
                      FM_VOICE_GATE_SECRETS=str(home / "secrets"),
                      FM_TEST_STUB_LOG=str(home / "stub.log"))
    scripts = [
        {"transcript": "Hello there."},                                   # cold-start
        {"transcript": "Fix the login bug and open a pull request."},     # fast-handover x answered
        {"transcript": "Please hand this to the first mate.", "tool": True},  # fast-handover x tool
        {"transcript": "What is in flight right now?"},                   # slow helper, turn never waits
    ]
    driver_holder["driver"] = ScriptedServer(scripts)
    queued = []
    relay.records.queue_request = lambda *a, **k: (queued.append(a), {"queued": True})[1]

    opts = relay.resolve_settings(relay.parse_args(
        ["--home", str(home), "--turn-timeout", str(turn_timeout)]))
    check(getattr(opts, "gate", None) is not None and opts.gate.enabled,
          "resolve_settings built an enabled gate for the opted-in home")
    sink = Sink()
    session = relay.make_session(opts, sink)
    await session.start()
    timings = []
    for index in range(4):
        os.environ["FM_TEST_STUB_MODE"] = "sleep" if index == 3 else "ok"
        os.environ["FM_TEST_STUB_SLEEP"] = "3"
        os.environ["FM_TEST_STUB_INTENT"] = "real_work"
        os.environ["FM_TEST_STUB_NR"] = "0.1000"
        os.environ["FM_TEST_STUB_HO"] = "0.9000"
        os.environ["FM_TEST_STUB_AF"] = "0.1000"
        session, _ = await relay.handle_uplink_frame(
            relay.frame.TALK_START, b"", session, opts, sink)
        await session.audio(b"\x01\x02" * 320)
        began = time.monotonic()
        await session.talk_end()
        await asyncio.wait_for(session.turn_done.wait(), 10)
        elapsed = time.monotonic() - began
        timings.append(elapsed)
        if session.gate_task is not None:
            await asyncio.wait_for(session.gate_task, 15)
    await session.close()
    return timings, read_rows(home, "shadow.log"), read_rows(home, "usage.log"), len(queued)


async def drive_inert(home):
    """The same spoken turn with the opt-in file absent: no gate at all."""
    relay = load_relay()
    os.environ.update(FM_VOICE_GATE_HELPER=str(home / "stub-helper"),
                      FM_VOICE_GATE_SECRETS=str(home / "secrets"),
                      FM_TEST_STUB_LOG=str(home / "stub.log"))
    driver_holder["driver"] = ScriptedServer([{"transcript": "Hello there."}])
    opts = relay.resolve_settings(relay.parse_args(["--home", str(home)]))
    check(opts.gate is not None and not opts.gate.enabled,
          "a home without the opt-in file keeps the gate disabled")
    sink = Sink()
    session = relay.make_session(opts, sink)
    await session.start()
    session, _ = await relay.handle_uplink_frame(
        relay.frame.TALK_START, b"", session, opts, sink)
    await session.audio(b"\x01\x02" * 320)
    await session.talk_end()
    await asyncio.wait_for(session.turn_done.wait(), 10)
    check(session.replies == 1, "the inert-gate turn still answered")
    await session.close()
    check(not (home / "state" / "voice-gate").exists(),
          "the inert gate wrote no state at all")
    check((home / "stub.log").read_text() == "",
          "the inert gate reached no helper")


async def drive_real_helper(home):
    """The fully-unstubbed pass: the real jev-route.mjs, real runtime, real
    network, synthetic key. One direct decide and one turn through the relay."""
    relay = load_relay()
    os.environ["FM_VOICE_GATE_SECRETS"] = str(home / "secrets")
    driver_holder["driver"] = ScriptedServer([{"transcript": "Status please."}])
    opts = relay.resolve_settings(relay.parse_args(["--home", str(home)]))
    check(opts.gate.enabled, "the real-helper home has the gate on")
    fast = opts.gate
    first = fast.decide("hello", 8.0)
    check(first.why == "cold-start", "first decision is the cold-start skip")
    began = time.monotonic()
    decision = fast.decide("what is in flight", 8.0)
    took = time.monotonic() - began
    print("  real helper: route={} why={} calls={} took={:.2f}s".format(
        decision.route, decision.why, decision.calls, took))
    check(decision.route == "heavy",
          "the real helper with a synthetic key must fail open to heavy")
    check(took < 8.0, "the caller's bound was respected by the real helper")
    sink = Sink()
    session = relay.make_session(opts, sink)
    await session.start()
    session, _ = await relay.handle_uplink_frame(
        relay.frame.TALK_START, b"", session, opts, sink)
    await session.audio(b"\x01\x02" * 320)
    await session.talk_end()
    await asyncio.wait_for(session.turn_done.wait(), 10)
    check(session.replies == 1, "the real-helper turn still answered")
    if session.gate_task is not None:
        await asyncio.wait_for(session.gate_task, 15)
    await session.close()


async def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    enabled = make_home("enabled")
    print("== enabled gate on the shipped hybrid pipeline (stubbed vendor) ==")
    timings, shadow, usage, queued = await drive_enabled(enabled, 2.0)
    print("  turn timings: " + ", ".join("{:.2f}s".format(x) for x in timings))
    print("  shadow rows:")
    for row in shadow:
        print("    " + " | ".join(row[1:5] + [row[11], row[12]]))
    print("  usage rows:")
    for row in usage:
        print("    " + " | ".join(row[1:]))
    check(len(shadow) == 4, "four spoken turns wrote exactly four shadow rows")
    if len(shadow) == 4:
        check(shadow[0][3:5] == ["heavy", "cold-start"] and shadow[0][12] == "answered",
              "turn 1: cold-start routes up beside an answered heavy turn")
        check(shadow[1][3:5] == ["fast-handover", "hand-over"]
              and shadow[1][11] == "Handing that to the first mate. It is queued."
              and shadow[1][12] == "answered",
              "turn 2: real work at 0.90 shadows fast-handover with the spoken line")
        check(shadow[2][3] == "fast-handover" and shadow[2][12] == "hand_over_to_firstmate",
              "turn 3: the handover tool turn joins the fast verdict to the tool name")
        check(shadow[3][3:5] == ["heavy", "helper-timeout"] and shadow[3][12] == "answered",
              "turn 4: a helper past its bound routes up and the row still lands")
    check(timings[3] < 1.2,
          "the slow-helper turn answered in {:.2f}s, far under its 3s helper".format(timings[3]))
    stub_calls = (enabled / "stub.log").read_text().splitlines()
    check(len(stub_calls) == 3,
          "exactly three helper calls: one per non-cold decision ({})".format(len(stub_calls)))
    check(all("timeout=" in line
              and 0 < int(line.split("=", 1)[1].split(" ", 1)[0])
              for line in stub_calls),
          "every helper call carried the caller's bound in milliseconds")
    check(queued == 1, "the handover tool ran exactly once")

    inert = make_home("inert", gate=False)
    print("== inert home: no opt-in file, spoken turn unchanged ==")
    await drive_inert(inert)

    real = make_home("real")
    print("== real helper, real runtime, real network, synthetic key ==")
    await drive_real_helper(real)
    shadow = read_rows(real, "shadow.log")
    usage = read_rows(real, "usage.log")
    print("  shadow rows: " + repr([" ".join(r[3:5] + [r[12]]) for r in shadow]))
    print("  usage rows: " + repr([" ".join(r[1:]) for r in usage]))
    if shadow:
        check(shadow[-1][3] == "heavy" and shadow[-1][12] == "answered",
              "the real-helper turn's shadow row joined an answered heavy turn")

    if failures:
        print("DRIVER FAILURES: " + repr(failures))
        return 1
    print("all driver checks passed")
    return 0


sys.exit(asyncio.run(main()))
