# SPEC 轴审查

## (a) 缺失或部分实现

- **高** — 规范要求“Extend the existing `contract` adapter steps to migrator + install + S1 + S2”（`.agents/eval-framework-tasks.md:355`）。`scripts/eval/suites/contract.sh:131-164` 却把 S1/S2 当作 optional；脚本缺失时不记录 step/scenario/error，contract 仍可 PASS。

## (b) 未要求的行为（scope creep）

- **高** — 边界是 runner “loads the existing frozen YAML rules/cases”（tasks:326），仅在缺覆盖时新增 priority/non-hit case（tasks:328）。diff 却把冻结的 GEOIP 输入从 `114.114.114.114` 收为 `183.1.2.3`（`testdata/rules/rule-matrix.yaml:38-43`）；原输入交给新 runner 会 FAIL，故这是改基线以适配实现，而非执行既定场景。

## (c) 已实现但行为错误

- **高** — 规范：“每个 suite report 与最终 summary 写盘前都必须通过” contract（plan:94）。`scripts/eval/lib.sh:169-175` 先 rename 到最终路径、后验证；验证失败仍留下无效报告。contract/interop 还在 `set +e` 后忽略 `eval_write_report` 失败，可按命令结果退出 0。
- **高** — 规范：“已执行命令的非零退出是 `fail`”（tasks:11）。`contract.sh:62-72` 将任何 rc=2 当 `error`；`perf.sh:140-165` 将已执行 recorder/build 的多数非零结果当 `error`，导致应为 fail/1 的测量失败变成 error/2。
- **高** — 规范要求 perf “`metrics` contains only measured facts”（tasks:272）。`perf.sh:180-194` 读取不存在的 `.median/.p95`；producer 实际字段为 `median_ns_per_op/p95_ns_per_op`（`src/perf_runner.zig:247-309`），PASS 报告因此写入 null 并漏掉实测值。
- **高** — 规范要求 trap 使用“same isolated env”且最终 `status --json` 为 stopped（tasks:298,303）。S1 在 `scripts/eval/scenarios/s1_startup.sh:76-80` 清空三个 XDG 路径，trap 遂用不同环境；`:205-217` 又忽略 status 失败/无效 JSON，并接受 `starting` 等非 stopped 状态。
- **高** — 规范声称现有 case 覆盖 DOMAIN/suffix/keyword/fallback（tasks:328）。runner 在 `src/eval_rule_matrix_runner.zig:157-180` 只比 target、完全不核对 `matched_rule`；这些规则与 MATCH 都返回 PROXY，删除具体规则后仍可由 fallback 获得 6/6 PASS，实际未证明命中路径或优先级。
- **中** — selfcheck 必须验证“placeholder perf files/latest output are absent”（tasks:416）。`scripts/eval/selfcheck.sh:349-356` 恰在 `scripts/perf-regression.sh` 存在时直接跳过整组检查，placeholder 回归会令 CI 假绿。
