use crate::{
    dns::Dns,
    outbound::{BoxStream, destination},
    target::Target,
};
use anyhow::{Context, Result, bail};
use shadowsocks::{
    config::ServerConfig,
    context::SharedContext,
    relay::udprelay::proxy_socket::{ProxySocket, ProxySocketError, UdpSocketType},
};
use std::{
    net::{IpAddr, SocketAddr},
    sync::Arc,
    time::Duration,
};
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::UdpSocket,
    sync::{Mutex, mpsc},
    task::JoinHandle,
    time::timeout,
};

struct Trojan {
    send: mpsc::Sender<Vec<u8>>,
    receive: Mutex<mpsc::Receiver<Result<Datagram>>>,
    worker: JoinHandle<()>,
    resolved: Mutex<Option<(Target, Target)>>,
}

impl Drop for Trojan {
    fn drop(&mut self) {
        self.worker.abort();
    }
}

enum Transport {
    Trojan(Trojan),
    Direct {
        ipv4: UdpSocket,
        ipv6: Option<UdpSocket>,
    },
    Shadowsocks {
        socket: ProxySocket<shadowsocks::net::UdpSocket>,
        overhead: usize,
    },
}

pub const MAX_WIRE_BYTES: usize = 65507;
const IDLE_TIMEOUT: Duration = Duration::from_secs(300);
const SEND_TIMEOUT: Duration = Duration::from_secs(10);

#[derive(Debug)]
pub struct Datagram {
    pub source: Target,
    pub payload: Vec<u8>,
}

/// A bounded datagram session. Receives may be cancelled by select! safely.
/// Pass Route.target to send_to to retain the routing decision's DNS pin.
pub struct UdpSession {
    dns: Arc<Dns>,
    transport: Transport,
    receive: Mutex<Vec<u8>>,
    send: Mutex<()>,
}

impl UdpSession {
    pub(crate) async fn direct(dns: Arc<Dns>) -> Result<Self> {
        let ipv4 = bind_socket("0.0.0.0:0").await?;
        let ipv6 = match bind_socket("[::]:0").await {
            Ok(socket) => Some(socket),
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::AddrNotAvailable | std::io::ErrorKind::Unsupported
                ) =>
            {
                None
            }
            Err(error) => return Err(error.into()),
        };
        Ok(Self {
            dns,
            transport: Transport::Direct { ipv4, ipv6 },
            receive: Mutex::new(vec![0; 65536]),
            send: Mutex::new(()),
        })
    }

    pub(crate) async fn shadowsocks(
        dns: Arc<Dns>,
        context: SharedContext,
        config: &ServerConfig,
        server: &Target,
    ) -> Result<Self> {
        let mut last = None;
        for ip in dns.resolve(server).await? {
            let bind = if ip.is_ipv4() { "0.0.0.0:0" } else { "[::]:0" };
            let socket = match bind_socket(bind).await {
                Ok(socket) => socket,
                Err(error) => {
                    last = Some(error);
                    continue;
                }
            };
            match socket.connect(SocketAddr::new(ip, server.port())).await {
                Ok(()) => {
                    return Ok(Self {
                        dns,
                        transport: Transport::Shadowsocks {
                            socket: ProxySocket::from_socket(
                                UdpSocketType::Client,
                                context,
                                config,
                                socket.into(),
                            ),
                            overhead: config.method().salt_len() + 16,
                        },
                        receive: Mutex::new(vec![0; 65536]),
                        send: Mutex::new(()),
                    });
                }
                Err(error) => last = Some(error),
            }
        }
        Err(last.context("no UDP server addresses")?.into())
    }

    pub(crate) fn trojan(dns: Arc<Dns>, stream: BoxStream) -> Self {
        let (send, outgoing) = mpsc::channel(2);
        let (incoming, receive) = mpsc::channel(2);
        let worker = tokio::spawn(trojan_worker(stream, outgoing, incoming));
        Self {
            dns,
            transport: Transport::Trojan(Trojan {
                send,
                receive: Mutex::new(receive),
                worker,
                resolved: Mutex::new(None),
            }),
            receive: Mutex::new(Vec::new()),
            send: Mutex::new(()),
        }
    }

    /// Returns the accepted payload length. Trojan accepts into a two-frame queue;
    /// a full queue returns an error (packet drop), never an unbounded waiter queue.
    pub async fn send_to(&self, payload: &[u8], target: &Target) -> Result<usize> {
        let _sending = self
            .send
            .try_lock()
            .context("UDP send already in progress; packet dropped")?;
        let limit = if matches!(self.transport, Transport::Trojan(_)) {
            u16::MAX as usize
        } else {
            MAX_WIRE_BYTES
        };
        if payload.len() > limit {
            bail!("UDP datagram exceeds protocol payload limit");
        }
        timeout(SEND_TIMEOUT, async {
            match &self.transport {
                Transport::Trojan(trojan) => {
                    let mut cache = trojan.resolved.lock().await;
                    let target = if target.host().parse::<IpAddr>().is_ok() {
                        target.clone()
                    } else if let Some((original, resolved)) = &*cache
                        && original == target
                    {
                        resolved.clone()
                    } else {
                        let ip = self.dns.resolve(target).await?[0];
                        let resolved = Target::new(ip.to_string(), target.port())?;
                        *cache = Some((target.clone(), resolved.clone()));
                        resolved
                    };
                    let mut frame = Vec::with_capacity(23 + payload.len());
                    destination(&target).write_to_buf(&mut frame);
                    frame.extend_from_slice(&(payload.len() as u16).to_be_bytes());
                    frame.extend_from_slice(b"\r\n");
                    frame.extend_from_slice(payload);
                    trojan.send.try_send(frame).map_err(|error| match error {
                        mpsc::error::TrySendError::Full(_) => {
                            anyhow::anyhow!("Trojan UDP send queue full; packet dropped")
                        }
                        mpsc::error::TrySendError::Closed(_) => {
                            anyhow::anyhow!("Trojan UDP session closed")
                        }
                    })?;
                    Ok(payload.len())
                }
                Transport::Direct { ipv4, ipv6 } => {
                    let ip = self.dns.resolve(target).await?[0];
                    let socket = match ip {
                        IpAddr::V4(_) => ipv4,
                        IpAddr::V6(_) => ipv6.as_ref().context("IPv6 UDP is unavailable")?,
                    };
                    Ok(socket
                        .send_to(payload, SocketAddr::new(ip, target.port()))
                        .await?)
                }
                Transport::Shadowsocks { socket, overhead } => {
                    let address = destination(target);
                    if payload.len() + address.serialized_len() + overhead > MAX_WIRE_BYTES {
                        bail!("Shadowsocks UDP wire datagram exceeds 65507 bytes");
                    }
                    socket
                        .send(&address, payload)
                        .await
                        .context("Shadowsocks UDP send failed")?;
                    Ok(payload.len())
                }
            }
        })
        .await
        .context("UDP send timed out after 10 seconds")?
    }

    pub async fn recv_from(&self) -> Result<Datagram> {
        if let Transport::Trojan(trojan) = &self.transport {
            let mut receive = trojan
                .receive
                .try_lock()
                .context("only one UDP receiver may wait per session")?;
            return receive.recv().await.context("Trojan UDP session closed")?;
        }
        let mut storage = self
            .receive
            .try_lock()
            .context("only one UDP receiver may wait per session")?;
        timeout(IDLE_TIMEOUT, async {
            if let Transport::Shadowsocks { socket, .. } = &self.transport {
                loop {
                    match socket.recv(&mut storage).await {
                        Ok((n, source, wire)) if wire <= MAX_WIRE_BYTES => {
                            if let Ok(source) = address_target(source) {
                                return Ok(Datagram { source, payload: storage[..n].to_vec() });
                            }
                        }
                        Ok(_) | Err(ProxySocketError::ProtocolError(_)) => {},
                        Err(error) => return Err(error).context("Shadowsocks UDP receive failed"),
                    }
                    // Authentication failures are packet-local, not DIRECT fallback or stream EOF.
                    tokio::task::yield_now().await;
                }
            }
            let Transport::Direct { ipv4, ipv6 } = &self.transport else { unreachable!() };
            // Separate buffers prevent a cancelled branch from corrupting the selected packet.
            let mut ipv6_buffer = [0; 65536];
            loop {
                let (n, address, v6) = tokio::select! {
                    result = ipv4.recv_from(&mut storage) => { let (n, a) = result?; (n, a, false) },
                    result = async {
                        match ipv6 {
                            Some(socket) => socket.recv_from(&mut ipv6_buffer).await,
                            None => std::future::pending().await,
                        }
                    } => { let (n, a) = result?; (n, a, true) },
                };
                if n > MAX_WIRE_BYTES { continue; }
                return Ok(Datagram { source: Target::new(address.ip().to_string(), address.port())?,
                    payload: if v6 { ipv6_buffer[..n].to_vec() } else { storage[..n].to_vec() } });
            }
        }).await.context("UDP receive idle timeout after 300 seconds")?
    }
}

fn address_target(address: shadowsocks::relay::socks5::Address) -> Result<Target> {
    use shadowsocks::relay::socks5::Address;
    match address {
        Address::SocketAddress(address) => Target::new(address.ip().to_string(), address.port()),
        Address::DomainNameAddress(host, port) => Target::from_socks(host, port),
    }
}

async fn bind_socket(address: &str) -> Result<UdpSocket, std::io::Error> {
    let socket = UdpSocket::bind(address).await?;
    // macOS defaults to a 9216-byte send buffer, below the supported UDP wire limit.
    #[cfg(unix)]
    {
        rustix::net::sockopt::set_socket_send_buffer_size(&socket, 256 * 1024)?;
        rustix::net::sockopt::set_socket_recv_buffer_size(&socket, 256 * 1024)?;
    }
    Ok(socket)
}

async fn trojan_worker(
    stream: BoxStream,
    mut outgoing: mpsc::Receiver<Vec<u8>>,
    incoming: mpsc::Sender<Result<Datagram>>,
) {
    let (mut reader, mut writer) = tokio::io::split(stream);
    // Each loop future is polled for its entire lifetime. select! never recreates
    // a read_exact future when a concurrent send wins, so partial frames survive.
    let result: Result<()> = tokio::select! {
        result = async {
            loop {
                let packet = timeout(IDLE_TIMEOUT, async {
                    let source = shadowsocks::relay::socks5::Address::read_from(&mut reader).await
                        .context("invalid or truncated Trojan UDP address")?;
                    let source = address_target(source).context("invalid Trojan UDP source")?;
                    let len = reader.read_u16().await.context("truncated Trojan UDP length")? as usize;
                    let mut delimiter = [0; 2];
                    reader.read_exact(&mut delimiter).await.context("truncated Trojan UDP delimiter")?;
                    if delimiter != *b"\r\n" { bail!("invalid Trojan UDP CRLF"); }
                    let mut payload = vec![0; len];
                    reader.read_exact(&mut payload).await.context("truncated Trojan UDP payload")?;
                    Ok(Datagram { source, payload })
                }).await.context("Trojan UDP frame timeout after 300 seconds")??;
                match incoming.try_send(Ok(packet)) {
                    Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => {},
                    Err(mpsc::error::TrySendError::Closed(_)) => return Ok(()),
                }
                tokio::task::yield_now().await;
            }
        } => result,
        result = async {
            while let Some(frame) = outgoing.recv().await {
                timeout(SEND_TIMEOUT, async {
                    writer.write_all(&frame).await?;
                    writer.flush().await
                }).await.context("Trojan UDP write timeout after 10 seconds")?
                    .context("Trojan UDP write failed")?;
            }
            Ok(())
        } => result,
    };
    // Close TLS immediately even when the receive queue is full. Terminal errors
    // follow already accepted frames, and no byte resynchronization is attempted.
    drop(reader);
    drop(writer);
    drop(outgoing);
    if let Err(error) = result {
        let _ = incoming.send(Err(error)).await;
    }
}
