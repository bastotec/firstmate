#!/usr/bin/env bash
# Live drive of bin/fm-bearings-snapshot.sh against a real, isolated tmux server.
set -u
ROOT=${ROOT:?}
EV=${EV:?}
T=$(cd "$(mktemp -d /tmp/fm-bearings-live.XXXXXX)" && pwd -P)
export TMUX_TMPDIR="$T/tmuxdir"; mkdir -p "$TMUX_TMPDIR"
unset TMUX
mkdir -p "$T/agentbin"
printf '#include <unistd.h>\nint main(){for(;;)pause();}\n' > "$T/agent.c"
cc -o "$T/agentbin/claude" "$T/agent.c"   # a real process whose name is a verified harness
HOME_DIR="$T/main"; MATE="$T/helper-home"
mkdir -p "$HOME_DIR"/{state,data,projects/wt,config} "$MATE"/{data,state,config,projects/wt,bin}
printf '# Firstmate fixture\n' > "$MATE/AGENTS.md"; printf 'helper\n' > "$MATE/.fm-secondmate-home"
printf -- '- helper - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-09-17)\n' "$MATE" > "$HOME_DIR/data/secondmates.md"
cat > "$HOME_DIR/data/backlog.md" <<B
## In flight
- [ ] live-ship - Fix the login redirect (repo: firstmate) (kind: ship) (since 2026-09-17)
- [ ] idle-ship - Shell-only pane task (repo: firstmate) (kind: ship) (since 2026-09-17)
- [ ] gone-ship - Closed window task (repo: firstmate) (kind: ship) (since 2026-09-17)

## Queued

## Done
B
cat > "$MATE/data/backlog.md" <<B
## In flight
- [ ] child-live - Child live work (repo: firstmate) (kind: ship) (since 2026-09-17)
- [ ] child-idle - Child shell-only work (repo: firstmate) (kind: ship) (since 2026-09-17)

## Queued

## Done
B
meta() { f=$1; shift; : > "$f"; for kv in "$@"; do printf '%s\n' "$kv" >> "$f"; done; }
for id in live-ship idle-ship gone-ship; do
  meta "$HOME_DIR/state/$id.meta" "window=fleet:fm-$id" "worktree=$HOME_DIR/projects/wt" project=firstmate harness=claude kind=ship mode=no-mistakes
done
meta "$HOME_DIR/state/helper.meta" "window=fleet:fm-helper" "worktree=$MATE" "project=$MATE" harness=claude kind=secondmate mode=secondmate "home=$MATE" projects=firstmate
meta "$MATE/state/child-live.meta" "window=fleet:fm-child-live" "worktree=$MATE/projects/wt" project=firstmate harness=claude kind=ship mode=no-mistakes
meta "$MATE/state/child-idle.meta" "window=fleet:fm-child-idle" "worktree=$MATE/projects/wt" project=firstmate harness=claude kind=ship mode=no-mistakes
busy() { g=$("$ROOT/bin/fm-busy-event.sh" arm "$1" "$2"); "$ROOT/bin/fm-busy-event.sh" apply "$1" "$2" busy --gen "$g" --source claude-hook --event user-prompt-submit >/dev/null; }
for id in live-ship idle-ship gone-ship; do busy "$HOME_DIR/state" "$id"; done
busy "$MATE/state" child-live; busy "$MATE/state" child-idle

# Real tmux windows: live agents run "claude", idle ones are a bare shell, gone-ship has no window.
tmux new-session -d -s fleet -n fm-live-ship "$T/agentbin/claude"
tmux new-window -t fleet -n fm-idle-ship "/bin/zsh -f"
tmux new-window -t fleet -n fm-helper "$T/agentbin/claude"
tmux new-window -t fleet -n fm-child-live "$T/agentbin/claude"
tmux new-window -t fleet -n fm-child-idle "/bin/zsh -f"
# live-ship's meta names fm-live-ship window
sed -i '' "s/fm-live-ship\$/fm-live-ship/" "$HOME_DIR/state/live-ship.meta"
sleep 1
{ echo '$ tmux list-windows -t fleet -F "#{window_name} #{pane_current_command}"'; tmux list-windows -t fleet -F '#{window_name} #{pane_current_command}'; } > "$EV/01-tmux-windows.txt"

bearings() { FM_HOME="$HOME_DIR" FM_BEARINGS_NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ) "$ROOT/bin/fm-bearings-snapshot.sh" "$@"; }
refresh() { FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$MATE" "$ROOT/bin/fm-home-summary-refresh.sh" >>"$EV/refresh.log" 2>&1 || echo "refresh rc=$?" >>"$EV/refresh.log"; }

# S1: fresh ledger
refresh
{ echo '$ fm-bearings-snapshot.sh --json | jq "{running, omitted_running: [.omitted[]|select(.surface|test(\"running\"))], in_flight_ids: [.in_flight[].id]}"'
  bearings --json | jq '{running, omitted_running: [.omitted[]|select(.surface|test("running"))], in_flight_ids: [.in_flight[].id]}'; } > "$EV/02-running-fresh.json.txt" 2>&1
{ echo '$ fm-bearings-snapshot.sh   (default TOON output, running section)'; bearings | grep -A6 '^running'; echo; echo '$ fm-bearings-snapshot.sh --help | grep -i running'; bearings --help 2>&1 | grep -in 'running'; echo; echo '$ fm-bearings-snapshot.sh --all-running'; bearings --all-running >/dev/null 2>&1; echo "exit=$?"; } > "$EV/03-running-toon-help.txt" 2>&1

# S2: stale ledger (backdate generated_epoch by 700s > 2*300)
L="$MATE/state/home-summary.json"
jq '.generated_epoch -= 700' "$L" > "$L.tmp" && mv "$L.tmp" "$L"
touch -t 202001010000 "$L" 2>/dev/null
{ echo '# ledger generated_epoch backdated by 700s (limit 2 x 300 = 600s); watcher not refreshed'
  echo '$ fm-bearings-snapshot.sh --json | jq "{running_ids, omitted_running}"'
  bearings --json | jq '{running_ids:[.running[].id], omitted_running: [.omitted[]|select(.surface|test("running"))], helper_freshness:[.secondmates[]|{id,freshness,age_seconds}]}'
  echo; echo '$ FM_HOME_SUMMARY_INTERVAL=400 (limit 800s) same ledger'
  FM_HOME_SUMMARY_INTERVAL=400 bearings --json | jq '{running_ids:[.running[].id]}'
  echo; echo '$ FM_HOME_SUMMARY_INTERVAL=0 (invalid -> 300)'
  FM_HOME_SUMMARY_INTERVAL=0 bearings --json | jq '{running_ids:[.running[].id]}'
} > "$EV/04-running-stale-ledger.txt" 2>&1

# S3: kill the live main worker -> it drops out
refresh
tmux kill-window -t fleet:fm-live-ship
sleep 1
{ echo '# after tmux kill-window -t fleet:fm-live-ship'
  bearings --json | jq '{running_ids:[.running[].id], in_flight_ids:[.in_flight[].id]}'; } > "$EV/05-running-after-kill.txt" 2>&1

# S4: probe bound - stall the classifier
{ echo '# FM_SNAPSHOT_CREW_STATE_TIMEOUT=1 with a tmux shim that hangs 20s on list-windows'
  mkdir -p "$T/slowbin"; REAL=$(command -v tmux)
  printf '#!/bin/bash\ncase "$1" in list-windows) sleep 20;; esac\nexec %s "$@"\n' "$REAL" > "$T/slowbin/tmux"; chmod +x "$T/slowbin/tmux"
  s=$(date +%s)
  PATH="$T/slowbin:$PATH" FM_SNAPSHOT_CREW_STATE_TIMEOUT=1 FM_HOME="$HOME_DIR" "$ROOT/bin/fm-fleet-snapshot.sh" --json 2>/dev/null | jq -c '[.tasks[] | {id, agent_state:.endpoint.agent_state}]'
  echo "elapsed_seconds=$(( $(date +%s) - s ))"; } > "$EV/06-probe-timeout.txt" 2>&1

tmux kill-server 2>/dev/null
pkill -f "$T/agentbin/claude" 2>/dev/null
rm -rf "$T"
echo done
