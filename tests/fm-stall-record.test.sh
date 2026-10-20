#!/usr/bin/env bash
# Stalled episode timing, conservative evidence, batched delivery and dedup.
set -u
FM_IDLE_SWEEP_TEST_SKIP_RUN=1
export FM_IDLE_SWEEP_TEST_SKIP_RUN
# shellcheck source=tests/fm-idle-sweep.test.sh
. "$(dirname "${BASH_SOURCE[0]}")/fm-idle-sweep.test.sh"

python3 - "$ROOT/bin/fm_stall_record.py" "$TMP_ROOT" <<'PY' || fail 'timing classifier'
import json, pathlib, subprocess, sys
cli, root = sys.argv[1], pathlib.Path(sys.argv[2])
meta, record = root/'timing.meta', root/'timing.json'
meta.write_text('kind=ship\nmode=no-mistakes\nspawn_gen=one\n')
working = 'state: working · source: pane · harness busy'
parked = 'state: parked · source: run-step · review gate'
question = 'review\tneeds-decision\tWhich behavior should be retained?'
def call(now, current=working, decisions='', mode='--observe'):
    args = [sys.executable, cli, str(record), str(meta), current, decisions, '--now', str(now)]
    if mode:
        args.append(mode)
    return json.loads(subprocess.check_output(args))
assert call(10000)['state'] == 'observing'
assert call(17200)['state'] == 'observing'  # strictly more than two hours
r = call(17201)
assert r['state'] == 'stalled' and r['notify'] and not r['questions']
assert r['route'] == 'mate-repair' and r['age_seconds'] == 7201
assert not call(17202, mode='--ack')['notify']
assert not call(18000)['notify']
assert call(18001, 'state: working · source: run-step · review running')['state'] == 'ineligible'
assert call(18002)['age_seconds'] == 0
assert call(18003, parked, question)['state'] == 'observing'
assert call(21603, parked, question)['state'] == 'observing'
r = call(21604, parked, question)
assert r['notify'] and r['questions'] == ['Which behavior should be retained?']
assert r['seconds_since_last_run'] == 0 and r['route'] == 'mate-triage'
assert not call(21605, parked, question, '--ack')['notify']
assert call(21606, parked, 'new\tneeds-decision\tNew question')['age_seconds'] == 0
assert call(21607, parked, '')['state'] == 'ineligible'  # resolution removes ask
for invalid in ['{broken', '{}', '[]', '{"since": -3}', '{"since": "100"}']:
    record.write_text(invalid)
    assert call(25000)['age_seconds'] == 0
r = call(25001)
r['since'] = 999999
record.write_text(json.dumps(r))
assert call(25002)['age_seconds'] == 0
r = call(25003)
r['observed_at'] = 999999
record.write_text(json.dumps(r))
assert call(25004)['age_seconds'] == 0
before = record.read_bytes()
assert call(35000, mode='')['state'] == 'stalled'
assert record.read_bytes() == before  # recovery traversal is read-only
meta.write_text('kind=ship\nmode=no-mistakes\nspawn_gen=two\n')
assert call(35001)['age_seconds'] == 0
assert call(35002, 'state: unknown · source: run-step · lookup failed')['state'] == 'ineligible'
assert call(45000)['age_seconds'] == 0
assert call(45001, working+' · declared-wait: active')['state'] == 'ineligible'
for contents in ['kind=scout\n', 'kind=secondmate\n', 'kind=ship\nmode=direct-PR\n', 'kind=ship\nmode=local-only\n']:
    meta.write_text(contents)
    assert call(45002)['state'] == 'ineligible'
record.unlink()
record.symlink_to(root/'untouched')
p = subprocess.run([sys.executable, cli, str(record), str(meta), working, '', '--observe'], capture_output=True)
assert p.returncode != 0 and not (root/'untouched').exists()
print('ok: strict thresholds, transitions, timing validation, read-only traversal and symlink refusal')
PY

for route in main parent; do
  dir=$(new_case "stall-$route")
  [ "$route" != parent ] || make_secondmate_home "$dir" mate
  add_worker "$dir" implementation 'state: working · source: pane · busy' 90000
  add_worker "$dir" decision 'state: parked · source: status-log · pending choice' 90000
  printf 'needs-decision [key=choice]: Keep the old behavior?\n' > "$dir/home/state/decision.status"
  old=$(( $(date +%s) - 8000 ))
  python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/implementation.stall.json" \
    "$dir/home/state/implementation.meta" "$(cat "$dir/home/crew/implementation")" '' --observe --now "$old" >/dev/null
  python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/decision.stall.json" \
    "$dir/home/state/decision.meta" "$(cat "$dir/home/crew/decision")" \
    $'choice\tneeds-decision\tKeep the old behavior?' --observe --now "$old" >/dev/null
  sweep "$dir" scan --now || fail 'stall scan'
  [ "$(summary_of "$dir" implementation)" = 'stalled none' ] || fail "implementation not stalled: $(cat "$dir/home/state/idle-sweep.json") $(cat "$dir/home/state/idle-sweep/implementation.stall.json")"
  [ "$(summary_of "$dir" decision)" = 'stalled none' ] || fail 'decision not stalled'
  target="$dir/home/state/.wake-queue"
  [ "$route" != parent ] || target="$dir/parent/state/mate.status"
  [ "$(grep -c 'stalled tasks digest:' "$target")" = 1 ] || fail 'not one batched digest'
  assert_contains "$(cat "$target")" 'Keep the old behavior?' 'question missing'
  assert_contains "$(cat "$target")" 'mate repair:' 'repair not distinguished'
  sweep "$dir" scan --now || fail 'repeat scan'
  [ "$(grep -c 'stalled tasks digest:' "$target")" = 1 ] || fail 'duplicate digest'
  [ ! -s "$dir/home/control-calls" ] || fail 'stall caused relaunch'
  [ ! -s "$dir/home/teardown-calls" ] || fail 'stall caused cleanup'
  assert_no_captain_call "$dir" 'stall digest'
  touch "$dir/home/held/decision"
  sweep "$dir" scan --now || fail 'held scan'
  [ "$(summary_of "$dir" decision)" = 'held none' ] || fail 'hold overridden'
  pass "stalled tasks batch and deduplicate on $route route without changing authority"
done

dir=$(new_case stall-redelivery)
add_worker "$dir" implementation 'state: working · source: pane · busy' 90000
old=$(( $(date +%s) - 8000 ))
python3 "$dir/bin/fm_stall_record.py" "$dir/home/state/idle-sweep/implementation.stall.json" \
  "$dir/home/state/implementation.meta" "$(cat "$dir/home/crew/implementation")" '' --observe --now "$old" >/dev/null
mkdir "$dir/home/state/.wake-queue"
sweep "$dir" scan --now || fail 'failed-delivery scan'
[ "$(jq -r .notify "$dir/home/state/idle-sweep/implementation.stall.json")" = true ] || fail 'failed delivery acknowledged'
rmdir "$dir/home/state/.wake-queue"
sweep "$dir" scan --now || fail 'redelivery scan'
[ "$(wake_count "$dir" 'stalled tasks digest:')" = 1 ] || fail 'redelivery missing'
[ "$(jq -r .reported "$dir/home/state/idle-sweep/implementation.stall.json")" != null ] || fail 'delivery not acknowledged'
pass 'failed digest publication leaves the episode eligible for redelivery'
