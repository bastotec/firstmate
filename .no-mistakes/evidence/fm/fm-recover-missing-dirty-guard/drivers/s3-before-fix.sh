#!/usr/bin/env bash
# S3 (regression proof): the SAME rescue, driven against the pre-fix tool
# (commit f659839, the parent of the fix). The reported failure must reproduce.
. /tmp/fm-live-drive/lib.sh
ID=live3
setup_task "$ID"
start_endpoint "$ID"
dirty_the_copy

echo "== the worker's mid-work local copy =="
git -C "$LAB/wt" status --porcelain
echo
echo "== the terminal window is gone =="
"${TMUX[@]}" kill-window -t "=fmlive:=fm-$ID"
"${TMUX[@]}" list-windows -t fmlive -F '  window: #{window_name}'
echo
echo "== \$ bin/fm-control.sh $ID recover-missing --note '...'   (tool at f659839, before the fix) =="
OUT=$(run_control "$ID" recover-missing --note "the terminal server died mid-task"); RC=$?
echo "$OUT"
echo "exit=$RC"
echo
echo "== the endpoint afterwards =="
"${TMUX[@]}" list-windows -t fmlive -F '  window: #{window_name}'
echo "S3 exit=$RC"
