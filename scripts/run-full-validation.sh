#!/usr/bin/env bash
set -euo pipefail

# Full Rust validation, including independent E2E and isolated installer tests.
# Usage: bash scripts/run-full-validation.sh

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

failed=()
passed=()

run_step() {
  local name="$1"
  shift
  echo "=== [$name] ==="
  if "$@"; then
    passed+=("$name")
    echo "  PASS"
  else
    failed+=("$name")
    echo "  FAIL"
  fi
}

run_step "check" just check
run_step "test" just test
run_step "delivery-contract" just delivery-test
run_step "e2e" just e2e
run_step "install-regression" just install-test
run_step "release" just release

total=$(( ${#passed[@]} + ${#failed[@]} ))
result="PASS"
[[ ${#failed[@]} -eq 0 ]] || result="FAIL"

echo ""
echo "VALIDATION_RESULT=$result"
echo "VALIDATION_PASS=${#passed[@]}/$total"
echo "VALIDATION_FAILED_STEPS=${failed[*]:-none}"
echo "VALIDATION_NEXT_STEP=$(if [[ "$result" == "PASS" ]]; then echo "Review candidate evidence before release"; else echo "Fix failed steps and rerun"; fi)"

[[ "$result" == "PASS" ]]
