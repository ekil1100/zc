#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HISTORY="$ROOT/.agents/install/evidence/history"
LATEST="$ROOT/.agents/install/evidence/latest"
INDEX="$HISTORY/index.jsonl"
missing=()
[[ -f "$INDEX" ]] || missing+=("index_missing")
[[ -L "$LATEST" ]] || missing+=("latest_missing")
if [[ -f "$INDEX" && -L "$LATEST" ]]; then
  latest_id="$(basename "$(readlink "$LATEST")")"
  head_id="$(head -n1 "$INDEX" | sed -E 's/.*"run_id":"([^"]+)".*/\1/')"
  [[ "$latest_id" == "$head_id" ]] || missing+=("latest_index_mismatch")
fi
result="PASS"; [[ ${#missing[@]} -eq 0 ]] || result="FAIL"
echo "INSTALL_RESULT=$result"
echo "INSTALL_ACTION=evidence-index-check"
echo "INSTALL_REPORT=$INDEX"
echo "INSTALL_FAILED_STEP=$(IFS=,; echo "${missing[*]:-}")"
[[ "$result" == "PASS" ]] && echo "INSTALL_NEXT_STEP=none" || echo "INSTALL_NEXT_STEP=先执行 generate-evidence-index.sh 并确认 latest 指向最新 run"
echo "INSTALL_SUMMARY=evidence index check result=$result missing=${missing[*]:-none}"
[[ "$result" == "PASS" ]]
