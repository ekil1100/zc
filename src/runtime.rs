use std::{
    future::Future,
    io,
    net::SocketAddr,
    pin::Pin,
    sync::{Arc, Mutex},
    task::{Context as TaskContext, Poll},
    time::Duration,
};

use anyhow::{Context, Result, bail};
use tokio::{
    io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, ReadBuf},
    net::{TcpListener, TcpStream},
    sync::Semaphore,
    task::JoinSet,
    time::{Instant, timeout, timeout_at},
};

use crate::{
    config::{Config, ProxyKind},
    outbound::{BoxStream, Connector},
    target::Target,
};

const MAX_CONNECTIONS: usize = 1024;
const MAX_HEADER: usize = 16 * 1024;
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(10);
const IDLE_TIMEOUT: Duration = Duration::from_secs(15 * 60);

pub struct Runtime {
    listener: TcpListener,
    context: Arc<ConnectionContext>,
}

struct ConnectionContext {
    config: Config,
    connector: Connector,
}

impl Runtime {
    pub async fn bind(config: Config, port: u16) -> Result<Self> {
        let connector = Connector::new(&config).context("cannot initialize TCP outbounds")?;
        let address = SocketAddr::new(config.bind_address(), port);
        let listener = TcpListener::bind(address).await
            .with_context(|| format!("cannot bind {address}; check the bind address and whether the port is already in use"))?;
        Ok(Self {
            listener,
            context: Arc::new(ConnectionContext { config, connector }),
        })
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

async fn http_reply(client: &mut TcpStream, status: &str) -> Result<()> {
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
    prefix: Vec<u8>,
    forward: Option<Forward>,
}

struct Forward {
    header: Vec<u8>,
    length: u64,
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

fn http_request(request: &httparse::Request<'_, '_>, prefix: Vec<u8>) -> Result<HttpRequest> {
    let method = request.method.context("missing method")?;
    let path = request.path.context("missing request target")?;
    if path
        .bytes()
        .any(|byte| !(0x21..=0x7e).contains(&byte) || byte == b'#' || byte == b'\\')
    {
        bail!("invalid request target");
    }
    let connect = method == "CONNECT";
    let (target, origin) = if connect {
        (authority(path, None)?, String::new())
    } else {
        let url = path
            .strip_prefix("http://")
            .context("use an http:// URL or CONNECT for HTTPS")?;
        let end = url.find(['/', '?']).unwrap_or(url.len());
        let target = authority(&url[..end], Some(80))?;
        let origin = match &url[end..] {
            "" => "/".to_owned(),
            query if query.starts_with('?') => format!("/{query}"),
            path => path.to_owned(),
        };
        (target, origin)
    };
    let mut length = None;
    let mut host_seen = false;
    let mut connection = Vec::new();
    for header in request.headers.iter() {
        let name = header.name.to_ascii_lowercase();
        match name.as_str() {
            "transfer-encoding" | "upgrade" | "expect" | "trailer" => {
                bail!("unsupported HTTP framing or upgrade")
            }
            "host" => {
                if host_seen {
                    bail!("duplicate Host");
                }
                host_seen = true;
                let value = std::str::from_utf8(header.value)?.trim_matches([' ', '\t']);
                let host = authority(value, if connect { None } else { Some(80) })?;
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
    if request.version == Some(1) && !host_seen {
        bail!("HTTP/1.1 requires Host");
    }
    if connect {
        return Ok(HttpRequest {
            target,
            prefix,
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
        prefix,
        forward: Some(Forward {
            header,
            length: length.unwrap_or(0),
        }),
    })
}

async fn http_handshake(client: &mut TcpStream) -> Result<HttpRequest> {
    let mut bytes = Vec::new();
    loop {
        let mut headers = [httparse::EMPTY_HEADER; 128];
        let mut request = httparse::Request::new(&mut headers);
        if let httparse::Status::Complete(end) = request.parse(&bytes)? {
            // httparse accepts bare LF and leading empty lines; reject ambiguous wire forms.
            for (index, byte) in bytes[..end].iter().enumerate() {
                if (*byte == b'\n' && (index == 0 || bytes[index - 1] != b'\r'))
                    || (*byte == b'\r' && bytes.get(index + 1) != Some(&b'\n'))
                {
                    bail!("HTTP requires CRLF");
                }
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
            return http_request(&request, bytes[end..].to_vec());
        }
        if bytes.len() == MAX_HEADER {
            bail!("HTTP header exceeds 16 KiB");
        }
        let mut chunk = [0; 4096];
        let available = chunk.len().min(MAX_HEADER - bytes.len());
        let count = client.read(&mut chunk[..available]).await?;
        if count == 0 {
            bail!("incomplete HTTP header");
        }
        bytes.extend_from_slice(&chunk[..count]);
    }
}

async fn dial(context: &ConnectionContext, target: &Target) -> Result<Option<BoxStream>> {
    let route = context.config.route(target).await?;
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

async fn socks_request(client: &mut TcpStream) -> std::result::Result<Target, u8> {
    let mut head = [0; 4];
    client.read_exact(&mut head).await.map_err(|_| 1)?;
    if head[0] != 5 || head[2] != 0 {
        return Err(1);
    }
    if head[1] != 1 {
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
    Target::new(host, port).map_err(|_| 8)
}

async fn socks_handshake(client: &mut TcpStream) -> Result<Option<Target>> {
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

async fn serve(mut client: TcpStream, context: Arc<ConnectionContext>) -> Result<()> {
    let deadline = Instant::now() + HANDSHAKE_TIMEOUT;
    let mut first = [0];
    if timeout_at(deadline, client.peek(&mut first)).await?? == 0 {
        return Ok(());
    }
    if first[0] == 5 {
        let Some(target) = timeout_at(deadline, socks_handshake(&mut client)).await?? else {
            return Ok(());
        };
        let upstream = match timeout(HANDSHAKE_TIMEOUT, dial(&context, &target)).await {
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
        return transfer(client, upstream, Vec::new(), None).await;
    }
    let request = match timeout_at(deadline, http_handshake(&mut client)).await {
        Ok(Ok(request)) => request,
        _ => {
            timeout(
                HANDSHAKE_TIMEOUT,
                http_reply(&mut client, "400 Bad Request"),
            )
            .await??;
            return Ok(());
        }
    };
    let upstream = match timeout(HANDSHAKE_TIMEOUT, dial(&context, &request.target)).await {
        Ok(Ok(Some(upstream))) => upstream,
        result => {
            let status = if matches!(result, Ok(Ok(None))) {
                "403 Forbidden"
            } else {
                "502 Bad Gateway"
            };
            timeout(HANDSHAKE_TIMEOUT, http_reply(&mut client, status)).await??;
            return Ok(());
        }
    };
    if request.forward.is_none() {
        timeout(
            HANDSHAKE_TIMEOUT,
            client.write_all(b"HTTP/1.1 200 Connection Established\r\n\r\n"),
        )
        .await??;
    }
    transfer(client, upstream, request.prefix, request.forward).await
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

async fn transfer(
    client: TcpStream,
    upstream: BoxStream,
    prefix: Vec<u8>,
    forward: Option<Forward>,
) -> Result<()> {
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
        if let Some(forward) = forward {
            let (read_client, mut write_client) = tokio::io::split(&mut client);
            let (mut read_upstream, mut write_upstream) = tokio::io::split(&mut upstream);
            let upload = async {
                write_upstream.write_all(&forward.header).await?;
                let count = prefix.len().min(forward.length as usize);
                write_upstream.write_all(&prefix[..count]).await?;
                let remaining = forward.length - count as u64;
                let copied =
                    tokio::io::copy(&mut read_client.take(remaining), &mut write_upstream).await?;
                if copied != remaining {
                    bail!("incomplete HTTP request body");
                }
                // Content-Length delimits the request. An early FIN/close_notify makes
                // trojan-go close both directions before the HTTP response arrives.
                // Connection: close asks the HTTP peer to end the response instead.
                write_upstream.flush().await?;
                Ok::<_, anyhow::Error>(())
            };
            let download = async {
                tokio::io::copy(&mut read_upstream, &mut write_client).await?;
                write_client.shutdown().await?;
                Ok::<_, anyhow::Error>(())
            };
            tokio::try_join!(upload, download)?;
        } else {
            upstream.write_all(&prefix).await?;
            tokio::io::copy_bidirectional(&mut client, &mut upstream).await?;
        }
        Ok(())
    };
    tokio::select! {
        result = transfer => result,
        _ = idle_expired(last_activity) => bail!("TCP connection idle for 15 minutes"),
    }
}
