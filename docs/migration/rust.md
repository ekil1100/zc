# Rust 迁移：候选实现与验收边界

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
| `src/daemon.rs` | PID/lock/nonce 身份、认证快照、readiness、stop/restart/回滚、live selection |
| `src/api.rs` | 有界 loopback minimal HTTP API、Bearer 与 managed generation 校验 |
| `src/config.rs`、`src/config_provider.rs` | 有界 YAML、规则展开、select 索引与路由 |
| `src/override_script.rs` | Lua/可执行脚本、canonical materialization、只用于运行时的兼容字段投影 |
| `src/runtime.rs` | mixed HTTP/SOCKS5、转发、UDP association 生命周期 |
| `src/outbound.rs`、`src/simple_obfs.rs`、`src/udp.rs` | TCP/TLS、classic SS、obfs HTTP、SS/Trojan UDP |
| `src/dns.rs`、`src/target.rs` | 有界异步 DNS、目标校验与路由后地址固定 |

生产只交付 `zc`。`examples/` 下的 origin、obfs、SS UDP 程序是独立测试 helper，不安装、不导入生产协议实现作为 oracle。

## 已接入的用户路径

- 完整命令树：`help/version`、`start/up`、`stop/down`、`restart/reload/status/log/test/doctor`、`config load/list/download/update/use/delete/dump/override`、`proxy/profile list/select/test`、`diag doctor`。详见 [CLI 契约](../cli/spec.md)。
- 托管 profile 的 immutable source、本地 provider assets、metadata、冻结 override 与 desired selections；先提交 durable desired，再尝试 exact revision 的 live apply。
- 后台或 supervised foreground daemon；监听器绑定和 desired reconciliation 完成后才发布 ready 并开放数据面。控制面只有显式 `127.0.0.1:<port>`，占用即失败。
- 内置 DIRECT/REJECT、classic AEAD SS、原生 TLS Trojan TCP；SS 的内建 simple-obfs HTTP；`udp:true` SS/Trojan 经 mixed SOCKS5 UDP ASSOCIATE。
- select 默认首成员、嵌套组、持久选择、循环/未知引用拒绝；first-match 规则、本地和 unmanaged HTTP rule-provider 展开。
- minimal API：`/`、`/version`、`/proxies`、`/rules`、`/status`、`PUT /proxies/<group>`，详见 [API](../api/README.md)。

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
- rustls / tokio-rustls 使用系统信任根，支持安全默认 TLS 1.2/1.3；Trojan 默认验证身份，显式 `skip-cert-verify:true` 才关闭链/身份校验，仍验证握手签名。不是照搬 Zig 的 `allow_truncation_attacks` 或自制 KeyUpdate 实现。
- `shadowsocks` crate 承担 classic AEAD TCP/UDP 加密与 framing，不重写密码协议；simple-obfs HTTP 由 zc 的有界适配器包装 TCP，UDP 不经过 obfs。
- Hickory 读取系统 DNS 配置与 hosts，网络查询异步且有 2 秒 deadline、64 query slots、最多 64 地址；缓存容量配置为 64，不是瞬时硬内存上限。它不等同于 libc/NSS、mDNS 或完整 split-DNS；配置/hosts 不自动重载，无 nameserver 时拒绝，不回退公共 DNS。
- Lua 5.4 通过 `mlua` 内嵌，在独立 worker 中执行，不要求系统 `lua/luajit`。脚本仍属于受信任代码，不是安全沙箱。

## 已对齐能力与仍有差异的边界

完整边界与资源上限见 [兼容说明](../compat/mihomo-clash.md)。功能接入和本机测试通过，不等于全部迁移验收完成：

1. **命名 direct/reject 节点**：已支持真实叶节点、规则与 select 引用，精确保留名 `DIRECT/REJECT` 仍禁止声明；Config/CLI/真实 socket 回归已覆盖。
2. **HTTP provider**：unmanaged 已接入 root-contained 安全磁盘 cache、interval 刷新、普通 HTTP 失败时的已验证缓存回退，以及独立 `test` 的 missing-only 策略；doctor 只检查声明。managed 仍拒绝引用 remote 的离线发布，不修改冻结 revision。详情及更严格的路径限制见 [兼容说明](../compat/mihomo-clash.md#rule-provider-与离线托管)。不提供 curl fallback。
3. **资源行为差异**：共享 collection/provider/展开上界已接入；YAML 已对齐原 Zig 根外 128 层；其余 parser events/nodes/scalar budgets 仍有差异。mixed 连接任务 1024 / 握手 10 秒（原为 128 / 5 秒）。这需要显式评审，不能宣称资源行为完全等价。
4. **CLI/缺省行为细节**：doctor 的多错误汇总、支持范围内的 warnings、原 source-text migration hints 及 256 条/512 bytes 错误优先预算已补齐；加载失败与语义检查失败保持分离，证据及保留差异见下节“doctor validator 诊断验收”。停止态保留显式 `mixed_port:null`；启动与重启的未转交 snapshot 由作用域 guard 清理，停止超时和取消不再遗留 staged 文件。缺省 rules 的旧审计结论已纠正：`config.zig::load/parseDocument` 的严格 CLI 路径本来就补 REJECT，DIRECT 只属于 legacy parser；原 dump 字节及真实路由已对照，不修改 canonical/hash。
5. 不支持 HTTP/SOCKS5 outbound、VMess/VLESS/AnyTLS、SS AEAD-2022、通用 SIP003、obfs TLS、Trojan WS/gRPC、非 select 策略组、TUN/透明代理、完整 DNS、proxy-provider、TUI 或完整 mihomo Controller。
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
- **warnings**：恢复 `allow-lan:false` 忽略非 `*` bind-address、两个 idle session 参数 `<=5` 秒的原兼容提示，以及 Trojan 关闭证书验证的警告。不启用 AnyTLS，不修改原文件或 immutable revision 的 canonical bytes；CLI 端口选择已清除的 port/socks-port 不捏造 ignored-port warnings。
- **预算**：errors/warnings 合计最多 256 条；后来的错误替换末尾 warning，独立 `has_errors` 不依赖保留条数。每条最多 512 UTF-8 bytes；超长值按原模板将所有参数替换成 `...`，追加精确后缀 ` ... [truncated]`，不先分配完整超长消息。数量或字节省略均置 `config_diagnostics_truncated`。控制字符清理前的原始字节也计费。
- **migration hints**：保留 `doctor_cli.zig::collectMigrationHints` 的四条固定英文文案、顺序、显式原始文件路径与 1 MiB 上限；仍是文本子串扫描，注释也可能触发，默认 profile 不扫描。override 的 effective bytes 不冒充原提示来源。提示不是支持承诺；实际 `tun/dns/proxy-providers` 声明继续明确拒绝。文本与 JSON 展示同一份有界 errors/warnings/hints。

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
