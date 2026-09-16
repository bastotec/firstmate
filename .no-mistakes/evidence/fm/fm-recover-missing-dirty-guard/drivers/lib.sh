# shared setup for the live recover-missing drive
set -u
ROOT=${FM_ROOT:?}
BIN=${FM_BIN:-$ROOT/bin}
REAL_TMUX=$(bash -lc 'command -v tmux')
LAB=$(mktemp -d "${TMPDIR:-/tmp}/fm-live.XXXXXX")
SOCKET="fmlive-$$-$RANDOM"

cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; }
trap cleanup EXIT

mkdir -p "$LAB/fakebin" "$LAB/user-home"
cat > "$LAB/fakebin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$LAB/fakebin/tmux"
# A stand-in for the Claude Code binary: a real compiled executable named
# `claude`, so the pane's foreground process classifies as a live agent exactly
# as the real one does, without launching a real agent in the test worktree.
cp /tmp/fm-live-drive/claude "$LAB/fakebin/claude"

GITC=(-c user.name='FM Live' -c user.email='live@example.invalid' -c init.defaultBranch=main -c commit.gpgsign=false)
TMUX=("$LAB/fakebin/tmux")

setup_task() {  # <id>
  local id=$1
  mkdir -p "$LAB/home/state" "$LAB/home/data/$id" "$LAB/proj"
  git "${GITC[@]}" init --quiet "$LAB/proj"
  printf '# project\noriginal line\n' > "$LAB/proj/README.md"
  printf 'echo hi\n' > "$LAB/proj/run.sh"
  git -C "$LAB/proj" "${GITC[@]}" add -A
  git -C "$LAB/proj" "${GITC[@]}" commit --quiet -m "seed"
  git -C "$LAB/proj" "${GITC[@]}" worktree add --quiet -b "task-$id" "$LAB/wt" >/dev/null
  cat > "$LAB/home/data/$id/brief.md" <<BRIEF
# Task
## Captain's intent
Rescue the worker whose terminal server died mid-task.

## Firstmate spec
Recreate the terminal without touching the local copy.
BRIEF
  {
    echo "window=fmlive:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$LAB/wt"
    echo "project=$LAB/proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-live-$id"
    echo "model=default"
    echo "effort=default"
  } > "$LAB/home/state/$id.meta"
}

# The real tmux session and window the task was originally launched into. The
# server is started with the lab's own HOME and PATH so panes resolve the
# stand-in `claude` and load no developer rc files.
start_endpoint() {  # <id>
  local id=$1
  env PATH="$LAB/fakebin:/usr/bin:/bin:/usr/sbin:/sbin" HOME="$LAB/user-home" \
    "${TMUX[@]}" new-session -d -s fmlive -n placeholder -x 200 -y 50
  "${TMUX[@]}" new-window -t fmlive -n "fm-$id" -c "$LAB/wt"
}

dirty_the_copy() {  # the mid-work state of the worker being rescued
  printf '# project\nthe worker was halfway through this line\n' > "$LAB/wt/README.md"
  printf 'work in progress\n' > "$LAB/wt/new-source.sh"
  printf 'staged change\n' > "$LAB/wt/staged.txt"
  git -C "$LAB/wt" add staged.txt
}

copy_fingerprint() { (cd "$LAB/wt" && git status --porcelain && git rev-parse HEAD && shasum README.md run.sh new-source.sh staged.txt 2>/dev/null); }

run_control() {  # <args...>
  env PATH="$LAB/fakebin:$PATH" FM_HOME="$LAB/home" HOME="$LAB/user-home" \
    CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 \
    FM_CONTROL_EXIT_WAIT=20 FM_CONTROL_LAUNCH_WAIT=25 \
    "$BIN/fm-control.sh" "$@" 2>&1
}
