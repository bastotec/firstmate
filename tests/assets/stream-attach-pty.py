#!/usr/bin/env python3
"""Drive `fm-stream.sh attach --interactive` from a real pseudoterminal.

Usage: stream-attach-pty.py ROOT NATIVE_DIR LAB

Starts a disposable native hub (loopback, ephemeral port, private token) and a
native agent running bash, then attaches through firstmate's own entry point
and proves: the existing screen is painted on connect, keystrokes reach the
child, a local resize reaches the child's PTY (`stty size`), and the detach key
leaves the endpoint running. Exits non-zero with a reason on the first failure.
"""
import fcntl
import json
import os
import pty
import secrets
import select
import struct
import subprocess
import sys
import termios
import time
import urllib.request

ROOT, NATIVE, LAB = sys.argv[1:4]
TOKEN = secrets.token_hex(16)
procs = []


def fail(message):
    print("FAIL: " + message, file=sys.stderr)
    sys.exit(1)


def wait_file(path, secs=20):
    end = time.time() + secs
    while time.time() < end:
        if os.path.exists(path) and os.path.getsize(path) > 0:
            return open(path).read().split()
        time.sleep(0.05)
    fail("timed out waiting for " + path)


def api(method, path, body=None):
    request = urllib.request.Request(
        URL + path, method=method,
        data=None if body is None else json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/json"})
    with urllib.request.urlopen(request, timeout=20) as response:
        data = response.read()
    return data.decode()


def cleanup():
    for proc in procs:
        try:
            proc.terminate()
            proc.wait(5)
        except Exception:
            proc.kill()


os.makedirs(LAB + "/home/config", exist_ok=True)
os.makedirs(LAB + "/home/state", exist_ok=True)
os.makedirs(LAB + "/cwd", exist_ok=True)
token_file = LAB + "/token"
with open(token_file, "w") as handle:
    handle.write(TOKEN + "\n")
os.chmod(token_file, 0o600)
env = dict(os.environ, FM_STREAM_TOKEN=TOKEN)
try:
    procs.append(subprocess.Popen(
        [NATIVE + "/fm-stream-hub", "serve", "--bind", "127.0.0.1", "--port", "0",
         "--ready-file", LAB + "/hub.ready", "--pid-file", LAB + "/hub.pid"],
        env=env, stdout=subprocess.DEVNULL, stderr=open(LAB + "/hub.log", "w")))
    host, port = wait_file(LAB + "/hub.ready")
    URL = "http://%s:%s" % (host, port)
    agent_env = dict(os.environ, SHELL="/bin/bash", TERM="xterm-256color")
    agent_env.pop("FM_STREAM_TOKEN", None)
    procs.append(subprocess.Popen(
        [NATIVE + "/fm-stream-agent", "serve", "--hub", URL, "--token-file", token_file,
         "--machine", "attach-test", "--label", "attach-%d" % os.getpid(),
         "--cwd", LAB + "/cwd", "--ready-file", LAB + "/agent.ready",
         "--rows", "24", "--cols", "80"],
        env=agent_env, stdout=subprocess.DEVNULL, stderr=open(LAB + "/agent.log", "w")))
    _, endpoint = wait_file(LAB + "/agent.ready")

    # Something on screen before anyone attaches: the paint must show it.
    api("POST", "/v1/tasks/%s/input" % endpoint, {"text": "echo before-$((20+1))", "submit": True})
    end = time.time() + 10
    while "before-21" not in api("GET", "/v1/tasks/%s/capture?lines=40" % endpoint):
        if time.time() > end:
            fail("the endpoint never rendered its pre-attach output")
        time.sleep(0.1)

    attach_env = dict(os.environ, FM_HOME=LAB + "/home", FM_STREAM_HUB=URL,
                      FM_STREAM_TOKEN=TOKEN, FM_STREAM_NATIVE_DIR=NATIVE, TERM="xterm-256color")
    pid, master = pty.fork()
    if pid == 0:
        fcntl.ioctl(0, termios.TIOCSWINSZ, struct.pack("HHHH", 24, 80, 0, 0))
        os.execve(ROOT + "/bin/fm-stream.sh",
                  [ROOT + "/bin/fm-stream.sh", "attach", "--interactive", endpoint], attach_env)

    seen = b""

    def read_until(needle, secs=15):
        global seen
        end = time.time() + secs
        while time.time() < end:
            ready, _, _ = select.select([master], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(master, 65536)
                except OSError:
                    break
                if not chunk:
                    break
                seen += chunk
            if needle in seen:
                return True
        return needle in seen

    if not read_until(b"before-21"):
        fail("attach did not paint the existing screen: %r" % seen[-400:])
    os.write(master, b"echo typed-$((40+2))\r")
    if not read_until(b"typed-42"):
        fail("a keystroke did not reach the child: %r" % seen[-400:])
    fcntl.ioctl(master, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
    time.sleep(1.0)
    os.write(master, b"stty size\r")
    if not read_until(b"30 100"):
        fail("the local resize did not reach the child's pty: %r" % seen[-400:])
    os.write(master, b"\x1d")
    if not read_until(b"detached from"):
        fail("the detach key did not detach: %r" % seen[-400:])
    _, status = os.waitpid(pid, 0)
    if os.WEXITSTATUS(status) != 0:
        fail("attach exited %d after a detach" % os.WEXITSTATUS(status))

    task = json.loads(api("GET", "/v1/tasks/" + endpoint))["task"]
    if task.get("closed_at") is not None:
        fail("detaching closed the endpoint")
    if procs[1].poll() is not None:
        fail("detaching ended the agent")
    api("POST", "/v1/tasks/%s/input" % endpoint, {"text": "echo after-$((1+1))", "submit": True})
    end = time.time() + 10
    while "after-2" not in api("GET", "/v1/tasks/%s/capture?lines=40" % endpoint):
        if time.time() > end:
            fail("the endpoint stopped taking input after the detach")
        time.sleep(0.1)
    if json.loads(api("GET", "/v1/tasks/" + endpoint))["task"]["rows"] != 30:
        fail("the hub's screen did not follow the resize")
    print("ok")
finally:
    cleanup()
