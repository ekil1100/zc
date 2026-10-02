#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ARCHIVE_ROOT="$ROOT_DIR/.agents/install/evidence"
HISTORY_DIR="$ARCHIVE_ROOT/history"
LATEST_LINK="$ARCHIVE_ROOT/latest"

missing=()

# 1) structure
[[ -d "$ARCHIVE_ROOT" ]] || missing+=("archive_root_missing")
[[ -d "$HISTORY_DIR" ]] || missing+=("history_dir_missing")
[[ -L "$LATEST_LINK" ]] || missing+=("latest_symlink_missing")

run_id=""
if [[ -L "$LATEST_LINK" ]]; then
  latest_target="$(readlink "$LATEST_LINK")"
  run_id="$(basename "$latest_target")"

  # 2) naming
  if [[ ! "$run_id" =~ ^beta-checklist-[0-9]{8}-[0-9]{6}$ ]]; then
    missing+=("latest_run_id_invalid")
  fi

  # 3) latest points into history
  if [[ "$latest_target" != *"/.agents/install/evidence/history/"* ]]; then
    # allow relative symlink if ends with history/<run_id>
    if [[ ! "$latest_target" =~ history/beta-checklist-[0-9]{8}-[0-9]{6}$ ]]; then
      missing+=("latest_target_outside_history")
    fi
  fi

  run_dir="$ARCHIVE_ROOT/history/$run_id"
  [[ -d "$run_dir" ]] || missing+=("latest_target_missing_dir")

  required_files=(
    summary.json
    A.install.out
    B.verify.out
    C.upgrade.out
    D.flow.out
    D.env.out
  )
  for f in "${required_files[@]}"; do
    [[ -f "$run_dir/$f" ]] || missing+=("missing_$f")
  done
fi

result="PASS"
[[ ${#missing[@]} -eq 0 ]] || result="FAIL"

echo "INSTALL_RESULT=$result"
echo "INSTALL_ACTION=evidence-archive-check"
echo "INSTALL_REPORT=$ARCHIVE_ROOT"
echo "INSTALL_FAILED_STEP=$(IFS=,; echo "${missing[*]:-}")"
if [[ "$result" == "PASS" ]]; then
  echo "INSTALL_NEXT_STEP=none"
else
  echo "INSTALL_NEXT_STEP=run: bash scripts/install/run-beta-checklist.sh, then rerun this check"
fi
echo "INSTALL_SUMMARY=evidence archive check result=$result missing=${missing[*]:-none}"

echo "EVIDENCE_ARCHIVE_RESULT=$result"
echo "EVIDENCE_ARCHIVE_MISSING=$(IFS=,; echo "${missing[*]:-}")"
echo "EVIDENCE_ARCHIVE_LATEST_RUN_ID=${run_id:-}"

[[ "$result" == "PASS" ]]
