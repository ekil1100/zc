//! Exploratory public-boundary stage timings; not an end-to-end performance gate.
use std::{hint::black_box, time::Instant};

fn measure(name: &str, count: usize, mut operation: impl FnMut()) {
    operation();
    let mut samples = Vec::new();
    for _ in 0..7 {
        let start = Instant::now();
        for _ in 0..count {
            operation();
        }
        samples.push(start.elapsed().as_nanos() as f64 / count as f64);
    }
    println!("{name}\t{samples:?}");
}

fn main() {
    let path = std::env::args().nth(1).expect("fixture path required");
    let source = std::fs::read_to_string(&path).unwrap();
    let document = zc::config::parse_document(&source).unwrap();
    let json = serde_json::to_string(&document).unwrap();
    let runtime = zc::override_script::runtime_source(source.as_bytes()).unwrap();
    measure("parse_document_yaml_ns", 20, || {
        black_box(zc::config::parse_document(&source).unwrap());
    });
    measure("parse_document_json_ns", 20, || {
        black_box(zc::config::parse_document(&json).unwrap());
    });
    measure("runtime_projection_ns", 20, || {
        black_box(zc::override_script::runtime_source(json.as_bytes()).unwrap());
    });
    measure("config_runtime_parse_ns", 20, || {
        black_box(zc::config::Config::parse(&runtime).unwrap());
    });
    measure("bundle_capture_ns", 20, || {
        black_box(zc::store::Bundle::capture_for_runtime(&path).unwrap());
    });
    let bundle = zc::store::Bundle::capture_for_runtime(&path).unwrap();
    measure("catalog_admission_ns", 20, || {
        assert!(black_box(bundle.catalog_ready().unwrap()));
    });
    measure("dump_json_ns", 20, || {
        black_box(zc::override_script::dump_config_json(source.as_bytes()).unwrap());
    });
}
