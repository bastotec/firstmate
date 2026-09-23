//! The serve, snapshot, and translate commands, ported command-for-command
//! from the reference: same validation order, same refusal classes, same
//! retry and recovery behaviour on the serve path.

use std::io::{BufRead, Write};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fm_stream_wire::{protocol_of_health, HUB_PROTOCOL};

use crate::bridge::{Bridge, Clock};
use crate::cli::Command;
use crate::hub::{BridgeError, GetOutcome, HubClient};

/// How a command ends.  `Refused` is the reference's BridgeError class
/// (exit 2); `Unreachable` exits 1 from snapshot; `Stdio` is a broken
/// standard stream other than a closed pipe (exit 1).
#[derive(Debug)]
pub enum Failure {
    Refused(String),
    Unreachable(String),
    Stdio(String),
}

/// The adapter's generation, if the operator did not pin one: the start time
/// in whole milliseconds since the Unix epoch, so a restart moves forward as
/// long as the host clock does.
pub fn default_epoch() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|elapsed| elapsed.as_millis() as i64)
        .unwrap_or(0)
}

/// Read the first non-blank line of a token file.  The unreadable-file
/// refusal names the OS's own words, the reference's `exc.strerror`, so the
/// two messages are byte-identical.
pub fn read_token(path: &str) -> Result<String, BridgeError> {
    let bytes = std::fs::read(path).map_err(|error| {
        BridgeError(format!(
            "cannot read the token file {path}: {}",
            fm_stream_wire::python_strerror(&error)
        ))
    })?;
    let text = String::from_utf8(bytes).map_err(|_| {
        BridgeError(format!(
            "cannot read the token file {path}: not valid UTF-8"
        ))
    })?;
    for line in text.lines() {
        let line = line.trim();
        if !line.is_empty() {
            return Ok(line.to_string());
        }
    }
    Err(BridgeError(format!("the token file {path} holds no token")))
}

/// Write records and flush once, like the reference's emit.  A closed reader
/// is not an error: whoever was reading the feed went away, and that ends
/// the feed (the caller exits 0).
pub fn emit(records: &[fm_stream_wire::LeafHeartbeat]) -> std::io::Result<()> {
    let mut stdout = std::io::stdout().lock();
    for record in records {
        writeln!(stdout, "{}", record.to_line())?;
    }
    stdout.flush()
}

/// One GET, protocol-checked when the caller asks.  Shared by snapshot and
/// compare; serve inlines its own loop because its retry behaviour differs.
pub(crate) async fn health_checked(client: &HubClient) -> Result<serde_json::Value, Failure> {
    match client.get("/v1/health").await {
        GetOutcome::Answer(health) => {
            if let Err(found) = protocol_of_health(&health) {
                return Err(Failure::Refused(format!(
                    "the hub at {} speaks protocol {}; this bridge reads protocol {}",
                    client.url(),
                    found,
                    HUB_PROTOCOL
                )));
            }
            let current = health
                .get("capabilities")
                .and_then(|v| v.as_array())
                .is_some_and(|values| {
                    values
                        .iter()
                        .any(|v| v.as_str() == Some("current_execution"))
                });
            if !current {
                return Err(Failure::Refused(format!(
                    "the hub at {} does not advertise the current_execution capability; restart or upgrade the hub before starting this bridge",
                    client.url()
                )));
            }
            Ok(health)
        }
        GetOutcome::Refused(error) => Err(Failure::Refused(error.0)),
        GetOutcome::Unreachable(error) => Err(Failure::Unreachable(error.0)),
    }
}

/// One poll: fetch the listing, stamp both clocks, translate.  The producer
/// clock is taken after the arrival clock, exactly as the reference does.
pub(crate) async fn tick(
    client: &HubClient,
    bridge: &mut Bridge,
    clock: &Clock,
) -> Result<Vec<fm_stream_wire::LeafHeartbeat>, Failure> {
    match client.get("/v1/tasks").await {
        GetOutcome::Answer(listing) => {
            let received = clock.ms();
            bridge
                .translate(&listing, clock.ms(), received)
                .map_err(|error| Failure::Refused(error.0))
        }
        GetOutcome::Refused(error) => Err(Failure::Refused(error.0)),
        GetOutcome::Unreachable(error) => Err(Failure::Unreachable(error.0)),
    }
}

fn is_valid_interval(interval_ms: i64) -> bool {
    // A tick at or past the Bridge's 1500 ms stale threshold cannot keep a
    // healthy leaf fresh, so it is refused rather than flickered.
    (crate::cli::MIN_INTERVAL_MS..crate::cli::BRIDGE_STALE_MS).contains(&interval_ms)
}

pub async fn serve(
    hub: String,
    token_file: String,
    fleet_id: String,
    epoch: Option<i64>,
    interval_ms: i64,
) -> Result<i32, Failure> {
    if !is_valid_interval(interval_ms) {
        return Err(Failure::Refused(format!(
            "--interval-ms must be at least {} and under {}, the Bridge's stale threshold",
            crate::cli::MIN_INTERVAL_MS,
            crate::cli::BRIDGE_STALE_MS
        )));
    }
    let token = read_token(&token_file).map_err(|error| Failure::Refused(error.0))?;
    let client = HubClient::new(&hub, &token);
    let mut bridge = Bridge::new(&fleet_id, epoch.unwrap_or_else(default_epoch));
    let clock = Clock::new();
    // The protocol is checked before the first record and again whenever the
    // hub comes back, because a hub that went away may return upgraded.
    let mut verified = false;
    let mut last_problem = String::new();
    loop {
        let started = std::time::Instant::now();
        let attempt: Result<Vec<fm_stream_wire::LeafHeartbeat>, Failure> = async {
            if !verified {
                health_checked(&client).await?;
                verified = true;
            }
            tick(&client, &mut bridge, &clock).await
        }
        .await;
        match attempt {
            Ok(records) => {
                if !last_problem.is_empty() {
                    eprintln!(
                        "fm-stream-bridge: the hub at {} answers again",
                        client.url()
                    );
                    last_problem.clear();
                }
                if emit_records(&records)? == EmitOutcome::PipeClosed {
                    return Ok(0);
                }
            }
            Err(Failure::Unreachable(problem)) => {
                verified = false;
                if problem != last_problem {
                    eprintln!("fm-stream-bridge: {problem}; emitting nothing until it answers");
                    last_problem = problem;
                }
            }
            Err(other) => return Err(other),
        }
        let remaining = interval_ms as f64 / 1000.0 - started.elapsed().as_secs_f64();
        if remaining > 0.0 {
            tokio::time::sleep(Duration::from_secs_f64(remaining)).await;
        }
    }
}

/// What happened at emit time: records written, or the reader gone.
#[derive(Debug, PartialEq)]
pub(crate) enum EmitOutcome {
    Done,
    PipeClosed,
}

fn emit_records(records: &[fm_stream_wire::LeafHeartbeat]) -> Result<EmitOutcome, Failure> {
    classify_stdout(emit(records))
}

pub(crate) fn classify_stdout(result: std::io::Result<()>) -> Result<EmitOutcome, Failure> {
    match result {
        Ok(()) => Ok(EmitOutcome::Done),
        // Whoever was reading the feed going away ends the feed, not this
        // process: report it and let the caller exit success.
        Err(error) if error.kind() == std::io::ErrorKind::BrokenPipe => Ok(EmitOutcome::PipeClosed),
        Err(error) => Err(Failure::Stdio(error.to_string())),
    }
}

pub async fn snapshot(
    hub: String,
    token_file: String,
    fleet_id: String,
    epoch: Option<i64>,
) -> Result<i32, Failure> {
    let token = read_token(&token_file).map_err(|error| Failure::Refused(error.0))?;
    let client = HubClient::new(&hub, &token);
    let mut bridge = Bridge::new(&fleet_id, epoch.unwrap_or_else(default_epoch));
    let outcome = async {
        health_checked(&client).await?;
        let records = tick(&client, &mut bridge, &Clock::new()).await?;
        emit_records(&records)
    }
    .await;
    match outcome {
        // A closed reader ends the feed successfully for snapshot too.
        Ok(EmitOutcome::Done) | Ok(EmitOutcome::PipeClosed) => Ok(0),
        Err(Failure::Unreachable(problem)) => {
            eprintln!("fm-stream-bridge: {problem}");
            Ok(1)
        }
        Err(other) => Err(other),
    }
}

pub async fn translate(fleet_id: String, epoch: Option<i64>) -> Result<i32, Failure> {
    // Recorded replay: epoch defaults to 0, not the start time, so a session
    // records replay deterministically.
    let mut bridge = Bridge::new(&fleet_id, epoch.unwrap_or(0));
    let stdin = std::io::stdin();
    let mut lines = stdin.lock().lines();
    let mut number = 0usize;
    while let Some(line) = lines.next() {
        number += 1;
        let raw = line.map_err(|error| Failure::Stdio(error.to_string()))?;
        let trimmed = raw.trim();
        if trimmed.is_empty() {
            continue;
        }
        let entry: serde_json::Value = match serde_json::from_str(trimmed) {
            Ok(value) => value,
            Err(error) => {
                // Python's parser accepts more than serde's (NaN, Infinity,
                // lone surrogate escapes) and words its refusals differently:
                // the wire scanner renders its exact message, and its
                // re-parse carries the extensions it accepts.
                if let Some(message) = fm_stream_wire::python_json::python_json_error(trimmed) {
                    return Err(Failure::Refused(format!(
                        "line {number} is not JSON: {message}"
                    )));
                }
                fm_stream_wire::python_json::python_reparse(trimmed)
                    .map_err(|_| Failure::Refused(format!("line {number} is not JSON: {error}")))?
            }
        };
        if !entry.is_object() {
            return Err(Failure::Refused(format!(
                "line {number} is not a JSON object"
            )));
        }
        let at_ms = entry.get("at_ms");
        let received_ms = entry.get("received_ms").or(at_ms);
        // at_ms is validated before received_ms, in the reference's order; a
        // JSON bool is not a number here, exactly as in its isinstance check.
        let validate = |name: &str, value: Option<&serde_json::Value>| -> Result<f64, Failure> {
            match value.and_then(serde_json::Value::as_f64) {
                Some(value) if value.is_finite() && value >= 0.0 => Ok(value),
                _ => Err(Failure::Refused(format!(
                    "line {number}: {name} must be a finite, non-negative number"
                ))),
            }
        };
        let at = validate("at_ms", at_ms)?;
        let received = validate("received_ms", received_ms)?;
        if received > at {
            return Err(Failure::Refused(format!(
                "line {number}: received_ms is later than at_ms"
            )));
        }
        let listing = entry
            .get("listing")
            .cloned()
            .unwrap_or(serde_json::Value::Null);
        let records = bridge
            .translate(&listing, at, received)
            .map_err(|error| Failure::Refused(format!("line {number}: {}", error.0)))?;
        if emit_records(&records)? == EmitOutcome::PipeClosed {
            return Ok(0);
        }
    }
    Ok(0)
}

pub async fn run(command: Command) -> Result<i32, Failure> {
    match command {
        Command::Serve {
            hub,
            token_file,
            fleet_id,
            epoch,
            interval_ms,
        } => serve(hub, token_file, fleet_id, epoch, interval_ms).await,
        Command::Snapshot {
            hub,
            token_file,
            fleet_id,
            epoch,
        } => snapshot(hub, token_file, fleet_id, epoch).await,
        Command::Translate { fleet_id, epoch } => translate(fleet_id, epoch).await,
        Command::Compare {
            hub,
            token_file,
            fleet_id,
            feed,
            home,
            crew_state,
        } => crate::compare::compare(fleet_id, hub, token_file, feed, home, crew_state).await,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn interval_bounds_match_the_stale_threshold() {
        assert!(!is_valid_interval(49));
        assert!(is_valid_interval(50));
        assert!(is_valid_interval(500));
        assert!(is_valid_interval(1499));
        assert!(!is_valid_interval(1500));
        assert!(!is_valid_interval(5000));
    }

    #[test]
    fn token_reading_takes_the_first_non_blank_line() {
        let dir =
            std::env::temp_dir().join(format!("fm-stream-bridge-test-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("token");
        std::fs::write(&path, "\n  \nsecond-is-not-taken\n").unwrap();
        assert_eq!(
            read_token(path.to_str().unwrap()).unwrap(),
            "second-is-not-taken"
        );
        std::fs::write(&path, "\n \n").unwrap();
        assert!(read_token(path.to_str().unwrap()).is_err());
        assert!(read_token(&dir.join("missing").to_string_lossy()).is_err());
        std::fs::remove_dir_all(&dir).ok();
    }

    #[test]
    fn epoch_advances_with_the_wall_clock() {
        let before = default_epoch();
        std::thread::sleep(Duration::from_millis(2));
        assert!(default_epoch() >= before);
    }
}
