# Eval Framework MVP — Done Report

**Branch:** `wt/eval-framework`  
**Base:** `origin/main` @ `24645af`  
**Closed:** 2026-08-12  
**Plan:** `.agents/eval-framework-plan.md` (temporary; not promoted to `docs/`)

## Result

MVP Tasks **0–10** and **12–13** are complete. Task **11** (reliability adapter) was **skipped** as optional NEXT; selecting `--suite reliability` remains fail-closed (`result=error`, exit 2, note `not implemented`).

## Commits (`origin/main..HEAD`)

```
107a52b test(eval): add eval framework selfcheck
49ffbdb fix(eval): restore migrator reports after contract suite
ea05ee7 feat(eval): wire scenario packs into all-suite run
331019f feat(eval): add S2 rule-matrix scenario pack
16f7360 feat(eval): add S1 startup scenario pack
1ccc524 docs(agents): record task 7 perf acceptance
10352ce feat(eval): record control-plane perf evidence in eval suite
efdde29 fix(perf): remove placeholder regression gate
7ceeca1 feat(eval): delegate interop suite to existing e2e entry
dd88ae3 feat(eval): wrap migrator and install regression as contract suite
2c2d12c feat(eval): wrap zig build test as correctness suite
b441bce feat(eval): add orchestrator entrypoint
9a6faeb feat(eval): add executable report contract and shell helpers
46e5897 docs(agents): freeze eval framework inventory
```

Plus the closeout commit that lands this file and CI wiring.

## Layout delivered

```text
scripts/eval/
  run.sh
  lib.sh
  selfcheck.sh
  schema/report.jq
  suites/{correctness,contract,interop,perf}.sh
  scenarios/{s1_startup,s2_rule_matrix}.sh
src/eval_rule_matrix_runner.zig   # test-only; not installed
testdata/eval/scenarios/s1_startup/expect.json
testdata/rules/rule-matrix.yaml   # GEOIP case IP aligned to SimpleGeoIp
.zig-cache/eval/<run_id>/
  suites/*.json
  summary.json
  artifacts/*
```

## Commands and results (closeout)

| Command | Result |
| --- | --- |
| `bash scripts/eval/selfcheck.sh` | **PASS** (exit 0, fast) |
| `bash scripts/eval/selfcheck.sh --full` | **PASS** (correctness + contract; perf not run) |
| `bash scripts/eval/run.sh --suite correctness` | **PASS** |
| `bash scripts/eval/run.sh --suite contract` | **PASS** (migrator, install, S1, S2) |
| `bash scripts/eval/run.sh --suite all` | **PASS** on clean tree (`t10-all3-7943`) |
| `bash scripts/eval/run.sh --suite interop` | **PASS** on this host (`CORE_E2E_RESULT=PASS`; CI `e2e-release` still authoritative) |
| `bash scripts/eval/run.sh --suite perf` (dirty probe) | **error** / exit 2; stderr requires clean worktree |
| `bash scripts/eval/run.sh --suite reliability` | **error** / exit 2 (not implemented; no chaos wrap) |
| `bash scripts/eval/run.sh --suite correctness --with-interop` | exit **2** |

### Clean-tree `--suite all` evidence

Run id: `t10-all3-7943`

- Suites written: `correctness.json`, `contract.json`, `perf.json` + `summary.json`
- No `scenarios.json` suite file
- Contract `scenarios`: `["s1_startup","s2_rule_matrix"]`
- Perf artifact sample counts (all 9):

```json
[
  {"name":"legacy_bounded_read","n":9},
  {"name":"strict_bounded_read","n":9},
  {"name":"authority_commit_profiles_1","n":9},
  {"name":"authority_commit_profiles_100","n":9},
  {"name":"authority_commit_profiles_1000","n":9}
]
```

## Interop status

- Local `zig build e2e --summary all` via eval: **executed and passed** on this macOS host.
- CI continues to own `zig build e2e-release` with target/optimize/cpu flags unchanged.

## Dirty / perf boundary

- Perf record requires a **clean** worktree (untracked files count).
- `pass` on the perf suite means **record completed**, not threshold passed.
- `omitted` includes `compare` and `threshold_judgment`.
- Contract suite restores regenerable migrator report files after the migrator step so `--suite all` does not leave a dirty tree that would block perf.

## Placeholder perf removal

Deleted:

- `scripts/perf-regression.sh`
- `scripts/perf/run-baseline.sh`
- `scripts/perf/check-readme-consistency.sh`
- `docs/perf/reports/latest.json`

`docs/perf/reports/README.md` now documents only the real control-plane recorder and deferred compare.

## CI

`.github/workflows/ci.yml` build-test job **adds**:

```yaml
- name: Eval framework selfcheck
  run: bash scripts/eval/selfcheck.sh
```

**Unchanged authoritative gates:**

- `zig build -Dcpu=baseline`
- `zig build test -Dcpu=baseline`
- `bash tools/config-migrator/run-all.sh`
- `bash scripts/install/run-all-regression.sh`
- `zig build e2e-release` (e2e job)

No perf record in CI.

## Hard constraints honored

- No `EVAL_*_CMD=true` / production fake-pass hooks
- No port `7899` in S1 (explicit rejection; free non-7899 port)
- S1/S2 are contract scenarios, not a sixth suite
- Temporary plan stayed under `.agents/`
- Work only on `wt/eval-framework`

## Known gaps / next tasks

1. **Perf compare thresholds** — machine-local baselines + policy file (deferred).
2. **Data-plane hot paths** — rule_eval / dns / handshake sampling in `perf_runner.zig`.
3. **CI artifact upload** for eval run directories (optional).
4. **Reliability** — real short gate or gated long soak (`run-soak-real.sh`); never wrap simulated chaos as pass.
5. **Replace CI gates with eval** — out of scope; MVP only adds selfcheck.
6. **Promote plan to `docs/eval/`** — only if a follow-up explicitly asks.
7. Migrator still rewrites tracked reports during its own entrypoint; eval restores them after contract. Longer-term, migrator should write only under cache/temp.

## Definition of Done checklist

- [x] Tasks 0–10, 12–13 complete; Task 11 optional skipped
- [x] Fast selfcheck green and wired into CI
- [x] Clean-tree `--suite all` green with real perf samples
- [x] Placeholder perf paths gone
- [x] S1 + S2 under contract; no scenarios suite
- [x] Existing CI gates unchanged
- [x] This done report written
