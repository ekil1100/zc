use std::{net::SocketAddr, sync::Arc, time::Duration};

use hickory_resolver::config::{NameServerConfig, ResolverConfig};
use tokio::{net::UdpSocket, task::JoinSet, time::timeout};
use zc::{dns::Dns, target::Target};

fn local_dns(address: SocketAddr) -> Dns {
    let mut server = NameServerConfig::udp(address.ip());
    server.connections[0].port = address.port();
    Dns::from_config(ResolverConfig::from_name_servers(vec![server])).unwrap()
}

#[tokio::test]
async fn silent_dns_has_a_two_second_deadline_and_releases_its_slot() {
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let dns = local_dns(socket.local_addr().unwrap());
    let target = Target::new("silent.example.", 443).unwrap();
    let started = std::time::Instant::now();
    let error = timeout(Duration::from_secs(3), dns.resolve(&target))
        .await
        .unwrap()
        .unwrap_err();
    assert!(error.to_string().contains("DNS"), "{error:#}");
    assert!(started.elapsed() >= Duration::from_millis(1900));
    let mut packet = [0; 4096];
    assert!(
        socket.try_recv_from(&mut packet).is_ok(),
        "lookup must reach the real UDP boundary"
    );
    while socket.try_recv_from(&mut packet).is_ok() {}
    let next_target = Target::new("next.example.", 443).unwrap();
    let mut next = Box::pin(dns.resolve(&next_target));
    tokio::select! {
        result = &mut next => panic!("new query should be pending: {result:?}"),
        result = timeout(Duration::from_secs(1), socket.recv_from(&mut packet)) => { result.unwrap().unwrap(); }
    }
}

#[tokio::test]
async fn stalled_queries_are_bounded_and_cancellation_reclaims_all_slots() {
    timeout(Duration::from_secs(5), async {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let dns = Arc::new(local_dns(socket.local_addr().unwrap()));
        let mut tasks = JoinSet::new();
        for index in 0..32 {
            let dns = dns.clone();
            tasks.spawn(async move {
                dns.resolve(&Target::new(format!("q{index}.example."), 443).unwrap())
                    .await
            });
        }
        let mut packet = [0; 4096];
        // Each lookup reserves two of the 64 query slots for parallel A and AAAA.
        for _ in 0..64 {
            socket.recv_from(&mut packet).await.unwrap();
        }
        let error = dns
            .resolve(&Target::new("overflow.example.", 443).unwrap())
            .await
            .unwrap_err();
        assert!(error.to_string().contains("64"), "{error:#}");
        tasks.abort_all();
        while tasks.join_next().await.is_some() {}
        for index in 0..32 {
            let dns = dns.clone();
            tasks.spawn(async move {
                dns.resolve(&Target::new(format!("fresh{index}.example."), 443).unwrap())
                    .await
            });
        }
        for _ in 0..64 {
            socket.recv_from(&mut packet).await.unwrap();
        }
        tasks.shutdown().await;
    })
    .await
    .unwrap();
}

#[test]
fn dropping_runtime_with_stalled_dns_does_not_wait_for_native_resolution() {
    let (done, completed) = std::sync::mpsc::channel();
    let thread = std::thread::spawn(move || {
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()
            .unwrap();
        runtime.block_on(async {
            let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let dns = local_dns(socket.local_addr().unwrap());
            tokio::spawn(async move {
                let _ = dns
                    .resolve(&Target::new("shutdown.example.", 443).unwrap())
                    .await;
            });
            timeout(Duration::from_secs(1), socket.recv_from(&mut [0; 4096]))
                .await
                .unwrap()
                .unwrap();
        });
        let started = std::time::Instant::now();
        drop(runtime);
        done.send(started.elapsed()).unwrap();
    });
    let elapsed = completed
        .recv_timeout(Duration::from_secs(3))
        .expect("runtime shutdown must not wait for DNS");
    assert!(elapsed < Duration::from_millis(500), "{elapsed:?}");
    thread.join().unwrap();
}

#[test]
fn empty_nameserver_config_is_rejected_without_public_dns_fallback() {
    let error = match Dns::from_config(ResolverConfig::from_name_servers(vec![])) {
        Ok(_) => panic!("missing DNS configuration must fail closed"),
        Err(error) => error,
    };
    assert!(error.to_string().contains("nameserver"));
}

#[test]
fn literal_addresses_need_neither_dns_nor_a_runtime_driver() {
    let dns = Dns::system();
    let runtime = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap();
    for host in ["127.0.0.1", "::1"] {
        let addresses = runtime
            .block_on(dns.resolve(&Target::new(host, 443).unwrap()))
            .unwrap();
        assert_eq!(addresses, vec![host.parse::<std::net::IpAddr>().unwrap()]);
    }
}

// Encode DNS with Hickory itself; no hand-written DNS protocol or private resolver mocks.
async fn answer(socket: &UdpSocket, ipv4_count: u8, ttl: u32) -> String {
    use hickory_resolver::proto::{
        op::{Message, MessageType},
        rr::{
            RData, Record, RecordType,
            rdata::{A, AAAA},
        },
    };
    let mut packet = [0; 4096];
    let (count, peer) = socket.recv_from(&mut packet).await.unwrap();
    let mut message = Message::from_vec(&packet[..count]).unwrap();
    message.metadata.message_type = MessageType::Response;
    message.metadata.recursion_available = true;
    let query = message.queries[0].clone();
    match query.query_type() {
        RecordType::A => {
            for index in 1..=ipv4_count {
                message.answers.push(Record::from_rdata(
                    query.name().clone(),
                    ttl,
                    RData::A(A(std::net::Ipv4Addr::new(127, 0, 0, index))),
                ));
            }
        }
        RecordType::AAAA => {
            message.answers.push(Record::from_rdata(
                query.name().clone(),
                ttl,
                RData::AAAA(AAAA(std::net::Ipv6Addr::LOCALHOST)),
            ));
        }
        kind => panic!("unexpected DNS query type: {kind}"),
    }
    socket
        .send_to(&message.to_vec().unwrap(), peer)
        .await
        .unwrap();
    query.name().to_string()
}

#[tokio::test]
async fn dns_results_are_dual_stack_and_reject_more_than_64_without_truncation() {
    timeout(Duration::from_secs(5), async {
        for (ipv4_count, valid) in [(63, true), (64, false)] {
            let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let dns = local_dns(socket.local_addr().unwrap());
            let peer = tokio::spawn(async move {
                for _ in 0..2 {
                    answer(&socket, ipv4_count, 0).await;
                }
            });
            let result = dns
                .resolve(&Target::new("answers.example.", 443).unwrap())
                .await;
            if valid {
                let addresses = result.unwrap();
                assert_eq!(addresses.len(), 64);
                assert_eq!(
                    addresses[0],
                    "127.0.0.1".parse::<std::net::IpAddr>().unwrap()
                );
                assert_eq!(addresses[63], "::1".parse::<std::net::IpAddr>().unwrap());
            } else {
                assert!(result.unwrap_err().to_string().contains("64"));
            }
            peer.await.unwrap();
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn hosts_file_precedes_the_configured_silent_dns_server() {
    let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
    let dns = local_dns(socket.local_addr().unwrap());
    let addresses = timeout(
        Duration::from_secs(1),
        dns.resolve(&Target::new("localhost", 80).unwrap()),
    )
    .await
    .unwrap()
    .unwrap();
    assert!(addresses.contains(&"127.0.0.1".parse().unwrap()));
    assert!(addresses.contains(&"::1".parse().unwrap()));
    assert!(socket.try_recv_from(&mut [0; 4096]).is_err());
}

#[tokio::test]
async fn route_snapshot_survives_zero_ttl_and_connector_does_not_resolve_it_again() {
    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
    };
    use zc::{config::Config, outbound::Connector};
    timeout(Duration::from_secs(5), async {
        for rule in ["IP-CIDR,127.0.0.1/32,DIRECT", "IP-CIDR,192.0.2.0/24,REJECT"] {
            let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let config = Config::parse(&format!(
                "rules: ['{rule}', 'DOMAIN,snapshot.example.,DIRECT']"
            ))
            .unwrap()
            .with_dns(local_dns(socket.local_addr().unwrap()));
            let connector = Connector::new(&config).unwrap();
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let target =
                Target::new("snapshot.example.", listener.local_addr().unwrap().port()).unwrap();
            let route = {
                let lookup = config.route(&target);
                let peer = async {
                    for _ in 0..2 {
                        answer(&socket, 1, 0).await;
                    }
                };
                let (route, ()) = tokio::join!(lookup, peer);
                route.unwrap()
            };
            assert_eq!(route.target.host(), "127.0.0.1");
            let mut client = connector.connect(route.proxy, &route.target).await.unwrap();
            let (mut server, _) = listener.accept().await.unwrap();
            server.write_all(b"snapshot").await.unwrap();
            let mut bytes = [0; 8];
            client.read_exact(&mut bytes).await.unwrap();
            assert_eq!(&bytes, b"snapshot");
            assert!(
                socket.try_recv_from(&mut [0; 4096]).is_err(),
                "zero-TTL destination must not be resolved a second time"
            );
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn config_and_connector_share_cache_for_proxy_server_names() {
    use tokio::net::TcpListener;
    use zc::{config::Config, outbound::Connector};
    timeout(Duration::from_secs(5), async {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let config = Config::parse(&format!("proxies: [{{name: edge, type: ss, server: server.example., port: {port}, password: password, cipher: aes-128-gcm}}]\nrules: ['IP-CIDR,127.0.0.0/8,edge']")).unwrap()
            .with_dns(local_dns(socket.local_addr().unwrap()));
        let connector = Connector::new(&config).unwrap();
        let target = Target::new("server.example.", 443).unwrap();
        let (route, ()) = tokio::join!(config.route(&target), async {
            for _ in 0..2 { assert_eq!(answer(&socket, 1, 60).await, "server.example."); }
        });
        let route = route.unwrap();
        let _stream = connector.connect(route.proxy, &route.target).await.unwrap();
        listener.accept().await.unwrap();
        assert!(socket.try_recv_from(&mut [0; 4096]).is_err(), "proxy server must use the per-config cached resolver");
    }).await.unwrap();
}

#[tokio::test]
async fn direct_without_ip_policy_can_try_the_next_dns_address() {
    use tokio::net::TcpListener;
    use zc::{config::Config, outbound::Connector, target::Target};
    timeout(Duration::from_secs(5), async {
        let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let listener = TcpListener::bind("[::1]:0").await.unwrap();
        let config = Config::parse("rules: ['MATCH,DIRECT']")
            .unwrap()
            .with_dns(local_dns(socket.local_addr().unwrap()));
        let connector = Connector::new(&config).unwrap();
        let target = Target::new("direct.example.", listener.local_addr().unwrap().port()).unwrap();
        let route = config.route(&target).await.unwrap();
        assert_eq!(route.target.host(), "direct.example.");
        let (stream, ()) = tokio::join!(connector.connect(route.proxy, &route.target), async {
            for _ in 0..2 {
                answer(&socket, 1, 0).await;
            }
        });
        let _stream = stream.unwrap();
        listener.accept().await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn runtime_shutdown_cancels_routing_direct_and_proxy_server_dns() {
    use tokio::{io::AsyncWriteExt, net::TcpStream, sync::oneshot};
    use zc::{config::Config, runtime::Runtime};
    timeout(Duration::from_secs(5), async {
        for source in [
            "rules: ['IP-CIDR,127.0.0.0/8,DIRECT', 'MATCH,REJECT']",
            "rules: ['MATCH,DIRECT']",
            "proxies: [{name: edge, type: ss, server: proxy.example., port: 443, password: password, cipher: aes-128-gcm}]\nrules: ['MATCH,edge']",
            "proxies: [{name: edge, type: trojan, server: proxy.example., port: 443, password: password, skip-cert-verify: true}]\nrules: ['MATCH,edge']",
        ] {
            let socket = UdpSocket::bind("127.0.0.1:0").await.unwrap();
            let config = Config::parse(source).unwrap().with_dns(local_dns(socket.local_addr().unwrap()));
            let runtime = Runtime::bind(config, 0).await.unwrap();
            let addr = runtime.local_addr().unwrap();
            let (stop, stopped) = oneshot::channel();
            let task = tokio::spawn(runtime.run(async { let _ = stopped.await; }));
            let mut client = TcpStream::connect(addr).await.unwrap();
            client.write_all(b"CONNECT destination.example.:443 HTTP/1.1\r\nHost: destination.example.:443\r\n\r\n").await.unwrap();
            let mut packet = [0; 4096];
            let (count, _) = socket.recv_from(&mut packet).await.unwrap();
            let message = hickory_resolver::proto::op::Message::from_vec(&packet[..count]).unwrap();
            let expected = if source.starts_with("proxies:") { "proxy.example." } else { "destination.example." };
            assert_eq!(message.queries[0].name().to_string(), expected);
            stop.send(()).unwrap();
            timeout(Duration::from_millis(500), task).await.unwrap().unwrap().unwrap();
            assert!(TcpStream::connect(addr).await.is_err());
        }
    }).await.unwrap();
}
