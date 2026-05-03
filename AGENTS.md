# AGENTS.md

## 目标

zc 以 mihomo/clash 为基线，优先做好这几件事：
- CLI 直觉、默认值合理、错误可操作
- CLI / minimal API 概念一致
- 不做 TUI
- 关键路径可观测、稳定、性能可回归
- 兼容主流配置与生态

统一概念：`profile / proxy / proxy-group / rule / connection / runtime / health`

## 技术约束

- Zig 版本要求 `0.16.0+`
- CI 使用 `0.16.0`
- 本地开发默认使用 `0.16.0`
- 不降级到低于 `0.16.0` 的版本

## 工程规则

- 先测后改：改动前补测试，改动后跑回归
- 小步提交：一个 commit 只做一个逻辑变更
- 可回滚：高风险改动必须能撤回
- 文档同更：用户可感知行为变化同步更新文档
- 性能门禁：关键路径性能劣化不能直接合入

以下变更必须同步更新 `docs/` 下相关文档：
- `daemon/status`
- 代理协议兼容性
- 默认运行行为

## 方法选择

- 核心逻辑、协议边界、解析器：TDD
- CLI / minimal API 行为：BDD
- 性能与稳定性：Benchmark-Driven + Scenario-based

## 执行要求

- v1.0 发布计划以 `.agents/zc-v1.0-roadmap.md` 为工作事实源，公开文档入口为 `docs/README.md` 与 `docs/roadmap/v1.0.md`
- 任务推进必须先定义验收标准，再进入实现
- 路线变更时，先更新当前 v1.0 roadmap，再同步 `docs/README.md` / 相关用户文档

## 开发流程

- 本地开发启动 `zc` 时不要使用 `7899`，该端口保留给生产环境；优先提供 `zc start --port <port>` 这类显式入口，端口冲突时只报错并拒绝启动，避免误启动到其他端口
- 实现完成后用 [iterative-review-fix skill](./.agents/skills/iterative-review-fix/SKILL.md) 检视代码
- 完成验证后提交 commit，并合并回 `main`；合并完成后清理本地分支

## Git 规范

- 提交信息清晰，优先使用 Conventional Commits
- 提交前确保该范围内可用，至少相关测试通过

## 工作方式

先统一模型，再统一接口，再打磨体验，用数据证明更好、更快。
