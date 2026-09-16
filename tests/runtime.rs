use std::{net::SocketAddr, time::Duration};

use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    task::JoinHandle,
    time::timeout,
};
use zc::{config::Config, runtime::Runtime};

const WAIT: Duration = Duration::from_secs(5);

struct Running {
    addr: SocketAddr,
    stop: oneshot::Sender<()>,
    task: JoinHandle<anyhow::Result<()>>,
}

impl Running {
    async fn start(rule: &str) -> Self {
        let config = Config::parse(&format!(
            "bind-address: 127.0.0.1\nrules:\n  - MATCH,{rule}\n"
        ))
        .unwrap();
        let runtime = Runtime::bind(config, 0).await.unwrap();
        let addr = runtime.local_addr().unwrap();
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(runtime.run(async {
            let _ = stopped.await;
        }));
        Self { addr, stop, task }
    }

    async fn stop(self) {
        self.stop.send(()).unwrap();
        timeout(WAIT, self.task).await.unwrap().unwrap().unwrap();
    }
}

async fn http_head(stream: &mut TcpStream) -> Vec<u8> {
    timeout(WAIT, async {
        let mut head = Vec::new();
        while !head.ends_with(b"\r\n\r\n") {
            head.push(stream.read_u8().await.unwrap());
            assert!(head.len() <= 16384);
        }
        head
    })
    .await
    .unwrap()
}

#[tokio::test]
async fn direct_connect_transfers_real_payload() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let runtime = Running::start("DIRECT").await;
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client
            .write_all(
                format!(
                    "CONNECT {} HTTP/1.1\r\nHost: {}\r\n\r\n",
                    upstream.local_addr().unwrap(),
                    upstream.local_addr().unwrap()
                )
                .as_bytes(),
            )
            .await
            .unwrap();
        assert_eq!(
            http_head(&mut client).await,
            b"HTTP/1.1 200 Connection Established\r\n\r\n"
        );
        let (mut server, _) = upstream.accept().await.unwrap();
        client.write_all(b"hello").await.unwrap();
        let mut payload = [0; 5];
        server.read_exact(&mut payload).await.unwrap();
        assert_eq!(&payload, b"hello");
        server.write_all(b"world").await.unwrap();
        client.read_exact(&mut payload).await.unwrap();
        assert_eq!(&payload, b"world");
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn socks_connect_preserves_coalesced_payload_and_half_close() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = upstream.local_addr().unwrap().port();
        let runtime = Running::start("DIRECT").await;
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        let mut request = vec![5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1];
        request.extend_from_slice(&port.to_be_bytes());
        request.extend_from_slice(b"coalesced payload");
        client.write_all(&request).await.unwrap();
        let mut negotiation = [0; 2];
        client.read_exact(&mut negotiation).await.unwrap();
        assert_eq!(negotiation, [5, 0]);
        let mut reply = [0; 10];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(&reply[..4], &[5, 0, 0, 1]);
        client.shutdown().await.unwrap();
        let (mut server, _) = upstream.accept().await.unwrap();
        let mut body = Vec::new();
        server.read_to_end(&mut body).await.unwrap();
        assert_eq!(body, b"coalesced payload");
        server.write_all(b"after half-close").await.unwrap();
        server.shutdown().await.unwrap();
        body.clear();
        client.read_to_end(&mut body).await.unwrap();
        assert_eq!(body, b"after half-close");
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn forward_rewrites_one_request_and_never_pipelines_unchecked_bytes() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = upstream.local_addr().unwrap();
        let runtime = Running::start("DIRECT").await;
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client.write_all(format!("POST http://{address}/upload?q=yes HTTP/1.1\r\nHost: {address}\r\nContent-Length: 4\r\nProxy-Authorization: Basic secret\r\nProxy-Connection: keep-alive\r\nConnection: keep-alive, X-Hop\r\nX-Hop: remove-me\r\nX-End: retain-me\r\n\r\nbodyGET http://blocked.invalid/ HTTP/1.1\r\nHost: blocked.invalid\r\n\r\n").as_bytes()).await.unwrap();
        let (mut server, _) = upstream.accept().await.unwrap();
        let mut forwarded = http_head(&mut server).await;
        let mut body = [0; 4];
        server.read_exact(&mut body).await.unwrap();
        forwarded.extend_from_slice(&body);
        assert!(timeout(Duration::from_millis(100), server.read(&mut [0])).await.is_err(), "forward must neither send unchecked bytes nor FIN before the HTTP response");
        let forwarded = String::from_utf8(forwarded).unwrap();
        assert!(forwarded.starts_with("POST /upload?q=yes HTTP/1.1\r\n"));
        assert!(forwarded.contains(&format!("Host: {address}\r\n")));
        assert!(forwarded.contains("Connection: close\r\n"));
        assert!(forwarded.contains("X-End: retain-me\r\n"));
        assert!(forwarded.ends_with("\r\n\r\nbody"));
        assert!(!forwarded.contains("secret"));
        assert!(!forwarded.contains("remove-me"));
        assert!(!forwarded.contains("Proxy-"));
        assert!(!forwarded.contains("blocked.invalid"));
        server.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").await.unwrap();
        server.shutdown().await.unwrap();
        let mut response = Vec::new();
        client.read_to_end(&mut response).await.unwrap();
        assert_eq!(response, b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok");
        runtime.stop().await;
    }).await.unwrap();
}

#[tokio::test]
async fn ambiguous_http_framing_is_rejected_before_routing() {
    let runtime = Running::start("REJECT").await;
    let requests = [
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: chunked\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\nHost: other.example\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nHost: example.com\r\n\r\n",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: +1\r\n\r\nx",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: 16777217\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nConnection: upgrade\r\n\r\n",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nExpect: 100-continue\r\n\r\n",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nConnection: Content-Length\r\nContent-Length: 1\r\n\r\nx",
        "GET https://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET http://example.com/#fragment HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET http://user@example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET http://example.com:+80/ HTTP/1.1\r\nHost: example.com:+80\r\n\r\n",
        "CONNECT [::1]:+443 HTTP/1.1\r\nHost: [::1]:+443\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\nHost: example.com\n\n",
        "\r\nGET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\nHost : example.com\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n folded\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\nHost: other.example:443\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\nContent-Length: 1\r\n\r\nx",
    ];
    for request in requests {
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client.write_all(request.as_bytes()).await.unwrap();
        let reply = http_head(&mut client).await;
        assert!(reply.starts_with(b"HTTP/1.1 400"), "{request:?}: {reply:?}");
    }
    runtime.stop().await;
}

#[tokio::test]
async fn rejects_and_protocol_errors_have_explicit_wire_replies() {
    let runtime = Running::start("REJECT").await;
    for method in ["CONNECT example.com:443", "GET http://example.com:443/"] {
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client
            .write_all(format!("{method} HTTP/1.1\r\nHost: example.com:443\r\n\r\n").as_bytes())
            .await
            .unwrap();
        assert!(http_head(&mut client).await.starts_with(b"HTTP/1.1 403"));
    }
    for (request, expected) in [
        (vec![5, 1, 0, 1, 127, 0, 0, 1, 0, 80], 2),
        (vec![5, 3, 0, 1, 127, 0, 0, 1, 0, 80], 7),
        (vec![5, 2, 0, 1, 127, 0, 0, 1, 0, 80], 7),
        (vec![5, 1, 0, 99], 8),
        (vec![5, 1, 1, 1], 1),
        (vec![5, 1, 0, 3, 0], 8),
    ] {
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client.write_all(&[5, 2, 2, 0]).await.unwrap();
        let mut method = [0; 2];
        timeout(WAIT, client.read_exact(&mut method))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(method, [5, 0]);
        client.write_all(&request).await.unwrap();
        let mut reply = [0; 10];
        timeout(WAIT, client.read_exact(&mut reply))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(reply[1], expected);
    }
    let mut client = TcpStream::connect(runtime.addr).await.unwrap();
    client.write_all(&[5, 1, 2]).await.unwrap();
    let mut reply = [0; 2];
    timeout(WAIT, client.read_exact(&mut reply))
        .await
        .unwrap()
        .unwrap();
    assert_eq!(reply, [5, 255]);
    runtime.stop().await;
}

#[tokio::test]
async fn header_limit_is_inclusive_and_connect_keeps_coalesced_binary_payload() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = upstream.local_addr().unwrap();
        let runtime = Running::start("DIRECT").await;
        for length in [16384, 16385] {
            let mut client = TcpStream::connect(runtime.addr).await.unwrap();
            let mut request =
                format!("CONNECT {address} HTTP/1.1\r\nHost: {address}\r\nX-Pad: ").into_bytes();
            request.resize(length - 4, b'x');
            request.extend_from_slice(b"\r\n\r\n");
            client.write_all(&request).await.unwrap();
            let response = http_head(&mut client).await;
            if length == 16384 {
                assert!(response.starts_with(b"HTTP/1.1 200"));
                let (mut server, _) = upstream.accept().await.unwrap();
                client.shutdown().await.unwrap();
                assert_eq!(
                    server.read_u8().await.unwrap_err().kind(),
                    std::io::ErrorKind::UnexpectedEof
                );
            } else {
                assert!(response.starts_with(b"HTTP/1.1 400"));
            }
        }
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        let mut request =
            format!("CONNECT {address} HTTP/1.1\r\nHost: {address}\r\n\r\n").into_bytes();
        request.extend_from_slice(&[0, 255, 13, 10, 42]);
        client.write_all(&request).await.unwrap();
        assert!(http_head(&mut client).await.starts_with(b"HTTP/1.1 200"));
        client.shutdown().await.unwrap();
        let (mut server, _) = upstream.accept().await.unwrap();
        let mut payload = Vec::new();
        server.read_to_end(&mut payload).await.unwrap();
        assert_eq!(payload, [0, 255, 13, 10, 42]);
        server.write_all(b"half-close response").await.unwrap();
        server.shutdown().await.unwrap();
        payload.clear();
        client.read_to_end(&mut payload).await.unwrap();
        assert_eq!(payload, b"half-close response");
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn shutdown_closes_active_tunnels_and_pending_handshakes() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = upstream.local_addr().unwrap();
        let runtime = Running::start("DIRECT").await;
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client
            .write_all(format!("CONNECT {address} HTTP/1.1\r\nHost: {address}\r\n\r\n").as_bytes())
            .await
            .unwrap();
        assert!(http_head(&mut client).await.starts_with(b"HTTP/1.1 200"));
        let (mut server, _) = upstream.accept().await.unwrap();
        let mut pending = TcpStream::connect(runtime.addr).await.unwrap();
        pending.write_all(b"C").await.unwrap();
        let runtime_addr = runtime.addr;
        runtime.stop().await;
        assert_eq!(client.read(&mut [0]).await.unwrap(), 0);
        assert_eq!(server.read(&mut [0]).await.unwrap(), 0);
        match pending.read(&mut [0]).await {
            Ok(0) | Err(_) => {}
            result => panic!("pending handshake survived shutdown: {result:?}"),
        }
        assert!(TcpStream::connect(runtime_addr).await.is_err());
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn handshake_budget_includes_protocol_detection() {
    let runtime = Running::start("DIRECT").await;
    let mut client = TcpStream::connect(runtime.addr).await.unwrap();
    let started = tokio::time::Instant::now();
    tokio::time::sleep(Duration::from_secs(2)).await;
    client.write_all(&[5]).await.unwrap();
    let result = tokio::time::timeout_at(
        started + Duration::from_millis(11000),
        client.read(&mut [0]),
    )
    .await;
    assert!(
        matches!(result, Ok(Ok(0)) | Ok(Err(_))),
        "handshake must close within its original 10-second budget"
    );
    runtime.stop().await;
}

#[tokio::test]
async fn unreachable_outbound_returns_http_502_and_socks_connection_refused() {
    timeout(WAIT, async {
        let reserved = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = reserved.local_addr().unwrap();
        drop(reserved);
        let runtime = Running::start("DIRECT").await;
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client
            .write_all(format!("CONNECT {address} HTTP/1.1\r\nHost: {address}\r\n\r\n").as_bytes())
            .await
            .unwrap();
        assert!(http_head(&mut client).await.starts_with(b"HTTP/1.1 502"));
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        let mut request = vec![5, 1, 0, 5, 1, 0, 1, 127, 0, 0, 1];
        request.extend_from_slice(&address.port().to_be_bytes());
        client.write_all(&request).await.unwrap();
        let mut reply = [0; 12];
        client.read_exact(&mut reply).await.unwrap();
        assert_eq!(&reply[..4], &[5, 0, 5, 5]);
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn forward_streams_exact_16_mib_body_under_backpressure() {
    timeout(Duration::from_secs(15), async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = upstream.local_addr().unwrap();
        let runtime = Running::start("DIRECT").await;
        let server = tokio::spawn(async move {
            let (mut server, _) = upstream.accept().await.unwrap();
            let header = http_head(&mut server).await;
            assert!(header.starts_with(b"POST / HTTP/1.1\r\n"));
            tokio::time::sleep(Duration::from_millis(100)).await;
            let mut chunk = [0; 4093];
            let mut received = 0;
            while received < 16 * 1024 * 1024 {
                let capacity = chunk.len().min(16 * 1024 * 1024 - received);
                let count = server.read(&mut chunk[..capacity]).await.unwrap();
                assert!(count > 0, "body truncated before Content-Length");
                assert!(chunk[..count].iter().all(|byte| *byte == b'b'));
                received += count;
            }
            assert_eq!(received, 16 * 1024 * 1024);
            server.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok").await.unwrap();
            server.shutdown().await.unwrap();
        });
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client.write_all(format!("POST http://{address}/ HTTP/1.1\r\nHost: {address}\r\nContent-Length: 16777216\r\n\r\n").as_bytes()).await.unwrap();
        let chunk = [b'b'; 65536];
        for _ in 0..256 { client.write_all(&chunk).await.unwrap(); }
        let mut response = Vec::new();
        client.read_to_end(&mut response).await.unwrap();
        assert!(response.ends_with(b"\r\n\r\nok"));
        server.await.unwrap();
        runtime.stop().await;
    }).await.unwrap();
}

#[tokio::test]
async fn connections_are_bounded_and_release_capacity_without_detached_tasks() {
    timeout(Duration::from_secs(8), async {
        let runtime = Running::start("DIRECT").await;
        let mut clients = Vec::new();
        for _ in 0..1024 {
            let mut client = TcpStream::connect(runtime.addr).await.unwrap();
            client.write_all(&[5, 1, 0]).await.unwrap();
            let mut reply = [0; 2];
            client.read_exact(&mut reply).await.unwrap();
            assert_eq!(reply, [5, 0]);
            clients.push(client);
        }
        let mut queued = TcpStream::connect(runtime.addr).await.unwrap();
        queued.write_all(&[5, 1, 0]).await.unwrap();
        let mut reply = [0; 2];
        assert!(
            timeout(Duration::from_millis(100), queued.read_exact(&mut reply))
                .await
                .is_err()
        );
        drop(clients.pop());
        timeout(WAIT, queued.read_exact(&mut reply))
            .await
            .unwrap()
            .unwrap();
        assert_eq!(reply, [5, 0]);
        runtime.stop().await;
        for mut client in clients {
            assert!(matches!(client.read(&mut [0]).await, Ok(0) | Err(_)));
        }
        assert!(matches!(queued.read(&mut [0]).await, Ok(0) | Err(_)));
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn fragmented_socks_domain_and_ipv6_requests_transfer_payload() {
    timeout(WAIT, async {
        let runtime = Running::start("DIRECT").await;
        for ipv6 in [false, true] {
            let upstream = TcpListener::bind(if ipv6 { "[::1]:0" } else { "127.0.0.1:0" })
                .await
                .unwrap();
            let mut client = TcpStream::connect(runtime.addr).await.unwrap();
            let mut request = vec![5, 1, 0, 5, 1, 0];
            if ipv6 {
                request.push(4);
                request.extend_from_slice(&std::net::Ipv6Addr::LOCALHOST.octets());
            } else {
                request.extend_from_slice(&[3, 9]);
                request.extend_from_slice(b"127.0.0.1");
            }
            request.extend_from_slice(&upstream.local_addr().unwrap().port().to_be_bytes());
            for byte in request {
                client.write_all(&[byte]).await.unwrap();
            }
            let mut reply = [0; 12];
            client.read_exact(&mut reply).await.unwrap();
            assert_eq!(&reply[..4], &[5, 0, 5, 0]);
            let (mut server, _) = upstream.accept().await.unwrap();
            server.write_all(b"payload").await.unwrap();
            let mut payload = [0; 7];
            client.read_exact(&mut payload).await.unwrap();
            assert_eq!(&payload, b"payload");
        }
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn localhost_cannot_bypass_ipv6_reject_via_an_allowed_ipv4_answer() {
    timeout(WAIT, async {
        let forbidden = TcpListener::bind("[::1]:0").await.unwrap();
        let port = forbidden.local_addr().unwrap().port();
        let config = Config::parse(
            "rules: ['IP-CIDR,127.0.0.0/8,DIRECT', 'IP-CIDR6,::/0,REJECT', 'MATCH,REJECT']",
        )
        .unwrap();
        let runtime = Runtime::bind(config, 0).await.unwrap();
        let addr = runtime.local_addr().unwrap();
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(runtime.run(async {
            let _ = stopped.await;
        }));
        for (host, status) in [("[::1]", "403"), ("localhost", "502")] {
            let mut client = TcpStream::connect(addr).await.unwrap();
            client
                .write_all(
                    format!("CONNECT {host}:{port} HTTP/1.1\r\nHost: {host}:{port}\r\n\r\n")
                        .as_bytes(),
                )
                .await
                .unwrap();
            let reply = http_head(&mut client).await;
            assert!(
                reply.starts_with(format!("HTTP/1.1 {status}").as_bytes()),
                "{host}: {reply:?}"
            );
        }
        assert!(
            timeout(Duration::from_millis(100), forbidden.accept())
                .await
                .is_err()
        );
        stop.send(()).unwrap();
        task.await.unwrap().unwrap();
    })
    .await
    .unwrap();
}
