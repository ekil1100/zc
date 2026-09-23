use serde_json::{Value, json};
use zc::{
    cli::{doctor_diagnostics, doctor_report},
    service::PrepareOptions,
};

async fn diagnose(source: &str) -> Value {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("source.yaml");
    std::fs::write(&path, source).unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let data = doctor_diagnostics(
        PrepareOptions {
            config: Some(path.to_str().unwrap().into()),
            port: Some(address.port()),
            command: "doctor".into(),
            ..Default::default()
        },
        &json!({"state":"stopped"}),
        address,
    )
    .await
    .unwrap();
    assert_eq!(std::fs::read_to_string(path).unwrap(), source);
    let text = doctor_report(&data);
    for field in ["config_errors", "config_warnings", "migration_hints"] {
        for message in data[field].as_array().unwrap() {
            assert!(text.contains(message.as_str().unwrap()), "{field}: {text}");
        }
    }
    data
}

#[tokio::test]
async fn doctor_accumulates_errors_and_original_supported_warnings() {
    let data = diagnose("mode: invalid\nlog-level: noisy\nbind-address: 127.0.0.2\nidle-session-timeout: 5\nproxies:\n  - {name: edge, type: trojan, server: localhost, port: 443, password: PRIVATE_MARKER, skip-cert-verify: true}\nrules: ['MATCH,missing']\n").await;
    assert_eq!(data["config_ok"], false);
    assert_eq!(
        data["config_errors"],
        json!([
            "Invalid mode: 'invalid' (must be 'rule', 'global', or 'direct')",
            "Unknown log level: 'noisy'",
            "Rule #1: references undefined target 'missing'"
        ])
    );
    assert_eq!(
        data["config_warnings"],
        json!([
            "allow-lan=false: bind-address '127.0.0.2' will be ignored, using 127.0.0.1",
            "idle-session-timeout=5s is too low (<=5s); clamped to 30s",
            "Trojan proxy 'edge': skip-cert-verify=true disables TLS certificate verification"
        ])
    );
    assert!(!data.to_string().contains("PRIVATE_MARKER"));
}

#[tokio::test]
async fn doctor_migration_hints_follow_original_source_scan_without_enabling_features() {
    let data = diagnose("# tun: disabled\n# enhanced-mode: legacy\n# proxy-providers: migrate\nrule-providers: {list: {type: http, behavior: domain, path: cache, url: 'http://127.0.0.1:23456/'}}\nrules: ['RULE-SET,list,DIRECT']\n").await;
    assert_eq!(data["config_ok"], true);
    assert_eq!(
        data["migration_hints"],
        json!([
            "tun mode is not supported by zc and will be ignored",
            "dns.enhanced-mode is not supported and will be ignored",
            "rule-providers remote update is not fully implemented; manual refresh recommended",
            "proxy-providers is not supported; declare proxies statically in the config"
        ])
    );
    for source in ["tun: {enable: true}\n", "proxy-providers: {}\n"] {
        let data = diagnose(source).await;
        assert_eq!(data["config_ok"], false, "{data}");
        assert!(!data["config_errors"].as_array().unwrap().is_empty());
    }
}

#[tokio::test]
async fn doctor_accepts_ignored_subscription_fields_without_claiming_runtime_support() {
    for source in [
        "dns: {enhanced-mode: fake-ip}\n",
        "hosts: {example.com: 192.0.2.1}\n",
        "sniffer: {enable: true}\n",
        "profile: {store-selected: true}\n",
        "experimental: {ignore-resolve-fail: true}\n",
        "unified-delay: true\n",
        "clash-for-android: {append-system-dns: false}\n",
    ] {
        let data = diagnose(source).await;
        assert_eq!(data["config_ok"], true, "{source}: {data}");
        assert_eq!(data["config_errors"], json!([]));
    }
}

#[tokio::test]
async fn diagnostics_replace_warnings_with_errors_and_keep_independent_invalid_state() {
    for (warnings, errors, retained_warnings, truncated) in [
        (255, 0, 255, false),
        (256, 0, 256, false),
        (257, 0, 256, true),
        (256, 1, 255, true),
        (256, 256, 0, true),
        (256, 300, 0, true),
    ] {
        let mut source = String::from("proxies:\n");
        for i in 0..warnings {
            source.push_str(&format!("  - {{name: edge{i}, type: trojan, server: localhost, port: 443, password: PRIVATE_MARKER, skip-cert-verify: true}}\n"));
        }
        source.push_str("rules:\n");
        for i in 0..errors {
            source.push_str(&format!("  - DOMAIN,example.com,missing{i}\n"));
        }
        source.push_str("  - MATCH,REJECT\n");
        let data = diagnose(&source).await;
        assert_eq!(
            data["config_errors"].as_array().unwrap().len(),
            errors.min(256)
        );
        assert_eq!(
            data["config_warnings"].as_array().unwrap().len(),
            retained_warnings
        );
        assert_eq!(data["config_ok"], errors == 0);
        assert_eq!(data["checks"][0]["ok"], errors == 0);
        assert_eq!(data["config_diagnostics_truncated"], truncated);
        if errors > 0 {
            assert_eq!(
                data["config_errors"][0],
                "Rule #1: references undefined target 'missing0'"
            );
        }
        if retained_warnings > 0 {
            assert_eq!(
                data["config_warnings"][retained_warnings - 1],
                format!(
                    "Trojan proxy 'edge{}': skip-cert-verify=true disables TLS certificate verification",
                    retained_warnings - 1
                )
            );
        }
        assert!(!data.to_string().contains("PRIVATE_MARKER"));
    }
}

#[tokio::test]
async fn diagnostic_byte_boundary_uses_zig_template_suffix_and_safe_unicode() {
    // "Unknown log level: ''" is 21 bytes.
    for size in [491, 492, 493, 200_000] {
        let data = diagnose(&format!("log-level: '{}'\n", "a".repeat(size))).await;
        let message = data["config_errors"][0].as_str().unwrap();
        if size <= 491 {
            assert_eq!(message.len(), size + 21);
            assert_eq!(data["config_diagnostics_truncated"], false);
        } else {
            assert_eq!(message, "Unknown log level: '...' ... [truncated]");
            assert_eq!(data["config_diagnostics_truncated"], true);
        }
        assert!(message.len() <= 512);
    }
    for value in ["界".repeat(164), "a\u{1b}\u{202e}z".into()] {
        let source = serde_json::to_string(&json!({"log-level":value})).unwrap();
        let data = diagnose(&source).await;
        let message = data["config_errors"][0].as_str().unwrap();
        assert!(message.len() <= 512);
        assert!(!message.chars().any(char::is_control));
        assert!(!message.contains('\u{202e}'));
    }
}

#[tokio::test]
async fn doctor_reports_payloads_duplicates_groups_and_references_independently() {
    let data = diagnose("proxies:\n  - {name: dup, type: direct}\n  - {name: dup, type: reject}\n  - {name: bad, type: trojan, server: 'bad host', port: 443, password: '', sni: '127.0.0.1'}\nproxy-groups:\n  - {name: dup, type: select, proxies: []}\n  - {name: empty, type: select, proxies: []}\n  - {name: empty, type: select, proxies: [missing]}\n  - {name: cycle, type: select, proxies: [DIRECT, cycle]}\nrules: ['IP-CIDR,bad,missing', 'SRC-PORT,0,missing', 'RULE-SET,absent,missing', 'MATCH,REJECT']\n").await;
    let errors = data["config_errors"].as_array().unwrap();
    for expected in [
        "Duplicate proxy name: 'dup'",
        "Trojan proxy 'bad': password is required",
        "Trojan proxy 'bad': sni must be a valid RFC hostname (1-253 bytes; no IP, wildcard, whitespace, or control characters)",
        "Policy name 'dup' is used by both a proxy and a proxy group",
        "Proxy group 'empty': proxy list cannot be empty",
        "Duplicate proxy group name: 'empty'",
        "Rule #1: invalid IPv4 CIDR format 'bad'",
        "Rule #2: invalid port range '0'",
        "Proxy group 'empty': references undefined proxy or group 'missing'",
        "Rule #3: references undefined rule-provider 'absent'",
        "Rule #3: references undefined target 'missing'",
        "Proxy group 'cycle': cycle detected, including unselected branches",
    ] {
        assert!(
            errors.iter().any(|e| e == expected),
            "missing {expected}: {errors:?}"
        );
    }
    assert_eq!(data["config_ok"], false);
}

#[tokio::test]
async fn malformed_and_unknown_rule_load_failures_remain_credential_free() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("bad.yaml");
    for text in [
        "mode: [PRIVATE_MARKER]\n",
        "proxies: [{name: edge, type: trojan, server: localhost, port: PRIVATE_MARKER}]\n",
        "rules: ['UNKNOWN,PRIVATE_MARKER,DIRECT']\n",
        "rules: ['MATCH,DIRECT', 'MATCH,PRIVATE_MARKER']\n",
        "rule-providers: {private: {type: file, behavior: domain, path: null, url: PRIVATE_MARKER}}\n",
    ] {
        std::fs::write(&source, text).unwrap();
        let error = zc::service::diagnose_config(&PrepareOptions {
            config: Some(source.to_str().unwrap().into()),
            port: Some(23457),
            command: "doctor".into(),
            ..Default::default()
        })
        .await
        .unwrap_err();
        assert!(!format!("{error:#}").contains("PRIVATE_MARKER"));
        assert!(format!("{error:#}").len() <= 512);
    }
}

#[tokio::test]
async fn per_entry_malformed_fields_and_duplicate_names_cannot_escape_the_shared_budget() {
    let source = serde_json::to_string(&json!({
        "proxies": (0..300).map(|_| json!({"name":"dup", "type":"direct", "unsupported-field":"PRIVATE_MARKER"})).collect::<Vec<_>>(),
        "rules":["MATCH,REJECT"]
    })).unwrap();
    let data = diagnose(&source).await;
    assert_eq!(data["config_ok"], false);
    assert_eq!(data["config_errors"].as_array().unwrap().len(), 256);
    assert_eq!(data["config_diagnostics_truncated"], true);
    assert!(!data.to_string().contains("PRIVATE_MARKER"));
    assert!(zc::config::Config::validate_declarations(&source).is_err());
}

#[tokio::test]
async fn controller_credentials_and_terminal_controls_are_never_diagnostics() {
    let data = diagnose(&serde_json::to_string(&json!({
        "secret":"PRIVATE_MARKER\n",
        "external-controller":"https://user:PRIVATE_MARKER@example.com/",
        "proxies":[{"name":"bad\u{1b}\u{202e}","type":"trojan","server":"localhost","port":443,"password":"PRIVATE_MARKER","skip-cert-verify":true}],
        "rules":["MATCH,REJECT"]
    })).unwrap()).await;
    assert_eq!(data["config_ok"], false);
    assert!(!data.to_string().contains("PRIVATE_MARKER"));
    for field in ["config_errors", "config_warnings"] {
        for message in data[field].as_array().unwrap() {
            let message = message.as_str().unwrap();
            assert!(message.len() <= 512);
            assert!(!message.chars().any(char::is_control));
            assert!(!message.contains('\u{202e}'));
        }
    }
}

#[tokio::test]
async fn source_hint_scan_has_the_original_one_mebibyte_limit() {
    for size in [1024 * 1024, 1024 * 1024 + 1] {
        let mut source = String::from("rules: ['MATCH,REJECT']\n# tun:");
        source.push_str(&"x".repeat(size - source.len()));
        let data = diagnose(&source).await;
        assert_eq!(data["config_ok"], true);
        assert_eq!(
            data["migration_hints"].as_array().unwrap().len(),
            usize::from(size == 1024 * 1024)
        );
    }
}

#[tokio::test]
async fn managed_doctor_keeps_canonical_revision_bytes_and_default_hint_behavior() {
    use zc::store::{Bundle, Metadata, Store};
    const CHILD: &str = "ZC_DIAGNOSTICS_TEST_CHILD";
    const SOURCE: &[u8] = b"# tun: historical source comment\nidle-session-timeout: 1\nrule-providers: {}\nrules: ['MATCH,REJECT']\n";
    if std::env::var_os(CHILD).is_some() {
        let store = Store::open(Store::default_root().unwrap()).unwrap();
        let before = store.load().unwrap();
        let identity = before.catalog.active.as_ref().unwrap();
        let bundle = store
            .read_bundle(&identity.key, &identity.revision)
            .unwrap();
        let digest = bundle.content_digest;
        assert_eq!(bundle.bundle.source(), SOURCE);
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let data = doctor_diagnostics(
            PrepareOptions {
                port: Some(address.port()),
                command: "doctor".into(),
                ..Default::default()
            },
            &json!({"state":"stopped"}),
            address,
        )
        .await
        .unwrap();
        assert_eq!(data["config_ok"], true);
        assert_eq!(
            data["config_warnings"],
            json!(["idle-session-timeout=1s is too low (<=5s); clamped to 30s"])
        );
        assert_eq!(data["migration_hints"], json!([]));
        assert_eq!(store.load().unwrap().token, before.token);
        let after = store
            .read_bundle(&identity.key, &identity.revision)
            .unwrap();
        assert_eq!(after.content_digest, digest);
        assert_eq!(after.bundle.source(), SOURCE);
        return;
    }
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let store = Store::open(home.join(".config/zc")).unwrap();
    let bundle = Bundle::from_memory(SOURCE, None, Default::default()).unwrap();
    store
        .publish(
            &store.load().unwrap().token,
            "doctor",
            None,
            &bundle,
            Metadata::default(),
            true,
        )
        .unwrap();
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "managed_doctor_keeps_canonical_revision_bytes_and_default_hint_behavior",
            "--nocapture",
        ])
        .env(CHILD, "1")
        .env("HOME", home)
        .env_remove("XDG_RUNTIME_DIR")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[tokio::test]
async fn multibyte_boundaries_and_proxy_templates_match_the_original_validator() {
    for (value, length, truncated) in [
        ("界".repeat(163), 510, false),
        ("界".repeat(163) + "aa", 512, false),
        ("界".repeat(163) + "界", 40, true),
    ] {
        let data = diagnose(&serde_json::to_string(&json!({"log-level":value})).unwrap()).await;
        let message = data["config_errors"][0].as_str().unwrap();
        assert_eq!(message.len(), length);
        assert_eq!(data["config_diagnostics_truncated"], truncated);
        if truncated {
            assert_eq!(message, "Unknown log level: '...' ... [truncated]");
        }
    }
    let data = diagnose(
        &serde_json::to_string(&json!({"proxies":[{
            "name":"界".repeat(200), "type":"trojan", "server":"localhost", "port":443,
            "password":"", "skip-cert-verify":true
        }]}))
        .unwrap(),
    )
    .await;
    assert_eq!(
        data["config_errors"],
        json!(["Trojan proxy '...': password is required ... [truncated]"])
    );
    assert_eq!(
        data["config_warnings"],
        json!([
            "Trojan proxy '...': skip-cert-verify=true disables TLS certificate verification ... [truncated]"
        ])
    );
    assert_eq!(data["config_diagnostics_truncated"], true);
}

#[tokio::test]
async fn reference_whitespace_must_not_hide_a_runtime_rejection() {
    for rule in ["MATCH,\nDIRECT", "DOMAIN,example.com,\rDIRECT"] {
        let source = serde_json::to_string(&json!({"rules":[rule]})).unwrap();
        assert!(zc::config::Config::validate_declarations(&source).is_err());
        let data = diagnose(&source).await;
        assert_eq!(data["config_ok"], false);
        assert_eq!(data["config_errors"].as_array().unwrap().len(), 1);
    }
}

#[tokio::test]
async fn sanitizing_terminal_controls_does_not_enlarge_the_original_byte_budget() {
    let data = diagnose(
        &serde_json::to_string(&json!({"log-level":"a".repeat(490) + "\u{202e}"})).unwrap(),
    )
    .await;
    assert_eq!(
        data["config_errors"],
        json!(["Unknown log level: '...' ... [truncated]"])
    );
    assert_eq!(data["config_diagnostics_truncated"], true);
}
