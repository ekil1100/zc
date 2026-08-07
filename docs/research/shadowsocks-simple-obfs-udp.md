# Research: simple-obfs HTTP、capability gate 与 Shadowsocks AEAD UDP（2017）

## Summary

zc 应只实现 **simple-obfs HTTP 客户端传输层**，接受 mihomo 风格 `plugin: obfs` 与 SIP003 风格 `plugin: obfs-local`，统一为 `mode: http`、`host: <伪装 Host>`；虽然上游 simple-obfs 确有 `tls` mode，但本次不应支持。UDP 应实现经典 Shadowsocks AEAD（SIP004/SIP007，本文称“2017 AEAD”）的独立数据报格式，并通过显式 `udp` capability gate 启用；simple-obfs/SIP003 只包装 TCP，UDP 仍直接发往 Shadowsocks 服务端 UDP 端口。

以下每项均标注 **[规范要求]**、**[成熟实现惯例]** 或 **[zc 设计建议]**。外部源码路径也写入结论，便于逐行核对。

## Findings

1. **配置语义与 capability gate（严重度：Blocker）**
   - **[规范要求]** SIP003 的客户端插件程序名/示例是 `obfs-local`，选项串是 `obfs=http;obfs-host=www.baidu.com`；插件是本地端口转发隧道，且 SIP003 明确“Only TCP traffic is forwarded”。因此 `obfs-host` 不是 Shadowsocks 服务端地址，而是混淆层生成的 HTTP `Host`（TLS mode 时为伪 ClientHello 的 SNI）；UDP 不得送入 simple-obfs TCP 流。[SIP003](https://shadowsocks.org/doc/sip003.html) [simple-obfs README](https://github.com/shadowsocks/simple-obfs/blob/master/README.md)
   - **[成熟实现惯例]** mihomo 在 `adapter/outbound/shadowsocks.go` 中只把 `plugin == "obfs"` 识别为内置 simple-obfs，并将 `plugin-opts.mode`/`host` 解码到 `simpleObfsOption`；默认 host 为 `bing.com`，mode 仅接受 `http` 或 `tls`。其 UDP capability 来自顶层 `udp` 布尔值：`ShadowSocksOption.UDP` 传入 `BaseOption.UDP`，`adapter/outbound/base.go::SupportUDP()` 原样返回它；HTTP/TLS obfs 只出现在 `StreamConnContext`，原生 UDP 走 `DialPacketConn`。[mihomo shadowsocks.go](https://github.com/MetaCubeX/mihomo/blob/Alpha/adapter/outbound/shadowsocks.go) [mihomo base.go](https://github.com/MetaCubeX/mihomo/blob/Alpha/adapter/outbound/base.go)
   - **[zc 设计建议]** 解析层接受且仅接受两种插件标识：`obfs`（mihomo YAML 语义）和 `obfs-local`（SIP003/SIP002 生态语义）；二者归一化为同一个内置 transport。对 map 配置使用 `mode`/`host`，对 SIP003 option string 将 `obfs`→`mode`、`obfs-host`→`host`。`mode` 必须显式为 `http`；`host` 必填、非空、拒绝 CR/LF/NUL，长度建议 ≤255 字节。不要默默使用 `bing.com`，因为 standalone CLI 的可诊断性优先。
   - **[zc 设计建议]** `udp` gate 应在三个边界一致：配置/API 中报告 capability；SOCKS5 收到 UDP ASSOCIATE 前检查；创建 UDP socket/association 前再次检查。只有 `udp: true` 且 cipher 属于已实现的 2017 AEAD 集合时才开放。gate 关闭时返回 SOCKS5 `REP=0x07`（command not supported），不得悄悄 DIRECT、不得分配 association。`plugin: obfs` 不应强制关闭 UDP，因为 UDP 绕过 SIP003，直接使用同一服务端 host:port 的 UDP。

2. **simple-obfs HTTP TCP wire/framing（严重度：Blocker）**
   - **[成熟实现惯例/事实上的互操作协议]** 官方 `src/obfs_http.c` 在客户端**第一次有 payload 的写入**前置：
     ```text
     <METHOD> <URI> HTTP/1.1\r\n
     Host: <host>[:<server-port-if-not-80>]\r\n
     User-Agent: curl/7.<random>.<random>\r\n
     Upgrade: websocket\r\n
     Connection: Upgrade\r\n
     Sec-WebSocket-Key: <base64(16 random bytes)>\r\n
     Content-Length: <first-payload-byte-count>\r\n
     \r\n
     <first Shadowsocks TCP bytes><all later bytes raw>
     ```
     默认 method/URI 由 simple-obfs 配置产生（通常 `GET /`）；服务端不按 HTTP body 或 Content-Length 继续分帧，而只剥离第一次 `\r\n\r\n`。第一次之后双向均为原始 Shadowsocks TCP 字节流。[simple-obfs `src/obfs_http.c`](https://github.com/shadowsocks/simple-obfs/blob/master/src/obfs_http.c)
   - **[成熟实现惯例]** 服务端第一次响应前置：
     ```text
     HTTP/1.1 101 Switching Protocols\r\n
     Server: nginx/1.<random>.<random>\r\n
     Date: <HTTP-date>\r\n
     Upgrade: websocket\r\n
     Connection: Upgrade\r\n
     Sec-WebSocket-Accept: <base64(16 random bytes)>\r\n
     \r\n
     <first Shadowsocks response bytes><all later bytes raw>
     ```
     这不是完整 WebSocket：没有 RFC WebSocket accept 计算、mask 或 frame；`Sec-WebSocket-Accept` 在官方源码中也是独立随机值。[simple-obfs `src/obfs_http.c`](https://github.com/shadowsocks/simple-obfs/blob/master/src/obfs_http.c)
   - **[规范边界]** TCP 无消息边界。请求/响应 header terminator 可能跨任意多次 read，terminator 后的 Shadowsocks 字节也可能与 header 同一次 read 到达。实现必须增量搜索 `\r\n\r\n`，在未完整前返回“需要更多”，完整后只消费 header 并保留同一缓冲区中的余留字节。官方 C `deobfs_http_header` 就是此语义；mihomo `transport/simple-obfs/http.go` 单次 Read 找不到 terminator 就返回 EOF，是不能照搬的脆弱点。[simple-obfs `src/obfs_http.c`](https://github.com/shadowsocks/simple-obfs/blob/master/src/obfs_http.c) [mihomo `transport/simple-obfs/http.go`](https://github.com/MetaCubeX/mihomo/blob/Alpha/transport/simple-obfs/http.go)
   - **[zc 设计建议]** transport 状态机仅需 `request_pending/request_raw` 与 `response_header/response_raw`。第一次空写不得发 header；第一次非空写应保证 header+payload 的短写语义正确（循环写或保留 pending buffer），对调用者只报告 payload 消费量。响应解析上限建议 8 KiB、握手首字节/完整 header deadline 建议 10 s；超限、EOF-before-terminator、非法 status line 均返回可操作错误。兼容时至少验证 `HTTP/1.1 101` 和完整 terminator；不要要求官方随机 `Sec-WebSocket-Accept` 与请求 key 对应。

3. **TLS mode 存在，但本次明确不支持（严重度：Major / scope control）**
   - **[事实]** simple-obfs README 和 man page 均声明 `http|tls`；官方 `src/obfs_tls.c` 实现的是伪 TLS 记录/ClientHello、SNI、session ticket 携带首段 payload，后续用 `17 03 03 <len>` 包装，并非真正 TLS。mihomo 也接受 `plugin: obfs` + `mode: tls`。[simple-obfs README](https://github.com/shadowsocks/simple-obfs/blob/master/README.md) [simple-obfs `src/obfs_tls.c`](https://github.com/shadowsocks/simple-obfs/blob/master/src/obfs_tls.c) [mihomo shadowsocks.go](https://github.com/MetaCubeX/mihomo/blob/Alpha/adapter/outbound/shadowsocks.go)
   - **[zc 设计建议]** 本次仅启用 HTTP；`mode: tls` 必须在配置加载时明确报错 `simple-obfs mode "tls" is not supported; supported: http`，不能回退到无混淆或误当真实 TLS。原因是 TLS mode 有完全不同的多阶段/记录 framing，扩大审计与互操作面，且 simple-obfs 官方项目已 deprecated。[simple-obfs README](https://github.com/shadowsocks/simple-obfs/blob/master/README.md)

4. **Shadowsocks AEAD UDP 2017 wire layout、密钥与 nonce（严重度：Blocker）**
   - **[规范要求]** 支持集合及参数：`aes-128-gcm` key/salt 16/16、`aes-256-gcm` 32/32、`chacha20-ietf-poly1305` 32/32；三者 nonce 12、tag 16。密码到 master key 沿用 OpenSSL `EVP_BytesToKey`；每包 subkey 为 `HKDF-SHA1(master_key, salt, "ss-subkey")`。[Shadowsocks AEAD spec](https://shadowsocks.org/doc/aead.html)
   - **[规范要求]** 每个 UDP 包独立：
     ```text
     wire = SALT || AEAD_ENCRYPT(subkey, nonce=00..00,
                                plaintext=ATYP||DST.ADDR||DST.PORT||DATA,
                                aad=empty) || TAG
     ```
     地址使用 SOCKS5 address encoding（IPv4、长度前缀 domain、IPv6；port 网络字节序）。响应 plaintext 同样以前缀地址开始，表示远端响应源。不得复用 TCP 的 length-chunk framing，也不得跨数据报递增 nonce。[Shadowsocks AEAD spec](https://shadowsocks.org/doc/aead.html) [shadowsocks-rust `udprelay/mod.rs`](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.23.5/crates/shadowsocks/src/relay/udprelay/mod.rs) [shadowsocks-rust `udprelay/aead.rs`](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.23.5/crates/shadowsocks/src/relay/udprelay/aead.rs)
   - **[规范要求]** salt 必须在 master key 整个生命周期内唯一；规范文字要求随机生成以确保唯一。zc 必须使用 OS CSPRNG，绝不能计时器、PRNG 或全零 salt。[Shadowsocks AEAD spec](https://shadowsocks.org/doc/aead.html)
   - **[重放要求的准确边界]** 协议的发送端 salt 唯一性是 MUST 级密码学要求；接收端历史缓存不属于 wire compatibility。shadowsocks-org #44 将 Bloom-filter 检测描述为防御建议且“does not change the protocol”，并建议成功认证后再查重；但 shadowsocks-rust v1.23.5 的经典 AEAD UDP 解密路径明确注释掉 `check_nonce_replay(salt)`。因此不能把有限窗口去重声称为 2017 UDP 互操作的规范 MUST。[shadowsocks-org #44](https://github.com/shadowsocks/shadowsocks-org/issues/44) [shadowsocks-rust `udprelay/aead.rs`](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.23.5/crates/shadowsocks/src/relay/udprelay/aead.rs)
   - **[zc 设计建议]** v1 最少保证 CSPRNG salt 和认证失败静默丢包；若加入接收端 replay cache，应只在 AEAD 验证成功后插入，采用有界双窗口/时间轮，指标化 replay/eviction/false-positive，并先做跨 NAT、重复 UDP 应用包测试。不要缓存未认证 salt（可被内存 DoS）。若当前实现只有客户端 outbound，则无需接收端全局 replay cache，因为响应来自可信配置的 server，且成熟 oracle 默认不做经典 AEAD UDP 查重。

5. **SOCKS5 UDP ASSOCIATE framing、FRAG 与生命周期（严重度：Blocker）**
   - **[规范要求]** TCP 控制连接经鉴权后发送 `VER=05 CMD=03 RSV=00 ATYP DST.ADDR DST.PORT`；未知本地 UDP endpoint 时请求必须用全零地址/端口。成功响应的 `BND.ADDR/BND.PORT` 是客户端必须发送 UDP 的 relay endpoint。association 在承载 UDP ASSOCIATE 的 TCP 连接终止时终止。[RFC 1928 §4, §6](https://www.rfc-editor.org/rfc/rfc1928.txt)
   - **[规范要求]** 每个 SOCKS5 UDP datagram 是 `RSV(0000)||FRAG||ATYP||DST.ADDR||DST.PORT||DATA`；响应使用相同 header 表示源地址。relay 必须丢弃非 association 所记录客户端 IP 发来的包。FRAG=0 表示独立包；fragmentation 可选，不实现时必须丢弃所有 FRAG!=0，不能转发残片数据。[RFC 1928 §7](https://www.rfc-editor.org/rfc/rfc1928.txt)
   - **[成熟实现惯例]** shadowsocks-rust 在 TCP handler 成功回复后持续读控制连接直到 EOF；UDP relay 对 `FRAG != 0` 直接丢弃。其 UDP association 默认 idle timeout 为 5 分钟，接收 buffer 常量为 65536；文档提供 `udp_timeout: 300` 和 `udp_max_associations`（示例 512）配置。[shadowsocks-rust `tcprelay.rs`](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.23.5/crates/shadowsocks-service/src/local/socks/server/socks5/tcprelay.rs) [shadowsocks-rust `udprelay.rs`](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.23.5/crates/shadowsocks-service/src/local/socks/server/socks5/udprelay.rs) [shadowsocks-rust `udprelay/mod.rs`](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.23.5/crates/shadowsocks/src/relay/udprelay/mod.rs) [shadowsocks-rust README](https://github.com/shadowsocks/shadowsocks-rust/blob/v1.23.5/README.md)
   - **[zc 设计建议]** association key 至少绑定 TCP control connection identity + client IP，并在首个合法 UDP 包后锁定源 port；TCP close 立即回收，另加 300 s idle 回收和全局 512 association 上限。每 association 的发送队列必须有界（建议 64 datagrams 或按字节计量），满时丢包并计数，不允许无界 allocator 增长。

6. **资源、超时与数据报大小上界（严重度：Major）**
   - **[规范要求]** RFC 1928 要求 SOCKS-aware UDP API 向应用报告的可用空间比 OS buffer 少：IPv4 10、domain 262、IPv6 20 字节，再加认证方法开销；其目的就是避免封装后超限。[RFC 1928 §7](https://www.rfc-editor.org/rfc/rfc1928.txt)
   - **[zc 设计建议]** 以跨 macOS/Linux、IPv4 可发送的 UDP payload 上限 **65507 bytes** 作为每个 wire datagram 的硬上限，并用 checked arithmetic 动态校验：
     - SOCKS 入站：`3 + encoded_addr_len + DATA <= 65507`；
     - SS AEAD 出站：`salt_len + encoded_addr_len + DATA + 16 <= 65507`；
     - 任一超限直接丢弃/返回 `datagram too large`，绝不 IP 分片感知、绝不截断。
     由于 domain address 最长编码 259 字节，`aes-128-gcm` 最坏可承载 DATA 为 `65507-16-259-16=65216`；AES-256/ChaCha salt 32 时为 65200。实际应按该包 ATYP 计算，而不是写死单一 DATA 常量。
   - **[zc 设计建议]** 单个 UDP receive buffer 可固定 65536（与 shadowsocks-rust 一致）；AEAD 解密前先验证最小 `salt + tag + 最短地址`，地址长度解析全程 checked。HTTP response header 8 KiB、SOCKS handshake 10 s、远端 UDP 请求 deadline 10 s、association idle 300 s；所有 timeout 和资源拒绝均打结构化计数器，但不要记录 payload、密码、master key、salt/subkey。

7. **固定版本独立互操作 oracle 与命令（严重度：Major）**
   - **[固定 oracle]** Shadowsocks 使用官方 `shadowsocks-rust v1.23.5`；它有 macOS/Linux release artifacts，经典 AEAD UDP 实现路径固定在 tag。simple-obfs 使用官方最后版本 `v0.0.5`（项目已 deprecated）。[shadowsocks-rust v1.23.5](https://github.com/shadowsocks/shadowsocks-rust/releases/tag/v1.23.5) [simple-obfs v0.0.5](https://github.com/shadowsocks/simple-obfs/releases/tag/v0.0.5)
   - **[构建 oracle；不含真实凭据]**
     ```bash
     git clone https://github.com/shadowsocks/shadowsocks-rust.git
     git -C shadowsocks-rust checkout v1.23.5
     cargo build --manifest-path shadowsocks-rust/Cargo.toml --release --bin sslocal --bin ssserver

     git clone https://github.com/shadowsocks/simple-obfs.git
     git -C simple-obfs checkout v0.0.5
     git -C simple-obfs submodule update --init --recursive
     (cd simple-obfs && ./autogen.sh && ./configure && make)
     ```
   - **[本机 oracle server 配置]** 写临时 `oracle-server.json`（仅测试口令）：
     ```json
     {
       "server": "127.0.0.1",
       "server_port": 18388,
       "method": "aes-128-gcm",
       "password": "interop-only-not-a-secret",
       "mode": "tcp_and_udp",
       "plugin": "/absolute/path/simple-obfs/src/obfs-server",
       "plugin_opts": "obfs=http"
     }
     ```
     启动：
     ```bash
     ./shadowsocks-rust/target/release/ssserver -c oracle-server.json
     ```
     zc profile 使用 server `127.0.0.1:18388`、相同 method/password、`udp: true`、`plugin: obfs`、`plugin-opts: {mode: http, host: www.bing.com}`。TCP 用 `curl --socks5-hostname 127.0.0.1:<zc-port> http://<local-http-echo>/`；UDP 用一个本机 UDP echo server，经 SOCKS5 UDP ASSOCIATE 发送 FRAG=0 包并核对返回地址/payload。分别把 cipher 改为 `aes-256-gcm`、`chacha20-ietf-poly1305` 重跑。
   - **[反向/差分 oracle]** 另起固定客户端：
     ```bash
     ./shadowsocks-rust/target/release/sslocal -c oracle-local.json
     ```
     其中 local 配置设 `local_address=127.0.0.1`、`local_port=11080`、`mode=tcp_and_udp`，server/plugin 与上面一致。对同一 TCP/UDP echo corpus 比较 zc 与 sslocal 的成功/失败矩阵；额外固定负例：分片 header、跨 read 的 HTTP 101 header、header 后同 read 带 ciphertext、错误 tag、截短 salt/tag、最大合法包和大 1 字节包。

## 建议验收矩阵

| 范围 | 必须通过 |
|---|---|
| 配置 | `obfs`/`obfs-local` 归一化；缺 host、CRLF host、tls mode、未知 mode 均明确报错 |
| HTTP obfs | 首写 header+payload；后续 raw；响应 header 每字节切分均可；terminator 后余留不丢；8 KiB+1 拒绝 |
| capability | `udp:false` 返回 REP 07 且零 association；`udp:true` 三种 AEAD 开放；obfs 不影响 UDP 路径 |
| AEAD UDP | 三 cipher 对 v1.23.5 双向互通；salt 长度/subkey/zero nonce/tag；篡改任一字节静默丢弃 |
| SOCKS5 UDP | IPv4/domain/IPv6；FRAG!=0 丢弃；错误 RSV/ATYP/长度丢弃；TCP close 立即销毁 |
| 资源 | 512 association 上限、300 s idle、队列满丢包、65507 wire cap、所有长度运算无溢出 |

## Sources

- **Kept:** [SIP003](https://shadowsocks.org/doc/sip003.html) — 插件名称、option string、生命周期及 TCP-only 规范。
- **Kept:** [Shadowsocks AEAD spec](https://shadowsocks.org/doc/aead.html) — 2017 AEAD cipher 参数、HKDF、UDP wire 与 nonce/salt 要求。
- **Kept:** [simple-obfs README](https://github.com/shadowsocks/simple-obfs/blob/master/README.md) — 官方配置、HTTP/TLS mode、弃用状态和部署命令。
- **Kept:** [simple-obfs `src/obfs_http.c`](https://github.com/shadowsocks/simple-obfs/blob/master/src/obfs_http.c) — HTTP 请求/响应 wire 和一次性 header 边界。
- **Kept:** [simple-obfs `src/obfs_tls.c`](https://github.com/shadowsocks/simple-obfs/blob/master/src/obfs_tls.c) — TLS mode 确实存在及其独立 framing。
- **Kept:** [shadowsocks-rust v1.23.5 source](https://github.com/shadowsocks/shadowsocks-rust/tree/v1.23.5) — 固定成熟实现的 AEAD UDP、SOCKS5、资源惯例。
- **Kept:** [mihomo shadowsocks.go](https://github.com/MetaCubeX/mihomo/blob/Alpha/adapter/outbound/shadowsocks.go) / [base.go](https://github.com/MetaCubeX/mihomo/blob/Alpha/adapter/outbound/base.go) — `plugin: obfs` 的 mode/host 与 UDP capability 配置语义。
- **Kept:** [RFC 1928](https://www.rfc-editor.org/rfc/rfc1928.txt) — UDP ASSOCIATE、FRAG、源地址和生命周期规范。
- **Dropped:** 博客、发行版包装文档、第三方教程、issue 中的用户配置 — 不在用户允许的高信任主来源集合内，或无法替代规范/官方源码。
- **Dropped:** AEAD-2022/SIP022 源码 — 本次目标明确是经典 2017 AEAD UDP，wire 完全不同。
- **Dropped:** mihomo `master`/未固定未来 release 的行为 — 仅用当前官方源码解释配置语义，不作为密码学 oracle。

## Gaps

- 未获得 zc 当前源码模块布局，因此本文给出的是行为与测试边界，未把建议绑定到未经核实的 `src/...` 路径；实现前应定位现有 profile parser、SOCKS5 handler、Shadowsocks AEAD TCP key derivation 和 runtime capability 接口，优先复用已有 master-key/HKDF/AEAD 原语。
- Shadowsocks 2017 AEAD 规范没有规定接收端 replay-cache 的容量/窗口；官方讨论仅是建议，shadowsocks-rust 固定版本也不对经典 UDP 启用该检查。若 zc 同时实现 server，应单独做安全设计评审，不能把自定义窗口当成协议要求。
- simple-obfs v0.0.5 构建本身有系统构建依赖；它只作为 CI/本机 oracle，不进入 zc standalone 产物，符合 zc 零运行时依赖目标。

```acceptance-report
{
  "criteriaSatisfied": [
    {
      "id": "criterion-1",
      "status": "satisfied",
      "evidence": "研究给出 Blocker/Major 分级，并引用具体外部源码路径：simple-obfs/src/obfs_http.c、simple-obfs/src/obfs_tls.c、mihomo/adapter/outbound/shadowsocks.go、mihomo/adapter/outbound/base.go、shadowsocks-rust v1.23.5 的 udprelay/aead.rs、tcprelay.rs、udprelay.rs；产物路径为 .pi-subagents/artifacts/outputs/89d610f2/research.md。"
    }
  ],
  "changedFiles": [
    ".pi-subagents/artifacts/outputs/89d610f2/research.md"
  ],
  "testsAddedOrUpdated": [],
  "commandsRun": [
    {
      "command": "Focused web research and primary-source fetch (SIP003, AEAD spec, RFC 1928, official GitHub source/release tags)",
      "result": "passed",
      "summary": "Fetched and cross-checked the required primary specifications and official source files."
    },
    {
      "command": "Implementation tests / oracle commands",
      "result": "not-run",
      "summary": "Research-only task; commands are provided as a reproducible fixed-version interoperability plan."
    }
  ],
  "validationOutput": [
    "Covered plugin aliases and mode/host semantics, HTTP request/response streaming boundaries, TLS scope decision, AEAD UDP layout/keying/replay boundary, RFC 1928 UDP association behavior, bounded resources, and fixed-version oracle commands.",
    "Only the authoritative runtime artifact was written; no project source or docs file was modified."
  ],
  "residualRisks": [
    "zc internal source paths were not discoverable with the available research tools, so implementation attachment points require repository inspection by the implementing agent.",
    "Classic AEAD UDP receive-side replay policy is intentionally left as a separate bounded security design because it is not fully specified and the fixed mature oracle disables that check."
  ],
  "noStagedFiles": true,
  "diffSummary": "Added one Chinese research brief at the runtime-authoritative artifact path; no repository docs/source changes.",
  "reviewFindings": [
    "blocker: HTTP obfs parser must handle CRLFCRLF across arbitrary TCP reads and preserve trailing ciphertext.",
    "blocker: UDP capability must reject before association allocation when disabled and must remain independent of TCP-only simple-obfs.",
    "blocker: 2017 AEAD UDP uses one random salt and all-zero nonce per independent datagram, not TCP chunk framing or AEAD-2022 layout.",
    "major: mode=tls exists upstream but must fail explicitly in this scope rather than silently downgrade.",
    "major: all header, association, queue, timeout, and datagram sizes require hard bounds."
  ],
  "manualNotes": "Runtime output-path override was followed: the requested docs/research/shadowsocks-simple-obfs-udp.md was not modified."
}
```
