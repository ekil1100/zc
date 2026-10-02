# AGENTS.md

## 目标

zc 以 mihomo/clash 为基线，优先做好这几件事：
- CLI 直觉、默认值合理、错误可操作
- CLI / minimal API 概念一致
- 不做 TUI
- 关键路径可观测、稳定、性能可回归
- 兼容主流配置与生态

统一概念：`profile / proxy / proxy-group / rule / connection / runtime / health`

## 文档与任务入口

- 回答“下一步”、安排任务或调整排期前，先读 `.agents/development-priorities.md`；它是已确认开发优先级的唯一入口。验收阻塞和历史路线图不自动改变排期；新的优先级须经用户确认后更新该文件。
- `docs/` 只放对外文档：安装与使用、CLI/API、配置、兼容边界和用户排障；入口为 `docs/README.md`。
- 开发计划、设计研究、实现进度、测试与验收记录、历史材料放在 `.agents/`，入口为 `.agents/README.md`；原始运行工件放 `target/`，需要长期保留的证据放 `.agents/` 对应目录。
- 用户可感知行为写入 `docs/`，实现过程与证据写入 `.agents/`；两者混杂时拆分。移动文档须同步链接及脚本路径，不把内部材料重新写回 `docs/`。

## 技术约束

- Rust 最低版本 `1.91`（以 `Cargo.toml` 为准）；CI 固定 `1.98.1`，本地优先同版本
- 默认构建、测试与交付使用 Cargo / just；依赖使用已提交的 `Cargo.lock`
- 原生依赖需要 C/C++ 工具链与 CMake；E2E 需要 Python 3、Node.js 与 just
- 生产目标为 Linux/macOS × x64/arm64，不支持 Windows
- Zig `0.16.0` 仅用于迁移期历史行为对照，不作为 Rust 构建或运行时回退
- 修改状态、daemon 或协议时，先读 `docs/cli/spec.md`、`docs/compat/mihomo-clash.md` 及 `.agents/migration/rust.md`；既有数据损坏必须拒绝，不得删除重建
- 迁移验收以独立门禁证据为准，构建成功不代表性能、四平台或长稳通过

## 工程规则

- 先测后改：改动前补测试，改动后跑回归
- 小步提交：一个 commit 只做一个逻辑变更
- 可回滚：高风险改动必须能撤回
- 文档同更：用户可感知行为变化同步更新文档
- 性能门禁：关键路径性能劣化不能直接合入
- 任务推进先定义可验证的验收标准，再进入实现

以下变更必须同步更新 `docs/` 下相关文档：
- `daemon/status`
- 代理协议兼容性
- 默认运行行为

## 开发流程选择

- 核心逻辑、协议边界、解析器：TDD
- CLI / minimal API 行为：BDD
- 性能与稳定性：Benchmark-Driven + Scenario-based

## 开发流程

- 本地开发启动 `zc` 时不要使用 `7899`，该端口保留给生产环境；优先提供 `zc start --port <port>` 这类显式入口，端口冲突时只报错并拒绝启动，避免误启动到其他端口

## Git 规范

- 提交信息清晰，优先使用 Conventional Commits
- 提交前确保该范围内可用，至少相关测试通过

## 工作方式

先统一模型，再统一接口，再打磨体验，用数据证明更好、更快。
