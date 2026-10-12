#!/usr/bin/env bash
# Behavior tests for the gateway tunnels in bin/fm-machine.sh (check items and
# the `tunnels` steps setup also runs) and bin/fm-machine-remote.sh
# install-tunnel. ssh is a stub: -G reads a scratch config, and remote commands
# run locally as a scratch machine account (alias box) or a scratch gateway
# account (alias gw). launchctl, systemctl, uname, ssh-keygen and curl on the
# machine are stubs too, so no real service or account key is touched.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(fm_test_tmproot fm-machine-tunnels)
FAKEBIN=$(fm_fakebin "$T")
FMH="$T/home"
mkdir -p "$FMH/data" "$FMH/config"
read -r GATEWAY_PORT HUB_PORT < <(python3 - <<'PY'
import socket
with socket.socket() as gateway, socket.socket() as hub:
    gateway.bind(('127.0.0.1', 0))
    hub.bind(('127.0.0.1', 0))
    print(gateway.getsockname()[1], hub.getsockname()[1])
PY
)
export GATEWAY_PORT HUB_PORT
GATEWAY_URL="http://127.0.0.1:$GATEWAY_PORT/v1"
HUB_URL="http://127.0.0.1:$HUB_PORT"
printf '%s\n' "$HUB_URL" > "$FMH/config/stream-hub"
export FAKE_PYTHON="$(command -v python3)" FAKE_SERVICE_PARSER="$T/service.py"
listener_pid=
cleanup() {
  if [ -n "$listener_pid" ]; then
    kill "$listener_pid" 2>/dev/null || true
    wait "$listener_pid" 2>/dev/null || true
  fi
  fm_test_cleanup
}
trap cleanup EXIT
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
HOME="$account" USER=captain PATH="$FAKE_RBIN:/usr/bin:/bin" exec sh -c "$*"
SH
chmod +x "$FAKEBIN/ssh"
export PATH="$FAKEBIN:$PATH"

cat > "$FAKE_SERVICE_PARSER" <<'PY'
import configparser
import os
import plistlib
import shlex
import sys

kind, path, label = sys.argv[1:]
port = os.environ['GATEWAY_PORT' if label == 'dev.firstmate.proxai-tunnel' else 'HUB_PORT']
home = os.environ['FAKE_BOX']
expected = [
    '/usr/bin/ssh', '-N', '-i', home + '/.ssh/fm_workload_tunnel',
    '-o', 'IdentitiesOnly=yes', '-o', 'IdentityAgent=none',
    '-o', 'UserKnownHostsFile=' + home + '/.ssh/fm_workload_known_hosts',
    '-o', 'StrictHostKeyChecking=yes', '-o', 'BatchMode=yes',
    '-o', 'ExitOnForwardFailure=yes', '-o', 'ServerAliveInterval=15',
    '-o', 'ServerAliveCountMax=3',
    '-L', f'127.0.0.1:{port}:127.0.0.1:{port}', 'keeper@gw.lan',
]
if kind == 'launchd':
    with open(path, 'rb') as file:
        service = plistlib.load(file)
    assert service['Label'] == label, service
    assert service['KeepAlive'] is True, service
    assert service['RunAtLoad'] is True, service
    args = service['ProgramArguments']
else:
    service = configparser.ConfigParser(interpolation=None)
    with open(path) as file:
        service.read_file(file)
    assert service['Service']['Restart'] == 'always', dict(service['Service'])
    assert service['Install']['WantedBy'] == 'default.target', dict(service['Install'])
    args = shlex.split(service['Service']['ExecStart'])
assert args == expected, args
print(port)
PY

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
set -eu
printf 'launchctl %s\n' "$*" >> "$FAKE_LOG"
case "$1" in
  print) [ -f "$HOME/loaded-${2##*/}" ] ;;
  bootout) rm -f "$HOME/loaded-${2##*/}" ;;
  bootstrap)
    label=$(basename "$3" .plist)
    port=$("$FAKE_PYTHON" "$FAKE_SERVICE_PARSER" launchd "$3" "$label")
    : > "$HOME/loaded-$label"
    : > "$HOME/up-$port" ;;
esac
TOOL
  cat > "$FAKE_RBIN/systemctl" <<'TOOL'
#!/bin/sh
set -eu
printf 'systemctl %s\n' "$*" >> "$FAKE_LOG"
case "$2" in
  is-active) [ -f "$HOME/loaded-${4%.service}" ] ;;
  restart)
    label=${3%.service}
    port=$("$FAKE_PYTHON" "$FAKE_SERVICE_PARSER" systemd "$HOME/.config/systemd/user/$3" "$label")
    : > "$HOME/loaded-$label"
    : > "$HOME/up-$port" ;;
esac
TOOL
  cat > "$FAKE_RBIN/loginctl" <<'TOOL'
#!/bin/sh
[ "$*" = 'show-user captain -p Linger' ] || exit 1
printf 'Linger=%s\n' "${FAKE_LINGER:-yes}"
TOOL
  cat > "$FAKE_RBIN/curl" <<'TOOL'
#!/bin/sh
for url; do :; done
port=$(printf '%s' "$url" | sed -n 's|^http://127.0.0.1:\([0-9]*\).*|\1|p')
if [ ! -f "$HOME/up-$port" ]; then printf 000; exit 7; fi
case "$*" in
  *' -K -'*)
    if grep -q 'Authorization: Bearer SECRET-GATEWAY-KEY'; then printf 200; else printf 401; fi ;;
  *) printf 401 ;;
esac
TOOL
  chmod +x "$FAKE_RBIN"/*
}

machine() { FM_HOME="$FMH" FM_MACHINE_GATEWAY_URL="$GATEWAY_URL" "$ROOT/bin/fm-machine.sh" "$@"; }
remote() { HOME="$FAKE_BOX" USER=captain PATH="$FAKE_RBIN:/usr/bin:/bin" "$ROOT/bin/fm-machine-remote.sh" "$@"; }

start_listener() {
  rm -f "$T/listener-ready"
  "$FAKE_PYTHON" - "$GATEWAY_PORT" "$T/listener-ready" <<'PY' &
import pathlib
import socket
import sys
with socket.socket() as listener:
    listener.bind(('127.0.0.1', int(sys.argv[1])))
    listener.listen()
    pathlib.Path(sys.argv[2]).touch()
    while True:
        connection, _ = listener.accept()
        connection.close()
PY
  listener_pid=$!
  for _ in {1..100}; do
    [ ! -f "$T/listener-ready" ] || return 0
    kill -0 "$listener_pid" 2>/dev/null || fail "listener failed to bind"
    sleep 0.02
  done
  fail "listener did not become ready"
}

stop_listener() {
  kill "$listener_pid"
  wait "$listener_pid" 2>/dev/null || true
  listener_pid=
}

# --- check: without config the forwards are the captain's; with it, setup's ---
new_world
out=$(machine check box) || true
assert_contains "$out" "item model-gateway=human: make $GATEWAY_URL answer" "no config keeps the gateway human"
assert_contains "$out" "item stream-hub=human: make $HUB_URL reachable" "no config keeps the hub human"
printf 'gateway=gw\n' > "$FMH/config/machine-tunnels"
out=$(machine check box) || true
assert_contains "$out" "item model-gateway=will-install: setup installs it: dev.firstmate.proxai-tunnel" "config makes the gateway setup's"
assert_contains "$out" "item stream-hub=will-install: setup installs it: dev.firstmate.stream-hub-tunnel" "config makes the hub setup's"
assert_absent "$FAKE_BOX/.ssh/fm_workload_tunnel" "check made a tunnel key"
pass "check offers the forwards to setup only when this home names the gateway host"

# --- tunnels on a new macOS machine ---
printf 'ssh-ed25519 AAAAOTHER comment-with-AAAATUNNELKEY' > "$T/original-keys"
cp "$T/original-keys" "$FAKE_GW/.ssh/authorized_keys"
out=$(machine tunnels box) || fail "tunnels failed: $out"
assert_contains "$out" "step tunnel-key=done:" "key step"
assert_contains "$out" "step tunnel-authorize=done: authorized to forward only 127.0.0.1:$GATEWAY_PORT 127.0.0.1:$HUB_PORT" "authorize step"
assert_contains "$out" "step tunnel-gateway=done: dev.firstmate.proxai-tunnel forwards 127.0.0.1:$GATEWAY_PORT; $GATEWAY_URL/models answers 200 with the client key" "gateway verified with the key"
assert_contains "$out" "step tunnel-hub=done: dev.firstmate.stream-hub-tunnel forwards 127.0.0.1:$HUB_PORT; $HUB_URL answers" "hub verified"
assert_contains "$out" "tunnels=complete" "verdict"
assert_not_contains "$out" "SECRET-GATEWAY-KEY" "the client key was printed"
assert_grep 'ssh-keygen -q -t ed25519 -N  -C fm-tunnel@box -f '"$FAKE_BOX"'/.ssh/fm_workload_tunnel' "$FAKE_LOG" "key made as specified"
assert_equals "gw.lan ssh-ed25519 $GW_KEY" "$(cat "$FAKE_BOX/.ssh/fm_workload_known_hosts")" "gateway host key pinned from this machine's trust"
authorization="restrict,port-forwarding,permitopen=\"127.0.0.1:$GATEWAY_PORT\",permitopen=\"127.0.0.1:$HUB_PORT\",command=\"/bin/false\" ssh-ed25519 AAAATUNNELKEY fm-tunnel@box"
assert_equals "$authorization" \
  "$(tail -n 1 "$FAKE_GW/.ssh/authorized_keys")" "restricted key line"
cmp -s "$T/original-keys" "$FAKE_GW"/.ssh/authorized_keys.fm-backup-* || fail "backup changed the unterminated original"
assert_equals 'ssh-ed25519 AAAAOTHER comment-with-AAAATUNNELKEY' "$(head -n 1 "$FAKE_GW/.ssh/authorized_keys")" "original key remains on its own line"
assert_equals 2 "$(wc -l < "$FAKE_GW/.ssh/authorized_keys" | tr -d ' ')" "new key has its own terminated line"
plist="$FAKE_BOX/Library/LaunchAgents/dev.firstmate.proxai-tunnel.plist"
assert_present "$plist" "gateway service installed"
assert_equals "$GATEWAY_PORT" "$("$FAKE_PYTHON" "$FAKE_SERVICE_PARSER" launchd "$plist" dev.firstmate.proxai-tunnel)" "launchd gateway service semantics"
assert_present "$FAKE_BOX/Library/LaunchAgents/dev.firstmate.stream-hub-tunnel.plist" "hub service installed"
pass "tunnels makes the key, pins the host, authorizes it narrowly and installs verified services"

# --- rerun: live forwards are left alone; a reboot reloads without re-authorizing ---
: > "$FAKE_LOG"
out=$(machine tunnels box) || fail "rerun failed: $out"
assert_contains "$out" "step tunnel-gateway=skipped: $GATEWAY_URL already answers" "live gateway left alone"
assert_contains "$out" "step tunnel-hub=skipped: $HUB_URL already answers" "live hub left alone"
assert_no_grep 'launchctl' "$FAKE_LOG" "a live service was touched"
rm -f "$FAKE_BOX"/up-* "$FAKE_BOX"/loaded-*
out=$(machine tunnels box) || fail "reload failed: $out"
assert_contains "$out" "step tunnel-authorize=skipped: the tunnel key is already authorized" "no second authorization"
assert_equals 1 "$(grep -c 'ssh-ed25519 AAAATUNNELKEY ' "$FAKE_GW/.ssh/authorized_keys")" "key appended once"
assert_contains "$out" "step tunnel-gateway=done:" "stopped service reloaded"
pass "tunnels is idempotent"

new_world
: > "$FAKE_BOX/up-$GATEWAY_PORT"
out=$(machine tunnels box) || fail "partial setup failed: $out"
assert_equals "$authorization" "$(cat "$FAKE_GW/.ssh/authorized_keys")" "partial setup authorizes both eligible ports"
assert_absent "$FAKE_BOX/Library/LaunchAgents/dev.firstmate.proxai-tunnel.plist" "already answering gateway was touched"
rm -f "$FAKE_BOX/up-$GATEWAY_PORT"
out=$(machine tunnels box) || fail "later gateway setup failed: $out"
assert_contains "$out" 'step tunnel-authorize=skipped:' "existing authorization covers the later gateway install"
assert_present "$FAKE_BOX/Library/LaunchAgents/dev.firstmate.proxai-tunnel.plist" "later gateway service missing"
pass "partial setup authorizes every eligible port without touching answering endpoints"

new_world
printf 'ssh-ed25519 AAAAOTHER someone AAAATUNNELKEY\ncommand="/bin/echo old",permitopen="127.0.0.1:%s" ssh-ed25519 AAAATUNNELKEY fm-tunnel@box\n' "$HUB_PORT" > "$T/old-authorization"
cp "$T/old-authorization" "$FAKE_GW/.ssh/authorized_keys"
out=$(machine tunnels box) || fail "authorization update failed: $out"
assert_contains "$out" 'step tunnel-authorize=done:' "old authorization updated"
assert_equals "$authorization" "$(tail -n 1 "$FAKE_GW/.ssh/authorized_keys")" "options replaced with both ports"
assert_equals 'ssh-ed25519 AAAAOTHER someone AAAATUNNELKEY' "$(head -n 1 "$FAKE_GW/.ssh/authorized_keys")" "comment containing the blob is not a key match"
assert_equals 2 "$(wc -l < "$FAKE_GW/.ssh/authorized_keys" | tr -d ' ')" "authorization replaced instead of duplicated"
cmp -s "$T/old-authorization" "$FAKE_GW"/.ssh/authorized_keys.fm-backup-* || fail "old authorization not backed up"
pass "setup replaces different key options and preserves unrelated keys"

# --- refusals ---
new_world
out=$(remote tunnel-key box)
assert_contains "$out" "pubkey=ssh-ed25519 AAAATUNNELKEY fm-tunnel@box" "tunnel-key prints the public key"
start_listener
for platform in Darwin Linux; do
  for existing in absent present; do
    unit="$FAKE_BOX/Library/LaunchAgents/dev.firstmate.proxai-tunnel.plist"
    [ "$platform" != Linux ] || unit="$FAKE_BOX/.config/systemd/user/dev.firstmate.proxai-tunnel.service"
    if [ "$existing" = present ]; then
      mkdir -p "$(dirname "$unit")"
      printf 'existing stopped unit\n' > "$unit"
    fi
    : > "$FAKE_LOG"
    set +e
    out=$(FAKE_UNAME="$platform" remote install-tunnel dev.firstmate.proxai-tunnel "$GATEWAY_PORT" keeper gw.lan 22 "gw.lan ssh-ed25519 $GW_KEY" "$GATEWAY_URL" gateway)
    rc=$?
    set -e
    expect_code 1 "$rc" "install over a TCP-only listener ($platform, $existing unit)"
    assert_contains "$out" "result=failed: 127.0.0.1:$GATEWAY_PORT is already taken by something else" "taken port refused"
    if [ "$existing" = present ]; then
      assert_equals 'existing stopped unit' "$(cat "$unit")" "existing file overwritten"
    else
      assert_absent "$unit" "service written over a taken port"
    fi
    assert_no_grep 'bootstrap\|bootout\|daemon-reload\|enable\|restart' "$FAKE_LOG" "occupied port service loaded"
  done
  rm -f "$unit"
done
: > "$FAKE_BOX/loaded-dev.firstmate.proxai-tunnel"
out=$(remote install-tunnel dev.firstmate.proxai-tunnel "$GATEWAY_PORT" keeper gw.lan 22 "gw.lan ssh-ed25519 $GW_KEY" "$GATEWAY_URL" gateway) || fail "loaded tunnel rejected: $out"
assert_contains "$out" 'result=done:' "loaded service owns the listening port"
out=$(FAKE_UNAME=Linux remote install-tunnel dev.firstmate.proxai-tunnel "$GATEWAY_PORT" keeper gw.lan 22 "gw.lan ssh-ed25519 $GW_KEY" "$GATEWAY_URL" gateway) || fail "active tunnel rejected: $out"
assert_contains "$out" 'result=done:' "active systemd service owns the listening port"
stop_listener
printf 'gw.lan ssh-ed25519 AAAADIFFERENT\n' > "$FAKE_BOX/.ssh/fm_workload_known_hosts"
set +e
out=$(remote install-tunnel dev.firstmate.proxai-tunnel "$GATEWAY_PORT" keeper gw.lan 22 "gw.lan ssh-ed25519 $GW_KEY" "$GATEWAY_URL" gateway)
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
set +e
out=$(FAKE_UNAME=Linux FAKE_LINGER=no machine tunnels box)
rc=$?
set -e
expect_code 1 "$rc" "Linux without lingering"
assert_contains "$out" 'run sudo loginctl enable-linger captain on the machine, then rerun setup' "persistent user manager prerequisite"
assert_absent "$FAKE_BOX/.config/systemd/user" "unit installed without lingering"
assert_absent "$FAKE_BOX/.ssh/fm_workload_known_hosts" "pin installed without lingering"
assert_no_grep 'systemctl' "$FAKE_LOG" "service manager mutated without lingering"
pass "Linux refuses tunnel installation until the account has lingering enabled"

out=$(FAKE_UNAME=Linux machine tunnels box) || fail "linux tunnels failed: $out"
unit="$FAKE_BOX/.config/systemd/user/dev.firstmate.proxai-tunnel.service"
assert_present "$unit" "systemd unit installed"
assert_equals "$GATEWAY_PORT" "$("$FAKE_PYTHON" "$FAKE_SERVICE_PARSER" systemd "$unit" dev.firstmate.proxai-tunnel)" "systemd gateway service semantics"
assert_equals "$HUB_PORT" "$("$FAKE_PYTHON" "$FAKE_SERVICE_PARSER" systemd "$FAKE_BOX/.config/systemd/user/dev.firstmate.stream-hub-tunnel.service" dev.firstmate.stream-hub-tunnel)" "systemd hub service semantics"
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
