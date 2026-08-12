#!/usr/bin/env bash
# S1: isolated startup / status / stop scenario (no public internet).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd -P)"
ZC_BIN=""
EXPECT_PATH="$ROOT_DIR/testdata/eval/scenarios/s1_startup/expect.json"
CONFIG_PATH="$ROOT_DIR/testdata/config/minimal.yaml"
FORBIDDEN_PORT=7899

usage() {
  cat <<'HELP'
Usage: bash scripts/eval/scenarios/s1_startup.sh --zc <path> [--expect <path>]

Starts zc with an isolated HOME/XDG_RUNTIME_DIR on a free non-7899 loopback
port, asserts status running, then stops and asserts the port closes.
HELP
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --zc)
      [[ $# -ge 2 ]] || { printf 's1: missing --zc value\n' >&2; exit 2; }
      ZC_BIN="$2"
      shift 2
      ;;
    --expect)
      [[ $# -ge 2 ]] || { printf 's1: missing --expect value\n' >&2; exit 2; }
      EXPECT_PATH="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      printf 's1: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

fail() {
  printf 'S1_STARTUP_RESULT=FAIL\n' >&2
  printf 's1: %s\n' "$1" >&2
  exit 1
}

[[ -n "$ZC_BIN" ]] || fail "--zc is required"
[[ -x "$ZC_BIN" ]] || fail "zc binary is not executable: $ZC_BIN"
[[ -f "$CONFIG_PATH" ]] || fail "missing config: $CONFIG_PATH"
[[ -f "$EXPECT_PATH" ]] || fail "missing expect: $EXPECT_PATH"

ZC_BIN="$(cd "$(dirname "$ZC_BIN")" && pwd)/$(basename "$ZC_BIN")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zc-eval-s1.XXXXXX")"
HOME_DIR="$WORK_DIR/home"
RUNTIME_DIR="$WORK_DIR/run"
mkdir -p "$HOME_DIR" "$RUNTIME_DIR" "$WORK_DIR/state" "$WORK_DIR/cache" "$WORK_DIR/config"
chmod 700 "$HOME_DIR" "$RUNTIME_DIR" "$WORK_DIR/state" "$WORK_DIR/cache"
# Canonicalize: macOS TMPDIR often lives under /var -> /private/var.
HOME_DIR="$(cd "$HOME_DIR" && pwd -P)"
RUNTIME_DIR="$(cd "$RUNTIME_DIR" && pwd -P)"
WORK_DIR="$(cd "$WORK_DIR" && pwd -P)"
CONFIG_HOME="$(cd "$WORK_DIR/config" && pwd -P)"
STATE_HOME="$(cd "$WORK_DIR/state" && pwd -P)"
CACHE_HOME="$(cd "$WORK_DIR/cache" && pwd -P)"

export HOME="$HOME_DIR"
export XDG_CONFIG_HOME="$CONFIG_HOME"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export XDG_STATE_HOME="$STATE_HOME"
export XDG_CACHE_HOME="$CACHE_HOME"

PORT=""
STARTED=0

tcp_is_open() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
}

pick_free_port() {
  local candidate attempt
  for attempt in $(seq 1 40); do
    # Prefer high ephemeral-ish loopback ports; never 7899.
    candidate=$((18000 + (attempt * 37 + RANDOM % 200) % 20000))
    if [[ "$candidate" -eq "$FORBIDDEN_PORT" ]]; then
      continue
    fi
    if tcp_is_open "$candidate"; then
      continue
    fi
    PORT="$candidate"
    return 0
  done
  return 1
}

wait_for_tcp_state() {
  local port="$1"
  local expected="$2"
  local attempt=0
  while [[ $attempt -lt 100 ]]; do
    if tcp_is_open "$port"; then
      [[ "$expected" == "open" ]] && return 0
    else
      [[ "$expected" == "closed" ]] && return 0
    fi
    attempt=$((attempt + 1))
    sleep 0.05
  done
  return 1
}

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  if [[ -x "$ZC_BIN" ]]; then
    HOME="$HOME_DIR" \
      XDG_CONFIG_HOME="$CONFIG_HOME" \
      XDG_RUNTIME_DIR="$RUNTIME_DIR" \
      XDG_STATE_HOME="$STATE_HOME" \
      XDG_CACHE_HOME="$CACHE_HOME" \
      "$ZC_BIN" stop --json >/dev/null 2>&1 || true
  fi
  if [[ -n "$PORT" ]]; then
    wait_for_tcp_state "$PORT" closed || true
  fi
  rm -rf "$WORK_DIR"
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

# Explicit rejection of production port.
if [[ "${S1_FORCE_PORT:-}" == "$FORBIDDEN_PORT" ]]; then
  fail "port $FORBIDDEN_PORT is forbidden for local eval scenarios"
fi

pick_free_port || fail "could not find a free non-$FORBIDDEN_PORT loopback port"
if [[ "$PORT" -eq "$FORBIDDEN_PORT" ]]; then
  fail "refusing forbidden port $FORBIDDEN_PORT"
fi

EXPECTED_STATE="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["state"])' "$EXPECT_PATH")"
EXPECTED_OK="$(python3 -c 'import json,sys; print("true" if json.load(open(sys.argv[1])).get("ok") is True else "false")' "$EXPECT_PATH")"

start_out=""
start_err="$WORK_DIR/start.err"
set +e
start_out="$("$ZC_BIN" start -c "$CONFIG_PATH" --port "$PORT" --json 2>"$start_err")"
start_rc=$?
set -e
if [[ $start_rc -ne 0 ]]; then
  printf '%s\n' "$start_out" >&2
  cat "$start_err" >&2 || true
  fail "zc start failed (rc=$start_rc); not auto-falling back to another port"
fi
STARTED=1

python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
if payload.get("ok") is not True:
    raise SystemExit(f"start envelope not ok: {payload}")
data = payload.get("data") or {}
if data.get("state") != "running":
    raise SystemExit(f"start state not running: {payload}")
' "$start_out" || fail "start json assertion failed"

status_out=""
set +e
status_out="$("$ZC_BIN" status --json 2>/dev/null)"
status_rc=$?
set -e
[[ $status_rc -eq 0 ]] || fail "status failed rc=$status_rc: $status_out"

python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
expect_ok = sys.argv[2] == "true"
expect_state = sys.argv[3]
ok = payload.get("ok") is True
state = (payload.get("data") or {}).get("state")
if ok != expect_ok or state != expect_state:
    raise SystemExit(f"status mismatch ok={ok} state={state} expected ok={expect_ok} state={expect_state}: {payload}")
' "$status_out" "$EXPECTED_OK" "$EXPECTED_STATE" || fail "status did not match expect.json"

wait_for_tcp_state "$PORT" open || fail "port $PORT did not open after start"

stop_out=""
set +e
stop_out="$("$ZC_BIN" stop --json 2>/dev/null)"
stop_rc=$?
set -e
[[ $stop_rc -eq 0 ]] || fail "stop failed rc=$stop_rc: $stop_out"
STARTED=0

wait_for_tcp_state "$PORT" closed || fail "port $PORT did not close after stop"

set +e
final_status="$("$ZC_BIN" status --json 2>/dev/null)"
final_rc=$?
set -e
[[ $final_rc -eq 0 ]] || fail "final status failed rc=$final_rc: $final_status"
python3 -c '
import json, sys
payload = json.loads(sys.argv[1])
state = (payload.get("data") or {}).get("state")
if state != "stopped":
    raise SystemExit(f"expected state=stopped after stop, got {state!r}: {payload}")
' "$final_status" || fail "daemon not stopped after stop"

printf 'S1_STARTUP_RESULT=PASS\n'
printf 'S1_STARTUP_PORT=%s\n' "$PORT"
exit 0
