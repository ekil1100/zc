# zc CLI 契约

当前 Rust 入口是 `src/main.rs` / `src/cli.rs`；命令表生成帮助，服务编排位于 `src/service.rs`，实例生命周期位于 `src/daemon.rs`，持久权威位于 `src/store.rs`。本文件保留原 CLI 行为契约；[迁移说明](../migration/rust.md) 单独列出尚未对齐的差异，不以实现缺口改写规范。历史决策见 [UX 工作流](ux-workflow.md)，冻结错误码见 [字典](../api/error-codes.md)。

## 完整命令表

所有公开命令支持 `--json`；`-c` 等同于 `--config`。裸 `config/proxy/profile/diag` 输出组帮助并退出 0。每个命令接受 `help`、`--help`、`-h`，帮助请求不执行业务。

| 命令 | 行为 |
| --- | --- |
| `zc help [command [subcommand]]`、`zc --help`、`zc -h` | 帮助写 stdout；未知主题 `HELP_TOPIC_UNKNOWN`，exit 2 |
| `zc version`、`zc --version` | 版本写 stdout，exit 0 |
| `zc start [-c <config>] [--port <port>] [--foreground]` | 别名 `up`；默认后台，父进程完成准备后启动认证快照；已运行返回成功 `detail:already_running` |
| `zc stop` | 别名 `down`；只停止当前 PID/nonce 绑定实例并清理对应 snapshot；已停止成功 `detail:already_stopped` |
| `zc restart [-c <config>] [--port <port>]` | 默认复用运行实例冻结快照；显式来源/override 才重新准备；目标先冻结、后停旧实例，失败尝试精确回滚 |
| `zc reload` | 重读 tracked source，保留 CLI 端口覆盖；当前成功路径为 restart fallback；未运行返回 `RELOAD_FAILED` |
| `zc status` | 实际 daemon 状态、uptime、端口、路径、select 当前选择；stopped 也是 exit 0 |
| `zc log [-n <lines>] [-f\|--no-follow]` | 文本默认 follow；JSON 默认不 follow，`-f` 可显式启用；默认尾部 50 行 |
| `zc test [-c <config>] [--port <port>]` | 通过代理端口做真实连通性检查；显式端口或默认 7899；文本/JSON 使用相同检查 |
| `zc doctor [-c <config>]` | 配置、daemon、端口、连接诊断；运行中使用 descriptor 的实际 mixed 端口 |
| `zc config load <path>` | 校验并捕获本地 YAML 与 root-contained provider 为 immutable revision，设为 active；不自动 apply，`applied:false` |
| `zc config list` | 别名 `ls`；列出显示名称及可用于 `config use` 的 ID，以 `*` 标记 active；JSON 保持 `name`（ID）/`display`/`active` |
| `zc config download <url> [-n <name>] [-d]` | 发布新 immutable revision；`-d` 请求激活，否则只自动激活首个 runtime-ready profile；同名拒绝 |
| `zc config update [name] [--apply auto\|hot\|restart]` | 默认 active；仅订阅来源可更新；下载后 CAS 校验旧 head，再提交新 revision；仅对运行 exact 旧 identity 的 daemon 尝试 apply |
| `zc config use <name>` | 切换 active，绝不自动 apply，`applied:false` |
| `zc config delete <name>` | 别名 `rm/remove`；删除 catalog 引用，不破坏历史 immutable revision；不接管或停止运行实例 |
| `zc config dump [-c <config>] [--no-override]` | 裸 YAML / 裸 JSON 文档，不包 envelope；默认 frozen materialization，`--no-override` 读 immutable source；通常脱敏 |
| `zc config override [<script>\|--clear]` | 查询、绑定或清除 active profile 的冻结 override；变更发布新 revision 并尝试 apply |
| `zc proxy list [-c <config>]` | 别名 `ls`；组、成员、`data.groups[].now` |
| `zc proxy select [-g <group>] [-p <proxy>] [-c <config>]` | 先持久化 desired selection/generation，再尝试 exact revision live apply；JSON 无 `-p` 是只读 |
| `zc proxy test [-c <config>] [--port <port>]` | 与 `zc test` 相同 |
| `zc profile list/select/test` | `proxy` 的别名组，共用 handler；共享选择错误使用 `PROXY_*` |
| `zc diag doctor [-c <config>]` | `zc doctor` 的别名路径 |

未知 flag、多余位置参数、缺值/非法参数不得静默忽略。`restart --foreground` 拒绝；`start/restart` 共用冻结 `START_*` 参数错误码。TUI 不在帮助或 dispatch 中；`--daemon-run` 和 override worker 是内部模式，不是用户入口。

`config download/update` 的订阅 HTTP(S) 请求发送 `User-Agent: zc/<版本>`，避免服务端拒绝缺失客户端标识的请求；不冒充 Clash 或浏览器，不增加 curl 回退。仍保持 TLS 校验、直连（不读取环境代理）、30 秒超时、最多 5 次重定向和 16 MiB 响应上限。服务端返回非成功状态时保留 `CONFIG_DOWNLOAD_FAILED` / `CONFIG_UPDATE_FAILED` 错误码，消息明确给出 HTTP 状态码并提示检查订阅是否开启、有效、可访问；不回显订阅 URL 或响应正文，也不发布失败响应。

`config list` 文本示例：`* Flower_SS.yaml (ID: BlWdYKsc)`。显示名称可能重复，操作时使用 ID，例如 `zc config use BlWdYKsc`；这只是已有 profile key 的展示，不引入新的身份字段，也不修改配置状态。

`start/restart`、配置加载类诊断及 `config dump` 的一次性 override 使用 `--override-script <path>`、可重复 `--override-arg <k=v>`、`--override-timeout-ms <1..60000>`；适用与安全边界见 [override](../config/override.md)。

## 端口与实例生命周期

生产 mixed 默认端口固定 **7899**，只有 CLI `--port` 能覆盖。配置/profile/override 的 `mixed-port` 数值（包括来源声明 0）仅兼容解析，准备时规范化；CLI 端口 0 非法。与 mixed 声明共存的 `port/socks-port` 忽略，不创建额外 listener；没有 mixed 声明的独立入口仍在 bind 前拒绝。开发必须显式选非生产端口；端口占用拒绝启动，不自动换端口。

`external-controller` 只接受显式 `127.0.0.1:<port>`，精确绑定失败返回 `START_CONTROLLER_PORT_IN_USE` / `RESTART_CONTROLLER_PORT_IN_USE`，不得漂移或静默关闭。mixed 非 loopback 暴露需要 `allow-lan:true`；当前入站不提供用户认证，不应暴露到不可信网络。

### readiness 与安全停止

1. 父进程完成来源、providers、override、desired 的校验和冻结。
2. 子进程验证快照、继承 lock，绑定全部 listener，发布 `ready:false` descriptor。
3. 在 catalog authority 保护下完成 exact desired reconciliation；提升为 `ready:true` 后才运行数据面/API accept loop。DIRECT/REJECT 也不能绕过就绪门槛。
4. `status/start` 以 ready descriptor 而非单独 PID 或监听 socket 判断 running。

`stop` 使用 owner-only、nonce 绑定的请求让实例自行退出，不按数值 PID 猜测并发送信号。不一致的 descriptor/lock/PID、替换的 lock inode 或 runtime directory 均 fail closed；旧实例会检测身份变化并退出，不收养其他 HOME/XDG 环境的进程。Rust 还使用稳定 lifecycle lock 防止 runtime 目录重建期间双实例。

### reload、restart 与 apply

- **reload**：重新准备 tracked source，保留原 CLI 端口覆盖；来源缺失、provider 下载或配置校验失败时，旧实例与流量保持不变。当前没有原地热替换，成功返回 `restart_fallback`。
- **默认 restart**：复用认证的冻结快照，来源文件/脚本删除也可重启；显式 `--port` 可替换端口。显式 `-c` 或新的 override 才触发重新准备。只传新的 timeout 不代表要求重读来源。
- 目标准备和冻结必须在停止捕获的 PID/nonce 前完成；期间实例变化返回 contention，不停止新实例。新启动失败时尝试恢复精确旧 snapshot，不重新读可变来源。
- `--foreground` 实例由 systemd/容器等 supervisor 管理，CLI reload/restart 拒绝并提示 supervisor。
- `config load/use` 仅持久化，不自动 apply。要显式切换运行来源可用 `restart -c <name>`；默认 restart 不等价于“读取最新 active”。
- `config update/override` 提交成功后才尝试 live apply。当前 `auto/hot` 均走 prepared restart fallback，`restart` 显式走 restart；不承诺热切换或存量流量 drain。apply 失败不撤销已经提交的新 revision，错误会说明 persisted-but-not-applied。

## 状态、快照与持久选择

catalog 位于 `$HOME/.config/zc/state-v2.json`，schema 2 为唯一权威，引用 immutable revisions。`meta.json` 与 `configs/` 是兼容镜像，损坏或不可写不改变健康 catalog 的权威。旧 metadata/configs 与 schema-1 authority 在 shared legacy cutover lock 下接管；已存在 schema-2 与 revision 必须通过原格式、canonical bytes、哈希校验。未知格式、损坏 catalog 或缺失 revision 都失败，禁止删除重建或默认 DIRECT 回退。

原生 Rust 与旧 Zig prepared snapshot 的认证格式、两种 nonce 的区别见 [迁移说明](../migration/rust.md#已有数据与实例安全)。原始配置、provider、脚本与 materialization 只写入新 revision，不就地覆盖旧 revision。

新配置名剥除一个 `.yaml` 后须为 1–250 字节有效 UTF-8，排除 `.`、`..`、控制/双向字符、`/`、`\`；非法名称在网络/文件操作前报 `CONFIG_NAME_INVALID`。已有 251–255 字节 key 保持可读可删除，不允许创建同类新 key，mirror 可报告不同步。

selection 先以 state token（format/sequence/digest）CAS 提交，绑定 exact key/revision/generation；每 profile 最多 1024 项。daemon apply 还要求 PID、instance nonce、endpoint 与 identity 一致，拒绝旧/乱序 generation；durable desired 领先时可跳至最新完整 snapshot，再推进 descriptor。离线或不匹配时返回 `applied:false`，下次启动恢复。显式 unmanaged 配置不能用 CLI 持久选择，先 `config load`；API 的 unmanaged 临时选择另见 [API](../api/README.md)。

无持久选择时 select 默认首成员；嵌套组、DIRECT/REJECT 字面量有效，未知引用/循环拒绝。文本交互只在 stdin 为 TTY 时进入；非 TTY 且无 `-p` 返回 `PROXY_SELECT_NOT_INTERACTIVE`，JSON 无 `-p` 只读。

`status` 文本在 daemon/PID/端口之后显示 `Selected proxies:`，按运行配置中代理组的声明顺序，以 `代理组 -> 所选节点或组成员` 逐行列出实际运行选择（多个组可能选择不同成员，不虚构全局唯一节点）。运行状态不可读时显示 `(unavailable)`；已停止或没有代理组选择时显示 `(none)`。名称中的中文、国旗及组合 Emoji 原样输出 UTF-8；仅控制字符和不安全的方向控制符做终端安全转义，Emoji 的具体显示效果取决于终端与字体。JSON 结构保持不变，`selected_proxies` 数组同样按运行配置的组声明顺序排列；需运行新版 daemon 才会生成新的顺序。

`status` 的 `active_config/selected_proxies` 是实际运行状态，不是当前 catalog active 的替身；通过匹配 descriptor 的 controller 查询。controller 不可用时保留实例 identity、选择为空、`runtime_state_available:false`，不能猜 endpoint。来源标记为 `persisted/transient/default`。停止时保留显式 `mixed_port:null`，运行时为实际端口；该字段不受通用 null 过滤影响，公开 CLI 回归已覆盖。

### durability 与恢复

Managed JSON 成功结果提供 `durability_uncertain` 与 `mirror_out_of_sync`。authority rename 可见但父目录 fsync 失败时仍返回成功，并标记前者；调用方须重新检查并建立持久性证据，不能当作 crash-durable。mirror 失败独立报告，不能回滚已可见 authority。启动/重启失败与持久状态提交失败是不同边界。

malformed/unsupported SS simple-obfs metadata 可在严格 YAML、基础字段/规则/provider 均有效时保留为 **inactive raw recovery revision**。仅该明确插件语义例外可恢复，不允许其他协议、reserved 名称、资源超限或离线 provider 错误混入。首个这类下载不占用首个 runtime-ready 自动激活位置；`download -d`、active update、`use` 返回 `CONFIG_CAPABILITY_UNSUPPORTED` 且保持 authority 不变。用 `config dump -c <name> --no-override` 检视、修复订阅并 update，再显式 use。

普通 dump 脱敏；recovery-only raw text dump 为保留原字节可能含凭据，不应分享。终端不安全控制字符报 `CONFIG_DUMP_UNSAFE_TERMINAL`；重定向可保留原始字节。

## 资源、诊断与运行目录

配置/每个 provider source 为 16 MiB，上界探测不能把长文件截成合法前缀；完整 collection/provider/展开限制见 [兼容说明](../compat/mihomo-clash.md#配置资源上界)。超限在 revision 发布、listener/dial 前拒绝；config load/download/update 映射 `CONFIG_*_LIMIT_EXCEEDED`，完整 source 大小独立为 `CONFIG_*_TOO_LARGE`。malformed raw recovery 也不能绕过上界。已有 catalog 超出 1024 selections 属损坏，不是可忽略的用户 limit。

doctor 最多保留 256 条 errors/warnings 合计、每条 512 rendered bytes，错误优先并可替换末尾 warning；有效性独立于保留条数。超长消息使用原模板省略参数并追加 ` ... [truncated]`，数量或字节省略均以 `config_diagnostics_truncated` 明示。文本/JSON 同源输出多错误、warnings 与 migration hints；凭据不回显，终端控制字符清理。hints 保留原显式文件的 1 MiB 文本扫描规则（包括注释），不表示启用所提及的能力，unsupported 声明仍拒绝。加载失败不伪造语义诊断，语义错误保持 `CHECKS_FAILED`。证据与原 Zig 的精确差异见 [doctor 诊断验收](../migration/rust.md#doctor-validator-诊断验收)；其他配置加载命令的诊断精度不由此宣称完成。

`test/proxy test/profile test` 含 `daemon_state/selected_proxies/ports/checks/targets`，文本并发探测按完成顺序输出；任何失败的 check 返回 `CHECKS_FAILED` + data，exit 1。单项 target 与聚合 check 不应混为一谈。`doctor` 含 `proxy_reachable/network_ok/config_ok/config_diagnostics_truncated`，文本冻结标签 `Config:/Daemon:/PID:/Port:/Connection:`。这些诊断会发起真实网络探测，不属于纯离线验证。

`zc.pid/zc.lock/zc.log/zc.daemon.json/zc.daemon.lock` 位于安全 runtime directory。`XDG_RUNTIME_DIR` 须为既有、绝对规范路径、当前 euid 所有、0700；未设置使用规范化 `$HOME/.local/state/zc/runtime`。不安全父路径、symlink、特殊文件 fail closed；文件 0600。后台日志超过 8 MiB 重置到 owner-only 文件；follow 会在安全重建后重开。测试必须使用临时 HOME/runtime。

## JSON、输出流与退出码

- 成功：`{"ok":true,"command":"<path>","data":{...}}`，stdout 单行，exit 0。
- 失败：`{"ok":false,"command":"<path>","error":{"code":"…","message":"…","hint":"…"}}`，stdout 单行。诊断失败及可用的语义校验附带 data，不伪造 parser/I/O 的字段诊断。
- `log --json` 为 JSON Lines：每行 `{"line":"…"}`；`config dump --json` 为裸 JSON。除此之外每次一个最终 envelope，restart 中间诊断走 stderr。
- `serde_json` 序列化并对 CLI wire 非 ASCII 字符转义；解析后的字符串无损。可选 null 字段一般省略；`status.mixed_port` 的停止态 null 必须保留。字段顺序不是契约。
- 文本主输出到 stdout，进度/错误到 stderr；错误块包含 `error:/hint:/code:`，不打印 Rust panic/backtrace。`--no-color` 与 `NO_COLOR` 不得出现 ANSI。
- exit 0：成功、stopped status、already running/stopped、帮助/版本；exit 1：运行失败、检查失败、未知顶级命令；exit 2：裸命令、参数错误、未知子命令/帮助主题、非交互选择等用法错误。两种输出模式退出码相同。

帮助由 `src/cli.rs` 命令表与 clap 排版生成。裸 `help` 只在命令词后首位作为帮助标记；`--help/-h` 在参数中生效，不把后续参数值恰好为 `help` 当成执行请求。
