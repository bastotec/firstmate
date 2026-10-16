#!/usr/bin/env bash
# Firstmate's VNC server on a machine: install, status, start/stop, the macOS
# privacy settings it needs, and opening a link in that machine's browser.
#
# Usage:
#   fm-machine-vnc.sh install <machine> [--install-deps]
#   fm-machine-vnc.sh status <machine>
#   fm-machine-vnc.sh start|stop|restart <machine>
#   fm-machine-vnc.sh open-setting <machine> screen|accessibility
#   fm-machine-vnc.sh open-url <machine> <http(s)-url>
#   fm-machine-vnc.sh connect <machine>
#
# <machine> is `local` or an ssh alias bin/fm-machine-skills.sh knows (roots);
# a remote machine runs this same script's `*-local` half through fm-on.sh,
# in the account's GUI session on macOS (the remote job worker).
#
# The server listens on 127.0.0.1:5917 only and asks for a VNC password
# (security type 2); a viewer reaches it through an ssh -L forward.
#   macOS: macVNC (github.com/LibVNC/macVNC at MACVNC_COMMIT), a small
#     ScreenCaptureKit + LibVNCServer server built here with clang into
#     ~/Applications/macVNC.app, so the privacy settings list it as "macVNC".
#     It needs Homebrew's libvncserver. Rebuilt only when the pinned commit
#     changes, because a new binary loses its Screen Recording and
#     Accessibility grants. LaunchAgent dev.firstmate.vnc, log
#     ~/Library/Logs/dev.firstmate.vnc.log.
#   Linux: TigerVNC's Xvnc on its own display :17 (the package
#     tigervnc-standalone-server; Xvnc needs the system xkbcomp, so it is not
#     installed per user), plus Chrome on that display with its own profile at
#     ~/.config/firstmate/vnc-browser. systemd user units dev.firstmate.vnc and
#     dev.firstmate.vnc-browser (linger must be on). Xvnc is an X server too, so
#     display :17 takes only clients holding the X11 cookie in
#     ~/.config/firstmate/vnc/xauthority (mode 600), not any local account.
# Packages are installed only with --install-deps (`brew install
# libvncserver`, or `sudo -n apt-get install -y tigervnc-standalone-server tigervnc-tools xauth`
# when sudo needs no password); otherwise install refuses with the exact
# command for a person to run. Never run --install-deps on a machine whose
# captain has not approved the package.
#
# The password: install generates one per machine and keeps it in this home
# at config/vnc/<machine>.password (mode 600), then sends it on stdin to the
# machine, which stores only LibVNCServer/TigerVNC's obfuscated form at
# ~/.config/firstmate/vnc/passwd (mode 600). It never appears in argv, logs or
# output, except `connect`, which prints `port=5917` and `password=<pw>` for
# Fleet Town's viewer to read; never log that output.
#
# status prints checklist lines (bin/fm-machine.sh's protocol):
#   item vnc-server=present|human: ...
#   item vnc-service=present|human: ...
#   item vnc-loopback=present|human: ...
#   item tcc-accessibility=present|human|unknown: ...      (macOS)
#   item tcc-screen-recording=present|human|unknown: ...   (macOS)
#   item vnc-browser=present|human: ...                    (Linux)
# macOS reports the privacy settings from the server's own log: it exits
# naming the missing permission, so `unknown` until a viewer has connected
# once. open-setting opens that pane of System Settings on the machine.
# start, restart and install clear the log first.
#
# open-url opens the link in the machine's browser: the default browser of
# the logged-in user on macOS, the display :17 Chrome on Linux.
#
# Refusals print `refuse: <reason>` and exit 1; usage errors 2.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
PORT=5917
DISPLAY_NUM=17
MACVNC_REPO=https://github.com/LibVNC/macVNC.git
MACVNC_COMMIT=6c45640168dd170120d96661b3b711d283257166
LABEL=dev.firstmate.vnc

usage() { sed -n '5,11p' "$0" | sed 's/^# \{0,1\}//' >&2; exit 2; }
refuse() { printf 'refuse: %s\n' "$1"; exit 1; }

valid_machine() {
  case "$1" in ''|-*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  [ "$1" = local ] || "$SCRIPT_DIR/fm-machine-skills.sh" roots 2>/dev/null | cut -f1 | grep -qxF -- "$1"
}

valid_url() {
  case "$1" in http://?*|https://?*) ;; *) return 1 ;; esac
  case "$1" in *[[:space:]]*|*[[:cntrl:]]*|*\'*|*\"*|*\`*|*\\*) return 1 ;; esac
  [ "${#1}" -le 4096 ]
}

# Run <op>-local on the machine; stdin passes through with --stdin.
on_machine() { # <machine> <op> [--stdin] [args...]
  local m=$1 op=$2 root
  local -a input=()
  shift 2
  if [ "${1:-}" = --stdin ]; then input=(--stdin); shift; fi
  if [ "$m" = local ]; then
    "$0" "$op-local" "$@"
  else
    root=$("$SCRIPT_DIR/fm-machine-skills.sh" roots | awk -F '\t' -v m="$m" '$1 == m { print $2; exit }')
    FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$SCRIPT_DIR/.." \
      "$SCRIPT_DIR/fm-on.sh" "${input[@]+"${input[@]}"}" --machine-root "$root" "$m" fm-machine-vnc.sh "$op-local" "$@"
  fi
}

password_file() { printf '%s/vnc/%s.password\n' "$CONFIG" "$1"; }

# Generate the machine's password once (8 characters: VNC uses no more).
ensure_password() { # <machine>
  local f
  f=$(password_file "$1")
  [ -s "$f" ] && return 0
  (umask 077; mkdir -p "$(dirname "$f")"
   python3 -c 'import secrets, string; a = string.ascii_letters + string.digits; print("".join(secrets.choice(a) for _ in range(8)))' > "$f.tmp"
   mv -f "$f.tmp" "$f")
}

# --- machine half -----------------------------------------------------------

os() { uname -s; }
vnc_dir() { printf '%s/.config/firstmate/vnc\n' "$HOME"; }
mac_app() { printf '%s/Applications/macVNC.app\n' "$HOME"; }
mac_log() { printf '%s/Library/Logs/%s.log\n' "$HOME" "$LABEL"; }
mac_plist() { printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$LABEL"; }
storepasswd() { printf '%s/.local/libexec/firstmate/fm-vnc-storepasswd\n' "$HOME"; }
brew_bin() { command -v brew 2>/dev/null || { [ -x /opt/homebrew/bin/brew ] && echo /opt/homebrew/bin/brew; } || { [ -x /usr/local/bin/brew ] && echo /usr/local/bin/brew; } || true; }

linux_browser() { command -v google-chrome 2>/dev/null || command -v chromium 2>/dev/null || command -v chromium-browser 2>/dev/null || true; }

# The password install-local received on stdin, read before anything else
# runs (brew and git would otherwise read, and print, it).
VNC_PASSWORD=
read_password() {
  IFS= read -r VNC_PASSWORD || true
  case "$VNC_PASSWORD" in ''|*[!A-Za-z0-9]*) refuse "install-local needs the 8-character password on stdin" ;; esac
}

# Write the password into the server's obfuscated file through <writer...>.
store_password() { # <writer...>
  local f
  f="$(vnc_dir)/passwd"
  (umask 077; mkdir -p "$(vnc_dir)")
  printf '%s\n' "$VNC_PASSWORD" | "$@" "$f.tmp" >/dev/null 2>&1 || { rm -f "$f.tmp"; refuse "could not store the VNC password"; }
  chmod 600 "$f.tmp"
  mv -f "$f.tmp" "$f"
}

mac_install() { # [--install-deps]
  local brew prefix src out app cc
  brew=$(brew_bin)
  [ -n "$brew" ] || refuse "Homebrew is missing on this Mac; macVNC is built against Homebrew's libvncserver"
  if ! prefix=$("$brew" --prefix --installed libvncserver 2>/dev/null) || [ -z "$prefix" ]; then
    [ "${1:-}" = --install-deps ] || refuse "libvncserver is missing; a person runs: brew install libvncserver"
    # Homebrew may link its new openssl over the one other tools use; put the
    # previously linked one back (libvncserver uses its own opt path).
    local before after
    before=$(readlink "$(dirname "$brew")/openssl" 2>/dev/null || true)
    "$brew" install libvncserver < /dev/null >&2 || refuse "brew install libvncserver failed"
    after=$(readlink "$(dirname "$brew")/openssl" 2>/dev/null || true)
    case "$before" in
      *Cellar/openssl@3/*)
        if [ "$after" != "$before" ]; then
          "$brew" unlink openssl@4 < /dev/null >/dev/null 2>&1 || true
          "$brew" link openssl@3 < /dev/null >/dev/null 2>&1 || true
        fi ;;
    esac
    prefix=$("$brew" --prefix --installed libvncserver)
  fi
  cc=$(command -v clang) || refuse "clang is missing; install the Xcode Command Line Tools (xcode-select --install)"
  src="$HOME/.cache/firstmate/macvnc"
  app=$(mac_app)
  if [ "$(cat "$app/Contents/Resources/firstmate-commit" 2>/dev/null)" != "$MACVNC_COMMIT" ]; then
    if [ -d "$src/.git" ]; then
      git -C "$src" fetch --quiet origin < /dev/null >&2 || refuse "git fetch of macVNC failed"
    else
      git clone --quiet "$MACVNC_REPO" "$src" < /dev/null >&2 || refuse "git clone of $MACVNC_REPO failed"
    fi
    git -C "$src" -c advice.detachedHead=false checkout --quiet --force "$MACVNC_COMMIT" >&2 || refuse "macVNC commit $MACVNC_COMMIT is not available"
    out="$src/out/macVNC.app"
    rm -rf "$src/out"
    mkdir -p "$out/Contents/MacOS" "$out/Contents/Resources"
    "$cc" -O2 -o "$out/Contents/MacOS/macVNC" "$src/src/mac.m" "$src/src/ScreenCapturer.m" \
      -I"$prefix/include" -L"$prefix/lib" -lvncserver -framework Carbon -framework IOKit \
      -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework Foundation \
      -framework ApplicationServices >&2 || refuse "building macVNC failed"
    cp "$src/src/icon.icns" "$out/Contents/Resources/"
    printf '%s\n' "$MACVNC_COMMIT" > "$out/Contents/Resources/firstmate-commit"
    cat > "$out/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>macVNC</string>
<key>CFBundleIdentifier</key><string>dev.firstmate.macvnc</string>
<key>CFBundleName</key><string>macVNC</string>
<key>CFBundleIconFile</key><string>icon.icns</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>LSUIElement</key><true/>
</dict></plist>
PLIST
    codesign -s - --force --identifier dev.firstmate.macvnc "$out" >/dev/null 2>&1 || refuse "signing macVNC failed"
    mkdir -p "$(dirname "$app")"
    if ! { rm -rf "$app.new" && cp -R "$out" "$app.new" && rm -rf "$app" && mv "$app.new" "$app"; }; then
      refuse "installing $app failed"
    fi
    printf 'step vnc-server=done: built macVNC %.7s into %s (grant its privacy settings again)\n' "$MACVNC_COMMIT" "$app"
  else
    printf 'step vnc-server=skipped: macVNC %.7s already at %s\n' "$MACVNC_COMMIT" "$app"
  fi
  if [ ! -x "$(storepasswd)" ]; then
    mkdir -p "$(dirname "$(storepasswd)")"
    printf '%s\n' '#include <rfb/rfb.h>' '#include <stdio.h>' '#include <string.h>' \
      'int main(int c, char **v) { char p[64]; if (c != 2 || !fgets(p, sizeof p, stdin)) return 2;' \
      '  p[strcspn(p, "\r\n")] = 0; return rfbEncryptAndStorePasswd(p, v[1]) == 0 ? 0 : 1; }' \
      | "$cc" -O2 -x c -o "$(storepasswd)" - -I"$prefix/include" -L"$prefix/lib" -lvncserver >&2 \
      || refuse "building the password helper failed"
  fi
  store_password "$(storepasswd)"
  printf 'step vnc-password=done: stored at %s/passwd\n' "$(vnc_dir)"
  mkdir -p "$(dirname "$(mac_plist)")" "$(dirname "$(mac_log)")"
  cat > "$(mac_plist)" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$LABEL</string>
<key>ProgramArguments</key><array>
<string>$app/Contents/MacOS/macVNC</string>
<string>-rfbport</string><string>$PORT</string>
<string>-rfbportv6</string><string>-1</string>
<string>-listen</string><string>127.0.0.1</string>
<string>-rfbauth</string><string>$(vnc_dir)/passwd</string>
<string>-alwaysshared</string>
</array>
<key>RunAtLoad</key><true/>
<key>KeepAlive</key><true/>
<key>ThrottleInterval</key><integer>30</integer>
<key>LimitLoadToSessionType</key><string>Aqua</string>
<key>StandardOutPath</key><string>$(mac_log)</string>
<key>StandardErrorPath</key><string>$(mac_log)</string>
</dict></plist>
PLIST
  mac_service restart
  printf 'step vnc-service=done: %s on 127.0.0.1:%s\n' "$LABEL" "$PORT"
}

mac_service() { # start|stop|restart
  local dom
  dom="gui/$(id -u)"
  case "$1" in
    stop) launchctl bootout "$dom/$LABEL" >/dev/null 2>&1 || true ;;
    start|restart)
      : > "$(mac_log)"
      launchctl bootout "$dom/$LABEL" >/dev/null 2>&1 || true
      launchctl bootstrap "$dom" "$(mac_plist)" >/dev/null 2>&1 \
        || launchctl kickstart -k "$dom/$LABEL" >/dev/null 2>&1 \
        || refuse "could not start $LABEL in $dom (is someone logged in at the screen?)"
      ;;
  esac
}

# The remote job worker runs commands with a bare environment; systemctl --user
# needs the account's runtime dir and session bus.
user_bus() {
  [ -n "${XDG_RUNTIME_DIR:-}" ] || XDG_RUNTIME_DIR="/run/user/$(id -u)"
  [ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ] || DBUS_SESSION_BUS_ADDRESS="unix:path=$XDG_RUNTIME_DIR/bus"
  export XDG_RUNTIME_DIR DBUS_SESSION_BUS_ADDRESS
}

# The display's X11 cookie: Xvnc is also an X server, so only clients holding it
# (the browser, open-url) may use :17, not any local account.
xauth_file() { printf '%s/xauthority\n' "$(vnc_dir)"; }
ensure_xauth() {
  local f cookie
  f=$(xauth_file)
  (umask 077; mkdir -p "$(vnc_dir)")
  if ! xauth -f "$f" list ":$DISPLAY_NUM" 2>/dev/null | grep -q MIT-MAGIC-COOKIE-1; then
    cookie=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
    (umask 077; xauth -q -f "$f" add ":$DISPLAY_NUM" MIT-MAGIC-COOKIE-1 "$cookie" 2>/dev/null) || refuse "could not write the display's X11 cookie"
  fi
  chmod 600 "$f"
}

linux_install() { # [--install-deps]
  local units browser
  if ! command -v Xvnc >/dev/null 2>&1 || ! command -v vncpasswd >/dev/null 2>&1 || ! command -v xauth >/dev/null 2>&1; then
    if [ "${1:-}" != --install-deps ] || ! sudo -n true 2>/dev/null; then
      refuse "TigerVNC is missing; a person runs: sudo apt-get install -y tigervnc-standalone-server tigervnc-tools xauth"
    fi
    sudo -n apt-get install -y tigervnc-standalone-server tigervnc-tools xauth < /dev/null >&2 || refuse "apt-get install of TigerVNC failed"
    printf 'step vnc-server=done: installed tigervnc-standalone-server, tigervnc-tools and xauth\n'
  else
    printf 'step vnc-server=skipped: Xvnc at %s\n' "$(command -v Xvnc)"
  fi
  browser=$(linux_browser)
  [ -n "$browser" ] || refuse "no Chrome or Chromium on this machine for the remote browser; a person installs google-chrome"
  # shellcheck disable=SC2016 # $1 is the inner shell's argument.
  store_password sh -c 'vncpasswd -f > "$1"' sh
  ensure_xauth
  printf 'step vnc-password=done: stored at %s/passwd, with an X11 cookie for display :%s\n' "$(vnc_dir)" "$DISPLAY_NUM"
  units="$HOME/.config/systemd/user"
  mkdir -p "$units"
  cat > "$units/$LABEL.service" <<UNIT
[Unit]
Description=Firstmate VNC desktop (Xvnc :$DISPLAY_NUM on 127.0.0.1:$PORT)

[Service]
ExecStart=$(command -v Xvnc) :$DISPLAY_NUM -auth %h/.config/firstmate/vnc/xauthority -nolisten tcp -localhost -rfbport $PORT -SecurityTypes VncAuth -rfbauth %h/.config/firstmate/vnc/passwd -geometry 1600x1000 -depth 24 -AlwaysShared
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  cat > "$units/$LABEL-browser.service" <<UNIT
[Unit]
Description=Firstmate VNC desktop browser on :$DISPLAY_NUM
Requires=$LABEL.service
After=$LABEL.service

[Service]
Environment=DISPLAY=:$DISPLAY_NUM
Environment=XAUTHORITY=%h/.config/firstmate/vnc/xauthority
ExecStartPre=/bin/sleep 2
ExecStart=$browser --user-data-dir=%h/.config/firstmate/vnc-browser --no-first-run --no-default-browser-check --start-maximized --window-position=0,0 --window-size=1600,1000
Restart=always
RestartSec=5

[Install]
WantedBy=default.target
UNIT
  user_bus
  systemctl --user daemon-reload
  systemctl --user enable "$LABEL.service" "$LABEL-browser.service" >/dev/null 2>&1 || true
  linux_service restart
  printf 'step vnc-service=done: %s on 127.0.0.1:%s with Chrome on :%s\n' "$LABEL" "$PORT" "$DISPLAY_NUM"
}

linux_service() { # start|stop|restart
  user_bus
  case "$1" in
    stop) systemctl --user stop "$LABEL-browser.service" "$LABEL.service" >/dev/null 2>&1 || true ;;
    *) systemctl --user restart "$LABEL.service" "$LABEL-browser.service" >/dev/null 2>&1 || refuse "could not start $LABEL" ;;
  esac
}

# 0 when every listener on the port is a loopback address.
loopback_only() {
  local addrs
  if command -v ss >/dev/null 2>&1; then
    addrs=$(ss -ltnH "sport = :$PORT" 2>/dev/null | awk '{ print $4 }')
  else
    addrs=$(lsof -nP -iTCP:"$PORT" -sTCP:LISTEN 2>/dev/null | awk 'NR > 1 { print $9 }')
  fi
  [ -n "$addrs" ] || return 2
  ! printf '%s\n' "$addrs" | grep -vqE '^(127\.0\.0\.1|\[::1\]|::1):'
}

cmd_status_local() {
  local log running=no rc
  case "$(os)" in
    Darwin)
      if [ -x "$(mac_app)/Contents/MacOS/macVNC" ]; then
        printf 'item vnc-server=present: macVNC %.7s at %s\n' "$(cat "$(mac_app)/Contents/Resources/firstmate-commit" 2>/dev/null)" "$(mac_app)"
      else
        printf 'item vnc-server=human: not installed; run bin/fm-machine-vnc.sh install <machine> (Homebrew libvncserver needed)\n'
      fi
      launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -q 'state = running' && running=yes
      log=$(tail -n 60 "$(mac_log)" 2>/dev/null || true)
      ;;
    *)
      if command -v Xvnc >/dev/null 2>&1; then
        printf 'item vnc-server=present: TigerVNC Xvnc at %s\n' "$(command -v Xvnc)"
      else
        printf 'item vnc-server=human: sudo apt-get install -y tigervnc-standalone-server tigervnc-tools xauth\n'
      fi
      user_bus
      systemctl --user is-active --quiet "$LABEL.service" 2>/dev/null && running=yes
      ;;
  esac
  set +e; loopback_only; rc=$?; set -e
  if [ "$running" = yes ] && [ "$rc" -eq 0 ]; then
    printf 'item vnc-service=present: %s is running on 127.0.0.1:%s\n' "$LABEL" "$PORT"
  else
    printf 'item vnc-service=human: %s is not running; start it with bin/fm-machine-vnc.sh start <machine>\n' "$LABEL"
  fi
  case "$rc" in
    0) printf 'item vnc-loopback=present: only 127.0.0.1 listens on port %s\n' "$PORT" ;;
    2) printf 'item vnc-loopback=unknown: nothing listens on port %s yet\n' "$PORT" ;;
    *) printf 'item vnc-loopback=human: port %s listens beyond loopback; stop it and check the service\n' "$PORT" ;;
  esac
  if [ "$(os)" = Darwin ]; then
    if printf '%s' "$log" | grep -q 'permission to control your computer'; then
      printf 'item tcc-accessibility=human: turn on macVNC in System Settings > Privacy & Security > Accessibility (at the Mac), then restart the service\n'
    elif [ "$running" = yes ]; then
      printf 'item tcc-accessibility=present: macVNC may control the Mac\n'
    else
      printf 'item tcc-accessibility=unknown: start the service to check\n'
    fi
    if printf '%s' "$log" | grep -q 'screen recording permissions'; then
      printf 'item tcc-screen-recording=human: turn on macVNC in System Settings > Privacy & Security > Screen & System Audio Recording (at the Mac), then restart the service\n'
    elif printf '%s' "$log" | grep -q 'Client [0-9.:]* gone\|Pixel format for client'; then
      printf 'item tcc-screen-recording=present: a viewer received the screen\n'
    else
      printf 'item tcc-screen-recording=unknown: connect once (Test frame) to check\n'
    fi
  else
    if systemctl --user is-active --quiet "$LABEL-browser.service" 2>/dev/null; then
      printf 'item vnc-browser=present: Chrome is running on display :%s\n' "$DISPLAY_NUM"
    else
      printf 'item vnc-browser=human: %s-browser is not running; restart the service\n' "$LABEL"
    fi
  fi
}

cmd_open_setting_local() { # screen|accessibility
  [ "$(os)" = Darwin ] || refuse "privacy settings are a macOS step"
  case "$1" in
    screen) open 'x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture' ;;
    accessibility) open 'x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility' ;;
    *) usage ;;
  esac
  printf 'opened=%s\n' "$1"
}

cmd_open_url_local() { # <url>
  valid_url "$1" || refuse "only plain http(s) links open on a machine"
  if [ "$(os)" = Darwin ]; then
    open "$1" || refuse "the browser did not open the link"
  else
    user_bus
    systemctl --user is-active --quiet "$LABEL-browser.service" || linux_service start
    DISPLAY=":$DISPLAY_NUM" XAUTHORITY="$(xauth_file)" "$(linux_browser)" --user-data-dir="$HOME/.config/firstmate/vnc-browser" "$1" >/dev/null 2>&1 &
  fi
  printf 'opened=url\n'
}

service_local() { # start|stop|restart
  if [ "$(os)" = Darwin ]; then mac_service "$1"; else linux_service "$1"; fi
  printf 'service=%s\n' "$1"
}

# --- primary half -----------------------------------------------------------

cmd_install() { # <machine> [--install-deps]
  local m=$1
  shift
  case "${1:-}" in ''|--install-deps) ;; *) usage ;; esac
  valid_machine "$m" || refuse "not a known machine: $m"
  ensure_password "$m"
  printf 'action=vnc-install\nmachine=%s\n' "$m"
  on_machine "$m" install --stdin "$@" < "$(password_file "$m")"
}

cmd_connect() { # <machine>
  local f
  valid_machine "$1" || refuse "not a known machine: $1"
  f=$(password_file "$1")
  [ -s "$f" ] || refuse "no VNC password for $1; run bin/fm-machine-vnc.sh install $1"
  printf 'port=%s\npassword=%s\n' "$PORT" "$(head -n 1 "$f")"
}

[ "$#" -ge 1 ] || usage
sub=$1
shift
case "$sub" in
  install-local)
    [ "$#" -le 1 ] || usage
    read_password
    if [ "$(os)" = Darwin ]; then mac_install "$@"; else linux_install "$@"; fi ;;
  status-local) [ "$#" -eq 0 ] || usage; cmd_status_local ;;
  start-local|stop-local|restart-local) [ "$#" -eq 0 ] || usage; service_local "${sub%-local}" ;;
  open-setting-local) [ "$#" -eq 1 ] || usage; cmd_open_setting_local "$1" ;;
  open-url-local) [ "$#" -eq 1 ] || usage; cmd_open_url_local "$1" ;;
  install) [ "$#" -ge 1 ] || usage; cmd_install "$@" ;;
  status|start|stop|restart)
    [ "$#" -eq 1 ] || usage
    valid_machine "$1" || refuse "not a known machine: $1"
    on_machine "$1" "$sub" ;;
  open-setting)
    [ "$#" -eq 2 ] || usage
    valid_machine "$1" || refuse "not a known machine: $1"
    case "$2" in screen|accessibility) ;; *) usage ;; esac
    on_machine "$1" open-setting "$2" ;;
  open-url)
    [ "$#" -eq 2 ] || usage
    valid_machine "$1" || refuse "not a known machine: $1"
    valid_url "$2" || refuse "only plain http(s) links open on a machine"
    on_machine "$1" open-url "$2" ;;
  connect) [ "$#" -eq 1 ] || usage; cmd_connect "$1" ;;
  *) usage ;;
esac
