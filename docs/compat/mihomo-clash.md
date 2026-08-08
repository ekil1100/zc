# zc mihomo/clash compatibility boundaries

This document describes compatibility based on current code, not aspirational roadmap items.

## Summary

zc v1.0 targets a practical subset:

- mixed inbound only;
- static proxy nodes and select proxy groups;
- core rule matching;
- rule-provider expansion;
- minimal API;
- CLI-first diagnostics.

zc v1.0 is **not** a full mihomo/clash replacement.

## Config fields

Implemented parser fields include:

- `port`
- `socks-port`
- `mixed-port`
- `allow-lan`
- `bind-address`
- `mode`
- `log-level`
- `external-controller`
- `proxies`
- `proxy-groups`
- `rule-providers`
- `rules`

Known gaps:

- `dns:` is not wired as a full runtime DNS config;
- `redir-port` / `tproxy-port` are not active runtime listeners;
- `proxy-providers` are not supported;
- managed revisions use captured local `rule-providers`; every referenced local provider is expanded from captured bytes, while a referenced remote provider that remains as `RULE-SET` is rejected before **any** managed revision publication (including inactive publication) and again at the exact persisted activation/runtime gate. An unused remote declaration with no `RULE-SET` reference may remain deferred. Managed loading never falls back to cwd/source paths. Capture accepts at most 4096 local-provider assets and 16 MiB per asset, matching the provider count/source limits. Each remote provider body is likewise limited to 16 MiB and all cached/downloaded provider sources in one sync pass share a fixed 64 MiB raw-byte budget. Under proxy-compatible HTTPS fallback, std HTTP and curl consume one shared remaining window: failed/HTTP-400 std response bytes reduce curl's cap and are included in successful download accounting. A candidate replaces an existing cache only after strict parse/validation, shared-budget reservation, and atomic publication. Only ordinary network/status failure may fall back to a strictly validated cached source; allocation, YAML, invalid-candidate, and resource-limit errors propagate unchanged;
- `external-controller` is restricted to an explicit `127.0.0.1:<port>` endpoint；端口冲突时启动失败，不自动漂移或静默关闭控制面；
- TUN/fake-ip/enhanced-mode are not supported;
- both legacy and managed YAML parsing reject nesting deeper than 128 levels;
- managed/offline configs without `MATCH` receive an implicit terminal `MATCH,REJECT`; duplicate or non-terminal `MATCH` entries are rejected. A legacy config with no `rules` field retains its historical `MATCH,DIRECT`; any present, well-formed ruleset without `MATCH` receives `MATCH,REJECT`, while malformed rule values are rejected;
- rules use declaration-order first-match semantics across rule types. Domain matching is ASCII case-insensitive and ignores a final root dot. Domain targets reaching `IP-CIDR`, `IP-CIDR6`, or `GEOIP` use the system resolver and a bounded 256-entry process cache;
- the mixed listener admits at most 128 concurrent connection workers. Initial HTTP/SOCKS negotiation has one 5-second monotonic deadline; excess or stalled handshakes are closed without terminating the daemon.

## Config resource limits

Every parser and runtime entry point uses one fixed, public resource contract:

- at most **262144 decoded YAML collection entries globally**: every block/flow mapping entry and sequence item counts, including nested and unknown extension data;
- at most **4096 rule-provider declarations**;
- at most **262144 normalized entries in each rule-provider**, and at most **262144 normalized entries / 64 MiB normalized entry bytes across all providers**; legacy/raw line providers without a YAML `payload:` wrapper use the same shared budget;
- at most **64 MiB aggregate raw rule-provider source bytes** across cached files and download bodies in each synchronization or authoritative load pass, independently of normalized bytes, so comments/low-normalization documents cannot amplify work; each individual provider source remains bounded to 16 MiB;
- after `RULE-SET` resolution, at most **262144 rules / 64 MiB owned payload+target bytes**. Every repeated provider reference is charged again; classical entries conservatively charge their full normalized entry length as the payload bound;
- at most **4096 proxy nodes**;
- at most **1024 proxy groups** in total, including groups declared in the compatibility `proxies:` mixed array;
- at most **5120 raw entries** in that mixed `proxies:` array (the checked sum of the two limits, including subscription information banners that zc later ignores);
- at most **5122 members per proxy group** (all possible proxy/group identities plus the `DIRECT` and `REJECT` literals);
- at most **1024 persisted selections** per profile.

Complete config sources have one public **16 MiB** bound. `config.load`, managed document loading, catalog capture, and replacement snapshots probe one byte past that bound: exactly 16 MiB is accepted, while 16 MiB + 1 returns a size error. A long source is never treated as a valid truncated YAML prefix, including when meaningful fields occur after the first MiB.

The exact maxima are accepted. A raw provider accepts exactly 262144 normalized entries when it is the only provider; the next normalized entry returns `RuleProviderAggregateEntryCountLimitExceeded` before cloning or list growth. Multiple providers consume shared normalized and raw-source budgets, and downloaded single-provider candidates retain the same fixed per-provider bounds. Sync passes the currently remaining raw budget (capped by the 16 MiB single-source bound) to the HTTP body writer; zero remaining bytes means no request is issued. A completed body is charged, while a transport failure with unreported partial bytes conservatively charges its advertised cap before cached fallback. Candidate reservations commit only after atomic visibility. Runtime loading then performs an independent shared-budget pass to detect post-sync file changes. A YAML-wrapped payload also consumes its surrounding mapping/sequence entries from the global document budget and can therefore reach `YamlCollectionEntryLimitExceeded` first. YAML allocation, collection-budget, and nesting errors never fall back to the line parser; only an ordinary syntax-compatibility failure may try the bounded legacy parser. Plain legacy lines and raw classical rules remain compatible.

Expansion first builds a bounded borrowed-key provider-name hash index and rejects duplicate names. It then uses hash lookup to precompute final count and conservative owned bytes with checked arithmetic. Remote providers retained by managed local-only preparation keep their unresolved `RULE-SET` as one rule. Only after the complete plan is within bounds does zc reserve the output once and clone/expand rules. Complexity is `O(providers + rules + expanded)`, rather than a provider scan per rule. Repeated references, several providers, and target-byte multiplication all consume the final budget.

Resource excess returns one of `ConfigTooLarge`, `YamlCollectionEntryLimitExceeded`, the proxy/group errors, `RuleProviderCountLimitExceeded`, `RuleProviderAggregateEntryCountLimitExceeded`, `RuleProviderAggregateBytesLimitExceeded`, `RuleProviderAggregateSourceBytesLimitExceeded`, `ExpandedRuleCountLimitExceeded`, or `ExpandedRuleBytesLimitExceeded` before revision publication, listener creation, output reservation, or dial. `requireConfigResourceLimits` applies the same checked contract to manually constructed providers, existing entries, and rules. At the CLI seam, `config load`, `config download`, and `config update` map those typed resource errors to `CONFIG_LOAD_LIMIT_EXCEEDED`, `CONFIG_DOWNLOAD_LIMIT_EXCEEDED`, and `CONFIG_UPDATE_LIMIT_EXCEEDED`; the 16 MiB source bound keeps separate `*_TOO_LARGE` codes. Catalog and legacy admission leave authoritative `state-v2.json` and the immutable revision tree unchanged on rejection. Reduce/filter YAML, provider entries, repeated references, or long targets and retry. There is no limit switch, truncation, compatibility fallback for resource errors, or partial publication.

`OutboundManager.init`/`initWithKey` return an **owned pointer to a public opaque handle**; callers must invoke `deinit` exactly once and cannot construct a manager value with a struct literal. Its public persisted-selection transaction and selection-barrier owners are likewise allocated opaque pointers: `commit`/`deinit` consumes a transaction, and `deinit` consumes a barrier, exactly once. Copying one of those pointers does not create another owner, and the former shallow-copyable value API is intentionally incompatible. The private implementation borrows the admitted `Config`: the value and all nested storage must remain alive, immutable, and address-stable until handle deinit. Runtime config mutation is outside the interface and is not a supported recovery mechanism.

Validation retains at most **256 errors and warnings combined**, with at most **512 rendered bytes per entry**. Oversized details use a bounded omission message; additional entries set `diagnostics_truncated` without allocating. Invalid status remains exact even when an error is omitted. Text validation and doctor output report that additional details were omitted.

`PersistedSelectionCountLimitExceeded` belongs to catalog/selection mutation, not to config YAML. The mutation seam enforces at most 1024 desired selections per profile. The config CLI retains a defensive catch for that typed error, but the normal load/download/update source path cannot construct it. A pre-existing `state-v2.json` with more than 1024 selections is corrupt catalog state and fails closed; it is not downgraded to a user-correctable source limit and receives no backward-compatibility exception.

## Proxy support

Runtime outbound support currently includes:

| Type | v1.0 status | Notes |
| --- | --- | --- |
| `direct` | supported | Direct TCP connect. |
| `reject` | supported | Fails connection intentionally. |
| `ss` | supported subset | Classic AEAD TCP and mixed SOCKS5 UDP ASSOCIATE: `aes-128-gcm`, `aes-256-gcm`, `chacha20-poly1305`, `chacha20-ietf-poly1305`; TCP may be plain or use the exact built-in simple-obfs HTTP shape documented below. |
| `vmess` | unsupported | v1.0 capability gate hard rejects it；现有代码未通过标准 wire/互操作验证。 |
| `trojan` | supported subset | TLS + CONNECT（TCP）；支持 `password`/`server`/`port`/`sni`/`skip-cert-verify`。`udp:true` 与其他 transport 被拒绝；`skip-cert-verify:true` 产生安全告警。已知限制（M1/M5）见下文。 |
| `vless` | unsupported | v1.0 capability gate hard rejects it；响应 framing 与 transport 尚未通过互操作门禁。 |
| `anytls` | unsupported | v1.0 capability gate hard rejects it；保留实现和设计文档不构成支持声明，生命周期与资源上界门禁尚未关闭。 |
| `http` | unsupported | Outbound connect 未实现；配置准入阶段拒绝。 |
| `socks5` | unsupported | Outbound connect 未实现；配置准入阶段拒绝。 |

### Shadowsocks simple-obfs HTTP boundary

The only enabled Shadowsocks plugin transport is:

```yaml
plugin: obfs # or obfs-local
plugin-opts: # plugin_opts map is accepted and canonicalized to this spelling
  mode: http
  host: cdn.example.com
```

`mode` and `host` must both be explicit. `host` is 1..255 bytes and may not contain CR, LF, or NUL. Managed config rejects malformed/non-map options and conflicting aliases; dump/override output uses the canonical `plugin-opts` map. SIP003 scalar option strings are intentionally not accepted in this release.

simple-obfs `tls`, unknown modes, plugins other than `obfs`/`obfs-local`, missing options/host, and derived plugin fields without the matching plugin declaration fail closed in validator/doctor. Validator, catalog capture, complete manager admission, and the selected-proxy gate all consume one allocation-free runtime capability classifier; it also owns standalone `port`/`socks-port`, reserved declarations, disabled proxy/group types, non-SS plugin metadata, SS cipher/TLS/WebSocket, and Trojan UDP/WebSocket decisions. `OutboundManager.initWithKey` completes that full gate before its first manager allocation, then builds borrowed-key proxy and group hash indexes with complete failure cleanup. TCP/UDP admission is independent of configured proxy/group counts: each resolved group layer and the final proxy use fixed hash lookups, while literal `DIRECT`/`REJECT` performs no config-table lookup. The selected concrete proxy still receives one focused classifier gate before private-target bypass or dial；UDP 另要求该 Shadowsocks leaf 显式 `udp:true` 并通过同一 cipher/字段 preflight。zc never launches an external plugin and never downgrades such a node to plain Shadowsocks. simple-obfs support remains TCP/HTTP only；UDP 绕过 plugin，直接使用该节点的 server host/port。

Catalog recovery uses a separate strict-YAML raw-capture path: duplicate keys still fail, but explicitly marked malformed or unsupported Shadowsocks simple-obfs metadata can be retained byte-for-byte as an inactive recovery revision. `config download` uses the same bounded recovery rule: a malformed first download without `-d` succeeds but remains inactive, so only the first later **runtime-ready** managed config auto-activates. The exemption applies only to the marked SS plugin-semantic finding: SS TLS/cipher/WebSocket findings and Trojan/other proxy findings remain errors. It also does not bypass offline validation of reserved names, proxy/group types, basic fields, rules/references, or providers; non-Shadowsocks plugin metadata is rejected. A retained revision can be listed, inspected, updated, or deleted, but `config download -d`, an active replacement update, and `config use` return `CONFIG_CAPABILITY_UNSUPPORTED` rather than changing the active identity. It cannot run or produce a frozen override until its effective config validates; after repairing an inactive revision through `config update`, activate it explicitly with `config use`. Runtime `config.load` and `parseDocument` remain strict.

User-declared proxy names `DIRECT` and `REJECT` are reserved and rejected before outbound allocation or dial. The same exact tokens remain valid as built-in literals in rules and proxy-group member lists.

### Trojan 已知限制

- **M1（TLS 截断暴露）**：Trojan 隧道承载*无帧*字节流，`read()` 在字节层面无法区分恶意的链路中途截断（攻击者注入 FIN/RST）与正常关闭——两者都呈现为干净的 0 长度 EOF。这是刻意权衡（`allow_truncation_attacks = true`），以容忍良性的 record 中途丢弃（brew 下载截断场景）。异常关闭不会被静默吞掉：底层 `TlsConnectionTruncated` 仍可经 `lastReadError()` / `ProxyStream.lastTlsReadError()` 观测，中继日志据此打点。对比 anytls 的有帧模型可拒绝过短的末帧，无帧的 Trojan 隧道在结构上做不到。
- **M5（阻塞读限制）**：中继按 `POLL.IN` 轮询 Trojan 句柄，但 poll 只保证至少一字节*密文*就绪；单个 TLS record 可能跨多个 TCP 段，故 poll-ready 的 `read()` 仍可能阻塞到整条 in-flight record 到齐，期间另一方向（client→target）短暂停顿。非阻塞改写受 AGENTS.md 性能门禁约束，暂按现状记录。

### AnyTLS 保留实现说明（v1.0 未启用）

以下内容只记录保留实现的技术边界，不代表 v1.0 支持。重新启用 AnyTLS 前必须先关闭生命周期、buffer/backpressure、OOM teardown 与真实互操作门禁。

保留实现使用 Zig 标准库的 `std.crypto.tls`（仅客户端 TLS 1.3）。以下能力受该 TLS 栈限制，**不支持**：

- **uTLS / ClientHello 指纹模拟**：std TLS 发送固定的 ClientHello，无法模拟 Chrome 等浏览器指纹。
- **ALPN 配置**：`std.crypto.tls.Client.Options` 无 alpn 字段，ClientHello 不发 ALPN 扩展。
- **TLS 版本控制**：std 仅 TLS 1.3，无 min/max 版本旋钮。
- **mTLS / 客户端证书**：std 客户端无客户端证书路径（且 AnyTLS 用 SHA-256 密码帧认证，本就不属于其协议）。
- **Reality**：不属于 AnyTLS，且需要 std TLS 没有的自定义 X25519/伪造证书握手。

### Shadowsocks classic AEAD UDP boundary

仅 mixed ingress 支持 SOCKS5 `UDP ASSOCIATE`（CMD=0x03）。配置中不存在任何 `ss + udp:true` leaf 时，命令在 association/socket allocation 前返回 `REP=0x07`；存在 UDP leaf 后，成功 reply 的 IPv4 endpoint 是客户端唯一应使用的 relay。association 绑定 TCP control peer IP，首个完全合法且同 IP 的 UDP 数据报锁定 source port；control close 立即清理，另有 300 秒 awake-clock idle 和全局 64 association 上限。第 65 个 association 返回 general failure，不会挤出已有 association。

每个 classic 2017 AEAD UDP 包独立使用 CSPRNG salt、HKDF-SHA1 `ss-subkey`、全零 nonce、空 AAD 与 `ATYP|ADDR|PORT|DATA` plaintext；不复用 TCP chunk framing。单个 SOCKS 或 Shadowsocks wire datagram 上限均为 65507 bytes，长度按实际 cipher/address checked。坏 tag、截短 salt/tag、非零 RSV/FRAG、坏 ATYP/长度和超限包均按 packet 静默丢弃；不做 fragmentation/reassembly 或应用层 datagram queue。首个合法目标只解析一次规则/组选择；DIRECT、group→DIRECT、REJECT、Trojan 或未声明 `udp:true` 的 leaf 都 teardown，绝不 fallback。

支持 AES-128-GCM、AES-256-GCM 与 ChaCha20-IETF-Poly1305；`chacha20-poly1305` 是同一 wire 的配置 alias。simple-obfs/SIP003 仍仅包装 TCP，UDP 直接发送到同一 Shadowsocks server UDP endpoint。AEAD-2022、standalone `socks-port` UDP、Trojan/AnyTLS UDP 与 fragmentation 不在 v1.0 范围。

## Proxy groups

The compatibility parser recognizes `select`, `url-test`, `fallback`, `load-balance`, and `relay`, but **zc v1.0 runtime supports only `select`**. `url-test`, `fallback`, `load-balance`, and `relay` return `UnsupportedProxyGroupType` during the allocation-free manager initialization gate. Public selection/control-plane operations may repeat that bounded complete validation; TCP/UDP connection paths rely on the opaque handle's admitted immutable borrow and the prebuilt group index, so admission cost depends on resolution depth rather than configured group count. Runtime mutation of a borrowed group is unsupported.

运行时选择优先使用持久化的用户选择；没有持久化选择时，合法的 `select` 组使用第一个组成员作为默认节点。TCP 与 UDP 共用同一个嵌套组解析器：每个实际组层级只做一次预建 hash-index 查询，并允许最多 **1024 个唯一组层级**。`DIRECT` 与 `REJECT` 是立即终止解析的合法 select 成员；非组名称继续交给最终 proxy index，因此未知名称仍返回 `ProxyNotFound`。重复层级返回明确的 `ProxyGroupResolutionCycle`；若在唯一层级上界后仍可命中另一组，防御性地返回 `ProxyGroupResolutionLimit`，不会静默截断、误报 `ProxyNotFound` 或无限循环。`zc status` 和 `zc test` 会显示同一套节点信息，JSON 字段为 `selected_proxies`；`zc test --json` 还会通过 `daemon_state` 报告本机 daemon 状态。不要在没有场景测试证明前假设完整 mihomo 策略一致性。

## Rules

Parsed rule types:

- `DOMAIN`
- `DOMAIN-SUFFIX`
- `DOMAIN-KEYWORD`
- `IP-CIDR`
- `IP-CIDR6`
- `GEOIP`
- `RULE-SET`
- `SRC-IP-CIDR`
- `DST-PORT`
- `SRC-PORT`
- `PROCESS-NAME`
- `MATCH`

`REJECT` 是终态策略：即使目标是 loopback、链路本地或私网地址，也不会被内部直连保护逻辑改写为 `DIRECT`。此语义同样适用于直接命名的 reject 节点和解析到 reject 节点的代理组。

Known limitations:

- HTTP CONNECT/forward paths must still be checked for full `DST-PORT` context propagation before GA.
- `PROCESS-NAME`, `SRC-IP-CIDR`, and `SRC-PORT` depend on proxy context that is not always supplied.
- IPv6 GEOIP is not complete.

## API and dashboard compatibility

Implemented API endpoints are documented in [`../api/README.md`](../api/README.md).

Not supported in v1.0:

- full REST API v1 resource model;
- WebSocket event stream;
- third-party dashboard parity;
- built-in TUI.

Use CLI diagnostics instead — every zc command supports `--json` (single
`{"ok","command","data"|"error"}` envelope on stdout; see
[`../cli/spec.md`](../cli/spec.md)). The most useful ones:

```bash
zc status --json     # data.state / data.selected_proxies / data.paths
zc doctor --json     # data.proxy_reachable / data.checks
zc test --json       # data.daemon_state / data.checks
zc proxy list --json # data.groups (group type + current node)
zc log --json        # JSON Lines, one {"line":"..."} event per line
```

## Migrator rules

The config migrator contains rule checks for common compatibility issues. See [`migrator-rules-quickref.md`](migrator-rules-quickref.md).

Machine-readable migrator rule declarations for parity checks:

- `PORT_TYPE_INT`
- `LOG_LEVEL_ENUM`
- `PROXY_GROUP_TYPE_CHECK`
- `DNS_FIELD_CHECK`
- `DNS_NAMESERVER_FORMAT`
- `PROXY_GROUP_EMPTY_PROXIES`
- `TUN_ENABLE_CHECK`
- `EXTERNAL_CONTROLLER_FORMAT`
- `ALLOW_LAN_BIND_CONFLICT`
- `RULE_PROVIDER_REF_CHECK`
- `PROXY_NODE_FIELDS_CHECK`
- `SS_CIPHER_ENUM_CHECK`
- `VMESS_UUID_FORMAT_CHECK`
- `MIXED_PORT_CONFLICT_CHECK`
- `MODE_ENUM_CHECK`
- `PROXY_NAME_UNIQUENESS_CHECK`
- `PORT_RANGE_CHECK`
- `SS_PROTOCOL_CHECK`
- `VMESS_ALTERID_RANGE_CHECK`
- `TROJAN_FIELDS_CHECK`
- `RULES_FORMAT_CHECK`
- `VLESS_FIELDS_CHECK`
- `PROXY_GROUP_REF_CHECK`
- `YAML_SYNTAX_CHECK`
- `SUBSCRIPTION_URL_CHECK`
- `WS_OPTS_FORMAT_CHECK`
- `TLS_SNI_CHECK`
- `UNSUPPORTED_PROXY_TYPE_CHECK`
- `PORT_CONFLICT_CHECK`

Before GA, migrator/docs/validator must agree on unsupported proxy types and DNS/TUN limitations.
