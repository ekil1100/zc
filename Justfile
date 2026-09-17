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

# Build independent test-only helpers (never installed as production binaries).
e2e-helpers:
    cargo build --locked --examples

# Test helper public interfaces and independent literal crypto vectors.
helper-test: e2e-helpers
    python3 examples/support/test-helpers.py target/debug/examples

# Run task-runner and release workflow contracts without installation.
delivery-test:
    python3 scripts/ci/test-justfile.py
    python3 scripts/ci/test-macos-artifact.py
    bash scripts/ci/test-release-workflow.sh

# Run the unchanged core harness plus independent TCP interoperability.
e2e: build helper-test
    bash scripts/e2e/fetch-static-fixtures.sh target/e2e-fixtures
    bash scripts/e2e/run-core.sh "$PWD/target/debug/zc" "$PWD/target/debug/examples/e2e_origin" "$PWD/target/debug/examples/e2e_obfs_oracle" "$PWD/target/debug/examples/e2e_ss_udp_oracle" "$PWD/target/e2e-fixtures" "$PWD/testdata/e2e"
    TMPDIR="$(cd "${TMPDIR:-/tmp}" && pwd -P)" python3 scripts/e2e/run-rust-tcp.py target/debug/zc target/e2e-fixtures

# Exercise installer rollback in temporary directories, never the real HOME.
install-test: build e2e-helpers
    bash scripts/install/run-all-regression.sh
    bash scripts/install/test-oneline-installer.sh "$PWD/target/debug/zc" "$PWD/target/debug/examples/e2e_origin"

# Run complete Rust delivery checks; no Zig runtime or compiler fallback.
validate: check test delivery-test e2e install-test release

# Build the Zig reference binary (Zig 0.16.0).
zig-build:
    zig build -Dcpu=baseline

# Run the Zig reference tests.
zig-test:
    zig build test -Dcpu=baseline

# Run the Zig reference end-to-end tests.
zig-e2e:
    zig build e2e --summary all

# Run a Rust eval suite: correctness, contract, interop, perf, or all.
eval suite *args:
    bash scripts/eval/run.sh --suite "$@"

# Check the Rust eval framework; pass --full to include its suites.
eval-selfcheck *args:
    bash scripts/eval/selfcheck.sh "$@"

# Run the independent configuration-migrator regressions.
migrator-test:
    bash tools/config-migrator/run-all.sh

# Run historical installer regressions; does not install into the real HOME.
zig-install-test:
    bash scripts/install/run-all-regression.sh
