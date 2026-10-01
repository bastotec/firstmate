use serde_json::{value::RawValue, Value};
use std::collections::HashMap;
use unicode_general_category::{get_general_category, GeneralCategory};

pub fn python_str(
    value: &Value,
    nonfinite: &HashMap<String, &'static str>,
) -> Result<String, &'static str> {
    Ok(match value {
        Value::Null => "None".into(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Number(number) if !number.is_f64() => {
            let token = number.to_string();
            nonfinite
                .get(&token)
                .map(|text| (*text).to_owned())
                .unwrap_or(token)
        }
        Value::Number(number) => {
            let float = number.as_f64().unwrap_or_else(|| {
                if number.to_string().starts_with('-') {
                    f64::NEG_INFINITY
                } else {
                    f64::INFINITY
                }
            });
            if float.is_finite() {
                fm_stream_wire::python_repr_f64(float)
            } else if float.is_sign_negative() {
                "-inf".into()
            } else {
                "inf".into()
            }
        }
        Value::String(text) => text.clone(),
        Value::Array(_) | Value::Object(_) => return Err("unrendered composite command value"),
    })
}

pub(super) fn raw_python_str(
    raw: &RawValue,
    nonfinite: &HashMap<String, &'static str>,
) -> Result<Result<String, &'static str>, serde_json::Error> {
    let bytes = raw.get().as_bytes();
    if bytes.first() == Some(&b'"') {
        let text: String = serde_json::from_slice(bytes)?;
        return Ok(decoded_string(&text));
    }
    let mut output = String::new();
    for token in crate::hub_json::Tokens::new(bytes) {
        match token {
            b"[" | b"]" | b"{" | b"}" => output.push(token[0] as char),
            b":" => output.push_str(": "),
            b"," => output.push_str(", "),
            token if token.first() == Some(&b'"') => {
                let text: String = serde_json::from_slice(token)?;
                string_repr(&mut output, &text);
            }
            token => match python_str(&serde_json::from_slice(token)?, nonfinite) {
                Ok(text) => output.push_str(&text),
                Err(error) => return Ok(Err(error)),
            },
        }
    }
    Ok(Ok(output))
}

pub(super) fn decoded_string(text: &str) -> Result<String, &'static str> {
    codes(text)
        .map(|code| char::from_u32(code).ok_or("surrogates cannot be encoded as UTF-8"))
        .collect()
}

fn codes(text: &str) -> impl Iterator<Item = u32> + '_ {
    let mut chars = text.chars();
    std::iter::from_fn(move || {
        let ch = chars.next()?;
        Some(if ch == '\0' {
            match chars.next().unwrap() {
                'n' => 0,
                's' => (0..4).fold(0, |unit, _| {
                    (unit << 4) | chars.next().unwrap().to_digit(16).unwrap()
                }),
                _ => unreachable!("invalid normalized string escape"),
            }
        } else {
            ch as u32
        })
    })
}

fn string_repr(output: &mut String, text: &str) {
    let quote = if text.contains('\'') && !text.contains('"') {
        '"'
    } else {
        '\''
    };
    output.push(quote);
    for code in codes(text) {
        let Some(ch) = char::from_u32(code) else {
            use std::fmt::Write;
            write!(output, "\\u{code:04x}").unwrap();
            continue;
        };
        match ch {
            '\\' => output.push_str("\\\\"),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            ch if ch == quote => {
                output.push('\\');
                output.push(ch);
            }
            ch if ch != ' '
                && matches!(
                    get_general_category(ch),
                    GeneralCategory::Control
                        | GeneralCategory::Format
                        | GeneralCategory::Surrogate
                        | GeneralCategory::PrivateUse
                        | GeneralCategory::Unassigned
                        | GeneralCategory::SpaceSeparator
                        | GeneralCategory::LineSeparator
                        | GeneralCategory::ParagraphSeparator
                ) =>
            {
                use std::fmt::Write;
                if code <= 0xff {
                    write!(output, "\\x{code:02x}").unwrap();
                } else if code <= 0xffff {
                    write!(output, "\\u{code:04x}").unwrap();
                } else {
                    write!(output, "\\U{code:08x}").unwrap();
                }
            }
            ch => output.push(ch),
        }
    }
    output.push(quote);
}
