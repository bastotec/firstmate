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

# Begin shutdown once: capture the child's tree before TERM can orphan any
# descendants, and retain it so repeated calls do not interrupt TERM cleanup.
# fm_stop_child_bounded can follow an earlier begin or initiate the stop itself;
# its <secs> grace is measured from that first TERM using a monotonic clock,
# including intervening work. It waits only the remaining grace, kills surviving
# trees even if the original child has exited, reaps the child, and returns its
# wait status.
fm_begin_child_stop() {  # <pid>
  local pid=$1 key="FM_CHILD_STOP_TREE_$1" time_key="FM_CHILD_STOP_TIME_$1" tree
  [ -z "${!key:-}" ] || return 0
  tree=$(ps -A -o pid= -o ppid= 2>/dev/null | awk -v root="$pid" '
    { parent[$1] = $2 }
    END {
      tree[root] = 1
      do {
        changed = 0
        for (pid in parent) if (!(pid in tree) && (parent[pid] in tree)) {
          tree[pid] = 1
          changed = 1
        }
      } while (changed)
      for (pid in tree) print pid
    }')
  printf -v "$key" '%s' "${tree:-$pid}"
  printf -v "$time_key" '%s' "$(fm_child_stop_now)"
  kill -TERM "$pid" 2>/dev/null || true
}

fm_child_stop_now() {
  python3 -c 'import time; print(time.clock_gettime_ns(time.CLOCK_MONOTONIC) // 1000000)'
}

fm_child_stop_pending() {  # <captured-pids>
  local pid
  for pid in $1; do
    kill -0 "$pid" 2>/dev/null && return 0
  done
  return 1
}

fm_stop_child_bounded() {  # <pid> <secs>
  local pid=$1 limit=$2 rc=0 key="FM_CHILD_STOP_TREE_$1" time_key="FM_CHILD_STOP_TIME_$1" tree member deadline
  fm_begin_child_stop "$pid"
  tree=${!key}
  deadline=$(( ${!time_key} + limit * 1000 ))
  while fm_child_stop_pending "$tree" && [ "$(fm_child_stop_now)" -lt "$deadline" ]; do
    sleep 0.1
  done
  for member in $tree; do kill_tree "$member"; done
  wait "$pid" 2>/dev/null || rc=$?
  unset "$key" "$time_key"
  return "$rc"
}
