#!/usr/bin/env bash
# Live rig for fm-control.sh recover-missing: REAL tmux server on a private
# socket, real git worktrees, real fm-control/fm-spawn. The only stand-in is
# the `claude` CLI itself (an external vendor binary), replaced by a process
# that holds the pane the way a real agent does.
set -u
ROOT=${ROOT:-/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M2HFXB6C7GYHE20VGXWHN7KH}
RIG=${RIG:-/tmp/fm-recover-live/run}
REAL_TMUX=$(command -v tmux)
SOCKET=${SOCKET:-fm-recover-live}

rig_reset() {
  "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true
  rm -rf "$RIG"
  mkdir -p "$RIG/bin" "$RIG/home/state" "$RIG/home/data" "$RIG/user-home" "$RIG/tmp"
  cat > "$RIG/bin/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
  chmod +x "$RIG/bin/tmux"
  cat > "$RIG/bin/claude" <<'SH'
#!/usr/bin/env bash
# stand-in for the vendor `claude` CLI: holds the pane as a live agent process
printf 'claude stand-in up in %s\n' "$PWD"
printf '%s\n' "$*" >> "${FM_RIG_CLAUDE_LOG:-/dev/null}"
# Hold the pane as a process whose argv[0] is `claude`, which is how the real
# vendor CLI presents itself to the liveness probe.
exec -a claude /bin/sleep 86400
SH
  chmod +x "$RIG/bin/claude"
  printf '%s\n' "${RC_SLEEP:-2}" > "$RIG/rc-sleep"
  cat > "$RIG/user-home/.zshrc" <<'SH'
# A heavy login shell: rc-file work that owns the pane tty while it runs,
# exactly what makes a freshly created terminal read `ambiguous` at first.
command sleep "$(cat "$FM_RIG_HOME/rc-sleep" 2>/dev/null || echo 0)"
if [ -n "${FM_RIG_HEAVY_RC:-}" ]; then
  # What a real developer rc does on every new terminal: a version manager's
  # node, a git call for the prompt, each owning the pane tty in turn.
  command -v node >/dev/null 2>&1 && node -e 'const t=Date.now()+1500;while(Date.now()<t);'
  command git -C "$FM_RIG_HOME" status >/dev/null 2>&1
  command sleep 1
fi
SH
  cat > "$RIG/user-home/.zshenv" <<SH
export FM_RIG_HOME="$RIG"
export FM_RIG_HEAVY_RC="${FM_RIG_HEAVY_RC:-}"
export PATH="$RIG/bin:\$PATH"
SH
}

rig_task() {  # <id> <session> [worktree]
  local id=$1 ses=$2 wt=${3:-$RIG/wt-$1} proj="$RIG/proj-$1"
  ( set -e
    git init --quiet "$proj"
    cd "$proj"
    git config user.email t@example.com; git config user.name T
    echo hello > README.md; git add README.md; git commit --quiet -m init
    git worktree add --quiet -b "task-$id" "$wt"
  ) >/dev/null || return 1
  mkdir -p "$RIG/home/data/$id"
  cat > "$RIG/home/data/$id/brief.md" <<EOF
# Task
## Captain's intent
Exercise missing-endpoint recovery for $id against a real tmux server.

## Firstmate spec
Recreate the terminal without touching the local copy.
EOF
  {
    echo "window=$ses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=ship"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=$RIG/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
  } > "$RIG/home/state/$id.meta"
}

rig_env() {
  env -u NO_MISTAKES_GATE -u FM_NO_MISTAKES_GATE PATH="$RIG/bin:$PATH" \
      HOME="$RIG/user-home" SHELL=/bin/zsh \
      FM_HOME="$RIG/home" FM_RIG_HOME="$RIG" \
      CLAUDE_CONFIG_DIR='' FM_SPAWN_NO_GUARD=1 \
      FM_RIG_CLAUDE_LOG="$RIG/claude-args.log" \
      "$@"
}

rig_tmux() { rig_env "$RIG/bin/tmux" "$@"; }

rig_control() { rig_env "$ROOT/bin/fm-control.sh" "$@"; }
