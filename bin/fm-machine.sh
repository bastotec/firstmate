#!/usr/bin/env bash
# Connect a new machine for remote second mates in scripted, reviewable steps.
#
# Usage:
#   fm-machine.sh check <alias> [<remote-root>] [--address <host-or-ip> --user <user>]
#   fm-machine.sh setup <alias> <remote-root>
#   fm-machine.sh add <alias> <address> <user>
#   fm-machine.sh trust <alias> <SHA256:fingerprint>
#   fm-machine.sh prepare <alias> <remote-root>
#   fm-machine.sh register <alias> <remote-root>
#   fm-machine.sh skills <alias> [<remote-root>]
#
# This is the deterministic entry point for an order that connects a machine
# (for example one sent from a UI and confirmed by the captain). It never
# handles private keys or prints secrets, never accepts a host key it was not
# given, and never invokes a system package manager, sudo or a login.
# docs/remote-secondmates.md owns what a ready host needs,
# bin/fm-remote-doctor.sh owns the readiness verdict, bin/fm-home-tools-lib.sh
# owns the CLI toolchain a home needs, and bin/fm-machine-remote.sh is the half
# that runs on the machine.
#
# check <alias> is read-only. An alias is configured when a Host line names it
# literally or ssh -G resolves it to a different hostname. It reports that
# configuration and whether the host key is known (ssh-keygen -F),
# and when it is not, the scanned key fingerprints (ssh-keyscan piped to
# ssh-keygen -lf -, never written anywhere). It then tries
#   ssh -o UpdateHostKeys=no -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 <alias> true
# and, when that connects, probes the machine read-only (bin/fm-machine-remote.sh
# probe) and, when a Firstmate clone is at <remote-root>, runs the doctor
# read-only through fm-on.sh using prepare's scratch route (described below).
# Home-specific checks therefore normally report skip; machine setup does not
# establish an actual home's authenticated stream readiness.
# <remote-root> defaults to the one data/machines.md records for the alias.
# With --address and --user, an alias no ssh config block resolves yet is
# probed as if `add` had written it, with
# -o HostName= and -o User= on every connection; nothing is written, and
# `check alias=missing` still names the `add` that closes it. It then prints the checklist: one
# `item` line per thing a home on that machine needs, each present,
# will-install (setup does it) or human (with the exact step). Items: the ssh
# alias, host key and login; the Firstmate clone and entrypoint link; every
# doctor check (the remote job worker, stream tools, stream token and hub for a
# home, logout survival, GUI session); every tool in the stream backend's and
# bin/fm-home-tools-lib.sh's lists; Deck; gh auth (exit status only); the model
# gateway at FM_MACHINE_GATEWAY_URL (default Deck's http://127.0.0.1:8329/v1)
# and its client key file (presence and mode only, never read); whether
# this home's config/stream-hub answers from the machine; and whether the
# approval gate (bin/fm-approval.py) is in the machine's deck.hooks.json, with
# the gates its policy enables (no item for a clone that predates it).
# After a successful probe it also offers optional machine instructions (described below).
# Exit 0 only when every check and item is ok or present; gaps exit 1.
# An absent clone is will-install only when prepare's clone-route guard passes;
# otherwise the clone item is human with the same refusal reason.
# With no known remote root, the clone and entrypoint-link items request it;
# the probe does not judge the entrypoint link.
# Required-tool doctor gaps are human items; read-only fixable checks are
# will-install, while fixable checks remaining after setup's --fix are human
# items and fail setup.
#
# setup <alias> <remote-root> performs only the automatable items, in order,
# printing one `step` line as each completes and stopping at the first failure:
# ssh login, the Firstmate clone and entrypoint link (as prepare), each missing
# tool whose bin/fm-home-tools-lib.sh install command is user-level (an
# installer script, or npm install -g when npm's global prefix is writable),
# Deck (FM_DECK_REPO_URL defaults to https://github.com/bastotec/deck.git;
# bin/fm-machine-remote.sh owns the build and atomic install mechanics,
# attempted when git and cargo are there), mode 600 on an owner-readable
# gateway key with group or other permission bits set, then the doctor's --fix
# through the same scratch route, then the approval gate hook (installed with no
# gates enabled; the machine's own policy file turns gates on), then the
# shared-skills and inventory steps described below.
# It then prints a `human` line for each remaining human item and the verdict.
# A doctor that did not run, a transport failure, or a fixable gap left after
# --fix fails the doctor step; human gaps alone do not. Rerunning skips
# already-present tool and clone installs, but repeats the shared-skills
# installer and inventory refresh. URL userinfo is redacted from all output;
# command diagnostics are merged into stdout through the same output filter.
# SSH login, clone/link, probe and install calls must exit successfully before
# their facts can advance setup; the doctor's reported gaps are handled above.
# A failed probe makes all probe-dependent checklist items human steps.
#
# add <alias> <address> <user> appends a marked Host block (HostName, User,
# StrictHostKeyChecking yes, ConnectTimeout 8, ForwardAgent no) to the ssh
# config, and refuses when an existing block already sets a HostName for the
# alias or names it on a Host line. Before writing, it evaluates the candidate
# config with ssh -G and refuses ineffective HostName or User settings.
#
# trust <alias> <SHA256:fingerprint> scans the host key again and appends the
# scanned key whose fingerprint exactly equals the given one to known_hosts. It
# refuses when nothing matches, and refuses when the host already has a
# different known key (remove that yourself with ssh-keygen -R after checking
# why it changed). Verify the fingerprint out of band before trusting it.
#
# prepare <alias> <remote-root> clones Firstmate at <remote-root> on the host
# when no checkout is there, from this checkout's own delivery route (the same
# rule bin/fm-home-route-lib.sh applies to seeding; a local path or file:// URL
# is refused), links ~/.local/bin/fm-remote-entrypoint.sh to it when nothing is
# there, and then runs `bin/fm-on.sh <alias> fm-remote-doctor.sh --backend
# stream --fix` and relays its verdict and exit status. fm-on.sh only routes to
# recorded remote homes, so a machine with no second mate yet is reached through
# a scratch single-route registry naming <remote-root> and an absent probe home
# under the remote account's home directory; the doctor reports home-specific
# checks as skip for an absent home and creates nothing there. Tool installation
# remains manual with prepare; use setup for supported automatic installs.
#
# Shared skills: setup (after the doctor) and `skills` record the connected
# machine's inventory with bin/fm-machine-skills.sh refresh. When this home has
# config/shared-skills, they first update the machine's copy of the captain's
# skills repo and run its installer. The file holds key=value lines:
#   source=<absolute path of this machine's clone of the skills repo>   (required)
#   ref=<ref to ship, default origin/main; setup/skills fetch origin/* first>
#   dir=<clone path relative to the remote account's home, default dotfiles>
#   install=<command run in that clone, default ./install.sh --skills-only>
# The machine needs no credentials for the repo: this machine pushes the
# commit over ssh into <dir>'s refs/remotes/origin/<branch> and the machine
# fast-forwards its <branch> to it (a fresh <dir> is created with this clone's
# origin URL, any user, token or password in it removed). It refuses a <dir>
# that is not a git clone, has local changes,
# is on another branch or cannot safely fast-forward or check out the commit,
# including a collision with an ignored host-local file. A clean, empty unborn
# repo with no refs may adopt the requested branch to recover an interrupted
# first push; committed work retains the branch guard. Which skills link is the
# installer's business (dotfiles keeps machine-only skills to their host).
# Without the file, shared provisioning prints `step shared-skills=skipped`,
# but inventory refresh still runs. On a successful probe with the file present,
# check prints `item shared-skills=present|will-install|human` and
# `item skill-inventory`; it resolves the locally cached ref without fetching
# or running the installer. A present inventory item means a recorded file,
# not a live skill check. Installer output goes to ~/.cache/fm-shared-skills.log
# on the connected machine.
# skills <alias> [<remote-root>] runs only provisioning and inventory refresh;
# <remote-root> defaults to fm-machine-skills.sh roots (the machine registry,
# then a remote secondmate route on that host), and is required if unrecorded.
#
# Machine instructions: check reports an informational
# `item machine-instructions=present` after a successful probe; `present` means
# the offer is available, not that an instructions file exists. Setup emits
# `step machine-instructions=skipped` after the skills steps. Both offers report
# the file's presence when readable; neither writes it or makes it required.
# bin/fm-machine-instructions.sh owns the separate read/save interface and its
# registration prerequisite.
#
# register <alias> <remote-root> records the machine in this home's
# data/machines.md as `- <alias> (root: <remote-root>; added YYYY-MM-DD)`. It is
# idempotent for the same root and refuses a different root for a recorded
# alias.
#
# FM_SSH_CONFIG selects the ssh config with -F. FM_KNOWN_HOSTS selects the
# trust file; otherwise the first userknownhostsfile from ssh -G is used, with
# a leading ~ expanded. Lookup, trust writes and every connection (including
# the doctor through fm-on.sh) use that file via -o UserKnownHostsFile=.
# Every connection disables UpdateHostKeys. Tests use scratch selections.
#
# Line protocol on stdout, one fact per line, stable for script consumers:
# The checklist replaces the former check entrypoint/deck/proxai lines; a local
# proxai executable is not required when the configured gateway answers.
#   action=check|setup|add|trust|prepare|register|skills
#   alias=<alias>
#   root=<remote-root>|-                         (check, setup, skills)
#   hostname=<name> user=<user> port=<port>     (check)
#   hostkey-fingerprint=<SHA256:...> type=<TYPE> (check, when the key is unknown)
#   reach=ok|auth|hostkey|timeout|refused|unresolved|error   (check)
#   tool <name>=<path>|missing                   (check, after a successful probe)
#   check <name>=ok|missing|unknown: <evidence>  (check: alias, hostkey, reach)
#   action: <exact step for the captain>         (after each gap)
#   item <name>=present|will-install|human: <evidence, what setup does, or the exact step>
#                                                (check; names: ssh-alias, ssh-hostkey, ssh-login,
#                                                machine, firstmate-clone, entrypoint-link, doctor,
#                                                doctor-<check>, doctor-required-<tool>, tool-<tool>, deck, gh-auth,
#                                                model-gateway, gateway-key, stream-hub, approval-gate,
#                                                shared-skills, skill-inventory, machine-instructions)
#   step <name>=done|skipped|failed: <evidence or plain reason>   (setup; skills emits
#                                                shared-skills and skill-inventory; setup names: ssh,
#                                                firstmate-clone, entrypoint-link, probe, tool-<tool>,
#                                                deck, gateway-key-mode, doctor, approval-gate,
#                                                shared-skills, skill-inventory, machine-instructions)
#   human <item-name>: <exact step for a person> (setup, after the steps)
#   setup=complete|incomplete: <n> human steps|failed   (setup; exit 0, 3, 1)
#   added=<ssh-config-path>                      (add)
#   trusted=<SHA256:...> file=<known-hosts-path> (trust)
#   trust=already-known                          (trust, idempotent)
#   clone=present|created root=<remote-root>     (prepare)
#   entrypoint-link=present|created|conflict: <target>   (prepare)
#   doctor: <each doctor line>                   (prepare)
#   registered=<alias> root=<remote-root>        (register)
#   register=already-recorded                    (register, idempotent)
#   refuse: <plain reason>                       (any refusal; exit 1)
# Usage errors exit 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
SSH_CONFIG="${FM_SSH_CONFIG:-$HOME/.ssh/config}"
KNOWN_HOSTS="${FM_KNOWN_HOSTS:-}"
TMP=
trap '[ -z "$TMP" ] || rm -rf -- "$TMP"' EXIT

# shellcheck source=bin/fm-home-route-lib.sh
. "$SCRIPT_DIR/fm-home-route-lib.sh"
# shellcheck source=bin/fm-home-tools-lib.sh
. "$SCRIPT_DIR/fm-home-tools-lib.sh"
# shellcheck source=bin/fm-machine-output-lib.sh
. "$SCRIPT_DIR/fm-machine-output-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

CHECK_ADDRESS=
CHECK_USER=
SKILLS_ITEMS=
GATEWAY_URL=${FM_MACHINE_GATEWAY_URL:-http://127.0.0.1:8329/v1}
DECK_REPO_URL=${FM_DECK_REPO_URL:-https://github.com/bastotec/deck.git}

usage() { sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
refuse() { printf 'refuse: %s\n' "$1"; exit 1; }

SSH_OPTS=(-o UpdateHostKeys=no)
[ -z "${FM_SSH_CONFIG:-}" ] || SSH_OPTS+=(-F "$FM_SSH_CONFIG")
[ -z "${FM_KNOWN_HOSTS:-}" ] || SSH_OPTS+=(-o "UserKnownHostsFile=$FM_KNOWN_HOSTS")
PROBE_OPTS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 -o ForwardAgent=no -o ClearAllForwardings=yes)

valid_alias() { case "$1" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac; }
valid_root() {
  case "$1" in /*) ;; *) return 1 ;; esac
  case "$1" in *[!A-Za-z0-9._/-]*) return 1 ;; esac
  case "/$1/" in */../*|*/./*) return 1 ;; esac
  case "$1" in *'//'*) return 1 ;; esac
  [ "$1" != / ]
}

# Resolve the alias through ssh -G into SSH_HOSTNAME, SSH_USER, SSH_PORT and
# KNOWN_NAME, the name its host key is stored under.
resolve_alias() { # <alias>
  local out alias_lc hostkeyalias trust_file
  out=$(ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" -G "$1" < /dev/null 2>/dev/null) || return 1
  SSH_HOSTNAME=$(printf '%s\n' "$out" | awk '$1 == "hostname" { print $2; exit }')
  SSH_USER=$(printf '%s\n' "$out" | awk '$1 == "user" { print $2; exit }')
  SSH_PORT=$(printf '%s\n' "$out" | awk '$1 == "port" { print $2; exit }')
  hostkeyalias=$(printf '%s\n' "$out" | awk '$1 == "hostkeyalias" { print $2; exit }')
  [ -n "$SSH_PORT" ] || SSH_PORT=22
  KNOWN_NAME=${hostkeyalias:-$SSH_HOSTNAME}
  [ "$SSH_PORT" = 22 ] || [ -n "$hostkeyalias" ] || KNOWN_NAME="[$SSH_HOSTNAME]:$SSH_PORT"
  alias_lc=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  ALIAS_CONFIGURED=0
  [ -z "$SSH_HOSTNAME" ] || [ "$(printf '%s' "$SSH_HOSTNAME" | tr '[:upper:]' '[:lower:]')" = "$alias_lc" ] || ALIAS_CONFIGURED=1
  if config_names_alias "$1"; then ALIAS_CONFIGURED=1; fi
  if [ -z "${FM_KNOWN_HOSTS:-}" ]; then
    trust_file=$(printf '%s\n' "$out" | awk '$1 == "userknownhostsfile" { print $2; exit }')
    [ -n "$trust_file" ] || return 1
    case "$trust_file" in
      \~/*) trust_file="$HOME/${trust_file#\~/}" ;;
      \~) trust_file=$HOME ;;
    esac
    KNOWN_HOSTS=$trust_file
    SSH_OPTS+=(-o "UserKnownHostsFile=$KNOWN_HOSTS")
  fi
}

# 0 when a Host line in the ssh config names the alias literally.
config_names_alias() { # <alias>
  [ -f "$SSH_CONFIG" ] || return 1
  awk -v a="$1" '
    tolower($1) == "host" { for (i = 2; i <= NF; i++) if (tolower($i) == tolower(a)) found = 1 }
    END { exit found ? 0 : 1 }
  ' "$SSH_CONFIG"
}

known_fingerprints() { # prints "<SHA256:...>" per known key for KNOWN_NAME
  [ -f "$KNOWN_HOSTS" ] || return 0
  ssh-keygen -F "$KNOWN_NAME" -f "$KNOWN_HOSTS" 2>/dev/null \
    | grep -v '^#' | grep -v '^[[:space:]]*$' \
    | while IFS= read -r line; do
        printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{ print $2 }'
      done
}

scan_keys() { # prints raw ssh-keyscan lines for the resolved host
  ssh-keyscan -T 8 -p "$SSH_PORT" "$SSH_HOSTNAME" 2>/dev/null | grep -v '^#' | grep -v '^[[:space:]]*$' || true
}

classify_reach() { # <stderr text> -> class
  case "$1" in
    *'Permission denied'*|*'Too many authentication failures'*|*'No more authentication methods'*) printf auth ;;
    *'Host key verification failed'*|*'REMOTE HOST IDENTIFICATION HAS CHANGED'*|*'No '*' host key is known'*|*'host key for'*'has changed'*) printf hostkey ;;
    *'timed out'*) printf timeout ;;
    *'Connection refused'*) printf refused ;;
    *'Could not resolve hostname'*|*'Name or service not known'*|*'nodename nor servname'*) printf unresolved ;;
    *) printf error ;;
  esac
}

cmd_check() { # <alias> [<remote-root>] [--address <host> --user <user>]
  local alias=$1 root='' address='' user='' gaps=0 known scanned err rc class first configured
  shift
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --address) [ "$#" -ge 2 ] || usage; address=$2; shift 2 ;;
      --user) [ "$#" -ge 2 ] || usage; user=$2; shift 2 ;;
      -*) usage ;;
      *) [ -z "$root" ] || usage; root=$1; shift ;;
    esac
  done
  if [ -n "$address$user" ]; then
    [ -n "$address" ] && [ -n "$user" ] || refuse "--address and --user go together"
    case "$address" in -*|*[!A-Za-z0-9.:_-]*) refuse "address must be a host name or IP address: $address" ;; esac
    case "$user" in -*|*[!A-Za-z0-9._-]*) refuse "user must be a plain account name: $user" ;; esac
  fi
  valid_alias "$alias" || refuse "alias must be a plain ssh config name of A-Z, a-z, 0-9, ., _ and -, not starting with -: $alias"
  if [ -z "$root" ] && [ -f "$DATA/machines.md" ]; then
    root=$(awk -v a="$alias" '$1 == "-" && $2 == a { r = $0; sub(/^.*\(root: /, "", r); sub(/;.*$/, "", r); print r; exit }' "$DATA/machines.md")
  fi
  [ -n "$root" ] || root=-
  [ "$root" = - ] || valid_root "$root" || refuse "remote root must be an absolute path of A-Z, a-z, 0-9, ., _, - and /: $root"
  printf 'action=check\nalias=%s\nroot=%s\n' "$alias" "$root"
  resolve_alias "$alias" || refuse "ssh -G could not evaluate the alias $alias"
  configured=$ALIAS_CONFIGURED
  if [ "$configured" -eq 0 ] && [ -n "$address" ]; then
    SSH_OPTS+=(-o "HostName=$address" -o "User=$user")
    resolve_alias "$alias" || refuse "ssh -G could not evaluate $alias at $address"
  fi
  ALIAS_CONFIGURED=$configured
  CHECK_ADDRESS=$address
  CHECK_USER=$user
  printf 'hostname=%s user=%s port=%s\n' "$SSH_HOSTNAME" "$SSH_USER" "$SSH_PORT"
  if [ "$ALIAS_CONFIGURED" -eq 1 ]; then
    printf 'check alias=ok: %s resolves to %s as %s on port %s\n' "$alias" "$SSH_HOSTNAME" "$SSH_USER" "$SSH_PORT"
  else
    gaps=1
    printf 'check alias=missing: no ssh config block names or resolves %s\n' "$alias"
    printf 'action: bin/fm-machine.sh add %s %s %s\n' "$alias" "${address:-<address>}" "${user:-<user>}"
  fi

  known=$(known_fingerprints)
  if [ -n "$known" ]; then
    printf 'check hostkey=ok: %s is known as %s\n' "$KNOWN_NAME" "$(printf '%s' "$known" | tr '\n' ' ' | sed 's/ $//')"
  else
    gaps=1
    scanned=$(scan_keys | while IFS= read -r line; do printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null; done)
    if [ -n "$scanned" ]; then
      printf '%s\n' "$scanned" | awk '{ t = $NF; gsub(/[()]/, "", t); print "hostkey-fingerprint=" $2 " type=" t }'
      first=$(printf '%s\n' "$scanned" | awk '/ED25519/ { print $2; exit }')
      [ -n "$first" ] || first=$(printf '%s\n' "$scanned" | awk '{ print $2; exit }')
      printf 'check hostkey=missing: %s is not in %s\n' "$KNOWN_NAME" "$KNOWN_HOSTS"
      printf 'action: compare the fingerprint with the one the machine itself shows (ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub on it), then bin/fm-machine.sh trust %s %s\n' "$alias" "$first"
    else
      printf 'check hostkey=unknown: %s is not in %s and no key could be scanned from %s port %s\n' "$KNOWN_NAME" "$KNOWN_HOSTS" "$SSH_HOSTNAME" "$SSH_PORT"
      printf 'action: make sure the machine is on and its ssh server is running, then rerun bin/fm-machine.sh check %s\n' "$alias"
    fi
  fi

  set +e
  err=$(ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "${PROBE_OPTS[@]}" "$alias" true < /dev/null 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then class=ok; else class=$(classify_reach "$err"); fi
  err=$(printf '%s' "$err" | grep -v '^[[:space:]]*$' | tail -n 1)
  printf 'reach=%s\n' "$class"
  case "$class" in
    ok) printf 'check reach=ok: key login as %s works without a prompt\n' "$SSH_USER" ;;
    auth)
      gaps=1
      printf 'check reach=missing: the machine refused key login (%s)\n' "$err"
      printf 'action: ssh-copy-id %s (or add the 1Password SSH agent public key to ~%s/.ssh/authorized_keys on the machine), then rerun bin/fm-machine.sh check %s\n' "$alias" "$SSH_USER" "$alias"
      ;;
    hostkey)
      gaps=1
      printf 'check reach=missing: the host key is not trusted (%s)\n' "$err"
      printf 'action: verify the fingerprint above, then bin/fm-machine.sh trust %s <SHA256:fingerprint>\n' "$alias"
      ;;
    timeout|refused|unresolved)
      gaps=1
      printf 'check reach=missing: %s (%s)\n' "$class" "$err"
      printf 'action: make sure %s is on, reachable from this machine, and running an ssh server on port %s, then rerun bin/fm-machine.sh check %s\n' "$SSH_HOSTNAME" "$SSH_PORT" "$alias"
      ;;
    *)
      gaps=1
      printf 'check reach=unknown: ssh exited %s (%s)\n' "$rc" "$err"
      printf 'action: run ssh %s true yourself to see the full error\n' "$alias"
      ;;
  esac

  DOCTOR_OUT=
  DOCTOR_ATTEMPTED=0
  DOCTOR_FIXED=0
  PROBE_OUT=
  PROBE_RC=0
  if [ "$class" = ok ]; then
    probe_machine "$alias" "$root"
    if [ "$root" != - ] && [ "$(fact clone)" = present ] && [ -n "$ACCOUNT_HOME" ]; then
      run_doctor "$alias" "$root" "$ACCOUNT_HOME"
    fi
    printf '%s\n' "$PROBE_OUT" | grep '^tool ' || true
    if [ "$PROBE_RC" -eq 0 ]; then
      skills_items "$alias"
      instructions_offer "$alias"
      SKILLS_ITEMS="${SKILLS_ITEMS}item machine-instructions=present: $INSTR_TEXT"$'\n'
    fi
  fi
  build_items "$alias" "$root" "$class" "$known"
  printf '%s' "$ITEMS"
  [ "$(items_not_present)" -eq 0 ] || gaps=1
  return "$gaps"
}

cmd_add() { # <alias> <address> <user>
  local alias=$1 address=$2 user=$3 today candidate effective effective_host effective_user block
  valid_alias "$alias" || refuse "alias must be a plain ssh config name of A-Z, a-z, 0-9, ., _ and -, not starting with -: $alias"
  case "$address" in ''|-*|*[!A-Za-z0-9.:_-]*) refuse "address must be a host name or IP address: $address" ;; esac
  case "$user" in ''|-*|*[!A-Za-z0-9._-]*) refuse "user must be a plain account name: $user" ;; esac
  printf 'action=add\nalias=%s\n' "$alias"
  if config_names_alias "$alias"; then
    refuse "$SSH_CONFIG already has a Host block naming $alias"
  fi
  if resolve_alias "$alias" && [ "$ALIAS_CONFIGURED" -eq 1 ]; then
    refuse "$alias already resolves to $SSH_HOSTNAME through the ssh config"
  fi
  if [ -e "$SSH_CONFIG" ] || [ -L "$SSH_CONFIG" ]; then
    [ -f "$SSH_CONFIG" ] && [ ! -L "$SSH_CONFIG" ] || refuse "$SSH_CONFIG is not a regular file"
  fi
  candidate=$(mktemp "${TMPDIR:-/tmp}/fm-machine-config.XXXXXX")
  TMP=$candidate
  [ ! -f "$SSH_CONFIG" ] || cat "$SSH_CONFIG" > "$candidate"
  today=$(date +%F)
  block=$(
    printf '# >>> firstmate machine %s (added %s)\n' "$alias" "$today"
    printf 'Host %s\n' "$alias"
    printf '  HostName %s\n' "$address"
    printf '  User %s\n' "$user"
    printf '  StrictHostKeyChecking yes\n'
    printf '  ConnectTimeout 8\n'
    printf '  ForwardAgent no\n'
    printf '# <<< firstmate machine %s\n' "$alias"
  )
  printf '\n%s\n' "$block" >> "$candidate"
  effective=$(ssh -o UpdateHostKeys=no -F "$candidate" -G "$alias" < /dev/null 2>/dev/null) \
    || refuse "ssh -G could not evaluate the candidate config for $alias"
  effective_host=$(printf '%s\n' "$effective" | awk '$1 == "hostname" { print tolower($2); exit }')
  effective_user=$(printf '%s\n' "$effective" | awk '$1 == "user" { print $2; exit }')
  [ "$effective_host" = "$(printf '%s' "$address" | tr '[:upper:]' '[:lower:]')" ] && [ "$effective_user" = "$user" ] \
    || refuse "earlier ssh config settings override the requested hostname or user for $alias"
  mkdir -p "$(dirname "$SSH_CONFIG")"
  chmod 700 "$(dirname "$SSH_CONFIG")" 2>/dev/null || true
  if [ ! -e "$SSH_CONFIG" ]; then (umask 077; : > "$SSH_CONFIG"); fi
  printf '\n%s\n' "$block" >> "$SSH_CONFIG"
  rm -f -- "$candidate"
  TMP=
  printf 'added=%s\n' "$SSH_CONFIG"
}

cmd_trust() { # <alias> <SHA256:fingerprint>
  local alias=$1 wanted=$2 known line fp match=
  valid_alias "$alias" || refuse "alias must be a plain ssh config name of A-Z, a-z, 0-9, ., _ and -, not starting with -: $alias"
  case "$wanted" in SHA256:?*) ;; *) refuse "fingerprint must look like SHA256:<base64>: $wanted" ;; esac
  case "${wanted#SHA256:}" in *[!A-Za-z0-9+/=]*) refuse "fingerprint must look like SHA256:<base64>: $wanted" ;; esac
  printf 'action=trust\nalias=%s\n' "$alias"
  resolve_alias "$alias" || refuse "ssh -G could not evaluate the alias $alias"
  known=$(known_fingerprints)
  if [ -n "$known" ]; then
    if printf '%s\n' "$known" | grep -qxF -- "$wanted"; then
      printf 'trust=already-known\n'
      return 0
    fi
    refuse "$KNOWN_NAME already has a different known host key in $KNOWN_HOSTS; check why it changed and remove it yourself with ssh-keygen -R '$KNOWN_NAME' before trusting a new one"
  fi
  while IFS= read -r line; do
    fp=$(printf '%s\n' "$line" | ssh-keygen -lf - 2>/dev/null | awk '{ print $2 }')
    if [ "$fp" = "$wanted" ]; then match=$line; break; fi
  done < <(scan_keys)
  [ -n "$match" ] || refuse "no key scanned from $SSH_HOSTNAME port $SSH_PORT has fingerprint $wanted"
  # Store the key under the name ssh looks it up by.
  match="$KNOWN_NAME ${match#* }"
  mkdir -p "$(dirname "$KNOWN_HOSTS")"
  if [ -s "$KNOWN_HOSTS" ] && [ "$(tail -c 1 "$KNOWN_HOSTS" | od -An -c | tr -d ' ')" != '\n' ]; then
    printf '\n' >> "$KNOWN_HOSTS"
  fi
  printf '%s\n' "$match" >> "$KNOWN_HOSTS"
  printf 'trusted=%s file=%s\n' "$wanted" "$KNOWN_HOSTS"
}

# Resolve this checkout's clone URL into CLONE_URL, or set CLONE_REASON and return 1.
resolve_clone_url() {
  CLONE_URL=$(fm_home_route_url "$FM_ROOT")
  CLONE_REASON=
  if [ -z "$CLONE_URL" ]; then
    CLONE_REASON="this Firstmate checkout has no origin to clone from"
  elif ! fm_home_route_is_remote "$CLONE_URL"; then
    CLONE_REASON="this Firstmate checkout's origin is $CLONE_URL, a local path the machine cannot clone from; point origin at the fork's network URL first"
  elif ! fm_project_url_plain "$CLONE_URL"; then
    CLONE_REASON="this Firstmate checkout's origin contains characters this command will not pass to a remote shell: $CLONE_URL"
  fi
  [ -z "$CLONE_REASON" ]
}

# Clone Firstmate at <root> when absent and link the entrypoint. Sets
# CLONE_OUT (the remote's fact lines) and CLONE_RC.
remote_clone_and_link() { # <alias> <root> <url>
  set +e
  CLONE_OUT=$(ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "${PROBE_OPTS[@]}" "$1" sh -s -- "$2" "$3" <<'SH'
root=$1
url=$2
printf 'account-home=%s\n' "$HOME"
if [ -f "$root/AGENTS.md" ] && [ -f "$root/bin/fm-remote-entrypoint.sh" ]; then
  printf 'clone=present\n'
elif [ -e "$root" ] && [ -n "$(ls -A "$root" 2>/dev/null)" ]; then
  printf 'refuse: %s exists and is not a Firstmate checkout\n' "$root"
  exit 3
else
  command -v git >/dev/null 2>&1 || { printf 'refuse: git is not on the non-interactive PATH of the machine\n'; exit 3; }
  git clone --quiet -- "$url" "$root" < /dev/null >&2 || { printf 'refuse: git clone of %s into %s failed\n' "$url" "$root"; exit 3; }
  printf 'clone=created\n'
fi
link="$HOME/.local/bin/fm-remote-entrypoint.sh"
target="$root/bin/fm-remote-entrypoint.sh"
if [ -L "$link" ] && [ "$(readlink "$link")" = "$target" ]; then
  printf 'entrypoint-link=present: %s\n' "$target"
elif [ -e "$link" ] || [ -L "$link" ]; then
  printf 'entrypoint-link=conflict: %s\n' "$(readlink "$link" 2>/dev/null || printf 'not a symlink')"
else
  mkdir -p "$HOME/.local/bin" && ln -s "$target" "$link" && printf 'entrypoint-link=created: %s\n' "$target"
fi
SH
)
  CLONE_RC=$?
  set -e
}

# Run the remote doctor through fm-on.sh. fm-on.sh routes only to recorded
# homes, so reach this machine through a scratch registry with one route and
# an absent probe home. Sets DOCTOR_OUT and DOCTOR_RC.
run_doctor() { # <alias> <root> <account-home> [--fix]
  local alias=$1 root=$2 account_home=$3 scratch
  shift 3
  DOCTOR_ATTEMPTED=1
  DOCTOR_FIXED=0
  [ "${1:-}" != --fix ] || DOCTOR_FIXED=1
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-machine.XXXXXX")
  TMP=$scratch
  {
    printf '#!/usr/bin/env bash\nexec ssh'
    printf ' %q' "${SSH_OPTS[@]}" "${PROBE_OPTS[@]}"
    printf ' "$@"\n'
  } > "$scratch/ssh"
  chmod 700 "$scratch/ssh"
  printf -- '- fm-machine-probe - machine readiness probe (host: %s; root: %s; home: %s/.firstmate-machine-probe; scope: readiness probe; projects: ; added %s)\n' \
    "$alias" "$root" "$account_home" "$(date +%F)" > "$scratch/secondmates.md"
  set +e
  DOCTOR_OUT=$(FM_DATA_OVERRIDE="$scratch" FM_SSH_BIN="$scratch/ssh" "$SCRIPT_DIR/fm-on.sh" fm-machine-probe fm-remote-doctor.sh --backend stream "$@" < /dev/null 2>&1)
  DOCTOR_RC=$?
  set -e
  rm -rf -- "$scratch"
  TMP=
}

cmd_prepare() { # <alias> <remote-root>
  local alias=$1 root=$2 account_home line
  valid_alias "$alias" || refuse "alias must be a plain ssh config name of A-Z, a-z, 0-9, ., _ and -, not starting with -: $alias"
  valid_root "$root" || refuse "remote root must be an absolute path of A-Z, a-z, 0-9, ., _, - and /: $root"
  printf 'action=prepare\nalias=%s\n' "$alias"
  resolve_clone_url || refuse "$CLONE_REASON"
  resolve_alias "$alias" || refuse "ssh -G could not evaluate the alias $alias"
  remote_clone_and_link "$alias" "$root" "$CLONE_URL"
  account_home=
  while IFS= read -r line; do
    case "$line" in
      account-home=*) account_home=${line#account-home=} ;;
      clone=*) printf '%s root=%s\n' "$line" "$root" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<EOF
$CLONE_OUT
EOF
  [ "$CLONE_RC" -ne 255 ] || refuse "ssh to $alias failed; run bin/fm-machine.sh check $alias"
  [ "$CLONE_RC" -eq 0 ] || exit 1
  case "$CLONE_OUT" in *'entrypoint-link=conflict'*) refuse "the ~/.local/bin/fm-remote-entrypoint.sh link on $alias is not Firstmate's link to $root; inspect it on the machine" ;; esac
  case "$account_home" in /?*) ;; *) refuse "could not read the remote account's home directory" ;; esac
  run_doctor "$alias" "$root" "$account_home" --fix
  printf '%s\n' "$DOCTOR_OUT" | sed 's/^/doctor: /'
  return "$DOCTOR_RC"
}

sq() { printf "'%s'" "${1//\'/\'\\\'\'}"; }

# The tools a home on the machine needs, in bin/fm-bootstrap.sh's order: the
# stream backend's tools, then the common toolchain.
machine_tools() {
  local seen=' ' tool
  for tool in $(fm_backend_required_tools stream) $(fm_home_common_tools); do
    case "$seen" in *" $tool "*) continue ;; esac
    seen="$seen$tool "
    printf '%s\n' "$tool"
  done
}

hub_url() {
  local hub=
  [ ! -f "$FM_HOME/config/stream-hub" ] || hub=$(head -n 1 "$FM_HOME/config/stream-hub" | tr -d '[:space:]')
  if [ -n "$hub" ] && fm_project_url_plain "$hub"; then printf '%s\n' "$hub"; else printf -- '-\n'; fi
}

# Run bin/fm-machine-remote.sh on the machine as `bash -s`, with the tools
# and output libraries in front of it. Sets REMOTE_OUT and REMOTE_RC (ssh's status).
remote_machine() { # <alias> <args...>
  local alias=$1 cmd='bash -s --' arg
  shift
  for arg in "$@"; do cmd="$cmd $(sq "$arg")"; done
  set +e
  REMOTE_OUT=$(
    # shellcheck disable=SC2029 # quoted for the remote shell on purpose.
    cat "$SCRIPT_DIR/fm-home-tools-lib.sh" "$SCRIPT_DIR/fm-machine-output-lib.sh" "$SCRIPT_DIR/fm-machine-remote.sh" \
      | ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "${PROBE_OPTS[@]}" "$alias" "$cmd" 2>/dev/null
    exit "${PIPESTATUS[1]}"
  )
  REMOTE_RC=$?
  set -e
}

# Probe the machine into PROBE_OUT, PROBE_RC and ACCOUNT_HOME.
probe_machine() { # <alias> <root|->
  local -a tools=()
  local tool
  while IFS= read -r tool; do tools+=("$tool"); done < <(machine_tools)
  remote_machine "$1" probe "$2" "$GATEWAY_URL" "$(hub_url)" "${tools[@]}"
  PROBE_RC=$REMOTE_RC
  PROBE_OUT=
  ACCOUNT_HOME=
  if [ "$PROBE_RC" -eq 0 ]; then
    PROBE_OUT=$REMOTE_OUT
    ACCOUNT_HOME=$(fact account-home)
  fi
}

fact() { # <key> -> value of the first "<key>=" line in PROBE_OUT
  printf '%s\n' "$PROBE_OUT" | awk -v k="$1=" 'index($0, k) == 1 { print substr($0, length(k) + 1); exit }'
}

interpret_doctor() {
  local line name state text action command checks=0 gaps=0 fixable=
  DOCTOR_ITEMS=
  DOCTOR_FAILURE=
  while IFS= read -r line; do
    case "$line" in
      required\ *=*)
        name=${line#required }
        state=${name#*=}
        name=${name%%=*}
        case "$state" in MISSING*|VERSION_UNREADABLE*) ;; *) continue ;; esac
        command=$(fm_home_tool_install_cmd "$name" 2>/dev/null || printf 'install %s on the remote runtime PATH' "$name")
        [ "$name" != harness ] || command='install Deck on the remote runtime PATH'
        DOCTOR_ITEMS="${DOCTOR_ITEMS}item doctor-required-$name=human: $command; doctor reports $state"$'\n'
        gaps=$((gaps + 1))
        ;;
      check\ *=*)
        name=${line#check }
        name=${name%%=*}
        state=${line#check "$name"=}
        text=${state#*: }
        state=${state%%:*}
        action=$(printf '%s\n' "$DOCTOR_OUT" | awk -v p="action: $name: " 'index($0, p) == 1 { print substr($0, length(p) + 1); exit }')
        checks=$((checks + 1))
        case "$state" in
          ok) state=present ;;
          skip) state=present; text="not needed yet: $text" ;;
          fixable)
            fixable="${fixable:+$fixable; }$name: $text"
            state=will-install
            [ "${DOCTOR_FIXED:-0}" -eq 0 ] || state=human
            text=${action:-$text}
            gaps=$((gaps + 1))
            ;;
          *) state=human; text=${action:-$text}; gaps=$((gaps + 1)) ;;
        esac
        DOCTOR_ITEMS="${DOCTOR_ITEMS}item doctor-$name=$state: $text"$'\n'
        ;;
    esac
  done <<EOF
$DOCTOR_OUT
EOF
  if [ "$checks" -eq 0 ]; then
    DOCTOR_FAILURE="doctor did not run: $(printf '%s\n' "$DOCTOR_OUT" | grep -v '^[[:space:]]*$' | tail -n 1)"
  elif [ "${DOCTOR_RC:-0}" -gt 1 ]; then
    DOCTOR_FAILURE="doctor transport or execution failed (exit $DOCTOR_RC)"
  elif [ "${DOCTOR_FIXED:-0}" -eq 1 ] && [ -n "$fixable" ]; then
    DOCTOR_FAILURE="fixable gaps remain after --fix: $fixable"
  elif [ "${DOCTOR_RC:-0}" -ne 0 ] && [ "$gaps" -eq 0 ]; then
    DOCTOR_FAILURE="doctor failed without reporting a gap (exit $DOCTOR_RC)"
  fi
}

# Build the checklist into ITEMS, one "item <name>=present|will-install|human: <text>"
# line each, from the ssh facts, PROBE_OUT and DOCTOR_OUT.
build_items() { # <alias> <root|-> <reach-class> <known-fingerprints>
  local alias=$1 root=$2 class=$3 known=$4 tool path cmd npm_global key_state gate
  ITEMS=
  item() { ITEMS="${ITEMS}item $1=$2: $3"$'\n'; }
  if [ "$ALIAS_CONFIGURED" -eq 1 ]; then
    item ssh-alias present "$alias resolves to $SSH_HOSTNAME as $SSH_USER"
  else
    item ssh-alias human "bin/fm-machine.sh add $alias ${CHECK_ADDRESS:-<address>} ${CHECK_USER:-<user>}"
  fi
  if [ -n "$known" ]; then
    item ssh-hostkey present "$KNOWN_NAME is in $KNOWN_HOSTS"
  else
    item ssh-hostkey human "verify the fingerprint bin/fm-machine.sh check $alias prints against the machine, then bin/fm-machine.sh trust $alias <SHA256:fingerprint>"
  fi
  case "$class" in
    ok) item ssh-login present "key login as $SSH_USER works without a prompt" ;;
    auth) item ssh-login human "ssh-copy-id $alias (or add the 1Password SSH agent public key to ~$SSH_USER/.ssh/authorized_keys on the machine)" ;;
    hostkey) item ssh-login human "trust the host key first (see ssh-hostkey)" ;;
    *) item ssh-login human "make $SSH_HOSTNAME reachable on port $SSH_PORT with its ssh server running ($class)" ;;
  esac
  if [ "$class" != ok ]; then
    item machine human "everything else is checked once ssh login works"
    return 0
  fi

  if [ "${PROBE_RC:-0}" -ne 0 ]; then
    for tool in firstmate-clone entrypoint-link doctor; do
      item "$tool" human "the probe over ssh failed (exit $PROBE_RC); rerun check"
    done
    while IFS= read -r tool; do
      item "tool-$tool" human "the probe over ssh failed (exit $PROBE_RC); rerun check"
    done < <(machine_tools)
    for tool in deck gh-auth model-gateway gateway-key stream-hub; do
      item "$tool" human "the probe over ssh failed (exit $PROBE_RC); rerun check"
    done
    return 0
  fi

  if [ "$root" = - ]; then
    item firstmate-clone human "name the remote code root: bin/fm-machine.sh check $alias <remote-root>"
  elif [ "$(fact clone)" = present ]; then
    item firstmate-clone present "$root"
  elif resolve_clone_url; then
    item firstmate-clone will-install "setup clones $CLONE_URL at $root"
  else
    item firstmate-clone human "$CLONE_REASON"
  fi
  if [ "$root" = - ]; then
    item entrypoint-link human "name the remote code root first: bin/fm-machine.sh check $alias <remote-root>"
  else
    case "$(fact entrypoint-link)" in
      present) item entrypoint-link present "the account's ~/.local/bin/fm-remote-entrypoint.sh points at $root" ;;
      conflict) item entrypoint-link human "the account's ~/.local/bin/fm-remote-entrypoint.sh on the machine is not a link to $root/bin/fm-remote-entrypoint.sh; inspect and move it" ;;
      *) item entrypoint-link will-install "setup links ~/.local/bin/fm-remote-entrypoint.sh to $root/bin/fm-remote-entrypoint.sh" ;;
    esac
  fi

  if [ "${DOCTOR_ATTEMPTED:-0}" -eq 1 ]; then
    interpret_doctor
    ITEMS="$ITEMS$DOCTOR_ITEMS"
    [ -z "$DOCTOR_FAILURE" ] || item doctor human "$DOCTOR_FAILURE; run bin/fm-machine.sh setup $alias $root"
  else
    item doctor will-install "setup runs fm-remote-doctor.sh --fix (remote job worker, entrypoint, tool wrappers) once the clone exists"
  fi

  npm_global=$(fact npm-global)
  while IFS= read -r tool; do
    path=$(fact "tool $tool")
    cmd=$(fm_home_tool_install_cmd "$tool" 2>/dev/null || printf 'install %s' "$tool")
    if [ -n "$path" ] && [ "$path" != missing ]; then
      item "tool-$tool" present "$path"
    elif ! fm_home_tool_user_installable "$tool"; then
      item "tool-$tool" human "$cmd"
    else
      case "$cmd" in
        'npm install -g '*)
          if [ "$(fact 'tool npm')" = missing ]; then
            item "tool-$tool" human "install node and npm first, then $cmd"
          elif [ "$npm_global" != writable ]; then
            item "tool-$tool" human "npm's global prefix is not writable by $SSH_USER; npm config set prefix ~/.local (or use a node version manager), then $cmd"
          else
            item "tool-$tool" will-install "$cmd"
          fi
          ;;
        *) item "tool-$tool" will-install "$cmd" ;;
      esac
    fi
  done < <(machine_tools)

  path=$(fact 'tool deck')
  if [ -n "$path" ] && [ "$path" != missing ]; then
    item deck present "$path"
  elif [ "$(fact 'tool cargo')" != missing ] && [ "$(fact 'tool git')" != missing ]; then
    item deck will-install "setup builds $DECK_REPO_URL with cargo build --release --locked into ~/.local/bin/deck"
  else
    item deck human "install Rust with rustup (https://rustup.rs) on the machine, then rerun setup to build Deck"
  fi

  case "$(fact gh-auth)" in
    ok) item gh-auth present "gh auth status succeeds" ;;
    missing) item gh-auth human "run gh auth login, then gh auth setup-git, on the machine" ;;
    *) item gh-auth human "install gh on the machine, then gh auth login and gh auth setup-git" ;;
  esac

  if [ "$(fact gateway)" = reachable ]; then
    item model-gateway present "$GATEWAY_URL answers"
  else
    item model-gateway human "make $GATEWAY_URL answer on the machine: run proxai there, or forward its port from the gateway host with a user service running ssh -N -L <port>:127.0.0.1:<port> <gateway-host>"
  fi
  key_state=$(fact gateway-key)
  case "$key_state" in
    present\ *) item gateway-key present "${key_state#present }" ;;
    unsafe\ *) item gateway-key will-install "setup restricts ${key_state#unsafe } to mode 600" ;;
    unreadable\ *) item gateway-key human "grant owner read access to ${key_state#unreadable } on the machine, then rerun setup" ;;
    *) item gateway-key human "put the gateway client key at ${key_state#missing path=} with mode 600, copied over a private channel; never paste it into chat" ;;
  esac

  case "$(fact stream-hub)" in
    reachable) item stream-hub present "$(hub_url) answers from the machine" ;;
    unreachable) item stream-hub human "make $(hub_url) reachable from the machine (docs/stream-backend.md owns encrypted cross-machine access), and give each home there its own config/stream-hub and config/stream-token" ;;
    *) item stream-hub human "this home has no config/stream-hub to check against; set it, then rerun" ;;
  esac

  gate=$(fact approval-gate)
  case "$gate" in
    *\ error=*) item approval-gate human "fix ~/.agents/approvals.json on the machine; every tool call is blocked until the policy is repaired: ${gate#* error=}" ;;
    hook=installed\ *) item approval-gate present "the approval gate runs in ~/.agents/deck.hooks.json; ${gate#hook=installed }; bin/fm-approval.sh enable <preset> on the machine turns gates on" ;;
    hook=missing\ *) item approval-gate will-install "setup installs the approval gate hook with no gates enabled; bin/fm-approval.sh enable <preset> on the machine then turns them on" ;;
    *) ;;  # a clone without bin/fm-approval.sh (or no clone yet) has nothing to report
  esac
  ITEMS="$ITEMS${SKILLS_ITEMS:-}"
}

items_not_present() { printf '%s' "$ITEMS" | grep -c -v -E '^item [^=]+=present:' || true; }

# Read config/shared-skills into SKILLS_SOURCE, SKILLS_REF, SKILLS_BRANCH,
# SKILLS_DIR and SKILLS_INSTALL. Returns 1 when absent; refuses a bad file.
shared_skills_config() {
  local file="$FM_HOME/config/shared-skills" line key value
  SKILLS_SOURCE='' SKILLS_REF=origin/main SKILLS_DIR=dotfiles SKILLS_INSTALL='./install.sh --skills-only'
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in ''|'#'*) continue ;; esac
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      source) SKILLS_SOURCE=$value ;;
      ref) SKILLS_REF=$value ;;
      dir) SKILLS_DIR=$value ;;
      install) SKILLS_INSTALL=$value ;;
      *) refuse "config/shared-skills has an unknown key: $key" ;;
    esac
  done < "$file"
  case "$SKILLS_SOURCE" in /*) ;; *) refuse "config/shared-skills needs source=<absolute path of the skills repo clone>" ;; esac
  git -C "$SKILLS_SOURCE" rev-parse --git-dir >/dev/null 2>&1 || refuse "config/shared-skills source is not a git clone: $SKILLS_SOURCE"
  case "$SKILLS_REF" in ''|-*|*[!A-Za-z0-9._/-]*) refuse "config/shared-skills ref must be a plain ref name: $SKILLS_REF" ;; esac
  case "$SKILLS_DIR" in ''|/*|-*|*[!A-Za-z0-9._/-]*|*..*) refuse "config/shared-skills dir must be a plain path under the remote home: $SKILLS_DIR" ;; esac
  case "$SKILLS_INSTALL" in ''|*[!A-Za-z0-9._/\ =-]*) refuse "config/shared-skills install must be a plain command: $SKILLS_INSTALL" ;; esac
  SKILLS_BRANCH=${SKILLS_REF#origin/}
  return 0
}

# Resolve the commit into SKILLS_COMMIT; the fetch argument refreshes origin/* first.
# Sets SKILLS_REASON and returns 1 on failure.
shared_skills_commit() {
  SKILLS_REASON=
  if [ "${1:-}" = fetch ]; then
    case "$SKILLS_REF" in
      origin/*) git -C "$SKILLS_SOURCE" fetch --quiet origin < /dev/null 2>/dev/null \
        || { SKILLS_REASON="git fetch origin failed in $SKILLS_SOURCE"; return 1; } ;;
    esac
  fi
  SKILLS_COMMIT=$(git -C "$SKILLS_SOURCE" rev-parse --verify --quiet "$SKILLS_REF^{commit}") \
    || { SKILLS_REASON="$SKILLS_REF does not name a commit in $SKILLS_SOURCE"; return 1; }
}

# Run a short sh script on the machine with args; sets SKILLS_OUT and SKILLS_RC.
skills_remote() { # <alias> <script> <args...>
  local alias=$1 script=$2 cmd='sh -s --' arg
  shift 2
  for arg in "$@"; do cmd="$cmd $(sq "$arg")"; done
  set +e
  # shellcheck disable=SC2029 # quoted for the remote shell on purpose.
  SKILLS_OUT=$(printf '%s\n' "$script" | ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "${PROBE_OPTS[@]}" "$alias" "$cmd" 2>&1)
  SKILLS_RC=$?
  set -e
}

# shellcheck disable=SC2016 # expanded by the remote shell.
SKILLS_STATE_SH='dir=$HOME/$1
if [ ! -e "$dir" ]; then echo "skills-repo=absent"
elif ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then echo "skills-repo=not-git"
else echo "skills-repo=present head=$(git -C "$dir" rev-parse HEAD 2>/dev/null)"; fi'

# Ensure <dir> on the machine can take the push: create it, or check it is a
# clean clone on <branch>.
# shellcheck disable=SC2016 # expanded by the remote shell.
SKILLS_PREPARE_SH='dir=$HOME/$1 url=$2 branch=$3
if [ ! -e "$dir" ]; then
  mkdir -p "$(dirname "$dir")" && git init -q -b "$branch" "$dir" && git -C "$dir" remote add origin "$url" || { echo "refuse: could not create a clone at $dir"; exit 3; }
  echo "skills-repo=created"
elif ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
  echo "refuse: $dir exists and is not a git clone"; exit 3
else
  [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] || { echo "refuse: $dir has local changes; commit or discard them on the machine"; exit 3; }
  cur=$(git -C "$dir" symbolic-ref --short -q HEAD)
  if [ "$cur" != "$branch" ]; then
    if [ -n "$cur" ] && ! git -C "$dir" rev-parse --verify -q HEAD >/dev/null && ! git -C "$dir" show-ref --quiet; then
      git -C "$dir" symbolic-ref HEAD "refs/heads/$branch" || exit 3
    else
      echo "refuse: $dir is on ${cur:-a detached HEAD}, not $branch"; exit 3
    fi
  fi
  echo "skills-repo=present"
fi'

# shellcheck disable=SC2016 # expanded by the remote shell.
SKILLS_FINISH_SH='dir=$HOME/$1 branch=$2 commit=$3 install=$4
cd "$dir" || exit 3
if git rev-parse --verify -q HEAD >/dev/null; then
  git merge --ff-only --no-overwrite-ignore -q "$commit" >/dev/null 2>&1 || { echo "refuse: $dir cannot safely fast-forward to $commit"; exit 3; }
else
  git checkout --no-overwrite-ignore -q -b "$branch" "$commit" >/dev/null 2>&1 || { echo "refuse: $dir cannot safely check out $commit"; exit 3; }
  git branch -q --set-upstream-to="origin/$branch" >/dev/null 2>&1
fi
[ "$(git rev-parse HEAD)" = "$commit" ] || { echo "refuse: $dir is not at $commit after the update"; exit 3; }
mkdir -p "$HOME/.cache"
sh -c "$install" < /dev/null > "$HOME/.cache/fm-shared-skills.log" 2>&1 || { echo "refuse: $install failed in $dir (log: ~/.cache/fm-shared-skills.log)"; exit 3; }
echo "linked=$(find "$HOME/.agents/skills" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d " ")"'

# Build SKILLS_ITEMS for check: shared-skills and skill-inventory.
skills_items() { # <alias>
  local head
  SKILLS_ITEMS=
  shared_skills_config || return 0
  if ! shared_skills_commit; then
    SKILLS_ITEMS="item shared-skills=human: $SKILLS_REASON"$'\n'
  else
    skills_remote "$1" "$SKILLS_STATE_SH" "$SKILLS_DIR"
    head=$(printf '%s\n' "$SKILLS_OUT" | sed -n 's/^skills-repo=present head=//p')
    if [ "$SKILLS_RC" -ne 0 ]; then
      SKILLS_ITEMS="item shared-skills=human: could not read ~/$SKILLS_DIR over ssh; rerun check"$'\n'
    elif [ "$head" = "$SKILLS_COMMIT" ]; then
      SKILLS_ITEMS="item shared-skills=present: ~/$SKILLS_DIR is at $SKILLS_REF ($(printf '%.7s' "$SKILLS_COMMIT"))"$'\n'
    elif printf '%s\n' "$SKILLS_OUT" | grep -q '^skills-repo=not-git'; then
      SKILLS_ITEMS="item shared-skills=human: ~/$SKILLS_DIR on the machine is not a git clone; move it aside"$'\n'
    else
      SKILLS_ITEMS="item shared-skills=will-install: setup ships $SKILLS_REF of $SKILLS_SOURCE to ~/$SKILLS_DIR and runs $SKILLS_INSTALL"$'\n'
    fi
  fi
  if [ -f "${FM_STATE_OVERRIDE:-$FM_HOME/state}/machine-skills/$1.tsv" ]; then
    SKILLS_ITEMS="${SKILLS_ITEMS}item skill-inventory=present: state/machine-skills/$1.tsv"$'\n'
  else
    SKILLS_ITEMS="${SKILLS_ITEMS}item skill-inventory=will-install: setup records it with bin/fm-machine-skills.sh refresh $1"$'\n'
  fi
}

# Ship the shared skills and record the inventory, printing step lines.
# Returns 1 on a failed step.
# A URL as the machine may record it: userinfo (a user, token or password before
# the host) never leaves this machine; scp-style and local paths pass through.
skills_url_without_userinfo() { # <url>
  local url=$1 scheme rest host
  case "$url" in
    *://*)
      scheme=${url%%://*}
      rest=${url#*://}
      host=${rest%%/*}
      case "$host" in *@*) rest=${host##*@}${rest#"$host"} ;; esac
      printf '%s://%s\n' "$scheme" "$rest"
      ;;
    *) printf '%s\n' "$url" ;;
  esac
}

# The machine's binding instructions (~/.agents/AGENTS.md), offered at connect:
# never written here, only reported, with the command that writes them.
# Sets INSTR_TEXT.
instructions_offer() { # <alias>
  local lines
  # A plain command, not `sh -s`: reading this file is never a clone or install.
  # shellcheck disable=SC2016 # expanded by the machine's shell.
  SKILLS_OUT=$(ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "${PROBE_OPTS[@]}" "$1" \
    'f=$HOME/.agents/AGENTS.md; if [ -f "$f" ]; then echo "present $(wc -l < "$f" | tr -d " ")"; else echo absent; fi' < /dev/null 2>/dev/null) || SKILLS_OUT=
  case "$SKILLS_OUT" in
    present\ *) lines=${SKILLS_OUT#present }; INSTR_TEXT="the machine's ~/.agents/AGENTS.md ($lines lines) binds every agent there; after registering this machine, review it with bin/fm-machine-instructions.sh show $1" ;;
    absent) INSTR_TEXT="none yet (optional): after registering this machine, read its version with bin/fm-machine-instructions.sh show $1, then write its binding instructions with bin/fm-machine-instructions.sh save $1 --expect <sha|none> or Fleet Town's Machine panel" ;;
    *) INSTR_TEXT="could not read ~/.agents/AGENTS.md over ssh; after registering this machine, check it with bin/fm-machine-instructions.sh show $1" ;;
  esac
}

skills_steps() { # <alias> <root>
  local alias=$1 root=$2 url line scratch out
  if ! shared_skills_config; then
    printf 'step shared-skills=skipped: this home has no config/shared-skills\n'
  else
    shared_skills_commit fetch || { printf 'step shared-skills=failed: %s\n' "$SKILLS_REASON"; return 1; }
    url=$(git -C "$SKILLS_SOURCE" config --get remote.origin.url || true)
    url=$(skills_url_without_userinfo "$url")
    fm_project_url_plain "$url" || url=
    skills_remote "$alias" "$SKILLS_PREPARE_SH" "$SKILLS_DIR" "$url" "$SKILLS_BRANCH"
    if [ "$SKILLS_RC" -ne 0 ]; then
      line=$(printf '%s\n' "$SKILLS_OUT" | awk '/^refuse: / { sub(/^refuse: /, ""); print; exit }')
      printf 'step shared-skills=failed: %s\n' "${line:-preparing ~/$SKILLS_DIR over ssh failed (exit $SKILLS_RC)}"
      return 1
    fi
    if ! out=$(GIT_SSH_COMMAND="ssh$(printf ' %q' "${SSH_OPTS[@]}" "${PROBE_OPTS[@]}")" \
      git -C "$SKILLS_SOURCE" push --quiet "$alias:$SKILLS_DIR" "$SKILLS_COMMIT:refs/remotes/origin/$SKILLS_BRANCH" < /dev/null 2>&1); then
      printf 'step shared-skills=failed: git push to %s:%s failed (%s)\n' "$alias" "$SKILLS_DIR" "$(printf '%s\n' "$out" | tail -n 1)"
      return 1
    fi
    skills_remote "$alias" "$SKILLS_FINISH_SH" "$SKILLS_DIR" "$SKILLS_BRANCH" "$SKILLS_COMMIT" "$SKILLS_INSTALL"
    if [ "$SKILLS_RC" -ne 0 ]; then
      line=$(printf '%s\n' "$SKILLS_OUT" | awk '/^refuse: / { sub(/^refuse: /, ""); print; exit }')
      printf 'step shared-skills=failed: %s\n' "${line:-updating ~/$SKILLS_DIR over ssh failed (exit $SKILLS_RC)}"
      return 1
    fi
    printf 'step shared-skills=done: ~/%s at %s (%s), %s skill links in ~/.agents/skills\n' "$SKILLS_DIR" "$SKILLS_REF" \
      "$(printf '%.7s' "$SKILLS_COMMIT")" "$(printf '%s\n' "$SKILLS_OUT" | sed -n 's/^linked=//p')"
  fi
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-machine.XXXXXX")
  TMP=$scratch
  {
    printf '#!/usr/bin/env bash\nexec ssh'
    printf ' %q' "${SSH_OPTS[@]}"
    printf ' "$@"\n'
  } > "$scratch/ssh"
  chmod 700 "$scratch/ssh"
  set +e
  out=$(FM_SSH_BIN="$scratch/ssh" "$SCRIPT_DIR/fm-machine-skills.sh" refresh "$alias:$root" 2>&1)
  set -e
  rm -rf -- "$scratch"
  TMP=
  case "$out" in
    *"refresh $alias=done: "*) printf 'step skill-inventory=done: %s recorded in state/machine-skills/%s.tsv\n' "${out##*=done: }" "$alias" ;;
    *) printf 'step skill-inventory=failed: %s\n' "${out##*=failed: }"; return 1 ;;
  esac
}

cmd_skills() { # <alias> [<remote-root>]
  local alias=$1 root=${2:-}
  valid_alias "$alias" || refuse "alias must be a plain ssh config name of A-Z, a-z, 0-9, ., _ and -, not starting with -: $alias"
  [ -n "$root" ] || root=$("$SCRIPT_DIR/fm-machine-skills.sh" roots 2>/dev/null | awk -F '\t' -v a="$alias" '$1 == a { print $2; exit }')
  [ -n "$root" ] || refuse "no remote root is recorded for $alias; pass it: bin/fm-machine.sh skills $alias <remote-root>"
  valid_root "$root" || refuse "remote root must be an absolute path of A-Z, a-z, 0-9, ., _, - and /: $root"
  printf 'action=skills\nalias=%s\nroot=%s\n' "$alias" "$root"
  resolve_alias "$alias" || refuse "ssh -G could not evaluate the alias $alias"
  skills_steps "$alias" "$root" || exit 1
}

cmd_setup() { # <alias> <remote-root>
  local alias=$1 root=$2 err rc class known line tool path result npm_global
  valid_alias "$alias" || refuse "alias must be a plain ssh config name of A-Z, a-z, 0-9, ., _ and -, not starting with -: $alias"
  valid_root "$root" || refuse "remote root must be an absolute path of A-Z, a-z, 0-9, ., _, - and /: $root"
  printf 'action=setup\nalias=%s\nroot=%s\n' "$alias" "$root"
  resolve_clone_url || refuse "$CLONE_REASON"
  resolve_alias "$alias" || refuse "ssh -G could not evaluate the alias $alias"
  known=$(known_fingerprints)
  DOCTOR_OUT=
  DOCTOR_ATTEMPTED=0
  DOCTOR_FIXED=0
  PROBE_OUT=
  PROBE_RC=0

  set +e
  err=$(ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "${PROBE_OPTS[@]}" "$alias" true < /dev/null 2>&1 >/dev/null)
  rc=$?
  set -e
  if [ "$rc" -eq 0 ]; then class=ok; else class=$(classify_reach "$err"); fi
  if [ "$class" != ok ]; then
    printf 'step ssh=failed: %s\n' "$(printf '%s' "$err" | grep -v '^[[:space:]]*$' | tail -n 1 | tr -d '\r')"
    setup_finish "$alias" "$root" "$class" "$known" 1
  fi
  printf 'step ssh=done: key login as %s works\n' "$SSH_USER"

  remote_clone_and_link "$alias" "$root" "$CLONE_URL"
  if [ "$CLONE_RC" -ne 0 ]; then
    line=$(printf '%s\n' "$CLONE_OUT" | awk '/^refuse: / { sub(/^refuse: /, ""); print; exit }')
    printf 'step firstmate-clone=failed: %s (exit %s)\n' "${line:-clone/link over ssh failed}" "$CLONE_RC"
    setup_finish "$alias" "$root" "$class" "$known" 1
  fi
  case "$CLONE_OUT" in
    *clone=present*) printf 'step firstmate-clone=skipped: already at %s\n' "$root" ;;
    *clone=created*) printf 'step firstmate-clone=done: cloned %s at %s\n' "$CLONE_URL" "$root" ;;
    *)
      printf 'step firstmate-clone=failed: %s\n' "$(printf '%s\n' "$CLONE_OUT" | awk '/^refuse: / { sub(/^refuse: /, ""); print; exit }')"
      setup_finish "$alias" "$root" "$class" "$known" 1
      ;;
  esac
  case "$CLONE_OUT" in
    *entrypoint-link=present*) printf 'step entrypoint-link=skipped: already linked\n' ;;
    *entrypoint-link=created*) printf 'step entrypoint-link=done: linked ~/.local/bin/fm-remote-entrypoint.sh\n' ;;
    *)
      printf 'step entrypoint-link=failed: ~/.local/bin/fm-remote-entrypoint.sh is something else; inspect it on the machine\n'
      setup_finish "$alias" "$root" "$class" "$known" 1
      ;;
  esac

  probe_machine "$alias" "$root"
  if [ "$PROBE_RC" -ne 0 ]; then
    printf 'step probe=failed: the probe over ssh failed (exit %s)\n' "$PROBE_RC"
    setup_finish "$alias" "$root" "$class" "$known" 1
  fi
  case "$ACCOUNT_HOME" in /?*) ;; *) printf 'step probe=failed: could not read the machine'"'"'s facts over ssh\n'; setup_finish "$alias" "$root" "$class" "$known" 1 ;; esac
  npm_global=$(fact npm-global)
  while IFS= read -r tool; do
    path=$(fact "tool $tool")
    if [ -n "$path" ] && [ "$path" != missing ]; then
      printf 'step tool-%s=skipped: present at %s\n' "$tool" "$path"
      continue
    fi
    fm_home_tool_user_installable "$tool" || continue
    case "$(fm_home_tool_install_cmd "$tool")" in
      'npm install -g '*) [ "$(fact 'tool npm')" != missing ] && [ "$npm_global" = writable ] || continue ;;
    esac
    remote_machine "$alias" install-tool "$tool" "$root"
    result=$(printf '%s\n' "$REMOTE_OUT" | awk '/^result=/ { sub(/^result=/, ""); print; exit }')
    if [ "$REMOTE_RC" -ne 0 ]; then
      case "$result" in
        failed:*) line=${result#failed: } ;;
        *) line='the install over ssh failed' ;;
      esac
      printf 'step tool-%s=failed: %s (exit %s)\n' "$tool" "$line" "$REMOTE_RC"
      setup_finish "$alias" "$root" "$class" "$known" 1
    fi
    case "$result" in
      done*) printf 'step tool-%s=%s\n' "$tool" "$result" ;;
      *) printf 'step tool-%s=failed: %s\n' "$tool" "${result#failed: }"
         setup_finish "$alias" "$root" "$class" "$known" 1 ;;
    esac
  done < <(machine_tools)

  path=$(fact 'tool deck')
  if [ -n "$path" ] && [ "$path" != missing ]; then
    printf 'step deck=skipped: present at %s\n' "$path"
  elif [ "$(fact 'tool cargo')" != missing ] && [ "$(fact 'tool git')" != missing ]; then
    remote_machine "$alias" install-deck "$root" "$DECK_REPO_URL"
    result=$(printf '%s\n' "$REMOTE_OUT" | awk '/^result=/ { sub(/^result=/, ""); print; exit }')
    if [ "$REMOTE_RC" -ne 0 ]; then
      case "$result" in
        failed:*) line=${result#failed: } ;;
        *) line='the install over ssh failed' ;;
      esac
      printf 'step deck=failed: %s (exit %s)\n' "$line" "$REMOTE_RC"
      setup_finish "$alias" "$root" "$class" "$known" 1
    fi
    case "$result" in
      done*) printf 'step deck=%s\n' "$result" ;;
      *) printf 'step deck=failed: %s\n' "${result#failed: }"
         setup_finish "$alias" "$root" "$class" "$known" 1 ;;
    esac
  fi

  case "$(fact gateway-key)" in
    unsafe\ *)
      line=$(fact gateway-key)
      line=${line#unsafe path=}
      line=${line% mode=*}
      # shellcheck disable=SC2029 # quoted for the remote shell on purpose.
      if ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "${PROBE_OPTS[@]}" "$alias" "chmod 600 $(sq "$line")" < /dev/null >/dev/null 2>&1; then
        printf 'step gateway-key-mode=done: %s is now mode 600\n' "$line"
      else
        printf 'step gateway-key-mode=failed: could not restrict %s to mode 600\n' "$line"
        setup_finish "$alias" "$root" "$class" "$known" 1
      fi
      ;;
  esac

  run_doctor "$alias" "$root" "$ACCOUNT_HOME" --fix
  interpret_doctor
  if [ -n "$DOCTOR_FAILURE" ]; then
    printf 'step doctor=failed: %s\n' "$DOCTOR_FAILURE"
    setup_finish "$alias" "$root" "$class" "$known" 1
  fi
  printf 'step doctor=done: fm-remote-doctor.sh --fix ran (exit %s)\n' "$DOCTOR_RC"
  case "$(fact approval-gate)" in
    hook=installed\ *) printf 'step approval-gate=skipped: already installed\n' ;;
    unknown|'') printf 'step approval-gate=skipped: the clone at %s has no bin/fm-approval.sh yet\n' "$root" ;;
    *)
      remote_machine "$alias" install-approval-gate "$root"
      result=$(printf '%s\n' "$REMOTE_OUT" | awk '/^result=/ { sub(/^result=/, ""); print; exit }')
      case "$REMOTE_RC:$result" in
        0:done*) printf 'step approval-gate=%s\n' "$result" ;;
        *) printf 'step approval-gate=failed: %s\n' "${result#failed: }"
           setup_finish "$alias" "$root" "$class" "$known" 1 ;;
      esac
      ;;
  esac
  skills_steps "$alias" "$root" || setup_finish "$alias" "$root" "$class" "$known" 1
  instructions_offer "$alias"
  printf 'step machine-instructions=skipped: %s\n' "$INSTR_TEXT"
  probe_machine "$alias" "$root"
  if [ "$PROBE_RC" -ne 0 ]; then
    printf 'step probe=failed: the probe over ssh failed (exit %s)\n' "$PROBE_RC"
    setup_finish "$alias" "$root" "$class" "$known" 1
  fi
  setup_finish "$alias" "$root" "$class" "$known" 0
}

# Print the remaining human steps and the verdict, then exit.
setup_finish() { # <alias> <root> <reach-class> <known> <failed 0|1>
  local line name text count=0
  SKILLS_ITEMS=
  [ "$3" != ok ] || [ "${PROBE_RC:-0}" -ne 0 ] || skills_items "$1"
  build_items "$1" "$2" "$3" "$4"
  while IFS= read -r line; do
    case "$line" in
      item\ *=human:*)
        name=${line#item }
        text=${name#*=human: }
        name=${name%%=*}
        printf 'human %s: %s\n' "$name" "$text"
        count=$((count + 1))
        ;;
    esac
  done <<EOF
$ITEMS
EOF
  if [ "$5" -eq 1 ]; then
    printf 'setup=failed\n'
    exit 1
  fi
  if [ "$count" -gt 0 ]; then
    printf 'setup=incomplete: %s human steps\n' "$count"
    exit 3
  fi
  printf 'setup=complete\n'
  exit 0
}

# 0 when a URL is safe to embed single-quoted in a remote command.
fm_project_url_plain() { case "$1" in *[!A-Za-z0-9._~:/@%+=,-]*) return 1 ;; esac; }

cmd_register() { # <alias> <remote-root>
  local alias=$1 root=$2 file existing tmp
  valid_alias "$alias" || refuse "alias must be a plain ssh config name of A-Z, a-z, 0-9, ., _ and -, not starting with -: $alias"
  valid_root "$root" || refuse "remote root must be an absolute path of A-Z, a-z, 0-9, ., _, - and /: $root"
  printf 'action=register\nalias=%s\n' "$alias"
  file="$DATA/machines.md"
  mkdir -p "$DATA"
  if [ -e "$file" ] || [ -L "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || refuse "$file is not a regular file"
    existing=$(awk -v a="$alias" '$1 == "-" && $2 == a { print; exit }' "$file")
    if [ -n "$existing" ]; then
      case "$existing" in
        "- $alias (root: $root; added "*) printf 'register=already-recorded\n'; return 0 ;;
        *) refuse "$alias is already recorded with a different root: $existing" ;;
      esac
    fi
  fi
  tmp=$(mktemp "$DATA/.machines.md.XXXXXX")
  [ ! -f "$file" ] || cat "$file" > "$tmp"
  printf -- '- %s (root: %s; added %s)\n' "$alias" "$root" "$(date +%F)" >> "$tmp"
  mv -f -- "$tmp" "$file"
  printf 'registered=%s root=%s\n' "$alias" "$root"
}

main() {
  trap '[ -z "$TMP" ] || rm -rf -- "$TMP"' EXIT
  [ "$#" -ge 1 ] || usage
  local sub=$1
  shift
  case "$sub" in
    check) [ "$#" -ge 1 ] || usage; cmd_check "$@" ;;
    setup) [ "$#" -eq 2 ] || usage; cmd_setup "$1" "$2" ;;
    add) [ "$#" -eq 3 ] || usage; cmd_add "$1" "$2" "$3" ;;
    trust) [ "$#" -eq 2 ] || usage; cmd_trust "$1" "$2" ;;
    prepare) [ "$#" -eq 2 ] || usage; cmd_prepare "$1" "$2" ;;
    register) [ "$#" -eq 2 ] || usage; cmd_register "$1" "$2" ;;
    skills) [ "$#" -ge 1 ] && [ "$#" -le 2 ] || usage; cmd_skills "$@" ;;
    *) usage ;;
  esac
}

main "$@" 2>&1 | fm_machine_redact_urls
exit "${PIPESTATUS[0]}"
