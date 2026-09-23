//! The Phase 2 comparison harness: this home's task records against the
//! adapter's rendered states against fm-crew-state.sh, one tab-separated row
//! per task, exit 1 when any row is a conflict or missing.

use std::collections::HashMap;
use std::io::Write;
use std::path::{Path, PathBuf};

use fm_stream_wire::{is_endpoint_id, python_repr_value};

use crate::bridge::{Bridge, Clock};
use crate::commands::{classify_stdout, health_checked, read_token, tick, EmitOutcome, Failure};
use crate::hub::HubClient;

/// Read a `state/<task>.meta` file: first occurrence of each `key=value`
/// wins, lines without `=` are ignored, unreadable files read as empty.
pub fn read_meta(path: &Path) -> HashMap<String, String> {
    let mut fields = HashMap::new();
    let Ok(bytes) = std::fs::read(path) else {
        return fields;
    };
    // The reference decodes with errors="replace"; lossy decoding matches.
    let text = String::from_utf8_lossy(&bytes);
    for raw in text.split('\n') {
        // The reference iterates with universal newlines, so a trailing \r
        // belongs to the line separator, not the value.
        let line = raw.strip_suffix('\r').unwrap_or(raw);
        if let Some((key, value)) = line.split_once('=') {
            fields
                .entry(key.to_string())
                .or_insert_with(|| value.to_string());
        }
    }
    fields
}

/// (task id, endpoint id) for every stream-backed task record in
/// `<home>/state/*.meta`, sorted by file name like the reference's listdir.
pub fn stream_tasks(home: &Path) -> Result<Vec<(String, String)>, Failure> {
    let state_dir = home.join("state");
    let entries = std::fs::read_dir(&state_dir).map_err(|error| {
        Failure::Refused(format!(
            "cannot read {}: {}",
            state_dir.display(),
            fm_stream_wire::python_strerror(&error)
        ))
    })?;
    let mut names: Vec<String> = entries
        .filter_map(|entry| entry.ok())
        .map(|entry| entry.file_name().to_string_lossy().into_owned())
        .collect();
    names.sort();
    let mut tasks = Vec::new();
    for name in names {
        if !name.ends_with(".meta") || name.starts_with('.') {
            continue;
        }
        let meta = read_meta(&state_dir.join(&name));
        let backend = meta.get("backend").map(String::as_str);
        let endpoint_id = meta
            .get("stream_endpoint_id")
            .map(String::as_str)
            .unwrap_or("");
        if backend != Some("stream") || !is_endpoint_id(endpoint_id) {
            continue;
        }
        tasks.push((
            name[..name.len() - ".meta".len()].to_string(),
            endpoint_id.to_string(),
        ));
    }
    Ok(tasks)
}

/// execution id -> the state its last heartbeat rendered, from a recorded
/// NDJSON feed.  Records that are not leaf heartbeats, or carry no string
/// execution id, cannot be keyed and are skipped.
///
/// The feed is JSON, not typed records, because a recorded session may hold
/// anything; the live path below only ever holds this bridge's own records
/// and reads them structurally.
pub fn rendered_states(records: &[serde_json::Value]) -> HashMap<String, serde_json::Value> {
    let mut states: HashMap<String, serde_json::Value> = HashMap::new();
    for record in records {
        if record.get("record") != Some(&serde_json::json!("leaf_heartbeat")) {
            continue;
        }
        let Some(execution_id) = record
            .get("identity")
            .and_then(|identity| identity.get("execution_id"))
            .and_then(serde_json::Value::as_str)
        else {
            continue;
        };
        states.insert(
            execution_id.to_string(),
            record
                .get("state")
                .cloned()
                .unwrap_or(serde_json::Value::Null),
        );
    }
    states
}

/// The live twin of `rendered_states`: this bridge's own records, read
/// structurally instead of re-parsed.
fn rendered_states_live(
    records: &[fm_stream_wire::LeafHeartbeat],
) -> HashMap<String, serde_json::Value> {
    records
        .iter()
        .map(|record| {
            (
                record.execution_id.clone(),
                serde_json::Value::String(record.state.to_string()),
            )
        })
        .collect()
}

/// The verdict for one row: `missing` when the endpoint is absent from the
/// feed, `no-verdict` when the adapter claims nothing (Unknown), `conflict`
/// when the adapter says the worker stopped while the pane-sourced crew
/// state says it is working or parked, `consistent` otherwise.
pub fn verdict(bridge_state: Option<&serde_json::Value>, crew: &str, source: &str) -> &'static str {
    let Some(state) = bridge_state.filter(|value| !value.is_null()) else {
        return "missing";
    };
    if state == &serde_json::json!("Unknown") {
        return "no-verdict";
    }
    if (state == &serde_json::json!("Stopped") || state == &serde_json::json!("Failed"))
        && source == "pane"
        && matches!(crew, "working" | "parked")
    {
        return "conflict";
    }
    "consistent"
}

/// Render the bridge-state cell the way the reference prints it: absent or
/// null renders as "-", everything else as itself.
pub fn display_state(bridge_state: Option<&serde_json::Value>) -> String {
    match bridge_state {
        None | Some(serde_json::Value::Null) => "-".to_string(),
        Some(serde_json::Value::String(state)) if state.is_empty() => "-".to_string(),
        Some(serde_json::Value::String(state)) => state.clone(),
        Some(other) => python_repr_value(other),
    }
}

/// (state, source) from one fm-crew-state.sh line, or ("unreadable",
/// "none").  The first line of stdout must read
/// `state: <word> · source: <word>`; anything else, a failure, or a hang
/// past 120 s reads as unreadable rather than guessed.
pub async fn crew_state(command: &str, task: &str, home: &Path) -> (String, String) {
    let child = match tokio::process::Command::new(command)
        .arg(task)
        .env("FM_HOME", home)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .kill_on_drop(true)
        .spawn()
    {
        Ok(child) => child,
        Err(_) => return ("unreadable".to_string(), "none".to_string()),
    };
    let collected = tokio::time::timeout(
        std::time::Duration::from_secs(120),
        child.wait_with_output(),
    )
    .await;
    let output = match collected {
        Ok(Ok(output)) => output,
        // A hang past the budget reads as unreadable; dropping the collect
        // future kills the child, as the reference's subprocess timeout does.
        _ => return ("unreadable".to_string(), "none".to_string()),
    };
    if !output.status.success() {
        return ("unreadable".to_string(), "none".to_string());
    }
    match parse_crew_line(&String::from_utf8_lossy(&output.stdout)) {
        Some((state, source)) => (state, source),
        None => ("unreadable".to_string(), "none".to_string()),
    }
}

/// The reference matches `^state: (\S+) · source: (\S+)`: a maximal non-space
/// run, the literal middle-dot separator, another maximal non-space run, and
/// no anchor at the end of the line.
pub fn parse_crew_line(stdout: &str) -> Option<(String, String)> {
    let rest = stdout.trim().strip_prefix("state: ")?;
    let (state, after) = rest.split_once(' ')?;
    if state.is_empty() {
        return None;
    }
    let tail = after.strip_prefix("· source: ")?;
    let source = tail.split_whitespace().next()?;
    Some((state.to_string(), source.to_string()))
}

/// The default home: FM_HOME, else the directory above this executable, the
/// same "beside bin/" shape the reference's own script location gives it.
fn default_home() -> PathBuf {
    std::env::current_exe()
        .ok()
        .and_then(|exe| exe.parent().map(Path::to_path_buf))
        .and_then(|dir| dir.parent().map(Path::to_path_buf))
        .unwrap_or_else(|| PathBuf::from("."))
}

pub async fn compare(
    fleet_id: String,
    hub: Option<String>,
    token_file: Option<String>,
    feed: Option<String>,
    home: Option<String>,
    crew_state_command: Option<String>,
) -> Result<i32, Failure> {
    let home = home
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("FM_HOME").map(PathBuf::from))
        .unwrap_or_else(default_home);
    let command = crew_state_command.unwrap_or_else(|| {
        std::env::current_exe()
            .ok()
            .and_then(|exe| exe.parent().map(|dir| dir.join("fm-crew-state.sh")))
            .unwrap_or_else(|| PathBuf::from("fm-crew-state.sh"))
            .to_string_lossy()
            .into_owned()
    });
    let states = if let Some(feed) = feed {
        let bytes = std::fs::read_to_string(&feed).map_err(|error| {
            Failure::Refused(format!(
                "cannot read the feed {feed}: {}",
                fm_stream_wire::python_oserror(&feed, &error)
            ))
        })?;
        let mut records = Vec::new();
        for line in bytes.split('\n') {
            let line = line.strip_suffix('\r').unwrap_or(line);
            if line.trim().is_empty() {
                continue;
            }
            let parsed = match serde_json::from_str::<serde_json::Value>(line) {
                Ok(value) => value,
                Err(error) => {
                    // The reference surfaces Python's own parse errors here
                    // (`cannot read the feed ...: Expecting value: ...`),
                    // so the wire scanner renders them, with its re-parse
                    // carrying the extensions Python accepts.
                    if let Some(message) = fm_stream_wire::python_json::python_json_error(line) {
                        return Err(Failure::Refused(format!(
                            "cannot read the feed {feed}: {message}"
                        )));
                    }
                    fm_stream_wire::python_json::python_reparse(line).map_err(|_| {
                        Failure::Refused(format!("cannot read the feed {feed}: {error}"))
                    })?
                }
            };
            records.push(parsed);
        }
        rendered_states(&records)
    } else if let (Some(hub), Some(token_file)) = (&hub, &token_file) {
        let token = read_token(token_file).map_err(|error| Failure::Refused(error.0))?;
        let client = HubClient::new(hub, &token);
        let mut bridge = Bridge::new(&fleet_id, 0);
        // A live comparison takes one snapshot; an unreachable hub is a
        // refusal here, not a retry and not a quiet exit.
        let refuse_unreachable = |failure: Failure| match failure {
            Failure::Unreachable(problem) => Failure::Refused(problem),
            other => other,
        };
        health_checked(&client).await.map_err(refuse_unreachable)?;
        let records = tick(&client, &mut bridge, &Clock::new())
            .await
            .map_err(refuse_unreachable)?;
        rendered_states_live(&records)
    } else {
        return Err(Failure::Refused(
            "compare needs --feed FILE, or --hub and --token-file".to_string(),
        ));
    };
    let tasks = stream_tasks(&home)?;
    let mut failed = false;
    let stdout = std::io::stdout();
    let mut stdout = stdout.lock();
    if classify_stdout(writeln!(
        stdout,
        "task\texecution_id\tbridge_state\tcrew_state\tcrew_source\tverdict"
    ))? == EmitOutcome::PipeClosed
    {
        return Ok(0);
    }
    for (task, endpoint_id) in tasks {
        let bridge_state = states.get(&endpoint_id);
        let (crew, source) = crew_state(&command, &task, &home).await;
        let result = verdict(bridge_state, &crew, &source);
        failed = failed || matches!(result, "conflict" | "missing");
        if classify_stdout(writeln!(
            stdout,
            "{}\t{}\t{}\t{}\t{}\t{}",
            task,
            endpoint_id,
            display_state(bridge_state),
            crew,
            source,
            result
        ))? == EmitOutcome::PipeClosed
        {
            return Ok(0);
        }
    }
    if classify_stdout(stdout.flush())? == EmitOutcome::PipeClosed {
        return Ok(0);
    }
    Ok(if failed { 1 } else { 0 })
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn tmp(name: &str) -> PathBuf {
        let dir =
            std::env::temp_dir().join(format!("fm-bridge-compare-{name}-{}", std::process::id()));
        std::fs::remove_dir_all(&dir).ok();
        std::fs::create_dir_all(&dir).unwrap();
        dir
    }

    #[test]
    fn meta_first_occurrence_wins_and_requires_separator() {
        let dir = tmp("meta");
        let file = dir.join("t.meta");
        std::fs::write(&file, "backend=stream\nx=1\nx=2\nnoseparator\n=y\nempty=\n").unwrap();
        let meta = read_meta(&file);
        assert_eq!(meta.get("backend").map(String::as_str), Some("stream"));
        assert_eq!(meta.get("x").map(String::as_str), Some("1"));
        assert!(!meta.contains_key("noseparator"));
        assert_eq!(meta.get("").map(String::as_str), Some("y"));
        assert_eq!(meta.get("empty").map(String::as_str), Some(""));
        assert!(read_meta(&dir.join("missing.meta")).is_empty());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn stream_tasks_filters_and_sorts() {
        let home = tmp("tasks");
        let state = home.join("state");
        std::fs::create_dir_all(&state).unwrap();
        std::fs::write(
            state.join("b.meta"),
            "backend=stream\nstream_endpoint_id=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\n",
        )
        .unwrap();
        std::fs::write(
            state.join("a.meta"),
            "backend=stream\nstream_endpoint_id=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb\n",
        )
        .unwrap();
        std::fs::write(state.join("c.meta"), "backend=tmux\n").unwrap();
        std::fs::write(
            state.join(".d.meta"),
            "backend=stream\nstream_endpoint_id=cccccccccccccccccccccccccccccccc\n",
        )
        .unwrap();
        std::fs::write(state.join("e.txt"), "backend=stream\n").unwrap();
        let tasks = stream_tasks(&home).unwrap();
        assert_eq!(
            tasks,
            vec![
                (
                    "a".to_string(),
                    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb".to_string()
                ),
                (
                    "b".to_string(),
                    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa".to_string()
                )
            ]
        );
        std::fs::remove_dir_all(&home).ok();
    }

    #[test]
    fn rendered_states_last_record_wins() {
        let records = vec![
            json!({"record": "leaf_heartbeat", "identity": {"execution_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, "state": "Unknown"}),
            json!({"record": "other"}),
            json!({"record": "leaf_heartbeat", "identity": {"execution_id": "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}, "state": "Failed"}),
        ];
        let states = rendered_states(&records);
        assert_eq!(
            states.get("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"),
            Some(&json!("Failed"))
        );
    }

    #[test]
    fn verdict_table_matches_the_reference() {
        let unknown = Some(&json!("Unknown"));
        let stopped = Some(&json!("Stopped"));
        let failed = Some(&json!("Failed"));
        assert_eq!(verdict(None, "working", "pane"), "missing");
        assert_eq!(verdict(unknown, "working", "pane"), "no-verdict");
        assert_eq!(verdict(stopped, "working", "pane"), "conflict");
        assert_eq!(verdict(failed, "parked", "pane"), "conflict");
        assert_eq!(verdict(stopped, "working", "stream"), "consistent");
        assert_eq!(verdict(stopped, "done", "pane"), "consistent");
        assert_eq!(verdict(stopped, "unreadable", "none"), "consistent");
        assert_eq!(verdict(unknown, "unreadable", "none"), "no-verdict");
        // A stored null is indistinguishable from absent.
        assert_eq!(verdict(Some(&json!(null)), "working", "pane"), "missing");
        assert_eq!(display_state(Some(&json!(null))), "-");
        assert_eq!(display_state(None), "-");
        assert_eq!(display_state(unknown), "Unknown");
    }

    #[test]
    fn crew_line_parsing_is_the_regex() {
        assert_eq!(
            parse_crew_line("state: working · source: pane\n"),
            Some(("working".to_string(), "pane".to_string()))
        );
        assert_eq!(
            parse_crew_line("state: working · source: pane extra words"),
            Some(("working".to_string(), "pane".to_string()))
        );
        assert_eq!(
            parse_crew_line("  state: working · source: pane"),
            Some(("working".to_string(), "pane".to_string()))
        );
        assert_eq!(parse_crew_line("state: working"), None);
        assert_eq!(parse_crew_line("state:  · source: pane"), None);
        assert_eq!(parse_crew_line("state: working source: pane"), None);
        assert_eq!(parse_crew_line("state: a b · source: pane"), None);
        assert_eq!(parse_crew_line("state: working · source: "), None);
        assert_eq!(parse_crew_line(""), None);
    }
}
