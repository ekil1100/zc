# End-to-end release gate

`zig build e2e --summary all` 从真实 `zc` ReleaseSafe 二进制出发，只通过公开 CLI、
mixed HTTP/SOCKS5、minimal API 和 TCP/TLS/UDP wire 验证行为。测试把 `zc` 当作独立进程；
本地 origin helper 只复用跨平台 socket compatibility，不调用配置、路由或协议实现。独立的 test-only obfs oracle 同样不导入生产 config、Shadowsocks 或 simple-obfs 模块；它验证 HTTP wire 后剥离首个 header，再以 raw TCP 转发到固定 Shadowsocks 服务端。独立 UDP oracle 只导入 Zig `std`/`builtin`，自行实现 classic AEAD、SOCKS address/framing、deadline 与 socket I/O；literal wire 来自 `scripts/e2e/generate-shadowsocks-udp-vectors.mjs` 的 Node built-in crypto 实现。门禁不存在 warning-as-pass 或 skip-as-pass 分支。

## Coverage

门禁在隔离的 canonical `HOME` / `XDG_RUNTIME_DIR` 中验证：

- one-line installer 的 explicit/latest 版本、四平台资产映射、SHA-256、原子替换与失败保留；
- `config load`、managed identity、`start/status` 与 durable `proxy select`；
- mixed HTTP 与 SOCKS5 的真实 payload round-trip；
- DIRECT、REJECT 与错误密码负路径；
- `aes-128-gcm`、`aes-256-gcm`、`chacha20-poly1305`、
  `chacha20-ietf-poly1305` 对独立 Shadowsocks 服务端的互操作；
- `plugin: obfs` 与 `obfs-local` 的 simple-obfs HTTP 真实 socket round-trip；两个 alias 分别绑定不同 oracle endpoint 与 Host，且都经真实 CLI selection、mixed SOCKS5 和 socket 转发；
- oracle 独立校验 GET、Host、Upgrade、Connection、Sec-WebSocket-Key，并把首帧 `Content-Length` 精确绑定到按固定 SOCKS domain target 推导出的 72 字节 body；header/body 同 read tail、split read 与 71/73 off-by-one 负例都进入门禁；
- 两个 oracle 分别输出 raw TCP accept 与 fully verified counter；alias 请求只允许对应 endpoint 的两个 counter 精确增长，错误请求只能增长 raw counter。响应分别覆盖分片 101 header 与同 write 的 101+Shadowsocks tail，并要求 zc/oracle/ssserver/origin 四方证据一致；
- oracle 的 accept/read/partial-write/relay 全部使用 monotonic absolute deadline 和固定 buffer/iteration 上界；内部可执行回归覆盖 timeout、partial write、TCP EOF half-close、双向完成以及 oversized header/body；
- simple-obfs `tls`、未知 plugin/mode、缺 options/host 与 CRLF host 在 mixed listener bind 和 oracle dial 前失败，两个 TCP oracle 的 raw/verified counter 都保持不变；
- Shadowsocks UDP 三种算法与 `chacha20-poly1305` alias 经真实 mixed SOCKS5 UDP ASSOCIATE 完成 IPv4/domain/IPv6 round-trip；固定 `shadowsocks-rust v1.24.0 -U`、dual-stack echo 与独立 oracle counter 共同证明双向互操作；
- UDP 负路径覆盖 bad tag、截短 salt/tag、RSV/FRAG/ATYP/长度、65507/max+1、client IP/source port pin、control close、64+1 capacity 与 slot release；`udp:false` 在 allocation 前返回 REP 07，DIRECT、group→DIRECT 与非 UDP leaf 都 teardown 且不 fallback；
- simple-obfs UDP probe 只增长同 host/port 的 UDP oracle counter，两个 TCP obfs counter 均不变，证明 SIP003 仍为 TCP-only；
- Trojan TCP/TLS 对独立服务端的互操作；
- controller Bearer 鉴权与 unmanaged selection；
- reload preparation 失败时旧 daemon 继续转发，恢复后 reload 成功；
- rule-provider/resource focused tests 覆盖 4096/+1 declarations、跨 provider aggregate count/bytes、单 provider 多次引用、多个 provider 累计、长 target byte 放大、所有 exact/max+1 边界，以及 remote local-only `RULE-SET` 保留为一条；
- expansion probe 证明 borrowed-key provider index 的 build/lookups 随 `N providers + N refs` 线性增长；FailingAllocator 与 FixedBufferAllocator 证明 count/byte 超限发生在 output reserve/clone 前且无泄漏；
- catalog/legacy/integration gates 验证上述 typed resource errors 在 immutable revision publication、listener 与 dial 前拒绝，并保持 `state-v2.json` 与 revision tree 不变；
- stop 后 runtime prepared snapshot 被精确清理。

## Standalone fixtures

生产 `zc` 不引入运行时依赖。协议互操作门禁仅在测试期间下载两个固定版本的 standalone
fixture，并在执行前验证仓库内固定的 SHA-256：

- `shadowsocks-rust` `v1.24.0`；
- `trojan-go` `v0.10.6`。

Linux fixture 必须由 `file` 识别为 statically linked。`src/e2e_obfs_oracle.zig` 与 `src/e2e_shadowsocks_udp_oracle.zig` 的 executable 只服务 `e2e` / `e2e-release`；各自内嵌的 unit tests 另以 host-native、libc-linked `addTest` artifact 执行，并同时依赖于普通 `test`、`e2e` 与 `e2e-release` gate。测试 artifact 和 vector generator 不 install、不进入 release archive；oracle 与 fixture 只使用测试端点，UDP 服务端与 echo 只绑定本机地址。`testdata/e2e/trojan-key.pem` 是公开的测试私钥，不能用于任何部署。

## Scheduling

真实 IPv6 与 client-IP 绑定负例要求测试宿主启用 `127.0.0.1`、`::1`，并提供一个可绑定的非 loopback IPv4 地址。oracle 通过 UDP `connect(192.0.2.1:9)` 只执行内核路由查询（不发送数据报）来发现该地址，因此宿主还必须具备通往 TEST-NET-1 的 IPv4 路由；官方 macOS/Linux runner 满足这些前提。缺少该网络能力时门禁明确失败，不会降级为 skip/pass。

完整 network/installer E2E 有意不挂到普通 `zig build test`；只有 oracle 的 bounded unit seams 同时进入普通测试图：

- pull request 与 ordinary `main` push：`.github/workflows/ci.yml` 的独立 `e2e` job 运行 `e2e-release`；
- version tag：`.github/workflows/release.yml` 先确认 tagged commit 已有成功的 `main` CI；
- 本地：开发者显式运行 `zig build e2e --summary all`。

`main` CI 在 Linux amd64 上直接对 `x86_64-linux-musl` static zc 执行该门禁。发布
workflow 只重建、校验和打包四平台产物；任一 E2E、主干门禁或 release matrix 失败都会阻止
publish。
