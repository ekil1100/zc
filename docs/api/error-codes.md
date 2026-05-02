# API Error Codes（P2-2 初稿）

## 1) 目标

为 zc API 提供稳定、可机器识别、可人类操作的错误码体系。

统一错误响应信封：

```json
{
  "ok": false,
  "error": {
    "code": "CONFIG_NOT_FOUND",
    "message": "config file not found",
    "hint": "run `zc profile list` and choose a valid profile"
  }
}
```

---

## 2) 命名规则

- 全大写 + 下划线：`DOMAIN_DETAIL_REASON`
- 建议结构：`<LAYER>_<ACTION>_<DETAIL>`
- 避免把动态信息写进 `code`（动态信息放 `message`）
- 同类语义错误只保留一个主 code，避免重复

示例：
- `CONFIG_NOT_FOUND`
- `NETWORK_DNS_FAILED`
- `PROVIDER_UNREACHABLE`
- `VALIDATION_RULE_INVALID`
- `AUTH_PERMISSION_DENIED`

---

## 3) 分层体系（至少 5 类）

## A. 配置类（CONFIG_*)

| code | message 示例 | hint 示例 |
|---|---|---|
| `CONFIG_NOT_FOUND` | config file not found | run `zc profile list` and select a valid profile |
| `CONFIG_PARSE_FAILED` | failed to parse config yaml | check yaml syntax and run `zc profile validate <file>` |
| `CONFIG_SWITCH_FAILED` | failed to switch active config | verify file permission and retry |

## B. 网络类（NETWORK_*)

| code | message 示例 | hint 示例 |
|---|---|---|
| `NETWORK_DNS_FAILED` | dns resolve failed for target | verify dns setting and upstream availability |
| `NETWORK_CONNECT_TIMEOUT` | tcp connect timeout | check proxy node health and network route |
| `NETWORK_PORT_IN_USE` | required local port is already in use | free the port or change config port |

## C. 提供商/上游类（PROVIDER_*)

| code | message 示例 | hint 示例 |
|---|---|---|
| `PROVIDER_UNREACHABLE` | upstream provider is unreachable | check provider endpoint/network/proxy chain |
| `PROVIDER_AUTH_FAILED` | provider authentication failed | verify token/credential and retry |
| `PROVIDER_RESPONSE_INVALID` | provider response format invalid | check provider compatibility and version |

## D. 校验类（VALIDATION_*)

| code | message 示例 | hint 示例 |
|---|---|---|
| `VALIDATION_RULE_INVALID` | rule format is invalid | use supported rule format and rerun validate |
| `VALIDATION_PROXY_INVALID` | proxy definition is invalid | check required proxy fields |
| `VALIDATION_PORT_CONFLICT` | config has port conflict | adjust mixed/http/socks port settings |

## E. 权限类（AUTH_*)

| code | message 示例 | hint 示例 |
|---|---|---|
| `AUTH_PERMISSION_DENIED` | permission denied for requested action | check role/token scope |
| `AUTH_TOKEN_MISSING` | auth token is missing | provide valid token in request |
| `AUTH_TOKEN_INVALID` | auth token is invalid | refresh token and retry |

## F. 资源路径对齐类（PROFILE_ / PROXY_ / DIAG_）

> 用于 profile/proxy/diag 资源路径的参数与流程错误，确保实现路径与字典一致。

| code | message 示例 | hint 示例 |
|---|---|---|
| `PROFILE_LIST_FAILED` | failed to list profiles | ensure config directory exists and is readable |
| `PROFILE_SUBCOMMAND_MISSING` | profile subcommand is required | use `zc profile list|use|import|validate` |
| `PROFILE_SUBCOMMAND_UNKNOWN` | unknown profile subcommand | use `zc profile list|use|import|validate` |
| `PROFILE_NAME_REQUIRED` | profile name is required | use `zc profile use <name>` |
| `PROFILE_NOT_FOUND` | profile not found | run `zc profile list` and confirm profile name |
| `PROFILE_USE_FAILED` | failed to switch profile | verify file permission and retry |
| `PROFILE_SOURCE_REQUIRED` | profile import source is required | use `zc profile import <url_or_path> [-n name]` |
| `PROFILE_IMPORT_FAILED` | failed to import profile | check source url/path and retry |
| `PROFILE_VALIDATE_FAILED` | failed to validate profile | run `zc profile validate <name_or_path>` |
| `PROXY_CONFIG_LOAD_FAILED` | failed to load config for proxy action | verify `-c` path and config validity |
| `PROXY_GROUP_NOT_FOUND` | proxy group not found | run `zc proxy list --json` to inspect groups |
| `PROXY_NOT_FOUND` | proxy not found in group | run `zc proxy select -g <group> --json` |
| `PROXY_SELECT_GROUP_MISSING` | no select-type proxy group found | check proxy-group type in profile |
| `PROXY_SELECT_FAILED` | failed to select proxy | retry with valid group/proxy arguments |
| `PROXY_SUBCOMMAND_UNKNOWN` | unknown proxy subcommand | use `zc proxy list|select|test` |
| `DIAG_DOCTOR_FAILED` | failed to run doctor diagnostics | retry with valid config and inspect logs |
| `DIAG_SUBCOMMAND_UNKNOWN` | unknown diag subcommand | use `zc diag doctor [-c <config>] [--json]` |
| `OVERRIDE_SCRIPT_NOT_FOUND` | override script or runtime not found | check `--override-script` path and lua availability |
| `OVERRIDE_SCRIPT_EXEC_FAILED` | override script execution failed | ensure script exits 0 and outputs valid override |
| `OVERRIDE_SCRIPT_TIMEOUT` | override script timed out | increase `--override-timeout-ms` or simplify script |
| `OVERRIDE_OUTPUT_INVALID` | override output is invalid | output yaml object with known config keys |
| `OVERRIDE_MERGE_FAILED` | failed to merge override result | check override field types and structure |
| `OVERRIDE_OPTION_DEPRECATED` | `--override-dump-yaml/json` has been removed | use `zc config dump [-c <config>]` |
| `RULE_PROVIDER_DOWNLOAD_FAILED` | failed to download rule-provider files | check provider url/network and retry |
| `RULE_PROVIDER_FILE_NOT_FOUND` | rule-provider file not found | check `rule-providers.<name>.path` or provider url |
| `CONFIG_OVERRIDE_ARGUMENT_INVALID` | invalid config override arguments | use `zc config override <script.lua>` / `--clear` |
| `CONFIG_OVERRIDE_NO_ACTIVE` | no active config found for override | run `zc config use <name>` first |
| `CONFIG_OVERRIDE_SCRIPT_NOT_FOUND` | override script file not found | check script path and retry |
| `CONFIG_OVERRIDE_FAILED` | failed to update persisted config override | check config state and retry |
| `CONFIG_OVERRIDE_APPLY_FAILED` | override persisted but failed to apply running daemon | check logs and run `zc restart` |
| `CONFIG_DUMP_FAILED` | failed to dump merged config | check config path/override script and retry |

---

## 4) 设计原则

1. `code` 稳定：供前端/脚本分支判断。
2. `message` 可读：一句话说清发生了什么。
3. `hint` 可执行：给用户下一步动作。
4. 尽量避免返回裸异常名（例如 `FileNotFound`）给最终用户。

---

## 5) API 文档对齐

- 当前 v1.0 active API 文档入口是 `docs/api/README.md`。
- 旧 OpenAPI 草案已归档到 `docs/archive/api/openapi.yaml`，不再作为当前契约。
- 新增错误码时，必须同步更新本字典，并在对应 CLI/API 文档中说明可触发场景。

## 6) 后续落地

1. CLI/API 逐步替换零散错误文本为标准错误码。
2. 为高频 code 增加集成测试断言（至少覆盖 profile/proxy/diag 路径）。
