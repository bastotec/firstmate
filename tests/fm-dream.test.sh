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
  slow) case "$*" in *abort*) echo "run_status: cancelled" ;;
          *) if [ ! -e "$STUB_CALLS/nm-first" ]; then : > "$STUB_CALLS/nm-first"
               printf 'pr: "https://github.com/bastotec/firstmate/pull/991"\nerror: wait of 8m0s elapsed while driving the run\n'; exit 1
             fi; sleep 30 ;; esac ;;
  scalar) case "$*" in *abort*) echo "run_status: cancelled" ;; *)
          printf 'run:\n  id: "r1"\n  status: running\n  findings[1]{id,severity,file,action,description}:\n    R2,warning,AGENTS.md,ask-user,"unclear"\ngate: review\n' ;; esac ;;
esac
SH
  cat > "$d/bin/gh-pr" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *additions*) printf '{"additions": 3, "deletions": 0, "files": [{"path": "AGENTS.md"}]}\n' ;;
  *createdAt*) printf '{"createdAt": "2026-10-14T16:23:20Z", "mergedAt": "2026-10-14T17:30:00Z", "state": "MERGED", "mergeCommit": {"oid": "abcdef0000000000000000000000000000000000"}, "commits": []}\n' ;;
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
  add) n=$(find "$STUB_CALLS" -name 'add.*' | wc -l | tr -d ' '); printf '%s\n' "$*" > "$STUB_CALLS/add.$n"
       while [ "$#" -gt 0 ]; do
         if [ "$1" = --body-file ]; then cp "$2" "$STUB_CALLS/body.$n.md"; break; fi
         shift
       done
       printf '{\n  "ok": true,\n  "action": "add",\n  "task": {"id": "dream-k%s"}\n}\n' "$n" ;;
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
 "mates": [{"id": "primary", "name": "first mate", "freshness": "local", "state": "idle"},
           {"id": "dave-tools", "name": "dave tools", "freshness": "remote", "state": "working"}],
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
  cat > "$d/bin/reflect" <<'SH'
#!/usr/bin/env bash
cat > "$STUB_CALLS/reflect.$(find "$STUB_CALLS" -name 'reflect.*' | wc -l | tr -d ' ')"
case "${STUB_REFLECT:-none}" in
  none) printf '%s\n' '{"choices": [{"message": {"content": "{\"changes\": []}"}}]}' ;;
  ok) python3 -c '
import json
changes = [
 {"kind": "instructions", "change": "Tell workers to run the repo checks before the first run", "target": "fix_rounds",
  "evidence": "ship-x needed 4 fix rounds"},
 {"kind": "code", "repo": "bastotec/deck", "title": "Merge green mate PRs without waiting for a person", "fix": "in the PR step",
  "change": "Merge green mate PRs at once", "target": "waiting to merge", "evidence": "ship-x waited 1h to merge"},
 {"kind": "captain", "change": "Decide whether mates may merge medium-risk PRs", "target": "waiting to merge",
  "evidence": "3 PRs waited for a merge"},
 {"kind": "captain", "change": "A target off the list", "target": "nonsense", "evidence": "e"},
 {"kind": "code", "repo": "nowhere", "title": "Not a fleet repo", "change": "x", "evidence": "y"},
 {"kind": "instructions", "change": "no evidence"}]
print(json.dumps({"choices": [{"message": {"content": "Plan:\n" + json.dumps({"changes": changes})}}]}))' ;;
  dup) python3 -c '
import json
changes = [{"kind": "code", "repo": "firstmate", "title": "Prevent duplicate worker spawns for a task", "fix": "lock",
            "change": "Stop duplicate spawns", "target": "fix_rounds", "evidence": "two workers on one task"}]
print(json.dumps({"choices": [{"message": {"content": json.dumps({"changes": changes})}}]}))' ;;
  instructions) python3 -c '
import json
changes = [{"kind": "instructions", "change": change, "target": "review", "evidence": "ship-x waited in review"}
           for change in ("Name the required check commands", "Explain how to reproduce a review failure")]
print(json.dumps({"choices": [{"message": {"content": json.dumps({"changes": changes})}}]}))' ;;
  bad-repos) python3 -c '
import json
base = {"kind": "code", "title": "Reject a projectless fix", "change": "Retry a read", "fix": "retry",
        "target": "failed_runs", "evidence": "one failed read"}
changes = [base, dict(base, repo=None), dict(base, repo=""),
           dict(base, repo="phone-harness", title="Retry the phone connection"),
           dict(base, repo="bastotec/deck", title="Retry a disconnected tool session")]
print(json.dumps({"choices": [{"message": {"content": json.dumps({"changes": changes})}}]}))' ;;
  down) printf '%s\n' '{"error": {"code": "upstream_error", "message": "selected account has no project-owned enrollment"}}' ;;
esac
SH
  # send, inbox and hold record their arguments under their own name
  cat > "$d/bin/send" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$STUB_CALLS/$(basename "$0")"
printf '%s\n' "${FM_SEND_STREAM:-conversation}" >> "$STUB_CALLS/$(basename "$0").stream"
SH
  cp "$d/bin/send" "$d/bin/inbox"
  cat > "$d/bin/hold" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$STUB_CALLS/hold"
key=$2
while [ "$#" -gt 0 ]; do
  if [ "$1" = --card-file ]; then
    "$ROOT/bin/fm-card.sh" validate --file "$2" --task "$key"
    cp "$2" "$STUB_CALLS/captain-card.json"
    exit 0
  fi
  shift
done
exit 1
SH
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/bin/card"
  chmod +x "$d/bin/"*
  printf '%s' "$d"
}

run_dream() {  # <case-dir> <args...>
  local d=$1; shift
  PATH="$d/bin:$PATH" DECK_STATE="$d/deck" FM_DREAM_DECK="$d/bin/deck" FM_DREAM_DOTFILES="$d/dotfiles" \
    FM_DREAM_JEV="$d/bin/jev" FM_DREAM_TASKS="$d/bin/tasks" FM_DREAM_HANDOFF="$d/bin/handoff" \
    FM_DREAM_REPORT="$d/bin/report" FM_DREAM_CAPTAIN_MEMORY="$d/bin/memory" FM_DREAM_NO_MISTAKES_DB="$d/nm.sqlite" STUB_CALLS="$d/calls" \
    FM_DREAM_FIRSTMATE="$d/firstmate" FM_DREAM_NO_MISTAKES="$d/bin/no-mistakes" FM_DREAM_GH="$d/bin/gh-pr" \
    FM_DREAM_REFLECT="$d/bin/reflect" FM_DREAM_SEND="$d/bin/send" FM_DREAM_INBOX="$d/bin/inbox" FM_DREAM_HOLD="$d/bin/hold" \
    FM_DREAM_CARD="$d/bin/card" ROOT="$ROOT" FM_DREAM_TRACK_WAIT=0 python3 "$DREAM" run --home "$d/home" "$@"
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

# seed_improve <case-dir>: ship-x is a task of the home, with one run spawned
# 2 h before NOW whose PR the gh stub reports merged at NOW - 1000.
seed_improve() {
  local d=$1
  printf '# Backlog\n\n## In flight\n- [ ] ship-x - Do the thing (repo: firstmate) (kind: ship)\n' > "$d/home/data/backlog.md"
  printf 'spawn_gen=s%s.1.2\n' $((NOW - 7200)) > "$d/home/state/ship-x.meta"
  sqlite3 "$d/nm.sqlite" "INSERT INTO runs VALUES('rx','fleet','completed','fm/ship-x','','https://github.com/x/fm/pull/5',$((NOW - 6000)),$((NOW - 5000)));"
  mkdir -p "$d/home/state/autoland" "$d/home/state/dream"
  printf '%s autoland: merged https://github.com/bastotec/firstmate/pull/990 (deploy follows)\n%s autoland: deployed firstmate abcdef0: homes at abcdef0\n' \
    "$(iso $((NOW - 100)))" "$(iso $((NOW - 50)))" > "$d/home/state/autoland/report.log"
}

test_last_night_keeps_unread_homes_unresolved() {
  local d log mode
  d=$(new_case improve-home-gaps)
  seed_improve "$d"
  printf '%s\n' '{"date":"2026-10-01","kind":"captain","what":"a call","key":"cap-1","state":"card raised"}' \
    '{"date":"2026-10-01","kind":"code","what":"retry the hub","key":"w-9","mate":"dave-tools"}' \
    > "$d/home/state/dream/improve-actions.jsonl"
  for mode in unread cached incomplete; do
    python3 - "$d/bin/report" "$mode" <<'PY'
import json, sys
primary = {'id': 'primary', 'name': 'first mate', 'state': 'idle', 'freshness': 'local'}
mate = {'id': 'dave-tools', 'name': 'dave tools', 'state': 'working', 'freshness': 'remote'}
mode = sys.argv[2]
gaps = []
if mode == 'unread':
    primary.update(state=None, freshness='unreadable')
    gaps = ['first mate: no readable home summary']
elif mode == 'cached':
    mate['freshness'] = 'cached'
    gaps = ['dave tools: live summary unreachable, using the copy from yesterday']
else:
    gaps = ['first mate: 2 more holds not listed', 'dave tools: summary incomplete (child current state unavailable: w-9)']
report = {'summary': 'partial report', 'waiting': [], 'crew': [], 'shipped': [], 'power': [],
          'mates': [primary, mate], 'gaps': gaps}
with open(sys.argv[1], 'w') as f:
    f.write('#!/usr/bin/env bash\nprintf \'%s\\n\' ' + "'" + json.dumps(report) + "'\n")
PY
    STUB_REFLECT=down run_dream "$d" --only collect improve > "$d/$mode.json" || fail "run exited nonzero"
    log=$(ls "$d"/home/state/dream/runs/*.json)
    python3 - "$log" "$mode" <<'PY' || fail "a partial home was assumed resolved: $(jq -c .improve.last_night "$log")"
import json, sys
rows = json.load(open(sys.argv[1]))['improve']['last_night']
mode = sys.argv[2]
assert len(rows) == 2, rows
assert rows[0]['now_state'].startswith('state unread') if mode != 'cached' else rows[0]['now_state'] == 'answered or closed', rows
assert rows[1]['now_state'].startswith('state unread') if mode != 'unread' else rows[1]['now_state'] == 'no worker on it yet', rows
PY
  done
  pass "improve: unread, stale or incomplete home reports cannot answer cards or prove workers absent"
}

test_every_unshipped_instruction_reaches_the_summary() {
  local d log
  d=$(new_case improve-unshipped)
  seed_improve "$d"
  STUB_REFLECT=instructions STUB_INSTR=none run_dream "$d" --only collect improve instructions track > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  python3 - "$log" "$ROOT/bin" <<'PY' || fail "unshipped instructions disappeared: $(jq -c '.improve.tonight, .summary' "$log")"
import json, sys
run = json.load(open(sys.argv[1]))
life = run['improve']
assert len(life['tonight']) == 2, life
for action in life['tonight']:
    assert action['pr'] is None and action['what'] in run['summary'] and action['state'] in run['summary'], run['summary']
sys.path.insert(0, sys.argv[2])
import fm_dream as dream
life['tonight'] = [{'kind': 'instructions', 'what': 'First edit', 'pr': None, 'state': 'skipped: missing evidence'},
                   {'kind': 'instructions', 'what': 'Second edit', 'pr': None, 'state': 'skipped: private file'},
                   {'kind': 'instructions', 'what': 'Shipped edits', 'pr': 'https://github.com/o/r/pull/1', 'state': 'open'},
                   {'kind': 'instructions', 'what': 'Shipped edits', 'pr': 'https://github.com/o/r/pull/1', 'state': 'open'}]
summary = dream.improve_summary(life)
assert 'First edit (skipped: missing evidence)' in summary and 'Second edit (skipped: private file)' in summary, summary
assert summary.count('https://github.com/o/r/pull/1') == 1, summary
PY
  pass "improve: every unshipped or skipped instruction is reported, and only real PR links deduplicate"
}

test_failed_empty_measurements_are_not_quiet_days() {
  local d log
  d=$(new_case improve-unread-db)
  printf 'not a sqlite database\n' > "$d/nm.sqlite"
  run_dream "$d" --only improve track > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  jq -e '.status == "partial" and .steps.improve.status == "partial" and .steps.track.status == "partial"
    and (.steps.improve.why | test("no-mistakes state"))
    and (.summary | test("Improve: measurement incomplete:.*no-mistakes state"))' "$log" >/dev/null \
    || fail "a corrupt database looked quiet: $(cat "$log")"
  [ ! -e "$d/calls/reflect.0" ] || fail "an unreadable empty measurement called the model"
  pass "improve: an empty failed measurement stays partial and its reason reaches the morning summary"
}

test_answered_calls_are_not_raised_and_repeats_join_the_open_card() {
  local d
  d=$(new_case improve-answered-calls)
  python3 - "$d" "$ROOT/bin" <<'PY' || fail "dreaming raised an answered or repeated captain call"
import json, os, pathlib, subprocess, sys, time
sys.path.insert(0, sys.argv[2])
import fm_dream as dream
root = pathlib.Path(sys.argv[1])

def control_available(ctx, key):
    result = subprocess.run(
        ['bash', '-c', '. "$1"; fm_lock_try_acquire "$2" || exit 1; fm_lock_release "$2"',
         'probe-control', str(pathlib.Path(sys.argv[2]) / 'fm-wake-lib.sh'),
         str(ctx.state / ('.control-' + key + '.lock'))],
        env=dict(os.environ, FM_HOME=str(ctx.home)), capture_output=True, text=True, timeout=5)
    assert result.returncode in (0, 1), result
    return result.returncode == 0

class Context(dream.Ctx):
    def run(self, argv, **kw):
        self.calls.append(list(argv))
        if argv[0] == 'fake-card':
            if self.card_timeout:
                raise subprocess.TimeoutExpired(argv, kw['timeout'])
            listing = ''.join('%s\tFleet dreaming needs your call\n' % k for k in self.open_keys)
            if self.close_after_lookup:
                self.open_keys = set()
                self.bodies[self.close_after_lookup] = ('Captain resolution: keep the current setup\n\n'
                                                       + self.bodies[self.close_after_lookup])
            return subprocess.CompletedProcess(argv, 1 if self.unreadable else 0, listing, '')
        if argv[:2] == ['fake-hold', 'open']:
            if self.probe_lock:
                assert not control_available(self, argv[2]), 'open check ran without task control'
            return subprocess.CompletedProcess(argv, self.hold_error or (0 if argv[2] in self.open_keys else 1), '', '')
        if argv[0] == 'fake-policy':
            if argv[1] == 'list':
                return subprocess.CompletedProcess(argv, 0, 'owner bastotec/* auto\n', '')
            return subprocess.CompletedProcess(argv, 0, 'auto owner bastotec\n' if argv[2].startswith('bastotec/') else 'ask default\n', '')
        if argv[0] == 'fake-tasks':
            if self.probe_lock and argv[1] in ('show', 'update'):
                assert not control_available(self, argv[2]), '%s ran without task control' % argv[1]
            if argv[1] == 'show':
                if self.body_unreadable:
                    return subprocess.CompletedProcess(argv, 1, '', 'task unavailable')
                return subprocess.CompletedProcess(argv, 0, 'task:\n  body: %s\n' % json.dumps(self.bodies[argv[2]]), '')
            if argv[1] == 'update':
                self.bodies[argv[2]] = pathlib.Path(argv[argv.index('--body-file') + 1]).read_text()
            if argv[1] == 'add':
                return subprocess.CompletedProcess(argv, 0, json.dumps({'id': 'dream-call-new'}), '')
        return subprocess.CompletedProcess(argv, 0, '', '')

os.environ.update(FM_DREAM_TASKS='fake-tasks', FM_DREAM_HOLD='fake-hold', FM_DREAM_INBOX='fake-inbox',
                  FM_DREAM_CARD='fake-card', FM_DREAM_MERGE_POLICY='fake-policy')
home = root / 'home'
(home / 'data').mkdir(parents=True, exist_ok=True)
(home / 'data' / 'captain-shared.md').write_text('- 2026-10-20 captain instruction: "never deploy customer agents on Fridays without a rollback plan"\n')

def ctx_with(open_keys, ledger):
    ctx = Context(home, False)
    ctx.calls, ctx.open_keys, ctx.unreadable, ctx.body_unreadable = [], open_keys, False, False
    ctx.card_timeout = False
    ctx.close_after_lookup, ctx.probe_lock, ctx.hold_error = None, False, 0
    ctx.bodies = {key: '# Fleet dreaming needs your call\n\n' + '\n'.join(
        '- %s Evidence: %s' % (row['change'], row.get('evidence', '')) for row in ledger if row['key'] == key)
                  for key in open_keys}
    ctx.deadline = time.time() + 600
    ctx.config = {'owners': {}}
    ctx.dir.mkdir(parents=True, exist_ok=True)
    (ctx.dir / 'calls.jsonl').write_text(''.join(json.dumps(r) + '\n' for r in ledger))
    return ctx

def call(change):
    return {'kind': 'captain', 'change': change, 'evidence': 'measured', 'target': 'waiting to merge', 'before': 1}

answered = call('Delegate merge authority to the first mate for PRs that pass the full pipeline')
shared = call('Never deploy customer agents on Fridays without a rollback plan')
policy = call('Let the fleet merge bastotec/no-mistakes PRs on green')
fresh = call('Spend up to 50 dollars a month on a hosted runner for macOS builds')
ledger = [{'change': answered['change'], 'key': 'dream-call-old', 'at': 1}]

# answered elsewhere: an earlier call now closed, captain-shared.md, the merge policy
ctx = ctx_with(set(), ledger)
tonight = []
kept = dream.unanswered_calls(ctx, [answered, shared, policy, fresh], tonight, {})
assert [c['change'] for c in kept] == [fresh['change']], kept
reasons = [t['state'] for t in tonight]
assert any('earlier call dream-call-old closed' in r for r in reasons), reasons
assert any('captain-shared.md' in r for r in reasons), reasons
assert any('merge policy' in r for r in reasons), reasons

for change in ('Let the fleet merge bastotec/firstmate PRs once the full pipeline passes and CI is green',
               'Allow firstmate to merge bastotec/firstmate PRs after the full pipeline has passed and CI is green',
               'Let secondmates merge bastotec/firstmate PRs after all required checks have succeeded',
               'Allow bastotec/firstmate PRs to be merged automatically after CI succeeds',
               'Delegate automatic merge authority for pull requests in bastotec/firstmate and bastotec/no-mistakes'):
    ctx = ctx_with(set(), [])
    tonight = []
    assert dream.unanswered_calls(ctx, [call(change)], tonight, {}) == [], (change, tonight)
    assert tonight[-1]['state'] == 'not raised: already settled by the merge policy', tonight

for change, target in (('Allow automatic production promotion after merging bastotec/firstmate', 'deploy'),
                       ('Deploy bastotec/firstmate automatically after merging PRs', 'deploy'),
                       ('Release bastotec/firstmate after merging green PRs', 'deploy'),
                       ('Authorize spending for merging bastotec/firstmate PRs', 'held_or_blocked'),
                       ('Allow merging bastotec/firstmate PRs without captain approval', 'held_or_blocked'),
                       ('Let the fleet merge bastotec/firstmate PRs when CI checks are red', 'held_or_blocked'),
                       ('Let the fleet merge bastotec/firstmate PRs or auto approve pull requests', 'held_or_blocked'),
                       *((f'Let the fleet merge bastotec/firstmate PRs and {action}', 'held_or_blocked')
                         for action in ('promote to prod', 'allow deployments', 'waive review', 'grant a waiver',
                                        'skip a check', 'skip the required CI checks', 'bypass review',
                                        'force the update', 'perform destructive actions', 'delete branches',
                                        'destroy stored data', 'wipe state', 'reset history')),
                       ('Let the fleet merge elsewhere/project PRs on green', 'held_or_blocked'),
                       ('Let the fleet merge PRs on green', 'held_or_blocked')):
    ctx = ctx_with(set(), [])
    proposed = call(change)
    proposed['target'] = target
    assert dream.improve_changes(ctx, [proposed], {}), proposed
    tonight = []
    assert dream.unanswered_calls(ctx, [proposed], tonight, {}) == [proposed], (change, tonight)
    dream.raise_card(ctx, [proposed], [], tonight, {}, [])
    assert tonight[-1]['state'] == 'card raised', (change, tonight)
    assert any(c[0] == 'fake-hold' for c in ctx.calls), ctx.calls

# a repeat of a call still open joins it: no second card, no new task
ctx = ctx_with({'dream-call-open'}, [{'change': fresh['change'], 'evidence': 'measured', 'key': 'dream-call-open', 'at': 1}])
tonight = []
dream.raise_card(ctx, [fresh], [], tonight, {}, [])
assert tonight[-1]['state'] == 'already waiting on the captain as dream-call-open', tonight
assert not any(c[0] == 'fake-tasks' and c[1] in ('add', 'update') for c in ctx.calls), ctx.calls

# a new question while a card is open is added to that card, not raised separately
suffix = ('\n- Apply this charter edit for cadia? name the kernel repo\n\n'
          'Captain hold set: 2026-10-20T18:00:00Z\n'
          'Captain hold reason: awaiting fleet approval\nLifecycle note: retain this exact context\n')
ctx.bodies['dream-call-open'] += suffix
original = ctx.bodies['dream-call-open']
other = call('Approve a monthly budget for a second gateway account')
tonight = []
dream.raise_card(ctx, [other], [], tonight, {}, [])
assert tonight[-1]['state'] == 'added to the open card dream-call-open', tonight
assert not any(c[:2] == ['fake-tasks', 'add'] for c in ctx.calls), ctx.calls
upd = [c for c in ctx.calls if c[:3] == ['fake-tasks', 'update', 'dream-call-open']]
assert upd and '--archive-body' in upd[0], ctx.calls
assert not any(c[:2] == ['fake-hold', 'hold'] for c in ctx.calls), ctx.calls
assert [r['key'] for r in dream.call_ledger(ctx)][-1] == 'dream-call-open'
updated = ctx.bodies['dream-call-open']
assert updated.endswith(suffix), updated
assert fresh['change'] in updated and other['change'] in updated, updated
assert updated.replace('\n- %s Evidence: measured' % other['change'], '') == original, updated

legacy_body = '# Fleet dreaming needs your call (2026-10-20)\n\n- %s Evidence: measured%s' % (fresh['change'], suffix)
ctx = ctx_with({'dream-call-legacy', 'dream-call-z-newer'}, [])
ctx.bodies['dream-call-legacy'] = legacy_body
ctx.bodies['dream-call-z-newer'] = '# Fleet dreaming needs your call\n\n- %s Evidence: measured' % other['change']
tonight = []
dream.raise_card(ctx, [fresh], [], tonight, {}, [])
assert tonight[-1]['state'] == 'already waiting on the captain as dream-call-legacy', tonight
assert ctx.bodies['dream-call-legacy'] == legacy_body
assert not any(c[0] in ('fake-hold', 'fake-tasks') and c[1] in ('hold', 'add', 'update') for c in ctx.calls), ctx.calls
backfilled = dream.call_ledger(ctx)
assert {(r['key'], r['change'], r['evidence']) for r in backfilled} == {
    ('dream-call-legacy', fresh['change'], 'measured'),
    ('dream-call-z-newer', other['change'], 'measured')}, backfilled
assert len(backfilled) == 2, backfilled
dream.raise_card(ctx, [fresh], [], tonight, {}, [])
assert dream.call_ledger(ctx) == backfilled
ctx.open_keys = set()
ctx.facts.pop('dream_open_calls', None)
ctx.calls = []
ctx.facts['improve'] = {'changes': [fresh], 'tonight': []}
assert dream.step_file(ctx)['status'] == 'done'
assert ctx.facts['improve']['tonight'][-1]['state'] == 'not raised: already answered (earlier call dream-call-legacy closed)', ctx.facts
assert not any(c[0] in ('fake-hold', 'fake-tasks') for c in ctx.calls), ctx.calls

charter = {'mate': 'cadia', 'what': 'name the kernel repo'}
ctx = ctx_with({'dream-call-charter'}, [])
ctx.bodies['dream-call-charter'] = '# Fleet dreaming needs your call\n' + suffix
tonight = []
dream.raise_card(ctx, [], [charter], tonight, {}, [])
assert tonight[-1]['state'] == 'already waiting on the captain as dream-call-charter', tonight
dream.raise_card(ctx, [fresh], [], tonight, {}, [])
assert tonight[-1]['state'] == 'added to the open card dream-call-charter', tonight
assert ctx.bodies['dream-call-charter'].endswith(suffix), ctx.bodies
assert fresh['change'] in ctx.bodies['dream-call-charter'], ctx.bodies
assert not any(c[:2] in (['fake-hold', 'hold'], ['fake-tasks', 'add']) for c in ctx.calls), ctx.calls
assert dream.call_ledger(ctx)[-1]['key'] == 'dream-call-charter'

for rows in ([], [{'change': fresh['change'], 'key': 'dream-call-open'}]):
    ctx = ctx_with({'dream-call-open'}, rows)
    ctx.unreadable = True
    tonight, errors = [], []
    pending = dream.unanswered_calls(ctx, [fresh], tonight, {})
    ctx.unreadable = False
    dream.raise_card(ctx, pending, [], tonight, {}, errors)
    assert tonight[-1]['state'] == 'not raised: open cards unreadable', tonight
    assert errors == ['captain card not raised: open cards unreadable'], errors
    assert not any(c[0] in ('fake-tasks', 'fake-hold') for c in ctx.calls), ctx.calls

for rows in ([], [{'change': fresh['change'], 'key': 'dream-call-open'}]):
    ctx = ctx_with({'dream-call-open'}, rows)
    ctx.card_timeout = True
    (ctx.dir / 'raised.jsonl').unlink(missing_ok=True)
    ctx.facts['improve'] = {'changes': [fresh], 'tonight': []}
    ctx.facts['triage'] = [{'title': 'Repair the inbox status display', 'repo': 'firstmate',
                            'why': 'The display is stale', 'fix': 'Refresh its status', 'evidence': ['measured']}]
    result = dream.step_file(ctx)
    assert result['status'] == 'partial', result
    assert result['why'] == 'captain card not raised: open cards unreadable', result
    assert ctx.facts['improve']['tonight'][-1]['state'] == 'not raised: open cards unreadable', ctx.facts
    assert [r['title'] for r in result['raised']] == ['Repair the inbox status display'], result
    assert [json.loads(line)['title'] for line in (ctx.dir / 'raised.jsonl').read_text().splitlines()] == [
        'Repair the inbox status display']
    assert sum(c[0] == 'fake-card' for c in ctx.calls) == 1, ctx.calls
    assert not any(c[0] == 'fake-hold' or (c[:2] == ['fake-tasks', 'add'] and 'dream-call' in c)
                   for c in ctx.calls), ctx.calls

ctx = ctx_with({'dream-call-open'}, [])
ctx.body_unreadable = True
tonight, errors = [], []
dream.raise_card(ctx, [fresh], [], tonight, {}, errors)
assert tonight[-1]['state'] == 'not raised: open cards unreadable', tonight
assert not any(c[:2] in (['fake-hold', 'hold'], ['fake-tasks', 'add'], ['fake-tasks', 'update']) for c in ctx.calls), ctx.calls
assert control_available(ctx, 'dream-call-open')

for rows in ([], [{'change': fresh['change'], 'key': 'dream-call-open'}]):
    for repeated in (False, True):
        ctx = ctx_with({'dream-call-open'}, rows)
        ctx.bodies['dream-call-open'] = legacy_body
        ctx.close_after_lookup, ctx.probe_lock = 'dream-call-open', True
        proposed = fresh if repeated else other
        tonight, errors = [], []
        pending = dream.unanswered_calls(ctx, [proposed], tonight, {})
        assert pending == [proposed], (pending, tonight)
        dream.raise_card(ctx, pending, [], tonight, {}, errors)
        assert not errors, errors
        assert ctx.bodies['dream-call-open'] == 'Captain resolution: keep the current setup\n\n' + legacy_body, ctx.bodies
        assert not any(c[:2] == ['fake-tasks', 'update'] for c in ctx.calls), ctx.calls
        backfilled = dream.call_ledger(ctx)
        assert [(r['change'], r['key']) for r in backfilled if r['key'] == 'dream-call-open'] == [
            (fresh['change'], 'dream-call-open')], backfilled
        if repeated:
            assert tonight[-1]['state'] == 'not raised: already answered (earlier call dream-call-open closed)', tonight
            assert not any(c[:2] == ['fake-tasks', 'add'] for c in ctx.calls), ctx.calls
            assert len(backfilled) == 1, backfilled
        else:
            assert tonight[-1]['state'] == 'card raised' and tonight[-1]['key'] == 'dream-call-new', tonight
            assert backfilled[-1]['change'] == other['change'] and backfilled[-1]['key'] == 'dream-call-new', backfilled
        ctx.open_keys = {'dream-call-new'} if not repeated else set()
        ctx.close_after_lookup = None
        ctx.facts.pop('dream_open_calls', None)
        next_night = []
        assert dream.unanswered_calls(ctx, [fresh], next_night, {}) == [], next_night
        assert next_night[-1]['state'] == 'not raised: already answered (earlier call dream-call-open closed)', next_night
        if not repeated:
            assert dream.unanswered_calls(ctx, [other], [], {}) == [other]
        assert control_available(ctx, 'dream-call-open')

for proposed in (fresh, other):
    ctx = ctx_with({'dream-call-legacy'}, [])
    ctx.bodies['dream-call-legacy'] = legacy_body
    ctx.close_after_lookup, ctx.probe_lock, ctx.body_unreadable = 'dream-call-legacy', True, True
    tonight, errors = [], []
    pending = dream.unanswered_calls(ctx, [proposed], tonight, {})
    dream.raise_card(ctx, pending, [], tonight, {}, errors)
    assert tonight[-1]['state'] == 'not raised: card state unreadable', tonight
    assert errors == ['captain card not raised: card state unreadable'], errors
    assert dream.call_ledger(ctx) == []
    assert ctx.bodies['dream-call-legacy'] == 'Captain resolution: keep the current setup\n\n' + legacy_body, ctx.bodies
    assert any(c[:3] == ['fake-tasks', 'show', 'dream-call-legacy'] for c in ctx.calls), ctx.calls
    assert not any(c[:2] in (['fake-tasks', 'add'], ['fake-tasks', 'update'], ['fake-hold', 'hold']) for c in ctx.calls), ctx.calls
    assert control_available(ctx, 'dream-call-legacy')

ctx = ctx_with({'dream-call-open'}, [])
ctx.probe_lock = True
original = ctx.bodies['dream-call-open'] = legacy_body
tonight, errors = [], []
dream.raise_card(ctx, [other], [], tonight, {}, errors)
assert not errors and tonight[-1]['state'] == 'added to the open card dream-call-open', (tonight, errors)
assert ctx.bodies['dream-call-open'].replace('\n- %s Evidence: measured' % other['change'], '') == original
assert dream.call_ledger(ctx)[-1]['key'] == 'dream-call-open'
assert control_available(ctx, 'dream-call-open')

ctx = ctx_with({'dream-call-open'}, [])
ctx.hold_error = 2
tonight, errors = [], []
dream.raise_card(ctx, [fresh], [], tonight, {}, errors)
assert tonight[-1]['state'] == 'not raised: open cards unreadable', tonight
assert not any(c[:2] in (['fake-tasks', 'add'], ['fake-tasks', 'update']) for c in ctx.calls), ctx.calls
assert dream.call_ledger(ctx) == []
assert control_available(ctx, 'dream-call-open')

# with no open card, a fresh call raises one card and is recorded for later nights
ctx = ctx_with(set(), [])
tonight = []
dream.raise_card(ctx, [fresh], [], tonight, {}, [])
assert tonight[-1]['state'] == 'card raised' and tonight[-1]['key'] == 'dream-call-new', tonight
assert [r['change'] for r in dream.call_ledger(ctx)] == [fresh['change']]

shared_path = home / 'data' / 'captain-shared.md'
budget = call('Use 75 dollars monthly for dedicated Linux test servers')
with shared_path.open('a') as fh:
    fh.write('- 2026-10-20 captain instruction (recorded at delivery from chat): "Always follow this runner-budget rule:\n'
             '  Use 75 dollars monthly for dedicated Linux test servers"\n')
tonight = []
assert dream.unanswered_calls(ctx, [budget], tonight, {}) == [], tonight
assert tonight[-1]['state'] == 'not raised: already answered in captain-shared.md', tonight

# the improve prompt is told what is already decided
text = dream.decided_text(ctx)
assert 'rollback plan' in text and 'Merge policy' in text and 'Already asked (dream-call-new)' in text, text
assert 'Always follow this runner-budget rule:\n  Use 75 dollars monthly' in text, text
PY
  pass "improve: answered captain calls are not raised again, and a repeat joins the open card"
}

test_decided_context_keeps_complete_public_entries_only() {
  local d
  d=$(new_case improve-decided-private)
  seed_improve "$d"
  python3 - "$d/home" <<'PY'
import json, pathlib, sys
home = pathlib.Path(sys.argv[1])
(home / 'data' / 'captain-shared.md').write_text(
    '- 2026-10-20 captain instruction (recorded at delivery from chat): "Always follow the runner budget:\n'
    '  PUBLIC BUDGET: spend up to 50 dollars a month on macOS builds"\n'
    '- 2026-10-20 captain instruction: "PRIVATE SHARED ' + 'x' * 700 + ' finn-finance"\n'
    '- 2026-10-20 captain instruction: "PRIVATE CONTINUATION\n  finn-finance"\n'
    'Rule: PUBLIC RULE never deploy without a rollback plan\n')
rows = [{'change': 'PUBLIC CALL: allow a second gateway', 'key': 'dream-call-public'},
        {'change': 'PRIVATE QUESTION ' + 'x' * 700 + ' finn-finance', 'key': 'dream-call-secret'},
        {'change': 'PRIVATE EVIDENCE', 'evidence': 'finn-finance', 'key': 'dream-call-evidence'}]
(home / 'state' / 'dream').mkdir(parents=True, exist_ok=True)
(home / 'state' / 'dream' / 'calls.jsonl').write_text(''.join(json.dumps(row) + '\n' for row in rows))
PY
  STUB_REFLECT=none run_dream "$d" --only collect improve > "$d/out.json" || fail "decided-context run failed"
  python3 - "$d/calls" <<'PY' || fail "the emitted gateway request leaked or truncated a decided entry"
import json, pathlib, sys
requests = [json.loads(path.read_text()) for path in pathlib.Path(sys.argv[1]).glob('reflect.*')]
assert requests, 'no gateway request emitted'
for request in requests:
    prompt = request['messages'][0]['content']
    assert 'Always follow the runner budget:\n  PUBLIC BUDGET: spend up to 50 dollars' in prompt, prompt
    assert 'PUBLIC CALL: allow a second gateway' in prompt and 'PUBLIC RULE' in prompt, prompt
    assert all(secret not in prompt for secret in ('PRIVATE SHARED', 'PRIVATE CONTINUATION', 'PRIVATE QUESTION',
                                                  'PRIVATE EVIDENCE', 'finn-finance')), prompt
PY
  pass "improve: the gateway receives complete instructions and no excluded decided records"
}

test_card_timeouts_keep_filings_and_allow_triage() {
  local d
  d=$(new_case improve-card-timeout)
  python3 - "$d" "$ROOT/bin" <<'PY' || fail "a card timeout lost filings or prevented triage"
import json, os, pathlib, subprocess, sys, time
sys.path.insert(0, sys.argv[2])
import fm_dream as dream
root = pathlib.Path(sys.argv[1])

class Context(dream.Ctx):
    def run(self, argv, **kw):
        self.calls.append(argv)
        if argv[0] == 'fake-hold' or (self.mode == 'add' and '--prefix' in argv and argv[argv.index('--prefix') + 1] == 'dream-call'):
            if self.mode == 'budget':
                self.deadline = time.time() - 1
            raise subprocess.TimeoutExpired(argv, 60)
        if argv[0] == 'fake-tasks':
            self.adds += 1
            return subprocess.CompletedProcess(argv, 0, json.dumps({'id': 'filed-%s' % self.adds}), '')
        return subprocess.CompletedProcess(argv, 0, '', '')

os.environ.update(FM_DREAM_TASKS='fake-tasks', FM_DREAM_HOLD='fake-hold', FM_DREAM_INBOX='fake-inbox',
                  FM_DREAM_CARD='fake-card')
for mode in ('hold', 'add', 'budget'):
    home = root / mode
    ctx = Context(home, False)
    ctx.mode, ctx.calls, ctx.adds = mode, [], 0
    ctx.deadline = time.time() + 600
    ctx.config = {'owners': {'firstmate': 'primary'}}
    code = {'kind': 'code', 'repo': 'firstmate', 'title': 'Retry the lifecycle read', 'change': 'Retry a transient read',
            'fix': 'Bound the retry', 'evidence': 'ship-x failed', 'target': 'failed_runs', 'before': 1}
    captain = {'kind': 'captain', 'change': 'Approve a private setting', 'evidence': 'ship-x waited',
               'target': 'waiting to merge', 'before': 60}
    triage = {'repo': 'firstmate', 'title': 'Cache independent measurements', 'evidence': ['slow read'], 'fix': 'cache'}
    ctx.facts = {'improve': {'changes': [code, captain], 'tonight': []}, 'triage': [triage], 'open_work': ([], [])}
    if mode == 'budget':
        try:
            dream.step_file(ctx)
            raise AssertionError('step-budget exhaustion was swallowed')
        except subprocess.TimeoutExpired:
            pass
        assert [r['title'] for r in ctx.facts['raised']] == [code['title']], ctx.facts
    else:
        result = dream.step_file(ctx)
        assert result['status'] == 'partial' and 'captain card not raised' in result['why'], result
        assert [r['title'] for r in result['raised']] == [code['title'], triage['title']], result
        assert ctx.facts['raised'] == result['raised'], ctx.facts
        assert ctx.facts['improve']['tonight'][0]['state'].startswith('dispatch ordered'), ctx.facts
    rows = [json.loads(l) for l in (ctx.dir / 'raised.jsonl').read_text().splitlines()]
    assert [r['key'] for r in rows] == [r['key'] for r in ctx.facts['raised']], rows
    card = ctx.facts['improve']['tonight'][-1]
    assert card['state'] == 'card not raised: TimeoutExpired', card
    assert card['key'] == ('filed-2' if mode != 'add' else None), card
    assert not (ctx.dir / '.card.md').exists() and not (ctx.dir / '.card.json').exists()
PY
  pass "improve: card timeouts preserve dispatched filings and continue triage unless the step budget is exhausted"
}

test_track_rejects_a_predecessor_deployment() {
  local d log
  d=$(new_case improve-deploy-predecessor)
  seed_improve "$d"
  printf '%s autoland: merged https://github.com/bastotec/firstmate/pull/990 (deploy follows)\n%s autoland: deployed firstmate 1111111: previous commit\n' \
    "$(iso $((NOW - 100)))" "$(iso $((NOW - 50)))" > "$d/home/state/autoland/report.log"
  STUB_REFLECT=none STUB_INSTR=edit run_dream "$d" --only collect improve instructions track > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  jq -e '.improve.tonight[] | select(.kind == "instructions") | .state == "merged, deploy pending"' "$log" >/dev/null \
    || fail "track accepted the preceding commit's deployment: $(cat "$log")"
  pass "improve: tracking retains deploy-pending when only a predecessor has deployed"
}

test_improve_acts_on_every_kind_of_change() {
  local d log
  d=$(new_case improve)
  seed_improve "$d"
  printf '{"date": "2026-10-01", "mate_median": 7000, "mate_p90": 9000, "session_median": 600, "merged": 0, "open": 2}\n' \
    > "$d/home/state/dream/improve.jsonl"
  STUB_REFLECT=ok STUB_INSTR=edit run_dream "$d" --only collect improve instructions file track > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  python3 - "$log" "$d/calls" <<'PY' || fail "improve wrong: $(jq -c '.steps, .summary' "$log")"
import glob, json, sys
run = json.load(open(sys.argv[1]))
calls = sys.argv[2]
st, life = run["steps"]["improve"], run["improve"]
assert st["status"] == "done" and st["tasks"] == 1 and st["changes"] == 3 and st["dropped"] == 3, st
assert life["model"] == "claude/opus-5-5" and life["metrics"]["mate"]["median"] == 6200, life
kinds = [c["kind"] for c in life["changes"]]
assert kinds == ["instructions", "code", "captain"], kinds
assert life["changes"][2]["target"] == "waiting to merge" and life["changes"][0]["before"] == 0, life["changes"]
assert life["previous"]["date"] == "2026-10-01" and life["change"]["mate_median"] == -800, life
reqs = glob.glob(calls + "/reflect.*")
assert len(reqs) == 1, reqs
req = json.load(open(reqs[0]))
assert req["model"] == "claude/opus-5-5" and "tools" not in req and len(req["messages"]) == 1, req
assert "ship-x" in req["messages"][0]["content"], req
# instructions: the agent was told to make the change, and its PR is followed to deploy
prompts = [open(f).read() for f in glob.glob(calls + "/deck.*")]
assert any("must make them" in p and "Tell workers to run the repo checks" in p for p in prompts), "required change not in the prompt"
tonight = {a["kind"]: a for a in life["tonight"]}
assert tonight["instructions"]["pr"].endswith("/pull/990") and tonight["instructions"]["state"] == "merged and deployed", tonight
assert run["steps"]["track"]["status"] == "done" and run["steps"]["track"]["acted"] == 3, run["steps"]["track"]
# code: a priority task, handed to the owning mate, with a dispatch order
adds = [open(f).read() for f in sorted(glob.glob(calls + "/add.*"))]
code_add = [a for a in adds if "Merge green mate PRs" in a]
assert code_add and "--priority 0" in code_add[0] and "--repo deck" in code_add[0], adds
key = tonight["code"]["key"]
assert tonight["code"]["state"] == "dispatch ordered to dave-tools as %s" % key, tonight["code"]
assert open(calls + "/handoff." + key).read().strip() == "dave-tools " + key
send = open(calls + "/send").read()
assert send.startswith("dave-tools Priority from fleet dreaming: %s" % key) and "Dispatch a worker on it now" in send, send
assert open(calls + "/send.stream").read().split() == ["monologue"], "the dispatch order did not go to the operational lane"
assert [r["key"] for r in run["raised"]] == [key] and run["raised"][0]["mate"] == "dave-tools", run["raised"]
# captain: one plain card, with the charter proposal on it
card = tonight["captain"]
assert card["state"] == "card raised" and card["key"], card
hold = open(calls + "/hold").read()
assert hold.startswith("hold %s --reason Decide whether mates may merge medium-risk PRs" % card["key"]), hold
assert "charter edit for cadia: name the kernel repo" in card["what"], card
payload = json.load(open(calls + "/captain-card.json"))
assert payload["project"] == "firstmate" and payload["recommended"] == "1", payload
assert [o["key"] for o in payload["options"]] == ["1", "2"], payload
assert all(card["key"] in o["instruction"] for o in payload["options"]), payload
body = open(calls + "/body.%s.md" % card["key"][len("dream-k"):]).read()
assert "Decide whether mates may merge medium-risk PRs" in body and "3 PRs waited for a merge" in body, body
assert "Apply this charter edit for cadia? name the kernel repo" in body, body
s = run["summary"]
assert "Improve: 1 mate task (1 merged, 0 open), start to merge median 1.7h (p90 1.7h) (-13m vs 2026-10-01)" in s, s
assert "Tonight: AGENTS.md: says how to answer a peer (https://github.com/bastotec/firstmate/pull/990, merged and deployed)" in s, s
assert "Merge green mate PRs without waiting for a person (dispatch ordered to dave-tools as %s)" % key in s, s
assert "captain card %s" % card["key"] in s, s
PY
  grep -q '^## Improve' "$d"/home/state/dream/digest-*.md || fail "the digest has no improve section"
  python3 -c 'import os, stat, sys; sys.exit(stat.S_IMODE(os.stat(sys.argv[1]).st_mode) != 0o600)' "$d"/home/state/dream/digest-*.md \
    || fail "the digest is no longer private"
  [ ! -e "$d/home/state/dream/improve-actions.jsonl" ] || fail "an --only run recorded the night's actions"
  [ "$(wc -l < "$d/home/state/dream/improve.jsonl" | tr -d ' ')" = 1 ] || fail "an --only run wrote the night-over-night history"
  pass "improve: Opus is asked once, and its instructions, code and captain changes are shipped, dispatched and carded"
}

test_improve_reports_last_night_s_changes_and_their_targets() {
  local d log
  d=$(new_case improve-last)
  seed_improve "$d"
  printf '%s\n' '{"date": "2026-10-01", "kind": "instructions", "what": "brief names the checks", "pr": "https://github.com/bastotec/firstmate/pull/990", "target": "parked at a gate", "before": 7200}' \
    '{"date": "2026-10-01", "kind": "code", "what": "retry the hub", "key": "w-9", "mate": "dave-tools", "target": "fix_rounds", "before": 9}' \
    '{"date": "2026-10-01", "kind": "captain", "what": "a call", "key": "cap-1", "state": "card raised"}' \
    '{"date": "2026-10-01", "kind": "code", "what": "PRIVATE ACTION", "key": "p-1", "mate": "finn-finance"}' \
    '{"date": "2026-09-30", "kind": "code", "what": "OLDER NIGHT", "key": "x"}' > "$d/home/state/dream/improve-actions.jsonl"
  STUB_REFLECT=down run_dream "$d" --only collect improve > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  python3 - "$log" <<'PY' || fail "last night wrong: $(jq -c '.improve.last_night, .summary' "$log")"
import json, sys
run = json.load(open(sys.argv[1]))
last = run["improve"]["last_night"]
assert [a["now_state"] for a in last] == ["merged and deployed", "worker failed", "answered or closed"], last
assert last[0]["now_value"] == 0 and last[1]["now_value"] == 0, last
s = run["summary"]
assert "Last night: brief names the checks (merged and deployed, parked at a gate 2.0h -> 0m); retry the hub (worker failed, fix_rounds 9 -> 0)" in s, s
assert "OLDER NIGHT" not in s and "PRIVATE ACTION" not in s, s
PY
  # an unreadable fleet report proves nothing about a worker or a card
  printf '#!/usr/bin/env bash\nexit 1\n' > "$d/bin/report"
  rm -f "$d"/home/state/dream/runs/*.json
  STUB_REFLECT=down run_dream "$d" --only collect improve > "$d/out2.json" || fail "second run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  [ "$(jq -c '[.improve.last_night[].now_state]' "$log")" = \
    '["merged and deployed","state unread: the fleet report could not be read","state unread: the fleet report could not be read"]' ] \
    || fail "an unreadable report was read as an answer: $(jq -c '.improve.last_night' "$log")"
  pass "improve: last night's changes are reported with their state now and the measurement they targeted, then and now"
}

test_improve_files_no_duplicate_and_cards_charters_on_a_quiet_night() {
  local d log
  d=$(new_case improve-dup)
  seed_improve "$d"
  STUB_REFLECT=dup run_dream "$d" --only collect improve triage file track > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  [ "$(jq -r '.improve.tonight[0].state' "$log")" = "already open, not filed again" ] \
    || fail "a change already in the open work was filed: $(jq -c '.improve.tonight' "$log")"
  [ ! -e "$d/calls/send" ] || fail "a duplicate got a dispatch order"
  [ "$(jq -r '.steps.track.status' "$log")" = "nothing changed" ] || fail "an unacted night read as done: $(jq -c .steps.track "$log")"
  d=$(new_case improve-quiet)
  sqlite3 "$d/nm.sqlite" "DELETE FROM runs"
  STUB_INSTR=edit run_dream "$d" --only collect improve instructions file track > "$d/out.json" || fail "quiet run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  python3 - "$log" <<'PY' || fail "quiet night wrong: $(jq -c '.steps, .summary' "$log")"
import json, sys
run = json.load(open(sys.argv[1]))
assert run["steps"]["improve"]["status"] == "quiet day" and run["steps"]["track"]["status"] == "quiet day", run["steps"]
card = run["charter_card"]
assert len(card) == 1 and card[0]["state"] == "card raised" and "cadia: name the kernel repo" in card[0]["what"], card
assert "Captain card %s for the charter edits (card raised)." % card[0]["key"] in run["summary"], run["summary"]
PY
  pass "improve: a change already open is not filed again, and a quiet night still cards its charter proposals"
}

test_an_unavailable_improve_model_is_named_and_never_replaced() {
  local d log
  d=$(new_case improve-down)
  seed_improve "$d"
  STUB_REFLECT=down run_dream "$d" --only collect improve track > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  python3 - "$log" "$d/calls" <<'PY' || fail "unavailable model handled wrong: $(jq -c '.steps, .summary' "$log")"
import glob, json, sys
run = json.load(open(sys.argv[1]))
st = run["steps"]["improve"]
assert st["status"] == "partial", st
note = "claude/opus-5-5 unavailable: selected account has no project-owned enrollment; no other model was tried"
assert note in st["why"] and "Nothing changed tonight: " + note in run["summary"], (st, run["summary"])
assert run["improve"]["metrics"]["tasks"] == 1 and run["improve"]["changes"] == [], run["improve"]
assert [json.load(open(c))["model"] for c in glob.glob(sys.argv[2] + "/reflect.*")] == ["claude/opus-5-5"]
assert run["steps"]["track"]["status"] == "done", run["steps"]["track"]
PY
  pass "improve: an unavailable Opus is named in the report, the measurements still land, and no other model is tried"
}

test_the_improve_model_comes_from_config_and_a_bad_one_stops_the_run() {
  local d
  d=$(new_case improve-config)
  seed_improve "$d"
  printf '{"exclude_homes": ["finn-finance"], "model": "stub/model", "improve": {"model": "claude/opus-9"}}\n' > "$d/home/config/dream.json"
  STUB_REFLECT=ok run_dream "$d" --only collect improve > "$d/out.json" || fail "run exited nonzero"
  [ "$(jq -r .model "$d"/calls/reflect.0)" = claude/opus-9 ] || fail "the configured improve model was not used"
  printf '{"improve": {"model": 5}}\n' > "$d/home/config/dream.json"
  if run_dream "$d" --only improve > "$d/out2.json" 2> "$d/err"; then fail "a malformed improve model did not stop the run"; fi
  grep -q 'improve must be an object whose model is a string' "$d/err" || fail "the refusal is unclear: $(cat "$d/err")"
  pass "improve: config/dream.json pins the model, and a malformed one stops the run"
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
    { git -C "$tree" add -A && git -C "$tree" commit -qm "proposal $day"; } || fail "could not seed proposal"
  done
  git -C "$d/firstmate" merge -q --no-edit fm/dream-instructions-2026-10-01 || fail "could not seed ancestor merge"
  { git -C "$d/firstmate" merge -q --squash fm/dream-instructions-2026-10-02 \
    && git -C "$d/firstmate" commit -qm 'squash proposal' \
    && git -C "$d/firstmate" push -q origin HEAD:main; } || fail "could not seed squash merge"
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
      { git -C "$d/firstmate" add -A && git -C "$d/firstmate" commit -qm 'add safety rule' \
        && git -C "$d/firstmate" push -q origin HEAD:main; } || fail "could not seed safety rule"
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

test_an_interrupted_night_stops_the_gate_and_keeps_the_pr() {
  local d pid waited=0 log
  d=$(new_case instr-interrupted)
  STUB_INSTR=edit STUB_NM=slow run_dream "$d" --only collect instructions > "$d/out.json" &
  pid=$!
  while [ ! -e "$d/calls/nm-first" ] || [ "$(grep -c '|axi run' "$d/calls/nm" 2>/dev/null)" -lt 2 ]; do
    sleep 0.2; waited=$((waited + 1)); [ "$waited" -lt 300 ] || { kill "$pid"; fail "the gate never reattached"; }
  done
  # run_dream is a shell function: signal the dreaming process itself, as launchd would.
  pkill -TERM -f "fm_dream.py run --home $d/home" || fail "no dreaming process to signal"
  wait "$pid" 2>/dev/null
  log=$(ls "$d"/home/state/dream/runs/*.json)
  python3 - "$log" <<'PY' || fail "an interrupted night lost the gate state: $(jq -c '.steps.instructions, .instructions' "$log")"
import json, sys
run = json.load(open(sys.argv[1]))
st, ins = run["steps"]["instructions"], run["instructions"]
assert st["status"] == "interrupted" and "stopping the gate run was confirmed" in st["why"], st
assert ins["pr"].endswith("/pull/991") and ins["proposed_lines"] == 1 and ins["risk"] == "Low", ins
PY
  grep -q '|axi abort' "$d/calls/nm" || fail "the gate run was not stopped"
  pass "instructions: an interrupted night stops the gate run and still reports the PR"
}

test_improve_rejects_missing_repositories_before_filing() {
  local d log
  d=$(new_case improve-missing-repos)
  seed_improve "$d"
  STUB_REFLECT=bad-repos run_dream "$d" --only collect improve file track > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  python3 - "$log" "$d/calls" <<'PY' || fail "a projectless change was dispatched"
import glob, json, sys
run = json.load(open(sys.argv[1]))
assert run['steps']['improve']['changes'] == 2 and run['steps']['improve']['dropped'] == 3, run['steps']
assert [c['repo'] for c in run['improve']['changes']] == ['phone-harness', 'deck'], run['improve']
adds = [open(p).read() for p in glob.glob(sys.argv[2] + '/add.*')]
assert len(adds) == 2 and not any('Reject a projectless fix' in a for a in adds), adds
assert any('--repo phone-harness' in a for a in adds) and any('--repo deck' in a for a in adds), adds
assert all(a['state'].startswith('dispatch ordered') for a in run['improve']['tonight']), run['improve']
PY
  pass "improve: missing, null and empty repositories are dropped while explicit keys and slugs still dispatch"
}

test_measurement_failure_preserves_independent_actions() {
  local d log
  d=$(new_case improve-unread-actions)
  printf 'not a sqlite database\n' > "$d/nm.sqlite"
  mkdir -p "$d/home/state/autoland"
  printf '%s autoland: merged https://github.com/bastotec/firstmate/pull/990 (deploy follows)\n%s autoland: deployed firstmate abcdef0: homes at abcdef0\n' \
    "$(iso $((NOW - 100)))" "$(iso $((NOW - 50)))" > "$d/home/state/autoland/report.log"
  STUB_INSTR=edit STUB_NO_TRIAGE=1 STUB_SKILLS=none run_dream "$d" > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  python3 - "$log" "$d/home/state/dream" <<'PY' || fail "measurement failure lost successful actions: $(cat "$log")"
import json, pathlib, sys
run = json.load(open(sys.argv[1]))
root = pathlib.Path(sys.argv[2])
assert run['status'] == 'partial' and run['steps']['improve']['status'] == 'partial', run['steps']
assert run['steps']['track']['status'] == 'partial' and run['steps']['track']['acted'] == 2, run['steps']
assert 'no-mistakes state' in run['steps']['track']['why'], run['steps']['track']
life = run['improve']
assert life['changes'] == [] and life['measurement_error'], life
instructions, card = life['tonight']
assert instructions['kind'] == 'instructions' and instructions['state'] == 'merged and deployed', instructions
assert instructions['pr'].endswith('/pull/990'), instructions
assert card['kind'] == 'captain' and card['state'] == 'card raised' and card['key'], card
rows = [json.loads(l) for l in (root / 'improve-actions.jsonl').read_text().splitlines()]
assert rows == [dict(a, date=run['date']) for a in life['tonight']], rows
assert not (root / 'improve.jsonl').exists(), 'failed measurements were persisted as metrics'
summary = run['summary']
assert 'Improve: measurement incomplete:' in summary and '. Tonight: AGENTS.md:' in summary, summary
assert instructions['pr'] + ', merged and deployed' in summary and 'captain card ' + card['key'] in summary, summary
PY
  [ ! -e "$d/calls/reflect.0" ] || fail "failed measurements called the reflection model"
  pass "improve: failed measurements stay partial but independent PRs and cards are tracked, recorded and summarized"
}

test_last_night_requires_evidence_before_resolving_failed_cards() {
  local d log
  d=$(new_case improve-failed-cards)
  seed_improve "$d"
  printf '%s\n' \
    '{"date":"2026-10-01","kind":"captain","what":"queued after failure","key":"cap-queued","state":"card not raised: TimeoutExpired"}' \
    '{"date":"2026-10-01","kind":"captain","what":"held later","key":"cap-held","state":"card not raised"}' \
    '{"date":"2026-10-01","kind":"captain","what":"completed later","key":"cap-done","state":"card not raised"}' \
    '{"date":"2026-10-01","kind":"captain","what":"confirmed card","key":"cap-confirmed","state":"card raised"}' \
    > "$d/home/state/dream/improve-actions.jsonl"
  cat > "$d/bin/report" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '{"summary":"fleet ok","gaps":[],"crew":[],"power":[],
 "mates":[{"id":"primary","name":"first mate","freshness":"local","state":"idle"}],
 "waiting":[{"task":"cap-held","mate":"primary"}],"shipped":[{"task":"cap-done","mate":"primary"}]}'
SH
  STUB_REFLECT=none run_dream "$d" --only collect improve > "$d/out.json" || fail "run exited nonzero"
  log=$(ls "$d"/home/state/dream/runs/*.json)
  jq -e '[.improve.last_night[].now_state] == ["card not raised: TimeoutExpired", "waiting on the captain", "answered or closed", "answered or closed"]
    and (.summary | contains("queued after failure (card not raised: TimeoutExpired)"))' "$log" >/dev/null \
    || fail "a failed card was assumed answered: $(cat "$log")"
  pass "improve: failed cards stay unresolved until a hold or completion is observed"
}

test_deployment_polls_cache_confirmed_comparisons_only() {
  local d
  d=$(new_case improve-compare-cache)
  python3 - "$d/home" "$ROOT/bin" <<'PY' || fail "deployment comparisons were repeated or unread results were cached"
import collections, json, subprocess, sys
sys.path.insert(0, sys.argv[2])
import fm_dream as dream

class Context(dream.Ctx):
    def run(self, argv, **kw):
        self.calls[tuple(argv)] += 1
        if argv[1:3] == ['pr', 'view']:
            body = {'state': 'MERGED', 'mergedAt': '2026-10-14T17:30:00Z', 'mergeCommit': {'oid': self.merge}}
        else:
            count = self.calls[tuple(argv)]
            sha = argv[-1].split('...')[-1]
            if sha == '4444444' and count == 1:
                return subprocess.CompletedProcess(argv, 1, '', 'unread')
            if sha == '4444444' and count == 2:
                return subprocess.CompletedProcess(argv, 0, '{', '')
            body = {'status': {'1111111': 'behind', '3333333': 'diverged', '4444444': 'behind', '2222222': 'ahead'}[sha]}
        return subprocess.CompletedProcess(argv, 0, json.dumps(body), '')

ctx = Context(sys.argv[1], False)
ctx.calls = collections.Counter()
ctx.merge = 'abcdef0000000000000000000000000000000000'
pr = 'https://github.com/o/firstmate/pull/1'
deps = {pr: [{'at': 1792000000, 'sha': sha} for sha in ('1111111', '3333333', '4444444')]}
for _ in range(4):
    assert dream.pr_state(ctx, pr, deps) == 'merged, deploy pending'
api = lambda: {argv[-1]: count for argv, count in ctx.calls.items() if argv[1] == 'api'}
assert sorted(api().values()) == [1, 1, 3], api()
assert sum(count for argv, count in ctx.calls.items() if argv[1] == 'pr') == 1, ctx.calls
deps[pr].append({'at': 1792000010, 'sha': '2222222'})
assert dream.pr_state(ctx, pr, deps) == 'merged and deployed'
assert dream.pr_state(ctx, pr, deps) == 'merged and deployed'
assert sorted(api().values()) == [1, 1, 1, 3], api()
other = 'https://github.com/o/other/pull/1'
assert dream.pr_state(ctx, other, {other: deps[pr][:1]}) == 'merged, deploy pending'
ctx.merge = 'fedcba0000000000000000000000000000000000'
next_pr = 'https://github.com/o/firstmate/pull/2'
assert dream.pr_state(ctx, next_pr, {next_pr: deps[pr][:1]}) == 'merged, deploy pending'
assert len(api()) == 6 and sorted(api().values()) == [1, 1, 1, 1, 1, 3], api()
PY
  pass "improve: polling caches confirmed commit comparisons per repository and pair, retries unread results and checks new deployments"
}

test_improve_rejects_missing_repositories_before_filing
test_measurement_failure_preserves_independent_actions
test_last_night_requires_evidence_before_resolving_failed_cards
test_deployment_polls_cache_confirmed_comparisons_only
test_last_night_keeps_unread_homes_unresolved
test_every_unshipped_instruction_reaches_the_summary
test_failed_empty_measurements_are_not_quiet_days
test_card_timeouts_keep_filings_and_allow_triage
test_answered_calls_are_not_raised_and_repeats_join_the_open_card
test_decided_context_keeps_complete_public_entries_only
test_track_rejects_a_predecessor_deployment
test_collect_builds_a_private_digest_of_the_day
test_each_relaunch_is_counted_once
test_an_interrupted_night_stops_the_gate_and_keeps_the_pr
test_improve_acts_on_every_kind_of_change
test_improve_reports_last_night_s_changes_and_their_targets
test_improve_files_no_duplicate_and_cards_charters_on_a_quiet_night
test_an_unavailable_improve_model_is_named_and_never_replaced
test_the_improve_model_comes_from_config_and_a_bad_one_stops_the_run
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
