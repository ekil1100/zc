#[path = "support/cli_fixture.rs"]
mod cli_fixture;
use serde_json::Value;
use std::{
    fs,
    path::PathBuf,
    process::{Command, Output},
    time::Duration,
};
struct Fixture {
    _home: tempfile::TempDir,
    home: PathBuf,
    runtime: PathBuf,
    config: PathBuf,
    _serial: std::sync::MutexGuard<'static, ()>,
}
impl Fixture {
    fn new() -> Self {
        let serial = cli_fixture::serial();
        let temp = tempfile::tempdir().unwrap();
        let home = temp.path().canonicalize().unwrap();
        let runtime = home.join("runtime");
        fs::create_dir(&runtime).unwrap();
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&runtime, fs::Permissions::from_mode(0o700)).unwrap();
        let config = home.join("config.yaml");
        fs::write(&config, "mixed-port: 17892\nproxy-groups:\n  - name: pick\n    type: select\n    proxies: [DIRECT, REJECT]\nrules: ['MATCH,pick']\n").unwrap();
        Self {
            _home: temp,
            home,
            runtime,
            config,
            _serial: serial,
        }
    }
    fn command(&self, args: &[&str]) -> Output {
        Command::new(env!("CARGO_BIN_EXE_zc"))
            .args(args)
            .env("HOME", &self.home)
            .env("XDG_RUNTIME_DIR", &self.runtime)
            .output()
            .unwrap()
    }
    fn json(&self, args: &[&str]) -> Value {
        let out = self.command(args);
        assert!(
            out.status.success(),
            "stdout={} stderr={}",
            String::from_utf8_lossy(&out.stdout),
            String::from_utf8_lossy(&out.stderr)
        );
        serde_json::from_slice(&out.stdout).unwrap()
    }
}
impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = self.command(&["stop", "--json"]);
    }
}
fn free_port() -> u16 {
    std::net::TcpListener::bind("127.0.0.1:0")
        .unwrap()
        .local_addr()
        .unwrap()
        .port()
}
fn log_events(f: &Fixture) -> Vec<Value> {
    let out = f.command(&["log", "--json", "--no-follow", "-n", "50"]);
    assert!(out.status.success(), "{out:?}");
    String::from_utf8(out.stdout)
        .unwrap()
        .lines()
        .filter_map(|line| {
            let envelope: Value = serde_json::from_str(line).unwrap();
            serde_json::from_str(envelope["line"].as_str().unwrap()).ok()
        })
        .collect()
}

#[test]
fn refused_upstream_is_logged_without_request_secrets() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,DIRECT']\n").unwrap();
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    let closed = free_port();
    let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write!(client, "CONNECT 127.0.0.1:{closed} HTTP/1.1\r\nHost: 127.0.0.1:{closed}\r\nProxy-Authorization: Basic private-token\r\n\r\n").unwrap();
    let mut response = String::new();
    client.read_to_string(&mut response).unwrap();
    assert!(response.starts_with("HTTP/1.1 502"));
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    assert!(
        events.iter().any(|e| e["event"] == "connection_failed"
            && e["stage"] == "connect"
            && e["error_kind"] == "ConnectionRefused"),
        "{events:?}"
    );
    let text = format!("{events:?}");
    assert!(!text.contains("private-token"));
    assert!(!text.contains(&format!("127.0.0.1:{closed}")));
}

#[test]
fn reject_and_clean_disconnect_are_not_faults() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,REJECT']\n").unwrap();
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    drop(std::net::TcpStream::connect(("127.0.0.1", port)).unwrap());
    let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    client.write_all(b"CONNECT private-target.invalid:443 HTTP/1.1\r\nHost: private-target.invalid:443\r\n\r\n").unwrap();
    let mut response = String::new();
    client.read_to_string(&mut response).unwrap();
    assert!(response.starts_with("HTTP/1.1 502"));
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    assert!(
        !events.iter().any(|e| e["event"] == "connection_failed"),
        "{events:?}"
    );
    assert!(!format!("{events:?}").contains("private-target"));
    let summary = events
        .iter()
        .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
        .unwrap();
    assert_eq!(summary["failures"], 0);
    assert_eq!(summary["rejections"], 1);
    assert_eq!(summary["active_connections"], 0);
}

#[test]
fn actual_tls_handshake_failure_is_classified() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    fs::write(&f.config, format!("proxies:\n  - name: private-proxy\n    type: trojan\n    server: 127.0.0.1\n    port: {}\n    password: private-password\n    skip-cert-verify: true\nrules: ['MATCH,private-proxy']\n", upstream.local_addr().unwrap().port())).unwrap();
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    let server = std::thread::spawn(move || {
        let (mut socket, _) = upstream.accept().unwrap();
        socket
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut hello = [0; 4096];
        assert!(socket.read(&mut hello).unwrap() > 0);
        socket.write_all(b"HTTP/1.1 400 Not TLS\r\n\r\n").unwrap();
    });
    let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    client.write_all(b"CONNECT private-target.invalid:443 HTTP/1.1\r\nHost: private-target.invalid:443\r\n\r\n").unwrap();
    let mut response = String::new();
    client.read_to_string(&mut response).unwrap();
    assert!(response.starts_with("HTTP/1.1 502"));
    server.join().unwrap();
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    assert!(
        events
            .iter()
            .any(|e| e["event"] == "connection_failed" && e["stage"] == "tls"),
        "{events:?}"
    );
    assert!(!format!("{events:?}").contains("private-"));
}

#[test]
fn udp_open_failure_is_accounted_without_leaking_target() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    let closed = free_port();
    fs::write(&f.config, format!("proxies:\n  - name: private-udp\n    type: trojan\n    server: 127.0.0.1\n    port: {closed}\n    password: private-password\n    skip-cert-verify: true\n    udp: true\nrules: ['MATCH,private-udp']\n")).unwrap();
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    let mut control = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    control
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    control.write_all(&[5, 1, 0]).unwrap();
    let mut method = [0; 2];
    control.read_exact(&mut method).unwrap();
    assert_eq!(method, [5, 0]);
    control.write_all(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap();
    let mut reply = [0; 10];
    control.read_exact(&mut reply).unwrap();
    assert_eq!(&reply[..4], &[5, 0, 0, 1]);
    let relay = std::net::SocketAddrV4::new(
        std::net::Ipv4Addr::new(reply[4], reply[5], reply[6], reply[7]),
        u16::from_be_bytes([reply[8], reply[9]]),
    );
    let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let target = b"private-target.invalid";
    let mut packet = vec![0, 0, 0, 3, target.len() as u8];
    packet.extend_from_slice(target);
    packet.extend_from_slice(&[0, 53, 1]);
    socket.send_to(&packet, relay).unwrap();
    assert_eq!(control.read(&mut [0]).unwrap(), 0);
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    assert!(
        events.iter().any(|e| e["event"] == "connection_failed"
            && e["stage"] == "connect"
            && e["error_kind"] == "ConnectionRefused"),
        "{events:?}"
    );
    assert!(!format!("{events:?}").contains("private-"));
}

#[test]
fn socks_refused_burst_is_bounded() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,DIRECT']\n").unwrap();
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    let closed = free_port();
    for _ in 0..32 {
        let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        client.write_all(&[5, 1, 0]).unwrap();
        let mut method = [0; 2];
        client.read_exact(&mut method).unwrap();
        assert_eq!(method, [5, 0]);
        let mut request = vec![5, 1, 0, 1, 127, 0, 0, 1];
        request.extend_from_slice(&closed.to_be_bytes());
        client.write_all(&request).unwrap();
        let mut reply = [0; 10];
        client.read_exact(&mut reply).unwrap();
        assert_eq!(reply[1], 5);
    }
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    let failures: Vec<_> = events
        .iter()
        .filter(|e| e["event"] == "connection_failed" || e["event"] == "connection_failure_summary")
        .collect();
    assert!(!failures.is_empty(), "{events:?}");
    assert_eq!(
        failures
            .iter()
            .map(|e| e["count"].as_u64().unwrap())
            .sum::<u64>(),
        32
    );
    let summary = events
        .iter()
        .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
        .unwrap();
    assert_eq!(summary["failures"], 32);
    assert_eq!(summary["active_connections"], 0);
    assert!(
        failures.len() < 32,
        "repeated faults must be coalesced: {events:?}"
    );
}

#[test]
fn udp_send_wire_limit_failure_is_classified() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    let upstream = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    fs::write(&f.config, format!("proxies:\n  - name: private-udp\n    type: ss\n    server: 127.0.0.1\n    port: {}\n    password: private-password\n    cipher: aes-128-gcm\n    udp: true\nrules: ['MATCH,private-udp']\n", upstream.local_addr().unwrap().port())).unwrap();
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    let mut control = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    control
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    control.write_all(&[5, 1, 0]).unwrap();
    let mut method = [0; 2];
    control.read_exact(&mut method).unwrap();
    assert_eq!(method, [5, 0]);
    control.write_all(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap();
    let mut reply = [0; 10];
    control.read_exact(&mut reply).unwrap();
    assert_eq!(&reply[..4], &[5, 0, 0, 1]);
    let relay = std::net::SocketAddrV4::new(
        std::net::Ipv4Addr::new(reply[4], reply[5], reply[6], reply[7]),
        u16::from_be_bytes([reply[8], reply[9]]),
    );
    let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    #[cfg(unix)]
    rustix::net::sockopt::set_socket_send_buffer_size(&socket, 256 * 1024).unwrap();
    // Legal SOCKS wire size, but insufficient space for the SS salt and tag.
    let mut packet = vec![0, 0, 0, 1, 127, 0, 0, 1, 0, 53];
    packet.resize(65507, 1);
    socket.send_to(&packet, relay).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let events = log_events(&f);
        if events
            .iter()
            .any(|e| e["event"] == "connection_failed" && e["stage"] == "udp")
        {
            assert!(!format!("{events:?}").contains("private-"));
            break;
        }
        assert!(std::time::Instant::now() < deadline, "{events:?}");
        std::thread::sleep(Duration::from_millis(20));
    }
    f.json(&["stop", "--json"]);
}

#[test]
fn clean_tunnel_and_aborted_handshake_release_live_count() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,DIRECT']\n").unwrap();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let target = upstream.local_addr().unwrap();
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write!(
        client,
        "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n"
    )
    .unwrap();
    let mut reply = [0; 39];
    client.read_exact(&mut reply).unwrap();
    assert_eq!(&reply, b"HTTP/1.1 200 Connection Established\r\n\r\n");
    let (server, _) = upstream.accept().unwrap();
    drop(server);
    client.shutdown(std::net::Shutdown::Write).unwrap();
    assert_eq!(client.read(&mut [0]).unwrap(), 0);
    let mut pending = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    pending
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    // The method reply proves acceptance, then the incomplete request waits for abort.
    pending.write_all(&[5, 1, 0]).unwrap();
    let mut method = [0; 2];
    pending.read_exact(&mut method).unwrap();
    assert_eq!(method, [5, 0]);
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    let summary = events
        .iter()
        .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
        .unwrap();
    assert_eq!(summary["failures"], 0);
    assert_eq!(summary["active_connections"], 0);
    assert_eq!(summary["total_connections"], 2);
}

fn accept_upstream(listener: &std::net::TcpListener) -> std::net::TcpStream {
    listener.set_nonblocking(true).unwrap();
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        match listener.accept() {
            Ok((socket, _)) => {
                socket.set_nonblocking(false).unwrap();
                return socket;
            }
            Err(error) if error.kind() == std::io::ErrorKind::WouldBlock => {
                assert!(
                    std::time::Instant::now() < deadline,
                    "upstream was not dialed"
                );
                std::thread::sleep(Duration::from_millis(10));
            }
            Err(error) => panic!("cannot accept upstream connection: {error}"),
        }
    }
}

#[test]
fn truncated_http_response_is_a_transfer_failure_without_secrets() {
    check_truncated_http_response(false);
}

#[test]
fn reset_during_http_content_length_is_a_transfer_failure() {
    check_truncated_http_response(true);
}

fn reset_socket(socket: std::net::TcpStream) {
    rustix::net::sockopt::set_socket_linger(&socket, Some(Duration::ZERO)).unwrap();
    drop(socket);
}

fn check_truncated_http_response(reset: bool) {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,DIRECT']\n").unwrap();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let target = upstream.local_addr().unwrap();
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    write!(client, "GET http://{target}/private-path?token=private-query HTTP/1.1\r\nHost: {target}\r\nAuthorization: Bearer private-auth\r\nProxy-Authorization: Basic private-proxy-auth\r\nConnection: close\r\n\r\n").unwrap();
    let mut server = accept_upstream(&upstream);
    server
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut request = Vec::new();
    while !request.ends_with(b"\r\n\r\n") {
        assert!(request.len() < 16 * 1024);
        let mut byte = [0];
        server.read_exact(&mut byte).unwrap();
        request.push(byte[0]);
    }
    let response = b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nX-Private: private-response\r\nConnection: close\r\n\r\nx";
    server.write_all(response).unwrap();
    // Wait until the partial body reaches the client before resetting the peer.
    let mut received = vec![0; response.len()];
    client.read_exact(&mut received).unwrap();
    assert_eq!(received, response);
    if reset {
        reset_socket(server);
    } else {
        drop(server);
    }
    assert_eq!(client.read(&mut [0]).unwrap(), 0);
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    assert!(
        events.iter().any(|e| e["event"] == "connection_failed"
            && e["stage"] == "transfer"
            && e["error_kind"]
                == if reset {
                    "ConnectionReset"
                } else {
                    "UnexpectedEof"
                }),
        "{events:?}"
    );
    let summary = events
        .iter()
        .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
        .unwrap();
    assert_eq!(summary["failures"], 1);
    assert_eq!(summary["active_connections"], 0);
    let logs = f.command(&["log", "--no-follow", "-n", "50"]);
    assert!(logs.status.success());
    let logs = String::from_utf8(logs.stdout).unwrap();
    assert!(!logs.contains("private-"));
    assert!(!logs.contains(&target.to_string()));
}

#[test]
fn truncated_response_headers_and_chunk_framing_are_not_normal_eof() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,DIRECT']\n").unwrap();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let target = upstream.local_addr().unwrap();
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    for response in [
        &b"HTTP/1.1 200 OK\r\nContent-Length: 100\r\nX-Private: incomplete"[..],
        &b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n1\r\nx\r\n"[..],
    ] {
        let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
        client
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        write!(
            client,
            "GET http://{target}/ HTTP/1.1\r\nHost: {target}\r\nConnection: close\r\n\r\n"
        )
        .unwrap();
        let mut server = accept_upstream(&upstream);
        server
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        let mut request = Vec::new();
        while !request.ends_with(b"\r\n\r\n") {
            assert!(request.len() < 16 * 1024);
            let mut byte = [0];
            server.read_exact(&mut byte).unwrap();
            request.push(byte[0]);
        }
        server.write_all(response).unwrap();
        drop(server);
        client.read_to_end(&mut Vec::new()).unwrap();
    }
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    let summary = events
        .iter()
        .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
        .unwrap();
    assert_eq!(summary["failures_by_stage"]["transfer"], 2, "{events:?}");
    assert_eq!(summary["active_connections"], 0);
}

#[test]
fn stalled_trojan_tls_keeps_its_stage_and_original_deadline_per_operation() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let closed = free_port();
    fs::write(&f.config, format!("proxies:\n  - name: private-proxy\n    type: trojan\n    server: 127.0.0.1\n    port: {}\n    password: private-password\n    skip-cert-verify: true\n    udp: true\nrules: ['DST-PORT,{closed},DIRECT', 'MATCH,private-proxy']\n", upstream.local_addr().unwrap().port())).unwrap();
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    let started = std::time::Instant::now();
    let mut client = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    client
        .set_read_timeout(Some(Duration::from_secs(13)))
        .unwrap();
    let body = "private-client-body";
    write!(client, "POST http://private-target.invalid/private-path?private-query HTTP/1.1\r\nHost: private-target.invalid\r\nAuthorization: Bearer private-auth\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).unwrap();
    let mut tcp_peer = accept_upstream(&upstream);
    tcp_peer
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    let mut hello = [0; 4096];
    assert!(tcp_peer.read(&mut hello).unwrap() > 0);
    assert_eq!(hello[0], 22, "peer must receive a TLS handshake");

    let mut control = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    control
        .set_read_timeout(Some(Duration::from_secs(13)))
        .unwrap();
    control.write_all(&[5, 1, 0]).unwrap();
    let mut method = [0; 2];
    control.read_exact(&mut method).unwrap();
    assert_eq!(method, [5, 0]);
    control.write_all(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap();
    let mut reply = [0; 10];
    control.read_exact(&mut reply).unwrap();
    assert_eq!(&reply[..4], &[5, 0, 0, 1]);
    let relay = std::net::SocketAddrV4::new(
        std::net::Ipv4Addr::new(reply[4], reply[5], reply[6], reply[7]),
        u16::from_be_bytes([reply[8], reply[9]]),
    );
    let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let mut packet = vec![0, 0, 0, 1, 127, 0, 0, 1, 0, 53];
    packet.extend_from_slice(b"private-udp-body");
    socket.send_to(&packet, relay).unwrap();
    let mut udp_peer = accept_upstream(&upstream);
    udp_peer
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    assert!(udp_peer.read(&mut hello).unwrap() > 0);
    assert_eq!(hello[0], 22);

    // A concurrent operation at Connect must not overwrite either TLS stage.
    let mut refused = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    refused
        .set_read_timeout(Some(Duration::from_secs(2)))
        .unwrap();
    write!(
        refused,
        "CONNECT 127.0.0.1:{closed} HTTP/1.1\r\nHost: 127.0.0.1:{closed}\r\n\r\n"
    )
    .unwrap();
    let mut response = String::new();
    refused.read_to_string(&mut response).unwrap();
    assert!(response.starts_with("HTTP/1.1 502"));
    response.clear();
    client.read_to_string(&mut response).unwrap();
    assert!(response.starts_with("HTTP/1.1 502"));
    assert_eq!(control.read(&mut [0]).unwrap(), 0);
    assert!(started.elapsed() >= Duration::from_millis(9500));
    assert!(started.elapsed() < Duration::from_secs(13));
    assert_eq!(tcp_peer.read(&mut [0]).unwrap(), 0);
    assert_eq!(udp_peer.read(&mut [0]).unwrap(), 0);
    upstream.set_nonblocking(true).unwrap();
    assert_eq!(
        upstream.accept().unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    let tls_failures: u64 = events
        .iter()
        .filter(|e| {
            (e["event"] == "connection_failed" || e["event"] == "connection_failure_summary")
                && e["stage"] == "tls"
                && e["error_kind"] == "TimedOut"
        })
        .map(|e| e["count"].as_u64().unwrap())
        .sum();
    assert_eq!(tls_failures, 2, "{events:?}");
    let summary = events
        .iter()
        .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
        .unwrap();
    assert_eq!(summary["failures"], 3);
    assert_eq!(summary["failures_by_stage"]["connect"], 1);
    assert_eq!(summary["active_connections"], 0);
    let logs = f.command(&["log", "--no-follow", "-n", "50"]);
    assert!(logs.status.success());
    assert!(!String::from_utf8(logs.stdout).unwrap().contains("private-"));
}

fn start_fixture(f: &Fixture) -> u16 {
    let port = free_port();
    f.json(&[
        "start",
        "-c",
        f.config.to_str().unwrap(),
        "--port",
        &port.to_string(),
        "--json",
    ]);
    port
}

fn tcp_client(port: u16) -> std::net::TcpStream {
    let socket = std::net::TcpStream::connect(("127.0.0.1", port)).unwrap();
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    socket
        .set_write_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    socket
}

fn read_http_header(socket: &mut std::net::TcpStream) -> Vec<u8> {
    use std::io::Read;
    socket
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    let mut header = Vec::new();
    while !header.ends_with(b"\r\n\r\n") {
        assert!(header.len() < 16 * 1024);
        let mut byte = [0];
        socket.read_exact(&mut byte).unwrap();
        header.push(byte[0]);
    }
    header
}

fn assert_transfer_failures(f: &Fixture, expected: u64) {
    f.json(&["stop", "--json"]);
    let events = log_events(f);
    let summary = events
        .iter()
        .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
        .unwrap();
    assert_eq!(summary["failures"], expected, "{events:?}");
    assert_eq!(
        summary["failures_by_stage"]["transfer"], expected,
        "{events:?}"
    );
    assert_eq!(summary["active_connections"], 0);
    assert!(!format!("{events:?}").contains("private-"));
}

#[test]
fn truncated_chunk_request_is_a_transfer_failure() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,DIRECT']\n").unwrap();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let target = upstream.local_addr().unwrap();
    let port = start_fixture(&f);
    for body in ["1\r\nx", "1\r\nx\r\n", "0\r\nX-Private: incomplete"] {
        let mut client = tcp_client(port);
        write!(client, "POST http://{target}/private-path HTTP/1.1\r\nHost: {target}\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n{body}").unwrap();
        client.shutdown(std::net::Shutdown::Write).unwrap();
        let mut server = accept_upstream(&upstream);
        read_http_header(&mut server);
        server.read_to_end(&mut Vec::new()).unwrap();
        assert_eq!(client.read(&mut [0]).unwrap(), 0);
    }
    assert_transfer_failures(&f, 3);
}

#[test]
fn truncated_shadowsocks_salt_is_a_transfer_failure() {
    check_truncated_ss_response(false, false);
}

#[test]
fn truncated_simple_obfs_response_is_a_transfer_failure() {
    check_truncated_ss_response(true, false);
}

#[test]
fn reset_during_shadowsocks_salt_is_a_transfer_failure() {
    check_truncated_ss_response(false, true);
}

#[test]
fn reset_during_simple_obfs_header_is_a_transfer_failure() {
    check_truncated_ss_response(true, true);
}

fn check_truncated_ss_response(obfs: bool, reset: bool) {
    use std::io::{Read, Write};
    let f = Fixture::new();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let plugin = if obfs {
        "    plugin: obfs\n    plugin-opts: {mode: http, host: private-obfs.invalid}\n"
    } else {
        ""
    };
    fs::write(&f.config, format!("proxies:\n  - name: private-ss\n    type: ss\n    server: 127.0.0.1\n    port: {}\n    password: private-password\n    cipher: aes-128-gcm\n{plugin}rules: ['MATCH,private-ss']\n", upstream.local_addr().unwrap().port())).unwrap();
    let port = start_fixture(&f);
    let mut client = tcp_client(port);
    client
        .write_all(b"CONNECT 127.0.0.1:443 HTTP/1.1\r\nHost: 127.0.0.1:443\r\n\r\n")
        .unwrap();
    assert_eq!(
        read_http_header(&mut client),
        b"HTTP/1.1 200 Connection Established\r\n\r\n"
    );
    let mut server = accept_upstream(&upstream);
    server
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    if obfs {
        let header = read_http_header(&mut server);
        assert!(header.starts_with(b"GET / HTTP/1.1\r\n"));
    }
    // AES-128-GCM salt + encrypted length + IPv4 destination + authentication tag.
    server.read_exact(&mut [0; 16 + 18 + 7 + 16]).unwrap();
    if obfs {
        server
            .write_all(b"HTTP/1.1 101 Switching Protocols\r\nX-Private: incomplete")
            .unwrap();
    } else {
        server.write_all(b"x").unwrap();
    }
    if reset {
        reset_socket(server);
        assert_eq!(client.read(&mut [0]).unwrap(), 0);
    } else {
        server.shutdown(std::net::Shutdown::Write).unwrap();
        assert_eq!(client.read(&mut [0]).unwrap(), 0);
        assert_eq!(server.read(&mut [0]).unwrap(), 0);
    }
    assert_transfer_failures(&f, 1);
    if reset {
        assert!(
            log_events(&f)
                .iter()
                .any(|e| e["event"] == "connection_failed"
                    && e["stage"] == "transfer"
                    && e["error_kind"] == "ConnectionReset")
        );
    }
}

#[derive(Clone, Copy, Debug)]
enum SsResponseBoundary {
    Salt,
    Length,
    PartialPayload,
    Payload,
}

#[test]
fn shadowsocks_aead_completed_length_still_requires_payload_on_reset() {
    for obfs in [false, true] {
        for completed_chunks in [0, 1] {
            check_ss_aead_boundary(obfs, completed_chunks, SsResponseBoundary::Length, true);
        }
    }
}

#[test]
fn shadowsocks_aead_completed_salt_still_requires_first_length_on_reset() {
    for obfs in [false, true] {
        check_ss_aead_boundary(obfs, 0, SsResponseBoundary::Salt, true);
    }
}

#[test]
fn shadowsocks_aead_partial_payload_reset_remains_a_fault() {
    check_ss_aead_boundary(false, 0, SsResponseBoundary::PartialPayload, true);
}

#[test]
fn shadowsocks_aead_complete_payload_reset_is_not_a_fault() {
    for obfs in [false, true] {
        for completed_chunks in [0, 1] {
            check_ss_aead_boundary(obfs, completed_chunks, SsResponseBoundary::Payload, true);
        }
    }
}

#[test]
fn shadowsocks_aead_fin_retains_library_boundary_behavior() {
    // The locked reader accepts EOF before any length bytes, including after salt,
    // but requires a payload once a length has been read successfully.
    for boundary in [
        SsResponseBoundary::Salt,
        SsResponseBoundary::Length,
        SsResponseBoundary::Payload,
    ] {
        check_ss_aead_boundary(false, 0, boundary, false);
    }
}

fn check_ss_aead_boundary(
    obfs: bool,
    completed_chunks: usize,
    boundary: SsResponseBoundary,
    reset: bool,
) {
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        crypto::CipherKind,
        relay::tcprelay::proxy_stream::ProxyServerStream,
    };
    use std::io::{Read, Write};
    let f = Fixture::new();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = upstream.local_addr().unwrap();
    let method = CipherKind::AES_128_GCM;
    let config = ServerConfig::new(address, "private-password", method).unwrap();
    let (wire, first_end) = tokio::runtime::Builder::new_current_thread()
        .build()
        .unwrap()
        .block_on(async {
            use tokio::io::AsyncWriteExt;
            // Let the library generate salt, encrypted lengths and authenticated data.
            let mut encoder = ProxyServerStream::from_stream(
                Context::new_shared(ServerType::Server),
                std::io::Cursor::new(Vec::new()),
                method,
                config.key(),
            );
            encoder.write_all(b"first").await.unwrap();
            let first_end = encoder.get_ref().get_ref().len();
            encoder.write_all(b"second").await.unwrap();
            (encoder.into_inner().into_inner(), first_end)
        });
    let plugin = if obfs {
        "    plugin: obfs\n    plugin-opts: {mode: http, host: private-obfs.invalid}\n"
    } else {
        ""
    };
    fs::write(&f.config, format!("proxies:\n  - name: private-ss\n    type: ss\n    server: 127.0.0.1\n    port: {}\n    password: private-password\n    cipher: aes-128-gcm\n{plugin}rules: ['MATCH,private-ss']\n", address.port())).unwrap();
    let port = start_fixture(&f);
    let mut client = tcp_client(port);
    client
        .write_all(b"CONNECT 127.0.0.1:443 HTTP/1.1\r\nHost: 127.0.0.1:443\r\n\r\n")
        .unwrap();
    assert_eq!(
        read_http_header(&mut client),
        b"HTTP/1.1 200 Connection Established\r\n\r\n"
    );
    let mut server = accept_upstream(&upstream);
    server
        .set_read_timeout(Some(Duration::from_secs(5)))
        .unwrap();
    if obfs {
        assert!(read_http_header(&mut server).starts_with(b"GET / HTTP/1.1\r\n"));
    }
    // Drain the outgoing IPv4 destination frame before intentionally resetting.
    server
        .read_exact(&mut vec![
            0;
            method.salt_len()
                + 2
                + method.tag_len()
                + 7
                + method.tag_len()
        ])
        .unwrap();
    let chunk_start = if completed_chunks == 0 {
        method.salt_len()
    } else {
        first_end
    };
    let end = match boundary {
        SsResponseBoundary::Salt => method.salt_len(),
        SsResponseBoundary::Length => chunk_start + 2 + method.tag_len(),
        SsResponseBoundary::PartialPayload => chunk_start + 2 + method.tag_len() + 1,
        SsResponseBoundary::Payload => {
            if completed_chunks == 0 {
                first_end
            } else {
                wire.len()
            }
        }
    };
    let mut response = Vec::new();
    if obfs {
        response.extend_from_slice(b"HTTP/1.1 101 Switching Protocols\r\n\r\n");
    }
    response.extend_from_slice(&wire[..end]);
    server.write_all(&response).unwrap();
    let delivered = match (completed_chunks, boundary) {
        (0, SsResponseBoundary::Payload) => b"first".as_slice(),
        (1, SsResponseBoundary::Payload) => b"firstsecond".as_slice(),
        (1, _) => b"first".as_slice(),
        _ => b"".as_slice(),
    };
    let mut plaintext = vec![0; delivered.len()];
    client.read_exact(&mut plaintext).unwrap();
    assert_eq!(plaintext, delivered);
    if reset {
        reset_socket(server);
    } else {
        server.shutdown(std::net::Shutdown::Write).unwrap();
    }
    assert_eq!(client.read(&mut [0]).unwrap(), 0);
    let fault = match boundary {
        SsResponseBoundary::Salt => reset,
        SsResponseBoundary::Length | SsResponseBoundary::PartialPayload => true,
        SsResponseBoundary::Payload => false,
    };
    assert_transfer_failures(&f, u64::from(fault));
    if fault {
        let kind = if reset {
            "ConnectionReset"
        } else {
            "UnexpectedEof"
        };
        let events = log_events(&f);
        assert!(
            events.iter().any(|e| e["event"] == "connection_failed"
                && e["stage"] == "transfer"
                && e["error_kind"] == kind),
            "{boundary:?}, completed_chunks={completed_chunks}, obfs={obfs}: {events:?}"
        );
    }
}

#[cfg(target_os = "linux")]
fn process_socket_count(pid: u64) -> usize {
    fs::read_dir(format!("/proc/{pid}/fd"))
        .unwrap()
        .filter_map(|entry| fs::read_link(entry.ok()?.path()).ok())
        .filter(|path| path.to_string_lossy().starts_with("socket:["))
        .count()
}

#[cfg(target_os = "macos")]
fn process_socket_count(pid: u64) -> usize {
    let output = Command::new("/usr/sbin/lsof")
        .args(["-nP", "-a", "-p", &pid.to_string(), "-i", "-Ff"])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "cannot inspect fixture sockets: {output:?}"
    );
    String::from_utf8(output.stdout)
        .unwrap()
        .lines()
        .filter(|line| line.starts_with('f'))
        .count()
}

fn wait_for_socket_count(pid: u64, expected: usize) {
    let deadline = std::time::Instant::now() + Duration::from_secs(5);
    loop {
        let count = process_socket_count(pid);
        if count == expected {
            return;
        }
        assert!(
            std::time::Instant::now() < deadline,
            "fixture sockets were not released: expected {expected}, found {count}"
        );
        std::thread::sleep(Duration::from_millis(20));
    }
}

fn socks_control(port: u16) -> std::net::TcpStream {
    use std::io::{Read, Write};
    let mut control = tcp_client(port);
    control.write_all(&[5, 1, 0]).unwrap();
    let mut method = [0; 2];
    control.read_exact(&mut method).unwrap();
    assert_eq!(method, [5, 0]);
    control
}

#[test]
fn udp_associate_reset_burst_is_not_a_transport_fault_and_releases_sockets() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    let upstream = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    fs::write(&f.config, format!("proxies:\n  - name: private-udp\n    type: ss\n    server: 127.0.0.1\n    port: {}\n    password: private-password\n    cipher: aes-128-gcm\n    udp: true\nrules: ['MATCH,private-udp']\n", upstream.local_addr().unwrap().port())).unwrap();
    let port = start_fixture(&f);
    let status = f.json(&["status", "--json"]);
    let pid = status["data"]["pid"].as_u64().unwrap();
    let baseline = process_socket_count(pid);
    const REQUEST: &[u8] = &[5, 3, 0, 1, 0, 0, 0, 0, 0, 0];
    for _ in 0..256 {
        let mut control = socks_control(port);
        control.write_all(REQUEST).unwrap();
        reset_socket(control);
    }
    // Check the live process, not cleanup performed by daemon stop.
    wait_for_socket_count(pid, baseline);
    let mut controls = Vec::new();
    for _ in 0..64 {
        let mut control = socks_control(port);
        control.write_all(REQUEST).unwrap();
        let mut reply = [0; 10];
        control.read_exact(&mut reply).unwrap();
        assert_eq!(
            &reply[..4],
            &[5, 0, 0, 1],
            "association slots must be reusable"
        );
        controls.push(control);
    }
    // Positive control: both the TCP controls and the relay sockets are visible.
    assert_eq!(process_socket_count(pid), baseline + 128);
    for mut control in controls {
        control.shutdown(std::net::Shutdown::Write).unwrap();
        assert_eq!(control.read(&mut [0]).unwrap(), 0);
    }
    wait_for_socket_count(pid, baseline);
    upstream.set_nonblocking(true).unwrap();
    assert_eq!(
        upstream.recv_from(&mut [0]).unwrap_err().kind(),
        std::io::ErrorKind::WouldBlock
    );
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    let summary = events
        .iter()
        .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
        .unwrap();
    assert_eq!(summary["failures_by_stage"]["udp"], 0, "{events:?}");
    assert_eq!(summary["failures"], 0, "{events:?}");
    assert_eq!(summary["active_connections"], 0);
    assert_eq!(summary["total_connections"], 320);
}

#[test]
fn reset_during_http_headers_and_chunk_framing_is_a_transfer_failure() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,DIRECT']\n").unwrap();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let target = upstream.local_addr().unwrap();
    let port = start_fixture(&f);
    for tail in [
        None,
        Some("1\r\nx"),
        Some("1\r\nx\r\n"),
        Some("0\r\nX-Private: incomplete"),
    ] {
        let mut client = tcp_client(port);
        write!(
            client,
            "GET http://{target}/ HTTP/1.1\r\nHost: {target}\r\nConnection: close\r\n\r\n"
        )
        .unwrap();
        let mut server = accept_upstream(&upstream);
        read_http_header(&mut server);
        if let Some(tail) = tail {
            server
                .write_all(
                    b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n",
                )
                .unwrap();
            read_http_header(&mut client);
            server.write_all(tail.as_bytes()).unwrap();
            if tail.starts_with('1') {
                let mut body = [0; 4];
                client.read_exact(&mut body).unwrap();
                assert_eq!(&body, b"1\r\nx");
            }
        } else {
            server
                .write_all(b"HTTP/1.1 200 OK\r\nX-Private: incomplete")
                .unwrap();
        }
        reset_socket(server);
        client.read_to_end(&mut Vec::new()).unwrap();
    }
    assert_transfer_failures(&f, 4);
}

#[test]
fn client_reset_during_http_response_is_not_a_framing_fault() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,DIRECT']\n").unwrap();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let target = upstream.local_addr().unwrap();
    let port = start_fixture(&f);
    let mut client = tcp_client(port);
    write!(
        client,
        "GET http://{target}/ HTTP/1.1\r\nHost: {target}\r\nConnection: close\r\n\r\n"
    )
    .unwrap();
    let mut server = accept_upstream(&upstream);
    read_http_header(&mut server);
    server
        .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 100000\r\nConnection: close\r\n\r\nx")
        .unwrap();
    read_http_header(&mut client);
    let mut first = [0];
    client.read_exact(&mut first).unwrap();
    assert_eq!(&first, b"x");
    reset_socket(client);
    server.write_all(&[b'x'; 4096]).unwrap();
    // Do not close the origin first: only the downstream write may fail.
    assert_eq!(server.read(&mut [0]).unwrap(), 0);
    assert_transfer_failures(&f, 0);
}

#[test]
fn early_final_response_cancels_fixed_and_chunked_uploads_without_faults() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,DIRECT']\n").unwrap();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let target = upstream.local_addr().unwrap();
    let port = start_fixture(&f);
    for framing in ["Content-Length: 1024", "Transfer-Encoding: chunked"] {
        let mut client = tcp_client(port);
        write!(client, "POST http://{target}/ HTTP/1.1\r\nHost: {target}\r\nExpect: 100-continue\r\n{framing}\r\nConnection: close\r\n\r\n").unwrap();
        let mut server = accept_upstream(&upstream);
        read_http_header(&mut server);
        let response = b"HTTP/1.1 413 Payload Too Large\r\nContent-Length: 0\r\n\r\n";
        server.write_all(response).unwrap();
        let mut received = Vec::new();
        client.read_to_end(&mut received).unwrap();
        assert_eq!(received, response);
        assert_eq!(server.read(&mut [0]).unwrap(), 0);
    }
    assert_transfer_failures(&f, 0);
}

#[test]
fn direct_tunnel_resets_are_not_protocol_truncations() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    fs::write(&f.config, "rules: ['MATCH,DIRECT']\n").unwrap();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let target = upstream.local_addr().unwrap();
    let port = start_fixture(&f);
    for reset_client in [true, false] {
        let mut client = tcp_client(port);
        write!(
            client,
            "CONNECT {target} HTTP/1.1\r\nHost: {target}\r\n\r\n"
        )
        .unwrap();
        read_http_header(&mut client);
        let mut server = accept_upstream(&upstream);
        server
            .set_read_timeout(Some(Duration::from_secs(5)))
            .unwrap();
        server.write_all(b"x").unwrap();
        client.read_exact(&mut [0]).unwrap();
        if reset_client {
            reset_socket(client);
            assert_eq!(server.read(&mut [0]).unwrap(), 0);
        } else {
            reset_socket(server);
            assert_eq!(client.read(&mut [0]).unwrap(), 0);
        }
    }
    assert_transfer_failures(&f, 0);
}

#[test]
fn actual_udp_socket_refusal_remains_a_transport_failure() {
    use std::io::{Read, Write};
    let f = Fixture::new();
    let upstream = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    let closed = upstream.local_addr().unwrap().port();
    fs::write(&f.config, format!("proxies:\n  - name: private-udp\n    type: ss\n    server: 127.0.0.1\n    port: {closed}\n    password: private-password\n    cipher: aes-128-gcm\n    udp: true\nrules: ['MATCH,private-udp']\n")).unwrap();
    let port = start_fixture(&f);
    let mut control = socks_control(port);
    control.write_all(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 0]).unwrap();
    let mut reply = [0; 10];
    control.read_exact(&mut reply).unwrap();
    assert_eq!(&reply[..4], &[5, 0, 0, 1]);
    let relay = std::net::SocketAddrV4::new(
        std::net::Ipv4Addr::new(reply[4], reply[5], reply[6], reply[7]),
        u16::from_be_bytes([reply[8], reply[9]]),
    );
    drop(upstream);
    let socket = std::net::UdpSocket::bind("127.0.0.1:0").unwrap();
    socket
        .send_to(&[0, 0, 0, 1, 127, 0, 0, 1, 0, 53, 1], relay)
        .unwrap();
    assert_eq!(control.read(&mut [0]).unwrap(), 0);
    f.json(&["stop", "--json"]);
    let events = log_events(&f);
    assert!(
        events.iter().any(|e| e["event"] == "connection_failed"
            && e["stage"] == "udp"
            && e["error_kind"] == "ConnectionRefused"),
        "{events:?}"
    );
    let summary = events
        .iter()
        .find(|e| e["event"] == "runtime_summary" && e["phase"] == "final")
        .unwrap();
    assert_eq!(summary["failures"], 1);
    assert_eq!(summary["failures_by_stage"]["udp"], 1);
    assert_eq!(summary["active_connections"], 0);
    assert!(!format!("{events:?}").contains("private-"));
}

#[test]
fn shadowsocks_resets_without_incomplete_incoming_units_are_not_faults() {
    use shadowsocks::{
        config::{ServerConfig, ServerType},
        context::Context,
        crypto::CipherKind,
        relay::tcprelay::proxy_stream::ProxyServerStream,
    };
    use std::io::{Read, Write};
    let f = Fixture::new();
    let upstream = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let address = upstream.local_addr().unwrap();
    fs::write(&f.config, format!("proxies: [{{name: private-ss, type: ss, server: 127.0.0.1, port: {}, password: private-password, cipher: aes-128-gcm}}]\nrules: ['MATCH,private-ss']\n", address.port())).unwrap();
    let port = start_fixture(&f);
    for (respond, reset_client) in [(false, false), (true, false), (true, true)] {
        let mut client = tcp_client(port);
        client
            .write_all(b"CONNECT 127.0.0.1:443 HTTP/1.1\r\nHost: 127.0.0.1:443\r\n\r\n")
            .unwrap();
        read_http_header(&mut client);
        let server = accept_upstream(&upstream);
        let (reset, wait_reset) = std::sync::mpsc::sync_channel(0);
        let peer = std::thread::spawn(move || {
            tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
                .unwrap()
                .block_on(async {
                    use tokio::io::{AsyncReadExt, AsyncWriteExt};
                    server.set_nonblocking(true).unwrap();
                    let socket = tokio::net::TcpStream::from_std(server).unwrap();
                    let config =
                        ServerConfig::new(address, "private-password", CipherKind::AES_128_GCM)
                            .unwrap();
                    let mut stream = ProxyServerStream::from_stream(
                        Context::new_shared(ServerType::Server),
                        socket,
                        config.method(),
                        config.key(),
                    );
                    stream.handshake().await.unwrap();
                    if respond {
                        stream.write_all(b"x").await.unwrap();
                        stream.flush().await.unwrap();
                    }
                    wait_reset.recv_timeout(Duration::from_secs(5)).unwrap();
                    if reset_client {
                        assert_eq!(
                            tokio::time::timeout(Duration::from_secs(5), stream.read(&mut [0]))
                                .await
                                .unwrap()
                                .unwrap(),
                            0
                        );
                    } else {
                        rustix::net::sockopt::set_socket_linger(
                            stream.get_ref(),
                            Some(Duration::ZERO),
                        )
                        .unwrap();
                    }
                });
        });
        if respond {
            client.read_exact(&mut [0]).unwrap();
        }
        if reset_client {
            reset_socket(client);
            reset.send(()).unwrap();
        } else {
            reset.send(()).unwrap();
            assert_eq!(client.read(&mut [0]).unwrap(), 0);
        }
        peer.join().unwrap();
    }
    assert_transfer_failures(&f, 0);
}
