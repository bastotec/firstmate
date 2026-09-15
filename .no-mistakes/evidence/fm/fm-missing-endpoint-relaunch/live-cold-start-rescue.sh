#!/usr/bin/env bash
# One cold rescue, the way the captain will run it: a brand-new tmux server,
# a task whose recorded window is gone, and a single `recover-missing`.
set -u
ROOT=/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M2HFXB6C7GYHE20VGXWHN7KH
REAL_TMUX=/opt/homebrew/bin/tmux
SOCKET="fm-cold-$$-$RANDOM"
LAB=$(mktemp -d); LAB=$(cd "$LAB" && pwd -P)
cleanup() { "$REAL_TMUX" -L "$SOCKET" kill-server >/dev/null 2>&1 || true; rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/shim" "$LAB/home/state" "$LAB/home/data" "$LAB/user-home"
printf '#!/usr/bin/env bash\nexec "%s" -L "%s" "$@"\n' "$REAL_TMUX" "$SOCKET" > "$LAB/shim/tmux"
chmod +x "$LAB/shim/tmux"
cat > "$LAB/shim/agent-state" <<SH
#!/usr/bin/env bash
set -u
PATH="$LAB/shim:\$PATH"
. "$ROOT/bin/fm-backend.sh"
fm_backend_source tmux
fm_backend_tmux_agent_state "\$1"
echo
SH
chmod +x "$LAB/shim/agent-state"
export PATH="$LAB/shim:$PATH"
ID=cold1; SES=fmses; WT="$LAB/wt"; PROJ="$LAB/proj"
mkdir -p "$PROJ"; git -C "$PROJ" init -q
git -C "$PROJ" config user.email f@e.com; git -C "$PROJ" config user.name F
printf 'seed\n' > "$PROJ/README.md"; git -C "$PROJ" add -A; git -C "$PROJ" commit -qm seed
git -C "$PROJ" worktree add --quiet -b "task-$ID" "$WT"
mkdir -p "$LAB/home/data/$ID"
printf '# Task\n## Captain'"'"'s intent\nCold rescue.\n\n## Firstmate spec\nRecreate the terminal.\n' > "$LAB/home/data/$ID/brief.md"
cat > "$LAB/home/state/$ID.meta" <<EOF
window=$SES:fm-$ID
endpoint_task_id=$ID
worktree=$WT
project=$PROJ
harness=claude
kind=ship
mode=no-mistakes
yolo=off
tasktmp=/tmp/fm-$ID-cold
model=default
effort=default
EOF
# A brand-new tmux server whose recorded session does not exist at all: the
# firstmate-account-slot-routing shape.
"$REAL_TMUX" -L "$SOCKET" new-session -d -s other -n scratch -c "$LAB"
for _ in $(seq 1 50); do
  st=$("$LAB/shim/agent-state" "$SES:fm-$ID" | head -1); [ "$st" = missing ] && break; sleep 0.2
done
out=$(env PATH="$PATH" FM_HOME="$LAB/home" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR='' \
  FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=30 \
  "$ROOT/bin/fm-control.sh" "$ID" recover-missing --note "cold rescue" 2>&1); rc=$?
ctl() {
  env PATH="$PATH" FM_HOME="$LAB/home" HOME="$LAB/user-home" CLAUDE_CONFIG_DIR='' \
    FM_SPAWN_NO_GUARD=1 FM_GATE_REFUSE_BYPASS=1 FM_CONTROL_POLL=0.2 FM_CONTROL_LAUNCH_WAIT=30 \
    "$ROOT/bin/fm-control.sh" "$@" 2>&1
}
if [ "$rc" = 0 ]; then
  printf 'RECOVERED | %s\n' "$(printf '%s' "$out" | grep '^recovered')"
  exit 0
fi
printf 'FAILED    | %s\n' "$(printf '%s' "$out" | grep '^error:' | head -1)"
printf '          | operator guidance: %s\n' "$(printf '%s' "$out" | grep '^error:' | tail -1)"
printf '          | endpoint now reads: %s\n' "$("$LAB/shim/agent-state" "$SES:fm-$ID" | head -1)"
out2=$(ctl "$ID" recover-missing --note "retry the same verb"); rc2=$?
printf '          | retry recover-missing -> rc=%s %s\n' "$rc2" "$(printf '%s' "$out2" | grep '^error:' | head -1)"
out3=$(ctl "$ID" relaunch --note "following the guidance the failure printed"); rc3=$?
if [ "$rc3" = 0 ]; then
  printf '          | relaunch -> rc=0 %s\n' "$(printf '%s' "$out3" | grep '^relaunched')"
else
  printf '          | relaunch -> rc=%s %s\n' "$rc3" "$(printf '%s' "$out3" | grep '^error:' | head -1)"
fi
exit "$rc"
