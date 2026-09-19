# shellcheck shell=bash
# Shared parser for tool-owned semantic version output.
# Usage: . bin/fm-tool-version-lib.sh

fm_tool_semver_parts() {  # <tool-name> <version-output>
  local tool=$1 output=$2
  case "$tool" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s\n' "$output" | LC_ALL=C awk -v tool="$tool" '
    function emit(line, fields, count, token, parts) {
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") return 0
      count = split(line, fields, /[[:space:]]+/)
      if (count == 1) {
        token = fields[1]
      } else if (fields[1] == tool && fields[2] == "version" && count >= 3) {
        token = fields[3]
      } else if (fields[1] == tool && count >= 2) {
        token = fields[2]
      } else {
        return 0
      }
      sub(/^[vV]/, "", token)
      if (token !~ /^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$/) return 0
      split(token, parts, /\./)
      print parts[1], parts[2], parts[3]
      return 1
    }
    emit($0) { exit }
  '
}
