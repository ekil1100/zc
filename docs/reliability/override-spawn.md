# override 可执行副本的启动竞争

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

本机通过：`cargo test --locked --test override_spawn --test override_script`（8 + 24 tests）及严格 Clippy。负对照 `/tmp/zc-override-shared-budget-red.log`，修复回归 `/tmp/zc-override-final-regressions.log`。Linux 原生并发场景与四平台整体通过仍需后续 CI，不能用本机 fault injection 代替。
