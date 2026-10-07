#!/usr/bin/env bash
# Check, and optionally repair, one remote account's second-mate readiness.
#
# Usage:
#   bin/fm-on.sh <secondmate-id|ssh-alias> fm-remote-doctor.sh [--backend stream] [--fix]
#
# Run it through fm-on.sh so the fixed entrypoint invokes this readiness owner
# over its plain SSH bootstrap. The command reports the same filesystem-composed
# PATH used by worker jobs while retaining authority to inspect and repair the
# worker itself. --backend stream is accepted (and is the only backend) so a
# parent that names it explicitly works against any checkout.
#
# A remote second mate runs on a stream endpoint, so the host needs: the
# sibling dev.firstmate.remote-job worker that runs normal fm-on commands
# through the Aqua (darwin, which needs a GUI login session) or Linux
# job-worker path; stream-tools (curl, jq, python3, and this checkout's stream
# agent); stream-token (the selected home's config/stream-token is readable and
# non-empty; its value is never printed); stream-hub (the hub that home's
# config/stream-hub names answers this host with that token on the adapter's
# protocol); and stream-survival (on Linux, systemd-logind does not kill the
# user's processes at logout, so a stream agent started over SSH outlives the
# connection). Every stream gap is a human one: --fix never starts a hub or
# mints a credential. SSH cannot create an Aqua session, so a darwin host with
# no GUI login is a human gap rather than something --fix attempts to bypass.
#
# Line protocol, one fact per line, stable for script consumers:
#   mode=check|fix
#   backend=stream
#   path=<the child PATH this command inherited>
#   entrypoint=yes|no
#   platform=darwin|linux|<uname -s>|unknown
#   required <tool>=<path>|MISSING|VERSION_UNREADABLE (requires semantic version >=<floor>)
#   optional <tool>=<path>|absent
#   fix <check>=applied: <what changed>       (--fix only)
#   fix <check>=failed: <why the repair did not land>   (--fix only)
#   check <check>=ok: <evidence>
#   check <check>=skip: <why this host is exempt>
#   check <check>=fixable: <gap --fix can close>
#   check <check>=human: <gap only a person at that machine can close>
#   action: <check>: <the exact step to take>
# Every check line is authoritative for the moment it printed: under --fix it is
# the state after the repair attempt, so a human gap is never presented as
# fixed. Any remaining fixable or human gap, and any missing required tool,
# exits non-zero.
#
# --fix is idempotent and closes only automatable gaps: it writes and reloads
# the remote-job Aqua agent, starts the Linux worker where no Aqua agent
# applies, recreates the entrypoint
# symlink, and may add an owned ~/.local/bin
# wrapper for a required tool it can discover under nvm, asdf, or mise. It never
# installs packages, creates a login session, writes an auto-login password,
# changes FileVault, stores an account password, or replaces a non-Firstmate
# wrapper; those remain reported gaps.
set -eu

# Resolve this script's directory with builtins only: a host missing a required
# tool must still reach the report that names it, not die on a bare PATH.
SCRIPT_SELF=${BASH_SOURCE[0]}
SCRIPT_DIR=${SCRIPT_SELF%/*}
[ "$SCRIPT_DIR" != "$SCRIPT_SELF" ] || SCRIPT_DIR=.
SCRIPT_DIR=$(CDPATH='' cd -- "$SCRIPT_DIR" && pwd -P)
FM_ROOT="${FM_ROOT_OVERRIDE:-$(CDPATH='' cd "$SCRIPT_DIR/.." && pwd -P)}"
# shellcheck source=bin/fm-remote-job-lib.sh
. "$SCRIPT_DIR/fm-remote-job-lib.sh"
# shellcheck source=bin/fm-tasks-axi-lib.sh
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
REQUIRED_TOOLS=(git jq tasks-axi treehouse)
HARNESS_TOOLS=(deck)
OPTIONAL_TOOLS=(no-mistakes gh)
ENTRYPOINT_LINK="${HOME:-}/.local/bin/fm-remote-entrypoint.sh"

usage() { sed -n '2,5p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

MODE=check
if [ "${1:-}" = --backend ]; then
  [ "${2:-}" = stream ] || usage
  shift 2
fi
case "${1:-}" in
  '') ;;
  --fix) MODE=fix; shift ;;
  --worker-tool-probe)
    [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] || { printf 'error: worker tool probe requires the remote job worker\n' >&2; exit 64; }
    MODE='worker-tool-probe'
    shift
    ;;
  *) usage ;;
esac
[ "$#" -eq 0 ] || usage

PLATFORM=$(fm_remote_job_platform)
UID_NUM=$(id -u 2>/dev/null) || UID_NUM=

CHECK_NAMES=()
CHECK_VALUES=()
CHECK_ACTIONS=()

record() { # <name> <value> [operator-action]
  CHECK_NAMES+=("$1")
  CHECK_VALUES+=("$2")
  CHECK_ACTIONS+=("${3:-}")
}

check_value() { # <name>; prints the recorded value, empty when unrecorded
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      printf '%s' "${CHECK_VALUES[$i]}"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

check_is_ok() { # <name>
  case "$(check_value "$1" 2>/dev/null || true)" in ok:*) return 0 ;; esac
  return 1
}

set_check() { # <name> <value> [operator-action]
  local i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    if [ "${CHECK_NAMES[$i]}" = "$1" ]; then
      CHECK_VALUES[i]=$2
      CHECK_ACTIONS[i]=${3:-}
      return 0
    fi
    i=$((i + 1))
  done
  record "$@"
}

# --- remote job and tool checks ---------------------------------------------

remote_job_existing_state() {
  local root
  root=${FM_REMOTE_JOB_STATE_ROOT:-${HOME:-}/.firstmate/remote-job}
  root=$(fm_remote_job_canonical_existing_dir "$root") || return 1
  fm_remote_job_canonical_existing_dir "$root/jobs" >/dev/null || return 1
  # shellcheck disable=SC2034 # The sourceable worker helpers consume the validated state root.
  FM_REMOTE_JOB_STATE=$root
}

remote_job_probe_ok() {
  local ready mtime now
  [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] && return 0
  remote_job_existing_state || return 1
  ready="$FM_REMOTE_JOB_STATE/worker.ready"
  [ -f "$ready" ] && [ ! -L "$ready" ] || return 1
  mtime=$(fm_remote_job_path_mtime "$ready" 2>/dev/null || true)
  case "$mtime" in ''|*[!0-9]*) return 1 ;; esac
  now=$(date +%s)
  [ $((now - mtime)) -le 10 ]
}

remote_job_identity_ok() {
  [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] && return 0
  remote_job_probe_ok || return 1
  fm_remote_job_worker_identity_matches "$FM_ROOT" "${HOME:-}"
}

check_remote_job_worker() {
  local worker
  worker="$FM_ROOT/bin/fm-remote-job-worker.sh"
  if [ ! -f "$worker" ] || [ -L "$worker" ] || [ ! -x "$worker" ]; then
    record remote-job-worker "human: the configured Firstmate code root has no safe remote job worker" \
      "update the remote Firstmate checkout, then rerun this command with --fix"
    record remote-job-worker-loaded "skip: no worker executable is available"
    record remote-job-probe "skip: no worker executable is available"
    return 0
  fi
  if [ "$PLATFORM" = darwin ]; then
    fm_remote_job_launchagent_paths "${HOME:-}"
    if fm_remote_job_launchagent_contract_matches "$FM_ROOT" "${HOME:-}"; then
      record remote-job-worker "ok: $FM_REMOTE_JOB_LAUNCH_AGENT_PLIST matches the Firstmate-owned Aqua worker contract"
    else
      record remote-job-worker "fixable: $FM_REMOTE_JOB_LAUNCH_AGENT_PLIST does not match the Firstmate-owned Aqua worker contract" \
        "rerun this command with --fix to write dev.firstmate.remote-job"
    fi
    if [ -z "$UID_NUM" ] || ! command -v launchctl >/dev/null 2>&1; then
      record remote-job-worker-loaded "human: the remote job worker cannot be inspected without launchctl and an account uid" \
        "restore launchctl and a readable account uid, then rerun this command"
    elif fm_remote_job_launchagent_loaded "$FM_ROOT" "${HOME:-}" "$UID_NUM"; then
      record remote-job-worker-loaded "ok: $FM_REMOTE_JOB_LABEL is loaded in gui/$UID_NUM"
    elif check_is_ok gui-session; then
      record remote-job-worker-loaded "fixable: $FM_REMOTE_JOB_LABEL is not loaded in gui/$UID_NUM" \
        "rerun this command with --fix to bootstrap the worker"
    else
      record remote-job-worker-loaded "human: $FM_REMOTE_JOB_LABEL cannot be loaded because gui/$UID_NUM has no login session" \
        "close the login-session gap first; SSH cannot create an Aqua session"
    fi
  else
    local pid
    pid=$(cat "${FM_REMOTE_JOB_STATE_ROOT:-${HOME:-}/.firstmate/remote-job}/worker.pid" 2>/dev/null || true)
    if [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] ||
      { remote_job_existing_state && case "$pid" in ''|*[!0-9]*) false ;; *) kill -0 "$pid" 2>/dev/null ;; esac; }; then
      record remote-job-worker "ok: the Linux remote job worker is running"
      record remote-job-worker-loaded "skip: Aqua launch agents do not apply on $PLATFORM"
    else
      record remote-job-worker "fixable: the Linux remote job worker is not running" \
        "rerun this command with --fix to start it"
      record remote-job-worker-loaded "skip: Aqua launch agents do not apply on $PLATFORM"
    fi
  fi
  if ! remote_job_probe_ok; then
    record remote-job-probe "fixable: the remote job worker has not reported a fresh probe" \
      "rerun this command with --fix to restart the worker, then rerun through fm-on.sh"
  elif ! remote_job_identity_ok; then
    set_check remote-job-worker "fixable: the running remote job worker does not match the current Firstmate code" \
      "rerun this command with --fix to reload the current worker"
    record remote-job-probe "fixable: the remote job worker identity is stale, so its runtime cannot be probed" \
      "rerun this command with --fix to reload the current worker"
  else
    record remote-job-probe "ok: the remote job worker published a fresh heartbeat"
  fi
}

selected_harness_tool() {
  local harness resolved
  for harness in "${HARNESS_TOOLS[@]}"; do
    resolved=$(command -v "$harness" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
      printf '%s\t%s\n' "$harness" "$resolved"
      return 0
    fi
  done
  return 1
}

report_required_tools() {
  local tool resolved harness status selected
  MISSING=()
  VERSION_UNREADABLE=()
  for tool in "${REQUIRED_TOOLS[@]}"; do
    resolved=$(command -v "$tool" 2>/dev/null || true)
    if [ -n "$resolved" ] && [ -x "$resolved" ]; then
      if [ "$tool" = tasks-axi ]; then
        if fm_tasks_axi_compatible; then
          printf 'required %s=%s\n' "$tool" "$resolved"
        else
          status=$?
          if [ "$status" -eq 2 ]; then
            printf 'required tasks-axi=VERSION_UNREADABLE (requires semantic version >=%s)\n' "$FM_TASKS_AXI_MIN"
            VERSION_UNREADABLE+=(tasks-axi)
          else
            printf 'required tasks-axi=MISSING (incompatible)\n'
            MISSING+=(tasks-axi)
          fi
        fi
      else
        printf 'required %s=%s\n' "$tool" "$resolved"
      fi
    else
      printf 'required %s=MISSING\n' "$tool"
      MISSING+=("$tool")
    fi
  done
  selected=$(selected_harness_tool 2>/dev/null || true)
  if [ -n "$selected" ]; then
    harness=${selected%%$'\t'*}
    resolved=${selected#*$'\t'}
    printf 'required harness=%s:%s\n' "$harness" "$resolved"
    if [ "$harness" = deck ]; then
      resolved=$(command -v python3 2>/dev/null || true)
      if [ -n "$resolved" ] && [ -x "$resolved" ]; then
        printf 'required python3=%s\n' "$resolved"
      else
        printf 'required python3=MISSING\n'
        MISSING+=(python3)
      fi
    fi
    return 0
  fi
  printf 'required harness=MISSING\n'
  MISSING+=(harness)
}

report_required_tools_from_worker() {
  local job_id probe_stdout probe_stderr probe_exit line fact name value problem_count
  local expected=5 count=0 valid=1 seen=' ' deck_harness=0 python_fact=0
  if ! job_id=$(fm_remote_job_stage "${HOME:-}" "$FM_ROOT" "${FM_HOME:-}" \
    fm-remote-doctor.sh --worker-tool-probe </dev/null); then
    set_check remote-job-probe "fixable: the remote job worker could not accept the required-tool probe" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
    return 0
  fi
  if ! fm_remote_job_wait "${HOME:-}" "$job_id"; then
    fm_remote_job_reap "${HOME:-}" "$job_id" 2>/dev/null || true
    set_check remote-job-probe "fixable: the remote job worker did not complete the required-tool probe" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
    return 0
  fi
  probe_stdout=$FM_REMOTE_JOB_STDOUT
  probe_stderr=$FM_REMOTE_JOB_STDERR
  probe_exit=$FM_REMOTE_JOB_EXIT
  MISSING=()
  VERSION_UNREADABLE=()
  while IFS= read -r line; do
    case "$line" in required\ *=*) ;; *) valid=0; continue ;; esac
    fact=${line#required }
    name=${fact%%=*}
    value=${fact#*=}
    case "$name" in git|jq|tasks-axi|treehouse|harness|python3) ;; *) valid=0; continue ;; esac
    case "$seen" in *" $name "*) valid=0; continue ;; esac
    seen="$seen$name "
    count=$((count + 1))
    [ "$name" != harness ] || case "$value" in deck:*) deck_harness=1 ;; esac
    [ "$name" != python3 ] || python_fact=1
    case "$value" in
      MISSING*) MISSING+=("$name") ;;
      VERSION_UNREADABLE*) VERSION_UNREADABLE+=("$name") ;;
      '') valid=0 ;;
    esac
  done < "$probe_stdout"
  if [ "$deck_harness" -eq 1 ]; then
    expected=6
    [ "$python_fact" -eq 1 ] || valid=0
  else
    [ "$python_fact" -eq 0 ] || valid=0
  fi
  [ "$count" -eq "$expected" ] || valid=0
  [ ! -s "$probe_stderr" ] || valid=0
  problem_count=$((${#MISSING[@]} + ${#VERSION_UNREADABLE[@]}))
  case "$probe_exit:$problem_count" in 0:0|1:[1-9]*) ;; *) valid=0 ;; esac
  if [ "$valid" -eq 1 ]; then
    cat "$probe_stdout"
    set_check remote-job-probe "ok: the remote job worker completed the required-tool probe"
  else
    set_check remote-job-probe "fixable: the remote job worker returned an invalid required-tool probe result" \
      "rerun this command with --fix to restart the worker"
    report_required_tools
  fi
  fm_remote_job_reap "${HOME:-}" "$job_id" 2>/dev/null || true
}

wrapper_is_firstmate_owned() { # <path>
  local path=$1 first second
  [ -f "$path" ] && [ ! -L "$path" ] || return 1
  IFS= read -r first < "$path" || return 1
  IFS= read -r second < <(tail -n +2 "$path") || return 1
  [ "$first" = '#!/usr/bin/env bash' ] && [ "$second" = '# Firstmate remote tool wrapper v1' ]
}

repair_tool_wrapper() { # <tool>
  local tool=$1 target wrapper tmp
  local resolved
  resolved=$(command -v "$tool" 2>/dev/null || true)
  [ -n "$resolved" ] && [ -x "$resolved" ] && return 0
  target=$(fm_remote_job_manager_tool "${HOME:-}" "$tool" 2>/dev/null || true)
  [ -n "$target" ] || return 1
  wrapper="${HOME:-}/.local/bin/$tool"
  if [ -e "$wrapper" ] || [ -L "$wrapper" ]; then
    if ! wrapper_is_firstmate_owned "$wrapper"; then
      fix_report "required-$tool" failed "$wrapper exists and is not Firstmate-owned"
      return 1
    fi
  else
    if ! mkdir -p "${HOME:-}/.local/bin" 2>/dev/null || [ -L "${HOME:-}/.local/bin" ]; then
      fix_report "required-$tool" failed "cannot create ${HOME:-}/.local/bin"
      return 1
    fi
  fi
  tmp="${HOME:-}/.local/bin/.$tool.tmp.$$"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' '# Firstmate remote tool wrapper v1'
    printf 'exec %q "$@"\n' "$target"
  } > "$tmp" || { rm -f -- "$tmp"; fix_report "required-$tool" failed "cannot write $wrapper"; return 1; }
  if ! chmod 0700 "$tmp" || ! mv -f -- "$tmp" "$wrapper"; then
    rm -f -- "$tmp"
    fix_report "required-$tool" failed "cannot publish $wrapper"
    return 1
  fi
  fix_report "required-$tool" applied "linked the discoverable version-manager tool at $wrapper"
}

repair_required_wrappers() {
  local tool selected harness
  for tool in "${REQUIRED_TOOLS[@]}"; do
    repair_tool_wrapper "$tool" || true
  done
  selected=$(selected_harness_tool 2>/dev/null || true)
  if [ -n "$selected" ]; then
    harness=${selected%%$'\t'*}
    if [ "$harness" = deck ]; then
      repair_tool_wrapper python3 || true
    fi
    return 0
  fi
  for tool in "${HARNESS_TOOLS[@]}"; do
    fm_remote_job_manager_tool "${HOME:-}" "$tool" >/dev/null 2>&1 || continue
    if repair_tool_wrapper "$tool"; then
      if [ "$tool" = deck ]; then
        repair_tool_wrapper python3 || true
      fi
      return 0
    fi
  done
}

fix_remote_job_worker() {
  if fm_remote_job_ensure_worker "$FM_ROOT" "${HOME:-}"; then
    [ "$FM_REMOTE_JOB_REPAIRED" -eq 0 ] || fix_report remote-job-worker applied "installed or reloaded $FM_REMOTE_JOB_LABEL"
    return 0
  fi
  fix_report remote-job-worker failed "${FM_REMOTE_JOB_ERROR:-the remote job worker could not start}"
  return 1
}

# --- checks -----------------------------------------------------------------

check_gui_session() {
  if [ "$PLATFORM" != darwin ]; then
    record gui-session "skip: no Aqua login session applies on $PLATFORM"
    return 0
  fi
  if [ -z "$UID_NUM" ]; then
    record gui-session "human: the account uid could not be read, so its login session cannot be inspected" \
      "run 'id -u' on that account and report the failure; Firstmate cannot address gui/<uid> without it"
    return 0
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    record gui-session "human: launchctl does not resolve, so the login session cannot be inspected" \
      "restore /bin/launchctl on that macOS account; without it no launch agent can be inspected or loaded"
    return 0
  fi
  if launchctl print "gui/$UID_NUM" >/dev/null 2>&1; then
    record gui-session "ok: gui/$UID_NUM"
    return 0
  fi
  record gui-session "human: no Aqua login session exists for uid $UID_NUM" \
    "log that account in once at the console, and enable automatic login in System Settings > Users & Groups if the machine runs headless; SSH cannot create a GUI session, and Firstmate never writes an auto-login password or changes FileVault"
}

check_entrypoint_link() {
  local want
  if [ -z "${FM_ROOT_OVERRIDE:-}" ]; then
    record entrypoint-link "skip: this run did not come through the fixed remote entrypoint"
    return 0
  fi
  want="$FM_ROOT_OVERRIDE/bin/fm-remote-entrypoint.sh"
  if [ -L "$ENTRYPOINT_LINK" ] && [ "$(readlink "$ENTRYPOINT_LINK")" = "$want" ]; then
    record entrypoint-link "ok: $ENTRYPOINT_LINK"
    return 0
  fi
  if [ -e "$ENTRYPOINT_LINK" ] || [ -L "$ENTRYPOINT_LINK" ]; then
    record entrypoint-link "human: $ENTRYPOINT_LINK exists but is not the symlink to $want" \
      "inspect that path yourself and replace it with 'ln -sfn $want $ENTRYPOINT_LINK' if it is stale; Firstmate never overwrites a file it did not create there"
    return 0
  fi
  record entrypoint-link "fixable: no entrypoint symlink at $ENTRYPOINT_LINK" \
    "rerun this command with --fix to create it"
}

# --- stream checks -------------------------------------------------------------

stream_adapter_load() {
  declare -F fm_backend_stream_version_check >/dev/null 2>&1 && return 0
  # A missing adapter must reach the stream-tools record, not exit the shell.
  [ -f "$SCRIPT_DIR/backends/stream.sh" ] || return 1
  # shellcheck source=bin/backends/stream.sh
  . "$SCRIPT_DIR/backends/stream.sh" 2>/dev/null
}

check_stream_tools() {
  local out
  if ! stream_adapter_load; then
    record stream-tools "human: this checkout's stream adapter bin/backends/stream.sh cannot be loaded" \
      "update this host's Firstmate checkout"
    return 0
  fi
  if out=$(fm_backend_stream_tool_check 2>&1); then
    record stream-tools "ok: curl, jq, python3, and $FM_BACKEND_STREAM_AGENT_BIN"
  else
    record stream-tools "human: ${out#error: }" \
      "install the missing tool on that account's runtime PATH"
  fi
}

check_stream_home() {
  local out token_file reason
  if [ ! -e "${FM_HOME:-$FM_ROOT}" ] && [ ! -L "${FM_HOME:-$FM_ROOT}" ]; then
    record stream-token "skip: the destination home has not been provisioned"
    record stream-hub "skip: the destination home has not been provisioned"
    return 0
  fi
  stream_adapter_load || return 0
  token_file="$(fm_backend_stream_config_dir)/stream-token"
  if [ -n "${FM_STREAM_TOKEN:-}" ]; then
    record stream-token "ok: FM_STREAM_TOKEN is set"
  elif [ -f "$token_file" ] && [ -r "$token_file" ] && fm_backend_stream_config_line stream-token >/dev/null; then
    record stream-token "ok: $token_file is readable"
  else
    record stream-token "human: $token_file is missing, unreadable, or empty" \
      "seed this home's stream credential from the home that hosts the hub (docs/stream-backend.md \"Security\")"
  fi
  if ! check_is_ok stream-tools || ! check_is_ok stream-token; then
    record stream-hub "skip: the stream tools or token gap above comes first"
  elif out=$(fm_backend_stream_version_check 2>&1); then
    record stream-hub "ok: $(fm_backend_stream_hub_url) accepted this home's token on protocol $FM_BACKEND_STREAM_PROTOCOL"
  else
    reason=$(printf '%s\n' "$out" | sed -n '1{s/^error: //;p;}')
    record stream-hub "human: ${reason:-the hub at $(fm_backend_stream_hub_url) did not answer}" \
      "start or restart the fleet hub on its host, or fix this home's config/stream-hub and config/stream-token"
  fi
}

check_stream_survival() {
  local out
  if [ "$PLATFORM" != linux ]; then
    record stream-survival "skip: logind applies only on linux"
    return 0
  fi
  if ! command -v busctl >/dev/null 2>&1; then
    record stream-survival "skip: busctl does not resolve, so systemd-logind cannot be asked"
    return 0
  fi
  out=$(busctl get-property org.freedesktop.login1 /org/freedesktop/login1 \
    org.freedesktop.login1.Manager KillUserProcesses 2>/dev/null || true)
  case "$out" in
    'b false') record stream-survival "ok: systemd-logind KillUserProcesses=no" ;;
    'b true')
      record stream-survival "human: systemd-logind kills this user's processes at logout, so a stream agent started over SSH would die with the connection" \
        "set KillUserProcesses=no in /etc/systemd/logind.conf on that host"
      ;;
    *) record stream-survival "skip: systemd-logind did not report KillUserProcesses" ;;
  esac
}

run_checks() {
  CHECK_NAMES=()
  CHECK_VALUES=()
  CHECK_ACTIONS=()
  check_stream_tools
  check_stream_home
  check_stream_survival
  check_gui_session
  check_remote_job_worker
  check_entrypoint_link
}

# --- repairs ----------------------------------------------------------------

fix_report() { # <check> applied|failed <text>
  printf 'fix %s=%s: %s\n' "$1" "$2" "$3"
}

link_entrypoint() {
  local want="${FM_ROOT_OVERRIDE:-}/bin/fm-remote-entrypoint.sh"
  if ! mkdir -p "$(dirname "$ENTRYPOINT_LINK")" 2>/dev/null; then
    fix_report entrypoint-link failed "cannot create $(dirname "$ENTRYPOINT_LINK")"
    return 1
  fi
  if ! ln -s "$want" "$ENTRYPOINT_LINK" 2>/dev/null; then
    fix_report entrypoint-link failed "cannot create the symlink at $ENTRYPOINT_LINK"
    return 1
  fi
  fix_report entrypoint-link applied "linked $ENTRYPOINT_LINK to $want"
}

apply_fixes() {
  local i name value remote_job_fixed=0
  repair_required_wrappers
  i=0
  while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
    name=${CHECK_NAMES[$i]}
    value=${CHECK_VALUES[$i]}
    i=$((i + 1))
    case "$value" in fixable:*) ;; *) continue ;; esac
    case "$name" in
      remote-job-worker|remote-job-worker-loaded|remote-job-probe)
        [ "$remote_job_fixed" -eq 0 ] || continue
        remote_job_fixed=1
        fix_remote_job_worker || true
        ;;
      entrypoint-link) link_entrypoint || true ;;
    esac
  done
}

# --- report -----------------------------------------------------------------

if [ "$MODE" = worker-tool-probe ]; then
  report_required_tools
  [ "$((${#MISSING[@]} + ${#VERSION_UNREADABLE[@]}))" -eq 0 ]
  exit
fi

printf 'mode=%s\n' "$MODE"
printf 'backend=stream\n'
printf 'path=%s\n' "${PATH:-}"
if [ -n "${FM_ROOT_OVERRIDE:-}" ] && [ "${PATH%%:*}" = "$FM_ROOT_OVERRIDE/bin" ]; then
  printf 'entrypoint=yes\n'
else
  printf 'entrypoint=no\n'
  printf 'note: not launched through the fixed remote entrypoint; the reported PATH is this caller environment.\n' >&2
fi
printf 'platform=%s\n' "$PLATFORM"

run_checks
if [ "$MODE" = fix ]; then
  apply_fixes
  # Re-derive every check from the host itself, so what prints below is the
  # state after repair rather than the intent of a repair.
  run_checks
fi

if [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] || ! remote_job_identity_ok; then
  report_required_tools
else
  report_required_tools_from_worker
fi
for tool in "${OPTIONAL_TOOLS[@]}"; do
  if resolved=$(command -v "$tool" 2>/dev/null); then
    printf 'optional %s=%s\n' "$tool" "$resolved"
  else
    printf 'optional %s=absent\n' "$tool"
  fi
done

GAPS=()
i=0
while [ "$i" -lt "${#CHECK_NAMES[@]}" ]; do
  printf 'check %s=%s\n' "${CHECK_NAMES[$i]}" "${CHECK_VALUES[$i]}"
  case "${CHECK_VALUES[$i]}" in
    fixable:*|human:*) GAPS+=("$i") ;;
  esac
  i=$((i + 1))
done
for i in ${GAPS[@]+"${GAPS[@]}"}; do
  [ -z "${CHECK_ACTIONS[$i]}" ] || printf 'action: %s: %s\n' "${CHECK_NAMES[$i]}" "${CHECK_ACTIONS[$i]}"
done

if [ "${#MISSING[@]}" -gt 0 ]; then
  printf 'error: required tools do not resolve on the remote runtime PATH: %s\n' "${MISSING[*]}" >&2
  printf 'fix: install each one where it resolves on the path reported above, or put a wrapper script for it in %s/.local/bin, which is always on that PATH.\n' "${HOME:-~}" >&2
  printf 'fix: tools in an unselected nvm version or outside the discovered asdf or mise paths need an absolute wrapper; see docs/remote-secondmates.md for the wrapper recipe.\n' >&2
fi
if [ "${#VERSION_UNREADABLE[@]}" -gt 0 ]; then
  printf 'error: required tool versions are unreadable on the remote runtime PATH: %s\n' "${VERSION_UNREADABLE[*]}" >&2
  printf 'fix: upgrade each unreadable tool to a build that reports a semantic version meeting the floor shown above.\n' >&2
fi
if [ "${#MISSING[@]}" -gt 0 ] || [ "${#VERSION_UNREADABLE[@]}" -gt 0 ] || [ "${#GAPS[@]}" -gt 0 ]; then
  NAMES=
  for i in ${GAPS[@]+"${GAPS[@]}"}; do
    NAMES="${NAMES:+$NAMES }${CHECK_NAMES[$i]}"
  done
  printf 'error: this host is not ready for a remote second mate%s\n' "${NAMES:+; unresolved: $NAMES}" >&2
  exit 1
fi
printf 'ok: remote second-mate readiness confirmed on this host\n'
