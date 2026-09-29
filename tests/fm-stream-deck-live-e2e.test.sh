#!/usr/bin/env bash
# Opt-in real Deck course correction through Bridge -> hub -> PTY agent ->
# native Deck safe point. No shared hub, endpoint, or supervisor home is used.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_DECK_LIVE deck python3 jq
DECK_BIN=${FM_DECK_LIVE_BINARY:-$(command -v deck)}
"$DECK_BIN" run --help | grep -q -- '--steer-dir' || { echo "FAIL Deck lacks --steer-dir: $DECK_BIN"; exit 1; }
"$DECK_BIN" --version
LAB=$(fm_test_tmproot fm-stream-deck-live)
trap fm_test_cleanup EXIT
python3 - "$ROOT" "$LAB" "$DECK_BIN" <<'PY'
import json, os, pathlib, shlex, signal, subprocess, sys, time, urllib.request
root, lab = map(pathlib.Path, sys.argv[1:3]); deck=sys.argv[3]
state=lab/'state';state.mkdir(); cwd=lab/'cwd';cwd.mkdir()
(cwd/'AGENTS.md').write_text('This is an isolated runtime verification. Follow only the explicit test prompt. Never spawn agents, run session start, or inspect other homes.\n')
token='isolated-steering-test'; (lab/'token').write_text(token+'\n');(lab/'token').chmod(0o600)
(lab/'hub-token').write_text('publish,subscribe,control:'+token+'\n');(lab/'hub-token').chmod(0o600)
children=[]
def launch(args,log,env=None):
    p=subprocess.Popen(args,stdout=(lab/log).open('w'),stderr=subprocess.STDOUT,env=env,start_new_session=True)
    children.append(p);return p
def wait_for(pred, label, count=1200):
    for _ in range(count):
        if pred():return
        if any(p.poll() is not None for p in children):
            raise AssertionError('process ended waiting for '+label)
        time.sleep(.1)
    raise AssertionError('timeout '+label)
try:
    hub=launch([sys.executable,str(root/'bin/fm-stream-hub.py'),'serve','--bind','127.0.0.1',
        '--port','0','--token-file',str(lab/'hub-token'),'--ready-file',str(lab/'hub.ready')],'hub.log')
    wait_for(lambda:(lab/'hub.ready').exists(),'hub')
    host,port=(lab/'hub.ready').read_text().split();url='http://'+host+':'+port
    env=dict(os.environ)
    env['DECK_STATE']=str(lab/'deck-state')
    agent=launch([sys.executable,str(root/'bin/fm-stream-agent.py'),'serve','--hub',url,
        '--token-file',str(lab/'token'),'--machine','lab','--label','worker','--cwd',str(cwd),
        '--status-path',str(state/'worker.status'),'--ready-file',str(lab/'agent.ready')],'agent.log',env)
    wait_for(lambda:(lab/'agent.ready').exists(),'agent'); endpoint=(lab/'agent.ready').read_text().split()[-1]
    gen=subprocess.check_output([str(root/'bin/fm-busy-event.sh'),'arm',str(state),'worker'],text=True).strip()
    prompt='Runtime test only. First run exactly this shell command: touch started; sleep 12. Then write ORIGINAL to result.txt and append done: original to '+str(state/'worker.status')+'. Do not inspect any other resources. If supervisor steering arrives, follow it instead and never write ORIGINAL.'
    args=['bash',str(root/'bin/fm-deck-worker.sh'),'--id','worker','--state',str(state),
          '--gen',gen,'--deck',deck,'--model',os.environ.get('FM_DECK_LIVE_MODEL','codex/gpt-6.1-sol'),'--',prompt]
    def call(path,body):
        request=urllib.request.Request(url+path,data=json.dumps(body).encode(),
            headers={'Authorization':'Bearer '+token,'Content-Type':'application/json'})
        return json.load(urllib.request.urlopen(request,timeout=30))
    call('/v1/tasks/'+endpoint+'/input',{'text':'exec '+shlex.join(args),'submit':True})
    wait_for(lambda:(cwd/'started').exists(),'running tool')
    before=(state/'worker.busy-state').read_bytes();assert b'state=busy' in before
    assert not (state/'worker.turn-ended').exists()
    steer='Change course now: do not write ORIGINAL. Run a shell command that writes CORRECTED to result.txt, then sleeps 5. Then acknowledge the ordinary source record described below, append done: corrected to '+str(state/'worker.status')+', and finish. Do nothing else.'
    record={'record':'command','command_id':'midturn-live','identity':{'fleet_id':'test',
        'leaf_worker_id':'lab/worker','parent_mate_id':'lab','execution_id':endpoint},
        'payload':{'kind':'steer','text':steer}}
    bridge=subprocess.Popen([sys.executable,str(root/'bin/fm-stream-bridge.py'),'command',
        '--hub',url,'--token-file',str(lab/'token'),'--fleet-id','test'],stdin=subprocess.PIPE,
        stdout=(lab/'bridge.out').open('w'),stderr=(lab/'bridge.err').open('w'),text=True)
    children.append(bridge);bridge.stdin.write(json.dumps(record)+'\n');bridge.stdin.close()
    # Bridge may finish its bounded wait with the order still pending.
    for _ in range(1200):
        if (cwd/'result.txt').exists():break
        if agent.poll() is not None:raise AssertionError('agent ended')
        time.sleep(.1)
    assert (cwd/'result.txt').read_text().strip()=='CORRECTED'
    assert not (state/'worker.turn-ended').exists(), 'correction arrived only after turn completion'
    assert (state/'worker.busy-state').read_bytes()==before, 'receiver advanced busy state'
    assert not (state/'worker.status').exists(), 'receiver manufactured turn evidence'
    for _ in range(1200):
        if (state/'worker.turn-ended').exists():break
        time.sleep(.1)
    assert (state/'worker.turn-ended').exists()
    assert 'failed:' not in (state/'worker.status').read_text()
    bridge.wait(timeout=30)
    # A lost/late first answer is reconciled by the exact same command id.
    result=subprocess.run([sys.executable,str(root/'bin/fm-stream-bridge.py'),'command',
        '--hub',url,'--token-file',str(lab/'token'),'--fleet-id','test'],input=json.dumps(record)+'\n',
        capture_output=True,text=True,timeout=40,check=True)
    ack=json.loads(result.stdout);assert ack['record']=='command_ack' and ack['state']=='accepted',result
    assert ack['command_id']=='midturn-live' and ack['leaf_worker_id']=='lab/worker'
    receiver=state/('worker.inbox/deck-'+endpoint)
    handled=list(receiver.glob('*/handled/*.msg'));assert len(handled)==1
    # One driver turn, same active execution, and one durable applied steer.
    assert len([p for p in receiver.iterdir() if p.is_dir()])==1
    assert list((state/'worker.inbox/handled').glob('*.msg')), 'ordinary source not acknowledged'
    print('PASS real Deck mid-turn correction through Bridge/hub/agent, execution-bound ack, one turn, and no false evidence/failure')
finally:
    for p in reversed(children):
        if p.poll() is None:
            try:os.killpg(p.pid,signal.SIGTERM) if p.pid != getattr(locals().get('bridge',None),'pid',None) else p.terminate()
            except ProcessLookupError:pass
    for p in children:
        try:p.wait(timeout=10)
        except subprocess.TimeoutExpired:p.kill();p.wait()
    for name in ('hub.log','agent.log','bridge.err','bridge.out'):
        if (lab/name).exists():print(name+':\n'+(lab/name).read_text(),file=sys.stderr)
PY
