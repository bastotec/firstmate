#!/usr/bin/env python3
"""Measure how `fm-stream-agent attach` feels: keystroke echo and redraw paint.

Usage: stream-attach-bench.py NATIVE_DIR [--rtt-ms N] [--path auto|hub]
                              [--keys N] [--redraws N] [--rows N] [--cols N]

Starts a disposable native hub (loopback, ephemeral port, private token), puts
a latency proxy in front of it that delays every chunk by half the requested
round trip in each direction (the ssh tunnel to a remote hub), and starts a
native agent whose endpoint runs a tiny raw-mode program: it echoes each key it
reads, draws a full screen of `rows` colored lines in ONE write on `r`, and
exits on `q`. Agent and attach client both reach the hub through the proxy.

It then attaches from a real pseudoterminal and reports:
  echo     keystroke written -> the same byte read back from the attach client
  redraw   `r` written -> last byte of the frame read back (total), and the
           paint spread: first frame byte -> last frame byte. A spread above one
           display frame (~16 ms) is what shows as line-by-line painting.

--path hub forces the hub round trip (FM_STREAM_ATTACH_LOCAL=0); auto lets the
client take the same-machine socket when the agent offers one. Nothing deployed
is touched. Prints one JSON object.
"""
import argparse
import asyncio
import json
import os
import pty
import secrets
import select
import statistics
import struct
import subprocess
import sys
import tempfile
import threading
import time
import fcntl
import termios
import urllib.request

ENDPOINT_PROGRAM = r'''
import os, sys, tty
rows, cols = int(sys.argv[1]), int(sys.argv[2])
tty.setraw(0)
out = sys.stdout.buffer
count = 0
def frame(n):
    parts = ["\x1b[H\x1b[2JFRAME-START"]
    for i in range(1, rows):
        text = ("line %03d " % i) + ("abcdefghij" * 30)
        parts.append("\x1b[%d;1H\x1b[38;5;%dm%s\x1b[0m" % (i + 1, 16 + i % 200, text[:cols - 12]))
    parts.append("FRAME-END-%d" % n)
    return "".join(parts).encode()
out.write(b"BENCH-READY")
out.flush()
while True:
    data = os.read(0, 1024)
    if not data:
        break
    for byte in data:
        key = bytes([byte])
        if key == b"q":
            sys.exit(0)
        if key == b"r":
            count += 1
            out.write(frame(count))
        else:
            out.write(key)
        out.flush()
'''


class Proxy:
    """Delay every chunk by `delay` seconds per direction, preserving order."""

    def __init__(self, target_port, delay):
        self.target_port = target_port
        self.delay = delay
        self.loop = asyncio.new_event_loop()
        self.port = None
        ready = threading.Event()
        threading.Thread(target=self._run, args=(ready,), daemon=True).start()
        ready.wait()

    def _run(self, ready):
        asyncio.set_event_loop(self.loop)

        async def start():
            server = await asyncio.start_server(self._client, "127.0.0.1", 0)
            self.port = server.sockets[0].getsockname()[1]
            ready.set()
            await server.serve_forever()

        self.loop.run_until_complete(start())

    async def _pipe(self, reader, writer):
        queue = asyncio.Queue()

        async def pump():
            while True:
                due, data = await queue.get()
                if data is None:
                    writer.close()
                    return
                wait = due - time.monotonic()
                if wait > 0:
                    await asyncio.sleep(wait)
                writer.write(data)
                await writer.drain()

        task = asyncio.ensure_future(pump())
        try:
            while True:
                data = await reader.read(65536)
                await queue.put((time.monotonic() + self.delay, data or None))
                if not data:
                    break
        except Exception:
            await queue.put((0, None))
        await task

    async def _client(self, reader, writer):
        try:
            upstream_reader, upstream_writer = await asyncio.open_connection("127.0.0.1", self.target_port)
        except Exception:
            writer.close()
            return
        await asyncio.gather(self._pipe(reader, upstream_writer), self._pipe(upstream_reader, writer),
                             return_exceptions=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("native")
    parser.add_argument("--rtt-ms", type=float, default=10.0)
    parser.add_argument("--path", choices=["auto", "hub"], default="hub")
    parser.add_argument("--keys", type=int, default=40)
    parser.add_argument("--redraws", type=int, default=15)
    parser.add_argument("--rows", type=int, default=200)
    parser.add_argument("--cols", type=int, default=120)
    args = parser.parse_args()
    native = os.path.abspath(args.native)
    lab = tempfile.mkdtemp(prefix="fm-attach-bench-")
    token = secrets.token_hex(16)
    procs = []

    def wait_file(path, secs=20):
        end = time.time() + secs
        while time.time() < end:
            if os.path.exists(path) and os.path.getsize(path) > 0:
                return open(path).read().split()
            time.sleep(0.02)
        sys.exit("timed out waiting for " + path)

    try:
        token_file = os.path.join(lab, "token")
        with open(token_file, "w") as handle:
            handle.write(token + "\n")
        os.chmod(token_file, 0o600)
        with open(os.path.join(lab, "endpoint.py"), "w") as handle:
            handle.write(ENDPOINT_PROGRAM)
        os.makedirs(os.path.join(lab, "cwd"))
        procs.append(subprocess.Popen(
            [native + "/fm-stream-hub", "serve", "--bind", "127.0.0.1", "--port", "0",
             "--ready-file", lab + "/hub.ready", "--pid-file", lab + "/hub.pid"],
            env=dict(os.environ, FM_STREAM_TOKEN=token), stdout=subprocess.DEVNULL,
            stderr=open(lab + "/hub.log", "w")))
        _, hub_port = wait_file(lab + "/hub.ready")
        proxy = Proxy(int(hub_port), args.rtt_ms / 2000.0)
        url = "http://127.0.0.1:%d" % proxy.port
        agent_env = dict(os.environ, SHELL="/bin/bash", TERM="xterm-256color")
        agent_env.pop("FM_STREAM_TOKEN", None)
        procs.append(subprocess.Popen(
            [native + "/fm-stream-agent", "serve", "--hub", url, "--token-file", token_file,
             "--machine", "bench", "--label", "bench-%d" % os.getpid(), "--cwd", lab + "/cwd",
             "--ready-file", lab + "/agent.ready", "--rows", str(args.rows), "--cols", str(args.cols)],
            env=agent_env, stdout=subprocess.DEVNULL, stderr=open(lab + "/agent.log", "w")))
        _, endpoint = wait_file(lab + "/agent.ready")

        def api(method, path, body=None):
            request = urllib.request.Request(
                url + path, method=method, data=None if body is None else json.dumps(body).encode(),
                headers={"Authorization": "Bearer " + token, "Content-Type": "application/json"})
            with urllib.request.urlopen(request, timeout=20) as response:
                return response.read().decode()

        api("POST", "/v1/tasks/%s/input" % endpoint,
            {"text": "exec %s %s/endpoint.py %d %d" % (sys.executable, lab, args.rows, args.cols),
             "submit": True})
        end = time.time() + 15
        while "BENCH-READY" not in api("GET", "/v1/tasks/%s/capture?lines=5" % endpoint):
            if time.time() > end:
                sys.exit("the endpoint program never started")
            time.sleep(0.05)

        env = dict(os.environ, FM_STREAM_TOKEN=token, TERM="xterm-256color")
        if args.path == "hub":
            env["FM_STREAM_ATTACH_LOCAL"] = "0"
        pid, master = pty.fork()
        if pid == 0:
            fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", args.rows, args.cols, 0, 0))
            os.execve(native + "/fm-stream-agent",
                      [native + "/fm-stream-agent", "attach", "--hub", url, "--endpoint", endpoint], env)
        seen = bytearray()
        arrivals = []

        def pump(until):
            """Read whatever arrives before `until`; True when the predicate holds."""
            ready, _, _ = select.select([master], [], [], max(0.0, until - time.monotonic()))
            if ready:
                chunk = os.read(master, 1 << 20)
                arrivals.append((time.monotonic(), len(seen), len(chunk)))
                seen.extend(chunk)
                return True
            return False

        def read_until(needle, start, secs=10):
            end = time.monotonic() + secs
            while needle not in seen[start:]:
                if time.monotonic() > end:
                    sys.exit("timed out waiting for %r; tail %r" % (needle, bytes(seen[-300:])))
                pump(end)
            return time.monotonic()

        read_until(b"BENCH-READY", 0, 15)
        # Let the attach settle (initial resize redraws, snapshot paint).
        settle = time.monotonic() + 0.5
        while time.monotonic() < settle:
            pump(settle)

        echoes = []
        for index in range(args.keys):
            key = b"abcdefghijklmnopstuvwxyz"[index % 24:index % 24 + 1]
            start = len(seen)
            sent = time.monotonic()
            os.write(master, key)
            echoes.append((read_until(key, start) - sent) * 1000)
            time.sleep(0.05)

        totals, spreads, chunks = [], [], []
        frame_bytes = None
        for count in range(1, args.redraws + 1):
            start = len(seen)
            mark = len(arrivals)
            sent = time.monotonic()
            os.write(master, b"r")
            done = read_until(b"FRAME-END-%d" % count, start)
            frame_arrivals = arrivals[mark:]
            first = frame_arrivals[0][0]
            frame_bytes = len(seen) - start
            totals.append((done - sent) * 1000)
            spreads.append((done - first) * 1000)
            chunks.append(len(frame_arrivals))
            time.sleep(0.1)
        os.write(master, b"\x1d")
        try:
            os.waitpid(pid, 0)
        except ChildProcessError:
            pass

        def summary(values):
            values = sorted(values)
            return {"median": round(statistics.median(values), 1),
                    "p90": round(values[int(len(values) * 0.9) - 1], 1),
                    "max": round(values[-1], 1)}

        print(json.dumps({
            "native": native, "path": args.path, "rtt_ms": args.rtt_ms,
            "frame_bytes": frame_bytes,
            "echo_ms": summary(echoes),
            "redraw_total_ms": summary(totals),
            "redraw_spread_ms": summary(spreads),
            "redraw_reads": summary(chunks),
        }))
    finally:
        for proc in procs:
            proc.terminate()
            try:
                proc.wait(5)
            except Exception:
                proc.kill()


if __name__ == "__main__":
    main()
