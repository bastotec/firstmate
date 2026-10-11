# shellcheck shell=bash
# Shared presentation boundary for machine commands, including their diagnostics.
# Usage: . bin/fm-machine-output-lib.sh; command 2>&1 | fm_machine_redact_urls
fm_machine_redact_urls() {
  sed -E "s#([[:alpha:]][[:alnum:]+.-]*://)[^/[:space:]\"'<>]*@#\1[redacted]@#g"
}
