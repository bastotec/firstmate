#!/usr/bin/env bash
# shellcheck disable=SC2034

fm_launch_env_read() {
  local config=$1
  FM_LAUNCH_ENV_FLOOR='HOME PATH USER LOGNAME SHELL TERM COLORTERM LANG LC_ALL LC_CTYPE TMPDIR TMP TEMP GOTMPDIR FM_TASK_ID'
  LAUNCH_ENV_ENABLED=$(fm_config_source_present "$config/launch-env-allowlist") || return 1
  LAUNCH_ENV_NAMES=
  if [ "$LAUNCH_ENV_ENABLED" = 1 ]; then
    if [ ! -f "$config/launch-env-allowlist" ] || [ ! -r "$config/launch-env-allowlist" ]; then
      echo 'error: config/launch-env-allowlist must be a readable regular file' >&2
      return 1
    fi
    if ! LAUNCH_ENV_NAMES=$(jq -Rrs '
      split("\n") | map(select(. != "" and (startswith("#") | not))) |
      if all(.[]; test("^[A-Za-z_][A-Za-z0-9_]*$")) then .[]
      else error("expected environment names only") end
    ' "$config/launch-env-allowlist" 2>/dev/null); then
      echo 'error: config/launch-env-allowlist must contain one environment name per line, blank lines, or # comments' >&2
      return 1
    fi
  fi
}
