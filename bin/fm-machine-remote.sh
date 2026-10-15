#!/usr/bin/env bash
# The machine-side half of bin/fm-machine.sh: facts and narrow installs that run
# as the remote account itself.
#
# Usage (bootstrap calls from bin/fm-machine.sh send the tools and output
# libraries followed by this file as `ssh <alias> bash -s -- ...`; shared-skills
# calls run the tracked command through bin/fm-on.sh's machine lane instead.
# Run directly, it sources those libraries from beside itself):
#   fm-machine-remote.sh probe <remote-root> <gateway-url> <hub-url|-> <tool>...
#   fm-machine-remote.sh install-tool <tool> <remote-root>
#   fm-machine-remote.sh install-deck <remote-root> <deck-repo-url>
#   fm-machine-remote.sh skills-prepare <dir> <url> <branch>
#   fm-machine-remote.sh skills-import <dir> <branch> <commit> < pack
#   fm-machine-remote.sh skills-finish <dir> <branch> <commit> <install>
#   fm-machine-remote.sh install-approval-gate <remote-root>
#   fm-machine-remote.sh tunnel-key <alias>
#   fm-machine-remote.sh install-tunnel <label> <port> <user> <host> <ssh-port> <known-hosts-line> <check-url> gateway|hub
#
# Bootstrap calls need no Firstmate checkout on the machine and work before prepare.
# Shared-skills calls require the prepared checkout and remote job worker;
# bin/fm-machine.sh's header owns their provisioning contract.
# Runtime lookups and install checks use the remote job worker's PATH, composed by
# that checkout's bin/fm-remote-job-lib.sh when <remote-root> already holds
# one; before that it uses the ssh PATH with ~/.local/bin in front, and says so.
# The build-only cargo lookup prepends ~/.cargo/bin in both probe and install.
#
# probe is read-only and prints one fact per line:
#   account-home=<the account's home directory>
#   path-source=worker|ssh
#   clone=present|absent
#   entrypoint-link=present|absent|conflict|unknown (unknown when remote-root is -)
#   tool <name>=<path>|missing         (each named tool, then deck, cargo and npm)
#   npm-global=writable|not-writable|unknown
#   gh-auth=ok|missing|unknown         (only the exit status of `gh auth status`)
#   gateway=reachable|unreachable      (any HTTP answer from <gateway-url>/models)
#   gateway-key=present|missing|unsafe|unreadable path=<file> [mode=<octal>]
#   stream-hub=reachable|unreachable|unknown
#   approval-gate=hook=installed|missing gates=<ids>|none [error=...]   (unknown without a clone)
# The gateway key file is $PROXAI_API_KEY_FILE when the ssh environment sets it,
# else ~/.config/proxai/client.key, where Deck looks by default. Only its
# presence and mode are read; its contents are never opened. `unreadable` means
# the owner-read bit is absent; `unsafe` means the owner can read but group or
# other bits are set; `present` means owner-read with no group or other bits.
# Missing files and symlinks report `missing`.
#
# install-tool runs the install command bin/fm-home-tools-lib.sh prints for
# <tool>, only when that command is a user-level one, and then requires <tool>
# to resolve on the worker PATH.
# install-deck clones or fetches <deck-repo-url> into ~/.cache/firstmate/deck,
# builds it with `cargo build --release --locked`, the build the Deck repo
# documents, and installs the binary atomically at ~/.local/bin/deck. It refuses
# to reuse a cached clone with a different origin. Both print one
# `result=done|failed: <reason>` line, with URL userinfo redacted in all output.
# install-approval-gate runs <remote-root>/bin/fm-approval.sh install-hook, which
# merges the approval gate into ~/.agents/deck.hooks.json; it enables no gate
# (bin/fm-approval.py owns the policy) and prints the same result line.
#
# tunnel-key makes ~/.ssh/fm_workload_tunnel (ed25519, no passphrase, comment
# fm-tunnel@<alias>) when it is absent and prints `pubkey=<public key line>`;
# the private key never leaves the machine.
# install-tunnel keeps 127.0.0.1:<port> forwarded to the same port on the
# gateway host with a KeepAlive user service: launchd (~/Library/LaunchAgents/
# <label>.plist, bootstrapped in gui/<uid>) on macOS, systemd --user
# (~/.config/systemd/user/<label>.service, Restart=always) on Linux.
# Linux requires `loginctl show-user <account> -p Linger` to report Linger=yes
# before writing a pin or service or invoking systemctl; otherwise it refuses
# with the human step `sudo loginctl enable-linger <account>` on the machine,
# then rerun setup. It never enables lingering itself; the caller may already
# have created the key and gateway authorization before this refusal.
# The service runs /usr/bin/ssh -N with absolute key and pin paths, BatchMode,
# IdentitiesOnly=yes, IdentityAgent=none, strict host-key checking against
# ~/.ssh/fm_workload_known_hosts (written from <known-hosts-line>; an existing
# pin file without that exact line is refused), ExitOnForwardFailure and
# ServerAliveInterval=15/ServerAliveCountMax=3. A non-default SSH port adds -p.
# A successful TCP connect to 127.0.0.1:<port> is refused before writing a pin
# or service unless this label is loaded in launchd or active in systemd;
# neither an HTTP timeout nor an existing service file establishes ownership.
# An unchanged, loaded/active service is left alone; otherwise it is installed
# and started. Verification makes at most 15 attempts, one second apart:
# gateway needs HTTP 200 from <check-url>/models with the gateway client key
# (PROXAI_API_KEY_FILE or ~/.config/proxai/client.key, read on the machine and
# passed via curl -K on stdin, never argv or output); hub needs any HTTP answer
# from <check-url>. A verification failure leaves the installed service in place
# and prints result=failed; success prints result=done.
set -u

if ! declare -F fm_home_tool_install_cmd >/dev/null; then
  # shellcheck source=bin/fm-home-tools-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-home-tools-lib.sh"
fi

if ! declare -F fm_machine_redact_urls >/dev/null; then
  # shellcheck source=bin/fm-machine-output-lib.sh
  . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-machine-output-lib.sh"
fi

die() { printf 'result=failed: %s\n' "$1"; exit 1; }

build_cargo() { (PATH="$HOME/.cargo/bin:$PATH"; command -v cargo); }

use_worker_path() { # <remote-root>
  local root=$1
  if [ -f "$root/bin/fm-remote-job-lib.sh" ]; then
    # shellcheck source=bin/fm-remote-job-lib.sh disable=SC1091
    . "$root/bin/fm-remote-job-lib.sh"
    fm_remote_job_compose_operator_path "$HOME" >/dev/null
    PATH=$(fm_remote_job_build_child_path "$root")
    PATH_SOURCE=worker
  else
    PATH="$HOME/.local/bin:$PATH"
    PATH_SOURCE=ssh
  fi
  export PATH
}

file_mode() { # <file>
  if stat -f %Lp "$1" >/dev/null 2>&1; then stat -f %Lp "$1"; else stat -c %a "$1"; fi
}

cmd_probe() { # <root> <gateway-url> <hub-url|-> <tool>...
  local root=$1 gateway=$2 hub=$3 tool p link prefix code key mode
  shift 3
  printf 'account-home=%s\n' "$HOME"
  use_worker_path "$root"
  printf 'path-source=%s\n' "$PATH_SOURCE"
  if [ -f "$root/AGENTS.md" ] && [ -f "$root/bin/fm-remote-entrypoint.sh" ]; then
    printf 'clone=present\n'
  else
    printf 'clone=absent\n'
  fi
  link="$HOME/.local/bin/fm-remote-entrypoint.sh"
  if [ "$root" = - ]; then
    printf 'entrypoint-link=unknown\n'
  elif [ -L "$link" ] && [ "$(readlink "$link")" = "$root/bin/fm-remote-entrypoint.sh" ]; then
    printf 'entrypoint-link=present\n'
  elif [ -e "$link" ] || [ -L "$link" ]; then
    printf 'entrypoint-link=conflict\n'
  else
    printf 'entrypoint-link=absent\n'
  fi
  for tool in "$@" deck cargo npm; do
    if [ "$tool" = cargo ]; then
      p=$(build_cargo 2>/dev/null) || p=
    else
      p=$(command -v "$tool" 2>/dev/null) || p=
    fi
    printf 'tool %s=%s\n' "$tool" "${p:-missing}"
  done
  if command -v npm >/dev/null 2>&1; then
    prefix=$(npm prefix -g 2>/dev/null < /dev/null) || prefix=
    if [ -z "$prefix" ]; then
      printf 'npm-global=unknown\n'
    elif [ -w "$prefix" ] && { [ ! -e "$prefix/lib" ] || [ -w "$prefix/lib" ]; }; then
      printf 'npm-global=writable\n'
    else
      printf 'npm-global=not-writable\n'
    fi
  else
    printf 'npm-global=unknown\n'
  fi
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1 < /dev/null; then printf 'gh-auth=ok\n'; else printf 'gh-auth=missing\n'; fi
  else
    printf 'gh-auth=unknown\n'
  fi
  code=000
  if command -v curl >/dev/null 2>&1; then
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "${gateway%/}/models" < /dev/null 2>/dev/null) || true
  fi
  case "$code" in 000|'') printf 'gateway=unreachable\n' ;; *) printf 'gateway=reachable\n' ;; esac
  key=${PROXAI_API_KEY_FILE:-$HOME/.config/proxai/client.key}
  if [ -f "$key" ] && [ ! -L "$key" ]; then
    mode=$(file_mode "$key")
    if [ "$((8#$mode & 0400))" -eq 0 ]; then
      printf 'gateway-key=unreadable path=%s mode=%s\n' "$key" "$mode"
    elif [ "$((8#$mode & 0077))" -ne 0 ]; then
      printf 'gateway-key=unsafe path=%s mode=%s\n' "$key" "$mode"
    else
      printf 'gateway-key=present path=%s mode=%s\n' "$key" "$mode"
    fi
  else
    printf 'gateway-key=missing path=%s\n' "$key"
  fi
  if [ "$hub" = - ] || ! command -v curl >/dev/null 2>&1; then
    printf 'stream-hub=unknown\n'
  else
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$hub" < /dev/null 2>/dev/null) || true
    case "$code" in 000|'') printf 'stream-hub=unreachable\n' ;; *) printf 'stream-hub=reachable\n' ;; esac
  fi
  if [ "$root" != - ] && [ -f "$root/bin/fm-approval.sh" ] && command -v python3 >/dev/null 2>&1; then
    printf 'approval-gate=%s\n' "$(bash "$root/bin/fm-approval.sh" status < /dev/null 2>/dev/null | head -n 1)"
  else
    printf 'approval-gate=unknown\n'
  fi
}

cmd_install_approval_gate() { # <root>
  local root=$1 out
  [ -f "$root/bin/fm-approval.sh" ] || die "no bin/fm-approval.sh in $root; update the Firstmate clone first"
  command -v python3 >/dev/null 2>&1 || die "python3 is missing"
  out=$(bash "$root/bin/fm-approval.sh" install-hook < /dev/null 2>&1) || die "${out:-install-hook failed}"
  printf 'result=done: %s\n' "$out"
}

cmd_install_tool() { # <tool> <root>
  local tool=$1 root=$2 command
  fm_home_tool_user_installable "$tool" || die "$tool has no user-level install command"
  command=$(fm_home_tool_install_cmd "$tool")
  use_worker_path "$root"
  bash -c "$command" < /dev/null >&2 || die "the install command for $tool failed"
  command -v "$tool" >/dev/null 2>&1 || die "$tool installed but does not resolve on the worker PATH"
  printf 'result=done: %s\n' "$(command -v "$tool")"
}

cmd_install_deck() { # <root> <repo-url>
  local root=$1 url=$2 src dest tmp cargo origin
  use_worker_path "$root"
  command -v git >/dev/null 2>&1 || die "git is missing"
  cargo=$(build_cargo) || die "cargo is missing"
  PATH="$HOME/.cargo/bin:$PATH"
  src="$HOME/.cache/firstmate/deck"
  mkdir -p "$(dirname "$src")" || die "cannot create $(dirname "$src")"
  if [ -d "$src/.git" ]; then
    origin=$(git -C "$src" config --get remote.origin.url) || die "cannot read the origin of $src"
    [ "$origin" = "$url" ] || die "cached Deck clone at $src has a different origin"
  else
    git clone --quiet -- "$url" "$src" < /dev/null >&2 \
      || die "git clone of $url failed; the machine needs read access to it (gh auth login, then gh auth setup-git)"
  fi
  git -C "$src" fetch --quiet origin < /dev/null >&2 || die "git fetch of $url failed"
  git -C "$src" -c advice.detachedHead=false checkout --quiet --force --detach origin/HEAD < /dev/null >&2 \
    || die "cannot check out the default branch of $url"
  (cd "$src" && "$cargo" build --release --locked --quiet < /dev/null >&2) || die "cargo build --release --locked failed"
  "$src/target/release/deck" --version >/dev/null 2>&1 < /dev/null || die "the built deck does not run"
  dest="$HOME/.local/bin/deck"
  mkdir -p "$HOME/.local/bin" || die "cannot create ~/.local/bin"
  tmp="$HOME/.local/bin/.deck.new.$$"
  if ! { cp "$src/target/release/deck" "$tmp" && chmod 0755 "$tmp"; }; then
    rm -f "$tmp"
    die "cannot stage the deck binary"
  fi
  mv -f "$tmp" "$dest" || { rm -f "$tmp"; die "cannot install deck"; }
  printf 'result=done: %s at %s\n' "$dest" "$(git -C "$src" rev-parse --short HEAD)"
}

TUNNEL_KEY_NAME=fm_workload_tunnel
TUNNEL_KNOWN_NAME=fm_workload_known_hosts

cmd_tunnel_key() { # <alias>
  local key="$HOME/.ssh/$TUNNEL_KEY_NAME"
  { mkdir -p "$HOME/.ssh" && chmod 700 "$HOME/.ssh"; } || die "cannot prepare ~/.ssh"
  if [ ! -f "$key" ]; then
    command -v ssh-keygen >/dev/null 2>&1 || die "ssh-keygen is missing"
    ssh-keygen -q -t ed25519 -N "" -C "fm-tunnel@$1" -f "$key" < /dev/null >&2 || die "ssh-keygen failed"
  fi
  [ -f "$key.pub" ] || die "$key exists without $key.pub; move it aside and rerun setup"
  printf 'pubkey=%s\n' "$(head -n 1 "$key.pub")"
}

# HTTP status from <url>, or 000 when nothing answers; extra args go to curl.
http_code() { # <url> [curl args...]
  local url=$1 code
  shift
  code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$@" "$url" < /dev/null 2>/dev/null) || true
  printf '%s\n' "${code:-000}"
}

gateway_code() { # <gateway-url>
  local key=${PROXAI_API_KEY_FILE:-$HOME/.config/proxai/client.key} code
  [ -r "$key" ] || { printf 'nokey\n'; return; }
  code=$({ printf 'header = "Authorization: Bearer '; tr -d '\r\n' < "$key"; printf '"\n'; } \
    | curl -s -o /dev/null -m 5 -w '%{http_code}' -K - "${1%/}/models" 2>/dev/null) || true
  printf '%s\n' "${code:-000}"
}

tunnel_unit() { # <kind launchd|systemd> <label> <args...>
  local kind=$1 label=$2 a
  shift 2
  if [ "$kind" = launchd ]; then
    printf '<?xml version="1.0" encoding="UTF-8"?>\n'
    printf '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
    printf '<plist version="1.0">\n<dict>\n  <key>Label</key><string>%s</string>\n  <key>ProgramArguments</key>\n  <array>\n' "$label"
    for a in "$@"; do printf '    <string>%s</string>\n' "$a"; done
    printf '  </array>\n  <key>RunAtLoad</key><true/>\n  <key>KeepAlive</key><true/>\n  <key>ThrottleInterval</key><integer>10</integer>\n</dict>\n</plist>\n'
  else
    printf '[Unit]\nDescription=Firstmate tunnel %s\nAfter=network-online.target\n\n[Service]\nExecStart=%s\nRestart=always\nRestartSec=10\n\n[Install]\nWantedBy=default.target\n' "$label" "$*"
  fi
}

cmd_install_tunnel() { # <label> <port> <user> <host> <ssh-port> <known-line> <check-url> <gateway|hub>
  local label=$1 port=$2 user=$3 host=$4 sshport=$5 known=$6 url=$7 what=$8
  local kind unit dir pin key tmp code tries account running=0
  case "$label" in dev.firstmate.*) ;; *) die "tunnel label must start with dev.firstmate." ;; esac
  case "$port:$sshport" in *[!0-9:]*|:*|*:) die "ports must be numbers" ;; esac
  command -v curl >/dev/null 2>&1 || die "curl is missing"
  key="$HOME/.ssh/$TUNNEL_KEY_NAME"
  [ -f "$key" ] || die "no tunnel key at $key; run tunnel-key first"
  # Test redirection and its limits are owned by bin/fm-test-run.sh's header.
  local unit_home=$HOME
  if [ -n "${FM_TEST_SERVICE_SANDBOX:-}" ] && [ "$HOME" = "${FM_TEST_REAL_HOME:-}" ]; then
    unit_home=$FM_TEST_SERVICE_SANDBOX
  fi
  case "$(uname -s)" in
    Darwin) kind=launchd; dir="$unit_home/Library/LaunchAgents"; unit="$dir/$label.plist" ;;
    Linux)
      kind=systemd; dir="$unit_home/.config/systemd/user"; unit="$dir/$label.service"
      account=${USER:-$(id -un)}
      [ "$(loginctl show-user "$account" -p Linger < /dev/null 2>/dev/null)" = Linger=yes ] \
        || die "run sudo loginctl enable-linger $account on the machine, then rerun setup"
      ;;
    *) die "no supported service manager on $(uname -s)" ;;
  esac
  if [ "$kind" = launchd ]; then
    launchctl print "gui/$(id -u)/$label" >/dev/null 2>&1 < /dev/null && running=1
  else
    systemctl --user is-active --quiet "$label.service" < /dev/null 2>/dev/null && running=1
  fi
  if (exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null && [ "$running" -eq 0 ]; then
    die "127.0.0.1:$port is already taken by something else; free it or forward it yourself"
  fi
  pin="$HOME/.ssh/$TUNNEL_KNOWN_NAME"
  if [ -f "$pin" ]; then
    grep -qxF -- "$known" "$pin" || die "$pin already pins a different key for the gateway host; inspect it before replacing"
  else
    (umask 077; printf '%s\n' "$known" > "$pin") || die "cannot write $pin"
  fi
  local -a args=(/usr/bin/ssh -N -i "$key" -o IdentitiesOnly=yes -o IdentityAgent=none
    -o "UserKnownHostsFile=$pin" -o StrictHostKeyChecking=yes -o BatchMode=yes
    -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3)
  [ "$sshport" = 22 ] || args+=(-p "$sshport")
  args+=(-L "127.0.0.1:$port:127.0.0.1:$port" "$user@$host")
  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-tunnel.XXXXXX") || die "cannot stage the service file"
  tunnel_unit "$kind" "$label" "${args[@]}" > "$tmp"
  if [ -f "$unit" ] && cmp -s "$tmp" "$unit" && [ "$running" -eq 1 ]; then
    rm -f "$tmp"
  else
    mkdir -p "$dir" || { rm -f "$tmp"; die "cannot create $dir"; }
    mv -f "$tmp" "$unit" || { rm -f "$tmp"; die "cannot install $unit"; }
    if [ "$kind" = launchd ]; then
      [ "$running" -eq 0 ] || launchctl bootout "gui/$(id -u)/$label" < /dev/null >/dev/null 2>&1 || true
      launchctl bootstrap "gui/$(id -u)" "$unit" < /dev/null >&2 || die "launchctl bootstrap of $label failed"
    else
      systemctl --user daemon-reload < /dev/null >&2 || die "systemctl --user daemon-reload failed"
      systemctl --user enable "$label.service" < /dev/null >&2 || die "cannot enable $label"
      systemctl --user restart "$label.service" < /dev/null >&2 || die "cannot start $label"
    fi
  fi
  tries=0
  while :; do
    if [ "$what" = gateway ]; then code=$(gateway_code "$url"); else code=$(http_code "$url"); fi
    case "$what:$code" in gateway:200|hub:[1-9]??) break ;; esac
    tries=$((tries + 1))
    [ "$tries" -lt 15 ] || break
    sleep 1
  done
  case "$what:$code" in
    gateway:200) printf 'result=done: %s forwards 127.0.0.1:%s; %s/models answers 200 with the client key\n' "$label" "$port" "${url%/}" ;;
    gateway:nokey) die "$label forwards 127.0.0.1:$port, but there is no readable gateway client key to verify it with" ;;
    hub:[1-9]??) printf 'result=done: %s forwards 127.0.0.1:%s; %s answers\n' "$label" "$port" "$url" ;;
    *) die "$label is installed but $url does not answer as expected (HTTP $code); check that the gateway host accepts the tunnel key" ;;
  esac
}

cmd_skills_prepare() {
  local dir="$HOME/$1" url=$2 branch=$3 cur
  if [ ! -e "$dir" ]; then
    if ! { mkdir -p "$(dirname "$dir")" && git init -q -b "$branch" "$dir" && git -C "$dir" remote add origin "$url"; }; then
      die "could not create a clone at $dir"
    fi
    echo 'skills-repo=created'
  elif ! git -C "$dir" rev-parse --git-dir >/dev/null 2>&1; then
    die "$dir exists and is not a git clone"
  else
    [ -z "$(git -C "$dir" status --porcelain)" ] || die "$dir has local changes"
    cur=$(git -C "$dir" symbolic-ref --short -q HEAD)
    if [ "$cur" != "$branch" ]; then
      if [ -n "$cur" ] && ! git -C "$dir" rev-parse --verify -q HEAD >/dev/null && ! git -C "$dir" show-ref --quiet; then
        git -C "$dir" symbolic-ref HEAD "refs/heads/$branch" || exit 3
      else
        die "$dir is on ${cur:-a detached HEAD}, not $branch"
      fi
    fi
    echo 'skills-repo=present'
  fi
}

cmd_skills_import() {
  local dir="$HOME/$1" branch=$2 commit=$3
  git -C "$dir" unpack-objects -q || die 'could not receive skills objects'
  git -C "$dir" update-ref "refs/remotes/origin/$branch" "$commit" || die 'could not record skills commit'
}

cmd_skills_finish() {
  local dir="$HOME/$1" branch=$2 commit=$3 install=$4
  cd "$dir" || exit 3
  if git rev-parse --verify -q HEAD >/dev/null; then
    git merge --ff-only --no-overwrite-ignore -q "$commit" >/dev/null 2>&1 || die "$dir cannot safely fast-forward to $commit"
  else
    git checkout --no-overwrite-ignore -q -b "$branch" "$commit" >/dev/null 2>&1 || die "$dir cannot safely check out $commit"
    git branch -q --set-upstream-to="origin/$branch" >/dev/null 2>&1
  fi
  [ "$(git rev-parse HEAD)" = "$commit" ] || die "$dir is not at $commit after the update"
  mkdir -p "$HOME/.cache"
  sh -c "$install" < /dev/null > "$HOME/.cache/fm-shared-skills.log" 2>&1 || die "$install failed in $dir (log: ~/.cache/fm-shared-skills.log)"
  echo "linked=$(find "$HOME/.agents/skills" -maxdepth 1 -type l 2>/dev/null | wc -l | tr -d ' ')"
}

main() {
  [ "$#" -ge 1 ] || { echo "usage: fm-machine-remote.sh probe|install-tool|install-deck|install-approval-gate|tunnel-key|install-tunnel ..." >&2; exit 2; }
  local sub=$1
  shift
  case "$sub" in
    probe) [ "$#" -ge 3 ] || exit 2; cmd_probe "$@" ;;
    install-tool) [ "$#" -eq 2 ] || exit 2; cmd_install_tool "$@" ;;
    install-deck) [ "$#" -eq 2 ] || exit 2; cmd_install_deck "$@" ;;
    skills-prepare) [ "$#" -eq 3 ] || exit 2; cmd_skills_prepare "$@" ;;
    skills-import) [ "$#" -eq 3 ] || exit 2; cmd_skills_import "$@" ;;
    skills-finish) [ "$#" -eq 4 ] || exit 2; cmd_skills_finish "$@" ;;
    install-approval-gate) [ "$#" -eq 1 ] || exit 2; cmd_install_approval_gate "$@" ;;
    tunnel-key) [ "$#" -eq 1 ] || exit 2; cmd_tunnel_key "$@" ;;
    install-tunnel) [ "$#" -eq 8 ] || exit 2; cmd_install_tunnel "$@" ;;
    *) exit 2 ;;
  esac
}

main "$@" 2>&1 | fm_machine_redact_urls
exit "${PIPESTATUS[0]}"
