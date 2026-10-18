#!/usr/bin/env bash
# fm-dream.sh - the fleet's nightly pass over its own day ("dreaming").
#
# Usage:
#   fm-dream.sh run [--only collect|skills|instructions|triage|file|memory ...] [--dry-run]
#   fm-dream.sh status [--json]
#   fm-dream.sh install-service     macOS launchd agent, nightly at 04:15
#   fm-dream.sh uninstall-service
#
# bin/fm_dream.py owns the steps, their guards and budgets, the run log under
# state/dream/, and the summary bin/fm_report.py shows; read its header first.
# Its header also owns the instructions step's gated harness-PR exception.
#
# The launchd agent runs `run` once a night on the main home's machine. It is
# not KeepAlive; a run that is still going when the next one starts is refused
# by the run lock. 04:15 leaves Ziggy's own 02:30 dream room to finish, and the
# run waits while that one is still going anyway.
#
# Environment:
#   FM_HOME                 the home (default: this checkout)
#   FM_LAUNCHCTL, FM_LAUNCH_AGENTS_DIR   launchctl and LaunchAgents dir (tests)
#
# Exit codes: 0 completed (steps may be partial); 1 refused, setup failure or
# interrupted; 2 usage.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME=${FM_HOME:-$(cd "$SCRIPT_DIR/.." && pwd)}
usage() { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }
die() { printf 'fm-dream: %s\n' "$1" >&2; exit "${2:-1}"; }

MODE=${1:-}
case "$MODE" in ''|-h|--help) usage ;; esac
shift

label() {
  printf 'dev.firstmate.dream.%s' "$(printf '%s' "$FM_HOME" \
    | python3 -c 'import hashlib,sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest()[:12])')"
}

service_prereqs() {
  LAUNCHCTL=${FM_LAUNCHCTL:-}
  if [ -z "$LAUNCHCTL" ]; then
    [ "$(uname)" = Darwin ] || die 'the dreaming service is a launchd agent and runs only on macOS' 2
    LAUNCHCTL=$(command -v launchctl 2>/dev/null) || die 'launchctl not found' 2
  fi
  AGENTS_DIR=${FM_LAUNCH_AGENTS_DIR:-$HOME/Library/LaunchAgents}
  LABEL=$(label)
  PLIST="$AGENTS_DIR/$LABEL.plist"
  DOMAIN="gui/$(id -u)"
}

case "$MODE" in
  run|status)
    exec python3 "$SCRIPT_DIR/fm_dream.py" "$MODE" --home "$FM_HOME" "$@"
    ;;
  install-service)
    [ $# -eq 0 ] || usage
    AT=04:15
    service_prereqs
    BASH_BIN=$(command -v bash) || die 'bash not found on PATH' 2
    mkdir -p "$AGENTS_DIR" "$FM_HOME/state/dream" || die "cannot create $AGENTS_DIR or state/dream" 2
    python3 - "$PLIST" "$LABEL" "$FM_HOME" "$BASH_BIN" "$SCRIPT_DIR/fm-dream.sh" "$AT" <<'PY' \
      || die "could not write $PLIST" 2
import os, plistlib, sys, tempfile
plist, label, home, bash, script, at = sys.argv[1:7]
hour, minute = (int(x) for x in at.split(':'))
env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin'), 'HOME': os.environ.get('HOME', ''), 'FM_HOME': home}
for name in ('LANG', 'LC_ALL', 'TMPDIR'):
    if os.environ.get(name):
        env[name] = os.environ[name]
log = os.path.join(home, 'state', 'dream', 'service.log')
body = plistlib.dumps({
    'Label': label, 'ProgramArguments': [bash, script, 'run'], 'EnvironmentVariables': env,
    'WorkingDirectory': home, 'StartCalendarInterval': {'Hour': hour, 'Minute': minute},
    'ProcessType': 'Background', 'LowPriorityIO': True, 'Nice': 10,
    'StandardOutPath': log, 'StandardErrorPath': log})
fd, tmp = tempfile.mkstemp(prefix='.' + os.path.basename(plist) + '.', dir=os.path.dirname(plist))
with os.fdopen(fd, 'wb') as handle:
    handle.write(body)
os.chmod(tmp, 0o644)
os.replace(tmp, plist)
PY
    "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    "$LAUNCHCTL" bootstrap "$DOMAIN" "$PLIST" || die "launchctl bootstrap $DOMAIN $PLIST failed"
    printf 'service: %s/%s runs nightly at %s (%s)\n' "$DOMAIN" "$LABEL" "$AT" "$PLIST"
    ;;
  uninstall-service)
    service_prereqs
    "$LAUNCHCTL" bootout "$DOMAIN/$LABEL" >/dev/null 2>&1 || true
    rm -f "$PLIST"
    printf 'service: %s/%s removed\n' "$DOMAIN" "$LABEL"
    ;;
  *) usage ;;
esac
