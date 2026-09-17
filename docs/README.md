# zc 文档

当前活跃文档描述 Rust `1.0.1` 候选版本。默认 Cargo / just 构建与交付入口已切换 Rust；这不代表原有行为、性能、四平台发布及长稳已全部验收。入口概览见根目录 [README](../README.md)。

## 阅读导航

| 主题 | 文档 | 用途 |
| --- | --- | --- |
| 迁移 | [Rust 候选实现](migration/rust.md) | 模块职责、已接入能力、差异和待验收门禁 |
| CLI | [命令契约](cli/spec.md) | 命令、JSON、状态权威、reload/restart |
| 配置 | [Override](config/override.md) | 内嵌 Lua、外部脚本、冻结 materialization |
| 兼容 | [mihomo/clash 边界](compat/mihomo-clash.md) | TCP/UDP、provider、规则、DNS 与资源上界 |
| 迁移工具 | [规则速查](compat/migrator-rules-quickref.md) | 配置 migrator，不等于运行时支持声明 |
| 安装 | [构建与安装](install/README.md) | 发布矩阵、安装器与隔离验证 |
| API | [Minimal API](api/README.md) | 端点、鉴权、CAS 与 HTTP 上界 |
| 错误码 | [错误码字典](api/error-codes.md) | 冻结词汇与可操作错误 |
| E2E | [端到端门禁](reliability/e2e.md) | 独立 wire oracle 与真实二进制回归 |
| 长稳 | [运行指南](reliability/soak-guide.md) | 隔离 runner 与证据边界 |
| 性能 | [报告入口](perf/reports/README.md) | 性能证据及其 provenance |
| 协议依据 | [simple-obfs / SS UDP](research/shadowsocks-simple-obfs-udp.md)、[Trojan UDP](research/trojan-udp.md) | 协议研究与原验收依据 |

## 实现与证据分开

`src/main.rs` / `src/cli.rs` 提供 CLI，`src/store.rs` 管理不可变配置与 CAS，`src/service.rs` 准备运行快照，`src/daemon.rs` 管理实例身份与就绪，`src/api.rs` 提供 minimal API，`src/runtime.rs` 处理 mixed 数据面。原 Zig 文件暂留作迁移行为对照，不参与默认生产构建。

已存在的 `state-v2.json`、revision 与旧 daemon snapshot 有明确接管路径；损坏状态必须拒绝，不得删除重建或回退 DIRECT。细节见 CLI 与迁移文档。

[原 v1.0 路线图](roadmap/v1.0.md)、[CLI UX 决策记录](cli/ux-workflow.md)、日期化报告与 `archive/` 保留历史事实，不能把其中的完成标记当作 Rust 验收。TUI 已排除，旧 TUI 设计仅存档。项目图标位于 `assets/`。
