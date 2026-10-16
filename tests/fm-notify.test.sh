#!/usr/bin/env bash
# Behavior tests for bin/fm-notify.sh: a notice record the Fleet feed pushes, with its
# duplicate, rate-limit and quiet-hours guards. The clock is fixed; nothing leaves the home.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(fm_test_tmproot fm-notify)
H="$T/home"
mkdir -p "$H/state" "$H/config"
N="$ROOT/bin/fm-notify.sh"
NOON=$(python3 -c 'import time; t=time.localtime(); print(int(time.mktime((t.tm_year,t.tm_mon,t.tm_mday,12,0,0,0,0,-1))))')
notify() { FM_HOME="$H" FM_NOTIFY_NOW="${AT:-$NOON}" "$N" "$@" 2>&1; }
expect_code() { [ "$1" = "$2" ] || fail "$3: expected exit $1, got $2"; }

for kind in ship scout; do
  fm_write_meta "$H/state/w-1.meta" "kind=$kind"
  rc=0
  out=$(FM_TASK_ID=w-1 notify --urgent "Blocked on a key") || rc=$?
  expect_code 3 "$rc" "a $kind cannot notify its mate's captain"
  assert_contains "$out" "needs-decision" "the worker is directed to its mate"
  assert_absent "$H/state/notices" "a refused worker creates no notification state"
done
pass "ships and scouts must escalate through their mate"

out=$(notify --title "Report ready" --link https://github.com/a/b/pull/7 "The VIP report is done.")
[[ "$out" =~ ^notice=(nt-[0-9]{8}T[0-9]{6}-[0-9a-f]{6})\ push$ ]] || fail "unexpected: $out"
id=${BASH_REMATCH[1]}
rec="$H/state/notices/$id.json"
assert_equals '{"version": 1, "title": "Report ready", "body": "The VIP report is done.", "urgent": false, "quiet": false, "link": "https://github.com/a/b/pull/7"}' \
  "$(python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); [r.pop(k) for k in ("id","created")]; print(json.dumps(r))' "$rec")" "the record the feed and the app read"
pass "a notice is one record with its title, body, urgency and link"

out=$(AT=$((NOON + 60)) notify --title "report  ready" "The VIP report is done.")
assert_equals "notice=duplicate: $id" "$out" "the same notice within 30 minutes"
for i in 1 2 3 4 5; do AT=$((NOON + 100 + i)) notify "update $i" >/dev/null; done
set +e; out=$(AT=$((NOON + 200)) notify "one too many"); rc=$?; set -e
expect_code 3 "$rc" "the seventh plain notice in an hour"
assert_contains "$out" "notice=limited: 6 notices in the last hour" "the limit says why"
out=$(AT=$((NOON + 201)) notify --urgent "The deploy is blocked on your key")
assert_contains "$out" " push" "an urgent notice still goes through the plain limit"
pass "duplicates and an hour's flood are held back, urgent ones still go"

AT=$((NOON + 12 * 3600)) notify "past midnight" > "$T/q"
assert_contains "$(cat "$T/q")" " quiet" "a plain notice at midnight is kept quiet"
assert_contains "$(AT=$((NOON + 12 * 3600 + 5)) notify --urgent "server down")" " push" "urgent rings in quiet hours"
echo off > "$H/config/notify-quiet"
assert_contains "$(AT=$((NOON + 12 * 3600 + 9)) notify "quiet off")" " push" "quiet hours can be turned off"
pass "quiet hours keep plain notices off the phone, not urgent ones"

AT=$((NOON + 9 * 86400)) notify "a week later" >/dev/null
[ ! -e "$rec" ] || fail "a week-old notice was kept"
set +e; out=$(notify --link http://x "body"); rc=$?; set -e
expect_code 2 "$rc" "a plain-http link"
set +e; out=$(notify ""); rc=$?; set -e
expect_code 2 "$rc" "an empty body"
pass "old notices go, and bad input is refused"

python3 - "$N" "$T/concurrent" "$NOON" <<'PY'
import concurrent.futures, json, os, pathlib, subprocess, sys, threading

script, home, now = sys.argv[1:]
env = dict(os.environ, FM_HOME=home, FM_NOTIFY_NOW=now)
notices = pathlib.Path(home) / "state" / "notices"

def burst(bodies, urgent=False):
    barrier = threading.Barrier(len(bodies), timeout=10)
    def send(body):
        barrier.wait()
        return subprocess.run([script] + (["--urgent"] if urgent else []) + [body],
                              env=env, capture_output=True, text=True, timeout=15)
    with concurrent.futures.ThreadPoolExecutor(max_workers=len(bodies)) as pool:
        return list(pool.map(send, bodies))

def records():
    return [json.loads(p.read_text()) for p in notices.glob("nt-*.json")]

results = burst(["The report is ready"] * 16)
assert all(r.returncode == 0 for r in results), results
assert sum("notice=duplicate:" in r.stdout for r in results) == 15, results
assert len(records()) == 1, records()

results = burst([f"Result {i}" for i in range(16)])
assert sorted(r.returncode for r in results) == [0] * 5 + [3] * 11, results
assert len(records()) == 6, records()

results = burst([f"Blocker {i}" for i in range(16)], urgent=True)
assert sorted(r.returncode for r in results) == [0] * 6 + [3] * 10, results
assert len(records()) == 12, records()
assert sum(r["urgent"] for r in records()) == 6, records()
PY
pass "overlapping sends preserve duplicate, plain and urgent limits"

echo "ALL TESTS PASSED"
