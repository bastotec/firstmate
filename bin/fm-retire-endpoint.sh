#!/usr/bin/env bash
# Retire the durable records of a task whose endpoint no backend can answer
# for, on an operator's explicit say-so.
#
# Operator-only by construction: nothing in firstmate runs this script, and no
# automatic path can produce what it writes. Cleanup itself never retires such
# a record - bin/fm-teardown.sh's require_task_endpoint_gone refuses on a stop
# nothing proved, and --force does not lift that refusal - so the records of a
# task whose backend cannot answer would otherwise stay forever. This is the
# one way they are ever retired, and it runs only when a human names them.
#
# Why this rather than an automatic rule. The obvious one for the stream hub -
# report an endpoint gone when a healthy hub's task listing omits it - is
# unsafe here: a worker's agent registers exactly once and has no way back
# (docs/stream-backend.md), so a hub restart empties the listing while every
# worker keeps running, and that rule would read every live worker as gone.
# That is the same unsafety as the settled-hub qualification this branch
# already reverted. No machine on this branch can tell a record the hub pruned
# from a live worker behind a partition. A human looking at the machine can,
# and this is where they say so - which is why the assertion is recorded with
# their name and the time they made it.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-retire-endpoint.sh <task-id> [<task-id>...]

Retires the durable records of tasks whose runtime endpoint no backend can
answer for, after you confirm the ids by typing them back.

Use it only when the endpoint is hub-unanswerable: the backend that owned the
worker can no longer say anything about it - a stream hub that was restarted or
rebuilt and no longer has the endpoint, a runtime that is gone for good - so
cleanup can never prove the worker stopped and keeps refusing.

By naming a record here you assert, from your own inspection of the machine
that ran it, that no worker is still running behind it. Cleanup will not make
that assertion for you, and --force does not make it either.

Every id must be named exactly; wildcards and all-records forms are refused.
Your username and the time are recorded with each retirement.
EOF
}

refuse() {
  echo "error: $1" >&2
  exit 1
}

IDS=()
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    *[][*?]*)
      refuse "refusing '$arg': name each task id exactly - a wildcard or all-records form cannot say which workers you inspected"
      ;;
    -*)
      refuse "unknown option '$arg'"
      ;;
    *)
      fm_task_id_path_safe "$arg" || refuse "invalid task id '$arg'"
      IDS+=("$arg")
      ;;
  esac
done

[ "${#IDS[@]}" -gt 0 ] || {
  usage >&2
  refuse "name at least one task id to retire"
}

for id in "${IDS[@]}"; do
  [ -f "$STATE/$id.meta" ] && [ ! -L "$STATE/$id.meta" ] \
    || refuse "no durable task record at $STATE/$id.meta, so there is nothing to retire for '$id'"
done

echo "About to retire the durable records of:" >&2
for id in "${IDS[@]}"; do
  printf '  %s (endpoint %s)\n' "$id" "$(fm_meta_get "$STATE/$id.meta" window)" >&2
done
printf 'Type those ids to confirm no worker is still running behind them: ' >&2
typed=
IFS= read -r typed || typed=
set -f
# shellcheck disable=SC2086 # deliberate: collapse the operator's spacing before comparing.
set -- $typed
set +f
[ "$*" = "${IDS[*]}" ] \
  || refuse "the ids typed back do not match the ids named; nothing was retired"

retired_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
retired_by=$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")
status=0
for id in "${IDS[@]}"; do
  note="$STATE/$id.endpoint-retired"
  {
    printf 'id=%s\n' "$id"
    printf 'spawn_gen=%s\n' "$(fm_meta_get "$STATE/$id.meta" spawn_gen)"
    printf 'retired_by=%s\n' "$retired_by"
    printf 'retired_at=%s\n' "$retired_at"
  } > "$note"
  if ! "$SCRIPT_DIR/fm-teardown.sh" "$id"; then
    status=1
    echo "error: cleanup for $id did not complete; its records are unchanged and the retirement was discarded" >&2
  fi
  rm -f "$note"
done
exit "$status"
