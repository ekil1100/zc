use std::{net::SocketAddr, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpStream, UdpSocket},
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};
use zc::{config::Config, runtime::Runtime};

const WAIT: Duration = Duration::from_secs(5);
const QUIET: Duration = Duration::from_millis(100);

struct Running {
    addr: SocketAddr,
    config: std::sync::Arc<Config>,
    stop: oneshot::Sender<()>,
    task: JoinHandle<anyhow::Result<()>>,
}
impl Running {
    async fn start(source: &str) -> Self {
        let config = Config::parse(source).unwrap();
        let runtime = Runtime::bind(config, 0).await.unwrap();
        let addr = runtime.local_addr().unwrap();
        let config = runtime.config();
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(runtime.run(async {
            let _ = stopped.await;
        }));
        Self {
            addr,
            config,
            stop,
            task,
        }
    }
    async fn stop(self) {
        self.stop.send(()).unwrap();
        timeout(WAIT, self.task).await.unwrap().unwrap().unwrap();
    }
}

async fn associate(addr: SocketAddr, requested: SocketAddr) -> (TcpStream, SocketAddr) {
    let mut control = TcpStream::connect(addr).await.unwrap();
    let mut request = vec![5, 1, 0, 5, 3, 0];
    encode_address(requested, &mut request);
    control.write_all(&request).await.unwrap();
    let mut reply = [0; 12];
    timeout(WAIT, control.read_exact(&mut reply))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(&reply[..6], &[5, 0, 5, 0, 0, 1]);
    let relay = SocketAddr::from((
        [reply[6], reply[7], reply[8], reply[9]],
        u16::from_be_bytes([reply[10], reply[11]]),
    ));
    assert!(relay.ip().is_loopback());
    assert_ne!(relay.port(), 0);
    (control, relay)
}

fn encode_address(address: SocketAddr, bytes: &mut Vec<u8>) {
    match address.ip() {
        std::net::IpAddr::V4(ip) => {
            bytes.push(1);
            bytes.extend_from_slice(&ip.octets());
        }
        std::net::IpAddr::V6(ip) => {
            bytes.push(4);
            bytes.extend_from_slice(&ip.octets());
        }
    }
    bytes.extend_from_slice(&address.port().to_be_bytes());
}
fn packet(address: SocketAddr, payload: &[u8]) -> Vec<u8> {
    let mut bytes = vec![0, 0, 0];
    encode_address(address, &mut bytes);
    bytes.extend_from_slice(payload);
    bytes
}

// A real SS wire peer keeps ingress tests from accidentally accepting DIRECT traffic.
struct SsPeer {
    socket: shadowsocks::relay::udprelay::proxy_socket::ProxySocket<shadowsocks::net::UdpSocket>,
    address: SocketAddr,
    destination: tokio::sync::Mutex<Option<shadowsocks::relay::socks5::Address>>,
}
impl SsPeer {
    async fn bind() -> Self {
        use shadowsocks::{
            config::{ServerConfig, ServerType},
            context::Context,
            crypto::CipherKind,
            relay::udprelay::proxy_socket::{ProxySocket, UdpSocketType},
        };
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let address = socket.local_addr().unwrap();
        let config = ServerConfig::new(address, "test-only", CipherKind::AES_128_GCM).unwrap();
        Self {
            socket: ProxySocket::from_socket(
                UdpSocketType::Server,
                Context::new_shared(ServerType::Server),
                &config,
                socket.into(),
            ),
            address,
            destination: tokio::sync::Mutex::new(None),
        }
    }
    fn config(&self, rules: &str) -> String {
        format!(
            "proxies: [{{name: udp-edge, type: ss, server: 127.0.0.1, port: {}, password: test-only, cipher: aes-128-gcm, udp: true}}]\n{rules}",
            self.address.port()
        )
    }
    fn local_addr(&self) -> std::io::Result<SocketAddr> {
        Ok(self.address)
    }
    async fn recv_from(&self, bytes: &mut [u8]) -> anyhow::Result<(usize, SocketAddr)> {
        let (n, client, destination, _) = self.socket.recv_from(bytes).await?;
        *self.destination.lock().await = Some(destination);
        Ok((n, client))
    }
    async fn send_to(&self, bytes: &[u8], client: SocketAddr) -> anyhow::Result<()> {
        let destination = self.destination.lock().await;
        self.socket
            .send_to(client, destination.as_ref().unwrap(), bytes)
            .await?;
        Ok(())
    }
}

#[tokio::test]
async fn shadowsocks_roundtrip_and_control_close_bound_the_udp_lifetime() {
    timeout(WAIT, async {
        let peer = SsPeer::bind().await;
        let runtime = Running::start(&peer.config("rules: ['MATCH,udp-edge']")).await;
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (mut control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
        let outgoing = packet(peer.local_addr().unwrap(), b"query");
        sender.send_to(&outgoing, relay).await.unwrap();
        let mut bytes = [0; 1024];
        let (n, from) = peer.recv_from(&mut bytes).await.unwrap();
        assert_eq!(&bytes[..n], b"query");
        peer.send_to(b"answer", from).await.unwrap();
        let (n, from) = sender.recv_from(&mut bytes).await.unwrap();
        assert_eq!(from, relay);
        assert_eq!(&bytes[..n], packet(peer.local_addr().unwrap(), b"answer"));
        control.shutdown().await.unwrap();
        assert_eq!(control.read(&mut bytes).await.unwrap(), 0);
        sender.send_to(&outgoing, relay).await.unwrap();
        assert!(timeout(QUIET, peer.recv_from(&mut bytes)).await.is_err());
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn invalid_datagrams_do_not_pin_and_valid_sender_is_pinned() {
    timeout(WAIT, async {
        let peer = SsPeer::bind().await;
        let runtime = Running::start(&peer.config("rules: ['MATCH,udp-edge']")).await;
        let bad = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let good = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (_control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
        let valid = packet(peer.local_addr().unwrap(), b"valid");
        let mut invalid = vec![
            vec![],
            vec![0],
            vec![0, 0, 0, 9],
            vec![0, 0, 0, 3, 0, 0, 53],
            valid[..9].to_vec(),
        ];
        for index in 0..3 {
            let mut bytes = valid.clone();
            bytes[index] = 1;
            invalid.push(bytes);
        }
        for bytes in invalid {
            bad.send_to(&bytes, relay).await.unwrap();
        }
        let mut buffer = [0; 100];
        assert!(timeout(QUIET, peer.recv_from(&mut buffer)).await.is_err());
        good.send_to(&valid, relay).await.unwrap();
        assert_eq!(peer.recv_from(&mut buffer).await.unwrap().0, 5);
        bad.send_to(&valid, relay).await.unwrap();
        assert!(timeout(QUIET, peer.recv_from(&mut buffer)).await.is_err());
        good.send_to(&valid, relay).await.unwrap();
        assert_eq!(peer.recv_from(&mut buffer).await.unwrap().0, 5);
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn explicit_source_port_is_enforced_and_mismatched_request_ip_is_denied() {
    timeout(WAIT, async {
        let peer = SsPeer::bind().await;
        let runtime = Running::start(&peer.config("rules: ['MATCH,udp-edge']")).await;
        let good = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let bad = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (_control, relay) = associate(runtime.addr, good.local_addr().unwrap()).await;
        let bytes = packet(peer.local_addr().unwrap(), b"pinned");
        bad.send_to(&bytes, relay).await.unwrap();
        let mut buffer = [0; 100];
        assert!(timeout(QUIET, peer.recv_from(&mut buffer)).await.is_err());
        good.send_to(&bytes, relay).await.unwrap();
        assert_eq!(peer.recv_from(&mut buffer).await.unwrap().0, 6);
        let mut control = TcpStream::connect(runtime.addr).await.unwrap();
        control
            .write_all(&[5, 1, 0, 5, 3, 0, 1, 192, 0, 2, 1, 0, 0])
            .await
            .unwrap();
        let mut reply = [0; 12];
        control.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply[3], 2);
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn source_context_selects_once_and_live_selection_only_affects_new_associations() {
    timeout(WAIT, async {
        let peer = SsPeer::bind().await;
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let port = sender.local_addr().unwrap().port();
        let runtime = Running::start(&peer.config(&format!("proxy-groups: [{{name: choice, type: select, proxies: [udp-edge, REJECT]}}]\nrules: ['PROCESS-NAME,unknown,REJECT', 'SRC-PORT,{port},choice', 'MATCH,REJECT']"))).await;
        let (_control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
        let bytes = packet(peer.address, b"route");
        sender.send_to(&bytes, relay).await.unwrap();
        let mut buffer = [0; 100];
        assert_eq!(peer.recv_from(&mut buffer).await.unwrap().0, 5);
        runtime.config.select("choice", "REJECT").unwrap();
        sender.send_to(&bytes, relay).await.unwrap();
        assert_eq!(peer.recv_from(&mut buffer).await.unwrap().0, 5);
        // A different destination still uses the original leaf, without re-routing.
        sender.send_to(&packet("127.0.0.1:9".parse().unwrap(), b"other"), relay).await.unwrap();
        assert_eq!(peer.recv_from(&mut buffer).await.unwrap().0, 5);
        assert_eq!(*peer.destination.lock().await, Some(shadowsocks::relay::socks5::Address::SocketAddress("127.0.0.1:9".parse().unwrap())));
        let (mut rejected, new_relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
        sender.send_to(&bytes, new_relay).await.unwrap();
        assert_eq!(rejected.read(&mut [0]).await.unwrap(), 0);
        assert!(timeout(QUIET, peer.recv_from(&mut buffer)).await.is_err());
        runtime.stop().await;
    }).await.unwrap();
}

#[tokio::test]
async fn admission_is_bounded_and_shutdown_closes_all_control_sockets() {
    timeout(WAIT, async {
        let peer = SsPeer::bind().await;
        let runtime = Running::start(&peer.config("rules: ['MATCH,udp-edge']")).await;
        let mut controls = Vec::new();
        for _ in 0..64 {
            controls.push(
                associate(runtime.addr, "0.0.0.0:0".parse().unwrap())
                    .await
                    .0,
            );
        }
        let mut excess = TcpStream::connect(runtime.addr).await.unwrap();
        excess
            .write_all(&[5, 1, 0, 5, 3, 0, 1, 0, 0, 0, 0, 0, 0])
            .await
            .unwrap();
        let mut reply = [0; 12];
        excess.read_exact(&mut reply).await.unwrap();
        assert_eq!(reply[3], 1);
        let mut released = controls.pop().unwrap();
        released.shutdown().await.unwrap();
        assert_eq!(released.read(&mut [0]).await.unwrap(), 0);
        controls.push(
            associate(runtime.addr, "0.0.0.0:0".parse().unwrap())
                .await
                .0,
        );
        runtime.stop().await;
        for mut control in controls {
            assert_eq!(control.read(&mut [0]).await.unwrap(), 0);
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn direct_reject_and_tcp_only_leaf_close_the_association_without_fallback() {
    timeout(WAIT, async {
        let peer = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let tcp_only = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let enabled = SsPeer::bind().await;
        for rule in ["DIRECT", "choice", "REJECT", "edge"] {
            let runtime = Running::start(&format!("proxies: [{{name: edge, type: ss, server: 127.0.0.1, port: {}, password: password, cipher: aes-128-gcm}}, {{name: enabled, type: ss, server: 127.0.0.1, port: {}, password: test-only, cipher: aes-128-gcm, udp: true}}]\nproxy-groups: [{{name: choice, type: select, proxies: [DIRECT]}}]\nrules: ['MATCH,{rule}']", tcp_only.local_addr().unwrap().port(), enabled.address.port())).await;
            let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let (mut control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
            sender.send_to(&packet(peer.local_addr().unwrap(), b"denied"), relay).await.unwrap();
            assert_eq!(control.read(&mut [0]).await.unwrap(), 0);
            assert!(timeout(QUIET, peer.recv_from(&mut [0; 100])).await.is_err());
            assert!(timeout(QUIET, tcp_only.accept()).await.is_err());
            assert!(timeout(QUIET, enabled.recv_from(&mut [0; 100])).await.is_err());
            runtime.stop().await;
        }
    }).await.unwrap();
}

#[tokio::test]
async fn ipv6_and_domain_targets_preserve_reply_address_and_empty_payload() {
    timeout(WAIT, async {
        let peer = SsPeer::bind().await;
        let runtime = Running::start(&peer.config("rules: ['MATCH,udp-edge']")).await;
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (_control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
        for ipv6 in [false, true] {
            let addr: SocketAddr = if ipv6 { "[::1]:53" } else { "127.0.0.1:53" }
                .parse()
                .unwrap();
            let outgoing = if ipv6 {
                packet(addr, b"")
            } else {
                let mut bytes = b"\0\0\0\x03\x09localhost".to_vec();
                bytes.extend_from_slice(&addr.port().to_be_bytes());
                bytes
            };
            sender.send_to(&outgoing, relay).await.unwrap();
            let mut buffer = [0; 100];
            let (n, from) = peer.recv_from(&mut buffer).await.unwrap();
            assert_eq!(n, 0);
            peer.send_to(b"", from).await.unwrap();
            let (n, _) = sender.recv_from(&mut buffer).await.unwrap();
            assert_eq!(&buffer[..n], &outgoing);
            let expected = if ipv6 {
                shadowsocks::relay::socks5::Address::SocketAddress(addr)
            } else {
                shadowsocks::relay::socks5::Address::DomainNameAddress("localhost".into(), 53)
            };
            assert_eq!(*peer.destination.lock().await, Some(expected));
        }
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn shadowsocks_mixed_ingress_auth_drop_recovers_without_direct_or_obfs() {
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        crypto::CipherKind,
        relay::{
            socks5::Address,
            udprelay::proxy_socket::{ProxySocket, UdpSocketType},
        },
    };
    timeout(WAIT, async {
        let raw = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
        raw.set_nonblocking(true).unwrap();
        let addr = raw.local_addr().unwrap();
        let invalid = UdpSocket::from_std(raw.try_clone().unwrap()).unwrap();
        let wrong_socket: shadowsocks::net::UdpSocket = UdpSocket::from_std(raw.try_clone().unwrap()).unwrap().into();
        let server_config = ServerConfig::new(addr, "password", CipherKind::AES_128_GCM).unwrap();
        let wrong_config = ServerConfig::new(addr, "wrong", CipherKind::AES_128_GCM).unwrap();
        let server: ProxySocket<shadowsocks::net::UdpSocket> = ProxySocket::from_socket(UdpSocketType::Server, Context::new_shared(ServerType::Server), &server_config, UdpSocket::from_std(raw).unwrap().into());
        let wrong = ProxySocket::from_socket(UdpSocketType::Server, Context::new_shared(ServerType::Server), &wrong_config, wrong_socket);
        let runtime = Running::start(&format!("proxies: [{{name: edge, type: ss, server: 127.0.0.1, port: {}, password: password, cipher: aes-128-gcm, udp: true, plugin: obfs, plugin-opts: {{mode: http, host: cover.example}}}}]\nrules: ['DOMAIN,example.com,edge', 'MATCH,REJECT']", addr.port())).await;
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (_control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
        sender.send_to(b"\0\0\0\x03\x0bexample.com\0\x35query", relay).await.unwrap();
        let mut buffer = [0; 1000];
        let (n, from, destination, _) = server.recv_from(&mut buffer).await.unwrap();
        assert_eq!(&buffer[..n], b"query");
        assert_eq!(destination, Address::DomainNameAddress("example.com".into(), 53));
        wrong.send_to(from, &destination, b"forged").await.unwrap();
        invalid.send_to(b"short salt", from).await.unwrap();
        assert!(timeout(QUIET, sender.recv_from(&mut buffer)).await.is_err());
        server.send_to(from, &destination, b"answer").await.unwrap();
        let (n, _) = sender.recv_from(&mut buffer).await.unwrap();
        assert_eq!(&buffer[..n], b"\0\0\0\x03\x0bexample.com\0\x35answer");
        runtime.stop().await;
    }).await.unwrap();
}

fn tls_acceptor() -> tokio_rustls::TlsAcceptor {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
    let cert =
        CertificateDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-cert.pem")).unwrap();
    let key =
        PrivateKeyDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-key.pem")).unwrap();
    let server = rustls::ServerConfig::builder_with_provider(std::sync::Arc::new(
        rustls::crypto::aws_lc_rs::default_provider(),
    ))
    .with_safe_default_protocol_versions()
    .unwrap()
    .with_no_client_auth()
    .with_single_cert(vec![cert], key)
    .unwrap();
    tokio_rustls::TlsAcceptor::from(std::sync::Arc::new(server))
}

#[tokio::test]
async fn trojan_domain_routes_before_resolution_and_control_close_cancels_partial_frame() {
    timeout(WAIT, async {
        let peer = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let runtime = Running::start(&format!("proxies: [{{name: edge, type: trojan, server: 127.0.0.1, port: {}, password: password, udp: true, skip-cert-verify: true}}]\nrules: ['DOMAIN,localhost,edge', 'MATCH,REJECT']", peer.local_addr().unwrap().port())).await;
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (mut control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
        sender.send_to(b"\0\0\0\x03\x09localhost\0\x35query", relay).await.unwrap();
        let (stream, _) = peer.accept().await.unwrap();
        let mut tls = tls_acceptor().accept(stream).await.unwrap();
        let mut auth = [0; 68]; tls.read_exact(&mut auth).await.unwrap();
        assert_eq!(&auth, b"d63dc919e201d7bc4c825630d2cf25fdc93d4b2f0d46706d29038d01\r\n\x03\x01\0\0\0\0\0\0\r\n");
        let address = shadowsocks::relay::socks5::Address::read_from(&mut tls).await.unwrap();
        assert!(matches!(address, shadowsocks::relay::socks5::Address::SocketAddress(addr) if addr.ip().is_loopback() && addr.port() == 53));
        let mut payload = [0; 9]; tls.read_exact(&mut payload).await.unwrap();
        assert_eq!(&payload, b"\0\x05\r\nquery");
        tls.write_all(b"\x01\x7f\0\0\x01\0\x35\0\x06\r\nanswer").await.unwrap();
        tls.flush().await.unwrap();
        let mut response = [0; 100];
        let (n, _) = sender.recv_from(&mut response).await.unwrap();
        assert_eq!(&response[..n], b"\0\0\0\x01\x7f\0\0\x01\0\x35answer");
        tls.write_all(b"\x01\x7f").await.unwrap(); tls.flush().await.unwrap();
        control.shutdown().await.unwrap();
        assert_eq!(control.read(&mut [0]).await.unwrap(), 0);
        assert!(matches!(tls.read(&mut [0]).await, Ok(0) | Err(_)));
        runtime.stop().await;
    }).await.unwrap();
}

#[tokio::test]
async fn control_close_cancels_pending_tls_setup_and_wrong_protocol_never_falls_back() {
    timeout(WAIT, async {
        let peer = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let direct = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let runtime = Running::start(&format!("proxies: [{{name: edge, type: trojan, server: 127.0.0.1, port: {}, password: password, udp: true, skip-cert-verify: true}}]\nrules: ['MATCH,edge']", peer.local_addr().unwrap().port())).await;
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        for wrong_protocol in [false, true] {
            let (mut control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
            sender.send_to(&packet(direct.local_addr().unwrap(), b"never direct"), relay).await.unwrap();
            let (mut stream, _) = peer.accept().await.unwrap();
            if wrong_protocol {
                stream.write_all(b"HTTP/1.1 200 OK\r\n\r\n").await.unwrap();
                let mut hello = Vec::new();
                timeout(Duration::from_secs(1), stream.read_to_end(&mut hello)).await.unwrap().unwrap();
                assert!(timeout(QUIET, direct.recv_from(&mut [0; 100])).await.is_err());
            }
            control.shutdown().await.unwrap();
            assert_eq!(control.read(&mut [0]).await.unwrap(), 0);
            let mut bytes = Vec::new();
            let _ = stream.read_to_end(&mut bytes).await;
            assert!(timeout(QUIET, direct.recv_from(&mut [0; 100])).await.is_err());
        }
        runtime.stop().await;
    }).await.unwrap();
}

#[tokio::test]
#[ignore = "Real five-minute idle-expiry scenario; run explicitly"]
async fn idle_association_expires_despite_invalid_udp_traffic() {
    timeout(Duration::from_secs(310), async {
        let peer = SsPeer::bind().await;
        let runtime = Running::start(&peer.config("rules: ['MATCH,udp-edge']")).await;
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (mut control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
        let traffic = async {
            loop {
                sender.send_to(b"malformed", relay).await.unwrap();
                tokio::time::sleep(Duration::from_secs(1)).await;
            }
        };
        let start = std::time::Instant::now();
        let mut byte = [0];
        tokio::select! {
            _ = traffic => unreachable!(),
            result = control.read(&mut byte) => assert_eq!(result.unwrap(), 0),
        }
        assert!(start.elapsed() >= Duration::from_secs(299));
        assert!(start.elapsed() < Duration::from_secs(305));
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn udp_ip_rule_pins_first_dns_answer_for_the_shadowsocks_wire() {
    timeout(WAIT, async {
        let peer = SsPeer::bind().await;
        let runtime = Running::start(&peer.config(
            "rules: ['IP-CIDR6,::1/128,udp-edge', 'IP-CIDR,127.0.0.0/8,REJECT', 'MATCH,REJECT']",
        ))
        .await;
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (_control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
        let request = b"\0\0\0\x03\x09localhost\0\x35pinned ipv6";
        sender.send_to(request, relay).await.unwrap();
        let mut bytes = [0; 100];
        let (n, _) = peer.recv_from(&mut bytes).await.unwrap();
        assert_eq!(&bytes[..n], b"pinned ipv6");
        assert_eq!(
            *peer.destination.lock().await,
            Some(shadowsocks::relay::socks5::Address::SocketAddress(
                "[::1]:53".parse().unwrap()
            ))
        );
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[cfg(target_os = "linux")]
#[tokio::test]
async fn nonmatching_udp_source_ip_cannot_claim_an_unpinned_association() {
    timeout(WAIT, async {
        let peer = SsPeer::bind().await;
        let runtime = Running::start(&peer.config("rules: ['MATCH,udp-edge']")).await;
        let attacker = UdpSocket::bind("127.0.0.2:0").await.unwrap();
        let sender = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let (_control, relay) = associate(runtime.addr, "0.0.0.0:0".parse().unwrap()).await;
        let bytes = packet(peer.local_addr().unwrap(), b"safe");
        attacker.send_to(&bytes, relay).await.unwrap();
        assert!(timeout(QUIET, peer.recv_from(&mut [0; 100])).await.is_err());
        sender.send_to(&bytes, relay).await.unwrap();
        assert_eq!(peer.recv_from(&mut [0; 100]).await.unwrap().0, 4);
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn associate_requires_an_enabled_shadowsocks_or_trojan_leaf() {
    timeout(WAIT, async {
        for source in [
            "rules: ['MATCH,DIRECT']",
            "proxies: [{name: edge, type: ss, server: 127.0.0.1, port: 9, password: test-only, cipher: aes-128-gcm}]\nrules: ['MATCH,edge']",
            "proxies: [{name: edge, type: trojan, server: 127.0.0.1, port: 9, password: test-only, udp: false, skip-cert-verify: true}]\nrules: ['MATCH,edge']",
        ] {
            let runtime = Running::start(source).await;
            let mut control = TcpStream::connect(runtime.addr).await.unwrap();
            control.write_all(&[5, 1, 0, 5, 3, 0, 1, 0, 0, 0, 0, 0, 0]).await.unwrap();
            let mut reply = [0; 12];
            control.read_exact(&mut reply).await.unwrap();
            assert_eq!(reply, [5, 0, 5, 7, 0, 1, 0, 0, 0, 0, 0, 0]);
            assert_eq!(control.read(&mut [0]).await.unwrap(), 0);
            runtime.stop().await;
        }
    }).await.unwrap();
}
