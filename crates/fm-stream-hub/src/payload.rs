use crate::model::{Error, Result};
use std::collections::BTreeMap;

pub enum Json {
    Null,
    Bool(bool),
    Number(String),
    String(Vec<u32>),
    Array(Vec<Json>),
    Object(BTreeMap<Vec<u32>, Json>),
}
impl Json {
    pub fn parse(text: &str) -> Result<Self> {
        if let Some(error) = fm_stream_wire::python_json::python_json_error(text) {
            return Err(Error::new(
                400,
                "bad_json",
                format!("malformed JSON body: {error}"),
            ));
        }
        let mut parser = Parser { text, pos: 0 };
        Ok(parser.value())
    }
    pub fn get(&self, field: &str) -> &Self {
        match self {
            Self::Object(fields) => fields
                .get(&field.chars().map(u32::from).collect::<Vec<_>>())
                .unwrap_or(&Self::Null),
            _ => &Self::Null,
        }
    }
    pub fn truth(&self) -> bool {
        match self {
            Self::Null => false,
            Self::Bool(value) => *value,
            Self::Number(value) => value.parse::<f64>() != Ok(0.),
            Self::String(value) => !value.is_empty(),
            Self::Array(value) => !value.is_empty(),
            Self::Object(value) => !value.is_empty(),
        }
    }
    pub fn encode(&self) -> String {
        match self {
            Self::Null => "null".into(),
            Self::Bool(value) => value.to_string(),
            Self::Number(value) => value.clone(),
            Self::String(value) => string(value),
            Self::Array(values) => format!(
                "[{}]",
                values
                    .iter()
                    .map(Self::encode)
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
            Self::Object(fields) => format!(
                "{{{}}}",
                fields
                    .iter()
                    .map(|(key, value)| format!("{}: {}", string(key), value.encode()))
                    .collect::<Vec<_>>()
                    .join(", ")
            ),
        }
    }
}
fn string(value: &[u32]) -> String {
    let mut out = String::from("\"");
    for &point in value {
        match point {
            8 => out.push_str("\\b"),
            9 => out.push_str("\\t"),
            10 => out.push_str("\\n"),
            12 => out.push_str("\\f"),
            13 => out.push_str("\\r"),
            34 => out.push_str("\\\""),
            92 => out.push_str("\\\\"),
            32..=126 => out.push(char::from_u32(point).unwrap()),
            0..=0xffff => out.push_str(&format!("\\u{point:04x}")),
            _ => {
                let point = point - 0x10000;
                out.push_str(&format!(
                    "\\u{:04x}\\u{:04x}",
                    0xd800 + (point >> 10),
                    0xdc00 + (point & 0x3ff)
                ));
            }
        }
    }
    out.push('"');
    out
}
struct Parser<'a> {
    text: &'a str,
    pos: usize,
}
impl Parser<'_> {
    fn ws(&mut self) {
        while self
            .text
            .as_bytes()
            .get(self.pos)
            .is_some_and(|b| matches!(b, b' ' | b'\t' | b'\r' | b'\n'))
        {
            self.pos += 1;
        }
    }
    fn string(&mut self) -> Vec<u32> {
        self.pos += 1;
        let mut points = Vec::new();
        loop {
            let ch = self.text[self.pos..].chars().next().unwrap();
            self.pos += ch.len_utf8();
            if ch == '"' {
                break;
            }
            let point = if ch == '\\' {
                let escape = self.text.as_bytes()[self.pos];
                self.pos += 1;
                match escape {
                    b'u' => {
                        let unit =
                            u32::from_str_radix(&self.text[self.pos..self.pos + 4], 16).unwrap();
                        self.pos += 4;
                        if (0xd800..=0xdbff).contains(&unit)
                            && self.text[self.pos..].starts_with("\\u")
                        {
                            let low =
                                u32::from_str_radix(&self.text[self.pos + 2..self.pos + 6], 16)
                                    .unwrap();
                            if (0xdc00..=0xdfff).contains(&low) {
                                self.pos += 6;
                                0x10000 + ((unit - 0xd800) << 10) + low - 0xdc00
                            } else {
                                unit
                            }
                        } else {
                            unit
                        }
                    }
                    b'b' => 8,
                    b'f' => 12,
                    b'n' => 10,
                    b'r' => 13,
                    b't' => 9,
                    _ => u32::from(escape),
                }
            } else {
                u32::from(ch)
            };
            points.push(point);
        }
        points
    }
    fn value(&mut self) -> Json {
        self.ws();
        match self.text.as_bytes()[self.pos] {
            b'"' => Json::String(self.string()),
            b'{' => {
                self.pos += 1;
                let mut fields = BTreeMap::new();
                self.ws();
                while self.text.as_bytes()[self.pos] != b'}' {
                    let key = self.string();
                    self.ws();
                    self.pos += 1;
                    fields.insert(key, self.value());
                    self.ws();
                    if self.text.as_bytes()[self.pos] != b',' {
                        break;
                    }
                    self.pos += 1;
                    self.ws();
                }
                self.pos += 1;
                Json::Object(fields)
            }
            b'[' => {
                self.pos += 1;
                let mut values = Vec::new();
                self.ws();
                while self.text.as_bytes()[self.pos] != b']' {
                    values.push(self.value());
                    self.ws();
                    if self.text.as_bytes()[self.pos] != b',' {
                        break;
                    }
                    self.pos += 1;
                }
                self.pos += 1;
                Json::Array(values)
            }
            _ => {
                let start = self.pos;
                while self.text.as_bytes().get(self.pos).is_some_and(|b| {
                    !matches!(b, b',' | b'}' | b']' | b' ' | b'\t' | b'\r' | b'\n')
                }) {
                    self.pos += 1;
                }
                let token = &self.text[start..self.pos];
                match token {
                    "null" => Json::Null,
                    "true" => Json::Bool(true),
                    "false" => Json::Bool(false),
                    "NaN" | "Infinity" | "-Infinity" => Json::Number(token.into()),
                    _ => {
                        let float = token.contains(['.', 'e', 'E']);
                        let number = if float
                            && token.parse::<f64>().is_ok_and(|value| value.is_infinite())
                        {
                            if token.starts_with('-') {
                                "-Infinity".into()
                            } else {
                                "Infinity".into()
                            }
                        } else {
                            crate::encode(
                                &serde_json::from_str::<serde_json::Value>(token).unwrap(),
                            )
                        };
                        Json::Number(number)
                    }
                }
            }
        }
    }
}

pub fn object(fields: &[(&str, String)]) -> String {
    let sorted: BTreeMap<_, _> = fields.iter().cloned().collect();
    format!(
        "{{{}}}",
        sorted
            .iter()
            .map(|(key, value)| format!("{}: {}", crate::encode(&serde_json::json!(key)), value))
            .collect::<Vec<_>>()
            .join(", ")
    )
}
