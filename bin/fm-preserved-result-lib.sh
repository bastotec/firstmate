# shellcheck shell=bash
# Accepted finite-result endpoint retirement, called only by
# fm-retire-endpoint.sh --accepted-result <acceptance.json> <task-id>.
# The owning mate explicitly accepts knowledge or obsolete work, never landing.
# Acceptance JSON fields (all required strings): task, spawn_gen, meta_sha256,
# head, outcome (diagnosis|superseded), accepted_by, summary, result (absolute
# regular nonempty report path), result_sha256, plus allocation (the complete
# original pool entry object copied from treehouse-state.json under its flock).
# Hash the ORIGINAL metadata and
# result bytes with SHA-256; head is the original full commit id.
# This is not an automatic sweep input and never accepts secondmates or scouts.
#
# The original metadata, acceptance, result bytes and Git inventory are retained
# at data/<id>/preserved-result/. The original allocation is leased IN PLACE,
# under Treehouse's state flock, before any endpoint stop. No git write, reset,
# return, branch deletion, source deletion, or worktree relocation occurs.
# fm_preserved_result.py owns the version-pinned Treehouse lease schema integration.
# state/<id>.preserved-result blocks ordinary task/home teardown and same-id
# reuse even after a partial failure; there is no automatic release path.
# The slot claim survives. Explicit operator discard remains a separate act.
#
# Only the exact recorded stream endpoint with a confirmed kill can complete.
# Without durable stop proof, missing/unreachable/foreign endpoints and hub-only
# closes retain the record. Once stop proof is saved, replay does not depend on
# the hub remembering that endpoint. The original kind and PR fields are never
# rewritten. Backlog completion links
# the saved knowledge result, not a PR or local-main claim. Open captain calls
# or conditional waits refuse; resolve those through their existing owner first.
# Validation ownership must be readable through no-mistakes; an active run
# attributed by fm-nm-run-lib.sh refuses, including a pipeline-owned head absent
# from the original worktree after a rebase or fix round.
# Public commitments retain fm-public-followup.sh's guard-work gate, resolving
# delegated work through fm-public-followup-lib.sh's primary-home binding.
# An unresolved primary home refuses before any endpoint or allocation change.
# The existing fused backlog-close journal owns crash replay after stop proof.
# Retry the SAME acceptance after a failure; it converges under project, control
# and metadata locks, never broadens into cleanup. Receipts retain stop evidence
# and are inspectable even after live metadata retirement.

preserved_result_retire() ( # <id> <acceptance-json>
  set -e
  # shellcheck disable=SC2153 # DATA is supplied by fm-retire-endpoint.sh.
  local id=$1 acceptance=$2 meta="$STATE/$1.meta" archive="$DATA/$1/preserved-result"
  local snapshot project wt lock meta_lock gen target task rc phase relative applies=0
  local project_lock='' control_lock='' held_meta_lock=''
  trap 'test -z "$held_meta_lock" || fm_lock_release "$held_meta_lock"; test -z "$control_lock" || fm_lock_release "$control_lock"; test -z "$project_lock" || fm_lock_release "$project_lock"' EXIT
  if [ -e "$meta" ] || [ -L "$meta" ]; then
    [ -f "$meta" ] && [ ! -L "$meta" ] || refuse "unsafe original task metadata"
    snapshot=$meta
  else
    snapshot="$archive/original.meta"
    [ -f "$snapshot" ] && [ ! -L "$snapshot" ] || refuse "no original task record or preservation receipt"
  fi
  project=$(fm_backend_meta_exact_value "$snapshot" project) || refuse "missing project identity"
  wt=$(fm_backend_meta_exact_value "$snapshot" worktree) || refuse "missing original allocation"
  lock=$(fm_treehouse_project_lock_path "$project") || refuse "cannot resolve allocation lock"
  fm_lock_try_acquire "$lock" || refuse "another allocation action is running"
  project_lock=$lock
  lock="$STATE/.control-$id.lock"
  fm_lock_try_acquire "$lock" || refuse "another lifecycle action is running"
  control_lock=$lock
  meta_lock=$(fm_meta_lock_path "$meta") || exit 1
  fm_lock_acquire_wait "$meta_lock"
  held_meta_lock=$meta_lock
  [ "$(fm_backend_meta_exact_value "$snapshot" project)" = "$project" ] \
    && [ "$(fm_backend_meta_exact_value "$snapshot" worktree)" = "$wt" ] \
    || refuse "original allocation changed while acquiring its locks"
  [ "$(fm_meta_get "$snapshot" kind)" = ship ] || refuse "accepted results require the original ship record"
  [ "$(fm_meta_get "$snapshot" backend)" = stream ] || refuse "accepted results require a confirmed stream endpoint"
  [ -z "$(fm_meta_get "$snapshot" remote_host)" ] || refuse "run in the allocation's owning local home"
  fm_backend_validate_task_endpoint "$snapshot" "$id" || exit 1
  target=$FM_BACKEND_VALIDATED_TARGET
  gen=$(fm_backend_meta_exact_value "$snapshot" spawn_gen) || refuse "missing original incarnation"
  fm_treehouse_pool_slot "$project" "$wt" || refuse "not the original managed allocation"
  fm_treehouse_slot_owner_state "$wt" "$id"
  [ "$FM_TREEHOUSE_SLOT_OWNER" = mine ] && [ "$FM_TREEHOUSE_SLOT_OWNER_HOME" = "$FM_HOME" ] \
    || refuse "the original allocation claim does not belong to this task and home"
  for task in open deferred; do
    rc=0
    # shellcheck disable=SC2153 # CONFIG is supplied by fm-retire-endpoint.sh.
    FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" FM_CONFIG_OVERRIDE="$CONFIG" \
      "$SCRIPT_DIR/fm-captain-hold.sh" "$task" "$id" >/dev/null || rc=$?
    [ "$rc" = 1 ] || refuse "resolve the task's captain call or deferred wait before accepting its result"
  done
  rc=0
  fm_backlog_transition_applies "$CONFIG" "$DATA" ship || rc=$?
  case "$rc" in 0) applies=1 ;; 1) ;; *) refuse "$FM_BACKLOG_TRANSITION_ERROR" ;; esac
  if [ "$applies" = 1 ] && [ -f "$meta" ]; then
    fm_backlog_row_probe "$DATA" "$id" || refuse "cannot read the original backlog item"
  fi
  # Do not strand a validation run that can still write this original history.
  if command -v no-mistakes >/dev/null 2>&1; then
    # shellcheck source=bin/fm-nm-run-lib.sh
    . "$SCRIPT_DIR/fm-nm-run-lib.sh"
    local ledger branch run_state status run_branch
    ledger=$(fm_nm_run_bounded "$wt" 10 runs --limit 200) || refuse "cannot establish validation run ownership"
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD) || refuse "original branch is detached"
    run_state=$(fm_nm_runs_status_for_worktree "$wt" "$branch" "$ledger")
    [ "$(fm_nm_run_status_class "$run_state")" != live ] || refuse "finish or abort the original validation run before accepting its result"
    status=$(fm_nm_run_bounded "$wt" 10 axi status) || refuse "cannot establish validation run ownership"
    if [ -z "$status" ] || printf '%s\n' "$status" | grep -q '^error:'; then
      refuse "cannot establish validation run ownership"
    fi
    if printf '%s\n' "$status" | grep -q '^run:'; then
      run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$status" branch)")
      [ "$run_branch" = "$branch" ] || refuse "cannot establish validation run ownership"
      if fm_nm_run_is_pipeline_owned_active "$status" \
        || { fm_nm_head_matches_worktree "$wt" "$(fm_nm_strip_quotes "$(fm_nm_field "$status" head)")" \
          && fm_nm_run_is_active "$status"; }; then
        refuse "finish or abort the original validation run before accepting its result"
      fi
      if fm_nm_run_is_active "$status"; then
        refuse "cannot establish validation run ownership"
      fi
    fi
  else
    refuse "cannot establish validation run ownership without no-mistakes"
  fi
  # shellcheck source=bin/fm-public-followup-lib.sh
  . "$SCRIPT_DIR/fm-public-followup-lib.sh"
  fm_pf_resolve_work_owner "$FM_HOME" "$STATE" ship "$id"
  [ "$PUBLIC_FOLLOWUP_PARENT_UNRESOLVED" != 1 ] \
    || refuse "cannot resolve the primary home for this task's public commitments"
  if [ -n "$PUBLIC_FOLLOWUP_STATE" ] && [ "$PUBLIC_FOLLOWUP_RELAY_ACTIVE" = 1 ] \
    && fm_pf_has_registrations "$PUBLIC_FOLLOWUP_STATE"; then
    FM_HOME="$PUBLIC_FOLLOWUP_HOME" FM_STATE_OVERRIDE="$PUBLIC_FOLLOWUP_STATE" \
      FM_DATA_OVERRIDE="$PUBLIC_FOLLOWUP_HOME/data" FM_CONFIG_OVERRIDE="$PUBLIC_FOLLOWUP_HOME/config" \
      "$SCRIPT_DIR/fm-public-followup.sh" guard-work "$PUBLIC_FOLLOWUP_WORK_HOME" "$id" \
      || refuse "task $id still owes a public reply through the myfirstmate relay"
  fi
  phase=$(python3 "$SCRIPT_DIR/fm_preserved_result.py" prepare "$STATE" "$DATA" "$id" "$acceptance" "$snapshot") || exit 1
  if [ -f "$meta" ]; then
    if [ "$phase" != endpoint-stopped ] && [ "$phase" != completed ]; then
      # The backend's kill treats a reused label as already gone; this operation
      # instead requires a fresh exact label before invoking that shared primitive.
      fm_backend_source stream
      fm_backend_stream_parse_target "$target" || refuse "cannot address the original endpoint"
      task=$(fm_backend_stream_api GET "/v1/tasks/$FM_BACKEND_STREAM_ENDPOINT") || refuse "endpoint identity is unconfirmed"
      [ "$(printf '%s' "$task" | jq -r '.task.label // empty')" = "fm-$id" ] || refuse "endpoint belongs to another task"
      fm_backend_kill stream "$target" "" "fm-$id" || refuse "endpoint stop is unconfirmed; original allocation and records retained"
      python3 "$SCRIPT_DIR/fm_preserved_result.py" stopped "$STATE" "$DATA" "$id" "$acceptance" "$snapshot"
    fi
    if [ "$applies" = 1 ]; then
      relative=$(fm_backlog_data_relative "$DATA") || exit 1
      fm_backlog_close_marker_write "$STATE" "$id" "$DATA" "$gen" 0 \
        --report "$relative/$id/report.md" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
      fm_backlog_atomic_transition close "$meta" "$STATE/$id.backlog-close" "$DATA" "$id" "$STATE" \
        --report "$relative/$id/report.md" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
    else
      fm_backlog_atomic_transition remove "$meta" "task record" "$STATE" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
    fi
  else
    python3 "$SCRIPT_DIR/fm_preserved_result.py" verify-stopped "$STATE" "$DATA" "$id" "$acceptance" "$snapshot"
    if [ -e "$STATE/$id.backlog-close" ]; then
      fm_backlog_close_marker_replay "$STATE" "$STATE/$id.backlog-close" "$DATA" || refuse "$FM_BACKLOG_TRANSITION_ERROR"
    fi
  fi
  python3 "$SCRIPT_DIR/fm_preserved_result.py" complete "$STATE" "$DATA" "$id" "$acceptance" "$archive/original.meta"
  printf 'Retired %s endpoint; accepted result recorded, original allocation and history retained at %s. No code landing is claimed.\n' "$id" "$wt"
)
