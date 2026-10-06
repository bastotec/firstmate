# shellcheck shell=bash
# fm-remote-control-lib.sh - the parent half of a remote second mate's
# lifecycle control and endpoint binding. Source only.
#
# A remote second mate's agent runs on another host, recorded in this home's
# state/<id>.meta under remote_host=. Its endpoint binding is the remote_*
# namespace, read back from the host's own route
# (bin/fm-remote-secondmate-control.sh route), never guessed here:
#   remote_backend=herdr|stream
#   remote_target=<the host-local endpoint target>
#   remote_herdr_session=fm-remote                 (herdr only)
#   remote_stream_hub=<hub URL the host's agent publishes to>   (stream only)
#   remote_stream_endpoint_id=<32-hex hub endpoint id>          (stream only)
# For stream, the hub is the host's own loopback hub; a parent that reaches the
# same hub through a tunnel sees the same endpoint id there.
#
# fm_remote_control_run is bin/fm-control.sh's remote arm: interrupt, exit, and
# relaunch (including relaunch --backend) run that same control plane on the
# host over bin/fm-on.sh, and a relaunch rewrites this home's binding from the
# host's route afterwards. It reads fm-control.sh's parsed globals.

# fm_remote_route_parse <route-output>: validate one host route. Sets
# FM_REMOTE_ROUTE_BACKEND, _TARGET, _HARNESS, _HERDR_SESSION, _STREAM_HUB,
# _STREAM_ENDPOINT_ID; on refusal returns 1 with FM_REMOTE_ROUTE_ERROR.
fm_remote_route_field() {  # <route-output> <key>
  printf '%s\n' "$1" | sed -n "s/^$2=//p" | tail -1
}

fm_remote_route_parse() {  # <route-output>
  local out=$1
  FM_REMOTE_ROUTE_ERROR=
  FM_REMOTE_ROUTE_BACKEND=$(fm_remote_route_field "$out" backend)
  FM_REMOTE_ROUTE_TARGET=$(fm_remote_route_field "$out" target)
  FM_REMOTE_ROUTE_HARNESS=$(fm_remote_route_field "$out" harness)
  FM_REMOTE_ROUTE_MODEL=$(fm_remote_route_field "$out" model)
  FM_REMOTE_ROUTE_EFFORT=$(fm_remote_route_field "$out" effort)
  FM_REMOTE_ROUTE_HERDR_SESSION=$(fm_remote_route_field "$out" herdr_session)
  FM_REMOTE_ROUTE_STREAM_HUB=$(fm_remote_route_field "$out" stream_hub)
  FM_REMOTE_ROUTE_STREAM_ENDPOINT_ID=$(fm_remote_route_field "$out" stream_endpoint_id)
  [ -n "$FM_REMOTE_ROUTE_TARGET" ] || {
    FM_REMOTE_ROUTE_ERROR="remote route names no endpoint target"
    return 1
  }
  case "$FM_REMOTE_ROUTE_BACKEND" in
    herdr)
      if [ "$FM_REMOTE_ROUTE_HERDR_SESSION" != fm-remote ] \
        || [ "${FM_REMOTE_ROUTE_TARGET%%:*}" != fm-remote ]; then
        FM_REMOTE_ROUTE_ERROR="remote launch returned Herdr session '${FM_REMOTE_ROUTE_HERDR_SESSION:-missing}', expected 'fm-remote'"
        return 1
      fi
      ;;
    stream)
      case "$FM_REMOTE_ROUTE_STREAM_ENDPOINT_ID" in
        ''|*[!0-9a-f]*)
          FM_REMOTE_ROUTE_ERROR="remote route returned no stream endpoint id"
          return 1
          ;;
      esac
      if [ "${FM_REMOTE_ROUTE_TARGET#*:}" != "$FM_REMOTE_ROUTE_STREAM_ENDPOINT_ID" ] \
        || [ -z "$FM_REMOTE_ROUTE_STREAM_HUB" ]; then
        FM_REMOTE_ROUTE_ERROR="remote route's stream target '$FM_REMOTE_ROUTE_TARGET' does not match its endpoint id or names no hub"
        return 1
      fi
      ;;
    *)
      FM_REMOTE_ROUTE_ERROR="remote launch returned backend '${FM_REMOTE_ROUTE_BACKEND:-missing}', expected herdr or stream"
      return 1
      ;;
  esac
}

# The remote_* binding lines for the route fm_remote_route_parse accepted.
fm_remote_route_binding_lines() {
  echo "remote_backend=$FM_REMOTE_ROUTE_BACKEND"
  if [ "$FM_REMOTE_ROUTE_BACKEND" = herdr ]; then
    echo "remote_herdr_session=$FM_REMOTE_ROUTE_HERDR_SESSION"
  else
    echo "remote_stream_hub=$FM_REMOTE_ROUTE_STREAM_HUB"
    echo "remote_stream_endpoint_id=$FM_REMOTE_ROUTE_STREAM_ENDPOINT_ID"
  fi
  echo "remote_target=$FM_REMOTE_ROUTE_TARGET"
}

# Rewrite <meta>'s binding (and harness/model/effort) from the parsed route,
# keeping every other line, under the record lock and one atomic publish.
fm_remote_route_rebind_meta() {  # <meta> <state-dir>
  local meta=$1 state=$2 lock tmp rc=0
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  tmp="$meta.rebind.${BASHPID:-$$}"
  {
    awk -F= '
      BEGIN {
        split("harness model effort remote_backend remote_target remote_herdr_session remote_stream_hub remote_stream_endpoint_id", keys, " ")
        for (i in keys) owned[keys[i]] = 1
      }
      !($1 in owned)
    ' "$meta"
    echo "harness=$FM_REMOTE_ROUTE_HARNESS"
    echo "model=$FM_REMOTE_ROUTE_MODEL"
    echo "effort=$FM_REMOTE_ROUTE_EFFORT"
    fm_remote_route_binding_lines
  } > "$tmp" || rc=1
  if [ "$rc" -eq 0 ] && ! fm_backlog_atomic_transition publish "$tmp" "$meta" "task record" "$state"; then
    rc=1
  fi
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$lock" || true
  return "$rc"
}

# shellcheck disable=SC2153 # META, STATE, ID, VERB, and NEW_* are fm-control.sh's parsed globals.
fm_remote_control_run() {
  local host harness model effort prior_harness out rc route
  local -a args
  host=$(fm_meta_get "$META" remote_host)
  case "$VERB" in
    interrupt|exit)
      rc=0
      "$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh control "$ID" "$VERB" < /dev/null || rc=$?
      [ "$rc" -ne 255 ] || echo "error: remote secondmate $ID on $host is unreachable or the $VERB outcome is unknown" >&2
      return "$rc"
      ;;
    relaunch) ;;
    *)
      echo "error: task $ID is a remotely placed secondmate on $host; '$VERB' is not available for it here, and its missing-endpoint recovery is the secondmate liveness sweep" >&2
      return 1
      ;;
  esac
  # Keep the recorded profile unless the caller names an axis; a backend
  # migration moves the same agent profile to a new endpoint.
  prior_harness=$(fm_meta_get "$META" harness)
  harness=${NEW_HARNESS:-$prior_harness}
  model=${NEW_MODEL:-$(fm_meta_get "$META" model)}
  effort=${NEW_EFFORT:-$(fm_meta_get "$META" effort)}
  if [ "$harness" != "$prior_harness" ]; then
    [ "$MODEL_SET" = 1 ] || model=default
    [ "$EFFORT_SET" = 1 ] || effort=default
  fi
  [ -n "$model" ] || model=default
  [ -n "$effort" ] || effort=default
  [ -n "$harness" ] || { echo "error: task $ID has no recorded harness; pass --harness" >&2; return 1; }
  args=("$ID" "$harness" "$model" "$effort")
  [ "$NEW_BACKEND_SET" = 0 ] || args+=(--backend "$NEW_BACKEND")
  rc=0
  out=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh relaunch "${args[@]}" < /dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ]; then
    [ -z "$out" ] || printf '%s\n' "$out" >&2
    [ "$rc" -ne 255 ] || echo "error: remote secondmate $ID on $host is unreachable or the relaunch outcome is unknown; reconcile with bin/fm-control.sh $ID relaunch once the host answers" >&2
    return "$rc"
  fi
  rc=0
  route=$("$SCRIPT_DIR/fm-on.sh" "$ID" fm-remote-secondmate-control.sh route "$ID" < /dev/null 2>&1) || rc=$?
  if [ "$rc" -ne 0 ] || ! fm_remote_route_parse "$route"; then
    printf '%s\n' "$out"
    echo "error: remote secondmate $ID was relaunched on $host, but its new route could not be read (${FM_REMOTE_ROUTE_ERROR:-exit $rc}); this record still names the previous endpoint" >&2
    return 1
  fi
  if ! fm_remote_route_rebind_meta "$META" "$STATE"; then
    printf '%s\n' "$out"
    echo "error: remote secondmate $ID was relaunched on $host as $FM_REMOTE_ROUTE_BACKEND $FM_REMOTE_ROUTE_TARGET, but this record could not be updated" >&2
    return 1
  fi
  printf '%s\n' "$out"
  echo "rebound $ID remote=$host backend=$FM_REMOTE_ROUTE_BACKEND target=$FM_REMOTE_ROUTE_TARGET"
}
