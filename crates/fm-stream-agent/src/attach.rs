//! Interactive terminal attach: a hub client, not an endpoint publisher.
//!
//! Puts the local terminal in raw mode, paints the endpoint's current screen,
//! streams its output from exactly where that screen ends, forwards every
//! input byte (keystrokes, escape sequences, pastes) as hub `input` commands,
//! forwards local resizes as hub `resize` commands, and detaches on one key
//! (Ctrl-] by default) without touching the endpoint. docs/stream-backend.md
//! "Interactive attach" owns the operator contract.
//!
//! When the endpoint's agent runs on this same machine, the same session runs
//! over the agent's private unix socket instead (local.rs), never touching the
//! hub; FM_STREAM_ATTACH_LOCAL=0 forces the hub path.
use crate::local;
use base64::{engine::general_purpose::STANDARD, Engine};
use reqwest::blocking::{Client, Response};
use serde_json::{json, Value};
use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::UnixStream;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const POST_SECS: u64 = 15;

enum Event {
    Detaching(Instant),
    Detach,
    Closed(Value),
    Lost(String),
}

enum Input {
    Bytes(Vec<u8>),
    Detach,
}

struct Session {
    hub: String,
    token: String,
    endpoint: String,
    client: Client,
}

impl Session {
    fn request(&self, method: &str, path: &str, body: Option<&Value>) -> Result<Response, String> {
        let mut request = self
            .client
            .request(method.parse().unwrap(), format!("{}{path}", self.hub))
            .bearer_auth(&self.token);
        let streaming = method == "GET" && (path.ends_with("/stream") || path.contains("/stream?"));
        if !streaming {
            request = request.timeout(Duration::from_secs(POST_SECS));
        }
        if let Some(body) = body {
            request = request.json(body);
        }
        request
            .send()
            .map_err(|_| format!("the hub at {} did not answer {method} {path}", self.hub))
    }
    fn json(&self, method: &str, path: &str, body: Option<&Value>) -> Result<(u16, Value), String> {
        let response = self.request(method, path, body)?;
        let status = response.status().as_u16();
        let value = response.json::<Value>().unwrap_or(Value::Null);
        Ok((status, value))
    }
    fn task_path(&self, tail: &str) -> String {
        format!("/v1/tasks/{}{tail}", self.endpoint)
    }
    fn resize(&self, rows: u16, cols: u16) -> Result<bool, String> {
        let (status, body) = self
            .json(
                "POST",
                &self.task_path("/resize"),
                Some(&json!({"rows": rows, "cols": cols})),
            )
            .map_err(|reason| format!("resize delivery uncertain: {reason}; not retried"))?;
        if status == 404
            || (status == 502
                && body["error"] == "agent_refused"
                && body["message"]
                    .as_str()
                    .is_some_and(|message| message.starts_with("unknown command kind")))
        {
            Ok(false)
        } else if (200..300).contains(&status) {
            Ok(true)
        } else {
            Err(format!(
                "resize delivery failed: HTTP {status}: {}; not retried",
                body["message"].as_str().unwrap_or("unknown error")
            ))
        }
    }
}

/// Restores the terminal mode it changed, on every exit path.
struct RawMode {
    saved: libc::termios,
    output: Arc<Mutex<bool>>,
}
impl RawMode {
    fn enter() -> Result<Self, String> {
        // SAFETY: termios is plain data; tcgetattr fills it for fd 0.
        let mut saved: libc::termios = unsafe { std::mem::zeroed() };
        if unsafe { libc::tcgetattr(0, &mut saved) } != 0 {
            return Err("cannot read the terminal mode".into());
        }
        let mut raw = saved;
        // SAFETY: raw is an initialized termios owned by this frame.
        unsafe { libc::cfmakeraw(&mut raw) };
        if unsafe { libc::tcsetattr(0, libc::TCSANOW, &raw) } != 0 {
            return Err("cannot put the terminal in raw mode".into());
        }
        Ok(Self {
            saved,
            output: Arc::new(Mutex::new(true)),
        })
    }
}
impl Drop for RawMode {
    fn drop(&mut self) {
        let mut active = self.output.lock().unwrap();
        *active = false;
        let mut stdout = std::io::stdout().lock();
        let _ = stdout.write_all(b"\x1b[?1049l\x1b[?1047l\x1b[?47l\x1b[?25h\x1b[?2004l\x1b[?1000l\x1b[?1001l\x1b[?1002l\x1b[?1003l\x1b[?1004l\x1b[?1005l\x1b[?1006l\x1b[?1015l\x1b[?1016l\x1b[0m");
        let _ = stdout.flush();
        unsafe { libc::tcsetattr(0, libc::TCSANOW, &self.saved) };
    }
}

fn local_size() -> Option<(u16, u16)> {
    for fd in [1, 0, 2] {
        // SAFETY: winsize is plain data; TIOCGWINSZ fills it.
        let mut size: libc::winsize = unsafe { std::mem::zeroed() };
        if unsafe { libc::ioctl(fd, libc::TIOCGWINSZ, &mut size) } == 0
            && size.ws_row > 0
            && size.ws_col > 0
        {
            return Some((size.ws_row, size.ws_col));
        }
    }
    None
}

/// "C-]" (default), "C-\", "C-a" .. "C-z" -> the control byte.
fn detach_byte(spec: &str) -> Result<u8, String> {
    let key = spec
        .strip_prefix("C-")
        .filter(|k| k.len() == 1)
        .ok_or_else(|| format!("--detach-key must look like C-] or C-a, not {spec:?}"))?;
    let byte = key.as_bytes()[0].to_ascii_uppercase();
    match byte {
        b'@'..=b'_' => Ok(byte - b'@'),
        _ => Err(format!("--detach-key {spec:?} has no control byte")),
    }
}

/// Split pending input into hub payloads: UTF-8 text when it is text (a
/// trailing partial character waits for the next read), raw base64 otherwise.
fn payload(pending: &mut Vec<u8>, flush: bool) -> Option<Value> {
    if pending.is_empty() {
        return None;
    }
    match std::str::from_utf8(pending) {
        Ok(text) => {
            let body = json!({"text": text});
            pending.clear();
            Some(body)
        }
        Err(error) if error.error_len().is_none() && !flush => {
            let valid = error.valid_up_to();
            if valid == 0 {
                return None;
            }
            let text = String::from_utf8(pending[..valid].to_vec()).ok()?;
            pending.drain(..valid);
            Some(json!({"text": text}))
        }
        Err(_) => {
            let body = json!({"b64": STANDARD.encode(&pending[..])});
            pending.clear();
            Some(body)
        }
    }
}

fn paint(snapshot: &Value) {
    let screen = snapshot["screen"].as_str().unwrap_or("");
    let mut out = String::from("\x1b[0m\x1b[H\x1b[2J");
    out.push_str(&screen.split('\n').collect::<Vec<_>>().join("\r\n"));
    let row = snapshot["cursor_row"].as_u64().unwrap_or(0) + 1;
    let col = snapshot["cursor_col"].as_u64().unwrap_or(0) + 1;
    out.push_str(&format!("\x1b[{row};{col}H"));
    let mut stdout = std::io::stdout().lock();
    let _ = stdout.write_all(out.as_bytes());
    let _ = stdout.flush();
}

fn parse(args: &[String]) -> Result<(Session, u8), String> {
    let mut hub = std::env::var("FM_STREAM_HUB").unwrap_or_default();
    let mut endpoint = String::new();
    let mut token_file = String::new();
    let mut detach = "C-]".to_owned();
    let mut index = 0;
    while index < args.len() {
        let value = args
            .get(index + 1)
            .cloned()
            .ok_or_else(|| format!("{} needs a value", args[index]))?;
        match args[index].as_str() {
            "--hub" => hub = value,
            "--endpoint" => endpoint = value,
            "--token-file" => token_file = value,
            "--detach-key" => detach = value,
            other => return Err(format!("unknown option {other}")),
        }
        index += 2;
    }
    if hub.is_empty() || endpoint.is_empty() {
        return Err("needs --hub URL and --endpoint ID".into());
    }
    if !fm_stream_wire::is_endpoint_id(&endpoint) {
        return Err(format!("{endpoint:?} is not an endpoint id"));
    }
    let token = if token_file.is_empty() {
        std::env::var("FM_STREAM_TOKEN").unwrap_or_default()
    } else {
        std::fs::read_to_string(&token_file)
            .map_err(|e| format!("cannot read {token_file}: {e}"))?
            .trim()
            .to_owned()
    };
    if token.is_empty() {
        return Err("no hub token; pass --token-file or set FM_STREAM_TOKEN".into());
    }
    let client = Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(None)
        .build()
        .map_err(|_| "HTTP client initialization failed".to_owned())?;
    let session = Session {
        hub: hub.trim_end_matches('/').to_owned(),
        token,
        endpoint,
        client,
    };
    Ok((session, detach_byte(&detach)?))
}

pub fn run(args: &[String]) -> Result<(), String> {
    let (session, detach) = parse(args)?;
    // SAFETY: isatty only inspects the descriptor.
    if unsafe { libc::isatty(0) } != 1 {
        return Err("interactive attach needs a terminal on stdin".into());
    }
    let resized = Arc::new(AtomicBool::new(false));
    let stop = Arc::new(AtomicBool::new(false));
    for (signal, flag) in [
        (signal_hook::consts::SIGWINCH, &resized),
        (signal_hook::consts::SIGINT, &stop),
        (signal_hook::consts::SIGTERM, &stop),
        (signal_hook::consts::SIGHUP, &stop),
    ] {
        signal_hook::flag::register(signal, flag.clone()).map_err(|e| e.to_string())?;
    }
    if std::env::var("FM_STREAM_ATTACH_LOCAL").as_deref() != Ok("0") {
        if let Some(stream) = connect_local(&session.endpoint) {
            if let Some((snapshot, reader, writer)) = handshake(&session.endpoint, stream)? {
                return run_local(
                    session.endpoint,
                    snapshot,
                    reader,
                    writer,
                    detach,
                    resized,
                    stop,
                );
            }
        }
    }
    let (status, task) = session.json("GET", &session.task_path(""), None)?;
    if status != 200 {
        return Err(format!(
            "the hub refused endpoint {}: {}",
            session.endpoint,
            task["message"].as_str().unwrap_or("unknown error")
        ));
    }
    if !task["task"]["closed_at"].is_null() {
        return Err(format!("endpoint {} has closed", session.endpoint));
    }
    let mut resize_supported = true;
    if let Some((rows, cols)) = local_size() {
        resize_supported = session.resize(rows, cols)?;
    }
    // The snapshot route is the native hub's; the Python rollback hub has
    // only /screen, and then the stream starts from "now" instead of from
    // exactly the painted offset.
    let (status, mut snapshot) = session.json("GET", &session.task_path("/snapshot"), None)?;
    let stream_path = if status == 200 {
        format!(
            "{}?from={}",
            session.task_path("/stream"),
            snapshot["stream_offset"].as_u64().unwrap_or(0)
        )
    } else {
        let (_, screen) = session.json("GET", &session.task_path("/screen?format=ansi"), None)?;
        snapshot = screen;
        session.task_path("/stream")
    };
    let stream = session.request("GET", &stream_path, None)?;
    if !stream.status().is_success() {
        let status = stream.status().as_u16();
        let body = stream.json::<Value>().unwrap_or(Value::Null);
        return Err(format!(
            "the hub refused the output stream: HTTP {status}: {}",
            body["message"].as_str().unwrap_or("unknown error")
        ));
    }

    let raw = RawMode::enter()?;
    paint(&snapshot);
    let session = Arc::new(session);
    let (events, inbox) = mpsc::channel::<Event>();

    // Output: the endpoint's bytes, verbatim, from the painted offset on.
    {
        let events = events.clone();
        let output = raw.output.clone();
        std::thread::spawn(move || {
            let mut reader = BufReader::new(stream);
            let mut line = String::new();
            let mut stdout = std::io::stdout();
            loop {
                line.clear();
                match reader.read_line(&mut line) {
                    Ok(0) | Err(_) => {
                        let _ = events.send(Event::Lost("the hub closed the output stream".into()));
                        return;
                    }
                    Ok(_) => (),
                }
                let Some(data) = line.trim_end().strip_prefix("data: ") else {
                    continue;
                };
                let Ok(record) = serde_json::from_str::<Value>(data) else {
                    continue;
                };
                if let Some(bytes) = record["b64"].as_str().and_then(|b| STANDARD.decode(b).ok()) {
                    let active = output.lock().unwrap();
                    if !*active {
                        return;
                    }
                    let _ = stdout.write_all(&bytes);
                    let _ = stdout.flush();
                } else if let Some(error) = record["error"].as_str() {
                    let _ = events.send(Event::Lost(format!(
                        "output stream {error}: {}",
                        record["message"].as_str().unwrap_or("unknown error")
                    )));
                    return;
                } else if record["closed"] == true {
                    let _ = events.send(Event::Closed(record["exit_code"].clone()));
                    return;
                }
            }
        });
    }

    // Input: read raw bytes, stop at the detach key, coalesce while a send
    // is in flight so a burst of keys becomes one hub command.
    let (keys, keyed) = mpsc::channel::<Input>();
    {
        let events = events.clone();
        let keys = keys.clone();
        std::thread::spawn(move || {
            let mut stdin = std::io::stdin().lock();
            let mut buffer = [0u8; 4096];
            loop {
                match stdin.read(&mut buffer) {
                    Ok(0) | Err(_) => {
                        let _ =
                            events.send(Event::Detaching(Instant::now() + Duration::from_secs(2)));
                        let _ = keys.send(Input::Detach);
                        return;
                    }
                    Ok(n) => {
                        let chunk = &buffer[..n];
                        if let Some(at) = chunk.iter().position(|b| *b == detach) {
                            if at > 0 {
                                let _ = keys.send(Input::Bytes(chunk[..at].to_vec()));
                            }
                            let _ = events
                                .send(Event::Detaching(Instant::now() + Duration::from_secs(2)));
                            let _ = keys.send(Input::Detach);
                            return;
                        }
                        let _ = keys.send(Input::Bytes(chunk.to_vec()));
                    }
                }
            }
        });
    }
    {
        let session = session.clone();
        let events = events.clone();
        std::thread::spawn(move || {
            let mut pending = Vec::new();
            while let Ok(first) = keyed.recv() {
                let mut draining = false;
                match first {
                    Input::Bytes(bytes) => pending.extend(bytes),
                    Input::Detach => draining = true,
                }
                while !draining {
                    match keyed.try_recv() {
                        Ok(Input::Bytes(bytes)) => pending.extend(bytes),
                        Ok(Input::Detach) => draining = true,
                        Err(_) => break,
                    }
                }
                while let Some(body) = payload(&mut pending, draining) {
                    match session.json("POST", &session.task_path("/input"), Some(&body)) {
                        Ok((status, _)) if (200..300).contains(&status) => (),
                        Ok((status, _)) => {
                            let _ = events.send(Event::Lost(format!(
                                "input delivery failed: HTTP {status}; not retried"
                            )));
                            return;
                        }
                        Err(reason) => {
                            let _ = events.send(Event::Lost(format!(
                                "input delivery uncertain: {reason}; not retried"
                            )));
                            return;
                        }
                    }
                }
                if draining {
                    let _ = events.send(Event::Detach);
                    return;
                }
            }
        });
    }

    {
        let session = session.clone();
        let stop = stop.clone();
        let events = events.clone();
        std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) {
                if resized.swap(false, Ordering::SeqCst) && resize_supported {
                    if let Some((rows, cols)) = local_size() {
                        match session.resize(rows, cols) {
                            Ok(supported) => resize_supported = supported,
                            Err(reason) => {
                                let _ = events.send(Event::Lost(reason));
                                return;
                            }
                        }
                    }
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        });
    }
    let outcome = await_outcome(&inbox, &stop, || {
        let _ = keys.send(Input::Detach);
    });
    conclude(outcome, &stop, raw, &session.endpoint)
}

/// Wait for the session's outcome. A signal starts a bounded detach drain.
fn await_outcome(inbox: &mpsc::Receiver<Event>, stop: &AtomicBool, detach: impl Fn()) -> Event {
    let mut drain_until = None;
    loop {
        if stop.load(Ordering::SeqCst) && drain_until.is_none() {
            drain_until = Some(Instant::now() + Duration::from_secs(2));
            detach();
        }
        if drain_until.is_some_and(|until| Instant::now() >= until) {
            break Event::Lost(
                "input delivery uncertain: detach drain timed out; not retried".into(),
            );
        }
        match inbox.recv_timeout(Duration::from_millis(50)) {
            Ok(Event::Detaching(until)) => {
                drain_until = Some(drain_until.map_or(until, |current| current.min(until)));
            }
            Ok(event) => break event,
            Err(mpsc::RecvTimeoutError::Timeout) => (),
            Err(mpsc::RecvTimeoutError::Disconnected) => break Event::Lost("internal".into()),
        }
    }
}

/// Restore the terminal, say why the session ended, and exit with it.
fn conclude(outcome: Event, stop: &AtomicBool, raw: RawMode, endpoint: &str) -> ! {
    stop.store(true, Ordering::SeqCst);
    drop(raw);
    let mut stdout = std::io::stdout();
    let (message, code) = match outcome {
        Event::Detach => (
            format!("\r\n[detached from {endpoint}; it keeps running]\r\n"),
            0,
        ),
        Event::Closed(exit) => (
            format!("\r\n[endpoint closed, exit {exit}]\r\n"),
            exit_status(&exit),
        ),
        Event::Lost(reason) => (format!("\r\n[{reason}]\r\n"), 1),
        Event::Detaching(_) => unreachable!(),
    };
    let _ = stdout.write_all(message.as_bytes());
    let _ = stdout.flush();
    // Reader threads may still be blocked in read(); exiting ends them.
    std::process::exit(code);
}

/// The endpoint's own agent, when it runs on this machine as this user.
fn connect_local(endpoint: &str) -> Option<UnixStream> {
    let path = local::socket_path(endpoint)?;
    // SAFETY: geteuid has no preconditions.
    let euid = unsafe { libc::geteuid() };
    if !std::fs::symlink_metadata(&path).is_ok_and(|m| m.uid() == euid) {
        return None;
    }
    let stream = UnixStream::connect(&path).ok()?;
    local::same_user(&stream).then_some(stream)
}

fn message_of(payload: &[u8]) -> String {
    serde_json::from_slice::<Value>(payload)
        .ok()
        .and_then(|v| v["message"].as_str().map(str::to_owned))
        .unwrap_or_else(|| "unknown error".into())
}

type Handshake = (Value, UnixStream, Arc<Mutex<UnixStream>>);

/// Hello, with the local size so the agent resizes before its snapshot. An
/// agent's definitive answer (closed, refused) ends the attach; one that does
/// not answer sends the client to the hub path instead (Ok(None)).
fn handshake(endpoint: &str, stream: UnixStream) -> Result<Option<Handshake>, String> {
    let Ok(mut reader) = stream.try_clone() else {
        return Ok(None);
    };
    let mut writer = stream;
    let mut hello = json!({ "endpoint": endpoint });
    if let Some((rows, cols)) = local_size() {
        hello["rows"] = json!(rows);
        hello["cols"] = json!(cols);
    }
    if local::write_frame(&mut writer, b'H', hello.to_string().as_bytes()).is_err()
        || reader
            .set_read_timeout(Some(Duration::from_secs(3)))
            .is_err()
    {
        return Ok(None);
    }
    let snapshot = match local::read_frame(&mut reader) {
        Ok(Some((b'S', payload))) => match serde_json::from_slice::<Value>(&payload) {
            Ok(snapshot) => snapshot,
            Err(_) => return Ok(None),
        },
        Ok(Some((b'C', _))) => return Err(format!("endpoint {endpoint} has closed")),
        Ok(Some((b'E', payload))) => {
            return Err(format!(
                "the local agent refused endpoint {endpoint}: {}",
                message_of(&payload)
            ))
        }
        _ => return Ok(None),
    };
    if reader.set_read_timeout(None).is_err() {
        return Ok(None);
    }
    Ok(Some((snapshot, reader, Arc::new(Mutex::new(writer)))))
}

/// The same session as the hub path, over the agent's local socket: output
/// frames written as they arrive, input written straight to the agent, and a
/// detach that waits for the agent to confirm it has written everything typed
/// before it.
fn run_local(
    endpoint: String,
    snapshot: Value,
    mut reader: UnixStream,
    writer: Arc<Mutex<UnixStream>>,
    detach: u8,
    resized: Arc<AtomicBool>,
    stop: Arc<AtomicBool>,
) -> Result<(), String> {
    let raw = RawMode::enter()?;
    paint(&snapshot);
    let (events, inbox) = mpsc::channel::<Event>();
    let detaching = Arc::new(AtomicBool::new(false));
    let begin_detach = {
        let writer = writer.clone();
        let events = events.clone();
        let detaching = detaching.clone();
        move || {
            begin_local_detach(&writer, &events, &detaching);
        }
    };

    {
        let events = events.clone();
        let output = raw.output.clone();
        let detaching = detaching.clone();
        std::thread::spawn(move || local_output(&mut reader, output, events, detaching));
    }

    {
        let events = events.clone();
        let writer = writer.clone();
        let detaching = detaching.clone();
        let begin_detach = begin_detach.clone();
        std::thread::spawn(move || {
            let mut stdin = std::io::stdin().lock();
            let mut buffer = [0u8; 4096];
            loop {
                let (chunk, last) = match stdin.read(&mut buffer) {
                    Ok(0) | Err(_) => (&buffer[..0], true),
                    Ok(n) => match buffer[..n].iter().position(|b| *b == detach) {
                        Some(at) => (&buffer[..at], true),
                        None => (&buffer[..n], false),
                    },
                };
                if !chunk.is_empty() {
                    let mut writer = writer.lock().unwrap();
                    if detaching.load(Ordering::SeqCst) {
                        return;
                    }
                    if local::write_frame(&mut *writer, b'I', chunk).is_err() {
                        let _ = events.send(Event::Lost(
                            "input delivery failed: the local agent connection closed; not retried"
                                .into(),
                        ));
                        return;
                    }
                }
                if last {
                    begin_detach();
                    return;
                }
            }
        });
    }

    {
        let stop = stop.clone();
        let writer = writer.clone();
        let detaching = detaching.clone();
        std::thread::spawn(move || {
            while !stop.load(Ordering::SeqCst) && !detaching.load(Ordering::SeqCst) {
                if resized.swap(false, Ordering::SeqCst) {
                    if let Some((rows, cols)) = local_size() {
                        let body = json!({ "rows": rows, "cols": cols }).to_string();
                        let mut writer = writer.lock().unwrap();
                        if detaching.load(Ordering::SeqCst) {
                            return;
                        }
                        let _ = local::write_frame(&mut *writer, b'Z', body.as_bytes());
                    }
                }
                std::thread::sleep(Duration::from_millis(50));
            }
        });
    }
    let outcome = await_outcome(&inbox, &stop, begin_detach);
    conclude(outcome, &stop, raw, &endpoint)
}

fn begin_local_detach(
    writer: &Arc<Mutex<UnixStream>>,
    events: &mpsc::Sender<Event>,
    detaching: &AtomicBool,
) {
    if !detaching.swap(true, Ordering::SeqCst) {
        let _ = events.send(Event::Detaching(Instant::now() + Duration::from_secs(2)));
        let writer = writer.clone();
        std::thread::spawn(move || {
            let _ = writer.lock().unwrap().shutdown(std::net::Shutdown::Write);
        });
    }
}

fn local_output(
    reader: &mut UnixStream,
    output: Arc<Mutex<bool>>,
    events: mpsc::Sender<Event>,
    detaching: Arc<AtomicBool>,
) {
    let mut stdout = std::io::stdout();
    loop {
        match local::read_frame(reader) {
            Ok(Some((b'O', bytes))) => {
                let active = output.lock().unwrap();
                if !*active {
                    return;
                }
                let _ = stdout.write_all(&bytes);
                let _ = stdout.flush();
            }
            Ok(Some((b'C', payload))) => {
                let exit = serde_json::from_slice::<Value>(&payload)
                    .map(|v| v["exit_code"].clone())
                    .unwrap_or(Value::Null);
                let _ = events.send(Event::Closed(exit));
                return;
            }
            Ok(Some((b'E', payload))) => {
                let _ = events.send(Event::Lost(format!(
                    "local agent: {}",
                    message_of(&payload)
                )));
                return;
            }
            Ok(Some((b'A', payload))) if payload.is_empty() && detaching.load(Ordering::SeqCst) => {
                let _ = events.send(Event::Detach);
                return;
            }
            Ok(Some(_)) => (),
            Ok(None) | Err(_) => {
                let reason = if detaching.load(Ordering::SeqCst) {
                    "input delivery uncertain: the local agent disconnected before drain acknowledgement; not retried"
                } else {
                    "the local agent closed the connection"
                };
                let _ = events.send(Event::Lost(reason.into()));
                return;
            }
        }
    }
}

fn exit_status(exit: &Value) -> i32 {
    match exit.as_i64() {
        Some(code @ 0..=255) => code as i32,
        Some(signal @ -127..=-1) => 128 - signal as i32,
        _ => 1,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_signal_drain_deadline_does_not_wait_for_the_input_writer() {
        let (stream, _peer) = UnixStream::pair().unwrap();
        let writer = Arc::new(Mutex::new(stream));
        let held = writer.lock().unwrap();
        let detaching = Arc::new(AtomicBool::new(false));
        let (events, inbox) = mpsc::channel();
        let (done, finished) = mpsc::channel();
        let worker = {
            let writer = writer.clone();
            let detaching = detaching.clone();
            std::thread::spawn(move || {
                let started = Instant::now();
                let outcome = await_outcome(&inbox, &AtomicBool::new(true), || {
                    begin_local_detach(&writer, &events, &detaching);
                });
                done.send((outcome, started.elapsed())).unwrap();
            })
        };
        let result = finished.recv_timeout(Duration::from_secs(3));
        drop(held);
        worker.join().unwrap();
        let (outcome, elapsed) = result.unwrap();
        assert!(matches!(outcome, Event::Lost(reason) if reason.contains("drain timed out")));
        assert!(elapsed < Duration::from_secs(3));
        assert!(detaching.load(Ordering::SeqCst));
    }

    #[test]
    fn only_an_explicit_acknowledgement_confirms_a_local_drain() {
        for ack in [false, true] {
            let (mut reader, mut server) = UnixStream::pair().unwrap();
            let (events, inbox) = mpsc::channel();
            let detaching = Arc::new(AtomicBool::new(true));
            if ack {
                local::write_frame(&mut server, b'A', b"").unwrap();
            }
            drop(server);
            local_output(&mut reader, Arc::new(Mutex::new(true)), events, detaching);
            let outcome = inbox.recv().unwrap();
            if ack {
                assert!(matches!(outcome, Event::Detach));
            } else {
                assert!(matches!(outcome, Event::Lost(reason) if reason.contains("uncertain")));
            }
        }
        let (mut reader, mut server) = UnixStream::pair().unwrap();
        server.write_all(b"A\0\0").unwrap();
        drop(server);
        let (events, inbox) = mpsc::channel();
        local_output(
            &mut reader,
            Arc::new(Mutex::new(true)),
            events,
            Arc::new(AtomicBool::new(true)),
        );
        assert!(
            matches!(inbox.recv().unwrap(), Event::Lost(reason) if reason.contains("uncertain"))
        );
    }

    #[test]
    fn detach_keys_map_to_control_bytes() {
        assert_eq!(detach_byte("C-]").unwrap(), 0x1d);
        assert_eq!(detach_byte("C-\\").unwrap(), 0x1c);
        assert_eq!(detach_byte("C-a").unwrap(), 0x01);
        assert!(detach_byte("x").is_err());
        assert!(detach_byte("^]").is_err());
    }

    #[test]
    fn endpoint_status_is_propagated() {
        assert_eq!(exit_status(&json!(7)), 7);
        assert_eq!(exit_status(&json!(0)), 0);
        assert_eq!(exit_status(&json!(-15)), 143);
        assert_eq!(exit_status(&Value::Null), 1);
    }

    #[test]
    fn input_is_text_until_it_cannot_be() {
        let mut pending = "héllo\x1b[A".as_bytes().to_vec();
        assert_eq!(
            payload(&mut pending, false),
            Some(json!({"text": "héllo\x1b[A"}))
        );
        // A split multibyte character waits for its tail.
        let mut pending = vec![b'a', 0xc3];
        assert_eq!(payload(&mut pending, false), Some(json!({"text": "a"})));
        assert_eq!(pending, vec![0xc3]);
        assert_eq!(payload(&mut pending, false), None);
        pending.push(0xa9);
        assert_eq!(payload(&mut pending, false), Some(json!({"text": "é"})));
        // Bytes that are not UTF-8 go raw.
        let mut pending = vec![0xff, b'x'];
        assert_eq!(payload(&mut pending, false), Some(json!({"b64": "/3g="})));
        assert!(pending.is_empty());
        let mut pending = vec![0xc3];
        assert_eq!(payload(&mut pending, true), Some(json!({"b64": "ww=="})));
        assert!(pending.is_empty());
    }
}
