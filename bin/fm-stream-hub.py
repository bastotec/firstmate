#!/usr/bin/env python3
"""fm-stream-hub.py - the central hub behind the `stream` runtime backend.

ONE hub for the whole fleet.  It owns no pseudoterminal at all: every pty lives
on the machine whose process it drives, published to the hub by a thin agent
(bin/fm-stream-agent.py).  That inversion is the whole point.  A hub that owned
ptys would have to run on every machine, which is exactly what kept the earlier
per-machine design from ever being central.

So the hub is a registry, a bounded frame history, a fan-out, and a command
router:

  * a durable endpoint registry, keyed by endpoint id and carrying the machine
    that owns it, so one page can group every worker in the fleet by machine;
  * a bounded per-endpoint ring of raw output frames, which is what lets a
    viewer that arrives late still see recent scroll-back;
  * fan-out to any number of subscribers over SSE;
  * a per-machine command queue that carries input and kill DOWN to the owning
    agent, and an acknowledgement path that carries the result back UP.

docs/stream-backend.md owns setup, security, and limits.

The five-point backend lifecycle contract in docs/codex-app-backend.md maps
onto these routes:

  1. create a task endpoint with a durable id   the agent creates the pty and
                                                POSTs /v1/agent/endpoints
  2. deliver instructions and later messages    POST   /v1/tasks/<id>/input
                                                (blocks for the agent's ack)
  3. read live state or bounded transcript      GET    /v1/tasks/<id>/capture
                                                GET    /v1/tasks/<id>/screen
                                                GET    /v1/tasks/<id>/stream
                                                GET    /v1/tasks/<id>/processes
                                                GET    /v1/tasks/<id>/cwd
  4. archive/kill the exact endpoint            DELETE /v1/tasks/<id>
                                                (blocks for the agent's ack)
  5. report status into firstmate's records     the owning AGENT appends to its
                                                own home's state/<id>.status

Point 5 deliberately never travels through the hub.  The agent owns both the
record and the path, so no local path is ever sent to a remote process and no
route here writes outside this process.

RELAYING IS NOT THE SAME AS BEING LOCAL, and three guarantees have to be built
rather than assumed:

  * Delivery: an input or kill is only reported as delivered when the OWNING
    AGENT acknowledges it.  A queued command that no agent ever takes is a
    failure, not a success, because fm-send's refusal rests on it.
  * Freshness: agent state arrives as a published frame, not a synchronous
    read.  Every state answer carries its age, and a caller that needs a verdict
    refuses to give one from a stale frame.
  * Partition: a hub that has not heard from an agent cannot tell a dead worker
    from an unreachable one, so it never says `dead` on silence.  Only a
    positive agent report - the process is gone, or only a shell remains -
    means dead.

Commands:

  fm-stream-hub.py serve [options]        run the hub in the foreground
  fm-stream-hub.py --protocol             print the wire protocol number
  fm-stream-hub.py --version              print the hub version

serve options:

  --bind ADDR            listen address (default 127.0.0.1).  The hub is
                         reachable across machines by design; binding it wider
                         is a deployment decision, and so is the TLS terminator
                         that should sit in front of it.  This process never
                         terminates TLS itself and assumes nothing about the
                         scheme a client used to reach it.
  --port N               listen port (default 7717; 0 picks a free port and the
                         chosen one is printed on the ready line)
  --token-file PATH      file of token definitions, one per line, each either a
                         bare token (granting the default classes) or
                         "<classes>:<token>" where <classes> is a
                         comma-separated subset of publish,subscribe,control.
                         A bare token grants subscribe only, so a viewing
                         credential can never register an endpoint nor steer
                         one; an operating credential is spelled
                         "subscribe,control:<token>".
  --state-max-age-secs N how old a published state frame may be before a state
                         answer is reported stale (default 30)
  --command-ack-secs N   how long an input, kill, or Bridge order waits for the
                         owning agent's acknowledgement (default 20); a taken,
                         unanswered Bridge order remains unconfirmed
  --ready-file PATH      write "<bind> <port>" there once listening
  --pid-file PATH        write this process's pid there once listening

Nothing is written to disk except the optional --ready-file and --pid-file.
Terminal content lives only in the bounded in-memory ring and rendered screen.
"""

from __future__ import annotations

import argparse
import base64
import codecs
import collections
import errno
import hmac
import http.server
import json
import os
import re
import signal
import socket
import socketserver
import sys
import threading
import time
import unicodedata
import urllib.parse
import uuid
from http import HTTPStatus

HUB_VERSION = "2.0.0"

# The wire protocol the agent and the shell adapter implement.  A peer
# announcing anything else is refused rather than driven on guessed routes.
HUB_PROTOCOL = 2
HUB_CAPABILITIES = ("current_execution", "idempotent_command_results")

DEFAULT_PORT = 7717
DEFAULT_RING_BYTES = 262144
DEFAULT_SCROLLBACK = 2000
DEFAULT_STATE_MAX_AGE = 30.0
DEFAULT_COMMAND_ACK = 20.0
DEFAULT_ENDPOINT_RETENTION = 3600.0
# How many recent orders the hub can still answer for. The journal exists so a
# caller that lost the answer to its own request can ask what became of it
# rather than guessing or sending the order twice, which is a short-lived need;
# it is not a history of the fleet and nothing is persisted.
ORDER_JOURNAL_MAX = 512
COMMAND_RESULT_JOURNAL_MAX = 512
# How long a command an agent took but never acknowledged remains eligible for
# a late acknowledgement. It is kept far past the initial acknowledgement
# window because that is exactly the command whose fate a caller most needs to
# settle, and becomes eligible for reaping eventually because an agent that has
# not answered it by then is not going to.
UNACKNOWLEDGED_COMMAND_RETENTION = 900.0
# How much longer than a placement's own worst case a resend of that order id
# waits for the call still placing it to answer. Placing is bounded by the
# fixed membership window plus the acknowledgement window, so this covers only
# scheduling between those waits and the answer; past it, the live record is
# the honest thing to return.
ORDER_ANSWER_SLACK_SECS = 5.0
# How long an endpoint may say nothing before the hub presumes its agent is
# gone. A presumption is not a close: the endpoint stays listed, stays
# streamable and stays steerable, because a worker the hub has merely not heard
# from lately may be perfectly healthy. All the presumption does is release the
# identity, so the next attempt at that task can claim the name. The hub hears from an agent on every frame, every state heartbeat, and
# every command poll, so this is several missed heartbeats. It is deliberately
# shorter than the agent's own startup budget, so the record an abandoned spawn
# left behind is gone before anyone could retry that task.
#
# The presumption is never a fact. An agent that comes back - after a hub
# restart, a network drop, anything its command loop is built to survive -
# revives its own endpoint by contacting the hub, because a worker whose tokens
# are still arriving is not gone whatever the hub concluded while it could not
# hear it. The one case with no way back is the lost one: the label has since
# been taken by another live endpoint, and two workers must never answer to one
# identity.
AGENT_SILENCE_PRESUMED_SECS = 10.0
# How long a leaf must keep failing to resolve before the hub will call it
# absent. The registry is in memory, so a hub that restarted holds nothing
# until each agent registers again - and a first-reply miss during that window
# would report every live worker in the fleet as gone at once. Waiting it out
# is what makes the answer a membership verdict instead of a reading, and it
# matches the window bin/backends/stream.sh's recovery-grade classifier waits
# before it will say `missing`.
MEMBERSHIP_GRACE_SECS = 6.0
MAX_BODY = 4 * 1024 * 1024
MAX_LABEL_LEN = 128
MAX_MACHINE_LEN = 128

# Token classes.  Publishing, watching, and steering are separate credentials
# from the first release: registering an endpoint starts a process on a worker
# machine, and typing into or killing one is another operator's live terminal,
# so a viewing credential must never be able to do either.  A token holds a SET
# of classes rather than one, so narrowing or widening what a credential may do
# - including adding a class this release does not define - stays a token-file
# edit rather than a protocol change.  Watching and steering are split because
# two classes cannot express what a fleet needs: one URL must watch every
# worker and type back, while a link handed to someone else must only watch.
# The three answers an order can get, and the whole of the difference between
# them. ACCEPTED means the owning agent applied it to the worker and said so.
# REFUSED means it did not reach the worker and the hub can say why. UNCONFIRMED
# means the hub does not know - which is not a failure and must never be
# rendered as either of the others.
ORDER_ACCEPTED = "accepted"
ORDER_REFUSED = "refused"
ORDER_UNCONFIRMED = "unconfirmed"

CLASS_PUBLISH = "publish"
CLASS_SUBSCRIBE = "subscribe"
CLASS_CONTROL = "control"
TOKEN_CLASSES = (CLASS_PUBLISH, CLASS_SUBSCRIBE, CLASS_CONTROL)

# A bare token in the token file grants these.  Publishing and steering are
# deliberately NOT among them: registering an endpoint means starting a process
# on a worker machine and steering means typing into or killing one, so those
# credentials must always be named explicitly and the careless line in a token
# file is the read-only one.
DEFAULT_CLASSES = (CLASS_SUBSCRIBE,)

LABEL_RE = re.compile(r"\A[A-Za-z0-9._@%%+-]{1,%d}\Z" % MAX_LABEL_LEN)
# The status vocabulary bin/fm-classify-lib.sh reconciles. The hub refuses
# anything outside it so the return channel cannot append a line firstmate's
# classifier would not understand.
STATUS_STATES = ("working", "needs-decision", "blocked", "paused", "done",
                 "failed", "resolved")

MACHINE_RE = re.compile(r"\A[A-Za-z0-9._-]{1,%d}\Z" % MAX_MACHINE_LEN)
ENDPOINT_ID_RE = re.compile(r"\A[0-9a-f]{32}\Z")
COMMAND_ID_RE = re.compile(r"\A[0-9a-f]{32}\Z")
# An order id is the CALLER's, because reconciliation is the caller asking what
# became of the id it issued. A uuid with or without dashes fits, and so does
# anything else safe to put in a path.
ORDER_ID_RE = re.compile(r"\A[A-Za-z0-9._-]{1,128}\Z")


def _now() -> float:
    return time.time()

# --- terminal model ---------------------------------------------------------


def _char_width(ch: str) -> int:
    """Display columns one character occupies.

    Combining marks take none, East Asian wide and fullwidth forms take two,
    everything else takes one.  The broker needs this because it renders a
    real screen for the composer classifier rather than replaying raw bytes:
    a miscounted wide glyph would shift every column after it and could move
    a composer border out from under its own row.
    """
    if unicodedata.combining(ch):
        return 0
    if unicodedata.category(ch) in ("Mn", "Me", "Cf"):
        return 0
    if unicodedata.east_asian_width(ch) in ("W", "F"):
        return 2
    return 1


class Attrs:
    """The SGR state the screen tracks per cell.

    Only the attributes firstmate's shared composer classifier reads are kept:
    dim/faint and truecolor foregrounds are what
    bin/fm-composer-lib.sh's ghost stripper looks for, and the remaining
    intensity and colour codes are carried so a styled render round-trips
    close enough for that stripper to see the same runs a real terminal shows.
    """

    __slots__ = ("bold", "dim", "italic", "underline", "blink", "reverse", "hidden", "strike", "fg", "bg")

    def __init__(self) -> None:
        self.reset()

    def reset(self) -> None:
        self.bold = False
        self.dim = False
        self.italic = False
        self.underline = False
        self.blink = False
        self.reverse = False
        self.hidden = False
        self.strike = False
        self.fg = ""
        self.bg = ""

    def copy(self) -> "Attrs":
        other = Attrs()
        for name in Attrs.__slots__:
            setattr(other, name, getattr(self, name))
        return other

    def serialize(self) -> str:
        parts = []
        if self.bold:
            parts.append("1")
        if self.dim:
            parts.append("2")
        if self.italic:
            parts.append("3")
        if self.underline:
            parts.append("4")
        if self.blink:
            parts.append("5")
        if self.reverse:
            parts.append("7")
        if self.hidden:
            parts.append("8")
        if self.strike:
            parts.append("9")
        if self.fg:
            parts.append(self.fg)
        if self.bg:
            parts.append(self.bg)
        return ";".join(parts)

    def apply_sgr(self, params: list[str]) -> None:
        if not params:
            params = ["0"]
        i = 0
        while i < len(params):
            raw = params[i] or "0"
            # A colon-subparameter colour (38:2::r:g:b) arrives as one token.
            head = raw.split(":", 1)[0] or "0"
            try:
                code = int(head)
            except ValueError:
                i += 1
                continue
            if code == 0:
                self.reset()
            elif code == 1:
                self.bold = True
            elif code == 2:
                self.dim = True
            elif code == 3:
                self.italic = True
            elif code == 4:
                self.underline = True
            elif code == 5:
                self.blink = True
            elif code == 7:
                self.reverse = True
            elif code == 8:
                self.hidden = True
            elif code == 9:
                self.strike = True
            elif code in (21, 22):
                self.bold = False
                self.dim = False
            elif code == 23:
                self.italic = False
            elif code == 24:
                self.underline = False
            elif code == 25:
                self.blink = False
            elif code == 27:
                self.reverse = False
            elif code == 28:
                self.hidden = False
            elif code == 29:
                self.strike = False
            elif (30 <= code <= 37) or (90 <= code <= 97):
                self.fg = str(code)
            elif code == 39:
                self.fg = ""
            elif (40 <= code <= 47) or (100 <= code <= 107):
                self.bg = str(code)
            elif code == 49:
                self.bg = ""
            elif code in (38, 48):
                spec, consumed = self._extended_colour(params, i, raw)
                if code == 38:
                    self.fg = spec
                else:
                    self.bg = spec
                i += consumed
            i += 1

    @staticmethod
    def _extended_colour(params: list[str], i: int, raw: str) -> tuple[str, int]:
        """The 38/48 colour starting at params[i], plus how many extra tokens it ate."""
        if ":" in raw:
            return raw, 0
        mode = params[i + 1] if i + 1 < len(params) else ""
        if mode == "5" and i + 2 < len(params):
            return ";".join(params[i : i + 3]), 2
        if mode == "2" and i + 4 < len(params):
            return ";".join(params[i : i + 5]), 4
        return "", 1


BLANK = (" ", "")
# A wide character's second column: no glyph of its own, so it renders as
# nothing and the leading cell carries the whole character.
CONTINUATION = ("", "")


class Screen:
    """A bounded VT-style screen plus scrollback, fed raw pseudoterminal bytes.

    This exists because every supervision read firstmate performs - the
    composer classifier, fm-peek's bounded capture, the watcher's change
    detection - is defined over a rendered SCREEN, not over a byte stream.  A
    broker that only relayed bytes would force each of those readers to grow
    its own terminal emulator.
    """

    def __init__(self, rows: int, cols: int, scrollback: int = DEFAULT_SCROLLBACK) -> None:
        self.rows = max(1, rows)
        self.cols = max(1, cols)
        self.cells = [self._blank_row() for _ in range(self.rows)]
        self.scrollback: collections.deque = collections.deque(maxlen=max(0, scrollback))
        self.cy = 0
        self.cx = 0
        self.attrs = Attrs()
        self.top = 0
        self.bot = self.rows - 1
        self._saved = (0, 0, Attrs())
        self._decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
        self._state = "text"
        self._buf = ""

    def _blank_row(self) -> list:
        return [BLANK] * self.cols

    # -- feeding ------------------------------------------------------------

    def feed(self, data: bytes) -> None:
        text = self._decoder.decode(data)
        for ch in text:
            self._feed_char(ch)

    def _feed_char(self, ch: str) -> None:
        state = self._state
        if state == "text":
            self._feed_text(ch)
        elif state == "esc":
            self._feed_esc(ch)
        elif state == "csi":
            if "\x40" <= ch <= "\x7e":
                self._dispatch_csi(self._buf, ch)
                self._state = "text"
            else:
                self._buf += ch
                if len(self._buf) > 64:
                    self._state = "text"
        elif state == "charset":
            self._state = "text"
        elif state in ("osc", "dcs"):
            # Both end at BEL or the two-character string terminator ESC \.
            if ch == "\x07":
                self._state = "text"
            elif ch == "\x1b":
                self._state = state + "-esc"
            elif len(self._buf) > 4096:
                self._state = "text"
            else:
                self._buf += ch
        elif state in ("osc-esc", "dcs-esc"):
            self._state = "text"
            if ch != "\\":
                self._feed_char(ch)

    def _feed_text(self, ch: str) -> None:
        if ch == "\x1b":
            self._state = "esc"
            self._buf = ""
        elif ch == "\r":
            self.cx = 0
        elif ch in ("\n", "\x0b", "\x0c"):
            self._linefeed()
        elif ch == "\b":
            self.cx = max(0, self.cx - 1)
        elif ch == "\t":
            self.cx = min(self.cols - 1, ((self.cx // 8) + 1) * 8)
        elif ch == "\x07":
            pass
        elif ch < " " and ch != "\x00":
            pass
        elif ch >= " ":
            self._put(ch)

    def _feed_esc(self, ch: str) -> None:
        if ch == "[":
            self._state = "csi"
            self._buf = ""
        elif ch == "]":
            self._state = "osc"
            self._buf = ""
        elif ch in ("P", "X", "^", "_"):
            self._state = "dcs"
            self._buf = ""
        elif ch in ("(", ")", "*", "+", "%"):
            self._state = "charset"
        elif ch == "7":
            self._saved = (self.cy, self.cx, self.attrs.copy())
            self._state = "text"
        elif ch == "8":
            self.cy, self.cx, attrs = self._saved
            self.attrs = attrs.copy()
            self._state = "text"
        elif ch == "M":
            self._reverse_index()
            self._state = "text"
        elif ch in ("D", "E"):
            if ch == "E":
                self.cx = 0
            self._linefeed()
            self._state = "text"
        elif ch == "c":
            self._full_reset()
            self._state = "text"
        else:
            self._state = "text"

    def _full_reset(self) -> None:
        self.cells = [self._blank_row() for _ in range(self.rows)]
        self.cy = self.cx = 0
        self.attrs = Attrs()
        self.top = 0
        self.bot = self.rows - 1

    def _put(self, ch: str) -> None:
        width = _char_width(ch)
        if width == 0:
            # Combine onto the previous cell rather than dropping the mark.
            prev = self.cx - 1
            if prev >= 0:
                glyph, sgr = self.cells[self.cy][prev]
                self.cells[self.cy][prev] = (glyph + ch, sgr)
            return
        if self.cx + width > self.cols:
            self.cx = 0
            self._linefeed()
        sgr = self.attrs.serialize()
        self.cells[self.cy][self.cx] = (ch, sgr)
        for extra in range(1, width):
            if self.cx + extra < self.cols:
                self.cells[self.cy][self.cx + extra] = CONTINUATION
        self.cx += width
        if self.cx > self.cols - 1:
            self.cx = self.cols

    def _linefeed(self) -> None:
        if self.cy == self.bot:
            self._scroll_up(1)
        elif self.cy < self.rows - 1:
            self.cy += 1

    def _reverse_index(self) -> None:
        if self.cy == self.top:
            self._scroll_down(1)
        elif self.cy > 0:
            self.cy -= 1

    def _scroll_up(self, count: int) -> None:
        for _ in range(count):
            row = self.cells.pop(self.top)
            # Only a full-height region's departing row is real history; a row
            # scrolled out of a smaller region was never the top of the screen.
            if self.top == 0 and self.scrollback.maxlen:
                self.scrollback.append(row)
            self.cells.insert(self.bot, self._blank_row())

    def _scroll_down(self, count: int) -> None:
        for _ in range(count):
            self.cells.pop(self.bot)
            self.cells.insert(self.top, self._blank_row())

    # -- CSI ----------------------------------------------------------------

    def _dispatch_csi(self, buf: str, final: str) -> None:
        private = buf[:1] in ("?", ">", "<", "=")
        body = buf[1:] if private else buf
        raw = [p for p in body.split(";")] if body else []

        def num(idx: int, default: int = 1) -> int:
            if idx >= len(raw):
                return default
            token = raw[idx].split(":", 1)[0]
            if not token:
                return default
            try:
                value = int(token)
            except ValueError:
                return default
            return value

        if private:
            # Mode sets and resets (cursor visibility, bracketed paste, the
            # alternate screen) change no cell content the readers care about.
            return
        if final == "m":
            self.attrs.apply_sgr(raw)
        elif final in ("A", "e"):
            self.cy = max(self.top, self.cy - max(1, num(0)))
        elif final == "B":
            self.cy = min(self.bot, self.cy + max(1, num(0)))
        elif final in ("C", "a"):
            self.cx = min(self.cols - 1, self.cx + max(1, num(0)))
        elif final == "D":
            self.cx = max(0, self.cx - max(1, num(0)))
        elif final == "E":
            self.cy = min(self.bot, self.cy + max(1, num(0)))
            self.cx = 0
        elif final == "F":
            self.cy = max(self.top, self.cy - max(1, num(0)))
            self.cx = 0
        elif final in ("G", "`"):
            self.cx = min(self.cols - 1, max(0, num(0) - 1))
        elif final == "d":
            self.cy = min(self.rows - 1, max(0, num(0) - 1))
        elif final in ("H", "f"):
            self.cy = min(self.rows - 1, max(0, num(0) - 1))
            self.cx = min(self.cols - 1, max(0, num(1) - 1))
        elif final == "J":
            self._erase_display(num(0, 0))
        elif final == "K":
            self._erase_line(num(0, 0))
        elif final == "L":
            self._insert_lines(max(1, num(0)))
        elif final == "M":
            self._delete_lines(max(1, num(0)))
        elif final == "P":
            self._delete_chars(max(1, num(0)))
        elif final == "@":
            self._insert_chars(max(1, num(0)))
        elif final == "X":
            count = max(1, num(0))
            row = self.cells[self.cy]
            for x in range(self.cx, min(self.cols, self.cx + count)):
                row[x] = BLANK
        elif final == "S":
            self._scroll_up(max(1, num(0)))
        elif final == "T":
            self._scroll_down(max(1, num(0)))
        elif final == "r":
            top = max(0, num(0) - 1)
            bot = min(self.rows - 1, num(1, self.rows) - 1)
            if top < bot:
                self.top, self.bot = top, bot
                self.cy, self.cx = top, 0
        elif final == "s":
            self._saved = (self.cy, self.cx, self.attrs.copy())
        elif final == "u":
            self.cy, self.cx, attrs = self._saved
            self.attrs = attrs.copy()

    def _erase_display(self, mode: int) -> None:
        if mode == 2 or mode == 3:
            self.cells = [self._blank_row() for _ in range(self.rows)]
            return
        if mode == 0:
            self._erase_line(0)
            for y in range(self.cy + 1, self.rows):
                self.cells[y] = self._blank_row()
        elif mode == 1:
            self._erase_line(1)
            for y in range(0, self.cy):
                self.cells[y] = self._blank_row()

    def _erase_line(self, mode: int) -> None:
        row = self.cells[self.cy]
        if mode == 0:
            for x in range(self.cx, self.cols):
                row[x] = BLANK
        elif mode == 1:
            for x in range(0, min(self.cx + 1, self.cols)):
                row[x] = BLANK
        else:
            self.cells[self.cy] = self._blank_row()

    def _insert_lines(self, count: int) -> None:
        if not (self.top <= self.cy <= self.bot):
            return
        for _ in range(count):
            self.cells.pop(self.bot)
            self.cells.insert(self.cy, self._blank_row())

    def _delete_lines(self, count: int) -> None:
        if not (self.top <= self.cy <= self.bot):
            return
        for _ in range(count):
            self.cells.pop(self.cy)
            self.cells.insert(self.bot, self._blank_row())

    def _delete_chars(self, count: int) -> None:
        row = self.cells[self.cy]
        for _ in range(count):
            if self.cx < self.cols:
                row.pop(self.cx)
                row.append(BLANK)

    def _insert_chars(self, count: int) -> None:
        row = self.cells[self.cy]
        for _ in range(count):
            if self.cx < self.cols:
                row.insert(self.cx, BLANK)
                row.pop()

    # -- rendering ----------------------------------------------------------

    @staticmethod
    def _row_plain(row: list) -> str:
        return "".join(cell[0] for cell in row).rstrip()

    @staticmethod
    def _row_ansi(row: list) -> str:
        plain_len = len(Screen._row_plain(row))
        if plain_len == 0:
            return ""
        out = []
        current = ""
        used = 0
        for cell in row:
            if used >= plain_len:
                break
            glyph, sgr = cell
            if sgr != current:
                out.append("\x1b[0m" if sgr == "" else "\x1b[%sm" % sgr)
                current = sgr
            out.append(glyph)
            used += len(glyph)
        if current != "":
            out.append("\x1b[0m")
        return "".join(out)

    def _render_rows(self, rows: list, ansi: bool) -> list[str]:
        render = self._row_ansi if ansi else self._row_plain
        return [render(row) for row in rows]

    def screen_lines(self, ansi: bool = False) -> list[str]:
        return self._render_rows(self.cells, ansi)

    def tail_lines(self, count: int, ansi: bool = False) -> list[str]:
        """The last <count> rendered lines of scrollback plus screen.

        Trailing blank rows are dropped first, so a 40-row screen holding two
        lines of output reads like tmux's capture rather than like 38 empty
        rows, and a caller asking for 40 lines of a young endpoint is not
        handed mostly padding.
        """
        rows = list(self.scrollback) + self.cells
        while rows and self._row_plain(rows[-1]) == "":
            rows.pop()
        if count > 0:
            rows = rows[-count:]
        return self._render_rows(rows, ansi)


# --- ring buffer ------------------------------------------------------------


class Ring:
    """A bounded byte ring with absolute offsets, for late stream subscribers.

    Absolute offsets are what make a reconnecting subscriber resumable without
    persisting anything: it asks for everything after the last offset it saw,
    and the broker either serves it from the ring or tells it how far the ring
    has already advanced.
    """

    def __init__(self, capacity: int) -> None:
        self.capacity = max(1024, capacity)
        self._buf = bytearray()
        self.start = 0  # absolute offset of self._buf[0]
        self.end = 0  # absolute offset just past the last byte

    def append(self, data: bytes) -> None:
        self._buf.extend(data)
        self.end += len(data)
        overflow = len(self._buf) - self.capacity
        if overflow > 0:
            del self._buf[:overflow]
            self.start += overflow

    def read_from(self, offset: int) -> tuple[int, bytes]:
        """Bytes at or after <offset>, plus the offset they actually begin at."""
        if offset < self.start:
            offset = self.start
        if offset >= self.end:
            return self.end, b""
        return offset, bytes(self._buf[offset - self.start :])


# --- tasks ------------------------------------------------------------------


# --- hub model --------------------------------------------------------------


class HubError(Exception):
    """A refusal, and the facts a caller needs to act on it.

    `details` carries the order path's typed answer - the outcome, which
    execution was addressed, and whether the hub holds evidence the worker is
    gone - so a refusal is as readable as an acceptance instead of collapsing
    into one message string.
    """

    def __init__(self, status: int, code: str, message: str, details: dict = None) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message
        self.details = details or {}


class Command:
    """One input or kill on its way down to the agent that owns an endpoint.

    The acknowledgement is the point.  A relayed command that is merely queued
    has NOT been delivered, and reporting it as delivered would quietly remove
    the refusal fm-send's guarantee rests on, so every command carries an event
    the requesting thread waits on and a result the owning agent fills in.
    """

    __slots__ = ("command_id", "endpoint_id", "machine", "kind", "payload",
                 "created_at", "taken_at", "done", "ok", "error", "withdrawn")

    def __init__(self, endpoint_id: str, machine: str, kind: str, payload: dict) -> None:
        self.command_id = uuid.uuid4().hex
        self.endpoint_id = endpoint_id
        self.machine = machine
        self.kind = kind
        self.payload = payload
        self.created_at = _now()
        self.taken_at = 0.0
        self.done = threading.Event()
        self.ok = False
        self.error = ""
        # Pulled back out of the queue before any agent took it. That is the
        # one circumstance in which the hub can say a command was NOT
        # delivered; a command an agent has already taken is never withdrawn,
        # because withdrawing it would not unsend it.
        self.withdrawn = False

    def describe(self) -> dict:
        return {
            "command_id": self.command_id,
            "endpoint_id": self.endpoint_id,
            "kind": self.kind,
            "payload": self.payload,
        }


class Order:
    """One leaf-addressed order, and what is known about its fate.

    The record holds the Command rather than a copy of its verdict, so resending
    an order reports what is true NOW.  An order the hub answered as
    unconfirmed becomes accepted the moment a late acknowledgement arrives,
    with nothing to keep in step.
    """

    __slots__ = ("order_id", "leaf_worker_id", "requested_execution_id",
                 "execution_id", "created_at", "endpoint", "command", "refusal",
                 "status", "answered")

    def __init__(self, order_id: str, leaf: str, requested_execution: str,
                 execution: str, endpoint: "Endpoint") -> None:
        self.order_id = order_id
        self.leaf_worker_id = leaf
        self.requested_execution_id = requested_execution
        self.execution_id = execution
        self.created_at = _now()
        # The addressed endpoint's own record, or None when the leaf resolved
        # to nothing. It is held rather than copied because the worker_gone
        # verdict below has to be read from it at answering time.
        self.endpoint = endpoint
        # Set when an order reached the command router; None when it was
        # refused before that, which is every membership refusal.
        self.command = None
        # (code, message) for an order no command was ever made for. The
        # refusal IS the whole record in that case.
        self.refusal = None
        # The status this order was first answered with, so a caller that
        # resends its id is told the same thing rather than a second opinion.
        self.status = HTTPStatus.OK
        # Set once the placement call that owns this order has answered, in
        # success or refusal. A resend of this order's id that arrives before
        # then waits on it rather than reading a record still being written
        # - or placing the order a second time.
        self.answered = threading.Event()

    def worker_gone(self) -> bool:
        """Whether the hub holds the owning AGENT's own report that the worker ended.

        This is the only authoritative absence the hub has, and it is read from
        one place for every answer.  A close the hub made by itself is
        bookkeeping about a record it could no longer steer and says nothing
        about the worker, so it is never counted here - and neither is silence,
        an unreachable agent, or a leaf the hub cannot currently resolve.
        """
        return bool(self.endpoint is not None and self.endpoint.closed_by == "agent")

    def outcome(self) -> tuple:
        """(outcome, code, message, delivered), read live.

        `delivered` is None, never False, wherever the hub cannot tell.  That
        distinction is the point of the whole record: False is a fact the hub
        is entitled to state, and None is the honest absence of one.
        """
        if self.refusal is not None:
            code, message = self.refusal
            return (ORDER_REFUSED, code, message, False)
        command = self.command
        if command is None:
            if self.refusal is None and not self.answered.is_set():
                return (ORDER_UNCONFIRMED, "routing",
                        "the order is still being placed, so nothing is known "
                        "yet of its delivery", None)
            return (ORDER_REFUSED, "not_submitted",
                    "no command was ever made for this order, so nothing was "
                    "delivered", False)
        if command.done.is_set():
            if command.ok:
                return (ORDER_ACCEPTED, "", "", True)
            # The agent looked at its own worker and would not apply the order.
            return (ORDER_REFUSED, "agent_refused",
                    command.error or "the owning agent refused the order", False)
        if command.withdrawn:
            return (ORDER_REFUSED, "no_agent_ack",
                    "no agent took the order, so it was not delivered", False)
        if command.taken_at:
            return (ORDER_UNCONFIRMED, "no_agent_ack",
                    "the owning agent took the order and has not acknowledged it, "
                    "so whether the worker received it is not known", None)
        return (ORDER_UNCONFIRMED, "queued",
                "the order is queued for the owning agent and has not been taken", None)

    def describe(self) -> dict:
        outcome, code, message, delivered = self.outcome()
        record = {
            "order_id": self.order_id,
            "leaf_worker_id": self.leaf_worker_id,
            "requested_execution_id": self.requested_execution_id,
            "execution_id": self.execution_id,
            "outcome": outcome,
            "delivered": delivered,
            "worker_gone": self.worker_gone(),
            # The other authoritative absence: the hub kept holding no
            # registration for this leaf for longer than a rejoin takes.
            "not_registered": self.refusal is not None and self.refusal[0] == "unknown_leaf",
            "requested_at": self.created_at,
        }
        if code:
            record["reason"] = code
        if message:
            record["reason_message"] = message
        return record


class Endpoint:
    """One worker's pseudoterminal, as the hub knows it.

    The hub never owns the pty.  It holds what the owning agent published: the
    raw output frames, a screen rendered from them, and the last state frame
    with the time it arrived.
    """

    def __init__(self, endpoint_id: str, machine: str, label: str, cwd: str,
                 rows: int, cols: int, ring_bytes: int, scrollback: int) -> None:
        self.endpoint_id = endpoint_id
        self.machine = machine
        self.label = label
        self.cwd = cwd
        self.rows = rows
        self.cols = cols
        self.created_at = _now()
        self.closed_at = 0.0
        # Who ended this endpoint: "agent" when its own agent reported the
        # worker gone and carried the exit code with it, "hub" when the hub
        # closed a record it could no longer steer. Only the first is evidence
        # about the worker; the second is bookkeeping.
        self.closed_by = ""
        # The hub has not heard from this endpoint's agent lately. It says
        # nothing about the worker, which is why it closes nothing and hides
        # nothing: it only frees the name for the next attempt at this task.
        self.presumed_gone = False
        self.exit_code = None
        self.screen = Screen(rows, cols, scrollback)
        self.ring = Ring(ring_bytes)
        self.lock = threading.Lock()
        self.wake = threading.Condition(self.lock)
        # The last published state frame, and when the hub received it. Both
        # matter: the agent's own timestamp can be skewed against this clock,
        # so freshness is measured against arrival here.
        self.state = {}
        self.state_received_at = 0.0
        # The last time THIS endpoint's own agent spoke to the hub, by any
        # route. One agent owns one endpoint, so this is the precise reachability
        # signal; the machine-level one only groups the viewer.
        self.agent_seen_at = _now()
        # Registering is not speaking. An agent proves it is there by polling
        # for commands or publishing, and until it has, this record stands for
        # nothing the hub has ever heard from.
        self.heard_from = False

    def feed(self, data: bytes) -> None:
        with self.wake:
            self.agent_seen_at = _now()
            self.ring.append(data)
            self.screen.feed(data)
            self.wake.notify_all()

    def publish_state(self, state: dict) -> None:
        with self.wake:
            self.state = state
            self.state_received_at = _now()
            self.agent_seen_at = self.state_received_at
            self.wake.notify_all()

    def agent_silent_for(self) -> float:
        return max(0.0, _now() - self.agent_seen_at)

    def mark_closed(self, exit_code, closed_by: str) -> None:
        """Close the record, first writer wins - with one asymmetry.

        A CLOSE RECORD MOVES FROM PRESUMPTION TO FACT, NEVER THE REVERSE.
        A `hub` close is a presumption: the hub stopped carrying a record it
        could no longer steer, and it knows nothing about that worker. An
        `agent` close is a fact: the owning agent watched its worker exit and
        brought the exit code back. So the agent's report may take over a
        record the hub force-closed - the partition healed, the worker ran on,
        then ended - and the hub's may never take over the agent's.

        The rule governs the WHOLE record, not the attribution alone: who
        closed it and the evidence that close carries are one statement about
        one event. A presumption that cannot claim the attribution must not be
        able to erase the exit code either, so the hub's empty-handed close
        leaves an agent's findings exactly as they stand. That asymmetry is
        what keeps an unacknowledged kill from ever claiming confirmation.
        """
        with self.wake:
            if not self.closed_at:
                self.closed_at = _now()
                self.closed_by = closed_by
                self.exit_code = exit_code
            elif closed_by == "agent":
                self.closed_by = closed_by
                self.exit_code = exit_code
            self.wake.notify_all()

    def wait_for(self, offset: int, timeout: float) -> tuple:
        """Block until output past <offset> exists, or the wait elapses."""
        deadline = _now() + timeout
        with self.wake:
            while True:
                start, data = self.ring.read_from(offset)
                if data or self.closed_at:
                    return start, data, bool(self.closed_at)
                remaining = deadline - _now()
                if remaining <= 0:
                    return self.ring.end, b"", bool(self.closed_at)
                self.wake.wait(remaining)

    def state_age(self) -> float:
        """Seconds since the last state frame arrived, or -1 if none ever did."""
        if not self.state_received_at:
            return -1.0
        return max(0.0, _now() - self.state_received_at)

    def describe(self) -> dict:
        age = self.state_age()
        return {
            "endpoint_id": self.endpoint_id,
            "machine": self.machine,
            "label": self.label,
            "cwd": self.cwd,
            "rows": self.rows,
            "cols": self.cols,
            "created_at": self.created_at,
            "closed_at": self.closed_at or None,
            "closed_by": self.closed_by or None,
            "exit_code": self.exit_code,
            "stream_offset": self.ring.end,
            "state_age_secs": None if age < 0 else round(age, 3),
            "agent_silent_for_secs": round(self.agent_silent_for(), 3),
        }


class Machine:
    """One worker machine's agent, as the hub knows it."""

    def __init__(self, name: str) -> None:
        self.name = name
        self.first_seen = _now()
        self.last_seen = _now()
        self.queue: list = []
        self.pending: dict = {}
        self.completed: "collections.OrderedDict" = collections.OrderedDict()

    def describe(self, silent_after: float) -> dict:
        silent_for = max(0.0, _now() - self.last_seen)
        return {
            "machine": self.name,
            "first_seen": self.first_seen,
            "last_seen": self.last_seen,
            "silent_for_secs": round(silent_for, 3),
            "reachable": silent_for <= silent_after,
        }


def parse_token_line(line: str) -> tuple:
    """One token-file line -> (token, frozenset(classes)).

    A bare token grants DEFAULT_CLASSES.  "<classes>:<token>" names them
    explicitly.  Splitting publishing from subscribing is therefore a token-file
    edit and nothing else - no client and no route changes shape.
    """
    line = line.strip()
    if not line or line.startswith("#"):
        return ("", frozenset())
    if ":" in line:
        raw_classes, token = line.split(":", 1)
        token = token.strip()
        names = [c.strip() for c in raw_classes.split(",") if c.strip()]
        unknown = [c for c in names if c not in TOKEN_CLASSES]
        if unknown:
            raise ValueError("unknown token class %r (known: %s)"
                             % (unknown[0], ",".join(TOKEN_CLASSES)))
        if not names:
            raise ValueError("token line names no classes")
        if not token:
            raise ValueError("token line has an empty token")
        return (token, frozenset(names))
    return (line, frozenset(DEFAULT_CLASSES))


class Hub:
    """The fleet's single registry, history, fan-out, and command router."""

    def __init__(self, options: argparse.Namespace, tokens: dict) -> None:
        self.options = options
        self.tokens = tokens
        self.endpoints: dict = {}
        self.machines: dict = {}
        self.lock = threading.RLock()
        self.command_wake = threading.Condition(self.lock)
        self.orders: "collections.OrderedDict" = collections.OrderedDict()
        self.started_at = _now()

    # --- authentication ---------------------------------------------------

    def classes_for(self, presented: str) -> frozenset:
        """The classes a presented token holds, compared without early exit.

        Every configured token is compared even after a match, so the time this
        takes does not depend on which token was presented or how far down the
        file it sits.
        """
        granted = frozenset()
        for token, classes in self.tokens.items():
            if _constant_time_equals(token, presented):
                granted = classes
        return granted

    # --- machines ---------------------------------------------------------

    def touch_machine(self, name: str) -> "Machine":
        with self.lock:
            machine = self.machines.get(name)
            if machine is None:
                machine = Machine(name)
                self.machines[name] = machine
            machine.last_seen = _now()
            return machine

    def touch_endpoint(self, endpoint_id: str) -> None:
        """Record that this endpoint's own agent just spoke to the hub.

        Freshness asks whether the OWNING agent is still reachable, not whether
        the worker printed anything. An idle worker publishes no output and may
        publish no new state for a while, and letting that read as stale would
        turn every quiet endpoint into an unreadable one.
        """
        with self.lock:
            endpoint = self.endpoints.get(endpoint_id)
            if endpoint is not None:
                self.agent_spoke(endpoint)

    def agent_spoke(self, endpoint: "Endpoint") -> None:
        """The owning agent is heard from, and its claim to the name is tested.

        Two records can only share one machine and label while the hub has
        stopped hearing from one of them, so the claim is tested whenever this
        endpoint could be that one: it is marked presumed gone, it has never
        been heard from, or it has in fact been silent long enough for its name
        to have been freed. The last is the same elapsed silence that frees a
        name in the first place, read here rather than taken from the marker
        that stands for it - the marker is only written when something happens
        to reap, so a quiet hub would otherwise let a record back in
        uncontested. Testing all three is what makes the rule the same rule
        whichever agent speaks first: no order of events leaves two open
        records answering to one name, and none decides it one way and its
        mirror the other.
        """
        with self.lock:
            contested = (endpoint.presumed_gone or not endpoint.heard_from
                         or endpoint.agent_silent_for() > AGENT_SILENCE_PRESUMED_SECS)
            if contested:
                for other in self.endpoints.values():
                    if other is endpoint or other.closed_at:
                        continue
                    # The name goes to whichever agent has most recently proven
                    # itself REACHABLE, not to whichever record is newer or was
                    # created more lately. Registering is not proof: a record
                    # nothing has ever been heard from takes no name from a
                    # worker that is publishing now, at any age.
                    if not other.heard_from:
                        continue
                    if other.agent_silent_for() > AGENT_SILENCE_PRESUMED_SECS:
                        continue
                    if other.machine == endpoint.machine and other.label == endpoint.label:
                        raise HubError(HTTPStatus.GONE, "endpoint_superseded",
                                       "machine %s serves %s from another endpoint, "
                                       "not from %s"
                                       % (endpoint.machine, endpoint.label,
                                          endpoint.endpoint_id))
                endpoint.presumed_gone = False
            # A loser never counts as reachable, so it cannot go on to unseat
            # the endpoint that just beat it.
            endpoint.agent_seen_at = _now()
            endpoint.heard_from = True

    def list_machines(self) -> list:
        """A snapshot of the machines, taken under the lock like list_endpoints.

        Every read of shared state here takes the lock and renders outside it:
        a threaded server means a machine can be registered while a listing is
        being built, and iterating the live dict raises rather than answering.
        """
        with self.lock:
            return sorted(self.machines.values(), key=lambda m: m.name)

    def machine_silent_for(self, name: str) -> float:
        with self.lock:
            machine = self.machines.get(name)
            if machine is None:
                return -1.0
            return max(0.0, _now() - machine.last_seen)

    # --- endpoints --------------------------------------------------------

    def register_endpoint(self, payload: dict) -> "Endpoint":
        endpoint_id = str(payload.get("endpoint_id") or "")
        if not ENDPOINT_ID_RE.match(endpoint_id):
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_endpoint_id",
                           "endpoint_id must be 32 lowercase hex characters")
        machine = str(payload.get("machine") or "")
        if not MACHINE_RE.match(machine):
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_machine",
                           "machine must be 1-%d characters of [A-Za-z0-9._-]" % MAX_MACHINE_LEN)
        label = str(payload.get("label") or "")
        if not LABEL_RE.match(label):
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_label",
                           "label must be 1-%d characters of [A-Za-z0-9._@%%+-]" % MAX_LABEL_LEN)
        cwd = str(payload.get("cwd") or "")
        rows = _positive_int(payload.get("rows"), 40, "rows")
        cols = _positive_int(payload.get("cols"), 200, "cols")
        # A label is only claimed by an endpoint that still has an agent, so
        # the silence check runs before the claim is tested rather than waiting
        # for the next listing call to notice.
        self.reap()
        with self.lock:
            existing = self.endpoints.get(endpoint_id)
            if existing is not None:
                # Re-registration by the same machine is how an agent recovers
                # its own endpoint after a reconnect; a DIFFERENT machine
                # claiming a live id would silently take over another worker.
                if existing.machine != machine:
                    raise HubError(HTTPStatus.CONFLICT, "endpoint_owned_elsewhere",
                                   "endpoint %s is registered to machine %s"
                                   % (endpoint_id, existing.machine))
                self.touch_machine(machine)
                return existing
            for other in self.endpoints.values():
                if other.closed_at or other.presumed_gone:
                    continue
                # The same rule agent_spoke applies on the publish path, and
                # for the same reason: registering is not proof. A record
                # nothing has ever been heard from stands for no worker, so it
                # takes no name from the agent that is about to publish under
                # it - which is exactly what a worker recovering its own
                # endpoint from a restarted hub is doing, against a
                # replacement that was started while the hub knew nothing.
                if not other.heard_from:
                    continue
                if other.machine == machine and other.label == label:
                    raise HubError(HTTPStatus.CONFLICT, "duplicate_label",
                                   "machine %s already has a live endpoint labelled %s"
                                   % (machine, label))
            endpoint = Endpoint(endpoint_id, machine, label, cwd, rows, cols,
                                DEFAULT_RING_BYTES, DEFAULT_SCROLLBACK)
            self.endpoints[endpoint_id] = endpoint
            self.touch_machine(machine)
            return endpoint

    def get(self, endpoint_id: str) -> "Endpoint":
        with self.lock:
            endpoint = self.endpoints.get(endpoint_id)
        if endpoint is None:
            raise HubError(HTTPStatus.NOT_FOUND, "no_such_endpoint",
                           "no endpoint %s" % endpoint_id)
        return endpoint

    def list_endpoints(self) -> list:
        with self.lock:
            return list(self.endpoints.values())

    def list_task_records(self) -> list:
        with self.lock:
            endpoints = sorted(self.endpoints.values(),
                               key=lambda endpoint: (endpoint.machine,
                                                     endpoint.created_at))
            members = {}
            for endpoint in endpoints:
                members.setdefault(leaf_of(endpoint), []).append(endpoint)
            current_ids = set()
            for group in members.values():
                current = self.current_execution(group)
                if current is not None:
                    current_ids.add(current.endpoint_id)
        records = []
        for endpoint in endpoints:
            record = endpoint.describe()
            record["current_execution"] = endpoint.endpoint_id in current_ids
            records.append(record)
        return records

    def reap(self) -> None:
        cutoff = _now() - DEFAULT_ENDPOINT_RETENTION
        with self.lock:
            for endpoint in list(self.endpoints.values()):
                if (not endpoint.closed_at
                        and endpoint.agent_silent_for() > AGENT_SILENCE_PRESUMED_SECS):
                    endpoint.presumed_gone = True
            for endpoint_id in [
                    e.endpoint_id for e in self.endpoints.values()
                    if (e.closed_at and e.closed_at < cutoff)
                    or e.agent_silent_for() > DEFAULT_ENDPOINT_RETENTION]:
                self.endpoints.pop(endpoint_id, None)
            # Commands an agent took and never answered remain eligible for a
            # late acknowledgement well past the initial window, because that
            # is the command whose fate a caller most needs to settle. They
            # eventually become eligible for reaping: an agent that has not
            # answered this command by then is not going to, and the journaled
            # order reads unconfirmed either way.
            stale = _now() - UNACKNOWLEDGED_COMMAND_RETENTION
            for machine in self.machines.values():
                for command_id, command in list(machine.pending.items()):
                    if not command.done.is_set() and command.taken_at < stale:
                        machine.pending.pop(command_id, None)

    # --- commands ---------------------------------------------------------

    def submit_command(self, endpoint: "Endpoint", kind: str, payload: dict,
                       order: "Order" = None) -> "Command":
        """Queue a command for the owning agent and wait for its acknowledgement.

        A command that is never taken, or whose agent reports a failure, is an
        error here.  Silence is never success.

        `order` is bound to the command the instant one exists, before anything
        here can raise, so an order whose command timed out can still be read
        back as what it is rather than as a record with nothing in it.
        """
        if endpoint.closed_at:
            raise HubError(HTTPStatus.CONFLICT, "endpoint_closed",
                           "endpoint %s has closed" % endpoint.endpoint_id)
        command = Command(endpoint.endpoint_id, endpoint.machine, kind, payload)
        if order is not None:
            order.command = command
        with self.command_wake:
            machine = self.machines.get(endpoint.machine)
            if machine is None:
                raise HubError(HTTPStatus.SERVICE_UNAVAILABLE, "machine_unknown",
                               "no agent has ever reported machine %s" % endpoint.machine)
            machine.queue.append(command)
            self.command_wake.notify_all()
        if not command.done.wait(self.options.command_ack_secs):
            with self.command_wake:
                # The acknowledgement may have landed in the instant between
                # the wait elapsing and this lock, and a command that WAS
                # acknowledged must never be reported as one that timed out.
                if not command.done.is_set():
                    if command in machine.queue:
                        # Never taken by any agent, so pulling it back is what
                        # makes "not delivered" a fact rather than a guess.
                        machine.queue.remove(command)
                        command.withdrawn = True
                    # A command an agent already TOOK stays pending on purpose.
                    # It may be running at the worker this instant, so the hub
                    # neither unsends it nor forgets it: leaving the record is
                    # what lets a late acknowledgement still settle what
                    # happened, which is the only way an unconfirmed command
                    # ever becomes a known one.
            if not command.done.is_set():
                silent = self.machine_silent_for(endpoint.machine)
                if command.withdrawn:
                    raise HubError(
                        HTTPStatus.GATEWAY_TIMEOUT, "no_agent_ack",
                        "the agent on machine %s did not acknowledge within %gs "
                        "(last heard from %.1fs ago); the %s was NOT delivered"
                        % (endpoint.machine, self.options.command_ack_secs, silent, kind),
                        {"taken": False})
                raise HubError(
                    HTTPStatus.GATEWAY_TIMEOUT, "no_agent_ack",
                    "the agent on machine %s took the %s but did not acknowledge it "
                    "within %gs (last heard from %.1fs ago); whether it reached the "
                    "worker is NOT known"
                    % (endpoint.machine, kind, self.options.command_ack_secs, silent),
                    {"taken": True})
        if not command.ok:
            raise HubError(HTTPStatus.BAD_GATEWAY, "agent_refused",
                           command.error or "the owning agent refused the %s" % kind,
                           {"taken": True})
        return command

    def take_commands(self, machine_name: str, endpoint_id: str, wait: float) -> list:
        """Long-poll: hand a polling agent the commands for ITS endpoint.

        The filter is not a convenience. One agent owns one endpoint, so several
        agents poll the same machine, and an unfiltered take would let one of
        them swallow a command meant for another endpoint's pty - which would
        then be acknowledged as delivered to the wrong worker.
        """
        deadline = _now() + wait
        with self.command_wake:
            while True:
                machine = self.machines.get(machine_name)
                if machine is not None and machine.queue:
                    taken = [c for c in machine.queue
                             if not endpoint_id or c.endpoint_id == endpoint_id]
                    if taken:
                        for command in taken:
                            machine.queue.remove(command)
                            command.taken_at = _now()
                            machine.pending[command.command_id] = command
                        return taken
                remaining = deadline - _now()
                if remaining <= 0:
                    return []
                self.command_wake.wait(remaining)

    def complete_command(self, machine_name: str, command_id: str,
                         ok: bool, error: str) -> None:
        with self.command_wake:
            machine = self.machines.get(machine_name)
            command = machine.pending.pop(command_id, None) if machine else None
            if command is None:
                completed = machine.completed.get(command_id) if machine else None
                if completed is None:
                    raise HubError(HTTPStatus.NOT_FOUND, "no_such_command",
                                   "machine %s holds no command %s"
                                   % (machine_name, command_id))
                if completed != (ok, error):
                    raise HubError(HTTPStatus.CONFLICT, "result_conflict",
                                   "command %s already has a different result"
                                   % command_id)
                machine.completed.move_to_end(command_id)
                return
            command.ok = ok
            command.error = error
            command.done.set()
            machine.completed[command_id] = (ok, error)
            while len(machine.completed) > COMMAND_RESULT_JOURNAL_MAX:
                machine.completed.popitem(last=False)

    # --- orders -----------------------------------------------------------

    def leaf_members(self, leaf: str) -> list:
        """Every endpoint the hub holds under one leaf_worker_id, oldest first."""
        with self.lock:
            members = [e for e in self.endpoints.values() if leaf_of(e) == leaf]
        members.sort(key=lambda e: e.created_at)
        return members

    @staticmethod
    def current_execution(members: list) -> "Endpoint":
        """Which endpoint a leaf's feed displays and its orders reach.

        The order of preference is the registration rule read from the other
        side.  An endpoint the hub has never HEARD FROM stands for no worker -
        registering is not proof - so it cannot supersede one that does, which
        is precisely the case of a replacement started while a live worker's
        agent was out of touch.  Silence is deliberately not a criterion: a
        presumption is not evidence, so a worker whose agent has merely gone
        quiet keeps its place here and its order is attempted rather than
        refused on a guess.
        """
        heard = [e for e in members if e.heard_from and not e.closed_at]
        if heard:
            return heard[-1]
        open_records = [e for e in members if not e.closed_at]
        if open_records:
            return open_records[-1]
        return members[-1] if members else None

    def record_order(self, order: "Order") -> "Order":
        """Enter an order in the journal, or hand back the one already holding its id.

        Entering under the journal's lock is what reserves a caller-supplied id
        from the instant its placement begins. A resend arriving while that
        call is still working - resolving a rejoining leaf, waiting out an
        acknowledgement - finds this record and is answered from it, so the
        order's text is typed once however many times its id is sent.
        """
        with self.lock:
            winner = self.orders.setdefault(order.order_id, order)
            while len(self.orders) > ORDER_JOURNAL_MAX:
                self.orders.popitem(last=False)
            return winner

    def place_order(self, leaf: str, requested_execution: str, text: str,
                    order_id: str) -> "Order":
        """Deliver one leaf-addressed, execution-scoped order, or refuse it.

        Addressing is by leaf so a caller names the worker rather than whichever
        endpoint it happened to be on, and the execution the caller AIMED at is
        carried with it so that stability can never become the wrong target: an
        order composed against one execution must not land in a replacement that
        never saw what prompted it.  Every exit from here is recorded under the
        caller's own id, so an answer that never reached the caller can still be
        returned on a resend.  A placement still in flight is waited out, so
        the caller gets the first order's fate instead of a second delivery.
        """
        order = Order(order_id, leaf, requested_execution, "", None)
        try:
            existing = self.record_order(order)
            if existing is not order:
                # Already placed, or another call is placing it right now.
                # Typing it a second time is the one outcome that cannot be
                # taken back, so a repeat is answered from the record rather
                # than delivered again - and a placement still in flight is
                # waited out first, so the answer is that order's own fate
                # and not a snapshot of its middle.
                if not existing.answered.is_set():
                    existing.answered.wait(MEMBERSHIP_GRACE_SECS
                                           + self.options.command_ack_secs
                                           + ORDER_ANSWER_SLACK_SECS)
                return existing
            self.reap()
            members = self.leaf_members(leaf)
            # A leaf that resolves to nothing is not absent yet. Rejoining agents
            # take seconds, and only an absence that outlasts that window is a
            # membership verdict rather than a reading.
            if not members:
                deadline = _now() + MEMBERSHIP_GRACE_SECS
                while _now() < deadline:
                    time.sleep(0.25)
                    members = self.leaf_members(leaf)
                    if members:
                        break
            current = self.current_execution(members)
            order.execution_id = (current.endpoint_id
                                  if current is not None else "")
            order.endpoint = current

            if current is None:
                self._refuse_order(order, HTTPStatus.NOT_FOUND, "unknown_leaf",
                                   "this hub held no endpoint for leaf %s for %gs, longer "
                                   "than a rejoin takes, so it is not registered here"
                                   % (leaf, MEMBERSHIP_GRACE_SECS))

            if current.endpoint_id != requested_execution:
                if any(e.endpoint_id == requested_execution for e in members):
                    self._refuse_order(
                        order, HTTPStatus.CONFLICT, "execution_superseded",
                        "leaf %s is now execution %s; the order was aimed at %s and was "
                        "not delivered" % (leaf, current.endpoint_id, requested_execution))
                self._refuse_order(
                    order, HTTPStatus.NOT_FOUND, "execution_not_found",
                    "this hub holds no execution %s for leaf %s (its current execution "
                    "is %s)" % (requested_execution, leaf, current.endpoint_id))

            if current.closed_by == "agent":
                self._refuse_order(
                    order, HTTPStatus.GONE, "worker_gone",
                    "the agent owning execution %s reported its worker ended (exit %s), "
                    "so the order was not delivered"
                    % (current.endpoint_id, current.exit_code))
            if current.closed_at:
                # The hub closed a record it could no longer steer. It cannot carry
                # this order, and it knows nothing about the worker either.
                self._refuse_order(
                    order, HTTPStatus.CONFLICT, "hub_closed_record",
                    "the hub closed its record of execution %s because it could no longer "
                    "steer it; the order was not delivered, and this is not evidence about "
                    "the worker" % current.endpoint_id)

            try:
                self.submit_command(current, "input", {
                    "text": text,
                    "keys": None,
                    "submit": True,
                }, order=order)
            except HubError as exc:
                if order.command is None or not order.command.taken_at:
                    # No agent ever took this, so the refusal itself is the whole
                    # record and it keeps the reason that produced it. Only a
                    # command an agent HAS taken is left to the command record,
                    # whose unconfirmed verdict no refusal may overwrite.
                    order.refusal = (exc.code, exc.message)
                order.status = exc.status
                raise HubError(exc.status, exc.code, exc.message, order.describe())
            return order
        finally:
            order.answered.set()

    def _refuse_order(self, order: "Order", status, code: str, message: str) -> None:
        order.refusal = (code, message)
        order.status = status
        raise HubError(status, code, message, order.describe())


# --- helpers ----------------------------------------------------------------


def leaf_of(endpoint: "Endpoint") -> str:
    """The stable identity an order addresses: one task on one home.

    The same spelling bin/fm-stream-bridge.py emits as leaf_worker_id, so what
    the Bridge shows and what an order names are the same thing.  It outlives
    any one execution, which is why an order carries the execution separately.
    """
    return "%s/%s" % (endpoint.machine, endpoint.label)


def _constant_time_equals(a: str, b: str) -> bool:
    return hmac.compare_digest(a.encode("utf-8", "surrogateescape"),
                               b.encode("utf-8", "surrogateescape"))


def _positive_int(value, default: int, name: str) -> int:
    if value is None:
        return default
    try:
        parsed = int(value)
    except (TypeError, ValueError):
        raise HubError(HTTPStatus.BAD_REQUEST, "bad_%s" % name,
                       "%s must be a positive integer" % name)
    if parsed <= 0:
        raise HubError(HTTPStatus.BAD_REQUEST, "bad_%s" % name,
                       "%s must be a positive integer" % name)
    return parsed


def _query_int(query: dict, name: str, default: int) -> int:
    raw = query.get(name)
    if raw is None:
        return default
    try:
        return int(raw[0] if isinstance(raw, list) else raw)
    except (TypeError, ValueError):
        raise HubError(HTTPStatus.BAD_REQUEST, "bad_%s" % name,
                       "%s must be an integer" % name)


def _query_one(query: dict, name: str, default: str = "") -> str:
    raw = query.get(name)
    if raw is None:
        return default
    return raw[0] if isinstance(raw, list) else raw


# --- HTTP -------------------------------------------------------------------


class HubServer(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True
    hub: "Hub" = None


class Handler(http.server.BaseHTTPRequestHandler):
    server_version = "fm-stream-hub/" + HUB_VERSION
    protocol_version = "HTTP/1.1"

    # --- plumbing ---------------------------------------------------------

    def log_message(self, fmt, *args) -> None:  # noqa: A003 - base class name
        # Request lines can carry an endpoint id and, for a client that used the
        # query form, a token. Neither belongs in a log this process does not
        # need, so nothing is logged at all.
        return

    def do_GET(self) -> None:  # noqa: N802 - base class name
        self._handle("GET")

    def do_POST(self) -> None:  # noqa: N802 - base class name
        self._handle("POST")

    def do_DELETE(self) -> None:  # noqa: N802 - base class name
        self._handle("DELETE")

    def _handle(self, method: str) -> None:
        self._body_consumed = False
        try:
            parsed = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(parsed.query)
            path = parsed.path.rstrip("/") or "/"
            if method == "GET" and path == "/ui":
                # A browser NAVIGATING to the viewer, and nothing else, is
                # served without a credential. The page is static - no endpoint
                # id, no machine name, no terminal content - and it is what
                # reads the token out of the URL fragment a browser never sends
                # to a server. Gating it would deadlock: the token cannot
                # arrive before the page that reads it loads. Every other
                # method and every data route stays authenticated.
                self._text(HTTPStatus.OK, WEB_UI, "text/html; charset=utf-8")
            else:
                self._route(method, path, query)
            self._discard_body()
        except HubError as exc:
            self._discard_body()
            refusal = dict(exc.details)
            refusal.update({"ok": False, "error": exc.code, "message": exc.message})
            self._json(exc.status, refusal)
        except BrokenPipeError:
            return
        except ConnectionResetError:
            return
        except Exception as exc:  # noqa: BLE001 - the hub must not die on one request
            self._discard_body()
            self._json(HTTPStatus.INTERNAL_SERVER_ERROR,
                       {"ok": False, "error": "internal", "message": str(exc)})

    def _discard_body(self) -> None:
        """Read a refused request's body, so the next one on this connection parses.

        A refusal that answers before the body is read leaves those bytes in the
        socket, and on a kept-alive connection the client's NEXT request is then
        parsed starting mid-body. Where the declared length cannot be honoured,
        the connection is closed instead of being left desynchronised.
        """
        if self._body_consumed:
            return
        self._body_consumed = True
        declared = self.headers.get("Content-Length")
        if declared is None:
            return
        try:
            size = int(declared)
        except (TypeError, ValueError):
            self.close_connection = True
            return
        if size < 0 or size > MAX_BODY:
            self.close_connection = True
            return
        try:
            self.rfile.read(size)
        except OSError:
            self.close_connection = True

    # --- auth -------------------------------------------------------------

    def _presented_token(self, query: dict, allow_query: bool) -> str:
        header = self.headers.get("Authorization", "")
        if header.startswith("Bearer "):
            return header[7:].strip()
        # The query form exists for the one client that cannot set a header: a
        # browser opening an EventSource on the stream route. Every other route
        # requires the header, which confines a credential in a request line to
        # that single route. It does not eliminate it: the viewer opens that
        # stream with whatever token it was given, usually an operating one, so
        # the token does reach that request line. The hub logs nothing, but a
        # TLS terminator in front of it logs what it is configured to.
        return _query_one(query, "access_token", "") if allow_query else ""

    def _require(self, needed: str, query: dict, allow_query: bool = False) -> frozenset:
        granted = self.server.hub.classes_for(self._presented_token(query, allow_query))
        if not granted:
            raise HubError(HTTPStatus.UNAUTHORIZED, "unauthenticated",
                           "a bearer token is required")
        if needed not in granted:
            raise HubError(HTTPStatus.FORBIDDEN, "wrong_token_class",
                           "this token does not hold the '%s' class" % needed)
        return granted

    # --- responses --------------------------------------------------------

    def _json(self, status, payload: dict) -> None:
        body = json.dumps(payload, sort_keys=True).encode("utf-8")
        self.send_response(int(status))
        if self.close_connection:
            self.send_header("Connection", "close")
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _text(self, status, text: str, content_type: str) -> None:
        body = text.encode("utf-8")
        self.send_response(int(status))
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def _body(self) -> dict:
        length = self.headers.get("Content-Length")
        if length is None:
            return {}
        try:
            size = int(length)
        except (TypeError, ValueError):
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_length", "malformed Content-Length")
        if size < 0 or size > MAX_BODY:
            raise HubError(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, "body_too_large",
                           "request body exceeds %d bytes" % MAX_BODY)
        raw = self.rfile.read(size) if size else b""
        self._body_consumed = True
        if not raw:
            return {}
        try:
            payload = json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError) as exc:
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_json", "malformed JSON body: %s" % exc)
        if not isinstance(payload, dict):
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_json", "the body must be a JSON object")
        return payload

    def _require_any(self, query: dict) -> frozenset:
        granted = self.server.hub.classes_for(self._presented_token(query, False))
        if not granted:
            raise HubError(HTTPStatus.UNAUTHORIZED, "unauthenticated",
                           "a bearer token is required")
        return granted

    # --- routing ----------------------------------------------------------

    def _route(self, method: str, path: str, query: dict) -> None:
        hub = self.server.hub

        if path == "/v1/health" and method == "GET":
            # Any valid token: an agent must be able to check the protocol
            # before it is trusted to publish, and a subscriber before it reads.
            self._require_any(query)
            hub.reap()
            self._json(HTTPStatus.OK, {
                "ok": True,
                "protocol": HUB_PROTOCOL,
                "version": HUB_VERSION,
                "capabilities": list(HUB_CAPABILITIES),
                "started_at": hub.started_at,
                "endpoints": len(hub.list_endpoints()),
                "state_max_age_secs": hub.options.state_max_age_secs,
                "command_ack_secs": hub.options.command_ack_secs,
            })
            return

        if path.startswith("/v1/agent/"):
            self._require(CLASS_PUBLISH, query)
            self._agent_route(method, path, query)
            return

        if path == "/v1/machines" and method == "GET":
            self._require(CLASS_SUBSCRIBE, query)
            silent_after = hub.options.state_max_age_secs
            self._json(HTTPStatus.OK, {
                "ok": True,
                "machines": [m.describe(silent_after) for m in hub.list_machines()],
            })
            return

        if path == "/v1/tasks" and method == "GET":
            self._require(CLASS_SUBSCRIBE, query)
            hub.reap()
            self._json(HTTPStatus.OK, {
                "ok": True,
                "tasks": hub.list_task_records(),
                "machines": [m.describe(hub.options.state_max_age_secs)
                             for m in hub.list_machines()],
            })
            return

        if path == "/v1/orders" and method == "POST":
            # Steering a worker is the control class, exactly as typing into
            # its endpoint is.
            self._require(CLASS_CONTROL, query)
            self._order_route(query)
            return

        if path.startswith("/v1/tasks/"):
            rest = path[len("/v1/tasks/"):]
            endpoint_id, _, tail = rest.partition("/")
            self._task_route(method, endpoint_id, tail, query)
            return

        raise HubError(HTTPStatus.NOT_FOUND, "no_such_route", "no such route: %s" % path)

    def _order_route(self, query: dict) -> None:
        """One order, addressed by leaf and bound to the execution it was aimed at.

        Both identifiers are required.  The leaf alone would let an order
        composed for one worker land in its replacement, and the execution
        alone would be the endpoint-addressed steer this already has.
        """
        payload = self._body()
        leaf = payload.get("leaf_worker_id")
        if not isinstance(leaf, str):
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_leaf",
                           "an order needs a 'leaf_worker_id'")
        machine, sep, label = leaf.partition("/")
        if not sep or not MACHINE_RE.match(machine) or not LABEL_RE.match(label):
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_leaf",
                           "leaf_worker_id must be '<machine>/<label>'")
        execution = payload.get("execution_id")
        if not isinstance(execution, str) or not ENDPOINT_ID_RE.match(execution):
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_execution",
                           "an execution_id must be 32 lowercase hex characters")
        text = payload.get("text")
        if not isinstance(text, str):
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_input",
                           "an order needs 'text' as a string")
        if payload.get("submit") is not True:
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_submit",
                           "an order must set 'submit' to true")
        allowed = {"leaf_worker_id", "execution_id", "order_id", "text", "submit"}
        unexpected = sorted(set(payload) - allowed)
        if unexpected:
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_order_fields",
                           "unsupported order fields: %s" % ", ".join(unexpected))
        order_id = payload.get("order_id")
        if not isinstance(order_id, str) or not ORDER_ID_RE.match(order_id):
            raise HubError(HTTPStatus.BAD_REQUEST, "bad_order_id",
                           "an order_id must be 1-128 characters of [A-Za-z0-9._-]")
        order = self.server.hub.place_order(leaf, execution, text, order_id)
        # Placing a fresh order raises on every refusal, so reaching here means
        # either a delivery or a caller resending an id the hub already
        # answered - and a resent id is told exactly what the first answer was.
        outcome, code, message, _delivered = order.outcome()
        if outcome != ORDER_ACCEPTED:
            raise HubError(order.status, code or outcome, message, order.describe())
        answer = {"ok": True}
        answer.update(order.describe())
        self._json(HTTPStatus.OK, answer)

    # --- agent routes -----------------------------------------------------

    def _agent_route(self, method: str, path: str, query: dict) -> None:
        hub = self.server.hub
        tail = path[len("/v1/agent/"):]

        if tail == "endpoints" and method == "POST":
            endpoint = hub.register_endpoint(self._body())
            self._json(HTTPStatus.CREATED, {"ok": True, "endpoint": endpoint.describe()})
            return

        if tail == "frames" and method == "POST":
            payload = self._body()
            machine = str(payload.get("machine") or "")
            if not MACHINE_RE.match(machine):
                raise HubError(HTTPStatus.BAD_REQUEST, "bad_machine", "malformed machine name")
            hub.touch_machine(machine)
            accepted = 0
            for frame in payload.get("frames") or []:
                if not isinstance(frame, dict):
                    continue
                endpoint = hub.get(str(frame.get("endpoint_id") or ""))
                if endpoint.machine != machine:
                    raise HubError(HTTPStatus.FORBIDDEN, "endpoint_owned_elsewhere",
                                   "endpoint %s belongs to machine %s"
                                   % (endpoint.endpoint_id, endpoint.machine))
                # A record announcing its own death takes no name from anyone,
                # so a closing frame is never subject to the contest. An agent
                # that has lost its name must still be able to close out the
                # record it already holds, or supersession would leave an open
                # endpoint with nothing behind it.
                closing = bool(frame.get("closed"))
                if not closing:
                    hub.agent_spoke(endpoint)
                if frame.get("b64"):
                    try:
                        endpoint.feed(base64.b64decode(frame["b64"], validate=True))
                    except (ValueError, TypeError) as exc:
                        raise HubError(HTTPStatus.BAD_REQUEST, "bad_frame",
                                       "frame payload is not valid base64: %s" % exc)
                state = frame.get("state")
                if isinstance(state, dict):
                    endpoint.publish_state(state)
                if closing:
                    endpoint.mark_closed(frame.get("exit_code"), "agent")
                accepted += 1
            self._json(HTTPStatus.OK, {"ok": True, "accepted": accepted})
            return

        if tail == "commands" and method == "GET":
            machine = _query_one(query, "machine")
            if not MACHINE_RE.match(machine):
                raise HubError(HTTPStatus.BAD_REQUEST, "bad_machine", "malformed machine name")
            endpoint_id = _query_one(query, "endpoint")
            if endpoint_id and not ENDPOINT_ID_RE.match(endpoint_id):
                raise HubError(HTTPStatus.BAD_REQUEST, "bad_endpoint_id",
                               "malformed endpoint id")
            hub.touch_machine(machine)
            if endpoint_id:
                hub.touch_endpoint(endpoint_id)
            wait = min(max(_query_int(query, "wait", 25), 0), 120)
            commands = hub.take_commands(machine, endpoint_id, float(wait))
            hub.touch_machine(machine)
            if endpoint_id:
                hub.touch_endpoint(endpoint_id)
            self._json(HTTPStatus.OK, {
                "ok": True,
                "commands": [c.describe() for c in commands],
            })
            return

        if tail == "results" and method == "POST":
            payload = self._body()
            machine = str(payload.get("machine") or "")
            command_id = str(payload.get("command_id") or "")
            if not COMMAND_ID_RE.match(command_id):
                raise HubError(HTTPStatus.BAD_REQUEST, "bad_command_id", "malformed command id")
            hub.touch_machine(machine)
            hub.complete_command(machine, command_id,
                                 bool(payload.get("ok")),
                                 str(payload.get("error") or ""))
            self._json(HTTPStatus.OK, {"ok": True})
            return

        raise HubError(HTTPStatus.NOT_FOUND, "no_such_route", "no such agent route: %s" % path)

    # --- subscriber and control routes ------------------------------------

    def _task_route(self, method: str, endpoint_id: str, tail: str, query: dict) -> None:
        hub = self.server.hub

        if not ENDPOINT_ID_RE.match(endpoint_id):
            raise HubError(HTTPStatus.NOT_FOUND, "no_such_endpoint",
                           "no endpoint %s" % endpoint_id)

        if tail == "" and method == "DELETE":
            self._require(CLASS_CONTROL, query)
            endpoint = hub.get(endpoint_id)
            delivered = True
            try:
                hub.submit_command(endpoint, "kill", {"signal": "TERM"})
            except HubError as exc:
                if exc.code != "no_agent_ack":
                    raise
                # An agent that never answers cannot be waited for, so the hub
                # stops carrying a record it can no longer steer. That is not
                # proof the worker died, and the answer says so rather than
                # reporting a kill it did not make.
                delivered = False
                endpoint.mark_closed(None, "hub")
            self._json(HTTPStatus.OK, {
                "ok": True,
                "closed": endpoint.endpoint_id,
                "machine": endpoint.machine,
                "delivered": delivered,
            })
            return

        # Steering an endpoint - typing into it or appending to its record - is
        # the control class; everything else on a task is a read.
        steering = method == "POST" and tail in ("input", "status")
        self._require(CLASS_CONTROL if steering else CLASS_SUBSCRIBE, query,
                      allow_query=(method == "GET" and tail == "stream"))
        endpoint = hub.get(endpoint_id)

        if tail == "" and method == "GET":
            self._json(HTTPStatus.OK, {"ok": True, "task": endpoint.describe()})
            return

        if tail == "input" and method == "POST":
            payload = self._body()
            text = payload.get("text")
            keys = payload.get("keys")
            if text is None and keys is None:
                raise HubError(HTTPStatus.BAD_REQUEST, "bad_input",
                               "an input needs 'text' or 'keys'")
            hub.submit_command(endpoint, "input", {
                "text": text,
                "keys": keys,
                "submit": bool(payload.get("submit")),
            })
            self._json(HTTPStatus.OK, {"ok": True, "delivered": endpoint.endpoint_id})
            return

        if tail == "status" and method == "POST":
            payload = self._body()
            state = str(payload.get("state") or "")
            if state not in STATUS_STATES:
                raise HubError(HTTPStatus.BAD_REQUEST, "bad_state",
                               "unknown status state %r (known: %s)"
                               % (state, ", ".join(STATUS_STATES)))
            # The hub routes this; it never writes it. The owning agent holds
            # the record and its path, which is why no local path is ever sent
            # across the network.
            hub.submit_command(endpoint, "status",
                               {"state": state, "note": payload.get("note") or ""})
            self._json(HTTPStatus.OK, {"ok": True, "appended": endpoint.endpoint_id})
            return

        if tail == "capture" and method == "GET":
            lines = min(max(_query_int(query, "lines", 40), 1), DEFAULT_SCROLLBACK)
            ansi = _query_one(query, "format", "text") == "ansi"
            with endpoint.lock:
                rendered = endpoint.screen.tail_lines(lines, ansi=ansi)
            self._text(HTTPStatus.OK, "\n".join(rendered) + "\n", "text/plain; charset=utf-8")
            return

        if tail == "screen" and method == "GET":
            ansi = _query_one(query, "format", "text") == "ansi"
            with endpoint.lock:
                rendered = endpoint.screen.screen_lines(ansi=ansi)
                cursor_row = endpoint.screen.cy
            self._json(HTTPStatus.OK, {
                "ok": True,
                "cursor_row": cursor_row,
                "screen": "\n".join(rendered),
            })
            return

        if tail == "processes" and method == "GET":
            self._json(HTTPStatus.OK, self._state_answer(endpoint, "foreground"))
            return

        if tail == "cwd" and method == "GET":
            self._json(HTTPStatus.OK, self._state_answer(endpoint, "cwd"))
            return

        if tail == "stream" and method == "GET":
            self._stream(endpoint, query)
            return

        raise HubError(HTTPStatus.NOT_FOUND, "no_such_route",
                       "no such endpoint route: %s" % (tail or "/"))

    def _state_answer(self, endpoint: "Endpoint", field: str) -> dict:
        """A state read, always carrying whether it is fresh enough to act on.

        The hub never converts silence into a verdict. `stale` true means the
        caller must report the endpoint unreadable; it must NEVER be read as
        the endpoint being dead, because an unreachable agent and a dead worker
        look identical from here and only one of them authorizes recovery.

        `closed_by` rides along because staleness governs live READINGS, not
        recorded facts: a close the owning agent reported is an event that
        already happened, and it does not expire the way a reading does.
        """
        hub = self.server.hub
        max_age = hub.options.state_max_age_secs
        age = endpoint.state_age()
        silent = endpoint.agent_silent_for()
        machine_silent = hub.machine_silent_for(endpoint.machine)
        stale = age < 0 or age > max_age or silent > max_age
        with endpoint.lock:
            state = dict(endpoint.state)
        answer = {
            "ok": True,
            "endpoint_id": endpoint.endpoint_id,
            "machine": endpoint.machine,
            "stale": stale,
            "state_age_secs": None if age < 0 else round(age, 3),
            "agent_silent_for_secs": round(silent, 3),
            "machine_silent_for_secs": None if machine_silent < 0 else round(machine_silent, 3),
            "state_max_age_secs": max_age,
            "closed": bool(endpoint.closed_at),
            "closed_by": endpoint.closed_by or None,
            "exit_code": endpoint.exit_code,
        }
        if stale:
            answer["reason"] = (
                "no state frame yet" if age < 0 else
                "the owning agent on machine %s has been silent for %.1fs"
                % (endpoint.machine, silent) if silent > max_age else
                "the last state frame is %.1fs old" % age)
            # Deliberately no verdict field: an unreachable agent and a dead
            # worker are indistinguishable from here, and only one of them
            # authorizes recovery.
            return answer
        answer["alive"] = bool(state.get("alive"))
        if field == "foreground":
            answer["foreground"] = state.get("foreground") or []
        else:
            answer["cwd"] = state.get("cwd") or ""
        return answer

    def _stream(self, endpoint: "Endpoint", query: dict) -> None:
        replay = _query_one(query, "replay", "") in ("1", "true", "yes")
        offset = 0 if replay else endpoint.ring.end
        self.send_response(int(HTTPStatus.OK))
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Connection", "close")
        self.end_headers()
        try:
            while True:
                start, data, closed = endpoint.wait_for(offset, 15.0)
                if data:
                    offset = start + len(data)
                    record = {
                        "offset": offset,
                        "machine": endpoint.machine,
                        "b64": base64.b64encode(data).decode("ascii"),
                    }
                    self.wfile.write(("data: %s\n\n" % json.dumps(record)).encode("utf-8"))
                    self.wfile.flush()
                    continue
                if closed:
                    record = {"offset": offset, "closed": True,
                              "exit_code": endpoint.exit_code}
                    self.wfile.write(("data: %s\n\n" % json.dumps(record)).encode("utf-8"))
                    self.wfile.flush()
                    return
                self.wfile.write(b": keepalive\n\n")
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError):
            return


# --- the one viewer ---------------------------------------------------------

# A pure subscriber: it lists every endpoint the hub knows, across every
# machine, and streams the selected one. It is static - no endpoint id, no
# machine name, and no terminal content is baked into it, so serving it costs
# nothing and leaks nothing. The token travels in the URL fragment, which a
# browser never sends to a server.
WEB_UI = """<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Firstmate stream</title>
<style>
  :root { color-scheme: dark; --bg:#0b0d10; --panel:#14181d; --line:#232a32;
          --fg:#d7dde5; --dim:#8b97a6; --live:#4ade80; --stale:#fbbf24; --gone:#6b7280; }
  * { box-sizing: border-box; }
  body { margin:0; height:100vh; display:flex; background:var(--bg); color:var(--fg);
         font:13px/1.5 ui-monospace, SFMono-Regular, Menlo, Consolas, monospace; }
  aside { width:300px; flex:none; border-right:1px solid var(--line); overflow-y:auto; }
  aside h1 { margin:0; padding:12px 14px; font-size:12px; letter-spacing:.09em;
             text-transform:uppercase; color:var(--dim); border-bottom:1px solid var(--line); }
  .machine { padding:10px 14px 4px; font-size:11px; letter-spacing:.07em;
             text-transform:uppercase; color:var(--dim); }
  .machine .silent { color:var(--stale); text-transform:none; letter-spacing:0; }
  button.ep { display:block; width:100%; text-align:left; padding:7px 14px; border:0;
              background:none; color:var(--fg); font:inherit; cursor:pointer; }
  button.ep:hover { background:var(--panel); }
  button.ep[aria-current="true"] { background:var(--panel); box-shadow:inset 2px 0 0 var(--live); }
  .dot { display:inline-block; width:7px; height:7px; border-radius:50%; margin-right:8px; }
  .dot.live { background:var(--live); } .dot.stale { background:var(--stale); }
  .dot.gone { background:var(--gone); }
  main { flex:1; display:flex; flex-direction:column; min-width:0; }
  header { padding:10px 16px; border-bottom:1px solid var(--line); display:flex;
           gap:12px; align-items:baseline; }
  header .name { font-weight:600; } header .meta { color:var(--dim); font-size:12px; }
  pre#out { flex:1; margin:0; padding:12px 16px; overflow:auto; white-space:pre-wrap;
            word-break:break-word; }
  form { display:flex; gap:8px; padding:10px 16px; border-top:1px solid var(--line); }
  input { flex:1; padding:8px 10px; background:var(--panel); color:var(--fg);
          border:1px solid var(--line); border-radius:4px; font:inherit; }
  input:disabled { opacity:.5; }
  button.send { padding:8px 16px; background:var(--panel); color:var(--fg);
                border:1px solid var(--line); border-radius:4px; font:inherit; cursor:pointer; }
  .notice { padding:12px 16px; color:var(--dim); }
  .error { color:var(--stale); }
</style>
</head>
<body>
<aside><h1>Fleet</h1><div id="list"><p class="notice">Loading...</p></div></aside>
<main>
  <header><span class="name" id="name">No worker selected</span>
          <span class="meta" id="meta"></span></header>
  <pre id="out"></pre>
  <form id="form"><input id="line" placeholder="Select a worker to type into it"
         autocomplete="off" disabled><button class="send" type="submit">Send</button></form>
</main>
<script>
(function () {
  "use strict";
  var token = location.hash.slice(1);
  var selected = null, source = null, decoder = null, selectedClosed = false;
  var listEl = document.getElementById("list"), outEl = document.getElementById("out");
  var nameEl = document.getElementById("name"), metaEl = document.getElementById("meta");
  var lineEl = document.getElementById("line"), formEl = document.getElementById("form");

  function api(path, options) {
    options = options || {};
    options.headers = Object.assign({}, options.headers,
      {"Authorization": "Bearer " + token});
    return fetch(path, options).then(function (r) {
      if (!r.ok) { return r.json().catch(function () { return {}; })
        .then(function (b) { throw new Error(b.message || ("HTTP " + r.status)); }); }
      return r.json();
    });
  }

  function health(ep, machines) {
    if (ep.closed_at) { return "gone"; }
    var m = machines[ep.machine];
    if (!m || !m.reachable) { return "stale"; }
    if (ep.state_age_secs === null) { return "stale"; }
    return "live";
  }

  function refresh() {
    return api("/v1/tasks").then(function (data) {
      var machines = {};
      (data.machines || []).forEach(function (m) { machines[m.machine] = m; });
      var groups = {};
      (data.tasks || []).forEach(function (ep) {
        (groups[ep.machine] = groups[ep.machine] || []).push(ep);
      });
      var names = Object.keys(groups).sort();
      if (!names.length) {
        listEl.innerHTML = '<p class="notice">No workers registered yet.</p>';
        return;
      }
      listEl.textContent = "";
      names.forEach(function (machine) {
        var head = document.createElement("div");
        head.className = "machine";
        head.textContent = machine;
        var m = machines[machine];
        if (m && !m.reachable) {
          var s = document.createElement("span");
          s.className = "silent";
          s.textContent = "  silent " + Math.round(m.silent_for_secs) + "s";
          head.appendChild(s);
        }
        listEl.appendChild(head);
        groups[machine].forEach(function (ep) {
          var b = document.createElement("button");
          b.className = "ep";
          b.type = "button";
          if (selected === ep.endpoint_id) { b.setAttribute("aria-current", "true"); }
          var dot = document.createElement("span");
          dot.className = "dot " + health(ep, machines);
          b.appendChild(dot);
          b.appendChild(document.createTextNode(ep.label));
          b.addEventListener("click", function () { select(ep); });
          listEl.appendChild(b);
        });
      });
    }).catch(function (err) {
      listEl.innerHTML = '<p class="notice error"></p>';
      listEl.firstChild.textContent = err.message;
    });
  }

  function select(ep) {
    var chosen = ep.endpoint_id;
    selected = chosen;
    nameEl.textContent = ep.label;
    metaEl.textContent = ep.machine + (ep.closed_at ? " - closed" : "");
    selectedClosed = !!ep.closed_at;
    lineEl.disabled = selectedClosed;
    lineEl.placeholder = ep.closed_at ? "This worker has closed"
                                      : "Type a line for " + ep.label;
    outEl.textContent = "";
    if (source) { source.close(); source = null; }
    // Every asynchronous write into the pane checks the selection it was
    // issued for. A response that loses the race to a later click is dropped:
    // painting one worker's terminal under another's name is the one mistake
    // this view must never make.
    fetch("/v1/tasks/" + chosen + "/capture?lines=200",
          {headers: {"Authorization": "Bearer " + token}})
      .then(function (r) {
        return r.text().then(function (t) {
          // A refusal is not terminal output. Painting its body into the pane
          // would read as something the worker printed, so only the hub's own
          // message crosses over, exactly as api() reports a failure.
          if (!r.ok) {
            var message = "";
            try { message = (JSON.parse(t) || {}).message || ""; } catch (e) { message = ""; }
            throw new Error(message || ("HTTP " + r.status));
          }
          return t;
        });
      })
      .then(function (t) {
        if (selected !== chosen) { return; }
        outEl.textContent = t;
        outEl.scrollTop = outEl.scrollHeight;
      })
      .catch(function (err) {
        if (selected !== chosen) { return; }
        outEl.textContent = "";
        var notice = document.createElement("span");
        notice.className = "notice error";
        notice.textContent = "This worker's transcript could not be read: " + err.message;
        outEl.appendChild(notice);
      });
    source = new EventSource("/v1/tasks/" + chosen +
      "/stream?access_token=" + encodeURIComponent(token));
    // One decoder for the whole subscription: frames are raw pty chunks, so a
    // character can straddle any frame boundary and only a streaming decode
    // carries the remainder across.
    decoder = new TextDecoder("utf-8");
    source.onmessage = function (event) {
      if (selected !== chosen) { return; }
      var record = JSON.parse(event.data);
      if (record.b64) {
        var binary = atob(record.b64);
        var bytes = new Uint8Array(binary.length);
        for (var i = 0; i < binary.length; i++) { bytes[i] = binary.charCodeAt(i); }
        outEl.textContent += decoder.decode(bytes, {stream: true});
        outEl.scrollTop = outEl.scrollHeight;
      }
      if (record.closed) { selectedClosed = true; lineEl.disabled = true; refresh(); }
    };
    refresh();
  }

  formEl.addEventListener("submit", function (event) {
    event.preventDefault();
    if (!selected || !lineEl.value) { return; }
    var chosen = selected;
    var text = lineEl.value;
    lineEl.value = "";
    lineEl.disabled = true;
    api("/v1/tasks/" + chosen + "/input", {
      method: "POST",
      headers: {"Content-Type": "application/json"},
      body: JSON.stringify({text: text, submit: true})
    }).catch(function (err) {
      if (selected !== chosen) { return; }
      outEl.textContent += "\\n[not delivered: " + err.message + "]\\n";
      outEl.scrollTop = outEl.scrollHeight;
    }).then(function () {
      if (selected !== chosen) { return; }
      // Whether the box is usable is the selected worker's business, not this
      // request's: a send that lands after the worker closed must not reopen
      // it under a placeholder saying it is gone.
      lineEl.disabled = selectedClosed;
      if (!selectedClosed) { lineEl.focus(); }
    });
  });

  if (!token) {
    listEl.innerHTML = '<p class="notice error">No token in the URL fragment.</p>';
  } else {
    refresh();
    setInterval(refresh, 5000);
  }
}());
</script>
</body>
</html>
"""


# --- entry point ------------------------------------------------------------


def load_tokens(path: str) -> dict:
    tokens = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for number, line in enumerate(fh, 1):
                try:
                    token, classes = parse_token_line(line)
                except ValueError as exc:
                    raise SystemExit("fm-stream-hub: %s line %d: %s" % (path, number, exc))
                if not token:
                    continue
                if token in tokens:
                    tokens[token] = tokens[token] | classes
                else:
                    tokens[token] = classes
    except OSError as exc:
        raise SystemExit("fm-stream-hub: cannot read --token-file %s: %s" % (path, exc))
    if not tokens:
        raise SystemExit("fm-stream-hub: %s defines no tokens; the hub refuses to "
                         "serve unauthenticated" % path)
    return tokens


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=True, description="the fleet's stream hub")
    parser.add_argument("--version", action="store_true")
    parser.add_argument("--protocol", action="store_true")
    sub = parser.add_subparsers(dest="command")
    serve = sub.add_parser("serve")
    serve.add_argument("--bind", default="127.0.0.1")
    serve.add_argument("--port", type=int, default=DEFAULT_PORT)
    serve.add_argument("--token-file", default="")
    serve.add_argument("--state-max-age-secs", type=float, default=DEFAULT_STATE_MAX_AGE)
    serve.add_argument("--command-ack-secs", type=float, default=DEFAULT_COMMAND_ACK)
    serve.add_argument("--ready-file", default="")
    serve.add_argument("--pid-file", default="")
    return parser


def main(argv: list) -> int:
    parser = build_parser()
    options = parser.parse_args(argv)
    if options.version:
        print(HUB_VERSION)
        return 0
    if options.protocol:
        print(HUB_PROTOCOL)
        return 0
    if options.command != "serve":
        parser.print_help()
        return 2

    token_file = options.token_file or os.environ.get("FM_STREAM_TOKEN_FILE", "")
    if token_file:
        tokens = load_tokens(token_file)
    else:
        env_token = os.environ.get("FM_STREAM_TOKEN", "")
        if not env_token:
            raise SystemExit("fm-stream-hub: no credential; pass --token-file or set "
                             "FM_STREAM_TOKEN. The hub never serves unauthenticated.")
        # A single environment token holds every class so a one-machine trial
        # works with no token file, while the token file remains the way to
        # issue a viewing credential that can neither register an endpoint nor
        # steer one.
        tokens = {env_token: frozenset(TOKEN_CLASSES)}

    HubServer.hub = Hub(options, tokens)
    try:
        server = HubServer((options.bind, options.port), Handler)
    except OSError as exc:
        if exc.errno == errno.EADDRINUSE:
            raise SystemExit("fm-stream-hub: %s:%d is already in use"
                             % (options.bind, options.port))
        raise SystemExit("fm-stream-hub: cannot listen on %s:%d: %s"
                         % (options.bind, options.port, exc))

    host, port = server.server_address[0], server.server_address[1]
    if options.pid_file:
        with open(options.pid_file, "w", encoding="utf-8") as fh:
            fh.write("%d\n" % os.getpid())
    if options.ready_file:
        with open(options.ready_file, "w", encoding="utf-8") as fh:
            fh.write("%s %d\n" % (host, port))
    sys.stderr.write("fm-stream-hub %s protocol %d listening on %s:%d\n"
                     % (HUB_VERSION, HUB_PROTOCOL, host, port))
    sys.stderr.flush()

    stopping = threading.Event()

    def _stop(signum, frame) -> None:  # noqa: ARG001
        stopping.set()
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, _stop)
    signal.signal(signal.SIGINT, _stop)

    try:
        server.serve_forever(poll_interval=0.2)
    finally:
        server.server_close()
        for path in (options.pid_file, options.ready_file):
            if path:
                try:
                    os.unlink(path)
                except OSError:
                    pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
