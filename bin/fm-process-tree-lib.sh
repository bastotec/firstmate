#!/usr/bin/env bash
# fm-process-tree-lib.sh - stop a Deck turn's tool trees the way the second-mate
# host does (bin/fm-deck-worker.sh "SECOND MATE TURN STOP"), shared with the
# captain lane (bin/fm-captain-lane.sh), plus the bounded child stop the host
# and the watcher arm (bin/fm-watch-arm.sh) use at shutdown. No side effects on source.

kill_tree() {  # <pid>: SIGKILL <pid> and every process descended from it
  local tree=$1 next pid changed seen=$'\n'
  kill -STOP "$1" 2>/dev/null || return 0
  seen+="$1"$'\n'
  while :; do
    changed=0
    next=$(ps -A -o pid= -o ppid= 2>/dev/null \
      | awk -v parents=" $(printf '%s' "$tree" | tr '\n' ' ') " 'index(parents, " " $2 " ") { print $1 }')
    for pid in $next; do
      case "$seen" in *$'\n'"$pid"$'\n'*) continue ;; esac
      kill -STOP "$pid" 2>/dev/null || true
      tree="$tree $pid"
      seen+="$pid"$'\n'
      changed=1
    done
    [ "$changed" -eq 1 ] || break
  done
  for pid in $tree; do kill -KILL "$pid" 2>/dev/null || true; done
}

# Cancel every direct child of <deck-pid> that shares its process group (shell
# tools and hooks; MCP servers lead their own groups and are left alone).
fm_cancel_tool_trees() {  # <deck-pid>
  local deck=$1 child deck_pgid child_pgid
  deck_pgid=$(ps -o pgid= -p "$deck" 2>/dev/null | tr -d '[:space:]')
  [ -n "$deck_pgid" ] || return 0
  for child in $(pgrep -P "$deck" 2>/dev/null); do
    child_pgid=$(ps -o pgid= -p "$child" 2>/dev/null | tr -d '[:space:]')
    [ "$child_pgid" != "$deck_pgid" ] || kill_tree "$child"
  done
}

# Stop one child of the calling shell within a bound: TERM, wait up to <secs>
# for it to exit, then SIGKILL its whole process subtree and reap it. Returns
# the child's wait status. Used where a shutdown must never hang on a child
# that defers its TERM trap (a foreground sleep, a slow check).
fm_stop_child_bounded() {  # <pid> <secs>
  local pid=$1 limit=$2 waited=0 rc=0
  kill -TERM "$pid" 2>/dev/null || true
  while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt $((limit * 10)) ]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  ! kill -0 "$pid" 2>/dev/null || kill_tree "$pid"
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}
