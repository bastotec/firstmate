//! Native PTY agent. Deployment selection and limits: docs/stream-backend.md.
mod attach;
mod command_value;
mod commands;
mod hub_json;
mod local;
mod pty;
mod receiver;
use base64::Engine;
use fm_stream_wire::{is_machine_name, protocol_of_health, HUB_PROTOCOL};
use pty::Pty;
use reqwest::blocking::Client;
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::fs::{self, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Condvar, Mutex};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

const CAPABILITY: &str = "idempotent_command_results";
const STARTUP_SECS: u64 = 12;
const RESULT_RETRY_SECS: u64 = 900;
const RESULT_POST_SECS: u64 = 15;
/// Output is published as soon as the pty has nothing more ready: after a read,
/// the reader waits this long for the rest of a burst the program is still
/// writing, so a full-screen redraw leaves in one frame instead of dozens.
const COALESCE_MILLIS: i32 = 1;
/// ...but a steady stream is never held back longer than this.
const COALESCE_LIMIT: Duration = Duration::from_millis(8);
/// The largest output frame, and so the most one POST carries: well inside the
/// hub's 256 KiB replay ring, like the reader's single reads always were.
const FRAME_BYTES: usize = 65536;
/// Output queued for the hub before the reader stops reading the pty. A hub
/// that stops taking output back-pressures the endpoint, as it always has.
const OUTBOX_BYTES: usize = 1 << 20;
/// The agent's own diagnostics destination: state/<task>.agent-diagnostics
/// beside the status path, one line per failure the agent detects about
/// itself. Bounded by rotation, not by size alone - a count cap holds even
/// when the only writer is the one appending.
const DIAGNOSTICS_MAX_BYTES: u64 = 256 * 1024;
const DIAGNOSTICS_FILES: u32 = 3;

/// The diagnostics path for this task: the status path with its .status
/// suffix swapped for .agent-diagnostics, or "" when there is no status path.
fn diagnostics_path(options: &Options) -> String {
    options
        .status_path
        .strip_suffix(".status")
        .map(|stem| format!("{stem}.agent-diagnostics"))
        .unwrap_or_default()
}

/// Append one diagnostics line at `path`, best-effort. A write failure is
/// swallowed: diagnostics must never break the agent's main path.
fn diag_write(path: &str, event: &str, reason: impl std::fmt::Display) {
    if path.is_empty() {
        return;
    }
    let line = format!("{} {event} {reason}\n", timestamp());
    let result = (|| -> std::io::Result<()> {
        if fs::metadata(path).map(|m| m.len()).unwrap_or(0) >= DIAGNOSTICS_MAX_BYTES {
            let _ = fs::remove_file(format!("{path}.{}", DIAGNOSTICS_FILES - 1));
            for index in (1..DIAGNOSTICS_FILES - 1).rev() {
                let _ = fs::rename(format!("{path}.{index}"), format!("{path}.{}", index + 1));
            }
            let _ = fs::rename(path, format!("{path}.1"));
        }
        let mut file = OpenOptions::new().create(true).append(true).open(path)?;
        file.write_all(line.as_bytes())
    })();
    let _ = result;
}

fn diag(options: &Options, event: &str, reason: impl std::fmt::Display) {
    diag_write(&diagnostics_path(options), event, reason);
}

/// UTC ISO-8601 second-resolution timestamp, the shape of every other durable
/// record in the home.
fn timestamp() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0);
    let days = secs / 86_400;
    let rem = secs % 86_400;
    let (hour, min, sec) = (rem / 3600, (rem % 3600) / 60, rem % 60);
    // Civil-from-days (Howard Hinnant's algorithm), so the line is readable
    // without dragging a datetime crate into the agent.
    let z = days as i64 + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z.rem_euclid(146_097);
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    format!("{y:04}-{m:02}-{d:02}T{hour:02}:{min:02}:{sec:02}Z")
}

#[derive(Debug)]
enum Error {
    Superseded,
    Forgotten,
    Rejected,
    /// The hub did not judge the result body, so this stays retryable rather
    /// than settling it; see docs/stream-backend.md "Command path".
    Unmatched,
    Other(String),
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Superseded => write!(f, "endpoint superseded"),
            Self::Forgotten => write!(f, "hub forgot endpoint"),
            Self::Rejected => write!(f, "command result rejected"),
            Self::Unmatched => write!(f, "hub holds no such command"),
            Self::Other(s) => f.write_str(s),
        }
    }
}
impl From<std::io::Error> for Error {
    fn from(e: std::io::Error) -> Self {
        Self::Other(e.to_string())
    }
}

struct Hub {
    url: String,
    token: String,
    client: Client,
    /// Output frames only: one kept-alive connection, so a keystroke's echo
    /// does not pay a fresh connection through the tunnel on every chunk.
    output: Client,
    capability: Mutex<String>,
    deadline: Mutex<Option<Instant>>,
}
impl Hub {
    fn call(
        &self,
        method: &str,
        path: &str,
        body: Option<&Value>,
        timeout: Duration,
    ) -> Result<hub_json::Response, Error> {
        self.call_with(&self.client, method, path, body, timeout)
    }
    fn call_with(
        &self,
        client: &Client,
        method: &str,
        path: &str,
        body: Option<&Value>,
        timeout: Duration,
    ) -> Result<hub_json::Response, Error> {
        let timeout = match *self.deadline.lock().unwrap() {
            Some(until) => timeout.min(
                until
                    .checked_duration_since(Instant::now())
                    .ok_or_else(|| Error::Other("startup budget exhausted".into()))?,
            ),
            None => timeout,
        };
        let mut request = client
            .request(method.parse().unwrap(), format!("{}{path}", self.url))
            .bearer_auth(&self.token)
            .timeout(timeout);
        let capability = self.capability.lock().unwrap().clone();
        if !capability.is_empty() {
            request = request.header("X-Endpoint-Capability", capability);
        }
        if let Some(body) = body {
            request = request.json(body);
        }
        let answer = request
            .send()
            .map_err(|_| Error::Other(format!("hub did not answer {method} {path}")))?;
        let status = answer.status();
        let bytes = answer
            .bytes()
            .map_err(|_| Error::Other("hub response incomplete".into()))?;
        let answer = hub_json::decode(
            if bytes.is_empty() { b"{}" } else { &bytes },
            status.is_success() && method == "GET" && path.starts_with("/v1/agent/commands?"),
        )
        .map_err(|_| Error::Other("hub returned malformed JSON".into()))?;
        if !status.is_success() {
            return Err(match answer["error"].as_str().unwrap_or("") {
                "endpoint_superseded" | "duplicate_label" => Error::Superseded,
                "no_such_endpoint" => Error::Forgotten,
                // An unmatched command id is not a verdict on the result body
                // (see Error::Unmatched), so it takes its own class rather
                // than the definitive rejection one.
                "no_such_command" => Error::Unmatched,
                "result_conflict" | "bad_command_id" | "endpoint_unauthorized" => Error::Rejected,
                _ => Error::Other(format!(
                    "hub refused {method} {path}: HTTP {}",
                    status.as_u16()
                )),
            });
        }
        if method == "POST" && path == "/v1/agent/endpoints" {
            *self.capability.lock().unwrap() = answer["command_capability"]
                .as_str()
                .unwrap_or("")
                .to_owned();
        }
        Ok(answer)
    }
}

struct Options {
    hub: String,
    token_file: String,
    machine: String,
    label: String,
    cwd: String,
    status_path: String,
    ready_file: String,
    rows: u16,
    cols: u16,
    state_interval: f64,
    state_explicit: bool,
    poll_secs: f64,
}
impl Options {
    fn parse(args: &[String]) -> Result<Self, Error> {
        let mut o = Self {
            hub: std::env::var("FM_STREAM_HUB").unwrap_or_default(),
            token_file: String::new(),
            machine: String::new(),
            label: String::new(),
            cwd: String::new(),
            status_path: String::new(),
            ready_file: String::new(),
            rows: 40,
            cols: 200,
            state_interval: 5.0,
            state_explicit: false,
            poll_secs: 25.0,
        };
        let mut i = 0;
        while i < args.len() {
            let (key, value) = if let Some(pair) = args[i].split_once('=') {
                pair
            } else {
                i += 1;
                (
                    args[i - 1].as_str(),
                    args.get(i)
                        .ok_or_else(|| Error::Other("option requires a value".into()))?
                        .as_str(),
                )
            };
            let bad = || Error::Other(format!("invalid {key}"));
            match key {
                "--hub" => o.hub = value.into(),
                "--token-file" => o.token_file = value.into(),
                "--machine" => o.machine = value.into(),
                "--label" => o.label = value.into(),
                "--cwd" => o.cwd = value.into(),
                "--status-path" => o.status_path = value.into(),
                "--ready-file" => o.ready_file = value.into(),
                "--rows" => o.rows = value.parse().map_err(|_| bad())?,
                "--cols" => o.cols = value.parse().map_err(|_| bad())?,
                "--state-interval" => {
                    o.state_interval = value.parse().map_err(|_| bad())?;
                    o.state_explicit = true;
                }
                "--poll-secs" => o.poll_secs = value.parse().map_err(|_| bad())?,
                _ => return Err(Error::Other(format!("unknown option {key}"))),
            }
            i += 1;
        }
        if o.machine.is_empty() {
            let mut name = [0u8; 256];
            // SAFETY: gethostname writes at most the supplied buffer size.
            if unsafe { libc::gethostname(name.as_mut_ptr().cast(), name.len()) } != 0 {
                return Err(std::io::Error::last_os_error().into());
            }
            let end = name.iter().position(|b| *b == 0).unwrap_or(name.len());
            o.machine = String::from_utf8_lossy(&name[..end])
                .chars()
                .map(|c| {
                    if c.is_ascii_alphanumeric() || "._-".contains(c) {
                        c
                    } else {
                        '-'
                    }
                })
                .collect();
        }
        if o.hub.is_empty() {
            return Err(Error::Other(
                "--hub is required (or set FM_STREAM_HUB)".into(),
            ));
        }
        if !is_machine_name(&o.machine) {
            return Err(Error::Other(
                "--machine must be 1-128 characters of [A-Za-z0-9._-]".into(),
            ));
        }
        if o.label.is_empty() {
            return Err(Error::Other("--label is required".into()));
        }
        if !Path::new(&o.cwd).is_absolute() || !Path::new(&o.cwd).is_dir() {
            return Err(Error::Other("--cwd must be an absolute directory".into()));
        }
        if !o.status_path.is_empty() && !Path::new(&o.status_path).is_absolute() {
            return Err(Error::Other("--status-path must be absolute".into()));
        }
        for (name, number) in [
            ("state-interval", o.state_interval),
            ("poll-secs", o.poll_secs),
        ] {
            let timer_seconds = if name == "poll-secs" {
                number + 15.0
            } else {
                number
            };
            if !number.is_finite()
                || number < 0.0
                || Duration::try_from_secs_f64(timer_seconds)
                    .ok()
                    .and_then(|duration| Instant::now().checked_add(duration))
                    .is_none()
            {
                return Err(Error::Other(format!(
                    "--{name} must be finite, nonnegative, and fit a monotonic timer"
                )));
            }
        }
        Ok(o)
    }
    fn token(&self) -> Result<String, Error> {
        if !self.token_file.is_empty() {
            let text = fs::read_to_string(&self.token_file)?;
            let token = text.lines().next().unwrap_or("").trim();
            if !token.is_empty() {
                return Ok(token.into());
            }
        }
        std::env::var("FM_STREAM_TOKEN")
            .ok()
            .filter(|s| !s.is_empty())
            .ok_or_else(|| {
                Error::Other("no publish token; pass --token-file or set FM_STREAM_TOKEN".into())
            })
    }
}

/// Generation-based wakeup: a recovery during a failed poll is not lost.
#[derive(Default)]
struct Wake {
    generation: Mutex<u64>,
    changed: Condvar,
}
impl Wake {
    fn snapshot(&self) -> u64 {
        *self.generation.lock().unwrap()
    }
    fn notify(&self) {
        *self.generation.lock().unwrap() += 1;
        self.changed.notify_all();
    }
    fn wait(&self, generation: u64, secs: f64, stop: &AtomicBool) -> bool {
        let until = Instant::now() + Duration::from_secs_f64(secs);
        let mut current = self.generation.lock().unwrap();
        while *current == generation && !stop.load(Ordering::SeqCst) && Instant::now() < until {
            let left = until
                .saturating_duration_since(Instant::now())
                .min(Duration::from_millis(100));
            current = self.changed.wait_timeout(current, left).unwrap().0;
        }
        *current != generation
    }
    /// Wait until the generation moves past `generation` or `timeout` passes.
    fn settle(&self, generation: u64, timeout: Duration) {
        let current = self.generation.lock().unwrap();
        if *current == generation {
            let _ = self.changed.wait_timeout(current, timeout);
        }
    }
}

enum Item {
    Bytes(Vec<u8>),
    Geometry(u16, u16),
}
/// Output waiting for the hub, in order, with the geometry changes made between
/// it so the hub's screen resizes exactly where the pty did.
#[derive(Default)]
struct Outbox {
    state: Mutex<(VecDeque<Item>, usize, bool)>,
    changed: Condvar,
}
impl Outbox {
    fn wait_capacity(&self) {
        let mut state = self.state.lock().unwrap();
        while state.1 + FRAME_BYTES > OUTBOX_BYTES && !state.2 {
            state = self
                .changed
                .wait_timeout(state, Duration::from_millis(100))
                .unwrap()
                .0;
        }
    }
    fn has_capacity(&self, bytes: usize) -> bool {
        bytes <= OUTBOX_BYTES.saturating_sub(self.state.lock().unwrap().1)
    }
    fn push(&self, item: Item) {
        let mut state = self.state.lock().unwrap();
        if let Item::Bytes(bytes) = &item {
            state.1 += bytes.len();
        }
        state.0.push_back(item);
        self.changed.notify_all();
    }
    fn finish(&self) {
        self.state.lock().unwrap().2 = true;
        self.changed.notify_all();
    }
    /// Everything queued, as frames for one POST of at most FRAME_BYTES of
    /// output; None once the reader has finished and the queue is empty.
    fn take(&self, id: &str) -> Option<Vec<Value>> {
        let mut state = self.state.lock().unwrap();
        while state.0.is_empty() && !state.2 {
            state = self.changed.wait(state).unwrap();
        }
        if state.0.is_empty() {
            return None;
        }
        let mut frames = Vec::new();
        let mut bytes = Vec::new();
        let mut total = 0;
        while let Some(item) = state.0.front_mut() {
            match item {
                Item::Geometry(rows, cols) => {
                    if !bytes.is_empty() {
                        frames.push(json!({"endpoint_id":id,"b64":base64::engine::general_purpose::STANDARD.encode(&bytes)}));
                        bytes.clear();
                    }
                    frames.push(json!({"endpoint_id":id,"geometry":{"rows":*rows,"cols":*cols}}));
                    state.0.pop_front();
                }
                Item::Bytes(chunk) => {
                    let room = FRAME_BYTES - total;
                    if chunk.len() <= room {
                        bytes.extend_from_slice(chunk);
                        total += chunk.len();
                        state.1 -= chunk.len();
                        state.0.pop_front();
                    } else {
                        bytes.extend_from_slice(&chunk[..room]);
                        chunk.drain(..room);
                        state.1 -= room;
                        total += room;
                    }
                    if total == FRAME_BYTES {
                        break;
                    }
                }
            }
        }
        if !bytes.is_empty() {
            frames.push(json!({"endpoint_id":id,"b64":base64::engine::general_purpose::STANDARD.encode(&bytes)}));
        }
        self.changed.notify_all();
        Some(frames)
    }
}
struct Registration {
    not_before: Instant,
    backoff: f64,
}
struct Agent {
    options: Options,
    hub: Hub,
    pty: Pty,
    id: String,
    stop: Arc<AtomicBool>,
    reader_stop: AtomicBool,
    stood_down: AtomicBool,
    wake: Wake,
    /// Wakes the command loop the moment a take or a result post returns.
    tick: Wake,
    outbox: Outbox,
    local: local::Local,
    registration: Mutex<Registration>,
    result_deadline: Mutex<Option<Instant>>,
    /// The PTY's current rows and cols; a resize changes it, and every
    /// re-registration reports it so a restarted hub renders the same size.
    geometry: Mutex<(u16, u16)>,
    output: Mutex<Vec<u8>>,
}
impl Agent {
    fn registration(&self) -> Value {
        let (rows, cols) = *self.geometry.lock().unwrap();
        json!({"endpoint_id":self.id,"machine":self.options.machine,"label":self.options.label,"cwd":self.options.cwd,"rows":rows,"cols":cols,"capabilities":[CAPABILITY,"native_steering_receiver"],"protocol":HUB_PROTOCOL})
    }
    fn state(&self) -> Value {
        let deadline = *self.hub.deadline.lock().unwrap();
        let foreground = self.pty.foreground(deadline);
        let cwd = self.pty.cwd(&foreground, deadline);
        json!({"endpoint_id":self.id,"state":{"alive":self.pty.alive(),"foreground":foreground,"cwd":cwd,"published_at":now()}})
    }
    fn initial_state(&self) -> Result<(), Error> {
        self.hub
            .call(
                "POST",
                "/v1/agent/frames",
                Some(&json!({"machine":self.options.machine,"frames":[self.state()]})),
                Duration::from_secs(15),
            )
            .map(|_| ())
    }
    fn halt(&self) {
        self.stop.store(true, Ordering::SeqCst);
        self.wake.notify();
        self.tick.notify();
    }
    fn stand_down(&self) {
        self.stood_down.store(true, Ordering::SeqCst);
        diag(&self.options, "stood-down", "endpoint identity superseded");
        self.wake.notify();
        self.tick.notify();
    }
    fn recover(&self, final_frame: bool) -> bool {
        if self.stood_down.load(Ordering::SeqCst) {
            return false;
        }
        let until = Instant::now() + Duration::from_secs(3);
        let mut registration = loop {
            match self.registration.try_lock() {
                Ok(lock) => break lock,
                Err(_) if final_frame && Instant::now() < until => {
                    std::thread::sleep(Duration::from_millis(10))
                }
                Err(_) => return false,
            }
        };
        if self.stood_down.load(Ordering::SeqCst)
            || (!final_frame && Instant::now() < registration.not_before)
        {
            return false;
        }
        // The endpoint ID's independent random byte spreads a fleet's
        // reconnects even when all agents discover a restart simultaneously.
        let jitter = u8::from_str_radix(&self.id[..2], 16).unwrap_or(0) as f64 / 255.0 * 0.25;
        registration.not_before =
            Instant::now() + Duration::from_secs_f64(registration.backoff * (1.0 + jitter));
        match self.hub.call(
            "POST",
            "/v1/agent/endpoints",
            Some(&self.registration()),
            Duration::from_secs(15),
        ) {
            Ok(_) => {
                registration.backoff = 2.0;
                registration.not_before =
                    Instant::now() + Duration::from_secs_f64(2.0 * (1.0 + jitter));
            }
            Err(Error::Superseded) => {
                self.stand_down();
                return false;
            }
            Err(error) => {
                diag(
                    &self.options,
                    "re-register-failed",
                    format_args!("could not re-register endpoint {}: {error}", self.id),
                );
                registration.backoff = (registration.backoff * 2.0).min(60.0);
                return false;
            }
        }
        drop(registration);
        self.wake.notify();
        if let Err(error) = self.initial_state() {
            diag(
                &self.options,
                "state-publish-failed",
                format_args!("re-registered but could not publish state: {error}"),
            );
        }
        diag(
            &self.options,
            "re-registered",
            format_args!("endpoint {} back after: hub forgot it", self.id),
        );
        true
    }
    fn frames(&self, frame: Value) {
        self.post_frames(vec![frame], &self.hub.client);
    }
    fn post_frames(&self, frames: Vec<Value>, client: &Client) {
        let closing = frames.iter().any(|frame| frame["closed"] == true);
        if self.stood_down.load(Ordering::SeqCst) && !closing {
            return;
        }
        let body = json!({"machine":self.options.machine,"frames":frames});
        for attempt in 0..2 {
            match self.hub.call_with(
                client,
                "POST",
                "/v1/agent/frames",
                Some(&body),
                Duration::from_secs(30),
            ) {
                Ok(_) => return,
                Err(Error::Forgotten) if attempt == 0 && self.recover(closing) => continue,
                Err(Error::Superseded) => self.stand_down(),
                Err(error) => diag(&self.options, "publish-failed", error),
            }
            return;
        }
    }
    /// Read the pty as fast as it produces, and hand each burst on at once:
    /// to local attach clients directly, and to the publisher for the hub.
    /// Publication capacity back-pressures reading outside the output lock;
    /// individual kernel reads do not wait for a network round trip.
    fn reader(&self) {
        let mut buffer = vec![0u8; FRAME_BYTES];
        let mut since = Instant::now();
        while !self.reader_stop.load(Ordering::SeqCst) {
            // Backpressure belongs outside the output lock: a local resize
            // must not wait for the hub to make room.
            self.outbox.wait_capacity();
            let wait = if self.output.lock().unwrap().is_empty() {
                100
            } else {
                COALESCE_MILLIS
            };
            let ready = self.pty.wait_readable(wait);
            let mut batch = self.output.lock().unwrap();
            if !self.outbox.has_capacity(FRAME_BYTES) {
                continue;
            }
            let room = FRAME_BYTES - batch.len();
            let ended = match ready.and_then(|ready| {
                if ready {
                    self.pty.read_within(&mut buffer[..room], 0)
                } else {
                    Ok(None)
                }
            }) {
                Ok(Some(0)) => true,
                Ok(Some(n)) => {
                    if batch.is_empty() {
                        since = Instant::now();
                    }
                    batch.extend_from_slice(&buffer[..n]);
                    if batch.len() < FRAME_BYTES && since.elapsed() < COALESCE_LIMIT {
                        continue;
                    }
                    false
                }
                Ok(None) => false,
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => continue,
                Err(_) => true,
            };
            if !batch.is_empty() {
                self.publish(std::mem::take(&mut *batch));
            }
            if ended {
                break;
            }
        }
        let mut batch = self.output.lock().unwrap();
        if !batch.is_empty() {
            self.publish(std::mem::take(&mut *batch));
        }
        self.outbox.finish();
        self.halt();
    }
    fn resize_output(&self, rows: u16, cols: u16) -> Result<(), Error> {
        if !(1..=1000).contains(&rows) || !(1..=1000).contains(&cols) {
            return Err(Error::Other("resize rows and cols must be 1-1000".into()));
        }
        let mut batch = self.output.lock().unwrap();
        if !self.pty.alive() {
            return Err(Error::Other("the endpoint process has exited".into()));
        }
        if *self.geometry.lock().unwrap() == (rows, cols) {
            return Ok(());
        }
        if !self.outbox.has_capacity(batch.len() + FRAME_BYTES) {
            return Err(Error::Other(
                "resize refused: hub output backlog full".into(),
            ));
        }
        if !batch.is_empty() {
            self.publish(std::mem::take(&mut *batch));
        }
        let mut buffer = vec![0; FRAME_BYTES];
        // Bound the old-size drain to one publication budget so a child
        // producing continuously cannot delay a local resize indefinitely.
        let mut pending = FRAME_BYTES;
        while pending > 0 {
            let limit = pending.min(buffer.len());
            let Some(n) = self.pty.read_within(&mut buffer[..limit], 0)? else {
                break;
            };
            if n == 0 {
                break;
            }
            self.publish(buffer[..n].to_vec());
            pending -= n;
        }
        self.pty.resize(rows, cols)?;
        self.local.resize(rows, cols);
        *self.geometry.lock().unwrap() = (rows, cols);
        self.outbox.push(Item::Geometry(rows, cols));
        Ok(())
    }
    fn publish(&self, bytes: Vec<u8>) {
        // The hub's copy first: the local screen parse must not delay it.
        self.outbox.push(Item::Bytes(bytes.clone()));
        self.local.feed(&bytes);
    }
    /// Post queued output in order, capped at FRAME_BYTES across each request.
    fn publisher(&self) {
        let mut geometry = None;
        while let Some(mut frames) = self.outbox.take(&self.id) {
            if let Some(size) = &geometry {
                frames.insert(0, json!({"endpoint_id":self.id,"geometry":size}));
            }
            for frame in &frames {
                if let Some(size) = frame.get("geometry") {
                    geometry = Some(size.clone());
                }
            }
            self.post_frames(frames, &self.hub.output);
        }
    }
    fn heartbeat(&self) {
        while !self.stop.load(Ordering::SeqCst) {
            self.wake.wait(
                self.wake.snapshot(),
                self.options.state_interval,
                &self.stop,
            );
            if !self.stop.load(Ordering::SeqCst) && !self.stood_down.load(Ordering::SeqCst) {
                self.frames(self.state());
            }
        }
    }
    fn apply(&self, command: &Value, response: &hub_json::Response) -> Result<(), Error> {
        let payload = &command["payload"];
        match command["kind"].as_str().unwrap_or("") {
            "input" => {
                let mut bytes = Vec::new();
                if !payload["text"].is_null() {
                    bytes.extend_from_slice(
                        response
                            .python_str(&payload["text"])
                            .map_err(|error| Error::Other(error.into()))?
                            .as_bytes(),
                    );
                }
                if let Some(b64) = payload["b64"].as_str() {
                    bytes.extend(
                        base64::engine::general_purpose::STANDARD
                            .decode(b64)
                            .map_err(|_| Error::Other("the input's b64 is not base64".into()))?,
                    );
                }
                if payload["submit"].as_bool().unwrap_or(false) {
                    bytes.push(b'\r');
                }
                if let Some(keys) = payload["keys"].as_array() {
                    for key in keys {
                        bytes.extend_from_slice(match key.as_str().unwrap_or("") {
                            "Enter" => b"\r",
                            "Escape" => b"\x1b",
                            "C-c" => b"\x03",
                            "C-u" => b"\x15",
                            _ => b"",
                        });
                    }
                }
                if bytes.is_empty() {
                    return Err(Error::Other("the input carried nothing to type".into()));
                }
                if !self.pty.alive() {
                    return Err(Error::Other("the endpoint process has exited".into()));
                }
                self.pty.write(&bytes)?;
                Ok(())
            }
            "resize" => {
                let (rows, cols) = local::geometry(payload)
                    .ok_or_else(|| Error::Other("resize rows and cols must be 1-1000".into()))?;
                self.resize_output(rows, cols)
            }
            "kill" => {
                self.pty.close(
                    payload["signal"]
                        .as_str()
                        .is_some_and(|s| !s.is_empty() && s != "TERM"),
                )?;
                Ok(())
            }
            "status" => {
                let state = payload["state"].as_str().unwrap_or("");
                if ![
                    "working",
                    "needs-decision",
                    "blocked",
                    "paused",
                    "done",
                    "failed",
                    "resolved",
                ]
                .contains(&state)
                {
                    return Err(Error::Other(format!("unknown status state {state:?}")));
                }
                if self.options.status_path.is_empty() {
                    return Err(Error::Other(
                        "this endpoint registered no status path".into(),
                    ));
                }
                let note = if payload["note"].is_null() {
                    String::new()
                } else {
                    response
                        .python_str(&payload["note"])
                        .map_err(|error| Error::Other(error.into()))?
                };
                let note = note
                    .split(|ch: char| ch.is_whitespace() || ('\u{1c}'..='\u{1f}').contains(&ch))
                    .filter(|part| !part.is_empty())
                    .collect::<Vec<_>>()
                    .join(" ");
                let record = format!("{state}: {note}\n");
                OpenOptions::new()
                    .create(true)
                    .append(true)
                    .open(&self.options.status_path)?
                    .write_all(record.as_bytes())?;
                Ok(())
            }
            kind => Err(Error::Other(format!("unknown command kind {kind:?}"))),
        }
    }
    fn abandon(&self) {
        // No reader runs before startup finishes, and a kernel that drains a
        // closing terminal (macOS) holds the child's exit while its output
        // sits unread, so discard it until the child is gone.
        let closed = AtomicBool::new(false);
        std::thread::scope(|scope| {
            scope.spawn(|| {
                let mut discard = [0u8; 4096];
                while !closed.load(Ordering::SeqCst) {
                    if matches!(self.pty.read(&mut discard), Ok(Some(0)) | Err(_)) {
                        break;
                    }
                }
            });
            let _ = self.pty.close(true);
            closed.store(true, Ordering::SeqCst);
        });
        *self.hub.deadline.lock().unwrap() = None;
        let _ = self.hub.call("POST", "/v1/agent/frames", Some(&json!({"machine":self.options.machine,"frames":[{"endpoint_id":self.id,"closed":true,"exit_code":null}]})), Duration::from_secs(2));
    }
    fn run(self: Arc<Self>) -> Result<(), Error> {
        signal_hook::flag::register(signal_hook::consts::SIGTERM, self.stop.clone())?;
        signal_hook::flag::register(signal_hook::consts::SIGINT, self.stop.clone())?;
        let reader = {
            let a = self.clone();
            std::thread::spawn(move || a.reader())
        };
        let heartbeat = {
            let a = self.clone();
            std::thread::spawn(move || a.heartbeat())
        };
        let commands = {
            let a = self.clone();
            std::thread::spawn(move || a.commands())
        };
        let publisher = {
            let a = self.clone();
            std::thread::spawn(move || a.publisher())
        };
        if let Some(listener) = self.local.listen(&self.id) {
            let a = self.clone();
            std::thread::spawn(move || local::serve(a, listener));
        }
        while !self.stop.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(50));
        }
        *self.result_deadline.lock().unwrap() =
            Some(Instant::now() + Duration::from_secs(RESULT_RETRY_SECS));
        self.wake.notify();
        // A signal must stop the child promptly, even during result retries.
        let close = self.pty.close(false);
        // A local attach hears the exit now, not after the command loop's
        // long poll returns: the reader has already handed it every byte.
        if reader.is_finished() {
            if let Ok(Some(code)) = self.pty.exit_code() {
                self.local.close(json!(code));
            }
        }
        let _ = commands.join();
        let _ = heartbeat.join();
        self.reader_stop.store(true, Ordering::SeqCst);
        let _ = reader.join(); // No descriptor release while a read can name it.
        self.outbox.finish();
        let _ = publisher.join(); // All output reaches the hub before the close.
        let exit = self.pty.exit_code();
        self.local.close(match &exit {
            Ok(Some(code)) => json!(code),
            _ => Value::Null,
        });
        close?;
        let exit = exit?;
        if exit.is_none() {
            return Err(Error::Other(
                "child exit unconfirmed; refusing final close".into(),
            ));
        }
        self.frames(json!({"endpoint_id":self.id,"closed":true,"exit_code":exit,"state":{"alive":false,"foreground":[],"cwd":"","published_at":now()}}));
        Ok(())
    }
}
impl local::Endpoint for Agent {
    fn id(&self) -> &str {
        &self.id
    }
    fn local(&self) -> &local::Local {
        &self.local
    }
    fn input(&self, bytes: &[u8]) -> Result<(), String> {
        if !self.pty.alive() {
            return Err("the endpoint process has exited".into());
        }
        self.pty.write(bytes).map_err(|error| error.to_string())
    }
    /// The local twin of the hub's `resize` command. Saturation must refuse
    /// rather than wait for hub progress while holding the output lock.
    fn resize(&self, rows: u16, cols: u16) -> Result<(), String> {
        self.resize_output(rows, cols)
            .map_err(|error| error.to_string())
    }
}
fn now() -> f64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs_f64()
}

fn serve(args: &[String]) -> Result<(), Error> {
    let mut options = Options::parse(args)?;
    let token = options.token()?;
    let hub = Hub {
        url: options.hub.trim_end_matches('/').into(),
        token,
        // One connection per call, like the Python agent: a hub that stalls
        // one call must not be masked by a pooled connection that stays
        // fast, and the startup budget bounds each attempt the same way.
        client: Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .pool_max_idle_per_host(0)
            .build()
            .map_err(|_| Error::Other("HTTP client initialization failed".into()))?,
        output: Client::builder()
            .redirect(reqwest::redirect::Policy::none())
            .pool_idle_timeout(Duration::from_secs(30))
            .tcp_nodelay(true)
            .build()
            .map_err(|_| Error::Other("HTTP client initialization failed".into()))?,
        capability: Mutex::new(String::new()),
        deadline: Mutex::new(Some(Instant::now() + Duration::from_secs(STARTUP_SECS))),
    };
    let health = hub.call("GET", "/v1/health", None, Duration::from_secs(30))?;
    protocol_of_health(&health).map_err(|p| {
        Error::Other(format!(
            "hub speaks protocol {p} but this agent implements {HUB_PROTOCOL}; update both ends"
        ))
    })?;
    if !health["capabilities"]
        .as_array()
        .is_some_and(|c| c.iter().any(|v| v == CAPABILITY))
    {
        return Err(Error::Other(format!(
            "hub does not advertise {CAPABILITY}; restart or upgrade the hub"
        )));
    }
    if !options.state_explicit {
        if let Some(age) = health["state_max_age_secs"]
            .as_f64()
            .filter(|age| *age > 0.0)
        {
            options.state_interval = options.state_interval.min(age / 3.0).max(0.5);
        }
    }
    let mut random = [0u8; 16];
    fs::File::open("/dev/urandom")?.read_exact(&mut random)?;
    let id: String = random.iter().map(|b| format!("{b:02x}")).collect();
    let mut pty = Pty::spawn(&options.cwd, options.rows, options.cols, &id, &options.hub)?;
    pty.set_diagnostics_path(diagnostics_path(&options));
    let (options_rows, options_cols) = (options.rows, options.cols);
    if pty.wait(Duration::from_millis(400)) {
        let mut output = [0u8; 65536];
        let size = pty.read(&mut output)?.unwrap_or(0);
        let output = String::from_utf8_lossy(&output[..size]);
        let detail = output.trim().lines().last().unwrap_or("no output");
        return Err(Error::Other(format!(
            "shell exited immediately (status {:?}): {detail}",
            pty.exit_code()?
        )));
    }
    let agent = Arc::new(Agent {
        options,
        hub,
        pty,
        id,
        stop: Arc::new(AtomicBool::new(false)),
        reader_stop: AtomicBool::new(false),
        stood_down: AtomicBool::new(false),
        wake: Wake::default(),
        tick: Wake::default(),
        outbox: Outbox::default(),
        local: local::Local::new(options_rows, options_cols),
        registration: Mutex::new(Registration {
            not_before: Instant::now(),
            backoff: 2.0,
        }),
        result_deadline: Mutex::new(None),
        geometry: Mutex::new((options_rows, options_cols)),
        output: Mutex::new(Vec::new()),
    });
    let startup = (|| {
        agent.hub.call(
            "POST",
            "/v1/agent/endpoints",
            Some(&agent.registration()),
            Duration::from_secs(30),
        )?;
        agent.initial_state()?;
        if !agent.options.ready_file.is_empty() {
            fs::write(
                &agent.options.ready_file,
                format!("{} {}\n", agent.options.machine, agent.id),
            )?;
        }
        Ok::<_, Error>(())
    })();
    if let Err(error) = startup {
        agent.abandon();
        return Err(error);
    }
    eprintln!(
        "fm-stream-agent {} endpoint {} on {} -> {}",
        env!("CARGO_PKG_VERSION"),
        agent.id,
        agent.options.machine,
        agent.options.hub
    );
    // Like Python, unlinkable startup diagnostic captures must not grow for
    // life. The durable diagnostics file carries the agent's own failures from
    // here, rotated and bounded where this capture was neither.
    let null = OpenOptions::new().write(true).open("/dev/null")?;
    use std::os::fd::AsRawFd;
    // SAFETY: null is live through both dup2 calls; only this agent's output changes.
    unsafe {
        libc::dup2(null.as_raw_fd(), 1);
        libc::dup2(null.as_raw_fd(), 2);
    }
    *agent.hub.deadline.lock().unwrap() = None;
    agent.clone().run().inspect_err(|error| {
        diag(&agent.options, "agent-crashed", error);
    })
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("fm-stream-agent serve --hub URL --token-file PATH --machine NAME --label NAME --cwd DIR\n  [--status-path PATH] [--ready-file PATH] [--rows N] [--cols N]\n  [--state-interval SECS] [--poll-secs SECS]\nfm-stream-agent attach --hub URL --endpoint ID [--token-file PATH] [--detach-key KEY]\nfm-stream-agent --protocol | --version");
        return;
    }
    match args.first().map(String::as_str) {
        Some("--protocol") => println!("{HUB_PROTOCOL}"),
        Some("--version") => println!("{}", env!("CARGO_PKG_VERSION")),
        Some("attach") => {
            if let Err(error) = attach::run(&args[1..]) {
                eprintln!("fm-stream-agent attach: {error}");
                std::process::exit(1);
            }
        }
        Some("serve") => {
            if let Err(error) = serve(&args[1..]) {
                eprintln!("fm-stream-agent: {error}");
                std::process::exit(1);
            }
        }
        _ => {
            println!("fm-stream-agent serve --hub URL --token-file PATH --machine NAME --label NAME --cwd DIR\n  [--status-path PATH] [--ready-file PATH] [--rows N] [--cols N]\n  [--state-interval SECS] [--poll-secs SECS]\nfm-stream-agent attach --hub URL --endpoint ID [--token-file PATH] [--detach-key KEY]\nfm-stream-agent --protocol | --version");
            if args.first().is_none_or(|a| a != "--help" && a != "-h") {
                std::process::exit(2);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn test_options(status_path: &str) -> Options {
        Options {
            hub: String::new(),
            token_file: String::new(),
            machine: String::new(),
            label: String::new(),
            cwd: String::new(),
            status_path: status_path.into(),
            ready_file: String::new(),
            rows: 40,
            cols: 200,
            state_interval: 5.0,
            state_explicit: false,
            poll_secs: 25.0,
        }
    }

    #[test]
    fn diagnostics_path_sits_beside_the_status_path() {
        let options = test_options("/home/state/task.status");
        assert_eq!(
            diagnostics_path(&options),
            "/home/state/task.agent-diagnostics"
        );
        assert_eq!(diagnostics_path(&test_options("")), "");
    }

    #[test]
    fn diag_appends_one_line_per_event_and_rotates_under_a_file_count_cap() {
        let dir =
            std::env::temp_dir().join(format!("fm-agent-diag-{}-{}", std::process::id(), line!()));
        fs::create_dir_all(&dir).unwrap();
        let options = test_options(&dir.join("task.status").display().to_string());
        // Enough volume to cross the shipped 256 KiB cap through the public
        // path, so the case exercises the real constants rather than a
        // test-only shrink.
        for index in 0..6000 {
            diag(
                &options,
                "publish-failed",
                format_args!("{index} {}", "x".repeat(200)),
            );
        }
        let live = fs::read_to_string(dir.join("task.agent-diagnostics")).unwrap();
        let one = fs::read_to_string(dir.join("task.agent-diagnostics.1")).unwrap();
        let two = fs::read_to_string(dir.join("task.agent-diagnostics.2")).unwrap();
        // The count cap: exactly the live file and its two rotations.
        let files: Vec<_> = fs::read_dir(&dir)
            .unwrap()
            .filter_map(|e| e.ok())
            .filter(|e| {
                e.file_name()
                    .to_string_lossy()
                    .contains("agent-diagnostics")
            })
            .collect();
        assert_eq!(files.len(), 3, "rotation left {files:?}");
        // Order: the oldest content is in .2, the newest in the live file.
        let number = |line: &str| line.split(' ').nth(2).unwrap().parse::<u32>().unwrap();
        let all: Vec<_> = two.lines().chain(one.lines()).chain(live.lines()).collect();
        let numbers: Vec<_> = all.iter().map(|l| number(l)).collect();
        let mut sorted = numbers.clone();
        sorted.sort();
        assert_eq!(numbers, sorted, "rotation must not reorder events");
        // No rotated file exceeds the cap by more than one line.
        for text in [&two, &one, &live] {
            assert!(text.len() as u64 <= DIAGNOSTICS_MAX_BYTES + 512);
            assert!(text.ends_with('\n'));
        }
        // One line per event, timestamp first, event second.
        let first = all.first().unwrap();
        assert!(first.starts_with("20"), "{first}");
        assert_eq!(first.split(' ').nth(1), Some("publish-failed"));
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn diag_swallows_an_unwritable_destination() {
        let dir = std::env::temp_dir().join(format!(
            "fm-agent-diag-denied-{}-{}",
            std::process::id(),
            line!()
        ));
        fs::create_dir_all(&dir).unwrap();
        let denied = dir.join("task.agent-diagnostics");
        fs::write(&denied, b"").unwrap();
        use std::os::unix::fs::PermissionsExt;
        let mut perms = fs::metadata(&denied).unwrap().permissions();
        perms.set_mode(0o000);
        fs::set_permissions(&denied, perms).unwrap();
        // Must not panic: the write failure is diagnostics, not an agent error.
        diag(
            &test_options(&dir.join("task.status").display().to_string()),
            "publish-failed",
            "must not raise",
        );
        // A directory standing in for the file is refused the same way.
        fs::create_dir(dir.join("blocked/task.status").parent().unwrap()).unwrap();
        diag(
            &test_options(&dir.join("blocked/task.status").display().to_string()),
            "publish-failed",
            "must not raise",
        );
        let _ = fs::remove_dir_all(&dir);
    }

    #[test]
    fn timestamp_is_utc_iso8601() {
        let stamp = timestamp();
        // 2026-10-09T20:58:40Z shape: 20 chars, T at index 10, Z at 19.
        assert_eq!(stamp.len(), 20);
        assert_eq!(stamp.as_bytes()[10], b'T');
        assert_eq!(stamp.as_bytes()[19], b'Z');
        assert!(stamp.starts_with("20"));
    }

    fn decoded(frame: &Value) -> Vec<u8> {
        base64::engine::general_purpose::STANDARD
            .decode(frame["b64"].as_str().unwrap())
            .unwrap()
    }

    #[test]
    fn outbox_coalesces_in_order_and_bounds_each_post() {
        let outbox = Outbox::default();
        outbox.push(Item::Bytes(b"ab".to_vec()));
        outbox.push(Item::Bytes(b"cd".to_vec()));
        outbox.push(Item::Geometry(30, 100));
        outbox.push(Item::Bytes(b"ef".to_vec()));
        // Everything already queued leaves in one POST, geometry in its place.
        let frames = outbox.take("id").unwrap();
        assert_eq!(frames.len(), 3);
        assert_eq!(decoded(&frames[0]), b"abcd");
        assert_eq!(frames[1]["geometry"], json!({"rows": 30, "cols": 100}));
        assert_eq!(decoded(&frames[2]), b"ef");
        // A burst larger than one frame is split, never reordered or lost.
        let burst: Vec<u8> = (0..FRAME_BYTES + 10).map(|i| i as u8).collect();
        outbox.push(Item::Bytes(burst.clone()));
        let first = outbox.take("id").unwrap();
        let second = outbox.take("id").unwrap();
        assert_eq!(first.len(), 1);
        assert_eq!(decoded(&first[0]).len(), FRAME_BYTES);
        assert_eq!([decoded(&first[0]), decoded(&second[0])].concat(), burst);
        assert_eq!(outbox.state.lock().unwrap().1, 0);
        outbox.finish();
        assert!(outbox.take("id").is_none());
    }

    #[test]
    fn geometry_does_not_reset_the_post_output_budget() {
        let outbox = Outbox::default();
        let mut expected = Vec::new();
        for row in 25..35 {
            let chunk = vec![row as u8; FRAME_BYTES / 2 + 7];
            expected.extend_from_slice(&chunk);
            outbox.push(Item::Bytes(chunk));
            outbox.push(Item::Geometry(row, 80));
        }
        outbox.finish();
        let mut output = Vec::new();
        let mut geometries = Vec::new();
        while let Some(frames) = outbox.take("id") {
            let mut total = 0;
            for frame in frames {
                if frame.get("b64").is_some() {
                    let bytes = decoded(&frame);
                    total += bytes.len();
                    output.extend(bytes);
                } else {
                    geometries.push(frame["geometry"]["rows"].as_u64().unwrap());
                }
            }
            assert!(total <= FRAME_BYTES);
        }
        assert_eq!(output, expected);
        assert_eq!(geometries, (25..35).collect::<Vec<_>>());
    }

    fn resize_test_agent() -> Arc<Agent> {
        let cwd = std::env::current_dir()
            .unwrap()
            .to_str()
            .unwrap()
            .to_owned();
        let options = Options::parse(&[
            "--hub".into(),
            "http://127.0.0.1:1".into(),
            "--label".into(),
            "resize-test".into(),
            "--cwd".into(),
            cwd.clone(),
            "--rows".into(),
            "24".into(),
            "--cols".into(),
            "80".into(),
        ])
        .unwrap();
        let client = Client::builder().build().unwrap();
        Arc::new(Agent {
            options,
            hub: Hub {
                url: "http://127.0.0.1:1".into(),
                token: String::new(),
                client: client.clone(),
                output: client,
                capability: Mutex::new(String::new()),
                deadline: Mutex::new(None),
            },
            pty: Pty::spawn(&cwd, 24, 80, "resize-test", "http://127.0.0.1:1").unwrap(),
            id: "0123456789abcdef0123456789abcdef".into(),
            stop: Arc::new(AtomicBool::new(false)),
            reader_stop: AtomicBool::new(false),
            stood_down: AtomicBool::new(false),
            wake: Wake::default(),
            tick: Wake::default(),
            outbox: Outbox::default(),
            local: local::Local::new(24, 80),
            registration: Mutex::new(Registration {
                not_before: Instant::now(),
                backoff: 2.0,
            }),
            result_deadline: Mutex::new(None),
            geometry: Mutex::new((24, 80)),
            output: Mutex::new(Vec::new()),
        })
    }

    #[test]
    fn both_resize_paths_flush_old_output_before_new_geometry_and_redraw() {
        for hub_command in [false, true] {
            let agent = resize_test_agent();
            let mut discard = [0; FRAME_BYTES];
            let marker = std::env::current_dir().unwrap().join(format!(
                ".resize-marker-{}-{hub_command}",
                std::process::id()
            ));
            // Interactive line editors can emit a newline even with echo off,
            // scrolling the bottom-row fixture. Use a plain command loop so
            // only the test's printf output reaches the screen after setup.
            let setup = format!(
                "exec /bin/sh -c 'stty -echo; printf ready > \"{}\"; while IFS= read -r command; do eval \"$command\"; done'\r",
                marker.display()
            );
            agent.pty.write(setup.as_bytes()).unwrap();
            let until = Instant::now() + Duration::from_secs(10);
            while !marker.is_file() && Instant::now() < until {
                agent.pty.read_within(&mut discard, 5).unwrap();
            }
            assert!(marker.is_file());
            fs::remove_file(&marker).unwrap();
            while agent.pty.read_within(&mut discard, 100).unwrap().is_some() {}
            *agent.output.lock().unwrap() = b"\x1b[24;1Hold-batch".to_vec();
            let command = format!(
                "printf '\\033[23;1Hold-kernel'; printf done > '{}'\r",
                marker.display()
            );
            agent.pty.write(command.as_bytes()).unwrap();
            let until = Instant::now() + Duration::from_secs(10);
            while !marker.is_file() && Instant::now() < until {
                std::thread::sleep(Duration::from_millis(5));
            }
            assert!(marker.is_file());
            fs::remove_file(&marker).unwrap();
            if hub_command {
                agent
                    .apply(
                        &json!({"kind":"resize", "payload":{"rows":40,"cols":80}}),
                        &hub_json::decode(b"{}", false).unwrap(),
                    )
                    .unwrap();
            } else {
                local::Endpoint::resize(&*agent, 40, 80).unwrap();
            }
            assert!(agent.local.lines()[23].contains("old-batch"));
            assert!(agent.local.lines()[22].contains("old-kernel"));
            assert_eq!(agent.registration()["rows"], 40);
            let reader_agent = agent.clone();
            let reader = std::thread::spawn(move || reader_agent.reader());
            agent
                .pty
                .write(b"printf '\\033[40;1Hnew-bottom'\r")
                .unwrap();
            let until = Instant::now() + Duration::from_secs(10);
            while !agent.local.lines()[39].contains("new-bottom") && Instant::now() < until {
                std::thread::sleep(Duration::from_millis(5));
            }
            agent.reader_stop.store(true, Ordering::SeqCst);
            reader.join().unwrap();
            assert!(agent.local.lines()[39].contains("new-bottom"));
            let mut before = Vec::new();
            let mut after = Vec::new();
            let mut resized = false;
            while let Some(frames) = agent.outbox.take(&agent.id) {
                for frame in frames {
                    if frame.get("geometry").is_some() {
                        assert_eq!(frame["geometry"], json!({"rows":40,"cols":80}));
                        resized = true;
                    } else if resized {
                        after.extend(decoded(&frame));
                    } else {
                        before.extend(decoded(&frame));
                    }
                }
            }
            assert!(resized);
            assert!(String::from_utf8_lossy(&before).contains("old-batch"));
            assert!(String::from_utf8_lossy(&before).contains("old-kernel"));
            assert!(String::from_utf8_lossy(&after).contains("new-bottom"));
            agent.pty.close(true).unwrap();
        }
    }

    #[test]
    fn saturated_resize_refuses_without_publishing_or_changing_geometry() {
        for hub_command in [false, true] {
            let agent = resize_test_agent();
            agent
                .outbox
                .push(Item::Bytes(vec![b'x'; OUTBOX_BYTES - FRAME_BYTES]));
            *agent.output.lock().unwrap() = b"pending".to_vec();
            let started = Instant::now();
            for rows in 30..130 {
                let error = if hub_command {
                    agent
                        .apply(
                            &json!({"kind":"resize", "payload":{"rows":rows,"cols":80}}),
                            &hub_json::decode(b"{}", false).unwrap(),
                        )
                        .unwrap_err()
                        .to_string()
                } else {
                    local::Endpoint::resize(&*agent, rows, 80).unwrap_err()
                };
                assert!(error.contains("backlog full"));
            }
            assert!(started.elapsed() < Duration::from_secs(1));
            assert_eq!(agent.registration()["rows"], 24);
            assert_eq!(agent.local.lines().len(), 24);
            assert_eq!(*agent.output.lock().unwrap(), b"pending");
            assert_eq!(
                agent.outbox.state.lock().unwrap().1,
                OUTBOX_BYTES - FRAME_BYTES
            );
            agent.outbox.take(&agent.id).unwrap();
            agent.resize_output(40, 80).unwrap();
            assert_eq!(agent.registration()["rows"], 40);
            agent.pty.close(true).unwrap();
        }
    }

    #[test]
    fn a_full_outbox_holds_the_reader_until_the_publisher_drains() {
        let outbox = Arc::new(Outbox::default());
        outbox.push(Item::Bytes(vec![0; OUTBOX_BYTES]));
        let pushed = Arc::new(AtomicBool::new(false));
        let reader = {
            let (outbox, pushed) = (outbox.clone(), pushed.clone());
            std::thread::spawn(move || {
                outbox.wait_capacity();
                outbox.push(Item::Bytes(b"next".to_vec()));
                pushed.store(true, Ordering::SeqCst);
            })
        };
        std::thread::sleep(Duration::from_millis(150));
        assert!(!pushed.load(Ordering::SeqCst));
        while outbox.state.lock().unwrap().1 >= OUTBOX_BYTES {
            outbox.take("id").unwrap();
        }
        reader.join().unwrap();
        assert!(pushed.load(Ordering::SeqCst));
    }
}
