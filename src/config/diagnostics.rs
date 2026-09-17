//! Bounded doctor validation. This report is never a routable configuration.
use std::{
    collections::{BTreeMap, HashMap, HashSet},
    fmt::{self, Write},
    net::IpAddr,
};

use serde::Deserialize;
use serde_json::Value;

use super::{RawProxy, Rule, parse_port, provider, validate_name};

const COUNT_MAX: usize = 256;
const BYTES_MAX: usize = 512;
const SUFFIX: &str = " ... [truncated]";

#[derive(Debug, Default)]
pub struct Diagnostics {
    pub errors: Vec<String>,
    pub warnings: Vec<String>,
    pub migration_hints: Vec<&'static str>,
    pub truncated: bool,
    // Validity must not depend on which messages fit in the retained budget.
    pub has_errors: bool,
}

fn unsafe_character(ch: char) -> bool {
    ch.is_control()
        || matches!(ch, '\u{061c}' | '\u{200e}' | '\u{200f}' | '\u{2028}'..='\u{202e}' | '\u{2066}'..='\u{2069}' | '\u{feff}')
}

struct Message {
    text: String,
    rendered_bytes: usize,
}
impl Write for Message {
    fn write_str(&mut self, text: &str) -> fmt::Result {
        for ch in text.chars() {
            if self.rendered_bytes + ch.len_utf8() > BYTES_MAX {
                return Err(fmt::Error);
            }
            // Charge the original rendered bytes before removing terminal controls.
            self.rendered_bytes += ch.len_utf8();
            self.text.push(if unsafe_character(ch) { ' ' } else { ch });
        }
        Ok(())
    }
}
impl Diagnostics {
    fn add(&mut self, error: bool, template: &'static str, args: fmt::Arguments<'_>) {
        self.has_errors |= error;
        if self.errors.len() + self.warnings.len() == COUNT_MAX {
            self.truncated = true;
            if !error || self.warnings.pop().is_none() {
                return;
            }
        }
        let mut message = Message {
            text: String::with_capacity(BYTES_MAX),
            rendered_bytes: 0,
        };
        if message.write_fmt(args).is_err() {
            self.truncated = true;
            message.text.clear();
            // Zig replaces ALL interpolated arguments with "...", rather than
            // retaining a potentially sensitive prefix of an oversized value.
            let mut literal = template;
            while let Some((prefix, rest)) = literal.split_once("{}") {
                message.text.push_str(prefix);
                message.text.push_str("...");
                literal = rest;
            }
            message.text.push_str(literal);
            let mut end = message.text.len().min(BYTES_MAX - SUFFIX.len());
            while !message.text.is_char_boundary(end) {
                end -= 1;
            }
            message.text.truncate(end);
            message.text.push_str(SUFFIX);
        }
        if error {
            self.errors.push(message.text);
        } else {
            self.warnings.push(message.text);
        }
    }
}
macro_rules! error {
    ($r:expr, $fmt:literal $(, $arg:expr)* $(,)?) => { $r.add(true, $fmt, format_args!($fmt $(, $arg)*)) };
}
macro_rules! warning {
    ($r:expr, $fmt:literal $(, $arg:expr)* $(,)?) => { $r.add(false, $fmt, format_args!($fmt $(, $arg)*)) };
}

pub(crate) fn validate(original: &Value, runtime: &Value) -> Diagnostics {
    let mut report = Diagnostics::default();
    basic(original, &mut report);
    // Compatibility projection must not grant unsupported root fields permission
    // to bypass the runtime parser's deny_unknown_fields contract.
    if let Some(fields) = runtime.as_object() {
        for field in fields.keys() {
            if !matches!(
                field.as_str(),
                "proxies"
                    | "proxy-groups"
                    | "rules"
                    | "rule-providers"
                    | "allow-lan"
                    | "bind-address"
                    | "mixed-port"
                    | "port"
                    | "socks-port"
                    | "mode"
                    | "log-level"
                    | "external-controller"
                    | "secret"
            ) {
                error!(report, "Unsupported configuration field '{}'", field);
            }
        }
    }
    let proxies = runtime["proxies"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let groups = runtime["proxy-groups"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let rules = runtime["rules"]
        .as_array()
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let mut names = HashMap::from([("DIRECT".to_owned(), 0), ("REJECT".to_owned(), 1)]);
    let mut proxy_names = HashSet::new();
    for (index, proxy) in proxies.iter().enumerate() {
        let name = proxy["name"].as_str().unwrap_or("");
        let duplicate = !name.is_empty() && !proxy_names.insert(name);
        names.entry(name.to_owned()).or_insert(index + 2);
        check_proxy(proxy, index + 1, duplicate, &mut report);
    }
    let mut group_names = HashMap::new();
    for (index, group) in groups.iter().enumerate() {
        let name = group["name"].as_str().unwrap_or("");
        let duplicate = group_names.insert(name, index).is_some();
        names
            .entry(name.to_owned())
            .or_insert(proxies.len() + index + 2);
        if name.is_empty() {
            error!(report, "Proxy group #{}: name cannot be empty", index + 1);
            continue;
        }
        if name.chars().any(unsafe_character) {
            error!(
                report,
                "Proxy group #{}: name contains terminal control characters",
                index + 1
            );
        } else if validate_name(name).is_err() {
            error!(
                report,
                "Proxy group #{}: name must be unpadded and contain no commas",
                index + 1
            );
        }
        if proxy_names.contains(name) {
            error!(
                report,
                "Policy name '{}' is used by both a proxy and a proxy group", name
            );
        }
        if duplicate {
            error!(report, "Duplicate proxy group name: '{}'", name);
        }
        if group["proxies"].as_array().is_none_or(Vec::is_empty) {
            error!(report, "Proxy group '{}': proxy list cannot be empty", name);
        }
        if super::RawGroup::deserialize(group).is_err() {
            error!(
                report,
                "Proxy group #{}: invalid fields or types",
                index + 1
            );
        }
    }
    let mut providers = BTreeMap::new();
    if let Some(declarations) = runtime["rule-providers"].as_object() {
        for (name, value) in declarations {
            if name.chars().any(unsafe_character) {
                error!(
                    report,
                    "Rule provider name contains terminal control characters"
                );
            }
            match provider::Provider::deserialize(value) {
                Ok(provider) => {
                    let one = BTreeMap::from([(name.clone(), provider)]);
                    if let Err(err) = provider::validate_rule_declarations(&[], &one, &names) {
                        error!(report, "Rule provider '{}': {}", name, err);
                    }
                    providers.extend(one);
                }
                Err(_) => error!(report, "Rule provider '{}': invalid fields or types", name),
            }
        }
    }
    for (index, value) in rules.iter().enumerate() {
        let Some(source) = value.as_str() else {
            error!(report, "Rule #{}: expected a string", index + 1);
            continue;
        };
        check_rule(source, index + 1, &names, &mut report);
    }
    let mut edges = vec![Vec::new(); groups.len()];
    for (index, group) in groups.iter().enumerate() {
        let name = group["name"].as_str().unwrap_or("");
        for member in group["proxies"].as_array().into_iter().flatten() {
            let Some(member) = member.as_str() else {
                error!(report, "Proxy group '{}': member must be a string", name);
                continue;
            };
            if !names.contains_key(member) {
                error!(
                    report,
                    "Proxy group '{}': references undefined proxy or group '{}'", name, member
                );
            }
            if let Some(&child) = group_names.get(member) {
                edges[index].push(child);
            }
        }
    }
    for (index, source) in rules
        .iter()
        .enumerate()
        .filter_map(|(i, r)| r.as_str().map(|r| (i, r)))
    {
        let fields: Vec<_> = source
            .split(',')
            .take(5)
            .map(|field| field.trim_matches([' ', '\t']))
            .collect();
        if let ["RULE-SET", provider, ..] = fields.as_slice()
            && !providers.contains_key(*provider)
        {
            error!(
                report,
                "Rule #{}: references undefined rule-provider '{}'",
                index + 1,
                provider
            );
        }
        let target = if fields.first() == Some(&"MATCH") {
            fields.get(1)
        } else {
            fields.get(2)
        };
        if let Some(target) = target
            && !names.contains_key(*target)
        {
            error!(
                report,
                "Rule #{}: references undefined target '{}'",
                index + 1,
                target
            );
        }
    }
    cycles(&edges, groups, &mut report);
    report
}

fn basic(doc: &Value, report: &mut Diagnostics) {
    if let Some(mode) = doc["mode"].as_str()
        && !matches!(mode, "rule" | "global" | "direct")
    {
        error!(
            report,
            "Invalid mode: '{}' (must be 'rule', 'global', or 'direct')", mode
        );
    }
    if let Some(level) = doc["log-level"].as_str()
        && !matches!(level, "debug" | "info" | "warning" | "error" | "silent")
    {
        error!(report, "Unknown log level: '{}'", level);
    }
    let bind = doc["bind-address"].as_str().unwrap_or("*");
    if bind != "*" && bind.parse::<std::net::Ipv4Addr>().is_err() {
        error!(report, "Invalid bind-address: '{}' (use '*' or IPv4)", bind);
    }
    if doc["allow-lan"] != true && bind != "*" {
        warning!(
            report,
            "allow-lan=false: bind-address '{}' will be ignored, using 127.0.0.1",
            bind
        );
    }
    if let Some(endpoint) = doc["external-controller"].as_str()
        && endpoint
            .strip_prefix("127.0.0.1:")
            .is_none_or(|p| parse_port(p).is_err())
    {
        // Endpoint values may contain URL credentials; never echo them.
        error!(
            report,
            "Invalid external-controller (expected 127.0.0.1:PORT)"
        );
    }
    if let Some(secret) = doc["secret"].as_str()
        && (secret.len() > 256
            || !secret
                .bytes()
                .all(|c| c.is_ascii_alphanumeric() || b"-._~".contains(&c)))
    {
        error!(
            report,
            "Invalid controller secret (use at most 256 characters from A-Z, a-z, 0-9, '-', '.', '_' or '~')"
        );
    }
    for field in ["idle-session-check-interval", "idle-session-timeout"] {
        if let Some(seconds) = doc[field].as_i64()
            && seconds <= 5
        {
            warning!(
                report,
                "{}={}s is too low (<=5s); clamped to 30s",
                field,
                seconds
            );
        }
    }
}

fn check_proxy(proxy: &Value, index: usize, duplicate: bool, report: &mut Diagnostics) {
    let name = proxy["name"].as_str().unwrap_or("");
    if name.is_empty() {
        error!(report, "Proxy #{}: name cannot be empty", index);
        return;
    }
    if name.chars().any(unsafe_character) {
        error!(
            report,
            "Proxy #{}: name contains terminal control characters", index
        );
    } else if validate_name(name).is_err() {
        error!(
            report,
            "Proxy #{}: name must be unpadded and contain no commas", index
        );
    }
    if proxy["server"]
        .as_str()
        .is_some_and(|s| s.chars().any(unsafe_character))
    {
        error!(
            report,
            "Proxy #{}: server contains terminal control characters", index
        );
    }
    if duplicate {
        error!(report, "Duplicate proxy name: '{}'", name);
    }
    let kind = proxy["type"].as_str().unwrap_or("");
    if kind == "trojan" && proxy["skip-cert-verify"] == true {
        warning!(
            report,
            "Trojan proxy '{}': skip-cert-verify=true disables TLS certificate verification",
            name
        );
    }
    let mut invalid = false;
    if matches!(kind, "ss" | "trojan") {
        let server = proxy["server"].as_str().unwrap_or("");
        let server_invalid = !server.is_empty()
            && (server.len() > 253
                || server
                    .strip_suffix('.')
                    .is_some_and(|s| s.parse::<IpAddr>().is_ok())
                || crate::target::Target::new(server, 1).is_err());
        if server.is_empty() {
            invalid = true;
            if kind == "ss" {
                error!(
                    report,
                    "Shadowsocks proxy '{}': server cannot be empty", name
                );
            } else {
                error!(report, "Trojan proxy '{}': server cannot be empty", name);
            }
        } else if kind == "ss" && server_invalid {
            invalid = true;
            error!(
                report,
                "Shadowsocks proxy '{}': server must be a valid IP literal or RFC hostname", name
            );
        }
        if proxy["port"].as_u64().is_none_or(|p| p == 0 || p > 65535) {
            invalid = true;
            error!(report, "Proxy '{}': invalid port (must be 1-65535)", name);
        }
        let password = proxy["password"].as_str().unwrap_or("");
        if password.is_empty() {
            invalid = true;
            if kind == "ss" {
                error!(report, "Shadowsocks proxy '{}': password is required", name);
            } else {
                error!(report, "Trojan proxy '{}': password is required", name);
            }
        } else if password.chars().any(char::is_control) {
            invalid = true;
            error!(
                report,
                "Proxy '{}': password contains control characters", name
            );
        }
        if kind == "ss" && proxy["cipher"].as_str().is_none_or(str::is_empty) {
            invalid = true;
            error!(report, "Shadowsocks proxy '{}': cipher is required", name);
        }
        if kind == "trojan" {
            if server_invalid {
                invalid = true;
                error!(
                    report,
                    "Trojan proxy '{}': server must be a valid IP literal or RFC hostname (1-253 bytes)",
                    name
                );
            }
            if let Some(sni) = proxy["sni"].as_str() {
                if sni.len() > 253
                    || sni.ends_with('.')
                    || sni.parse::<IpAddr>().is_ok()
                    || crate::target::Target::new(sni, 1).is_err()
                {
                    invalid = true;
                    error!(
                        report,
                        "Trojan proxy '{}': sni must be a valid RFC hostname (1-253 bytes; no IP, wildcard, whitespace, or control characters)",
                        name
                    );
                }
            } else if proxy["skip-cert-verify"] != true && server.parse::<IpAddr>().is_ok() {
                invalid = true;
                error!(
                    report,
                    "Trojan proxy '{}': verified IP server requires an explicit hostname sni", name
                );
            }
        }
    }
    // Reuse the runtime primitive for the remaining protocol/field restrictions.
    // Never stringify serde errors: they can include raw credentials.
    match RawProxy::deserialize(proxy) {
        Ok(proxy) if !invalid => {
            if let Err(err) = proxy.build() {
                error!(report, "Proxy '{}': {}", name, err);
            }
        }
        Ok(_) => (),
        Err(_) => error!(report, "Proxy #{}: invalid fields or types", index),
    }
}

fn cycles(edges: &[Vec<usize>], groups: &[Value], report: &mut Diagnostics) {
    let mut state = vec![0u8; edges.len()];
    let mut stack = Vec::with_capacity(edges.len());
    for root in 0..edges.len() {
        if state[root] != 0 {
            continue;
        }
        state[root] = 1;
        stack.push((root, 0));
        while let Some(&(node, next)) = stack.last() {
            let Some(&child) = edges[node].get(next) else {
                state[node] = 2;
                stack.pop();
                continue;
            };
            stack.last_mut().unwrap().1 += 1;
            match state[child] {
                0 => {
                    state[child] = 1;
                    stack.push((child, 0));
                }
                1 => error!(
                    report,
                    "Proxy group '{}': cycle detected, including unselected branches",
                    groups[node]["name"].as_str().unwrap_or("")
                ),
                _ => (),
            }
        }
    }
}

/// Preserve the original doctor source-text scan (including comments), its order
/// and its 1 MiB limit. These informational strings never alter validation.
pub(crate) fn migration_hints(source: &[u8]) -> Vec<&'static str> {
    if source.len() > 1024 * 1024 {
        return Vec::new();
    }
    let source = std::str::from_utf8(source).unwrap_or("");
    [
        (
            "tun:",
            "tun mode is not supported by zc and will be ignored",
        ),
        (
            "enhanced-mode:",
            "dns.enhanced-mode is not supported and will be ignored",
        ),
        (
            "rule-providers:",
            "rule-providers remote update is not fully implemented; manual refresh recommended",
        ),
        (
            "proxy-providers:",
            "proxy-providers is not supported; declare proxies statically in the config",
        ),
    ]
    .into_iter()
    .filter_map(|(needle, hint)| source.contains(needle).then_some(hint))
    .collect()
}

fn check_rule(
    source: &str,
    index: usize,
    names: &HashMap<String, usize>,
    report: &mut Diagnostics,
) {
    let fields: Vec<_> = source
        .split(',')
        .take(5)
        .map(|field| field.trim_matches([' ', '\t']))
        .collect();
    let kind = fields[0];
    let payload = fields.get(1).copied().unwrap_or("");
    let empty = kind != "MATCH" && payload.is_empty();
    if empty {
        error!(report, "Rule #{}: payload cannot be empty", index);
    }
    let mut specific_error = empty;
    match kind {
        "IP-CIDR" | "IP-CIDR6" | "SRC-IP-CIDR" => {
            if payload
                .parse::<ipnet::IpNet>()
                .is_ok_and(|net| net.addr().is_ipv6() == (kind == "IP-CIDR6"))
            {
                // The runtime uses the same CIDR parser.
            } else {
                specific_error = true;
                if kind == "IP-CIDR6" {
                    error!(
                        report,
                        "Rule #{}: invalid IPv6 CIDR format '{}'", index, payload
                    );
                } else {
                    error!(
                        report,
                        "Rule #{}: invalid IPv4 CIDR format '{}'", index, payload
                    );
                }
            }
        }
        "DST-PORT" | "SRC-PORT" => {
            let (first, last) = payload.split_once('-').unwrap_or((payload, payload));
            if !matches!((parse_port(first), parse_port(last)), (Ok(a), Ok(b)) if a <= b) {
                specific_error = true;
                error!(report, "Rule #{}: invalid port range '{}'", index, payload);
            }
        }
        "RULE-SET" => {
            if empty {
                error!(
                    report,
                    "Rule #{}: RULE-SET provider name cannot be empty", index
                );
            }
            if !matches!(
                fields.as_slice(),
                ["RULE-SET", _, _] | ["RULE-SET", _, _, "no-resolve"]
            ) {
                error!(report, "Rule #{}: invalid RULE-SET declaration", index);
            }
            return;
        }
        _ => (),
    }
    if !specific_error && let Err(err) = Rule::parse(source, names) {
        // References are reported after all payload and group errors.
        if err.to_string() != "rule references an unknown proxy or group" {
            error!(report, "Rule #{}: {}", index, err);
        }
    }
}
