# Rust 迁移：候选实现与验收边界

> 本文为内部实现与分阶段验收记录，不决定任务顺序。安排下一步先读[开发优先级](../development-priorities.md)；各轮测试、性能和未安装说明仅适用于其记录的候选与场景，不代表当前部署状态。

## 状态与验收原则

当前 Cargo 包版本 `1.0.1`，不是仅提供 `start --foreground` 的实验 TCP 切片。CLI、托管配置、daemon、minimal API、simple-obfs 和受限 UDP 已接入 Rust；默认构建、测试、E2E、安装回归及发布配置均使用 Rust。**接入不等于验收完成，也不等于已发布。**

迁移沿用原有 CLI、状态权威、安全与协议行为规范，不把旧实现的缺口扩写成 mihomo 全功能，也不把 Rust 尚未对齐的行为改写成新规范。原 Zig 源码当前只作审查 oracle；最终移除由完整验收决定，默认路径不调用 Zig、不自动回退。

验收必须可验证：公开 CLI/JSON、真实进程生命周期、旧状态与 snapshot 样本、独立 TCP/TLS/UDP 服务端、原样 core E2E、四平台 release artifact、安装回滚、性能对照和实际长稳分别提供证据。局部通过不替代全套通过，历史 Zig 报告也不能证明 Rust。

## 工程与模块

Rust 最低 `1.91`（Cargo 声明），CI 固定 `1.98.1`。原生依赖需要 C/C++ 工具链与 CMake；E2E 使用 Python 3、Node.js、just。生产目标仅 Linux/macOS × x64/arm64；Windows 不支持。Zig `0.16.0` 仅为迁移期历史对照工具链。

| 模块 | 职责 |
| --- | --- |
| `src/main.rs`、`src/cli.rs` | 命令表、别名、冻结错误码、JSON/text 输出、用户操作编排 |
| `src/store.rs`、`src/fsutil.rs` | schema-2 catalog、不可变 revision、旧数据接管、CAS、owner-only 路径与原子持久化 |
| `src/service.rs` | 解析配置身份，准备 provider/override/selection，冻结启动输入 |
| `src/user_service.rs` | 用户服务注册与管理器适配、冻结调用、本地冷发布和失败恢复 |
| `src/daemon.rs` | PID/lock/nonce 身份、认证快照、readiness、stop/restart/回滚、live selection |
| `src/api.rs` | 有界 minimal HTTP API、loopback/通配监听鉴权与 managed generation 校验 |
| `src/config.rs`、`src/config_provider.rs` | 有界 YAML、规则展开、select 索引与路由 |
| `src/override_script.rs` | Lua/可执行脚本、canonical materialization、只用于运行时的兼容字段投影 |
| `src/runtime.rs`、`src/connection.rs` | mixed HTTP/SOCKS5、转发、UDP association 生命周期，以及实例内有界连接索引与管理取消 |
| `src/outbound.rs`、`src/anytls.rs`、`src/simple_obfs.rs`、`src/udp.rs` | TCP/TLS、单流 AnyTLS、classic SS、obfs HTTP、SS/Trojan UDP |
| `src/dns.rs`、`src/target.rs` | 有界异步 DNS、目标校验与路由后地址固定 |

生产只交付 `zc`。`examples/` 下的 origin、obfs、SS UDP 程序是独立测试 helper，不安装、不导入生产协议实现作为 oracle。

## 已接入的用户路径

- 完整命令树：`help/version`、`start/up`、`stop/down`、`restart/reload/status/log/test/doctor`、`config load/list/download/update/use/delete/dump/override`、`proxy/profile list/select/test`、`connection list/close <id>`、`diag doctor`。详见 [CLI 契约](../../docs/cli/spec.md)。
- 托管 profile 的 immutable source、本地 provider assets、metadata、冻结 override 与 desired selections；先提交 durable desired，再尝试 exact revision 的 live apply。
- 后台或 supervised foreground daemon；监听器绑定和 desired reconciliation 完成后才发布 ready 并开放数据面。控制面接受显式 `127.0.0.1:<port>` 和 `0.0.0.0:<port>`，占用即失败；通配监听要求非空 secret 和全路由 Bearer，本机 CLI 始终连接 loopback。
- 内置 DIRECT/REJECT、classic AEAD SS、原生 TLS Trojan / AnyTLS TCP；SS 的内建 simple-obfs HTTP；`udp:true` SS/Trojan 经 mixed SOCKS5 UDP ASSOCIATE。
- select 默认首成员、嵌套组、持久选择、循环/未知引用拒绝；first-match 规则、本地和 unmanaged HTTP rule-provider 展开。
- minimal API：`/`、`/version`、`/proxies`、`/rules`、`/status`、`PUT /proxies/<group>`、需强制鉴权的 `GET /connections` 与 `DELETE /connections/<id>`，详见 [API](../../docs/api/README.md)。

生产默认端口固定 **7899**。`mixed-port` 数值只作配置兼容（含来源中的 0），真正 bind 由 CLI `--port` 或默认值决定；独立 `port`/`socks-port` 不创建 listener。开发显式用非生产端口；冲突不漂移。配置投影不能改变 immutable bytes 或其哈希证明。

## 已有数据与实例安全

- `state-v2.json` schema 2 及 schema-1 immutable revision 采用原格式、canonical bytes 和内容摘要验证，不创建平行 Rust 状态库。文件位于 `$HOME/.config/zc`，不是从 cwd 猜测。
- `meta.json` / `configs/` 和旧 schema-1 authority 经共享 `legacy-cutover.lock`、catalog lock、最终重采样与 CAS 接管。原 bytes、assets、override proof 与 selections 验证后才切换 authority；镜像不是权威写入入口。
- 健康 state-v2 直接读取；未知格式、损坏 catalog/revision、缺失 identity、不可验证旧状态均失败。**禁止以删除目录、重建空 catalog 或默认 DIRECT 恢复。** 存储失败可能留下不可达 immutable 对象，不应盲目清理。
- 原子 rename 已可见但父目录 fsync 失败时，返回成功并标记 `durability_uncertain:true`；这不是已证明 crash-durable。该标志保留于当前 Store 生命周期，不是持久 health 位。镜像问题独立使用 `mirror_out_of_sync`。
- Rust 原生 `.snapshot` 绑定文件 HMAC 与 instance nonce。旧 Zig `.yaml` prepared snapshot 按其真实格式验证 HMAC、identity/source/port header；旧文件 nonce 本来就独立于 descriptor nonce，不能错误要求两者相等。接管不是一般 YAML 回退，也不绕过 owner/lock/PID 校验。
- 状态 token 使用格式、sequence 与内容 digest；选择绑定 exact key/revision/generation。live apply 还校验 PID、nonce、endpoint，旧实例或乱序 CAS 不能改写新实例。

试用前停止旧 daemon、备份并复制完整状态到隔离环境验证；本任务不授权真实安装或真实 HOME 迁移。只回退二进制并不自动恢复数据与运行时状态。

## reload 与 restart 不是同义词

`reload` 重新准备 tracked source，保留 CLI 端口覆盖；读取、下载或校验失败时旧实例继续运行。当前成功路径是实例绑定的 restart fallback，不承诺原地热替换。

默认 `restart` 复用当前已认证的冻结快照，不要求原配置、provider 或脚本文件仍存在；显式新配置/override 才重新准备。目标先冻结，再停止捕获的 PID/nonce；启动失败恢复精确旧快照。前台实例须由 supervisor 重启。`config use/load` 只改变持久状态，不自动 apply；显式切换来源时使用 `restart -c <name>`，不要指望默认 restart 重读来源。

## 成熟 Rust 依赖与行为差异

- Tokio 负责可取消 socket、deadline 和任务回收；旧 Zig poll、独立 TLS I/O thread 等内部实现说明不再适用。
- rustls / tokio-rustls 使用系统信任根，支持安全默认 TLS 1.2/1.3；Trojan / AnyTLS 默认验证身份，显式 `skip-cert-verify:true` 才关闭链/身份校验，仍验证握手签名。不是照搬 Zig 的 `allow_truncation_attacks` 或自制 KeyUpdate 实现。
- `shadowsocks` crate 承担 classic AEAD TCP/UDP 加密与 framing，不重写密码协议；simple-obfs HTTP 由 zc 的有界适配器包装 TCP，UDP 不经过 obfs。
- Hickory 读取系统 DNS 配置与 hosts，网络查询异步且有 2 秒 deadline、64 query slots、最多 64 地址；缓存容量配置为 64，不是瞬时硬内存上限。它不等同于 libc/NSS、mDNS 或完整 split-DNS；配置/hosts 不自动重载，无 nameserver 时拒绝，不回退公共 DNS。
- Lua 5.4 通过 `mlua` 内嵌，在独立 worker 中执行，不要求系统 `lua/luajit`。脚本仍属于受信任代码，不是安全沙箱。

## 已对齐能力与仍有差异的边界

完整边界与资源上限见 [兼容说明](../../docs/compat/mihomo-clash.md)。功能接入和本机测试通过，不等于全部迁移验收完成：

1. **命名 direct/reject 节点**：已支持真实叶节点、规则与 select 引用，精确保留名 `DIRECT/REJECT` 仍禁止声明；Config/CLI/真实 socket 回归已覆盖。
2. **HTTP provider**：unmanaged 已接入 root-contained 安全磁盘 cache、interval 刷新、普通 HTTP 失败时的已验证缓存回退，以及独立 `test` 的 missing-only 策略；doctor 只检查声明。managed 仍拒绝引用 remote 的离线发布，不修改冻结 revision。详情及更严格的路径限制见 [兼容说明](../../docs/compat/mihomo-clash.md#rule-provider-与离线托管)。不提供 curl fallback。
3. **资源行为差异**：共享 collection/provider/展开上界已接入；YAML 已对齐原 Zig 根外 128 层；其余 parser events/nodes/scalar budgets 仍有差异。mixed 连接任务 1024 / 握手 10 秒（原为 128 / 5 秒）。这需要显式评审，不能宣称资源行为完全等价。
4. **CLI/缺省行为细节**：doctor 的多错误汇总、支持范围内的 warnings、原 source-text migration hints 及 256 条/512 bytes 错误优先预算已补齐；加载失败与语义检查失败保持分离，证据及保留差异见下节“doctor validator 诊断验收”。停止态保留显式 `mixed_port:null`；启动与重启的未转交 snapshot 由作用域 guard 清理，停止超时和取消不再遗留 staged 文件。缺省 rules 的旧审计结论已纠正：`config.zig::load/parseDocument` 的严格 CLI 路径本来就补 REJECT，DIRECT 只属于 legacy parser；原 dump 字节及真实路由已对照，不修改 canonical/hash。
5. 不支持 HTTP/SOCKS5 outbound、VMess/VLESS、SS AEAD-2022、通用 SIP003、obfs TLS、Trojan WS/gRPC、非 select 策略组、TUN/透明代理、完整 DNS、proxy-provider、TUI 或完整 mihomo Controller。订阅的 `dns/hosts/sniffer/profile/experimental/unified-delay/clash-for-android` 七个顶层字段现接受并仅在运行时投影中跳过，原始数据不重写；具体行为及待支持项见[兼容字段清单](../../docs/compat/mihomo-clash.md#接受但暂不执行的订阅字段)。其余能力准入不放宽。
6. UDP ingress 不支持 DIRECT、分片或 standalone socks-port。首个合法包固定实际 leaf，后续包不重新路由或 fallback；64 association、300 秒 idle、65507-byte wire 上界必须由真实边界测试验收。

## 验证入口与剩余门禁

```bash
just build
just run testdata/config/rust-tcp.yaml 17890
just check
just test
just delivery-test
just helper-test
just e2e
just install-test
just release
just validate
just eval-selfcheck
just eval correctness
just migrator-test
```

`just validate` 包含格式/Clippy、Rust tests、交付契约、core+TCP E2E、安装回归和 release build；不包含实际 24/72 小时长稳，也不自动完成四平台远端发布与性能等价证明。`just test` 使用文件描述符上限 8192；本地所有网络测试用隔离 HOME/runtime 与非生产端口。`just e2e` 的 fixture 版本/网络前提见 [E2E](../reliability/e2e.md)。

最终本机 beta gate **6/6**、全目标 tests/Clippy、原 core + 独立 TCP E2E、隔离安装回滚、真实 300 秒 UDP idle 均已通过；四目标 Release 已编译，其中只有 macOS arm64 在本机执行。尚未证明其余目标原生 CI、性能/内存门禁及 24/72h 长稳；未执行真实安装或删除 Zig 对照。最后性能对照的小配置 dump 仍慢 35.4%。证据及未完成项见 [completion](completion.md) 与 [performance](performance.md)。

## remaining config contracts：定向验收记录

- 原始证据：`config.zig::load/parseDocument/parseRoot` 与测试 `managed config keeps final routing terminal and fail closed`；`main.zig::ruleProviderSyncPolicyForCommand/loadRuntimeConfig/runDoctorCommand`；`doctor_cli.zig::doctorChecks`、`test_cli.zig::runConnectivityTest/getIpGeoInfo/runCurl`；`util/yaml.zig::max_nesting_depth`。旧 `zig-out/bin/zc` 均在临时 HOME、随机非生产端口下运行。
- 旧二进制探测：缺失 rules、`[]`、非空无匹配均 dump 为尾部 `MATCH,REJECT`，真实 HTTP 请求均 502；显式 MATCH,DIRECT 作为 Rust 路由测试阳性对照。`extension: [ ... ]` 128 层及根外 128 层 block mapping 接受，129 层拒绝；纯 JSON mapping 总计 129 frame 接受、130 拒绝。
- 缓存 oracle：missing 下载一次；fresh 不请求；stale 独立 test 不请求，proxy test 刷新一次；503 使用旧有效 bytes；200 畸形候选报 `PROXY_CONFIG_LOAD_FAILED` 且不覆盖旧 bytes。旧“source.yaml 同时是 cache”的 fixture 自身即加载失败，测试只改为独立 cache 路径，没有降低断言。
- 红绿证据：原 16 层拒绝合法 127/128 层；直接提高深度暴露 serde 栈溢出后加入受限解析栈；原独立 test 无视 stale cache 等待 HTTP；新增 source/cache 同路径保护；此前 Rust doctor 仅给概括错误且同步 provider body；managed one-shot 无效 deferred HTTP 声明须在 prune 前拒绝。均有公开 seam/真实临时文件与 loopback 回归。
- 定向 tests 覆盖 cache fresh/missing/stale、普通网络失败、畸形/超限 bytes、count/aggregate/entry budgets、symlink/hardlink/FIFO/目录、写失败、目录替换、迟到 headers 的可取消性及真实 30 秒总 deadline、完整 wire body 冻结后才监听、默认 restart 离线复用、managed revision 不刷新、无用 TLS roots FIFO 不被打开、精确 YAML 边界、doctor 本地探测与 IP/Location/latency target 的 JSON/text 形状。8 个相关 integration suites 共 115 tests 通过（另含 fsutil 的子进程复测）；`cargo clippy --locked --lib --tests -- -D warnings`、本机 release 构建、原样 core E2E 均通过。本轮未重新证明四平台或长稳。
- 本机 release 小样本对照（临时 HOME，3 次预热＋40 次交错测量）：小配置 dump median 原 Rust 3.811 ms、本轮 3.806 ms、优化 Zig 2.453 ms；没有可声称的 dump 改善，本轮仍慢约 55%，不替代前轮约 39% 的独立场景结果。闭端口 `test` 从 89.525 ms 到 4.747 ms，对应移除零 remote 时无用的 TLS/client 构造；Zig 为 2.781 ms。**没有正式性能 PASS**。对照 Rust 为 `target/perf/cli-final-source-1789576342623681000/target/rust-release/zc`，Zig 为 `target/perf/candidate-source-1789575884380663000/target/zig-reference/bin/zc`；当前构建 `cargo build --locked --release`。

## doctor validator 诊断验收

本节关闭此前“仅首个语义错误、warnings/migration_hints 为空”的具体 doctor 缺口，不宣称整个迁移完成。实现位于 `src/config/diagnostics.rs`，仅接入 `service::diagnose_config` 与 doctor 输出；不改变配置发布、provider 准备、cache 或 daemon，不生成可用于路由的部分配置。

- **语义诊断**：累计基础字段、代理必填项/身份、重复名称、组冲突/空组/引用、规则 payload/provider/target 错误；复用核心 typed proxy/group/provider/rule 校验，并继续拒绝所有分支上的组循环。语法、字段类型/规则格式及能力准入仍走既有加载失败路径，不把未知规则修成有效规则，也不以 hints 掩盖 unsupported 错误。语义无效仍由 config check 导致 `CHECKS_FAILED`。
- **warnings**：恢复 `allow-lan:false` 忽略非 `*` bind-address、两个 idle session 参数 `<=5` 秒的原兼容提示，以及 Trojan 关闭证书验证的警告。当时尚未启用 AnyTLS，不修改原文件或 immutable revision 的 canonical bytes；CLI 端口选择已清除的 port/socks-port 不捏造 ignored-port warnings。
- **预算**：errors/warnings 合计最多 256 条；后来的错误替换末尾 warning，独立 `has_errors` 不依赖保留条数。每条最多 512 UTF-8 bytes；超长值按原模板将所有参数替换成 `...`，追加精确后缀 ` ... [truncated]`，不先分配完整超长消息。数量或字节省略均置 `config_diagnostics_truncated`。控制字符清理前的原始字节也计费。
- **migration hints**：保留 `doctor_cli.zig::collectMigrationHints` 的四条固定英文文案、顺序、显式原始文件路径与 1 MiB 上限；仍是文本子串扫描，注释也可能触发，默认 profile 不扫描。override 的 effective bytes 不冒充原提示来源。提示不是支持承诺；当时实际 `tun/dns/proxy-providers` 声明均明确拒绝；后续订阅兼容调整仅让 `dns` 接受但忽略，`tun/proxy-providers` 仍拒绝。文本与 JSON 展示同一份有界 errors/warnings/hints。

### 独立证据

- 原 `zig-out/bin/zc` 使用规范化临时 HOME、`sandbox-exec -p '(version 1)(allow default)(deny network*)'`、随机非生产端口执行 `start --foreground --port <port> -c <fixture>`，让无效配置在绑定前进入同一 `config_validator.zig::validate`。未执行会固定探测外网/7899 的旧 doctor 命令，未把 Rust 当旧实现的 oracle。
- 二进制确认：invalid mode/log-level/未知 MATCH target 共 3 条错误，同时有 bind-address、idle timeout、Trojan TLS 共 3 条 warnings；另一配置确认重复代理/组、策略名冲突、空组、Trojan password/server/SNI、CIDR/port payload 与未知引用共 13 条具体错误。对应文字来自原 validator，不是人工编造。
- 二进制确认：log-level 消息恰好 512 bytes 不截断，513 bytes 和 164 个三字节汉字均回退到 `Unknown log level: '...' ... [truncated]`；超长 Trojan name 的 error/warning 同样使用模板。256 条 TLS warnings 后接 300 条未知 target 错误，最终仅保留 256 条错误、无 warnings，并明示省略。未知规则和畸形字段类型在加载时失败，不产生 validator 条目。
- 公开 seam 回归：`tests/diagnostics.rs`、`tests/diagnostics_validation.rs` 使用注入的真实 loopback sockets；覆盖文本/JSON 消息一致、255/256/257 数量边界、warnings 被错误替换、满预算仍 invalid、512-byte UTF-8 边界、200 KB 输入值、300 个重复/畸形节点、控制字符及凭据不泄漏、hints 的 1 MiB 边界和 unsupported 不降级。managed 子进程使用隔离 HOME，确认 source、content digest 与 catalog token 不变。红绿测试还防止把带换行的 target 额外 trim 成 core parser 原本拒绝的有效引用。
- 本轮通过：`cargo test --offline --locked --test diagnostics --test diagnostics_validation --test config --test config_parity --test service --test cli`，以及 `cli_managed::load_semantic_diagnostics_are_bounded_and_parse_failures_do_not_fake_them`，共 **72 tests**（另有 managed 子进程复测）；`cargo clippy --offline --locked --lib --tests -- -D warnings` 通过。未运行会访问默认外网 target 的旧 CLI integration case，以本地注入 seam 检查 doctor。

### 保留的精确差异

1. 原 `config_validator.zig::validateReferences` 明确允许组自引用，旧二进制的 `mode: invalid` 加自引用 fixture 只给 mode 错误；Rust 继续按现有 core validator 拒绝自引用和间接循环，包括未选分支。不为诊断一致性削弱 runtime 的 fail-closed 规则。
2. 原 validator 的 external-controller 错误模板插入完整 endpoint，`doctor_cli.zig::populateConfigData` 直接复制原消息到 JSON；Rust 不回显可能包含 URL credentials 的 endpoint，并把终端控制/双向字符清为空格，文本与解析后的 JSON 都不含原控制字符。这是本任务的凭据/终端安全要求，不承诺此类恶意输入逐字相同。
3. 原 `doctor_cli.zig::formatDoctorReport` 只有摘要标签；Rust 保留已有详细诊断输出，并同源补上 warnings/hints。核心 Rust 已有的更严格字段、名称、domain rule 等限制继续保留，其额外错误使用具体条目位置和核心校验消息，不伪称全部非法输入与 Zig 逐字等价。

性能、四平台 native release、真实安装回滚及 24/72 小时长稳仍待独立门禁；本轮定向诊断证据不替代这些验收，也未重新证明 all-targets 全量测试。

## 稳定性观测

Rust 实例已接入生命周期、连接故障分类及限频合并、异常退出诊断、脱敏 panic 记录、CPU/RSS 周期摘要和有界日志轮转；命令仍为 `zc log`，不新增配置开关或完整监控 API。连接热路径只更新计数，独立线程负责采样与写入。具体字段、归档、采样精度及不可用行为见[运行时稳定性观测](../../docs/reliability/observability.md)。

这不替代长稳、四平台、性能和发布门禁，也未更新本机在用二进制。本轮复现的停止确认与 descriptor 退出清理竞态已通过共享既有读写锁修复，并有确定性红绿回归；它不自动关闭历史 Intel CI 的其他失败。记录、迭代检视后 175 项相关测试及检视前 Release 短测边界见[观测验收记录](../observability-validation.md)。

## cache safety review 闭环

本节仅关闭已复现的缓存 P2 与同类文件身份碰撞，不改变 daemon、diagnostics、CI 或 managed revision。修改限于 `config_provider`、`fsutil` 缓存辅助函数与 `service::prepare_loaded` 的来源/缓存集成，无新依赖。

- **身份保护**：原字符串比较在本机文件系统将 `source.yaml` 与 `SOURCE.yaml` 视为同一文件时失效。现在从持有的根 dirfd 打开并保留 source/provider 文件句柄，按设备/inode 校验；source 句柄在 script/HTTP await 前持有，provider 句柄跨 HTTP await 保留。已有 local/remote、remote/remote 的大小写及 Unicode 别名在下载前拒绝，发布前再次检查；不通过任意路径 canonicalize 后 reopen 来证明别名安全。新发布缓存也保留身份，后续缺失路径别名不能覆盖它；内部 `.provider-cache.lock` 的文件身份别名在读取/发布时拒绝。
- **先验证后发布**：下载及回退字节先放入独立 assets，所有 provider、aggregate 以及完整配置语义/展开校验通过后才开始逐文件发布。140000 条有效域名被同一配置引用两次触发 262144 展开上限、后续 provider 畸形时，旧缓存均保持逐字节不变。仅有 pending writes 时增加完整解析；零更新/local-only 不额外完整解析。fresh/missing-only、普通网络失败的有效缓存回退、坏候选拒绝及 frozen managed revision 行为保持。
- **权限**：缓存 metadata/read/write 预检共享 `mode & 022 == 0`，允许 0644，拒绝 0666/0620；新写仍为 0600。只约束缓存的 POSIX mode，不宣称 ACL 证明，不扩大普通 source 的权限限制；既有 private state 规则仍严格。
- **API**：`config::sync_http_assets` 接收已经规范化的 runtime source，新增末尾 `protected_source: Option<&File>`；service 提供通过 `SecureDir::hold_cache_source` 获取的 held source，独立缓存调用无 source 时传 `None`。所有仓库调用已更新，不保留旧签名或兼容回退；provider 层不调用 override 投影。

### 红绿与回归证据

以下命令均使用已安装 Rust 1.98.1、已有依赖缓存及隔离测试 HOME；真实 loopback HTTP 使用随机端口，prepare 显式端口 23457，不绑定生产端口。

```bash
cargo test --offline --locked --test service http_cache_filesystem_alias
cargo test --offline --locked --test provider_cache existing_provider_filesystem_aliases
cargo test --offline --locked --test service expanded_provider_budget_failure
cargo test --offline --locked --test fsutil cache_permissions
cargo test --offline --locked --test provider_cache newly_published_cache
cargo test --offline --locked --test provider_cache cache_cannot_replace_filesystem_alias
```

每个上述切片均先观测失败再修复通过：source/local 文件被替换、展开失败后旧缓存变化、0666 被接受，以及新缓存/内部锁的别名被错误接受。别名测试按实际文件系统能力条件执行，不按 OS 名称猜测；另补后续坏 provider、source/local 文件在 HTTP await 期间被移入目的路径的回归。HTTP race 测试消费真实 request headers 后才执行替换，避免过早响应导致普通网络失败回退而误测发布路径。

最终定向回归：

```bash
cargo test --offline --locked --test provider_cache --test service --test fsutil --test config --test config_parity
cargo clippy --offline --locked --lib --test provider_cache --test service --test fsutil --test config --test config_parity -- -D warnings
```

共 **71 tests** 通过（另含 fsutil 两次子进程复测），修改的 Rust 文件通过 rustfmt 检查。覆盖 symlink/hardlink/FIFO、ancestor/root 替换、目录目的替换、不可用写锁、HTTP await 期间权限变为 0666、真实 30 秒 deadline、managed revision 不变及无 remote 的本地路径。

原 reviewer `/tmp/zc-provider-review.Gt5FOY/probe.rs` 在 `/tmp/zc-cache-repair-probe/probe.rs` 仅适配新增参数，并避免提前拒绝后 join 未使用的 HTTP listener，重新链接修复后的库：`case` 与 `expand` 均拒绝且 `source_unchanged=true/cache_unchanged=true`，`mode` 为 `world_writable_cache_accepted=false`；`races` 中 symlink/hardlink/FIFO/ancestor 均拒绝，root swap 仍写 held root，全部 `outside_unchanged=true`。

边界：完整配置校验先于任何候选发布，但逐文件写入不是多文件事务；后续 I/O、晚出现的文件身份碰撞或 durability uncertain 不保证回滚之前已可见的写入。没有新性能 PASS，既有性能仍慢于 Zig；全局回归、四平台、真实安装回滚与 24/72 小时长稳门禁仍待独立完成，不宣称完整 Rust 迁移验收。

## AnyTLS 原生 TCP 首版

`src/anytls.rs` 直接持有现有 rustls/Tokio TLS stream，无 worker、池、复用或 UDP；每条应用 TCP 流独占一个 session，id=1。认证一次 TLS 写，Settings/SYN/地址主动发送；v1/v2 乐观开流、控制帧、v2 心跳、默认 padding 和每节点后续 session 更新已接入。`md-5 0.11.0` 由已有锁定间接依赖改为显式直接依赖，lock 只新增根 package 依赖项，现有第三方通知已包含其 MIT/Apache-2.0 全文。

配置在 canonical 丢字段前拒绝未支持字段与未选节点，包含 override；诊断增加 AnyTLS 必填字段与 TLS 降级警告。既有 canonical/hash、全局 idle 默认、SS 和 runtime UDP SS/Trojan 白名单不改。混合配置即使允许 UDP ASSOCIATE，路由选到 AnyTLS 仍终止，不 fallback。

### 本机定向证据

- 配置准入、协议接入和 AnyTLS 诊断切片先观测失败再通过；另有背压取消/继续写的真实回归：仅 flush 后 Drop 在本机使对端停在最后一个数据帧，改为 FIN 后完成 TLS/套接字写侧 shutdown 再释放后通过，逐帧核对无重发/丢字节。新增 canonical 回归先复现 `disable-reuse` 误改变其他协议字节，再将该字段序列化限定为 AnyTLS，保持旧协议哈希输入不变。
- Rust 公共配置/准备、Connector、真实 mixed 和 CLI 日志边界覆盖 strict/canonical/override、可信/错身份/未知 CA、TLS 1.2/1.3 错误签名、独立字节 framing、分片/合并/空 PSH/大 payload、padding 原始 MD5/隔离/资源拒绝、FIN/EOF/RST/Alert/SYNACK、双任务唤醒、慢读慢写、取消 Drop、并发独占 session、UDP 拒绝与故障脱敏。
- 执行 `just anytls-e2e` 的等价 Python 脚本，固定官方 Go v0.0.13 和 v0.0.5 在 macOS arm64 本机通过：每版本 10 个场景，包含 SOCKS/HTTP CONNECT echo 与 server-first、domain/IPv4/IPv6、HTTP forward、本地 FIN 收尾、错密码、目标失败及默认拒绝自签证书。独立可信 OpenSSL 另验证两个 session 的认证、默认 padding 与服务器更新后的实际 TLS record（纯 Waste 为尺寸+7）。脚本保留日志和结果至 `target/anytls-reference/rust-e2e-*`。

最终定向 Rust 回归首轮 **215 passed / 1 ignored**（lib 加 14 个相关 integration suites）；canonical 修正后重跑 `anytls_config/config_parity/override_script` 为 **51 passed**，含一个新增用例，去重共 **216** 项通过。忽略项是既有真实五分钟 UDP idle，不宣称本轮已跑。`cargo fmt --all`、`cargo clippy --offline --locked --all-targets -- -D warnings`、新 Python 脚本 Ruff 0.16.8 检查/格式和 Justfile 契约 15 tests 均通过；未重新执行完整 core E2E/安装/发布矩阵。详细命令及本机日志索引保留于 `target/anytls-reference/implementation-validation.md`，长期测试入口和 fixture 哈希则在仓库内。

**保留边界**：FIN 是整流关闭，不承诺半关闭后的响应；CONNECT/SOCKS 成功是乐观准备完成，不是统一的远端 dial 成功确认。padding 的本地资源限制、拒绝字段详见 [兼容说明](../../docs/compat/mihomo-clash.md#anytls单流原生-tlstcp)。AnyTLS Go 门禁是显式可选命令，未纳入 `just e2e` / `just validate` / 发布 CI；生产交付不带 Go。仅固定 fixture 哈希的 macOS arm64 已执行，不宣称其他平台、完整规范合规、抗审查、性能等价或 24/72h 长稳通过。

### AnyTLS 生命周期修复后的定向验收

上节 **216 项**和首版 Go/OpenSSL 结果保留为生命周期修复前证据，不代表已经覆盖以下三个缺陷。后续独立核查复现：心跳回复依赖背压上行导致双向等待；FIN 后迟到写触发 BrokenPipe 丢掉中继已收到的下行尾部；FIN 后仍等待客户端写侧 EOF。

修复仅增加 AnyTLS 的有界心跳队列及 `IoStream::whole_close()` 可选终态通知。公共 `runtime::transfer` 与 HTTP forward 在终态停止轮询上行，排尽下行后结束；HTTPS 包裹层透传通知。DIRECT/SS/Trojan 保持原半关闭策略，不统一吞 BrokenPipe 或 TLS 截断。测试另实证 HTTP 请求头和 CONNECT 已缓存前缀需要在等待更多输入前 flush，已同步修复；没有增加后台任务或改变 daemon 生命周期。`src/daemon.rs` 仅给既有测试替身补一行显式 `IoStream` 实现。

- 三个缺陷先通过公共 Connector + 实际 transfer 入口变红，再逐片修绿。下行丢失用 `duplex(1)` 和对端观察到 TLS 释放的屏障精确触发；结束后检查迟到上行没有被读取。背压用真实 TCP/TLS、服务端 16 KiB 收发缓冲、实际 Pending 写及双向各 16776960 字节；保留无心跳对照，不用 sleep 猜测触发时机。超时仅作失败看门狗。
- `tests/anytls_lifecycle.rs` 共 **8 项**：三个主回归，加控制洪泛拒绝、取消释放、本地 shutdown 保留 65534 字节尾部、mixed CONNECT/SOCKS 前缀、HTTP/HTTPS 未完成上传时完整转发提前响应。整套连续 **20 轮通过**；32 个合法排队心跳按序响应，洪泛超限明确失败。
- 重新运行首版同范围 lib + 15 个 integration suites：**224 passed / 1 ignored**。ignored 仍为既有真实五分钟 UDP idle，本轮未执行，不计通过。原 DIRECT/SS/Trojan/obfs 半关闭、HTTP framing/100-continue/keep-alive、协议错误分类及 UDP 回归均通过。
- `cargo fmt --all -- --check`、`cargo clippy --offline --locked --all-targets -- -D warnings` 通过。先 `cargo build --offline --locked` 更新 binary，再执行 `python3 scripts/e2e/run-anytls.py target/debug/zc target/anytls-reference`：固定官方 Go 两版本各 **10 场景通过**，可信 OpenSSL 默认/更新 padding record 通过。
- 原始红绿及所有中间失败保留在 `target/anytls-reference/lifecycle/`；修复后 Go 证据为 `target/anytls-reference/rust-e2e-71oo7bem/`；完整索引追加到 `target/anytls-reference/implementation-validation.md`。期间曾有洪泛量未填满传输缓冲、前缀夹具漏发 payload、测试替身缺 trait 导致的失败，均修正后重跑，没有当作通过。

本轮未访问真实 HOME 的 zc 配置或生产端口，未 install/commit/push，未改历史 Zig。以上仍仅为 macOS arm64 本机定向验证；未重新执行完整 core E2E、安装/发布矩阵、四平台原生测试、性能/内存门禁及 24/72h 长稳。短时背压进度测试不是吞吐或抗指纹证明。


## P2：连接列表与按 ID 关闭最小版

已接入 `zc connection list`、`zc connection close <id>` 与相同模型的 minimal API。功能、字段和错误契约见 [CLI](../../docs/cli/spec.md#连接管理最小版)、[API](../../docs/api/README.md#连接模型与关闭语义)、[错误码](../../docs/api/error-codes.md#b2-connection-家族)。未增加流量计数、全部断开、历史、分页、WebSocket、自动 controller 或 TUI。

- Runtime 持有实例内 `ConnectionRegistry`，独立注入 API，与 managed selection 权威无关；没有磁盘状态或 Observer 第二份详情表。daemon 在共享和接受连接前绑定既有实例 nonce，不改变 descriptor、snapshot schema 或旧 canonical bytes。ID 为 nonce 加 checked 单调序号，关闭始终检查完整 ID；旧实例 ID 在副作用前拒绝。
- 记录仅有有限元数据、rule/leaf 索引与取消信号，不克隆包含 password 的 Proxy。每个 TCP 任务一条记录，UDP 关联共用同 ID；上界仍为 1024 任务和 64 UDP。仅在阶段/请求边界更新，查询不重路由、解析 DNS 或重算当前选择。大配置名称和规则通过借用视图有界编码，含 JSON 转义最多 4 MiB；超限完整 500，不省略条目。
- 新请求的入站类型、目标与清旧路由在同一次锁内更新。HTTP idle 清除目标与路由，下一请求重新决议；UDP 只记录首合法包，后续目标不改写首包规则/leaf。管理取消在外层优先处理，预发布 receiver 并检查当前值；closing 不被后续阶段更新覆盖。外部 RAII guard 留到 `session.close().await`、UDP worker join 和资源释放之后，正常 EOF/拒绝/异常/可捕获 panic 均回收；不 abort 整个连接任务。
- 新 GET/DELETE 均要求非空 secret 和 Bearer，旧 GET/PUT 不变。CLI 使用已认证的运行快照与 descriptor，直连、禁重定向、2 秒网络期限、4 MiB 响应检查，并前后校验 PID/nonce/endpoint/exact identity；同实例 selection generation 不作为连接身份。不回显目标、凭据或失败响应正文。无 controller/未运行明确失败；修改配置后必须显式重新准备，默认 restart 仍冻结。

### 本机证据与未完成门禁

实现切片先复现：接口 404 而非 401、真实隧道假空列表、UDP 被显示为 TCP、CLI 不认识命令、裸组吞掉非法参数、文本漏掉 UDP 首包来源/范围、错误 controller 的 active 条目缺目标仍被当成功。逐片修复后通过。HTTP forward 转 CONNECT 的过渡另做代码不变量补强：原两次锁更新存在短暂入站/阶段不一致窗口，已合并；其端到端扩展回归原本即通过，不伪称确定性复现该窗口。

本机 macOS arm64、Rust 1.98.1，lib 加 20 个相关 integration suites 共 **275 passed / 1 ignored / 1 filtered**；包含一个仅由父用例启动的外部控制器夹具入口，其子进程断言计在父用例内，不另累加。忽略的是既有真实五分钟 UDP idle；为禁止外网，过滤既有会运行默认外网 doctor 的 CLI diagnostics 用例。其余 CLI/API/daemon、正常 DIRECT/SS/Trojan/obfs half-close、AnyTLS FIN/心跳/生命周期和 UDP 回归均通过。

原子过渡补强后仅重跑受影响的 6 套（connections、connections_cli、API、runtime、socks_udp、anytls_lifecycle），**66 passed / 1 ignored**，未重复扩大整套。后补 CLI 身份定点用例使用真实 CLI 生成的认证快照，在外部 controller 收完请求后发布夹具的下一代 selection 或新实例 descriptor：同实例 generation 改变仍成功，实例 nonce 改变拒绝成功；该用例通过。没有给生产代码增加测试开关。

新增公开回归还覆盖：两条 TCP 只关一条；入站握手、出站 TLS、路由/出站 DNS 的定点取消；零 TTL 下查询不重新解析；旧 ID 防误伤；暂停独立数据面执行器时的重复 closing；UDP 首包固定与 Trojan 部分帧 worker 回收、64 槽位复用；1024/1025 任务准入；大名称与反斜杠 JSON 转义的 4 MiB 拒绝，以及后补恰好 4 MiB 成功、再增加一个节点名字节即拒绝（新增 1 项通过，去重合计 276）；CLI/API 元数据同源、终端方向控制符转义、冻结 secret、拒绝错误 JSON/schema/大小/nonce/重定向。

`cargo fmt --all -- --check` 与 `cargo clippy --offline --locked --all-targets -- -D warnings` 通过；无新增 Python 文件。详细红绿、命令及边界保存于 `target/connections/implementation-validation.md`。所有新增网络夹具仅 loopback，CLI 使用临时 HOME；未 install/commit/push，未读取真实 HOME 的 zc 配置或操作生产 7899/在用实例。

**没有性能通过声明**：阶段锁设计和资源上界测试不替代吞吐、延迟、CPU/RSS 测量。原生待完成 TCP connect 的队列饱和夹具在本机返回 RST，未得到有效取消证据；已保存失败的夹具探索，不把 DNS/TLS 取消冒充原生 connect 定点验证。未执行本轮独立 Go 互操作、四平台原生、完整 E2E/安装/发布矩阵、五分钟 idle 或 24/72 小时长稳；u64 序号溢出由 checked_add 拒绝，未以公开接口执行不可行的穷举连接次数。不宣称 Rust 迁移已完整验收或已部署。

## 自动 controller secret 的状态兼容与回退

托管 profile 的可选 `auto_controller_secret` 位于 schema-2 catalog 的 Profile 末尾；缺省不序列化，因此旧 catalog 的 canonical bytes/state token 保持不变，**不增加 catalog schema 版本**。新 reader 向后读取旧 Rust/Zig 状态，但不是双向兼容：旧 Rust 的 `deny_unknown_fields` 会拒绝含新字段的 catalog。回退必须先安全停止实例并恢复**完整旧状态备份**（含 catalog、revisions 与相应运行状态），不能仅替换 binary、从 `meta.json` 镜像恢复或手工删字段。损坏/空值/null/非小写 64 位 hex/错误类型/重复/未知字段拒绝，不删除重建、不生成替代 key。

首次实际托管运行准备中，仅当已有 controller 且缺少非空显式 secret，才在全部配置校验后持久生成 32 随机字节。显式非空值逐字节优先，旧自动值仍保留；更新/override/选择/重命名不轮换，delete+reimport 为新生命周期。只读/诊断、已运行 start、默认 restart 不生成；没有 controller 仍无 listener，不增加默认控制端口。source/materialization/assets/revision/hash 与兼容 mirror 不变，自动值不注入 dump/日志/Debug/环境/命令行。

自动 key 的使用不能仅依赖 Store 进程内的 `durability_uncertain`：首次 commit 的 receipt 若目录 fsync 失败，准备报错而不停止旧实例，已可见 key 留存；以后任意进程复用该值前都在 catalog 锁内重新同步 authority 目录。CAS 精确绑定 token/key/head，冲突失败而不覆盖赢家。后续 bind 失败不会撤销或轮换 key。start 的准备副作用现在位于既有 launch/instance 锁的所有权边界内，后台仍通过 stdin 交接同一实例锁；foreground 运行前释放 launch 锁但始终保留实例锁。已运行或竞争未获所有权的 start 不准备、不写 key，foreground 也不执行 override；restart 仍先完成准备和持久确认再停止旧实例。

运行快照独立冻结实际采用的自动 secret overlay，**有 overlay 必须 schema 2**，防止旧 Rust 的宽松 Prepared reader 忽略字段而无 secret 启动。新 reader 严格区分 schema 1（无 overlay）和 schema 2（完整合法 overlay，仅 managed、有 controller、原 source 无非空显式 secret）；坏字段、null、缺失及 HMAC 篡改均拒绝，解码错误不输出字段值。没有 overlay 继续 schema 1；旧 Rust 和认证 legacy Zig YAML 保持原 source secret，不查询新 profile 状态。需要启用自动值须显式 `restart -c <profile>`；默认 restart、readiness/selection 重写及失败回滚保留冻结认证。当前 head 已变更时既有 readiness 拒绝及精确回滚策略不变。

实现与验收记录：`target/profile-secret/implementation-validation.md`；新增公共边界测试为 `tests/profile_secret.rs`、`tests/store.rs` 与 `tests/connections_cli.rs`。旧 Rust/Zig binary 对照为显式可选用例，普通测试不自动构建或运行历史 binary。仅临时 HOME/loopback，未安装或操作在用实例；本轮不声称性能、四平台、安装回滚或 24/72 小时长稳通过。


## 用户服务与本地冷升级

本次用户授权范围、验收契约与验证结果见 [契约](../service-upgrade-contract.md)、[验证](../service-upgrade-validation.md)。新增 `zc service` 与本地安装器状态保持冷升级；不追随旧 Zig 热升级提案，不提供无中断切换。

仅服务实例在 descriptor 末尾写可选 `service_id`，与注册、管理器 PID、nonce、认证快照及实例锁共同校验。普通手动实例省略该字段，原 descriptor canonical bytes 保持；旧严格 reader 可能拒绝新服务 descriptor。自动恢复适用于已经接受原注册/快照格式的旧服务二进制，不把它扩写为任意历史版本的数据格式回退。恢复兼容边界与完整状态备份要求保持。

本机新服务测试使用独立管理器替身和真实隔离 daemon/二进制发布；没有真实用户服务变更或生产安装。首轮累计去重 227 项定向回归通过、3 项历史二进制忽略，以及未解决的 override_spawn 失败分别记录。后续服务恢复修复的当前定向验证为 185 passed / 3 ignored，含 27 项用户服务测试、36 个中断/超时子场景；本轮未运行 override_spawn。详细红绿、人工恢复边界及原生 Linux 待验证项见上述验证文档；构建/Clippy 通过不代替原生平台、性能、四平台或长稳证据。

## 通配 controller 兼容与鉴权

用户确认支持旧配置的 `0.0.0.0:<port>`：保留 source、catalog 与 snapshot 格式，本机 descriptor endpoint 仍为 loopback；托管自动 secret 在实际准备时生成，非托管缺少 secret 在启动/服务注册前拒绝。内部 status 和服务选择捕获使用冻结凭据。217 项相关回归通过、3 项历史二进制忽略；Release 经本机两类网卡验证 401/200。未安装或改动真实配置，完整证据与边界见 [验证记录](../reliability/controller-wildcard.md)。
