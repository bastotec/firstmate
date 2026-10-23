#!/usr/bin/env bash
# Select private startup timings in the destination home, including remote launches.
# Usage: fm-startup-diagnostics.sh enable|disable
# Local: FM_HOME=<destination-home> bin/fm-startup-diagnostics.sh enable
# Remote: bin/fm-on.sh <mate> fm-startup-diagnostics.sh enable
# enable atomically writes 1 to config/startup-diagnostics in that home, so
# selection survives launch environment stripping; disable removes the selector.
# Does not start, stop, or restart a session. Disable after the authorized start;
# selection otherwise persists for subsequent starts. Artifact format and
# retention are owned by bin/fm-session-start.sh's header.
set -eu
case "${1:-}" in
  enable|disable) [ "$#" -eq 1 ] || exit 2 ;;
  *) printf 'usage: fm-startup-diagnostics.sh enable|disable\n' >&2; exit 2 ;;
esac
: "${FM_HOME:?FM_HOME is required}"
[ -d "$FM_HOME" ] && [ ! -L "$FM_HOME/config" ] || exit 1
[ ! -e "$FM_HOME/config/startup-diagnostics" ] \
  || { [ -f "$FM_HOME/config/startup-diagnostics" ] && [ ! -L "$FM_HOME/config/startup-diagnostics" ]; } \
  || exit 1
if [ "$1" = enable ]; then
  (umask 077; mkdir -p "$FM_HOME/config")
  marker=$(umask 077; mktemp "$FM_HOME/config/.startup-diagnostics.XXXXXX")
  trap 'rm -f "$marker"' EXIT
  printf '1\n' > "$marker"
  mv -f "$marker" "$FM_HOME/config/startup-diagnostics"
else
  rm -f "$FM_HOME/config/startup-diagnostics"
fi
printf 'startup diagnostics: %sd for the next destination-home starts\n' "$1"
