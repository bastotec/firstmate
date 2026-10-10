#!/usr/bin/env bash
# fm-backend.sh - runtime-backend selection, meta helpers, selector resolution,
# and dispatch for firstmate's session-provider abstraction.
#
# stream (bin/backends/stream.sh, docs/stream-backend.md) is the only backend.
# The tmux and herdr adapters were removed; their names stay known only as
# RETIRED backends, so a record left over from them reads as an endpoint
# firstmate can no longer drive (unverified, gone, kill unconfirmed) instead of
# crashing a caller. bin/fm-retire-endpoint.sh retires such a record.
#
# Compatibility: fm_backend_of_meta below owns the legacy missing-field
# default; docs/configuration.md owns the operator-facing metadata contract,
# and fm-spawn.sh's header owns publication of explicit backend fields.

FM_BACKEND_SCRIPT=${BASH_SOURCE[0]:-$0}
FM_BACKEND_LIB_DIR="$(cd "$(dirname "$FM_BACKEND_SCRIPT")" && pwd)"
unset FM_BACKEND_SCRIPT
FM_BACKEND_DEFAULT_ROOT="$(cd "$FM_BACKEND_LIB_DIR/.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_DEFAULT_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
FM_BACKEND_CONFIG_DIR="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# The one backend, and the retired ones whose records can still be read.
FM_BACKEND_KNOWN="stream"
FM_BACKEND_RETIRED="tmux herdr"

# fm_backend_list_contains: whitespace-delimited membership without relying on
# shell word splitting. fm-backend.sh is normally sourced by bash scripts, but
# zsh diagnostics can source it too, so backend-name matching must stay portable.
fm_backend_list_contains() {  # <list> <name>
  local list=$1 name=$2
  case "$name" in
    *[[:space:]]*) return 1 ;;
  esac
  case " $list " in
    *" $name "*) return 0 ;;
  esac
  return 1
}

fm_backend_is_known() {  # <name>
  fm_backend_list_contains "$FM_BACKEND_KNOWN" "$1"
}

# fm_backend_is_retired: a backend firstmate used to drive and no longer does.
fm_backend_is_retired() {  # <name>
  fm_backend_list_contains "$FM_BACKEND_RETIRED" "$1"
}

# fm_backend_name: resolve the backend for a NEW spawn, absent an explicit
# per-task override. Precedence: FM_BACKEND env, then config/backend (a single
# word on its first non-empty line), then stream. A per-task `--backend` flag is
# parsed by the caller (fm-spawn.sh) and takes precedence over this resolution
# entirely; it is not read here. Callers validate the result, so a leftover
# `tmux` or `herdr` setting is refused loudly rather than ignored.
fm_backend_name() {
  local line v
  if [ -n "${FM_BACKEND:-}" ]; then
    printf '%s' "$FM_BACKEND"
    return 0
  fi
  if [ -f "$FM_BACKEND_CONFIG_DIR/backend" ]; then
    while IFS= read -r line || [ -n "$line" ]; do
      v=$(printf '%s' "$line" | tr -d '[:space:]')
      if [ -n "$v" ]; then
        printf '%s' "$v"
        return 0
      fi
    done < "$FM_BACKEND_CONFIG_DIR/backend"
  fi
  printf 'stream'
}

# fm_backend_validate: refuse an unknown or retired backend LOUDLY. Silent on
# success.
fm_backend_validate() {  # <name>
  local name=$1
  if fm_backend_is_retired "$name"; then
    echo "error: the '$name' backend was removed; stream is the only backend (set config/backend to stream or delete it)" >&2
    return 1
  fi
  if ! fm_backend_is_known "$name"; then
    echo "error: unknown backend '$name' (known: $FM_BACKEND_KNOWN)" >&2
    return 1
  fi
  return 0
}

fm_backend_validate_spawn() {  # <name>
  fm_backend_validate "$1"
}

# fm_backend_required_tools: the backend-SPECIFIC CLI tools a firstmate home
# genuinely requires, beyond firstmate's universal toolchain (owned by
# docs/configuration.md "Toolchain" and bootstrap's COMMON list). stream has no
# session CLI of its own: its session host is the fleet's hub reached over HTTP,
# so the set is python3 (the Python rollback and helper scripts), curl (this
# adapter's HTTP client), jq (its JSON parsing) and the treehouse worktree
# provider. Prints a single space-separated line and returns 0 for a known
# backend; returns 1 and prints nothing otherwise.
fm_backend_required_tools() {  # <backend>
  case "$1" in
    stream) printf '%s' 'python3 curl jq treehouse' ;;
    *) return 1 ;;
  esac
}

fm_backend_required_tool_available() {  # <backend> <tool>
  local backend=$1 tool=$2 required
  required=$(fm_backend_required_tools "$backend") || return 1
  fm_backend_list_contains "$required" "$tool" || return 1
  command -v "$tool" >/dev/null 2>&1
}

# fm_meta_get: the LAST value of `key=` in <meta-file>, or empty (never
# errors) if the file or key is absent. Mirrors the ad hoc `grep '^key=' |
# tail -1 | cut -d= -f2-` snippet every fm-*.sh script used to repeat inline.
fm_meta_get() {  # <meta-file> <key>
  local meta=$1 key=$2 line value=''
  [ -f "$meta" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$key="*) value=${line#*=} ;;
    esac
  done < "$meta" 2>/dev/null || true
  printf '%s' "$value"
}

# fm_backend_of_meta: the backend recorded in <meta-file>. A record with no
# backend= field predates explicit backend fields, and every such record was
# written for tmux, so the field defaults to `tmux` - a
# retired backend, which every dispatcher below reports as undrivable.
fm_backend_of_meta() {  # <meta-file>
  local v
  v=$(fm_meta_get "$1" backend)
  printf '%s' "${v:-tmux}"
}

fm_backend_target_of_meta() {  # <meta-file>
  local meta=$1 window
  window=$(fm_meta_get "$meta" window)
  [ -n "$window" ] && printf '%s' "$window"
}

# fm_backend_validate_task_endpoint: validate a task cleanup record entirely
# from its durable metadata before any runtime command or cleanup mutation.
# The validation binds the exact task id, selected backend, target, project,
# and worktree. Stream records carry endpoint_task_id because their opaque
# endpoint ids do not encode the task label. A record on a retired backend
# validates its identity fields only (its endpoint can no longer be driven, so
# there is nothing further to bind), which lets cleanup and
# bin/fm-retire-endpoint.sh retire it.
# On success, sets FM_BACKEND_VALIDATED_BACKEND and
# FM_BACKEND_VALIDATED_TARGET. On failure, prints one refusal and returns 1.
fm_backend_meta_exact_value() {  # <meta-file> <key>
  local meta=$1 key=$2 count value
  count=$(grep -c "^$key=" "$meta" 2>/dev/null || true)
  [ "$count" -eq 1 ] || return 1
  value=$(grep "^$key=" "$meta" | cut -d= -f2-)
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

fm_backend_endpoint_atom_valid() {  # <value>
  case "$1" in
    ''|*[!A-Za-z0-9._@%+-]*) return 1 ;;
  esac
}

fm_backend_validate_task_endpoint() {  # <meta-file> <task-id>
  local meta=$1 id=$2 backend_count backend window worktree project binding_count binding
  local hub_url endpoint_id hub_tag session pane recorded_session workspace tab
  FM_BACKEND_VALIDATED_BACKEND=
  FM_BACKEND_VALIDATED_TARGET=
  [ -f "$meta" ] && [ ! -L "$meta" ] || {
    echo "REFUSED: task $id has no regular endpoint metadata at $meta; preserving task state." >&2
    return 1
  }
  case "$id" in ''|*[!A-Za-z0-9._-]*)
    echo "REFUSED: task endpoint identity has an invalid task id; preserving task state." >&2
    return 1
  esac
  window=$(fm_backend_meta_exact_value "$meta" window) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous window endpoint; preserving task state." >&2
    return 1
  }
  worktree=$(fm_backend_meta_exact_value "$meta" worktree) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous worktree identity; preserving task state." >&2
    return 1
  }
  project=$(fm_backend_meta_exact_value "$meta" project) || {
    echo "REFUSED: task $id has a missing, empty, or ambiguous project identity; preserving task state." >&2
    return 1
  }
  case "$worktree$project$window" in *$'\n'*|*$'\r'*|*$'\t'*)
    echo "REFUSED: task $id has malformed endpoint metadata; preserving task state." >&2
    return 1
  esac
  backend_count=$(grep -c '^backend=' "$meta" 2>/dev/null || true)
  case "$backend_count" in
    0) backend=tmux ;;
    1) backend=$(fm_backend_meta_exact_value "$meta" backend) || backend= ;;
    *) backend= ;;
  esac
  if [ -z "$backend" ] || { ! fm_backend_is_known "$backend" && ! fm_backend_is_retired "$backend"; }; then
    echo "REFUSED: task $id has a missing, ambiguous, or unknown backend identity; preserving task state." >&2
    return 1
  fi
  binding_count=$(grep -c '^endpoint_task_id=' "$meta" 2>/dev/null || true)
  case "$binding_count" in
    0) binding= ;;
    1)
      binding=$(fm_backend_meta_exact_value "$meta" endpoint_task_id) || {
        echo "REFUSED: task $id has an empty endpoint task binding; preserving task state." >&2
        return 1
      }
      ;;
    *)
      echo "REFUSED: task $id has an ambiguous endpoint task binding; preserving task state." >&2
      return 1
      ;;
  esac
  if [ -n "$binding" ] && [ "$binding" != "$id" ]; then
    echo "REFUSED: endpoint metadata belongs to task $binding, not $id; preserving task state." >&2
    return 1
  fi

  # A record on a retired backend keeps its identity checks: cleanup never
  # drives its endpoint, but it must still refuse a malformed or foreign record
  # before touching the worktree, exactly as it did while that backend ran.
  case "$backend" in
    tmux)
      session=${window%%:*}
      pane=${window#*:}
      if [ "$pane" = "$window" ] || [ "$pane" != "fm-$id" ] \
        || [ -z "$session" ]; then
        echo "REFUSED: tmux endpoint '$window' is malformed or does not belong to task $id; preserving task state." >&2
        return 1
      fi
      ;;
    herdr)
      [ "$binding" = "$id" ] || {
        echo "REFUSED: legacy Herdr endpoint metadata for task $id lacks an exact task binding; preserving task state." >&2
        return 1
      }
      recorded_session=$(fm_backend_meta_exact_value "$meta" herdr_session) || recorded_session=
      workspace=$(fm_backend_meta_exact_value "$meta" herdr_workspace_id) || workspace=
      tab=$(fm_backend_meta_exact_value "$meta" herdr_tab_id) || tab=
      pane=$(fm_backend_meta_exact_value "$meta" herdr_pane_id) || pane=
      if [ -z "$recorded_session" ] || [ -z "$workspace" ] || [ -z "$tab" ] || [ -z "$pane" ] \
        || [ "$window" != "$recorded_session:$pane" ] \
        || ! fm_backend_endpoint_atom_valid "$recorded_session" \
        || ! fm_backend_endpoint_atom_valid "$workspace" \
        || ! fm_backend_endpoint_atom_valid "${tab//:/_}" \
        || ! fm_backend_endpoint_atom_valid "${pane//:/_}"; then
        echo "REFUSED: Herdr endpoint metadata for task $id is malformed or inconsistent; preserving task state." >&2
        return 1
      fi
      ;;
    stream)
      [ "$binding" = "$id" ] || {
        echo "REFUSED: stream endpoint metadata for task $id lacks an exact task binding; preserving task state." >&2
        return 1
      }
      hub_url=$(fm_backend_meta_exact_value "$meta" stream_hub) || hub_url=
      endpoint_id=$(fm_backend_meta_exact_value "$meta" stream_endpoint_id) || endpoint_id=
      case "$endpoint_id" in *[!0-9a-f]*) endpoint_id= ;; esac
      # The window must agree with the RECORDED hub, not with whatever this
      # home is configured for now: a record that only matched the current
      # setting would start refusing the moment an operator repointed this home
      # at another hub, and would accept an endpoint id against a hub it was
      # never created on.
      hub_tag=
      if [ -n "$hub_url" ] && fm_backend_source stream >/dev/null 2>&1; then
        hub_tag=$(fm_backend_stream_hub_tag "$hub_url" 2>/dev/null) || hub_tag=
      fi
      if [ -z "$hub_url" ] || [ -z "$endpoint_id" ] || [ -z "$hub_tag" ] \
        || [ "$window" != "$hub_tag:$endpoint_id" ] \
        || ! fm_backend_endpoint_atom_valid "$hub_tag"; then
        echo "REFUSED: stream endpoint metadata for task $id is malformed or inconsistent; preserving task state." >&2
        return 1
      fi
      ;;
  esac
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_BACKEND_VALIDATED_BACKEND=$backend
  # shellcheck disable=SC2034 # Output globals are consumed by sourcing callers.
  FM_BACKEND_VALIDATED_TARGET=$window
  return 0
}

fm_backend_meta_for_window() {  # <target> <state-dir>
  local target=$1 state=$2 meta window
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    window=$(fm_meta_get "$meta" window)
    [ -n "$window" ] && [ "$window" = "$target" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_backend_task_id_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  case "$raw" in
    *:*) return 1 ;;
  esac
  if [ -f "$state/$raw.meta" ]; then
    printf '%s' "$raw"
    return 0
  fi
  case "$raw" in
    fm-*)
      id=${raw#fm-}
      [ -f "$state/$id.meta" ] || return 1
      printf '%s' "$id"
      return 0
      ;;
  esac
  return 1
}

fm_backend_meta_for_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state") || return 1
  printf '%s/%s.meta' "$state" "$id"
}

fm_backend_of_selector() {  # <raw-target> <resolved-target> <state-dir>
  local raw=$1 resolved=$2 state=$3 meta
  meta=$(fm_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  if [ -n "$resolved" ]; then
    meta=$(fm_backend_meta_for_window "$resolved" "$state" 2>/dev/null || true)
    [ -n "$meta" ] && { fm_backend_of_meta "$meta"; return 0; }
  fi
  printf 'stream'
}

fm_backend_expected_label_of_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 id
  id=$(fm_backend_task_id_for_selector "$raw" "$state" 2>/dev/null || true)
  [ -n "$id" ] && printf 'fm-%s' "$id"
  return 0
}

# fm_backend_source: source the named backend's adapter file, once per shell.
# The adapter is an independently linted canonical root. The /dev/null source
# boundary keeps runtime dispatch from importing the adapter AST into every
# dispatcher consumer while preserving the runtime source operation.
fm_backend_source() {  # <name>
  fm_backend_validate "$1" || return 1
  if [ -z "${_FM_BACKEND_STREAM_SOURCED:-}" ]; then
    # shellcheck source=/dev/null
    . "$FM_BACKEND_LIB_DIR/backends/stream.sh" || return 1
    _FM_BACKEND_STREAM_SOURCED=1
  fi
}

# fm_backend_resolve_selector: resolve a raw fm-send.sh/fm-peek.sh style
# selector to a session-provider target. Four forms, in order:
#   target with ":"   used as-is (the escape hatch for an endpoint outside this
#                      firstmate home) - a literal string.
#   exact task id      routed through <state-dir>/<id>.meta's backend target
#                      (`window=`) - a stored value, NOT re-verified against
#                      the hub here.
#   "fm-<id>"          legacy task label fallback routed through
#                      <state-dir>/<id>.meta when no exact
#                      <state-dir>/fm-<id>.meta exists.
#   anything else      matched against recorded `window=` metadata, else
#                      refused.
fm_backend_resolve_selector() {  # <raw-target> <state-dir>
  local raw=$1 state=$2 meta window
  case "$raw" in
    *:*)
      printf '%s' "$raw"
      return 0
      ;;
  esac
  meta=$(fm_backend_meta_for_selector "$raw" "$state" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    window=$(fm_backend_target_of_meta "$meta")
    [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
    printf '%s' "$window"
    return 0
  fi
  case "$raw" in
    fm-*)
      echo "error: no metadata for $raw in $state; pass a <hub-tag>:<endpoint-id> target to reach an endpoint outside this firstmate home" >&2
      return 1
      ;;
    *)
      meta=$(fm_backend_meta_for_window "$raw" "$state" 2>/dev/null || true)
      if [ -n "$meta" ]; then
        window=$(fm_backend_target_of_meta "$meta")
        [ -n "$window" ] || { echo "error: no backend target recorded in $meta" >&2; return 1; }
        printf '%s' "$window"
        return 0
      fi
      echo "error: no task or endpoint named $raw in $state; pass a task id or a <hub-tag>:<endpoint-id> target" >&2
      return 1
      ;;
  esac
}

# --- generic per-op dispatch -------------------------------------------------
#
# Callers name an operation and the backend recorded for the task. Every
# operation sources the adapter through fm_backend_source, so a record on a
# retired backend gets that backend's one refusal line and the operation's
# "cannot drive" answer below, never an adapter call.

# fm_backend_capture: bounded plain-text session capture.
fm_backend_capture() {  # <backend> <target> <lines> [expected-label]
  fm_backend_source "$1" || return 1
  shift
  fm_backend_stream_capture "$@"
}

# fm_backend_send_key: one backend-supported named special key.
fm_backend_send_key() {  # <backend> <target> <key> [expected-label]
  fm_backend_source "$1" || return 1
  shift
  fm_backend_stream_send_key "$@"
}

# fm_backend_send_text_submit: type text once, then submit and verify,
# retrying only the submission (never retyping). Echoes the backend's
# proof-carrying verdict; callers require exact empty for confirmed delivery.
fm_backend_send_text_submit() {  # <backend> <target> <text> <retries> <enter-sleep> <settle> [expected-label] [harness] [state-dir] [task-id]
  fm_backend_source "$1" || return 1
  shift
  fm_backend_stream_send_text_submit "$@"
}

# fm_backend_kill: remove the task's session endpoint.
#
# This header is the single owner of the kill return contract. Every caller
# must distinguish all four, because a durable record that says a worker is
# gone while that worker may still be running is the exact failure this
# contract exists to prevent:
#
#   0  GONE. The endpoint is not there any more, and something the backend
#      itself reported says so: either this call removed it and a structured
#      follow-up read confirmed the removal, or the endpoint was already
#      absent before the call. An already-absent endpoint is ordinary
#      idempotent cleanup and stays a success, never a refusal.
#   3  STILL-PRESENT. The backend answered, and its answer positively says the
#      endpoint is still there: the kill was attempted and the backend
#      reported that the worker was not stopped - the hub answered the kill
#      with the endpoint's own agent never acknowledging it. Exactly one
#      explanatory line is written to stderr; callers relay it rather than
#      inventing their own.
#   2  UNCONFIRMED. The kill was attempted, or deliberately skipped, and
#      nothing proved the endpoint gone - the backend refused it, never
#      answered, or answered with nothing that could be read. A record on a
#      retired backend lands here too: firstmate can no longer close it, and
#      nothing proves it closed. The worker may still be running. Exactly one
#      explanatory line is written to stderr; callers relay it rather than
#      inventing their own.
#   1  UNSUPPORTED. The kill could never be attempted at all: an empty or
#      malformed target, an unknown backend, or an adapter that could not be
#      sourced.
#
# Only 0 licenses removing the task's durable records. Every nonzero return
# means the endpoint's identity must be retained so a later rerun can retry;
# bin/fm-retire-endpoint.sh's header owns retirement of an UNCONFIRMED one on
# a plain assertion, and of a STILL-PRESENT one only with
# --override-runtime-refusal.
# A caller that needs to tell them apart should use fm_backend_kill_verdict
# rather than re-deriving the numbers.
fm_backend_kill() {  # <backend> <target> [tab-id] [expected-label]
  local backend=$1
  shift
  [ -n "${1:-}" ] || { echo "error: refusing empty backend kill target" >&2; return 1; }
  if fm_backend_is_retired "$backend"; then
    echo "warning: endpoint $1 is on the retired '$backend' backend, which firstmate can no longer close; stop it by hand if it still runs" >&2
    return 2
  fi
  fm_backend_source "$backend" || return 1
  fm_backend_stream_kill "$@"
}

# fm_backend_kill_verdict: name one fm_backend_kill status, so callers that
# need the reason read the contract's words rather than re-deriving its numbers.
fm_backend_kill_verdict() {  # <status> -> gone|present|unconfirmed|unsupported
  case "$1" in
    0) printf 'gone' ;;
    3) printf 'present' ;;
    2) printf 'unconfirmed' ;;
    *) printf 'unsupported' ;;
  esac
}

# fm_backend_busy_state: semantic busy/idle/unknown from a backend's native
# agent state. stream exposes none, so the answer is always unknown; callers
# own the fallback (fm-watch.sh reads the harness-scoped pane tail,
# fm-crew-state.sh corroborates with the recorded harness's signature).
fm_backend_busy_state() {  # <backend> <target>
  printf 'unknown'
}

# fm_backend_composer_state: classify the composer/input area of <target> as
# empty|pending|pending-unproven|unknown for callers that need a pre-submit
# input guard, a submit acknowledgement, or a launch-readiness check (the send
# path, and the away-mode daemon in bin/fm-supervise-daemon.sh). The adapter's
# classifier is a THIN wrapper - capture plus a capability descriptor fed to the
# one shared shape owner (bin/fm-composer-lib.sh, fm_composer_classify_screen).
fm_backend_composer_state() {  # <backend> <target> [expected-label] -> empty|pending|pending-unproven|unknown
  fm_backend_source "$1" 2>/dev/null || { printf 'unknown'; return 0; }
  shift
  fm_backend_stream_composer_state "$@"
}

# fm_backend_composer_holds_only: 0 when the composer visibly holds nothing but
# copies of <text>, firstmate's own constant line; 1 otherwise or unreadable.
fm_backend_composer_holds_only() {  # <backend> <target> <expected-label> <text>
  fm_backend_source "$1" 2>/dev/null || return 1
  shift
  fm_backend_stream_composer_holds_only "$@"
}

# fm_backend_target_exists: cheap, READ-ONLY existence check - does the
# recorded TARGET endpoint still exist? A record on a retired backend never
# does, as far as firstmate can tell. Exists as one shared primitive so callers
# that only need a fast alive/dead read (recovery digests, the session-start
# fleet digest) do not re-derive it inline.
fm_backend_target_exists() {  # <backend> <target> [expected-label]
  fm_backend_source "$1" 2>/dev/null || return 1
  fm_backend_stream_target_ready "$2" "${3:-}"
}

# fm_backend_agent_state: the single recovery-grade agent/endpoint state
# contract. It is deliberately richer than fm_backend_target_exists's cheap
# presence read and prints exactly one of:
#   alive      - a verified harness agent is running.
#   dead       - the endpoint exists but confidently has no agent.
#   missing    - the recorded endpoint is absent from the backend inventory.
#   ambiguous  - the endpoint exists but its process cannot be attributed.
#   unreadable - a target or inventory read failed or contradicted itself.
#   unverified - this backend has no recovery classifier (a retired backend).
# Only `dead` and `missing` can license recovery, subject to the caller's
# ownership guards. Stream `missing` proves only absence from the hub registry,
# never that its agent is gone: bin/fm-bootstrap.sh skips automatic respawn,
# and bin/fm-control.sh adds a local owning-agent guard for manual recovery.
# Every `alive` is proven at process level through the shared classifier in
# bin/fm-agent-process-lib.sh, from the foreground process group the endpoint's
# owning AGENT published, never from a registration or a rendered title alone.
# A silent agent makes the endpoint `unreadable`, never `dead`, because an
# unreachable worker and a stopped one are indistinguishable from the hub and
# only one of them authorizes recovery - unless the hub holds that agent's OWN
# report that its worker exited, which is a recorded fact rather than a live
# reading, does not go stale, and reads `dead`.
fm_backend_agent_state() {  # <backend> <target>
  fm_backend_source "$1" 2>/dev/null || { printf 'unverified'; return 0; }
  fm_backend_stream_agent_state "$2"
}

# fm_backend_agent_pids: the operating-system pid of each harness process the
# recorded endpoint hosts, one per line, reduced to the top of each harness
# chain, so a caller can hold an agent by process identity (bin/fm-wake-lib.sh's
# fm_pid_identity) or read the arguments it was launched with. Empty output is
# an agent-free endpoint. Only an endpoint whose owning agent runs on this
# machine has that view, since its pids come from that agent's report
# (bin/backends/stream.sh's fm_backend_stream_agent_pids); any other endpoint,
# and one whose processes cannot be read, returns 1.
fm_backend_agent_pids() {  # <backend> <target>
  fm_backend_source "$1" 2>/dev/null || return 1
  fm_backend_stream_agent_pids "$2"
}

# Backward-compatible three-state view for existing callers: `dead` and
# `missing` both map to `dead`; ambiguous, unreadable, and unverified map to
# `unknown`. This lossy view does not prove a worker stopped: recovery must use
# fm_backend_agent_state's verdict and caller ownership guards above.
fm_backend_agent_alive() {  # <backend> <target>
  case "$(fm_backend_agent_state "$1" "$2")" in
    alive) printf 'alive' ;;
    dead|missing) printf 'dead' ;;
    *) printf 'unknown' ;;
  esac
}
