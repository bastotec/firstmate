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
# Why this rather than an automatic rule, and how it came to exist. The rule
# first asked for was the obvious one for the stream hub: report an endpoint
# gone when a healthy hub's task listing omits it. It was implemented, and then
# reverted, because it is unsafe here - a worker's agent registers exactly once
# and has no way back (docs/stream-backend.md), so a hub restart empties the
# listing while every worker keeps running, and the rule would have read every
# live worker as gone. Reverting it alone would have left every stream record
# unretirable after a hub restart, so this command was authorized in its place.
# No machine on this branch can tell a record the hub pruned from a live worker
# behind a partition. A human looking at the machine can, and this is where
# they say so - which is why the assertion is recorded with their name and the
# time they made it. docs/stream-backend.md carries the operator-facing entry.
#
# Retiring a record is RECORD bookkeeping and nothing else. Cleanup runs first,
# because when its own gates allow it, it does the whole job properly. Exactly
# one of its refusals is proceeded past: the work-protection gate, which runs
# before anything on disk has been touched. Work on disk is not the record this
# retires, so the records are retired and the worktree, its uncommitted work,
# the task branch and the task's data are all left exactly as they were, and
# named in the output - an operator who retires a record must never thereby
# lose work, nor be left unaware that work is still sitting there. That is also
# why no --force is accepted or forwarded here: discarding work is a different
# authority, exercised with a different command.
#
# Every OTHER refusal stands and stops the retirement, because each protects
# something no retirement has a say over: an outcome that never reached the
# parent channel and must stay retryable, a backlog transition that cannot be
# replayed, a runtime that still answers.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
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

  Cleanup runs first and finishes the job whenever its own gates allow. The one
  refusal this proceeds past is cleanup's work-protection gate - unlanded or
  uncommitted work in the worktree - which refuses before anything on disk has
  been touched. The records are then retired and NOTHING on disk is touched:
  the worktree, any uncommitted work in it, the task branch and the task's data
  are left exactly as they are, and are named in the output. Dealing with them
  is then yours, under your own authority: this command never discards work,
  and never passes --force to anything.

  Every other refusal stands and nothing is retired - an outcome that has not
  reached the parent channel, a backlog transition that cannot be replayed, a
  runtime that still answers. Read cleanup's own message and resolve it.

  --override-runtime-refusal additionally overrides a RUNTIME's own refusal to
  answer for this task's endpoint: a herdr server that cannot be reached at
  all. Without the flag that refusal stands and nothing is retired. The
  override is recorded with your name and the time, exactly like the retirement
  itself.

  Every run appends one line to state/endpoint-retirements.log recording your
  ASSERTION - that you, at that time, asserted the named record should be
  retired, and whether the override was used. It is written before anything is
  removed, so nothing is ever removed without it; cleanup may still refuse
  afterwards and retire nothing, and no outcome is written back to the line.

  Out of reach: a record in another home - a secondmate's own state directory -
  must be retired by running this command against that home. A child endpoint
  refused during a parent's forced home cleanup is not reachable at all, from
  here or from that home, because nothing can leave a retirement standing for
  that sweep to read.

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
# An interrupt must ABORT the retirement, not just tidy up after it: without
# the exit, bash runs the handler and carries on into the record removal, so
# the operator's own Ctrl-C would be what retires the records.
abort_on_signal() {
  cleanup_note
  echo "error: interrupted; nothing further was retired" >&2
  exit 130
}
trap cleanup_note EXIT
trap abort_on_signal INT TERM

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
# The deliverable a closed or retained row carries, derived from this task's
# own record exactly as cleanup derives it.
RETIRE_DONE_ARGS=()
retirement_done_args() {  # <id>
  local id=$1 meta="$STATE/$id.meta" kind mode pr data_relative
  RETIRE_DONE_ARGS=()
  kind=$(fm_meta_get "$meta" kind)
  mode=$(fm_meta_get "$meta" mode)
  pr=$(fm_meta_get "$meta" pr)
  case "$kind" in
    scout)
      data_relative=$(fm_backlog_data_relative "$DATA") || return 1
      RETIRE_DONE_ARGS=(--report "$data_relative/$id/report.md")
      ;;
    *)
      if [ "$mode" = local-only ]; then
        RETIRE_DONE_ARGS=(--note "local main")
      elif [ -n "$pr" ]; then
        RETIRE_DONE_ARGS=(--pr "$pr")
      fi
      ;;
  esac
}

# Whether this home's backlog is firstmate's to transition at all is one
# question with one owner: fm_backlog_transition_applies, the gate cleanup
# consults for the same decision. A home that selects manual editing, one that
# keeps no markdown backlog, and a secondmate are all exempt - the record is
# retired and their backlog is left exactly as the operator keeps it, rather
# than hand-edited here or made permanently unretirable by a row read that
# cannot apply.
#
# Both record-only paths clear any pending close this task left behind, the way
# the transition below consumes it, and they clear it BEFORE the record goes.
# A stamped marker outliving its own task record is unresolvable: session-start
# replay reads its endpoint=unconfirmed and refuses, cleanup refuses because
# there is no endpoint metadata left to validate, and this command refuses
# because there is no record to retire. The reverse order is harmless - a
# marker cleared while the record survives leaves replay nothing to replay and
# cleanup free to rerun - so a clear that fails stops the retirement with every
# record still in place.
#
# A row that could not be READ is not an absent row: removing the task record
# behind one would leave the row asserting work in flight that nothing is
# doing, which is this change's own defect wearing the other face. Only a
# not-found answer is absence. A captain-held row takes the retain transition
# with its deliverable, exactly as cleanup and the session-start replay do, so
# a retirement never quietly answers the captain's own question.
retire_records_only() {  # <id>
  local id=$1 meta="$STATE/$id.meta" marker mode=close probe_rc=0 gate_rc=0 marker_flags=()
  fm_backlog_transition_applies "$CONFIG" "$DATA" "$(fm_meta_get "$meta" kind)" || gate_rc=$?
  if [ "$gate_rc" -eq 2 ]; then
    FM_BACKLOG_TRANSITION_ERROR="${FM_BACKLOG_TRANSITION_ERROR:-the backlog data directory is inaccessible}"
    return 1
  fi
  if [ "$gate_rc" -ne 0 ]; then
    echo "note: $id's backlog row is not firstmate's to transition ($FM_BACKLOG_TRANSITION_SKIP); its task record is retired and the backlog is left as it is" >&2
    fm_backlog_close_marker_clear "$STATE" "$id" || return 1
    fm_backlog_atomic_transition remove "$meta" "task record" "$STATE" || return 1
    rm -f "$STATE/$id.turn-ended" "$STATE/$id.progress"
    return 0
  fi
  marker=$(fm_backlog_close_marker_path "$STATE" "$id") || return 1
  retirement_done_args "$id" || return 1
  fm_backlog_row_probe "$DATA" "$id" || probe_rc=$?
  if [ "$probe_rc" -ne 0 ]; then
    if [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
      FM_BACKLOG_TRANSITION_ERROR="${FM_BACKLOG_ROW_ERROR:-the backlog row could not be read}"
      return 1
    fi
    fm_backlog_close_marker_clear "$STATE" "$id" || return 1
    fm_backlog_atomic_transition remove "$meta" "task record" "$STATE" || return 1
    rm -f "$STATE/$id.turn-ended" "$STATE/$id.progress"
    return 0
  fi
  if [ "${FM_BACKLOG_ROW_STATE%% *}" != done ] && [ "$FM_BACKLOG_ROW_HOLD_KIND" = captain ]; then
    mode=retain
    marker_flags=(--retain)
  fi
  fm_backlog_close_marker_write "$STATE" "$id" "$DATA" "$(fm_meta_get "$meta" spawn_gen)" \
    "${marker_flags[@]+"${marker_flags[@]}"}" \
    "${RETIRE_DONE_ARGS[@]+"${RETIRE_DONE_ARGS[@]}"}" || return 1
  fm_backlog_atomic_transition "$mode" "$meta" "$marker" "$DATA" "$id" "$STATE" \
    "${RETIRE_DONE_ARGS[@]+"${RETIRE_DONE_ARGS[@]}"}" || return 1
  rm -f "$STATE/$id.turn-ended" "$STATE/$id.progress"
}

# The work gate refuses BEFORE any kill is attempted, so on this path the
# endpoint was never closed and never read. The record that named it is now
# gone, so this is the last place it is written down: an operator must not be
# left unaware of the one thing that may still be executing.
report_what_remains() {  # <id> <worktree> <endpoint>
  local id=$1 wt=$2 endpoint=$3 remaining=()
  echo "note: $id's records are retired and nothing on disk was touched; no kill was attempted, so its endpoint ${endpoint:-(none recorded)} was neither closed nor checked" >&2
  [ -z "$wt" ] || [ ! -d "$wt" ] || remaining+=("$wt")
  [ ! -d "$DATA/$id" ] || remaining+=("$DATA/$id")
  [ "${#remaining[@]}" -gt 0 ] || return 0
  echo "note: these remain for you to handle:" >&2
  printf '  %s\n' "${remaining[@]}" >&2
}

# bin/fm-teardown.sh's own statuses: the runtime refusal this retirement did
# not override, and the work-protection refusal - the only one it proceeds
# past, raised before anything on disk has been touched.
RUNTIME_REFUSAL_EXIT=71
WORK_GATE_EXIT=72

# The durable answer to "who asserted this stop, and when". The retirement note
# is consumed by the cleanup it authorizes and this command's own output is
# only stderr, so without this line nothing on disk would say who asserted a
# record should be retired once the record itself is gone - the one question an
# incident review asks about this command.
#
# Each line records an ASSERTION, not a completed retirement: it has to be
# appended BEFORE anything is removed, so that no record is ever removed with
# no recorded author, and cleanup can still refuse afterwards and retire
# nothing. A failed append refuses that record outright. One line per
# assertion, append-only, with no outcome written back - it is read by people,
# not by firstmate.
RETIREMENT_LOG="$STATE/endpoint-retirements.log"
record_retirement_assertion() {  # <id>
  printf '%s\tasserted\t%s\tby=%s\toverride_runtime_refusal=%s\n' \
    "$retired_at" "$1" "$retired_by" "$OVERRIDE_RUNTIME_REFUSAL" >> "$RETIREMENT_LOG"
}

retired_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
retired_by=$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")
status=0
for id in "${IDS[@]}"; do
  worktree=$(fm_meta_get "$STATE/$id.meta" worktree)
  endpoint=$(fm_backend_target_of_meta "$STATE/$id.meta")
  if ! record_retirement_assertion "$id"; then
    status=1
    echo "error: the assertion that $id should be retired could not be recorded in $RETIREMENT_LOG; nothing was retired - a record is never removed without a durable author" >&2
    continue
  fi
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
  elif [ "$teardown_rc" != "$WORK_GATE_EXIT" ]; then
    status=1
    echo "error: cleanup for $id refused (status $teardown_rc) for a reason this retirement does not answer for; nothing was retired - cleanup's own message above says what it is protecting" >&2
  elif retire_records_only "$id"; then
    echo "warning: cleanup for $id refused over the work in its worktree, before touching anything on disk; its records are retired on the retirement recorded for $retired_by at $retired_at" >&2
    report_what_remains "$id" "$worktree" "$endpoint"
  else
    status=1
    echo "error: $id's records could not be retired ($FM_BACKLOG_TRANSITION_ERROR); inspect $STATE/$id.meta and this task's backlog row before retrying" >&2
  fi
  cleanup_note
done
exit "$status"
