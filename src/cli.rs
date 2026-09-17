//! Public command contract. State and runtime authority remain in store/daemon.
use crate::{
    config::{self, Config},
    daemon,
    fsutil::SecureDir,
    override_script::{self, CliOptions},
    service::{self, PrepareOptions},
    store::{self, ActiveIdentity, Bundle, FrozenOverride, Metadata, Selection, Store},
};
use anyhow::{Context, Result, anyhow, bail, ensure};
use serde_json::{Value, json};
use std::{
    collections::{BTreeMap, BTreeSet},
    io::{IsTerminal, Write},
    path::Path,
    time::Duration,
};

#[derive(Debug)]
struct Failure {
    code: String,
    message: String,
    hint: String,
    exit: u8,
    data: Option<Value>,
}
impl std::fmt::Display for Failure {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}: {}", self.code, self.message)
    }
}
impl std::error::Error for Failure {}
fn fail(code: &str, message: &str, hint: &str, exit: u8) -> anyhow::Error {
    Failure {
        code: code.into(),
        message: message.into(),
        hint: hint.into(),
        exit,
        data: None,
    }
    .into()
}
fn usage(code: &str, command: &str) -> anyhow::Error {
    fail(
        code,
        "unknown, missing or invalid command argument",
        &format!("run `zc help {command}` for usage"),
        2,
    )
}

const COMMANDS: &[(&str, &str)] = &[
    ("start", "[-c <config>] [--port <port>] [--foreground]"),
    ("stop", ""),
    ("restart", "[-c <config>] [--port <port>]"),
    ("reload", ""),
    ("status", ""),
    ("log", "[-n <lines>] [-f|--no-follow]"),
    ("test", "[-c <config>] [--port <port>]"),
    ("doctor", "[-c <config>]"),
    ("version", ""),
    ("config load", "<path>"),
    ("config list", ""),
    ("config download", "<url> [-n <name>] [-d]"),
    ("config update", "[name] [--apply auto|hot|restart]"),
    ("config use", "<name>"),
    ("config delete", "<name>"),
    ("config dump", "[-c <config>] [--no-override]"),
    ("config override", "[script|--clear]"),
    ("proxy list", "[-c <config>]"),
    ("proxy select", "[-g <group>] [-p <proxy>] [-c <config>]"),
    ("proxy test", "[-c <config>] [--port <port>]"),
    ("profile list", "[-c <config>]"),
    ("profile select", "[-g <group>] [-p <proxy>] [-c <config>]"),
    ("profile test", "[-c <config>] [--port <port>]"),
    ("diag doctor", "[-c <config>]"),
];
fn group(s: &str) -> bool {
    matches!(s, "config" | "proxy" | "profile" | "diag")
}
fn canonical(s: &str) -> &str {
    match s {
        "up" => "start",
        "down" => "stop",
        "--version" => "version",
        _ => s,
    }
}
fn sub_alias(s: &str) -> &str {
    match s {
        "ls" => "list",
        "rm" | "remove" => "delete",
        _ => s,
    }
}
fn help(topic: &str) -> Result<String> {
    if topic.is_empty() {
        let commands = COMMANDS
            .iter()
            .filter(|(p, _)| !p.contains(' '))
            .map(|(p, _)| format!("  {p}"))
            .collect::<Vec<_>>()
            .join("\n");
        return Ok(format!(
            "zc {} — proxy runtime\n\nUsage: zc <command> [options]\n\nCommands:\n{commands}\n  config\n  proxy\n  profile\n  diag\n  help\n\nAliases: up = start, down = stop, ls = list\n\nOptions:\n  --json        Machine-readable output\n  --no-color    Disable ANSI colors\n\nExamples:\n  zc help start\n",
            env!("CARGO_PKG_VERSION")
        ));
    }
    if group(topic) {
        let items = COMMANDS
            .iter()
            .filter(|(p, _)| p.starts_with(&format!("{topic} ")))
            .map(|(p, a)| format!("  {p} {a}"))
            .collect::<Vec<_>>()
            .join("\n");
        return Ok(format!(
            "Usage: zc {topic} <subcommand> [options]\n\nSubcommands:\n{items}\n\nOptions:\n  --json\n\nExamples:\n  zc help {topic}\n"
        ));
    }
    let &(path, args) = COMMANDS
        .iter()
        .find(|(p, _)| *p == topic)
        .ok_or_else(|| usage("HELP_TOPIC_UNKNOWN", ""))?;
    let overrides = if matches!(path, "start" | "restart" | "config dump") {
        "\n  --override-script <path>\n  --override-arg <key=value>\n  --override-timeout-ms <n>"
    } else {
        ""
    };
    // Clap owns help layout; dispatch keeps the frozen command-specific usage codes.
    let usage_text = format!("zc {path} {args} [--json]");
    let after = format!(
        "Options:\n  {args}\n  --json\n  --no-color{overrides}\n\nAliases: up = start, down = stop, ls = list\n\nExamples:\n  zc {path} --help"
    );
    let mut cli = clap::Command::new("zc")
        .disable_version_flag(true)
        .override_usage(usage_text)
        .after_help(after);
    Ok(cli.render_long_help().to_string())
}

#[derive(Default)]
struct Args {
    path: String,
    values: BTreeMap<String, String>,
    flags: BTreeSet<String>,
    positionals: Vec<String>,
    overrides: CliOptions,
}
impl Args {
    fn value(&self, k: &str) -> Option<&str> {
        self.values.get(k).map(String::as_str)
    }
    fn flag(&self, k: &str) -> bool {
        self.flags.contains(k)
    }
    fn port(&self) -> Option<u16> {
        self.value("--port").and_then(|p| p.parse().ok())
    }
    fn prepare(&self) -> PrepareOptions {
        PrepareOptions {
            config: self.value("-c").map(str::to_owned),
            port: self.port(),
            foreground: self.flag("--foreground"),
            command: self.path.clone(),
            override_options: self.overrides.clone(),
        }
    }
}
fn argument_code(path: &str) -> String {
    match path {
        "start" | "restart" => "START_ARGS_INVALID".into(),
        "doctor" | "diag doctor" => "DIAG_DOCTOR_ARGUMENT_INVALID".into(),
        _ => format!("{}_ARGUMENT_INVALID", path.replace(' ', "_").to_uppercase()),
    }
}
fn parse(path: &str, tokens: &[String]) -> Result<Args> {
    let mut args = Args {
        path: path.into(),
        ..Default::default()
    };
    let mut i = 0;
    while i < tokens.len() {
        let token = &tokens[i];
        let (flag, inline) = token
            .split_once('=')
            .map_or((token.as_str(), None), |(a, b)| (a, Some(b)));
        let normalized = match flag {
            "--config" => "-c",
            "--follow" => "-f",
            _ => flag,
        };
        if matches!(normalized, "--json" | "--no-color") && inline.is_none() {
            args.flags.insert(normalized.into());
            i += 1;
            continue;
        }
        if matches!(normalized, "--override-dump-yaml" | "--override-dump-json") {
            return Err(usage("OVERRIDE_OPTION_DEPRECATED", path));
        }
        let override_flag = matches!(
            normalized,
            "--override-script" | "--override-arg" | "--override-timeout-ms"
        );
        let takes_value = override_flag
            || match normalized {
                "-c" => matches!(
                    path,
                    "start"
                        | "restart"
                        | "test"
                        | "doctor"
                        | "diag doctor"
                        | "config dump"
                        | "proxy list"
                        | "proxy select"
                        | "proxy test"
                        | "profile list"
                        | "profile select"
                        | "profile test"
                ),
                "--port" => matches!(
                    path,
                    "start" | "restart" | "test" | "proxy test" | "profile test"
                ),
                "-n" => matches!(path, "log" | "config download"),
                "--apply" => path == "config update",
                "-g" | "-p" => path.ends_with(" select"),
                _ => false,
            };
        if takes_value {
            let value = if let Some(v) = inline {
                Some(v)
            } else {
                i += 1;
                tokens
                    .get(i)
                    .map(String::as_str)
                    .filter(|v| !v.starts_with('-'))
            };
            let missing_code = match normalized {
                "-c" if matches!(path, "start" | "restart") => "START_CONFIG_PATH_REQUIRED".into(),
                "--port" if matches!(path, "start" | "restart") => "START_PORT_REQUIRED".into(),
                "-n" if path == "config download" => "CONFIG_DOWNLOAD_NAME_REQUIRED".into(),
                "--override-script" => "OVERRIDE_SCRIPT_NOT_FOUND".into(),
                "--override-arg" => "OVERRIDE_OUTPUT_INVALID".into(),
                "--override-timeout-ms" => "OVERRIDE_SCRIPT_TIMEOUT".into(),
                _ => argument_code(path),
            };
            let value = value
                .filter(|v| !v.is_empty())
                .ok_or_else(|| usage(&missing_code, path))?;
            match normalized {
                "--port" => {
                    if value.parse::<u16>().ok().filter(|n| *n != 0).is_none()
                        || !value.bytes().all(|b| b.is_ascii_digit())
                    {
                        let code = if matches!(path, "start" | "restart") {
                            "START_PORT_INVALID".into()
                        } else {
                            argument_code(path)
                        };
                        return Err(usage(&code, path));
                    }
                }
                "-n" if path == "log" => {
                    if value.parse::<usize>().is_err() || !value.bytes().all(|b| b.is_ascii_digit())
                    {
                        return Err(usage("LOG_ARGUMENT_INVALID", path));
                    }
                }
                "--apply" if !matches!(value, "auto" | "hot" | "restart") => {
                    return Err(usage("CONFIG_UPDATE_APPLY_INVALID", path));
                }
                "--override-script" => args.overrides.script_path = Some(value.into()),
                "--override-arg" => args.overrides.args.push(
                    override_script::OverrideArg::parse(value)
                        .map_err(|_| usage("OVERRIDE_OUTPUT_INVALID", path))?,
                ),
                "--override-timeout-ms" => {
                    args.overrides.timeout_ms = override_script::parse_timeout_ms(value)
                        .map_err(|_| usage("OVERRIDE_SCRIPT_TIMEOUT", path))?
                }
                _ => {}
            }
            if !override_flag {
                args.values.insert(normalized.into(), value.into());
            }
        } else {
            let boolean = match normalized {
                "--foreground" => path == "start",
                "-f" | "--no-follow" => path == "log",
                "-d" => path == "config download",
                "--clear" => path == "config override",
                "--no-override" => path == "config dump",
                _ => false,
            };
            if boolean && inline.is_none() {
                args.flags.insert(normalized.into());
            } else if !token.starts_with('-') {
                args.positionals.push(token.clone());
            } else {
                return Err(usage(&argument_code(path), path));
            }
        }
        i += 1;
    }
    let (min, max, missing) = match path {
        "config load" => (1, 1, "CONFIG_LOAD_PATH_REQUIRED"),
        "config download" => (1, 1, "CONFIG_DOWNLOAD_URL_REQUIRED"),
        "config use" => (1, 1, "CONFIG_USE_NAME_REQUIRED"),
        "config delete" => (1, 1, "CONFIG_DELETE_NAME_REQUIRED"),
        "config update" | "config override" => (0, 1, ""),
        _ => (0, 0, ""),
    };
    if args.positionals.len() < min {
        return Err(usage(missing, path));
    }
    if args.positionals.len() > max || (args.flag("--clear") && !args.positionals.is_empty()) {
        return Err(usage(&argument_code(path), path));
    }
    Ok(args)
}

enum Output {
    Data(Value),
    Raw(String),
    Silent,
}
fn without_nulls(value: &mut Value) {
    match value {
        Value::Object(map) => {
            map.retain(|_, v| !v.is_null());
            for v in map.values_mut() {
                without_nulls(v);
            }
        }
        Value::Array(a) => {
            for v in a {
                without_nulls(v)
            }
        }
        _ => {}
    }
}
pub fn ascii_json(value: &Value) -> String {
    let text = serde_json::to_string(value).expect("JSON values serialize");
    let mut output = String::with_capacity(text.len());
    for c in text.chars() {
        if c.is_ascii() {
            output.push(c)
        } else {
            for unit in c.encode_utf16(&mut [0; 2]) {
                use std::fmt::Write;
                write!(output, "\\u{unit:04x}").expect("string write");
            }
        }
    }
    output
}
fn safe_text(text: &str) -> String {
    text.chars().flat_map(|c| if c.is_control() || matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{2028}'..='\u{202e}'|'\u{2066}'..='\u{2069}'|'\u{feff}') {c.escape_default().collect::<Vec<_>>()} else {vec![c]}).collect()
}

/// Run ordinary CLI dispatch, returning the stable process exit code.
pub async fn run(tokens: Vec<String>) -> u8 {
    let json_mode = tokens.iter().any(|t| t == "--json");
    let mut command = String::new();
    let result: Result<Output> = async {
        if tokens.is_empty() {
            return Err(usage("COMMAND_UNKNOWN", ""));
        }
        if matches!(tokens[0].as_str(), "--help" | "-h") {
            return Ok(Output::Raw(help("")?));
        }
        if tokens[0] == "help" {
            command = "help".into();
            let topic = tokens[1..]
                .iter()
                .filter(|t| !matches!(t.as_str(), "--json" | "--no-color"))
                .map(|s| s.as_str())
                .collect::<Vec<_>>();
            let topic = match topic.as_slice() {
                [] => String::new(),
                [one] => canonical(one).into(),
                [one, two] => format!("{} {}", canonical(one), sub_alias(two)),
                _ => return Err(usage("HELP_TOPIC_UNKNOWN", "")),
            };
            return Ok(Output::Raw(help(&topic)?));
        }
        command = canonical(&tokens[0]).into();
        let mut start = 1;
        if group(&command) {
            if tokens.len() == 1
                || matches!(
                    tokens[1].as_str(),
                    "help" | "-h" | "--help" | "--json" | "--no-color"
                )
            {
                if command == "diag"
                    && tokens.len() > 1
                    && !matches!(tokens[1].as_str(), "help" | "-h" | "--help")
                {
                    return Err(usage("DIAG_SUBCOMMAND_MISSING", "diag"));
                }
                return Ok(Output::Raw(help(&command)?));
            }
            let family = command.clone();
            command = format!("{family} {}", sub_alias(&tokens[1]));
            start = 2;
            if !COMMANDS.iter().any(|(p, _)| *p == command) {
                return Err(usage(
                    &format!("{}_SUBCOMMAND_UNKNOWN", family.to_uppercase()),
                    &family,
                ));
            }
        }
        if !COMMANDS.iter().any(|(p, _)| *p == command) {
            return Err(fail(
                "COMMAND_UNKNOWN",
                "unknown command",
                "use `zc help` to list supported commands",
                1,
            ));
        }
        if tokens.get(start).is_some_and(|t| t == "help")
            || tokens[start..]
                .iter()
                .any(|t| matches!(t.as_str(), "-h" | "--help"))
        {
            return Ok(Output::Raw(help(&command)?));
        }
        let args = parse(&command, &tokens[start..])?;
        dispatch(&args).await
    }
    .await;
    match result {
        Ok(Output::Raw(text)) => {
            print!("{text}");
            0
        }
        Ok(Output::Silent) => 0,
        Ok(Output::Data(mut data)) => {
            without_nulls(&mut data);
            // The stopped port is an explicit state, not an omitted optional field.
            if command == "status" && data["state"] == "stopped" {
                data["mixed_port"] = Value::Null;
            }
            if json_mode {
                println!(
                    "{}",
                    ascii_json(&json!({"ok":true,"command":command,"data":data}))
                );
            } else {
                render_text(&command, &data);
            }
            0
        }
        Err(error) => {
            let failure = map_error(&command, error);
            if json_mode {
                let mut envelope = json!({"ok":false,"command":command,"error":{"code":failure.code,"message":failure.message,"hint":failure.hint}});
                if let Some(data) = failure.data {
                    envelope["data"] = data;
                }
                without_nulls(&mut envelope);
                println!("{}", ascii_json(&envelope));
            } else {
                if command.is_empty() {
                    eprintln!("Usage: zc <command> [options]");
                }
                eprintln!(
                    "error: {}\nhint: {}\ncode: {}",
                    safe_text(&failure.message),
                    safe_text(&failure.hint),
                    failure.code
                );
                if let Some(data) = failure.data
                    && let Some(errors) = data["config_errors"].as_array()
                {
                    for error in errors {
                        eprintln!(
                            "  {}",
                            safe_text(error.as_str().unwrap_or("invalid configuration"))
                        );
                    }
                }
            }
            failure.exit
        }
    }
}

fn map_error(command: &str, error: anyhow::Error) -> Failure {
    let error = match error.downcast::<Failure>() {
        Ok(f) => return f,
        Err(e) => e,
    };
    let text = format!("{error:#}");
    let default_code = match command {
        "start" => "START_FAILED",
        "restart" => "RESTART_FAILED",
        "reload" => "RELOAD_FAILED",
        "stop" => "STOP_FAILED",
        "status" => "STATUS_FAILED",
        "log" => "LOG_FAILED",
        "doctor" | "diag doctor" => "DIAG_DOCTOR_FAILED",
        "test" | "proxy test" | "profile test" => "PROXY_TEST_FAILED",
        "proxy select" | "profile select" => "PROXY_SELECT_FAILED",
        "proxy list" | "profile list" => "PROXY_CONFIG_LOAD_FAILED",
        "config use" => "CONFIG_SWITCH_FAILED",
        "config override" => "CONFIG_OVERRIDE_FAILED",
        "config dump" => "CONFIG_DUMP_FAILED",
        "config load" => "CONFIG_LOAD_FAILED",
        "config list" => "CONFIG_LIST_FAILED",
        "config update" => "CONFIG_UPDATE_FAILED",
        "config download" => "CONFIG_DOWNLOAD_FAILED",
        "config delete" => "CONFIG_DELETE_FAILED",
        _ => "COMMAND_UNKNOWN",
    };
    let mut code = default_code.to_owned();
    for cause in error.chain() {
        let message = cause.to_string();
        if let Some((candidate, _)) = message.split_once(':')
            && candidate.contains('_')
            && candidate
                .bytes()
                .all(|b| b.is_ascii_uppercase() || b == b'_')
        {
            code = candidate.into();
            break;
        }
    }
    if code.starts_with("RUNTIME_") {
        code = default_code.into();
    }
    if matches!(command, "start" | "restart") {
        let prefix = command.to_uppercase();
        if text.contains("external-controller must") {
            code = format!("{prefix}_EXTERNAL_CONTROLLER_INVALID");
        } else if text.contains("bind-address must") || text.contains("non-loopback bind-address") {
            code = format!("{prefix}_BIND_ADDRESS_INVALID");
        } else if text.contains("unsupported")
            || text.contains("supported classic AEAD")
            || text.contains("proxy-group must be select")
        {
            code = "CONFIG_CAPABILITY_UNSUPPORTED".into();
        } else if code == default_code
            && (text.contains("invalid configuration") || text.contains("configuration must be"))
        {
            code = format!("{prefix}_PREFLIGHT_FAILED");
        }
        if text.contains("previous snapshot restored") {
            code = "RESTART_FAILED_ROLLED_BACK".into();
        }
        if text.contains("rollback failed") {
            code = "RESTART_ROLLBACK_FAILED".into();
        }
    }
    if command == "config override" && code == "OVERRIDE_SCRIPT_NOT_FOUND" {
        code = "CONFIG_OVERRIDE_SCRIPT_NOT_FOUND".into();
    }
    if text.contains("ProfileNotFound") {
        code = "CONFIG_NOT_FOUND".into();
    }
    if text.contains("ProfileNotRuntimeReady") || text.contains("UnsupportedCapability:") {
        code = "CONFIG_CAPABILITY_UNSUPPORTED".into();
    }
    if command == "restart" && code.starts_with("START_") {
        code = code.replacen("START_", "RESTART_", 1);
    }
    if matches!(command, "config load" | "config download" | "config update") {
        let prefix = command.replace(' ', "_").to_uppercase();
        let lower = text.to_lowercase();
        if lower.contains("limit exceeded")
            || text.contains("LimitExceeded")
            || text.contains("AssetTooLarge")
            || lower.contains("provider")
                && (lower.contains("too large") || lower.contains("byte limit"))
        {
            code = format!("{prefix}_LIMIT_EXCEEDED");
        } else if text.contains("SourceTooLarge") || lower.contains("16 mib") {
            code = format!("{prefix}_TOO_LARGE");
        } else if command == "config load"
            && (lower.contains("invalid configuration")
                || lower.contains("utf-8")
                || lower.contains("yaml"))
        {
            code = "CONFIG_LOAD_INVALID".into();
        } else if command == "config update" && text.contains("Conflict") {
            code = "CONFIG_UPDATE_CONFLICT".into();
        }
    }
    let hint=match code.as_str() {
        "CONFIG_CAPABILITY_UNSUPPORTED" if command=="config update"=>"repair the subscription source and retry `zc config update`",
        "CONFIG_CAPABILITY_UNSUPPORTED"=>"retry download without -d; inspect `zc config dump -c <name> --no-override`, then repair the subscription source",
        "START_CONFIG_NOT_SELECTED"|"RESTART_CONFIG_NOT_SELECTED"=>"run `zc config list`, then `zc config use <name>`",
        "CONFIG_NAME_INVALID"=>"use 1-250 UTF-8 bytes, excluding slashes, controls, . and ..",
        "CONFIG_ALREADY_EXISTS"=>"choose another name or run `zc config update`",
        "CONFIG_NOT_FOUND"=>"run `zc config list` and pick an existing config name",
        _=>"check the configuration and permissions; use `zc help` and `zc log --no-follow` for next steps"
    }.into();
    // Foundation errors discard parser snippets, remote bodies and script stderr.
    // Filesystem failures are rendered generically; never expose subscription URLs.
    let message = if code == "CONFIG_NAME_INVALID" {
        "invalid config name".into()
    } else if matches!(command, "config download" | "config update") {
        format!(
            "{} failed; source or authoritative state was not accepted",
            command
        )
    } else {
        text
    };
    Failure {
        code,
        message,
        hint,
        exit: 1,
        data: None,
    }
}

fn render_text(command: &str, data: &Value) {
    match command {
        "version" => println!("zc {}", env!("CARGO_PKG_VERSION")),
        "config list" => {
            println!("Available configs:\n");
            if let Some(items) = data["configs"].as_array() {
                for item in items {
                    println!(
                        "  {} {}",
                        if item["active"] == true { "*" } else { " " },
                        safe_text(item["display"].as_str().unwrap_or(""))
                    );
                }
                if items.is_empty() {
                    println!("  (no config files found)");
                }
            }
        }
        "config use" | "config load" => {
            println!("Config is active; run `zc reload` or `zc restart` to apply it")
        }
        "proxy list" | "profile list" => {
            if let Some(groups) = data["groups"].as_array() {
                for g in groups {
                    println!(
                        "{} ({}) -> {}",
                        safe_text(g["name"].as_str().unwrap_or("")),
                        g["type"].as_str().unwrap_or("select"),
                        safe_text(g["now"].as_str().unwrap_or("(none)"))
                    );
                    if let Some(members) = g["proxies"].as_array() {
                        for m in members {
                            println!("  {}", safe_text(m["name"].as_str().unwrap_or("")));
                        }
                    }
                }
            }
        }
        "status" => {
            println!("Daemon: {}", data["state"].as_str().unwrap_or("stopped"));
            println!(
                "PID: {}",
                data.get("pid")
                    .map(Value::to_string)
                    .unwrap_or("(none)".into())
            );
            println!(
                "Mixed port: {}",
                data.get("mixed_port")
                    .map(Value::to_string)
                    .unwrap_or("(none)".into())
            );
        }
        "doctor" | "diag doctor" | "test" | "proxy test" | "profile test" => {}
        _ => println!("{}: {}", command, ascii_json(data)),
    }
}

async fn dispatch(args: &Args) -> Result<Output> {
    match args.path.as_str() {
        "version" => Ok(Output::Data(json!({"version":env!("CARGO_PKG_VERSION")}))),
        "start" => {
            if !args.flag("--foreground")
                && let Some(current) = daemon::current_prepared().await?
            {
                return Ok(Output::Data(extend(
                    daemon::start(current).await?,
                    json!({"action":"start","state":"running"}),
                )));
            }
            let prepared = service::prepare(args.prepare()).await?;
            if args.flag("--foreground") {
                let address = std::net::SocketAddr::new(
                    service::prepared_config(&prepared)?.bind_address(),
                    prepared.port,
                );
                let foreground = daemon::run_foreground(prepared);
                tokio::pin!(foreground);
                let mut announced = false;
                let mut tick = tokio::time::interval(Duration::from_millis(25));
                loop {
                    tokio::select! {
                        result = &mut foreground => { result?; break; },
                        _ = tick.tick(), if !announced => {
                            if let Ok(state) = daemon::status().await
                                && state["state"] == "running" && state["pid"] == std::process::id() {
                                    eprintln!("Runtime listening on {address} (foreground)");
                                    announced = true;
                                }
                        }
                    }
                }
                Ok(Output::Silent)
            } else {
                Ok(Output::Data(extend(
                    daemon::start(prepared).await?,
                    json!({"action":"start","state":"running"}),
                )))
            }
        }
        "stop" => Ok(Output::Data(extend(
            daemon::stop().await?,
            json!({"action":"stop","state":"stopped"}),
        ))),
        "status" => Ok(Output::Data(daemon::status().await?)),
        "restart" | "reload" => {
            let captured = daemon::capture_restart().await?;
            let current = captured.prepared.clone();
            if args.path == "reload" && current.is_none() {
                bail!("RELOAD_FAILED: daemon is not running");
            }
            let mut options = args.prepare();
            let reuse = args.path == "restart"
                && options.config.is_none()
                && options.override_options.script_path.is_none()
                && options.override_options.args.is_empty();
            let frozen = current.clone();
            if let Some(old) = current {
                if old.invocation.foreground {
                    bail!(
                        "RESTART_INVOCATION_UNTRACKED: foreground daemon must be restarted through its supervisor"
                    );
                }
                if options.config.is_none() {
                    options.config = old.invocation.source_path.or(old.invocation.config_path);
                }
                if options.port.is_none() {
                    options.port = old.invocation.port_override;
                }
                if args.path == "restart" && options.override_options.script_path.is_none() {
                    options.override_options = old.override_options;
                }
            }
            let prepared = if let Some(mut frozen) = frozen.filter(|_| reuse) {
                if let Some(port) = options.port {
                    frozen.port = port;
                    frozen.invocation.port_override = Some(port);
                }
                frozen
            } else {
                service::prepare(options).await?
            };
            let mut data = extend(
                daemon::restart_checked(captured, prepared).await?,
                json!({"action":args.path,"state":"running"}),
            );
            if args.path == "reload" {
                data["applied"] = json!("restart_fallback");
            }
            Ok(Output::Data(data))
        }
        "log" => {
            daemon::log(
                args.value("-n").and_then(|v| v.parse().ok()).unwrap_or(50),
                args.flag("-f") || (!args.flag("--json") && !args.flag("--no-follow")),
                args.flag("--json"),
            )
            .await?;
            Ok(Output::Silent)
        }
        "test" | "proxy test" | "profile test" => diagnose(args, false).await,
        "doctor" | "diag doctor" => diagnose(args, true).await,
        path if path.starts_with("config ") => config_command(args).await,
        _ => proxy_command(args).await,
    }
}

fn profile<'a>(snapshot: &'a store::Snapshot, key: &str) -> Result<&'a store::Profile> {
    snapshot
        .catalog
        .profiles
        .iter()
        .find(|p| p.key == key)
        .context("CONFIG_NOT_FOUND: config not found")
}
fn existing_required() -> Result<Store> {
    service::existing_store()?.context("CONFIG_NOT_FOUND: no managed configs found")
}
fn health_data(store: &Store, receipt: Option<&store::Receipt>) -> Value {
    let mirror_error = refresh_mirror(store).is_err();
    json!({"durability_uncertain":store.durability_uncertain() || receipt.is_some_and(|r|r.durability_error.is_some()),"mirror_out_of_sync":mirror_error})
}
fn extend(mut data: Value, extra: Value) -> Value {
    if let (Some(a), Some(b)) = (data.as_object_mut(), extra.as_object()) {
        a.extend(b.clone());
    }
    data
}

struct MirrorDocuments {
    files: BTreeMap<String, Vec<u8>>,
    metadata: Vec<u8>,
}

fn mirror_documents(store: &Store, snapshot: &store::Snapshot) -> Result<MirrorDocuments> {
    let mut files = BTreeMap::new();
    let mut metadata = serde_json::Map::new();
    for profile in &snapshot.catalog.profiles {
        let view = store.read_bundle(&profile.key, &profile.head)?;
        let name = format!("{}.yaml", profile.key);
        ensure!(name.len() <= 255, "mirror filename too long");
        for (name, bytes) in std::iter::once((name, view.bundle.effective_source().to_vec())).chain(
            view.bundle
                .assets()
                .iter()
                .map(|(p, a)| (p.clone(), a.bytes.clone())),
        ) {
            if let Some(previous) = files.insert(name, bytes.clone()) {
                ensure!(previous == bytes, "conflicting mirror asset path");
            }
        }
        let mut entry = json!({"url":view.metadata.url,"filename":view.metadata.filename,"params":view.metadata.params.iter().map(|p|(p.key.clone(),json!(p.value))).collect::<serde_json::Map<_,_>>(),"selections":profile.desired.selections.iter().map(|s|(s.group.clone(),json!(s.proxy))).collect::<serde_json::Map<_,_>>()});
        if let Some(frozen) = view.frozen_override {
            entry["override_script"] = json!(frozen.script_name);
        }
        without_nulls(&mut entry);
        metadata.insert(profile.key.clone(), entry);
    }
    let mut metadata =
        json!({"active":snapshot.catalog.active.as_ref().map(|a|&a.key),"configs":metadata});
    without_nulls(&mut metadata);
    Ok(MirrorDocuments {
        files,
        metadata: serde_json::to_vec(&metadata)?,
    })
}

fn verify_mirror_tree(
    root: &Path,
    prefix: &str,
    files: &BTreeMap<String, Vec<u8>>,
    depth: usize,
) -> Result<()> {
    ensure!(depth <= 64, "mirror directory depth exceeded");
    for entry in std::fs::read_dir(root)? {
        let entry = entry?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| anyhow!("invalid mirror name"))?;
        let relative = format!("{prefix}{name}");
        let kind = entry.file_type()?;
        if kind.is_file() {
            ensure!(files.contains_key(&relative), "unexpected mirror file");
        } else {
            let prefix = format!("{relative}/");
            ensure!(
                kind.is_dir() && files.keys().any(|path| path.starts_with(&prefix)),
                "unexpected mirror path"
            );
            verify_mirror_tree(&entry.path(), &prefix, files, depth + 1)?;
        }
    }
    Ok(())
}

fn mirror_in_sync(store: &Store, snapshot: &store::Snapshot) -> bool {
    (|| -> Result<()> {
        if snapshot.token.format == store::StateFormat::Missing {
            return Ok(());
        }
        let MirrorDocuments { files, metadata } = mirror_documents(store, snapshot)?;
        let root = SecureDir::open(store.root_path())?;
        let actual: Value = serde_json::from_slice(&root.read("meta.json", 4 * 1024 * 1024)?)?;
        ensure!(
            actual == serde_json::from_slice::<Value>(&metadata)?,
            "mirror metadata differs"
        );
        verify_mirror_tree(&store.root_path().join("configs"), "", &files, 0)?;
        for (path, bytes) in files {
            let components = path.split('/').collect::<Vec<_>>();
            let mut dir = root.child("configs", false)?;
            for component in &components[..components.len() - 1] {
                dir = dir.child(component, false)?;
            }
            ensure!(
                dir.read(components[components.len() - 1], store::FILE_LIMIT)? == bytes,
                "mirror source differs"
            );
        }
        Ok(())
    })()
    .is_ok()
}

/// The mirror is derived; a failed refresh cannot turn a committed catalog into failure.
fn refresh_mirror(store: &Store) -> Result<()> {
    let root = SecureDir::open(store.root_path())?;
    let _lock = root.lock("legacy-mirror.lock", Duration::from_secs(5))?;
    let snapshot = store.load()?;
    if snapshot.token.format == store::StateFormat::Missing {
        return Ok(());
    }
    let MirrorDocuments { files, metadata } = mirror_documents(store, &snapshot)?;
    let configs = root.child("configs", true)?;
    for (path, bytes) in &files {
        let components = path.split('/').collect::<Vec<_>>();
        let mut dir = root.child("configs", false)?;
        for component in &components[..components.len() - 1] {
            dir = dir.child(component, true)?;
        }
        ensure!(
            dir.atomic_write(components[components.len() - 1], bytes)?
                .durability_error
                .is_none(),
            "mirror sync failed"
        );
    }
    // Do not follow unexpected directories or symlinks when pruning stale mirrors.
    for entry in std::fs::read_dir(store.root_path().join("configs"))? {
        let entry = entry?;
        let name = entry
            .file_name()
            .into_string()
            .map_err(|_| anyhow!("invalid mirror name"))?;
        if !files.contains_key(&name) && !files.keys().any(|p| p.starts_with(&format!("{name}/"))) {
            ensure!(
                entry.file_type()?.is_file(),
                "mirror contains an unexpected path"
            );
            configs.remove_file(&name)?;
        }
    }
    verify_mirror_tree(&store.root_path().join("configs"), "", &files, 0)?;
    ensure!(
        root.atomic_write("meta.json", &metadata)?
            .durability_error
            .is_none(),
        "mirror sync failed"
    );
    ensure!(
        store.load()?.token == snapshot.token,
        "mirror authority changed during refresh"
    );
    Ok(())
}

async fn download(url: &str, command: &str) -> Result<Vec<u8>> {
    let prefix = command.replace(' ', "_").to_uppercase();
    let parsed =
        reqwest::Url::parse(url).map_err(|_| anyhow!("{prefix}_FAILED: invalid HTTP URL"))?;
    ensure!(
        matches!(parsed.scheme(), "http" | "https") && parsed.host_str().is_some(),
        "{prefix}_FAILED: invalid HTTP URL"
    );
    let client = reqwest::Client::builder()
        .no_proxy()
        .timeout(Duration::from_secs(30))
        .redirect(reqwest::redirect::Policy::limited(5))
        .build()?;
    let mut response = client.get(parsed).send().await.map_err(|e| {
        anyhow!(
            "{}_{}: subscription request failed",
            prefix,
            if e.is_timeout() { "TIMEOUT" } else { "FAILED" }
        )
    })?;
    ensure!(
        response.status().is_success(),
        "{prefix}_FAILED: subscription server returned an unsuccessful status"
    );
    ensure!(
        response
            .content_length()
            .is_none_or(|n| n <= store::FILE_LIMIT as u64),
        "{prefix}_TOO_LARGE: source exceeds 16 MiB"
    );
    let mut bytes = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| {
        anyhow!(
            "{}_{}: subscription response failed",
            prefix,
            if e.is_timeout() { "TIMEOUT" } else { "FAILED" }
        )
    })? {
        ensure!(
            chunk.len() <= store::FILE_LIMIT - bytes.len(),
            "{prefix}_TOO_LARGE: source exceeds 16 MiB"
        );
        bytes.extend_from_slice(&chunk);
    }
    Ok(bytes)
}

async fn config_command(args: &Args) -> Result<Output> {
    let data = match args.path.as_str() {
        "config list" => {
            let Some(store) = service::existing_store()? else {
                return Ok(Output::Data(
                    json!({"configs":[],"durability_uncertain":false,"mirror_out_of_sync":false}),
                ));
            };
            let snapshot = store.load()?;
            let configs=snapshot.catalog.profiles.iter().map(|p| {let view=store.read_bundle(&p.key,&p.head)?;Ok(json!({"name":p.key,"display":view.metadata.filename.as_deref().unwrap_or(&p.key),"active":snapshot.catalog.active.as_ref().is_some_and(|a|a.key==p.key)}))}).collect::<Result<Vec<_>>>()?;
            // Listing never mutates the catalog. Mirrors are advisory, not read inputs.
            json!({"configs":configs,"active":snapshot.catalog.active.as_ref().map(|a|&a.key),"durability_uncertain":snapshot.durability_uncertain,"mirror_out_of_sync":!mirror_in_sync(&store,&snapshot)})
        }
        "config load" => {
            let path = Path::new(&args.positionals[0]);
            let name =
                service::validate_name(path.file_name().and_then(|s| s.to_str()).unwrap_or(""))?;
            let bytes = service::read_source(path)?;
            let bundle = Bundle::capture(path).map_err(|error| {
                let message = format!("{error:#}");
                let semantic = config::parse_document(std::str::from_utf8(&bytes).unwrap_or("")).is_ok()
                    && !message.to_lowercase().contains("limit")
                    && !message.contains("TooLarge")
                    && ["proxy", "group", "Shadowsocks", "Trojan", "mode must", "rule references", "rule payload", "unsupported"].iter().any(|word| message.contains(word));
                if semantic {
                    let end = message.char_indices().map(|(i,_)|i).take_while(|i|*i<=512).last().unwrap_or(0);
                    let truncated = message.len() > 512;
                    Failure { code: "CONFIG_LOAD_INVALID".into(), message: "local configuration is invalid".into(), hint: "fix the listed configuration errors and retry".into(), exit: 1,
                        data: Some(json!({"config_errors":[if truncated {&message[..end]} else {&message}], "config_warnings":[], "config_diagnostics_truncated":truncated})) }.into()
                } else { error.context("invalid configuration") }
            })?;
            ensure!(
                bundle.catalog_ready()?,
                "CONFIG_CAPABILITY_UNSUPPORTED: config uses an unsupported runtime capability"
            );
            let store = service::open_store()?;
            let snapshot = store.load()?;
            ensure!(
                !snapshot.catalog.profiles.iter().any(|p| p.key == name),
                "CONFIG_ALREADY_EXISTS: a config with this name already exists"
            );
            let receipt = store.publish(
                &snapshot.token,
                name,
                None,
                &bundle,
                Metadata {
                    filename: Some(name.into()),
                    ..Default::default()
                },
                true,
            )?;
            let revision = store.get(name)?.head;
            extend(
                json!({"action":"config_load","name":name,"revision":revision,"active":true,"applied":false}),
                health_data(&store, Some(&receipt)),
            )
        }
        "config download" => {
            let generated = format!(
                "config-{}",
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)?
                    .as_secs()
            );
            let name = service::validate_name(args.value("-n").unwrap_or(&generated))?;
            // Validate the name and current authority before any network activity.
            let existing = service::existing_store()?;
            if let Some(store) = &existing {
                let snapshot = store.load()?;
                ensure!(
                    !snapshot.catalog.profiles.iter().any(|p| p.key == name),
                    "CONFIG_ALREADY_EXISTS: a config with this name already exists"
                );
            }
            let bytes = download(&args.positionals[0], &args.path).await?;
            let bundle = Bundle::from_memory(&bytes, None, BTreeMap::new())?;
            let ready = bundle.catalog_ready()?;
            ensure!(
                !args.flag("-d") || ready,
                "CONFIG_CAPABILITY_UNSUPPORTED: config uses an unsupported runtime capability"
            );
            let store = if let Some(store) = existing {
                store
            } else {
                service::open_store()?
            };
            let snapshot = store.load()?;
            ensure!(
                !snapshot.catalog.profiles.iter().any(|p| p.key == name),
                "CONFIG_ALREADY_EXISTS: a config with this name already exists"
            );
            let activate = args.flag("-d") || snapshot.catalog.active.is_none() && ready;
            let receipt = store.publish(
                &snapshot.token,
                name,
                None,
                &bundle,
                Metadata {
                    url: Some(args.positionals[0].clone()),
                    filename: Some(name.into()),
                    ..Default::default()
                },
                activate,
            )?;
            let health = health_data(&store, Some(&receipt));
            let path = if health["mirror_out_of_sync"] == false {
                Some(
                    store
                        .root_path()
                        .join("configs")
                        .join(format!("{name}.yaml"))
                        .to_string_lossy()
                        .into_owned(),
                )
            } else {
                None
            };
            extend(
                json!({"name":name,"revision":store.get(name)?.head,"active":activate,"set_default":activate,"path":path,"applied":false}),
                health,
            )
        }
        "config use" => {
            let name = service::key(&args.positionals[0]);
            let store = existing_required()?;
            let snapshot = store.load()?;
            let p = profile(&snapshot, name)?;
            let bundle = store.read_bundle(name, &p.head)?.bundle;
            ensure!(
                bundle.catalog_ready()?,
                "CONFIG_CAPABILITY_UNSUPPORTED: config uses an unsupported runtime capability"
            );
            let receipt = store.activate(&snapshot.token, Some(name))?;
            extend(
                json!({"name":name,"active":name,"applied":false}),
                health_data(&store, Some(&receipt)),
            )
        }
        "config delete" => {
            let name = service::key(&args.positionals[0]);
            let store = existing_required()?;
            let snapshot = store.load()?;
            let p = profile(&snapshot, name)?;
            let receipt = store.delete(&snapshot.token, name, &p.head)?;
            extend(
                json!({"action":"config_delete","name":name,"deleted":true,"was_active":snapshot.catalog.active.as_ref().is_some_and(|a|a.key==name)}),
                health_data(&store, Some(&receipt)),
            )
        }
        "config dump" => return dump(args).await,
        "config update" => return update(args).await,
        "config override" => return persisted_override(args).await,
        _ => unreachable!(),
    };
    Ok(Output::Data(data))
}

async fn dump(args: &Args) -> Result<Output> {
    let loaded = service::load(args.value("-c"))?;
    let raw = loaded.bundle.source();
    if args.flag("--no-override") && !args.flag("--json") && !loaded.bundle.catalog_ready()? {
        let text = std::str::from_utf8(raw)?;
        if std::io::stdout().is_terminal() && text.chars().any(|c| (c.is_control()&&c!='\n')||matches!(c,'\u{061c}'|'\u{200e}'|'\u{200f}'|'\u{2028}'..='\u{202e}'|'\u{2066}'..='\u{2069}'|'\u{feff}')) {bail!("CONFIG_DUMP_UNSAFE_TERMINAL: redirect stdout to preserve raw bytes");}
        return Ok(Output::Raw(text.into()));
    }
    ensure!(
        loaded.bundle.catalog_ready()?,
        "CONFIG_DUMP_FAILED: config is not runtime-ready; use --no-override without --json to recover the source"
    );
    let mut source = if args.flag("--no-override") {
        raw.to_vec()
    } else {
        loaded.bundle.effective_source().to_vec()
    };
    if !args.flag("--no-override")
        && let Some(script) = &args.overrides.script_path
    {
        let result = override_script::execute(&override_script::Invocation {
            command: "config.dump".into(),
            config_path: loaded.source_path.unwrap_or_default(),
            script_path: script.clone(),
            timeout_ms: args.overrides.timeout_ms,
            args: args.overrides.args.clone(),
        })
        .await?;
        source = override_script::materialize_source(&source, &result.patch_bytes)?;
        let materialized = Bundle::from_memory(&source, None, loaded.bundle.assets().clone())
            .context("OVERRIDE_MERGE_FAILED: override output failed configuration validation")?;
        ensure!(
            materialized.catalog_ready()?,
            "CONFIG_CAPABILITY_UNSUPPORTED: override uses an unsupported runtime capability"
        );
    }
    let text = if args.flag("--json") {
        ascii_json(&serde_json::from_str(&override_script::dump_config_json(
            &source,
        )?)?)
    } else {
        override_script::dump_config_yaml(&source)?
    };
    Ok(Output::Raw(format!("{}\n", text.trim_end_matches('\n'))))
}

fn frozen(execution: override_script::ExecutedOverride) -> FrozenOverride {
    FrozenOverride {
        script_name: execution.script.name,
        script_bytes: execution.script.bytes,
        command: execution.invocation.command,
        config_path: Some(execution.invocation.config_path),
        timeout_ms: execution.invocation.timeout_ms,
        args: execution
            .invocation
            .args
            .into_iter()
            .map(|a| store::Param {
                key: a.key,
                value: a.value,
            })
            .collect(),
        patch_bytes: execution.patch_bytes,
    }
}
async fn apply_revision(
    captured: Result<daemon::RestartCapture>,
    old: &ActiveIdentity,
    new: &ActiveIdentity,
    args: &Args,
) -> Result<bool> {
    let captured = captured?;
    let Some(current) = captured.prepared.clone() else {
        return Ok(false);
    };
    if current.identity.as_ref() != Some(old) {
        return Ok(false);
    }
    if current.invocation.foreground {
        bail!("foreground daemon must be restarted through its supervisor");
    }
    let store = existing_required()?;
    let snapshot = store.load()?;
    let p = profile(&snapshot, &new.key)?;
    ensure!(p.head == new.revision, "config changed before live apply");
    let loaded = service::Loaded {
        bundle: store.read_bundle(&new.key, &new.revision)?.bundle,
        identity: Some(new.clone()),
        desired: p.desired.clone(),
        source_path: Some(new.key.clone()),
    };
    let prepared = service::prepare_loaded(
        loaded,
        PrepareOptions {
            config: Some(new.key.clone()),
            port: current.invocation.port_override,
            foreground: false,
            command: args.path.clone(),
            override_options: current.override_options,
        },
    )
    .await?;
    daemon::restart_checked(captured, prepared).await?;
    Ok(true)
}

async fn update(args: &Args) -> Result<Output> {
    let store = service::existing_store()?.ok_or_else(|| {
        if args.positionals.is_empty() {
            anyhow!("CONFIG_UPDATE_NAME_REQUIRED: no config name given and no active config")
        } else {
            anyhow!("CONFIG_NOT_FOUND: config not found")
        }
    })?;
    let snapshot = store.load()?;
    let name = args
        .positionals
        .first()
        .map(|s| service::key(s))
        .or_else(|| snapshot.catalog.active.as_ref().map(|a| a.key.as_str()))
        .context("CONFIG_UPDATE_NAME_REQUIRED: no config name given and no active config")?;
    let p = profile(&snapshot, name)?;
    let view = store.read_bundle(name, &p.head)?;
    let url = view
        .metadata
        .url
        .as_deref()
        .context("CONFIG_UPDATE_NO_SUBSCRIPTION: no subscription URL recorded")?;
    let captured = daemon::capture_restart().await;
    let source = download(url, &args.path).await?;
    let rematerialized = if let Some(previous) = &view.frozen_override {
        let execution = override_script::execute_bytes(
            &override_script::Script {
                name: previous.script_name.clone(),
                bytes: previous.script_bytes.clone(),
            },
            &override_script::Invocation {
                command: previous.command.clone(),
                config_path: previous.config_path.clone().unwrap_or_default(),
                script_path: previous.script_name.clone(),
                timeout_ms: previous.timeout_ms,
                args: previous
                    .args
                    .iter()
                    .map(|a| override_script::OverrideArg {
                        key: a.key.clone(),
                        value: a.value.clone(),
                    })
                    .collect(),
            },
        )
        .await?;
        Some(frozen(execution))
    } else {
        None
    };
    let effective = rematerialized
        .as_ref()
        .map(|f| override_script::materialize_source(&source, &f.patch_bytes))
        .transpose()?;
    let bundle = Bundle::from_memory(&source, effective.as_deref(), view.bundle.assets().clone())?;
    let active = snapshot
        .catalog
        .active
        .as_ref()
        .is_some_and(|a| a.key == name);
    ensure!(
        !active || bundle.catalog_ready()?,
        "CONFIG_CAPABILITY_UNSUPPORTED: replacement config is not runtime-ready"
    );
    let receipt = store.publish_frozen(
        &snapshot.token,
        name,
        Some(&p.head),
        &bundle,
        view.metadata,
        rematerialized,
        false,
    )?;
    let identity = ActiveIdentity {
        key: name.into(),
        revision: store.get(name)?.head,
    };
    let health = health_data(&store, Some(&receipt));
    let applied=apply_revision(captured, &ActiveIdentity{key:name.into(),revision:p.head.clone()},&identity,args).await.map_err(|e| if e.to_string().starts_with("RESTART_CONTENDED:") { e } else { anyhow!("CONFIG_UPDATE_APPLY_FAILED: revision persisted but live apply failed; inspect status and restart; {e:#}") })?;
    Ok(Output::Data(extend(
        json!({"name":name,"applied":applied,"apply_result":if applied {Some(if args.value("--apply")==Some("restart"){"restart"}else{"restart_fallback"})}else{None}}),
        health,
    )))
}

async fn persisted_override(args: &Args) -> Result<Output> {
    let store = service::existing_store()?;
    if args.positionals.is_empty() && !args.flag("--clear") && store.is_none() {
        return Ok(Output::Data(
            json!({"action":"config_override_get","profile":"(none)","enabled":false,"durability_uncertain":false,"mirror_out_of_sync":false}),
        ));
    }
    let store = store.context("CONFIG_OVERRIDE_NO_ACTIVE: no active config found for override")?;
    let snapshot = store.load()?;
    let Some(active) = &snapshot.catalog.active else {
        if args.positionals.is_empty() && !args.flag("--clear") {
            return Ok(Output::Data(
                json!({"action":"config_override_get","profile":"(none)","enabled":false,"durability_uncertain":snapshot.durability_uncertain,"mirror_out_of_sync":false}),
            ));
        }
        bail!("CONFIG_OVERRIDE_NO_ACTIVE: no active config found for override");
    };
    let view = store.read_bundle(&active.key, &active.revision)?;
    if args.positionals.is_empty() && !args.flag("--clear") {
        return Ok(Output::Data(
            json!({"action":"config_override_get","profile":active.key,"enabled":view.frozen_override.is_some(),"script":view.frozen_override.map(|f|f.script_name),"durability_uncertain":snapshot.durability_uncertain,"mirror_out_of_sync":!mirror_in_sync(&store,&snapshot)}),
        ));
    }
    let had_override = view.frozen_override.is_some();
    if args.flag("--clear") && !had_override {
        return Ok(Output::Data(
            json!({"action":"config_override_clear","profile":active.key,"enabled":false,"cleared":false,"durability_uncertain":snapshot.durability_uncertain,"mirror_out_of_sync":!mirror_in_sync(&store,&snapshot)}),
        ));
    }
    let captured = daemon::capture_restart().await;
    let mut available = view.bundle.assets().clone();
    let frozen = if let Some(script) = args.positionals.first() {
        let invocation = override_script::Invocation {
            command: "config.override".into(),
            script_path: std::path::absolute(script)?.to_string_lossy().into_owned(),
            ..Default::default()
        };
        Some(frozen(override_script::execute(&invocation).await?))
    } else {
        None
    };
    let effective = frozen
        .as_ref()
        .map(|f| override_script::materialize_source(view.bundle.source(), &f.patch_bytes))
        .transpose()?;
    if let (Some(script), Some(effective)) = (args.positionals.first(), &effective) {
        let source = std::str::from_utf8(effective)?;
        let doc = config::parse_document(source)?;
        let needs_capture = doc
            .get("rule-providers")
            .and_then(Value::as_object)
            .is_some_and(|p| {
                p.values().any(|v| {
                    v["type"] == "file"
                        && v["path"]
                            .as_str()
                            .is_some_and(|p| !available.contains_key(p))
                })
            });
        if needs_capture {
            for (name, bytes) in config::capture_file_assets(source, &service::source_root(script))?
            {
                available.entry(name.clone()).or_insert(store::Asset {
                    canonical_relative_target: name,
                    bytes,
                });
            }
        }
    }
    let bundle = Bundle::from_memory(view.bundle.source(), effective.as_deref(), available)?;
    ensure!(
        bundle.catalog_ready()?,
        "CONFIG_CAPABILITY_UNSUPPORTED: override is not runtime-ready"
    );
    let receipt = store.publish_frozen(
        &snapshot.token,
        &active.key,
        Some(&active.revision),
        &bundle,
        view.metadata,
        frozen,
        false,
    )?;
    let new = ActiveIdentity {
        key: active.key.clone(),
        revision: store.get(&active.key)?.head,
    };
    let health = health_data(&store, Some(&receipt));
    let applied=apply_revision(captured, active,&new,args).await.map_err(|e| if e.to_string().starts_with("RESTART_CONTENDED:") { e } else { anyhow!("CONFIG_OVERRIDE_APPLY_FAILED: override persisted but live apply failed; restart through the supervisor if applicable; {e:#}") })?;
    Ok(Output::Data(extend(
        json!({"action":if args.flag("--clear"){"config_override_clear"}else{"config_override_set"},"profile":active.key,"enabled":!args.flag("--clear"),"cleared":if args.flag("--clear"){Some(had_override)}else{None},"script":args.positionals.first(),"applied":applied}),
        health,
    )))
}

fn groups(config: &Config) -> Vec<Value> {
    let mut groups = Vec::new();
    for key in ["proxies", "proxy-groups"] {
        if let Some(items) = config.document()[key].as_array() {
            for item in items {
                if item["type"] == "select" {
                    groups.push(item.clone());
                }
            }
        }
    }
    groups
}
async fn proxy_command(args: &Args) -> Result<Output> {
    let prepared = service::prepare(args.prepare())
        .await
        .map_err(|e| anyhow!("PROXY_CONFIG_LOAD_FAILED: {e:#}"))?;
    let config = service::prepared_config(&prepared)?;
    let groups = groups(&config);
    if args.path.ends_with(" list") {
        let selected = config.selected();
        let groups=groups.iter().map(|g| {
            let members=g["proxies"].as_array().into_iter().flatten().map(|m| {
                let name=m.as_str().unwrap_or("");
                let kind=if name=="DIRECT" {"direct"}else if name=="REJECT"{"reject"}else if groups.iter().any(|g|g["name"]==name){"select"}else{config.document()["proxies"].as_array().and_then(|p|p.iter().find(|p|p["name"]==name)).and_then(|p|p["type"].as_str()).unwrap_or("unknown")};
                json!({"name":name,"type":kind})
            }).collect::<Vec<_>>();
            json!({"name":g["name"],"type":g["type"],"now":g["name"].as_str().and_then(|n|selected.get(n)),"proxies":members})
        }).collect::<Vec<_>>();
        return Ok(Output::Data(
            json!({"stats":{"group_count":groups.len(),"proxy_count":config.proxies().len().saturating_sub(2)},"groups":groups}),
        ));
    }
    let group = if let Some(name) = args.value("-g") {
        groups
            .iter()
            .find(|g| g["name"] == name)
            .ok_or_else(|| anyhow!("PROXY_GROUP_NOT_FOUND: proxy group not found"))?
    } else {
        groups
            .first()
            .context("PROXY_SELECT_GROUP_MISSING: no select-type proxy group found")?
    };
    let name = group["name"].as_str().context("invalid group name")?;
    let choices = group["proxies"]
        .as_array()
        .context("invalid group members")?;
    let mut proxy = args.value("-p").map(str::to_owned);
    if proxy.is_none() {
        if args.flag("--json") {
            return Ok(Output::Data(
                json!({"action":"proxy_select","group":name,"choices":choices}),
            ));
        }
        if !std::io::stdin().is_terminal() {
            return Err(fail(
                "PROXY_SELECT_NOT_INTERACTIVE",
                "interactive selection requires a TTY on stdin",
                "use `zc proxy select -g <group> -p <proxy>`",
                2,
            ));
        }
        for (i, choice) in choices.iter().enumerate() {
            eprintln!("{}: {}", i + 1, safe_text(choice.as_str().unwrap_or("")));
        }
        eprint!("Select a number (q to cancel): ");
        std::io::stderr().flush()?;
        let mut line = String::new();
        std::io::stdin().read_line(&mut line)?;
        if matches!(line.trim(), "" | "q" | "\u{1b}") {
            return Ok(Output::Silent);
        }
        proxy = line
            .trim()
            .parse::<usize>()
            .ok()
            .and_then(|i| i.checked_sub(1))
            .and_then(|i| choices.get(i))
            .and_then(Value::as_str)
            .map(str::to_owned);
    }
    let proxy = proxy.context("PROXY_NOT_FOUND: proxy not found in group")?;
    ensure!(
        choices.iter().any(|p| p == &proxy),
        "PROXY_NOT_FOUND: proxy not found in group"
    );
    let identity=prepared.identity.context("PROXY_SELECTION_MANAGED_CONFIG_REQUIRED: import the config with `zc config load <path>` first")?;
    let store = existing_required()?;
    let snapshot = store.load()?;
    let profile = profile(&snapshot, &identity.key)?;
    ensure!(
        profile.head == identity.revision,
        "PROXY_SELECT_FAILED: config changed during selection"
    );
    let mut selections = service::reconcile_selections(&config, &profile.desired.selections);
    selections.retain(|s| s.group != name);
    selections.push(Selection {
        group: name.into(),
        proxy: proxy.clone(),
    });
    let receipt = store.select(
        &snapshot.token,
        &identity.key,
        &identity.revision,
        profile.desired.generation,
        selections.clone(),
    )?;
    let applied =
        match daemon::apply_selection(&identity, profile.desired.generation + 1, &selections).await
        {
            Ok(applied) => applied,
            Err(_) => {
                eprintln!(
                    "Selection saved only; the daemon identity or controller could not be verified"
                );
                false
            }
        };
    Ok(Output::Data(extend(
        json!({"action":"proxy_select","group":name,"proxy":proxy,"state":"selected","applied":applied}),
        health_data(&store, Some(&receipt)),
    )))
}

async fn tcp_probe(address: std::net::SocketAddr, timeout: Duration) -> bool {
    matches!(
        tokio::time::timeout(timeout, tokio::net::TcpStream::connect(address)).await,
        Ok(Ok(_))
    )
}
/// Public probe seam for real local tests; the command retains 1.1.1.1:443.
pub async fn doctor_diagnostics(
    options: PrepareOptions,
    state: &Value,
    network_target: std::net::SocketAddr,
) -> Result<Value> {
    let diagnostics = service::diagnose_config(&options).await?;
    let running = state["state"] == "running";
    let port = if running {
        state["mixed_port"]
            .as_u64()
            .and_then(|p| u16::try_from(p).ok())
            .context("running daemon has no mixed port")?
    } else {
        options.port.unwrap_or(7899)
    };
    let listening = tcp_probe(([127, 0, 0, 1], port).into(), Duration::from_millis(250)).await;
    let network = tcp_probe(network_target, Duration::from_millis(200)).await;
    let valid = !diagnostics.has_errors;
    Ok(
        json!({"action":"doctor","version":format!("zc v{}",env!("CARGO_PKG_VERSION")),"config_path":options.config.as_deref().unwrap_or("(default)"),"config_source":if options.config.is_some(){"custom"}else{"default"},"config_ok":valid,"daemon_running":running,"daemon_pid":state.get("pid"),"daemon_uptime_seconds":state.get("uptime_seconds"),"proxy_reachable":listening,"network_ok":network,"ports":[{"label":"mixed","port":port,"listening":listening}],"config_errors":diagnostics.errors,"config_warnings":diagnostics.warnings,"config_diagnostics_truncated":diagnostics.truncated,"migration_hints":diagnostics.migration_hints,"checks":[{"name":"config","ok":valid,"detail":if valid{"config parsed and validated"}else{"config invalid (see config_errors)"}},{"name":"connection","ok":!running||listening,"detail":if !running{"daemon stopped; connection check not gating"}else if listening{"proxy port reachable"}else{"daemon running but no configured proxy port is listening"}}]}),
    )
}

fn bounded_diagnostic(message: &str) -> (String, bool) {
    let mut output = String::new();
    for ch in message.chars() {
        let ch = if ch.is_control() { ' ' } else { ch };
        if output.len() + ch.len_utf8() > 512 {
            return (output, true);
        }
        output.push(ch);
    }
    (output, false)
}

/// Text and JSON use the same bounded diagnostic messages and gating facts.
pub fn doctor_report(data: &Value) -> String {
    let mut report = format!(
        "Config: {}\nDaemon: {}\nPID: {}\nPort: {} {}\nConnection: {}\n",
        if data["config_ok"] == true {
            "OK valid"
        } else {
            "invalid"
        },
        if data["daemon_running"] == true {
            "running"
        } else {
            "stopped"
        },
        data.get("daemon_pid")
            .filter(|v| !v.is_null())
            .map(Value::to_string)
            .unwrap_or("(none)".into()),
        data["ports"][0]["port"],
        if data["ports"][0]["listening"] == true {
            "listening"
        } else {
            "not listening"
        },
        if data["checks"][1]["ok"] == true {
            "OK"
        } else {
            "failed"
        }
    );
    for field in ["config_errors", "config_warnings", "migration_hints"] {
        for message in data[field]
            .as_array()
            .into_iter()
            .flatten()
            .filter_map(Value::as_str)
        {
            report.push_str("  ");
            report.push_str(message);
            report.push('\n');
        }
    }
    if data["config_diagnostics_truncated"] == true {
        report.push_str("  Configuration diagnostics truncated\n");
    }
    report
}

/// Probe an explicit real HTTP target using the command's proxy client. Tests
/// supply local URLs; no CLI or environment target override is introduced.
pub async fn diagnostic_target_probe(client: &reqwest::Client, name: &str, url: &str) -> Value {
    let geo = name == "IP/Location";
    let failure =
        |reason: &str| json!({"name":name,"ok":false,"reason":if geo {"no response"}else{reason}});
    let request_error = |error: reqwest::Error| {
        failure(if error.is_timeout() {
            "Timeout"
        } else if error.is_connect() {
            "TCP connect failure"
        } else {
            "Unknown failure"
        })
    };
    let start = std::time::Instant::now();
    let mut response = match client
        .get(url)
        .timeout(Duration::from_secs(if geo { 90 } else { 5 }))
        .send()
        .await
    {
        Ok(response) => response,
        Err(error) => return request_error(error),
    };
    if response.status().as_u16() == 502 {
        return failure("TCP connect failure");
    }
    let mut body = Vec::new();
    loop {
        match response.chunk().await {
            Ok(Some(chunk)) if geo => {
                if chunk.len() > (1024 * 1024usize).saturating_sub(body.len()) {
                    return failure("Unknown failure");
                }
                body.extend_from_slice(&chunk);
            }
            Ok(Some(_)) => (),
            Ok(None) => break,
            Err(error) => return request_error(error),
        }
    }
    if geo {
        // Zig's getIpGeoInfo uses "unknown" for a successful response without a
        // query value. Geo results have an IP field, not a latency measurement.
        let value = serde_json::from_slice::<Value>(&body).ok();
        let ip = value
            .as_ref()
            .and_then(|value| value["query"].as_str())
            .unwrap_or("unknown");
        json!({"name":name,"ok":true,"ip":ip})
    } else {
        json!({"name":name,"ok":true,"latency_ms":start.elapsed().as_millis() as u64})
    }
}

pub fn diagnostic_target_report(target: &Value) -> String {
    let name = target["name"].as_str().unwrap_or("target");
    if let Some(ip) = target["ip"].as_str() {
        let (ip, truncated) = bounded_diagnostic(ip);
        format!(
            "{name}: {ip}{}",
            if truncated { " (truncated)" } else { "" }
        )
    } else if target["ok"] == true {
        format!("{name}: OK {} ms", target["latency_ms"])
    } else {
        format!("{name}: {}", target["reason"].as_str().unwrap_or("failed"))
    }
}

fn diagnostic_load_error(error: anyhow::Error, args: &Args, doctor: bool) -> anyhow::Error {
    if args.overrides.script_path.is_some()
        && error
            .chain()
            .any(|cause| cause.to_string().starts_with("OVERRIDE_"))
    {
        return error;
    }
    let capability = error.chain().any(|cause| {
        let message = cause.to_string();
        message.starts_with("UnsupportedCapability:")
            || message.starts_with("CONFIG_CAPABILITY_UNSUPPORTED:")
    });
    let code = if capability {
        "CONFIG_CAPABILITY_UNSUPPORTED"
    } else if doctor {
        "DIAG_DOCTOR_FAILED"
    } else {
        "PROXY_CONFIG_LOAD_FAILED"
    };
    anyhow!("{code}: {error:#}")
}

async fn diagnose(args: &Args, doctor: bool) -> Result<Output> {
    if doctor {
        let state = daemon::status().await?;
        let data = doctor_diagnostics(args.prepare(), &state, ([1, 1, 1, 1], 443).into())
            .await
            .map_err(|error| diagnostic_load_error(error, args, true))?;
        if !args.flag("--json") {
            print!("{}", doctor_report(&data));
        }
        return diagnostic_result(data);
    }
    let prepared = service::prepare(args.prepare())
        .await
        .map_err(|error| diagnostic_load_error(error, args, false))?;
    let state = daemon::status().await?;
    let port = prepared.port;
    let listening = tcp_probe(([127, 0, 0, 1], port).into(), Duration::from_millis(250)).await;
    let config = service::prepared_config(&prepared)?;
    let mut checks = vec![
        json!({"name":"port:mixed","ok":listening,"detail":format!("127.0.0.1:{port} {}",if listening{"listening"}else{"not listening"})}),
    ];
    let mut targets = Vec::new();
    if listening {
        let client = reqwest::Client::builder()
            .no_proxy()
            .proxy(reqwest::Proxy::http(format!("http://127.0.0.1:{port}"))?)
            .connect_timeout(Duration::from_secs(5))
            .timeout(Duration::from_secs(10))
            .redirect(reqwest::redirect::Policy::none())
            .build()?;
        let mut tasks = tokio::task::JoinSet::new();
        for (name, url) in [
            ("IP/Location", "http://ip-api.com/json"),
            ("Google", "http://www.google.com/generate_204"),
            ("YouTube", "http://www.youtube.com/generate_204"),
            ("Netflix", "http://www.netflix.com"),
            ("OpenAI", "http://chat.openai.com"),
            ("GitHub", "http://github.com"),
            ("Cloudflare", "http://1.1.1.1"),
        ] {
            let client = client.clone();
            tasks.spawn(async move { diagnostic_target_probe(&client, name, url).await });
        }
        while let Some(result) = tasks.join_next().await {
            let target = result?;
            if !args.flag("--json") {
                println!("{}", diagnostic_target_report(&target));
            }
            targets.push(target);
        }
        let success = targets.iter().filter(|t| t["ok"] == true).count();
        checks.push(json!({"name":"connectivity","ok":success>0,"detail":format!("{success}/{} targets reachable",targets.len())}));
    } else if !args.flag("--json") {
        println!("Port: 127.0.0.1:{port} not listening");
    }
    let selected = config
        .selected()
        .into_iter()
        .map(|(group, proxy)| json!({"group":group,"proxy":proxy}))
        .collect::<Vec<_>>();
    diagnostic_result(
        json!({"action":"proxy_test","daemon_state":state["state"],"selected_proxies":selected,"ports":[{"label":"mixed","port":port,"listening":listening}],"checks":checks,"targets":targets}),
    )
}
fn diagnostic_result(data: Value) -> Result<Output> {
    let failed = data["checks"]
        .as_array()
        .context("missing diagnostic checks")?
        .iter()
        .any(|c| c["ok"] != true);
    if failed {
        return Err(Failure {
            code: "CHECKS_FAILED".into(),
            message: "one or more diagnostic checks failed".into(),
            hint: "inspect failed checks; `zc status` and `zc log --no-follow` show daemon details"
                .into(),
            exit: 1,
            data: Some(data),
        }
        .into());
    }
    Ok(Output::Data(data))
}
