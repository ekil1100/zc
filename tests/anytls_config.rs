use zc::{
    config::Config,
    override_script::{materialize_source, runtime_source},
};

fn source(extra: &str) -> String {
    format!(
        "proxies: [{{name: edge, type: anytls, server: localhost, port: 443, password: fixture-password{extra}}}]\nrules: ['MATCH,DIRECT']\n"
    )
}

#[test]
fn anytls_native_config_survives_materialization_and_reports_its_type() {
    for extra in [
        "",
        ", network: tcp, udp: false",
        ", sni: front.example, skip-cert-verify: true, disable-reuse: true",
    ] {
        let input = source(extra);
        let config = Config::parse(&input).unwrap();
        assert_eq!(config.proxies_json()["proxies"][0]["type"], "AnyTLS");
        for patch in [b"".as_slice(), b"log-level: debug\n"] {
            let materialized = materialize_source(input.as_bytes(), patch).unwrap();
            Config::parse(&runtime_source(&materialized).unwrap()).unwrap();
        }
    }
}

#[test]
fn anytls_rejects_unsupported_fields_before_canonical_or_override_can_erase_them() {
    for extra in [
        ", udp: true",
        ", network: ws",
        ", disable-reuse: false",
        ", alpn: [h2]",
        ", client-fingerprint: chrome",
        ", idle-session-timeout: 30",
        ", min-idle-session: 0",
        ", idle-session-check-interval: 30",
        ", client-metadata: secret",
        ", typo: private-field-value",
        ", cipher: aes-128-gcm",
        ", tls: true",
        ", alterId: 1",
        ", plugin: obfs",
        ", sni: 127.0.0.1",
    ] {
        let input = source(extra);
        assert!(Config::parse(&input).is_err(), "accepted {extra}");
        for patch in [b"".as_slice(), b"log-level: debug\n"] {
            let result = materialize_source(input.as_bytes(), patch)
                .and_then(|s| Config::parse(&runtime_source(&s)?));
            assert!(result.is_err(), "canonical accepted {extra}");
        }
        let result = materialize_source(source("").as_bytes(), input.as_bytes())
            .and_then(|s| Config::parse(&runtime_source(&s)?));
        assert!(result.is_err(), "override accepted {extra}");
    }
}

#[tokio::test]
async fn anytls_cli_preparation_preserves_native_tls_and_rejects_unselected_nodes() {
    use zc::{
        override_script::CliOptions,
        service::{PrepareOptions, prepare, prepared_config},
    };
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("source.yaml");
    for extra in ["", ", alpn: [h2]"] {
        std::fs::write(&path, source(extra)).unwrap();
        let result = prepare(PrepareOptions {
            config: Some(path.to_str().unwrap().into()),
            port: Some(23457),
            foreground: true,
            command: "start".into(),
            override_options: CliOptions::default(),
        })
        .await;
        if extra.is_empty() {
            let prepared = result.unwrap();
            assert_eq!(prepared.port, 23457);
            prepared_config(&prepared).unwrap();
        } else {
            assert!(result.is_err());
        }
    }
}

#[test]
fn anytls_disable_reuse_does_not_change_existing_protocol_canonical_bytes() {
    use zc::override_script::dump_config_yaml;
    for kind in ["trojan", "ss"] {
        let base = format!(
            "proxies: [{{name: old, type: {kind}, server: localhost, port: 443, password: password}}]\nrules: ['MATCH,DIRECT']"
        );
        let with_ignored_field = base.replace(
            "password: password",
            "password: password, disable-reuse: true",
        );
        assert_eq!(
            dump_config_yaml(base.as_bytes()).unwrap(),
            dump_config_yaml(with_ignored_field.as_bytes()).unwrap()
        );
    }
    let canonical = dump_config_yaml(source(", disable-reuse: true").as_bytes()).unwrap();
    assert!(canonical.contains("disable-reuse: true"));
}
