//! A stack-safe compatibility scanner for CPython's `json.JSONDecodeError` messages.
//!
//! `serde_json` and CPython disagree on both messages and the set of accepted
//! documents (Python takes `NaN`/`Infinity` literals and lone surrogate
//! escapes), and the adapters surface those messages verbatim (`line %d is
//! not JSON: %s`, `cannot read the feed %s: %s`).  So when `serde_json`
//! rejects a document, this scanner produces Python's own refusal, or says
//! `None` when Python would accept the document. Container scanning uses an
//! explicit stack so deeply nested command values do not exhaust the call stack.
//!
//! Positions are character-based, like Python's, and `lineno`/`colno` follow
//! CPython's arithmetic, including for multiline hub request bodies.

/// Python's error message, or a safety refusal above 128 nested containers.
/// This entry point retains the bridge's bounded Serde-value contract.
pub fn python_json_error(text: &str) -> Option<String> {
    let mut depth: usize = 0;
    let mut quoted = false;
    let mut escaped = false;
    for byte in text.bytes() {
        if quoted {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                escaped = true;
            } else if byte == b'"' {
                quoted = false;
            }
        } else {
            match byte {
                b'"' => quoted = true,
                b'[' | b'{' => {
                    depth += 1;
                    if depth > 128 {
                        return Some("maximum JSON nesting depth exceeded".into());
                    }
                }
                b']' | b'}' => depth = depth.saturating_sub(1),
                _ => (),
            }
        }
    }
    python_json_error_unbounded(text)
}

/// Python's error message, or `None` for a Python-valid document.
/// Use only with stack-safe value parsing, encoding, and destruction.
pub fn python_json_error_unbounded(text: &str) -> Option<String> {
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
/// can be re-parsed.
pub fn python_reparse(text: &str) -> Result<serde_json::Value, ()> {
    reparse(text, "null")
}

/// Reparse with non-finite values represented by a truthy number instead of null.
/// Use only to recover consumed boolean fields: this is not a numeric-value
/// representation and must not replace the bridge's null-based reparse.
pub fn python_reparse_truthy(text: &str) -> Result<serde_json::Value, ()> {
    reparse(text, "1")
}

fn reparse(text: &str, nonfinite: &str) -> Result<serde_json::Value, ()> {
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
                if c == '\\' && index + 1 < chars.len() {
                    out.push(c);
                    out.push(chars[index + 1]);
                    index += 2;
                    continue;
                }
                out.push(c);
                index += 1;
            }
            continue;
        }
        if ch == '-' || ch.is_ascii_digit() || ch == 'N' || ch == 'I' {
            // A bare number or non-standard literal outside strings: replace
            // the ones serde cannot hold with the caller's sentinel.
            let start = index;
            if ch == '-' {
                index += 1;
            }
            if matches!(chars.get(index), Some('N') | Some('I')) {
                while index < chars.len() && chars[index].is_ascii_alphabetic() {
                    index += 1;
                }
                out.push_str(nonfinite);
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
                _ => out.push_str(nonfinite),
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

fn scan_value(chars: &[char], mut pos: usize) -> Result<usize, ScanError> {
    // Each entry is the closer to expect after this container's next value.
    let mut containers = Vec::new();
    loop {
        match chars.get(pos) {
            Some('{') => {
                containers.push('}');
                pos = skip_ws(chars, pos + 1);
                if chars.get(pos) != Some(&'}') {
                    pos = scan_key(chars, pos)?;
                    continue;
                }
                pos += 1;
                containers.pop();
            }
            Some('[') => {
                containers.push(']');
                pos = skip_ws(chars, pos + 1);
                if chars.get(pos) != Some(&']') {
                    continue;
                }
                pos += 1;
                containers.pop();
            }
            Some('"') => pos = scan_string(chars, pos)?,
            Some('t') => pos = scan_literal(chars, pos, "true")?,
            Some('f') => pos = scan_literal(chars, pos, "false")?,
            Some('n') => pos = scan_literal(chars, pos, "null")?,
            Some('N') => pos = scan_literal(chars, pos, "NaN")?,
            Some('I') => pos = scan_literal(chars, pos, "Infinity")?,
            Some('-') if chars.get(pos + 1) == Some(&'I') => {
                pos = scan_literal(chars, pos, "-Infinity")?;
            }
            Some('-' | '0'..='9') => pos = scan_number(chars, pos)?,
            _ => return Err(("Expecting value", pos)),
        }
        loop {
            let Some(&closer) = containers.last() else {
                return Ok(pos);
            };
            pos = skip_ws(chars, pos);
            if chars.get(pos) == Some(&closer) {
                containers.pop();
                pos += 1;
                continue;
            }
            if chars.get(pos) != Some(&',') {
                return Err(("Expecting ',' delimiter", pos));
            }
            let comma = pos;
            pos = skip_ws(chars, pos + 1);
            if chars.get(pos) == Some(&closer) {
                return Err((
                    if closer == '}' {
                        "Illegal trailing comma before end of object"
                    } else {
                        "Illegal trailing comma before end of array"
                    },
                    comma,
                ));
            }
            if closer == '}' {
                pos = scan_key(chars, pos)?;
            }
            break;
        }
    }
}

fn scan_key(chars: &[char], pos: usize) -> Result<usize, ScanError> {
    if chars.get(pos) != Some(&'"') {
        return Err(("Expecting property name enclosed in double quotes", pos));
    }
    let pos = skip_ws(chars, scan_string(chars, pos)?);
    if chars.get(pos) != Some(&':') {
        return Err(("Expecting ':' delimiter", pos));
    }
    Ok(skip_ws(chars, pos + 1))
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
    fn nesting_is_scanned_without_recursion_or_counting_string_contents() {
        let nested = format!("{}0{}", "[".repeat(200_000), "]".repeat(200_000));
        assert_eq!(python_json_error_unbounded(&nested), None);
        assert_eq!(
            python_json_error(&nested).as_deref(),
            Some("maximum JSON nesting depth exceeded")
        );
        let mixed = format!("{}0{}", "{\"x\":[".repeat(100_000), "]}".repeat(100_000));
        assert_eq!(python_json_error_unbounded(&mixed), None);
        let malformed = format!("{}0,{}", "[".repeat(150), "]".repeat(150));
        assert_eq!(
            python_json_error_unbounded(&malformed).as_deref(),
            Some("Illegal trailing comma before end of array: line 1 column 152 (char 151)")
        );
        let quoted =
            serde_json::json!({"text": format!("\\\"{}", "[".repeat(200_000))}).to_string();
        assert_eq!(python_json_error(&quoted), None);
        let bounded = format!("{}NaN{}", "[".repeat(64), "]".repeat(64));
        assert_eq!(python_json_error(&bounded), None);
        assert!(python_reparse(&bounded).is_ok());
    }

    #[test]
    fn reparse_preserves_literal_escapes_and_escaped_quotes() {
        let text =
            r#"{"text":"\\ud800 \\udfff \\ud83d\\ude00 \\\"NaN Infinity","keys":["\ud800"]}"#;
        assert_eq!(python_json_error(text), None);
        let value = python_reparse(text).unwrap();
        assert_eq!(
            value["text"],
            "\\ud800 \\udfff \\ud83d\\ude00 \\\"NaN Infinity"
        );
        assert_eq!(value["keys"][0], "\u{fffd}");
        let escaped_quote = r#"{"text":"a\"NaN Infinity b","unused":NaN}"#;
        let value = python_reparse(escaped_quote).unwrap();
        assert_eq!(value["text"], "a\"NaN Infinity b");
    }

    #[test]
    fn truthy_reparse_does_not_change_bridge_nonfinite_conversion() {
        let text = "[NaN, Infinity, -Infinity, 1e999, -1e999, 0, 1e-999]";
        let bridge = python_reparse(text).unwrap();
        let truthy = python_reparse_truthy(text).unwrap();
        for index in 0..5 {
            assert!(bridge[index].is_null());
            assert_eq!(truthy[index], 1);
        }
        for index in 5..7 {
            assert_eq!(bridge[index].as_f64(), Some(0.));
            assert_eq!(truthy[index].as_f64(), Some(0.));
        }
    }

    #[test]
    fn reparse_holds_pythons_nonstandard_documents() {
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
