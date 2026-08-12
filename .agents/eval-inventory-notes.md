# Eval Framework Inventory Notes

Frozen at branch bootstrap on `wt/eval-framework` (base `24645af` / `origin/main`).

## Tooling

| Check | Result |
| --- | --- |
| `zig version` | `0.16.0` (matches CI) |
| `jq` | available |
| `bash` | available |

## Existing entries to reuse

| Layer | Path | Role in eval |
| --- | --- | --- |
| Correctness | CI: `zig build -Dcpu=baseline` + `zig build test -Dcpu=baseline` | Task 3 wraps exact commands |
| Contract migrator | `tools/config-migrator/run-all.sh` | Task 4 step |
| Contract install | `scripts/install/run-all-regression.sh` | Task 4 step |
| Interop local | `zig build e2e` (`zig build --help` lists `e2e` and `e2e-release`) | Task 5 delegates local `e2e` |
| Interop CI | `zig build e2e-release` in `.github/workflows/ci.yml` | remains authoritative; eval does not own it |
| Interop docs | `docs/reliability/e2e.md` | present |
| Perf record | `scripts/perf/run-control-plane-baseline.sh` | Task 7 real record path |
| Beta aggregate | `scripts/run-beta-gate.sh` | keep as-is; eval does not re-wrap |
| Port policy | `AGENTS.md` forbids local daemon on `7899` | S1 must pick non-7899 port |

## Placeholder entries targeted for deletion (Task 6)

| Path | Why delete |
| --- | --- |
| `scripts/perf-regression.sh` | placeholder gate; prints `PERF_REGRESSION_RESULT=PASS` |
| `scripts/perf/run-baseline.sh` | writes fake `docs/perf/reports/latest.json` |
| `scripts/perf/check-readme-consistency.sh` | asserts obsolete fake-PASS contract |
| `docs/perf/reports/latest.json` | tracked placeholder output |

Do **not** delete `scripts/perf/run-control-plane-baseline.sh` or history blobs under `docs/perf/reports/history/` (historical only, non-authoritative).

## Reliability (later / Task 11 optional)

| Path | Note |
| --- | --- |
| `scripts/reliability/run-chaos-round.sh` | simulated PASS — must not wrap as eval evidence |
| `scripts/reliability/run-soak-real.sh` | possible future long wrap only |
| `scripts/reliability/run-soak.sh` | present |
| `scripts/reliability/run-rollback-check.sh` | present |

## CI gates that stay authoritative (unchanged in MVP except adding selfcheck)

From `.github/workflows/ci.yml`:

1. `zig build -Dcpu=baseline`
2. `zig build test -Dcpu=baseline`
3. `bash tools/config-migrator/run-all.sh`
4. `bash scripts/install/run-all-regression.sh`
5. `zig build e2e-release` (separate job)

MVP Task 13 only adds `bash scripts/eval/selfcheck.sh` to the build-test job.
