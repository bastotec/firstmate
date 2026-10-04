#!/usr/bin/env python3
"""Reuse repository-owned loopback/PTY fixtures; no shared runtime touched.
Run from the tested worktree: python3 <this-file> [json|agent|ui]
"""
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
LAB = ROOT / '.test-tmp' / 'probes'
LAB.mkdir(exist_ok=True)
CURRENT = ROOT / 'target/debug/fm-stream-hub'
PREVIOUS = ROOT / '.test-tmp/pre-fix/target/debug/fm-stream-hub'

def load(name, path, argv):
    old = sys.argv
    sys.argv = argv
    try:
        spec = importlib.util.spec_from_file_location(name, path)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        return module
    finally:
        sys.argv = old

hub = load('hub_fixture', ROOT / 'tests/assets/stream-hub-differential.py', ['probe', str(CURRENT)])
agent = load('agent_fixture', ROOT / 'tests/assets/stream-agent-rust-parity.py', ['probe', str(ROOT), str(LAB)])

if sys.argv[1] == 'json':
    records = []
    commands = [('python', [sys.executable, str(ROOT / 'bin/fm-stream-hub.py')]),
                ('pre-fix-5b5eef06', [str(PREVIOUS)]), ('current-e27dcaa9', [str(CURRENT)])]
    for name, command in commands:
        p = hub.Pilot(command, LAB / name)
        try:
            eid = 'a' * 32
            assert p.register(eid)[0] == 201
            for depth in (0, 125, 150):
                note = '[NaN, "\\ud800"]'
                note = '[' * depth + note + ']' * depth
                body = ('{"state":"working","note":' + note + '}').encode()
                with concurrent.futures.ThreadPoolExecutor() as pool:
                    future = pool.submit(p.api, 'POST', '/v1/tasks/' + eid + '/status', body)
                    status, raw = p.api('GET', '/v1/agent/commands?machine=box&endpoint=' + eid + '&wait=1',
                                        token='pub', capability=p.capabilities[eid], raw_json=True)
                    taken = json.loads(raw)['commands']
                    if taken:
                        cid = taken[0]['command_id']
                        expected = {'commands':[{'command_id':cid, 'endpoint_id':eid, 'kind':'status',
                                                'payload':{'state':'working', 'note':json.loads(note)}}], 'ok':True}
                        assert raw == json.dumps(expected, sort_keys=True).encode(), raw
                        assert p.result(cid, eid)[0] == 200
                        normalized = raw.replace(cid.encode(), b'command').decode()
                    else:
                        normalized = raw.decode()
                    result = future.result()
                record = {'hub':name, 'depth':depth, 'request':body.decode(), 'commands':normalized,
                          'response':result, 'health':p.api('GET', '/v1/health', token='pub')}
                records.append(record)
                print(json.dumps(record, ensure_ascii=True), flush=True)
                assert result[0] == (400 if name.startswith('pre-fix') and depth >= 150 else 200), result
            if name != 'pre-fix-5b5eef06':
                hub.command_json_compatibility(p, eid)
                peer_records, durable = hub.peers(p)
                EVIDENCE.joinpath(name + '-durable.status').write_bytes(durable)
                print(name + ' durable peer record: ' + repr(durable), flush=True)
        finally:
            p.close()
    EVIDENCE.joinpath('json-counterfactual.json').write_text(json.dumps(records, indent=2) + '\n')

elif sys.argv[1] == 'agent':
    original_spawn = agent.Rig.spawn
    def spawn(self, args, **kwargs):
        if len(args) > 1 and args[1] == str(ROOT / 'bin/fm-stream-hub.py'):
            args = [str(CURRENT)] + args[2:]
        return original_spawn(self, args, **kwargs)
    agent.Rig.spawn = spawn
    for index, executable in enumerate(agent.AGENTS):
        name = ('python', 'rust')[index]
        for function in (agent.command_values, agent.command_limits):
            observed = function(executable, 'rust-hub-' + name + '-' + function.__name__)
            if function == agent.command_values:
                EVIDENCE.joinpath(name + '-agent-command-values.status').write_text(observed[0])
                EVIDENCE.joinpath(name + '-agent-command-values-pty.txt').write_bytes(observed[1])
            print('Rust hub + ' + name + ' agent: ' + function.__name__ + ' matched exact durable status and PTY byte contracts', flush=True)

elif sys.argv[1] == 'ui':
    original_spawn = agent.Rig.spawn
    def spawn(self, args, **kwargs):
        if len(args) > 1 and args[1] == str(ROOT / 'bin/fm-stream-hub.py'):
            args = [str(CURRENT)] + args[2:]
        return original_spawn(self, args, **kwargs)
    agent.Rig.spawn = spawn
    rig = agent.Rig('ui-rust')
    browser = ['agent-browser', '--session', 'a', '--executable-path',
               '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
               '--profile', str(ROOT / '.test-tmp/browser-profile')]
    def run(*args):
        result = subprocess.run(browser + list(args), capture_output=True, text=True, timeout=50)
        print('$ agent-browser ' + ' '.join(args) + '\n' + result.stdout + result.stderr, flush=True)
        assert result.returncode == 0, result.stderr
        return result.stdout
    try:
        proc, eid, _ = rig.agent(agent.AGENTS[0])
        rig.remember_worker(eid)
        rig.marker(eid, 'RUST-HUB-BROWSER-READY')
        run('open', rig.url + '/ui#' + agent.CTL)
        run('set', 'viewport', '1200', '800')
        run('wait', '--text', 'worker')
        run('snapshot', '-i')
        run('find', 'role', 'button', 'click', '--name', 'worker', '--exact')
        run('wait', '--fn', "document.querySelector('#out').textContent.includes('RUST-HUB-BROWSER-READY')")
        run('fill', '#line', "printf '\\nUI-ROUNDTRIP:%s\\n' 'é-中'")
        run('click', 'button.send')
        run('wait', '--fn', "document.querySelector('#out').textContent.includes('\\nUI-ROUNDTRIP:é-中')")
        assert '\nUI-ROUNDTRIP:é-中\n' in rig.capture(eid)
        run('screenshot', str(EVIDENCE / 'rust-hub-ui-roundtrip.png'))
        run('fill', '#line', 'exit 0')
        run('click', 'button.send')
        run('wait', '--fn', "document.querySelector('#line').disabled && document.querySelector('#list .gone') !== null")
        run('screenshot', str(EVIDENCE / 'rust-hub-ui-closed.png'))
        proc.wait(timeout=15)
        assert rig.task(eid)['closed_by'] == 'agent'
        print('Browser sent real PTY input; UTF-8 appeared in capture/SSE; agent close disabled the input.', flush=True)
    finally:
        try:
            run('close')
        finally:
            rig.close()
