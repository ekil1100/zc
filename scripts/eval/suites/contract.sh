#!/usr/bin/env bash
# Contract suite: migrator + install regression + S1/S2 scenarios (required).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../lib.sh
source "$ROOT_DIR/scripts/eval/lib.sh"

RUN_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)
      [[ $# -ge 2 ]] || { printf 'contract: missing --run-dir value\n' >&2; exit 2; }
      RUN_DIR="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'HELP'
Usage: bash scripts/eval/suites/contract.sh --run-dir <dir>

Runs all steps and aggregates:
  1. bash tools/config-migrator/run-all.sh
  2. bash scripts/install/run-all-regression.sh
  3. S1 startup scenario (required)
  4. S2 rule-matrix scenario (required)

Exit: 0 pass, 1 fail, 2 error
HELP
      exit 0
      ;;
    *)
      printf 'contract: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
  printf 'contract: --run-dir must be an existing directory\n' >&2
  exit 2
fi

ARTIFACT_DIR="$RUN_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR" "$RUN_DIR/suites"

steps_json='[]'
failed_json='[]'
artifacts_json='[]'
scenarios_json='[]'
notes_json='[]'
result="pass"

append_note() {
  notes_json="$(jq -c --arg n "$1" '. + [$n]' <<<"$notes_json")"
}

# Record a step. kind: ran | missing
# - missing dependency/script before execution => error
# - command found and executed with nonzero => fail
record_step() {
  local name="$1"
  local rc="$2"
  local log_rel="$3"
  local kind="${4:-ran}"
  local step_result="pass"

  if [[ "$kind" == "missing" ]]; then
    step_result="error"
    result="$(eval_merge_result "$result" error)"
    failed_json="$(jq -c --arg n "$name" '. + [$n]' <<<"$failed_json")"
  elif [[ $rc -ne 0 ]]; then
    step_result="fail"
    result="$(eval_merge_result "$result" fail)"
    failed_json="$(jq -c --arg n "$name" '. + [$n]' <<<"$failed_json")"
  fi

  steps_json="$(jq -c \
    --arg n "$name" \
    --arg r "$step_result" \
    --argjson code "$rc" \
    '. + [{name:$n, result:$r, exit_code:$code}]' <<<"$steps_json")"
  artifacts_json="$(jq -c --arg p "$log_rel" '. + [$p]' <<<"$artifacts_json")"
}

run_logged() {
  local name="$1"
  local log_rel="$2"
  shift 2
  local log="$RUN_DIR/$log_rel"
  local rc=0
  printf 'contract: running %s\n' "$name"
  (
    cd "$ROOT_DIR"
    "$@"
  ) >"$log" 2>&1 || rc=$?
  printf 'contract: %s exit=%s log=%s\n' "$name" "$rc" "$log"
  record_step "$name" "$rc" "$log_rel" ran
}

require_script() {
  local path="$1"
  if [[ ! -f "$path" ]]; then
    printf 'contract: missing required script: %s\n' "$path" >&2
    return 2
  fi
}

# --- migrator --------------------------------------------------------------
MIGRATOR_REPORTS=(
  tools/config-migrator/reports/samples-report.json
  tools/config-migrator/reports/samples-summary.json
)
MIGRATOR_BACKUP="$ARTIFACT_DIR/migrator-reports-backup"
mkdir -p "$MIGRATOR_BACKUP"
for rel in "${MIGRATOR_REPORTS[@]}"; do
  if [[ -f "$ROOT_DIR/$rel" ]]; then
    cp "$ROOT_DIR/$rel" "$MIGRATOR_BACKUP/$(basename "$rel")"
  fi
done

if ! require_script "$ROOT_DIR/tools/config-migrator/run-all.sh"; then
  printf 'contract: missing migrator entry\n' >"$ARTIFACT_DIR/contract-migrator.log"
  record_step migrator 2 "artifacts/contract-migrator.log" missing
else
  run_logged migrator artifacts/contract-migrator.log \
    bash tools/config-migrator/run-all.sh
  # Restore regenerable migrator report files from pre-run copies so a later
  # perf suite in the same eval run still sees a clean worktree.
  restore_failed=0
  for rel in "${MIGRATOR_REPORTS[@]}"; do
    base="$(basename "$rel")"
    if [[ -f "$MIGRATOR_BACKUP/$base" ]]; then
      if ! cp "$MIGRATOR_BACKUP/$base" "$ROOT_DIR/$rel"; then
        restore_failed=1
        printf 'contract: failed to restore %s\n' "$rel" >&2
      fi
    fi
  done
  if [[ $restore_failed -ne 0 ]]; then
    append_note "migrator report restore failed; worktree may be dirty for later perf"
    result="$(eval_merge_result "$result" error)"
  fi
fi

# --- install ---------------------------------------------------------------
if ! require_script "$ROOT_DIR/scripts/install/run-all-regression.sh"; then
  printf 'contract: missing install entry\n' >"$ARTIFACT_DIR/contract-install.log"
  record_step install 2 "artifacts/contract-install.log" missing
else
  run_logged install artifacts/contract-install.log \
    bash scripts/install/run-all-regression.sh
fi

# --- S1 (required) ---------------------------------------------------------
S1="$ROOT_DIR/scripts/eval/scenarios/s1_startup.sh"
scenarios_json="$(jq -c '. + ["s1_startup"]' <<<"$scenarios_json")"
if [[ ! -f "$S1" ]]; then
  printf 'contract: missing required scenario script: %s\n' "$S1" \
    >"$ARTIFACT_DIR/contract-s1.log"
  record_step s1_startup 2 "artifacts/contract-s1.log" missing
else
  zc_bin="$ROOT_DIR/zig-out/bin/zc"
  if [[ ! -x "$zc_bin" ]]; then
    build_rc=0
    (
      cd "$ROOT_DIR"
      zig build -Dcpu=baseline
    ) >"$ARTIFACT_DIR/contract-s1-build.log" 2>&1 || build_rc=$?
    if [[ $build_rc -ne 0 ]]; then
      record_step s1_startup "$build_rc" "artifacts/contract-s1-build.log" ran
      append_note "s1_startup: zig build failed"
    else
      run_logged s1_startup artifacts/contract-s1.log \
        bash "$S1" --zc "$zc_bin"
    fi
  else
    run_logged s1_startup artifacts/contract-s1.log \
      bash "$S1" --zc "$zc_bin"
  fi
fi

# --- S2 (required) ---------------------------------------------------------
S2="$ROOT_DIR/scripts/eval/scenarios/s2_rule_matrix.sh"
scenarios_json="$(jq -c '. + ["s2_rule_matrix"]' <<<"$scenarios_json")"
if [[ ! -f "$S2" ]]; then
  printf 'contract: missing required scenario script: %s\n' "$S2" \
    >"$ARTIFACT_DIR/contract-s2.log"
  record_step s2_rule_matrix 2 "artifacts/contract-s2.log" missing
else
  run_logged s2_rule_matrix artifacts/contract-s2.log \
    bash "$S2"
fi

ts="$(eval_iso_timestamp)"
subject="$(eval_git_head)"
dirty="$(eval_worktree_dirty)"
env_json="$(eval_capture_env_json)"
report="$RUN_DIR/suites/contract.json"

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
  --argjson scenarios "$scenarios_json" \
  --argjson notes "$notes_json" \
  '{
    schema_version: 1,
    kind: "suite",
    run_id: $run_id,
    timestamp: $timestamp,
    suite: "contract",
    scenarios: $scenarios,
    subject_commit: $subject,
    harness_commit: $harness,
    worktree_dirty: $dirty,
    env: $env,
    result: $result,
    metrics: {},
    omitted: [],
    failed: $failed,
    artifacts: $artifacts,
    notes: $notes,
    steps: $steps
  }')"

if ! eval_write_report "$report" "$json"; then
  printf 'contract: failed to write validated suite report\n' >&2
  exit 2
fi

case "$result" in
  pass) exit 0 ;;
  fail) exit 1 ;;
  *) exit 2 ;;
esac
