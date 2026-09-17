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
- [x] 候选 `10d2bab` 的 Linux/macOS × x64/arm64 原生 CI、生产产物与产物回归。
- [ ] 新 macOS 15 延迟初始化候选的完整原生信任/首次使用门禁。
- [ ] 性能与长稳验收、正式发布及本机安装切换。
- [ ] 删除已替代的 Zig 生产路径并同步全部有效文档。

## macOS 15 延迟初始化候选

用户已批准最低 macOS 提高到 15。构建配置、最终产物校验、ad-hoc 签名和冷启动检查已接入；本机 Debug/Release arm64 通过，旧产物在新契约下明确失败。原生 trust/首次 DNS/并发验证只在显式授权的一次性 CI runner 执行，不以本机假 HOME 冒充系统信任隔离。

[CI 35234530286 / `23eb9a1`](https://github.com/ekil1100/zc/actions/runs/35234530286)：Linux x64/arm64 全部通过；macOS 15 arm64、15 Intel 和较新 arm64 均通过产物最小版本/强延迟标记、签名、冷启动及产物 E2E，真实 native baseline-untrusted 也通过。但随后 User trust 写入/清理失败，**完整原生门禁尚未通过**。

[诊断 CI 35240315075 / `5ab079b`](https://github.com/ekil1100/zc/actions/runs/35240315075) 的 Linux 两架构继续通过；两个 arm64 系统的直接栈确认 `/usr/bin/security` 卡在 TrustSettings 写入的同步 XPC，原 30 秒超时和清理失败均保留。尚无服务端证据证明 GUI/授权或锁根因。Intel 本轮另在 shadowsocks-rust UDP core E2E 阶段超时，尚未定位，不能用历史 PASS 覆盖。没有修改授权策略、增加重试/超时或跳过测试。

见[实施与边界](../research/macos-framework-startup.md#后续实施状态)和[原生门禁](../reliability/macos-native.md)。不能复用下节 `10d2bab` 的成功作为新构建放行证据。

## 已通过候选的远端证据

候选 `10d2babb62b9406cbcd8cd76514d4dd1c32fef78` 的 [CI 35176614058](https://github.com/ekil1100/zc/actions/runs/35176614058) **四项全部成功**：

| 原生 runner | 生产目标 | 结果 |
| --- | --- | --- |
| ubuntu-latest | x86_64-unknown-linux-musl | PASS |
| ubuntu-24.04-arm | aarch64-unknown-linux-musl | PASS |
| macos-latest | aarch64-apple-darwin | PASS |
| macos-15-intel | x86_64-apple-darwin | PASS |

每项运行格式/Clippy、公开接口测试、交付与 beta gate 契约、core/独立 TCP 互操作、隔离安装回归；随后以指定 target 构建实际 Release 产物，再对该产物运行 core、独立 TCP E2E 和隔离安装测试。Linux 另验证静态链接与隔离默认端口。这不是仅交叉编译通过，也没有重跑失败 job、扩大超时或删掉负测。

此前失败已分别处理：可移植 shell YAML fixture、跨空闲阶段存活的 obfs oracle、[capture metadata 校验](../reliability/read-capture.md)、[冻结可执行文件 ETXTBSY](../reliability/override-spawn.md)。最后一项只在原始 deadline 内等待确定的 busy 错误，不重试权限等其他失败、不切换解释器；保持 8 × 64 并发调用和完整性断言。原失败记录仍保留。

上述勾选只代表这些 runner、语料和候选通过，不等于所有旧 OS 版本、性能、24/72h 长稳或正式发布已经完成。原始结果快照：`target/ci/35176614058/result.json`。

## 历史本机验收补充

以下是在此前未提交工作区完成的本机证据；保留其来源边界，不冒充当前提交的长稳或远端运行结果。

- `just check`：格式检查与全目标严格 Clippy 通过。
- `just test --all-targets`：全部通过；默认忽略的真实 300 秒 UDP idle 用例已另行执行通过。
- `bash scripts/run-beta-gate.sh`：最终 `BETA_GATE_PASS=6/6`，覆盖 Release、check、tests、交付契约、原样 core + 独立 TCP E2E、隔离安装/回滚回归。原 `scripts/e2e/run-core.sh` 未修改。
- schema-1/schema-2、canonical hash、认证旧 snapshot、fsync 注入、CAS/并发与恢复用例通过；重启停止超时的 staged snapshot 泄漏已由公开 CLI 回归锁定。
- provider cache 的 source/文件系统别名覆盖、整体展开失败提前发布、group/other 可写输入三个问题已修复；doctor 多错误、warnings、迁移提示及预算已补齐。依据和定向证据见 [Rust 迁移](rust.md)。
- daemon/CLI fixture 的 macOS socket 继承竞态已隔离，未放宽生产身份或 metadata 校验，未移除单用例内部并发场景。历史失败和根因见 [fixture 记录](../reliability/daemon-fixtures.md)。
- Linux/macOS × x64/arm64 四目标 Release 编译通过，Linux 为静态 musl 产物。当时本机仅执行 macOS arm64，其余目标的原生证据现由上节 CI 补齐。该轮交叉编译日志为 `target/cross-verification/logs/final-*.log`。
- eval selfcheck 44 项、helper 5 项、tooling 2 项、可靠性 runner 3 项，以及许可生成器 8 项与 `--check` 通过。许可范围/人工审核限制未消除。
- 最终 60 秒真实 soak：61 次转发、零崩溃/失败；10 秒进程退出恢复：11 次探测、零非注入崩溃/失败。不是 24/72h 长稳。

该轮本机总门禁日志：`/tmp/zc-final-beta-gate-r3.log`；全部 target tests：`/tmp/zc-final-all-targets.log`；UDP idle：`/tmp/zc-final-udp-idle.log`。这些是本次本地工件，尚非远端 CI 或已提交的发布证明。

## 仍阻塞完整验收

1. **性能尚未放行**：新 `bdefd33` clean-commit 冻结 Release 的 100 条规则 dump 为 Rust 3.469 ms / Zig 2.952 ms，仍慢 **17.5%（0.517 ms）**。另一次固定旧/新 Rust 和相同 Zig 的同批对照显示本次构建调整使 dump 下降 32.6%，但新 Rust 仍比 Zig 慢 16.1%。不同批次/采样口径不混算，不降低阈值；完整样本、hash 与限制见 [performance](performance.md)。
2. **原生与可靠性证据未齐**：旧候选四平台通过不替代当前 macOS TrustSettings 门禁；系统信任写入已定位为同步 IPC 等待，但服务端根因和真实信任正/负矩阵尚未完成；最新 Intel UDP E2E 超时也待定位。24/72h 长稳、完整 RSS/尾延迟与受支持 OS 矩阵未全部证明。
3. **发布尚未切换**：原 Zig 对照源码保留；未覆盖本机安装、未迁移真实 HOME。上述本地验收来自当时的未提交工作区；后续提交和候选分支推送不代表发布、生产安装或性能放行。许可自动检查不替代最终发行审核。

只有有直接测试证据的项才能勾选。迁移完成前不覆盖本机已安装二进制，不触碰生产端口 7899，所有状态测试使用临时 HOME/XDG 目录。
旧状态默认保留，损坏或未知格式拒绝；不以初始化空 catalog、删除原文件或静默回退来“迁移”。
