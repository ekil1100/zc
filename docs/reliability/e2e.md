# End-to-end release gate

`zig build e2e --summary all` 从真实 `zc` ReleaseSafe 二进制出发，只通过公开 CLI、
mixed HTTP/SOCKS5、minimal API 和 TCP/TLS wire 验证行为。测试把 `zc` 当作独立进程；
本地 origin helper 只复用跨平台 socket compatibility，不调用配置、路由或协议实现。独立的 test-only obfs oracle 同样不导入生产 config、Shadowsocks 或 simple-obfs 模块；它验证 HTTP wire 后剥离首个 header，再以 raw TCP 转发到固定 Shadowsocks 服务端。门禁不存在 warning-as-pass 或 skip-as-pass 分支。

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
- simple-obfs `tls`、未知 plugin/mode、缺 options/host、CRLF host 以及 Shadowsocks `udp:true` 在 mixed listener bind 和 oracle dial 前失败，两个 oracle 的 raw/verified counter 都保持不变；
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

Linux fixture 必须由 `file` 识别为 statically linked。`src/e2e_obfs_oracle.zig` 的 executable 只服务 `e2e` / `e2e-release`；同一文件内嵌的 unit tests 另以 host-native、libc-linked `addTest` artifact 执行，并同时依赖于普通 `test`、`e2e` 与 `e2e-release` gate。测试 artifact 不 install、不进入 release archive；oracle 与 fixture 都只绑定 loopback。`testdata/e2e/trojan-key.pem` 是公开的测试私钥，不能用于任何部署。

## Scheduling

完整 network/installer E2E 有意不挂到普通 `zig build test`；只有 oracle 的 bounded unit seams 同时进入普通测试图：

- pull request：`.github/workflows/ci.yml` 的独立 `e2e` job；
- version tag：`.github/workflows/release.yml` 的 Linux amd64 release-artifact E2E step；
- ordinary `main` push：不重复执行；
- 本地：开发者显式运行 `zig build e2e --summary all`。

发布 workflow 在 Linux amd64 上直接对将被打包的 `x86_64-linux-musl` static zc 执行
该门禁；任一 E2E 或四平台 release matrix 失败都会阻止 publish。
