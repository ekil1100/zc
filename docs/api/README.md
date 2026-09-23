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

非空 `secret` 使所有 PUT 要求 `Authorization: Bearer <secret>`，缺失/错误返回 401；只读端点不要求 Bearer。loopback 不是多用户授权边界，生产应始终配置随机 secret，且不要把只读接口视为私密信息通道。

## 端点

| 方法 | 路径 | 行为 |
| --- | --- | --- |
| GET | `/` | hello/version |
| GET | `/version` | 版本 |
| GET | `/proxies` | 配置节点 |
| GET | `/rules` | 配置规则 |
| GET | `/status` | 实际运行 config identity 与当前 group selections；`selected_proxies` 按运行配置的代理组声明顺序排列 |
| PUT | `/proxies/<group>` | body 至少含 `{"name":"proxy"}`；group 支持百分号编码 |

响应由 `serde_json` 序列化，引号、反斜杠、控制字符与 Unicode 正确转义。错误为 `{"error":"…"}`，不是 CLI 的 code/message/hint envelope。

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
- response body 最大 4 MiB，写出期限 2 秒；超限为完整的 500 `Response Too Large`。
- PUT 必须提供唯一合法 Content-Length；不支持 Transfer-Encoding/chunked，拒绝歧义 framing。
- 单连接单个 HTTP/1.0 或 HTTP/1.1 request，响应后关闭。

无 WebSocket、`/runtime`、`/profiles`、`/connections`、`/metrics`。不要将该有界控制面当作通用 HTTP 服务。
