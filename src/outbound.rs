use std::{
    io,
    net::{IpAddr, SocketAddr},
    pin::Pin,
    sync::{Arc, OnceLock},
    task::{Context as TaskContext, Poll},
    time::Duration,
};

use anyhow::{Context, Result, bail};
use rustls::{
    ClientConfig, DigitallySignedStruct, RootCertStore, SignatureScheme,
    client::danger::{HandshakeSignatureValid, ServerCertVerified, ServerCertVerifier},
    crypto::{CryptoProvider, verify_tls12_signature, verify_tls13_signature},
    pki_types::{CertificateDer, ServerName, UnixTime},
};
use sha2::{Digest, Sha224};
use shadowsocks::{
    config::{ServerConfig, ServerType},
    context::{Context as ShadowsocksContext, SharedContext},
    crypto::CipherKind,
    relay::{socks5::Address, tcprelay::proxy_stream::ProxyClientStream},
};
use tokio::{
    io::{AsyncRead, AsyncWrite, AsyncWriteExt, ReadBuf},
    net::TcpStream,
    time::timeout,
};

use tokio_rustls::TlsConnector;

use crate::{
    config::{Config, Proxy, ProxyKind},
    dns::Dns,
    observability::FailureStage,
    target::Target,
};

pub trait IoStream: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> IoStream for T {}
pub type BoxStream = Box<dyn IoStream>;

// An incoming protocol unit was interrupted. Retain only its I/O kind, never
// the transport error's text, since these errors may cross diagnostic boundaries.
#[derive(Debug)]
pub(crate) struct ProtocolReadTruncated;
impl std::fmt::Display for ProtocolReadTruncated {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("incomplete protocol read")
    }
}
impl std::error::Error for ProtocolReadTruncated {}

pub(crate) fn truncated_read(error: io::Error) -> io::Error {
    io::Error::new(error.kind(), ProtocolReadTruncated)
}

// shadowsocks 1.25.0 aead::DecryptedReader::poll_read_exact requests exactly the
// remaining salt/length/data bytes in a fresh ReadBuf, even after Pending. A full
// buffer completes one read unit, not necessarily a record: salt still needs its
// first length, and each length needs its payload (including the tag). Only before
// salt or after a complete payload is an unstarted unit's reset ordinary.
// Track those phases without decoding lengths or duplicating crypto framing.
// EOF validation remains with the library (which permits EOF just after salt).
// This adapter is only used under classic AEAD, whose salts and tags are nonempty.
#[derive(Clone, Copy)]
enum SsReadUnit {
    Salt,
    FirstLength,
    Payload,
    NextLength,
}

struct SsReadProgress<S> {
    inner: S,
    unit: SsReadUnit,
    partial: bool,
}
impl<S: AsyncRead + Unpin> AsyncRead for SsReadProgress<S> {
    fn poll_read(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        buffer: &mut ReadBuf<'_>,
    ) -> Poll<io::Result<()>> {
        let remaining = buffer.remaining();
        if remaining == 0 {
            return Poll::Ready(Ok(()));
        }
        let before = buffer.filled().len();
        let result = Pin::new(&mut self.inner).poll_read(cx, buffer);
        match result {
            Poll::Ready(Ok(())) => {
                let read = buffer.filled().len() - before;
                if read != 0 {
                    self.partial = read < remaining;
                    if !self.partial {
                        self.unit = match self.unit {
                            SsReadUnit::Salt => SsReadUnit::FirstLength,
                            SsReadUnit::FirstLength | SsReadUnit::NextLength => SsReadUnit::Payload,
                            SsReadUnit::Payload => SsReadUnit::NextLength,
                        };
                    }
                }
                Poll::Ready(Ok(()))
            }
            Poll::Ready(Err(error))
                if self.partial
                    || matches!(self.unit, SsReadUnit::FirstLength | SsReadUnit::Payload) =>
            {
                Poll::Ready(Err(truncated_read(error)))
            }
            result => result,
        }
    }
}
impl<S: AsyncWrite + Unpin> AsyncWrite for SsReadProgress<S> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        cx: &mut TaskContext<'_>,
        data: &[u8],
    ) -> Poll<io::Result<usize>> {
        Pin::new(&mut self.inner).poll_write(cx, data)
    }
    fn poll_flush(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_flush(cx)
    }
    fn poll_shutdown(mut self: Pin<&mut Self>, cx: &mut TaskContext<'_>) -> Poll<io::Result<()>> {
        Pin::new(&mut self.inner).poll_shutdown(cx)
    }
}

pub struct Connector {
    dns: Arc<Dns>,
    ss_context: OnceLock<SharedContext>,
    tls_unverified: Option<TlsConnector>,
    tls_verified: Option<TlsConnector>,
}

impl Connector {
    pub fn new(config: &Config) -> Result<Self> {
        Self::build(config, None)
    }

    /// Use an explicit trust store without process-global certificate environment changes.
    pub fn with_tls_roots(config: &Config, roots: RootCertStore) -> Result<Self> {
        Self::build(config, Some(roots))
    }

    fn build(config: &Config, roots: Option<RootCertStore>) -> Result<Self> {
        for proxy in config.proxies() {
            if let ProxyKind::Trojan {
                server,
                sni,
                skip_cert_verify,
                ..
            } = &proxy.kind
            {
                trojan_server_name(server, sni.as_deref(), *skip_cert_verify)?;
            }
        }
        let needs_unverified = config.proxies().iter().any(|proxy| {
            matches!(
                proxy.kind,
                ProxyKind::Trojan {
                    skip_cert_verify: true,
                    ..
                }
            )
        });
        let tls_unverified = if needs_unverified {
            let provider = Arc::new(rustls::crypto::aws_lc_rs::default_provider());
            let client = ClientConfig::builder_with_provider(provider.clone())
                .with_safe_default_protocol_versions()?
                .dangerous()
                .with_custom_certificate_verifier(Arc::new(SkipServerIdentity { provider }))
                .with_no_client_auth();
            Some(TlsConnector::from(Arc::new(client)))
        } else {
            None
        };
        let needs_verified = config.proxies().iter().any(|proxy| {
            matches!(
                proxy.kind,
                ProxyKind::Trojan {
                    skip_cert_verify: false,
                    ..
                }
            )
        });
        let tls_verified = if needs_verified {
            let roots = roots.unwrap_or_else(|| {
                let mut roots = RootCertStore::empty();
                roots.add_parsable_certificates(rustls_native_certs::load_native_certs().certs);
                roots
            });
            if roots.is_empty() {
                bail!(
                    "no usable system TLS trust roots; install trusted CA certificates or check SSL_CERT_FILE/SSL_CERT_DIR"
                );
            }
            let client = ClientConfig::builder_with_provider(Arc::new(
                rustls::crypto::aws_lc_rs::default_provider(),
            ))
            .with_safe_default_protocol_versions()?
            .with_root_certificates(roots)
            .with_no_client_auth();
            Some(TlsConnector::from(Arc::new(client)))
        } else {
            None
        };
        Ok(Self {
            dns: config.dns.clone(),
            ss_context: OnceLock::new(),
            tls_unverified,
            tls_verified,
        })
    }

    /// Open a datagram association without sending a payload. Each send_to must
    /// receive the routed target, because a session can carry multiple destinations.
    pub async fn open_udp(&self, proxy: &Proxy, target: &Target) -> Result<crate::udp::UdpSession> {
        let mut stage = FailureStage::Udp;
        self.open_udp_observed(proxy, target, &mut stage).await
    }

    pub(crate) async fn open_udp_observed(
        &self,
        proxy: &Proxy,
        _target: &Target,
        stage: &mut FailureStage,
    ) -> Result<crate::udp::UdpSession> {
        *stage = FailureStage::Udp;
        validate_obfs(proxy)?;
        match &proxy.kind {
            ProxyKind::Direct => crate::udp::UdpSession::direct(self.dns.clone()).await,
            ProxyKind::Reject => bail!("UDP connection rejected by REJECT routing rule"),
            ProxyKind::Shadowsocks {
                server,
                port,
                password,
                cipher,
            } => {
                if !proxy.udp {
                    bail!("UDP is disabled for this proxy; configure udp: true");
                }
                let method = ss_method(cipher)?;
                let config = ServerConfig::new((server.clone(), *port), password.clone(), method)
                    .context("cannot prepare Shadowsocks UDP configuration")?;
                timeout(
                    Duration::from_secs(10),
                    crate::udp::UdpSession::shadowsocks(
                        self.dns.clone(),
                        self.ss_context
                            .get_or_init(|| ShadowsocksContext::new_shared(ServerType::Local))
                            .clone(),
                        &config,
                        &Target::new(server.clone(), *port)?,
                        stage,
                    ),
                )
                .await
                .with_context(|| *stage)
                .context("UDP setup timed out after 10 seconds")?
            }
            ProxyKind::Trojan { .. } => {
                if !proxy.udp {
                    bail!("UDP is disabled for this proxy; configure udp: true");
                }
                let stream = timeout(
                    Duration::from_secs(10),
                    self.trojan_stream(proxy, None, stage),
                )
                .await
                .with_context(|| *stage)
                .context("UDP setup timed out after 10 seconds")??;
                Ok(crate::udp::UdpSession::trojan(self.dns.clone(), stream))
            }
        }
    }

    pub async fn connect(&self, proxy: &Proxy, target: &Target) -> Result<BoxStream> {
        let mut stage = FailureStage::Connect;
        self.connect_observed(proxy, target, &mut stage).await
    }

    pub(crate) async fn connect_observed(
        &self,
        proxy: &Proxy,
        target: &Target,
        stage: &mut FailureStage,
    ) -> Result<BoxStream> {
        *stage = FailureStage::Connect;
        timeout(
            Duration::from_secs(10),
            self.connect_inner(proxy, target, stage),
        )
        .await
        .with_context(|| *stage)
        .context("outbound setup timed out after 10 seconds; check DNS and proxy reachability")?
    }

    async fn dial(&self, host: &str, port: u16, stage: &mut FailureStage) -> Result<TcpStream> {
        *stage = FailureStage::Dns;
        let addresses = self.dns.resolve(&Target::new(host, port)?).await?;
        *stage = FailureStage::Connect;
        let mut last_error = None;
        for ip in addresses {
            match TcpStream::connect(SocketAddr::new(ip, port)).await {
                Ok(stream) => return Ok(stream),
                Err(error) => last_error = Some(error),
            }
        }
        Err(
            anyhow::Error::from(last_error.expect("DNS returns at least one address"))
                .context(FailureStage::Connect),
        )
    }

    async fn connect_inner(
        &self,
        proxy: &Proxy,
        target: &Target,
        stage: &mut FailureStage,
    ) -> Result<BoxStream> {
        validate_obfs(proxy)?;
        match &proxy.kind {
            ProxyKind::Direct => {
                let stream = self
                    .dial(target.host(), target.port(), stage)
                    .await
                    .context("DIRECT TCP connection failed; check destination reachability")?;
                Ok(Box::new(stream))
            }
            ProxyKind::Reject => bail!(
                "connection rejected by REJECT; select an allowed proxy or change the routing rule"
            ),
            ProxyKind::Shadowsocks {
                server,
                port,
                password,
                cipher,
            } => {
                let method = ss_method(cipher)?;
                let config = ServerConfig::new((server.clone(), *port), password.clone(), method)
                    .context("cannot prepare Shadowsocks TCP configuration")?;
                let socket = self.dial(server, *port, stage).await.context(
                    "Shadowsocks server TCP connection failed; check server reachability",
                )?;
                let socket: BoxStream = match &proxy.obfs {
                    Some(obfs) => Box::new(crate::simple_obfs::HttpObfsStream::new(
                        socket, &obfs.host, *port,
                    )?),
                    None => Box::new(socket),
                };
                let context = self
                    .ss_context
                    .get_or_init(|| ShadowsocksContext::new_shared(ServerType::Local));
                let mut stream = ProxyClientStream::from_stream(
                    context.clone(),
                    SsReadProgress {
                        inner: socket,
                        unit: SsReadUnit::Salt,
                        partial: false,
                    },
                    &config,
                    destination(target),
                );
                // Unlike write_all(&[]), write(&[]) polls AsyncWrite and sends the SS address.
                // Server-first protocols must receive this header before the caller writes payload.
                stream
                    .write(&[])
                    .await
                    .context("cannot write Shadowsocks destination header")?;
                stream
                    .flush()
                    .await
                    .context("cannot flush Shadowsocks destination header")?;
                Ok(Box::new(stream))
            }
            ProxyKind::Trojan { .. } => self.trojan_stream(proxy, Some(target), stage).await,
        }
    }

    async fn trojan_stream(
        &self,
        proxy: &Proxy,
        target: Option<&Target>,
        stage: &mut FailureStage,
    ) -> Result<BoxStream> {
        let ProxyKind::Trojan {
            server,
            port,
            password,
            sni,
            skip_cert_verify,
        } = &proxy.kind
        else {
            bail!("Trojan transport requires a Trojan proxy");
        };
        let name = trojan_server_name(server, sni.as_deref(), *skip_cert_verify)?;
        let tls = if *skip_cert_verify {
            &self.tls_unverified
        } else {
            &self.tls_verified
        };
        let tls = tls.as_ref().context("Trojan TLS configuration is unavailable; rebuild Connector with this proxy configuration")?;
        let socket = self
            .dial(server, *port, stage)
            .await
            .context("Trojan server TCP connection failed; check server reachability")?;
        *stage = FailureStage::Tls;
        let mut stream = tls
            .connect(name, socket)
            .await
            .context("Trojan TLS handshake failed; check server certificate, trust roots and sni")
            .context(FailureStage::Tls)?;
        *stage = FailureStage::Connect;
        let mut request = format!("{:x}\r\n", Sha224::digest(password.as_bytes())).into_bytes();
        if let Some(target) = target {
            request.push(1);
            destination(target).write_to_buf(&mut request);
        } else {
            // Trojan UDP uses an unspecified IPv4 endpoint, not the first datagram target.
            request.extend_from_slice(&[3, 1, 0, 0, 0, 0, 0, 0]);
        }
        request.extend_from_slice(b"\r\n");
        stream
            .write_all(&request)
            .await
            .context("cannot write Trojan request")?;
        stream
            .flush()
            .await
            .context("cannot flush Trojan request")?;
        Ok(Box::new(stream))
    }
}

pub(crate) fn destination(target: &Target) -> Address {
    match target.host().parse::<IpAddr>() {
        Ok(ip) => Address::SocketAddress((ip, target.port()).into()),
        Err(_) => Address::DomainNameAddress(target.host().to_owned(), target.port()),
    }
}

// Explicit skip-cert-verify bypasses identity checks, never proof of key possession.
#[derive(Debug)]
struct SkipServerIdentity {
    provider: Arc<CryptoProvider>,
}

impl ServerCertVerifier for SkipServerIdentity {
    fn verify_server_cert(
        &self,
        _end_entity: &CertificateDer<'_>,
        _intermediates: &[CertificateDer<'_>],
        _server_name: &ServerName<'_>,
        _ocsp_response: &[u8],
        _now: UnixTime,
    ) -> Result<ServerCertVerified, rustls::Error> {
        Ok(ServerCertVerified::assertion())
    }

    fn verify_tls12_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls12_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn verify_tls13_signature(
        &self,
        message: &[u8],
        cert: &CertificateDer<'_>,
        dss: &DigitallySignedStruct,
    ) -> Result<HandshakeSignatureValid, rustls::Error> {
        verify_tls13_signature(
            message,
            cert,
            dss,
            &self.provider.signature_verification_algorithms,
        )
    }

    fn supported_verify_schemes(&self) -> Vec<SignatureScheme> {
        self.provider
            .signature_verification_algorithms
            .supported_schemes()
    }
}

fn trojan_server_name(
    server: &str,
    sni: Option<&str>,
    skip_cert_verify: bool,
) -> Result<ServerName<'static>> {
    if let Some(name) = sni {
        if name.ends_with('.') || name.parse::<IpAddr>().is_ok() {
            bail!(
                "Trojan sni must be a DNS hostname without a trailing root dot, not an IP address"
            );
        }
        Target::new(name, 1).context("Trojan sni must be a valid ASCII DNS hostname")?;
    }
    if sni.is_none() && !skip_cert_verify && server.parse::<IpAddr>().is_ok() {
        bail!("verified Trojan IP server requires sni; configure the certificate's DNS hostname");
    }
    let name = sni.unwrap_or(server);
    ServerName::try_from(name.strip_suffix('.').unwrap_or(name).to_owned())
        .context("invalid Trojan TLS server name; configure a valid sni hostname")
}

fn ss_method(cipher: &str) -> Result<CipherKind> {
    match cipher {
        "aes-128-gcm" => Ok(CipherKind::AES_128_GCM),
        "aes-256-gcm" => Ok(CipherKind::AES_256_GCM),
        "chacha20-ietf-poly1305" | "chacha20-poly1305" => Ok(CipherKind::CHACHA20_POLY1305),
        _ => bail!(
            "unsupported Shadowsocks cipher; use aes-128-gcm, aes-256-gcm or chacha20-ietf-poly1305"
        ),
    }
}

fn validate_obfs(proxy: &Proxy) -> Result<()> {
    if let Some(obfs) = &proxy.obfs {
        if !matches!(proxy.kind, ProxyKind::Shadowsocks { .. }) {
            bail!("simple-obfs is supported only for Shadowsocks TCP");
        }
        crate::simple_obfs::validate_host(&obfs.host)?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tokio::{io::AsyncReadExt, net::TcpListener, task::JoinSet};

    // A transport boundary fixture, not a replacement for the AEAD parser.
    struct InterruptedRead {
        bytes: io::Cursor<Vec<u8>>,
        max_read: usize,
        pending: bool,
        error_kind: io::ErrorKind,
    }

    impl AsyncRead for InterruptedRead {
        fn poll_read(
            mut self: Pin<&mut Self>,
            cx: &mut TaskContext<'_>,
            buffer: &mut ReadBuf<'_>,
        ) -> Poll<io::Result<()>> {
            if buffer.remaining() == 0 {
                return Poll::Ready(Ok(()));
            }
            if self.pending {
                self.pending = false;
                cx.waker().wake_by_ref();
                return Poll::Pending;
            }
            self.pending = true;
            let pos = self.bytes.position() as usize;
            let bytes = &self.bytes.get_ref()[pos..];
            if bytes.is_empty() {
                return Poll::Ready(Err(io::Error::new(
                    self.error_kind,
                    "private-transport-error",
                )));
            }
            let read = bytes.len().min(buffer.remaining()).min(self.max_read);
            buffer.put_slice(&bytes[..read]);
            self.bytes.set_position((pos + read) as u64);
            Poll::Ready(Ok(()))
        }
    }

    #[tokio::test]
    async fn ss_aead_read_boundaries_preserve_error_kind_across_pending_and_empty_reads() {
        use shadowsocks::relay::tcprelay::{
            crypto_io::{DecryptedReader, StreamType},
            proxy_stream::ProxyServerStream,
        };
        for method in [
            CipherKind::AES_128_GCM,
            CipherKind::AES_256_GCM,
            CipherKind::CHACHA20_POLY1305,
        ] {
            let config = ServerConfig::new(("127.0.0.1", 443), "private-password", method).unwrap();
            let mut encoder = ProxyServerStream::from_stream(
                ShadowsocksContext::new_shared(ServerType::Server),
                io::Cursor::new(Vec::new()),
                method,
                config.key(),
            );
            encoder.write_all(b"first").await.unwrap();
            let first_end = encoder.get_ref().get_ref().len();
            encoder.write_all(b"second").await.unwrap();
            let wire = encoder.into_inner().into_inner();
            // Every cut includes salt/length/payload boundaries and partial units.
            // Whole-unit reads reproduce the bug; one-byte reads exercise Pending.
            for max_read in [usize::MAX, 1] {
                for cut in 0..=wire.len() {
                    for kind in [
                        io::ErrorKind::ConnectionReset,
                        io::ErrorKind::ConnectionAborted,
                    ] {
                        let context = ShadowsocksContext::new_shared(ServerType::Local);
                        let mut reader =
                            DecryptedReader::new(StreamType::Client, method, config.key());
                        let mut stream = SsReadProgress {
                            inner: InterruptedRead {
                                bytes: io::Cursor::new(wire[..cut].to_vec()),
                                max_read,
                                pending: true,
                                error_kind: kind,
                            },
                            unit: SsReadUnit::Salt,
                            partial: false,
                        };
                        let mut plaintext = Vec::new();
                        let error = loop {
                            let mut bytes = [0; 3];
                            let mut buffer = ReadBuf::new(&mut bytes);
                            let result = std::future::poll_fn(|cx| {
                                // Empty reads between parser polls must not advance a unit
                                // or erase a partial read retained across Pending.
                                assert!(matches!(
                                    Pin::new(&mut stream).poll_read(cx, &mut ReadBuf::new(&mut [])),
                                    Poll::Ready(Ok(()))
                                ));
                                reader.poll_read_decrypted(cx, &context, &mut stream, &mut buffer)
                            })
                            .await;
                            if let Err(error) = result {
                                break io::Error::from(error);
                            }
                            assert!(!buffer.filled().is_empty());
                            plaintext.extend_from_slice(buffer.filled());
                        };
                        let expected = if cut == wire.len() {
                            b"firstsecond".as_slice()
                        } else if cut >= first_end {
                            b"first".as_slice()
                        } else {
                            b"".as_slice()
                        };
                        assert_eq!(plaintext, expected);
                        assert_eq!(error.kind(), kind);
                        let truncated = error
                            .get_ref()
                            .is_some_and(|e| e.is::<ProtocolReadTruncated>());
                        assert_eq!(
                            truncated,
                            cut != 0 && cut != first_end && cut != wire.len(),
                            "method={method:?}, cut={cut}, max_read={max_read}, kind={kind:?}"
                        );
                        if truncated {
                            assert_eq!(error.to_string(), "incomplete protocol read");
                        }
                    }
                }
            }
        }
    }

    #[tokio::test]
    async fn silent_tls_preserves_stage_for_connector_and_caller_deadlines() {
        timeout(Duration::from_secs(13), async {
            let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
            let config = Config::parse(&format!(
                "proxies: [{{name: edge, type: trojan, server: 127.0.0.1, port: {}, password: private-password, skip-cert-verify: true, udp: true}}]\nrules: ['MATCH,edge']",
                listener.local_addr().unwrap().port()
            )).unwrap();
            let connector = Connector::new(&config).unwrap();
            let target = Target::new("private-target.invalid", 443).unwrap();
            let route = config.route(&target).await.unwrap();
            let peer = tokio::spawn(async move {
                let mut tasks = JoinSet::new();
                for _ in 0..3 {
                    let (mut stream, _) = listener.accept().await.unwrap();
                    tasks.spawn(async move {
                        let mut hello = Vec::new();
                        stream.read_to_end(&mut hello).await.unwrap();
                        assert_eq!(hello.first(), Some(&22));
                    });
                }
                while let Some(result) = tasks.join_next().await {
                    result.unwrap();
                }
            });
            let cancelled = async {
                let mut stage = FailureStage::Connect;
                // Routing consumes part of the unchanged outer ten-second budget.
                // This makes the caller deadline win over Connector's own timer.
                let result = timeout(Duration::from_secs(10), async {
                    tokio::time::sleep(Duration::from_millis(100)).await;
                    connector.connect_observed(route.proxy, &target, &mut stage).await
                }).await;
                assert!(result.is_err(), "the caller deadline must win");
                assert!(matches!(stage, FailureStage::Tls));
            };
            let started = std::time::Instant::now();
            let (tcp, udp, ()) = tokio::join!(
                connector.connect(route.proxy, &target),
                connector.open_udp(route.proxy, &target),
                cancelled,
            );
            assert!(started.elapsed() >= Duration::from_secs(10));
            for error in [tcp.err().unwrap(), udp.err().unwrap()] {
                assert!(error.to_string().contains("timed out after 10 seconds"));
                assert!(error.is::<tokio::time::error::Elapsed>());
                assert!(matches!(error.downcast_ref::<FailureStage>(), Some(FailureStage::Tls)));
            }
            peer.await.unwrap();
        }).await.unwrap();
    }
}
