#!/usr/bin/env bash
# Retire the durable records of a task whose endpoint no backend can answer
# for, on an operator's explicit say-so.
#
# Operator-only by construction: nothing in firstmate runs this script, and no
# automatic path can produce what it writes. Cleanup itself never retires such
# a record - bin/fm-teardown.sh's endpoint gates refuse on a stop nothing
# proved, and --force does not lift them - so the records of a task whose
# backend cannot answer would otherwise stay forever. This is the one way they
# are ever retired, and it runs only when a human names them.
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
#
# Retiring a record is RECORD bookkeeping and nothing else. Cleanup runs first,
# because when its own gates allow it, it does the whole job properly. When
# cleanup refuses - unlanded work in the worktree is the ordinary reason - the
# records are still retired and NOTHING on disk is touched: no worktree is
# returned, no branch deleted, no file stashed or discarded. What remains is
# named in the output, because an operator who retires a record must never
# thereby lose work, and must never be left unaware that work is still sitting
# there. That is also why no --force is accepted or forwarded here: discarding
# work is a different authority, exercised with a different command.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"

usage() {
  cat <<'EOF'
usage: fm-retire-endpoint.sh [--override-runtime-refusal] <task-id> [<task-id>...]

Retires the durable records - the task record and its backlog row - of tasks
whose runtime endpoint no backend can answer for, after you confirm the ids by
typing them back.

Use it only when the endpoint is hub-unanswerable: the backend that owned the
worker can no longer say anything about it - a stream hub that was restarted or
rebuilt and no longer has the endpoint - so cleanup can never prove the worker
stopped and keeps refusing.

By naming a record here you assert, from your own inspection of the machine
that ran it, that no worker is still running behind it. Cleanup will not make
that assertion for you, and --force does not make it either.

What this reaches, exactly:

  Cleanup runs first and finishes the job whenever its own gates allow. If
  cleanup refuses - unlanded work in the worktree is the ordinary reason - the
  records are retired anyway and NOTHING on disk is touched. The worktree, any
  uncommitted work in it, the task branch and the task's data are left exactly
  as they are, and are named in the output. Dealing with them is then yours,
  under your own authority: this command never discards work, and never passes
  --force to anything.

  --override-runtime-refusal additionally overrides a RUNTIME's own refusal:
  a herdr server that cannot be reached at all, or a child endpoint whose kill
  nothing answered during forced home cleanup. Without the flag those refusals
  stand and nothing is retired. The override is recorded with your name and the
  time, exactly like the retirement itself.

  A record that lives in another home - a secondmate's own state directory -
  is out of reach from here even with the flag; run this command against that
  home to retire it.

Every id must be named exactly; wildcards and all-records forms are refused.
EOF
}

refuse() {
  echo "error: $1" >&2
  exit 1
}

IDS=()
OVERRIDE_RUNTIME_REFUSAL=0
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --override-runtime-refusal)
      OVERRIDE_RUNTIME_REFUSAL=1
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

NOTE=
cleanup_note() {
  [ -z "$NOTE" ] || rm -f "$NOTE"
  NOTE=
}
trap cleanup_note EXIT INT TERM

echo "About to retire the durable records of:" >&2
for id in "${IDS[@]}"; do
  printf '  %s (endpoint %s)\n' "$id" "$(fm_backend_target_of_meta "$STATE/$id.meta")" >&2
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

# Record bookkeeping only: the task record and its backlog row, through the
# same transition that owns that pairing for cleanup. Nothing here reads or
# writes anything outside the state directory.
retire_records_only() {  # <id>
  local id=$1 meta="$STATE/$id.meta" marker
  marker=$(fm_backlog_close_marker_path "$STATE" "$id") || return 1
  if fm_backlog_row_probe "$DATA" "$id"; then
    fm_backlog_close_marker_write "$STATE" "$id" "$DATA" \
      "$(fm_meta_get "$meta" spawn_gen)" || return 1
    fm_backlog_atomic_transition close "$meta" "$marker" "$DATA" "$id" "$STATE" || return 1
  else
    fm_backlog_atomic_transition remove "$meta" "task record" "$STATE" || return 1
  fi
  rm -f "$STATE/$id.turn-ended" "$STATE/$id.progress"
}

report_what_remains() {  # <id> <worktree>
  local id=$1 wt=$2 remaining=()
  [ -z "$wt" ] || [ ! -d "$wt" ] || remaining+=("$wt")
  [ ! -d "$DATA/$id" ] || remaining+=("$DATA/$id")
  [ "${#remaining[@]}" -gt 0 ] || return 0
  echo "note: $id's records are retired and nothing on disk was touched; these remain for you to handle:" >&2
  printf '  %s\n' "${remaining[@]}" >&2
}

# bin/fm-teardown.sh's own status for a runtime refusal this retirement did
# not override, which is the one refusal that must retire nothing.
RUNTIME_REFUSAL_EXIT=3

retired_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
retired_by=$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")
status=0
for id in "${IDS[@]}"; do
  worktree=$(fm_meta_get "$STATE/$id.meta" worktree)
  NOTE="$STATE/$id.endpoint-retired"
  {
    printf 'id=%s\n' "$id"
    printf 'spawn_gen=%s\n' "$(fm_meta_get "$STATE/$id.meta" spawn_gen)"
    printf 'retired_by=%s\n' "$retired_by"
    printf 'retired_at=%s\n' "$retired_at"
    printf 'runtime_refusal_override=%s\n' "$OVERRIDE_RUNTIME_REFUSAL"
  } > "$NOTE"
  if [ "$OVERRIDE_RUNTIME_REFUSAL" = 1 ]; then
    echo "note: $id is being retired with a runtime refusal overridden by $retired_by at $retired_at" >&2
  fi
  teardown_rc=0
  "$SCRIPT_DIR/fm-teardown.sh" "$id" || teardown_rc=$?
  if [ "$teardown_rc" = 0 ]; then
    echo "note: $id retired; cleanup completed under the retirement recorded for $retired_by at $retired_at" >&2
  elif [ "$teardown_rc" = "$RUNTIME_REFUSAL_EXIT" ]; then
    status=1
    echo "error: $id's runtime refused to answer and this retirement did not override that; nothing was retired - rerun with --override-runtime-refusal if that runtime can never answer for this record again" >&2
  elif retire_records_only "$id"; then
    echo "warning: cleanup for $id did not complete; its records are retired on the retirement recorded for $retired_by at $retired_at, and nothing on disk was touched" >&2
    report_what_remains "$id" "$worktree"
  else
    status=1
    echo "error: $id's records could not be retired ($FM_BACKLOG_TRANSITION_ERROR); inspect $STATE/$id.meta and this task's backlog row before retrying" >&2
  fi
  cleanup_note
done
exit "$status"
