use crate::{
    override_script::CliOptions,
    store::{ActiveIdentity, Selection},
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Invocation {
    pub foreground: bool,
    pub prepared: bool,
    pub config_path: Option<String>,
    pub source_path: Option<String>,
    pub port_override: Option<u16>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Prepared {
    pub source: String,
    pub assets: BTreeMap<String, String>,
    pub identity: Option<ActiveIdentity>,
    pub generation: u64,
    pub selections: Vec<Selection>,
    pub invocation: Invocation,
    pub port: u16,
    pub override_options: CliOptions,
}

use crate::{
    api,
    config::Config,
    fsutil::{self, FileLock, SecureDir},
    runtime::Runtime,
    store::{self, Store},
};
use anyhow::{Context, Result, bail, ensure};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use std::{
    collections::BTreeSet,
    fs::File,
    io::{self, Write},
    path::{Path, PathBuf},
    process::{Child, Command, Stdio},
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
    time::{Duration, SystemTime},
};
use subtle::ConstantTimeEq;
use tokio::time::{Instant, sleep};

const LOCK_WAIT: Duration = Duration::from_secs(1);
const START_WAIT: Duration = Duration::from_secs(10);
const STOP_WAIT: Duration = Duration::from_secs(5);
const LOG_LIMIT: usize = 8 * 1024 * 1024;
const SNAPSHOT_LIMIT: usize = 6 * (store::FILE_LIMIT + store::AGGREGATE_LIMIT) + 1024 * 1024;
const DESCRIPTOR: &str = "zc.daemon.json";

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Descriptor {
    schema_version: u32,
    pid: u32,
    nonce: String,
    endpoint: Option<String>,
    identity: Option<ActiveIdentity>,
    generation: u64,
    ready: bool,
    invocation: Option<Invocation>,
}
#[derive(Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
struct Snapshot {
    schema_version: u32,
    nonce: String,
    prepared: Prepared,
}
struct Directory {
    path: PathBuf,
    dir: SecureDir,
}
fn home() -> Result<PathBuf> {
    let path = PathBuf::from(std::env::var_os("HOME").context("HOME is not configured")?);
    SecureDir::open_owned_absolute(&path, false)?;
    Ok(path)
}
fn fallback_parent(create: bool) -> Result<Directory> {
    let mut path = home()?;
    let mut dir = SecureDir::open_owned_absolute(&path, false)?;
    for name in [".local", "state", "zc"] {
        dir = dir.owned_child(name, create, false)?;
        path.push(name);
    }
    Ok(Directory { path, dir })
}
fn runtime_path() -> Result<PathBuf> {
    if let Some(path) = std::env::var_os("XDG_RUNTIME_DIR") {
        return Ok(path.into());
    }
    Ok(home()?.join(".local/state/zc/runtime"))
}
fn runtime_dir(create: bool) -> Result<Option<Directory>> {
    if let Some(path) = std::env::var_os("XDG_RUNTIME_DIR") {
        let path = PathBuf::from(path);
        let dir = SecureDir::open_owned_absolute(&path, true)
            .context("RUNTIME_DIRECTORY_INVALID: invalid XDG_RUNTIME_DIR")?;
        return Ok(Some(Directory { path, dir }));
    }
    let result = (|| -> Result<Directory> {
        let parent = fallback_parent(create)?;
        Ok(Directory {
            path: parent.path.join("runtime"),
            dir: parent.dir.owned_child("runtime", create, true)?,
        })
    })();
    match result {
        Ok(dir) => Ok(Some(dir)),
        Err(e) if !create && is_missing(&e) => Ok(None),
        Err(e) => Err(e),
    }
}
fn is_missing(e: &anyhow::Error) -> bool {
    e.downcast_ref::<io::Error>()
        .is_some_and(|e| e.kind() == io::ErrorKind::NotFound)
}
fn valid_hex(value: &str, length: usize) -> bool {
    value.len() == length
        && value
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'a'..=b'f').contains(&b))
}
fn encode<T: Serialize>(value: &T) -> Result<Vec<u8>> {
    let mut bytes = serde_json::to_vec(value)?;
    bytes.push(b'\n');
    Ok(bytes)
}
fn read_descriptor(dir: &SecureDir) -> Result<Option<Descriptor>> {
    let mut attempts = 0;
    let bytes = loop {
        match dir.read(DESCRIPTOR, 64 * 1024) {
            Ok(v) => break v,
            Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
            // An atomic publisher can unlink the inode between open and fstat.
            // Reopen only when the current path passes all ownership/link checks;
            // never accept the unlinked handle or relax persistent integrity errors.
            Err(e)
                if attempts < 3
                    && e.kind() == io::ErrorKind::InvalidData
                    && dir.file_metadata(DESCRIPTOR).is_ok() =>
            {
                attempts += 1;
            }
            Err(e) => return Err(e.into()),
        }
    };
    let d: Descriptor =
        serde_json::from_slice(&bytes).context("RUNTIME_DESCRIPTOR_INVALID: corrupt descriptor")?;
    ensure!(
        d.schema_version == 2 && d.pid > 0 && valid_hex(&d.nonce, 32) && encode(&d)? == bytes,
        "RUNTIME_DESCRIPTOR_INVALID: invalid descriptor"
    );
    ensure!(
        d.identity
            .as_ref()
            .is_none_or(|i| store::valid_key(&i.key) && valid_hex(&i.revision, 32)),
        "RUNTIME_DESCRIPTOR_INVALID: invalid identity"
    );
    ensure!(
        d.identity.is_some() || d.generation == 0,
        "RUNTIME_DESCRIPTOR_INVALID: unmanaged generation"
    );
    if let Some(endpoint) = &d.endpoint {
        let address: std::net::SocketAddr = endpoint.parse()?;
        ensure!(
            address.ip() == std::net::Ipv4Addr::LOCALHOST
                && address.port() != 0
                && address.to_string() == *endpoint,
            "RUNTIME_DESCRIPTOR_INVALID: invalid endpoint"
        );
    }
    if let Some(invocation) = &d.invocation {
        ensure!(
            !(invocation.prepared && invocation.foreground)
                && (!invocation.prepared || invocation.config_path.is_some())
                && invocation.port_override != Some(0),
            "RUNTIME_DESCRIPTOR_INVALID: invalid invocation"
        );
        for path in [&invocation.config_path, &invocation.source_path]
            .into_iter()
            .flatten()
        {
            ensure!(
                !path.is_empty() && path.len() <= 4096 && !path.contains('\0'),
                "RUNTIME_DESCRIPTOR_INVALID: invalid invocation path"
            );
        }
    }
    Ok(Some(d))
}
fn publish(dir: &SecureDir, descriptor: &Descriptor) -> Result<()> {
    let receipt = dir.atomic_write(DESCRIPTOR, &encode(descriptor)?)?;
    if let Some(error) = receipt.durability_error {
        // Rename is already visible. Reverting the runtime here would disagree
        // with the committed descriptor; report uncertainty instead.
        eprintln!("Runtime descriptor durability is uncertain: {error}");
        let _ = dir.append_bounded(
            "zc.log",
            b"Warning: runtime descriptor durability is uncertain.\n",
            LOG_LIMIT,
        );
    }
    Ok(())
}
fn pid(dir: &SecureDir) -> Result<Option<u32>> {
    match dir.read("zc.pid", 32) {
        Ok(bytes) => {
            let pid = std::str::from_utf8(&bytes)?.trim().parse::<u32>()?;
            ensure!(
                pid > 0 && pid <= i32::MAX as u32,
                "RUNTIME_PID_INVALID: invalid PID"
            );
            Ok(Some(pid))
        }
        Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(e) => Err(e.into()),
    }
}
fn alive(pid: u32) -> bool {
    rustix::process::Pid::from_raw(pid as i32)
        .is_some_and(|p| rustix::process::test_kill_process(p).is_ok())
}
fn lock_held(dir: &SecureDir) -> Result<bool> {
    match dir.lock("zc.lock", Duration::from_millis(1)) {
        Ok(_) => Ok(false),
        Err(e) if e.kind() == io::ErrorKind::TimedOut => Ok(true),
        Err(e) => Err(e.into()),
    }
}
fn daemon_process(pid: u32) -> Result<bool> {
    if !alive(pid) {
        return Ok(false);
    }
    #[cfg(target_os = "linux")]
    let bytes = {
        use std::io::Read;
        let mut bytes = Vec::new();
        File::open(format!("/proc/{pid}/cmdline"))?
            .take(64 * 1024 + 1)
            .read_to_end(&mut bytes)?;
        bytes
    };
    #[cfg(not(target_os = "linux"))]
    let bytes = {
        // Match the original targeted process probe, never a global PID scan.
        let output = Command::new("/bin/ps")
            .args(["-ww", "-o", "command=", "-p", &pid.to_string()])
            .output()?;
        if !output.status.success() {
            return Ok(false);
        }
        output.stdout
    };
    ensure!(
        bytes.len() <= 64 * 1024,
        "RUNTIME_IDENTITY_CHANGED: process command exceeds limit"
    );
    #[cfg(target_os = "linux")]
    let args: Vec<_> = bytes.split(|b| *b == 0).filter(|a| !a.is_empty()).collect();
    #[cfg(not(target_os = "linux"))]
    let args: Vec<_> = bytes
        .split(u8::is_ascii_whitespace)
        .filter(|a| !a.is_empty())
        .collect();
    let Some(binary) = args.first().and_then(|a| std::str::from_utf8(a).ok()) else {
        return Ok(false);
    };
    if !matches!(
        Path::new(binary).file_name().and_then(|n| n.to_str()),
        Some("zc" | "zclash")
    ) {
        return Ok(false);
    }
    Ok(args.contains(&b"--daemon-run".as_slice())
        || (args.contains(&b"--foreground".as_slice())
            && args.iter().skip(1).find(|a| !a.starts_with(b"-")) == Some(&&b"start"[..])))
}
fn observe(runtime: &Directory) -> Result<Option<Descriptor>> {
    runtime.dir.validate_path(&runtime.path)?;
    for _ in 0..4 {
        let d = read_descriptor(&runtime.dir)?;
        let lock_identity = runtime.dir.file_metadata("zc.lock").ok();
        let held = lock_held(&runtime.dir)?;
        let process = pid(&runtime.dir)?;
        if let Some(d) = d {
            if held {
                ensure!(
                    process == Some(d.pid) && daemon_process(d.pid)?,
                    "RUNTIME_IDENTITY_CHANGED: PID and daemon lock disagree"
                );
                use std::os::unix::fs::MetadataExt;
                let before =
                    lock_identity.context("RUNTIME_IDENTITY_CHANGED: missing daemon lock")?;
                let after = runtime.dir.file_metadata("zc.lock")?;
                ensure!(
                    before.dev() == after.dev()
                        && before.ino() == after.ino()
                        && lock_held(&runtime.dir)?
                        && pid(&runtime.dir)? == Some(d.pid),
                    "RUNTIME_IDENTITY_CHANGED: runtime changed during observation"
                );
                let next = read_descriptor(&runtime.dir)?;
                if next.as_ref() != Some(&d) {
                    ensure!(
                        next.as_ref()
                            .is_some_and(|next| next.pid == d.pid && next.nonce == d.nonce),
                        "RUNTIME_IDENTITY_CHANGED: runtime changed during observation"
                    );
                    continue;
                }
                runtime.dir.validate_path(&runtime.path)?;
                return Ok(Some(d));
            }
            ensure!(
                !alive(d.pid),
                "RUNTIME_IDENTITY_CHANGED: live PID without its daemon lock"
            );
        } else if held {
            return Ok(None);
        }
        if let Some(process) = process {
            ensure!(
                !alive(process),
                "RUNTIME_IDENTITY_CHANGED: unverified live PID"
            );
        }
        return Ok(None);
    }
    bail!("RUNTIME_IDENTITY_CHANGED: descriptor did not stabilize")
}
fn parse_config(prepared: &Prepared) -> Result<Config> {
    ensure!(
        prepared.source.len() <= store::FILE_LIMIT
            && prepared.assets.len() <= 4096
            && prepared.assets.values().map(String::len).sum::<usize>() <= store::AGGREGATE_LIMIT,
        "START_CONFIG_INVALID: prepared source limit exceeded"
    );
    ensure!(
        prepared
            .identity
            .as_ref()
            .is_none_or(|i| store::valid_key(&i.key) && valid_hex(&i.revision, 32)),
        "START_CONFIG_INVALID: invalid prepared identity"
    );
    ensure!(
        prepared.port != 0,
        "START_PORT_INVALID: port must be nonzero"
    );
    ensure!(
        prepared.identity.is_some() || prepared.generation == 0,
        "START_FAILED: unmanaged generation"
    );
    let assets = prepared
        .assets
        .iter()
        .map(|(k, v)| (k.clone(), v.as_bytes().to_vec()))
        .collect();
    let runtime_source = crate::override_script::runtime_source(prepared.source.as_bytes())?;
    let config = Config::parse_with_assets(&runtime_source, &assets)
        .context("START_CONFIG_INVALID: invalid prepared configuration")?;
    config.set_selections(&selection_map(&prepared.selections)?)?;
    ensure!(
        config
            .controller_endpoint()
            .is_none_or(|a| a.port() != prepared.port),
        "START_PORT_CONFLICT: mixed and controller ports must differ"
    );
    Ok(config)
}
fn selection_map(selections: &[Selection]) -> Result<BTreeMap<String, String>> {
    ensure!(selections.len() <= 1024, "selection count limit exceeded");
    let mut map = BTreeMap::new();
    for entry in selections {
        ensure!(
            map.insert(entry.group.clone(), entry.proxy.clone())
                .is_none(),
            "duplicate selection"
        );
    }
    Ok(map)
}
fn hmac(key: &[u8], bytes: &[u8]) -> String {
    let mut inner = [0x36; 64];
    let mut outer = [0x5c; 64];
    for (index, byte) in key.iter().enumerate() {
        inner[index] ^= byte;
        outer[index] ^= byte;
    }
    let mut hash = Sha256::new();
    hash.update(inner);
    hash.update(bytes);
    let mut mac = Sha256::new();
    mac.update(outer);
    mac.update(hash.finalize());
    mac.finalize().iter().map(|b| format!("{b:02x}")).collect()
}
fn snapshot_key(dir: &SecureDir, create: bool) -> Result<Vec<u8>> {
    let _guard = dir.lock("zc.prepared.key.lock", LOCK_WAIT)?;
    if !dir.exists("zc.prepared.key")? && create {
        let mut bytes = [0; 32];
        getrandom::fill(&mut bytes).map_err(io::Error::other)?;
        dir.write_new("zc.prepared.key", &bytes)?;
        dir.sync()?;
    }
    let key = dir.read("zc.prepared.key", 32)?;
    ensure!(
        key.len() == 32,
        "START_SNAPSHOT_INVALID: invalid snapshot key"
    );
    Ok(key)
}
fn save_snapshot(dir: &SecureDir, prepared: Prepared, nonce: &str) -> Result<String> {
    let bytes = encode(&Snapshot {
        schema_version: 1,
        nonce: nonce.into(),
        prepared,
    })?;
    ensure!(
        bytes.len() <= SNAPSHOT_LIMIT,
        "START_SNAPSHOT_INVALID: snapshot too large"
    );
    let mac = hmac(&snapshot_key(dir, true)?, &bytes);
    let name = format!("zc.prepared.{mac}.{nonce}.snapshot");
    if dir.exists(&name)? {
        ensure!(
            dir.read(&name, SNAPSHOT_LIMIT)? == bytes,
            "START_SNAPSHOT_INVALID: immutable snapshot changed"
        );
    } else {
        dir.write_new(&name, &bytes)?;
        dir.sync()?;
    }
    Ok(name)
}
fn load_snapshot(dir: &SecureDir, name: &str, nonce: &str) -> Result<Prepared> {
    ensure!(
        valid_hex(nonce, 32) && fsutil::single_component(name),
        "START_SNAPSHOT_INVALID: invalid snapshot name"
    );
    let parts: Vec<_> = name.split('.').collect();
    ensure!(
        parts.len() == 5
            && parts[0] == "zc"
            && parts[1] == "prepared"
            && valid_hex(parts[2], 64)
            && parts[3] == nonce
            && parts[4] == "snapshot",
        "START_SNAPSHOT_INVALID: invalid snapshot name"
    );
    let bytes = dir.read(name, SNAPSHOT_LIMIT)?;
    ensure!(
        bool::from(
            hmac(&snapshot_key(dir, false)?, &bytes)
                .as_bytes()
                .ct_eq(parts[2].as_bytes())
        ),
        "START_SNAPSHOT_INVALID: snapshot authentication failed"
    );
    let snapshot: Snapshot = serde_json::from_slice(&bytes)?;
    ensure!(
        snapshot.schema_version == 1 && snapshot.nonce == nonce,
        "START_SNAPSHOT_INVALID: snapshot nonce mismatch"
    );
    Ok(snapshot.prepared)
}
fn decode_hex(text: &str, limit: usize) -> Result<String> {
    ensure!(
        !text.is_empty()
            && text.len() <= limit * 2
            && text.len().is_multiple_of(2)
            && text.bytes().all(|b| b.is_ascii_hexdigit()),
        "START_SNAPSHOT_INVALID: invalid hex metadata"
    );
    let bytes: Result<Vec<_>, _> = (0..text.len())
        .step_by(2)
        .map(|n| u8::from_str_radix(&text[n..n + 2], 16))
        .collect();
    let result = String::from_utf8(bytes?)?;
    ensure!(
        !result.contains('\0'),
        "START_SNAPSHOT_INVALID: NUL in metadata"
    );
    Ok(result)
}
// Decode the original runtime serializer, not a general configuration fallback.
// It emits inert defaults that are absent from the strict user-facing schema.
fn zig_runtime_source(yaml: &str) -> Result<String> {
    let mut document = crate::config::parse_document(yaml)?;
    let map = document
        .as_object_mut()
        .context("START_SNAPSHOT_INVALID: expected mapping")?;
    for (field, default) in [
        ("redir-port", json!(0)),
        ("tproxy-port", json!(0)),
        ("ipv6", json!(true)),
        ("idle-session-check-interval", json!(30)),
        ("idle-session-timeout", json!(30)),
        ("min-idle-session", json!(0)),
    ] {
        if let Some(value) = map.remove(field) {
            ensure!(
                value == default,
                "START_SNAPSHOT_INVALID: unsupported runtime snapshot field {field}"
            );
        }
    }
    // Zig resolves all non-LAN listener addresses to loopback at runtime.
    if map.get("allow-lan") == Some(&json!(false)) {
        map.insert("bind-address".into(), json!("127.0.0.1"));
    }
    if let Some(groups) = map.get_mut("proxy-groups").and_then(Value::as_array_mut) {
        for group in groups {
            let group = group
                .as_object_mut()
                .context("START_SNAPSHOT_INVALID: invalid group")?;
            if group.get("type") == Some(&json!("select")) {
                for (field, default) in [
                    ("interval", json!(300)),
                    ("tolerance", json!(100)),
                    ("lazy", json!(true)),
                ] {
                    if let Some(value) = group.remove(field) {
                        ensure!(
                            value == default,
                            "START_SNAPSHOT_INVALID: unsupported group snapshot field {field}"
                        );
                    }
                }
            }
        }
    }
    Ok(serde_json::to_string(&document)?)
}
fn load_zig_prepared(dir: &SecureDir, name: &str, descriptor: &Descriptor) -> Result<Prepared> {
    let parts: Vec<_> = name.split('.').collect();
    ensure!(
        fsutil::single_component(name)
            && parts.len() == 5
            && parts[0] == "zc"
            && parts[1] == "prepared"
            && valid_hex(parts[2], 64)
            && valid_hex(parts[3], 32)
            && parts[4] == "yaml",
        "START_SNAPSHOT_INVALID: invalid prepared name"
    );
    // Zig's file nonce is independently generated; only its HMAC authenticates
    // the immutable envelope. The instance nonce belongs to the descriptor.
    let bytes = dir.read(name, store::FILE_LIMIT + 16 * 1024)?;
    ensure!(
        bool::from(
            hmac(&snapshot_key(dir, false)?, &bytes)
                .as_bytes()
                .ct_eq(parts[2].as_bytes())
        ),
        "START_SNAPSHOT_INVALID: snapshot authentication failed"
    );
    let text = std::str::from_utf8(&bytes)?;
    let mut lines = text.splitn(4, '\n');
    let encoded = lines
        .next()
        .and_then(|v| v.strip_prefix("# zc-prepared-v1 "))
        .context("START_SNAPSHOT_INVALID: missing identity header")?;
    let identity = if encoded == "-" {
        None
    } else {
        let (key, revision) = encoded
            .split_once(':')
            .context("START_SNAPSHOT_INVALID: invalid identity")?;
        let key = decode_hex(key, 255)?;
        ensure!(
            store::valid_key(&key) && valid_hex(revision, 32),
            "START_SNAPSHOT_INVALID: invalid identity"
        );
        Some(ActiveIdentity {
            key,
            revision: revision.into(),
        })
    };
    let encoded = lines
        .next()
        .and_then(|v| v.strip_prefix("# zc-prepared-source-v1 "))
        .context("START_SNAPSHOT_INVALID: missing source header")?;
    let source_path = if encoded == "-" {
        None
    } else {
        Some(decode_hex(encoded, 4096)?)
    };
    let encoded = lines
        .next()
        .and_then(|v| v.strip_prefix("# zc-prepared-port-v1 "))
        .context("START_SNAPSHOT_INVALID: missing port header")?;
    let port_override = if encoded == "-" {
        None
    } else {
        ensure!(
            encoded.bytes().all(|b| b.is_ascii_digit()),
            "START_SNAPSHOT_INVALID: invalid port"
        );
        let port = encoded.parse::<u16>()?;
        ensure!(port > 0, "START_SNAPSHOT_INVALID: invalid port");
        Some(port)
    };
    let source = zig_runtime_source(
        lines
            .next()
            .context("START_SNAPSHOT_INVALID: missing payload")?,
    )?;
    let invocation = descriptor
        .invocation
        .as_ref()
        .context("START_SNAPSHOT_INVALID: missing invocation")?;
    ensure!(
        invocation.prepared
            && invocation.source_path == source_path
            && invocation.port_override == port_override
            && identity == descriptor.identity,
        "START_SNAPSHOT_INVALID: prepared invocation mismatch"
    );
    let config = Config::parse(&source)?;
    let port = port_override
        .or_else(|| {
            config.document()["mixed-port"]
                .as_u64()
                .and_then(|p| u16::try_from(p).ok())
        })
        .filter(|p| *p > 0)
        .context("START_SNAPSHOT_INVALID: no mixed port")?;
    Ok(Prepared {
        source,
        assets: BTreeMap::new(),
        identity,
        generation: descriptor.generation,
        selections: Vec::new(),
        invocation: invocation.clone(),
        port,
        override_options: CliOptions::default(),
    })
}
fn remove_descriptor_snapshot(runtime: &Directory, d: &Descriptor) {
    let Some(path) = d.invocation.as_ref().and_then(|i| i.config_path.as_ref()) else {
        return;
    };
    let path = Path::new(path);
    let Some(name) = path.file_name().and_then(|v| v.to_str()) else {
        return;
    };
    let authenticated_yaml =
        name.ends_with(".yaml") && load_zig_prepared(&runtime.dir, name, d).is_ok();
    if path.parent() != Some(runtime.path.as_path())
        || !name.starts_with("zc.prepared.")
        || (!name.ends_with(&format!(".{}.snapshot", d.nonce)) && !authenticated_yaml)
    {
        return;
    }
    if let Err(error) = runtime.dir.remove_file(name)
        && error.kind() != io::ErrorKind::NotFound
    {
        eprintln!("Snapshot cleanup failed: {error}");
    }
}
fn prepared_for(runtime: &Directory, d: &Descriptor) -> Result<Prepared> {
    let path = d
        .invocation
        .as_ref()
        .and_then(|i| i.config_path.as_ref())
        .context("RUNTIME_SNAPSHOT_MISSING: exact snapshot unavailable")?;
    let path = Path::new(path);
    ensure!(
        path.parent() == Some(runtime.path.as_path()),
        "RUNTIME_SNAPSHOT_INVALID: snapshot directory mismatch"
    );
    let prepared = if path.extension().is_some_and(|ext| ext == "yaml") {
        load_zig_prepared(
            &runtime.dir,
            path.file_name()
                .and_then(|v| v.to_str())
                .context("invalid snapshot path")?,
            d,
        )?
    } else {
        load_snapshot(
            &runtime.dir,
            path.file_name()
                .and_then(|v| v.to_str())
                .context("invalid snapshot path")?,
            &d.nonce,
        )?
    };
    ensure!(
        prepared.identity == d.identity
            && prepared.generation == d.generation
            && parse_config(&prepared)?
                .controller_endpoint()
                .map(|a| a.to_string())
                == d.endpoint,
        "RUNTIME_SNAPSHOT_INVALID: snapshot identity mismatch"
    );
    Ok(prepared)
}

/// Capture before any asynchronous preparation; the token is checked under launch ownership.
#[derive(Clone)]
pub struct RestartCapture {
    descriptor: Option<Descriptor>,
    pub prepared: Option<Prepared>,
}
pub async fn capture_restart() -> Result<RestartCapture> {
    let Some(runtime) = runtime_dir(false)? else {
        return Ok(RestartCapture {
            descriptor: None,
            prepared: None,
        });
    };
    let descriptor = observe(&runtime)?;
    ensure!(
        descriptor.as_ref().is_none_or(|d| d.ready),
        "RESTART_CONTENDED: startup is in progress"
    );
    ensure!(
        descriptor.is_some() || !lock_held(&runtime.dir)?,
        "RESTART_CONTENDED: startup is in progress"
    );
    let mut prepared = descriptor
        .as_ref()
        .map(|d| prepared_for(&runtime, d))
        .transpose()?;
    if let (Some(d), Some(prepared)) = (&descriptor, &mut prepared)
        && d.invocation
            .as_ref()
            .and_then(|i| i.config_path.as_deref())
            .is_some_and(|p| p.ends_with(".yaml"))
    {
        if let Some(endpoint) = &d.endpoint {
            let state = get_runtime_status(endpoint).await?;
            ensure!(
                state["config_key"].as_str() == d.identity.as_ref().map(|i| i.key.as_str()),
                "RUNTIME_SNAPSHOT_INVALID: controller identity mismatch"
            );
            let entries = state["selected_proxies"]
                .as_array()
                .context("RUNTIME_SNAPSHOT_INVALID: missing selections")?;
            ensure!(
                entries.len() <= 1024,
                "RUNTIME_SNAPSHOT_INVALID: too many selections"
            );
            prepared.selections = entries
                .iter()
                .map(|entry| {
                    Ok(Selection {
                        group: entry["group"]
                            .as_str()
                            .context("invalid selection group")?
                            .into(),
                        proxy: entry["proxy"]
                            .as_str()
                            .context("invalid selection proxy")?
                            .into(),
                    })
                })
                .collect::<Result<_>>()?;
        } else if let Some(identity) = &d.identity {
            let (desired, _guard) = desired_guard(identity)?
                .context("RUNTIME_SNAPSHOT_INVALID: desired identity changed")?;
            ensure!(
                desired.generation == d.generation,
                "RUNTIME_SNAPSHOT_INVALID: applied selections unavailable"
            );
            prepared.selections = desired.selections;
        }
        parse_config(prepared)?;
    }
    ensure!(
        observe(&runtime)? == descriptor,
        "RESTART_CONTENDED: runtime changed during capture"
    );
    Ok(RestartCapture {
        descriptor,
        prepared,
    })
}
pub async fn current_prepared() -> Result<Option<Prepared>> {
    let Some(runtime) = runtime_dir(false)? else {
        return Ok(None);
    };
    let Some(d) = observe(&runtime)?.filter(|d| d.ready) else {
        return Ok(None);
    };
    let prepared = prepared_for(&runtime, &d)?;
    ensure!(
        observe(&runtime)?.as_ref() == Some(&d),
        "RUNTIME_IDENTITY_CHANGED: instance changed"
    );
    Ok(Some(prepared))
}

pub async fn start(prepared: Prepared) -> Result<Value> {
    let runtime = runtime_dir(true)?.context("runtime unavailable")?;
    let _launch = runtime
        .dir
        .lock("zc.launch.lock", START_WAIT + Duration::from_secs(2))?;
    start_locked(&runtime, prepared, false, true).await
}
async fn start_locked(
    runtime: &Directory,
    prepared: Prepared,
    exact: bool,
    idempotent: bool,
) -> Result<Value> {
    if let Some(d) = observe(runtime)?.filter(|d| d.ready) {
        ensure!(
            idempotent,
            "RESTART_FAILED: another runtime instance appeared; it was not stopped"
        );
        return Ok(json!({"pid": d.pid, "detail": "already_running"}));
    }
    let deadline = Instant::now() + START_WAIT;
    while lock_held(&runtime.dir)? {
        if let Some(d) = observe(runtime)?.filter(|d| d.ready) {
            ensure!(
                idempotent,
                "RESTART_FAILED: another runtime instance appeared; it was not stopped"
            );
            return Ok(json!({"pid":d.pid,"detail":"already_running"}));
        }
        ensure!(
            Instant::now() < deadline,
            "START_FAILED: daemon readiness deadline exceeded"
        );
        sleep(Duration::from_millis(25)).await;
    }
    parse_config(&prepared)?;
    let lock = runtime.dir.lock("zc.lock", LOCK_WAIT)?;
    // Validate again after acquiring ownership, before deleting only dead artifacts.
    if let Some(old) = pid(&runtime.dir)? {
        ensure!(
            !alive(old),
            "RUNTIME_IDENTITY_CHANGED: refusing to replace a live PID"
        );
    }
    let _descriptor_guard = runtime.dir.lock("zc.daemon.lock", LOCK_WAIT)?;
    if let Some(stale) = read_descriptor(&runtime.dir)? {
        remove_descriptor_snapshot(runtime, &stale);
    }
    for name in ["zc.pid", DESCRIPTOR] {
        if runtime.dir.exists(name)? {
            runtime.dir.read(name, 64 * 1024)?;
            runtime.dir.remove_file(name)?;
        }
    }
    drop(_descriptor_guard);
    let nonce = fsutil::nonce()?;
    let name = save_snapshot(&runtime.dir, prepared, &nonce)?;
    let mut owned = PendingLaunch(None, Some((&runtime.dir, &nonce, &name)));
    if exact {
        runtime.dir.write_new(
            &format!("zc.restore.{nonce}"),
            format!("{nonce}\n").as_bytes(),
        )?;
    }
    let mut command = Command::new(std::env::current_exe()?);
    command
        .args(["--daemon-run", &name, &nonce])
        .stdin(Stdio::from(lock.inherited_file()?))
        .stdout(Stdio::null())
        .stderr(Stdio::null());
    owned.0 = Some(
        command
            .spawn()
            .context("START_FAILED: cannot spawn daemon")?,
    );
    drop(command);
    drop(lock);
    let deadline = Instant::now() + START_WAIT;
    loop {
        let child = owned.0.as_mut().expect("pending child");
        if let Some(d) = observe(runtime)? {
            ensure!(
                d.nonce == nonce && d.pid == child.id(),
                "START_FAILED: runtime instance changed while starting"
            );
            if d.ready {
                let mut child = owned.0.take().expect("ready child");
                owned.1 = None;
                std::thread::spawn(move || {
                    let _ = child.wait();
                });
                return Ok(json!({"pid": d.pid}));
            }
        }
        if let Some(exit) = child.try_wait()? {
            let error = runtime
                .dir
                .read(&format!("zc.start.{nonce}"), 4096)
                .ok()
                .and_then(|v| String::from_utf8(v).ok())
                .unwrap_or_else(|| {
                    format!("START_FAILED: daemon exited before readiness ({exit})")
                });
            cleanup_names(&runtime.dir, &nonce, &name);
            bail!("{error}");
        }
        if Instant::now() >= deadline {
            bail!("START_FAILED: daemon readiness deadline exceeded");
        }
        sleep(Duration::from_millis(25)).await;
    }
}
// Staged inputs and any unready child belong exclusively to this call. Cleanup
// also runs on failed preparation/stop and when the caller's future is dropped.
struct PendingLaunch<'a>(Option<Child>, Option<(&'a SecureDir, &'a str, &'a str)>);
impl Drop for PendingLaunch<'_> {
    fn drop(&mut self) {
        if let Some(mut child) = self.0.take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        if let Some((dir, nonce, name)) = self.1.take() {
            cleanup_names(dir, nonce, name);
        }
    }
}
fn cleanup_names(dir: &SecureDir, nonce: &str, snapshot: &str) {
    for name in [
        snapshot.to_owned(),
        format!("zc.stop.{nonce}"),
        format!("zc.start.{nonce}"),
        format!("zc.restore.{nonce}"),
    ] {
        if let Err(error) = dir.remove_file(&name)
            && error.kind() != io::ErrorKind::NotFound
        {
            eprintln!("Runtime cleanup failed: {error}");
        }
    }
}

pub async fn run_child(snapshot_name: &str, nonce: &str) -> Result<()> {
    let runtime = runtime_dir(false)?.context("START_FAILED: runtime directory missing")?;
    let result = async {
        let prepared = load_snapshot(&runtime.dir, snapshot_name, nonce)?;
        let inherited: File = rustix::io::fcntl_dupfd_cloexec(std::io::stdin(), 3)?.into();
        rustix::io::fcntl_setfd(std::io::stdin(), rustix::io::FdFlags::CLOEXEC)?;
        let lock = FileLock::from_inherited(inherited, &runtime.dir, "zc.lock")
            .context("START_LOCK_HANDOFF_INVALID: daemon lock handoff failed")?;
        rustix::process::setsid().context("START_FAILED: cannot detach daemon session")?;
        let exact = runtime.dir.exists(&format!("zc.restore.{nonce}"))?;
        run_instance(&runtime, prepared, snapshot_name, nonce, lock, exact).await
    }
    .await;
    if let Err(error) = &result {
        let message = format!("{error:#}");
        if valid_hex(nonce, 32) {
            let _ = runtime.dir.atomic_write(
                &format!("zc.start.{nonce}"),
                &message.as_bytes()[..message.len().min(4096)],
            );
        }
        let _ =
            runtime
                .dir
                .append_bounded("zc.log", b"Daemon startup or runtime failed.\n", LOG_LIMIT);
    }
    result
}
pub async fn run_foreground(mut prepared: Prepared) -> Result<()> {
    prepared.invocation.foreground = true;
    prepared.invocation.prepared = false;
    parse_config(&prepared)?;
    let runtime = runtime_dir(true)?.context("runtime unavailable")?;
    let lock = runtime
        .dir
        .lock("zc.lock", LOCK_WAIT)
        .context("START_FAILED: daemon already running")?;
    if let Some(old) = pid(&runtime.dir)? {
        ensure!(!alive(old), "RUNTIME_IDENTITY_CHANGED: unverified live PID");
    }
    let nonce = fsutil::nonce()?;
    let name = save_snapshot(&runtime.dir, prepared.clone(), &nonce)?;
    run_instance(&runtime, prepared, &name, &nonce, lock, false).await
}

struct Control {
    runtime: Directory,
    config: Arc<Config>,
    descriptor: Mutex<Descriptor>,
    persisted: Mutex<BTreeSet<String>>,
    stopped: AtomicBool,
}
impl Control {
    fn validate(&self, d: &Descriptor) -> Result<()> {
        ensure!(
            !self.stopped.load(Ordering::Acquire) && observe(&self.runtime)?.as_ref() == Some(d),
            "RUNTIME_IDENTITY_CHANGED: runtime instance changed"
        );
        Ok(())
    }
}
impl api::Managed for Control {
    fn status(&self) -> Result<Value> {
        let d = self
            .descriptor
            .lock()
            .map_err(|_| anyhow::anyhow!("runtime state poisoned"))?;
        self.validate(&d)?;
        Ok(
            json!({"config_key": d.identity.as_ref().map(|i| &i.key), "selected_proxies": api::selected_json(&self.config, &*self.persisted.lock().map_err(|_| anyhow::anyhow!("selection state poisoned"))?)}),
        )
    }
    fn select(&self, group: &str, proxy: &str, metadata: &Value) -> Result<bool> {
        // There are no await points from authority validation to descriptor publication.
        // Cancellation therefore cannot split a durable/apply transaction.
        let mut d = self
            .descriptor
            .lock()
            .map_err(|_| anyhow::anyhow!("runtime state poisoned"))?;
        self.validate(&d)?;
        let Some(identity) = &d.identity else {
            return Ok(false);
        };
        let generation = metadata["generation"].as_u64().unwrap_or(0);
        if metadata["instance_nonce"] != d.nonce
            || metadata["identity_key"] != identity.key
            || metadata["identity_revision"] != identity.revision
            || generation <= d.generation
        {
            return Ok(false);
        }
        let Some((desired, _authority)) = desired_guard(identity)? else {
            return Ok(false);
        };
        if desired.generation != generation
            || !desired
                .selections
                .iter()
                .any(|s| s.group == group && s.proxy == proxy)
        {
            return Ok(false);
        }
        let _descriptor_guard = self.runtime.dir.lock("zc.daemon.lock", LOCK_WAIT)?;
        self.validate(&d)?;
        let mut frozen = prepared_for(&self.runtime, &d)?;
        frozen.generation = generation;
        frozen.selections = desired.selections.clone();
        let snapshot = save_snapshot(&self.runtime.dir, frozen, &d.nonce)?;
        let previous = self.config.selected();
        self.config
            .set_selections(&selection_map(&desired.selections)?)?;
        let mut next = d.clone();
        next.generation = generation;
        next.invocation
            .as_mut()
            .context("runtime invocation missing")?
            .config_path = Some(
            self.runtime
                .path
                .join(&snapshot)
                .to_string_lossy()
                .into_owned(),
        );
        if let Err(error) = publish(&self.runtime.dir, &next) {
            self.config.set_selections(&previous)?;
            self.stopped.store(true, Ordering::Release);
            return Err(error);
        }
        *self
            .persisted
            .lock()
            .map_err(|_| anyhow::anyhow!("selection state poisoned"))? =
            desired.selections.iter().map(|s| s.group.clone()).collect();
        remove_descriptor_snapshot(&self.runtime, &d);
        *d = next;
        Ok(true)
    }
}
fn desired_guard(identity: &ActiveIdentity) -> Result<Option<(store::Desired, FileLock)>> {
    let store = Store::open(Store::default_root()?)?;
    for _ in 0..4 {
        let before = store.load()?;
        let root = SecureDir::open(store.root_path())?;
        let guard = root.lock("state-v2.lock", LOCK_WAIT)?;
        let current: store::Catalog =
            serde_json::from_slice(&root.read("state-v2.json", 4 * 1024 * 1024)?)?;
        guard.validate(&root, "state-v2.lock")?;
        if current != before.catalog {
            continue;
        }
        let Some(profile) = current
            .profiles
            .iter()
            .find(|p| p.key == identity.key && p.head == identity.revision)
        else {
            return Ok(None);
        };
        return Ok(Some((profile.desired.clone(), guard)));
    }
    bail!("RUNTIME_DESIRED_CHANGED: desired state did not stabilize")
}

async fn run_instance(
    runtime: &Directory,
    prepared: Prepared,
    name: &str,
    nonce: &str,
    lock: FileLock,
    exact: bool,
) -> Result<()> {
    // This second stable lock excludes overlap even if the entire XDG directory is replaced.
    let guardian = fallback_parent(true)?;
    let guardian_lock = guardian
        .dir
        .lock("zc.lifecycle.lock", LOCK_WAIT)
        .context("START_FAILED: another runtime still owns the lifecycle lock")?;
    let config = parse_config(&prepared)?;
    let proxy = Runtime::bind(config, prepared.port)
        .await
        .map_err(|e| anyhow::anyhow!("START_PORT_IN_USE: {e:#}"))?;
    let config = proxy.config();
    let mut invocation = prepared.invocation.clone();
    invocation.prepared = !invocation.foreground;
    invocation.config_path = Some(runtime.path.join(name).to_string_lossy().into_owned());
    let mut descriptor = Descriptor {
        schema_version: 2,
        pid: std::process::id(),
        nonce: nonce.into(),
        endpoint: config.controller_endpoint().map(|a| a.to_string()),
        identity: prepared.identity.clone(),
        generation: prepared.generation,
        ready: false,
        invocation: Some(invocation),
    };
    let control = Arc::new(Control {
        runtime: Directory {
            path: runtime.path.clone(),
            dir: SecureDir::open_owned_absolute(&runtime.path, true)?,
        },
        config: config.clone(),
        descriptor: Mutex::new(descriptor.clone()),
        persisted: Mutex::new(
            prepared
                .selections
                .iter()
                .map(|s| s.group.clone())
                .collect(),
        ),
        stopped: AtomicBool::new(false),
    });
    let controller = api::Server::bind(
        config.clone(),
        if prepared.identity.is_some() {
            Some(control.clone())
        } else {
            None
        },
    )
    .await?;
    let result = async {
        lock.validate(&runtime.dir, "zc.lock")?;
        runtime.dir.validate_path(&runtime.path)?;
        lock.write_contents(b"")?;
        runtime.dir.atomic_write("zc.pid", format!("{}\n", descriptor.pid).as_bytes())?;
        {
            let _guard = runtime.dir.lock("zc.daemon.lock", LOCK_WAIT)?;
            publish(&runtime.dir, &descriptor)?;
        }
        let authority = if !exact { if let Some(identity) = &prepared.identity { Some(desired_guard(identity)?.context("START_FAILED: prepared revision changed before readiness")?) } else { None } } else { None };
        if let Some((desired, _guard)) = &authority {
            config.set_selections(&selection_map(&desired.selections)?)?;
            descriptor.generation = desired.generation;
            let mut frozen = prepared.clone();
            frozen.generation = desired.generation;
            frozen.selections = desired.selections.clone();
            let current_name = save_snapshot(&runtime.dir, frozen, nonce)?;
            descriptor.invocation.as_mut().context("runtime invocation missing")?.config_path = Some(runtime.path.join(&current_name).to_string_lossy().into_owned());
            *control.persisted.lock().map_err(|_| anyhow::anyhow!("selection state poisoned"))? = desired.selections.iter().map(|s| s.group.clone()).collect();
        }
        let mut terminate = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())?;
        let mut interrupt = tokio::signal::unix::signal(tokio::signal::unix::SignalKind::interrupt())?;
        runtime.dir.append_bounded("zc.log", format!("Daemon ready: mixed port {}.\n", prepared.port).as_bytes(), LOG_LIMIT)?;
        {
            let _guard = runtime.dir.lock("zc.daemon.lock", LOCK_WAIT)?;
            lock.validate(&runtime.dir, "zc.lock")?;
            runtime.dir.validate_path(&runtime.path)?;
            descriptor.ready = true;
            publish(&runtime.dir, &descriptor)?;
            *control.descriptor.lock().map_err(|_| anyhow::anyhow!("runtime state poisoned"))? = descriptor.clone();
        }
        drop(authority);
        let (shutdown_tx, shutdown_rx) = tokio::sync::watch::channel(false);
        let wait_shutdown = |mut rx: tokio::sync::watch::Receiver<bool>| async move { while !*rx.borrow_and_update() { if rx.changed().await.is_err() { break; } } };
        let mut tasks = tokio::task::JoinSet::new();
        tasks.spawn(proxy.run(wait_shutdown(shutdown_rx.clone())));
        if let Some(controller) = controller { tasks.spawn(controller.run(wait_shutdown(shutdown_rx))); }
        let reason: Result<()> = loop {
            tokio::select! {
                _ = terminate.recv() => break Ok(()),
                _ = interrupt.recv() => break Ok(()),
                ended = tasks.join_next() => break match ended { Some(Ok(result)) => result, Some(Err(e)) => Err(e.into()), None => Ok(()) },
                _ = sleep(Duration::from_millis(100)) => {
                    let check = (|| -> Result<bool> {
                        runtime.dir.validate_path(&runtime.path)?; lock.validate(&runtime.dir, "zc.lock")?;
                        guardian_lock.validate(&guardian.dir, "zc.lifecycle.lock")?;
                        ensure!(!control.stopped.load(Ordering::Acquire), "RUNTIME_FAILED: selection publication failed");
                        if runtime.dir.exists("zc.log")? && runtime.dir.file_metadata("zc.log")?.len() > LOG_LIMIT as u64 { runtime.dir.atomic_write("zc.log", b"")?; }
                        let stop_name = format!("zc.stop.{nonce}");
                        if !runtime.dir.exists(&stop_name)? { return Ok(false); }
                        let request = runtime.dir.read(&stop_name, 33)?;
                        if request != format!("{nonce}\n").as_bytes() { return Ok(false); }
                        match runtime.dir.remove_file(&stop_name) {
                            Ok(()) => Ok(true),
                            Err(e) if e.kind() == io::ErrorKind::NotFound => Ok(false),
                            Err(e) => Err(e.into()),
                        }
                    })();
                    match check { Ok(false) => (), Ok(true) => break Ok(()), Err(error) => break Err(error) }
                }
            }
        };
        control.stopped.store(true, Ordering::Release);
        let _ = shutdown_tx.send(true);
        while let Some(ended) = tasks.join_next().await { ended??; }
        reason
    }.await;
    control.stopped.store(true, Ordering::Release);
    if let Ok(_guard) = runtime.dir.lock("zc.daemon.lock", LOCK_WAIT)
        && let Ok(Some(current)) = read_descriptor(&runtime.dir)
        && current.nonce == nonce
        && current.pid == std::process::id()
    {
        remove_descriptor_snapshot(runtime, &current);
        let _ = runtime.dir.remove_file(DESCRIPTOR);
        if pid(&runtime.dir).ok().flatten() == Some(std::process::id()) {
            let _ = runtime.dir.remove_file("zc.pid");
        }
    }
    cleanup_names(&runtime.dir, nonce, name);
    result
}

pub async fn stop() -> Result<Value> {
    let Some(runtime) = runtime_dir(false)? else {
        return Ok(json!({"detail": "already_stopped"}));
    };
    let Some(d) = observe(&runtime)? else {
        ensure!(
            !lock_held(&runtime.dir)?,
            "STOP_FAILED: startup is in progress; retry shortly"
        );
        cleanup_stale(&runtime)?;
        return Ok(json!({"detail": "already_stopped"}));
    };
    stop_instance(&runtime, &d).await?;
    Ok(json!({"pid": d.pid}))
}
struct StopRequest<'a> {
    dir: &'a SecureDir,
    name: String,
    armed: bool,
}
impl StopRequest<'_> {
    fn revoke(&mut self) -> Result<bool> {
        match self.dir.remove_file(&self.name) {
            Ok(()) => {
                self.armed = false;
                Ok(true)
            }
            Err(e) if e.kind() == io::ErrorKind::NotFound => {
                self.armed = false;
                Ok(false)
            }
            Err(e) => Err(e).context("STOP_FAILED: cannot revoke stop request"),
        }
    }
}
impl Drop for StopRequest<'_> {
    fn drop(&mut self) {
        if self.armed
            && let Err(error) = self.revoke()
        {
            eprintln!("Stop request cleanup failed: {error:#}");
        }
    }
}
fn stopped(runtime: &Directory, expected: &Descriptor) -> Result<bool> {
    runtime.dir.validate_path(&runtime.path)?;
    if !lock_held(&runtime.dir)? {
        return Ok(true);
    }
    if let Some(d) = read_descriptor(&runtime.dir)? {
        ensure!(
            d.nonce == expected.nonce && d.pid == expected.pid,
            "STOP_FAILED: runtime instance changed"
        );
    }
    Ok(false)
}
async fn stop_instance(runtime: &Directory, expected: &Descriptor) -> Result<()> {
    // Serialize request ownership so a cancelled caller cannot revoke another call.
    let _request_lock = runtime.dir.lock("zc.stop.lock", LOCK_WAIT)?;
    let current = observe(runtime)?.context("STOP_FAILED: runtime instance disappeared")?;
    ensure!(
        current.pid == expected.pid && current.nonce == expected.nonce,
        "STOP_FAILED: runtime instance changed"
    );
    let mut request = StopRequest {
        dir: &runtime.dir,
        name: format!("zc.stop.{}", expected.nonce),
        armed: true,
    };
    let publication = runtime
        .dir
        .atomic_write(&request.name, format!("{}\n", expected.nonce).as_bytes());
    if publication.is_ok() {
        let deadline = Instant::now() + STOP_WAIT;
        while Instant::now() < deadline {
            if stopped(runtime, expected)? {
                return Ok(());
            }
            sleep(Duration::from_millis(25)).await;
        }
    }
    // The daemon may already have consumed the request. Confirm that outcome
    // within a bounded settle interval rather than report a false failure.
    if !request.revoke()? {
        let deadline = Instant::now() + Duration::from_secs(1);
        while Instant::now() < deadline {
            if stopped(runtime, expected)? {
                return Ok(());
            }
            sleep(Duration::from_millis(25)).await;
        }
    }
    publication?;
    bail!("STOP_FAILED: daemon stop deadline exceeded; request revoked; no PID signal sent")
}
pub async fn restart_checked(captured: RestartCapture, prepared: Prepared) -> Result<Value> {
    parse_config(&prepared)?;
    let runtime = runtime_dir(true)?.context("runtime unavailable")?;
    let _launch = runtime.dir.lock("zc.launch.lock", START_WAIT + STOP_WAIT)?;
    let previous = observe(&runtime)?;
    ensure!(
        previous == captured.descriptor && (previous.is_some() || !lock_held(&runtime.dir)?),
        "RESTART_CONTENDED: the captured daemon instance changed before replacement"
    );
    let previous_prepared = captured.prepared;
    if let Some(d) = &previous {
        ensure!(
            !d.invocation.as_ref().is_some_and(|i| i.foreground),
            "RELOAD_FAILED: supervised foreground runtime must be restarted by its supervisor"
        );
    }
    // Freeze before stopping; source files and providers are never reopened during rollback.
    let target_nonce = fsutil::nonce()?;
    let target_name = save_snapshot(&runtime.dir, prepared, &target_nonce)?;
    let staged = PendingLaunch(None, Some((&runtime.dir, &target_nonce, &target_name)));
    let target = load_snapshot(&runtime.dir, &target_name, &target_nonce)?;
    if let Some(d) = &previous {
        stop_instance(&runtime, d).await?;
    }
    let result = start_locked(&runtime, target, false, false).await;
    drop(staged);
    match result {
        Ok(value) => Ok(value),
        Err(error) => {
            if let Some(previous) = previous_prepared {
                match start_locked(&runtime, previous, true, false).await {
                    Ok(_) => bail!("{error:#}; previous snapshot restored"),
                    Err(rollback) => {
                        bail!("{error:#}; rollback failed: {rollback:#}")
                    }
                }
            }
            Err(error)
        }
    }
}

fn cleanup_stale(runtime: &Directory) -> Result<Option<u32>> {
    let lock = match runtime.dir.lock("zc.lock", Duration::from_millis(1)) {
        Ok(lock) => lock,
        Err(error) if error.kind() == io::ErrorKind::TimedOut => return Ok(None),
        Err(error) => return Err(error.into()),
    };
    runtime.dir.validate_path(&runtime.path)?;
    lock.validate(&runtime.dir, "zc.lock")?;
    let stale = pid(&runtime.dir)?;
    if let Some(pid) = stale {
        ensure!(
            !alive(pid),
            "RUNTIME_IDENTITY_CHANGED: live PID cannot be cleaned"
        );
    }
    let _guard = runtime.dir.lock("zc.daemon.lock", LOCK_WAIT)?;
    if let Some(d) = read_descriptor(&runtime.dir)? {
        ensure!(
            !alive(d.pid),
            "RUNTIME_IDENTITY_CHANGED: live descriptor cannot be cleaned"
        );
        remove_descriptor_snapshot(runtime, &d);
        runtime.dir.remove_file(DESCRIPTOR)?;
    }
    if stale.is_some() {
        runtime.dir.remove_file("zc.pid")?;
    }
    Ok(stale)
}
pub async fn status() -> Result<Value> {
    let path = runtime_path()?;
    let mut result = json!({"action":"status", "state":"stopped", "mixed_port":null, "selected_proxies":[], "paths":{"pid_file":path.join("zc.pid"),"lock_file":path.join("zc.lock"),"log_file":path.join("zc.log")}});
    let Some(runtime) = runtime_dir(false)? else {
        return Ok(result);
    };
    let Some(d) = observe(&runtime)?.filter(|d| d.ready) else {
        if let Some(stale) = cleanup_stale(&runtime)? {
            result["detail"] = json!("stale_pid_file");
            result["pid"] = json!(stale);
        }
        return Ok(result);
    };
    let prepared = prepared_for(&runtime, &d)?;
    result["state"] = json!("running");
    result["pid"] = json!(d.pid);
    result["mixed_port"] = json!(prepared.port);
    result["uptime_seconds"] = json!(
        SystemTime::now()
            .duration_since(runtime.dir.file_metadata("zc.pid")?.modified()?)
            .unwrap_or_default()
            .as_secs()
    );
    result["runtime_state_available"] = json!(false);
    if let Some(endpoint) = &d.endpoint
        && let Ok(response) = get_runtime_status(endpoint).await
        && observe(&runtime)?.as_ref() == Some(&d)
    {
        result["runtime_state_available"] = json!(true);
        if !response["config_key"].is_null() {
            result["active_config"] = response["config_key"].clone();
        }
        result["selected_proxies"] = response["selected_proxies"].clone();
    }
    Ok(result)
}
fn client() -> Result<reqwest::Client> {
    Ok(reqwest::Client::builder()
        .no_proxy()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_secs(2))
        .build()?)
}
async fn get_runtime_status(endpoint: &str) -> Result<Value> {
    let mut response = client()?
        .get(format!("http://{endpoint}/status"))
        .send()
        .await?
        .error_for_status()?;
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await? {
        ensure!(
            bytes.len() + chunk.len() <= 4 * 1024 * 1024,
            "runtime response too large"
        );
        bytes.extend_from_slice(&chunk);
    }
    Ok(serde_json::from_slice(&bytes)?)
}
pub async fn apply_selection(
    identity: &ActiveIdentity,
    generation: u64,
    selections: &[Selection],
) -> Result<bool> {
    // Durable desired state is already committed. An unverifiable runtime only
    // disables live apply; it must never turn that commit into a reported failure.
    Ok(apply_selection_checked(identity, generation, selections)
        .await
        .unwrap_or(false))
}
async fn apply_selection_checked(
    identity: &ActiveIdentity,
    generation: u64,
    selections: &[Selection],
) -> Result<bool> {
    let Some(runtime) = runtime_dir(false)? else {
        return Ok(false);
    };
    let Some(d) = observe(&runtime)?.filter(|d| d.ready) else {
        return Ok(false);
    };
    if d.identity.as_ref() != Some(identity) || generation <= d.generation {
        return Ok(false);
    }
    let Some(endpoint) = &d.endpoint else {
        return Ok(false);
    };
    let Some(selection) = selections.first() else {
        return Ok(false);
    };
    let prepared = prepared_for(&runtime, &d)?;
    let config = parse_config(&prepared)?;
    ensure!(
        observe(&runtime)?.as_ref() == Some(&d),
        "RUNTIME_IDENTITY_CHANGED: daemon changed before apply"
    );
    let group: String = selection
        .group
        .bytes()
        .map(|b| {
            if b.is_ascii_alphanumeric() || b"-._~".contains(&b) {
                (b as char).to_string()
            } else {
                format!("%{b:02X}")
            }
        })
        .collect();
    let response = client()?.put(format!("http://{endpoint}/proxies/{group}")).bearer_auth(config.secret()).json(&json!({"name":selection.proxy,"instance_nonce":d.nonce,"identity_key":identity.key,"identity_revision":identity.revision,"generation":generation})).send().await;
    let Ok(response) = response else {
        return Ok(false);
    };
    if !response.status().is_success() {
        return Ok(false);
    }
    Ok(observe(&runtime)?.is_some_and(|current| {
        current.pid == d.pid
            && current.nonce == d.nonce
            && current.identity == d.identity
            && current.generation == generation
    }))
}
pub async fn log(lines: usize, follow: bool, json_output: bool) -> Result<()> {
    use std::os::unix::fs::MetadataExt;
    let mut previous: Option<(u64, u64, usize)> = None;
    let mut first = true;
    loop {
        let read = (|| -> Result<Option<(Vec<u8>, u64, u64)>> {
            let Some(runtime) = runtime_dir(false)? else {
                return Ok(None);
            };
            let (bytes, metadata) = match runtime.dir.read_with_metadata("zc.log", LOG_LIMIT) {
                Ok(v) => v,
                Err(e) if e.kind() == io::ErrorKind::NotFound => return Ok(None),
                Err(e) => return Err(e.into()),
            };
            Ok(Some((bytes, metadata.dev(), metadata.ino())))
        })();
        match read {
            Ok(Some((bytes, dev, ino))) => {
                // Keep an incomplete record unconsumed until its newline arrives.
                let end = if follow {
                    bytes
                        .iter()
                        .rposition(|byte| *byte == b'\n')
                        .map_or(0, |index| index + 1)
                } else {
                    bytes.len()
                };
                let bytes = &bytes[..end];
                let start = match previous {
                    Some((d, i, n)) if d == dev && i == ino && n <= bytes.len() => n,
                    _ if first => {
                        let mut count = 0;
                        let mut start = 0;
                        for (index, byte) in bytes.iter().enumerate().rev() {
                            if *byte == b'\n' && index + 1 != bytes.len() {
                                count += 1;
                                if count == lines {
                                    start = index + 1;
                                    break;
                                }
                            }
                        }
                        if lines == 0 { bytes.len() } else { start }
                    }
                    _ => 0,
                };
                let text = String::from_utf8_lossy(&bytes[start..]);
                let stdout = std::io::stdout();
                let mut out = stdout.lock();
                for line in text.lines() {
                    if json_output {
                        serde_json::to_writer(&mut out, &json!({"line":line}))?;
                        writeln!(out)?;
                    } else {
                        writeln!(out, "{line}")?;
                    }
                }
                out.flush()?;
                previous = Some((dev, ino, bytes.len()));
                first = false;
            }
            Ok(None) => (),
            Err(error) => {
                if !follow {
                    return Err(error);
                }
            }
        }
        if !follow {
            return Ok(());
        }
        tokio::select! { _ = tokio::signal::ctrl_c() => return Ok(()), _ = sleep(Duration::from_millis(200)) => () }
    }
}

#[cfg(test)]
mod lifecycle_tests {
    use super::*;

    mod descriptor_fixture {
        include!(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/tests/support/descriptor_fixture.rs"
        ));
    }

    #[test]
    fn atomic_descriptor_publication_never_accepts_unlinked_or_partial_state() {
        use std::{
            fs,
            io::Read,
            os::unix::{
                fs::{MetadataExt, OpenOptionsExt, PermissionsExt},
                net::UnixListener,
            },
        };
        let Some(root) = std::env::var_os(descriptor_fixture::ROOT_ENV) else {
            descriptor_fixture::run_scoped();
            return;
        };
        let root = PathBuf::from(root);
        fs::set_permissions(&root, fs::Permissions::from_mode(0o700)).unwrap();
        let dir = Arc::new(SecureDir::open(&root).unwrap());
        let bytes = include_bytes!("../tests/fixtures/daemon_zig_descriptor.json");
        assert!(
            dir.atomic_write(DESCRIPTOR, bytes)
                .unwrap()
                .durability_error
                .is_none()
        );
        let mut expected: Descriptor = serde_json::from_slice(bytes).unwrap();
        dir.write_new("control-inode", b"unrelated").unwrap();
        dir.write_new("unused-inode", b"never read").unwrap();
        let socket = UnixListener::bind(root.join("writer.sock")).unwrap();
        let writer = dir.clone();
        let (publish, request) = std::sync::mpsc::sync_channel::<(u64, Vec<u8>)>(0);
        let task = std::thread::spawn(move || {
            for epoch in 1_u64..=500 {
                let (requested_epoch, bytes) =
                    request.recv_timeout(Duration::from_secs(10)).unwrap();
                assert_eq!(requested_epoch, epoch);
                let (mut stream, _) = socket.accept().unwrap();
                stream
                    .set_read_timeout(Some(Duration::from_secs(10)))
                    .unwrap();
                stream
                    .set_write_timeout(Some(Duration::from_secs(10)))
                    .unwrap();
                let mut notification = [0; 8];
                stream.read_exact(&mut notification).unwrap();
                assert_eq!(u64::from_ne_bytes(notification), epoch);
                assert!(
                    writer
                        .atomic_write(DESCRIPTOR, &bytes)
                        .unwrap()
                        .durability_error
                        .is_none()
                );
                stream.write_all(&epoch.to_ne_bytes()).unwrap();
            }
        });
        let case = std::env::var(descriptor_fixture::NEGATIVE_ENV).unwrap();
        let mut markers = String::new();
        let mut successes = 0;
        for epoch in 1_u64..=500 {
            // Sample the actual current inode BEFORE arming; every publication
            // has different valid bytes, so accepting the old handle must fail.
            let current = fs::metadata(root.join(DESCRIPTOR)).unwrap();
            expected.pid += 1;
            publish.send((epoch, encode(&expected).unwrap())).unwrap();
            let control = match case.as_str() {
                "malformed" => "invalid control\n".to_owned(),
                "miss" => {
                    let unused = fs::metadata(root.join("unused-inode")).unwrap();
                    format!("{} {} {epoch}\n", unused.dev(), unused.ino())
                }
                _ => format!("{} {} {epoch}\n", current.dev(), current.ino()),
            };
            let mut arm = fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .open(root.join("control.next"))
                .unwrap();
            arm.write_all(control.as_bytes()).unwrap();
            drop(arm);
            fs::rename(root.join("control.next"), root.join("control")).unwrap();
            // An unrelated inode must not consume either target snapshot.
            assert_eq!(dir.read("control-inode", 9).unwrap(), b"unrelated");
            assert_eq!(descriptor_fixture::read_markers(&root), markers);
            // The hook pauses capture-before, not checked-open. The writer does
            // a real rename while this read holds the old fd; only the existing
            // production retry may return the NEXT complete descriptor.
            let first = read_descriptor(&dir).unwrap().unwrap();
            markers.push_str(&format!(
                "DESCRIPTOR_CAPTURE {epoch} {} {} nlink=0\n",
                current.dev(),
                current.ino()
            ));
            assert_eq!(
                descriptor_fixture::read_markers(&root),
                markers,
                "descriptor hook missed at epoch {epoch}"
            );
            assert_eq!(first, expected);
            successes += 1;
            for _ in 0..9 {
                assert_eq!(read_descriptor(&dir).unwrap().unwrap(), expected);
                successes += 1;
            }
        }
        task.join().unwrap();
        assert_eq!(successes, 5000);
        assert_eq!(
            fs::read_to_string(root.join("markers"))
                .unwrap()
                .lines()
                .count(),
            500
        );
        assert_eq!(read_descriptor(&dir).unwrap().unwrap(), expected);
        fs::hard_link(root.join(DESCRIPTOR), root.join("linked.json")).unwrap();
        assert!(read_descriptor(&dir).is_err());
        eprintln!(
            "Verified 500 capture/rename overlaps, 5000 complete NEXT reads, and static hardlink refusal"
        );
    }

    #[tokio::test]
    async fn cancelled_readiness_owner_kills_and_reaps_only_its_child() {
        let child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
        let pid = child.id();
        let (tx, rx) = tokio::sync::oneshot::channel();
        let task = tokio::spawn(async move {
            let _owned = PendingLaunch(Some(child), None);
            tx.send(()).unwrap();
            std::future::pending::<()>().await;
        });
        rx.await.unwrap();
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert!(
            !alive(pid),
            "cancelled handoff left its child alive or unreaped"
        );
    }

    #[tokio::test]
    async fn cancelled_stop_owner_revokes_its_nonce_request() {
        let temp = tempfile::tempdir().unwrap();
        let path = temp.path().to_owned();
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o700)).unwrap();
        let (tx, rx) = tokio::sync::oneshot::channel();
        let name = "zc.stop.00000000000000000000000000000000";
        let task = tokio::spawn(async move {
            let dir = SecureDir::open(&path).unwrap();
            let _request = StopRequest {
                dir: &dir,
                name: name.into(),
                armed: true,
            };
            dir.atomic_write(name, b"00000000000000000000000000000000\n")
                .unwrap();
            tx.send(()).unwrap();
            std::future::pending::<()>().await;
        });
        rx.await.unwrap();
        task.abort();
        assert!(task.await.unwrap_err().is_cancelled());
        assert!(!temp.path().join(name).exists());
    }
}
