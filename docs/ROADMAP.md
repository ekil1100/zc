# ROADMAP.md — zc 详尽开发计划（对标并超越 mihomo/c）

## 0. 路线图说明

- 本文件是**唯一开发计划来源**
- AGENTS.md 只保留原则与协作规范
- 计划按阶段推进，允许并行，但必须有清晰里程碑与验收口径

## 发布里程碑（MVP → Beta → 1.0）

### MVP（已达成）
- 判定：Phase 0~2 的最小可用闭环已可复现（CLI/API 基础能力、基线测试、回归入口）。

### Beta（进行中）
- 口径：按“Beta 准入门槛”逐项打勾（见下文）。
- 当前重点：补齐 Phase 3 易用性 + Phase 4 稳定性门槛并持续验证。

### 1.0（GA）
- 进入条件：
  1) 满足 Beta 退出条件（连续两个迭代无 P0/P1 未收敛、72h 长稳通过、迁移边界清晰）；
  2) 兼容与迁移体验达到“可低成本迁移且行为可解释”；
  3) 运维与诊断能力可支持稳定对外使用。

---

## Phase 0 — 基线与差距分析（1~2 周）

### 目标
先“看清楚”，建立可量化对比。

### 任务
- [x] 梳理 mihomo/c 能力矩阵（功能、交互、性能、稳定性）
- [x] 梳理 zc 当前能力矩阵（已实现/缺失/不稳定）
- [x] 建立标准测试场景与样例配置集
- [x] 明确北极星指标与采样方法
- [x] 输出差距清单与优先级

### 交付物
- `docs/benchmark/baseline.md`
- `docs/roadmap/gap-analysis.md`

### 验收
- 可清晰回答“我们比谁差、差在哪、优先补什么”

---

## Phase 1 — CLI 直觉化（2~3 周）

### 目标
CLI 首次使用可猜、可完成核心任务。

### 任务
- [x] 命令模型统一：`zc <resource> <action>` + 常见快捷模式
- [x] 核心命令：`start/stop/restart/status`
- [x] profile 命令：`list/use/import/validate`
- [x] proxy 命令：`list/select/test`
- [x] 诊断命令：`diag doctor`
- [x] 全面支持 `--json`
- [x] 错误输出统一（原因 + hint + 文档链接）

### 交付物
- `docs/cli/spec.md`
- `docs/cli/migration.md`

### 验收
- 新用户 ≤5 分钟完成：启动 → 切换节点 → 查看状态

---

## Phase 2 — API 易用化（2~4 周）

### 目标
建立稳定、可集成、可文档化的 API v1。

### 任务
- [x] 定义资源模型（runtime/profiles/proxies/connections/rules/metrics）
- [x] 统一错误码结构：`code/message/hint`
- [x] REST + WebSocket 事件流边界清晰
- [x] 输出 OpenAPI 并自动校验
- [x] 关键端点集成测试覆盖

### 交付物
- `docs/api/openapi.yaml`
- `docs/api/error-codes.md`

### 验收
- API 可预测、版本稳定、可直接生成 SDK

---

## Phase 3 — TUI 易用化（2~3 周）

### 目标
让 TUI 成为“高效控制台”，不是“功能堆叠页”。

### 任务
- [x] 信息架构重排：Overview / Proxies / Connections / Logs / Diagnose
- [x] 全局快捷键统一：`? / / / g / r`
- [x] 代理组切换与延迟对比体验优化
- [x] 连接筛选/排序与日志过滤
- [x] 重载配置后结果反馈可见

### 交付物
- `docs/tui/interaction.md`
- `docs/tui/keymap.md`

### 验收
- 不看文档也能完成核心任务
- 首屏 3 秒可读懂当前状态

---

## Beta 准入门槛（新增）

> 建议：**在 Phase 3 验收完成后进入 Beta**，并在 Beta 期间持续执行 Phase 4 稳定性项。

进入 Beta 前需同时满足：

1. **可用性门槛（CLI/TUI/API）**
   - CLI 核心链路可闭环：启动 → 切换节点 → 状态确认 → 诊断
   - TUI 核心视图可独立完成常用操作（无需查文档）
   - API v1 关键资源与错误码稳定，文档与实现一致

2. **质量门槛（回归/兼容）**
   - 回归脚本稳定通过（本地与 CI 同口径）
   - `--json` 输出契约稳定（关键命令）
   - 至少覆盖一批常见 mihomo/c 配置迁移样例并可解释行为差异

3. **稳定性门槛（长稳/故障）**
   - 完成 24h 长稳测试且无阻塞级崩溃
   - 故障注入（超时/抖动/节点故障）具备可复现报告与恢复路径
   - 热重载失败可回滚，且有明确告警

4. **发布门槛（可观测/可支持）**
   - 提供基础运维文档（常见故障 + next-step）
   - 提供最小诊断包能力（日志/版本/配置摘要）
   - 关键指标可观测：启动耗时、规则延迟 p95、错误率

> Beta 退出条件（进入 GA 前）：
> - 连续两个迭代无 P0/P1 未收敛问题；
> - 72h 长稳通过；
> - 迁移兼容问题有明确边界与文档声明。

## Phase 4 — 性能与稳定性（持续）

### 目标
在关键指标上达到或超过基线，并具备长期稳定运行能力。

### 任务（性能）
- [x] 热路径 profiling（规则匹配、DNS、握手、转发）
- [x] 分配与内存行为优化
- [x] 连接池与并发调度优化

### 任务（稳定性）
- [x] 热重载回滚机制
- [x] 故障注入（超时、抖动、节点故障）
- [x] 24h/72h 长稳测试

### 交付物
- `docs/perf/reports/*.md`
- `docs/reliability/chaos-tests.md`

### 验收
- 指标稳定、可复现、无明显性能回退

---

## Phase 5 — 兼容与生态（并行）

### 目标
降低迁移成本，扩大可用生态。

### 任务
- [x] mihomo/c 配置兼容层
- [x] 迁移工具（lint + autofix）
- [x] 常见 GUI/面板接入说明
- [x] 样例配置库

### 交付物
- `docs/compat/mihomo-clash.md`
- `tools/config-migrator/`

### 验收
- 常见配置可低成本迁移，且行为可解释

---

## Phase 6 — 交付与安装体验（并行）

### 目标
提供“一键安装”最小可用链路（install/verify/upgrade），让新环境可快速落地并可验证。

### 任务
- [x] 设计安装脚本接口契约（输入/输出/失败 next-step）
- [x] 提供 install / verify / upgrade / rollback 三段+回滚最小命令
- [x] 定义失败场景回执与恢复建议（词典化）
- [x] 建立全量回归总入口 + evidence 自动归档与索引
- [x] 形成 Beta 退出检查清单 v1（含验证命令与证据路径）

### 交付物
- `docs/install/README.md`
- `scripts/install/oc-{install,verify,upgrade,rollback,run}.sh`
- `scripts/install/run-all-regression.sh`
- `scripts/install/next-step-dict.sh`
- `scripts/install/generate-evidence-index.sh`

### 验收
- 新机器可按文档执行 install -> verify -> upgrade（可选 rollback）流程
- 每步失败都给出可执行 next-step（统一机读字段）
- 单命令可执行全链路回归并输出失败分类

---

## 指标看板（持续更新）

- 启动耗时
- 规则匹配延迟（p50/p95）
- 单连接与并发吞吐
- DNS 解析耗时与命中率
- 错误率/重试率
- 长稳期间崩溃数与恢复时间

---

## 当前优先级（Now）

1. 执行 P6 Beta 退出检查清单 v1（稳定性窗口/通过率/证据完整性）
2. 满足准入后进入 P7（1.0 收口）
3. 保持安装链路总入口与证据索引每日可复核

---

## 日志系统 (Logging System)

### 目标
- 统一的日志系统，支持文件输出和控制台输出
- 可配置日志级别 (debug, info, warn, error)
- 日志轮转 (log rotation)
- 结构化日志 (JSON 格式可选)

### 阶段

#### Phase 1: 基础日志系统
- [ ] 统一日志接口，替换所有 `std.debug.print`
- [ ] 支持日志级别过滤
- [ ] 支持输出到文件和控制台

#### Phase 2: 高级特性
- [ ] 日志轮转 (按大小/时间)
- [ ] 结构化 JSON 日志
- [ ] 日志查询 CLI 工具
