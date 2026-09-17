use std::time::Duration;
use tokio::{net::UdpSocket, time::timeout};
use zc::{config::Config, outbound::Connector, target::Target};

#[tokio::test]
async fn direct_udp_roundtrip_and_receive_cancellation() {
    timeout(Duration::from_secs(3), async {
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let address = peer.local_addr().unwrap();
        let target = Target::new(address.ip().to_string(), address.port()).unwrap();
        let config = Config::parse("rules: ['MATCH,DIRECT']").unwrap();
        let route = config.route(&target).await.unwrap();
        let connector = Connector::new(&config).unwrap();
        let session = connector
            .open_udp(route.proxy, &route.target)
            .await
            .unwrap();
        assert!(
            timeout(Duration::from_millis(20), session.recv_from())
                .await
                .is_err()
        );
        assert_eq!(session.send_to(b"hello", &route.target).await.unwrap(), 5);
        let mut buffer = [0; 100];
        let (n, client) = peer.recv_from(&mut buffer).await.unwrap();
        assert_eq!(&buffer[..n], b"hello");
        peer.send_to(b"world", client).await.unwrap();
        let reply = session.recv_from().await.unwrap();
        assert_eq!(reply.source, target);
        assert_eq!(reply.payload, b"world");
        assert!(session.send_to(&vec![0; 65508], &target).await.is_err());
        session.send_to(b"", &target).await.unwrap();
        assert_eq!(peer.recv_from(&mut buffer).await.unwrap().0, 0);
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn classic_shadowsocks_udp_drops_bad_auth_and_truncation_then_recovers() {
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        crypto::CipherKind,
        relay::{
            socks5::Address,
            udprelay::proxy_socket::{ProxySocket, UdpSocketType},
        },
    };
    for (cipher, method) in [
        ("aes-128-gcm", CipherKind::AES_128_GCM),
        ("aes-256-gcm", CipherKind::AES_256_GCM),
        ("chacha20-ietf-poly1305", CipherKind::CHACHA20_POLY1305),
    ] {
        timeout(Duration::from_secs(5), async {
            let raw = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
            raw.set_nonblocking(true).unwrap();
            let address = raw.local_addr().unwrap();
            let invalid = UdpSocket::from_std(raw.try_clone().unwrap()).unwrap();
            let wrong_socket: shadowsocks::net::UdpSocket = UdpSocket::from_std(raw.try_clone().unwrap()).unwrap().into();
            let socket: shadowsocks::net::UdpSocket = UdpSocket::from_std(raw).unwrap().into();
            let server_config = ServerConfig::new(address, "password", method).unwrap();
            let wrong_config = ServerConfig::new(address, "wrong", method).unwrap();
            let server = ProxySocket::from_socket(UdpSocketType::Server, Context::new_shared(ServerType::Server), &server_config, socket);
            let wrong = ProxySocket::from_socket(UdpSocketType::Server, Context::new_shared(ServerType::Server), &wrong_config, wrong_socket);
            let config = Config::parse(&format!("proxies: [{{name: edge, type: ss, server: 127.0.0.1, port: {}, password: password, cipher: {cipher}, udp: true, plugin: obfs, plugin-opts: {{mode: http, host: cover.example}}}}]\nrules: ['MATCH,edge']", address.port())).unwrap();
            let connector = Connector::new(&config).unwrap();
            let target = Target::new("example.com", 53).unwrap();
            let route = config.route(&target).await.unwrap();
            let session = connector.open_udp(route.proxy, &route.target).await.unwrap();
            let expected = Address::DomainNameAddress("example.com".into(), 53);
            session.send_to(b"query", &target).await.unwrap();
            let mut buffer = vec![0; 65536];
            let (n, client, destination, _) = server.recv_from(&mut buffer).await.unwrap();
            assert_eq!(destination, expected); assert_eq!(&buffer[..n], b"query");
            wrong.send_to(client, &expected, b"forged").await.unwrap();
            invalid.send_to(b"short salt", client).await.unwrap();
            invalid.send_to(&[0; 20], client).await.unwrap();
            server.send_to(client, &expected, b"authenticated").await.unwrap();
            let reply = session.recv_from().await.unwrap();
            assert_eq!(reply.source, target); assert_eq!(reply.payload, b"authenticated");
            let salt = if cipher == "aes-128-gcm" { 16 } else { 32 };
            let max = 65507 - salt - 16 - 15;
            assert!(session.send_to(&vec![0; max + 1], &target).await.is_err());
            session.send_to(&vec![42; max], &target).await.unwrap();
            let (n, _, _, wire) = server.recv_from(&mut buffer).await.unwrap();
            assert_eq!(n, max); assert_eq!(wire, 65507);
            for target in [Target::new("127.0.0.1", 53).unwrap(), Target::new("::1", 53).unwrap()] {
                session.send_to(b"", &target).await.unwrap();
                let (n, client, destination, _) = server.recv_from(&mut buffer).await.unwrap();
                assert_eq!(n, 0);
                assert_eq!(destination, Address::SocketAddress(format!("{}:53", if target.host() == "::1" { "[::1]" } else { "127.0.0.1" }).parse().unwrap()));
                server.send_to(client, &destination, b"address reply").await.unwrap();
                let reply = session.recv_from().await.unwrap();
                assert_eq!(reply.source, target); assert_eq!(reply.payload, b"address reply");
            }
        }).await.unwrap();
    }
}

fn tls_peer() -> (tokio_rustls::TlsAcceptor, rustls::RootCertStore) {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
    use std::sync::Arc;
    let cert =
        CertificateDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-cert.pem")).unwrap();
    let key =
        PrivateKeyDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-key.pem")).unwrap();
    let mut roots = rustls::RootCertStore::empty();
    roots.add(cert.clone()).unwrap();
    let server = rustls::ServerConfig::builder_with_provider(Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![cert], key)
    .unwrap();
    (tokio_rustls::TlsAcceptor::from(Arc::new(server)), roots)
}

fn trojan_config(port: u16, sni: &str) -> Config {
    Config::parse(&format!("proxies: [{{name: edge, type: trojan, server: 127.0.0.1, port: {port}, password: password, sni: {sni}, udp: true}}]\nrules: ['MATCH,edge']")).unwrap()
}

const UDP_REQUEST: &[u8] = b"d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01\r\n\x03\x01\x00\x00\x00\x00\x00\x00\r\n";

#[tokio::test]
async fn verified_trojan_udp_keeps_partial_frame_across_receive_cancellation_and_concurrent_send() {
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
        sync::oneshot,
    };
    timeout(Duration::from_secs(5), async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = trojan_config(
            listener.local_addr().unwrap().port(),
            "localhost.localdomain",
        );
        let (acceptor, roots) = tls_peer();
        let (partial_sent, partial_ready) = oneshot::channel();
        let (resume, resumed) = oneshot::channel();
        let peer = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut stream = acceptor.accept(socket).await.unwrap();
            assert_eq!(
                stream.get_ref().1.server_name(),
                Some("localhost.localdomain")
            );
            let mut request = vec![0; UDP_REQUEST.len()];
            stream.read_exact(&mut request).await.unwrap();
            assert_eq!(request, UDP_REQUEST);
            // IPv4 127.0.0.1:53, length 5, then CRLF and payload (independent fixture).
            let frame = b"\x01\x7f\x00\x00\x01\x00\x35\x00\x05\r\nhello";
            stream.write_all(&frame[..3]).await.unwrap();
            stream.flush().await.unwrap();
            partial_sent.send(()).unwrap();
            let mut outgoing = vec![0; frame.len()];
            stream.read_exact(&mut outgoing).await.unwrap();
            assert_eq!(outgoing, frame);
            resumed.await.unwrap();
            stream.write_all(&frame[3..]).await.unwrap();
            stream
                .write_all(b"\x03\x0bexample.com\x00\x35\x00\x00\r\n")
                .await
                .unwrap();
            stream.flush().await.unwrap();
            let mut eof = [0];
            assert_eq!(stream.read(&mut eof).await.unwrap_or(0), 0);
        });
        let connector = Connector::with_tls_roots(&config, roots).unwrap();
        let target = Target::new("127.0.0.1", 53).unwrap();
        let route = config.route(&target).await.unwrap();
        let session = connector
            .open_udp(route.proxy, &route.target)
            .await
            .unwrap();
        partial_ready.await.unwrap();
        assert!(
            timeout(Duration::from_millis(30), session.recv_from())
                .await
                .is_err()
        );
        session.send_to(b"hello", &target).await.unwrap();
        resume.send(()).unwrap();
        let first = session.recv_from().await.unwrap();
        assert_eq!(first.source, target);
        assert_eq!(first.payload, b"hello");
        let second = session.recv_from().await.unwrap();
        assert_eq!(second.source, Target::new("example.com", 53).unwrap());
        assert!(second.payload.is_empty());
        drop(session);
        peer.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn trojan_udp_certificate_failure_never_sends_auth_or_direct_datagram() {
    use tokio::net::TcpListener;
    timeout(Duration::from_secs(5), async {
        for trusted in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let config = trojan_config(listener.local_addr().unwrap().port(), "wrong.example");
            let (acceptor, roots) = tls_peer();
            let peer = tokio::spawn(async move {
                let (socket, _) = listener.accept().await.unwrap();
                assert!(acceptor.accept(socket).await.is_err());
            });
            let direct = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let address = direct.local_addr().unwrap();
            let target = Target::new(address.ip().to_string(), address.port()).unwrap();
            let connector = if trusted {
                Connector::with_tls_roots(&config, roots)
            } else {
                Connector::new(&config)
            }
            .unwrap();
            let route = config.route(&target).await.unwrap();
            let error = match connector.open_udp(route.proxy, &route.target).await {
                Ok(_) => panic!("TLS verification must fail"),
                Err(error) => format!("{error:#}"),
            };
            assert!(error.contains("certificate"), "{error}");
            assert!(!error.contains("password"));
            let mut buffer = [0; 100];
            assert!(
                timeout(Duration::from_millis(20), direct.recv_from(&mut buffer))
                    .await
                    .is_err()
            );
            peer.await.unwrap();
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn trojan_malformed_frames_and_mid_frame_eof_terminate_without_resynchronization() {
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    timeout(Duration::from_secs(5), async {
        for frame in [
            b"\x09".as_slice(),
            b"\x03\x00\x00\x35\x00\x00\r\n",
            b"\x01\x7f\x00\x00\x01\x00\x00\x00\x00\r\n",
            b"\x01\x7f\x00\x00\x01\x00\x35\x00\x00XX",
            b"\x01\x7f\x00\x00\x01\x00\x35\x00\x05\r\nabc",
            b"\x04\x00\x00",
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let config = trojan_config(
                listener.local_addr().unwrap().port(),
                "localhost.localdomain",
            );
            let (acceptor, roots) = tls_peer();
            let peer = tokio::spawn(async move {
                let (socket, _) = listener.accept().await.unwrap();
                let mut stream = acceptor.accept(socket).await.unwrap();
                let mut request = vec![0; UDP_REQUEST.len()];
                stream.read_exact(&mut request).await.unwrap();
                assert_eq!(request, UDP_REQUEST);
                stream.write_all(frame).await.unwrap();
                stream.shutdown().await.unwrap();
            });
            let connector = Connector::with_tls_roots(&config, roots).unwrap();
            let target = Target::new("127.0.0.1", 53).unwrap();
            let route = config.route(&target).await.unwrap();
            let session = connector
                .open_udp(route.proxy, &route.target)
                .await
                .unwrap();
            assert!(session.recv_from().await.is_err());
            assert!(session.recv_from().await.is_err());
            assert!(session.send_to(b"no resync", &target).await.is_err());
            peer.await.unwrap();
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn trojan_datagram_ipv6_maximum_payload_and_domain_dns_pinning() {
    use shadowsocks::relay::socks5::Address;
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    timeout(Duration::from_secs(5), async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = trojan_config(listener.local_addr().unwrap().port(), "localhost.localdomain");
        let (acceptor, roots) = tls_peer();
        let peer = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap(); let mut stream = acceptor.accept(socket).await.unwrap();
            let mut request = vec![0; UDP_REQUEST.len()]; stream.read_exact(&mut request).await.unwrap(); assert_eq!(request, UDP_REQUEST);
            let address = Address::read_from(&mut stream).await.unwrap();
            assert_eq!(address, Address::SocketAddress("[::1]:53".parse().unwrap()));
            assert_eq!(stream.read_u16().await.unwrap(), 65535);
            assert_eq!(stream.read_u16().await.unwrap(), 0x0d0a);
            let mut data = vec![0; 65535]; stream.read_exact(&mut data).await.unwrap(); assert!(data.iter().all(|b| *b == 42));
            // Write the response in small fragments, crossing address, length and payload boundaries.
            let mut frame = b"\x04\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x01\x00\x35\xff\xff\r\n".to_vec();
            frame.extend_from_slice(&data);
            for fragment in frame.chunks(997) { stream.write_all(fragment).await.unwrap(); }
            stream.flush().await.unwrap();
            for _ in 0..2 {
                match Address::read_from(&mut stream).await.unwrap() {
                    Address::SocketAddress(address) => { assert!(address.ip().is_loopback()); assert_eq!(address.port(), 54); },
                    _ => panic!("Trojan domains must be resolved before writing frames"),
                }
                assert_eq!(stream.read_u16().await.unwrap(), 0); assert_eq!(stream.read_u16().await.unwrap(), 0x0d0a);
            }
        });
        let connector = Connector::with_tls_roots(&config, roots).unwrap();
        let target = Target::new("::1", 53).unwrap(); let route = config.route(&target).await.unwrap();
        let session = connector.open_udp(route.proxy, &route.target).await.unwrap();
        assert!(session.send_to(&vec![0; 65536], &target).await.is_err());
        session.send_to(&vec![42; 65535], &target).await.unwrap();
        let reply = session.recv_from().await.unwrap(); assert_eq!(reply.source, target); assert_eq!(reply.payload, vec![42; 65535]);
        let domain = Target::new("localhost", 54).unwrap();
        session.send_to(b"", &domain).await.unwrap(); session.send_to(b"", &domain).await.unwrap();
        peer.await.unwrap();
    }).await.unwrap();
}

#[tokio::test]
async fn reject_disabled_udp_and_unsupported_cipher_do_not_dial_or_fallback() {
    use zc::config::{Proxy, ProxyKind};
    timeout(Duration::from_secs(3), async {
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let address = peer.local_addr().unwrap();
        let tcp = tokio::net::TcpListener::bind(address).await.unwrap();
        let config = Config::parse("rules: ['MATCH,DIRECT']").unwrap();
        let connector = Connector::new(&config).unwrap();
        let target = Target::new(address.ip().to_string(), address.port()).unwrap();
        for (kind, udp) in [
            (ProxyKind::Reject, true),
            (
                ProxyKind::Shadowsocks {
                    server: "127.0.0.1".into(),
                    port: address.port(),
                    password: "password".into(),
                    cipher: "aes-128-gcm".into(),
                },
                false,
            ),
            (
                ProxyKind::Shadowsocks {
                    server: "127.0.0.1".into(),
                    port: address.port(),
                    password: "password".into(),
                    cipher: "2022-blake3-aes-128-gcm".into(),
                },
                true,
            ),
            (
                ProxyKind::Trojan {
                    server: "127.0.0.1".into(),
                    port: address.port(),
                    password: "password".into(),
                    sni: Some("localhost.localdomain".into()),
                    skip_cert_verify: false,
                },
                false,
            ),
        ] {
            let proxy = Proxy {
                name: "denied".into(),
                kind,
                udp,
                obfs: None,
            };
            assert!(connector.open_udp(&proxy, &target).await.is_err());
        }
        let mut buffer = [0; 10];
        assert!(
            timeout(Duration::from_millis(20), peer.recv_from(&mut buffer))
                .await
                .is_err()
        );
        assert!(
            timeout(Duration::from_millis(20), tcp.accept())
                .await
                .is_err()
        );
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn trojan_send_queue_is_bounded_and_accepted_frames_preserve_order() {
    use tokio::{io::AsyncReadExt, net::TcpListener};
    timeout(Duration::from_secs(5), async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = trojan_config(
            listener.local_addr().unwrap().port(),
            "localhost.localdomain",
        );
        let (acceptor, roots) = tls_peer();
        let peer = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            let mut stream = acceptor.accept(socket).await.unwrap();
            let mut request = vec![0; UDP_REQUEST.len()];
            stream.read_exact(&mut request).await.unwrap();
            for expected in [b"first".as_slice(), b"second"] {
                let mut header = [0; 11];
                stream.read_exact(&mut header).await.unwrap();
                assert_eq!(&header[..7], b"\x01\x7f\x00\x00\x01\x00\x35");
                assert_eq!(
                    u16::from_be_bytes([header[7], header[8]]) as usize,
                    expected.len()
                );
                let mut data = vec![0; expected.len()];
                stream.read_exact(&mut data).await.unwrap();
                assert_eq!(data, expected);
            }
        });
        let connector = Connector::with_tls_roots(&config, roots).unwrap();
        let target = Target::new("127.0.0.1", 53).unwrap();
        let route = config.route(&target).await.unwrap();
        let session = connector
            .open_udp(route.proxy, &route.target)
            .await
            .unwrap();
        // On the current-thread executor no worker runs until the caller yields.
        session.send_to(b"first", &target).await.unwrap();
        session.send_to(b"second", &target).await.unwrap();
        let error = session.send_to(b"dropped", &target).await.unwrap_err();
        assert!(error.to_string().contains("queue full"));
        peer.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn route_target_pins_shadowsocks_udp_ip_instead_of_re_resolving_domain() {
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        crypto::CipherKind,
        relay::{
            socks5::Address,
            udprelay::proxy_socket::{ProxySocket, UdpSocketType},
        },
    };
    timeout(Duration::from_secs(3), async {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap(); let address = socket.local_addr().unwrap();
        let server_config = ServerConfig::new(address, "password", CipherKind::AES_128_GCM).unwrap();
        let socket: shadowsocks::net::UdpSocket = socket.into();
        let server = ProxySocket::from_socket(UdpSocketType::Server, Context::new_shared(ServerType::Server), &server_config, socket);
        let config = Config::parse(&format!("proxies: [{{name: edge, type: ss, server: localhost, port: {}, password: password, cipher: aes-128-gcm, udp: true}}]\nrules: ['IP-CIDR,127.0.0.0/8,edge', 'MATCH,REJECT']", address.port())).unwrap();
        let connector = Connector::new(&config).unwrap();
        let route = config.route(&Target::new("localhost", 53).unwrap()).await.unwrap();
        let session = connector.open_udp(route.proxy, &route.target).await.unwrap();
        session.send_to(b"pinned", &route.target).await.unwrap();
        let mut buffer = [0; 65536]; let (n, _, destination, _) = server.recv_from(&mut buffer).await.unwrap();
        assert_eq!(destination, Address::SocketAddress("127.0.0.1:53".parse().unwrap())); assert_eq!(&buffer[..n], b"pinned");
    }).await.unwrap();
}

#[tokio::test]
async fn direct_udp_session_handles_both_address_families_and_maximum_payload() {
    timeout(Duration::from_secs(3), async {
        let config = Config::parse("rules: ['MATCH,DIRECT']").unwrap();
        let connector = Connector::new(&config).unwrap();
        let ipv4 = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let ipv6 = UdpSocket::bind("[::1]:0").await.unwrap();
        let initial = Target::new("127.0.0.1", ipv4.local_addr().unwrap().port()).unwrap();
        let route = config.route(&initial).await.unwrap();
        let session = connector
            .open_udp(route.proxy, &route.target)
            .await
            .unwrap();
        for peer in [ipv4, ipv6] {
            let address = peer.local_addr().unwrap();
            let target = Target::new(address.ip().to_string(), address.port()).unwrap();
            session.send_to(&vec![42; 65507], &target).await.unwrap();
            let mut buffer = vec![0; 65536];
            let (n, client) = peer.recv_from(&mut buffer).await.unwrap();
            assert_eq!(n, 65507);
            assert!(buffer[..n].iter().all(|b| *b == 42));
            peer.send_to(b"reply", client).await.unwrap();
            let reply = session.recv_from().await.unwrap();
            assert_eq!(reply.source, target);
            assert_eq!(reply.payload, b"reply");
        }
    })
    .await
    .unwrap();
}
