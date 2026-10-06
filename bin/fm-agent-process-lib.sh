#!/usr/bin/env bash
# Backend-neutral harness-process identity.
# Sourced by bin/backends/tmux.sh and bin/backends/herdr.sh. This file is
# sourced by scripts and has no side effects on source.
#
# Why one owner: every runtime backend that proves an agent is alive does it by
# attributing operating-system processes - the pane's foreground process group
# on tmux, Herdr's `pane process-info` view plus the pane shell's descendants
# on Herdr - and the two must agree on what a given process name means, or a
# harness one backend recognizes silently reads as a dead pane on the other.
# The classifier moved here verbatim from the tmux adapter, where it was born;
# docs/tmux-backend.md "Agent liveness probe" owns the empirical basis for the
# names below, and tests/fm-tmux-agent-liveness.test.sh keeps them honest.

# shellcheck source=bin/fm-session-lock-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-session-lock-lib.sh"

# fm_agent_process_classify_name: the single owner of the process-name
# vocabulary shared by every liveness signal - `agent` for a verified harness,
# `shell` for an idle login/interactive shell, `other` for anything else.
# Keeping one classifier means independent name sources (a kernel process
# name, an argv[0], a rendered pane title) can never drift into disagreeing
# about what a given name means.
fm_agent_process_classify_name() {  # <path> [argv0] -> agent|shell|other
  local path=$1 argv0=${2:-} base
  base=${path:-$argv0}
  base=${base##*/}
  base=${base#-}
  case "$base" in
    # A Deck worker's pane foreground is bin/fm-deck-worker.sh, a bash script
    # launched with argv[0] `fm-deck-worker` so it never reads as an idle
    # shell; a `deck chat` primary's is bin/fm-deck-chat.sh (argv[0]
    # `fm-deck-chat`); `deck` itself is the binary they run. All anchored, so
    # unrelated commands containing these words never read as an agent. Any
    # other process - including a harness Firstmate no longer supports - is
    # `other`, which callers fold into `ambiguous` rather than `dead`.
    fm-deck-worker|fm-deck-chat|deck) printf 'agent' ;;
    zsh|bash|sh|dash|ash|ksh|mksh|tcsh|csh|fish) printf 'shell' ;;
    *)
      if fm_harness_path_name "$path" >/dev/null || fm_harness_path_name "$argv0" >/dev/null; then
        printf 'agent'
      else
        printf 'other'
      fi
      ;;
  esac
}

# fm_agent_process_classify: one process, from every identity surface a
# backend can hand over, as agent|shell|other. Any single surface naming a
# verified harness carries `agent`, because a false negative is the one outcome
# that launches a duplicate agent onto a live worktree; `shell` needs every
# readable surface to agree the process is a shell; anything else is `other`.
#
#   <name>   the kernel process name (ps comm, or Herdr's process-info .name):
#            on Linux the exec name, on macOS argv[0] truncated to 16 bytes.
#   <argv0>  argv[0] as the process reports it - a bare name or an install
#            path, whichever the launcher used (empty when unknown).
#   <args>   the flattened command line (accepted for caller compatibility;
#            no remaining harness needs it).
#   [pid]    accepted for caller compatibility, unused.
fm_agent_process_classify() {  # <name> <argv0> <args> [pid] -> agent|shell|other
  local name=${1:-} argv0=${2:-} by_name by_argv0
  by_name=$(fm_agent_process_classify_name "$name" "$argv0")
  [ "$by_name" != agent ] || { printf 'agent'; return 0; }
  if [ -n "$argv0" ]; then
    # argv[0] is classified as a path in its own right, so a bare
    # `fm-deck-worker` or a `-zsh` login name reads by basename and an install
    # path by component.
    by_argv0=$(fm_agent_process_classify_name "$argv0" "$argv0")
    [ "$by_argv0" != agent ] || { printf 'agent'; return 0; }
  else
    by_argv0=$by_name
  fi
  if [ "$by_name" = shell ] && [ "$by_argv0" = shell ]; then
    printf 'shell'
  else
    printf 'other'
  fi
}

# fm_agent_process_topmost: filter a pid list (stdin, one per line) down to the
# pids whose parent is not also in it, so a harness that spawned helpers whose
# names or install paths also read as a harness is reported once, as the
# process its launch created. A pid whose parent cannot be read is kept.
fm_agent_process_topmost() {  # pids on stdin -> pids on stdout
  local pids pid ppid
  pids=" $(tr '\n' ' ') "
  for pid in $pids; do
    ppid=$(LC_ALL=C ps -p "$pid" -o ppid= 2>/dev/null | tr -d '[:space:]')
    case "$pids" in
      *" ${ppid:-none} "*) ;;
      *) printf '%s\n' "$pid" ;;
    esac
  done
}

# fm_agent_process_has_args: whether live <pid>'s command line carries <arg>...
# as consecutive arguments after argv[0]. Returns 0 when it does, 1 when the
# line was read and does not, and 2 when the process cannot be read. A
# Linux-compatible /proc keeps argv boundaries, so one long argument - a launch
# brief quoting a flag - can never satisfy the match; elsewhere ps's flattened
# line is split on whitespace, which keeps every flag whole but cannot
# reassemble an argument that itself holds a space, such as a path under a
# spaced home. A backend that reads the boundaries itself matches those
# arguments from its own report instead (bin/backends/herdr.sh's
# fm_backend_herdr_deck_pid_is_driver).
fm_agent_process_has_args() {  # <pid> <arg>...
  local pid=$1 proc_root flat
  shift
  case "$pid" in ''|*[!0-9]*) return 2 ;; esac
  [ "$#" -gt 0 ] || return 2
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/cmdline" ]; then
    perl -e '
      my $path = shift;
      open(my $fh, "<", $path) or exit 2;
      local $/; my $raw = <$fh>; close $fh;
      exit 2 unless defined $raw && length $raw;
      $raw =~ s/\0\z//;
      my @argv = split /\0/, $raw, -1;
      for my $i (1 .. $#argv - $#ARGV) {
        my $hit = 1;
        for my $j (0 .. $#ARGV) { if ($argv[$i + $j] ne $ARGV[$j]) { $hit = 0; last } }
        exit 0 if $hit;
      }
      exit 1;
    ' "$proc_root/$pid/cmdline" "$@"
    return $?
  fi
  flat=$(COLUMNS=100000 LC_ALL=C ps -ww -p "$pid" -o args= 2>/dev/null) || return 2
  [ -n "$flat" ] || return 2
  perl -e '
    my @argv = split " ", shift;
    for my $i (1 .. $#argv - $#ARGV) {
      my $hit = 1;
      for my $j (0 .. $#ARGV) { if ($argv[$i + $j] ne $ARGV[$j]) { $hit = 0; last } }
      exit 0 if $hit;
    }
    exit 1;
  ' "$flat" "$@"
}
