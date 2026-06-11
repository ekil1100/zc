# zc mihomo/clash compatibility boundaries

This document describes compatibility based on current code, not aspirational roadmap items.

## Summary

zc v1.0 targets a practical subset:

- explicit HTTP/SOCKS/mixed inbound, with runtime defaulting to mixed;
- static proxy nodes and proxy groups;
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
- TUN/fake-ip/enhanced-mode are not supported.

## Proxy support

Runtime outbound support currently includes:

| Type | v1.0 status | Notes |
| --- | --- | --- |
| `direct` | supported | Direct TCP connect. |
| `reject` | supported | Fails connection intentionally. |
| `ss` | partially supported | AEAD ciphers: `aes-128-gcm`, `aes-256-gcm`, `chacha20-poly1305`, `chacha20-ietf-poly1305`. |
| `vmess` | minimal | TCP-only style implementation; transport options are not fully wired. |
| `trojan` | minimal | TLS + CONNECT style implementation. |
| `vless` | minimal | TCP-only implementation. |
| `anytls` | minimal | 基于 TLS 的 TCP stream 支持。已接入 `password`、`server`、`port`、`sni`、`skip-cert-verify`；暂不支持 UDP-over-TCP 和 Reality。 |
| `http` | blocker | Parser accepts it, but outbound connect is not implemented yet. Must be implemented or rejected before GA. |
| `socks5` | blocker | Parser accepts it, but outbound connect is not implemented yet. Must be implemented or rejected before GA. |

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
