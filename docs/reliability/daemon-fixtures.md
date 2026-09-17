# daemon fixture 的竞态隔离

本说明覆盖 `tests/{cli,cli_managed,daemon,daemon_races}.rs` 的公开 CLI 子进程、真实 loopback socket 与隔离 HOME/runtime 文件操作；不是完整 Rust 迁移验收或性能结论。fixture 修复未修改生产 `src/daemon.rs`、`src/fsutil.rs`。

## socket 创建不能与其他 fixture 的 spawn 重叠

macOS 上 Rust std 创建 socket 后另行设置 CLOEXEC。其他线程在两次系统调用之间 spawn，会继承该 socket；父线程随后 bind/listen、关闭探测 listener，并不关闭子进程中的副本。换端口范围或保证端口数字不重复不能解决 FD 继承。

本机实证（Rust 1.98.1 / macOS arm64）：

- `/tmp/zc-daemon-race-diagnosis/owner-37.log`：controller 冲突用例的 mixed `12867` 被 PID `22869`、FD `4` 持有。该 PID 的同轮 spawn 记录是另一临时 HOME 的 `zc config load`，不是另一个有意绑定该端口的 daemon；启动返回真实的 `START_PORT_IN_USE`。
- 最小化到并发 std listener 探测与一个隔离的 `zc log -f --json` 子进程后，`socket-spawn-cli-parallel-red.log` 的第 2 次尝试抓到 PID `34880`、FD `14` 持有探测端口 `50042`。仅结束这个持有 `Child` handle 的测试子进程后，同一端口立即可重新绑定；未对未知 PID 发信号。
- 只将 socket 创建与 spawn 互斥的对照探针，100 次未再出现继承。`/tmp` 中保留两份独立探针及原始日志；单独重跑通过不是根因证据，PID/FD 与释放后重新绑定才是。

fixture 契约：

1. `Fixture` 在创建之前取得进程内 mutex，直到其 stop 和临时目录销毁完成才释放。独立用例不得同时在同一测试进程内创建 socket 和 spawn。
2. 一个用例内部需要验证的并发仍显式保留，例如两个后台 start 竞争同一实例；没有把该用例改成顺序 start。
3. 移除实验性的 PID-seeded `10000..29999` 分配器，恢复 OS 分配的非生产临时端口。bind-then-close 是测试探测，不是端口租约；外部占用仍必须使测试失败，不能重试 CLI 或自动换端口来掩盖它。
4. controller/mixed 占用分别严格断言 `START_CONTROLLER_PORT_IN_USE` / `START_PORT_IN_USE`，不得发布 ready。controller 用例还验证只有 fixture 释放占用后，显式启动才能在原请求端口成功。

后续总门禁在 `cli_managed` 的 provider 完整冻结测试中捕获同类干扰：provider body 尚未发送，探测端口却可连接。`tests/support/cli_fixture.rs` 因而统一上述四个 CLI/process suite 的独立 fixture 生命周期隔离；普通配置解析和协议测试仍可并行，单用例内部的并发 start、CAS、订阅更新竞争等场景保持原样。`cargo test --locked --all-targets` 在此调整后通过。

不声称其他测试程序或生产中的所有 socket/spawn 组合均已验收。lsof 仅用于本次诊断，不成为测试或生产依赖。

## listener 关闭不是清理完成的屏障

替换 `zc.lock` 后，旧实例先关闭 listener，再在 `zc.daemon.lock` 保护下清理 descriptor、PID 与 snapshot，最后释放原 lock inode。若测试只等连接被拒绝就要求 status 成功，仍可能观察到活 PID 配合替换后的锁，或在文件 capture 期间碰到 unlink。

这不是可以忽略的 status 错误：现行 CLI 安全契约要求身份不一致 fail closed；原 `src/daemon.zig::inspectRuntimeWithInspector` 也会在活实例丢失锁时返回 `RuntimeLockIntegrityLost` / `RuntimeIdentityUncertain`。

定向证据：

- 先持有实际 `zc.daemon.lock`，再替换实例锁，原来的“listener 关闭后立刻 stopped”断言稳定失败。`lock-cleanup-red.log` 保存 `STATUS_FAILED / RUNTIME_IDENTITY_CHANGED: live PID without its daemon lock`。
- 临时 capture 探针只固定读取与 cleanup 的交错，不放松任何检查。`capture-unlink-values-red.log` 记录读取 `zc.pid` 的 inode `42301143` 在 cleanup 中发生 `nlink 1→0`、ctime 改变，uid/mode 不变，复现原始 `file metadata changed during capture`。历史随机失败没有文件名，不能反推那一次一定是 PID 而非 descriptor；该受控重放证明现有清理顺序足以产生同一错误。
- 这些生产临时探针已全部移除；其 patch、重放脚本和原始输出仅保留在 `/tmp/zc-daemon-race-diagnosis/`。

回归测试固定清理窗口并要求过渡期 status **失败且不改 descriptor/PID**；释放清理锁后，只对已持有的原 lock 文件 handle 做有界 `try_lock` 等待。只有 `WouldBlock` 可以继续等待，其他错误立即失败。确认旧 owner 释放原 inode、descriptor/PID 已删除后，仍严格要求 `status` 成功且为 stopped。不轮询吞掉 status 错误，不读数值 PID 后发信号，也不修改 metadata、nonce 或冻结快照验证。

## 定向验证入口

```bash
cargo test --offline --locked --test daemon controller_collision
cargo test --offline --locked --test daemon runtime_lock_replacement
cargo test --offline --locked --test daemon
cargo clippy --offline --locked --test daemon -- -D warnings
rustfmt --edition 2024 --check tests/daemon.rs
```

本机结果：15 个 daemon 用例通过；随后直接执行同一测试二进制 **50 轮 × 15 用例** 全部通过（`final/summary.txt`，约 365 秒），Clippy 与 rustfmt 检查通过。`src/daemon.rs`、`src/fsutil.rs` 与诊断前副本逐字节一致。红绿原始输出与有界重复运行日志位于 `/tmp/zc-daemon-race-diagnosis/`。

本次不重跑无关四平台构建、300 秒 UDP idle、E2E、安装或性能门禁，也不据此宣称那些门禁重新通过。
