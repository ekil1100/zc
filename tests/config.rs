use zc::{
    config::{Config, ProxyKind},
    target::Target,
};

#[tokio::test]
async fn builtin_match_is_explicit_and_unmatched_routes_fail_closed() {
    let config = Config::parse("rules: [MATCH,REJECT]");
    assert!(
        config.is_err(),
        "unquoted rule must not become two valid rules"
    );
    let config = Config::parse("rules: ['MATCH,REJECT']").unwrap();
    assert!(config.bind_address().is_loopback());
    assert_eq!(config.proxies().len(), 2);
    assert!(matches!(
        config
            .route(&Target::new("localhost", 443).unwrap())
            .await
            .unwrap()
            .proxy
            .kind,
        ProxyKind::Reject
    ));
    let empty = Config::parse("{}").unwrap();
    assert!(
        empty
            .route(&Target::new("127.0.0.1", 443).unwrap())
            .await
            .is_err()
    );
}

#[test]
fn listener_declarations_are_strict_and_never_override_cli_port() {
    for (source, expected) in [
        (
            "mixed-port: 12345\nmode: rule\nlog-level: warning\nallow-lan: false",
            "127.0.0.1",
        ),
        ("allow-lan: true", "0.0.0.0"),
        ("allow-lan: true\nbind-address: '*'", "0.0.0.0"),
        ("allow-lan: true\nbind-address: '::'", "::"),
        ("bind-address: '::1'", "::1"),
        ("bind-address: 127.0.0.2\nallow-lan: false", "127.0.0.2"),
    ] {
        assert_eq!(
            Config::parse(source).unwrap().bind_address().to_string(),
            expected
        );
    }
    for source in [
        "allow-lan: false\nbind-address: '*'",
        "bind-address: 0.0.0.0",
        "bind-address: example.com",
        "bind-address: '192.168.1.1'",
        "allow-lan: yes",
        "log-level: nonsense",
        "mixed-port: 0\nport: 12345",
        "mixed-port: 65536",
        "port: 12345",
        "socks-port: 12345",
        "redir-port: 12345",
        "tproxy-port: 12345",
        "dns: {}",
        "tun: {enable: false}",
        "proxy-providers: {}",
        "profile: {}",
        "ipv6: true",
        "unknown: false",
    ] {
        assert!(Config::parse(source).is_err(), "accepted {source}");
    }
}

#[tokio::test]
async fn static_tcp_proxies_preserve_credentials_and_normalize_cipher_alias() {
    for (cipher, expected) in [
        ("aes-128-gcm", "aes-128-gcm"),
        ("aes-256-gcm", "aes-256-gcm"),
        ("chacha20-ietf-poly1305", "chacha20-ietf-poly1305"),
        ("chacha20-poly1305", "chacha20-ietf-poly1305"),
    ] {
        let config = Config::parse(&format!("proxies:\n  - {{name: edge, type: ss, server: localhost, port: 443, password: 'secret: #value', cipher: {cipher}, udp: false, tls: false, network: tcp}}\nrules: ['MATCH,edge']")).unwrap();
        assert_eq!(config.proxies().len(), 3);
        let selected = config
            .route(&Target::new("example.com", 443).unwrap())
            .await
            .unwrap();
        assert_eq!(selected.proxy.name, "edge");
        match &selected.proxy.kind {
            ProxyKind::Shadowsocks {
                server,
                port,
                password,
                cipher,
            } => {
                assert_eq!(server, "localhost");
                assert_eq!(*port, 443);
                assert_eq!(password, "secret: #value");
                assert_eq!(cipher, expected);
            }
            _ => panic!("wrong proxy kind"),
        }
    }
    for (extra, expected) in [
        ("", false),
        (
            ", skip-cert-verify: true, tls: true, network: tcp, udp: false",
            true,
        ),
    ] {
        let config = Config::parse(&format!("proxies: [{{name: tls, type: trojan, server: '::1', port: 443, password: secret, sni: Example.COM{extra}}}]\nrules: ['MATCH,tls']")).unwrap();
        match &config.proxies()[2].kind {
            ProxyKind::Trojan {
                server,
                port,
                password,
                sni,
                skip_cert_verify,
            } => {
                assert_eq!(server, "::1");
                assert_eq!(*port, 443);
                assert_eq!(password, "secret");
                assert_eq!(sni.as_deref(), Some("Example.COM"));
                assert_eq!(*skip_cert_verify, expected);
            }
            _ => panic!("wrong proxy kind"),
        }
    }
}

#[test]
fn unsupported_proxy_capabilities_and_unsafe_values_are_rejected_without_secrets() {
    let base = "name: edge, type: ss, server: localhost, port: 443, password: top-secret-marker, cipher: aes-128-gcm";
    let mut invalid: Vec<String> = [
        ", plugin: ''",
        ", plugin: obfs",
        ", plugin-opts: {}",
        ", ws-opts: {}",
        ", grpc-opts: {}",
        ", network: ws",
        ", network: grpc",
        ", network: udp",
        ", tls: true",
        ", sni: example.com",
        ", skip-cert-verify: false",
        ", unknown: top-secret-marker",
        ", udp: null",
        ", tls: null",
        ", network: null",
        ", alpn: [h2]",
    ]
    .into_iter()
    .map(|extra| format!("{base}{extra}"))
    .collect();
    for (from, to) in [
        ("name: edge", "name: DIRECT"),
        ("name: edge", "name: REJECT"),
        ("name: edge", "name: ''"),
        ("name: edge", "name: 'bad,name'"),
        ("name: edge", "name: ' padded '"),
        ("type: ss", "type: vmess"),
        ("server: localhost", "server: 'bad/host'"),
        ("server: localhost", "server: '[::1]'"),
        ("port: 443", "port: 0"),
        ("password: top-secret-marker", "password: ''"),
        (
            "password: top-secret-marker",
            "password: \"top-secret-marker\\n\"",
        ),
        ("cipher: aes-128-gcm", "cipher: aes-256-cfb"),
        ("cipher: aes-128-gcm", "cipher: 2022-blake3-aes-128-gcm"),
    ] {
        invalid.push(base.replace(from, to));
    }
    for entry in invalid {
        let source = format!("proxies: [{{{entry}}}]\nrules: ['MATCH,DIRECT']");
        let error = match Config::parse(&source) {
            Ok(_) => panic!("accepted invalid proxy: {entry}"),
            Err(error) => error,
        };
        assert!(!format!("{error:#}").contains("top-secret-marker"));
        assert!(!format!("{error:?}").contains("proxies:"));
    }
    assert!(Config::parse(&format!("proxies: [{{{base}}}, {{{base}}}]")).is_err());
    for extra in [
        ", tls: false",
        ", cipher: aes-128-gcm",
        ", sni: 'bad/host'",
        ", sni: ''",
        ", sni: null",
        ", skip-cert-verify: null",
        ", network: ws",
    ] {
        assert!(Config::parse(&format!("proxies: [{{name: edge, type: trojan, server: localhost, port: 443, password: top-secret-marker{extra}}}]")).is_err());
    }
}

#[tokio::test]
async fn select_groups_choose_first_member_and_validate_all_branches_iteratively() {
    let config = Config::parse("proxy-groups:\n  - {name: outer, type: select, proxies: [inner, DIRECT]}\n  - {name: inner, type: select, proxies: [REJECT, DIRECT]}\nrules: ['MATCH,outer']").unwrap();
    assert_eq!(
        config
            .route(&Target::new("localhost", 443).unwrap())
            .await
            .unwrap()
            .proxy
            .name,
        "REJECT"
    );
    for source in [
        "proxy-groups: [{name: a, type: select, proxies: []}]",
        "proxy-groups: [{name: a, type: select, proxies: [a]}]",
        "proxy-groups: [{name: a, type: select, proxies: [DIRECT, a]}]",
        "proxy-groups: [{name: a, type: select, proxies: [DIRECT, b]}, {name: b, type: select, proxies: [a]}]",
        "proxy-groups: [{name: a, type: select, proxies: [DIRECT, missing]}]",
        "proxy-groups: [{name: DIRECT, type: select, proxies: [REJECT]}]",
        "proxy-groups: [{name: REJECT, type: select, proxies: [DIRECT]}]",
        "proxy-groups: [{name: a, type: select, proxies: [DIRECT]}, {name: a, type: select, proxies: [REJECT]}]",
        "proxy-groups: [{name: a, type: url-test, proxies: [DIRECT]}]",
        "proxy-groups: [{name: a, type: select, proxies: [DIRECT], use: [provider]}]",
        "rules: ['MATCH,missing']",
    ] {
        assert!(Config::parse(source).is_err(), "accepted {source}");
    }
    let mut source = String::from("proxy-groups:\n");
    for index in 0..1024 {
        let member = if index == 1023 {
            "REJECT".into()
        } else {
            format!("g{}", index + 1)
        };
        source.push_str(&format!(
            "  - {{name: g{index}, type: select, proxies: [{member}, DIRECT]}}\n"
        ));
    }
    source.push_str("rules: ['MATCH,g0']\n");
    let config = Config::parse(&source).unwrap();
    assert_eq!(
        config
            .route(&Target::new("localhost", 443).unwrap())
            .await
            .unwrap()
            .proxy
            .name,
        "REJECT"
    );
}

#[tokio::test]
async fn domain_rules_use_declaration_order_ascii_case_and_label_boundaries() {
    for (rule, cases) in [
        (
            "DOMAIN,Example.COM.,REJECT",
            vec![
                ("example.com", "REJECT"),
                ("EXAMPLE.COM.", "REJECT"),
                ("a.example.com", "DIRECT"),
                ("badexample.com", "DIRECT"),
            ],
        ),
        (
            "DOMAIN-SUFFIX,Example.COM.,REJECT",
            vec![
                ("example.com", "REJECT"),
                ("A.Example.Com.", "REJECT"),
                ("badexample.com", "DIRECT"),
                ("example.com.evil", "DIRECT"),
            ],
        ),
        (
            "DOMAIN-KEYWORD,AMPle.,REJECT",
            vec![
                ("EXAMPLE.COM.", "REJECT"),
                ("ample.org", "REJECT"),
                ("other.org", "DIRECT"),
            ],
        ),
        (
            "DOMAIN-KEYWORD,127,REJECT",
            vec![("127.0.0.1", "DIRECT"), ("host127.test", "REJECT")],
        ),
    ] {
        let config = Config::parse(&format!("rules: ['{rule}', 'MATCH,DIRECT']")).unwrap();
        for (host, expected) in cases {
            assert_eq!(
                config
                    .route(&Target::new(host, 443).unwrap())
                    .await
                    .unwrap()
                    .proxy
                    .name,
                expected,
                "{rule}: {host}"
            );
        }
    }
    for rules in [
        "['DOMAIN-SUFFIX,example.com,REJECT', 'DOMAIN,a.example.com,DIRECT']",
        "['MATCH,REJECT', 'DOMAIN,a.example.com,DIRECT']",
        "[' DOMAIN , a.example.com , REJECT ', 'MATCH,DIRECT']",
    ] {
        let config = Config::parse(&format!("rules: {rules}")).unwrap();
        assert_eq!(
            config
                .route(&Target::new("a.example.com", 443).unwrap())
                .await
                .unwrap()
                .proxy
                .name,
            "REJECT"
        );
    }
    let config = Config::parse("rules: ['DOMAIN,example.com,DIRECT']").unwrap();
    assert!(
        config
            .route(&Target::new("other.test", 443).unwrap())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn ip_and_destination_port_rules_match_in_order_using_real_socket_destination() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let config = Config::parse(&format!(
        "rules: ['DST-PORT,{},DIRECT', 'IP-CIDR,127.0.0.0/8,REJECT', 'MATCH,REJECT']",
        address.port()
    ))
    .unwrap();
    assert_eq!(
        config
            .route(&Target::new(address.ip().to_string(), address.port()).unwrap())
            .await
            .unwrap()
            .proxy
            .name,
        "DIRECT"
    );
    let (client, accepted) =
        tokio::join!(tokio::net::TcpStream::connect(address), listener.accept());
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    client.unwrap().write_all(b"route").await.unwrap();
    let mut bytes = [0; 5];
    accepted.unwrap().0.read_exact(&mut bytes).await.unwrap();
    assert_eq!(&bytes, b"route");
    for (rule, host, port, expected) in [
        ("IP-CIDR,192.0.2.0/24,REJECT", "192.0.2.255", 443, "REJECT"),
        ("IP-CIDR,192.0.2.0/24,REJECT", "192.0.3.0", 443, "DIRECT"),
        ("IP-CIDR,0.0.0.0/0,REJECT", "::1", 443, "DIRECT"),
        (
            "IP-CIDR6,2001:db8::/32,REJECT",
            "2001:db8::1",
            443,
            "REJECT",
        ),
        ("IP-CIDR6,::/0,REJECT", "192.0.2.1", 443, "DIRECT"),
        ("IP-CIDR6,::1/128,REJECT,no-resolve", "::1", 443, "REJECT"),
        (
            "IP-CIDR,127.0.0.1/32,REJECT,no-resolve",
            "127.0.0.1",
            443,
            "REJECT",
        ),
        ("DST-PORT,440-443,REJECT", "example.com", 440, "REJECT"),
        ("DST-PORT,440-443,REJECT", "example.com", 443, "REJECT"),
        ("DST-PORT,440-443,REJECT", "example.com", 444, "DIRECT"),
        ("DST-PORT,1-65535,REJECT", "::1", 65535, "REJECT"),
    ] {
        let config = Config::parse(&format!("rules: ['{rule}', 'MATCH,DIRECT']")).unwrap();
        assert_eq!(
            config
                .route(&Target::new(host, port).unwrap())
                .await
                .unwrap()
                .proxy
                .name,
            expected,
            "{rule}: {host}:{port}"
        );
    }
    for rule in [
        "RULE-SET,list,DIRECT",
        "DOMAIN,,DIRECT",
        "DOMAIN,bad name,DIRECT",
        "DOMAIN,example.com,DIRECT,no-resolve",
        "MATCH,DIRECT,extra",
        "MATCH",
        "DST-PORT,0,DIRECT",
        "DST-PORT,65536,DIRECT",
        "DST-PORT,443-440,DIRECT",
        "DST-PORT,1-2-3,DIRECT",
        "DST-PORT,+443,DIRECT",
        "IP-CIDR,::/0,DIRECT",
        "IP-CIDR6,0.0.0.0/0,DIRECT",
        "IP-CIDR,1.2.3.4/33,DIRECT",
        "IP-CIDR,127.0.0.0/8,DIRECT,resolve",
        "IP-CIDR,127.0.0.0/8,DIRECT,no-resolve,extra",
        "DST-PORT,443,DIRECT,no-resolve",
    ] {
        assert!(
            Config::parse(&format!("rules: ['{rule}']")).is_err(),
            "accepted {rule}"
        );
    }
}

#[tokio::test]
async fn domain_ip_rules_resolve_lazily_and_preserve_no_resolve_even_after_lookup() {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    let target = Target::new("localhost", port).unwrap();
    let config = Config::parse(
        "rules: ['IP-CIDR,127.0.0.0/8,DIRECT', 'IP-CIDR6,::1/128,DIRECT', 'MATCH,REJECT']",
    )
    .unwrap();
    let route = config.route(&target).await.unwrap();
    assert_eq!(route.proxy.name, "DIRECT");
    let address =
        std::net::SocketAddr::new(route.target.host().parse().unwrap(), route.target.port());
    let (client, accepted) =
        tokio::join!(tokio::net::TcpStream::connect(address), listener.accept());
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    client.unwrap().write_all(b"dns").await.unwrap();
    let mut bytes = [0; 3];
    accepted.unwrap().0.read_exact(&mut bytes).await.unwrap();
    assert_eq!(&bytes, b"dns");
    for rules in [
        "['IP-CIDR,127.0.0.0/8,REJECT,no-resolve', 'IP-CIDR6,::1/128,REJECT,no-resolve', 'MATCH,DIRECT']",
        "['IP-CIDR,192.0.2.0/24,REJECT', 'IP-CIDR,127.0.0.0/8,REJECT,no-resolve', 'IP-CIDR6,::1/128,REJECT,no-resolve', 'MATCH,DIRECT']",
        "['DOMAIN,localhost,DIRECT', 'IP-CIDR,0.0.0.0/0,REJECT']",
    ] {
        let config = Config::parse(&format!("rules: {rules}")).unwrap();
        assert_eq!(config.route(&target).await.unwrap().proxy.name, "DIRECT");
    }
}

#[test]
fn earlier_match_and_no_resolve_need_no_dns_or_timer_driver() {
    let runtime = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap();
    for rules in [
        "['MATCH,REJECT', 'IP-CIDR,0.0.0.0/0,DIRECT']",
        "['IP-CIDR,0.0.0.0/0,DIRECT,no-resolve', 'IP-CIDR6,::/0,DIRECT,no-resolve', 'MATCH,REJECT']",
    ] {
        let config = Config::parse(&format!("rules: {rules}")).unwrap();
        let target = Target::new("nonexistent.invalid", 443).unwrap();
        assert_eq!(
            runtime.block_on(config.route(&target)).unwrap().proxy.name,
            "REJECT"
        );
    }
}

#[test]
fn configuration_collection_limits_are_inclusive_and_enforced_during_parsing() {
    for (count, valid) in [(1025, false), (1024, true)] {
        let mut source = String::from("proxy-groups:\n");
        for index in 0..count {
            source.push_str(&format!(
                "- {{name: g{index}, type: select, proxies: [DIRECT]}}\n"
            ));
        }
        assert_eq!(Config::parse(&source).is_ok(), valid, "group count {count}");
    }
    for (count, valid) in [(4096, true), (4097, false)] {
        let mut source = String::from("proxies:\n");
        for index in 0..count {
            source.push_str(&format!("- {{name: p{index}, type: ss, server: localhost, port: 443, password: secret, cipher: aes-128-gcm}}\n"));
        }
        assert_eq!(Config::parse(&source).is_ok(), valid, "proxy count {count}");
    }
    for (count, valid) in [(5122, true), (5123, false)] {
        let source = format!(
            "proxy-groups: [{{name: g, type: select, proxies: [{}]}}]",
            vec!["DIRECT"; count].join(",")
        );
        assert_eq!(
            Config::parse(&source).is_ok(),
            valid,
            "member count {count}"
        );
    }
    for (count, valid) in [(262143, true), (262144, false)] {
        let source = format!("rules:\n{}", "- MATCH,DIRECT\n".repeat(count));
        assert_eq!(Config::parse(&source).is_ok(), valid, "rule count {count}");
    }
    let limit = 16 * 1024 * 1024;
    let source = format!("{{}} #{}", "x".repeat(limit - 4));
    assert!(Config::parse(&source).is_ok());
    assert!(Config::parse(&(source + "x")).is_err());
}

#[test]
fn yaml_structure_cannot_hide_unsupported_fields_or_exhaust_parser_budgets() {
    for source in [
        "rules: ['MATCH,DIRECT']\nrules: ['MATCH,REJECT']",
        "allow-lan: true\nallow-lan: false",
        "mode: direct\nmode: rule",
        "proxies: [{name: p, type: ss, type: trojan, server: localhost, port: 443, password: secret, cipher: aes-128-gcm}]",
        "proxies: [{name: p, type: ss, server: localhost, port: 443, password: secret, cipher: aes-128-gcm, udp: true, udp: false}]",
        "proxies: [{name: p, type: ss, server: localhost, port: 443, password: secret, cipher: aes-128-gcm, plugin: obfs, plugin: ''}]",
        "<<: {dns: {enable: true}}\nrules: ['MATCH,DIRECT']",
        "!!merge <<: {dns: {enable: true}}",
        "'<<': {dns: {enable: true}}",
        "rules: &r ['MATCH,DIRECT']",
        "rules: [ &r 'MATCH,DIRECT', *r ]",
        "proxy-groups: [{name: a, type: select, proxies: &members [DIRECT]}, {name: b, type: select, proxies: *members}]",
        "rules: !custom ['MATCH,DIRECT']",
        "rules: !include other.yaml",
        "{}\n---\nrules: ['MATCH,DIRECT']",
        "[]",
        "null",
        "rules: null",
        "proxies: null",
        "mode: null",
    ] {
        assert!(Config::parse(source).is_err(), "accepted {source}");
    }
    let nested = format!(
        "rules: {}'sensitive-marker'{}",
        "[".repeat(10000),
        "]".repeat(10000)
    );
    let error = match Config::parse(&nested) {
        Ok(_) => panic!("accepted excessive nesting"),
        Err(error) => error,
    };
    assert!(!format!("{error:#}").contains("sensitive-marker"));
    // YAML's two-byte escape expands into a three-byte Unicode line separator.
    let expanded = format!(
        "proxies: [{{name: p, type: ss, server: localhost, port: 443, cipher: aes-128-gcm, password: \"{}\"}}]",
        "\\L".repeat(5_592_406)
    );
    assert!(expanded.len() < 16 * 1024 * 1024);
    assert!(
        Config::parse(&expanded).is_err(),
        "decoded scalar budget must be enforced independently of source length"
    );
}

#[test]
fn trojan_tls_names_are_valid_before_connector_construction() {
    for extra in [
        ", sni: 127.0.0.1",
        ", sni: example.com.",
        ", sni: _service.example.com",
        ", sni: '-bad.example.com'",
    ] {
        let source = format!(
            "proxies: [{{name: tls, type: trojan, server: localhost, port: 443, password: secret{extra}}}]"
        );
        assert!(Config::parse(&source).is_err(), "accepted {extra}");
    }
    for (server, extra, valid) in [
        ("localhost", "", true),
        ("localhost.", "", true),
        ("127.0.0.1", "", false),
        ("::1", "", false),
        ("127.0.0.1", ", sni: localhost", true),
        ("::1", ", skip-cert-verify: true", true),
    ] {
        let source = format!(
            "proxies: [{{name: tls, type: trojan, server: '{server}', port: 443, password: secret{extra}}}]"
        );
        assert_eq!(Config::parse(&source).is_ok(), valid, "{server}{extra}");
    }
}

#[test]
fn malformed_domain_payloads_are_not_repaired_into_valid_rules() {
    for payload in [
        "example.com..",
        ".example.com",
        "a..example.com",
        "-bad.example.com",
        "é.example.com",
        "a/b",
    ] {
        for kind in ["DOMAIN", "DOMAIN-SUFFIX"] {
            assert!(
                Config::parse(&format!("rules: ['{kind},{payload},DIRECT']")).is_err(),
                "accepted {kind}: {payload}"
            );
        }
    }
}

#[tokio::test]
async fn route_pins_the_matching_address_or_the_prior_dns_snapshot() {
    let target = Target::new("localhost", 443).unwrap();
    for (rules, expected) in [
        (
            "'IP-CIDR,127.0.0.0/8,DIRECT', 'IP-CIDR6,::/0,REJECT'",
            "127.0.0.1",
        ),
        ("'IP-CIDR6,::1/128,DIRECT', 'MATCH,REJECT'", "::1"),
        (
            "'IP-CIDR,192.0.2.0/24,REJECT', 'DOMAIN,localhost,DIRECT'",
            "127.0.0.1",
        ),
        ("'IP-CIDR,192.0.2.0/24,REJECT', 'MATCH,DIRECT'", "127.0.0.1"),
        (
            "'IP-CIDR,192.0.2.0/24,REJECT', 'DST-PORT,443,DIRECT'",
            "127.0.0.1",
        ),
        (
            "'IP-CIDR,127.0.0.0/8,REJECT,no-resolve', 'MATCH,DIRECT'",
            "localhost",
        ),
        (
            "'DOMAIN,localhost,DIRECT', 'IP-CIDR,0.0.0.0/0,REJECT'",
            "localhost",
        ),
    ] {
        let config = Config::parse(&format!("rules: [{rules}]")).unwrap();
        let route = config.route(&target).await.unwrap();
        assert_eq!(route.proxy.name, "DIRECT");
        assert_eq!(route.target, Target::new(expected, 443).unwrap(), "{rules}");
    }
}
