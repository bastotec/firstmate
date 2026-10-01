use serde_json::{value::RawValue, Value};
use std::collections::{BTreeMap, HashMap, HashSet};
use std::ops::Deref;

pub struct Response {
    value: Value,
    nonfinite: HashMap<String, &'static str>,
    encoding_errors: HashMap<String, &'static str>,
}

impl Deref for Response {
    type Target = Value;

    fn deref(&self) -> &Value {
        &self.value
    }
}

impl Response {
    pub fn python_str(&self, value: &Value) -> Result<String, &'static str> {
        if let Value::Number(number) = value {
            if let Some(error) = self.encoding_errors.get(&number.to_string()) {
                return Err(error);
            }
        }
        crate::command_value::python_str(value, &self.nonfinite)
    }
}

struct Tags {
    used: HashSet<String>,
    next: u128,
}

impl Tags {
    fn new(bytes: &[u8]) -> Self {
        Self {
            used: Tokens::new(bytes)
                .filter(|token| matches!(token.first(), Some(b'0'..=b'9' | b'-')))
                .map(|token| String::from_utf8_lossy(token).into_owned())
                .collect(),
            next: u128::MAX,
        }
    }

    fn take(&mut self) -> String {
        loop {
            let token = self.next.to_string();
            self.next -= 1;
            if self.used.insert(token.clone()) {
                return token;
            }
        }
    }
}

pub fn decode(bytes: &[u8], command_response: bool) -> Result<Response, serde_json::Error> {
    if !command_response {
        return Ok(Response {
            value: serde_json::from_slice(bytes)?,
            nonfinite: HashMap::new(),
            encoding_errors: HashMap::new(),
        });
    }
    let mut normalized = Vec::with_capacity(bytes.len());
    let mut nonfinite: HashMap<String, &'static str> = HashMap::new();
    let mut tags = Tags::new(bytes);
    let mut quoted = false;
    let mut escaped = false;
    let mut index = 0;
    while index < bytes.len() {
        let byte = bytes[index];
        if quoted {
            if escaped {
                escaped = false;
            } else if byte == b'\\' {
                if let Some(unit) = unicode_escape(&bytes[index..]) {
                    if unit == 0 {
                        normalized.extend_from_slice(b"\\u0000n");
                        index += 6;
                        continue;
                    }
                    if (0xd800..=0xdfff).contains(&unit) {
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
                        normalized.extend_from_slice(format!("\\u0000s{unit:04x}").as_bytes());
                        index += 6;
                        continue;
                    }
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
            .find(|(token, _)| {
                bytes[index..].starts_with(token)
                    && bytes
                        .get(index + token.len())
                        .is_none_or(|byte| value_end(*byte))
            })
            .copied();
            if let Some((token, rendered)) = special {
                let marker = nonfinite
                    .iter()
                    .find_map(|(marker, value)| (*value == rendered).then(|| marker.clone()))
                    .unwrap_or_else(|| tags.take());
                normalized.extend_from_slice(marker.as_bytes());
                nonfinite.insert(marker, rendered);
                index += token.len();
                continue;
            }
        }
        normalized.push(byte);
        index += 1;
    }
    let fields: BTreeMap<String, &RawValue> = serde_json::from_slice(&normalized)?;
    let mut value = serde_json::Map::new();
    let mut encoding_errors = HashMap::new();
    for (key, raw) in fields {
        let parsed = if key == "commands" {
            let commands: Vec<BTreeMap<String, &RawValue>> = serde_json::from_str(raw.get())?;
            let mut parsed = Vec::with_capacity(commands.len());
            for command in commands {
                let convertible = command
                    .get("kind")
                    .map(|kind| plain(kind))
                    .transpose()?
                    .is_some_and(|kind| kind == "input" || kind == "status");
                let mut fields = serde_json::Map::new();
                for (key, raw) in command {
                    let parsed = if key == "payload" && convertible {
                        let payload: BTreeMap<String, &RawValue> = serde_json::from_str(raw.get())?;
                        let mut fields = serde_json::Map::new();
                        for (key, raw) in payload {
                            let parsed =
                                if matches!(key.as_str(), "text" | "note") && raw.get() != "null" {
                                    match crate::command_value::raw_python_str(raw, &nonfinite)? {
                                        Ok(text) => Value::String(text),
                                        Err(error) => {
                                            let marker = tags.take();
                                            let value = serde_json::from_str(&marker)?;
                                            encoding_errors.insert(marker, error);
                                            value
                                        }
                                    }
                                } else {
                                    plain(raw)?
                                };
                            fields.insert(key, parsed);
                        }
                        Value::Object(fields)
                    } else {
                        plain(raw)?
                    };
                    fields.insert(key, parsed);
                }
                parsed.push(Value::Object(fields));
            }
            Value::Array(parsed)
        } else {
            plain(raw)?
        };
        value.insert(key, parsed);
    }
    Ok(Response {
        value: Value::Object(value),
        nonfinite,
        encoding_errors,
    })
}

fn plain(raw: &RawValue) -> Result<Value, serde_json::Error> {
    let mut value = serde_json::from_str(raw.get())?;
    let mut pending = vec![&mut value];
    while let Some(value) = pending.pop() {
        match value {
            Value::String(text) => *text = decode_string(text)?,
            Value::Array(items) => pending.extend(items.iter_mut()),
            Value::Object(items) => {
                let old = std::mem::take(items);
                for (key, value) in old {
                    items.insert(decode_string(&key)?, value);
                }
                pending.extend(items.values_mut());
            }
            _ => (),
        }
    }
    Ok(value)
}

fn decode_string(text: &str) -> Result<String, serde_json::Error> {
    crate::command_value::decoded_string(text).map_err(|error| {
        serde_json::Error::io(std::io::Error::new(std::io::ErrorKind::InvalidData, error))
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

pub(super) struct Tokens<'a> {
    bytes: &'a [u8],
    index: usize,
}

impl<'a> Tokens<'a> {
    pub(super) fn new(bytes: &'a [u8]) -> Self {
        Self { bytes, index: 0 }
    }
}

impl<'a> Iterator for Tokens<'a> {
    type Item = &'a [u8];

    fn next(&mut self) -> Option<Self::Item> {
        while self
            .bytes
            .get(self.index)
            .is_some_and(u8::is_ascii_whitespace)
        {
            self.index += 1;
        }
        let start = self.index;
        let byte = *self.bytes.get(start)?;
        self.index += 1;
        if byte == b'"' {
            while let Some(byte) = self.bytes.get(self.index) {
                self.index += 1;
                if *byte == b'\\' {
                    self.index = (self.index + 1).min(self.bytes.len());
                } else if *byte == b'"' {
                    break;
                }
            }
        } else if !matches!(byte, b'[' | b']' | b'{' | b'}' | b':' | b',') {
            while self.bytes.get(self.index).is_some_and(|byte| {
                !byte.is_ascii_whitespace()
                    && !matches!(byte, b'[' | b']' | b'{' | b'}' | b':' | b',' | b'"')
            }) {
                self.index += 1;
            }
        }
        Some(&self.bytes[start..self.index])
    }
}

#[cfg(test)]
mod tests {
    use super::decode;

    fn command(note: &str) -> String {
        format!("{{\"commands\":[{{\"kind\":\"status\",\"payload\":{{\"note\":{note}}}}}]}}")
    }

    #[test]
    fn composite_surrogates_are_scoped_to_command_responses() {
        let bytes = command(
            r#"["\ud800",{"\udfff":"a\ud800'b","paired":"\ud83d\ude00","literal":"\\ud800","null":"\u0000d800","mixed":"\u0000\ud800\u0000\udfff"},NaN]"#,
        );
        assert!(decode(command(r#"["\ud800"]"#).as_bytes(), false).is_err());
        assert!(decode(bytes.as_bytes(), false).is_err());
        let response = decode(bytes.as_bytes(), true).unwrap();
        assert_eq!(
            response.python_str(&response["commands"][0]["payload"]["note"]).unwrap(),
            "['\\ud800', {'\\udfff': \"a\\ud800'b\", 'paired': '😀', 'literal': '\\\\ud800', 'null': '\\x00d800', 'mixed': '\\x00\\ud800\\x00\\udfff'}, nan]"
        );
        let response = decode(command(r#""\ud800""#).as_bytes(), true).unwrap();
        assert!(response
            .python_str(&response["commands"][0]["payload"]["note"])
            .is_err());
    }

    #[test]
    fn malformed_command_strings_still_fail() {
        for note in [
            r#"["\ud800\q"]"#,
            r#"["\ud80"]"#,
            r#"["\ud800""#,
            "[\"\\ud800\0\"]",
        ] {
            assert!(decode(command(note).as_bytes(), true).is_err());
        }
    }

    #[test]
    fn large_surrogate_composite_has_exact_linear_rendering() {
        let note = format!(
            "[\"{}{}\"]",
            "\\u0000".repeat(50_000),
            "\\ud800".repeat(50_000)
        );
        let response = decode(command(&note).as_bytes(), true).unwrap();
        assert_eq!(
            response
                .python_str(&response["commands"][0]["payload"]["note"])
                .unwrap(),
            format!("['{}{}']", "\\x00".repeat(50_000), "\\ud800".repeat(50_000))
        );
    }

    #[test]
    fn nested_command_values_do_not_use_recursive_trees() {
        let note = format!("{}\"ordinary\"{}", "[".repeat(10_000), "]".repeat(10_000));
        let bytes = command(&note);
        assert!(decode(bytes.as_bytes(), false).is_err());
        let response = decode(bytes.as_bytes(), true).unwrap();
        assert_eq!(
            response
                .python_str(&response["commands"][0]["payload"]["note"])
                .unwrap(),
            format!("{}'ordinary'{}", "[".repeat(10_000), "]".repeat(10_000))
        );
    }
}
