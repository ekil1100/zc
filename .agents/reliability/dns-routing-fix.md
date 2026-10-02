# TCP 代理域名被本地 DNS 错地址固定：根因与修复验收

## 范围与结论

2026-09-30，macOS arm64，Rust 1.98.1。修复基线为 `c3bb2d2f95846d39f2c747c136143f17ee15626d`，候选为该基线上的本轮未提交改动。

**已修复 zc 在纯 DIRECT 地址分流未命中后，仍把本地 DNS 地址强制用于 TCP 代理的行为。** 用户确认的范围是：仅放宽此路径，保留实际 IP 命中、限制性地址规则、DIRECT 与 UDP 的地址固定保护。未添加公共 DNS 回退、npm 特例、TLS 降级或重试。

首次交付已完成本机定向测试、独立边界核查、真实配置隔离对照及路由微基准，但**没有执行完整 `zc test` 或安装后的生产冒烟，不能据此宣称日常代理全面可用**。当时未安装、提交、推送或重启生产实例；生产端口 7899 未用于启动测试服务，原生产 PID 39575 仍在运行。

2026-10-01 用户安装并重启后的首轮补充验收为**不通过**：生产实例及新旧隔离实例均只有 1/7 目标成功，`vite.plus` 返回 502。00:55 前后的 zc/mihomo 同机对照及生产复验均为 **7/7 通过**，两个 HTTPS 下载地址均返回 200，证书校验通过；同一组节点地址恢复了 TCP 连通性，原生产 PID 59766 保持运行。这次恢复期间没有更新订阅、切换节点、重启生产或新增产品代码修复，详见下文；专项通过与间歇性连接故障分开记录。

## 根因证据

### 历史记录

- pi session `01a0ef2a-c535-705d-9133-36b0a927dd1d`（2026-09-29）的第 75、107 行：npm 域名请求被路由到 `141.193.154.70:443`，收到只有该 IP、没有 npm 域名的证书；同节点固定正常 IP `104.16.6.34` 后 HTTP 200、TLS 校验通过。
- 同一 session 第 187 行：直接向路由器查询 A 记录，也收到 `141.193.154.70`。该查询不经过 zc。之后 DNS 和代理请求曾自行恢复，但当时没有代码修复。
- 安装 session `01a0f2c4-498c-751a-91a9-f36bd4887cf9`（2026-09-30）：经代理下载 npm metadata 再次出现 curl 60，直连正常，仅以临时绕过 npm 代理完成安装。

### 本轮现场与实现

本轮直接查询路由器和 Tailscale DNS，再次得到 npm 的错误 A 记录 `141.193.154.70/210`；当时正常 AAAA 与错误 A 也曾共存。不能将此归因于单纯 IPv6 优先或缓存无限续期，更不能从这些证据确定路由器内部改写机制或具体上游责任。

当前配置的地址规则中，只有索引 4273 的 `GEOIP,CN,DIRECT` 会解析域名；其他地址规则带 `no-resolve`。该规则未命中后，最终索引 4274 的 `MATCH` 选中 SS。旧 `Config::route_with_context` 无条件采用 `pinned.or_else(resolved[0])`，把仅为尝试分流取得的错误地址固定为 SS 目的地址，阻止节点自行解析原域名。

## 实现边界

- `src/config.rs`：累计本次已经过的、需要解析的 IP/GEOIP 规则是否全部直接引用 DIRECT 叶节点。字面量 DIRECT 与命名 direct 均可；REJECT、其他代理及任意 select 组都会永久关闭本次路由的域名例外，后续 DIRECT 不会重新放开。
- 最终选中非地址规则和 SS/Trojan/AnyTLS 叶节点时，符合上述条件的 TCP 请求保留原域名。最终 select 的 leaf 只解析一次，既用于判断，也用于 Route。
- 真正命中的 IP/GEOIP 规则始终优先保留匹配地址，包括非首个 A/AAAA；DIRECT 与限制性前缀继续使用同一 DNS 快照。
- `route_udp_with_context` 明确禁用此例外，`src/runtime.rs` 的真实 UDP 首包入口已切换；后续 datagram 语义未修改。
- `no-resolve`、first-match、DNS 失败拒绝、TLS 身份验证保持原行为。未更改 source、revision、snapshot 或持久化格式。
- 用户可感知语义见 [兼容说明](../../docs/compat/mihomo-clash.md#代理组规则与-dns)。本地 DIRECT 分流未命中后，远端最终 IP 不再触发第二次分流；这不是完整 DNS 能力或错误应答检测。

## 确定性红绿测试

新增 `tests/dns_routing.rs` 使用真实 loopback DNS 应答与 SS 协议服务端，不 mock 私有路由或解析器：

```bash
cargo test --offline --locked --test dns_routing tcp_proxy_keeps_domain_after_unmatched_direct_geoip -- --nocapture
```

修复前：

```text
left: 141.193.154.70:443
right: registry.example.:443
FAILED
```

修复后：SS 握手发送原域名，测试通过。六个新增用例覆盖：

1. 错误 DNS 地址经过未命中的 DIRECT/GEOIP 后，SS 线上目标保留域名。
2. 21 组路由边界：限制性规则在 DIRECT 前后、命名叶节点、嵌套拒绝组、前置可变组、最终 select、IPv4/IPv6/GEOIP 非首地址匹配、no-resolve、提前命中及 SS/Trojan/AnyTLS 路由结果。
3. 字面量 IP 和提前命中域名不引入 DNS。
4. DNS 超时不能当作未命中而退到代理。
5. 真实 HTTP CONNECT / SOCKS5 CONNECT → SS → TLS：正确证书名称完成收发，错误名称仍拒绝，SS 线上地址独立断言为域名。
6. 真实 SOCKS5 UDP ASSOCIATE → SS UDP：同样的 DIRECT 前缀仍发送原快照 IP。

`tests/dns.rs` 另扩展零 TTL 的 DIRECT 对照，证明未命中的 DIRECT 地址规则也不会使最终直连重新解析。

TLS fixture `testdata/e2e/dns-route-cert.pem` 的 SAN 为 `front.example`，复用仓库既有的测试私钥；只加入测试客户端局部信任库，不修改系统信任。夹具编写期间出现过类型标注缺失、IPv6 范围误选、误用已有证书 SAN、误把内置 GEOIP 当作真实地理库的测试错误，均修正后重跑；不将这些失败计作产品回归。

## 真实配置隔离对照

工件：`target/dns-routing/live_probe.rs`、`live-baseline.log`、`live-candidate.log`。

方法：调用既有只读 `capture_restart` 验证并取得运行快照，在内存中应用原规则、资产和选择；凭据不打印、不写入工件。另建 loopback DNS，仅对 npm 强制返回 `141.193.154.70`，代理服务器域名等其他查询仍由系统路径解析。使用随机非生产 mixed 端口，不启动 controller，不调用生产 restart/stop/apply。对照分别链接基线和候选库，均使用原配置的同一代理节点。

| 请求 | 基线 | 候选 |
| --- | --- | --- |
| `/vite-plus/latest` | curl 28，TLS 超时 | HTTP 200，TLS 校验 0，12547 字节 |
| 平台包 `darwin-arm64/1.0.0` metadata | curl 60，证书名称不匹配 | HTTP 200，TLS 校验 0，1994 字节 |
| 对应完整 `.tgz` | curl 28，TLS 超时 | HTTP 200，TLS 校验 0，4462436 字节 |

两者命中相同索引 4274；基线 `routed_host=141.193.154.70`，候选 `routed_host=registry.npmjs.org`。这把外部 DNS 波动从对照变量中排除，复现了原始证书错误和超时，而不是用重启后一次成功冒充修复。未执行下载的安装脚本或二进制。隔离 runtime、DNS 任务均已回收。

## 回归与构建

```bash
cargo test --offline --locked \
  --test config --test config_parity --test dns --test dns_routing \
  --test outbound --test runtime --test socks_udp --test connections \
  --test anytls --test anytls_lifecycle
cargo fmt --all -- --check
cargo clippy --offline --locked --all-targets -- -D warnings
cargo build --offline --locked --release --lib --bin zc
```

结果：**132 passed / 1 ignored**；忽略的是既有真实五分钟 UDP idle 测试，未计入通过。格式、严格 Clippy、Release 构建通过。独立只读核查未发现阻塞问题。

新增组合端到端场景使用 SS 承载目标 TLS；Trojan/AnyTLS 依靠新增路由断言、既有域名协议编码与 TLS 回归，以及未改变的 Connector 路径支撑，不宣称新增三协议组合端到端证据齐全。

## 局部路由性能对照

基线与候选均为 Rust 1.98.1 Release、thin LTO。相同 harness，11 组交错进程样本，每个场景先预热 1000 次；仅测 `Config::route`，不含解析配置、远端网络或吞吐。工件：`target/dns-routing/route_bench.rs`、`performance.json`。

| 场景 | 基线中位数 ns/次 | 候选中位数 ns/次 | 变化 |
| --- | ---: | ---: | ---: |
| MATCH DIRECT | 35.37 | 36.17 | +2.25% |
| 4273 条未命中域名规则 | 7644.96 | 7651.33 | +0.08% |
| 4273 条 no-resolve 地址规则 | 7734.50 | 7775.35 | +0.53% |
| DIRECT 分流未命中后代理 | 1019.45 | 967.83 | -5.06% |
| REJECT 前缀后代理 | 910.75 | 929.59 | +2.07% |

其余差异较小且样本范围有重叠；本次没有发现明显的局部路由性能劣化，但不据此声称全局性能门禁、吞吐、内存或长稳通过。第一次独立链接微基准时未传 thin LTO，触发 Apple linker 与 Rust LLVM bitcode 版本差异；随后按项目 Release 参数链接成功，未更改生产构建配置。

## 安装后的完整冒烟失败与补充诊断

2026-10-01（UTC+8），用户报告安装后 `zc test` 只有 Cloudflare 成功，下载 `vite.plus` 返回 502。首次交付漏测完整 CLI 冒烟，此处纠正验收范围；不能因为单项自动化、三个 npm 地址或 CLI 退出码为 0 就称整体修复完成。

### 直接复现与新旧对照

- 生产 PID 59766；已安装二进制与 `target/release/zc` 的 SHA-256 相同，排除仍运行旧安装文件这一解释。
- 生产 `zc test --json`：Cloudflare 成功，其余 Google、YouTube、Netflix、OpenAI、GitHub 超时，IP/Location 无响应。
- 显式经 `127.0.0.1:7899` 访问 `https://vite.plus`，收到 HTTP CONNECT 的 `502 Bad Gateway`；未进入目标 TLS 握手。较短的客户端超时也曾表现为 curl 28。
- 连接快照显示 `routed_target=vite.plus:443`、阶段 `connecting`，命中索引 4274 的 MATCH，选择与首次对照相同名称的 SS 节点；日志错误为 `stage=connect, error_kind=TimedOut`。
- 在随机 loopback 端口，对基线和候选分别运行同一当前配置、资产、选择及真实系统 DNS，不注入 DNS 应答。两者完整 `zc test` 都是 **1/7**，两者 `vite.plus` 都返回 **502**。隔离实例均已退出；未重启或更改生产选择。
- `zc test` 的 Cloudflare 实际目标为 `http://1.1.1.1`，当前配置命中索引 4262 的 **DIRECT**，并不证明 SS 节点可用。当前聚合检查只要至少一个目标成功就返回 `ok=true`、退出码 0；本次以逐目标结果验收，不修改该既有 CLI 契约。

工件：`target/dns-routing/smoke_probe.rs`、`smoke-baseline.log`、`smoke-candidate.log`。

### 节点入口探测

- 当前 SS 节点域名得到 4 个 IPv4 地址。逐地址、绕开 zc 的原生 TCP 连接探测均在 2 秒内未建立连接；真实 zc 路径则触发完整 10 秒建连期限。
- Hickory 系统解析、macOS 原生解析、通过校验 TLS 的阿里 DoH 和腾讯 DoH 返回同一组地址；每组地址的节点端口探测均超时。Google/Cloudflare DoH 探测未成功，不作为地址正确性的证据。
- 四个地址路由均走 `en1`，不是 loopback、私有 IPv4 或 CGNAT 地址；不能仅凭这些信息断定 ISP、路由器或服务商中的具体责任方。
- 另对已配置的三个新加坡备选和一个香港备选做只读入口探测，解析出的节点地址也均未通过 TCP 建连探测。未改生产选择；由于没有可达入口，没有将备选计作完整冒烟通过。
- 外部 DoH 仅为诊断对照，**没有加入运行时回退、修改系统 DNS 或写入用户配置**。工件不保存节点域名、地址或凭据，地址以不可直接识别的标识关联。

工件：`target/dns-routing/server_dns_probe.rs`、`server-dns-expanded.log`、`node-network-route.log`、`node_smoke_probe.rs`、`node-smoke.log`、`node-smoke-hk.log`。

### 订阅更新链路核对

用户要求继续修复后，再次复现生产 `zc test` 仅 1/7 成功，并只读读取当前 revision 记录的订阅 URL。未发布新 revision、执行覆盖脚本或更改运行配置。

- 保存的订阅转换地址返回 HTTP 400，正文提示源链接没有有效节点信息；后续也观察到转换地址请求超时。
- 从转换 URL 的 `url` 参数提取源订阅，直接请求得到 **HTTP 404，空响应体**。分别使用 `Clash.Meta`、`clash.meta/1.19.18` 和 `Mozilla/5.0` 均得到同样结果。
- HTTPS 使用正常证书校验，请求显式直连；未输出完整 URL、token 或节点凭据。
- 这证明当前记录的源订阅在本机无法获取节点信息，自动更新当前配置也会失败；尚不足以判定是链接撤销、服务地址迁移还是服务端访问策略，更不把 404 直接认定为账户欠费或全部节点超时的唯一原因。

该核查只说明订阅更新链路当时不可用；它与现有节点连接超时的因果关系尚未建立。此前把有效新订阅当成继续修复的前提，依据不足；后续在完全没有更新订阅的情况下恢复，更说明应将两者分开处理。原始脱敏工件：`target/dns-routing/source-subscription.log`、`source-subscription-agents.log`；诊断程序：`subscription_probe.rs`、`source_subscription_probe.rs`。

### 同机对照前的结论与未解决项

当前可直接证明的故障边界是**本机到所选代理节点入口的 TCP 连接超时**；它发生在发送代理目的域名和目标 TLS 之前，基线与候选均失败，绕开 zc 的原生连接也失败。因此不能用回退域名修复、关闭 TLS 校验或修改目标站点解析来解决本轮 502。

尚无法区分节点/入口服务故障、链路丢弃或其他网络侧原因；需要入口服务端证据或来自另一网络的同入口探测。**日常代理尚未恢复，完整冒烟仍未通过。** 未新增产品代码改动，也未安装脚本、切换生产节点或重启生产进程。

## zc / mihomo 同机对照与生产恢复复验

2026-10-01 00:55 前后（UTC+8），使用本机 Clash Verge 附带的 **Mihomo Meta v1.19.31，darwin arm64** 对照当前候选 zc。

### 对照方法与边界

- 只读捕获现有运行快照；两者使用相同源节点参数、4275 条规则和代理组选择。启动 mihomo 后通过其私有 loopback controller 设置选择，并逐组断言一致。
- zc、mihomo 分别绑定随机非生产 mixed 端口；mihomo 的 controller 也使用临时 loopback 端口与随机认证值。额外监听、TUN、自动地理库更新、选择持久化和 UI 下载均关闭；未启用系统代理或更改生产配置。
- 原配置 `dns.enable=false`；各核心沿用自己的默认解析路径，未注入公共 DNS。mihomo 地理库取本机已安装的现有文件；zc 沿用已有实现，因此保留这项实现差异，不声称地理分类数据库完全相同。
- 两个核心同时执行同一已安装 CLI 的 `zc test --port <隔离端口> --json`，然后分别以显式 HTTP 代理请求两个 HTTPS 下载地址。
- mihomo 所需凭据配置仅存于权限受限的临时目录，结束后连同原始日志删除；zc 与父进程之间通过私有管道传递快照。持久工件仅保留脱敏结果。

### 结果

| 环境 | 完整连通性检查 | `https://vite.plus` | npm `/vite-plus/latest` |
| --- | --- | --- | --- |
| 隔离 zc | 7/7 | HTTP 200，TLS 校验 0 | HTTP 200，TLS 校验 0 |
| 隔离 mihomo | 7/7 | HTTP 200，TLS 校验 0 | HTTP 200，TLS 校验 0 |
| 生产 zc，端口 7899 | 7/7 | HTTP 200，TLS 校验 0 | HTTP 200，TLS 校验 0 |

生产 PID 仍为 **59766**，复验时已运行 2909 秒。再次只读解析并逐地址探测所选节点，四个地址标识与失败阶段完全相同，仅顺序不同：`5158cb5c94d1640e`、`181849f4f77a79d7`、`6427ea1f2d0c0851`、`7dda8dbe73a8c129`。此前它们逐个连接超时，此时均成功建立 TCP 连接，路由仍走 `en1`。

结论：**本轮连接故障随现有入口连通性恢复而消失；这次没有新增代码修复，也没有通过更新订阅、替换节点或重启恢复。** 当前同机对照没有发现 zc 独有的失败，但故障发生时未获得 mihomo 的同步样本，因此这次成功对照不代表已经排除所有间歇性差异。究竟由入口服务还是中间链路恢复触发，仍缺少上游证据。

工件：`target/dns-routing/comparison_bridge.rs`、`compare_mihomo.py`、`mihomo-comparison.jsonl`、`production-after-comparison.json`、`node-recovery.log`。隔离进程均已退出，临时凭据目录已删除；未执行下载内容。

## 保留边界

- 本轮不修复路由器或其上游错误 DNS 应答本身。需要 IP 固定的规则、已经误命中 DIRECT 的坏地址、代理节点自身 DNS 故障，不在此例外覆盖范围。
- 不把任意网络超时都归于这一个缺陷；证明的是同一错地址在本次链路上的证书错误/超时可由修复消除。
- 未执行完整发布矩阵、其他平台、全量 E2E、五分钟 UDP idle 或 24/72 小时长稳。
- 工件保存在 `target/dns-routing/`，仅本机可用；本记录保存长期结论与关键输出，不包含订阅、节点地址或凭据。
