# shellcheck shell=bash
# Single owner of the CLI toolchain every Firstmate home needs and of the
# install command printed for each tool. bin/fm-bootstrap.sh reports these as
# MISSING lines at session start, and bin/fm-machine.sh checks and installs them
# on a machine being connected for remote second mates. The runtime backend's
# own tools come from fm_backend_required_tools in bin/fm-backend.sh.
# Usage: . bin/fm-home-tools-lib.sh

# The tools every home needs regardless of runtime backend.
fm_home_common_tools() {
  printf '%s\n' "node git gh no-mistakes gh-axi chrome-devtools-axi tasks-axi quota-axi"
}

# Print the install command for <tool>, or return 1 when there is none.
fm_home_tool_install_cmd() { # <tool>
  case "$1" in
    node|git|gh|curl|jq|python3) echo "brew install $1  # or the platform's package manager" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi|quota-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

# 0 when <tool>'s install command runs as the account itself with no package
# manager or sudo: a user-level installer script or a global npm install.
fm_home_tool_user_installable() { # <tool>
  case "$(fm_home_tool_install_cmd "$1" 2>/dev/null)" in
    'curl -fsSL '*|'npm install -g '*) return 0 ;;
    *) return 1 ;;
  esac
}
