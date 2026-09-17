use std::{
    cell::Cell,
    collections::{BTreeMap, HashMap},
    io::Read,
    path::{Component, Path},
    time::Duration,
};

use anyhow::{Result, anyhow, bail};
use serde::{
    Deserialize,
    de::{DeserializeSeed, Error as _, Visitor},
};
use serde_json::Value;

use super::{Config, MAX_RULES, MAX_SOURCE_BYTES, Mapping, Matcher, Rule};

// Zig counts nesting below the root collection, which itself occupies one frame.
pub(crate) const MAX_DOCUMENT_DEPTH: usize = 129;

const MAX_PROVIDERS: usize = 4096;
const MAX_AGGREGATE_BYTES: usize = 64 * 1024 * 1024;
const MAX_COLLECTION_ENTRIES: usize = 262144;

// Charge all nested mapping entries and sequence items, including extension data,
// before retaining their values. Parser depth and scalar budgets remain independent.
struct Document(Value);
struct ValueSeed<'a>(&'a Cell<usize>, usize);

fn charge<E: serde::de::Error>(remaining: &Cell<usize>) -> std::result::Result<(), E> {
    let next = remaining
        .get()
        .checked_sub(1)
        .ok_or_else(|| E::custom("YAML collection entry limit exceeded"))?;
    remaining.set(next);
    Ok(())
}

impl<'de> Deserialize<'de> for Document {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        ValueSeed(&Cell::new(MAX_COLLECTION_ENTRIES), 0)
            .deserialize(deserializer)
            .map(Self)
    }
}

impl<'de> DeserializeSeed<'de> for ValueSeed<'_> {
    type Value = Value;
    fn deserialize<D: serde::Deserializer<'de>>(
        self,
        deserializer: D,
    ) -> std::result::Result<Value, D::Error> {
        deserializer.deserialize_any(self)
    }
}

impl<'de> Visitor<'de> for ValueSeed<'_> {
    type Value = Value;
    fn expecting(&self, f: &mut std::fmt::Formatter) -> std::fmt::Result {
        f.write_str("bounded YAML data")
    }
    fn visit_unit<E: serde::de::Error>(self) -> std::result::Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_none<E: serde::de::Error>(self) -> std::result::Result<Value, E> {
        Ok(Value::Null)
    }
    fn visit_bool<E: serde::de::Error>(self, value: bool) -> std::result::Result<Value, E> {
        Ok(value.into())
    }
    fn visit_i64<E: serde::de::Error>(self, value: i64) -> std::result::Result<Value, E> {
        Ok(value.into())
    }
    fn visit_u64<E: serde::de::Error>(self, value: u64) -> std::result::Result<Value, E> {
        Ok(value.into())
    }
    fn visit_f64<E: serde::de::Error>(self, value: f64) -> std::result::Result<Value, E> {
        serde_json::Number::from_f64(value)
            .map(Value::Number)
            .ok_or_else(|| E::custom("non-finite YAML number"))
    }
    fn visit_str<E: serde::de::Error>(self, value: &str) -> std::result::Result<Value, E> {
        Ok(value.into())
    }
    fn visit_string<E: serde::de::Error>(self, value: String) -> std::result::Result<Value, E> {
        Ok(value.into())
    }
    fn visit_seq<A: serde::de::SeqAccess<'de>>(
        self,
        mut sequence: A,
    ) -> std::result::Result<Value, A::Error> {
        if self.1 >= MAX_DOCUMENT_DEPTH {
            return Err(A::Error::custom("YAML resource limit exceeded"));
        }
        struct Item<'a>(&'a Cell<usize>, usize);
        impl<'de> DeserializeSeed<'de> for Item<'_> {
            type Value = Value;
            fn deserialize<D: serde::Deserializer<'de>>(
                self,
                deserializer: D,
            ) -> std::result::Result<Value, D::Error> {
                charge::<D::Error>(self.0)?;
                ValueSeed(self.0, self.1).deserialize(deserializer)
            }
        }
        let mut items = Vec::new();
        while let Some(item) = sequence.next_element_seed(Item(self.0, self.1 + 1))? {
            items.push(item);
        }
        Ok(Value::Array(items))
    }
    fn visit_map<A: serde::de::MapAccess<'de>>(
        self,
        mut map: A,
    ) -> std::result::Result<Value, A::Error> {
        if self.1 >= MAX_DOCUMENT_DEPTH {
            return Err(A::Error::custom("YAML resource limit exceeded"));
        }
        let mut entries = serde_json::Map::new();
        while let Some(key) = map.next_key::<String>()? {
            charge::<A::Error>(self.0)?;
            if key == "<<" || entries.contains_key(&key) {
                return Err(A::Error::custom("duplicate or merge key"));
            }
            let value = map.next_value_seed(ValueSeed(self.0, self.1 + 1))?;
            entries.insert(key, value);
        }
        Ok(Value::Object(entries))
    }
}

// Serde's recursive visitors need more than a 2 MiB worker stack at Zig's limit.
// Keep ordinary documents on the caller stack; conservative lexical counting may
// overestimate quoted scalars, but never grants extra parser depth or byte budget.
pub(crate) fn on_document_stack<T: Send>(
    source: &str,
    parse: impl FnOnce() -> Result<T> + Send,
) -> Result<T> {
    let mut flow = 0usize;
    let mut line_work = 0usize;
    let mut deep = false;
    for byte in source.bytes() {
        match byte {
            b'[' | b'{' => flow = flow.saturating_add(1),
            b'\n' => line_work = 0,
            b' ' | b'\t' | b':' | b'-' => line_work += 1,
            _ => (),
        }
        if flow > 16 || line_work > 32 {
            deep = true;
            break;
        }
    }
    if !deep {
        return parse();
    }
    std::thread::scope(|scope| {
        std::thread::Builder::new()
            .name("config-parser".into())
            .stack_size(16 * 1024 * 1024)
            .spawn_scoped(scope, parse)?
            .join()
            .map_err(|_| anyhow!("configuration parser thread failed"))?
    })
}

fn yaml_value(source: &str) -> Result<Value> {
    if source.len() > MAX_SOURCE_BYTES {
        bail!("configuration/provider exceeds the 16 MiB source limit");
    }
    // Internally serialized documents are JSON. Reuse the bounded visitor, including
    // duplicate/merge-key rejection, and require EOF before accepting this fast path.
    // At most 262144 entries imply <= 524289 nodes and < 1600000 events; JSON's
    // decoded scalar bytes cannot exceed its bounded source bytes. No aliases/tags exist.
    // Non-integer numbers and literal Unicode retain YAML's scalar interpretation,
    // line-break normalization and character admission rules.
    fn exact_json_scalars(value: &Value) -> bool {
        match value {
            Value::Number(number) => number.is_i64(),
            Value::Array(items) => items.iter().all(exact_json_scalars),
            Value::Object(entries) => entries.values().all(exact_json_scalars),
            _ => true,
        }
    }
    if source.is_ascii()
        && !source.contains('\u{007f}')
        && source.trim_start().starts_with(['{', '['])
        && let Ok(Document(value)) = serde_json::from_str(source)
        && exact_json_scalars(&value)
    {
        return Ok(value);
    }
    on_document_stack(source, || yaml_value_inner(source))
}

fn yaml_value_inner(source: &str) -> Result<Value> {
    // JSON-looking flow YAML is still YAML; its entire stream must pass the same bounds.
    let options = serde_saphyr::options! {
        duplicate_keys: serde_saphyr::DuplicateKeyPolicy::Error,
        merge_keys: serde_saphyr::MergeKeyPolicy::Error,
        strict_booleans: true,
        reject_unsupported_tags: true,
        emit_comments: false,
        budget: serde_saphyr::budget! {
            max_depth: MAX_DOCUMENT_DEPTH,
            flow_nesting_limit: MAX_DOCUMENT_DEPTH,
            max_events: 1_600_000,
            max_nodes: 524_289,
            max_total_scalar_bytes: MAX_SOURCE_BYTES,
            max_documents: 1,
            max_aliases: 0,
            max_anchors: 0,
            max_merge_keys: 0,
            max_inclusion_depth: 0,
        },
    };
    // Do not propagate parser snippets containing subscription credentials.
    let mut documents: Vec<Document> = serde_saphyr::from_multiple_with_options(source, options)
        .map_err(|error| match error.without_snippet() {
            serde_saphyr::Error::Budget { .. } => anyhow!("YAML resource limit exceeded"),
            serde_saphyr::Error::Message { msg, .. }
                if msg == "YAML collection entry limit exceeded" =>
            {
                anyhow!("YAML collection entry limit exceeded")
            }
            _ => anyhow!("invalid configuration YAML: check fields, types and duplicates"),
        })?;
    // The single-document entry point suppresses some malformed trailing YAML.
    // The stream entry point plus max_documents: 1 validates the complete input.
    Ok(documents.pop().map_or(Value::Null, |document| document.0))
}

pub fn parse_document(source: &str) -> Result<Value> {
    let value = yaml_value(source)?;
    if !value.is_object() {
        bail!("configuration must be a YAML mapping");
    }
    Ok(value)
}

pub fn parse_with_assets(source: &str, assets: &BTreeMap<String, Vec<u8>>) -> Result<Config> {
    Config::parse_with_assets(source, assets)
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
pub(super) struct Provider {
    #[serde(rename = "type")]
    kind: String,
    behavior: String,
    path: String,
    #[serde(default, deserialize_with = "super::present")]
    url: Option<String>,
    #[serde(default = "default_interval")]
    interval: u32,
}
fn default_interval() -> u32 {
    86400
}

fn validate(providers: &BTreeMap<String, Provider>) -> Result<()> {
    if providers.len() > MAX_PROVIDERS {
        bail!("rule-provider count limit exceeded");
    }
    for (name, provider) in providers {
        super::validate_name(name)?;
        if !matches!(provider.kind.as_str(), "file" | "http")
            || !matches!(
                provider.behavior.as_str(),
                "classical" | "domain" | "ipcidr"
            )
            || provider.path.is_empty()
            || provider.path.contains('\0')
            || provider.interval == 0
        {
            bail!(
                "invalid rule-provider declaration: require file/http, classical/domain/ipcidr, path and positive interval"
            );
        }
        if provider.kind == "http" && provider.url.is_none() {
            bail!("HTTP rule-provider requires a URL");
        }
        if let Some(url) = &provider.url {
            let url = reqwest::Url::parse(url).map_err(|_| anyhow!("invalid rule-provider URL"))?;
            if !matches!(url.scheme(), "http" | "https") || url.host_str().is_none() {
                bail!("rule-provider URL must use HTTP or HTTPS with a host");
            }
        }
    }
    Ok(())
}

fn declarations(source: &str) -> Result<BTreeMap<String, Provider>> {
    let document = parse_document(source)?;
    let providers = match document.get("rule-providers") {
        None => BTreeMap::new(),
        Some(value) => {
            serde_json::from_value::<Mapping<BTreeMap<String, Provider>>>(value.clone())
                .map_err(|_| anyhow!("invalid rule-provider declarations"))?
                .0
        }
    };
    validate(&providers)?;
    Ok(providers)
}

fn add_budget(total: &mut usize, amount: usize, max: usize, message: &str) -> Result<()> {
    *total = total
        .checked_add(amount)
        .filter(|&next| next <= max)
        .ok_or_else(|| anyhow!("{message}"))?;
    Ok(())
}

fn asset_budget(assets: &BTreeMap<String, Vec<u8>>) -> Result<()> {
    if assets.len() > MAX_PROVIDERS {
        bail!("rule-provider asset count limit exceeded");
    }
    let mut total = 0;
    for bytes in assets.values() {
        if bytes.len() > MAX_SOURCE_BYTES {
            bail!("rule-provider file exceeds the 16 MiB source limit");
        }
        add_budget(
            &mut total,
            bytes.len(),
            MAX_AGGREGATE_BYTES,
            "rule-provider aggregate source bytes limit exceeded",
        )?;
    }
    Ok(())
}

fn entries(source: &str, behavior: &str) -> Result<Vec<String>> {
    let source = source.strip_prefix('\u{feff}').unwrap_or(source);
    let first = source
        .lines()
        .map(str::trim)
        .find(|line| !line.is_empty() && !line.starts_with('#'))
        .unwrap_or("");
    let raw_classical = behavior == "classical"
        && first.split_once(',').is_some_and(|(kind, _)| {
            matches!(
                kind.trim(),
                "DOMAIN"
                    | "DOMAIN-SUFFIX"
                    | "DOMAIN-KEYWORD"
                    | "IP-CIDR"
                    | "IP-CIDR6"
                    | "GEOIP"
                    | "RULE-SET"
                    | "SRC-IP-CIDR"
                    | "SRC-PORT"
                    | "DST-PORT"
                    | "PROCESS-NAME"
                    | "MATCH"
            )
        });
    if !raw_classical {
        // Structured provider documents must never fall back on duplicate, resource,
        // tag or syntax errors. Plain line lists are the only legacy format.
        let structured = first.starts_with(['{', '[', '-', '!', '&', '*'])
            || source.lines().any(|line| {
                line.trim() == "..."
                    || line
                        .as_bytes()
                        .windows(2)
                        .any(|w| w[0] == b':' && w[1].is_ascii_whitespace())
                    || line.trim_end().ends_with(':')
            });
        if structured {
            let value = yaml_value(source)?;
            let payload = value
                .as_object()
                .and_then(|map| map.get("payload"))
                .and_then(Value::as_array)
                .ok_or_else(|| anyhow!("rule-provider YAML requires a payload sequence"))?;
            return payload
                .iter()
                .map(|value| {
                    value
                        .as_str()
                        .map(str::to_owned)
                        .ok_or_else(|| anyhow!("rule-provider payload entries must be strings"))
                })
                .collect();
        }
    }
    let mut result = Vec::new();
    for line in source.lines() {
        let mut line = line.trim_matches([' ', '\t', '\r']);
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if line.len() >= 2
            && ((line.starts_with('"') && line.ends_with('"'))
                || (line.starts_with('\'') && line.ends_with('\'')))
        {
            line = &line[1..line.len() - 1];
        }
        if result.len() == MAX_RULES {
            bail!("rule-provider entry count limit exceeded");
        }
        result.push(line.to_owned());
    }
    Ok(result)
}

fn provider_rule(entry: &str, behavior: &str, names: &HashMap<String, usize>) -> Result<Rule> {
    let entry = entry.trim_matches([' ', '\t', '\r']);
    let (source, no_resolve) = match behavior {
        "domain" => {
            let domain = entry
                .strip_prefix("DOMAIN-SUFFIX,")
                .or_else(|| entry.strip_prefix("DOMAIN,"))
                .or_else(|| entry.strip_prefix("+."))
                .or_else(|| entry.strip_prefix('.'))
                .unwrap_or(entry)
                .trim();
            (format!("DOMAIN-SUFFIX,{domain},DIRECT"), false)
        }
        "ipcidr" => {
            let cidr = entry
                .strip_prefix("IP-CIDR,")
                .or_else(|| entry.strip_prefix("IP-CIDR6,"))
                .unwrap_or(entry)
                .trim();
            let kind = if cidr.contains(':') {
                "IP-CIDR6"
            } else {
                "IP-CIDR"
            };
            (format!("{kind},{cidr},DIRECT"), false)
        }
        "classical" => {
            let mut fields = entry
                .split(',')
                .map(|field| field.trim_matches([' ', '\t']));
            let kind = fields
                .next()
                .ok_or_else(|| anyhow!("invalid classical rule"))?;
            if kind == "RULE-SET" {
                bail!("recursive rule-provider RULE-SET is unsupported");
            }
            let payload = if kind == "MATCH" {
                None
            } else {
                Some(
                    fields
                        .next()
                        .ok_or_else(|| anyhow!("classical rule requires payload"))?,
                )
            };
            let mut no_resolve = false;
            for option in fields {
                match option {
                    "no-resolve" => no_resolve = true,
                    "" => {}
                    _ => bail!(
                        "classical provider entries cannot declare targets or unknown options"
                    ),
                }
            }
            (
                match payload {
                    Some(payload) => format!("{kind},{payload},DIRECT"),
                    None => "MATCH,DIRECT".into(),
                },
                no_resolve,
            )
        }
        _ => unreachable!("provider behavior validated"),
    };
    let mut rule = Rule::parse(&source, names)?;
    if no_resolve {
        inherit_no_resolve(&mut rule);
    }
    Ok(rule)
}

fn inherit_no_resolve(rule: &mut Rule) {
    match &mut rule.matcher {
        Matcher::Ip { no_resolve, .. } | Matcher::GeoIp { no_resolve, .. } => *no_resolve = true,
        _ => {}
    }
}

pub(super) fn expand(
    source_rules: &[String],
    providers: &BTreeMap<String, Provider>,
    assets: &BTreeMap<String, Vec<u8>>,
    names: &HashMap<String, usize>,
) -> Result<Vec<Rule>> {
    validate(providers)?;
    asset_budget(assets)?;
    let mut normalized_count = 0;
    let mut normalized_bytes = 0;
    let mut raw_bytes = 0;
    let mut templates = HashMap::with_capacity(providers.len());
    for (name, provider) in providers {
        let bytes = assets.get(&provider.path).ok_or_else(|| anyhow!("missing immutable rule-provider asset; capture files or fetch HTTP providers before parsing"))?;
        add_budget(
            &mut raw_bytes,
            bytes.len(),
            MAX_AGGREGATE_BYTES,
            "rule-provider aggregate source bytes limit exceeded",
        )?;
        let source = std::str::from_utf8(bytes)
            .map_err(|_| anyhow!("rule-provider source must be UTF-8"))?;
        let entries = entries(source, &provider.behavior)?;
        add_budget(
            &mut normalized_count,
            entries.len(),
            MAX_RULES,
            "rule-provider aggregate entry count limit exceeded",
        )?;
        let mut entry_bytes = 0;
        let mut rules = Vec::with_capacity(entries.len());
        for entry in entries {
            add_budget(
                &mut normalized_bytes,
                entry.len(),
                MAX_AGGREGATE_BYTES,
                "rule-provider aggregate normalized bytes limit exceeded",
            )?;
            entry_bytes += entry.len();
            rules.push(provider_rule(&entry, &provider.behavior, names)?);
        }
        templates.insert(name.as_str(), (rules, entry_bytes));
    }
    enum Planned<'a> {
        Rule(Rule),
        Provider(&'a [Rule], usize, bool),
    }
    let mut plan = Vec::with_capacity(source_rules.len());
    let mut count = 0;
    let mut bytes = 0;
    for source in source_rules {
        let fields: Vec<_> = source
            .split(',')
            .take(5)
            .map(|field| field.trim_matches([' ', '\t']))
            .collect();
        if fields.first() == Some(&"RULE-SET") {
            let (name, target, no_resolve) = match fields.as_slice() {
                ["RULE-SET", name, target] => (*name, *target, false),
                ["RULE-SET", name, target, "no-resolve"] => (*name, *target, true),
                _ => bail!("invalid RULE-SET declaration"),
            };
            let (rules, entry_bytes) = templates
                .get(name)
                .ok_or_else(|| anyhow!("RULE-SET references unknown provider"))?;
            let proxy = *names
                .get(target)
                .ok_or_else(|| anyhow!("rule references unknown proxy or group"))?;
            add_budget(
                &mut count,
                rules.len(),
                MAX_RULES,
                "expanded rule count limit exceeded",
            )?;
            let target_bytes = target
                .len()
                .checked_mul(rules.len())
                .ok_or_else(|| anyhow!("expanded rule bytes limit exceeded"))?;
            add_budget(
                &mut bytes,
                target_bytes,
                MAX_AGGREGATE_BYTES,
                "expanded rule bytes limit exceeded",
            )?;
            add_budget(
                &mut bytes,
                *entry_bytes,
                MAX_AGGREGATE_BYTES,
                "expanded rule bytes limit exceeded",
            )?;
            plan.push(Planned::Provider(rules, proxy, no_resolve));
        } else {
            let rule = Rule::parse(source, names)?;
            add_budget(
                &mut count,
                1,
                MAX_RULES,
                "expanded rule count limit exceeded",
            )?;
            let target = if fields[0] == "MATCH" {
                fields[1]
            } else {
                fields[2]
            };
            add_budget(
                &mut bytes,
                rule.payload.len() + target.len(),
                MAX_AGGREGATE_BYTES,
                "expanded rule bytes limit exceeded",
            )?;
            plan.push(Planned::Rule(rule));
        }
    }
    // Managed provider preparation inserts its fail-closed final rule before expansion.
    // A provider-supplied MATCH cannot hide a second final or bypass its byte reservation.
    if !providers.is_empty()
        && !plan.iter().any(
            |item| matches!(item, Planned::Rule(rule) if matches!(rule.matcher, Matcher::Match)),
        )
    {
        add_budget(
            &mut count,
            1,
            MAX_RULES,
            "expanded rule count limit exceeded",
        )?;
        add_budget(
            &mut bytes,
            "REJECT".len(),
            MAX_AGGREGATE_BYTES,
            "expanded rule bytes limit exceeded",
        )?;
        plan.push(Planned::Rule(Rule::parse("MATCH,REJECT", names)?));
    }
    // Check every count and conservative payload+target reservation before expansion.
    let mut expanded = Vec::with_capacity(count);
    for item in plan {
        match item {
            Planned::Rule(rule) => expanded.push(rule),
            Planned::Provider(rules, proxy, no_resolve) => {
                for rule in rules {
                    let mut rule = rule.clone();
                    rule.proxy = proxy;
                    if no_resolve {
                        inherit_no_resolve(&mut rule);
                    }
                    expanded.push(rule);
                }
            }
        }
    }
    if !providers.is_empty() {
        let finals: Vec<_> = expanded
            .iter()
            .enumerate()
            .filter(|(_, rule)| matches!(rule.matcher, Matcher::Match))
            .map(|(index, _)| index)
            .collect();
        if finals.as_slice() != [expanded.len().saturating_sub(1)] || expanded.is_empty() {
            bail!("expanded provider rules require exactly one final MATCH at the end");
        }
    }
    Ok(expanded)
}

// Local capture is explicit, root-contained, and independent of parse-time state.
// Descriptor-relative traversal rejects symlinks and special files without blocking.
#[cfg(unix)]
fn read_asset(root: &Path, path: &str, limit: usize) -> Result<Vec<u8>> {
    use rustix::fs::{CWD, Mode, OFlags, openat};
    let components: Vec<_> = Path::new(path).components().take(65).collect();
    if components.is_empty()
        || components.len() > 64
        || components
            .iter()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        bail!("local rule-provider path must be relative and root-contained");
    }
    let flags = OFlags::RDONLY | OFlags::CLOEXEC | OFlags::NOFOLLOW | OFlags::NONBLOCK;
    let mut fd = openat(CWD, root, flags | OFlags::DIRECTORY, Mode::empty())
        .map_err(|_| anyhow!("cannot open rule-provider root directory"))?;
    for (index, component) in components.iter().enumerate() {
        let directory = if index + 1 == components.len() {
            OFlags::empty()
        } else {
            OFlags::DIRECTORY
        };
        fd = openat(&fd, component.as_os_str(), flags | directory, Mode::empty())
            .map_err(|_| anyhow!("cannot open root-contained rule-provider asset"))?;
    }
    let file = std::fs::File::from(fd);
    let metadata = file.metadata()?;
    if !metadata.is_file() {
        bail!("rule-provider asset must be a regular file");
    }
    if metadata.len() > limit as u64 {
        bail!("rule-provider source bytes limit exceeded");
    }
    let mut bytes = Vec::new();
    file.take(limit as u64 + 1).read_to_end(&mut bytes)?;
    if bytes.len() > limit {
        bail!("rule-provider source bytes limit exceeded");
    }
    Ok(bytes)
}

#[cfg(not(unix))]
fn read_asset(_root: &Path, _path: &str, _limit: usize) -> Result<Vec<u8>> {
    bail!("secure local provider capture requires Unix");
}

pub fn capture_file_assets(source: &str, root: &Path) -> Result<BTreeMap<String, Vec<u8>>> {
    let providers = declarations(source)?;
    let mut assets = BTreeMap::new();
    let mut total = 0;
    for provider in providers.values().filter(|provider| provider.url.is_none()) {
        let bytes = read_asset(
            root,
            &provider.path,
            MAX_SOURCE_BYTES.min(MAX_AGGREGATE_BYTES - total),
        )?;
        total += bytes.len();
        assets.insert(provider.path.clone(), bytes);
    }
    Ok(assets)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ProviderSyncPolicy {
    Eager,
    MissingOnly,
}

fn http_client() -> Result<reqwest::Client> {
    reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()
        .map_err(|_| anyhow!("cannot initialize rule-provider HTTP client"))
}

// None means an ordinary transport/status failure, the only cache-eligible error.
// Every wire chunk, including failed response bodies, consumes the sync budget.
async fn download(
    client: &reqwest::Client,
    url: &str,
    total: &mut usize,
) -> Result<Option<Vec<u8>>> {
    let limit = MAX_SOURCE_BYTES.min(MAX_AGGREGATE_BYTES - *total);
    if limit == 0 {
        bail!("rule-provider aggregate source bytes limit exceeded");
    }
    let mut response = match client.get(url).send().await {
        Ok(response) => response,
        Err(_) => {
            *total += limit;
            return Ok(None);
        }
    };
    if response
        .content_length()
        .is_some_and(|length| length > limit as u64)
    {
        bail!("rule-provider HTTP body exceeds source byte limit");
    }
    let success = response.status() == reqwest::StatusCode::OK;
    let mut bytes = Vec::new();
    loop {
        let chunk = match response.chunk().await {
            Ok(Some(chunk)) => chunk,
            Ok(None) => break,
            Err(_) => {
                *total += limit - bytes.len();
                return Ok(None);
            }
        };
        if chunk.len() > limit - bytes.len() {
            bail!("rule-provider HTTP body exceeds source byte limit");
        }
        *total += chunk.len();
        bytes.extend_from_slice(&chunk);
    }
    Ok(success.then_some(bytes))
}

/// Fetch without persistence. No HTTP client or trust store is opened if unused.
pub async fn fetch_http_assets(source: &str) -> Result<BTreeMap<String, Vec<u8>>> {
    let providers = declarations(source)?;
    let mut client = None;
    let mut assets = BTreeMap::new();
    let mut total = 0;
    for provider in providers.values().filter(|provider| provider.url.is_some()) {
        if client.is_none() {
            client = Some(http_client()?);
        }
        let bytes = download(
            client.as_ref().unwrap(),
            provider.url.as_ref().unwrap(),
            &mut total,
        )
        .await?
        .ok_or_else(|| anyhow!("rule-provider download failed or timed out"))?;
        if assets.insert(provider.path.clone(), bytes).is_some() {
            bail!("multiple HTTP providers cannot publish the same asset path");
        }
    }
    Ok(assets)
}

fn cache_parent(
    root: &crate::fsutil::SecureDir,
    path: &str,
    create: bool,
) -> Result<(Option<crate::fsutil::SecureDir>, String)> {
    let components: Vec<_> = Path::new(path).components().take(65).collect();
    if components.is_empty()
        || components.len() > 64
        || components
            .iter()
            .any(|part| !matches!(part, Component::Normal(_)))
    {
        bail!("HTTP rule-provider cache path must be relative and root-contained");
    }
    let mut parent = None;
    for component in &components[..components.len() - 1] {
        let name = component
            .as_os_str()
            .to_str()
            .ok_or_else(|| anyhow!("invalid cache path"))?;
        parent = Some(
            parent
                .as_ref()
                .unwrap_or(root)
                .owned_child(name, create, false)?,
        );
    }
    let name = components
        .last()
        .unwrap()
        .as_os_str()
        .to_str()
        .ok_or_else(|| anyhow!("invalid cache path"))?
        .to_owned();
    if name == ".provider-cache.lock" {
        bail!("reserved HTTP rule-provider cache path");
    }
    Ok((parent, name))
}

fn validate_candidate(
    provider: &Provider,
    bytes: &[u8],
    count: &mut usize,
    normalized: &mut usize,
) -> Result<()> {
    let source =
        std::str::from_utf8(bytes).map_err(|_| anyhow!("rule-provider source must be UTF-8"))?;
    let names = HashMap::from([("DIRECT".into(), 0), ("REJECT".into(), 1)]);
    for entry in entries(source, &provider.behavior)? {
        add_budget(
            count,
            1,
            MAX_RULES,
            "rule-provider aggregate entry count limit exceeded",
        )?;
        add_budget(
            normalized,
            entry.len(),
            MAX_AGGREGATE_BYTES,
            "rule-provider aggregate normalized bytes limit exceeded",
        )?;
        provider_rule(&entry, &provider.behavior, &names)?;
    }
    Ok(())
}

fn reject_source_collision(
    cache: Option<&std::fs::Metadata>,
    source: Option<&std::fs::Metadata>,
) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    if let (Some(cache), Some(source)) = (cache, source)
        && cache.dev() == source.dev()
        && cache.ino() == source.ino()
    {
        bail!("HTTP rule-provider cache must not overwrite the configuration source");
    }
    Ok(())
}

/// Synchronize unmanaged caches from a normalized runtime configuration under a
/// held source directory. Validate all candidate assets and the full configuration
/// before publishing any cache. The protected source descriptor stays held across
/// awaits. No caller bytes or managed revisions change.
pub async fn sync_http_assets(
    source: &str,
    root: &crate::fsutil::SecureDir,
    policy: ProviderSyncPolicy,
    local_assets: &BTreeMap<String, Vec<u8>>,
    protected_source: Option<&std::fs::File>,
) -> Result<BTreeMap<String, Vec<u8>>> {
    let providers = declarations(source)?;
    let source_identity = protected_source.map(std::fs::File::metadata).transpose()?;
    asset_budget(local_assets)?;
    let mut total = 0;
    let mut count = 0;
    let mut normalized = 0;
    let mut assets = local_assets.clone();
    let mut client = None;
    let mut paths = std::collections::HashMap::new();
    let mut pending = Vec::new();
    // Reject asset collisions before any network or publication.
    for provider in providers.values() {
        let remote = provider.url.is_some();
        let path: std::path::PathBuf = Path::new(&provider.path).components().collect();
        if paths
            .insert(path, remote)
            .is_some_and(|previous_remote| previous_remote || remote)
        {
            bail!("multiple providers cannot publish the same HTTP asset path");
        }
        if provider.url.is_none() {
            let bytes = assets
                .get(&provider.path)
                .ok_or_else(|| anyhow!("missing immutable rule-provider asset"))?;
            add_budget(
                &mut total,
                bytes.len(),
                MAX_AGGREGATE_BYTES,
                "rule-provider aggregate source bytes limit exceeded",
            )?;
            validate_candidate(provider, bytes, &mut count, &mut normalized)?;
        }
    }
    // Keep descriptors alive across HTTP awaits so inode reuse cannot defeat
    // identity checks. Compare OS identities, not case-folded path strings.
    let mut identities = HashMap::new();
    let mut held_files = Vec::new();
    if providers.values().any(|provider| provider.url.is_some()) {
        use std::os::unix::fs::MetadataExt;
        for provider in providers.values() {
            let held = (|| -> Result<_> {
                let (parent, name) = cache_parent(root, &provider.path, false)?;
                let parent = parent.as_ref().unwrap_or(root);
                let file = parent.hold_cache_source(&name)?;
                // A fresh cache must not consume the lock via an OS alias either.
                // Unrelated lock usability is checked only when publishing.
                if let Ok(lock) = parent.hold_cache_source(".provider-cache.lock") {
                    let a = file.metadata()?;
                    let b = lock.metadata()?;
                    if a.dev() == b.dev() && a.ino() == b.ino() {
                        bail!("reserved HTTP rule-provider cache file");
                    }
                }
                Ok(file)
            })();
            let file = match held {
                Ok(file) => file,
                Err(error)
                    if error
                        .downcast_ref::<std::io::Error>()
                        .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
                {
                    continue;
                }
                Err(error) => return Err(error),
            };
            let metadata = file.metadata()?;
            let remote = provider.url.is_some();
            if remote {
                reject_source_collision(Some(&metadata), source_identity.as_ref())?;
            }
            let identity = (metadata.dev(), metadata.ino());
            if let Some((_, previous_remote)) =
                identities.insert(identity, (&provider.path, remote))
                && (remote || previous_remote)
            {
                bail!("multiple providers cannot publish the same HTTP asset file");
            }
            held_files.push(file);
        }
    }
    for provider in providers.values().filter(|provider| provider.url.is_some()) {
        let parent = match cache_parent(root, &provider.path, false) {
            Ok(parent) => Some(parent),
            Err(error)
                if error
                    .downcast_ref::<std::io::Error>()
                    .is_some_and(|error| error.kind() == std::io::ErrorKind::NotFound) =>
            {
                None
            }
            Err(error) => return Err(error),
        };
        let metadata = match &parent {
            Some((dir, name)) => match dir.as_ref().unwrap_or(root).cache_metadata(name) {
                Ok(metadata) => Some(metadata),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(error.into()),
            },
            None => None,
        };
        reject_source_collision(metadata.as_ref(), source_identity.as_ref())?;
        let fresh = metadata.as_ref().is_some_and(|metadata| {
            policy == ProviderSyncPolicy::MissingOnly
                || metadata.modified().ok().is_some_and(|mtime| {
                    let epoch = std::time::UNIX_EPOCH;
                    let modified = mtime.duration_since(epoch).unwrap_or_default().as_secs();
                    let now = std::time::SystemTime::now()
                        .duration_since(epoch)
                        .unwrap_or_default()
                        .as_secs();
                    modified > 0 && now.saturating_sub(modified) < u64::from(provider.interval)
                })
        });
        let candidate = if fresh {
            None
        } else {
            if client.is_none() {
                client = Some(http_client()?);
            }
            let candidate = download(
                client.as_ref().unwrap(),
                provider.url.as_ref().unwrap(),
                &mut total,
            )
            .await?;
            if candidate.is_none() && metadata.is_none() {
                bail!("rule-provider download failed or timed out; no valid cache available");
            }
            candidate
        };
        let bytes = if let Some(bytes) = candidate {
            validate_candidate(provider, &bytes, &mut count, &mut normalized)?;
            pending.push(provider);
            bytes
        } else {
            let (parent, name) =
                parent.ok_or_else(|| anyhow!("rule-provider cache disappeared"))?;
            let bytes = parent
                .as_ref()
                .unwrap_or(root)
                .read_cache(&name, MAX_SOURCE_BYTES.min(MAX_AGGREGATE_BYTES - total))?;
            add_budget(
                &mut total,
                bytes.len(),
                MAX_AGGREGATE_BYTES,
                "rule-provider aggregate source bytes limit exceeded",
            )?;
            validate_candidate(provider, &bytes, &mut count, &mut normalized)?;
            if !fresh {
                eprintln!("Rule-provider refresh failed; using validated cached bytes");
            }
            bytes
        };
        if assets.insert(provider.path.clone(), bytes).is_some() {
            bail!("conflicting HTTP rule-provider asset path");
        }
    }
    asset_budget(&assets)?;
    if !pending.is_empty() {
        // Complete semantics and repeated RULE-SET expansion must pass before
        // the first visible write. This is not a multi-file I/O transaction.
        Config::parse_with_assets(source, &assets)?;
        for provider in pending {
            let bytes = &assets[&provider.path];
            let (parent, name) = cache_parent(root, &provider.path, true)?;
            let parent = parent.as_ref().unwrap_or(root);
            let lock = parent.lock(".provider-cache.lock", Duration::from_secs(5))?;
            let current = match parent.cache_metadata(&name) {
                Ok(metadata) => Some(metadata),
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
                Err(error) => return Err(error.into()),
            };
            reject_source_collision(current.as_ref(), source_identity.as_ref())?;
            if let Some(metadata) = &current {
                use std::os::unix::fs::MetadataExt;
                let lock_metadata = lock.inherited_file()?.metadata()?;
                if metadata.dev() == lock_metadata.dev() && metadata.ino() == lock_metadata.ino() {
                    bail!("reserved HTTP rule-provider cache file");
                }
                if let Some((path, _)) = identities.get(&(metadata.dev(), metadata.ino()))
                    && *path != &provider.path
                {
                    bail!("multiple providers cannot publish the same HTTP asset file");
                }
            }
            let receipt = parent.write_cache(&name, bytes)?;
            if receipt.durability_error.is_some() {
                eprintln!("Rule-provider cache visible but durability uncertain");
            }
            // A later previously missing path may be an OS alias of this new
            // entry. Keep its new identity too; never overwrite our own output.
            let file = parent.hold_cache_source(&name)?;
            let metadata = file.metadata()?;
            use std::os::unix::fs::MetadataExt;
            identities.insert((metadata.dev(), metadata.ino()), (&provider.path, true));
            held_files.push(file);
        }
    }
    Ok(assets)
}

pub(super) fn validate_rule_declarations(
    rules: &[String],
    providers: &BTreeMap<String, Provider>,
    names: &HashMap<String, usize>,
) -> Result<()> {
    validate(providers)?;
    for source in rules {
        let fields: Vec<_> = source.split(',').take(5).map(str::trim).collect();
        if fields.first() == Some(&"RULE-SET") {
            let (name, target) = match fields.as_slice() {
                ["RULE-SET", name, target] | ["RULE-SET", name, target, "no-resolve"] => {
                    (*name, *target)
                }
                _ => bail!("invalid RULE-SET declaration"),
            };
            if !providers.contains_key(name) {
                bail!("RULE-SET references unknown provider");
            }
            if !names.contains_key(target) {
                bail!("rule references an unknown proxy or group");
            }
        } else {
            Rule::parse(source, names)?;
        }
    }
    Ok(())
}
