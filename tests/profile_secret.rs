//! Managed CLI and authenticated runtime boundaries; only temporary HOME/loopback.
#[path = "support/cli_fixture.rs"]
mod cli_fixture;
use serde_json::{Value, json};
use std::{
    fs,
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Child, Command, Output, Stdio},
    time::{Duration, Instant},
};
use zc::store::{Bundle, Metadata, Store};

struct Fixture {
    home: tempfile::TempDir,
    _serial: std::sync::MutexGuard<'static, ()>,
}
impl Fixture {
    fn new() -> Self {
        Self {
            home: tempfile::tempdir().unwrap(),
            _serial: cli_fixture::serial(),
        }
    }
    fn command(&self, args: &[&str]) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_zc"));
        command
            .args(args)
            .env("HOME", self.home.path().canonicalize().unwrap())
            .env_remove("XDG_RUNTIME_DIR")
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_STATE_HOME");
        command
    }
    fn run(&self, args: &[&str]) -> Output {
        self.command(args).output().unwrap()
    }
    fn ok(&self, args: &[&str]) -> Value {
        let out = self.run(args);
        assert!(out.status.success(), "{args:?}: {out:?}");
        serde_json::from_slice(&out.stdout).unwrap()
    }
    fn load(&self, name: &str, source: &str) {
        let path = self.home.path().join(format!("{name}.yaml"));
        fs::write(&path, source).unwrap();
        self.ok(&["config", "load", path.to_str().unwrap(), "--json"]);
    }
    fn store(&self) -> Store {
        Store::open(self.home.path().join(".config/zc")).unwrap()
    }
    fn auto(&self, name: &str) -> Value {
        serde_json::to_value(self.store().get(name).unwrap()).unwrap()["auto_controller_secret"]
            .clone()
    }
    fn runtime(&self) -> PathBuf {
        self.home
            .path()
            .canonicalize()
            .unwrap()
            .join(".local/state/zc/runtime")
    }
    fn descriptor(&self) -> Value {
        serde_json::from_slice(&fs::read(self.runtime().join("zc.daemon.json")).unwrap()).unwrap()
    }
    fn snapshot(&self) -> Value {
        let d = self.descriptor();
        serde_json::from_slice(&fs::read(d["invocation"]["config_path"].as_str().unwrap()).unwrap())
            .unwrap()
    }
    fn start(&self) {
        self.ok(&["start", "--port", &free_port().to_string(), "--json"]);
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::write(self.home.path().join("release"), "");
        let _ = self.run(&["stop", "--json"]);
    }
}
fn free_port() -> u16 {
    let port = TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    assert_ne!(port, 7899);
    port
}
fn source(controller: u16, secret: &str) -> String {
    format!(
        "external-controller: 127.0.0.1:{controller}\nsecret: '{secret}'\nproxy-groups: [{{name: pick, type: select, proxies: [DIRECT, REJECT]}}]\nrules: ['MATCH,pick']\n"
    )
}
fn authorized(controller: u16, secret: &str) -> bool {
    let mut stream = TcpStream::connect(("127.0.0.1", controller)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    write!(
        stream,
        "GET /connections HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer {secret}\r\n\r\n"
    )
    .unwrap();
    let mut response = String::new();
    stream.read_to_string(&mut response).unwrap();
    response.starts_with("HTTP/1.1 200")
}

struct Process(Option<Child>);
impl Process {
    fn spawn(mut command: Command) -> Self {
        Self(Some(
            command
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap(),
        ))
    }
    fn finished(&mut self) -> bool {
        self.0.as_mut().unwrap().try_wait().unwrap().is_some()
    }
    fn output(mut self) -> Output {
        wait(|| self.finished());
        self.0.take().unwrap().wait_with_output().unwrap()
    }
}
impl Drop for Process {
    fn drop(&mut self) {
        if let Some(child) = &mut self.0 {
            let _ = child.kill();
            let _ = child.wait();
        }
    }
}
fn wait(mut ready: impl FnMut() -> bool) {
    let deadline = Instant::now() + Duration::from_secs(20);
    while !ready() {
        assert!(Instant::now() < deadline, "condition timed out");
        std::thread::sleep(Duration::from_millis(5));
    }
}
fn script(f: &Fixture, barrier: bool) -> PathBuf {
    let path = f.home.path().join("start.sh");
    fs::write(
        &path,
        format!(
            "#!/bin/sh\n: > '{}'\n{}printf 'mode: rule\\n'\n",
            f.home.path().join("gate").display(),
            if barrier {
                format!(
                    "while [ ! -e '{}' ]; do /bin/sleep 0.01; done\n",
                    f.home.path().join("release").display()
                )
            } else {
                String::new()
            }
        ),
    )
    .unwrap();
    fs::set_permissions(&path, fs::Permissions::from_mode(0o700)).unwrap();
    path
}
fn assert_running_start_has_no_prepare_side_effects(f: &Fixture) {
    let catalog = f.store().root_path().join("state-v2.json");
    let before = fs::read(&catalog).unwrap();
    let descriptor = f.descriptor();
    let script = script(f, false);
    for foreground in [true, false] {
        let port = free_port().to_string();
        let mut args = vec![
            "start",
            "-c",
            "managed",
            "--port",
            &port,
            "--override-script",
            script.to_str().unwrap(),
            "--json",
        ];
        if foreground {
            args.push("--foreground");
        }
        let out = Process::spawn(f.command(&args)).output();
        let response: Value = serde_json::from_slice(&out.stdout).unwrap();
        if foreground {
            assert!(!out.status.success(), "{out:?}");
            assert_eq!(response["error"]["code"], "START_FAILED");
        } else {
            assert!(out.status.success(), "{out:?}");
            assert_eq!(response["data"]["detail"], "already_running");
        }
        assert_eq!(f.descriptor(), descriptor);
        assert!(
            f.auto("managed").is_null(),
            "rejected start generated a profile key"
        );
        assert!(
            fs::read(&catalog).unwrap() == before,
            "rejected start changed catalog bytes"
        );
        assert!(
            !f.home.path().join("gate").exists(),
            "rejected start executed override"
        );
    }
}

#[test]
fn start_ownership_running_instance_skips_prepare_including_foreground() {
    let f = Fixture::new();
    f.load("managed", &source(free_port(), ""));
    let unmanaged = f.home.path().join("unmanaged.yaml");
    fs::write(&unmanaged, "rules: ['MATCH,REJECT']\n").unwrap();
    f.ok(&[
        "start",
        "-c",
        unmanaged.to_str().unwrap(),
        "--port",
        &free_port().to_string(),
        "--json",
    ]);
    assert_running_start_has_no_prepare_side_effects(&f);
}

#[test]
fn start_ownership_override_race_only_owner_can_persist_key() {
    for first_managed in [true, false] {
        start_override_race(first_managed);
    }
}
fn start_override_race(first_managed: bool) {
    let f = Fixture::new();
    f.load("managed", &source(free_port(), ""));
    let before = f.store().load().unwrap().token;
    let unmanaged = f.home.path().join("unmanaged.yaml");
    fs::write(&unmanaged, "rules: ['MATCH,REJECT']\n").unwrap();
    let script = script(&f, true);
    let managed_port = free_port().to_string();
    let other_port = free_port().to_string();
    let first_config = if first_managed {
        "managed"
    } else {
        unmanaged.to_str().unwrap()
    };
    let other_config = if first_managed {
        unmanaged.to_str().unwrap()
    } else {
        "managed"
    };
    let first = Process::spawn(f.command(&[
        "start",
        "-c",
        first_config,
        "--port",
        &managed_port,
        "--override-script",
        script.to_str().unwrap(),
        "--override-timeout-ms",
        "20000",
        "--json",
    ]));
    wait(|| f.home.path().join("gate").exists());
    // A real flock probe selects the schedule, not a sleep or implementation flag.
    // Before the fix the contender can finish while prepare is paused. With
    // ownership acquired first, release prepare before waiting for its contender.
    let owns = instance_lock_held(&f);
    let mut other =
        Process::spawn(f.command(&["start", "-c", other_config, "--port", &other_port, "--json"]));
    if !owns {
        wait(|| other.finished());
    }
    fs::write(f.home.path().join("release"), "").unwrap();
    let first = first.output();
    let other = other.output();
    assert!(first.status.success(), "{first:?}");
    assert!(other.status.success(), "{other:?}");
    let first: Value = serde_json::from_slice(&first.stdout).unwrap();
    let other: Value = serde_json::from_slice(&other.stdout).unwrap();
    let first_won = first["data"]["detail"] != "already_running";
    assert_ne!(first_won, other["data"]["detail"] != "already_running");
    let descriptor = f.descriptor();
    assert_eq!(first["data"]["pid"], descriptor["pid"]);
    assert_eq!(other["data"]["pid"], descriptor["pid"]);
    let winning_port = if first_won {
        &managed_port
    } else {
        &other_port
    };
    assert!(TcpStream::connect(("127.0.0.1", winning_port.parse::<u16>().unwrap())).is_ok());
    assert!(
        instance_lock_held(&f),
        "ready instance lost ownership during handoff"
    );
    if first_won == first_managed {
        assert_eq!(f.snapshot()["schema_version"], 2);
        assert!(f.snapshot()["prepared"]["controller_secret"] == f.auto("managed"));
        f.ok(&["connection", "list", "--json"]);
    } else {
        assert!(
            f.auto("managed").is_null(),
            "already_running start generated a profile key"
        );
        assert_eq!(f.store().load().unwrap().token, before);
    }
}

fn instance_lock_held(f: &Fixture) -> bool {
    if !f.runtime().exists() {
        return false;
    }
    let dir = zc::fsutil::SecureDir::open(f.runtime()).unwrap();
    match dir.lock("zc.lock", Duration::from_millis(1)) {
        Ok(_) => false,
        Err(error) => {
            assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
            true
        }
    }
}

#[test]
fn start_ownership_foreground_holds_instance_but_releases_launch_before_runtime() {
    let f = Fixture::new();
    f.load("managed", &source(free_port(), ""));
    let unmanaged = f.home.path().join("unmanaged.yaml");
    fs::write(&unmanaged, "rules: ['MATCH,REJECT']\n").unwrap();
    let script = script(&f, true);
    let port = free_port().to_string();
    let foreground = Process::spawn(f.command(&[
        "start",
        "--foreground",
        "-c",
        unmanaged.to_str().unwrap(),
        "--port",
        &port,
        "--override-script",
        script.to_str().unwrap(),
        "--override-timeout-ms",
        "20000",
        "--json",
    ]));
    let pid = foreground.0.as_ref().unwrap().id();
    wait(|| f.home.path().join("gate").exists());
    let owns_during_prepare = instance_lock_held(&f);
    let contender = Process::spawn(f.command(&[
        "start",
        "-c",
        "managed",
        "--port",
        &free_port().to_string(),
        "--json",
    ]));
    fs::write(f.home.path().join("release"), "").unwrap();
    let contender = contender.output();
    assert!(
        owns_during_prepare,
        "foreground prepared without instance ownership"
    );
    assert!(contender.status.success(), "{contender:?}");
    let result: Value = serde_json::from_slice(&contender.stdout).unwrap();
    assert_eq!(result["data"]["detail"], "already_running");
    assert_eq!(result["data"]["pid"], pid);
    assert!(TcpStream::connect(("127.0.0.1", port.parse::<u16>().unwrap())).is_ok());
    assert!(instance_lock_held(&f));
    // A foreground run must not hold this short-lived lock until shutdown.
    let dir = zc::fsutil::SecureDir::open(f.runtime()).unwrap();
    drop(
        dir.lock("zc.launch.lock", Duration::from_millis(1))
            .unwrap(),
    );
    fs::remove_file(f.home.path().join("gate")).unwrap();
    assert_running_start_has_no_prepare_side_effects(&f);
    f.ok(&["stop", "--json"]);
    assert!(foreground.output().status.success());
    assert!(!instance_lock_held(&f));
}

#[test]
#[ignore = "requires pre-change Rust binary via ZC_PROFILE_SECRET_OLD_BINARY"]
fn actual_old_foreground_cannot_overtake_start_ownership_during_prepare() {
    let old = std::env::var("ZC_PROFILE_SECRET_OLD_BINARY").unwrap();
    let f = Fixture::new();
    f.load("managed", &source(free_port(), ""));
    let unmanaged = f.home.path().join("unmanaged.yaml");
    fs::write(&unmanaged, "rules: ['MATCH,REJECT']\n").unwrap();
    let script = script(&f, true);
    let first = Process::spawn(f.command(&[
        "start",
        "-c",
        "managed",
        "--port",
        &free_port().to_string(),
        "--override-script",
        script.to_str().unwrap(),
        "--override-timeout-ms",
        "20000",
        "--json",
    ]));
    wait(|| f.home.path().join("gate").exists());
    let mut command = Command::new(old);
    command
        .args([
            "start",
            "--foreground",
            "-c",
            unmanaged.to_str().unwrap(),
            "--port",
            &free_port().to_string(),
            "--json",
        ])
        .env("HOME", f.home.path().canonicalize().unwrap())
        .env_remove("XDG_RUNTIME_DIR")
        .env_remove("XDG_CONFIG_HOME")
        .env_remove("XDG_STATE_HOME");
    // This binary bypasses zc.launch.lock, so launch-only protection is insufficient.
    let other = Process::spawn(command).output();
    fs::write(f.home.path().join("release"), "").unwrap();
    assert!(!other.status.success(), "{other:?}");
    let result: Value = serde_json::from_slice(&other.stdout).unwrap();
    assert_eq!(result["error"]["code"], "START_FAILED");
    let first = first.output();
    assert!(first.status.success(), "{first:?}");
    assert_eq!(f.snapshot()["schema_version"], 2);
    assert!(f.snapshot()["prepared"]["controller_secret"] == f.auto("managed"));
    f.ok(&["connection", "list", "--json"]);
}

#[test]
fn readonly_validation_unmanaged_and_absent_controller_do_not_generate_keys() {
    let f = Fixture::new();
    let controller = free_port();
    f.load("managed", &source(controller, ""));
    for args in [
        vec!["config", "list", "--json"],
        vec!["config", "dump", "--json"],
        vec!["config", "dump", "--no-override", "--json"],
        vec!["config", "use", "managed", "--json"],
        vec!["config", "override", "--json"],
        vec!["proxy", "list", "--json"],
        vec!["proxy", "select", "--json"],
        vec!["proxy", "select", "-g", "pick", "-p", "REJECT", "--json"],
    ] {
        f.ok(&args);
        assert!(f.auto("managed").is_null());
    }
    let before = f.store().load().unwrap().token;
    let failure = f.run(&["start", "--port", &controller.to_string(), "--json"]);
    assert!(!failure.status.success());
    assert_eq!(f.store().load().unwrap().token, before);
    let script = f.home.path().join("bad.lua");
    fs::write(&script, "return { rules = { 'MATCH,missing' } }").unwrap();
    assert!(
        !f.run(&[
            "start",
            "--port",
            &free_port().to_string(),
            "--override-script",
            script.to_str().unwrap(),
            "--json"
        ])
        .status
        .success()
    );
    assert_eq!(f.store().load().unwrap().token, before);
    f.ok(&[
        "start",
        "-c",
        f.home.path().join("managed.yaml").to_str().unwrap(),
        "--port",
        &free_port().to_string(),
        "--json",
    ]);
    assert!(f.auto("managed").is_null());
    let out: Value =
        serde_json::from_slice(&f.run(&["connection", "list", "--json"]).stdout).unwrap();
    assert_eq!(out["error"]["code"], "CONNECTION_SECRET_REQUIRED");
    f.ok(&["stop", "--json"]);
    f.load("explicit", &source(controller, "EXPLICIT_FIRST"));
    f.start();
    assert!(f.auto("explicit").is_null());
    assert_eq!(f.snapshot()["schema_version"], 1);
    assert!(authorized(controller, "EXPLICIT_FIRST"));
    f.ok(&["stop", "--json"]);
    f.load("without", "rules: ['MATCH,REJECT']\n");
    f.start();
    assert!(f.auto("without").is_null());
    assert!(f.descriptor()["endpoint"].is_null());
    let out: Value =
        serde_json::from_slice(&f.run(&["connection", "list", "--json"]).stdout).unwrap();
    assert_eq!(out["error"]["code"], "CONNECTION_CONTROLLER_REQUIRED");
}

#[test]
fn frozen_auto_secret_survives_selection_head_active_changes_and_failed_restart() {
    let f = Fixture::new();
    let controller = free_port();
    f.load("managed", &source(controller, ""));
    f.start();
    let key = f.auto("managed");
    assert_eq!(f.snapshot()["schema_version"], 2);
    assert_eq!(f.snapshot()["prepared"]["controller_secret"], key);
    assert_eq!(
        f.ok(&["proxy", "select", "-g", "pick", "-p", "REJECT", "--json"])["data"]["applied"],
        true
    );
    assert_eq!(f.snapshot()["prepared"]["controller_secret"], key);
    let occupied = TcpListener::bind("127.0.0.1:0").unwrap();
    let out = f.run(&[
        "restart",
        "--port",
        &occupied.local_addr().unwrap().port().to_string(),
        "--json",
    ]);
    assert!(!out.status.success());
    assert!(String::from_utf8_lossy(&out.stdout).contains("restored"));
    assert_eq!(f.snapshot()["prepared"]["controller_secret"], key);
    assert_eq!(
        f.ok(&["status", "--json"])["data"]["selected_proxies"][0]["proxy"],
        "REJECT"
    );
    f.ok(&["connection", "list", "--json"]);
    let store = f.store();
    let old = store.get("managed").unwrap();
    let bundle = Bundle::from_memory(
        source(controller, "NEW_EXPLICIT").as_bytes(),
        None,
        Default::default(),
    )
    .unwrap();
    store
        .publish(
            &store.load().unwrap().token,
            "managed",
            Some(&old.head),
            &bundle,
            Metadata::default(),
            true,
        )
        .unwrap();
    f.load("other", &source(free_port(), "OTHER_EXPLICIT"));
    assert!(authorized(controller, key.as_str().unwrap()));
    assert!(!authorized(controller, "NEW_EXPLICIT"));
    f.ok(&["connection", "list", "--json"]);
    let before = store.load().unwrap().token;
    f.ok(&["start", "-c", "other", "--json"]);
    assert_eq!(store.load().unwrap().token, before);
    // Existing readiness rejects a superseded head; exact rollback must keep its key.
    let restart = f.run(&["restart", "--json"]);
    assert!(!restart.status.success());
    assert!(String::from_utf8_lossy(&restart.stdout).contains("restored"));
    assert_eq!(store.load().unwrap().token, before);
    assert_eq!(f.snapshot()["prepared"]["controller_secret"], key);
    f.ok(&["connection", "list", "--json"]);
}

#[test]
fn subscription_update_explicit_secret_and_override_preserve_automatic_lifecycle() {
    let f = Fixture::new();
    let controller = free_port();
    let server = TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/subscription", server.local_addr().unwrap());
    let peer = std::thread::spawn(move || {
        for secret in ["", "EXPLICIT_SECRET", ""] {
            let (mut stream, _) = server.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(10)))
                .unwrap();
            let mut headers = Vec::new();
            while !headers.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                stream.read_exact(&mut byte).unwrap();
                headers.push(byte[0]);
            }
            let body = source(controller, secret);
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                body.len()
            )
            .unwrap();
        }
    });
    f.ok(&["config", "download", &url, "-n", "managed", "--json"]);
    assert!(f.auto("managed").is_null());
    f.start();
    let key = f.auto("managed");
    for secret in ["EXPLICIT_SECRET", key.as_str().unwrap()] {
        assert_eq!(
            f.ok(&["config", "update", "managed", "--json"])["data"]["applied"],
            true
        );
        assert_eq!(f.auto("managed"), key);
        assert!(authorized(controller, secret));
        f.ok(&["connection", "list", "--json"]);
        if secret == "EXPLICIT_SECRET" {
            assert!(!authorized(controller, key.as_str().unwrap()));
            assert_eq!(f.snapshot()["schema_version"], 1);
            assert!(f.snapshot()["prepared"].get("controller_secret").is_none());
        }
    }
    peer.join().unwrap();
    let script = f.home.path().join("override.lua");
    fs::write(&script, "return { mode = 'rule' }").unwrap();
    for args in [
        vec!["config", "override", script.to_str().unwrap(), "--json"],
        vec!["config", "override", "--clear", "--json"],
    ] {
        assert_eq!(f.ok(&args)["data"]["applied"], true);
        assert_eq!(f.auto("managed"), key);
        assert_eq!(f.snapshot()["prepared"]["controller_secret"], key);
        f.ok(&["connection", "list", "--json"]);
    }
}

// Python's standard HMAC is an independent wire oracle; secrets never enter argv/env.
fn sign_snapshot(f: &Fixture, bytes: &[u8], nonce: &str) -> String {
    let dir = zc::fsutil::SecureDir::open(f.runtime()).unwrap();
    dir.atomic_write("fixture-input", bytes).unwrap();
    let out = Command::new("python3").args(["-c", r#"
import hashlib, hmac, pathlib, sys
root = pathlib.Path(sys.argv[1])
body = (root / 'fixture-input').read_bytes()
key = (root / 'zc.prepared.key').read_bytes()
print('zc.prepared.' + hmac.new(key, body, hashlib.sha256).hexdigest() + '.' + sys.argv[2] + '.snapshot')
"#]).arg(f.runtime()).arg(nonce).output().unwrap();
    assert!(out.status.success());
    let name = String::from_utf8(out.stdout).unwrap().trim().to_owned();
    dir.atomic_write(&name, bytes).unwrap();
    name
}

#[test]
fn schema_two_requires_complete_authenticated_overlay_and_never_falls_back() {
    let f = Fixture::new();
    f.load("managed", &source(free_port(), ""));
    f.start();
    let valid = f.snapshot();
    let nonce = valid["nonce"].as_str().unwrap();
    let mut cases = Vec::new();
    for value in [
        Value::Null,
        json!(""),
        json!("PRIVATE_BAD_VALUE"),
        json!("A".repeat(64)),
        json!(42),
        json!({"PRIVATE_BAD_VALUE":true}),
    ] {
        let mut next = valid.clone();
        next["prepared"]["controller_secret"] = value;
        cases.push(serde_json::to_vec(&next).unwrap());
    }
    let mut missing = valid.clone();
    missing["prepared"]
        .as_object_mut()
        .unwrap()
        .remove("controller_secret");
    cases.push(serde_json::to_vec(&missing).unwrap());
    for kind in [
        "schema1",
        "unmanaged",
        "explicit",
        "controller",
        "unknown",
        "identity",
    ] {
        let mut next = valid.clone();
        match kind {
            "schema1" => next["schema_version"] = json!(1),
            "unmanaged" => next["prepared"]["identity"] = Value::Null,
            "explicit" => {
                next["prepared"]["source"] = json!(source(free_port(), "PRIVATE_BAD_VALUE"))
            }
            "controller" => next["prepared"]["source"] = json!("rules: ['MATCH,REJECT']\n"),
            "unknown" => next["prepared"]["PRIVATE_BAD_VALUE"] = json!(true),
            "identity" => next["prepared"]["identity"]["revision"] = json!("PRIVATE_BAD_VALUE"),
            _ => unreachable!(),
        }
        cases.push(serde_json::to_vec(&next).unwrap());
    }
    let duplicate = serde_json::to_string(&valid).unwrap().replace(
        "\"controller_secret\":",
        "\"controller_secret\":\"PRIVATE_BAD_VALUE\",\"controller_secret\":",
    );
    cases.push(duplicate.into_bytes());
    let mut legacy_null = missing.clone();
    legacy_null["schema_version"] = json!(1);
    legacy_null["prepared"]["controller_secret"] = Value::Null;
    cases.push(serde_json::to_vec(&legacy_null).unwrap());
    for bytes in cases {
        let name = sign_snapshot(&f, &bytes, nonce);
        let out = f.run(&["--daemon-run", &name, nonce]);
        assert!(!out.status.success());
        let error = String::from_utf8_lossy(&out.stderr);
        assert!(error.contains("START_SNAPSHOT_INVALID"), "{error}");
        assert!(!error.contains("PRIVATE_BAD_VALUE"), "{error}");
        assert!(!error.contains(valid["prepared"]["controller_secret"].as_str().unwrap()));
    }
    let name = sign_snapshot(&f, &serde_json::to_vec(&valid).unwrap(), nonce);
    // An authentic overlay passes decoding, then rejects missing lock handoff.
    let out = f.run(&["--daemon-run", &name, nonce]);
    assert!(String::from_utf8_lossy(&out.stderr).contains("START_LOCK_HANDOFF_INVALID"));
    fs::write(
        f.runtime().join(&name),
        serde_json::to_vec(&missing).unwrap(),
    )
    .unwrap();
    let out = f.run(&["--daemon-run", &name, nonce]);
    assert!(String::from_utf8_lossy(&out.stderr).contains("snapshot authentication failed"));
    f.ok(&["connection", "list", "--json"]);
}

#[test]
#[ignore = "requires pre-change Rust binary via ZC_PROFILE_SECRET_OLD_BINARY"]
fn actual_old_rust_restart_does_not_upgrade_and_old_reader_rejects_schema_two() {
    let old = std::env::var("ZC_PROFILE_SECRET_OLD_BINARY").unwrap();
    let f = Fixture::new();
    f.load("managed", &source(free_port(), ""));
    let out = Command::new(&old)
        .args(["start", "--port", &free_port().to_string(), "--json"])
        .env("HOME", f.home.path().canonicalize().unwrap())
        .env_remove("XDG_RUNTIME_DIR")
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    assert_eq!(f.snapshot()["schema_version"], 1);
    assert_running_start_has_no_prepare_side_effects(&f);
    let before = f.store().load().unwrap().token;
    f.ok(&["start", "--json"]);
    f.ok(&["restart", "--json"]);
    assert_eq!(f.store().load().unwrap().token, before);
    assert!(f.auto("managed").is_null());
    assert_eq!(f.snapshot()["schema_version"], 1);
    let out: Value =
        serde_json::from_slice(&f.run(&["connection", "list", "--json"]).stdout).unwrap();
    assert_eq!(out["error"]["code"], "CONNECTION_SECRET_REQUIRED");
    f.ok(&["restart", "-c", "managed", "--json"]);
    f.ok(&["connection", "list", "--json"]);
    assert_eq!(f.snapshot()["schema_version"], 2);
    let d = f.descriptor();
    let path = PathBuf::from(d["invocation"]["config_path"].as_str().unwrap());
    let out = Command::new(&old)
        .args([
            "--daemon-run",
            path.file_name().unwrap().to_str().unwrap(),
            d["nonce"].as_str().unwrap(),
        ])
        .env("HOME", f.home.path().canonicalize().unwrap())
        .env_remove("XDG_RUNTIME_DIR")
        .output()
        .unwrap();
    assert!(!out.status.success());
    assert!(
        String::from_utf8_lossy(&out.stderr).contains("START_SNAPSHOT_INVALID"),
        "{out:?}"
    );
    assert!(!String::from_utf8_lossy(&out.stderr).contains("START_LOCK_HANDOFF_INVALID"));
}

#[cfg(target_os = "macos")]
#[test]
fn fsync_failure_refuses_start_keeps_old_instance_and_new_process_resyncs_same_key() {
    for running in [false, true] {
        let f = Fixture::new();
        let controller = free_port();
        let port = free_port();
        f.load("managed", &source(controller, ""));
        let original_pid = if running {
            let old = f.home.path().join("old.yaml");
            fs::write(&old, "rules: ['MATCH,REJECT']\n").unwrap();
            Some(
                f.ok(&[
                    "start",
                    "-c",
                    old.to_str().unwrap(),
                    "--port",
                    &port.to_string(),
                    "--json",
                ])["data"]["pid"]
                    .clone(),
            )
        } else {
            None
        };
        let dylib = f.home.path().join("state_io_fault.dylib");
        assert!(
            Command::new("cc")
                .args(["-dynamiclib", "-o"])
                .arg(&dylib)
                .arg(concat!(
                    env!("CARGO_MANIFEST_DIR"),
                    "/tests/support/state_io_fault.c"
                ))
                .status()
                .unwrap()
                .success()
        );
        let root = f.store().root_path().canonicalize().unwrap();
        let armed = f.home.path().join("armed");
        let port = port.to_string();
        let args = [
            if running { "restart" } else { "start" },
            "-c",
            "managed",
            "--port",
            &port,
            "--json",
        ];
        let mut key = Value::Null;
        // Each CLI retry constructs a fresh Store. Both commit and reuse must sync.
        for pass in 0..2 {
            fs::write(&armed, b"armed").unwrap();
            let out = f
                .command(&args)
                .env("DYLD_INSERT_LIBRARIES", &dylib)
                .env("TEST_FAIL_SYNC_DIR", &root)
                .env("TEST_FAIL_SYNC_READY", root.join("state-v2.json"))
                .env("TEST_FAIL_SYNC_ARMED", &armed)
                .output()
                .unwrap();
            assert!(
                String::from_utf8_lossy(&out.stderr).contains("INJECT_EIO"),
                "{out:?}"
            );
            assert!(!out.status.success(), "{out:?}");
            assert!(String::from_utf8_lossy(&out.stdout).contains("durability unconfirmed"));
            let visible = f.auto("managed");
            assert!(visible.is_string());
            if pass == 0 {
                key = visible;
            } else {
                assert_eq!(visible, key);
            }
            let status = f.ok(&["status", "--json"]);
            if let Some(pid) = &original_pid {
                assert_eq!(&status["data"]["pid"], pid);
            } else {
                assert_eq!(status["data"]["state"], "stopped");
                assert!(TcpStream::connect(("127.0.0.1", port.parse::<u16>().unwrap())).is_err());
            }
            assert!(TcpStream::connect(("127.0.0.1", controller)).is_err());
        }
        f.ok(&args);
        assert_eq!(f.auto("managed"), key);
        f.ok(&["connection", "list", "--json"]);
        assert!(authorized(controller, key.as_str().unwrap()));
    }
}

#[test]
fn bind_failure_keeps_durable_key_and_retry_reuses_it() {
    let f = Fixture::new();
    let busy = TcpListener::bind("127.0.0.1:0").unwrap();
    f.load("managed", &source(busy.local_addr().unwrap().port(), ""));
    let port = free_port().to_string();
    assert!(
        !f.run(&["start", "--port", &port, "--json"])
            .status
            .success()
    );
    let key = f.auto("managed");
    assert!(key.is_string());
    drop(busy);
    f.ok(&["start", "--port", &port, "--json"]);
    assert_eq!(f.auto("managed"), key);
    f.ok(&["connection", "list", "--json"]);
}

#[tokio::test]
async fn service_preparation_child() {
    if std::env::var_os("ZC_PROFILE_SECRET_SERVICE_CHILD").is_none() {
        return;
    }
    use zc::service::{self, PrepareOptions};
    let store = service::open_store().unwrap();
    let controller = free_port();
    let bundle =
        Bundle::from_memory(source(controller, "").as_bytes(), None, Default::default()).unwrap();
    store
        .publish(
            &store.load().unwrap().token,
            "managed",
            None,
            &bundle,
            Metadata::default(),
            true,
        )
        .unwrap();
    let before = store.load().unwrap();
    let options = PrepareOptions {
        port: Some(free_port()),
        ..Default::default()
    };
    for command in [
        "proxy list",
        "proxy select",
        "proxy test",
        "profile test",
        "test",
        "doctor",
        "config dump",
    ] {
        let prepared = service::prepare(PrepareOptions {
            command: command.into(),
            ..options.clone()
        })
        .await
        .unwrap();
        assert!(prepared.controller_secret.is_none());
        assert_eq!(store.load().unwrap().token, before.token);
    }
    service::diagnose_config(&options).await.unwrap();
    assert_eq!(store.load().unwrap().token, before.token);
    let stale = service::load(None).unwrap();
    let profile = store.get("managed").unwrap();
    store
        .select(
            &before.token,
            "managed",
            &profile.head,
            0,
            vec![zc::store::Selection {
                group: "removed".into(),
                proxy: "DIRECT".into(),
            }],
        )
        .unwrap();
    let after_selection = store.load().unwrap().token;
    assert!(
        service::prepare_loaded(stale, options.clone())
            .await
            .is_err()
    );
    assert_eq!(store.load().unwrap().token, after_selection);
    assert!(
        store
            .get("managed")
            .unwrap()
            .auto_controller_secret
            .is_none()
    );
    // Reconciliation commits first; automatic key must use that receipt's token.
    let prepared = service::prepare(options.clone()).await.unwrap();
    let config = service::prepared_config(&prepared).unwrap();
    assert_eq!(config.secret().len(), 64);
    assert_eq!(config.document()["secret"], "");
    assert!(!prepared.source.contains(config.secret()));
    assert!(!format!("{prepared:?}").contains(config.secret()));
    assert_eq!(prepared.generation, 2);
    let key = store.get("managed").unwrap().auto_controller_secret;
    let head = store.get("managed").unwrap().head;
    let explicit = "  Exact UTF8 秘密  ";
    let bundle = Bundle::from_memory(
        source(controller, explicit).as_bytes(),
        None,
        Default::default(),
    )
    .unwrap();
    store
        .publish(
            &store.load().unwrap().token,
            "managed",
            Some(&head),
            &bundle,
            Metadata::default(),
            true,
        )
        .unwrap();
    let frozen = service::prepare(options).await.unwrap();
    assert!(frozen.controller_secret.is_none());
    assert_eq!(
        service::prepared_config(&frozen)
            .unwrap()
            .secret()
            .as_bytes(),
        explicit.as_bytes()
    );
    assert!(!format!("{frozen:?}").contains(explicit));
    assert_eq!(store.get("managed").unwrap().auto_controller_secret, key);
}

#[test]
fn service_validation_cas_and_readonly_commands_use_isolated_authority() {
    let f = Fixture::new();
    let out = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", "service_preparation_child", "--nocapture"])
        .env("HOME", f.home.path().canonicalize().unwrap())
        .env_remove("XDG_RUNTIME_DIR")
        .env("ZC_PROFILE_SECRET_SERVICE_CHILD", "1")
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
}

#[test]
#[ignore = "requires legacy Zig binary via ZC_PROFILE_SECRET_ZIG_BINARY"]
fn actual_legacy_zig_snapshot_restart_keeps_no_overlay_until_explicit_reprepare() {
    let old = std::env::var("ZC_PROFILE_SECRET_ZIG_BINARY").unwrap();
    let f = Fixture::new();
    let controller = free_port();
    f.load("managed", &source(controller, ""));
    let out = Command::new(&old)
        .args(["start", "--port", &free_port().to_string(), "--json"])
        .env("HOME", f.home.path().canonicalize().unwrap())
        .env_remove("XDG_RUNTIME_DIR")
        .output()
        .unwrap();
    assert!(out.status.success(), "{out:?}");
    assert!(
        f.descriptor()["invocation"]["config_path"]
            .as_str()
            .unwrap()
            .ends_with(".yaml")
    );
    let before = f.store().load().unwrap().token;
    f.ok(&["start", "--json"]);
    f.ok(&["restart", "--json"]);
    assert_eq!(f.store().load().unwrap().token, before);
    assert!(f.auto("managed").is_null());
    assert_eq!(f.snapshot()["schema_version"], 1);
    let out: Value =
        serde_json::from_slice(&f.run(&["connection", "list", "--json"]).stdout).unwrap();
    assert_eq!(out["error"]["code"], "CONNECTION_SECRET_REQUIRED");
    f.ok(&["restart", "-c", "managed", "--json"]);
    f.ok(&["connection", "list", "--json"]);
    assert_eq!(f.snapshot()["schema_version"], 2);
    assert!(authorized(controller, f.auto("managed").as_str().unwrap()));
}
