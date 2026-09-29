#!/usr/bin/env bash
set -eu
D=/Users/bastotecnologia/.no-mistakes/worktrees/5a1fd3284f12/01M3Q2CVXNFM8FR64YHCHYYB7T/.no-mistakes/live-reply-isolation
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) shift 2 ;;
    --) shift; break ;;
    *) exit 90 ;;
  esac
done
[ "$1" = live-synthetic ] || exit 91
[ "$2" = fm-remote-entrypoint.sh ] || exit 92
shift 2
PORT=$(< "$D/port")
exec /usr/bin/ssh -F /dev/null -p "$PORT" -i "$D/client-key" \
  -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=yes \
  -o UserKnownHostsFile="$D/known_hosts" -o GlobalKnownHostsFile=/dev/null \
  -o UpdateHostKeys=no -o ControlMaster=no -o ControlPath=none \
  -o ForwardAgent=no -o ClearAllForwardings=yes -o 'SendEnv=-*' \
  -- bastotecnologia@127.0.0.1 /usr/bin/env \
  "FM_REMOTE_JOB_PLATFORM_OVERRIDE=Linux" \
  "FM_REMOTE_JOB_STATE_ROOT=$D/runtime/jobs" \
  "TMPDIR=$D/runtime/tmp" \
  "$D/code/bin/fm-remote-entrypoint.sh" "$@"
