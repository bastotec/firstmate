#!/usr/bin/env bash
# End-to-end driver for the merge-poll trust repair, exercised exactly the way an
# operator does: register a PR for merge notification with bin/fm-pr-check.sh,
# let ordinary writers append to the task record, then run bin/fm-watch.sh and
# see whether the merge is reported.
set -u
ROOT=${ROOT:?set ROOT to a firstmate checkout}
TMP=${TMP_ROOT:?set TMP_ROOT}
BASE_PATH=/usr/bin:/bin:/usr/sbin:/sbin

mkhome() { # <name>
  local d="$TMP/$1"
  rm -rf "$d"
  mkdir -p "$d/home/state" "$d/home/data" "$d/home/config" "$d/wt" "$d/fakebin" "$d/root/bin"
  cat > "$d/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$d/root/bin/fm-guard.sh"
  cat > "$d/fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" state "*) printf '%s\n' "${FM_TEST_GH_STATE:-OPEN}" ;;
esac
exit 0
SH
  chmod +x "$d/fakebin/gh"
  printf 'window=fm-task-a\nendpoint_task_id=task-a\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' \
    "$d/wt" "$d/project" > "$d/home/state/task-a.meta"
  chmod 0600 "$d/home/state/task-a.meta"
  printf '%s\n' "$d"
}

arm() { # <dir> <url>
  local d=$1 url=$2
  FM_ROOT_OVERRIDE="$d/root" FM_HOME="$d/home" PATH="$d/fakebin:$BASE_PATH" \
    "$ROOT/bin/fm-pr-check.sh" task-a "$url"
}

stop_check() { # <dir> - a trivial custom check so the watcher completes a cycle
  local d=$1
  printf '#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n' > "$d/home/state/z-stop.check.sh"
  chmod 0700 "$d/home/state/z-stop.check.sh"
  FM_HOME="$d/home" "$ROOT/bin/fm-check-register.sh" z-stop >/dev/null
}

watch() { # <dir home> <dir fakebin>
  local home=$1 fakebin=$2
  perl -e 'my $pid=fork; die unless defined $pid; if (!$pid) { exec @ARGV } local $SIG{ALRM}=sub { kill "TERM", $pid; waitpid $pid, 0; exit 124 }; alarm 20; waitpid $pid, 0; alarm 0; exit($? >> 8)' \
    env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" FM_CHECK_INTERVAL=0 FM_CHECK_TIMEOUT=5 \
      FM_POLL=0.02 FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=0 FM_TEST_GH_STATE=MERGED \
      PATH="$fakebin:$BASE_PATH" "$ROOT/bin/fm-watch.sh"
}
