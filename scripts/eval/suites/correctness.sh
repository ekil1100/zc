#!/usr/bin/env bash
# Correctness suite: zig build + zig build test (baseline cpu).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../lib.sh
source "$ROOT_DIR/scripts/eval/lib.sh"

RUN_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)
      [[ $# -ge 2 ]] || { printf 'correctness: missing --run-dir value\n' >&2; exit 2; }
      RUN_DIR="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'HELP'
Usage: bash scripts/eval/suites/correctness.sh --run-dir <dir>

Runs:
  zig build -Dcpu=baseline
  zig build test -Dcpu=baseline

Exit: 0 pass, 1 fail, 2 error
HELP
      exit 0
      ;;
    *)
      printf 'correctness: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
  printf 'correctness: --run-dir must be an existing directory\n' >&2
  exit 2
fi

if ! command -v zig >/dev/null 2>&1; then
  printf 'correctness: zig not found on PATH\n' >&2
  exit 2
fi

ARTIFACT_DIR="$RUN_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR" "$RUN_DIR/suites"

run_step() {
  local name="$1"
  shift
  local log="$ARTIFACT_DIR/correctness-${name}.log"
  local rc=0
  printf 'correctness: running %s: %s\n' "$name" "$*"
  (
    cd "$ROOT_DIR"
    "$@"
  ) >"$log" 2>&1 || rc=$?
  printf 'correctness: %s exit=%s log=%s\n' "$name" "$rc" "$log"
  return "$rc"
}

build_rc=0
test_rc=0
run_step build zig build -Dcpu=baseline || build_rc=$?
run_step test zig build test -Dcpu=baseline || test_rc=$?

steps_json='[]'
failed_json='[]'
artifacts_json='[]'
result="pass"

add_step() {
  local name="$1"
  local rc="$2"
  local step_result="pass"
  if [[ $rc -ne 0 ]]; then
    step_result="fail"
    result="fail"
    failed_json="$(jq -c --arg n "$name" '. + [$n]' <<<"$failed_json")"
  fi
  steps_json="$(jq -c --arg n "$name" --arg r "$step_result" --argjson code "$rc" \
    '. + [{name:$n, result:$r, exit_code:$code}]' <<<"$steps_json")"
  artifacts_json="$(jq -c --arg p "artifacts/correctness-${name}.log" \
    '. + [$p]' <<<"$artifacts_json")"
}

add_step build "$build_rc"
add_step test "$test_rc"

ts="$(eval_iso_timestamp)"
subject="$(eval_git_head)"
dirty="$(eval_worktree_dirty)"
env_json="$(eval_capture_env_json)"
report="$RUN_DIR/suites/correctness.json"

json="$(jq -n \
  --arg run_id "$(basename "$RUN_DIR")" \
  --arg timestamp "$ts" \
  --arg subject "$subject" \
  --arg harness "$subject" \
  --argjson dirty "$dirty" \
  --argjson env "$env_json" \
  --arg result "$result" \
  --argjson steps "$steps_json" \
  --argjson failed "$failed_json" \
  --argjson artifacts "$artifacts_json" \
  '{
    schema_version: 1,
    kind: "suite",
    run_id: $run_id,
    timestamp: $timestamp,
    suite: "correctness",
    scenarios: [],
    subject_commit: $subject,
    harness_commit: $harness,
    worktree_dirty: $dirty,
    env: $env,
    result: $result,
    metrics: {},
    omitted: [],
    failed: $failed,
    artifacts: $artifacts,
    notes: [],
    steps: $steps
  }')"
if ! eval_write_report "$report" "$json"; then
  printf 'correctness: failed to write validated suite report\n' >&2
  exit 2
fi

case "$result" in
  pass) exit 0 ;;
  fail) exit 1 ;;
  *) exit 2 ;;
esac
