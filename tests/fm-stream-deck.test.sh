#!/usr/bin/env bash
# Executable command application regressions for Deck's stream receiver.
set -eu
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAB=$(fm_test_tmproot fm-stream-deck)
trap fm_test_cleanup EXIT
python3 - "$ROOT" "$LAB" <<'PY'
import importlib.util, pathlib, subprocess, sys
root, lab = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(root/'bin'))
from fm_stream_deck import Receiver
spec = importlib.util.spec_from_file_location('stream_agent', root/'bin/fm-stream-agent.py')
module = importlib.util.module_from_spec(spec); spec.loader.exec_module(module)
class Pty:
    def alive(self): return True
    def write(self, data): raise AssertionError('Deck steer must never write PTY')
    def foreground_processes(self): return [{'args': 'fm-deck-worker bash fm-deck-worker.sh'}]
agent = module.Agent.__new__(module.Agent)
agent.pty = Pty(); agent.endpoint_id = 'e'*32; agent.status_path = str(lab/'task.status')
def command(id='one', text='change course', execution=None):
    return {'kind':'steer','command_id':id,'endpoint_id':execution or agent.endpoint_id,
            'payload':{'order_id':id,'execution_id':execution or agent.endpoint_id,'text':text}}
r = Receiver(str(lab), 'task', agent.endpoint_id)
assert agent.apply_command(command())[0] is False
subprocess.check_call([sys.executable,str(root/'bin/fm_stream_deck.py'),'start',str(lab),
                       'task',agent.endpoint_id,'old','0'], stdout=subprocess.DEVNULL)
assert agent.apply_command(command())[0] is False
r.end(); projection = pathlib.Path(r.start('live', True))
for name in ('task.status','task.turn-ended','task.progress','task.busy-state'):
    (lab/name).write_text('sentinel\n')
before = {p.name:(p.read_bytes(), p.stat().st_mtime_ns) for p in lab.glob('task.*') if p.is_file()}
assert agent.apply_command(command(execution='f'*32))[0] is False
assert not list((lab/'task.inbox').glob('*.msg'))
assert agent.apply_command(command()) == (None, 'Deck application pending')
sources = list((lab/'task.inbox').glob('*.msg')); assert len(sources)==1
seq = str(int(sources[0].stem)); message = projection/(seq+'.msg')
assert message.read_text().startswith('change course\n\nAfter handling')
assert agent.apply_command(command()) == (None, 'Deck application pending')
assert len(list((lab/'task.inbox').glob('*.msg')))==1
# Deck's durable handled proof reconciles a lost response after turn completion.
(projection/'handled').mkdir(); message.rename(projection/'handled'/message.name)
sources[0].rename(lab/'task.inbox/handled'/sources[0].name)
r.end()
assert agent.apply_command(command()) == (True, '')
next_projection = pathlib.Path(r.start('next', True))
assert agent.apply_command(command()) == (True, '')
assert not list(next_projection.glob('*.msg'))
assert agent.apply_command(command(text='different'))[0] is False
# Finish wins: a redelivery cannot cross into another turn.
assert agent.apply_command(command('race'))[0] is None
r.end(); newer = pathlib.Path(r.start('newer', True))
assert agent.apply_command(command('race'))[0] is None
assert not list(newer.glob('*.msg'))
# Crash after source publication: reconstruct all earlier projections first.
binding={'execution':agent.endpoint_id,'turn':'newer','order_id':'crash'}
r.enqueue(binding,'crash-safe')
assert agent.apply_command(command('following','later'))[0] is None
projected=sorted(newer.glob('*.msg'),key=lambda p:int(p.stem))
assert [p.read_text().split('\n\nAfter handling')[0] for p in projected]==['crash-safe','later']
(newer/'rejected').mkdir(); projected[-1].rename(newer/'rejected'/projected[-1].name)
assert agent.apply_command(command('following','later'))[0] is False
assert before == {p.name:(p.read_bytes(),p.stat().st_mtime_ns) for p in lab.glob('task.*') if p.is_file()}
print('PASS active-turn delivery, duplicate/lost-ack reconciliation, stale execution, finish race, unavailable interface, ordered recovery, and untouched evidence')
PY
