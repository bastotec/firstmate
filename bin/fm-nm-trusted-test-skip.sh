#!/usr/bin/env bash
# fm-nm-trusted-test-skip.sh - let a Test step skipped by firstmate's trusted
# default-branch .no-mistakes.yaml (test.skip) satisfy the "PR must be raised
# via no-mistakes" check, whose pinned shared verifier otherwise requires the
# review, test, and document steps to be completed.
#
# Usage: fm-nm-trusted-test-skip.sh <trusted-config> <body-in> <body-out>
#
# <trusted-config> must be the BASE branch copy of .no-mistakes.yaml, because
# no-mistakes honors test.skip only from the default branch. A missing or
# unreadable file counts as "not configured".
#
# Writes <body-out> as the PR body unchanged, except when ALL of these hold:
#   - <trusted-config> sets test.skip: true and a non-empty single-line
#     test.skip_reason R;
#   - the first pipeline attestation comment in the body has exactly one
#     "test" entry, and its status is "skipped";
#   - after the end of that first attestation comment, the first Test summary
#     line is exactly "<summary>⏭️ **Test** - skipped: test.skip: R</summary>"
#     (R HTML-escaped as no-mistakes renders it), allowing surrounding
#     whitespace only.
# Then that one entry's status becomes "completed" for the shared verifier
# that runs next. Any other Test state - failed, missing, completed, a per-run
# or agent skip, or a reason that differs from the trusted config - passes
# through unchanged and the shared verifier judges it exactly as before. The
# signature, head binding, review, and document checks stay the shared
# verifier's job.
#
# Prints one "trusted-test-skip: <decision>" line on stdout. Exits 0 once
# <body-out> is written, 2 on usage errors, and 1 when ruby is unavailable.
set -u

if [ "$#" -ne 3 ]; then
  printf 'usage: fm-nm-trusted-test-skip.sh <trusted-config> <body-in> <body-out>\n' >&2
  exit 2
fi
[ -f "$2" ] || { printf 'fm-nm-trusted-test-skip.sh: body file not found: %s\n' "$2" >&2; exit 2; }
command -v ruby >/dev/null 2>&1 || {
  printf 'fm-nm-trusted-test-skip.sh: ruby is required to read the trusted YAML config\n' >&2
  exit 1
}

exec ruby -ryaml -rjson -e '
config_path, body_in, body_out = ARGV
body = File.read(body_in, encoding: "UTF-8")
out = body

finish = lambda do |text|
  File.write(body_out, out)
  puts "trusted-test-skip: #{text}"
  exit 0
end

config = begin
  File.file?(config_path) ? YAML.safe_load(File.read(config_path)) : nil
rescue StandardError
  nil
end
test_cfg = config.is_a?(Hash) ? config["test"] : nil
unless test_cfg.is_a?(Hash) && test_cfg["skip"] == true
  finish.call("not configured in the trusted config; body unchanged")
end
reason = test_cfg["skip_reason"]
reason = reason.is_a?(String) ? reason.strip : ""
if reason.empty? || reason.include?("\n")
  finish.call("refused: trusted test.skip has no single-line skip_reason; body unchanged")
end

prefix = "<!-- no-mistakes-pipeline-attestation:v1 "
start = body.index(prefix)
finish.call("no pipeline attestation; body unchanged") if start.nil?
payload_start = start + prefix.length
stop = body.index(" -->", payload_start)
finish.call("unterminated pipeline attestation; body unchanged") if stop.nil?
payload = begin
  JSON.parse(body[payload_start...stop])
rescue JSON::ParserError
  nil
end
steps = payload.is_a?(Hash) ? payload["steps"] : nil
finish.call("unparseable pipeline attestation; body unchanged") unless steps.is_a?(Array)
tests = steps.select { |item| item.is_a?(Hash) && item["step"] == "test" }
unless tests.length == 1 && tests[0]["status"] == "skipped"
  status = tests.length == 1 ? tests[0]["status"].inspect : "#{tests.length} test entries"
  finish.call("Test step not skipped (#{status}); body unchanged")
end

# no-mistakes renders the skip reason through Go html.EscapeString.
escaped = reason.gsub(/[&<>"\x27]/, "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&#34;", "\x27" => "&#39;")
expected = "<summary>\u23ed\ufe0f **Test** - skipped: test.skip: #{escaped}</summary>"
summary = body[(stop + " -->".length)..].each_line.find do |line|
  line.strip.match?(/\A<summary>.*\*\*Test\*\* - .*<\/summary>\z/)
end
unless summary && summary.strip == expected
  finish.call("refused: Test was skipped, but not by the trusted test.skip reason; body unchanged")
end

tests[0]["status"] = "completed"
out = body[0...payload_start] + JSON.generate(payload) + body[stop..]
finish.call("accepted: Test step skipped by trusted test.skip (#{reason})")
' "$1" "$2" "$3"
