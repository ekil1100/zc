use std::{sync::Arc, time::Duration};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, server::TlsStream};
use zc::{config::Config, outbound::Connector, target::Target};

const WAIT: Duration = Duration::from_secs(8);
fn config(port: u16) -> Config {
    Config::parse(&format!("proxies: [{{name: edge, type: anytls, server: 127.0.0.1, port: {port}, password: password, sni: front.example, skip-cert-verify: true}}]\nrules: ['MATCH,edge']")).unwrap()
}
fn tls_config() -> Arc<rustls::ServerConfig> {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
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
    Arc::new(config)
}
// Independent literal wire fixture, never imports the production codec.
async fn frame(s: &mut TlsStream<TcpStream>) -> (u8, u32, Vec<u8>) {
    loop {
        let mut h = [0; 7];
        s.read_exact(&mut h).await.unwrap();
        let mut body = vec![0; u16::from_be_bytes([h[5], h[6]]) as usize];
        s.read_exact(&mut body).await.unwrap();
        if h[0] != 0 {
            return (h[0], u32::from_be_bytes(h[1..5].try_into().unwrap()), body);
        }
    }
}
async fn opened(listener: TcpListener) -> TlsStream<TcpStream> {
    opened_to(listener, b"\x03\x0bexample.com\x01\xbb").await
}
async fn opened_to(listener: TcpListener, address: &[u8]) -> TlsStream<TcpStream> {
    let padding = 30;
    let md5 = "75cff2ad89aadf5e257059ee571ebe11";
    let (s, _) = listener.accept().await.unwrap();
    rustix::net::sockopt::set_socket_recv_buffer_size(&s, 16 * 1024).unwrap();
    rustix::net::sockopt::set_socket_send_buffer_size(&s, 16 * 1024).unwrap();
    let mut s = TlsAcceptor::from(tls_config()).accept(s).await.unwrap();
    assert!(matches!(
        s.get_ref().1.server_name(),
        Some("front.example" | "localhost.localdomain")
    ));
    // SHA256("password"), computed independently with openssl.
    let digest = [
        0x5e, 0x88, 0x48, 0x98, 0xda, 0x28, 0x04, 0x71, 0x51, 0xd0, 0xe5, 0x6f, 0x8d, 0xc6, 0x29,
        0x27, 0x73, 0x60, 0x3d, 0x0d, 0x6a, 0xab, 0xbd, 0xd6, 0x2a, 0x11, 0xef, 0x72, 0x1d, 0x15,
        0x42, 0xd8,
    ];
    let mut auth = vec![0; 34 + padding];
    s.read_exact(&mut auth).await.unwrap();
    // tokio-rustls coalesces records; the independent Go fixture checks single-read authentication.
    assert_eq!(&auth[..32], &digest);
    assert_eq!(&auth[32..34], &(padding as u16).to_be_bytes());
    let (cmd, id, body) = frame(&mut s).await;
    assert_eq!((cmd, id), (4, 0));
    let settings = String::from_utf8(body).unwrap();
    assert!(settings.contains("v=2"));
    assert!(settings.contains("client=zc/"));
    assert!(settings.contains(&format!("padding-md5={md5}")));
    assert_eq!(frame(&mut s).await, (1, 1, vec![]));
    assert_eq!(frame(&mut s).await, (2, 1, address.to_vec()));
    s
}

// Public Connector + the same transfer adapter used by mixed CONNECT/SOCKS.
#[tokio::test]
async fn remote_fin_drains_received_data_before_rejecting_late_upload() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            s.write_all(b"\x02\0\0\0\x01\0\x05hello\x03\0\0\0\x01\0\0")
                .await
                .unwrap();
            s.flush().await.unwrap();
            let _ = s.read_to_end(&mut Vec::new()).await;
        });
        let connector = Connector::new(&config).unwrap();
        let upstream = connector
            .connect(
                &config.proxies()[2],
                &Target::new("example.com", 443).unwrap(),
            )
            .await
            .unwrap();
        let (mut app, ingress) = tokio::io::duplex(1);
        let consumed = Arc::new(std::sync::atomic::AtomicUsize::new(0));
        let ingress = CountReads {
            inner: ingress,
            bytes: consumed.clone(),
        };
        let relay = tokio::spawn(zc::runtime::transfer(ingress, upstream, Vec::new()));
        // TLS release proves FIN was consumed while four bytes remain buffered.
        peer.await.unwrap();
        app.write_all(b"x").await.unwrap();
        let mut response = Vec::new();
        app.read_to_end(&mut response).await.unwrap();
        assert_eq!(
            response, b"hello",
            "late upload must not discard received downstream data"
        );
        relay.await.unwrap().unwrap();
        assert_eq!(
            consumed.load(std::sync::atomic::Ordering::Relaxed),
            0,
            "FIN must stop ingress consumption, not silently sink uploads"
        );
        assert!(app.write_all(b"not accepted").await.is_err());
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn remote_fin_returns_without_waiting_for_ingress_write_eof() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            s.write_all(b"\x02\0\0\0\x01\0\x05hello\x03\0\0\0\x01\0\0")
                .await
                .unwrap();
            s.flush().await.unwrap();
            let _ = s.read_to_end(&mut Vec::new()).await;
        });
        let connector = Connector::new(&config).unwrap();
        let upstream = connector
            .connect(
                &config.proxies()[2],
                &Target::new("example.com", 443).unwrap(),
            )
            .await
            .unwrap();
        let local = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let mut app = TcpStream::connect(local.local_addr().unwrap())
            .await
            .unwrap();
        let (ingress, _) = local.accept().await.unwrap();
        let relay = tokio::spawn(zc::runtime::transfer(ingress, upstream, Vec::new()));
        let mut response = Vec::new();
        app.read_to_end(&mut response).await.unwrap();
        assert_eq!(response, b"hello");
        peer.await.unwrap();
        // Keep app's write half alive across the join. Timeout is only a watchdog.
        relay.await.unwrap().unwrap();
        drop(app);
    })
    .await
    .expect("FIN must finish transfer, not wait for the 15-minute idle timer");
}

#[tokio::test]
async fn heartbeat_does_not_block_real_bidirectional_backpressure() {
    for heartbeat_count in [0, 1, 32] {
        timeout(Duration::from_secs(12), async {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let config = config(listener.local_addr().unwrap().port());
            let (resume, resumed) = tokio::sync::oneshot::channel();
            let peer = tokio::spawn(async move {
                let mut s = opened(listener).await;
                let accepted = resumed.await.unwrap();
                s.write_all(b"\x0a\0\0\0\0\0\x03v=2").await.unwrap();
                for id in 42u32..42 + heartbeat_count {
                    s.write_all(&[8]).await.unwrap();
                    s.write_all(&id.to_be_bytes()).await.unwrap();
                    s.write_all(&[0,0]).await.unwrap();
                }
                let mut wire = vec![42; 65542];
                wire[..7].copy_from_slice(&[2,0,0,0,1,255,255]);
                // The peer cannot read upload until its entire download has drained.
                for _ in 0..256 { s.write_all(&wire).await.unwrap(); }
                s.flush().await.unwrap();
                let mut count = 0;
                let mut hearts = 0;
                while count < accepted + 256 * 65535 || hearts < heartbeat_count as usize {
                    let (cmd, id, body) = frame(&mut s).await;
                    if cmd == 9 { assert_eq!(id,42 + hearts as u32); assert!(body.is_empty()); hearts += 1; }
                    else { assert_eq!((cmd,id),(2,1)); assert!(body.iter().all(|b| *b == 7)); count += body.len(); }
                }
                assert_eq!(count, accepted + 256 * 65535);
                assert_eq!(hearts, heartbeat_count as usize);
                s.write_all(b"\x03\0\0\0\x01\0\0").await.unwrap();
                s.flush().await.unwrap();
            });
            let connector = Connector::new(&config).unwrap();
            let mut upstream = connector.connect(&config.proxies()[2], &Target::new("example.com",443).unwrap()).await.unwrap();
            let accepted = saturate_upload(&mut upstream).await;
            let local = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let mut app = TcpStream::connect(local.local_addr().unwrap()).await.unwrap();
            let (ingress, _) = local.accept().await.unwrap();
            resume.send(accepted).unwrap();
            let relay = tokio::spawn(zc::runtime::transfer(ingress, upstream, Vec::new()));
            let (mut r, mut w) = app.split();
            let upload = async { w.write_all(&vec![7;256*65535]).await.unwrap(); };
            let download = async {
                let mut response = Vec::new(); r.read_to_end(&mut response).await.unwrap();
                assert_eq!(response.len(), 256*65535);
                assert!(response.iter().all(|b| *b == 42));
            };
            tokio::join!(upload, download);
            peer.await.unwrap();
            // Application write EOF is deliberately absent, including under backpressure.
            relay.await.unwrap().unwrap();
            println!("PASS heartbeat_count={heartbeat_count}, prefilled={accepted}, upload=16776960, download=16776960");
        }).await.unwrap_or_else(|_| panic!("bidirectional progress stalled: heartbeat_count={heartbeat_count}"));
    }
}

#[tokio::test]
async fn local_shutdown_preserves_already_assembled_psh_body() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            let mut wire = vec![42;65542];
            wire[..7].copy_from_slice(&[2,0,0,0,1,255,255]);
            s.write_all(&wire).await.unwrap();
            s.flush().await.unwrap();
            assert_eq!(frame(&mut s).await, (3,1,vec![]));
            let mut tail = Vec::new();
            s.read_to_end(&mut tail).await.unwrap();
        });
        let connector = Connector::new(&config).unwrap();
        let mut s = connector.connect(&config.proxies()[2], &Target::new("example.com",443).unwrap()).await.unwrap();
        assert_eq!(s.read_u8().await.unwrap(),42);
        s.shutdown().await.unwrap();
        let mut rest = Vec::new();
        s.read_to_end(&mut rest).await.unwrap();
        assert_eq!(rest.len(),65534);
        assert!(rest.iter().all(|b| *b==42));
        peer.await.unwrap();
        println!("PASS: local shutdown sent FIN without waiting for reply and preserved all 65534 undelivered bytes of a complete PSH");
    }).await.unwrap();
}

async fn saturate_upload(upstream: &mut zc::outbound::BoxStream) -> usize {
    use std::{pin::Pin, task::Poll};
    use tokio::io::AsyncWrite;
    let block = vec![7; 65535];
    let mut accepted = 0;
    // Cancel only an actually Pending write; do not guess saturation with sleep.
    // Unconstrained prevents Tokio's cooperative yield masquerading as I/O Pending.
    tokio::task::unconstrained(std::future::poll_fn(|cx| {
        loop {
            match Pin::new(&mut *upstream).poll_write(cx, &block) {
                Poll::Ready(result) => {
                    accepted += result.unwrap();
                    assert!(accepted < 64 * 1024 * 1024);
                }
                Poll::Pending => return Poll::Ready(()),
            }
        }
    }))
    .await;
    assert!(accepted > 0);
    accepted
}

#[tokio::test]
async fn control_flood_under_write_backpressure_fails_instead_of_blocking_or_growing() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let (resume, resumed) = tokio::sync::oneshot::channel();
        let (release, released) = tokio::sync::oneshot::channel();
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            resumed.await.unwrap();
            let mut wire = b"\x0a\0\0\0\0\0\x03v=2".to_vec();
            for id in 0u32..65536 {
                wire.push(8);
                wire.extend_from_slice(&id.to_be_bytes());
                wire.extend_from_slice(&[0, 0]);
            }
            // The client may reject before the flood fits in the TCP window.
            let _ = s.write_all(&wire).await;
            let _ = s.flush().await;
            // Keep upload backpressured until the bounded-control rejection.
            released.await.unwrap();
            let _ = s.read_to_end(&mut Vec::new()).await;
        });
        let connector = Connector::new(&config).unwrap();
        let mut s = connector
            .connect(
                &config.proxies()[2],
                &Target::new("example.com", 443).unwrap(),
            )
            .await
            .unwrap();
        saturate_upload(&mut s).await;
        resume.send(()).unwrap();
        assert_eq!(
            s.read_u8().await.unwrap_err().kind(),
            std::io::ErrorKind::InvalidData
        );
        assert!(s.write_all(b"late").await.is_err());
        release.send(()).unwrap();
        peer.await.unwrap();
    })
    .await
    .unwrap();
}

async fn http_head(s: &mut (impl tokio::io::AsyncRead + Unpin)) -> Vec<u8> {
    let mut head = Vec::new();
    while !head.ends_with(b"\r\n\r\n") {
        head.push(s.read_u8().await.unwrap());
        assert!(head.len() < 16384);
    }
    head
}

#[tokio::test]
async fn mixed_connect_and_socks_deliver_fin_without_client_half_close() {
    timeout(WAIT, async {
        for socks in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let runtime =
                zc::runtime::Runtime::bind(config(listener.local_addr().unwrap().port()), 0)
                    .await
                    .unwrap();
            let address = runtime.local_addr().unwrap();
            let (stop, stopped) = tokio::sync::oneshot::channel();
            let runtime = tokio::spawn(runtime.run(async {
                let _ = stopped.await;
            }));
            let peer = tokio::spawn(async move {
                let mut s = opened(listener).await;
                assert_eq!(frame(&mut s).await, (2, 1, b"first".to_vec()));
                s.write_all(b"\x02\0\0\0\x01\0\x05hello\x03\0\0\0\x01\0\0")
                    .await
                    .unwrap();
                s.flush().await.unwrap();
                let _ = s.read_to_end(&mut Vec::new()).await;
            });
            let mut app = TcpStream::connect(address).await.unwrap();
            if socks {
                app.write_all(b"\x05\x01\0").await.unwrap();
                let mut greeting = [0; 2];
                app.read_exact(&mut greeting).await.unwrap();
                assert_eq!(greeting, [5, 0]);
                app.write_all(b"\x05\x01\0\x03\x0bexample.com\x01\xbbfirst")
                    .await
                    .unwrap();
                let mut reply = [0; 10];
                app.read_exact(&mut reply).await.unwrap();
                assert_eq!(reply, [5, 0, 0, 1, 0, 0, 0, 0, 0, 0]);
            } else {
                app.write_all(
                    b"CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\nfirst",
                )
                .await
                .unwrap();
                assert_eq!(
                    http_head(&mut app).await,
                    b"HTTP/1.1 200 Connection Established\r\n\r\n"
                );
            }
            let mut data = Vec::new();
            app.read_to_end(&mut data).await.unwrap();
            assert_eq!(data, b"hello");
            peer.await.unwrap();
            stop.send(()).unwrap();
            runtime.await.unwrap().unwrap();
        }
    })
    .await
    .unwrap();
}

async fn send_psh(s: &mut TlsStream<TcpStream>, data: &[u8]) {
    for chunk in data.chunks(65535) {
        s.write_all(&[2, 0, 0, 0, 1]).await.unwrap();
        s.write_all(&(chunk.len() as u16).to_be_bytes())
            .await
            .unwrap();
        s.write_all(chunk).await.unwrap();
    }
    s.flush().await.unwrap();
}

// Independent nested TLS endpoint: only literal AnyTLS frames, no production codec.
async fn send_tls(s: &mut TlsStream<TcpStream>, tls: &mut rustls::ServerConnection) {
    let mut records = Vec::new();
    while tls.wants_write() {
        tls.write_tls(&mut records).unwrap();
    }
    send_psh(s, &records).await;
}

#[tokio::test]
async fn mixed_http_and_https_forward_drain_early_response_with_upload_still_open() {
    if std::env::var_os("ZC_ANYTLS_HTTPS_CHILD").is_none() {
        let home = tempfile::tempdir().unwrap();
        let cert = home.path().join("ca.pem");
        std::fs::write(&cert, include_bytes!("../testdata/e2e/trojan-cert.pem")).unwrap();
        let result = timeout(
            Duration::from_secs(20),
            tokio::process::Command::new(std::env::current_exe().unwrap())
                .args([
                    "--exact",
                    "mixed_http_and_https_forward_drain_early_response_with_upload_still_open",
                    "--nocapture",
                ])
                .env("ZC_ANYTLS_HTTPS_CHILD", "1")
                .env("SSL_CERT_FILE", cert)
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
            result.status.success(),
            "{}\n{}",
            String::from_utf8_lossy(&result.stdout),
            String::from_utf8_lossy(&result.stderr)
        );
        return;
    }
    timeout(Duration::from_secs(15), async {
        for secure in [false, true] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let runtime = zc::runtime::Runtime::bind(config(listener.local_addr().unwrap().port()),0).await.unwrap();
            let address = runtime.local_addr().unwrap();
            let (stop, stopped) = tokio::sync::oneshot::channel();
            let runtime = tokio::spawn(runtime.run(async { let _ = stopped.await; }));
            let peer = tokio::spawn(async move {
                use std::io::{Read, Write};
                let mut s = opened_to(listener, b"\x03\x15localhost.localdomain\x01\xbb").await;
                let mut tls = secure.then(|| rustls::ServerConnection::new(tls_config()).unwrap());
                let mut request = Vec::new();
                while !request.ends_with(b"\r\n\r\n") {
                    let (cmd,id,body) = frame(&mut s).await;
                    assert_eq!((cmd,id),(2,1));
                    if let Some(tls) = &mut tls {
                        let mut input = body.as_slice();
                        while !input.is_empty() { tls.read_tls(&mut input).unwrap(); }
                        tls.process_new_packets().unwrap();
                        let mut plain = [0;16384];
                        loop {
                            match tls.reader().read(&mut plain) {
                                Ok(0) => break,
                                Ok(n) => request.extend_from_slice(&plain[..n]),
                                Err(e) if e.kind() == std::io::ErrorKind::WouldBlock => break,
                                Err(e) => panic!("{e}"),
                            }
                        }
                        send_tls(&mut s,tls).await;
                    } else { request.extend_from_slice(&body); }
                }
                assert!(request.starts_with(b"POST /early HTTP/1.1\r\n"));
                assert!(String::from_utf8(request).unwrap().contains("Content-Length: 16777216\r\n"));
                // EOF-framed response ensures the read path must consume FIN.
                let mut response = b"HTTP/1.1 413 Content Too Large\r\nConnection: close\r\n\r\n".to_vec();
                response.extend(vec![42;2*1024*1024]);
                for chunk in response.chunks(16384) {
                    if let Some(tls) = &mut tls {
                        tls.writer().write_all(chunk).unwrap();
                        send_tls(&mut s,tls).await;
                    } else { send_psh(&mut s,chunk).await; }
                }
                if let Some(tls) = &mut tls { tls.send_close_notify(); send_tls(&mut s,tls).await; }
                s.write_all(b"\x03\0\0\0\x01\0\0").await.unwrap(); s.flush().await.unwrap();
                let _ = s.read_to_end(&mut Vec::new()).await;
            });
            let mut app = TcpStream::connect(address).await.unwrap();
            rustix::net::sockopt::set_socket_recv_buffer_size(&app,16*1024).unwrap();
            let scheme = if secure { "https" } else { "http" };
            app.write_all(format!("POST {scheme}://localhost.localdomain:443/early HTTP/1.1\r\nHost: localhost.localdomain:443\r\nContent-Length: 16777216\r\n\r\n").as_bytes()).await.unwrap();
            assert_eq!(http_head(&mut app).await,b"HTTP/1.1 413 Content Too Large\r\nConnection: close\r\n\r\n");
            let mut data = Vec::new(); app.read_to_end(&mut data).await.unwrap();
            assert_eq!(data.len(),2*1024*1024); assert!(data.iter().all(|b| *b == 42));
            peer.await.unwrap();
            stop.send(()).unwrap(); runtime.await.unwrap().unwrap();
        }
    }).await.unwrap();
}

// Count real ingress consumption, not write acknowledgements from the application.
struct CountReads<S> {
    inner: S,
    bytes: Arc<std::sync::atomic::AtomicUsize>,
}
impl<S: tokio::io::AsyncRead + Unpin> tokio::io::AsyncRead for CountReads<S> {
    fn poll_read(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        let before = buf.filled().len();
        let result = std::pin::Pin::new(&mut self.inner).poll_read(cx, buf);
        self.bytes.fetch_add(
            buf.filled().len() - before,
            std::sync::atomic::Ordering::Relaxed,
        );
        result
    }
}
impl<S: tokio::io::AsyncWrite + Unpin> tokio::io::AsyncWrite for CountReads<S> {
    fn poll_write(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::pin::Pin::new(&mut self.inner).poll_write(cx, buf)
    }
    fn poll_flush(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(
        mut self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

#[tokio::test]
async fn cancelling_transfer_drops_owned_tls_without_a_worker() {
    use std::{future::Future, task::Poll};
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            let _ = s.read_to_end(&mut Vec::new()).await;
        });
        let connector = Connector::new(&config).unwrap();
        let upstream = connector
            .connect(
                &config.proxies()[2],
                &Target::new("example.com", 443).unwrap(),
            )
            .await
            .unwrap();
        let (app, ingress) = tokio::io::duplex(1);
        let mut relay = Box::pin(zc::runtime::transfer(ingress, upstream, Vec::new()));
        std::future::poll_fn(|cx| {
            assert!(relay.as_mut().poll(cx).is_pending());
            Poll::Ready(())
        })
        .await;
        drop(relay);
        peer.await.unwrap();
        drop(app);
    })
    .await
    .unwrap();
}
