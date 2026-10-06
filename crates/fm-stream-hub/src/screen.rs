//! The reference hub's deliberately small VT model (not a full emulator).
use east_asian_width::east_asian_width;
use std::alloc::Layout;
use std::collections::VecDeque;
use unicode_general_category::{get_general_category, GeneralCategory};
use unicode_normalization::char::canonical_combining_class;

type Cell = (String, String);
type Row = Vec<Cell>;
fn blank(cols: usize) -> Row {
    vec![(" ".into(), String::new()); cols]
}
#[derive(Clone, Default)]
struct Attrs {
    flags: [bool; 8],
    fg: String,
    bg: String,
}
impl Attrs {
    fn render(&self) -> String {
        let mut parts: Vec<String> = self
            .flags
            .iter()
            .zip([1, 2, 3, 4, 5, 7, 8, 9])
            .filter(|(b, _)| **b)
            .map(|(_, n)| n.to_string())
            .collect();
        if !self.fg.is_empty() {
            parts.push(self.fg.clone());
        }
        if !self.bg.is_empty() {
            parts.push(self.bg.clone());
        }
        parts.join(";")
    }
    fn sgr(&mut self, raw: &[&str]) {
        let defaults = ["0"];
        let raw = if raw.is_empty() { &defaults[..] } else { raw };
        let mut i = 0;
        while i < raw.len() {
            let token = if raw[i].is_empty() { "0" } else { raw[i] };
            let code = token
                .split(':')
                .next()
                .unwrap_or("0")
                .parse::<i32>()
                .unwrap_or(-1);
            match code {
                0 => *self = Self::default(),
                1..=5 => self.flags[(code - 1) as usize] = true,
                7..=9 => self.flags[(code - 2) as usize] = true,
                21 | 22 => {
                    self.flags[0] = false;
                    self.flags[1] = false;
                }
                23..=25 => self.flags[(code - 21) as usize] = false,
                27..=29 => self.flags[(code - 22) as usize] = false,
                30..=37 | 90..=97 => self.fg = code.to_string(),
                39 => self.fg.clear(),
                40..=47 | 100..=107 => self.bg = code.to_string(),
                49 => self.bg.clear(),
                38 | 48 => {
                    let (spec, consumed) = if token.contains(':') {
                        (token.to_string(), 0)
                    } else if raw.get(i + 1) == Some(&"5") && i + 2 < raw.len() {
                        (raw[i..i + 3].join(";"), 2)
                    } else if raw.get(i + 1) == Some(&"2") && i + 4 < raw.len() {
                        (raw[i..i + 5].join(";"), 4)
                    } else {
                        (String::new(), 1)
                    };
                    if code == 38 {
                        self.fg = spec;
                    } else {
                        self.bg = spec;
                    }
                    i += consumed;
                }
                _ => (),
            }
            i += 1;
        }
    }
}
pub struct Screen {
    rows: usize,
    cols: usize,
    cells: Vec<Row>,
    history: VecDeque<Row>,
    pub cy: usize,
    cx: usize,
    top: usize,
    bot: usize,
    attrs: Attrs,
    saved: (usize, usize, Attrs),
    state: &'static str,
    buf: String,
    buf_len: usize,
    utf8: Vec<u8>,
    pending_bytes: usize,
}
impl Screen {
    #[cfg(test)]
    pub fn new(rows: usize, cols: usize) -> Self {
        Self::try_new(rows, cols).expect("screen allocation")
    }
    pub fn try_new(rows: usize, cols: usize) -> Result<Self, ()> {
        if rows == 0 || cols == 0 {
            return Err(());
        }
        let count = rows.checked_mul(cols).ok_or(())?;
        Layout::array::<Cell>(count).map_err(|_| ())?;
        Layout::array::<Row>(rows).map_err(|_| ())?;
        let mut cells = Vec::new();
        cells.try_reserve_exact(rows).map_err(|_| ())?;
        for _ in 0..rows {
            let mut row = Vec::new();
            row.try_reserve_exact(cols).map_err(|_| ())?;
            for _ in 0..cols {
                let mut glyph = String::new();
                glyph.try_reserve_exact(1).map_err(|_| ())?;
                glyph.push(' ');
                row.push((glyph, String::new()));
            }
            cells.push(row);
        }
        Ok(Self {
            rows,
            cols,
            cells,
            history: VecDeque::new(),
            cy: 0,
            cx: 0,
            top: 0,
            bot: rows - 1,
            attrs: Attrs::default(),
            saved: (0, 0, Attrs::default()),
            state: "text",
            buf: String::new(),
            buf_len: 0,
            utf8: Vec::new(),
            pending_bytes: 0,
        })
    }
    pub fn feed(&mut self, data: &[u8]) {
        self.utf8.extend_from_slice(data);
        let mut offset = 0;
        loop {
            match std::str::from_utf8(&self.utf8[offset..]) {
                Ok(s) => {
                    let s = s.to_owned();
                    offset = self.utf8.len();
                    for c in s.chars() {
                        self.consume(c, c.len_utf8());
                    }
                    break;
                }
                Err(e) => {
                    let end = offset + e.valid_up_to();
                    let s = String::from_utf8_lossy(&self.utf8[offset..end]).into_owned();
                    let bad = e.error_len();
                    offset = end;
                    for c in s.chars() {
                        self.consume(c, c.len_utf8());
                    }
                    if let Some(len) = bad {
                        offset += len;
                        self.consume('\u{fffd}', len);
                    } else {
                        break;
                    }
                }
            }
        }
        self.utf8.drain(..offset);
    }
    pub fn pending_len(&self) -> usize {
        self.pending_bytes + self.utf8.len()
    }
    fn consume(&mut self, c: char, bytes: usize) {
        self.pending_bytes += bytes;
        self.character(c);
        if self.state == "text" {
            self.pending_bytes = 0;
        }
    }
    fn clear_buf(&mut self) {
        self.buf.clear();
        self.buf_len = 0;
    }
    fn character(&mut self, c: char) {
        match self.state {
            "text" => match c {
                '\x1b' => {
                    self.state = "esc";
                    self.clear_buf();
                }
                '\r' => self.cx = 0,
                '\n' | '\x0b' | '\x0c' => self.linefeed(),
                '\x08' => self.cx = self.cx.saturating_sub(1),
                '\t' => self.cx = (self.cx / 8 * 8 + 8).min(self.cols - 1),
                c if c >= ' ' => self.put(c),
                _ => (),
            },
            "esc" => {
                self.state = "text";
                match c {
                    '[' => {
                        self.state = "csi";
                        self.clear_buf();
                    }
                    ']' => {
                        self.state = "osc";
                        self.clear_buf();
                    }
                    'P' | 'X' | '^' | '_' => {
                        self.state = "dcs";
                        self.clear_buf();
                    }
                    '(' | ')' | '*' | '+' | '%' => self.state = "charset",
                    '7' => self.saved = (self.cy, self.cx, self.attrs.clone()),
                    '8' => self.restore(),
                    'M' => {
                        if self.cy == self.top {
                            self.scroll(false, 1);
                        } else {
                            self.cy = self.cy.saturating_sub(1);
                        }
                    }
                    'D' | 'E' => {
                        if c == 'E' {
                            self.cx = 0;
                        }
                        self.linefeed();
                    }
                    'c' => {
                        self.cells = vec![blank(self.cols); self.rows];
                        self.cy = 0;
                        self.cx = 0;
                        self.attrs = Attrs::default();
                        self.top = 0;
                        self.bot = self.rows - 1;
                    }
                    _ => (),
                }
            }
            "csi" => {
                if ('\x40'..='\x7e').contains(&c) {
                    let b = std::mem::take(&mut self.buf);
                    self.buf_len = 0;
                    self.csi(&b, c);
                    self.state = "text";
                } else {
                    self.buf.push(c);
                    self.buf_len += 1;
                    if self.buf_len > 64 {
                        self.state = "text";
                    }
                }
            }
            "charset" => self.state = "text",
            "osc" | "dcs" => {
                if c == '\x07' {
                    self.state = "text";
                } else if c == '\x1b' {
                    self.state = if self.state == "osc" {
                        "osc-esc"
                    } else {
                        "dcs-esc"
                    };
                } else if self.buf_len > 4096 {
                    self.state = "text";
                } else {
                    self.buf.push(c);
                    self.buf_len += 1;
                }
            }
            _ => {
                self.state = "text";
                if c != '\\' {
                    self.character(c);
                }
            }
        }
    }
    fn restore(&mut self) {
        self.cy = self.saved.0.min(self.rows - 1);
        self.cx = self.saved.1.min(self.cols);
        self.attrs = self.saved.2.clone();
    }
    fn put(&mut self, c: char) {
        let width = if canonical_combining_class(c) != 0
            || matches!(
                get_general_category(c),
                GeneralCategory::NonspacingMark
                    | GeneralCategory::EnclosingMark
                    | GeneralCategory::Format
            ) {
            0
        } else {
            east_asian_width(c as u32).as_usize()
        };
        if width == 0 {
            if self.cx > 0 && self.cx <= self.cols {
                self.cells[self.cy][self.cx - 1].0.push(c);
            }
            return;
        }
        if self.cx + width > self.cols {
            self.cx = 0;
            self.linefeed();
        }
        self.cells[self.cy][self.cx] = (c.to_string(), self.attrs.render());
        for i in 1..width {
            if self.cx + i < self.cols {
                self.cells[self.cy][self.cx + i] = (String::new(), String::new());
            }
        }
        self.cx = (self.cx + width).min(self.cols);
    }
    fn linefeed(&mut self) {
        if self.cy == self.bot {
            self.scroll(true, 1);
        } else if self.cy < self.rows - 1 {
            self.cy += 1;
        }
    }
    fn scroll(&mut self, up: bool, count: usize) {
        // Equivalent once the entire region and bounded history are blank.
        for _ in 0..count.min(self.rows + 2000) {
            if up {
                let row = self.cells.remove(self.top);
                if self.top == 0 {
                    self.history.push_back(row);
                    if self.history.len() > 2000 {
                        self.history.pop_front();
                    }
                }
                self.cells.insert(self.bot, blank(self.cols));
            } else {
                self.cells.remove(self.bot);
                self.cells.insert(self.top, blank(self.cols));
            }
        }
    }
    fn erase_line(&mut self, mode: i64) {
        let range = match mode {
            0 => self.cx.min(self.cols)..self.cols,
            1 => 0..(self.cx + 1).min(self.cols),
            _ => 0..self.cols,
        };
        for x in range {
            self.cells[self.cy][x] = (" ".into(), String::new());
        }
    }
    fn csi(&mut self, b: &str, c: char) {
        if b.starts_with(['?', '>', '<', '=']) {
            return;
        }
        let raw: Vec<&str> = if b.is_empty() {
            vec![]
        } else {
            b.split(';').collect()
        };
        let num = |i: usize, d: i64| {
            raw.get(i)
                .and_then(|s| s.split(':').next())
                .and_then(|s| {
                    let s = s.trim();
                    match s.parse::<i64>() {
                        Ok(n) => Some(n),
                        Err(_) => {
                            let digits = s.strip_prefix(['+', '-']).unwrap_or(s);
                            if !digits.is_empty() && digits.bytes().all(|c| c.is_ascii_digit()) {
                                Some(if s.starts_with('-') {
                                    i64::MIN
                                } else {
                                    i64::MAX
                                })
                            } else {
                                None
                            }
                        }
                    }
                })
                .unwrap_or(d)
        };
        let n = num(0, 1).max(1) as usize;
        match c {
            'm' => self.attrs.sgr(&raw),
            'A' | 'e' => self.cy = self.cy.saturating_sub(n).max(self.top),
            'B' => self.cy = self.cy.saturating_add(n).min(self.bot),
            'C' | 'a' => self.cx = self.cx.saturating_add(n).min(self.cols - 1),
            'D' => self.cx = self.cx.saturating_sub(n),
            'E' => {
                self.cy = self.cy.saturating_add(n).min(self.bot);
                self.cx = 0;
            }
            'F' => {
                self.cy = self.cy.saturating_sub(n).max(self.top);
                self.cx = 0;
            }
            'G' | '`' => self.cx = (num(0, 1).saturating_sub(1).max(0) as usize).min(self.cols - 1),
            'd' => self.cy = (num(0, 1).saturating_sub(1).max(0) as usize).min(self.rows - 1),
            'H' | 'f' => {
                self.cy = (num(0, 1).saturating_sub(1).max(0) as usize).min(self.rows - 1);
                self.cx = (num(1, 1).saturating_sub(1).max(0) as usize).min(self.cols - 1);
            }
            'J' => {
                let mode = num(0, 0);
                match mode {
                    2 | 3 => self.cells = vec![blank(self.cols); self.rows],
                    0 => {
                        self.erase_line(0);
                        for y in self.cy + 1..self.rows {
                            self.cells[y] = blank(self.cols);
                        }
                    }
                    1 => {
                        self.erase_line(1);
                        for y in 0..self.cy {
                            self.cells[y] = blank(self.cols);
                        }
                    }
                    _ => (),
                }
            }
            'K' => self.erase_line(num(0, 0)),
            'L' | 'M' => {
                if self.top <= self.cy && self.cy <= self.bot {
                    for _ in 0..n.min(self.rows) {
                        if c == 'L' {
                            self.cells.remove(self.bot);
                            self.cells.insert(self.cy, blank(self.cols));
                        } else {
                            self.cells.remove(self.cy);
                            self.cells.insert(self.bot, blank(self.cols));
                        }
                    }
                }
            }
            'P' | '@' => {
                if self.cx < self.cols {
                    for _ in 0..n.min(self.cols) {
                        if c == 'P' {
                            self.cells[self.cy].remove(self.cx);
                            self.cells[self.cy].push((" ".into(), String::new()));
                        } else {
                            self.cells[self.cy].insert(self.cx, (" ".into(), String::new()));
                            self.cells[self.cy].pop();
                        }
                    }
                }
            }
            'X' => {
                for x in self.cx..self.cx.saturating_add(n).min(self.cols) {
                    self.cells[self.cy][x] = (" ".into(), String::new());
                }
            }
            'S' | 'T' => self.scroll(c == 'S', n),
            'r' => {
                let top = num(0, 1).saturating_sub(1).max(0) as usize;
                let bot = num(1, self.rows as i64)
                    .saturating_sub(1)
                    .min(self.rows as i64 - 1);
                if bot >= 0 && top < bot as usize {
                    self.top = top;
                    self.bot = bot as usize;
                    self.cy = top;
                    self.cx = 0;
                }
            }
            's' => self.saved = (self.cy, self.cx, self.attrs.clone()),
            'u' => self.restore(),
            _ => (),
        }
        self.cx = self.cx.min(self.cols);
    }
    fn render(row: &Row, ansi: bool) -> String {
        let plain: String = row.iter().map(|c| c.0.as_str()).collect();
        let plain = plain.trim_end();
        if !ansi || plain.is_empty() {
            return plain.to_owned();
        }
        let mut out = String::new();
        let mut current = "";
        let mut used = 0;
        let plain_len = plain.chars().count();
        for (glyph, sgr) in row {
            if used >= plain_len {
                break;
            }
            if sgr != current {
                out.push_str(if sgr.is_empty() { "\x1b[0m" } else { "\x1b[" });
                if !sgr.is_empty() {
                    out.push_str(sgr);
                    out.push('m');
                }
                current = sgr;
            }
            out.push_str(glyph);
            used += glyph.chars().count();
        }
        if !current.is_empty() {
            out.push_str("\x1b[0m");
        }
        out
    }
    pub fn cursor_col(&self) -> usize {
        self.cx.min(self.cols - 1)
    }
    /// Follow the endpoint's pseudoterminal to a new geometry. Rows leaving
    /// the top go to history, the way a terminal keeps the bottom of the
    /// screen; the scroll region resets to the full screen.
    pub fn resize(&mut self, rows: usize, cols: usize) {
        if rows == 0 || cols == 0 || (rows == self.rows && cols == self.cols) {
            return;
        }
        for row in self.cells.iter_mut() {
            row.resize(cols, (" ".into(), String::new()));
        }
        for row in self.history.iter_mut() {
            row.resize(cols, (" ".into(), String::new()));
        }
        if rows < self.cells.len() {
            let excess = self.cells.len() - rows;
            // Drop blank rows below the cursor first, then scroll the rest off.
            let mut trimmed = 0;
            while trimmed < excess
                && self.cells.len() - 1 > self.cy
                && self
                    .cells
                    .last()
                    .is_some_and(|r| r.iter().all(|(g, a)| g == " " && a.is_empty()))
            {
                self.cells.pop();
                trimmed += 1;
            }
            for _ in trimmed..excess {
                let row = self.cells.remove(0);
                self.history.push_back(row);
                if self.history.len() > 2000 {
                    self.history.pop_front();
                }
                self.cy = self.cy.saturating_sub(1);
            }
        }
        while self.cells.len() < rows {
            self.cells.push(blank(cols));
        }
        self.rows = rows;
        self.cols = cols;
        self.cy = self.cy.min(rows - 1);
        self.cx = self.cx.min(cols);
        self.top = 0;
        self.bot = rows - 1;
    }
    pub fn lines(&self, ansi: bool) -> Vec<String> {
        self.cells.iter().map(|r| Self::render(r, ansi)).collect()
    }
    pub fn tail(&self, n: usize, ansi: bool) -> Vec<String> {
        let mut rows: Vec<&Row> = self.history.iter().chain(self.cells.iter()).collect();
        while rows
            .last()
            .is_some_and(|r| Self::render(r, false).is_empty())
        {
            rows.pop();
        }
        rows[rows.len().saturating_sub(n)..]
            .iter()
            .map(|r| Self::render(r, ansi))
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn identical_resize_preserves_the_scroll_region() {
        let mut screen = Screen::new(4, 8);
        screen.feed(b"top\r\nfirst\r\nsecond\r\nbottom\x1b[2;3r\x1b[3;1H");
        screen.resize(4, 8);
        screen.feed(b"\nnew");
        assert_eq!(screen.lines(false), vec!["top", "second", "new", "bottom"]);
    }

    #[test]
    fn pending_length_counts_original_bytes_until_parsing_completes() {
        let mut screen = Screen::new(2, 80);
        for (prefix, suffix) in [
            (&b"\x1b[3"[..], &b"1mred"[..]),
            (&b"\xe4\xb8"[..], &b"\xad"[..]),
            (&b"\x1b]title\xc3"[..], &b"\xa9\x07"[..]),
            (&b"\x1b( "[..2], &b"B"[..]),
            (&b"\x1bP\xff\x1b"[..], &b"\\"[..]),
        ] {
            screen.feed(prefix);
            assert_eq!(screen.pending_len(), prefix.len());
            screen.feed(suffix);
            assert_eq!(screen.pending_len(), 0);
        }
    }

    #[test]
    fn allocation_layout_failures_are_fallible() {
        assert!(Screen::try_new(1, usize::MAX / 2).is_err());
        assert!(Screen::try_new(usize::MAX / 2, 1).is_err());
        assert!(Screen::try_new(usize::MAX / 2, usize::MAX / 2).is_err());
        assert!(Screen::try_new(0, 1).is_err());
    }

    #[test]
    fn widths_follow_east_asian_categories_without_terminal_exceptions() {
        for c in [
            '\u{17d8}', '\u{2e3a}', '\u{2e3b}', '\u{a1}', '\u{1160}', '\u{ff61}',
        ] {
            let mut screen = Screen::new(3, 4);
            screen.feed(format!("ab{c}cd").as_bytes());
            assert_eq!(
                screen.lines(false),
                vec![format!("ab{c}c"), "d".into(), String::new()]
            );
            assert_eq!(screen.cy, 1);
        }
        for c in ['中', '\u{ff21}', '\u{115f}'] {
            let mut screen = Screen::new(3, 4);
            screen.feed(format!("ab{c}cd").as_bytes());
            assert_eq!(
                screen.lines(false),
                vec![format!("ab{c}"), "cd".into(), String::new()]
            );
            assert_eq!(screen.cy, 1);
        }
    }

    #[test]
    fn control_strings_preserve_character_limits_and_reset_for_csi() {
        for kind in [']', 'P', 'X', '^', '_'] {
            for terminator in ["\x07", "\x1b\\"] {
                for length in [0, 1, 64, 65, 4000, 4096, 4097, 4098, 4099] {
                    let mut screen = Screen::new(2, 20);
                    let input = format!(
                        "start\x1b{kind}{}{terminator} \x1b[31mok\x1b[0m",
                        "é".repeat(length)
                    );
                    for chunk in input.as_bytes().chunks(31) {
                        screen.feed(chunk);
                    }
                    let visible = if length > 4098 { "starté" } else { "start" };
                    assert_eq!(
                        screen.lines(false),
                        vec![format!("{visible} ok"), String::new()]
                    );
                    assert_eq!(
                        screen.lines(true),
                        vec![format!("{visible} \x1b[31mok\x1b[0m"), String::new()]
                    );
                }
            }
        }
    }

    #[test]
    fn repeated_large_control_strings_never_leak_payloads() {
        let mut screen = Screen::new(2, 120);
        let payload = "x".repeat(4000);
        for _ in 0..100 {
            screen.feed(format!("\x1b]52;{payload}\x07\x1bP{payload}\x1b\\+").as_bytes());
        }
        assert_eq!(screen.lines(false), vec!["+".repeat(100), String::new()]);
        assert_eq!(screen.cy, 0);
    }

    #[test]
    fn zero_width_marks_and_format_characters_do_not_wrap() {
        for c in [
            '\u{2063}', '\u{fe0f}', '\u{fe0e}', '\u{20dd}', '\u{ad}', '\u{301}',
        ] {
            let mut screen = Screen::new(2, 4);
            let text = format!("ab{c}cd");
            for byte in text.as_bytes() {
                screen.feed(&[*byte]);
            }
            assert_eq!(screen.cy, 0, "{c:?}");
            assert_eq!(screen.lines(false), vec![text.clone(), String::new()]);
            assert_eq!(screen.tail(2, false), vec![text]);
            screen.feed(c.to_string().as_bytes());
            assert_eq!(screen.cy, 0);
            screen.feed(b"e");
            assert_eq!(screen.cy, 1);
            assert_eq!(screen.lines(false), vec![format!("ab{c}cd{c}"), "e".into()]);
        }
    }

    #[test]
    fn binary_chunks_preserve_replacements_and_incomplete_suffixes() {
        let mut screen = Screen::new(2, 256);
        screen.feed(&vec![0xff; 65_536]);
        let row = "\u{fffd}".repeat(256);
        assert_eq!(screen.lines(false), vec![row.clone(), row.clone()]);
        screen.feed(b"\xe4\xb8");
        assert_eq!(screen.lines(false), vec![row.clone(), row.clone()]);
        screen.feed(b"\xad\xffx");
        assert_eq!(screen.lines(false), vec![row, "中\u{fffd}x".into()]);
        assert_eq!(screen.cy, 1);
    }

    #[test]
    fn malformed_utf8_decodes_consistently_across_frame_boundaries() {
        for data in [
            &b"A\xf0\x90\x80B\xc0\xafC\xe4\xb8\xadD"[..],
            &b"A\xffB\xed\xa0\x80C\xe2\x82D\xf4\x90\x80\x80E"[..],
        ] {
            let expected = String::from_utf8_lossy(data).into_owned();
            for split in 0..=data.len() {
                let mut screen = Screen::new(2, 80);
                screen.feed(&data[..split]);
                screen.feed(&data[split..]);
                assert_eq!(screen.lines(false), vec![expected.clone(), String::new()]);
                assert_eq!(screen.cy, 0);
            }
        }
    }

    #[test]
    fn one_column_wide_glyph_accepts_backspace_and_combining_marks() {
        let mut screen = Screen::new(3, 1);
        screen.feed("中\u{301}".as_bytes());
        assert_eq!(screen.lines(false), vec!["", "中\u{301}", ""]);
        assert_eq!(screen.cy, 1);
        screen.feed(b"\x08x");
        assert_eq!(screen.lines(false), vec!["", "x", ""]);
        assert_eq!(screen.cy, 1);
    }

    #[test]
    fn ansi_rendering_preserves_styles_unicode_and_trimmed_spaces() {
        let mut screen = Screen::new(3, 12);
        screen.feed("\x1b[31mab\u{301}\x1b[0m中\x1b[2mc  \x1b[0m\r\n\x1b[44m   ".as_bytes());
        let ansi = "\x1b[31mab\u{301}\x1b[0m中\x1b[2mc\x1b[0m";
        assert_eq!(screen.lines(false), vec!["ab\u{301}中c", "", ""]);
        assert_eq!(screen.lines(true), vec![ansi, "", ""]);
        assert_eq!(screen.tail(3, true), vec![ansi]);
    }

    #[test]
    fn ansi_capture_preserves_full_width_retained_rows() {
        let mut screen = Screen::new(2, 200);
        let plain = "x\u{301}".repeat(200);
        let ansi = format!("\x1b[1;31m{plain}\x1b[0m");
        for _ in 0..2001 {
            screen.feed(format!("{ansi}\r\n").as_bytes());
        }
        assert_eq!(screen.tail(2000, true), vec![ansi; 2000]);
        assert_eq!(screen.tail(2000, false), vec![plain; 2000]);
    }

    #[test]
    fn spacing_marks_still_occupy_a_column() {
        let mut screen = Screen::new(2, 4);
        screen.feed("ab\u{903}cd".as_bytes());
        assert_eq!(screen.cy, 1);
        assert_eq!(screen.lines(false), vec!["ab\u{903}c", "d"]);
    }
}
