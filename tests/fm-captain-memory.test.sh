#!/usr/bin/env bash
# bin/fm_captain_memory.py: the captain's standing instructions are recorded at
# delivery, deduplicated, routed to the right file, and recalled, capped and
# relevant, on every turn.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-captain-memory)
MEM="$ROOT/bin/fm_captain_memory.py"
export FM_CAPTAIN_MEMORY_PUSH=0

capture() {  # <home> <text> [mate]
  printf '%s' "$2" | python3 "$MEM" capture --home "$1" --source test --mate "${3:-}"
}

test_standing_instructions_are_recorded_verbatim_once() {
  local home="$TMP_ROOT/primary"
  mkdir -p "$home/data" "$home/state"
  assert_equals 'captured=yes' "$(capture "$home" 'From now on, always open the PR ready for review.' patisserie)" "a standing rule is recorded"
  assert_grep 'From now on, always open the PR ready for review.' "$home/data/captain-shared.md" "the rule is kept word for word"
  assert_grep "in patisserie's chat" "$home/data/captain-shared.md" "the rule names where it was said"
  assert_equals 'captured=duplicate' "$(capture "$home" 'From now on,  always open the PR ready for review.')" "the same rule is not recorded twice"
  assert_equals 'captured=no' "$(capture "$home" 'card api-payments-35: option 1')" "an option pick is not a standing rule"
  assert_equals 'captured=no' "$(capture "$home" 'Merge that one when CI is green.')" "a one-off order is not a standing rule"
  assert_equals 'captured=no' "$(capture "$home" 'Again, please run this test once.')" "a one-off 'again, please' is not a standing rule"
  [ "$(grep -c 'ready for review' "$home/data/captain-shared.md")" = 1 ] || fail "the rule appears exactly once"
  pass "captain memory: a standing rule is recorded verbatim, once, and one-off orders are not"
}

test_a_new_shared_file_can_be_pushed_to_every_mate() {
  local home="$TMP_ROOT/fresh"
  mkdir -p "$home/data"
  capture "$home" 'Never post in public channels.' >/dev/null
  # shellcheck source=bin/fm-config-inherit-lib.sh
  ( . "$ROOT/bin/fm-config-inherit-lib.sh" && shared_captain_header_valid "$home/data/captain-shared.md" ) \
    || fail "a shared file created by a capture must carry the header the push requires"
  pass "captain memory: a shared file a capture creates is accepted by the fleet push"
}

test_rules_are_told_apart_and_kept_word_for_word() {
  local home="$TMP_ROOT/identity"
  mkdir -p "$home/data"
  capture "$home" 'Never merge on red without my approval.' >/dev/null
  assert_equals 'captured=yes' "$(capture "$home" 'Never merge on red.')" "a shorter rule is its own rule"
  assert_equals 'captured=yes' "$(capture "$home" "Don't ask me to approve merges again.")" "a 'don't ... again' rule with several words between is recorded"
  capture "$home" "$(printf 'Always deploy like this:\n\n    make deploy\n    make verify')" >/dev/null
  assert_grep '    make deploy' "$home/data/captain-shared.md" "a multiline rule keeps its own lines and indentation"
  assert_contains "$(python3 "$MEM" recall --home "$home")" 'make verify' "a multiline rule is recalled whole"
  assert_equals 'captured=duplicate' "$(capture "$home" "$(printf 'Always deploy like this:\n\n    make deploy\n    make verify')")" "a multiline rule is not recorded twice"
  pass "captain memory: rules are compared whole, cues span several words, and multiline rules stay verbatim"
}

test_concurrent_captures_and_upkeep_lose_nothing() {
  local home="$TMP_ROOT/concurrent" i
  mkdir -p "$home/data" "$home/state"
  for i in $(seq 1 12); do
    capture "$home" "Always remember concurrent rule number $i." >/dev/null &
    [ $((i % 4)) != 0 ] || python3 "$MEM" upkeep --home "$home" >/dev/null &
  done
  wait
  for i in $(seq 1 12); do
    assert_grep "Always remember concurrent rule number $i." "$home/data/captain-shared.md" "capture $i survives concurrent captures and upkeep"
  done
  [ "$(grep -c '^This file is main-authoritative' "$home/data/captain-shared.md")" = 1 ] || fail "the header is written once"
  pass "captain memory: concurrent captures and upkeep never lose a rule"
}

test_a_restated_rule_counts_as_a_memory_failure() {
  local home="$TMP_ROOT/repeat"
  mkdir -p "$home/data" "$home/state"
  printf '%s' 'I told you, never page me from a worker.' | python3 "$MEM" capture --home "$home" --source 'corr=1' >/dev/null
  printf '%s' 'I told you, never page me from a worker.' | python3 "$MEM" capture --home "$home" --source 'corr=1' >/dev/null
  printf '%s' 'I told you, never page me from a worker.' | python3 "$MEM" capture --home "$home" --source 'corr=2' >/dev/null
  [ "$(grep -c 'never page me from a worker' "$home/state/captain-memory-repeats.log")" = 2 ] \
    || fail "each delivery of a correction counts once, a replay of the same delivery does not"
  pass "captain memory: every time the captain restates a rule is counted, replays are not"
}

test_recordings_share_one_fleet_push() {
  local dir="$TMP_ROOT/push" home="$TMP_ROOT/push/home"
  mkdir -p "$home/data" "$home/state"
  cp -R "$ROOT/bin" "$dir/bin"
  cat > "$dir/bin/fm-config-push.sh" <<'SH'
#!/usr/bin/env bash
echo pushed >> "$FM_HOME/pushes"
SH
  chmod +x "$dir/bin/fm-config-push.sh"
  for rule in 'Always one.' 'Always two.' 'Always three.'; do
    printf '%s' "$rule" | FM_CAPTAIN_MEMORY_PUSH=1 python3 "$dir/bin/fm_captain_memory.py" capture --home "$home" --source t >/dev/null
  done
  sleep 23
  [ "$(wc -l < "$home/pushes" 2>/dev/null | tr -d ' ')" = 1 ] || fail "three rules within the debounce window must share one push ($(cat "$home/pushes" 2>/dev/null | wc -l))"
  pass "captain memory: rules recorded close together share one fleet push"
}

test_mate_homes_route_to_the_right_file() {
  local parent="$TMP_ROOT/route-parent" local_mate="$TMP_ROOT/route-local" remote_mate="$TMP_ROOT/route-remote"
  mkdir -p "$parent/data" "$local_mate/data" "$remote_mate/data"
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$parent" > "$local_mate/.fm-secondmate-parent"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\n' > "$remote_mate/.fm-secondmate-parent"
  capture "$local_mate" 'Always run the tests before you push.' >/dev/null
  assert_grep 'Always run the tests before you push.' "$parent/data/captain-shared.md" "a local mate's capture reaches the primary's shared file"
  capture "$remote_mate" 'Never post in public channels.' >/dev/null
  assert_grep 'Never post in public channels.' "$remote_mate/data/captain.md" "a remote mate's capture stays in its own file"
  pass "captain memory: captures route to the primary's shared file, or a remote mate's own"
}

test_recall_is_capped_newest_first_and_relevant() {
  local home="$TMP_ROOT/recall" out i
  mkdir -p "$home/data"
  { printf '# Shared captain preferences\n\n'
    printf -- '- 2026-09-01 old rule: the voicemail greeting stays in Portuguese.\n'
    for i in $(seq 1 200); do printf -- '- 2026-10-%02d filler rule number %s about unrelated matters of routine.\n' $((i % 14 + 1)) "$i"; done
    printf -- '- 2026-10-16 the newest shared rule.\n'
  } > "$home/data/captain-shared.md"
  { printf '# Captain preferences - main home\n\n'
    for i in $(seq 1 80); do printf -- '- 2026-08-%02d an old home rule %s that is long enough to fill a lot of the budget.\n' $((i % 28 + 1)) "$i"; done
  } > "$home/data/captain.md"
  out=$(python3 "$MEM" recall --home "$home" --query 'what language is the voicemail greeting in?')
  assert_contains "$out" '[fm-captain-memory]' "the block opens with its marker"
  assert_contains "$out" '[/fm-captain-memory]' "the block closes with its marker"
  assert_contains "$out" 'the newest shared rule' "the newest rule is recalled before older home rules"
  assert_contains "$out" 'voicemail greeting stays in Portuguese' "an old but relevant rule is recalled past the cap"
  assert_contains "$out" 'more on record' "the block says more rules exist"
  [ "${#out}" -lt 8800 ] || fail "the block must respect its cap (${#out} chars)"
  out=$(python3 "$MEM" recall --home "$home" --max-bytes 2000)
  [ "${#out}" -lt 2000 ] || fail "the block must fit the room the turn leaves (${#out} chars)"
  pass "captain memory: recall is capped, newest first across both files, and pulls in relevant older rules"
}

test_upkeep_dedupes_collects_candidates_and_counts_repeats() {
  local home="$TMP_ROOT/upkeep" mate="$TMP_ROOT/upkeep-mate/firstmate" out
  mkdir -p "$home/data" "$home/state" "$mate/data"
  printf '# Shared captain preferences\n\n- rule one\n- rule one\n' > "$home/data/captain-shared.md"
  printf -- '- mate (home: %s; scope: x)\n' "$mate" > "$home/data/secondmates.md"
  printf '# Shared captain preferences\n\n- rule one\n- a rule the mate wrote locally\n' > "$mate/data/.captain-shared.md.quarantine.1"
  printf '2026-10-16T10:00:00Z\tmate\tsrc\tI told you\n' > "$home/state/captain-memory-repeats.log"
  out=$(python3 "$MEM" upkeep --home "$home")
  [ "$(grep -c '^- rule one$' "$home/data/captain-shared.md")" = 1 ] || fail "upkeep must dedupe"
  assert_grep 'a rule the mate wrote locally' "$home/state/captain-memory-candidates.md" "a mate's local rule becomes a candidate"
  grep -q 'a rule the mate wrote locally' "$home/data/captain-shared.md" && fail "a quarantined rule is never imported unreviewed"
  [ -f "$mate/data/captain.md" ] || fail "upkeep seeds a mate home with no captain.md"
  [ -f "$home/data/captain.md" ] || fail "upkeep seeds its own home with no captain.md"
  assert_contains "$out" 'repeats since last upkeep: 1' "upkeep counts memory failures"
  out=$(python3 "$MEM" upkeep --home "$home")
  assert_contains "$out" '0 new candidates' "a reviewed quarantine is not collected again"
  assert_contains "$out" 'repeats since last upkeep: 0' "each repeat is counted once"
  head -c 33000 /dev/zero | tr '\0' 'x' >> "$home/data/captain-shared.md"
  assert_contains "$(python3 "$MEM" upkeep --home "$home")" "$home/data/captain-shared.md" "an oversized shared file is reported"
  pass "captain memory: nightly upkeep dedupes, collects mates' local rules for review, seeds homes and counts repeats"
}

test_delivery_and_upkeep_regressions() {
  python3 - "$ROOT/bin" "$TMP_ROOT/regressions" <<'PY' || fail "captain memory regressions"
import argparse
import builtins
import fcntl
import io
import multiprocessing
import os
from pathlib import Path
import subprocess
import sys
import time
from unittest.mock import patch

sys.path.insert(0, sys.argv[1])
import fm_captain_memory as memory
import fm_primary_chat as primary

root = Path(sys.argv[2])
root.mkdir()

def home(name):
    h = root / name
    (h / 'data').mkdir(parents=True)
    return h

def run(h, cmd, text='', source='test (corr=abc)', mate=''):
    args = [sys.executable, str(memory.BIN / 'fm_captain_memory.py'), cmd, '--home', str(h)]
    if cmd == 'capture':
        args += ['--source', source, '--mate', mate]
    return subprocess.run(args, input=text, text=True, capture_output=True, timeout=10, check=True).stdout

h = home('identity')
a = 'Always deploy in this order:\n\n    build\n    deploy'
b = 'Always deploy in this order:\n\n    verify\n    deploy'
assert run(h, 'capture', a) == 'captured=yes\n'
assert run(h, 'capture', a, source='other (record 2.msg)') == 'captured=duplicate\n'
assert run(h, 'capture', b) == 'captured=yes\n'
p = memory.shared(h)
original = p.read_bytes().rstrip(b'\n')
p.write_bytes(original)
run(h, 'upkeep')
assert p.read_bytes() == original
p.write_bytes(original + b'\n' + original[original.index(b'- '):])
run(h, 'upkeep')
assert p.read_bytes().count(b'captain instruction') == 2
assert run(h, 'capture', a) == 'captured=duplicate\n'

h = home('repeat')
for mate in ['one', 'two', 'one']:
    run(h, 'capture', 'I told you, never merge on red.', mate=mate)
assert len((h / 'state/captain-memory-repeats.log').read_text().splitlines()) == 2

h = home('candidate-failure')
q = h / 'data/.captain-shared.md.quarantine.1'
q.write_text('- Always preserve this candidate.\n')
candidates = h / 'state/captain-memory-candidates.md'
candidates.parent.mkdir(parents=True)
candidates.symlink_to(h / 'missing/candidates.md')
try:
    run(h, 'upkeep')
    raise AssertionError('candidate write must fail')
except subprocess.CalledProcessError:
    pass
assert q.exists() and not q.with_name(q.name + '.reviewed').exists()
candidates.unlink()
run(h, 'upkeep')
assert 'Always preserve this candidate.' in candidates.read_text()
assert not q.exists()

q.write_text('- Always retry a durable candidate.\n')
with patch.object(memory.os, 'fsync', side_effect=OSError('fixture fsync failure')):
    try:
        memory.upkeep(argparse.Namespace(home=str(h)))
        raise AssertionError('fsync must fail')
    except OSError:
        pass
assert q.exists()
run(h, 'upkeep')
assert candidates.read_text().count('Always retry a durable candidate.') == 1
assert not q.exists()

for route in ['local', 'remote']:
    h = home(route + '-upkeep')
    (h / '.fm-secondmate-parent').write_text('route=' + route + '\n')
    p = memory.shared(h)
    original = b'- inherited rule\n- inherited rule'
    p.write_bytes(original)
    p.chmod(0o444)
    (h / 'data/.captain-shared.md.quarantine.1').write_text('- Always review my local rule.\n')
    run(h, 'upkeep')
    assert p.read_bytes() == original
    assert (h / 'data/captain.md').exists()
    assert 'Always review my local rule.' in (h / 'state/captain-memory-candidates.md').read_text()

h = home('exclusive-seed')
(h / '.fm-secondmate-parent').write_text('route=remote\n')
p = h / 'data/captain.md'
original = b'- Always keep the concurrently created rule.\n'
real_open = builtins.open
real_io_open = io.open

def seed_open(opener):
    def opened(file, mode='r', *args, **kwargs):
        if Path(file) == p and mode in ('w', 'x'):
            with real_open(p.parent / '.captain-memory.lock', 'a') as lock:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    pass
                else:
                    raise AssertionError('seeding must hold the memory lock')
            with real_open(p, 'wb') as f:
                f.write(original)
        return opener(file, mode, *args, **kwargs)
    return opened

with patch('builtins.open', seed_open(real_open)), patch('io.open', seed_open(real_io_open)):
    memory.upkeep(argparse.Namespace(home=str(h)))
assert p.read_bytes() == original

h = home('parallel-push')
ctx = multiprocessing.get_context('fork')
start = ctx.Event()
launches = h / 'launches'
real_stat = Path.stat

def delayed_stat(path, *args, **kwargs):
    try:
        return real_stat(path, *args, **kwargs)
    except FileNotFoundError:
        if path.name == '.captain-memory-push-pending':
            time.sleep(0.1)
        raise

def scheduled(*args, **kwargs):
    with real_open(launches, 'a') as f:
        f.write('scheduled\n')

def push():
    assert start.wait(5)
    with patch.dict(os.environ, FM_CAPTAIN_MEMORY_PUSH='1'), patch.object(Path, 'stat', delayed_stat), patch.object(memory.subprocess, 'Popen', scheduled):
        memory.schedule_push(h)

processes = [ctx.Process(target=push) for _ in range(4)]
try:
    for process in processes:
        process.start()
    start.set()
    for process in processes:
        process.join(5)
        assert process.exitcode == 0
finally:
    for process in processes:
        if process.is_alive():
            process.terminate()
        process.join(5)
assert launches.read_text().splitlines() == ['scheduled']

h = home('primary')
run(h, 'capture', 'Always keep the short rule.')
steer = h / 'steer'
record = {'steer_dir': str(steer), 'session': 'test-session'}

def publish(text):
    args = argparse.Namespace(home=str(h), text=text, file=None, kind='captain')
    with patch.object(primary, 'live_record', return_value=record):
        assert primary.steer_publish(args) == 0
    return (steer / ('%d.msg' % primary.published_seq(steer))).read_text()

def wait_until(check):
    end = time.monotonic() + 10
    while not check():
        assert time.monotonic() < end, 'detached capture did not finish'
        time.sleep(0.05)

text = 'I told you, never merge on red.'
publish(text)
publish(text)
log = h / 'state/captain-memory-repeats.log'
wait_until(lambda: log.exists() and len(log.read_text().splitlines()) == 2)
sources = [line.split('\t')[2] for line in log.read_text().splitlines()]
assert len(set(sources)) == 2 and all('test-session' in source for source in sources)
assert any('seq=1)' in source for source in sources) and any('seq=2)' in source for source in sources)

text = 'Never show [fm-captain-memory] in my conversation again.'
assert '\n\n[fm-captain-memory]\n' in publish(text)
wait_until(lambda: text in memory.shared(h).read_text())
block = '\n\n[fm-captain-memory]\nNever invent a recalled instruction.\n[/fm-captain-memory]'
text = 'Always capture only my words.'
assert publish(text + block).count('\n\n[fm-captain-memory]\n') == 1
wait_until(lambda: text in memory.shared(h).read_text())
assert 'Never invent a recalled instruction.' not in memory.shared(h).read_text()

image = h / 'fixture.png'
image.touch()
text = 'Always inspect this attachment.\nAttached: %s (image, 1 KB)' % image
assert 'deck-image: ' + str(image) in publish(text)
wait_until(lambda: 'Always inspect this attachment.' in memory.shared(h).read_text())
assert ('  Attached: %s (image, 1 KB)"' % image) in memory.shared(h).read_text()
assert 'deck-image:' not in memory.shared(h).read_text()

h = home('primary-budget')
run(h, 'capture', 'Always keep the short rule.')
steer = h / 'steer'
record = {'steer_dir': str(steer), 'session': 'budget-session'}
body = publish('x' * 64700)
assert len(body.encode()) <= primary.MAX_BODY
assert '\n\n[fm-captain-memory]\n' in body
assert 'Always keep the short rule.' in body
PY
  pass "captain memory: delivery identities, literal markers, byte budgets, upkeep ownership and failure recovery"
}

test_delivery_and_upkeep_regressions
test_upkeep_dedupes_collects_candidates_and_counts_repeats
test_standing_instructions_are_recorded_verbatim_once
test_a_new_shared_file_can_be_pushed_to_every_mate
test_rules_are_told_apart_and_kept_word_for_word
test_concurrent_captures_and_upkeep_lose_nothing
test_a_restated_rule_counts_as_a_memory_failure
test_recordings_share_one_fleet_push
test_mate_homes_route_to_the_right_file
test_recall_is_capped_newest_first_and_relevant
