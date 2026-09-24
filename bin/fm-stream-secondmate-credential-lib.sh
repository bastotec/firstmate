# shellcheck shell=bash
# Single owner of stream hub credential seeding for a freshly provisioned
# secondmate home: mint one fresh random token per home, append the narrow
# class line that home needs to the hub host's config/stream-hub-tokens, and
# deliver the token into the mate home's own config/stream-token.
#
# The decision this implements (recorded in the ruling this task was briefed
# from): a stream-hosted second mate runs a firstmate of its own, so its home
# needs the same client credential shape any home has - publish, subscribe, and
# control - but the credential is MINTED FOR THAT HOME, never copied from the
# primary. A shared credential would make every mate's traffic
# indistinguishable from the primary's and make revoking one mate's access
# impossible without cutting the whole fleet off.
#
# LIMIT this library deliberately does not hide: the hub reads its token file
# exactly once, at serve start (bin/fm-stream-hub.py load_tokens - no SIGHUP,
# no reload subcommand). A seeded mate token is therefore INACTIVE until the
# hub restarts, and a hub restart clears terminal scrollback and Bridge-order
# reconciliation fleet-wide, so it is a planned quiet-boundary operation rather
# than part of seeding. docs/stream-backend.md owns that contract; making the
# hub reloadable is separate work and deliberately out of scope here.
#
# Usage: . bin/fm-stream-secondmate-credential-lib.sh   (no setup required)
# Requires the lock primitives from bin/fm-wake-lib.sh; callers that source
# this through bin/fm-home-seed.sh get them from its own sourcing chain.
# shellcheck source=bin/fm-wake-lib.sh
#
# Seeding is transactional from the caller's side: seed_stream_secondmate_token
# performs the mate-home write first and the hub-file append second, and
# rollback_stream_secondmate_token undoes both in reverse when the caller's own
# transaction fails (bin/fm-home-seed.sh). The primary's config/stream-token
# and config/stream-hub-tokens are only ever READ here, never written.

FM_STREAM_MATE_CLASSES='publish,subscribe,control'

fm_stream_mate_credential_lock_path() {  # <state-dir>
  printf '%s/.stream-hub-tokens.lock\n' "$1"
}

fm_stream_mate_mint_token() {
  python3 -c 'import secrets; print(secrets.token_urlsafe(32))'
}

# The hub token file path for the home this process runs in. $CONFIG resolves
# to the active home's config dir in every caller (fm-home-seed.sh sets it the
# same way bin/fm-stream.sh does); FM_CONFIG_OVERRIDE wins, so tests aim
# seeding at a scratch home without touching a real one.
fm_stream_mate_hub_tokens_path() {
  printf '%s/stream-hub-tokens\n' "${FM_CONFIG_OVERRIDE:-${CONFIG:?CONFIG must name the seeding home config dir}}"
}

fm_stream_mate_token_path() {  # <mate-home>
  printf '%s/config/stream-token\n' "$1"
}

fm_stream_mate_class_line() {  # <token>
  printf '%s:%s\n' "$FM_STREAM_MATE_CLASSES" "$1"
}

# Append "publish,subscribe,control:<token>" to the hub host's token file,
# creating it 0600 when absent. The class line is built by the single owner
# above and written through printf into a plain redirect, never handed to an
# external command, so no minted value reaches a process listing. An existing
# file's bytes and mode are left untouched.
fm_stream_mate_append_hub_class_line() {  # <token> <hub-tokens-path>
  local token=$1 path=$2 line
  [ -n "$token" ] || { echo "error: refusing to append an empty stream mate token" >&2; return 1; }
  [ ! -L "$path" ] || { echo "error: stream hub token file $path is a symlink; refusing to write through it" >&2; return 1; }
  if [ -e "$path" ] && [ ! -f "$path" ]; then
    echo "error: stream hub token file $path exists and is not a regular file" >&2
    return 1
  fi
  line=$(fm_stream_mate_class_line "$token")
  if [ -f "$path" ]; then
    # Idempotent on the exact class line: a re-seed that mints the same token
    # (it cannot, but a restored backup can) appends one line, not two.
    if grep -Fqx -- "$line" "$path"; then
      return 0
    fi
    # No blank separator line: the token parser skips empties, but a trailing
    # blank per seed would accumulate and make the file's shape drift from
    # every hand-maintained line in it.
    printf '%s\n' "$line" >> "$path"
  else
    (umask 077 && printf '%s\n' "$line" > "$path")
  fi
}

fm_stream_mate_write_home_token() {  # <token> <mate-home>
  local token=$1 home=$2 path
  [ -n "$token" ] || { echo "error: refusing to write an empty stream mate token" >&2; return 1; }
  path=$(fm_stream_mate_token_path "$home")
  [ ! -L "$path" ] || { echo "error: mate stream token path $path is a symlink; refusing to write through it" >&2; return 1; }
  [ ! -d "$path" ] || { echo "error: mate stream token path $path exists and is not a regular file" >&2; return 1; }
  (umask 077 && printf '%s\n' "$token" > "$path.tmp.$$")
  mv -f -- "$path.tmp.$$" "$path"
}

seed_stream_secondmate_token() {  # <id> <mate-home> <state-dir>
  local id=$1 home=$2 state_dir=$3 hub_tokens lock token
  [ -n "$id" ] || { echo "error: stream mate credential seeding needs a secondmate id" >&2; return 1; }
  [ -n "$home" ] || { echo "error: stream mate credential seeding needs a mate home path" >&2; return 1; }
  [ -n "$state_dir" ] || { echo "error: stream mate credential seeding needs a state dir" >&2; return 1; }
  command -v python3 >/dev/null 2>&1 || {
    echo "error: python3 is required to mint a stream mate credential" >&2
    return 1
  }
  hub_tokens=$(fm_stream_mate_hub_tokens_path)
  mkdir -p "$state_dir" "$home/config" || return 1
  lock=$(fm_stream_mate_credential_lock_path "$state_dir")
  fm_lock_acquire_wait "$lock" || {
    echo "error: could not lock stream hub token file $hub_tokens for seeding" >&2
    return 1
  }
  FM_STREAM_MATE_LOCK_HELD=1
  # The primary's own credential is never a source: nothing here reads
  # config/stream-token of the seeding home, so a mate token cannot arrive as
  # a copy of it even by accident of a later edit.
  token=$(fm_stream_mate_mint_token) || {
    echo "error: could not mint a stream hub token for secondmate $id" >&2
    return 1
  }
  [ -n "$token" ] || { echo "error: minting a stream hub token for secondmate $id produced nothing" >&2; return 1; }
  fm_stream_mate_write_home_token "$token" "$home" || return 1
  fm_stream_mate_append_hub_class_line "$token" "$hub_tokens" || return 1
}

# Commit side of the transactional pair: releases the credential lock taken by
# seed_stream_secondmate_token without undoing anything. Called by
# bin/fm-home-seed.sh only after the whole seed has committed, because the EXIT
# trap that would otherwise release the lock is disarmed there.
commit_stream_secondmate_token() {  # <state-dir>
  if [ "${FM_STREAM_MATE_LOCK_HELD:-0}" = 1 ]; then
    FM_STREAM_MATE_LOCK_HELD=0
    fm_lock_release "$(fm_stream_mate_credential_lock_path "$1")" 2>/dev/null || true
  fi
  return 0
}

rollback_stream_secondmate_token() {  # <mate-home> <state-dir>
  local home=$1 state_dir=$2 hub_tokens token lock line
  [ "${FM_STREAM_MATE_LOCK_HELD:-0}" = 1 ] || return 0
  FM_STREAM_MATE_LOCK_HELD=0
  lock=$(fm_stream_mate_credential_lock_path "$state_dir")
  hub_tokens=$(fm_stream_mate_hub_tokens_path)
  token=$(cat "$(fm_stream_mate_token_path "$home")" 2>/dev/null || true)
  line="$FM_STREAM_MATE_CLASSES:$token"
  if [ -n "$token" ]; then
    if [ -f "$hub_tokens" ] && grep -Fqx -- "$line" "$hub_tokens"; then
      grep -Fvx -- "$line" "$hub_tokens" > "$hub_tokens.tmp.$$" 2>/dev/null \
        && mv -f -- "$hub_tokens.tmp.$$" "$hub_tokens" \
        || rm -f -- "$hub_tokens.tmp.$$" 2>/dev/null || true
    fi
    rm -f -- "$(fm_stream_mate_token_path "$home")" 2>/dev/null || true
  fi
  fm_lock_release "$lock" 2>/dev/null || true
  return 0
}
