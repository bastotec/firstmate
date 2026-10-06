#!/usr/bin/env bash
# fm-control-lib.sh - the ONE executable owner of firstmate's agent lifecycle
# CONTROL-PLANE mechanics.
#
# Data plane vs control plane (captain-approved root architecture, 2026-07-13).
# bin/fm-send.sh is the DATA plane: conversational text for the agent to read,
# always routing-marked for a kind=secondmate target so the reply comes back
# through the status path. That marking is exactly right for a message and
# exactly wrong for a lifecycle command: a marked "/quit" arrives as ordinary
# chat ("[fm-from-firstmate] /quit") that the agent reasons ABOUT instead of
# executing. bin/fm-control.sh is the CONTROL plane: allowlisted lifecycle
# verbs addressed to an exact task id, with the per-harness mechanics owned
# here rather than improvised per harness in agent prose.
#
# This file owns three capability tables plus their pure artifact-path tables
# and nothing else. It has no side effects, runs no backend command, and reads
# no state, so it can be sourced by a test as a pure contract:
#
#   1. Verb allowlist. There is no arbitrary-text and no generic raw-key entry
#      point on the control plane; a caller either names an allowlisted verb or
#      is refused.
#   2. Per-harness control mechanics: which key interrupts a running turn, how
#      many times it must be sent, whether the composer needs clearing after
#      that key, which command exits the agent, and which task kinds the adapter is
#      verified to run. These are the empirically verified facts previously
#      carried only in the harness-adapters skill's per-adapter tables; that
#      skill now points here so one executable owner holds them, and
#      bin/fm-send.sh's --key path reads the same table rather than a second
#      copy of it.
#   3. Per-backend capability: which named keys a runtime backend can deliver,
#      and whether the backend has a recovery-grade agent-state classifier
#      (bin/fm-backend.sh's fm_backend_agent_state) able to PROVE that an agent
#      stopped or that its endpoint is gone. A verb whose postcondition cannot
#      be proven on the recorded backend is refused rather than performed
#      blind.
#
# `resume` is deliberately NOT a verb. Neither pi, pi-signed, nor deck has a
# verified pane-resume contract. `relaunch` covers the same need deterministically for every adapter,
# because the brief on disk - not a harness-private session - is the durable
# instruction.

# The complete control-plane verb allowlist, one per line.
fm_control_verbs() {
  cat <<'EOF'
interrupt
exit
relaunch
recover-missing
EOF
}

fm_control_verb_allowed() {  # <verb>
  case "${1-}" in
    interrupt|exit|relaunch|recover-missing) return 0 ;;
  esac
  return 1
}

# The harnesses whose control mechanics are implemented.
fm_control_harness_supported() {  # <harness>
  case "${1-}" in
    pi|pi-signed|deck) return 0 ;;
  esac
  return 1
}

# The recognized adapter a RECORDED harness value belongs to. Every table below
# is keyed by the exact adapter name. `pi` and `pi-signed` are exact because a
# `pi*` prefix would swallow the signed adapter, and an unrecognized value
# returns nonzero rather than being guessed into a family.
fm_control_harness_family() {  # <recorded-harness>
  case "${1-}" in
    pi) printf 'pi' ;;
    pi-signed) printf 'pi-signed' ;;
    deck) printf 'deck' ;;
    *) return 1 ;;
  esac
}

# Which task kinds an adapter can run. Every supported adapter runs every
# kind. The control plane asks this BEFORE it stops anything, so an
# incompatible relaunch target is refused while the current agent is still
# running rather than after it has been stopped.
fm_control_harness_supports_kind() {  # <harness> <kind>
  local harness=${1-}
  fm_control_harness_supported "$harness" || return 1
  return 0
}

# The key that cancels a running turn. Pi cancels on a single Escape and
# leaves an empty composer.
fm_control_interrupt_key() {  # <harness>
  case "${1-}" in
    pi|pi-signed) printf 'Escape' ;;
    # deck's pane runs bin/fm-deck-worker.sh, which cancels the running turn on
    # Ctrl+C (the whole foreground group gets SIGINT; the driver traps it and
    # returns to its prompt), and has no Escape binding.
    deck) printf 'C-c' ;;
    *) return 1 ;;
  esac
}

# How many times the interrupt key must be delivered. Every verified adapter
# interrupts on a single press.
fm_control_interrupt_repeat() {  # <harness>
  case "${1-}" in
    pi|pi-signed|deck) printf '1' ;;
    *) return 1 ;;
  esac
}

# The key that must follow the interrupt key to leave the composer empty, or
# nothing when the adapter needs none. No supported adapter restores the
# cancelled prompt into its composer. Prints the key or nothing; a harness
# with no verified mechanics returns nonzero, matching the tables above.
fm_control_interrupt_clear_key() {  # <harness>
  case "${1-}" in
    pi|pi-signed|deck) ;;
    *) return 1 ;;
  esac
}

# The verified key sequence that CLEARS a composer holding input the fleet
# cannot prove, for the verify-then-clear gate in front of fm-control.sh's exit
# command (that script's gate_exit_composer owns the sequence and its budget).
# This is a different question from fm_control_interrupt_clear_key above: that
# one names the key an interrupt must be FOLLOWED by so a cancelled prompt is
# never left behind, while this one names what the control plane may deliver to
# CHANGE a composer reading - it is the supported clearing path, so `unknown`
# stops being a structural dead end. Prints one key per line; an empty result
# means no verified clear exists for that harness and the gate falls back to
# bounded re-reads only. A harness with unverified mechanics returns nonzero
# rather than receiving a guessed key.
#   deck  Ctrl+U then Enter, which the pane driver (bin/fm-deck-worker.sh)
#         consumes as ONE input line carrying its clear byte: the driver
#         discards that line whole and repaints its prompt, so the pair can
#         never submit anything even when unproven text was already echoed
#         into the pane, and the repaint is what turns the reading back into a
#         provably empty prompt row.
fm_control_composer_clear_keys() {  # <harness>
  case "${1-}" in
    deck) printf 'C-u\nEnter\n' ;;
    pi|pi-signed) ;;
    *) return 1 ;;
  esac
}

# The command that exits the agent from its own composer.
fm_control_exit_command() {  # <harness>
  case "${1-}" in
    pi|pi-signed|deck) printf '/quit' ;;
    *) return 1 ;;
  esac
}

# Which named keys a backend adapter can deliver. Every session provider
# normalizes Enter, Ctrl+C, and the Ctrl+U composer clear. The stream agent
# writes raw bytes to a pseudoterminal, so it delivers all four.
fm_control_backend_supports_key() {  # <backend> <key>
  local backend=${1-} key=${2-}
  case "$backend" in
    tmux|herdr|stream)
      case "$key" in Escape|Enter|C-c|C-u) return 0 ;; esac
      ;;
  esac
  return 1
}

# Whether <backend> has a recovery-grade agent-state classifier. tmux, herdr,
# and stream implement fm_backend_agent_state; any other backend reports
# `unverified`, so no reading of its can prove an agent stopped. The control
# plane refuses a stop-proving verb there instead of reporting an unprovable
# transition as success.
fm_control_backend_state_verified() {  # <backend>
  case "${1-}" in
    tmux|herdr|stream) return 0 ;;
  esac
  return 1
}

# The per-task wiring artifacts a harness leaves behind, so a relaunch that
# changes harness (or re-arms the same one with a fresh busy generation) can
# clear the previous incarnation's wiring instead of leaving a stale hook
# pointing at a retired generation. Prints zero or more absolute paths, one per
# line: worktree-resident hook files and firstmate-owned state tokens only,
# never a harness's own managed config.
fm_control_harness_wiring_paths() {  # <harness> <worktree> <state-dir> <id>
  local harness=${1-} wt=${2-} state=${3-} id=${4-}
  [ -n "$wt" ] && [ -n "$state" ] && [ -n "$id" ] || return 1
  case "$harness" in
    pi|pi-signed) printf '%s\n' "$state/$id.pi-ext.ts" ;;
  esac
}
