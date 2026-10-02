#!/usr/bin/env bash
set -euo pipefail

# Rust candidate gate; failures are collected, never hidden.
# Usage: bash scripts/run-beta-gate.sh

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

failed=()
passed=()

run_gate() {
  local name="$1"
  shift
  echo "=== [$name] ==="
  local output
  local exit_code
  if output=$("$@" 2>&1); then
    exit_code=0
  else
    exit_code=$?
  fi
  if [[ $exit_code -eq 0 ]]; then
    passed+=("$name")
    echo "  PASS"
  else
    failed+=("$name")
    echo "  FAIL"
    echo "  --- failure details ---"
    printf '%s\n' "$output"
    echo "  --- end ---"
  fi
}

run_gate "release" just release
run_gate "check" just check
run_gate "test" just test
run_gate "delivery-contract" just delivery-test
run_gate "e2e" just e2e
run_gate "install-regression" just install-test

total=$(( ${#passed[@]} + ${#failed[@]} ))
result="PASS"
[[ ${#failed[@]} -eq 0 ]] || result="FAIL"

echo ""
echo "BETA_GATE_RESULT=$result"
echo "BETA_GATE_PASS=${#passed[@]}/$total"
echo "BETA_GATE_FAILED=${failed[*]:-none}"

[[ "$result" == "PASS" ]]
