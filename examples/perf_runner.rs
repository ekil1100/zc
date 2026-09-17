//! Release-only control-plane measurements. No thresholds or synthetic PASS values.
use std::{fs::File, hint::black_box, io::Read, time::Instant};

use anyhow::{Result, ensure};
use clap::Parser;
use serde::Serialize;
use zc::store::{Bundle, Metadata, Store};

#[derive(Parser)]
struct Options {
    #[arg(long, default_value_t = 9)]
    samples: usize,
    #[arg(long, default_value_t = 200)]
    iterations: u64,
    #[arg(long, default_value_t = 65536)]
    fixture_bytes: usize,
    #[arg(long, default_value = "unknown")]
    subject_commit: String,
    #[arg(long, default_value = "unknown")]
    harness_commit: String,
    #[arg(long, default_value = "unknown")]
    machine: String,
}

#[derive(Serialize)]
struct Sample {
    iterations: u64,
    elapsed_ns: u64,
    ns_per_op: u64,
}
#[derive(Serialize)]
struct Benchmark {
    name: String,
    samples: Vec<Sample>,
    median_ns_per_op: u64,
    p95_ns_per_op: u64,
}

fn measure(
    name: &str,
    options: &Options,
    mut operation: impl FnMut() -> Result<()>,
) -> Result<Benchmark> {
    let mut samples = Vec::new();
    for index in 0..=options.samples {
        let started = Instant::now();
        for _ in 0..options.iterations {
            operation()?;
        }
        let elapsed_ns = u64::try_from(started.elapsed().as_nanos())?;
        if index != 0 {
            samples.push(Sample {
                iterations: options.iterations,
                elapsed_ns,
                ns_per_op: elapsed_ns / options.iterations,
            });
        }
    }
    let mut ordered: Vec<_> = samples.iter().map(|s| s.ns_per_op).collect();
    ordered.sort_unstable();
    let middle = ordered.len() / 2;
    let median = if ordered.len() % 2 == 0 {
        ordered[middle - 1] + (ordered[middle] - ordered[middle - 1]) / 2
    } else {
        ordered[middle]
    };
    let p95 = ordered[(ordered.len() * 95).div_ceil(100) - 1];
    Ok(Benchmark {
        name: name.into(),
        samples,
        median_ns_per_op: median,
        p95_ns_per_op: p95,
    })
}

fn profile_commits(options: &Options, count: usize) -> Result<Benchmark> {
    let work = tempfile::tempdir()?;
    let store = Store::open(work.path().join("state"))?;
    let bundle = Bundle::from_memory(
        b"mixed-port: 18080\nrules: ['MATCH,DIRECT']\n",
        None,
        Default::default(),
    )?;
    let mut token = store.load()?.token;
    for index in 0..count {
        let key = if index == 0 {
            "target".into()
        } else {
            format!("profile-{index}")
        };
        let receipt = store.publish(&token, &key, None, &bundle, Metadata::default(), false)?;
        ensure!(
            receipt.durability_error.is_none(),
            "profile initialization durability failure"
        );
        token = receipt.token;
    }
    let mut head = store.get("target")?.head;
    let mut counter = 0_u64;
    let benchmark = measure(
        &format!("profile_publish_profiles_{count}"),
        options,
        || {
            counter += 1;
            let metadata = Metadata {
                filename: Some(format!("revision-{counter}.yaml")),
                ..Metadata::default()
            };
            let receipt = store.publish(&token, "target", Some(&head), &bundle, metadata, false)?;
            ensure!(
                receipt.durability_error.is_none(),
                "profile commit durability failure"
            );
            token = receipt.token;
            head = store.get("target")?.head;
            Ok(())
        },
    )?;
    let reopened = Store::open(work.path().join("state"))?;
    ensure!(reopened.list()?.len() == count, "profile count mismatch");
    ensure!(reopened.get("target")?.head == head, "head mismatch");
    ensure!(reopened.load()?.token == token, "token mismatch");
    Ok(benchmark)
}

fn main() -> Result<()> {
    let options = Options::parse();
    ensure!(!cfg!(debug_assertions), "release build required");
    ensure!(options.samples >= 5, "at least five samples required");
    ensure!(options.iterations > 0, "iterations must be positive");
    ensure!(
        (1..=16 * 1024 * 1024).contains(&options.fixture_bytes),
        "invalid fixture size"
    );
    let work = tempfile::tempdir()?;
    let path = work.path().join("read.bin");
    // Match the original repeated 4096-byte Zig fixture exactly.
    let fixture: Vec<_> = (0..options.fixture_bytes)
        .map(|n| ((n % 4096) % 251) as u8)
        .collect();
    std::fs::write(&path, &fixture)?;
    File::open(&path)?.sync_all()?;
    let legacy = measure("legacy_bounded_read", &options, || {
        // Harness-only reference for the old truncating reader, not a runtime fallback.
        let mut bytes = Vec::new();
        File::open(&path)?
            .take(options.fixture_bytes as u64)
            .read_to_end(&mut bytes)?;
        ensure!(bytes.len() == fixture.len(), "short read");
        black_box(bytes[0].wrapping_add(bytes[bytes.len() - 1]));
        Ok(())
    })?;
    let strict = measure("strict_bounded_read", &options, || {
        let bytes = zc::fsutil::read_regular(&path, options.fixture_bytes)?;
        ensure!(bytes.len() == fixture.len(), "short read");
        black_box(bytes[0].wrapping_add(bytes[bytes.len() - 1]));
        Ok(())
    })?;
    let mut benchmarks = vec![legacy, strict];
    for count in [1, 100, 1000] {
        benchmarks.push(profile_commits(&options, count)?);
    }
    let rust = std::process::Command::new("rustc")
        .arg("--version")
        .output()?;
    ensure!(rust.status.success(), "rustc version probe failed");
    let report = serde_json::json!({
        "schema_version": 1, "kind": "measurement", "status": "measured",
        "provenance": {
            "subject_commit": options.subject_commit, "harness_commit": options.harness_commit,
            "optimize": "release", "os": std::env::consts::OS, "arch": std::env::consts::ARCH,
            "cpu_model": "rustc-default-target", "rust_version": String::from_utf8(rust.stdout)?.trim(),
            "machine": options.machine,
        },
        "method": {"warmup_runs": 1, "sample_count": options.samples,
            "iterations_per_sample": options.iterations, "fixture_bytes": options.fixture_bytes,
            "clock": "std::time::Instant", "profile_operation": "Store.publish + Store.get; immutable revision and durable catalog CAS; not Zig Authority.commit"},
        "benchmarks": benchmarks, "checks": {"fixture_bytes_match": true},
        "omitted": ["authority_compare_exchange_head", "connection_admission", "connection_throughput",
            "connection_latency_p99", "active_flow_rss", "config_import"],
    });
    println!("{report}");
    Ok(())
}
