#!/usr/bin/env bash
# Live driver: exercises the real fm-spawn.sh CLI to show the accepted-backend
# list, the secondmate axis, and the auto-detection axis that
# docs/configuration.md "Runtime backend" now claims sole ownership of.
ROOT=/home/bruno/.no-mistakes/worktrees/0311921e9ccd/01M2RRQ4XZTHNXWZCE6Q52AKH5
TMP=$(mktemp -d)
base_env=(FM_ROOT_OVERRIDE='' FM_HOME='' FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE=''
          FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE="$TMP/config" FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1)
mkdir -p "$TMP/config"

run() { # <label> <env-assignments...> -- <args...>
  local label=$1; shift
  local -a envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done; shift
  echo "### $label"
  echo "\$ ${envs[*]} fm-spawn.sh $*"
  local out
  out=$(env "${base_env[@]}" "${envs[@]}" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1)
  local rc=$?
  printf '%s\n' "$out" | head -4
  echo "[exit $rc]"
  echo
}

echo "===== A. accepted backend list: ship spawn (--backend <name>) ====="
for b in tmux herdr zellij orca cmux stream codex-app bogus; do
  run "ship spawn on backend=$b" -- "axes-$b-1" projects/none claude --mode no-mistakes --yolo off --backend "$b"
done

echo "===== B. secondmate axis (--secondmate) ====="
for b in tmux herdr zellij orca cmux stream; do
  run "secondmate spawn on backend=$b" -- "axes-sm-$b" projects/none claude --backend "$b" --secondmate
done

echo "===== C. selection / auto-detection axis ====="
run "FM_BACKEND=bogus (env override validated)" FM_BACKEND=bogus -- axes-env-1 projects/none claude --mode no-mistakes --yolo off
printf 'zellij\n' > "$TMP/config/backend"
run "config/backend=zellij (explicit file selection)" -- axes-cfg-1 projects/none claude --mode no-mistakes --yolo off
printf 'codex-app\n' > "$TMP/config/backend"
run "config/backend=codex-app (rejected)" -- axes-cfg-2 projects/none claude --mode no-mistakes --yolo off
rm -f "$TMP/config/backend"
run "ambient HERDR_ENV=1, nothing configured (auto-detect)" HERDR_ENV=1 -- axes-auto-herdr projects/none claude --mode no-mistakes --yolo off
run "ambient CMUX_WORKSPACE_ID, nothing configured (auto-detect)" CMUX_WORKSPACE_ID=ws-1 -- axes-auto-cmux projects/none claude --mode no-mistakes --yolo off
run "ambient TMUX, nothing configured (auto-detect, silent)" TMUX=fake,1,0 -- axes-auto-tmux projects/none claude --mode no-mistakes --yolo off
run "no ambient signal at all (default tmux)" -- axes-auto-default projects/none claude --mode no-mistakes --yolo off
rm -rf "$TMP"
