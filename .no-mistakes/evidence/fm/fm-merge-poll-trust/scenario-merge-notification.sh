#!/usr/bin/env bash
# Scenario: a PR is registered for automatic merge notification, ordinary task
# writers then append to the task record, and the PR merges.
set -u
. /tmp/fm-poll-drive/drive.sh
label=${LABEL:-run}
d=$(mkhome "merge-notification-$label")
echo "# operator registers the PR for merge notification"
arm "$d" https://github.com/example/repo/pull/42 && echo "fm-pr-check.sh: exit 0 (registration reported success)"
echo
echo "# what the registration armed:"
ls "$d/home/state" | sed 's/^/  /'
echo
echo "# then the task is relaunched and the captain reviews - both append to the task record"
printf 'control_relaunch_tx=%s\n' '96772.20260915T115436Z.29459' >> "$d/home/state/task-a.meta"
printf 'decisions_reviewed=1\ndecision_keys=%s\n' 'nm-1-review' >> "$d/home/state/task-a.meta"
echo "  task record now reads:"
sed 's/^/    /' "$d/home/state/task-a.meta"
echo
echo "# the PR merges (gh reports MERGED); the supervisor's watcher runs"
case "${STOP_CHECK-1}" in 0) ;; *) stop_check "$d" ;; esac
watch "$d/home" "$d/fakebin" > "$d/watch.out" 2> "$d/watch.err"
rc=$?
echo "fm-watch.sh: exit $rc"
echo "watcher told the supervisor:"
sed 's/^/  /' "$d/watch.out"
[ -s "$d/watch.err" ] && { echo "stderr:"; sed 's/^/  /' "$d/watch.err"; }
echo
if grep -q 'task-a.check.sh: merged' "$d/watch.out"; then
  echo "RESULT: merge notification delivered"
elif grep -q 'rejected unauthenticated state checks' "$d/watch.out"; then
  echo "RESULT: NO merge notification - poll refused as unauthenticated"
else
  echo "RESULT: no merge notification and no refusal reported"
fi
