use std::{
    net::{IpAddr, SocketAddr},
    sync::{Arc, OnceLock},
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
    io::{AsyncRead, AsyncWrite, AsyncWriteExt},
    net::TcpStream,
    time::timeout,
};

use tokio_rustls::TlsConnector;

use crate::{
    config::{Config, Proxy, ProxyKind},
    dns::Dns,
    target::Target,
};

pub trait IoStream: AsyncRead + AsyncWrite + Send + Unpin {}
impl<T: AsyncRead + AsyncWrite + Send + Unpin> IoStream for T {}
pub type BoxStream = Box<dyn IoStream>;

pub struct Connector {
    dns: Arc<Dns>,
    ss_context: OnceLock<SharedContext>,
    tls_unverified: Option<TlsConnector>,
    tls_verified: Option<TlsConnector>,
}

impl Connector {
    pub fn new(config: &Config) -> Result<Self> {
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
            let mut roots = RootCertStore::empty();
            let native = rustls_native_certs::load_native_certs();
            roots.add_parsable_certificates(native.certs);
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

    pub async fn connect(&self, proxy: &Proxy, target: &Target) -> Result<BoxStream> {
        timeout(Duration::from_secs(10), self.connect_inner(proxy, target))
            .await
            .context(
                "outbound setup timed out after 10 seconds; check DNS and proxy reachability",
            )?
    }

    async fn dial(&self, host: &str, port: u16) -> Result<TcpStream> {
        let addresses = self.dns.resolve(&Target::new(host, port)?).await?;
        let mut last_error = None;
        for ip in addresses {
            match TcpStream::connect(SocketAddr::new(ip, port)).await {
                Ok(stream) => return Ok(stream),
                Err(error) => last_error = Some(error),
            }
        }
        Err(last_error.expect("DNS returns at least one address").into())
    }

    async fn connect_inner(&self, proxy: &Proxy, target: &Target) -> Result<BoxStream> {
        match &proxy.kind {
            ProxyKind::Direct => {
                let stream = self
                    .dial(target.host(), target.port())
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
                let method = match cipher.as_str() {
                    "aes-128-gcm" => CipherKind::AES_128_GCM,
                    "aes-256-gcm" => CipherKind::AES_256_GCM,
                    "chacha20-ietf-poly1305" => CipherKind::CHACHA20_POLY1305,
                    _ => bail!(
                        "unsupported Shadowsocks cipher; use aes-128-gcm, aes-256-gcm or chacha20-ietf-poly1305"
                    ),
                };
                let config = ServerConfig::new((server.clone(), *port), password.clone(), method)
                    .context("cannot prepare Shadowsocks TCP configuration")?;
                let socket = self.dial(server, *port).await.context(
                    "Shadowsocks server TCP connection failed; check server reachability",
                )?;
                let context = self
                    .ss_context
                    .get_or_init(|| ShadowsocksContext::new_shared(ServerType::Local));
                let mut stream = ProxyClientStream::from_stream(
                    context.clone(),
                    socket,
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
            ProxyKind::Trojan {
                server,
                port,
                password,
                sni,
                skip_cert_verify,
            } => {
                let name = trojan_server_name(server, sni.as_deref(), *skip_cert_verify)?;
                let tls = if *skip_cert_verify {
                    &self.tls_unverified
                } else {
                    &self.tls_verified
                };
                let tls = tls.as_ref()
                    .context("Trojan TLS configuration is unavailable; rebuild Connector with this proxy configuration")?;
                let socket = self
                    .dial(server, *port)
                    .await
                    .context("Trojan server TCP connection failed; check server reachability")?;
                let mut stream = tls.connect(name, socket).await.context(
                    "Trojan TLS handshake failed; check server certificate, trust roots and sni",
                )?;
                let mut request =
                    format!("{:x}\r\n", Sha224::digest(password.as_bytes())).into_bytes();
                request.push(1); // CONNECT
                destination(target).write_to_buf(&mut request);
                request.extend_from_slice(b"\r\n");
                stream
                    .write_all(&request)
                    .await
                    .context("cannot write Trojan CONNECT request")?;
                stream
                    .flush()
                    .await
                    .context("cannot flush Trojan CONNECT request")?;
                Ok(Box::new(stream))
            }
        }
    }
}

fn destination(target: &Target) -> Address {
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
