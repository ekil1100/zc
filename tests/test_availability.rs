use serde_json::Value;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    process::Command,
};

// A loopback HTTP proxy fixture answers locally; it never resolves or forwards
// the public target URLs sent by the CLI.
async fn run_test(
    command: &[&str],
    json_mode: bool,
    successful_targets: usize,
) -> std::process::Output {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let source = home.join("config.yaml");
    std::fs::write(&source, "proxy-groups: [{name: Choice, type: select, proxies: [DIRECT, REJECT]}]\nrules: ['MATCH,Choice']\n").unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    assert_ne!(port, 7899);
    let peer = tokio::spawn(async move {
        let mut requests = 0;
        while requests < 7 {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            loop {
                match stream.read_u8().await {
                    Ok(byte) => request.push(byte),
                    Err(_) if request.is_empty() => break, // Port readiness probe.
                    Err(error) => panic!("incomplete request: {error}"),
                }
                assert!(request.len() < 16384);
                if request.ends_with(b"\r\n\r\n") {
                    requests += 1;
                    let cloudflare = request.starts_with(b"GET http://1.1.1.1/ ");
                    let status = if successful_targets == 7
                        || successful_targets == 1 && cloudflare
                        || successful_targets == 6 && !cloudflare
                    {
                        200
                    } else {
                        502
                    };
                    let body = "{\"query\":\"192.0.2.1\"}";
                    stream.write_all(format!("HTTP/1.1 {status} Response\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).await.unwrap();
                    break;
                }
            }
        }
    });
    let mut cli = Command::new(env!("CARGO_BIN_EXE_zc"));
    cli.args(command)
        .args(["-c", source.to_str().unwrap(), "--port", &port.to_string()])
        .env("HOME", &home)
        .env_remove("XDG_RUNTIME_DIR")
        .kill_on_drop(true);
    if json_mode {
        cli.arg("--json");
    }
    let output = tokio::time::timeout(std::time::Duration::from_secs(15), cli.output())
        .await
        .unwrap()
        .unwrap();
    tokio::time::timeout(std::time::Duration::from_secs(5), peer)
        .await
        .unwrap()
        .unwrap();
    output
}

#[tokio::test]
async fn closed_port_reports_not_run_instead_of_vacuous_success() {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let source = home.join("config.yaml");
    std::fs::write(&source, "rules: ['MATCH,DIRECT']\n").unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    assert_ne!(port, 7899);
    drop(listener);
    for json_mode in [false, true] {
        let mut cli = Command::new(env!("CARGO_BIN_EXE_zc"));
        cli.args([
            "test",
            "-c",
            source.to_str().unwrap(),
            "--port",
            &port.to_string(),
        ])
        .env("HOME", &home)
        .env_remove("XDG_RUNTIME_DIR")
        .kill_on_drop(true);
        if json_mode {
            cli.arg("--json");
        }
        let output = cli.output().await.unwrap();
        assert_eq!(output.status.code(), Some(1));
        if json_mode {
            let value: Value = serde_json::from_slice(&output.stdout).unwrap();
            assert_eq!(value["ok"], false);
            assert_eq!(value["error"]["code"], "CHECKS_FAILED");
            assert_eq!(value["data"]["targets"], serde_json::json!([]));
            assert_eq!(
                value["data"]["summary"],
                serde_json::json!({
                    "status": "not_run", "total": 0, "succeeded": 0, "failed": 0
                })
            );
            assert_eq!(value["data"]["checks"][0]["ok"], false);
        } else {
            assert!(
                String::from_utf8(output.stdout)
                    .unwrap()
                    .contains("Summary: not run (0/0 targets reachable)")
            );
        }
    }
}

#[tokio::test]
async fn summaries_and_exit_codes_agree_in_text_and_json() {
    for (succeeded, status, label, exit) in [
        (7, "all_succeeded", "all targets reachable", 0),
        (1, "partial", "partially reachable", 1),
        (6, "partial", "partially reachable", 1),
        (0, "all_failed", "all targets failed", 1),
    ] {
        for command in [
            &["test"][..],
            &["proxy", "test"][..],
            &["profile", "test"][..],
        ] {
            for json_mode in [false, true] {
                let output = run_test(command, json_mode, succeeded).await;
                assert_eq!(output.status.code(), Some(exit));
                if json_mode {
                    let value: Value = serde_json::from_slice(&output.stdout).unwrap();
                    assert_eq!(value["ok"], exit == 0);
                    assert_eq!(
                        value["data"]["summary"],
                        serde_json::json!({
                            "status": status, "total": 7, "succeeded": succeeded, "failed": 7 - succeeded
                        })
                    );
                    assert_eq!(value["data"]["targets"].as_array().unwrap().len(), 7);
                } else {
                    let text = String::from_utf8(output.stdout).unwrap();
                    assert!(
                        text.contains(&format!(
                            "Summary: {label} ({succeeded}/7 targets reachable)"
                        )),
                        "{text}"
                    );
                    assert_eq!(text.matches("[actual path: unknown]").count(), 7);
                    assert!(!text.contains("actual path: DIRECT"));
                }
            }
        }
    }
}

#[tokio::test]
async fn only_cloudflare_reachable_is_partial_failure_for_every_test_command() {
    for command in [
        &["test"][..],
        &["proxy", "test"][..],
        &["profile", "test"][..],
    ] {
        let output = run_test(command, true, 1).await;
        let value: Value = serde_json::from_slice(&output.stdout).unwrap();
        assert_eq!(output.status.code(), Some(1), "{value}");
        assert_eq!(value["ok"], false);
        assert_eq!(value["error"]["code"], "CHECKS_FAILED");
        assert_eq!(
            value["data"]["summary"],
            serde_json::json!({
                "status": "partial", "total": 7, "succeeded": 1, "failed": 6
            })
        );
        assert_eq!(value["data"]["checks"][1]["ok"], false);
        assert_eq!(value["data"]["selected_proxies_source"], "prepared_config");
        let targets = value["data"]["targets"].as_array().unwrap();
        assert_eq!(targets.len(), 7);
        assert_eq!(
            value["data"]["selected_proxies"],
            serde_json::json!([
                {"group": "Choice", "proxy": "DIRECT"}
            ])
        );
        // Even a config selecting DIRECT is not evidence of the actual
        // route taken by the independent proxy listening on the requested port.
        assert!(
            targets
                .iter()
                .all(|target| target["actual_path"] == "unknown")
        );
        assert_eq!(
            targets.iter().filter(|target| target["ok"] == true).count(),
            1
        );
        assert!(
            targets
                .iter()
                .any(|target| target["name"] == "Cloudflare" && target["ok"] == true)
        );
    }
}
