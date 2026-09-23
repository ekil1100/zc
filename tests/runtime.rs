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
async fn connect_host_without_port_uses_the_target_port_and_transfers_payload() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = upstream.local_addr().unwrap();
        let runtime = Running::start("DIRECT").await;
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        // Undici omits the Host port for HTTPS CONNECT and sends these hop headers.
        client.write_all(format!("CONNECT {address} HTTP/1.1\r\nHost: 127.0.0.1\r\nConnection: close\r\nProxy-Connection: keep-alive\r\n\r\nhello").as_bytes()).await.unwrap();
        assert_eq!(http_head(&mut client).await, b"HTTP/1.1 200 Connection Established\r\n\r\n");
        let (mut server, _) = upstream.accept().await.unwrap();
        let mut payload = [0; 5];
        server.read_exact(&mut payload).await.unwrap();
        assert_eq!(&payload, b"hello");
        server.write_all(b"world").await.unwrap();
        client.read_exact(&mut payload).await.unwrap();
        assert_eq!(&payload, b"world");
        runtime.stop().await;
    }).await.unwrap();
}

#[tokio::test]
async fn connect_host_port_omission_keeps_authority_validation_and_reject_routing() {
    let runtime = Running::start("REJECT").await;
    for (target, host) in [
        ("example.com:443", "example.com"),
        ("example.com:8443", "EXAMPLE.COM"),
        ("127.0.0.1:8443", "127.0.0.1"),
        ("[::1]:443", "[::1]"),
        ("[::1]:8443", "[0:0:0:0:0:0:0:1]"),
    ] {
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client
            .write_all(format!("CONNECT {target} HTTP/1.1\r\nHost: {host}\r\n\r\n").as_bytes())
            .await
            .unwrap();
        // A valid request must reach REJECT, not be rejected as malformed or dial DIRECT.
        let reply = http_head(&mut client).await;
        assert!(
            reply.starts_with(b"HTTP/1.1 502"),
            "{target} / {host}: {reply:?}"
        );
    }
    for request in [
        "CONNECT example.com:443 HTTP/1.1\r\nHost: other.example\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:8443\r\n\r\n",
        "CONNECT example.com:8443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:+443\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:0\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:65536\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\nHost: user@example.com\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\nHost: example.com\r\nHost: example.com\r\n\r\n",
        "CONNECT example.com:443 HTTP/1.1\r\n\r\n",
        "CONNECT example.com HTTP/1.1\r\nHost: example.com\r\n\r\n",
        "CONNECT [::1]:443 HTTP/1.1\r\nHost: [::2]\r\n\r\n",
        "CONNECT [::1]:443 HTTP/1.1\r\nHost: [::1]:8443\r\n\r\n",
        "CONNECT [::1]:443 HTTP/1.1\r\nHost: [::1]:\r\n\r\n",
        "CONNECT [::1]:443 HTTP/1.1\r\nHost: ::1\r\n\r\n",
        "GET http://example.com:8443/ HTTP/1.1\r\nHost: example.com\r\n\r\n",
    ] {
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client.write_all(request.as_bytes()).await.unwrap();
        let reply = http_head(&mut client).await;
        assert!(reply.starts_with(b"HTTP/1.1 400"), "{request:?}: {reply:?}");
    }
    runtime.stop().await;
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
        client.write_all(format!("POST http://{address}/upload?q=yes HTTP/1.1\r\nHost: {address}\r\nContent-Length: 4\r\nProxy-Authorization: Basic secret\r\nProxy-Connection: keep-alive\r\nConnection: close, X-Hop\r\nX-Hop: remove-me\r\nX-End: retain-me\r\n\r\nbodyGET http://blocked.invalid/ HTTP/1.1\r\nHost: blocked.invalid\r\n\r\n").as_bytes()).await.unwrap();
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
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nTransfer-Encoding: gzip\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\nHost: other.example\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nHost: example.com\r\n\r\n",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: 1\r\nContent-Length: 2\r\n\r\nx",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: 1\r\nContent-Length: 1\r\n\r\nx",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: +1\r\n\r\nx",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nContent-Length: 16777217\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nUpgrade: websocket\r\n\r\n",
        "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\nConnection: upgrade\r\n\r\n",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nExpect: unsupported\r\n\r\n",
        "POST http://example.com/ HTTP/1.1\r\nHost: example.com\r\nConnection: Content-Length\r\nContent-Length: 1\r\n\r\nx",
        "GET ftp://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n",
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
        assert!(
            http_head(&mut client)
                .await
                .starts_with(b"HTTP/1.1 502 Bad Gateway\r\n")
        );
    }
    for (request, expected) in [
        (vec![5, 1, 0, 1, 127, 0, 0, 1, 0, 80], 2),
        (vec![5, 4, 0, 1, 127, 0, 0, 1, 0, 80], 7),
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
        client.write_all(format!("POST http://{address}/ HTTP/1.1\r\nHost: {address}\r\nContent-Length: 16777216\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
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
        for (host, status) in [("[::1]", "502"), ("localhost", "502")] {
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

#[tokio::test]
async fn bind_does_not_serve_until_run_and_source_rules_use_the_real_tcp_peer() {
    timeout(WAIT, async {
        let config = Config::parse("rules: ['PROCESS-NAME,unknown,REJECT', 'SRC-IP-CIDR,127.0.0.0/8,DIRECT', 'MATCH,REJECT']").unwrap();
        let runtime = Runtime::bind(config, 0).await.unwrap();
        let mut client = TcpStream::connect(runtime.local_addr().unwrap()).await.unwrap();
        client.write_all(&[5, 1, 0]).await.unwrap();
        assert!(timeout(Duration::from_millis(100), client.read(&mut [0; 2])).await.is_err());
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(runtime.run(async { let _ = stopped.await; }));
        let mut reply = [0; 2]; client.read_exact(&mut reply).await.unwrap(); assert_eq!(reply, [5, 0]);
        let peer = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut request = vec![5, 1, 0, 1, 127, 0, 0, 1]; request.extend_from_slice(&peer.local_addr().unwrap().port().to_be_bytes());
        client.write_all(&request).await.unwrap();
        let mut reply = [0; 10]; client.read_exact(&mut reply).await.unwrap(); assert_eq!(reply[1], 0);
        let _accepted = peer.accept().await.unwrap();
        stop.send(()).unwrap(); task.await.unwrap().unwrap();
    }).await.unwrap();
}

#[tokio::test]
async fn chunked_forward_and_keepalive_reparse_each_request_and_route() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = upstream.local_addr().unwrap();
        let config = Config::parse("rules: ['DOMAIN,blocked.invalid,REJECT', 'MATCH,DIRECT']").unwrap();
        let runtime = Runtime::bind(config, 0).await.unwrap();
        let addr = runtime.local_addr().unwrap();
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(runtime.run(async { let _ = stopped.await; }));
        let mut client = TcpStream::connect(addr).await.unwrap();
        client.write_all(format!("POST http://{address}/chunk HTTP/1.1\r\nHost: {address}\r\nTransfer-Encoding: chunked\r\nConnection: keep-alive\r\n\r\n4\r\nbody\r\n0\r\n\r\nGET http://blocked.invalid/ HTTP/1.1\r\nHost: blocked.invalid\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        let (mut server, _) = upstream.accept().await.unwrap();
        let head = http_head(&mut server).await;
        assert!(head.starts_with(b"POST /chunk HTTP/1.1\r\n"));
        assert!(String::from_utf8(head).unwrap().contains("Transfer-Encoding: chunked\r\n"));
        let mut body = [0; 14]; server.read_exact(&mut body).await.unwrap(); assert_eq!(&body, b"4\r\nbody\r\n0\r\n\r\n");
        assert!(timeout(Duration::from_millis(100), server.read(&mut [0])).await.is_err());
        server.write_all(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n2\r\nok\r\n0\r\n\r\n").await.unwrap();
        server.shutdown().await.unwrap();
        let first = http_head(&mut client).await; assert!(first.starts_with(b"HTTP/1.1 200"));
        assert!(!String::from_utf8(first).unwrap().to_ascii_lowercase().contains("connection: close"));
        let mut body = [0; 12]; client.read_exact(&mut body).await.unwrap(); assert_eq!(&body, b"2\r\nok\r\n0\r\n\r\n");
        assert!(http_head(&mut client).await.starts_with(b"HTTP/1.1 502 Bad Gateway\r\n"));
        assert!(timeout(Duration::from_millis(100), upstream.accept()).await.is_err());
        stop.send(()).unwrap(); task.await.unwrap().unwrap();
    }).await.unwrap();
}

#[tokio::test]
async fn origin_form_forward_uses_host_and_chunked_framing_conflicts_are_rejected() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = upstream.local_addr().unwrap();
        let runtime = Running::start("DIRECT").await;
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client
            .write_all(
                format!("GET /origin?q=1 HTTP/1.1\r\nHost: {address}\r\nConnection: close\r\n\r\n")
                    .as_bytes(),
            )
            .await
            .unwrap();
        let (mut server, _) = upstream.accept().await.unwrap();
        assert!(
            http_head(&mut server)
                .await
                .starts_with(b"GET /origin?q=1 HTTP/1.1\r\n")
        );
        server
            .write_all(b"HTTP/1.1 204 No Content\r\n\r\n")
            .await
            .unwrap();
        server.shutdown().await.unwrap();
        assert!(http_head(&mut client).await.starts_with(b"HTTP/1.1 204"));
        for headers in [
            "Transfer-Encoding: chunked\r\nContent-Length: 4",
            "Transfer-Encoding: chunked\r\nTransfer-Encoding: chunked",
            "Transfer-Encoding: gzip, chunked",
        ] {
            let mut client = TcpStream::connect(runtime.addr).await.unwrap();
            client
                .write_all(
                    format!(
                        "POST http://{address}/ HTTP/1.1\r\nHost: {address}\r\n{headers}\r\n\r\n"
                    )
                    .as_bytes(),
                )
                .await
                .unwrap();
            assert!(http_head(&mut client).await.starts_with(b"HTTP/1.1 400"));
        }
        runtime.stop().await;
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn empty_chunk_size_is_not_a_terminator_and_cannot_forward_a_second_request() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = upstream.local_addr().unwrap();
        let runtime = Running::start("DIRECT").await;
        for body in ["\r\n\r\n", ";ext=value\r\n\r\n", " 0\r\n\r\n"] {
            let mut client = TcpStream::connect(runtime.addr).await.unwrap();
            client.write_all(format!("POST http://{address}/ HTTP/1.1\r\nHost: {address}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{body}GET http://blocked.invalid/ HTTP/1.1\r\nHost: blocked.invalid\r\n\r\n").as_bytes()).await.unwrap();
            let (mut server, _) = upstream.accept().await.unwrap();
            assert!(http_head(&mut server).await.starts_with(b"POST /"));
            let mut bytes = Vec::new();
            timeout(Duration::from_secs(1), server.read_to_end(&mut bytes)).await.unwrap().unwrap();
            assert!(bytes.is_empty(), "invalid chunk size must not reach upstream: {bytes:?}");
        }
        runtime.stop().await;
    }).await.unwrap();
}

#[tokio::test]
async fn https_absolute_form_uses_verified_tls_with_the_original_hostname() {
    // Isolate the explicit fixture trust store from other tests and the user's state.
    if std::env::var_os("ZC_HTTPS_FORWARD_CHILD").is_none() {
        let home = tempfile::tempdir().unwrap();
        let cert = home.path().join("ca.pem");
        std::fs::write(&cert, include_bytes!("../testdata/e2e/trojan-cert.pem")).unwrap();
        let output = timeout(
            Duration::from_secs(15),
            tokio::process::Command::new(std::env::current_exe().unwrap())
                .arg("--exact")
                .arg("https_absolute_form_uses_verified_tls_with_the_original_hostname")
                .arg("--nocapture")
                .env("ZC_HTTPS_FORWARD_CHILD", "1")
                .env("SSL_CERT_FILE", &cert)
                .env("SSL_CERT_DIR", home.path())
                .env("HOME", home.path())
                .env("XDG_CONFIG_HOME", home.path())
                .env("XDG_STATE_HOME", home.path())
                .env("XDG_RUNTIME_DIR", home.path())
                .kill_on_drop(true)
                .output(),
        )
        .await
        .unwrap()
        .unwrap();
        assert!(
            output.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
        return;
    }
    use hickory_resolver::{
        config::{NameServerConfig, ResolverConfig},
        proto::{
            op::{Message, MessageType},
            rr::{RData, Record, RecordType, rdata::A},
        },
    };
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
    timeout(WAIT, async {
        let dns = tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
        let mut nameserver = NameServerConfig::udp(dns.local_addr().unwrap().ip());
        nameserver.connections[0].port = dns.local_addr().unwrap().port();
        let config = Config::parse("rules: ['IP-CIDR,127.0.0.0/8,DIRECT', 'MATCH,REJECT']").unwrap()
            .with_dns(zc::dns::Dns::from_config(ResolverConfig::from_name_servers(vec![nameserver])).unwrap());
        let dns_peer = tokio::spawn(async move {
            let mut bytes = [0; 4096];
            loop {
                let (n, peer) = dns.recv_from(&mut bytes).await.unwrap();
                let mut message = Message::from_vec(&bytes[..n]).unwrap();
                message.metadata.message_type = MessageType::Response;
                message.metadata.recursion_available = true;
                let query = &message.queries[0];
                if query.query_type() == RecordType::A {
                    message.answers.push(Record::from_rdata(query.name().clone(), 0, RData::A(A(std::net::Ipv4Addr::LOCALHOST))));
                }
                dns.send_to(&message.to_vec().unwrap(), peer).await.unwrap();
            }
        });
        let cert = CertificateDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-cert.pem")).unwrap();
        let key = PrivateKeyDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-key.pem")).unwrap();
        let tls = rustls::ServerConfig::builder_with_provider(std::sync::Arc::new(rustls::crypto::aws_lc_rs::default_provider()))
            .with_safe_default_protocol_versions().unwrap().with_no_client_auth().with_single_cert(vec![cert], key).unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(std::sync::Arc::new(tls));
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = upstream.local_addr().unwrap().port();
        let runtime = Runtime::bind(config, 0).await.unwrap();
        let addr = runtime.local_addr().unwrap();
        let (stop, stopped) = oneshot::channel();
        let task = tokio::spawn(runtime.run(async { let _ = stopped.await; }));
        let origin = tokio::spawn(async move {
            let (socket, _) = upstream.accept().await.unwrap();
            let mut stream = acceptor.accept(socket).await.unwrap();
            assert_eq!(stream.get_ref().1.server_name(), Some("localhost.localdomain"));
            let mut head = Vec::new();
            while !head.ends_with(b"\r\n\r\n") { head.push(stream.read_u8().await.unwrap()); }
            assert!(head.starts_with(b"GET /secure HTTP/1.1\r\n"));
            stream.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nsecure").await.unwrap();
            stream.shutdown().await.unwrap();
            let (socket, _) = upstream.accept().await.unwrap();
            assert!(acceptor.accept(socket).await.is_err(), "trusted certificate must still match the target identity");
        });
        let mut client = TcpStream::connect(addr).await.unwrap();
        client.write_all(format!("GET https://localhost.localdomain:{port}/secure HTTP/1.1\r\nHost: localhost.localdomain:{port}\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        let mut bytes = Vec::new(); client.read_to_end(&mut bytes).await.unwrap();
        assert_eq!(bytes, b"HTTP/1.1 200 OK\r\nContent-Length: 6\r\n\r\nsecure");
        let mut client = TcpStream::connect(addr).await.unwrap();
        client.write_all(format!("GET https://127.0.0.1:{port}/secure HTTP/1.1\r\nHost: 127.0.0.1:{port}\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        assert!(http_head(&mut client).await.starts_with(b"HTTP/1.1 502"));
        origin.await.unwrap();
        stop.send(()).unwrap(); task.await.unwrap().unwrap();
        dns_peer.abort(); let _ = dns_peer.await;
    }).await.unwrap();
}

#[tokio::test]
async fn forward_relays_continue_and_bounded_chunk_trailers() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = upstream.local_addr().unwrap();
        let runtime = Running::start("DIRECT").await;
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client.write_all(format!("POST http://{address}/ HTTP/1.1\r\nHost: {address}\r\nExpect: 100-continue\r\nTransfer-Encoding: chunked\r\nTrailer: X-Checksum\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        let (mut server, _) = upstream.accept().await.unwrap();
        assert!(http_head(&mut server).await.starts_with(b"POST / HTTP/1.1"));
        server.write_all(b"HTTP/1.1 100 Continue\r\n\r\n").await.unwrap();
        assert_eq!(http_head(&mut client).await, b"HTTP/1.1 100 Continue\r\n\r\n");
        let body = b"4;tag=value\r\nbody\r\n0\r\nX-Checksum: test\r\n\r\n";
        client.write_all(body).await.unwrap();
        let mut uploaded = vec![0; body.len()]; server.read_exact(&mut uploaded).await.unwrap(); assert_eq!(uploaded, body);
        server.write_all(b"HTTP/1.1 201 Created\r\nContent-Length: 0\r\n\r\n").await.unwrap();
        assert!(http_head(&mut client).await.starts_with(b"HTTP/1.1 201"));
        runtime.stop().await;
    }).await.unwrap();
}

#[tokio::test]
async fn early_final_response_cancels_an_unfinished_upload() {
    timeout(WAIT, async {
        let upstream = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = upstream.local_addr().unwrap();
        let runtime = Running::start("DIRECT").await;
        let mut client = TcpStream::connect(runtime.addr).await.unwrap();
        client.write_all(format!("POST http://{address}/ HTTP/1.1\r\nHost: {address}\r\nExpect: 100-continue\r\nContent-Length: 1024\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
        let (mut server, _) = upstream.accept().await.unwrap();
        let _head = http_head(&mut server).await;
        server.write_all(b"HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n").await.unwrap();
        let mut response = Vec::new();
        timeout(Duration::from_secs(1), client.read_to_end(&mut response)).await.unwrap().unwrap();
        assert!(response.starts_with(b"HTTP/1.1 413"));
        assert_eq!(server.read(&mut [0]).await.unwrap(), 0);
        runtime.stop().await;
    }).await.unwrap();
}
