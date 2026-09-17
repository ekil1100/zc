# macOS 原生首次使用门禁

生产产物要求 macOS 15+，强延迟加载 Security、SystemConfiguration、CoreFoundation；本页讨论真实系统 API 的验收，不是只读 Mach-O 结构检查。最低版本、签名与冷启动检查见[研究记录](../research/macos-framework-startup.md)。

## 隔离与边界

`scripts/ci/test-macos-native.py` 只在明确确认的一次性 macOS CI runner 上执行，要求 `GITHUB_ACTIONS=true`、`RUNNER_OS=macOS`、`--ephemeral-runner` 和原生 target。环境变量不是隔离证明，调用方仍须保证机器可销毁、无生产凭据和并行 trust writer。**不要在开发机伪造这些开关；假 HOME 不隔离系统信任。**

- 生成唯一的短期自签名证书、私钥与独立 keychain；仅修改该证书的 User/Admin TrustSettings 和临时 search-list 项。
- 不修改 System-domain trust、DNS、authdb/SIP，不使用自定义 roots、`skip-cert-verify` 或 Zig 来替代原生语义。
- 原搜索列表先快照，任何修改尝试都登记清理；逐项撤销 trust、恢复列表、删除 owned keychain 并验证列表。
- 清理失败仍失败，保留私有夹具并要求销毁 runner；不能把英文 item-not-found 当成成功，也不上传整个夹具目录（含私钥）。

`tests/macos_native.rs` 通过真实 verified Trojan socket 与 `Dns::system()` 覆盖九个场景：未信任拒绝、Security-first、DNS-first、错误 SNI、独立/共享 DNS 并发、User deny、Admin trust 正对照、User deny 优先于 Admin trust。按名称选择 Trojan，不依赖包含内建 DIRECT 的数组下标。每个场景必须执行且有唯一 BEGIN/PASS marker，忽略/过滤全部用例不能通过。

这不声称覆盖 System-domain 优先级、TrustAsRoot 全矩阵、外部 DNS、24/72h 长稳或性能。

## 当前阻塞与诊断

[CI 35234530286](https://github.com/ekil1100/zc/actions/runs/35234530286) 的 Linux 两架构通过；macOS 的原生信任门禁失败。macOS 15 arm64 日志已确认 baseline-untrusted 通过，随后 User trust 写入阶段约 30 秒后出现清理 item-not-found。旧 harness 只打印最终 cleanup 错误，遮住了 primary，**这些日志还不能证明一定在等待 GUI**。

当前 runner 保留 primary 和全部 cleanup 错误，按阶段打印 BEGIN/END/FAIL 与 owned PID，不打印密码参数。只有 trust setter 到原 30 秒预算的一半仍未完成时，才对仍持有的命令进程做一次 1 秒只读栈采样（Admin 时持有的是 sudo wrapper）；采样最多占用剩余预算中的 3 秒，随后仅等待原 deadline 的剩余时间。采样失败不替代原错误，栈输出上限 16 KiB；不放宽 timeout，不重试操作。

[诊断 CI 35240315075 / `5ab079b`](https://github.com/ekil1100/zc/actions/runs/35240315075) 已取得直接栈证据：两个 arm64 系统的独立 `/usr/bin/security` 命令停在 `SecTrustSettingsSetTrustSettings → TrustSettings::flushToDisk → SecTrustSettingsXPCWrite → securityd_send_sync_and_do → xpc_connection_send_message_with_reply_sync → mach_msg2_trap`。原错误完整保留为 User `add-trusted-cert` 的 30 秒 watchdog；清理 item-not-found 仍明确失败，search list 恢复与 owned keychain 删除则成功。**已定位到系统信任写入的同步 IPC，尚未确定服务端是授权、锁还是其他等待；没有据此声称 GUI 根因或延迟加载回归。** 还需要服务端证据，不能直接改 authdb、重试或增大超时。

同轮 Linux 两架构及 24 项 runner 合约测试通过。Intel 在更早的 core E2E、进入 shadowsocks-rust UDP 三 cipher 对照阶段后出现 `deadline has elapsed`，未到达 native 阶段；前一轮 Intel 通过不覆盖这次失败，尚未定位，也未为此调整生产行为或测试预算。全部结果/日志位于 `target/ci/35240315075/`。

不能凭旧经验用 `authorizationdb ... allow` 绕过：Apple [authd `_find_rule`](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/authd/engine.m#L1235-L1246) 在数据库查询前为 User/Admin TrustSettings 选择硬编码规则；[规则实现](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/authd/rule.c#L183-L275) 保留 session-owner/admin 授权。数据库读写成功不证明有效授权改变。源码调查不是运行中系统的 trace，仍需原生采样定位。只读证据详见 `target/ci/35234530286/user-trust-authorization.md`。

若最终确认需要交互认证，应准备经合法授权的专用一次性 GUI/VM 环境；不能跳过 User trust 场景、修改系统授权策略或削弱证书验证来换取 green。

## 可在开发机安全运行的检查

```bash
python3 scripts/ci/test-macos-native-runner.py
just delivery-test
```

runner 合约测试只使用临时目录、无害子进程和外部进程边界替身，不调用实际 security/sample 或更改系统设置。覆盖原错误与多项清理错误并存、部分写入后的清理、密码脱敏、owned child 回收、采样与原 deadline 共享预算、启动拒绝。它们只验证 harness，不是九项原生门禁通过的证据。
