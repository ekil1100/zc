# Rust AnyTLS TCP 出站：协议与独立服务端研究

## 结论与范围

**能做“每条 TCP 代理连接独占一条 TLS 连接、只承载一个 AnyTLS stream”的首版，并与固定版本官方 Go 服务端互操作；不能把它称为完整 AnyTLS 合规实现，也不能承诺透明 TCP 半关闭。** 官方协议仍要求连接复用，但官方 `anytls-go v0.0.13` 客户端已经提供 `-dr` 禁用复用，mihomo 也有 `disable-reuse`。[P][GC][MC]

本研究日期为 **2026-09-28**，zc 基线为 `8e3e85cae2e412f6d3306e0cb5e2264efdaf0403`。先阅读了 [兼容边界](../compat/mihomo-clash.md)、[Rust 迁移](../migration/rust.md) 及 [CLI 契约](../cli/spec.md)。这是新增出站的设计依据，**不是已实现或已通过 Rust 验收的声明**；当前文档中的 AnyTLS 不支持状态不变。

| 问题 | 精确结论 |
| --- | --- |
| 认证 | TLS 后发送 `SHA256(password)` 的 **32 个原始字节**，接 `padding0_len:BE16` 与对应填充；不是 hex、不是 HMAC、没有独立认证成功 ACK |
| 基本线格式 | `command:u8 + stream_id:BE32 + length:BE16 + data`，固定头 7 字节；TCP/TLS 分包不是 frame 边界 |
| 建流 | 先 `Settings`，再 `SYN(id=1)`，再 `PSH(id=1, SOCKS_ADDR)`；目标地址不在 SYN 内，也不是完整 SOCKS5 握手 |
| v1/v2 | 先按对端 v1 工作，收到 `ServerSettings(v>=2)` 才使用 v2 特性；不能等这个帧之后才发送 SYN/目标地址，也不能对 v1 强制等 SYNACK |
| 单请求独立连接 | 官方 v0.0.13 与 v0.0.5 均实测可用；此处“一请求”指一条出站 TCP 流，不是每个 HTTP 请求或每个 PSH；不讨论 TLS ticket 恢复是否启用 |
| 默认 padding 必要吗 | **对固定 Go 服务端的连通性不是必要条件**：认证零填充、会话不加 Waste 仍通过。**对官方完整行为及抗指纹目标不能省略**：规范要求初始默认方案、接收更新并用于后续新会话 |
| 关闭 | FIN 关闭整个逻辑 stream，不是单向 EOF；v0.0.13 收到 FIN 不回 FIN，session 可以继续存在 |
| 半关闭 | **不能透明支持**“上游写 EOF 后继续收响应”。发送 FIN 或关闭独占 TLS 都不能弥补协议缺少方向性关闭的事实 |
| Rust 依赖 | 有 Rust 实现，但本次没有找到已经证明满足 zc 资源、生命周期和独立互操作要求的即插即用库；优先现有 Tokio/rustls/sha2，加小型有界 AnyTLS 适配器，不引入整个代理框架 |

协议事实来自官方源码；本文的“首版建议”“建议拒绝”是 zc 的选择，不冒充协议要求。独立实测见第七节。

## 一、固定的一手来源

所有后文引用都固定至提交或包版本，不用分支首页作为协议证据。

| 来源 | 固定版本 / 提交 | 用途 |
| --- | --- | --- |
| `anytls/anytls-go` | **v0.0.13** / `9666872946857b50a74fdb692896d77b53773cb2` | 主协议、v2 服务端、官方禁用复用客户端 |
| `anytls/anytls-go` | **v0.0.5** / `bcb7b3dc0f74a2ca87c9959b1c3860c555288f1a` | 确认为仅有命令 0–6 的 v1 独立服务端；不能仅按版本号推测协议代际 |
| `MetaCubeX/mihomo` | **v1.19.31** / `ab405bad5beeeac8b003bb01f60f134f6df54471` | 客户端字段、默认 TLS 身份、padding 状态作用域 |
| `MetaCubeX/Meta-Docs` | `517f4c2303aae17eee681129bde6422e9f7a4e67` | 官方中文配置文档 |
| `SagerNet/sing` | **v0.5.1** / `8c0bf1c05e576e854cb071ca1116958df7bf6692` | Go fixture 锁定的转发、关闭实现 |

官方 v0.0.13 的协议说明把 v2 更新记在 v0.0.8，但历史 v0.0.7 源码已含 v2 命令。因此 v1 测试特意使用经 [frame.go][V1F] 核实的 v0.0.5，不用“低于 v0.0.8”判断。

## 二、认证、settings 与 framing

### 2.1 TLS 与认证

```text
TCP connect → TLS handshake
client → server: SHA256(password)[32] | padding0_len[2, BE] | padding0[N]
client → server: AnyTLS frames...
```

- 密码按字符串的原始字节求 SHA-256；不 trim、不追加换行、不转十六进制。TLS 是密码摘要及后续明文的保密/服务端身份保护层。[P][GI][MT]
- 认证没有返回码；失败可能关闭 TLS，也允许实现选择 HTTP fallback。**固定 Go 示例的 fallback 没有实现，只记日志并关闭**，不能把所有认证失败映射成一个不存在的 AnyTLS alert。[GI]
- 关键实现约束：Go 示例服务端先对 TLS **只读一次**，然后在这个缓冲区里检查完整的 32+2+N 字节；它不是对认证字段逐项 `ReadFull`。客户端必须先组织好整个认证块并一次交给 TLS，默认 N=30，总长 64 字节；不要把摘要与长度/填充分成不同 TLS 应用写入。将 32 字节摘要单独发送的负向实验确实立即 EOF。[GI][GCC]
- 这不等于底层 TCP 不能分段；TLS 可以重组 TCP 段。也不等于 AnyTLS 后续 frame 不能跨 TLS record。认证长度字段虽然是 u16，不能据此断言这个 Go 示例能接受 65535 字节的 padding0；它的单次 TLS 读取是额外互操作边界。
- 首版沿用现有 rustls 安全默认、系统根、显式 SNI 与 `skip-cert-verify` 语义，默认验证证书。官方示例临时自签证书和示例客户端的 `InsecureSkipVerify` **只适合隔离 fixture，不是生产默认值**。[GM][CERT]

### 2.2 frame 与命令

```text
0              1                    5             7
+ command:u8   + stream_id:u32 BE    + len:u16 BE   + data[len]
```

length 只计 data；单帧上限 65535 字节。应用数据大于它必须拆 PSH；不能直接把 `usize` 转成 u16 导致回绕。读取采用有界增量解析：7 字节头与完整 body 均可跨 read，单次 read 也可含多个 frame。协议没有 CRC、额外分隔符或 HTTP/2/yamux framing。[P][F][GS]

| 值 | 命令 | data / 处理 |
| --- | --- | --- |
| 0 | Waste | 任意填充，完整消费后丢弃，不交给应用 |
| 1 | SYN | 无 data；客户端建流，id 在 session 内单调递增，官方从 1 开始 |
| 2 | PSH | stream 数据；初始字节为目标地址，后续为透明应用数据；零长度不表示关闭 |
| 3 | FIN | 无 data；关闭整个 stream |
| 4 | Settings | 客户端发 UTF-8 键值文本；须先于 SYN |
| 5 | Alert | 服务端会话级错误文本；读出后关闭整个 session |
| 6 | UpdatePaddingScheme | 服务端发原始方案字节；不能当作应用数据 |
| 7 | SYNACK | v2；对应 stream_id；空 body 表示成功，非空 body 是错误，必须关闭该 stream |
| 8 | HeartRequest | v2；无 body；回复 HeartResponse，参考实现回显 stream_id |
| 9 | HeartResponse | v2；无 body；用于心跳完成，不是应用数据 |
| 10 | ServerSettings | v2；服务端版本文本，典型 `v=2` |

Settings、Alert、padding 更新与 ServerSettings 通常用 id=0；数据与建流/关流用实际 stream_id；**不要把所有控制帧都断言为 id=0**，SYNACK 与心跳有自己的 id 语义。[GS]

Settings 示例（顺序无要求，不需要末尾换行）：

```text
v=2
client=zc/1.0.1
padding-md5=75cff2ad89aadf5e257059ee571ebe11
```

解析按行分割、每行首个 `=` 分割键值。固定 Go 实现缺少非空 Settings 就收到 SYN 时发送 `Alert("client did not send its settings")` 并关闭；其宽松解析不意味着 zc 应接受任意非法版本、重复键或无限文本。实现时对 UTF-8、长度、数字溢出和状态转换定界，不复制参考代码的宽松未知命令处理造成的失步风险。[SM][GS]

### 2.3 开流、地址与成功时机

推荐初次写入顺序：

```text
认证（一个完整 TLS 写入）
Settings(0) || SYN(1) || PSH(1, SOCKS_ADDR)  （合并为 padding 包 1）
PSH(1, first_application_bytes)            （padding 包 2）
PSH(1, ...)
```

`SOCKS_ADDR = ATYP | ADDR | PORT_BE16`：IPv4 为 `01 + 4 bytes`；域名为 `03 + length:u8 + name`；IPv6 为 `04 + 16 bytes`。没有 SOCKS 版本、CMD、RSV 或 CRLF。目标地址是 stream 的首部，不要求与应用数据恰好落在某个 PSH 边界；Go 服务端从 stream 连续读取地址。[P][GI][GO]

必须主动送出地址，即使应用暂时没有数据；否则服务端无法 dial，SSH/SMTP 等“服务端先说话”协议会死锁。**不能在发地址前等 SYNACK**：官方 Go 的 ACK 在目标 TCP 握手成功之后发送。[GO][GSTREAM]

v2 Go 服务端成功返回空 SYNACK，dial 失败返回带错误文本的 SYNACK，随后关闭 stream 发 FIN。规范也允许无法得知真实出站状态的服务器提前 ACK，故不能将 ACK 当成所有服务器都已端到端连接成功的保证。[P][GO]

### 2.4 v1/v2 协商

| 客户端 / 服务端 | 线行为 |
| --- | --- |
| v1 / v2 | 客户端 `v=1`；服务器不发 ServerSettings/SYNACK，按 v1 转发 |
| v2 / v1 | 客户端可以发送 `v=2`；旧服务端不返回 ServerSettings，仍可用 Settings/SYN/PSH/FIN 转发 |
| v2 / v2 | 服务端收到 Settings 后返回 `ServerSettings(v=2)`；建流结果用 SYNACK；可使用心跳 |

“没有收到 ServerSettings”没有一个可靠的即时判定点：既可能是 v1，也可能是网络慢。**不能通过永久等它来识别 v1，不能因短等待超时就认定服务端认证失败。** 官方客户端先发流量；新 session 的首条 stream 也不强制等待 ACK，它只对复用 session 的后续 stream 在已知 v2 时设置 3 秒 SYNACK 看门狗。[P][GS]

首版建议沿用这种乐观开流：写完认证、Settings、SYN、地址便可交付流接口，接收路径持续处理服务端控制帧及错误。明确它不提供统一的“远端 dial 已成功”同步保证；晚到的 SYNACK 错误必须成为该流错误，不是普通 EOF。这样不需要猜测版本，也兼容 v1；如产品要求 HTTP CONNECT 成功之前一定拿到远端成功证明，应另行决定只支持 v2，而不是偷偷破坏 v1 或无限等待。

## 三、padding：连通性与完整行为不是一回事

### 3.1 默认方案及算法边界

官方默认原始字节如下：UTF-8/ASCII、LF 分行、**最后一行没有 LF**。其 MD5 小写 hex 为 `75cff2ad89aadf5e257059ee571ebe11`；MD5 仅用于方案指纹，不是安全认证。[PAD]

```text
stop=8
0=30-30
1=100-400
2=400-500,c,500-1000,c,500-1000,c,500-1000,c,500-1000
3=9-9,500-1000
4=500-1000
5=500-1000
6=500-1000
7=500-1000
```

- 包 0 为认证填充，取第一个尺寸，不分包；默认 30 字节，零字节内容即可。
- 包 1 是合并的 Settings+SYN+地址，包 2 是首个应用数据。这里的“包”是会话写入/填充分组，不是 IP 包、read 次数或 PSH 数；一个分组可以导致多次底层 TLS Write。
- `stop=8`：只处理 0–7，8 起停止填充。没有对应条目的分组直接发送。
- `c`：若上一片之后没有真实数据剩余，本次停止，不再发送后续纯填充片。
- 参考随机数生成对 `min<max` 取 **[min,max)**；两者相等时固定值。不要自行假定上限闭区间。
- 剩余真实字节超过计划尺寸时先切片，frame 头/body 都可能被切开；真实数据不足且余量大于 7 时，追加一个完整 Waste 头及填充；小于等于 7 的差额不会用裸零补齐。
- **文档与参考实现有尺寸细节差异**：`writeConn` 在“纯填充片”分支把抽到的 l 当 Waste 的 body 长度，所以实际 TLS 明文是 **l+7**，而非 l；“真实数据+Waste”分支才试图凑到 l。实现和字节测试应以这个固定参考行为为明确对照，不能泛称“所有 TLS record 均精确命中方案尺寸”。TLS 栈还可能拆分大写入，Rust 的实际 record 形状必须另测。[P][PAD][GS]

### 3.2 服务器更新与必要性

服务器比对 Settings 的 `padding-md5` 与自己的原始方案；不一致时下发命令 6。固定 Go 服务端**不检验客户端实际是否按该尺寸填充**，也不因认证填充为 0 或缺少 Waste 拒绝。这是无 padding 实测能通的原因，不是协议允许永久忽略 padding 的证据。[GI][GS]

规范要求：首次用默认方案，收到更新后，**连接到同一服务器的客户端对象**存储新方案，后续新 session 必须使用它。不能把“首版不复用 TLS”误解成“完全没有跨连接状态”；padding 方案仍需要每节点共享、线程安全地保存。mihomo 用每 Client 的原子方案指针；官方 Go 示例的全局 DefaultPaddingFactory 不适合直接照搬为多节点全局状态。[P][MT][MP]

建议每个 session 使用打开时的方案快照，更新作用于下一条 session，避免正在写的分组被异步换方案。先完整消费并有界校验候选，再原子替换；MD5 对原始字节计算，不能先 trim 或重排行。Go 参考代码较宽松，zc 应明确限制 stop、条目/分片数、每片尺寸及总开销，拒绝溢出和资源攻击；这些限制是待实现的本地策略，不是额外线协议字段。

**首版决策建议：**

1. 仅为验证 TCP 管线的实验切片可以暂时不填充，但必须标为有限互操作实验，不能发布为完整 AnyTLS。
2. 可交付首版保留默认 padding、Waste 接收及服务器更新，不增加用户自定义 padding 配置；这样保留 AnyTLS 的主要目的，也避免所有后续新连接反复暴露过时默认特征。
3. 不做连接池可以作为明确的首版兼容例外；不能再把“只接受默认方案、静默忽略更新”包装成正常支持。若暂时实现不了更新，应明确失败/限制支持范围，不伪报正确的 MD5。
4. 本次零填充探针在部分用例里仍上报默认 MD5，**是用于测量服务端是否检查填充的故意不合规实验**，不能照搬到生产。

## 四、stream 关闭、server error 与 EOF

### 4.1 FIN 不是半关闭

官方 v0.0.13 `recvLoop` 收到 FIN 会把 stream 从映射移除，再 `closeLocally()`；后者关闭读管道并标记 stream 不可写。不等待对端另一个 FIN，也不回复 FIN。session 关闭则关闭全部 stream，毋须逐条 FIN。[GS][GSTREAM]

Go 服务端目标转发使用 sing v0.5.1 `CopyConn`。AnyTLS stream 没有 `CloseWrite()`；stream 关闭产生的错误会关闭目标 TCP，而不是创建一个还能反向读的 AnyTLS 半关闭通道。[GO][COPY]

因此：

- 入站写侧 EOF → 可以排空已经接受的应用字节，再发送 **一次** FIN，随后结束这个独占 session；这是**整流关闭降级**，不是保留原有 DIRECT 半关闭能力。
- 收到远端 FIN → 已完整收到、已排队的 PSH 必须按序交付，然后向应用报 EOF，并拒绝后续写入；不回 FIN、不无限等 FIN 回包。
- 收到本地 FIN 后依赖目标 EOF 才生成的响应，无法保证返回。实测目标确实收到 EOF，但其之后的响应没有回到客户端。
- 不可以通过“不发 FIN、一直等”假装支持半关闭：需要 EOF 才响应的目标会死锁；也不能用 TLS `close_notify` 代替一个不存在的方向性 AnyTLS FIN。
- 首版应在 AnyTLS 专用适配层处理这个终态，不修改所有代理通用的半关闭行为。取消、异常、timeout 必须回收 TLS、任务与队列；不能等到 15 分钟空闲期限才完成本地 EOF。

### 4.2 错误分类

| 事件 | 协议 / 参考行为 | zc 建议 |
| --- | --- | --- |
| 错密码、认证块不完整 | 固定 Go 直接关闭；没有认证错误 ACK | 报认证/握手阶段连接失败；不能仅凭 EOF 断言一定是错密码 |
| Alert | 服务器会话级拒绝，可能说明不接受某类实现 | 完整消费，脱敏、限长、清理控制字符后处理诊断；终止 session，不回退 DIRECT |
| 非空 SYNACK | v2 远端开流错误 | 对应流报错，不能当作正常 EOF 或把文本交给应用；拒绝自动重放请求 |
| v1 目标 dial 失败 | 没有 SYNACK 错误文本，通常只有 FIN | 说明原因信息缺失；不能伪造已知的 DNS/拒绝连接分类 |
| 正常 FIN | 逻辑流结束，session 可活着 | 交付此前完整数据再 EOF；单流首版自行回收 session |
| TLS/传输 EOF，无 FIN | 参考读循环退出并关闭所有流；不返回结构化原因 | 首版建议对尚未关闭的流报异常 session 中断，不伪造成有序 FIN |
| 头或 body 中途 EOF | `ReadFull` 失败，session 终止 | 明确协议截断错误；不得丢弃半帧后继续解析 |
| 未知命令、错误方向/长度/id | 官方 Go 部分分支宽松且不会消费非法 body | 有界读取、显式拒绝；不复制可造成 framing 失步的宽松行为 |

EOF 严格性是 zc 的本地安全选择：在帧边界断开也不必然证明代理流正常完成；TLS 证书错误、缺少合法 TLS 关闭等继续由 rustls 判断，不能启用统一“容忍截断”来掩盖协议错误。普通 session EOF 的行为没有在本次实验中做所有注入组合，不能把以上建议当成已经写好的 Rust 实现。

官方要求打印 Alert 文本，但 zc 现有稳定性日志不接受远端原始错误/目标/凭据；落地时须采用有界分类与受控诊断，不能把服务端可控字符串直接送入常规日志。[P][CLI]

## 五、mihomo 配置与首版可用范围

固定 mihomo 的真实字段由 `AnyTLSOption` 定义，不只看网页示例。[MC][MD]

| 字段 / 能力 | mihomo 行为 | zc 首版建议 |
| --- | --- | --- |
| `type/name/server/port/password` | AnyTLS 基本参数 | 支持并沿用现有严格字段/目标校验 |
| `sni` | 空时以 server 为 TLS Host | 沿用当前 Trojan 的更严格身份规则，明确 IP server 与显式 DNS SNI 边界 |
| `skip-cert-verify` | 可显式关闭证书验证 | 默认 false；仅显式 true 降级，仍验证握手签名 |
| `udp` | 通过 UoT v2，非原生 UDP | 首版仅允许缺省/false；true 明确拒绝，不偷偷关闭功能 |
| `idle-session-check-interval` | 秒；默认 30 | 无连接池时不可假装生效；首版建议拒绝显式配置并说明未支持复用 |
| `idle-session-timeout` | 秒；默认 30 | 同上 |
| `min-idle-session` | 默认 0 | 同上；不是“预先建立 n 个连接” |
| `disable-reuse` | 源码确实支持，默认 false；网页字段列表未完整列出 | 如暴露此字段，仅接受 true；缺省也不复用，并清楚说明与 mihomo 默认不同；false 请求未实现能力，应拒绝 |
| `client-metadata` | v1.19.30 起默认空；实际 `client=` 仍写入 Settings | 首版不新增自由元数据入口，发真实 `zc/<版本>`；这是与 mihomo 的明确差异 |
| `alpn`、指纹、ECH、证书 pin、mTLS、ShadowTLS/ResTLS/JLS 等 | 固定版本包含相应 TLS 扩展选项 | 首版不支持，显式声明须拒绝，不能只解析却不执行 |

上述字段准入是建议，不是本轮修改。mihomo 示例里的 `client-fingerprint: chrome`、`udp:true`、`skip-cert-verify:true` **不是 zc 的默认需求**；AnyTLS 的 TLS 层并不要求 HTTP/2、ALPN 或浏览器指纹。UoT 的特殊目标 `sp.v2.udp-over-tcp.arpa` 也不是普通 TCP 首版要引入的协议框架。[P][MC]

建议的最小交付切片：

1. 原生 TLS/TCP；IPv4、IPv6、域名目标；每条出站一个 session、id=1；无连接池、无并发多 stream、无 UDP。
2. 实现命令 0–10 所需的客户端处理；不主动开启空闲心跳计时器，但收到合法 v2 HeartRequest 必须响应。不支持的方向/命令明确报错。
3. 默认 padding + 每节点服务器更新状态；发送有界、串行化，控制帧与数据不能交错损坏线格式。
4. 接到现有 `outbound::BoxStream` / `AsyncRead + AsyncWrite` seam；TLS 验证、目标规范化、系统 DNS、路由后固定地址、连接预算、10 秒出站准备期限沿用当前路径，不建立第二套拨号/DNS/TLS 框架。
5. 接收持续推进控制帧，发送有背压；缓冲和任务数有上界。应用慢读不能让无限 PSH 排队，取消要打断所有 await；不能仅靠接口看起来像 AsyncRead/AsyncWrite 就认为资源安全。
6. CLI/minimal API 使用同一 `proxy` 模型，能力不支持时准备阶段失败；不触碰状态 schema、不回退 DIRECT、不调用历史 Zig。
7. 合入实现时同步更新兼容文档与迁移文档，标明**不复用、FIN 非半关闭、乐观开流、未支持字段**；本轮按任务限定只写本研究。

验收不是“能编译”：先做线字节/状态机测试，再跑独立 Go 服务端的真实 SOCKS5/HTTP CONNECT 出站路径；覆盖错误密码、证书验证、错误地址、超长/截断帧、目标失败、服务端先发、EOF 后响应、取消/背压及资源释放。性能比较至少包含首次连接与大量短连接，因为不复用必然失去避免新 TCP/TLS 建连的收益；不宣称等价性能或抗审查有效性。

## 六、Rust 实现与依赖选择

检索了 crates.io 的 `anytls` 查询以及各库作者仓库的源码/清单；注册表检索只是发现入口，以下判断固定到作者提交。**“有实现”“近期有更新”“成熟且符合本项目”是三个不同结论。** 没有因某个库星数或版本号而认定其可靠，也没有把任何 Rust 库当协议 oracle。

| 候选 | 固定源码 | 核查与结论 |
| --- | --- | --- |
| `anytls` 0.4.2，ssrlive | `51b22ad4e739ac9829fe65e8ae35556209747597` | 最近提交为 2026-09-27；有 `core/runtime/client/server` 特性、可注入 `BoxTransport`、`StreamIo`，是真正可集成候选，不是不存在库。**但**接收每 stream 的 `Vec<u8>` 走 `unbounded_channel`，与 zc 有界资源要求冲突；FIN 状态机同时跟踪 local/remote FIN，并有等待对端关闭的语义，需要重新核对官方“不回复 FIN”及整流关闭。`client` 特性还带 UoT、CLI、SOCKS 等依赖。暂不直接引入。[RS1][RS1IO] |
| `anytls-rs` 0.5.4，jxo-me | `f09613e0102d611b1a850913e1269fe76dfc36cf` | 最近固定提交为 2025-11-12；客户端/服务端/TLS/证书热加载/独立 DNS 等一起暴露，依赖不可简单裁成一个薄 codec；仅凭现有证据无法确认持续维护可靠。meow 自己也记录了上游 0.5.4 缺少其所需 `Stream::close()` 的问题。不是首版默认选择。[RS2][RS3README] |
| `meow-anytls`，仓库清单 0.21.2 | `866a171adc3c13176ac156c0eb773be48fa560c0` | 维护中的内置 fork，默认客户端 TLS 可由宿主注入，不应误称强制 BoringSSL；但直接依赖 `meow-common`，自带 DNS/池等机制，项目更新与宿主工作区耦合。此处评估的是该提交，不假定已发布的同版本包内容完全相同。暂不为单流功能引入其宿主依赖。[RS3] |
| `cfal/shoes`，清单 0.2.8 | `60ed3838b346268615c81e4eace4e15e717da23e` | 多协议项目有 AnyTLS 实现与集成测试，可作对照阅读；依赖包含 QUIC/TUN/HTTP 等广泛框架，许多版本用 `*`；不是一个独立、最小 AnyTLS 出站库。[RS4] |

**推荐：现有成熟底层依赖 + 有界的小型专用协议层。** 当前 `Cargo.lock` 已有：

- `tokio 1.53.1`、`tokio-rustls 0.26.5`、`rustls 0.23.45`：取消、网络与 TLS，继续复用 zc 现有连接器及校验，不改用库内自建 TLS/DNS。
- `sha2 0.10.9`：新增使用 `Sha256` 即可；已有 `getrandom` 可生成 padding 随机长度，范围抽样避免简单取模偏差。
- `shadowsocks 1.25.0` 的 SOCKS 地址类型/编码：先检查现有公开 API 能否直接复用；不要为了三个地址类型引入完整 SOCKS 代理框架。
- 方案 MD5 所需的 RustCrypto **`md-5 0.11.0` 已在 Cargo.lock 中，由 shadowsocks 间接引入**。若需要在 zc 中直接调用，仍须在 Cargo.toml 声明直接依赖；这不是“现有依赖可以无声明随便用”。推荐显式复用这个锁定版本，不自写 MD5，不只硬编码默认摘要而无法处理更新。其 `digest 0.11` 与 sha2 0.10 的 trait 版本不同，分别导入对应 `Digest`，不要假定可混用。[LOCK]

本轮未修改 Cargo.toml/lock，也未编译评测上述 Rust 候选；因此不能给出它们的 MSRV、四平台、长稳、安全审计通过结论。若后续决定引库，必须先以独立 Go fixture 验证 FIN、padding 更新、背压和取消，而不是只跑 Rust 客户端对同库 Rust 服务端。

## 七、独立 Go 服务端 fixture 与实测

### 7.1 获取与构建

独立 oracle 为官方未修改的 `cmd/server`：主用 **v0.0.13**，v1 对照 **v0.0.5**。服务端转发依赖锁定 `github.com/sagernet/sing v0.5.1`，构建使用上游 go.mod/go.sum，`-mod=readonly`。v0.0.13 要求 Go 1.24.0 或以上；本机实际用官方 **Go 1.27.1 / darwin-arm64**，没有安装到用户全局目录。[GMOD]

以下在仓库根目录用 Bash 执行。两版本均使用官方固定提交的 codeload 源码归档，先验证归档 SHA-256，再用同一构建流程处理。明确设置 `-buildvcs=false`，避免无 `.git` 的归档源码向上查找并嵌入 zc 的 HEAD/dirty 状态；`-trimpath` 排除路径差异。来源由固定提交、归档 SHA、上游 go.mod/go.sum 和构建清单证明，不依赖二进制里的 VCS 字段，也不取消二进制 SHA 门禁。

先准备隔离工具链；已有经校验的 `target/anytls-reference/go` 可直接复用，不安装全局 Go。归档 SHA-256 来自 [Go 官方下载元数据][GODL]。这里固定 Go 1.27.1 / darwin-arm64，不接受任意“Go >= 1.24”；其他平台必须单独审查。

```bash
set -eu
R="$PWD/target/anytls-reference"
mkdir -p "$R/home"
HOME="$R/home" curl -q -fL https://go.dev/dl/go1.27.1.darwin-arm64.tar.gz \
  -o "$R/go1.27.1.darwin-arm64.tar.gz"
printf '%s  %s\n' \
  ee215d57e0ec269c60cc9ceca68e6bda321ba9ee5afe24f4b0988703c2d87d12 \
  "$R/go1.27.1.darwin-arm64.tar.gz" | shasum -a 256 -c -
tar -xzf "$R/go1.27.1.darwin-arm64.tar.gz" -C "$R"
```

构建命令如下。默认输出供 `just anytls-e2e` 使用；也可通过环境变量 `R` 指定全新的绝对路径，并将它传给 `run-anytls.py`。`src/<version>` 必须不存在，重复验证请换目录，不自动删除已有源码。`env -i`、临时 HOME 和 `GOENV=off` 避免读取真实 HOME、用户 Go 配置及继承的构建 flags；禁用 CGO 固定目标架构，排除本机 C 工具链差异。源码、缓存和临时文件都留在 `R` 内。

```bash
set -eu
ROOT="$(pwd)"
R="${R:-$ROOT/target/anytls-reference}"
GO="$ROOT/target/anytls-reference/go/bin/go"
mkdir -p "$R"/{home,bin,archives,src,gocache,gomodcache,gopath,tmp}
export HOME="$R/home"
export TMPDIR="$R/tmp"
build_go() {
  env -i PATH=/usr/bin:/bin HOME="$HOME" TMPDIR="$TMPDIR" \
    GOPATH="$R/gopath" GOCACHE="$R/gocache" GOMODCACHE="$R/gomodcache" \
    GOENV=off GOTOOLCHAIN=local GOPROXY=https://proxy.golang.org GOSUMDB=sum.golang.org \
    CGO_ENABLED=0 GOOS=darwin GOARCH=arm64 GOARM64=v8.0 \
    "$GO" "$@"
}
test "$(build_go version)" = 'go version go1.27.1 darwin/arm64'
while read -r version commit archive_sha; do
  archive="$R/archives/$version.tar.gz"
  if [ ! -f "$archive" ]; then
    curl -q -fL "https://codeload.github.com/anytls/anytls-go/tar.gz/$commit" -o "$archive"
  fi
  printf '%s  %s\n' "$archive_sha" "$archive" | shasum -a 256 -c -
  mkdir "$R/src/$version"
  tar -xzf "$archive" --strip-components=1 -C "$R/src/$version"
  (
    cd "$R/src/$version"
    build_go build -mod=readonly -trimpath -buildvcs=false \
      -o "$R/bin/anytls-server-$version" ./cmd/server
    if [ "$version" = v0.0.13 ]; then
      build_go build -mod=readonly -trimpath -buildvcs=false \
        -o "$R/bin/anytls-client-$version" ./cmd/client
    fi
  )
  build_go version -m "$R/bin/anytls-server-$version"
  shasum -a 256 "$R/bin/anytls-server-$version"
done <<'PINS'
v0.0.13 9666872946857b50a74fdb692896d77b53773cb2 53806a6373492066390e9ba4cdfef065d5b426904b91506b349a9e172d27d9b1
v0.0.5 bcb7b3dc0f74a2ca87c9959b1c3860c555288f1a 63d77535f2faa3ef1417ad3c44fbc3c321c9a2c281d7d37b9a17007b1b8c9b82
PINS
```

`testdata/e2e/anytls-fixtures.json` 同时固定两个服务端的来源、归档 SHA、工具链 SHA、flags 和最终二进制 SHA。Go 模块仍由上游 go.sum 验证；若网络不可用，可将已缓存的 `target/anytls-reference/gomodcache/cache` 复制到新 `R/gomodcache/`（仅模块下载缓存，不复制源码或编译缓存），校验不放宽。

本轮重建证据位于 `target/anytls-reference/loop-round1/fixture-fix/`：

- `evidence/fixture-repro.log`、`evidence/fixture-gate.log` 保留原始失败；旧 v0.0.5 嵌入了 zc VCS 信息。
- `build.sh`、`build.log` 记录上述同一流程及 Go 构建信息；`archives/` 为固定原始来源。模块直连超时记录在 `evidence/dependency-network-failure.log`，随后仅复用了已校验的模块下载缓存。
- `parent-clean.log`、`parent-dirty.log` 与 `build-clean.log`、`build-dirty.log`：在隔离父 Git 仓库的干净/有未跟踪文件状态下，从同一原始归档向两个不同路径重建；`reproducibility.log` 证明两版本与 zc dirty 工作区内的初次构建均逐字节一致。
- `evidence/gate-before.log`、`evidence/gate-after.log` 调用原 runner 的 SHA 校验，校验后立即中止，不启动网络互通；不能据此宣称完整 E2E PASS。
- 本轮供最终互通使用的实际产物为 `target/anytls-reference/loop-round1/fixture-fix/bin/anytls-server-v0.0.13`、`anytls-server-v0.0.5`；另有 `anytls-client-v0.0.13`。传入 fixture 根目录 `target/anytls-reference/loop-round1/fixture-fix`，不是 `bin`。

### 7.2 独立运行方式

三个终端分别运行；只绑定 loopback。端口冲突直接失败，不寻找其他端口、不访问生产 7899。密码为公开的 fixture 专用字符串：

```bash
R="$PWD/target/anytls-reference"
HOME="$R/home" LOG_LEVEL=debug "$R/bin/anytls-server-v0.0.13" \
  -l 127.0.0.1:18443 -p anytls-fixture-only
```

```bash
R="$PWD/target/anytls-reference"
HOME="$R/home" LOG_LEVEL=debug "$R/bin/anytls-server-v0.0.5" \
  -l 127.0.0.1:18444 -p anytls-fixture-only
```

```bash
R="$PWD/target/anytls-reference"
HOME="$R/home" CLIENT_DEBUG_SESSION_POOL=1 "$R/bin/anytls-client-v0.0.13" \
  -l 127.0.0.1:18080 -s 127.0.0.1:18443 -p anytls-fixture-only -dr
```

服务端没有 `--cert/--key` 参数，每次启动生成短期自签证书。官方客户端默认跳过验证，所以能连上。未来 Rust 的负向证书用例必须证明默认验证会拒绝它；正向可信 CA/SNI 用例需要另一份独立 Go TLS 包装 fixture 或固定的 mihomo/sing-box 服务端，不能假装原示例已支持证书文件。[GM][CERT][GC]

无需 zc 的最小人工冒烟：另开隔离 HTTP origin 后经官方 SOCKS 客户端请求两次，检查日志的 `cumulative session: 2 cumulative stream: 2 avg: 1`。不要在已运行自动探针时同时开这些端口：

```bash
R="$PWD/target/anytls-reference"
mkdir -p "$R/http-root"
printf 'anytls-fixture-ok\n' > "$R/http-root/probe.txt"
python3 -m http.server 18081 --bind 127.0.0.1 --directory "$R/http-root"
```

```bash
for i in 1 2; do
  curl --fail --max-time 5 --noproxy '' \
    --proxy socks5h://127.0.0.1:18080 http://127.0.0.1:18081/probe.txt
done
```

每条 curl 都新建代理 TCP 流；官方客户端 `-dr` + 默认 padding + 官方服务端即构成不依赖 Rust 的独立冒烟。固定上游行为是 oracle，不以 zc 自己生成的响应作为正确性答案。

### 7.3 本次已执行的验证

实际执行的是临时 Python 标准库 TLS 线协议探针及官方 Go 客户端冒烟；只连 loopback 的 Go fixtures 和临时 TCP origin。未启动 zc，未打开真实用户配置/实例，未连接生产端口。探针发送字节依据第二节结构，服务端保持上游原样；Python 不是另一套用来证明自身正确的服务端。

临时证据均在 `target/anytls-reference/`（不是提交文件）：

- `probe.py`、`probe-results.json`、`probe-output.txt`：**15 个用例通过**；脚本 SHA-256 为 `b0edb12258b1b0cfdbe7d08cc53e027a849c774b0e8ea978ce8fff679893b2cb`。
- `official-client-smoke.py` 与 `anytls-client-v0.0.13-smoke.log`：官方客户端 `-dr` 的两个 stream 分别用两个 session，默认 padding 路径通过。
- `build-v0.0.13.txt`：实际二进制嵌入 `vcs.revision=9666872946857b50a74fdb692896d77b53773cb2`、`vcs.modified=false`。
- `server-v0.0.13.log`、`server-v0.0.5.log`：参考服务端日志。自动探针通过 `finally` 终止并等待自己启动的进程，不保留后台服务。

| 探针 | 实际观察 |
| --- | --- |
| 两次独立 TLS 会话，各只开 id=1 | 各回显 262144 字节，接收命令 10/7/2；没有客户端会话池 |
| 第二次认证 padding0=0，所有会话不发 Waste | 仍正常转发；证明固定服务器不强制检查 padding，不证明完整合规 |
| domain `localhost`、IPv6 `::1` | 各通过 262144 字节回显；IPv4 由其他用例覆盖 |
| 会话帧逐字节 TLS 写入 | 服务端重组成功；完整认证仍单独一次发送 |
| 上报空 padding MD5 | 接收完整命令 6 的默认方案，随后正常 10/7/2；没有验证 Rust 动态采用更新 |
| 客户端 v=1 / v2 服务端 | 只有 PSH 数据，没有 ServerSettings/SYNACK |
| 客户端 v=2 / v1 服务端 | 同上，262144 字节回显通过 |
| 目标连接失败（v2） | 命令顺序 10、非空 7、3；远端错误不混入数据 |
| 目标连接失败（v1） | 只有 FIN，没有远端错误文本 |
| 不发 Settings 直接 SYN | Alert 文本精确为 `client did not send its settings`，然后 TLS EOF |
| 错密码 | TLS EOF，没有 Alert |
| 认证只先写摘要 32 字节 | TLS EOF，确认官方单次认证读取限制 |
| 目标先发 `server-first` 后关闭 | 10/7/2/3，客户端在 FIN 后仍能用心跳证明 session 存活 |
| 客户端 PSH 后 FIN，目标等 EOF 才响应 | 目标收到请求及 EOF；无响应 PSH、无 FIN 回包；心跳仍成功 |

“目标连接失败”用绑定但不 listen 的本地 TCP 端口避免误连其他进程；在本机 macOS 观察到的是服务端 **5 秒 dial timeout**，不是即时 connection refused。探针旧标签含 `target-refused`，应以上述实际日志为准，不把它当成精确的 ECONNREFUSED 测试。大数据逐块发送并读取回显，不是吞吐/并发性能测试。

这些临时脚本可在本工作区重复执行；清理 target 后不再存在。第 7.1–7.2 节完整保留了重新获取、构建、启动官方 fixture 与不依赖临时脚本的最小冒烟方法；后续实现应把所需探针整理成正式 E2E，而不是把 target 当长期证据仓库。

## 八、未解决项与准入条件

1. **完整规范合规性**：不复用是本次明确建议的首版偏离。虽然固定 Go 与 mihomo 都有禁用复用路径，规范仍允许服务器拒绝不正确实现复用/更新的客户端；无法保证所有商业部署接受，需要目标服务端矩阵，但本任务不授权访问真实节点。
2. **padding 与 TLS record 形状**：默认 Go 客户端冒烟通过；Rust 对默认方案、非默认更新、随机分片和 rustls 实际 record 的实现尚不存在，抗指纹效果未证明。纯填充分支的 l+7 差异必须在验收中明确采用哪一种行为。
3. **同步开流错误体验**：建议 v1/v2 兼容的乐观开流；如果必须向入站返回精确的远端连接成功/失败，应决定 v2-only 门槛及 ACK deadline，不能含糊地同时承诺 v1 兼容和强 ACK。
4. **半关闭**：这是协议能力边界，不是将来在 Rust `poll_shutdown` 中简单补齐的功能；依赖 EOF 后响应的 TCP 应用不在透明支持承诺内。
5. **Rust 生命周期与攻击面**：FIN 前排队数据、所有截断点、恶意控制帧、慢读/慢写、取消、Drop、队列/任务/内存预算尚须真正实现与测试；没有给候选 Rust 库做完整审计或四平台构建。
6. **TLS 可信链/SNI/ALPN**：本次参考 Go 示例使用自签证书；可信证书正向、证书/SNI 负向、TLS 关闭截断等要用独立可控证书 fixture 补齐。
7. **性能与发布**：不复用的短连接延迟/CPU 成本、四平台、长稳、Rust 真实 CLI/HTTP/SOCKS 端到端仍未验收；本次只证明所列官方 fixture 行为，不代表 AnyTLS 已接入或可发布。

## 固定源码索引

[P]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/docs/protocol.md
[F]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/proxy/session/frame.go#L7-L49
[GI]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/cmd/server/inbound_tcp.go#L20-L89
[GM]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/cmd/server/main.go#L20-L78
[GO]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/cmd/server/outbound_tcp.go#L16-L30
[GS]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/proxy/session/session.go
[GSTREAM]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/proxy/session/stream.go#L39-L163
[GC]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/cmd/client/main.go#L20-L95
[GCC]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/cmd/client/myclient.go#L29-L67
[PAD]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/proxy/padding/padding.go#L17-L95
[SM]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/util/string_map.go
[CERT]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/util/mkcert.go
[GMOD]: https://github.com/anytls/anytls-go/blob/9666872946857b50a74fdb692896d77b53773cb2/go.mod
[V1F]: https://github.com/anytls/anytls-go/blob/bcb7b3dc0f74a2ca87c9959b1c3860c555288f1a/proxy/session/frame.go
[COPY]: https://github.com/SagerNet/sing/blob/8c0bf1c05e576e854cb071ca1116958df7bf6692/common/bufio/copy.go#L159-L196
[MC]: https://github.com/MetaCubeX/mihomo/blob/ab405bad5beeeac8b003bb01f60f134f6df54471/adapter/outbound/anytls.go#L27-L175
[MT]: https://github.com/MetaCubeX/mihomo/blob/ab405bad5beeeac8b003bb01f60f134f6df54471/transport/anytls/client.go#L32-L98
[MP]: https://github.com/MetaCubeX/mihomo/blob/ab405bad5beeeac8b003bb01f60f134f6df54471/transport/anytls/padding/padding.go
[MD]: https://github.com/MetaCubeX/Meta-Docs/blob/517f4c2303aae17eee681129bde6422e9f7a4e67/docs/config/proxies/anytls.md
[RS1]: https://github.com/ssrlive/anytls-rs/blob/51b22ad4e739ac9829fe65e8ae35556209747597/Cargo.toml
[RS1IO]: https://github.com/ssrlive/anytls-rs/blob/51b22ad4e739ac9829fe65e8ae35556209747597/src/runtime/session.rs
[RS2]: https://github.com/jxo-me/anytls-rs/blob/f09613e0102d611b1a850913e1269fe76dfc36cf/Cargo.toml
[RS3]: https://github.com/meow-rs/meow-rs/blob/866a171adc3c13176ac156c0eb773be48fa560c0/crates/meow-anytls/Cargo.toml
[RS3README]: https://github.com/meow-rs/meow-rs/blob/866a171adc3c13176ac156c0eb773be48fa560c0/crates/meow-anytls/README.md
[RS4]: https://github.com/cfal/shoes/blob/60ed3838b346268615c81e4eace4e15e717da23e/Cargo.toml
[GODL]: https://go.dev/dl/#go1.27.1
[LOCK]: ../../Cargo.lock
[CLI]: ../cli/spec.md#稳定性日志

## 后续实现与生命周期修复说明

本文前述研究和建议保留为实现前记录。首版实现后，独立核查实际复现了第四节要求中的三个缺口：心跳写背压阻断读取、FIN 后迟到上行使通用中继丢下行、FIN 后中继继续等待入站 EOF。修复后通过可选整流终态通知停止上行并排尽下行；心跳队列有硬上限且不再以写完成作为继续读的前提。该通知也经 HTTP forward 和 HTTPS 包裹层传递，不放宽其他协议半关闭或 TLS 错误。

当前实现边界以 [兼容说明](../compat/mihomo-clash.md#anytls单流原生-tlstcp) 为准；修复前后结果分别保留于 [迁移验收](../migration/rust.md#anytls-生命周期修复后的定向验收)。首版 216 项不能替代生命周期回归；修复后定向 Rust 224 项通过、五分钟 UDP idle 未跑，固定 Go 两版及 OpenSSL 重新通过，仍未证明四平台、性能或长稳。
