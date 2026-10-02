# CLI/API 错误码

本字典说明公开错误码及处理方式；历史内部错误名不保证逐项出现在当前输出中。message/hint 列是英文输出示例，不要求逐字相同。

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

## 3) CLI 错误码

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
| `START_CONFIG_NOT_SELECTED` | no active config is selected | run `zc config list`, then `zc config use <name>` |
| `START_PORT_IN_USE` | requested start port is already in use | retry with `zc start --port <free-port>` |
| `START_CONTROLLER_PORT_IN_USE` | configured controller port is already in use | free the exact `external-controller` port or update the config |
| `START_PORT_CONFLICT` | requested start port conflicts with another runtime listener | change the port or fix the conflicting runtime config |
| `START_BIND_ADDRESS_INVALID` | invalid bind address for start preflight | fix `bind-address` in config and retry |
| `START_EXTERNAL_CONTROLLER_INVALID` | invalid `external-controller` address in config | use an explicit loopback endpoint such as `127.0.0.1:9090` |
| `START_PREFLIGHT_FAILED` | failed to validate daemon start ports | check config and retry |
| `STOP_FAILED` | failed to stop daemon | verify process permissions and retry `zc stop` |
| `STOP_TIMEOUT` | daemon did not acknowledge the stop request within 5 seconds | inspect `zc status` and the daemon log before retrying |
| `STOP_CLEANUP_FAILED` | daemon stopped without removing its prepared snapshot, or a timed-out stop request could not be disarmed | repair the owner-only runtime directory before retrying |
| `RESTART_FAILED` | failed to restart daemon | check logs and retry `zc restart -c <config>` |
| `RESTART_INVOCATION_UNTRACKED` | running daemon invocation could not be captured safely | restart it through its supervisor or original command |
| `RESTART_FAILED_ROLLED_BACK` | new daemon failed, so the previous invocation was restored | fix the target config and retry |
| `RESTART_ROLLBACK_FAILED` | new daemon failed and the previous invocation could not be restored | inspect status/logs and start the known-good config explicitly |
| `RESTART_CONTENDED` | another daemon acquired the runtime during restart | inspect `zc status` before retrying |
| `RESTART_READINESS_TIMEOUT` | daemon did not publish readiness before the startup deadline | check override duration, port ownership, and the daemon log |
| `RESTART_CONFIG_NOT_SELECTED` | no active config is selected for restart | run `zc config list`, then `zc config use <name>` |
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

### B2. connection 家族

| code | 触发条件 | 恢复方式 |
|---|---|---|
| `CONNECTION_ARGUMENT_INVALID` | 裸组全局选项后仍有非法/多余参数 | 使用 `zc help connection`，exit 2 |
| `CONNECTION_SUBCOMMAND_UNKNOWN` | 未知子命令 | 仅使用 list 或 close，exit 2 |
| `CONNECTION_LIST_ARGUMENT_INVALID` | list 的非法参数 | 使用 `zc connection list [--json]`，exit 2 |
| `CONNECTION_CLOSE_ID_REQUIRED` | 缺少 ID | 从 list 取得 ID，exit 2 |
| `CONNECTION_CLOSE_ARGUMENT_INVALID` | 非法 ID、额外参数或 `--all` | 使用完整 `<nonce>-<序号>`，exit 2 |
| `CONNECTION_NOT_RUNNING` | 没有已验证的 ready 实例 | 显式准备配置并启动，exit 1 |
| `CONNECTION_CONTROLLER_REQUIRED` | 冻结配置没有 controller | 配置 controller 后显式 `restart -c <config>`；托管自动提供 secret，非托管还需手工配置；默认 restart 冻结 |
| `CONNECTION_SECRET_REQUIRED` | 冻结配置无非空 secret，或 API 返回 403 | 托管显式 `restart -c <profile>` 启用自动值；非托管先配置非空 secret；不是默认 restart |
| `CONNECTION_UNAUTHORIZED` | API 返回 401 | 核对运行实例及冻结 secret，不输出或分享凭据 |
| `CONNECTION_INSTANCE_CHANGED` | PID/nonce/endpoint/exact identity 或快照不可验证、响应实例头缺失/不匹配、旧 ID、API 409 | 重新 list，仅操作当前实例 ID |
| `CONNECTION_NOT_FOUND` | API 404，连接已回收 | 重新 list；不存在历史记录 |
| `CONNECTION_RESPONSE_INVALID` | schema/JSON/响应完整性错误、超过 4 MiB 或 API 无法生成完整响应 | 核对 controller 版本，减少过大的节点/规则展示数据 |
| `CONNECTION_FAILED` | 其他控制请求、超时、文件读取等失败 | 检查 status/controller；不会创建新监听器 |

除明确列出的用法错误外均 exit 1，文本/JSON 同码。错误不回显 secret、目标或控制器响应正文。CLI 的 DELETE 成功仅为 `close_requested:true`，不能自动重试为“已回收”；仍在 closing 的条目可重复请求，消失后 404。

API 保持 `{"error":"…"}`，不发 CLI 信封或上述 code：非空 secret 缺失 403，缺失/错误 Bearer 401，格式错误 400，实例不符 409，条目不存在 404，完整编码超限 500。旧 GET/PUT 鉴权规则不变。协议与元数据详见 [API](README.md)。

### B3. service 与本地冷升级

| code | 触发条件 | 恢复方式 |
|---|---|---|
| `SERVICE_SUBCOMMAND_UNKNOWN` / `SERVICE_ARGUMENT_INVALID` / `SERVICE_<ACTION>_ARGUMENT_INVALID` | 未知动作、缺值、非法端口或多余参数 | 使用 `zc help service`；用法错误 exit 2 |
| `SERVICE_USER_REQUIRED` / `SERVICE_HOME_MISMATCH` | root 或 HOME 与操作系统登录用户不一致 | 用原登录用户及其 HOME；环境覆盖不授予服务管理权限 |
| `SERVICE_NOT_REGISTERED` | 未注册却请求 restart | 显式 `zc service start -c <config> --port <port>` |
| `SERVICE_OWNED` | 普通生命周期命令触及注册 runtime | 使用对应 service 命令；重新准备来源须显式 `-c` |
| `SERVICE_MANUAL_INSTANCE` | 服务/安装操作遇到手动或其他调用 | 确认原 namespace，按原方式停止，再显式迁移；原实例保留 |
| `SERVICE_EXECUTABLE_PATH_UNSUPPORTED` | Linux 二进制绝对路径含引号或反斜杠 | 在不含这些字符的路径安装后注册；空格、`$`、`%` 可用；拒绝先于配置准备与服务状态创建 |
| `SERVICE_TARGET_MISMATCH` | 二进制路径、HOME、runtime 或平台与注册不一致 | 使用已注册安装及其环境，勿换 namespace 绕过 |
| `SERVICE_STATE_INVALID` / `SERVICE_FOREIGN` | 注册、快照、定义缺失/损坏/内容或调用不符 | 保留现场，核查所有权及备份，不删除重建 |
| `SERVICE_RUNNING` | start/enable 试图修改运行中配置 | 使用显式 service restart，或先停止再配置 |
| `SERVICE_INSTANCE_MISMATCH` / `SERVICE_CONTENDED` | 管理器/daemon 身份不符、并发启动/发布 | 检查两个状态及实际进程；未证明的实例不会被停止 |
| `SERVICE_MANAGER_UNAVAILABLE` / `SERVICE_MANAGER_FAILED` | 管理器不可执行、登录域不可用、拒绝访问或返回异常 | 检查当前用户登录会话及管理器；与 unit 不存在分开处理 |
| `SERVICE_MANAGER_TIMEOUT` / `SERVICE_MANAGER_OUTPUT_LIMIT` | 单次命令超过 15 秒或单流输出超过 64 KiB | 检查管理器健康；输出正文不会回显 |
| `SERVICE_START_FAILED` / `SERVICE_STOP_FAILED` | 未取得真实 readiness 或停止证明 | 停止失败恢复原注册/启动许可；若已停止，确认状态后显式 start；结果不明先核对管理器与实例 |
| `SERVICE_START_FAILED_ROLLED_BACK` | service restart 新调用失败，旧调用已恢复 | 修复目标输入后重试；命令仍 exit 1 |
| `SERVICE_CANDIDATE_INVALID` / `SERVICE_TARGET_INVALID` / `SERVICE_PUBLISH_FAILED` | 候选检查、安装目标或安全 staging 失败 | 保留旧安装，核查候选、目标权限与遗留进程 |
| `SERVICE_INSTALL_INTERRUPTED` | 本地安装收到 SIGINT/SIGTERM | 等待命令回收与恢复结果；作为回滚/恢复失败的原因保留，不强杀恢复过程 |
| `SERVICE_COMMAND_CLEANUP_FAILED` | 命令组终止或直接子进程回收失败 | 保留工件并核对遗留发布进程；锁释放本身不证明发布已结束 |
| `SERVICE_INSTALL_ROLLED_BACK` | 冷升级失败，旧二进制与原启停状态已恢复 | 修复原因后重试；不会按默认 profile 启动 |
| `SERVICE_RECOVERY_FAILED` | 旧二进制/精确调用恢复失败 | 保留 `.zc.recovery.*`、注册和认证快照，先核查状态再恢复 |
| `SERVICE_FAILED` | 其他服务文件系统或状态检查失败 | 检查路径、权限、注册及日志，保留现场 |

除用法错误外均 exit 1；服务命令沿用公开 CLI JSON 信封，不新增 HTTP API。冻结配置准备可能沿用既有 `CONFIG_*` / `START_*` 错误；锁或文件系统错误可通过 `SERVICE_FAILED` 报告。安装内部入口输出脱敏英文错误并返回非零，`just` 传播失败。

### C. 配置类（CONFIG_*）

| code | message 示例 | hint 示例 |
|---|---|---|
| `CONFIG_LOAD_PATH_REQUIRED` | missing `<path>` for config load | use `zc config load <path>` |
| `CONFIG_LOAD_ARGUMENT_INVALID` | unknown or unexpected argument for `config load` | use `zc config load <path>` |
| `CONFIG_LOAD_INVALID` | local config is invalid | fix listed validator errors, YAML structure/field types/rule ordering, or keep file-provider paths relative and inside the config source directory |
| `CONFIG_LOAD_TOO_LARGE` | local config exceeds the 16 MiB limit | reduce the complete config source to 16 MiB or less and retry |
| `CONFIG_LOAD_LIMIT_EXCEEDED` | config exceeds a fixed YAML/proxy/rule-provider/expanded-rule resource limit | remove unused collections, providers, provider entries, repeated references, or long targets and retry |
| `CONFIG_CAPABILITY_UNSUPPORTED` | config revision cannot be activated because it uses an unsupported runtime capability | follow the command-specific recovery hint described below |
| `CONFIG_LOAD_FAILED` | failed to load local config | check the path, local dependencies, and file permissions |
| `CONFIG_ALREADY_EXISTS` | a config with this name already exists | rename the file or delete the existing config first |
| `CONFIG_NAME_INVALID` | invalid config name | after removing one `.yaml` suffix, use 1-250 bytes of valid UTF-8; not `.`/`..`; exclude control/bidirectional characters, `/` and `\` |
| `CONFIG_LIST_FAILED` | failed to list configs | ensure the config directory exists and is readable |
| `CONFIG_LIST_ARGUMENT_INVALID` | unknown or unexpected argument for `config list` | use `zc config list [--json]` |
| `CONFIG_DOWNLOAD_URL_REQUIRED` | missing <url> for config download | use `zc config download <url> [-n <name>] [-d]` |
| `CONFIG_DOWNLOAD_NAME_REQUIRED` | missing value for `-n` | use `zc config download <url> -n <name>` |
| `CONFIG_DOWNLOAD_ARGUMENT_INVALID` | unknown or unexpected argument for `config download` | use `zc config download <url> [-n <name>] [-d]` |
| `CONFIG_DOWNLOAD_TOO_LARGE` | downloaded config exceeds the 16 MiB limit | reduce the config size and retry |
| `CONFIG_DOWNLOAD_LIMIT_EXCEEDED` | config exceeds a fixed YAML/proxy/rule-provider/expanded-rule resource limit | remove unused collections, providers, provider entries, repeated references, or long targets and retry |
| `CONFIG_DOWNLOAD_TIMEOUT` | config download exceeded the 30 second deadline | check the server or network and retry |
| `CONFIG_DOWNLOAD_FAILED` | failed to download config | check the url/network and retry |
| `CONFIG_UPDATE_APPLY_INVALID` | invalid `--apply` value | use `--apply auto\|hot\|restart` |
| `CONFIG_UPDATE_ARGUMENT_INVALID` | unknown or unexpected argument for `config update` | use `zc config update [name] [--apply auto\|hot\|restart]` |
| `CONFIG_UPDATE_NAME_REQUIRED` | no config name given and no active config | use `zc config update <name>`, or `zc config use <name>` first |
| `CONFIG_UPDATE_NO_SUBSCRIPTION` | no subscription url recorded for this config | use `zc config download <url>` to (re)create it |
| `CONFIG_UPDATE_TOO_LARGE` | updated source or its persisted-override materialization exceeds the 16 MiB limit | reduce the config size and retry |
| `CONFIG_UPDATE_LIMIT_EXCEEDED` | config exceeds a fixed YAML/proxy/rule-provider/expanded-rule resource limit | remove unused collections, providers, provider entries, repeated references, or long targets and retry |
| `CONFIG_UPDATE_TIMEOUT` | config update exceeded the 30 second deadline | check the server or network and retry |
| `CONFIG_UPDATE_CONFLICT` | config changed while its update was downloading | retry against the new profile revision |
| `CONFIG_UPDATE_FAILED` | failed to update config | check subscription url/network and retry |
| `CONFIG_UPDATE_APPLY_FAILED` | config updated but failed to apply to running daemon | check `zc log --no-follow`, then run `zc restart` |
| `CONFIG_USE_NAME_REQUIRED` | missing <name> for config use | use `zc config use <name>`; run `zc config list` to see candidates |
| `CONFIG_USE_ARGUMENT_INVALID` | unknown or unexpected argument for `config use` | use `zc config use <name>` |
| `CONFIG_NOT_FOUND` | config not found | run `zc config list` and pick an existing config name |
| `CONFIG_SWITCH_FAILED` | failed to switch active config | verify file permission and retry |
| `CONFIG_DUMP_ARGUMENT_INVALID` | unknown or unexpected argument for `config dump` | use `zc config dump [-c <config>] [--no-override]` |
| `CONFIG_DUMP_FAILED` | failed to dump merged config | check config path/override script and retry |
| `CONFIG_DUMP_UNSAFE_TERMINAL` | raw config contains unsafe terminal controls | redirect stdout to a file to preserve raw bytes |
| `CONFIG_OVERRIDE_ARGUMENT_INVALID` | invalid config override arguments | use `zc config override <script.lua>` / `--clear` |
| `CONFIG_OVERRIDE_NO_ACTIVE` | no active config found for override | run `zc config use <name>` first |
| `CONFIG_OVERRIDE_SCRIPT_NOT_FOUND` | override script file not found | check script path and retry |
| `CONFIG_OVERRIDE_FAILED` | failed to update persisted config override | check config state and retry |
| `CONFIG_OVERRIDE_APPLY_FAILED` | override persisted but failed to apply running daemon | check logs and run `zc restart` |
| `CONFIG_DELETE_NAME_REQUIRED` | missing config name | use `zc config delete <name>` |
| `CONFIG_DELETE_ARGUMENT_INVALID` | invalid delete arguments | use `zc config delete <name>` |
| `CONFIG_DELETE_FAILED` | failed to delete config reference | inspect catalog state without deleting immutable data |
| `CONFIG_SUBCOMMAND_UNKNOWN` | unknown config subcommand | use `zc config --help` to list config subcommands |

`CONFIG_LOAD_INVALID` 是 validator 完成后的语义失败：文本 stderr 在错误块后列出具体 errors/warnings；JSON failure envelope 附带 `data.config_errors`、`data.config_warnings`、`data.config_diagnostics_truncated`。errors 优先于 warnings，占满 256 条共享上界时仍至少保留一条可操作 error。parser/I/O/resource-limit/name 错误不伪造这些字段。

YAML source 的 `CONFIG_{LOAD,DOWNLOAD,UPDATE}_LIMIT_EXCEEDED` 覆盖底层
`YamlCollectionEntryLimitExceeded`、proxy/group limits，以及
`RuleProviderCountLimitExceeded`、`RuleProviderFileTooLarge`、
`RuleProviderAggregateEntryCountLimitExceeded`、`RuleProviderAggregateBytesLimitExceeded`、
`RuleProviderAggregateSourceBytesLimitExceeded`、
`ExpandedRuleCountLimitExceeded` 与 `ExpandedRuleBytesLimitExceeded`。固定
provider/rule 合同为 4096 providers、所有 providers 合计 262144 normalized
entries / 64 MiB normalized bytes、每次同步或权威加载合计 64 MiB raw provider
source bytes、展开后 262144 rules / 64 MiB owned payload+target bytes；每个
provider 自身也最多 262144 entries，且单个 source 最多 16 MiB。managed capture
最多保留 4096 个 local-provider assets；单 asset 的默认与 custom-tightened capture
上界都稳定发射 `RuleProviderFileTooLarge`，由 load/download/update 映射到各自的
`*_LIMIT_EXCEEDED`。aggregate raw limit 同样属于 `*_LIMIT_EXCEEDED`；完整 config
自身的 16 MiB source limit 仍使用独立 `*_TOO_LARGE`。超限在 provider
entry clone、expanded output reserve、revision publication、listener 和 dial 之前
拒绝；前后 authoritative `state-v2.json` 与 immutable revision tree 不变，因此
token/sequence/head/active/desired 均不变。64 MiB bundle/source aggregate 与
revision manifest 的独立 1 MiB 编码上界均未因单 asset 放宽而改变。

`PersistedSelectionCountLimitExceeded` 不是 config YAML source 字段。1024
persisted-selection 上界在 catalog/selection mutation seam 执行；CLI
config handler 保留该 error 的防御映射，但 `load/download/update` 的合法 YAML
路径不会构造它。已有 `state-v2.json` 若含 1025 项或更多 selection，按损坏
catalog fail closed，不降级为普通用户 limit，亦不提供旧状态兼容豁免。

`config download -d`、active `config update` 或 `config use` 试图激活一个
保留的非 runtime-ready revision 时统一返回 `CONFIG_CAPABILITY_UNSUPPORTED`，
但 recovery hint 按可执行命令区分：download 提示先去掉 `-d` 保留 inactive
revision，再运行 `zc config dump -c <name> --no-override` 检视其 retained raw
source 并修复 subscription source；active update 只提示修复 subscription source
后重试；use 同样提示用 `config dump` 检视已存在 name 的 raw source。三种拒绝
均保持 authoritative state 逐字节不变。

`CONFIG_UPDATE_TOO_LARGE` 同时覆盖下载 body/source 上界与 persisted override
重新 materialize 后的 effective source 上界。后一种情况即使下载 source 本身小于
16 MiB 也会在 publish 前失败；authoritative `state-v2.json` 逐字节不变。

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
`checks`），exit 1（决策 D3）。`test` 及其别名现在要求全部目标成功；部分成功同样返回此码，`data.summary` 提供成功/失败计数与状态，`data.targets` 保留逐项目标结果。端口不可达时摘要为 `not_run`。字段及旧版兼容变化见 [CLI 契约](../cli/spec.md#test-的可用性摘要与实际路径)。

### F. override / rule-provider

| code | message 示例 | hint 示例 |
|---|---|---|
| `OVERRIDE_SCRIPT_NOT_FOUND` | override script or executable interpreter not found | check the selected script path or executable interpreter |
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

1. `code` 稳定：供前端/脚本分支判断。
2. `message` 可读：一句话说清发生了什么。
3. `hint` 可执行：给用户下一步动作。
4. 尽量避免返回裸异常名（例如 `FileNotFound`）给最终用户；CLI 在 envelope 之外可经 stderr 附加真实错误名作诊断。

---

## 6) API 与诊断边界

- HTTP API 使用 `{"error":"…"}` 简单响应，不承诺 CLI envelope；端点及状态码见 [Minimal API](README.md)。
- 配置资源超限使用公开 `CONFIG_*_LIMIT_EXCEEDED` 等错误码，脚本不应依赖内部 Rust 错误类型名称。
- 部分配置加载路径只返回概括性错误；doctor 的详细诊断范围见 [CLI](../cli/spec.md)。
- `durability_uncertain:true` 是可见提交成功但持久性未确认，不应当作失败后自动重试发布；`mirror_out_of_sync:true` 也不代表 catalog commit 失败。
