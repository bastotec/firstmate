use serde_json::Value;
use std::collections::HashMap;
use unicode_general_category::{get_general_category, GeneralCategory};

pub fn python_str(value: &Value, nonfinite: &HashMap<String, &'static str>) -> String {
    match value {
        Value::String(text) => text.clone(),
        other => python_repr(other, nonfinite),
    }
}

fn python_repr(value: &Value, nonfinite: &HashMap<String, &'static str>) -> String {
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
        Value::String(text) => string_repr(text),
        Value::Array(items) => format!(
            "[{}]",
            items
                .iter()
                .map(|item| python_repr(item, nonfinite))
                .collect::<Vec<_>>()
                .join(", ")
        ),
        Value::Object(items) => format!(
            "{{{}}}",
            items
                .iter()
                .map(|(key, value)| {
                    format!("{}: {}", string_repr(key), python_repr(value, nonfinite))
                })
                .collect::<Vec<_>>()
                .join(", ")
        ),
    }
}

fn string_repr(text: &str) -> String {
    let quote = if text.contains('\'') && !text.contains('"') {
        '"'
    } else {
        '\''
    };
    let mut output = String::new();
    output.push(quote);
    for ch in text.chars() {
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
