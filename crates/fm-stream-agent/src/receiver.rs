//! Native Deck receiver. Shares the driver's lock, reservations and projections;
//! only a handled projection proves application, never publication or liveness.
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Write};
use std::os::fd::AsRawFd;
use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
use std::path::{Path, PathBuf};
use std::process::Command;

pub enum Decision {
    Legacy,
    Pending(String),
    Confirmed(bool, String),
}
impl Decision {
    fn pending(note: &str) -> Self {
        Self::Pending(note.into())
    }
    fn refused(note: &str) -> Self {
        Self::Confirmed(false, note.into())
    }
}
/// One task-inbox record as a native stream-order source: its binding and
/// text, or None when the record is not a well-formed stream order.
fn parse_source(bytes: &[u8]) -> Option<(Value, String)> {
    let text = std::str::from_utf8(bytes).ok()?;
    let body = text.split_once("\n--\n")?.1;
    let line_and_rest = body.strip_prefix("[stream-order ")?;
    let (binding, rest) = line_and_rest.split_once('\n')?;
    let binding: Value = serde_json::from_str(binding.strip_suffix(']')?).ok()?;
    if !binding.is_object() {
        return None;
    }
    Some((binding, rest.split_once('\n')?.1.to_owned()))
}
fn hash(text: &str) -> String {
    format!("{:x}", Sha256::digest(text.as_bytes()))
}
fn read(path: &Path) -> io::Result<Option<Value>> {
    match fs::read(path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map(Some)
            .map_err(io::Error::other),
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e),
    }
}
fn sync_dir(path: &Path) -> io::Result<()> {
    File::open(path)?.sync_all()
}
fn atomic(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path.parent().unwrap();
    let mut random = [0u8; 16];
    use std::io::Read;
    File::open("/dev/urandom")?.read_exact(&mut random)?;
    let temp = parent.join(format!(".publish.{:x}", u128::from_ne_bytes(random)));
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&temp)?;
        file.write_all(bytes)?;
        file.sync_all()?;
        fs::rename(&temp, path)?;
        sync_dir(parent)
    })();
    let _ = fs::remove_file(temp);
    result
}
fn save(path: &Path, value: &Value) -> io::Result<()> {
    atomic(path, &serde_json::to_vec(value).map_err(io::Error::other)?)
}
struct Lock(File);
impl Drop for Lock {
    fn drop(&mut self) {
        // SAFETY: the file owns this lock descriptor through the call.
        unsafe {
            libc::flock(self.0.as_raw_fd(), libc::LOCK_UN);
        }
    }
}
pub struct Receiver {
    state: PathBuf,
    task: String,
    endpoint: String,
    inbox: PathBuf,
    root: PathBuf,
}
impl Receiver {
    pub fn from_status(status: &str, endpoint: &str) -> Option<Self> {
        if status.is_empty() {
            return None;
        }
        let path = Path::new(status);
        let state = path.parent()?.to_path_buf();
        let filename = path.file_name()?.to_str()?;
        let task = filename
            .strip_suffix(".status")
            .unwrap_or(filename)
            .to_owned();
        let inbox = state.join(format!("{task}.inbox"));
        let root = inbox.join(format!("deck-{endpoint}"));
        Some(Self {
            state,
            task,
            endpoint: endpoint.into(),
            inbox,
            root,
        })
    }
    fn locked(&self) -> io::Result<Lock> {
        fs::DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(&self.root)?;
        let file = OpenOptions::new()
            .create(true)
            .append(true)
            .mode(0o600)
            .open(self.root.join(".lifecycle.lock"))?;
        // SAFETY: file owns a live descriptor; flock serializes with the driver.
        if unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX) } != 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Lock(file))
    }
    fn active(&self) -> io::Result<Option<Value>> {
        read(&self.root.join("active.json"))
    }
    fn order_path(&self, order: &str) -> PathBuf {
        self.root.join(format!("order-{}.json", hash(order)))
    }
    fn sources(&self) -> io::Result<Vec<(PathBuf, Value, String)>> {
        let mut found = Vec::new();
        for directory in [&self.inbox, &self.inbox.join("handled")] {
            let entries = match fs::read_dir(directory) {
                Ok(entries) => entries,
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(e),
            };
            for entry in entries {
                let mut path = entry?.path();
                if path.extension().is_none_or(|s| s != "msg") {
                    continue;
                }
                let bytes = match fs::read(&path) {
                    Ok(bytes) => bytes,
                    Err(e) if e.kind() == io::ErrorKind::NotFound => {
                        path = self.inbox.join("handled").join(path.file_name().unwrap());
                        match fs::read(&path) {
                            Ok(bytes) => bytes,
                            Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                            Err(e) => return Err(e),
                        }
                    }
                    Err(e) => return Err(e),
                };
                // The task inbox is shared with ordinary steering, so a record
                // this receiver cannot read as a stream order (plain text, a
                // foreign format, a corrupt binding) is not ours: leave it in
                // place for its owner and keep serving every other order.
                let Some((binding, text)) = parse_source(&bytes) else {
                    continue;
                };
                found.push((path, binding, text));
            }
        }
        Ok(found)
    }
    fn enqueue(&self, binding: &Value, text: &str) -> io::Result<PathBuf> {
        // Keep allocation/format/idempotency under the existing inbox owner.
        let library = std::env::var_os("FM_STREAM_CODE_ROOT")
            .map(|root| PathBuf::from(root).join("bin/fm-task-inbox-lib.sh"))
            .filter(|path| path.is_file())
            .or_else(|| {
                std::env::current_exe()
                    .ok()?
                    .ancestors()
                    .map(|root| root.join("bin/fm-task-inbox-lib.sh"))
                    .find(|path| path.is_file())
            })
            .ok_or_else(|| {
                io::Error::other(
                    "task inbox writer unavailable; set FM_STREAM_CODE_ROOT to the repository root",
                )
            })?;
        let body = format!("[stream-order {}]\nNative Deck delivery only: do not execute this source as ordinary steering. Retain it until native guidance instructs acknowledgement.\n{text}", serde_json::to_string(binding).map_err(io::Error::other)?);
        let output = Command::new("bash")
            .args([
                "-c",
                ". \"$1\"; fm_task_inbox_write_idempotent \"$2\" \"$3\" \"$4\" fire-and-forget",
                "stream-order",
            ])
            .arg(library)
            .arg(&self.state)
            .arg(&self.task)
            .arg(body)
            .output()?;
        if !output.status.success() {
            return Err(io::Error::other("task inbox writer failed"));
        }
        let record = PathBuf::from(
            String::from_utf8(output.stdout)
                .map_err(io::Error::other)?
                .trim(),
        );
        File::open(&record)?.sync_all()?;
        sync_dir(record.parent().unwrap())?;
        Ok(record)
    }
    pub fn save_result(&self, order: &str, command: &str, record: &Value) -> io::Result<()> {
        let _lock = self.locked()?;
        let path = self.order_path(order);
        let mut stored = read(&path)?.unwrap_or_else(|| json!({}));
        if stored.get("results").is_none() {
            stored["results"] = json!({});
        }
        if let Some(previous) = stored["results"].get(command) {
            if previous["result"] != record["result"] {
                return Err(io::Error::other("command result idempotency conflict"));
            }
        }
        let mut durable = record.clone();
        durable
            .as_object_mut()
            .ok_or_else(|| io::Error::other("malformed result"))?
            .retain(|key, _| !key.starts_with('_'));
        stored["results"][command] = durable;
        save(&path, &stored)
    }
    pub fn recover(&self) -> io::Result<(Vec<Value>, Vec<Value>)> {
        let _lock = self.locked()?;
        let sources = self.sources()?;
        let mut commands = Vec::new();
        let mut results = Vec::new();
        for entry in fs::read_dir(&self.root)? {
            let path = entry?.path();
            if !path
                .file_name()
                .unwrap()
                .to_string_lossy()
                .starts_with("order-")
                || path.extension().is_none_or(|s| s != "json")
            {
                continue;
            }
            let Some(stored) = read(&path)? else {
                continue;
            };
            if !stored.is_object() {
                return Err(io::Error::other("malformed durable receiver record"));
            }
            if let Some(saved) = stored.get("results") {
                let saved = saved
                    .as_object()
                    .ok_or_else(|| io::Error::other("malformed durable results"))?;
                for (id, record) in saved {
                    if record["result"]["command_id"] != *id
                        || record["result"]["machine"].as_str().is_none()
                        || record["result"]["ok"].as_bool().is_none()
                        || record["result"]["error"].as_str().is_none()
                        || record["order_id"].as_str().is_none()
                        || record["settled"].as_bool().is_none()
                        || ["expires_at", "retry_at", "backoff"].iter().any(|key| {
                            record[key]
                                .as_f64()
                                .is_none_or(|number| !number.is_finite())
                        })
                    {
                        return Err(io::Error::other("malformed durable command result"));
                    }
                    results.push(record.clone());
                }
            }
            let binding = &stored["binding"];
            if binding["execution"] != self.endpoint {
                continue;
            }
            let Some((_, _, text)) = sources
                .iter()
                .find(|(_, b, _)| b["order_id"] == binding["order_id"])
            else {
                continue;
            };
            for id in stored["command_ids"].as_array().into_iter().flatten() {
                let command_id = id
                    .as_str()
                    .ok_or_else(|| io::Error::other("malformed reserved command id"))?;
                if stored["results"].get(command_id).is_some() {
                    continue;
                }
                commands.push(json!({"command_id":id,"endpoint_id":self.endpoint,"kind":"steer","payload":{"order_id":binding["order_id"],"execution_id":self.endpoint,"text":text},"_native_prepared":true,"_steering_reservation":stored}));
            }
        }
        Ok((commands, results))
    }
    #[allow(clippy::too_many_arguments)]
    pub fn apply(
        &self,
        order: &str,
        execution: &str,
        text: &str,
        alive: impl Fn() -> bool,
        reconcile: bool,
        reservation: &mut Value,
        command: &str,
        reserve_only: bool,
    ) -> io::Result<Decision> {
        if execution != self.endpoint {
            return Ok(Decision::refused("stale execution; steer was not applied"));
        }
        let _lock = self.locked()?;
        if reservation.is_null() {
            *reservation = json!({});
        }
        if reservation.get("binding").is_none() && !reconcile {
            if let Some(active) = self.active()? {
                if active["active"] == true && active["supported"] == true {
                    *reservation = json!({"binding":{"order_id":order,"execution":execution,"turn":active["turn"]},"text_sha256":hash(text)});
                }
            }
        }
        let path = self.order_path(order);
        let stored = read(&path)?;
        if let Some(stored) = &stored {
            if let Some(fields) = stored.as_object() {
                reservation
                    .as_object_mut()
                    .ok_or_else(|| io::Error::other("malformed reservation"))?
                    .extend(fields.clone());
            }
        }
        if reservation.get("binding").is_some() {
            if reservation.get("command_ids").is_none() {
                reservation["command_ids"] = json!([]);
            }
            let ids = reservation["command_ids"]
                .as_array_mut()
                .ok_or_else(|| io::Error::other("malformed command IDs"))?;
            if !ids.iter().any(|id| id == command) {
                ids.push(json!(command));
            }
            if stored.as_ref() != Some(reservation) {
                save(&path, reservation)?;
            }
        }
        let sources = self.sources()?;
        let (record, binding) = if let Some((record, binding, original)) = sources
            .iter()
            .find(|(_, binding, _)| binding["order_id"] == order)
        {
            let before = reservation.clone();
            reservation["binding"] = binding.clone();
            reservation["text_sha256"] = json!(hash(original));
            if reservation.get("command_ids").is_none() {
                reservation["command_ids"] = json!([]);
            }
            let ids = reservation["command_ids"]
                .as_array_mut()
                .ok_or_else(|| io::Error::other("malformed command IDs"))?;
            if !ids.iter().any(|id| id == command) {
                ids.push(json!(command));
            }
            if *reservation != before {
                save(&path, reservation)?;
            }
            if original != text || binding["execution"] != execution {
                return Ok(Decision::refused("steering idempotency conflict"));
            }
            (record.clone(), binding.clone())
        } else {
            let Some(binding) = reservation.get("binding").cloned() else {
                if reconcile {
                    return Ok(Decision::pending(
                        "Deck binding unavailable; application unconfirmed",
                    ));
                }
                if self
                    .active()?
                    .is_some_and(|a| a["active"] == true && a["supported"] == false)
                {
                    return Ok(Decision::refused(
                        "Deck has no --steer-dir interface; no PTY fallback",
                    ));
                }
                return Ok(Decision::Legacy);
            };
            if binding["order_id"] != order
                || binding["execution"] != execution
                || reservation["text_sha256"] != hash(text)
            {
                return Ok(Decision::refused("steering idempotency conflict"));
            }
            let active = self.active()?;
            if !reserve_only
                && (active
                    .as_ref()
                    .is_none_or(|a| a["active"] != true || a["turn"] != binding["turn"])
                    || !alive())
            {
                return Ok(Decision::pending(
                    "original Deck turn ended; application unconfirmed",
                ));
            }
            let limit = 65536usize.saturating_sub(2 * self.inbox.as_os_str().len() + 400);
            if text.trim().is_empty() || text.len() > limit {
                return Ok(Decision::refused(
                    "Deck steering is blank or exceeds interface size with source reference",
                ));
            }
            if active.is_some_and(|a| a["turn"] == binding["turn"] && a["supported"] == false) {
                return Ok(Decision::refused(
                    "Deck has no --steer-dir interface; no PTY fallback",
                ));
            }
            (self.enqueue(&binding, text)?, binding)
        };
        if reserve_only {
            File::open(&record)?.sync_all()?;
            sync_dir(record.parent().unwrap())?;
            return Ok(Decision::pending("Deck application reserved"));
        }
        let number: u64 = record
            .file_stem()
            .unwrap()
            .to_string_lossy()
            .parse()
            .map_err(io::Error::other)?;
        let projection = self.root.join(
            binding["turn"]
                .as_str()
                .ok_or_else(|| io::Error::other("missing turn"))?,
        );
        let name = format!("{number}.msg");
        let message = projection.join(&name);
        let handled = projection.join("handled").join(&name);
        let rejected = projection.join("rejected").join(&name);
        if !message.exists() && !handled.exists() && !rejected.exists() {
            if self
                .active()?
                .is_none_or(|a| a["active"] != true || a["turn"] != binding["turn"])
            {
                return Ok(Decision::pending(
                    "original Deck turn ended; application unconfirmed",
                ));
            }
            let mut sources = self
                .sources()?
                .into_iter()
                .filter(|(_, b, _)| {
                    b == &binding || (b["execution"] == execution && b["turn"] == binding["turn"])
                })
                .map(|(p, _, text)| {
                    Ok((
                        p.file_stem()
                            .unwrap()
                            .to_string_lossy()
                            .parse::<u64>()
                            .map_err(io::Error::other)?,
                        text,
                    ))
                })
                .collect::<io::Result<Vec<_>>>()?;
            sources.sort_by_key(|(number, _)| *number);
            for (number, text) in sources {
                let name = format!("{number}.msg");
                if ["", "handled", "rejected"]
                    .iter()
                    .any(|sub| projection.join(sub).join(&name).exists())
                {
                    continue;
                }
                let source = self.inbox.join(format!("{number:03}.msg"));
                let guidance = format!("{text}\n\nAfter handling this native steer, acknowledge its ordinary task-inbox source by moving {} to {}. Do not apply the same source record twice.", source.display(), self.inbox.join("handled").join(source.file_name().unwrap()).display());
                if guidance.len() > 65536 {
                    return Ok(Decision::refused(
                        "Deck steering exceeds interface size after source reference",
                    ));
                }
                atomic(&projection.join(name), guidance.as_bytes())?;
            }
        }
        drop(_lock);
        if handled.is_file() {
            return Ok(Decision::Confirmed(true, String::new()));
        }
        if rejected.is_file() {
            return Ok(Decision::refused("Deck rejected the steering message"));
        }
        if self
            .active()?
            .is_none_or(|a| a["active"] != true || a["turn"] != binding["turn"])
            || !alive()
        {
            if handled.is_file() {
                return Ok(Decision::Confirmed(true, String::new()));
            }
            return Ok(Decision::pending(
                "Deck application unconfirmed for original turn; retained in task inbox",
            ));
        }
        Ok(Decision::pending("Deck application pending"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    struct Lab(PathBuf);
    impl Lab {
        fn new() -> Self {
            let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
                .join("../../target/receiver-tests")
                .join(format!(
                    "{}-{}",
                    std::process::id(),
                    hash(&format!("{:?}", std::time::SystemTime::now()))
                ));
            fs::create_dir_all(&root).unwrap();
            Self(root)
        }
        fn receiver(&self) -> Receiver {
            Receiver::from_status(
                self.0.join("task.status").to_str().unwrap(),
                &"e".repeat(32),
            )
            .unwrap()
        }
    }
    impl Drop for Lab {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }
    fn start(receiver: &Receiver, turn: &str) {
        let _lock = receiver.locked().unwrap();
        fs::create_dir_all(receiver.root.join(turn)).unwrap();
        save(
            &receiver.root.join("active.json"),
            &json!({"turn":turn,"active":true,"supported":true}),
        )
        .unwrap();
    }
    #[test]
    fn records_that_are_not_stream_orders_never_block_the_receiver() {
        let lab = Lab::new();
        let receiver = lab.receiver();
        fs::create_dir_all(receiver.inbox.join("handled")).unwrap();
        let binding = json!({"order_id":"kept","execution":receiver.endpoint,"turn":"t1"});
        let valid = format!(
            "from: stream-order\n--\n[stream-order {binding}]\nNative guidance line\nthe order text"
        );
        for (name, bytes) in [
            ("900.msg", b"unhandled steer\n".to_vec()),
            ("901.msg", vec![0xff, 0xfe, b'\n']),
            (
                "902.msg",
                b"hdr\n--\n[stream-order {not json]\nx\ny".to_vec(),
            ),
            ("903.msg", b"hdr\n--\n[stream-order 7]\nx\ny".to_vec()),
            ("904.msg", b"hdr\n--\n[stream-order {}]".to_vec()),
            ("905.msg", b"hdr\n--\nordinary steering text".to_vec()),
        ] {
            fs::write(receiver.inbox.join(name), bytes).unwrap();
        }
        fs::write(receiver.inbox.join("handled/906.msg"), valid).unwrap();
        let sources = receiver.sources().unwrap();
        assert_eq!(sources.len(), 1, "{sources:?}");
        assert_eq!(sources[0].1, binding);
        assert_eq!(sources[0].2, "the order text");
        receiver.recover().unwrap();
        // The unreadable records are left for their owner, untouched.
        assert_eq!(
            fs::read(receiver.inbox.join("900.msg")).unwrap(),
            b"unhandled steer\n"
        );
        assert!(receiver.inbox.join("902.msg").is_file());
    }
    #[test]
    fn enqueue_uses_code_root_outside_repository() {
        if let Ok(mode) = std::env::var("FM_RECEIVER_ENQUEUE_TEST") {
            assert!(!std::env::current_exe()
                .unwrap()
                .ancestors()
                .any(|root| root.join("bin/fm-task-inbox-lib.sh").is_file()));
            let lab = Lab::new();
            let receiver = lab.receiver();
            let binding =
                json!({"order_id":"outside","execution":receiver.endpoint,"turn":"original"});
            let result = receiver.enqueue(&binding, "native guidance");
            if mode == "bound" {
                let record = result.unwrap();
                assert!(record.is_file());
                let sources = receiver.sources().unwrap();
                assert_eq!(sources.len(), 1);
                assert_eq!(sources[0].1, binding);
                assert_eq!(sources[0].2, "native guidance");
            } else {
                assert!(result.is_err());
            }
            return;
        }
        let outside = Lab(std::env::temp_dir().join(format!(
            "fm-receiver-executable-{}-{}",
            std::process::id(),
            hash(&format!("{:?}", std::time::SystemTime::now()))
        )));
        fs::create_dir_all(&outside.0).unwrap();
        let binary = outside.0.join("receiver-test");
        fs::copy(std::env::current_exe().unwrap(), &binary).unwrap();
        for mode in ["unbound", "bound"] {
            let mut child = Command::new(&binary);
            child
                .args([
                    "--exact",
                    "receiver::tests::enqueue_uses_code_root_outside_repository",
                    "--nocapture",
                ])
                .env("FM_RECEIVER_ENQUEUE_TEST", mode)
                .env_remove("FM_STREAM_CODE_ROOT");
            if mode == "bound" {
                child.env(
                    "FM_STREAM_CODE_ROOT",
                    Path::new(env!("CARGO_MANIFEST_DIR")).join("../.."),
                );
            }
            let output = child.output().unwrap();
            assert!(
                output.status.success(),
                "{}\n{}",
                String::from_utf8_lossy(&output.stdout),
                String::from_utf8_lossy(&output.stderr)
            );
        }
    }
    #[test]
    fn durable_reservation_recovery_never_borrows_a_successor() {
        let lab = Lab::new();
        let receiver = lab.receiver();
        start(&receiver, "original");
        let mut reservation = json!({});
        let text = "α\r\nβ\n\n";
        let endpoint = &"e".repeat(32);
        assert!(matches!(
            receiver
                .apply(
                    "one",
                    endpoint,
                    text,
                    || true,
                    false,
                    &mut reservation,
                    "cmd",
                    true
                )
                .unwrap(),
            Decision::Pending(_)
        ));
        let reopened = lab.receiver();
        let (commands, results) = reopened.recover().unwrap();
        assert_eq!(commands.len(), 1);
        assert!(results.is_empty());
        assert_eq!(commands[0]["payload"]["text"], text);
        assert!(
            !receiver.root.join("original/1.msg").exists(),
            "reserve-only projected before application"
        );
        start(&reopened, "successor");
        let mut reservation = commands[0]["_steering_reservation"].clone();
        assert!(matches!(
            reopened
                .apply(
                    "one",
                    endpoint,
                    text,
                    || true,
                    true,
                    &mut reservation,
                    "cmd",
                    false
                )
                .unwrap(),
            Decision::Pending(_)
        ));
        assert!(!reopened.root.join("successor/1.msg").exists());
        assert!(!reopened.root.join("original/1.msg").exists());
        save(
            &reopened.root.join("active.json"),
            &json!({"turn":"original","active":true,"supported":true}),
        )
        .unwrap();
        assert!(matches!(
            reopened
                .apply(
                    "one",
                    endpoint,
                    text,
                    || true,
                    true,
                    &mut reservation,
                    "cmd",
                    false
                )
                .unwrap(),
            Decision::Pending(_)
        ));
        let message = reopened.root.join("original/1.msg");
        assert!(fs::read(&message)
            .unwrap()
            .starts_with(format!("{text}\n\nAfter handling").as_bytes()));
        fs::create_dir_all(reopened.root.join("original/handled")).unwrap();
        fs::rename(message, reopened.root.join("original/handled/1.msg")).unwrap();
        save(
            &reopened.root.join("active.json"),
            &json!({"turn":"successor","active":true,"supported":true}),
        )
        .unwrap();
        assert!(matches!(
            reopened
                .apply(
                    "one",
                    endpoint,
                    text,
                    || false,
                    true,
                    &mut reservation,
                    "cmd",
                    false
                )
                .unwrap(),
            Decision::Confirmed(true, _)
        ));
        assert!(matches!(
            reopened
                .apply(
                    "one",
                    endpoint,
                    "changed",
                    || true,
                    true,
                    &mut reservation,
                    "cmd",
                    false
                )
                .unwrap(),
            Decision::Confirmed(false, _)
        ));
        assert!(matches!(
            reopened
                .apply(
                    "stale",
                    &"f".repeat(32),
                    text,
                    || true,
                    false,
                    &mut json!({}),
                    "other",
                    false
                )
                .unwrap(),
            Decision::Confirmed(false, _)
        ));
        let record = json!({"order_id":"one","result":{"machine":"pilot","command_id":"cmd","ok":true,"error":""},"expires_at":123.0,"retry_at":120.0,"backoff":2.0,"settled":false,"_dirty":true});
        reopened.save_result("one", "cmd", &record).unwrap();
        let (commands, results) = lab.receiver().recover().unwrap();
        assert!(commands.is_empty());
        assert_eq!(results.len(), 1);
        assert_eq!(results[0]["result"], record["result"]);
        assert!(results[0].get("_dirty").is_none());
        let mut conflicting = record.clone();
        conflicting["result"]["ok"] = json!(false);
        assert!(reopened.save_result("one", "cmd", &conflicting).is_err());
    }
    #[test]
    fn failed_reservation_is_uncertain_and_retains_original_binding() {
        let lab = Lab::new();
        let receiver = lab.receiver();
        start(&receiver, "original");
        let order = receiver.order_path("failed");
        fs::create_dir(&order).unwrap();
        let mut reservation = json!({});
        let endpoint = &"e".repeat(32);
        assert!(receiver
            .apply(
                "failed",
                endpoint,
                "text",
                || true,
                false,
                &mut reservation,
                "cmd",
                true
            )
            .is_err());
        assert!(receiver.sources().unwrap().is_empty());
        assert_eq!(reservation["binding"]["turn"], "original");
        fs::remove_dir(order).unwrap();
        start(&receiver, "successor");
        assert!(matches!(
            receiver
                .apply(
                    "failed",
                    endpoint,
                    "text",
                    || true,
                    true,
                    &mut reservation,
                    "cmd",
                    false
                )
                .unwrap(),
            Decision::Pending(_)
        ));
        assert!(receiver.sources().unwrap().is_empty());
        assert!(!receiver.root.join("successor/1.msg").exists());
    }
}
