# Standards 轴审查

## 硬性违规

- `src/eval_rule_matrix_runner.zig:18-157`：`loadFile`、`yamlString`、`buildConfigYaml`、`collectRuleStrings`、`parseCases`、`formatRuleLabel`、`runCase` 违反 `CONTRIBUTING.md:55-58`“函数和变量使用 snake_case”。
- `scripts/eval/suites/contract.sh:89-95,140-146`、`interop.sh:51-57`、`perf.sh:131-137`：捕获子命令状态后再次执行 `set +e`，导致后续 `jq`/`eval_write_report` 失败可被吞掉，成功路径仍退出 0；违反 `AGENTS.md:9`“关键路径可观测、稳定”。
- `scripts/eval/suites/contract.sh:116-120`：`git ... checkout -- tools/config-migrator/reports/... || true` 会无提示覆盖运行前已有的 tracked 修改，且隐藏恢复失败；违反 `AGENTS.md:25`“高风险改动必须能撤回”。
- `scripts/eval/scenarios/s1_startup.sh:66-80,120-130`：刚保存的 `CONFIG_HOME/STATE_HOME/CACHE_HOME` 被清空，失败清理遂以空 XDG 路径执行 `zc stop`，可能遗留 daemon；违反 `AGENTS.md:9` 的稳定性要求。
- `scripts/eval/selfcheck.sh:54-57,296-300,382-390` 未要求 `rg`，但把 `rg` 不存在与“无匹配”都记为 PASS；`src/eval_rule_matrix_runner.zig:208-215` 又把 OOM、类型错误和缺字段统一报成“missing”。二者违反 `AGENTS.md:6,9`“错误可操作、关键路径可观测”。
- `scripts/eval/suites/perf.sh:63-221` 没有行为测试（`selfcheck.sh:22-25` 明示永不执行 perf）；提交 `49ffbdb` 的 destructive restore 也未增加测试。违反 `AGENTS.md:23`“先测后改”及 `CONTRIBUTING.md:67-71`“新功能包含测试”。
- 删除 `latest.json`、重写性能 README 后，`docs/perf/reports/baseline-v1.0.0.md:66` 仍链接 `latest.json`，`docs/reliability/chaos-tests.md:209` 仍引用已消失的“README 第4节”；违反 `AGENTS.md:26`“用户可感知行为变化同步更新文档”。
- 提交 `107a52b test(eval): add ... selfcheck` 实际只改任务 Markdown；`d503c59 docs(agents): ...` 同时改 CI 行为。违反 `AGENTS.md:47`“提交信息清晰”及 `CONTRIBUTING.md:48-53` 的 Conventional Commits 类型语义。

## 判断项（smell baseline）

- **Duplicated Code**：`run.sh:140-155`、四个 `suites/*.sh` 的报告构造重复同一 envelope：`subject_commit: $subject, harness_commit: $harness, worktree_dirty: $dirty, env: $env`。
- **Speculative Generality**：`run.sh:84-89` 的 `is_known_suite()` 从未调用；`eval_rule_matrix_runner.zig:226-231` 明言仅为“keeps the helper available for diagnostics”而触碰 `formatRuleLabel`；`selfcheck.sh:75,305` 仍保留“early/later tasks”临时可选路径。
- **Repeated Switches**：suite 集合在 `run.sh:84-105`（`correctness|contract|interop|perf|reliability`）与 `schema/report.jq:20-25`（逐项 `or`）重复判别。
