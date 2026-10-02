use serde_json::{Value, json};
use std::path::Path;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    process::Command,
};
use zc::service::PrepareOptions;

async fn cli(args: &[&str]) -> Value {
    let output = Command::new(env!("CARGO_BIN_EXE_zc"))
        .args(args)
        .output()
        .await
        .unwrap();
    assert!(output.status.success(), "{args:?}: {output:?}");
    serde_json::from_slice(&output.stdout).unwrap()
}
struct Stop;
impl Drop for Stop {
    fn drop(&mut self) {
        let _ = std::process::Command::new(env!("CARGO_BIN_EXE_zc"))
            .args(["stop", "--json"])
            .output();
    }
}
async fn free_port() -> u16 {
    let port = TcpListener::bind("127.0.0.1:0")
        .await
        .unwrap()
        .local_addr()
        .unwrap()
        .port();
    assert_ne!(port, 7899);
    port
}
async fn isolated(name: &str) -> bool {
    if std::env::var("ZC_PROBE_CLI_CASE").ok().as_deref() == Some(name) {
        return false;
    }
    // Free-port choices are snapshots. Keep independent subprocess fixtures
    // from claiming each other's ports between selection and daemon startup.
    static CASES: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    let _case = CASES.lock().await;
    let dir = tempfile::tempdir().unwrap();
    let output = Command::new(std::env::current_exe().unwrap())
        .args(["--exact", name, "--nocapture"])
        .env("HOME", dir.path().canonicalize().unwrap())
        .env("ZC_PROBE_CLI_CASE", name)
        .env_remove("XDG_RUNTIME_DIR")
        .env_remove("XDG_CONFIG_HOME")
        .env_remove("XDG_STATE_HOME")
        .env("HTTP_PROXY", "http://127.0.0.1:1")
        .env("ALL_PROXY", "http://127.0.0.1:1")
        .env("NO_PROXY", "")
        .kill_on_drop(true)
        .output()
        .await
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    true
}
async fn start(source: &str) -> (u16, Stop) {
    let home = std::env::var("HOME").unwrap();
    let file = Path::new(&home).join(format!("fixture-{}.yaml", zc::fsutil::nonce().unwrap()));
    std::fs::write(&file, source).unwrap();
    cli(&["config", "load", file.to_str().unwrap(), "--json"]).await;
    let port = free_port().await;
    cli(&["start", "--port", &port.to_string(), "--json"]).await;
    (port, Stop)
}
async fn origin(listener: TcpListener) {
    let (mut stream, _) = listener.accept().await.unwrap();
    let mut request = Vec::new();
    while !request.ends_with(b"\r\n\r\n") {
        request.push(stream.read_u8().await.unwrap());
    }
    assert!(
        !String::from_utf8_lossy(&request)
            .to_lowercase()
            .contains("x-zc-probe")
    );
    stream
        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
        .await
        .unwrap();
}

#[tokio::test]
async fn unavailable_controller_and_external_port_report_unknown_without_sending_tickets() {
    if isolated("unavailable_controller_and_external_port_report_unknown_without_sending_tickets")
        .await
    {
        return;
    }
    for controller_enabled in [false, true] {
        let controller = free_port().await;
        let config = if controller_enabled {
            format!("external-controller: 127.0.0.1:{controller}\nrules: ['MATCH,DIRECT']")
        } else {
            "rules: ['MATCH,DIRECT']".to_owned()
        };
        let (mixed, stop) = start(&config).await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let endpoint = if controller_enabled {
            address.port()
        } else {
            mixed
        };
        // The explicit external port receives both a reachability connection
        // and the HTTP request. It must never receive a tracking credential.
        let peer = tokio::spawn(async move {
            if controller_enabled {
                let _ = listener.accept().await.unwrap();
            }
            origin(listener).await;
        });
        let url = format!("http://{address}/");
        let data = zc::cli::test_diagnostics(
            PrepareOptions {
                port: Some(endpoint),
                command: "test".into(),
                ..Default::default()
            },
            &[("Local", &url)],
            false,
        )
        .await
        .unwrap();
        peer.await.unwrap();
        let result = &data["targets"][0];
        assert_eq!(result["ok"], true);
        assert_eq!(result["actual_path"], "unknown");
        assert_eq!(
            result["path_reason"],
            if controller_enabled {
                "port_mismatch"
            } else {
                "controller_required"
            }
        );
        assert!(result["path_hint"].is_string());
        assert_eq!(data["path_summary"]["unknown"]["succeeded"], 1);
        assert_eq!(data["path_summary"]["proxy"]["total"], 0);
        drop(stop);
    }
}

#[tokio::test]
async fn selection_changes_preserve_request_evidence_but_restart_invalidates_it() {
    if isolated("selection_changes_preserve_request_evidence_but_restart_invalidates_it").await {
        return;
    }
    for restart in [false, true] {
        let controller = free_port().await;
        let (port, stop) = start(&format!("external-controller: 127.0.0.1:{controller}\nproxies: [{{name: other-direct, type: direct}}]\nproxy-groups: [{{name: Pick, type: select, proxies: [DIRECT, other-direct]}}]\nrules: ['MATCH,Pick']")).await;
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let (arrived, arrival) = tokio::sync::oneshot::channel();
        let (release, released) = tokio::sync::oneshot::channel();
        let peer = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                request.push(stream.read_u8().await.unwrap());
            }
            assert!(
                !String::from_utf8_lossy(&request)
                    .to_lowercase()
                    .contains("x-zc-probe")
            );
            arrived.send(()).unwrap();
            let _ = released.await;
            let _ = stream
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .await;
        });
        let probe = tokio::spawn(async move {
            zc::cli::test_diagnostics(
                PrepareOptions {
                    port: Some(port),
                    command: "test".into(),
                    ..Default::default()
                },
                &[("Local", &format!("http://{address}/"))],
                false,
            )
            .await
            .unwrap()
        });
        arrival.await.unwrap();
        if restart {
            cli(&["restart", "--json"]).await;
        } else {
            cli(&[
                "proxy",
                "select",
                "-g",
                "Pick",
                "-p",
                "other-direct",
                "--json",
            ])
            .await;
        }
        let _ = release.send(());
        let data = probe.await.unwrap();
        peer.await.unwrap();
        let target = &data["targets"][0];
        if restart {
            assert_eq!(target["actual_path"], "unknown", "{data}");
            assert!(target.get("proxy").is_none());
            assert!(target.get("route_evidence").is_none());
        } else {
            assert_eq!(target["ok"], true, "{data}");
            assert_eq!(target["actual_path"], "direct");
            assert_eq!(target["proxy"]["name"], "DIRECT");
        }
        drop(stop);
    }
}

#[tokio::test]
async fn proxy_success_and_direct_failure_are_counted_separately() {
    if isolated("proxy_success_and_direct_failure_are_counted_separately").await {
        return;
    }
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        crypto::CipherKind,
        relay::tcprelay::proxy_stream::ProxyServerStream,
    };
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let failed = free_port().await;
    let controller = free_port().await;
    let (port, _stop) = start(&format!("external-controller: 127.0.0.1:{controller}\nproxies: [{{name: edge, type: ss, server: 127.0.0.1, port: {}, password: test-only, cipher: aes-128-gcm}}]\nrules: ['DST-PORT,{failed},DIRECT', 'MATCH,edge']", address.port())).await;
    let peer = tokio::spawn(async move {
        let server = ServerConfig::new(address, "test-only", CipherKind::AES_128_GCM).unwrap();
        let (stream, _) = listener.accept().await.unwrap();
        let mut stream = ProxyServerStream::from_stream(
            Context::new_shared(ServerType::Server),
            stream,
            server.method(),
            server.key(),
        );
        stream.handshake().await.unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            request.push(stream.read_u8().await.unwrap());
        }
        assert!(
            !String::from_utf8_lossy(&request)
                .to_lowercase()
                .contains("x-zc-probe")
        );
        stream
            .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
            .await
            .unwrap();
        stream.flush().await.unwrap();
    });
    let direct = format!("http://127.0.0.1:{failed}/");
    let proxy = format!("http://{address}/");
    let data = zc::cli::test_diagnostics(
        PrepareOptions {
            port: Some(port),
            command: "test".into(),
            ..Default::default()
        },
        &[("Direct", &direct), ("Proxy", &proxy)],
        false,
    )
    .await
    .unwrap();
    peer.await.unwrap();
    assert_eq!(
        data["path_summary"]["direct"],
        json!({"total":1,"succeeded":0,"failed":1})
    );
    assert_eq!(
        data["path_summary"]["proxy"],
        json!({"total":1,"succeeded":1,"failed":0})
    );
}

#[tokio::test]
async fn public_test_command_reports_real_ss_leaf_for_all_default_targets() {
    if isolated("public_test_command_reports_real_ss_leaf_for_all_default_targets").await {
        return;
    }
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        crypto::CipherKind,
        relay::tcprelay::proxy_stream::ProxyServerStream,
    };
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let controller = free_port().await;
    let (port, _stop) = start(&format!("external-controller: 127.0.0.1:{controller}\nproxies: [{{name: edge, type: ss, server: 127.0.0.1, port: {}, password: test-only, cipher: aes-128-gcm}}]\nrules: ['MATCH,edge']", address.port())).await;
    let peer = tokio::spawn(async move {
        for _ in 0..7 {
            let server = ServerConfig::new(address, "test-only", CipherKind::AES_128_GCM).unwrap();
            let (stream, _) = listener.accept().await.unwrap();
            let mut stream = ProxyServerStream::from_stream(
                Context::new_shared(ServerType::Server),
                stream,
                server.method(),
                server.key(),
            );
            // Decode the destination but answer locally: never dial public URLs.
            stream.handshake().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                request.push(stream.read_u8().await.unwrap());
            }
            assert!(
                !String::from_utf8_lossy(&request)
                    .to_lowercase()
                    .contains("x-zc-probe")
            );
            let body = "{\"query\":\"192.0.2.1\"}";
            stream
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
            stream.flush().await.unwrap();
        }
    });
    let result = cli(&["test", "--port", &port.to_string(), "--json"]).await;
    peer.await.unwrap();
    assert_eq!(result["ok"], true);
    assert_eq!(
        result["data"]["path_summary"]["proxy"],
        json!({"total":7,"succeeded":7,"failed":0})
    );
    assert_eq!(result["data"]["path_summary"]["direct"]["total"], 0);
    assert!(
        result["data"]["targets"]
            .as_array()
            .unwrap()
            .iter()
            .all(|t| t["actual_path"] == "proxy" && t["proxy"]["name"] == "edge")
    );
}

#[tokio::test]
async fn managed_probe_reports_real_direct_and_proxy_counts() {
    if isolated("managed_probe_reports_real_direct_and_proxy_counts").await {
        return;
    }
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let direct = listener.local_addr().unwrap();
    let failed = free_port().await;
    let controller = free_port().await;
    let (port, _stop) = start(&format!("external-controller: 127.0.0.1:{controller}\nproxies: [{{name: edge, type: ss, server: 127.0.0.1, port: {failed}, password: test-only, cipher: aes-128-gcm}}]\nrules: ['DST-PORT,{},DIRECT', 'MATCH,edge']", direct.port())).await;
    let peer = tokio::spawn(origin(listener));
    let direct_url = format!("http://{direct}/");
    let proxy_url = format!("http://127.0.0.1:{failed}/");
    let targets = [
        ("Cloudflare", direct_url.as_str()),
        ("A", proxy_url.as_str()),
        ("B", proxy_url.as_str()),
        ("C", proxy_url.as_str()),
        ("D", proxy_url.as_str()),
        ("E", proxy_url.as_str()),
        ("F", proxy_url.as_str()),
    ];
    let data = zc::cli::test_diagnostics(
        PrepareOptions {
            port: Some(port),
            command: "test".into(),
            ..Default::default()
        },
        &targets,
        false,
    )
    .await
    .unwrap();
    peer.await.unwrap();
    assert_eq!(
        data["summary"],
        json!({"status":"partial","total":7,"succeeded":1,"failed":6})
    );
    assert_eq!(data["checks"][1]["ok"], false);
    assert_eq!(
        data["path_summary"]["direct"],
        json!({"total":1,"succeeded":1,"failed":0})
    );
    assert_eq!(
        data["path_summary"]["proxy"],
        json!({"total":6,"succeeded":0,"failed":6})
    );
    assert_eq!(data["path_summary"]["unknown"]["total"], 0);
    let items = data["targets"].as_array().unwrap();
    for target in items {
        if target["name"] == "Cloudflare" {
            assert_eq!(target["actual_path"], "direct", "{target}");
            assert_eq!(target["proxy"], json!({"name":"DIRECT","type":"Direct"}));
        } else {
            assert_eq!(target["actual_path"], "proxy", "{target}");
            assert_eq!(target["proxy"], json!({"name":"edge","type":"Shadowsocks"}));
        }
        assert!(target["route_evidence"]["connection_id"].is_string());
    }
    assert!(!data.to_string().contains("test-only"));
    assert!(!data.to_string().contains("\"token\""));
}
