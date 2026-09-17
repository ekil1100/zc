# 配置 Override

当前实现为 `src/override_script.rs`；命令编排位于 `src/cli.rs` / `src/service.rs`。一次性 CLI override 只影响本次准备；持久 override 发布新的 immutable revision，冻结脚本、参数、patch 与 materialized config，不覆盖原 source。

## 使用

```bash
zc start -c config.yaml --port 17890 --override-script rules.lua
zc config override rules.lua
zc config override
zc config override --clear
zc config dump
zc config dump --json
zc config dump --no-override
```

配置加载命令可使用 `--override-script <path>`、可重复 `--override-arg <k=v>`、`--override-timeout-ms <n>`。timeout 为 `1..60000` ms，默认 5000；0 不表示无限执行。旧 `--override-dump-yaml/json` 拒绝，改用 `config dump`。

优先级：一次性 CLI override > 当前 revision 已冻结的持久 override > 无 override。`config dump` 从 exact active revision 读取 materialization；有临时 override 时再执行一次，`--no-override` 读取 source。默认 restart 复用冻结快照，不自动重新执行脚本；reload 重读 tracked source，不能把两者混为一谈。

## 持久绑定

`config override <script>` / `--clear` 绑定操作开始时的 active identity 和 state token，离线校验候选后 CAS 发布；并发 config use/head 变化返回冲突，不能把脚本写到另一个 profile。原脚本提交后不再是读取该 revision 的依赖。清除时从未改变的 source 发布新 revision，旧 immutable revision 保留。

提交后只向匹配 exact 旧 identity 的 daemon 尝试 apply，目前使用实例绑定的 prepared restart。supervised foreground 须通过 supervisor 操作。apply 失败不否定已经持久化的新 revision，需检查 status 后显式恢复。`meta.json/configs` 只是兼容镜像，不是持久 override 的权威来源。

## Lua 与可执行脚本

### Lua（`.lua`）

Rust 通过 `mlua` 内嵌 Lua 5.4，在独立 worker 进程执行，**不需要系统 lua/luajit**。返回 table 作为 patch，nil 表示无 patch；也接受 YAML 字符串。输入：

```lua
input.command      -- e.g. "start" or "proxy.list"
input.config_path  -- selected source path or ""
input.script_path  -- selected script path
input.args         -- key/value arguments
```

```lua
return {
  rules = {
    "DOMAIN,blocked.invalid,REJECT",
    "MATCH,DIRECT",
  },
}
```

重复参数 key 后者覆盖前者；`;`、`=`、空值原样保留，不按拼接分隔符猜测。worker 提供相应 `ZC_OVERRIDE_*` 环境输入。

Lua worker 可使用标准 io/os；这是**受信任脚本执行，不是安全沙箱**，可能访问文件或创建子进程。与旧解释器环境可能有差异，不保证 LuaJIT/外部 Lua 模块兼容。脚本/输出各最多 1 MiB，Lua 内存预算 64 MiB、指令预算 5000 万，并受父进程 absolute timeout；stdout/stderr 各有界，超时/取消清理进程组。脚本日志不要混入 YAML stdout。

### 非 Lua 可执行脚本

选定文件必须是有执行权限的普通文件，stdout 输出一个 YAML map。脚本以冻结副本执行，环境清理后只传调用元数据，不保证继承 shell/PATH；需使用明确 shebang 与所需工具绝对路径。子进程同样受 deadline、输出上界与进程组回收约束。

```yaml
rules:
  - MATCH,DIRECT
```

## 合并与能力 gate

- patch 必须是完整 YAML map；重复 key、尾随非注释内容、畸形/超限文档拒绝。
- scalar 替换；`rule-providers` 整 map 替换；`proxies/proxy-groups/rules` 整 list 替换，不增量拼接。
- 未知/不支持字段或非法类型报错。YAML null 可清除 `external-controller`；字符串 `"null"` 不等同 null。
- patch 事务式验证，失败不改变 source/authority。空 patch 也必须经过 capability gate；不能借 override 绕过 reserved 名称、未启用类型、standalone listener 或 plugin gate。
- `mixed-port` patch 不控制实际端口，真正 bind 仍为 CLI `--port` 或生产默认 7899。兼容字段仅在 `runtime_source` 投影中移除，不能把投影字节写回 revision 冒充原 proof。
- 共享资源上界见 [兼容说明](../compat/mihomo-clash.md#配置资源上界)，replacement 不得截断、绕过计数或部分发布。额外 1 MiB patch/脚本上界同时生效。

`plugin_opts/plugin-opts` map 输入规范成 `plugin-opts`，保留 mode/host；非 SS plugin、未知 plugin/mode、非 map 或冲突 alias 拒绝。不启动外部 SIP003 插件。

## Provider：离线与网络准备分开

Managed materialization 只使用捕获的本地 assets。被 RULE-SET 引用的 HTTP provider 在离线发布/激活 gate 拒绝；未引用声明可 deferred。持久 override 加入远程 RULE-SET 并不使 managed revision 自动获得网络权限。

Unmanaged 来源在准备阶段同步、校验并冻结 HTTP provider bytes；已支持 root-contained cache、interval 刷新、普通网络失败时的已验证缓存回退，以及独立 `zc test` 的 missing-only 策略。畸形、超限或发布错误不得回退；不使用 curl fallback。reload preparation 失败时旧运行实例继续服务。完整策略与安全边界见 [兼容说明](../compat/mihomo-clash.md#rule-provider-与离线托管)。

## Dump 与错误

普通 dump 输出裸 YAML / JSON，脱敏 password、uuid、secret、sni 等字段；不加 CLI envelope，便于 jq/yq。失败仍使用标准错误 envelope。

唯一敏感例外：`config dump -c <name> --no-override` 的 malformed recovery-only **文本**输出保留经验证的 raw source，可能包含凭据；终端不安全字符拒绝，重定向保留字节。不要将其发到公开日志。

常见错误：`OVERRIDE_SCRIPT_NOT_FOUND`、`OVERRIDE_SCRIPT_EXEC_FAILED`、`OVERRIDE_SCRIPT_TIMEOUT`、`OVERRIDE_OUTPUT_INVALID`、`OVERRIDE_MERGE_FAILED`、`OVERRIDE_OPTION_DEPRECATED`、`CONFIG_OVERRIDE_APPLY_FAILED`、`CONFIG_DUMP_FAILED`。完整词汇见 [错误码](../api/error-codes.md)。

非 `NotFound` 的 spawn 错误保留操作系统原因，便于区分权限、可执行文件忙与资源问题；不附带脚本内容或脚本 stderr，错误码仍为 `OVERRIDE_SCRIPT_EXEC_FAILED`。

示例 [override-loyalsoldier-rules.lua](examples/override-loyalsoldier-rules.lua) 引用远程 provider，适用于 unmanaged 网络准备；不能据此宣称 managed offline 支持 HTTP RULE-SET。
