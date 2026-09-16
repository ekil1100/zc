# Rust 迁移

## 当前阶段：TCP 端到端首版

迁移以已发布 Zig 版的行为为参考，不逐文件翻译，也不同时扩展 mihomo 全功能。
根目录 Cargo 工程与 Zig 工程暂时共存；Rust 首版不是现有生产二进制的替代品。
现有 installer、daemon 与托管状态仍由 Zig 版维护，迁移期间不改写已有用户数据。

### 验收标准

测试通过以下公开接口进行：CLI、配置解析与路由、TCP 出站、mixed HTTP/SOCKS5 wire。

- `cargo build --locked` 与 `cargo test --locked` 可运行。
- 使用显式配置、显式非生产端口、`--foreground` 启动；不访问托管目录。
- 配置先验证，随后绑定唯一指定端口；端口冲突报错，不自动换端口。
- HTTP CONNECT、HTTP absolute-form forward 和 SOCKS5 CONNECT 可传递真实 TCP payload。
- DIRECT/REJECT、classic AEAD Shadowsocks、原生 TLS Trojan TCP 可用。
- 规则按声明顺序 first-match；select 组确定性选择首成员并支持嵌套，未知引用与循环拒绝。
- TLS 默认验证证书；只在明确 `skip-cert-verify: true` 时关闭身份验证。
- 未支持的协议、transport、UDP、plugin 与运行能力显式拒绝，不回退 DIRECT。
- 握手、建连、连接数量和协议头有界；双向转发保留 TCP half-close；退出回收连接任务。
- 独立 Shadowsocks/Trojan 服务端验证协议互操作；测试只能绑定临时端口，不使用 `7899`。

### 使用与验证

```bash
just build
just run
# Use Ctrl-C or SIGTERM to stop the foreground process.

just test
just check
just e2e
just validate
```

`Justfile` 默认面向 Rust：`build` / `release` 构建 debug / release 二进制，
`fmt` 格式化，`check` 检查格式与 Clippy，`validate` 顺序执行 check、test、e2e。
`just run` 使用 `testdata/config/rust-tcp.yaml`、端口 `17890` 和前台模式；
`just run <config> <port>` 可覆盖配置与端口，但拒绝生产端口 `7899`。
带选项的 Cargo 参数可使用 `just -- test --test cli` 传递。
Zig 基线使用独立的 `zig-*` 命令；不保留旧 `rust-*` 别名，不提供自动安装命令。

示例配置默认 DIRECT。真实节点可以声明为：

```yaml
proxies:
  - name: ss
    type: ss
    server: your-ss.example
    port: 443
    password: change-me
    cipher: aes-128-gcm
  - name: trojan
    type: trojan
    server: your-trojan.example
    port: 443
    password: change-me
    sni: your-trojan.example
proxy-groups:
  - name: selected
    type: select
    proxies: [ss, trojan]
rules:
  - DOMAIN,blocked.invalid,REJECT
  - MATCH,selected
```

`selected` 固定选择首成员，不代表已经提供交互或持久选择。SS cipher 另支持
`aes-256-gcm`、`chacha20-ietf-poly1305` 和 `chacha20-poly1305` 别名。
Trojan 默认验证系统信任链与 SNI，IP server 必须配置 DNS SNI；仅显式
`skip-cert-verify: true` 关闭身份校验，握手签名仍验证。

CLI 仅提供 help/version 与 `start`；`-c/--config`、`--port`、`--foreground`
均必填，端口不得为 0。参数错误退出 2，运行错误退出 1；诊断与监听地址写 stderr。
`mixed-port` 仅兼容解析，不能覆盖 CLI 端口。默认绑定 loopback；非 loopback
地址必须显式 `allow-lan: true`，首版没有入站认证，不应直接暴露到不可信网络。

`cargo test` 不下载或依赖外部服务；连接容量测试需要文件描述符上限至少 4096，
`just test` 与 CI 使用 8192。`just e2e` 复用 SHA-256 校验的固定
`shadowsocks-rust v1.24.0`、`trojan-go v0.10.6` 服务端，要求本机 IPv4/IPv6。
通过真实 Rust CLI 验证独立服务端双向 payload、域名/IPv4/IPv6、server-first、
HTTP forward、错误密码、TLS 信任/SNI 负路径和无 DIRECT 回退；缺少 fixture 或
网络前提就失败，不跳过。测试仅使用临时 HOME、runtime directory 和端口。

### 精确兼容范围与限制

- HTTP CONNECT 与 SOCKS5 CONNECT 是双向 TCP tunnel；SOCKS5 不提供认证或 UDP。
- HTTP forward 每连接仅转发一条 `http://` 请求，强制 `Connection: close`，支持
  最多 16 MiB 的 Content-Length body；拒绝 chunked、Expect、Upgrade、歧义
  framing、冲突 Host 和 HTTPS absolute-form。HTTPS 使用 CONNECT。
- HTTP forward 的 request 完成不提前发送 FIN/TLS close_notify，避免 trojan-go
  在响应到达前结束双向转发；TCP tunnel 保留原有 half-close。
- 支持 DOMAIN、DOMAIN-SUFFIX、DOMAIN-KEYWORD、IP-CIDR、IP-CIDR6、DST-PORT
  和 MATCH，IP 规则支持 `no-resolve`；无规则匹配就拒绝，不默认 DIRECT。
- IP 路由命中后固定获准 IP；后续 DIRECT/SS/Trojan 都使用同一地址，不重新解析，
  不尝试其他未获准地址。若为前置 IP 规则做过解析，后续规则也使用该解析快照。
- Hickory 读取系统 DNS 配置与 hosts，A/AAAA 结果 IPv4 优先；并不等价于 libc/NSS、
  mDNS 或完整 split-DNS。配置/hosts 不自动重载，无 nameserver 时拒绝，不回退公共 DNS。
- DNS lookup 最多 2 秒、保留最多 64 地址；并行 A/AAAA 每次占 2 个 query slot，
  共 64 slots，取消释放。缓存容量配置为 64，但不是瞬时硬内存上限。
  不调用阻塞式 getaddrinfo，停止进程不等待阻塞 DNS 网络线程。
- listener 最多 1024 个连接任务；入站握手 10 秒、路由与出站建立合计另限 10 秒，
  转发按双向活动更新 15 分钟空闲期限。Ctrl-C/SIGTERM 取消并回收连接任务，不承诺 drain 完存量流量。
- YAML 最多 16 MiB、嵌套 16 层，parser events/nodes 各最多 6000000、scalar
  总字节最多 16 MiB；proxies 4096、groups 1024、每组 members 5122、rules 262144。
  拒绝 duplicate keys、anchors/aliases、merge keys 和未知字段。这与 Zig 的全局
  collection-entry 预算并不相同，不能视为资源契约已完全对齐。
- `log-level` 仅接受合法兼容声明，当前不改变日志等级。配置错误保留无凭据的操作提示，
  不回显 YAML source。配置必须是普通文件；Unix 以 nonblocking open 防止被替换成 FIFO 后卡住。
- 这是较严格的 YAML 子集；现有订阅的 `udp: true`、plugin、controller、DNS、provider、
  独立 listener 等字段需要后续实现，当前拒绝而非忽略。

### 本阶段不包含

- daemon 生命周期、status/reload/restart、托管配置与持久代理选择；
- minimal REST API、JSON CLI 契约；
- UDP、simple-obfs、WebSocket/gRPC、VMess/VLESS/AnyTLS；
- rule-provider、proxy-provider、GEOIP、进程规则、完整 DNS；
- 生产发布切换或性能等价承诺。

这些内容必须在后续阶段分别达到行为与回归要求后才能启用。
旧状态格式的接管与迁移策略须在修改现有数据前明确。

## 依赖选择

- Tokio：异步 socket、超时与任务生命周期。
- rustls / tokio-rustls：TLS；使用系统信任根，不迁移 Zig 的 TLS 派生实现。
- shadowsocks-rust 的 `shadowsocks` crate：classic AEAD TCP，不自行重写加密协议。
- serde / serde-saphyr：有资源预算的 YAML 解析，不使用已停止维护的 serde_yaml。
- clap：显式、可操作的命令行参数校验。
- Hickory：有并发与 deadline 限制的异步 DNS；避免 getaddrinfo 不能取消导致退出阻塞。

Rust 最低工具链声明为 1.91，当前本地验证使用 1.98.1；Zig 基线仍要求 0.16.0。

## 验证状态

本地 macOS arm64 已通过 Rust 测试和独立 SS/Trojan CLI 互操作。新增 Rust CI
覆盖 Linux/macOS × amd64/arm64；远端 CI 尚待运行，不能视为四平台已经验收。
未验证 Release 性能、长稳或与 Zig 数据面的吞吐/内存等价；默认 Just 开发命令已切换 Rust，安装与发布仍保持 Zig 基线。

## 后续顺序

1. 收敛本阶段兼容性、错误路径、互操作与吞吐/内存对照。
2. 迁移托管配置、revision 与持久选择，明确旧数据接管要求。
3. 迁移 daemon 与 minimal API，再迁移 UDP、simple-obfs 等已支持能力。
4. 完成四平台发布与回归验收后切换安装与发布入口，移除 Zig 生产实现。
