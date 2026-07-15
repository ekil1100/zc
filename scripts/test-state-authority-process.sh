#!/usr/bin/env bash
set -euo pipefail
umask 000

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <state-authority-process-test-exe>" >&2
  exit 2
fi

EXE="$1"
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/zc-authority.XXXXXX")"
PIDS=()
cleanup() {
  for pid in "${PIDS[@]:-}"; do
    [[ -n "$pid" ]] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  rm -rf "$ROOT"
}
trap cleanup EXIT

wait_for_file() {
  local path="$1"
  for _ in $(seq 1 500); do
    [[ -e "$path" ]] && return 0
    sleep 0.01
  done
  echo "timed out waiting for $path" >&2
  return 1
}

wait_for_exit() {
  local pid="$1"
  for _ in $(seq 1 500); do
    kill -0 "$pid" 2>/dev/null || { wait "$pid"; return $?; }
    sleep 0.01
  done
  echo "timed out waiting for process $pid" >&2
  return 1
}

REV_A="00112233445566778899aabbccddeeff"
REV_B="ffeeddccbbaa99887766554433221100"
LOCK_READY="$ROOT/lock-ready"
A_READY="$ROOT/a-ready"
B_READY="$ROOT/b-ready"

# Hold the exact production lock before workers reach Authority.commit.
"$EXE" hold-lock "$ROOT" "$LOCK_READY" &
holder=$!
PIDS+=("$holder")
wait_for_file "$LOCK_READY"
[[ "$("$EXE" probe-lock "$ROOT")" == "blocked" ]] || {
  echo "lock probe did not block" >&2
  exit 1
}

"$EXE" cas "$ROOT" home missing "$REV_A" "$A_READY" >"$ROOT/a.out" &
a_pid=$!
PIDS+=("$a_pid")
"$EXE" cas "$ROOT" home missing "$REV_B" "$B_READY" >"$ROOT/b.out" &
b_pid=$!
PIDS+=("$b_pid")
wait_for_file "$A_READY"
wait_for_file "$B_READY"

# Both workers reported immediately before Authority.commit. They must remain
# blocked while the holder owns the production lock.
sleep 0.1
kill -0 "$a_pid"
kill -0 "$b_pid"
[[ ! -s "$ROOT/a.out" && ! -s "$ROOT/b.out" ]] || {
  echo "Authority.commit was not blocked by the production lock" >&2
  exit 1
}

kill "$holder"
wait "$holder" 2>/dev/null || true
PIDS=("$a_pid" "$b_pid")
wait_for_exit "$a_pid"
wait_for_exit "$b_pid"
PIDS=()

committed=$(cat "$ROOT/a.out" "$ROOT/b.out" | grep -c '^committed$')
conflicts=$(cat "$ROOT/a.out" "$ROOT/b.out" | grep -c '^conflict$')
[[ "$committed" -eq 1 && "$conflicts" -eq 1 ]] || {
  echo "expected one committed and one conflict" >&2
  cat "$ROOT/a.out" "$ROOT/b.out" >&2
  exit 1
}

jq -e \
  --arg a "$REV_A" \
  --arg b "$REV_B" \
  '.schema_version == 1 and
   .sequence == 1 and
   (.profiles | length) == 1 and
   .profiles[0].key == "home" and
   (.profiles[0].head == $a or .profiles[0].head == $b)' \
  "$ROOT/state-v2.json" >/dev/null

[[ "$("$EXE" probe-lock "$ROOT")" == "acquired" ]] || {
  echo "lock was not released after holder exit" >&2
  exit 1
}

echo "STATE_AUTHORITY_PROCESS_TEST=PASS"
