# 端到端交付门禁

`just e2e` 从真实 Rust `target/debug/zc` 出发，只通过公开 CLI、mixed HTTP/SOCKS5、minimal API 和 TCP/TLS/UDP wire 验证；先原样执行 `scripts/e2e/run-core.sh`，再执行 `scripts/e2e/run-rust-tcp.py`。默认入口不依赖 Zig。CI 还使用 release 产物验证，不把 debug 成功等同 release/matrix 通过。

`examples/` 的 origin、simple-obfs、SS UDP helper 是 test-only 独立程序，不导入生产配置、路由或协议 codec。SS UDP 使用独立 Node/OpenSSL worker 与 literal crypto vectors，obfs helper 校验 HTTP 后 raw TCP 转发。不存在 warning-as-pass 或 skip-as-pass。以下是应覆盖的验收范围，**不是本轮全部通过的声明**；最终证据见 [迁移说明](../migration/rust.md)。

## 覆盖范围

daemon CLI 回归的 socket/spawn 隔离与锁替换同步边界见 [daemon fixture 契约](daemon-fixtures.md)。

门禁与配套回归在隔离的 canonical `HOME` / `XDG_RUNTIME_DIR` 中验证：

- one-line installer 的 explicit/latest 版本、四平台资产映射、SHA-256、原子替换与失败保留；
- `config load`、managed identity、`start/status` 与 durable `proxy select`；
- 独立 CI smoke 使用声明了 `mixed-port: 7892` 的配置执行无 `--port` 的 `start`，并以真实 TCP、`doctor`、`reload` 与 `restart` 证明运行端口始终是 `7899`、配置端口未监听；
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
- simple-obfs UDP probe 只增长同 host/port 的 UDP oracle counter，两个 TCP obfs counter 均不变，证明 SIP003 仍为 TCP-only；TCP/UDP 同号 fixture 使用有界重试配对，且每个 UDP readiness 都必须通过带 nonce 的真实 datagram challenge；
- Trojan TCP/TLS（包括 domain target 经 trojan-go 收到方向性 TLS close 后，EOF-origin 与客户端均在 deadline 内结束且不误走 DIRECT；trojan-go 不保留 EOF 后生成的反向响应），以及 `udp:true` 经 mixed SOCKS5 UDP ASSOCIATE 对固定 `trojan-go v0.10.6` 的 IPv4/domain/IPv6 双向互操作；专用 UDP probe 在同一 association 连续发送 IPv4 与 domain，要求 trojan-go association 仅增长 1、双向 frame 各增长 2，并断言 trojan-go 请求方向的 `udp packet from` metadata 已从 domain 变为 IP；IPv6 probe 另行锁定 dual-stack wire，避免 DIRECT/fallback、单帧 association 或 domain 透传假阳性；
- controller Bearer 鉴权与 unmanaged selection；
- reload preparation 失败时旧 daemon 继续转发，恢复后 reload 成功；
- rule-provider/resource focused tests 覆盖 4096/+1 declarations、跨 provider aggregate count/bytes、单 provider 多次引用、多个 provider 累计、长 target byte 放大、所有 exact/max+1 边界，以及 remote local-only `RULE-SET` 保留为一条；
- provider index / expansion 的线性行为与 reserve/clone 前资源拒绝须有 Rust 测试和性能证据；原 Zig FailingAllocator/FixedBufferAllocator 测试是历史参考，不能代替 Rust 验收；
- catalog/legacy/integration gates 验证上述 typed resource errors 在 immutable revision publication、listener 与 dial 前拒绝，并保持 `state-v2.json` 与 revision tree 不变；
- stop 后 runtime prepared snapshot 被精确清理。

## 独立 fixture

生产 `zc` 不引入运行时依赖。协议互操作门禁仅在测试期间下载两个固定版本的 standalone
fixture，并在执行前验证仓库内固定的 SHA-256：

- `shadowsocks-rust` `v1.24.0`；
- `trojan-go` `v0.10.6`。

Linux fixture 必须由 `file` 识别为 statically linked。Rust test-only helper 构建为 `target/debug/examples/e2e_origin`、`e2e_obfs_oracle`、`e2e_ss_udp_oracle`，由 `just helper-test` 验证公开 process/socket 接口、独立 literal vectors 与负路径。SS UDP 加密 worker 依赖测试环境的 Node.js，不是生产 zc 的依赖。

测试 artifact 和 vector generator 不 install、不进入 release archive；oracle/echo 仅用测试端点。`testdata/e2e/trojan-key.pem` 是公开测试私钥，不能用于部署。oracle 中的故意 ContentLengthMismatch 是负向预检，不是生产 obfs 故障。

## 调度与前置条件

真实 IPv6 与 client-IP 绑定负例要求测试宿主启用 `127.0.0.1`、`::1`，并提供一个可绑定的非 loopback IPv4 地址。oracle 通过 UDP `connect(192.0.2.1:9)` 只执行内核路由查询（不发送数据报）来发现该地址，因此宿主还必须具备通往 TEST-NET-1 的 IPv4 路由；官方 macOS/Linux runner 满足这些前提。缺少该网络能力时门禁明确失败，不会降级为 skip/pass。

完整网络/安装 E2E 不隐式挂到普通 `cargo test`，开发者显式运行：

```bash
just test
just helper-test
just e2e
just install-test
just validate
```

需要 Python 3、Node.js、curl/归档/SHA-256 工具和上述网络能力。fixture 缺失或校验失败即失败；`just e2e` 先下载固定 fixture 到 `target/e2e-fixtures`。本地使用临时 canonical HOME/runtime 和非生产端口，不能运行默认 7899 smoke。

PR/main 与 tag 的实际任务以 `.github/workflows/ci.yml` / `release.yml` 为准：四平台 native Rust 构建，Linux musl static 检查，真实 release E2E 与安装 smoke；tag 发布先确认对应 main CI 成功。固定默认 7899 的独立 smoke 只在一次性 Linux CI 环境执行。

300 秒 UDP idle 是需显式执行的长等待场景，短回归与默认 ignored 测试不构成其通过证据。`CORE_E2E_RESULT=PASS`、`INSTALLER_E2E_RESULT=PASS` 必须来自对应完整命令的零退出；不能从部分 counter/marker 推导全部门禁或四平台通过。
