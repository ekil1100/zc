#!/usr/bin/env bash
# Fast contract checks for the zc eval framework.
# Default mode is CI-safe: no full zig test, e2e, or perf record.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/../.." && pwd -P)"
# shellcheck source=lib.sh
source "$ROOT_DIR/scripts/eval/lib.sh"

FULL=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --full)
      FULL=1
      shift
      ;;
    -h|--help)
      cat <<'EOF'
Usage:
  just eval-selfcheck
  just eval-selfcheck-full
  bash scripts/eval/selfcheck.sh [--full]

Fast checks for eval framework contracts (report schema, orchestrator CLI,
adapter fail-closed behavior, scenario fixture presence). Prefer just.

  --full   Also run correctness + contract suites (perf still needs a clean
           dedicated run and is never executed here).
EOF
      exit 0
      ;;
    *)
      printf 'selfcheck: unknown option: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

PASS=0
FAIL=0
WORK="$(mktemp -d "${TMPDIR:-/tmp}/zc-eval-selfcheck.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

ok() {
  PASS=$((PASS + 1))
  printf '  PASS %s\n' "$1"
}

bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL %s\n' "$1" >&2
  if [[ -n "${2:-}" ]]; then
    printf '       %s\n' "$2" >&2
  fi
}

require_tools() {
  eval_require_cmd bash "bash is required" || exit 2
  eval_require_cmd jq "install jq (https://jqlang.github.io/jq/)" || exit 2
}

section() {
  printf '\n== %s ==\n' "$1"
}

# --- Task 1: report contract + lib helpers ---------------------------------

check_shell_syntax() {
  section "shell syntax"
  local f
  for f in \
    "$ROOT_DIR/scripts/eval/lib.sh" \
    "$ROOT_DIR/scripts/eval/selfcheck.sh"
  do
    if bash -n "$f"; then
      ok "bash -n $(basename "$f")"
    else
      bad "bash -n $(basename "$f")"
    fi
  done
  # Optional files may not exist yet during early tasks.
  for f in \
    "$ROOT_DIR/scripts/eval/run.sh" \
    "$ROOT_DIR/scripts/eval/suites/correctness.sh" \
    "$ROOT_DIR/scripts/eval/suites/contract.sh" \
    "$ROOT_DIR/scripts/eval/suites/interop.sh" \
    "$ROOT_DIR/scripts/eval/suites/perf.sh" \
    "$ROOT_DIR/scripts/eval/suites/reliability.sh" \
    "$ROOT_DIR/scripts/eval/scenarios/s1_startup.sh" \
    "$ROOT_DIR/scripts/eval/scenarios/s2_rule_matrix.sh"
  do
    if [[ -f "$f" ]]; then
      if bash -n "$f"; then
        ok "bash -n ${f#"$ROOT_DIR/"}"
      else
        bad "bash -n ${f#"$ROOT_DIR/"}"
      fi
    fi
  done
}

write_valid_suite_fixture() {
  local dest="$1"
  cat >"$dest" <<EOF
{
  "schema_version": 1,
  "kind": "suite",
  "run_id": "selfcheck-suite",
  "timestamp": "2026-08-12T00:00:00Z",
  "suite": "correctness",
  "scenarios": [],
  "subject_commit": "deadbeef",
  "harness_commit": "deadbeef",
  "worktree_dirty": false,
  "env": {
    "os": "Darwin",
    "arch": "arm64",
    "zig_version": "0.16.0"
  },
  "result": "pass",
  "metrics": {},
  "omitted": [],
  "failed": [],
  "artifacts": ["artifacts/correctness-build.log"],
  "notes": [],
  "steps": [
    {"name": "build", "result": "pass"},
    {"name": "test", "result": "pass"}
  ]
}
EOF
}

write_valid_summary_fixture() {
  local dest="$1"
  cat >"$dest" <<EOF
{
  "schema_version": 1,
  "kind": "summary",
  "run_id": "selfcheck-summary",
  "timestamp": "2026-08-12T00:00:00Z",
  "subject_commit": "deadbeef",
  "harness_commit": "deadbeef",
  "worktree_dirty": false,
  "env": {
    "os": "Darwin",
    "arch": "arm64",
    "zig_version": "0.16.0"
  },
  "requested_suites": ["correctness"],
  "suites": [
    {
      "suite": "correctness",
      "result": "pass",
      "report": "suites/correctness.json"
    }
  ],
  "result": "pass",
  "failed": [],
  "notes": []
}
EOF
}

check_report_contract() {
  section "report contract"
  local schema suite_ok summary_ok bad_file
  schema="$(eval_schema_path)"
  suite_ok="$WORK/suite-ok.json"
  summary_ok="$WORK/summary-ok.json"
  bad_file="$WORK/bad.json"

  write_valid_suite_fixture "$suite_ok"
  write_valid_summary_fixture "$summary_ok"

  if jq -e -f "$schema" "$suite_ok" >/dev/null; then
    ok "valid suite fixture"
  else
    bad "valid suite fixture"
  fi
  if jq -e -f "$schema" "$summary_ok" >/dev/null; then
    ok "valid summary fixture"
  else
    bad "valid summary fixture"
  fi

  # unknown suite
  jq '.suite = "scenarios"' "$suite_ok" >"$bad_file"
  if jq -e -f "$schema" "$bad_file" >/dev/null 2>&1; then
    bad "unknown suite must fail validation"
  else
    ok "unknown suite rejected"
  fi

  # missing required field
  jq 'del(.result)' "$suite_ok" >"$bad_file"
  if jq -e -f "$schema" "$bad_file" >/dev/null 2>&1; then
    bad "missing result must fail validation"
  else
    ok "missing required field rejected"
  fi

  # invalid result
  jq '.result = "skipped"' "$suite_ok" >"$bad_file"
  if jq -e -f "$schema" "$bad_file" >/dev/null 2>&1; then
    bad "invalid result must fail validation"
  else
    ok "invalid result rejected"
  fi

  # path-like run_id
  jq '.run_id = "../escape"' "$suite_ok" >"$bad_file"
  if jq -e -f "$schema" "$bad_file" >/dev/null 2>&1; then
    bad "path-like run_id must fail validation"
  else
    ok "path-like run_id rejected"
  fi

  # summary unknown suite in requested_suites
  jq '.requested_suites = ["not-a-suite"]' "$summary_ok" >"$bad_file"
  if jq -e -f "$schema" "$bad_file" >/dev/null 2>&1; then
    bad "summary unknown suite must fail validation"
  else
    ok "summary unknown suite rejected"
  fi
}

check_run_dir_helpers() {
  section "run directory helpers"
  local rid run_dir cache_root outside
  rid="selfcheck-$$"
  cache_root="$(eval_cache_root)"
  outside="$(dirname "$cache_root")/eval-escape-probe-$$"

  # Clean any leftover from a previous crashed run.
  rm -rf "$cache_root/$rid" "$outside"

  if ! run_dir="$(eval_new_run_dir "$rid")"; then
    bad "eval_new_run_dir first create"
    return 0
  fi
  if [[ "$run_dir" != "$cache_root/$rid" ]]; then
    bad "eval_new_run_dir path" "got $run_dir"
  else
    ok "eval_new_run_dir creates under .zig-cache/eval"
  fi
  if [[ -d "$run_dir/suites" && -d "$run_dir/artifacts" ]]; then
    ok "eval_new_run_dir creates suites/ and artifacts/"
  else
    bad "eval_new_run_dir missing subdirs"
  fi

  set +e
  eval_new_run_dir "$rid" >/dev/null 2>"$WORK/dup.err"
  local dup_rc=$?
  set -e
  if [[ $dup_rc -eq 2 ]]; then
    ok "duplicate run_id exits 2"
  else
    bad "duplicate run_id exits 2" "rc=$dup_rc"
  fi

  set +e
  eval_new_run_dir '../escape' >/dev/null 2>"$WORK/escape.err"
  local esc_rc=$?
  set -e
  if [[ $esc_rc -eq 2 && ! -e "$outside" ]]; then
    ok "path-like run_id rejected without escape"
  else
    bad "path-like run_id rejected without escape" "rc=$esc_rc outside=$([[ -e $outside ]] && echo yes || echo no)"
  fi

  # Atomic write + validate
  local report="$run_dir/suites/correctness.json"
  write_valid_suite_fixture "$WORK/to-write.json"
  jq --arg rid "$rid" '.run_id = $rid' "$WORK/to-write.json" >"$WORK/to-write2.json"
  if eval_write_report "$report" "$WORK/to-write2.json"; then
    ok "eval_write_report validates suite"
  else
    bad "eval_write_report validates suite"
  fi

  rm -rf "$run_dir"
}

check_no_fake_pass_hooks() {
  section "no production fake-pass hooks"
  # Assemble patterns without a single-line self-match for acceptance scans.
  local cmd_prefix=EVAL_
  local cmd_suffix=CMD
  local pat_cmd="${cmd_prefix}.*${cmd_suffix}"
  local pass_prefix=PERF_REGRESSION_RESULT
  local pass_suffix=PASS
  local pat_pass="${pass_prefix}=${pass_suffix}"
  local chaos_prefix=run-chaos
  local chaos_suffix=round
  local pat_chaos="${chaos_prefix}-${chaos_suffix}"
  if [[ -d "$ROOT_DIR/scripts/eval" ]]; then
    local hit=0
    if command -v rg >/dev/null 2>&1; then
      if rg -n -e "$pat_cmd" -e "$pat_pass" -e "$pat_chaos" "$ROOT_DIR/scripts/eval" >/dev/null 2>&1; then
        hit=1
        rg -n -e "$pat_cmd" -e "$pat_pass" -e "$pat_chaos" "$ROOT_DIR/scripts/eval" >&2 || true
      fi
    else
      if grep -R -n -E "$pat_cmd|$pat_pass|$pat_chaos" "$ROOT_DIR/scripts/eval" >/dev/null 2>&1; then
        hit=1
        grep -R -n -E "$pat_cmd|$pat_pass|$pat_chaos" "$ROOT_DIR/scripts/eval" >&2 || true
      fi
    fi
    if [[ $hit -ne 0 ]]; then
      bad "forbidden fake-pass pattern under scripts/eval"
    else
      ok "no command-override / chaos / placeholder PASS hooks"
    fi
  fi
}

# Later tasks append more check_* functions; invoke those that exist.
check_orchestrator_if_present() {
  if [[ ! -f "$ROOT_DIR/scripts/eval/run.sh" ]]; then
    return 0
  fi
  section "orchestrator CLI"
  if bash -n "$ROOT_DIR/scripts/eval/run.sh"; then
    ok "run.sh syntax"
  else
    bad "run.sh syntax"
  fi

  set +e
  local help_out help_rc
  help_out="$(bash "$ROOT_DIR/scripts/eval/run.sh" --help 2>&1)"
  help_rc=$?
  set -e
  if [[ $help_rc -eq 0 ]] && grep -Eq 'correctness|contract|interop|perf|reliability|exit' <<<"$help_out"; then
    ok "run.sh --help"
  else
    bad "run.sh --help" "rc=$help_rc"
  fi

  set +e
  bash "$ROOT_DIR/scripts/eval/run.sh" --suite not-a-suite >/dev/null 2>&1
  local unk_rc=$?
  set -e
  if [[ $unk_rc -eq 2 ]]; then
    ok "unknown suite exits 2"
  else
    bad "unknown suite exits 2" "rc=$unk_rc"
  fi

  set +e
  bash "$ROOT_DIR/scripts/eval/run.sh" --suite correctness --run-id '../escape' >/dev/null 2>&1
  local esc_rc=$?
  set -e
  if [[ $esc_rc -eq 2 ]]; then
    ok "path-like --run-id exits 2"
  else
    bad "path-like --run-id exits 2" "rc=$esc_rc"
  fi
}

check_placeholder_perf_absent() {
  section "placeholder perf removed"
  local reg_name="perf-regression"
  local base_name="run-baseline"
  local check_name="check-readme-consistency"
  local f
  local still_present=0
  for f in \
    "scripts/${reg_name}.sh" \
    "scripts/perf/${base_name}.sh" \
    "scripts/perf/${check_name}.sh" \
    "docs/perf/reports/latest.json"
  do
    if [[ -e "$ROOT_DIR/$f" ]]; then
      bad "still present: $f"
      still_present=1
    fi
  done
  if [[ $still_present -eq 0 ]]; then
    ok "placeholder perf paths absent"
  fi
  local pass_prefix=PERF_REGRESSION_RESULT
  local pass_suffix=PASS
  local pat_pass="${pass_prefix}=${pass_suffix}"
  local rule_prefix=RULE_EVAL_P95
  local rule_suffix=VALUE
  local pat_rule="${rule_prefix}_${rule_suffix}"
  local pat_base="${base_name}.sh"
  # Prefer rg; fall back to grep -R so missing rg is not a silent PASS.
  local scan_rc=0
  if command -v rg >/dev/null 2>&1; then
    if rg -n -e "$pat_pass" -e "$pat_rule" -e "$pat_base" \
        -g '!scripts/eval/selfcheck.sh' \
        "$ROOT_DIR/scripts" "$ROOT_DIR/docs/perf/reports/README.md" >/dev/null 2>&1; then
      scan_rc=1
      rg -n -e "$pat_pass" -e "$pat_rule" -e "$pat_base" \
        -g '!scripts/eval/selfcheck.sh' \
        "$ROOT_DIR/scripts" "$ROOT_DIR/docs/perf/reports/README.md" >&2 || true
    fi
  else
    if grep -R -n -E "$pat_pass|$pat_rule|$pat_base" \
        --exclude='selfcheck.sh' \
        "$ROOT_DIR/scripts" "$ROOT_DIR/docs/perf/reports/README.md" >/dev/null 2>&1; then
      scan_rc=1
      grep -R -n -E "$pat_pass|$pat_rule|$pat_base" \
        --exclude='selfcheck.sh' \
        "$ROOT_DIR/scripts" "$ROOT_DIR/docs/perf/reports/README.md" >&2 || true
    fi
  fi
  if [[ $scan_rc -ne 0 ]]; then
    bad "placeholder perf strings still advertised"
  else
    ok "placeholder perf strings gone from active docs/scripts"
  fi
}

check_correctness_adapter() {
  if [[ ! -f "$ROOT_DIR/scripts/eval/suites/correctness.sh" ]]; then
    return 0
  fi
  section "correctness adapter argv + fail aggregation"
  local fake_bin="$WORK/fake-zig-bin"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/zig" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
log="${ZC_EVAL_FAKE_ZIG_LOG:?}"
printf '%s\n' "$*" >>"$log"
case "$*" in
  version)
    printf '0.16.0\n'
    exit 0
    ;;
  "build -Dcpu=baseline")
    exit 42
    ;;
  "build test -Dcpu=baseline")
    exit 42
    ;;
  *)
    printf 'fake zig: unexpected argv: %s\n' "$*" >&2
    exit 99
    ;;
esac
FAKE
  chmod +x "$fake_bin/zig"
  local log="$WORK/fake-zig.log"
  : >"$log"
  local rid="selfcheck-correctness-$$"
  rm -rf "$(eval_cache_root)/$rid"
  set +e
  local out rc
  out="$(
    ZC_EVAL_FAKE_ZIG_LOG="$log" PATH="$fake_bin:$PATH" \
      bash "$ROOT_DIR/scripts/eval/run.sh" --suite correctness --run-id "$rid" 2>&1
  )"
  rc=$?
  set -e
  if [[ $rc -eq 1 ]]; then
    ok "fake zig correctness exits 1"
  else
    bad "fake zig correctness exits 1" "rc=$rc out=$out"
  fi
  local suite_json summary_json
  suite_json="$(eval_cache_root)/$rid/suites/correctness.json"
  summary_json="$(eval_cache_root)/$rid/summary.json"
  if [[ -f "$suite_json" && -f "$summary_json" \
    && "$(jq -r .result "$suite_json")" == "fail" \
    && "$(jq -r .result "$summary_json")" == "fail" ]]; then
    ok "correctness suite/summary report fail"
  else
    bad "correctness suite/summary report fail" "suite=$(cat "$suite_json" 2>/dev/null || true)"
  fi
  if [[ -f "$suite_json" \
    && "$(jq -r '.steps | length' "$suite_json")" == "2" \
    && "$(jq -r '.failed | length' "$suite_json")" == "2" ]]; then
    ok "both build and test steps recorded as failed"
  else
    bad "both build and test steps recorded as failed"
  fi
  if grep -Fxq 'build -Dcpu=baseline' "$log" \
    && grep -Fxq 'build test -Dcpu=baseline' "$log"; then
    ok "fake zig received exact correctness argv"
  else
    bad "fake zig received exact correctness argv" "$(cat "$log")"
  fi
  rm -rf "$(eval_cache_root)/$rid"
}


check_contract_adapter() {
  if [[ ! -f "$ROOT_DIR/scripts/eval/suites/contract.sh" ]]; then
    return 0
  fi
  section "contract adapter run-all aggregation"
  local tmp="$WORK/contract-repo"
  rm -rf "$tmp"
  mkdir -p \
    "$tmp/scripts/eval/suites" \
    "$tmp/scripts/eval/scenarios" \
    "$tmp/scripts/eval/schema" \
    "$tmp/scripts/install" \
    "$tmp/tools/config-migrator" \
    "$tmp/.git"
  # Minimal git repo so provenance helpers work.
  git -C "$tmp" init -q
  git -C "$tmp" config user.email "eval@example.com"
  git -C "$tmp" config user.name "eval"
  # Copy eval framework pieces.
  cp "$ROOT_DIR/scripts/eval/lib.sh" "$tmp/scripts/eval/lib.sh"
  cp "$ROOT_DIR/scripts/eval/run.sh" "$tmp/scripts/eval/run.sh"
  cp "$ROOT_DIR/scripts/eval/suites/contract.sh" "$tmp/scripts/eval/suites/contract.sh"
  cp "$ROOT_DIR/scripts/eval/schema/report.jq" "$tmp/scripts/eval/schema/report.jq"
  cat >"$tmp/tools/config-migrator/run-all.sh" <<'EOF'
#!/usr/bin/env bash
exit 42
EOF
  cat >"$tmp/scripts/install/run-all-regression.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  # Required scenario stubs so only migrator failure is under test.
  cat >"$tmp/scripts/eval/scenarios/s1_startup.sh" <<'EOF'
#!/usr/bin/env bash
echo S1_STARTUP_RESULT=PASS
exit 0
EOF
  cat >"$tmp/scripts/eval/scenarios/s2_rule_matrix.sh" <<'EOF'
#!/usr/bin/env bash
echo RULE_MATRIX_RESULT=PASS
exit 0
EOF
  # Provide a dummy zc so contract does not attempt zig build in the fixture repo.
  mkdir -p "$tmp/zig-out/bin"
  cat >"$tmp/zig-out/bin/zc" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x \
    "$tmp/tools/config-migrator/run-all.sh" \
    "$tmp/scripts/install/run-all-regression.sh" \
    "$tmp/scripts/eval/scenarios/s1_startup.sh" \
    "$tmp/scripts/eval/scenarios/s2_rule_matrix.sh" \
    "$tmp/scripts/eval/run.sh" \
    "$tmp/scripts/eval/suites/contract.sh" \
    "$tmp/zig-out/bin/zc"
  # Dummy commit so rev-parse works.
  git -C "$tmp" add scripts tools
  git -C "$tmp" commit -q -m "fixture"
  local rid="selfcheck-contract-$$"
  rm -rf "$tmp/.zig-cache/eval/$rid"
  set +e
  local out rc
  out="$(bash "$tmp/scripts/eval/run.sh" --suite contract --run-id "$rid" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 1 ]]; then
    ok "contract fixture exits 1"
  else
    bad "contract fixture exits 1" "rc=$rc out=$out"
  fi
  local suite_json="$tmp/.zig-cache/eval/$rid/suites/contract.json"
  if [[ -f "$suite_json" ]]; then
    local failed names
    failed="$(jq -r '.failed | join(",")' "$suite_json")"
    names="$(jq -r '[.steps[].name] | join(",")' "$suite_json")"
    if [[ "$failed" == "migrator" \
      && "$names" == *"install"* \
      && "$names" == *"migrator"* \
      && "$names" == *"s1_startup"* \
      && "$names" == *"s2_rule_matrix"* ]]; then
      ok "contract runs both steps and only migrator failed"
    else
      bad "contract runs both steps and only migrator failed" "failed=$failed names=$names"
    fi
    if [[ "$(jq -r '.steps[] | select(.name=="install") | .result' "$suite_json")" == "pass" ]]; then
      ok "install step still recorded pass"
    else
      bad "install step still recorded pass"
    fi
  else
    bad "contract fixture wrote suite report" "$out"
  fi
}


check_interop_adapter() {
  if [[ ! -f "$ROOT_DIR/scripts/eval/suites/interop.sh" ]]; then
    return 0
  fi
  section "interop adapter argv + pass/fail"
  local fake_bin="$WORK/fake-zig-interop"
  mkdir -p "$fake_bin"
  cat >"$fake_bin/zig" <<'FAKE'
#!/usr/bin/env bash
set -euo pipefail
log="${ZC_EVAL_FAKE_ZIG_LOG:?}"
mode="${ZC_EVAL_FAKE_ZIG_MODE:?}"
printf '%s\n' "$*" >>"$log"
case "$*" in
  version)
    printf '0.16.0\n'
    exit 0
    ;;
  "build e2e --summary all")
    if [[ "$mode" == "pass" ]]; then
      exit 0
    fi
    exit 42
    ;;
  *)
    printf 'fake zig interop: unexpected argv: %s\n' "$*" >&2
    exit 99
    ;;
esac
FAKE
  chmod +x "$fake_bin/zig"

  run_case() {
    local mode="$1"
    local expect_rc="$2"
    local expect_result="$3"
    local rid="selfcheck-interop-${mode}-$$"
    local log="$WORK/fake-zig-interop-${mode}.log"
    : >"$log"
    rm -rf "$(eval_cache_root)/$rid"
    set +e
    local out rc
    out="$(
      ZC_EVAL_FAKE_ZIG_LOG="$log" \
      ZC_EVAL_FAKE_ZIG_MODE="$mode" \
      PATH="$fake_bin:$PATH" \
        bash "$ROOT_DIR/scripts/eval/run.sh" --suite interop --run-id "$rid" 2>&1
    )"
    rc=$?
    set -e
    if [[ $rc -eq $expect_rc ]]; then
      ok "interop fake zig mode=$mode exits $expect_rc"
    else
      bad "interop fake zig mode=$mode exits $expect_rc" "rc=$rc out=$out"
    fi
    local suite_json summary_json
    suite_json="$(eval_cache_root)/$rid/suites/interop.json"
    summary_json="$(eval_cache_root)/$rid/summary.json"
    if [[ -f "$suite_json" && -f "$summary_json" \
      && "$(jq -r .result "$suite_json")" == "$expect_result" \
      && "$(jq -r .result "$summary_json")" == "$expect_result" ]]; then
      ok "interop mode=$mode reports $expect_result"
    else
      bad "interop mode=$mode reports $expect_result"
    fi
    if grep -Fxq 'build e2e --summary all' "$log"; then
      ok "interop mode=$mode exact argv"
    else
      bad "interop mode=$mode exact argv" "$(cat "$log")"
    fi
    rm -rf "$(eval_cache_root)/$rid"
  }

  run_case pass 0 pass
  run_case fail 1 fail
}


check_scenario_fail_aggregation() {
  if [[ ! -f "$ROOT_DIR/scripts/eval/scenarios/s2_rule_matrix.sh" ]]; then
    return 0
  fi
  section "contract scenario fail aggregation"
  local tmp="$WORK/scenario-fail-repo"
  rm -rf "$tmp"
  mkdir -p \
    "$tmp/scripts/eval/suites" \
    "$tmp/scripts/eval/scenarios" \
    "$tmp/scripts/eval/schema" \
    "$tmp/scripts/install" \
    "$tmp/tools/config-migrator" \
    "$tmp/testdata/rules"
  cp "$ROOT_DIR/scripts/eval/lib.sh" "$tmp/scripts/eval/lib.sh"
  cp "$ROOT_DIR/scripts/eval/run.sh" "$tmp/scripts/eval/run.sh"
  cp "$ROOT_DIR/scripts/eval/suites/contract.sh" "$tmp/scripts/eval/suites/contract.sh"
  cp "$ROOT_DIR/scripts/eval/schema/report.jq" "$tmp/scripts/eval/schema/report.jq"
  # S1 present but always pass (noop)
  cat >"$tmp/scripts/eval/scenarios/s1_startup.sh" <<'EOF'
#!/usr/bin/env bash
echo S1_STARTUP_RESULT=PASS
echo S1_STARTUP_PORT=18000
exit 0
EOF
  # S2 fails
  cat >"$tmp/scripts/eval/scenarios/s2_rule_matrix.sh" <<'EOF'
#!/usr/bin/env bash
echo RULE_MATRIX_RESULT=FAIL
exit 1
EOF
  cat >"$tmp/tools/config-migrator/run-all.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  cat >"$tmp/scripts/install/run-all-regression.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$tmp"/scripts/eval/scenarios/*.sh \
    "$tmp/tools/config-migrator/run-all.sh" \
    "$tmp/scripts/install/run-all-regression.sh" \
    "$tmp/scripts/eval/run.sh" \
    "$tmp/scripts/eval/suites/contract.sh"
  git -C "$tmp" init -q
  git -C "$tmp" config user.email "eval@example.com"
  git -C "$tmp" config user.name "eval"
  git -C "$tmp" add scripts tools
  git -C "$tmp" commit -q -m "fixture"
  local rid="selfcheck-s2-fail-$$"
  set +e
  local out rc
  out="$(bash "$tmp/scripts/eval/run.sh" --suite contract --run-id "$rid" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 1 ]]; then
    ok "scenario fail exits 1"
  else
    bad "scenario fail exits 1" "rc=$rc out=$out"
  fi
  local suite_json="$tmp/.zig-cache/eval/$rid/suites/contract.json"
  if [[ -f "$suite_json" ]]; then
    local failed names
    failed="$(jq -r '.failed | join(",")' "$suite_json")"
    names="$(jq -r '[.steps[].name] | join(",")' "$suite_json")"
    if [[ "$failed" == *s2_rule_matrix* && "$names" == *migrator* && "$names" == *install* && "$names" == *s1_startup* ]]; then
      ok "s2 fail still runs migrator/install/s1"
    else
      bad "s2 fail still runs migrator/install/s1" "failed=$failed names=$names"
    fi
    if [[ "$(jq -r '.result' "$suite_json")" == "fail" ]]; then
      ok "contract result fail with scenario failure"
    else
      bad "contract result fail with scenario failure"
    fi
  else
    bad "scenario fail wrote suite report"
  fi
}


main() {
  printf 'EVAL_SELFCHECK_BEGIN\n'
  require_tools
  check_shell_syntax
  check_report_contract
  check_run_dir_helpers
  check_no_fake_pass_hooks
  check_orchestrator_if_present
  check_correctness_adapter
  check_contract_adapter
  check_interop_adapter
  check_scenario_fail_aggregation
  check_placeholder_perf_absent

  if [[ $FULL -eq 1 ]]; then
    section "full mode"
    if [[ ! -f "$ROOT_DIR/scripts/eval/run.sh" ]]; then
      bad "--full requires scripts/eval/run.sh"
    else
      set +e
      bash "$ROOT_DIR/scripts/eval/run.sh" --suite correctness
      local c_rc=$?
      bash "$ROOT_DIR/scripts/eval/run.sh" --suite contract
      local k_rc=$?
      set -e
      if [[ $c_rc -eq 0 ]]; then ok "full correctness"; else bad "full correctness" "rc=$c_rc"; fi
      if [[ $k_rc -eq 0 ]]; then ok "full contract"; else bad "full contract" "rc=$k_rc"; fi
      printf '  NOTE perf is not run by --full; use a clean dedicated --suite perf/all run\n'
    fi
  fi

  printf '\nEVAL_SELFCHECK_PASS=%s\n' "$PASS"
  printf 'EVAL_SELFCHECK_FAIL=%s\n' "$FAIL"
  if [[ $FAIL -ne 0 ]]; then
    printf 'EVAL_SELFCHECK_RESULT=FAIL\n'
    exit 1
  fi
  printf 'EVAL_SELFCHECK_RESULT=PASS\n'
  exit 0
}

main "$@"
