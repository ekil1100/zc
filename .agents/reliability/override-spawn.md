# override 可执行副本的启动竞争

## 后续：macOS 注入夹具的并行首次加载干扰

在 `6b6e567` 后，本机 macOS arm64、Rust 1.98.1 重跑 `override_spawn`，复现了无故障对照组和一次/两次 busy 后真实执行超时，以及共享预算用例缺少脚本运行标记。单独无故障对照组连续 6 次通过，默认并行套件继续失败；普通 `override_script` 的 24 项全部通过。

诊断日志显示失败调用的 `posix_spawn` 在 1 ms 内成功返回，采样中的脚本子进程停在 `_dyld_start`，尚未进入脚本。原夹具每个用例独立编译一个注入动态库；仅将这些库替换为同一份库，默认并行套件连续 4 次通过；恢复独立库后连续 2 次失败（各 6 passed / 2 failed）。这些证据定位到测试夹具的并行加载干扰，未进一步确认 macOS 内部等待的具体机制，也不用于解释历史 Linux ETXTBSY。

修复仅调整 `tests/override_spawn.rs`：并行用例通过弱引用缓存共享已编译库，每个用例保持自己的隔离进程、环境、故障计数、预期字节、日志和脚本目录。锁只覆盖库的创建/取得，脚本测试仍并行；每个用例持有目录强引用直到 helper 退出，最后一个使用者退出后清理，避免静态强引用遗留临时目录。无需新依赖或生产测试开关，产品执行逻辑、期限与断言均保持原样。

验收：

- 默认并行 `cargo test --offline --locked --test override_spawn` 连续 10 次通过，每次 8 项；每次测试进程重新构建自己的共享夹具。
- `cargo test --offline --locked --test override_spawn --test override_script`：32 项通过；额外串行调度 `--test-threads=1`：8 项通过。
- 负对照临时将产品执行阶段改成重新计算完整期限，共享预算测试明确失败（本应超时却成功）；恢复原 absolute deadline 后上述组合回归通过。诊断改动已全部移除，`src/override_script.rs` 与 native interposer 均无最终改动。
- `cargo fmt --all -- --check`、`cargo clippy --offline --locked --test override_spawn -- -D warnings` 和 `git diff --check` 通过。

原始工件位于 `target/validation/`：`override-spawn-suite-before.log`、`override-spawn-probe.log`、`override-child-*.sample`、`override-spawn-shared-*.log`、`override-spawn-per-case-*.log`、`override-spawn-fixed-{1..10}.log`、`override-spawn-budget-negative.log`、`override-spawn-final-regression.log`、`override-spawn-serial.log`。本次只证明本机相关回归恢复；Linux、其他架构与完整默认测试未重跑。

## 直接证据

[CI 35174135462](https://github.com/ekil1100/zc/actions/runs/35174135462) 在 Linux x64、arm64 的 `concurrent_executable_captures_preserve_bytes_and_results` 均记录真实 `Text file busy (os error 26)`。场景为八个并发调用各执行 64 次同样的冻结脚本，不更改超时、不串行化、不忽略失败；macOS 同一用例通过。

`TemporaryScript` 已关闭自己的写入句柄，但并发 fork 的子进程可能在 exec 关闭 CLOEXEC 描述符前仍持有副本；Linux 的 ETXTBSY 明确表示执行对象仍被写打开。本轮没有采集具体持有者的 PID/FD，不能把历史只有笼统 spawn 错误的日志逐条追认为同一原因。

## 修复边界

- 仅冻结的非 Lua 可执行副本收到 `ExecutableFileBusy` 时重试；仍是同一路径、同一内容和 command，不切解释器、不重读原脚本。
- 每次等待 5 ms 或剩余预算中较短者；每次尝试前检查同一个 absolute deadline。等待可取消，不创建脱离调用方的重试任务。
- 成功 spawn 后的进程与输出读取继续使用同一 deadline；不会因重试重新获得完整执行时长。持续 busy 返回 `OVERRIDE_SCRIPT_TIMEOUT`。
- EACCES、NotFound 和其他 spawn 错误不重试；Lua worker 不走该 busy 重试。既有进程组取消/回收与 stdout/stderr 上界保留。

## 回归证据

`tests/override_spawn.rs` 从公开 `execute_bytes` 边界运行真实子进程。测试专用 native interposer 只作用于隔离 TMPDIR 内的执行对象，注入 POSIX spawn 返回码并核对每次候选字节；必须留下 marker，漏钩不能通过。注入用于验证策略，**不是上述 Linux 根因证据**。生产无该 shim、无 unsafe Rust、新依赖或测试开关。

覆盖一次/两次 busy 后真实执行、持续 busy、等待取消、权限单次失败、临时文件清理及没有迟到启动。真实子进程通过安全引用的参数路径留下 marker；清理只用持有的 `Child`，不按 marker 中的数值 PID 发信号。

共享预算用例实际注入 400 ms busy，再执行包含 750 ms sleep 的子进程，总预算仍为 1000 ms。将执行阶段故意改回相对 timeout 的负对照会错误成功，回归确实 RED；恢复共享 deadline 后 GREEN。最初按 80 次等待估算时长的 fixture 因 timer 调度吞掉启动预算，已改为单调时钟窗口，未扩大产品 timeout。

本机通过：`cargo test --locked --test override_spawn --test override_script`（8 + 24 tests）及严格 Clippy。负对照 `/tmp/zc-override-shared-budget-red.log`，修复回归 `/tmp/zc-override-final-regressions.log`。

修复提交 `10d2bab` 的 [CI 35176614058](https://github.com/ekil1100/zc/actions/runs/35176614058) 四平台全部通过，含原始 Linux 并发场景、公开边界 fault injection 和实际 Release 产物的 core/TCP/隔离安装回归；没有重跑失败 job 或放宽测试。原失败与本轮成功分别绑定自己的提交，不能用本机注入代替原生证据。
