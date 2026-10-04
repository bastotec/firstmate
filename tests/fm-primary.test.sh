#!/usr/bin/env bash
# Managed primary setup, discovery, owned-child lifecycle and native steering.
# Uses a fixture-only hub/home and standby Deck/Pi executables, never the fleet.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-primary)
trap fm_test_cleanup EXIT
python3 - "$ROOT" "$LAB" <<'PY'
import json, os, pathlib, shutil, signal, socket, subprocess, sys, time, urllib.request
root, lab = map(pathlib.Path, sys.argv[1:])
bundle = lab/'bundle'
shutil.copytree(root/'bin', bundle/'bin')
bin = bundle/'bin'
fixture = lab/'tools'; fixture.mkdir()
home = lab/'home'; home.mkdir(); (home/'state').mkdir(); (home/'config').mkdir()
# Stub ONLY home bootstrap/watcher ownership: production primary owner, stream
# agent, PTY, Deck driver, receiver and durable inbox all run unchanged.
def executable(path, body):
    path.write_text(body); path.chmod(0o755)
executable(bin/'fm-session-start.sh', '''#!/bin/sh
printf '%s\n' "$PPID" > "$FM_HOME/state/.session-start-complete"
printf 'fixture home digest\n'
''')
executable(bin/'fm-session-lock-lib.sh', '''#!/bin/sh
fm_session_lock_owned_by_self() { test "$(cat "$1/.session-start-complete")" = "$$"; }
''')
executable(bin/'fm-watch-arm.sh', '''#!/bin/sh
while :; do sleep 1; done
''')
executable(fixture/'deck', '''#!/usr/bin/env python3
import json, os, pathlib, signal, sys, time
if '--help' in sys.argv:
 print('--steer-dir PATH'); sys.exit(0)
endpoint = os.environ['FM_STREAM_ENDPOINT_ID']
root = pathlib.Path(__file__).parent
(root/(endpoint+'.started')).write_text(json.dumps({'argv':sys.argv, 'pid':os.getpid()}))
def interrupted(signum, frame):
 (root/(endpoint+'.interrupted')).touch(); sys.exit(130)
signal.signal(signal.SIGINT, interrupted)
print(json.dumps({'type':'run_started','session':'fixture-session','model':'fixture-model'}), flush=True)
projection = pathlib.Path(sys.argv[sys.argv.index('--steer-dir')+1])
while True:
 for source in projection.glob('*.msg'):
  (projection/'handled').mkdir(exist_ok=True)
  text = source.read_text()
  assert text.startswith('native fixture steer'), text
  source.rename(projection/'handled'/source.name)
  (root/(endpoint+'.steered')).write_text(text)
 time.sleep(0.02)
''')
executable(fixture/'pi', '''#!/usr/bin/env python3
import os, pathlib, time
pathlib.Path(__file__).with_name(os.environ['FM_STREAM_ENDPOINT_ID']+'.pi').touch()
while True: time.sleep(1)
''')
# Launch a real isolated stream hub on an ephemeral loopback port.
token=lab/'token'; token.write_text('fixture-secret\n'); token.chmod(0o600)
hub_tokens=lab/'hub-tokens'; hub_tokens.write_text('publish,subscribe,control:fixture-secret\n'); hub_tokens.chmod(0o600)
hub_log=(lab/'hub.log').open('w')
ready=lab/'hub.ready'
hub=subprocess.Popen([sys.executable,str(bin/'fm-stream-hub.py'),'serve','--bind','127.0.0.1',
                      '--port','0','--token-file',str(hub_tokens),'--ready-file',str(ready)],
                     stdout=hub_log,stderr=hub_log)
processes=[hub]
logs=[]
env=dict(os.environ, PATH=str(fixture)+os.pathsep+os.environ['PATH'],
         TMPDIR=str(lab), FM_TASK_ID='must-not-leak', FM_HOME='must-not-leak')
registration=home/'state/primary-owner/registration.json'
cli=[sys.executable,str(bin/'fm-primary.py')]
def wait(predicate, note):
 for _ in range(400):
  value=predicate()
  if value: return value
  time.sleep(0.05)
 raise AssertionError(note+'\n'+''.join(p.read_text() for p in lab.glob('*.log')))
def record():
 try: return json.loads(registration.read_text())
 except (FileNotFoundError,json.JSONDecodeError): return None
def command(*args, success=True):
 result=subprocess.run(cli+list(args),env=env,capture_output=True,text=True,timeout=130)
 assert (result.returncode==0)==success,(args,result.returncode,result.stdout,result.stderr)
 return json.loads(result.stdout)
def control(execution,action,*args,success=True):
 return command('control','--home',str(home),'--execution-id',execution,action,*args,success=success)
def launch(adapter='deck'):
 logfile=lab/(adapter+'-owner.log'); log=logfile.open('w'); logs.append(log)
 proc=subprocess.Popen(cli+['launch','--home',str(home),'--machine','fixture-machine',
        '--label','fixture-primary','--hub',url,'--token-file',str(token),
        '--adapter',adapter,'--model','fixture-model','--prompt','fixture primary'],
        env=env,stdout=log,stderr=log)
 processes.append(proc); return proc
try:
 wait(lambda:ready.exists(),'hub readiness')
 bind, port = ready.read_text().split()
 url='http://'+bind+':'+port
 refusal=command('discover','--home',str(home),success=False)
 assert 'unregistered_primary' in refusal['message']
 refusal=control('missing','exit',success=False)
 assert 'unregistered_primary' in refusal['message']
 owner=launch()
 first=wait(lambda: (r if (r:=record()) and r['state']=='running' else None),'registered primary')
 eid=first['execution_id']; assert eid==first['endpoint_generation']
 wait(lambda:(fixture/(eid+'.started')).exists(),'Deck active turn')
 assert first['home']==str(home) and first['machine']=='fixture-machine'
 assert first['label']=='fixture-primary'
 assert first['profile']['executable']==str(fixture/'deck')
 assert first['profile']['model']=='fixture-model'
 assert 'FM_TASK_ID' not in first['profile']['environment']
 assert first['status_path']==str(home/'state/primary-owner/executions'/eid/'primary.status')
 assert not list((home/'state').glob('*.meta'))
 discovered=command('discover','--home',str(home))
 assert discovered=={'machine':'fixture-machine','label':'fixture-primary',
   'fm_home':str(home),'task_id':None,'primary_registration':str(registration)}
 # The captured private registration is genuine: the actual isolated hub has
 # exactly this endpoint, not invented task metadata.
 request=urllib.request.Request(url+'/v1/tasks',headers={'Authorization':'Bearer fixture-secret'})
 with urllib.request.urlopen(request) as response: endpoints=json.load(response)
 assert eid in json.dumps(endpoints), endpoints
 duplicate=subprocess.run(cli+['launch','--home',str(home),'--machine','fixture-machine',
       '--label','fixture-primary','--hub',url,'--token-file',str(token),
       '--adapter','deck','--prompt','duplicate'],env=env,capture_output=True,text=True,timeout=10)
 assert duplicate.returncode!=0 and 'duplicate_primary_registration' in duplicate.stdout
 assert record()==first
 stale=control('0'*32,'interrupt',success=False)
 assert 'stale_primary_execution' in stale['message']
 alive=control(eid,'recover-missing',success=False)
 assert 'registered_primary_is_alive' in alive['message']
 native_args=('--order-id','fixture-order','--text','native fixture steer')
 result=control(eid,'steer',*native_args)
 assert result['state'] in ('pending','accepted'),result
 wait(lambda:(fixture/(eid+'.steered')).exists(),'execution-bound native application')
 assert control(eid,'steer',*native_args)['state']=='accepted'
 assert len(list(pathlib.Path(first['status_path']).parent.glob('primary.inbox/*.msg')))==1
 assert control(eid,'interrupt')['state']=='accepted'
 wait(lambda:(fixture/(eid+'.interrupted')).exists(),'interrupt genuine owned Deck turn')
 assert owner.poll() is None
 assert control(eid,'relaunch')['state']=='accepted'
 second=record(); eid2=second['execution_id']; assert eid2!=eid
 assert second['profile']==first['profile'],'restart changed original launch profile'
 wait(lambda:(fixture/(eid2+'.started')).exists(),'replacement genuine child')
 assert control(eid,'exit',success=False)['state']=='refused'
 assert control(eid2,'exit')['state']=='accepted' and record()['state']=='exited'
 assert owner.poll() is None,'exit must retain manager capability for relaunch'
 assert control(eid2,'recover-missing')['state']=='accepted'
 third=record(); eid3=third['execution_id']; assert eid3 not in (eid,eid2)
 wait(lambda:(fixture/(eid3+'.started')).exists(),'recover missing owned child')
 assert third['profile']==first['profile']
 assert control(eid3,'exit')['state']=='accepted'
 owner.terminate(); owner.wait(timeout=15)
 assert not registration.exists(),'clean owner stop must retire registration'
 owner2=launch('pi')
 unsupported=wait(lambda: (r if (r:=record()) and r['state']=='running' else None),'Pi registration')
 eidpi=unsupported['execution_id']
 wait(lambda:(fixture/(eidpi+'.pi')).exists(),'Pi fixture child')
 refused=control(eidpi,'steer',*native_args,success=False)
 assert 'primary_adapter_has_no_native_receiver' in refused['message']
 assert not list(pathlib.Path(unsupported['status_path']).parent.glob('primary.inbox/*.msg'))
 assert control(eidpi,'exit')['state']=='accepted'
 owner2.terminate(); owner2.wait(timeout=15)
 print('PASS managed setup/discovery, genuine endpoint registration, duplicate and unregistered refusals')
 print('PASS owned-child interrupt/exit/relaunch/recover-missing, exact profile replay, stale execution refusal')
 print('PASS execution-bound Deck native acceptance and unsupported-adapter no-fallback refusal')
finally:
 # Reap only children this fixture created. Owners reap their own PTY children.
 for proc in reversed(processes):
  if proc.poll() is None:
   proc.terminate()
   try: proc.wait(timeout=20)
   except subprocess.TimeoutExpired:
    proc.kill(); proc.wait(timeout=5)
 for log in logs: log.close()
 hub_log.close()
PY
