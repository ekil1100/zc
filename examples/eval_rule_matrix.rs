//! Frozen rule-matrix runner using only the production parser and router.
use anyhow::{Result, ensure};
use serde::Deserialize;
use zc::{config::Config, target::Target};

#[derive(Deserialize)]
struct Matrix {
    rules: Vec<String>,
    cases: Vec<Case>,
}
#[derive(Deserialize)]
struct Case {
    id: String,
    input: Input,
    expect: Expect,
}
#[derive(Deserialize)]
struct Input {
    host: Option<String>,
    ip: Option<String>,
}
#[derive(Deserialize)]
struct Expect {
    target: String,
    matched_rule: Option<String>,
}

fn config(rules: &[String]) -> Result<Config> {
    // Zig's Engine.init has no DNS client. Preserve that matrix contract explicitly;
    // production DNS/resolve behavior is independently covered by interoperability tests.
    let rules: Vec<_> = rules
        .iter()
        .map(|rule| {
            let kind = rule.split(',').next().unwrap_or_default();
            if matches!(kind, "IP-CIDR" | "IP-CIDR6" | "GEOIP")
                && !rule.split(',').any(|part| part.trim() == "no-resolve")
            {
                format!("{rule},no-resolve")
            } else {
                rule.clone()
            }
        })
        .collect();
    // JSON is valid YAML and safely quotes arbitrary fixture strings.
    Config::parse(
        &serde_json::json!({
            "mode": "rule",
            "proxies": [{"name": "PROXY", "type": "ss", "server": "127.0.0.1",
                "port": 1, "cipher": "aes-128-gcm", "password": "matrix-only"}],
            "rules": rules,
        })
        .to_string(),
    )
}

async fn run_case(matrix: &Matrix, full: &Config, case: &Case) -> Result<()> {
    let host = case.input.host.as_ref().or(case.input.ip.as_ref());
    ensure!(host.is_some(), "input needs host or ip");
    let target = Target::new(host.unwrap().clone(), 80)?;
    let actual = &full.route(&target).await?.proxy.name;
    ensure!(
        actual == &case.expect.target,
        "target got={actual} expected={}",
        case.expect.target
    );
    if let Some(expected) = &case.expect.matched_rule {
        ensure!(!expected.is_empty(), "empty matched_rule");
        for end in 1..=matrix.rules.len() {
            let prefix = config(&matrix.rules[..end])?;
            if let Ok(route) = prefix.route(&target).await {
                if &route.proxy.name != actual {
                    continue;
                }
                let mut parts = matrix.rules[end - 1].split(',').map(str::trim);
                let kind = parts.next().unwrap_or_default();
                let label = if matches!(kind, "MATCH" | "FINAL") {
                    "MATCH".to_owned()
                } else {
                    format!("{kind},{}", parts.next().unwrap_or_default())
                };
                ensure!(
                    &label == expected,
                    "matched_rule got={label} expected={expected}"
                );
                return Ok(());
            }
        }
        anyhow::bail!("could not identify winning rule via engine prefixes");
    }
    Ok(())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<()> {
    let args: Vec<_> = std::env::args().collect();
    ensure!(args.len() == 2, "usage: eval-rule-matrix <matrix.yaml>");
    let bytes = zc::fsutil::read_regular(&args[1], 16 * 1024 * 1024)?;
    let matrix: Matrix = serde_saphyr::from_str(std::str::from_utf8(&bytes)?)?;
    ensure!(!matrix.cases.is_empty(), "no cases executed");
    let full = config(&matrix.rules)?;
    let mut failed = Vec::new();
    for case in &matrix.cases {
        if let Err(error) = run_case(&matrix, &full, case).await {
            eprintln!("FAIL {}: {error:#}", case.id);
            failed.push(case.id.as_str());
        }
    }
    eprintln!(
        "RULE_MATRIX_RESULT={}",
        if failed.is_empty() { "PASS" } else { "FAIL" }
    );
    eprintln!("RULE_MATRIX_PASSED={}", matrix.cases.len() - failed.len());
    eprintln!("RULE_MATRIX_FAILED={}", failed.len());
    eprintln!("RULE_MATRIX_TOTAL={}", matrix.cases.len());
    if !failed.is_empty() {
        eprintln!("RULE_MATRIX_FAILED_IDS={}", failed.join(","));
        std::process::exit(1);
    }
    Ok(())
}
