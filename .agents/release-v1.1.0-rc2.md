# v1.1.0-rc2 发布阻塞修复记录

## 状态

用户已确认目标为 `v1.1.0-rc2`，保留四平台完整发布门禁。当前仍未更新 Cargo 版本、创建 tag 或发布 Release。修复与诊断位于 `fix/release-rc2-ci`；main 和已有 rc1 保持原样。

## Linux 测试状态发布

基线 `25c2658` 的 [CI 38707401434](https://github.com/ekil1100/zc/actions/runs/38707401434) 在两种 Linux 架构上失败于 `failed_new_binary_and_publication_restore_real_old_binary_and_invocation`。arm64 恢复时读到不完整的 `fake-manager.json`；x64 的最后一次停止超过测试管理器 5 秒等待。后者的唯一根因尚未证明。

`tests/support/service_manager.py::save` 原先直接覆盖状态文件。定点打断写入以及在部分写入窗口读取状态，两项测试均产生 JSONDecodeError。现在完整写入同目录、按 PID 命名的临时文件，再原子替换原文件；失败保留原完整状态。不增加超时、重试、空状态回退或生产行为变更。临时 HOME 负责清理由 SIGKILL 留下的工件。

`tests/user_service.rs` 的隔离父测试在失败时仅记录最近 30 条日志的固定生命周期字段，不转储配置、snapshot、secret 或原始错误。诊断工作流独立于验收门禁，保留全部样本。

## 原生证据

| 提交与运行 | Linux x64 | Linux arm64 |
| --- | --- | --- |
| `9ab26c0` / [38730564597](https://github.com/ekil1100/zc/actions/runs/38730564597) | 安装恢复 13/13 | 安装恢复 13/13 |
| `9f2949e` / [38731283459](https://github.com/ekil1100/zc/actions/runs/38731283459) | 完整用户服务 48/48，安装恢复 13/13 | 完整用户服务 48/48，安装恢复 13/13 |

每轮恢复样本含 1 个串行样本和 12 个并发样本（4 workers），每个样本仍覆盖 launchd/systemd 两种替身和真实隔离 daemon、安装与失败恢复。没有修改原断言与产品期限。

下载工件分别位于 `target/release-blocker-native-38730564597/`、`target/release-blocker-native-38731283459/`。这些结果证明当前修复的原生定向回归通过，不能独立证明 x64 原超时的唯一原因，也不替代完整 main CI、musl 交付、性能或长稳门禁。

本机另通过管理器夹具 7 项、用户服务 48 项及 Ruff/格式检查。

## macOS 仍受阻

本轮核对 arm64/Intel 日志，User trust setter 均等待系统认证并超过 30 秒；严格清理仍报告 item-not-found。保留全部九项原生场景及 User deny 优先于 Admin trust，不以 Admin-only、无认证配置或仅模拟测试代替。

补充 runner 合约测试后 26 项通过；诊断合约 20 项通过。源码与凭据探索的结论见 [macOS 原生记录](reliability/macos-native.md) 和 [授权边界](reliability/macos-trust-auth.md)。探索工件留在 `target/`，尚无已验证的非交互 User setter 修复。

继续完整发布需要能完成正常系统认证的独占、可销毁 macOS 环境及九项原生通过证据；当前发布仍受阻，Linux-only 范围未被批准用于 rc2。
