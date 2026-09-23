//! Explicit overrides: bounded script execution, atomic YAML replacement and frozen inputs.
//! No provider IO or networking. Callers must validate runtime capabilities before publication.

use anyhow::{Result, anyhow, bail};
use serde_json::Value;

pub const MAX_SOURCE_BYTES: usize = 16 * 1024 * 1024;
pub const MAX_OUTPUT_BYTES: usize = 1024 * 1024;
pub const MAX_COLLECTION_ENTRIES: usize = 262_144;

fn document(bytes: &[u8], limit: usize) -> Result<Value> {
    if bytes.len() > limit {
        bail!("OVERRIDE_OUTPUT_INVALID: document byte limit exceeded");
    }
    let text = std::str::from_utf8(bytes)
        .map_err(|_| anyhow!("OVERRIDE_OUTPUT_INVALID: YAML must be UTF-8"))?;
    let value = crate::config::parse_document(text).map_err(|_| {
        anyhow!("OVERRIDE_OUTPUT_INVALID: invalid YAML mapping, duplicate key or resource limit")
    })?;
    if !value.is_object() {
        bail!("OVERRIDE_OUTPUT_INVALID: expected a YAML mapping");
    }
    let mut remaining = MAX_COLLECTION_ENTRIES;
    count_entries(&value, &mut remaining)?;
    Ok(value)
}

fn count_entries(value: &Value, remaining: &mut usize) -> Result<()> {
    let count = match value {
        Value::Array(items) => items.len(),
        Value::Object(items) => items.len(),
        _ => 0,
    };
    *remaining = remaining
        .checked_sub(count)
        .ok_or_else(|| anyhow!("OVERRIDE_OUTPUT_INVALID: collection entry limit exceeded"))?;
    match value {
        Value::Array(items) => {
            for item in items {
                count_entries(item, remaining)?;
            }
        }
        Value::Object(items) => {
            for item in items.values() {
                count_entries(item, remaining)?;
            }
        }
        _ => {}
    }
    Ok(())
}

fn empty_patch(patch: &[u8]) -> bool {
    patch
        .iter()
        .all(|byte| matches!(byte, b' ' | b'\t' | b'\r' | b'\n'))
}

/// Atomically replace fields without changing source. Collections replace, never deep-merge.
pub fn merge(source: &[u8], patch: &[u8]) -> Result<String> {
    let mut base = document(source, MAX_SOURCE_BYTES)?;
    validate_collections(&base)?;
    if patch.len() > MAX_OUTPUT_BYTES {
        bail!("OVERRIDE_OUTPUT_INVALID: patch exceeds 1 MiB");
    }
    if empty_patch(patch) {
        return Ok(std::str::from_utf8(source)?.to_owned());
    }
    split_source_groups(&mut base);
    let patch_bytes = patch;
    let patch = document(patch, MAX_OUTPUT_BYTES)?;
    validate_collections(&patch)?;
    for (key, value) in patch.as_object().unwrap() {
        let valid = match key.as_str() {
            "port" | "socks-port" | "mixed-port" => {
                value.as_u64().is_some_and(|port| port <= 65535)
            }
            "allow-lan" => value.is_boolean(),
            "bind-address" | "mode" | "log-level" => value.is_string(),
            "external-controller" => value.is_null() || value.is_string(),
            "proxies" | "proxy-groups" | "rules" => value.is_array(),
            "rule-providers" => value.is_object(),
            _ => false,
        };
        if !valid {
            bail!("OVERRIDE_OUTPUT_INVALID: unsupported patch key or invalid field type");
        }
        let base = base.as_object_mut().unwrap();
        if key == "external-controller" && value.is_null() {
            base.remove(key);
        } else if key == "proxies" {
            let nodes = value
                .as_array()
                .unwrap()
                .iter()
                .filter(|item| !is_group(item))
                .cloned()
                .collect();
            base.insert(key.clone(), Value::Array(nodes));
        } else {
            base.insert(key.clone(), value.clone());
        }
    }
    let mut remaining = MAX_COLLECTION_ENTRIES;
    count_entries(&base, &mut remaining)?;
    validate_collections(&base)?;
    canonical_plugin_options(&mut base)?;
    // Source parsing precedes replacement in Zig, including scalar type checks.
    config_document(source)?;
    normalize_config(&mut base)?;
    materializable(&base)?;
    let provider_input = if patch.get("rule-providers").is_some() {
        patch_bytes
    } else {
        source
    };
    let providers = zig_map_order(provider_order(provider_input)?);
    canonical_config_yaml(&base, &providers, ConfigYamlKind::Effective)
}

/// Preserve exact source bytes for an empty patch; otherwise return merged YAML.
/// The caller must validate the complete configuration, even for an empty patch.
pub fn materialize_source(source: &[u8], patch: &[u8]) -> Result<Vec<u8>> {
    if empty_patch(patch) {
        materializable(&config_document(source)?)?;
    }
    Ok(merge(source, patch)?.into_bytes())
}

pub const TIMEOUT_MS_DEFAULT: u32 = 5_000;
pub const TIMEOUT_MS_MAX: u32 = 60_000;

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct OverrideArg {
    pub key: String,
    pub value: String,
}

impl OverrideArg {
    pub fn parse(pair: &str) -> Result<Self> {
        let (key, value) = pair
            .split_once('=')
            .ok_or_else(|| anyhow!("INVALID_OVERRIDE_ARG: expected key=value"))?;
        let key = key.trim_matches([' ', '\t']);
        if key.is_empty() {
            bail!("INVALID_OVERRIDE_ARG: key must not be empty");
        }
        Ok(Self {
            key: key.into(),
            value: value.into(),
        })
    }
}

pub fn parse_timeout_ms(text: &str) -> Result<u32> {
    if text.is_empty() || !text.bytes().all(|byte| byte.is_ascii_digit()) {
        bail!("INVALID_OVERRIDE_TIMEOUT: expected 1..60000 milliseconds");
    }
    let timeout = text
        .parse::<u32>()
        .map_err(|_| anyhow!("INVALID_OVERRIDE_TIMEOUT: expected 1..60000 milliseconds"))?;
    validate_timeout(timeout)?;
    Ok(timeout)
}

fn validate_timeout(timeout: u32) -> Result<()> {
    if !(1..=TIMEOUT_MS_MAX).contains(&timeout) {
        bail!("INVALID_OVERRIDE_TIMEOUT: expected 1..60000 milliseconds");
    }
    Ok(())
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub struct CliOptions {
    pub script_path: Option<String>,
    pub timeout_ms: u32,
    pub args: Vec<OverrideArg>,
}

impl Default for CliOptions {
    fn default() -> Self {
        Self {
            script_path: None,
            timeout_ms: TIMEOUT_MS_DEFAULT,
            args: Vec::new(),
        }
    }
}

impl CliOptions {
    /// Accept argv including the command name. Ignore flags owned by the CLI.
    pub fn parse(args: &[&str]) -> Result<Self> {
        let mut options = Self::default();
        let mut args = args.iter().skip(1);
        while let Some(argument) = args.next() {
            let (flag, inline) = argument
                .split_once('=')
                .map_or((*argument, None), |(a, b)| (a, Some(b)));
            if matches!(flag, "--override-dump-json" | "--override-dump-yaml") {
                bail!("OVERRIDE_OPTION_DEPRECATED: use config dump instead");
            }
            if !matches!(
                flag,
                "--override-script" | "--override-arg" | "--override-timeout-ms"
            ) {
                continue;
            }
            let value = inline
                .or_else(|| args.next().copied())
                .ok_or_else(|| anyhow!("missing value for {flag}"))?;
            match flag {
                "--override-script" if value.is_empty() => bail!("MISSING_OVERRIDE_SCRIPT_PATH"),
                "--override-script" => options.script_path = Some(value.into()),
                "--override-arg" => options.args.push(OverrideArg::parse(value)?),
                _ => options.timeout_ms = parse_timeout_ms(value)?,
            }
        }
        Ok(options)
    }

    pub fn forward_args(&self) -> Vec<String> {
        let mut result = Vec::new();
        if let Some(path) = &self.script_path {
            result.extend(["--override-script".into(), path.clone()]);
        }
        for argument in &self.args {
            result.extend([
                "--override-arg".into(),
                format!("{}={}", argument.key, argument.value),
            ]);
        }
        if self.timeout_ms != TIMEOUT_MS_DEFAULT {
            result.extend(["--override-timeout-ms".into(), self.timeout_ms.to_string()]);
        }
        result
    }
}

fn validate_collections(value: &Value) -> Result<()> {
    for (field, limit) in [
        ("proxies", 5120),
        ("proxy-groups", 1024),
        ("rules", 262_144),
    ] {
        if let Some(value) = value.get(field) {
            let list = value
                .as_array()
                .ok_or_else(|| anyhow!("OVERRIDE_MERGE_FAILED: {field} must be a list"))?;
            if list.len() > limit {
                bail!("OVERRIDE_MERGE_FAILED: {field} collection limit exceeded");
            }
            for item in list {
                if field == "rules" {
                    if !item.is_string() {
                        bail!("OVERRIDE_MERGE_FAILED: rules must contain strings");
                    }
                } else {
                    if !item.is_object()
                        || !item.get("name").is_some_and(Value::is_string)
                        || !item.get("type").is_some_and(Value::is_string)
                    {
                        bail!("OVERRIDE_MERGE_FAILED: proxy/group requires name and type strings");
                    }
                    if let Some(members) = item.get("proxies") {
                        let members = members.as_array().ok_or_else(|| {
                            anyhow!("OVERRIDE_MERGE_FAILED: group proxies must be a list")
                        })?;
                        if members.len() > 5122 {
                            bail!("OVERRIDE_MERGE_FAILED: proxy-group member limit exceeded");
                        }
                        if !members.iter().all(Value::is_string) {
                            bail!("OVERRIDE_MERGE_FAILED: group members must be strings");
                        }
                    }
                }
            }
        }
    }
    let mixed = value.get("proxies").and_then(Value::as_array);
    let groups = mixed.map_or(0, |list| list.iter().filter(|item| is_group(item)).count());
    if mixed.map_or(0, Vec::len) - groups > 4096
        || groups
            + value
                .get("proxy-groups")
                .and_then(Value::as_array)
                .map_or(0, Vec::len)
            > 1024
    {
        bail!("OVERRIDE_MERGE_FAILED: proxy/group count limit exceeded");
    }
    if let Some(providers) = value.get("rule-providers") {
        let providers = providers
            .as_object()
            .ok_or_else(|| anyhow!("OVERRIDE_MERGE_FAILED: rule-providers must be a map"))?;
        if providers.len() > 4096 {
            bail!("OVERRIDE_MERGE_FAILED: rule-provider count limit exceeded");
        }
        if !providers.values().all(Value::is_object) {
            bail!("OVERRIDE_MERGE_FAILED: rule-providers must contain maps");
        }
    }
    Ok(())
}

fn is_group(value: &Value) -> bool {
    matches!(
        value.get("type").and_then(Value::as_str),
        Some("select" | "url-test" | "fallback" | "load-balance" | "relay")
    )
}

/// Invocation metadata independent of storage encoding; retain ordered and duplicate arguments.
#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Invocation {
    pub command: String,
    pub config_path: String,
    pub script_path: String,
    pub timeout_ms: u32,
    pub args: Vec<OverrideArg>,
}

impl Default for Invocation {
    fn default() -> Self {
        Self {
            command: String::new(),
            config_path: String::new(),
            script_path: String::new(),
            timeout_ms: TIMEOUT_MS_DEFAULT,
            args: Vec::new(),
        }
    }
}

impl Invocation {
    pub fn environment(&self) -> Result<std::collections::BTreeMap<String, String>> {
        validate_timeout(self.timeout_ms)?;
        let mut input_bytes = self
            .command
            .len()
            .saturating_add(self.config_path.len())
            .saturating_add(self.script_path.len());
        for argument in &self.args {
            input_bytes = input_bytes
                .saturating_add(argument.key.len())
                .saturating_add(argument.value.len())
                .saturating_add(2);
        }
        if input_bytes > MAX_OUTPUT_BYTES {
            bail!("INVALID_OVERRIDE_ARG: invocation exceeds 1 MiB");
        }
        let mut env = std::collections::BTreeMap::from([
            ("ZC_OVERRIDE_COMMAND".into(), self.command.clone()),
            ("ZC_OVERRIDE_CONFIG_PATH".into(), self.config_path.clone()),
            ("ZC_OVERRIDE_SCRIPT_PATH".into(), self.script_path.clone()),
            ("ZC_OVERRIDE_TIMEOUT_MS".into(), self.timeout_ms.to_string()),
            ("ZC_OVERRIDE_ARG_COUNT".into(), self.args.len().to_string()),
        ]);
        let mut legacy = Vec::new();
        for (index, argument) in self.args.iter().enumerate() {
            if argument.key.is_empty() {
                bail!("INVALID_OVERRIDE_ARG: empty key");
            }
            env.insert(format!("ZC_OVERRIDE_ARG_{index}_KEY"), argument.key.clone());
            env.insert(
                format!("ZC_OVERRIDE_ARG_{index}_VALUE"),
                argument.value.clone(),
            );
            let key: String = argument
                .key
                .bytes()
                .map(|byte| {
                    if byte.is_ascii_alphanumeric() {
                        byte.to_ascii_uppercase() as char
                    } else {
                        '_'
                    }
                })
                .collect();
            env.insert(format!("ZC_OVERRIDE_ARG_{key}"), argument.value.clone());
            legacy.push(format!("{}={}", argument.key, argument.value));
        }
        env.insert("ZC_OVERRIDE_ARGS".into(), legacy.join(";"));
        if env.values().any(|value| value.contains('\0')) {
            bail!("INVALID_OVERRIDE_ARG: environment values cannot contain NUL");
        }
        if env
            .iter()
            .map(|(key, value)| key.len() + value.len() + 2)
            .sum::<usize>()
            > MAX_OUTPUT_BYTES
        {
            bail!("INVALID_OVERRIDE_ARG: invocation exceeds 1 MiB");
        }
        Ok(env)
    }
}

pub const MAX_SCRIPT_BYTES: usize = 1024 * 1024;
pub const LUA_MEMORY_BYTES: usize = 64 * 1024 * 1024;
const LUA_INSTRUCTIONS: u64 = 50_000_000;

/// Pure evaluation without file, process or network IO. Production must use execute.
/// Workers allow standard io/os; this seam exposes captured io.write/print and os.getenv only.
pub fn evaluate(script: &[u8], invocation: &Invocation) -> Result<Vec<u8>> {
    evaluate_inner(script, invocation, false)
}

fn evaluate_inner(script: &[u8], invocation: &Invocation, worker: bool) -> Result<Vec<u8>> {
    use mlua::{Lua, LuaSerdeExt, StdLib};
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicU64, Ordering},
    };
    use std::time::{Duration, Instant};
    let environment = invocation.environment()?;
    if script.len() > MAX_SCRIPT_BYTES {
        bail!("OVERRIDE_SCRIPT_EXEC_FAILED: script exceeds 1 MiB");
    }
    let libraries = if worker {
        StdLib::ALL_SAFE
    } else {
        StdLib::TABLE | StdLib::STRING | StdLib::MATH | StdLib::UTF8
    };
    let lua = Lua::new_with(libraries, mlua::LuaOptions::default())?;
    lua.set_memory_limit(LUA_MEMORY_BYTES)?;
    let deadline = Instant::now() + Duration::from_millis(invocation.timeout_ms.into());
    let instructions = Arc::new(AtomicU64::new(0));
    let ticks = instructions.clone();
    lua.set_global_hook(
        mlua::HookTriggers::new().every_nth_instruction(1000),
        move |_, _| {
            if ticks.fetch_add(1000, Ordering::Relaxed) >= LUA_INSTRUCTIONS
                || Instant::now() >= deadline
            {
                return Err(mlua::Error::RuntimeError(
                    "OVERRIDE_SCRIPT_TIMEOUT: Lua execution limit exceeded".into(),
                ));
            }
            Ok(mlua::VmState::Continue)
        },
    )?;
    // Prevent protected calls from indefinitely swallowing the execution-limit error.
    for name in ["pcall", "xpcall"] {
        let original: mlua::Function = lua.globals().get(name)?;
        let ticks = instructions.clone();
        lua.globals().set(
            name,
            lua.create_function(move |_, args: mlua::MultiValue| {
                let check = || {
                    if ticks.load(Ordering::Relaxed) >= LUA_INSTRUCTIONS
                        || Instant::now() >= deadline
                    {
                        Err(mlua::Error::RuntimeError(
                            "OVERRIDE_SCRIPT_TIMEOUT: Lua execution limit exceeded".into(),
                        ))
                    } else {
                        Ok(())
                    }
                };
                check()?;
                let result = original.call::<mlua::MultiValue>(args);
                check()?;
                result
            })?,
        )?;
    }
    let args = lua.create_table()?;
    for argument in &invocation.args {
        args.set(argument.key.as_str(), argument.value.as_str())?;
    }
    let input = lua.create_table()?;
    input.set("command", invocation.command.as_str())?;
    input.set("config_path", invocation.config_path.as_str())?;
    input.set("script_path", invocation.script_path.as_str())?;
    input.set("args", args)?;
    lua.globals().set("input", input)?;
    let os = if worker {
        lua.globals().get::<mlua::Table>("os")?
    } else {
        lua.create_table()?
    };
    os.set(
        "getenv",
        lua.create_function(move |_, key: String| Ok(environment.get(&key).cloned()))?,
    )?;
    lua.globals().set("os", os)?;
    if !worker {
        // Base loadfile/dofile can block on special files even without the io library.
        lua.globals().set("dofile", mlua::Value::Nil)?;
        lua.globals().set("loadfile", mlua::Value::Nil)?;
    }
    let output = Arc::new(Mutex::new(Vec::<u8>::new()));
    let captured = output.clone();
    let write = lua.create_function(move |_, values: mlua::MultiValue| {
        let mut output = captured
            .lock()
            .map_err(|_| mlua::Error::RuntimeError("output lock poisoned".into()))?;
        for value in values {
            let text = match value {
                mlua::Value::String(text) => text.as_bytes().to_vec(),
                mlua::Value::Integer(number) => number.to_string().into_bytes(),
                mlua::Value::Number(number) => number.to_string().into_bytes(),
                _ => {
                    return Err(mlua::Error::RuntimeError(
                        "io.write requires strings or numbers".into(),
                    ));
                }
            };
            append_output(&mut output, &text).map_err(mlua::Error::external)?;
        }
        Ok(())
    })?;
    if !worker {
        let io = lua.create_table()?;
        io.set("write", write.clone())?;
        lua.globals().set("io", io)?;
    } else {
        // Keep native io for explicitly selected scripts; the parent bounds both pipes.
    }
    if !worker {
        let captured = output.clone();
        lua.globals().set(
            "print",
            lua.create_function(move |lua, values: mlua::MultiValue| {
                let tostring: mlua::Function = lua.globals().get("tostring")?;
                for (index, value) in values.into_iter().enumerate() {
                    let text: mlua::LuaString = tostring.call(value)?;
                    let mut output = captured
                        .lock()
                        .map_err(|_| mlua::Error::RuntimeError("output lock poisoned".into()))?;
                    if index != 0 {
                        append_output(&mut output, b"\t").map_err(mlua::Error::external)?;
                    }
                    append_output(&mut output, &text.as_bytes()).map_err(mlua::Error::external)?;
                }
                append_output(
                    &mut *captured
                        .lock()
                        .map_err(|_| mlua::Error::RuntimeError("output lock poisoned".into()))?,
                    b"\n",
                )
                .map_err(mlua::Error::external)
            })?,
        )?;
    }
    let flush: Option<mlua::Function> = if worker {
        Some(
            lua.load("local stdout = io.stdout; return function() stdout:flush() end")
                .eval()?,
        )
    } else {
        None
    };
    let result = lua
        .load(script)
        .set_name("override")
        .set_mode(mlua::chunk::ChunkMode::Text)
        .eval::<mlua::Value>()
        .map_err(|error| lua_failure(error, deadline))?;
    if let Some(flush) = flush {
        flush
            .call::<()>(())
            .map_err(|error| lua_failure(error, deadline))?;
    }
    let result = match result {
        mlua::Value::Nil => Vec::new(),
        mlua::Value::String(text) => text.as_bytes().to_vec(),
        mlua::Value::Table(ref table) if table.is_empty() => Vec::new(),
        mlua::Value::Table(_) => {
            let mut entries = MAX_COLLECTION_ENTRIES;
            let mut bytes = MAX_OUTPUT_BYTES;
            check_lua_value(
                &result,
                0,
                &mut entries,
                &mut bytes,
                &mut std::collections::HashSet::new(),
            )?;
            let mut value: Value = lua.from_value_with(
                result,
                mlua::serde::DeserializeOptions::new().sort_keys(true),
            )?;
            normalize_lua_collections(&mut value);
            serialize_yaml(&value, MAX_OUTPUT_BYTES)?.into_bytes()
        }
        _ => bail!("OVERRIDE_OUTPUT_INVALID: Lua must return a table, YAML string or nil"),
    };
    let mut output = output
        .lock()
        .map_err(|_| anyhow!("OVERRIDE_SCRIPT_EXEC_FAILED: output lock poisoned"))?;
    append_output(&mut output, &result)?;
    if !worker {
        validate_patch(&output)?;
    }
    Ok(std::mem::take(&mut *output))
}

fn lua_failure(error: mlua::Error, deadline: std::time::Instant) -> anyhow::Error {
    // Do not leak script snippets or returned secrets through diagnostics.
    if std::time::Instant::now() >= deadline
        || error.to_string().contains("OVERRIDE_SCRIPT_TIMEOUT")
    {
        anyhow!("OVERRIDE_SCRIPT_TIMEOUT: Lua execution limit exceeded")
    } else {
        anyhow!("OVERRIDE_SCRIPT_EXEC_FAILED: Lua syntax, execution or memory limit error")
    }
}

fn append_output(output: &mut Vec<u8>, text: &[u8]) -> Result<()> {
    if text.len() > MAX_OUTPUT_BYTES.saturating_sub(output.len()) {
        bail!("OVERRIDE_OUTPUT_INVALID: script output exceeds 1 MiB");
    }
    output.extend_from_slice(text);
    Ok(())
}

fn validate_patch(patch: &[u8]) -> Result<()> {
    if patch.len() > MAX_OUTPUT_BYTES {
        bail!("OVERRIDE_OUTPUT_INVALID: patch exceeds 1 MiB");
    }
    if !empty_patch(patch) {
        document(patch, MAX_OUTPUT_BYTES)?;
    }
    Ok(())
}

fn check_lua_value(
    value: &mlua::Value,
    depth: usize,
    entries: &mut usize,
    bytes: &mut usize,
    visiting: &mut std::collections::HashSet<usize>,
) -> Result<()> {
    if depth > 32 {
        bail!("OVERRIDE_OUTPUT_INVALID: Lua table nesting limit exceeded");
    }
    match value {
        mlua::Value::String(text) => {
            text.to_str()
                .map_err(|_| anyhow!("OVERRIDE_OUTPUT_INVALID: Lua strings must be UTF-8"))?;
            *bytes = bytes.checked_sub(text.as_bytes().len()).ok_or_else(|| {
                anyhow!("OVERRIDE_OUTPUT_INVALID: Lua string byte limit exceeded")
            })?;
        }
        mlua::Value::Table(table) => {
            let pointer = table.to_pointer() as usize;
            if !visiting.insert(pointer) {
                bail!("OVERRIDE_OUTPUT_INVALID: recursive Lua table");
            }
            let mut numeric_keys = 0usize;
            let mut string_keys = 0usize;
            let mut max_index = 0usize;
            for pair in table.pairs::<mlua::Value, mlua::Value>() {
                let (key, value) = pair?;
                match &key {
                    mlua::Value::Integer(index) if *index > 0 => {
                        numeric_keys += 1;
                        max_index = max_index.max(usize::try_from(*index)?);
                    }
                    mlua::Value::String(_) => string_keys += 1,
                    _ => bail!(
                        "OVERRIDE_OUTPUT_INVALID: Lua keys must be strings or contiguous positive indices"
                    ),
                }
                *entries = entries.checked_sub(1).ok_or_else(|| {
                    anyhow!("OVERRIDE_OUTPUT_INVALID: Lua collection entry limit exceeded")
                })?;
                check_lua_value(&key, depth + 1, entries, bytes, visiting)?;
                check_lua_value(&value, depth + 1, entries, bytes, visiting)?;
            }
            if (numeric_keys != 0 && string_keys != 0) || max_index != numeric_keys {
                bail!("OVERRIDE_OUTPUT_INVALID: mixed or sparse Lua table");
            }
            visiting.remove(&pointer);
        }
        _ => {}
    }
    Ok(())
}

fn normalize_lua_collections(value: &mut Value) {
    if let Some(map) = value.as_object_mut() {
        for field in ["proxies", "proxy-groups", "rules"] {
            if map
                .get(field)
                .and_then(Value::as_object)
                .is_some_and(|map| map.is_empty())
            {
                map.insert(field.into(), Value::Array(Vec::new()));
            }
        }
        for field in ["proxies", "proxy-groups"] {
            if let Some(items) = map.get_mut(field).and_then(Value::as_array_mut) {
                for item in items {
                    normalize_lua_collections(item);
                }
            }
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct Script {
    pub name: String,
    pub bytes: Vec<u8>,
}

#[derive(Debug, Clone)]
pub struct ExecutedOverride {
    pub script: Script,
    pub invocation: Invocation,
    pub patch_bytes: Vec<u8>,
}

/// Storage can convert these fields into its own metadata. No disk format or implicit writes.
#[derive(Debug, Clone)]
pub struct Materialization {
    pub source_bytes: Vec<u8>,
    pub effective_yaml: Vec<u8>,
    pub script: Script,
    pub invocation: Invocation,
    pub patch_bytes: Vec<u8>,
}

impl ExecutedOverride {
    /// The callback must perform the offline runtime capability gate before returning publishable data.
    pub fn materialize(
        self,
        source: &[u8],
        validate: impl FnOnce(&[u8]) -> Result<()>,
    ) -> Result<Materialization> {
        let effective_yaml = materialize_source(source, &self.patch_bytes)?;
        validate(&effective_yaml)?;
        Ok(Materialization {
            source_bytes: source.to_vec(),
            effective_yaml,
            script: self.script,
            invocation: self.invocation,
            patch_bytes: self.patch_bytes,
        })
    }
}

pub const WORKER_ARGUMENT: &str = "__override-worker";
pub const MAX_WORKER_INPUT_BYTES: usize = 8 * 1024 * 1024;
pub const MAX_STDERR_BYTES: usize = 1024 * 1024;

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(deny_unknown_fields)]
pub struct WorkerRequest {
    pub script: Vec<u8>,
    pub invocation: Invocation,
}

impl WorkerRequest {
    pub fn decode(bytes: &[u8]) -> Result<Self> {
        if bytes.len() > MAX_WORKER_INPUT_BYTES {
            bail!("OVERRIDE_SCRIPT_EXEC_FAILED: worker input exceeds 8 MiB");
        }
        let request: Self = serde_json::from_slice(bytes)
            .map_err(|_| anyhow!("OVERRIDE_SCRIPT_EXEC_FAILED: invalid worker request"))?;
        if request.script.len() > MAX_SCRIPT_BYTES {
            bail!("OVERRIDE_SCRIPT_EXEC_FAILED: script exceeds 1 MiB");
        }
        request.invocation.environment()?;
        Ok(request)
    }
}

/// Dispatch the first CLI argument before clap and daemon initialization; child process only.
/// Read bounded WorkerRequest JSON from stdin and emit raw YAML to stdout, without an envelope.
pub fn worker_main() -> Result<()> {
    use std::io::{Read, Write};
    let mut bytes = Vec::new();
    std::io::stdin()
        .lock()
        .take(MAX_WORKER_INPUT_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    let request = WorkerRequest::decode(&bytes)?;
    let output = evaluate_inner(&request.script, &request.invocation, true)?;
    let mut stdout = std::io::stdout().lock();
    stdout.write_all(&output)?;
    stdout.flush()?;
    Ok(())
}

/// Execute an explicitly selected script only; downloading a configuration never calls this.
/// Capture before execution so frozen script bytes match the actual execution input.
pub async fn execute(invocation: &Invocation) -> Result<ExecutedOverride> {
    invocation.environment()?;
    let path = std::path::Path::new(&invocation.script_path);
    let name = path
        .file_name()
        .and_then(|name| name.to_str())
        .ok_or_else(|| anyhow!("OVERRIDE_SCRIPT_NOT_FOUND: invalid script path"))?;
    let bytes = read_script(path)?;
    execute_bytes(
        &Script {
            name: name.into(),
            bytes,
        },
        invocation,
    )
    .await
}

/// Execute captured bytes, allowing rematerialization without the original script file.
pub async fn execute_bytes(script: &Script, invocation: &Invocation) -> Result<ExecutedOverride> {
    use tokio::process::Command;
    validate_script(script)?;
    let environment = invocation.environment()?;
    let temporary;
    let (mut command, input) = if script.name.ends_with(".lua") {
        let request = WorkerRequest {
            script: script.bytes.clone(),
            invocation: invocation.clone(),
        };
        let input = serde_json::to_vec(&request)?;
        if input.len() > MAX_WORKER_INPUT_BYTES {
            bail!("OVERRIDE_SCRIPT_EXEC_FAILED: worker input exceeds 8 MiB");
        }
        let mut command = Command::new(std::env::current_exe()?);
        command.arg(WORKER_ARGUMENT);
        (command, input)
    } else {
        temporary = TemporaryScript::new(&script.bytes)?;
        (Command::new(&temporary.path), Vec::new())
    };
    command.env_clear().envs(environment);
    let patch_bytes = run_child(
        command,
        input,
        invocation.timeout_ms,
        script.name.ends_with(".lua"),
    )
    .await?;
    validate_patch(&patch_bytes)?;
    Ok(ExecutedOverride {
        script: script.clone(),
        invocation: invocation.clone(),
        patch_bytes,
    })
}

fn validate_script(script: &Script) -> Result<()> {
    if script.name.is_empty()
        || script.name.len() > 255
        || matches!(script.name.as_str(), "." | "..")
        || script.name.contains(['/', '\\', '\0'])
        || script
            .name
            .chars()
            .any(|character| character.is_control() || unsafe_unicode(character))
    {
        bail!("OVERRIDE_SCRIPT_EXEC_FAILED: invalid script name");
    }
    if script.bytes.len() > MAX_SCRIPT_BYTES {
        bail!("OVERRIDE_SCRIPT_EXEC_FAILED: script exceeds 1 MiB");
    }
    Ok(())
}

fn read_script(path: &std::path::Path) -> Result<Vec<u8>> {
    use std::io::Read;
    #[cfg(unix)]
    let file: std::fs::File = {
        use rustix::fs::{Mode, OFlags, open};
        // Nonblocking open prevents a selected FIFO/device from hanging the caller.
        open(
            path,
            OFlags::RDONLY | OFlags::NONBLOCK | OFlags::CLOEXEC,
            Mode::empty(),
        )
        .map_err(|_| anyhow!("OVERRIDE_SCRIPT_NOT_FOUND: cannot open selected script"))?
        .into()
    };
    #[cfg(not(unix))]
    let file = std::fs::File::open(path)
        .map_err(|_| anyhow!("OVERRIDE_SCRIPT_NOT_FOUND: cannot open selected script"))?;
    let metadata = file.metadata()?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        if !path.to_string_lossy().ends_with(".lua") && metadata.permissions().mode() & 0o111 == 0 {
            bail!("OVERRIDE_SCRIPT_EXEC_FAILED: selected non-Lua script must be executable");
        }
    }
    if !metadata.is_file() || metadata.len() > MAX_SCRIPT_BYTES as u64 {
        bail!("OVERRIDE_SCRIPT_EXEC_FAILED: script must be a regular file at most 1 MiB");
    }
    let mut bytes = Vec::new();
    file.take(MAX_SCRIPT_BYTES as u64 + 1)
        .read_to_end(&mut bytes)?;
    if bytes.len() > MAX_SCRIPT_BYTES {
        bail!("OVERRIDE_SCRIPT_EXEC_FAILED: script exceeds 1 MiB");
    }
    Ok(bytes)
}

struct TemporaryScript {
    path: std::path::PathBuf,
}

impl TemporaryScript {
    fn new(bytes: &[u8]) -> Result<Self> {
        use std::io::Write;
        let mut random = [0u8; 16];
        getrandom::fill(&mut random).map_err(|_| {
            anyhow!("OVERRIDE_SCRIPT_EXEC_FAILED: cannot create random temporary name")
        })?;
        let name: String = random.iter().map(|byte| format!("{byte:02x}")).collect();
        let path = std::env::temp_dir().join(format!("zc-override-{name}"));
        let mut options = std::fs::OpenOptions::new();
        options.create_new(true).write(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o700);
        }
        let mut file = options.open(&path)?;
        let temporary = Self { path };
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        Ok(temporary)
    }
}

impl Drop for TemporaryScript {
    fn drop(&mut self) {
        let _ = std::fs::remove_file(&self.path);
    }
}

struct RunningChild {
    child: tokio::process::Child,
    #[cfg(unix)]
    group: Option<rustix::process::Pid>,
    active: bool,
}

impl RunningChild {
    fn stop(&mut self) {
        if !self.active {
            return;
        }
        #[cfg(unix)]
        if let Some(group) = self.group {
            let _ = rustix::process::kill_process_group(group, rustix::process::Signal::KILL);
        }
        let _ = self.child.start_kill();
    }
}

impl Drop for RunningChild {
    fn drop(&mut self) {
        self.stop();
    }
}

async fn run_child(
    mut command: tokio::process::Command,
    input: Vec<u8>,
    timeout_ms: u32,
    worker: bool,
) -> Result<Vec<u8>> {
    use std::process::Stdio;
    use tokio::io::AsyncWriteExt;
    use tokio::time::{Instant, sleep_until, timeout_at};
    validate_timeout(timeout_ms)?;
    let deadline = Instant::now() + std::time::Duration::from_millis(timeout_ms.into());
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .kill_on_drop(true);
    #[cfg(unix)]
    command.process_group(0);
    let child = loop {
        if Instant::now() >= deadline {
            bail!("OVERRIDE_SCRIPT_TIMEOUT: script exceeded its deadline");
        }
        match command.spawn() {
            Ok(child) => break child,
            Err(error) if !worker && error.kind() == std::io::ErrorKind::ExecutableFileBusy => {
                // Concurrent pre-exec children can briefly retain a writable fd.
                // Retry only this frozen executable, inside its original budget.
                sleep_until((Instant::now() + std::time::Duration::from_millis(5)).min(deadline))
                    .await;
            }
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                bail!("OVERRIDE_SCRIPT_NOT_FOUND: selected script interpreter not found");
            }
            Err(error) => {
                return Err(anyhow::Error::new(error)
                    .context("OVERRIDE_SCRIPT_EXEC_FAILED: cannot spawn selected script"));
            }
        }
    };
    let mut running = RunningChild {
        #[cfg(unix)]
        group: child
            .id()
            .and_then(|id| i32::try_from(id).ok())
            .and_then(rustix::process::Pid::from_raw),
        child,
        active: true,
    };
    let mut stdin = running.child.stdin.take().unwrap();
    let stdout = running.child.stdout.take().unwrap();
    let stderr = running.child.stderr.take().unwrap();
    let outcome = timeout_at(deadline, async {
        let write_input = async {
            stdin
                .write_all(&input)
                .await
                .map_err(|_| anyhow!("OVERRIDE_SCRIPT_EXEC_FAILED: worker input pipe failed"))?;
            drop(stdin);
            Ok::<_, anyhow::Error>(())
        };
        // Drain both pipes concurrently; never wait on a child with a full output pipe.
        let (_, stdout, stderr) = tokio::try_join!(
            write_input,
            read_pipe(stdout, MAX_OUTPUT_BYTES),
            read_pipe(stderr, MAX_STDERR_BYTES)
        )?;
        let status = running.child.wait().await?;
        running.active = false;
        if !status.success() {
            // The CLI prints worker errors to stderr. Preserve known codes only, never script text.
            if worker
                && stderr
                    .windows(b"OVERRIDE_SCRIPT_TIMEOUT".len())
                    .any(|part| part == b"OVERRIDE_SCRIPT_TIMEOUT")
            {
                bail!("OVERRIDE_SCRIPT_TIMEOUT: Lua execution limit exceeded");
            }
            if worker
                && stderr
                    .windows(b"OVERRIDE_OUTPUT_INVALID".len())
                    .any(|part| part == b"OVERRIDE_OUTPUT_INVALID")
            {
                bail!("OVERRIDE_OUTPUT_INVALID: invalid Lua patch or output limit exceeded");
            }
            bail!("OVERRIDE_SCRIPT_EXEC_FAILED: script returned a nonzero status");
        }
        Ok(stdout)
    })
    .await;
    match outcome {
        Ok(Ok(output)) => Ok(output),
        error => {
            running.stop();
            // Keep the leader unreaped until its pipes finish or we have killed the group.
            let _ = running.child.wait().await;
            running.active = false;
            match error {
                Err(_) => bail!("OVERRIDE_SCRIPT_TIMEOUT: script exceeded its deadline"),
                Ok(Err(error)) => Err(error),
                Ok(Ok(_)) => unreachable!(),
            }
        }
    }
}

async fn read_pipe(mut reader: impl tokio::io::AsyncRead + Unpin, limit: usize) -> Result<Vec<u8>> {
    use tokio::io::AsyncReadExt;
    let mut bytes = Vec::new();
    let mut chunk = [0u8; 8192];
    loop {
        let count = reader.read(&mut chunk).await?;
        if count == 0 {
            return Ok(bytes);
        }
        if count > limit.saturating_sub(bytes.len()) {
            bail!("OVERRIDE_OUTPUT_INVALID: script output limit exceeded");
        }
        bytes.extend_from_slice(&chunk[..count]);
    }
}

/// Public bare YAML with sensitive fields replaced by ******.
pub fn dump_config_yaml(source: &[u8]) -> Result<String> {
    let mut value = dump_value(source)?;
    redact(&mut value);
    canonical_config_yaml(&value, &provider_order(source)?, ConfigYamlKind::Public)
}

/// Public bare JSON without a CLI envelope.
pub fn dump_config_json(source: &[u8]) -> Result<String> {
    let mut value = dump_value(source)?;
    redact(&mut value);
    value.as_object_mut().unwrap().retain(|key, _| {
        matches!(
            key.as_str(),
            "port"
                | "socks-port"
                | "mixed-port"
                | "allow-lan"
                | "bind-address"
                | "mode"
                | "log-level"
                | "external-controller"
                | "rule-providers"
                | "proxies"
                | "proxy-groups"
                | "rules"
        )
    });
    for group in value["proxy-groups"].as_array_mut().unwrap() {
        group
            .as_object_mut()
            .unwrap()
            .retain(|key, _| matches!(key.as_str(), "name" | "type" | "proxies"));
    }
    for proxy in value["proxies"].as_array_mut().unwrap() {
        proxy.as_object_mut().unwrap().retain(|key, value| {
            if matches!(key.as_str(), "tls" | "skip-cert-verify" | "udp") {
                return value == true;
            }
            matches!(
                key.as_str(),
                "name"
                    | "type"
                    | "server"
                    | "port"
                    | "password"
                    | "cipher"
                    | "plugin"
                    | "plugin-opts"
                    | "uuid"
                    | "sni"
                    | "network"
                    | "grpc-opts"
                    | "ws-opts"
            )
        });
        if let Some(grpc) = proxy.get_mut("grpc-opts") {
            *grpc = serde_json::json!({});
        }
        if let Some(ws) = proxy.get_mut("ws-opts").and_then(Value::as_object_mut) {
            ws.retain(|key, _| matches!(key.as_str(), "path" | "headers"));
            if let Some(headers) = ws.get_mut("headers").and_then(Value::as_object_mut) {
                headers.retain(|key, _| key == "Host");
            }
        }
    }
    let output = serde_json::to_string(&value)?;
    let mut writer = BoundedText {
        text: String::new(),
        limit: MAX_SOURCE_BYTES,
    };
    std::fmt::Write::write_str(&mut writer, &output)
        .map_err(|_| anyhow!("CONFIG_DUMP_FAILED: output limit exceeded"))?;
    Ok(writer.text)
}

/// Owner-only snapshot: preserve secrets and omit already-expanded provider declarations.
/// The caller must expand providers first; reject unresolved RULE-SET dependencies.
pub fn dump_runtime_config_yaml(source: &[u8]) -> Result<String> {
    let mut value = dump_value(source)?;
    if value
        .get("rules")
        .and_then(Value::as_array)
        .is_some_and(|rules| {
            rules.iter().any(|rule| {
                rule.as_str().is_some_and(|rule| {
                    rule.split(',')
                        .next()
                        .is_some_and(|kind| kind.trim() == "RULE-SET")
                })
            })
        })
    {
        bail!("CONFIG_DUMP_FAILED: expand rule providers before creating a runtime snapshot");
    }
    value.as_object_mut().unwrap().remove("rule-providers");
    canonical_config_yaml(&value, &[], ConfigYamlKind::Runtime)
}

fn dump_value(source: &[u8]) -> Result<Value> {
    config_document(source)
}

fn canonical_plugin_options(value: &mut Value) -> Result<()> {
    if let Some(proxies) = value.get_mut("proxies").and_then(Value::as_array_mut) {
        for proxy in proxies {
            let proxy = proxy
                .as_object_mut()
                .ok_or_else(|| anyhow!("OVERRIDE_MERGE_FAILED: invalid proxy mapping"))?;
            if let Some(alias) = proxy.remove("plugin_opts") {
                if proxy.contains_key("plugin-opts") {
                    bail!("OVERRIDE_MERGE_FAILED: duplicate plugin options aliases");
                }
                proxy.insert("plugin-opts".into(), alias);
            }
            if let Some(options) = proxy.get("plugin-opts") {
                let options = options.as_object().ok_or_else(|| {
                    anyhow!("OVERRIDE_MERGE_FAILED: plugin options must be a mapping")
                })?;
                if options.iter().any(|(key, value)| {
                    !matches!(key.as_str(), "mode" | "host") || !value.is_string()
                }) {
                    bail!("OVERRIDE_MERGE_FAILED: unsupported plugin options");
                }
            }
        }
    }
    Ok(())
}

fn redact(value: &mut Value) {
    if let Some(secret) = value.get_mut("secret") {
        *secret = Value::String("******".into());
    }
    if let Some(proxies) = value.get_mut("proxies").and_then(Value::as_array_mut) {
        for proxy in proxies {
            for key in ["password", "uuid", "sni"] {
                if let Some(secret) = proxy.get_mut(key) {
                    *secret = Value::String("******".into());
                }
            }
        }
    }
}

struct BoundedText {
    text: String,
    limit: usize,
}

fn unsafe_unicode(character: char) -> bool {
    matches!(character, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{2028}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}' | '\u{80}'..='\u{9f}')
}

impl std::fmt::Write for BoundedText {
    fn write_str(&mut self, text: &str) -> std::fmt::Result {
        for character in text.chars() {
            if unsafe_unicode(character) {
                if self.limit.saturating_sub(self.text.len()) < 6 {
                    return Err(std::fmt::Error);
                }
                write!(self.text, "\\u{:04x}", character as u32)?;
            } else {
                if self.limit.saturating_sub(self.text.len()) < character.len_utf8() {
                    return Err(std::fmt::Error);
                }
                self.text.push(character);
            }
        }
        Ok(())
    }
}

// Every string is double quoted so escaping bidi/control characters in the writer
// cannot turn a plain/single-quoted scalar into a different value.
struct QuotedYaml<'a>(&'a Value);
impl serde::Serialize for QuotedYaml<'_> {
    fn serialize<S: serde::Serializer>(
        &self,
        serializer: S,
    ) -> std::result::Result<S::Ok, S::Error> {
        use serde::ser::{SerializeMap, SerializeSeq};
        match self.0 {
            Value::String(text) => serde_saphyr::DoubleQuoted(text).serialize(serializer),
            Value::Array(list) => {
                let mut sequence = serializer.serialize_seq(Some(list.len()))?;
                for item in list {
                    sequence.serialize_element(&QuotedYaml(item))?;
                }
                sequence.end()
            }
            Value::Object(map) => {
                let mut mapping = serializer.serialize_map(Some(map.len()))?;
                for (key, value) in map {
                    mapping
                        .serialize_entry(&serde_saphyr::DoubleQuoted(key), &QuotedYaml(value))?;
                }
                mapping.end()
            }
            scalar => scalar.serialize(serializer),
        }
    }
}

fn serialize_yaml(value: &Value, limit: usize) -> Result<String> {
    let mut writer = BoundedText {
        text: String::new(),
        limit,
    };
    serde_saphyr::to_fmt_writer(&mut writer, &QuotedYaml(value)).map_err(|_| {
        anyhow!("OVERRIDE_OUTPUT_INVALID: YAML serialization or output limit exceeded")
    })?;
    Ok(writer.text)
}

fn split_source_groups(value: &mut Value) {
    let map = value.as_object_mut().unwrap();
    let mut groups = Vec::new();
    if let Some(proxies) = map.get_mut("proxies").and_then(Value::as_array_mut) {
        let mut nodes = Vec::new();
        for item in std::mem::take(proxies) {
            if is_group(&item) {
                groups.push(item);
            } else {
                nodes.push(item);
            }
        }
        *proxies = nodes;
    }
    if !groups.is_empty() {
        if let Some(existing) = map
            .remove("proxy-groups")
            .and_then(|value| value.as_array().cloned())
        {
            groups.extend(existing);
        }
        map.insert("proxy-groups".into(), Value::Array(groups));
    }
}

// This wire format is part of schema-1 migration proofs. It mirrors the original
// override.zig effective/public writers, not a general YAML serializer.
#[derive(Clone, Copy, PartialEq)]
enum ConfigYamlKind {
    Effective,
    Public,
    Runtime,
}

fn config_document(source: &[u8]) -> Result<Value> {
    let mut value = document(source, MAX_SOURCE_BYTES)?;
    validate_collections(&value)?;
    split_source_groups(&mut value);
    canonical_plugin_options(&mut value)?;
    normalize_config(&mut value)?;
    Ok(value)
}

fn typed_default(
    map: &mut serde_json::Map<String, Value>,
    key: &str,
    default: Value,
) -> Result<()> {
    let value = map.entry(key).or_insert(default.clone());
    let valid = match default {
        Value::Bool(_) => value.is_boolean(),
        Value::Number(_) => value.as_i64().is_some(),
        Value::String(_) => value.is_string(),
        Value::Array(_) => value.is_array(),
        Value::Object(_) => value.is_object(),
        _ => false,
    };
    if !valid {
        bail!("OVERRIDE_MERGE_FAILED: invalid {key} type");
    }
    Ok(())
}
fn optional_string(
    map: &mut serde_json::Map<String, Value>,
    key: &str,
    nullable: bool,
) -> Result<()> {
    match map.get(key) {
        Some(Value::Null) if nullable => {
            map.remove(key);
        }
        Some(value) if !value.is_string() => bail!("OVERRIDE_MERGE_FAILED: invalid {key} type"),
        _ => {}
    }
    Ok(())
}
fn integer_range(value: &Value, key: &str, max: u64) -> Result<()> {
    if !value
        .get(key)
        .and_then(Value::as_u64)
        .is_some_and(|n| n <= max)
    {
        bail!("OVERRIDE_MERGE_FAILED: invalid {key} range");
    }
    Ok(())
}
fn normalize_config(value: &mut Value) -> Result<()> {
    use serde_json::json;
    let map = value.as_object_mut().unwrap();
    for (key, default) in [
        ("port", json!(0)),
        ("socks-port", json!(0)),
        ("mixed-port", json!(0)),
        ("redir-port", json!(0)),
        ("tproxy-port", json!(0)),
        ("allow-lan", json!(false)),
        ("bind-address", json!("*")),
        ("mode", json!("rule")),
        ("log-level", json!("info")),
        ("ipv6", json!(true)),
        ("idle-session-check-interval", json!(30)),
        ("idle-session-timeout", json!(30)),
        ("min-idle-session", json!(0)),
        ("proxies", json!([])),
        ("proxy-groups", json!([])),
        ("rule-providers", json!({})),
        ("rules", json!([])),
    ] {
        typed_default(map, key, default)?;
    }
    for key in ["external-controller", "external-ui", "secret"] {
        optional_string(map, key, true)?;
    }
    for key in [
        "port",
        "socks-port",
        "mixed-port",
        "redir-port",
        "tproxy-port",
    ] {
        integer_range(value, key, 65535)?;
    }
    integer_range(value, "min-idle-session", u32::MAX as u64)?;
    for proxy in value["proxies"].as_array_mut().unwrap() {
        let map = proxy.as_object_mut().unwrap();
        let kind = map["type"].as_str().unwrap().to_owned();
        if !matches!(
            kind.as_str(),
            "direct"
                | "reject"
                | "http"
                | "socks5"
                | "ss"
                | "vmess"
                | "trojan"
                | "vless"
                | "anytls"
        ) {
            bail!("OVERRIDE_MERGE_FAILED: unknown proxy type");
        }
        if matches!(kind.as_str(), "direct" | "reject") {
            map.insert("server".into(), json!(""));
            map.insert("port".into(), json!(0));
        } else if !map.get("server").is_some_and(Value::is_string)
            || !map
                .get("port")
                .and_then(Value::as_u64)
                .is_some_and(|p| p > 0 && p <= 65535)
        {
            bail!("OVERRIDE_MERGE_FAILED: proxy server/port required");
        }
        for key in ["password", "cipher", "uuid", "sni", "network", "plugin"] {
            optional_string(map, key, false)?;
        }
        for key in ["tls", "skip-cert-verify", "udp"] {
            typed_default(map, key, json!(false))?;
        }
        typed_default(map, "alterId", json!(0))?;
        for key in ["grpc-opts", "ws-opts"] {
            if map.get(key).is_some_and(|v| !v.is_object()) {
                bail!("OVERRIDE_MERGE_FAILED: transport options must be a map");
            }
        }
        if let Some(ws) = map.get_mut("ws-opts").and_then(Value::as_object_mut) {
            optional_string(ws, "path", false)?;
            if let Some(headers) = ws.get_mut("headers") {
                optional_string(
                    headers
                        .as_object_mut()
                        .ok_or_else(|| anyhow!("invalid ws headers"))?,
                    "Host",
                    false,
                )?;
            }
        }
        integer_range(proxy, "alterId", 65535)?;
        validate_plugin_metadata(proxy)?;
    }
    for group in value["proxy-groups"].as_array_mut().unwrap() {
        if !is_group(group) {
            bail!("OVERRIDE_MERGE_FAILED: unknown group type");
        }
        let map = group.as_object_mut().unwrap();
        optional_string(map, "url", false)?;
        for (key, default) in [
            ("proxies", json!([])),
            ("interval", json!(300)),
            ("tolerance", json!(100)),
            ("lazy", json!(true)),
        ] {
            typed_default(map, key, default)?;
        }
        integer_range(group, "interval", u32::MAX as u64)?;
        integer_range(group, "tolerance", 65535)?;
    }
    for provider in value["rule-providers"]
        .as_object_mut()
        .unwrap()
        .values_mut()
    {
        let map = provider.as_object_mut().unwrap();
        for key in ["type", "behavior", "path"] {
            if !map.get(key).is_some_and(Value::is_string) {
                bail!("OVERRIDE_MERGE_FAILED: provider fields required");
            }
        }
        optional_string(map, "url", true)?;
        typed_default(map, "interval", json!(86400))?;
        integer_range(provider, "interval", u32::MAX as u64)?;
        if provider["interval"] == 0
            || !matches!(provider["type"].as_str(), Some("file" | "http"))
            || !matches!(
                provider["behavior"].as_str(),
                Some("domain" | "ipcidr" | "classical")
            )
            || provider["path"].as_str() == Some("")
        {
            bail!("OVERRIDE_MERGE_FAILED: invalid provider declaration");
        }
        if let Some(url) = provider.get("url").and_then(Value::as_str) {
            let parsed = reqwest::Url::parse(url)?;
            if !matches!(parsed.scheme(), "http" | "https") || parsed.host_str().is_none() {
                bail!("invalid provider URL");
            }
        }
    }
    let rules = value["rules"].as_array_mut().unwrap();
    let mut final_seen = false;
    for rule in rules.iter_mut() {
        if final_seen {
            bail!("OVERRIDE_MERGE_FAILED: MATCH must be last");
        }
        let fields: Vec<_> = rule
            .as_str()
            .unwrap()
            .trim_matches([' ', '\t', '\r', '\n'])
            .split(',')
            .collect();
        let kind = fields[0];
        if !matches!(
            kind,
            "DOMAIN"
                | "DOMAIN-SUFFIX"
                | "DOMAIN-KEYWORD"
                | "IP-CIDR"
                | "IP-CIDR6"
                | "GEOIP"
                | "RULE-SET"
                | "SRC-IP-CIDR"
                | "DST-PORT"
                | "SRC-PORT"
                | "PROCESS-NAME"
                | "MATCH"
        ) {
            bail!("OVERRIDE_MERGE_FAILED: unknown rule type");
        }
        let count = if kind == "MATCH" { 2 } else { 3 };
        if fields.len() < count {
            bail!("OVERRIDE_MERGE_FAILED: incomplete rule");
        }
        let mut normalized = fields[..count]
            .iter()
            .map(|field| field.trim_matches([' ', '\t']))
            .collect::<Vec<_>>()
            .join(",");
        if fields[count..]
            .iter()
            .any(|field| field.trim_matches([' ', '\t']) == "no-resolve")
        {
            normalized.push_str(",no-resolve");
        }
        final_seen = kind == "MATCH";
        *rule = json!(normalized);
    }
    if !final_seen {
        rules.push(json!("MATCH,REJECT"));
    }
    Ok(())
}

fn yaml_quote(text: &str) -> String {
    use std::fmt::Write;
    let mut output = String::from("\"");
    for c in text.chars() {
        match c {
            '\\' => output.push_str("\\\\"),
            '"' => output.push_str("\\\""),
            '\n' => output.push_str("\\n"),
            '\r' => output.push_str("\\r"),
            '\t' => output.push_str("\\t"),
            '\x00'..='\x1f' | '\x7f' => write!(output, "\\x{:02x}", c as u32).unwrap(),
            c if unsafe_unicode(c) => write!(output, "\\u{:04x}", c as u32).unwrap(),
            c => output.push(c),
        }
    }
    output.push('"');
    output
}
fn yaml_field(output: &mut BoundedText, prefix: &str, key: &str, value: &Value) -> Result<()> {
    use std::fmt::Write;
    let scalar = if let Some(s) = value.as_str() {
        yaml_quote(s)
    } else {
        value.to_string()
    };
    writeln!(output, "{prefix}{key}: {scalar}")
        .map_err(|_| anyhow!("CONFIG_DUMP_FAILED: output limit exceeded"))
}
fn canonical_config_yaml(
    value: &Value,
    providers: &[String],
    kind: ConfigYamlKind,
) -> Result<String> {
    use std::fmt::Write;
    let mut out = BoundedText {
        text: String::new(),
        limit: MAX_SOURCE_BYTES,
    };
    let mut emit = |prefix: &str, key: &str, v: &Value| yaml_field(&mut out, prefix, key, v);
    for key in [
        "port",
        "socks-port",
        "mixed-port",
        "redir-port",
        "tproxy-port",
        "allow-lan",
    ] {
        emit("", key, &value[key])?;
    }
    if kind != ConfigYamlKind::Effective {
        emit("", "ipv6", &value["ipv6"])?;
    }
    for key in ["bind-address", "mode", "log-level"] {
        emit("", key, &value[key])?;
    }
    if kind == ConfigYamlKind::Effective {
        emit("", "ipv6", &value["ipv6"])?;
    }
    for key in [
        "external-controller",
        "external-ui",
        "secret",
        "idle-session-check-interval",
        "idle-session-timeout",
        "min-idle-session",
    ] {
        if let Some(v) = value.get(key) {
            emit("", key, v)?;
        }
    }
    let write_error = |_| anyhow!("CONFIG_DUMP_FAILED: output limit exceeded");
    if kind != ConfigYamlKind::Runtime {
        if providers.is_empty() {
            if kind == ConfigYamlKind::Effective {
                out.write_str("rule-providers: {}\n").map_err(write_error)?;
            }
        } else {
            out.write_str("rule-providers:\n").map_err(write_error)?;
            for name in providers {
                writeln!(out, "  {}:", yaml_quote(name)).map_err(write_error)?;
                let provider = &value["rule-providers"][name];
                for key in ["type", "behavior", "url", "path", "interval"] {
                    if let Some(v) = provider.get(key) {
                        yaml_field(&mut out, "    ", key, v)?;
                    }
                }
            }
        }
    }
    let proxies = value["proxies"].as_array().unwrap();
    out.write_str(if proxies.is_empty() {
        "proxies: []\n"
    } else {
        "proxies:\n"
    })
    .map_err(write_error)?;
    for proxy in proxies {
        yaml_field(&mut out, "  - ", "name", &proxy["name"])?;
        yaml_field(&mut out, "    ", "type", &proxy["type"])?;
        if kind != ConfigYamlKind::Effective
            || !matches!(proxy["type"].as_str(), Some("direct" | "reject"))
        {
            for key in ["server", "port"] {
                yaml_field(&mut out, "    ", key, &proxy[key])?;
            }
        }
        for key in ["password", "cipher", "uuid"] {
            if let Some(v) = proxy.get(key) {
                yaml_field(&mut out, "    ", key, v)?;
            }
        }
        if proxy["alterId"] != 0 {
            yaml_field(&mut out, "    ", "alterId", &proxy["alterId"])?;
        }
        for key in ["tls", "skip-cert-verify"] {
            if proxy[key] == true {
                yaml_field(&mut out, "    ", key, &proxy[key])?;
            }
        }
        if kind == ConfigYamlKind::Effective && proxy["udp"] == true {
            yaml_field(&mut out, "    ", "udp", &proxy["udp"])?;
        }
        for key in ["sni", "network"] {
            if let Some(v) = proxy.get(key) {
                yaml_field(&mut out, "    ", key, v)?;
            }
        }
        if proxy.get("grpc-opts").is_some() {
            out.write_str("    grpc-opts: {}\n").map_err(write_error)?;
        }
        if kind != ConfigYamlKind::Effective && proxy["udp"] == true {
            yaml_field(&mut out, "    ", "udp", &proxy["udp"])?;
        }
        if let Some(ws) = proxy.get("ws-opts") {
            let path = ws.get("path");
            let host = ws.get("headers").and_then(|h| h.get("Host"));
            out.write_str(if path.is_none() && host.is_none() {
                "    ws-opts: {}\n"
            } else {
                "    ws-opts:\n"
            })
            .map_err(write_error)?;
            if let Some(path) = path {
                yaml_field(&mut out, "      ", "path", path)?;
            }
            if let Some(host) = host {
                out.write_str("      headers:\n").map_err(write_error)?;
                yaml_field(&mut out, "        ", "Host", host)?;
            }
        }
        if let Some(plugin) = proxy.get("plugin") {
            yaml_field(&mut out, "    ", "plugin", plugin)?;
        }
        if let Some(options) = proxy.get("plugin-opts") {
            out.write_str(if options.as_object().unwrap().is_empty() {
                "    plugin-opts: {}\n"
            } else {
                "    plugin-opts:\n"
            })
            .map_err(write_error)?;
            for key in ["mode", "host"] {
                if let Some(v) = options.get(key) {
                    yaml_field(&mut out, "      ", key, v)?;
                }
            }
        }
    }
    let groups = value["proxy-groups"].as_array().unwrap();
    out.write_str(if groups.is_empty() {
        "proxy-groups: []\n"
    } else {
        "proxy-groups:\n"
    })
    .map_err(write_error)?;
    for group in groups {
        yaml_field(&mut out, "  - ", "name", &group["name"])?;
        yaml_field(&mut out, "    ", "type", &group["type"])?;
        let members = group["proxies"].as_array().unwrap();
        out.write_str(if members.is_empty() && kind == ConfigYamlKind::Effective {
            "    proxies: []\n"
        } else {
            "    proxies:\n"
        })
        .map_err(write_error)?;
        for member in members {
            writeln!(out, "      - {}", yaml_quote(member.as_str().unwrap()))
                .map_err(write_error)?;
        }
        for key in ["url", "interval", "tolerance", "lazy"] {
            if let Some(v) = group.get(key) {
                yaml_field(&mut out, "    ", key, v)?;
            }
        }
    }
    out.write_str("rules:\n").map_err(write_error)?;
    for rule in value["rules"].as_array().unwrap() {
        writeln!(out, "  - {}", yaml_quote(rule.as_str().unwrap())).map_err(write_error)?;
    }
    Ok(out.text)
}

#[derive(Default)]
struct ProviderNames(Vec<String>);
impl<'de> serde::Deserialize<'de> for ProviderNames {
    fn deserialize<D: serde::Deserializer<'de>>(
        deserializer: D,
    ) -> std::result::Result<Self, D::Error> {
        struct Visitor;
        impl<'de> serde::de::Visitor<'de> for Visitor {
            type Value = ProviderNames;
            fn expecting(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                f.write_str("provider mapping")
            }
            fn visit_map<M: serde::de::MapAccess<'de>>(
                self,
                mut map: M,
            ) -> std::result::Result<Self::Value, M::Error> {
                let mut names = Vec::new();
                while let Some((name, _)) = map.next_entry::<String, serde::de::IgnoredAny>()? {
                    names.push(name);
                }
                Ok(ProviderNames(names))
            }
        }
        deserializer.deserialize_map(Visitor)
    }
}
fn provider_order(source: &[u8]) -> Result<Vec<String>> {
    #[derive(serde::Deserialize)]
    struct Names {
        #[serde(default, rename = "rule-providers")]
        providers: ProviderNames,
    }
    // The bounded strict document parser has already accepted this input.
    let source = std::str::from_utf8(source)?;
    if source.is_ascii()
        && !source.contains('\u{007f}')
        && let Ok(names) = serde_json::from_str::<Names>(source)
    {
        return Ok(zig_map_order(names.providers.0));
    }
    let names: Names = crate::config::on_document_stack(source, || {
        let options = serde_saphyr::options! {
            budget: serde_saphyr::budget! {
                max_depth: crate::config::MAX_DOCUMENT_DEPTH,
                flow_nesting_limit: crate::config::MAX_DOCUMENT_DEPTH, max_events: 1_600_000,
                max_nodes: 524_289, max_total_scalar_bytes: MAX_SOURCE_BYTES,
                max_documents: 1, max_aliases: 0, max_anchors: 0, max_merge_keys: 0,
                max_inclusion_depth: 0,
            },
        };
        serde_saphyr::from_str_with_options(source, options)
            .map_err(|_| anyhow!("OVERRIDE_MERGE_FAILED: provider ordering resource limit"))
    })?;
    Ok(zig_map_order(names.providers.0))
}
fn zig_map_order(names: Vec<String>) -> Vec<String> {
    fn insert(slots: &mut [Option<String>], name: String) {
        let mut index = zig_string_hash(name.as_bytes()) as usize & (slots.len() - 1);
        for _ in 0..slots.len() {
            if slots[index].is_none() {
                slots[index] = Some(name);
                return;
            }
            index = (index + 1) & (slots.len() - 1);
        }
        unreachable!("bounded hash table always has free capacity");
    }
    let mut slots = Vec::new();
    for (count, name) in names.into_iter().enumerate() {
        if count + 1 > slots.len() * 80 / 100 {
            let capacity = (((count + 1) * 100 / 80 + 1).next_power_of_two()).max(8);
            let old = std::mem::replace(&mut slots, vec![None; capacity]);
            for name in old.into_iter().flatten() {
                insert(&mut slots, name);
            }
        }
        insert(&mut slots, name);
    }
    slots.into_iter().flatten().collect()
}
// Zig 0.16 std.hash.Wyhash.hash(0, bytes), used by StringHashMap's serialized
// provider iteration order. This is wire compatibility, never a security hash.
fn zig_string_hash(bytes: &[u8]) -> u64 {
    const SECRET: [u64; 4] = [
        0xa0761d6478bd642f,
        0xe7037ed1a0b428db,
        0x8ebc6af09c88c6e3,
        0x589965cc75374cc3,
    ];
    fn mix(a: u64, b: u64) -> u64 {
        let p = a as u128 * b as u128;
        p as u64 ^ (p >> 64) as u64
    }
    fn read(b: &[u8], n: usize) -> u64 {
        b[..n]
            .iter()
            .enumerate()
            .fold(0, |v, (i, b)| v | ((*b as u64) << (i * 8)))
    }
    let mut state = [mix(SECRET[0], SECRET[1]); 3];
    let (mut a, mut b);
    let len = bytes.len();
    if len <= 16 {
        if len >= 4 {
            let end = len - 4;
            let quarter = (len >> 3) << 2;
            a = (read(bytes, 4) << 32) | read(&bytes[quarter..], 4);
            b = (read(&bytes[end..], 4) << 32) | read(&bytes[end - quarter..], 4);
        } else if len > 0 {
            a = ((bytes[0] as u64) << 16) | ((bytes[len >> 1] as u64) << 8) | bytes[len - 1] as u64;
            b = 0;
        } else {
            a = 0;
            b = 0;
        }
    } else {
        let mut i = 0;
        if len >= 48 {
            while i + 48 < len {
                for lane in 0..3 {
                    state[lane] = mix(
                        read(&bytes[i + lane * 16..], 8) ^ SECRET[lane + 1],
                        read(&bytes[i + lane * 16 + 8..], 8) ^ state[lane],
                    );
                }
                i += 48;
            }
            state[0] ^= state[1] ^ state[2];
        }
        while i + 16 < len {
            state[0] = mix(
                read(&bytes[i..], 8) ^ SECRET[1],
                read(&bytes[i + 8..], 8) ^ state[0],
            );
            i += 16;
        }
        a = read(&bytes[len - 16..], 8);
        b = read(&bytes[len - 8..], 8);
    }
    a ^= SECRET[1];
    b ^= state[0];
    let product = a as u128 * b as u128;
    mix(
        product as u64 ^ SECRET[0] ^ len as u64,
        (product >> 64) as u64 ^ SECRET[1],
    )
}

fn materializable(value: &Value) -> Result<()> {
    if value["mixed-port"] == 0 && (value["port"] != 0 || value["socks-port"] != 0) {
        bail!("UnsupportedCapability: standalone listeners");
    }
    for group in value["proxy-groups"].as_array().unwrap() {
        if group["type"] != "select" || matches!(group["name"].as_str(), Some("DIRECT" | "REJECT"))
        {
            bail!("UnsupportedCapability: proxy group");
        }
    }
    for proxy in value["proxies"].as_array().unwrap() {
        let kind = proxy["type"].as_str().unwrap();
        if !matches!(kind, "direct" | "reject" | "ss" | "trojan")
            || matches!(proxy["name"].as_str(), Some("DIRECT" | "REJECT"))
            || proxy.get("ws-opts").is_some()
            || proxy.get("grpc-opts").is_some()
            || proxy.get("network").is_some_and(|v| v != "tcp")
        {
            bail!("UnsupportedCapability: proxy transport");
        }
        if kind == "ss"
            && (proxy["tls"] == true
                || proxy.get("cipher").is_some_and(|v| {
                    !matches!(
                        v.as_str(),
                        Some(
                            "aes-128-gcm"
                                | "aes-256-gcm"
                                | "chacha20-ietf-poly1305"
                                | "chacha20-poly1305"
                        )
                    )
                }))
        {
            bail!("UnsupportedCapability: Shadowsocks cipher/TLS");
        }
        validate_plugin_metadata(proxy)?;
    }
    Ok(())
}

/// Project typed, compatibility-only Zig fields for the current runtime parser.
/// Never use this projection as revision content: proofs hash canonical bytes.
pub fn runtime_source(source: &[u8]) -> Result<String> {
    let mut value = config_document(source)?;
    let map = value.as_object_mut().unwrap();
    // Accepted subscription metadata, not implemented runtime capabilities.
    // Drop only from this projection; immutable source and proof bytes stay intact.
    for key in [
        "dns",
        "hosts",
        "sniffer",
        "profile",
        "experimental",
        "unified-delay",
        "clash-for-android",
        "redir-port",
        "tproxy-port",
        "ipv6",
        "external-ui",
        "idle-session-check-interval",
        "idle-session-timeout",
        "min-idle-session",
    ] {
        map.remove(key);
    }
    // Zig ignores bind-address whenever allow-lan is false.
    if map["allow-lan"] == false {
        map.insert("bind-address".into(), Value::String("127.0.0.1".into()));
    }
    // Compatibility-only group tunables do not alter select behavior.
    for group in map["proxy-groups"].as_array_mut().unwrap() {
        let group = group.as_object_mut().unwrap();
        for key in ["url", "interval", "tolerance", "lazy"] {
            group.remove(key);
        }
    }
    for proxy in map["proxies"].as_array_mut().unwrap() {
        let proxy = proxy.as_object_mut().unwrap();
        // Defaults absent in input must not become a new TLS declaration.
        for key in ["tls", "skip-cert-verify"] {
            if proxy.get(key) == Some(&Value::Bool(false)) {
                proxy.remove(key);
            }
        }
        // Match Zig's native connector inputs after type validation. Never discard
        // network/ws/grpc/plugin declarations, SS cipher/TLS, or Trojan TLS identity.
        let unused: &[&str] = match proxy.get("type").and_then(Value::as_str) {
            Some("direct" | "reject") => &[
                "password",
                "cipher",
                "uuid",
                "alterId",
                "tls",
                "sni",
                "skip-cert-verify",
            ],
            Some("ss") => &["uuid", "alterId", "sni", "skip-cert-verify"],
            Some("trojan") => &["uuid", "alterId", "cipher", "tls"],
            _ => &[],
        };
        for key in unused {
            proxy.remove(*key);
        }
        if proxy.get("alterId") == Some(&Value::from(0)) {
            proxy.remove("alterId");
        }
    }
    Ok(serde_json::to_string(&value)?)
}

fn validate_plugin_metadata(proxy: &Value) -> Result<()> {
    let kind = proxy["type"].as_str().unwrap();
    match (proxy.get("plugin"), proxy.get("plugin-opts")) {
        (None, None) => {}
        (Some(plugin), Some(options))
            if kind == "ss"
                && matches!(plugin.as_str(), Some("obfs" | "obfs-local"))
                && options.get("mode").and_then(Value::as_str) == Some("http") =>
        {
            crate::simple_obfs::validate_host(
                options
                    .get("host")
                    .and_then(Value::as_str)
                    .ok_or_else(|| anyhow!("UnsupportedCapability: missing obfs host"))?,
            )?;
        }
        _ => bail!("UnsupportedCapability: plugin metadata"),
    }
    Ok(())
}
