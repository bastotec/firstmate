//! A scanner that renders CPython's exact `json.JSONDecodeError` messages.
//!
//! `serde_json` and CPython disagree on both messages and the set of accepted
//! documents (Python takes `NaN`/`Infinity` literals and lone surrogate
//! escapes), and the adapters surface those messages verbatim (`line %d is
//! not JSON: %s`, `cannot read the feed %s: %s`).  So when `serde_json`
//! rejects a line, this scanner either produces Python's own refusal, byte
//! for byte, or - when it finds the line Python-valid - says `None`, and the
//! caller knows the failure is one of Python's non-standard extensions.
//!
//! Positions are character-based, like Python's, and `lineno`/`colno` follow
//! CPython's arithmetic even though the call sites always hand over a single
//! line.

/// Python's error message for a rejected document, or `None` when Python's
/// parser would have accepted it.
pub fn python_json_error(text: &str) -> Option<String> {
    let chars: Vec<char> = text.chars().collect();
    match scan_value(&chars, skip_ws(&chars, 0)) {
        Ok(mut pos) => {
            pos = skip_ws(&chars, pos);
            if pos < chars.len() {
                Some(render(&chars, "Extra data", pos))
            } else {
                None
            }
        }
        Err((message, pos)) => Some(render(&chars, message, pos)),
    }
}

/// `NaN`/`Infinity`/-`Infinity` tokens and numbers whose value overflows a
/// finite f64 become `null`, and unpaired surrogate escapes inside strings
/// become `\uFFFD`, so a Python-valid document that `serde_json` rejected
/// can be re-parsed.  Downstream, `null` reaches the same refusals Python's
/// non-finite values reach (`must be a finite, non-negative number`, the
/// not-an-int exit-code reading), which is what makes the rewrite safe.
pub fn python_reparse(text: &str) -> Result<serde_json::Value, ()> {
    let chars: Vec<char> = text.chars().collect();
    let mut out = String::with_capacity(text.len());
    let mut index = 0;
    while index < chars.len() {
        let ch = chars[index];
        if ch == '"' {
            // Copy the string, rewriting unpaired surrogate escapes.
            out.push('"');
            index += 1;
            while index < chars.len() {
                let c = chars[index];
                if c == '"' {
                    out.push('"');
                    index += 1;
                    break;
                }
                if c == '\\' && index + 1 < chars.len() && chars[index + 1] == 'u' {
                    let unit = unit_at(&chars, index + 2);
                    if let Some(unit) = unit {
                        if (0xd800..=0xdbff).contains(&unit) {
                            // A high surrogate pairs only with an escaped
                            // low surrogate immediately after it; a pair is
                            // copied whole, anything else is replaced.
                            let paired = chars.get(index + 6).copied() == Some('\\')
                                && chars.get(index + 7).copied() == Some('u')
                                && unit_at(&chars, index + 8)
                                    .is_some_and(|low| (0xdc00..=0xdfff).contains(&low));
                            if paired {
                                out.push_str(&chars[index..index + 12].iter().collect::<String>());
                                index += 12;
                                continue;
                            }
                            out.push_str("\\uFFFD");
                            index += 6;
                            continue;
                        }
                        if (0xdc00..=0xdfff).contains(&unit) {
                            out.push_str("\\uFFFD");
                            index += 6;
                            continue;
                        }
                    }
                }
                out.push(c);
                index += 1;
            }
            continue;
        }
        if ch == '-' || ch.is_ascii_digit() || ch == 'N' || ch == 'I' {
            // A bare number or non-standard literal outside strings: replace
            // the ones serde cannot hold with null, copy the rest through.
            let start = index;
            if ch == '-' {
                index += 1;
            }
            if matches!(chars.get(index), Some('N') | Some('I')) {
                while index < chars.len() && chars[index].is_ascii_alphabetic() {
                    index += 1;
                }
                out.push_str("null");
                continue;
            }
            while index < chars.len()
                && (chars[index].is_ascii_digit()
                    || matches!(chars[index], '.' | 'e' | 'E' | '+' | '-'))
            {
                index += 1;
            }
            let token: String = chars[start..index].iter().collect();
            match token.parse::<f64>() {
                Ok(value) if value.is_finite() => out.push_str(&token),
                // Overflow beyond f64: Python holds inf, every consumer of
                // it refuses it as non-finite, null reaches the same words.
                _ => out.push_str("null"),
            }
            continue;
        }
        out.push(ch);
        index += 1;
    }
    serde_json::from_str(&out).map_err(|_| ())
}

/// `NaN` and the infinities, written as Python accepts them, are the two
/// non-standard literals; a leading `-` may prefix `Infinity`.
fn unit_at(chars: &[char], start: usize) -> Option<u16> {
    let mut unit: u16 = 0;
    for offset in 0..4 {
        let digit = chars.get(start + offset).copied()?.to_digit(16)? as u16;
        unit = unit * 16 + digit;
    }
    Some(unit)
}

fn render(chars: &[char], message: &str, pos: usize) -> String {
    let mut newline_before = None;
    for (index, ch) in chars.iter().enumerate().take(pos) {
        if *ch == '\n' {
            newline_before = Some(index);
        }
    }
    let lineno = 1 + chars.iter().take(pos).filter(|c| **c == '\n').count();
    // CPython's colno is pos minus the last newline index, with rfind's -1
    // when there is none - hence pos + 1 at the line head.
    let last_newline = newline_before.map(|p| p as i64).unwrap_or(-1);
    let colno = pos as i64 - last_newline;
    format!("{message}: line {lineno} column {colno} (char {pos})")
}

fn skip_ws(chars: &[char], mut pos: usize) -> usize {
    while matches!(
        chars.get(pos),
        Some(' ') | Some('\t') | Some('\n') | Some('\r')
    ) {
        pos += 1;
    }
    pos
}

/// A parse failure: Python's message and the character it points at.
type ScanError = (&'static str, usize);

fn scan_value(chars: &[char], pos: usize) -> Result<usize, ScanError> {
    let Some(&ch) = chars.get(pos) else {
        return Err(("Expecting value", pos));
    };
    match ch {
        '"' => scan_string(chars, pos),
        '{' => scan_object(chars, pos),
        '[' => scan_array(chars, pos),
        't' => scan_literal(chars, pos, "true"),
        'f' => scan_literal(chars, pos, "false"),
        'n' => scan_literal(chars, pos, "null"),
        'N' => scan_literal(chars, pos, "NaN"),
        'I' => scan_literal(chars, pos, "Infinity"),
        '-' => {
            // Python special-cases -Infinity before its number grammar.
            if chars.get(pos + 1) == Some(&'I') {
                scan_literal(chars, pos, "-Infinity")
            } else {
                scan_number(chars, pos)
            }
        }
        '0'..='9' => scan_number(chars, pos),
        _ => Err(("Expecting value", pos)),
    }
}

fn scan_literal(chars: &[char], pos: usize, word: &str) -> Result<usize, ScanError> {
    let expected: Vec<char> = word.chars().collect();
    for (offset, want) in expected.iter().enumerate() {
        if chars.get(pos + offset) != Some(want) {
            return Err(("Expecting value", pos));
        }
    }
    Ok(pos + expected.len())
}

fn scan_number(chars: &[char], start: usize) -> Result<usize, ScanError> {
    let mut pos = start;
    if chars.get(pos) == Some(&'-') {
        pos += 1;
    }
    match chars.get(pos) {
        Some('0') => pos += 1,
        Some(c) if c.is_ascii_digit() => {
            while matches!(chars.get(pos), Some(c) if c.is_ascii_digit()) {
                pos += 1;
            }
        }
        _ => return Err(("Expecting value", start)),
    }
    // A fraction needs digits after the dot, an exponent digits after its
    // sign: when they do not follow, the number simply ends there, exactly
    // as Python's number regex leaves the character for the next rule.
    if chars.get(pos) == Some(&'.') && matches!(chars.get(pos + 1), Some(c) if c.is_ascii_digit()) {
        pos += 1;
        while matches!(chars.get(pos), Some(c) if c.is_ascii_digit()) {
            pos += 1;
        }
    }
    if matches!(chars.get(pos), Some('e') | Some('E')) {
        let mut after = pos + 1;
        if matches!(chars.get(after), Some('+') | Some('-')) {
            after += 1;
        }
        if matches!(chars.get(after), Some(c) if c.is_ascii_digit()) {
            pos = after;
            while matches!(chars.get(pos), Some(c) if c.is_ascii_digit()) {
                pos += 1;
            }
        }
    }
    Ok(pos)
}

fn scan_string(chars: &[char], start: usize) -> Result<usize, ScanError> {
    let mut pos = start + 1;
    loop {
        let Some(&ch) = chars.get(pos) else {
            return Err(("Unterminated string starting at", start));
        };
        match ch {
            '"' => return Ok(pos + 1),
            '\\' => {
                let Some(&escape) = chars.get(pos + 1) else {
                    return Err(("Unterminated string starting at", start));
                };
                match escape {
                    '"' | '\\' | '/' | 'b' | 'f' | 'n' | 'r' | 't' => pos += 2,
                    'u' => {
                        for offset in 0..4 {
                            if chars
                                .get(pos + 2 + offset)
                                .copied()
                                .and_then(|c| c.to_digit(16))
                                .is_none()
                            {
                                return Err(("Invalid \\uXXXX escape", pos + 1));
                            }
                        }
                        pos += 6;
                    }
                    _ => return Err(("Invalid \\escape", pos)),
                }
            }
            c if (c as u32) < 0x20 => return Err(("Invalid control character at", pos)),
            _ => pos += 1,
        }
    }
}

fn scan_object(chars: &[char], open: usize) -> Result<usize, ScanError> {
    let mut pos = skip_ws(chars, open + 1);
    loop {
        match chars.get(pos) {
            Some('}') => return Ok(pos + 1),
            Some('"') => {}
            _ => return Err(("Expecting property name enclosed in double quotes", pos)),
        }
        pos = scan_string(chars, pos)?;
        pos = skip_ws(chars, pos);
        if chars.get(pos) != Some(&':') {
            return Err(("Expecting ':' delimiter", pos));
        }
        pos = skip_ws(chars, pos + 1);
        pos = scan_value(chars, pos)?;
        pos = skip_ws(chars, pos);
        match chars.get(pos) {
            Some(',') => {
                let comma = pos;
                pos = skip_ws(chars, pos + 1);
                if chars.get(pos) == Some(&'}') {
                    // The refusal points at the comma, where the ill-formed
                    // pair began, not at the closer it was reaching for.
                    return Err(("Illegal trailing comma before end of object", comma));
                }
            }
            Some('}') => return Ok(pos + 1),
            _ => return Err(("Expecting ',' delimiter", pos)),
        }
    }
}

fn scan_array(chars: &[char], open: usize) -> Result<usize, ScanError> {
    let mut pos = skip_ws(chars, open + 1);
    if chars.get(pos) == Some(&']') {
        return Ok(pos + 1);
    }
    loop {
        pos = scan_value(chars, pos)?;
        pos = skip_ws(chars, pos);
        match chars.get(pos) {
            Some(',') => {
                let comma = pos;
                pos = skip_ws(chars, pos + 1);
                if chars.get(pos) == Some(&']') {
                    return Err(("Illegal trailing comma before end of array", comma));
                }
            }
            Some(']') => return Ok(pos + 1),
            _ => return Err(("Expecting ',' delimiter", pos)),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Every case was captured from CPython 3.13's json module directly.
    #[test]
    fn error_messages_match_cpython() {
        let cases: Vec<(&str, &str)> = vec![
            ("", "Expecting value: line 1 column 1 (char 0)"),
            ("notjson", "Expecting value: line 1 column 1 (char 0)"),
            (
                "{",
                "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)",
            ),
            (
                "{\"a\"",
                "Expecting ':' delimiter: line 1 column 5 (char 4)",
            ),
            ("{\"a\":}", "Expecting value: line 1 column 6 (char 5)"),
            (
                "{\"a\": 1,}",
                "Illegal trailing comma before end of object: line 1 column 8 (char 7)",
            ),
            ("[1,2", "Expecting ',' delimiter: line 1 column 5 (char 4)"),
            (
                "\"abc",
                "Unterminated string starting at: line 1 column 1 (char 0)",
            ),
            ("{\"a\": 1} extra", "Extra data: line 1 column 10 (char 9)"),
            ("[1] [2]", "Extra data: line 1 column 5 (char 4)"),
            (
                "{\"a\": 01}",
                "Expecting ',' delimiter: line 1 column 8 (char 7)",
            ),
            (
                "{\"a\": 1e}",
                "Expecting ',' delimiter: line 1 column 8 (char 7)",
            ),
            (
                "{'a': 1}",
                "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)",
            ),
            ("tru", "Expecting value: line 1 column 1 (char 0)"),
            (
                "{\"a\" 1}",
                "Expecting ':' delimiter: line 1 column 6 (char 5)",
            ),
            ("[\"\\x\"]", "Invalid \\escape: line 1 column 3 (char 2)"),
            ("[\"a\\q\"]", "Invalid \\escape: line 1 column 4 (char 3)"),
            ("{\"a\": +1}", "Expecting value: line 1 column 7 (char 6)"),
            (
                "[1,]",
                "Illegal trailing comma before end of array: line 1 column 3 (char 2)",
            ),
            ("{\"a\":.5}", "Expecting value: line 1 column 6 (char 5)"),
            ("123abc", "Extra data: line 1 column 4 (char 3)"),
            (
                "\"\u{1}\"",
                "Invalid control character at: line 1 column 2 (char 1)",
            ),
            (
                "{\"a\": 1 \"b\": 2}",
                "Expecting ',' delimiter: line 1 column 9 (char 8)",
            ),
            ("[1 2]", "Expecting ',' delimiter: line 1 column 4 (char 3)"),
            ("01", "Extra data: line 1 column 2 (char 1)"),
            ("{\"a\": 1}}", "Extra data: line 1 column 9 (char 8)"),
            (
                "{\"\\u12\"}",
                "Invalid \\uXXXX escape: line 1 column 4 (char 3)",
            ),
            ("1.", "Extra data: line 1 column 2 (char 1)"),
            ("[,1]", "Expecting value: line 1 column 2 (char 1)"),
            (
                "{,}",
                "Expecting property name enclosed in double quotes: line 1 column 2 (char 1)",
            ),
            (
                "[\"a\",]",
                "Illegal trailing comma before end of array: line 1 column 5 (char 4)",
            ),
            (
                "[\"a\\\"b]",
                "Unterminated string starting at: line 1 column 2 (char 1)",
            ),
            (
                "{\"a\": 1.5.5}",
                "Expecting ',' delimiter: line 1 column 10 (char 9)",
            ),
            ("{\"a\": -}", "Expecting value: line 1 column 7 (char 6)"),
            ("[--1]", "Expecting value: line 1 column 2 (char 1)"),
            (
                "{\"a\": 1e+}",
                "Expecting ',' delimiter: line 1 column 8 (char 7)",
            ),
            (" ", "Expecting value: line 1 column 2 (char 1)"),
            ("{\"a\"::1}", "Expecting value: line 1 column 6 (char 5)"),
            (
                "\"\\/",
                "Unterminated string starting at: line 1 column 1 (char 0)",
            ),
            ("[0x1]", "Expecting ',' delimiter: line 1 column 3 (char 2)"),
            ("- 1", "Expecting value: line 1 column 1 (char 0)"),
        ];
        for (text, expected) in cases {
            assert_eq!(
                python_json_error(text).as_deref(),
                Some(expected),
                "input {text:?}"
            );
        }
        // Python-valid documents, including its non-standard extensions.
        for text in [
            "NaN",
            "Infinity",
            "-Infinity",
            "{\"a\": NaN}",
            "[\"\\ud800\"]",
            "1e-999",
            "[[\"x\"]]",
            "{\"\":1}",
            "\"\\/\"",
            "\t{\"a\":1}",
        ] {
            assert_eq!(python_json_error(text), None, "input {text:?}");
        }
    }

    #[test]
    fn reparse_holds_pythons_nonstandard_documents() {
        // Non-finite literals become null, which every consumer refuses the
        // same way Python's finite check refuses the original.
        let value = python_reparse("{\"at_ms\": NaN}").unwrap();
        assert_eq!(value["at_ms"], serde_json::Value::Null);
        let value = python_reparse("[Infinity, -Infinity]").unwrap();
        assert_eq!(value[0], serde_json::Value::Null);
        // Overflowing exponents share the null rewrite.
        let value = python_reparse("{\"at_ms\": 1e999}").unwrap();
        assert_eq!(value["at_ms"], serde_json::Value::Null);
        // Unpaired surrogate escapes are replaced; paired ones stay astral.
        let value = python_reparse("[\"\\ud800\", \"\\ud83d\\ude00\"]").unwrap();
        assert_eq!(value[0].as_str(), Some("\u{FFFD}"));
        assert_eq!(value[1].as_str(), Some("\u{1F600}"));
        // Ordinary documents round-trip untouched.
        let value = python_reparse("{\"a\": [1.5e-7, 2], \"b\": \"NaN in a string\"}").unwrap();
        assert_eq!(value["b"].as_str(), Some("NaN in a string"));
        assert_eq!(value["a"][0].as_f64(), Some(1.5e-7));
    }
}
