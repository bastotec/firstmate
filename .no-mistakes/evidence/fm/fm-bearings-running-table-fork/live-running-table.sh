#!/usr/bin/env bash
# Live driver: real tmux server on an isolated socket, real fm-bearings-snapshot.sh.
# Usage: live-running-table.sh <repo-root> <evidence-dir>
set -u
ROOT=$1
EV=$2
. "$ROOT/tests/lib.sh"
W=$(mktemp -d /tmp/fm-live-running.XXXXXX)
W=$(cd "$W" && pwd -P)
export TMUX_TMPDIR="$W/tmux"
mkdir -p "$TMUX_TMPDIR"
chmod 700 "$TMUX_TMPDIR"
unset TMUX TMUX_PANE
TMUXBIN=/opt/homebrew/bin/tmux
export FM_ROOT_OVERRIDE="$ROOT"
cleanup() { "$TMUXBIN" kill-server 2>/dev/null; rm -rf "$W"; }
trap cleanup EXIT

# A harness-named process: a copy of sleep called "claude".
mkdir -p "$W/agentbin"
cp /bin/sleep "$W/agentbin/claude" && codesign -f -s - "$W/agentbin/claude" 2>/dev/null

home="$W/home"; mate="$W/mate-home"
mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects/wt" \
  "$mate/data" "$mate/state" "$mate/config" "$mate/projects/wt" "$mate/bin"
printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
printf 'helper\n' > "$mate/.fm-secondmate-home"
printf -- '- helper - live domain (home: %s; scope: live work; projects: firstmate; added 2026-09-17)\n' "$mate" > "$home/data/secondmates.md"
cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-ship - Ship the live thing (repo: firstmate) (kind: ship) (since 2026-09-17)
- [ ] idle-ship - Ship the shell-only thing (repo: firstmate) (kind: ship) (since 2026-09-17)
- [ ] gone-ship - Ship the closed thing (repo: firstmate) (kind: ship) (since 2026-09-17)

## Queued

## Done
EOF
arm() {  # <state> <id> <busy|idle>
  local g; g=$("$ROOT/bin/fm-busy-event.sh" arm "$1" "$2")
  "$ROOT/bin/fm-busy-event.sh" apply "$1" "$2" "$3" --gen "$g" --source claude-hook --event user-prompt-submit >/dev/null
}
for id in live-ship idle-ship gone-ship; do
  fm_write_meta "$home/state/$id.meta" "window=fleet:fm-$id" "worktree=$home/projects/wt" \
    "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes"
  arm "$home/state" "$id" busy
done
printf 'working: running the integration tests\n' > "$home/state/live-ship.status"
fm_write_meta "$home/state/helper.meta" "window=fleet:fm-helper" "worktree=$mate" \
  "project=$mate" "harness=claude" "kind=secondmate" "mode=secondmate" "home=$mate" "projects=firstmate"
cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] child-live - Child live work (repo: firstmate) (kind: ship) (since 2026-09-17)
- [ ] child-idle - Child shell-only work (repo: firstmate) (kind: ship) (since 2026-09-17)

## Queued

## Done
EOF
fm_write_meta "$mate/state/child-live.meta" "window=mfleet:fm-child-live" "worktree=$mate/projects/wt" \
  "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes"
fm_write_meta "$mate/state/child-idle.meta" "window=mfleet:fm-child-idle" "worktree=$mate/projects/wt" \
  "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes"
arm "$mate/state" child-live busy
arm "$mate/state" child-idle busy
printf 'working: validating its change before opening a PR\n' > "$mate/state/child-live.status"

# Real tmux: live agents run "claude"; idle panes are plain shells; gone-ship has no window.
"$TMUXBIN" -f /dev/null new-session -d -s fleet -n fm-live-ship "$W/agentbin/claude 900"
"$TMUXBIN" new-window -d -t fleet -n fm-idle-ship "/bin/sh"
"$TMUXBIN" new-window -d -t fleet -n fm-helper "$W/agentbin/claude 900"
"$TMUXBIN" new-session -d -s mfleet -n fm-child-live "$W/agentbin/claude 900"
"$TMUXBIN" new-window -d -t mfleet -n fm-child-idle "/bin/sh"
sleep 1
{ echo '$ tmux list-windows -a'; "$TMUXBIN" list-windows -a -F '#{session_name}:#{window_name} cmd=#{pane_current_command}'; } > "$EV/live-tmux-windows.txt"

refresh() { FM_HOME="$mate" "$ROOT/bin/fm-home-summary-refresh.sh" >/dev/null 2>&1 || echo "refresh failed" >&2; }
bearings() { FM_HOME="$home" "$ROOT/bin/fm-bearings-snapshot.sh" "$@"; }

echo "== S1: live fleet, JSON running[] =="
refresh
bearings --json > "$EV/live-s1-bearings.json"; echo "rc=$?"
jq '{running, omitted}' "$EV/live-s1-bearings.json"
echo "== S1: default TOON output =="
bearings > "$EV/live-s1-bearings.toon"; echo "rc=$?"
grep -A5 '^running' "$EV/live-s1-bearings.toon"

echo "== S2: stale ledger (now + 700s) =="
FM_SNAPSHOT_NOW_EPOCH=$(( $(date +%s) + 700 )) bearings --json > "$EV/live-s2-stale.json"; echo "rc=$?"
jq '{running:[.running[].id], omitted}' "$EV/live-s2-stale.json"

echo "== S3: kill live-ship agent (pane falls back to a shell) =="
"$TMUXBIN" respawn-pane -k -t fleet:fm-live-ship /bin/sh
sleep 1
refresh
bearings --json > "$EV/live-s3-killed.json"; echo "rc=$?"
jq '{running:[.running[].id], in_flight:[.in_flight[].id], omitted}' "$EV/live-s3-killed.json"

echo "== S4: endpoints bound hides a live child -> disclosed =="
FM_SNAPSHOT_SECONDMATE_CHILDREN=1 refresh
FM_SNAPSHOT_SECONDMATE_CHILDREN=1 bearings --json > "$EV/live-s4-bound.json"; echo "rc=$?"
jq '{running:[.running[].id], omitted}' "$EV/live-s4-bound.json"

echo "== S5: canonical snapshot default does not probe remote; local agent_state present =="
FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json | jq '[.tasks[] | {id, agent_state:.endpoint.agent_state}], [.secondmate_current.records[] | {id, agent_state}]'
