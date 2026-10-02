// Test-only independent SS UDP services and SOCKS probes. Crypto is delegated
// exclusively to Node/OpenSSL, not shadowsocks or any zc production module.
use anyhow::{Context, Result, bail, ensure};
use base64::{Engine, engine::general_purpose::STANDARD};
use serde_json::{Value, json};
use std::cell::RefCell;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr};
use std::process::Stdio;
use std::time::Duration;
use tokio::io::{AsyncBufReadExt, AsyncReadExt, AsyncWriteExt, BufReader};
use tokio::net::{TcpStream, UdpSocket};
use tokio::process::{Child, ChildStdin, ChildStdout, Command};
use tokio::time::{Instant, timeout, timeout_at};

const MAX: usize = 65507;
const ABSENCE: Duration = Duration::from_millis(350);

// Diagnostic-only: observe the existing helper without changing deadlines or I/O.
tokio::task_local! {
    static PROBE_TRACE: RefCell<ProbeTrace>;
}
struct ProbeTrace {
    started: Instant,
    stage: &'static str,
    tx_packets: usize,
    rx_packets: usize,
    enabled: bool,
}
impl ProbeTrace {
    fn summary(&self) -> String {
        format!(
            "protocol=socks5-udp stage={} tx_packets={} rx_packets={} elapsed_ms={}",
            self.stage,
            self.tx_packets,
            self.rx_packets,
            self.started.elapsed().as_millis()
        )
    }
}
fn stage(name: &'static str) {
    let _ = PROBE_TRACE.try_with(|trace| {
        let mut trace = trace.borrow_mut();
        trace.stage = name;
        if trace.enabled {
            eprintln!("[DEBUG-udp-probe] {}", trace.summary());
        }
    });
}
fn packet_metric(sent: bool, peer: SocketAddr, bytes: &[u8]) {
    let _ = PROBE_TRACE.try_with(|trace| {
        let mut trace = trace.borrow_mut();
        if sent {
            trace.tx_packets += 1;
        } else {
            trace.rx_packets += 1;
        }
        if trace.enabled {
            eprintln!(
                "[DEBUG-udp-probe] {} direction={} peer={} bytes={} atyp={:?}",
                trace.summary(),
                if sent { "send" } else { "receive" },
                peer,
                bytes.len(),
                bytes.get(3)
            );
        }
    });
}

struct Crypto {
    _child: Child,
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    cipher: String,
    password: String,
}
impl Crypto {
    async fn new(cipher: &str, password: &str) -> Result<Self> {
        salt_len(cipher)?;
        let mut child = Command::new("node")
            .args([
                "--input-type=module",
                "-e",
                include_str!("support/ss-crypto.mjs"),
            ])
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true)
            .spawn()?;
        let input = child.stdin.take().unwrap();
        let mut output = BufReader::new(child.stdout.take().unwrap());
        let mut ready = String::new();
        timeout(Duration::from_secs(5), output.read_line(&mut ready)).await??;
        ensure!(ready == "READY\n", "IndependentCryptoSelftestFailed");
        Ok(Self {
            _child: child,
            input,
            output,
            cipher: cipher.to_owned(),
            password: password.to_owned(),
        })
    }
    async fn transform(&mut self, op: &str, bytes: &[u8]) -> Result<Option<Vec<u8>>> {
        let request = json!({"op":op,"cipher":self.cipher,"password":self.password,"input":STANDARD.encode(bytes)});
        timeout(Duration::from_secs(2), async {
            self.input
                .write_all(format!("{request}\n").as_bytes())
                .await?;
            let mut line = String::new();
            ensure!(
                self.output.read_line(&mut line).await? > 0,
                "CryptoWorkerExited"
            );
            let result: Value = serde_json::from_str(&line)?;
            if let Some(e) = result["error"].as_str() {
                if op == "open" && matches!(e, "AuthenticationFailed" | "InvalidPacket") {
                    return Ok(None);
                }
                bail!("CryptoWorker: {e}");
            }
            Ok(Some(
                STANDARD.decode(
                    result["output"]
                        .as_str()
                        .ok_or_else(|| anyhow::anyhow!("InvalidCryptoResponse"))?,
                )?,
            ))
        })
        .await?
    }
}

fn salt_len(cipher: &str) -> Result<usize> {
    match cipher {
        "aes-128-gcm" => Ok(16),
        "aes-256-gcm" | "chacha20-ietf-poly1305" => Ok(32),
        _ => bail!("InvalidCipher"),
    }
}
fn port(text: &str, zero: bool) -> Result<u16> {
    ensure!(
        !text.is_empty() && text.len() <= 5 && text.bytes().all(|b| b.is_ascii_digit()),
        "InvalidPort"
    );
    let p = text.parse()?;
    ensure!((zero || p != 0) && p != 7899, "InvalidPort");
    Ok(p)
}
fn valid_id(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 32
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let a: Vec<_> = std::env::args().skip(1).collect();
    ensure!(!a.is_empty(), "InvalidArguments");
    match a[0].as_str() {
        "selftest" => {
            ensure!(a.len() == 1, "InvalidArguments");
            let _crypto = Crypto::new("aes-128-gcm", "password").await?;
            println!("E2E_SS_UDP_SELFTEST=PASS");
        }
        "serve" => {
            ensure!(a.len() == 5 || a.len() == 6, "InvalidArguments");
            ensure!(
                !a[2].is_empty() && a[2].len() <= 1024 && valid_id(&a[4]),
                "InvalidArguments"
            );
            ensure!(
                matches!(
                    a[3].as_str(),
                    "normal" | "bad-tag-once" | "truncated-salt-once" | "truncated-tag-once"
                ),
                "InvalidArguments"
            );
            let p = if a.len() == 6 { port(&a[5], true)? } else { 0 };
            timeout(
                Duration::from_secs(180),
                serve(&a[1], &a[2], &a[3], &a[4], p),
            )
            .await??;
        }
        "echo" => {
            ensure!(a.len() == 2 || a.len() == 3, "InvalidArguments");
            let p = if a.len() == 3 { port(&a[2], true)? } else { 0 };
            timeout(Duration::from_secs(180), echo(&a[1], p)).await??;
        }
        "health" => {
            ensure!(a.len() == 3 && valid_id(&a[2]), "InvalidArguments");
            let p = port(&a[1], false)?;
            timeout(Duration::from_millis(500), async {
                let socket = udp("127.0.0.1:0".parse()?).await?;
                let peer: SocketAddr = ([127, 0, 0, 1], p).into();
                send(
                    &socket,
                    format!("ZC_E2E_UDP_HEALTH:{}", a[2]).as_bytes(),
                    peer,
                )
                .await?;
                let (bytes, sender) = receive(&socket).await?;
                ensure!(
                    sender == peer && bytes == format!("ZC_E2E_UDP_READY:{}", a[2]).as_bytes(),
                    "InvalidHealthResponse"
                );
                Ok::<_, anyhow::Error>(())
            })
            .await??;
            println!("E2E_SS_UDP_HEALTH_PASS={}", a[2]);
        }
        "probe" => {
            let trace = RefCell::new(ProbeTrace {
                started: Instant::now(),
                stage: "arguments",
                tx_packets: 0,
                rx_packets: 0,
                enabled: std::env::var_os("ZC_E2E_UDP_DIAGNOSTIC").as_deref()
                    == Some(std::ffi::OsStr::new("1")),
            });
            PROBE_TRACE
                .scope(trace, async {
                    let result = timeout(Duration::from_secs(5), probe(&a[1..])).await;
                    let context = format!(
                        "[DEBUG-udp-probe] probe={} {}",
                        a.get(1).map(String::as_str).unwrap_or("missing"),
                        PROBE_TRACE.with(|trace| trace.borrow().summary())
                    );
                    result.context(context.clone())?.context(context)?;
                    stage("complete");
                    Ok::<_, anyhow::Error>(())
                })
                .await?;
            println!("E2E_SS_UDP_PROBE_PASS={}", a[1]);
        }
        _ => bail!("InvalidArguments"),
    }
    Ok(())
}

async fn udp(address: SocketAddr) -> Result<UdpSocket> {
    stage("udp-bind");
    let socket = UdpSocket::bind(address).await?;
    rustix::net::sockopt::set_socket_send_buffer_size(&socket, MAX)?;
    rustix::net::sockopt::set_socket_recv_buffer_size(&socket, 262144)?;
    ensure!(
        rustix::net::sockopt::socket_send_buffer_size(&socket)? >= MAX
            && rustix::net::sockopt::socket_recv_buffer_size(&socket)? >= 65536,
        "SocketBufferTooSmall"
    );
    Ok(socket)
}
async fn receive(socket: &UdpSocket) -> Result<(Vec<u8>, SocketAddr)> {
    stage("udp-receive");
    let mut buffer = vec![0; 65536];
    let (n, peer) = socket.recv_from(&mut buffer).await?;
    buffer.truncate(n);
    packet_metric(false, peer, &buffer);
    Ok((buffer, peer))
}
async fn send(socket: &UdpSocket, bytes: &[u8], peer: SocketAddr) -> Result<()> {
    stage("udp-send");
    ensure!(bytes.len() <= MAX, "DatagramTooLarge");
    ensure!(
        socket.send_to(bytes, peer).await? == bytes.len(),
        "PartialDatagram"
    );
    packet_metric(true, peer, bytes);
    Ok(())
}
fn address_len(bytes: &[u8]) -> Result<usize> {
    let n = match bytes.first() {
        Some(1) => 7,
        Some(4) => 19,
        Some(3) => {
            let n = *bytes
                .get(1)
                .ok_or_else(|| anyhow::anyhow!("TruncatedAddress"))? as usize;
            ensure!(n > 0, "InvalidDomainLength");
            n + 4
        }
        _ => bail!("InvalidAddressType"),
    };
    ensure!(bytes.len() >= n, "TruncatedAddress");
    Ok(n)
}
async fn serve(cipher: &str, password: &str, mode: &str, id: &str, port: u16) -> Result<()> {
    let mut crypto = Crypto::new(cipher, password).await?;
    let socket = udp(([127, 0, 0, 1], port).into()).await?;
    println!(
        "E2E_SS_UDP_ORACLE_READY={id}:{}",
        socket.local_addr()?.port()
    );
    let mut raw = 0;
    let mut pending = mode;
    for _ in 0..4096 {
        let (bytes, peer) = receive(&socket).await?;
        if let Some(nonce) = bytes.strip_prefix(b"ZC_E2E_UDP_HEALTH:") {
            if let Ok(nonce) = std::str::from_utf8(nonce)
                && valid_id(nonce)
            {
                send(
                    &socket,
                    format!("ZC_E2E_UDP_READY:{nonce}").as_bytes(),
                    peer,
                )
                .await?;
            }
            continue;
        }
        raw += 1;
        println!("E2E_SS_UDP_ORACLE_RAW={id}:{raw}");
        if bytes.len() > MAX {
            continue;
        }
        let Some(plaintext) = crypto.transform("open", &bytes).await? else {
            continue;
        };
        if address_len(&plaintext).is_err() {
            continue;
        }
        println!("E2E_SS_UDP_ORACLE_VERIFIED={id}:{raw}");
        let mut response = crypto
            .transform("seal", &plaintext)
            .await?
            .ok_or_else(|| anyhow::anyhow!("MissingCiphertext"))?;
        let kind = match pending {
            "bad-tag-once" => {
                *response.last_mut().unwrap() ^= 1;
                "BAD_TAG"
            }
            "truncated-salt-once" => {
                response.truncate(salt_len(cipher)? - 1);
                "TRUNCATED_SALT"
            }
            "truncated-tag-once" => {
                response.pop();
                "TRUNCATED_TAG"
            }
            _ => "NORMAL",
        };
        send(&socket, &response, peer).await?;
        pending = "normal";
        println!("E2E_SS_UDP_ORACLE_RESPONSE={id}:{raw}:{kind}");
    }
    Ok(())
}
async fn echo(family: &str, port: u16) -> Result<()> {
    let address = match family {
        "ipv4" => SocketAddr::from(([127, 0, 0, 1], port)),
        "ipv6" => SocketAddr::from((Ipv6Addr::LOCALHOST, port)),
        _ => bail!("InvalidArguments"),
    };
    let socket = udp(address).await?;
    println!(
        "E2E_UDP_ECHO_READY={family}:{}",
        socket.local_addr()?.port()
    );
    let mut count = 0;
    for _ in 0..4096 {
        let (bytes, peer) = receive(&socket).await?;
        if bytes.len() > MAX {
            continue;
        }
        if std::env::var_os("ZC_E2E_UDP_DIAGNOSTIC").as_deref() == Some(std::ffi::OsStr::new("1")) {
            eprintln!(
                "[DEBUG-udp-echo] stage=received family={family} peer={peer} bytes={}",
                bytes.len()
            );
        }
        send(&socket, &bytes, peer).await?;
        if std::env::var_os("ZC_E2E_UDP_DIAGNOSTIC").as_deref() == Some(std::ffi::OsStr::new("1")) {
            eprintln!(
                "[DEBUG-udp-echo] stage=sent family={family} peer={peer} bytes={}",
                bytes.len()
            );
        }
        count += 1;
        println!("E2E_UDP_ECHO_PACKET={family}:{count}");
    }
    Ok(())
}

struct Association {
    control: TcpStream,
    relay: SocketAddr,
    rep: u8,
}
async fn associate(port: u16, required: bool) -> Result<Association> {
    stage("tcp-connect");
    let mut control = TcpStream::connect(("127.0.0.1", port)).await?;
    stage("greeting-send");
    control.write_all(&[5, 1, 0]).await?;
    let mut greeting = [0; 2];
    stage("greeting-receive");
    control.read_exact(&mut greeting).await?;
    stage("greeting-validate");
    ensure!(greeting == [5, 0], "InvalidGreetingReply");
    stage("associate-send");
    control.write_all(&[5, 3, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
    let mut reply = [0; 10];
    stage("associate-receive");
    control.read_exact(&mut reply).await?;
    stage("associate-validate");
    ensure!(
        reply[0] == 5 && reply[2] == 0 && reply[3] == 1,
        "InvalidAssociateReply"
    );
    let relay = SocketAddr::from((
        [reply[4], reply[5], reply[6], reply[7]],
        u16::from_be_bytes([reply[8], reply[9]]),
    ));
    if reply[1] == 0 {
        ensure!(
            relay.ip() == IpAddr::V4(Ipv4Addr::LOCALHOST) && relay.port() != 0,
            "NonLoopbackRelay"
        );
    }
    if required {
        ensure!(reply[1] == 0, "AssociateRejected: {}", reply[1]);
    }
    Ok(Association {
        control,
        relay,
        rep: reply[1],
    })
}
async fn eof(stream: &mut TcpStream) -> Result<()> {
    stage("control-eof");
    match stream.read(&mut [0]).await {
        Ok(0) => Ok(()),
        Err(e) if e.kind() == std::io::ErrorKind::ConnectionReset => Ok(()),
        Ok(_) => bail!("UnexpectedControlData"),
        Err(e) => Err(e.into()),
    }
}
async fn teardown(a: &mut Association) -> Result<()> {
    stage("control-shutdown");
    a.control.shutdown().await?;
    eof(&mut a.control).await
}
fn address(kind: &str, port: u16) -> Result<Vec<u8>> {
    let mut b = match kind {
        "ipv4" => vec![1, 127, 0, 0, 1],
        "ipv6" => {
            let mut b = vec![4];
            b.extend_from_slice(&Ipv6Addr::LOCALHOST.octets());
            b
        }
        "domain" => {
            let mut b = vec![3, 9];
            b.extend_from_slice(b"localhost");
            b
        }
        "max" => {
            let mut b = vec![3, 255];
            b.extend_from_slice(&[b'a'; 255]);
            b
        }
        _ => bail!("InvalidAddressKind"),
    };
    b.extend_from_slice(&port.to_be_bytes());
    Ok(b)
}
fn packet(addr: &[u8], payload: &[u8]) -> Result<Vec<u8>> {
    let mut b = vec![0; 3];
    b.extend_from_slice(addr);
    b.extend_from_slice(payload);
    ensure!(b.len() <= MAX, "DatagramTooLarge");
    Ok(b)
}
async fn exchange(
    socket: &UdpSocket,
    relay: SocketAddr,
    addr: &[u8],
    payload: &[u8],
    domain_resolved: bool,
) -> Result<()> {
    send(socket, &packet(addr, payload)?, relay).await?;
    let (bytes, peer) = receive(socket).await?;
    stage("response-sender");
    ensure!(peer == relay, "UnexpectedResponseSender");
    stage("response-header");
    ensure!(
        bytes.len() <= MAX && bytes.starts_with(&[0, 0, 0]),
        "InvalidSocksDatagram"
    );
    stage("response-address");
    let n = address_len(&bytes[3..])?;
    let actual = &bytes[3..3 + n];
    let port = u16::from_be_bytes([addr[addr.len() - 2], addr[addr.len() - 1]]);
    if domain_resolved {
        ensure!(
            actual == address("ipv4", port)?
                || actual == address("ipv6", port)?
                || actual.eq_ignore_ascii_case(&address("domain", port)?),
            "UnexpectedResponseAddress"
        );
    } else {
        ensure!(actual == addr, "UnexpectedResponseAddress");
    }
    stage("response-payload");
    ensure!(&bytes[3 + n..] == payload, "UnexpectedResponsePayload");
    Ok(())
}
async fn absent(sockets: &[&UdpSocket]) -> Result<()> {
    stage("absence-check");
    let deadline = Instant::now() + ABSENCE;
    let mut bytes = [0; 65536];
    loop {
        for socket in sockets {
            match socket.try_recv_from(&mut bytes) {
                Ok((n, peer)) => {
                    packet_metric(false, peer, &bytes[..n]);
                    bail!("UnexpectedUdpResponse");
                }
                Err(e)
                    if matches!(
                        e.kind(),
                        std::io::ErrorKind::WouldBlock
                            | std::io::ErrorKind::ConnectionRefused
                            | std::io::ErrorKind::ConnectionReset
                    ) => {}
                Err(e) => return Err(e.into()),
            }
        }
        if Instant::now() >= deadline {
            return Ok(());
        }
        tokio::time::sleep(Duration::from_millis(2)).await;
    }
}
async fn probe(a: &[String]) -> Result<()> {
    ensure!(a.len() >= 2, "InvalidArguments");
    let kind = a[0].as_str();
    let extra = matches!(kind, "invalid-then-valid" | "max");
    ensure!(!extra || a.len() == 5, "InvalidArguments");
    let mixed = port(&a[if extra { 2 } else { 1 }], false)?;
    if kind == "capacity" {
        ensure!(a.len() == 2, "InvalidArguments");
        let mut controls = Vec::new();
        for _ in 0..64 {
            controls.push(associate(mixed, true).await?);
        }
        let rejected = associate(mixed, false).await?;
        ensure!(rejected.rep == 1, "UnexpectedCapacityReply");
        teardown(&mut controls[0]).await?;
        for _ in 0..4096 {
            let candidate = associate(mixed, false).await?;
            if candidate.rep == 0 {
                return Ok(());
            }
            ensure!(candidate.rep == 1, "UnexpectedCapacityReply");
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        bail!("CapacitySlotNotReleased");
    }
    if kind == "associate-rejected" {
        ensure!(a.len() == 3, "InvalidArguments");
        let result = associate(mixed, false).await?;
        ensure!(
            result.rep != 0 && result.rep == a[2].parse::<u8>()?,
            "UnexpectedAssociateReply"
        );
        return Ok(());
    }
    ensure!(a.len() == if extra { 5 } else { 4 }, "InvalidArguments");
    let target = port(&a[if extra { 3 } else { 2 }], false)?;
    let nonce = a.last().unwrap();
    ensure!(!nonce.is_empty() && nonce.len() <= 1024, "InvalidArguments");
    let mut association = associate(mixed, true).await?;
    let relay = association.relay;
    let socket = udp(([127, 0, 0, 1], 0).into()).await?;
    let addr = address("ipv4", target)?;
    match kind {
        "roundtrip" => exchange(&socket, relay, &addr, nonce.as_bytes(), false).await?,
        "roundtrip-domain" => {
            exchange(
                &socket,
                relay,
                &address("domain", target)?,
                nonce.as_bytes(),
                true,
            )
            .await?
        }
        "roundtrip-ipv6" => {
            exchange(
                &socket,
                relay,
                &address("ipv6", target)?,
                nonce.as_bytes(),
                false,
            )
            .await?
        }
        "trojan-multi" => {
            exchange(&socket, relay, &addr, nonce.as_bytes(), false).await?;
            exchange(
                &socket,
                relay,
                &address("domain", target)?,
                nonce.as_bytes(),
                true,
            )
            .await?;
        }
        "response-drop-recovery" | "invalid-then-valid" => {
            let suffix = if extra { "-invalid" } else { "-first" };
            let mut b = packet(&addr, format!("{nonce}{suffix}").as_bytes())?;
            if extra {
                match a[1].as_str() {
                    "rsv1" => b[0] = 1,
                    "rsv2" => b[1] = 1,
                    "frag" => b[2] = 1,
                    "atyp" => b[3] = 2,
                    "truncated" => b.truncate(5),
                    _ => bail!("InvalidArguments"),
                }
            }
            send(&socket, &b, relay).await?;
            absent(&[&socket]).await?;
            exchange(&socket, relay, &addr, nonce.as_bytes(), false).await?;
        }
        "source-pin" => {
            let second = udp(([127, 0, 0, 1], 0).into()).await?;
            let mut b = packet(&addr, format!("{nonce}-invalid").as_bytes())?;
            b[0] = 1;
            send(&socket, &b, relay).await?;
            absent(&[&socket, &second]).await?;
            exchange(
                &second,
                relay,
                &addr,
                format!("{nonce}-pinned").as_bytes(),
                false,
            )
            .await?;
            send(
                &socket,
                &packet(&addr, format!("{nonce}-wrong-source").as_bytes())?,
                relay,
            )
            .await?;
            absent(&[&socket, &second]).await?;
            exchange(&second, relay, &addr, nonce.as_bytes(), false).await?;
        }
        "client-ip" => {
            let discovery = UdpSocket::bind("0.0.0.0:0").await?;
            discovery.connect("192.0.2.1:9").await?;
            let ip = discovery.local_addr()?.ip();
            ensure!(
                !ip.is_loopback() && !ip.is_unspecified(),
                "NonLoopbackAddressUnavailable"
            );
            let wrong = udp(SocketAddr::new(ip, 0)).await?;
            send(&wrong, &packet(&addr, nonce.as_bytes())?, relay).await?;
            absent(&[&wrong, &socket]).await?;
            exchange(&socket, relay, &addr, nonce.as_bytes(), false).await?;
        }
        "control-close" => {
            exchange(
                &socket,
                relay,
                &addr,
                format!("{nonce}-before-close").as_bytes(),
                false,
            )
            .await?;
            teardown(&mut association).await?;
            send(
                &socket,
                &packet(&addr, format!("{nonce}-closed").as_bytes())?,
                relay,
            )
            .await?;
            absent(&[&socket]).await?;
            let recovery = associate(mixed, true).await?;
            let fresh = udp(([127, 0, 0, 1], 0).into()).await?;
            exchange(&fresh, recovery.relay, &addr, nonce.as_bytes(), false).await?;
        }
        "selection-teardown" => {
            send(&socket, &packet(&addr, nonce.as_bytes())?, relay).await?;
            timeout_at(
                Instant::now() + Duration::from_secs(1),
                eof(&mut association.control),
            )
            .await??;
            absent(&[&socket]).await?;
        }
        "max" => {
            let len = MAX - salt_len(&a[1])? - 16 - 259;
            let pattern: Vec<u8> = nonce.bytes().cycle().take(len + 1).collect();
            let addr = address("max", target)?;
            exchange(&socket, relay, &addr, &pattern[..len], false).await?;
            send(&socket, &packet(&addr, &pattern)?, relay).await?;
            absent(&[&socket]).await?;
            exchange(&socket, relay, &addr, nonce.as_bytes(), false).await?;
        }
        _ => bail!("InvalidArguments"),
    }
    Ok(())
}
