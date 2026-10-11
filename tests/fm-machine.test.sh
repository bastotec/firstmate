#!/usr/bin/env bash
# Behavior tests for bin/fm-machine.sh: check classification and checklist, add
# and trust refusals, prepare and setup composition, and register idempotence.
# ssh, ssh-keyscan and ssh-keygen are stubs on PATH, and FM_SSH_CONFIG /
# FM_KNOWN_HOSTS point at scratch files, so no real machine or ~/.ssh is ever
# touched. The ssh stub runs remote commands locally in a scratch account: HOME
# is a throwaway directory and PATH holds fake installers and tools there.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(fm_test_tmproot fm-machine)
FAKEBIN=$(fm_fakebin "$T")
FMH="$T/home"
SSH_LOG="$T/ssh.log"
mkdir -p "$FMH/data"
export FM_SSH_CONFIG="$T/ssh_config"
export FM_KNOWN_HOSTS="$T/known_hosts"
export FAKE_SSH_LOG="$SSH_LOG"
export REAL_SSH
REAL_SSH=$(command -v ssh)
: > "$SSH_LOG"
cat > "$FM_SSH_CONFIG" <<'CFG'
Host *
  ServerAliveInterval 30

Host box
  HostName box.lan
  User captain
CFG
printf 'box.lan ssh-ed25519 AAAAKEYBOX\n' > "$FM_KNOWN_HOSTS"

# ssh stub: -G reads the scratch config; "true" answers per FAKE_SSH_REACH; the
# fixed entrypoint answers like a remote doctor; anything else runs locally in
# the scratch remote account.
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
G=0
CONFIG=
TRUST=
GOPTS=()
UPDATE_KEYS=yes
while [ "$#" -gt 0 ]; do
  case "$1" in
    -G) G=1; shift ;;
    -F) CONFIG=$2; shift 2 ;;
    -o)
      case "$2" in
        UserKnownHostsFile=*) TRUST=${2#UserKnownHostsFile=} ;;
        UpdateHostKeys=*) UPDATE_KEYS=${2#UpdateHostKeys=} ;;
        HostName=*|User=*) GOPTS+=(-o "$2"); printf 'override %s\n' "$2" >> "$FAKE_SSH_LOG" ;;
      esac
      shift 2 ;;
    -p) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
alias=$1
shift
if [ "$G" -eq 1 ]; then
  if [ -n "${FAKE_G_KNOWN_HOSTS:-}" ]; then
    "$REAL_SSH" -F "$CONFIG" "${GOPTS[@]+"${GOPTS[@]}"}" -G "$alias" | awk '$1 != "userknownhostsfile"'
    printf 'userknownhostsfile %s\n' "$FAKE_G_KNOWN_HOSTS"
    exit 0
  fi
  exec "$REAL_SSH" -F "$CONFIG" "${GOPTS[@]+"${GOPTS[@]}"}" -G "$alias"
fi
if [ "$CONFIG" != "$FM_SSH_CONFIG" ] || [ "$TRUST" != "${FAKE_EXPECT_KNOWN_HOSTS:-$FM_KNOWN_HOSTS}" ]; then
  echo 'wrong ssh config or trust selection' >&2
  exit 255
fi
if [ "$UPDATE_KEYS" != no ]; then
  printf 'box.lan ssh-rsa UNEXPECTEDKEY\n' >> "$TRUST"
fi
printf 'ssh %s %s\n' "$alias" "$*" >> "$FAKE_SSH_LOG"
case "$1" in
  true)
    case "${FAKE_SSH_REACH:-ok}" in
      ok) exit 0 ;;
      auth) echo "captain@box.lan: Permission denied (publickey)." >&2; exit 255 ;;
      hostkey) echo "No ED25519 host key is known for box.lan and you have requested strict checking." >&2
               echo "Host key verification failed." >&2; exit 255 ;;
      timeout) echo "ssh: connect to host box.lan port 22: Operation timed out" >&2; exit 255 ;;
    esac ;;
  fm-remote-entrypoint.sh)
    printf 'entrypoint root=%s home=%s argv=%s\n' "$(printf '%s' "$3" | base64 -d)" "$(printf '%s' "$4" | base64 -d)" \
      "$(printf '%s' "$5" | base64 -d | tr '\0' ' ')" >> "$FAKE_SSH_LOG"
    if [ "${FAKE_DOCTOR_UNAVAILABLE:-0}" = 1 ]; then
      echo 'ssh: doctor transport failed' >&2
      exit 255
    fi
    mode=check
    case "$(printf '%s' "$5" | base64 -d | tr '\0' ' ')" in *--fix*) mode=fix ;; esac
    printf 'mode=%s\ncheck stream-tools=ok: fake\n' "$mode"
    [ -z "${FAKE_DOCTOR_REQUIRED:-}" ] || printf 'required tasks-axi=%s\n' "$FAKE_DOCTOR_REQUIRED"
    if [ "${FAKE_DOCTOR_FIXABLE:-0}" = 1 ]; then
      printf 'check remote-job-worker=fixable: worker is not running\naction: remote-job-worker: repair the worker on the machine\n'
    fi
    if [ "${FAKE_DOCTOR_GAP:-0}" = 1 ]; then
      printf 'check gui-session=human: no GUI login session\naction: gui-session: log in on the console once\n'
    fi
    exit "${FAKE_DOCTOR_RC:-0}"
    ;;
  *)
    # Any other command runs here as the scratch remote account.
    cd "$FAKE_ACCOUNT" || exit 255
    unset PROXAI_API_KEY_FILE
    operation=
    case "$*" in
      *" 'probe' "*) operation=probe ;;
      *" 'install-tool' "*) operation=install-tool ;;
      *" 'install-deck' "*) operation=install-deck ;;
      "sh -s -- "*) operation=clone ;;
    esac
    fail=0
    if [ -n "$operation" ] && [ "${FAKE_SSH_FAIL_AFTER:-}" = "$operation" ]; then
      fail=1
      if [ "$operation" = probe ]; then
        probe_count=0
        [ ! -f "$FAKE_ACCOUNT/probe-count" ] || read -r probe_count < "$FAKE_ACCOUNT/probe-count"
        probe_count=$((probe_count + 1))
        printf '%s\n' "$probe_count" > "$FAKE_ACCOUNT/probe-count"
        [ "$probe_count" -eq "${FAKE_SSH_PROBE_FAIL_AT:-1}" ] || fail=0
      fi
    fi
    if [ "$fail" -eq 1 ]; then
      if [ "$operation" = probe ]; then
        cat >/dev/null
        printf 'account-home=%s\nclone=present\ntool treehouse=/partial/treehouse\n' "$FAKE_ACCOUNT"
      else
        HOME="$FAKE_ACCOUNT" PATH="$FAKE_RBIN:/usr/bin:/bin" sh -c "$*"
      fi
      exit 255
    fi
    HOME="$FAKE_ACCOUNT" PATH="$FAKE_RBIN:/usr/bin:/bin" exec sh -c "$*"
    ;;
esac
SH
cat > "$FAKEBIN/ssh-keyscan" <<'SH'
#!/usr/bin/env bash
host=${*: -1}
printf '# %s:22 SSH-2.0-OpenSSH\n' "$host"
printf '%s ssh-ed25519 %s\n' "$host" "${FAKE_SCAN_KEY:-AAAAKEYNEW}"
SH
# ssh-keygen stub: -lf - fingerprints stdin lines; -F finds a host in -f file.
cat > "$FAKEBIN/ssh-keygen" <<'SH'
#!/usr/bin/env bash
if [ "$1" = -lf ] && [ "$2" = - ]; then
  while read -r host type key; do
    [ -n "$key" ] && printf '256 SHA256:FP%s %s (ED25519)\n' "$key" "$host"
  done
  exit 0
fi
if [ "$1" = -F ]; then
  awk -v h="$2" '$1 == h { print "# Host " h " found: line " NR; print; f = 1 } END { exit f ? 0 : 1 }' "$4"
  exit
fi
exit 2
SH
chmod +x "$FAKEBIN"/*
export PATH="$FAKEBIN:$PATH"

export FAKE_ACCOUNT="$T/acct" FAKE_RBIN="$T/rbin"
# The scratch account's tools. git clones make a Firstmate-shaped tree (or a
# bare source tree for Deck); curl answers probes by port and prints a tiny
# installer otherwise; npm and cargo install into the account.
new_account() {
  rm -rf "$FAKE_ACCOUNT" "$FAKE_RBIN"
  mkdir -p "$FAKE_ACCOUNT" "$FAKE_RBIN"
  for tool in node jq python3; do printf '#!/bin/sh\nexit 0\n' > "$FAKE_RBIN/$tool"; done
  cat > "$FAKE_RBIN/git" <<'TOOL'
#!/bin/sh
case "$1" in
  clone)
    if [ "${FAKE_CLONE_FAIL:-0}" = 1 ]; then
      printf 'fatal: cannot clone %s\n' "$4" >&2
      exit 1
    fi
    for dest; do :; done
    mkdir -p "$dest/.git" "$dest/bin"
    printf '%s\n' "$4" > "$dest/.git/origin"
    case "$*" in
      *deck*) ;;
      *) printf 'fixture\n' > "$dest/AGENTS.md"; : > "$dest/bin/fm-remote-entrypoint.sh" ;;
    esac ;;
  -C)
    case "$3" in
      rev-parse) echo abc1234 ;;
      config) cat "$2/.git/origin" ;;
    esac ;;
esac
exit 0
TOOL
  cat > "$FAKE_RBIN/curl" <<'TOOL'
#!/bin/sh
for url; do :; done
case "$*" in
  *' -w '*)
    case "$url" in
      *8329*) printf '%s' "${FAKE_GATEWAY_CODE:-401}" ;;
      *) printf '%s' "${FAKE_HUB_CODE:-401}" ;;
    esac ;;
  *)
    case "$url" in *treehouse*) name=treehouse ;; *) name=no-mistakes ;; esac
    printf 'mkdir -p "$HOME/.local/bin"; printf "#!/bin/sh\\nexit 0\\n" > "$HOME/.local/bin/%s"; chmod +x "$HOME/.local/bin/%s"\n' "$name" "$name" ;;
esac
TOOL
  cat > "$FAKE_RBIN/npm" <<'TOOL'
#!/bin/sh
case "$1" in
  prefix) mkdir -p "$HOME/.npm-global"; echo "$HOME/.npm-global" ;;
  install) for t; do :; done; mkdir -p "$HOME/.local/bin"; printf '#!/bin/sh\nexit 0\n' > "$HOME/.local/bin/$t"; chmod +x "$HOME/.local/bin/$t" ;;
esac
TOOL
  cat > "$FAKE_RBIN/cargo" <<'TOOL'
#!/bin/sh
[ "${FAKE_CARGO_FAIL:-0}" = 1 ] && exit 101
mkdir -p target/release
printf '#!/bin/sh\necho deck 0.1\n' > target/release/deck
chmod +x target/release/deck
TOOL
  cat > "$FAKE_RBIN/gh" <<'TOOL'
#!/bin/sh
[ "$1 $2" = "auth status" ] && exit "${FAKE_GH_AUTH:-0}"
exit 0
TOOL
  chmod +x "$FAKE_RBIN"/*
  mkdir -p "$FAKE_ACCOUNT/.config/proxai"
  printf 'SECRET-GATEWAY-KEY\n' > "$FAKE_ACCOUNT/.config/proxai/client.key"
  chmod 644 "$FAKE_ACCOUNT/.config/proxai/client.key"
}
new_account
mkdir -p "$FMH/config"
printf 'http://127.0.0.1:7717\n' > "$FMH/config/stream-hub"

NETFM="$T/net-fm"
fm_git_init_commit "$NETFM"
mkdir -p "$NETFM/bin"
cp "$ROOT/bin/fm-remote-doctor.sh" "$NETFM/bin/"
git -C "$NETFM" add bin/fm-remote-doctor.sh
git -C "$NETFM" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm doctor
git -C "$NETFM" remote add origin https://example.com/acme/firstmate.git
RROOT="$FAKE_ACCOUNT/firstmate"

machine() { FM_HOME="$FMH" FM_ROOT_OVERRIDE="${FM_ROOT_OVERRIDE:-$NETFM}" "$ROOT/bin/fm-machine.sh" "$@"; }

# --- check ---
before=$(cat "$FM_KNOWN_HOSTS")
set +e
out=$(machine check box "$RROOT")
rc=$?
set -e
expect_code 1 "$rc" "check of a fresh machine"
assert_equals "$before" "$(cat "$FM_KNOWN_HOSTS")" "check updated trusted host keys"
assert_contains "$out" "check alias=ok: box resolves to box.lan as captain on port 22" "alias ok"
assert_contains "$out" "check hostkey=ok: box.lan is known as SHA256:FPAAAAKEYBOX" "hostkey ok"
assert_contains "$out" "reach=ok" "reach ok"
assert_contains "$out" "item ssh-login=present:" "ssh login item"
assert_contains "$out" "item firstmate-clone=will-install: setup clones https://example.com/acme/firstmate.git at $RROOT" "clone item"
assert_contains "$out" "item doctor=will-install:" "doctor item before clone"
assert_contains "$out" "item tool-jq=present: $FAKE_RBIN/jq" "present tool"
assert_contains "$out" "item tool-treehouse=will-install: curl -fsSL" "curl installer tool"
assert_contains "$out" "item tool-tasks-axi=will-install: npm install -g tasks-axi" "npm tool"
assert_contains "$out" "item tool-curl=present:" "curl present"
assert_contains "$out" "item deck=will-install: setup builds" "deck item"
assert_contains "$out" "item gh-auth=present:" "gh auth item"
assert_contains "$out" "item model-gateway=present:" "gateway item"
assert_contains "$out" "item gateway-key=will-install: setup restricts path=$FAKE_ACCOUNT/.config/proxai/client.key mode=644 to mode 600" "unsafe key item"
assert_contains "$out" "item stream-hub=present:" "hub item"
assert_not_contains "$out" "SECRET-GATEWAY-KEY" "check printed the gateway key"
assert_absent "$RROOT" "check created the clone"
pass "check prints the machine checklist read-only"

: > "$SSH_LOG"
set +e
out=$(FAKE_SSH_FAIL_AFTER=probe machine check box "$RROOT")
rc=$?
set -e
expect_code 1 "$rc" "check with partial output from a failed probe"
for item in firstmate-clone entrypoint-link doctor tool-treehouse tool-tasks-axi deck gh-auth model-gateway gateway-key stream-hub; do
  assert_contains "$out" "item $item=human: the probe over ssh failed (exit 255); rerun check" "failed probe certified $item"
done
assert_not_contains "$out" 'tool treehouse=/partial/treehouse' "failed probe exposed untrusted tool facts"
assert_not_contains "$out" '=will-install:' "failed probe scheduled installs"
assert_no_grep 'fm-remote-doctor.sh' "$SSH_LOG" "doctor ran using a failed probe"
pass "check marks probe-dependent items human after a partial SSH failure"

set +e
out=$(FAKE_GH_AUTH=1 FAKE_GATEWAY_CODE=000 FAKE_HUB_CODE=000 machine check box "$RROOT")
set -e
assert_contains "$out" "item gh-auth=human: run gh auth login" "gh auth human step"
assert_contains "$out" "item model-gateway=human: make http://127.0.0.1:8329/v1 answer on the machine" "gateway human step"
assert_contains "$out" "item stream-hub=human: make http://127.0.0.1:7717 reachable" "hub human step"
rm -f "$FAKE_RBIN/cargo" "$FAKE_RBIN/node"
rm -f "$FAKE_ACCOUNT/.config/proxai/client.key"
set +e
out=$(machine check box "$RROOT")
set -e
assert_contains "$out" "item deck=human: install Rust with rustup" "deck without cargo"
assert_contains "$out" "item tool-node=human: brew install node" "package-manager tool"
assert_contains "$out" "item gateway-key=human: put the gateway client key at $FAKE_ACCOUNT/.config/proxai/client.key with mode 600" "missing key"
new_account
pass "check names the human steps for auth, gateway, hub, Rust, packages and the key"

set +e
out=$(FAKE_SSH_REACH=auth machine check newbox)
rc=$?
set -e
expect_code 1 "$rc" "unknown machine"
assert_contains "$out" "check alias=missing: no ssh config block names or resolves newbox" "alias missing"
assert_contains "$out" "action: bin/fm-machine.sh add newbox <address> <user>" "add action"
assert_contains "$out" "hostkey-fingerprint=SHA256:FPAAAAKEYNEW type=ED25519" "scanned fingerprint"
assert_contains "$out" "check hostkey=missing: newbox is not in $FM_KNOWN_HOSTS" "hostkey missing"
assert_contains "$out" "reach=auth" "auth class"
assert_contains "$out" "action: ssh-copy-id newbox" "auth action"
assert_not_contains "$out" "tool deck=" "tool probe ran without a connection"
assert_contains "$out" "item machine=human: everything else is checked once ssh login works" "checklist stops at ssh"
assert_no_grep "newbox" "$FM_KNOWN_HOSTS" "check wrote a scanned key"
pass "check classifies a missing alias, an unknown key and refused key login"

: > "$SSH_LOG"
before_cfg=$(cat "$FM_SSH_CONFIG")
set +e
out=$(machine check freshbox --address 10.0.0.42 --user captain)
rc=$?
set -e
expect_code 1 "$rc" "check of an unconfigured alias with an address"
assert_contains "$out" "hostname=10.0.0.42 user=captain port=22" "address override resolved"
assert_contains "$out" "check alias=missing: no ssh config block names or resolves freshbox" "alias still missing"
assert_contains "$out" "action: bin/fm-machine.sh add freshbox 10.0.0.42 captain" "add action with values"
assert_contains "$out" "hostkey-fingerprint=SHA256:FPAAAAKEYNEW" "scanned the given address"
assert_contains "$out" "check hostkey=missing: 10.0.0.42 is not in" "hostkey looked up by address"
assert_grep "override HostName=10.0.0.42" "$SSH_LOG" "connections did not carry the address"
assert_equals "$before_cfg" "$(cat "$FM_SSH_CONFIG")" "check wrote the ssh config"
assert_no_grep "10.0.0.42" "$FM_KNOWN_HOSTS" "check wrote a host key"
set +e
out=$(machine check freshbox --address -oProxy=x --user captain)
rc=$?
set -e
expect_code 1 "$rc" "unsafe address"
assert_contains "$out" "refuse: address must be a host name or IP address" "address validation"
pass "check probes an unconfigured alias at a given address and user without writing"

set +e
out=$(FAKE_SSH_REACH=hostkey machine check box)
set -e
assert_contains "$out" "reach=hostkey" "hostkey class"
out=$(FAKE_SSH_REACH=timeout machine check box) || true
assert_contains "$out" "reach=timeout" "timeout class"
pass "check classifies host key and timeout failures"

cat >> "$FM_SSH_CONFIG" <<'CFG'
Host samebox
  HostName samebox
  User captain
CFG
printf 'samebox ssh-ed25519 AAAAKEYSAME\n' >> "$FM_KNOWN_HOSTS"
out=$(machine check samebox) || true
assert_contains "$out" "check alias=ok: samebox resolves to samebox" "literal self-resolving alias"
assert_not_contains "$out" "action: bin/fm-machine.sh add" "configured alias recommended add"
pass "check accepts an explicitly configured alias equal to its hostname"

# --- add ---
before=$(cat "$FM_SSH_CONFIG")
set +e
out=$(machine add box 10.0.0.9 captain)
rc=$?
set -e
expect_code 1 "$rc" "add existing alias"
assert_contains "$out" "refuse: $FM_SSH_CONFIG already has a Host block naming box" "add refusal"
assert_equals "$before" "$(cat "$FM_SSH_CONFIG")" "a refused add changed the config"
out=$(machine add newbox 10.0.0.9 captain)
assert_contains "$out" "added=$FM_SSH_CONFIG" "add result"
assert_grep "Host newbox" "$FM_SSH_CONFIG" "add wrote no Host line"
assert_grep "  HostName 10.0.0.9" "$FM_SSH_CONFIG" "add wrote no HostName"
assert_grep "  ForwardAgent no" "$FM_SSH_CONFIG" "add allowed agent forwarding"
set +e
machine add newbox 10.0.0.10 captain >/dev/null
rc=$?
set -e
expect_code 1 "$rc" "add twice"
set +e
out=$(machine add -oProxyCommand=x 10.0.0.9 captain)
rc=$?
set -e
expect_code 1 "$rc" "add unsafe alias"
pass "add appends a marked block once and refuses an existing alias"

CONFLICT_CONFIG="$T/conflict_config"
printf 'Host *\n  User olduser\n' > "$CONFLICT_CONFIG"
before=$(cat "$CONFLICT_CONFIG")
set +e
out=$(FM_SSH_CONFIG="$CONFLICT_CONFIG" machine add conflictbox 10.0.0.9 newuser)
rc=$?
set -e
expect_code 1 "$rc" "add with earlier wildcard User"
assert_contains "$out" "earlier ssh config settings override" "ineffective User refusal"
assert_equals "$before" "$(cat "$CONFLICT_CONFIG")" "ineffective add changed the config"
printf 'Host *\n  HostName %%h\n' > "$CONFLICT_CONFIG"
before=$(cat "$CONFLICT_CONFIG")
set +e
out=$(FM_SSH_CONFIG="$CONFLICT_CONFIG" machine add conflictbox 10.0.0.9 captain)
rc=$?
set -e
expect_code 1 "$rc" "add with earlier wildcard HostName"
assert_equals "$before" "$(cat "$CONFLICT_CONFIG")" "ineffective hostname add changed the config"
out=$(machine add upperbox UPPER.EXAMPLE captain)
assert_contains "$out" "added=$FM_SSH_CONFIG" "case-insensitive hostname validation"
pass "add refuses ineffective hostname or user settings before writing"

# --- trust ---
before=$(cat "$FM_KNOWN_HOSTS")
set +e
out=$(machine trust newbox SHA256:FPSOMETHINGELSE)
rc=$?
set -e
expect_code 1 "$rc" "trust mismatch"
assert_contains "$out" "refuse: no key scanned from 10.0.0.9 port 22 has fingerprint SHA256:FPSOMETHINGELSE" "mismatch refusal"
assert_equals "$before" "$(cat "$FM_KNOWN_HOSTS")" "a refused trust changed known_hosts"
out=$(machine trust newbox SHA256:FPAAAAKEYNEW)
assert_contains "$out" "trusted=SHA256:FPAAAAKEYNEW file=$FM_KNOWN_HOSTS" "trust result"
assert_grep "10.0.0.9 ssh-ed25519 AAAAKEYNEW" "$FM_KNOWN_HOSTS" "trusted key not written"
out=$(machine trust newbox SHA256:FPAAAAKEYNEW)
assert_contains "$out" "trust=already-known" "trust idempotent"
set +e
out=$(FAKE_SCAN_KEY=AAAAROTATED machine trust newbox SHA256:FPAAAAROTATED)
rc=$?
set -e
expect_code 1 "$rc" "trust over a different known key"
assert_contains "$out" "already has a different known host key" "changed-key refusal"
pass "trust writes only an exactly matching scanned key"

CLUSTER_HOME="$T/cluster-home"
CLUSTER_CONFIG="$T/cluster-config"
CLUSTER_KEYS="$CLUSTER_HOME/.ssh/cluster_keys"
mkdir -p "$CLUSTER_HOME/.ssh"
cat > "$CLUSTER_CONFIG" <<CFG
Host cluster
  HostName cluster.lan
  User captain
  UserKnownHostsFile $CLUSTER_KEYS $CLUSTER_HOME/.ssh/unused_keys
CFG
before=$(cat "$FM_KNOWN_HOSTS")
cluster() {
  (unset FM_KNOWN_HOSTS
   HOME="$CLUSTER_HOME" FM_SSH_CONFIG="$CLUSTER_CONFIG" FAKE_EXPECT_KNOWN_HOSTS="$CLUSTER_KEYS" machine "$@")
}
out=$(cluster trust cluster SHA256:FPAAAAKEYNEW)
assert_contains "$out" "trusted=SHA256:FPAAAAKEYNEW file=$CLUSTER_KEYS" "configured trust file"
assert_grep "cluster.lan ssh-ed25519 AAAAKEYNEW" "$CLUSTER_KEYS" "key missing from selected trust file"
out=$(cluster check cluster) || true
assert_contains "$out" "check hostkey=ok: cluster.lan" "lookup missed configured trust file"
assert_contains "$out" "reach=ok" "connection missed configured trust file"
out=$(FAKE_G_KNOWN_HOSTS="$(printf '%s/.ssh/cluster_keys %s/.ssh/unused_keys' '~' '~')" cluster check cluster) || true
assert_contains "$out" "reach=ok" "tilde expansion missed selected trust file"
assert_equals "$before" "$(cat "$FM_KNOWN_HOSTS")" "configured trust wrote default keys"
assert_absent "$CLUSTER_HOME/.ssh/unused_keys" "trust wrote a secondary file"
pass "trust and check share the first configured known-hosts file with tilde expansion"

# --- register ---
out=$(machine register box /srv/firstmate)
assert_contains "$out" "registered=box root=/srv/firstmate" "register result"
out=$(machine register box /srv/firstmate)
assert_contains "$out" "register=already-recorded" "register idempotent"
assert_equals 1 "$(grep -c '^- box ' "$FMH/data/machines.md")" "register duplicated the machine"
grep -qE '^- box \(root: /srv/firstmate; added [0-9]{4}-[0-9]{2}-[0-9]{2}\)$' "$FMH/data/machines.md" \
  || fail "machines.md line has the wrong shape: $(cat "$FMH/data/machines.md")"
set +e
out=$(machine register box /other/root)
rc=$?
set -e
expect_code 1 "$rc" "register different root"
assert_contains "$out" "already recorded with a different root" "different root refusal"
pass "register records a machine once and refuses a different root"

# --- prepare ---
LOCALFM="$T/local-origin-fm"
fm_git_init_commit "$LOCALFM"
git -C "$LOCALFM" remote add origin /some/local/path
set +e
out=$(FM_ROOT_OVERRIDE="$LOCALFM" machine prepare box /srv/firstmate)
rc=$?
set -e
expect_code 1 "$rc" "prepare from a local origin"
assert_contains "$out" "a local path the machine cannot clone from" "local origin refusal"
pass "prepare refuses to clone from a local-path origin"

: > "$SSH_LOG"
out=$(machine prepare box "$RROOT")
assert_equals "$before" "$(cat "$FM_KNOWN_HOSTS")" "prepare updated trusted host keys"
assert_contains "$out" "clone=created root=$RROOT" "clone line"
assert_contains "$out" "entrypoint-link=created: $RROOT/bin/fm-remote-entrypoint.sh" "link line"
assert_contains "$out" "doctor: check stream-tools=ok: fake" "doctor relayed"
assert_present "$RROOT/AGENTS.md" "prepare did not clone"
[ "$(readlink "$FAKE_ACCOUNT/.local/bin/fm-remote-entrypoint.sh")" = "$RROOT/bin/fm-remote-entrypoint.sh" ] || fail "prepare did not link the entrypoint"
assert_grep "entrypoint root=$RROOT home=$FAKE_ACCOUNT/.firstmate-machine-probe argv=fm-remote-doctor.sh --backend stream --fix" "$SSH_LOG" "doctor was not run with --fix through the entrypoint"
assert_absent "$FMH/data/secondmates.md" "prepare left a route in the real registry"
out=$(machine prepare box "$RROOT")
assert_contains "$out" "clone=present root=$RROOT" "prepare rerun"
set +e
out=$(FAKE_DOCTOR_RC=1 machine prepare box "$RROOT")
rc=$?
set -e
expect_code 1 "$rc" "prepare relays the doctor verdict"
out=$(cluster prepare cluster "$RROOT")
assert_contains "$out" "doctor: check stream-tools=ok: fake" "doctor lost configured trust selection"
pass "prepare clones, links and relays the doctor's --fix verdict"

# --- setup ---
for operation in clone probe install-tool install-deck; do
  new_account
  : > "$SSH_LOG"
  set +e
  out=$(FAKE_SSH_FAIL_AFTER="$operation" machine setup box "$RROOT")
  rc=$?
  set -e
  expect_code 1 "$rc" "setup with failed $operation transport after output"
  assert_contains "$out" 'setup=failed' "failed $operation transport verdict"
  assert_not_contains "$out" 'setup=complete' "failed $operation transport certified setup"
  assert_no_grep 'fm-remote-doctor.sh' "$SSH_LOG" "doctor ran after failed $operation transport"
  assert_equals 644 "$(stat -f %Lp "$FAKE_ACCOUNT/.config/proxai/client.key" 2>/dev/null || stat -c %a "$FAKE_ACCOUNT/.config/proxai/client.key")" "key was changed after failed $operation transport"
  case "$operation" in
    clone)
      assert_contains "$out" 'step firstmate-clone=failed: clone/link over ssh failed (exit 255)' "partial clone success overrode SSH failure"
      assert_not_contains "$out" 'step firstmate-clone=done:' "failed clone reported done"
      assert_not_contains "$out" 'step entrypoint-link=' "setup continued after failed clone call"
      assert_no_grep "'probe'" "$SSH_LOG" "probe ran after failed clone call"
      ;;
    probe)
      assert_contains "$out" 'step probe=failed: the probe over ssh failed (exit 255)' "partial account-home overrode probe failure"
      assert_equals 1 "$(cat "$FAKE_ACCOUNT/probe-count")" "setup retried after probe failure"
      assert_no_grep "'install-tool'" "$SSH_LOG" "installation ran after probe failure"
      ;;
    install-tool)
      assert_contains "$out" 'step tool-treehouse=failed: the install over ssh failed (exit 255)' "success-looking tool result overrode SSH failure"
      assert_not_contains "$out" 'step tool-treehouse=done:' "failed install reported done"
      assert_absent "$FAKE_ACCOUNT/.local/bin/no-mistakes" "setup installed the next tool after SSH failure"
      ;;
    install-deck)
      assert_contains "$out" 'step deck=failed: the install over ssh failed (exit 255)' "success-looking Deck result overrode SSH failure"
      assert_not_contains "$out" 'step deck=done:' "failed Deck install reported done"
      ;;
  esac
  if [ "$operation" != install-deck ]; then
    assert_no_grep "'install-deck'" "$SSH_LOG" "Deck ran after failed $operation transport"
  fi
done
pass "setup stops after clone, probe and install SSH failures despite success-looking output"

new_account
: > "$SSH_LOG"
set +e
out=$(FAKE_SSH_FAIL_AFTER=probe FAKE_SSH_PROBE_FAIL_AT=2 machine setup box "$RROOT")
rc=$?
set -e
expect_code 1 "$rc" "setup with a failed final probe"
assert_contains "$out" 'step doctor=done:' "final probe failure fixture did not reach doctor"
assert_contains "$out" 'step probe=failed: the probe over ssh failed (exit 255)' "final probe failure was hidden"
assert_contains "$out" 'setup=failed' "final probe failure certified setup"
assert_equals 2 "$(cat "$FAKE_ACCOUNT/probe-count")" "setup retried after final probe failure"
pass "setup fails rather than certifying readiness when its final probe connection drops"

new_account
: > "$SSH_LOG"
set +e
out=$(FAKE_DOCTOR_GAP=1 FAKE_GH_AUTH=1 machine setup box "$RROOT")
rc=$?
set -e
expect_code 3 "$rc" "setup with human steps left"
assert_contains "$out" "step ssh=done:" "ssh step"
assert_contains "$out" "step firstmate-clone=done: cloned https://example.com/acme/firstmate.git at $RROOT" "clone step"
assert_contains "$out" "step entrypoint-link=done:" "link step"
assert_contains "$out" "step tool-jq=skipped: present at $FAKE_RBIN/jq" "present tool skipped"
assert_contains "$out" "step tool-treehouse=done: $FAKE_ACCOUNT/.local/bin/treehouse" "curl installer step"
assert_contains "$out" "step tool-no-mistakes=done:" "no-mistakes step"
assert_contains "$out" "step tool-gh-axi=done:" "npm step"
assert_contains "$out" "step tool-quota-axi=done:" "npm step"
assert_contains "$out" "step deck=done: $FAKE_ACCOUNT/.local/bin/deck at abc1234" "deck step"
assert_contains "$out" "step gateway-key-mode=done:" "key mode step"
assert_contains "$out" "step doctor=done:" "doctor step"
assert_contains "$out" "human doctor-gui-session: log in on the console once" "doctor human step"
assert_contains "$out" "human gh-auth: run gh auth login" "gh human step"
assert_contains "$out" "setup=incomplete: 2 human steps" "setup verdict"
assert_not_contains "$out" "SECRET-GATEWAY-KEY" "setup printed the gateway key"
[ "$(stat -f %Lp "$FAKE_ACCOUNT/.config/proxai/client.key" 2>/dev/null || stat -c %a "$FAKE_ACCOUNT/.config/proxai/client.key")" = 600 ] \
  || fail "setup did not restrict the gateway key"
assert_grep "argv=fm-remote-doctor.sh --backend stream --fix" "$SSH_LOG" "setup did not run doctor --fix"
pass "setup installs the automatable items in order and lists the human steps"

out=$(machine setup box "$RROOT")
assert_contains "$out" "step firstmate-clone=skipped:" "clone rerun"
assert_contains "$out" "step entrypoint-link=skipped:" "link rerun"
assert_contains "$out" "step tool-treehouse=skipped: present" "tool rerun"
assert_contains "$out" "step deck=skipped: present" "deck rerun"
assert_not_contains "$out" "step gateway-key-mode" "key mode rerun"
assert_contains "$out" "setup=complete" "complete rerun"
pass "setup is idempotent and reports complete once nothing is left"

for required in 'MISSING (incompatible)' 'VERSION_UNREADABLE (requires semantic version >=0.21.0)'; do
  set +e
  out=$(FAKE_DOCTOR_REQUIRED="$required" FAKE_DOCTOR_RC=1 machine check box "$RROOT")
  rc=$?
  set -e
  expect_code 1 "$rc" "check with a doctor-required tool gap"
  assert_contains "$out" "item doctor-required-tasks-axi=human: npm install -g tasks-axi; doctor reports $required" "doctor-required item"
  set +e
  out=$(FAKE_DOCTOR_REQUIRED="$required" FAKE_DOCTOR_RC=1 machine setup box "$RROOT")
  rc=$?
  set -e
  expect_code 3 "$rc" "setup with a doctor-required human step"
  assert_contains "$out" "step doctor=done:" "human-only doctor gap failed setup"
  assert_contains "$out" "human doctor-required-tasks-axi: npm install -g tasks-axi" "missing tool upgrade step"
  assert_contains "$out" "setup=incomplete: 1 human steps" "required tool gap was lost"
done
pass "doctor-required missing and unreadable versions remain human steps"

set +e
out=$(FAKE_DOCTOR_FIXABLE=1 FAKE_DOCTOR_RC=1 machine check box "$RROOT")
rc=$?
set -e
expect_code 1 "$rc" "check with a fixable gap"
assert_contains "$out" "item doctor-remote-job-worker=will-install: repair the worker on the machine" "read-only doctor repair item"
set +e
out=$(FAKE_DOCTOR_FIXABLE=1 FAKE_DOCTOR_RC=1 machine setup box "$RROOT")
rc=$?
set -e
expect_code 1 "$rc" "setup with a fixable gap after repair"
assert_contains "$out" "step doctor=failed: fixable gaps remain after --fix: remote-job-worker: worker is not running" "failed repair was marked done"
assert_contains "$out" "human doctor-remote-job-worker: repair the worker on the machine" "failed repair was not counted as human"
assert_contains "$out" "setup=failed" "failed repair verdict"
assert_not_contains "$out" "step doctor=done:" "failed doctor also reported done"
pass "setup fails and retains human repair steps when doctor fixes do not converge"

for transport in unavailable partial; do
  set +e
  if [ "$transport" = unavailable ]; then
    out=$(FAKE_DOCTOR_UNAVAILABLE=1 machine setup box "$RROOT")
  else
    out=$(FAKE_DOCTOR_RC=255 machine setup box "$RROOT")
  fi
  rc=$?
  set -e
  expect_code 1 "$rc" "setup with doctor transport failure"
  assert_contains "$out" "step doctor=failed:" "doctor transport failure was hidden"
  assert_contains "$out" "setup=failed" "transport failure verdict"
done
pass "setup rejects absent and partial doctor transport results"

chmod 200 "$FAKE_ACCOUNT/.config/proxai/client.key"
set +e
out=$(machine setup box "$RROOT")
rc=$?
set -e
expect_code 3 "$rc" "setup with an owner-unreadable key"
assert_contains "$out" "human gateway-key: grant owner read access" "owner access needs a person"
assert_not_contains "$out" "step gateway-key-mode=" "setup expanded key permissions"
assert_equals 200 "$(stat -f %Lp "$FAKE_ACCOUNT/.config/proxai/client.key" 2>/dev/null || stat -c %a "$FAKE_ACCOUNT/.config/proxai/client.key")" "setup expanded owner permissions"
for mode in 400 600 700; do
  chmod "$mode" "$FAKE_ACCOUNT/.config/proxai/client.key"
  out=$(machine setup box "$RROOT")
  assert_contains "$out" "setup=complete" "owner-readable restrictive key rejected"
  assert_not_contains "$out" "step gateway-key-mode=" "restrictive key was changed"
done
pass "setup tightens only loose keys and leaves permission expansion to a person"

new_account
: > "$SSH_LOG"
set +e
out=$(FAKE_CARGO_FAIL=1 machine setup box "$RROOT")
rc=$?
set -e
expect_code 1 "$rc" "setup stops on a failed step"
assert_contains "$out" "step deck=failed: cargo build --release --locked failed" "deck failure"
assert_contains "$out" "setup=failed" "failed verdict"
assert_not_contains "$out" "step doctor=" "setup continued after a failure"
assert_no_grep "fm-remote-doctor.sh" "$SSH_LOG" "doctor ran after a failed step"
pass "setup stops safely at the first failed step"

set +e
out=$(FM_DECK_REPO_URL=https://example.com/other/deck.git machine setup box "$RROOT")
rc=$?
set -e
expect_code 1 "$rc" "Deck cache origin mismatch"
assert_contains "$out" "step deck=failed: cached Deck clone at $FAKE_ACCOUNT/.cache/firstmate/deck has a different origin" "wrong Deck cache was reused"
assert_absent "$FAKE_ACCOUNT/.local/bin/deck" "wrong repository's binary was installed"
pass "Deck retries refuse a cache belonging to another repository"

set +e
out=$(FAKE_SSH_REACH=auth machine setup box "$RROOT")
rc=$?
set -e
expect_code 1 "$rc" "setup without ssh login"
assert_contains "$out" "step ssh=failed: captain@box.lan: Permission denied (publickey)." "ssh failure"
assert_contains "$out" "human ssh-login: ssh-copy-id box" "ssh human step"
pass "setup refuses to start without a working ssh login"

new_account
out=$(machine prepare box "$RROOT")
cp "$ROOT/bin/fm-remote-job-lib.sh" "$RROOT/bin/"
cp "$FAKE_RBIN"/* "$FAKE_ACCOUNT/.local/bin/"
mkdir -p "$FAKE_ACCOUNT/.cargo/bin"
mv "$FAKE_ACCOUNT/.local/bin/cargo" "$FAKE_ACCOUNT/.cargo/bin/"
rm "$FAKE_RBIN/cargo"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_ACCOUNT/.cargo/bin/cargo-only-runtime"
chmod +x "$FAKE_ACCOUNT/.cargo/bin/cargo-only-runtime"
remote() { HOME="$FAKE_ACCOUNT" PATH="$FAKE_RBIN:/usr/bin:/bin" "$ROOT/bin/fm-machine-remote.sh" "$@"; }
out=$(remote probe "$RROOT" http://127.0.0.1:8329/v1 - cargo-only-runtime)
assert_contains "$out" "path-source=worker" "worker PATH not used"
assert_contains "$out" "tool cargo=$FAKE_ACCOUNT/.cargo/bin/cargo" "rustup cargo not found for builds"
assert_contains "$out" "tool cargo-only-runtime=missing" "cargo directory leaked into runtime PATH"
out=$(machine setup box "$RROOT")
assert_contains "$out" "step deck=done:" "setup skipped rustup Deck build"
out=$(remote install-deck "$RROOT" https://github.com/bastotec/deck.git)
assert_contains "$out" "result=done:" "same-origin Deck cache was refused"
assert_equals 'deck 0.1' "$("$FAKE_ACCOUNT/.local/bin/deck" --version)" "replacement Deck does not run"
assert_equals '' "$(find "$FAKE_ACCOUNT/.local/bin" -name 'deck.prev-*' -o -name '.deck.new.*')" "Deck replacement left persistent backups or staging files"
pass "rustup builds resolve cargo without changing worker runtime lookups or leaving backups"

new_account
git -C "$NETFM" remote set-url origin https://user:ORIGIN-TOKEN@example.com/acme/firstmate.git
printf 'http://HUB-TOKEN@127.0.0.1:7717\n' > "$FMH/config/stream-hub"
set +e
out=$(FM_MACHINE_GATEWAY_URL=http://user:GATEWAY-TOKEN@127.0.0.1:8329/v1 FM_DECK_REPO_URL=https://DECK-TOKEN@example.com/deck.git machine check box "$RROOT" 2>&1)
rc=$?
set -e
expect_code 1 "$rc" "credential-bearing checklist"
assert_contains "$out" 'setup clones https://[redacted]@example.com/acme/firstmate.git' "clone URL presentation"
assert_contains "$out" 'http://[redacted]@127.0.0.1:8329/v1 answers' "gateway URL presentation"
assert_contains "$out" 'http://[redacted]@127.0.0.1:7717 answers' "hub URL presentation"
assert_contains "$out" 'setup builds https://[redacted]@example.com/deck.git' "Deck URL presentation"
for secret in ORIGIN-TOKEN HUB-TOKEN GATEWAY-TOKEN DECK-TOKEN; do
  assert_not_contains "$out" "$secret" "check exposed URL credentials"
done
out=$(machine setup box "$RROOT" 2>&1)
assert_contains "$out" 'step firstmate-clone=done: cloned https://[redacted]@example.com/acme/firstmate.git' "setup clone presentation"
assert_not_contains "$out" ORIGIN-TOKEN "setup exposed origin credentials"
new_account
set +e
out=$(FAKE_CLONE_FAIL=1 machine setup box "$RROOT" 2>&1)
rc=$?
set -e
expect_code 1 "$rc" "credential-bearing clone failure"
assert_contains "$out" 'fatal: cannot clone https://[redacted]@example.com/acme/firstmate.git' "clone diagnostic presentation"
assert_not_contains "$out" ORIGIN-TOKEN "clone diagnostic exposed origin credentials"
set +e
out=$(FAKE_CLONE_FAIL=1 remote install-deck "$RROOT" https://DECK-TOKEN@example.com/deck.git 2>&1)
rc=$?
set -e
expect_code 1 "$rc" "credential-bearing direct Deck failure"
assert_contains "$out" 'git clone of https://[redacted]@example.com/deck.git failed' "Deck failure presentation"
assert_not_contains "$out" DECK-TOKEN "direct Deck failure exposed credentials"
git -C "$NETFM" remote set-url origin 'https://user:REFUSAL-TOKEN@example.com/invalid!'
set +e
out=$(machine prepare box "$RROOT" 2>&1)
rc=$?
set -e
expect_code 1 "$rc" "credential-bearing URL refusal"
assert_contains "$out" 'refuse:' "unsafe URL was not refused"
assert_not_contains "$out" REFUSAL-TOKEN "refusal exposed credentials"
pass "machine output redacts URL userinfo in facts, success, failure, diagnostics and refusals"

echo "ALL TESTS PASSED"
