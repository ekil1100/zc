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
fn acceptor() -> TlsAcceptor {
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
    TlsAcceptor::from(Arc::new(config))
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
    opened_with(&listener, 30, "75cff2ad89aadf5e257059ee571ebe11").await
}
async fn opened_with(listener: &TcpListener, padding: usize, md5: &str) -> TlsStream<TcpStream> {
    let (s, _) = listener.accept().await.unwrap();
    let mut s = acceptor().accept(s).await.unwrap();
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
    assert_eq!(
        frame(&mut s).await,
        (2, 1, b"\x03\x0bexample.com\x01\xbb".to_vec())
    );
    s
}

#[tokio::test]
async fn anytls_server_first_fragmented_control_and_fin_close_the_entire_stream() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            // v2 settings, success ACK, empty PSH, Waste, heartbeat (nonzero id), data, FIN.
            let wire = b"\x0a\0\0\0\0\0\x03v=2\x07\0\0\0\x01\0\0\x02\0\0\0\x01\0\0\x00\0\0\0\0\0\x02xx\x08\0\0\0\x2a\0\0\x02\0\0\0\x01\0\x05hello";
            for byte in wire { s.write_all(&[*byte]).await.unwrap(); s.flush().await.unwrap(); }
            assert_eq!(frame(&mut s).await, (9,42,vec![]));
            s.write_all(b"\x03\0\0\0\x01\0\0").await.unwrap(); s.flush().await.unwrap();
            // No FIN reply is needed or sent. The single-session client releases TLS.
            let mut tail = Vec::new(); let _ = s.read_to_end(&mut tail).await;
            let mut rest = tail.as_slice();
            while !rest.is_empty() { assert!(rest.len() >= 7); assert_eq!(rest[0], 0); let n = u16::from_be_bytes([rest[5],rest[6]]) as usize; rest = &rest[7+n..]; }
        });
        let connector = Connector::new(&config).unwrap();
        let mut s = connector.connect(&config.proxies()[2], &Target::new("example.com",443).unwrap()).await.unwrap();
        let mut data = Vec::new(); s.read_to_end(&mut data).await.unwrap(); assert_eq!(data,b"hello");
        assert!(s.write_all(b"late").await.is_err()); s.shutdown().await.unwrap(); peer.await.unwrap();
    }).await.unwrap();
}

#[tokio::test]
async fn anytls_v1_large_payload_and_local_fin_do_not_wait_for_a_reply() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let payload: Vec<u8> = (0..300_000).map(|i| (i % 251) as u8).collect();
        let expected = payload.clone();
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            let mut received = Vec::new();
            loop {
                let (cmd, id, body) = frame(&mut s).await;
                assert_eq!(id, 1);
                if cmd == 3 {
                    assert!(body.is_empty());
                    break;
                }
                assert_eq!(cmd, 2);
                assert!(!body.is_empty());
                received.extend_from_slice(&body);
                // Independent encoder: mirror payload under a literal PSH header.
                s.write_all(&[2, 0, 0, 0, 1]).await.unwrap();
                s.write_all(&(body.len() as u16).to_be_bytes())
                    .await
                    .unwrap();
                s.write_all(&body).await.unwrap();
                s.flush().await.unwrap();
            }
            assert_eq!(received, expected);
            // Official v0.0.13 does not answer FIN. Client must still finish promptly.
            let mut tail = Vec::new();
            let _ = s.read_to_end(&mut tail).await;
        });
        let connector = Connector::new(&config).unwrap();
        let mut s = connector
            .connect(
                &config.proxies()[2],
                &Target::new("example.com", 443).unwrap(),
            )
            .await
            .unwrap();
        let (mut r, mut w) = tokio::io::split(&mut s);
        let mut echo = vec![0; payload.len()];
        let (write, read) = tokio::join!(
            async {
                w.write_all(&payload).await?;
                w.flush().await
            },
            r.read_exact(&mut echo)
        );
        write.unwrap();
        read.unwrap();
        assert_eq!(echo, payload);
        s.shutdown().await.unwrap();
        assert_eq!(s.read(&mut [0; 1]).await.unwrap(), 0);
        assert!(s.write_all(b"late").await.is_err());
        peer.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn anytls_rejects_truncation_malformed_controls_and_remote_errors_without_disclosure() {
    timeout(Duration::from_secs(15), async {
        let mut cases = vec![
            vec![],
            b"\x02\0\0\0\x01\0\x04abcd".to_vec(),
            b"\x05\0\0\0\0\0\x0eprivate-secret".to_vec(),
            b"\x0a\0\0\0\0\0\x03v=2\x07\0\0\0\x01\0\x0eprivate-target".to_vec(),
            b"\xff\0\0\0\0\0\0".to_vec(),
            b"\x02\0\0\0\x02\0\0".to_vec(),
            b"\x03\0\0\0\x01\0\x01x".to_vec(),
            b"\x08\0\0\0\x01\0\0".to_vec(),
            b"\x01\0\0\0\x01\0\0".to_vec(),
            b"\x04\0\0\0\0\0\0".to_vec(),
            b"\x0a\0\0\0\0\0\x07v=2\nv=2".to_vec(),
            b"\x0a\0\0\0\0\0\x03v=0".to_vec(),
            b"\x0a\0\0\0\0\0\x03v=\xff".to_vec(),
            b"\x06\0\0\0\0\x10\x01".to_vec(),
        ];
        let complete = b"\x02\0\0\0\x01\0\x04abcd";
        for cut in 1..complete.len() {
            cases.push(complete[..cut].to_vec());
        }
        for wire in cases {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let config = config(listener.local_addr().unwrap().port());
            let peer = tokio::spawn(async move {
                let mut s = opened(listener).await;
                s.write_all(&wire).await.unwrap();
                s.shutdown().await.unwrap();
            });
            let connector = Connector::new(&config).unwrap();
            let mut s = connector
                .connect(
                    &config.proxies()[2],
                    &Target::new("example.com", 443).unwrap(),
                )
                .await
                .unwrap();
            let error = s.read_to_end(&mut Vec::new()).await.unwrap_err();
            let text = format!("{error:?}");
            for secret in [
                "private-secret",
                "private-target",
                "password",
                "example.com",
            ] {
                assert!(!text.contains(secret));
            }
            assert!(s.write_all(b"late").await.is_err());
            peer.await.unwrap();
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn anytls_verified_tls_accepts_trust_and_rejects_wrong_identity_or_untrusted_ca() {
    use rustls::pki_types::{CertificateDer, pem::PemObject};
    timeout(WAIT, async {
        for (sni, trusted) in [("localhost.localdomain",true),("wrong.example",true),("localhost.localdomain",false)] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let config = Config::parse(&format!("proxies: [{{name: edge, type: anytls, server: 127.0.0.1, port: {}, password: password, sni: {sni}}}]\nrules: ['MATCH,edge']",listener.local_addr().unwrap().port())).unwrap();
            let success = trusted && sni == "localhost.localdomain";
            let peer = tokio::spawn(async move {
                if success { let mut s = opened(listener).await; s.write_all(b"\x03\0\0\0\x01\0\0").await.unwrap(); s.flush().await.unwrap(); }
                else { let (s,_) = listener.accept().await.unwrap(); assert!(acceptor().accept(s).await.is_err()); }
            });
            let connector = if trusted {
                let mut roots = rustls::RootCertStore::empty(); roots.add(CertificateDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-cert.pem")).unwrap()).unwrap();
                Connector::with_tls_roots(&config,roots).unwrap()
            } else { Connector::new(&config).unwrap() };
            let result = connector.connect(&config.proxies()[2], &Target::new("example.com",443).unwrap()).await;
            if success { assert_eq!(result.unwrap().read(&mut [0;1]).await.unwrap(),0); }
            else { let text = format!("{:#}", result.err().unwrap()); assert!(text.contains("TLS handshake")); assert!(!text.contains("password")); }
            peer.await.unwrap();
        }
    }).await.unwrap();
}

#[tokio::test]
async fn anytls_padding_update_uses_raw_md5_next_session_and_never_crosses_nodes() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let config = Config::parse(&format!("proxies: [{{name: a, type: anytls, server: localhost, port: {port}, password: password, sni: front.example, skip-cert-verify: true}}, {{name: b, type: anytls, server: localhost, port: {port}, password: password, sni: front.example, skip-cert-verify: true}}]\nrules: ['MATCH,a']")).unwrap();
        let peer = tokio::spawn(async move {
            let mut a = opened_with(&listener,30,"75cff2ad89aadf5e257059ee571ebe11").await;
            let update = b"stop=3\n0=9-9\n1=200-200\n2=20-20,40-40\n";
            a.write_all(&[6,0,0,0,0,0,update.len() as u8]).await.unwrap();
            a.write_all(update).await.unwrap();
            a.write_all(b"\x02\0\0\0\x01\0\x01!").await.unwrap(); a.flush().await.unwrap();
            let mut b = opened_with(&listener,30,"75cff2ad89aadf5e257059ee571ebe11").await;
            b.write_all(b"\x03\0\0\0\x01\0\0").await.unwrap(); b.flush().await.unwrap();
            let mut next = opened_with(&listener,9,"8d29f7a84b60406b4144b7461f63b0fb").await;
            assert_eq!(frame(&mut a).await, (2,1,b"hey".to_vec()));
            // The old session retains the default group's 400..500 plaintext size.
            let mut h=[0;7]; a.read_exact(&mut h).await.unwrap(); assert_eq!(h[0],0);
            let len=u16::from_be_bytes([h[5],h[6]]) as usize; assert!((383..483).contains(&len));
            let mut body=vec![0;len]; a.read_exact(&mut body).await.unwrap();
            assert_eq!(frame(&mut next).await,(2,1,b"hey".to_vec()));
            // PSH(10) + Waste(10) -> 20, then pure Waste BODY(40) -> 47.
            for expected in [3,40] {
                let mut h=[0;7]; next.read_exact(&mut h).await.unwrap(); assert_eq!(&h[..5], &[0;5]);
                assert_eq!(u16::from_be_bytes([h[5],h[6]]),expected);
                next.read_exact(&mut vec![0;expected as usize]).await.unwrap();
            }
            for s in [&mut a,&mut next] { s.write_all(b"\x03\0\0\0\x01\0\0").await.unwrap(); s.flush().await.unwrap(); }
        });
        let connector = Connector::new(&config).unwrap(); let target=Target::new("example.com",443).unwrap();
        let mut a=connector.connect(&config.proxies()[2],&target).await.unwrap();
        assert_eq!(a.read_u8().await.unwrap(),b'!');
        let mut b=connector.connect(&config.proxies()[3],&target).await.unwrap();
        let mut next=connector.connect(&config.proxies()[2],&target).await.unwrap();
        a.write_all(b"hey").await.unwrap(); a.flush().await.unwrap();
        next.write_all(b"hey").await.unwrap(); next.flush().await.unwrap();
        for s in [&mut a,&mut b,&mut next] { assert_eq!(s.read(&mut [0;1]).await.unwrap(),0); }
        peer.await.unwrap();
    }).await.unwrap();
}

#[tokio::test]
async fn anytls_invalid_padding_is_fatal_and_cannot_poison_the_next_session() {
    timeout(WAIT, async {
        for update in [
            "stop=0",
            "stop=33",
            "stop=2\n0=4063-4063",
            "stop=2\n1=9-2",
            "stop=2\n1=0-1",
            "stop=2\n1=16385-16385",
            "stop=2\n0=c",
            "stop=2\n1=2-2\n1=3-3",
            "stop=99999999999999999999999999999999999",
            "stop=2\n1=16384-16384,16384-16384,16384-16384,16384-16384",
        ] {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let config = config(listener.local_addr().unwrap().port());
            let peer = tokio::spawn(async move {
                let mut s = opened_with(&listener, 30, "75cff2ad89aadf5e257059ee571ebe11").await;
                s.write_all(&[6, 0, 0, 0, 0, 0, update.len() as u8])
                    .await
                    .unwrap();
                s.write_all(update.as_bytes()).await.unwrap();
                s.flush().await.unwrap();
                let mut s = opened_with(&listener, 30, "75cff2ad89aadf5e257059ee571ebe11").await;
                s.write_all(b"\x03\0\0\0\x01\0\0").await.unwrap();
                s.flush().await.unwrap();
            });
            let connector = Connector::new(&config).unwrap();
            let target = Target::new("example.com", 443).unwrap();
            let mut s = connector
                .connect(&config.proxies()[2], &target)
                .await
                .unwrap();
            assert!(s.read_u8().await.is_err(), "accepted {update}");
            let mut s = connector
                .connect(&config.proxies()[2], &target)
                .await
                .unwrap();
            assert_eq!(s.read(&mut [0; 1]).await.unwrap(), 0);
            peer.await.unwrap();
        }
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn anytls_slow_peer_backpressures_writes_and_cancel_drop_releases_tls() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let (ready, wait) = tokio::sync::oneshot::channel();
        let (resume, resumed) = tokio::sync::oneshot::channel();
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            ready.send(()).unwrap();
            resumed.await.unwrap();
            let mut drained = 0;
            let mut bytes = [0; 8192];
            loop {
                match s.read(&mut bytes).await {
                    Ok(0) | Err(_) => break,
                    Ok(n) => drained += n,
                }
            }
            drained
        });
        let connector = Connector::new(&config).unwrap();
        let target = Target::new("example.com", 443).unwrap();
        let mut s = connector
            .connect(&config.proxies()[2], &target)
            .await
            .unwrap();
        wait.await.unwrap();
        let block = vec![42; 65535];
        let mut accepted = 0;
        assert!(
            timeout(Duration::from_millis(150), async {
                for _ in 0..1024 {
                    s.write_all(&block).await.unwrap();
                    accepted += block.len();
                }
                s.flush().await.unwrap();
            })
            .await
            .is_err(),
            "slow peer must not accept an unbounded queue"
        );
        assert!(accepted < 64 * 1024 * 1024);
        drop(s);
        resume.send(()).unwrap();
        assert!(peer.await.unwrap() < 64 * 1024 * 1024);
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn anytls_concurrent_sessions_have_independent_ids_data_and_cancellation() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let peer = tokio::spawn(async move {
            let mut tasks = tokio::task::JoinSet::new();
            for _ in 0..8 {
                let mut s = opened_with(&listener, 30, "75cff2ad89aadf5e257059ee571ebe11").await;
                tasks.spawn(async move {
                    let (cmd, id, body) = frame(&mut s).await;
                    assert_eq!((cmd, id), (2, 1));
                    assert_eq!(body.len(), 1);
                    if body[0] == 0 {
                        let _ = s.read_to_end(&mut Vec::new()).await;
                    } else {
                        s.write_all(&[2, 0, 0, 0, 1, 0, 1, body[0], 3, 0, 0, 0, 1, 0, 0])
                            .await
                            .unwrap();
                        s.flush().await.unwrap();
                    }
                });
            }
            while let Some(task) = tasks.join_next().await {
                task.unwrap();
            }
        });
        let connector = Arc::new(Connector::new(&config).unwrap());
        let config = Arc::new(config);
        let mut tasks = tokio::task::JoinSet::new();
        for id in 0..8u8 {
            let connector = connector.clone();
            let config = config.clone();
            tasks.spawn(async move {
                let mut s = connector
                    .connect(
                        &config.proxies()[2],
                        &Target::new("example.com", 443).unwrap(),
                    )
                    .await
                    .unwrap();
                s.write_all(&[id]).await.unwrap();
                s.flush().await.unwrap();
                if id != 0 {
                    let mut response = Vec::new();
                    s.read_to_end(&mut response).await.unwrap();
                    assert_eq!(response, [id]);
                }
            });
        }
        while let Some(task) = tasks.join_next().await {
            task.unwrap();
        }
        peer.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn anytls_mixed_udp_rejects_without_allocating_or_falling_back() {
    use zc::runtime::Runtime;
    timeout(WAIT, async {
        for mixed in [false,true] {
            let listener=TcpListener::bind("127.0.0.1:0").await.unwrap();
            let other = if mixed {", {name: udp, type: ss, server: localhost, port: 23456, password: password, cipher: aes-128-gcm, udp: true}"} else {""};
            let config=Config::parse(&format!("proxies: [{{name: edge, type: anytls, server: localhost, port: {}, password: password, skip-cert-verify: true}}{other}]\nrules: ['MATCH,edge']",listener.local_addr().unwrap().port())).unwrap();
            let connector=Connector::new(&config).unwrap();
            assert!(connector.open_udp(&config.proxies()[2],&Target::new("example.com",443).unwrap()).await.is_err());
            let runtime=Runtime::bind(config,0).await.unwrap(); let addr=runtime.local_addr().unwrap();
            let (stop,stopped)=tokio::sync::oneshot::channel(); let task=tokio::spawn(runtime.run(async {let _=stopped.await;}));
            let mut control=TcpStream::connect(addr).await.unwrap();
            control.write_all(b"\x05\x01\0").await.unwrap(); let mut greeting=[0;2]; control.read_exact(&mut greeting).await.unwrap(); assert_eq!(greeting,[5,0]);
            control.write_all(b"\x05\x03\0\x01\0\0\0\0\0\0").await.unwrap(); let mut reply=[0;10]; control.read_exact(&mut reply).await.unwrap();
            if mixed {
                assert_eq!(reply[1],0);
                let socket=tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap();
                let target=tokio::net::UdpSocket::bind("127.0.0.1:0").await.unwrap(); let port=target.local_addr().unwrap().port().to_be_bytes();
                socket.send_to(&[0,0,0,1,127,0,0,1,port[0],port[1],42],(std::net::Ipv4Addr::new(reply[4],reply[5],reply[6],reply[7]),u16::from_be_bytes([reply[8],reply[9]]))).await.unwrap();
                assert_eq!(control.read(&mut [0;1]).await.unwrap(),0);
                assert!(timeout(Duration::from_millis(30),target.recv(&mut [0;1])).await.is_err());
            } else {assert_eq!(reply[1],7);}
            assert!(timeout(Duration::from_millis(30),listener.accept()).await.is_err());
            stop.send(()).unwrap(); task.await.unwrap().unwrap();
        }
    }).await.unwrap();
}

#[tokio::test]
async fn anytls_pending_write_cancel_resume_never_replays_or_loses_accepted_bytes() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let (resume, resumed) = tokio::sync::oneshot::channel();
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            resumed.await.unwrap();
            let mut count = 0usize;
            loop {
                let (cmd, id, body) = frame(&mut s).await;
                assert_eq!(id, 1);
                if cmd == 3 {
                    break;
                }
                assert_eq!(cmd, 2);
                assert_eq!(body.len(), 65535);
                assert!(body.iter().all(|b| *b == (count % 251) as u8));
                count += 1;
            }
            count
        });
        let connector = Connector::new(&config).unwrap();
        let target = Target::new("example.com", 443).unwrap();
        let mut s = connector
            .connect(&config.proxies()[2], &target)
            .await
            .unwrap();
        let mut count = 0usize;
        loop {
            let block = vec![(count % 251) as u8; 65535];
            match timeout(Duration::from_millis(50), s.write(&block)).await {
                Ok(result) => {
                    assert_eq!(result.unwrap(), block.len());
                    count += 1;
                    assert!(count < 1024);
                }
                Err(_) => break,
            }
        }
        resume.send(()).unwrap();
        for _ in 0..8 {
            let block = vec![(count % 251) as u8; 65535];
            assert_eq!(s.write(&block).await.unwrap(), block.len());
            count += 1;
        }
        s.shutdown().await.unwrap();
        assert_eq!(peer.await.unwrap(), count);
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn anytls_slow_application_reader_and_drop_backpressure_the_tls_peer() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let (blocked, wait) = tokio::sync::oneshot::channel();
        let (dropped, after_drop) = tokio::sync::oneshot::channel();
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            let mut wire = vec![42; 65542];
            wire[..7].copy_from_slice(&[2, 0, 0, 0, 1, 255, 255]);
            assert!(
                timeout(Duration::from_millis(150), async {
                    for _ in 0..1024 {
                        s.write_all(&wire).await.unwrap();
                    }
                    s.flush().await.unwrap();
                })
                .await
                .is_err()
            );
            blocked.send(()).unwrap();
            after_drop.await.unwrap();
            assert!(s.write_all(&wire).await.is_err() || s.flush().await.is_err());
        });
        let connector = Connector::new(&config).unwrap();
        let target = Target::new("example.com", 443).unwrap();
        let mut s = connector
            .connect(&config.proxies()[2], &target)
            .await
            .unwrap();
        assert_eq!(s.read_u8().await.unwrap(), 42);
        wait.await.unwrap();
        drop(s);
        dropped.send(()).unwrap();
        peer.await.unwrap();
    })
    .await
    .unwrap();
}

#[tokio::test]
async fn anytls_heartbeat_and_data_share_frames_but_not_lost_wakeups_between_tasks() {
    timeout(WAIT, async {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let config = config(listener.local_addr().unwrap().port());
        let total = 2 * 1024 * 1024;
        let peer = tokio::spawn(async move {
            let mut s = opened(listener).await;
            s.write_all(b"\x0a\0\0\0\0\0\x03v=2\x08\0\0\0\x2a\0\0")
                .await
                .unwrap();
            s.flush().await.unwrap();
            tokio::time::sleep(Duration::from_millis(60)).await;
            let mut count = 0;
            let mut hearts = 0;
            while count < total || hearts == 0 {
                let (cmd, id, body) = frame(&mut s).await;
                if cmd == 9 {
                    assert_eq!(id, 42);
                    assert!(body.is_empty());
                    hearts += 1;
                    assert_eq!(hearts, 1);
                } else {
                    assert_eq!((cmd, id), (2, 1));
                    assert!(body.iter().all(|b| *b == 42));
                    count += body.len();
                }
            }
            assert_eq!(count, total);
            s.write_all(b"\x02\0\0\0\x01\0\x01!\x03\0\0\0\x01\0\0")
                .await
                .unwrap();
            s.flush().await.unwrap();
        });
        let connector = Connector::new(&config).unwrap();
        let s = connector
            .connect(
                &config.proxies()[2],
                &Target::new("example.com", 443).unwrap(),
            )
            .await
            .unwrap();
        let (mut r, mut w) = tokio::io::split(s);
        let reader = tokio::spawn(async move {
            let mut data = Vec::new();
            r.read_to_end(&mut data).await.unwrap();
            assert_eq!(data, b"!");
        });
        let writer = tokio::spawn(async move {
            w.write_all(&vec![42; total]).await.unwrap();
            w.flush().await.unwrap();
        });
        reader.await.unwrap();
        writer.await.unwrap();
        peer.await.unwrap();
    })
    .await
    .unwrap();
}
