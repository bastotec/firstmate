#!/usr/bin/env bash
# Connect a new machine for remote second mates in scripted, reviewable steps.
#
# Usage:
#   fm-machine.sh check <alias>
#   fm-machine.sh add <alias> <address> <user>
#   fm-machine.sh trust <alias> <SHA256:fingerprint>
#   fm-machine.sh prepare <alias> <remote-root>
#   fm-machine.sh register <alias> <remote-root>
#
# This is the deterministic entry point for an order that connects a machine
# (for example one sent from a UI and confirmed by the captain). It never
# handles private keys, never accepts a host key it was not given, and never
# installs packages. docs/remote-secondmates.md owns what a ready host needs and
# bin/fm-remote-doctor.sh owns the readiness verdict.
#
# check <alias> is read-only. It reports whether an ssh config block sets a
# HostName for the alias (ssh -G), whether the host key is known (ssh-keygen -F),
# and when it is not, the scanned key fingerprints (ssh-keyscan piped to
# ssh-keygen -lf -, never written anywhere). It then tries
#   ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=8 <alias> true
# and, when that connects, runs read-only `command -v` probes over one more such
# call for fm-remote-entrypoint.sh, deck and proxai on the account's
# non-interactive PATH. Exit 0 only when every check is ok.
#
# add <alias> <address> <user> appends a marked Host block (HostName, User,
# StrictHostKeyChecking yes, ConnectTimeout 8, ForwardAgent no) to the ssh
# config, and refuses when an existing block already sets a HostName for the
# alias or names it on a Host line.
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
# checks as skip for an absent home and creates nothing there. Deck, proxai and
# every other missing tool stay the doctor's human steps.
#
# register <alias> <remote-root> records the machine in this home's
# data/machines.md as `- <alias> (root: <remote-root>; added YYYY-MM-DD)`. It is
# idempotent for the same root and refuses a different root for a recorded
# alias.
#
# FM_SSH_CONFIG and FM_KNOWN_HOSTS replace ~/.ssh/config and ~/.ssh/known_hosts
# (they are passed to ssh as -F and -o UserKnownHostsFile=); tests use them.
#
# Line protocol on stdout, one fact per line, stable for script consumers:
#   action=check|add|trust|prepare|register
#   alias=<alias>
#   hostname=<name> user=<user> port=<port>     (check)
#   hostkey-fingerprint=<SHA256:...> type=<TYPE> (check, when the key is unknown)
#   reach=ok|auth|hostkey|timeout|refused|unresolved|error   (check)
#   tool <name>=<path>|missing                   (check, when reachable)
#   check <name>=ok|missing|unknown: <evidence>  (check: alias, hostkey, reach, entrypoint, deck, proxai)
#   action: <exact step for the captain>         (after each gap)
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
KNOWN_HOSTS="${FM_KNOWN_HOSTS:-$HOME/.ssh/known_hosts}"

# shellcheck source=bin/fm-home-route-lib.sh
. "$SCRIPT_DIR/fm-home-route-lib.sh"

usage() { sed -n '2,9p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
refuse() { printf 'refuse: %s\n' "$1"; exit 1; }

SSH_OPTS=()
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
  local out alias_lc hostkeyalias
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
}

# 0 when a Host line in the ssh config names the alias literally.
config_names_alias() { # <alias>
  [ -f "$SSH_CONFIG" ] || return 1
  awk -v a="$1" '
    tolower($1) == "host" { for (i = 2; i <= NF; i++) if ($i == a) found = 1 }
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

cmd_check() { # <alias>
  local alias=$1 gaps=0 known scanned err rc class first probe
  valid_alias "$alias" || refuse "alias must be a plain ssh config name of A-Z, a-z, 0-9, ., _ and -, not starting with -: $alias"
  printf 'action=check\nalias=%s\n' "$alias"
  resolve_alias "$alias" || refuse "ssh -G could not evaluate the alias $alias"
  printf 'hostname=%s user=%s port=%s\n' "$SSH_HOSTNAME" "$SSH_USER" "$SSH_PORT"
  if [ "$ALIAS_CONFIGURED" -eq 1 ]; then
    printf 'check alias=ok: %s resolves to %s as %s on port %s\n' "$alias" "$SSH_HOSTNAME" "$SSH_USER" "$SSH_PORT"
  else
    gaps=1
    printf 'check alias=missing: no ssh config block sets a HostName for %s\n' "$alias"
    printf 'action: bin/fm-machine.sh add %s <address> <user>\n' "$alias"
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

  if [ "$class" = ok ]; then
    set +e
    probe=$(ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "${PROBE_OPTS[@]}" "$alias" sh -s 2>/dev/null <<'SH'
for t in fm-remote-entrypoint.sh deck proxai; do
  p=$(command -v "$t" 2>/dev/null) || p=
  printf 'tool %s=%s\n' "$t" "${p:-missing}"
done
SH
)
    rc=$?
    set -e
    for tool in fm-remote-entrypoint.sh deck proxai; do
      path=$(printf '%s\n' "$probe" | awk -v t="tool $tool=" 'index($0, t) == 1 { print substr($0, length(t) + 1); exit }')
      name=${tool%.sh}
      name=${name#fm-remote-}
      if [ "$rc" -ne 0 ] || [ -z "$path" ]; then
        gaps=1
        printf 'tool %s=unknown\n' "$tool"
        printf 'check %s=unknown: the PATH probe over ssh failed (exit %s)\n' "$name" "$rc"
        printf 'action: rerun bin/fm-machine.sh check %s\n' "$alias"
        continue
      fi
      printf 'tool %s=%s\n' "$tool" "$path"
      if [ "$path" != missing ]; then
        printf 'check %s=ok: %s\n' "$name" "$path"
        continue
      fi
      gaps=1
      printf 'check %s=missing: %s is not on the non-interactive ssh PATH\n' "$name" "$tool"
      case "$tool" in
        fm-remote-entrypoint.sh) printf 'action: bin/fm-machine.sh prepare %s <remote-root>\n' "$alias" ;;
        deck) printf 'action: install Deck on the machine for %s and expose it on the non-interactive PATH (docs/remote-secondmates.md "Non-interactive tool contract")\n' "$SSH_USER" ;;
        proxai) printf 'action: install proxai on the machine for %s and set its client key there (docs/remote-secondmates.md "Readiness, repair, and the human steps")\n' "$SSH_USER" ;;
      esac
    done
  fi
  return "$gaps"
}

cmd_add() { # <alias> <address> <user>
  local alias=$1 address=$2 user=$3 today
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
  mkdir -p "$(dirname "$SSH_CONFIG")"
  chmod 700 "$(dirname "$SSH_CONFIG")" 2>/dev/null || true
  if [ ! -e "$SSH_CONFIG" ]; then (umask 077; : > "$SSH_CONFIG"); fi
  [ -f "$SSH_CONFIG" ] && [ ! -L "$SSH_CONFIG" ] || refuse "$SSH_CONFIG is not a regular file"
  if [ -s "$SSH_CONFIG" ] && [ "$(tail -c 1 "$SSH_CONFIG" | od -An -c | tr -d ' ')" != '\n' ]; then
    printf '\n' >> "$SSH_CONFIG"
  fi
  today=$(date +%F)
  {
    printf '\n# >>> firstmate machine %s (added %s)\n' "$alias" "$today"
    printf 'Host %s\n' "$alias"
    printf '  HostName %s\n' "$address"
    printf '  User %s\n' "$user"
    printf '  StrictHostKeyChecking yes\n'
    printf '  ConnectTimeout 8\n'
    printf '  ForwardAgent no\n'
    printf '# <<< firstmate machine %s\n' "$alias"
  } >> "$SSH_CONFIG"
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

cmd_prepare() { # <alias> <remote-root>
  local alias=$1 root=$2 url out rc account_home line scratch status=0 doctor_out
  valid_alias "$alias" || refuse "alias must be a plain ssh config name of A-Z, a-z, 0-9, ., _ and -, not starting with -: $alias"
  valid_root "$root" || refuse "remote root must be an absolute path of A-Z, a-z, 0-9, ., _, - and /: $root"
  printf 'action=prepare\nalias=%s\n' "$alias"
  url=$(fm_home_route_url "$FM_ROOT")
  [ -n "$url" ] || refuse "this Firstmate checkout has no origin to clone from"
  fm_home_route_is_remote "$url" || refuse "this Firstmate checkout's origin is $url, a local path the machine cannot clone from; point origin at the fork's network URL first"
  fm_project_url_plain "$url" || refuse "this Firstmate checkout's origin contains characters this command will not pass to a remote shell: $url"

  set +e
  out=$(ssh "${SSH_OPTS[@]+"${SSH_OPTS[@]}"}" "${PROBE_OPTS[@]}" "$alias" sh -s -- "$root" "$url" <<'SH'
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
  git clone --quiet -- "$url" "$root" >&2 || { printf 'refuse: git clone of %s into %s failed\n' "$url" "$root"; exit 3; }
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
  rc=$?
  set -e
  account_home=
  while IFS= read -r line; do
    case "$line" in
      account-home=*) account_home=${line#account-home=} ;;
      clone=*) printf '%s root=%s\n' "$line" "$root" ;;
      *) printf '%s\n' "$line" ;;
    esac
  done <<EOF
$out
EOF
  [ "$rc" -ne 255 ] || refuse "ssh to $alias failed; run bin/fm-machine.sh check $alias"
  [ "$rc" -eq 0 ] || exit 1
  case "$out" in *'entrypoint-link=conflict'*) refuse "the ~/.local/bin/fm-remote-entrypoint.sh link on $alias is not Firstmate's link to $root; inspect it on the machine" ;; esac
  case "$account_home" in /?*) ;; *) refuse "could not read the remote account's home directory" ;; esac

  # fm-on.sh routes only to recorded homes, so reach this machine through a
  # scratch registry with one route and an absent probe home.
  scratch=$(mktemp -d "${TMPDIR:-/tmp}/fm-machine.XXXXXX")
  printf -- '- fm-machine-probe - machine readiness probe (host: %s; root: %s; home: %s/.firstmate-machine-probe; scope: readiness probe; projects: ; added %s)\n' \
    "$alias" "$root" "$account_home" "$(date +%F)" > "$scratch/secondmates.md"
  set +e
  doctor_out=$(FM_DATA_OVERRIDE="$scratch" "$SCRIPT_DIR/fm-on.sh" fm-machine-probe fm-remote-doctor.sh --backend stream --fix < /dev/null 2>&1)
  status=$?
  set -e
  rm -rf -- "$scratch"
  printf '%s\n' "$doctor_out" | sed 's/^/doctor: /'
  return "$status"
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

[ "$#" -ge 1 ] || usage
SUB=$1
shift
case "$SUB" in
  check) [ "$#" -eq 1 ] || usage; cmd_check "$1" ;;
  add) [ "$#" -eq 3 ] || usage; cmd_add "$1" "$2" "$3" ;;
  trust) [ "$#" -eq 2 ] || usage; cmd_trust "$1" "$2" ;;
  prepare) [ "$#" -eq 2 ] || usage; cmd_prepare "$1" "$2" ;;
  register) [ "$#" -eq 2 ] || usage; cmd_register "$1" "$2" ;;
  *) usage ;;
esac
