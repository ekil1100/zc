# 本地安装异步停止修复验收

## 范围与结论

修复 `just install` 在管理器已确认停止、daemon 尚在退出时误报 `SERVICE_CONTENDED: captured runtime changed` 的问题。用户授权检查后修复；本轮未安装到真实用户目录、未操作原生用户服务、未提交或推送。所有运行测试使用临时 HOME/runtime 和非生产端口。

本机为 macOS arm64，构建、测试和 Clippy 使用 Rust 1.98.1、已提交 Cargo.lock 和已有依赖缓存。结论只覆盖本轮候选与下列场景；未证明 Linux 原生管理器、其他平台、性能或长稳。

## 修复边界

- `src/daemon.rs`：服务捕获固定原 runtime 目录及现存实例锁文件句柄。停止前继续严格验证稳定状态；停止确认在 descriptor 清理锁内只检查 PID、nonce、服务身份和原锁释放，不重读退出中的配置快照。文件已清理但原锁仍被持有时继续等待；目录、锁、PID/nonce/服务身份变化拒绝。
- 已停止服务可能留下合法 descriptor/PID 文件。捕获其原停止态基线，允许原样保留；不把新出现的文件或锁持有者当作原状态，也不删除重建。
- `src/user_service.rs`：安装、service stop/restart 及恢复停止共用有界确认。管理器确认 stop 后，使用共享 5 秒预算等原实例锁释放并确认管理器 PID 为空，再进入发布或恢复启动。
- 区分停止未请求、回执未确认、请求已确认、退出已确认。回执丢失或退出未确认时恢复原注册和启动许可、保留旧二进制与恢复备份，明确报告恢复失败/运行态未确认，不根据一次旧 PID 观察宣称恢复成功。请求已确认后的等待收到安装中断时，先完成有界停止确认，再进行恢复。
- readiness 使用共享 10 秒工作预算，内部管理器命令共用剩余时间。超时仍经原命令组终止与直接子进程回收路径；没有用外层 timeout 丢弃命令 future。同步检查结束后也拒绝迟到 ready。
- Linux ExecStart 校验先匹配完整注册路径/argv，再检查剩余元数据中的多命令分隔符；允许合法路径包含 `} ;`，继续拒绝额外命令或参数。
- 用户契约同步至 `docs/cli/spec.md` 和 `docs/install/README.md`。Release 安装器共用事务，其信号回归更新为保留证据、确认状态后显式恢复。

## 红绿证据

原始工件位于 `target/install-audit/`，属于本机运行工件，不随仓库保存。

| 场景 | 修改前/首次结果 | 修复后 |
| --- | --- | --- |
| 管理器先返回、稍后完成停止；真实 daemon/安装 | 10/10 误回滚，其中 4 次完整复现用户错误；同步停止对照 10/10 成功 | 原始异步探针 10/10 成功 |
| 正式异步停止回归，安装/restart/stop | `SERVICE_STOP_FAILED: service is still running` | 两适配器均通过；另覆盖等待中的 SIGINT 和原调用恢复 |
| stop 已确认但原实例未退出 | 恢复失败留下错误启动许可；systemd 路径还可能虚报原运行态已恢复 | 原注册字节、旧二进制和备份保留；返回未确认；测试返回后再放行独立停止 |
| stop 回执丢失、后台请求稍后完成 | 旧代码存在基于瞬时 PID 的成功恢复分支 | 独立请求测试确认无错误恢复声明、保留证据 |
| readiness 内管理器命令挂起 | 命令仍等待约 15 秒，超过共享 10 秒预算 | 在剩余预算内终止；返回前清理辅助进程，放行屏障后无迟到写入 |
| Linux 路径含 `} ;` | 合法调用被报 `SERVICE_FOREIGN` | 生命周期通过；额外 argv/第二命令仍拒绝 |
| 原服务被强制退出、留下合法 descriptor/PID | 首版停止等待过度拒绝停止态安装 | 补充停止态基线捕获后通过，遗留文件原样保留 |

正式身份边界回归覆盖：退出清理移除 descriptor/PID 后仍持有原实例锁，nonce、service_id、PID 变化，实例锁 inode 替换及整个 runtime 目录替换。所有替换场景均拒绝发布，并检查目标二进制 inode 未改变。

## 最终验证

共 **96 项相关 Rust 测试通过**，不重复计入测试内部隔离子进程：

| 测试集 | 通过数 |
| --- | ---: |
| `user_service` | 46 |
| `daemon` | 20 |
| `daemon_races` | 8 |
| `fsutil` | 18 |
| lib `lifecycle_tests` | 4 |

首轮相关回归曾有 1 项既有夹具失败：取消测试仅按 PID 文件存在判断写入完成，命令组终止时文件可能仍为空。将测试 PID 文件改为临时文件写完后 rename 发布；定向复测及随后完整 46 项用户服务测试均通过。未放宽生产清理断言或延长超时。

另通过：

- 原始异步安装探针 10 次升级；日志 `original-probe-green.log`。
- `scripts/install/verify-local-dev-install.sh`，含运行目标、发布竞争和 symlink 拒绝；日志 `fix-publisher.log`。
- `scripts/install/test-release-service.py`：两适配器共 24 个成功/回滚/中断场景；日志 `release-service-green.log`。使用独立测试入口和真实隔离二进制，未调用原生 launchctl/systemctl。
- `cargo +1.98.1 clippy --offline --locked --all-targets -- -D warnings`。
- `cargo +1.98.1 fmt --all -- --check`、`git diff --check`。
- 修改的 Python 文件通过 Ruff 0.16.8 检查和格式检查。
- `cargo +1.98.1 build --offline --locked --release`。

最终服务日志为 `fix-service-final.log`，其余 Rust 测试见 `fix-regressions.log` 和 `fix-lifecycle-lib.log`；首轮失败亦保留，不以最后成功覆盖原失败记录。

## 保留边界

5/10 秒是停止确认/readiness 的工作预算；命令清理回收与失败恢复另计，同步文件检查也不是可抢占的硬实时操作。原生管理器停止回执丢失后，选择保留证据并要求人工确认，不提供后台 job 撤销或自动认领机制。SIGKILL/断电恢复仍遵循既有人工流程。

本轮未改变 `src/observability.rs` 的原子操作 API。Rust 1.99 的既有 `fetch_update` 弃用警告与安装失败无关；本轮验证工具链为项目固定的 Rust 1.98.1，未宣称已验证声明的最低 Rust 1.91 或全部新工具链组合。
