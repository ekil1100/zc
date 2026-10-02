use std::{net::IpAddr, time::Duration};

use hickory_resolver::{
    config::{NameServerConfig, ResolverConfig},
    proto::{
        op::{Message, MessageType},
        rr::{
            RData, Record, RecordType,
            rdata::{A, AAAA},
        },
    },
};
use shadowsocks::{
    config::{ServerConfig, ServerType},
    context::Context,
    crypto::CipherKind,
    relay::{socks5::Address, tcprelay::proxy_stream::ProxyServerStream},
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, UdpSocket},
    task::JoinHandle,
    time::timeout,
};
use zc::{config::Config, dns::Dns, outbound::Connector, target::Target};

const WAIT: Duration = Duration::from_secs(5);
const DOMAIN: &str = "registry.example.";

// Real DNS responses reproduce a successful lookup containing an unsuitable IP.
// No system DNS, production proxy, or private resolver mock is involved.
async fn dns_answers(addresses: &[&str]) -> (Dns, JoinHandle<()>) {
    let addresses: Vec<IpAddr> = addresses.iter().map(|ip| ip.parse().unwrap()).collect();
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let bound = socket.local_addr().unwrap();
    let mut server = NameServerConfig::udp(bound.ip());
    server.connections[0].port = bound.port();
    let dns = Dns::from_config(ResolverConfig::from_name_servers(vec![server])).unwrap();
    let task = tokio::spawn(async move {
        for _ in 0..2 {
            let mut packet = [0; 4096];
            let (count, peer) = socket.recv_from(&mut packet).await.unwrap();
            let mut response = Message::from_vec(&packet[..count]).unwrap();
            response.metadata.message_type = MessageType::Response;
            response.metadata.recursion_available = true;
            let query = response.queries[0].clone();
            for ip in &addresses {
                let data = match (query.query_type(), ip) {
                    (RecordType::A, IpAddr::V4(ip)) => RData::A(A(*ip)),
                    (RecordType::AAAA, IpAddr::V6(ip)) => RData::AAAA(AAAA(*ip)),
                    _ => continue,
                };
                response
                    .answers
                    .push(Record::from_rdata(query.name().clone(), 0, data));
            }
            socket
                .send_to(&response.to_vec().unwrap(), peer)
                .await
                .unwrap();
        }
    });
    (dns, task)
}

fn ss_source(port: u16, rules: &str) -> String {
    format!(
        "proxies: [{{name: edge, type: ss, server: 127.0.0.1, port: {port}, password: test-only, cipher: aes-128-gcm, udp: true}}]\nrules: [{rules}]"
    )
}

#[tokio::test]
async fn tcp_proxy_keeps_domain_after_unmatched_direct_geoip() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let peer = tokio::spawn(async move {
            let server = ServerConfig::new(address, "test-only", CipherKind::AES_128_GCM).unwrap();
            let (stream, _) = listener.accept().await.unwrap();
            let mut stream = ProxyServerStream::from_stream(
                Context::new_shared(ServerType::Server),
                stream,
                server.method(),
                server.key(),
            );
            let destination = stream.handshake().await.unwrap();
            stream.write_all(b"ready").await.unwrap();
            stream.flush().await.unwrap();
            destination
        });
        let (dns, dns_peer) = dns_answers(&["141.193.154.70"]).await;
        let config = Config::parse(&ss_source(
            address.port(),
            "'GEOIP,CN,DIRECT', 'MATCH,edge'",
        ))
        .unwrap()
        .with_dns(dns);
        let connector = Connector::new(&config).unwrap();
        let route = config
            .route(&Target::new(DOMAIN, 443).unwrap())
            .await
            .unwrap();
        let mut stream = connector.connect(route.proxy, &route.target).await.unwrap();
        let mut greeting = [0; 5];
        stream.read_exact(&mut greeting).await.unwrap();
        assert_eq!(&greeting, b"ready");
        dns_peer.await.unwrap();
        assert_eq!(
            peer.await.unwrap(),
            Address::DomainNameAddress(DOMAIN.into(), 443),
            "an unmatched DIRECT split must not force its local DNS answer onto the proxy"
        );
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn domain_routing_exception_preserves_restrictive_prefixes_and_matched_ips() {
    timeout(WAIT, async {
        for (rules, expected_host, expected_proxy) in [
            ("'GEOIP,CN,DIRECT', 'MATCH,via'", DOMAIN, "edge"),
            ("'IP-CIDR,192.0.2.0/24,local', 'DOMAIN,registry.example,edge'", DOMAIN, "edge"),
            ("'IP-CIDR6,2001:db9::/32,DIRECT', 'DST-PORT,443,edge'", DOMAIN, "edge"),
            ("'IP-CIDR,0.0.0.0/0,REJECT,no-resolve', 'GEOIP,CN,DIRECT', 'MATCH,edge'", DOMAIN, "edge"),
            ("'GEOIP,CN,DIRECT', 'IP-CIDR,0.0.0.0/0,REJECT,no-resolve', 'MATCH,edge'", DOMAIN, "edge"),
            ("'GEOIP,CN,DIRECT', 'DOMAIN,registry.example,edge', 'IP-CIDR,0.0.0.0/0,REJECT'", DOMAIN, "edge"),
            ("'GEOIP,CN,DIRECT', 'MATCH,tls-edge'", DOMAIN, "tls-edge"),
            ("'GEOIP,CN,DIRECT', 'MATCH,any-edge'", DOMAIN, "any-edge"),
            ("'IP-CIDR,192.0.2.0/24,REJECT', 'GEOIP,CN,DIRECT', 'MATCH,edge'", "141.193.154.70", "edge"),
            ("'GEOIP,CN,DIRECT', 'IP-CIDR,192.0.2.0/24,deny', 'MATCH,edge'", "141.193.154.70", "edge"),
            ("'GEOIP,CN,blocked', 'MATCH,edge'", "141.193.154.70", "edge"),
            ("'GEOIP,CN,DIRECT', 'IP-CIDR,192.0.2.0/24,blocked', 'MATCH,edge'", "141.193.154.70", "edge"),
            ("'GEOIP,CN,direct-group', 'MATCH,edge'", "141.193.154.70", "edge"),
            ("'IP-CIDR,192.0.2.0/24,tls-edge', 'MATCH,edge'", "141.193.154.70", "edge"),
            ("'GEOIP,CN,DIRECT', 'MATCH,local'", "141.193.154.70", "local"),
            ("'GEOIP,CN,DIRECT', 'MATCH,direct-group'", "141.193.154.70", "local"),
            ("'GEOIP,CN,DIRECT', 'MATCH,REJECT'", "141.193.154.70", "REJECT"),
            ("'IP-CIDR,104.16.0.0/12,edge', 'MATCH,REJECT'", "104.16.7.34", "edge"),
            ("'GEOIP,JP,edge', 'MATCH,REJECT'", "81.1.2.3", "edge"),
            ("'IP-CIDR6,2001:db8::/32,edge', 'MATCH,REJECT'", "2001:db8::1", "edge"),
            ("'IP-CIDR,104.16.0.0/12,blocked', 'MATCH,edge'", "104.16.7.34", "deny"),
        ] {
            let (dns, peer) = dns_answers(&["141.193.154.70", "104.16.7.34", "81.1.2.3", "2001:db8::1"]).await;
            let source = format!(
                "proxies:\n  - {{name: edge, type: ss, server: 127.0.0.1, port: 443, password: test-only, cipher: aes-128-gcm}}\n  - {{name: local, type: direct}}\n  - {{name: deny, type: reject}}\n  - {{name: tls-edge, type: trojan, server: 127.0.0.1, port: 443, password: test-only, sni: front.example}}\n  - {{name: any-edge, type: anytls, server: 127.0.0.1, port: 443, password: test-only, sni: front.example}}\nproxy-groups:\n  - {{name: via, type: select, proxies: [edge]}}\n  - {{name: inner, type: select, proxies: [deny]}}\n  - {{name: blocked, type: select, proxies: [inner]}}\n  - {{name: direct-group, type: select, proxies: [local, deny]}}\nrules: [{rules}]"
            );
            let config = Config::parse(&source).unwrap().with_dns(dns);
            let route = config.route(&Target::new(DOMAIN, 443).unwrap()).await.unwrap();
            peer.await.unwrap();
            assert_eq!(route.target.host(), expected_host, "{rules}");
            assert_eq!(route.proxy.name, expected_proxy, "{rules}");
        }
    }).await.unwrap();
}

#[tokio::test]
async fn literal_ip_and_early_domain_matches_do_not_query_dns() {
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let bound = socket.local_addr().unwrap();
    let mut server = NameServerConfig::udp(bound.ip());
    server.connections[0].port = bound.port();
    let dns = Dns::from_config(ResolverConfig::from_name_servers(vec![server])).unwrap();
    let config = Config::parse(&ss_source(
        443,
        "'DOMAIN,registry.example,edge', 'GEOIP,CN,DIRECT', 'MATCH,edge'",
    ))
    .unwrap()
    .with_dns(dns);
    for host in [DOMAIN, "141.193.154.70", "2001:db8::1"] {
        let target = Target::new(host, 443).unwrap();
        let route = timeout(Duration::from_millis(100), config.route(&target))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(route.target, target);
        assert_eq!(route.proxy.name, "edge");
    }
    assert!(socket.try_recv_from(&mut [0; 4096]).is_err());
}

#[tokio::test]
async fn dns_failure_during_direct_split_is_not_a_proxy_fallback() {
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let bound = socket.local_addr().unwrap();
    let mut server = NameServerConfig::udp(bound.ip());
    server.connections[0].port = bound.port();
    let dns = Dns::from_config(ResolverConfig::from_name_servers(vec![server])).unwrap();
    let config = Config::parse(&ss_source(443, "'GEOIP,CN,DIRECT', 'MATCH,edge'"))
        .unwrap()
        .with_dns(dns);
    let error = timeout(
        Duration::from_secs(3),
        config.route(&Target::new(DOMAIN, 443).unwrap()),
    )
    .await
    .unwrap()
    .err()
    .expect("a failed lookup must not bypass routing");
    assert!(error.to_string().contains("DNS"), "{error:#}");
    assert!(socket.try_recv_from(&mut [0; 4096]).is_ok());
}

#[tokio::test]
async fn mixed_tcp_tunnels_preserve_remote_domain_and_tls_identity_checks() {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, ServerName, pem::PemObject};
    use std::sync::Arc;
    use tokio::{net::TcpStream, sync::oneshot};
    use tokio_rustls::{TlsAcceptor, TlsConnector};
    use zc::runtime::Runtime;

    timeout(Duration::from_secs(10), async {
        for (socks, valid_name) in [(false, true), (true, true), (false, false)] {
            let cert = CertificateDer::from_pem_slice(include_bytes!(
                "../testdata/e2e/dns-route-cert.pem"
            ))
            .unwrap();
            let key =
                PrivateKeyDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-key.pem"))
                    .unwrap();
            let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
            let mut roots = rustls::RootCertStore::empty();
            roots.add(cert.clone()).unwrap();
            let client_config = rustls::ClientConfig::builder_with_provider(provider.clone())
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_root_certificates(roots)
                .with_no_client_auth();
            let server_config = rustls::ServerConfig::builder_with_provider(provider)
                .with_safe_default_protocol_versions()
                .unwrap()
                .with_no_client_auth()
                .with_single_cert(vec![cert], key)
                .unwrap();
            let acceptor = TlsAcceptor::from(Arc::new(server_config));
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let address = listener.local_addr().unwrap();
            let peer = tokio::spawn(async move {
                let server =
                    ServerConfig::new(address, "test-only", CipherKind::AES_128_GCM).unwrap();
                let (stream, _) = listener.accept().await.unwrap();
                let mut stream = ProxyServerStream::from_stream(
                    Context::new_shared(ServerType::Server),
                    stream,
                    server.method(),
                    server.key(),
                );
                let destination = stream.handshake().await.unwrap();
                match acceptor.accept(stream).await {
                    Ok(mut tls) => {
                        assert!(valid_name);
                        let mut request = [0; 4];
                        tls.read_exact(&mut request).await.unwrap();
                        assert_eq!(&request, b"ping");
                        tls.write_all(b"pong").await.unwrap();
                        tls.shutdown().await.unwrap();
                    }
                    Err(_) => assert!(!valid_name),
                }
                destination
            });
            let (dns, dns_peer) = dns_answers(&["141.193.154.70"]).await;
            let config = Config::parse(&ss_source(
                address.port(),
                "'GEOIP,CN,DIRECT', 'MATCH,edge'",
            ))
            .unwrap()
            .with_dns(dns);
            let runtime = Runtime::bind(config, 0).await.unwrap();
            let bound = runtime.local_addr().unwrap();
            let (stop, stopped) = oneshot::channel();
            let task = tokio::spawn(runtime.run(async {
                let _ = stopped.await;
            }));
            let mut tunnel = TcpStream::connect(bound).await.unwrap();
            if socks {
                tunnel.write_all(&[5, 1, 0]).await.unwrap();
                let mut hello = [0; 2];
                tunnel.read_exact(&mut hello).await.unwrap();
                assert_eq!(hello, [5, 0]);
                let mut request = vec![5, 1, 0, 3, 13];
                request.extend_from_slice(b"front.example");
                request.extend_from_slice(&[1, 187]);
                tunnel.write_all(&request).await.unwrap();
                let mut reply = [0; 10];
                tunnel.read_exact(&mut reply).await.unwrap();
                assert_eq!(&reply[..4], &[5, 0, 0, 1]);
            } else {
                tunnel
                    .write_all(
                        b"CONNECT front.example:443 HTTP/1.1\r\nHost: front.example:443\r\n\r\n",
                    )
                    .await
                    .unwrap();
                let mut reply = Vec::new();
                while !reply.ends_with(b"\r\n\r\n") {
                    assert!(reply.len() < 1024);
                    reply.push(tunnel.read_u8().await.unwrap());
                }
                assert!(reply.starts_with(b"HTTP/1.1 200"));
            }
            let name = if valid_name {
                "front.example"
            } else {
                "wrong.example"
            };
            let result = TlsConnector::from(Arc::new(client_config))
                .connect(ServerName::try_from(name).unwrap(), tunnel)
                .await;
            if valid_name {
                let mut tls = result.unwrap();
                tls.write_all(b"ping").await.unwrap();
                let mut response = [0; 4];
                tls.read_exact(&mut response).await.unwrap();
                assert_eq!(&response, b"pong");
            } else {
                let error = result.unwrap_err();
                assert!(error.to_string().contains("not valid for name"), "{error}");
            }
            assert_eq!(
                peer.await.unwrap(),
                Address::DomainNameAddress("front.example".into(), 443)
            );
            dns_peer.await.unwrap();
            stop.send(()).unwrap();
            task.await.unwrap().unwrap();
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn socks_udp_keeps_its_dns_snapshot_after_direct_split() {
    use shadowsocks::relay::udprelay::proxy_socket::{ProxySocket, UdpSocketType};
    use tokio::{net::TcpStream, sync::oneshot};
    use zc::runtime::Runtime;

    timeout(WAIT, async {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let address = socket.local_addr().unwrap();
        let server = ServerConfig::new(address, "test-only", CipherKind::AES_128_GCM).unwrap();
        let peer: ProxySocket<shadowsocks::net::UdpSocket> = ProxySocket::from_socket(
            UdpSocketType::Server,
            Context::new_shared(ServerType::Server),
            &server,
            socket.into(),
        );
        let (dns, dns_peer) = dns_answers(&["141.193.154.70"]).await;
        let config = Config::parse(&ss_source(
            address.port(),
            "'GEOIP,CN,DIRECT', 'MATCH,edge'",
        ))
        .unwrap()
        .with_dns(dns);
        let runtime = Runtime::bind(config, 0).await.unwrap();
        let bound = runtime.local_addr().unwrap();
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(runtime.run(async {
            let _ = stopped.await;
        }));
        let mut control = TcpStream::connect(bound).await.unwrap();
        control
            .write_all(&[5, 1, 0, 5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
            .await
            .unwrap();
        let mut reply = [0; 12];
        control.read_exact(&mut reply).await.unwrap();
        assert_eq!(&reply[..6], &[5, 0, 5, 0, 0, 1]);
        let relay = std::net::SocketAddr::from((
            [reply[6], reply[7], reply[8], reply[9]],
            u16::from_be_bytes([reply[10], reply[11]]),
        ));
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let mut packet = vec![0, 0, 0, 3, DOMAIN.len() as u8];
        packet.extend_from_slice(DOMAIN.as_bytes());
        packet.extend_from_slice(&[0, 53]);
        packet.extend_from_slice(b"query");
        sender.send_to(&packet, relay).await.unwrap();
        let mut bytes = [0; 1024];
        let (count, _, destination, _) = peer.recv_from(&mut bytes).await.unwrap();
        assert_eq!(&bytes[..count], b"query");
        assert_eq!(
            destination,
            Address::SocketAddress("141.193.154.70:53".parse().unwrap())
        );
        dns_peer.await.unwrap();
        drop(control);
        stop.send(()).unwrap();
        task.await.unwrap().unwrap();
    })
    .await
    .unwrap();
}
