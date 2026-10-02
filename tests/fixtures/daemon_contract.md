# daemon 修复验证与交接

## 范围与来源

复核共 3 / 50 轮：独立报告复现、修复后时序复核、最终集成复核；当前因范围外配置/schema 阻塞停止。七项独立发现均先运行原审计脚本复现，再补 Rust 回归并修改实现。原脚本和证据位于用户指定的 `zc-identity-review-m3_9rqci` 临时目录；没有改动这些脚本或 `scripts/e2e/run-core.sh`。

原协议依据：

- `src/daemon.zig`：空的独占锁、定向 PID 命令验证、nonce stop 文件、撤销及结果确认、准备文件 HMAC。
- `src/runtime_descriptor.zig`：schema 2 descriptor。
- `src/main.zig`：准备前捕获身份、替换 CAS、prepared 文件启动和回滚。
- `src/override.zig`：原运行态 YAML 序列化。
- `src/controller_auth.zig`、`src/api/server.zig`：ASCII scheme 比较、精确 secret、严格 CRLF 边界。

`daemon_zig_prepared.yaml`、`daemon_zig_key.bin`、`daemon_zig_descriptor.json` 来自原 `zig-out/bin/zc` 在全新临时 HOME/XDG 的一次实际启动，保留原始序列化字节。密钥仅用于测试，不是用户凭据。测试只替换 descriptor 的 PID、实例 nonce 和临时 prepared 路径；文件 nonce 与实例 nonce 独立。

## 实现

- 新接口 `capture_restart().await -> RestartCapture`、`restart_checked(capture, prepared).await`。删除没有前置捕获参数的 `restart`，没有兼容回退。
- CLI restart/reload 在 override/provider 准备前捕获。config update 在下载前、config override 在执行脚本前捕获，并传给 `apply_revision`。持有 launch lock 后复核；竞争时返回 `RESTART_CONTENDED`，不停止替代实例。
- 未显式换 source/override 的 restart 使用已认证冻结配置；reload 则重新准备 tracked source，准备失败时保留原实例。后者由父任务根据原 core E2E 和 `main.zig::replaceRunningDaemonWithPrepared` 补回归修正。
- 新 Rust daemon 写空锁。观察组合验证 PID、活进程命令、锁持有和 inode、descriptor PID/nonce，重复观察排除发布竞争；私有控制仍使用原 nonce 文件/managed PUT 元数据，没有杜撰 HTTP identity endpoint。
- 原 `.yaml` prepared 文件原生验证 HMAC、文件名、元数据、identity、endpoint；回滚捕获已应用选择。只有运行态序列化中已识别的默认字段被归一化，不放宽公共配置 schema。
- ready 前由创建者 guard 独占 child 所有权；失败或 future 取消同步 kill/reap 自己的 child，并清理自己的 prepared/restore 文件。ready 后解除该清理责任。
- stop 请求有作用域所有权，失败/取消撤销；已消费则有界确认退出。普通 stop 不向 descriptor PID 发信号。
- 后台内部入口验证 handoff 后通过安全 `rustix::process::setsid()` 脱离 session；foreground 不变。
- HTTP 必须完整消费所找到的 header 边界，并拒绝裸 CR/LF；Bearer scheme ASCII 大小写不敏感，secret 保持精确常量时间比较。
- 额外捕获并修复原子 descriptor 发布期间的已 unlink inode 读取竞争：仅在当前路径通过原安全检查时有界重开；永久 hard link 仍拒绝。

## 验证入口

```sh
cargo test --test api --test daemon --test daemon_races
cargo test --lib daemon::lifecycle_tests
python3 tests/fixtures/daemon_external.py target/debug/zc zig-out/bin/zc
```

最后一条是独立进程复现和可选原 Zig 在线迁移验证，不属于默认 Cargo 测试依赖。省略第二个二进制参数只跑 Rust 外部场景。所有端口动态分配并排除 7899，HOME/XDG 均为临时目录；没有安装或 Git 写操作。

已通过：HTTP 六项、原 daemon 十四项、取消/原子发布三项、七项独立外部复现修复验证；真实 Zig daemon 的 status、幂等 start、安全 stop、managed PUT、失败回滚至 Rust。原先“删除 source 后 reload 成功”的自建断言不符合旧版契约；已改为 reload 拒绝且实例不变、无参数 restart 使用冻结输入。会话测试对仍存活的专用 launcher 进程组实际发送 SIGHUP。

## 交接限制

- 本次只验证 macOS，Linux 的 `/proc/<pid>/cmdline` 路径尚未执行。
- 旧快照中的非默认 IPv6/idle/select 检查参数，以及 Rust 尚未支持的协议配置，仍 fail closed；没有通过删除未知字段来假装完整兼容。无 controller 的旧 managed 实例只有 durable identity/generation 与 descriptor 相符时才能冻结选择，否则拒绝替换。
- 共享树的 `config`/`override_script` 改动发生在验证期间。新增 config override 准备竞争测试最初红→绿；随后被 canonical effective YAML 与当前 `Config` schema 不一致阻塞，返回 `CONFIG_OVERRIDE_APPLY_FAILED`。未降低断言或修改这些模块。
- 扩展检查发现 `tests/cli.rs` 四项失败（旧版本字符串、显式 CLI 端口仍被源配置预检挡住）；`tests/cli_managed.rs` 十三项失败（配置/schema、provider、错误码等）。这些不在本任务修改范围内，不能宣称全仓通过。
- Clippy 最近一次被 `src/override_script.rs` 的 `collapsible_if` 阻塞；没有添加 lint 抑制。
- 父任务需把本说明中用户可感知的生命周期、默认后台行为及迁移边界同步到其拥有的 `docs/` 文档，并在共享改动完成后进行最终集成验证。
