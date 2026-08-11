#!/usr/bin/env bash
set -euo pipefail

# Beta 准入一键自检：build + test + migrator + install regression
# 用法：bash scripts/run-beta-gate.sh

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
    echo "$output" | grep -iE "error|fail|FAIL|expected|panic" | head -20 | sed 's/^/  /' || true
    echo "  --- end ---"
  fi
}

run_gate "build" zig build
run_gate "test" zig build test
run_gate "migrator-regression" bash tools/config-migrator/run-all.sh
run_gate "install-regression" bash scripts/install/run-all-regression.sh

total=$(( ${#passed[@]} + ${#failed[@]} ))
result="PASS"
[[ ${#failed[@]} -eq 0 ]] || result="FAIL"

echo ""
echo "BETA_GATE_RESULT=$result"
echo "BETA_GATE_PASS=${#passed[@]}/$total"
echo "BETA_GATE_FAILED=${failed[*]:-none}"

[[ "$result" == "PASS" ]]
