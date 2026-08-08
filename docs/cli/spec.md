# zc CLI spec — v1.0 contract

This document describes the command surface and output contract implemented by
`src/main.zig`, driven by the declarative command table in
`src/cli/commands.zig` and the output layer in `src/cli/output.zig`.
Help text is generated from the same table, so help can never drift from what
the binary accepts.

验收标准与决策记录见 [`ux-workflow.md`](ux-workflow.md)；错误码字典见
[`../api/error-codes.md`](../api/error-codes.md)。

## Global commands

| Command | Aliases | Notes |
| --- | --- | --- |
| `zc help [command]` / `zc --help` / `zc -h` | | Global help; `zc help start`、`zc help config download`、`zc help config` 均可。Unknown topic ⇒ `HELP_TOPIC_UNKNOWN`, exit 2. |
| `zc version` | `zc --version` | Prints version on stdout, exit 0; supports `--json`. |
| `zc start [-c <config>] [--port <port>] [--foreground] [--json]` | `zc up` | Fork-and-exit daemon start. `--foreground` runs without forking (containers/systemd). Background start fully prepares providers/overrides in the parent, then launches from an owner-only authenticated snapshot. Already-running daemon is reported as success (`detail:"already_running"`), exit 0. `--port` overrides mixed-port for this run. Override flags (`--override-script`/`--override-arg`/`--override-timeout-ms`) accepted. |
| `zc stop [--json]` | `zc down` | Stops the PID/nonce-bound daemon and removes its prepared snapshot. Already stopped ⇒ success (`detail:"already_stopped"`), exit 0. |
| `zc restart [-c <config>] [--port <port>] [--json]` | | Fully validates and freezes the target before stopping the captured PID/nonce. A post-stop startup failure restores the exact previous snapshot; a changed runtime instance is never stopped. The original source and CLI port override remain tracked for later reloads, while an explicit new override replaces the prior one-shot override. JSON 模式只输出**一个**最终 envelope（中间步骤文本走 stderr）。`--foreground` is rejected (exit 2). |
| `zc reload [--json]` | | Reloads the tracked original source, preserving its CLI port override; current hot reload falls back to the same instance-bound prepared restart. Daemon not running ⇒ `RELOAD_FAILED`, exit 1. Supervised foreground daemon（systemd/容器）拒绝并提示走 supervisor。 |
| `zc status [--json]` | | Daemon state, uptime, runtime paths, and current node of each select group. Stopped daemon is **still exit 0**（状态在 `data.state`，决策 D5）。 |
| `zc log [-n <lines>] [-f\|--no-follow] [--json]` | | Follows by default in text mode. `--json` = JSON Lines（每行一个 `{"line":"…"}` 事件），implies `--no-follow` unless `-f`. Default `-n` is 50 when not following. |
| `zc test [-c <config>] [--port <port>] [--json]` | | Connectivity probes through the configured proxy。文本与 JSON **跑相同探测**；any failed check ⇒ `error.code=CHECKS_FAILED` + per-check `data`, exit 1（决策 D3）。JSON 含 `daemon_state`、`selected_proxies`、`ports`、`checks`、`targets`。 |
| `zc doctor [-c <config>] [--json]` | | Config/daemon/port/connectivity diagnostics。文本标签冻结为 `Config:`、`Daemon:`、`PID:`、`Port:`、`Connection:`（健康输出含 `OK`/`valid`）。Failed checks ⇒ `CHECKS_FAILED` + `data.checks`, exit 1。JSON 含 `proxy_reachable`、`network_ok`、`config_ok` 与 `config_diagnostics_truncated`；validator 超过 256 条合计或单条 512 bytes 时文本会提示 omitted。 |

Lifecycle commands enforce 决策 D11 like every other tree: unknown flags,
stray positional arguments, and missing/invalid flag values (`-c`, `--port`,
`log -n`) are usage errors — envelope/error block + exit 2, never silently
ignored. `restart` shares `start`'s argument parser and therefore emits the
frozen `START_*` argument-error codes (messages/hints rendered for restart);
`stop`/`status`/`reload`/`log` use `<CMD>_ARGUMENT_INVALID`, and
`doctor`/`diag doctor` share `DIAG_DOCTOR_ARGUMENT_INVALID`.

v1 的 `external-controller` 只接受显式 `127.0.0.1:<port>`。启动必须绑定配置中的精确端口；端口已占用时返回 `START_CONTROLLER_PORT_IN_USE` / `RESTART_CONTROLLER_PORT_IN_USE`，不得自动改用相邻端口，也不得静默禁用控制面。

生命周期文件 `zc.pid`、`zc.lock`、`zc.log`、`zc.daemon.json` 与 `zc.daemon.lock` 统一位于经过校验的 runtime directory。设置 `XDG_RUNTIME_DIR` 时，它必须是绝对、规范化、由当前 euid 所有且权限为 `0700` 的既有目录；未设置时使用规范化 `$HOME/.local/state/zc/runtime`，其父目录不得由 group/other 写入，最终目录权限为 `0700`。不安全路径与 symlink fail closed；文件明确收敛为 `0600`，特殊文件不得在类型校验前阻塞读取。后台日志超过 8 MiB 后重置到新的 owner-only 文件，避免 runtime filesystem 无界增长；`zc log -f` 在日志暂时缺失或整个 runtime directory 被安全重建时持续重开，不退出也不永久钉住旧目录。

后台 `zc start` 先绑定所有配置 listener，并发布 `ready:false` 的 provisional descriptor；并发 `status`/`start` 不把它当作 running。exact desired reconciliation 完成后，daemon 持有 authority guard 与 selection barrier，并以独立 data-plane readiness barrier 阻塞包括 `DIRECT`/`REJECT` 在内的所有出站；descriptor 提升为 `ready:true` 后才释放数据面；并发 `start` 也以该 descriptor 作为最终就绪事实。`zc stop` 通过 descriptor nonce 认证的 runtime 请求让目标实例自行退出；descriptor/lock/PID 不一致时拒绝按数值 PID 发信号。运行中 lock path 缺失、inode 被替换或整个 runtime directory 被重建时，实例会校验继承 lock identity 并退出；`status`/`start` fail closed，不删除 live PID，也不形成永久双实例。`zc status` 返回 pid/lock/log 的实际路径；descriptor 位于同一 runtime directory，但不是冻结的 `paths` 字段。`proxy select` 只向 PID、instance nonce、revision、generation 与 endpoint 均匹配的 live descriptor 发送运行时变更；daemon 以 generation CAS 拒绝过期/乱序 apply；durable desired 领先时允许前跳到最新完整 snapshot，并在成功后推进 descriptor。descriptor 缺失、损坏或过期时只保留 durable selection，绝不回退猜测配置端点。显式 unmanaged 配置没有可比较 revision，`proxy select` 不做 live apply；需先 `zc config load` 导入。

The TUI command is excluded from v1.0 and is not present in help/dispatch.
`zc --daemon-run` is an internal mode used by `zc start` and is intentionally
undocumented in help.

## Command groups

Bare group commands (`zc config`, `zc proxy`, `zc profile`, `zc diag`) print
group help on stdout, exit 0. Every subcommand accepts `help`, `--help`, or
`-h` after the subcommand, e.g. `zc config download --help`.

### config

| Command | Notes |
| --- | --- |
| `zc config load <path> [--json]` | Validates and imports a local YAML plus its root-contained local provider assets into an immutable revision, makes it active, and never applies it to an already-running daemon (`data.applied:false`). Duplicate exact basename keys fail closed. YAML/proxy/provider/expanded-rule resource excess ⇒ `CONFIG_LOAD_LIMIT_EXCEEDED`; the 16 MiB source bound remains `CONFIG_LOAD_TOO_LARGE`. |
| `zc config list [--json]` | Alias `zc config ls`. Lists configs + active one (`data.configs`, `data.active`). |
| `zc config download <url> [-n <name>] [-d] [--json]` | Publishes an immutable revision through the catalog authority. `-d` requests activation; without `-d`, only the first **runtime-ready** managed config becomes active automatically. A first strict-YAML revision whose only recoverable defect is malformed/unsupported Shadowsocks simple-obfs metadata succeeds but remains inactive. Requesting its activation returns `CONFIG_CAPABILITY_UNSUPPORTED` and tells the user to retry without `-d`, inspect the retained source with `zc config dump -c <name> --no-override`, and repair its subscription source. Existing names fail closed. Missing `<url>` ⇒ `CONFIG_DOWNLOAD_URL_REQUIRED`, exit 2. Response body is limited to 16 MiB with a 30-second total deadline. YAML/proxy/provider/expanded-rule resource excess ⇒ `CONFIG_DOWNLOAD_LIMIT_EXCEEDED`; size excess stays `CONFIG_DOWNLOAD_TOO_LARGE`. `data.path` is null when compatibility mirror publication failed; the catalog commit still remains authoritative. |
| `zc config update [name] [--apply auto\|hot\|restart] [--json]` | Re-downloads a previously downloaded config under the same 16 MiB / 30-second limits and commits only if the fetched subscription revision is still the profile head. Concurrent head changes fail rather than publishing bytes fetched for stale metadata. A malformed replacement for the active profile returns `CONFIG_CAPABILITY_UNSUPPORTED`, tells the user only to repair the subscription source and retry, and leaves its exact authoritative state unchanged. YAML/proxy/provider/expanded-rule resource excess ⇒ `CONFIG_UPDATE_LIMIT_EXCEEDED`; downloaded-source or persisted-override materialization size excess ⇒ `CONFIG_UPDATE_TOO_LARGE`. Applies to a running daemon per `--apply`（默认 auto）。JSON 单 envelope：`data.applied` / `data.apply_result`。 |
| `zc config use <name> [--json]` | Switches the active config only when its exact revision is runtime-ready; a retained malformed revision returns `CONFIG_CAPABILITY_UNSUPPORTED`, points to `zc config dump -c <name> --no-override` for raw-source inspection, and does not change authoritative state. **绝不自动 apply**（决策 D8）：文本模式提示 `zc reload`；JSON `data.applied:false`。 |
| `zc config dump [-c <config>] [--no-override] [--json]` | Without `-c`, reads the exact active catalog revision; `--no-override` reads that revision's immutable source instead of its frozen materialization. A retained malformed recovery name is accepted directly by `-c`; text mode emits its verified raw YAML so the advertised recovery seam remains executable. Other dumps print a **bare document** — YAML in text mode, bare JSON object with `--json`（唯一 envelope 例外，决策 D2）。可直接 `\| yq` / `\| jq`。Runtime-ready Shadowsocks `plugin_opts` input is emitted as a canonical `plugin-opts` map with mode/host preserved. Failures still use the envelope/error block。 |
| `zc config override [<script>\|--clear] [--json]` | Bind/show/clear a frozen override by publishing a new immutable revision for the active config; applies to a running daemon. |

新托管配置名在剥除一个 `.yaml` 后必须为 1–250 字节的有效 UTF-8，且不能是 `.`、`..`，也不能包含控制字符、`/` 或 `\`。无效新名称返回 `CONFIG_NAME_INVALID`，并且不会发起网络或文件访问。旧版本已持久化的 251–255 字节 key 可继续读取和删除，避免升级时把 catalog 判坏；它们不再允许作为新 key，且兼容 mirror 可能报告 `mirror_out_of_sync:true`。bootstrap 通过共享 legacy cutover lock 冻结最终 snapshot 与 authority CAS；完成后，catalog v2 是 `load/list/download/update/use/delete/dump/override` 的唯一权威状态；`meta.json` 与 `configs/` 仅为派生兼容镜像，镜像损坏或不可写不会阻断健康 catalog 的读取。损坏 catalog、缺失 active identity 或缺失 immutable revision 均明确失败，不回退到内置 `DIRECT`。

Legacy cutover 与 `config download` 的 raw recovery 只会把明确标记为 malformed/unsupported 的 Shadowsocks simple-obfs 语义保留为 inactive 原始 revision，使其仍可通过 `config list/delete/update` 检视或替换；reserved proxy/group 名、未支持的 proxy/group type、基础字段、rule/reference/provider 等离线错误仍会拒绝，非 Shadowsocks plugin metadata 也不会进入 catalog。首个这类 recovery revision 不会占用“首个 runtime-ready config 自动 active”的位置；修复来源并成功 `config update` 后，显式 `config use` 才会激活它。这一恢复例外不绕过运行时 capability gate：`config download -d`、active update 与 `config use` 均以 `CONFIG_CAPABILITY_UNSUPPORTED` 拒绝非 runtime-ready identity，并保持已有 active identity。旧状态没有 active profile 时，`start`/`restart` 返回 `START_CONFIG_NOT_SELECTED` / `RESTART_CONFIG_NOT_SELECTED`，必须先执行 `zc config use <name>`。唯一支持的 Shadowsocks plugin shape 是 `obfs|obfs-local` + map options 中显式 `mode: http` 与合法非空 host；通用外部插件不会启动。classic AEAD Shadowsocks 节点可声明 `udp:true`，仅通过 mixed SOCKS5 UDP ASSOCIATE 使用；simple-obfs 不包装 UDP，standalone `socks-port` UDP、AEAD-2022、fragmentation 与其他协议 UDP 仍不支持。

Config YAML 共享固定上界：整个 decoded document 最多 **262144 个 collection entries**（每个 block/flow mapping entry 与 sequence item 都计数，包含 nested 和 unknown extension data）、4096 proxies、1024 proxy groups、兼容 mixed `proxies:` array 5120 entries、每组 5122 members；此外最多 **4096 个 rule providers**，managed capture 因而最多保留 4096 个 local-provider assets，且每个 config 或 provider source 都最多 **16 MiB**。所有 provider 合计最多 **262144 个 normalized entries / 64 MiB normalized entry bytes**，且每次 provider 同步与权威加载另有独立的 **64 MiB aggregate raw source bytes** 上界（comments 也计 raw budget）；`RULE-SET` 展开结果最多 **262144 条 rules / 64 MiB owned payload+target bytes**。单个 provider 同样不能超过 262144 entries。local-provider asset 超过默认或收紧后的单 asset 上界都发射 `RuleProviderFileTooLarge` 并进入 command-specific `*_LIMIT_EXCEEDED`，而不是完整 config 的 `*_TOO_LARGE`。classical entry 在展开预检中按完整 normalized entry length 作为保守 payload 上界；重复引用会重复计入 entry、target 与最终 rule count。全局 YAML entry budget 与这些上界同时生效，不能通过换字段、拆分 provider、重复 `RULE-SET` 或放大 target 绕过。

`config load/download/update` 分别把 `YamlCollectionEntryLimitExceeded`、proxy/group limits、`RuleProvider{Count,AggregateEntryCount,AggregateBytes}LimitExceeded` 与 `ExpandedRule{Count,Bytes}LimitExceeded` 映射为 `CONFIG_LOAD_LIMIT_EXCEEDED`、`CONFIG_DOWNLOAD_LIMIT_EXCEEDED`、`CONFIG_UPDATE_LIMIT_EXCEEDED`；16 MiB + 1 分别使用 `CONFIG_LOAD_TOO_LARGE`、`CONFIG_DOWNLOAD_TOO_LARGE`、`CONFIG_UPDATE_TOO_LARGE`。Provider names 先进入 bounded borrowed-key hash index；重复名称 fail closed，引用查找与展开为 `O(providers + rules + expanded)`，不会为每条 `RULE-SET` 线性扫描 providers。任何展开 count/byte 超限都在 output reserve/clone 之前拒绝；catalog 与 legacy admission 也在 revision publication、listener 或 dial 前执行同一 gate。这些是默认且用户可感知的拒绝；前后 authoritative `state-v2.json` 与 immutable revision tree 均不变，因此 token/sequence/head/active/desired 均不变。

每 profile 1024 persisted selections 是独立的 catalog/selection mutation seam 上界，不是 YAML source 字段。合法的 `config load/download/update` source 不会生成 `PersistedSelectionCountLimitExceeded`；已有 on-disk catalog 若超出该上界属于损坏状态并 fail closed，不映射为普通用户 limit，也不保留向后兼容。

Managed config JSON success data includes `durability_uncertain` and `mirror_out_of_sync`. A visible state commit whose parent-directory sync failed remains a success with `durability_uncertain:true`; callers must verify again before treating it as crash-durable. Mirror refresh failure is separately reported as `mirror_out_of_sync:true` and never changes catalog authority.

### proxy / profile

`profile` is an alias group for `proxy`（决策 D10）：same handler, messages and
hints rendered per command path. Shared select errors keep the frozen `PROXY_*`
codes on both paths; only the `*_ARGUMENT_INVALID` / `*_SUBCOMMAND_UNKNOWN`
codes carry the family prefix (`PROXY_…` / `PROFILE_…`).

| Command | Notes |
| --- | --- |
| `zc proxy list [-c <config>] [--json]` | Alias `zc proxy ls`. Groups + members + current selection（`data.groups[].now`），all names escaped via `std.json`。 |
| `zc proxy select [-g <group>] [-p <proxy>] [-c <config>] [--json]` | `-g` 只匹配 select 类型组（命中非 select 组 ⇒ `PROXY_GROUP_NOT_SELECTABLE`）。With `-p`: first commits the desired selection and increments its generation, then applies only to a daemon running the exact same config revision. Offline/mismatched daemon keeps `data.applied:false` but the selection is restored before listeners open on the next start. Interactive picker only when stdin is a TTY; non-TTY without `-p` ⇒ `PROXY_SELECT_NOT_INTERACTIVE`, exit 2。JSON without `-p` is read-only. |
| `zc proxy test [-c <config>] [--port <port>] [--json]` | Same probe path and `CHECKS_FAILED` semantics as `zc test`. |
| `zc profile list / select / test` | Same as the `proxy` equivalents. |

### diag

| Command | Notes |
| --- | --- |
| `zc diag doctor [-c <config>] [--json]` | Alias of `zc doctor`. |
| `zc diag` (bare) | Group help, exit 0. Flags without a subcommand ⇒ `DIAG_SUBCOMMAND_MISSING`; unknown subcommand ⇒ `DIAG_SUBCOMMAND_UNKNOWN`; both exit 2. |

## JSON contract（`--json`，全命令支持）

- Success: `{"ok":true,"command":"<path>","data":{...}}` — one line, **stdout**, exit 0.
- Failure: `{"ok":false,"command":"<path>","error":{"code":"…","message":"…","hint":"…"}}` — one line, **stdout**, exit ≠ 0. 诊断类命令（`test`/`doctor`/`proxy test`）失败时附带 `"data"`（逐项检查结果）。
- `command` is the canonical command path (aliases resolved), e.g. `"config list"`, `"proxy select"`.
- Exactly **one** JSON document per invocation on stdout. Streaming exception: `zc log --json` emits JSON Lines (one event object per line, no envelope).
- Bare-document exception: `zc config dump --json` prints the merged config as a bare JSON object (no envelope); text mode prints bare YAML.
- All JSON is serialized via `std.json`（真实转义，禁止手拼字符串）；`null` optional fields are omitted.

## Stream rules

- Payload（人类主输出 / JSON envelope / JSON Lines / dump 文档）→ **stdout**.
- Diagnostics and progress（校验警告、下载进度、restart 中间步骤、错误块）→ **stderr**.
- Text-mode errors render as an actionable block on stderr: `error: <message>` / `hint: …` / `code: …`.
- Color: ANSI only when the stream is a TTY and neither `NO_COLOR` (env) nor `--no-color` (flag) is set.
- Interactive UI（`proxy select` picker）只在 stdin 为 TTY 时进入。

## Exit codes

| Code | Meaning | Examples |
| --- | --- | --- |
| 0 | Success | `zc status`（含 stopped 状态）、`already_running`/`already_stopped`、help/version、picker cancel |
| 1 | Runtime failure | start/stop/reload failures, download/network errors, `CHECKS_FAILED`（test/doctor 探测失败）, config load failures, `COMMAND_UNKNOWN` |
| 2 | Usage error | bare `zc`, unknown subcommand, unknown/extra argument, missing flag value, `HELP_TOPIC_UNKNOWN`, non-TTY `select` without `-p`, `restart --foreground` |

JSON mode and text mode always share the same exit code. Failure paths never
print Zig stack traces.

## Help behavior

- `zc --help` / `zc -h` / `zc help` print global help to **stdout**, exit 0.
- `zc help <command>`、`zc help <group>`、`zc help <group> <subcommand>` print specific help; unknown topics ⇒ `HELP_TOPIC_UNKNOWN`, exit 2.
- `zc <command> --help` (and `-h`, or `help` as the first argument after the command) prints help and **never executes the command** — `zc start --help` must not start a daemon.
- 裸 `help` 词只在命令词后的**第一个**参数位识别（值恰好为 "help" 的后续参数不会被吞掉成帮助请求）；`-h`/`--help` 在任意位置生效。
- Bare `zc` prints a short usage line to **stderr**, exit 2.
- All help text is generated from `src/cli/commands.zig`（含 `Usage:` 字样、别名、Options、Examples）。

## Error output

Every failure carries a stable `code` (frozen vocabulary, see
[`../api/error-codes.md`](../api/error-codes.md)), a human-readable `message`,
and a next-step `hint` — identical content in JSON envelope and text error
block.
