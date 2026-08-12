# zc Eval Framework Implementation Plan

> **Status:** MVP complete on `wt/eval-framework` (temporary plan; not project docs)
> **Location:** `.agents/` only — do not promote into `docs/` unless a later task explicitly says so
> **Created:** 2026-08-12
> **Branch target:** `wt/eval-framework`
> **Baseline:** current `main`
> **For agentic workers:** execute task-by-task; each task has a hard acceptance check. Do not skip acceptance. One commit per completed task unless the task says otherwise.

## Goal

把仓库里已有的 test / contract / e2e / perf / reliability 门禁收成统一 eval 框架：

- 同一套 **Suite / Scenario / Metric / Gate** 概念
- 同一套 **report schema** 与 run 目录
- 一个薄编排入口，**不重写**现有测试本体
- 废止 placeholder perf 假绿
- 先交付可端到端跑通的 MVP，再逐条扩展热路径与场景

## Non-goals

- 不做 TUI / dashboard / 通用测试 DSL
- 不把网络 RTT 类指标放进每个 PR 的硬门禁
- 不在框架里二次实现代理协议
- 不把临时 plan 当作用户文档写进 `docs/`
- 不保留 placeholder PASS 兼容路径
- 不为尚未存在的 suite 预建插件系统

## Current inventory (reuse, don't rewrite)

| Layer | Existing entry | Notes |
| --- | --- | --- |
| Correctness | CI: `zig build -Dcpu=baseline` + `zig build test -Dcpu=baseline` | unit + process + oracle unit seams；eval 复用相同命令 |
| Contract smoke | `tools/config-migrator/run-all.sh`, `scripts/install/run-all-regression.sh` | eval 直接包装现有入口，不复制测试本体 |
| Beta aggregate | `scripts/run-beta-gate.sh`, `scripts/run-full-validation.sh` | 保留现有入口；eval 不再套一层 aggregate，避免重复执行与结果漂移 |
| Interop | `zig build e2e` / `e2e-release`, `docs/reliability/e2e.md` | gold standard；本地 `e2e`，现有 CI 继续跑 `e2e-release` |
| Perf record | `scripts/perf/run-control-plane-baseline.sh`, `src/perf_runner.zig` | facts only；要求 clean worktree；不作阈值判定 |
| Perf placeholder | `scripts/perf-regression.sh`, `scripts/perf/run-baseline.sh`, tracked `docs/perf/reports/latest.json` | **必须直接删除**，不保留 tombstone/成功 shim |
| Reliability | `scripts/reliability/*`, soak/chaos docs | 当前 `run-chaos-round.sh` 是 simulated PASS，不可包装为 eval 通过 |

## Unified model

Domain terms stay: `profile / proxy / proxy-group / rule / connection / runtime / health`.

Eval terms:

| Term | Meaning |
| --- | --- |
| **Suite** | `correctness` \| `contract` \| `interop` \| `perf` \| `reliability` |
| **Scenario** | frozen input + actions + expect / metric policy |
| **Metric** | comparable scalar or distribution with raw samples when measured |
| **Gate** | when to run + how to judge + whether merge/release blocks |

Hard rules (already proven in-tree):

1. Evidence and judgment are separate (`record` vs `compare` / gate).
2. No skip-as-pass / warning-as-pass；缺少命令/依赖是 `error`，已执行命令的非零退出是 `fail`。
3. `subject_commit`、`harness_commit` 与 `worktree_dirty` 都要记录；perf record 额外要求 clean worktree。
4. Unmeasured metrics go to `omitted[]`; never fabricate `0`.
5. Production binary under test stays isolated from oracles.
6. Daily outputs write under `.zig-cache/eval/`; tracked report promotion is explicit later.
7. 生产入口不提供能把真实命令替换为 `true` 的环境变量；selfcheck 用临时 `PATH` fake executable 测编排，不给正常运行留下 fake-pass 开关。

## Target layout after MVP

```text
scripts/eval/
  run.sh                 # orchestrator
  lib.sh                 # shared helpers
  selfcheck.sh           # fast contract checks; test-first growth
  schema/report.jq       # one executable jq contract for suite + summary
  suites/
  scenarios/
testdata/eval/
  scenarios/s1_startup/
testdata/rules/rule-matrix.yaml  # existing S2 fixture, now exercised
.zig-cache/eval/<run_id>/
  suites/<suite>.json
  summary.json
.agents/
  eval-framework-plan.md
  eval-framework-tasks.md
```

Project user docs under `docs/eval/` are **out of scope for MVP** unless a follow-up task is added after review.

## Report contract (MVP)

只维护一个可执行的 `scripts/eval/schema/report.jq` contract，避免同时维护 JSON Schema 与手写 validator。所有报告都含 `schema_version: 1` 与 `kind`：

- `kind="suite"`：包含 `run_id`、`timestamp`、`suite`（只允许五个 Suite）、`scenarios[]`、commits、`worktree_dirty`、`env`、`result`、`metrics`、`omitted[]`、`failed[]`、`artifacts[]`、`notes[]`；`steps[]` 可用于 contract 等多步骤 suite。
- `kind="summary"`：包含同一 run provenance、`requested_suites[]`、`suites[]`（suite/result/report path）、`result`、`failed[]`、`notes[]`。它同时承担 manifest 职责，不再生成重复的 `manifest.json`。

结果优先级固定为 `error > fail > pass`。所选 suite 都是 required；未选择的 suite 不写 skip/pass。S1/S2 是 contract suite 下的 Scenario，不新增第六个 `scenarios` Suite。每个 suite report 与最终 summary 写盘前都必须通过 `jq -e -f scripts/eval/schema/report.jq`。

## Scheduling (MVP intent)

| Trigger | Suites |
| --- | --- |
| Local `scripts/eval/run.sh --suite correctness` | correctness |
| Local full MVP | correctness + contract（含 S1/S2）+ perf record；perf 最后运行且 dirty worktree 明确 `error` |
| Local interop | 显式 `--suite interop` / `--with-interop`，委托 `zig build e2e --summary all` |
| Existing CI jobs | build/test/migrator/install/e2e-release 保持 authoritative；MVP 只额外接入 fast `selfcheck.sh`，不在 CI 录 perf |
| Nightly / release soak | reliability later phase；现有 simulated chaos 不得作为通过证据 |

## Phased delivery mapped to tasks

- **Phase A:** test-first selfcheck + thin orchestrator + executable report contract + wrap exact existing commands
- **Phase B:** S1/S2 scenario packages + contract assertions
- **Phase C:** kill placeholder perf green; real record path（compare remains deferred）
- **Phase D:** fold install/migrator into contract summary cleanly
- **Phase E:** reliability adapter
- **Phase F:** optional more scenarios / mihomo compare (not MVP)

## Execution rules for implementer

1. Work only in the assigned git worktree/branch.
2. Read this plan and `eval-framework-tasks.md` before coding.
3. Follow repo `AGENTS.md`: Zig 0.16.0+, no backward-compat shims, smallest complete step, Chinese replies/docs comments in code English.
4. Local daemon tests must not use port `7899`.
5. Do not commit secrets or force-push/rewrite shared history；Task 0 的本地 rebase 仅用于对齐 `origin/main`。
6. Tasks 1–10 必须 red → green：先在 `selfcheck.sh` 或任务专属 fixture 中加入会因缺失行为而失败的断言，确认非零，再实现并确认转绿；不得靠 fake-pass 环境开关验收。Task 7 因 recorder 强制 clean tree，允许先建 candidate commit 再实测；若失败，用小步 follow-up 修复，最终集成时按仓库规范 squash，不 amend/force-push；通过前不得勾选完成。
7. After each task: run its acceptance commands; only then finalize its Conventional Commit.
8. If blocked, stop and write blocker into task checklist notes rather than inventing scope.

## Success definition for the whole MVP

All of the following are true on the worktree branch:

1. `bash scripts/eval/run.sh --suite correctness` exits 0 on a healthy tree and writes validated suite + summary reports under `.zig-cache/eval/<run_id>/`.
2. `bash scripts/eval/run.sh --suite contract` runs migrator、install、S1、S2 and rolls them into the same contract report.
3. `bash scripts/eval/run.sh --suite interop` delegates to the existing local e2e entry and fails closed.
4. On a clean tree, `bash scripts/eval/run.sh --suite perf` records real control-plane evidence；dirty tree returns `error`；neither path claims threshold PASS.
5. Placeholder scripts and tracked fake `latest.json` are removed; active docs no longer advertise placeholder PASS.
6. S1 uses an isolated runtime and explicit non-7899 port；S2 drives the real rule engine from frozen cases rather than reimplementing matching in shell.
7. Existing CI gates remain unchanged and a fast eval selfcheck is added to CI; perf record stays local/manual.
8. Each completed task has a commit; plan/tasks checkboxes updated.
