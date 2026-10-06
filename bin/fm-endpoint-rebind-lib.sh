#!/usr/bin/env bash
# fm-endpoint-rebind-lib.sh - point one task record at a different runtime
# endpoint, keeping everything else about the task.
#
# fm_endpoint_rebind_meta <meta> <task-id> <backend> <window> [key=value...]
#   Rewrites <meta> so it names exactly one endpoint. Every endpoint-identity
#   line - window=, backend=, and each backend's own identity keys (herdr_*,
#   zellij_*, cmux_*, orca_worktree_id=, terminal=, stream_hub=,
#   stream_endpoint_id=) - is dropped, and window=<window>, backend=<backend>,
#   and the given key=value lines are appended. Every other line (worktree,
#   harness, kind, spawn_gen, endpoint_task_id, ...) is kept in order, so the
#   task keeps its worktree, session, and identity and only its endpoint moves.
#
#   Callers: bin/fm-control.sh recover-missing on stream, which has to record
#   the NEW agent-generated endpoint for a task whose old one is gone, and any
#   verb that moves a task between backends.
#
#   Runs under the record's own meta lock (bin/fm-wake-lib.sh's
#   fm_meta_lock_path, the lock fm-spawn.sh publishes under), so it must not be
#   called while the caller already holds that lock. The replace is atomic (a
#   temporary file in the same directory, then mv). Refuses, with
#   FM_ENDPOINT_REBIND_ERROR set and the record untouched: a record that is not
#   a regular file, one whose endpoint_task_id= is not exactly <task-id>, a
#   backend bin/fm-backend.sh does not know, an empty or multi-line window, and
#   any extra line that is not key=value for an endpoint-identity key.
#
# Requires bin/fm-backend.sh and bin/fm-wake-lib.sh to be sourced.

FM_ENDPOINT_REBIND_ERROR=

# fm_endpoint_rebind_is_endpoint_key: whether <key> names a runtime endpoint
# rather than the task.
fm_endpoint_rebind_is_endpoint_key() {  # <key>
  case "$1" in
    window|backend|herdr_*|zellij_*|cmux_*|orca_worktree_id|terminal|stream_hub|stream_endpoint_id) return 0 ;;
  esac
  return 1
}

fm_endpoint_rebind_meta() {  # <meta> <task-id> <backend> <window> [key=value...]
  local meta=$1 id=$2 backend=$3 window=$4 lock tmp line key extra
  shift 4
  FM_ENDPOINT_REBIND_ERROR=
  fm_backend_validate "$backend" 2>/dev/null || {
    FM_ENDPOINT_REBIND_ERROR="unknown backend '$backend'"
    return 1
  }
  case "$window" in
    ''|*$'\n'*) FM_ENDPOINT_REBIND_ERROR="the new endpoint target is empty or malformed"; return 1 ;;
  esac
  for extra in "$@"; do
    key=${extra%%=*}
    case "$extra" in
      *$'\n'*) FM_ENDPOINT_REBIND_ERROR="endpoint line '$key' spans lines"; return 1 ;;
    esac
    if [ "$key" = "$extra" ] || ! fm_endpoint_rebind_is_endpoint_key "$key" \
      || [ "$key" = window ] || [ "$key" = backend ]; then
      FM_ENDPOINT_REBIND_ERROR="'$extra' is not an endpoint identity line"
      return 1
    fi
  done
  lock=$(fm_meta_lock_path "$meta") || {
    FM_ENDPOINT_REBIND_ERROR="$meta is not a task record path"
    return 1
  }
  fm_lock_acquire_wait "$lock"
  if [ -L "$meta" ] || [ ! -f "$meta" ]; then
    FM_ENDPOINT_REBIND_ERROR="$meta is not a regular task record"
  elif [ "$(fm_meta_get "$meta" endpoint_task_id)" != "$id" ]; then
    FM_ENDPOINT_REBIND_ERROR="$meta is not bound to task $id (endpoint_task_id differs)"
  fi
  if [ -z "$FM_ENDPOINT_REBIND_ERROR" ]; then
    tmp="$meta.rebind.$$"
    if {
      while IFS= read -r line || [ -n "$line" ]; do
        key=${line%%=*}
        if [ "$key" != "$line" ] && fm_endpoint_rebind_is_endpoint_key "$key"; then
          continue
        fi
        printf '%s\n' "$line"
      done < "$meta"
      printf 'window=%s\n' "$window"
      printf 'backend=%s\n' "$backend"
      for extra in "$@"; do
        printf '%s\n' "$extra"
      done
    } > "$tmp" && mv -f "$tmp" "$meta"; then
      :
    else
      rm -f "$tmp"
      FM_ENDPOINT_REBIND_ERROR="$meta could not be rewritten"
    fi
  fi
  fm_lock_release "$lock"
  [ -z "$FM_ENDPOINT_REBIND_ERROR" ]
}
