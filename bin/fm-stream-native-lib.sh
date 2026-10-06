#!/usr/bin/env bash
# bin/fm-stream-native-lib.sh - which stream implementation runs, and where its
# native (Rust) binaries live. Sourced by bin/backends/stream.sh; the operator
# commands are `bin/fm-stream.sh native build|ensure|status|path`.
#
# Implementation selection: FM_STREAM_IMPL, then config/stream-impl, then
# "rust". "python" is the explicit rollback to bin/fm-stream-hub.py and
# bin/fm-stream-agent.py. Nothing falls back from one to the other on its own:
# a rust home without built binaries refuses with the fix.
#
# Binary location:
#   1. FM_STREAM_NATIVE_DIR, then config/stream-native-dir: a prebuilt directory
#      holding fm-stream-hub, fm-stream-agent and fm-stream-bridge, used as is.
#      This is how a host without cargo is fed binaries built elsewhere.
#   2. Otherwise the per-user build cache
#      ${FM_STREAM_NATIVE_CACHE:-${XDG_DATA_HOME:-$HOME/.local/share}/firstmate/stream-native}/<source-key>/
#      where <source-key> hashes the working-tree content of crates/,
#      Cargo.toml and Cargo.lock. Every home on the same sources (the primary
#      and its local secondmate worktrees) shares one build, and a home whose
#      crates changed resolves a different, not-yet-built directory instead of
#      silently running stale binaries.

FM_STREAM_NATIVE_BINARIES="fm-stream-hub fm-stream-agent fm-stream-bridge"

# The checkout whose crates/ are built: the one this library ships in, which is
# the code that will run the binaries.
fm_stream_native_root() {
  (cd "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
}

fm_stream_native_config_line() {  # <config-file-name>
  local file line
  file="${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT:-$(fm_stream_native_root)}}/config}/$1"
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|\#*) continue ;;
    esac
    printf '%s' "$line"
    return 0
  done < "$file"
  return 1
}

# fm_stream_impl: print rust or python; refuse anything else.
fm_stream_impl() {
  local impl
  if [ -n "${FM_STREAM_IMPL:-}" ]; then
    impl=$FM_STREAM_IMPL
  elif impl=$(fm_stream_native_config_line stream-impl); then
    :
  else
    impl=rust
  fi
  case "$impl" in
    rust|python) printf '%s' "$impl" ;;
    *)
      echo "error: unknown stream implementation '$impl' (FM_STREAM_IMPL or config/stream-impl); use rust or python" >&2
      return 1
      ;;
  esac
}

fm_stream_native_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -c1-16
  else
    shasum -a 256 | cut -c1-16
  fi
}

# fm_stream_native_source_key: hash existing tracked and non-ignored untracked
# crate inputs as they are on disk, skipping deleted paths. Refuse hashing
# failures rather than resolving an install with a partial source key.
fm_stream_native_source_key() {
  local root hashes path object
  root=$(fm_stream_native_root) || return 1
  hashes=$(
    set -o pipefail
    cd "$root" || exit 1
    git ls-files --cached --others --exclude-standard -z -- crates Cargo.toml Cargo.lock |
      while IFS= read -r -d '' path; do
        [ -e "$path" ] || continue
        object=$(git hash-object -- "$path") || exit 1
        printf '%s %q\n' "$object" "$path"
      done
  ) || return 1
  [ -n "$hashes" ] || {
    echo "error: $root has no crate sources; a home that is not a git checkout needs config/stream-native-dir pointing at prebuilt binaries" >&2
    return 1
  }
  (set -o pipefail; printf '%s\n' "$hashes" | fm_stream_native_sha)
}

fm_stream_native_cache() {
  printf '%s' "${FM_STREAM_NATIVE_CACHE:-${XDG_DATA_HOME:-$HOME/.local/share}/firstmate/stream-native}"
}

# fm_stream_native_prebuilt: print the configured prebuilt directory, if any.
fm_stream_native_prebuilt() {
  if [ -n "${FM_STREAM_NATIVE_DIR:-}" ]; then
    printf '%s' "$FM_STREAM_NATIVE_DIR"
  else
    fm_stream_native_config_line stream-native-dir
  fi
}

# fm_stream_native_dir: the directory this home's native binaries resolve to,
# whether or not they exist yet.
fm_stream_native_dir() {
  local dir key
  if dir=$(fm_stream_native_prebuilt); then
    printf '%s' "$dir"
    return 0
  fi
  key=$(fm_stream_native_source_key) || return 1
  printf '%s/%s' "$(fm_stream_native_cache)" "$key"
}

# fm_stream_native_bin <name>: print the path of one native binary, or refuse
# with the command that fixes it.
fm_stream_native_bin() {  # <fm-stream-hub|fm-stream-agent|fm-stream-bridge>
  local dir
  dir=$(fm_stream_native_dir) || return 1
  if [ -x "$dir/$1" ]; then
    printf '%s' "$dir/$1"
    return 0
  fi
  if fm_stream_native_prebuilt >/dev/null; then
    echo "error: the prebuilt stream directory $dir has no executable $1 (FM_STREAM_NATIVE_DIR or config/stream-native-dir)" >&2
  else
    echo "error: the Rust stream binaries for this checkout are not built ($dir/$1 is missing); run bin/fm-stream.sh native build, or roll back with: echo python > config/stream-impl" >&2
  fi
  return 1
}

fm_stream_native_cargo() {
  if command -v cargo >/dev/null 2>&1; then
    command -v cargo
  elif [ -x "$HOME/.cargo/bin/cargo" ]; then
    printf '%s' "$HOME/.cargo/bin/cargo"
  else
    return 1
  fi
}

fm_stream_native_installed() {  # <dir>
  local name
  for name in $FM_STREAM_NATIVE_BINARIES; do
    [ -x "$1/$name" ] || return 1
  done
  [ -f "$1/stamp" ]
}

# fm_stream_native_build [--if-stale]: cargo build --release --locked the three
# binaries and install them, stamped, into the cache directory for the current
# source key. With --if-stale an existing install for this key is left alone.
# Prints one result line: built <dir> | current <dir> | prebuilt <dir>.
fm_stream_native_build() {
  local if_stale=0 root dir key cargo cache tmp lock name commit target
  [ "${1:-}" = "--if-stale" ] && if_stale=1
  if dir=$(fm_stream_native_prebuilt); then
    echo "prebuilt $dir"
    return 0
  fi
  root=$(fm_stream_native_root) || return 1
  target=${CARGO_TARGET_DIR:-$root/target}
  case "$target" in
    /*) ;;
    *) target="$root/$target" ;;
  esac
  key=$(fm_stream_native_source_key) || return 1
  cache=$(fm_stream_native_cache)
  dir="$cache/$key"
  if [ "$if_stale" -eq 1 ] && fm_stream_native_installed "$dir"; then
    echo "current $dir"
    return 0
  fi
  cargo=$(fm_stream_native_cargo) || {
    echo "error: cargo is not installed, so the Rust stream binaries cannot be built here. Install Rust into ~/.cargo with: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --profile minimal - or build them on another host of the same OS and CPU and point config/stream-native-dir at that directory" >&2
    return 1
  }
  mkdir -p "$cache" || return 1
  lock="$cache/.build-$key.lock"
  if ! mkdir "$lock" 2>/dev/null; then
    echo "error: another build of $key holds $lock; wait for it, or remove the directory if no build is running" >&2
    return 1
  fi
  tmp="$cache/.install-$key.$$"
  rm -rf "$tmp"
  local -a packages=()
  for name in $FM_STREAM_NATIVE_BINARIES; do
    packages+=(-p "$name")
  done
  touch "$lock" || { rmdir "$lock"; return 1; }
  if ! (cd "$root" && unset CARGO_BUILD_TARGET && CARGO_TARGET_DIR="$target" "$cargo" build --release --locked "${packages[@]}") >&2; then
    rmdir "$lock"
    echo "error: cargo build failed for the stream binaries; nothing was installed" >&2
    return 1
  fi
  for name in $FM_STREAM_NATIVE_BINARIES; do
    if [ ! -f "$target/release/$name" ] || [ -z "$(find "$target/release/$name" -newer "$lock" -print)" ]; then
      rmdir "$lock"
      echo "error: $target/release/$name was not refreshed by this build; check Cargo build.target configuration; nothing was installed" >&2
      return 1
    fi
  done
  mkdir -p "$tmp"
  for name in $FM_STREAM_NATIVE_BINARIES; do
    cp "$target/release/$name" "$tmp/$name" || { rm -rf "$tmp"; rmdir "$lock"; return 1; }
    chmod 755 "$tmp/$name"
  done
  commit=$(cd "$root" && git rev-parse HEAD 2>/dev/null) || commit=unknown
  printf 'source=%s\ncommit=%s\nbuilt_at=%s\n' "$key" "$commit" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp/stamp"
  rm -rf "$dir.old"
  [ -d "$dir" ] && mv "$dir" "$dir.old"
  mv "$tmp" "$dir"
  rm -rf "$dir.old"
  rmdir "$lock"
  echo "built $dir"
}
