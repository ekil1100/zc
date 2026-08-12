# zc Eval Framework Tasks

> Temporary task list for `.agents/eval-framework-plan.md`.  
> Track progress with checkboxes. Each task ends with an **Acceptance** block that must pass before commit.

Legend: `MVP` required for first shippable branch. `NEXT` after MVP.

## Global execution contract

- Tasks 1–10 use red → green: first add/extend a failing check in `scripts/eval/selfcheck.sh` or a task-local fixture, run it and record the expected failure, then implement and rerun green. Task 7 is the sole provenance exception: create a candidate commit before the clean-tree measurement; if it fails, fix with a focused follow-up and squash only during final local integration—never mark it complete from an unmeasured dirty tree.
- Suite adapters accept a run directory, write one validated suite report, and return `0=pass` / `1=fail` / `2=error`. Missing executable/script/dependency is `error`; a command that was found and executed but returned nonzero is `fail`. The orchestrator always writes a validated summary after a selected suite fails/errors.
- No `EVAL_*_CMD=true` or equivalent success override is allowed. Self-tests may shadow real executables through a temporary `PATH`, as `scripts/ci/test-beta-gate.sh` already does; fake executables must assert the exact argv they receive.
- Every generated path stays under `.zig-cache/eval/`. User-supplied run IDs must match `[A-Za-z0-9][A-Za-z0-9._-]{0,63}` and an existing run directory is an error, not an overwrite.
- S1/S2 are Scenarios inside the `contract` Suite, not an extra Suite.

---

## Task 0 — Branch hygiene and inventory freeze

**Phase:** A · **Priority:** MVP

**Files:**
- Add: `.agents/eval-framework-plan.md`
- Add: `.agents/eval-framework-tasks.md`
- Optionally add: `.agents/eval-inventory-notes.md`

**Steps:**
- [x] 0.1 Bootstrap-commit these two temporary `.agents` files first; otherwise the initial “clean worktree” condition is impossible because they start untracked.
- [x] 0.2 Fetch `origin/main`, rebase the eval branch onto it, and confirm the branch contains only the temporary-plan bootstrap commit beyond `origin/main`.
  - Note: `git fetch origin main` failed once with SSL_ERROR_SYSCALL; local `origin/main` already at `24645af` matching HEAD base — rebase was a no-op after bootstrap.
- [x] 0.3 Capture inventory in the commit body or `.agents/eval-inventory-notes.md`:
  - `test -f scripts/run-beta-gate.sh`
  - `test -f scripts/perf/run-control-plane-baseline.sh`
  - `test -f scripts/perf-regression.sh`
  - `test -f scripts/perf/run-baseline.sh`
  - `zig build --help | rg 'e2e|e2e-release'`
  - `test -f docs/reliability/e2e.md`
  - `rg -n '7899' AGENTS.md`
  - `zig version` must equal CI's `0.16.0`.
- [x] 0.4 Do **not** change product code in this task.

**Acceptance:**
- [x] `git status --short` is empty after bootstrap/rebase.
- [x] `git merge-base HEAD origin/main` equals `git rev-parse origin/main`.
- [x] Inventory commands all pass and notes distinguish current placeholder entries from target deletion in Task 6.

**Commit:**
```bash
git add .agents/eval-framework-plan.md .agents/eval-framework-tasks.md
# If created: git add .agents/eval-inventory-notes.md
git commit -m "docs(agents): freeze eval framework inventory"
git fetch origin main
git rebase origin/main
```

---

## Task 1 — Report schema + shared shell library

**Phase:** A · **Priority:** MVP

**Files:**
- Create: `scripts/eval/selfcheck.sh`
- Create: `scripts/eval/schema/report.jq`
- Create: `scripts/eval/lib.sh`
- Modify: `.agents/eval-framework-tasks.md`

**Requirements:**
- `report.jq` is the single executable contract for both `kind="suite"` and `kind="summary"`; it checks `schema_version == 1`, exact Suite/result enums, required arrays/objects, commits, `worktree_dirty`, env, and summary report references.
- `lib.sh` provides only the shared operations needed now:
  - repo/eval root resolution and atomic `eval_new_run_dir`
  - ISO timestamp, git HEAD, dirty-state, OS/arch/Zig capture
  - atomic JSON write and `eval_validate_report` using `report.jq`
- `selfcheck.sh` starts with report-contract fixtures. First observe red with an invalid/missing-field fixture, then green after the contract exists.
- No network dependency. Require `bash` + `jq`; missing tools fail with an actionable message.

**Acceptance:**
- [x] `bash -n scripts/eval/lib.sh scripts/eval/selfcheck.sh` exits 0.
- [x] A valid suite fixture and valid summary fixture pass `jq -e -f scripts/eval/schema/report.jq`.
- [x] Fixtures with an unknown Suite, missing required field, invalid result, or path-like run ID fail validation.
- [x] Inline smoke atomically creates one `.zig-cache/eval/<run_id>/`; repeating the same run ID exits 2 and does not overwrite it.

**Commit:**
```bash
git add scripts/eval/schema/report.jq scripts/eval/lib.sh scripts/eval/selfcheck.sh .agents/eval-framework-tasks.md
git commit -m "feat(eval): add executable report contract and shell helpers"
```

---

## Task 2 — Orchestrator MVP entry

**Phase:** A · **Priority:** MVP

**Files:**
- Create: `scripts/eval/run.sh`
- Modify: `.agents/eval-framework-tasks.md`

**CLI contract:**
```bash
bash scripts/eval/run.sh --help
bash scripts/eval/run.sh --suite correctness|contract|interop|perf|reliability|all
bash scripts/eval/run.sh --suite correctness --run-id <id>   # optional
```

Behavior:
- Atomically creates `.zig-cache/eval/<run_id>/`; `summary.json` carries suite list + env + commits, so there is no duplicate `manifest.json`.
- Dispatches suite adapters. Until implemented, a selected adapter writes `result=error`, note `not implemented`, then returns 2.
- Writes and validates `summary.json` even when a selected suite returns fail/error.
- Exit codes: `0` all selected suites pass；`1` at least one selected suite fails；`2` CLI/dispatch/report error（including unknown suite and not implemented）。
- Unknown suite and invalid/existing `--run-id` exit 2 without writing outside the eval root.
- Must not use port 7899.

**Acceptance:**
- [x] `bash scripts/eval/run.sh --help` exits 0 and documents suites, `all`, exit codes, and report root.
- [x] `bash scripts/eval/run.sh --suite not-a-suite` exits 2.
- [x] `bash scripts/eval/run.sh --suite correctness --run-id ../escape` exits 2 and creates nothing outside `.zig-cache/eval/`.
- [x] `bash scripts/eval/run.sh --suite correctness` fails closed until Task 3, but still writes validated `suites/correctness.json` and `summary.json` with `result=error`.
- [x] Reusing a run ID exits 2 without altering the first run's files.

**Commit:**
```bash
git add scripts/eval/run.sh .agents/eval-framework-tasks.md
git commit -m "feat(eval): add orchestrator entrypoint"
```

---

## Task 3 — Suite adapter: correctness

**Phase:** A · **Priority:** MVP

**Files:**
- Create: `scripts/eval/suites/correctness.sh` (or inline in `run.sh` if smaller; prefer separate file)
- Modify: `scripts/eval/run.sh`
- Modify: `.agents/eval-framework-tasks.md`

**Behavior:**
- Runs the exact existing CI correctness commands, in order: `zig build -Dcpu=baseline` and `zig build test -Dcpu=baseline`.
- Runs both and aggregates `steps[]`, so one failure does not hide the other. Each step streams to its own artifact log.
- Writes `suites/correctness.json` with `result=pass|fail`, artifacts, and failed step names. Do not parse every Zig test name.
- No command override exists in production scripts.

**Acceptance:**
- [x] `bash scripts/eval/run.sh --suite correctness` on the healthy tree exits 0.
- [x] Suite report lists `build` and `test`, validates, and summary is `pass`.
- [x] `selfcheck.sh` shadows `zig` with a temporary executable that asserts argv and returns 42; the run exits 1 and both suite/summary report `fail`.
- [x] `rg -n 'EVAL_.*CMD' scripts/eval` has no match.

**Commit:**
```bash
git add scripts/eval/suites/correctness.sh scripts/eval/run.sh .agents/eval-framework-tasks.md
git commit -m "feat(eval): wrap zig build test as correctness suite"
```

---

## Task 4 — Suite adapter: contract (install + migrator)

**Phase:** A/D · **Priority:** MVP

**Files:**
- Create: `scripts/eval/suites/contract.sh`
- Modify: `scripts/eval/run.sh`
- Modify: `.agents/eval-framework-tasks.md`

**Behavior:**
- Runs, in order:
  1. `bash tools/config-migrator/run-all.sh`
  2. `bash scripts/install/run-all-regression.sh`
- Each step recorded in suite json (`steps[]` with name/result).
- Fail closed on first failure or run all and aggregate — pick **run all and aggregate** so summary shows every failed step.
- Exit non-zero if any step failed.

**Acceptance:**
- [x] `bash scripts/eval/run.sh --suite contract` exits 0 on the healthy tree; a pre-existing failure is recorded as failure and leaves the task incomplete until resolved or explicitly re-scoped in this plan.
- [x] Validated `suites/contract.json` lists both steps and separate log artifacts.
- [x] A task-local temporary-repo fixture, modeled on `scripts/ci/test-beta-gate.sh`, makes migrator exit 42 and install exit 0; the adapter runs both, reports only migrator failed, and exits 1.
- [x] No production command-override environment variable is added.

**Commit:**
```bash
git add scripts/eval/suites/contract.sh scripts/eval/run.sh .agents/eval-framework-tasks.md
git commit -m "feat(eval): wrap migrator and install regression as contract suite"
```

---

## Task 5 — Suite adapter: interop (delegate e2e)

**Phase:** A · **Priority:** MVP

**Files:**
- Create: `scripts/eval/suites/interop.sh`
- Modify: `scripts/eval/run.sh`
- Modify: `.agents/eval-framework-tasks.md`

**Behavior:**
- Local command is exactly `zig build e2e --summary all`.
- `e2e-release` remains owned by the existing Linux CI job with its target/optimize/cpu flags; do not add a host-ambiguous release flag to eval.
- No skip-as-pass and no command override. Missing fixtures/network capability produce a real fail with actionable stderr.
- Stream logs to `artifacts/interop.log`; real-run status belongs in task/done notes, because the adapter cannot safely attest that `PATH` was not shadowed by its caller.

**Acceptance:**
- [x] Adapter is dispatched by `--suite interop` and writes a validated report.
- [x] `selfcheck.sh` uses a temporary `PATH` fake `zig` that first asserts exact argv `build e2e --summary all`, then returns 0/42 in separate cases; reports become pass/fail respectively without any production bypass hook.
- [x] Record the real `bash scripts/eval/run.sh --suite interop` outcome on a viable host. If prerequisites are unavailable, record the concrete missing prerequisite and `not executed` (never `pass`) in task notes; the unchanged CI remains authoritative for full `e2e-release`.
  - Note: real host run on 2026-08-12 exited 0 (`CORE_E2E_RESULT=PASS`, Build Summary 15/15). CI `e2e-release` remains authoritative for release artifacts.

**Commit:**
```bash
git add scripts/eval/suites/interop.sh scripts/eval/run.sh .agents/eval-framework-tasks.md
git commit -m "feat(eval): delegate interop suite to existing e2e entry"
```

---

## Task 6 — Kill placeholder perf green path

**Phase:** C · **Priority:** MVP

**Files:**
- Delete: `scripts/perf-regression.sh`
- Delete: `scripts/perf/run-baseline.sh`
- Delete: `scripts/perf/check-readme-consistency.sh` (it asserts the obsolete fake-PASS contract)
- Delete: `docs/perf/reports/latest.json` (tracked placeholder output)
- Modify: `docs/perf/reports/README.md` (the only project doc intentionally changed by this temporary plan)
- Modify: `.agents/eval-framework-tasks.md`

**Behavior:**
- Remove obsolete placeholder entrypoints outright; do not retain tombstones, fail shims, env-default metrics, or `PERF_REGRESSION_RESULT=PASS` compatibility output.
- The only active measurement entry is `scripts/perf/run-control-plane-baseline.sh`; eval Task 7 wraps it as a record, not a threshold gate.
- README must remove instructions that advertise the deleted commands/latest file as active. Existing history blobs stay only as explicitly non-authoritative historical artifacts; no new tracked measurement is promoted in MVP.

**Acceptance:**
- [x] `test ! -e scripts/perf-regression.sh && test ! -e scripts/perf/run-baseline.sh && test ! -e scripts/perf/check-readme-consistency.sh`.
- [x] `test ! -e docs/perf/reports/latest.json`.
- [x] `! rg -n 'PERF_REGRESSION_RESULT=PASS|RULE_EVAL_P95_VALUE|run-baseline.sh' scripts docs/perf/reports/README.md`.
- [x] README gives the real record command, clean-worktree precondition, output location, and explicitly says compare/threshold gating is deferred.
- [x] `bash scripts/perf/run-control-plane-baseline.sh --help` remains green.

**Commit:**
```bash
git add -A scripts/perf-regression.sh scripts/perf docs/perf/reports .agents/eval-framework-tasks.md
git commit -m "fix(perf): remove placeholder regression gate"
```

---

## Task 7 — Suite adapter: perf record (control-plane)

**Phase:** C · **Priority:** MVP

**Files:**
- Create: `scripts/eval/suites/perf.sh`
- Modify: `scripts/eval/run.sh`
- Modify: `.agents/eval-framework-tasks.md`

**Behavior:**
- Invokes `bash scripts/perf/run-control-plane-baseline.sh` with output under the eval run dir, e.g. `--output .zig-cache/eval/<run_id>/artifacts/control-plane.json`.
- Dirty worktree: control-plane script already refuses; adapter surfaces it as `result=error` and returns 2. It must not silently clean/stash, and `--suite all` runs perf last.
- Suite json:
  - `result=pass` means **record succeeded** (facts written), not “performance better than threshold”.
  - Thresholds/compare are strictly out of this task and remain deferred.
- Copy/link artifact paths into suite json `artifacts`.
- Never read env placeholder metrics.

**Acceptance:**
- [x] On a clean worktree after the Task 7 commit, `bash scripts/eval/run.sh --suite perf` exits 0 with validated suite/summary reports and a non-empty measurement artifact whose existing harness checks prove raw sample counts.
- [x] With a temporary untracked probe outside ignored paths, the same command exits 2, suite/summary report `error`, and stderr says the worktree must be clean; cleanup removes the probe.
  - Verified pre-commit with dirty tree (adapter source uncommitted) and again with orchestrator.
- [x] Suite notes state `pass` means record completed, not threshold passed; `metrics` contains only measured facts and `omitted` names compare/threshold judgment.
- [x] No placeholder metric environment variable is read.

**Commit:**
```bash
git add scripts/eval/suites/perf.sh scripts/eval/run.sh .agents/eval-framework-tasks.md
git commit -m "feat(eval): record control-plane perf evidence in eval suite"
```

---

## Task 8 — Scenario pack S1 startup

**Phase:** B · **Priority:** MVP

**Files:**
- Reuse: `testdata/config/minimal.yaml`
- Create: `testdata/eval/scenarios/s1_startup/expect.json`
- Create: `scripts/eval/scenarios/s1_startup.sh`
- Modify: `.agents/eval-framework-tasks.md`

**Scenario definition:**
- Script accepts `--zc <path>` and optional `--expect <path>`; it uses the existing minimal config and never accesses public internet.
- Create owner-only isolated `HOME` and `XDG_RUNTIME_DIR` under a temporary directory.
- Select an explicit currently-free loopback port with bounded retries, reject `7899`, and run `zc start -c testdata/config/minimal.yaml --port <port> --json`.
- Assert start success, `zc status --json` has `.ok == true` and `.data.state == "running"`, and the chosen TCP port listens; then `zc stop --json` and assert the port closes.
- `trap` always stops the daemon with the same isolated env and removes temp files. Do not auto-fallback to another port after `zc start` reports a bind conflict.

**Acceptance:**
- [x] `zig build -Dcpu=baseline` then `bash scripts/eval/scenarios/s1_startup.sh --zc zig-out/bin/zc` exits 0.
- [x] A copied `expect.json` with expected state changed to `stopped`, passed via `--expect`, makes the script exit non-zero.
- [x] Both pass/fail runs leave `status --json` stopped and their chosen listener closed.
- [x] Script contains an explicit 7899 rejection and emits `S1_STARTUP_RESULT=<PASS|FAIL>` plus the selected non-7899 port.

**Commit:**
```bash
git add testdata/eval/scenarios/s1_startup scripts/eval/scenarios/s1_startup.sh .agents/eval-framework-tasks.md
git commit -m "feat(eval): add S1 startup scenario pack"
```

---

## Task 9 — Scenario pack S2 rule-matrix

**Phase:** B · **Priority:** MVP

**Files:**
- Reuse: `testdata/rules/rule-matrix.yaml`
- Create: `src/eval_rule_matrix_runner.zig` (test-only; never installed; lives under `src/` for Zig module path)
- Modify: `build.zig` to add host-native `eval-rule-matrix` run step
- Create: `scripts/eval/scenarios/s2_rule_matrix.sh`
- Modify: `.agents/eval-framework-tasks.md`

**Behavior:**
- The test-only Zig runner loads the existing frozen YAML rules/cases and calls the real config/rule engine. It must not reimplement DOMAIN matching in shell/Zig glue.
- Script accepts optional `--matrix <path>` for negative fixture tests and runs `zig build eval-rule-matrix -Dcpu=baseline -- <matrix>`.
- Existing cases cover domain/domain-suffix/domain-keyword plus fallback; add a first-match-priority and explicit negative/non-hit case only if they are not already proven by the fixture.
- Runner prints `RULE_MATRIX_RESULT=<PASS|FAIL>`, `RULE_MATRIX_PASSED=<n>`, `RULE_MATRIX_FAILED=<n>`, `RULE_MATRIX_TOTAL=<n>`, and failed case IDs; it exits non-zero on mismatch. The artifact is test-only and is not installed or included in release archives.

**Acceptance:**
- [x] `bash scripts/eval/scenarios/s2_rule_matrix.sh` exits 0 and reports nonzero total with all passed.
- [x] Copy the YAML to `/tmp`, use portable `awk` to change the first expected `target: PROXY` to `target: REJECT`, pass it via `--matrix`, and observe exit 1 with the failed case ID.
- [x] `rg`/review confirms the runner imports the production rule engine and contains no second matching implementation.
- [x] `zig build test -Dcpu=baseline` remains green after the build graph change.

**Commit:**
```bash
git add build.zig src/eval_rule_matrix_runner.zig scripts/eval/scenarios/s2_rule_matrix.sh testdata/rules/rule-matrix.yaml .agents/eval-framework-tasks.md
git commit -m "feat(eval): add S2 rule-matrix scenario pack"
```

---

## Task 10 — Wire scenarios into orchestrator + `all` suite set

**Phase:** B · **Priority:** MVP

**Files:**
- Modify: `scripts/eval/run.sh`
- Modify: `scripts/eval/suites/contract.sh`
- Modify: `.agents/eval-framework-tasks.md`

**Behavior:**
- Extend the existing `contract` adapter steps to migrator + install + S1 + S2; each scenario name appears in `scenarios[]` and each step has a log artifact.
- `--suite all` runs correctness, contract, then perf record. There is no `scenarios` Suite.
- `interop` is opt-in via `--suite interop` or `--with-interop`; `--with-interop` is valid only with `--suite all` and runs before perf.
- `reliability` is omitted when not selected; selecting its not-yet-implemented adapter returns `error`/2, never skip/pass.

**Acceptance:**
- [x] `--help` documents exact `all` order, interop opt-in, perf clean-tree precondition, and reliability boundary.
- [x] On a clean worktree, `bash scripts/eval/run.sh --suite all` produces correctness/contract/perf suite reports and one summary; contract lists both scenarios.
- [x] In a temporary copied repo, replace only the S1 or S2 scenario executable with a failing fixture; contract and summary fail while migrator/install/the other scenario still run. No production override hook is added.
- [x] `bash scripts/eval/run.sh --suite correctness --with-interop` exits 2.
- [x] `find <run>/suites -type f` has no `scenarios.json`.

**Commit:**
```bash
git add scripts/eval .agents/eval-framework-tasks.md
git commit -m "feat(eval): wire scenario packs into all-suite run"
```

---

## Task 11 — Reliability adapter stub or thin wrap (optional MVP stretch)

**Phase:** E · **Priority:** NEXT (do only if MVP Tasks 0–10 green and time remains)

> Skipped in this MVP branch: reliability remains orchestrator fail-closed stub (`not implemented` / exit 2). No chaos wrap added.

**Files:**
- Create: `scripts/eval/suites/reliability.sh`
- Modify: `scripts/eval/run.sh`

**Behavior:**
- Do **not** wrap `scripts/reliability/run-chaos-round.sh`: it currently emits simulated/dry-run PASS and is not evidence.
- MVP boundary may remain a thin fail-closed adapter. A future real wrap may call only `run-soak-real.sh` with explicit binary, duration, and non-7899 port, gated by `--allow-long`.
- No fake PASS and no tracked output under `docs/perf/reports/history/`.

**Acceptance:**
- [ ] `bash scripts/eval/run.sh --suite reliability` exits 2, writes validated suite/summary `error`, and explains that no authoritative short reliability gate exists.
- [ ] `rg -n 'run-chaos-round' scripts/eval` has no match.
- [ ] If a real long wrap is added later, omitting `--allow-long` and explicit non-7899 port still exits 2.

**Commit:**
```bash
git add scripts/eval/suites/reliability.sh scripts/eval/run.sh .agents/eval-framework-tasks.md
git commit -m "feat(eval): add reliability suite adapter boundaries"
```

---

## Task 12 — Self-check script for eval framework

**Phase:** A–B · **Priority:** MVP

**Files:**
- Modify: `scripts/eval/selfcheck.sh`
- Modify: `.agents/eval-framework-tasks.md`

**Behavior:**
- Consolidate the red→green checks accumulated in Tasks 1–10:
  - shell syntax and executable report contract positive/negative fixtures
  - help, invalid suite/run-id/flag combinations, existing-run refusal, and exit-code mapping
  - atomic reports on adapter fail/error
  - placeholder perf files/latest output are absent
  - temporary-`PATH` fake executables verify exact correctness/interop argv and pass/fail aggregation without production override hooks
  - contract temporary-repo fixture proves run-all aggregation
  - S1/S2 fixture syntax/presence and S2 negative matrix; S1's real daemon negative path remains Task 8 acceptance and is not rerun by fast selfcheck
- Default remains fast and must not run full `zig build test`, full e2e, perf record, or long reliability. Optional `--full` may run correctness + contract only and must document that perf still needs a clean dedicated run.

**Acceptance:**
- [x] `bash scripts/eval/selfcheck.sh` exits 0 on the finished MVP branch and is fast enough for the existing build-test CI job.
- [x] `bash scripts/eval/selfcheck.sh --full` either works as documented or is rejected as an unknown option; do not leave a half-implemented mode.
- [x] `rg -n 'EVAL_.*CMD|run-chaos-round|PERF_REGRESSION_RESULT=PASS' scripts/eval` has no match.

**Commit:**
```bash
git add scripts/eval/selfcheck.sh .agents/eval-framework-tasks.md
git commit -m "test(eval): add eval framework selfcheck"
```

---

## Task 13 — Final MVP verification + plan checkbox sweep

**Phase:** closeout · **Priority:** MVP

**Steps:**
- [x] Start from a clean committed Task 12 tree and run `bash scripts/eval/selfcheck.sh`.
- [x] Run `bash scripts/eval/run.sh --suite correctness`.
- [x] Run `bash scripts/eval/run.sh --suite contract`.
- [x] Run `bash scripts/eval/run.sh --suite all` while still clean, so perf provenance is valid.
- [x] Run real interop if host prerequisites permit; otherwise record it as not executed and rely on the unchanged authoritative CI `e2e-release` job.
- [x] Confirm obsolete placeholder perf files are absent.
- [x] Add `bash scripts/eval/selfcheck.sh` to the existing CI build-test job without replacing build/test/migrator/install/e2e-release gates and without adding perf record to CI.
- [x] Run fast selfcheck again after the CI edit, update task checkboxes to match reality, and set plan status accurately.
- [x] Produce `.agents/eval-framework-done.md` with commits, exact commands/results, interop status, dirty/perf boundary, known gaps, and next tasks (perf compare thresholds, CI artifact upload, more measured hot paths).

**Acceptance:**
- [x] Fast selfcheck passes and `.github/workflows/ci.yml` invokes it.
- [x] Clean-tree `--suite all` passes and contains real perf samples; if it fails, closeout remains incomplete.
- [x] Placeholder files are absent and active docs contain no placeholder PASS instruction.
- [x] Existing CI gate commands remain present unchanged.
- [x] `git diff --check` passes and done report exists.

**Commit:**
```bash
git add .github/workflows/ci.yml .agents/eval-framework-tasks.md .agents/eval-framework-plan.md .agents/eval-framework-done.md
git commit -m "docs(agents): close eval framework MVP checklist"
```

---

## Explicitly deferred (do not implement in this branch unless plan updated)

1. Replacing existing CI gates with `scripts/eval/run.sh` (MVP only adds fast selfcheck; replacement requires a follow-up).
2. Data-plane perf metrics: rule_eval / dns / handshake sampling in `perf_runner.zig`.
3. Perf compare gate with machine-local baselines and thresholds policy file.
4. mihomo side-by-side runner.
5. Promoting temporary `.agents` plan into `docs/eval/`.
6. 24h soak as PR gate.
7. Dashboard / HTML report UI.

---

## Definition of Done (branch)

- [x] Tasks 0–10 and 12–13 complete (Task 11 remains optional NEXT).
- [x] `bash scripts/eval/selfcheck.sh` pass locally and is wired into existing CI.
- [x] Clean-tree `bash scripts/eval/run.sh --suite all` pass with real perf samples.
- [x] Placeholder perf scripts and tracked fake latest report are absent.
- [x] S1 + S2 run under contract and pass; no `scenarios` Suite exists.
- [x] Existing build/test/migrator/install/e2e-release CI gates remain authoritative and unchanged.
- [x] `.agents/eval-framework-done.md` written.
- [x] No unrelated refactors.
