#[path = "support/cli_fixture.rs"]
mod cli_fixture;
use serde_json::Value;
use std::os::unix::fs::PermissionsExt;
use std::{
    fs,
    path::PathBuf,
    process::{Child, Command, Output, Stdio},
    time::{Duration, Instant},
};

struct Fixture {
    _temp: tempfile::TempDir,
    home: PathBuf,
    runtime: PathBuf,
    config: PathBuf,
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
        fs::write(
            &config,
            format!("mixed-port: {}\nrules: ['MATCH,DIRECT']\n", port()),
        )
        .unwrap();
        Self {
            _temp: temp,
            home,
            runtime,
            config,
            _serial: serial,
        }
    }
    fn command(&self, args: &[&str]) -> Command {
        let mut c = Command::new(env!("CARGO_BIN_EXE_zc"));
        c.args(args)
            .env("HOME", &self.home)
            .env("XDG_RUNTIME_DIR", &self.runtime)
            .env("XDG_CONFIG_HOME", self.home.join(".config"))
            .env("XDG_STATE_HOME", self.home.join(".local/state"))
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        c
    }
    fn run(&self, args: &[&str]) -> Output {
        self.command(args).output().unwrap()
    }
    fn json(&self, args: &[&str]) -> Value {
        let out = self.run(args);
        assert!(
            out.status.success(),
            "{} {}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }
    fn start(&self) -> (u32, u16) {
        let port = port();
        let result = self.json(&[
            "start",
            "-c",
            self.config.to_str().unwrap(),
            "--port",
            &port.to_string(),
            "--json",
        ]);
        (result["data"]["pid"].as_u64().unwrap() as u32, port)
    }
    fn descriptor(&self) -> Value {
        serde_json::from_slice(&fs::read(self.runtime.join("zc.daemon.json")).unwrap()).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        // Release script children even when an assertion fails before publication.
        let _ = fs::write(self.home.join("release"), "");
        let _ = fs::write(self.home.join("apply_release"), "");
        // Only the isolated fixture's authenticated daemon is stopped.
        let _ = self.run(&["stop", "--json"]);
    }
}
struct Process(Child);
impl Drop for Process {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
fn port() -> u16 {
    let port = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    assert_ne!(port, 7899);
    port
}
fn wait(mut check: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !check() {
        assert!(Instant::now() < deadline, "condition timed out");
        std::thread::sleep(Duration::from_millis(2));
    }
}

#[test]
fn stale_cli_restart_keeps_newer_instance_after_blocked_override() {
    let f = Fixture::new();
    f.start();
    let gate = f.home.join("gate");
    let release = f.home.join("release");
    let script = f.home.join("daemon_block.sh");
    fs::write(
        &script,
        format!(
            "#!/bin/sh\n: > '{}'\nwhile [ ! -e '{}' ]; do /bin/sleep 0.01; done\n",
            gate.display(),
            release.display()
        ),
    )
    .unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
    let stale_port = port();
    let mut paused = Process(
        f.command(&[
            "restart",
            "-c",
            f.config.to_str().unwrap(),
            "--port",
            &stale_port.to_string(),
            "--override-script",
            script.to_str().unwrap(),
            "--override-timeout-ms",
            "10000",
            "--json",
        ])
        .spawn()
        .unwrap(),
    );
    wait(|| gate.exists());
    let newer_port = port();
    f.json(&[
        "restart",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &newer_port.to_string(),
        "--json",
    ]);
    let newer = f.descriptor();
    fs::write(&release, "").unwrap();
    wait(|| paused.0.try_wait().unwrap().is_some());
    use std::io::Read;
    let mut output = String::new();
    paused
        .0
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut output)
        .unwrap();
    assert!(output.contains("RESTART_CONTENDED"), "{output}");
    assert_eq!(f.descriptor(), newer);
    assert!(std::net::TcpStream::connect(("127.0.0.1", newer_port)).is_ok());
    assert!(std::net::TcpStream::connect(("127.0.0.1", stale_port)).is_err());
}

#[test]
fn failed_readiness_handoff_cannot_publish_late_listener() {
    let f = Fixture::new();
    let guardian = f.home.join(".local/state/zc");
    fs::create_dir_all(&guardian).unwrap();
    fs::set_permissions(&guardian, fs::Permissions::from_mode(0o700)).unwrap();
    let dir = zc::fsutil::SecureDir::open(&guardian).unwrap();
    let lock = dir
        .lock("zc.lifecycle.lock", Duration::from_secs(1))
        .unwrap();
    let mixed = port();
    let mut parent = Process(
        f.command(&[
            "start",
            "-c",
            f.config.to_str().unwrap(),
            "--port",
            &mixed.to_string(),
            "--json",
        ])
        .spawn()
        .unwrap(),
    );
    wait(|| {
        fs::read_dir(&f.runtime).unwrap().any(|e| {
            e.unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".snapshot")
        })
    });
    let dir = zc::fsutil::SecureDir::open(&f.runtime).unwrap();
    dir.atomic_write("zc.daemon.json", b"{}\n").unwrap();
    wait(|| parent.0.try_wait().unwrap().is_some());
    assert!(!parent.0.wait().unwrap().success());
    drop(lock);
    std::thread::sleep(Duration::from_millis(350));
    assert!(
        std::net::TcpStream::connect(("127.0.0.1", mixed)).is_err(),
        "failed start left a live listener"
    );
    assert!(
        dir.lock("zc.lock", Duration::from_millis(100)).is_ok(),
        "failed start left a child holding its lock"
    );
    fs::remove_file(f.runtime.join("zc.daemon.json")).unwrap();
}

#[test]
fn failed_stop_revokes_request_before_suspended_daemon_resumes() {
    let f = Fixture::new();
    let (pid, mixed) = f.start();
    let pid = rustix::process::Pid::from_raw(pid as i32).unwrap();
    struct Resume(rustix::process::Pid);
    impl Drop for Resume {
        fn drop(&mut self) {
            let _ = rustix::process::kill_process(self.0, rustix::process::Signal::CONT);
        }
    }
    let resume = Resume(pid);
    rustix::process::kill_process(pid, rustix::process::Signal::STOP).unwrap();
    let d = f.descriptor();
    let result = f.run(&["stop", "--json"]);
    let remains = f
        .runtime
        .join(format!("zc.stop.{}", d["nonce"].as_str().unwrap()))
        .exists();
    drop(resume);
    assert!(!result.status.success());
    assert!(!remains, "failed stop left a delayed request");
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(f.json(&["status", "--json"])["data"]["pid"], d["pid"]);
    assert!(std::net::TcpStream::connect(("127.0.0.1", mixed)).is_ok());
}

#[test]
fn failed_restart_releases_its_staged_snapshot_on_stop_timeout() {
    let f = Fixture::new();
    let (pid, _) = f.start();
    let pid = rustix::process::Pid::from_raw(pid as i32).unwrap();
    struct Resume(rustix::process::Pid);
    impl Drop for Resume {
        fn drop(&mut self) {
            let _ = rustix::process::kill_process(self.0, rustix::process::Signal::CONT);
        }
    }
    let files = || {
        fs::read_dir(&f.runtime)
            .unwrap()
            .map(|entry| entry.unwrap().file_name())
            .filter(|name| name.to_string_lossy().ends_with(".snapshot"))
            .collect::<std::collections::BTreeSet<_>>()
    };
    let original = files();
    assert_eq!(original.len(), 1);
    let descriptor = f.descriptor();
    let resume = Resume(pid);
    rustix::process::kill_process(pid, rustix::process::Signal::STOP).unwrap();
    for _ in 0..2 {
        let result = f.run(&[
            "restart",
            "-c",
            f.config.to_str().unwrap(),
            "--port",
            &port().to_string(),
            "--json",
        ]);
        assert!(!result.status.success());
        assert_eq!(f.descriptor(), descriptor);
        assert_eq!(
            files(),
            original,
            "failed restart retained an unowned configuration snapshot"
        );
    }
    drop(resume);
    f.json(&["stop", "--json"]);
    assert!(files().is_empty());
}

#[test]
fn background_child_has_its_own_session() {
    use std::io::BufRead;
    use std::os::unix::process::CommandExt;
    let f = Fixture::new();
    let mixed = port();
    // Keep a dedicated launcher group alive after its CLI child exits.
    let mut launcher = Process(
        Command::new("/bin/sh")
            .args([
                "-c",
                "\"$@\"; sleep 30",
                "daemon_launcher",
                env!("CARGO_BIN_EXE_zc"),
                "start",
                "-c",
                f.config.to_str().unwrap(),
                "--port",
                &mixed.to_string(),
                "--json",
            ])
            .env("HOME", &f.home)
            .env("XDG_RUNTIME_DIR", &f.runtime)
            .process_group(0)
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .spawn()
            .unwrap(),
    );
    let mut line = String::new();
    std::io::BufReader::new(launcher.0.stdout.take().unwrap())
        .read_line(&mut line)
        .unwrap();
    let started: Value = serde_json::from_str(&line).unwrap();
    assert_eq!(started["ok"], true, "{line}");
    let pid = started["data"]["pid"].as_u64().unwrap() as u32;
    let process = rustix::process::Pid::from_raw(pid as i32).unwrap();
    assert_eq!(rustix::process::getpgid(Some(process)).unwrap(), process);
    assert_eq!(rustix::process::getsid(Some(process)).unwrap(), process);
    rustix::process::kill_process_group(
        rustix::process::Pid::from_raw(launcher.0.id() as i32).unwrap(),
        rustix::process::Signal::HUP,
    )
    .unwrap();
    launcher.0.wait().unwrap();
    assert_eq!(f.json(&["status", "--json"])["data"]["pid"], pid);
    assert!(std::net::TcpStream::connect(("127.0.0.1", mixed)).is_ok());
}

#[test]
fn original_zig_empty_lock_and_authenticated_yaml_are_read_natively() {
    let f = Fixture::new();
    let (pid, _) = f.start();
    let descriptor: Value =
        serde_json::from_slice(include_bytes!("fixtures/daemon_zig_descriptor.json")).unwrap();
    let original_path = PathBuf::from(descriptor["invocation"]["config_path"].as_str().unwrap());
    let name = original_path.file_name().unwrap().to_str().unwrap();
    let expected_port = descriptor["invocation"]["port_override"].clone();
    let current = f.descriptor();
    let dir = zc::fsutil::SecureDir::open(&f.runtime).unwrap();
    dir.atomic_write(
        "zc.prepared.key",
        include_bytes!("fixtures/daemon_zig_key.bin"),
    )
    .unwrap();
    dir.atomic_write(name, include_bytes!("fixtures/daemon_zig_prepared.yaml"))
        .unwrap();
    // The descriptor has normative field ordering, not serde_json::Value ordering.
    let raw =
        String::from_utf8(include_bytes!("fixtures/daemon_zig_descriptor.json").to_vec()).unwrap();
    let original: Value = serde_json::from_str(&raw).unwrap();
    let raw = raw
        .replace(
            &format!("\"pid\":{}", original["pid"]),
            &format!("\"pid\":{pid}"),
        )
        .replace(
            original["nonce"].as_str().unwrap(),
            current["nonce"].as_str().unwrap(),
        )
        .replace(
            original_path.to_str().unwrap(),
            f.runtime.join(name).to_str().unwrap(),
        );
    dir.atomic_write("zc.daemon.json", raw.as_bytes()).unwrap();
    fs::write(f.runtime.join("zc.lock"), b"").unwrap();
    let result = f.run(&["status", "--json"]);
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stdout)
    );
    let result: Value = serde_json::from_slice(&result.stdout).unwrap();
    assert_eq!(result["data"]["mixed_port"], expected_port);
    assert_eq!(result["data"]["state"], "running");
    let mut tampered = include_bytes!("fixtures/daemon_zig_prepared.yaml").to_vec();
    tampered.push(b'\n');
    dir.atomic_write(name, &tampered).unwrap();
    let invalid = f.run(&["status", "--json"]);
    dir.atomic_write(name, include_bytes!("fixtures/daemon_zig_prepared.yaml"))
        .unwrap();
    assert!(!invalid.status.success());
    assert!(String::from_utf8_lossy(&invalid.stdout).contains("snapshot authentication failed"));
    let again = f.json(&["start", "-c", "/missing/source", "--json"]);
    assert_eq!(again["data"]["pid"], pid);
    assert_eq!(again["data"]["detail"], "already_running");
    // No owned Child handle: stop must use the original nonce-file protocol.
    f.json(&["stop", "--json"]);
}

#[test]
fn config_override_captures_instance_before_script_preparation() {
    let f = Fixture::new();
    f.json(&["config", "load", f.config.to_str().unwrap(), "--json"]);
    f.json(&["start", "--port", &port().to_string(), "--json"]);
    let script = f.home.join("daemon_apply_block.sh");
    let gate = f.home.join("apply_gate");
    let release = f.home.join("apply_release");
    fs::write(&script, format!("#!/bin/sh\n: > '{}'\nwhile [ ! -e '{}' ]; do /bin/sleep 0.01; done\nprintf '%s\\n' 'rules: [\"MATCH,REJECT\"]'\n", gate.display(), release.display())).unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o700)).unwrap();
    let mut paused = Process(
        f.command(&["config", "override", script.to_str().unwrap(), "--json"])
            .spawn()
            .unwrap(),
    );
    wait(|| gate.exists());
    f.json(&["restart", "--port", &port().to_string(), "--json"]);
    let newer = f.descriptor();
    fs::write(release, "").unwrap();
    wait(|| paused.0.try_wait().unwrap().is_some());
    use std::io::Read;
    let mut output = String::new();
    paused
        .0
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut output)
        .unwrap();
    assert!(output.contains("RESTART_CONTENDED"), "{output}");
    assert_eq!(f.descriptor(), newer);
}

#[test]
fn restart_serializes_descriptor_capture_with_exit_cleanup() {
    use std::io::Read;
    use std::os::unix::fs::MetadataExt;

    let f = Fixture::new();
    let scope = f.home.join("capture-race");
    fs::create_dir(&scope).unwrap();
    let library = scope.join(if cfg!(target_os = "macos") {
        "capture.dylib"
    } else {
        "capture.so"
    });
    let mut cc = Command::new("cc");
    cc.args(["-std=c11", "-Wall", "-Wextra", "-Werror"]);
    if cfg!(target_os = "macos") {
        cc.arg("-dynamiclib");
    } else {
        cc.args(["-shared", "-fPIC"]);
    }
    cc.arg("-o").arg(&library).arg(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/tests/support/restart_capture_race.c"
    ));
    if cfg!(target_os = "linux") {
        cc.arg("-ldl");
    }
    let compiled = cc.output().expect("cc is required for the restart fixture");
    assert!(
        compiled.status.success(),
        "{}",
        String::from_utf8_lossy(&compiled.stderr)
    );
    let preload = if cfg!(target_os = "macos") {
        "DYLD_INSERT_LIBRARIES"
    } else {
        "LD_PRELOAD"
    };
    let started = f
        .command(&[
            "start",
            "-c",
            f.config.to_str().unwrap(),
            "--port",
            &port().to_string(),
            "--json",
        ])
        .env(preload, &library)
        .env("ZC_RESTART_CAPTURE_ROOT", &scope)
        .env("ZC_RESTART_CAPTURE_ROLE", "writer")
        .output()
        .unwrap();
    assert!(started.status.success(), "{started:?}");
    let old = f.descriptor();
    let pid = rustix::process::Pid::from_raw(old["pid"].as_i64().unwrap() as i32).unwrap();
    struct Resume(rustix::process::Pid);
    impl Drop for Resume {
        fn drop(&mut self) {
            let _ = rustix::process::kill_process(self.0, rustix::process::Signal::CONT);
        }
    }
    let resume = Resume(pid);
    rustix::process::kill_process(pid, rustix::process::Signal::STOP).unwrap();
    let descriptor_path = f.runtime.join("zc.daemon.json");
    let descriptor = fs::metadata(&descriptor_path).unwrap();
    let lock = fs::metadata(f.runtime.join("zc.daemon.lock")).unwrap();
    fs::write(
        scope.join("arming"),
        format!(
            "{} {} {} {}\n",
            descriptor.dev(),
            descriptor.ino(),
            lock.dev(),
            lock.ino()
        ),
    )
    .unwrap();
    fs::rename(scope.join("arming"), scope.join("armed")).unwrap();
    let next_port = port();
    let mut restart = Process(
        f.command(&["restart", "--port", &next_port.to_string(), "--json"])
            .env(preload, &library)
            .env("ZC_RESTART_CAPTURE_ROOT", &scope)
            .env("ZC_RESTART_CAPTURE_ROLE", "reader")
            .env(
                "ZC_RESTART_CAPTURE_REQUEST",
                f.runtime
                    .join(format!("zc.stop.{}", old["nonce"].as_str().unwrap())),
            )
            .spawn()
            .unwrap(),
    );
    let evidence = |name: &str| fs::read_to_string(scope.join(name)).unwrap_or_default();
    wait(|| !evidence("reader-ready").is_empty());
    // Resume the real daemon only after stopped() has its capture-before stat.
    // Its actual flock result tells us whether cleanup can unlink that inode.
    drop(resume);
    wait(|| !evidence("writer-lock").is_empty());
    let writer = evidence("writer-lock");
    if writer == "acquired\n" {
        // On the broken implementation, finish the real unlink before allowing
        // read_bounded to sample capture-after. No forged metadata or timeout.
        wait(|| !descriptor_path.exists());
    }
    fs::write(scope.join("reader-release"), "").unwrap();
    wait(|| restart.0.try_wait().unwrap().is_some());
    let status = restart.0.wait().unwrap();
    let mut output = String::new();
    restart
        .0
        .stdout
        .take()
        .unwrap()
        .read_to_string(&mut output)
        .unwrap();
    let before = evidence("reader-ready");
    let after = evidence("reader-after");
    eprintln!("Restart capture: writer={writer:?}, before={before:?}, after={after:?}");
    assert!(status.success(), "{output}");
    assert_eq!(writer, "blocked\n", "cleanup did not overlap the reader");
    assert_eq!(before, after, "captured inode changed during cleanup");
    let result: Value = serde_json::from_str(&output).unwrap();
    assert_eq!(result["ok"], true);
    let current = f.json(&["status", "--json"]);
    assert_eq!(current["data"]["state"], "running");
    assert_eq!(current["data"]["mixed_port"], next_port);
    assert_ne!(current["data"]["pid"], old["pid"]);
    assert!(std::net::TcpStream::connect(("127.0.0.1", next_port)).is_ok());
}
