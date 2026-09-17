use anyhow::{Result, bail};

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Target {
    host: String,
    port: u16,
}

impl Target {
    pub fn new(host: impl Into<String>, port: u16) -> Result<Self> {
        let host = host.into();
        if port == 0 {
            bail!("destination port must be between 1 and 65535");
        }
        if host.parse::<std::net::IpAddr>().is_err() {
            let domain = host.strip_suffix('.').unwrap_or(&host);
            if domain.is_empty()
                || domain.len() > 253
                || !domain.split('.').all(|label| {
                    !label.is_empty()
                        && label.len() <= 63
                        && label
                            .bytes()
                            .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
                        && !label.starts_with('-')
                        && !label.ends_with('-')
                })
            {
                bail!(
                    "destination must be an IP address or ASCII DNS name (use punycode for IDNs)"
                );
            }
        }
        Ok(Self { host, port })
    }

    /// SOCKS domains are length-prefixed wire names, not validated DNS labels.
    /// Configuration and HTTP authorities must continue to use `new`.
    pub fn from_socks(host: impl Into<String>, port: u16) -> Result<Self> {
        let host = host.into();
        if host.is_empty() || host.len() > u8::MAX as usize || port == 0 {
            bail!("SOCKS destination requires a 1..255 byte name and a nonzero port");
        }
        Ok(Self { host, port })
    }

    pub fn host(&self) -> &str {
        &self.host
    }

    pub fn port(&self) -> u16 {
        self.port
    }
}
