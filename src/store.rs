//! Zig-compatible schema-2 catalogs and schema-1 immutable revisions.
use crate::{
    config::Config,
    fsutil::{self, SecureDir},
};
use anyhow::{Context, Result, ensure};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fmt,
    fs::File,
    io::Read,
    path::{Path, PathBuf},
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

pub const FILE_LIMIT: usize = 16 * 1024 * 1024;
pub const AGGREGATE_LIMIT: usize = 64 * 1024 * 1024;
const CATALOG_LIMIT: usize = 4 * 1024 * 1024;
const MANIFEST_LIMIT: usize = 1024 * 1024;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StoreError {
    CorruptCatalog,
    CorruptRevision,
    UnknownFormat(u64),
    LegacyTakeoverRequired,
    Conflict,
    ProfileNotFound,
    ProfileNotRuntimeReady,
}
impl fmt::Display for StoreError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "{self:?}")
    }
}
impl std::error::Error for StoreError {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Selection {
    pub group: String,
    pub proxy: String,
}
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Desired {
    pub generation: u64,
    pub selections: Vec<Selection>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Profile {
    pub key: String,
    pub storage_id: String,
    pub head: String,
    pub desired: Desired,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct ActiveIdentity {
    pub key: String,
    pub revision: String,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Catalog {
    pub schema_version: u32,
    pub sequence: u64,
    pub active: Option<ActiveIdentity>,
    pub profiles: Vec<Profile>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum StateFormat {
    Missing,
    CatalogV2,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct StateToken {
    pub format: StateFormat,
    pub sequence: u64,
    pub digest: String,
}
#[derive(Debug, Clone)]
pub struct Snapshot {
    /// A visible commit in this Store failed its authority directory sync.
    pub durability_uncertain: bool,
    pub token: StateToken,
    pub catalog: Catalog,
}
#[derive(Debug)]
pub struct Receipt {
    pub token: StateToken,
    pub durability_error: Option<std::io::Error>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Param {
    pub key: String,
    pub value: String,
}
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Metadata {
    pub url: Option<String>,
    pub filename: Option<String>,
    pub params: Vec<Param>,
}
/// Frozen execution evidence, independent of the override runner.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct FrozenOverride {
    pub script_name: String,
    pub script_bytes: Vec<u8>,
    pub command: String,
    pub config_path: Option<String>,
    pub timeout_ms: u32,
    pub args: Vec<Param>,
    pub patch_bytes: Vec<u8>,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Asset {
    pub canonical_relative_target: String,
    pub bytes: Vec<u8>,
}
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct RemoteProvider {
    pub provider_name: String,
    pub logical_path: String,
    pub remote_deferred: bool,
}
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Bundle {
    source: Vec<u8>,
    materialized: Option<Vec<u8>>,
    assets: BTreeMap<String, Asset>,
    remotes: Vec<RemoteProvider>,
}
#[derive(Debug, Clone)]
pub struct RevisionView {
    pub key: String,
    pub storage_id: String,
    pub revision: String,
    pub content_digest: String,
    pub metadata: Metadata,
    pub frozen_override: Option<FrozenOverride>,
    pub bundle: Bundle,
}

impl Bundle {
    pub fn source(&self) -> &[u8] {
        &self.source
    }
    pub fn materialized(&self) -> Option<&[u8]> {
        self.materialized.as_deref()
    }
    pub fn effective_source(&self) -> &[u8] {
        self.materialized.as_deref().unwrap_or(&self.source)
    }
    pub fn assets(&self) -> &BTreeMap<String, Asset> {
        &self.assets
    }
    pub fn remotes(&self) -> &[RemoteProvider] {
        &self.remotes
    }
    pub fn resolve_local(&self, logical: &str) -> Result<&[u8]> {
        self.assets
            .get(logical)
            .map(|a| a.bytes.as_slice())
            .ok_or_else(|| anyhow::anyhow!("AssetNotDeclared"))
    }
    pub fn from_memory(
        source: &[u8],
        materialized: Option<&[u8]>,
        available: BTreeMap<String, Asset>,
    ) -> Result<Self> {
        let bundle = Self::capture_memory(source, materialized, available)?;
        bundle.catalog_ready()?;
        Ok(bundle)
    }
    fn capture_memory(
        source: &[u8],
        materialized: Option<&[u8]>,
        available: BTreeMap<String, Asset>,
    ) -> Result<Self> {
        ensure!(
            source.len() <= FILE_LIMIT && materialized.is_none_or(|v| v.len() <= FILE_LIMIT),
            "SourceTooLarge"
        );
        let document = parse_document(materialized.unwrap_or(source))?;
        let (paths, remotes) = provider_refs(&document)?;
        let mut assets = BTreeMap::new();
        let mut total = source.len() + materialized.map_or(0, <[u8]>::len);
        for path in paths {
            let asset = available
                .get(&path)
                .context("AssetNotDeclared: local providers require captured assets")?;
            ensure!(asset.bytes.len() <= FILE_LIMIT, "AssetTooLarge");
            total = total
                .checked_add(asset.bytes.len())
                .context("AggregateTooLarge")?;
            ensure!(total <= AGGREGATE_LIMIT, "AggregateTooLarge");
            assets.insert(path, asset.clone());
        }
        let bundle = Self {
            source: source.to_vec(),
            materialized: materialized.map(<[u8]>::to_vec),
            assets,
            remotes,
        };
        Ok(bundle)
    }
    /// Capture unmanaged runtime inputs; callers must fetch HTTP assets before
    /// runtime_config_with_assets. Publication still requires catalog admission.
    pub fn capture_for_runtime(path: impl AsRef<Path>) -> Result<Self> {
        Self::capture_files(path.as_ref(), None)
    }
    pub fn capture(path: impl AsRef<Path>) -> Result<Self> {
        Self::capture_materialized(path, None)
    }
    pub fn capture_materialized(
        path: impl AsRef<Path>,
        materialized: Option<&[u8]>,
    ) -> Result<Self> {
        let bundle = Self::capture_files(path.as_ref(), materialized)?;
        bundle.catalog_ready()?;
        Ok(bundle)
    }
    fn capture_files(path: &Path, materialized: Option<&[u8]>) -> Result<Self> {
        let parent = path
            .parent()
            .filter(|p| !p.as_os_str().is_empty())
            .unwrap_or(Path::new("."));
        let name = path
            .file_name()
            .and_then(|n| n.to_str())
            .context("invalid source path")?;
        let (_, source) = fsutil::read_contained(parent, name, FILE_LIMIT)?;
        let (paths, _) = provider_refs(&parse_document(materialized.unwrap_or(&source))?)?;
        let mut assets = BTreeMap::new();
        let mut total = source.len() + materialized.map_or(0, <[u8]>::len);
        for logical in paths {
            let (target, bytes) = fsutil::read_contained(parent, &logical, FILE_LIMIT)?;
            total = total
                .checked_add(bytes.len())
                .context("AggregateTooLarge")?;
            ensure!(total <= AGGREGATE_LIMIT, "AggregateTooLarge");
            assets.insert(
                logical,
                Asset {
                    canonical_relative_target: target,
                    bytes,
                },
            );
        }
        // A second capture detects edits and path replacement during the first pass.
        ensure!(
            fsutil::read_contained(parent, name, FILE_LIMIT)?.1 == source,
            "SourceChanged"
        );
        for (logical, asset) in &assets {
            let (target, bytes) = fsutil::read_contained(parent, logical, FILE_LIMIT)?;
            ensure!(
                target == asset.canonical_relative_target && bytes == asset.bytes,
                "SourceChanged"
            );
        }
        Self::capture_memory(&source, materialized, assets)
    }
    fn aggregate(&self) -> usize {
        self.source.len()
            + self.materialized.as_ref().map_or(0, Vec::len)
            + self.assets.values().map(|a| a.bytes.len()).sum::<usize>()
    }
    fn local_asset_bytes(&self) -> BTreeMap<String, Vec<u8>> {
        self.assets
            .iter()
            .map(|(k, v)| (k.clone(), v.bytes.clone()))
            .collect()
    }
    pub fn runtime_config(&self) -> Result<Config> {
        self.runtime_config_with_assets(&BTreeMap::new())
    }
    /// Parse only after the caller has fetched every declared HTTP provider.
    /// Remote bytes are runtime inputs, never silently replaced by empty rules.
    pub fn runtime_config_with_assets(
        &self,
        fetched: &BTreeMap<String, Vec<u8>>,
    ) -> Result<Config> {
        let mut assets = self.local_asset_bytes();
        for remote in &self.remotes {
            let bytes = fetched
                .get(&remote.logical_path)
                .ok_or(StoreError::ProfileNotRuntimeReady)?;
            ensure!(
                !assets.contains_key(&remote.logical_path),
                "ConflictingProviderAssetPath"
            );
            assets.insert(remote.logical_path.clone(), bytes.clone());
        }
        Config::parse_with_assets(
            &crate::override_script::runtime_source(self.effective_source())?,
            &assets,
        )
    }
    fn validate_offline(&self, source: &str) -> Result<()> {
        let mut document = crate::config::parse_document(source)?;
        let assets = self.local_asset_bytes();
        for remote in &self.remotes {
            ensure!(
                !assets.contains_key(&remote.logical_path),
                "ConflictingProviderAssetPath"
            );
            if let Some(rules) = document.get("rules").and_then(|value| value.as_array()) {
                for rule in rules.iter().filter_map(|value| value.as_str()) {
                    let mut fields = rule.split(',').map(|field| field.trim_matches([' ', '\t']));
                    ensure!(
                        fields.next() != Some("RULE-SET")
                            || fields.next() != Some(&remote.provider_name),
                        "ManagedRemoteRuleProviderUnsupported"
                    );
                }
            }
            let providers = document
                .get_mut("rule-providers")
                .and_then(|value| value.as_object_mut())
                .context("InvalidRuleProviders")?;
            let declaration = providers
                .remove(&remote.provider_name)
                .context("InvalidRuleProviders")?;
            validate_deferred_provider(&remote.provider_name, &declaration)?;
        }
        // Deferred declarations are validated but never substituted with an empty
        // executable payload. Only genuinely captured local assets reach parsing.
        Config::parse_with_assets(
            &crate::override_script::runtime_source(&serde_json::to_vec(&document)?)?,
            &assets,
        )?;
        Ok(())
    }
    /// False denotes only the designated raw Shadowsocks plugin recovery case.
    pub fn catalog_ready(&self) -> Result<bool> {
        let runtime_error =
            match self.validate_offline(std::str::from_utf8(self.effective_source())?) {
                Ok(_) => return Ok(true),
                Err(error) => error,
            };
        // Recovery is exclusively for original raw input. An override is an
        // explicit materialization and must satisfy all runtime capabilities.
        if self.materialized.is_some() {
            return Err(runtime_error);
        }
        let mut doc = parse_document(&self.source)?;
        let mut removed = false;
        if let Some(proxies) = doc.get_mut("proxies").and_then(|v| v.as_array_mut()) {
            for proxy in proxies {
                if proxy.get("type").and_then(|v| v.as_str()) == Some("ss")
                    && let Some(map) = proxy.as_object_mut()
                {
                    for field in ["plugin", "plugin-opts", "plugin_opts"] {
                        removed |= map.remove(field).is_some();
                    }
                }
            }
        }
        if removed && self.validate_offline(&serde_json::to_string(&doc)?).is_ok() {
            return Ok(false);
        }
        Err(runtime_error)
    }
}

fn validate_deferred_provider(name: &str, value: &serde_json::Value) -> Result<()> {
    let map = value.as_object().context("InvalidRuleProvider")?;
    ensure!(
        !name.is_empty()
            && name.trim() == name
            && !name.contains(',')
            && !name.chars().any(char::is_control),
        "InvalidRuleProviderName"
    );
    ensure!(
        map.keys().all(|key| matches!(
            key.as_str(),
            "type" | "behavior" | "url" | "path" | "interval"
        )),
        "InvalidRuleProvider"
    );
    ensure!(
        matches!(
            value.get("type").and_then(|v| v.as_str()),
            Some("http" | "file")
        ),
        "InvalidRuleProviderType"
    );
    ensure!(
        matches!(
            value.get("behavior").and_then(|v| v.as_str()),
            Some("domain" | "ipcidr" | "classical")
        ),
        "InvalidRuleProviderBehavior"
    );
    ensure!(
        value
            .get("path")
            .and_then(|v| v.as_str())
            .is_some_and(|path| !path.is_empty() && !path.contains('\0')),
        "InvalidRuleProviderPath"
    );
    ensure!(
        value
            .get("interval")
            .is_none_or(|v| v.as_u64().is_some_and(|n| n > 0 && n <= u32::MAX as u64)),
        "InvalidRuleProviderInterval"
    );
    let url = reqwest::Url::parse(
        value
            .get("url")
            .and_then(|v| v.as_str())
            .context("InvalidRuleProviderUrl")?,
    )?;
    ensure!(
        matches!(url.scheme(), "http" | "https") && url.host_str().is_some(),
        "InvalidRuleProviderUrl"
    );
    Ok(())
}

fn parse_document(bytes: &[u8]) -> Result<serde_json::Value> {
    ensure!(bytes.len() <= FILE_LIMIT, "SourceTooLarge");
    crate::config::parse_document(std::str::from_utf8(bytes)?)
}
fn provider_refs(doc: &serde_json::Value) -> Result<(BTreeSet<String>, Vec<RemoteProvider>)> {
    let mut local = BTreeSet::new();
    let mut remote = Vec::new();
    if let Some(value) = doc.get("rule-providers") {
        let providers = value.as_object().context("InvalidRuleProviders")?;
        ensure!(providers.len() <= 4096, "TooManyAssets");
        for (name, provider) in providers {
            let path = provider
                .get("path")
                .and_then(|v| v.as_str())
                .context("InvalidRuleProviderPath")?;
            if provider.get("url").is_some_and(|v| !v.is_null()) {
                remote.push(RemoteProvider {
                    provider_name: name.clone(),
                    logical_path: path.to_owned(),
                    remote_deferred: true,
                });
            } else {
                local.insert(path.to_owned());
            }
        }
    }
    remote.sort_by(|a, b| a.provider_name.cmp(&b.provider_name));
    Ok((local, remote))
}

fn hex(bytes: &[u8]) -> String {
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}
fn digest(bytes: &[u8]) -> String {
    hex(&Sha256::digest(bytes))
}
fn unhex(text: &str, count: usize) -> Result<Vec<u8>> {
    ensure!(
        text.len() == count * 2
            && text
                .bytes()
                .all(|c| c.is_ascii_digit() || (b'a'..=b'f').contains(&c)),
        "InvalidDigest"
    );
    (0..count)
        .map(|i| Ok(u8::from_str_radix(&text[i * 2..i * 2 + 2], 16)?))
        .collect()
}
fn hash_u64(h: &mut Sha256, n: usize) {
    h.update((n as u64).to_be_bytes());
}
fn hash_bytes(h: &mut Sha256, bytes: &[u8]) {
    hash_u64(h, bytes.len());
    h.update(bytes);
}
fn hash_optional(h: &mut Sha256, value: Option<&str>) {
    h.update([u8::from(value.is_some())]);
    if let Some(s) = value {
        hash_bytes(h, s.as_bytes());
    }
}
pub fn storage_id(key: &str) -> String {
    let mut h = Sha256::new();
    h.update(b"zc.profile-storage.v1");
    hash_bytes(&mut h, key.as_bytes());
    hex(&h.finalize())
}
pub fn legacy_revision(key: &str) -> String {
    let mut h = Sha256::new();
    h.update(b"zc.legacy-key.v1");
    hash_bytes(&mut h, key.as_bytes());
    hex(&h.finalize()[..16])
}
fn revision_id(key: &str, content: &[u8]) -> String {
    let mut h = Sha256::new();
    h.update(b"zc.migration-incarnation.v1");
    hash_bytes(&mut h, key.as_bytes());
    h.update(content);
    let incarnation = h.finalize();
    let mut h = Sha256::new();
    h.update(b"zc.revision.v1");
    h.update(content);
    h.update(incarnation);
    hex(&h.finalize()[..16])
}
fn content_digest(
    key: &str,
    bundle: &Bundle,
    meta: &Metadata,
    frozen: Option<&FrozenOverride>,
) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(b"zc.revision-content.v1");
    hash_bytes(&mut h, key.as_bytes());
    hash_optional(&mut h, meta.url.as_deref());
    hash_optional(&mut h, meta.filename.as_deref());
    for p in &meta.params {
        hash_bytes(&mut h, p.key.as_bytes());
        hash_bytes(&mut h, p.value.as_bytes());
    }
    hash_u64(&mut h, meta.params.len());
    if let Some(v) = frozen {
        h.update(b"zc.override-materialization.v1");
        hash_bytes(&mut h, v.script_name.as_bytes());
        hash_bytes(&mut h, &v.script_bytes);
        hash_bytes(&mut h, v.command.as_bytes());
        hash_optional(&mut h, v.config_path.as_deref());
        hash_u64(&mut h, v.timeout_ms as usize);
        for p in &v.args {
            hash_bytes(&mut h, p.key.as_bytes());
            hash_bytes(&mut h, p.value.as_bytes());
        }
        hash_u64(&mut h, v.args.len());
        hash_bytes(&mut h, &v.patch_bytes);
    }
    hash_content(&mut h, &bundle.source);
    h.update([u8::from(bundle.materialized.is_some())]);
    if let Some(v) = &bundle.materialized {
        hash_content(&mut h, v);
    }
    hash_u64(&mut h, bundle.aggregate());
    for (logical, a) in &bundle.assets {
        hash_bytes(&mut h, logical.as_bytes());
        hash_bytes(&mut h, a.canonical_relative_target.as_bytes());
        hash_content(&mut h, &a.bytes);
    }
    hash_u64(&mut h, bundle.assets.len());
    for r in &bundle.remotes {
        hash_bytes(&mut h, r.provider_name.as_bytes());
        hash_bytes(&mut h, r.logical_path.as_bytes());
    }
    hash_u64(&mut h, bundle.remotes.len());
    h.finalize().into()
}
fn hash_content(h: &mut Sha256, bytes: &[u8]) {
    hash_u64(h, bytes.len());
    h.update(Sha256::digest(bytes));
}
fn line<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    let mut v = serde_json::to_vec(value)?;
    v.push(b'\n');
    Ok(v)
}
fn safe_text(s: &str) -> bool {
    !s.is_empty() && !s.chars().any(|c| matches!(c as u32, 0..=31 | 127..=159 | 0x61c | 0x200e | 0x200f | 0x2028..=0x202e | 0x2066..=0x2069 | 0xfeff))
}
pub fn valid_key(key: &str) -> bool {
    key.len() <= 250 && stored_key(key)
}
fn stored_key(key: &str) -> bool {
    key.len() <= 255 && fsutil::single_component(key) && safe_text(key)
}
fn validate_selections(selections: &mut [Selection]) -> Result<()> {
    ensure!(
        selections.len() <= 1024,
        "PersistedSelectionCountLimitExceeded"
    );
    selections.sort_by(|a, b| a.group.cmp(&b.group));
    ensure!(
        selections
            .iter()
            .all(|s| safe_text(&s.group) && safe_text(&s.proxy))
            && selections.windows(2).all(|w| w[0].group != w[1].group),
        "InvalidSelections"
    );
    Ok(())
}
fn canonical(mut catalog: Catalog) -> Result<Vec<u8>> {
    ensure!(catalog.schema_version == 2, "InvalidCatalog");
    catalog.profiles.sort_by(|a, b| a.key.cmp(&b.key));
    ensure!(
        catalog.profiles.windows(2).all(|w| w[0].key != w[1].key),
        "InvalidCatalog"
    );
    for p in &mut catalog.profiles {
        ensure!(
            stored_key(&p.key) && p.storage_id == storage_id(&p.key),
            "InvalidCatalog"
        );
        unhex(&p.head, 16)?;
        validate_selections(&mut p.desired.selections)?;
    }
    if let Some(a) = &catalog.active {
        ensure!(
            catalog
                .profiles
                .iter()
                .any(|p| p.key == a.key && p.head == a.revision),
            "InvalidCatalog"
        );
    }
    let bytes = line(&catalog)?;
    ensure!(bytes.len() <= CATALOG_LIMIT, "CatalogTooLarge");
    Ok(bytes)
}
fn canonical_next(catalog: &Catalog) -> Result<Vec<u8>> {
    let mut next = catalog.clone();
    next.sequence = next.sequence.checked_add(1).context("SequenceOverflow")?;
    canonical(next)
}
fn token(bytes: Option<&[u8]>, sequence: u64) -> StateToken {
    let mut h = Sha256::new();
    if let Some(bytes) = bytes {
        h.update(b"zc.state-token.v1");
        hash_bytes(&mut h, bytes);
    } else {
        h.update(b"zc.state.missing.v1");
    }
    StateToken {
        format: if bytes.is_some() {
            StateFormat::CatalogV2
        } else {
            StateFormat::Missing
        },
        sequence,
        digest: hex(&h.finalize()),
    }
}

#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Identity {
    schema_version: u32,
    key: String,
    storage_id: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Content {
    size: usize,
    sha256: String,
}
impl Content {
    fn of(bytes: &[u8]) -> Self {
        Self {
            size: bytes.len(),
            sha256: digest(bytes),
        }
    }
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DiskOverride {
    script_name: String,
    script: Content,
    command: String,
    config_path: Option<String>,
    timeout_ms: u32,
    args: Vec<Param>,
    patch: Content,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct DiskAsset {
    logical_path: String,
    canonical_relative_target: String,
    object_id: String,
    size: usize,
    sha256: String,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Manifest {
    schema_version: u32,
    key: String,
    storage_id: String,
    revision: String,
    content_digest: String,
    metadata: Metadata,
    #[serde(default, rename = "override")]
    frozen: Option<DiskOverride>,
    source: Content,
    materialized_source: Option<Content>,
    aggregate_bytes: usize,
    local_assets: Vec<DiskAsset>,
    remote_providers: Vec<RemoteProvider>,
}
fn validate_metadata(meta: &Metadata) -> Result<()> {
    ensure!(
        meta.params.iter().all(|p| !p.key.is_empty())
            && meta.params.windows(2).all(|w| w[0].key < w[1].key),
        "InvalidMetadata"
    );
    Ok(())
}
fn validate_override(bundle: &Bundle, frozen: Option<&FrozenOverride>) -> Result<()> {
    if let Some(v) = frozen {
        ensure!(
            bundle.materialized.is_some(),
            "OverrideMaterializationMismatch"
        );
        ensure!(
            fsutil::single_component(&v.script_name)
                && !v.script_bytes.is_empty()
                && v.script_bytes.len() <= MANIFEST_LIMIT
                && v.patch_bytes.len() <= MANIFEST_LIMIT
                && !v.command.is_empty()
                && !v.command.contains('\0')
                && v.config_path.as_ref().is_none_or(|s| !s.contains('\0'))
                && v.args
                    .iter()
                    .all(|a| !a.key.is_empty() && !a.key.contains('\0') && !a.value.contains('\0')),
            "InvalidOverrideMaterialization"
        );
    }
    Ok(())
}

#[derive(Debug)]
pub struct Store {
    root: SecureDir,
    legacy_root: File,
    path: PathBuf,
    lock_timeout: Duration,
    durability_uncertain: AtomicBool,
}
impl Store {
    pub fn open(root: impl AsRef<Path>) -> Result<Self> {
        Self::open_with_timeout(root, Duration::from_secs(5))
    }
    pub fn open_with_timeout(root: impl AsRef<Path>, lock_timeout: Duration) -> Result<Self> {
        let path = root.as_ref().to_path_buf();
        if !path.try_exists()? && path.symlink_metadata().is_err() {
            SecureDir::create(&path)?;
        }
        let legacy_root = open_legacy_directory(rustix::fs::CWD, &path)?;
        // Older Zig directories used the process umask. Tighten only our owned
        // root, never HOME or its ancestors; reject writable shared state.
        use std::os::unix::fs::MetadataExt;
        let metadata = legacy_root.metadata()?;
        ensure!(
            metadata.uid() == rustix::process::geteuid().as_raw() && metadata.mode() & 0o022 == 0,
            "InvalidLegacyLayout"
        );
        rustix::fs::fchmod(&legacy_root, rustix::fs::Mode::from_raw_mode(0o700))?;
        let root = SecureDir::open(&path)?;
        ensure!(
            same_inode(&legacy_root.metadata()?, &std::fs::symlink_metadata(&path)?),
            "SourceChanged"
        );
        Ok(Self {
            root,
            legacy_root,
            path,
            lock_timeout,
            durability_uncertain: AtomicBool::new(false),
        })
    }
    pub fn default_root() -> Result<PathBuf> {
        Ok(fsutil::default_store_root()?)
    }
    pub fn root_path(&self) -> &Path {
        &self.path
    }
    /// Retained for this reader's lifetime; it is not a persistent health bit.
    pub fn durability_uncertain(&self) -> bool {
        self.durability_uncertain.load(Ordering::Relaxed)
    }
    fn lock(&self) -> Result<fsutil::FileLock> {
        self.root
            .lock("state-v2.lock", self.lock_timeout)
            .context("acquire catalog lock")
    }
    fn inspect(&self) -> Result<Snapshot> {
        let bytes = match self.root.read("state-v2.json", CATALOG_LIMIT) {
            Ok(b) => b,
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                if self.root.exists("meta.json")? || self.root.exists("configs")? {
                    return Err(StoreError::LegacyTakeoverRequired.into());
                }
                return Ok(Snapshot {
                    durability_uncertain: self.durability_uncertain(),
                    token: token(None, 0),
                    catalog: Catalog {
                        schema_version: 2,
                        sequence: 0,
                        active: None,
                        profiles: Vec::new(),
                    },
                });
            }
            Err(e) => return Err(anyhow::Error::new(e).context(StoreError::CorruptCatalog)),
        };
        let doc: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|_| StoreError::CorruptCatalog)?;
        let schema = doc
            .get("schema_version")
            .and_then(|v| v.as_u64())
            .ok_or(StoreError::CorruptCatalog)?;
        if schema == 1 {
            return Err(StoreError::LegacyTakeoverRequired.into());
        }
        if schema != 2 {
            return Err(StoreError::UnknownFormat(schema).into());
        }
        let catalog: Catalog =
            serde_json::from_slice(&bytes).map_err(|_| StoreError::CorruptCatalog)?;
        let encoded = canonical(catalog.clone()).map_err(|_| StoreError::CorruptCatalog)?;
        ensure!(encoded == bytes, StoreError::CorruptCatalog);
        Ok(Snapshot {
            durability_uncertain: self.durability_uncertain(),
            token: token(Some(&bytes), catalog.sequence),
            catalog,
        })
    }
    /// Load/list/get validate every immutable revision referenced by the catalog.
    pub fn load(&self) -> Result<Snapshot> {
        let guard = self.lock()?;
        let snapshot = match self.inspect() {
            Ok(snapshot) => snapshot,
            Err(error)
                if error.downcast_ref::<StoreError>()
                    == Some(&StoreError::LegacyTakeoverRequired) =>
            {
                drop(guard);
                return self.takeover();
            }
            Err(error) => return Err(error),
        };
        for p in &snapshot.catalog.profiles {
            self.read_bundle(&p.key, &p.head)?;
        }
        Ok(snapshot)
    }
    fn takeover(&self) -> Result<Snapshot> {
        let cutover = self.root.lock("legacy-cutover.lock", self.lock_timeout)?;
        let guard = self.lock()?;
        match self.inspect() {
            Ok(snapshot) if snapshot.token.format == StateFormat::CatalogV2 => {
                for profile in &snapshot.catalog.profiles {
                    self.read_bundle(&profile.key, &profile.head)?;
                }
                return Ok(snapshot);
            }
            Ok(_) => {}
            Err(error)
                if error.downcast_ref::<StoreError>()
                    == Some(&StoreError::LegacyTakeoverRequired) => {}
            Err(error) => return Err(error),
        }
        let authority_bytes =
            read_optional_legacy(&self.legacy_root, "state-v2.json", CATALOG_LIMIT)?;
        let authority = authority_bytes
            .as_deref()
            .map(parse_schema_one)
            .transpose()?;
        let legacy = capture_legacy(&self.legacy_root)?;
        let mut catalog = Catalog {
            schema_version: 2,
            sequence: authority.as_ref().map_or(0, |state| state.sequence),
            active: None,
            profiles: Vec::new(),
        };
        ensure!(catalog.sequence < u64::MAX, "SequenceOverflow");
        let mut prepared = Vec::new();
        for key in &legacy.keys {
            let metadata = legacy
                .metadata
                .configs
                .get(key)
                .cloned()
                .unwrap_or_default();
            let mut selections = metadata
                .selections
                .clone()
                .unwrap_or_default()
                .into_iter()
                .map(|(group, proxy)| Selection { group, proxy })
                .collect::<Vec<_>>();
            validate_selections(&mut selections).context("InvalidLegacyMetadata")?;
            let disk_metadata = Metadata {
                url: metadata.url.clone(),
                filename: metadata.filename.clone(),
                params: metadata
                    .params
                    .iter()
                    .map(|(key, value)| Param {
                        key: key.clone(),
                        value: value.clone(),
                    })
                    .collect(),
            };
            validate_metadata(&disk_metadata).context("InvalidLegacyMetadata")?;
            let configs = legacy.configs.as_ref().context("LegacyConfigMissing")?;
            let (bundle, frozen) =
                prepare_legacy(configs, key, metadata.override_script.as_deref())?;
            let ready = bundle.catalog_ready().context("InvalidLegacyConfig")?;
            validate_override(&bundle, frozen.as_ref())?;
            let content = content_digest(key, &bundle, &disk_metadata, frozen.as_ref());
            let revision = revision_id(key, &content);
            encode_revision(
                key,
                &revision,
                &content,
                &bundle,
                &disk_metadata,
                frozen.as_ref(),
            )?;
            self.preflight_existing_revision(key, &revision)?;
            catalog.profiles.push(Profile {
                key: key.clone(),
                storage_id: storage_id(key),
                head: revision.clone(),
                desired: Desired {
                    generation: u64::from(metadata.selections.is_some()),
                    selections,
                },
            });
            if legacy.metadata.active.as_deref() == Some(key) && ready {
                catalog.active = Some(ActiveIdentity {
                    key: key.clone(),
                    revision: revision.clone(),
                });
            }
            prepared.push((bundle, disk_metadata, frozen, content));
        }
        canonical_next(&catalog).context("InvalidLegacyMetadata")?;
        if let Some(authority) = &authority {
            ensure!(
                authority.profiles.len() == catalog.profiles.len()
                    && authority
                        .profiles
                        .iter()
                        .zip(&catalog.profiles)
                        .all(|(old, new)| old.key == new.key && old.head == new.head),
                "LegacyProofMismatch"
            );
        }
        let repeated = capture_legacy(&self.legacy_root).context("LegacyChanged")?;
        ensure!(
            legacy.meta_bytes == repeated.meta_bytes && legacy.keys == repeated.keys,
            "LegacyChanged"
        );
        for (profile, (bundle, _, frozen, _)) in catalog.profiles.iter().zip(&prepared) {
            if let Some(frozen) = frozen {
                let script_path = legacy.metadata.configs[&profile.key]
                    .override_script
                    .as_deref()
                    .context("InvalidLegacyOverride")?;
                ensure!(
                    fsutil::read_regular(script_path, MANIFEST_LIMIT)? == frozen.script_bytes,
                    "LegacyChanged"
                );
            }
            let recaptured = capture_legacy_bundle(
                repeated.configs.as_ref().context("LegacyConfigMissing")?,
                &profile.key,
                bundle.materialized(),
            )?;
            ensure!(&recaptured == bundle, "LegacyChanged");
        }
        cutover.validate(&self.root, "legacy-cutover.lock")?;
        guard.validate(&self.root, "state-v2.lock")?;
        ensure!(
            read_optional_legacy(&self.legacy_root, "state-v2.json", CATALOG_LIMIT)?
                == authority_bytes,
            StoreError::Conflict
        );
        // All logical rejection points precede immutable writes. Storage failure
        // may leave verified orphans; authority still switches exactly once.
        for (profile, (bundle, metadata, frozen, content)) in catalog.profiles.iter().zip(prepared)
        {
            self.publish_revision(
                &profile.key,
                &profile.head,
                &content,
                &bundle,
                metadata,
                frozen,
            )?;
        }
        cutover.validate(&self.root, "legacy-cutover.lock")?;
        ensure!(
            read_optional_legacy(&self.legacy_root, "state-v2.json", CATALOG_LIMIT)?
                == authority_bytes,
            StoreError::Conflict
        );
        self.commit(catalog, &guard)?;
        self.inspect()
    }
    fn preflight_existing_revision(&self, key: &str, revision: &str) -> Result<()> {
        // Only absence permits publication. Corrupt or unsafe existing paths
        // must fail before earlier profiles can leave new immutable orphans.
        let profiles = match self.root.child("profiles", false) {
            Ok(dir) => dir,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
            Err(error) => return Err(error.into()),
        };
        if !profiles.exists(&storage_id(key))? {
            return Ok(());
        }
        let profile = profiles.child(&storage_id(key), false)?;
        if profile.exists("identity.json")? {
            verify_identity(&profile, key)?;
        }
        if !profile.exists("revisions")? {
            return Ok(());
        }
        let revisions = profile.child("revisions", false)?;
        if revisions.exists(revision)? {
            self.read_bundle(key, revision)?;
        }
        Ok(())
    }
    pub fn list(&self) -> Result<Vec<Profile>> {
        Ok(self.load()?.catalog.profiles)
    }
    pub fn get(&self, key: &str) -> Result<Profile> {
        self.list()?
            .into_iter()
            .find(|p| p.key == key)
            .ok_or_else(|| StoreError::ProfileNotFound.into())
    }
    fn expected(&self, expected: &StateToken) -> Result<Catalog> {
        let snapshot = self.inspect()?;
        ensure!(&snapshot.token == expected, StoreError::Conflict);
        Ok(snapshot.catalog)
    }
    fn commit(&self, mut catalog: Catalog, guard: &fsutil::FileLock) -> Result<Receipt> {
        guard.validate(&self.root, "state-v2.lock")?;
        catalog.sequence = catalog
            .sequence
            .checked_add(1)
            .context("SequenceOverflow")?;
        let bytes = canonical(catalog.clone())?;
        let receipt = self.root.atomic_write("state-v2.json", &bytes)?;
        if receipt.durability_error.is_some() {
            self.durability_uncertain.store(true, Ordering::Relaxed);
        }
        Ok(Receipt {
            token: token(Some(&bytes), catalog.sequence),
            durability_error: receipt.durability_error,
        })
    }
    pub fn publish(
        &self,
        expected: &StateToken,
        key: &str,
        expected_head: Option<&str>,
        bundle: &Bundle,
        metadata: Metadata,
        activate: bool,
    ) -> Result<Receipt> {
        self.publish_frozen(
            expected,
            key,
            expected_head,
            bundle,
            metadata,
            None,
            activate,
        )
    }
    #[allow(clippy::too_many_arguments)]
    pub fn publish_frozen(
        &self,
        expected: &StateToken,
        key: &str,
        expected_head: Option<&str>,
        bundle: &Bundle,
        mut metadata: Metadata,
        frozen: Option<FrozenOverride>,
        activate: bool,
    ) -> Result<Receipt> {
        // Fresh bootstrap must exclude cooperative legacy writers before state CAS.
        let _cutover = if expected.format == StateFormat::Missing {
            Some(self.root.lock("legacy-cutover.lock", self.lock_timeout)?)
        } else {
            None
        };
        let _guard = self.lock()?;
        let mut catalog = self.expected(expected)?;
        let index = catalog.profiles.iter().position(|p| p.key == key);
        ensure!(
            index.map(|i| catalog.profiles[i].head.as_str()) == expected_head,
            StoreError::Conflict
        );
        ensure!(
            if index.is_none() {
                valid_key(key)
            } else {
                stored_key(key)
            },
            "InvalidKey"
        );
        let ready = bundle.catalog_ready()?;
        let active = activate || catalog.active.as_ref().is_some_and(|a| a.key == key);
        ensure!(!active || ready, StoreError::ProfileNotRuntimeReady);
        metadata.params.sort_by(|a, b| a.key.cmp(&b.key));
        validate_metadata(&metadata)?;
        validate_override(bundle, frozen.as_ref())?;
        let content = content_digest(key, bundle, &metadata, frozen.as_ref());
        let revision = revision_id(key, &content);
        let mut desired = index
            .map(|i| catalog.profiles[i].desired.clone())
            .unwrap_or_default();
        let document = parse_document(bundle.effective_source())?;
        let previous_count = desired.selections.len();
        desired.selections.retain(|selection| {
            ["proxies", "proxy-groups"]
                .iter()
                .filter_map(|key| document.get(*key).and_then(|value| value.as_array()))
                .flatten()
                .any(|group| {
                    group.get("name").and_then(|v| v.as_str()) == Some(&selection.group)
                        && group
                            .get("proxies")
                            .and_then(|v| v.as_array())
                            .is_some_and(|members| {
                                members
                                    .iter()
                                    .any(|member| member.as_str() == Some(&selection.proxy))
                            })
                })
        });
        if desired.selections.len() != previous_count {
            desired.generation = desired
                .generation
                .checked_add(1)
                .context("GenerationOverflow")?;
        }
        let profile = Profile {
            key: key.to_owned(),
            storage_id: storage_id(key),
            head: revision.clone(),
            desired,
        };
        if let Some(i) = index {
            catalog.profiles[i] = profile;
        } else {
            catalog.profiles.push(profile);
        }
        if active {
            catalog.active = Some(ActiveIdentity {
                key: key.to_owned(),
                revision: revision.clone(),
            });
        }
        // Complete deterministic state encoding before touching the revision tree.
        ensure!(catalog.sequence < u64::MAX, "SequenceOverflow");
        canonical_next(&catalog)?;
        self.publish_revision(key, &revision, &content, bundle, metadata, frozen)?;
        self.commit(catalog, &_guard)
    }
    pub fn activate(&self, expected: &StateToken, key: Option<&str>) -> Result<Receipt> {
        ensure!(
            expected.format == StateFormat::CatalogV2,
            "Schema2CatalogRequired"
        );
        let _guard = self.lock()?;
        let mut catalog = self.expected(expected)?;
        catalog.active = if let Some(key) = key {
            let p = catalog
                .profiles
                .iter()
                .find(|p| p.key == key)
                .ok_or(StoreError::ProfileNotFound)?;
            ensure!(
                self.read_bundle(&p.key, &p.head)?.bundle.catalog_ready()?,
                StoreError::ProfileNotRuntimeReady
            );
            Some(ActiveIdentity {
                key: p.key.clone(),
                revision: p.head.clone(),
            })
        } else {
            None
        };
        self.commit(catalog, &_guard)
    }
    pub fn delete(&self, expected: &StateToken, key: &str, head: &str) -> Result<Receipt> {
        let _guard = self.lock()?;
        let mut catalog = self.expected(expected)?;
        let i = catalog
            .profiles
            .iter()
            .position(|p| p.key == key)
            .ok_or(StoreError::ProfileNotFound)?;
        ensure!(catalog.profiles[i].head == head, StoreError::Conflict);
        catalog.profiles.remove(i);
        if catalog.active.as_ref().is_some_and(|a| a.key == key) {
            catalog.active = None;
        }
        self.commit(catalog, &_guard)
    }
    /// Atomically rename a key and derive its new identity; retain old revisions.
    pub fn rename(
        &self,
        expected: &StateToken,
        key: &str,
        head: &str,
        new_key: &str,
    ) -> Result<Receipt> {
        ensure!(valid_key(new_key), "InvalidKey");
        let _guard = self.lock()?;
        let mut catalog = self.expected(expected)?;
        ensure!(
            !catalog.profiles.iter().any(|p| p.key == new_key),
            "ProfileAlreadyExists"
        );
        let i = catalog
            .profiles
            .iter()
            .position(|p| p.key == key)
            .ok_or(StoreError::ProfileNotFound)?;
        ensure!(catalog.profiles[i].head == head, StoreError::Conflict);
        let view = self.read_bundle(key, head)?;
        let content = content_digest(
            new_key,
            &view.bundle,
            &view.metadata,
            view.frozen_override.as_ref(),
        );
        let revision = revision_id(new_key, &content);
        catalog.profiles[i].key = new_key.to_owned();
        catalog.profiles[i].storage_id = storage_id(new_key);
        catalog.profiles[i].head = revision.clone();
        if catalog.active.as_ref().is_some_and(|a| a.key == key) {
            catalog.active = Some(ActiveIdentity {
                key: new_key.to_owned(),
                revision: revision.clone(),
            });
        }
        ensure!(catalog.sequence < u64::MAX, "SequenceOverflow");
        canonical_next(&catalog)?;
        self.publish_revision(
            new_key,
            &revision,
            &content,
            &view.bundle,
            view.metadata,
            view.frozen_override,
        )?;
        self.commit(catalog, &_guard)
    }
    pub fn select(
        &self,
        expected: &StateToken,
        key: &str,
        head: &str,
        generation: u64,
        mut selections: Vec<Selection>,
    ) -> Result<Receipt> {
        validate_selections(&mut selections)?;
        let _guard = self.lock()?;
        let mut catalog = self.expected(expected)?;
        let p = catalog
            .profiles
            .iter_mut()
            .find(|p| p.key == key)
            .ok_or(StoreError::ProfileNotFound)?;
        ensure!(
            p.head == head && p.desired.generation == generation,
            StoreError::Conflict
        );
        self.read_bundle(key, head)?;
        p.desired = Desired {
            generation: generation.checked_add(1).context("GenerationOverflow")?,
            selections,
        };
        self.commit(catalog, &_guard)
    }
    fn profile_dir(&self, key: &str, create: bool) -> Result<SecureDir> {
        Ok(self
            .root
            .child("profiles", create)?
            .child(&storage_id(key), create)?)
    }
    fn publish_revision(
        &self,
        key: &str,
        revision: &str,
        content: &[u8],
        bundle: &Bundle,
        metadata: Metadata,
        frozen: Option<FrozenOverride>,
    ) -> Result<()> {
        let (identity_bytes, bytes) =
            encode_revision(key, revision, content, bundle, &metadata, frozen.as_ref())?;
        let profile = self.profile_dir(key, true)?;
        if profile.exists("identity.json")? {
            verify_identity(&profile, key)?;
        } else {
            match profile.install_new("identity.json", &identity_bytes) {
                Ok(receipt) => {
                    if let Some(error) = receipt.durability_error {
                        return Err(error.into());
                    }
                }
                Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {
                    verify_identity(&profile, key)?
                }
                Err(error) => return Err(error.into()),
            }
        }
        let revisions = profile.child("revisions", true)?;
        let _publish_lock = revisions.lock(".publish.lock", self.lock_timeout)?;
        if revisions.exists(revision)? {
            self.read_bundle(key, revision)?;
            // A prior rename may be visible despite a failed directory sync.
            // Never publish authority until the retry establishes durability.
            revisions.sync()?;
            return Ok(());
        }
        let staging_name = format!(".staging-{}", fsutil::nonce()?);
        let staging = revisions.child(&staging_name, true)?;
        staging.write_new("source.yaml", &bundle.source)?;
        if let Some(bytes) = &bundle.materialized {
            staging.write_new("materialized.yaml", bytes)?;
        }
        if let Some(v) = frozen {
            staging.write_new("override-script", &v.script_bytes)?;
            staging.write_new("override-output.yaml", &v.patch_bytes)?;
        }
        let objects = staging.child("objects", true)?;
        for a in bundle.assets.values() {
            let id = digest(&a.bytes);
            if !objects.exists(&id)? {
                objects.write_new(&id, &a.bytes)?;
            }
        }
        objects.sync()?;
        staging.write_new("manifest.json", &bytes)?;
        staging.sync()?;
        revisions.rename(&staging_name, revision)?;
        revisions.sync()?;
        Ok(())
    }
    pub fn read_bundle(&self, key: &str, revision: &str) -> Result<RevisionView> {
        self.read_revision(key, revision)
            .context(StoreError::CorruptRevision)
    }
    fn read_revision(&self, key: &str, revision: &str) -> Result<RevisionView> {
        ensure!(stored_key(key), "InvalidKey");
        unhex(revision, 16)?;
        let profile = self.profile_dir(key, false)?;
        verify_identity(&profile, key)?;
        let dir = profile.child("revisions", false)?.child(revision, false)?;
        let m: Manifest = serde_json::from_slice(&dir.read("manifest.json", MANIFEST_LIMIT)?)?;
        ensure!(
            m.schema_version == 1
                && m.key == key
                && m.storage_id == storage_id(key)
                && m.revision == revision,
            "RevisionIdentityMismatch"
        );
        ensure!(
            m.local_assets.len() <= 4096
                && m.remote_providers.len() <= 4096
                && m.aggregate_bytes <= AGGREGATE_LIMIT,
            "RevisionLimitExceeded"
        );
        validate_metadata(&m.metadata)?;
        let source = read_content(&dir, "source.yaml", &m.source, FILE_LIMIT)?;
        let materialized = if let Some(c) = &m.materialized_source {
            Some(read_content(&dir, "materialized.yaml", c, FILE_LIMIT)?)
        } else {
            ensure!(
                !dir.exists("materialized.yaml")?,
                "UnexpectedMaterialization"
            );
            None
        };
        let frozen = if let Some(v) = m.frozen {
            Some(FrozenOverride {
                script_name: v.script_name,
                script_bytes: read_content(&dir, "override-script", &v.script, MANIFEST_LIMIT)?,
                command: v.command,
                config_path: v.config_path,
                timeout_ms: v.timeout_ms,
                args: v.args,
                patch_bytes: read_content(&dir, "override-output.yaml", &v.patch, MANIFEST_LIMIT)?,
            })
        } else {
            ensure!(
                !dir.exists("override-script")? && !dir.exists("override-output.yaml")?,
                "UnexpectedOverride"
            );
            None
        };
        let objects = dir.child("objects", false)?;
        ensure!(
            m.local_assets
                .windows(2)
                .all(|w| w[0].logical_path < w[1].logical_path),
            "UnsortedAssets"
        );
        let mut assets = BTreeMap::new();
        let mut total = source.len() + materialized.as_ref().map_or(0, Vec::len);
        for a in m.local_assets {
            total = total.checked_add(a.size).context("AggregateTooLarge")?;
            ensure!(
                total <= m.aggregate_bytes && total <= AGGREGATE_LIMIT,
                "AggregateTooLarge"
            );
            unhex(&a.object_id, 32)?;
            ensure!(a.object_id == a.sha256, "ObjectDigestMismatch");
            let bytes = read_content(
                &objects,
                &a.object_id,
                &Content {
                    size: a.size,
                    sha256: a.sha256,
                },
                FILE_LIMIT,
            )?;
            assets.insert(
                a.logical_path,
                Asset {
                    canonical_relative_target: a.canonical_relative_target,
                    bytes,
                },
            );
        }
        ensure!(total == m.aggregate_bytes, "AggregateMismatch");
        ensure!(
            m.remote_providers.iter().all(|r| r.remote_deferred)
                && m.remote_providers
                    .windows(2)
                    .all(|w| w[0].provider_name < w[1].provider_name),
            "InvalidRemotes"
        );
        let bundle = Bundle {
            source,
            materialized,
            assets,
            remotes: m.remote_providers,
        };
        validate_override(&bundle, frozen.as_ref())?;
        let computed = content_digest(key, &bundle, &m.metadata, frozen.as_ref());
        ensure!(
            hex(&computed) == m.content_digest && revision_id(key, &computed) == revision,
            "ContentDigestMismatch"
        );
        Ok(RevisionView {
            key: key.to_owned(),
            storage_id: m.storage_id,
            revision: revision.to_owned(),
            content_digest: m.content_digest,
            metadata: m.metadata,
            frozen_override: frozen,
            bundle,
        })
    }
}
fn verify_identity(dir: &SecureDir, key: &str) -> Result<()> {
    let identity: Identity = serde_json::from_slice(&dir.read("identity.json", 64 * 1024)?)?;
    ensure!(
        identity.schema_version == 1
            && identity.key == key
            && identity.storage_id == storage_id(key),
        "IdentityMismatch"
    );
    Ok(())
}
fn read_content(dir: &SecureDir, name: &str, identity: &Content, limit: usize) -> Result<Vec<u8>> {
    ensure!(identity.size <= limit, "ContentTooLarge");
    unhex(&identity.sha256, 32)?;
    let bytes = dir.read(name, limit)?;
    ensure!(
        bytes.len() == identity.size && digest(&bytes) == identity.sha256,
        "ContentMismatch"
    );
    Ok(bytes)
}

fn encode_revision(
    key: &str,
    revision: &str,
    content: &[u8],
    bundle: &Bundle,
    metadata: &Metadata,
    frozen: Option<&FrozenOverride>,
) -> Result<(Vec<u8>, Vec<u8>)> {
    let id = storage_id(key);
    let identity = Identity {
        schema_version: 1,
        key: key.to_owned(),
        storage_id: id.clone(),
    };
    let manifest = Manifest {
        schema_version: 1,
        key: key.to_owned(),
        storage_id: id,
        revision: revision.to_owned(),
        content_digest: hex(content),
        metadata: metadata.clone(),
        frozen: frozen.as_ref().map(|v| DiskOverride {
            script_name: v.script_name.clone(),
            script: Content::of(&v.script_bytes),
            command: v.command.clone(),
            config_path: v.config_path.clone(),
            timeout_ms: v.timeout_ms,
            args: v.args.clone(),
            patch: Content::of(&v.patch_bytes),
        }),
        source: Content::of(&bundle.source),
        materialized_source: bundle.materialized.as_deref().map(Content::of),
        aggregate_bytes: bundle.aggregate(),
        local_assets: bundle
            .assets
            .iter()
            .map(|(k, a)| DiskAsset {
                logical_path: k.clone(),
                canonical_relative_target: a.canonical_relative_target.clone(),
                object_id: digest(&a.bytes),
                size: a.bytes.len(),
                sha256: digest(&a.bytes),
            })
            .collect(),
        remote_providers: bundle.remotes.clone(),
    };
    let bytes = line(&manifest)?;
    ensure!(bytes.len() <= MANIFEST_LIMIT, "ManifestTooLarge");
    let identity_bytes = line(&identity)?;
    ensure!(identity_bytes.len() <= 64 * 1024, "IdentityTooLarge");
    Ok((identity_bytes, bytes))
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyMetadata {
    url: Option<String>,
    filename: Option<String>,
    override_script: Option<String>,
    #[serde(default)]
    params: BTreeMap<String, String>,
    selections: Option<BTreeMap<String, String>>,
}
#[derive(Debug, Default, Deserialize)]
#[serde(deny_unknown_fields)]
struct LegacyMeta {
    active: Option<String>,
    configs: BTreeMap<String, LegacyMetadata>,
}
struct LegacySnapshot {
    meta_bytes: Option<Vec<u8>>,
    metadata: LegacyMeta,
    configs: Option<File>,
    keys: Vec<String>,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SchemaOneProfile {
    key: String,
    head: String,
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SchemaOne {
    schema_version: u32,
    sequence: u64,
    profiles: Vec<SchemaOneProfile>,
}
fn parse_schema_one(bytes: &[u8]) -> Result<SchemaOne> {
    let mut state: SchemaOne = serde_json::from_slice(bytes).context(StoreError::CorruptCatalog)?;
    ensure!(state.schema_version == 1, StoreError::CorruptCatalog);
    let mut keys = BTreeSet::new();
    for profile in &state.profiles {
        ensure!(
            stored_key(&profile.key) && keys.insert(&profile.key),
            StoreError::CorruptCatalog
        );
        unhex(&profile.head, 16).context(StoreError::CorruptCatalog)?;
    }
    state.profiles.sort_by(|a, b| a.key.cmp(&b.key));
    Ok(state)
}
fn parse_legacy_meta(bytes: &[u8]) -> Result<LegacyMeta> {
    // JSON syntax is required, and the bounded document visitor rejects duplicate
    // map keys instead of silently dropping a legacy profile or selection.
    serde_json::from_slice::<serde_json::Value>(bytes).context("InvalidLegacyMetadata")?;
    let document = parse_document(bytes).context("InvalidLegacyMetadata")?;
    ensure!(
        document.get("active").is_some() && document.get("configs").is_some(),
        "InvalidLegacyMetadata"
    );
    if let Some(configs) = document.get("configs").and_then(|v| v.as_object()) {
        for config in configs.values() {
            ensure!(
                config.get("selections").is_none_or(|v| v.is_object()),
                "InvalidLegacyMetadata"
            );
        }
    }
    let metadata: LegacyMeta = serde_json::from_value(document).context("InvalidLegacyMetadata")?;
    ensure!(
        metadata.active.as_ref().is_none_or(|key| stored_key(key))
            && metadata.configs.keys().all(|key| stored_key(key)),
        "InvalidLegacyKey"
    );
    Ok(metadata)
}
fn open_legacy_directory(fd: impl std::os::fd::AsFd, path: impl rustix::path::Arg) -> Result<File> {
    use rustix::fs::{Mode, OFlags, openat};
    Ok(openat(
        fd,
        path,
        OFlags::RDONLY | OFlags::DIRECTORY | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    )?
    .into())
}
fn same_inode(a: &std::fs::Metadata, b: &std::fs::Metadata) -> bool {
    use std::os::unix::fs::MetadataExt;
    a.dev() == b.dev() && a.ino() == b.ino()
}
fn read_optional_legacy(root: &File, name: &str, limit: usize) -> Result<Option<Vec<u8>>> {
    use rustix::fs::{Mode, OFlags, openat};
    let file: File = match openat(
        root,
        name,
        OFlags::RDONLY | OFlags::NONBLOCK | OFlags::NOFOLLOW | OFlags::CLOEXEC,
        Mode::empty(),
    ) {
        Ok(fd) => fd.into(),
        Err(rustix::io::Errno::NOENT) => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    let before = file.metadata()?;
    ensure!(
        before.is_file() && before.len() <= limit as u64,
        "InvalidLegacyFile"
    );
    let mut bytes = Vec::new();
    (&file).take(limit as u64 + 1).read_to_end(&mut bytes)?;
    let after = file.metadata()?;
    use std::os::unix::fs::MetadataExt;
    ensure!(
        bytes.len() <= limit
            && bytes.len() as u64 == before.len()
            && before.len() == after.len()
            && before.mtime() == after.mtime()
            && before.mtime_nsec() == after.mtime_nsec()
            && before.ctime() == after.ctime()
            && before.ctime_nsec() == after.ctime_nsec()
            && before.nlink() == after.nlink(),
        "LegacyChanged"
    );
    Ok(Some(bytes))
}
fn capture_legacy(root: &File) -> Result<LegacySnapshot> {
    let meta_bytes =
        read_optional_legacy(root, "meta.json", MANIFEST_LIMIT).context("InvalidLegacyMetadata")?;
    let metadata = meta_bytes
        .as_deref()
        .map(parse_legacy_meta)
        .transpose()?
        .unwrap_or_default();
    let configs = match open_legacy_directory(root, "configs") {
        Ok(file) => Some(file),
        Err(error)
            if error.downcast_ref::<rustix::io::Errno>() == Some(&rustix::io::Errno::NOENT) =>
        {
            None
        }
        Err(error) => return Err(error.context("InvalidLegacyLayout")),
    };
    let mut keys = Vec::new();
    if let Some(configs) = &configs {
        for entry in rustix::fs::Dir::read_from(configs)? {
            let entry = entry?;
            let name = entry.file_name().to_bytes();
            if !name.ends_with(b".yaml") {
                continue;
            }
            let key = std::str::from_utf8(&name[..name.len() - 5]).context("InvalidLegacyKey")?;
            ensure!(stored_key(key), "InvalidLegacyKey");
            ensure!(keys.len() < CATALOG_LIMIT / 128, "CatalogTooLarge");
            keys.push(key.to_owned());
        }
    }
    keys.sort();
    ensure!(
        keys.windows(2).all(|pair| pair[0] != pair[1]),
        "InvalidLegacyLayout"
    );
    ensure!(
        metadata
            .configs
            .keys()
            .all(|key| keys.binary_search(key).is_ok()),
        "LegacyConfigMissing"
    );
    ensure!(
        metadata
            .active
            .as_ref()
            .is_none_or(|key| keys.binary_search(key).is_ok()),
        "LegacyActiveMissing"
    );
    Ok(LegacySnapshot {
        meta_bytes,
        metadata,
        configs,
        keys,
    })
}
fn directory_path(file: &File) -> Result<PathBuf> {
    #[cfg(target_os = "macos")]
    {
        use std::os::unix::ffi::OsStrExt;
        Ok(PathBuf::from(std::ffi::OsStr::from_bytes(
            rustix::fs::getpath(file)?.to_bytes(),
        )))
    }
    #[cfg(target_os = "linux")]
    {
        use std::os::fd::AsRawFd;
        Ok(std::fs::read_link(format!(
            "/proc/self/fd/{}",
            file.as_raw_fd()
        ))?)
    }
}
fn legacy_source_path(configs: &File, key: &str) -> Result<PathBuf> {
    let path = directory_path(configs)?;
    ensure!(
        same_inode(&configs.metadata()?, &std::fs::symlink_metadata(&path)?),
        "LegacyChanged"
    );
    Ok(path.join(format!("{key}.yaml")))
}
fn capture_legacy_bundle(configs: &File, key: &str, materialized: Option<&[u8]>) -> Result<Bundle> {
    let path = legacy_source_path(configs, key)?;
    let bundle = Bundle::capture_materialized(&path, materialized)?;
    ensure!(legacy_source_path(configs, key)? == path, "LegacyChanged");
    Ok(bundle)
}
fn prepare_legacy(
    configs: &File,
    key: &str,
    script_path: Option<&str>,
) -> Result<(Bundle, Option<FrozenOverride>)> {
    let Some(script_path) = script_path else {
        return Ok((capture_legacy_bundle(configs, key, None)?, None));
    };
    let path = legacy_source_path(configs, key)?;
    let parent = path.parent().context("InvalidLegacyLayout")?;
    let (_, source) = fsutil::read_contained(
        parent,
        path.file_name()
            .and_then(|v| v.to_str())
            .context("InvalidLegacyKey")?,
        FILE_LIMIT,
    )?;
    let script_bytes =
        fsutil::read_regular(script_path, MANIFEST_LIMIT).context("InvalidLegacyOverride")?;
    ensure!(!script_bytes.is_empty(), "InvalidLegacyOverride");
    let script_name = Path::new(script_path)
        .file_name()
        .and_then(|v| v.to_str())
        .context("InvalidLegacyOverride")?
        .to_owned();
    let invocation = crate::override_script::Invocation {
        command: "legacy-migration".into(),
        config_path: path
            .canonicalize()?
            .to_str()
            .context("InvalidLegacyLayout")?
            .into(),
        script_path: script_path.into(),
        ..Default::default()
    };
    let script = crate::override_script::Script {
        name: script_name,
        bytes: script_bytes,
    };
    // load() is synchronous and may be called inside a Tokio runtime. Use a
    // dedicated thread for the bounded worker rather than nesting block_on.
    let executed = std::thread::spawn(move || -> Result<_> {
        tokio::runtime::Builder::new_current_thread()
            .enable_all()
            .build()?
            .block_on(crate::override_script::execute_bytes(&script, &invocation))
    })
    .join()
    .map_err(|_| anyhow::anyhow!("InvalidLegacyOverride: worker panicked"))??;
    let effective = crate::override_script::materialize_source(&source, &executed.patch_bytes)?;
    let bundle = capture_legacy_bundle(configs, key, Some(&effective))?;
    ensure!(bundle.source() == source, "LegacyChanged");
    let frozen = FrozenOverride {
        script_name: executed.script.name,
        script_bytes: executed.script.bytes,
        command: executed.invocation.command,
        config_path: Some(executed.invocation.config_path),
        timeout_ms: executed.invocation.timeout_ms,
        args: Vec::new(),
        patch_bytes: executed.patch_bytes,
    };
    Ok((bundle, Some(frozen)))
}
