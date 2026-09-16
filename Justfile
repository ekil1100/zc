set shell := ["bash", "-euo", "pipefail", "-c"]
set positional-arguments

# List available tasks.
default:
    @just --list

# Build the Rust development binary.
build *args:
    cargo build --locked "$@"

# Build the optimized Rust binary without installing it.
release:
    cargo build --locked --release

# Format Rust source files.
fmt:
    cargo fmt --all

# Check Rust formatting and lint all targets.
check:
    cargo fmt --all -- --check
    cargo clippy --locked --all-targets -- -D warnings

# Run Rust tests; extra arguments are passed to cargo test.
test *args:
    #!/usr/bin/env bash
    set -euo pipefail
    ulimit -n 8192
    cargo test --locked "$@"

# Run the Rust foreground proxy on a non-production port.
run config="testdata/config/rust-tcp.yaml" port="17890":
    if [[ "$2" =~ ^\+?0*7899$ ]]; then echo "error: port 7899 is reserved for production; choose another port" >&2; exit 2; fi
    cargo run --locked -- start --config "$1" --port "$2" --foreground

# Test the Rust binary against independent SS/Trojan servers.
e2e: build
    bash scripts/e2e/fetch-static-fixtures.sh .zig-cache/e2e-fixtures
    python3 scripts/e2e/run-rust-tcp.py target/debug/zc .zig-cache/e2e-fixtures

# Run the complete Rust development checks.
validate: check test e2e

# Build the Zig reference binary (Zig 0.16.0).
zig-build:
    zig build -Dcpu=baseline

# Run the Zig reference tests.
zig-test:
    zig build test -Dcpu=baseline

# Run the Zig reference end-to-end tests.
zig-e2e:
    zig build e2e --summary all

# Run a Zig eval suite: correctness, contract, interop, perf, or all.
zig-eval suite *args:
    bash scripts/eval/run.sh --suite "$@"

# Check the Zig eval framework; pass --full to include its suites.
zig-eval-selfcheck *args:
    bash scripts/eval/selfcheck.sh "$@"

# Run configuration-migrator regressions for the Zig baseline.
zig-migrator-test:
    bash tools/config-migrator/run-all.sh

# Run installer regressions for the Zig baseline; does not install zc.
zig-install-test:
    bash scripts/install/run-all-regression.sh
