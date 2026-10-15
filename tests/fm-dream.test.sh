#!/usr/bin/env bash
# tests/fm-dream.test.sh - fleet dreaming (bin/fm-dream.sh, bin/fm_dream.py) and
# its report section (bin/fm_report.py). Every case runs over a synthetic home,
# a synthetic deck session, a local bare "dotfiles" remote and stub deck, Jev,
# backlog, handoff, report and gh commands; nothing reaches the network and no
# model is called. The load-bearing guarantees: the digest carries captain
# messages, tool errors, slow fm-* commands and failed no-mistakes runs and is
# private; excluded homes never reach it; the skills step pushes only skills/
# changes within the caps; triage drops duplicates of open work, keeps at most
# three and files each with its owning mate; a dry run files nothing; and the
# fleet report shows the last run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v sqlite3 >/dev/null 2>&1 || { echo "skip: sqlite3 not found"; exit 0; }

DREAM="$ROOT/bin/fm_dream.py"
TMP_ROOT=$(fm_test_tmproot fm-dream)
NOW=1792000000
export FM_DREAM_NOW=$NOW FM_DREAM_SKIP_ZIGGY_WAIT=1 FM_DREAM_MIN_FREE_GB=0 FM_DREAM_RETRY_SECS=0

iso() { python3 -c "import datetime,sys; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%S.000Z'))" "$1"; }

# new_case <name>: a home with a primary session, a private mate session, a
# captain-direct line, a failed no-mistakes run, stub tools and a dotfiles remote.
new_case() {
  local d="$TMP_ROOT/$1" recent old
  mkdir -p "$d/home/state/primary-chat" "$d/home/config" "$d/home/data" "$d/deck/sessions" "$d/bin" "$d/calls"
  recent=$(iso $((NOW - 3600))); old=$(iso $((NOW - 3 * 86400)))
  printf 'p-1\n' > "$d/home/state/primary-chat/session"
  printf 's-private\n' > "$d/home/state/finn-finance.deck-session"
  printf 'sup-1\n' > "$d/home/state/docana-delivery.supervisor-session"
  printf 'broken\n' > "$d/home/state/broken-mate.deck-session"
  mkdir -p "$d/home/state/procevent-inbox"
  printf 'status: action-failed\nrestarted: cadia on workload (deck)\nunreached: finn-finance: SECRET RESTART DETAIL\n' \
    > "$d/home/state/procevent-inbox/when-secondmate-restart-1.1.result"
  python3 - "$d/deck/sessions" "$recent" "$old" "$d/home" <<'PY'
import json, sys
root, recent, old, home = sys.argv[1:5]
call = lambda cid, cmd: {"type": "toolcall", "id": cid, "function": {"name": "run_command", "arguments": {"command": cmd}}}
res = lambda cid, val: {"type": "toolresult", "call": cid, "name": "run_command", "content": [{"type": "json", "value": val}]}
msgs = [
  {"role": "user", "content": [{"type": "text", "text": "an old line from days ago"}], "at": old},
  {"role": "user", "content": [{"type": "text", "text": "no, use fm-pr-merge.sh, not gh pr merge"}], "at": recent},
  {"role": "user", "content": [{"type": "text", "text": "PRIVATE PREFIX " + "x" * 600 + " finn-finance"}], "at": recent},
  {"role": "assistant", "content": [call("c1", "bin/fm-wake-drain.sh"), call("c2", "bin/fm-spawn.sh x"), call("c3", "bin/fm-send.sh finn-finance 'PRIVATE SEND'")], "at": recent},
  {"role": "user", "content": [res("c1", {"exit_code": 0, "stdout": "ok"}), res("c2", {"exit_code": 1, "stderr": "spawn refused: hub unreachable"}),
                               res("c3", {"exit_code": 1, "stderr": "send failed"})],
   "at": recent, "tools": [{"id": "c1", "duration_ms": 47000}, {"id": "c2", "duration_ms": 900}, {"id": "c3", "duration_ms": 30000}]},
  {"role": "assistant", "content": [{"type": "text", "text": "Captain, done."}], "at": recent}]
json.dump({"version": 1, "messages": msgs}, open(root + "/p-1.json", "w"))
json.dump({"version": 1, "messages": [{"role": "user", "content": [{"type": "text", "text": "PRIVATE BANK LINE"}], "at": recent}]},
          open(root + "/s-private.json", "w"))
brief = lambda extra, h=home: {"role": "user", "content": [{"type": "text", "text": "FIRSTMATE_OP: v1 launch-brief\ntask: %s\nYour steering inbox is `%s/state/%s.inbox`; this exact path." % (extra, h, extra)}], "at": recent}
json.dump({"version": 1, "messages": [brief("other-ship", "/elsewhere/firstmate"), {"role": "assistant", "content": [{"type": "text", "text": "ANOTHER HOME WORKER"}], "at": recent}]},
          open(root + "/w-3.json", "w"))
quoting = brief("quoting-ship", "/elsewhere/firstmate")
quoting["content"][0]["text"] += "\nsee %s/state/idle-sweep.log" % home
json.dump({"version": 1, "messages": [quoting, {"role": "assistant", "content": [{"type": "text", "text": "QUOTING WORKER"}], "at": recent}]},
          open(root + "/w-4.json", "w"))
open(root + "/broken.json", "w").write('{"version": 1, "messages": [')
json.dump({"version": 1, "messages": [brief("ship-x"), {"role": "assistant", "content": [{"type": "text", "text": "WORKER DID THE THING"}], "at": recent}]},
          open(root + "/w-1.json", "w"))
json.dump({"version": 1, "messages": [brief("finn-finance-close"), {"role": "assistant", "content": [{"type": "text", "text": "PRIVATE WORKER LINE"}], "at": recent}]},
          open(root + "/w-2.json", "w"))
json.dump({"version": 1, "messages": [{"role": "user", "content": [{"type": "text", "text": "SPLIT SUPERVISOR LINE"}], "at": recent}]},
          open(root + "/sup-1.json", "w"))
json.dump({"version": 1, "messages": [{"role": "user", "content": [{"type": "text", "text": "UNRELATED DECK USE"}], "at": recent}]},
          open(root + "/other.json", "w"))
PY
  printf '{"exclude_homes": ["finn-finance"], "owners": {"deck": "dave-tools"}, "model": "stub/model"}\n' > "$d/home/config/dream.json"
  printf '%s\tcorr-1\tcaptain: please stop opening duplicate workers\n' $((NOW - 600)) > "$d/home/state/captain-direct.log"
  printf '%s delivered corr=abc123 task=cadia\n' "$(iso $((NOW - 500)))" >> "$d/home/state/captain-direct.log"
  mkdir -p "$d/home/state/captain-direct"; printf 'no, merge only on green\n' > "$d/home/state/captain-direct/abc123.text"
  sqlite3 "$d/nm.sqlite" "CREATE TABLE repos(id TEXT, working_path TEXT, upstream_url TEXT, fork_url TEXT);
    INSERT INTO repos VALUES('fleet','$d/home','https://github.com/x/fm',NULL);
    INSERT INTO repos VALUES('elsewhere','/somewhere/private-project','https://github.com/x/private',NULL);
    INSERT INTO repos VALUES('client','/clients/deck','https://github.com/client/deck',NULL);
    INSERT INTO repos VALUES('harness','/anywhere/deck','https://github.com/kunchen/deck','https://github.com/bastotec/deck.git');
    CREATE TABLE runs(id TEXT, repo_id TEXT, status TEXT, branch TEXT, error TEXT, pr_url TEXT, created_at INTEGER, updated_at INTEGER);
    INSERT INTO runs VALUES('r1','fleet','failed','fm/x','lint step timed out','',$((NOW - 9 * 86400)),$((NOW - 7200)));
    INSERT INTO runs VALUES('r0','fleet','failed','fm/old','ancient','',$((NOW - 9 * 86400)),$((NOW - 9 * 86400)));
    INSERT INTO runs VALUES('r2','elsewhere','failed','fm/p','PRIVATE PROJECT FAILURE','',$((NOW - 3600)),$((NOW - 3600)));
    INSERT INTO runs VALUES('r3','client','failed','x','CLIENT DECK FAILURE','',$((NOW - 3600)),$((NOW - 3600)));
    INSERT INTO runs VALUES('r4','harness','failed','y','HARNESS DECK FAILURE','',$((NOW - 3600)),$((NOW - 3600)));"
  # dotfiles: a bare origin with one skill, and a local clone
  git init -q --bare "$d/origin.git"
  git clone -q "$d/origin.git" "$d/dotfiles" 2>/dev/null
  fm_git_identity "$d/dotfiles" 2>/dev/null || { git -C "$d/dotfiles" config user.email t@t; git -C "$d/dotfiles" config user.name t; }
  mkdir -p "$d/dotfiles/skills/merge"
  printf -- '---\nname: merge\ndescription: merging\n---\nUse gh.\n' > "$d/dotfiles/skills/merge/SKILL.md"
  git -C "$d/dotfiles" add -A && git -C "$d/dotfiles" commit -qm init && git -C "$d/dotfiles" push -q origin HEAD:main 2>/dev/null
  git -C "$d/dotfiles" branch -q -u origin/main 2>/dev/null || true
  # stubs
  cat > "$d/bin/deck" <<'SH'
#!/usr/bin/env bash
prompt=$(cat)
if [ -n "${STUB_DECK_SLEEP:-}" ]; then sleep "$STUB_DECK_SLEEP"; fi
if [ -n "${STUB_DECK_FAIL:-}" ]; then
  printf '{"type":"run_failed","error":"model gateway request failed (HTTP 502)"}\n'; exit 1
fi
if [ -n "${STUB_DECK_FAIL_ONCE:-}" ] && [ ! -e "$STUB_CALLS/failed-once.$(printf '%s' "$prompt" | head -c 30 | cksum | cut -d' ' -f1)" ]; then
  : > "$STUB_CALLS/failed-once.$(printf '%s' "$prompt" | head -c 30 | cksum | cut -d' ' -f1)"
  printf '{"type":"run_failed","error":"model gateway request failed (HTTP 502)"}\n'; exit 1
fi
printf '%s\n' "$prompt" > "$STUB_CALLS/deck.$$"
summary=$(printf '%s' "$prompt" | grep -o '/[^ ]*skills-[0-9-]*\.json' | head -1)
triage=$(printf '%s' "$prompt" | grep -o '/[^ ]*triage-[0-9-]*\.json' | head -1)
if [ -n "$summary" ]; then
  [ "${STUB_SKILLS:-edit}" = nosummary ] || printf '{"changes":[{"skill":"merge","what":"edit","why":"why"}]}' > "$summary"
  case "${STUB_SKILLS:-edit}" in
    edit) printf -- '---\nname: merge\ndescription: merging\n---\nUse bin/fm-pr-merge.sh, never gh pr merge.\n' > skills/merge/SKILL.md
          printf '{"changes":[{"skill":"merge","what":"says to merge through fm-pr-merge.sh","why":"captain corrected it"}]}' > "$summary" ;;
    outside) printf 'x\n' > README.md ;;
    secret) printf 'token ghp_abcdefghijklmnopqrstuvwxyz0123\n' >> skills/merge/SKILL.md ;;
    checkpoint) printf 'token ghp_abcdefghijklmnopqrstuvwxyz0123\n' > skills/merge/NOTES.md
                git add -A && git -c user.email=a@b -c user.name=a commit -qm checkpoint
                git rm -q skills/merge/NOTES.md 2>/dev/null; git -c user.email=a@b -c user.name=a commit -qm undo 2>/dev/null
                printf 'token ghp_abcdefghijklmnopqrstuvwxyz0123\n' > skills/merge/NOTES.md
                git add -A && git -c user.email=a@b -c user.name=a commit -qm again
                printf 'clean edit\n' >> skills/merge/SKILL.md ;;
    binary) printf 'GIF89a\0\0token ghp_abcdefghijklmnopqrstuvwxyz0123\0' > skills/merge/shot.gif ;;
    nosummary) printf 'clean edit\n' >> skills/merge/SKILL.md ;;
    message) printf 'clean edit\n' >> skills/merge/SKILL.md
             printf '{"changes":[{"skill":"merge","what":"x","why":"it failed with ghp_abcdefghijklmnopqrstuvwxyz0123"}]}' > "$summary" ;;
    none) ;;
  esac
fi
if [ -n "$triage" ] && [ -z "${STUB_NO_TRIAGE:-}" ]; then
  cat > "$triage" <<'JSON'
{"items": [
 {"repo": "firstmate", "title": "Cache the drain result in fm-wake-drain.sh", "kind": "slow", "evidence": ["slow command (47s): bin/fm-wake-drain.sh"], "why": "47 s per wake", "fix": "cache"},
 {"repo": "deck", "title": "Retry spawn when the hub is briefly unreachable", "kind": "bug", "evidence": ["tool error: spawn refused"], "why": "lost spawn", "fix": "retry"},
 {"repo": "firstmate", "title": "Stop duplicate worker spawns for one task", "kind": "guard", "evidence": ["captain: stop duplicates"], "why": "dupes", "fix": "lock"},
 {"repo": "cli-proxy-native", "title": "Lower the default retry budget for upstream errors", "kind": "default", "evidence": ["x"], "why": "y", "fix": "z"},
 {"repo": "firstmate", "title": "Make the idle sweep log its decisions", "kind": "guard", "evidence": ["x"], "why": "y", "fix": "z"},
 {"repo": "nowhere", "title": "Not a harness repo", "kind": "bug", "evidence": ["x"], "why": "y", "fix": "z"},
 {"repo": "firstmate", "title": "Cache the drain result in fm-wake-drain.sh", "kind": "slow", "evidence": ["again"], "why": "same", "fix": "same"}
]}
JSON
fi
SH
  cat > "$d/bin/tasks" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list) case "$*" in *--fields*) echo "unexpected --fields" >&2; exit 2 ;; esac
        printf 'count: 3\ntasks[3]{id,state,kind,repo,title}:\n  fm-old,done,ship,firstmate,"Cache the drain result in fm-wake-drain.sh"\n  fm-dupes,queued,ship,"-","Prevent duplicate worker spawns, for a task"\n  fm-q,queued,ship,deck,"Handle \\"a,b\\" retry arguments in deck"\n' ;;
  add) n=$(find "$STUB_CALLS" -name 'add.*' | wc -l | tr -d ' '); printf '%s\n' "$*" > "$STUB_CALLS/add.$n"; printf '{\n  "ok": true,\n  "action": "add",\n  "task": {"id": "dream-k%s"}\n}\n' "$n" ;;
esac
SH
  cat > "$d/bin/handoff" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_CALLS/handoff.$2"
SH
  cat > "$d/bin/jev" <<'SH'
#!/usr/bin/env bash
in=$(cat)
case "$in" in *"idle sweep"*) printf 'usage\t1\t1\t0\t1\nanswers\t0.9\t0.2\t0.4\n' ;; *) printf 'usage\t1\t1\t0\t1\nanswers\t0.9\t0.9\t0.8\n' ;; esac
SH
  cat > "$d/bin/report" <<'SH'
#!/usr/bin/env bash
printf '{"summary": "fleet ok", "waiting": [], "gaps": [], "power": [], "shipped": [],
 "crew": [{"agent": "w-9", "task": "deploy", "status": "failed", "mate": "dave-tools"},
          {"agent": "w-8", "task": "finn-finance-crew", "status": "failed", "mate": "finn-finance"}]}\n'
SH
  printf '#!/usr/bin/env bash\nprintf "[]\\n"\n' > "$d/bin/gh"
  chmod +x "$d/bin/"*
  printf '%s' "$d"
}

run_dream() {  # <case-dir> <args...>
  local d=$1; shift
  PATH="$d/bin:$PATH" DECK_STATE="$d/deck" FM_DREAM_DECK="$d/bin/deck" FM_DREAM_DOTFILES="$d/dotfiles" \
    FM_DREAM_JEV="$d/bin/jev" FM_DREAM_TASKS="$d/bin/tasks" FM_DREAM_HANDOFF="$d/bin/handoff" \
    FM_DREAM_REPORT="$d/bin/report" FM_DREAM_NO_MISTAKES_DB="$d/nm.sqlite" STUB_CALLS="$d/calls" \
    python3 "$DREAM" run --home "$d/home" "$@"
}

test_collect_builds_a_private_digest_of_the_day() {
  local d digest
  d=$(new_case collect)
  run_dream "$d" --only collect > "$d/out.json" || fail "collect exited nonzero"
  digest=$(ls "$d"/home/state/dream/digest-*.md) || fail "no digest written"
  [ "$(stat -f %Lp "$digest" 2>/dev/null || stat -c %a "$digest")" = 600 ] || fail "digest is not 0600"
  grep -q 'no, use fm-pr-merge.sh' "$digest" || fail "captain correction missing"
  grep -q 'slow command (47s): bin/fm-wake-drain.sh' "$digest" || fail "slow fm-* command missing"
  grep -q 'tool error (bin/fm-spawn.sh x): spawn refused' "$digest" || fail "tool error missing"
  grep -q 'please stop opening duplicate workers' "$digest" || fail "captain-direct line missing"
  grep -q 'lint step timed out' "$digest" || fail "a run created long ago but failed today is missing"
  grep -q 'PRIVATE PROJECT FAILURE' "$digest" && fail "a run outside the fleet's repositories reached the digest"
  grep -q 'CLIENT DECK FAILURE' "$digest" && fail "a same-named client repository's run reached the digest"
  grep -q 'HARNESS DECK FAILURE' "$digest" || fail "a harness repository's run (by its GitHub remote) is missing"
  grep -q 'no, merge only on green' "$digest" || fail "a captain-direct message body is missing"
  grep -q 'ancient\|an old line' "$digest" && fail "lines older than a day leaked in"
  grep -q 'PRIVATE BANK LINE' "$digest" && fail "an excluded home reached the digest"
  grep -q 'PRIVATE WORKER LINE' "$digest" && fail "an excluded home's worker reached the digest"
  grep -q 'WORKER DID THE THING' "$digest" || fail "an unbound worker session was not found by its launch brief"
  grep -q 'SPLIT SUPERVISOR LINE' "$digest" || fail "a split mate's supervisor session was missed"
  grep -q 'UNRELATED DECK USE' "$digest" && fail "a session that is not fleet work reached the digest"
  grep -q 'ANOTHER HOME WORKER' "$digest" && fail "a worker of another firstmate home reached the digest"
  grep -q 'QUOTING WORKER' "$digest" && fail "a foreign worker quoting this home's paths reached the digest"
  jq -e '.steps.collect.status == "partial" and (.steps.collect.why | test("unreadable"))' "$d/out.json" >/dev/null \
    || fail "an unreadable session did not make collect partial"
  grep -q 'restarted: cadia on workload' "$digest" || fail "restart results missing"
  grep -q 'SECRET RESTART DETAIL' "$digest" && fail "an excluded home's restart line reached the digest"
  grep -q 'PRIVATE SEND' "$digest" && fail "a command addressed to an excluded home reached the digest"
  grep -q 'PRIVATE PREFIX' "$digest" && fail "a message naming an excluded home past the cut reached the digest"
  grep -q 'crew failed: w-9 on deploy (dave-tools)' "$digest" || fail "a remote mate's failed crew row is missing"
  grep -q 'finn-finance-crew' "$digest" && fail "an excluded mate's crew row reached the digest"
  pass "collect builds a private digest of the day and leaves excluded homes out"
}

test_skills_pushes_a_guarded_change_to_main() {
  local d
  d=$(new_case skills)
  run_dream "$d" --only collect skills >/dev/null || fail "run exited nonzero"
  git -C "$d/origin.git" log -1 --format=%s main | grep -q 'fleet dreaming' || fail "no dreaming commit on main"
  git -C "$d/origin.git" show main:skills/merge/SKILL.md | grep -q 'fm-pr-merge.sh' || fail "skill edit not pushed"
  [ -z "$(git -C "$d/dotfiles" worktree list | sed -n 2p)" ] || fail "the dreaming worktree was left behind"
  pass "the skills step commits and pushes a skills-only change to main"
}

test_skills_rejects_changes_outside_skills_and_secrets() {
  local d mode before
  for mode in outside secret checkpoint message binary; do
    d=$(new_case "skills-$mode")
    before=$(git -C "$d/origin.git" rev-parse main)
    STUB_SKILLS=$mode run_dream "$d" --only collect skills > "$d/out.json" || fail "$mode: run exited nonzero"
    grep -q '"rejected"' "$d/out.json" || fail "$mode: change not rejected"
    case $mode in secret|checkpoint|binary|message) grep -q 'secret-like' "$d/out.json" || fail "$mode: rejected for the wrong reason: $(cat "$d/out.json")" ;; esac
    [ "$(git -C "$d/origin.git" rev-parse main)" = "$before" ] || fail "$mode: main moved"
  done
  d=$(new_case skills-nosummary)
  before=$(git -C "$d/origin.git" rev-parse main)
  STUB_SKILLS=nosummary run_dream "$d" > "$d/out.json" || fail "nosummary: run exited nonzero"
  jq -e '.steps.skills.status == "failed"' "$d/out.json" >/dev/null || fail "edits without a summary were not a failure"
  [ "$(git -C "$d/origin.git" rev-parse main)" = "$before" ] || fail "nosummary: main moved"
  pass "the skills step rejects changes outside skills/, secret-like text, also in agent commits and summaries"
}

test_a_malformed_config_stops_the_run() {
  local d
  d=$(new_case badconfig)
  printf '{"exclude_homes": ["finn-finance"],}\n' > "$d/home/config/dream.json"
  if run_dream "$d" > "$d/out.json" 2> "$d/err"; then fail "a malformed dream.json did not stop the run"; fi
  grep -q 'dream.json is unreadable' "$d/err" || fail "the refusal does not name the file: $(cat "$d/err")"
  printf '{"exclude_homes": "finn-finance"}\n' > "$d/home/config/dream.json"
  if run_dream "$d" > "$d/out.json" 2> "$d/err"; then fail "a string exclude_homes did not stop the run"; fi
  grep -q 'exclude_homes must be a list' "$d/err" || fail "the refusal does not explain exclude_homes"
  printf '{"owners": {"deck": ["dave-tools"]}}\n' > "$d/home/config/dream.json"
  if run_dream "$d" > "$d/out.json" 2> "$d/err"; then fail "a list-valued owner did not stop the run"; fi
  printf '{"exclude_homes": ["finn-finance"]}\n' > "$d/home/config/dream.json"
  printf -- '- dave-tools\n' > "$d/home/data/secondmates.md"
  if run_dream "$d" > "$d/out.json" 2> "$d/err"; then fail "an unparsable registry entry did not stop a run with exclusions"; fi
  grep -q 'secondmates.md has an entry that cannot be parsed' "$d/err" || fail "the registry refusal is unclear: $(cat "$d/err")"
  [ -z "$(find "$d/home/state" -name 'digest-*' 2>/dev/null)" ] || fail "a digest was written without the exclusions"
  pass "a malformed or mistyped dream.json stops the run before anything is collected"
}

test_the_jev_helper_refuses_without_a_key() {
  local out rc
  command -v node >/dev/null 2>&1 || { pass "the Jev helper key check (skipped: no node)"; return; }
  out=$(printf '{"title": "x"}' | env -u FM_WAKE_GATE_KEY_VAR node "$ROOT/bin/wake-gate/jev-worth.mjs"); rc=$?
  [ "$out" = "$(printf 'error\tno-key')" ] && [ "$rc" = 3 ] || fail "expected error/no-key and exit 3, got '$out' ($rc)"
  out=$(printf 'not json' | node "$ROOT/bin/wake-gate/jev-worth.mjs"); rc=$?
  [ "$out" = "$(printf 'error\tbad-input')" ] && [ "$rc" = 2 ] || fail "expected error/bad-input and exit 2, got '$out' ($rc)"
  pass "the Jev helper refuses bad input and a missing key before any call"
}

test_a_failed_agent_is_reported_as_failed() {
  local d
  d=$(new_case agent-fail)
  STUB_DECK_FAIL=1 run_dream "$d" > "$d/out.json" || fail "run exited nonzero"
  jq -e '.steps.skills.status == "failed" and (.steps.skills.why | test("502"))' "$d/out.json" >/dev/null \
    || fail "a failed skills agent was not reported as failed: $(cat "$d/out.json")"
  jq -e '.steps.triage.status == "failed" and .steps.file.status == "nothing to file"' "$d/out.json" >/dev/null \
    || fail "a failed triage agent was not reported as failed"
  pass "an agent that fails (a gateway 502) is reported as failed, not as no changes"
}

test_a_gateway_blip_is_retried_once_and_succeeds() {
  local d
  d=$(new_case blip)
  STUB_DECK_FAIL_ONCE=1 run_dream "$d" > "$d/out.json" || fail "run exited nonzero"
  jq -e '.steps.skills.status == "merged" and .steps.triage.status == "done"' "$d/out.json" >/dev/null \
    || fail "a retry that succeeded was not reported as success: $(cat "$d/out.json")"
  pass "an agent that fails once and then succeeds is reported by its second attempt"
}

test_unreadable_open_work_files_nothing_blind() {
  local d
  d=$(new_case blind)
  printf '#!/usr/bin/env bash\necho "gh: not logged in" >&2; exit 1\n' > "$d/bin/gh"
  run_dream "$d" > "$d/out.json" || fail "run exited nonzero"
  [ -z "$(find "$d/calls" -name 'add.*')" ] || fail "items were filed although open PRs could not be read"
  jq -e '.steps.triage.why | test("unreadable")' "$d/out.json" >/dev/null || fail "the blind spot was not reported"
  pass "a repository whose open PRs cannot be read gets nothing filed, and the report says so"
}

test_triage_dedupes_scores_caps_and_files_with_owners() {
  local d n
  d=$(new_case triage)
  run_dream "$d" > "$d/out.json" || fail "run exited nonzero"
  n=$(find "$d/calls" -name 'add.*' | wc -l | tr -d ' ')
  [ "$n" = 3 ] || fail "expected 3 tasks filed, got $n"
  grep -l 'duplicate worker' "$d"/calls/add.* >/dev/null 2>&1 && fail "a duplicate of an open task was filed"
  grep -l 'idle sweep' "$d"/calls/add.* >/dev/null 2>&1 && fail "an item Jev scored low was filed"
  grep -l 'Not a harness repo' "$d"/calls/add.* >/dev/null 2>&1 && fail "an unknown repo was filed"
  grep -q 'dave-tools' "$d"/calls/handoff.* || fail "the deck item was not handed to its owner"
  [ "$(wc -l < "$d/home/state/dream/raised.jsonl")" -eq 3 ] || fail "raised ledger not written"
  jq -e '.raised | length == 3' "$d/home/state/dream/latest.json" >/dev/null || fail "latest.json lacks the raised items"
  pass "triage drops duplicates and low Jev scores, keeps three and files them with their owners"
}

test_a_corrupt_ledger_or_missing_agent_output_files_nothing() {
  local d
  d=$(new_case ledger)
  mkdir -p "$d/home/state/dream"; printf '{"title": "x", "at": 1}\n{broken\n' > "$d/home/state/dream/raised.jsonl"
  run_dream "$d" > "$d/out.json" || fail "run exited nonzero"
  [ -z "$(find "$d/calls" -name 'add.*')" ] || fail "items were filed with an unreadable ledger"
  jq -e '.steps.triage.status == "partial" and (.steps.triage.why | test("raised.jsonl"))' "$d/out.json" >/dev/null \
    || fail "the unreadable ledger was not reported: $(jq -c .steps.triage "$d/out.json")"
  d=$(new_case notriage)
  STUB_NO_TRIAGE=1 run_dream "$d" > "$d/out.json" || fail "run exited nonzero"
  jq -e '.steps.triage.status == "failed"' "$d/out.json" >/dev/null || fail "missing triage output was not a failure"
  jq -e '.summary | test("Did not run cleanly")' "$d/out.json" >/dev/null || fail "the summary hides the failed step"
  pass "a corrupt ledger or a triage agent that writes nothing files nothing and is reported"
}

test_a_terminated_run_leaves_no_agent_behind() {
  local d pid
  d=$(new_case term)
  STUB_DECK_SLEEP=31.4159 run_dream "$d" --only collect skills > "$d/out.json" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do pgrep -f 'sleep 31.4159' >/dev/null && break; sleep 0.2; done
  pgrep -f 'sleep 31.4159' >/dev/null || fail "the stub agent never started"
  kill -TERM "$(pgrep -f "fm_dream.py run --home $d/home")"; wait "$pid" 2>/dev/null
  sleep 0.5
  if pgrep -f 'sleep 31.4159' >/dev/null; then pkill -f 'sleep 31.4159'; fail "the agent kept running after SIGTERM"; fi
  [ -z "$(git -C "$d/dotfiles" worktree list | sed -n 2p)" ] || fail "the dreaming worktree was left behind after SIGTERM"
  pass "a terminated run ends its agent and removes its worktree"
}

test_dry_run_files_nothing_and_pushes_nothing() {
  local d before
  d=$(new_case dry)
  before=$(git -C "$d/origin.git" rev-parse main)
  run_dream "$d" --dry-run >/dev/null || fail "dry run exited nonzero"
  [ -n "$(find "$d/calls" -name 'add.*')" ] && fail "a dry run filed a task"
  [ "$(git -C "$d/origin.git" rev-parse main)" = "$before" ] || fail "a dry run pushed"
  [ -e "$d/home/state/dream/latest.json" ] && fail "a dry run replaced latest.json"
  pass "a dry run files nothing, pushes nothing and leaves the last summary alone"
}

test_report_shows_the_last_run() {
  local d out
  d=$(new_case report)
  run_dream "$d" >/dev/null || fail "run exited nonzero"
  out=$(python3 -c "
import sys, json, time; sys.path.insert(0, '$ROOT/bin'); import fm_report
print(json.dumps(fm_report.read_dream('$d/home', time.time() - 86400)))")
  printf '%s' "$out" | jq -e '.summary | test("Overnight")' >/dev/null || fail "report dream section missing: $out"
  printf '%s' "$out" | jq -e '.skills[0].skill == "merge"' >/dev/null || fail "skills missing from the report"
  pass "the fleet report carries the last dreaming run"
}

test_collect_builds_a_private_digest_of_the_day
test_skills_pushes_a_guarded_change_to_main
test_skills_rejects_changes_outside_skills_and_secrets
test_triage_dedupes_scores_caps_and_files_with_owners
test_a_failed_agent_is_reported_as_failed
test_a_malformed_config_stops_the_run
test_the_jev_helper_refuses_without_a_key
test_a_gateway_blip_is_retried_once_and_succeeds
test_unreadable_open_work_files_nothing_blind
test_a_corrupt_ledger_or_missing_agent_output_files_nothing
test_a_terminated_run_leaves_no_agent_behind
test_dry_run_files_nothing_and_pushes_nothing
test_report_shows_the_last_run
