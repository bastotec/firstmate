# shellcheck shell=bash
# Shared parser and floor comparison for tool-owned semantic version output.
# Usage: . bin/fm-tool-version-lib.sh

fm_tool_semver_parts() {  # <tool-name> <version-output>
  local tool=$1 output=$2
  case "$tool" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  printf '%s\n' "$output" | LC_ALL=C awk -v tool="$tool" '
    function identifiers_valid(value, prerelease, identifiers, count, i) {
      count = split(value, identifiers, /\./)
      if (count == 0) return 0
      for (i = 1; i <= count; i++) {
        if (identifiers[i] == "" || identifiers[i] !~ /^[0-9A-Za-z-]+$/) return 0
        if (prerelease && identifiers[i] ~ /^[0-9]+$/ && identifiers[i] !~ /^(0|[1-9][0-9]*)$/) return 0
      }
      return 1
    }
    function parse(token, core, prerelease, build, plus, dash, parts, count) {
      sub(/^[vV]/, "", token)
      plus = index(token, "+")
      if (plus) {
        build = substr(token, plus + 1)
        token = substr(token, 1, plus - 1)
        if (!identifiers_valid(build, 0)) return 0
      }
      dash = index(token, "-")
      if (dash) {
        prerelease = substr(token, dash + 1)
        core = substr(token, 1, dash - 1)
        if (!identifiers_valid(prerelease, 1)) return 0
      } else {
        prerelease = "_"
        core = token
      }
      count = split(core, parts, /\./)
      if (count != 3) return 0
      if (parts[1] !~ /^(0|[1-9][0-9]*)$/ ||
          parts[2] !~ /^(0|[1-9][0-9]*)$/ ||
          parts[3] !~ /^(0|[1-9][0-9]*)$/) return 0
      if (length(parts[1]) == 4 && parts[2] >= 1 && parts[2] <= 12 && parts[3] >= 1 && parts[3] <= 31) return 0
      parsed = parts[1] " " parts[2] " " parts[3] " " prerelease
      return 1
    }
    {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      sub(/[[:space:]]+$/, "", line)
      if (line == "") next
      nonblank++
      count = split(line, fields, /[[:space:]]+/)
      if (fields[1] == tool && fields[2] == "version" && count >= 3) {
        if (associated == "" && parse(fields[3])) associated = parsed
      } else if (fields[1] == tool && count >= 2) {
        if (associated == "" && parse(fields[2])) associated = parsed
      } else if (count == 1) {
        bare = fields[1]
      }
    }
    END {
      if (associated != "") {
        print associated
      } else if (nonblank == 1 && parse(bare)) {
        print parsed
      }
    }
  '
}

fm_semver_parts_at_least() {  # <parsed-version-parts> <minimum-core-version>
  local parsed=$1 minimum=$2 major minor patch prerelease extra
  local min_major min_minor min_patch min_extra component
  IFS=' ' read -r major minor patch prerelease extra <<< "$parsed"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] \
    && [ -n "$prerelease" ] && [ -z "$extra" ] || return 2
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$minimum"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 2
  for component in "$min_major" "$min_minor" "$min_patch"; do
    case "$component" in ''|*[!0-9]*|0[0-9]*) return 2 ;; esac
  done
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -gt "$min_patch" ] && return 0
  [ "$patch" -eq "$min_patch" ] || return 1
  [ "$prerelease" = _ ]
}
