#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

CI_WORKFLOW=".github/workflows/ci.yml"
RELEASE_WORKFLOW=".github/workflows/release.yml"
JUSTFILE="Justfile"
THIRD_PARTY_NOTICES="THIRD_PARTY_NOTICES.md"

fail() {
  printf 'RELEASE_WORKFLOW_CONTRACT=FAIL detail=%s\n' "$1" >&2
  exit 1
}

expect_text() {
  local file="$1"
  local text="$2"
  grep -Fq -- "$text" "$file" || fail "missing '$text' in $file"
}

reject_text() {
  local file="$1"
  local text="$2"
  if grep -Fq -- "$text" "$file"; then
    fail "unexpected '$text' in $file"
  fi
}

expect_text "$CI_WORKFLOW" "branches: [ main ]"
expect_text "$CI_WORKFLOW" "run: just delivery-test"
expect_text "$CI_WORKFLOW" "bash scripts/ci/test-beta-gate.sh"
expect_text "$CI_WORKFLOW" "bash scripts/ci/test-default-runtime-port.sh"
expect_text "$CI_WORKFLOW" "run: just check"
expect_text "$CI_WORKFLOW" "run: just test"
expect_text "$CI_WORKFLOW" "run: just e2e"
expect_text "$CI_WORKFLOW" "run: just install-test"
expect_text "$CI_WORKFLOW" "cargo build --locked --release --target"
expect_text "$CI_WORKFLOW" "musl-tools"
expect_text "$CI_WORKFLOW" 'bash scripts/e2e/run-core.sh "$PWD/$BINARY"'
expect_text "$CI_WORKFLOW" 'python3 scripts/e2e/run-rust-tcp.py "$BINARY"'
expect_text "$CI_WORKFLOW" 'os: macos-15'
expect_text "$CI_WORKFLOW" 'python3 scripts/ci/test-macos-native.py --ephemeral-runner --target'
for workflow in "$CI_WORKFLOW" "$RELEASE_WORKFLOW"; do
  expect_text "$workflow" '/Applications/Xcode_26.3.app/Contents/Developer'
  expect_text "$workflow" 'python3 scripts/ci/verify-macos-artifact.py "$BINARY"'
  expect_text "$workflow" 'codesign --verify --strict "$BINARY"'
done
expect_text "$RELEASE_WORKFLOW" 'depends_on macos: :sequoia'
expect_text "$JUSTFILE" 'python3 scripts/ci/test-macos-artifact.py'
expect_text "$RELEASE_WORKFLOW" '-f branch=main'
expect_text "$RELEASE_WORKFLOW" 'Cargo.toml)'
reject_text "$RELEASE_WORKFLOW" 'build.zig.zon'
expect_text "$JUSTFILE" "bash scripts/ci/test-release-workflow.sh"
expect_text "$JUSTFILE" "bash scripts/e2e/run-core.sh"
expect_text "$JUSTFILE" "bash scripts/install/test-oneline-installer.sh"
expect_text "$JUSTFILE" "cargo build --locked --release"
reject_text "$CI_WORKFLOW" "zig build"
reject_text "$CI_WORKFLOW" "Setup Zig"
reject_text "$CI_WORKFLOW" "if: github.event_name == 'pull_request'"

expect_text "$RELEASE_WORKFLOW" "Verify successful main CI"
expect_text "$RELEASE_WORKFLOW" "actions/workflows/ci.yml/runs"
expect_text "$RELEASE_WORKFLOW" "fail-fast: false"
expect_text "$RELEASE_WORKFLOW" "x86_64-unknown-linux-musl"
expect_text "$RELEASE_WORKFLOW" "aarch64-unknown-linux-musl"
expect_text "$RELEASE_WORKFLOW" "x86_64-apple-darwin"
expect_text "$RELEASE_WORKFLOW" "aarch64-apple-darwin"
expect_text "$RELEASE_WORKFLOW" "THIRD_PARTY_NOTICES.md"
expect_text "$THIRD_PARTY_NOTICES" "Copyright (c) Zig contributors"
expect_text "$THIRD_PARTY_NOTICES" "The MIT License (Expat)"
expect_text "$RELEASE_WORKFLOW" "Prepare release notes"
expect_text "$RELEASE_WORKFLOW" "body_path: dist/release-notes.md"
expect_text "$RELEASE_WORKFLOW" "Publish GitHub Release"
expect_text "$RELEASE_WORKFLOW" "Commit and push"
expect_text "$RELEASE_WORKFLOW" "cargo build --locked --release --target"
expect_text "$RELEASE_WORKFLOW" "musl-tools"
expect_text "$RELEASE_WORKFLOW" 'PKG_NAME="zc-${RELEASE_TAG}-${TARGET_OS}-${TARGET_ARCH}"'
expect_text "$RELEASE_WORKFLOW" '"${PKG_NAME}.tar.gz.sha256"'
expect_text "$RELEASE_WORKFLOW" 'file "$BINARY"'
reject_text "$RELEASE_WORKFLOW" "Setup Zig"
reject_text "$RELEASE_WORKFLOW" "zig build test"
reject_text "$RELEASE_WORKFLOW" "tools/config-migrator/run-all.sh"
reject_text "$RELEASE_WORKFLOW" "scripts/install/run-all-regression.sh"
reject_text "$RELEASE_WORKFLOW" "zig build e2e-release"
reject_text "$RELEASE_WORKFLOW" "Rebuild final standalone artifact"

PACKAGE_VERSION=$(awk -F'"' '/^version = / { print $2; exit }' Cargo.toml)
[[ -n "$PACKAGE_VERSION" ]] || fail "package version is missing"
RELEASE_NOTES=$(awk -v heading="## [${PACKAGE_VERSION}] - " '
  index($0, heading) == 1 { found = 1; next }
  found && index($0, "## [") == 1 { exit }
  found { print }
  END { if (!found) exit 1 }
' CHANGELOG.md) || fail "CHANGELOG has no $PACKAGE_VERSION release section"
[[ -n "${RELEASE_NOTES//[[:space:]]/}" ]] || fail "CHANGELOG $PACKAGE_VERSION release notes are empty"

printf 'RELEASE_WORKFLOW_CONTRACT=PASS\n'
