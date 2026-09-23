#[path = "support/cli_fixture.rs"]
mod cli_fixture;
use serde_json::{Value, json};
use std::{
    path::Path,
    process::{Command, Output},
};

fn run(home: &Path, args: &[&str]) -> Output {
    let home = &home.canonicalize().unwrap();
    Command::new(env!("CARGO_BIN_EXE_zc"))
        .args(args)
        .env("HOME", home)
        .env("XDG_CONFIG_HOME", home.join(".config"))
        .env("XDG_STATE_HOME", home.join(".local/state"))
        .env_remove("XDG_RUNTIME_DIR")
        .stdin(std::process::Stdio::null())
        .output()
        .unwrap()
}
fn ok(home: &Path, args: &[&str]) -> Value {
    let out = run(home, args);
    assert!(
        out.status.success(),
        "{args:?}: {} {}",
        String::from_utf8_lossy(&out.stdout),
        String::from_utf8_lossy(&out.stderr)
    );
    serde_json::from_slice(&out.stdout).unwrap()
}
#[test]
fn immutable_managed_load_selection_and_dump_work_without_daemon() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().join("home");
    std::fs::create_dir(&home).unwrap();
    let empty = ok(&home, &["config", "ls", "--json"]);
    assert_eq!(empty["data"]["configs"], json!([]));
    assert!(!home.join(".config/zc").exists());
    let source = dir.path().join("work.yaml");
    std::fs::write(&source, "mixed-port: 23456\nsecret: secret-value\nproxy-groups: [{name: Pick, type: select, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,Pick']\n").unwrap();
    let loaded = ok(
        &home,
        &["config", "load", source.to_str().unwrap(), "--json"],
    );
    assert_eq!(loaded["data"]["name"], "work");
    assert_eq!(loaded["data"]["applied"], false);
    std::fs::remove_file(source).unwrap();
    let choices = ok(&home, &["proxy", "select", "--json"]);
    assert_eq!(choices["data"]["choices"], json!(["DIRECT", "REJECT"]));
    let selected = ok(
        &home,
        &["profile", "select", "-g", "Pick", "-p", "REJECT", "--json"],
    );
    assert_eq!(selected["data"]["applied"], false);
    assert_eq!(
        ok(&home, &["proxy", "list", "--json"])["data"]["groups"][0]["now"],
        "REJECT"
    );
    let dump = ok(&home, &["config", "dump", "--json"]);
    assert!(dump.get("ok").is_none());
    assert!(dump.get("secret").is_none());
    assert!(!dump.to_string().contains("secret-value"));
    assert_eq!(
        ok(&home, &["config", "use", "work.yaml", "--json"])["data"]["applied"],
        false
    );
    ok(&home, &["config", "delete", "work", "--json"]);
    let out = run(&home, &["start", "--port", "23457", "--json"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        serde_json::from_slice::<Value>(&out.stdout).unwrap()["error"]["code"],
        "START_CONFIG_NOT_SELECTED"
    );
}

#[test]
fn config_list_text_shows_selectable_ids_alongside_display_names() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let empty = run(home, &["config", "list"]);
    assert!(empty.status.success());
    assert!(
        String::from_utf8(empty.stdout)
            .unwrap()
            .contains("(no config files found)")
    );

    let store = zc::store::Store::open(home.join(".config/zc")).unwrap();
    let bundle =
        zc::store::Bundle::from_memory(b"rules: ['MATCH,REJECT']\n", None, Default::default())
            .unwrap();
    // A display filename is not necessarily unique or usable as a selector.
    for (id, active) in [("BlWdYKsc", true), ("another-id", false)] {
        store
            .publish(
                &store.load().unwrap().token,
                id,
                None,
                &bundle,
                zc::store::Metadata {
                    filename: Some("Flower_SS.yaml".into()),
                    ..Default::default()
                },
                active,
            )
            .unwrap();
    }
    let before = store.load().unwrap().token;
    for command in ["list", "ls"] {
        let output = run(home, &["config", command]);
        assert!(output.status.success());
        let text = String::from_utf8(output.stdout).unwrap();
        assert!(text.contains("  * Flower_SS.yaml (ID: BlWdYKsc)"), "{text}");
        assert!(
            text.contains("    Flower_SS.yaml (ID: another-id)"),
            "{text}"
        );
    }
    let listed = ok(home, &["config", "list", "--json"]);
    assert_eq!(
        listed["data"]["configs"],
        json!([
            {"name": "BlWdYKsc", "display": "Flower_SS.yaml", "active": true},
            {"name": "another-id", "display": "Flower_SS.yaml", "active": false}
        ])
    );
    assert_eq!(store.load().unwrap().token, before);
    ok(home, &["config", "use", "another-id", "--json"]);
    assert_eq!(
        ok(home, &["config", "list", "--json"])["data"]["active"],
        "another-id"
    );
}

#[test]
fn config_collection_limits_keep_the_command_error_without_publishing() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("limit.yaml");
    let cases = [
        format!(
            "extension: [{}]\nrules: ['MATCH,DIRECT']\n",
            vec!["0"; 262_144].join(",")
        ),
        format!(
            "proxy-groups: [{}]\nrules: ['MATCH,DIRECT']\n",
            vec!["{name: Pick, type: select, proxies: [DIRECT]}"; 1025].join(",")
        ),
        format!(
            "proxy-groups: [{{name: Pick, type: select, proxies: [{}]}}]\nrules: ['MATCH,DIRECT']\n",
            vec!["DIRECT"; 5123].join(",")
        ),
    ];
    for contents in cases {
        std::fs::write(&source, contents).unwrap();
        let out = run(
            dir.path(),
            &["config", "load", source.to_str().unwrap(), "--json"],
        );
        assert_eq!(out.status.code(), Some(1));
        let result: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(
            result["error"]["code"], "CONFIG_LOAD_LIMIT_EXCEEDED",
            "{result}"
        );
        assert!(!dir.path().join(".config/zc/state-v2.json").exists());
        assert!(!dir.path().join(".config/zc/profiles").exists());
    }
}

#[test]
fn stopped_status_keeps_the_explicit_null_port_contract() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let status = ok(dir.path(), &["status", "--json"]);
    assert_eq!(status["data"]["state"], "stopped");
    assert_eq!(status["data"].get("mixed_port"), Some(&Value::Null));
    assert!(!dir.path().join(".config/zc").exists());
}

#[test]
fn usage_errors_share_json_codes_and_never_create_state() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    for (args, code) in [
        (vec!["restart", "--port", "--json"], "START_PORT_REQUIRED"),
        (
            vec!["restart", "--foreground", "--json"],
            "START_ARGS_INVALID",
        ),
        (vec!["stop", "extra", "--json"], "STOP_ARGUMENT_INVALID"),
        (
            vec!["status", "-c", "file", "--json"],
            "STATUS_ARGUMENT_INVALID",
        ),
        (
            vec!["config", "download", "--json"],
            "CONFIG_DOWNLOAD_URL_REQUIRED",
        ),
        (
            vec!["config", "update", "--apply", "bad", "--json"],
            "CONFIG_UPDATE_APPLY_INVALID",
        ),
        (
            vec!["profile", "list", "--bad", "--json"],
            "PROFILE_LIST_ARGUMENT_INVALID",
        ),
        (vec!["diag", "--json"], "DIAG_SUBCOMMAND_MISSING"),
        (vec!["help", "unknown", "--json"], "HELP_TOPIC_UNKNOWN"),
        (
            vec!["start", "--override-timeout-ms", "0", "--json"],
            "OVERRIDE_SCRIPT_TIMEOUT",
        ),
        (
            vec!["config", "dump", "--override-dump-yaml", "--json"],
            "OVERRIDE_OPTION_DEPRECATED",
        ),
    ] {
        let out = run(home, &args);
        assert_eq!(
            out.status.code(),
            Some(2),
            "{args:?}: {}",
            String::from_utf8_lossy(&out.stdout)
        );
        let value: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(value["error"]["code"], code, "{args:?}");
        assert!(out.stderr.is_empty());
    }
    let output = run(
        home,
        &[
            "config",
            "download",
            "http://127.0.0.1:1/?private-token",
            "-n",
            "../bad",
            "--json",
        ],
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
        "CONFIG_NAME_INVALID"
    );
    assert!(!String::from_utf8_lossy(&output.stdout).contains("private-token"));
    assert!(!home.join(".config").exists());
}

struct HttpSource {
    url: String,
    body: std::sync::Arc<std::sync::Mutex<Vec<u8>>>,
    stopped: std::sync::Arc<std::sync::atomic::AtomicBool>,
    worker: Option<std::thread::JoinHandle<()>>,
}
impl HttpSource {
    fn new(body: &[u8]) -> Self {
        use std::{
            io::{Read, Write},
            sync::{
                Arc, Mutex,
                atomic::{AtomicBool, Ordering},
            },
        };
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = format!(
            "http://{}/subscription?private-token",
            listener.local_addr().unwrap()
        );
        listener.set_nonblocking(true).unwrap();
        let body = Arc::new(Mutex::new(body.to_vec()));
        let copy = body.clone();
        let stopped = Arc::new(AtomicBool::new(false));
        let stop = stopped.clone();
        let worker = std::thread::spawn(move || {
            while !stop.load(Ordering::Acquire) {
                if let Ok((mut stream, _)) = listener.accept() {
                    // BSD accept inherits O_NONBLOCK; the bounded fixture reader is blocking.
                    stream.set_nonblocking(false).unwrap();
                    stream
                        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
                        .unwrap();
                    let mut request = Vec::new();
                    let mut byte = [0];
                    while !request.ends_with(b"\r\n\r\n") && request.len() < 16384 {
                        if stream.read_exact(&mut byte).is_err() {
                            break;
                        }
                        request.push(byte[0]);
                    }
                    if !request.ends_with(b"\r\n\r\n") {
                        continue;
                    }
                    let bytes = copy.lock().unwrap().clone();
                    let _ = write!(
                        stream,
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                        bytes.len()
                    );
                    let _ = stream.write_all(&bytes);
                } else {
                    std::thread::sleep(std::time::Duration::from_millis(5));
                }
            }
        });
        Self {
            url,
            body,
            stopped,
            worker: Some(worker),
        }
    }
}
impl Drop for HttpSource {
    fn drop(&mut self) {
        self.stopped
            .store(true, std::sync::atomic::Ordering::Release);
        self.worker.take().unwrap().join().unwrap();
    }
}

#[test]
fn subscription_fixture_waits_for_a_complete_request_after_accept() {
    let _serial = cli_fixture::serial();
    use std::io::{Read, Write};
    let fixture = HttpSource::new(b"verified-body");
    let address = fixture
        .url
        .strip_prefix("http://")
        .unwrap()
        .split('/')
        .next()
        .unwrap();
    let mut socket = std::net::TcpStream::connect(address).unwrap();
    socket
        .set_read_timeout(Some(std::time::Duration::from_millis(50)))
        .unwrap();
    let mut byte = [0];
    assert!(
        socket.peek(&mut byte).is_err(),
        "response arrived before any request"
    );
    socket
        .write_all(b"GET / HTTP/1.1\r\nHost: local\r\n")
        .unwrap();
    assert!(
        socket.peek(&mut byte).is_err(),
        "response arrived before the header boundary"
    );
    socket.write_all(b"\r\n").unwrap();
    socket
        .set_read_timeout(Some(std::time::Duration::from_secs(2)))
        .unwrap();
    let mut response = Vec::new();
    socket.read_to_end(&mut response).unwrap();
    assert!(response.starts_with(b"HTTP/1.1 200 OK\r\n"));
    assert!(response.ends_with(b"verified-body"));
}

#[test]
fn downloaded_config_and_lua_override_are_frozen_and_update_retains_exact_source() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let http = HttpSource::new(
        b"# original source\nmixed-port: 23456\nmode: rule\nrules: ['MATCH,DIRECT']\n",
    );
    let downloaded = ok(
        home,
        &[
            "config",
            "download",
            &http.url,
            "-n",
            "subscription.yaml",
            "--json",
        ],
    );
    assert_eq!(downloaded["data"]["active"], true);
    assert!(
        !String::from_utf8_lossy(&run(home, &["config", "list", "--json"]).stdout)
            .contains("private-token")
    );
    let script = home.join("override.lua");
    std::fs::write(
        &script,
        "assert(input.command == 'config.override'); return {mode = 'direct'}",
    )
    .unwrap();
    let result = ok(
        home,
        &["config", "override", script.to_str().unwrap(), "--json"],
    );
    assert_eq!(result["data"]["enabled"], true);
    std::fs::remove_file(script).unwrap();
    assert_eq!(ok(home, &["config", "dump", "--json"])["mode"], "direct");
    assert_eq!(
        ok(home, &["config", "dump", "--no-override", "--json"])["mode"],
        "rule"
    );
    *http.body.lock().unwrap() =
        b"# updated source\nmixed-port: 23457\nmode: global\nrules: ['MATCH,REJECT']\n".to_vec();
    assert_eq!(
        ok(home, &["config", "update", "--json"])["data"]["applied"],
        false
    );
    let updated = ok(home, &["config", "dump", "--json"]);
    assert_eq!(updated["mode"], "direct");
    assert_eq!(updated["rules"], json!(["MATCH,REJECT"]));
    ok(home, &["config", "override", "--clear", "--json"]);
    assert_eq!(ok(home, &["config", "dump", "--json"])["mode"], "global");
}

#[test]
fn malformed_obfs_recovery_is_inactive_and_dump_preserves_raw_bytes() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let source=b"# raw recovery\nproxies: [{name: edge, type: ss, server: localhost, port: 443, password: secret, cipher: aes-128-gcm, plugin: obfs, plugin-opts: {mode: tls, host: example.com}}]\nrules: ['MATCH,edge']\n";
    let http = HttpSource::new(source);
    let rejected = run(
        home,
        &["config", "download", &http.url, "-n", "bad", "-d", "--json"],
    );
    assert_eq!(
        serde_json::from_slice::<Value>(&rejected.stdout).unwrap()["error"]["code"],
        "CONFIG_CAPABILITY_UNSUPPORTED"
    );
    assert!(!home.join(".config/zc/state-v2.json").exists());
    let saved = ok(
        home,
        &["config", "download", &http.url, "-n", "bad", "--json"],
    );
    assert_eq!(saved["data"]["active"], false);
    assert_eq!(
        run(home, &["config", "dump", "-c", "bad", "--no-override"]).stdout,
        source
    );
    let rejected = run(home, &["config", "use", "bad", "--json"]);
    assert_eq!(
        serde_json::from_slice::<Value>(&rejected.stdout).unwrap()["error"]["code"],
        "CONFIG_CAPABILITY_UNSUPPORTED"
    );
    *http.body.lock().unwrap() = b"rules: ['MATCH,DIRECT']\n".to_vec();
    ok(home, &["config", "update", "bad", "--json"]);
    assert!(
        ok(home, &["config", "list", "--json"])["data"]
            .get("active")
            .is_none()
    );
    ok(home, &["config", "use", "bad", "--json"]);
}

#[test]
fn lua_worker_runtime_options_and_ascii_output_do_not_mutate_managed_state() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let source = home.join("source.yaml");
    let script = home.join("script.lua");
    std::fs::write(&source,"secret: top-secret\nproxy-groups: [{name: 日本, type: select, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,日本']\n").unwrap();
    std::fs::write(&script, "return { mode = input.args.mode }").unwrap();
    let out = run(
        home,
        &[
            "config",
            "dump",
            "-c",
            source.to_str().unwrap(),
            "--override-script",
            script.to_str().unwrap(),
            "--override-arg",
            "mode=direct",
            "--json",
        ],
    );
    assert!(
        out.status.success(),
        "{}",
        String::from_utf8_lossy(&out.stdout)
    );
    assert!(out.stdout.is_ascii());
    assert!(!String::from_utf8_lossy(&out.stdout).contains("top-secret"));
    assert_eq!(
        serde_json::from_slice::<Value>(&out.stdout).unwrap()["mode"],
        "direct"
    );
    assert!(!home.join(".config/zc").exists());
}

struct DaemonGuard(std::path::PathBuf);
impl Drop for DaemonGuard {
    fn drop(&mut self) {
        let _ = run(&self.0, &["stop", "--json"]);
    }
}
fn free_port() -> u16 {
    let p = std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    assert_ne!(p, 7899);
    p
}

#[test]
fn managed_subscription_compatibility_fields_do_not_block_start() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let source = home.join("subscription.yaml");
    let contents = json!({
        "dns": {"enable": true, "enhanced-mode": "fake-ip", "nameserver": ["192.0.2.1"]},
        "hosts": {"example.com": "192.0.2.2"},
        "sniffer": {"enable": true},
        "profile": {"store-selected": true, "store-fake-ip": true},
        "experimental": {"ignore-resolve-fail": true},
        "unified-delay": true,
        "clash-for-android": {"append-system-dns": false},
        "proxies": [{"name": "edge", "type": "ss", "server": "localhost", "port": 443,
            "cipher": "aes-128-gcm", "password": "fixture", "plugin": "obfs",
            "plugin-opts": {"mode": "http", "host": "example.com"}}],
        "proxy-groups": [{"name": "Pick", "type": "select", "proxies": ["REJECT", "edge"]}],
        "rules": ["MATCH,Pick"]
    })
    .to_string();
    std::fs::write(&source, &contents).unwrap();
    ok(
        home,
        &["config", "load", source.to_str().unwrap(), "--json"],
    );
    assert_eq!(std::fs::read_to_string(&source).unwrap(), contents);
    // The immutable source retains ignored fields rather than rewriting the subscription.
    let store = zc::store::Store::open(home.join(".config/zc")).unwrap();
    let active = store.load().unwrap().catalog.active.unwrap();
    let view = store.read_bundle(&active.key, &active.revision).unwrap();
    assert_eq!(view.bundle.source(), contents.as_bytes());
    std::fs::remove_file(source).unwrap();
    let port = free_port();
    ok(home, &["start", "--port", &port.to_string(), "--json"]);
    let status = ok(home, &["status", "--json"]);
    assert_eq!(status["data"]["state"], "running");
    assert_eq!(status["data"]["mixed_port"], port);
    assert_eq!(
        ok(home, &["proxy", "list", "--json"])["data"]["groups"][0]["now"],
        "REJECT"
    );
    assert_eq!(
        store
            .read_bundle(&active.key, &active.revision)
            .unwrap()
            .bundle
            .source(),
        contents.as_bytes()
    );
}

#[test]
fn managed_live_selection_reload_and_immutable_local_provider_work_end_to_end() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let proxy = free_port();
    let controller = free_port();
    let source = home.join("managed.yaml");
    let rules = home.join("rules.yaml");
    std::fs::write(&rules, "payload: ['+.example.com']\n").unwrap();
    std::fs::write(&source,format!("mixed-port: 23456\nexternal-controller: 127.0.0.1:{controller}\nsecret: control-secret\nproxy-groups: [{{name: Pick, type: select, proxies: [DIRECT, REJECT]}}]\nrule-providers: {{local: {{type: file, behavior: domain, path: rules.yaml}}}}\nrules: ['RULE-SET,local,Pick', 'MATCH,Pick']\n")).unwrap();
    ok(
        home,
        &["config", "load", source.to_str().unwrap(), "--json"],
    );
    std::fs::remove_file(source).unwrap();
    std::fs::remove_file(rules).unwrap();
    ok(home, &["start", "--port", &proxy.to_string(), "--json"]);
    let selected = ok(
        home,
        &["proxy", "select", "-g", "Pick", "-p", "REJECT", "--json"],
    );
    assert_eq!(selected["data"]["applied"], true);
    let status = ok(home, &["status", "--json"]);
    assert_eq!(status["data"]["mixed_port"], proxy);
    assert_eq!(status["data"]["selected_proxies"][0]["proxy"], "REJECT");
    ok(home, &["reload", "--json"]);
    assert_eq!(ok(home, &["status", "--json"])["data"]["mixed_port"], proxy);
    let log = run(home, &["log", "--json", "-n", "1"]);
    assert!(log.status.success());
    assert!(
        serde_json::from_slice::<Value>(&log.stdout)
            .unwrap()
            .get("line")
            .is_some()
    );
    ok(home, &["stop", "--json"]);
    assert_eq!(ok(home, &["status", "--json"])["data"]["state"], "stopped");
}

#[test]
fn reload_prepares_the_tracked_source_before_replacing_the_live_instance() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let source = home.join("reload.yaml");
    let controller = free_port();
    std::fs::write(
        &source,
        format!("external-controller: 127.0.0.1:{controller}\nrules: ['MATCH,DIRECT']\n"),
    )
    .unwrap();
    ok(
        home,
        &[
            "start",
            "-c",
            source.to_str().unwrap(),
            "--port",
            &free_port().to_string(),
            "--json",
        ],
    );
    let previous = ok(home, &["status", "--json"])["data"]["pid"].clone();
    std::fs::write(&source, "rules: ['MATCH,missing']\n").unwrap();
    let failed = run(home, &["reload", "--json"]);
    assert_eq!(
        failed.status.code(),
        Some(1),
        "{}",
        String::from_utf8_lossy(&failed.stdout)
    );
    assert_eq!(ok(home, &["status", "--json"])["data"]["pid"], previous);
    std::fs::write(&source, format!("external-controller: 127.0.0.1:{controller}\nproxy-groups: [{{name: New, type: select, proxies: [REJECT, DIRECT]}}]\nrules: ['MATCH,New']\n")).unwrap();
    ok(home, &["reload", "--json"]);
    let current = ok(home, &["status", "--json"]);
    assert_ne!(current["data"]["pid"], previous);
    assert_eq!(current["data"]["selected_proxies"][0]["proxy"], "REJECT");
}

#[test]
fn diagnostics_fail_closed_on_closed_proxy_port_and_invalid_config() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let source = home.join("good.yaml");
    std::fs::write(&source, "rules: ['MATCH,DIRECT']").unwrap();
    let port = free_port().to_string();
    for command in [vec!["test"], vec!["proxy", "test"], vec!["profile", "test"]] {
        let mut args = command;
        args.extend(["-c", source.to_str().unwrap(), "--port", &port, "--json"]);
        let out = run(home, &args);
        assert_eq!(out.status.code(), Some(1));
        let value: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(value["error"]["code"], "CHECKS_FAILED");
        assert_eq!(value["data"]["ports"][0]["listening"], false);
    }
    ok(
        home,
        &[
            "start",
            "-c",
            source.to_str().unwrap(),
            "--port",
            &free_port().to_string(),
            "--json",
        ],
    );
    let doctor = ok(home, &["doctor", "-c", source.to_str().unwrap(), "--json"]);
    assert_eq!(doctor["data"]["config_ok"], true);
    assert_eq!(doctor["data"]["checks"].as_array().unwrap().len(), 2);
    std::fs::write(&source, "rules: ['MATCH,missing']").unwrap();
    let out = run(
        home,
        &["diag", "doctor", "-c", source.to_str().unwrap(), "--json"],
    );
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(
        serde_json::from_slice::<Value>(&out.stdout).unwrap()["error"]["code"],
        "CHECKS_FAILED"
    );
}

#[test]
fn remote_provider_bytes_are_resolved_before_start_and_frozen_for_daemon() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let provider = HttpSource::new(b"payload: ['+.example.com']\n");
    let source = home.join("remote.yaml");
    std::fs::write(&source,format!("rule-providers: {{remote: {{type: http, behavior: domain, path: remote-cache.yaml, url: '{}'}}}}\nrules: ['RULE-SET,remote,REJECT', 'MATCH,DIRECT']\n",provider.url)).unwrap();
    // Zig's offline catalog gate rejects referenced remote providers; unmanaged
    // runtime preparation must fetch and freeze them instead of empty substitution.
    let rejected = run(
        home,
        &["config", "load", source.to_str().unwrap(), "--json"],
    );
    assert_eq!(rejected.status.code(), Some(1));
    assert!(!home.join(".config/zc/state-v2.json").exists());
    ok(
        home,
        &[
            "start",
            "-c",
            source.to_str().unwrap(),
            "--port",
            &free_port().to_string(),
            "--json",
        ],
    );
    std::fs::remove_file(source).unwrap();
    drop(provider);
    ok(home, &["restart", "--json"]);
    assert_eq!(ok(home, &["status", "--json"])["data"]["state"], "running");
    ok(home, &["stop", "--json"]);
}

#[test]
fn mirror_corruption_is_advisory_but_truthfully_reported_and_catalog_corruption_fails_closed() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let source = home.join("one.yaml");
    std::fs::write(&source, "rules: ['MATCH,DIRECT']\n").unwrap();
    let loaded = ok(
        home,
        &["config", "load", source.to_str().unwrap(), "--json"],
    );
    assert_eq!(loaded["data"]["mirror_out_of_sync"], false);
    std::fs::write(home.join(".config/zc/configs/one.yaml"), "broken mirror").unwrap();
    assert_eq!(
        ok(home, &["config", "list", "--json"])["data"]["mirror_out_of_sync"],
        true
    );
    assert_eq!(
        ok(home, &["config", "dump", "--json"])["rules"],
        json!(["MATCH,DIRECT"])
    );
    let catalog = home.join(".config/zc/state-v2.json");
    std::fs::write(&catalog, b"invalid catalog").unwrap();
    let out = run(home, &["config", "list", "--json"]);
    assert_eq!(out.status.code(), Some(1));
    assert_eq!(std::fs::read(catalog).unwrap(), b"invalid catalog");
}

#[test]
fn stale_selection_is_reconciled_before_next_listener_opens() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let controller = free_port();
    let http=HttpSource::new(format!("external-controller: 127.0.0.1:{controller}\nproxy-groups: [{{name: Pick, type: select, proxies: [DIRECT, REJECT]}}]\nrules: ['MATCH,Pick']\n").as_bytes());
    ok(
        home,
        &["config", "download", &http.url, "-n", "nodes", "--json"],
    );
    ok(
        home,
        &["proxy", "select", "-g", "Pick", "-p", "REJECT", "--json"],
    );
    *http.body.lock().unwrap()=format!("external-controller: 127.0.0.1:{controller}\nproxy-groups: [{{name: Pick, type: select, proxies: [DIRECT]}}]\nrules: ['MATCH,Pick']\n").into_bytes();
    ok(home, &["config", "update", "nodes", "--json"]);
    ok(
        home,
        &["start", "--port", &free_port().to_string(), "--json"],
    );
    assert_eq!(
        ok(home, &["status", "--json"])["data"]["selected_proxies"][0]["proxy"],
        "DIRECT"
    );
}

#[test]
fn load_semantic_diagnostics_are_bounded_and_parse_failures_do_not_fake_them() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let source = home.join("invalid.yaml");
    std::fs::write(&source, "rules: ['MATCH,missing']\n").unwrap();
    let out = run(
        home,
        &["config", "load", source.to_str().unwrap(), "--json"],
    );
    let value: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(value["error"]["code"], "CONFIG_LOAD_INVALID");
    assert!(
        !value["data"]["config_errors"]
            .as_array()
            .unwrap()
            .is_empty()
    );
    std::fs::write(&source, "password: SECRET_SOURCE\nbroken: [").unwrap();
    let out = run(
        home,
        &["config", "load", source.to_str().unwrap(), "--json"],
    );
    let value: Value = serde_json::from_slice(&out.stdout).unwrap();
    assert_eq!(value["error"]["code"], "CONFIG_LOAD_INVALID");
    assert!(value.get("data").is_none());
    assert!(!String::from_utf8_lossy(&out.stdout).contains("SECRET_SOURCE"));
}

#[test]
fn already_running_start_does_not_require_a_managed_active_config() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let source = home.join("explicit.yaml");
    std::fs::write(&source, "rules: ['MATCH,DIRECT']").unwrap();
    ok(
        home,
        &[
            "start",
            "-c",
            source.to_str().unwrap(),
            "--port",
            &free_port().to_string(),
            "--json",
        ],
    );
    assert_eq!(
        ok(home, &["up", "--json"])["data"]["detail"],
        "already_running"
    );
    assert!(!home.join(".config/zc").exists());
}

#[test]
fn update_commits_only_against_the_subscription_head_captured_before_download() {
    let _serial = cli_fixture::serial();
    use std::{
        io::{Read, Write},
        sync::mpsc,
        time::Duration,
    };
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let url = format!("http://{}/subscription", listener.local_addr().unwrap());
    let (ready_tx, ready_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let server = std::thread::spawn(move || {
        for round in 0..2 {
            let (mut stream, _) = listener.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut request = Vec::new();
            let mut byte = [0];
            while !request.ends_with(b"\r\n\r\n") {
                stream.read_exact(&mut byte).unwrap();
                request.push(byte[0]);
            }
            if round == 1 {
                ready_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(10)).unwrap();
            }
            let body = b"mode: rule\nrules: ['MATCH,DIRECT']\n";
            write!(
                stream,
                "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                body.len()
            )
            .unwrap();
            stream.write_all(body).unwrap();
        }
    });
    ok(
        home,
        &["config", "download", &url, "-n", "subscription", "--json"],
    );
    let home_copy = home.to_owned();
    let update = std::thread::spawn(move || {
        run(&home_copy, &["config", "update", "subscription", "--json"])
    });
    ready_rx.recv_timeout(Duration::from_secs(5)).unwrap();
    let script = home.join("replace.lua");
    std::fs::write(&script, "return {mode = 'direct'}").unwrap();
    ok(
        home,
        &["config", "override", script.to_str().unwrap(), "--json"],
    );
    let catalog = std::fs::read(home.join(".config/zc/state-v2.json")).unwrap();
    release_tx.send(()).unwrap();
    let output = update.join().unwrap();
    server.join().unwrap();
    assert_eq!(output.status.code(), Some(1));
    assert_eq!(
        serde_json::from_slice::<Value>(&output.stdout).unwrap()["error"]["code"],
        "CONFIG_UPDATE_CONFLICT"
    );
    assert_eq!(
        std::fs::read(home.join(".config/zc/state-v2.json")).unwrap(),
        catalog
    );
    assert_eq!(ok(home, &["config", "dump", "--json"])["mode"], "direct");
}

#[test]
fn update_applies_to_matching_managed_daemon_but_not_an_unmanaged_instance() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let http = HttpSource::new(b"mode: rule\nrules: ['MATCH,DIRECT']\n");
    ok(
        home,
        &["config", "download", &http.url, "-n", "remote", "--json"],
    );
    let port = free_port().to_string();
    ok(home, &["start", "--port", &port, "--json"]);
    let before = ok(home, &["status", "--json"])["data"]["pid"].clone();
    *http.body.lock().unwrap() = b"mode: direct\nrules: ['MATCH,DIRECT']\n".to_vec();
    let update = ok(home, &["config", "update", "remote", "--json"]);
    assert_eq!(update["data"]["applied"], true);
    assert_eq!(update["data"]["apply_result"], "restart_fallback");
    let after = ok(home, &["status", "--json"]);
    assert_ne!(after["data"]["pid"], before);
    assert_eq!(after["data"]["mixed_port"], port.parse::<u16>().unwrap());
    ok(home, &["stop", "--json"]);
    let explicit = home.join("explicit.yaml");
    std::fs::write(&explicit, "rules: ['MATCH,DIRECT']\n").unwrap();
    ok(
        home,
        &[
            "start",
            "-c",
            explicit.to_str().unwrap(),
            "--port",
            &port,
            "--json",
        ],
    );
    let before = ok(home, &["status", "--json"])["data"]["pid"].clone();
    *http.body.lock().unwrap() = b"mode: global\nrules: ['MATCH,DIRECT']\n".to_vec();
    assert_eq!(
        ok(home, &["config", "update", "remote", "--json"])["data"]["applied"],
        false
    );
    assert_eq!(ok(home, &["status", "--json"])["data"]["pid"], before);
}

#[test]
fn selection_persists_when_the_runtime_descriptor_is_corrupt() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let source = home.join("nodes.yaml");
    std::fs::write(&source,"proxy-groups: [{name: Pick, type: select, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,Pick']\n").unwrap();
    ok(
        home,
        &["config", "load", source.to_str().unwrap(), "--json"],
    );
    let runtime = home.join(".local/state/zc/runtime");
    std::fs::create_dir_all(&runtime).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&runtime, std::fs::Permissions::from_mode(0o700)).unwrap();
    std::fs::write(runtime.join("zc.daemon.json"), b"corrupt").unwrap();
    std::fs::set_permissions(
        runtime.join("zc.daemon.json"),
        std::fs::Permissions::from_mode(0o600),
    )
    .unwrap();
    let selected = ok(
        home,
        &["proxy", "select", "-g", "Pick", "-p", "REJECT", "--json"],
    );
    assert_eq!(selected["data"]["applied"], false);
    assert_eq!(
        ok(home, &["proxy", "list", "--json"])["data"]["groups"][0]["now"],
        "REJECT"
    );
}

#[test]
fn unexpected_mirror_files_are_reported_without_becoming_authoritative() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let source = home.join("one.yaml");
    std::fs::write(&source, "rules: ['MATCH,DIRECT']\n").unwrap();
    ok(
        home,
        &["config", "load", source.to_str().unwrap(), "--json"],
    );
    std::fs::write(
        home.join(".config/zc/configs/untracked.yaml"),
        "rules: ['MATCH,REJECT']\n",
    )
    .unwrap();
    let list = ok(home, &["config", "list", "--json"]);
    assert_eq!(list["data"]["configs"].as_array().unwrap().len(), 1);
    assert_eq!(list["data"]["mirror_out_of_sync"], true);
}

#[test]
fn dump_rejects_semantically_invalid_one_shot_override_without_publishing_state() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let source = home.join("source.yaml");
    let script = home.join("invalid.lua");
    std::fs::write(&source, "rules: ['MATCH,DIRECT']\n").unwrap();
    std::fs::write(&script, "return {mode = 'invalid'}").unwrap();
    let out = run(
        home,
        &[
            "config",
            "dump",
            "-c",
            source.to_str().unwrap(),
            "--override-script",
            script.to_str().unwrap(),
            "--json",
        ],
    );
    assert_eq!(out.status.code(), Some(1));
    assert!(
        !serde_json::from_slice::<Value>(&out.stdout).unwrap()["ok"]
            .as_bool()
            .unwrap()
    );
    assert!(!home.join(".config/zc").exists());
}

#[test]
fn all_http_provider_wire_bytes_are_frozen_before_any_listener_opens() {
    let _serial = cli_fixture::serial();
    use std::{
        io::{Read, Write},
        net::{TcpListener, TcpStream},
        sync::mpsc,
        time::Duration,
    };
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let source = home.join("source.yaml");
    let server = TcpListener::bind("127.0.0.1:0").unwrap();
    let address = server.local_addr().unwrap();
    let source_bytes = format!(
        "rule-providers: {{a: {{type: http, behavior: domain, path: a.cache, url: 'http://{address}/a'}}, b: {{type: http, behavior: domain, path: b.cache, url: 'http://{address}/b'}}}}\nrules: ['RULE-SET,a,REJECT', 'RULE-SET,b,REJECT', 'MATCH,DIRECT']\n"
    );
    std::fs::write(&source, &source_bytes).unwrap();
    let (ready_tx, ready_rx) = mpsc::channel();
    let (release_tx, release_rx) = mpsc::channel();
    let peer = std::thread::spawn(move || {
        for index in 0..2 {
            let (mut stream, _) = server.accept().unwrap();
            stream
                .set_read_timeout(Some(Duration::from_secs(5)))
                .unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let mut byte = [0];
                stream.read_exact(&mut byte).unwrap();
                request.push(byte[0]);
                assert!(request.len() <= 16 * 1024);
            }
            stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\n")
                .unwrap();
            if index == 1 {
                stream.write_all(b"new.").unwrap();
                ready_tx.send(()).unwrap();
                release_rx.recv_timeout(Duration::from_secs(10)).unwrap();
                stream.write_all(b"example\n").unwrap();
            } else {
                stream.write_all(b"new.example\n").unwrap();
            }
        }
    });
    let port = free_port();
    let child_home = home.to_path_buf();
    let child_source = source.clone();
    let start = std::thread::spawn(move || {
        run(
            &child_home,
            &[
                "start",
                "-c",
                child_source.to_str().unwrap(),
                "--port",
                &port.to_string(),
                "--json",
            ],
        )
    });
    ready_rx.recv_timeout(Duration::from_secs(10)).unwrap();
    assert!(
        TcpStream::connect_timeout(&([127, 0, 0, 1], port).into(), Duration::from_millis(100))
            .is_err()
    );
    assert!(!start.is_finished());
    release_tx.send(()).unwrap();
    peer.join().unwrap();
    let result = start.join().unwrap();
    assert!(
        result.status.success(),
        "{}",
        String::from_utf8_lossy(&result.stdout)
    );
    assert_eq!(std::fs::read_to_string(&source).unwrap(), source_bytes);
    assert_eq!(
        std::fs::read(home.join("a.cache")).unwrap(),
        b"new.example\n"
    );
    assert_eq!(
        std::fs::read(home.join("b.cache")).unwrap(),
        b"new.example\n"
    );
    std::fs::remove_file(source).unwrap();
    std::fs::write(home.join("a.cache"), b"broken: [").unwrap();
    std::fs::remove_file(home.join("b.cache")).unwrap();
    ok(home, &["restart", "--json"]);
    assert_eq!(ok(home, &["status", "--json"])["data"]["state"], "running");
}

#[test]
fn absent_empty_and_unmatched_rules_reject_real_requests_like_strict_zig() {
    let _serial = cli_fixture::serial();
    use std::{
        io::{Read, Write},
        net::TcpStream,
        time::Duration,
    };
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let origin = HttpSource::new(b"ORIGIN_REACHED");
    let source = home.join("rules.yaml");
    for (contents, allowed) in [
        ("mode: rule\n", false),
        ("rules: []\n", false),
        ("rules: ['DOMAIN,only.example,DIRECT']\n", false),
        ("rules: ['MATCH,DIRECT']\n", true),
    ] {
        std::fs::write(&source, contents).unwrap();
        let port = free_port();
        ok(
            home,
            &[
                "start",
                "-c",
                source.to_str().unwrap(),
                "--port",
                &port.to_string(),
                "--json",
            ],
        );
        let mut stream = TcpStream::connect(("127.0.0.1", port)).unwrap();
        stream
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        write!(
            stream,
            "GET {} HTTP/1.1\r\nHost: {}\r\nConnection: close\r\n\r\n",
            origin.url,
            origin
                .url
                .strip_prefix("http://")
                .unwrap()
                .split('/')
                .next()
                .unwrap()
        )
        .unwrap();
        let mut response = String::new();
        stream.read_to_string(&mut response).unwrap();
        assert_eq!(
            response.contains("ORIGIN_REACHED"),
            allowed,
            "{contents}: {response}"
        );
        assert!(
            response.starts_with(if allowed {
                "HTTP/1.1 200"
            } else {
                "HTTP/1.1 502"
            }),
            "{response}"
        );
        ok(home, &["stop", "--json"]);
    }
}

#[test]
fn managed_one_shot_deferred_providers_still_require_valid_declarations() {
    let _serial = cli_fixture::serial();
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    let _guard = DaemonGuard(home.into());
    let source = home.join("source.yaml");
    std::fs::write(&source, "rules: ['MATCH,REJECT']\n").unwrap();
    ok(
        home,
        &["config", "load", source.to_str().unwrap(), "--json"],
    );
    let script = home.join("bad.lua");
    std::fs::write(
        &script,
        "return {['rule-providers']={unused={type='http',behavior='domain',path='cache'}}}",
    )
    .unwrap();
    let result = run(
        home,
        &[
            "start",
            "--port",
            &free_port().to_string(),
            "--override-script",
            script.to_str().unwrap(),
            "--json",
        ],
    );
    assert_eq!(result.status.code(), Some(1));
    assert_eq!(ok(home, &["status", "--json"])["data"]["state"], "stopped");
    assert!(!home.join("cache").exists());
}

#[test]
fn offline_preparation_does_not_open_unneeded_tls_roots() {
    let _serial = cli_fixture::serial();
    use std::time::{Duration, Instant};
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let fifo = home.join("unused-cert.pem");
    assert!(
        Command::new("mkfifo")
            .arg(&fifo)
            .status()
            .unwrap()
            .success()
    );
    let source = home.join("source.yaml");
    std::fs::write(home.join("cached"), b"example.com\n").unwrap();
    for text in [
        "rules: ['MATCH,DIRECT']\n",
        "rule-providers: {list: {type: http, behavior: domain, path: cached, url: 'http://127.0.0.1:1/'}}\nrules: ['RULE-SET,list,DIRECT']\n",
    ] {
        std::fs::write(&source, text).unwrap();
        let mut child = Command::new(env!("CARGO_BIN_EXE_zc"))
            .args([
                "test",
                "-c",
                source.to_str().unwrap(),
                "--port",
                &free_port().to_string(),
                "--json",
            ])
            .env("HOME", &home)
            .env_remove("XDG_RUNTIME_DIR")
            .env("SSL_CERT_FILE", &fifo)
            .env("SSL_CERT_DIR", home.join("absent-certs"))
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        let start = Instant::now();
        loop {
            if child.try_wait().unwrap().is_some() {
                break;
            }
            if start.elapsed() > Duration::from_secs(5) {
                child.kill().unwrap();
                child.wait().unwrap();
                panic!("offline preparation blocked opening the TLS roots FIFO");
            }
            std::thread::sleep(Duration::from_millis(10));
        }
        let output = child.wait_with_output().unwrap();
        let data: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(data["error"]["code"], "CHECKS_FAILED", "{data}");
        assert_eq!(data["data"]["ports"][0]["listening"], false);
    }
}
