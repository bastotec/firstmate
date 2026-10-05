#!/usr/bin/env bash
# fm-supervisor-target-lib.sh - the single owner of supervisor-pane discovery.
#
# The away-mode daemon (bin/fm-supervise-daemon.sh) must know which pane runs
# firstmate itself, both to inject escalations into it and, for the daemon, to
# validate that target at startup. The script-owned away launcher
# (bin/fm-afk-launch.sh) must resolve the SAME captain pane BEFORE it creates a
# separate, non-visible terminal for the daemon, so it can pass that pane in as
# FM_SUPERVISOR_TARGET (otherwise the daemon, running in its own terminal, would
# auto-discover its OWN pane and inject there instead of into the captain's).
#
# Because both callers need the identical resolution, it lives here once. The
# function names and precedence are unchanged from when this logic lived inline
# in bin/fm-supervise-daemon.sh, so its unit tests (tests/fm-daemon.test.sh)
# keep exercising the same names after the daemon sources this file.
#
# Stream primaries. A primary hosted on a stream endpoint is addressed as
# "<hub-tag>:<endpoint-id>" with backend `stream`. Two signals select it:
#   - FM_STREAM_ENDPOINT_ID + FM_STREAM_HUB, which the stream agent sets in its
#     own child's environment. It is checked BEFORE $TMUX_PANE because the
#     agent's child also inherits whatever $TMUX_PANE its launcher had, which
#     names the launcher's pane, not the primary.
#   - a live deck-chat primary record, state/primary-chat.json (written by the
#     deck-chat host, read by bin/fm-primary-steer.sh). It is checked before the
#     tmux/herdr markers too: while a deck-chat primary owns this home, the pane
#     the caller happens to run in is never the primary. Its endpoint may be
#     null (a host not on a stream endpoint); the target is then "-" and only
#     the steer path can deliver.

# Default supervisor pane target/backend when nothing is configured or detected.
# "firstmate:0" is a tmux session:window name, so the bare fallback (nothing
# configured, nothing detected) assumes tmux - matching the daemon's pre-herdr
# behavior byte-for-byte when run outside both tmux and herdr.
FM_SUPERVISOR_TARGET_DEFAULT="firstmate:0"
FM_SUPERVISOR_BACKEND_DEFAULT="tmux"

# The stream endpoint this process runs inside, from the variables the stream
# agent sets for its child. Prints "<hub-tag>:<endpoint-id>"; returns 1 when the
# process is not inside a stream endpoint.
fm_supervisor_stream_env_target() {
  local tag
  [ -n "${FM_STREAM_ENDPOINT_ID:-}" ] && [ -n "${FM_STREAM_HUB:-}" ] || return 1
  if ! declare -F fm_backend_stream_hub_tag >/dev/null 2>&1; then
    declare -F fm_backend_source >/dev/null 2>&1 || return 1
    fm_backend_source stream >/dev/null 2>&1 || return 1
  fi
  tag=$(fm_backend_stream_hub_tag "$FM_STREAM_HUB") || return 1
  [ -n "$tag" ] || return 1
  printf '%s:%s' "$tag" "$FM_STREAM_ENDPOINT_ID"
}

# The endpoint of a LIVE deck-chat primary record for this home: the record
# exists, is not marked stopped, and its host_pid is alive. Prints the recorded
# endpoint, or "-" when the host has none; returns 1 when there is no live record.
fm_supervisor_primary_chat_endpoint() {
  local state record pid stopped endpoint
  state=${FM_STATE_OVERRIDE:-${FM_HOME:-.}/state}
  record="$state/primary-chat.json"
  [ -f "$record" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  pid=$(jq -r '.host_pid // empty' "$record" 2>/dev/null) || return 1
  case "$pid" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$pid" 2>/dev/null || return 1
  stopped=$(jq -r '(.stopped == true) or (.state == "stopped") or (.stopped_at != null)' "$record" 2>/dev/null) || return 1
  [ "$stopped" = false ] || return 1
  endpoint=$(jq -r '.endpoint // empty' "$record" 2>/dev/null) || return 1
  printf '%s' "${endpoint:--}"
}

# discover_supervisor_source: name which signal selects the supervisor, in the
# precedence both discover_* functions below share. One of FM_SUPERVISOR_BACKEND
# (an explicit backend override), FM_STREAM_ENDPOINT_ID, PRIMARY_CHAT_RECORD,
# TMUX_PANE, HERDR_ENV, or FALLBACK. The explicit FM_SUPERVISOR_TARGET override
# is reported by the target resolver itself.
discover_supervisor_source() {
  if fm_supervisor_stream_env_target >/dev/null 2>&1; then
    printf 'FM_STREAM_ENDPOINT_ID'
  elif fm_supervisor_primary_chat_endpoint >/dev/null 2>&1; then
    printf 'PRIMARY_CHAT_RECORD'
  elif [ -n "${TMUX_PANE:-}" ]; then
    printf 'TMUX_PANE'
  elif [ "${HERDR_ENV:-}" = "1" ] && [ -n "${HERDR_PANE_ID:-}" ]; then
    printf 'HERDR_ENV'
  else
    printf 'FALLBACK'
  fi
}

# discover_supervisor_target: resolve the pane running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override) - may be a tmux target, a
#      herdr "<session>:<pane-id>" target, or a stream "<hub-tag>:<endpoint-id>"
#      target (paired with discover_supervisor_backend to know which).
#      With FM_SUPERVISOR_BACKEND=stream and no explicit target, only the stream
#      signals below apply, and the result is "-" when neither is present.
#   2. FM_STREAM_ENDPOINT_ID + FM_STREAM_HUB - this process runs inside a stream
#      endpoint; compose its "<hub-tag>:<endpoint-id>" target.
#   3. a live state/primary-chat.json record - its endpoint, or "-" when null.
#   4. $TMUX_PANE - tmux sets this in every pane's environment; inherited by a
#      process launched from firstmate's own pane.
#   5. $HERDR_ENV=1 + $HERDR_PANE_ID - herdr injects both into every process it
#      manages a pane for; compose the "<session>:<pane-id>" target from
#      $HERDR_SESSION (defaulting to "default", mirroring bin/backends/herdr.sh's
#      fm_backend_herdr_session) and $HERDR_PANE_ID. Checked after $TMUX_PANE so a
#      tmux pane nested inside herdr still resolves to tmux, matching
#      fm_backend_detect's innermost-first rule.
#   6. FM_SUPERVISOR_TARGET_DEFAULT - legacy tmux fallback (may not resolve if the
#      session is named differently). Returns 1 so the caller can warn.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  # An explicit stream backend never borrows a tmux/herdr pane id: it takes the
  # stream endpoint this process is in, else the live record's, else "-" (the
  # steer path needs no endpoint; returns 1 so the caller can warn).
  if [ "${FM_SUPERVISOR_BACKEND:-}" = stream ]; then
    fm_supervisor_stream_env_target 2>/dev/null && return 0
    fm_supervisor_primary_chat_endpoint 2>/dev/null && return 0
    printf -- '-'
    return 1
  fi
  case "$(discover_supervisor_source)" in
    FM_STREAM_ENDPOINT_ID) fm_supervisor_stream_env_target; return 0 ;;
    PRIMARY_CHAT_RECORD) fm_supervisor_primary_chat_endpoint; return 0 ;;
    TMUX_PANE) printf '%s' "$TMUX_PANE"; return 0 ;;
    HERDR_ENV) printf '%s:%s' "${HERDR_SESSION:-default}" "$HERDR_PANE_ID"; return 0 ;;
  esac
  printf '%s' "$FM_SUPERVISOR_TARGET_DEFAULT"
  return 1
}

# discover_supervisor_backend: resolve the supervisor pane's BACKEND, independent
# of the target string so an explicit FM_SUPERVISOR_TARGET override still knows
# which primitives (tmux, herdr, or stream) to dispatch through. Priority mirrors
# discover_supervisor_target:
#   1. FM_SUPERVISOR_BACKEND env (explicit override).
#   2. FM_STREAM_ENDPOINT_ID + FM_STREAM_HUB - stream.
#   3. a live state/primary-chat.json record - stream.
#   4. $TMUX_PANE set - tmux.
#   5. $HERDR_ENV=1 (with $HERDR_PANE_ID present) - herdr.
#   6. FM_SUPERVISOR_BACKEND_DEFAULT (tmux) - matches the target fallback. Returns 1.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  case "$(discover_supervisor_source)" in
    FM_STREAM_ENDPOINT_ID|PRIMARY_CHAT_RECORD) printf 'stream'; return 0 ;;
    TMUX_PANE) printf 'tmux'; return 0 ;;
    HERDR_ENV) printf 'herdr'; return 0 ;;
  esac
  printf '%s' "$FM_SUPERVISOR_BACKEND_DEFAULT"
  return 1
}
