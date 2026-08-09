# Runtime Config Override

`zc` supports runtime config override for commands that load config (`start`, `test`, `doctor`, `proxy ...`).

A one-shot CLI override is in-memory only. A persistent override is captured as a new immutable managed revision; the source profile bytes remain unchanged, while the validated materialized result is frozen in that revision.
You can bind a persistent override script to the active config profile via `zc config override`.

## CLI Flags

- `--override-script <path>`: run override script.
- `--override-arg <k=v>`: repeatable key/value arguments passed to script.
- `--override-timeout-ms <n>`：脚本超时范围为 `1..60000` ms，默认 `5000`；`0` 不再表示无期限执行。

For merged config output, use:

- `zc config dump` (YAML)
- `zc config dump --json` (JSON)
- `zc config dump --no-override` (ignore all override scripts and dump source config)

## Persistent Binding (Per Config)

- `zc config override <script.lua>`: bind a persistent override script to current config.
- `zc config override --clear`: clear persistent binding for current config.
- `zc config override`: show current config binding status.

Persistence scope is the active profile's immutable catalog revision. `meta.json` and `configs/` are compatibility mirrors and are never authoritative writers.
When setting override:

- script bytes, invocation metadata, emitted patch, and materialized config are captured in a new revision
- the active profile and authority token are bound before materialization; a concurrent `config use` or head change fails with a retryable conflict
- the candidate is parsed and validated offline before the profile head advances
- the original script file is no longer required after a successful commit
- if the daemon is running, the exact committed revision is auto-applied (`auto`: try hot, fallback to an instance-bound prepared restart)

When clearing override, a new revision is published from the unchanged source bytes without the frozen override. Existing immutable revisions remain available for exact identity checks.

Runtime priority:

1. CLI `--override-script` (highest, one-shot)
2. persisted `zc config override` binding
3. no override

## Script Contract

### Mode A: Lua script (`*.lua`)

`zc` executes lua script and expects:

- return `table`: override object
- return `nil`: no override

Requirement: `luajit` or `lua` executable must be available in runtime environment.

Global input available in script:

```lua
input.command      -- string, e.g. "test" / "proxy.list"
input.config_path  -- base config path or ""
input.script_path  -- resolved override script path
input.args         -- key/value map from --override-arg
```

Lua 参数通过逐项环境变量传输，值中的 `;`、`=` 和空字符串会原样保留；重复 key 按命令行顺序由后一个值覆盖前一个值。

Example:

```lua
return {
  mode = "global",
  ["log-level"] = "debug",
  ["mixed-port"] = 7899,
}
```

### Mode B: executable script (non-lua)

Executable script should print YAML override map to stdout.

Example output:

```yaml
mode: global
log-level: debug
```

## Merge Rules

- override stdout 必须是一个完整 YAML map；重复 key、尾随非注释内容和畸形文档会被拒绝
- 整个 patch 采用事务式提交：语法、类型、分配或语义失败时，原配置保持不变
- scalar keys: replace
- map key `rule-providers`: whole-map replace
- list keys (`proxies`, `proxy-groups`, `rules`): whole-list replace
- unknown/unsupported key: error (`OVERRIDE_OUTPUT_INVALID`)
- YAML `null` 清除 `external-controller`；带引号的 `"null"` 保持为字符串

The materialized result remains subject to all shared fixed limits: 4096 proxy nodes, 1024 proxy groups, 5120 mixed `proxies:` entries, 5122 members per group, 4096 rule providers, 262144 aggregate normalized provider entries / 64 MiB normalized bytes, 64 MiB aggregate raw provider source bytes per synchronization/authoritative load pass (16 MiB per source), and 262144 expanded rules / 64 MiB owned payload+target bytes. Override replacement cannot bypass or truncate these limits. The parser exposes typed proxy/provider/expanded-rule limit errors; the override transaction surfaces its existing merge/apply failure code. Reduce/filter the replacement list and retry; there is no limit switch or fallback.

`RULE-SET` in `rules` is supported via `rule-providers`. Each provider is also bounded to 262144 normalized entries, including raw legacy/classical lines. Multiple providers share the aggregate normalized budgets and the independent 64 MiB raw-source budget; a raw payload at the exact normalized aggregate bound succeeds and its next normalized entry returns `RuleProviderAggregateEntryCountLimitExceeded` before cloning. A YAML wrapper may instead reach the separate global decoded-YAML budget first. Expansion uses a borrowed-key hash index, rejects duplicate provider names, charges repeated references and targets, and reserves output only after a checked count/byte preflight. YAML allocation, collection-budget, and nesting failures never fall back to the line parser. Managed revisions expand captured local providers offline, but a referenced remote provider left as `RULE-SET` is not catalog-admissible or runtime-ready; it is rejected before revision publication and at the exact activation gate. Unreferenced remote provider declarations may remain deferred.

Frozen materialization applies the shared v1 runtime-capability gate to both empty and non-empty patches. Reserved proxy/group declarations, disabled proxy/group types, standalone `port`/`socks-port`, and plugin capability errors all return `UnsupportedCapability`. 这里的 standalone 指结果中没有非零 `mixed-port`；若 mixed listener 已配置，额外的 `port`/`socks-port` 仅作为 ignored compatibility declarations 保留，运行时不会绑定它们。This materialization gate performs no provider download or local-asset resolution; those remain responsibilities of the later bundle/offline-runtime preparation stages.

Runtime preparation behavior:

- missing provider file + `url` present: download required (failure returns error)
- existing provider file + `url` present + interval due: best-effort refresh (failure keeps cached file)
- `zc test` exception: if the provider file already exists, skip interval-based refresh and reuse the local cache
- missing provider file without `url`: `RULE_PROVIDER_FILE_NOT_FOUND`

## Dump Output

`zc config dump` normally prints merged config with sensitive fields redacted (`password`, `uuid`, `secret`, `sni`).
`zc config dump` reads the frozen materialized bytes from the exact active revision. A temporary override flag is then applied once, if supplied. `--no-override` reads the immutable source bytes instead. Shadowsocks `plugin_opts`/`plugin-opts` map input is normalized to canonical `plugin-opts` output, preserving `mode` and `host`. The recovery-only text command `zc config dump -c <name> --no-override` emits a retained malformed revision's verified raw YAML because it cannot be safely normalized; treat that output as sensitive.

## Error Codes

- `OVERRIDE_SCRIPT_NOT_FOUND`
- `OVERRIDE_SCRIPT_EXEC_FAILED`
- `OVERRIDE_SCRIPT_TIMEOUT`
- `OVERRIDE_OUTPUT_INVALID`
- `OVERRIDE_MERGE_FAILED`
- `OVERRIDE_OPTION_DEPRECATED`
- `RULE_PROVIDER_DOWNLOAD_FAILED`
- `RULE_PROVIDER_FILE_NOT_FOUND`
- `CONFIG_OVERRIDE_APPLY_FAILED`
- `CONFIG_DUMP_FAILED`

## Example

- Lua rules override example: `docs/config/examples/override-loyalsoldier-rules.lua`
