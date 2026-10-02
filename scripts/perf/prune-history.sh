#!/usr/bin/env bash
set -euo pipefail

# Prune .agents/perf/reports/history/*.json while keeping latest N files.
# NOTE: latest.json is never touched.

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
HISTORY_DIR="$ROOT_DIR/.agents/perf/reports/history"
KEEP="${1:-30}"

if ! [[ "$KEEP" =~ ^[0-9]+$ ]] || [[ "$KEEP" -lt 1 ]]; then
  echo "Usage: bash scripts/perf/prune-history.sh [keep_count>=1]" >&2
  exit 2
fi

mkdir -p "$HISTORY_DIR"

# shellcheck disable=SC2012
files="$(ls -1t "$HISTORY_DIR"/*.json 2>/dev/null || true)"
count=$(printf '%s\n' "$files" | sed '/^$/d' | wc -l | tr -d ' ')

if [[ "$count" -le "$KEEP" ]]; then
  echo "PERF_HISTORY_PRUNE=PASS"
  echo "PERF_HISTORY_PRUNE_KEPT=$count"
  echo "PERF_HISTORY_PRUNE_REMOVED=0"
  echo "PERF_HISTORY_PRUNE_NOTE=latest.json untouched"
  exit 0
fi

remove_count=$((count - KEEP))
printf '%s\n' "$files" | sed '/^$/d' | tail -n +$((KEEP + 1)) | while IFS= read -r f; do
  rm -f "$f"
done

echo "PERF_HISTORY_PRUNE=PASS"
echo "PERF_HISTORY_PRUNE_KEPT=$KEEP"
echo "PERF_HISTORY_PRUNE_REMOVED=$remove_count"
echo "PERF_HISTORY_PRUNE_NOTE=latest.json untouched"
