use serde_json::Value;
use std::collections::HashMap;
use std::ops::Deref;

pub struct Response {
    value: Value,
    nonfinite: HashMap<String, &'static str>,
}

impl Deref for Response {
    type Target = Value;

    fn deref(&self) -> &Value {
        &self.value
    }
}

impl Response {
    pub fn python_str(&self, value: &Value) -> String {
        crate::command_value::python_str(value, &self.nonfinite)
    }
}

pub fn decode(bytes: &[u8], command_response: bool) -> Result<Response, serde_json::Error> {
    if !command_response {
        return Ok(Response {
            value: serde_json::from_slice(bytes)?,
            nonfinite: HashMap::new(),
        });
    }
    let mut normalized = Vec::with_capacity(bytes.len());
    let mut nonfinite = HashMap::new();
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
    })
}

fn value_start(byte: u8) -> bool {
    matches!(byte, b'[' | b',' | b':' | b' ' | b'\t' | b'\r' | b'\n')
}

fn value_end(byte: u8) -> bool {
    matches!(byte, b']' | b'}' | b',' | b' ' | b'\t' | b'\r' | b'\n')
}
