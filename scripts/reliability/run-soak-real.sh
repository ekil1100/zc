#!/usr/bin/env bash
set -euo pipefail

# Real 24h/72h soak test runner
# Usage:
#   bash scripts/reliability/run-soak-real.sh 24 [--config <path>]
#   bash scripts/reliability/run-soak-real.sh 72 [--config <path>]

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
OUT_DIR="$ROOT_DIR/docs/perf/reports/history"
LOG_DIR="$ROOT_DIR/docs/reliability/soak-logs"
mkdir -p "$OUT_DIR" "$LOG_DIR"

HOURS="${1:-}"
shift || true
CONFIG_PATH=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config) CONFIG_PATH="${2:-}"; shift 2 ;;
    *) echo "Unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$HOURS" != "24" && "$HOURS" != "72" ]]; then
  echo "Usage: bash scripts/reliability/run-soak-real.sh <24|72> [--config <path>]" >&2
  exit 2
fi

# Resolve config
if [[ -z "$CONFIG_PATH" ]]; then
  for candidate in "$HOME/.config/zc/config.yaml" "$HOME/.zc/config.yaml" "$ROOT_DIR/config.yaml"; do
    if [[ -f "$candidate" ]]; then
      CONFIG_PATH="$candidate"
      break
    fi
  done
fi

if [[ -z "$CONFIG_PATH" || ! -f "$CONFIG_PATH" ]]; then
  echo "SOAK_RESULT=FAIL"
  echo "SOAK_FAILED_STEP=config-missing"
  echo "SOAK_NEXT_STEP=提供代理配置文件：--config <path>"
  exit 1
fi

RUN_ID="soak-${HOURS}h-$(date +%Y%m%d-%H%M%S)"
TS_START="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
SOAK_LOG="$LOG_DIR/$RUN_ID.log"
METRICS_LOG="$LOG_DIR/$RUN_ID-metrics.jsonl"
OUT_FILE="$OUT_DIR/$RUN_ID.json"
DURATION_SEC=$((HOURS * 3600))
SAMPLE_INTERVAL=300  # 5 minutes

echo "=== Soak test: ${HOURS}h ==="
echo "Config: $CONFIG_PATH"
echo "Log: $SOAK_LOG"
echo "Start: $TS_START"
echo ""

# Build if needed
if [[ ! -x "$ROOT_DIR/zig-out/bin/zc" ]]; then
  echo "Building zc..."
  (cd "$ROOT_DIR" && zig build) || { echo "SOAK_RESULT=FAIL"; echo "SOAK_FAILED_STEP=build"; exit 1; }
fi

# Start zc in background. --foreground keeps the daemon as this shell's
# child so the kill -0 "$ZCLASH_PID" liveness/crash checks below track the
# real daemon (default `zc start` is fork-and-exit: $! would die immediately).
"$ROOT_DIR/zig-out/bin/zc" start --foreground -c "$CONFIG_PATH" >> "$SOAK_LOG" 2>&1 &
ZCLASH_PID=$!
echo "zc started (PID: $ZCLASH_PID)"
sleep 2

# Verify it's running
if ! kill -0 "$ZCLASH_PID" 2>/dev/null; then
  echo "SOAK_RESULT=FAIL"
  echo "SOAK_FAILED_STEP=start-failed"
  echo "SOAK_NEXT_STEP=检查配置文件是否有效：zc doctor -c $CONFIG_PATH"
  exit 1
fi

# Monitoring loop
elapsed=0
samples=0
failures=0
crash_count=0

cleanup() {
  echo "Stopping zc (PID: $ZCLASH_PID)..."
  kill "$ZCLASH_PID" 2>/dev/null || true
  wait "$ZCLASH_PID" 2>/dev/null || true
}
trap cleanup EXIT

while [[ $elapsed -lt $DURATION_SEC ]]; do
  sleep "$SAMPLE_INTERVAL"
  elapsed=$((elapsed + SAMPLE_INTERVAL))
  samples=$((samples + 1))
  sample_ts="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

  # Check process alive
  if ! kill -0 "$ZCLASH_PID" 2>/dev/null; then
    crash_count=$((crash_count + 1))
    echo "{\"ts\":\"$sample_ts\",\"elapsed_s\":$elapsed,\"alive\":false,\"crash_count\":$crash_count}" >> "$METRICS_LOG"
    echo "[$sample_ts] CRASH detected (count: $crash_count), restarting..."
    "$ROOT_DIR/zig-out/bin/zc" start --foreground -c "$CONFIG_PATH" >> "$SOAK_LOG" 2>&1 &
    ZCLASH_PID=$!
    sleep 2
    continue
  fi

  # Check port listening (basic health).
  # `doctor --json` emits its envelope on stdout (one line); diagnostics go to
  # stderr and are discarded. The data payload (incl. "proxy_reachable") is
  # present on both the ok:true and CHECKS_FAILED envelopes.
  port_ok=false
  if "$ROOT_DIR/zig-out/bin/zc" doctor -c "$CONFIG_PATH" --json 2>/dev/null | grep -q '"proxy_reachable":true'; then
    port_ok=true
  fi

  echo "{\"ts\":\"$sample_ts\",\"elapsed_s\":$elapsed,\"alive\":true,\"port_ok\":$port_ok,\"crash_count\":$crash_count}" >> "$METRICS_LOG"

  if [[ "$port_ok" != "true" ]]; then
    failures=$((failures + 1))
  fi

  # Progress
  pct=$((elapsed * 100 / DURATION_SEC))
  echo "[$sample_ts] ${pct}% (${elapsed}s/${DURATION_SEC}s) alive=true port=$port_ok crashes=$crash_count"
done

TS_END="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# Determine result
result="PASS"
if [[ $crash_count -gt 0 ]]; then
  result="FAIL"
fi

cat > "$OUT_FILE" <<EOF
{
  "run_id": "$RUN_ID",
  "start": "$TS_START",
  "end": "$TS_END",
  "duration_hours": $HOURS,
  "status": "$result",
  "samples": $samples,
  "crashes": $crash_count,
  "port_failures": $failures,
  "config": "$CONFIG_PATH",
  "log": "$SOAK_LOG",
  "metrics": "$METRICS_LOG"
}
EOF

echo ""
echo "SOAK_RESULT=$result"
echo "SOAK_REPORT=$OUT_FILE"
echo "SOAK_CRASHES=$crash_count"
echo "SOAK_SAMPLES=$samples"
echo "SOAK_PORT_FAILURES=$failures"

[[ "$result" == "PASS" ]]
