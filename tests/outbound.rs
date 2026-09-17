use std::time::Duration;

use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpListener,
    time::timeout,
};
use zc::{
    config::{Config, Proxy, ProxyKind},
    outbound::Connector,
    target::Target,
};

#[tokio::test]
async fn direct_roundtrip_preserves_half_close() {
    timeout(Duration::from_secs(3), async {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let address = listener.local_addr().unwrap();
        let peer = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            stream.read_to_end(&mut request).await.unwrap();
            assert_eq!(request, b"request before FIN");
            stream.write_all(b"response after FIN").await.unwrap();
            stream.shutdown().await.unwrap();
        });
        let config = Config::parse("rules: ['MATCH,DIRECT']\n").unwrap();
        let connector = Connector::new(&config).unwrap();
        let proxy = Proxy {
            udp: true,
            obfs: None,
            name: "DIRECT".into(),
            kind: ProxyKind::Direct,
        };
        let target = Target::new(address.ip().to_string(), address.port()).unwrap();
        let mut stream = connector.connect(&proxy, &target).await.unwrap();
        stream.write_all(b"request before FIN").await.unwrap();
        stream.shutdown().await.unwrap();
        let mut response = Vec::new();
        stream.read_to_end(&mut response).await.unwrap();
        assert_eq!(response, b"response after FIN");
        peer.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn reject_reports_policy_without_dialing_target() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let address = listener.local_addr().unwrap();
    let config = Config::parse("rules: ['MATCH,REJECT']\n").unwrap();
    let connector = Connector::new(&config).unwrap();
    let proxy = Proxy {
        udp: true,
        obfs: None,
        name: "REJECT".into(),
        kind: ProxyKind::Reject,
    };
    let target = Target::new(address.ip().to_string(), address.port()).unwrap();
    let error = match connector.connect(&proxy, &target).await {
        Ok(_) => panic!("REJECT must not return a stream"),
        Err(error) => error.to_string(),
    };
    assert!(
        error.contains("REJECT") && error.contains("routing rule"),
        "{error}"
    );
    assert!(
        timeout(Duration::from_millis(100), listener.accept())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn shadowsocks_sends_destination_before_server_first_payload_and_preserves_half_close() {
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        crypto::CipherKind,
        relay::{socks5::Address, tcprelay::proxy_stream::ProxyServerStream},
    };

    for (cipher, method) in [
        ("aes-128-gcm", CipherKind::AES_128_GCM),
        ("aes-256-gcm", CipherKind::AES_256_GCM),
        ("chacha20-ietf-poly1305", CipherKind::CHACHA20_POLY1305),
    ] {
        timeout(Duration::from_secs(3), async {
            let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
            let address = listener.local_addr().unwrap();
            let peer = tokio::spawn(async move {
                let config = ServerConfig::new(address, "password", method).unwrap();
                let (stream, _) = listener.accept().await.unwrap();
                let mut stream = ProxyServerStream::from_stream(
                    Context::new_shared(ServerType::Server),
                    stream,
                    config.method(),
                    config.key(),
                );
                assert_eq!(
                    stream.handshake().await.unwrap(),
                    Address::DomainNameAddress("example.com".into(), 25)
                );
                stream.write_all(b"220 server ready\r\n").await.unwrap();
                let mut request = Vec::new();
                stream.read_to_end(&mut request).await.unwrap();
                assert_eq!(request, b"QUIT\r\n");
                stream.write_all(b"221 goodbye\r\n").await.unwrap();
                stream.shutdown().await.unwrap();
            });
            let config = Config::parse("rules: ['MATCH,DIRECT']\n").unwrap();
            let connector = Connector::new(&config).unwrap();
            let proxy = Proxy {
                udp: true,
                obfs: None,
                name: "ss".into(),
                kind: ProxyKind::Shadowsocks {
                    server: address.ip().to_string(),
                    port: address.port(),
                    password: "password".into(),
                    cipher: cipher.into(),
                },
            };
            let target = Target::new("example.com", 25).unwrap();
            let mut stream = connector.connect(&proxy, &target).await.unwrap();
            let mut greeting = [0; 18];
            stream.read_exact(&mut greeting).await.unwrap();
            assert_eq!(&greeting, b"220 server ready\r\n");
            stream.write_all(b"QUIT\r\n").await.unwrap();
            stream.shutdown().await.unwrap();
            let mut response = Vec::new();
            stream.read_to_end(&mut response).await.unwrap();
            assert_eq!(response, b"221 goodbye\r\n");
            peer.await.unwrap();
        })
        .await
        .unwrap();
    }
}

fn trojan_config(port: u16, skip_cert_verify: bool) -> Config {
    let skip = if skip_cert_verify {
        "    skip-cert-verify: true\n"
    } else {
        ""
    };
    Config::parse(&format!(
        "proxies:\n  - name: trojan\n    type: trojan\n    server: 127.0.0.1\n    port: {port}\n    password: password\n    sni: front.example\n{skip}rules: ['MATCH,trojan']\n"
    )).unwrap()
}

fn tls_acceptor() -> tokio_rustls::TlsAcceptor {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
    use std::sync::Arc;

    let cert =
        CertificateDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-cert.pem")).unwrap();
    let key =
        PrivateKeyDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-key.pem")).unwrap();
    let config = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![cert], key)
    .unwrap();
    tokio_rustls::TlsAcceptor::from(Arc::new(config))
}

#[tokio::test]
async fn trojan_tls_sends_fixed_wire_request_and_preserves_half_close() {
    timeout(Duration::from_secs(5), async {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let config = trojan_config(listener.local_addr().unwrap().port(), true);
        let acceptor = tls_acceptor();
        let peer = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            let mut stream = acceptor.accept(stream).await.unwrap();
            assert_eq!(stream.get_ref().1.server_name(), Some("front.example"));
            // Digest fixed independently using: printf password | openssl dgst -sha224.
            // CONNECT, domain example.com, port 443, followed by CRLF (Trojan protocol).
            let expected = b"d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01\r\n\x01\x03\x0bexample.com\x01\xbb\r\n";
            let mut request = vec![0; expected.len()];
            stream.read_exact(&mut request).await.unwrap();
            assert_eq!(request, expected);
            stream.write_all(b"server first").await.unwrap();
            stream.flush().await.unwrap();
            let mut payload = Vec::new();
            stream.read_to_end(&mut payload).await.unwrap();
            assert_eq!(payload, b"client payload");
            stream.write_all(b"response after FIN").await.unwrap();
            stream.shutdown().await.unwrap();
        });
        let connector = Connector::new(&config).unwrap();
        let target = Target::new("example.com", 443).unwrap();
        let proxy = config.proxies().iter().find(|p| p.name == "trojan").unwrap();
        let mut stream = connector.connect(proxy, &target).await.unwrap();
        let mut greeting = [0; 12];
        stream.read_exact(&mut greeting).await.unwrap();
        assert_eq!(&greeting, b"server first");
        stream.write_all(b"client payload").await.unwrap();
        stream.shutdown().await.unwrap();
        let mut response = Vec::new();
        stream.read_to_end(&mut response).await.unwrap();
        assert_eq!(response, b"response after FIN");
        peer.await.unwrap();
    }).await.unwrap();
}

#[tokio::test]
async fn trojan_default_rejects_untrusted_certificate_without_sending_request() {
    timeout(Duration::from_secs(10), async {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let config = trojan_config(listener.local_addr().unwrap().port(), false);
        let acceptor = tls_acceptor();
        let peer = tokio::spawn(async move {
            let (stream, _) = listener.accept().await.unwrap();
            assert!(
                acceptor.accept(stream).await.is_err(),
                "untrusted TLS must fail before Trojan authentication"
            );
        });
        let connector = Connector::new(&config).unwrap();
        let proxy = config
            .proxies()
            .iter()
            .find(|p| p.name == "trojan")
            .unwrap();
        let target_listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let address = target_listener.local_addr().unwrap();
        let target = Target::new(address.ip().to_string(), address.port()).unwrap();
        let error = match connector.connect(proxy, &target).await {
            Ok(_) => panic!("default Trojan TLS must reject the untrusted certificate"),
            Err(error) => format!("{error:#}"),
        };
        assert!(error.contains("certificate"), "{error}");
        assert!(
            !error.contains("password"),
            "credentials must not appear in diagnostics"
        );
        peer.await.unwrap();
        assert!(
            timeout(Duration::from_millis(100), target_listener.accept())
                .await
                .is_err(),
            "TLS failure must never fall back to DIRECT"
        );
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn verified_trojan_ip_requires_explicit_dns_sni_without_dialing() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let address = listener.local_addr().unwrap();
    let config = trojan_config(address.port(), false);
    let connector = Connector::new(&config).unwrap();
    let proxy = Proxy {
        udp: true,
        obfs: None,
        name: "trojan-ip".into(),
        kind: ProxyKind::Trojan {
            server: address.ip().to_string(),
            port: address.port(),
            password: "password".into(),
            sni: None,
            skip_cert_verify: false,
        },
    };
    let target = Target::new("example.com", 443).unwrap();
    let result = timeout(
        Duration::from_millis(500),
        connector.connect(&proxy, &target),
    )
    .await
    .expect("missing SNI must be rejected before dialing or TLS");
    let error = match result {
        Ok(_) => panic!("verified IP server requires explicit DNS SNI"),
        Err(error) => error.to_string(),
    };
    assert!(error.contains("requires sni"), "{error}");
    assert!(
        timeout(Duration::from_millis(100), listener.accept())
            .await
            .is_err()
    );
}

#[tokio::test]
async fn trojan_explicit_sni_rejects_ip_and_root_dot_before_dialing() {
    let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
    let address = listener.local_addr().unwrap();
    let config = trojan_config(address.port(), true);
    let connector = Connector::new(&config).unwrap();
    let target = Target::new("example.com", 443).unwrap();
    for sni in ["127.0.0.1", "::1", "front.example.", "bad_name.example"] {
        let proxy = Proxy {
            udp: true,
            obfs: None,
            name: "bad-sni".into(),
            kind: ProxyKind::Trojan {
                server: address.ip().to_string(),
                port: address.port(),
                password: "password".into(),
                sni: Some(sni.into()),
                skip_cert_verify: true,
            },
        };
        let result = timeout(
            Duration::from_millis(500),
            connector.connect(&proxy, &target),
        )
        .await
        .expect("invalid explicit SNI must be rejected before dialing");
        let error = match result {
            Ok(_) => panic!("invalid explicit SNI must not connect"),
            Err(error) => error.to_string(),
        };
        assert!(error.contains("sni"), "{error}");
    }
    assert!(
        timeout(Duration::from_millis(100), listener.accept())
            .await
            .is_err()
    );
}

// A real TLS peer with one corrupted signature exercises the client's verifier,
// without implementing TLS or cryptography in the test.
#[derive(Debug)]
struct CorruptSigningKey(std::sync::Arc<dyn rustls::sign::SigningKey>);

impl rustls::sign::SigningKey for CorruptSigningKey {
    fn choose_scheme(
        &self,
        offered: &[rustls::SignatureScheme],
    ) -> Option<Box<dyn rustls::sign::Signer>> {
        self.0
            .choose_scheme(offered)
            .map(|signer| Box::new(CorruptSigner(signer)) as Box<dyn rustls::sign::Signer>)
    }

    fn algorithm(&self) -> rustls::SignatureAlgorithm {
        self.0.algorithm()
    }
}

#[derive(Debug)]
struct CorruptSigner(Box<dyn rustls::sign::Signer>);

impl rustls::sign::Signer for CorruptSigner {
    fn sign(&self, message: &[u8]) -> Result<Vec<u8>, rustls::Error> {
        let mut signature = self.0.sign(message)?;
        signature[0] ^= 1;
        Ok(signature)
    }

    fn scheme(&self) -> rustls::SignatureScheme {
        self.0.scheme()
    }
}

#[tokio::test]
async fn trojan_skip_identity_still_rejects_invalid_tls12_and_tls13_signatures() {
    use rustls::{
        pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject},
        sign::{CertifiedKey, SingleCertAndKey},
    };
    use std::sync::Arc;

    timeout(Duration::from_secs(5), async {
        for version in [&rustls::version::TLS12, &rustls::version::TLS13] {
            let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
            let cert =
                CertificateDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-cert.pem"))
                    .unwrap();
            let key =
                PrivateKeyDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-key.pem"))
                    .unwrap();
            let signing_key = provider.key_provider.load_private_key(key).unwrap();
            let certified_key =
                CertifiedKey::new(vec![cert], Arc::new(CorruptSigningKey(signing_key)));
            let server_config = rustls::ServerConfig::builder_with_provider(provider)
                .with_protocol_versions(&[version])
                .unwrap()
                .with_no_client_auth()
                .with_cert_resolver(Arc::new(SingleCertAndKey::from(certified_key)));
            let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(server_config));
            let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
            let config = trojan_config(listener.local_addr().unwrap().port(), true);
            let peer = tokio::spawn(async move {
                let (stream, _) = listener.accept().await.unwrap();
                assert!(acceptor.accept(stream).await.is_err());
            });
            let connector = Connector::new(&config).unwrap();
            let proxy = config
                .proxies()
                .iter()
                .find(|p| p.name == "trojan")
                .unwrap();
            let target = Target::new("example.com", 443).unwrap();
            let error = match connector.connect(proxy, &target).await {
                Ok(_) => panic!("skip-cert-verify must still verify handshake signatures"),
                Err(error) => format!("{error:#}"),
            };
            assert!(error.contains("BadSignature"), "{error}");
            peer.await.unwrap();
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn trojan_stalled_tls_is_bounded_by_the_ten_second_setup_deadline() {
    timeout(Duration::from_secs(12), async {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let config = trojan_config(listener.local_addr().unwrap().port(), true);
        let peer = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut hello = Vec::new();
            stream.read_to_end(&mut hello).await.unwrap();
            assert!(
                !hello.is_empty(),
                "the client must start a real TLS handshake"
            );
        });
        let connector = Connector::new(&config).unwrap();
        let proxy = config
            .proxies()
            .iter()
            .find(|p| p.name == "trojan")
            .unwrap();
        let target = Target::new("example.com", 443).unwrap();
        let started = std::time::Instant::now();
        let error = match connector.connect(proxy, &target).await {
            Ok(_) => panic!("a stalled TLS peer must time out"),
            Err(error) => error.to_string(),
        };
        assert!(error.contains("timed out after 10 seconds"), "{error}");
        assert!(started.elapsed() >= Duration::from_secs(10));
        peer.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn ip_policy_pins_shadowsocks_destination_on_the_wire() {
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        crypto::CipherKind,
        relay::{socks5::Address, tcprelay::proxy_stream::ProxyServerStream},
    };
    timeout(Duration::from_secs(5), async {
        // Include a later MATCH after a nonmatching IP rule: it must use the same snapshot.
        for rule in ["IP-CIDR,127.0.0.0/8,edge", "IP-CIDR,192.0.2.0/24,REJECT"] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let peer = tokio::spawn(async move {
                let config = ServerConfig::new(address, "password", CipherKind::AES_128_GCM).unwrap();
                let (stream, _) = listener.accept().await.unwrap();
                let mut stream = ProxyServerStream::from_stream(
                    Context::new_shared(ServerType::Server), stream, config.method(), config.key(),
                );
                assert_eq!(stream.handshake().await.unwrap(), Address::SocketAddress("127.0.0.1:443".parse().unwrap()));
                stream.write_all(b"pinned").await.unwrap();
                stream.flush().await.unwrap();
            });
            let config = Config::parse(&format!("proxies: [{{name: edge, type: ss, server: localhost, port: {}, password: password, cipher: aes-128-gcm}}]\nrules: ['{rule}', 'MATCH,edge']", address.port())).unwrap();
            let connector = Connector::new(&config).unwrap();
            let route = config.route(&Target::new("localhost", 443).unwrap()).await.unwrap();
            let mut stream = connector.connect(route.proxy, &route.target).await.unwrap();
            let mut response = [0; 6];
            stream.read_exact(&mut response).await.unwrap();
            assert_eq!(&response, b"pinned");
            peer.await.unwrap();
        }
    }).await.unwrap();
}

#[tokio::test]
async fn ip_policy_pins_trojan_destination_but_preserves_tls_sni() {
    timeout(Duration::from_secs(5), async {
        for rule in ["IP-CIDR6,::1/128,edge", "IP-CIDR,192.0.2.0/24,REJECT"] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let port = listener.local_addr().unwrap().port();
            let acceptor = tls_acceptor();
            let ipv6 = rule.starts_with("IP-CIDR6");
            let peer = tokio::spawn(async move {
                let (stream, _) = listener.accept().await.unwrap();
                let mut stream = acceptor.accept(stream).await.unwrap();
                assert_eq!(stream.get_ref().1.server_name(), Some("front.example"));
                let mut expected = b"d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01\r\n\x01".to_vec();
                if ipv6 {
                    expected.push(4);
                    expected.extend_from_slice(&[0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1]);
                } else {
                    expected.extend_from_slice(&[1, 127, 0, 0, 1]);
                }
                expected.extend_from_slice(b"\x01\xbb\r\n");
                let mut request = vec![0; expected.len()];
                stream.read_exact(&mut request).await.unwrap();
                assert_eq!(request, expected);
                stream.write_all(b"pinned").await.unwrap();
                stream.flush().await.unwrap();
            });
            let config = Config::parse(&format!("proxies: [{{name: edge, type: trojan, server: localhost, port: {port}, password: password, sni: front.example, skip-cert-verify: true}}]\nrules: ['{rule}', 'MATCH,edge']")).unwrap();
            let connector = Connector::new(&config).unwrap();
            let route = config.route(&Target::new("localhost", 443).unwrap()).await.unwrap();
            let mut stream = connector.connect(route.proxy, &route.target).await.unwrap();
            let mut response = [0; 6];
            stream.read_exact(&mut response).await.unwrap();
            assert_eq!(&response, b"pinned");
            peer.await.unwrap();
        }
    }).await.unwrap();
}

#[tokio::test]
async fn shadowsocks_http_obfs_wraps_ciphertext_before_independent_server_decryption() {
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        crypto::CipherKind,
        relay::{socks5::Address, tcprelay::proxy_stream::ProxyServerStream},
    };
    timeout(Duration::from_secs(5), async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let peer = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            // An independent HTTP envelope reader, not the client codec in reverse.
            let mut header = Vec::new();
            while !header.ends_with(b"\r\n\r\n") && header.len() < 1024 {
                header.push(stream.read_u8().await.unwrap());
            }
            let header = String::from_utf8(header).unwrap();
            assert!(header.starts_with("GET / HTTP/1.1\r\n"));
            assert!(header.contains(&format!("Host: cover.example:{}\r\n", address.port())));
            // AES-128: salt(16) + encrypted length(2+16) + address(15) + tag(16).
            assert!(header.contains("\r\nContent-Length: 65\r\n"), "{header}");
            stream.write_all(b"HTTP/1.1 101 Switching Protocols\r\n\r\n").await.unwrap();
            let config = ServerConfig::new(address, "password", CipherKind::AES_128_GCM).unwrap();
            let mut stream = ProxyServerStream::from_stream(Context::new_shared(ServerType::Server), stream, config.method(), config.key());
            assert_eq!(stream.handshake().await.unwrap(), Address::DomainNameAddress("example.com".into(), 25));
            stream.write_all(b"ready").await.unwrap(); stream.flush().await.unwrap();
            let mut request = Vec::new(); stream.read_to_end(&mut request).await.unwrap(); assert_eq!(request, b"QUIT");
            stream.write_all(b"bye").await.unwrap(); stream.shutdown().await.unwrap();
        });
        let config = Config::parse(&format!("proxies: [{{name: edge, type: ss, server: 127.0.0.1, port: {}, password: password, cipher: aes-128-gcm, plugin: obfs-local, plugin-opts: {{mode: http, host: cover.example}}}}]\nrules: ['MATCH,edge']", address.port())).unwrap();
        let connector = Connector::new(&config).unwrap();
        let target = Target::new("example.com", 25).unwrap(); let route = config.route(&target).await.unwrap();
        let mut stream = connector.connect(route.proxy, &route.target).await.unwrap();
        let mut greeting = [0; 5]; stream.read_exact(&mut greeting).await.unwrap(); assert_eq!(&greeting, b"ready");
        stream.write_all(b"QUIT").await.unwrap(); stream.shutdown().await.unwrap();
        let mut response = Vec::new(); stream.read_to_end(&mut response).await.unwrap(); assert_eq!(response, b"bye");
        peer.await.unwrap();
    }).await.unwrap();
}

#[tokio::test]
async fn obfs_preflight_rejects_invalid_host_and_non_ss_metadata_before_tcp_or_udp_open() {
    use zc::config::ObfsHttp;
    let config = Config::parse("rules: ['MATCH,DIRECT']").unwrap();
    let connector = Connector::new(&config).unwrap();
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let address = listener.local_addr().unwrap();
    let target = Target::new(address.ip().to_string(), address.port()).unwrap();
    for (kind, host) in [
        (ProxyKind::Direct, "cover.example"),
        (
            ProxyKind::Shadowsocks {
                server: "127.0.0.1".into(),
                port: address.port(),
                password: "password".into(),
                cipher: "aes-128-gcm".into(),
            },
            "bad\r\nInjected: true",
        ),
    ] {
        let proxy = Proxy {
            name: "invalid-obfs".into(),
            kind,
            udp: true,
            obfs: Some(ObfsHttp { host: host.into() }),
        };
        assert!(connector.connect(&proxy, &target).await.is_err());
        assert!(connector.open_udp(&proxy, &target).await.is_err());
    }
    assert!(
        timeout(Duration::from_millis(20), listener.accept())
            .await
            .is_err()
    );
}
