use std::{
    future::Future,
    io,
    net::{IpAddr, SocketAddr},
    pin::Pin,
    sync::{Arc, Mutex, OnceLock},
    task::{Context as TaskContext, Poll},
    time::Duration,
};

use anyhow::{Context, Result, bail};
use tokio::{
    io::{
        AsyncBufRead, AsyncBufReadExt, AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt,
        BufReader, ReadBuf,
    },
    net::{TcpListener, TcpStream, UdpSocket},
    sync::Semaphore,
    task::JoinSet,
    time::{Instant, timeout, timeout_at},
};

use crate::{
    config::{Config, MatchContext, ProxyKind},
    outbound::{BoxStream, Connector},
    target::Target,
    udp::{MAX_WIRE_BYTES, UdpSession},
};

const MAX_CONNECTIONS: usize = 1024;
const MAX_UDP_ASSOCIATIONS: usize = 64;
const UDP_IDLE_TIMEOUT: Duration = Duration::from_secs(300);
const MAX_HEADER: usize = 16 * 1024;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const IDLE_TIMEOUT: Duration = Duration::from_secs(15 * 60);

pub struct Runtime {
    listener: TcpListener,
    context: Arc<ConnectionContext>,
}

struct ConnectionContext {
    config: Arc<Config>,
    connector: Connector,
    udp_permits: Arc<Semaphore>,
    forward_tls: OnceLock<std::result::Result<tokio_rustls::TlsConnector, String>>,
}

impl Runtime {
    pub async fn bind(config: Config, port: u16) -> Result<Self> {
        let connector = Connector::new(&config).context("cannot initialize TCP outbounds")?;
        let address = SocketAddr::new(config.bind_address(), port);
        let listener = TcpListener::bind(address).await
            .with_context(|| format!("cannot bind {address}; check the bind address and whether the port is already in use"))?;
        Ok(Self {
            listener,
            context: Arc::new(ConnectionContext {
                config: Arc::new(config),
                connector,
                udp_permits: Arc::new(Semaphore::new(MAX_UDP_ASSOCIATIONS)),
                forward_tls: OnceLock::new(),
            }),
        })
    }

    pub fn config(&self) -> Arc<Config> {
        self.context.config.clone()
    }

    pub fn local_addr(&self) -> Result<SocketAddr> {
        Ok(self.listener.local_addr()?)
    }

    pub async fn run(self, shutdown: impl Future<Output = ()>) -> Result<()> {
        let permits = Arc::new(Semaphore::new(MAX_CONNECTIONS));
        let mut tasks = JoinSet::new();
        tokio::pin!(shutdown);
        let result = loop {
            tokio::select! {
                biased;
                _ = &mut shutdown => break Ok(()),
                completed = tasks.join_next(), if !tasks.is_empty() => {
                    if let Some(Err(error)) = completed {
                        break Err(anyhow::anyhow!("connection task failed: {error}"));
                    }
                }
                accepted = self.listener.accept(), if tasks.len() < MAX_CONNECTIONS => {
                    let (client, _) = match accepted {
                        Ok(accepted) => accepted,
                        Err(error) => break Err(error).context("cannot accept TCP connection"),
                    };
                    let permit = permits.clone().try_acquire_owned()
                        .expect("task count bounds connection permits");
                    let context = self.context.clone();
                    tasks.spawn(async move {
                        let _permit = permit;
                        // Peer failures are isolated and never logged with request data.
                        let _ = serve(client, context).await;
                    });
                }
            }
        };
        tasks.shutdown().await;
        result
    }
}

async fn http_reply(client: &mut (impl AsyncWrite + Unpin), status: &str) -> Result<()> {
    client
        .write_all(
            format!("HTTP/1.1 {status}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
                .as_bytes(),
        )
        .await?;
    Ok(())
}

fn authority_port(value: &str) -> Result<u16> {
    if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
        bail!("authority port must contain decimal digits");
    }
    Ok(value.parse()?)
}

fn authority(value: &str, default_port: Option<u16>) -> Result<Target> {
    let (host, port) = if let Some(rest) = value.strip_prefix('[') {
        let (host, suffix) = rest.split_once(']').context("invalid IPv6 authority")?;
        host.parse::<std::net::Ipv6Addr>()
            .context("invalid IPv6 address")?;
        (
            host,
            suffix
                .strip_prefix(':')
                .map(authority_port)
                .transpose()?
                .or({
                    if suffix.is_empty() {
                        default_port
                    } else {
                        None
                    }
                })
                .context("missing or invalid port")?,
        )
    } else if let Some((host, port)) = value.split_once(':') {
        (host, authority_port(port)?)
    } else {
        (value, default_port.context("missing port")?)
    };
    Target::new(host, port)
}

struct HttpRequest {
    target: Target,
    forward: Option<Forward>,
}

struct Forward {
    header: Vec<u8>,
    length: u64,
    chunked: bool,
    keep_alive: bool,
    head: bool,
    tls: bool,
}

fn same_target(left: &Target, right: &Target) -> bool {
    if left.port() != right.port() {
        return false;
    }
    match (
        left.host().parse::<std::net::IpAddr>(),
        right.host().parse::<std::net::IpAddr>(),
    ) {
        (Ok(left), Ok(right)) => left == right,
        _ => left.host().eq_ignore_ascii_case(right.host()),
    }
}

fn http_request(request: &httparse::Request<'_, '_>) -> Result<HttpRequest> {
    let method = request.method.context("missing method")?;
    let path = request.path.context("missing request target")?;
    if path
        .bytes()
        .any(|byte| !(0x21..=0x7e).contains(&byte) || byte == b'#' || byte == b'\\')
    {
        bail!("invalid request target");
    }
    let connect = method == "CONNECT";
    let tls = path.starts_with("https://");
    let default_port = if tls { 443 } else { 80 };
    let (target, origin) = if connect {
        (authority(path, None)?, String::new())
    } else if path.starts_with('/') || path == "*" {
        let host = request
            .headers
            .iter()
            .find(|h| h.name.eq_ignore_ascii_case("host"))
            .context("origin-form requires Host")?;
        (
            authority(
                std::str::from_utf8(host.value)?.trim_matches([' ', '\t']),
                Some(80),
            )?,
            path.to_owned(),
        )
    } else {
        let url = path
            .strip_prefix("http://")
            .or_else(|| path.strip_prefix("https://"))
            .context("unsupported URL scheme")?;
        let end = url.find(['/', '?']).unwrap_or(url.len());
        let target = authority(&url[..end], Some(default_port))?;
        let origin = match &url[end..] {
            "" => "/".to_owned(),
            query if query.starts_with('?') => format!("/{query}"),
            path => path.to_owned(),
        };
        (target, origin)
    };
    let mut length = None;
    let mut chunked = false;
    let mut expect_seen = false;
    let mut trailers = false;
    let mut host_seen = false;
    let mut connection = Vec::new();
    for header in request.headers.iter() {
        let name = header.name.to_ascii_lowercase();
        match name.as_str() {
            "transfer-encoding" => {
                if chunked
                    || connect
                    || request.version != Some(1)
                    || !header.value.eq_ignore_ascii_case(b"chunked")
                {
                    bail!("unsupported or duplicate Transfer-Encoding");
                }
                chunked = true;
            }
            "expect" => {
                if expect_seen
                    || connect
                    || request.version != Some(1)
                    || !header.value.eq_ignore_ascii_case(b"100-continue")
                {
                    bail!("unsupported or duplicate Expect");
                }
                expect_seen = true;
            }
            "trailer" => {
                for name in std::str::from_utf8(header.value)?.split(',') {
                    validate_trailer(name.trim_matches([' ', '\t']))?;
                }
                trailers = true;
            }
            "upgrade" => bail!("HTTP upgrade is unsupported"),
            "host" => {
                if host_seen {
                    bail!("duplicate Host");
                }
                host_seen = true;
                let value = std::str::from_utf8(header.value)?.trim_matches([' ', '\t']);
                let host = authority(value, if connect { None } else { Some(default_port) })?;
                if !same_target(&target, &host) {
                    bail!("Host conflicts with request target");
                }
            }
            "content-length" => {
                if length.is_some() {
                    bail!("duplicate Content-Length");
                }
                let value = std::str::from_utf8(header.value)?.trim_matches([' ', '\t']);
                if value.is_empty() || !value.bytes().all(|byte| byte.is_ascii_digit()) {
                    bail!("invalid Content-Length");
                }
                let count: u64 = value.parse()?;
                if count > 16 * 1024 * 1024 || (connect && count != 0) {
                    bail!("unsupported request body length");
                }
                length = Some(count);
            }
            "connection" => {
                for token in std::str::from_utf8(header.value)?.split(',') {
                    let token = token.trim_matches([' ', '\t']).to_ascii_lowercase();
                    if token.is_empty()
                        || !token.bytes().all(|byte| {
                            byte.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&byte)
                        })
                    {
                        bail!("invalid Connection option");
                    }
                    if [
                        "host",
                        "content-length",
                        "transfer-encoding",
                        "upgrade",
                        "expect",
                        "trailer",
                    ]
                    .contains(&token.as_str())
                    {
                        bail!("Connection option conflicts with framing");
                    }
                    connection.push(token);
                }
            }
            _ => {}
        }
    }
    if chunked && length.is_some() {
        bail!("conflicting HTTP body framing");
    }
    if trailers && !chunked {
        bail!("trailers require chunked framing");
    }
    if request.version == Some(1) && !host_seen {
        bail!("HTTP/1.1 requires Host");
    }
    if connect {
        return Ok(HttpRequest {
            target,
            forward: None,
        });
    }
    let host = if target.host().contains(':') {
        format!("[{}]", target.host())
    } else {
        target.host().to_owned()
    };
    let mut header = format!(
        "{method} {origin} HTTP/1.1\r\nHost: {host}:{}\r\n",
        target.port()
    )
    .into_bytes();
    for field in request.headers.iter() {
        let name = field.name.to_ascii_lowercase();
        if [
            "host",
            "content-length",
            "connection",
            "proxy-authorization",
            "proxy-connection",
            "keep-alive",
            "te",
        ]
        .contains(&name.as_str())
            || connection.contains(&name)
        {
            continue;
        }
        header.extend_from_slice(field.name.as_bytes());
        header.extend_from_slice(b": ");
        header.extend_from_slice(field.value);
        header.extend_from_slice(b"\r\n");
    }
    if let Some(length) = length {
        header.extend_from_slice(format!("Content-Length: {length}\r\n").as_bytes());
    }
    header.extend_from_slice(b"Connection: close\r\n\r\n");
    Ok(HttpRequest {
        target,
        forward: Some(Forward {
            header,
            length: length.unwrap_or(0),
            chunked,
            keep_alive: !connection.iter().any(|v| v == "close")
                && (request.version == Some(1) || connection.iter().any(|v| v == "keep-alive")),
            head: method == "HEAD",
            tls,
        }),
    })
}

async fn http_line(reader: &mut (impl AsyncBufRead + Unpin), limit: usize) -> Result<Vec<u8>> {
    let mut line = Vec::new();
    loop {
        let available = reader.fill_buf().await?;
        if available.is_empty() {
            bail!("incomplete HTTP line");
        }
        let count = available
            .iter()
            .position(|&b| b == b'\n')
            .map_or(available.len(), |n| n + 1);
        if line.len() + count > limit {
            bail!("HTTP line exceeds limit");
        }
        line.extend_from_slice(&available[..count]);
        reader.consume(count);
        if line.ends_with(b"\n") {
            if !line.ends_with(b"\r\n") || line[..line.len() - 2].contains(&b'\r') {
                bail!("HTTP requires CRLF");
            }
            return Ok(line);
        }
    }
}

async fn http_header(reader: &mut (impl AsyncBufRead + Unpin)) -> Result<Vec<u8>> {
    let mut bytes = Vec::new();
    loop {
        let line = http_line(reader, MAX_HEADER - bytes.len()).await?;
        let end = line == b"\r\n";
        bytes.extend_from_slice(&line);
        if end {
            return Ok(bytes);
        }
    }
}

async fn http_handshake(client: &mut (impl AsyncBufRead + Unpin)) -> Result<HttpRequest> {
    let bytes = http_header(client).await?;
    let mut headers = [httparse::EMPTY_HEADER; 128];
    let mut request = httparse::Request::new(&mut headers);
    if !request.parse(&bytes)?.is_complete() {
        bail!("incomplete HTTP header");
    }
    let line = format!(
        "{} {} HTTP/1.{}\r\n",
        request.method.context("missing method")?,
        request.path.context("missing target")?,
        request.version.context("missing version")?
    );
    if !bytes.starts_with(line.as_bytes()) {
        bail!("invalid request line");
    }
    http_request(&request)
}

async fn dial(
    context: &ConnectionContext,
    target: &Target,
    source: SocketAddr,
) -> Result<Option<BoxStream>> {
    let route = context
        .config
        .route_with_context(target, &match_context(source))
        .await?;
    if matches!(route.proxy.kind, ProxyKind::Reject) {
        return Ok(None);
    }
    Ok(Some(
        context
            .connector
            .connect(route.proxy, &route.target)
            .await?,
    ))
}

fn socks_connect_error(error: &anyhow::Error) -> u8 {
    let kind = error
        .chain()
        .find_map(|cause| cause.downcast_ref::<io::Error>().map(io::Error::kind));
    match kind {
        Some(io::ErrorKind::PermissionDenied) => 2,
        Some(io::ErrorKind::NetworkUnreachable) => 3,
        Some(io::ErrorKind::HostUnreachable) => 4,
        Some(io::ErrorKind::ConnectionRefused) => 5,
        Some(io::ErrorKind::TimedOut) => 6,
        _ => 1,
    }
}

async fn socks_reply(client: &mut TcpStream, code: u8) -> Result<()> {
    client.write_all(&[5, code, 0, 1, 0, 0, 0, 0, 0, 0]).await?;
    Ok(())
}

enum SocksRequest {
    Connect(Target),
    Associate(SocketAddr),
}

async fn socks_request(client: &mut TcpStream) -> std::result::Result<SocksRequest, u8> {
    let mut head = [0; 4];
    client.read_exact(&mut head).await.map_err(|_| 1)?;
    if head[0] != 5 || head[2] != 0 {
        return Err(1);
    }
    if ![1, 3].contains(&head[1]) {
        return Err(7);
    }
    let host = match head[3] {
        1 => {
            let mut bytes = [0; 4];
            client.read_exact(&mut bytes).await.map_err(|_| 1)?;
            std::net::Ipv4Addr::from(bytes).to_string()
        }
        4 => {
            let mut bytes = [0; 16];
            client.read_exact(&mut bytes).await.map_err(|_| 1)?;
            std::net::Ipv6Addr::from(bytes).to_string()
        }
        3 => {
            let length = client.read_u8().await.map_err(|_| 1)?;
            if length == 0 {
                return Err(8);
            }
            let mut bytes = vec![0; usize::from(length)];
            client.read_exact(&mut bytes).await.map_err(|_| 1)?;
            String::from_utf8(bytes).map_err(|_| 8)?
        }
        _ => return Err(8),
    };
    let port = client.read_u16().await.map_err(|_| 1)?;
    if head[1] == 3 {
        let ip = host.parse::<IpAddr>().map_err(|_| 8)?;
        return Ok(SocksRequest::Associate(SocketAddr::new(ip, port)));
    }
    Target::from_socks(host, port)
        .map(SocksRequest::Connect)
        .map_err(|_| 8)
}

async fn socks_handshake(client: &mut TcpStream) -> Result<Option<SocksRequest>> {
    let version = client.read_u8().await?;
    let count = client.read_u8().await?;
    let mut methods = vec![0; usize::from(count)];
    client.read_exact(&mut methods).await?;
    if version != 5 || !methods.contains(&0) {
        client.write_all(&[5, 255]).await?;
        return Ok(None);
    }
    client.write_all(&[5, 0]).await?;
    match socks_request(client).await {
        Ok(target) => Ok(Some(target)),
        Err(code) => {
            socks_reply(client, code).await?;
            Ok(None)
        }
    }
}

fn match_context(source: SocketAddr) -> MatchContext<'static> {
    MatchContext {
        source_ip: Some(source.ip()),
        source_port: Some(source.port()),
        // The baseline has no process lookup implementation. Unknown is not a match.
        process_name: None,
    }
}

fn udp_request(bytes: &[u8]) -> Result<(Target, &[u8])> {
    if bytes.len() > MAX_WIRE_BYTES || !bytes.starts_with(&[0, 0, 0]) {
        bail!("invalid SOCKS5 UDP header or fragmentation");
    }
    let (host, end) = match bytes.get(3) {
        Some(1) => {
            let ip: [u8; 4] = bytes
                .get(4..8)
                .context("truncated IPv4 address")?
                .try_into()?;
            (std::net::Ipv4Addr::from(ip).to_string(), 8)
        }
        Some(4) => {
            let ip: [u8; 16] = bytes
                .get(4..20)
                .context("truncated IPv6 address")?
                .try_into()?;
            (std::net::Ipv6Addr::from(ip).to_string(), 20)
        }
        Some(3) => {
            let len = usize::from(*bytes.get(4).context("truncated domain length")?);
            let end = 5 + len;
            (
                std::str::from_utf8(bytes.get(5..end).context("truncated domain")?)?.to_owned(),
                end,
            )
        }
        _ => bail!("unsupported UDP address type"),
    };
    let port = u16::from_be_bytes(
        bytes
            .get(end..end + 2)
            .context("truncated port")?
            .try_into()?,
    );
    Ok((Target::from_socks(host, port)?, &bytes[end + 2..]))
}

fn udp_response(source: &Target, payload: &[u8]) -> Result<Vec<u8>> {
    let mut bytes = vec![0, 0, 0];
    crate::outbound::destination(source).write_to_buf(&mut bytes);
    if bytes.len() + payload.len() > MAX_WIRE_BYTES {
        bail!("SOCKS5 UDP response exceeds wire limit");
    }
    bytes.extend_from_slice(payload);
    Ok(bytes)
}

async fn associate(
    mut control: TcpStream,
    context: Arc<ConnectionContext>,
    requested: SocketAddr,
) -> Result<()> {
    if !context.config.proxies().iter().any(|proxy| {
        proxy.udp
            && matches!(
                proxy.kind,
                ProxyKind::Shadowsocks { .. } | ProxyKind::Trojan { .. }
            )
    }) {
        timeout(HANDSHAKE_TIMEOUT, socks_reply(&mut control, 7)).await??;
        return Ok(());
    }
    let source = control.peer_addr()?;
    if !requested.ip().is_unspecified() && requested.ip() != source.ip() {
        timeout(HANDSHAKE_TIMEOUT, socks_reply(&mut control, 2)).await??;
        return Ok(());
    }
    let Ok(_permit) = context.udp_permits.clone().try_acquire_owned() else {
        timeout(HANDSHAKE_TIMEOUT, socks_reply(&mut control, 1)).await??;
        return Ok(());
    };
    let socket = match UdpSocket::bind(SocketAddr::new(control.local_addr()?.ip(), 0)).await {
        Ok(socket) => socket,
        Err(_) => {
            timeout(HANDSHAKE_TIMEOUT, socks_reply(&mut control, 1)).await??;
            return Ok(());
        }
    };
    #[cfg(unix)]
    {
        rustix::net::sockopt::set_socket_send_buffer_size(&socket, 256 * 1024)?;
        rustix::net::sockopt::set_socket_recv_buffer_size(&socket, 256 * 1024)?;
    }
    let bound = socket.local_addr()?;
    let mut reply = vec![5, 0, 0];
    crate::outbound::destination(&Target::new(bound.ip().to_string(), bound.port())?)
        .write_to_buf(&mut reply);
    timeout(HANDSHAKE_TIMEOUT, control.write_all(&reply)).await??;
    let mut byte = [0];
    // Keep cancellation outside the whole relay, including DNS, open and send.
    // Any control bytes (including EOF) terminate this association.
    tokio::select! {
        biased;
        _ = control.read(&mut byte) => Ok(()),
        result = udp_relay(socket, &context, source.ip(), requested.port()) => result,
    }
}

async fn udp_relay(
    socket: UdpSocket,
    context: &ConnectionContext,
    source_ip: IpAddr,
    requested_port: u16,
) -> Result<()> {
    let mut pinned = (requested_port != 0).then_some(SocketAddr::new(source_ip, requested_port));
    let mut storage = vec![0; 65536];
    // One outbound session per association bounds both per-node and total sessions
    // to 64. The selected leaf is immutable for each opened session.
    let mut session: Option<UdpSession> = None;
    let mut deadline = Instant::now() + UDP_IDLE_TIMEOUT;
    loop {
        if Instant::now() >= deadline {
            return Ok(());
        }
        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => return Ok(()),
            received = socket.recv_from(&mut storage) => {
                let (len, sender) = received?;
                if sender.ip() != source_ip || sender.port() == 0 || pinned.is_some_and(|p| p != sender) {
                    continue;
                }
                let Ok((target, payload)) = udp_request(&storage[..len]) else { continue };
                pinned = Some(sender);
                let target = if session.is_none() {
                    let opened = timeout(HANDSHAKE_TIMEOUT, async {
                        let route = context.config.route_with_context(&target, &match_context(sender)).await?;
                        if !route.proxy.udp || !matches!(route.proxy.kind,
                            ProxyKind::Shadowsocks { .. } | ProxyKind::Trojan { .. }) {
                            bail!("selected leaf does not support UDP associations");
                        }
                        let opened = context.connector.open_udp(route.proxy, &route.target).await?;
                        Ok::<_, anyhow::Error>((opened, route.target))
                    }).await;
                    let Ok(Ok((opened, target))) = opened else { return Ok(()) };
                    session = Some(opened);
                    target
                } else {
                    target
                };
                // The first valid datagram fixes the leaf for this association.
                // Packet-local errors (including wire size) must not re-route it.
                let forwarded = timeout(HANDSHAKE_TIMEOUT,
                    session.as_ref().expect("session opened").send_to(payload, &target)
                ).await;
                if matches!(forwarded, Ok(Ok(_))) {
                    deadline = Instant::now() + UDP_IDLE_TIMEOUT;
                }
            }
            received = async {
                match &session {
                    Some(session) => session.recv_from().await,
                    None => std::future::pending().await,
                }
            } => {
                let datagram = match received {
                    Ok(datagram) => datagram,
                    Err(_) => return Ok(()),
                };
                if let Some(client) = pinned {
                    let Ok(response) = udp_response(&datagram.source, &datagram.payload) else { continue };
                    if socket.send_to(&response, client).await.is_ok() {
                        deadline = Instant::now() + UDP_IDLE_TIMEOUT;
                    }
                }
            }
        }
    }
}

async fn serve(mut client: TcpStream, context: Arc<ConnectionContext>) -> Result<()> {
    let source = client.peer_addr()?;
    let deadline = Instant::now() + HANDSHAKE_TIMEOUT;
    let mut first = [0];
    if timeout_at(deadline, client.peek(&mut first)).await?? == 0 {
        return Ok(());
    }
    if first[0] == 5 {
        let Some(request) = timeout_at(deadline, socks_handshake(&mut client)).await?? else {
            return Ok(());
        };
        let target = match request {
            SocksRequest::Connect(target) => target,
            SocksRequest::Associate(requested) => {
                return associate(client, context, requested).await;
            }
        };
        let upstream = match timeout(HANDSHAKE_TIMEOUT, dial(&context, &target, source)).await {
            Ok(Ok(Some(upstream))) => upstream,
            result => {
                let code = match result {
                    Ok(Ok(None)) => 2,
                    Ok(Err(error)) => socks_connect_error(&error),
                    Err(_) => 6,
                    Ok(Ok(Some(_))) => unreachable!("successful dial handled above"),
                };
                timeout(HANDSHAKE_TIMEOUT, socks_reply(&mut client, code)).await??;
                return Ok(());
            }
        };
        timeout(HANDSHAKE_TIMEOUT, socks_reply(&mut client, 0)).await??;
        return transfer(client, upstream, Vec::new()).await;
    }
    let (read_client, mut write_client) = client.into_split();
    let mut client = BufReader::new(read_client);
    for number in 0..1024 {
        let deadline = if number == 0 {
            deadline
        } else {
            Instant::now() + HANDSHAKE_TIMEOUT
        };
        if number != 0 && timeout_at(deadline, client.fill_buf()).await??.is_empty() {
            return Ok(());
        }
        let request = match timeout_at(deadline, http_handshake(&mut client)).await {
            Ok(Ok(request)) => request,
            _ => {
                timeout(
                    HANDSHAKE_TIMEOUT,
                    http_reply(&mut write_client, "400 Bad Request"),
                )
                .await??;
                return Ok(());
            }
        };
        let mut upstream =
            match timeout(HANDSHAKE_TIMEOUT, dial(&context, &request.target, source)).await {
                Ok(Ok(Some(upstream))) => upstream,
                _ => {
                    timeout(
                        HANDSHAKE_TIMEOUT,
                        http_reply(&mut write_client, "502 Bad Gateway"),
                    )
                    .await??;
                    return Ok(());
                }
            };
        let Some(mut forward) = request.forward else {
            timeout(
                HANDSHAKE_TIMEOUT,
                write_client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n"),
            )
            .await??;
            let prefix = client.buffer().to_vec();
            return transfer(client.into_inner().reunite(write_client)?, upstream, prefix).await;
        };
        if forward.tls {
            upstream = match timeout(
                HANDSHAKE_TIMEOUT,
                https_stream(&context, request.target.host(), upstream),
            )
            .await
            {
                Ok(Ok(stream)) => stream,
                _ => {
                    timeout(
                        HANDSHAKE_TIMEOUT,
                        http_reply(&mut write_client, "502 Bad Gateway"),
                    )
                    .await??;
                    return Ok(());
                }
            };
        }
        forward.keep_alive &= number < 1023;
        if !forward_http(&mut client, &mut write_client, upstream, forward).await? {
            return Ok(());
        }
    }
    Ok(())
}

async fn https_stream(
    context: &ConnectionContext,
    host: &str,
    upstream: BoxStream,
) -> Result<BoxStream> {
    let tls = context
        .forward_tls
        .get_or_init(|| {
            let mut roots = rustls::RootCertStore::empty();
            roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
            if roots.is_empty() {
                return Err("no usable system TLS trust roots".to_owned());
            }
            let config = rustls::ClientConfig::builder_with_provider(Arc::new(
                rustls::crypto::aws_lc_rs::default_provider(),
            ))
            .with_safe_default_protocol_versions()
            .map_err(|e| e.to_string())?
            .with_root_certificates(roots)
            .with_no_client_auth();
            Ok(tokio_rustls::TlsConnector::from(Arc::new(config)))
        })
        .as_ref()
        .map_err(|e| anyhow::anyhow!("{e}"))?;
    let name = rustls::pki_types::ServerName::try_from(host.to_owned())?;
    Ok(Box::new(tls.connect(name, upstream).await?))
}

async fn copy_exact(
    reader: &mut (impl AsyncRead + Unpin),
    writer: &mut (impl AsyncWrite + Unpin),
    length: u64,
) -> Result<()> {
    if tokio::io::copy(&mut reader.take(length), writer).await? != length {
        bail!("incomplete HTTP body");
    }
    Ok(())
}

fn validate_trailer(name: &str) -> Result<()> {
    if name.is_empty()
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b"!#$%&'*+-.^_`|~".contains(&b))
    {
        bail!("invalid HTTP trailer name");
    }
    if [
        "host",
        "content-length",
        "transfer-encoding",
        "connection",
        "trailer",
        "authorization",
        "proxy-authorization",
        "upgrade",
        "expect",
        "te",
        "proxy-connection",
        "keep-alive",
    ]
    .iter()
    .any(|forbidden| name.eq_ignore_ascii_case(forbidden))
    {
        bail!("trailer conflicts with routing or framing");
    }
    Ok(())
}

async fn copy_chunked(
    reader: &mut (impl AsyncBufRead + Unpin),
    writer: &mut (impl AsyncWrite + Unpin),
    limit: u64,
) -> Result<()> {
    let mut total = 0u64;
    // Bound framing overhead as well as payload, including zero/one-byte chunks.
    for _ in 0..262144 {
        let line = http_line(reader, 4096).await?;
        if !line[0].is_ascii_hexdigit()
            || line[..line.len() - 2]
                .iter()
                .any(|&b| !(0x20..=0x7e).contains(&b))
        {
            bail!("invalid chunk size line");
        }
        let httparse::Status::Complete((end, size)) =
            httparse::parse_chunk_size(&line).map_err(|_| anyhow::anyhow!("invalid chunk size"))?
        else {
            bail!("incomplete chunk size");
        };
        if end != line.len() {
            bail!("invalid chunk size line");
        }
        total = total.checked_add(size).context("HTTP body size overflow")?;
        if total > limit {
            bail!("HTTP body exceeds limit");
        }
        if size == 0 {
            // Validate all bounded trailers before forwarding the terminal chunk.
            let mut trailers = Vec::new();
            loop {
                let line = http_line(reader, MAX_HEADER - trailers.len()).await?;
                let end = line == b"\r\n";
                trailers.extend_from_slice(&line);
                if end {
                    break;
                }
            }
            let mut headers = [httparse::EMPTY_HEADER; 128];
            let httparse::Status::Complete((_, fields)) =
                httparse::parse_headers(&trailers, &mut headers)?
            else {
                bail!("incomplete HTTP trailers");
            };
            for field in fields {
                validate_trailer(field.name)?;
            }
            writer.write_all(&line).await?;
            writer.write_all(&trailers).await?;
            return Ok(());
        }
        writer.write_all(&line).await?;
        copy_exact(reader, writer, size).await?;
        let mut crlf = [0; 2];
        reader.read_exact(&mut crlf).await?;
        if crlf != *b"\r\n" {
            bail!("invalid chunk delimiter");
        }
        writer.write_all(&crlf).await?;
    }
    bail!("HTTP chunk count exceeds limit")
}

async fn forward_response(
    reader: &mut (impl AsyncBufRead + Unpin),
    writer: &mut (impl AsyncWrite + Unpin),
    forward: &Forward,
) -> Result<bool> {
    for _ in 0..16 {
        let bytes = http_header(reader).await?;
        let mut fields = [httparse::EMPTY_HEADER; 128];
        let mut response = httparse::Response::new(&mut fields);
        if !response.parse(&bytes)?.is_complete() || !bytes.starts_with(b"HTTP/1.") {
            bail!("invalid HTTP response");
        }
        let status = response.code.context("missing HTTP status")?;
        let mut length = None;
        let mut chunked = false;
        let mut connection = Vec::new();
        for field in response.headers.iter() {
            if field.name.eq_ignore_ascii_case("content-length") {
                let text = std::str::from_utf8(field.value)?.trim_matches([' ', '\t']);
                if length.is_some() || text.is_empty() || !text.bytes().all(|b| b.is_ascii_digit())
                {
                    bail!("invalid response Content-Length");
                }
                length = Some(text.parse::<u64>()?);
            } else if field.name.eq_ignore_ascii_case("transfer-encoding") {
                if chunked || !field.value.eq_ignore_ascii_case(b"chunked") {
                    bail!("unsupported response Transfer-Encoding");
                }
                chunked = true;
            } else if field.name.eq_ignore_ascii_case("connection") {
                for token in std::str::from_utf8(field.value)?.split(',') {
                    let token = token.trim().to_ascii_lowercase();
                    if ["content-length", "transfer-encoding"].contains(&token.as_str()) {
                        bail!("response Connection conflicts with framing");
                    }
                    connection.push(token);
                }
            }
        }
        if length.is_some() && chunked {
            bail!("conflicting response framing");
        }
        if status == 101 {
            bail!("HTTP upgrade is unsupported");
        }
        if status < 200 {
            writer.write_all(&bytes).await?;
            continue;
        }
        let empty = forward.head || status == 204 || status == 304;
        let persistent = forward.keep_alive && (empty || length.is_some() || chunked);
        if persistent {
            let line_end = bytes
                .windows(2)
                .position(|b| b == b"\r\n")
                .context("missing response line")?;
            let mut header = bytes[..line_end + 2].to_vec();
            for field in response.headers.iter() {
                let name = field.name.to_ascii_lowercase();
                if ["connection", "keep-alive", "proxy-connection"].contains(&name.as_str())
                    || connection.contains(&name)
                {
                    continue;
                }
                header.extend_from_slice(field.name.as_bytes());
                header.extend_from_slice(b": ");
                header.extend_from_slice(field.value);
                header.extend_from_slice(b"\r\n");
            }
            header.extend_from_slice(b"Connection: keep-alive\r\n\r\n");
            writer.write_all(&header).await?;
        } else {
            writer.write_all(&bytes).await?;
        }
        if !empty {
            if chunked {
                copy_chunked(reader, writer, u64::MAX).await?;
            } else if let Some(length) = length {
                copy_exact(reader, writer, length).await?;
            } else {
                tokio::io::copy(reader, writer).await?;
            }
        }
        writer.flush().await?;
        return Ok(persistent);
    }
    bail!("too many interim HTTP responses")
}

async fn forward_http(
    read_client: &mut BufReader<tokio::net::tcp::OwnedReadHalf>,
    write_client: &mut tokio::net::tcp::OwnedWriteHalf,
    upstream: BoxStream,
    forward: Forward,
) -> Result<bool> {
    let last_activity = Arc::new(Mutex::new(Instant::now()));
    let mut upstream = ActiveIo {
        stream: upstream,
        last_activity: last_activity.clone(),
    };
    let mut read_client = ActiveIo {
        stream: read_client,
        last_activity: last_activity.clone(),
    };
    let mut write_client = ActiveIo {
        stream: write_client,
        last_activity: last_activity.clone(),
    };
    let transfer = async {
        let (read_upstream, mut write_upstream) = tokio::io::split(&mut upstream);
        let mut read_upstream = BufReader::new(read_upstream);
        let upload = async {
            write_upstream.write_all(&forward.header).await?;
            if forward.chunked {
                copy_chunked(&mut read_client, &mut write_upstream, 16 * 1024 * 1024).await?;
            } else {
                copy_exact(&mut read_client, &mut write_upstream, forward.length).await?;
            }
            write_upstream.flush().await?;
            Ok::<_, anyhow::Error>(())
        };
        let download = forward_response(&mut read_upstream, &mut write_client, &forward);
        tokio::pin!(upload, download);
        tokio::select! {
            biased;
            result = &mut upload => {
                result?;
                download.await
            }
            result = &mut download => {
                result?;
                // An early final response cancels the upload. Never reinterpret
                // an unread body as the next keep-alive request.
                Ok(false)
            }
        }
    };
    tokio::select! {
        result = transfer => result,
        _ = idle_expired(last_activity) => bail!("HTTP connection idle for 15 minutes"),
    }
}

// A shared clock measures inactivity in either direction, not connection age.
struct ActiveIo<S> {
    stream: S,
    last_activity: Arc<Mutex<Instant>>,
}

impl<S> ActiveIo<S> {
    fn touch(&self) {
        *self
            .last_activity
            .lock()
            .expect("activity clock is not poisoned") = Instant::now();
    }
}

impl<S: AsyncRead + Unpin> AsyncRead for ActiveIo<S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let before = buffer.filled().len();
        let result = Pin::new(&mut self.stream).poll_read(cx, buffer);
        if matches!(result, Poll::Ready(Ok(()))) && buffer.filled().len() > before {
            self.touch();
        }
        result
    }
}

impl<S: AsyncBufRead + Unpin> AsyncBufRead for ActiveIo<S> {
    fn poll_fill_buf(self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<&[u8]>> {
        Pin::new(&mut self.get_mut().stream).poll_fill_buf(cx)
    }

    fn consume(mut self: Pin<&mut Self>, amount: usize) {
        if amount > 0 {
            self.touch();
        }
        Pin::new(&mut self.stream).consume(amount);
    }
}

impl<S: AsyncWrite + Unpin> AsyncWrite for ActiveIo<S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        bytes: &[u8],
    ) -> Poll<io::Result<usize>> {
        let result = Pin::new(&mut self.stream).poll_write(cx, bytes);
        if matches!(result, Poll::Ready(Ok(count)) if count > 0) {
            self.touch();
        }
        result
    }

    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_flush(cx)
    }

    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.stream).poll_shutdown(cx)
    }
}

async fn idle_expired(last_activity: Arc<Mutex<Instant>>) {
    loop {
        let deadline = *last_activity
            .lock()
            .expect("activity clock is not poisoned")
            + IDLE_TIMEOUT;
        tokio::time::sleep_until(deadline).await;
        if Instant::now().duration_since(
            *last_activity
                .lock()
                .expect("activity clock is not poisoned"),
        ) >= IDLE_TIMEOUT
        {
            return;
        }
    }
}

async fn transfer(client: TcpStream, upstream: BoxStream, prefix: Vec<u8>) -> Result<()> {
    let last_activity = Arc::new(Mutex::new(Instant::now()));
    let mut client = ActiveIo {
        stream: client,
        last_activity: last_activity.clone(),
    };
    let mut upstream = ActiveIo {
        stream: upstream,
        last_activity: last_activity.clone(),
    };
    let transfer = async {
        upstream.write_all(&prefix).await?;
        tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
        Ok(())
    };
    tokio::select! {
        result = transfer => result,
        _ = idle_expired(last_activity) => bail!("TCP connection idle for 15 minutes"),
    }
}
