#!/usr/bin/env bash
# Live driver 2: real fm-spawn.sh spawns against a sandbox fleet, to observe the
# RESOLVED backend and the worktree provider actually used.
set -u
ROOT=/home/bruno/.no-mistakes/worktrees/0311921e9ccd/01M2RRQ4XZTHNXWZCE6Q52AKH5
. "$ROOT/tests/fixtures.sh"
fm_git_identity fmtest fmtest@example.invalid
TMP_ROOT=$(fm_test_tmproot fm-axes-live)

spawn_case() { # <label> <id> [VAR=VAL...]
  local label=$1 id=$2; shift 2
  local dir="$TMP_ROOT/$id" home proj wt fb out rc
  home="$dir/home"; proj="$dir/project"; wt="$dir/wt"
  mkdir -p "$dir"
  fb=$(fm_test_make_spawn_fakebin "$dir/fake" claude)
  cat > "$fb/treehouse" <<'SH'
#!/usr/bin/env bash
{ printf 'treehouse'; for a in "$@"; do printf ' %s' "$a"; done; printf '\n'; } >> "${FM_TREEHOUSE_LOG:?}"
exit 0
SH
  chmod +x "$fb/treehouse"
  fm_test_spawn_home "$home" claude
  fm_git_worktree "$proj" "$wt" "wt-$id" >/dev/null 2>&1
  fm_test_spawn_brief "$home" "$id"
  echo "### $label"
  echo "\$ $* bin/fm-spawn.sh $id <project> claude --mode no-mistakes --yolo off"
  out=$(
    for kv in "$@"; do export "${kv?}"; done
    export FM_TREEHOUSE_LOG="$dir/treehouse.log"
    fm_test_run_spawn "$home" "$wt" "$fb" "$id" "$proj" claude --mode no-mistakes --yolo off
  ); rc=$?
  printf '%s\n' "$out"
  echo "[exit $rc]"
  echo "-- resolved backend in state/$id.meta: $(grep -E '^backend=' "$home/state/$id.meta" 2>/dev/null || echo '(no backend= field -> tmux, the documented compatibility default)')"
  echo "-- worktree-provider calls: $(head -3 "$dir/treehouse.log" 2>/dev/null || echo none)"
  echo
  rm -rf "/tmp/fm-$id"
}

echo "===== D. resolved backend + worktree provider on a real spawn ====="
spawn_case "no ambient signal at all: default tmux; treehouse provides the worktree" axesdefault1
spawn_case "ambient zellij markers (ZELLIJ=0, ZELLIJ_SESSION_NAME): zellij is NEVER auto-detected" axeszellij1 ZELLIJ=0 ZELLIJ_SESSION_NAME=firstmate
spawn_case "ambient orca/stream markers: neither is EVER auto-detected" axesorca1 ORCA_TERMINAL_ID=t1 ORCA_WORKTREE_ID=w1 STREAM_SESSION=s1
