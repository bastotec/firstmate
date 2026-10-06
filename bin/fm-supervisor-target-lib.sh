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
# function names are preserved from when this logic lived inline in
# bin/fm-supervise-daemon.sh, so tests/fm-daemon.test.sh keeps exercising the
# same discovery interface after the daemon sources this file.
#
# The primary is a deck-chat host (bin/fm-deck-chat.sh), addressed as
# "<hub-tag>:<endpoint-id>" when it runs on a stream endpoint. Two signals
# select it:
#   - FM_STREAM_ENDPOINT_ID + FM_STREAM_HUB, which the stream agent sets in its
#     own child's environment;
#   - a live deck-chat primary, as bin/fm-primary-steer.sh status reports it
#     from state/primary-chat.json. Its endpoint may be null (a host not on a
#     stream endpoint); the target is then "-" and only the steer path can
#     deliver.

FM_SUPERVISOR_TARGET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# The endpoint of a LIVE deck-chat primary for this home, as the steer client
# reports it (`fm-primary-steer.sh status`; FM_PRIMARY_STEER_BIN overrides it).
# The client owns what "live" means for state/primary-chat.json - not stopped,
# and host_pid a running fm-deck-chat - so this never re-derives it. Prints the
# endpoint, or "-" when the host has none; returns 1 when there is no live host.
fm_supervisor_primary_chat_endpoint() {
  local bin status endpoint
  bin=${FM_PRIMARY_STEER_BIN:-$FM_SUPERVISOR_TARGET_LIB_DIR/fm-primary-steer.sh}
  [ -x "$bin" ] || return 1
  status=$("$bin" status --home "${FM_HOME:-$FM_SUPERVISOR_TARGET_LIB_DIR/..}" </dev/null 2>/dev/null) || return 1
  endpoint=$(printf '%s' "$status" | jq -r '.endpoint // empty' 2>/dev/null) || return 1
  printf '%s' "${endpoint:--}"
}

# discover_supervisor_source: name which signal selects the supervisor, in the
# precedence both discover_* functions below share. One of
# FM_STREAM_ENDPOINT_ID, PRIMARY_CHAT_RECORD, or NONE. Explicit overrides are
# handled and reported by the callers, not this helper.
discover_supervisor_source() {
  if fm_supervisor_stream_env_target >/dev/null 2>&1; then
    printf 'FM_STREAM_ENDPOINT_ID'
  elif fm_supervisor_primary_chat_endpoint >/dev/null 2>&1; then
    printf 'PRIMARY_CHAT_RECORD'
  else
    printf 'NONE'
  fi
}

# discover_supervisor_target: resolve the endpoint running firstmate. Priority:
#   1. FM_SUPERVISOR_TARGET env (explicit override), a stream
#      "<hub-tag>:<endpoint-id>" target.
#   2. FM_STREAM_ENDPOINT_ID + FM_STREAM_HUB - this process runs inside a stream
#      endpoint; compose its "<hub-tag>:<endpoint-id>" target.
#   3. a live deck-chat primary (steer status) - its endpoint, or "-" when null.
#   4. "-" - nothing found. Returns 1 so the caller can warn; only the steer
#      path could deliver, and it has no live host either.
discover_supervisor_target() {
  if [ -n "${FM_SUPERVISOR_TARGET:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_TARGET"
    return 0
  fi
  case "$(discover_supervisor_source)" in
    FM_STREAM_ENDPOINT_ID) fm_supervisor_stream_env_target; return 0 ;;
    PRIMARY_CHAT_RECORD) fm_supervisor_primary_chat_endpoint; return 0 ;;
  esac
  printf -- '-'
  return 1
}

# discover_supervisor_backend: the supervisor endpoint's backend. stream is the
# only one; FM_SUPERVISOR_BACKEND may still name it explicitly, and any other
# value is passed through so the daemon refuses it loudly. Returns 1 when no
# signal found a primary, matching discover_supervisor_target.
discover_supervisor_backend() {
  if [ -n "${FM_SUPERVISOR_BACKEND:-}" ]; then
    printf '%s' "$FM_SUPERVISOR_BACKEND"
    return 0
  fi
  printf 'stream'
  case "$(discover_supervisor_source)" in
    NONE) return 1 ;;
  esac
  return 0
}
