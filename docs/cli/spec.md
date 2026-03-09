# CLI Spec（Phase 1 初稿）

> 状态：DRAFT  
> 更新时间：2026-02-11 04:48 (GMT+8)

## 1. 目标

统一 zclash CLI 的命令模型与输出契约，保证：
- 人类使用直觉一致
- 自动化脚本可稳定依赖
- 错误可定位且可操作

---

## 2. 命名规范

### 2.1 总体规则
- 优先使用：`zclash <resource> <action>`
- 对全局动作保留短命令：`zclash start|stop|restart|status`
- 命令、参数统一使用 `kebab-case`
- 避免同义重复命令（只保留一个主命令，必要时提供 alias）

### 2.2 资源命名
- `profile`：配置文件与激活配置管理
- `proxy`：代理组与节点操作
- `rule`：规则检查与测试
- `diag`：诊断与健康检查

### 2.3 alias 约定
- `list` 可提供 `ls`
- alias 仅作为便捷入口，不单独扩展语义

---

## 3. 命令层级

## 3.1 L0（全局控制）
- `zclash start [-c <config>] [--port <port>]`
- `zclash stop`
- `zclash restart [-c <config>]`
- `zclash status`

## 3.2 L1（资源控制）
- `zclash profile <action>`
- `zclash proxy <action>`
- `zclash rule <action>`
- `zclash diag <action>`

## 3.3 L2（示例动作）
- `zclash profile list|use|import|validate`
- `zclash proxy list|select|test`
- `zclash rule inspect|test`
- `zclash diag doctor`

---

## 4. start/stop/restart/status 统一语义

### `start`
- 语义：启动服务（若已启动则返回已运行状态，不重复拉起）
- `--port <port>`：显式覆盖本次 daemon 启动使用的 mixed port，便于本地开发避开生产占用端口
- 若请求端口已被占用：直接报错并拒绝启动，不自动切换到其他端口
- 成功：返回运行中状态 + 关键端口/配置摘要

### `stop`
- 语义：停止服务（若未运行，返回已停止状态）
- 成功：确认进程已退出

### `restart`
- 语义：先 stop 再 start；中间失败必须显式报错
- mixed-port / bind-address 预检与 `start` 保持一致；端口冲突时在前台直接报错，不只写 daemon 日志
- 成功：返回新进程状态与配置摘要

### `status`
- 语义：只读查询，不改变状态
- 成功：返回运行状态、PID、daemon uptime、当前激活配置，以及 pid/lock/log 运行时路径

---

## 5. `--json` 输出规范

所有可读命令应支持 `--json`。

### 5.1 顶层结构
```json
{
  "ok": true,
  "data": {},
  "meta": {
    "command": "zclash status",
    "timestamp": "2026-02-11T04:48:00+08:00"
  }
}
```

### 5.2 约束
- `ok=true` 时必须返回 `data`
- `ok=false` 时必须返回 `error`
- 字段命名统一 `snake_case` 或 `camelCase`（二选一，全局一致；当前建议 `snake_case`）

---

## 6. 错误输出格式（code/message/hint）

### 6.1 标准结构
```json
{
  "ok": false,
  "error": {
    "code": "CONFIG_NOT_FOUND",
    "message": "config file not found: /path/to/config.yaml",
    "hint": "run `zclash profile list` to view available profiles"
  },
  "meta": {
    "command": "zclash start -c /path/to/config.yaml",
    "timestamp": "2026-02-11T04:48:00+08:00"
  }
}
```

### 6.2 规则
- `code`：稳定、可机器判断（全大写 + 下划线）
- `message`：面向人类，解释发生了什么
- `hint`：给出下一步可执行动作

---

## 7. 验收标准（P1-1）

- [x] 命令命名规范与层级结构清晰
- [x] `start/stop/restart/status` 语义统一
- [x] `--json` 输出有统一顶层结构
- [x] 错误输出采用 `code/message/hint`
- [ ] 与实现逐项对齐并补充示例输出（下一步）

---

## 8. 实现映射清单（代码位置 + 缺口）

| 规范项 | 代码位置 | 现状 | 说明 |
|---|---|---|---|
| `start` 语义统一 | `src/main.zig`（命令分发）、`src/daemon.zig`（`startDaemon`） | 已实现（P1-1 范围内） | 输出已统一为 `ok action=start ...`，支持 `--json` |
| `stop` 语义统一 | `src/main.zig`、`src/daemon.zig`（`stopDaemon`） | 已实现（P1-1 范围内） | 输出已统一为 `ok action=stop ...`，支持 `--json` |
| `restart` 语义统一 | `src/main.zig`、`src/daemon.zig`（`restartDaemon`） | 已实现（P1-1 范围内） | stop/start 语义统一，支持 `--json` |
| `status` 语义统一 | `src/main.zig`（status 分支）、`src/daemon.zig`（状态查询） | 已实现（P1-1 范围内） | 输出统一，支持 `--json` 结构化结果 |
| `--json` 输出规范 | `src/main.zig`（`hasFlag(--json)`）、`src/daemon.zig`（`printCliOk/printCliError`）、`src/proxy_cli.zig`（`listProxiesJson`） | 部分实现 | 已覆盖 start/stop/restart/status + `proxy list`，其他资源命令待补齐 |
| 错误格式 `code/message/hint` | `src/main.zig`、`src/daemon.zig` | 部分实现 | 已覆盖服务控制命令 + `proxy` 部分路径（配置加载/未知子命令）；其余命令待统一 |

### 8.1 缺口结论
- 服务控制主流程（start/stop/restart/status）的契约化输出已落地。
- 当前剩余缺口在于：
  1) 将 `--json` 能力扩展到 `proxy/config/test/doctor` 等资源命令；
  2) 将 `code/message/hint` 扩展到非服务控制命令；
  3) 为 JSON 输出补充 `meta` 字段（command/timestamp）与回归测试。

## 9. 下一步最小实现序列（原子可提交）

1. **原子任务 A：统一参数入口（`--json` 开关）**  
   在 `main.zig` 增加全局 `--json` 解析与透传，不改业务逻辑，仅建立结构化输出开关。

2. **原子任务 B：状态命令结构化输出**  
   先改 `status` 命令：文本输出保留，新增 `--json` 下的标准结构（`ok/data/meta`）。

3. **原子任务 C：错误输出标准化最小闭环**  
   先覆盖 start/stop/restart/status 四命令，把核心错误统一为 `code/message/hint`；其它命令后续跟进。

## 10. 最小实现序列进度

- [x] 原子任务 A：start/stop/restart/status 语义对齐（文本输出统一，错误输出具备 `code/message/hint` 结构）
- [x] 原子任务 B：补全 `--json` 开关与 start/stop/restart/status 结构化输出
- [x] 原子任务 C（首批）：扩展 `--json` 到资源命令 `proxy list`，并补齐 `proxy` 路径部分错误结构

验证记录（关键场景）：
- `zig run src/main.zig -- status --json` 输出：`{"ok":true,"data":{"action":"status","state":"stopped","uptime_seconds":null,"active_config":"<config-key>|null","paths":{"pid_file":"...","lock_file":"...","log_file":"..."}}}`
- `zig run src/main.zig -- stop --json` 输出：`{"ok":true,"data":{"action":"stop","state":"stopped","detail":"already_stopped"}}`
- `zig run src/main.zig -- proxy list -c testdata/config/minimal.yaml --json` 输出：`{"ok":true,"data":{"groups":[...]}}`
- `zig run src/main.zig -- proxy select -g PROXY --json -c testdata/config/minimal.yaml` 输出：`{"ok":true,"data":{"action":"proxy_select",...}}`
- `zig run src/main.zig -- proxy test -c testdata/config/minimal.yaml --json` 输出：`{"ok":true,"data":{"action":"proxy_test",...}}`
- `zig run src/main.zig -- diag doctor -c testdata/config/minimal.yaml --json` 输出：`{"ok":true,"data":{"action":"doctor","version":"v0.1.0","config_ok":...,"network_ok":...,...}}`

#### doctor --json 结构化输出字段（v1.1+）
- `version`：当前版本
- `config_ok`：配置是否有效
- `config_source`：配置来源
- `daemon_running`：守护进程是否运行
- `network_ok`：网络连通性（DNS 53 端口可达）
- `daemon_pid`：守护进程 PID
- `ports`：有效端口列表

#### status 输出字段（v1.1+）
- 文本态固定输出：`state`、`pid`、`uptime_seconds`、`active_config`、`pid_file`、`lock_file`、`log_file`
- `detail`：仅在存在补充说明时输出（如 `stale_pid_file`、`lock_held_pid_untracked`）
- 当 `detail=lock_held_pid_untracked` 时，表示 runtime lock 明确仍被 daemon 持有，但当前 pid 文件/进程扫描未恢复出 PID；此时 `state` 仍应视为 `running`
- JSON 兼容保留：`action`、`state`、`detail`、`pid`
- JSON 新增：`uptime_seconds`、`active_config`、`paths.pid_file`、`paths.lock_file`、`paths.log_file`

---

## 11. P1-2：profile 子命令规范（list/use/import/validate）

### 11.1 `profile list`
- 输入：`zclash profile list [--json]`
- 成功输出（文本）：配置列表 + 当前激活项
- 成功输出（JSON）：
```json
{
  "ok": true,
  "data": {
    "profiles": ["default.yaml", "hk.yaml"],
    "active": "default.yaml"
  }
}
```
- 错误输出：`code/message/hint`
  - `PROFILE_LIST_FAILED`

### 11.2 `profile use`
- 输入：`zclash profile use <name> [--json]`
- 成功语义：将 `<name>` 设为激活配置（幂等）
- 成功输出（JSON）：
```json
{
  "ok": true,
  "data": {
    "action": "profile_use",
    "profile": "hk.yaml",
    "state": "active"
  }
}
```
- 错误输出：
  - `PROFILE_NOT_FOUND`
  - `PROFILE_USE_FAILED`

### 11.3 `profile import`
- 输入：`zclash profile import <url_or_path> [-n <name>] [--json]`
- 成功语义：导入配置并返回保存名称；可选是否设为默认
- 成功输出（JSON）：
```json
{
  "ok": true,
  "data": {
    "action": "profile_import",
    "profile": "my.yaml",
    "source": "https://..."
  }
}
```
- 错误输出：
  - `PROFILE_IMPORT_FAILED`
  - `PROFILE_SOURCE_INVALID`

### 11.4 `profile validate`
- 输入：`zclash profile validate [<name_or_path>] [--json]`
- 成功语义：返回校验结果与 warnings/errors
- 成功输出（JSON）：
```json
{
  "ok": true,
  "data": {
    "valid": true,
    "warnings": [],
    "errors": []
  }
}
```
- 错误输出：
  - `PROFILE_VALIDATE_FAILED`

### 11.5 P1-2 最小实现顺序（文档先行）
1. 先实现：`profile list/use`（基础读写闭环）
2. 再实现：`profile import/validate`（导入与质量门禁）
3. 每步都先补 `--json` + `code/message/hint`

---

## 12. Runtime Override（v1）

适用命令：所有会加载配置的命令路径（如 `start/tui/test/doctor/proxy ...`）。

### 12.0 config 级持久化绑定

- `zc config override <script.lua>`：给当前配置绑定持久化 override 脚本。
- `zc config override --clear`：清除当前配置绑定。
- `zc config override`：查看当前配置绑定状态。
- 绑定粒度是 `meta.configs.<key>`，仅作用该配置。
- `set` 会将脚本复制到 `~/.config/zc/override/` 托管目录。
- `set/clear` 后若 daemon 正在运行，会自动尝试应用配置（`auto`，当前会 fallback restart）。

### 12.1 flags

- `--override-script <path>`
- `--override-arg <k=v>`（可重复）
- `--override-timeout-ms <n>`（默认 `500`）
- merged 配置查看统一使用 `zc config dump`（`--json` 输出 JSON，`--no-override` 忽略覆盖脚本）

### 12.2 行为

- 覆盖仅在当前命令进程内生效，不写回 profile 文件。
- 运行时优先级：`--override-script` > `zc config override` 持久化绑定 > 无覆盖。
- 合并策略：标量字段替换；`rule-providers` / `proxies` / `proxy-groups` / `rules` 使用整体替换。
- `rules` 中支持 `RULE-SET`；运行时会按 `rule-providers.<name>.path` 加载本地规则文件。
- provider 文件自动同步策略：
  - 缺失且有 `url`：必须下载成功，否则报错
  - 已存在且到达 `interval`：尝试刷新，失败保留本地缓存
  - 缺失且无 `url`：报错
- 未知或暂不支持的键直接报错（`OVERRIDE_OUTPUT_INVALID`）。

### 12.3 脚本契约

- `*.lua`：脚本返回 Lua table（或 `nil`）。
- 非 lua 可执行脚本：stdout 输出 YAML 覆盖对象。
- 可通过 `input.command / input.config_path / input.args` 获取上下文（lua 模式）。
- `*.lua` 需要运行环境存在 `luajit` 或 `lua` 可执行文件。
