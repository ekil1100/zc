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
- managed revisions use captured local `rule-providers`; remote providers that remain unresolved at exact-load time fail before listener startup rather than falling back to cwd/source paths;
- `external-controller` is restricted to an explicit `127.0.0.1:<port>` endpoint；端口冲突时启动失败，不自动漂移或静默关闭控制面；
- TUN/fake-ip/enhanced-mode are not supported;
- both legacy and managed YAML parsing reject nesting deeper than 128 levels;
- managed/offline configs without `MATCH` receive an implicit terminal `MATCH,REJECT`; duplicate or non-terminal `MATCH` entries are rejected. A legacy config with no `rules` field retains its historical `MATCH,DIRECT`; any present, well-formed ruleset without `MATCH` receives `MATCH,REJECT`, while malformed rule values are rejected;
- rules use declaration-order first-match semantics across rule types. Domain matching is ASCII case-insensitive and ignores a final root dot. Domain targets reaching `IP-CIDR`, `IP-CIDR6`, or `GEOIP` use the system resolver and a bounded 256-entry process cache;
- the mixed listener admits at most 128 concurrent connection workers. Initial HTTP/SOCKS negotiation has one 5-second monotonic deadline; excess or stalled handshakes are closed without terminating the daemon.

## Proxy support

Runtime outbound support currently includes:

| Type | v1.0 status | Notes |
| --- | --- | --- |
| `direct` | supported | Direct TCP connect. |
| `reject` | supported | Fails connection intentionally. |
| `ss` | partially supported | AEAD ciphers: `aes-128-gcm`, `aes-256-gcm`, `chacha20-poly1305`, `chacha20-ietf-poly1305`. Plugins/transports are rejected before bind/dial. |
| `vmess` | unsupported | v1.0 capability gate hard rejects it；现有代码未通过标准 wire/互操作验证。 |
| `trojan` | supported subset | TLS + CONNECT（TCP）；支持 `password`/`server`/`port`/`sni`/`skip-cert-verify`。`udp:true` 与其他 transport 被拒绝；`skip-cert-verify:true` 产生安全告警。已知限制（M1/M5）见下文。 |
| `vless` | unsupported | v1.0 capability gate hard rejects it；响应 framing 与 transport 尚未通过互操作门禁。 |
| `anytls` | unsupported | v1.0 capability gate hard rejects it；保留实现和设计文档不构成支持声明，生命周期与资源上界门禁尚未关闭。 |
| `http` | unsupported | Outbound connect 未实现；配置准入阶段拒绝。 |
| `socks5` | unsupported | Outbound connect 未实现；配置准入阶段拒绝。 |

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

其它行为说明：UDP 中继按“首包目标匹配路由规则”选代理（一次 ASSOCIATE 一条 UoT 流一个代理，IsConnect=0 非连接模式）；客户端侧 UDP socket 仅 IPv4（UoT 承载的目标可为 IPv6）；FRAG≠0 的 SOCKS5 UDP 数据报丢弃（不重组）。

## Proxy groups

Parsed group types:

- `select`
- `url-test`
- `fallback`
- `load-balance`
- `relay`

运行时选择优先使用持久化的用户选择；没有持久化选择时，select 组使用第一个组成员作为默认节点。`zc status` 和 `zc test` 会显示同一套节点信息，JSON 字段为 `selected_proxies`；`zc test --json` 还会通过 `daemon_state` 报告本机 daemon 状态。不要在没有场景测试证明前假设完整 mihomo 策略一致性。

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
