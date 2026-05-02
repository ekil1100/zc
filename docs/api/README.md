# zc minimal API

zc v1.0 only documents the API that is implemented in `src/api/server.zig`.

The API is **minimal** and should not be advertised as a complete REST API v1 or mihomo/clash panel-compatible API.

## Enabling the API

The API server starts when `external-controller` is present in the active config.

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

## Known limitations

- No WebSocket event stream.
- No `/runtime`, `/profiles`, `/connections`, or `/metrics` endpoints.
- Error responses are currently minimal and do not consistently use the CLI `code/message/hint` envelope.
- The HTTP parser is a small built-in implementation and should be treated as control-plane only.

## v1.0 action

Before GA, either:

1. keep this API explicitly documented as minimal, or
2. implement and test the larger API surface before advertising it.
