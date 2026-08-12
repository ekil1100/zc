#!/usr/bin/env bash
# Thin orchestrator for the zc eval framework.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/eval/lib.sh"

usage() {
  cat <<'EOF'
Usage:
  just eval <suite> [-- --run-id <id>]
  just eval all [-- --with-interop] [-- --run-id <id>]
  just eval-selfcheck
  just eval-s1 / just eval-s2

  # equivalent direct entry (prefer just):
  bash scripts/eval/run.sh --help
  bash scripts/eval/run.sh --suite <name> [--run-id <id>]
  bash scripts/eval/run.sh --suite all [--with-interop] [--run-id <id>]

Suites:
  correctness   zig build + zig build test (baseline cpu)
  contract      migrator + install regression (+ S1/S2 when wired)
  interop       local zig build e2e (opt-in; also --with-interop with all)
  perf          control-plane record only (requires clean worktree; no threshold)
  reliability   fail-closed until a real short gate exists
  all           correctness -> contract -> [interop if --with-interop] -> perf

Exit codes:
  0  all selected suites passed
  1  at least one selected suite failed (commands ran, assertions failed)
  2  CLI / dispatch / report / missing-dependency error

Reports:
  .zig-cache/eval/<run_id>/suites/<suite>.json
  .zig-cache/eval/<run_id>/summary.json

Notes:
  - Selected suites are required; unselected suites are omitted (never skip/pass).
  - Perf records facts only; compare/threshold gating is deferred.
  - Local daemon scenarios must not use production port 7899.
  - --with-interop is valid only with --suite all.
EOF
}

SUITE=""
RUN_ID=""
WITH_INTEROP=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --suite)
      [[ $# -ge 2 ]] || { printf 'eval: missing value for --suite\n' >&2; exit 2; }
      SUITE="$2"
      shift 2
      ;;
    --run-id)
      [[ $# -ge 2 ]] || { printf 'eval: missing value for --run-id\n' >&2; exit 2; }
      RUN_ID="$2"
      shift 2
      ;;
    --with-interop)
      WITH_INTEROP=1
      shift
      ;;
    *)
      printf 'eval: unknown argument: %s\n' "$1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$SUITE" ]]; then
  printf 'eval: --suite is required\n' >&2
  usage >&2
  exit 2
fi

if [[ "$WITH_INTEROP" -eq 1 && "$SUITE" != "all" ]]; then
  printf 'eval: --with-interop is only valid with --suite all\n' >&2
  exit 2
fi

is_known_suite() {
  case "$1" in
    correctness|contract|interop|perf|reliability) return 0 ;;
    *) return 1 ;;
  esac
}

build_suite_list() {
  case "$SUITE" in
    all)
      SUITES=(correctness contract)
      if [[ "$WITH_INTEROP" -eq 1 ]]; then
        SUITES+=(interop)
      fi
      SUITES+=(perf)
      ;;
    *)
      if ! is_known_suite "$SUITE"; then
        printf 'eval: unknown suite: %s\n' "$SUITE" >&2
        printf 'eval: expected correctness|contract|interop|perf|reliability|all\n' >&2
        exit 2
      fi
      SUITES=("$SUITE")
      ;;
  esac
}

adapter_path() {
  printf '%s/scripts/eval/suites/%s.sh\n' "$ROOT_DIR" "$1"
}

# Write a fail-closed suite report when the adapter is missing or returns error
# without producing a report.
write_stub_suite_report() {
  local run_dir="$1"
  local suite="$2"
  local result="$3"
  local note="$4"
  local report="$run_dir/suites/${suite}.json"
  local ts subject harness dirty env_json
  ts="$(eval_iso_timestamp)"
  subject="$(eval_git_head)"
  harness="$subject"
  dirty="$(eval_worktree_dirty)"
  env_json="$(eval_capture_env_json)"

  jq -n \
    --arg run_id "$(basename "$run_dir")" \
    --arg timestamp "$ts" \
    --arg suite "$suite" \
    --arg subject "$subject" \
    --arg harness "$harness" \
    --argjson dirty "$dirty" \
    --argjson env "$env_json" \
    --arg result "$result" \
    --arg note "$note" \
    '{
      schema_version: 1,
      kind: "suite",
      run_id: $run_id,
      timestamp: $timestamp,
      suite: $suite,
      scenarios: [],
      subject_commit: $subject,
      harness_commit: $harness,
      worktree_dirty: $dirty,
      env: $env,
      result: $result,
      metrics: {},
      omitted: [],
      failed: (if $result == "pass" then [] else [$suite] end),
      artifacts: [],
      notes: (if $note == "" then [] else [$note] end)
    }' | eval_write_report "$report" "$(cat)"
}

write_summary() {
  local run_dir="$1"
  local overall="$2"
  shift 2
  # remaining: triples suite result report_rel ...
  local ts subject harness dirty env_json
  ts="$(eval_iso_timestamp)"
  subject="$(eval_git_head)"
  harness="$subject"
  dirty="$(eval_worktree_dirty)"
  env_json="$(eval_capture_env_json)"

  local suites_json="[]"
  local failed_json="[]"
  local requested_json
  requested_json="$(printf '%s\n' "${SUITES[@]}" | jq -R . | jq -s .)"

  local suite result report_rel
  while [[ $# -gt 0 ]]; do
    suite="$1"; result="$2"; report_rel="$3"
    shift 3
    suites_json="$(jq -c \
      --arg suite "$suite" \
      --arg result "$result" \
      --arg report "$report_rel" \
      '. + [{suite:$suite, result:$result, report:$report}]' <<<"$suites_json")"
    if [[ "$result" != "pass" ]]; then
      failed_json="$(jq -c --arg suite "$suite" '. + [$suite]' <<<"$failed_json")"
    fi
  done

  local summary="$run_dir/summary.json"
  jq -n \
    --arg run_id "$(basename "$run_dir")" \
    --arg timestamp "$ts" \
    --arg subject "$subject" \
    --arg harness "$harness" \
    --argjson dirty "$dirty" \
    --argjson env "$env_json" \
    --argjson requested "$requested_json" \
    --argjson suites "$suites_json" \
    --arg result "$overall" \
    --argjson failed "$failed_json" \
    '{
      schema_version: 1,
      kind: "summary",
      run_id: $run_id,
      timestamp: $timestamp,
      subject_commit: $subject,
      harness_commit: $harness,
      worktree_dirty: $dirty,
      env: $env,
      requested_suites: $requested,
      suites: $suites,
      result: $result,
      failed: $failed,
      notes: []
    }' | eval_write_report "$summary" "$(cat)"
}

run_adapter() {
  local run_dir="$1"
  local suite="$2"
  local adapter report rc
  adapter="$(adapter_path "$suite")"
  report="$run_dir/suites/${suite}.json"

  if [[ ! -f "$adapter" ]]; then
    write_stub_suite_report "$run_dir" "$suite" "error" "not implemented"
    return 2
  fi
  if [[ ! -x "$adapter" && ! -f "$adapter" ]]; then
    write_stub_suite_report "$run_dir" "$suite" "error" "adapter not executable: $adapter"
    return 2
  fi

  set +e
  bash "$adapter" --run-dir "$run_dir"
  rc=$?
  set +e

  if [[ ! -f "$report" ]]; then
    write_stub_suite_report "$run_dir" "$suite" "error" "adapter did not write suite report"
    return 2
  fi
  if ! eval_validate_report "$report"; then
    write_stub_suite_report "$run_dir" "$suite" "error" "adapter wrote invalid suite report"
    return 2
  fi

  # Prefer adapter exit code mapping; fall back to report result.
  # Keep set +e so non-zero return does not abort the orchestrator under errexit.
  case "$rc" in
    0|1|2) return "$rc" ;;
    *) return 2 ;;
  esac
}

main() {
  eval_require_cmd bash || exit 2
  eval_require_cmd jq "install jq to run eval reports" || exit 2

  build_suite_list

  local run_dir
  if ! run_dir="$(eval_new_run_dir "$RUN_ID")"; then
    exit 2
  fi

  printf 'EVAL_RUN_ID=%s\n' "$(basename "$run_dir")"
  printf 'EVAL_RUN_DIR=%s\n' "$run_dir"

  local overall="pass"
  local summary_args=()
  local suite rc result report_rel report_path
  for suite in "${SUITES[@]}"; do
    printf '=== suite:%s ===\n' "$suite"
    set +e
    run_adapter "$run_dir" "$suite"
    rc=$?
    set -e
    report_path="$run_dir/suites/${suite}.json"
    report_rel="suites/${suite}.json"
    if [[ -f "$report_path" ]]; then
      result="$(jq -r .result "$report_path")"
    else
      result="error"
    fi
    # Normalize overall by exit code priority as well.
    case "$rc" in
      0) ;;
      1)
        if [[ "$result" == "pass" ]]; then result="fail"; fi
        ;;
      *)
        result="error"
        rc=2
        ;;
    esac
    overall="$(eval_merge_result "$overall" "$result")"
    summary_args+=("$suite" "$result" "$report_rel")
    printf 'EVAL_SUITE_%s=%s rc=%s\n' "$suite" "$result" "$rc"
  done

  write_summary "$run_dir" "$overall" "${summary_args[@]}"
  printf 'EVAL_SUMMARY=%s/summary.json\n' "$run_dir"
  printf 'EVAL_RESULT=%s\n' "$overall"

  case "$overall" in
    pass) exit 0 ;;
    fail) exit 1 ;;
    *) exit 2 ;;
  esac
}

main "$@"
