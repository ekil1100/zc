// Test-only HTTP origin and EOF probe; intentionally independent of zc modules.
use anyhow::{Result, bail, ensure};
use std::io::{Read, Write};
use std::net::{Shutdown, TcpListener, TcpStream};
use std::time::{Duration, Instant};

fn main() -> Result<()> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    if args.first().map(String::as_str) == Some("socks-eof-probe") {
        ensure!(args.len() == 4, "InvalidArguments");
        let mut stream = TcpStream::connect(("127.0.0.1", port(&args[1])?))?;
        stream.set_read_timeout(Some(Duration::from_secs(8)))?;
        stream.set_write_timeout(Some(Duration::from_secs(8)))?;
        stream.write_all(&[5, 1, 0])?;
        let mut greeting = [0; 2];
        stream.read_exact(&mut greeting)?;
        ensure!(greeting == [5, 0], "InvalidSocksGreeting");
        ensure!(
            !args[3].is_empty() && args[3].len() <= 255,
            "InvalidTargetHost"
        );
        let mut request = vec![5, 1, 0, 3, args[3].len() as u8];
        request.extend_from_slice(args[3].as_bytes());
        request.extend_from_slice(&port(&args[2])?.to_be_bytes());
        stream.write_all(&request)?;
        let mut reply = [0; 10];
        stream.read_exact(&mut reply)?;
        ensure!(reply[..4] == [5, 0, 0, 1], "InvalidSocksConnectResponse");
        stream.write_all(b"NEEDS_EOF")?;
        stream.shutdown(Shutdown::Write)?;
        ensure!(stream.read(&mut [0; 12])? == 0, "UnexpectedEOFResponse");
        println!("E2E_TROJAN_TCP_EOF_TERMINATION=PASS");
        return Ok(());
    }
    ensure!(args.len() <= 1, "InvalidArguments");
    let mode = args.first().map(String::as_str).unwrap_or("http");
    ensure!(
        matches!(mode, "http" | "reject" | "eof-response" | "reserve-port"),
        "InvalidArguments"
    );
    let listener = TcpListener::bind("127.0.0.1:0")?;
    let port = listener.local_addr()?.port();
    ensure!(port != 7899, "ReservedPort");
    if mode == "reserve-port" {
        println!("{port}");
        return Ok(());
    }
    let label = if mode == "eof-response" {
        "E2E_EOF_ORIGIN_PORT"
    } else {
        "E2E_ORIGIN_PORT"
    };
    println!("{label}={port}");
    for _ in 0..256 {
        let (mut stream, _) = listener.accept()?;
        stream.set_write_timeout(Some(Duration::from_secs(8)))?;
        let deadline = Instant::now() + Duration::from_secs(8);
        let mut bytes = Vec::new();
        for _ in 0..16 {
            stream.set_read_timeout(Some(
                deadline
                    .saturating_duration_since(Instant::now())
                    .max(Duration::from_millis(1)),
            ))?;
            let mut buffer = [0; 4096];
            let count = stream.read(&mut buffer)?;
            if count == 0 {
                if mode == "eof-response" {
                    ensure!(bytes == b"NEEDS_EOF", "InvalidEOFPayload");
                    stream.write_all(b"EOF-RESPONSE")?;
                    println!("E2E_EOF_ORIGIN_RESPONSE=PASS");
                    return Ok(());
                }
                break;
            }
            bytes.extend_from_slice(&buffer[..count]);
            if mode == "eof-response" {
                ensure!(bytes.len() <= 64, "RequestTooLarge");
                continue;
            }
            if bytes.len() > 4096 {
                break;
            }
            if !bytes.windows(4).any(|w| w == b"\r\n\r\n") {
                continue;
            }
            let request = String::from_utf8_lossy(&bytes);
            let fields: Vec<_> = request
                .split("\r\n")
                .next()
                .unwrap_or("")
                .split(' ')
                .filter(|s| !s.is_empty())
                .collect();
            let valid = fields.len() == 3
                && fields[0] == "GET"
                && fields[2] == "HTTP/1.1"
                && fields[1].starts_with('/')
                && (2..=128).contains(&fields[1].len())
                && fields[1].as_bytes()[1..]
                    .iter()
                    .all(|c| c.is_ascii_alphanumeric() || *c == b'-' || *c == b'_');
            if !valid {
                stream.write_all(
                    b"HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
                )?;
                break;
            }
            let path = fields[1];
            let (status, body) = if mode == "reject" {
                println!("E2E_ORIGIN_REJECT={path}");
                ("403 Forbidden", "forbidden".to_owned())
            } else {
                println!("E2E_ORIGIN_REQUEST={path}");
                ("200 OK", format!("zc-e2e-origin:{}", &path[1..]))
            };
            write!(
                stream,
                "HTTP/1.1 {status}\r\nContent-Length: {}\r\nConnection: close\r\nContent-Type: text/plain\r\n\r\n{body}",
                body.len()
            )?;
            break;
        }
        if mode == "eof-response" {
            bail!("DeadlineExceeded");
        }
    }
    Ok(())
}

fn port(text: &str) -> Result<u16> {
    let port = text.parse()?;
    ensure!(port != 0 && port != 7899, "InvalidPort");
    Ok(port)
}
