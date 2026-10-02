#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
HISTORY="$ROOT/.agents/install/evidence/history"
INDEX_JSONL="$HISTORY/index.jsonl"
TIMELINE_MD="$HISTORY/timeline.md"
: > "$INDEX_JSONL"

for d in "$HISTORY"/beta-checklist-*; do
  [[ -d "$d" ]] || continue
  run_id="$(basename "$d")"
  summary="$d/summary.json"
  result="UNKNOWN"
  if [[ -f "$summary" ]]; then
    result="$(grep -E '"result"' "$summary" | head -n1 | sed -E 's/.*"result"\s*:\s*"([^"]+)".*/\1/')"
  fi
  ts="${run_id#beta-checklist-}"
  echo "{\"run_id\":\"$run_id\",\"time\":\"$ts\",\"result\":\"$result\",\"path\":\"$d\"}" >> "$INDEX_JSONL"
done

sort -r "$INDEX_JSONL" -o "$INDEX_JSONL"
{
  echo "# Evidence Timeline"
  while IFS= read -r line; do
    run_id="$(echo "$line" | sed -E 's/.*"run_id":"([^"]+)".*/\1/')"
    time="$(echo "$line" | sed -E 's/.*"time":"([^"]+)".*/\1/')"
    result="$(echo "$line" | sed -E 's/.*"result":"([^"]+)".*/\1/')"
    path="$(echo "$line" | sed -E 's/.*"path":"([^"]+)".*/\1/')"
    echo "- $run_id | $time | $result | $path"
  done < "$INDEX_JSONL"
} > "$TIMELINE_MD"

echo "INSTALL_RESULT=PASS"
echo "INSTALL_ACTION=evidence-index"
echo "INSTALL_REPORT=$INDEX_JSONL"
echo "INSTALL_FAILED_STEP="
echo "INSTALL_NEXT_STEP=none"
echo "INSTALL_SUMMARY=evidence index generated"
echo "EVIDENCE_INDEX_FILE=$INDEX_JSONL"
echo "EVIDENCE_TIMELINE_FILE=$TIMELINE_MD"
