use std::{
    collections::{BTreeMap, HashMap},
    net::{IpAddr, SocketAddr},
    sync::{Arc, RwLock},
};

use anyhow::{Result, anyhow, bail};
use ipnet::IpNet;
use serde::Deserialize;

use crate::{dns::Dns, target::Target};

pub mod diagnostics;

#[path = "config_provider.rs"]
mod provider;
pub(crate) use provider::{MAX_DOCUMENT_DEPTH, on_document_stack};
pub use provider::{
    ProviderSyncPolicy, capture_file_assets, fetch_http_assets, parse_document, parse_with_assets,
    sync_http_assets,
};

const MAX_SOURCE_BYTES: usize = 16 * 1024 * 1024;
const MAX_PROXIES: usize = 4096;
const MAX_GROUPS: usize = 1024;
const MAX_MIXED_PROXIES: usize = MAX_PROXIES + MAX_GROUPS;
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
    groups: Vec<Group>,
    selections: RwLock<Vec<usize>>,
    mode: String,
    controller: Option<SocketAddr>,
    secret: String,
    document: serde_json::Value,
}

struct Group {
    name: String,
    members: Vec<usize>,
}

// Consumers must dial/encode this target, never the original unresolved destination.
pub struct Route<'a> {
    pub proxy: &'a Proxy,
    pub target: Target,
}

#[derive(Default)]
pub struct MatchContext<'a> {
    pub source_ip: Option<IpAddr>,
    pub source_port: Option<u16>,
    pub process_name: Option<&'a str>,
}

#[derive(Clone)]
struct Rule {
    matcher: Matcher,
    proxy: usize,
    kind: String,
    payload: String,
}

#[derive(Clone)]
enum Matcher {
    Domain(String),
    DomainSuffix(String),
    DomainKeyword(String),
    Ip { network: IpNet, no_resolve: bool },
    DestinationPort { first: u16, last: u16 },
    SourcePort { first: u16, last: u16 },
    SourceIp(IpNet),
    ProcessName(String),
    GeoIp { country: String, no_resolve: bool },
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
            ["SRC-IP-CIDR", payload, name] => {
                let network: IpNet = payload
                    .parse()
                    .map_err(|_| anyhow!("source IP rule requires a valid IPv4 CIDR network"))?;
                if !network.addr().is_ipv4() {
                    bail!("SRC-IP-CIDR requires IPv4");
                }
                (Matcher::SourceIp(network), *name)
            }
            ["PROCESS-NAME", payload, name] if !payload.is_empty() => {
                (Matcher::ProcessName((*payload).into()), *name)
            }
            ["GEOIP", country, name] | ["GEOIP", country, name, "no-resolve"]
                if !country.is_empty() =>
            {
                (
                    Matcher::GeoIp {
                        country: (*country).into(),
                        no_resolve: fields.len() == 4,
                    },
                    *name,
                )
            }
            [kind @ ("DST-PORT" | "SRC-PORT"), payload, name] => {
                let (first, last) = payload.split_once('-').unwrap_or((payload, payload));
                let first = parse_port(first)?;
                let last = parse_port(last)?;
                if first > last {
                    bail!("DST-PORT range must be ascending");
                }
                (
                    if *kind == "DST-PORT" {
                        Matcher::DestinationPort { first, last }
                    } else {
                        Matcher::SourcePort { first, last }
                    },
                    *name,
                )
            }
            _ => bail!(
                "unsupported or invalid rule; PROCESS-PATH and recursive RULE-SET are not supported"
            ),
        };
        let proxy = *names
            .get(name)
            .ok_or_else(|| anyhow!("rule references an unknown proxy or group"))?;
        Ok(Self {
            matcher,
            proxy,
            kind: fields[0].into(),
            payload: if fields[0] == "MATCH" {
                String::new()
            } else {
                fields[1].into()
            },
        })
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
struct RawConfig {
    #[serde(default, deserialize_with = "bounded::<_, _, MAX_MIXED_PROXIES>")]
    proxies: Vec<RawEntry>,
    #[serde(default, deserialize_with = "bounded::<_, _, MAX_GROUPS>")]
    proxy_groups: Vec<RawGroup>,
    #[serde(default, deserialize_with = "bounded::<_, _, MAX_RULES>")]
    rules: Vec<String>,
    #[serde(default, deserialize_with = "provider_map")]
    rule_providers: BTreeMap<String, provider::Provider>,
    #[serde(default)]
    allow_lan: bool,
    #[serde(default, deserialize_with = "present")]
    bind_address: Option<String>,
    #[serde(default, deserialize_with = "present")]
    mixed_port: Option<u16>,
    #[serde(default, deserialize_with = "present")]
    port: Option<u16>,
    #[serde(default, deserialize_with = "present")]
    socks_port: Option<u16>,
    #[serde(default, deserialize_with = "present")]
    mode: Option<String>,
    #[serde(default, deserialize_with = "present")]
    log_level: Option<String>,
    #[serde(default)]
    external_controller: Option<String>,
    #[serde(default)]
    secret: Option<String>,
}

fn provider_map<'de, D: serde::Deserializer<'de>>(
    deserializer: D,
) -> std::result::Result<BTreeMap<String, provider::Provider>, D::Error> {
    Mapping::<BTreeMap<String, provider::Provider>>::deserialize(deserializer)
        .map(|mapping| mapping.0)
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
#[serde(untagged)]
enum RawEntry {
    Proxy(RawProxy),
    Group(RawGroup),
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

// Validate every edge while retaining immutable group definitions for dynamic selection.
// The explicit DFS stack is bounded by group count, not the process call stack.
fn resolve_groups(
    groups: Vec<RawGroup>,
    names: &mut HashMap<String, usize>,
    proxy_count: usize,
) -> Result<Vec<Group>> {
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
    Ok(groups
        .into_iter()
        .zip(edges)
        .map(|(group, members)| Group {
            name: group.name,
            members,
        })
        .collect())
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields, rename_all = "kebab-case")]
struct RawProxy {
    name: String,
    #[serde(rename = "type")]
    kind: String,
    #[serde(default)]
    server: String,
    #[serde(default)]
    port: u16,
    #[serde(default)]
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
    #[serde(default, deserialize_with = "present")]
    plugin: Option<String>,
    #[serde(default, alias = "plugin_opts", deserialize_with = "present")]
    plugin_opts: Option<RawObfs>,
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct RawObfs {
    mode: String,
    host: String,
}

impl RawProxy {
    fn build(self) -> Result<Proxy> {
        if self
            .network
            .as_deref()
            .is_some_and(|network| network != "tcp")
        {
            bail!("only native proxy transport is supported; use network: tcp");
        }
        let obfs = match (self.plugin.as_deref(), self.plugin_opts) {
            (None, None) => None,
            (Some("obfs" | "obfs-local"), Some(options)) if self.kind == "ss" => {
                if options.mode != "http"
                    || options.host.is_empty()
                    || options.host.len() > 255
                    || options
                        .host
                        .bytes()
                        .any(|byte| matches!(byte, 0 | b'\r' | b'\n'))
                {
                    bail!(
                        "simple-obfs requires mode: http and a nonempty host of at most 255 bytes without NUL/CR/LF"
                    );
                }
                Some(ObfsHttp { host: options.host })
            }
            _ => bail!("only Shadowsocks obfs/obfs-local with explicit HTTP options is supported"),
        };
        if matches!(self.kind.as_str(), "direct" | "reject") {
            return Ok(Proxy {
                name: self.name,
                kind: if self.kind == "direct" {
                    ProxyKind::Direct
                } else {
                    ProxyKind::Reject
                },
                udp: self.udp,
                obfs: None,
            });
        }
        if self.password.is_empty() || self.password.chars().any(char::is_control) {
            bail!("proxy password must be nonempty and contain no control characters");
        }
        Target::new(self.server.clone(), self.port).map_err(|_| {
            anyhow!("proxy server/port must be a valid IP or ASCII DNS name and nonzero port")
        })?;
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
            _ => bail!("unsupported proxy type; only direct, reject, ss and trojan are supported"),
        };
        Ok(Proxy {
            name: self.name,
            kind,
            udp: self.udp,
            obfs,
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
    pub udp: bool,
    pub obfs: Option<ObfsHttp>,
}

pub struct ObfsHttp {
    pub host: String,
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
        Self::parse_with_assets(source, &BTreeMap::new())
    }

    pub fn parse_with_assets(source: &str, assets: &BTreeMap<String, Vec<u8>>) -> Result<Self> {
        Self::parse_inner(source, Some(assets))
    }

    /// Doctor validates declarations without fetching or opening provider assets.
    /// This result cannot be used as a routable runtime configuration.
    pub fn validate_declarations(source: &str) -> Result<()> {
        Self::parse_inner(source, None).map(|_| ())
    }

    fn parse_inner(source: &str, assets: Option<&BTreeMap<String, Vec<u8>>>) -> Result<Self> {
        let document = parse_document(source)?;
        // Preserve resource failures before untagged deserialization erases their cause.
        for (field, limit) in [
            ("proxies", MAX_MIXED_PROXIES),
            ("proxy-groups", MAX_GROUPS),
            ("rules", MAX_RULES),
        ] {
            if document
                .get(field)
                .and_then(serde_json::Value::as_array)
                .is_some_and(|entries| entries.len() > limit)
            {
                bail!("configuration collection limit exceeded");
            }
        }
        for field in ["proxies", "proxy-groups"] {
            if let Some(entries) = document.get(field).and_then(serde_json::Value::as_array) {
                for entry in entries {
                    if entry
                        .get("proxies")
                        .and_then(serde_json::Value::as_array)
                        .is_some_and(|members| members.len() > MAX_MEMBERS)
                    {
                        bail!("proxy-group member limit exceeded");
                    }
                }
            }
        }
        let raw = RawConfig::deserialize(&document).map_err(|_| {
            anyhow!("invalid configuration: check supported fields, types and collection limits")
        })?;
        if raw.mixed_port.unwrap_or(0) == 0
            && (raw.port.unwrap_or(0) != 0 || raw.socks_port.unwrap_or(0) != 0)
        {
            bail!(
                "standalone port/socks-port listeners are unsupported; use mixed-port or the CLI port override"
            );
        }
        if raw
            .mode
            .as_deref()
            .is_some_and(|mode| !matches!(mode, "rule" | "global" | "direct"))
        {
            bail!("mode must be rule, global or direct");
        }
        let controller = raw
            .external_controller
            .as_deref()
            .map(|endpoint| {
                let port = endpoint.strip_prefix("127.0.0.1:").ok_or_else(|| {
                    anyhow!("external-controller must be explicit 127.0.0.1:<port>")
                })?;
                Ok::<_, anyhow::Error>(SocketAddr::from(([127, 0, 0, 1], parse_port(port)?)))
            })
            .transpose()?;
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
                udp: true,
                obfs: None,
            },
            Proxy {
                name: "REJECT".into(),
                kind: ProxyKind::Reject,
                udp: false,
                obfs: None,
            },
        ];
        let mut raw_groups = Vec::new();
        for entry in raw.proxies {
            match entry {
                RawEntry::Proxy(proxy) => {
                    if proxies.len() == MAX_PROXIES + 2 {
                        bail!("proxy count limit exceeded");
                    }
                    proxies.push(proxy.build()?);
                }
                RawEntry::Group(group) => raw_groups.push(group),
            }
        }
        raw_groups.extend(raw.proxy_groups);
        if raw_groups.len() > MAX_GROUPS {
            bail!("proxy-group count limit exceeded");
        }
        let mut names = HashMap::new();
        for (index, proxy) in proxies.iter().enumerate() {
            validate_name(&proxy.name)?;
            if names.insert(proxy.name.clone(), index).is_some() {
                bail!("duplicate or reserved proxy/group name");
            }
        }
        let groups = resolve_groups(raw_groups, &mut names, proxies.len())?;
        let rules = if let Some(assets) = assets {
            provider::expand(&raw.rules, &raw.rule_providers, assets, &names)?
        } else {
            provider::validate_rule_declarations(&raw.rules, &raw.rule_providers, &names)?;
            Vec::new()
        };
        Ok(Self {
            dns: Arc::new(Dns::system()),
            bind_address,
            proxies,
            rules,
            selections: RwLock::new(vec![0; groups.len()]),
            groups,
            mode: raw.mode.unwrap_or_else(|| "rule".into()),
            controller,
            secret: raw.secret.unwrap_or_default(),
            document,
        })
    }

    pub fn document(&self) -> &serde_json::Value {
        &self.document
    }

    pub fn controller_endpoint(&self) -> Option<SocketAddr> {
        self.controller
    }

    pub fn secret(&self) -> &str {
        &self.secret
    }

    // Zig validates and reports this metadata but does not branch its rule engine on mode.
    pub fn mode(&self) -> &str {
        &self.mode
    }

    fn node_name(&self, index: usize) -> &str {
        if index < self.proxies.len() {
            &self.proxies[index].name
        } else {
            &self.groups[index - self.proxies.len()].name
        }
    }

    fn resolve_proxy(&self, mut index: usize) -> &Proxy {
        let selections = self
            .selections
            .read()
            .unwrap_or_else(|error| error.into_inner());
        // All edges were checked for cycles at construction, including inactive members.
        for _ in 0..=self.groups.len() {
            if index < self.proxies.len() {
                return &self.proxies[index];
            }
            let group = index - self.proxies.len();
            index = self.groups[group].members[selections[group]];
        }
        unreachable!("validated group graph is acyclic")
    }

    pub(crate) fn group_names(&self) -> impl Iterator<Item = &str> {
        self.groups.iter().map(|group| group.name.as_str())
    }

    pub fn selected(&self) -> BTreeMap<String, String> {
        let selections = self
            .selections
            .read()
            .unwrap_or_else(|error| error.into_inner());
        self.groups
            .iter()
            .zip(selections.iter())
            .map(|(group, &selected)| {
                (
                    group.name.clone(),
                    self.node_name(group.members[selected]).to_owned(),
                )
            })
            .collect()
    }

    fn selection(&self, group: &str, proxy: &str) -> Result<(usize, usize)> {
        let index = self
            .groups
            .iter()
            .position(|candidate| candidate.name == group)
            .ok_or_else(|| anyhow!("unknown selectable proxy-group"))?;
        let member = self.groups[index]
            .members
            .iter()
            .position(|&node| self.node_name(node) == proxy)
            .ok_or_else(|| anyhow!("selection must be a direct member of the proxy-group"))?;
        Ok((index, member))
    }

    // A persisted snapshot replaces all selections; omitted groups return to their first member.
    // Validation completes before publishing, so invalid snapshots never partially apply.
    pub fn set_selections(&self, selections: &BTreeMap<String, String>) -> Result<()> {
        if selections.len() > MAX_GROUPS {
            bail!("persisted selection count limit exceeded");
        }
        let mut next = vec![0; self.groups.len()];
        for (group, proxy) in selections {
            let (index, member) = self.selection(group, proxy)?;
            next[index] = member;
        }
        *self
            .selections
            .write()
            .unwrap_or_else(|error| error.into_inner()) = next;
        Ok(())
    }

    pub fn select(&self, group: &str, proxy: &str) -> Result<()> {
        let (index, member) = self.selection(group, proxy)?;
        self.selections
            .write()
            .unwrap_or_else(|error| error.into_inner())[index] = member;
        Ok(())
    }

    pub fn proxies_json(&self) -> serde_json::Value {
        let proxies: Vec<_> = self.proxies.iter().skip(2).map(|proxy| {
            let (kind, server, port) = match &proxy.kind {
                ProxyKind::Shadowsocks { server, port, .. } => ("Shadowsocks", server.as_str(), *port),
                ProxyKind::Trojan { server, port, .. } => ("Trojan", server.as_str(), *port),
                ProxyKind::Direct => ("Direct", "", 0),
                ProxyKind::Reject => ("Reject", "", 0),
            };
            serde_json::json!({"name": proxy.name, "type": kind, "server": server, "port": port})
        }).collect();
        serde_json::json!({"proxies": proxies})
    }

    pub fn rules_json(&self) -> serde_json::Value {
        let rules: Vec<_> = self.rules.iter().map(|rule| {
            serde_json::json!({"type": rule.kind, "payload": rule.payload, "target": self.node_name(rule.proxy)})
        }).collect();
        serde_json::json!({"rules": rules})
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
        self.route_with_context(target, &MatchContext::default())
            .await
    }

    pub async fn route_with_context(
        &self,
        target: &Target,
        context: &MatchContext<'_>,
    ) -> Result<Route<'_>> {
        let literal_ip = target.host().parse::<IpAddr>().ok();
        let domain = literal_ip
            .is_none()
            .then(|| canonical_domain(target.host()));
        let mut resolved: Option<Vec<IpAddr>> = None;
        for rule in &self.rules {
            let mut pinned = None;
            let matched = match &rule.matcher {
                Matcher::Match => true,
                Matcher::SourceIp(network) => {
                    context.source_ip.is_some_and(|ip| network.contains(&ip))
                }
                Matcher::SourcePort { first, last } => context
                    .source_port
                    .is_some_and(|port| (*first..=*last).contains(&port)),
                Matcher::ProcessName(name) => {
                    context.process_name.is_some_and(|process| process == name)
                }
                Matcher::GeoIp {
                    country,
                    no_resolve,
                } => {
                    if let Some(ip) = literal_ip {
                        geoip_country(ip) == Some(country.as_str())
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
                            .find(|&ip| geoip_country(ip) == Some(country.as_str()));
                        pinned.is_some()
                    }
                }
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
                    proxy: self.resolve_proxy(rule.proxy),
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

// Exact ordered SimpleGeoIp table from src/geoip.zig. Overlaps intentionally use first match.
// This is a compatibility heuristic, not an authoritative geolocation database.
fn geoip_country(ip: IpAddr) -> Option<&'static str> {
    let IpAddr::V4(ip) = ip else {
        return None;
    };
    let ip = u32::from(ip);
    const ENTRIES: &[(u32, u32, &str)] = &[
        (0x01000000, 0x01ffffff, "CN"),
        (0x0a000000, 0x0affffff, "CN"),
        (0x22300000, 0x223fffff, "CN"),
        (0x2e000000, 0x2effffff, "CN"),
        (0x3a800000, 0x3abfffff, "CN"),
        (0x3c000000, 0x3dffffff, "CN"),
        (0x3e000000, 0x3effffff, "CN"),
        (0x59300000, 0x593fffff, "CN"),
        (0x63000000, 0x63ffffff, "CN"),
        (0x67000000, 0x67ffffff, "CN"),
        (0xa0000000, 0xa000ffff, "CN"),
        (0xa1a80000, 0xa1a8ffff, "CN"),
        (0xac100000, 0xac1fffff, "CN"),
        (0xb7000000, 0xb7ffffff, "CN"),
        (0xbc000000, 0xbdffffff, "CN"),
        (0xc0000000, 0xc0ffffff, "CN"),
        (0xd8000000, 0xdfffffff, "CN"),
        (0x01000000, 0x01ffffff, "US"),
        (0x02000000, 0x02ffffff, "US"),
        (0x03000000, 0x03ffffff, "US"),
        (0x04000000, 0x04ffffff, "US"),
        (0x06000000, 0x07ffffff, "US"),
        (0x08000000, 0x08ffffff, "US"),
        (0x09000000, 0x09ffffff, "US"),
        (0x0b000000, 0x0bffffff, "US"),
        (0x0c000000, 0x0dffffff, "US"),
        (0x0e000000, 0x0effffff, "US"),
        (0x11000000, 0x11ffffff, "US"),
        (0x12000000, 0x12ffffff, "US"),
        (0x17000000, 0x17ffffff, "US"),
        (0x18000000, 0x18ffffff, "US"),
        (0x1a000000, 0x1affffff, "US"),
        (0x1b000000, 0x1bffffff, "US"),
        (0x1c000000, 0x1cffffff, "US"),
        (0x1d000000, 0x1dffffff, "US"),
        (0x1e000000, 0x1effffff, "US"),
        (0x1f000000, 0x1fffffff, "US"),
        (0x20000000, 0x20ffffff, "US"),
        (0x21000000, 0x21ffffff, "US"),
        (0x22000000, 0x22ffffff, "US"),
        (0x23000000, 0x23ffffff, "US"),
        (0x24000000, 0x24ffffff, "US"),
        (0x26000000, 0x26ffffff, "US"),
        (0x27000000, 0x27ffffff, "US"),
        (0x28000000, 0x28ffffff, "US"),
        (0x29000000, 0x29ffffff, "US"),
        (0x2a000000, 0x2affffff, "US"),
        (0x2b000000, 0x2bffffff, "US"),
        (0x2c000000, 0x2cffffff, "US"),
        (0x2d000000, 0x2dffffff, "US"),
        (0x2f000000, 0x2fffffff, "US"),
        (0x30000000, 0x30ffffff, "US"),
        (0x32000000, 0x32ffffff, "US"),
        (0x33000000, 0x33ffffff, "US"),
        (0x34000000, 0x35ffffff, "US"),
        (0x36000000, 0x37ffffff, "US"),
        (0x38000000, 0x39ffffff, "US"),
        (0x3f000000, 0x3fffffff, "US"),
        (0x44000000, 0x45ffffff, "US"),
        (0x47000000, 0x47ffffff, "US"),
        (0x48000000, 0x48ffffff, "US"),
        (0x49000000, 0x49ffffff, "US"),
        (0x4a000000, 0x4affffff, "US"),
        (0x4b000000, 0x4bffffff, "US"),
        (0x4c000000, 0x4cffffff, "US"),
        (0x4d000000, 0x4dffffff, "US"),
        (0x4e000000, 0x4fffffff, "US"),
        (0x50000000, 0x50ffffff, "US"),
        (0x52000000, 0x52ffffff, "US"),
        (0x53000000, 0x53ffffff, "US"),
        (0x54000000, 0x55ffffff, "US"),
        (0x8b000000, 0x8bffffff, "US"),
        (0x8d000000, 0x8dffffff, "US"),
        (0x8e000000, 0x8effffff, "US"),
        (0x91000000, 0x91ffffff, "US"),
        (0x96000000, 0x96ffffff, "US"),
        (0x98000000, 0x98ffffff, "US"),
        (0x99000000, 0x99ffffff, "US"),
        (0xc0000200, 0xc00002ff, "US"),
        (0xc0586300, 0xc05863ff, "US"),
        (0xc6120000, 0xc613ffff, "US"),
        (0xc7000000, 0xc7ffffff, "US"),
        (0x29000000, 0x29ffffff, "JP"),
        (0x51000000, 0x51ffffff, "JP"),
        (0x60000000, 0x60ffffff, "JP"),
        (0x76000000, 0x76ffffff, "JP"),
        (0x8a000000, 0x8affffff, "JP"),
        (0xa2000000, 0xa2ffffff, "JP"),
        (0xa9000000, 0xa9ffffff, "JP"),
        (0xc2000000, 0xc2ffffff, "JP"),
        (0xc5000000, 0xc5ffffff, "JP"),
        (0xc6000000, 0xc6ffffff, "JP"),
        (0x2b000000, 0x2bffffff, "HK"),
        (0x3b400000, 0x3b7fffff, "HK"),
        (0x57000000, 0x57ffffff, "HK"),
        (0x61000000, 0x61ffffff, "HK"),
        (0xa1000000, 0xa1ffffff, "HK"),
        (0xce000000, 0xceffffff, "HK"),
        (0xcf000000, 0xcfffffff, "HK"),
        (0x2f000000, 0x2fffffff, "SG"),
        (0x3e800000, 0x3e8fffff, "SG"),
        (0x67000000, 0x67ffffff, "SG"),
        (0x8c000000, 0x8cffffff, "SG"),
        (0xc1000000, 0xc1ffffff, "SG"),
        (0x3a000000, 0x3a3fffff, "KR"),
        (0x57000000, 0x57ffffff, "KR"),
        (0x7a000000, 0x7affffff, "KR"),
        (0xa5000000, 0xa5ffffff, "KR"),
        (0xd5000000, 0xd5ffffff, "KR"),
        (0xd9000000, 0xd9ffffff, "KR"),
        (0xe0000000, 0xe0ffffff, "KR"),
        (0x05000000, 0x05ffffff, "RU"),
        (0x1f000000, 0x1f1fffff, "RU"),
        (0x2d000000, 0x2dffffff, "RU"),
        (0x5f000000, 0x5fffffff, "RU"),
        (0x77000000, 0x77ffffff, "RU"),
        (0x7b000000, 0x7bffffff, "RU"),
        (0x85000000, 0x85ffffff, "RU"),
        (0x8f000000, 0x8fffffff, "RU"),
        (0x90000000, 0x90ffffff, "RU"),
        (0x92000000, 0x92ffffff, "RU"),
        (0x94000000, 0x94ffffff, "RU"),
        (0x9d000000, 0x9dffffff, "RU"),
        (0xb3000000, 0xb3ffffff, "RU"),
        (0xb7000000, 0xb7ffffff, "RU"),
        (0xc2000000, 0xc2ffffff, "RU"),
        (0xc7000000, 0xc7ffffff, "RU"),
        (0xcb000000, 0xcbffffff, "RU"),
        (0xd4000000, 0xd4ffffff, "RU"),
        (0xd8000000, 0xd8ffffff, "RU"),
        (0x02000000, 0x02ffffff, "GB"),
        (0x1e000000, 0x1effffff, "GB"),
        (0x5c000000, 0x5dffffff, "GB"),
        (0x81000000, 0x81ffffff, "GB"),
        (0x8b000000, 0x8bffffff, "GB"),
        (0xa3000000, 0xa3ffffff, "GB"),
        (0xb1000000, 0xb1ffffff, "GB"),
        (0xb2000000, 0xb2ffffff, "GB"),
        (0xb3000000, 0xb3ffffff, "GB"),
        (0xb8000000, 0xb8ffffff, "GB"),
        (0xb9000000, 0xb9ffffff, "GB"),
        (0xc3000000, 0xc3ffffff, "GB"),
        (0xc4000000, 0xc4ffffff, "GB"),
        (0x03000000, 0x03ffffff, "DE"),
        (0x2f000000, 0x2fffffff, "DE"),
        (0x4d000000, 0x4dffffff, "DE"),
        (0x53000000, 0x53ffffff, "DE"),
        (0x78000000, 0x79ffffff, "DE"),
        (0x87000000, 0x87ffffff, "DE"),
        (0x93000000, 0x93ffffff, "DE"),
        (0xa0000000, 0xa0ffffff, "DE"),
        (0xa4000000, 0xa4ffffff, "DE"),
        (0xae000000, 0xaeffffff, "DE"),
        (0xba000000, 0xbaffffff, "DE"),
        (0xc3000000, 0xc3ffffff, "DE"),
        (0x05000000, 0x05ffffff, "FR"),
        (0x50000000, 0x50ffffff, "FR"),
        (0x5a000000, 0x5affffff, "FR"),
        (0x5f000000, 0x5fffffff, "FR"),
        (0x81000000, 0x81ffffff, "FR"),
        (0x83000000, 0x83ffffff, "FR"),
        (0x88000000, 0x88ffffff, "FR"),
        (0x89000000, 0x89ffffff, "FR"),
        (0x90000000, 0x90ffffff, "FR"),
        (0x93000000, 0x93ffffff, "FR"),
        (0x9a000000, 0x9affffff, "FR"),
        (0xa7000000, 0xa7ffffff, "FR"),
        (0xa9000000, 0xa9ffffff, "FR"),
        (0xbc000000, 0xbcffffff, "FR"),
        (0xc0000000, 0xc0ffffff, "FR"),
        (0x01000000, 0x01ffffff, "AU"),
        (0x1e000000, 0x1effffff, "AU"),
        (0x27000000, 0x27ffffff, "AU"),
        (0x2e000000, 0x2effffff, "AU"),
        (0x3b000000, 0x3bffffff, "AU"),
        (0x61000000, 0x61ffffff, "AU"),
        (0x97000000, 0x97ffffff, "AU"),
        (0x9e000000, 0x9effffff, "AU"),
        (0xa5000000, 0xa5ffffff, "AU"),
        (0xb7000000, 0xb7ffffff, "AU"),
        (0xbd000000, 0xbdffffff, "AU"),
        (0xc0000000, 0xc0ffffff, "AU"),
        (0xc1000000, 0xc1ffffff, "AU"),
        (0xc7000000, 0xc7ffffff, "AU"),
        (0xce000000, 0xceffffff, "AU"),
        (0xd4000000, 0xd4ffffff, "AU"),
        (0xd9000000, 0xd9ffffff, "AU"),
        (0x02000000, 0x02ffffff, "CA"),
        (0x0a000000, 0x0affffff, "CA"),
        (0x1c000000, 0x1cffffff, "CA"),
        (0x1f000000, 0x1fffffff, "CA"),
        (0x24000000, 0x24ffffff, "CA"),
        (0x2f000000, 0x2fffffff, "CA"),
        (0x3a000000, 0x3affffff, "CA"),
        (0x47000000, 0x47ffffff, "CA"),
        (0x4a000000, 0x4affffff, "CA"),
        (0x54000000, 0x55ffffff, "CA"),
        (0x63000000, 0x63ffffff, "CA"),
        (0x64000000, 0x65ffffff, "CA"),
        (0x69000000, 0x69ffffff, "CA"),
        (0x6c000000, 0x6cffffff, "CA"),
        (0x71000000, 0x71ffffff, "CA"),
        (0x72000000, 0x72ffffff, "CA"),
        (0x7d000000, 0x7dffffff, "CA"),
        (0x80000000, 0x80ffffff, "CA"),
        (0x84000000, 0x84ffffff, "CA"),
        (0x86000000, 0x86ffffff, "CA"),
        (0x8c000000, 0x8cffffff, "CA"),
        (0x92000000, 0x92ffffff, "CA"),
        (0x96000000, 0x96ffffff, "CA"),
        (0x9a000000, 0x9affffff, "CA"),
        (0xa3000000, 0xa3ffffff, "CA"),
        (0xa6000000, 0xa6ffffff, "CA"),
        (0xa7000000, 0xa7ffffff, "CA"),
        (0xb2000000, 0xb2ffffff, "CA"),
        (0xb4000000, 0xb4ffffff, "CA"),
        (0xb8000000, 0xb8ffffff, "CA"),
        (0xc2000000, 0xc2ffffff, "CA"),
        (0xc3000000, 0xc3ffffff, "CA"),
        (0xc4000000, 0xc4ffffff, "CA"),
        (0xc5000000, 0xc5ffffff, "CA"),
        (0xc7000000, 0xc7ffffff, "CA"),
        (0xca000000, 0xcaffffff, "CA"),
        (0xd4000000, 0xd4ffffff, "CA"),
        (0xd6000000, 0xd6ffffff, "CA"),
        (0x05000000, 0x05ffffff, "NL"),
        (0x31000000, 0x31ffffff, "NL"),
        (0x4d000000, 0x4dffffff, "NL"),
        (0x81000000, 0x81ffffff, "NL"),
        (0x83000000, 0x83ffffff, "NL"),
        (0x91000000, 0x91ffffff, "NL"),
        (0x94000000, 0x94ffffff, "NL"),
        (0x9d000000, 0x9dffffff, "NL"),
        (0xa2000000, 0xa2ffffff, "NL"),
        (0xa9000000, 0xa9ffffff, "NL"),
        (0xba000000, 0xbaffffff, "NL"),
        (0xc0000000, 0xc0ffffff, "NL"),
        (0xc1000000, 0xc1ffffff, "NL"),
        (0xc2000000, 0xc2ffffff, "NL"),
        (0xc3000000, 0xc3ffffff, "NL"),
        (0x01000000, 0x01ffffff, "IN"),
        (0x2f000000, 0x2fffffff, "IN"),
        (0x59000000, 0x59ffffff, "IN"),
        (0x61000000, 0x61ffffff, "IN"),
        (0x9e000000, 0x9effffff, "IN"),
        (0xa4000000, 0xa4ffffff, "IN"),
        (0xc0000000, 0xc0ffffff, "IN"),
        (0x01000000, 0x01ffffff, "TW"),
        (0x3b400000, 0x3b7fffff, "TW"),
        (0x57000000, 0x57ffffff, "TW"),
        (0x61000000, 0x61ffffff, "TW"),
        (0xa1000000, 0xa1ffffff, "TW"),
        (0xce000000, 0xceffffff, "TW"),
        (0xcf000000, 0xcfffffff, "TW"),
        (0x01000000, 0x01ffffff, "BR"),
        (0x5f000000, 0x5fffffff, "BR"),
        (0x64000000, 0x65ffffff, "BR"),
        (0x8d000000, 0x8dffffff, "BR"),
        (0x96000000, 0x96ffffff, "BR"),
        (0xa9000000, 0xa9ffffff, "BR"),
        (0xb1000000, 0xb1ffffff, "BR"),
        (0xb2000000, 0xb2ffffff, "BR"),
        (0xb7000000, 0xb7ffffff, "BR"),
        (0xbd000000, 0xbdffffff, "BR"),
        (0xc0000000, 0xc0ffffff, "BR"),
        (0xc1000000, 0xc1ffffff, "BR"),
        (0xc2000000, 0xc2ffffff, "BR"),
        (0xc3000000, 0xc3ffffff, "BR"),
        (0xc4000000, 0xc4ffffff, "BR"),
        (0xc5000000, 0xc5ffffff, "BR"),
        (0xc7000000, 0xc7ffffff, "BR"),
        (0xc8000000, 0xc8ffffff, "BR"),
        (0xc9000000, 0xc9ffffff, "BR"),
        (0xca000000, 0xcaffffff, "BR"),
        (0xcb000000, 0xcbffffff, "BR"),
        (0xcc000000, 0xccffffff, "BR"),
        (0xcd000000, 0xcdffffff, "BR"),
        (0xce000000, 0xceffffff, "BR"),
        (0xcf000000, 0xcfffffff, "BR"),
    ];
    ENTRIES
        .iter()
        .find(|&&(start, end, _)| (start..=end).contains(&ip))
        .map(|entry| entry.2)
}
