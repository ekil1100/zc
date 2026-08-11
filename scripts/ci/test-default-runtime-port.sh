#!/usr/bin/env bash
set -euo pipefail

fail() {
  printf 'DEFAULT_RUNTIME_PORT=FAIL detail=%s\n' "$1" >&2
  exit 1
}

if [[ "${CI:-}" != "true" ]]; then
  fail "this test binds production port 7899 and may only run in isolated CI"
fi
if [[ $# -ne 1 ]]; then
  fail "usage: test-default-runtime-port.sh <zc-binary>"
fi

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
ZC_BIN="$1"
[[ -x "$ZC_BIN" ]] || fail "zc binary is not executable: $ZC_BIN"
ZC_BIN="$(cd "$(dirname "$ZC_BIN")" && pwd)/$(basename "$ZC_BIN")"

WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zc-default-port.XXXXXX")"
HOME_DIR="$WORK_DIR/home"
RUNTIME_DIR="$WORK_DIR/run"
CONFIG_DIR="$WORK_DIR/config"
CONFIG_PATH="$CONFIG_DIR/default-port.yaml"
mkdir -p "$HOME_DIR" "$RUNTIME_DIR" "$CONFIG_DIR" "$WORK_DIR/state" "$WORK_DIR/cache"
chmod 700 "$HOME_DIR" "$RUNTIME_DIR" "$WORK_DIR/state" "$WORK_DIR/cache"

export HOME="$HOME_DIR"
export XDG_CONFIG_HOME="$CONFIG_DIR/xdg"
export XDG_RUNTIME_DIR="$RUNTIME_DIR"
export XDG_STATE_HOME="$WORK_DIR/state"
export XDG_CACHE_HOME="$WORK_DIR/cache"

cleanup() {
  local exit_code=$?
  trap - EXIT INT TERM
  "$ZC_BIN" stop --json >/dev/null 2>&1 || true
  local status_output=""
  status_output=$("$ZC_BIN" status --json 2>/dev/null || true)
  local daemon_pid=""
  daemon_pid=$(python3 -c '
import json, sys
try:
    print(json.load(sys.stdin).get("data", {}).get("pid") or "")
except Exception:
    print("")
' <<<"$status_output")
  if [[ -n "$daemon_pid" ]] && kill -0 "$daemon_pid" >/dev/null 2>&1; then
    kill -9 "$daemon_pid" >/dev/null 2>&1 || true
  fi
  if [[ $exit_code -eq 0 ]]; then
    rm -rf "$WORK_DIR"
  else
    printf 'DEFAULT_RUNTIME_PORT_WORK_DIR=%s\n' "$WORK_DIR" >&2
    find "$WORK_DIR" -maxdepth 4 -type f -print >&2 || true
  fi
  exit "$exit_code"
}
trap cleanup EXIT INT TERM

tcp_is_open() {
  local port="$1"
  (exec 3<>"/dev/tcp/127.0.0.1/$port") >/dev/null 2>&1
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
  fail "port $port did not become $expected"
}

assert_ok_json() {
  local command_name="$1"
  local payload="$2"
  python3 -c '
import json, sys
command_name = sys.argv[1]
value = json.load(sys.stdin)
if value.get("ok") is not True:
    raise SystemExit(f"{command_name} returned a failure envelope: {value}")
' "$command_name" <<<"$payload" || fail "$command_name did not return ok:true"
}

status_pid() {
  local payload="$1"
  python3 -c '
import json, sys
value = json.load(sys.stdin)
if value.get("ok") is not True or value.get("data", {}).get("state") != "running":
    raise SystemExit(f"daemon is not running: {value}")
pid = value.get("data", {}).get("pid")
if not isinstance(pid, int) or pid <= 0:
    raise SystemExit(f"invalid daemon pid: {value}")
print(pid)
' <<<"$payload"
}

assert_doctor_port() {
  local payload="$1"
  python3 -c '
import json, sys
value = json.load(sys.stdin)
ports = value.get("data", {}).get("ports", [])
matches = [item for item in ports if item.get("label") == "mixed"]
if len(matches) != 1:
    raise SystemExit(f"expected one mixed port: {value}")
port = matches[0]
if port.get("port") != 7899 or port.get("listening") is not True:
    raise SystemExit(f"doctor did not observe mixed:7899 listening: {value}")
' <<<"$payload" || fail "doctor port report disagrees with the listener"
}

if tcp_is_open 7899; then
  fail "production port 7899 is already occupied"
fi
if tcp_is_open 7892; then
  fail "configured probe port 7892 is already occupied"
fi

controller_port=$(python3 -c '
import socket
sock = socket.socket()
sock.bind(("127.0.0.1", 0))
print(sock.getsockname()[1])
sock.close()
')
cp "$ROOT_DIR/testdata/config/minimal.yaml" "$CONFIG_PATH"
printf '\nexternal-controller: "127.0.0.1:%s"\n' "$controller_port" >>"$CONFIG_PATH"

start_output=$("$ZC_BIN" start -c "$CONFIG_PATH" --json)
assert_ok_json "start" "$start_output"
wait_for_tcp_state 7899 open
wait_for_tcp_state 7892 closed

status_output=$("$ZC_BIN" status --json)
first_pid=$(status_pid "$status_output")

doctor_output=$("$ZC_BIN" doctor -c "$CONFIG_PATH" --json 2>/dev/null || true)
assert_doctor_port "$doctor_output"

reload_output=$("$ZC_BIN" reload --json)
assert_ok_json "reload" "$reload_output"
wait_for_tcp_state 7899 open
wait_for_tcp_state 7892 closed

restart_output=$("$ZC_BIN" restart --json)
assert_ok_json "restart" "$restart_output"
wait_for_tcp_state 7899 open
wait_for_tcp_state 7892 closed

status_output=$("$ZC_BIN" status --json)
second_pid=$(status_pid "$status_output")
[[ "$second_pid" != "$first_pid" ]] || fail "restart did not replace the daemon process"

doctor_output=$("$ZC_BIN" doctor -c "$CONFIG_PATH" --json 2>/dev/null || true)
assert_doctor_port "$doctor_output"

stop_output=$("$ZC_BIN" stop --json)
assert_ok_json "stop" "$stop_output"
wait_for_tcp_state 7899 closed

printf 'DEFAULT_RUNTIME_PORT=PASS port=7899 configured_port=7892 first_pid=%s second_pid=%s\n' \
  "$first_pid" "$second_pid"
