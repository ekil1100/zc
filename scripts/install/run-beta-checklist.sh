#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
RUNNER="$ROOT_DIR/scripts/install/oc-run.sh"
FLOW_REG="$ROOT_DIR/scripts/install/verify-install-flow.sh"
ENV_REG="$ROOT_DIR/scripts/install/verify-install-env.sh"

TARGET_DIR="/tmp/zc-beta"
OUT_DIR="/tmp/zc-beta-checklist"
ARCHIVE_ROOT="$ROOT_DIR/.agents/install/evidence/history"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target-dir)
      TARGET_DIR="${2:-}"
      shift 2
      ;;
    --archive-root)
      ARCHIVE_ROOT="${2:-}"
      shift 2
      ;;
    *)
      echo "BETA_CHECKLIST_RESULT=FAIL"
      echo "BETA_CHECKLIST_FAILED_STEP=arg-parse"
      echo "BETA_CHECKLIST_NEXT_STEP=use: run-beta-checklist.sh [--target-dir <path>] [--archive-root <path>]"
      exit 2
      ;;
  esac
done

mkdir -p "$OUT_DIR" "$ARCHIVE_ROOT"

RUN_ID="beta-checklist-$(date +%Y%m%d-%H%M%S)"
ARCHIVE_DIR="$ARCHIVE_ROOT/$RUN_ID"
mkdir -p "$ARCHIVE_DIR"

items=()
failed=()

record_item() {
  local id="$1" result="$2" evidence="$3" note="$4"
  items+=("{\"id\":\"$id\",\"result\":\"$result\",\"evidence\":\"$evidence\",\"note\":\"$note\"}")
  [[ "$result" == "PASS" ]] || failed+=("$id")
}

# A install
A_OUT="$OUT_DIR/A.install.out"
if bash "$RUNNER" install --target-dir "$TARGET_DIR" > "$A_OUT" 2>&1 \
  && grep -q 'INSTALL_RESULT=PASS' "$A_OUT" \
  && [[ -f "$TARGET_DIR/.zc_installed" ]] \
  && [[ -f "$TARGET_DIR/.zc_version" ]]; then
  record_item "A_install" "PASS" "$TARGET_DIR/.zc_installed,$TARGET_DIR/.zc_version" "install passed"
else
  record_item "A_install" "FAIL" "$A_OUT" "run install and check permission/path"
fi

# B verify
B_OUT="$OUT_DIR/B.verify.out"
if bash "$RUNNER" verify --target-dir "$TARGET_DIR" > "$B_OUT" 2>&1 \
  && grep -q 'INSTALL_RESULT=PASS' "$B_OUT" \
  && grep -q 'INSTALL_ACTION=verify' "$B_OUT"; then
  record_item "B_verify" "PASS" "$TARGET_DIR/.zc_installed" "verify passed"
else
  record_item "B_verify" "FAIL" "$B_OUT" "run install first then verify"
fi

# C upgrade
C_OUT="$OUT_DIR/C.upgrade.out"
if bash "$RUNNER" upgrade --target-dir "$TARGET_DIR" --version v0.2.0 > "$C_OUT" 2>&1 \
  && grep -q 'INSTALL_RESULT=PASS' "$C_OUT" \
  && grep -q '^v0.2.0$' "$TARGET_DIR/.zc_version"; then
  record_item "C_upgrade" "PASS" "$TARGET_DIR/.zc_version" "upgrade passed"
else
  record_item "C_upgrade" "FAIL" "$C_OUT" "retry upgrade with --version"
fi

# D failures + rollback operability through regressions
D1_OUT="$OUT_DIR/D.flow.out"
D2_OUT="$OUT_DIR/D.env.out"
if bash "$FLOW_REG" > "$D1_OUT" 2>&1 \
  && bash "$ENV_REG" > "$D2_OUT" 2>&1 \
  && grep -q 'INSTALL_FLOW_REGRESSION=PASS' "$D1_OUT" \
  && grep -q 'INSTALL_ENV_REGRESSION_RESULT=PASS' "$D2_OUT"; then
  record_item "D_failure_rollback" "PASS" "/tmp/zc-install-regression,/tmp/zc-install-env/install-env-summary.json" "failure+rollback checks passed"
else
  record_item "D_failure_rollback" "FAIL" "$D1_OUT,$D2_OUT" "inspect failed samples and next-step fields"
fi

total=${#items[@]}
pass=$((total - ${#failed[@]}))
rate=$(( pass * 100 / total ))
result="PASS"
[[ ${#failed[@]} -eq 0 ]] || result="FAIL"

REPORT="$OUT_DIR/summary.json"
printf '{\n  "run_id": "%s",\n  "result": "%s",\n  "pass_count": %d,\n  "total_count": %d,\n  "pass_rate": %d,\n  "failed_items": ["%s"],\n  "items": [\n    %s\n  ]\n}\n' \
  "$RUN_ID" "$result" "$pass" "$total" "$rate" "$(IFS='\",\"'; echo "${failed[*]:-}")" "$(IFS=,; echo "${items[*]}")" > "$REPORT"

cp "$A_OUT" "$ARCHIVE_DIR/"
cp "$B_OUT" "$ARCHIVE_DIR/"
cp "$C_OUT" "$ARCHIVE_DIR/"
cp "$D1_OUT" "$ARCHIVE_DIR/"
cp "$D2_OUT" "$ARCHIVE_DIR/"
cp "$REPORT" "$ARCHIVE_DIR/summary.json"

LATEST_LINK="$ROOT_DIR/.agents/install/evidence/latest"
rm -rf "$LATEST_LINK"
ln -s "$ARCHIVE_DIR" "$LATEST_LINK"

# machine fields
echo "BETA_CHECKLIST_RESULT=$result"
echo "BETA_CHECKLIST_PASS_RATE=$rate"
echo "BETA_CHECKLIST_FAILED_ITEMS=$(IFS=,; echo "${failed[*]:-}")"
echo "BETA_CHECKLIST_REPORT=$ARCHIVE_DIR/summary.json"
echo "BETA_CHECKLIST_EVIDENCE=$TARGET_DIR,/tmp/zc-install-regression,/tmp/zc-install-env/install-env-summary.json"
echo "BETA_CHECKLIST_ARCHIVE_DIR=$ARCHIVE_DIR"

# human summary
echo "BETA_CHECKLIST_SUMMARY=beta checklist $pass/$total passed (${rate}%), failed_items=${failed[*]:-none}, archive=$ARCHIVE_DIR"

[[ "$result" == "PASS" ]]
