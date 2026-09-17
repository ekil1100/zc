#[path = "support/cli_fixture.rs"]
mod cli_fixture;
use serde_json::Value;
use std::{
    fs,
    path::PathBuf,
    process::{Command, Output},
    time::Duration,
};
struct Fixture {
    _home: tempfile::TempDir,
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
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
        let config = home.join("config.yaml");
        fs::write(&config, "mixed-port: 17892\nproxy-groups:\n  - name: pick\n    type: select\n    proxies: [DIRECT, REJECT]\nrules: ['MATCH,pick']\n").unwrap();
        Self {
            _home: temp,
            home,
            runtime,
            config,
            _serial: serial,
        }
    }
    fn command(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_zc"))
            .args(args)
            .env("HOME", &self.home)
            .env("XDG_RUNTIME_DIR", &self.runtime)
            .output()
            .unwrap()
    }
    fn json(&self, args: &[&str]) -> Value {
        let out = self.command(args);
        assert!(
            out.status.success(),
            "stdout={} stderr={}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command(&["stop", "--json"]);
    }
}
fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}
#[test]
fn background_lifecycle_is_ready_idempotent_and_nonce_bound() {
    let f = Fixture::new();
    let stopped = f.json(&["status", "--json"]);
    assert_eq!(stopped["data"]["state"], "stopped");
    assert!(stopped["data"]["mixed_port"].is_null());
    let port = free_port().to_string();
    let started = f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port,
        "--json",
    ]);
    assert!(started["data"]["pid"].as_u64().is_some());
    let descriptor: Value =
        serde_json::from_slice(&fs::read(f.runtime.join("zc.daemon.json")).unwrap()).unwrap();
    assert_eq!(descriptor["schema_version"], 2);
    assert_eq!(descriptor["ready"], true);
    assert_eq!(
        f.json(&[
            "start",
            "-c",
            f.config.to_str().unwrap(),
            "--port",
            &port,
            "--json"
        ])["data"]["detail"],
        "already_running"
    );
    let running = f.json(&["status", "--json"]);
    assert_eq!(running["data"]["state"], "running");
    assert_eq!(running["data"]["mixed_port"], port.parse::<u16>().unwrap());
    fs::write(
        f.runtime.join("zc.stop.00000000000000000000000000000000"),
        "00000000000000000000000000000000\n",
    )
    .unwrap();
    std::thread::sleep(Duration::from_millis(200));
    assert_eq!(f.json(&["status", "--json"])["data"]["state"], "running");
    f.json(&["stop", "--json"]);
    assert_eq!(
        f.json(&["stop", "--json"])["data"]["detail"],
        "already_stopped"
    );
    assert!(!f.runtime.join("zc.pid").exists());
    assert!(!f.runtime.join("zc.daemon.json").exists());
    assert!(!fs::read_dir(&f.runtime).unwrap().any(|entry| {
        entry
            .unwrap()
            .file_name()
            .to_string_lossy()
            .ends_with(".snapshot")
    }));
}

#[test]
fn failed_restart_restores_frozen_config_after_source_disappears() {
    let f = Fixture::new();
    let port = free_port().to_string();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port,
        "--json",
    ]);
    fs::remove_file(&f.config).unwrap();
    let next = f.home.join("next.yaml");
    fs::write(&next, "mixed-port: 17893\nrules: ['MATCH,REJECT']\n").unwrap();
    let occupied = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let blocked = occupied.local_addr().unwrap().port().to_string();
    let failure = f.command(&[
        "restart",
        "-c",
        next.to_str().unwrap(),
        "--port",
        &blocked,
        "--json",
    ]);
    assert!(
        !failure.status.success(),
        "{}",
        String::from_utf8_lossy(&failure.stdout)
    );
    let state = f.json(&["status", "--json"]);
    assert_eq!(state["data"]["state"], "running");
    assert_eq!(state["data"]["mixed_port"], port.parse::<u16>().unwrap());
}
fn http(port: u16, path: &str, body: &Value) -> (u16, Value) {
    use std::io::{Read, Write};
    let body = serde_json::to_vec(body).unwrap();
    let mut stream = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    write!(stream, "PUT {path} HTTP/1.1\r\nAuthorization: Bearer integration-secret\r\nContent-Length: {}\r\n\r\n", body.len()).unwrap();
    stream.write_all(&body).unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    let (header, body) = response.split_once("\r\n\r\n").unwrap();
    (
        header.split_whitespace().nth(1).unwrap().parse().unwrap(),
        serde_json::from_str(body).unwrap(),
    )
}
#[test]
fn managed_selection_is_durable_and_rejects_stale_nonce_and_generation() {
    let f = Fixture::new();
    let controller = free_port();
    let source = fs::read_to_string(&f.config).unwrap();
    fs::write(
        &f.config,
        format!(
            "{source}external-controller: 127.0.0.1:{controller}\nsecret: integration-secret\n"
        ),
    )
    .unwrap();
    f.json(&["config", "load", f.config.to_str().unwrap(), "--json"]);
    let port = free_port().to_string();
    f.json(&["start", "--port", &port, "--json"]);
    let initial: Value =
        serde_json::from_slice(&fs::read(f.runtime.join("zc.daemon.json")).unwrap()).unwrap();
    assert_eq!(
        http(
            controller,
            "/proxies/unknown",
            &serde_json::json!({"name":"REJECT"})
        )
        .0,
        404
    );
    assert_eq!(
        http(
            controller,
            "/proxies/pick",
            &serde_json::json!({"name":"REJECT"})
        )
        .0,
        409
    );
    let selection = f.json(&["proxy", "select", "-g", "pick", "-p", "REJECT", "--json"]);
    assert_eq!(selection["data"]["applied"], true);
    let state = f.json(&["status", "--json"]);
    assert_eq!(state["data"]["selected_proxies"][0]["proxy"], "REJECT");
    assert_eq!(state["data"]["selected_proxies"][0]["source"], "persisted");
    let descriptor: Value =
        serde_json::from_slice(&fs::read(f.runtime.join("zc.daemon.json")).unwrap()).unwrap();
    assert!(descriptor["generation"].as_u64().unwrap() > initial["generation"].as_u64().unwrap());
    let stale = serde_json::json!({"name":"DIRECT", "instance_nonce": descriptor["nonce"], "identity_key":descriptor["identity"]["key"], "identity_revision":descriptor["identity"]["revision"], "generation":descriptor["generation"]});
    assert_eq!(http(controller, "/proxies/pick", &stale).0, 409);
    let mut wrong = stale.clone();
    wrong["generation"] = serde_json::json!(descriptor["generation"].as_u64().unwrap() + 1);
    wrong["instance_nonce"] = serde_json::json!("00000000000000000000000000000000");
    assert_eq!(http(controller, "/proxies/pick", &wrong).0, 409);
    wrong["instance_nonce"] = serde_json::json!("invalid");
    assert_eq!(http(controller, "/proxies/pick", &wrong).0, 400);
    f.json(&["stop", "--json"]);
    f.json(&["start", "--port", &port, "--json"]);
    assert_eq!(
        f.json(&["status", "--json"])["data"]["selected_proxies"][0]["proxy"],
        "REJECT"
    );
}

#[test]
fn runtime_lock_replacement_self_exits_without_signalling_a_pid() {
    let f = Fixture::new();
    let port = free_port().to_string();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port,
        "--json",
    ]);
    let original_lock = fs::File::open(f.runtime.join("zc.lock")).unwrap();
    assert!(matches!(
        original_lock.try_lock(),
        Err(fs::TryLockError::WouldBlock)
    ));
    let runtime = zc::fsutil::SecureDir::open(&f.runtime).unwrap();
    // Hold cleanup at a real filesystem boundary, so listener closure cannot be
    // mistaken for process exit or descriptor/PID cleanup completion.
    let cleanup = runtime
        .lock("zc.daemon.lock", Duration::from_secs(1))
        .unwrap();
    let descriptor = fs::read(f.runtime.join("zc.daemon.json")).unwrap();
    let pid = fs::read(f.runtime.join("zc.pid")).unwrap();
    fs::rename(f.runtime.join("zc.lock"), f.runtime.join("old.lock")).unwrap();
    fs::write(f.runtime.join("zc.lock"), "").unwrap();
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(f.runtime.join("zc.lock"), fs::Permissions::from_mode(0o600)).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    loop {
        if std::net::TcpStream::connect(("127.0.0.1", port.parse::<u16>().unwrap())).is_err() {
            break;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "old listener did not close"
        );
        std::thread::sleep(Duration::from_millis(25));
    }
    let transitional = f.command(&["status", "--json"]);
    assert!(
        !transitional.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&transitional.stdout),
        String::from_utf8_lossy(&transitional.stderr)
    );
    let error: Value = serde_json::from_slice(&transitional.stdout).unwrap();
    assert_eq!(error["error"]["code"], "STATUS_FAILED");
    assert!(
        error["error"]["message"]
            .as_str()
            .unwrap()
            .starts_with("RUNTIME_IDENTITY_CHANGED:"),
        "{error}"
    );
    assert_eq!(
        fs::read(f.runtime.join("zc.daemon.json")).unwrap(),
        descriptor
    );
    assert_eq!(fs::read(f.runtime.join("zc.pid")).unwrap(), pid);
    assert!(matches!(
        original_lock.try_lock(),
        Err(fs::TryLockError::WouldBlock)
    ));
    drop(cleanup);
    // Follow the held original inode, not the replacement path or a raw PID.
    loop {
        match original_lock.try_lock() {
            Ok(()) => break,
            Err(fs::TryLockError::WouldBlock) => {
                assert!(
                    std::time::Instant::now() < deadline,
                    "old owner did not exit"
                );
                std::thread::sleep(Duration::from_millis(5));
            }
            Err(error) => panic!("cannot observe the original lock: {error}"),
        }
    }
    assert!(!f.runtime.join("zc.pid").exists());
    assert!(!f.runtime.join("zc.daemon.json").exists());
    assert_eq!(f.json(&["status", "--json"])["data"]["state"], "stopped");
}

#[test]
fn missing_or_corrupt_descriptor_keeps_selection_durable_without_live_apply() {
    let f = Fixture::new();
    f.json(&["config", "load", f.config.to_str().unwrap(), "--json"]);
    f.json(&["start", "--port", &free_port().to_string(), "--json"]);
    let path = f.runtime.join("zc.daemon.json");
    let bytes = fs::read(&path).unwrap();
    fs::write(&path, "{}\n").unwrap();
    let out = f.command(&["proxy", "select", "-g", "pick", "-p", "REJECT", "--json"]);
    fs::write(&path, &bytes).unwrap();
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    let result: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(result["data"]["applied"], false);
    let listed = f.json(&["proxy", "list", "--json"]);
    assert_eq!(listed["data"]["groups"][0]["now"], "REJECT");
}

#[test]
fn managed_rollback_retains_last_applied_selection_snapshot() {
    let f = Fixture::new();
    let controller = free_port();
    let source = fs::read_to_string(&f.config).unwrap();
    fs::write(
        &f.config,
        format!(
            "{source}external-controller: 127.0.0.1:{controller}\nsecret: integration-secret\n"
        ),
    )
    .unwrap();
    f.json(&["config", "load", f.config.to_str().unwrap(), "--json"]);
    f.json(&["start", "--port", &free_port().to_string(), "--json"]);
    assert_eq!(
        f.json(&["proxy", "select", "-g", "pick", "-p", "REJECT", "--json"])["data"]["applied"],
        true
    );
    let occupied = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let failure = f.command(&[
        "restart",
        "--port",
        &occupied.local_addr().unwrap().port().to_string(),
        "--json",
    ]);
    assert!(!failure.status.success());
    assert_eq!(
        f.json(&["status", "--json"])["data"]["selected_proxies"][0]["proxy"],
        "REJECT"
    );
}

#[test]
fn stale_pid_cleanup_and_live_unverified_pid_fail_closed() {
    let f = Fixture::new();
    use std::os::unix::fs::PermissionsExt;
    fs::write(f.runtime.join("zc.pid"), "2147483647\n").unwrap();
    fs::set_permissions(f.runtime.join("zc.pid"), fs::Permissions::from_mode(0o600)).unwrap();
    let state = f.json(&["status", "--json"]);
    assert_eq!(state["data"]["state"], "stopped");
    assert_eq!(state["data"]["detail"], "stale_pid_file");
    assert!(!f.runtime.join("zc.pid").exists());
    fs::write(
        f.runtime.join("zc.pid"),
        format!("{}\n", std::process::id()),
    )
    .unwrap();
    fs::set_permissions(f.runtime.join("zc.pid"), fs::Permissions::from_mode(0o600)).unwrap();
    let out = f.command(&["stop", "--json"]);
    assert!(!out.status.success());
    assert!(f.runtime.join("zc.pid").exists());
    fs::remove_file(f.runtime.join("zc.pid")).unwrap();
}
#[test]
fn simultaneous_background_starts_share_one_ready_instance() {
    let f = Fixture::new();
    let port = free_port().to_string();
    let spawn = || {
        Command::new(env!("CARGO_BIN_EXE_zc"))
            .args([
                "start",
                "-c",
                f.config.to_str().unwrap(),
                "--port",
                &port,
                "--json",
            ])
            .env("HOME", &f.home)
            .env("XDG_RUNTIME_DIR", &f.runtime)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap()
    };
    let a = spawn();
    let b = spawn();
    let a = a.wait_with_output().unwrap();
    let b = b.wait_with_output().unwrap();
    assert!(a.status.success(), "{}", String::from_utf8_lossy(&a.stdout));
    assert!(b.status.success(), "{}", String::from_utf8_lossy(&b.stdout));
    let a: Value = serde_json::from_slice(&a.stdout).unwrap();
    let b: Value = serde_json::from_slice(&b.stdout).unwrap();
    assert_eq!(a["data"]["pid"], b["data"]["pid"]);
}
#[test]
fn controller_collision_never_reports_ready_or_falls_back() {
    let f = Fixture::new();
    let occupied = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let controller = occupied.local_addr().unwrap().port();
    let source = fs::read_to_string(&f.config).unwrap();
    fs::write(
        &f.config,
        format!("{source}external-controller: 127.0.0.1:{controller}\n"),
    )
    .unwrap();
    let port = free_port();
    let out = f.command(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    assert!(
        !out.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let result: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(
        result["error"]["code"],
        "START_CONTROLLER_PORT_IN_USE",
        "stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    assert!(std::net::TcpStream::connect(("127.0.0.1", port)).is_err());
    assert!(!f.runtime.join("zc.daemon.json").exists());
    assert_eq!(f.json(&["status", "--json"])["data"]["state"], "stopped");
    // Only the fixture releases the collision; the CLI must not choose a fallback.
    drop(occupied);
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    assert_eq!(f.json(&["status", "--json"])["data"]["mixed_port"], port);
}

#[test]
fn mixed_collision_never_reports_ready_or_falls_back() {
    let f = Fixture::new();
    let occupied = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let out = f.command(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &occupied.local_addr().unwrap().port().to_string(),
        "--json",
    ]);
    assert!(
        !out.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    let result: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(result["error"]["code"], "START_PORT_IN_USE", "{result}");
    assert!(!f.runtime.join("zc.daemon.json").exists());
    assert_eq!(f.json(&["status", "--json"])["data"]["state"], "stopped");
}

#[test]
fn snapshot_tampering_and_missing_lock_handoff_are_rejected() {
    let f = Fixture::new();
    let port = free_port().to_string();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port,
        "--json",
    ]);
    let d: Value =
        serde_json::from_slice(&fs::read(f.runtime.join("zc.daemon.json")).unwrap()).unwrap();
    let path = PathBuf::from(d["invocation"]["config_path"].as_str().unwrap());
    let name = path.file_name().unwrap().to_str().unwrap();
    let nonce = d["nonce"].as_str().unwrap();
    let authentic = fs::read(&path).unwrap();
    let failure = f.command(&["--daemon-run", name, nonce]);
    assert!(!failure.status.success());
    assert!(String::from_utf8_lossy(&failure.stderr).contains("START_LOCK_HANDOFF_INVALID"));
    fs::write(&path, b"{}\n").unwrap();
    let failure = f.command(&["--daemon-run", name, nonce]);
    fs::write(&path, authentic).unwrap();
    assert!(!failure.status.success());
    assert!(String::from_utf8_lossy(&failure.stderr).contains("snapshot authentication failed"));
    assert_eq!(f.json(&["status", "--json"])["data"]["state"], "running");
}
#[test]
fn unsafe_runtime_paths_are_rejected_and_logs_are_bounded() {
    let f = Fixture::new();
    let link = f.home.join("runtime-link");
    std::os::unix::fs::symlink(&f.runtime, &link).unwrap();
    let out = Command::new(env!("CARGO_BIN_EXE_zc"))
        .args(["status", "--json"])
        .env("HOME", &f.home)
        .env("XDG_RUNTIME_DIR", &link)
        .output()
        .unwrap();
    assert!(!out.status.success());
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &free_port().to_string(),
        "--json",
    ]);
    let log = f.runtime.join("zc.log");
    fs::write(&log, b"first\nsecond\nthird\n").unwrap();
    let output = f.command(&["log", "--json", "-n", "2"]);
    assert!(
        output.status.success(),
        "stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let records: Vec<Value> = String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .map(|s| serde_json::from_str(s).unwrap())
        .collect();
    assert_eq!(
        records,
        vec![
            serde_json::json!({"line":"second"}),
            serde_json::json!({"line":"third"})
        ]
    );
    use std::os::unix::fs::MetadataExt;
    let old_inode = fs::metadata(&log).unwrap().ino();
    fs::write(&log, vec![b'x'; 8 * 1024 * 1024 + 1]).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(3);
    while fs::metadata(&log).unwrap().len() > 8 * 1024 * 1024 {
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(25));
    }
    assert_ne!(fs::metadata(&log).unwrap().ino(), old_inode);
    assert_eq!(fs::metadata(&log).unwrap().mode() & 0o777, 0o600);
}

#[test]
fn managed_apply_can_jump_to_latest_complete_desired_generation() {
    let f = Fixture::new();
    let controller = free_port();
    let source = fs::read_to_string(&f.config).unwrap();
    fs::write(
        &f.config,
        format!(
            "{source}external-controller: 127.0.0.1:{controller}\nsecret: integration-secret\n"
        ),
    )
    .unwrap();
    f.json(&["config", "load", f.config.to_str().unwrap(), "--json"]);
    f.json(&["start", "--port", &free_port().to_string(), "--json"]);
    let descriptor: Value =
        serde_json::from_slice(&fs::read(f.runtime.join("zc.daemon.json")).unwrap()).unwrap();
    let store = zc::store::Store::open(f.home.join(".config/zc")).unwrap();
    for proxy in ["DIRECT", "REJECT"] {
        let snapshot = store.load().unwrap();
        let p = &snapshot.catalog.profiles[0];
        store
            .select(
                &snapshot.token,
                &p.key,
                &p.head,
                p.desired.generation,
                vec![zc::store::Selection {
                    group: "pick".into(),
                    proxy: proxy.into(),
                }],
            )
            .unwrap();
    }
    let generation = store.load().unwrap().catalog.profiles[0].desired.generation;
    let mut body = serde_json::json!({"name":"DIRECT", "instance_nonce":descriptor["nonce"], "identity_key":descriptor["identity"]["key"], "identity_revision":descriptor["identity"]["revision"], "generation":generation-1});
    assert_eq!(http(controller, "/proxies/pick", &body).0, 409);
    body["generation"] = serde_json::json!(generation);
    body["name"] = serde_json::json!("REJECT");
    assert_eq!(http(controller, "/proxies/pick", &body).0, 200);
    assert_eq!(
        f.json(&["status", "--json"])["data"]["selected_proxies"][0]["proxy"],
        "REJECT"
    );
    let latest: Value =
        serde_json::from_slice(&fs::read(f.runtime.join("zc.daemon.json")).unwrap()).unwrap();
    assert_eq!(latest["generation"], generation);
}

#[test]
fn provisional_readiness_blocks_even_direct_traffic_until_authority_reconciliation() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    let mut source = String::from("mixed-port: 17896\nproxies:\n");
    // A realistic large config leaves enough time to acquire the authority guard
    // after CLI preparation but before the child reaches reconciliation.
    for index in 0..2000 {
        source.push_str(&format!("  - {{name: node-{index}, type: ss, server: localhost, port: 443, password: test, cipher: aes-128-gcm}}\n"));
    }
    source.push_str("rules: ['MATCH,DIRECT']\n");
    fs::write(&f.config, source).unwrap();
    f.json(&["config", "load", f.config.to_str().unwrap(), "--json"]);
    let root = zc::fsutil::SecureDir::open(f.home.join(".config/zc")).unwrap();
    let port = free_port();
    let child = Command::new(env!("CARGO_BIN_EXE_zc"))
        .args(["start", "--port", &port.to_string(), "--json"])
        .env("HOME", &f.home)
        .env("XDG_RUNTIME_DIR", &f.runtime)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    while !f.runtime.join("zc.prepared.key").exists() {
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(Duration::from_micros(100));
    }
    let authority = root.lock("state-v2.lock", Duration::from_secs(1)).unwrap();
    let descriptor_path = f.runtime.join("zc.daemon.json");
    while !descriptor_path.exists() {
        assert!(std::time::Instant::now() < deadline);
        std::thread::sleep(Duration::from_millis(1));
    }
    let descriptor: Value = serde_json::from_slice(&fs::read(&descriptor_path).unwrap()).unwrap();
    assert_eq!(descriptor["ready"], false);
    assert_eq!(f.json(&["status", "--json"])["data"]["state"], "stopped");
    let origin = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    origin.set_nonblocking(true).unwrap();
    let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let destination = origin.local_addr().unwrap();
    write!(
        client,
        "CONNECT {destination} HTTP/1.1\r\nHost: {destination}\r\n\r\n"
    )
    .unwrap();
    std::thread::sleep(Duration::from_millis(100));
    assert_eq!(
        origin.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    drop(authority);
    let started = child.wait_with_output().unwrap();
    assert!(
        started.status.success(),
        "{}",
        String::from_utf8_lossy(&started.stdout)
    );
    let mut response = [0; 128];
    let count = client.read(&mut response).unwrap();
    assert!(
        std::str::from_utf8(&response[..count])
            .unwrap()
            .contains("200"),
        "{}",
        String::from_utf8_lossy(&response[..count])
    );
    assert!(origin.accept().is_ok());
}

#[test]
fn log_follow_keeps_partial_lines_and_reopens_a_rebuilt_runtime_directory() {
    use std::io::{BufRead, Write};
    use std::os::unix::fs::PermissionsExt;
    struct Follower(std::process::Child);
    impl Drop for Follower {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let f = Fixture::new();
    let log = f.runtime.join("zc.log");
    fs::write(&log, "seed\n").unwrap();
    fs::set_permissions(&log, fs::Permissions::from_mode(0o600)).unwrap();
    let mut child = Follower(
        Command::new(env!("CARGO_BIN_EXE_zc"))
            .args(["log", "-f", "--json", "-n", "1"])
            .env("HOME", &f.home)
            .env("XDG_RUNTIME_DIR", &f.runtime)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap(),
    );
    let reader = child.0.stdout.take().unwrap();
    let (tx, rx) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        for line in std::io::BufReader::new(reader).lines() {
            if tx.send(line.unwrap()).is_err() {
                break;
            }
        }
    });
    assert_eq!(
        serde_json::from_str::<Value>(&rx.recv_timeout(Duration::from_secs(3)).unwrap()).unwrap()["line"],
        "seed"
    );
    fs::OpenOptions::new()
        .append(true)
        .open(&log)
        .unwrap()
        .write_all(b"partial")
        .unwrap();
    assert!(rx.recv_timeout(Duration::from_millis(350)).is_err());
    fs::OpenOptions::new()
        .append(true)
        .open(&log)
        .unwrap()
        .write_all(b" line\n")
        .unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&rx.recv_timeout(Duration::from_secs(3)).unwrap()).unwrap()["line"],
        "partial line"
    );
    fs::rename(&f.runtime, f.home.join("old-runtime")).unwrap();
    fs::create_dir(&f.runtime).unwrap();
    fs::set_permissions(&f.runtime, fs::Permissions::from_mode(0o700)).unwrap();
    fs::write(&log, "replacement\n").unwrap();
    fs::set_permissions(&log, fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(
        serde_json::from_str::<Value>(&rx.recv_timeout(Duration::from_secs(3)).unwrap()).unwrap()["line"],
        "replacement"
    );
    drop(child);
    thread.join().unwrap();
}
