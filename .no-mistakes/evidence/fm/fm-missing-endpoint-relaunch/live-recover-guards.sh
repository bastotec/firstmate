#!/usr/bin/env bash
# Live drive of the two guards the captain named that the main transcript does
# not cover: a Treehouse pool slot reassigned to another task, and a secondmate
# whose configured runtime pin differs from its recorded one. Real tmux, real
# fm-control.sh, private socket.
set -u

ROOT=/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M2JBRFTMVJQHAWBSAD5VSQCH
REAL_TMUX=/opt/homebrew/bin/tmux
SOCK="fm-live-guards-$$"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-guards.XXXXXX")
SESSION=fmguard

cleanup() { "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true; rm -rf "$W"; }
trap cleanup EXIT
say() { printf '\n=== %s ===\n' "$*"; }

mkdir -p "$W/fakebin" "$W/home/state" "$W/home/data" "$W/home/config" "$W/user-home"
cat > "$W/fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
chmod +x "$W/fakebin/tmux"
cat > "$W/fakebin/claude" <<'SH'
#!/bin/bash
exec -a claude /bin/sleep 3600
SH
chmod +x "$W/fakebin/claude"
# The configured pin names a DIFFERENT runtime; a recovery must not follow it.
cat > "$W/fakebin/codex" <<'SH'
#!/bin/bash
exec -a codex /bin/sleep 3600
SH
chmod +x "$W/fakebin/codex"
export PATH="$W/fakebin:$PATH"

fm() {
  env FM_HOME="$W/home" HOME="$W/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

git_commit_all() { git -C "$1" add -A && git -C "$1" -c user.name=fm -c user.email=fm@example.com commit -qm "$2"; }

env HOME="$W/user-home" tmux new-session -d -s "$SESSION" -x 200 -y 50
sleep 1

# --- G1: a pool slot now claimed by another task -----------------------------
POOL="$W/pool"; mkdir -p "$POOL/1"
printf '{}\n' > "$POOL/treehouse-state.json"
PROJ="$W/proj"; git -c init.defaultBranch=main init -q "$PROJ"
printf 'x\n' > "$PROJ/README.md"; git_commit_all "$PROJ" init
SLOTWT="$POOL/1/checkout"
git -C "$PROJ" worktree add --quiet -b task-g1 "$SLOTWT"
mkdir -p "$W/home/data/g1"
cat > "$W/home/data/g1/brief.md" <<'B'
# Task
## Captain's intent
Finish the parked validation run in this pool slot.

## Firstmate spec
Recreate the terminal without touching the slot.
B
cat > "$W/home/state/g1.meta" <<EOF
window=$SESSION:fm-g1
endpoint_task_id=g1
worktree=$SLOTWT
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
model=default
effort=default
EOF
printf 'task=%s\nhome=%s\n' other-task "$W/home" > "$POOL/1/.fm-slot-owner"
META_BEFORE=$(cat "$W/home/state/g1.meta")

say "G1 the recorded endpoint really is missing on this live tmux server"
tmux list-windows -t "$SESSION" -F '#{window_name}' | tr '\n' ' '; echo
say "G1 recover-missing must refuse a slot another task now claims"
fm g1 recover-missing --note "should refuse"
echo "exit=$?"
echo "slot claim untouched: $(tr '\n' ' ' < "$POOL/1/.fm-slot-owner")"
echo "no window created:    $(tmux list-windows -t "$SESSION" -F '#{window_name}' | tr '\n' ' ')"
[ "$META_BEFORE" = "$(cat "$W/home/state/g1.meta")" ] && echo "durable record byte-identical: yes"

say "G1b the SAME task's own claim recovers instead of refusing"
printf 'task=%s\nhome=%s\n' g1 "$W/home" > "$POOL/1/.fm-slot-owner"
fm g1 recover-missing --note "the terminal vanished; continue the run"
echo "exit=$?"
echo "window now:        $(tmux list-windows -t "$SESSION" -F '#{window_name}' | tr '\n' ' ')"
echo "slot claim still:  $(tr '\n' ' ' < "$POOL/1/.fm-slot-owner")"
echo "worktree still:    $(grep '^worktree=' "$W/home/state/g1.meta")"

# --- G2: a secondmate whose configured pin differs from its record -----------
printf 'codex some-model high\n' > "$W/home/config/secondmate-harness"
SMHOME="$W/smhome"
git -C "$PROJ" worktree add --quiet -b sm-branch "$SMHOME"
mkdir -p "$SMHOME/state" "$SMHOME/data" "$SMHOME/bin" "$W/home/data/g2"
printf 'g2\n' > "$SMHOME/.fm-secondmate-home"
printf '# agents\n' > "$SMHOME/AGENTS.md"
printf '# secondmate brief\n' > "$W/home/data/g2/brief.md"
git_commit_all "$SMHOME" "secondmate home"
cat > "$W/home/state/g2.meta" <<EOF
window=$SESSION:fm-g2
endpoint_task_id=g2
worktree=$SMHOME
project=$SMHOME
harness=claude
kind=secondmate
mode=secondmate
yolo=off
model=opus
effort=xhigh
home=$SMHOME
EOF

say "G2 configured pin says codex; the record says claude/opus/xhigh"
cat "$W/home/config/secondmate-harness"
say "G2 recovery must continue the RECORDED runtime, not the pin"
fm g2 recover-missing
echo "exit=$?"
i=0; while [ $i -lt 40 ]; do
  c=$(tmux display-message -p -t "$SESSION:fm-g2" '#{pane_current_command}' 2>/dev/null)
  case "$c" in sleep) break ;; esac
  sleep 0.5; i=$((i+1))
done
echo "--- the process actually launched in the recreated terminal ---"
TTY=$(tmux display-message -p -t "$SESSION:fm-g2" '#{pane_tty}')
ps -t "${TTY#/dev/}" -o comm=,args= | sed -n '1,10p'
echo "--- the journal's recorded target runtime ---"
grep -E '^(to_harness|to_model|to_effort)=' "$W/home/state/g2.control-relaunch" | tail -3
