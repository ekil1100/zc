# AGENTS.md — zc 协作准则

## 目标

zc 以 mihomo/c 为基线，优先做好这几件事：
- CLI 直觉、默认值合理、错误可操作
- CLI / API / TUI 概念一致
- 关键路径可观测、稳定、性能可回归
- 兼容主流配置与生态

统一概念：`profile / proxy / proxy-group / rule / connection / runtime / health`

## 技术约束

- Zig 版本要求 `0.15.0+`
- CI 使用 `0.15.2`
- 本地开发默认使用 `0.15.2`
- 不降级到 `0.13.0` 或更低版本

## 工程规则

- 先测后改：改动前补测试，改动后跑回归
- 小步提交：一个 commit 只做一个逻辑变更
- 可回滚：高风险改动必须能撤回
- 文档同更：用户可感知行为变化同步更新文档
- 性能门禁：关键路径退化不能直接合入

以下变更必须同步更新 `README.md`：
- `daemon/status`
- 代理协议兼容性
- 默认运行行为

## 方法选择

- 核心逻辑、协议边界、解析器：TDD
- CLI / API / TUI 行为：BDD
- 性能与稳定性：Benchmark-Driven + Scenario-based

## 执行要求

- 开发计划放在 `ROADMAP.md`
- 执行任务统一维护在 `TASKS.md`
- 任务状态变化时，实时更新 `TASKS.md`
- 每个功能先定义验收标准，再进入 DOING
- 路线变更时，先改 `ROADMAP.md`，再同步 `TASKS.md`

## Git 规范

- 提交信息清晰，优先使用 Conventional Commits
- 提交前确保该范围内可用，至少相关测试通过
- 完成一个原子变更后尽快 push
- 最晚每 60–90 分钟 push 一次，避免长期本地漂移
- 上下文切换前必须 push

## 工作方式

先统一模型，再统一接口，再打磨体验，用数据证明更好、更快。
