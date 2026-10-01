use serde_json::Value;
use std::collections::HashMap;
use unicode_general_category::{get_general_category, GeneralCategory};

pub fn python_str(
    value: &Value,
    nonfinite: &HashMap<String, &'static str>,
    surrogate_prefix: &str,
) -> Result<String, &'static str> {
    match value {
        Value::String(text) if !surrogate_prefix.is_empty() && text.contains(surrogate_prefix) => {
            Err("surrogates cannot be encoded as UTF-8")
        }
        Value::String(text) => Ok(text.clone()),
        other => Ok(python_repr(other, nonfinite, surrogate_prefix)),
    }
}

fn python_repr(
    value: &Value,
    nonfinite: &HashMap<String, &'static str>,
    surrogate_prefix: &str,
) -> String {
    match value {
        Value::Null => "None".into(),
        Value::Bool(true) => "True".into(),
        Value::Bool(false) => "False".into(),
        Value::Number(number) if !number.is_f64() => {
            let token = number.to_string();
            nonfinite
                .get(&token)
                .map(|value| (*value).to_owned())
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
        Value::String(text) => string_repr(text, surrogate_prefix),
        Value::Array(items) => format!(
            "[{}]",
            items
                .iter()
                .map(|item| python_repr(item, nonfinite, surrogate_prefix))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Value::Object(items) => format!(
            "{{{}}}",
            items
                .iter()
                .map(|(key, value)| {
                    format!(
                        "{}: {}",
                        string_repr(key, surrogate_prefix),
                        python_repr(value, nonfinite, surrogate_prefix)
                    )
                })
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn string_repr(text: &str, surrogate_prefix: &str) -> String {
    let quote = if text.contains('\'') && !text.contains('"') {
        '"'
    } else {
        '\''
    };
    let mut output = String::new();
    output.push(quote);
    let mut remaining = text;
    while !remaining.is_empty() {
        if !surrogate_prefix.is_empty() {
            if let Some(rest) = remaining.strip_prefix(surrogate_prefix) {
                output.push_str("\\u");
                output.push_str(&rest[..4]);
                remaining = &rest[4..];
                continue;
            }
        }
        let ch = remaining.chars().next().unwrap();
        remaining = &remaining[ch.len_utf8()..];
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
                let code = ch as u32;
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
    output
}
