#!/usr/bin/env bash
# S4 (adversarial): with the dirty-copy refusal gone, every OTHER refusal the
# verb promises must still hold on a copy full of uncommitted work, and each
# must leave the durable record and the instructions byte-identical.
. /tmp/fm-live-drive/lib.sh
ID=live4
setup_task "$ID"
start_endpoint "$ID"
dirty_the_copy
META="$LAB/home/state/$ID.meta"; BRIEF="$LAB/home/data/$ID/brief.md"

check_untouched() {  # <label> <meta-before> <brief-before>
  local label=$1 mb=$2 bb=$3 ok=yes
  [ "$(cat "$META")" = "$mb" ] || { echo "  !! durable record changed"; ok=no; }
  [ "$(cat "$BRIEF")" = "$bb" ] || { echo "  !! instructions changed"; ok=no; }
  [ "$(git -C "$LAB/wt" status --porcelain)" = " M README.md
A  staged.txt
?? new-source.sh" ] || { echo "  !! the local copy changed"; ok=no; }
  [ "$ok" = yes ] && echo "  record, instructions and the dirty copy all unchanged"
}

echo "=== 4a. the endpoint holds a bare shell (agent gone, terminal alive) ==="
MB=$(cat "$META"); BB=$(cat "$BRIEF")
OUT=$(run_control "$ID" recover-missing --note "recover"); RC=$?
echo "$OUT" | sed 's/^/  /'; echo "  exit=$RC"
check_untouched 4a "$MB" "$BB"

echo
echo "=== 4b. an agent is still running at the endpoint ==="
"${TMUX[@]}" send-keys -t "=fmlive:=fm-$ID" 'claude --dangerously-skip-permissions' Enter
for _ in $(seq 1 50); do
  [ "$("${TMUX[@]}" display-message -p -t "=fmlive:=fm-$ID" '#{pane_current_command}')" = claude ] && break
  sleep 0.2
done
echo "  pane command: $("${TMUX[@]}" display-message -p -t "=fmlive:=fm-$ID" '#{pane_current_command}')"
MB=$(cat "$META"); BB=$(cat "$BRIEF")
OUT=$(run_control "$ID" recover-missing --note "recover"); RC=$?
echo "$OUT" | sed 's/^/  /'; echo "  exit=$RC"
check_untouched 4b "$MB" "$BB"

echo
echo "=== 4c. the local copy itself is gone ==="
"${TMUX[@]}" kill-window -t "=fmlive:=fm-$ID"
mv "$LAB/wt" "$LAB/wt-parked"
MB=$(cat "$META"); BB=$(cat "$BRIEF")
OUT=$(run_control "$ID" recover-missing --note "recover"); RC=$?
echo "$OUT" | sed 's/^/  /'; echo "  exit=$RC"
mv "$LAB/wt-parked" "$LAB/wt"
check_untouched 4c "$MB" "$BB"
echo "  endpoint after the refusal: $("${TMUX[@]}" list-windows -t fmlive -F '#{window_name}' | tr '\n' ' ')"

echo
echo "=== 4d. the dirty copy is a Treehouse pool slot another task now claims ==="
POOL="$LAB/pool"; mkdir -p "$POOL/1"; printf '{}\n' > "$POOL/treehouse-state.json"
rm -rf "$POOL/1/checkout"; cp -R "$LAB/wt" "$POOL/1/checkout"
printf 'someone-else\n' > "$POOL/1/.fm-slot-owner"
sed -i '' "s#^worktree=.*#worktree=$POOL/1/checkout#; s#^project=.*#project=$POOL#" "$META"
MB=$(cat "$META"); BB=$(cat "$BRIEF")
OUT=$(run_control "$ID" recover-missing --note "recover"); RC=$?
echo "$OUT" | sed 's/^/  /'; echo "  exit=$RC"
[ "$(cat "$META")" = "$MB" ] && [ "$(cat "$BRIEF")" = "$BB" ] \
  && echo "  record and instructions unchanged" || echo "  !! something changed"
[ "$(cat "$POOL/1/.fm-slot-owner")" = someone-else ] \
  && echo "  the other task's slot claim is untouched" || echo "  !! the slot claim changed"
echo "  endpoint after the refusal: $("${TMUX[@]}" list-windows -t fmlive -F '#{window_name}' | tr '\n' ' ')"
