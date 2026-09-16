#!/usr/bin/env bash
# S4d (adversarial): the dirty copy is a Treehouse pool slot that another task
# now claims. Removing the dirty guard must not let recovery walk into it.
. /tmp/fm-live-drive/lib.sh
ID=live5
setup_task "$ID"
POOL="$LAB/pool"; mkdir -p "$POOL/1"; printf '{}\n' > "$POOL/treehouse-state.json"
SLOT="$POOL/1/checkout"
git -C "$LAB/proj" "${GITC[@]}" worktree add --quiet -b "slot-$ID" "$SLOT" >/dev/null
sed -i '' "s#^worktree=.*#worktree=$SLOT#" "$LAB/home/state/$ID.meta"
printf 'work in progress\n' > "$SLOT/new-source.sh"
printf '# project\nhalfway through\n' > "$SLOT/README.md"
start_endpoint "$ID"
"${TMUX[@]}" kill-window -t "=fmlive:=fm-$ID"

META="$LAB/home/state/$ID.meta"; BRIEF="$LAB/home/data/$ID/brief.md"
echo "== the slot is dirty and claimed by another task =="
git -C "$SLOT" status --porcelain | sed 's/^/  /'
printf 'task=someone-else\nhome=%s\n' "$LAB/home" > "$POOL/1/.fm-slot-owner"
echo "  .fm-slot-owner: $(tr "\n" " " < "$POOL/1/.fm-slot-owner")"
MB=$(cat "$META"); BB=$(cat "$BRIEF")
echo
echo "== \$ bin/fm-control.sh $ID recover-missing --note '...' =="
OUT=$(run_control "$ID" recover-missing --note "recover"); RC=$?
echo "$OUT" | sed 's/^/  /'; echo "  exit=$RC"
[ "$(cat "$META")" = "$MB" ] && [ "$(cat "$BRIEF")" = "$BB" ] \
  && echo "  record and instructions unchanged" || echo "  !! something changed"
grep -qx 'task=someone-else' "$POOL/1/.fm-slot-owner" \
  && echo "  the other task's slot claim is untouched" || echo "  !! the slot claim changed"
echo "  endpoint after the refusal: $("${TMUX[@]}" list-windows -t fmlive -F '#{window_name}' | tr '\n' ' ')"

echo
echo "== the same slot, claimed by THIS task, still recovers while dirty =="
printf 'task=%s\nhome=%s\n' "$ID" "$LAB/home" > "$POOL/1/.fm-slot-owner"
OUT=$(run_control "$ID" recover-missing --note "the terminal server died mid-task"); RC=$?
echo "$OUT" | sed 's/^/  /'; echo "  exit=$RC"
git -C "$SLOT" status --porcelain | sed 's/^/  /'
echo "  .fm-slot-owner: $(tr "\n" " " < "$POOL/1/.fm-slot-owner")"
echo "  pane command: $("${TMUX[@]}" display-message -p -t "=fmlive:=fm-$ID" '#{pane_current_command}' 2>/dev/null)"
