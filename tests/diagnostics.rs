use serde_json::json;
use zc::{
    cli::{doctor_diagnostics, doctor_report},
    service::PrepareOptions,
};

#[tokio::test]
async fn doctor_checks_declarations_without_fetching_providers_and_uses_local_probe_seam() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.yaml");
    let network = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let remote = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let options = PrepareOptions {
        config: Some(source.to_str().unwrap().into()),
        port: Some(port.local_addr().unwrap().port()),
        command: "doctor".into(),
        ..Default::default()
    };
    std::fs::write(&source, format!("rule-providers: {{list: {{type: http, behavior: domain, path: cache, url: 'http://{}/'}}}}\nrules: ['RULE-SET,list,DIRECT']\n", remote.local_addr().unwrap())).unwrap();
    let state = json!({"state":"stopped"});
    let data = doctor_diagnostics(options.clone(), &state, network.local_addr().unwrap())
        .await
        .unwrap();
    assert_eq!(data["config_ok"], true);
    assert_eq!(data["config_source"], "custom");
    assert_eq!(data["network_ok"], true);
    assert_eq!(data["checks"][1]["ok"], true);
    assert!(!dir.path().join("cache").exists());
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(30), remote.accept())
            .await
            .is_err()
    );
    std::fs::write(&source, "rules: ['MATCH,missing']\n").unwrap();
    let data = doctor_diagnostics(options.clone(), &state, network.local_addr().unwrap())
        .await
        .unwrap();
    assert_eq!(data["config_ok"], false);
    let message = data["config_errors"][0].as_str().unwrap();
    assert_eq!(message, "Rule #1: references undefined target 'missing'");
    assert!(message.len() <= 512);
    let text = doctor_report(&data);
    assert!(text.contains(message));
    for label in ["Config:", "Daemon:", "PID:", "Port:", "Connection:"] {
        assert!(text.contains(label));
    }
    std::fs::write(source, "password: PRIVATE_MARKER\nbroken: [").unwrap();
    let error = doctor_diagnostics(options, &state, network.local_addr().unwrap())
        .await
        .unwrap_err();
    assert!(!error.to_string().contains("PRIVATE_MARKER"));
}

#[tokio::test]
async fn doctor_network_is_informational_but_running_unreachable_proxy_fails() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.yaml");
    std::fs::write(&source, "rules: ['MATCH,DIRECT']\n").unwrap();
    let closed = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = closed.local_addr().unwrap();
    drop(closed);
    let options = PrepareOptions {
        config: Some(source.to_str().unwrap().into()),
        port: Some(address.port()),
        command: "doctor".into(),
        ..Default::default()
    };
    for running in [false, true] {
        let state =
            json!({"state":if running {"running"}else{"stopped"},"mixed_port":address.port()});
        let data = doctor_diagnostics(options.clone(), &state, address)
            .await
            .unwrap();
        assert_eq!(data["network_ok"], false);
        assert_eq!(data["config_ok"], true);
        assert_eq!(data["proxy_reachable"], false);
        assert_eq!(data["checks"][1]["ok"], !running);
        assert_eq!(data["config_diagnostics_truncated"], false);
    }
}

#[test]
fn malformed_diagnostic_commands_keep_original_load_failure_codes_and_no_fake_data() {
    use std::process::Command;
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let source = home.join("bad.yaml");
    std::fs::write(&source, "secret: PRIVATE_MARKER\nbroken: [").unwrap();
    for (command, code) in [
        (vec!["doctor"], "DIAG_DOCTOR_FAILED"),
        (vec!["diag", "doctor"], "DIAG_DOCTOR_FAILED"),
        (vec!["test"], "PROXY_CONFIG_LOAD_FAILED"),
        (vec!["proxy", "test"], "PROXY_CONFIG_LOAD_FAILED"),
    ] {
        for json_mode in [false, true] {
            let mut args = command.clone();
            args.extend(["-c", source.to_str().unwrap()]);
            if command.last() == Some(&"test") {
                args.extend(["--port", "23457"]);
            }
            if json_mode {
                args.push("--json");
            }
            let output = Command::new(env!("CARGO_BIN_EXE_zc"))
                .args(args)
                .env("HOME", &home)
                .env_remove("XDG_RUNTIME_DIR")
                .output()
                .unwrap();
            assert_eq!(output.status.code(), Some(1));
            assert!(!String::from_utf8_lossy(&output.stdout).contains("PRIVATE_MARKER"));
            assert!(!String::from_utf8_lossy(&output.stderr).contains("PRIVATE_MARKER"));
            if json_mode {
                let value: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
                assert_eq!(value["error"]["code"], code);
                assert!(value.get("data").is_none());
            } else {
                assert!(String::from_utf8_lossy(&output.stderr).contains(code));
            }
        }
    }
}

#[tokio::test]
async fn doctor_rejects_unsupported_capabilities_before_reporting_semantic_checks() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.yaml");
    std::fs::write(
        &source,
        "proxies: [{name: edge, type: http, server: localhost, port: 80}]\nrules: ['MATCH,edge']\n",
    )
    .unwrap();
    let options = PrepareOptions {
        config: Some(source.to_str().unwrap().into()),
        port: Some(23457),
        command: "doctor".into(),
        ..Default::default()
    };
    assert!(zc::service::diagnose_config(&options).await.is_err());
}

#[test]
fn diagnostic_load_errors_do_not_leak_start_codes_or_hide_capability_codes() {
    use std::process::Command;
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let source = home.join("unsupported.yaml");
    std::fs::write(
        &source,
        "proxies: [{name: edge, type: http, server: localhost, port: 80}]\nrules: ['MATCH,edge']\n",
    )
    .unwrap();
    for (config, code) in [
        ("missing-profile", "DIAG_DOCTOR_FAILED"),
        (source.to_str().unwrap(), "CONFIG_CAPABILITY_UNSUPPORTED"),
    ] {
        let output = Command::new(env!("CARGO_BIN_EXE_zc"))
            .args(["doctor", "-c", config, "--json"])
            .env("HOME", &home)
            .env_remove("XDG_RUNTIME_DIR")
            .output()
            .unwrap();
        let result: serde_json::Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(output.status.code(), Some(1));
        assert_eq!(result["error"]["code"], code, "{result}");
        assert!(result.get("data").is_none());
    }
}

#[tokio::test]
async fn proxy_target_shapes_match_zig_geo_and_latency_results_on_real_local_http() {
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    let client = reqwest::Client::builder().no_proxy().build().unwrap();
    for (name, status, body, expected_ip, expected_ok) in [
        (
            "IP/Location",
            200,
            "{\"query\":\"192.0.2.1\"}",
            Some("192.0.2.1"),
            true,
        ),
        ("IP/Location", 200, "not JSON", Some("unknown"), true),
        ("IP/Location", 502, "upstream failed", None, false),
        ("Google", 403, "denied", None, true),
        ("Google", 502, "upstream failed", None, false),
    ] {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!("http://{}/", listener.local_addr().unwrap());
        let peer = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                request.push(stream.read_u8().await.unwrap());
                assert!(request.len() < 16384);
            }
            stream.write_all(format!("HTTP/1.1 {status} Response\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
        });
        let target = zc::cli::diagnostic_target_probe(&client, name, &url).await;
        peer.await.unwrap();
        assert_eq!(target["ok"], expected_ok);
        assert_eq!(
            target.get("ip").and_then(|value| value.as_str()),
            expected_ip
        );
        assert_eq!(
            target.get("latency_ms").is_some(),
            expected_ok && name != "IP/Location"
        );
        if !expected_ok {
            assert_eq!(
                target["reason"],
                if name == "IP/Location" {
                    "no response"
                } else {
                    "TCP connect failure"
                }
            );
        }
        let text = zc::cli::diagnostic_target_report(&target);
        assert!(text.contains(name));
        if let Some(ip) = expected_ip {
            assert!(text.contains(ip));
        }
        if !expected_ok {
            assert!(text.contains(target["reason"].as_str().unwrap()));
        }
    }
}
