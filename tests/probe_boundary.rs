//! An external control/mixed boundary, using CLI-authenticated fixture snapshots.
//! It never forwards or resolves the public URLs received from `zc test`.
use serde_json::{Value, json};
use std::{
    io::{BufRead, Write},
    process::{Command, Stdio},
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
};
use zc::connection::{INSTANCE_HEADER, PROBE_HEADER};

async fn request(stream: &mut TcpStream) -> (String, Value) {
    let mut bytes = Vec::new();
    while !bytes.ends_with(b"\r\n\r\n") {
        bytes.push(stream.read_u8().await.unwrap());
        assert!(bytes.len() < 16384);
    }
    let header = String::from_utf8(bytes).unwrap();
    let length = header
        .lines()
        .filter_map(|l| l.split_once(':'))
        .find(|(k, _)| k.eq_ignore_ascii_case("content-length"))
        .map(|(_, v)| v.trim().parse::<usize>().unwrap())
        .unwrap_or(0);
    let mut body = vec![0; length];
    stream.read_exact(&mut body).await.unwrap();
    (header, serde_json::from_slice(&body).unwrap_or(Value::Null))
}
async fn response(stream: &mut TcpStream, status: u16, nonce: Option<&str>, body: &Value) {
    let body = body.to_string();
    let instance = nonce
        .map(|n| format!("{INSTANCE_HEADER}: {n}\r\n"))
        .unwrap_or_default();
    let _ = stream.write_all(format!("HTTP/1.1 {status} Response\r\n{instance}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",body.len()).as_bytes()).await;
}

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn probe_controller_boundary_child() {
    let Ok(mode) = std::env::var("ZC_PROBE_BOUNDARY") else {
        return;
    };
    let home = std::path::PathBuf::from(std::env::var_os("HOME").unwrap());
    let dir = zc::fsutil::SecureDir::open(home.join(".local/state/zc/runtime")).unwrap();
    let _lock = dir.lock("zc.lock", Duration::from_secs(1)).unwrap();
    let original = std::fs::read_to_string(home.join("descriptor.fixture")).unwrap();
    let descriptor: Value = serde_json::from_str(&original).unwrap();
    let nonce = descriptor["nonce"].as_str().unwrap().to_owned();
    let api = TcpListener::bind(descriptor["endpoint"].as_str().unwrap())
        .await
        .unwrap();
    let mixed = TcpListener::bind(format!(
        "127.0.0.1:{}",
        std::env::var("ZC_PROBE_MIXED").unwrap()
    ))
    .await
    .unwrap();
    let descriptor = original.replacen(
        &format!("\"pid\":{}", descriptor["pid"]),
        &format!("\"pid\":{}", std::process::id()),
        1,
    );
    let descriptor = if mode == "bad-descriptor" {
        serde_json::from_str::<Value>(&descriptor)
            .unwrap()
            .to_string()
    } else {
        descriptor
    };
    dir.atomic_write("zc.pid", format!("{}\n", std::process::id()).as_bytes())
        .unwrap();
    dir.atomic_write("zc.daemon.json", descriptor.as_bytes())
        .unwrap();
    let control_mode = mode.clone();
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = api.accept().await.unwrap();
            let mode = control_mode.clone();
            let nonce = nonce.clone();
            tokio::spawn(async move {
                let (header, body) = request(&mut socket).await;
                let line = header.lines().next().unwrap();
                if line.starts_with("GET /status ") {
                    response(
                        &mut socket,
                        200,
                        None,
                        &json!({"config_key":null,"selected_proxies":[]}),
                    )
                    .await;
                    return;
                }
                assert!(
                    header
                        .to_lowercase()
                        .contains("authorization: bearer private_fixture_secret")
                );
                assert!(
                    header
                        .to_lowercase()
                        .contains(&format!("{INSTANCE_HEADER}: {nonce}"))
                );
                if line.starts_with("PUT ") {
                    if mode == "auth" {
                        response(&mut socket, 401, None, &json!({"error":"PRIVATE_RESPONSE"}))
                            .await;
                    } else {
                        let prefix = if mode == "wrong-token" {
                            "0".repeat(32)
                        } else {
                            nonce.clone()
                        };
                        // Preserve target in this boundary token lookup without shared mutable state:
                        // the malformed-evidence cases intentionally return a mismatching target.
                        assert!(body["host"].is_string());
                        response(
                            &mut socket,
                            200,
                            Some(&nonce),
                            &json!({"token":format!("{prefix}.{}",zc::fsutil::nonce().unwrap())}),
                        )
                        .await;
                    }
                } else if line.starts_with("DELETE ") {
                    response(&mut socket, 200, Some(&nonce), &json!({"released":true})).await;
                } else if mode == "stale" {
                    response(
                        &mut socket,
                        409,
                        Some(&"0".repeat(32)),
                        &json!({"error":"instance changed"}),
                    )
                    .await;
                } else if mode == "wrong-evidence" {
                    let token = line
                        .split_whitespace()
                        .nth(1)
                        .unwrap()
                        .rsplit('/')
                        .next()
                        .unwrap();
                    response(&mut socket,200,Some(&nonce),&json!({"token":token,"state":"routed","target":{"host":"wrong.example","port":80},"connection_id":format!("{nonce}-1"),"request_index":0,"proxy":{"name":"DIRECT","type":"Direct"}})).await;
                } else {
                    response(
                        &mut socket,
                        404,
                        Some(&nonce),
                        &json!({"error":"unknown ticket"}),
                    )
                    .await;
                }
            });
        }
    });
    tokio::spawn(async move {
        loop {
            let (mut socket, _) = mixed.accept().await.unwrap();
            let mode = mode.clone();
            tokio::spawn(async move {
                if socket.peek(&mut [0]).await.unwrap_or(0) == 0 {
                    return;
                }
                let (header, _) = request(&mut socket).await;
                let lower = header.to_lowercase();
                let tagged = lower.contains(&format!("{PROBE_HEADER}:"));
                assert!(!lower.contains("private_fixture_secret"));
                if mode == "auth" || mode == "wrong-token" {
                    assert!(!tagged, "untrusted reservation sent a ticket");
                }
                let hop_local = lower
                    .lines()
                    .filter_map(|l| l.split_once(':'))
                    .filter(|(k, _)| *k == "connection")
                    .any(|(_, v)| v.split(',').any(|t| t.trim() == PROBE_HEADER));
                // Model the old zc / standards-compliant proxy: it strips only
                // fixed hop fields and fields nominated by Connection.
                let status = if mode == "stale" || tagged && !hop_local {
                    502
                } else {
                    200
                };
                response(&mut socket, status, None, &json!({"query":"192.0.2.1"})).await;
            });
        }
    });
    println!("READY");
    std::io::stdout().flush().unwrap();
    tokio::task::spawn_blocking(|| {
        let _ = std::io::Read::read(&mut std::io::stdin(), &mut [0]);
    })
    .await
    .unwrap();
}

#[test]
fn cli_rejects_untrusted_probe_evidence_and_nominates_hop_local_tokens() {
    for (mode, reason, succeeded) in [
        ("bad-descriptor", "", 0),
        ("auth", "unauthorized", 7),
        ("wrong-token", "evidence_unavailable", 7),
        ("wrong-evidence", "evidence_unavailable", 7),
        ("hop", "evidence_unavailable", 7),
        ("stale", "instance_changed", 0),
    ] {
        let home = tempfile::tempdir().unwrap();
        let home = home.path().canonicalize().unwrap();
        let run = |args: &[&str]| {
            let output = Command::new(env!("CARGO_BIN_EXE_zc"))
                .args(args)
                .env("HOME", &home)
                .env_remove("XDG_RUNTIME_DIR")
                .output()
                .unwrap();
            let value: Value = serde_json::from_slice(&output.stdout).unwrap();
            (output, value)
        };
        let free = || {
            let port = std::net::TcpListener::bind("127.0.0.1:0")
                .unwrap()
                .local_addr()
                .unwrap()
                .port();
            assert_ne!(port, 7899);
            port
        };
        let controller = free();
        let mixed = free();
        let source = home.join("source.yaml");
        std::fs::write(&source,format!("external-controller: 127.0.0.1:{controller}\nsecret: PRIVATE_FIXTURE_SECRET\nrules: ['MATCH,DIRECT']")).unwrap();
        assert!(
            run(&["config", "load", source.to_str().unwrap(), "--json"])
                .0
                .status
                .success()
        );
        assert!(
            run(&["start", "--port", &mixed.to_string(), "--json"])
                .0
                .status
                .success()
        );
        let runtime = home.join(".local/state/zc/runtime");
        let descriptor = std::fs::read(runtime.join("zc.daemon.json")).unwrap();
        let meta: Value = serde_json::from_slice(&descriptor).unwrap();
        let snapshot =
            std::path::PathBuf::from(meta["invocation"]["config_path"].as_str().unwrap());
        let frozen = std::fs::read(&snapshot).unwrap();
        assert!(run(&["stop", "--json"]).0.status.success());
        zc::fsutil::SecureDir::open(&runtime)
            .unwrap()
            .atomic_write(snapshot.file_name().unwrap().to_str().unwrap(), &frozen)
            .unwrap();
        std::fs::write(home.join("descriptor.fixture"), descriptor).unwrap();
        let executable = home.join("zc");
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
                    "probe_controller_boundary_child",
                    "--skip",
                    "--daemon-run",
                    "--nocapture",
                ])
                .env("HOME", &home)
                .env_remove("XDG_RUNTIME_DIR")
                .env("ZC_PROBE_BOUNDARY", mode)
                .env("ZC_PROBE_MIXED", mixed.to_string())
                .stdin(Stdio::piped())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
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
        let (output, value) = run(&["test", "--port", &mixed.to_string(), "--json"]);
        if mode == "bad-descriptor" {
            assert_eq!(value["error"]["code"], "PROXY_TEST_FAILED");
            assert!(value.get("data").is_none());
            continue;
        }
        assert_eq!(
            value["data"]["summary"]["succeeded"], succeeded,
            "{mode}: {value}"
        );
        assert_eq!(output.status.success(), succeeded == 7);
        for target in value["data"]["targets"].as_array().unwrap() {
            assert_eq!(target["actual_path"], "unknown");
            assert_eq!(target["path_reason"], reason, "{mode}: {target}");
            assert!(target.get("proxy").is_none());
            assert!(target.get("route_evidence").is_none());
        }
        assert!(!value.to_string().contains("PRIVATE_"));
    }
}
