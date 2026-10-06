//! Same-machine attach: a private unix socket per endpoint, so an interactive
//! attach on the agent's own machine never pays the hub round trip.
//!
//! The agent keeps its own copy of the hub's small VT model (the hub's
//! screen.rs, compiled in here) fed with exactly the bytes it publishes, so a
//! local attach paints the same kind of snapshot the hub's /snapshot route
//! returns, then streams from exactly where that screen ends. The socket lives
//! at `<dir>/<endpoint-id>.sock`, where `<dir>` is `$FM_STREAM_LOCAL_DIR` or
//! `/tmp/fm-stream-<uid>`: a 0700 directory this user owns (anything else and
//! neither side uses it), the socket itself 0600, and every connection's peer
//! must be this same user. docs/stream-backend.md "Interactive attach" owns the
//! operator contract.
//!
//! Wire: frames of `[tag u8][len u32 big-endian][payload]`.
//!   client -> agent  H {"endpoint","rows","cols"}  hello, sent once, first
//!                    I <bytes>                      input for the pty
//!                    Z {"rows","cols"}              resize
//!   agent -> client  S {"screen","cursor_row","cursor_col"}
//!                    O <bytes>                      output, in order
//!                    C {"exit_code"}                the endpoint closed
//!                    E {"message"}                  refusal or failure
//!                    A <empty>                      input drain acknowledgement
#[allow(dead_code)]
#[path = "../../fm-stream-hub/src/screen.rs"]
mod screen;

use screen::Screen;
use serde_json::{json, Value};
use std::collections::VecDeque;
use std::fs;
use std::io::{self, Read, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, MetadataExt, PermissionsExt};
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::mpsc::{sync_channel, Receiver, SyncSender};
use std::sync::{Arc, Mutex};

/// Largest frame either side accepts; output is published in chunks this size.
pub const MAX_FRAME: usize = 1 << 20;
/// Output chunks a slow client may have queued before it is cut off, so a
/// stalled local terminal can never stall the endpoint itself.
const QUEUE: usize = 4096;
/// Raw output kept to replay an escape or UTF-8 sequence the screen has not
/// finished parsing when a client attaches.
const TAIL: usize = 65536;

fn euid() -> u32 {
    // SAFETY: geteuid has no preconditions.
    unsafe { libc::geteuid() }
}

pub fn dir() -> PathBuf {
    match std::env::var_os("FM_STREAM_LOCAL_DIR").filter(|d| !d.is_empty()) {
        Some(dir) => PathBuf::from(dir),
        None => PathBuf::from(format!("/tmp/fm-stream-{}", euid())),
    }
}

/// The directory only counts when this user owns it and nobody else can enter
/// it; a directory someone else planted disables the local path rather than
/// trusting it.
fn private(dir: &Path) -> bool {
    fs::symlink_metadata(dir)
        .is_ok_and(|m| m.is_dir() && m.uid() == euid() && m.mode() & 0o077 == 0)
}

pub fn socket_path(endpoint: &str) -> Option<PathBuf> {
    if !fm_stream_wire::is_endpoint_id(endpoint) {
        return None;
    }
    let dir = dir();
    private(&dir).then(|| dir.join(format!("{endpoint}.sock")))
}

pub fn write_frame(out: &mut impl Write, tag: u8, payload: &[u8]) -> io::Result<()> {
    let mut frame = Vec::with_capacity(5 + payload.len());
    frame.push(tag);
    frame.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    frame.extend_from_slice(payload);
    out.write_all(&frame)
}

/// One frame, or None on a clean end of stream between frames.
pub fn read_frame(input: &mut impl Read) -> io::Result<Option<(u8, Vec<u8>)>> {
    let mut head = [0u8; 5];
    let mut got = 0;
    while got < head.len() {
        match input.read(&mut head[got..]) {
            Ok(0) if got == 0 => return Ok(None),
            Ok(0) => return Err(io::ErrorKind::UnexpectedEof.into()),
            Ok(n) => got += n,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => (),
            Err(e) => return Err(e),
        }
    }
    let len = u32::from_be_bytes([head[1], head[2], head[3], head[4]]) as usize;
    if len > MAX_FRAME {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "oversized frame",
        ));
    }
    let mut payload = vec![0u8; len];
    input.read_exact(&mut payload)?;
    Ok(Some((head[0], payload)))
}

pub fn error(message: &str) -> Vec<u8> {
    json!({ "message": message }).to_string().into_bytes()
}

/// Whether the connected peer is this same user.
pub fn same_user(stream: &UnixStream) -> bool {
    peer_uid(stream).is_some_and(|uid| uid == euid())
}

#[cfg(any(target_os = "linux", target_os = "android"))]
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    // SAFETY: ucred is plain data and getsockopt writes at most `len` bytes.
    let mut cred: libc::ucred = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::ucred>() as libc::socklen_t;
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_PEERCRED,
            (&mut cred as *mut libc::ucred).cast(),
            &mut len,
        )
    };
    (rc == 0).then_some(cred.uid)
}

#[cfg(not(any(target_os = "linux", target_os = "android")))]
fn peer_uid(stream: &UnixStream) -> Option<u32> {
    let (mut uid, mut gid) = (0, 0);
    // SAFETY: the descriptor is live for the call; both outputs are locals.
    (unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } == 0).then_some(uid)
}

enum Message {
    Output(Arc<[u8]>),
    Closed(Value),
    Drained,
    Error(String),
}

#[derive(Debug)]
struct Connection {
    stream: UnixStream,
    stopped: AtomicBool,
}
impl Connection {
    fn stop(&self) {
        self.stopped.store(true, Ordering::SeqCst);
        hang_up(&self.stream);
    }
}

struct Inner {
    screen: Screen,
    tail: VecDeque<u8>,
    subscribers: Vec<(Arc<Connection>, SyncSender<Message>)>,
    closed: Option<Value>,
}

/// The agent's side: its screen copy, its subscribers, and its socket.
pub struct Local {
    inner: Mutex<Inner>,
    path: Mutex<Option<PathBuf>>,
}

impl Local {
    pub fn new(rows: u16, cols: u16) -> Self {
        let screen = Screen::try_new(rows.max(1) as usize, cols.max(1) as usize)
            .unwrap_or_else(|_| Screen::try_new(40, 200).expect("default screen"))
            .without_history();
        Self {
            inner: Mutex::new(Inner {
                screen,
                tail: VecDeque::new(),
                subscribers: Vec::new(),
                closed: None,
            }),
            path: Mutex::new(None),
        }
    }

    /// Bind `<dir>/<endpoint>.sock`. Failure only means no local fast path.
    pub fn listen(&self, endpoint: &str) -> Option<UnixListener> {
        let dir = dir();
        if fs::symlink_metadata(&dir).is_err() {
            let _ = fs::DirBuilder::new().mode(0o700).create(&dir);
        }
        let path = socket_path(endpoint)?;
        let _ = fs::remove_file(&path);
        let listener = UnixListener::bind(&path).ok()?;
        if fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).is_err() {
            let _ = fs::remove_file(&path);
            return None;
        }
        *self.path.lock().unwrap() = Some(path);
        Some(listener)
    }

    /// Every output byte the agent publishes, in publication order. Clients
    /// get it before the screen parses it; both happen under one lock, so a
    /// snapshot never misses or repeats a byte of the stream that follows it.
    pub fn feed(&self, bytes: &[u8]) {
        let mut inner = self.inner.lock().unwrap();
        if !inner.subscribers.is_empty() {
            let chunk: Arc<[u8]> = bytes.into();
            inner.subscribers.retain(|(connection, subscriber)| {
                if subscriber.try_send(Message::Output(chunk.clone())).is_ok() {
                    true
                } else {
                    connection.stop();
                    false
                }
            });
        }
        inner.screen.feed(bytes);
        let held = inner.tail.len();
        let overflow = (held + bytes.len()).saturating_sub(TAIL).min(held);
        inner.tail.drain(..overflow);
        let keep = bytes.len().saturating_sub(TAIL);
        inner.tail.extend(&bytes[keep..]);
    }

    #[cfg(test)]
    pub(crate) fn lines(&self) -> Vec<String> {
        self.inner.lock().unwrap().screen.lines(true)
    }

    pub fn resize(&self, rows: u16, cols: u16) {
        self.inner
            .lock()
            .unwrap()
            .screen
            .resize(rows as usize, cols as usize);
    }

    /// The endpoint is gone: tell every client, refuse new ones, drop the socket.
    pub fn close(&self, exit: Value) {
        let mut inner = self.inner.lock().unwrap();
        if inner.closed.is_some() {
            return;
        }
        for (connection, subscriber) in inner.subscribers.drain(..) {
            if subscriber.try_send(Message::Closed(exit.clone())).is_err() {
                connection.stop();
            }
        }
        inner.closed = Some(exit);
        drop(inner);
        self.unlink();
    }

    pub fn unlink(&self) {
        if let Some(path) = self.path.lock().unwrap().take() {
            let _ = fs::remove_file(path);
        }
    }

    /// The snapshot, the unparsed tail it leaves for the stream, and the
    /// subscription that continues exactly after it - taken under one lock.
    fn subscribe(
        &self,
        stream: UnixStream,
    ) -> Result<(Value, Vec<u8>, Receiver<Message>, Arc<Connection>), Value> {
        let mut inner = self.inner.lock().unwrap();
        if let Some(exit) = &inner.closed {
            return Err(exit.clone());
        }
        let screen = &inner.screen;
        let snapshot = json!({
            "ok": true,
            "screen": screen.lines(true).join("\n"),
            "cursor_row": screen.cy,
            "cursor_col": screen.cursor_col(),
        });
        let pending = screen.pending_len().min(inner.tail.len());
        let skip = inner.tail.len() - pending;
        let tail: Vec<u8> = inner.tail.iter().skip(skip).copied().collect();
        let (sender, receiver) = sync_channel(QUEUE);
        let connection = Arc::new(Connection {
            stream,
            stopped: AtomicBool::new(false),
        });
        inner.subscribers.push((connection.clone(), sender));
        Ok((snapshot, tail, receiver, connection))
    }

    fn end_session(&self, connection: &Arc<Connection>, final_message: Option<Message>) {
        let mut inner = self.inner.lock().unwrap();
        if let Some(index) = inner
            .subscribers
            .iter()
            .position(|(c, _)| Arc::ptr_eq(c, connection))
        {
            let (_, sender) = inner.subscribers.remove(index);
            if final_message.is_none_or(|message| sender.try_send(message).is_err()) {
                connection.stop();
            }
        } else {
            connection.stop();
        }
    }
}

impl Drop for Local {
    fn drop(&mut self) {
        self.unlink();
    }
}

/// What a session needs from the agent that owns the endpoint.
pub trait Endpoint: Send + Sync + 'static {
    fn id(&self) -> &str;
    fn local(&self) -> &Local;
    /// Write input to the pty; Err carries the refusal shown to the client.
    fn input(&self, bytes: &[u8]) -> Result<(), String>;
    fn resize(&self, rows: u16, cols: u16) -> Result<(), String>;
}

pub fn serve<E: Endpoint>(endpoint: Arc<E>, listener: UnixListener) {
    for stream in listener.incoming() {
        let Ok(stream) = stream else { continue };
        if !same_user(&stream) {
            continue;
        }
        let endpoint = endpoint.clone();
        std::thread::spawn(move || session(endpoint, stream));
    }
}

pub(crate) fn geometry(value: &Value) -> Option<(u16, u16)> {
    let side = |name: &str| {
        value[name]
            .as_u64()
            .and_then(|v| u16::try_from(v).ok())
            .filter(|v| (1..=1000).contains(v))
    };
    Some((side("rows")?, side("cols")?))
}

fn session<E: Endpoint>(endpoint: Arc<E>, mut stream: UnixStream) {
    let refuse = |stream: &mut UnixStream, message: &str| {
        let _ = write_frame(stream, b'E', &error(message));
        hang_up(stream);
    };
    let _ = stream.set_read_timeout(Some(std::time::Duration::from_secs(10)));
    let hello = match read_frame(&mut stream) {
        Ok(Some((b'H', payload))) => serde_json::from_slice::<Value>(&payload).unwrap_or_default(),
        _ => return refuse(&mut stream, "expected a hello"),
    };
    let _ = stream.set_read_timeout(None);
    if hello["endpoint"].as_str() != Some(endpoint.id()) {
        return refuse(&mut stream, "this socket serves another endpoint");
    }
    // Resize before the snapshot, like the hub path, so the first paint is
    // already at the client's geometry.
    if hello.get("rows").is_some() || hello.get("cols").is_some() {
        let Some((rows, cols)) = geometry(&hello) else {
            return refuse(&mut stream, "a resize needs rows and cols in 1-1000");
        };
        if let Err(message) = endpoint.resize(rows, cols) {
            return refuse(&mut stream, &format!("resize failed: {message}"));
        }
    }
    let Ok(mut writer) = stream.try_clone() else {
        return;
    };
    let Ok(control) = stream.try_clone() else {
        return;
    };
    let (snapshot, tail, receiver, connection) = match endpoint.local().subscribe(control) {
        Ok(subscription) => subscription,
        Err(exit) => {
            let _ = write_frame(
                &mut stream,
                b'C',
                json!({ "exit_code": exit }).to_string().as_bytes(),
            );
            hang_up(&stream);
            return;
        }
    };
    let output_connection = connection.clone();
    let output = std::thread::spawn(move || {
        let painted = write_frame(&mut writer, b'S', snapshot.to_string().as_bytes()).is_ok()
            && (tail.is_empty() || write_frame(&mut writer, b'O', &tail).is_ok());
        if painted {
            for message in receiver.iter() {
                if output_connection.stopped.load(Ordering::SeqCst) {
                    break;
                }
                let (sent, last) = match message {
                    Message::Output(bytes) => (write_frame(&mut writer, b'O', &bytes), false),
                    Message::Closed(exit) => (
                        write_frame(
                            &mut writer,
                            b'C',
                            json!({ "exit_code": exit }).to_string().as_bytes(),
                        ),
                        true,
                    ),
                    Message::Drained => (write_frame(&mut writer, b'A', b""), true),
                    Message::Error(message) => {
                        (write_frame(&mut writer, b'E', &error(&message)), true)
                    }
                };
                if sent.is_err() || last {
                    break;
                }
            }
        }
        output_connection.stop();
    });
    let final_message = loop {
        let frame = match read_frame(&mut stream) {
            Ok(Some(frame)) => frame,
            Ok(None) => break Some(Message::Drained),
            Err(_) => break None,
        };
        let outcome = match frame {
            (b'I', bytes) if !bytes.is_empty() => endpoint.input(&bytes),
            (b'Z', payload) => match serde_json::from_slice::<Value>(&payload)
                .ok()
                .as_ref()
                .and_then(geometry)
            {
                Some((rows, cols)) => endpoint.resize(rows, cols),
                None => Err("a resize needs rows and cols in 1-1000".into()),
            },
            _ => Ok(()),
        };
        if let Err(message) = outcome {
            break Some(Message::Error(message));
        }
    };
    endpoint.local().end_session(&connection, final_message);
    let _ = output.join();
    connection.stop();
}

/// End the connection for the peer. Write first: once the peer has shut its
/// own write half, macOS refuses a both-ways shutdown outright (ENOTCONN), and
/// the peer would never see its end of stream.
fn hang_up(stream: &UnixStream) {
    let _ = stream.shutdown(std::net::Shutdown::Write);
    let _ = stream.shutdown(std::net::Shutdown::Read);
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn frames_round_trip_and_bound_their_size() {
        let mut wire = Vec::new();
        write_frame(&mut wire, b'O', b"hello").unwrap();
        write_frame(&mut wire, b'I', b"").unwrap();
        let mut reader = &wire[..];
        assert_eq!(
            read_frame(&mut reader).unwrap(),
            Some((b'O', b"hello".to_vec()))
        );
        assert_eq!(read_frame(&mut reader).unwrap(), Some((b'I', Vec::new())));
        assert_eq!(read_frame(&mut reader).unwrap(), None);
        let mut truncated = &wire[..3];
        assert!(read_frame(&mut truncated).is_err());
        let mut huge = vec![b'O'];
        huge.extend_from_slice(&((MAX_FRAME as u32) + 1).to_be_bytes());
        assert!(read_frame(&mut &huge[..]).is_err());
    }

    #[test]
    fn snapshot_and_stream_continue_exactly() {
        let local = Local::new(4, 20);
        local.feed(b"first line\r\nsecond\x1b[3");
        let (client, server) = UnixStream::pair().unwrap();
        let (snapshot, tail, receiver, connection) = local.subscribe(server).unwrap();
        assert!(snapshot["screen"].as_str().unwrap().contains("first line"));
        assert_eq!(snapshot["cursor_row"], 1);
        // The unfinished escape is replayed, then the stream continues.
        assert_eq!(tail, b"\x1b[3");
        local.feed(b"1mred");
        match receiver.try_recv().unwrap() {
            Message::Output(bytes) => assert_eq!(&bytes[..], b"1mred"),
            _ => panic!("not output"),
        }
        local.close(json!(3));
        assert!(matches!(receiver.try_recv().unwrap(), Message::Closed(code) if code == 3));
        assert_eq!(
            local.subscribe(client.try_clone().unwrap()).unwrap_err(),
            json!(3)
        );
        connection.stop();
    }

    const ID: &str = "0123456789abcdef0123456789abcdef";
    struct Fake {
        local: Local,
        typed: Mutex<Vec<u8>>,
        sizes: Mutex<Vec<(u16, u16)>>,
    }
    impl Endpoint for Fake {
        fn id(&self) -> &str {
            ID
        }
        fn local(&self) -> &Local {
            &self.local
        }
        fn input(&self, bytes: &[u8]) -> Result<(), String> {
            self.typed.lock().unwrap().extend_from_slice(bytes);
            Ok(())
        }
        fn resize(&self, rows: u16, cols: u16) -> Result<(), String> {
            self.sizes.lock().unwrap().push((rows, cols));
            self.local.resize(rows, cols);
            Ok(())
        }
    }
    fn fake() -> Arc<Fake> {
        Arc::new(Fake {
            local: Local::new(4, 20),
            typed: Mutex::new(Vec::new()),
            sizes: Mutex::new(Vec::new()),
        })
    }
    fn open(endpoint: &Arc<Fake>, hello: Value) -> (UnixStream, std::thread::JoinHandle<()>) {
        let (mut client, server) = UnixStream::pair().unwrap();
        assert!(same_user(&client));
        let agent = endpoint.clone();
        let handle = std::thread::spawn(move || session(agent, server));
        write_frame(&mut client, b'H', hello.to_string().as_bytes()).unwrap();
        (client, handle)
    }

    #[test]
    fn a_session_paints_streams_types_resizes_and_drains() {
        let endpoint = fake();
        endpoint.local.feed(b"before\r\n");
        let (mut client, handle) = open(&endpoint, json!({"endpoint": ID, "rows": 5, "cols": 30}));
        let (tag, snapshot) = read_frame(&mut client).unwrap().unwrap();
        assert_eq!(tag, b'S');
        let snapshot: Value = serde_json::from_slice(&snapshot).unwrap();
        assert!(snapshot["screen"].as_str().unwrap().starts_with("before"));
        // The resize in the hello lands before the snapshot is taken.
        assert_eq!(*endpoint.sizes.lock().unwrap(), vec![(5, 30)]);
        assert_eq!(snapshot["screen"].as_str().unwrap().split('\n').count(), 5);
        endpoint.local.feed(b"after");
        assert_eq!(
            read_frame(&mut client).unwrap(),
            Some((b'O', b"after".to_vec()))
        );
        write_frame(&mut client, b'I', b"typed\r").unwrap();
        write_frame(&mut client, b'Z', br#"{"rows":6,"cols":31}"#).unwrap();
        write_frame(&mut client, b'I', b"more").unwrap();
        client.shutdown(std::net::Shutdown::Write).unwrap();
        handle.join().unwrap();
        assert_eq!(*endpoint.typed.lock().unwrap(), b"typed\rmore");
        assert_eq!(*endpoint.sizes.lock().unwrap(), vec![(5, 30), (6, 31)]);
        assert_eq!(read_frame(&mut client).unwrap(), Some((b'A', Vec::new())));
        assert!(read_frame(&mut client).map_or(true, |frame| frame.is_none()));
        assert!(endpoint.local.inner.lock().unwrap().subscribers.is_empty());
    }

    #[test]
    fn a_session_refuses_another_endpoint_and_reports_a_closed_one() {
        let endpoint = fake();
        let (mut client, handle) = open(&endpoint, json!({"endpoint": "f".repeat(32)}));
        let (tag, message) = read_frame(&mut client).unwrap().unwrap();
        assert_eq!(tag, b'E');
        assert!(String::from_utf8_lossy(&message).contains("another endpoint"));
        handle.join().unwrap();
        assert!(endpoint.local.inner.lock().unwrap().subscribers.is_empty());

        endpoint.local.close(json!(7));
        let (mut client, handle) = open(&endpoint, json!({"endpoint": ID}));
        assert_eq!(
            read_frame(&mut client).unwrap(),
            Some((b'C', br#"{"exit_code":7}"#.to_vec()))
        );
        handle.join().unwrap();
    }

    #[test]
    fn a_closing_endpoint_tells_its_attached_clients() {
        let endpoint = fake();
        let (mut client, _handle) = open(&endpoint, json!({"endpoint": ID}));
        assert_eq!(read_frame(&mut client).unwrap().unwrap().0, b'S');
        endpoint.local.feed(b"last words");
        endpoint.local.close(json!(0));
        assert_eq!(
            read_frame(&mut client).unwrap(),
            Some((b'O', b"last words".to_vec()))
        );
        assert_eq!(
            read_frame(&mut client).unwrap(),
            Some((b'C', br#"{"exit_code":0}"#.to_vec()))
        );
    }

    #[test]
    fn only_a_private_directory_counts() {
        let dir = std::env::temp_dir().join(format!("fm-local-test-{}", std::process::id()));
        fs::DirBuilder::new().mode(0o755).create(&dir).unwrap();
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o755)).unwrap();
        assert!(!private(&dir));
        fs::set_permissions(&dir, fs::Permissions::from_mode(0o700)).unwrap();
        assert!(private(&dir));
        fs::remove_dir(&dir).unwrap();
        assert!(!private(&dir));
    }

    #[test]
    fn a_stalled_client_is_cut_off_not_waited_for() {
        let local = Local::new(4, 20);
        let (mut client, server) = UnixStream::pair().unwrap();
        let (_, _, receiver, connection) = local.subscribe(server).unwrap();
        for _ in 0..QUEUE + 1 {
            local.feed(b"x");
        }
        assert!(local.inner.lock().unwrap().subscribers.is_empty());
        assert_eq!(receiver.iter().count(), QUEUE);
        assert!(connection.stopped.load(Ordering::SeqCst));
        assert_eq!(read_frame(&mut client).unwrap(), None);
    }

    #[test]
    fn idle_detach_and_disconnect_release_every_subscription() {
        let endpoint = fake();
        for _ in 0..32 {
            let (mut client, handle) = open(&endpoint, json!({"endpoint": ID}));
            assert_eq!(read_frame(&mut client).unwrap().unwrap().0, b'S');
            client.shutdown(std::net::Shutdown::Write).unwrap();
            assert_eq!(read_frame(&mut client).unwrap(), Some((b'A', Vec::new())));
            handle.join().unwrap();
            assert!(endpoint.local.inner.lock().unwrap().subscribers.is_empty());
            assert_eq!(read_frame(&mut client).unwrap(), None);
        }
        let (mut client, handle) = open(&endpoint, json!({"endpoint": ID}));
        assert_eq!(read_frame(&mut client).unwrap().unwrap().0, b'S');
        drop(client);
        handle.join().unwrap();
        assert!(endpoint.local.inner.lock().unwrap().subscribers.is_empty());
    }

    #[test]
    fn overflow_unblocks_a_stalled_socket_writer_and_input_session() {
        let endpoint = fake();
        let (mut client, handle) = open(&endpoint, json!({"endpoint": ID}));
        assert_eq!(read_frame(&mut client).unwrap().unwrap().0, b'S');
        let (done, finished) = std::sync::mpsc::channel();
        let join = std::thread::spawn(move || {
            handle.join().unwrap();
            done.send(()).unwrap();
        });
        let chunk = vec![b'x'; 64];
        for _ in 0..QUEUE * 4 {
            endpoint.local.feed(&chunk);
            if endpoint.local.inner.lock().unwrap().subscribers.is_empty() {
                break;
            }
        }
        let result = finished.recv_timeout(std::time::Duration::from_secs(3));
        if result.is_err() {
            hang_up(&client);
        }
        join.join().unwrap();
        assert!(result.is_ok());
        assert!(endpoint.local.inner.lock().unwrap().subscribers.is_empty());
        while matches!(read_frame(&mut client), Ok(Some(_))) {}
    }

    #[test]
    fn unsupported_geometry_is_refused_before_resize() {
        for size in [0, 1001, 65535] {
            let endpoint = fake();
            let (mut client, handle) =
                open(&endpoint, json!({"endpoint": ID, "rows": 24, "cols": size}));
            assert_eq!(read_frame(&mut client).unwrap().unwrap().0, b'E');
            handle.join().unwrap();
            assert!(endpoint.sizes.lock().unwrap().is_empty());
            assert!(endpoint.local.inner.lock().unwrap().subscribers.is_empty());

            let (mut client, handle) = open(&endpoint, json!({"endpoint": ID}));
            assert_eq!(read_frame(&mut client).unwrap().unwrap().0, b'S');
            write_frame(
                &mut client,
                b'Z',
                json!({"rows": size, "cols": 80}).to_string().as_bytes(),
            )
            .unwrap();
            assert_eq!(read_frame(&mut client).unwrap().unwrap().0, b'E');
            handle.join().unwrap();
            assert!(endpoint.sizes.lock().unwrap().is_empty());
            assert!(endpoint.local.inner.lock().unwrap().subscribers.is_empty());
        }
    }
}
