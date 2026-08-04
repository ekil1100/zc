# zc minimal API

zc v1.0 only documents the API that is implemented in `src/api/server.zig`.

The API is **minimal** and should not be advertised as a complete REST API v1 or mihomo/clash panel-compatible API.

## Enabling the API

The API server starts when `external-controller` is present in the active config. zc v1.0 accepts only an explicit `127.0.0.1:<port>` endpoint. If that exact port is unavailable, startup fails; zc never drifts to another port or silently disables the controller.

Example:

```yaml
mixed-port: 7899
external-controller: 127.0.0.1:9090
```

## Implemented endpoints

| Method | Path | Description |
| --- | --- | --- |
| `GET` | `/` | Basic hello/version response. |
| `GET` | `/version` | Version response. |
| `GET` | `/proxies` | List configured proxy nodes. |
| `GET` | `/rules` | List configured rules. |
| `PUT` | `/proxies/<group_name>` | Select a proxy for a group; body contains `{"name":"proxy_name"}`. |

所有 JSON 响应均由标准序列化器生成；配置中的引号、反斜杠、控制字符与 Unicode 会按 JSON 规则转义并可无损还原。

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
