use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};
use zc::simple_obfs::HttpObfsStream;

#[tokio::test]
async fn http_upgrade_preserves_fragmented_header_binary_tail_and_half_close() {
    timeout(Duration::from_secs(3), async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let peer = tokio::spawn(async move {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut header = Vec::new();
            while !header.ends_with(b"\r\n\r\n") {
                header.push(socket.read_u8().await.unwrap());
            }
            let text = String::from_utf8(header).unwrap();
            assert!(text.starts_with("GET / HTTP/1.1\r\nHost: cover.example:"));
            assert!(text.contains("\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"));
            assert!(text.contains("\r\nContent-Length: 4\r\n"));
            let mut body = [0; 4];
            socket.read_exact(&mut body).await.unwrap();
            assert_eq!(body, [0, 255, 1, 128]);
            socket
                .write_all(b"HTTP/1.1 101 Switching Protocols\r\nUpgr")
                .await
                .unwrap();
            tokio::time::sleep(Duration::from_millis(20)).await;
            socket
                .write_all(b"ade: websocket\r\n\r\n\xff\x00tail")
                .await
                .unwrap();
            let mut rest = Vec::new();
            socket.read_to_end(&mut rest).await.unwrap();
            assert_eq!(rest, b"raw");
            socket.write_all(b"after FIN").await.unwrap();
        });
        let socket = TcpStream::connect(address).await.unwrap();
        let mut stream = HttpObfsStream::new(socket, "cover.example", address.port()).unwrap();
        stream.write_all(&[0, 255, 1, 128]).await.unwrap();
        stream.flush().await.unwrap();
        let mut tail = [0; 6];
        stream.read_exact(&mut tail).await.unwrap();
        assert_eq!(&tail, b"\xff\x00tail");
        stream.write_all(b"raw").await.unwrap();
        stream.shutdown().await.unwrap();
        let mut rest = Vec::new();
        stream.read_to_end(&mut rest).await.unwrap();
        assert_eq!(rest, b"after FIN");
        peer.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn invalid_upgrade_truncation_and_oversized_headers_fail_closed() {
    timeout(Duration::from_secs(5), async {
        let mut too_large = b"HTTP/1.1 101 Switching Protocols\r\nX: ".to_vec();
        too_large.resize(8192, b'x');
        for response in [
            b"HTTP/1.1 200 OK\r\n\r\nsecret".to_vec(),
            b"HTTP/1.0 101 Switching Protocols\r\n\r\nsecret".to_vec(),
            b"HTTP/1.1 101evil\r\n\r\nsecret".to_vec(),
            b"HTTP/1.1 10\r\n\r\nsecret".to_vec(),
            b"HTTP/1.1 101 Switching Protocols\r\ntruncated".to_vec(),
            too_large,
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let socket = TcpStream::connect(listener.local_addr().unwrap())
                .await
                .unwrap();
            let (mut peer, _) = listener.accept().await.unwrap();
            peer.write_all(&response).await.unwrap();
            peer.shutdown().await.unwrap();
            let mut stream = HttpObfsStream::new(socket, "cover.example", 80).unwrap();
            let mut buffer = [0; 32];
            assert!(
                stream.read(&mut buffer).await.is_err(),
                "invalid response must not leak its body"
            );
            assert!(
                stream.read(&mut buffer).await.is_err(),
                "an invalid response poisons the transport"
            );
            assert!(stream.write_all(b"more").await.is_err());
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn host_injection_is_rejected_and_port_80_omits_suffix() {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    for host in [
        "",
        "evil\r\nX: yes",
        "bad\0host",
        "bad\nhost",
        &"x".repeat(256),
    ] {
        let socket = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        assert!(HttpObfsStream::new(socket, host, 80).is_err());
        let (mut peer, _) = listener.accept().await.unwrap();
        assert_eq!(
            peer.read_u8().await.unwrap_err().kind(),
            std::io::ErrorKind::UnexpectedEof
        );
    }
    let socket = TcpStream::connect(listener.local_addr().unwrap())
        .await
        .unwrap();
    let (mut peer, _) = listener.accept().await.unwrap();
    let mut stream = HttpObfsStream::new(socket, "cover.example", 80).unwrap();
    stream.write_all(b"").await.unwrap();
    stream.flush().await.unwrap();
    assert!(
        timeout(Duration::from_millis(20), peer.read_u8())
            .await
            .is_err()
    );
    stream.write_all(b"body").await.unwrap();
    stream.shutdown().await.unwrap();
    let mut wire = Vec::new();
    peer.read_to_end(&mut wire).await.unwrap();
    let text = String::from_utf8(wire).unwrap();
    assert!(text.contains("\r\nHost: cover.example\r\n"));
    let key = text
        .split("Sec-WebSocket-Key: ")
        .nth(1)
        .unwrap()
        .split("\r\n")
        .next()
        .unwrap();
    use base64::Engine;
    assert_eq!(
        base64::engine::general_purpose::STANDARD
            .decode(key)
            .unwrap()
            .len(),
        16
    );
    assert!(text.ends_with("\r\n\r\nbody"));
}

#[tokio::test]
async fn stalled_upgrade_uses_absolute_response_deadline() {
    timeout(Duration::from_secs(12), async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let socket = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (mut peer, _) = listener.accept().await.unwrap();
        let mut stream = HttpObfsStream::new(socket, "cover.example", 80).unwrap();
        stream.write_all(b"body").await.unwrap();
        stream.flush().await.unwrap();
        peer.write_all(b"HTTP/1.1 101 ").await.unwrap();
        let mut buffer = [0; 1];
        // Cancelling a receive must not reset the deadline or discard the prefix.
        assert!(
            timeout(Duration::from_millis(20), stream.read(&mut buffer))
                .await
                .is_err()
        );
        let started = std::time::Instant::now();
        let error = stream.read(&mut buffer).await.unwrap_err();
        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
        assert!(started.elapsed() >= Duration::from_secs(9));
    })
    .await
    .unwrap();
}
