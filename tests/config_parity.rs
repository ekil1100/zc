use zc::config::Config;

#[test]
fn native_udp_and_http_obfs_metadata_follow_zig_admission() {
    for kind in ["ss", "trojan"] {
        let cipher = if kind == "ss" {
            ", cipher: aes-128-gcm"
        } else {
            ""
        };
        for udp in ["", ", udp: false", ", udp: true"] {
            let config = Config::parse(&format!(
                "proxies: [{{name: edge, type: {kind}, server: localhost, port: 443, password: secret{cipher}{udp}}}]"
            ));
            assert!(config.is_ok(), "native UDP metadata rejected");
        }
    }
    for plugin in ["obfs", "obfs-local"] {
        for key in ["plugin-opts", "plugin_opts"] {
            let config = Config::parse(&format!(
                "proxies: [{{name: edge, type: ss, server: localhost, port: 443, password: secret, cipher: aes-128-gcm, udp: true, plugin: {plugin}, {key}: {{mode: http, host: cdn.example.com}}}}]"
            ));
            assert!(config.is_ok(), "simple-obfs HTTP metadata rejected");
        }
    }
}

#[tokio::test]
async fn selection_snapshot_is_atomic_and_routes_keep_safe_proxy_borrows() {
    use std::collections::BTreeMap;
    use zc::target::Target;
    let config = Config::parse("proxy-groups: [{name: outer, type: select, proxies: [inner, DIRECT]}, {name: inner, type: select, proxies: [REJECT, DIRECT]}]\nrules: ['MATCH,outer']").unwrap();
    let target = Target::new("example.com", 443).unwrap();
    let before = config.route(&target).await.unwrap();
    config.select("inner", "DIRECT").unwrap();
    assert_eq!(before.proxy.name, "REJECT");
    assert_eq!(config.route(&target).await.unwrap().proxy.name, "DIRECT");
    let state = config.selected();
    let invalid = BTreeMap::from([
        ("inner".into(), "REJECT".into()),
        ("outer".into(), "missing".into()),
    ]);
    assert!(config.set_selections(&invalid).is_err());
    assert_eq!(config.selected(), state);
    assert!(config.select("DIRECT", "REJECT").is_err());
    config.set_selections(&BTreeMap::new()).unwrap();
    assert_eq!(config.route(&target).await.unwrap().proxy.name, "REJECT");
}

#[test]
fn controller_modes_and_api_views_preserve_baseline_metadata() {
    for mode in ["rule", "direct", "global"] {
        let config = Config::parse(&format!("mode: {mode}\nexternal-controller: 127.0.0.1:19432\nsecret: 'a\\b'\nrules: ['MATCH,DIRECT']")).unwrap();
        assert_eq!(config.mode(), mode);
        assert_eq!(
            config.controller_endpoint().unwrap().to_string(),
            "127.0.0.1:19432"
        );
        assert_eq!(config.secret(), "a\\b");
        assert_eq!(config.proxies_json(), serde_json::json!({"proxies": []}));
        assert_eq!(
            config.rules_json(),
            serde_json::json!({"rules": [{"type":"MATCH", "payload":"", "target":"DIRECT"}]})
        );
    }
    for endpoint in [
        "localhost:19432",
        "127.0.0.2:19432",
        "0.0.0.0:19432",
        "[::1]:19432",
        "127.0.0.1:0",
        "127.0.0.1:+123",
    ] {
        assert!(Config::parse(&format!("external-controller: '{endpoint}'")).is_err());
    }
}

#[tokio::test]
async fn contextual_rules_use_real_peer_and_explicit_process_identity_only() {
    use zc::{config::MatchContext, target::Target};
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let (client, accepted) = tokio::join!(
        tokio::net::TcpStream::connect(listener.local_addr().unwrap()),
        listener.accept()
    );
    let client = client.unwrap();
    let (_, peer) = accepted.unwrap();
    assert_eq!(client.local_addr().unwrap(), peer);
    let target = Target::new("example.com", 443).unwrap();
    let ctx = MatchContext {
        source_ip: Some(peer.ip()),
        source_port: Some(peer.port()),
        process_name: Some("curl"),
    };
    for rule in [
        format!("SRC-PORT,{},REJECT", peer.port()),
        "SRC-IP-CIDR,127.0.0.0/8,REJECT".into(),
        "PROCESS-NAME,curl,REJECT".into(),
    ] {
        let config = Config::parse(&format!("rules: ['{rule}', 'MATCH,DIRECT']")).unwrap();
        assert_eq!(config.route(&target).await.unwrap().proxy.name, "DIRECT");
        assert_eq!(
            config
                .route_with_context(&target, &ctx)
                .await
                .unwrap()
                .proxy
                .name,
            "REJECT"
        );
    }
    for rule in [
        "PROCESS-PATH,/usr/bin/curl,DIRECT",
        "SRC-IP-CIDR,::1/128,DIRECT",
        "SRC-PORT,0,DIRECT",
        "PROCESS-NAME,,DIRECT",
    ] {
        assert!(Config::parse(&format!("rules: ['{rule}']")).is_err());
    }
}

#[tokio::test]
async fn geoip_uses_the_zig_ordered_builtin_ipv4_table_not_a_database() {
    use zc::target::Target;
    for (country, host, matched) in [
        ("CN", "1.0.0.1", true),
        ("US", "2.0.0.1", true),
        ("CN", "192.0.2.1", true),
        ("US", "192.0.2.1", false),
        ("CN", "::1", false),
        ("CN", "0.0.0.0", false),
        ("cn", "1.0.0.1", false),
    ] {
        let config = Config::parse(&format!(
            "rules: ['GEOIP,{country},REJECT,no-resolve', 'MATCH,DIRECT']"
        ))
        .unwrap();
        assert_eq!(
            config
                .route(&Target::new(host, 443).unwrap())
                .await
                .unwrap()
                .proxy
                .name,
            if matched { "REJECT" } else { "DIRECT" }
        );
    }
    let config = Config::parse("rules: ['GEOIP,CN,REJECT,no-resolve', 'MATCH,DIRECT']").unwrap();
    assert_eq!(
        config
            .route(&Target::new("nonexistent.invalid", 443).unwrap())
            .await
            .unwrap()
            .target
            .host(),
        "nonexistent.invalid"
    );
}

#[test]
fn public_document_parser_bounds_all_nested_collection_entries() {
    use zc::config::parse_document;
    assert_eq!(
        parse_document("extension: {nested: [1, true, null]}").unwrap(),
        serde_json::json!({"extension":{"nested":[1,true,null]}})
    );
    for source in [
        "[]",
        "null",
        "x: 1\nx: 2",
        "x: &a [1]",
        "x: !include /tmp/secret",
    ] {
        assert!(parse_document(source).is_err(), "accepted {source}");
    }
    // The strict Zig oracle accepts 129 total map frames, rejects 130.
    assert!(parse_document(&format!("{}1{}", "{x: ".repeat(130), "}".repeat(130))).is_err());
    for (count, valid) in [(262143, true), (262144, false)] {
        assert_eq!(
            parse_document(&format!("extension: [{}]", vec!["0"; count].join(","))).is_ok(),
            valid
        );
    }
}

#[tokio::test]
async fn immutable_provider_assets_expand_in_order_and_never_fall_back_to_disk() {
    use std::collections::BTreeMap;
    use zc::{
        config::{capture_file_assets, parse_with_assets},
        target::Target,
    };
    let root = tempfile::tempdir().unwrap();
    std::fs::create_dir(root.path().join("rules")).unwrap();
    std::fs::write(
        root.path().join("rules/domains.yaml"),
        "payload: ['+.example.com', 'DOMAIN,exact.test']",
    )
    .unwrap();
    let source = "rule-providers:\n  domains: {type: file, behavior: domain, path: rules/domains.yaml}\nrules: ['RULE-SET,domains,REJECT', 'MATCH,DIRECT']";
    let assets = capture_file_assets(source, root.path()).unwrap();
    std::fs::write(
        root.path().join("rules/domains.yaml"),
        "payload: ['different.test']",
    )
    .unwrap();
    let config = parse_with_assets(source, &assets).unwrap();
    for host in ["example.com", "www.example.com", "sub.exact.test"] {
        assert_eq!(
            config
                .route(&Target::new(host, 443).unwrap())
                .await
                .unwrap()
                .proxy
                .name,
            "REJECT"
        );
    }
    assert_eq!(
        config.rules_json()["rules"][0],
        serde_json::json!({"type":"DOMAIN-SUFFIX", "payload":"example.com", "target":"REJECT"})
    );
    assert!(parse_with_assets(source, &BTreeMap::new()).is_err());
    assert!(Config::parse(source).is_err());
}

#[tokio::test]
async fn classical_and_ipcidr_providers_inherit_targets_and_no_resolve() {
    use std::collections::BTreeMap;
    use zc::{config::parse_with_assets, target::Target};
    for (behavior, body, host, target_name) in [
        (
            "classical",
            "DOMAIN,example.com\nDOMAIN-SUFFIX,other.test,no-resolve\n",
            "example.com",
            "REJECT",
        ),
        (
            "classical",
            "payload: ['IP-CIDR,127.0.0.0/8', 'IP-CIDR6,::1/128']",
            "localhost",
            "DIRECT",
        ),
        (
            "ipcidr",
            "payload: ['IP-CIDR,127.0.0.0/8', '::1/128']",
            "127.0.0.1",
            "REJECT",
        ),
        ("ipcidr", "127.0.0.0/8\n::1/128\n", "localhost", "DIRECT"),
    ] {
        let source = format!(
            "rule-providers: {{list: {{type: file, behavior: {behavior}, path: list}}}}\nrules: ['RULE-SET,list,REJECT,no-resolve', 'MATCH,DIRECT']"
        );
        let config = parse_with_assets(
            &source,
            &BTreeMap::from([("list".into(), body.as_bytes().to_vec())]),
        )
        .unwrap();
        assert_eq!(
            config
                .route(&Target::new(host, 443).unwrap())
                .await
                .unwrap()
                .proxy
                .name,
            target_name
        );
    }
}

#[test]
fn provider_documents_cannot_smuggle_targets_recursion_or_parser_failures() {
    use std::collections::BTreeMap;
    use zc::config::parse_with_assets;
    for (behavior, body) in [
        ("classical", b"RULE-SET,list".as_slice()),
        ("classical", b"DOMAIN,example.com,REJECT"),
        ("classical", b"PROCESS-PATH,/bin/curl"),
        ("classical", b"payload: ['MATCH', 'DOMAIN,a.test']"),
        ("domain", b"payload: [a.test]\npayload: [b.test]"),
        ("domain", b"payload: &p [a.test]"),
        ("domain", b"payload: [!include /tmp/sensitive]"),
        ("domain", b"[a.test]"),
        ("domain", b"payload: [true]"),
        ("domain", b"payload: [a.test"),
        ("domain", b"payload: null"),
        ("domain", b"payload: ['bad\xff.test']"),
        ("ipcidr", b"payload: ['1.2.3.4/33']"),
    ] {
        let source = format!(
            "rule-providers: {{list: {{type: file, behavior: {behavior}, path: list}}}}\nrules: ['RULE-SET,list,DIRECT', 'MATCH,REJECT']"
        );
        assert!(
            parse_with_assets(&source, &BTreeMap::from([("list".into(), body.to_vec())])).is_err(),
            "accepted {behavior} provider"
        );
    }
}

#[tokio::test]
async fn explicit_http_provider_fetch_freezes_real_socket_response_and_limits_body() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use zc::{
        config::{fetch_http_assets, parse_with_assets},
        target::Target,
    };
    for (body, valid) in [
        (
            "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n17\r\npayload: ['+.web.test']\r\n0\r\n\r\n",
            true,
        ),
        ("HTTP/1.1 200 OK\r\nContent-Length: 16777217\r\n\r\n", false),
        (
            "HTTP/1.1 503 Unavailable\r\nContent-Length: 0\r\n\r\n",
            false,
        ),
    ] {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let url = format!(
            "http://{}/rules?secret-marker",
            listener.local_addr().unwrap()
        );
        let source = format!(
            "rule-providers: {{web: {{type: http, behavior: domain, url: '{url}', path: web, interval: 60}}}}\nrules: ['RULE-SET,web,REJECT', 'MATCH,DIRECT']"
        );
        assert!(
            Config::parse(&source).is_err(),
            "parsing must not implicitly fetch"
        );
        let peer = async {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                assert!(request.len() < 4096);
                request.push(socket.read_u8().await.unwrap());
            }
            socket.write_all(body.as_bytes()).await.unwrap();
        };
        let (assets, ()) = tokio::join!(fetch_http_assets(&source), peer);
        if valid {
            let config = parse_with_assets(&source, &assets.unwrap()).unwrap();
            assert_eq!(
                config
                    .route(&Target::new("sub.web.test", 443).unwrap())
                    .await
                    .unwrap()
                    .proxy
                    .name,
                "REJECT"
            );
        } else {
            let error = assets.unwrap_err();
            assert!(!format!("{error:#}").contains("secret-marker"));
        }
    }
}

#[cfg(unix)]
#[test]
fn provider_file_capture_rejects_symlinks_traversal_and_special_files() {
    use zc::config::capture_file_assets;
    let root = tempfile::tempdir().unwrap();
    std::fs::write(root.path().join("valid"), b"example.com").unwrap();
    std::os::unix::fs::symlink(root.path().join("valid"), root.path().join("linked")).unwrap();
    let _socket = std::os::unix::net::UnixListener::bind(root.path().join("socket")).unwrap();
    for path in ["../escape", "/tmp/escape", "linked", "socket", "."] {
        let source =
            format!("rule-providers: {{list: {{type: file, behavior: domain, path: '{path}'}}}}");
        assert!(
            capture_file_assets(&source, root.path()).is_err(),
            "accepted {path}"
        );
    }
}

#[test]
fn provider_and_expansion_budgets_include_unreferenced_entries_and_repeated_sets() {
    use std::collections::BTreeMap;
    use zc::config::parse_with_assets;
    let source = "rule-providers: {list: {type: file, behavior: domain, path: list}}\nrules: ['MATCH,DIRECT']";
    for (count, valid) in [(262144, true), (262145, false)] {
        let assets = BTreeMap::from([("list".into(), "a.test\n".repeat(count).into_bytes())]);
        assert_eq!(
            parse_with_assets(source, &assets).is_ok(),
            valid,
            "provider count {count}"
        );
    }
    let assets = BTreeMap::from([("list".into(), "a.test\n".repeat(140000).into_bytes())]);
    let repeated = "rule-providers: {list: {type: file, behavior: domain, path: list}}\nrules: ['RULE-SET,list,DIRECT', 'RULE-SET,list,DIRECT', 'MATCH,REJECT']";
    assert!(parse_with_assets(repeated, &assets).is_err());
    let target = "g".repeat(512);
    let expanded_bytes = format!(
        "proxy-groups: [{{name: {target}, type: select, proxies: [DIRECT]}}]\nrule-providers: {{list: {{type: file, behavior: domain, path: list}}}}\nrules: ['RULE-SET,list,{target}', 'MATCH,DIRECT']"
    );
    assert!(parse_with_assets(&expanded_bytes, &assets).is_err());
    for (count, valid) in [(4096, true), (4097, false)] {
        let mut source = "rules: ['MATCH,DIRECT']\nrule-providers:\n".to_owned();
        for index in 0..count {
            source.push_str(&format!(
                "  p{index}: {{type: file, behavior: domain, path: empty}}\n"
            ));
        }
        assert_eq!(
            parse_with_assets(&source, &BTreeMap::from([("empty".into(), Vec::new())])).is_ok(),
            valid
        );
    }
}

#[tokio::test]
async fn mixed_subscription_groups_and_ignored_extra_listeners_match_zig() {
    use zc::target::Target;
    let source = "mixed-port: 18080\nport: 18081\nsocks-port: 18082\nexternal-controller: null\nsecret: null\nproxies: [{name: choose, type: select, proxies: [REJECT, DIRECT]}]\nrules: ['MATCH,choose']";
    let config = Config::parse(source).unwrap();
    assert_eq!(config.controller_endpoint(), None);
    assert_eq!(config.secret(), "");
    assert_eq!(config.document()["mixed-port"], 18080);
    assert_eq!(
        config
            .route(&Target::new("example.com", 443).unwrap())
            .await
            .unwrap()
            .proxy
            .name,
        "REJECT"
    );
    config.select("choose", "DIRECT").unwrap();
    assert_eq!(
        config
            .route(&Target::new("example.com", 443).unwrap())
            .await
            .unwrap()
            .proxy
            .name,
        "DIRECT"
    );
    for source in [
        "port: 18081",
        "socks-port: 18082",
        "mixed-port: 18080\nport: -1",
        "mixed-port: 18080\nsocks-port: 65536",
    ] {
        assert!(Config::parse(source).is_err());
    }
}

#[test]
fn provider_raw_byte_budgets_count_comments_and_do_not_read_oversized_files() {
    use std::collections::BTreeMap;
    use zc::config::{capture_file_assets, parse_with_assets};
    let limit = 16 * 1024 * 1024;
    let mut assets = BTreeMap::new();
    let mut source = "rules: ['MATCH,DIRECT']\nrule-providers:\n".to_owned();
    for index in 0..4 {
        let mut comment = vec![b' '; limit];
        comment[0] = b'#';
        assets.insert(format!("p{index}"), comment);
        source.push_str(&format!(
            "  p{index}: {{type: file, behavior: domain, path: p{index}}}\n"
        ));
    }
    assert!(
        parse_with_assets(&source, &assets).is_ok(),
        "exact aggregate raw byte limit"
    );
    assets.insert("extra".into(), vec![b'#']);
    assert!(
        parse_with_assets(&source, &assets).is_err(),
        "unreferenced asset bytes still count"
    );
    assets.remove("extra");
    assets.get_mut("p0").unwrap().push(b' ');
    assert!(
        parse_with_assets(&source, &assets).is_err(),
        "per-source limit"
    );
    let root = tempfile::tempdir().unwrap();
    let file = std::fs::File::create(root.path().join("large")).unwrap();
    file.set_len(limit as u64 + 1).unwrap();
    assert!(
        capture_file_assets(
            "rule-providers: {p: {type: file, behavior: domain, path: large}}",
            root.path()
        )
        .is_err()
    );
}

#[test]
fn provider_normalized_bytes_are_bounded_independently_of_raw_yaml_bytes() {
    use std::collections::BTreeMap;
    use zc::config::parse_with_assets;
    let body = format!("payload: [\"PROCESS-NAME,{}\"]", "\\L".repeat(4_500_000));
    assert!(body.len() < 16 * 1024 * 1024);
    let mut assets = BTreeMap::new();
    let mut source = "rules: ['MATCH,DIRECT']\nrule-providers:\n".to_owned();
    for index in 0..5 {
        assets.insert(format!("p{index}"), body.as_bytes().to_vec());
        source.push_str(&format!(
            "  p{index}: {{type: file, behavior: classical, path: p{index}}}\n"
        ));
    }
    let error = match parse_with_assets(&source, &assets) {
        Ok(_) => panic!("accepted over 64 MiB decoded entries"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("normalized bytes"), "{error:#}");
}

#[test]
fn obfs_rejections_preserve_defaults_and_never_disclose_secrets() {
    let base = "name: edge, type: ss, server: localhost, port: 443, cipher: aes-128-gcm, password: secret-marker";
    let config = Config::parse(&format!("proxies: [{{{base}}}]")).unwrap();
    assert!(!config.proxies()[2].udp);
    assert!(config.proxies()[2].obfs.is_none());
    for extra in [
        "plugin: obfs, plugin-opts: {mode: tls, host: cdn.test}",
        "plugin: obfs, plugin-opts: {mode: http, host: ''}",
        "plugin: obfs, plugin-opts: {mode: http, host: cdn.test, extra: 1}",
        "plugin: obfs, plugin-opts: 'mode=http;host=cdn.test'",
        "plugin: obfs, plugin-opts: {mode: http, host: cdn.test}, plugin_opts: {mode: http, host: cdn.test}",
        "plugin: obfs, plugin-opts: {mode: http, host: \"bad\\r\\nhost\"}",
        "plugin: obfs, plugin-opts: {mode: http, host: \"bad\\0host\"}",
        "plugin: v2ray-plugin, plugin-opts: {mode: http, host: cdn.test}",
    ] {
        let error = match Config::parse(&format!("proxies: [{{{base}, {extra}}}]")) {
            Ok(_) => panic!("accepted unsupported obfs"),
            Err(error) => error,
        };
        assert!(!format!("{error:#}").contains("secret-marker"));
    }
    let valid = Config::parse(&format!("proxies: [{{{base}, udp: true, plugin: obfs-local, plugin_opts: {{mode: http, host: cdn.test}}}}]")).unwrap();
    assert!(valid.proxies()[2].udp);
    assert_eq!(valid.proxies()[2].obfs.as_ref().unwrap().host, "cdn.test");
}

#[tokio::test]
async fn provider_configs_without_final_match_get_the_managed_reject_fallback() {
    use std::collections::BTreeMap;
    use zc::{config::parse_with_assets, target::Target};
    let source = "rule-providers: {p: {type: file, behavior: domain, path: p}}\nrules: ['RULE-SET,p,DIRECT']";
    let config = parse_with_assets(
        source,
        &BTreeMap::from([("p".into(), b"example.com".to_vec())]),
    )
    .unwrap();
    assert_eq!(
        config
            .route(&Target::new("example.com", 443).unwrap())
            .await
            .unwrap()
            .proxy
            .name,
        "DIRECT"
    );
    assert_eq!(
        config
            .route(&Target::new("other.test", 443).unwrap())
            .await
            .unwrap()
            .proxy
            .name,
        "REJECT"
    );
    assert_eq!(
        config.rules_json()["rules"][1],
        serde_json::json!({"type":"MATCH", "payload":"", "target":"REJECT"})
    );
}

#[tokio::test]
async fn named_direct_and_reject_are_real_selectable_leaves() {
    use zc::{config::ProxyKind, target::Target};
    let config = Config::parse("proxies: [{name: local, type: direct}, {name: blocked, type: reject}]\nproxy-groups: [{name: choice, type: select, proxies: [local, blocked]}]\nrules: ['MATCH,choice']").unwrap();
    let target = Target::new("127.0.0.1", 80).unwrap();
    let route = config.route(&target).await.unwrap();
    assert_eq!(route.proxy.name, "local");
    assert!(matches!(route.proxy.kind, ProxyKind::Direct));
    config.select("choice", "blocked").unwrap();
    let route = config.route(&target).await.unwrap();
    assert_eq!(route.proxy.name, "blocked");
    assert!(matches!(route.proxy.kind, ProxyKind::Reject));
    for kind in ["direct", "reject"] {
        for metadata in [
            "network: ws",
            "ws-opts: {}",
            "grpc-opts: {}",
            "plugin: obfs, plugin-opts: {mode: http, host: example.com}",
            "plugin-opts: {mode: http, host: example.com}",
        ] {
            assert!(
                Config::parse(&format!(
                    "proxies: [{{name: leaf, type: {kind}, {metadata}}}]\nrules: ['MATCH,leaf']"
                ))
                .is_err(),
                "{kind}: {metadata}"
            );
        }
        for name in ["DIRECT", "REJECT"] {
            assert!(Config::parse(&format!("proxies: [{{name: {name}, type: {kind}}}]")).is_err());
        }
    }
    for kind in ["ss", "trojan"] {
        assert!(Config::parse(&format!("proxies: [{{name: remote, type: {kind}}}]")).is_err());
    }
}

#[test]
fn json_documents_preserve_yaml_security_and_value_boundaries() {
    use zc::config::parse_document;
    let valid = r#"{"extension":{"text":"秘密\n\u0000","values":[true,false,null,42,-7,1.25]},"rules":["MATCH,DIRECT"]}"#;
    assert_eq!(
        parse_document(valid).unwrap(),
        serde_json::from_str::<serde_json::Value>(valid).unwrap()
    );
    // JSON-looking flow YAML remains a supported input syntax.
    assert_eq!(
        parse_document(r#"{"rules": ['MATCH,DIRECT']}"#).unwrap()["rules"][0],
        "MATCH,DIRECT"
    );
    for source in [
        r#"{"password":"PRIVATE_MARKER","password":"duplicate"}"#,
        r#"{"extension":{"x":1,"x":2}}"#,
        r#"{"extension":{"<<":{}}}"#,
        r#"{"password":"PRIVATE_MARKER","x":[}"#,
        r#"{"x":1} {"x":2}"#,
        r#"{"x": &anchor [1]}"#,
        r#"{"x": !include "/PRIVATE_MARKER"}"#,
        "[]",
        "null",
        "true",
        "42",
        "\"PRIVATE_MARKER\"",
    ] {
        let error = parse_document(source).unwrap_err().to_string();
        assert!(!error.contains("PRIVATE_MARKER"), "{error}");
    }
    // Zig root is depth zero; 128 nested collections are accepted.
    for depth in [128, 129, 130] {
        let source = format!("{}0{}", "{\"x\":".repeat(depth), "}".repeat(depth));
        assert_eq!(
            parse_document(&source).is_ok(),
            depth <= 129,
            "depth {depth}"
        );
    }
    for count in [262143, 262144] {
        let source = format!("{{\"extension\":[{}]}}", vec!["0"; count].join(","));
        assert_eq!(parse_document(&source).is_ok(), count < 262144);
    }
    let source = format!("{{\"x\":\"{}\"}}", "x".repeat(16 * 1024 * 1024 - 8));
    assert_eq!(source.len(), 16 * 1024 * 1024);
    assert!(parse_document(&source).is_ok());
    assert!(parse_document(&(source + " ")).is_err());
}

#[test]
fn json_fast_path_keeps_yaml_scalar_interpretation() {
    use zc::config::parse_document;
    for scalar in [
        "0",
        "-0",
        "9223372036854775807",
        "9223372036854775808",
        "18446744073709551616",
        "-9223372036854775809",
        "1.2345678901234567",
        "1e-300",
        "1e300",
        "true",
        "null",
        r#""\u0000\u000b\u007f""#,
        r#""\u0085\u2028\u2029""#,
        r#""\ud83d\ude00""#,
        r#""\ud800""#,
        r#""\ufffe\uffff""#,
        "\"literal\u{0085}line\"",
        "\"literal\u{2028}line\"",
        "\"literal\u{007f}control\"",
    ] {
        let source = format!("{{\"x\":{scalar}}}");
        let reference = serde_saphyr::from_multiple::<serde_json::Value>(&source);
        match (parse_document(&source), reference) {
            (Ok(actual), Ok(expected)) => assert_eq!(actual, expected[0], "{scalar}"),
            (Err(_), Err(_)) => {}
            _ => panic!("JSON and YAML admission differ for {scalar}"),
        }
    }
}

#[tokio::test]
async fn strict_missing_empty_and_unmatched_rules_keep_zig_reject_canonical_bytes() {
    use zc::{
        override_script::{dump_config_json, dump_config_yaml, runtime_source},
        target::Target,
    };
    let header = "port: 0\nsocks-port: 0\nmixed-port: 0\nredir-port: 0\ntproxy-port: 0\nallow-lan: false\nipv6: true\nbind-address: \"*\"\nmode: \"rule\"\nlog-level: \"info\"\nidle-session-check-interval: 30\nidle-session-timeout: 30\nmin-idle-session: 0\nproxies: []\nproxy-groups: []\nrules:\n";
    // Exact strict CLI dump bytes from zig-out/bin/zc, not its legacy parse() seam.
    for (source, extra) in [
        ("mode: rule\n", ""),
        ("rules: []\n", ""),
        (
            "rules: ['DOMAIN,only.example,DIRECT']\n",
            "  - \"DOMAIN,only.example,DIRECT\"\n",
        ),
    ] {
        assert_eq!(
            dump_config_yaml(source.as_bytes()).unwrap(),
            format!("{header}{extra}  - \"MATCH,REJECT\"\n")
        );
        let json: serde_json::Value =
            serde_json::from_str(&dump_config_json(source.as_bytes()).unwrap()).unwrap();
        assert_eq!(
            json["rules"].as_array().unwrap().last().unwrap(),
            "MATCH,REJECT"
        );
        let config = Config::parse(&runtime_source(source.as_bytes()).unwrap()).unwrap();
        assert_eq!(
            config
                .route(&Target::new("127.0.0.1", 23457).unwrap())
                .await
                .unwrap()
                .proxy
                .name,
            "REJECT"
        );
    }
    for source in [
        "proxies: [{name: bad, type: unsupported}]",
        "rules: ['MATCH,unknown']",
    ] {
        assert!(
            runtime_source(source.as_bytes())
                .and_then(|source| Config::parse(&source))
                .is_err()
        );
    }
}

#[test]
fn yaml_depth_matches_strict_zig_root_plus_128_nested_collections() {
    use zc::config::parse_document;
    for depth in [127, 128, 129, 10_000] {
        let flow = format!("extension: {}0{}\n", "[".repeat(depth), "]".repeat(depth));
        assert_eq!(parse_document(&flow).is_ok(), depth <= 128, "flow {depth}");
        if depth < 1000 {
            let block = (0..depth)
                .map(|n| format!("{}x:\n", "  ".repeat(n)))
                .collect::<String>()
                + &format!("{}leaf: 0\n", "  ".repeat(depth));
            assert_eq!(
                parse_document(&block).is_ok(),
                depth <= 128,
                "block {depth}"
            );
            if depth <= 128 {
                assert!(zc::override_script::dump_config_yaml(block.as_bytes()).is_ok());
            }
        }
    }
}
