#[path = "support/cli_fixture.rs"]
mod cli_fixture;
use serde_json::Value;
use std::{
    fs,
    net::TcpListener,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Child, Command, Output, Stdio},
    time::{Duration, Instant},
};

struct ChildGuard(Child);
impl std::ops::Deref for ChildGuard {
    type Target = Child;
    fn deref(&self) -> &Child {
        &self.0
    }
}
impl std::ops::DerefMut for ChildGuard {
    fn deref_mut(&mut self) -> &mut Child {
        &mut self.0
    }
}
impl Drop for ChildGuard {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}

struct Fixture {
    _home: tempfile::TempDir,
    home: PathBuf,
    runtime: PathBuf,
    config: PathBuf,
    port: u16,
    _serial: std::sync::MutexGuard<'static, ()>,
}
impl Fixture {
    fn new() -> Self {
        let serial = cli_fixture::serial();
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().canonicalize().unwrap();
        let runtime = home.join("runtime");
        fs::create_dir(&runtime).unwrap();
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
        let config = home.join("config.yaml");
        fs::write(&config, "rules: ['MATCH,DIRECT']\n").unwrap();
        let port = TcpListener::bind("127.0.0.1:0")
            .unwrap()
            .local_addr()
            .unwrap()
            .port();
        assert_ne!(port, 7899);
        Self {
            _home: temp,
            home,
            runtime,
            config,
            port,
            _serial: serial,
        }
    }
    fn command(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_zc"));
        command
            .env("HOME", &self.home)
            .env("XDG_RUNTIME_DIR", &self.runtime);
        command
    }
    fn output(&self, args: &[&str]) -> Output {
        self.command().args(args).output().unwrap()
    }
    fn json(&self, args: &[&str]) -> Value {
        let output = self.output(args);
        assert!(output.status.success(), "{output:?}");
        serde_json::from_slice(&output.stdout).unwrap()
    }
    fn start(&self) -> Value {
        self.json(&[
            "start",
            "-c",
            self.config.to_str().unwrap(),
            "--port",
            &self.port.to_string(),
            "--json",
        ])
    }
    fn foreground(&self) -> ChildGuard {
        ChildGuard(
            self.command()
                .args([
                    "start",
                    "--foreground",
                    "-c",
                    self.config.to_str().unwrap(),
                    "--port",
                    &self.port.to_string(),
                    "--json",
                ])
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .unwrap(),
        )
    }
    fn events(&self) -> Vec<Value> {
        let output = self.output(&["log", "--json", "--no-follow", "-n", "1000"]);
        assert!(output.status.success(), "{output:?}");
        String::from_utf8(output.stdout)
            .unwrap()
            .lines()
            .filter_map(|line| {
                let envelope: Value = serde_json::from_str(line).unwrap();
                serde_json::from_str(envelope["line"].as_str().unwrap()).ok()
            })
            .collect()
    }
    fn wait_ready(&self) {
        wait_until(|| self.json(&["status", "--json"])["data"]["state"] == "running");
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.output(&["stop", "--json"]);
    }
}
fn wait_until(mut check: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(10);
    while !check() {
        assert!(Instant::now() < deadline, "condition did not settle");
        std::thread::sleep(Duration::from_millis(25));
    }
}

#[test]
fn cli_reports_initial_and_final_resource_snapshots() {
    let f = Fixture::new();
    let started = f.start();
    f.json(&["stop", "--json"]);
    let events = f.events();
    let summaries: Vec<_> = events
        .iter()
        .filter(|event| event["event"] == "runtime_summary")
        .collect();
    assert_eq!(
        summaries.len(),
        2,
        "missing initial/final resource evidence: {events:?}"
    );
    assert_eq!(summaries[0]["phase"], "initial");
    assert_eq!(summaries[1]["phase"], "final");
    for summary in &summaries {
        assert_eq!(summary["pid"], started["data"]["pid"]);
        assert_eq!(summary["active_connections"], 0);
        assert_eq!(summary["total_connections"], 0);
        assert_eq!(summary["rejections"], 0);
        assert_eq!(summary["sample_interval_seconds"], 30);
        assert!(summary["uptime_ms"].is_u64());
        if summary["resource_status"] == "available" {
            assert!(summary["rss_bytes"].as_u64().unwrap() > 0);
            assert!(summary["cpu_time_ms"].is_u64());
        } else {
            assert_eq!(summary["resource_status"], "unavailable");
            assert!(summary["rss_bytes"].is_null());
            assert!(summary["cpu_time_ms"].is_null());
        }
    }
    assert!(summaries[0]["cpu_delta_ms"].is_null());
    assert!(summaries[1]["uptime_ms"].as_u64() >= summaries[0]["uptime_ms"].as_u64());
    assert_eq!(events.last().unwrap()["event"], "daemon_stopped");
}

#[test]
fn killed_isolated_child_is_reported_on_next_start_but_clean_exit_is_not() {
    let f = Fixture::new();
    let mut child = f.foreground();
    f.wait_ready();
    let old_pid = child.id();
    child.kill().unwrap();
    child.wait().unwrap();
    f.start();
    f.json(&["stop", "--json"]);
    let events = f.events();
    let unknown: Vec<_> = events
        .iter()
        .filter(|e| e["event"] == "previous_exit_unknown")
        .collect();
    assert_eq!(
        unknown.len(),
        1,
        "unclean exit was not retained: {events:?}"
    );
    assert_eq!(unknown[0]["previous_pid"], old_pid);
    assert_ne!(unknown[0]["previous_instance"], unknown[0]["instance"]);
    f.start();
    f.json(&["stop", "--json"]);
    assert_eq!(
        f.events()
            .iter()
            .filter(|e| e["event"] == "previous_exit_unknown")
            .count(),
        1
    );
}

#[test]
fn sigterm_is_a_clean_exit_with_final_resource_evidence() {
    let f = Fixture::new();
    let mut child = f.foreground();
    f.wait_ready();
    rustix::process::kill_process(
        rustix::process::Pid::from_raw(child.id() as i32).unwrap(),
        rustix::process::Signal::TERM,
    )
    .unwrap();
    wait_until(|| child.try_wait().unwrap().is_some());
    assert!(child.wait().unwrap().success());
    let events = f.events();
    assert!(
        events
            .iter()
            .any(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
    );
    assert_eq!(events.last().unwrap()["event"], "daemon_stopped");
    assert_eq!(events.last().unwrap()["phase"], "sigterm");
    f.start();
    f.json(&["stop", "--json"]);
    assert!(
        !f.events()
            .iter()
            .any(|e| e["event"] == "previous_exit_unknown")
    );
}

fn fill_log(f: &Fixture, event: &str) {
    let tail = format!("{{\"event\":\"{event}\"}}\n");
    let mut bytes = vec![b'\n'; 8 * 1024 * 1024 - 32 - tail.len()];
    bytes.extend_from_slice(tail.as_bytes());
    let path = f.runtime.join("fixture-log.next");
    fs::write(&path, bytes).unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600)).unwrap();
    fs::rename(&path, f.runtime.join("zc.log")).unwrap();
}

#[test]
fn bounded_rotation_retains_one_private_archive_readable_through_log_json() {
    let f = Fixture::new();
    fill_log(&f, "first_archive_tail");
    f.start();
    assert!(
        f.runtime.join("zc.log.1").exists(),
        "full log was discarded instead of archived"
    );
    assert!(
        f.events()
            .iter()
            .any(|e| e["event"] == "first_archive_tail")
    );
    wait_until(|| {
        f.events()
            .iter()
            .any(|e| e["event"] == "runtime_summary" && e["phase"] == "initial")
    });
    fill_log(&f, "second_archive_tail");
    f.json(&["stop", "--json"]);
    let events = f.events();
    assert!(events.iter().any(|e| e["event"] == "second_archive_tail"));
    assert!(!events.iter().any(|e| e["event"] == "first_archive_tail"));
    for name in ["zc.log", "zc.log.1"] {
        let metadata = fs::metadata(f.runtime.join(name)).unwrap();
        assert!(metadata.len() <= 8 * 1024 * 1024);
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    }
    assert!(!f.runtime.join("zc.log.2").exists());
}

#[test]
fn corrupt_exit_marker_is_preserved_and_does_not_become_process_authority() {
    let f = Fixture::new();
    let marker = f.runtime.join("zc.exit.json");
    let bytes = b"{corrupt:credential=private-marker-data}\n";
    fs::write(&marker, bytes).unwrap();
    fs::set_permissions(&marker, fs::Permissions::from_mode(0o600)).unwrap();
    f.start();
    f.json(&["stop", "--json"]);
    assert_eq!(fs::read(&marker).unwrap(), bytes);
    let events = f.events();
    assert!(events.iter().any(|e| e["event"] == "exit_marker_invalid"));
    assert!(!events.iter().any(|e| e["event"] == "previous_exit_unknown"));
    assert!(!format!("{events:?}").contains("private-marker-data"));

    // Even a valid marker naming this live test process is diagnostic only.
    let bytes = format!(
        "{{\"schema_version\":1,\"pid\":{},\"instance\":\"0123456789abcdef0123456789abcdef\"}}\n",
        std::process::id()
    );
    fs::write(&marker, bytes).unwrap();
    f.start();
    f.json(&["stop", "--json"]);
    assert!(
        f.events()
            .iter()
            .any(|e| e["event"] == "previous_exit_unknown"
                && e["previous_pid"] == std::process::id())
    );
}

#[test]
fn failed_bind_has_final_evidence_and_does_not_claim_an_unclean_exit() {
    let mut f = Fixture::new();
    let listener = TcpListener::bind("127.0.0.1:0").unwrap();
    f.port = listener.local_addr().unwrap().port();
    assert_ne!(f.port, 7899);
    fs::write(
        &f.config,
        "secret: do-not-log-this-secret\nrules: ['MATCH,DIRECT']\n",
    )
    .unwrap();
    let output = f.output(&[
        "start",
        "--foreground",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &listener.local_addr().unwrap().port().to_string(),
        "--json",
    ]);
    assert!(!output.status.success());
    let events = f.events();
    let failed = events
        .iter()
        .find(|e| e["event"] == "daemon_failed")
        .unwrap();
    assert_eq!(failed["phase"], "mixed_bind");
    assert_eq!(failed["error_kind"], "AddrInUse");
    assert!(
        events
            .iter()
            .any(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
    );
    assert!(!events.iter().any(|e| e["event"] == "daemon_ready"));
    assert!(!format!("{events:?}").contains("do-not-log-this-secret"));
    assert!(!format!("{events:?}").contains(f.config.to_str().unwrap()));
    // The collision socket must be released before testing successful recovery.
    // Two sequential ephemeral allocations are allowed to return the same port.
    drop(listener);
    f.start();
    f.json(&["stop", "--json"]);
    assert!(
        !f.events()
            .iter()
            .any(|e| e["event"] == "previous_exit_unknown")
    );
}

#[test]
fn unsafe_archive_is_never_followed_or_replaced() {
    for kind in ["symlink", "hardlink", "fifo"] {
        let f = Fixture::new();
        fill_log(&f, "retained");
        let outside = f.home.join("outside");
        fs::write(&outside, "outside-secret").unwrap();
        fs::set_permissions(&outside, fs::Permissions::from_mode(0o600)).unwrap();
        let archive = f.runtime.join("zc.log.1");
        match kind {
            "symlink" => std::os::unix::fs::symlink(&outside, &archive).unwrap(),
            "hardlink" => fs::hard_link(&outside, &archive).unwrap(),
            "fifo" => {
                assert!(
                    Command::new("mkfifo")
                        .arg(&archive)
                        .status()
                        .unwrap()
                        .success()
                );
            }
            _ => unreachable!(),
        }
        let output = f.output(&[
            "start",
            "--foreground",
            "-c",
            f.config.to_str().unwrap(),
            "--port",
            &f.port.to_string(),
            "--json",
        ]);
        assert!(!output.status.success(), "unsafe archive accepted: {kind}");
        assert_eq!(fs::read(&outside).unwrap(), b"outside-secret");
        assert!(fs::symlink_metadata(&archive).is_ok());
        assert_eq!(f.json(&["status", "--json"])["data"]["state"], "stopped");
    }
}

#[test]
fn real_socks_tunnel_is_counted_in_periodic_resources_and_released_at_shutdown() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    let origin = TcpListener::bind("127.0.0.1:0").unwrap();
    let port = origin.local_addr().unwrap().port();
    f.start();
    let mut client = std::net::TcpStream::connect(("127.0.0.1", f.port)).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    client.write_all(&[5, 1, 0]).unwrap();
    let mut method = [0; 2];
    client.read_exact(&mut method).unwrap();
    assert_eq!(method, [5, 0]);
    let mut request = vec![5, 1, 0, 1, 127, 0, 0, 1];
    request.extend_from_slice(&port.to_be_bytes());
    client.write_all(&request).unwrap();
    let mut reply = [0; 10];
    client.read_exact(&mut reply).unwrap();
    assert_eq!(&reply[..4], &[5, 0, 0, 1]);
    let (mut peer, _) = origin.accept().unwrap();
    peer.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
    client.write_all(b"resource-evidence").unwrap();
    let mut payload = [0; 17];
    peer.read_exact(&mut payload).unwrap();
    assert_eq!(&payload, b"resource-evidence");
    let deadline = Instant::now() + Duration::from_secs(35);
    let periodic = loop {
        if let Some(summary) = f
            .events()
            .into_iter()
            .find(|e| e["event"] == "runtime_summary" && e["phase"] == "periodic")
        {
            break summary;
        }
        assert!(Instant::now() < deadline, "missing 30-second sample");
        std::thread::sleep(Duration::from_millis(200));
    };
    assert_eq!(periodic["active_connections"], 1);
    assert_eq!(periodic["total_connections"], 1);
    assert_eq!(periodic["failures"], 0);
    assert!(periodic["uptime_ms"].as_u64().unwrap() >= 30_000);
    if periodic["resource_status"] == "available" {
        assert!(periodic["cpu_delta_ms"].is_u64());
        assert!(periodic["sample_elapsed_ms"].as_u64().unwrap() >= 30_000);
        assert!(periodic["rss_delta_bytes"].is_i64());
    }
    // Stop cancels a live tunnel, proving RAII decrements the active counter.
    f.json(&["stop", "--json"]);
    let events = f.events();
    let final_summary = events
        .iter()
        .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
        .unwrap();
    assert_eq!(final_summary["active_connections"], 0);
    assert_eq!(final_summary["total_connections"], 1);
    assert_eq!(final_summary["failures"], 0);
}

#[cfg(target_os = "macos")]
#[test]
fn unavailable_resource_sampler_is_null_and_does_not_stop_the_daemon() {
    let f = Fixture::new();
    let mut child = ChildGuard(
        Command::new("/usr/bin/sandbox-exec")
            .args([
                "-p",
                "(version 1)(allow default)(deny process-exec (literal \"/bin/ps\"))",
                env!("CARGO_BIN_EXE_zc"),
                "start",
                "--foreground",
                "-c",
                f.config.to_str().unwrap(),
                "--port",
                &f.port.to_string(),
                "--json",
            ])
            .env("HOME", &f.home)
            .env("XDG_RUNTIME_DIR", &f.runtime)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    f.wait_ready();
    f.json(&["stop", "--json"]);
    wait_until(|| child.try_wait().unwrap().is_some());
    assert!(child.wait().unwrap().success());
    let events = f.events();
    let samples: Vec<_> = events
        .iter()
        .filter(|e| e["event"] == "runtime_summary")
        .collect();
    assert_eq!(samples.len(), 2);
    for sample in samples {
        assert_eq!(sample["resource_status"], "unavailable");
        for field in [
            "rss_bytes",
            "cpu_time_ms",
            "cpu_delta_ms",
            "rss_delta_bytes",
            "sample_elapsed_ms",
        ] {
            assert!(
                sample[field].is_null(),
                "unavailable metric must not be fabricated: {field}"
            );
        }
    }
}

#[test]
fn log_follow_reopens_the_rotated_current_file_with_the_same_json_envelope() {
    use std::io::BufRead;
    let f = Fixture::new();
    f.start();
    wait_until(|| {
        f.events()
            .iter()
            .any(|e| e["event"] == "runtime_summary" && e["phase"] == "initial")
    });
    fill_log(&f, "follow_seed");
    let mut child = ChildGuard(
        f.command()
            .args(["log", "-f", "--json", "-n", "1"])
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let stdout = child.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::sync_channel(16);
    let reader = std::thread::spawn(move || {
        for line in std::io::BufReader::new(stdout).lines() {
            if tx.send(line.unwrap()).is_err() {
                break;
            }
        }
    });
    let first: Value =
        serde_json::from_str(&rx.recv_timeout(Duration::from_secs(3)).unwrap()).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(first["line"].as_str().unwrap()).unwrap()["event"],
        "follow_seed"
    );
    f.json(&["stop", "--json"]);
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let line = rx
            .recv_timeout(deadline.saturating_duration_since(Instant::now()))
            .unwrap();
        let envelope: Value = serde_json::from_str(&line).unwrap();
        let event: Value = serde_json::from_str(envelope["line"].as_str().unwrap()).unwrap();
        if event["event"] == "daemon_stopped" {
            break;
        }
    }
    drop(child);
    reader.join().unwrap();
    assert!(f.runtime.join("zc.log.1").exists());
}

#[test]
fn repeated_faults_emit_one_first_event_then_a_bounded_final_summary() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    let reserved = TcpListener::bind("127.0.0.1:0").unwrap();
    let closed = reserved.local_addr().unwrap().port();
    drop(reserved);
    f.start();
    for _ in 0..64 {
        let mut client = std::net::TcpStream::connect(("127.0.0.1", f.port)).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        write!(client, "CONNECT 127.0.0.1:{closed} HTTP/1.1\r\nHost: 127.0.0.1:{closed}\r\nAuthorization: Bearer private-burst-token\r\n\r\n").unwrap();
        let mut response = String::new();
        client.read_to_string(&mut response).unwrap();
        assert!(response.starts_with("HTTP/1.1 502"));
    }
    f.json(&["stop", "--json"]);
    let events = f.events();
    let failures: Vec<_> = events
        .iter()
        .filter(|e| e["event"] == "connection_failed" || e["event"] == "connection_failure_summary")
        .collect();
    assert_eq!(failures.len(), 2, "{events:?}");
    assert_eq!(failures[0]["event"], "connection_failed");
    assert_eq!(failures[0]["count"], 1);
    assert_eq!(failures[1]["event"], "connection_failure_summary");
    assert_eq!(failures[1]["count"], 63);
    assert_eq!(failures[1]["total"], 64);
    assert!(
        failures
            .iter()
            .all(|e| e["stage"] == "connect" && e["error_kind"] == "ConnectionRefused")
    );
    assert!(!format!("{events:?}").contains("private-burst-token"));
}

#[test]
fn ready_log_failure_does_not_stop_a_published_instance() {
    use zc::fsutil::SecureDir;
    let f = Fixture::new();
    let guardian = SecureDir::open_owned_absolute(&f.home, false)
        .unwrap()
        .owned_child(".local", true, false)
        .unwrap()
        .owned_child("state", true, false)
        .unwrap()
        .owned_child("zc", true, false)
        .unwrap();
    let gate = guardian
        .lock("zc.lifecycle.lock", Duration::from_secs(1))
        .unwrap();
    let mut child = f.foreground();
    wait_until(|| {
        f.events()
            .iter()
            .any(|e| e["event"] == "runtime_summary" && e["phase"] == "initial")
    });
    let dir = SecureDir::open(&f.runtime).unwrap();
    let blocked_log = dir.lock("zc.log.lock", Duration::from_secs(1)).unwrap();
    drop(gate);
    f.wait_ready();
    // Exceed the logger's lock deadline; readiness must remain authoritative.
    std::thread::sleep(Duration::from_millis(250));
    assert!(
        child.try_wait().unwrap().is_none(),
        "ready logger failure stopped the instance"
    );
    assert_eq!(f.json(&["status", "--json"])["data"]["state"], "running");
    drop(blocked_log);
    f.json(&["stop", "--json"]);
    wait_until(|| child.try_wait().unwrap().is_some());
    assert!(child.wait().unwrap().success());
    assert_eq!(f.events().last().unwrap()["event"], "daemon_stopped");
}

#[test]
fn nonfollow_log_waits_for_rotation_and_reads_one_snapshot() {
    let f = Fixture::new();
    let dir = zc::fsutil::SecureDir::open(&f.runtime).unwrap();
    dir.atomic_write("zc.log.1", b"old\n").unwrap();
    dir.atomic_write("zc.log", b"current\n").unwrap();
    let rotating = dir.lock("zc.log.lock", Duration::from_secs(1)).unwrap();
    let mut child = ChildGuard(
        f.command()
            .args(["log", "--json", "--no-follow", "-n", "10"])
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .unwrap(),
    );
    std::thread::sleep(Duration::from_millis(500));
    assert!(
        child.try_wait().unwrap().is_none(),
        "snapshot bypassed the rotation lock"
    );
    dir.rename("zc.log", "zc.log.1").unwrap();
    dir.atomic_write("zc.log", b"next\n").unwrap();
    drop(rotating);
    wait_until(|| child.try_wait().unwrap().is_some());
    assert!(child.wait().unwrap().success());
    let mut text = String::new();
    use std::io::Read;
    child
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut text)
        .unwrap();
    let lines: Vec<Value> = text
        .lines()
        .map(|line| serde_json::from_str(line).unwrap())
        .collect();
    assert_eq!(
        lines,
        [
            serde_json::json!({"line":"current"}),
            serde_json::json!({"line":"next"})
        ]
    );
}

#[test]
fn nonfollow_log_reads_an_archive_without_a_current_file() {
    let f = Fixture::new();
    let dir = zc::fsutil::SecureDir::open(&f.runtime).unwrap();
    dir.atomic_write("zc.log.1", b"{\"event\":\"retained\"}\n")
        .unwrap();
    assert_eq!(f.events(), [serde_json::json!({"event":"retained"})]);
    assert!(!f.runtime.join("zc.log").exists());
}

#[test]
fn idle_log_maintenance_is_not_performed_on_every_atomic_poll() {
    let f = Fixture::new();
    let started = f.start();
    wait_until(|| {
        let events = f.events();
        events.iter().any(|e| e["event"] == "daemon_ready")
            && events
                .iter()
                .any(|e| e["event"] == "runtime_summary" && e["phase"] == "initial")
    });
    let log = f.runtime.join("zc.log");
    let limit = 8 * 1024 * 1024;
    let oversize = || {
        fs::OpenOptions::new()
            .write(true)
            .open(&log)
            .unwrap()
            .set_len(limit + 1)
            .unwrap();
    };
    let wait_rotated = || {
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            match fs::metadata(&log) {
                Ok(metadata) if metadata.len() == 0 => break,
                Ok(_) => (),
                Err(e) if e.kind() == std::io::ErrorKind::NotFound => (),
                Err(e) => panic!("cannot inspect rotated log: {e}"),
            }
            assert!(
                Instant::now() < deadline,
                "oversized log was not rotated within 3 seconds"
            );
            std::thread::sleep(Duration::from_millis(5));
        }
    };
    // Synchronize with a real maintenance pass, not CLI startup or the initial
    // sample: ready logging may still be pending when start returns success.
    oversize();
    wait_rotated();
    oversize();
    std::thread::sleep(Duration::from_millis(350));
    assert_eq!(
        fs::metadata(&log).unwrap().len(),
        limit + 1,
        "maintenance still runs at counter-poll frequency"
    );
    wait_rotated();
    let events = f.events();
    let warning = events
        .iter()
        .find(|e| e["event"] == "log_retention_exceeded")
        .unwrap();
    assert_eq!(warning["level"], "warn");
    assert_eq!(warning["pid"], started["data"]["pid"]);
    let descriptor: Value =
        serde_json::from_slice(&fs::read(f.runtime.join("zc.daemon.json")).unwrap()).unwrap();
    assert_eq!(warning["instance"], descriptor["nonce"]);
    assert!(warning["instance"].is_string());
    assert!(warning["timestamp_ms"].as_u64().unwrap() > 0);
    f.json(&["stop", "--json"]);
}

#[test]
fn oversized_log_warning_has_the_rotating_instances_metadata() {
    let f = Fixture::new();
    let log = f.runtime.join("zc.log");
    let file = fs::File::create(&log).unwrap();
    fs::set_permissions(&log, fs::Permissions::from_mode(0o600)).unwrap();
    file.set_len(8 * 1024 * 1024 + 1).unwrap();
    let started = f.start();
    let events = f.events();
    let ready = events
        .iter()
        .find(|e| e["event"] == "daemon_starting")
        .unwrap();
    let warning = events
        .iter()
        .find(|e| e["event"] == "log_retention_exceeded")
        .unwrap();
    assert_eq!(warning["level"], "warn");
    assert!(warning["timestamp_ms"].as_u64().unwrap() > 0);
    assert_eq!(warning["pid"], started["data"]["pid"]);
    assert_eq!(warning["instance"], ready["instance"]);
    assert!(warning["instance"].is_string());
    for name in ["zc.log", "zc.log.1"] {
        let metadata = fs::metadata(f.runtime.join(name)).unwrap();
        assert!(metadata.len() <= 8 * 1024 * 1024);
        assert_eq!(metadata.permissions().mode() & 0o777, 0o600);
    }
    assert!(!f.runtime.join("zc.log.2").exists());
}
