# zc 使用文档

这里介绍 zc 的安装、使用、配置与支持边界。当前文档描述 Rust `1.0.1` 候选；候选构建不等于正式发布，安装器提供的版本以实际 GitHub Release 为准。

## 阅读导航

| 你想做什么 | 文档 |
| --- | --- |
| 安装、升级或从源码构建 | [构建与安装](install/README.md) |
| 启停代理、管理 profile 和连接、使用 JSON 输出 | [CLI 命令契约](cli/spec.md) |
| 确认协议、规则、DNS 和配置支持范围 | [mihomo/clash 兼容边界](compat/mihomo-clash.md) |
| 使用 Lua 或外部脚本修改配置 | [配置 Override](config/override.md) |
| 检查 mihomo/clash 配置的迁移规则 | [迁移工具规则速查](compat/migrator-rules-quickref.md) |
| 通过 HTTP 查询状态、选择节点、管理连接 | [Minimal API](api/README.md) |
| 处理命令或 API 错误 | [错误码字典](api/error-codes.md) |
| 查看日志、故障记录、CPU 和内存趋势 | [运行时稳定性观测](reliability/observability.md) |

## 使用前注意

- 支持 Linux/macOS × x64/arm64；Rust 候选要求 macOS 15+，不支持 Windows。
- 默认代理端口是 `7899`；隔离试用或开发时显式使用其他端口，端口冲突会拒绝启动。
- 配置“可以读取”不等于其中所有能力都会执行；以兼容文档中的支持、忽略和拒绝范围为准。
- 升级前保留完整状态备份；损坏或未知格式会拒绝读取，不应通过删除状态目录解决。
- 项目提供 CLI 与 minimal API，不提供 TUI 或完整 mihomo Controller。

项目概览及快速开始见根目录 [README](../README.md)。
