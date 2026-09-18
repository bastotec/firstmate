#!/usr/bin/env bash
# Drives the real seed, bootstrap, sync and remote-provision entry points in a
# throwaway sandbox. Usage: drive-home-route.sh <worktree>
set -u
SRC=$1
BASE=554740650f5edf94a22ced3761354ad73ac68311
FORK=https://github.com/bastotec/firstmate.git
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-route-drive.XXXXXX")
S=$(cd "$S" && pwd -P)
export GIT_TERMINAL_PROMPT=0 GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export TMUX_TMPDIR="$S/tmux"; mkdir -p "$TMUX_TMPDIR"
say() { printf '\n=== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; printf '[exit %s]\n' "$?"; }
parent() { mkdir -p "$1/projects" "$1/data" "$1/state"; }
seed_env() { env FM_HOME="$1" FM_SECONDMATE_CHARTER='firstmate self-development' FM_SECONDMATE_SCOPE='firstmate repo work' "${@:2}"; }

say "S0 baseline: seed a standalone home with the OLD script (base $BASE)"
git clone -q "$SRC" "$S/base-root" && git -C "$S/base-root" checkout -q "$BASE"
git -C "$S/base-root" remote set-url origin "$FORK"
parent "$S/parent0"
run seed_env "$S/parent0" "$S/base-root/bin/fm-home-seed.sh" fdev "$S/homes/old" --no-projects
echo "old home origin: $(git -C "$S/homes/old" remote get-url origin)"

say "S1 new seed from a code root whose origin is the fork"
git clone -q "$SRC" "$S/fmroot" && git -C "$S/fmroot" remote set-url origin "$FORK"
echo "code root HEAD: $(git -C "$S/fmroot" log --oneline -1)"
parent "$S/parent1"
run seed_env "$S/parent1" "$S/fmroot/bin/fm-home-seed.sh" fdev "$S/homes/new" --no-projects
echo "new home origin: $(git -C "$S/homes/new" remote get-url origin)"
echo "new home remotes: $(git -C "$S/homes/new" remote | tr '\n' ' ')"
echo "code root origin after seed: $(git -C "$S/fmroot" remote get-url origin)"

say "S2 adversarial: code root whose origin is a local path"
git clone -q "$SRC" "$S/pathroot"
echo "code root origin: $(git -C "$S/pathroot" remote get-url origin)"
parent "$S/parent2"
run seed_env "$S/parent2" "$S/pathroot/bin/fm-home-seed.sh" fdev "$S/homes/path" --no-projects
[ -e "$S/homes/path" ] && echo "home dir LEFT BEHIND" || echo "home dir not created"
grep -F -- '- fdev ' "$S/parent2/data/secondmates.md" 2>/dev/null && echo "REGISTERED" || echo "not registered"

say "S3 adversarial: code root whose origin is a file:// URL"
git -C "$S/pathroot" remote set-url origin "file://$S/fmroot"
run seed_env "$S/parent2" "$S/pathroot/bin/fm-home-seed.sh" fdev "$S/homes/fileurl" --no-projects
[ -e "$S/homes/fileurl" ] && echo "home dir LEFT BEHIND" || echo "home dir not created"

boot() { env FM_HOME="$1" FM_ROOT_OVERRIDE="$1" FM_BACKEND=tmux FM_BOOTSTRAP_DETECT_ONLY=1 "$S/fmroot/bin/fm-bootstrap.sh" 2>&1 | grep -E 'HOME_ROUTE' || echo "(no HOME_ROUTE line)"; }

say "S4 session start on the already-seeded OLD home (origin is a path)"
boot "$S/homes/old"

say "S5 old home: origin repointed at the fork, but its no-mistakes gate still saved the path"
git init -q --bare "$S/gate.git"
git -C "$S/gate.git" remote add origin "$S/base-root"
git -C "$S/homes/old" remote add no-mistakes "$S/gate.git"
git -C "$S/homes/old" remote set-url origin "$FORK"
boot "$S/homes/old"
echo "gate origin after session start: $(git -C "$S/gate.git" remote get-url origin)"
say "S5b reseeding that home with the new script is refused, not blessed"
run seed_env "$S/parent0" "$S/fmroot/bin/fm-home-seed.sh" fdev "$S/homes/old" --no-projects
echo "old home origin after refused reseed: $(git -C "$S/homes/old" remote get-url origin)"
echo "gate origin after refused reseed: $(git -C "$S/gate.git" remote get-url origin)"
say "S5c gate refreshed to the fork -> the line clears"
git -C "$S/gate.git" remote set-url origin "$FORK"
boot "$S/homes/old"

say "S6 session start on the NEW seeded home"
boot "$S/homes/new"

say "S7 parent sync imports a code-root commit the fork has never seen, into the new home"
git -C "$S/fmroot" commit -q --allow-empty -m 'local-only commit the fork never saw'
SHA=$(git -C "$S/fmroot" rev-parse HEAD)
git -C "$S/homes/new" cat-file -e "$SHA^{commit}" 2>/dev/null && echo "home already had it" || echo "home does not have $SHA yet"
run env FM_HOME="$S/homes/new" FM_ROOT_OVERRIDE="$S/fmroot" "$S/fmroot/bin/fm-remote-secondmate-control.sh" sync fdev "$SHA"
echo "home HEAD after sync: $(git -C "$S/homes/new" rev-parse HEAD)"
echo "home origin after sync: $(git -C "$S/homes/new" remote get-url origin)"

manifest() { printf 'schema=fm-remote-home-provision.v1\nid_b64=%s\ncharter_b64=%s\nproject_count=0\n' "$(printf rdev | base64)" "$(printf 'remote firstmate dev' | base64)"; }
say "S8 remote host provisions a home from its own Firstmate copy (origin = fork)"
mkdir -p "$S/rhost"
git clone -q "$SRC" "$S/rhost/copy" && git -C "$S/rhost/copy" remote set-url origin "$FORK"
manifest | run env FM_HOME="$S/rhost/home" FM_ROOT_OVERRIDE="$S/rhost/copy" "$S/rhost/copy/bin/fm-remote-home-provision.sh"
echo "remote home origin: $(git -C "$S/rhost/home" remote get-url origin 2>&1)"
say "S8b remote host copy whose origin is a path refuses to provision"
git -C "$S/rhost/copy" remote set-url origin "$SRC"
manifest | run env FM_HOME="$S/rhost/home2" FM_ROOT_OVERRIDE="$S/rhost/copy" "$S/rhost/copy/bin/fm-remote-home-provision.sh"
[ -e "$S/rhost/home2" ] && echo "remote home LEFT BEHIND" || echo "remote home not created"

rm -rf "$S"
