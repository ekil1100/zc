# Profiling & Regression Baseline Scaffold（P4-1.A）

## 0) 当前证据状态

`latest.json`、现有 `history/` 和 `scripts/perf/run-baseline.sh` 来自旧 placeholder scaffold：它们没有 raw samples，**不能作为真实性能基线或回归门禁证据**。

P0-6 Batch 1 新增只记录事实、不宣称 PASS/FAIL 的 ReleaseFast 入口：

```bash
bash scripts/perf/run-control-plane-baseline.sh \
  --samples 9 \
  --output .zig-cache/perf/control-plane.json
```

新入口至少输出 5 份 raw samples、median、nearest-rank p95、subject/harness commit、Zig version、machine/CPU、OS/arch/optimize provenance；默认拒绝 dirty worktree，只写 `.zig-cache/perf/`，并拒绝自动覆盖本目录 tracked report。`subject_commit` 默认必须等于 clean HEAD；唯一例外是 direct parent + 单个 harness-only commit，且变更路径受脚本 allowlist 约束。Batch 1 当前测量 `legacy_bounded_read`、`strict_bounded_read` 以及 1/100/1000 profiles 的 `authority_commit`；connection admission、flow RSS 和 config import 在对应 seam 落地前明确列为 omitted，禁止用 `0` 或环境变量假值代替。

旧 `scripts/perf-regression.sh` 暂时保留兼容，但其 placeholder PASS 不得用于 P0-6 完成判断。

## 1) 目标

建立 zc 性能回归最小脚手架，保证后续优化有统一口径：
- 可重复采样
- 可对比历史结果
- 可设置门禁阈值

---

## 2) 采样口径

### 2.1 执行原则
- 每轮至少执行 3 次采样，取中位数（median）作为本轮结果
- 采样环境尽量固定（机器/网络/配置）
- 指标统一记录到结构化文件（建议 JSON）

### 2.2 热路径采样计划（P4-1H）
- 采样对象（至少 3 条热路径）：
  1) 规则匹配路径（rule eval）
  2) DNS 解析路径（dns resolve）
  3) 连接握手路径（handshake/connect）
- 采样窗口：每条路径连续采样 **60s**
- 样本量：每条路径每轮至少 **200** 样本；每次回归跑 **3 轮**

### 2.3 热路径指标与采集方式
1) `rule_eval_p95_ms`
- 采集方式：在规则匹配关键路径打点，统计 p95（ms）
- 写入字段：`metrics.rule_eval_p95_ms.{value,threshold,pass}`

2) `dns_resolve_p95_ms`
- 采集方式：DNS 请求发起/返回打点，统计 p95（ms）
- 写入字段：`metrics.dns_resolve_p95_ms.{value,threshold,pass}`

3) `handshake_p95_ms`
- 采集方式：建立连接握手阶段打点，统计 p95（ms）
- 写入字段：`metrics.handshake_p95_ms.{value,threshold,pass}`

### 2.4 字段兼容约束（latest/history）
- 顶层字段保持兼容：`run_id` / `timestamp` / `mode` / `metrics`
- 新增指标仅追加在 `metrics` 对象内，不改已有键语义
- `latest.json` 与 `history/*.json` 使用同一 schema，保证可直接归档

### 2.5 统计字段建议
- `run_id`
- `timestamp`
- `scenario`
- `samples[]`
- `median`
- `threshold`
- `pass`

---

## 3) 目录约定

```text
docs/perf/reports/
  README.md                  # 本文件：口径与规范
  baseline-template.json     # 基线结果模板（后续生成）
  latest.json                # 最新一次采样（后续生成）
  history/
    YYYY-MM-DD-<run_id>.json # 历史归档（后续生成）
```

### 3.1 history 目录治理规则（P4-2.A）
- 命名规则：`YYYY-MM-DD-<run_id>.json`
- 保留上限：默认保留最近 **30** 份归档（按文件修改时间）
- 清理策略：超过上限时删除最旧文件（先清理 history，不影响 latest）
- 清理频率：每次回归执行后可触发一次

`latest.json` 与 `history/` 关系：
- `latest.json` 仅表示“最新一次执行结果”（可被覆盖）
- `history/` 保存历史快照（用于趋势回看）
- 每次执行流程建议：先写 `latest.json`，再拷贝到 `history/`

可执行清理入口：
```bash
# 保留最新30份历史归档（latest.json 不受影响）
bash scripts/perf/prune-history.sh 30
```
注意事项：
- 该清理入口仅处理 `docs/perf/reports/history/*.json`
- 不会删除或改写 `docs/perf/reports/latest.json`

---

## 4) 核心指标（含阈值占位）

> 当前阈值为占位值，后续按实测逐步收敛。

1. `rule_eval_p95_ms`
- 含义：规则匹配 p95 延迟
- 默认阈值占位：`<= 1.0 ms`
- 调整说明：
  - 若连续 3 轮稳定低于 0.7ms，可收紧到 `<= 0.8 ms`
  - 若新场景引入复杂规则，临时放宽不得超过 `<= 1.2 ms`

2. `dns_resolve_p95_ms`
- 含义：DNS 解析 p95 延迟
- 默认阈值占位：`<= 80 ms`
- 调整说明：
  - 若网络环境稳定且命中率提升，可收紧到 `<= 70 ms`
  - 若测试环境链路波动明显，临时放宽不得超过 `<= 100 ms`

3. `throughput_rps`
- 含义：端到端吞吐（每秒请求数）
- 默认阈值占位：`>= 800 rps`
- 调整说明：
  - 若 CPU/内存优化后稳定提升，可上调到 `>= 900 rps`
  - 若场景并发显著增大，临时下调不得低于 `>= 700 rps`

4. `reload_cost_ms`（可选扩展）
- 含义：配置重载耗时
- 阈值占位：`<= 500 ms`

---

## 5) 回归执行入口（本地 / CI 一致）

### 5.1 本地入口
- 命令：`bash scripts/perf-regression.sh`
- 约定：
  - `scripts/perf-regression.sh` 作为统一入口，内部转发到 `scripts/perf/run-baseline.sh`
  - 读取本文件定义的指标阈值
  - 输出 `docs/perf/reports/latest.json`
  - 同步归档到 `docs/perf/reports/history/`

### 5.2 CI 入口
- 命令：`bash scripts/perf-regression.sh`
- 约定：
  - 与本地完全同命令、同参数口径
  - CI 仅负责执行与门禁，不维护另一套脚本逻辑

### 5.3 通过 / 失败判定
- **通过标准**：
  1) 脚本退出码为 `0`
  2) 关键指标全部满足阈值（`rule_eval_p95_ms` / `dns_resolve_p95_ms` / `throughput_rps`）
- **失败判定**：
  1) 脚本退出码非 `0`
  2) 任一关键指标越阈值

### 5.4 本地执行与结果判读（最小）
1) 查看帮助：`bash scripts/perf-regression.sh --help`
2) 执行回归：`bash scripts/perf-regression.sh`
3) 一键一致性回归检查：`bash scripts/perf-regression.sh --check-consistency`
4) 终端判读：
   - `PERF_REGRESSION_RESULT=PASS` → 本轮通过
   - `PERF_REGRESSION_RESULT=FAIL` → 本轮失败
5) 返回码语义：
   - `0` = PASS
   - `1` = FAIL
   - `2` = 参数错误
6) 文件判读：查看 `docs/perf/reports/latest.json` 中各指标的 `value/threshold/pass`。

---

## 6) 脚本接入指导（下一步）

后续脚本（建议：`scripts/perf/run-baseline.sh`）需至少完成：
1) 执行固定场景采样
2) 产出 `latest.json`
3) 对比阈值并输出 `pass/fail`
4) 将结果归档到 `history/`

输出示例（概念）：
```json
{
  "run_id": "p4a-001",
  "timestamp": "2026-02-11T09:40:00+08:00",
  "metrics": {
    "rule_eval_p95_ms": { "value": 0.82, "threshold": 1.0, "pass": true },
    "dns_resolve_p95_ms": { "value": 73.0, "threshold": 80.0, "pass": true },
    "throughput_rps": { "value": 910, "threshold": 800, "pass": true }
  }
}
```

### 6.1 一次执行结果样例（与当前脚本输出一致）

字段顺序（固定）：
1) 终端输出顺序：
   - `PERF_REGRESSION_RESULT=<PASS|FAIL>`
   - `PERF_REGRESSION_REPORT=<path>`（仅 PASS 路径保证输出）
2) `latest.json` 顶层字段顺序：`run_id` -> `timestamp` -> `mode` -> `metrics`
3) `metrics` 子字段顺序：`rule_eval_p95_ms` -> `dns_resolve_p95_ms` -> `throughput_rps`

#### 成功样例（PASS）
终端输出：
```text
PERF_REGRESSION_RESULT=PASS
PERF_REGRESSION_REPORT=/path/to/zc/docs/perf/reports/latest.json
```
返回码：`0`

结果文件（`latest.json`）关键字段示例：
```json
{
  "run_id": "p4d-placeholder-1739241000",
  "timestamp": "2026-02-11T02:30:00Z",
  "mode": "placeholder",
  "metrics": {
    "rule_eval_p95_ms": {"value": 0.0, "threshold": 1.0, "pass": true},
    "dns_resolve_p95_ms": {"value": 0.0, "threshold": 80.0, "pass": true},
    "throughput_rps": {"value": 0, "threshold": 800, "pass": true}
  }
}
```
判定规则：终端为 `PERF_REGRESSION_RESULT=PASS` 且返回码 `0` 即通过。

#### 失败样例（FAIL）
终端输出（示例）：
```text
PERF_REGRESSION_RESULT=FAIL
```
返回码：`1`

判定规则：出现 `PERF_REGRESSION_RESULT=FAIL` 或返回码非 `0` 即失败；
若是参数错误（如未知参数），返回码为 `2`，同样按失败处理。

对应关系说明（与 `scripts/perf-regression.sh` 一一对应）：
- 成功路径：输出 `RESULT=PASS` + `REPORT=<path>`，返回 `0`
- 失败路径：输出 `RESULT=FAIL`，返回 `1`
- 参数错误：返回 `2`（可视为 FAIL）

---

## 7) 失败后处理建议（P4-1.C）

当回归失败（exit code != 0 或指标越阈）时：

1. **先定位再调阈值**
- 优先检查当次 `latest.json` 与最近 3 次 `history/*.json`，确认是否偶发抖动。
- 对应定位方向：
  - `rule_eval_p95_ms` 超阈：先看规则数量、匹配顺序、缓存命中
  - `dns_resolve_p95_ms` 超阈：先看 DNS 上游、缓存命中率、网络抖动
  - `throughput_rps` 低于阈值：先看 CPU 饱和、连接复用、锁竞争

2. **放宽阈值的前置条件**
- 只有在“可解释的环境变化”下才可临时放宽；
- 放宽必须记录原因、范围、回收时间（何时恢复原阈值）；
- 禁止一次性大幅放宽（遵循上文“调整上限”）。

3. **回归恢复路径**
- 修复后至少重跑 3 轮；
- 若恢复达标，再关闭失败告警并保留修复记录。

## 8) 验收对齐（P4-1.A / P4-1.C）

- [x] 定义 profiling 目标、采样口径、目录约定
- [x] 至少 3 个核心指标 + 阈值占位
- [x] 文档可直接指导脚本接入
- [x] 核心指标具备默认阈值占位 + 调整说明
- [x] 失败后处理建议可执行
