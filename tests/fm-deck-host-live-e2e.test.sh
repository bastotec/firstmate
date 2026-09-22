#!/usr/bin/env bash
# Opt-in real Deck secondmate host check: startup, driver-owned lock, durable
# steering-inbox watcher turn, acknowledgement, and clean exit without a TUI.
# Requires a configured Deck gateway; FM_DECK_LIVE_MODEL names its route.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate opt-in FM_DECK_LIVE deck python3 jq
: "${FM_DECK_LIVE_MODEL:?set FM_DECK_LIVE_MODEL to a supported gateway route}"
export FM_DECK_LIVE_MODEL
deck --version
LAB=$(fm_test_tmproot fm-deck-host-live)
python3 - "$ROOT" "$LAB" <<'PYTHON'
import os, pathlib, signal, subprocess, time, shutil, sys
root=pathlib.Path(sys.argv[1])
lab=pathlib.Path(sys.argv[2])
home=lab/'home'
for d in ['state','data','config','projects']:(home/d).mkdir(parents=True,exist_ok=True)
(home/'bin').symlink_to(root/'bin') if not (home/'bin').exists() else None
(home/'.fm-secondmate-home').write_text('host-check\n')
(home/'config/backlog-backend').write_text('manual\n')
(home/'config/backend').write_text('tmux\n')
(home/'AGENTS.md').write_text('This is an isolated Deck host verification home, not a production supervisor. The driver has already run session start. Never run it again. Do not spawn, steer, inspect other homes, install, repair, sync, or change any external resource. Act only on the explicit live-check prompt and its inbox notes in this home. Treat startup diagnostics as evidence, not repair instructions.\n')
parent=lab/'parent';parent.mkdir(exist_ok=True)
env=dict(os.environ,FM_HOME=str(home),FM_ROOT_OVERRIDE='',FM_STATE_OVERRIDE='',FM_DATA_OVERRIDE='',FM_CONFIG_OVERRIDE='',FM_PROJECTS_OVERRIDE='',FM_POLL='1',FM_SIGNAL_GRACE='1',FM_HEARTBEAT='999999',FM_DECK_MAX_TURNS='20',FM_DECK_DEADLINE_SECS='180',FM_SUPERVISION_MODEL='autoarm')
for k in ['CLAUDECODE','PI_CODING_AGENT','FM_PI_HARNESS','GROK_AGENT','CURSOR_AGENT','CURSOR_INVOKED_AS','GEMINI_CLI','FM_OMP_HARNESS']:env.pop(k,None)
gen=subprocess.check_output([str(root/'bin/fm-busy-event.sh'),'arm',str(parent),'host-check'],text=True).strip()
prompt='This is a bounded live adapter verification, not production work. Read the supplied startup digest; do not rerun session start or repair any diagnostic. Write exactly READY to ready.txt in this home, then finish. If the home watcher wakes you later, first drain bin/fm-wake-drain.sh, handle only the notes in this isolated home (including startup-network reports without repair), acknowledge the handled inbox note and the exact WAKE_ACK_REQUIRED command after handling. Do not run or arm a watcher: the host does that. Never inspect other homes or launch workers.'
cmd=['bash','-c','exec -a fm-deck-worker bash "$@"','fm-deck-worker',str(root/'bin/fm-deck-worker.sh'),'--secondmate','--id','host-check','--state',str(parent),'--gen',gen,'--deck',shutil.which('deck'),'--model',os.environ['FM_DECK_LIVE_MODEL'],'--',prompt]
with (lab/'pane.log').open('w') as out:
 p=subprocess.Popen(cmd,stdin=subprocess.PIPE,stdout=out,stderr=subprocess.STDOUT,text=True,env=env,start_new_session=True)
 (lab/'pid').write_text(str(p.pid))
 try:
  def wait(path):
   for _ in range(900):
    if path.exists(): return
    if p.poll() is not None: raise RuntimeError('host exited '+str(p.returncode))
    time.sleep(.2)
   raise RuntimeError('timeout '+str(path))
  wait(home/'ready.txt')
  time.sleep(3)
  print('startup completed; stable driver owns home lock',flush=True)
  note=subprocess.check_output([str(root/'bin/fm-inbox.sh'),'note','Live verification only: write exactly WAKE_HANDLED to wake-handled.txt in this isolated home, then acknowledge this inbox note and the handled wake queue. Do not do any production work.'],env=env,text=True)
  assert note.startswith('queued ')
  wait(home/'wake-handled.txt')
  for _ in range(600):
   if not (home/'state/.wake-queue').exists() or not (home/'state/.wake-queue').read_text().strip():break
   if p.poll() is not None:raise RuntimeError('host exited before acknowledgement')
   time.sleep(.2)
  else:raise RuntimeError('wake unacknowledged')
  time.sleep(3)
  assert (home/'state/.lock').read_text().strip()==str(p.pid)
  assert list((parent/'host-check.inbox/handled').glob('*.msg')), 'wake did not use durable steering inbox'
  assert not list((parent/'host-check.inbox').glob('*.msg')), 'steering wake was not acknowledged'
  assert not (parent/'host-check.status').exists() or 'failed:' not in (parent/'host-check.status').read_text()
  p.stdin.write('/quit\n');p.stdin.flush()
  assert p.wait(timeout=30)==0
  print('PASS real Deck startup, stable driver lock, watcher wake-as-next-turn, acknowledgement, and clean exit',flush=True)
 except Exception:
  print((lab/'pane.log').read_text(), file=sys.stderr)
  raise
 finally:
  if p.poll() is None:
   os.killpg(p.pid, signal.SIGTERM)
   try:p.wait(timeout=30)
   except subprocess.TimeoutExpired:
    os.killpg(p.pid, signal.SIGKILL);p.wait()
PYTHON
