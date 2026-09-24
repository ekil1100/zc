//! Bounded, privacy-preserving runtime evidence; no user-provided error text.
use crate::fsutil::{FileLock, SecureDir};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::{
    fmt,
    io::{self, Read},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
        mpsc::{self, SyncSender},
    },
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub(crate) const LOG_LIMIT: usize = 8 * 1024 * 1024;
const RECORD_LIMIT: usize = 4096;
const EXIT_MARKER: &str = "zc.exit.json";
const SAMPLE_INTERVAL: Duration = Duration::from_secs(30);
const REPORT_POLL: Duration = Duration::from_millis(100);
const MAINTENANCE_INTERVAL: Duration = Duration::from_secs(1);
const PS_TIMEOUT: Duration = Duration::from_millis(500);
const KINDS: [&str; 16] = [
    "Other",
    "TimedOut",
    "ConnectionRefused",
    "ConnectionReset",
    "ConnectionAborted",
    "BrokenPipe",
    "UnexpectedEof",
    "InvalidData",
    "InvalidInput",
    "PermissionDenied",
    "AddrNotAvailable",
    "NotConnected",
    "NotFound",
    "AddrInUse",
    "OutOfMemory",
    "Unsupported",
];
const STAGES: [FailureStage; 6] = [
    FailureStage::Ingress,
    FailureStage::Dns,
    FailureStage::Connect,
    FailureStage::Tls,
    FailureStage::Transfer,
    FailureStage::Udp,
];

#[derive(Copy, Clone, Debug)]
pub(crate) enum FailureStage {
    Ingress,
    Dns,
    Connect,
    Tls,
    Transfer,
    Udp,
}
impl FailureStage {
    fn label(self) -> &'static str {
        match self {
            Self::Ingress => "ingress",
            Self::Dns => "dns",
            Self::Connect => "connect",
            Self::Tls => "tls",
            Self::Transfer => "transfer",
            Self::Udp => "udp",
        }
    }
}
impl fmt::Display for FailureStage {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(self.label())
    }
}
impl std::error::Error for FailureStage {}

fn error_index(error: &anyhow::Error) -> usize {
    // Only typed, finite categories are retained; never format any error or context.
    let kind = error
        .chain()
        .find_map(|cause| cause.downcast_ref::<io::Error>())
        .map(io::Error::kind);
    match kind {
        Some(io::ErrorKind::TimedOut) => 1,
        Some(io::ErrorKind::ConnectionRefused) => 2,
        Some(io::ErrorKind::ConnectionReset) => 3,
        Some(io::ErrorKind::ConnectionAborted) => 4,
        Some(io::ErrorKind::BrokenPipe) => 5,
        Some(io::ErrorKind::UnexpectedEof) => 6,
        Some(io::ErrorKind::InvalidData) => 7,
        Some(io::ErrorKind::InvalidInput) => 8,
        Some(io::ErrorKind::PermissionDenied) => 9,
        Some(io::ErrorKind::AddrNotAvailable) => 10,
        Some(io::ErrorKind::NotConnected) => 11,
        Some(io::ErrorKind::NotFound) => 12,
        Some(io::ErrorKind::AddrInUse) => 13,
        Some(io::ErrorKind::OutOfMemory) => 14,
        Some(io::ErrorKind::Unsupported) => 15,
        _ => 0,
    }
}
fn increment(counter: &AtomicU64) {
    let _ = counter.fetch_update(Ordering::Relaxed, Ordering::Relaxed, |n| {
        Some(n.saturating_add(1))
    });
}
pub(crate) struct Observer {
    active: AtomicU64,
    total: AtomicU64,
    rejected: AtomicU64,
    panics: AtomicU64,
    failures: [[AtomicU64; KINDS.len()]; STAGES.len()],
}
impl Observer {
    fn new() -> Self {
        Self {
            active: AtomicU64::new(0),
            total: AtomicU64::new(0),
            rejected: AtomicU64::new(0),
            panics: AtomicU64::new(0),
            failures: std::array::from_fn(|_| std::array::from_fn(|_| AtomicU64::new(0))),
        }
    }
    pub(crate) fn connection(self: &Arc<Self>) -> ConnectionGuard {
        increment(&self.active);
        increment(&self.total);
        ConnectionGuard(self.clone())
    }
    pub(crate) fn failure(&self, stage: FailureStage, error: &anyhow::Error) {
        increment(&self.failures[stage as usize][error_index(error)]);
    }
    pub(crate) fn rejected(&self) {
        increment(&self.rejected);
    }
}
pub(crate) struct ConnectionGuard(Arc<Observer>);
impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        self.0.active.fetch_sub(1, Ordering::Relaxed);
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct ExitMarker {
    schema_version: u32,
    pid: u32,
    instance: String,
}
fn marker_bytes(marker: &ExitMarker) -> Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(marker)?;
    bytes.push(b'\n');
    Ok(bytes)
}
fn valid_marker(bytes: &[u8]) -> Option<ExitMarker> {
    let marker: ExitMarker = serde_json::from_slice(bytes).ok()?;
    (marker.schema_version == 1
        && marker.pid > 0
        && marker.pid <= i32::MAX as u32
        && marker.instance.len() == 32
        && marker
            .instance
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
        && marker_bytes(&marker).ok()?.as_slice() == bytes)
        .then_some(marker)
}

/// Fixed retention: current plus one archive, each at most eight MiB. The lock
/// also serializes the few pre-observer diagnostic writers in the daemon.
pub(crate) fn append_log(dir: &SecureDir, bytes: &[u8]) -> Result<()> {
    // A generic diagnostic writer has no authenticated instance identity.
    append_log_for_instance(dir, bytes, None)
}
fn append_log_for_instance(dir: &SecureDir, bytes: &[u8], instance: Option<&str>) -> Result<()> {
    ensure!(bytes.len() <= RECORD_LIMIT, "runtime event exceeds limit");
    let guard = dir.lock("zc.log.lock", Duration::from_millis(50))?;
    guard.validate(dir, "zc.log.lock")?;
    rotate_log(dir, bytes.len(), instance)?;
    dir.append_bounded("zc.log", bytes, LOG_LIMIT)?;
    Ok(())
}
fn rotate_log(dir: &SecureDir, additional: usize, instance: Option<&str>) -> Result<()> {
    let length = match dir.file_metadata("zc.log") {
        Ok(metadata) => metadata.len(),
        Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(e) => return Err(e.into()),
    };
    if length.saturating_add(additional as u64) <= LOG_LIMIT as u64 {
        return Ok(());
    }
    // Validate both endpoints; never replace a symlink, hard link or special file.
    if dir.exists("zc.log.1")? {
        dir.file_metadata("zc.log.1")?;
    }
    if length > LOG_LIMIT as u64 {
        // Only external/legacy writers can exceed our append bound. Do not copy
        // unbounded content into the archive or silently claim it was retained.
        let warning = event_bytes(
            json!({"level":"warn", "event":"log_retention_exceeded"}),
            instance,
        )?;
        dir.atomic_write("zc.log", &warning)?;
    }
    dir.rename("zc.log", "zc.log.1")?;
    dir.atomic_write("zc.log", b"")?;
    Ok(())
}

fn event_bytes(mut value: Value, instance: Option<&str>) -> Result<Vec<u8>> {
    value["timestamp_ms"] = json!(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .ok()
            .map(|d| d.as_millis())
    );
    value["pid"] = json!(std::process::id());
    value["instance"] = json!(instance);
    let mut bytes = serde_json::to_vec(&value)?;
    bytes.push(b'\n');
    ensure!(bytes.len() <= RECORD_LIMIT, "runtime event exceeds limit");
    Ok(bytes)
}

struct EventLog {
    dir: SecureDir,
    path: PathBuf,
    lock: Arc<FileLock>,
    nonce: String,
    writer: Mutex<()>,
}
impl EventLog {
    fn event(&self, value: Value) -> Result<()> {
        let bytes = event_bytes(value, Some(&self.nonce))?;
        let _guard = self
            .writer
            .lock()
            .map_err(|_| anyhow::anyhow!("runtime log writer unavailable"))?;
        self.dir.validate_path(&self.path)?;
        self.lock.validate(&self.dir, "zc.lock")?;
        append_log_for_instance(&self.dir, &bytes, Some(&self.nonce))?;
        Ok(())
    }
    fn maintenance(&self) -> Result<()> {
        let _guard = self
            .writer
            .lock()
            .map_err(|_| anyhow::anyhow!("runtime log writer unavailable"))?;
        self.dir.validate_path(&self.path)?;
        self.lock.validate(&self.dir, "zc.lock")?;
        let guard = self.dir.lock("zc.log.lock", Duration::from_millis(50))?;
        guard.validate(&self.dir, "zc.log.lock")?;
        rotate_log(&self.dir, 0, Some(&self.nonce))
    }
    fn diagnostic(&self, event: &'static str) {
        let _ = self.event(json!({"level":"warn", "event":event, "phase":"exit_marker"}));
    }
    fn begin_marker(&self) -> Option<Vec<u8>> {
        // Diagnostic only: no PID probing, adoption, stop, or authority decisions.
        // Invalid/unreadable markers are preserved rather than repaired or removed.
        if self.dir.validate_path(&self.path).is_err()
            || self.lock.validate(&self.dir, "zc.lock").is_err()
        {
            return None;
        }
        match self.dir.read(EXIT_MARKER, 1024) {
            Ok(bytes) => {
                let Some(previous) = valid_marker(&bytes) else {
                    self.diagnostic("exit_marker_invalid");
                    return None;
                };
                let _ = self.event(json!({"level":"warn", "event":"previous_exit_unknown",
                    "previous_pid":previous.pid, "previous_instance":previous.instance}));
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => (),
            Err(_) => {
                self.diagnostic("exit_marker_unavailable");
                return None;
            }
        }
        let bytes = marker_bytes(&ExitMarker {
            schema_version: 1,
            pid: std::process::id(),
            instance: self.nonce.clone(),
        })
        .ok()?;
        match self.dir.atomic_write(EXIT_MARKER, &bytes) {
            Ok(receipt) => {
                if receipt.durability_error.is_some() {
                    self.diagnostic("exit_marker_durability_uncertain");
                }
                Some(bytes)
            }
            Err(_) => {
                self.diagnostic("exit_marker_unavailable");
                None
            }
        }
    }
    fn finish_marker(&self, owned: Option<&[u8]>) {
        let Some(owned) = owned else {
            return;
        };
        let cleared = (|| -> Result<()> {
            self.dir.validate_path(&self.path)?;
            self.lock.validate(&self.dir, "zc.lock")?;
            ensure!(
                self.dir.read(EXIT_MARKER, 1024)? == owned,
                "exit marker identity changed"
            );
            self.dir.remove_file(EXIT_MARKER)?;
            self.dir.sync()?;
            Ok(())
        })();
        if cleared.is_err() {
            self.diagnostic("exit_marker_cleanup_uncertain");
        }
    }
    fn lifecycle(
        &self,
        event: &'static str,
        phase: &'static str,
        error_kind: Option<&'static str>,
    ) -> Result<()> {
        self.event(
            json!({"level": if error_kind.is_some() {"error"} else {"info"},
            "event": event, "phase": phase, "error_kind": error_kind}),
        )
    }
}
type Hook = Box<dyn Fn(&std::panic::PanicHookInfo<'_>) + Send + Sync + 'static>;
struct PanicHook(Option<Hook>);
impl PanicHook {
    fn install(observer: Arc<Observer>) -> Self {
        let previous = std::panic::take_hook();
        // No allocation, formatting, filesystem operation, mutex, or user data.
        // Deliberately do not chain the default hook: it prints payload/location.
        std::panic::set_hook(Box::new(move |_| {
            observer.panics.fetch_add(1, Ordering::Relaxed);
        }));
        Self(Some(previous))
    }
}
impl Drop for PanicHook {
    fn drop(&mut self) {
        // Rust forbids changing hooks while unwinding; never recursively panic.
        if !std::thread::panicking()
            && let Some(previous) = self.0.take()
        {
            std::panic::set_hook(previous);
        }
    }
}

pub(crate) fn task_error(error: tokio::task::JoinError) -> anyhow::Error {
    // JoinError's Display and source retain the private panic payload. Do not
    // attach it as a cause, even when callers request the full error chain.
    anyhow::anyhow!(if error.is_panic() {
        "RUNTIME_FAILED: task panicked"
    } else {
        "RUNTIME_FAILED: task cancelled"
    })
}

/// Keep an instance-future failure inside the evidence shutdown scope.
pub(crate) async fn catch_instance_panic(
    future: impl std::future::Future<Output = Result<()>>,
) -> Result<()> {
    // Own the pin so destruction can also occur inside catch_unwind. A stack
    // pin would drop the poisoned/completed future outside the catch boundary.
    let mut future = Box::pin(future);
    let result = std::future::poll_fn(|cx| {
        // The poisoned future is never polled again. Keep the payload private;
        // the installed hook has already counted this panic without formatting it.
        match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| future.as_mut().poll(cx))) {
            Ok(poll) => poll,
            Err(_) => std::task::Poll::Ready(Err(anyhow::anyhow!(
                "RUNTIME_FAILED: instance future panicked"
            ))),
        }
    })
    .await;
    match std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| drop(future))) {
        Ok(()) => result,
        Err(_) => Err(anyhow::anyhow!(
            "RUNTIME_FAILED: instance future drop panicked"
        )),
    }
}

struct Finish {
    phase: &'static str,
    error_kind: Option<&'static str>,
}

/// The reporter owns a lock reference until its final write. Disk/ps work never
/// runs on connection tasks; shutdown waits at most two seconds for evidence.
pub(crate) struct Evidence {
    pub(crate) observer: Arc<Observer>,
    log: Arc<EventLog>,
    finish: SyncSender<Finish>,
    done: tokio::sync::oneshot::Receiver<()>,
    _hook: PanicHook,
}
impl Evidence {
    pub(crate) fn start(path: &Path, nonce: &str, lock: Arc<FileLock>) -> Result<Self> {
        let log = Arc::new(EventLog {
            dir: SecureDir::open_owned_absolute(path, true)?,
            path: path.into(),
            lock,
            nonce: nonce.into(),
            writer: Mutex::new(()),
        });
        log.lifecycle("daemon_starting", "startup", None)?;
        let marker = log.begin_marker();
        let observer = Arc::new(Observer::new());
        let hook = PanicHook::install(observer.clone());
        let (finish, receiver) = mpsc::sync_channel::<Finish>(1);
        let (completed, done) = tokio::sync::oneshot::channel();
        let reporter_log = log.clone();
        let reporter_observer = observer.clone();
        let reporter_marker = marker.clone();
        let spawned = std::thread::Builder::new()
            .name("zc-evidence".into())
            .spawn(move || {
                let mut reporter = Reporter::new(reporter_log, reporter_observer);
                reporter.run(receiver, reporter_marker.as_deref());
                let _ = completed.send(());
            });
        if let Err(error) = spawned {
            let error = anyhow::Error::from(error);
            if log
                .lifecycle(
                    "daemon_failed",
                    "observability",
                    Some(KINDS[error_index(&error)]),
                )
                .is_ok()
            {
                log.finish_marker(marker.as_deref());
            }
            return Err(error).context("START_FAILED: cannot start runtime evidence reporter");
        }
        Ok(Self {
            observer,
            log,
            finish,
            done,
            _hook: hook,
        })
    }
    pub(crate) fn instance_lock(&self) -> &FileLock {
        &self.log.lock
    }
    pub(crate) fn ready(&self) -> Result<()> {
        self.log.lifecycle("daemon_ready", "ready", None)
    }
    pub(crate) async fn finish(self, phase: &'static str, error: Option<&anyhow::Error>) {
        let _ = self.finish.try_send(Finish {
            phase,
            error_kind: error.map(|e| KINDS[error_index(e)]),
        });
        let _ = tokio::time::timeout(Duration::from_secs(2), self.done).await;
    }
}

struct Reporter {
    log: Arc<EventLog>,
    observer: Arc<Observer>,
    started: Instant,
    reported: [[u64; KINDS.len()]; STAGES.len()],
    last_report: [[Instant; KINDS.len()]; STAGES.len()],
    previous: Option<(Instant, Resources)>,
    panic_reported: bool,
}
impl Reporter {
    fn new(log: Arc<EventLog>, observer: Arc<Observer>) -> Self {
        let started = Instant::now();
        Self {
            log,
            observer,
            started,
            reported: [[0; KINDS.len()]; STAGES.len()],
            last_report: [[started; KINDS.len()]; STAGES.len()],
            previous: None,
            panic_reported: false,
        }
    }
    fn run(&mut self, receiver: mpsc::Receiver<Finish>, marker: Option<&[u8]>) {
        self.summary("initial");
        let mut next_sample = Instant::now() + SAMPLE_INTERVAL;
        let mut next_maintenance = Instant::now() + MAINTENANCE_INTERVAL;
        loop {
            match receiver.recv_timeout(REPORT_POLL) {
                Ok(finish) => {
                    self.failures(true);
                    self.panic();
                    self.summary("final");
                    if self
                        .log
                        .lifecycle(
                            if finish.error_kind.is_some() {
                                "daemon_failed"
                            } else {
                                "daemon_stopped"
                            },
                            finish.phase,
                            finish.error_kind,
                        )
                        .is_ok()
                    {
                        self.log.finish_marker(marker);
                    }
                    break;
                }
                Err(mpsc::RecvTimeoutError::Disconnected) => {
                    // The owner never certified an outcome. Preserve the marker,
                    // but do not discard panic evidence already captured by the hook.
                    self.panic();
                    self.failures(true);
                    break;
                }
                Err(mpsc::RecvTimeoutError::Timeout) => (),
            }
            self.failures(false);
            self.panic();
            if Instant::now() >= next_maintenance {
                let _ = self.log.maintenance();
                next_maintenance = Instant::now() + MAINTENANCE_INTERVAL;
            }
            if Instant::now() >= next_sample {
                self.summary("periodic");
                next_sample = Instant::now() + SAMPLE_INTERVAL;
            }
        }
    }
    fn panic(&mut self) {
        let count = self.observer.panics.load(Ordering::Relaxed);
        if count > 0 && !self.panic_reported {
            self.panic_reported = true;
            let _ = self
                .log
                .event(json!({"level":"error", "event":"runtime_panic", "count":count}));
        }
    }
    fn failures(&mut self, final_report: bool) {
        let now = Instant::now();
        for (stage, counters) in self.observer.failures.iter().enumerate() {
            for (kind, counter) in counters.iter().enumerate() {
                let total = counter.load(Ordering::Relaxed);
                if total > 0 && self.reported[stage][kind] == 0 {
                    let _ = self.log.event(json!({
                        "level":"error", "event":"connection_failed",
                        "stage":STAGES[stage].label(), "error_kind":KINDS[kind],
                        "count":1, "total":1,
                    }));
                    self.reported[stage][kind] = 1;
                    self.last_report[stage][kind] = now;
                }
                let old = self.reported[stage][kind];
                if total > old
                    && (final_report
                        || now.duration_since(self.last_report[stage][kind]) >= SAMPLE_INTERVAL)
                {
                    let _ = self.log.event(json!({
                        "level":"error", "event":"connection_failure_summary",
                        "stage":STAGES[stage].label(), "error_kind":KINDS[kind],
                        "count":total.saturating_sub(old), "total":total,
                    }));
                    // A failed sink must not cause an unbounded retry storm either.
                    self.reported[stage][kind] = total;
                    self.last_report[stage][kind] = now;
                }
            }
        }
    }
    fn summary(&mut self, phase: &'static str) {
        let resources = sample_resources();
        let now = Instant::now();
        let delta = resources
            .zip(self.previous)
            .and_then(|(current, (time, previous))| {
                Some((
                    current.cpu_ms.checked_sub(previous.cpu_ms)?,
                    now.duration_since(time).as_millis(),
                    i64::try_from(i128::from(current.rss_bytes) - i128::from(previous.rss_bytes))
                        .ok()?,
                ))
            });
        let mut failures_by_stage = serde_json::Map::new();
        let mut failures = 0_u64;
        for (stage, counters) in self.observer.failures.iter().enumerate() {
            let total = counters.iter().fold(0_u64, |sum, count| {
                sum.saturating_add(count.load(Ordering::Relaxed))
            });
            failures_by_stage.insert(STAGES[stage].label().into(), json!(total));
            failures = failures.saturating_add(total);
        }
        let _ = self.log.event(json!({
            "level":"info", "event":"runtime_summary", "phase":phase,
            "uptime_ms": self.started.elapsed().as_millis(), "sample_interval_seconds": SAMPLE_INTERVAL.as_secs(),
            "active_connections": self.observer.active.load(Ordering::Relaxed),
            "total_connections": self.observer.total.load(Ordering::Relaxed),
            "failures": failures, "failures_by_stage": failures_by_stage,
            "rejections": self.observer.rejected.load(Ordering::Relaxed),
            "panics": self.observer.panics.load(Ordering::Relaxed),
            "resource_status": if resources.is_some() {"available"} else {"unavailable"},
            "cpu_time_ms":resources.map(|r| r.cpu_ms), "rss_bytes":resources.map(|r| r.rss_bytes),
            "cpu_delta_ms":delta.map(|d| d.0), "sample_elapsed_ms":delta.map(|d| d.1),
            "rss_delta_bytes":delta.map(|d| d.2),
        }));
        self.previous = resources.map(|r| (now, r));
    }
}

#[derive(Clone, Copy)]
struct Resources {
    cpu_ms: u64,
    rss_bytes: u64,
}
struct Reap(Child);
impl Drop for Reap {
    fn drop(&mut self) {
        // Also reap on parser/read errors. No child or inherited pipe is retained.
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn sample_resources() -> Option<Resources> {
    sample_resources_checked().ok()
}
fn sample_resources_checked() -> Result<Resources> {
    let child = Reap(
        Command::new("/bin/ps")
            .args([
                "-p",
                &std::process::id().to_string(),
                "-o",
                "time=",
                "-o",
                "rss=",
            ])
            .env_clear()
            .env("LC_ALL", "C")
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()?,
    );
    read_resources(child)
}
fn read_resources(mut child: Reap) -> Result<Resources> {
    let mut stdout = child.0.stdout.take().context("resource pipe unavailable")?;
    let flags = rustix::fs::fcntl_getfl(&stdout)?;
    rustix::fs::fcntl_setfl(&stdout, flags | rustix::fs::OFlags::NONBLOCK)?;
    let started = Instant::now();
    let mut bytes = [0_u8; 1025];
    let mut used = 0;
    loop {
        match stdout.read(&mut bytes[used..]) {
            Ok(n) => used += n,
            Err(e)
                if matches!(
                    e.kind(),
                    io::ErrorKind::WouldBlock | io::ErrorKind::Interrupted
                ) => {}
            Err(e) => return Err(e.into()),
        }
        ensure!(used <= 1024, "resource output exceeds limit");
        if let Some(status) = child.0.try_wait()? {
            ensure!(status.success(), "resource sampler failed");
            // The fixed ps child has exited; drain its bounded remaining output.
            loop {
                match stdout.read(&mut bytes[used..]) {
                    Ok(0) => break,
                    Ok(n) => used += n,
                    Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
                    Err(e) => return Err(e.into()),
                }
                ensure!(used <= 1024, "resource output exceeds limit");
            }
            break;
        }
        ensure!(started.elapsed() < PS_TIMEOUT, "resource sampler timed out");
        std::thread::sleep(Duration::from_millis(5));
    }
    let mut fields = std::str::from_utf8(&bytes[..used])?.split_whitespace();
    let cpu_ms = parse_cpu_time(fields.next().context("CPU time unavailable")?)
        .context("invalid CPU time")?;
    let rss_bytes = fields
        .next()
        .context("RSS unavailable")?
        .parse::<u64>()?
        .checked_mul(1024)
        .context("RSS overflow")?;
    ensure!(fields.next().is_none(), "invalid resource output");
    Ok(Resources { cpu_ms, rss_bytes })
}
fn parse_cpu_time(value: &str) -> Option<u64> {
    let (days, clock) = match value.split_once('-') {
        Some((days, clock)) => (days.parse::<u64>().ok()?, clock),
        None => (0, value),
    };
    let (whole, fraction) = clock.split_once('.').unwrap_or((clock, ""));
    if !fraction.bytes().all(|b| b.is_ascii_digit()) {
        return None;
    }
    let mut seconds = 0_u64;
    let mut fields = 0;
    for component in whole.split(':') {
        let value = component.parse::<u64>().ok()?;
        if fields > 0 && value >= 60 {
            return None;
        }
        seconds = seconds.checked_mul(60)?.checked_add(value)?;
        fields += 1;
    }
    if !(2..=3).contains(&fields) {
        return None;
    }
    let millis = fraction
        .bytes()
        .take(3)
        .enumerate()
        .fold(0_u64, |sum, (i, b)| {
            sum + u64::from(b - b'0') * [100, 10, 1][i]
        });
    days.checked_mul(86400)?
        .checked_add(seconds)?
        .checked_mul(1000)?
        .checked_add(millis)
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;

    pub(crate) fn harness(name: &str, case: &str) -> (tempfile::TempDir, std::process::Output) {
        use std::os::unix::fs::PermissionsExt;
        let home = tempfile::tempdir().unwrap();
        let path = home.path().canonicalize().unwrap();
        let runtime = path.join("runtime");
        std::fs::create_dir(&runtime).unwrap();
        std::fs::set_permissions(&runtime, std::fs::Permissions::from_mode(0o700)).unwrap();
        let mut child = Reap(
            Command::new(std::env::current_exe().unwrap())
                .args(["--exact", name, "--nocapture"])
                .env("ZC_EVIDENCE_HARNESS", case)
                .env("HOME", path)
                .env("XDG_RUNTIME_DIR", runtime)
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap(),
        );
        let deadline = Instant::now() + Duration::from_secs(10);
        let status = loop {
            if let Some(status) = child.0.try_wait().unwrap() {
                break status;
            }
            assert!(Instant::now() < deadline, "evidence harness timed out");
            std::thread::sleep(Duration::from_millis(10));
        };
        let mut stdout = Vec::new();
        let mut stderr = Vec::new();
        child
            .0
            .stdout
            .take()
            .unwrap()
            .read_to_end(&mut stdout)
            .unwrap();
        child
            .0
            .stderr
            .take()
            .unwrap()
            .read_to_end(&mut stderr)
            .unwrap();
        (
            home,
            std::process::Output {
                status,
                stdout,
                stderr,
            },
        )
    }

    #[tokio::test]
    async fn pre_observer_rotation_reports_writer_pid_without_guessing_instance() {
        if std::env::var_os("ZC_EVIDENCE_HARNESS").is_some() {
            let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
            let dir = SecureDir::open(&path).unwrap();
            dir.atomic_write("zc.log", b"").unwrap();
            std::fs::OpenOptions::new()
                .write(true)
                .open(path.join("zc.log"))
                .unwrap()
                .set_len(LOG_LIMIT as u64 + 1)
                .unwrap();
            // A stale marker must not turn this diagnostic writer into that instance.
            dir.atomic_write(
                EXIT_MARKER,
                &marker_bytes(&ExitMarker {
                    schema_version: 1,
                    pid: 1,
                    instance: "0123456789abcdef0123456789abcdef".into(),
                })
                .unwrap(),
            )
            .unwrap();
            append_log(&dir, b"Diagnostic before observer startup.\n").unwrap();
            println!("writer_pid={}", std::process::id());
            crate::daemon::log(1000, false, true).await.unwrap();
            return;
        }
        let (_, output) = harness(
            "observability::tests::pre_observer_rotation_reports_writer_pid_without_guessing_instance",
            "pre-observer",
        );
        assert!(output.status.success(), "{output:?}");
        let stdout = String::from_utf8(output.stdout).unwrap();
        let pid: u32 = stdout
            .lines()
            .find_map(|l| l.strip_prefix("writer_pid="))
            .unwrap()
            .parse()
            .unwrap();
        let warning: Value = stdout
            .lines()
            .find_map(|line| {
                let envelope: Value = serde_json::from_str(line).ok()?;
                let event: Value = serde_json::from_str(envelope["line"].as_str()?).ok()?;
                (event["event"] == "log_retention_exceeded").then_some(event)
            })
            .unwrap();
        assert_eq!(warning["level"], "warn");
        assert_eq!(warning["pid"], pid);
        assert!(warning["timestamp_ms"].as_u64().unwrap() > 0);
        assert_eq!(
            warning.as_object().unwrap().get("instance"),
            Some(&Value::Null)
        );
    }

    #[tokio::test]
    async fn spawned_task_errors_never_serialize_panic_payload_or_location() {
        if std::env::var_os("ZC_EVIDENCE_HARNESS").is_some() {
            let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
            let dir = SecureDir::open(&path).unwrap();
            let lock = Arc::new(dir.lock("zc.lock", Duration::from_secs(1)).unwrap());
            let nonce = "0123456789abcdef0123456789abcdef";
            let evidence = Evidence::start(&path, nonce, lock).unwrap();
            let result = tokio::spawn(async {
                tokio::task::yield_now().await;
                panic!("credential=private-task-payload");
            })
            .await
            .map_err(task_error);
            let error = result.unwrap_err();
            // Exercise both CLI Display and the full chain used by startup errors.
            println!("error: {error}");
            eprintln!("error: {error:?}");
            dir.atomic_write(
                &format!("zc.start.{nonce}"),
                format!("{error:#}").as_bytes(),
            )
            .unwrap();
            evidence.finish("runtime", Some(&error)).await;
            let cancelled = tokio::spawn(std::future::pending::<()>());
            cancelled.abort();
            assert_eq!(
                task_error(cancelled.await.unwrap_err()).to_string(),
                "RUNTIME_FAILED: task cancelled"
            );
            crate::daemon::log(1000, false, true).await.unwrap();
            return;
        }
        let (home, output) = harness(
            "observability::tests::spawned_task_errors_never_serialize_panic_payload_or_location",
            "task",
        );
        let startup = std::fs::read_to_string(
            home.path()
                .join("runtime/zc.start.0123456789abcdef0123456789abcdef"),
        )
        .unwrap();
        for text in [
            String::from_utf8_lossy(&output.stdout).as_ref(),
            String::from_utf8_lossy(&output.stderr).as_ref(),
            &startup,
        ] {
            assert!(
                !text.contains("private-task-payload"),
                "panic payload escaped"
            );
            assert!(
                !text.contains("observability.rs:"),
                "panic location escaped"
            );
        }
        assert!(output.status.success(), "{output:?}");
        assert_eq!(startup, "RUNTIME_FAILED: task panicked");
        let stdout = String::from_utf8(output.stdout).unwrap();
        let events: Vec<Value> = stdout
            .lines()
            .filter_map(|line| {
                let envelope: Value = serde_json::from_str(line).ok()?;
                serde_json::from_str(envelope["line"].as_str()?).ok()
            })
            .collect();
        assert!(events.iter().any(|e| e["event"] == "runtime_panic"));
        assert_eq!(events.last().unwrap()["event"], "daemon_failed");
    }

    #[tokio::test]
    async fn main_future_panic_finishes_with_private_fatal_evidence() {
        if std::env::var_os("ZC_EVIDENCE_HARNESS").is_some() {
            let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
            let dir = SecureDir::open(&path).unwrap();
            let lock = Arc::new(dir.lock("zc.lock", Duration::from_secs(1)).unwrap());
            let evidence =
                Evidence::start(&path, "0123456789abcdef0123456789abcdef", lock).unwrap();
            let mut phase = "startup";
            // Poll once to Pending, then panic on the main task, not a spawned worker.
            let result = catch_instance_panic(async {
                tokio::task::yield_now().await;
                phase = "runtime";
                panic!("credential=private-main-future-payload");
            })
            .await;
            let error = result.as_ref().unwrap_err();
            assert_eq!(
                error.to_string(),
                "RUNTIME_FAILED: instance future panicked"
            );
            let started = Instant::now();
            evidence.finish(phase, result.as_ref().err()).await;
            assert!(started.elapsed() < Duration::from_secs(3));
            assert!(!path.join(EXIT_MARKER).exists());
            crate::daemon::log(1000, false, true).await.unwrap();
            return;
        }
        let (_, output) = harness(
            "observability::tests::main_future_panic_finishes_with_private_fatal_evidence",
            "main",
        );
        assert!(output.status.success(), "{output:?}");
        let stdout = String::from_utf8(output.stdout).unwrap();
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(!stdout.contains("private-main-future-payload"));
        assert!(!stderr.contains("private-main-future-payload"));
        let events: Vec<Value> = stdout
            .lines()
            .filter_map(|line| {
                let envelope: Value = serde_json::from_str(line).ok()?;
                serde_json::from_str(envelope["line"].as_str()?).ok()
            })
            .collect();
        assert_eq!(
            events
                .iter()
                .filter(|e| e["event"] == "runtime_panic")
                .count(),
            1
        );
        let summary = events
            .iter()
            .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
            .unwrap();
        assert_eq!(summary["panics"], 1);
        let last = events.last().unwrap();
        assert_eq!(last["event"], "daemon_failed");
        assert_eq!(last["phase"], "runtime");
        assert_eq!(last["error_kind"], "Other");
        assert!(!events.iter().any(|e| e["event"] == "daemon_stopped"));
    }

    #[tokio::test]
    async fn caught_future_drop_panic_stays_inside_cleanup_boundary() {
        if std::env::var_os("ZC_EVIDENCE_HARNESS").is_some() {
            struct DropPanic;
            impl std::future::Future for DropPanic {
                type Output = Result<()>;
                fn poll(
                    self: std::pin::Pin<&mut Self>,
                    _: &mut std::task::Context<'_>,
                ) -> std::task::Poll<Self::Output> {
                    std::task::Poll::Ready(Ok(()))
                }
            }
            impl Drop for DropPanic {
                fn drop(&mut self) {
                    panic!("private-future-drop-payload");
                }
            }
            let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
            let dir = SecureDir::open(&path).unwrap();
            let lock = Arc::new(dir.lock("zc.lock", Duration::from_secs(1)).unwrap());
            let evidence =
                Evidence::start(&path, "0123456789abcdef0123456789abcdef", lock).unwrap();
            let joined = tokio::spawn(catch_instance_panic(DropPanic)).await;
            let caught = joined.is_ok();
            let result = joined.map_err(task_error).and_then(|r| r);
            assert!(result.is_err());
            evidence.finish("runtime", result.as_ref().err()).await;
            assert!(caught, "future destructor escaped the cleanup boundary");
            return;
        }
        let (home, output) = harness(
            "observability::tests::caught_future_drop_panic_stays_inside_cleanup_boundary",
            "future-drop",
        );
        assert!(output.status.success(), "{output:?}");
        let text = std::fs::read_to_string(home.path().join("runtime/zc.log")).unwrap();
        assert!(!text.contains("private-future-drop-payload"));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("private-future-drop-payload"));
        let summary: Value = text
            .lines()
            .map(|line| serde_json::from_str::<Value>(line).unwrap())
            .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
            .unwrap();
        assert_eq!(summary["panics"], 1);
    }

    #[tokio::test]
    async fn runtime_scope_panic_drains_live_connections_before_evidence() {
        if std::env::var_os("ZC_EVIDENCE_HARNESS").is_some() {
            use tokio::io::{AsyncReadExt, AsyncWriteExt};
            let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
            let dir = SecureDir::open(&path).unwrap();
            let lock = Arc::new(dir.lock("zc.lock", Duration::from_secs(1)).unwrap());
            let evidence =
                Evidence::start(&path, "0123456789abcdef0123456789abcdef", lock).unwrap();
            let runtime = crate::runtime::Runtime::bind(
                crate::config::Config::parse("rules: ['MATCH,DIRECT']").unwrap(),
                0,
            )
            .await
            .unwrap()
            .with_observer(evidence.observer.clone());
            let addr = runtime.local_addr().unwrap();
            let (panic_now, trigger) = tokio::sync::oneshot::channel();
            let driver = async {
                let mut client = tokio::net::TcpStream::connect(addr).await.unwrap();
                client.write_all(&[5, 1, 0]).await.unwrap();
                let mut method = [0; 2];
                client.read_exact(&mut method).await.unwrap();
                assert_eq!(method, [5, 0]);
                assert_eq!(evidence.observer.active.load(Ordering::Relaxed), 1);
                panic_now.send(()).unwrap();
                // Keep the accepted connection live, with an incomplete request.
                client
            };
            let run = catch_instance_panic(runtime.run(async {
                trigger.await.unwrap();
                panic!("private-listener-panic");
            }));
            let (result, _client) = tokio::join!(run, driver);
            // No yield/retry: run returning must itself certify task destruction.
            let active = evidence.observer.active.load(Ordering::Relaxed);
            evidence.finish("runtime", result.as_ref().err()).await;
            assert_eq!(active, 0, "listener returned with live child tasks");
            assert!(!path.join(EXIT_MARKER).exists());
            return;
        }
        let (home, output) = harness(
            "observability::tests::runtime_scope_panic_drains_live_connections_before_evidence",
            "nested-runtime",
        );
        assert!(output.status.success(), "{output:?}");
        let text = std::fs::read_to_string(home.path().join("runtime/zc.log")).unwrap();
        assert!(!text.contains("private-listener-panic"));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("private-listener-panic"));
        let events: Vec<Value> = text
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let summary = events
            .iter()
            .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
            .unwrap();
        assert_eq!(summary["active_connections"], 0);
        assert_eq!(summary["total_connections"], 1);
        assert_eq!(summary["panics"], 1);
        assert_eq!(events.last().unwrap()["event"], "daemon_failed");
    }

    #[tokio::test]
    async fn runtime_panic_drains_trojan_udp_worker() {
        if std::env::var_os("ZC_EVIDENCE_HARNESS").is_some() {
            use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
            use tokio::{
                io::{AsyncReadExt, AsyncWriteExt},
                net::{TcpListener, TcpStream, UdpSocket},
            };
            let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
            let dir = SecureDir::open(&path).unwrap();
            let lock = Arc::new(dir.lock("zc.lock", Duration::from_secs(1)).unwrap());
            let evidence =
                Evidence::start(&path, "0123456789abcdef0123456789abcdef", lock).unwrap();
            let peer = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let config = crate::config::Config::parse(&format!("proxies: [{{name: edge, type: trojan, server: 127.0.0.1, port: {}, password: password, udp: true, skip-cert-verify: true}}]\nrules: ['MATCH,edge']", peer.local_addr().unwrap().port())).unwrap();
            let runtime = crate::runtime::Runtime::bind(config, 0)
                .await
                .unwrap()
                .with_observer(evidence.observer.clone());
            let addr = runtime.local_addr().unwrap();
            let server = rustls::ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::aws_lc_rs::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .unwrap()
            .with_no_client_auth()
            .with_single_cert(
                vec![
                    CertificateDer::from_pem_slice(include_bytes!(
                        "../testdata/e2e/trojan-cert.pem"
                    ))
                    .unwrap(),
                ],
                PrivateKeyDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-key.pem"))
                    .unwrap(),
            )
            .unwrap();
            let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(server));
            let (panic_now, trigger) = tokio::sync::oneshot::channel();
            let baseline = tokio::runtime::Handle::current()
                .metrics()
                .num_alive_tasks();
            let driver = async {
                let mut control = TcpStream::connect(addr).await.unwrap();
                control
                    .write_all(&[5, 1, 0, 5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
                    .await
                    .unwrap();
                let mut reply = [0; 12];
                control.read_exact(&mut reply).await.unwrap();
                assert_eq!(&reply[..6], &[5, 0, 5, 0, 0, 1]);
                let relay = std::net::SocketAddr::from((
                    [reply[6], reply[7], reply[8], reply[9]],
                    u16::from_be_bytes([reply[10], reply[11]]),
                ));
                let udp = UdpSocket::bind("127.0.0.1:0").await.unwrap();
                udp.send_to(b"\0\0\0\x01\x7f\0\0\x01\0\x35query", relay)
                    .await
                    .unwrap();
                let (stream, _) = peer.accept().await.unwrap();
                let mut tls = acceptor.accept(stream).await.unwrap();
                tls.read_exact(&mut [0; 68]).await.unwrap();
                let mut frame = [0; 16];
                tls.read_exact(&mut frame).await.unwrap();
                assert_eq!(&frame, b"\x01\x7f\0\0\x01\0\x35\0\x05\r\nquery");
                tls.write_all(b"\x01\x7f").await.unwrap();
                tls.flush().await.unwrap();
                assert_eq!(evidence.observer.active.load(Ordering::Relaxed), 1);
                assert!(
                    tokio::runtime::Handle::current()
                        .metrics()
                        .num_alive_tasks()
                        >= baseline + 2
                );
                panic_now.send(()).unwrap();
                (control, tls)
            };
            let run = catch_instance_panic(runtime.run(async {
                trigger.await.unwrap();
                panic!("private-udp-listener-panic");
            }));
            let (result, (_control, _tls)) = tokio::join!(run, driver);
            // Before yielding for evidence: the real connection and worker are gone.
            let remaining = tokio::runtime::Handle::current()
                .metrics()
                .num_alive_tasks();
            assert_eq!(
                remaining, baseline,
                "nested Trojan worker survived Runtime::run"
            );
            assert_eq!(evidence.observer.active.load(Ordering::Relaxed), 0);
            evidence.finish("runtime", result.as_ref().err()).await;
            return;
        }
        let (home, output) = harness(
            "observability::tests::runtime_panic_drains_trojan_udp_worker",
            "nested-udp",
        );
        assert!(output.status.success(), "{output:?}");
        let text = std::fs::read_to_string(home.path().join("runtime/zc.log")).unwrap();
        assert!(!text.contains("private-udp-listener-panic"));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("private-udp-listener-panic"));
        let events: Vec<Value> = text
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        let summary = events
            .iter()
            .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
            .unwrap();
        assert_eq!(summary["active_connections"], 0);
        assert_eq!(summary["total_connections"], 1);
        assert_eq!(summary["panics"], 1);
        assert_eq!(events.last().unwrap()["event"], "daemon_failed");
    }

    #[test]
    fn disconnected_reporter_flushes_panic_without_certifying_exit() {
        if std::env::var_os("ZC_EVIDENCE_HARNESS").is_some() {
            let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
            let dir = SecureDir::open(&path).unwrap();
            let lock = Arc::new(dir.lock("zc.lock", Duration::from_secs(1)).unwrap());
            let log = Arc::new(EventLog {
                dir,
                path: path.clone(),
                lock,
                nonce: "0123456789abcdef0123456789abcdef".into(),
                writer: Mutex::new(()),
            });
            let marker = log.begin_marker().unwrap();
            let observer = Arc::new(Observer::new());
            let _hook = PanicHook::install(observer.clone());
            assert!(std::panic::catch_unwind(|| panic!("private-disconnect-payload")).is_err());
            let (sender, receiver) = mpsc::sync_channel(1);
            drop(sender);
            Reporter::new(log, observer).run(receiver, Some(&marker));
            assert_eq!(std::fs::read(path.join(EXIT_MARKER)).unwrap(), marker);
            return;
        }
        let (home, output) = harness(
            "observability::tests::disconnected_reporter_flushes_panic_without_certifying_exit",
            "disconnect",
        );
        assert!(output.status.success(), "{output:?}");
        let text = std::fs::read_to_string(home.path().join("runtime/zc.log")).unwrap();
        assert!(!text.contains("private-disconnect-payload"));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("private-disconnect-payload"));
        let events: Vec<Value> = text
            .lines()
            .map(|line| serde_json::from_str(line).unwrap())
            .collect();
        assert_eq!(
            events
                .iter()
                .filter(|e| e["event"] == "runtime_panic")
                .count(),
            1,
            "{events:?}"
        );
        assert!(
            !events
                .iter()
                .any(|e| e["event"] == "daemon_stopped" || e["event"] == "daemon_failed")
        );
        assert!(home.path().join("runtime").join(EXIT_MARKER).exists());
    }

    #[test]
    fn resource_sampler_deadline_and_bad_output_reap_the_child() {
        for (script, expected) in [
            ("exec /bin/sleep 30", "resource sampler timed out"),
            ("printf '%01025d' 0", "resource output exceeds limit"),
            ("printf 'invalid 12'", "invalid CPU time"),
        ] {
            let child = Reap(
                Command::new("/bin/sh")
                    .args(["-c", script])
                    .env_clear()
                    .stdin(Stdio::null())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::null())
                    .spawn()
                    .unwrap(),
            );
            let pid = rustix::process::Pid::from_raw(child.0.id() as i32).unwrap();
            let started = Instant::now();
            let error = read_resources(child)
                .err()
                .expect("invalid resource sample accepted");
            assert_eq!(error.to_string(), expected);
            assert!(started.elapsed() < Duration::from_secs(2));
            assert!(
                rustix::process::test_kill_process(pid).is_err(),
                "sampler child survived or was not reaped"
            );
        }
    }

    #[tokio::test]
    async fn panic_finish_deadline_does_not_wait_for_a_stalled_sink() {
        if std::env::var_os("ZC_EVIDENCE_HARNESS").is_some() {
            let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
            let dir = SecureDir::open(&path).unwrap();
            let lock = Arc::new(dir.lock("zc.lock", Duration::from_secs(1)).unwrap());
            let evidence =
                Evidence::start(&path, "0123456789abcdef0123456789abcdef", lock).unwrap();
            let log = evidence.log.clone();
            let remaining = Arc::downgrade(&log);
            let (held, wait_held) = mpsc::sync_channel(0);
            let (release, wait_release) = mpsc::sync_channel(0);
            let holder = std::thread::spawn(move || {
                let _guard = log.writer.lock().unwrap();
                held.send(()).unwrap();
                let _ = wait_release.recv_timeout(Duration::from_secs(4));
            });
            wait_held.recv_timeout(Duration::from_secs(1)).unwrap();
            let result = catch_instance_panic(async {
                panic!("private-stalled-panic");
            })
            .await;
            let started = Instant::now();
            evidence.finish("runtime", result.as_ref().err()).await;
            assert!((Duration::from_secs(2)..Duration::from_secs(3)).contains(&started.elapsed()));
            assert!(
                path.join(EXIT_MARKER).exists(),
                "uncertified exit marker was removed"
            );
            release.send(()).unwrap();
            holder.join().unwrap();
            let deadline = Instant::now() + Duration::from_secs(2);
            while remaining.upgrade().is_some() {
                assert!(
                    Instant::now() < deadline,
                    "reporter did not release instance ownership"
                );
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
            assert!(!path.join(EXIT_MARKER).exists());
            let _lock = dir.lock("zc.lock", Duration::from_millis(50)).unwrap();
            return;
        }
        let (home, output) = harness(
            "observability::tests::panic_finish_deadline_does_not_wait_for_a_stalled_sink",
            "deadline",
        );
        assert!(output.status.success(), "{output:?}");
        let text = std::fs::read_to_string(home.path().join("runtime/zc.log")).unwrap();
        assert!(!text.contains("private-stalled-panic"));
        assert!(!String::from_utf8_lossy(&output.stderr).contains("private-stalled-panic"));
        let last: Value = serde_json::from_str(text.lines().last().unwrap()).unwrap();
        assert_eq!(last["event"], "daemon_failed");
    }

    #[tokio::test]
    async fn panic_evidence_is_private_bounded_and_restores_the_hook_in_a_subprocess() {
        if std::env::var_os("ZC_EVIDENCE_HARNESS").is_some() {
            let path = PathBuf::from(std::env::var_os("XDG_RUNTIME_DIR").unwrap());
            let dir = SecureDir::open(&path).unwrap();
            let lock = Arc::new(dir.lock("zc.lock", Duration::from_secs(1)).unwrap());
            let restored = Arc::new(AtomicU64::new(0));
            let count = restored.clone();
            let original = std::panic::take_hook();
            std::panic::set_hook(Box::new(move |_| {
                count.fetch_add(1, Ordering::Relaxed);
            }));
            let evidence =
                Evidence::start(&path, "0123456789abcdef0123456789abcdef", lock).unwrap();
            for _ in 0..20 {
                assert!(
                    std::thread::spawn(|| panic!("credential=never-serialize-this-panic"))
                        .join()
                        .is_err()
                );
            }
            evidence.finish("stop_request", None).await;
            assert_eq!(restored.load(Ordering::Relaxed), 0);
            assert!(
                std::thread::spawn(|| panic!("restored hook"))
                    .join()
                    .is_err()
            );
            assert_eq!(restored.load(Ordering::Relaxed), 1);
            std::panic::set_hook(original);
            crate::daemon::log(1000, false, true).await.unwrap();
            return;
        }
        let (_, output) = harness(
            "observability::tests::panic_evidence_is_private_bounded_and_restores_the_hook_in_a_subprocess",
            "hook",
        );
        assert!(output.status.success(), "{output:?}");
        let stdout = String::from_utf8(output.stdout).unwrap();
        let stderr = String::from_utf8(output.stderr).unwrap();
        assert!(!stdout.contains("never-serialize-this-panic"));
        assert!(!stderr.contains("never-serialize-this-panic"));
        let events: Vec<Value> = stdout
            .lines()
            .filter_map(|line| {
                let envelope: Value = serde_json::from_str(line).ok()?;
                serde_json::from_str(envelope["line"].as_str()?).ok()
            })
            .collect();
        let panics: Vec<_> = events
            .iter()
            .filter(|e| e["event"] == "runtime_panic")
            .collect();
        assert_eq!(panics.len(), 1, "{events:?}");
        assert!(!panics[0].as_object().unwrap().contains_key("location"));
        assert!(!panics[0].as_object().unwrap().contains_key("payload"));
        let summary = events
            .iter()
            .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
            .unwrap();
        assert_eq!(summary["panics"], 20);
    }
}
