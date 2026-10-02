# zc minimal API

当前实现位于 `src/api.rs`，daemon 的持久 identity/CAS 位于 `src/daemon.rs`。这是 **minimal API**，不是完整 REST API v1 或 mihomo dashboard 兼容接口。

## 启用与鉴权

配置 `external-controller` 时启动，只接受精确 `127.0.0.1:<port>`；端口占用即启动失败，不换端口、不静默关闭。示例仅定义 controller，开发启动另传 `--port 17890`，避免生产默认 7899：

```yaml
external-controller: 127.0.0.1:19090
secret: replace-with-a-random-secret
rules:
  - MATCH,DIRECT
```

非空 `secret` 使所有 PUT 要求 `Authorization: Bearer <secret>`，缺失/错误返回 401；原有只读端点仍不要求 Bearer。连接详情敏感，`GET /connections`、`DELETE /connections/<id>` 及下述 `/connections/probes` 诊断票据端点 **必须具有非空运行时 secret 并使用 Bearer**：未配置返回 403，缺失或错误 Bearer 返回 401。loopback 不是多用户授权边界；非托管配置应始终配置随机 secret，不要把原有只读接口视为私密信息通道。

托管 profile 在首次实际运行准备时，若已有 controller 而 secret 缺失/为空，会自动生成并持久保存 64 位小写 hex secret；显式非空 secret 优先，自动值保留供以后复用。CLI connection/selection 从认证运行快照取实际值，无需用户复制 key；订阅更新、override、选择和重命名不轮换。key 不进入普通 dump、日志或兼容镜像；非托管 `-c` 文件仍须手工配置。

不自动配置 controller 或任何默认控制端口。旧快照、默认 restart 和已运行 start 不补认证；托管升级须显式 `zc restart -c <profile>`。带自动 secret 的快照使用 schema 2，读取严格鉴权、校验完整 overlay；不使用当前 active/head 的 key 代替运行快照。持久性未确认时拒绝新准备并保留旧实例；完整生命周期见 [CLI 契约](../cli/spec.md#托管-profile-的自动-controller-secret)。Bearer 与实例 nonce 规则不变。

## 端点

| 方法 | 路径 | 行为 |
| --- | --- | --- |
| GET | `/` | hello/version |
| GET | `/version` | 版本 |
| GET | `/proxies` | 配置节点 |
| GET | `/rules` | 配置规则 |
| GET | `/connections` | 当前活动连接快照；强制鉴权，格式见下节 |
| DELETE | `/connections/<id>` | 请求关闭指定连接；强制鉴权和实例身份检查 |
| PUT | `/connections/probes` | 预约单次诊断请求票据，body 为 `{host,port}`；强制鉴权及实例请求头 |
| GET | `/connections/probes/<token>` | 读取本次请求已记录的实际 leaf；强制鉴权及实例请求头 |
| DELETE | `/connections/probes/<token>` | 释放票据及其证据；强制鉴权及实例请求头 |
| GET | `/status` | 实际运行 config identity 与当前 group selections；`selected_proxies` 按运行配置的代理组声明顺序排列 |
| PUT | `/proxies/<group>` | body 至少含 `{"name":"proxy"}`；group 支持百分号编码 |

响应由 `serde_json` 序列化，引号、反斜杠、控制字符与 Unicode 正确转义。错误为 `{"error":"…"}`，不是 CLI 的 code/message/hint envelope。

## 连接模型与关闭语义

一条 mixed 接受的 TCP 任务对应一个 `connection`；SOCKS5 UDP 控制关联也使用该 ID。列表为 `{"connections":[...]}`，条目字段如下；握手中尚未知的可选字段省略，不默认填 DIRECT。

| 字段 | 含义 |
| --- | --- |
| `id` | `<实例 nonce>-<单调序号>`；实例内不复用，序号溢出拒绝新连接 |
| `source` | 接受时的 TCP 来源地址及端口；UDP 时仍是控制连接来源 |
| `protocol` / `phase` | `tcp/udp`；阶段为 `handshake/routing/connecting/active/idle/udp_wait/rejected/closing` |
| `inbound` | 已识别的 `http_connect/http_forward/socks5_connect/socks5_udp` |
| `target` | 当前原始目标 `{host,port}`，不含 URL 路径、请求头或正文 |
| `routed_target` | 单次规则匹配后固定的目标 `{host,port}`；可能是域名或获准 IP，**不是实际远端 IP** |
| `rule` | `{index,type,payload,target}`，零起始 index 对应本实例 `/rules` 的运行时展开顺序，不是 YAML 行号或 provider 来源 |
| `proxy` | `{name,type}`，实际 leaf 节点；type 使用 `Direct/Reject/Shadowsocks/Trojan/AnyTLS`，不含凭据 |
| `datagram_source` / `target_scope` | UDP 首个合法数据报来源；scope 固定为 `first_datagram` |

`routing` 包含可能的规则 DNS 等待；`connecting` 包含出站 DNS、TCP、TLS 或 HTTPS 准备，不细分每个协议内部步骤。`active` 也不保证远端目标已确认成功，例如 AnyTLS 保持乐观开流语义。拒绝状态可能很短暂，列表不是历史记录。

元数据来自实际单次路由与同一次选择读锁，不在查询时重路由、解析 DNS 或按当前选择重算。切组不会改写存量隧道的 leaf。HTTP forward 顺序 keep-alive 使用同一 ID，每个新请求重新路由；等待下一请求时为 `idle`，清除 target、routed_target、rule 和 proxy。UDP 首包前为 `udp_wait`，上述目标和路由字段未知；首合法包固定目标、来源、rule 与 leaf。后续数据报仍可有其他目标，但**列表只代表首包**，不会把新目标搭配旧规则伪装成重新路由。

DELETE 成功返回 `{"id":"…","close_requested":true,"phase":"closing"}`，只表示已请求关闭，不表示资源已回收。重复关闭尚存的 closing 条目可以成功；条目已删除返回 404。关闭 UDP 会关闭整条关联；数据面任务先取消转发，再等待 Trojan UDP worker 回收，最后释放槽位、删除记录与释放观测计数。不强制 abort 整个连接任务，也不把管理取消计为连接故障。

仅连接接口请求通过非空 secret 和 Bearer 鉴权后，响应才携带 `X-Zc-Instance-Nonce`，包括后续的 400/404/409/500。旧 GET、其他路由、未通过鉴权以及 HTTP 读取失败/超时的响应均不带该头。CLI 对 401/403 不依赖实例头，分别返回既有 `CONNECTION_UNAUTHORIZED` / `CONNECTION_SECRET_REQUIRED`，不读取或回显响应正文；成功及所有其他响应仍严格验证唯一且匹配的实例头，保留请求前后的 descriptor 身份复查。连接请求可带同名请求头，带了就必须与实例匹配；重复头为 400，不匹配为 409。CLI 必须发送并检查该头。手工 GET 可省略请求头，但不能省略鉴权。DELETE 无论是否带头，都先检查完整 ID 中的 nonce，旧实例 ID 返回 409，不会只按序号误伤新实例。格式错误的 ID 返回 400。

配置变更后须显式重新准备，例如 `zc restart -c <config>`；默认 `zc restart` 仍复用冻结快照。没有 controller 时不创建临时监听器。无流量计数、全部断开、历史、分页、WebSocket、自动 controller 或 TUI；这不是 mihomo `/connections` 的完整响应兼容实现。

## 诊断请求票据

这是 zc `test` 的请求关联接口，不是 mihomo 兼容端点，也不是通用请求历史。复用既有非空 secret、Bearer 与 `X-Zc-Instance-Nonce`；三种操作都**要求**实例请求头，缺失为 400、不匹配为 409。鉴权先于实例/票据校验，未鉴权错误不返回实例头、票据或 leaf。响应继续使用既有 4 MiB 上限与 2 秒 I/O 期限。

1. `PUT /connections/probes`：body 精确为 `{"host":"example.com","port":80}`。字段缺失、重复、未知字段及无效目标返回 400；返回 `{"token":"<实例 nonce>.<票据标识>"}`。目标 IP 规范化、域名 ASCII 小写化，保留域名末尾点；端口精确匹配。
2. 在该实例的 mixed HTTP forward 请求中发送 `X-Zc-Probe-Token: <token>`，并发送 `Connection: X-Zc-Probe-Token` 声明逐跳性质。运行时在任何路由/拨号之前校验实例、目标和票据，原子地消费一次，随后保存**本次实际 Route 的 leaf 索引**。目标/实例错误、重放或已过期票据返回本地 502，目标未被拨号；CONNECT 携此头、重复头、声明或实际追踪 trailer 拒绝。入口始终剥离追踪头，旧版 zc 也按 `Connection` 声明移除该字段。
3. `GET /connections/probes/<token>` 返回以下快照；短请求结束、连接记录删除或同连接下一请求开始都不会覆盖它。查询时只投影已记录的 leaf，不重路由或重新选择。
4. `DELETE /connections/probes/<token>` 返回 `{"released":true}` 并释放记录；缺失/已释放/到期为 404。旧实例 token 为 409，无效语法为 400。删除或过期后，迟到的路由操作不能恢复记录。

```json
{
  "token": "<实例 nonce>.<票据标识>",
  "state": "routed",
  "target": {"host": "example.com", "port": 80},
  "connection_id": "<实例 nonce>-42",
  "request_index": 0,
  "proxy": {"name": "edge", "type": "Shadowsocks"}
}
```

- `state:reserved`：尚未消费，只有 token/state/target。
- `state:claimed`：已关联连接与请求序号，尚无 route；含 `connection_id/request_index`，无 proxy。
- `state:routed`：另含 `proxy:{name,type}`，类型同连接模型。只证明选定/尝试路径，目标成功由 CLI HTTP 结果判断。记录不含节点凭据、订阅、URL 路径、请求头或正文。

票据只存在于实例内存中：最多 **256** 张，从预约起 **120 秒** 有效，按操作惰性清理；额度满返回 429，不驱逐有效记录。标识为 96 位随机数加 checked 32 位发行序号（合计 32 位十六进制），实例内删除、到期后也不复用，序号耗尽拒绝新增。CLI 每个目标单独预约，查询后尽力删除；controller 不可用时依靠到期清理。票据本身不赋予控制 API 查询权限，长期 secret 只用于已有 controller。

CLI 使用认证冻结快照的 mixed 端口、controller 与 secret；控制请求前后验证 PID、实例 nonce、endpoint 和配置 identity，同实例选择 generation 改变允许。目标探测禁重定向；HTTPS 普通请求头可能位于隧道内部，因此当前不向 HTTPS 请求附票据。没有 controller、缺 secret、外部 `--port`、旧版接口或实例校验失败时，CLI 明确报告路径未知，不自动开启监听器。默认端口规则保持不变。

`Connection` 声明覆盖旧版 zc 与遵守 HTTP 逐跳规则的端口接管者；协议仍沿用可信本机 loopback HTTP 的身份边界，不声称能抵御恶意本地监听器冒充整个控制面。客户端不得把长期 Bearer 放进 mixed 请求，票据也不得作为端到端请求头转发。

## managed selection 与 readiness

- 只有 unmanaged 实例允许 name-only PUT，选择为 transient，不保证重启保留。
- Managed 实例要求 `name` 以及 `instance_nonce`、`identity_key`、`identity_revision`、`generation`。缺完整 managed metadata 返回 409；格式不合法返回 400。Bearer 验证不能替代 identity/CAS。
- `zc proxy select` 先提交 durable desired generation，再通知 PID/nonce/endpoint/exact revision 匹配的实例。daemon 只接受经 authority 校验的完整 snapshot，拒绝旧或乱序 generation；durable desired 领先时可前跳到最新 generation，数据面提交后更新 descriptor。
- descriptor 缺失/不可验证时 CLI 只保留 durable selection，不猜配置 endpoint。status 不得用当前 active profile 冒充运行实例。
- 所有 listener 绑定、desired reconciliation 和 ready descriptor 发布完成后，才运行数据面/API accept loop；仅看到端口可连接不等价于已就绪。

## HTTP 资源上界

- 同时最多 16 个连接，超出立即关闭。
- header 最大 16 KiB，body 最大 64 KiB，超限 413。
- 完整 request 读取期限 2 秒，超时 408。
- response body 最大 4 MiB，写出期限 2 秒；超限为完整的 500 `Response Too Large`。连接列表先轻量快照，再借用配置索引通过有界编码器；配置中的巨大名称、规则及 JSON 转义也计费，不先克隆成无界 JSON，不静默截断或省略条目。
- PUT 必须提供唯一合法 Content-Length；不支持 Transfer-Encoding/chunked，拒绝歧义 framing。
- 单连接单个 HTTP/1.0 或 HTTP/1.1 request，响应后关闭。

无 WebSocket、`/runtime`、`/profiles`、`/metrics`。不要将该有界控制面当作通用 HTTP 服务。
