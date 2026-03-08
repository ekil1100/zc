#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
steps=(
  "verify-install-flow.sh:flow"
  "verify-install-env.sh:env"
  "verify-install-path-matrix.sh:path"
  "verify-local-dev-install.sh:dev-install"
  "verify-rollback-flow.sh:rollback"
  "run-3step-smoke.sh:smoke"
  "run-beta-checklist.sh:evidence"
  "verify-evidence-archive.sh:evidence-check"
)

failed=()
for s in "${steps[@]}"; do
  script="${s%%:*}"; category="${s##*:}"
  out="/tmp/zc-all-${category}.out"
  if ! bash "$ROOT/$script" > "$out" 2>&1; then
    failed+=("$category")
  fi
done

result="PASS"; [[ ${#failed[@]} -eq 0 ]] || result="FAIL"
report="/tmp/zc-install-all-summary.json"
printf '{\n  "result":"%s",\n  "failed_categories":["%s"],\n  "steps":["%s"]\n}\n' \
  "$result" "$(IFS='","'; echo "${failed[*]:-}")" "$(IFS='","'; printf '%s' "${steps[*]%:*}")" > "$report"

echo "INSTALL_RESULT=$result"
echo "INSTALL_ACTION=all-regression"
echo "INSTALL_REPORT=$report"
echo "INSTALL_FAILED_STEP=$(IFS=,; echo "${failed[*]:-}")"
if [[ "$result" == "PASS" ]]; then
  echo "INSTALL_NEXT_STEP=none"
else
  echo "INSTALL_NEXT_STEP=查看失败分类并按对应脚本输出处理"
fi
echo "INSTALL_SUMMARY=all regression result=$result failed=${failed[*]:-none}"
echo "INSTALL_ALL_RESULT=$result"
echo "INSTALL_ALL_FAILED_CATEGORIES=$(IFS=,; echo "${failed[*]:-}")"

[[ "$result" == "PASS" ]]
