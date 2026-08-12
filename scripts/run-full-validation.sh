#!/usr/bin/env bash
set -euo pipefail

# 全链路一键验证：install regression + migrator regression + beta gate
# 用法：just validate
# 等价：bash scripts/run-full-validation.sh

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

failed=()
passed=()

run_step() {
  local name="$1"
  shift
  echo "=== [$name] ==="
  if "$@" >/dev/null 2>&1; then
    passed+=("$name")
    echo "  PASS"
  else
    failed+=("$name")
    echo "  FAIL"
  fi
}

run_step "install-regression" bash scripts/install/run-all-regression.sh
run_step "migrator-regression" bash tools/config-migrator/run-all.sh
run_step "beta-gate" bash scripts/run-beta-gate.sh

total=$(( ${#passed[@]} + ${#failed[@]} ))
result="PASS"
[[ ${#failed[@]} -eq 0 ]] || result="FAIL"

echo ""
echo "VALIDATION_RESULT=$result"
echo "VALIDATION_PASS=${#passed[@]}/$total"
echo "VALIDATION_FAILED_STEPS=${failed[*]:-none}"
echo "VALIDATION_NEXT_STEP=$(if [[ "$result" == "PASS" ]]; then echo "全部通过，可继续发布流程"; else echo "修复失败项后重新运行"; fi)"

[[ "$result" == "PASS" ]]
