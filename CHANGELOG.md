# Changelog

## [Unreleased] - 1.2.0-rc1

### Added - 生态与安装
- **Homebrew 支持** - 可通过 `brew install zc` 安装 (P17-1A)
- **Debian/Ubuntu 包** - 提供 `.deb` 包及构建脚本 (P17-1B)
- **systemd 服务文件** - 支持 `systemctl enable/start zc` (P17-1C)
- **安装指南整合** - 统一文档入口，支持 curl/Homebrew/Debian/源码安装 (P20-1A)

### Added - 迁移规则（R1-R31）
- R1-R27: 基础迁移规则集（端口类型、日志级别、代理组、DNS、规则等）
- R28: 更多代理类型检测（snell/tuic/hysteria 未支持提示）(P17-1D)
- R29: 端口冲突检测 (P18-1D)
- R30: 配置项重复检测 (P19-1B)
- R31: DNS 服务器有效性提示 (P19-1C)

### Improved - 配置与测试
- **复杂配置样本** - `testdata/config/all-proxy-types.yaml` 覆盖所有代理类型 (P20-1B)
- **回归测试脚本** - `tools/config-migrator/test-complex-config.sh` 验证复杂配置 (P20-1B)
- **下载配置修复** - 添加 User-Agent header 修复 403 错误，并补充单元测试

### Documentation
- 完整安装指南 (`docs/install/README.md`)
- Homebrew/Debian/systemd 独立文档
- 迁移规则速查表更新到 R31
- 风险与回滚策略文档

---

## [1.0.0] - 2026-02-17

### Added - 核心功能
- **CLI 直觉化** - 统一的 `zc <resource> <action>` 命令模型
- **API v1** - RESTful API 与 WebSocket 事件流
- **TUI 控制台** - 高效的终端交互界面
- **配置热重载** - 支持动态配置更新与回滚

### Added - 代理协议
- Shadowsocks (ss) - 支持多种加密算法
- VMess - 支持 TLS/WebSocket
- Trojan - 支持 SNI
- VLESS - 支持 TLS
- HTTP/SOCKS5 代理

### Added - 规则引擎
- DOMAIN/DOMAIN-SUFFIX/DOMAIN-KEYWORD
- IP-CIDR/IP-CIDR6
- GEOIP
- DST-PORT/SRC-PORT
- PROCESS-NAME
- MATCH (final)

### Added - 安装与部署
- curl 一键安装脚本
- 安装契约与验证框架
- Beta 验收清单与证据归档

### Added - 测试与质量
- 31 条配置迁移规则
- 回归测试套件
- 安装流程验证脚本
- 跨环境测试（路径/权限/冲突）

---

## [0.1.0] - 2025-12

### Added
- 初始项目结构
- Zig 构建系统
- 基础代理转发功能
- YAML 配置解析
