//! Independent pilot port. The Python deployment remains the default.
mod command_value;
mod pty;
use base64::Engine;
use fm_stream_wire::{is_machine_name, protocol_of_health, HUB_PROTOCOL};
use pty::Pty;
use reqwest::blocking::Client;
use serde_json::{json, Value};
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

#[derive(Debug)]
enum Error {
    Superseded,
    Forgotten,
    Rejected,
    Other(String),
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Superseded => write!(f, "endpoint superseded"),
            Self::Forgotten => write!(f, "hub forgot endpoint"),
            Self::Rejected => write!(f, "command result rejected"),
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
    ) -> Result<Value, Error> {
        let timeout = match *self.deadline.lock().unwrap() {
            Some(until) => timeout.min(
                until
                    .checked_duration_since(Instant::now())
                    .ok_or_else(|| Error::Other("startup budget exhausted".into()))?,
            ),
            None => timeout,
        };
        let mut request = self
            .client
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
        let answer: Value = if bytes.is_empty() {
            json!({})
        } else {
            serde_json::from_slice(&bytes)
                .map_err(|_| Error::Other("hub returned malformed JSON".into()))?
        };
        if !status.is_success() {
            return Err(match answer["error"].as_str().unwrap_or("") {
                "endpoint_superseded" | "duplicate_label" => Error::Superseded,
                "no_such_endpoint" => Error::Forgotten,
                "no_such_command"
                | "result_conflict"
                | "bad_command_id"
                | "endpoint_unauthorized" => Error::Rejected,
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
            if !number.is_finite() || number <= 0.0 || number > 86400.0 {
                return Err(Error::Other(format!(
                    "--{name} must be finite and in (0, 86400]"
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
    registration: Mutex<Registration>,
    result_deadline: Mutex<Option<Instant>>,
}
impl Agent {
    fn registration(&self) -> Value {
        json!({"endpoint_id":self.id,"machine":self.options.machine,"label":self.options.label,"cwd":self.options.cwd,"rows":self.options.rows,"cols":self.options.cols,"capabilities":[CAPABILITY],"protocol":HUB_PROTOCOL})
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
    }
    fn stand_down(&self) {
        self.stood_down.store(true, Ordering::SeqCst);
        self.wake.notify();
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
            Err(_) => {
                registration.backoff = (registration.backoff * 2.0).min(60.0);
                return false;
            }
        }
        drop(registration);
        self.wake.notify();
        let _ = self.initial_state();
        true
    }
    fn frames(&self, frame: Value) {
        let closing = frame["closed"] == true;
        if self.stood_down.load(Ordering::SeqCst) && !closing {
            return;
        }
        let body = json!({"machine":self.options.machine,"frames":[frame]});
        for attempt in 0..2 {
            match self.hub.call(
                "POST",
                "/v1/agent/frames",
                Some(&body),
                Duration::from_secs(30),
            ) {
                Ok(_) => return,
                Err(Error::Forgotten) if attempt == 0 && self.recover(closing) => continue,
                Err(Error::Superseded) => self.stand_down(),
                Err(_) => (),
            }
            return;
        }
    }
    fn reader(&self) {
        let mut buffer = [0u8; 65536];
        while !self.reader_stop.load(Ordering::SeqCst) {
            match self.pty.read(&mut buffer) {
                Ok(Some(0)) => break,
                Ok(Some(n)) => self.frames(json!({"endpoint_id":self.id,"b64":base64::engine::general_purpose::STANDARD.encode(&buffer[..n])})),
                Ok(None) => (),
                Err(e) if e.kind() == std::io::ErrorKind::Interrupted => (),
                Err(_) => break,
            }
        }
        self.halt();
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
    fn apply(&self, command: &Value) -> Result<(), Error> {
        let payload = &command["payload"];
        match command["kind"].as_str().unwrap_or("") {
            "input" => {
                let mut bytes = Vec::new();
                if !payload["text"].is_null() {
                    bytes.extend_from_slice(
                        command_value::python_str(&payload["text"])
                            .as_bytes(),
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
                    command_value::python_str(&payload["note"])
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
    fn acknowledge(&self, command: &Value, result: Result<(), Error>) {
        let body = json!({"machine":self.options.machine,"command_id":command["command_id"],"ok":result.is_ok(),"error":result.err().map(|e| e.to_string()).unwrap_or_default()});
        let deadline = Instant::now() + Duration::from_secs(RESULT_RETRY_SECS);
        let mut backoff: f64 = 2.0;
        loop {
            let attempted = Instant::now();
            match self.hub.call(
                "POST",
                "/v1/agent/results",
                Some(&body),
                Duration::from_secs(RESULT_POST_SECS),
            ) {
                Ok(_) | Err(Error::Rejected) => return,
                Err(_) => (),
            }
            let until = self
                .result_deadline
                .lock()
                .unwrap()
                .unwrap_or(deadline)
                .min(deadline);
            if attempted >= until {
                return;
            }
            if Instant::now() >= until {
                continue;
            } // One final attempt after deadline.
              // Stop must not discard an applied result. Shutdown's deadline, not
              // process presence, bounds reconciliation; wake on deadline publication.
            self.wake.wait(
                self.wake.snapshot(),
                backoff.min(
                    until
                        .saturating_duration_since(Instant::now())
                        .as_secs_f64(),
                ),
                &AtomicBool::new(false),
            );
            backoff = (backoff * 2.0).min(60.0);
        }
    }
    fn commands(&self) {
        let path = format!(
            "/v1/agent/commands?machine={}&endpoint={}&wait={}",
            self.options.machine, self.id, self.options.poll_secs as u64
        );
        let mut backoff: f64 = 2.0;
        while !self.stop.load(Ordering::SeqCst) && !self.stood_down.load(Ordering::SeqCst) {
            let generation = self.wake.snapshot();
            match self.hub.call(
                "GET",
                &path,
                None,
                Duration::from_secs_f64(self.options.poll_secs + 15.0),
            ) {
                Ok(answer) => {
                    backoff = 2.0;
                    if let Some(commands) = answer["commands"].as_array() {
                        for command in commands {
                            self.acknowledge(command, self.apply(command));
                        }
                    }
                }
                Err(Error::Superseded) => {
                    self.stand_down();
                    return;
                }
                Err(_) => {
                    if self.wake.wait(generation, backoff, &self.stop) {
                        backoff = 2.0;
                    } else {
                        backoff = (backoff * 2.0).min(60.0);
                    }
                }
            }
        }
    }
    fn abandon(&self) {
        let _ = self.pty.close(true);
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
        while !self.stop.load(Ordering::SeqCst) {
            std::thread::sleep(Duration::from_millis(50));
        }
        *self.result_deadline.lock().unwrap() =
            Some(Instant::now() + Duration::from_secs(RESULT_RETRY_SECS));
        self.wake.notify();
        // A signal must stop the child promptly, even during result retries.
        let close = self.pty.close(false);
        let _ = commands.join();
        let _ = heartbeat.join();
        self.reader_stop.store(true, Ordering::SeqCst);
        let _ = reader.join(); // No descriptor release while a read can name it.
        close?;
        let exit = self.pty.exit_code()?;
        if exit.is_none() {
            return Err(Error::Other(
                "child exit unconfirmed; refusing final close".into(),
            ));
        }
        self.frames(json!({"endpoint_id":self.id,"closed":true,"exit_code":exit,"state":{"alive":false,"foreground":[],"cwd":"","published_at":now()}}));
        Ok(())
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
        client: Client::builder()
            .redirect(reqwest::redirect::Policy::none())
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
    let pty = Pty::spawn(&options.cwd, options.rows, options.cols, &id, &options.hub)?;
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
        registration: Mutex::new(Registration {
            not_before: Instant::now(),
            backoff: 2.0,
        }),
        result_deadline: Mutex::new(None),
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
    // Like Python, unlinkable startup diagnostic captures must not grow for life.
    let null = OpenOptions::new().write(true).open("/dev/null")?;
    use std::os::fd::AsRawFd;
    // SAFETY: null is live through both dup2 calls; only this agent's output changes.
    unsafe {
        libc::dup2(null.as_raw_fd(), 1);
        libc::dup2(null.as_raw_fd(), 2);
    }
    *agent.hub.deadline.lock().unwrap() = None;
    agent.run()
}
fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.iter().any(|arg| arg == "--help" || arg == "-h") {
        println!("fm-stream-agent serve --hub URL --token-file PATH --machine NAME --label NAME --cwd DIR\n  [--status-path PATH] [--ready-file PATH] [--rows N] [--cols N]\n  [--state-interval SECS] [--poll-secs SECS]\nfm-stream-agent --protocol | --version");
        return;
    }
    match args.first().map(String::as_str) {
        Some("--protocol") => println!("{HUB_PROTOCOL}"),
        Some("--version") => println!("{}", env!("CARGO_PKG_VERSION")),
        Some("serve") => {
            if let Err(error) = serve(&args[1..]) {
                eprintln!("fm-stream-agent: {error}");
                std::process::exit(1);
            }
        }
        _ => {
            println!("fm-stream-agent serve --hub URL --token-file PATH --machine NAME --label NAME --cwd DIR\n  [--status-path PATH] [--ready-file PATH] [--rows N] [--cols N]\n  [--state-interval SECS] [--poll-secs SECS]\nfm-stream-agent --protocol | --version");
            if args.first().is_none_or(|a| a != "--help" && a != "-h") {
                std::process::exit(2);
            }
        }
    }
}
