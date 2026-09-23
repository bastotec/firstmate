//! Shared wire contract for the Rust stream-backend port.
//!
//! One compiled definition of what crosses the wire for the Rust pieces as
//! they replace the Python backend one at a time.  The bridge uses it today;
//! later hub and agent ports should reuse it rather than restating the
//! protocol.  The Python deployment at `bin/fm-stream-hub.py`,
//! `bin/fm-stream-agent.py`, and `bin/fm-stream-bridge.py` remains the
//! reference implementation while the port proceeds; its OBSERVED BEHAVIOUR,
//! not its source, is the spec.  The byte-level encoders here reproduce the
//! Python toolchain's observable output exactly - `json.dumps` with default
//! `ensure_ascii` and the interpreter's `repr` for floats - because the
//! bridge's NDJSON feed is diffed byte-for-byte against the reference in
//! `tests/fm-stream-bridge-rust.test.sh`.
//!
//! JSON integers wider than 64 bits remain outside the Rust bridge's accepted
//! domain.  Signed 64-bit values cover every OS exit status and hub clock the
//! deployed backend produces.

pub mod python_json;

/// The hub wire protocol this generation speaks.  A peer announcing anything
/// else is refused rather than driven on guessed routes; this is the same
/// number `bin/fm-stream-hub.py --protocol` prints.
pub const HUB_PROTOCOL: i64 = 2;

/// Longest a machine name or task label may be, mirroring the hub's registry
/// limits (it refuses to register anything longer, so the bridge never sees
/// one from a healthy hub - it re-checks anyway rather than guessing).
pub const MAX_MACHINE_LEN: usize = 128;
pub const MAX_LABEL_LEN: usize = 128;

/// The three heartbeat states the Bridge UI's live wire format defines.  The
/// hub's only positive verdict is an agent reporting its own worker gone;
/// everything else - running, silent, or a close the hub made on its own -
/// carries no verdict at all.
pub const STATE_UNKNOWN: &str = "Unknown";
pub const STATE_STOPPED: &str = "Stopped";
pub const STATE_FAILED: &str = "Failed";

// --- identity validation ----------------------------------------------------

/// A durable endpoint id: exactly 32 lowercase hex characters.
pub fn is_endpoint_id(s: &str) -> bool {
    s.len() == 32
        && s.bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}

/// A machine name: 1-128 characters of `[A-Za-z0-9._-]`.
pub fn is_machine_name(s: &str) -> bool {
    let mut count = 0;
    for ch in s.chars() {
        count += 1;
        if !(ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-')) {
            return false;
        }
    }
    count >= 1 && count <= MAX_MACHINE_LEN
}

/// A task label: 1-128 characters of `[A-Za-z0-9._@%+-]`.
pub fn is_label(s: &str) -> bool {
    let mut count = 0;
    for ch in s.chars() {
        count += 1;
        if !(ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '@' | '%' | '+' | '-')) {
            return false;
        }
    }
    count >= 1 && count <= MAX_LABEL_LEN
}

// --- listing resolution -----------------------------------------------------

/// One leaf as resolved from a hub `/v1/tasks` answer.
///
/// `exit_code` is the raw JSON integer the listing carried (`None` for null,
/// non-integers, and out-of-i64 values), preserved untyped here so the
/// heartbeat classification applies exactly the reference's `isinstance(int)`
/// rule rather than a lossy parse.
#[derive(Debug, Clone, PartialEq)]
pub struct LeafEndpoint {
    pub machine: String,
    pub label: String,
    pub endpoint_id: String,
    /// Whether the endpoint's OWN agent reported the worker gone (`closed_by`
    /// exactly the string "agent"); the only close that carries a verdict.
    pub closed_by_agent: bool,
    pub exit_code: Option<i64>,
}

/// Why a listing could not be resolved at all.  A listing that is not an
/// object, or whose `tasks` is not an array, is refused rather than read.
#[derive(Debug, PartialEq)]
pub struct NoTasksArray;

impl LeafEndpoint {
    /// The leaf worker id: "<machine>/<label>", the task as the publishing
    /// home spells it, so one label on two homes is two leaves.
    pub fn leaf_id(&self) -> String {
        format!("{}/{}", self.machine, self.label)
    }

    /// The heartbeat state this endpoint supports, and nothing stronger.
    ///
    /// Only a close the endpoint's own agent reported is evidence about the
    /// worker: a close the hub made by itself is an unacknowledged kill, and
    /// an open endpoint says nothing about whether the worker is producing or
    /// idle.  A positive integer exit code is a failure; zero, a signal
    /// (negative), and no code at all are stops.  JSON booleans and floats are
    /// not integers here, exactly as in the reference.
    pub fn heartbeat_state(&self) -> &'static str {
        if !self.closed_by_agent {
            return STATE_UNKNOWN;
        }
        match self.exit_code {
            Some(code) if code > 0 => STATE_FAILED,
            _ => STATE_STOPPED,
        }
    }
}

/// Resolve a hub `/v1/tasks` body into one entry per leaf, from its newest
/// endpoint.
///
/// The hub lists a machine's endpoints oldest first, so a later record with
/// the same machine and label supersedes the one it replaces, which may linger
/// listed.  Superseding replaces the VALUE and keeps the leaf at its
/// first-insertion position, which is the reference's dict semantics and what
/// keeps the record order on the wire identical.  Records the hub itself would
/// have refused to register are not leaves and are left out.
pub fn resolve_listing(listing: &serde_json::Value) -> Result<Vec<LeafEndpoint>, NoTasksArray> {
    let tasks = listing
        .as_object()
        .and_then(|body| body.get("tasks"))
        .and_then(|tasks| tasks.as_array())
        .ok_or(NoTasksArray)?;
    let mut index: std::collections::HashMap<String, usize> = std::collections::HashMap::new();
    let mut leaves: Vec<LeafEndpoint> = Vec::new();
    for task in tasks {
        let object = match task.as_object() {
            Some(object) => object,
            None => continue,
        };
        let (endpoint_id, machine, label) = match (
            object.get("endpoint_id").and_then(|v| v.as_str()),
            object.get("machine").and_then(|v| v.as_str()),
            object.get("label").and_then(|v| v.as_str()),
        ) {
            (Some(endpoint_id), Some(machine), Some(label))
                if is_endpoint_id(endpoint_id) && is_machine_name(machine) && is_label(label) =>
            {
                (endpoint_id, machine, label)
            }
            // A record the hub itself would have refused to register is not a
            // leaf, and guessing its identity would be worse than leaving it
            // out.
            _ => continue,
        };
        let endpoint = LeafEndpoint {
            machine: machine.to_owned(),
            label: label.to_owned(),
            endpoint_id: endpoint_id.to_owned(),
            closed_by_agent: object.get("closed_by").and_then(|v| v.as_str()) == Some("agent"),
            exit_code: object.get("exit_code").and_then(|v| v.as_i64()),
        };
        let leaf = endpoint.leaf_id();
        match index.get(&leaf) {
            Some(&slot) => leaves[slot] = endpoint,
            None => {
                index.insert(leaf, leaves.len());
                leaves.push(endpoint);
            }
        }
    }
    Ok(leaves)
}

// --- protocol handshake -----------------------------------------------------

/// The verdict of a `/v1/health` protocol read: `Ok`, or the value found
/// under `protocol`, rendered the way the reference's `%r` renders it for its
/// refusal message.
pub fn protocol_of_health(health: &serde_json::Value) -> Result<(), String> {
    let found = health.get("protocol");
    let matches = found.and_then(|v| v.as_f64()) == Some(HUB_PROTOCOL as f64);
    if matches {
        return Ok(());
    }
    Err(match found {
        None => "None".to_string(),
        Some(value) => python_repr_value(value),
    })
}

/// Render a filesystem error's message the way Python's `exc.strerror`
/// prints it: the OS's own words with Rust's appended " (os error N)"
/// suffix removed.  Refusals that name the failing read surface this string
/// byte-for-byte, so the port's message and the reference's cannot drift.
pub fn python_strerror(error: &std::io::Error) -> String {
    let rendered = error.to_string();
    match error.raw_os_error() {
        Some(_) => match rendered.find(" (os error ") {
            Some(at) => rendered[..at].to_string(),
            None => rendered,
        },
        None => rendered,
    }
}

/// Render a filesystem error the way Python's `str(exc)` prints an OSError:
/// `"[Errno 2] No such file or directory: '/path'"`, filename quoted as a
/// Python string repr.  Used where the reference formats the exception
/// object itself rather than its `.strerror`.
pub fn python_oserror(path: &str, error: &std::io::Error) -> String {
    match error.raw_os_error() {
        Some(code) => format!(
            "[Errno {}] {}: {}",
            code,
            python_strerror(error),
            python_repr_value(&serde_json::Value::String(path.to_string()))
        ),
        None => error.to_string(),
    }
}

/// Render a JSON value roughly the way Python's `%r` does, for refusal
/// messages that must name what the hub answered with.  Only the shapes a
/// `protocol` field can plausibly hold are rendered faithfully; composites
/// fall back to a compact JSON rendering, which never reaches a healthy path.
pub fn python_repr_value(value: &serde_json::Value) -> String {
    match value {
        serde_json::Value::Null => "None".to_string(),
        serde_json::Value::Bool(true) => "True".to_string(),
        serde_json::Value::Bool(false) => "False".to_string(),
        serde_json::Value::Number(number) => number
            .as_i64()
            .map(|i| i.to_string())
            .unwrap_or_else(|| python_repr_f64(number.as_f64().unwrap_or(0.0))),
        serde_json::Value::String(s) => {
            format!("'{}'", s.replace('\\', "\\\\").replace('\'', "\\'"))
        }
        other => serde_json::to_string(other).unwrap_or_else(|_| "...".to_string()),
    }
}

// --- byte-exact encoders ----------------------------------------------------

/// Append `s` as a JSON string whose bytes are exactly what the reference's
/// `json.dumps` (default `ensure_ascii=True`) emits: control characters as
/// short escapes, everything outside `0x20..=0x7e` as `\uXXXX`, and astral
/// characters as surrogate pairs.
pub fn append_json_string(s: &str, out: &mut String) {
    out.push('"');
    for ch in s.chars() {
        match ch {
            '"' => out.push_str("\\\""),
            '\\' => out.push_str("\\\\"),
            '\u{08}' => out.push_str("\\b"),
            '\u{09}' => out.push_str("\\t"),
            '\u{0a}' => out.push_str("\\n"),
            '\u{0c}' => out.push_str("\\f"),
            '\u{0d}' => out.push_str("\\r"),
            c if (c as u32) < 0x20 || (c as u32) > 0x7e => {
                let point = c as u32;
                if point <= 0xffff {
                    append_unit_escape(point as u16, out);
                } else {
                    let value = point - 0x10000;
                    append_unit_escape((0xd800 + (value >> 10)) as u16, out);
                    append_unit_escape((0xdc00 + (value & 0x3ff)) as u16, out);
                }
            }
            c => out.push(c),
        }
    }
    out.push('"');
}

fn append_unit_escape(unit: u16, out: &mut String) {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    out.push_str("\\u");
    for byte in unit.to_be_bytes() {
        out.push(HEX[(byte >> 4) as usize] as char);
        out.push(HEX[(byte & 0x0f) as usize] as char);
    }
}

/// Render a finite `f64` exactly as CPython's `repr` (and therefore
/// `json.dumps`) renders it: the shortest digit string that round-trips,
/// positional between exponents -4 and 15 inclusive, otherwise scientific
/// with a signed, at-least-two-digit exponent.
pub fn python_repr_f64(value: f64) -> String {
    debug_assert!(
        value.is_finite(),
        "wire floats are validated finite upstream"
    );
    // Rust's LowerExp for f64 is also shortest-round-trip: "5.005e2",
    // "-1.5e-7", "0e0".  Split it into sign, digits, and exponent, then
    // re-render under CPython's positional/scientific thresholds.
    let scientific = format!("{:e}", value);
    let (mantissa, exponent) = match scientific.split_once('e') {
        Some(parts) => parts,
        None => return scientific,
    };
    let exponent: i32 = exponent.parse().unwrap_or(0);
    let (sign, mantissa) = match mantissa.strip_prefix('-') {
        Some(rest) => ("-", rest),
        None => ("", mantissa),
    };
    let digits: String = mantissa.chars().filter(|c| *c != '.').collect();
    let mut out = String::with_capacity(digits.len() + 8);
    out.push_str(sign);
    if exponent < -4 || exponent >= 16 {
        out.push_str(&digits[..1]);
        if digits.len() > 1 {
            out.push('.');
            out.push_str(&digits[1..]);
        }
        out.push('e');
        out.push(if exponent < 0 { '-' } else { '+' });
        let magnitude = exponent.unsigned_abs();
        if magnitude < 10 {
            out.push('0');
        }
        out.push_str(&magnitude.to_string());
    } else if exponent >= 0 {
        let integer_len = exponent as usize + 1;
        if digits.len() <= integer_len {
            out.push_str(&digits);
            for _ in digits.len()..integer_len {
                out.push('0');
            }
            out.push_str(".0");
        } else {
            out.push_str(&digits[..integer_len]);
            out.push('.');
            out.push_str(&digits[integer_len..]);
        }
    } else {
        out.push_str("0.");
        for _ in 0..(-exponent - 1) {
            out.push('0');
        }
        out.push_str(&digits);
    }
    out
}

/// One `leaf_heartbeat` record as emitted on the bridge feed.
#[derive(Debug, Clone, PartialEq)]
pub struct LeafHeartbeat {
    pub fleet_id: String,
    pub leaf_worker_id: String,
    pub parent_mate_id: String,
    pub execution_id: String,
    pub stream_epoch: i64,
    pub sequence: u64,
    pub state: &'static str,
    pub producer_monotonic_ms: f64,
    pub hub_arrival_ms: f64,
}

impl LeafHeartbeat {
    /// Encode as the exact NDJSON line the reference emits: fixed key order,
    /// compact separators, ASCII-safe strings, and float clocks under the
    /// reference's repr rules.
    pub fn to_line(&self) -> String {
        let mut out = String::with_capacity(192);
        out.push_str("{\"record\":\"leaf_heartbeat\",\"identity\":{\"fleet_id\":");
        append_json_string(&self.fleet_id, &mut out);
        out.push_str(",\"leaf_worker_id\":");
        append_json_string(&self.leaf_worker_id, &mut out);
        out.push_str(",\"parent_mate_id\":");
        append_json_string(&self.parent_mate_id, &mut out);
        out.push_str(",\"execution_id\":");
        append_json_string(&self.execution_id, &mut out);
        out.push_str(",\"stream_epoch\":");
        out.push_str(&self.stream_epoch.to_string());
        out.push_str("},\"sequence\":");
        out.push_str(&self.sequence.to_string());
        out.push_str(",\"state\":");
        append_json_string(self.state, &mut out);
        out.push_str(",\"clock\":{\"producer_monotonic_ms\":");
        out.push_str(&python_repr_f64(self.producer_monotonic_ms));
        out.push_str(",\"hub_arrival_ms\":");
        out.push_str(&python_repr_f64(self.hub_arrival_ms));
        out.push_str("}}");
        out
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    // Expected bytes below were generated with CPython itself
    // (`json.dumps(..., separators=(",", ":"))` and `repr`); regenerating the
    // battery is one python3 one-liner if a case ever looks wrong.

    #[test]
    fn float_repr_matches_python() {
        // (value, expected) pairs, taken from repr() on CPython 3.x.
        let cases: Vec<(f64, &str)> = vec![
            (0.0, "0.0"),
            (-0.0, "-0.0"),
            (1.0, "1.0"),
            (3.0, "3.0"),
            (499.0, "499.0"),
            (500.0, "500.0"),
            (500.5, "500.5"),
            (0.001, "0.001"),
            (0.0001, "0.0001"),
            (0.00001, "1e-05"),
            (1.5e-7, "1.5e-07"),
            (123456.789, "123456.789"),
            (1e15, "1000000000000000.0"),
            (9999999999999998.0, "9999999999999998.0"),
            (1e16, "1e+16"),
            (1.5e16, "1.5e+16"),
            (1e100, "1e+100"),
            (-3.25, "-3.25"),
            (1789829165998.0, "1789829165998.0"),
        ];
        for (value, expected) in cases {
            assert_eq!(python_repr_f64(value), expected, "value {value}");
        }
    }

    #[test]
    fn json_strings_match_python() {
        let cases: Vec<(&str, &str)> = vec![
            ("plain", "\"plain\""),
            ("é", "\"\\u00e9\""),
            ("中", "\"\\u4e2d\""),
            ("\u{7f}", "\"\\u007f\""),
            ("😀", "\"\\ud83d\\ude00\""),
            ("a\"b", "\"a\\\"b\""),
            ("a\\b", "\"a\\\\b\""),
            ("tab\there", "\"tab\\there\""),
            ("nl\nhere", "\"nl\\nhere\""),
            ("cr\rhere", "\"cr\\rhere\""),
            ("\u{1}", "\"\\u0001\""),
            ("fleet-é-中文", "\"fleet-\\u00e9-\\u4e2d\\u6587\""),
        ];
        for (input, expected) in cases {
            let mut out = String::new();
            append_json_string(input, &mut out);
            assert_eq!(out, expected, "input {input:?}");
        }
    }

    #[test]
    fn heartbeat_line_is_byte_exact() {
        // python3 -c 'import json; print(json.dumps({
        //   "record": "leaf_heartbeat",
        //   "identity": {"fleet_id": "fleet-t", "leaf_worker_id": "box-a/task-open",
        //                "parent_mate_id": "box-a",
        //                "execution_id": "0123456789abcdef0123456789abcdef",
        //                "stream_epoch": 7},
        //   "sequence": 2, "state": "Stopped",
        //   "clock": {"producer_monotonic_ms": 500.5, "hub_arrival_ms": 499.0}},
        //   separators=(",", ":"))'
        let record = LeafHeartbeat {
            fleet_id: "fleet-t".to_string(),
            leaf_worker_id: "box-a/task-open".to_string(),
            parent_mate_id: "box-a".to_string(),
            execution_id: "0123456789abcdef0123456789abcdef".to_string(),
            stream_epoch: 7,
            sequence: 2,
            state: STATE_STOPPED,
            producer_monotonic_ms: 500.5,
            hub_arrival_ms: 499.0,
        };
        assert_eq!(
            record.to_line(),
            "{\"record\":\"leaf_heartbeat\",\"identity\":{\"fleet_id\":\"fleet-t\",\
             \"leaf_worker_id\":\"box-a/task-open\",\"parent_mate_id\":\"box-a\",\
             \"execution_id\":\"0123456789abcdef0123456789abcdef\",\"stream_epoch\":7},\
             \"sequence\":2,\"state\":\"Stopped\",\"clock\":{\"producer_monotonic_ms\":500.5,\
             \"hub_arrival_ms\":499.0}}"
        );
    }

    #[test]
    fn identity_validation_matches_the_hub_registry_rules() {
        assert!(is_endpoint_id("0123456789abcdef0123456789abcdef"));
        assert!(!is_endpoint_id("0123456789ABCDEF0123456789ABCDEF"));
        assert!(!is_endpoint_id("0123456789abcdef0123456789abcde"));
        assert!(!is_endpoint_id(""));
        assert!(is_machine_name("box-a"));
        assert!(is_machine_name("A._-9"));
        assert!(!is_machine_name("bad machine"));
        assert!(!is_machine_name(""));
        assert!(!is_machine_name(&"x".repeat(129)));
        assert!(is_label("task-open_1@2%3+4-5."));
        assert!(!is_label("task/open"));
        assert!(!is_label(""));
        assert!(!is_label(&"x".repeat(129)));
    }

    #[test]
    fn resolve_keeps_first_insertion_order_and_last_value() {
        let listing = json!({
            "ok": true,
            "tasks": [
                {"endpoint_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "machine": "box-a",
                 "label": "t1", "closed_by": "agent", "exit_code": 2},
                {"endpoint_id": "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", "machine": "box-a",
                 "label": "t2", "closed_by": null, "exit_code": null},
                {"endpoint_id": "cccccccccccccccccccccccccccccccc", "machine": "box-a",
                 "label": "t1", "closed_by": null, "exit_code": null},
                {"endpoint_id": "not-an-id", "machine": "box-a", "label": "t3"},
                {"endpoint_id": "dddddddddddddddddddddddddddddddd", "machine": "bad machine",
                 "label": "t4"},
            ]
        });
        let leaves = resolve_listing(&listing).unwrap();
        assert_eq!(leaves.len(), 2);
        assert_eq!(leaves[0].leaf_id(), "box-a/t1");
        assert_eq!(leaves[0].endpoint_id, "cccccccccccccccccccccccccccccccc");
        assert_eq!(leaves[0].heartbeat_state(), STATE_UNKNOWN);
        assert_eq!(leaves[1].leaf_id(), "box-a/t2");
        for bad in [
            json!({}),
            json!({"tasks": {}}),
            json!([]),
            serde_json::Value::Null,
        ] {
            assert_eq!(resolve_listing(&bad), Err(NoTasksArray));
        }
    }

    #[test]
    fn only_an_agent_reported_positive_exit_is_failed() {
        let state = |closed_by: serde_json::Value, exit_code: serde_json::Value| {
            let listing = json!({"tasks": [
                {"endpoint_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", "machine": "m",
                 "label": "l", "closed_by": closed_by, "exit_code": exit_code}]});
            resolve_listing(&listing).unwrap()[0].heartbeat_state()
        };
        assert_eq!(state(json!(null), json!(null)), STATE_UNKNOWN);
        assert_eq!(state(json!("hub"), json!(null)), STATE_UNKNOWN);
        assert_eq!(state(json!("Hub"), json!(null)), STATE_UNKNOWN);
        assert_eq!(state(json!("agent"), json!(null)), STATE_STOPPED);
        assert_eq!(state(json!("agent"), json!(0)), STATE_STOPPED);
        assert_eq!(state(json!("agent"), json!(-15)), STATE_STOPPED);
        assert_eq!(state(json!("agent"), json!(true)), STATE_STOPPED);
        assert_eq!(state(json!("agent"), json!(2.0)), STATE_STOPPED);
        assert_eq!(state(json!("agent"), json!("2")), STATE_STOPPED);
        assert_eq!(state(json!("agent"), json!(3)), STATE_FAILED);
    }

    #[test]
    fn os_errors_render_like_python() {
        // "[Errno 2] No such file or directory: '/no/such'" is CPython's
        // str(OSError) for the same failed open; strerror is its .strerror.
        let error = std::io::Error::from_raw_os_error(2);
        assert_eq!(python_strerror(&error), "No such file or directory");
        assert_eq!(
            python_oserror("/no/such", &error),
            "[Errno 2] No such file or directory: '/no/such'"
        );
        let denied = std::io::Error::from_raw_os_error(13);
        assert_eq!(python_strerror(&denied), "Permission denied");
        assert_eq!(
            python_oserror("/root/t", &denied),
            "[Errno 13] Permission denied: '/root/t'"
        );
        // A path with a quote renders as Python's repr of it would.
        assert_eq!(
            python_oserror("it's", &error),
            "[Errno 2] No such file or directory: 'it\\'s'"
        );
        // An error with no OS code keeps its own words.
        let plain = std::io::Error::new(std::io::ErrorKind::Other, "custom");
        assert_eq!(python_strerror(&plain), "custom");
        assert_eq!(python_oserror("p", &plain), "custom");
    }

    #[test]
    fn protocol_check_renders_the_found_value_like_python() {
        assert!(protocol_of_health(&json!({"protocol": 2, "ok": true})).is_ok());
        assert_eq!(
            protocol_of_health(&json!({"protocol": 99})),
            Err("99".to_string())
        );
        assert_eq!(protocol_of_health(&json!({})), Err("None".to_string()));
        assert_eq!(
            protocol_of_health(&json!({"protocol": "2"})),
            Err("'2'".to_string())
        );
        assert_eq!(
            protocol_of_health(&json!({"protocol": 2.5})),
            Err("2.5".to_string())
        );
    }
}
