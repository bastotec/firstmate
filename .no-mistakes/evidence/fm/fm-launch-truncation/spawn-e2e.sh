#!/usr/bin/env bash
# Drives the REAL bin/fm-spawn.sh CLI against a REAL tmux server on a private
# socket. The tmux backend, the pane, its tty line discipline, the readiness
# gate and the launched process are all real; `treehouse` and the harness
# binary are stand-ins (real processes that put the pane in the shape the
# scenario needs and record that they ran).
#
#   MODE=ok    the pane reaches a prompt -> the long launch command must start the worker
#   MODE=busy  the pane never reads input -> spawn must fail loudly, not silently
set -u
ROOT=$1
MODE=$2
. "$ROOT/tests/fixtures.sh"

REAL_TMUX=$(command -v tmux)
SOCKET="fm-spawn-e2e-$$-$MODE"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-spawn-e2e.XXXXXX")
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$TMP"; }
trap cleanup EXIT

# Redirect HOME and strip the host's own bin dirs from PATH so nothing here can
# reach the operator's real treehouse install or real home state.
export HOME="$TMP/fakehome"; mkdir -p "$HOME"
BASE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
HOME_DIR="$TMP/home"; PROJ="$TMP/project"; WT="$TMP/slot"
FAKEBIN="$TMP/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<SH
#!/usr/bin/env bash
exec "$REAL_TMUX" -L "$SOCKET" "\$@"
SH
chmod +x "$FAKEBIN/tmux"

if [ "$MODE" = busy ]; then
  # Leaves the pane in the isolated slot with NOTHING reading input - the
  # never-ready shape the gate exists to refuse.
  cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
cd "$FM_FAKE_WT" || exit 1
exec cat > /dev/null
SH
else
  cat > "$FAKEBIN/treehouse" <<'SH'
#!/usr/bin/env bash
cd "$FM_FAKE_WT" || exit 1
exec /bin/bash --noprofile --norc -i
SH
fi
chmod +x "$FAKEBIN/treehouse"

# The harness a launch is supposed to start: a real process that writes its own
# evidence, so "marker present" means a worker actually ran.
cat > "$FAKEBIN/codex" <<'SH'
#!/usr/bin/env bash
{ printf 'codex really started\n'; printf 'cwd=%s\n' "$PWD"; printf 'argv:'; printf ' [%s]' "$@"; printf '\n'; } > "$FM_FAKE_MARKER"
exec sleep 300
SH
chmod +x "$FAKEBIN/codex"

fm_test_spawn_home "$HOME_DIR" codex
fm_git_worktree "$PROJ" "$WT" "slot-e2e"
ID="e2e-$MODE-z1"
fm_test_spawn_brief "$HOME_DIR" "$ID" "Drive the launch-truncation readiness gate end to end."

"$REAL_TMUX" -L "$SOCKET" new-session -d -s firstmate -x 200 -y 50 "/bin/bash --noprofile --norc -i" 2>/dev/null

export FM_FAKE_WT="$WT" FM_FAKE_MARKER="$TMP/harness-marker"
# New windows inherit the tmux SERVER's environment, not the client's, so the
# pane's PATH/HOME/fixture vars have to be set on the server explicitly.
for v in FM_FAKE_WT FM_FAKE_MARKER HOME; do
  "$REAL_TMUX" -L "$SOCKET" set-environment -g "$v" "$(eval printf '%s' "\$$v")"
done
"$REAL_TMUX" -L "$SOCKET" set-environment -g PATH "$FAKEBIN:$BASE_PATH"
: > "$FM_FAKE_MARKER"
unset TMUX TMUX_PANE
set +e
out=$(
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_SPAWN_NO_GUARD=1 FM_PANE_READY_TIMEOUT="${FM_PANE_READY_TIMEOUT:-5}" \
  PATH="$FAKEBIN:$BASE_PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJ" --mode no-mistakes --yolo off 2>&1
)
status=$?
set -e
echo "=== MODE=$MODE   FM_PANE_READY_TIMEOUT=${FM_PANE_READY_TIMEOUT:-5}"
echo "--- fm-spawn.sh exit status: $status"
echo "--- fm-spawn.sh output (what the operator sees):"
printf '%s\n' "$out" | grep -v '^warning: ' | cut -c1-220 | sed 's/^/    /'
echo "--- state/$ID.status (what recovery and the crew board read):"
sed 's/^/    /' "$HOME_DIR/state/$ID.status" 2>/dev/null || echo "    (no status file)"
i=0; while [ $i -lt 100 ]; do [ -s "$FM_FAKE_MARKER" ] && break; sleep 0.1; i=$((i+1)); done
echo "--- pane tail (what an operator sees in the window):"
"$REAL_TMUX" -L "$SOCKET" capture-pane -p -t "firstmate:fm-$ID" 2>/dev/null | grep -v '^$' | tail -4 | cut -c1-140 | sed 's/^/    /'
echo "--- harness marker (written by the launched process itself):"
if [ -s "$FM_FAKE_MARKER" ]; then
  head -2 "$FM_FAKE_MARKER" | sed 's/^/    /'
  echo "    argv it received: $(tail -n +3 "$FM_FAKE_MARKER" | wc -c | tr -d ' ') bytes, first 90: $(tail -n +3 "$FM_FAKE_MARKER" | head -1 | cut -c1-90)"
else
  echo "    (no worker started)"
fi
echo "--- host ~/.treehouse untouched: $(ls "$HOME/.treehouse" 2>/dev/null | wc -l | tr -d ' ') entries under the sandboxed HOME"
