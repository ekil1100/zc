# v1.1.0-rc2 发布阻塞修复记录

## 状态

用户已确认目标为 `v1.1.0-rc2`，保留四平台发布检查；随后明确批准移除 macOS 原生系统信任/首次使用必过要求，保留可选手动测试和未验证边界。当前仍未更新 Cargo 版本、创建 tag 或发布 Release。修复与诊断位于 `fix/release-rc2-ci`；main 和已有 rc1 保持原样。

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

## Linux 停止超时的后续诊断

`3f83748` 的 [诊断 39565854524](https://github.com/ekil1100/zc/actions/runs/39565854524) 中，两架构完整用户服务测试均为 48/48；arm64 恢复样本 13/13，x64 为 12/13。x64 `recovery-1` 在两次安装失败回滚断言通过后，最后一次停止失败：Python 测试管理器发送 SIGTERM 后，原 5 秒等待结束仍判断进程存活。后续查询显示已停止；汇总日志包含 `daemon_stopped`，但缺少与超时断言对应的精确时间，尚不能确定原始根因。

`74efd48` 只增加测试诊断：显式 `ZC_SERVICE_STOP_DIAGNOSTICS=1` 时保存原存活采样的时间、PID、kill errno、原始 proc stat（含 starttime）和解析结果；发送信号及最终结果分别记录期限。超时后最多采集 32 个线程的 stat/wchan/stack，每字段最多 4 KiB，读取错误保留 errno。不读取 cmdline/environ，不追加信号，不放宽期限或重试。父测试在临时 HOME 删除前输出最后 60 条诊断和有限生命周期字段；成功样本也保留供对照。开关仅在专项 CI 压力步骤启用，生产代码及默认 CI 要求不变。

本机 14 项夹具回归通过，包含虚拟时钟超时仍报原错、诊断失败保留原停止结果、采样不追加存活检测、线程输出上界，以及真实 systemd 命令入口的操作名记录；真实隔离恢复场景在 launchd/systemd 两种替身均通过。另用本轮自建、忽略 SIGTERM 的 Python 子进程验证原 stop：约 5 秒后保留原失败断言并写出实际超时采样，随后由创建方回收该子进程。Ruff、格式、定向 Clippy、发布工作流契约及 6 项发布策略测试通过。原始日志和复现工件保留在 `target/diagnosis-39565854524/`。

[Linux 双架构运行 40340983012](https://github.com/ekil1100/zc/actions/runs/40340983012) 的完整套件均为 48/48；压力样本均在进入 systemd 替身时遇到新增诊断代码的 `IndexError`，不记作原停止故障复现。原因是 systemd 分支已拆分参数，诊断再次按旧位置读操作名。`8b911c3` 改为记录已解析的 command，真实 Python CLI 回归先红后绿；日志保留在 `target/diagnosis-40340983012/`。

修正后的 `8b911c3` / [Linux 双架构运行 40342641214](https://github.com/ekil1100/zc/actions/runs/40342641214) 已完成并通过：

| 原生定向检查 | Linux x64 | Linux arm64 |
| --- | --- | --- |
| 完整用户服务套件 | 48/48 | 48/48 |
| 恢复压力样本（1 串行 + 12 并发、4 workers） | 13/13 | 13/13 |
| 最后 60 条诊断中留存的停止结果数 | 52 | 53 |
| 留存采样的最长停止耗时（原期限 5 秒） | 0.162 秒 | 0.489 秒 |
| 原停止超时 | 未复现 | 未复现 |

工件位于 `target/diagnosis-40342641214/`；统计入口为 `target/diagnosis-39565854524/summarize-stop.py`。停止采样数受每个隔离子测试最后 60 条记录上限影响，不冒充全部停止调用。此次证明诊断接入后原生定向回归通过，原偶发超时根因仍未确认；没有放宽期限、修改产品代码或据此宣称原故障修复。本地 `main` 尚未合并。

## macOS 系统信任：已豁免发布阻塞，验证仍未完成

本轮核对 arm64/Intel 日志，User trust setter 均等待系统认证并超过 30 秒；严格清理仍报告 item-not-found。保留全部九项原生场景及 User deny 优先于 Admin trust，不以 Admin-only、无认证配置或仅模拟测试代替。

补充 runner 合约测试后 26 项通过；诊断合约 20 项通过。源码与凭据探索的结论见 [macOS 原生记录](reliability/macos-native.md) 和 [授权边界](reliability/macos-trust-auth.md)。探索工件留在 `target/`，尚无已验证的非交互 User setter 修复。

用户已批准将这九项原生系统信任/首次使用场景移出必过发布门禁；默认 CI 移除对应执行步骤，脚本与隔离合约测试保留。后续手动验证仍要求能完成正常系统认证的独占、可销毁 macOS 环境和严格清理。当前缺失证据不再单独阻塞发布，也不记为验收通过。四平台范围及其他检查保持不变；未批准 Linux-only 发布。
