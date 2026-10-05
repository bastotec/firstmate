#!/usr/bin/env bash
# Managed primary setup, discovery, owned-child lifecycle and native steering.
# Uses a fixture-only hub/home and standby Deck/Pi executables, never the fleet.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-primary)
trap fm_test_cleanup EXIT
python3 - "$ROOT" "$LAB" <<'PY'
import hashlib, json, os, pathlib, shutil, signal, socket, subprocess, sys, time, urllib.request
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
publication_fault=lab/'publication-fault.json'
publication_attempts=lab/'publication-attempts'; publication_attempts.mkdir()
executable(bin/'fixture-primary-launch.py', '''#!/usr/bin/env python3
import errno, importlib.util, json, os, pathlib, stat, sys
spec=importlib.util.spec_from_file_location('fixture_primary',pathlib.Path(__file__).with_name('fm-primary.py'))
owner=importlib.util.module_from_spec(spec); spec.loader.exec_module(owner)
write=owner.write_record
read=owner.read_record
fsync=os.fsync
fault=pathlib.Path(os.environ['FM_TEST_PUBLICATION_FAULT'])
attempts=pathlib.Path(os.environ['FM_TEST_PUBLICATION_ATTEMPTS'])
read_errors=attempts.parent/'readback-errors'
sync_target=None
unreadable=None
unreadable_rule=None

def inject_sync(fd):
 global unreadable, unreadable_rule
 if sync_target is not None:
  info=os.fstat(fd); parent=sync_target.parent.stat()
  if stat.S_ISDIR(info.st_mode) and (info.st_dev,info.st_ino)==(parent.st_dev,parent.st_ino):
   unreadable=sync_target
   unreadable_rule=json.loads(fault.read_text())
   raise OSError(errno.EIO,'fixture registration directory fsync failure',str(sync_target))
 fsync(fd)

def inject_read(path):
 if path==unreadable and fault.exists() and json.loads(fault.read_text())==unreadable_rule:
  count=int(read_errors.read_text()) if read_errors.exists() else 0
  staged=read_errors.with_suffix('.next'); staged.write_text(str(count+1)); staged.replace(read_errors)
  raise OSError(errno.EIO,'fixture registration readback failure',str(path))
 return read(path)

def inject(path,record,on_replace=None):
 global sync_target
 if path.name=='registration.json' and fault.exists():
  rule=json.loads(fault.read_text())
  if record['state']==rule['state']:
   write(attempts/(str(len(list(attempts.glob('*.json'))))+'.json'),record)
   if rule['phase']=='fsync-readback':
    sync_target=path
    try: write(path,record,**({'on_replace':on_replace} if on_replace is not None else {}))
    finally: sync_target=None
    return
   if rule['phase']=='after': write(path,record,**({'on_replace':on_replace} if on_replace is not None else {}))
   raise OSError(errno.ENOSPC,'fixture registration storage failure',str(path))
 write(path,record,**({'on_replace':on_replace} if on_replace is not None else {}))
owner.write_record=inject
owner.read_record=inject_read
owner.os.fsync=inject_sync
thread_start=owner.threading.Thread.start
thread_fault=attempts.parent/'thread-start-fault'
thread_attempt=attempts.parent/'thread-start-attempt.json'
def inject_thread_start(thread):
 target=getattr(thread,'_target',None)
 if thread_fault.exists() and getattr(target,'__func__',None) is owner.stream.Agent.run:
  agent=target.__self__
  write(thread_attempt,{'endpoint_id':agent.endpoint_id,'pid':agent.pty.pid})
  raise RuntimeError('fixture publisher thread start failure')
 return thread_start(thread)
owner.threading.Thread.start=inject_thread_start
sys.exit(owner.main())
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
sentinel=subprocess.Popen(['sleep','300'])
processes.append(sentinel)
logs=[]
env=dict(os.environ, PATH=str(fixture)+os.pathsep+os.environ['PATH'],
         TMPDIR=str(lab), FM_TASK_ID='must-not-leak', FM_HOME='must-not-leak',
         FM_TEST_PUBLICATION_FAULT=str(publication_fault),
         FM_TEST_PUBLICATION_ATTEMPTS=str(publication_attempts))
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
registry=lab/'ui-registry.json'
router=[sys.executable,str(bin/'fm-ui-host-control.py'),'--registry',str(registry)]
def ui_result(action,execution,*,command_id=None,**extra):
 payload=dict(kind=action,execution_id=execution)
 if action in ('relaunch','recover-missing'): payload['note']='fixture lifecycle checkpoint'
 payload.update(extra)
 request=dict(record='command',command_id=command_id or 'fixture-'+action+'-'+execution,
              identity=dict(parent_mate_id='fixture-machine',leaf_worker_id='fixture-machine/fixture-primary'),
              payload=payload)
 result=subprocess.run(router+['command'],input=json.dumps(request)+'\n',env=env,
                       capture_output=True,text=True,timeout=130)
 assert result.returncode==0,(result.stdout,result.stderr)
 return result

def ui(action,execution,**extra):
 result=ui_result(action,execution,**extra)
 return [json.loads(line) for line in result.stdout.splitlines()]
def publish_ui_binding(binding):
 registry.write_text(json.dumps([binding])); registry.chmod(0o600)
 result=subprocess.run(router+['targets'],env=env,capture_output=True,text=True,timeout=10)
 assert result.returncode==0,(result.stdout,result.stderr)
 safe=json.loads(result.stdout)
 assert len(safe)==1 and safe[0]['target_class']=='primary' and not safe[0]['call_available']
 assert safe[0]['execution_id']==record()['execution_id']
 for secret in (str(home),str(registration),record()['capability'],record()['profile']['executable']):
  assert secret not in result.stdout,'host-private data leaked to discovery'
 return safe[0]
def launch(adapter='deck'):
 logfile=lab/(adapter+'-owner.log'); log=logfile.open('w'); logs.append(log)
 proc=subprocess.Popen([sys.executable,str(bin/'fixture-primary-launch.py'),'launch','--home',str(home),'--machine','fixture-machine',
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
 assert 'unregistered_primary' in refusal['message'] and len(refusal['command_id'])==32
 gate_env=dict(env,NO_MISTAKES_GATE='fixture-gate',FM_GATE_REFUSE_BYPASS='')
 gate=subprocess.run(cli+['control','--home',str(home),'--execution-id','missing','exit'],
                     env=gate_env,capture_output=True,text=True,timeout=10)
 assert gate.returncode!=0 and 'authority refused' in gate.stdout
 assert not registration.parent.exists(),'gate refusal mutated primary state'
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
 target=publish_ui_binding(discovered)
 assert set(target['supported_operations'])=={'note','interrupt','exit','relaunch','recover-missing','steer'}
 assert ui('interrupt','0'*32)[0]['reason']=='stale_primary_execution: refresh discovery before control'
 assert ui('recover-missing',eid)[0]['reason']=='registered_primary_is_alive: recover-missing refused'
 receipt_root=registration.parent/'commands'/hashlib.sha256(first['capability'].encode()).hexdigest()
 command_id='fixture-interrupt-'+eid
 receipt=receipt_root/(hashlib.sha256(command_id.encode()).hexdigest()+'.json')
 receipt.mkdir()
 try:
  failure=ui_result('interrupt',eid)
  ack=json.loads(failure.stdout)
  assert ack['state']=='refused' and ack['reason']=='primary owner refused',ack
  assert ack['command_id']==command_id and ack['leaf_worker_id']=='fixture-machine/fixture-primary',ack
  diagnostic=json.loads(failure.stderr)
  assert diagnostic['record']=='host_owner_result' and diagnostic['state']=='unconfirmed',diagnostic
  assert diagnostic['command_id']==command_id and diagnostic['leaf_worker_id']==ack['leaf_worker_id'],diagnostic
  assert diagnostic['exit_code']==1 and not diagnostic['stderr'],diagnostic
  owner_error=json.loads(diagnostic['stdout'])
  assert owner_error['state']=='refused' and str(receipt) in owner_error['message'],owner_error
  for secret in (str(home),str(registration),str(receipt),first['capability'],
                 first['profile']['executable'],'fixture-secret'):
   assert secret not in failure.stdout,'owner-private diagnostic reached browser stdout'
  assert record()==first and not (fixture/(eid+'.interrupted')).exists(),'failed receipt mutated child'
 finally:
  receipt.rmdir()
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
 receiver=pathlib.Path(first['status_path']).parent/'primary.inbox'/('deck-'+eid)
 active=wait(lambda: (json.loads((receiver/'active.json').read_text())
                     if (receiver/'active.json').exists() else None),'native receiver active')
 assert active['active'] and active['supported'],active
 order_id='ui-'+hashlib.sha256(('fixture-steer-'+eid).encode()).hexdigest()
 reservation=receiver/('order-'+hashlib.sha256(order_id.encode()).hexdigest()+'.json')
 inbox_library=bin/'fm-task-inbox-lib.sh'
 saved_library=bin/'fixture-task-inbox-lib.sh'
 inbox_library.rename(saved_library)
 executable(inbox_library, '''#!/bin/sh
fm_task_inbox_write_idempotent() {
 printf 'fixture enqueue failure\n' >&2
 return 73
}
''')
 try:
  failed_steer=control(eid,'steer','--order-id',order_id,'--text','native fixture steer')
  assert failed_steer['state']=='pending' and 'non-zero exit status 73' in failed_steer['message'],failed_steer
  stored=json.loads(reservation.read_text())
  assert stored['binding']=={'order_id':order_id,'execution':eid,'turn':active['turn']},stored
  pending_ui=ui_result('steer',eid,text='native fixture steer')
  assert not pending_ui.stdout,pending_ui.stdout
  diagnostic=json.loads(pending_ui.stderr)
  assert diagnostic['state']=='unconfirmed' and diagnostic['command_id']=='fixture-steer-'+eid,diagnostic
  pending=json.loads(diagnostic['stdout'])
  assert pending['state']=='pending' and 'non-zero exit status 73' in pending['message'],pending
  assert owner.poll() is None and record()==first,'enqueue failure stopped the lifecycle owner'
  child_pid=json.loads((fixture/(eid+'.started')).read_text())['pid']
  os.kill(child_pid,0)
  assert json.loads((receiver/'active.json').read_text())==active,'enqueue failure retired the native turn'
  assert not list(receiver.parent.glob('*.msg')) and not (fixture/(eid+'.steered')).exists()
 finally:
  saved_library.replace(inbox_library)
 result=ui('steer',eid,text='native fixture steer')
 assert not result or result[0]['state']=='accepted',result
 wait(lambda:(fixture/(eid+'.steered')).exists(),'execution-bound native application')
 assert ui('steer',eid,text='native fixture steer')[0]['state']=='accepted'
 assert len(list(pathlib.Path(first['status_path']).parent.glob('primary.inbox/*.msg')))==1
 assert ui('interrupt',eid)[0]['state']=='accepted'
 wait(lambda:(fixture/(eid+'.interrupted')).exists(),'interrupt genuine owned Deck turn')
 assert owner.poll() is None
 assert ui('relaunch',eid)[0]['state']=='accepted'
 second=record(); eid2=second['execution_id']; assert eid2!=eid
 assert ui('relaunch',eid)[0]['state']=='accepted','same request must reconcile the original result'
 assert record()['execution_id']==eid2,'duplicate lifecycle request launched a second child'
 assert second['profile']==first['profile'],'restart changed original launch profile'
 wait(lambda:(fixture/(eid2+'.started')).exists(),'replacement genuine child')
 assert control(eid,'exit',success=False)['state']=='refused'
 assert ui('exit',eid)[0]['state']=='refused'
 assert ui('exit',eid2)[0]['state']=='accepted' and record()['state']=='exited'
 assert owner.poll() is None,'exit must retain manager capability for relaunch'
 exited=record()
 owner_socket=pathlib.Path(exited['socket'])
 saved_token=lab/'token.restore'
 token.rename(saved_token)
 try:
  standalone=subprocess.run([sys.executable,str(bin/'fm-stream-agent.py'),'serve',
       '--hub',url,'--token-file',str(token),'--label','fixture-standalone','--cwd',str(home)],
       env=env,capture_output=True,text=True,timeout=10)
  assert standalone.returncode==1 and not standalone.stdout and 'cannot read --token-file' in standalone.stderr,standalone
  failed_recovery=ui_result('recover-missing',eid2)
  assert not failed_recovery.stdout,failed_recovery.stdout
  diagnostic=json.loads(failed_recovery.stderr)
  pending=json.loads(diagnostic['stdout'])
  assert diagnostic['state']=='unconfirmed' and diagnostic['command_id']=='fixture-recover-missing-'+eid2,diagnostic
  assert pending['state']=='pending' and 'cannot read --token-file' in pending['message'],pending
  assert owner.poll() is None and record()==exited and owner_socket.is_socket(),'token failure retired the manager'
  assert command('discover','--home',str(home))==discovered,'token failure lost discoverable ownership'
  assert control('0'*32,'interrupt',success=False)['state']=='refused','manager stopped handling requests'
 finally:
  saved_token.replace(token)
 retained=ui_result('recover-missing',eid2)
 assert not retained.stdout and json.loads(json.loads(retained.stderr)['stdout'])==pending,'pending receipt repeated lifecycle'
 assert record()==exited and owner_socket.is_socket() and owner.poll() is None
 assert ui('recover-missing',eid2,command_id='fixture-restored-token-'+eid2)[0]['state']=='accepted'
 third=record(); eid3=third['execution_id']; assert eid3 not in (eid,eid2)
 wait(lambda:(fixture/(eid3+'.started')).exists(),'recover missing owned child')
 assert third['profile']==first['profile']
 publication_fault.write_text(json.dumps({'state':'exited','phase':'before'}))
 try:
  failed_exit=control(eid3,'exit')
  assert failed_exit['state']=='pending' and 'fixture registration storage failure' in failed_exit['message'],failed_exit
  assert len(failed_exit['command_id'])==32,failed_exit
  wait(lambda:len(list(publication_attempts.glob('*.json')))>=2,'monitoring retries failed exit publication')
  assert record()==third and owner.poll() is None and pathlib.Path(third['socket']).is_socket()
  stage=registration.with_suffix('.fixture')
  foreign=dict(third,label='foreign-fixture')
  stage.write_text(json.dumps(foreign)); stage.chmod(0o600); stage.replace(registration)
  try:
   refused_foreign=control(eid3,'exit',success=False)
   assert 'registration changed' in refused_foreign['message'] and refused_foreign['command_id'],refused_foreign
   assert record()==foreign and owner.poll() is None,'foreign registration was overwritten or retired'
  finally:
   stage.write_text(json.dumps(third)); stage.chmod(0o600); stage.replace(registration)
 finally:
  publication_fault.unlink()
 wait(lambda:(r if (r:=record()) and r['state']=='exited' else None),'monitoring recovers after restored storage')
 assert control(eid3,'exit','--command-id',failed_exit['command_id'])==failed_exit,'pending exit receipt repeated lifecycle'
 assert control(eid3,'recover-missing')['state']=='accepted'
 for phase in ('before','after'):
  original=record(); original_id=original['execution_id']
  wait(lambda:(fixture/(original_id+'.started')).exists(),'publication fixture child')
  attempt_count=len(list(publication_attempts.glob('*.json')))
  publication_fault.write_text(json.dumps({'state':'running','phase':phase}))
  try:
   failed_relaunch=control(original_id,'relaunch')
   assert failed_relaunch['state']=='pending' and 'fixture registration storage failure' in failed_relaunch['message'],failed_relaunch
   candidate=json.loads((publication_attempts/(str(attempt_count)+'.json')).read_text())
   failed_id=candidate['execution_id']; assert failed_id!=original_id
   request=urllib.request.Request(url+'/v1/tasks/'+failed_id,headers={'Authorization':'Bearer fixture-secret'})
   with urllib.request.urlopen(request) as response: failed_endpoint=json.load(response)['task']
   assert failed_endpoint['closed_by']=='agent','unpublished replacement was left running'
   committed=wait(lambda:(r if (r:=record()) and r['state']=='exited' else None),'failed relaunch reconciles committed identity')
   assert committed['execution_id']==(original_id if phase=='before' else failed_id),committed
   assert committed['profile']==original['profile'] and owner.poll() is None
   assert pathlib.Path(committed['socket']).is_socket()
  finally:
   publication_fault.unlink()
  assert control(original_id,'relaunch','--command-id',failed_relaunch['command_id'])==failed_relaunch
  assert control(committed['execution_id'],'recover-missing')['state']=='accepted'
 for action in ('exit','relaunch'):
  original=record(); original_id=original['execution_id']
  wait(lambda:(fixture/(original_id+'.started')).exists(),'EIO fixture child')
  attempt_count=len(list(publication_attempts.glob('*.json')))
  read_errors=lab/'readback-errors'; read_errors.unlink(missing_ok=True)
  publication_fault.write_text(json.dumps({'state':'exited' if action=='exit' else 'running',
                                           'phase':'fsync-readback'}))
  try:
   failed=control(original_id,action)
   assert failed['state']=='pending' and 'directory fsync failure' in failed['message'],failed
   candidate=json.loads((publication_attempts/(str(attempt_count)+'.json')).read_text())
   assert record()==candidate,'atomic replacement did not publish the owner-authored candidate'
   wait(lambda:read_errors.exists() and int(read_errors.read_text())>=2,
        'monitoring retries unavailable readback even after exit')
   assert owner.poll() is None and pathlib.Path(candidate['socket']).is_socket()
   stage=registration.with_suffix('.fixture')
   foreign=dict(candidate,label='foreign-eio-fixture')
   stage.write_text(json.dumps(foreign)); stage.chmod(0o600); stage.replace(registration)
  finally:
   publication_fault.unlink()
  try:
   refused=control(candidate['execution_id'],'exit',success=False)
   assert 'registration changed' in refused['message'],refused
   assert record()==foreign and owner.poll() is None,'uncertain publication adopted or overwrote a foreign record'
  finally:
   restored=original if action=='exit' else candidate
   stage.write_text(json.dumps(restored)); stage.chmod(0o600); stage.replace(registration)
  committed=wait(lambda:(r if (r:=record()) and r['state']=='exited' else None),
                 'EIO publication reconciles after storage restoration')
  assert committed['execution_id']==candidate['execution_id'] and committed['profile']==original['profile']
  assert control(original_id,action,'--command-id',failed['command_id'])==failed,'EIO pending receipt repeated lifecycle'
  assert control(committed['execution_id'],'relaunch')['state']=='accepted'
 thread_fault=lab/'thread-start-fault'
 for recovery in ('exit','relaunch','recover-missing'):
  original=record(); original_id=original['execution_id']
  wait(lambda:(fixture/(original_id+'.started')).exists(),'thread-start fixture child')
  command_id='fixture-thread-failure-'+recovery
  thread_fault.touch()
  try:
   failed=control(original_id,'relaunch','--command-id',command_id)
   assert failed['state']=='pending' and failed['command_id']==command_id,failed
   assert 'fixture publisher thread start failure' in failed['message'],failed
   attempt=json.loads((lab/'thread-start-attempt.json').read_text())
   failed_id=attempt['endpoint_id']; assert failed_id!=original_id
   try:
    os.kill(attempt['pid'],0)
   except ProcessLookupError:
    pass
   else:
    raise AssertionError('failed publisher left its owned PTY child alive')
   request=urllib.request.Request(url+'/v1/tasks/'+failed_id,headers={'Authorization':'Bearer fixture-secret'})
   with urllib.request.urlopen(request) as response: endpoint=json.load(response)['task']
   assert endpoint['closed_by']=='agent' and endpoint['closed_at'] is not None,endpoint
   assert owner.poll() is None and record()['execution_id']==failed_id
   assert pathlib.Path(record()['socket']).is_socket()
   assert control(original_id,'relaunch','--command-id',command_id)==failed,'thread failure receipt repeated lifecycle'
  finally:
   thread_fault.unlink()
  recovered=control(failed_id,recovery)
  assert recovered['state']=='accepted',recovered
  if recovery=='exit':
   assert record()['state']=='exited' and record()['execution_id']==failed_id
   assert control(failed_id,'recover-missing')['state']=='accepted'
  replacement=record(); assert replacement['state']=='running' and replacement['execution_id']!=failed_id
  wait(lambda:(fixture/(replacement['execution_id']+'.started')).exists(),'restored publisher child')
  assert replacement['profile']==original['profile'] and owner.poll() is None
 helper=bin/'fm-busy-event.sh'; saved_helper=bin/'fixture-busy-event.sh'
 helper.rename(saved_helper)
 executable(helper, '#!/bin/sh\nexit 74\n')
 original=record(); original_id=original['execution_id']
 try:
  helper_failure=control(original_id,'relaunch')
  assert helper_failure['state']=='pending' and 'non-zero exit status 74' in helper_failure['message'],helper_failure
  assert len(helper_failure['command_id'])==32,helper_failure
  submitted_failure=control(original_id,'relaunch','--command-id','fixture-submitted-helper-failure')
  assert submitted_failure['state']=='pending' and submitted_failure['command_id']=='fixture-submitted-helper-failure',submitted_failure
  assert 'non-zero exit status 74' in submitted_failure['message'],submitted_failure
  assert record()['state']=='exited' and record()['execution_id']==original_id and owner.poll() is None
 finally:
  saved_helper.replace(helper)
 reconciled=control(original_id,'relaunch','--command-id',helper_failure['command_id'])
 assert reconciled['state']=='pending' and reconciled['command_id']==helper_failure['command_id'],reconciled
 assert record()['execution_id']==original_id,'helper failure reconciliation started another child'
 explicit=control(original_id,'relaunch','--command-id','fixture-explicit-helper-recovery')
 assert explicit['state']=='accepted' and explicit['command_id']=='fixture-explicit-helper-recovery',explicit
 assert control(record()['execution_id'],'exit')['state']=='accepted'
 owner.terminate(); owner.wait(timeout=15)
 assert not registration.exists(),'clean owner stop must retire registration'
 owner2=launch('pi')
 unsupported=wait(lambda: (r if (r:=record()) and r['state']=='running' else None),'Pi registration')
 eidpi=unsupported['execution_id']
 wait(lambda:(fixture/(eidpi+'.pi')).exists(),'Pi fixture child')
 pi_target=publish_ui_binding(command('discover','--home',str(home)))
 assert 'steer' not in pi_target['supported_operations']
 ui_refused=ui('steer',eidpi,text='native fixture steer')
 assert ui_refused[0]['state']=='refused' and 'primary_adapter_has_no_native_receiver' in ui_refused[0]['reason']
 refused=control(eidpi,'steer',*native_args,success=False)
 assert 'primary_adapter_has_no_native_receiver' in refused['message']
 assert not list(pathlib.Path(unsupported['status_path']).parent.glob('primary.inbox/*.msg'))
 assert control(eidpi,'exit')['state']=='accepted'
 pathlib.Path(unsupported['socket']).unlink()  # Fixture-owned capability only.
 unreachable=control(eidpi,'recover-missing',success=False)
 assert 'primary_owner_unreachable' in unreachable['message'] and len(unreachable['command_id'])==32
 unreachable_ui=ui_result('recover-missing',eidpi)
 assert json.loads(unreachable_ui.stdout)['reason']=='primary_owner_unreachable: no adoption, PID kill or PTY fallback'
 assert json.loads(json.loads(unreachable_ui.stderr)['stdout'])['message']==unreachable['message']
 assert unsupported['capability'] not in unreachable_ui.stdout and str(home) not in unreachable_ui.stdout
 assert sentinel.poll() is None,'lifecycle touched an unrelated fixture process'
 owner2.terminate(); owner2.wait(timeout=15)
 print('PASS managed setup/discovery, genuine endpoint registration, duplicate and unregistered refusals')
 print('PASS owned-child interrupt/exit/relaunch/recover-missing, exact profile replay, stale execution refusal')
 print('PASS browser-safe storage refusal, correlated host-only owner diagnostics and safe named categories')
 print('PASS enqueue subprocess failure stays pending, preserves owner/child and reconciles the original order')
 print('PASS token failure retains manager/socket and pending receipt; restored fixture token permits authorized recovery')
 print('PASS transactional publication, monitoring storage recovery, foreign-registration refusal and CLI reconciliation identities')
 print('PASS atomic replacement survives directory-fsync/readback EIO, refuses foreign records and restores authorized lifecycle')
 print('PASS publisher Thread.start failure cleans up only its owned child and permits exit/relaunch/recover-missing')
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
