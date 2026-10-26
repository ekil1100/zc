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

## 当前发布要求

用户已批准移除本文件九项原生系统信任/首次使用场景的必过发布要求。默认 CI 不再执行 `scripts/ci/test-macos-native.py`；保留该脚本及隔离合约测试，供有正常系统认证条件的一次性环境手动验证。四平台构建、普通 TLS 回归及其他检查不变。下文“阻塞”“仍待通过”等描述保留历史诊断语境；当前测试未通过的事实不变，但不再阻塞发布，也不代表产品证书校验被关闭。

## 历史阻塞与诊断

### 凭据与 token 传递探索：原生修复未完成

探索性探针与 15 项隔离回归保留在 `target/macos-trust-fix/credential-probe/`，未加入正式测试入口。它们逐项检查真实 User right 的凭据授权、同 token、外部化导入及 setter 式新 token 的无凭据求权。探针仅使用 public Authorization/AuthSession API，无 UI flag、无 trust/keychain/account 写入；密码走 FD，所有 OSStatus 与清理状态均保留，native/parent watchdog 分别为 25/30 秒。

源码进一步确认：`SecTrustSettingsSetTrustSettingsExternal` 属于 private header 中的内存数据操作；public import 仍走另建 token 的 `flushToDisk`。`canAddTrustSettingsAsRoot` 只考虑 root、Admin、非空设置及指定 SIP 状态，User 明确排除。创建新账户或 audit session 本身也没有提供 setter 的凭据入口。**尚未找到受支持的非交互写入修复，九项原生门禁保持原要求。**

[源码依据与证据边界](macos-trust-auth.md)。当前缺少可完成正常认证的可销毁环境及原生执行证据；探针成功仅证明 token 对照，不替代真实 User deny 优先级与清理验收。下节保留此前 CI 复核的原始记录。

### CI 38707401434 复核：授权阻塞仍未修复

本轮基线为 `25c2658`，只补充 macOS runner 合约测试与本记录。生产 Rust、原生 runner、诊断脚本、工作流和发布门禁均保持原样。**本机 stub 回归通过不代表信任写入修复；九项原生验收仍待通过。**

本轮直接检查的原始日志是 `target/release-v1.1.0-rc2/macos-arm64.log`（SHA-256：`de345108836203d2af08d2317fb44158553a24e06f20994a2d7a6f5060659d2a`）。同一 CI 的另一 arm64 job 也在原生首次使用步骤失败；以下精确时序只对应这份本地日志：

| 证据 | 结果 |
| --- | --- |
| 第 4918–4923 行：创建、解锁、追加 owned keychain | 全部成功 |
| 第 4924–4926 行：独立 native baseline-untrusted | 0.455 秒成功 |
| 第 4927–4962 行：User setter PID 39886，中点采样 | 538 个样本停在 `SecTrustSettingsSetTrustSettings → TrustSettings::flushToDisk → SecTrustSettingsXPCWrite → securityd_send_sync_and_do → xpc_connection_send_message_with_reply_sync → mach_msg2_trap` |
| 第 4963 行：primary | 30.027 秒后报原 30 秒 watchdog |
| 第 4964–4974 行：cleanup | remove-trusted-cert 报 item-not-found；搜索列表恢复、owned keychain 删除、列表复核成功；总结果仍失败 |

对照与可证伪预测：

| 假设 | 预测 | 已有证据与结论 |
| --- | --- | --- |
| 系统会话所有者认证未完成 | 无 Rust 仍失败；关联 right/token 会进入认证机制 | `35250040916` 的 token 134：客户端 engine 144 为 `0x13` PreAuthorize，服务端 engine 145 为 `0x3`；后者进入 session-owner 认证，SecurityAgent 记录 `builtin:authenticate` 和 `SC confirmation dialog detected`。支持夹具授权阻塞。 |
| 钥匙串锁或搜索列表错误 | keychain-only 对照失败，或 setter 停在钥匙串插入 | 本次解锁成功，栈位于 TrustSettings 写入；`35247844404/keychain-only.log` 第 177 行插入仅用 0.123 秒且清理成功。普通钥匙串写入不是已复现的阻塞点。 |
| Rust 首次加载是必要原因 | 去掉 Rust 后成功 | 历史独立诊断完全未启动 Rust，仍复现相同写入等待；该必要性假设被否定。 |
| 只需更长超时 | 有完成授权或继续推进的证据 | 当前样本没有该证据；历史诊断反而显示认证等待。保持 30 秒预算。 |

随后取得的 Intel job `116330108731` 日志（`target/release-v1.1.0-rc2/macos-intel.log`）也显示 User setter 在 30.003 秒后超时，清理返回 item-not-found；该平台同样未通过门禁。

当前日志只含客户端栈，无法单独证明这一次请求的全部服务端等待原因。历史关联日志提供同类故障的授权证据，不冒充本次 authd trace。item-not-found 是清理阶段的返回结果，既不能代替 primary，也不足以证明没有任何延迟提交或跨进程残留；继续保留严格清理失败与销毁 runner 要求。

#### 已排查的替代路径

Apple Security 源码固定到 `db15acbe6a7f257a859ad9a3bb86097bfe0679d9`：

- [rule.c:183–275](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/authd/rule.c#L183-L275)：User/Admin TrustSettings 使用硬编码授权规则；写 authdb 的 allow 不是有效修复。
- [engine.m:936–1035](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/authd/engine.m#L936-L1035)：零有效期规则的 PreAuthorize 可直接成功，实际认证仍在后续发生。历史日志明确记录 `credential 501 expired '429.947008 > 0'`；单独预热 `security authorize` 不构成 setter 已授权的证明。
- [TrustSettings.cpp:643–717](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_keychain/lib/TrustSettings.cpp#L643-L717)：setter 创建自己的 AuthorizationRef，随后外部化给服务端；公开 setter 没有接收调用方 auth ref 的参数。另写凭据 helper 仍需验证这条完整链路，不能仅靠 stub 宣布有效。
- sudo 普通 User setter 会改变被测身份；Admin-only 无法替代 User deny 优先级。直接编辑信任数据库、修改账户、authdb 或 SIP 均未采用。

源码是机制参考，不是当前 macOS 二进制的运行时证明。本轮只下载源码到 `target/macos-trust-fix/` 阅读，未运行系统 trust/keychain 命令。

#### 本轮验证与尚缺证据

- `python3 scripts/ci/test-macos-native-runner.py`：26 项通过。新增完整场景回归约束：超时后只执行过 baseline、setter 无重试、primary 与 cleanup 均保留；成功路径仍须执行九项，User/Admin 修改身份与顺序严格不变。
- `python3 scripts/ci/test-macos-trust-diagnostic.py`：20 项通过。
- 新增两项测试均经内存变异确认可报红：将首个 User trust 改为 Admin，以及抹掉 primary，各产生一项断言失败。变异不写回 runner 文件；所有外部进程边界仍为 stub。这证明覆盖约束有效，未模拟或证明真实系统认证成功。
- 定向 Ruff 格式、lint 与 `git diff --check` 通过。未运行本机原生信任场景、服务或生产端口；未 commit、push、tag。

**完整修复尚缺：可完成正常 session-owner/Admin 认证的一次性独占 macOS 环境，及该环境中的原生成功证据。** 需要验证新增、deny 更新和撤销均在原预算内完成，九个独立 first-use 子进程全部通过，User/Admin trust、搜索列表与 owned keychain 清理成功。若使用凭据自动化，须先证明凭据进入 setter 对应的最终服务端授权，而非仅另一个 token 的预授权成功，并覆盖失败后的清理。当前资料无法给出已验证的 stock CLI 无交互替换；本轮保留阻塞，没有提交推测性的授权修复。

### 历史诊断

[CI 35234530286](https://github.com/ekil1100/zc/actions/runs/35234530286) 的 Linux 两架构通过；macOS 的原生信任门禁失败。macOS 15 arm64 日志已确认 baseline-untrusted 通过，随后 User trust 写入阶段约 30 秒后出现清理 item-not-found。旧 harness 只打印最终 cleanup 错误，遮住了 primary，**这些日志还不能证明一定在等待 GUI**。

当前 runner 保留 primary 和全部 cleanup 错误，按阶段打印 BEGIN/END/FAIL 与 owned PID，不打印密码参数。只有 trust setter 到原 30 秒预算的一半仍未完成时，才对仍持有的命令进程做一次 1 秒只读栈采样（Admin 时持有的是 sudo wrapper）；采样最多占用剩余预算中的 3 秒，随后仅等待原 deadline 的剩余时间。采样失败不替代原错误，栈输出上限 16 KiB；不放宽 timeout，不重试操作。

[诊断 CI 35240315075 / `5ab079b`](https://github.com/ekil1100/zc/actions/runs/35240315075) 已取得直接栈证据：两个 arm64 系统的独立 `/usr/bin/security` 命令停在 `SecTrustSettingsSetTrustSettings → TrustSettings::flushToDisk → SecTrustSettingsXPCWrite → securityd_send_sync_and_do → xpc_connection_send_message_with_reply_sync → mach_msg2_trap`。原错误完整保留为 User `add-trusted-cert` 的 30 秒 watchdog；清理 item-not-found 仍明确失败，search list 恢复与 owned keychain 删除则成功。**已定位到系统信任写入的同步 IPC，尚未确定服务端是授权、锁还是其他等待；没有据此声称 GUI 根因或延迟加载回归。** 该轮还缺服务端证据，不能直接改 authdb、重试或增大超时。

后续[独立诊断](platform-diagnostics.md)已补齐关键关联：完全不启动 Rust 的 User setter 仍超时，而 keychain-only 成功；`35250040916` 中同一 token 的服务端 engine 145 进入 `hardcoded-authenticate-session-owner`，SecurityAgent 记录 `builtin:authenticate` 和 `SC confirmation dialog detected`。因此必须先解决隔离测试环境的正常身份认证，不能把这个 setup 失败归为必须由 Rust 引起。客户端 PreAuthorize 的成功不代表服务端最终授权完成。没有修改授权策略，完整九项仍未通过。

同轮 Linux 两架构及 24 项 runner 合约测试通过。Intel 在更早的 core E2E、进入 shadowsocks-rust UDP 三 cipher 对照阶段后出现 `deadline has elapsed`，未到达 native 阶段；前一轮 Intel 通过不覆盖这次失败，尚未定位，也未为此调整生产行为或测试预算。全部结果/日志位于 `target/ci/35240315075/`。

不能凭旧经验用 `authorizationdb ... allow` 绕过：Apple [authd `_find_rule`](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/authd/engine.m#L1235-L1246) 在数据库查询前为 User/Admin TrustSettings 选择硬编码规则；[规则实现](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/authd/rule.c#L183-L275) 保留 session-owner/admin 授权。数据库读写成功不证明有效授权改变。源码调查不是运行中系统的 trace，仍需原生采样定位。只读证据详见 `target/ci/35234530286/user-trust-authorization.md`。

若最终确认需要交互认证，应准备经合法授权的专用一次性 GUI/VM 环境；不能跳过 User trust 场景、修改系统授权策略或削弱证书验证来换取 green。

## 可在开发机安全运行的检查

```bash
python3 scripts/ci/test-macos-native-runner.py
just delivery-test
```

runner 合约测试只使用临时目录、无害子进程和外部进程边界替身，不调用实际 security/sample 或更改系统设置。覆盖原错误与多项清理错误并存、部分写入后的清理、密码脱敏、owned child 回收、采样与原 deadline 共享预算、启动拒绝。它们只验证 harness，不是九项原生门禁通过的证据。
