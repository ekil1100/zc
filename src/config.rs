use std::{collections::HashMap, net::IpAddr, sync::Arc};

use anyhow::{Result, anyhow, bail};
use ipnet::IpNet;
use serde::Deserialize;

use crate::{dns::Dns, target::Target};

const MAX_SOURCE_BYTES: usize = 16 * 1024 * 1024;
const MAX_PROXIES: usize = 4096;
const MAX_GROUPS: usize = 1024;
const MAX_MEMBERS: usize = 5122;
const MAX_RULES: usize = 262144;

fn bounded<'de, D, T, const LIMIT: usize>(deserializer: D) -> std::result::Result<Vec<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    struct Sequence<T, const LIMIT: usize>(std::marker::PhantomData<T>);
    impl<'de, T: Deserialize<'de>, const LIMIT: usize> serde::de::Visitor<'de> for Sequence<T, LIMIT> {
        type Value = Vec<T>;
        fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
            write!(formatter, "a sequence containing at most {LIMIT} entries")
        }
        fn visit_seq<A: serde::de::SeqAccess<'de>>(
            self,
            mut sequence: A,
        ) -> std::result::Result<Self::Value, A::Error> {
            let mut entries = Vec::new();
            while entries.len() < LIMIT {
                match sequence.next_element()? {
                    Some(entry) => entries.push(entry),
                    None => return Ok(entries),
                }
            }
            if sequence.next_element::<serde::de::IgnoredAny>()?.is_some() {
                return Err(serde::de::Error::custom(
                    "configuration collection limit exceeded",
                ));
            }
            Ok(entries)
        }
    }
    // deserialize_seq in serde-saphyr accepts null as an empty sequence.
    deserializer.deserialize_any(Sequence::<T, LIMIT>(std::marker::PhantomData))
}

// Require an actual root mapping: serde-saphyr otherwise treats null as an empty struct.
struct Mapping<T>(T);

impl<'de, T: Deserialize<'de>> Deserialize<'de> for Mapping<T> {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        struct Map<T>(std::marker::PhantomData<T>);
        impl<'de, T: Deserialize<'de>> serde::de::Visitor<'de> for Map<T> {
            type Value = Mapping<T>;
            fn expecting(&self, formatter: &mut std::fmt::Formatter) -> std::fmt::Result {
                formatter.write_str("a configuration mapping")
            }
            fn visit_map<A: serde::de::MapAccess<'de>>(
                self,
                map: A,
            ) -> std::result::Result<Self::Value, A::Error> {
                T::deserialize(serde::de::value::MapAccessDeserializer::new(map)).map(Mapping)
            }
        }
        deserializer.deserialize_any(Map::<T>(std::marker::PhantomData))
    }
}

pub struct Config {
    pub(crate) dns: Arc<Dns>,
    bind_address: IpAddr,
    proxies: Vec<Proxy>,
    rules: Vec<Rule>,
}

// Consumers must dial/encode this target, never the original unresolved destination.
pub struct Route<'a> {
    pub proxy: &'a Proxy,
    pub target: Target,
}

struct Rule {
    matcher: Matcher,
    proxy: usize,
}

enum Matcher {
    Domain(String),
    DomainSuffix(String),
    DomainKeyword(String),
    Ip { network: IpNet, no_resolve: bool },
    DestinationPort { first: u16, last: u16 },
    Match,
}

fn parse_port(port: &str) -> Result<u16> {
    if port.is_empty() || !port.bytes().all(|byte| byte.is_ascii_digit()) {
        bail!("DST-PORT requires a decimal port or port range");
    }
    let port: u16 = port
        .parse()
        .map_err(|_| anyhow!("DST-PORT must be between 1 and 65535"))?;
    if port == 0 {
        bail!("DST-PORT must be between 1 and 65535");
    }
    Ok(port)
}

fn canonical_domain(domain: &str) -> String {
    domain
        .strip_suffix('.')
        .unwrap_or(domain)
        .to_ascii_lowercase()
}

impl Rule {
    fn parse(source: &str, names: &HashMap<String, usize>) -> Result<Self> {
        let fields: Vec<_> = source
            .split(',')
            .take(5)
            .map(|field| field.trim_matches([' ', '\t']))
            .collect();
        let (matcher, name) = match fields.as_slice() {
            ["MATCH", name] => (Matcher::Match, *name),
            [
                kind @ ("DOMAIN" | "DOMAIN-SUFFIX" | "DOMAIN-KEYWORD"),
                payload,
                name,
            ] => {
                if *kind != "DOMAIN-KEYWORD" {
                    Target::new(*payload, 1).map_err(|_| {
                        anyhow!("domain rule payload must be a valid ASCII DNS name")
                    })?;
                }
                let payload = canonical_domain(payload);
                if payload.is_empty()
                    || !payload.is_ascii()
                    || payload
                        .bytes()
                        .any(|byte| byte.is_ascii_whitespace() || byte.is_ascii_control())
                {
                    bail!(
                        "domain rule payload must be nonempty ASCII without whitespace or control characters"
                    );
                }
                let matcher = match *kind {
                    "DOMAIN" => Matcher::Domain(payload),
                    "DOMAIN-SUFFIX" => Matcher::DomainSuffix(payload),
                    _ => Matcher::DomainKeyword(payload),
                };
                (matcher, *name)
            }
            [kind @ ("IP-CIDR" | "IP-CIDR6"), payload, name]
            | [kind @ ("IP-CIDR" | "IP-CIDR6"), payload, name, "no-resolve"] => {
                let network: IpNet = payload
                    .parse()
                    .map_err(|_| anyhow!("IP rule requires a valid CIDR network"))?;
                if (*kind == "IP-CIDR") != network.addr().is_ipv4() {
                    bail!("IP-CIDR requires IPv4; IP-CIDR6 requires IPv6");
                }
                (
                    Matcher::Ip {
                        network,
                        no_resolve: fields.len() == 4,
                    },
                    *name,
                )
            }
            ["DST-PORT", payload, name] => {
                let (first, last) = payload.split_once('-').unwrap_or((payload, payload));
                let first = parse_port(first)?;
                let last = parse_port(last)?;
                if first > last {
                    bail!("DST-PORT range must be ascending");
                }
                (Matcher::DestinationPort { first, last }, *name)
            }
            _ => bail!(
                "unsupported or invalid rule; use DOMAIN, DOMAIN-SUFFIX, DOMAIN-KEYWORD, IP-CIDR, IP-CIDR6, DST-PORT or MATCH"
            ),
        };
        let proxy = *names
            .get(name)
            .ok_or_else(|| anyhow!("rule references an unknown proxy or group"))?;
        Ok(Self { matcher, proxy })
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
struct RawConfig {
    #[serde(default, deserialize_with = "bounded::<_, _, MAX_PROXIES>")]
    proxies: Vec<RawProxy>,
    #[serde(default, deserialize_with = "bounded::<_, _, MAX_GROUPS>")]
    proxy_groups: Vec<RawGroup>,
    #[serde(default, deserialize_with = "bounded::<_, _, MAX_RULES>")]
    rules: Vec<String>,
    #[serde(default)]
    allow_lan: bool,
    #[serde(default, deserialize_with = "present")]
    bind_address: Option<String>,
    #[serde(default, deserialize_with = "present")]
    mixed_port: Option<u16>,
    #[serde(default, deserialize_with = "present")]
    mode: Option<String>,
    #[serde(default, deserialize_with = "present")]
    log_level: Option<String>,
}

// Optional means absent, not an explicitly null declaration.
fn present<'de, D, T>(deserializer: D) -> std::result::Result<Option<T>, D::Error>
where
    D: serde::Deserializer<'de>,
    T: Deserialize<'de>,
{
    T::deserialize(deserializer).map(Some)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
struct RawGroup {
    name: String,
    #[serde(rename = "type")]
    kind: String,
    #[serde(deserialize_with = "bounded::<_, _, MAX_MEMBERS>")]
    proxies: Vec<String>,
}

// Validate every edge, then flatten first-member selection to a concrete proxy.
// The explicit DFS stack is bounded by group count, not the process call stack.
fn resolve_groups(
    groups: Vec<RawGroup>,
    names: &mut HashMap<String, usize>,
    proxy_count: usize,
) -> Result<()> {
    for (index, group) in groups.iter().enumerate() {
        validate_name(&group.name)?;
        if group.kind != "select" || group.proxies.is_empty() {
            bail!("proxy-group must be select with at least one member");
        }
        if names
            .insert(group.name.clone(), proxy_count + index)
            .is_some()
        {
            bail!("duplicate or reserved proxy/group name");
        }
    }
    let edges: Vec<Vec<usize>> = groups
        .iter()
        .map(|group| {
            group
                .proxies
                .iter()
                .map(|member| {
                    names
                        .get(member)
                        .copied()
                        .ok_or_else(|| anyhow!("proxy-group references an unknown proxy or group"))
                })
                .collect()
        })
        .collect::<Result<_>>()?;
    let total = proxy_count + groups.len();
    let mut state = vec![0_u8; total];
    state[..proxy_count].fill(2);
    let mut selected: Vec<usize> = (0..total).collect();
    let mut stack = Vec::with_capacity(groups.len());
    for root in proxy_count..total {
        if state[root] == 2 {
            continue;
        }
        state[root] = 1;
        stack.push((root, 0));
        while let Some(&(node, next)) = stack.last() {
            let members = &edges[node - proxy_count];
            if next == members.len() {
                selected[node] = selected[members[0]];
                state[node] = 2;
                stack.pop();
                continue;
            }
            stack.last_mut().expect("active DFS frame").1 += 1;
            let child = members[next];
            match state[child] {
                0 => {
                    state[child] = 1;
                    stack.push((child, 0));
                }
                1 => bail!("proxy-group cycle detected, including unselected branches"),
                _ => {}
            }
        }
    }
    for (index, group) in groups.into_iter().enumerate() {
        names.insert(group.name, selected[proxy_count + index]);
    }
    Ok(())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
struct RawProxy {
    name: String,
    #[serde(rename = "type")]
    kind: String,
    server: String,
    port: u16,
    password: String,
    #[serde(default, deserialize_with = "present")]
    cipher: Option<String>,
    #[serde(default, deserialize_with = "present")]
    sni: Option<String>,
    #[serde(default, deserialize_with = "present")]
    skip_cert_verify: Option<bool>,
    #[serde(default, deserialize_with = "present")]
    tls: Option<bool>,
    #[serde(default, deserialize_with = "present")]
    network: Option<String>,
    #[serde(default)]
    udp: bool,
}

impl RawProxy {
    fn build(self) -> Result<Proxy> {
        if self.password.is_empty() || self.password.chars().any(char::is_control) {
            bail!("proxy password must be nonempty and contain no control characters");
        }
        Target::new(self.server.clone(), self.port).map_err(|_| {
            anyhow!("proxy server/port must be a valid IP or ASCII DNS name and nonzero port")
        })?;
        if self.udp
            || self
                .network
                .as_deref()
                .is_some_and(|network| network != "tcp")
        {
            bail!("only TCP proxy transport is supported; disable UDP and use network: tcp");
        }
        let kind = match self.kind.as_str() {
            "ss" => {
                if self.tls == Some(true) || self.sni.is_some() || self.skip_cert_verify.is_some() {
                    bail!("Shadowsocks TLS metadata is unsupported");
                }
                let cipher = match self.cipher.as_deref() {
                    Some("aes-128-gcm") => "aes-128-gcm",
                    Some("aes-256-gcm") => "aes-256-gcm",
                    Some("chacha20-ietf-poly1305" | "chacha20-poly1305") => {
                        "chacha20-ietf-poly1305"
                    }
                    _ => bail!("Shadowsocks requires a supported classic AEAD cipher"),
                };
                ProxyKind::Shadowsocks {
                    server: self.server,
                    port: self.port,
                    password: self.password,
                    cipher: cipher.into(),
                }
            }
            "trojan" => {
                if self.tls == Some(false) || self.cipher.is_some() {
                    bail!("Trojan requires native TLS without cipher metadata");
                }
                if let Some(sni) = &self.sni {
                    if sni.ends_with('.') || sni.parse::<IpAddr>().is_ok() {
                        bail!(
                            "Trojan SNI must be a DNS hostname without a trailing root dot, not an IP address"
                        );
                    }
                    Target::new(sni.clone(), 1)
                        .map_err(|_| anyhow!("Trojan SNI must be a valid ASCII DNS hostname"))?;
                } else if self.skip_cert_verify != Some(true)
                    && self.server.parse::<IpAddr>().is_ok()
                {
                    bail!(
                        "verified Trojan IP server requires SNI matching the certificate's DNS hostname"
                    );
                }
                let tls_name = self.sni.as_deref().unwrap_or(&self.server);
                rustls::pki_types::ServerName::try_from(
                    tls_name.strip_suffix('.').unwrap_or(tls_name),
                )
                .map_err(|_| {
                    anyhow!("invalid Trojan TLS server name; configure a valid SNI hostname")
                })?;
                ProxyKind::Trojan {
                    server: self.server,
                    port: self.port,
                    password: self.password,
                    sni: self.sni,
                    skip_cert_verify: self.skip_cert_verify.unwrap_or(false),
                }
            }
            _ => bail!("unsupported proxy type; only ss and trojan are supported"),
        };
        Ok(Proxy {
            name: self.name,
            kind,
        })
    }
}

fn validate_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.trim() != name
        || name.contains(',')
        || name.chars().any(char::is_control)
    {
        bail!(
            "proxy/group name must be nonempty, unpadded and contain no commas or control characters"
        );
    }
    Ok(())
}

pub struct Proxy {
    pub name: String,
    pub kind: ProxyKind,
}

pub enum ProxyKind {
    Direct,
    Reject,
    Shadowsocks {
        server: String,
        port: u16,
        password: String,
        cipher: String,
    },
    Trojan {
        server: String,
        port: u16,
        password: String,
        sni: Option<String>,
        skip_cert_verify: bool,
    },
}

impl Config {
    pub fn parse(source: &str) -> Result<Self> {
        if source.len() > MAX_SOURCE_BYTES {
            bail!("configuration exceeds the 16 MiB source limit");
        }
        let options = serde_saphyr::options! {
            duplicate_keys: serde_saphyr::DuplicateKeyPolicy::Error,
            merge_keys: serde_saphyr::MergeKeyPolicy::Error,
            strict_booleans: true,
            reject_unsupported_tags: true,
            emit_comments: false,
            budget: serde_saphyr::budget! {
                max_depth: 16,
                flow_nesting_limit: 16,
                max_events: 6_000_000,
                max_nodes: 6_000_000,
                max_total_scalar_bytes: MAX_SOURCE_BYTES,
                max_documents: 1,
                max_aliases: 0,
                max_anchors: 0,
                max_merge_keys: 0,
                max_inclusion_depth: 0,
            },
        };
        // Parser diagnostics can contain source snippets and credentials. Do not retain them.
        let Mapping(raw): Mapping<RawConfig> = serde_saphyr::from_str_with_options(source, options)
            .map_err(|_| anyhow!("invalid configuration YAML: check supported fields, types, duplicates and resource limits"))?;
        if raw.mixed_port == Some(0) {
            bail!("mixed-port must be between 1 and 65535; listener port is required on the CLI");
        }
        if raw.mode.as_deref().is_some_and(|mode| mode != "rule") {
            bail!("only mode: rule is supported");
        }
        if raw.log_level.as_deref().is_some_and(|level| {
            !matches!(level, "silent" | "error" | "warning" | "info" | "debug")
        }) {
            bail!("log-level must be silent, error, warning, info or debug");
        }
        let bind_address = match raw.bind_address.as_deref() {
            Some("*") => IpAddr::from([0, 0, 0, 0]),
            Some(address) => address
                .parse::<IpAddr>()
                .map_err(|_| anyhow!("bind-address must be an IP address or '*'"))?,
            None if raw.allow_lan => IpAddr::from([0, 0, 0, 0]),
            None => IpAddr::from([127, 0, 0, 1]),
        };
        if !raw.allow_lan && !bind_address.is_loopback() {
            bail!("non-loopback bind-address requires allow-lan: true");
        }
        let mut proxies = vec![
            Proxy {
                name: "DIRECT".into(),
                kind: ProxyKind::Direct,
            },
            Proxy {
                name: "REJECT".into(),
                kind: ProxyKind::Reject,
            },
        ];
        for proxy in raw.proxies {
            proxies.push(proxy.build()?);
        }
        let mut names = HashMap::new();
        for (index, proxy) in proxies.iter().enumerate() {
            validate_name(&proxy.name)?;
            if names.insert(proxy.name.clone(), index).is_some() {
                bail!("duplicate or reserved proxy/group name");
            }
        }
        resolve_groups(raw.proxy_groups, &mut names, proxies.len())?;
        let mut rules = Vec::new();
        for rule in raw.rules {
            rules.push(Rule::parse(&rule, &names)?);
        }
        Ok(Self {
            dns: Arc::new(Dns::system()),
            bind_address,
            proxies,
            rules,
        })
    }

    pub fn with_dns(mut self, dns: Dns) -> Self {
        self.dns = Arc::new(dns);
        self
    }

    pub fn bind_address(&self) -> IpAddr {
        self.bind_address
    }

    pub fn proxies(&self) -> &[Proxy] {
        &self.proxies
    }

    pub async fn route(&self, target: &Target) -> Result<Route<'_>> {
        let literal_ip = target.host().parse::<IpAddr>().ok();
        let domain = literal_ip
            .is_none()
            .then(|| canonical_domain(target.host()));
        let mut resolved: Option<Vec<IpAddr>> = None;
        for rule in &self.rules {
            let mut pinned = None;
            let matched = match &rule.matcher {
                Matcher::Match => true,
                Matcher::DestinationPort { first, last } => {
                    (*first..=*last).contains(&target.port())
                }
                Matcher::Ip {
                    network,
                    no_resolve,
                } => {
                    if let Some(ip) = literal_ip {
                        network.contains(&ip)
                    } else if *no_resolve {
                        false
                    } else {
                        if resolved.is_none() {
                            resolved = Some(self.dns.resolve(target).await?);
                        }
                        pinned = resolved
                            .as_ref()
                            .expect("DNS lookup completed")
                            .iter()
                            .copied()
                            .find(|ip| network.contains(ip));
                        pinned.is_some()
                    }
                }
                Matcher::Domain(expected) => {
                    domain.as_ref().is_some_and(|domain| domain == expected)
                }
                Matcher::DomainSuffix(suffix) => domain.as_ref().is_some_and(|domain| {
                    domain == suffix
                        || domain
                            .strip_suffix(suffix)
                            .is_some_and(|prefix| prefix.ends_with('.'))
                }),
                Matcher::DomainKeyword(keyword) => domain
                    .as_ref()
                    .is_some_and(|domain| domain.contains(keyword)),
            };
            if matched {
                let pinned = pinned.or_else(|| resolved.as_ref().map(|addresses| addresses[0]));
                return Ok(Route {
                    proxy: &self.proxies[rule.proxy],
                    target: match pinned {
                        Some(ip) => Target::new(ip.to_string(), target.port())?,
                        None => target.clone(),
                    },
                });
            }
        }
        bail!("no routing rule matched; connection denied")
    }
}
