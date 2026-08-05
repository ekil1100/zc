# zc minimal API

zc v1.0 only documents the API that is implemented in `src/api/server.zig`.

The API is **minimal** and should not be advertised as a complete REST API v1 or mihomo/clash panel-compatible API.

## Enabling the API

The API server starts when `external-controller` is present in the active config. zc v1.0 accepts only an explicit `127.0.0.1:<port>` endpoint. If that exact port is unavailable, startup fails; zc never drifts to another port or silently disables the controller.

Example:

```yaml
mixed-port: 7899
external-controller: 127.0.0.1:9090
secret: replace-with-a-random-secret
```

## Implemented endpoints

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/` | Basic hello/version response. |
| `GET` | `/version` | Version response. |
| `GET` | `/proxies` | List configured proxy nodes. |
| `GET` | `/rules` | List configured rules. |
| `GET` | `/status` | Report the running config identity and current group selections. |
| `PUT` | `/proxies/<group_name>` | Select a proxy for a group; body contains `{"name":"proxy_name"}`. |

所有 JSON 响应均由标准序列化器生成；配置中的引号、反斜杠、控制字符与 Unicode 会按 JSON 规则转义并可无损还原。

配置非空 `secret` 后，变更状态的 `PUT` endpoint 要求 `Authorization: Bearer <secret>`；缺失或错误凭据返回 `401`。只读 endpoint 保持可用于本机状态探测。controller 虽然仅监听 loopback，但 loopback 不是多用户系统上的授权边界，生产环境应始终配置随机 secret。

仅显式 unmanaged 配置允许发送只含 `name` 的临时 runtime PUT，重启后不保证保留。Managed daemon 要求完整的 instance nonce、exact identity、revision 与 generation，缺少元数据返回 `409`。`zc proxy select` 会先提交 durable desired generation，再调用同一端点；daemon 拒绝过期或乱序 generation；当 durable desired 已领先多个 generation 时，可从旧 descriptor 原子前跳到最新完整 snapshot，并在数据面提交后推进 runtime descriptor。

## 资源与 framing 上界

- 同时最多处理 16 个连接；超出 admission 上界的连接立即关闭。
- request header 最大 16 KiB，body 最大 64 KiB；超限返回 `413`。
- 每个 request 的完整读取期限为 2 秒；超时返回 `408`。
- response body 最大 4 MiB，写出期限为 2 秒；超限 endpoint 返回完整的 `500 Response Too Large`。
- `PUT` 必须提供唯一、合法的 `Content-Length`；不支持 chunked transfer encoding。
- 每个连接只处理一个 HTTP/1.0 或 HTTP/1.1 request，响应后关闭。

## Known limitations

- No WebSocket event stream.
- No `/runtime`, `/profiles`, `/connections`, or `/metrics` endpoints.
- Error responses are currently minimal and do not consistently use the CLI `code/message/hint` envelope.
- The HTTP parser is a small built-in implementation and should be treated as control-plane only.

## v1.0 action

Before GA, either:

1. keep this API explicitly documented as minimal, or
2. implement and test the larger API surface before advertising it.
