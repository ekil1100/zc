// Independent test-only HTTP camouflage oracle. No production codec imports.
use anyhow::{Result, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use std::collections::HashMap;
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::time::{Instant, sleep, timeout, timeout_at};

const RESPONSE: &[u8] = b"HTTP/1.1 101 Switching Protocols\r\nServer: zc-e2e-obfs-oracle\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n";

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let a: Vec<_> = std::env::args().skip(1).collect();
    ensure!(a.len() == 5, "InvalidArguments");
    let backend: u16 = a[0].parse()?;
    let length: usize = a[2].parse()?;
    ensure!(
        backend != 0
            && backend != 7899
            && !a[1].is_empty()
            && a[1].len() <= 255
            && (1..=4096).contains(&length),
        "InvalidArguments"
    );
    ensure!(
        matches!(a[3].as_str(), "fragmented_header" | "same_write_tail"),
        "InvalidArguments"
    );
    let id = &a[4];
    ensure!(
        !id.is_empty()
            && id.len() <= 32
            && id
                .bytes()
                .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_'),
        "InvalidArguments"
    );
    let listener = TcpListener::bind("127.0.0.1:0").await?;
    let port = listener.local_addr()?.port();
    ensure!(port != 7899, "ReservedPort");
    println!("E2E_OBFS_ORACLE_READY={id}:{port}");
    println!(
        "E2E_OBFS_ORACLE_EXPECTED={id}:host={}:body={length}:mode={}",
        a[1], a[3]
    );
    let mut verified = 0;
    for raw in 1..=64 {
        let (front, _) = timeout(Duration::from_secs(120), listener.accept()).await??;
        println!("E2E_OBFS_ORACLE_RAW_ACCEPTED={id}:{raw}");
        match handle(front, backend, &a[1], port, length, &a[3]).await {
            Ok(()) => {
                verified += 1;
                println!("E2E_OBFS_ORACLE_VERIFIED={id}:{verified}");
                println!(
                    "E2E_OBFS_ORACLE_REQUEST={id}:GET_HOST_UPGRADE_CONNECTION_KEY_CONTENT_LENGTH_EXACT:{length}"
                );
                println!("E2E_OBFS_ORACLE_RESPONSE={id}:{}", a[3]);
                println!("E2E_OBFS_ORACLE_FORWARD={id}:RAW_TCP_HALF_CLOSE_PASS");
            }
            Err(e) => {
                println!("E2E_OBFS_ORACLE_REJECTED={id}:raw={raw}:verified={verified}:error={e}")
            }
        }
    }
    bail!("ConnectionLimitReached")
}

fn validate_header(bytes: &[u8], host: &str, port: u16, expected: usize) -> Result<usize> {
    let text = std::str::from_utf8(bytes)?;
    let mut lines = text.split("\r\n");
    ensure!(lines.next() == Some("GET / HTTP/1.1"), "InvalidRequestLine");
    let mut headers = HashMap::new();
    for (i, line) in lines.take_while(|s| !s.is_empty()).enumerate() {
        ensure!(i < 128, "TooManyHeaders");
        let (name, value) = line
            .split_once(':')
            .ok_or_else(|| anyhow::anyhow!("InvalidHeaderLine"))?;
        ensure!(!name.is_empty(), "InvalidHeaderLine");
        let name = name.to_ascii_lowercase();
        if matches!(
            name.as_str(),
            "host" | "upgrade" | "connection" | "sec-websocket-key" | "content-length"
        ) {
            ensure!(
                headers
                    .insert(name, value.trim_matches([' ', '\t']))
                    .is_none(),
                "DuplicateRequiredHeader"
            );
        }
    }
    let get = |name: &str| -> Result<&str> {
        headers
            .get(name)
            .copied()
            .ok_or_else(|| anyhow::anyhow!("MissingRequiredHeader"))
    };
    let expected_host = if port == 80 {
        host.to_owned()
    } else {
        format!("{host}:{port}")
    };
    ensure!(get("host")? == expected_host, "InvalidHostHeader");
    ensure!(
        get("upgrade")?.eq_ignore_ascii_case("websocket"),
        "InvalidUpgradeHeader"
    );
    ensure!(
        get("connection")?.eq_ignore_ascii_case("Upgrade"),
        "InvalidConnectionHeader"
    );
    ensure!(
        STANDARD.decode(get("sec-websocket-key")?)?.len() == 16,
        "InvalidWebSocketKey"
    );
    let value = get("content-length")?;
    ensure!(
        !value.is_empty() && value.bytes().all(|b| b.is_ascii_digit()),
        "InvalidContentLength"
    );
    let length: usize = value.parse()?;
    ensure!((1..=4096).contains(&length), "InvalidContentLength");
    ensure!(length == expected, "ContentLengthMismatch");
    Ok(length)
}

async fn write(stream: &mut TcpStream, bytes: &[u8]) -> Result<()> {
    timeout(Duration::from_secs(10), stream.write_all(bytes)).await??;
    Ok(())
}

async fn handle(
    mut front: TcpStream,
    backend_port: u16,
    host: &str,
    port: u16,
    expected: usize,
    mode: &str,
) -> Result<()> {
    let deadline = Instant::now() + Duration::from_secs(10);
    let mut request = Vec::new();
    let mut completed = false;
    let mut header_end = None;
    for _ in 0..128 {
        if let Some(end) = request
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .map(|i| i + 4)
        {
            ensure!(end <= 8192, "RequestHeaderLimitExceeded");
            if header_end.is_none() {
                validate_header(&request[..end], host, port, expected)?;
                header_end = Some(end);
            }
            if request.len() >= end + expected {
                completed = true;
                break;
            }
        } else {
            ensure!(request.len() < 8192, "RequestHeaderLimitExceeded");
        }
        ensure!(request.len() < 32768, "RequestBufferLimitExceeded");
        let mut buffer = vec![0; 32768 - request.len()];
        let count = timeout_at(deadline, front.read(&mut buffer)).await??;
        ensure!(count > 0, "RequestUnexpectedEof");
        request.extend_from_slice(&buffer[..count]);
    }
    ensure!(completed, "RequestReadLimitExceeded");
    let mut backend = timeout(
        Duration::from_secs(5),
        TcpStream::connect(("127.0.0.1", backend_port)),
    )
    .await??;
    write(&mut backend, &request[header_end.unwrap()..]).await?;
    let mut front_open = true;
    if mode == "fragmented_header" {
        let mut start = 0;
        for end in [
            1,
            8,
            31,
            67,
            RESPONSE.len() - 3,
            RESPONSE.len() - 1,
            RESPONSE.len(),
        ] {
            write(&mut front, &RESPONSE[start..end]).await?;
            start = end;
            if end != RESPONSE.len() {
                sleep(Duration::from_millis(2)).await;
            }
        }
    } else {
        let deadline = Instant::now() + Duration::from_secs(10);
        let mut sent = false;
        let mut fbuf = [0; 16384];
        let mut bbuf = [0; 16384];
        for _ in 0..4096 {
            tokio::select! {
                _ = tokio::time::sleep_until(deadline) => bail!("DeadlineExceeded"),
                n = front.read(&mut fbuf), if front_open => {
                    let n = n?;
                    if n == 0 { front_open = false; backend.shutdown().await?; }
                    else { write(&mut backend, &fbuf[..n]).await?; }
                }
                n = backend.read(&mut bbuf) => {
                    let n = n?;
                    ensure!(n > 0, "BackendUnexpectedEof");
                    let mut combined = RESPONSE.to_vec();
                    combined.extend_from_slice(&bbuf[..n]);
                    write(&mut front, &combined).await?;
                    sent = true;
                    break;
                }
            }
        }
        ensure!(sent, "RelayIterationLimitExceeded");
    }
    let lifetime = Instant::now() + Duration::from_secs(60);
    let mut idle = Instant::now() + Duration::from_secs(20);
    let mut backend_open = true;
    let mut fbuf = [0; 16384];
    let mut bbuf = [0; 16384];
    for _ in 0..4096 {
        if !front_open && !backend_open {
            return Ok(());
        }
        tokio::select! {
            _ = tokio::time::sleep_until(lifetime.min(idle)) => bail!("RelayDeadlineExceeded"),
            n = front.read(&mut fbuf), if front_open => {
                let n = n?;
                if n == 0 { front_open = false; backend.shutdown().await?; }
                else { write(&mut backend, &fbuf[..n]).await?; idle = Instant::now() + Duration::from_secs(20); }
            }
            n = backend.read(&mut bbuf), if backend_open => {
                let n = n?;
                if n == 0 { backend_open = false; front.shutdown().await?; }
                else { write(&mut front, &bbuf[..n]).await?; idle = Instant::now() + Duration::from_secs(20); }
            }
        }
    }
    bail!("RelayIterationLimitExceeded")
}
