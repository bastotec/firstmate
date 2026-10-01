use serde_json::Value;
use std::collections::HashMap;
use std::ops::Deref;

pub struct Response {
    value: Value,
    nonfinite: HashMap<String, &'static str>,
    surrogate_prefix: String,
}

impl Deref for Response {
    type Target = Value;

    fn deref(&self) -> &Value {
        &self.value
    }
}

impl Response {
    pub fn python_str(&self, value: &Value) -> Result<String, &'static str> {
        crate::command_value::python_str(value, &self.nonfinite, &self.surrogate_prefix)
    }
}

pub fn decode(bytes: &[u8], command_response: bool) -> Result<Response, serde_json::Error> {
    if !command_response {
        return Ok(Response {
            value: serde_json::from_slice(bytes)?,
            nonfinite: HashMap::new(),
            surrogate_prefix: String::new(),
        });
    }
    let mut normalized = Vec::with_capacity(bytes.len());
    let mut nonfinite = HashMap::new();
    let mut null_run = 0;
    let mut longest_null_run = 0;
    let mut index = 0;
    while index < bytes.len() {
        if unicode_escape(&bytes[index..]) == Some(0) {
            null_run += 1;
            longest_null_run = longest_null_run.max(null_run);
            index += 6;
        } else {
            null_run = 0;
            index += 1;
        }
    }
    let surrogate_prefix = format!("{}:", "\0".repeat(longest_null_run + 1));
    let mut prefix = String::from("100000000000000000000");
    while bytes
        .windows(prefix.len())
        .any(|part| part == prefix.as_bytes())
    {
        prefix.push('0');
    }
    let mut quoted = false;
    let mut escaped = false;
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        if quoted {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                if let Some(unit) =
                    unicode_escape(&bytes[index..]).filter(|unit| (0xd800..=0xdfff).contains(unit))
                {
                    if (0xd800..=0xdbff).contains(&unit)
                        && bytes
                            .get(index + 6..)
                            .and_then(unicode_escape)
                            .is_some_and(|low| (0xdc00..=0xdfff).contains(&low))
                    {
                        normalized.extend_from_slice(&bytes[index..index + 12]);
                        index += 12;
                        continue;
                    }
                    let marker = serde_json::to_vec(&format!("{surrogate_prefix}{unit:04x}"))?;
                    normalized.extend_from_slice(&marker[1..marker.len() - 1]);
                    index += 6;
                    continue;
                }
                escaped = true;
            } else if byte == b'"' {
                quoted = false;
            }
        } else if byte == b'"' {
            quoted = true;
        } else if index == 0 || value_start(bytes[index - 1]) {
            let special = [
                (b"NaN".as_slice(), "nan"),
                (b"Infinity".as_slice(), "inf"),
                (b"-Infinity".as_slice(), "-inf"),
            ]
            .iter()
            .enumerate()
            .find(|(_, (token, _))| {
                bytes[index..].starts_with(token)
                    && bytes
                        .get(index + token.len())
                        .is_none_or(|byte| value_end(*byte))
            })
            .map(|(tag, (token, rendered))| (tag, token.len(), *rendered));
            if let Some((tag, length, rendered)) = special {
                let marker = format!("{prefix}{tag}");
                normalized.extend_from_slice(marker.as_bytes());
                nonfinite.insert(marker, rendered);
                index += length;
                continue;
            }
        }
        normalized.push(byte);
        index += 1;
    }
    Ok(Response {
        value: serde_json::from_slice(&normalized)?,
        nonfinite,
        surrogate_prefix,
    })
}

fn unicode_escape(bytes: &[u8]) -> Option<u16> {
    if !bytes.starts_with(b"\\u") {
        return None;
    }
    let hex = std::str::from_utf8(bytes.get(2..6)?).ok()?;
    if !hex.bytes().all(|byte| byte.is_ascii_hexdigit()) {
        return None;
    }
    u16::from_str_radix(hex, 16).ok()
}

fn value_start(byte: u8) -> bool {
    matches!(byte, b'[' | b',' | b':' | b' ' | b'\t' | b'\r' | b'\n')
}

fn value_end(byte: u8) -> bool {
    matches!(byte, b']' | b'}' | b',' | b' ' | b'\t' | b'\r' | b'\n')
}

#[cfg(test)]
mod tests {
    use super::decode;

    #[test]
    fn composite_surrogates_are_scoped_to_command_responses() {
        let bytes = br#"{"note":["\ud800",{"\udfff":"a\ud800'b","paired":"\ud83d\ude00","literal":"\\ud800","null":"\u0000d800","mixed":"\u0000\ud800\u0000\udfff"},NaN]}"#;
        assert!(decode(br#"{"note":["\ud800"]}"#, false).is_err());
        assert!(decode(bytes, false).is_err());
        let response = decode(bytes, true).unwrap();
        assert_eq!(
            response.python_str(&response["note"]).unwrap(),
            "['\\ud800', {'\\udfff': \"a\\ud800'b\", 'paired': '😀', 'literal': '\\\\ud800', 'null': '\\x00d800', 'mixed': '\\x00\\ud800\\x00\\udfff'}, nan]"
        );
        let response = decode(br#"{"note":"\ud800"}"#, true).unwrap();
        assert!(response.python_str(&response["note"]).is_err());
    }

    #[test]
    fn malformed_command_strings_still_fail() {
        for bytes in [
            br#"["\ud800\q"]"#.as_slice(),
            br#"["\ud80"]"#,
            br#"["\ud800""#,
            b"[\"\\ud800\x00\"]",
        ] {
            assert!(decode(bytes, true).is_err());
        }
    }
}
