#!/usr/bin/env bash
# Behavior tests for bin/fm-machine.sh: check classification, add and trust
# refusals, prepare composition, and register idempotence. ssh, ssh-keyscan and
# ssh-keygen are stubs on PATH, and FM_SSH_CONFIG / FM_KNOWN_HOSTS point at
# scratch files, so no real machine or ~/.ssh is ever touched.
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
: > "$SSH_LOG"
cat > "$FM_SSH_CONFIG" <<'CFG'
Host *
  ServerAliveInterval 30

Host box
  HostName box.lan
  User captain
CFG
printf 'box.lan ssh-ed25519 AAAAKEYBOX\n' > "$FM_KNOWN_HOSTS"

# ssh stub: -G reads the scratch config; "true" answers per FAKE_SSH_REACH;
# "sh -s" answers the PATH probe or the prepare script; the fixed entrypoint
# answers like a remote doctor.
cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
G=0
CONFIG=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -G) G=1; shift ;;
    -F) CONFIG=$2; shift 2 ;;
    -o|-p) shift 2 ;;
    --) shift; break ;;
    -*) shift ;;
    *) break ;;
  esac
done
alias=$1
shift
if [ "$G" -eq 1 ]; then
  host=$(awk -v a="$alias" '$1 == "Host" { inblk = ($2 == a) } inblk && $1 == "HostName" { print $2; exit }' "$CONFIG")
  user=$(awk -v a="$alias" '$1 == "Host" { inblk = ($2 == a) } inblk && $1 == "User" { print $2; exit }' "$CONFIG")
  printf 'user %s\nhostname %s\nport 22\n' "${user:-me}" "$(printf '%s' "${host:-$alias}" | tr '[:upper:]' '[:lower:]')"
  exit 0
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
  sh)
    cat > /dev/null
    if [ "${2:-}" = -s ] && [ "${3:-}" = -- ]; then
      printf 'prepare root=%s url=%s\n' "$4" "$5" >> "$FAKE_SSH_LOG"
      printf 'account-home=/home/captain\nclone=created\nentrypoint-link=created: %s/bin/fm-remote-entrypoint.sh\n' "$4"
      exit 0
    fi
    printf 'tool fm-remote-entrypoint.sh=/home/captain/.local/bin/fm-remote-entrypoint.sh\n'
    printf 'tool deck=%s\n' "${FAKE_DECK:-/usr/local/bin/deck}"
    printf 'tool proxai=/usr/local/bin/proxai\n'
    ;;
  fm-remote-entrypoint.sh)
    printf 'entrypoint root=%s home=%s argv=%s\n' "$(printf '%s' "$3" | base64 -d)" "$(printf '%s' "$4" | base64 -d)" \
      "$(printf '%s' "$5" | base64 -d | tr '\0' ' ')" >> "$FAKE_SSH_LOG"
    printf 'mode=fix\ncheck stream-tools=ok: fake\n'
    exit "${FAKE_DOCTOR_RC:-0}"
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

machine() { FM_HOME="$FMH" "$ROOT/bin/fm-machine.sh" "$@"; }

# --- check ---
out=$(machine check box)
assert_contains "$out" "check alias=ok: box resolves to box.lan as captain on port 22" "alias ok"
assert_contains "$out" "check hostkey=ok: box.lan is known as SHA256:FPAAAAKEYBOX" "hostkey ok"
assert_contains "$out" "reach=ok" "reach ok"
assert_contains "$out" "check entrypoint=ok: /home/captain/.local/bin/fm-remote-entrypoint.sh" "entrypoint ok"
assert_contains "$out" "check deck=ok: /usr/local/bin/deck" "deck ok"
assert_contains "$out" "check proxai=ok: /usr/local/bin/proxai" "proxai ok"
assert_not_contains "$out" "action:" "an all-ok check printed an action"
pass "check reports a ready machine as ok and exits 0"

set +e
out=$(FAKE_DECK=missing machine check box)
rc=$?
set -e
expect_code 1 "$rc" "missing deck"
assert_contains "$out" "check deck=missing: deck is not on the non-interactive ssh PATH" "deck gap"
pass "check reports a missing tool as a gap"

set +e
out=$(FAKE_SSH_REACH=auth machine check newbox)
rc=$?
set -e
expect_code 1 "$rc" "unknown machine"
assert_contains "$out" "check alias=missing: no ssh config block sets a HostName for newbox" "alias missing"
assert_contains "$out" "action: bin/fm-machine.sh add newbox <address> <user>" "add action"
assert_contains "$out" "hostkey-fingerprint=SHA256:FPAAAAKEYNEW type=ED25519" "scanned fingerprint"
assert_contains "$out" "check hostkey=missing: newbox is not in $FM_KNOWN_HOSTS" "hostkey missing"
assert_contains "$out" "reach=auth" "auth class"
assert_contains "$out" "action: ssh-copy-id newbox" "auth action"
assert_not_contains "$out" "tool deck=" "tool probe ran without a connection"
assert_no_grep "newbox" "$FM_KNOWN_HOSTS" "check wrote a scanned key"
pass "check classifies a missing alias, an unknown key and refused key login"

set +e
out=$(FAKE_SSH_REACH=hostkey machine check box)
set -e
assert_contains "$out" "reach=hostkey" "hostkey class"
out=$(FAKE_SSH_REACH=timeout machine check box) || true
assert_contains "$out" "reach=timeout" "timeout class"
pass "check classifies host key and timeout failures"

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

NETFM="$T/net-fm"
fm_git_init_commit "$NETFM"
mkdir -p "$NETFM/bin"
cp "$ROOT/bin/fm-remote-doctor.sh" "$NETFM/bin/"
git -C "$NETFM" add bin/fm-remote-doctor.sh
git -C "$NETFM" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' commit -qm doctor
git -C "$NETFM" remote add origin https://example.com/acme/firstmate.git
: > "$SSH_LOG"
out=$(FM_ROOT_OVERRIDE="$NETFM" machine prepare box /srv/firstmate)
assert_contains "$out" "clone=created root=/srv/firstmate" "clone line"
assert_contains "$out" "entrypoint-link=created: /srv/firstmate/bin/fm-remote-entrypoint.sh" "link line"
assert_contains "$out" "doctor: check stream-tools=ok: fake" "doctor relayed"
assert_grep "prepare root=/srv/firstmate url=https://example.com/acme/firstmate.git" "$SSH_LOG" "prepare cloned from the wrong url"
assert_grep "entrypoint root=/srv/firstmate home=/home/captain/.firstmate-machine-probe argv=fm-remote-doctor.sh --backend stream --fix" "$SSH_LOG" "doctor was not run with --fix through the entrypoint"
assert_absent "$FMH/data/secondmates.md" "prepare left a route in the real registry"
set +e
out=$(FAKE_DOCTOR_RC=1 FM_ROOT_OVERRIDE="$NETFM" machine prepare box /srv/firstmate)
rc=$?
set -e
expect_code 1 "$rc" "prepare relays the doctor verdict"
pass "prepare clones, links and relays the doctor's --fix verdict"

echo "ALL TESTS PASSED"
