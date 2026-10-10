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
#      its exact endpoint id, never by its label alone. Either
#        - state/<id>.inbox/deck-<endpoint-id>/ exists in this home: the
#          endpoint's own agent creates it from the --status-path this home
#          gave it, and only that agent knows the random endpoint id; or
#        - a stream agent process on this machine carries this home's
#          `--status-path <state>/<id>.status` together with the hub's own
#          machine, label and registered cwd for that endpoint.
#      The hub's label must also be fm-<id>. A label match with no such
#      evidence, or evidence from another home's state directory, is refused.
#   3. Nothing running or pending: the hub's process reading says the harness
#      is gone (only a shell, or the agent reported the exit), or the harness
#      is alive but its Deck turn record says no turn is active and the task
#      inbox holds no unhandled message. A stale, unreadable or ambiguous
#      reading is refused.
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
# state/<id>.inbox/deck-* directories and local agents carrying this home's
# status paths - for ids with no task record, and prints "<id>\t<endpoint-id>"
# for each endpoint the hub still lists live and the ownership check proves.

# shellcheck disable=SC2153 # STATE and DATA are set by the sourcing script.
ORPHAN_EVIDENCE=
ORPHAN_HUB_CWD=
ORPHAN_HUB_MACHINE=

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

# Local stream agent command lines, one per line, unflattened as ps prints them.
orphan_agent_lines() {
  local bin=${FM_BACKEND_STREAM_AGENT_BIN##*/}
  LC_ALL=C ps -eo pid=,args= 2>/dev/null \
    | awk -v bin="$bin" 'index($0, "fm-stream-agent") > 0 || (bin != "" && index($0, bin) > 0)'
}

# Prints the pid of a local agent that carries this home's status path for
# <id> together with the hub's machine, label and cwd for the endpoint.
# create_task passes those options adjacently and in this order, and the whole
# run is matched as one substring so a path holding spaces still binds exactly.
orphan_agent_proof() {  # <id> <machine> <cwd>
  local id=$1 machine=$2 cwd=$3 needle line
  needle=" --machine $machine --label fm-$id --cwd $cwd --status-path $STATE/$id.status --"
  while IFS= read -r line; do
    case "$line --" in
      *"$needle"*)
        line=${line#"${line%%[![:space:]]*}"}
        printf '%s' "${line%% *}"
        return 0
        ;;
    esac
  done < <(orphan_agent_lines)
  return 1
}

# Task ids this home's own records tie to an endpoint, with no task record.
orphan_candidate_ids() {
  local dir id line rest
  {
    for dir in "$STATE"/*.inbox/deck-*; do
      [ -d "$dir" ] || continue
      id=${dir%/deck-*}
      id=${id##*/}
      printf '%s\n' "${id%.inbox}"
    done
    while IFS= read -r line; do
      rest=${line#*" --status-path $STATE/"}
      [ "$rest" != "$line" ] || continue
      case "$rest" in
        *.status\ --*) printf '%s\n' "${rest%%.status --*}" ;;
        *.status) printf '%s\n' "${rest%.status}" ;;
      esac
    done < <(orphan_agent_lines)
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
  local id=$1 eid=$2 out rc=0 label closed pid
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
  ORPHAN_HUB_MACHINE=$(printf '%s' "$out" | jq -r '.task.machine // empty' 2>/dev/null) || ORPHAN_HUB_MACHINE=
  ORPHAN_HUB_CWD=$(printf '%s' "$out" | jq -r '.task.cwd // empty' 2>/dev/null) || ORPHAN_HUB_CWD=
  closed=$(printf '%s' "$out" | jq -r '.task.closed_at // empty' 2>/dev/null) || closed=
  if [ "$label" != "fm-$id" ]; then
    ORPHAN_REASON="endpoint $eid carries label '${label:-(none)}', not fm-$id"
    return 1
  fi
  if [ -d "$STATE/$id.inbox/deck-$eid" ] && [ ! -L "$STATE/$id.inbox/deck-$eid" ]; then
    ORPHAN_EVIDENCE="home-record:$id.inbox/deck-$eid"
  elif [ -n "$ORPHAN_HUB_MACHINE" ] && [ -n "$ORPHAN_HUB_CWD" ] \
    && pid=$(orphan_agent_proof "$id" "$ORPHAN_HUB_MACHINE" "$ORPHAN_HUB_CWD"); then
    ORPHAN_EVIDENCE="local-agent:pid=$pid,status-path=$STATE/$id.status"
  else
    ORPHAN_REASON="nothing in this home ties endpoint $eid to it - no state/$id.inbox/deck-$eid record and no local agent carrying this home's status path for $id - so a matching label alone is not ownership"
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
    dead) return 0 ;;
    alive)
      active=$(jq -r 'if .active == false then "idle" elif .active == true then "busy" else "unknown" end' \
        "$STATE/$id.inbox/deck-$ORPHAN_ENDPOINT_ID/active.json" 2>/dev/null) || active=unknown
      case "$active" in
        idle) ;;
        busy) refuse "$id's agent is running a turn right now, so it is busy; nothing was closed" ;;
        *) refuse "$id's agent is still running and nothing in this home records that its turn ended, so it cannot be proved idle; nothing was closed" ;;
      esac
      for msg in "$STATE/$id.inbox"/*.msg; do
        [ -e "$msg" ] || continue
        refuse "$id's agent is idle but its inbox still holds an unhandled message (${msg##*/}), so work is pending; nothing was closed"
      done
      ORPHAN_AGENT=alive-idle
      ;;
    *) refuse "the hub's reading of $id's agent is '$ORPHAN_AGENT', so nothing proves it is stopped or idle; nothing was closed" ;;
  esac
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
  if git -C "$wt" rev-parse --verify -q HEAD >/dev/null 2>&1; then
    ahead=$(git -C "$wt" rev-list --count HEAD --not --remotes 2>/dev/null) \
      || refuse "the worktree $wt ($why) cannot be compared with its remotes; nothing was closed"
    [ "$ahead" = 0 ] \
      || refuse "the worktree $wt ($why) has $ahead commit(s) on no remote branch, so its work has not landed; nothing was closed"
  fi
  ORPHAN_WORKTREES="${ORPHAN_WORKTREES:+$ORPHAN_WORKTREES,}$wt"
}

orphan_check_worktrees() {  # <id> <target>
  local id=$1 target=$2 cwd top git_dir common line wt
  ORPHAN_WORKTREES=
  ORPHAN_SCRATCH=0
  ! orphan_finished_scout "$id" || ORPHAN_SCRATCH=1
  cwd=$(fm_backend_stream_current_path "$target" "fm-$id" 2>/dev/null) \
    || refuse "the hub cannot say which directory $id's endpoint is in, so nothing proves no unlanded work sits behind it; nothing was closed"
  [ -d "$cwd" ] \
    || refuse "$id's endpoint is in $cwd, which this machine cannot inspect for unlanded work; nothing was closed"
  if top=$(git -C "$cwd" rev-parse --show-toplevel 2>/dev/null); then
    git_dir=$(git -C "$top" rev-parse --path-format=absolute --git-dir 2>/dev/null) || git_dir=
    common=$(git -C "$top" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || common=
    if [ -z "$git_dir" ] || [ "$git_dir" != "$common" ]; then
      orphan_judge_worktree "$id" "$top" "the endpoint's working directory"
    fi
  fi
  if [ -n "$ORPHAN_HUB_CWD" ] && [ -d "$ORPHAN_HUB_CWD" ] \
    && git -C "$ORPHAN_HUB_CWD" rev-parse --git-dir >/dev/null 2>&1; then
    while IFS= read -r line; do
      case "$line" in worktree\ *) wt=${line#worktree } ;; *) continue ;; esac
      [ -d "$wt" ] || continue
      fm_treehouse_slot_owner_state "$wt" "$id"
      [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] || continue
      case ",$ORPHAN_WORKTREES," in *",$wt,"*|*",$wt(finished-scout-scratch),"*) continue ;; esac
      orphan_judge_worktree "$id" "$wt" "its slot claim names $id"
    done < <(git -C "$ORPHAN_HUB_CWD" worktree list --porcelain 2>/dev/null)
  fi
}

orphan_close() {  # <id> [eid]
  local id=$1 want=${2:-} tag target at by rc=0
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
  at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  by=$(id -un 2>/dev/null || printf '%s' "${USER:-unknown}")
  printf '%s\tasserted\t%s\tby=%s\tbasis=orphan-endpoint\tendpoint=%s\tevidence=%s\tagent=%s\tworktrees=%s\n' \
    "$at" "$id" "$by" "$target" \
    "$(printf '%s' "$ORPHAN_EVIDENCE" | orphan_clean)" "$ORPHAN_AGENT" \
    "$(printf '%s' "${ORPHAN_WORKTREES:-none}" | orphan_clean)" >> "$STATE/endpoint-retirements.log" \
    || refuse "the assertion for $id could not be recorded in $STATE/endpoint-retirements.log; nothing was closed - an endpoint is never closed without a durable author"
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
