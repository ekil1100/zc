# mihomo/clash 兼容边界

本文描述 Rust 候选的配置与运行时支持边界，**不是完整 mihomo 替代声明，也不代表正式发布验证已经完成**。

## 配置、入口与能力准入

- 一个 mixed HTTP/SOCKS5 listener，默认 loopback。生产默认端口 **7899**；只有 CLI `--port` 控制实际端口。来源 `mixed-port`（含 0）只作兼容声明，准备时规范化；开发显式使用其他端口。
- 同文件存在 mixed 声明时，`port/socks-port` 是 ignored compatibility declarations；没有 mixed 的 standalone 入口拒绝。`redir-port/tproxy-port` 不创建 listener，TUN 不支持。
- `allow-lan:false` 的规范运行时投影绑定 loopback；`allow-lan:true` 才允许 LAN。没有入站认证，不应暴露给不可信客户端。
- `external-controller` 仅接受 `127.0.0.1:<port>`；必须精确绑定，不漂移、不静默关闭。托管 profile 仅在已有 controller 且无非空显式 secret 的实际运行准备时，生成并持久复用自动 secret；显式值优先且不抹掉旧自动值。不会添加 controller/默认控制端口，非托管文件保持手工配置。
- `mode/log-level` 接受合法兼容声明；不要据此宣称完整 mihomo 模式调度或动态日志级别。当前路由由规则决定。
- `dns`（含 fake-ip、enhanced-mode、nameserver-policy）、`hosts`、`sniffer`、`profile`、`experimental`、`unified-delay`、`clash-for-android` 接受但不执行，见下方清单；`proxy-providers` 仍拒绝。`external-ui` 等兼容元数据不代表托管 dashboard。
- 运行时只使用已经校验的兼容字段；原始配置和规范化配置的字节及内容摘要不会被运行时投影改写。
- 未启用的 outbound/group/plugin 在准备或准入时明确拒绝，绝不回退 DIRECT。用户声明的精确名称 `DIRECT/REJECT` 保留，不能覆盖内置字面量。

## 接受但暂不执行的订阅字段

以下七个**顶层字段**不会阻止配置加载、启动或 doctor 检查；仅在运行时投影中跳过，不修改原文件、托管 revision 的 source/materialization 或其内容摘要。它们仍受全文 YAML 语法、重复键、alias、深度和资源限制约束，但暂不校验其内部功能 schema。接受声明不表示相关功能生效。

| 字段 | 当前行为 | 不代表支持的能力 |
| --- | --- | --- |
| `dns` | 使用现有系统 DNS 路径，不应用本段配置 | 自定义解析器、fake-ip、nameserver-policy 等 |
| `hosts` | 不应用配置内映射；系统 hosts 路径不变 | 配置级静态域名映射 |
| `sniffer` | 不嗅探应用层协议或改写目标 | 协议嗅探与目标覆盖 |
| `profile` | 不应用本段选项；zc 自身持久选择逻辑不变 | store-selected/store-fake-ip 等兼容语义 |
| `experimental` | 不应用实验选项 | 不能据字段存在宣称支持实验功能 |
| `unified-delay` | 不改变延迟测量 | 统一延迟测量语义 |
| `clash-for-android` | 不应用 Android 客户端选项 | Android 客户端功能；Android 不在生产目标内 |

这是明确列举的兼容例外，不是忽略所有未知字段。未列出的未知字段、`tun`、`proxy-providers`、不支持的节点协议/插件/策略组以及错误规则仍拒绝；不会把未实现的出站替换为 DIRECT。override patch 的字段许可范围也不因此扩大。

## TCP 与出站

| 能力 | Rust 候选边界 |
| --- | --- |
| HTTP CONNECT / SOCKS5 CONNECT | 双向 TCP tunnel；除 AnyTLS 外保留 half-close；SOCKS5 无用户认证 |
| HTTP forward | absolute-form HTTP/HTTPS；有界 Content-Length/chunked request、100-continue、顺序 keep-alive；每连接最多 1024 请求；拒绝冲突 framing/Host、非法 trailer、Upgrade |
| DIRECT / REJECT | 内置字面量可用；REJECT 是终态，不因目标为私网/loopback 改写为 DIRECT |
| 用户命名 `type: direct/reject` | 可作为命名叶节点及 select 成员 |
| SS classic AEAD | `aes-128-gcm`、`aes-256-gcm`、`chacha20-ietf-poly1305`；`chacha20-poly1305` 是同一 wire alias |
| simple-obfs | 只支持下述内建 HTTP 形状，仅包装 SS TCP |
| Trojan | 原生 TLS/TCP，password/server/port/sni/skip-cert-verify；另有受限 UDP association |
| AnyTLS | 原生 TLS/TCP，单流独占 session；详见下节，无复用/UDP |
| HTTP/SOCKS5 outbound、VMess/VLESS | 不支持 |
| SS AEAD-2022、外部 SIP003、obfs TLS、Trojan WS/gRPC | 不支持，拒绝而非降级 |

HTTP CONNECT 的请求目标必须包含显式端口（例如 `CONNECT example.com:443`）。为兼容 Node/Undici/Pi，`Host: example.com` 省略端口时按请求目标端口校验；域名、IPv4 和带方括号的 IPv6 均支持。不同主机、冲突的显式端口、非法/重复 Host 及 HTTP/1.1 缺失 Host 仍拒绝；不改变规则匹配、出站目标或非 CONNECT 的 Host 校验。

HTTP request header 最多 16 KiB，request body 最多 16 MiB；chunk framing/trailer 也有计数/字节上界。response 按流转发，不应把 request body 上界误称 response 总大小上界。mixed 最多 1024 connection tasks，入站握手 10 秒，路由与出站准备另有 10 秒 deadline，TCP 转发空闲期限 15 分钟。退出取消并回收任务，不承诺 drain 完全部存量流量。

TLS 使用 rustls / tokio-rustls、系统信任根、安全默认 TLS 1.2/1.3；不继承 Zig TLS 派生实现的 poll/partial-record/KeyUpdate 限制说明。Trojan / AnyTLS server 必须是合法 IP 或 RFC hostname，DNS server 尾点在派生身份时去除；显式 SNI 必须是无尾点的 DNS hostname，不接受 IP/wildcard/控制字符。验证证书的 IP server 须显式 SNI。仅 `skip-cert-verify:true` 关闭链和身份校验，握手签名仍验证；这是安全降级，不是默认行为。uTLS/Reality/mTLS/任意 ALPN 配置不在支持范围。

### AnyTLS：单流原生 TLS/TCP

每条应用 TCP 流新建一个 TLS session，stream id 固定为 1；不建立池、不复用、不提供 UDP/UoT。支持 `name/type/server/port/password/sni/skip-cert-verify`、`network: tcp`、`udp: false`；`disable-reuse` 缺省即禁用复用，显式值只接受 `true`。这与 mihomo 默认复用不同，不能称为完整 AnyTLS 合规或等价性能。

- 默认验证 TLS 身份及握手签名；仅显式 `skip-cert-verify: true` 降低链/身份校验，不跳过握手签名。身份/SNI 约束同 Trojan。
- 拒绝节点级池参数、`disable-reuse: false`、UDP、ALPN、指纹、自由 client metadata、扩展 TLS/transport 参数及未知字段，包括未选节点。原始 source 和 override 有效输入在 canonical 丢字段前检查。现有规范化占位 `tls: false` / `alterId: 0` 不表示关闭 TLS 或开启另一协议；其他值拒绝。顶层 idle-session 兼容默认值不变，不启用 AnyTLS 池，也不改变既有 canonical bytes/hash。
- 完整认证块为原始 SHA-256 摘要、BE16 padding 长度和 padding，一次提交 TLS。随后主动发送 Settings → SYN → PSH 地址，支持 IPv4/IPv6/domain，服务端先发无需客户端先送 payload。
- **乐观开流**：写完准备数据即可向 mixed CONNECT/SOCKS 返回成功，不等待 v2 ServerSettings/SYNACK，因此兼容 v1。后续 Alert、非空 SYNACK 或未收到 FIN 的 session EOF/RST 是连接错误，不回退 DIRECT、不重放请求；v1 目标失败可能仅返回 FIN，无法提供精确原因。
- **FIN 是整流关闭，不是半关闭**。本地 shutdown 排空已接受字节，发送一次 FIN，完成 TLS/套接字写侧 shutdown 后释放 session，不等待 FIN 回应；已组装 PSH 的未读尾部仍可读取。远端 FIN 后立即停止新增上行，按序排尽 FIN 前已收到的数据（包括中继的下行缓冲），再返回 EOF 并结束中继，不等待客户端写侧 EOF 或 15 分钟 idle。独立流接口仍拒绝迟到写；中继不能通过忽略任意 BrokenPipe 丢下行，也不能假装接受并丢弃上行。依赖“发送 EOF 后才收到响应”的应用不在透明支持范围内；其他协议的 half-close 不变。
- 适配器直接持有 TLS，无后台 worker；每次仅缓存一个待发送分组、一个待接收帧及最多 **32 个排队心跳 ID**，另可有一个已进入发送分组的心跳回复。所有分组串行发送，部分写游标不重置、不交错数据与控制帧；控制写 Pending 时仍读取后续 PSH/FIN。队列满后再收到 HeartRequest 明确终止，不阻塞全部读取或无限积累。帧 body 上限 65535 bytes，大 payload 分 PSH；文本控制帧上限 4096 bytes，每 poll 最多处理 32 个帧后让出调度。合法 v2 心跳按序回显 id；非法方向/id/长度、重复版本/ACK、截断均终止。慢读/慢写有背压，取消 Drop 直接释放连接。
- 初始使用官方默认 padding；服务端更新按节点线程安全保存，仅后续 session 使用，MD5 对**原始字节**计算（含末尾 LF）。本地准入：方案最多 4096 bytes、`stop` 为 1–32、分组索引小于 stop、每组最多 16 项，正向范围 `min<=max`；认证组仅一个尺寸、最多 4062 bytes，普通片最多 16384 bytes；所有尺寸上界加各自 7-byte 帧开销的总和最多 65536 bytes。缺省分组不填充；认证组缺省为零填充。超过预算或非法更新终止当前 session，不污染原方案。
- 随机范围与固定 Go 实现一致为 `[min,max)`，相等时固定；`c` 在无真实数据时停止后续填充。纯填充分支发送 body 长度为所选尺寸的 Waste，所以 TLS 明文长度为 **尺寸+7**。每个发送分组最多一个 65542-byte 数据帧加 64 KiB padding 预算；这不是整个 TLS/内核缓冲的总内存承诺，也不保证所有方案尺寸等于 TLS record 尺寸。

AnyTLS 整流关闭时，CONNECT/SOCKS 和 HTTP forward 均停止上传并排完已接收响应；未完成的 HTTP 请求体不得复用为下一请求。HTTPS 仍检查内层 TLS 截断。DIRECT/SS/Trojan 保留 TCP half-close 转发，不采用 AnyTLS 的整流关闭语义。请求头和 CONNECT 已缓存前缀会及时发送，避免阻塞服务端提前响应或 100-continue。

不保证抗指纹效果、与 mihomo 等价的性能或长期稳定性。

### simple-obfs HTTP

```yaml
plugin: obfs # or obfs-local
plugin-opts:
  mode: http
  host: cdn.example.com
```

两个字段必须显式存在。host 为 1–255 bytes，不含 CR/LF/NUL。`plugin_opts` map alias 可接受并规范成 `plugin-opts`；冲突 alias、非 map、SIP003 scalar 字符串、未知模式/plugin、缺 host、非 SS plugin 均拒绝。不启动外部 plugin，也不退化为 plain SS。

HTTP 首帧、Content-Length、分片 response header 与同次读取的尾部数据均作有界处理。

仅明确 malformed/unsupported SS obfs metadata 可作为 inactive raw recovery revision 保存；严格 YAML、字段、规则/provider 和资源 gate 仍必须通过。`download -d`、active update、use 不能激活此 revision；修复 source 后 update/use。其他协议错误没有这一恢复豁免。

## UDP：受限 association，不是通用 DIRECT UDP 入口

mixed SOCKS5 CMD=0x03 仅用于显式 `udp:true` 的 SS classic AEAD 或原生 TLS Trojan leaf。配置不存在任何此类 leaf 时，在 association/socket allocation 前返回 REP=0x07。成功 reply 的 endpoint 是客户端应使用的 relay；不支持独立 socks-port UDP。

- TCP control peer IP 绑定 association；请求非零 source port 时约束该端口，否则首个完全合法、同 IP 数据报固定 source port。
- 首个合法 datagram 执行规则与 select 解析并固定实际 leaf；后续 datagram 可有其他目标，但复用同一 outbound session，不重新选组、不 fallback。
- DIRECT、group→DIRECT、REJECT、AnyTLS、非 `udp:true` leaf 结束 association，不提供 DIRECT UDP ingress。
- 最多 64 associations，第 65 个返回 general failure；control close 立即取消 DNS/open/send/relay 并释放 slot，另有 300 秒单调时钟 idle。
- SOCKS 与 SS wire 单包上界均为 65507 bytes，按实际 address/cipher overhead 检查；坏 RSV/FRAG/ATYP/长度、SS bad tag 或截短 salt/tag 按 packet 丢弃；不分片、不重组、不积累无界队列。

### SS classic AEAD UDP

使用 `shadowsocks` crate；每包独立 CSPRNG salt、HKDF-SHA1 `ss-subkey`、全零 nonce、空 AAD 与 `ATYP|ADDR|PORT|DATA` plaintext，不复用 TCP chunk framing。三种 cipher 与 alias 与 TCP 相同。simple-obfs 不包装 UDP，直接使用同一 server host/port 的 UDP endpoint；错误不得改走 plain/DIRECT fallback。

### Trojan UDP

专用 TLS/TCP stream 请求：`SHA224_HEX(password) | CRLF | CMD=0x03 | 0.0.0.0:0 | CRLF`。datagram frame：`SOCKS_ADDR | PAYLOAD_LEN_BE16 | CRLF | PAYLOAD`，payload 后无额外分隔符。支持 IPv4/domain/IPv6、空 payload；非法 CRLF、ATYP、长度和中途 EOF 结束 association，不做 stream 重同步。

domain 先按原域名匹配规则，再本地解析成 IP frame 兼容主流服务端；session 缓存最后一个 domain/port 结果。使用异步单一 worker 独占 stream、有界双向各 2-frame channel，满时丢包。实际 IPv6 可达性依赖服务端 egress。

## 代理组、规则与 DNS

仅 `select` 可运行；`url-test/fallback/load-balance/relay` 不启用。默认首成员，持久选择优先；嵌套组按预建索引解析，未知引用、循环拒绝，最多 1024 个组。不要假设 mihomo 的探测、故障转移或负载均衡策略。

支持解析与匹配：`DOMAIN/DOMAIN-SUFFIX/DOMAIN-KEYWORD`、`IP-CIDR/IP-CIDR6`、`DST-PORT/SRC-PORT`（含范围）、`SRC-IP-CIDR`、`PROCESS-NAME`、`GEOIP`、`RULE-SET`、`MATCH`。

- 声明顺序 first-match，域名 ASCII 大小写不敏感、忽略末尾 root dot；无匹配拒绝，不任意 fallback DIRECT。
- **CLI 规则默认值**：缺失 `rules`、显式 `[]`、非空规则缺终态 MATCH 均补 `MATCH,REJECT`；重复/非尾部 MATCH 拒绝。
- mixed HTTP/SOCKS 提供目标端口与来源 IP/端口；不提供进程名，`PROCESS-NAME` 的可解析性不等于实际进程规则生效。
- GEOIP 保留原有静态 IPv4 heuristic table，不是完整地理库；IPv6 不完整。`no-resolve` 避免为相应 IP/GEOIP 规则解析域名。
- 为 IP 规则解析后使用同一 DNS 快照，获准 IP 固定给后续 DIRECT/SS/Trojan/AnyTLS dial/encode，不重解析并选择未获准地址。

Hickory 从系统 DNS 配置/hosts 初始化，网络查询非阻塞；2 秒 lookup deadline，64 query slots，每个并行 A/AAAA lookup 占 2 slots，最多保留 64 地址，取消释放 slot。cache size 配置为 64，但不是瞬时硬内存上界。系统/hosts 不自动重载，不等价于 libc/NSS、mDNS 或完整 split-DNS；没有 nameserver 时拒绝，不暗用公共 DNS。

## rule-provider 与离线托管

`domain/ipcidr/classical` provider 展开为有界规则。local assets 必须位于配置根内、相对路径、普通文件；descriptor-relative traversal 拒绝 symlink/特殊文件，不能逃到 cwd/source 外部。托管 revision 捕获 source 与 assets，加载只信任捕获字节，不回读可变文件。

**Managed 离线 gate**：被 RULE-SET 引用的 HTTP provider 不可离线展开，load/download/update/旧数据接管在发布任何 revision（包括 inactive）前拒绝，activation/runtime 再检查。未引用 remote declaration 可作为 deferred metadata 存在。这是原离线基线限制，不是“已经实现远程 provider 托管”。

**Unmanaged 显式来源**：准备阶段持有配置来源根目录的 dirfd，再同步、校验并冻结 provider bytes；监听器不得先于完整 body 和规则展开校验开放。默认 `interval: 86400` 秒，mtime 按秒判断；将来时间视为未到期。

| 调用路径 | 缓存策略 |
| --- | --- |
| start、显式来源 restart、reload、proxy/profile test | 缺文件下载；已有文件到期刷新，未到期不联网 |
| 独立 `test` | missing-only：已有文件不周期刷新，但仍须校验 |
| 默认 restart | 复用认证的冻结快照，不重新访问来源、cache 或网络 |
| doctor / diag doctor | 原调用链只校验声明，不同步或展开 provider body；不是 runtime-ready 证明 |
| managed revision | 保持离线 gate；未引用 remote metadata 不触发网络或缓存写入 |

HTTP(S) 请求总期限 30 秒（包括迟到的 headers/body）、最多 5 次 redirect，不使用环境代理；仅 HTTP 200 是成功候选。无 remote 或全部使用有效缓存时不构造 HTTP client、不加载 TLS roots。普通连接/下载/状态失败只有在原缓存存在、且重新有界读取和内容校验通过时才可回退；不会替换成空规则或 DIRECT。畸形/非 UTF-8/超限候选、资源错误和发布失败不能回退。全部候选先进入独立 immutable assets；仅有待写缓存时，在第一笔发布前验证完整配置语义、aggregate 与重复 RULE-SET 展开预算。这些校验失败（包括后续 provider 畸形）时，所有旧缓存保持原字节；零更新路径不额外完整解析一次。逐文件发布不是多文件事务：后续 I/O 或目的身份冲突失败时，先前已发布文件可能保留。过期坏缓存可由有效下载修复，未到期或 missing-only 下的坏缓存直接拒绝。

缓存必须是 source root 内的相对路径。根目录及子目录须为当前用户所有且不可被 group/other 写入；dirfd traversal 拒绝 symlink、特殊文件和越界，文件拒绝非本人所有或 hard links。已有普通缓存可为 0644，但 metadata/read/write 预检一致拒绝 POSIX `mode & 022 != 0`（例如 0666、0620）；此检查不构成 ACL 安全证明，也不改变普通 source 或 owner-only state 的权限规则。新文件原子写为 0600，新目录 0700；不以真实 configRoot/cwd 猜测缺失路径。source 与已有 provider 文件句柄跨 await 持有，按设备/inode 身份拒绝缓存覆盖 source、本地 provider 或其他 HTTP provider，包含文件系统实际支持的大小写/Unicode 别名，不用字符串小写化推断。不能使用内部 `.provider-cache.lock` 名称或文件身份别名。发布时复检目的身份，并记录新发布文件身份，后续缺失路径若成为其别名不得覆盖；此时允许先前输出已可见，不伪称整批回滚。rename 前失败报错；rename 后目录 fsync 失败保留已可见候选并明确提示 durability uncertain，不伪称回滚。

同步同时保留 source 16 MiB、4096 declarations/assets、raw aggregate 64 MiB、normalized 与 expanded budgets。失败 response body 也计费；无法精确获知失败传输量时保守扣除该请求剩余窗口，再检查缓存预算。冻结结果不受随后源文件/cache 编辑影响；managed source/materialization/revision 不就地刷新。

不会自动迁移旧 cwd/绝对路径缓存，也没有 curl 回退。请按上述来源根目录与相对路径要求配置缓存。

## 配置资源上界

| 对象 | 上界 |
| --- | --- |
| 配置、单 provider source | 各 16 MiB，有效 UTF-8 |
| decoded YAML collection entries | 全文 262144，包含 nested/extension map entry 与 sequence item |
| proxies / groups | 4096 / 1024；兼容 mixed `proxies:` array 最多 5120 |
| 每组 members | 5122 |
| provider declarations / captured local assets | 4096 |
| normalized provider entries | 全部合计 262144（单 provider 也不能超出） |
| normalized provider bytes / aggregate raw provider bytes | 分别 64 MiB；注释计入 raw budget |
| 展开规则 / owned payload+target bytes | 262144 / 64 MiB |
| 每 profile persisted selections | 1024；已有 catalog 超限按损坏处理 |
| catalog / revision manifest | 4 MiB / 1 MiB 独立编码上界 |
| immutable bundle aggregate | 64 MiB |

这些是同时生效的最大值，不保证达到某个局部上界时仍能绕过另一全文上界。重复 RULE-SET/target 重复计费；classical entry 用完整 normalized 长度保守预检。provider-name 索引与完整 count/byte plan 在展开 reserve/clone 前检查，资源错误不能回退 legacy line parser，也不截断或部分发布。

YAML 按“根节点之外最多 128 层”计数（最多 129 个 collection frame），block/flow 与 JSON-looking 文档共享此边界。复杂 YAML 使用受限 16 MiB 栈的解析线程，普通原生 JSON 快路径保留自身递归保护，超出该快路径的合法深度交给同样有界的 YAML parser。仍限制 events 1600000、nodes 524289、scalar 合计 16 MiB，禁 anchors/aliases/merge keys/duplicate keys。source 16 MiB+1 使用 `CONFIG_*_TOO_LARGE`，collection/provider/展开超限映射 `CONFIG_*_LIMIT_EXCEEDED`，细节见 [错误码](../api/error-codes.md)。逻辑拒绝必须保持 authority 与 revision tree 不变；存储 I/O 故障可能产生已验证但不可达对象，不能混淆。

## 控制面与支持限制

CLI/daemon/state 契约见 [CLI](../cli/spec.md)；minimal API 见 [API](../api/README.md)。连接最小版提供 `connection list/close <id>` 与 `GET /connections`、`DELETE /connections/<id>`，均要求非空运行时 secret（托管自动值或显式值）和 Bearer；这是 zc 的有界实例模型，不是 mihomo 连接详情完整兼容。

每个 mixed TCP 任务一个实例绑定 ID，UDP 关联复用控制连接 ID。运行时展开规则索引和实际 leaf 来自同一次匹配/选择；不按当前选择重新计算存量连接。HTTP forward idle 清目标与路由，下一请求再路由；UDP 仅展示首合法包元数据并标记 `first_datagram`，不伪装成每包重新路由。`routed_target` 不是实际远端 IP。DELETE 仅确认关闭请求，先取消数据面并回收 UDP worker，再删除条目；不改变 DIRECT/SS/Trojan half-close 或 AnyTLS FIN 的正常转发语义。

活动记录最多 1024，UDP 仍最多 64，无历史或逐包/逐字节 registry 更新；配置索引避免复制节点凭据，大配置及 JSON 转义计入 4 MiB 响应预算，超限完整 500。无流量计数、全部断开、分页、自动 controller、WebSocket、完整 REST v1、第三方 dashboard parity 或 TUI。

自动 secret 是 zc 的 profile 生命周期能力，不改 mihomo/clash 原始配置字节、materialization、assets 或 hash，不写入兼容 `meta.json`。订阅更新/override/选择/重命名不轮换，删除重新导入才开始新生命周期。只读操作、已运行 start（含 foreground 拒绝）和旧快照默认 restart 不升级；显式重新准备才启用。start 先取得实例启动所有权再准备，已有 daemon 时连一次性 override 也不执行，竞争失败方不写自动 key。状态校验、冻结鉴权及回退约束见 [CLI](../cli/spec.md#托管-profile-的自动-controller-secret)。

完整诊断等价性、四平台、性能和长期稳定性尚不能保证；使用成熟 TLS/DNS 库不代表已经完成这些验证。

[配置 migrator](migrator-rules-quickref.md) 是独立 lint 工具；其可识别字段/类型不代表运行时启用。机器规则词汇包括 `PORT_TYPE_INT`、`LOG_LEVEL_ENUM`、`PROXY_GROUP_TYPE_CHECK`、`DNS_FIELD_CHECK`、`DNS_NAMESERVER_FORMAT`、`PROXY_GROUP_EMPTY_PROXIES`、`TUN_ENABLE_CHECK`、`EXTERNAL_CONTROLLER_FORMAT`、`ALLOW_LAN_BIND_CONFLICT`、`RULE_PROVIDER_REF_CHECK`、`PROXY_NODE_FIELDS_CHECK`、`SS_CIPHER_ENUM_CHECK`、`VMESS_UUID_FORMAT_CHECK`、`MIXED_PORT_CONFLICT_CHECK`、`MODE_ENUM_CHECK`、`PROXY_NAME_UNIQUENESS_CHECK`、`PORT_RANGE_CHECK`、`SS_PROTOCOL_CHECK`、`VMESS_ALTERID_RANGE_CHECK`、`TROJAN_FIELDS_CHECK`、`RULES_FORMAT_CHECK`、`VLESS_FIELDS_CHECK`、`PROXY_GROUP_REF_CHECK`、`YAML_SYNTAX_CHECK`、`SUBSCRIPTION_URL_CHECK`、`WS_OPTS_FORMAT_CHECK`、`TLS_SNI_CHECK`、`UNSUPPORTED_PROXY_TYPE_CHECK`、`PORT_CONFLICT_CHECK`。

### 诊断的实际契约

`doctor` 保留配置与连接两个 gating checks：daemon stopped 合法；运行中端口不可达才使连接 check 失败。`network_ok` 仍真实探测 `1.1.1.1:443`，200 ms，但不 gating。显式/默认 `config_source` 为原来的 `custom/default`。语法/I/O 失败返回 `DIAG_DOCTOR_FAILED`，显式 override 保留对应错误码，上表兼容字段不构成配置错误；已识别的能力准入失败返回 `CONFIG_CAPABILITY_UNSUPPORTED`，不捏造字段诊断；可解析但语义无效时返回 `CHECKS_FAILED`，`config_errors` 给出具体错误，文本和 JSON 使用同一条消息，512 UTF-8 bytes 上限并明确标记截断。

`test/proxy test/profile test` 加载失败使用 `PROXY_CONFIG_LOAD_FAILED`；端口不可达时不跑外网 targets。七个默认目标、至少一个目标成功才通过 connectivity 的判定保持不变。IP/Location JSON：成功含 `ip`（无 query 时 `unknown`），不含 `latency_ms`；其他成功 target 含 latency。502 失败，403 等非 502 响应仍算连通；文本显示同一 IP/latency/reason，连接期限 5 秒、geo 总期限 90 秒、其余目标 5 秒。

诊断提供多错误汇总、支持范围内的 warnings 和原始配置迁移提示；errors/warnings 合计最多 256 条、每条 512 bytes，错误优先，省略必须显式标记。geo 文本的城市/地区附加信息及 curl 特有的底层错误细分未逐项复刻，不宣称所有诊断文字完全等价。
