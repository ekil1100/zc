use zc::{
    override_script::CliOptions,
    service::{PrepareOptions, prepare},
};

#[tokio::test]
async fn explicit_preparation_normalizes_port_and_accepts_native_udp_without_state() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.yaml");
    std::fs::write(&source, "mixed-port: 23456\nproxies: [{name: edge, type: ss, server: localhost, port: 443, cipher: aes-128-gcm, password: secret, udp: true}]\nrules: ['MATCH,edge']\n").unwrap();
    let result = prepare(PrepareOptions {
        config: Some(source.to_str().unwrap().into()),
        port: Some(23457),
        foreground: true,
        command: "start".into(),
        override_options: CliOptions::default(),
    })
    .await
    .unwrap();
    assert_eq!(result.port, 23457);
    assert!(result.identity.is_none());
    assert_eq!(result.invocation.source_path.as_deref(), source.to_str());
    assert_eq!(result.invocation.port_override, Some(23457));
    let value: serde_json::Value = serde_saphyr::from_str(&result.source).unwrap();
    assert_eq!(value["mixed-port"], 23457);
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 1);
}

#[tokio::test]
async fn standalone_listener_is_not_silently_converted_into_mixed() {
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("standalone.yaml");
    std::fs::write(&source, "socks-port: 23456\nrules: ['MATCH,DIRECT']\n").unwrap();
    let error = prepare(PrepareOptions {
        config: Some(source.to_str().unwrap().into()),
        port: Some(23457),
        ..Default::default()
    })
    .await
    .unwrap_err();
    assert!(error.to_string().contains("standalone"));
}

#[tokio::test]
async fn runtime_projection_ignores_only_typed_inactive_native_protocol_metadata() {
    use zc::{config::ProxyKind, service::prepared_config};
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("metadata.yaml");
    for (kind, metadata) in [
        (
            "ss",
            "cipher: aes-128-gcm, sni: unused, skip-cert-verify: true",
        ),
        (
            "trojan",
            "cipher: unused, tls: false, sni: example.com, skip-cert-verify: true",
        ),
    ] {
        std::fs::write(&source, format!("proxies: [{{name: edge, type: {kind}, server: localhost, port: 443, password: secret, uuid: unused, alterId: 42, {metadata}}}]\nrules: ['MATCH,edge']\n")).unwrap();
        let prepared = prepare(PrepareOptions {
            config: Some(source.to_str().unwrap().into()),
            port: Some(23457),
            ..Default::default()
        })
        .await
        .unwrap();
        // Projection must not rewrite the frozen source or its credential metadata.
        let frozen: serde_json::Value = serde_json::from_str(&prepared.source).unwrap();
        assert_eq!(frozen["proxies"][0]["uuid"], "unused");
        assert_eq!(frozen["proxies"][0]["alterId"], 42);
        let config = prepared_config(&prepared).unwrap();
        let proxy = &config.proxies()[2];
        match &proxy.kind {
            ProxyKind::Shadowsocks {
                cipher, password, ..
            } => {
                assert_eq!(cipher, "aes-128-gcm");
                assert_eq!(password, "secret");
            }
            ProxyKind::Trojan {
                sni,
                skip_cert_verify,
                ..
            } => {
                assert_eq!(sni.as_deref(), Some("example.com"));
                assert!(*skip_cert_verify);
            }
            _ => panic!("native proxy kind changed"),
        }
    }
    for (kind, metadata) in [
        ("ss", "cipher: aes-128-gcm, tls: true"),
        ("ss", "cipher: aes-256-cfb"),
        ("ss", "cipher: aes-128-gcm, network: ws"),
        ("ss", "cipher: aes-128-gcm, plugin: unknown"),
        ("trojan", "network: grpc"),
        ("trojan", "grpc-opts: {}"),
        (
            "trojan",
            "plugin: obfs, plugin-opts: {mode: http, host: example.com}",
        ),
        ("trojan", "sni: '*.example.com'"),
        ("trojan", "sni: 127.0.0.1"),
        ("trojan", "uuid: 42"),
    ] {
        std::fs::write(&source, format!("proxies: [{{name: edge, type: {kind}, server: localhost, port: 443, password: secret, {metadata}}}]\nrules: ['MATCH,edge']\n")).unwrap();
        assert!(
            prepare(PrepareOptions {
                config: Some(source.to_str().unwrap().into()),
                port: Some(23457),
                ..Default::default()
            })
            .await
            .is_err(),
            "{kind}: {metadata}"
        );
    }
}

#[tokio::test]
async fn standalone_test_uses_stale_cache_but_proxy_test_refreshes_before_freezing() {
    use std::time::{Duration, SystemTime};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.yaml");
    let cache = dir.path().join("list");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    std::fs::write(&source, format!("rule-providers: {{list: {{type: http, behavior: domain, path: list, url: 'http://{}/rules', interval: 1}}}}\nrules: ['RULE-SET,list,DIRECT', 'MATCH,REJECT']\n", listener.local_addr().unwrap())).unwrap();
    std::fs::write(&cache, b"old.example\n").unwrap();
    std::fs::File::options()
        .write(true)
        .open(&cache)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(10))
        .unwrap();
    let options = PrepareOptions {
        config: Some(source.to_str().unwrap().into()),
        port: Some(23457),
        command: "test".into(),
        ..Default::default()
    };
    let frozen = tokio::time::timeout(Duration::from_secs(2), prepare(options.clone()))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(frozen.assets["list"], "old.example\n");
    assert!(
        tokio::time::timeout(Duration::from_millis(30), listener.accept())
            .await
            .is_err()
    );
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            request.push(stream.read_u8().await.unwrap());
            assert!(request.len() <= 16 * 1024);
        }
        stream
            .write_all(
                b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnew.example\n",
            )
            .await
            .unwrap();
    });
    let refreshed = prepare(PrepareOptions {
        command: "proxy test".into(),
        ..options
    })
    .await
    .unwrap();
    peer.await.unwrap();
    assert_eq!(refreshed.assets["list"], "new.example\n");
    std::fs::write(cache, b"changed.example\n").unwrap();
    let target = zc::target::Target::new("old.example", 80).unwrap();
    assert_eq!(
        zc::service::prepared_config(&frozen)
            .unwrap()
            .route(&target)
            .await
            .unwrap()
            .proxy
            .name,
        "DIRECT"
    );
    assert_eq!(
        zc::service::prepared_config(&refreshed)
            .unwrap()
            .route(&target)
            .await
            .unwrap()
            .proxy
            .name,
        "REJECT"
    );
}

#[tokio::test]
async fn http_cache_cannot_overwrite_its_configuration_source() {
    use std::time::{Duration, SystemTime};
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.yaml");
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let bytes = format!(
        "rule-providers: {{list: {{type: http, behavior: domain, path: source.yaml, url: 'http://{}/rules', interval: 1}}}}\nrules: ['RULE-SET,list,DIRECT']\n",
        listener.local_addr().unwrap()
    );
    std::fs::write(&source, &bytes).unwrap();
    std::fs::File::options()
        .write(true)
        .open(&source)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(10))
        .unwrap();
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            request.push(stream.read_u8().await.unwrap());
            assert!(request.len() <= 16 * 1024);
        }
        stream
            .write_all(
                b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnew.example\n",
            )
            .await
            .unwrap();
    });
    let result = prepare(PrepareOptions {
        config: Some(source.to_str().unwrap().into()),
        port: Some(23457),
        ..Default::default()
    })
    .await;
    peer.abort();
    assert!(result.is_err());
    assert_eq!(std::fs::read_to_string(source).unwrap(), bytes);
}

#[tokio::test]
async fn managed_deferred_remote_metadata_never_fetches_or_mutates_revision_inputs() {
    use zc::{
        service::{Loaded, prepare_loaded},
        store::{ActiveIdentity, Bundle, Desired},
    };
    let dir = tempfile::tempdir().unwrap();
    let remote = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let source = format!(
        "rule-providers: {{list: {{type: http, behavior: domain, path: cache, url: 'http://{}/'}}}}\nrules: ['MATCH,REJECT']\n",
        remote.local_addr().unwrap()
    );
    let bundle = Bundle::from_memory(source.as_bytes(), None, Default::default()).unwrap();
    let frozen = bundle.clone();
    let prepared = prepare_loaded(
        Loaded {
            bundle,
            identity: Some(ActiveIdentity {
                key: "fixture".into(),
                revision: "frozen".into(),
            }),
            desired: Desired::default(),
            source_path: None,
        },
        PrepareOptions {
            port: Some(23457),
            ..Default::default()
        },
    )
    .await
    .unwrap();
    assert!(prepared.assets.is_empty());
    assert_eq!(frozen.source(), source.as_bytes());
    assert!(frozen.assets().is_empty());
    assert!(
        tokio::time::timeout(std::time::Duration::from_millis(30), remote.accept())
            .await
            .is_err()
    );
    assert_eq!(std::fs::read_dir(dir.path()).unwrap().count(), 0);
    let referenced = source.replace("MATCH,REJECT", "RULE-SET,list,DIRECT");
    assert!(Bundle::from_memory(referenced.as_bytes(), None, Default::default()).is_err());
}

#[tokio::test]
async fn configuration_without_remote_assets_does_not_require_a_cache_directory() {
    let source = tempfile::NamedTempFile::new_in("/tmp").unwrap();
    std::fs::write(source.path(), "rules: ['MATCH,REJECT']\n").unwrap();
    let prepared = prepare(PrepareOptions {
        config: Some(source.path().to_str().unwrap().into()),
        port: Some(23457),
        ..Default::default()
    })
    .await
    .unwrap();
    assert!(prepared.assets.is_empty());
}

#[tokio::test]
async fn http_cache_filesystem_alias_cannot_overwrite_source() {
    use std::os::unix::fs::MetadataExt;
    use std::time::{Duration, SystemTime};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    for (name, alias) in [
        ("source.yaml", "SOURCE.yaml"),
        ("café.yaml", "cafe\u{301}.yaml"),
    ] {
        let dir = tempfile::tempdir().unwrap();
        let source = dir.path().join(name);
        let cache = dir.path().join(alias);
        std::fs::write(&source, b"probe").unwrap();
        let Ok(metadata) = std::fs::metadata(&cache) else {
            continue;
        };
        if metadata.ino() != std::fs::metadata(&source).unwrap().ino() {
            continue;
        }
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let bytes = format!(
            "rule-providers: {{p: {{type: http, behavior: domain, path: '{alias}', url: 'http://{}/', interval: 1}}}}\nrules: ['RULE-SET,p,DIRECT']\n",
            listener.local_addr().unwrap()
        );
        std::fs::write(&source, &bytes).unwrap();
        std::fs::File::options()
            .write(true)
            .open(&source)
            .unwrap()
            .set_modified(SystemTime::now() - Duration::from_secs(10))
            .unwrap();
        let peer = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                request.push(stream.read_u8().await.unwrap());
            }
            let _ = stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnew.example\n").await;
        });
        let result = prepare(PrepareOptions {
            config: Some(source.to_str().unwrap().into()),
            port: Some(23457),
            ..Default::default()
        })
        .await;
        peer.abort();
        assert_eq!(
            std::fs::read(&source).unwrap(),
            bytes.as_bytes(),
            "source overwritten via {alias}"
        );
        assert!(result.is_err(), "accepted source alias {alias}");
    }
}

#[tokio::test]
async fn expanded_provider_budget_failure_preserves_old_cache() {
    use std::time::{Duration, SystemTime};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.yaml");
    let cache = dir.path().join("rules");
    std::fs::write(&cache, b"old.example\n").unwrap();
    std::fs::File::options()
        .write(true)
        .open(&cache)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(10))
        .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let input = format!(
        "rule-providers: {{p: {{type: http, behavior: domain, path: rules, url: 'http://{}/', interval: 1}}}}\nrules: ['RULE-SET,p,DIRECT', 'RULE-SET,p,DIRECT', 'MATCH,REJECT']\n",
        listener.local_addr().unwrap()
    );
    std::fs::write(&source, &input).unwrap();
    let peer = tokio::spawn(async move {
        let (mut stream, _) = listener.accept().await.unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            request.push(stream.read_u8().await.unwrap());
        }
        let body = "a.test\n".repeat(140_000);
        stream
            .write_all(
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
                    body.len()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        stream.write_all(body.as_bytes()).await.unwrap();
    });
    let error = prepare(PrepareOptions {
        config: Some(source.to_str().unwrap().into()),
        port: Some(23457),
        ..Default::default()
    })
    .await
    .unwrap_err();
    peer.await.unwrap();
    assert!(error.to_string().contains("limit"), "{error:#}");
    assert_eq!(std::fs::read(&cache).unwrap(), b"old.example\n");
    assert_eq!(std::fs::read(&source).unwrap(), input.as_bytes());
}

#[tokio::test]
async fn source_identity_stays_protected_across_http_await() {
    use std::time::{Duration, SystemTime};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    let dir = tempfile::tempdir().unwrap();
    let source = dir.path().join("source.yaml");
    let cache = dir.path().join("rules");
    std::fs::write(&cache, b"old.example\n").unwrap();
    std::fs::File::options()
        .write(true)
        .open(&cache)
        .unwrap()
        .set_modified(SystemTime::now() - Duration::from_secs(10))
        .unwrap();
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let input = format!(
        "rule-providers: {{p: {{type: http, behavior: domain, path: rules, url: 'http://{}/', interval: 1}}}}\nrules: ['RULE-SET,p,DIRECT']\n",
        listener.local_addr().unwrap()
    );
    std::fs::write(&source, &input).unwrap();
    let prepared = prepare(PrepareOptions {
        config: Some(source.to_str().unwrap().into()),
        port: Some(23457),
        ..Default::default()
    });
    tokio::pin!(prepared);
    let (mut peer, _) = tokio::select! {
        result = &mut prepared => panic!("completed before response: {result:?}"),
        accepted = listener.accept() => accepted.unwrap(),
    };
    let mut request = Vec::new();
    tokio::select! {
        result = &mut prepared => panic!("completed before request: {result:?}"),
        _ = async {
            while !request.ends_with(b"\r\n\r\n") {
                request.push(peer.read_u8().await.unwrap());
                assert!(request.len() <= 16 * 1024);
            }
        } => (),
    }
    std::fs::rename(&source, &cache).unwrap();
    peer.write_all(
        b"HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nnew.example\n",
    )
    .await
    .unwrap();
    assert!(prepared.await.is_err());
    assert_eq!(std::fs::read(&cache).unwrap(), input.as_bytes());
}
