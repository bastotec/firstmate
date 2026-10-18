#!/usr/bin/env bash
# tests/fm-lifecycle.test.sh - the lifecycle timeline builder (bin/fm_lifecycle.py)
# over a synthetic no-mistakes database, a synthetic firstmate home, a stub gh
# and an auto-land log. The load-bearing guarantees: a mate task is told apart
# from a session branch by the home's task ids, its start is its spawn, retries
# group under one task, and its time is split into implementation, pipeline
# steps, parked gates, rework between runs, the wait to merge and the deploy.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not found"; exit 0; }

LIFE="$ROOT/bin/fm_lifecycle.py"
TMP_ROOT=$(fm_test_tmproot fm-lifecycle)
NOW=1792000000

iso() { python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'))" "$1"; }

# new_case <name>: a home with one mate task, a database with its two runs, a
# session branch's two retries, an old run and a stub gh.
new_case() {
  local d="$TMP_ROOT/$1" t0=$((NOW - 20000))
  mkdir -p "$d/home/data" "$d/home/state" "$d/bin"
  printf '# Backlog\n\n## In flight\n- [ ] ship-a - Fix the thing (repo: firstmate) (kind: ship)\n' > "$d/home/data/backlog.md"
  printf 'kind=ship\nspawn_gen=s%s.1.2\n' "$t0" > "$d/home/state/ship-a.meta"
  printf 'working: on it\nblocked: waiting for a credential\n' > "$d/home/state/ship-a.status"
  : > "$d/home/state/ship-a.control-relaunch"
  # ship-a: spawned at t0, first run at t0+600 fails at t0+1600, the second runs
  # t0+2000..t0+5000 (CI ready at t0+4800), merged at t0+6000, deployed at t0+6300.
  sqlite3 "$d/nm.sqlite" "CREATE TABLE repos(id TEXT, working_path TEXT);
    INSERT INTO repos VALUES('fm','/fleet/firstmate');
    CREATE TABLE runs(id TEXT, repo_id TEXT, branch TEXT, status TEXT, created_at INTEGER, updated_at INTEGER,
      parked_ms INTEGER, ci_ready_at INTEGER, pr_url TEXT, error TEXT);
    INSERT INTO runs VALUES('a1','fm','fm/ship-a','failed',$((t0 + 600)),$((t0 + 1600)),300000,NULL,NULL,'upstream_error: gateway timeout');
    INSERT INTO runs VALUES('a2','fm','fm/ship-a','completed',$((t0 + 2000)),$((t0 + 5000)),120000,$((t0 + 4800)),'https://github.com/o/firstmate/pull/7',NULL);
    INSERT INTO runs VALUES('s1','fm','fm/quick-fix','failed',$((t0 + 100)),$((t0 + 400)),0,NULL,NULL,NULL);
    INSERT INTO runs VALUES('s2','fm','fm/quick-fix-2','completed',$((t0 + 500)),$((t0 + 900)),0,NULL,'https://github.com/o/firstmate/pull/8',NULL);
    INSERT INTO runs VALUES('old','fm','fm/ship-a','failed',$((NOW - 9 * 86400)),$((NOW - 9 * 86400)),0,NULL,NULL,NULL);
    CREATE TABLE step_results(id TEXT, run_id TEXT, step_name TEXT, duration_ms INTEGER, error TEXT);
    INSERT INTO step_results VALUES('x1','a1','review',700000,NULL);
    INSERT INTO step_results VALUES('x2','a2','review',900000,NULL);
    INSERT INTO step_results VALUES('x3','a2','test',400000,NULL);
    INSERT INTO step_results VALUES('x4','a2','ci',1200000,NULL);
    CREATE TABLE step_rounds(id TEXT, step_result_id TEXT, trigger_type TEXT);
    INSERT INTO step_rounds VALUES('q1','x1','initial');
    INSERT INTO step_rounds VALUES('q2','x1','auto_fix');
    INSERT INTO step_rounds VALUES('q3','x2','auto_fix');"
  cat > "$d/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  */pull/7*) printf '{"createdAt":"$(iso $((t0 + 4000)))","mergedAt":"$(iso $((t0 + 6000)))","state":"MERGED","mergeCommit":{"oid":"abcdef0000000000000000000000000000000000"},"commits":[{"authoredDate":"$(iso $((t0 + 300)))"}]}\n' ;;
  */pull/8*) printf '{"createdAt":"$(iso $((t0 + 850)))","mergedAt":"$(iso $((t0 + 1500)))","state":"MERGED","commits":[{"authoredDate":"$(iso $((t0 + 50)))"}]}\n' ;;
  api*...1111111) printf '{"status":"behind"}\n' ;;
  api*...2222222) printf '{"status":"ahead"}\n' ;;
  api*...3333333) printf '{"status":"diverged"}\n' ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$d/bin/gh"
  # one tick logs every event on one line, joined with "; "
  printf '%s autoland: merged https://github.com/o/other/pull/1 (deploy follows); merged https://github.com/o/firstmate/pull/7 (deploy follows)\n' \
    "$(iso $((t0 + 6000)))" > "$d/autoland.log"
  printf '%s autoland: deployed firstmate abcdef0: homes at abcdef0\n' "$(iso $((t0 + 6300)))" >> "$d/autoland.log"
  printf '%s' "$d"
}

timeline() {  # <case-dir>
  python3 "$LIFE" timeline --db "$1/nm.sqlite" --home "$1/home" --since $((NOW - 86400)) --now "$NOW" \
    --gh "$1/bin/gh" --autoland-log "$1/autoland.log"
}

test_a_mate_task_s_time_is_split_by_stage() {
  local d
  d=$(new_case split)
  timeline "$d" > "$d/out.json" || fail "the timeline did not build"
  python3 - "$d/out.json" <<'PY' || fail "mate task timeline wrong: $(cat "$d/out.json")"
import json, sys
doc = json.load(open(sys.argv[1]))
t = {x["task"]: x for x in doc["timelines"]}
a = t["ship-a"]
assert a["kind"] == "mate" and a["start_from"] == "spawn" and a["seconds"] == 6000, a
assert a["runs"] == 2 and a["failed_runs"] == 1 and a["fix_rounds"] == 2, a
assert a["gateway_errors"] == 1 and a["relaunches"] == 1 and a["waits"] == ["blocked"], a
assert a["pr"].endswith("/pull/7") and a["deployed"] and not a["open"], a
s = a["sinks"]
assert s == {"implementation": 600, "review": 1600, "ci": 1200, "parked at a gate": 420, "rework": 400,
             "test": 400, "waiting to merge": 1200, "deploy": 300}, s
PY
  pass "lifecycle: a mate task starts at its spawn and its time splits into implementation, steps, gates, rework, merge wait and deploy"
}

test_session_branches_are_the_benchmark_and_retries_group() {
  local d
  d=$(new_case bench)
  timeline "$d" > "$d/out.json" || fail "the timeline did not build"
  python3 - "$d/out.json" <<'PY' || fail "benchmark wrong: $(cat "$d/out.json")"
import json, sys
doc = json.load(open(sys.argv[1]))
t = {x["task"]: x for x in doc["timelines"]}
assert set(t) == {"ship-a", "quick-fix"}, sorted(t)  # the old run is outside the window
q = t["quick-fix"]
assert q["kind"] == "session" and q["runs"] == 2 and q["branches"] == ["fm/quick-fix", "fm/quick-fix-2"], q
assert q["start_from"] == "first commit" and q["seconds"] == 1450, q
m = doc["metrics"]
assert m["tasks"] == 1 and m["sessions"] == 1, m
assert m["mate"]["median"] == 6000 and m["mate"]["run_to_merge_median"] == 5400, m["mate"]
assert m["session"]["median"] == 1450 and m["session"]["merged"] == 1, m["session"]
assert m["slowest"][0]["task"] == "ship-a" and m["counted"]["held_or_blocked"] == 1, m
assert "when the captain asked is not recorded per task" in doc["digest"], doc["digest"]
assert "ship-a" in doc["digest"] and "quick-fix" not in doc["digest"], doc["digest"]
PY
  pass "lifecycle: branches that are no mate task are the benchmark, retries group under one name, old runs are out"
}

test_an_open_task_is_measured_to_now_and_a_missing_database_reads_as_empty() {
  local d
  d=$(new_case open)
  sqlite3 "$d/nm.sqlite" "UPDATE runs SET pr_url = NULL WHERE id = 'a2'"
  timeline "$d" > "$d/out.json" || fail "the timeline did not build"
  python3 - "$d/out.json" <<'PY' || fail "open task wrong: $(cat "$d/out.json")"
import json, sys
doc = json.load(open(sys.argv[1]))
a = {x["task"]: x for x in doc["timelines"]}["ship-a"]
# CI was ready at t0+4800 and the PR is not merged: it is still waiting, through now
assert a["open"] and a["seconds"] == 20000 and a["sinks"]["waiting to merge"] == 15200, a
assert doc["metrics"]["mate"]["merged"] == 0 and doc["metrics"]["mate"]["open"] == 1, doc["metrics"]
PY
  python3 "$LIFE" timeline --db "$d/none.sqlite" --home "$d/home" --since $((NOW - 86400)) --now "$NOW" > "$d/empty.json" \
    || fail "a missing database failed the read"
  [ "$(jq -c '[.timelines[] | [.task, .runs]]' "$d/empty.json")" = '[["ship-a",0]]' ] \
    || fail "a missing database produced run timelines: $(jq -c .timelines "$d/empty.json")"
  pass "lifecycle: an open task is measured to now, and a machine without a database has only its spawned tasks"
}

test_unread_prs_spawned_tasks_repositories_and_percentiles() {
  local d t0=$((NOW - 20000))
  d=$(new_case edges)
  # gh cannot read pull/8; a second repository has its own fm/quick-fix; ship-b is spawned with no run
  sed -i.bak 's#\*/pull/8\*)#*/pull/never*)#' "$d/bin/gh" && rm -f "$d/bin/gh.bak"
  sqlite3 "$d/nm.sqlite" "INSERT INTO repos VALUES('other','/fleet/other');
    INSERT INTO runs VALUES('o1','other','fm/quick-fix','completed',$((t0 + 100)),$((t0 + 200)),0,NULL,NULL,NULL);"
  printf -- '- [ ] ship-b - Next (repo: firstmate) (kind: ship)\n- [ ] mate-c - A mate (kind: secondmate)\n' >> "$d/home/data/backlog.md"
  printf 'kind=ship\nspawn_gen=s%s.1.2\n' $((NOW - 3000)) > "$d/home/state/ship-b.meta"
  printf 'kind=secondmate\nspawn_gen=s%s.1.2\n' $((NOW - 3000)) > "$d/home/state/mate-c.meta"
  timeline "$d" > "$d/out.json" || fail "the timeline did not build"
  python3 - "$d/out.json" "$ROOT/bin" <<'PY' || fail "edge cases wrong: $(cat "$d/out.json")"
import json, sys
doc = json.load(open(sys.argv[1]))
rows = doc["timelines"]
quick = [t for t in rows if t["task"] == "quick-fix"]
assert len(quick) == 2 and sorted(t["runs"] for t in quick) == [1, 2], quick  # one per repository
unread = [t for t in quick if t["runs"] == 2][0]
assert unread["pr_unread"] and unread["open"] is None and unread["merged"] is None, unread
b = [t for t in rows if t["task"] == "ship-b"]
assert len(b) == 1 and b[0]["runs"] == 0 and b[0]["sinks"] == {"implementation": 3000} and b[0]["open"], b
assert not [t for t in rows if t["task"] == "mate-c"], "a second mate's record became a task"
m = doc["metrics"]
assert m["tasks"] == 2 and m["session"]["unknown"] == 1 and m["session"]["merged"] == 0, m
sys.path.insert(0, sys.argv[2])
import fm_lifecycle as fl
assert fl.pct([100, 200, 300, 400, 500, 600, 700, 800, 900, 1000], 90) == 900
assert fl.pct([5], 90) == 5 and fl.pct([], 90) is None
PY
  pass "lifecycle: unread PRs stay unknown, spawned tasks without runs count, repositories never merge, p90 is nearest rank"
}

test_deployments_must_contain_the_pr_merge() {
  local d t0=$((NOW - 20000))
  d=$(new_case deploy-sha)
  printf '%s autoland: merged https://github.com/o/firstmate/pull/7 (deploy follows)\n' "$(iso $((t0 + 6000)))" > "$d/autoland.log"
  printf '%s autoland: deployed firstmate 1111111: predecessor deployed; deploy of firstmate abcdef0 FAILED\n' \
    "$(iso $((t0 + 6300)))" >> "$d/autoland.log"
  printf '%s autoland: deployed firstmate 3333333: unrelated; deployed firstmate 4444444: unread commit\n' \
    "$(iso $((t0 + 6400)))" >> "$d/autoland.log"
  timeline "$d" > "$d/out.json" || fail "the timeline did not build"
  jq -e '.timelines[] | select(.task == "ship-a") | .deployed == null and (.sinks | has("deploy") | not)' "$d/out.json" >/dev/null \
    || fail "a predecessor or unverified commit counted as deployment"
  printf '%s autoland: deployed firstmate 2222222: descendant deployed\n' "$(iso $((t0 + 6600)))" >> "$d/autoland.log"
  timeline "$d" > "$d/out2.json" || fail "the timeline did not build"
  jq -e --argjson at "$((t0 + 6600))" '.timelines[] | select(.task == "ship-a") | .deployed == $at and .sinks.deploy == 600' "$d/out2.json" >/dev/null \
    || fail "a verified descendant did not count as deployment"
  pass "lifecycle: deployments require the merge commit or a verified descendant, never a predecessor or unread commit"
}

test_task_metadata_stays_with_its_home_and_repository() {
  local d t0=$((NOW - 20000))
  d=$(new_case task-homes)
  mkdir -p "$d/other/data" "$d/other/state" "$d/third/state"
  printf 'project=/fleet/firstmate\n' >> "$d/home/state/ship-a.meta"
  printf -- '- [ ] ship-a - Another task (repo: other) (kind: ship)\n' > "$d/other/data/backlog.md"
  printf 'kind=ship\nproject=/fleet/other\nspawn_gen=s%s.1.2\n' $((t0 + 1800)) > "$d/other/state/ship-a.meta"
  printf 'paused: awaiting service\n' > "$d/other/state/ship-a.status"
  printf 'kind=scout\nproject=/fleet/third\nspawn_gen=s%s.1.2\n' $((t0 + 1900)) > "$d/third/state/ship-a.meta"
  sqlite3 "$d/nm.sqlite" "INSERT INTO repos VALUES('other','/fleet/other');
    INSERT INTO runs VALUES('other-a','other','fm/ship-a','running',$((t0 + 2000)),$((t0 + 2200)),0,NULL,NULL,NULL);"
  python3 "$LIFE" timeline --db "$d/nm.sqlite" --home "$d/home" --home "$d/other" --home "$d/third" \
    --since $((NOW - 86400)) --now "$NOW" --gh "$d/bin/gh" > "$d/out.json" || fail "the timeline did not build"
  python3 - "$d/out.json" "$d" "$t0" <<'PY' || fail "metadata crossed homes: $(cat "$d/out.json")"
import json, sys
rows = [t for t in json.load(open(sys.argv[1]))['timelines'] if t['task'] == 'ship-a']
root, t0 = sys.argv[2], int(sys.argv[3])
assert len(rows) == 3, rows
by_home = {t['home']: t for t in rows}
a, b, c = (by_home[root + '/' + h] for h in ('home', 'other', 'third'))
assert a['start'] == t0 and a['sinks']['implementation'] == 600 and a['runs'] == 2, a
assert a['waits'] == ['blocked'] and a['relaunches'] == 1, a
assert b['start'] == t0 + 1800 and b['sinks']['implementation'] == 200 and b['runs'] == 1, b
assert b['waits'] == ['paused'] and b['relaunches'] == 0, b
assert c['start'] == t0 + 1900 and c['runs'] == 0 and c['waits'] == [], c
PY
  pass "lifecycle: repeated task ids retain each home's spawn, waits, relaunches and unstarted work"
}

test_deployments_must_contain_the_pr_merge
test_task_metadata_stays_with_its_home_and_repository
test_a_mate_task_s_time_is_split_by_stage
test_session_branches_are_the_benchmark_and_retries_group
test_an_open_task_is_measured_to_now_and_a_missing_database_reads_as_empty
test_unread_prs_spawned_tasks_repositories_and_percentiles
