#!/usr/bin/env bash
# Post-merge hook for the firstmate repository itself.
# Copy to <home>/config/post-merge/firstmate.sh (mode 0755) and name it with
# "hook": "firstmate" in config/autoland.json.
#
# It runs the mechanical half of /updatefirstmate: bin/fm-update.sh
# fast-forwards this home and every registered local and remote second-mate
# home, never forcing, stashing, or discarding. The restart of live second
# mates and the AGENTS.md re-read stay with the supervisor, so the summary line
# names what /updatefirstmate still has to do.
set -u

target=$1
out=$(FM_ROOT_OVERRIDE="$FM_AUTOLAND_CODE_ROOT" "$FM_AUTOLAND_CODE_ROOT/bin/fm-update.sh" 2>&1)
rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ]; then
  echo "bin/fm-update.sh exited $rc"
  exit 1
fi
head=$(git -C "$FM_AUTOLAND_CODE_ROOT" rev-parse HEAD 2>/dev/null || true)
if [ "$head" != "$target" ]; then
  echo "tracked code is at ${head:-an unreadable commit}, not ${target:0:7}: $(printf '%s\n' "$out" | grep -m1 'skipped' || echo 'see the log')"
  exit 1
fi
reread=$(printf '%s\n' "$out" | sed -n 's/^reread-firstmate: //p')
restart=$(printf '%s\n' "$out" | sed -n 's/^restart-secondmates: *//p')
nudge=$(printf '%s\n' "$out" | sed -n 's/^nudge-secondmates: *//p')
skipped=$(printf '%s\n' "$out" | grep -c 'skipped' || true)
echo "homes at ${target:0:7} (${skipped} skipped); reread-firstmate ${reread:-no}; restart-secondmates ${restart:-none}; nudge-secondmates ${nudge:-none}; finish /updatefirstmate from step 2"
