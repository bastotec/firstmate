# shellcheck shell=bash
# Single owner of a firstmate home's DELIVERY ROUTE: the remote a validated
# change to the firstmate repo ITSELF is pushed to and opens its pull request on.
# Usage: . bin/fm-home-route-lib.sh
#
# A home seeded as a standalone clone of the local code root inherits that
# host path as its `origin`, and the validation pipeline registers whatever
# `origin` holds when the home first initializes it. Such a home pushes a
# finished firstmate change into a directory on its own host and never opens a
# pull request: nothing errors, nothing is lost, and the absent PR is the only
# symptom. bin/fm-home-seed.sh gates that at seed time, and bin/fm-bootstrap.sh
# reports it for homes seeded before that gate existed.
#
# What this rejects is a BARE filesystem path, because that is the signature of
# the accident: `git clone <path>` records the path it cloned from, so a home
# ends up delivering to its own code root without anyone having chosen that. A
# `file://` URL is never produced that way - it is always configured on purpose,
# by a local mirror, an air-gapped setup, or a test forge - so it is a route
# here, and a remote-helper transport is refused as a transport rather than a
# forge. Reaching the LOCAL code root is a separate concern with its own remote
# name below, so a home can keep both and `origin` always means the fork.
#
# This file classifies a route; it never rewrites one. bin/fm-project-origin-lib.sh
# stays the owner of which clone URLs are safe to hand between hosts, a different
# question - a local path is an accepted clone URL there and never a route here.

# The remote name a seeded standalone home keeps its host's firstmate code root
# under, so that copy stays reachable by name once `origin` is the fork.
# shellcheck disable=SC2034 # Read by the sourcing caller.
FM_HOME_ROUTE_CODE_ROOT_REMOTE=code-root

# 0 when <url> names a route this home can deliver a pull request through.
fm_home_route_is_remote() { # <url>
  case ${1-} in
    '' | -*) return 1 ;;
    *[[:space:]]* | *[[:cntrl:]]*) return 1 ;;
    file://?*) return 0 ;;
    /* | ./* | ../*) return 1 ;;
    https://?* | http://?* | ssh://?* | git://?*) return 0 ;;
    *://*) return 1 ;;
    # A remote helper such as "ext::<command>" is a transport, not a forge.
    *::*) return 1 ;;
    # scp-like [user@]host:path.
    *:*) return 0 ;;
    *) return 1 ;;
  esac
}

# Echo the delivery route of the firstmate checkout at <dir>, or nothing.
fm_home_route_url() { # <dir>
  git -C "$1" remote get-url origin 2>/dev/null || true
}

# Echo why the checkout at <dir> would deliver a firstmate change to the wrong
# place and return 0; print nothing and return 1 when it would not. The caller
# decides whether that is a refusal (seeding) or a report (session start).
#
# Scoped to the SILENT failure: an origin that is a bare path this checkout was
# cloned from. A checkout with no origin, or none at all, cannot push anywhere
# and says so at the push, so it is not this check's business.
fm_home_route_misdirected() { # <dir>
  local dir=$1 url
  git -C "$dir" rev-parse --is-inside-work-tree >/dev/null 2>&1 || return 1
  url=$(fm_home_route_url "$dir")
  [ -n "$url" ] || return 1
  fm_home_route_is_remote "$url" && return 1
  printf 'its origin is the path %s rather than a route it can open a pull request through\n' "$url"
}

# 0 when <dir> has its own object store, as opposed to a linked worktree that
# shares a code root's git directory - and with it that code root's own remotes,
# which a home must never rewrite through.
fm_home_route_standalone_repo() { # <dir>
  local dir=$1 git_dir common_dir
  git_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-dir 2>/dev/null) || return 1
  common_dir=$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null) || return 1
  [ "$git_dir" = "$common_dir" ]
}
