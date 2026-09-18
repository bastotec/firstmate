#!/usr/bin/env python3
"""Post one closing frame from an agent whose re-registration pace is spent.

The case this exists for cannot be staged from outside the agent. An agent
reaches a spent pace by making a re-registration attempt that failed, which
needs a hub that answers "I have forgotten this endpoint" and then refuses the
registration that answers it - and then, for the frame under test to be worth
anything, the same hub healthy again a moment later. Driving the agent's own
publish path directly stages exactly that state and nothing else: the pace is
set as a failed attempt would leave it, and the hub on the other end is the
real one, answering for real.

What it proves is the worker's end being recorded at all. The frame carries an
exit code, the hub has never heard of the endpoint it names, and a dropped
frame here is a task whose end nothing afterwards will ever ask about again.

  --hub URL --token TOKEN --machine NAME --label NAME --endpoint HEX
  --exit-code N       the exit status the closing frame reports
  --pace-secs SECS    how far ahead to put the next attempt this agent allows
  --hold-lock-secs S  hold the agent's registration lock for S seconds first,
                      as a recovery already in flight on another thread does
"""

import argparse
import importlib.util
import os
import threading
import time


def load_agent_module():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "..", "bin", "fm-stream-agent.py")
    spec = importlib.util.spec_from_file_location("fm_stream_agent",
                                                  os.path.normpath(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class ExitedPty:
    """The pty of a worker that has already gone, which is the only state here."""

    def alive(self) -> bool:
        return False

    def foreground_processes(self, until=None) -> list:  # noqa: ARG002
        return []

    def foreground_cwd(self, until=None) -> str:  # noqa: ARG002
        return ""


def hold_register_lock(agent, seconds: float) -> None:
    """Stand in for a recovery already in flight on another of the agent's threads.

    A heartbeat that met the same forgotten endpoint takes the agent's
    registration lock and keeps it for one registration round trip. That hold
    is what the closing frame has to survive, and it is staged directly because
    arranging for a second thread to be inside a real registration at the exact
    instant the closing frame arrives is not something a case can time.
    """
    held = threading.Event()

    def _hold() -> None:
        with agent._register_lock:
            held.set()
            time.sleep(seconds)

    thread = threading.Thread(target=_hold, daemon=True)
    thread.start()
    if not held.wait(5.0):
        raise SystemExit("could not take the agent's registration lock")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hub", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--exit-code", type=int, default=7)
    parser.add_argument("--pace-secs", type=float, default=600.0)
    parser.add_argument("--hold-lock-secs", type=float, default=0.0)
    options = parser.parse_args()

    agent_module = load_agent_module()
    hub = agent_module.HubClient(options.hub, options.token)
    identity = argparse.Namespace(machine=options.machine, label=options.label,
                                  cwd="/tmp", rows=40, cols=200, status_path="",
                                  state_interval=5.0)
    agent = agent_module.Agent(identity, hub, ExitedPty(), options.endpoint)
    # The state a long outage leaves: the last attempt failed, so the next one
    # is not due for a long time yet and the growth behind it is at its ceiling.
    # Staging it means writing the agent's own pace fields, so prove they are
    # still the agent's: a rename would otherwise create stray attributes here,
    # leave the real pace unspent, and let this case pass without ever reaching
    # the window the closing frame has to survive.
    for attribute in ("_register_not_before", "_register_backoff", "_register_lock"):
        if not hasattr(agent, attribute):
            raise SystemExit(
                "fm-stream-agent.py no longer has Agent.%s; this case can no "
                "longer stage a spent re-registration pace" % attribute)
    agent._register_not_before = time.monotonic() + options.pace_secs
    agent._register_backoff = agent_module.REREGISTER_BACKOFF_MAX
    if options.hold_lock_secs > 0:
        hold_register_lock(agent, options.hold_lock_secs)
    agent._post_frames([{
        "endpoint_id": options.endpoint,
        "closed": True,
        "exit_code": options.exit_code,
        "state": {"alive": False, "foreground": [], "cwd": "",
                  "published_at": agent_module._now()},
    }])
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
