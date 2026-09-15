#!/usr/bin/env bash
# Adversarial scenarios: things that must NOT be allowed to report a merge, all
# driven through the real watcher with gh stubbed MERGED, so an accepted poll
# would visibly report "merged".
set -u
. /tmp/fm-poll-drive/drive.sh

report() { # <dir> <label>
  local d=$1 label=$2
  if grep -q 'task-a.check.sh: merged' "$d/watch.out"; then
    echo "RESULT[$label]: merge REPORTED"
  elif grep -q 'rejected unauthenticated state checks' "$d/watch.out"; then
    echo "RESULT[$label]: refused as unauthenticated, no merge reported"
  else
    echo "RESULT[$label]: neither merge nor refusal: $(cat "$d/watch.out")"
  fi
}

echo "### tampered: poll program bytes edited after registration"
d=$(mkhome trust-tampered)
arm "$d" https://github.com/example/repo/pull/42 >/dev/null
printf '\nprintf "tampered-bytes-ran\\n"\n' >> "$d/home/state/task-a.check.sh"
echo "  appended to task-a.check.sh: printf tampered-bytes-ran"
watch "$d/home" "$d/fakebin" > "$d/watch.out" 2> "$d/watch.err"; echo "  fm-watch.sh exit $?"
sed 's/^/  /' "$d/watch.out"
grep -q 'tampered-bytes-ran' "$d/watch.out" && echo "  !! tampered bytes executed"
report "$d" tampered
echo

echo "### replaced: the registered file swapped for a different file with identical bytes"
d=$(mkhome trust-replaced)
arm "$d" https://github.com/example/repo/pull/42 >/dev/null
cp "$d/home/state/task-a.check.sh" "$d/replacement.check.sh"
rm -f "$d/home/state/task-a.check.sh"
mv "$d/replacement.check.sh" "$d/home/state/task-a.check.sh"
chmod 0600 "$d/home/state/task-a.check.sh"
cmp -s "$ROOT/bin/fm-pr-poll.sh" "$d/home/state/task-a.check.sh" && echo "  replacement is byte-identical to bin/fm-pr-poll.sh"
watch "$d/home" "$d/fakebin" > "$d/watch.out" 2> "$d/watch.err"; echo "  fm-watch.sh exit $?"
sed 's/^/  /' "$d/watch.out"
report "$d" replaced
echo

echo "### cross-home: a whole registered poll lifted into a second home"
a=$(mkhome trust-home-a)
b=$(mkhome trust-home-b)
arm "$a" https://github.com/example/repo/pull/42 >/dev/null
cp "$a/home/state/task-a.meta" "$a/home/state/task-a.check.sh" "$a/home/state/task-a.pr-poll" \
   "$a/home/state/task-a.pr-poll-registration" "$b/home/state/"
chmod 0600 "$b/home/state/task-a.check.sh" "$b/home/state/task-a.pr-poll" "$b/home/state/task-a.pr-poll-registration"
echo "  copied home A's four poll artifacts into home B"
watch "$b/home" "$b/fakebin" > "$b/watch.out" 2> "$b/watch.err"; echo "  home B fm-watch.sh exit $?"
sed 's/^/  /' "$b/watch.out"
report "$b" cross-home
stop_check "$a"
watch "$a/home" "$a/fakebin" > "$a/watch.out" 2> "$a/watch.err"
echo "  home A (the home that registered it) still reports:"
sed 's/^/  /' "$a/watch.out"
echo

echo "### ambiguous identity: a second pr= line appended to the task record"
d=$(mkhome trust-second-pr)
arm "$d" https://github.com/example/repo/pull/42 >/dev/null
printf 'pr=%s\n' 'https://github.com/example/repo/pull/99' >> "$d/home/state/task-a.meta"
echo "  task record now names two pull requests (42 and 99)"
watch "$d/home" "$d/fakebin" > "$d/watch.out" 2> "$d/watch.err"; echo "  fm-watch.sh exit $?"
sed 's/^/  /' "$d/watch.out"
report "$d" second-pr
echo

echo "### ambiguous identity: a malformed pr_head= appended to the task record"
d=$(mkhome trust-bad-head)
arm "$d" https://github.com/example/repo/pull/42 >/dev/null
printf 'pr_head=%s\n' 'not-a-sha' >> "$d/home/state/task-a.meta"
watch "$d/home" "$d/fakebin" > "$d/watch.out" 2> "$d/watch.err"; echo "  fm-watch.sh exit $?"
sed 's/^/  /' "$d/watch.out"
report "$d" bad-head
