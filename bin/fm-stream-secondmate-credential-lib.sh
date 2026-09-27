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
# transaction fails (bin/fm-home-seed.sh). A re-seed of a home that already
# holds a credential captures that token and its class line before minting, so
# a failed re-seed puts the home back on the credential it had and a committed
# one retires the line the superseded token leaves behind. The primary's own
# config/stream-token is never read or written here, so a mate token cannot
# arrive as a copy of it.

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

# Whole-line membership and line removal stay in shell on purpose: the class
# line carries the minted token, and an external grep would take it as argv,
# briefly putting a live credential in every local process listing.
fm_stream_mate_hub_file_has_line() {  # <line> <path>
  local line=$1 path=$2 existing
  while IFS= read -r existing || [ -n "$existing" ]; do
    if [ "$existing" = "$line" ]; then
      return 0
    fi
  done < "$path"
  return 1
}

# Rewrite <path> without <line> under umask 077 and move the result into
# place, so removing a line can never widen the fleet's secrets file away
# from the 0600 mode it is created with.
fm_stream_mate_remove_hub_line() {  # <line> <path>
  local line=$1 path=$2 tmp existing
  tmp="$path.tmp.$$"
  if (
    umask 077
    while IFS= read -r existing || [ -n "$existing" ]; do
      [ "$existing" = "$line" ] || printf '%s\n' "$existing"
    done < "$path" > "$tmp"
  ); then
    mv -f -- "$tmp" "$path"
  else
    rm -f -- "$tmp" 2>/dev/null || true
    return 1
  fi
}

# Append "publish,subscribe,control:<token>" to the hub host's token file,
# creating it 0600 when absent. The class line never reaches an external
# command - not even as a grep argv - so no minted value appears in a process
# listing. An existing file's mode is left untouched; its bytes are left alone
# except that a missing trailing newline is completed first, because the file
# is hand-maintained (docs/stream-backend.md) and appending onto an
# unterminated last line would splice the class line onto the operator's own.
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
    if fm_stream_mate_hub_file_has_line "$line" "$path"; then
      return 0
    fi
    if [ -s "$path" ] && [ -n "$(tail -c 1 "$path" 2>/dev/null)" ]; then
      printf '\n' >> "$path"
    fi
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
  local id=$1 home=$2 state_dir=$3 hub_tokens lock token mate_token prior_line new_line
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
  FM_STREAM_MATE_MINTED_TOKEN=
  FM_STREAM_MATE_PRIOR_TOKEN=
  FM_STREAM_MATE_PRIOR_TOKEN_EXISTED=0
  FM_STREAM_MATE_PRIOR_LINE_EXISTED=0
  mate_token=$(fm_stream_mate_token_path "$home")
  if [ -f "$mate_token" ] && [ ! -L "$mate_token" ]; then
    FM_STREAM_MATE_PRIOR_TOKEN_EXISTED=1
    FM_STREAM_MATE_PRIOR_TOKEN=$(cat "$mate_token" 2>/dev/null || true)
    if [ -n "$FM_STREAM_MATE_PRIOR_TOKEN" ]; then
      prior_line=$(fm_stream_mate_class_line "$FM_STREAM_MATE_PRIOR_TOKEN")
      if [ -f "$hub_tokens" ] && fm_stream_mate_hub_file_has_line "$prior_line" "$hub_tokens"; then
        FM_STREAM_MATE_PRIOR_LINE_EXISTED=1
      fi
    fi
  fi
  # The primary's own credential is never a source: nothing here reads
  # config/stream-token of the seeding home, so a mate token cannot arrive as
  # a copy of it even by accident of a later edit.
  token=$(fm_stream_mate_mint_token) || {
    echo "error: could not mint a stream hub token for secondmate $id" >&2
    return 1
  }
  [ -n "$token" ] || { echo "error: minting a stream hub token for secondmate $id produced nothing" >&2; return 1; }
  FM_STREAM_MATE_MINTED_TOKEN=$token
  fm_stream_mate_write_home_token "$token" "$home" || return 1
  fm_stream_mate_append_hub_class_line "$token" "$hub_tokens" || return 1
  if [ -n "$FM_STREAM_MATE_PRIOR_TOKEN" ] && [ "$FM_STREAM_MATE_PRIOR_LINE_EXISTED" = 1 ]; then
    prior_line=$(fm_stream_mate_class_line "$FM_STREAM_MATE_PRIOR_TOKEN")
    new_line=$(fm_stream_mate_class_line "$token")
    if [ "$prior_line" != "$new_line" ]; then
      fm_stream_mate_remove_hub_line "$prior_line" "$hub_tokens" || return 1
    fi
  fi
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
  FM_STREAM_MATE_MINTED_TOKEN=
  FM_STREAM_MATE_PRIOR_TOKEN=
  return 0
}

rollback_stream_secondmate_token() {  # <mate-home> <state-dir>
  local home=$1 state_dir=$2 hub_tokens token lock line mate_token
  [ "${FM_STREAM_MATE_LOCK_HELD:-0}" = 1 ] || return 0
  FM_STREAM_MATE_LOCK_HELD=0
  lock=$(fm_stream_mate_credential_lock_path "$state_dir")
  hub_tokens=$(fm_stream_mate_hub_tokens_path)
  mate_token=$(fm_stream_mate_token_path "$home")
  token=${FM_STREAM_MATE_MINTED_TOKEN:-}
  FM_STREAM_MATE_MINTED_TOKEN=
  if [ -n "$token" ]; then
    line=$(fm_stream_mate_class_line "$token")
    if [ -f "$hub_tokens" ] && fm_stream_mate_hub_file_has_line "$line" "$hub_tokens"; then
      fm_stream_mate_remove_hub_line "$line" "$hub_tokens" 2>/dev/null || true
    fi
    if [ "${FM_STREAM_MATE_PRIOR_TOKEN_EXISTED:-0}" = 1 ]; then
      # A re-seed that fails rolls the home back onto the credential it held
      # before the mint, and its class line goes back with it.
      if [ -n "${FM_STREAM_MATE_PRIOR_TOKEN:-}" ]; then
        fm_stream_mate_write_home_token "$FM_STREAM_MATE_PRIOR_TOKEN" "$home" 2>/dev/null || true
        if [ "${FM_STREAM_MATE_PRIOR_LINE_EXISTED:-0}" = 1 ]; then
          fm_stream_mate_append_hub_class_line "$FM_STREAM_MATE_PRIOR_TOKEN" "$hub_tokens" 2>/dev/null || true
        fi
      else
        rm -f -- "$mate_token" 2>/dev/null || true
      fi
    else
      rm -f -- "$mate_token" 2>/dev/null || true
    fi
  fi
  FM_STREAM_MATE_PRIOR_TOKEN=
  fm_lock_release "$lock" 2>/dev/null || true
  return 0
}
