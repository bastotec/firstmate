#!/usr/bin/env bash
# S1: the task's tmux WINDOW is gone while the session survives. The local copy
# is mid-work (modified + untracked + staged) and the project's base branch has
# moved on, so a base refresh would be visible if one ran.
. /tmp/fm-live-drive/lib.sh
ID=live1
setup_task "$ID"
start_endpoint "$ID"
dirty_the_copy

# base moves on: a `git reset --hard`/base refresh would show up as a changed HEAD
printf 'a later commit on the base branch\n' >> "$LAB/proj/README.md"
git -C "$LAB/proj" "${GITC[@]}" commit --quiet -am "base moves on"

echo "== the worker's mid-work local copy =="
git -C "$LAB/wt" status --porcelain
BEFORE=$(copy_fingerprint)

echo
echo "== the terminal window is gone =="
"${TMUX[@]}" kill-window -t "=fmlive:=fm-$ID"
"${TMUX[@]}" list-windows -t fmlive -F '  window: #{window_name}'

echo
echo "== \$ bin/fm-control.sh $ID recover-missing --note '...' =="
OUT=$(run_control "$ID" recover-missing --note "the terminal server died mid-task; your local copy is untouched"); RC=$?
echo "$OUT"
echo "exit=$RC"

echo
echo "== the endpoint afterwards =="
"${TMUX[@]}" list-windows -t fmlive -F '  window: #{window_name}'
echo "  pane command: $("${TMUX[@]}" display-message -p -t "=fmlive:=fm-$ID" '#{pane_current_command}')"
echo "  pane cwd:     $("${TMUX[@]}" display-message -p -t "=fmlive:=fm-$ID" '#{pane_current_path}')"

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
echo "== what the rescue itself put in the local copy =="
echo "  files now in the copy: $(ls -A "$LAB/wt" | tr '\n' ' ')"
echo "  harness wiring written by the launch owner:"
find "$LAB/wt/.claude" -type f 2>/dev/null | sed "s#$LAB/wt/#    #"
echo "  git-excluded, so it never shows as local change:"
grep -n 'claude' "$LAB/proj/.git/info/exclude" 2>/dev/null | sed 's/^/    /'

echo
echo "== journal =="
grep -E '^(phase|worktree_dirty|worktree_head|exit_result)=' "$LAB/home/state/$ID.control-relaunch"
echo "S1 exit=$RC"
