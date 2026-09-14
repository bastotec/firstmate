#!/usr/bin/env bash
# Validate and probe home-local account slots without exposing account identity.
# Usage:
#   fm-account-slot.sh validate
#   fm-account-slot.sh probe <slot>
#   fm-account-slot.sh probe-all [<slot>...]
#
# FM_HOME selects the home. FM_CONFIG_OVERRIDE selects its exact config
# directory. probe-all de-duplicates explicitly named slots, validates the
# registry and references as one configuration, then probes sequentially. With
# no names it probes every configured slot. A valid but unavailable slot emits
# only its logical ID plus availability.status=unavailable and does not stop
# later slots; malformed configuration and missing requested IDs still refuse.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-account-slot-lib.sh
. "$SCRIPT_DIR/fm-account-slot-lib.sh"

die_slot() {
  printf 'error: %s\n' "$FM_ACCOUNT_SLOT_ERROR" >&2
  exit 1
}

case "${1:-}" in
  validate)
    [ "$#" -eq 1 ] || { echo "usage: fm-account-slot.sh validate" >&2; exit 2; }
    fm_account_slot_validate_registry "$CONFIG" || die_slot
    fm_account_slot_validate_dispatch "$CONFIG" || die_slot
    printf 'account slots valid\n'
    ;;
  probe)
    [ "$#" -eq 2 ] || { echo "usage: fm-account-slot.sh probe <slot>" >&2; exit 2; }
    fm_account_slot_probe "$CONFIG" "$2" || die_slot
    ;;
  probe-all)
    shift
    fm_account_slot_validate_registry "$CONFIG" || die_slot
    fm_account_slot_validate_dispatch "$CONFIG" || die_slot
    fm_quota_axi_supports_profile_only \
      || { FM_ACCOUNT_SLOT_ERROR="quota-axi does not support --profile-only; install a published release that advertises that flag"; die_slot; }
    slots=
    if [ "$#" -eq 0 ]; then
      slots=$(jq -r '.slots | keys[]' "$CONFIG/account-slots.json")
    else
      for slot in "$@"; do
        case $'\n'"$slots"$'\n' in *$'\n'"$slot"$'\n'*) continue ;; esac
        slots=${slots:+$slots$'\n'}$slot
      done
    fi
    while IFS= read -r slot; do
      [ -n "$slot" ] || continue
      harness=$(jq -r --arg slot "$slot" '.slots[$slot].harness // empty' "$CONFIG/account-slots.json") \
        || { FM_ACCOUNT_SLOT_ERROR="slot '$slot' cannot be read"; die_slot; }
      [ -n "$harness" ] || { FM_ACCOUNT_SLOT_ERROR="slot '$slot' is not configured in this home"; die_slot; }
    done <<< "$slots"
    tmp=$(mktemp "${TMPDIR:-/tmp}/fm-account-slots.XXXXXX") || exit 1
    trap 'rm -f "$tmp"' EXIT
    : > "$tmp"
    while IFS= read -r slot; do
      [ -n "$slot" ] || continue
      if ! fm_account_slot_probe "$CONFIG" "$slot" >> "$tmp"; then
        jq -cn --arg slot "$slot" '{accountSlot:$slot,availability:{status:"unavailable"}}' >> "$tmp" \
          || { FM_ACCOUNT_SLOT_ERROR="sanitized unavailable evidence could not be emitted"; die_slot; }
      fi
    done <<< "$slots"
    jq -sc '{slots:.}' "$tmp"
    ;;
  -h|--help|'')
    sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "usage: fm-account-slot.sh validate|probe <slot>|probe-all [<slot>...]" >&2
    exit 2
    ;;
esac
