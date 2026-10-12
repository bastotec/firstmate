#!/usr/bin/env bash
# tests/fm-stream-agent-diagnostics.test.sh - the agent's own failures must
# land in a durable, bounded destination rather than /dev/null.
#
# _silence_diagnostics() puts /dev/null over fd 1 and 2 for the rest of the
# agent's life, so every failure the agent detects about itself after startup -
# a hub it cannot reach, a re-registration that failed, a stand-down - was
# unreportable: a worker that stopped working for a reason nobody could read.
# The diagnostics file in the task's home-owned state directory is the fix,
# and this file pins its properties.
#
# 1. Rotation is bounded: at most DIAGNOSTICS_FILES files exist, every record
#    and file stays within DIAGNOSTICS_MAX_BYTES, and oldest content leaves
#    first on the append path alone.
# 2. Failure routing: detected failures append one diagnostics line with a
#    timestamp, an event, and a reason, including statusless and thread-failure
#    paths.
# 3. Silence on failure: a diagnostics write that cannot happen is swallowed,
#    never raised into the agent's main path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || fail "python3 is required for the stream agent"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CASE_DIR=$(fm_test_tmproot fm-stream-agent-diagnostics)

cat > "$CASE_DIR/drive.py" <<'PY'
"""Drive the agent's diagnostics helpers through their bounded-rotation and
failure-routing properties."""
import importlib.util
import os
import sys
from types import SimpleNamespace

spec = importlib.util.spec_from_file_location("fm_stream_agent", sys.argv[1])
agent = importlib.util.module_from_spec(spec)
spec.loader.exec_module(agent)

RESULTS = []


def report(name, ok, detail=""):
    RESULTS.append((name, ok, detail))


work = sys.argv[2]

# 1. Rotation: file-count cap holds on the append path alone.
small = os.path.join(work, "small")
original_max = agent.DIAGNOSTICS_MAX_BYTES
original_files = agent.DIAGNOSTICS_FILES
try:
    agent.DIAGNOSTICS_MAX_BYTES = 120
    for index in range(30):
        agent._diag_write(small, "publish-failed", "reason %02d cannot reach the hub" % index)
    names = sorted(n for n in os.listdir(work) if n.startswith("small"))
    report("rotation-count-bounded",
           names == ["small", "small.1", "small.2"],
           "files=%r" % names)
    live = open(small).read().splitlines()
    one = open(small + ".1").read().splitlines()
    two = open(small + ".2").read().splitlines()
    numbers = [line.split()[3] for line in two + one + live]
    report("rotation-orders-content",
           numbers == sorted(numbers) and len(numbers) > 1
           and live[-1].split()[3] == "29",
           "numbers=%r" % numbers)
finally:
    agent.DIAGNOSTICS_MAX_BYTES = original_max
    agent.DIAGNOSTICS_FILES = original_files

# 2. A single oversized event is truncated before it can exceed the cap.
oversized = os.path.join(work, "oversized")
agent._diag_write(oversized, "publish-failed", "x" * (agent.DIAGNOSTICS_MAX_BYTES * 2))
report("oversized-event-bounded",
       os.path.getsize(oversized) <= agent.DIAGNOSTICS_MAX_BYTES,
       "size=%d" % os.path.getsize(oversized))

# 3. Line shape: one line per event, timestamp, event, single-line reason.
agent._diag_write(small, "stood-down", "endpoint superseded\nby another\nworker")
lines = open(small).read().splitlines()
report("line-is-single-line",
       lines[-1].split()[0].endswith("Z")
       and lines[-1].split()[1] == "stood-down"
       and lines[-1].endswith("endpoint superseded by another worker"),
       repr(lines[-1]))

# 4. Routing: the failure sites call the helper with the home's options shape.
options = SimpleNamespace(status_path=os.path.join(work, "task.status"), label="task")
path = agent._diagnostics_path(options)
report("path-beside-status",
       path == os.path.join(work, "task.agent-diagnostics"),
       path)
agent._agent_diag(options, "publish-failed", "cannot reach the hub at http://x")
report("agent-diag-writes",
       os.path.exists(path)
       and open(path).read().splitlines()[-1].endswith("cannot reach the hub at http://x"),
       open(path).read() if os.path.exists(path) else "absent")

# A statusless endpoint uses its home-owned state directory.
home = os.path.join(work, "home")
state = os.path.join(home, "state")
os.makedirs(state)
old_home = os.environ.get("FM_HOME")
old_state = os.environ.pop("FM_STATE_OVERRIDE", None)
os.environ["FM_HOME"] = home
try:
    statusless = SimpleNamespace(status_path="", label="primary-chat")
    statusless_path = agent._diagnostics_path(statusless)
    agent._agent_diag(statusless, "publish-failed", "statusless endpoint failure")
finally:
    if old_home is None:
        os.environ.pop("FM_HOME", None)
    else:
        os.environ["FM_HOME"] = old_home
    if old_state is not None:
        os.environ["FM_STATE_OVERRIDE"] = old_state
report("statusless-path-is-home-owned",
       statusless_path == os.path.join(state, "primary-chat.agent-diagnostics")
       and os.path.exists(statusless_path),
       statusless_path)

# 5. An uncaught worker-thread failure is durable and halts the agent.
class FakeHub:
    deadline = None

    def call(self, *_args, **_kwargs):
        return {}


class FakePty:
    exit_code = 1

    def close(self, *_args):
        pass

    def release(self):
        pass


thread_options = SimpleNamespace(
    machine="test", status_path=os.path.join(work, "thread.status"), label="thread",
    state_interval=5.0, poll_secs=1.0)
subject = agent.Agent(thread_options, FakeHub(), FakePty(), "0" * 32)


def reader():
    subject.stop.wait()
    subject.reader_done.set()


subject.read_loop = reader
subject.state_loop = lambda: (_ for _ in ()).throw(OverflowError("timer overflow"))
subject.command_loop = subject.stop.wait
thread_result = subject.run(install_signals=False)
thread_diagnostics = open(agent._diagnostics_path(thread_options)).read()
report("thread-failure-is-durable",
       thread_result == 1 and "thread-crashed state: OverflowError: timer overflow" in thread_diagnostics,
       thread_diagnostics)

# 6. Silence: an unwritable destination never raises into the main path.
denied = os.path.join(work, "denied.agent-diagnostics")
open(denied, "w").close()
os.chmod(denied, 0o000)
try:
    agent._diag_write(denied, "publish-failed", "must not raise")
    report("write-failure-swallowed", True)
except OSError as exc:
    report("write-failure-swallowed", False, str(exc))

# A directory in place of the file is refused by open() the same way.
blocked = os.path.join(work, "blocked")
os.mkdir(blocked)
try:
    agent._diag_write(blocked, "publish-failed", "must not raise")
    report("directory-destination-swallowed", True)
except OSError as exc:
    report("directory-destination-swallowed", False, str(exc))

for name, ok, detail in RESULTS:
    print("%s %s %s" % ("ok" if ok else "FAIL", name, detail))
sys.exit(0 if all(ok for _, ok, _ in RESULTS) else 1)
PY

python3 "$CASE_DIR/drive.py" "$ROOT/bin/fm-stream-agent.py" "$CASE_DIR" > "$CASE_DIR/out"
cat "$CASE_DIR/out"
while IFS= read -r line; do
  case "$line" in
    ok\ *) pass "${line#ok }" ;;
    FAIL*) fail "${line#FAIL }" ;;
  esac
done < "$CASE_DIR/out"

pass "stream agent diagnostics: bounded destination, routed failures, swallowed write errors"
