#!/usr/bin/env bash
# The machine-side half of bin/fm-machine.sh: facts and narrow installs that run
# as the remote account itself.
#
# Usage (bin/fm-machine.sh sends the tools and output libraries followed by this file
# as the script of `ssh <alias> bash -s -- ...`; run directly, it sources those
# libraries from beside itself):
#   fm-machine-remote.sh probe <remote-root> <gateway-url> <hub-url|-> <tool>...
#   fm-machine-remote.sh install-tool <tool> <remote-root>
#   fm-machine-remote.sh install-deck <remote-root> <deck-repo-url>
#
# It needs no Firstmate checkout on the machine, so it works before prepare.
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

main() {
  [ "$#" -ge 1 ] || { echo "usage: fm-machine-remote.sh probe|install-tool|install-deck ..." >&2; exit 2; }
  local sub=$1
  shift
  case "$sub" in
    probe) [ "$#" -ge 3 ] || exit 2; cmd_probe "$@" ;;
    install-tool) [ "$#" -eq 2 ] || exit 2; cmd_install_tool "$@" ;;
    install-deck) [ "$#" -eq 2 ] || exit 2; cmd_install_deck "$@" ;;
    *) exit 2 ;;
  esac
}

main "$@" 2>&1 | fm_machine_redact_urls
exit "${PIPESTATUS[0]}"
