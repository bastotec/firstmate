#!/usr/bin/env bash
# Behavior tests for the gateway tunnels in bin/fm-machine.sh (check items and
# the `tunnels` steps setup also runs) and bin/fm-machine-remote.sh
# install-tunnel. ssh is a stub: -G reads a scratch config, and remote commands
# run locally as a scratch machine account (alias box) or a scratch gateway
# account (alias gw). launchctl, systemctl, uname, ssh-keygen and curl on the
# machine are stubs too, so no real service, key or port is touched.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(fm_test_tmproot fm-machine-tunnels)
FAKEBIN=$(fm_fakebin "$T")
FMH="$T/home"
mkdir -p "$FMH/data" "$FMH/config"
printf 'http://127.0.0.1:7717\n' > "$FMH/config/stream-hub"
export FM_SSH_CONFIG="$T/ssh_config" FM_KNOWN_HOSTS="$T/known_hosts"
export FAKE_BOX="$T/box" FAKE_GW="$T/gw" FAKE_RBIN="$T/rbin" FAKE_LOG="$T/remote.log"
REAL_SSH=$(command -v ssh)
export REAL_SSH
cat > "$FM_SSH_CONFIG" <<'CFG'
Host box
  HostName box.lan
  User captain

Host gw
  HostName gw.lan
  User keeper
CFG
ssh-keygen -q -t ed25519 -N '' -C gw -f "$T/gw_host_key"
GW_KEY=$(awk '{ print $2 }' "$T/gw_host_key.pub")
printf 'box.lan ssh-ed25519 AAAAKEYBOX\ngw.lan ssh-ed25519 %s\n' "$GW_KEY" > "$FM_KNOWN_HOSTS"

cat > "$FAKEBIN/ssh" <<'SH'
#!/usr/bin/env bash
G=0
CONFIG=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -G) G=1; shift ;;
    -F) CONFIG=$2; shift 2 ;;
    -o|-p) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
alias=$1
shift
[ "$G" -eq 0 ] || exec "$REAL_SSH" -F "$CONFIG" -G "$alias"
[ "$1" != true ] || exit 0
case "$alias" in
  box) account=$FAKE_BOX ;;
  gw) account=$FAKE_GW ;;
  *) exit 255 ;;
esac
printf 'ssh %s %s\n' "$alias" "${1%% *}" >> "$FAKE_LOG"
cd "$account" || exit 255
HOME="$account" PATH="$FAKE_RBIN:/usr/bin:/bin" exec sh -c "$*"
SH
chmod +x "$FAKEBIN/ssh"
export PATH="$FAKEBIN:$PATH"

# The machine's tools. A service that loads marks its forwarded port as up;
# curl answers a port that is up (or FAKE_TAKEN_<port>), and the gateway's
# /models answers 200 only with a bearer header from the key file.
new_world() {
  rm -rf "$FAKE_BOX" "$FAKE_GW" "$FAKE_RBIN"
  mkdir -p "$FAKE_BOX/.config/proxai" "$FAKE_GW/.ssh" "$FAKE_RBIN"
  printf 'SECRET-GATEWAY-KEY\n' > "$FAKE_BOX/.config/proxai/client.key"
  chmod 600 "$FAKE_BOX/.config/proxai/client.key"
  : > "$FAKE_LOG"
  for tool in jq python3 node; do printf '#!/bin/sh\nexit 0\n' > "$FAKE_RBIN/$tool"; done
  cat > "$FAKE_RBIN/uname" <<'TOOL'
#!/bin/sh
echo "${FAKE_UNAME:-Darwin}"
TOOL
  cat > "$FAKE_RBIN/id" <<'TOOL'
#!/bin/sh
echo 501
TOOL
  cat > "$FAKE_RBIN/ssh-keygen" <<'TOOL'
#!/bin/sh
for f; do :; done
printf 'PRIVATE\n' > "$f"
printf 'ssh-ed25519 AAAATUNNELKEY fm-tunnel@box\n' > "$f.pub"
printf 'ssh-keygen %s\n' "$*" >> "$FAKE_LOG"
TOOL
  cat > "$FAKE_RBIN/launchctl" <<'TOOL'
#!/bin/sh
printf 'launchctl %s\n' "$*" >> "$FAKE_LOG"
case "$1" in
  print) [ -f "$HOME/loaded-${2##*/}" ] ;;
  bootout) rm -f "$HOME/loaded-${2##*/}" ;;
  bootstrap)
    label=$(basename "$3" .plist)
    : > "$HOME/loaded-$label"
    port=$(grep -o '127.0.0.1:[0-9]*:127' "$3" | head -n 1 | cut -d: -f2)
    : > "$HOME/up-$port" ;;
esac
TOOL
  cat > "$FAKE_RBIN/systemctl" <<'TOOL'
#!/bin/sh
printf 'systemctl %s\n' "$*" >> "$FAKE_LOG"
case "$2" in
  is-active) [ -f "$HOME/loaded-${4%.service}" ] ;;
  restart)
    : > "$HOME/loaded-${3%.service}"
    port=$(grep -o '127.0.0.1:[0-9]*:127' "$HOME/.config/systemd/user/$3" | head -n 1 | cut -d: -f2)
    : > "$HOME/up-$port" ;;
esac
TOOL
  cat > "$FAKE_RBIN/curl" <<'TOOL'
#!/bin/sh
for url; do :; done
port=$(printf '%s' "$url" | sed -n 's|^http://127.0.0.1:\([0-9]*\).*|\1|p')
eval taken=\${FAKE_TAKEN_$port:-}
if [ ! -f "$HOME/up-$port" ] && [ -z "$taken" ]; then printf 000; exit 7; fi
case "$*" in
  *' -K -'*)
    if grep -q 'Authorization: Bearer SECRET-GATEWAY-KEY'; then printf 200; else printf 401; fi ;;
  *) printf 401 ;;
esac
TOOL
  chmod +x "$FAKE_RBIN"/*
}

machine() { FM_HOME="$FMH" FM_MACHINE_GATEWAY_URL=http://127.0.0.1:8329/v1 "$ROOT/bin/fm-machine.sh" "$@"; }
remote() { HOME="$FAKE_BOX" PATH="$FAKE_RBIN:/usr/bin:/bin" FM_TUNNEL_WAIT_TRIES=1 "$ROOT/bin/fm-machine-remote.sh" "$@"; }

# --- check: without config the forwards are the captain's; with it, setup's ---
new_world
out=$(machine check box) || true
assert_contains "$out" "item model-gateway=human: make http://127.0.0.1:8329/v1 answer" "no config keeps the gateway human"
assert_contains "$out" "item stream-hub=human: make http://127.0.0.1:7717 reachable" "no config keeps the hub human"
printf 'gateway=gw\n' > "$FMH/config/machine-tunnels"
out=$(machine check box) || true
assert_contains "$out" "item model-gateway=will-install: setup installs it: dev.firstmate.proxai-tunnel" "config makes the gateway setup's"
assert_contains "$out" "item stream-hub=will-install: setup installs it: dev.firstmate.stream-hub-tunnel" "config makes the hub setup's"
assert_absent "$FAKE_BOX/.ssh/fm_workload_tunnel" "check made a tunnel key"
pass "check offers the forwards to setup only when this home names the gateway host"

# --- tunnels on a new macOS machine ---
printf 'ssh-ed25519 AAAAOTHER someone\n' > "$FAKE_GW/.ssh/authorized_keys"
out=$(machine tunnels box) || fail "tunnels failed: $out"
assert_contains "$out" "step tunnel-key=done:" "key step"
assert_contains "$out" "step tunnel-authorize=done: authorized to forward only 127.0.0.1:8329 127.0.0.1:7717" "authorize step"
assert_contains "$out" "step tunnel-gateway=done: dev.firstmate.proxai-tunnel forwards 127.0.0.1:8329; http://127.0.0.1:8329/v1/models answers 200 with the client key" "gateway verified with the key"
assert_contains "$out" "step tunnel-hub=done: dev.firstmate.stream-hub-tunnel forwards 127.0.0.1:7717; http://127.0.0.1:7717 answers" "hub verified"
assert_contains "$out" "tunnels=complete" "verdict"
assert_not_contains "$out" "SECRET-GATEWAY-KEY" "the client key was printed"
assert_grep 'ssh-keygen -q -t ed25519 -N  -C fm-tunnel@box -f '"$FAKE_BOX"'/.ssh/fm_workload_tunnel' "$FAKE_LOG" "key made as specified"
assert_equals "gw.lan ssh-ed25519 $GW_KEY" "$(cat "$FAKE_BOX/.ssh/fm_workload_known_hosts")" "gateway host key pinned from this machine's trust"
assert_equals 'restrict,port-forwarding,permitopen="127.0.0.1:8329",permitopen="127.0.0.1:7717",command="/bin/false" ssh-ed25519 AAAATUNNELKEY fm-tunnel@box' \
  "$(tail -n 1 "$FAKE_GW/.ssh/authorized_keys")" "restricted key line"
assert_equals 'ssh-ed25519 AAAAOTHER someone' "$(cat "$FAKE_GW"/.ssh/authorized_keys.fm-backup-*)" "authorized_keys backed up first"
plist="$FAKE_BOX/Library/LaunchAgents/dev.firstmate.proxai-tunnel.plist"
assert_present "$plist" "gateway service installed"
args=$(sed -n 's|^ *<string>\(.*\)</string>$|\1|p' "$plist" | tr '\n' ' ')
assert_equals "/usr/bin/ssh -N -i $FAKE_BOX/.ssh/fm_workload_tunnel -o IdentitiesOnly=yes -o IdentityAgent=none -o UserKnownHostsFile=$FAKE_BOX/.ssh/fm_workload_known_hosts -o StrictHostKeyChecking=yes -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -o ServerAliveCountMax=3 -L 127.0.0.1:8329:127.0.0.1:8329 keeper@gw.lan " \
  "$args" "service runs the exact ssh forward"
assert_grep '<key>KeepAlive</key><true/>' "$plist" "service is kept alive"
assert_present "$FAKE_BOX/Library/LaunchAgents/dev.firstmate.stream-hub-tunnel.plist" "hub service installed"
pass "tunnels makes the key, pins the host, authorizes it narrowly and installs verified services"

# --- rerun: live forwards are left alone; a reboot reloads without re-authorizing ---
: > "$FAKE_LOG"
out=$(machine tunnels box) || fail "rerun failed: $out"
assert_contains "$out" "step tunnel-gateway=skipped: http://127.0.0.1:8329/v1 already answers" "live gateway left alone"
assert_contains "$out" "step tunnel-hub=skipped: http://127.0.0.1:7717 already answers" "live hub left alone"
assert_no_grep 'launchctl' "$FAKE_LOG" "a live service was touched"
rm -f "$FAKE_BOX"/up-* "$FAKE_BOX"/loaded-*
out=$(machine tunnels box) || fail "reload failed: $out"
assert_contains "$out" "step tunnel-authorize=skipped: the tunnel key is already authorized" "no second authorization"
assert_equals 1 "$(grep -c AAAATUNNELKEY "$FAKE_GW/.ssh/authorized_keys")" "key appended once"
assert_contains "$out" "step tunnel-gateway=done:" "stopped service reloaded"
pass "tunnels is idempotent"

# --- refusals ---
new_world
out=$(remote tunnel-key box)
assert_contains "$out" "pubkey=ssh-ed25519 AAAATUNNELKEY fm-tunnel@box" "tunnel-key prints the public key"
set +e
out=$(FAKE_TAKEN_8329=1 remote install-tunnel dev.firstmate.proxai-tunnel 8329 keeper gw.lan 22 "gw.lan ssh-ed25519 $GW_KEY" http://127.0.0.1:8329/v1 gateway)
rc=$?
set -e
expect_code 1 "$rc" "install over a taken port"
assert_contains "$out" "result=failed: 127.0.0.1:8329 is already taken by something else" "taken port refused"
assert_absent "$FAKE_BOX/Library/LaunchAgents/dev.firstmate.proxai-tunnel.plist" "service written over a taken port"
printf 'gw.lan ssh-ed25519 AAAADIFFERENT\n' > "$FAKE_BOX/.ssh/fm_workload_known_hosts"
set +e
out=$(remote install-tunnel dev.firstmate.proxai-tunnel 8329 keeper gw.lan 22 "gw.lan ssh-ed25519 $GW_KEY" http://127.0.0.1:8329/v1 gateway)
rc=$?
set -e
expect_code 1 "$rc" "install over a different pin"
assert_contains "$out" "already pins a different key" "different pin refused"
pass "install-tunnel refuses a taken port and a different host pin"

new_world
printf 'box.lan ssh-ed25519 AAAAKEYBOX\n' > "$FM_KNOWN_HOSTS"
set +e
out=$(machine tunnels box)
rc=$?
set -e
expect_code 1 "$rc" "tunnels with no trusted gateway key"
assert_contains "$out" "step tunnel-key=failed: this machine trusts no ed25519 host key for gw.lan" "trust on first use refused"
assert_absent "$FAKE_GW/.ssh/authorized_keys" "gateway host touched without a pin"
printf 'box.lan ssh-ed25519 AAAAKEYBOX\ngw.lan ssh-ed25519 %s\n' "$GW_KEY" > "$FM_KNOWN_HOSTS"
pass "tunnels never trusts the gateway host on first use"

# --- Linux: systemd --user ---
new_world
out=$(FAKE_UNAME=Linux machine tunnels box) || fail "linux tunnels failed: $out"
unit="$FAKE_BOX/.config/systemd/user/dev.firstmate.proxai-tunnel.service"
assert_present "$unit" "systemd unit installed"
exec_line=$(grep '^ExecStart=' "$unit")
assert_contains "$exec_line" "ExecStart=/usr/bin/ssh -N -i $FAKE_BOX/.ssh/fm_workload_tunnel -o IdentitiesOnly=yes" "unit runs ssh with the tunnel key"
assert_contains "$exec_line" "-L 127.0.0.1:8329:127.0.0.1:8329 keeper@gw.lan" "unit forwards the gateway port"
assert_grep 'Restart=always' "$unit" "unit restarts"
assert_grep 'systemctl --user enable dev.firstmate.proxai-tunnel.service' "$FAKE_LOG" "unit enabled"
assert_contains "$out" "tunnels=complete" "linux verdict"
pass "tunnels uses systemd --user services on Linux"

rm -f "$FMH/config/machine-tunnels"
set +e
out=$(machine tunnels box)
rc=$?
set -e
expect_code 1 "$rc" "tunnels without config"
assert_contains "$out" "refuse: this home has no config/machine-tunnels" "tunnels needs the config"
pass "tunnels refuses without config/machine-tunnels"
