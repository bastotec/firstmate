//! Kernel ownership boundary. Every reap and signal shares the child lock.
use serde_json::{json, Value};
use std::fs::File;
use std::io::{self, Read, Write};
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::process::{Child, Command, Stdio};
use std::sync::Mutex;
use std::time::{Duration, Instant};

pub struct Pty {
    pub master: File,
    child: Mutex<Child>,
    pub pid: i32,
    pgid: i32,
    tty: String,
}

impl Pty {
    pub fn spawn(cwd: &str, rows: u16, cols: u16, id: &str, hub: &str) -> io::Result<Self> {
        let mut master = -1;
        let mut slave = -1;
        let mut size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: openpty initializes two owned descriptors; all pointers live for the call.
        if unsafe {
            libc::openpty(
                &mut master,
                &mut slave,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                &mut size,
            )
        } != 0
        {
            return Err(io::Error::last_os_error());
        }
        // SAFETY: these descriptors were just returned by openpty and are now owned by File.
        let (master, slave) = unsafe { (File::from_raw_fd(master), File::from_raw_fd(slave)) };
        let mut name = [0u8; 1024];
        // SAFETY: buffer is writable and sized as supplied; slave is still open.
        let rc =
            unsafe { libc::ttyname_r(slave.as_raw_fd(), name.as_mut_ptr().cast(), name.len()) };
        if rc != 0 {
            return Err(io::Error::from_raw_os_error(rc));
        }
        let end = name.iter().position(|b| *b == 0).unwrap_or(name.len());
        let tty = String::from_utf8_lossy(&name[..end]).into_owned();
        // SAFETY: both files own live descriptors; fcntl receives the documented integer argument.
        for descriptor in [&master, &slave] {
            if unsafe { libc::fcntl(descriptor.as_raw_fd(), libc::F_SETFD, libc::FD_CLOEXEC) } < 0 {
                return Err(io::Error::last_os_error());
            }
        }
        let shell = std::env::var("SHELL")
            .ok()
            .filter(|s| !s.is_empty())
            .unwrap_or("/bin/bash".into());
        let mut command = Command::new(&shell);
        if std::path::Path::new(&shell)
            .file_name()
            .is_some_and(|s| s == "bash")
        {
            command.args(["--norc", "--noprofile"]);
        }
        command
            .arg("-i")
            .current_dir(cwd)
            .env("FM_STREAM_ENDPOINT_ID", id)
            .env("FM_STREAM_HUB", hub)
            .env_remove("FM_STREAM_TOKEN")
            .env_remove("FM_STREAM_CODE_ROOT")
            .env(
                "TERM",
                std::env::var("TERM").unwrap_or("xterm-256color".into()),
            )
            .stdin(Stdio::from(slave.try_clone()?))
            .stdout(Stdio::from(slave.try_clone()?))
            .stderr(Stdio::from(slave));
        // SAFETY: child-side setup uses only async-signal-safe libc operations.
        unsafe {
            command.pre_exec(|| {
                libc::signal(libc::SIGINT, libc::SIG_DFL);
                if libc::setsid() < 0 {
                    return Err(io::Error::last_os_error());
                }
                if libc::ioctl(0, libc::TIOCSCTTY as _, 0) < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let child = command.spawn()?;
        let pid = child.id() as i32;
        Ok(Self {
            master,
            child: Mutex::new(child),
            pid,
            pgid: pid,
            tty,
        })
    }

    pub fn exit_code(&self) -> io::Result<Option<i32>> {
        Ok(self
            .child
            .lock()
            .unwrap()
            .try_wait()?
            .map(|s| s.code().unwrap_or_else(|| -s.signal().unwrap_or(0))))
    }
    pub fn alive(&self) -> bool {
        self.exit_code().is_ok_and(|s| s.is_none())
    }
    pub fn wait(&self, timeout: Duration) -> bool {
        let until = Instant::now() + timeout;
        loop {
            if !self.alive() {
                return true;
            }
            if Instant::now() >= until {
                return false;
            }
            std::thread::sleep(Duration::from_millis(20));
        }
    }
    fn signal(&self, signal: i32) -> io::Result<bool> {
        self.signal_with(|| {
            // SAFETY: signal_with holds the child lock and has verified the
            // recorded group while its child still owns this unreaped PID.
            if unsafe { libc::killpg(self.pgid, signal) < 0 && libc::kill(self.pid, signal) < 0 } {
                return Err(io::Error::last_os_error());
            }
            Ok(())
        })
    }
    // Keep the destructive syscall behind a testable ownership gate: a
    // regression test must never actually signal its own runner's group.
    fn signal_with(&self, deliver: impl FnOnce() -> io::Result<()>) -> io::Result<bool> {
        let mut child = self.child.lock().unwrap();
        if child.try_wait()?.is_some() {
            return Ok(false);
        }
        // SAFETY: getpgrp/getsid inspect our own process. The child lock prevents
        // reaping (and therefore PID reuse) until deliver returns.
        unsafe {
            if self.pgid == libc::getpgrp() || self.pgid == libc::getsid(0) {
                return Err(io::Error::other(
                    "refusing to signal agent's own group/session",
                ));
            }
        }
        deliver()?;
        Ok(true)
    }
    // The terminal's foreground process group, when it is a job of ours. The
    // endpoint's interactive shell runs each command in a process group of its
    // own and hands it the terminal, so the worker is usually NOT in the group
    // the child leads. Signalling only that group kills the shell and orphans
    // the worker: on Linux the orphan keeps the pty open, the reader never sees
    // EOF, and the endpoint (and its label) stays open with the worker still
    // running. The group is named only while the child is unreaped and only
    // when it belongs to the child's own session, so it can never be a
    // stranger's.
    fn foreground_group(&self) -> Option<i32> {
        let mut child = self.child.lock().unwrap();
        if !matches!(child.try_wait(), Ok(None)) {
            return None;
        }
        // SAFETY: tcgetpgrp reads the owned master fd; getpgrp/getsid only
        // inspect process ids, and the child lock keeps our session id unreused.
        unsafe {
            let fg = libc::tcgetpgrp(self.master.as_raw_fd());
            if fg <= 0 || fg == self.pgid || fg == libc::getpgrp() || fg == libc::getsid(0) {
                return None;
            }
            (libc::getsid(fg) == self.pgid).then_some(fg)
        }
    }
    // Signal a job named by foreground_group, re-checking it is still in the
    // child's session.
    fn signal_foreground(&self, fg: Option<i32>, signal: i32) -> bool {
        let Some(fg) = fg else { return false };
        // SAFETY: the group is signalled only while it is still in our session.
        unsafe { libc::getsid(fg) == self.pgid && libc::killpg(fg, signal) == 0 }
    }
    fn foreground_alive(&self, fg: Option<i32>) -> bool {
        // SAFETY: getsid only inspects a process id.
        fg.is_some_and(|fg| unsafe { libc::getsid(fg) } == self.pgid)
    }
    pub fn close(&self, kill: bool) -> io::Result<()> {
        let signal = if kill { libc::SIGKILL } else { libc::SIGTERM };
        let fg = self.foreground_group();
        let signalled = self.signal(signal)?;
        let job_signalled = self.signal_foreground(fg, signal);
        if signalled || job_signalled {
            let until = Instant::now() + Duration::from_secs(3);
            while Instant::now() < until && (self.alive() || self.foreground_alive(fg)) {
                std::thread::sleep(Duration::from_millis(20));
            }
            self.signal(libc::SIGKILL)?;
            self.signal_foreground(fg, libc::SIGKILL);
        }
        if !self.wait(Duration::from_secs(2)) {
            return Err(io::Error::other("child exit unconfirmed"));
        }
        Ok(())
    }
    pub fn read(&self, buffer: &mut [u8]) -> io::Result<Option<usize>> {
        let mut fd = libc::pollfd {
            fd: self.master.as_raw_fd(),
            events: libc::POLLIN,
            revents: 0,
        };
        // SAFETY: the fd is owned for the lifetime of self; poll borrows this stack record.
        let rc = unsafe { libc::poll(&mut fd, 1, 100) };
        if rc < 0 {
            return Err(io::Error::last_os_error());
        }
        if rc == 0 {
            return Ok(None);
        }
        match (&self.master).read(buffer) {
            Err(e) if e.raw_os_error() == Some(libc::EIO) => Ok(Some(0)),
            other => other.map(Some),
        }
    }
    pub fn resize(&self, rows: u16, cols: u16) -> io::Result<()> {
        let size = libc::winsize {
            ws_row: rows,
            ws_col: cols,
            ws_xpixel: 0,
            ws_ypixel: 0,
        };
        // SAFETY: the master fd is owned by self; the ioctl reads this stack record.
        if unsafe { libc::ioctl(self.master.as_raw_fd(), libc::TIOCSWINSZ, &size) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
    pub fn write(&self, bytes: &[u8]) -> io::Result<()> {
        (&self.master).write_all(bytes)
    }
    pub fn foreground(&self, until: Option<Instant>) -> Vec<Value> {
        let text = inspect(
            "ps",
            &[
                "-t",
                self.tty.trim_start_matches("/dev/"),
                "-o",
                "pid=,pgid=,tpgid=,comm=",
            ],
            until,
        );
        text.lines().filter_map(|line| {
            let fields: Vec<_> = line.split_whitespace().collect();
            if fields.len() < 4 || fields[1] != fields[2] { return None; }
            let args = inspect("ps", &["-p", fields[0], "-o", "args="], until).trim().to_string();
            Some(json!({"pid": fields[0], "name": fields[3..].join(" "), "argv0": args.split(' ').next().unwrap_or(""), "args": args}))
        }).collect()
    }
    pub fn cwd(&self, foreground: &[Value], until: Option<Instant>) -> String {
        for pid in foreground.iter().rev().filter_map(|p| p["pid"].as_str()) {
            let cwd = process_cwd(pid, until);
            if !cwd.is_empty() {
                return cwd;
            }
        }
        process_cwd(&self.pid.to_string(), until)
    }
}

impl Drop for Pty {
    fn drop(&mut self) {
        // Every early-return path still owns cleanup. Normal shutdown has
        // already reaped the child, so this cannot signal a recycled PID.
        let _ = self.close(true);
    }
}

fn process_cwd(pid: &str, until: Option<Instant>) -> String {
    if let Ok(path) = std::fs::read_link(format!("/proc/{pid}/cwd")) {
        return path.to_string_lossy().into_owned();
    }
    inspect("lsof", &["-a", "-p", pid, "-d", "cwd", "-Fn"], until)
        .lines()
        .find_map(|s| s.strip_prefix("n/").map(|s| format!("/{s}")))
        .unwrap_or_default()
}

/// Inspection is bounded even after startup: an unavailable mount cannot park
/// the publisher forever. Read concurrently so a full pipe cannot block exit.
fn inspect(program: &str, args: &[&str], until: Option<Instant>) -> String {
    let until = until.unwrap_or_else(|| Instant::now() + Duration::from_secs(10));
    if Instant::now() >= until {
        return String::new();
    }
    // Its own process group, so a timeout can end whatever the probe started
    // (a wrapper's grandchild would otherwise hold the pipe open).
    let Ok(mut child) = Command::new(program)
        .args(args)
        .env("LC_ALL", "C")
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .process_group(0)
        .spawn()
    else {
        return String::new();
    };
    let mut pipe = child.stdout.take().unwrap();
    let reader = std::thread::spawn(move || {
        let mut out = String::new();
        let _ = pipe.read_to_string(&mut out);
        out
    });
    let mut success = false;
    while Instant::now() < until {
        match child.try_wait() {
            Ok(Some(_)) => {
                success = true;
                break;
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(10)),
            Err(_) => break,
        }
    }
    if !success {
        // SAFETY: the group was created for this unreaped child just above.
        unsafe { libc::killpg(child.id() as i32, libc::SIGKILL) };
        let _ = child.kill();
        let _ = child.wait();
        // Never wait on the pipe of a probe that ran out of time: anything
        // that escaped the group would hold it for as long as it lives.
        return String::new();
    }
    reader.join().unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn reaped_child_cannot_signal_a_bystander() {
        let mut bystander = Command::new("sleep");
        bystander.arg("30");
        // SAFETY: setsid is async-signal-safe child setup.
        unsafe {
            bystander.pre_exec(|| {
                if libc::setsid() < 0 {
                    return Err(io::Error::last_os_error());
                }
                Ok(())
            });
        }
        let mut bystander = bystander.spawn().unwrap();
        let mut pty = Pty::spawn("/", 40, 200, "test", "http://localhost").unwrap();
        pty.close(true).unwrap();
        pty.pgid = bystander.id() as i32;
        assert!(!pty.signal(libc::SIGKILL).unwrap());
        assert!(bystander.try_wait().unwrap().is_none());
        bystander.kill().unwrap();
        bystander.wait().unwrap();
    }
    #[test]
    fn foreground_job_dies_with_its_endpoint() {
        let pty = Pty::spawn("/", 40, 200, "test", "http://localhost").unwrap();
        // A job that ignores SIGHUP survives its shell's death, which is the
        // orphan a close that signals only the shell's group leaves behind.
        // The marker is split in the typed text so the echo never matches it.
        (&pty.master)
            .write_all(b"bash -c 'trap \"\" HUP; echo FG_JOB_''READY; exec sleep 300'\n")
            .unwrap();
        let until = Instant::now() + Duration::from_secs(20);
        let mut seen = Vec::new();
        let mut buffer = [0u8; 4096];
        let mut job = None;
        while Instant::now() < until && job.is_none() {
            if let Ok(Some(n)) = pty.read(&mut buffer) {
                seen.extend_from_slice(&buffer[..n]);
            }
            if String::from_utf8_lossy(&seen).contains("FG_JOB_READY") {
                job = pty.foreground_group();
            }
        }
        let job = job.expect("the typed job never became the terminal's foreground group");
        // Keep draining the terminal while it closes, as the agent's reader
        // does: an exiting shell can wait on undrained tty output.
        let done = std::sync::atomic::AtomicBool::new(false);
        let closed = std::thread::scope(|scope| {
            scope.spawn(|| {
                let mut sink = [0u8; 4096];
                while !done.load(std::sync::atomic::Ordering::Relaxed) {
                    let _ = pty.read(&mut sink);
                }
            });
            let closed = pty.close(false);
            done.store(true, std::sync::atomic::Ordering::Relaxed);
            closed
        });
        closed.unwrap();
        let until = Instant::now() + Duration::from_secs(8);
        // SAFETY: kill with signal 0 only probes whether the pid still exists.
        while Instant::now() < until && unsafe { libc::kill(job, 0) } == 0 {
            std::thread::sleep(Duration::from_millis(50));
        }
        // SAFETY: as above; the cleanup kill only reaches a job this test started.
        let survived = unsafe { libc::kill(job, 0) } == 0;
        if survived {
            unsafe { libc::killpg(job, libc::SIGKILL) };
        }
        assert!(
            !survived,
            "closing the endpoint orphaned its foreground job {job}"
        );
    }
    #[test]
    fn own_group_and_session_are_refused() {
        let mut pty = Pty::spawn("/", 40, 200, "test", "http://localhost").unwrap();
        // SAFETY: only reads this process's group and session IDs.
        for group in unsafe { [libc::getpgrp(), libc::getsid(0)] } {
            pty.pgid = group;
            let result = pty.signal_with(|| Err(io::Error::other("unsafe signal tripwire")));
            // Restore the actual owned group before any assertion can unwind.
            pty.pgid = pty.pid;
            assert_eq!(
                result.unwrap_err().to_string(),
                "refusing to signal agent's own group/session"
            );
        }
        pty.close(true).unwrap();
    }
}
