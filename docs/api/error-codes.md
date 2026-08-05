# CLI/API Error Codes

## 1) 目标

为 zc CLI（及最小 API）提供稳定、可机器识别、可人类操作的错误码体系。

统一错误响应信封（CLI `--json` 模式，stdout 单行；`command` 为规范命令路径）：

```json
{
  "ok": false,
  "command": "config use",
  "error": {
    "code": "CONFIG_NOT_FOUND",
    "message": "config not found",
    "hint": "run `zc config list` and pick an existing config name"
  }
}
```

文本模式输出等价的错误块到 stderr（`error:` / `hint:` / `code:`）。
诊断类失败（`CHECKS_FAILED`）会在 envelope 中附带 `"data"`（逐项检查结果）。
退出码约定见 [`../cli/spec.md`](../cli/spec.md)：用法错误 exit 2，运行时失败 exit 1。

---

## 2) 命名规则

- 全大写 + 下划线：`DOMAIN_DETAIL_REASON`
- 建议结构：`<LAYER>_<ACTION>_<DETAIL>`
- 避免把动态信息写进 `code`（动态信息放 `message`）
- 同类语义错误只保留一个主 code，避免重复
- 用法错误统一以 `*_ARGUMENT_INVALID` / `*_REQUIRED` / `*_SUBCOMMAND_UNKNOWN` / `*_SUBCOMMAND_MISSING` 收尾

---

## 3) 已实现 CLI 错误码（与 `src/` 实际发射点一致）

### A. 全局（dispatch / help / version）

| code | message 示例 | hint 示例 |
|---|---|---|
| `COMMAND_UNKNOWN` | unknown command: nope | use `zc help` to list supported commands |
| `HELP_TOPIC_UNKNOWN` | unknown help topic | run `zc help` to list commands |
| `VERSION_ARGUMENT_INVALID` | unknown or unexpected argument for `version` | use `zc version [--json]` |

### B. 生命周期（start / stop / restart / reload / status / log）

| code | message 示例 | hint 示例 |
|---|---|---|
| `START_FAILED` | daemon exited before startup completed | check `zc log --no-follow` for details |
| `START_READINESS_TIMEOUT` | daemon did not publish readiness before the startup deadline | check override duration, port ownership, and the daemon log |
| `START_RUNTIME_PUBLISH_FAILED` | failed to publish the daemon pid or descriptor | remove unsafe runtime artifacts and retry |
| `START_LOCK_HANDOFF_INVALID` | daemon lock handoff is missing or invalid | launch the daemon through `zc start` |
| `START_ARGS_INVALID` | unknown or unexpected argument for `start` | use `zc start [-c <config>] [--port <port>] [--foreground] [--json]` |
| `START_PORT_REQUIRED` | missing value for `--port` | use `zc start --port <port>` |
| `START_PORT_INVALID` | invalid `--port` value | use an integer between 1 and 65535 |
| `START_CONFIG_PATH_REQUIRED` | missing value for `-c` | use `zc start -c <config>` |
| `START_PORT_IN_USE` | requested start port is already in use | retry with `zc start --port <free-port>` |
| `START_CONTROLLER_PORT_IN_USE` | configured controller port is already in use | free the exact `external-controller` port or update the config |
| `START_PORT_CONFLICT` | requested start port conflicts with another runtime listener | change the port or fix the conflicting runtime config |
| `START_BIND_ADDRESS_INVALID` | invalid bind address for start preflight | fix `bind-address` in config and retry |
| `START_EXTERNAL_CONTROLLER_INVALID` | invalid `external-controller` address in config | use an explicit loopback endpoint such as `127.0.0.1:9090` |
| `START_PREFLIGHT_FAILED` | failed to validate daemon start ports | check config and retry |
| `STOP_FAILED` | failed to stop daemon | verify process permissions and retry `zc stop` |
| `STOP_TIMEOUT` | daemon did not acknowledge the stop request within 5 seconds | inspect `zc status` and the daemon log before retrying |
| `RESTART_FAILED` | failed to restart daemon | check logs and retry `zc restart -c <config>` |
| `RESTART_READINESS_TIMEOUT` | daemon did not publish readiness before the startup deadline | check override duration, port ownership, and the daemon log |
| `RESTART_PORT_IN_USE` | restart target port is already in use | free the occupied port, then retry `zc restart` |
| `RESTART_CONTROLLER_PORT_IN_USE` | restart controller port is already in use | free the exact `external-controller` port before retrying `zc restart` |
| `RESTART_PORT_CONFLICT` | restart target port conflicts with another runtime listener | fix the conflicting runtime config before retrying `zc restart` |
| `RESTART_BIND_ADDRESS_INVALID` | invalid bind address for restart preflight | fix `bind-address` in config and retry `zc restart` |
| `RESTART_EXTERNAL_CONTROLLER_INVALID` | invalid `external-controller` address in config | use an explicit loopback endpoint such as `127.0.0.1:9090` |
| `RESTART_PREFLIGHT_FAILED` | failed to validate daemon restart ports | check config and retry `zc restart` |
| `RELOAD_FAILED` | daemon is not running | start it first with `zc start` |
| `RELOAD_ARGUMENT_INVALID` | unknown or unexpected argument for `reload` | use `zc reload [--json]` |
| `STOP_ARGUMENT_INVALID` | unknown or unexpected argument for `stop` | use `zc stop [--json]` |
| `STATUS_FAILED` | failed to read daemon status | use a canonical owner-only runtime directory and retry `zc status` |
| `STATUS_ARGUMENT_INVALID` | unknown or unexpected argument for `status` | use `zc status [--json]` |
| `LOG_FAILED` | failed to read daemon log | check log file permissions; `zc status` shows the log path |
| `LOG_ARGUMENT_INVALID` | invalid `-n` value (use a non-negative integer) | use `zc log [-n <lines>] [-f\|--no-follow] [--json]` |

`zc restart` 与 `zc start` 共用同一参数解析器，因此 restart 的参数用法错误
（未知/多余参数、缺值 `-c`/`--port`、非法端口）发射同一组冻结码
（`START_ARGS_INVALID` / `START_CONFIG_PATH_REQUIRED` / `START_PORT_REQUIRED` /
`START_PORT_INVALID`），message/hint 按 `restart` 渲染。以上 `*_REQUIRED` /
`*_INVALID` 参数错误均为用法错误，exit 2。

### C. 配置类（CONFIG_*）

| code | message 示例 | hint 示例 |
|---|---|---|
| `CONFIG_LOAD_PATH_REQUIRED` | missing `<path>` for config load | use `zc config load <path>` |
| `CONFIG_LOAD_ARGUMENT_INVALID` | unknown or unexpected argument for `config load` | use `zc config load <path>` |
| `CONFIG_LOAD_INVALID` | local config is invalid | fix the config and retry |
| `CONFIG_CAPABILITY_UNSUPPORTED` | config uses a capability not supported in zc v1.0 | run `zc doctor -c <config>` and use direct/reject/ss/trojan |
| `CONFIG_LOAD_FAILED` | failed to load local config | check the path, local dependencies, and file permissions |
| `CONFIG_ALREADY_EXISTS` | a config with this name already exists | rename the file or delete the existing config first |
| `CONFIG_NAME_INVALID` | invalid config name | use 1-255 characters without control characters, `/` or `\` |
| `CONFIG_LIST_FAILED` | failed to list configs | ensure the config directory exists and is readable |
| `CONFIG_LIST_ARGUMENT_INVALID` | unknown or unexpected argument for `config list` | use `zc config list [--json]` |
| `CONFIG_DOWNLOAD_URL_REQUIRED` | missing <url> for config download | use `zc config download <url> [-n <name>] [-d]` |
| `CONFIG_DOWNLOAD_NAME_REQUIRED` | missing value for `-n` | use `zc config download <url> -n <name>` |
| `CONFIG_DOWNLOAD_ARGUMENT_INVALID` | unknown or unexpected argument for `config download` | use `zc config download <url> [-n <name>] [-d]` |
| `CONFIG_DOWNLOAD_FAILED` | failed to download config | check the url/network and retry |
| `CONFIG_UPDATE_APPLY_INVALID` | invalid `--apply` value | use `--apply auto\|hot\|restart` |
| `CONFIG_UPDATE_ARGUMENT_INVALID` | unknown or unexpected argument for `config update` | use `zc config update [name] [--apply auto\|hot\|restart]` |
| `CONFIG_UPDATE_NAME_REQUIRED` | no config name given and no active config | use `zc config update <name>`, or `zc config use <name>` first |
| `CONFIG_UPDATE_NO_SUBSCRIPTION` | no subscription url recorded for this config | use `zc config download <url>` to (re)create it |
| `CONFIG_UPDATE_FAILED` | failed to update config | check subscription url/network and retry |
| `CONFIG_UPDATE_APPLY_FAILED` | config updated but failed to apply to running daemon | check `zc log --no-follow`, then run `zc restart` |
| `CONFIG_USE_NAME_REQUIRED` | missing <name> for config use | use `zc config use <name>`; run `zc config list` to see candidates |
| `CONFIG_USE_ARGUMENT_INVALID` | unknown or unexpected argument for `config use` | use `zc config use <name>` |
| `CONFIG_NOT_FOUND` | config not found | run `zc config list` and pick an existing config name |
| `CONFIG_SWITCH_FAILED` | failed to switch active config | verify file permission and retry |
| `CONFIG_DUMP_ARGUMENT_INVALID` | unknown or unexpected argument for `config dump` | use `zc config dump [-c <config>] [--no-override]` |
| `CONFIG_DUMP_FAILED` | failed to dump merged config | check config path/override script and retry |
| `CONFIG_OVERRIDE_ARGUMENT_INVALID` | invalid config override arguments | use `zc config override <script.lua>` / `--clear` |
| `CONFIG_OVERRIDE_NO_ACTIVE` | no active config found for override | run `zc config use <name>` first |
| `CONFIG_OVERRIDE_SCRIPT_NOT_FOUND` | override script file not found | check script path and retry |
| `CONFIG_OVERRIDE_FAILED` | failed to update persisted config override | check config state and retry |
| `CONFIG_OVERRIDE_APPLY_FAILED` | override persisted but failed to apply running daemon | check logs and run `zc restart` |
| `CONFIG_SUBCOMMAND_UNKNOWN` | unknown config subcommand | use `zc config --help` to list config subcommands |

### D. proxy / profile 家族

`profile` 与 `proxy` 共用同一 handler：共享的 select/load 错误保持冻结的
`PROXY_*` 码（两条路径相同），仅参数与子命令错误按家族携带
`PROXY_…` / `PROFILE_…` 前缀。

| code | message 示例 | hint 示例 |
|---|---|---|
| `PROXY_CONFIG_LOAD_FAILED` | failed to load/validate config for proxy list | check config path and retry with `-c <config>` |
| `PROXY_GROUP_NOT_FOUND` | proxy group not found | run `zc proxy list --json` to inspect groups |
| `PROXY_GROUP_NOT_SELECTABLE` | group is not a select-type proxy group | only select-type groups support manual selection; run `zc proxy list` to see group types |
| `PROXY_NOT_FOUND` | proxy not found in group | run `zc proxy select -g <group> --json` to inspect choices |
| `PROXY_SELECT_GROUP_MISSING` | no select-type proxy group found | check profile proxy-groups config |
| `PROXY_SELECT_NOT_INTERACTIVE` | interactive selection requires a TTY on stdin | stdin is not a TTY; use `zc proxy select -g <group> -p <proxy>` |
| `PROXY_SELECT_FAILED` | failed to select proxy | retry with valid group/proxy arguments |
| `PROXY_SELECTION_MANAGED_CONFIG_REQUIRED` | selection requires a managed config revision | import the config with `zc config load <path>` first |
| `PROXY_TEST_FAILED` | failed to run connectivity test | retry; `zc status` and `zc log --no-follow` show daemon state |
| `PROXY_LIST_ARGUMENT_INVALID` | unknown or unexpected argument for `proxy list` | use `zc proxy list [-c <config>] [--json]` |
| `PROXY_SELECT_ARGUMENT_INVALID` | unknown or unexpected argument for `proxy select` | use `zc proxy select [-g <group>] [-p <proxy>] [-c <config>] [--json]` |
| `PROXY_TEST_ARGUMENT_INVALID` | unknown or unexpected argument for `proxy test` | use `zc proxy test [-c <config>] [--port <port>] [--json]` |
| `PROXY_SUBCOMMAND_UNKNOWN` | unknown proxy subcommand | use `zc proxy --help` or `zc help proxy` |
| `PROFILE_LIST_ARGUMENT_INVALID` | unknown or unexpected argument for `profile list` | use `zc profile list [-c <config>] [--json]` |
| `PROFILE_SELECT_ARGUMENT_INVALID` | unknown or unexpected argument for `profile select` | use `zc profile select [-g <group>] [-p <proxy>] [-c <config>] [--json]` |
| `PROFILE_TEST_ARGUMENT_INVALID` | unknown or unexpected argument for `profile test` | use `zc profile test [-c <config>] [--port <port>] [--json]` |
| `PROFILE_SUBCOMMAND_UNKNOWN` | unknown profile subcommand | use `zc profile --help` or `zc help profile` |

### E. test / doctor / diag

| code | message 示例 | hint 示例 |
|---|---|---|
| `CHECKS_FAILED` | 2 connectivity check(s) failed / 1 doctor check(s) failed | inspect the failed entries in data.checks; `zc status` and `zc log --no-follow` show daemon details |
| `TEST_ARGUMENT_INVALID` | unknown or unexpected argument for `test` | use `zc test [-c <config>] [--port <port>] [--json]` |
| `DIAG_DOCTOR_FAILED` | failed to run doctor diagnostics | check config path/permissions and retry `zc doctor` |
| `DIAG_DOCTOR_ARGUMENT_INVALID` | unknown or unexpected argument for `doctor` | use `zc doctor [-c <config>] [--json]` |
| `DIAG_SUBCOMMAND_MISSING` | missing diag subcommand | use `zc diag doctor [-c <config>] [--json]` |
| `DIAG_SUBCOMMAND_UNKNOWN` | unknown diag subcommand | use `zc diag doctor [-c <config>] [--json]` |

`CHECKS_FAILED` 是诊断类命令（`test` / `proxy test` / `profile test` /
`doctor` / `diag doctor`）的统一失败码：envelope 附带 `data`（逐项
`checks`），exit 1（决策 D3）。

### F. override / rule-provider

| code | message 示例 | hint 示例 |
|---|---|---|
| `OVERRIDE_SCRIPT_NOT_FOUND` | override script or runtime not found | check `--override-script` path and lua availability |
| `OVERRIDE_SCRIPT_EXEC_FAILED` | override script execution failed | ensure script exits 0 and outputs valid override |
| `OVERRIDE_SCRIPT_TIMEOUT` | override script timed out | increase `--override-timeout-ms` or simplify script |
| `OVERRIDE_OUTPUT_INVALID` | override output is invalid | output yaml object with known config keys |
| `OVERRIDE_MERGE_FAILED` | failed to merge override result | check override field types and structure |
| `OVERRIDE_OPTION_DEPRECATED` | `--override-dump-yaml/json` has been removed | use `zc config dump [-c <config>]` |
| `RULE_PROVIDER_DOWNLOAD_FAILED` | failed to download rule-provider files | check provider url/network and retry |
| `RULE_PROVIDER_FILE_NOT_FOUND` | rule-provider file not found | check `rule-providers.<name>.path` or provider url |

override flag 本身的解析错误（`--override-script`/`--override-arg` 缺值、
`--override-timeout-ms` 非法值、已废弃的 `--override-dump-*`）在 dispatch 前
统一报错：复用上表的 `OVERRIDE_*` 码，但作为用法错误 exit 2；脚本的运行期
失败（执行/超时/输出非法）仍为 exit 1。

---

## 4) 预留分层（API 侧，尚未在代码中发射）

以下分类为 API 错误码体系预留，当前代码尚未发射，**不得**在文档/脚本中
当作已实现行为断言：

- 网络类 `NETWORK_*`（如 `NETWORK_DNS_FAILED`、`NETWORK_CONNECT_TIMEOUT`）
- 提供商类 `PROVIDER_*`（如 `PROVIDER_UNREACHABLE`、`PROVIDER_AUTH_FAILED`）
- 校验类 `VALIDATION_*`（如 `VALIDATION_RULE_INVALID`）
- 权限类 `AUTH_*`（如 `AUTH_PERMISSION_DENIED`）

已移除的历史错误码（不再发射，勿再断言）：`PROFILE_SUBCOMMAND_MISSING`、
`PROFILE_LIST_FAILED`、`PROFILE_NAME_REQUIRED`、`PROFILE_NOT_FOUND`、
`PROFILE_USE_FAILED`、`PROFILE_SOURCE_REQUIRED`、`PROFILE_IMPORT_FAILED`、
`PROFILE_VALIDATE_FAILED`、`CONFIG_PARSE_FAILED`。

---

## 5) 设计原则

1. `code` 稳定：供前端/脚本分支判断（冻结词汇，见 `docs/cli/ux-workflow.md` 第 3 节）。
2. `message` 可读：一句话说清发生了什么。
3. `hint` 可执行：给用户下一步动作。
4. 尽量避免返回裸异常名（例如 `FileNotFound`）给最终用户；CLI 在 envelope 之外可经 stderr 附加真实错误名作诊断。

---

## 6) API 文档对齐

- 当前 v1.0 active API 文档入口是 `docs/api/README.md`。
- 旧 OpenAPI 草案已归档到 `docs/archive/api/openapi.yaml`，不再作为当前契约。
- 新增错误码时，必须同步更新本字典，并在对应 CLI/API 文档中说明可触发场景。

## 7) 后续落地

1. API 路径（`src/api/server.zig`）错误响应仍为 `{"error":"…"}` 简单格式，尚未对齐本字典的 envelope。
2. 为高频 code 增加集成测试断言（已覆盖 PROXY / PROFILE / DIAG / CHECKS_FAILED 路径，见 `src/integration_error_test.zig`）。
