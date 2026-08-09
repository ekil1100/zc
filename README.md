<p align="center">
  <img src="docs/assets/zc-mark-transparent.png" width="176" alt="zc project mark">
</p>

<h1 align="center">zc</h1>

<p align="center">
  一个面向 mihomo/clash 配置生态的 CLI-first Zig 代理运行时。
</p>

## 安装

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/ekil1100/zc/main/install.sh | sh
export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
zc --version
```

## 与 mihomo 的功能对比

表格区分完整实现、部分实现和未实现能力。未支持的出站协议与代理组会在启动或连接前明确拒绝；仅为配置兼容而接受的字段会单独注明 ignored 或上下文限制。

### 入站与运行模式

| 功能 | zc | 与 mihomo 的差异 |
| --- | --- | --- |
| Mixed HTTP/SOCKS5 入站 | ⚠️ 部分实现 | 只有一个 mixed listener；无 `--port` 时固定绑定 `7899`，配置中的 `mixed-port` 数值仅兼容解析。 |
| SOCKS5 UDP ASSOCIATE | ✅ 已实现 | 仅用于 `udp: true` 的 Shadowsocks classic AEAD 节点。 |
| 独立 HTTP `port` | ❌ 未实现 | 与非零 `mixed-port` 共存时仅作为兼容声明忽略；不能单独启动。 |
| 独立 `socks-port` | ❌ 未实现 | 与非零 `mixed-port` 共存时仅作为兼容声明忽略；不能单独启动。 |
| TUN | ❌ 未实现 | 不创建 TUN 设备。 |
| Redir / TProxy | ❌ 未实现 | `redir-port`、`tproxy-port` 不会创建 listener。 |

### 出站协议

| 协议或能力 | zc | 实现边界 |
| --- | --- | --- |
| DIRECT | ✅ 已实现 | TCP 直连。 |
| REJECT | ✅ 已实现 | 终止连接，不会因目标是私网或 loopback 而改写为 DIRECT。 |
| Shadowsocks classic AEAD TCP | ✅ 已实现 | `aes-128-gcm`、`aes-256-gcm`、`chacha20-poly1305`、`chacha20-ietf-poly1305`。 |
| Shadowsocks classic AEAD UDP | ✅ 已实现 | 仅经 mixed SOCKS5 UDP ASSOCIATE；不支持分片。 |
| Shadowsocks simple-obfs HTTP | ✅ 已实现 | 仅 `obfs` / `obfs-local` 的 HTTP 模式，且只包装 TCP。 |
| Shadowsocks AEAD-2022 | ❌ 未实现 | 配置准入阶段拒绝。 |
| Shadowsocks 通用 SIP003 外部插件 | ❌ 未实现 | 不启动外部 plugin；simple-obfs TLS 也不支持。 |
| Trojan TCP/TLS | ✅ 已实现 | 支持 `password`、`server`、`port`、`sni`、`skip-cert-verify`。 |
| Trojan UDP / WebSocket / gRPC | ❌ 未实现 | 仅支持 TCP/TLS CONNECT。 |
| HTTP outbound | ❌ 未实现 | 配置准入阶段拒绝。 |
| SOCKS5 outbound | ❌ 未实现 | 配置准入阶段拒绝。 |
| VMess | ❌ 未实现 | 未通过标准 wire 与互操作验证。 |
| VLESS | ❌ 未实现 | 未完成主流 transport 与互操作验证。 |
| AnyTLS | ❌ 未实现 | 保留代码不构成运行时支持。 |
| mihomo 的其他 outbound 协议 | ❌ 未实现 | 未列出的协议均不作为已支持能力。 |

### 代理组

| 功能 | zc | 与 mihomo 的差异 |
| --- | --- | --- |
| `select` | ✅ 已实现 | 支持持久选择、嵌套组、DIRECT/REJECT 成员与循环检测。 |
| `url-test` | ❌ 未实现 | parser 可识别，运行时准入拒绝。 |
| `fallback` | ❌ 未实现 | parser 可识别，运行时准入拒绝。 |
| `load-balance` | ❌ 未实现 | parser 可识别，运行时准入拒绝。 |
| `relay` | ❌ 未实现 | parser 可识别，运行时准入拒绝。 |

### 规则与 Provider

| 功能 | zc | 实现边界 |
| --- | --- | --- |
| `DOMAIN` / `DOMAIN-SUFFIX` / `DOMAIN-KEYWORD` | ✅ 已实现 | 按声明顺序 first-match。 |
| `IP-CIDR` / `IP-CIDR6` | ✅ 已实现 | 域名目标使用系统 resolver。 |
| `RULE-SET` | ✅ 已实现 | 支持本地、被托管配置捕获的 rule-provider 展开。 |
| `MATCH` | ✅ 已实现 | 作为终态规则。 |
| `GEOIP` | ⚠️ 部分实现 | IPv6 GEOIP 不完整。 |
| `DST-PORT` | ⚠️ 部分实现 | mixed HTTP CONNECT/forward 的完整上下文仍有限制。 |
| `SRC-IP-CIDR` / `SRC-PORT` / `PROCESS-NAME` | ⚠️ 部分实现 | parser 已接入，但部分入站路径不会提供完整匹配上下文。 |
| Remote `RULE-SET` 完整兼容 | ❌ 未实现 | 托管 revision 不允许引用尚未捕获的 remote provider。 |
| `proxy-providers` | ❌ 未实现 | 不解析为运行时代理节点。 |
| mihomo 的其他规则类型 | ❌ 未实现 | 未列出的规则不作为已支持能力。 |

### DNS

| 功能 | zc | 与 mihomo 的差异 |
| --- | --- | --- |
| 规则匹配所需的域名解析 | ✅ 已实现 | 使用系统 resolver 和有界进程缓存。 |
| `dns:` 运行时配置 | ❌ 未实现 | 未接入完整 DNS 配置模型。 |
| Fake IP | ❌ 未实现 | 不支持 fake-ip。 |
| `enhanced-mode` / `nameserver-policy` | ❌ 未实现 | 不提供 mihomo DNS 行为兼容。 |

### 配置与控制面

| 功能 | zc | 实现边界 |
| --- | --- | --- |
| Clash-style YAML 核心字段 | ✅ 已实现 | 支持 mixed 入口、静态 proxies、select groups、rules 与 local rule-providers。 |
| 托管配置 | ✅ 已实现 | 支持 load/download/update/use/delete/dump/override、immutable revision 与本地依赖捕获。 |
| 持久代理选择 | ✅ 已实现 | 选择与 exact config revision 绑定，daemon 启动前恢复。 |
| Daemon 生命周期 CLI | ✅ 已实现 | start/stop/restart/reload/status/log/test/doctor，支持结构化 JSON 输出。 |
| Minimal REST API | ✅ 已实现 | `/`、`/version`、`/proxies`、`/rules`、`/status`、`PUT /proxies/<group>`。 |
| mihomo 完整 Controller API | ❌ 未实现 | 没有 `/runtime`、`/profiles`、`/connections`、`/metrics` 等完整资源模型。 |
| WebSocket 事件流 | ❌ 未实现 | 不兼容依赖事件流的 dashboard。 |
| 第三方 dashboard 兼容 | ❌ 未实现 | minimal API 不等同于 mihomo Controller API。 |
| 内置 TUI | ❌ 未实现 | 产品表面仅提供 CLI 与 minimal API。 |

详细边界见 [`docs/compat/mihomo-clash.md`](docs/compat/mihomo-clash.md)，实际 API 见 [`docs/api/README.md`](docs/api/README.md)。
