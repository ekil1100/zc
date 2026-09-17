# 完整迁移验收

目标是以纯 Rust 生产二进制替换当前 Zig 已支持能力，不增加原本未支持的 mihomo 协议。
现有 Zig 源码只作规范和测试对照，不通过 FFI、子进程转发或旧二进制 fallback 实现 Rust 功能。

## 验收接口

- 公开 CLI：命令树、JSON envelope、退出码、错误提示、非交互行为。
- 配置与存储：Zig catalog/revision 样本可被 Rust 验证读取；更新保留格式与数据，原子提交且跨进程互斥。
- Runtime：实例 nonce/锁/描述符绑定，准备失败不停止旧实例，停止不向未经认证的数值 PID 发信号。
- Wire：HTTP/SOCKS5、SS/Trojan TCP/UDP、simple-obfs 与独立固定服务端互操作。
- Minimal API：现有 endpoint、鉴权、managed identity 与 selection generation。
- 工程：Rust 构建、测试、lint、E2E、发布与安装路径；不得用删除负测换取通过。

## 进度

- [x] 配置兼容、provider、动态代理组选择与上下文规则（当前受支持范围）。
- [x] catalog/revision、本地依赖捕获、旧数据读取与安全更新。
- [x] Lua/可执行 override 与冻结 materialization。
- [x] SS/Trojan UDP 与 simple-obfs HTTP。
- [x] daemon、minimal API、完整 CLI 与诊断。
- [x] 独立旧版 E2E、状态样本互读、进程/资源负路径本机回归。
- [ ] 性能与长稳验收、四平台发布、安装器切换。
- [ ] 删除已替代的 Zig 生产路径并同步全部有效文档。

## 最终候选的直接证据

勾选代表本机现有验收语料通过，不代表四平台所有行为或发布门禁完成。

- `just check`：格式检查与全目标严格 Clippy 通过。
- `just test --all-targets`：全部通过；默认忽略的真实 300 秒 UDP idle 用例已另行执行通过。
- `bash scripts/run-beta-gate.sh`：最终 `BETA_GATE_PASS=6/6`，覆盖 Release、check、tests、交付契约、原样 core + 独立 TCP E2E、隔离安装/回滚回归。原 `scripts/e2e/run-core.sh` 未修改。
- schema-1/schema-2、canonical hash、认证旧 snapshot、fsync 注入、CAS/并发与恢复用例通过；重启停止超时的 staged snapshot 泄漏已由公开 CLI 回归锁定。
- provider cache 的 source/文件系统别名覆盖、整体展开失败提前发布、group/other 可写输入三个问题已修复；doctor 多错误、warnings、迁移提示及预算已补齐。依据和定向证据见 [Rust 迁移](rust.md)。
- daemon/CLI fixture 的 macOS socket 继承竞态已隔离，未放宽生产身份或 metadata 校验，未移除单用例内部并发场景。历史失败和根因见 [fixture 记录](../reliability/daemon-fixtures.md)。
- Linux/macOS × x64/arm64 四目标 Release 编译通过，Linux 为静态 musl 产物。本机仅执行 macOS arm64；其余目标仍待原生 CI。日志为 `target/cross-verification/logs/final-*.log`。
- eval selfcheck 44 项、helper 5 项、tooling 2 项、可靠性 runner 3 项，以及许可生成器 8 项与 `--check` 通过。许可范围/人工审核限制未消除。
- 最终 60 秒真实 soak：61 次转发、零崩溃/失败；10 秒进程退出恢复：11 次探测、零非注入崩溃/失败。不是 24/72h 长稳。

最后一次总门禁日志：`/tmp/zc-final-beta-gate-r3.log`；全部 target tests：`/tmp/zc-final-all-targets.log`；UDP idle：`/tmp/zc-final-udp-idle.log`。这些是本次本地工件，尚非远端 CI 或已提交的发布证明。

## 仍阻塞完整验收

1. **性能尚未放行**：最终 Release 探索性对照中，100 条规则 `config dump` 为 Rust 4.106 ms / Zig 3.032 ms，慢 **35.4%（1.074 ms）**。万规则改善、loopback 中位数接近不能抵消该退化；dirty candidate 不冒充 clean-commit 基线。原始样本和方法见 [performance](performance.md)。
2. **平台和可靠性证据未齐**：其余三目标原生运行、远端 CI、24/72h 长稳、完整 RSS/尾延迟门禁尚未证明；资源/DNS/TLS 等已知差异仍按迁移文档显式保留。
3. **发布尚未切换**：原 Zig 对照源码保留；未覆盖本机安装、未迁移真实 HOME。上述本地验收来自当时的未提交工作区；后续提交和候选分支推送不代表发布、生产安装或性能放行。许可自动检查不替代最终发行审核。

只有有直接测试证据的项才能勾选。迁移完成前不覆盖本机已安装二进制，不触碰生产端口 7899，所有状态测试使用临时 HOME/XDG 目录。
旧状态默认保留，损坏或未知格式拒绝；不以初始化空 catalog、删除原文件或静默回退来“迁移”。
