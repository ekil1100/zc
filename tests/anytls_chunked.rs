use std::{sync::Arc, time::Duration};

use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::{TcpListener, TcpStream},
    sync::oneshot,
    time::timeout,
};
use tokio_rustls::{TlsAcceptor, server::TlsStream};
use zc::{config::Config, runtime::Runtime};

const WAIT: Duration = Duration::from_secs(5);
const CHUNK: &[u8] = b"1\r\nx\r\n";
const RESPONSE: &[u8] =
    b"HTTP/1.1 413 Content Too Large\r\nContent-Length: 0\r\nConnection: close\r\n\r\n";

fn tls_config() -> Arc<rustls::ServerConfig> {
    use rustls::pki_types::{CertificateDer, PrivateKeyDer, pem::PemObject};
    let cert =
        CertificateDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-cert.pem")).unwrap();
    let key =
        PrivateKeyDer::from_pem_slice(include_bytes!("../testdata/e2e/trojan-key.pem")).unwrap();
    Arc::new(
        rustls::ServerConfig::builder_with_provider(Arc::new(
            rustls::crypto::aws_lc_rs::default_provider(),
        ))
        .with_safe_default_protocol_versions()
        .unwrap()
        .with_no_client_auth()
        .with_single_cert(vec![cert], key)
        .unwrap(),
    )
}

// Independent wire fixture: do not import the production AnyTLS codec.
async fn frame(stream: &mut TlsStream<TcpStream>) -> (u8, u32, Vec<u8>) {
    loop {
        let mut header = [0; 7];
        stream.read_exact(&mut header).await.unwrap();
        let mut body = vec![0; u16::from_be_bytes([header[5], header[6]]) as usize];
        stream.read_exact(&mut body).await.unwrap();
        if header[0] != 0 {
            return (
                header[0],
                u32::from_be_bytes(header[1..5].try_into().unwrap()),
                body,
            );
        }
    }
}

async fn open_anytls(socket: TcpStream) -> TlsStream<TcpStream> {
    let mut stream = TlsAcceptor::from(tls_config())
        .accept(socket)
        .await
        .unwrap();
    let mut auth = [0; 34];
    stream.read_exact(&mut auth).await.unwrap();
    // SHA256("password"), independently computed with openssl.
    assert_eq!(
        &auth[..32],
        &[
            0x5e, 0x88, 0x48, 0x98, 0xda, 0x28, 0x04, 0x71, 0x51, 0xd0, 0xe5, 0x6f, 0x8d, 0xc6,
            0x29, 0x27, 0x73, 0x60, 0x3d, 0x0d, 0x6a, 0xab, 0xbd, 0xd6, 0x2a, 0x11, 0xef, 0x72,
            0x1d, 0x15, 0x42, 0xd8,
        ]
    );
    let mut padding = vec![0; u16::from_be_bytes([auth[32], auth[33]]) as usize];
    stream.read_exact(&mut padding).await.unwrap();
    let (cmd, id, _) = frame(&mut stream).await;
    assert_eq!((cmd, id), (4, 0));
    assert_eq!(frame(&mut stream).await, (1, 1, vec![]));
    assert_eq!(
        frame(&mut stream).await,
        (2, 1, b"\x03\x0bexample.com\0\x50".to_vec())
    );
    stream
}

// Returns true only after the complete nonterminal chunk, including its CRLF.
fn complete_chunk(request: &[u8]) -> bool {
    assert!(request.len() <= 16384);
    let Some(end) = request.windows(4).position(|bytes| bytes == b"\r\n\r\n") else {
        return false;
    };
    assert!(request.starts_with(b"POST /stream HTTP/1.1\r\n"));
    let body = &request[end + 4..];
    assert!(CHUNK.starts_with(body), "unexpected chunk bytes: {body:?}");
    body == CHUNK
}

async fn early_response_after_chunk(anytls: bool) {
    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let port = listener.local_addr().unwrap().port();
    assert_ne!(port, 7899);
    let config = if anytls {
        Config::parse(&format!(
            "proxies: [{{name: edge, type: anytls, server: 127.0.0.1, port: {port}, password: password, sni: front.example, skip-cert-verify: true}}]\nrules: ['MATCH,edge']"
        ))
    } else {
        Config::parse("rules: ['MATCH,DIRECT']")
    }
    .unwrap();
    let runtime = Runtime::bind(config, 0).await.unwrap();
    let mixed = runtime.local_addr().unwrap();
    assert_ne!(mixed.port(), 7899);
    let (stop, stopped) = oneshot::channel();
    let task = tokio::spawn(runtime.run(async {
        let _ = stopped.await;
    }));

    let result = timeout(WAIT, async {
        let peer = async {
            let (mut socket, _) = listener.accept().await.unwrap();
            let mut request = Vec::new();
            if anytls {
                let mut stream = open_anytls(socket).await;
                while !complete_chunk(&request) {
                    let (cmd, id, body) = frame(&mut stream).await;
                    assert_eq!((cmd, id), (2, 1));
                    request.extend_from_slice(&body);
                }
                let mut response = vec![2, 0, 0, 0, 1];
                response.extend_from_slice(&(RESPONSE.len() as u16).to_be_bytes());
                response.extend_from_slice(RESPONSE);
                response.extend_from_slice(b"\x03\0\0\0\x01\0\0");
                stream.write_all(&response).await.unwrap();
                stream.flush().await.unwrap();
            } else {
                while !complete_chunk(&request) {
                    request.push(socket.read_u8().await.unwrap());
                }
                socket.write_all(RESPONSE).await.unwrap();
            }
        };
        let client = async {
            let mut app = TcpStream::connect(mixed).await.unwrap();
            let target = if anytls {
                "example.com:80".to_owned()
            } else {
                format!("127.0.0.1:{port}")
            };
            app.write_all(format!("POST http://{target}/stream HTTP/1.1\r\nHost: {target}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n").as_bytes()).await.unwrap();
            app.write_all(CHUNK).await.unwrap();
            // No next header, terminal chunk, or write EOF until the response arrives.
            let mut response = vec![0; RESPONSE.len()];
            app.read_exact(&mut response).await.unwrap();
            assert_eq!(response, RESPONSE);
            drop(app);
        };
        tokio::join!(peer, client);
    })
    .await;
    stop.send(()).unwrap();
    timeout(WAIT, task).await.unwrap().unwrap().unwrap();
    result.expect("complete chunk must reach the peer and receive an early response without another client write");
}

#[tokio::test]
async fn direct_complete_chunk_allows_response_before_next_chunk() {
    early_response_after_chunk(false).await;
}

#[tokio::test]
async fn anytls_complete_chunk_allows_response_before_next_chunk() {
    early_response_after_chunk(true).await;
}
