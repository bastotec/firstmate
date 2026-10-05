#!/usr/bin/env python3
"""Run the reference hub with an externally advanced test clock.

Only the clock is injected; HTTP routing, reap, orders and authorization are
production code. The offset file belongs to the calling suite's disposable rig.
"""
import importlib.util
from pathlib import Path
import sys

spec = importlib.util.spec_from_file_location("retention_hub", sys.argv[1])
hub = importlib.util.module_from_spec(spec)
spec.loader.exec_module(hub)
offset = Path(sys.argv[2])
real_now = hub._now
hub._now = lambda: real_now() + float(offset.read_text())
raise SystemExit(hub.main(sys.argv[3:]))
