#!/usr/bin/env bash
# shellcheck disable=SC2016 # stub bodies expand when the stub runs.
# Behavior tests for bin/fm-machine-vnc.sh on a stub Linux machine: the
# password is generated once, kept private and never printed outside
# `connect`; install writes loopback-only, password-only units; a missing
# package is refused with the exact command; status reads loopback and the
# browser; links and settings are validated. Every tool is a stub on PATH and
# HOME is scratch, so nothing real is installed or started.
set -euo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

T=$(fm_test_tmproot fm-machine-vnc)
FAKEBIN=$(fm_fakebin "$T")
H="$T/home"
ACCT="$T/acct"
V="$ROOT/bin/fm-machine-vnc.sh"
LOG="$T/calls.log"
mkdir -p "$H/data" "$H/config" "$ACCT"
: > "$LOG"
export FAKE_LOG="$LOG" FAKE_LISTEN="127.0.0.1:5917"

stub() { printf '#!/usr/bin/env bash\n%s\n' "$2" > "$FAKEBIN/$1"; chmod +x "$FAKEBIN/$1"; }
stub uname 'echo Linux'
stub Xvnc 'echo "Xvnc TigerVNC 1.15"'
stub loginctl 'echo ${FAKE_LINGER:-yes}'
stub xauth 'f=; while [ $# -gt 0 ]; do case $1 in -f) f=$2; shift 2;; -q) shift;; list) [ -s "$f" ] && cat "$f"; exit 0;; add) printf "%s MIT-MAGIC-COOKIE-1 %s\n" "$2" "$4" >> "$f"; exit 0;; *) shift;; esac; done'
stub vncpasswd '[ "$1" = -f ] || exit 2; read -r p; printf "OBF:%s" "${#p}"'
stub google-chrome 'printf "chrome %s\n" "$*" >> "$FAKE_LOG"; exit ${FAKE_CHROME_RC:-0}'
stub systemctl 'printf "systemctl %s\n" "$*" >> "$FAKE_LOG"; case "$*" in *MainPID*) echo 4242 ;; esac; exit 0'
stub ss 'printf "LISTEN 0 5 %s 0.0.0.0:* users:((\"Xvnc\",pid=%s,fd=5))\n" $FAKE_LISTEN ${FAKE_PID:-4242}'
expect_code() { [ "$1" = "$2" ] || fail "$3: expected exit $1, got $2"; }
vnc() { PATH="$FAKEBIN:$PATH" HOME="$ACCT" FM_HOME="$H" FM_CONFIG_OVERRIDE="$H/config" "$V" "$@" 2>&1; }
file_mode() { python3 -c 'import os, stat, sys; print(format(stat.S_IMODE(os.stat(sys.argv[1]).st_mode), "o"))' "$1"; }

out=$(vnc install local)
PW=$(cat "$H/config/vnc/local.password")
[[ "$PW" =~ ^[A-Za-z0-9]{8}$ ]] || fail "the password is not 8 letters and digits"
assert_equals 600 "$(file_mode "$H/config/vnc/local.password")" "the kept password is private"
assert_not_contains "$out" "$PW" "install printed the password"
assert_contains "$out" "step vnc-service=done: dev.firstmate.vnc on 127.0.0.1:5917" "service step"
assert_equals "OBF:8" "$(cat "$ACCT/.config/firstmate/vnc/passwd")" "the machine keeps only the obfuscated form"
assert_equals 600 "$(file_mode "$ACCT/.config/firstmate/vnc/passwd")" "the machine's password file is private"
# The units as systemd reads them: the one uncommented ExecStart and its arguments.
unit_exec() { awk '/^[[:space:]]*#/ { next } /^ExecStart=/ { n++; sub(/^ExecStart=/, ""); line = $0 } END { if (n != 1) exit 1; print line }' "$1"; }
unit_env() { awk -v k="$2" '/^[[:space:]]*#/ { next } /^Environment=/ { sub(/^Environment=/, ""); if (index($0, k "=") == 1) v = substr($0, length(k) + 2) } END { print v }' "$1"; }
arg_after() { awk -v want="$2" '{ for (i = 1; i < NF; i++) if ($i == want) { print $(i + 1); exit } }' <<< "$1"; }
units="$ACCT/.config/systemd/user"
exec_line=$(unit_exec "$units/dev.firstmate.vnc.service") || fail "the VNC unit must have exactly one ExecStart"
[[ " $exec_line " == *" -localhost "* ]] || fail "Xvnc runs without -localhost"
assert_equals 5917 "$(arg_after "$exec_line" -rfbport)" "Xvnc's port"
assert_equals VncAuth "$(arg_after "$exec_line" -SecurityTypes)" "Xvnc takes only the VNC password"
assert_equals "%h/.config/firstmate/vnc/passwd" "$(arg_after "$exec_line" -rfbauth)" "Xvnc's password file"
assert_equals "%h/.config/firstmate/vnc/xauthority" "$(arg_after "$exec_line" -auth)" "Xvnc's X11 cookie"
assert_equals tcp "$(arg_after "$exec_line" -nolisten)" "no X11 over TCP"
assert_equals ":17" "$(unit_env "$units/dev.firstmate.vnc-browser.service" DISPLAY)" "the browser runs on the VNC display"
assert_equals "%h/.config/firstmate/vnc/xauthority" "$(unit_env "$units/dev.firstmate.vnc-browser.service" XAUTHORITY)" "the browser holds the X11 cookie"
assert_grep "MIT-MAGIC-COOKIE-1" "$ACCT/.config/firstmate/vnc/xauthority" "the X11 cookie was written"
assert_equals 600 "$(file_mode "$ACCT/.config/firstmate/vnc/xauthority")" "the X11 cookie is private"
assert_no_grep "$PW" "$LOG" "a stub saw the password on argv"
vnc install local > /dev/null
assert_equals "$PW" "$(cat "$H/config/vnc/local.password")" "a reinstall keeps the same password"
pass "install keeps one private password and writes loopback-only, password-only units"

out=$(vnc connect local)
assert_equals "port=5917
password=$PW" "$out" "connect gives the viewer what it needs"
pass "connect is the one place the password is printed"

out=$(vnc status local)
assert_contains "$out" "item vnc-server=present: TigerVNC at" "server present"
assert_contains "$out" "item vnc-service=present: dev.firstmate.vnc is running on 127.0.0.1:5917" "service running"
assert_contains "$out" "item vnc-loopback=present: only 127.0.0.1 listens on port 5917" "loopback only"
assert_contains "$out" "item vnc-browser=present: Chrome is running on display :17" "browser running"
out=$(FAKE_LISTEN="0.0.0.0:5917" vnc status local)
assert_contains "$out" "item vnc-loopback=human: port 5917 listens beyond loopback" "a public listener is flagged"
assert_contains "$out" "item vnc-service=human:" "a public listener is not a healthy service"
out=$(FAKE_PID=99 vnc status local)
assert_contains "$out" "item vnc-loopback=unknown: the server does not listen on port 5917 yet" "another process's listener does not count"
assert_contains "$out" "item vnc-service=human:" "an unrelated listener is not a healthy service"
pass "status reads the server, the service, loopback and the browser"

rm "$FAKEBIN/Xvnc"
set +e
out=$(vnc install local)
rc=$?
set -e
expect_code 1 "$rc" "install without the package"
assert_contains "$out" "refuse: TigerVNC is missing; a person runs: sudo apt-get install -y tigervnc-standalone-server tigervnc-tools xauth" "exact command for a person"
stub Xvnc 'echo "Xvnc TigerVNC 1.15"'
set +e; out=$(FAKE_LINGER=no vnc install local); rc=$?; set -e
expect_code 1 "$rc" "install without lingering"
assert_contains "$out" "a person runs: sudo loginctl enable-linger" "the linger step is a person's"
pass "a missing package is never installed without --install-deps"

: > "$LOG"
out=$(vnc open-url local 'https://github.com/a/vip-dashboard/pull/7')
assert_contains "$out" "opened=url" "open-url result"
for _ in $(seq 1 50); do grep -q vip-dashboard "$LOG" && break; sleep 0.1; done
assert_grep 'chrome --user-data-dir='"$ACCT"'/.config/firstmate/vnc-browser https://github.com/a/vip-dashboard/pull/7' "$LOG" "the link opens in the VNC display's Chrome"
set +e; out=$(FAKE_CHROME_RC=1 vnc open-url local 'https://github.com/a/b'); rc=$?; set -e
expect_code 1 "$rc" "a link Chrome did not take"
assert_contains "$out" "did not take the link" "the failure reaches the caller"
for bad in 'file:///etc/passwd' 'javascript:alert(1)' "https://x/\$(id)'" 'https://x/ a'; do
  set +e; out=$(vnc open-url local "$bad"); rc=$?; set -e
  expect_code 1 "$rc" "open-url $bad"
  assert_contains "$out" "only plain http(s) links" "open-url refused $bad"
done
set +e; out=$(vnc open-setting local screen); rc=$?; set -e
expect_code 1 "$rc" "privacy settings on Linux"
set +e; out=$(vnc status ghost); rc=$?; set -e
expect_code 1 "$rc" "unknown machine"
assert_contains "$out" "refuse: not a known machine: ghost" "unknown machine refusal"
pass "links, settings and machines are validated"

echo "ALL TESTS PASSED"
