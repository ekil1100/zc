# 平台阻塞项的独立诊断

这些入口用于缩小故障范围，**不替代原生门禁，不以重跑成功关闭历史失败**。正式 CI 的超时、断言和证书策略不变，生产 Rust 没有增加诊断钩子。

## 系统信任写入：去掉 Rust 的对照

`scripts/ci/diagnose-macos-trust.py` 仅允许显式确认的一次性、独占 macOS 15+ GitHub runner。不要在开发机伪造环境开关；假 HOME 不隔离系统信任。

- 默认模式：不构建、不启动 Rust；生成唯一证书和独立 keychain，原样调用 User `add-trusted-cert`。
- `--keychain-only`：在另一台全新 runner 上，只把同类证书写入独立 keychain，不写 TrustSettings。
- 保持原 30 秒预算、写前登记清理、primary 与全部 cleanup 错误；item-not-found 不当成功。
- 写入期间并发收集 trustd/authd/securityd 的限定日志，最多输出 16 KiB。结束后另用独立 3 秒 watchdog 只读查询 authd/SecurityAgent 最近一分钟的持久日志，补齐 stream 启动前的事件；先脱敏再截断，不延长 setter 的 30 秒预算。空日志不证明不存在授权或 IPC 等待。
- 不修改 authdb、SIP、账户或密码，不把 User setter 改成 sudo，不上传私有 keychain/证书私钥；失败后销毁 runner。

有区分力的预测：无 Rust 仍失败可排除 Rust 前置验证是必要条件；keychain-only 成功而 TrustSettings 失败，将范围缩到后者；相关服务日志才可进一步区分授权、锁或其他 IPC 等待。上述模式通过也不代表九项 TLS/DNS 场景通过。

[诊断 CI 35247844404 / `d22abd6`](https://github.com/ekil1100/zc/actions/runs/35247844404) 已确认：无 Rust 的 User setter 仍在相同 XPC 路径超时，独立 keychain-only 对照通过。stream 首个事件比 setter 启动晚约 0.2 秒；仅捕获 authd 的 `builtin:authenticate`，缺少关联 right/请求来源，**还不能把它直接认定为本次 GUI 根因**。新增持久日志查询用于补足这一证据缺口，不是修复或授权绕过。

[后续诊断 35248899957 / `d501556`](https://github.com/ekil1100/zc/actions/runs/35248899957) 已关联同一 token 60、setter PID 2007 与 `com.apple.trust-settings.user`：客户端 engine 67 的 `0x13` 含 PreAuthorize；服务端 trustd engine 68 的 `0x3` 实际执行 `hardcoded-authenticate-session-owner`，并启动 SecurityAgent/`builtin:authenticate`。因此可排除“Rust 是夹具失败的必要原因”，并确认存在尚需满足的系统身份认证要求。**预授权成功不是最终认证完成**；日志前缀被 UI 启动噪声截断，不能宣称已看见某个弹窗或证明全部后续等待原因。持久查询进一步限定到 Authorization subsystem，避免这些无关噪声。下一阶段需要能正常完成合法认证的专用一次性环境，不以 authdb/SIP/账户改动或跳过用例替代。

## Intel UDP：最小真实链路

`scripts/e2e/diagnose-ss-udp.py` 使用真实 CLI、SOCKS5 TCP control/UDP socket、独立 shadowsocks-rust 1.24.0 与 loopback echo，不用生产内部 mock。

```bash
cargo build --locked --bin zc --example e2e_ss_udp_oracle
bash scripts/e2e/fetch-static-fixtures.sh target/e2e-fixtures
python3 scripts/e2e/test-diagnose-ss-udp.py
python3 scripts/e2e/diagnose-ss-udp.py \
  --cipher aes-128-gcm --iterations 30 \
  --kinds roundtrip roundtrip-domain roundtrip-ipv6 \
  --artifacts "$PWD/target/diagnose-ss-udp/new-run"
```

每轮私有 HOME/XDG，配置写后冻结，使用临时非 7899 端口；端口冲突失败，不自动换端口。保留原 probe 5 秒总预算和无重试策略。任何一轮失败，即使后续成功，总退出码仍非零；保存所有命令输出、配置 hash、二进制 hash、结果与子进程回收记录，不覆盖旧目录。

helper 错误现在带 probe kind、当前阶段、收发包数和耗时；`ZC_E2E_UDP_DIAGNOSTIC=1` 额外打印阶段/echo 收发信息，但不打印 payload。这些 `[DEBUG-udp-*]` 标记只属于测试 helper/诊断脚本。原 core 流程同样启用它们，保留完整 suite 的历史与后台启动模式。

本机 arm64 已测 73 轮、219 次实际探测，0 次自然复现；这**不能关闭 Intel 故障**。收到包后的校验失败、等待 UDP 返回、等待 TCP 控制连接关闭由不同阶段区分。若最小 Intel 链路也通过，仍需保留原 core 失败，不能假定省略的历史不重要。原始报告：`target/diagnose-ss-udp/REPORT.md`。

`35247844404` 的原生 Intel 最小链路也完成三种 cipher 各 30 轮、合计 270 次 probe，全部成功；全部配置未变，原始样本下载于 `target/ci/35247844404/udp-samples/`。仍不关闭原故障：独立诊断增加原样 core 的 trace=0/1 对照，保留完整 suite 历史与后台模式，并观察逐阶段日志是否影响复现；两次结果均保留，任一次失败总状态仍失败，不尝试“跑到绿”。

## CI 与安全回归

`.github/workflows/platform-diagnostics.yml` 与正式验收分离：两台新 macOS runner 做 trust/keychain 对照，Intel runner 对三种 cipher 各做 30 轮，随后执行两次不同 trace 设置的原样 core，保存全部样本且失败仍非零。工作流名称明确 `not acceptance`。只上传隔离的 UDP 测试工件，不上传 trust 私有夹具。

开发机可安全运行：

```bash
python3 scripts/ci/test-macos-trust-diagnostic.py
just delivery-test
```

20 项 trust 诊断合约只使用无害子进程和外部进程边界替身；6 项 UDP 回归使用真实 socket，包括黑洞、畸形响应、第一轮失败后第二轮成功仍报错、SIGTERM 回收。它们验证诊断工具能报红，不证明平台根因已修复。
