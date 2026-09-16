#!/usr/bin/env bash
# S2: the exact reported sequence - a ship task is mid-work with a modified
# source file and its terminal SERVER dies, so the whole session goes with it.
. /tmp/fm-live-drive/lib.sh
ID=live2
setup_task "$ID"
start_endpoint "$ID"
dirty_the_copy

echo "== the worker's mid-work local copy =="
git -C "$LAB/wt" status --porcelain
BEFORE=$(copy_fingerprint)

echo
echo "== the terminal server dies =="
"${TMUX[@]}" kill-server 2>/dev/null
"${TMUX[@]}" list-sessions 2>&1 | sed 's/^/  /'

echo
echo "== relaunch cannot take over a missing endpoint =="
OUT=$(run_control "$ID" relaunch --note "try the other verb first"); RC=$?
echo "$OUT" | sed 's/^/  /'
echo "  exit=$RC"

echo
echo "== \$ bin/fm-control.sh $ID recover-missing --note '...' =="
OUT=$(run_control "$ID" recover-missing --note "the terminal server died mid-task; your local copy is untouched"); RC=$?
echo "$OUT"
echo "exit=$RC"

echo
echo "== the endpoint afterwards =="
"${TMUX[@]}" list-sessions -F '  session: #{session_name}' 2>&1
"${TMUX[@]}" list-windows -t fmlive -F '  window: #{window_name}'
echo "  pane command: $("${TMUX[@]}" display-message -p -t "=fmlive:=fm-$ID" '#{pane_current_command}')"

echo
echo "== the mid-work copy afterwards =="
git -C "$LAB/wt" status --porcelain
AFTER=$(copy_fingerprint)
if [ "$BEFORE" = "$AFTER" ]; then
  echo "RESULT: local copy byte-identical (status, HEAD and every file)"
else
  echo "RESULT: LOCAL COPY CHANGED"; diff <(printf '%s\n' "$BEFORE") <(printf '%s\n' "$AFTER")
fi
echo
echo "== journal =="
grep -E '^(phase|worktree_dirty|exit_result)=' "$LAB/home/state/$ID.control-relaunch"
echo "S2 exit=$RC"
