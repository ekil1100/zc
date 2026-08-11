#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT_DIR"

CI_WORKFLOW=".github/workflows/ci.yml"
RELEASE_WORKFLOW=".github/workflows/release.yml"

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
expect_text "$CI_WORKFLOW" "bash scripts/ci/test-release-workflow.sh"
expect_text "$CI_WORKFLOW" "bash scripts/ci/test-beta-gate.sh"
expect_text "$CI_WORKFLOW" "bash scripts/ci/test-default-runtime-port.sh"
expect_text "$CI_WORKFLOW" "zig build test"
expect_text "$CI_WORKFLOW" "tools/config-migrator/run-all.sh"
expect_text "$CI_WORKFLOW" "scripts/install/run-all-regression.sh"
expect_text "$CI_WORKFLOW" "zig build e2e-release"
expect_text "$CI_WORKFLOW" "-Doptimize=ReleaseSafe"
reject_text "$CI_WORKFLOW" "if: github.event_name == 'pull_request'"
reject_text "$CI_WORKFLOW" "Full validation"

expect_text "$RELEASE_WORKFLOW" "Verify successful main CI"
expect_text "$RELEASE_WORKFLOW" "actions/workflows/ci.yml/runs"
expect_text "$RELEASE_WORKFLOW" "fail-fast: false"
expect_text "$RELEASE_WORKFLOW" "x86_64-linux-musl"
expect_text "$RELEASE_WORKFLOW" "aarch64-linux-musl"
expect_text "$RELEASE_WORKFLOW" "x86_64-macos"
expect_text "$RELEASE_WORKFLOW" "aarch64-macos"
expect_text "$RELEASE_WORKFLOW" "Prepare release notes"
expect_text "$RELEASE_WORKFLOW" "body_path: dist/release-notes.md"
expect_text "$RELEASE_WORKFLOW" "Publish GitHub Release"
expect_text "$RELEASE_WORKFLOW" "Commit and push"
reject_text "$RELEASE_WORKFLOW" "zig build test"
reject_text "$RELEASE_WORKFLOW" "tools/config-migrator/run-all.sh"
reject_text "$RELEASE_WORKFLOW" "scripts/install/run-all-regression.sh"
reject_text "$RELEASE_WORKFLOW" "zig build e2e-release"
reject_text "$RELEASE_WORKFLOW" "Rebuild final standalone artifact"

PACKAGE_VERSION=$(awk -F'"' '/^[[:space:]]*\.version = / { print $2; exit }' build.zig.zon)
[[ -n "$PACKAGE_VERSION" ]] || fail "package version is missing"
RELEASE_NOTES=$(awk -v heading="## [${PACKAGE_VERSION}] - " '
  index($0, heading) == 1 { found = 1; next }
  found && index($0, "## [") == 1 { exit }
  found { print }
  END { if (!found) exit 1 }
' CHANGELOG.md) || fail "CHANGELOG has no $PACKAGE_VERSION release section"
[[ -n "${RELEASE_NOTES//[[:space:]]/}" ]] || fail "CHANGELOG $PACKAGE_VERSION release notes are empty"

printf 'RELEASE_WORKFLOW_CONTRACT=PASS\n'
