#!/usr/bin/env python3
"""fm-reply-log-guard.py - Deck pre_tool_use hook that keeps a second mate's
reply logs append-only.

Usage: fm-reply-log-guard.py <protected-file>...   (hook event JSON on stdin)

A second mate answers its first mate by appending lines to its reply log
(state/parent-replies.status for a remote mate, the parent status file for a
local one). The first mate mirrors those files line by line from a byte cursor,
so editing one in place - a typo fix, a dedupe, a rewritten line - breaks the
mirror and every later reply stops reaching the first mate. This hook refuses
the tool calls that rewrite a protected file: edit_file on it, and run_command
lines that name it alongside an in-place edit, a truncating redirect, a write
mode, a move or copy onto it, a truncate or a removal. Appending (>>) and
reading are left alone. Matching shell text is best effort: the first mate's
mirror recovers from a rewrite on its own (bin/fm-procevent-remote-reply.sh),
and this guard only keeps the common ways from happening. Exit 2 blocks the call and its stderr goes back to the
model; anything this hook cannot read is allowed (exit 0), because it guards a
convention rather than a security boundary.
"""
import json
import os
import re
import sys

MESSAGE = (
    "{name} is append-only: your first mate mirrors it line by line, and "
    "editing it in place breaks that mirror so later replies stop reaching it. "
    "Do not edit, dedupe, truncate or replace it. To fix a line, append a new "
    "line instead (for example 'correction to corr=<id>: <the corrected text>')."
)


def writes(command, name):
    """True when the shell command rewrites the file called <name>."""
    if name not in command:
        return False
    n = re.escape(name)
    # Quoted text that does not name the file is payload (a reply being
    # appended, a search pattern), not command syntax.
    shell = re.sub(r"'[^']*'|\"[^\"]*\"",
                   lambda m: m.group(0) if name in m.group(0) else "''", command)
    patterns = [
        r"\bsed\b[^|;&\n]*\s(-[A-Za-z]*i|--in-place)",
        r"\bperl\b[^|;&\n]*\s-[A-Za-z]*i",
        r"(?<!>)>(?!>)\s*['\"]?[^\s'\";|&]*" + n,
        r"\btee\b(?![^|;&\n]*\s(-a|--append)\b)[^|;&\n]*" + n,
        r"\b(mv|cp|install|rsync|ln)\b[^|;&\n]*" + n + r"['\"]?\s*(#[^\n]*)?($|[|;&\n])",
        r"(^|[;&|(\n]\s*|\bsudo\s+)truncate\b[^|;&\n]*" + n,
        r"(^|[;&|(\n]\s*|\bsudo\s+)rm\b[^|;&\n]*" + n,
        r"\.write_text\(|\.write_bytes\(|os\.truncate|shutil\.(move|copy)",
    ]
    if any(re.search(p, shell) for p in patterns):
        return True
    # Any open() alongside a writing mode literal: argument nesting makes the
    # mode's position unparseable by pattern, so the pair is enough.
    return bool(re.search(r"\bopen\(", command)
                and re.search(r",\s*(mode\s*=\s*)?['\"][rabt]*[wx+][rwxabt+]*['\"]", command))


def main():
    protected = [p for p in sys.argv[1:] if p]
    if not protected:
        return 0
    try:
        event = json.load(sys.stdin)
    except Exception:
        return 0
    tool = event.get("tool_name") or ""
    args = event.get("args")
    if not isinstance(args, dict):
        return 0
    names = {os.path.basename(p) for p in protected}
    if tool == "edit_file":
        path = str(args.get("path") or "")
        if os.path.basename(path) in names:
            print(MESSAGE.format(name=os.path.basename(path)), file=sys.stderr)
            return 2
        return 0
    if tool == "run_command":
        command = str(args.get("command") or "")
        for name in sorted(names):
            if writes(command, name):
                print(MESSAGE.format(name=name), file=sys.stderr)
                return 2
    return 0


if __name__ == "__main__":
    sys.exit(main())
