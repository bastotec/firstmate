#!/usr/bin/env python3
"""Re-register twice in a row, and prove the pace between them is the floor.

An agent reaches a long pause honestly: every refused attempt to come back
doubles what it waits before the next one, up to a ceiling. The question this
stages is what a registration the hub ACCEPTS does to that pause. The accepted
attempt is proof the hub is answering again, so the pause it was serving is
spent - and if the hub forgets this endpoint a second time a moment later, a
second restart or a hub taking registrations while still refusing frames, the
agent has to be allowed back at its floor rather than held out for the ceiling
the outage before it earned.

Driving the agent's own recovery path directly is what makes that measurable:
a real outage long enough to grow the pause to its ceiling cannot be staged
inside a test, and the pause under test is minutes wide while the floor is
seconds. What is real here is the recovery itself and the hub on the other end
answering it.

  --hub URL --token TOKEN --machine NAME --label NAME --endpoint HEX
  --settle-secs SECS  how long to wait between the two recoveries; longer than
                      the floor the agent is allowed to use and far shorter
                      than the ceiling a spent pause would leave in its place
"""

import argparse
import importlib.util
import os
import time


def load_agent_module():
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)),
                        "..", "..", "bin", "fm-stream-agent.py")
    spec = importlib.util.spec_from_file_location("fm_stream_agent",
                                                  os.path.normpath(path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class LivePty:
    """A worker still running, which is the whole point of bringing it back."""

    def alive(self) -> bool:
        return True

    def foreground_processes(self, until=None) -> list:  # noqa: ARG002
        return ["bash"]

    def foreground_cwd(self, until=None) -> str:  # noqa: ARG002
        return "/tmp"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--hub", required=True)
    parser.add_argument("--token", required=True)
    parser.add_argument("--machine", required=True)
    parser.add_argument("--label", required=True)
    parser.add_argument("--endpoint", required=True)
    parser.add_argument("--settle-secs", type=float, default=3.0)
    options = parser.parse_args()

    agent_module = load_agent_module()
    hub = agent_module.HubClient(options.hub, options.token)
    identity = argparse.Namespace(machine=options.machine, label=options.label,
                                  cwd="/tmp", rows=40, cols=200, status_path="",
                                  state_interval=5.0)
    agent = agent_module.Agent(identity, hub, LivePty(), options.endpoint)
    # The pause a long outage leaves, staged by writing the agent's own fields,
    # so prove they are still the agent's: a rename would otherwise create
    # stray attributes here, leave the real pause at its untouched default of
    # zero, and let this case pass without ever measuring anything.
    for attribute in ("_register_not_before", "_register_backoff"):
        if not hasattr(agent, attribute):
            raise SystemExit(
                "fm-stream-agent.py no longer has Agent.%s; this case can no "
                "longer stage a grown re-registration pace" % attribute)
    agent._register_backoff = agent_module.REREGISTER_BACKOFF_MAX
    # Due now: the outage is over and this attempt is the one that finds out.
    agent._register_not_before = time.monotonic()
    if not agent.recover_registration(RuntimeError("the hub forgot this endpoint")):
        raise SystemExit("the first recovery was refused, so there is no accepted "
                         "registration to measure the pace after")
    time.sleep(options.settle_secs)
    if not agent.recover_registration(RuntimeError("the hub forgot this endpoint again")):
        raise SystemExit(
            "%.1fs after a registration the hub accepted, the agent still would "
            "not try again: the accepted attempt reset how fast the pause grows "
            "but left the pause itself at the ceiling the outage before it earned"
            % options.settle_secs)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
