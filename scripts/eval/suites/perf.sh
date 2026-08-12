#!/usr/bin/env bash
# Perf suite: record control-plane evidence (no threshold judgment).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../../.." && pwd -P)"
# shellcheck source=../lib.sh
source "$ROOT_DIR/scripts/eval/lib.sh"

RUN_DIR=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --run-dir)
      [[ $# -ge 2 ]] || { printf 'perf: missing --run-dir value\n' >&2; exit 2; }
      RUN_DIR="$2"
      shift 2
      ;;
    -h|--help)
      cat <<'HELP'
Usage: bash scripts/eval/suites/perf.sh --run-dir <dir>

Records control-plane measurements via:
  bash scripts/perf/run-control-plane-baseline.sh --output <run>/artifacts/control-plane.json

pass  = record succeeded (facts written); NOT a threshold pass
error = dirty worktree / missing tool / recorder refused
fail  = recorder ran but measurement validation failed

Exit: 0 pass, 1 fail, 2 error
HELP
      exit 0
      ;;
    *)
      printf 'perf: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

if [[ -z "$RUN_DIR" || ! -d "$RUN_DIR" ]]; then
  printf 'perf: --run-dir must be an existing directory\n' >&2
  exit 2
fi

RECORDER="$ROOT_DIR/scripts/perf/run-control-plane-baseline.sh"
if [[ ! -f "$RECORDER" ]]; then
  printf 'perf: missing recorder: %s\n' "$RECORDER" >&2
  exit 2
fi

ARTIFACT_DIR="$RUN_DIR/artifacts"
mkdir -p "$ARTIFACT_DIR" "$RUN_DIR/suites"
measure_rel="artifacts/control-plane.json"
measure_path="$RUN_DIR/$measure_rel"
log_rel="artifacts/perf-record.log"
log_path="$RUN_DIR/$log_rel"

dirty="$(eval_worktree_dirty)"
ts="$(eval_iso_timestamp)"
subject="$(eval_git_head)"
env_json="$(eval_capture_env_json)"
report="$RUN_DIR/suites/perf.json"

write_perf_report() {
  local result="$1"
  local note="$2"
  local metrics_json="${3:-"{}"}"
  local omitted_json="${4:-"[]"}"
  local failed_json="${5:-"[]"}"
  local artifacts_json="${6:-"[]"}"
  local exit_code="${7:-2}"

  local json
  json="$(jq -n \
    --arg run_id "$(basename "$RUN_DIR")" \
    --arg timestamp "$ts" \
    --arg subject "$subject" \
    --arg harness "$subject" \
    --argjson dirty "$dirty" \
    --argjson env "$env_json" \
    --arg result "$result" \
    --arg note "$note" \
    --argjson metrics "$metrics_json" \
    --argjson omitted "$omitted_json" \
    --argjson failed "$failed_json" \
    --argjson artifacts "$artifacts_json" \
    --argjson code "$exit_code" \
    --arg step_result "$result" \
    '{
      schema_version: 1,
      kind: "suite",
      run_id: $run_id,
      timestamp: $timestamp,
      suite: "perf",
      scenarios: [],
      subject_commit: $subject,
      harness_commit: $harness,
      worktree_dirty: $dirty,
      env: $env,
      result: $result,
      metrics: $metrics,
      omitted: $omitted,
      failed: $failed,
      artifacts: $artifacts,
      notes: [
        "pass means record completed, not threshold passed",
        $note
      ],
      steps: [
        {name: "control-plane-record", result: $step_result, exit_code: $code}
      ]
    }')"
  if ! eval_write_report "$report" "$json"; then
    printf 'perf: failed to write validated suite report\n' >&2
    exit 2
  fi
}

# Dirty worktree: surface as error without attempting a silent clean/stash.
if [[ "$dirty" == "true" ]]; then
  printf 'perf: worktree must be clean to record provenance; commit or clean first\n' >&2
  printf 'perf: worktree must be clean to record provenance; commit or clean first\n' >"$log_path"
  write_perf_report \
    "error" \
    "dirty worktree refused; no measurement recorded" \
    '{}' \
    '["compare","threshold_judgment"]' \
    '["control-plane-record"]' \
    "[\"$log_rel\"]" \
    2
  exit 2
fi

printf 'perf: recording control-plane baseline -> %s\n' "$measure_path"
rc=0
(
  cd "$ROOT_DIR"
  bash "$RECORDER" --output "$measure_path"
) >"$log_path" 2>&1 || rc=$?
printf 'perf: recorder exit=%s\n' "$rc"

if [[ $rc -ne 0 ]]; then
  # Precondition / provenance refusal => error. Executed measurement failure => fail.
  result="fail"
  if grep -Eiq 'dirty worktree|refusing to record provenance|unable to resolve repository|missing required' "$log_path"; then
    result="error"
  fi
  write_perf_report \
    "$result" \
    "control-plane recorder exited $rc" \
    '{}' \
    '["compare","threshold_judgment"]' \
    '["control-plane-record"]' \
    "[\"$log_rel\"]" \
    "$rc"
  if [[ "$result" == "fail" ]]; then
    exit 1
  fi
  exit 2
fi

if [[ ! -s "$measure_path" ]]; then
  write_perf_report \
    "fail" \
    "recorder exited 0 but measurement artifact is missing/empty" \
    '{}' \
    '["compare","threshold_judgment"]' \
    '["control-plane-record"]' \
    "[\"$log_rel\"]" \
    1
  exit 1
fi

# Extract measured facts only; never invent thresholds.
# Field names match src/perf_runner.zig / control-plane artifact schema.
metrics_json="$(jq -c '
  {
    benchmarks: [
      .benchmarks[]? | {
        name,
        sample_count: (.samples|length),
        median_ns_per_op,
        p95_ns_per_op
      }
    ],
    method: .method,
    provenance: .provenance
  }
' "$measure_path")"

# Basic raw-sample proof already enforced by recorder jq; re-state counts.
sample_ok="$(jq -r '
  ([.benchmarks[].samples | length] | min // 0) as $m
  | if $m >= 5 then "true" else "false" end
' "$measure_path")"
if [[ "$sample_ok" != "true" ]]; then
  write_perf_report \
    "fail" \
    "measurement artifact lacks required raw sample counts" \
    "$metrics_json" \
    '["compare","threshold_judgment"]' \
    '["control-plane-record"]' \
    "[\"$log_rel\",\"$measure_rel\"]" \
    1
  exit 1
fi

write_perf_report \
  "pass" \
  "control-plane facts recorded; compare/threshold deferred" \
  "$metrics_json" \
  '["compare","threshold_judgment"]' \
  '[]' \
  "[\"$log_rel\",\"$measure_rel\"]" \
  0
exit 0

