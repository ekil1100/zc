#[path = "support/cli_fixture.rs"]
mod cli_fixture;
use serde_json::Value;
use std::{
    io::{Read, Write},
    net::{TcpListener, TcpStream},
    process::{Command, Output},
    time::{Duration, Instant},
};

struct Fixture {
    home: tempfile::TempDir,
    _serial: std::sync::MutexGuard<'static, ()>,
}
impl Fixture {
    fn new() -> Self {
        Self {
            _serial: cli_fixture::serial(),
            home: tempfile::tempdir().unwrap(),
        }
    }
    fn run(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_zc"))
            .args(args)
            .env("HOME", self.home.path().canonicalize().unwrap())
            .env_remove("XDG_RUNTIME_DIR")
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_STATE_HOME")
            .env("HTTP_PROXY", "http://127.0.0.1:1")
            .env("ALL_PROXY", "http://127.0.0.1:1")
            .env("NO_PROXY", "")
            .output()
            .unwrap()
    }
    fn ok(&self, args: &[&str]) -> Value {
        let out = self.run(args);
        assert!(out.status.success(), "{args:?}: {out:?}");
        serde_json::from_slice(&out.stdout).unwrap()
    }
    fn error(&self, args: &[&str], exit: i32, code: &str) -> Value {
        let out = self.run(args);
        assert_eq!(out.status.code(), Some(exit), "{out:?}");
        let value: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], code, "{value}");
        value
    }
    fn start(&self, extra: &str) -> u16 {
        self.start_source(&format!("{extra}\nrules: ['MATCH,DIRECT']\n"))
    }
    fn start_source(&self, source: &str) -> u16 {
        let config = self.home.path().join("connection.yaml");
        std::fs::write(&config, source).unwrap();
        let port = free_port();
        self.ok(&[
            "start",
            "-c",
            config.to_str().unwrap(),
            "--port",
            &port.to_string(),
            "--json",
        ]);
        port
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
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
fn pending(port: u16) -> TcpStream {
    let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
    stream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    stream.write_all(b"C").unwrap();
    stream
}
fn one(f: &Fixture) -> Value {
    let deadline = Instant::now() + Duration::from_secs(3);
    loop {
        let data = f.ok(&["connection", "list", "--json"])["data"].clone();
        if data["connections"].as_array().unwrap().len() == 1 {
            return data["connections"][0].clone();
        }
        assert!(Instant::now() < deadline);
    }
}
#[test]
fn connection_help_usage_and_stopped_are_explicit() {
    let f = Fixture::new();
    for args in [
        vec!["connection"],
        vec!["connection", "--json"],
        vec!["help", "connection"],
        vec!["connection", "close", "--help"],
    ] {
        let out = f.run(&args);
        assert!(out.status.success(), "{out:?}");
        let text = String::from_utf8(out.stdout).unwrap();
        assert!(
            text.contains("connection") && text.contains("close"),
            "{text}"
        );
    }
    for flag in ["--json", "--no-color"] {
        for help in ["-h", "--help"] {
            for args in [
                vec!["connection", flag, help],
                vec!["connection", help, flag],
            ] {
                let out = f.run(&args);
                assert!(out.status.success(), "{args:?}: {out:?}");
                let text = String::from_utf8(out.stdout).unwrap();
                assert!(text.contains("Usage: zc connection <subcommand>"), "{text}");
                assert!(out.stderr.is_empty(), "{args:?}: {:?}", out.stderr);
            }
        }
    }
    assert!(
        String::from_utf8(f.run(&["--help"]).stdout)
            .unwrap()
            .contains("connection")
    );
    for (args, code) in [
        (
            vec!["connection", "nope", "--json"],
            "CONNECTION_SUBCOMMAND_UNKNOWN",
        ),
        (
            vec!["connection", "--json", "--all"],
            "CONNECTION_ARGUMENT_INVALID",
        ),
        (
            vec!["connection", "--no-color", "--all", "--json"],
            "CONNECTION_ARGUMENT_INVALID",
        ),
        (
            vec!["connection", "--json", "--port", "help"],
            "CONNECTION_ARGUMENT_INVALID",
        ),
        (
            vec!["connection", "--json", "--unknown=--help"],
            "CONNECTION_ARGUMENT_INVALID",
        ),
        (
            vec!["connection", "list", "--port", "help", "--json"],
            "CONNECTION_LIST_ARGUMENT_INVALID",
        ),
        (
            vec!["connection", "close", "--json"],
            "CONNECTION_CLOSE_ID_REQUIRED",
        ),
        (
            vec!["connection", "close", "bad", "--json"],
            "CONNECTION_CLOSE_ARGUMENT_INVALID",
        ),
        (
            vec!["connection", "list", "extra", "--json"],
            "CONNECTION_LIST_ARGUMENT_INVALID",
        ),
        (
            vec!["connection", "list", "-c", "file", "--json"],
            "CONNECTION_LIST_ARGUMENT_INVALID",
        ),
        (
            vec!["connection", "list", "--port", "12345", "--json"],
            "CONNECTION_LIST_ARGUMENT_INVALID",
        ),
        (
            vec!["connection", "close", "--all", "--json"],
            "CONNECTION_CLOSE_ARGUMENT_INVALID",
        ),
        (
            vec!["connection", "list", "--override-script", "file", "--json"],
            "CONNECTION_LIST_ARGUMENT_INVALID",
        ),
    ] {
        f.error(&args, 2, code);
    }
    f.error(
        &["connection", "list", "--json"],
        1,
        "CONNECTION_NOT_RUNNING",
    );
}

#[test]
fn cli_uses_frozen_secret_and_rejects_old_ids_after_restart() {
    let f = Fixture::new();
    let port = f.start(&format!(
        "external-controller: 127.0.0.1:{}\nsecret: PRIVATE_SECRET",
        free_port()
    ));
    let mut old = pending(port);
    let entry = one(&f);
    let id = entry["id"].as_str().unwrap();
    assert_eq!(entry["phase"], "handshake");
    assert!(entry.get("target").is_none());
    let text = f.run(&["connection", "list"]);
    assert!(text.status.success());
    assert!(String::from_utf8(text.stdout).unwrap().contains(id));
    // Source edits must not replace the authenticated running snapshot.
    std::fs::write(
        f.home.path().join("connection.yaml"),
        "secret: wrong\nrules: ['MATCH,REJECT']\n",
    )
    .unwrap();
    f.ok(&["connection", "list", "--json"]);
    f.ok(&["restart", "--json"]);
    assert!(matches!(old.read(&mut [0]), Ok(0) | Err(_)));
    let mut new = pending(port);
    let next = one(&f);
    assert_ne!(next["id"], entry["id"]);
    f.error(
        &["connection", "close", id, "--json"],
        1,
        "CONNECTION_INSTANCE_CHANGED",
    );
    assert_eq!(one(&f)["id"], next["id"]);
    let id = next["id"].as_str().unwrap();
    assert_eq!(
        f.ok(&["connection", "close", id, "--json"])["data"]["close_requested"],
        true
    );
    assert!(matches!(new.read(&mut [0]), Ok(0) | Err(_)));
    f.error(
        &["connection", "close", id, "--json"],
        1,
        "CONNECTION_NOT_FOUND",
    );
    f.ok(&["stop", "--json"]);
    let log =
        std::fs::read_to_string(f.home.path().join(".local/state/zc/runtime/zc.log")).unwrap();
    assert!(!log.contains("PRIVATE_SECRET") && !log.contains("connection_failed"));
}

#[test]
fn missing_controller_and_secret_do_not_fake_empty_lists() {
    let f = Fixture::new();
    for (extra, code) in [
        (String::new(), "CONNECTION_CONTROLLER_REQUIRED"),
        (
            format!("external-controller: 127.0.0.1:{}", free_port()),
            "CONNECTION_SECRET_REQUIRED",
        ),
    ] {
        f.start(&extra);
        let value = f.error(&["connection", "list", "--json"], 1, code);
        let hint = value["error"]["hint"].as_str().unwrap();
        assert!(
            hint.contains("restart -c") && hint.contains("snapshot"),
            "{hint}"
        );
        f.ok(&["stop", "--json"]);
    }
}

// An external HTTP boundary fixture, launched as a separate isolated process.
// It reuses a CLI-created authenticated snapshot, not a production test hook.
#[test]
fn fake_controller_boundary() {
    let Some(home) = std::env::var_os("ZC_CONNECTION_FAKE_HOME") else {
        return;
    };
    let home = std::path::PathBuf::from(home);
    let runtime = home.join(".local/state/zc/runtime");
    let dir = zc::fsutil::SecureDir::open(&runtime).unwrap();
    let _lock = dir.lock("zc.lock", Duration::from_secs(1)).unwrap();
    let original = std::fs::read_to_string(home.join("descriptor.fixture")).unwrap();
    let value: Value = serde_json::from_str(&original).unwrap();
    let nonce = value["nonce"].as_str().unwrap();
    let endpoint = value["endpoint"].as_str().unwrap();
    let listener = TcpListener::bind(endpoint).unwrap();
    let descriptor = original.replacen(
        &format!("\"pid\":{}", value["pid"]),
        &format!("\"pid\":{}", std::process::id()),
        1,
    );
    dir.atomic_write("zc.pid", format!("{}\n", std::process::id()).as_bytes())
        .unwrap();
    dir.atomic_write("zc.daemon.json", descriptor.as_bytes())
        .unwrap();
    println!("READY");
    std::io::stdout().flush().unwrap();
    for case in 0..32 {
        let (mut socket, _) = listener.accept().unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            let mut byte = [0];
            socket.read_exact(&mut byte).unwrap();
            request.push(byte[0]);
            assert!(request.len() < 16384);
        }
        let request = String::from_utf8(request).unwrap();
        assert!(
            request
                .to_lowercase()
                .contains(&format!("x-zc-instance-nonce: {nonce}"))
        );
        assert!(
            request
                .to_lowercase()
                .contains("authorization: bearer private_secret")
        );
        let id = format!("{nonce}-1");
        let body = match case {
            0 => "{".to_owned(),
            1 => r#"{"connections":{}}"#.to_owned(),
            2 => format!(
                r#"{{"connections":[{{"id":"{nonce}-0","source":"127.0.0.1:1","protocol":"tcp","phase":"handshake"}}]}}"#
            ),
            3 => format!(
                r#"{{"connections":[{{"id":"{id}","source":"127.0.0.1:1","protocol":"tcp","phase":"invented"}}]}}"#
            ),
            4 => " ".repeat(4 * 1024 * 1024 + 1),
            5 => r#"{"error":"PRIVATE_REMOTE_BODY"}"#.into(),
            9 | 20..=29 => r#"{"error":"PRIVATE_REMOTE_BODY"}"#.into(),
            10 => format!(r#"{{"id":"{id}","phase":"closing","close_requested":false}}"#),
            11 => format!(r#"{{"id":"{nonce}-2","phase":"closing","close_requested":true}}"#),
            12 => format!(
                r#"{{"connections":[{{"id":"{id}","source":"127.0.0.1:1","protocol":"tcp","phase":"active"}}]}}"#
            ),
            13..=19 => {
                let mut entry = serde_json::json!({
                    "id": id, "source": "127.0.0.1:1", "protocol": "udp",
                    "phase": "active", "inbound": "socks5_udp",
                    "target": {"host": "127.0.0.1", "port": 80},
                    "routed_target": {"host": "127.0.0.1", "port": 80},
                    "rule": {"index": 0, "type": "MATCH", "payload": "", "target": "edge"},
                    "proxy": {"name": "edge", "type": "Shadowsocks"},
                    "datagram_source": "127.0.0.1:2", "target_scope": "first_datagram"
                });
                let fields = entry.as_object_mut().unwrap();
                match case {
                    13 => {
                        fields.remove("datagram_source");
                        fields.remove("target_scope");
                    }
                    14 => {
                        fields.remove("target_scope");
                    }
                    15 => {
                        fields.remove("datagram_source");
                    }
                    17 => {
                        fields.insert("protocol".into(), "tcp".into());
                        fields.insert("inbound".into(), "http_forward".into());
                    }
                    16 | 18 | 19 => {
                        for key in ["target", "routed_target", "rule", "proxy"] {
                            fields.remove(key);
                        }
                        fields.insert("phase".into(), "udp_wait".into());
                        if case != 18 {
                            fields.remove("datagram_source");
                            fields.remove("target_scope");
                        }
                        if case == 16 {
                            fields.insert("protocol".into(), "tcp".into());
                        }
                        if case == 19 {
                            fields.insert("phase".into(), "handshake".into());
                        }
                    }
                    _ => unreachable!(),
                }
                serde_json::json!({"connections": [entry]}).to_string()
            }
            _ => r#"{"connections":[]}"#.into(),
        };
        let status = match case {
            5 => "302 Found",
            9 | 29 => "401 Unauthorized",
            20 | 28 => "403 Forbidden",
            21 => "204 No Content",
            22 | 26 => "404 Not Found",
            23 => "409 Conflict",
            24 | 27 => "500 Internal Server Error",
            25 => "400 Bad Request",
            _ => "200 OK",
        };
        let instance = match case {
            6 | 27..=29 => "X-Zc-Instance-Nonce: wrong\r\n".to_owned(),
            7 | 9 | 20 | 26 => String::new(),
            8 => format!("X-Zc-Instance-Nonce: {nonce}\r\nX-Zc-Instance-Nonce: {nonce}\r\n"),
            _ => format!("X-Zc-Instance-Nonce: {nonce}\r\n"),
        };
        let response = format!(
            "HTTP/1.1 {status}\r\n{instance}Location: http://127.0.0.1:1/PRIVATE_REDIRECT\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
            body.len()
        );
        if case >= 30 {
            // The complete request is the barrier: change only the captured CLI fixture now.
            let next = std::fs::read_to_string(home.join(if case == 30 {
                "selection.fixture"
            } else {
                "restart.fixture"
            }))
            .unwrap();
            let metadata: Value = serde_json::from_str(&next).unwrap();
            let next = next.replacen(
                &format!("\"pid\":{}", metadata["pid"]),
                &format!("\"pid\":{}", std::process::id()),
                1,
            );
            dir.atomic_write("zc.daemon.json", next.as_bytes()).unwrap();
        }
        let _ = socket.write_all(response.as_bytes());
    }
    // Keep process identity and its lock alive through the last CLI postflight.
    let _ = std::io::stdin().read(&mut [0]);
}

#[test]
fn cli_rejects_bad_controller_schema_size_nonce_and_redirect_without_echoing_secrets() {
    use std::io::BufRead;
    let f = Fixture::new();
    f.start(&format!(
        "external-controller: 127.0.0.1:{}\nsecret: PRIVATE_SECRET\nproxy-groups: [{{name: Pick, type: select, proxies: [DIRECT, REJECT]}}]",
        free_port()
    ));
    f.ok(&[
        "config",
        "load",
        f.home.path().join("connection.yaml").to_str().unwrap(),
        "--json",
    ]);
    f.ok(&["restart", "-c", "connection", "--json"]);
    let runtime = f.home.path().join(".local/state/zc/runtime");
    // Capture real CLI-produced, authenticated snapshots for a selection change and a restart.
    let mut snapshots = Vec::new();
    let mut value = Value::Null;
    for name in ["descriptor.fixture", "selection.fixture", "restart.fixture"] {
        if name == "selection.fixture" {
            f.ok(&[
                "proxy",
                "select",
                "-g",
                "Pick",
                "-p",
                "REJECT",
                "-c",
                "connection",
                "--json",
            ]);
        }
        if name == "restart.fixture" {
            f.ok(&["restart", "--json"]);
        }
        let descriptor = std::fs::read(runtime.join("zc.daemon.json")).unwrap();
        let metadata: Value = serde_json::from_slice(&descriptor).unwrap();
        let snapshot =
            std::path::PathBuf::from(metadata["invocation"]["config_path"].as_str().unwrap());
        snapshots.push((
            snapshot.file_name().unwrap().to_str().unwrap().to_owned(),
            std::fs::read(&snapshot).unwrap(),
        ));
        std::fs::write(f.home.path().join(name), descriptor).unwrap();
        if name == "descriptor.fixture" {
            value = metadata;
        }
    }
    f.ok(&["stop", "--json"]);
    let dir = zc::fsutil::SecureDir::open(&runtime).unwrap();
    for (name, frozen) in snapshots {
        dir.atomic_write(&name, &frozen).unwrap();
    }
    let executable = f.home.path().join("zc");
    std::os::unix::fs::symlink(std::env::current_exe().unwrap(), &executable).unwrap();
    struct Child(std::process::Child);
    impl Drop for Child {
        fn drop(&mut self) {
            let _ = self.0.kill();
            let _ = self.0.wait();
        }
    }
    let mut child = Child(
        Command::new(executable)
            .args([
                "--exact",
                "fake_controller_boundary",
                "--skip",
                "--daemon-run",
                "--nocapture",
            ])
            .env("ZC_CONNECTION_FAKE_HOME", f.home.path())
            .env("HOME", f.home.path())
            .env_remove("XDG_RUNTIME_DIR")
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap(),
    );
    let mut reader = std::io::BufReader::new(child.0.stdout.take().unwrap());
    loop {
        let mut line = String::new();
        assert!(reader.read_line(&mut line).unwrap() > 0);
        if line.trim() == "READY" {
            break;
        }
    }
    let id = format!("{}-1", value["nonce"].as_str().unwrap());
    for (case, code) in [
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_FAILED",
        "CONNECTION_INSTANCE_CHANGED",
        "CONNECTION_INSTANCE_CHANGED",
        "CONNECTION_INSTANCE_CHANGED",
        "CONNECTION_UNAUTHORIZED",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        // UDP metadata must be complete and consistent with protocol and phase.
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_SECRET_REQUIRED",
        "CONNECTION_FAILED",
        "CONNECTION_NOT_FOUND",
        "CONNECTION_INSTANCE_CHANGED",
        "CONNECTION_RESPONSE_INVALID",
        "CONNECTION_FAILED",
        "CONNECTION_INSTANCE_CHANGED",
        "CONNECTION_INSTANCE_CHANGED",
        "CONNECTION_SECRET_REQUIRED",
        "CONNECTION_UNAUTHORIZED",
    ]
    .iter()
    .enumerate()
    {
        let args = if (10..12).contains(&case) {
            vec!["connection", "close", &id, "--json"]
        } else {
            vec!["connection", "list", "--json"]
        };
        let value = f.error(&args, 1, code);
        assert!(!value.to_string().contains("PRIVATE_"));
    }
    assert_eq!(
        f.ok(&["connection", "list", "--json"])["data"]["connections"],
        serde_json::json!([])
    );
    f.error(
        &["connection", "list", "--json"],
        1,
        "CONNECTION_INSTANCE_CHANGED",
    );
}

#[test]
fn cli_and_api_share_udp_metadata_and_text_escapes_terminal_controls() {
    let f = Fixture::new();
    let upstream = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    upstream
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    let api = free_port();
    let name = "edge\u{202e}name";
    let port=f.start_source(&format!("external-controller: 127.0.0.1:{api}\nsecret: PRIVATE_SECRET\nproxies: [{{name: {name}, type: ss, server: 127.0.0.1, port: {}, password: PRIVATE_PASSWORD, cipher: aes-128-gcm, udp: true}}]\nrules: ['MATCH,{name}']",upstream.local_addr().unwrap().port()));
    let mut control = TcpStream::connect(("127.0.0.1", port)).unwrap();
    control
        .set_read_timeout(Some(Duration::from_secs(3)))
        .unwrap();
    control
        .write_all(b"\x05\x01\x00\x05\x03\x00\x01\x00\x00\x00\x00\x00\x00")
        .unwrap();
    let mut reply = [0; 12];
    control.read_exact(&mut reply).unwrap();
    assert_eq!(&reply[..6], &[5, 0, 5, 0, 0, 1]);
    let relay = std::net::SocketAddr::from((
        [reply[6], reply[7], reply[8], reply[9]],
        u16::from_be_bytes([reply[10], reply[11]]),
    ));
    let client = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    client
        .send_to(b"\x00\x00\x00\x01\x7f\x00\x00\x01\x00\x35query", relay)
        .unwrap();
    upstream.recv_from(&mut [0; 1024]).unwrap();
    let data = f.ok(&["connection", "list", "--json"])["data"].clone();
    let mut http = TcpStream::connect(("127.0.0.1", api)).unwrap();
    http.set_read_timeout(Some(Duration::from_secs(3))).unwrap();
    http.write_all(b"GET /connections HTTP/1.1\r\nAuthorization: Bearer PRIVATE_SECRET\r\n\r\n")
        .unwrap();
    let mut response = String::new();
    http.read_to_string(&mut response).unwrap();
    assert!(response.starts_with("HTTP/1.1 200"));
    assert_eq!(
        data,
        serde_json::from_str::<Value>(response.split_once("\r\n\r\n").unwrap().1).unwrap()
    );
    let output = f.run(&["connection", "list"]);
    assert!(output.status.success());
    let text = String::from_utf8(output.stdout).unwrap();
    assert!(!text.contains('\u{202e}') && !text.contains("PRIVATE_"));
    assert!(text.contains("\\u{202e}"));
    assert!(
        text.contains("first_datagram") && text.contains(&client.local_addr().unwrap().to_string()),
        "{text}"
    );
    let id = data["connections"][0]["id"].as_str().unwrap();
    f.ok(&["connection", "close", id, "--json"]);
    assert!(matches!(control.read(&mut [0]), Ok(0) | Err(_)));
}
