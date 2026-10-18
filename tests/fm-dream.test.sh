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

# Dreaming commits outside new_case's command-substitution subshell, so its
# identity must be exported by the parent test shell too.
fm_git_identity

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
  mkdir -p "$d/dotfiles/skills/merge"
  printf -- '---\nname: merge\ndescription: merging\n---\nUse gh.\n' > "$d/dotfiles/skills/merge/SKILL.md"
  git -C "$d/dotfiles" add -A && git -C "$d/dotfiles" commit -qm init && git -C "$d/dotfiles" push -q origin HEAD:main 2>/dev/null
  git -C "$d/dotfiles" branch -q -u origin/main 2>/dev/null || true
  # firstmate: a bare origin with the instruction files, and a local clone
  git init -q --bare "$d/fm-origin.git"
  git clone -q "$d/fm-origin.git" "$d/firstmate" 2>/dev/null
  mkdir -p "$d/firstmate/.agents/skills/guide" "$d/firstmate/bin"
  printf '# Agents\n\nNever move money without the captain'"'"'s explicit word.\nBe brief.\n' > "$d/firstmate/AGENTS.md"
  printf -- '---\nname: guide\n---\nOne rule.\n' > "$d/firstmate/.agents/skills/guide/SKILL.md"
  printf '#!/usr/bin/env bash\n# brief templates\n' > "$d/firstmate/bin/fm-brief.sh"
  git -C "$d/firstmate" add -A && git -C "$d/firstmate" commit -qm init && git -C "$d/firstmate" push -q origin HEAD:main 2>/dev/null
  # stubs
  cat > "$d/bin/no-mistakes" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$STUB_CALLS/nm"
case "${STUB_NM:-pass}" in
  pass) printf 'outcome: checks-passed\nhelp[1]: "CI checks passed - the PR is ready: https://github.com/bastotec/firstmate/pull/990"\n' ;;
  gate) case "$*" in *abort*) echo "run_status: cancelled" ;; *)
          printf 'gate:\n  step: review\n  status: awaiting_approval\n  findings[1]{id,severity,file,action,description}:\n    R1,error,AGENTS.md,ask-user,"too broad"\n' ;; esac ;;
  broken) echo "error: daemon unreachable: dial ipc: no such file" >&2; exit 1 ;;
  scalar) case "$*" in *abort*) echo "run_status: cancelled" ;; *)
          printf 'run:\n  id: "r1"\n  status: running\n  findings[1]{id,severity,file,action,description}:\n    R2,warning,AGENTS.md,ask-user,"unclear"\ngate: review\n' ;; esac ;;
esac
SH
  cat > "$d/bin/gh-pr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *additions*) printf '{"additions": 3, "deletions": 0, "files": [{"path": "AGENTS.md"}]}\n' ;;
  *) printf '## Intent\n\nx\n\n## Risk Assessment\n\n✅ Low: a small wording change.\n' ;;
esac
SH
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
instructions=$(printf '%s' "$prompt" | grep -o '/[^ ]*instructions-[0-9-]*\.json' | head -1)
if [ -n "$instructions" ]; then
  case "${STUB_INSTR:-none}" in
    none) printf '{"changes": [], "charters": []}' > "$instructions" ;;
    edit) printf 'Answer a peer with --reply-to, never on the parent channel.\n' >> AGENTS.md
          printf '{"changes": [{"path": "AGENTS.md", "what": "says how to answer a peer", "why": "a mate answered on its parent channel", "evidence": ["x"]}],
                   "charters": [{"mate": "cadia", "what": "name the kernel repo", "why": "asked twice", "evidence": ["y"]},
                                {"mate": "finn-finance", "what": "PRIVATE CHARTER EDIT", "why": "z"}]}' > "$instructions" ;;
    unlisted) printf 'one\n' >> AGENTS.md; printf 'two\n' >> .agents/skills/guide/SKILL.md
              printf '{"changes": [{"path": "AGENTS.md", "what": "x", "why": "y", "evidence": ["e"]}]}' > "$instructions" ;;
    noevidence) printf 'one\n' >> AGENTS.md
                printf '{"changes": [{"path": "AGENTS.md", "what": "x", "why": "y"}]}' > "$instructions" ;;
    outside) printf 'x\n' > README.md
             printf '{"changes": [{"path": "README.md", "what": "x", "why": "y"}]}' > "$instructions" ;;
    hardstop) sed -i.bak '/money/d' AGENTS.md && rm -f AGENTS.md.bak
              printf '{"changes": [{"path": "AGENTS.md", "what": "shorter", "why": "y"}]}' > "$instructions" ;;
    moved) mkdir -p .agents/skills/archived && git mv AGENTS.md .agents/skills/archived/SKILL.md
           printf '{"changes": [{"path": "AGENTS.md", "what": "x", "why": "y", "evidence": ["e"]}, {"path": ".agents/skills/archived/SKILL.md", "what": "x", "why": "y", "evidence": ["e"]}]}' > "$instructions" ;;
    big) for i in $(seq 1 90); do printf 'line %s\n' "$i" >> AGENTS.md; done
         printf '{"changes": [{"path": "AGENTS.md", "what": "x", "why": "y"}]}' > "$instructions" ;;
    delimiters-small|delimiters-big|delimiters-hardstop)
         rm .agents/skills/guide/SKILL.md
         count=1; [ "$STUB_INSTR" != delimiters-big ] || count=78
         for i in $(seq 1 "$count"); do printf '++ tip %s\n' "$i"; done > .agents/skills/guide/NOTES.md
         printf '{"changes": [{"path": ".agents/skills/guide/SKILL.md", "what": "replace guide", "why": "unclear", "evidence": ["x"]},
                              {"path": ".agents/skills/guide/NOTES.md", "what": "add tips", "why": "unclear", "evidence": ["x"]}]}' > "$instructions" ;;
  esac
fi
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
        printf 'count: 3\ntasks[3]{id,state,kind,repo,title}:\n  fm-old,done,ship,firstmate,"Cache the drain result in fm-wake-drain.sh"\n  fm-dupes,queued,ship,"-","Prevent duplicate worker spawns, for a task"\n  fm-q,queued,ship,deck,"Handle \\"a,b\\" retry arguments in deck"\nhelp[2]:\n  - Run `tasks-axi show <id>` for full notes on a task\n  - Run `tasks-axi ready` to see unblocked queued work\n' ;;
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
  cat > "$d/bin/memory" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$STUB_CALLS/memory"
[ ! -e "$STUB_CALLS/memory-fails" ] || { echo "cannot read the shared file" >&2; exit 1; }
echo "captain-memory: 12 entries, 2 new candidates in x, oversized: none, repeats since last upkeep: 1"
SH
  chmod +x "$d/bin/"*
  printf '%s' "$d"
}

run_dream() {  # <case-dir> <args...>
  local d=$1; shift
  PATH="$d/bin:$PATH" DECK_STATE="$d/deck" FM_DREAM_DECK="$d/bin/deck" FM_DREAM_DOTFILES="$d/dotfiles" \
    FM_DREAM_JEV="$d/bin/jev" FM_DREAM_TASKS="$d/bin/tasks" FM_DREAM_HANDOFF="$d/bin/handoff" \
    FM_DREAM_REPORT="$d/bin/report" FM_DREAM_CAPTAIN_MEMORY="$d/bin/memory" FM_DREAM_NO_MISTAKES_DB="$d/nm.sqlite" STUB_CALLS="$d/calls" \
    FM_DREAM_FIRSTMATE="$d/firstmate" FM_DREAM_NO_MISTAKES="$d/bin/no-mistakes" FM_DREAM_GH="$d/bin/gh-pr" \
    python3 "$DREAM" run --home "$d/home" "$@"
}

test_each_relaunch_is_counted_once() {
  local d ts runs
  d=$(new_case revives)
  ts=$(date -u -r "$NOW" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "@$NOW" +%Y-%m-%dT%H:%M:%SZ)
  {
    printf '%s reviving mate-a (dead endpoint) with relaunch\n' "$ts"
    printf '%s revived mate-a: relaunched mate-a harness=deck model=m\n' "$ts"
    printf '%s mate-a is alive again\n' "$ts"
    printf '%s relaunched mate-b because its inner monologue (supervisor) kept failing\n' "$ts"
  } > "$d/home/state/secondmate-revive.log"
  run_dream "$d" --only collect > "$d/out.json" || true
  runs=$(find "$d/home/state/dream/runs" -name '*.json' | head -1)
  [ -n "$runs" ] || fail "no run record"
  [ "$(jq -r '.counts.revives' "$runs")" = 2 ] || fail "two relaunches must count as two, not every log line ($(jq -c .counts "$runs"))"
  pass "fm-dream: each relaunch is counted once, not once per log line"
}

test_collect_builds_a_private_digest_of_the_day() {
  local d digest
  d=$(new_case collect)
  run_dream "$d" --only collect > "$d/out.json" || fail "collect exited nonzero"
  digest=$(ls "$d"/home/state/dream/digest-*.md) || fail "no digest written"
  python3 -c 'import os, stat, sys; sys.exit(stat.S_IMODE(os.stat(sys.argv[1]).st_mode) != 0o600)' "$digest" \
    || fail "digest is not 0600"
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
  run_dream "$d" --only collect skills > "$d/out.json" || fail "run exited nonzero"
  jq -e '.steps.skills.status == "merged"' "$d/out.json" >/dev/null \
    || fail "skills step did not merge: $(jq -c .steps.skills "$d/out.json")"
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

test_the_captain_memory_upkeep_runs_nightly_and_reports_its_findings() {
  local d out
  d=$(new_case memory)
  out=$(run_dream "$d" --only memory) || fail "the memory step exited nonzero"
  assert_contains "$(cat "$d/calls/memory")" "upkeep --home $d/home" "the upkeep runs for this home"
  assert_contains "$out" 'Captain-memory: 12 entries, 2 new candidates' "its findings reach the summary line"
  assert_contains "$out" '"status": "done"' "findings are not a failure"
  : > "$d/calls/memory-fails"
  out=$(run_dream "$d" --only memory) || true
  assert_contains "$out" 'Did not run cleanly: memory (failed)' "an upkeep that cannot run is reported"
  pass "the captain memory's nightly upkeep runs in dreaming, and only a failure to run is not clean"
}

test_dry_run_files_nothing_and_pushes_nothing() {
  local d before
  d=$(new_case dry)
  before=$(git -C "$d/origin.git" rev-parse main)
  run_dream "$d" --dry-run >/dev/null || fail "dry run exited nonzero"
  [ -n "$(find "$d/calls" -name 'add.*')" ] && fail "a dry run filed a task"
  [ "$(git -C "$d/origin.git" rev-parse main)" = "$before" ] || fail "a dry run pushed"
  [ -e "$d/home/state/dream/latest.json" ] && fail "a dry run replaced latest.json"
  [ -e "$d/calls/memory" ] && fail "a dry run ran the captain memory upkeep"
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

test_collect_reads_captain_direct_from_every_included_local_home() {
  local d digest
  d=$(new_case captain-direct-mates)
  # a local included mate home: registered, no host, not excluded
  mkdir -p "$d/mate/state/captain-direct"
  printf -- '- dave-tools - tools and harness (home: %s; scope: tools; projects: deck; added 2026-01-01)\n' "$d/mate" \
    > "$d/home/data/secondmates.md"
  printf '%s\tcorr-9\tmate: first line\n' $((NOW - 700)) > "$d/mate/state/captain-direct.log"
  printf '%s delivered corr=def456 task=ship\n' "$(iso $((NOW - 400)))" >> "$d/mate/state/captain-direct.log"
  printf 'run the deck tests before pushing\n' > "$d/mate/state/captain-direct/def456.text"
  run_dream "$d" --only collect > "$d/out.json" || fail "collect exited nonzero"
  digest=$(ls "$d"/home/state/dream/digest-*.md) || fail "no digest written"
  grep -q 'run the deck tests before pushing' "$digest" || fail "a captain-direct delivery recorded in an included local mate's home is missing"
  grep -q 'no, merge only on green' "$digest" || fail "the main home's captain-direct body was lost"
  jq -e '.steps.collect.captain_messages == 4' "$d/out.json" >/dev/null \
    || fail "captain message count does not cover both homes' logs: $(jq -c .steps.collect "$d/out.json")"
  # an excluded home's records never reach the digest
  mkdir -p "$d/excluded/state/captain-direct"
  printf -- '- finn-finance - finance (home: %s; scope: finance; projects: books; added 2026-01-01)\n' "$d/excluded" \
    >> "$d/home/data/secondmates.md"
  printf '%s delivered corr=eee999 task=x\n' "$(iso $((NOW - 300)))" > "$d/excluded/state/captain-direct.log"
  printf 'PRIVATE EXCLUDED CORRECTION\n' > "$d/excluded/state/captain-direct/eee999.text"
  run_dream "$d" --only collect >/dev/null || fail "second collect exited nonzero"
  digest=$(ls "$d"/home/state/dream/digest-*.md)
  grep -q 'PRIVATE EXCLUDED CORRECTION' "$digest" && fail "an excluded home's captain-direct record reached the digest"
  pass "collect reads captain-direct deliveries from every included local home, not only the main one"
}

test_skills_accepts_a_non_ascii_skill_path() {
  local d
  d=$(new_case skills-utf8)
  cat > "$d/bin/deck" <<'SH'
#!/usr/bin/env bash
prompt=$(cat)
if [ -n "${STUB_DECK_SLEEP:-}" ]; then sleep "$STUB_DECK_SLEEP"; fi
summary=$(printf '%s' "$prompt" | grep -o '/[^ ]*skills-[0-9-]*\.json' | head -1)
triage=$(printf '%s' "$prompt" | grep -o '/[^ ]*triage-[0-9-]*\.json' | head -1)
if [ -n "$summary" ]; then
  mkdir -p skills/x
  printf 'uma skill sobre açaí\n' > 'skills/x/ação.md'
  printf '{"changes":[{"skill":"x/ação","what":"add","why":"why"}]}' > "$summary"
fi
if [ -n "$triage" ] && [ -z "${STUB_NO_TRIAGE:-}" ]; then printf '{"items": []}\n' > "$triage"; fi
SH
  chmod +x "$d/bin/deck"
  run_dream "$d" --only collect skills > "$d/out.json" || fail "run exited nonzero"
  jq -e '.steps.skills.status == "merged"' "$d/out.json" >/dev/null \
    || fail "a skills-only edit under a non-ASCII path was not merged: $(cat "$d/out.json")"
  git -C "$d/origin.git" show main:'skills/x/ação.md' | grep -q 'açaí' \
    || fail "the non-ASCII skill file did not land on main"
  [ -z "$(git -C "$d/dotfiles" worktree list | sed -n 2p)" ] || fail "the dreaming worktree was left behind"
  pass "a skills-only edit under a non-ASCII path is accepted, not falsely rejected"
}

test_a_terminated_run_is_finalized_as_partial() {
  local d pid runs latest
  d=$(new_case term-finalize)
  STUB_DECK_SLEEP=31.4159 run_dream "$d" > "$d/out.json" 2>&1 &
  pid=$!
  for _ in $(seq 1 50); do pgrep -f 'sleep 31.4159' >/dev/null && break; sleep 0.2; done
  pgrep -f 'sleep 31.4159' >/dev/null || fail "the stub agent never started"
  kill -TERM "$(pgrep -f "fm_dream.py run --home $d/home")"; wait "$pid" 2>/dev/null
  runs="$d/home/state/dream/runs"
  latest="$d/home/state/dream/latest.json"
  jq -e '.status == "partial" and .steps.skills.status == "interrupted" and (.steps | has("triage") | not)' \
    "$runs"/*.json >/dev/null || fail "the interrupted run record is wrong: $(cat "$runs"/*.json)"
  jq -e '.status == "partial" and .steps.skills.status == "interrupted" and (.summary | test("Did not run cleanly"))' \
    "$latest" >/dev/null || fail "latest.json was not finalized for the interrupted run: $(cat "$latest" 2>/dev/null)"
  # completed steps keep what they earned: the digest is still there
  ls "$d"/home/state/dream/digest-*.md >/dev/null 2>&1 || fail "the interrupted run lost the digest"
  pass "a terminated run finalizes as partial, keeping what its completed steps earned"
}

test_a_control_character_in_a_successful_add_is_still_parsed() {
  local d
  d=$(new_case add-control-chars)
  cat > "$d/bin/tasks" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list) printf 'count: 0\ntasks[0]{id,state,kind,repo,title}:\n' ;;
  add) n=$(find "$STUB_CALLS" -name 'add.*' | wc -l | tr -d ' '); printf '%s\n' "$*" > "$STUB_CALLS/add.$n"
       printf '{\n  "ok": true,\n  "action": "add",\n  "task": {"id": "dream-k%s", "title": "has a raw \ttab and\rcarriage return inside"}\n}\n' "$n" ;;
esac
SH
  chmod +x "$d/bin/tasks"
  run_dream "$d" > "$d/out.json" || fail "run exited nonzero"
  jq -e '.steps.file.status == "done" and (.steps.file.raised | length == 3)' "$d/out.json" >/dev/null \
    || fail "a successful add with raw control characters was rejected: $(jq -c .steps.file "$d/out.json")"
  [ "$(wc -l < "$d/home/state/dream/raised.jsonl")" -eq 3 ] || fail "the ledger was not written"
  grep -q 'unconfirmed' "$d/home/state/dream/raised.jsonl" && fail "handoffs read as unconfirmed"
  pass "tasks-axi output with raw control characters is still parsed, so the handoff and ledger are written"
}

# nm_case <name>: a case whose no-mistakes database has step results and repair
# budget decisions, so failures can be told apart by step and cause.
nm_case() {
  local d
  d=$(new_case "$1")
  sqlite3 "$d/nm.sqlite" "CREATE TABLE step_results(id TEXT, run_id TEXT, step_name TEXT, step_order INTEGER, status TEXT,
      started_at INTEGER, completed_at INTEGER, error TEXT, findings_json TEXT);
    CREATE TABLE repair_budget_decisions(round_id TEXT, step_result_id TEXT, consumed INTEGER, repair_limit INTEGER,
      authority_limit INTEGER, source TEXT, dispatch_state TEXT);
    INSERT INTO runs VALUES('c1','fleet','cancelled','fm/c1','cancelled: aborted by user','',$((NOW - 3000)),$((NOW - 3000)));
    INSERT INTO runs VALUES('c2','fleet','cancelled','fm/c2','cancelled: aborted by user','',$((NOW - 3000)),$((NOW - 3000)));
    INSERT INTO runs VALUES('k1','fleet','failed','fm/k1','step ci failed: update run PR state: database is locked (5) (SQLITE_BUSY)','',$((NOW - 3000)),$((NOW - 3000)));
    INSERT INTO runs VALUES('f1','fleet','failed','fm/f1','step pr failed: refusing non-compliant PR publication','',$((NOW - 3000)),$((NOW - 3000)));
    INSERT INTO step_results VALUES('s1','c1','review',3,'awaiting_approval',$((NOW - 3500)),NULL,'','[{\"id\":\"R1\"}]');
    INSERT INTO step_results VALUES('s2','c2','review',3,'awaiting_approval',$((NOW - 3500)),NULL,'','[]');
    INSERT INTO step_results VALUES('s3','k1','review',3,'completed',$((NOW - 3500)),$((NOW - 3400)),'','[]');
    INSERT INTO step_results VALUES('s4','k1','ci',10,'failed',$((NOW - 3300)),$((NOW - 3000)),'database is locked','[]');
    INSERT INTO step_results VALUES('s5','f1','pr',9,'failed',$((NOW - 3300)),$((NOW - 3000)),'non-compliant','[]');
    INSERT INTO step_results VALUES('s6','r1','lint',8,'failed',$((NOW - 7300)),$((NOW - 7200)),'timed out','[]');
    INSERT INTO runs VALUES('c3','fleet','cancelled','fm/c3','cancelled: aborted by user','',$((NOW - 3 * 86400)),$((NOW - 3000)));
    INSERT INTO step_results VALUES('s7','c3','review',3,'awaiting_approval',$((NOW - 3 * 86400)),NULL,'','[]');
    INSERT INTO runs VALUES('d1','fleet','failed','fm/d1','step review failed: context canceled','',$((NOW - 3000)),$((NOW - 3000)));
    INSERT INTO runs VALUES('c4','fleet','cancelled','fm/c4','cancelled: aborted by user','',$((NOW - 3000)),$((NOW - 3000)));
    INSERT INTO step_results VALUES('s8','c4','review',3,'fix_review',$((NOW - 3500)),NULL,'','[]');
    INSERT INTO step_results VALUES('s9','c4','test',4,'pending',NULL,NULL,'','[]');
    INSERT INTO repair_budget_decisions VALUES('x','s1',0,0,0,'exhausted','');
    INSERT INTO repair_budget_decisions VALUES('y','s7',0,0,0,'exhausted','');"
  printf '%s' "$d"
}

test_no_mistakes_failures_are_broken_down_by_step_cause_and_host() {
  local d log
  d=$(nm_case nm-causes)
  printf -- '- dave-tools - tools (host: workload; root: /r; home: /h/dave; scope: tools; projects: ; added 2026-10-01)\n' \
    > "$d/home/data/secondmates.md"
  cat > "$d/bin/bridge" <<'SH'
#!/usr/bin/env bash
[ "$1 $3" = "check reports" ] && exit 0; exit 1
SH
  cat > "$d/bin/ssh" <<'SH'
#!/usr/bin/env bash
cat > /dev/null
printf '%s\n' "$*" > "$STUB_CALLS/ssh"
printf '{"reviews": 7, "cap_hits": 3, "failed": 2, "by_step": {"review": 2}, "by_cause": {"repair cap": 2}, "runs": []}\n'
SH
  chmod +x "$d/bin/bridge" "$d/bin/ssh"
  mkdir -p "$d/home/state/dream"
  printf '{"schema": "fm-dream.v1", "date": "2026-10-11", "no_mistakes": {"failed": 9, "by_cause": {"aborted": 6, "infra": 3}, "hosts": {"this Mac": {"failed": 9, "by_cause": {"aborted": 6, "infra": 3}}}}}\n' \
    > "$d/home/state/dream/latest.json"
  FM_DREAM_BRIDGE="$d/bin/bridge" FM_DREAM_SSH="$d/bin/ssh" run_dream "$d" --only collect > "$d/out.json" \
    || fail "collect exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  python3 - "$log" <<'PY' || fail "no-mistakes breakdown wrong: $(jq -c .no_mistakes "$log")"
import json, sys
run = json.load(open(sys.argv[1]))
nm = run["no_mistakes"]
# r4 is the harness repository's failure from new_case, with no step results;
# c3 hit the repair cap days ago and was cancelled today, so the cap is its cause.
# d1 failed on a daemon shutdown (infra); c4 was cancelled while its review sat in fix_review.
assert nm["hosts"]["this Mac"]["by_cause"] == {"repair cap": 2, "aborted": 2, "infra": 2, "finding": 1, "timeout": 1, "other": 1}, nm["hosts"]["this Mac"]
assert nm["hosts"]["this Mac"]["reviews"] == 4 and nm["hosts"]["this Mac"]["cap_hits"] == 1, nm["hosts"]["this Mac"]
assert nm["hosts"]["workload"] == {"reviews": 7, "cap_hits": 3, "failed": 2, "by_cause": {"repair cap": 2}}, nm["hosts"]
assert nm["by_step"] == {"review": 6, "ci": 1, "pr": 1, "lint": 1, "none": 2}, nm["by_step"]
assert nm["failed"] == 11 and nm["by_cause"]["repair cap"] == 4, nm
# Only the machine measured both nights is compared; workload is new coverage.
ch = nm["change"]
assert ch["hosts"] == ["this Mac"] and ch["failed"] == 0 and ch["coverage_changed"] == ["workload"], ch
assert ch["by_cause"]["aborted"] == -4 and ch["by_cause"]["repair cap"] == 2, ch
assert "No-mistakes: 11 failed (+0 vs 2026-10-11, on this Mac only); top: repair cap 4" in run["summary"], run["summary"]
PY
  grep -q 'workload: 7 reviews, 3 hit the repair cap, 2 failed (repair cap 2)' "$d"/home/state/dream/digest-*.md \
    || fail "the digest lacks the per-host breakdown"
  grep -q 'workload python3 - ~/.no-mistakes/state.sqlite' "$d/calls/ssh" || fail "the remote database was not read over ssh"
  pass "no-mistakes failures are counted by step, cause and host, with the change since the previous night"
}

test_a_bridge_without_reports_skips_the_host_and_says_so() {
  local d
  d=$(nm_case nm-bridge)
  printf -- '- dave-tools - tools (host: workload; root: /r; home: /h/dave; scope: tools; projects: ; added 2026-10-01)\n' \
    > "$d/home/data/secondmates.md"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$d/bin/bridge"
  # shellcheck disable=SC2016 # the stub expands its own variables
  printf '#!/usr/bin/env bash\ntouch "$STUB_CALLS/ssh-called"\n' > "$d/bin/ssh"
  chmod +x "$d/bin/bridge" "$d/bin/ssh"
  FM_DREAM_BRIDGE="$d/bin/bridge" FM_DREAM_SSH="$d/bin/ssh" run_dream "$d" --only collect > "$d/out.json" \
    || fail "collect exited nonzero"
  [ ! -e "$d/calls/ssh-called" ] || fail "a host whose bridge denies reports was read anyway"
  jq -e '.steps.collect.why | test("workload: bridge does not allow reports")' "$d/out.json" >/dev/null \
    || fail "the skipped host is not named: $(cat "$d/out.json")"
  pass "a machine whose bridge denies reports is skipped and named, never read"
}

test_readable_disagreements_do_not_make_collect_partial() {
  local d
  d=$(nm_case clean-collect)
  # Only what makes collect partial in this case: no unreadable sessions.
  rm -f "$d/deck/sessions/broken.json" "$d/home/state/broken-mate.deck-session"
  cat > "$d/bin/report" <<'SH'
#!/usr/bin/env bash
printf '{"summary": "fleet ok", "waiting": [], "power": [], "shipped": [], "crew": [],
 "gaps": ["firstmate runtime: 31 more queued not listed"],
 "inconsistencies": ["bob helper: live child state has no in-flight backlog item: w1=paused"],
 "mates": [{"id": "bob-helper", "machine": "workload", "state": "externally_held", "working": 0, "waiting": 2, "shipped": 1, "freshness": "remote"}]}\n'
SH
  run_dream "$d" --only collect > "$d/out.json" || fail "collect exited nonzero"
  jq -e '.steps.collect.status == "done"' "$d/out.json" >/dev/null \
    || fail "readable data made collect partial: $(jq -c .steps.collect "$d/out.json")"
  grep -q 'mate bob-helper (workload): externally_held; 0 working, 2 waiting, 1 shipped' "$d"/home/state/dream/digest-*.md \
    || fail "the digest lacks the mate's current state"
  grep -q 'records disagree: bob helper: live child state' "$d"/home/state/dream/digest-*.md \
    || fail "the disagreement is not in the digest for triage"
  jq -e '.disagreements == ["bob helper: live child state has no in-flight backlog item: w1=paused"]
    and (.summary | test("1 home record disagrees \\(bob helper: live child state"))' "$(ls "$d"/home/state/dream/runs/*.json)" >/dev/null \
    || fail "the disagreement is not in the run summary: $(jq -c '{summary, disagreements}' "$(ls "$d"/home/state/dream/runs/*.json)")"
  sed -i.bak 's/"state": "externally_held", //' "$d/bin/report"
  run_dream "$d" --only collect > "$d/out.json" || fail "collect exited nonzero"
  jq -e '.steps.collect.status == "partial" and (.steps.collect.why | test("bob-helper: no current state"))' "$d/out.json" >/dev/null \
    || fail "a mate without a current state did not make collect partial"
  pass "collect is done when every mate was read, and readable disagreements go to the digest"
}

test_waiting_for_ziggy_is_not_the_step_s_own_time() {
  local d
  d=$(new_case ziggy-wait)
  # Ziggy's dream is "running" for the first five checks, then done.
  cat > "$d/bin/pgrep" <<'SH'
#!/usr/bin/env bash
n=$(cat "$STUB_CALLS/pgrep" 2>/dev/null || echo 0); echo $((n + 1)) > "$STUB_CALLS/pgrep"
[ "$n" -lt 5 ]
SH
  chmod +x "$d/bin/pgrep"
  FM_DREAM_SKIP_ZIGGY_WAIT=0 FM_DREAM_ZIGGY_POLL=1 run_dream "$d" --only collect > "$d/out.json" \
    || fail "collect exited nonzero"
  python3 - "$(ls "$d"/home/state/dream/runs/*.json)" <<'PY' || fail "the wait was booked as collect time: $(cat "$d/out.json")"
import json, sys
c = json.load(open(sys.argv[1]))["steps"]["collect"]
assert c["waited_for_ziggy"] == 5, c
# Collect itself takes about a second here; the wait is not part of it.
assert c["seconds"] < 5, c
assert set(c["timings"]) == {"sessions and local logs", "no-mistakes", "fleet report", "digest"}, c["timings"]
PY
  pass "time spent waiting for Ziggy's dream is recorded apart from the step's own time, with collect's phases"
}

test_instructions_open_one_gated_pr_and_propose_charter_edits() {
  local d log
  d=$(new_case instr-edit)
  STUB_INSTR=edit run_dream "$d" --only collect instructions > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  python3 - "$log" <<'PY' || fail "instructions step wrong: $(jq -c '.steps.instructions, .summary' "$log")"
import json, sys
run = json.load(open(sys.argv[1]))
st = run["steps"]["instructions"]
assert st["status"] == "pr opened" and st["pr"].endswith("/pull/990") and st["risk"] == "Low", st
# The gate repaired the one proposed line into three: the report shows what the PR holds.
assert run["instructions"]["lines"] == 3 and run["instructions"]["proposed_lines"] == 1, run["instructions"]
assert run["instructions"]["files"] == ["AGENTS.md"], run["instructions"]
assert "Instructions: PR holds 3 lines in AGENTS.md; proposed AGENTS.md: says how to answer a peer (PR https://github.com/bastotec/firstmate/pull/990, rated Low)" in run["summary"], run["summary"]
assert run["charter_proposals"] == [{"mate": "cadia", "what": "name the kernel repo"}], run["charter_proposals"]
PY
  grep -q -- '--yes --intent Nightly fleet dreaming instructions change' "$d/calls/nm" || fail "the change did not go through the gate"
  git -C "$d/firstmate" log -1 --format=%s "fm/dream-instructions-$(jq -r .date "$log")" | grep -q 'Improves fleet instructions' \
    || fail "the gated branch has no commit"
  [ "$(git -C "$d/fm-origin.git" rev-parse main)" = "$(git -C "$d/firstmate" rev-parse origin/main)" ] || fail "main moved"
  git -C "$d/fm-origin.git" log -1 --format=%s main | grep -q init || fail "dreaming pushed to main"
  grep -q 'cadia: name the kernel repo' "$d"/home/state/dream/charters-*.md || fail "charter proposal missing"
  grep -q 'PRIVATE CHARTER EDIT' "$d"/home/state/dream/charters-*.md && fail "an excluded mate's charter proposal leaked"
  pass "instructions: one small change ships through the gate as a PR, charter edits are proposed, main is untouched"
}

test_instructions_prune_landed_or_old_worktrees() {
  local d trees day branch tree current
  d=$(new_case instr-prune)
  trees="$d/home/state/dream"
  mkdir -p "$trees"
  current=$(python3 -c 'import datetime, os; print(datetime.datetime.fromtimestamp(int(os.environ["FM_DREAM_NOW"])).strftime("%Y-%m-%d"))')
  for day in 2026-10-01 2026-10-02 2026-10-03 2026-10-04 2026-10-05 2026-10-06 "$current"; do
    branch="fm/dream-instructions-$day"
    tree="$trees/firstmate-${branch//\//-}"
    git -C "$d/firstmate" worktree add -qb "$branch" "$tree" origin/main || fail "could not seed worktree"
    printf '%s\n' "$day" > "$tree/proposal-$day.txt"
    git -C "$tree" add -A && git -C "$tree" commit -qm "proposal $day" || fail "could not seed proposal"
  done
  git -C "$d/firstmate" merge -q --no-edit fm/dream-instructions-2026-10-01 || fail "could not seed ancestor merge"
  git -C "$d/firstmate" merge -q --squash fm/dream-instructions-2026-10-02 \
    && git -C "$d/firstmate" commit -qm 'squash proposal' \
    && git -C "$d/firstmate" push -q origin HEAD:main || fail "could not seed squash merge"
  git -C "$d/firstmate" merge-base --is-ancestor fm/dream-instructions-2026-10-02 origin/main \
    && fail "squash fixture unexpectedly has commit ancestry"
  python3 - "$trees" "$NOW" <<'PY'
import os, pathlib, sys
for path in pathlib.Path(sys.argv[1]).glob('firstmate-*'):
    stamp = int(sys.argv[2]) - (8 * 86400 if path.name.endswith('2026-10-06') else 0)
    os.utime(path, (stamp, stamp))
PY
  cat > "$d/bin/gh-pr" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "$PWD" "$*" >> "$STUB_CALLS/pr-list"
[ "$1 $2 $3" = 'pr list --head' ] && [ "$5 $6 $7 $8" = '--state merged --json number' ] || exit 2
case "$4" in
  *2026-10-02) printf '[{"number": 990}]\n' ;;
  *2026-10-04) printf '[{"number": 991}]\n'; exit 1 ;;
  *2026-10-05) printf 'unreadable\n' ;;
  *) printf '[]\n' ;;
esac
SH
  STUB_INSTR=none run_dream "$d" --only collect instructions > "$d/out.json" || fail "prune run failed"
  jq -e '.steps.instructions.status == "rejected" and (.steps.instructions.why | test("already exists"))' "$d/out.json" >/dev/null \
    || fail "current night's branch was not preserved"
  for day in 2026-10-01 2026-10-02 2026-10-06; do
    [ ! -d "$trees/firstmate-fm-dream-instructions-$day" ] || fail "$day landed or old tree survived"
  done
  for day in 2026-10-03 2026-10-04 2026-10-05 "$current"; do
    [ -d "$trees/firstmate-fm-dream-instructions-$day" ] || fail "$day unconfirmed or current tree was pruned"
  done
  grep -Fxq "$d/firstmate|pr list --head fm/dream-instructions-2026-10-02 --state merged --json number" "$d/calls/pr-list" \
    || fail "merged PR lookup did not use the configured gh in the firstmate repo"
  pass "instructions: ancestry and squash landings or age prune old trees, uncertain and current trees stay"
}

test_instructions_guards_reject_out_of_scope_hard_stop_and_big_changes() {
  local d mode
  for mode in outside hardstop big unlisted noevidence moved; do
    d=$(new_case "instr-$mode")
    STUB_INSTR=$mode run_dream "$d" --only collect instructions > "$d/out.json" || fail "run exited nonzero"
    jq -e '.steps.instructions.status == "rejected"' "$d/out.json" >/dev/null \
      || fail "$mode change was not rejected: $(jq -c .steps.instructions "$d/out.json")"
    [ ! -e "$d/calls/nm" ] || fail "a rejected $mode change reached the gate"
    git -C "$d/firstmate" rev-parse -q --verify "refs/heads/fm/dream-instructions-$(jq -r .date "$(ls "$d"/home/state/dream/runs/*.json)")" >/dev/null \
      && fail "a rejected $mode change left its branch"
  done
  jq -e '.steps.instructions.why | test("hard-stop")' "$TMP_ROOT/instr-hardstop/out.json" >/dev/null \
    || fail "the hard-stop rejection does not say why"
  pass "instructions: changes outside the instruction files, to a hard stop, or too big are rejected before the gate"
}

test_instructions_count_delimiter_content_and_check_its_hard_stops() {
  local d mode
  for mode in small big hardstop; do
    d=$(new_case "instr-delimiters-$mode")
    if [ "$mode" = hardstop ]; then
      printf -- '-- Never move money.\n' >> "$d/firstmate/.agents/skills/guide/SKILL.md"
      git -C "$d/firstmate" add -A && git -C "$d/firstmate" commit -qm 'add safety rule' \
        && git -C "$d/firstmate" push -q origin HEAD:main || fail "could not seed safety rule"
    fi
    STUB_INSTR="delimiters-$mode" run_dream "$d" --only collect instructions > "$d/out.json" || fail "run exited nonzero"
    case "$mode" in
      small)
        jq -e '.steps.instructions.status == "pr opened"' "$d/out.json" >/dev/null \
          || fail "a small delimiter change was rejected: $(cat "$d/out.json")"
        jq -e '.instructions.proposed_lines == 5' "$d"/home/state/dream/runs/*.json >/dev/null \
          || fail "the four removed lines and one added line were not all counted" ;;
      big|hardstop)
        jq -e '.steps.instructions.status == "rejected"' "$d/out.json" >/dev/null \
          || fail "$mode delimiter change was not rejected: $(cat "$d/out.json")"
        [ ! -e "$d/calls/nm" ] || fail "a rejected delimiter change reached the gate"
        if [ "$mode" = big ]; then
          jq -e '.steps.instructions.why == "82 changed lines (cap 80)"' "$d/out.json" >/dev/null \
            || fail "the delimiter content was not counted toward the cap"
        else
          jq -e '.steps.instructions.why | test("hard-stop")' "$d/out.json" >/dev/null \
            || fail "the removed -- safety rule was not checked"
        fi ;;
    esac
  done
  pass "instructions: delimiter content counts toward the proposal cap and removed hard-stop checks"
}

test_instructions_stop_a_parked_gate_and_report_it() {
  local d
  d=$(new_case instr-gate)
  STUB_INSTR=edit STUB_NM=gate run_dream "$d" --only collect instructions > "$d/out.json" || fail "run exited nonzero"
  jq -e '.steps.instructions.status == "needs a decision" and (.steps.instructions.why | test("review gate: R1 error"))
         and (.steps.instructions.why | test("not confirmed") | not)' "$d/out.json" >/dev/null \
    || fail "a parked gate was not reported: $(jq -c .steps.instructions "$d/out.json")"
  grep -q '|axi abort' "$d/calls/nm" || fail "the parked run was not stopped"
  d=$(new_case instr-gate-scalar)
  STUB_INSTR=edit STUB_NM=scalar run_dream "$d" --only collect instructions > "$d/out.json" || fail "run exited nonzero"
  jq -e '.steps.instructions.status == "needs a decision" and (.steps.instructions.why | test("review gate: R2 warning"))' "$d/out.json" >/dev/null \
    || fail "a scalar gate was not recognized: $(jq -c .steps.instructions "$d/out.json")"
  [ "$(grep -c '|axi run' "$d/calls/nm")" = 1 ] || fail "a scalar gate was reattached instead of stopped"
  d=$(new_case instr-gate-broken)
  STUB_INSTR=edit STUB_NM=broken run_dream "$d" --only collect instructions > "$d/out.json" || fail "run exited nonzero"
  jq -e '.steps.instructions.status == "failed" and (.steps.instructions.why | test("daemon unreachable"))' "$d/out.json" >/dev/null \
    || fail "a no-mistakes error was retried or hidden: $(jq -c .steps.instructions "$d/out.json")"
  [ "$(grep -c '|axi run' "$d/calls/nm")" = 1 ] || fail "a no-mistakes error was retried"
  pass "instructions: a gate --yes cannot pass is stopped and reported for the captain"
}

test_collect_builds_a_private_digest_of_the_day
test_each_relaunch_is_counted_once
test_instructions_open_one_gated_pr_and_propose_charter_edits
test_instructions_prune_landed_or_old_worktrees
test_instructions_guards_reject_out_of_scope_hard_stop_and_big_changes
test_instructions_count_delimiter_content_and_check_its_hard_stops
test_instructions_stop_a_parked_gate_and_report_it
test_waiting_for_ziggy_is_not_the_step_s_own_time
test_no_mistakes_failures_are_broken_down_by_step_cause_and_host
test_a_bridge_without_reports_skips_the_host_and_says_so
test_readable_disagreements_do_not_make_collect_partial
test_skills_pushes_a_guarded_change_to_main
test_skills_rejects_changes_outside_skills_and_secrets
test_collect_reads_captain_direct_from_every_included_local_home
test_skills_accepts_a_non_ascii_skill_path
test_a_terminated_run_is_finalized_as_partial
test_a_control_character_in_a_successful_add_is_still_parsed
test_triage_dedupes_scores_caps_and_files_with_owners
test_a_failed_agent_is_reported_as_failed
test_a_malformed_config_stops_the_run
test_the_jev_helper_refuses_without_a_key
test_a_gateway_blip_is_retried_once_and_succeeds
test_unreadable_open_work_files_nothing_blind
test_a_corrupt_ledger_or_missing_agent_output_files_nothing
test_a_terminated_run_leaves_no_agent_behind
test_dry_run_files_nothing_and_pushes_nothing
test_the_captain_memory_upkeep_runs_nightly_and_reports_its_findings
test_report_shows_the_last_run
