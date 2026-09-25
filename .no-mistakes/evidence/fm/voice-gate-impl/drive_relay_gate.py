#!/usr/bin/env python3
"""Drive the real voice relay process end-to-end with the fast layer configured.

Spawns bin/fm-voice-relay.py --serve as a real process, speaks the real frame
protocol on its stdin/stdout, and stands in for the external local speech
stack with a real websocket server speaking the same minimal Realtime event
set the product's own offline suite scripts. The gate helper is a real stub
subprocess with the real helper's contract (FM_VOICE_GATE_HELPER).

Modes:
  shadow   two turns with a fast-answering helper: the turn never waits on the
           gate, the reply is byte-identical in shape, and shadow.log joins the
           fast verdict with what the heavy model actually did.
  hang     a helper that sleeps 25s past a 30s turn budget: the heavy reply
           still arrives in seconds (detached), and QUIT exits the relay
           promptly instead of joining the stuck helper thread.
  refuse   voice-gate-mode=act must refuse startup loudly naming the file.
"""
import asyncio
import base64
import json
import os
import pathlib
import shutil
import socket
import subprocess
import sys
import tempfile
import time

ROOT = pathlib.Path("/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M3BRKT89SJ4M6BA6HGX5MRX0")
EVIDENCE = pathlib.Path("/Users/bastotecnologia/.no-mistakes/evidence/01M3BRKT89SJ4M6BA6HGX5MRX0")
MAGIC = b"FMVOICE1"

def make_stub(case):
    """A stub with the real helper's contract. Python shebang and baked-in
    absolute debug paths, so a silent death is still visible."""
    debug = str(case / "stub-debug.log")
    stub = case / "stub-helper"
    stub.write_text(
        "#!/usr/bin/python3\n"
        "import json, os, sys, time\n"
        "with open(%r, 'a') as dbg:\n"
        "    dbg.write('start pid=%%d argv=%%r mode=%%r\\n' %% (os.getpid(), sys.argv, os.environ.get('FM_TEST_STUB_MODE')))\n"
        "req = json.load(sys.stdin)\n"
        "with open(%r, 'a') as log:\n"
        "    log.write('spawned %%d timeout=%%s\\n' %% (time.time(), os.environ.get('FM_VOICE_GATE_TIMEOUT_MS', '')))\n"
        "if os.environ.get('FM_TEST_STUB_MODE') == 'hang':\n"
        "    time.sleep(float(os.environ.get('FM_TEST_STUB_SLEEP', '25')))\n"
        "    sys.exit(0)\n"
        "sys.stdout.write('usage\\t1\\t713\\t112\\t360\\n')\n"
        "sys.stdout.write('answers\\treal_work\\t0.1000\\t0.9000\\t0.1000\\n')\n"
        % (debug, str(case / "stub.log")))
    stub.chmod(0o755)
    (case / "stub.log").write_text("")
    return stub


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


def make_case(mode):
    case = pathlib.Path(tempfile.mkdtemp(prefix="fm-gate-drive-"))
    (case / "config").mkdir()
    (case / "state").mkdir()
    cfg = case / "config"
    port = free_port()
    (cfg / "voice-engine").write_text("hybrid\n")
    (cfg / "voice-local-url").write_text("ws://127.0.0.1:%d/v1/realtime\n" % port)
    (cfg / "voice-gateway-url").write_text("http://127.0.0.1:9/v1\n")
    (cfg / "voice-gateway-model").write_text("fixture/text-route\n")
    (cfg / "voice-gate-key-var").write_text("GATE_TEST_KEY\n")
    if mode == "refuse":
        (cfg / "voice-gate-mode").write_text("act\n")
    else:
        (cfg / "voice-gate-mode").write_text("shadow\n")
    (case / "secrets").write_text("GATE_TEST_KEY=synthetic-not-a-key\n")
    make_stub(case)
    return case, port


class StackServer:
    """The local speech stack's minimal side of the Realtime protocol, in a thread."""

    def __init__(self, port, transcript="Please fix the login bug now."):
        self.port = port
        self.transcript = transcript
        self.thread = None

    def start(self):
        import threading

        def runner():
            loop = asyncio.new_event_loop()
            asyncio.set_event_loop(loop)
            loop.run_until_complete(self._serve())

        self.thread = threading.Thread(target=runner, daemon=True)
        self.thread.start()

    async def _serve(self):
        from websockets.asyncio.server import serve
        triggered = {}

        async def handler(ws):
            triggered[ws] = False
            await ws.send(json.dumps({"type": "session.created"}))
            async for raw in ws:
                event = json.loads(raw)
                kind = event.get("type")
                if kind == "session.update":
                    rate = event["session"]["audio"]["output"]["format"]["rate"]
                    assert rate == 24000, "relay must request the unchanged 24k wire rate"
                    await ws.send(json.dumps({"type": "session.updated"}))
                elif kind == "input_audio_buffer.append":
                    pcm = base64.b64decode(event["audio"])
                    if any(pcm):
                        triggered[ws] = False
                    elif not triggered[ws]:
                        triggered[ws] = True
                        await ws.send(json.dumps({
                            "type": "conversation.item.input_audio_transcription.completed",
                            "transcript": self.transcript}))
                        await ws.send(json.dumps({
                            "type": "response.output_audio.delta",
                            "delta": base64.b64encode(b"\x01\x02" * 240).decode()}))
                        await ws.send(json.dumps({
                            "type": "response.output_audio_transcript.done",
                            "transcript": "On it."}))
                        await ws.send(json.dumps({
                            "type": "response.done", "response": {"status": "completed"}}))

        async with serve(handler, "127.0.0.1", self.port):
            await asyncio.Future()  # serve until cancelled


class Client:
    """The laptop client's side of the frame stream."""

    def __init__(self, proc):
        self.proc = proc
        self.frames = []

    def read_magic(self):
        buf = b""
        while not buf.startswith(MAGIC):
            chunk = self.proc.stdout.read(1)
            if not chunk:
                raise RuntimeError("relay died before MAGIC: %r" % buf)
            buf += chunk

    def read_frame(self, timeout=10):
        header = self._exact(5, timeout)
        kind, length = header[0:1], int.from_bytes(header[1:5], "big")
        payload = self._exact(length, timeout) if length else b""
        self.frames.append((time.monotonic(), kind, payload))
        return kind, payload

    def _exact(self, count, timeout):
        deadline = time.monotonic() + timeout
        buf = b""
        while len(buf) < count:
            self.proc.stdout.flush() if False else None
            import select
            left = deadline - time.monotonic()
            if left <= 0:
                raise RuntimeError("timeout reading %d bytes, got %r" % (count, buf))
            ready, _, _ = select.select([self.proc.stdout], [], [], left)
            if not ready:
                raise RuntimeError("timeout reading %d bytes, got %r" % (count, buf))
            chunk = os.read(self.proc.stdout.fileno(), count - len(buf))
            if not chunk:
                raise RuntimeError("relay stdout closed at %r" % buf)
            buf += chunk
        return buf

    def send(self, kind, payload=b""):
        self.proc.stdin.write(kind + len(payload).to_bytes(4, "big") + payload)
        self.proc.stdin.flush()


def turn(client, label):
    began = time.monotonic()
    client.send(b"S")
    client.send(b"A", b"\x01\x02" * 1600)   # 100 ms of non-silent 16 kHz PCM
    client.send(b"E")
    seen = {"user": None, "assistant": None, "audio": 0, "reply_end": None,
            "notice": []}
    while True:
        kind, payload = client.read_frame(timeout=15)
        if kind == b"T":
            text = json.loads(payload)
            if text["role"] == "USER":
                seen["user"] = text["text"]
            else:
                seen["assistant"] = text["text"]
        elif kind == b"A":
            seen["audio"] += len(payload)
        elif kind == b"M":
            mark = json.loads(payload)
            if mark.get("mark") == "reply_end":
                seen["reply_end"] = time.monotonic() - began
        elif kind == b"V":
            seen["notice"].append(json.loads(payload))
        elif kind == b"B":
            raise RuntimeError("unexpected BYE mid-turn")
        if seen["reply_end"] is not None and seen["assistant"] is not None:
            break
    return seen


def run(mode, relay_path, out):
    case, port = make_case(mode)
    log = lambda *a: print(*a, file=out, flush=True)
    log("case home: %s" % case)
    log("relay: %s" % relay_path)

    server = StackServer(port)
    server.start()
    time.sleep(0.3)
    env = os.environ.copy()
    env["FM_VOICE_GATE_HELPER"] = os.environ.get("DRIVE_FORCE_HELPER") or str(case / "stub-helper")
    # The pre-fix regression relay lives outside bin/ and still needs the
    # unchanged sibling modules; its own dir is always first on its path.
    env["PYTHONPATH"] = str(ROOT / "bin")
    env["FM_VOICE_GATE_SECRETS"] = str(case / "secrets")
    env["FM_TEST_STUB_LOG"] = str(case / "stub.log")
    env["FM_TEST_STUB_MODE"] = "hang" if mode == "hang" else "answer"
    began = time.monotonic()
    proc = subprocess.Popen(
        [sys.executable, str(relay_path), "--serve", "--home", str(case),
         "--turn-timeout", "30"],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        env=env)
    client = Client(proc)
    try:
        if mode == "refuse":
            code = proc.wait(timeout=15)
            err = proc.stderr.read().decode()
            log("exit=%d" % code)
            log("stderr: %s" % err.strip())
            ok = (code == 2 and "voice-gate-mode" in err and "shadow" in err
                  and "act" in err)
            log("REFUSE_OK=%s" % ok)
            return 0 if ok else 1

        client.read_magic()
        kind, payload = client.read_frame(timeout=15)
        ready = json.loads(payload)
        log("ready notice: %s" % ready)
        assert kind == b"V" and ready["event"] == "ready", ready

        stub_mode = "hang" if mode == "hang" else "answer"
        # Turn 1: the gate's first decision is the cold start (no helper call).
        one = turn(client, "one")
        log("turn1: user=%r assistant=%r audio_bytes=%d reply_end=%.2fs notices=%d"
            % (one["user"], one["assistant"], one["audio"], one["reply_end"],
               len(one["notice"])))
        stub_calls_after_one = len((case / "stub.log").read_text().splitlines())
        log("helper spawns after turn 1: %d (cold start spends none)" % stub_calls_after_one)

        # Turn 2: a real helper run. In hang mode it sleeps 25s of a 30s
        # budget, so a reply inside seconds proves the turn never waits on it.
        two = turn(client, "two")
        log("turn2: user=%r assistant=%r audio_bytes=%d reply_end=%.2fs"
            % (two["user"], two["assistant"], two["audio"], two["reply_end"]))
        stub_calls = len((case / "stub.log").read_text().splitlines())
        log("helper spawns after turn 2: %d" % stub_calls)

        # In answer mode the detached shadow decision still lands after the
        # reply; a captain pauses between turns, so wait for the row before
        # quitting. In hang mode the helper never answers on purpose: QUIT
        # with the call still in flight is the teardown this run proves.
        if mode != "hang":
            shadow_path = case / "state" / "voice-gate" / "shadow.log"
            began_wait = time.monotonic()
            deadline = began_wait + 15
            while time.monotonic() < deadline:
                rows = (shadow_path.read_text().splitlines()
                        if shadow_path.exists() else [])
                if len(rows) >= 2:
                    log("shadow rows settled %.2fs after turn 2 reply"
                        % (time.monotonic() - began_wait))
                    break
                time.sleep(0.1)
            else:
                log("shadow rows did not settle: %r"
                    % (shadow_path.read_text().splitlines() if shadow_path.exists() else []))

        # QUIT: teardown. In hang mode the helper is still mid-call here; a
        # short pause first puts it verifiably mid-sleep (its debug line is
        # written once its interpreter is up), so the kill cuts a live call.
        if mode == "hang":
            deadline = time.monotonic() + 5
            debug = case / "stub-debug.log"
            while time.monotonic() < deadline:
                if debug.exists() and debug.read_text().splitlines():
                    log("helper is alive and mid-sleep: %r"
                        % debug.read_text().splitlines()[-1])
                    break
                time.sleep(0.05)
        quit_at = time.monotonic()
        client.send(b"Q")
        bye_kind, _ = client.read_frame(timeout=10)
        log("BYE after QUIT: %s (%.2fs)" % (bye_kind == b"B", time.monotonic() - quit_at))
        code = proc.wait(timeout=40)
        exit_s = time.monotonic() - quit_at
        log("relay exit=%d %.2fs after QUIT" % (code, exit_s))
        stderr = proc.stderr.read().decode().strip()
        if stderr:
            log("relay stderr: %s" % stderr)

        shadow = case / "state" / "voice-gate" / "shadow.log"
        usage = case / "state" / "voice-gate" / "usage.log"
        log("shadow.log:")
        for line in (shadow.read_text().splitlines() if shadow.exists() else ["<absent>"]):
            log("  %s" % line)
        log("usage.log:")
        for line in (usage.read_text().splitlines() if usage.exists() else ["<absent>"]):
            log("  %s" % line)

        leftover = subprocess.run(["pgrep", "-f", str(case / "stub-helper")],
                                  capture_output=True, text=True)
        log("leftover helper processes: %r" % leftover.stdout.strip())
        debug = case / "stub-debug.log"
        log("stub-debug.log:")
        for line in (debug.read_text().splitlines() if debug.exists() else ["<absent>"]):
            log("  %s" % line)

        rows = ([l.split("\t") for l in shadow.read_text().splitlines()]
                if shadow.exists() else [])
        ok = (code == 0 and one["user"] and one["assistant"] and one["audio"] > 0
              and two["user"] and two["assistant"] and two["audio"] > 0
              and len(rows) >= 1 and rows[0][3] == "heavy" and rows[0][4] == "cold-start"
              and rows[0][12] == "answered")
        if stub_mode == "answer":
            ok = ok and len(rows) >= 2 and rows[1][3] == "fast-handover" \
                and rows[1][12] == "answered" and rows[1][11] != "-"
        if mode == "hang":
            ok = ok and exit_s < 5 and two["reply_end"] < 5
        log("%s_OK=%s" % (mode.upper(), ok))
        return 0 if ok else 1
    finally:
        if proc.poll() is None:
            proc.kill()
        kept = (EVIDENCE / ("relay-gate-%s-case-kept" % mode)).exists()
        if not kept:
            shutil.rmtree(case, ignore_errors=True)
        else:
            log("KEEPING case dir for inspection: %s" % case)


def main():
    mode = sys.argv[1]
    relay = sys.argv[2] if len(sys.argv) > 2 else str(ROOT / "bin" / "fm-voice-relay.py")
    out_path = EVIDENCE / ("relay-gate-%s-transcript.txt" % mode)
    with open(out_path, "w") as out:
        code = run(mode, pathlib.Path(relay), out)
    print("transcript: %s" % out_path)
    return code


if __name__ == "__main__":
    sys.exit(main())
