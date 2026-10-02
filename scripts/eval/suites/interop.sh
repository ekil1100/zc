#!/usr/bin/env bash
# Interop suite: delegate to local just e2e.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../lib.sh
source "$ROOT_DIR/scripts/eval/lib.sh"

RUN_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)
      [[ $# -ge 2 ]] || { printf 'interop: missing --run-dir value\n' >&2; exit 2; }
      RUN_DIR="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'HELP'
Usage: bash scripts/eval/suites/interop.sh --run-dir <dir>

Runs exactly:
  just e2e

Exit: 0 pass, 1 fail, 2 error (missing just)
HELP
      exit 0
      ;;
    *)
      printf 'interop: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
  printf 'interop: --run-dir must be an existing directory\n' >&2
  exit 2
fi

if ! command -v just >/dev/null 2>&1; then
  printf 'interop: just not found on PATH\n' >&2
  exit 2
fi

ARTIFACT_DIR="$RUN_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR" "$RUN_DIR/suites"
log_rel="artifacts/interop.log"
log="$RUN_DIR/$log_rel"

printf 'interop: running just e2e\n'
rc=0
(
  cd "$ROOT_DIR"
  just e2e
) >"$log" 2>&1 || rc=$?
printf 'interop: exit=%s log=%s\n' "$rc" "$log"

result="pass"
failed_json='[]'
if [[ $rc -ne 0 ]]; then
  result="fail"
  failed_json='["e2e"]'
fi

ts="$(eval_iso_timestamp)"
subject="$(eval_git_head)"
dirty="$(eval_worktree_dirty)"
env_json="$(eval_capture_env_json)"
report="$RUN_DIR/suites/interop.json"

json="$(jq -n \
  --arg run_id "$(basename "$RUN_DIR")" \
  --arg timestamp "$ts" \
  --arg subject "$subject" \
  --arg harness "$subject" \
  --argjson dirty "$dirty" \
  --argjson env "$env_json" \
  --arg result "$result" \
  --argjson code "$rc" \
  --argjson failed "$failed_json" \
  --arg log_rel "$log_rel" \
  '{
    schema_version: 1,
    kind: "suite",
    run_id: $run_id,
    timestamp: $timestamp,
    suite: "interop",
    scenarios: [],
    subject_commit: $subject,
    harness_commit: $harness,
    worktree_dirty: $dirty,
    env: $env,
    result: $result,
    metrics: {},
    omitted: [],
    failed: $failed,
    artifacts: [$log_rel],
    notes: [
      "local command is just e2e",
      "e2e-release remains owned by CI; this adapter does not attest PATH integrity"
    ],
    steps: [
      {name: "e2e", result: $result, exit_code: $code}
    ]
  }')"
if ! eval_write_report "$report" "$json"; then
  printf 'interop: failed to write validated suite report\n' >&2
  exit 2
fi

case "$result" in
  pass) exit 0 ;;
  fail) exit 1 ;;
  *) exit 2 ;;
esac
