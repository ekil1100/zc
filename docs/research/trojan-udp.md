# Trojan UDP 协议与互操作结论

## 结论

Trojan UDP ASSOCIATE 不是 UDP socket 直连代理服务器，而是在一条独立 TLS
字节流里承载有边界的 UDP datagram。

请求：

```text
SHA224_HEX(password)[56] || CRLF || 0x03 || SOCKS_ADDR || CRLF
```

每个双向 datagram：

```text
SOCKS_ADDR || PAYLOAD_LENGTH_BE16 || CRLF || PAYLOAD
```

- `PAYLOAD_LENGTH` 只计算 payload；
- frame 没有 SOCKS5 UDP 的 `RSV` / `FRAG`；
- payload 后没有 CRLF；下一字节直接是下一帧 ATYP；
- IPv4/domain/IPv6 分别使用 ATYP `0x01`/`0x03`/`0x04`；
- 一条 TLS association 可连续承载多个目标；EOF/坏帧结束整条 association；
- 协议没有成功 ACK、per-packet ACK 或结束帧。

来源：

- [Trojan 官方协议](https://github.com/trojan-gfw/trojan/blob/3e7bb9aecdc694f9bcae8d646fae395f773d60f8/docs/protocol.md#L7-L49)
- [官方 UDP frame parser](https://github.com/trojan-gfw/trojan/blob/3e7bb9aecdc694f9bcae8d646fae395f773d60f8/src/proto/udppacket.cpp#L24-L61)
- [mihomo Trojan transport](https://github.com/MetaCubeX/mihomo/blob/ac017cdd246ce8bd547653d927e7bf77d7ee73d5/transport/trojan/trojan.go#L54-L130)
- [trojan-go v0.10.6 UDP client](https://github.com/p4gefau1t/trojan-go/blob/2dc60f52e79ff8b910e78e444f1e80678e936450/tunnel/trojan/client.go#L136-L154)

## zc 的协议选择

- UDP ASSOCIATE 请求使用生态中已验证的 `0.0.0.0:0` sentinel；实际目标始终在每个 frame 中。
- frame 接收端严格校验 CRLF。mihomo 某些版本只跳过两字节，但 writer 仍发送标准 CRLF；zc 不复制宽松 parser。
- codec 支持完整的 `u16` payload 长度（0..65535），不拆包、不重组。
- mixed SOCKS5 自身仍受 65507-byte UDP wire 上限约束，不支持 SOCKS fragmentation。
- domain 先按原域名匹配规则，再在发往 Trojan 前本地解析为 IP frame。原因是
  mihomo v1.19.30 的 Trojan 入站无法把 ATYP=domain frame 转为 UDP endpoint：
  [mihomo address conversion](https://github.com/MetaCubeX/mihomo/blob/ac017cdd246ce8bd547653d927e7bf77d7ee73d5/transport/socks5/socks5.go#L69-L85)。
- 相同 domain/port 使用 association 内固定一项解析缓存，避免逐包系统 DNS。
- TCP 保留既有无帧流的 truncation 权衡；UDP TLS 禁止 truncation，因为 frame
  中途 EOF 可以被确定识别为错误。
- Trojan 使用基于 Zig 0.16.0 `std.crypto.tls.Client` 的审计副本
  `src/protocol/TLSClient.zig`：SNI 与 certificate reference identity 独立配置，
  `skip-cert-verify:true` 因此可以保留 SNI 并同时禁用链/身份校验；TLS 1.3 收到
  `KeyUpdate(update_requested)` 时，会有界重组跨 record 的 post-handshake 消息、
  校验 TLS 版本/固定 1-byte body/record boundary，并先用旧发送密钥发送
  `KeyUpdate(update_not_requested)`，再轮换发送密钥。对应上游问题与修复依据：
  [ziglang/zig#22508](https://github.com/ziglang/zig/issues/22508)、
  [ziglang/zig#22512](https://github.com/ziglang/zig/pull/22512)。

## 资源与生命周期

- mixed ingress 的 64 条 UDP association 总上限由 Shadowsocks 与 Trojan 共享；
- 每条 Trojan association 使用一条 TLS/TCP 连接、固定 frame buffers、最多各
  2 个 frame 的有界收/发队列和 256 KiB steady-state I/O stack；建连阶段另有一条
  最多存活 10 秒、可取消并在返回前 join 的临时 512 KiB handshake worker，64 条
  并发建连的临时 stack 预算因此最多约 32 MiB；队列满时丢包，不增长内存；
- 单一 I/O thread 独占可变 TLS state，避免 reader/writer 与 TLS 1.3 KeyUpdate
  竞争；接收器仍是增量、有界 parser，可处理 TLS 分片、同一 read 内连续 frame
  和末帧+HUP；
- Trojan server DNS、nonblocking TCP connect 与 TLS handshake 均受同一 absolute
  deadline/control cancel 约束；control TCP 关闭或出现额外数据时会 shutdown 上游、
  join I/O thread 并释放 association；shutdown 同时
  可打断 blocking TLS read/write，所以背压 peer 不能占死 64 条 slot；
- Trojan server DNS/TCP/TLS 共享 10 秒 session-open deadline；初始 TLS handshake
  最多消费 256 个 record 和 32 条完整 handshake message，单条 message 使用固定
  128 KiB accumulator（可覆盖跨多个 record 的证书链消息），拒绝无限控制帧输入；目标
  domain 另有 5 秒 cancel-aware DNS 上限。TCP 数据流仍保留下述 blocking-record
  M5，UDP 则用 I/O thread 与有界队列隔离 association worker；
- TLS writer 会有界排空完整 16645-byte plaintext buffer，不把未加密尾部当成已消费；
  TLS 1.2/1.3 record sequence 以 ciphertext/明文提交为边界原子推进，耗尽会在 nonce
  重用前失败；最终正常关闭会 flush `close_notify`，fatal/cancel 路径显式 abort；
- Trojan TCP 没有独立的应用层半关闭帧；本地写侧 EOF 会 flush 一次方向性的 TLS
  `close_notify`，从而禁止后续应用数据并避免 idle 悬挂。固定 `trojan-go v0.10.6`
  会在收到该关闭后结束双向 tunnel：E2E 用 domain target 证明 origin 确实收到 EOF，
  同时明确断言客户端及时收到 EOF；依赖传输 EOF 后才生成的数据不能透明返回。

## 验证证据

- literal codec 单测覆盖 IPv4/domain/IPv6、空 payload、65535 payload、坏 ATYP、
  坏 CRLF、port 0 以及每个截断点；
- 普通测试图：`zig build test --summary all`；
- 固定 `trojan-go v0.10.6` E2E：IPv4、domain 和 IPv6 分别通过真实 mixed
  SOCKS5 UDP ASSOCIATE、TLS Trojan server 与 dual-stack UDP echo；每个 probe
  同时用专用 probe 在一条 association 连续发送 IPv4+domain，断言 trojan-go
  association 只增长 1、双向 frame 各增长 2，且 trojan-go 请求方向的
  `udp packet from` metadata 已由 `localhost` 变成 IPv4；IPv6 probe 另行锁定 dual-stack frame。DIRECT/fallback、单帧 association
  或 ATYP=domain 透传均无法伪造该 oracle；
- 本地另使用真实订阅节点验证 IPv4 DNS，以及同一 association 的 IPv4+domain
  多目标 round-trip。测试只使用显式非生产端口，不占用 7899。
