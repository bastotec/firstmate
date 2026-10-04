#!/usr/bin/env python3
"""Replay the existing agent-parity note through real isolated Python/Rust hubs.
Run: PYTHONDONTWRITEBYTECODE=1 python3 nested-status-repro.py "$PWD"
Exits 1 when the supported 150-deep note cannot traverse the Rust hub.
Uses only the repository's existing Rig; all fixture writes stay in the worktree.
"""
import os
from pathlib import Path
import runpy
import sys
import tempfile

root = Path(sys.argv[1])
with tempfile.TemporaryDirectory(prefix='.nested-status-repro-', dir=root) as tmp:
    sys.argv = [str(root / 'tests/assets/stream-agent-rust-parity.py'), str(root), tmp]
    m = runpy.run_path(sys.argv[0])
    home = Path(tmp) / 'home'
    home.mkdir()
    m['ENV'].update(HOME=str(home), SHELL='/bin/bash', HISTFILE='/dev/null')
    for key in ('BASH_ENV', 'ENV', 'ZDOTDIR'):
        m['ENV'].pop(key, None)
    original_spawn = m['Rig'].spawn
    rust_hub = [False]

    def spawn_selected_hub(self, args, **kwargs):
        if rust_hub[0] and args[:2] == [sys.executable, str(root / 'bin/fm-stream-hub.py')]:
            args = [str(root / 'target/debug/fm-stream-hub')] + args[2:]
        return original_spawn(self, args, **kwargs)

    m['Rig'].spawn = spawn_selected_hub
    outcomes = {}
    for name, selected in [('python-reference', False), ('rust-current', True)]:
        rust_hub[0] = selected
        rig = m['Rig'](name)
        try:
            proc, eid, status = rig.agent(m['AGENTS'][0])
            for depth in (125, 150):
                note = 'ordinary'
                for _ in range(depth):
                    note = [note]
                code, response = m['call'](rig.url, 'POST', f'/v1/tasks/{eid}/status',
                                           {'state': 'working', 'note': note})
                print(name, 'depth=', depth, 'HTTP', code, response, flush=True)
                outcomes[name, depth] = code
                if code == 200:
                    expected_line = ('working: ' + str(note) + '\n').encode()
                    assert status.read_bytes().endswith(expected_line)
                    print('Owner durable record matches exact submitted value', flush=True)
            assert m['call'](rig.url, 'GET', '/v1/health')[0] == 200
        finally:
            rig.close()
    assert outcomes['python-reference', 125] == outcomes['rust-current', 125] == 200
    assert outcomes['python-reference', 150] == outcomes['rust-current', 150] == 200, outcomes
