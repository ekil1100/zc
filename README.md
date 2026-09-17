<p align="center">
  <img src="docs/assets/zc-mark-transparent.png" width="176" alt="zc project mark">
</p>

<h1 align="center">zc</h1>

<p align="center">
  一个面向 mihomo/clash 配置生态的 CLI-first Rust 代理运行时。
</p>

## Rust 候选版本

当前开发与交付入口使用 Rust `1.0.1`：完整 CLI、托管 revision、daemon、minimal API、mixed TCP 与受限 UDP 已接入。**实现覆盖不等于迁移验收完成**；四平台、性能、长稳和最终回归状态见 [迁移说明](docs/migration/rust.md)。原 Zig 文件暂留作行为对照，不参与默认构建或运行时回退。

```bash
just build                   # target/debug/zc
just run                     # Foreground, example config, port 17890
```

## 安装

已发布版本使用 [安装指南](docs/install/README.md) 中的独立安装器或 Homebrew。安装器消费实际 GitHub Release，不代表当前工作区的候选版本已经发布。迁移验收前不要覆盖生产安装或删除已有状态目录。

## 开发与验证

Rust 最低 `1.91`，CI 固定 `1.98.1`；原生依赖需要 C/C++ 工具链与 CMake，E2E 需要 Python 3、Node.js 和 [`just`](https://github.com/casey/just)。生产目标为 Linux/macOS × x64/arm64，不支持 Windows。

```bash
just build
just release                 # target/release/zc; no installation
just check                   # Formatting check + Clippy
just test
just delivery-test
just e2e                     # Unchanged core harness + independent TCP interoperability
just install-test            # Temporary-directory installer regressions
just validate                # check, test, delivery, E2E, installer, release build
just eval-selfcheck
just eval correctness
just -- eval all --with-interop
just migrator-test
just run path/to/config.yaml 17891
just -- test --test cli
```

`just` 列出全部任务；`just fmt` 会格式化 Rust 源码。默认任务纯 Rust；临时 `zig-*` 任务只供历史对照，不能代替候选版本验收。没有自动停启 daemon 的 `just install`。

生产默认 mixed 端口为 **7899**；配置中的 `mixed-port` 数值不覆盖它。开发必须显式传 `--port` 或使用 `just run`（默认 `17890`，拒绝 `7899`）。端口冲突只报错，不漂移。测试使用临时 HOME/runtime，不读写真实用户状态。

## 与 mihomo 的功能对比

下表描述 Rust 候选实现，不是最终验收声明。未支持的出站协议与代理组会在启动或连接前明确拒绝；仅为配置兼容而接受的字段会单独注明 ignored 或上下文限制。

### 入站与运行模式

| 功能 | zc | 与 mihomo 的差异 |
| --- | --- | --- |
| Mixed HTTP/SOCKS5 入站 | ⚠️ 部分实现 | 只有一个 mixed listener；无 `--port` 时固定绑定 `7899`，配置中的 `mixed-port` 数值仅兼容解析。 |
| SOCKS5 UDP ASSOCIATE | ✅ 已实现 | 用于 `udp: true` 的 Shadowsocks classic AEAD 或原生 TLS Trojan 节点。 |
| 独立 HTTP `port` | ❌ 未实现 | 与 `mixed-port` 声明共存时仅作为兼容声明忽略；不能单独启动。 |
| 独立 `socks-port` | ❌ 未实现 | 与 `mixed-port` 声明共存时仅作为兼容声明忽略；不能单独启动。 |
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
| Trojan UDP | ✅ 已实现 | `udp:true` 经 mixed SOCKS5 UDP ASSOCIATE；TLS stream framing，支持 IPv4/domain/IPv6。 |
| Trojan WebSocket / gRPC | ❌ 未实现 | 仅支持原生 TCP/TLS transport。 |
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
| `IP-CIDR` / `IP-CIDR6` | ✅ 已实现 | 域名目标使用读取系统配置的 Hickory 异步 resolver。 |
| `RULE-SET` | ✅ 已实现 | 本地 provider 可捕获到托管 revision；unmanaged HTTP provider 可真实下载后展开。 |
| `MATCH` | ✅ 已实现 | 作为终态规则。 |
| `GEOIP` | ⚠️ 部分实现 | IPv6 GEOIP 不完整。 |
| `DST-PORT` | ✅ 已实现 | mixed HTTP/SOCKS5 使用目标端口，支持范围匹配。 |
| `SRC-IP-CIDR` / `SRC-PORT` / `PROCESS-NAME` | ⚠️ 部分实现 | mixed 提供来源 IP/端口，不提供进程名；不能宣称进程规则运行时可用。 |
| Remote `RULE-SET` 完整兼容 | ❌ 未实现 | 托管 revision 不允许引用尚未捕获的 remote provider。 |
| `proxy-providers` | ❌ 未实现 | 不解析为运行时代理节点。 |
| mihomo 的其他规则类型 | ❌ 未实现 | 未列出的规则不作为已支持能力。 |

### DNS

| 功能 | zc | 与 mihomo 的差异 |
| --- | --- | --- |
| 规则匹配所需的域名解析 | ✅ 已实现 | Hickory 读取系统 DNS/hosts，具有 deadline、并发与缓存配置上界；不等价于 libc/NSS。 |
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

内置 `DIRECT`/`REJECT` 字面量可用；用户命名的 `type: direct/reject` 节点仍待补齐，不能据此表宣称已迁移。

详细边界见 [`docs/compat/mihomo-clash.md`](docs/compat/mihomo-clash.md)，实际 API 见 [`docs/api/README.md`](docs/api/README.md)。
