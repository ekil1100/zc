//! Resolve immutable configuration inputs before opening any runtime listener.
use crate::{
    config::{self, Config},
    daemon::{Invocation, Prepared},
    fsutil,
    override_script::{self, CliOptions},
    store::{self, ActiveIdentity, Bundle, Desired, Store},
};
use anyhow::{Context, Result, bail, ensure};
use std::{
    collections::BTreeMap,
    path::{Path, PathBuf},
};

#[derive(Debug, Clone)]
pub struct PrepareOptions {
    pub config: Option<String>,
    pub port: Option<u16>,
    pub foreground: bool,
    pub command: String,
    pub override_options: CliOptions,
}
impl Default for PrepareOptions {
    fn default() -> Self {
        Self {
            config: None,
            port: None,
            foreground: false,
            command: "start".into(),
            override_options: CliOptions::default(),
        }
    }
}

pub struct Loaded {
    pub bundle: Bundle,
    pub identity: Option<ActiveIdentity>,
    pub desired: Desired,
    pub source_path: Option<String>,
}

pub fn key(name: &str) -> &str {
    name.strip_suffix(".yaml").unwrap_or(name)
}
pub fn validate_name(name: &str) -> Result<&str> {
    let name = key(name);
    ensure!(
        store::valid_key(name),
        "CONFIG_NAME_INVALID: invalid config name"
    );
    Ok(name)
}

/// Does not create a catalog or directory for a read of absent state.
pub fn existing_store() -> Result<Option<Store>> {
    let root = Store::default_root()?;
    match std::fs::symlink_metadata(&root) {
        Ok(_) => Ok(Some(Store::open(root)?)),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}
pub fn open_store() -> Result<Store> {
    Store::open(Store::default_root()?)
}

pub fn read_source(path: &Path) -> Result<Vec<u8>> {
    let bytes = fsutil::read_regular(path, store::FILE_LIMIT).map_err(|e| {
        if e.kind() == std::io::ErrorKind::FileTooLarge
            || e.to_string().contains("exceeds byte limit")
            || e.to_string().contains("too large")
        {
            anyhow::anyhow!("SourceTooLarge: configuration exceeds the 16 MiB limit")
        } else {
            anyhow::anyhow!(
                "cannot read configuration; use a bounded regular file ({})",
                e.kind()
            )
        }
    })?;
    std::str::from_utf8(&bytes).context("configuration must be UTF-8")?;
    Ok(bytes)
}

fn managed_selector(selector: &str, root: &Path) -> Option<String> {
    let path = Path::new(selector);
    if path.components().count() == 1 && !path.exists() {
        return Some(key(selector).into());
    }
    let parent = path.parent()?;
    if parent == root.join("configs") {
        return path.file_name()?.to_str().map(|s| key(s).into());
    }
    None
}

pub fn load(selector: Option<&str>) -> Result<Loaded> {
    let root = Store::default_root()?;
    let managed = selector.and_then(|s| managed_selector(s, &root));
    if selector.is_none() || managed.is_some() {
        let store =
            existing_store()?.context("START_CONFIG_NOT_SELECTED: no active config is selected")?;
        let snapshot = store.load()?;
        let identity = if let Some(key) = managed {
            let profile = snapshot
                .catalog
                .profiles
                .iter()
                .find(|p| p.key == key)
                .context("CONFIG_NOT_FOUND: config not found")?;
            ActiveIdentity {
                key,
                revision: profile.head.clone(),
            }
        } else {
            snapshot
                .catalog
                .active
                .context("START_CONFIG_NOT_SELECTED: no active config is selected")?
        };
        let profile = snapshot
            .catalog
            .profiles
            .iter()
            .find(|p| p.key == identity.key)
            .context("CorruptCatalog")?;
        let view = store.read_bundle(&identity.key, &identity.revision)?;
        return Ok(Loaded {
            bundle: view.bundle,
            identity: Some(identity),
            desired: profile.desired.clone(),
            source_path: selector.map(str::to_owned),
        });
    }
    let path = std::path::absolute(selector.context("configuration path required")?)?;
    // Read first for bounded, credential-free diagnostics and no special-file blocking.
    read_source(&path)?;
    let bundle = Bundle::capture_for_runtime(&path)
        .map_err(|e| anyhow::anyhow!("invalid configuration: {e:#}"))?;
    Ok(Loaded {
        bundle,
        identity: None,
        desired: Desired::default(),
        source_path: Some(path.to_string_lossy().into_owned()),
    })
}

pub fn asset_bytes(bundle: &Bundle) -> BTreeMap<String, Vec<u8>> {
    bundle
        .assets()
        .iter()
        .map(|(k, a)| (k.clone(), a.bytes.clone()))
        .collect()
}

/// Validate and freeze all local/remote provider bytes, one-shot overrides and selections.
pub async fn prepare(options: PrepareOptions) -> Result<Prepared> {
    let loaded = load(options.config.as_deref())?;
    prepare_loaded(loaded, options).await
}

pub async fn prepare_loaded(loaded: Loaded, options: PrepareOptions) -> Result<Prepared> {
    let mut source = loaded.bundle.effective_source().to_vec();
    let mut assets = asset_bytes(&loaded.bundle);
    // Hold the owned source directory before any script/network await. Never infer
    // a cache root from HOME, cwd, a managed mirror, or an absolute provider path.
    let source_dir = if loaded.identity.is_none()
        && (!loaded.bundle.remotes().is_empty() || options.override_options.script_path.is_some())
    {
        let path = loaded
            .source_path
            .as_deref()
            .context("unmanaged source path required")?;
        let root = Path::new(path)
            .parent()
            .context("unmanaged source root required")?
            .canonicalize()?;
        Some(fsutil::SecureDir::open_owned_absolute(&root, false)?)
    } else {
        if loaded.identity.is_some() {
            ensure!(
                loaded.bundle.catalog_ready()?,
                "CONFIG_CAPABILITY_UNSUPPORTED: managed revision is not runtime-ready"
            );
        }
        None
    };
    let source_file = source_dir
        .as_ref()
        .map(|root| {
            let name = loaded
                .source_path
                .as_deref()
                .and_then(|path| Path::new(path).file_name())
                .and_then(|name| name.to_str())
                .context("unmanaged source filename required")?;
            Ok::<_, anyhow::Error>(root.hold_cache_source(name)?)
        })
        .transpose()?;
    if let Some(script_path) = &options.override_options.script_path {
        let invocation = override_script::Invocation {
            command: options.command.replace(' ', "."),
            config_path: loaded.source_path.clone().unwrap_or_default(),
            script_path: script_path.clone(),
            timeout_ms: options.override_options.timeout_ms,
            args: options.override_options.args.clone(),
        };
        let execution = override_script::execute(&invocation).await?;
        source = override_script::materialize_source(&source, &execution.patch_bytes)?;
        let root = loaded
            .source_path
            .as_deref()
            .map(Path::new)
            .and_then(Path::parent)
            .unwrap_or(Path::new("."));
        let text = std::str::from_utf8(&source)?;
        // Existing immutable assets win over mutable files during managed preparation.
        let doc = config::parse_document(text)?;
        let missing_local = doc
            .get("rule-providers")
            .and_then(|v| v.as_object())
            .is_some_and(|providers| {
                providers.values().any(|p| {
                    p["type"] == "file"
                        && p["path"].as_str().is_some_and(|p| !assets.contains_key(p))
                })
            });
        if missing_local {
            for (path, bytes) in config::capture_file_assets(text, root)? {
                assets.entry(path).or_insert(bytes);
            }
        }
    }
    let text = std::str::from_utf8(&source).context("configuration must be UTF-8")?;
    let mut doc = config::parse_document(text)?;
    // Preserve standalone listener rejection before inserting the normalized mixed listener.
    if doc.get("mixed-port").is_none()
        && ["port", "socks-port"]
            .iter()
            .any(|k| doc.get(*k).and_then(|v| v.as_u64()).is_some_and(|n| n != 0))
    {
        bail!("standalone port/socks-port listeners are unsupported; use mixed-port");
    }
    let port = options.port.unwrap_or(7899);
    ensure!(port != 0, "START_PORT_INVALID: invalid port");
    doc["mixed-port"] = port.into();
    // Validate remote declarations and all node/rule references before either
    // pruning deferred managed metadata or performing unmanaged network IO.
    Config::validate_declarations(&override_script::runtime_source(&serde_json::to_vec(
        &doc,
    )?)?)?;
    if loaded.identity.is_some() {
        // Deferred remote metadata is not a mutable runtime dependency. Recheck
        // one-shot patches too; never fetch into an immutable managed revision.
        let remotes: Vec<String> = doc
            .get("rule-providers")
            .and_then(|value| value.as_object())
            .into_iter()
            .flat_map(|providers| providers.iter())
            .filter(|(_, provider)| provider.get("url").is_some() || provider["type"] == "http")
            .map(|(name, _)| name.clone())
            .collect();
        for name in remotes {
            let referenced = doc
                .get("rules")
                .and_then(|value| value.as_array())
                .into_iter()
                .flatten()
                .filter_map(|value| value.as_str())
                .any(|rule| {
                    let mut fields = rule.split(',').map(str::trim);
                    fields.next() == Some("RULE-SET") && fields.next() == Some(name.as_str())
                });
            ensure!(!referenced, "ManagedRemoteRuleProviderUnsupported");
            doc["rule-providers"].as_object_mut().unwrap().remove(&name);
        }
    }
    let source = serde_json::to_string(&doc)?;
    let runtime_source = override_script::runtime_source(source.as_bytes())?;
    if let Some(root) = &source_dir {
        let policy = if matches!(
            options.command.as_str(),
            "test" | "doctor" | "diag doctor" | "diag.doctor"
        ) {
            config::ProviderSyncPolicy::MissingOnly
        } else {
            config::ProviderSyncPolicy::Eager
        };
        assets =
            config::sync_http_assets(&runtime_source, root, policy, &assets, source_file.as_ref())
                .await?;
    }
    let config = Config::parse_with_assets(&runtime_source, &assets)?;
    let selections = reconcile_selections(&config, &loaded.desired.selections);
    config.set_selections(
        &selections
            .iter()
            .map(|s| (s.group.clone(), s.proxy.clone()))
            .collect(),
    )?;
    let mut generation = loaded.desired.generation;
    if selections != loaded.desired.selections
        && matches!(
            options.command.as_str(),
            "start" | "restart" | "reload" | "config update" | "config override"
        )
        && let Some(identity) = &loaded.identity
    {
        let store = existing_store()?.context("managed catalog disappeared during preparation")?;
        let snapshot = store.load()?;
        store.select(
            &snapshot.token,
            &identity.key,
            &identity.revision,
            generation,
            selections.clone(),
        )?;
        generation = generation
            .checked_add(1)
            .context("selection generation exhausted")?;
    }
    let source_path = loaded.source_path;
    Ok(Prepared {
        source,
        assets: assets
            .into_iter()
            .map(|(k, v)| Ok((k, String::from_utf8(v).context("provider must be UTF-8")?)))
            .collect::<Result<_>>()?,
        identity: loaded.identity,
        generation,
        selections,
        invocation: Invocation {
            foreground: options.foreground,
            prepared: true,
            config_path: options.config,
            source_path,
            port_override: options.port,
        },
        port,
        override_options: options.override_options,
    })
}

/// Stale persisted groups/members are ignored; only valid select groups survive.
pub fn reconcile_selections(
    config: &Config,
    selections: &[store::Selection],
) -> Vec<store::Selection> {
    selections
        .iter()
        .filter(|s| config.select(&s.group, &s.proxy).is_ok())
        .cloned()
        .collect()
}

pub fn prepared_config(prepared: &Prepared) -> Result<Config> {
    let assets = prepared
        .assets
        .iter()
        .map(|(k, v)| (k.clone(), v.as_bytes().to_vec()))
        .collect();
    let runtime_source = override_script::runtime_source(prepared.source.as_bytes())?;
    let config = Config::parse_with_assets(&runtime_source, &assets)?;
    config.set_selections(
        &prepared
            .selections
            .iter()
            .map(|s| (s.group.clone(), s.proxy.clone()))
            .collect(),
    )?;
    Ok(config)
}

pub fn source_root(path: &str) -> PathBuf {
    Path::new(path).parent().unwrap_or(Path::new(".")).into()
}

/// Doctor's original path loads and validates declarations, not provider bodies.
/// Syntax/I/O/override failures are outer errors; concrete semantic failures are
/// returned for CHECKS_FAILED rendering. No runtime configuration is published.
pub async fn diagnose_config(options: &PrepareOptions) -> Result<config::diagnostics::Diagnostics> {
    let root = Store::default_root()?;
    let mut source = match options.config.as_deref() {
        Some(path) if managed_selector(path, &root).is_none() => read_source(Path::new(path))?,
        selector => load(selector)?.bundle.effective_source().to_vec(),
    };
    config::parse_document(std::str::from_utf8(&source)?)?;
    let hints = match options.config.as_deref() {
        Some(path) if managed_selector(path, &root).is_none() => {
            config::diagnostics::migration_hints(&source)
        }
        // Zig scans an explicit file path, not a catalog name or the effective
        // override. A missing/oversized hint source never changes validation.
        Some(path) => fsutil::read_regular(Path::new(path), 1024 * 1024)
            .map(|bytes| config::diagnostics::migration_hints(&bytes))
            .unwrap_or_default(),
        None => Vec::new(),
    };
    if let Some(script_path) = &options.override_options.script_path {
        let execution = override_script::execute(&override_script::Invocation {
            command: options.command.replace(' ', "."),
            config_path: options.config.clone().unwrap_or_default(),
            script_path: script_path.clone(),
            timeout_ms: options.override_options.timeout_ms,
            args: options.override_options.args.clone(),
        })
        .await?;
        source = override_script::materialize_source(&source, &execution.patch_bytes)?;
    }
    // The same existing capability gate as materialized runtime inputs; this is
    // still a load failure, not a fabricated validator diagnostic.
    override_script::materialize_source(&source, b"{}")?;
    let mut document = config::parse_document(&override_script::runtime_source(&source)?)?;
    document["mixed-port"] = options.port.unwrap_or(7899).into();
    // Original applyRuntimePortSelection clears these compatibility declarations.
    document["port"] = 0.into();
    document["socks-port"] = 0.into();
    let original = config::parse_document(std::str::from_utf8(&source)?)?;
    let mut diagnostics = config::diagnostics::validate(&original, &document);
    diagnostics.migration_hints = hints;
    Ok(diagnostics)
}
