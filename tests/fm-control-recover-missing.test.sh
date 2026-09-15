#!/usr/bin/env bash
# fm-control.sh recover-missing: the transactional recreate-the-terminal verb.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-trace-context-lib.sh"

CONTROL="$ROOT/bin/fm-control.sh"
SPAWN="$ROOT/bin/fm-spawn.sh"

TMP_ROOT=$(fm_test_tmproot fm-control-recover)
mkdir -p "$TMP_ROOT"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
TASK_TMPS=()

relaunch_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  rm -rf "$TMP_ROOT"
}
trap relaunch_cleanup EXIT

make_tmux_stub() {  # <dir>
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *cursor_y*) printf '1\n'; exit 0 ;;
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    ;;
  has-session)
    [ -f "$D/session" ] && exit 0
    exit 1 ;;
  new-window)
    printf '%s\n' "fm-t1" >> "$D/windows"
    printf 'zsh\n' > "$D/command"
    printf '@999\n'
    exit 0 ;;
  set-window-option) exit 0 ;;
  list-windows)
    [ -f "$D/windows" ] && cat "$D/windows"
    exit 0 ;;
  capture-pane)
    printf '╭────╮\n│    │\n╰────╯\n'
    exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  : > "$dir/fake/keys"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  : > "$dir/fake/session"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

add_ship_task() {
  local dir=$1 id=$2 harness=${3:-claude}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  cat > "$home/data/$id/brief.md" <<EOF
# Task
EOF
  {
    echo "harness=$harness"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "kind=ship"
    echo "backend=tmux"
    echo "window=fm:fm-$id"
  } > "$home/state/$id.meta"
  printf '%s' "$wt" > "$dir/fake/cwd"
  TASK_TMPS+=("$dir")
}

test_recover_missing_success() {
  local dir
  dir=$(new_case success)
  add_ship_task "$dir" "t1"
  # Make the original window MISSING
  rm -f "$dir/fake/windows"
  echo "relaunch_tx=test" > "$dir/home/state/t1.meta.control_relaunch_tx"

  # We have to stub fm-spawn.sh so it doesn't fail on missing harness
  mkdir -p "$dir/fakebin"
  cat > "$dir/fakebin/fm-spawn.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/fakebin/fm-spawn.sh"

  FM_HOME="$dir/home" PATH="$dir/fakebin:$PATH" SCRIPT_DIR="$dir/fakebin" FM_FAKE_DIR="$dir/fake" FM_BACKEND_TMUX_NO_CREATE=1 \
    "$CONTROL" t1 recover-missing --note "recover" >"$dir/out" 2>"$dir/err" || {
      cat "$dir/err" >&2
      echo "recover-missing failed"
      exit 1
    }

  # The window target in meta is still fm:fm-t1
  grep -q "window=fm:fm-t1" "$dir/home/state/t1.meta" || {
    echo "target unexpectedly changed in meta"
    exit 1
  }
}

test_recover_missing_refuses_alive() {
  local dir
  dir=$(new_case alive)
  add_ship_task "$dir" "t1"
  # Window is present, agent is claude (alive)

  FM_HOME="$dir/home" PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" FM_BACKEND_TMUX_NO_CREATE=1 \
    "$CONTROL" t1 recover-missing --note "recover" >"$dir/out" 2>"$dir/err" && exit 1
  grep -q "endpoint reads 'alive'" "$dir/err" || exit 1
}

test_recover_missing_refuses_dirty() {
  local dir
  dir=$(new_case dirty)
  add_ship_task "$dir" "t1"
  rm -f "$dir/fake/windows"
  
  : > "$dir/wt/dirty.txt"
  git -C "$dir/wt" add dirty.txt

  FM_HOME="$dir/home" PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" FM_BACKEND_TMUX_NO_CREATE=1 \
    "$CONTROL" t1 recover-missing --note "recover" >"$dir/out" 2>"$dir/err" && exit 1
  grep -q "uncommitted changes; refusing" "$dir/err" || exit 1
}

test_recover_missing_refuses_ambiguous() {
  local dir
  dir=$(new_case ambiguous)
  add_ship_task "$dir" "t1"
  # Window is present, agent is unknown (ambiguous)
  printf 'unknown\n' > "$dir/fake/command"

  FM_HOME="$dir/home" PATH="$dir/fakebin:$PATH" FM_FAKE_DIR="$dir/fake" FM_BACKEND_TMUX_NO_CREATE=1 \
    "$CONTROL" t1 recover-missing --note "recover" >"$dir/out" 2>"$dir/err" && exit 1
  grep -q "endpoint reads 'ambiguous'" "$dir/err" || exit 1
}

test_recover_missing_success
test_recover_missing_refuses_alive
test_recover_missing_refuses_ambiguous
test_recover_missing_refuses_dirty
echo "PASS: fm-control-recover-missing"
