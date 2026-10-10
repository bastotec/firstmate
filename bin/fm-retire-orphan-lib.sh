#!/usr/bin/env bash
# fm-retire-orphan-lib.sh - close a stream endpoint whose task record is gone.
#
# Sourced only by bin/fm-retire-endpoint.sh for --orphan and --list-orphans,
# which own the argument checks, including the explicit FM_HOME. Callers have
# STATE, DATA, SCRIPT_DIR and bin/fm-backend.sh / bin/fm-wake-lib.sh loaded.
#
# A leftover is an endpoint the hub still lists live for task <id> after this
# home's state/<id>.meta is gone, for example when a captain decision removed
# the record. Nothing else can close it: cleanup, control and retirement all
# start from that record. This closes one, and only when every check holds:
#
#   1. No task record: state/<id>.meta does not exist, and <id> is not a
#      registered secondmate (a persistent home is never closed from here).
#   2. Ownership: the endpoint is proved to be THIS home's by evidence bound to
#      its exact endpoint id, never by its label alone:
#      state/<id>.inbox/deck-<endpoint-id>/ exists in this home, created by the
#      endpoint's own agent from the --status-path this home gave it.
#      The hub's label must also be fm-<id>. A label match with no such
#      evidence, or evidence from another home's state directory, is refused.
#   3. Nothing running or pending: the hub's process reading says the harness
#      is gone (only a shell, or the agent reported the exit), or the harness
#      is alive but its Deck turn record says no turn is active and the task
#      inbox holds no unhandled message. A stale, unreadable or ambiguous
#      reading is refused. The final reading holds the Deck lifecycle lock,
#      but releases it immediately before the kill so the agent can persist
#      and acknowledge the result. A turn can still start in that narrow
#      unlocked window; this check and close are not an atomic transition.
#   4. No unlanded work: the endpoint's live working directory must be
#      readable. If it is a linked worktree, and for every worktree of the
#      registered project whose Treehouse slot claim names <id>, there must be
#      no uncommitted change and no commit missing from every remote branch.
#      A project's own primary clone is not a task worktree and is not judged.
#      As in cleanup, a finished scout's worktree is scratch: when this home's
#      backlog row for <id> is a done scout and data/<id>/report.md exists, a
#      worktree that is its own (or unclaimed) is logged as scratch, not judged.
#
# Every close first appends one assertion line, basis=orphan-endpoint with its
# evidence, to state/endpoint-retirements.log; a line that cannot be written
# closes nothing. Closing is the backend's own kill (bin/backends/stream.sh's
# fm_backend_stream_kill) with the expected label, and only a close its agent
# acknowledged reports success. No file, worktree, branch or backlog row is
# touched. Any check that cannot be proved refuses with a plain reason, which
# is the captain's decision.
#
# --list-orphans is read-only. It looks only at this home's own records - its
# state/<id>.inbox/deck-* directories - for ids with no task record, and
# prints "<id>\t<endpoint-id>"
# for each endpoint the hub still lists live and the ownership check proves.

# shellcheck disable=SC2153 # STATE and DATA are set by the sourcing script.
ORPHAN_EVIDENCE=
ORPHAN_HUB_CWD=

orphan_clean() {
  LC_ALL=C tr '\t\r\n' '   '
}

orphan_is_hex() {
  case "$1" in ''|*[!0-9a-f]*) return 1 ;; esac
}

orphan_record_exists() {  # <id>
  [ -e "$STATE/$1.meta" ] || [ -L "$STATE/$1.meta" ]
}

orphan_is_secondmate() {  # <id>
  local line
  [ -f "$DATA/secondmates.md" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "- $1 - "*) return 0 ;; esac
  done < "$DATA/secondmates.md"
  return 1
}

# Task ids this home's own records tie to an endpoint, with no task record.
orphan_candidate_ids() {
  local dir id
  {
    for dir in "$STATE"/*.inbox/deck-*; do
      [ -d "$dir" ] || continue
      id=${dir%/deck-*}
      id=${id##*/}
      printf '%s\n' "${id%.inbox}"
    done
  } | while IFS= read -r id; do
    fm_task_id_path_safe "$id" || continue
    orphan_record_exists "$id" && continue
    printf '%s\n' "$id"
  done | LC_ALL=C sort -u
}

# Candidate endpoint ids for <id>: this home's deck directories, plus live hub
# endpoints labeled fm-<id> on this machine (a candidate only, which the
# ownership check must still prove).
orphan_candidate_endpoints() {  # <id>
  local id=$1 dir machine
  {
    for dir in "$STATE/$id.inbox"/deck-*; do
      [ -d "$dir" ] || continue
      printf '%s\n' "${dir##*/deck-}"
    done
    machine=$(fm_backend_stream_machine) || machine=
    fm_backend_stream_list_live 2>/dev/null \
      | awk -F '\t' -v m="$machine" -v l="fm-$id" '$1 == m && $2 == l { print $3 }'
  } | while IFS= read -r eid; do
    orphan_is_hex "$eid" && printf '%s\n' "$eid"
  done | LC_ALL=C sort -u
}

# Reads the hub's record of <eid> and proves it is <id>'s endpoint in this
# home. Returns 0 proved live, 1 not proved (ORPHAN_REASON says why), 2 the hub
# could not be read, 3 the hub lists it but it is already closed.
ORPHAN_REASON=
orphan_prove() {  # <id> <eid>
  local id=$1 eid=$2 out rc=0 label closed
  ORPHAN_EVIDENCE=
  ORPHAN_REASON=
  out=$(fm_backend_stream_api GET "/v1/tasks/$eid" 2>/dev/null) || rc=$?
  if [ "$rc" -eq 3 ]; then
    ORPHAN_REASON="the hub has no endpoint $eid"
    return 1
  elif [ "$rc" -ne 0 ]; then
    ORPHAN_REASON="the hub could not be read about endpoint $eid"
    return 2
  fi
  label=$(printf '%s' "$out" | jq -r '.task.label // empty' 2>/dev/null) || label=
  ORPHAN_HUB_CWD=$(printf '%s' "$out" | jq -r '.task.cwd // empty' 2>/dev/null) || ORPHAN_HUB_CWD=
  closed=$(printf '%s' "$out" | jq -r '.task.closed_at // empty' 2>/dev/null) || closed=
  if [ "$label" != "fm-$id" ]; then
    ORPHAN_REASON="endpoint $eid carries label '${label:-(none)}', not fm-$id"
    return 1
  fi
  if [ -d "$STATE/$id.inbox/deck-$eid" ] && [ ! -L "$STATE/$id.inbox/deck-$eid" ]; then
    ORPHAN_EVIDENCE="home-record:$id.inbox/deck-$eid"
  else
    ORPHAN_REASON="nothing in this home ties endpoint $eid to it - no state/$id.inbox/deck-$eid record - so a matching label alone is not ownership"
    return 1
  fi
  [ -z "$closed" ] || return 3
  return 0
}

# The one live endpoint this home owns for <id>, in ORPHAN_ENDPOINT_ID.
ORPHAN_ENDPOINT_ID=
orphan_resolve() {  # <id> [eid]
  local id=$1 want=${2:-} eid rc proved=() reasons=() evidence=() closed=0
  ORPHAN_ENDPOINT_ID=
  local candidates
  if [ -n "$want" ]; then
    candidates=$want
  else
    candidates=$(orphan_candidate_endpoints "$id")
  fi
  [ -n "$candidates" ] || refuse "this home has no record of an endpoint for '$id' and the hub lists none labeled fm-$id on this machine; nothing to close"
  while IFS= read -r eid; do
    [ -n "$eid" ] || continue
    rc=0
    orphan_prove "$id" "$eid" || rc=$?
    case "$rc" in
      0) proved+=("$eid"); evidence+=("$ORPHAN_EVIDENCE") ;;
      2) refuse "$ORPHAN_REASON; nothing was closed" ;;
      3) closed=$((closed + 1)) ;;
      *) reasons+=("$ORPHAN_REASON") ;;
    esac
  done <<< "$candidates"
  if [ "${#proved[@]}" -eq 0 ]; then
    if [ "$closed" -gt 0 ] && [ "${#reasons[@]}" -eq 0 ]; then
      echo "note: $id's endpoint is already closed on the hub; nothing to do" >&2
      exit 0
    fi
    [ "${#reasons[@]}" -gt 0 ] || reasons=("no candidate could be proved to be this home's")
    refuse "refusing to close an endpoint for '$id': ${reasons[*]}"
  fi
  [ "${#proved[@]}" -eq 1 ] \
    || refuse "this home owns ${#proved[@]} live endpoints for '$id' (${proved[*]}); name one with --endpoint"
  ORPHAN_ENDPOINT_ID=${proved[0]}
  ORPHAN_EVIDENCE=${evidence[0]}
  # Re-read the proved endpoint so the hub fields describe it, not the last candidate.
  orphan_prove "$id" "$ORPHAN_ENDPOINT_ID" >/dev/null 2>&1 || true
}

# Nothing running, or an idle harness with nothing pending. Sets ORPHAN_AGENT.
ORPHAN_AGENT=
orphan_check_idle() {  # <id> <target>
  local id=$1 target=$2 active msg
  ORPHAN_AGENT=$(fm_backend_stream_agent_state "$target")
  case "$ORPHAN_AGENT" in
    dead|alive) ;;
    *) refuse "the hub's reading of $id's agent is '$ORPHAN_AGENT', so nothing proves it is stopped or idle; nothing was closed" ;;
  esac
  active=$(jq -r 'if .active == false then "idle" elif .active == true then "busy" else "unknown" end' \
    "$STATE/$id.inbox/deck-$ORPHAN_ENDPOINT_ID/active.json" 2>/dev/null) || active=unknown
  case "$active" in
    busy) refuse "$id's agent is running a turn right now, so it is busy; nothing was closed" ;;
    idle) [ "$ORPHAN_AGENT" != alive ] || ORPHAN_AGENT=alive-idle ;;
    *)
      [ "$ORPHAN_AGENT" = dead ] \
        || refuse "$id's agent is still running and nothing in this home records that its turn ended, so it cannot be proved idle; nothing was closed"
      ;;
  esac
  for msg in "$STATE/$id.inbox"/*.msg; do
    [ -e "$msg" ] || continue
    refuse "$id's inbox still holds an unhandled message (${msg##*/}), so work is pending; nothing was closed"
  done
}

# A finished scout's worktree is scratch, exactly as cleanup treats it: this
# home's backlog row for <id> is a done scout and its report exists.
orphan_finished_scout() {  # <id>
  local id=$1 data out
  [ -f "$DATA/$id/report.md" ] || return 1
  data=$(fm_backlog_data_absolute "$DATA" 2>/dev/null) || return 1
  out=$(fm_backlog_row_show "$data" "$id" 2>/dev/null) || return 1
  [ "$(printf '%s\n' "$out" | sed -n 's/^  state: *//p' | head -1)" = "done" ] || return 1
  [ "$(printf '%s\n' "$out" | sed -n 's/^  kind: *//p' | head -1)" = scout ]
}

# Refuses on uncommitted or unlanded work in a worktree tied to the endpoint.
# A finished scout's own scratch is not unlanded work, but a worktree whose
# slot claim names another task is that task's, so it is judged in full.
ORPHAN_WORKTREES=
ORPHAN_SCRATCH=0
orphan_judge_worktree() {  # <id> <worktree> <why>
  local id=$1 wt=$2 why=$3 dirty ahead
  if [ "$ORPHAN_SCRATCH" = 1 ]; then
    fm_treehouse_slot_owner_state "$wt" "$id"
    case "$FM_TREEHOUSE_SLOT_OWNER" in
      mine|absent)
        ORPHAN_WORKTREES="${ORPHAN_WORKTREES:+$ORPHAN_WORKTREES,}$wt(finished-scout-scratch)"
        return 0
        ;;
    esac
  fi
  dirty=$(git -C "$wt" status --porcelain 2>/dev/null) \
    || refuse "the worktree $wt ($why) cannot be read, so nothing proves it holds no unlanded work; nothing was closed"
  [ -z "$dirty" ] \
    || refuse "the worktree $wt ($why) has uncommitted changes; nothing was closed"
  git -C "$wt" rev-parse --verify -q HEAD >/dev/null 2>&1 \
    || refuse "the worktree $wt ($why) has no readable HEAD, so its landed work cannot be proved; nothing was closed"
  ahead=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) \
    || refuse "the worktree $wt ($why) cannot be compared with its remotes; nothing was closed"
  [ "$ahead" = 0 ] \
    || refuse "the worktree $wt ($why) has $ahead commit(s) on no remote branch, so its work has not landed; nothing was closed"
  ORPHAN_WORKTREES="${ORPHAN_WORKTREES:+$ORPHAN_WORKTREES,}$wt"
}

orphan_git_repository() {
  local cwd=$1 out ancestor
  [ -d "$cwd" ] && [ -r "$cwd" ] && [ -x "$cwd" ] \
    || refuse "directory $cwd cannot be inspected for associated worktrees; nothing was closed"
  if out=$(LC_ALL=C git -C "$cwd" rev-parse --is-inside-work-tree 2>&1); then
    case "$out" in true|false) return 0 ;; esac
  else
    case "$out" in
      'fatal: not a git repository (or any of the parent directories): .git')
        ancestor=$(cd "$cwd" && pwd -P) \
          || refuse "directory $cwd cannot be resolved; nothing was closed"
        while :; do
          [ -r "$ancestor" ] && [ -x "$ancestor" ] \
            || refuse "Git ancestry of $cwd cannot be inspected at $ancestor; nothing was closed"
          if [ -e "$ancestor/.git" ] || [ -L "$ancestor/.git" ] \
            || { [ -e "$ancestor/HEAD" ] && [ -d "$ancestor/objects" ]; }; then
            refuse "Git cannot classify $cwd despite repository evidence at $ancestor; nothing was closed"
          fi
          [ "$ancestor" != / ] || return 1
          ancestor=${ancestor%/*}
          [ -n "$ancestor" ] || ancestor=/
        done
        ;;
    esac
  fi
  refuse "Git cannot classify $cwd: $out; nothing was closed"
}

orphan_check_worktrees() {  # <id> <target>
  local id=$1 target=$2 cwd top git_dir common line wt inventory
  ORPHAN_WORKTREES=
  ORPHAN_SCRATCH=0
  ! orphan_finished_scout "$id" || ORPHAN_SCRATCH=1
  cwd=$(fm_backend_stream_current_path "$target" "fm-$id" 2>/dev/null) \
    || refuse "the hub cannot say which directory $id's endpoint is in, so nothing proves no unlanded work sits behind it; nothing was closed"
  [ -d "$cwd" ] \
    || refuse "$id's endpoint is in $cwd, which this machine cannot inspect for unlanded work; nothing was closed"
  if orphan_git_repository "$cwd"; then
    top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null) \
      || refuse "Git cannot locate the worktree behind $cwd; nothing was closed"
    git_dir=$(git -C "$top" rev-parse --path-format=absolute --git-dir 2>/dev/null) \
      || refuse "Git cannot classify the worktree directory for $top; nothing was closed"
    common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) \
      || refuse "Git cannot classify the common directory for $top; nothing was closed"
    if [ "$git_dir" != "$common" ]; then
      orphan_judge_worktree "$id" "$top" "the endpoint's working directory"
    fi
  fi
  [ -n "$ORPHAN_HUB_CWD" ] \
    || refuse "the hub has no registered directory for $id to inspect for slot claims; nothing was closed"
  if orphan_git_repository "$ORPHAN_HUB_CWD"; then
    inventory=$(git -C "$ORPHAN_HUB_CWD" worktree list --porcelain 2>/dev/null) \
      || refuse "Git cannot enumerate associated worktrees from $ORPHAN_HUB_CWD; nothing was closed"
    [ -n "$inventory" ] \
      || refuse "Git returned no associated worktree inventory for $ORPHAN_HUB_CWD; nothing was closed"
    while IFS= read -r line; do
      case "$line" in worktree\ *) wt=${line#worktree } ;; *) continue ;; esac
      [ -d "$wt" ] && [ -r "$wt" ] && [ -x "$wt" ] \
        || refuse "associated worktree $wt cannot be inspected for slot claims; nothing was closed"
      fm_treehouse_slot_owner_state "$wt" "$id"
      case "$FM_TREEHOUSE_SLOT_OWNER" in
        mine) ;;
        absent|other) continue ;;
        *) refuse "the slot ownership claim for worktree $wt cannot be read safely, so its association with $id is unprovable; nothing was closed" ;;
      esac
      case ",$ORPHAN_WORKTREES," in *",$wt,"*|*",$wt(finished-scout-scratch),"*) continue ;; esac
      orphan_judge_worktree "$id" "$wt" "its slot claim names $id"
    done <<< "$inventory"
  fi
}

orphan_close() {  # <id> [eid]
  local id=$1 want=${2:-} tag target context declarations
  fm_backend_source stream || refuse "the stream backend could not be loaded"
  orphan_record_exists "$id" \
    && refuse "'$id' still has a task record at $STATE/$id.meta; clean it up with bin/fm-teardown.sh, not as a leftover"
  orphan_is_secondmate "$id" \
    && refuse "'$id' is a registered secondmate; a persistent home is retired only on an explicit decision, never as a leftover"
  orphan_resolve "$id" "$want"
  tag=$(fm_backend_stream_hub_tag) || refuse "this home's hub address cannot be resolved"
  target="$tag:$ORPHAN_ENDPOINT_ID"
  orphan_check_idle "$id" "$target"
  orphan_check_worktrees "$id" "$target"
  context=$(declare -p SCRIPT_DIR STATE DATA)
  declarations=$(declare -p ORPHAN_ENDPOINT_ID ORPHAN_WORKTREES)
  python3 - "$STATE/$id.inbox/deck-$ORPHAN_ENDPOINT_ID/.lifecycle.lock" "$context" "$declarations" "$id" "$target" <<'PY'
import fcntl
import subprocess
import sys

try:
    with open(sys.argv[1], 'a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        command = sys.argv[2] + '''
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
. "$SCRIPT_DIR/fm-retire-orphan-lib.sh"
''' + sys.argv[3] + '''
fm_backend_source stream || exit 1
refuse() { echo "error: $1" >&2; exit 1; }
orphan_close_locked "$1" "$2" "$3"
'''
        result = subprocess.run(['bash', '-euo', 'pipefail', '-c', command,
                                 'orphan-close', *sys.argv[4:], str(lock.fileno())],
                                pass_fds=(lock.fileno(),))
        sys.exit(result.returncode if result.returncode >= 0 else 1)
except OSError as error:
    print(f'error: endpoint lifecycle could not be locked: {error}; nothing was closed', file=sys.stderr)
    sys.exit(1)
PY
}

orphan_close_locked() {
  local id=$1 target=$2 at by rc=0 inbox_lock="$STATE/$1.inbox/.seq.lock"
  fm_task_inbox_lock_acquire "$inbox_lock" \
    || refuse "$id's inbox publication could not be locked; nothing was closed"
  trap "$(printf 'fm_lock_release %q' "$inbox_lock")" EXIT
  orphan_record_exists "$id" \
    && refuse "'$id' now has a task record; nothing was closed"
  orphan_is_secondmate "$id" \
    && refuse "'$id' is now a registered secondmate; nothing was closed"
  orphan_prove "$id" "$ORPHAN_ENDPOINT_ID" \
    || refuse "endpoint ownership or liveness changed: $ORPHAN_REASON; nothing was closed"
  orphan_check_idle "$id" "$target"
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  by=$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")
  printf '%s\tasserted\t%s\tby=%s\tbasis=orphan-endpoint\tendpoint=%s\tevidence=%s\tagent=%s\tworktrees=%s\n' \
    "$at" "$id" "$by" "$target" \
    "$(printf '%s' "$ORPHAN_EVIDENCE" | orphan_clean)" "$ORPHAN_AGENT" \
    "$(printf '%s' "${ORPHAN_WORKTREES:-none}" | orphan_clean)" >> "$STATE/endpoint-retirements.log" \
    || refuse "the assertion for $id could not be recorded in $STATE/endpoint-retirements.log; nothing was closed - an endpoint is never closed without a durable author"
  python3 -c 'import fcntl, sys; fcntl.flock(int(sys.argv[1]), fcntl.LOCK_UN)' "$3"
  fm_backend_stream_kill "$target" "" "fm-$id" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "error: the hub did not confirm that $id's endpoint $ORPHAN_ENDPOINT_ID closed; it may still be running" >&2
    return 1
  fi
  echo "note: closed $id's leftover endpoint $ORPHAN_ENDPOINT_ID ($ORPHAN_EVIDENCE; agent $ORPHAN_AGENT; worktrees ${ORPHAN_WORKTREES:-none}); its files and worktrees are untouched" >&2
}

orphan_list() {
  local id eid rc candidates
  fm_backend_source stream || refuse "the stream backend could not be loaded"
  fm_backend_stream_api GET /v1/tasks >/dev/null 2>&1 \
    || refuse "the hub cannot be read, so no leftover endpoint can be listed"
  candidates=$(orphan_candidate_ids)
  [ -n "$candidates" ] || return 0
  while IFS= read -r id; do
    orphan_is_secondmate "$id" && continue
    while IFS= read -r eid; do
      [ -n "$eid" ] || continue
      rc=0
      orphan_prove "$id" "$eid" || rc=$?
      [ "$rc" -eq 0 ] && printf '%s\t%s\n' "$id" "$eid"
    done < <(orphan_candidate_endpoints "$id")
  done <<< "$candidates"
  return 0
}
