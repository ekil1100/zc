# API Versioning & REST/WS Boundary (P2-1)

## REST vs WebSocket Boundary

- REST (`/v1/*`):
  - 用于获取快照与执行显式操作（如 profile 切换、proxy 选择）。
  - 适合可重放、可审计的请求响应流程。

- WebSocket (`/v1/events`):
  - 用于接收增量事件（状态变化、连接变化、指标 tick）。
  - 客户端应先通过 REST 拉取基线，再通过 WS 追增量。

## v1 Version Policy

1. v1 内不做破坏性修改（字段不删除、不重命名）。
2. 新增字段必须可选或具备安全默认值。
3. 错误响应信封固定为：
   - `ok=false`
   - `error.code`
   - `error.message`
   - `error.hint`
4. 破坏性变更只能在新主版本路径中进行（如 `/v2`）。
5. 弃用策略：必须先给迁移说明与过渡期，再移除旧行为。
