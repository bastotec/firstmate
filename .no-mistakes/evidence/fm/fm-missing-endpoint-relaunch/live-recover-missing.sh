#!/usr/bin/env bash
# Live end-to-end drive of `fm-control.sh <id> recover-missing` against a REAL
# tmux server on a private socket. Nothing here stubs tmux: the terminal that
# goes missing, the one that comes back, and the agent process the replacement
# runs are all real. The only stand-in is the harness binary itself - a `claude`
# on PATH that holds the pane the way the real CLI does.
set -u

ROOT=/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M2JBRFTMVJQHAWBSAD5VSQCH
REAL_TMUX=/opt/homebrew/bin/tmux
SOCK="fm-live-recover-$$"
W=$(mktemp -d "${TMPDIR:-/tmp}/fm-live-recover.XXXXXX")
SESSION=fmlive

cleanup() {
  "$REAL_TMUX" -L "$SOCK" kill-server >/dev/null 2>&1 || true
  rm -rf "$W" /tmp/fm-live-* 2>/dev/null || true
}
trap cleanup EXIT

say() { printf '\n=== %s ===\n' "$*"; }

mkdir -p "$W/fakebin" "$W/home/state" "$W/home/data" "$W/user-home"

# tmux shim: every bare `tmux` the product runs lands on the private socket.
cat > "$W/fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCK" "\$@"
SH
chmod +x "$W/fakebin/tmux"

# The harness stand-in. Rewrites argv[0] so the pane's foreground process is
# named `claude`, which is exactly what the tmux liveness probe reads.
cat > "$W/fakebin/claude" <<'SH'
#!/bin/bash
printf '%s\n' "$@" > "${FM_LIVE_ARGS_FILE:-/dev/null}"
exec -a claude /bin/sleep 3600
SH
chmod +x "$W/fakebin/claude"

export PATH="$W/fakebin:$PATH"
export FM_LIVE_ARGS_FILE="$W/claude-args"

settle() {  # wait for the recreated pane to hold the replacement agent
  local i=0
  while [ "$i" -lt 60 ]; do
    case "$(tmux display-message -p -t "$SESSION:fm-$ID" '#{pane_current_command}' 2>/dev/null)" in
      sleep|claude) return 0 ;;
    esac
    sleep 0.5; i=$((i + 1))
  done
  return 1
}

fm() {  # run the real control plane the way an operator does
  env FM_HOME="$W/home" HOME="$W/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_LIVE_ARGS_FILE="$W/claude-args" \
    FM_GATE_REFUSE_BYPASS=1 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}

# --- a real project, a real local copy, a real durable record ----------------
ID=${1:-live1}
PROJ="$W/proj"; WT="$W/wt"
mkdir -p "$PROJ"
git -c init.defaultBranch=main init -q "$PROJ"
printf 'hello\n' > "$PROJ/README.md"
git -C "$PROJ" -c user.name=fm -c user.email=fm@example.com add -A
git -C "$PROJ" -c user.name=fm -c user.email=fm@example.com commit -qm init
git -C "$PROJ" worktree add --quiet -b "task-$ID" "$WT"

mkdir -p "$W/home/data/$ID"
cat > "$W/home/data/$ID/brief.md" <<EOF
# Task
## Captain's intent
Continue the parked validation run for $ID.

## Firstmate spec
Recreate the terminal without touching the local copy.
EOF
cat > "$W/home/state/$ID.meta" <<EOF
window=$SESSION:fm-$ID
endpoint_task_id=$ID
worktree=$WT
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-live-$ID
model=default
effort=default
EOF

# A steering message already waiting in the inbox: the rescue must preserve it.
mkdir -p "$W/home/state/$ID.inbox"
printf 'Steer: finish the parked run, do not restart it.\n' > "$W/home/state/$ID.inbox/016.msg"
INBOX_BEFORE=$(cd "$W/home/state/$ID.inbox" && ls)
BRIEF_SHA_BEFORE=$(shasum "$W/home/data/$ID/brief.md" | cut -d' ' -f1)
HEAD_BEFORE=$(git -C "$WT" rev-parse HEAD)

# --- stand the task up for real: session, window, running agent --------------
env HOME="$W/user-home" tmux new-session -d -s "$SESSION" -x 200 -y 50
tmux new-window -t "$SESSION:" -n "fm-$ID" -c "$WT"
tmux set-window-option -t "$SESSION:fm-$ID" automatic-rename off >/dev/null
for _ in $(seq 1 40); do
  [ "$(tmux display-message -p -t "$SESSION:fm-$ID" '#{pane_current_command}')" = zsh ] && break
  sleep 0.25
done
sleep 1
tmux send-keys -t "$SESSION:fm-$ID" -l "$W/fakebin/claude --live-original"
tmux send-keys -t "$SESSION:fm-$ID" Enter
for _ in $(seq 1 40); do
  [ "$(tmux display-message -p -t "$SESSION:fm-$ID" '#{pane_current_command}')" = claude ] && break
  sleep 0.25
done

say "S0 baseline: the task's terminal exists and holds a live agent"
tmux list-windows -t "$SESSION" -F '#{window_name}'
echo "pane command: $(tmux display-message -p -t "$SESSION:fm-$ID" '#{pane_current_command}')"

say "S1 adversarial: recover-missing against that LIVE endpoint must refuse"
fm "$ID" recover-missing --note "trying to recover a task that is not missing"
echo "exit=$?"
echo "meta unchanged: $(grep -c . "$W/home/state/$ID.meta") lines, window=$(grep '^window=' "$W/home/state/$ID.meta")"

say "S2 the motivating shape: the task's WINDOW is gone from a live session"
tmux kill-window -t "$SESSION:fm-$ID"
sleep 1
echo "windows now: $(tmux list-windows -t "$SESSION" -F '#{window_name}' | tr '\n' ' ')"
echo "--- operator runs the rescue ---"
fm "$ID" recover-missing --note "Terminal disappeared; the parked validation run is unfinished. Read the inbox first."
echo "exit=$?"
settle || echo "(pane never settled)"
say "S2 result: the terminal is back under its recorded name, with an agent in it"
tmux list-windows -t "$SESSION" -F '#{window_name}'
echo "pane command: $(tmux display-message -p -t "$SESSION:fm-$ID" '#{pane_current_command}')"
echo "pane cwd:     $(tmux display-message -p -t "$SESSION:fm-$ID" '#{pane_current_path}')"
echo "recorded wt:  $WT"
echo "inbox before: $INBOX_BEFORE"
echo "inbox after:  $(cd "$W/home/state/$ID.inbox" && ls)"
echo "worktree HEAD before: $HEAD_BEFORE"
echo "worktree HEAD after:  $(git -C "$WT" rev-parse HEAD)"
echo "brief sha before: $BRIEF_SHA_BEFORE"
echo "brief sha after:  $(shasum "$W/home/data/$ID/brief.md" | cut -d' ' -f1)"
echo "--- the progress note the replacement now reads (tail of its instructions) ---"
tail -12 "$W/home/data/$ID/brief.md"
echo "--- the replacement really received the brief (argv of the launched agent) ---"
sed -n '1,20p' "$W/claude-args" | cut -c1-160
echo "--- what an operator sees in the recreated terminal (tmux capture-pane) ---"
tmux capture-pane -p -t "$SESSION:fm-$ID" | grep -v '^$' | tail -6 | cut -c1-160

say "S3 the second shape: the WHOLE recorded session is gone"
tmux kill-session -t "$SESSION"
sleep 1
tmux has-session -t "=$SESSION" 2>&1 || echo "(session is gone, as reported by real tmux)"
echo "--- operator runs the same rescue ---"
fm "$ID" recover-missing --note "The whole tmux session vanished. Resume the same parked run."
echo "exit=$?"
settle || echo "(pane never settled)"
say "S3 result: the session and the window are both back"
tmux list-sessions -F '#{session_name}'
tmux list-windows -t "$SESSION" -F '#{window_name}'
echo "pane command: $(tmux display-message -p -t "$SESSION:fm-$ID" '#{pane_current_command}')"
echo "inbox after:  $(cd "$W/home/state/$ID.inbox" && ls)"
echo "worktree HEAD after: $(git -C "$WT" rev-parse HEAD)"

say "S4 adversarial: a dirty local copy must refuse rather than clean it"
tmux kill-window -t "$SESSION:fm-$ID"
sleep 1
printf 'unpublished work\n' > "$WT/unpublished.txt"
git -C "$WT" add unpublished.txt
fm "$ID" recover-missing --note "should refuse"
echo "exit=$?"
echo "windows after refusal: $(tmux list-windows -t "$SESSION" -F '#{window_name}' | tr '\n' ' ')"
echo "dirt still present: $(git -C "$WT" status --porcelain)"
git -C "$WT" reset -q && rm -f "$WT/unpublished.txt"

say "S5 adversarial: an absent local copy must refuse rather than reallocating one"
mv "$WT" "$W/wt-moved"
fm "$ID" recover-missing --note "should refuse"
echo "exit=$?"
echo "windows after refusal: $(tmux list-windows -t "$SESSION" -F '#{window_name}' | tr '\n' ' ')"
mv "$W/wt-moved" "$WT"

say "S6 adversarial: runtime-switch flags belong to relaunch, not here"
fm "$ID" recover-missing --harness codex --note "should refuse"
echo "exit=$?"

say "S7 final: after the refusals, the rescue still works (idempotent retry)"
fm "$ID" recover-missing --note "Retry after the refusals were corrected."
echo "exit=$?"
settle || echo "(pane never settled)"
tmux list-windows -t "$SESSION" -F '#{window_name}'
echo "pane command: $(tmux display-message -p -t "$SESSION:fm-$ID" '#{pane_current_command}')"
echo "worktree HEAD unchanged: $(git -C "$WT" rev-parse HEAD) (was $HEAD_BEFORE)"
echo "inbox intact: $(cd "$W/home/state/$ID.inbox" && ls)"
