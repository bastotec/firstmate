#!/usr/bin/env bash
# Private startup event writer, sourced by session-start and wake-drain.
# bin/fm-session-start.sh owns opt-in creation, format, and artifact lifetime.
# Fixed labels only: never pass command output, arguments, or task identifiers.
startup_diagnostic() {  # <fixed-event> <fixed-stage>
  [ -n "${FM_SESSION_START_DIAGNOSTIC_FILE:-}" ] || return 0
  case "${1:-}" in enter|complete|timeout|failed) ;; *) return 0 ;; esac
  case "${2:-}" in
    harness|tasks-compatibility|lock|trace-context|home-summary|network-launch|bootstrap|decision-cards|wake-queue|supervision-instructions|read-once|fleet-state|network-checks|context|next-step|unknown|wake-queue-lock|wake-queue-read|wake-presentation-lock|wake-snapshot|wake-annotations|wake-sections|wake-record-divergence|wake-receipt|wake-possible-asks|wake-liveness) ;;
    *) return 0 ;;
  esac
  printf 'v1\t%s\t%s\t%s\n' "$(date +%s)" "$1" "$2" \
    >> "$FM_SESSION_START_DIAGNOSTIC_FILE" 2>/dev/null || true
}
