# zc CLI 契约

本文件说明 CLI 命令、输出格式、配置与实例管理行为。协议与配置支持范围见[兼容说明](../compat/mihomo-clash.md)，错误码见[字典](../api/error-codes.md)。

## 完整命令表

所有公开命令支持 `--json`；`-c` 等同于 `--config`。裸 `config/proxy/profile/diag/connection` 输出组帮助并退出 0。每个命令接受 `help`、`--help`、`-h`，帮助请求不执行业务。

| 命令 | 行为 |
| --- | --- |
| `zc help [command [subcommand]]`、`zc --help`、`zc -h` | 帮助写 stdout；未知主题 `HELP_TOPIC_UNKNOWN`，exit 2 |
| `zc version`、`zc --version` | 版本写 stdout，exit 0 |
| `zc start [-c <config>] [--port <port>] [--foreground]` | 别名 `up`；默认后台，取得启动所有权后准备并启动认证快照；已运行时后台成功返回 `detail:already_running`，前台拒绝，两者均不准备配置 |
| `zc stop` | 别名 `down`；只停止当前 PID/nonce 绑定实例并清理对应 snapshot；已停止成功 `detail:already_stopped` |
| `zc restart [-c <config>] [--port <port>]` | 默认复用运行实例冻结快照；显式来源/override 才重新准备；目标先冻结、后停旧实例，失败尝试精确回滚 |
| `zc reload` | 重读 tracked source，保留 CLI 端口覆盖；当前成功路径为 restart fallback；未运行返回 `RELOAD_FAILED` |
| `zc status` | 实际 daemon 状态、uptime、端口、路径、select 当前选择；stopped 也是 exit 0 |
| `zc connection list` | 列出运行实例的活动连接、来源、协议/阶段、目标、命中运行时规则和实际 leaf；需显式 controller；托管自动 secret 或非空显式 secret |
| `zc connection close <id>` | 按完整实例绑定 ID 请求关闭；成功仅表示已请求，非已回收 |
| `zc log [-n <lines>] [-f\|--no-follow]` | 文本默认 follow；JSON 默认不 follow，`-f` 可显式启用；默认尾部 50 行 |
| `zc test [-c <config>] [--port <port>]` | 通过代理端口做真实目标连通性检查，全部目标成功才 exit 0；显式端口或默认 7899；文本/JSON 使用相同检查 |
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

1. start 在既有 `zc.launch.lock` 协调下先取得 `zc.lock` 启动所有权，再完成来源、providers、override、desired 的校验和冻结；已运行或竞争未获所有权时不执行 override、不生成自动 key。前台同样遵守此边界，在运行实例前释放短期 launch 锁，全程保留实例锁。restart 的先准备、后停旧实例顺序不变。
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

原生 Rust 运行快照与旧 Zig prepared snapshot 均须通过认证及实例身份校验；旧快照的文件 nonce 与 descriptor nonce 可以独立，不能通过改写快照绕过校验。原始配置、provider、脚本与 materialization 只写入新 revision，不就地覆盖旧 revision。

新配置名剥除一个 `.yaml` 后须为 1–250 字节有效 UTF-8，排除 `.`、`..`、控制/双向字符、`/`、`\`；非法名称在网络/文件操作前报 `CONFIG_NAME_INVALID`。已有 251–255 字节 key 保持可读可删除，不允许创建同类新 key，mirror 可报告不同步。

selection 先以 state token（format/sequence/digest）CAS 提交，绑定 exact key/revision/generation；每 profile 最多 1024 项。daemon apply 还要求 PID、instance nonce、endpoint 与 identity 一致，拒绝旧/乱序 generation；durable desired 领先时可跳至最新完整 snapshot，再推进 descriptor。离线或不匹配时返回 `applied:false`，下次启动恢复。显式 unmanaged 配置不能用 CLI 持久选择，先 `config load`；API 的 unmanaged 临时选择另见 [API](../api/README.md)。

无持久选择时 select 默认首成员；嵌套组、DIRECT/REJECT 字面量有效，未知引用/循环拒绝。文本交互只在 stdin 为 TTY 时进入；非 TTY 且无 `-p` 返回 `PROXY_SELECT_NOT_INTERACTIVE`，JSON 无 `-p` 只读。

`status` 文本在 daemon/PID/端口之后显示 `Selected proxies:`，按运行配置中代理组的声明顺序，以 `代理组 -> 所选节点或组成员` 逐行列出实际运行选择（多个组可能选择不同成员，不虚构全局唯一节点）。运行状态不可读时显示 `(unavailable)`；已停止或没有代理组选择时显示 `(none)`。名称中的中文、国旗及组合 Emoji 原样输出 UTF-8；仅控制字符和不安全的方向控制符做终端安全转义，Emoji 的具体显示效果取决于终端与字体。JSON 结构保持不变，`selected_proxies` 数组同样按运行配置的组声明顺序排列；需运行新版 daemon 才会生成新的顺序。

`status` 的 `active_config/selected_proxies` 是实际运行状态，不是当前 catalog active 的替身；通过匹配 descriptor 的 controller 查询。controller 不可用时保留实例 identity、选择为空、`runtime_state_available:false`，不能猜 endpoint。来源标记为 `persisted/transient/default`。停止时保留显式 `mixed_port:null`，运行时为实际端口；该字段不受通用 null 过滤影响，公开 CLI 回归已覆盖。

### 托管 profile 的自动 controller secret

只在**实际运行准备**（start、显式来源 restart、reload、运行中 update/override 的 apply）且有效配置已有 `external-controller`、`secret` 缺失或为空时，首次生成 32 随机字节（64 位小写 hex）。先完成配置、provider、override、端口与选择校验，再通过 catalog 锁及 exact token/key/head CAS 持久化；冲突明确失败，重新准备后复用赢家。**不自动添加 controller，也不添加 9090 或任何其他默认监听端口**；没有 controller 时连接命令仍报 controller 缺失。非托管 `-c <文件>` 保持原有行为，需要手工配置非空 secret。

自动值只属于 `state-v2.json` 的可选 profile 字段 `auto_controller_secret`，不写入 `meta.json`、immutable source/materialization/assets 或内容摘要。显式非空 secret 逐字节优先；显式值存在期间仍保留旧自动值，移除后复用。订阅更新、override、选择及重命名不轮换；删除后重新导入是新生命周期。普通 dump、日志、Debug、环境与命令行不注入或披露自动值。

load/list/dump/use、proxy 查询/选择及诊断不生成；已运行 start（含被拒绝的 foreground）、默认 restart 也不隐式升级。已有 daemon 时 foreground 不执行任何一次性 override；竞争中返回 `already_running` 或因未取得所有权而拒绝的 start 不持久化 key。旧实例缺 secret 时，托管用户须显式 `zc restart -c <profile>`（前台由 supervisor 按来源重新准备）。默认 restart 与失败回滚继续使用原冻结认证；新 active/head 不替换运行实例的 secret。

新自动值的 authority rename 可见但目录 fsync 失败时，拒绝本次准备，旧实例不停止；不删除或轮换可见 key。后续进程复用已有值也必须在 catalog 锁内重新同步 authority 目录。后续 listener bind 失败不撤销已持久 key。此处比普通状态提交的 durability warning 更严格：未经持久确认的 key 不进入 Prepared。

采用自动值的认证快照使用 schema 2，冻结独立 secret overlay；只修改运行时私有 secret，不修改冻结 source。无 overlay 仍写 schema 1；旧 Rust/旧 Zig 快照缺字段时只采用原 source 的 secret，不查 profile、不补 key。schema 1 不允许 overlay；schema 2 必须包含合法非空 overlay、managed identity、原 source 已有 controller 且没有非空显式 secret。缺失/null/错误字段、非法语义和 HMAC 篡改均拒绝，无来源回退。readiness/选择快照重写及回滚保留实际冻结值。旧 binary 与新状态的回退限制见[升级与回退](../install/README.md#状态兼容与回退)。

### durability 与恢复

Managed JSON 成功结果提供 `durability_uncertain` 与 `mirror_out_of_sync`。authority rename 可见但父目录 fsync 失败时仍返回成功，并标记前者；调用方须重新检查并建立持久性证据，不能当作 crash-durable。mirror 失败独立报告，不能回滚已可见 authority。启动/重启失败与持久状态提交失败是不同边界。

malformed/unsupported SS simple-obfs metadata 可在严格 YAML、基础字段/规则/provider 均有效时保留为 **inactive raw recovery revision**。仅该明确插件语义例外可恢复，不允许其他协议、reserved 名称、资源超限或离线 provider 错误混入。首个这类下载不占用首个 runtime-ready 自动激活位置；`download -d`、active update、`use` 返回 `CONFIG_CAPABILITY_UNSUPPORTED` 且保持 authority 不变。用 `config dump -c <name> --no-override` 检视、修复订阅并 update，再显式 use。

普通 dump 脱敏；recovery-only raw text dump 为保留原字节可能含凭据，不应分享。终端不安全控制字符报 `CONFIG_DUMP_UNSAFE_TERMINAL`；重定向可保留原始字节。

## 连接管理最小版

`zc connection list [--json]` 与 `zc connection close <id> [--json]` 对应 minimal API 的 `GET /connections`、`DELETE /connections/<id>`；字段与关闭语义见 [API](../api/README.md#连接模型与关闭语义)。文本展示 ID、TCP 来源、协议/阶段、入站、原始目标、路由后目标、运行时规则、实际 leaf，以及 UDP 首包来源和范围；不安全终端字符转义。JSON 的 `data` 与 API 响应一致，继续使用 `ok/command/data` 信封。未知字段省略，不把未知 leaf 写成 DIRECT。

裸 `connection` 显示组帮助并 exit 0；非法子命令、缺失/非法 ID、多余参数 exit 2。不接受 `-c/--config/--port/--all` 或 override 参数。未运行、无 controller、无 secret、鉴权失败、身份不可验证、记录消失或坏响应均 exit 1，**不能返回假空表**。成功空表仅代表已鉴权的当前实例没有活动记录。

CLI 只用 `observe` 确认的 PID/nonce/endpoint/exact identity 与认证冻结快照取得 secret；不读取当前 active profile 猜测地址。控制请求直连、禁环境代理、禁重定向、网络期限 2 秒、响应上限 4 MiB；发送并校验实例头，拒绝坏 schema 或跨实例 ID。请求前后复查实例身份，但同实例 selection generation 变化不使连接操作失败。DELETE 的旧 ID 防护在服务端副作用之前执行，不能只靠事后复查。

没有 controller 时不自动开端口。若修改 `external-controller/secret`，必须显式重新准备再重启，例如 `zc restart -c <config>`；默认 restart 冻结语义不变，前台实例由 supervisor 按显式来源重新准备。连接列表属于敏感详情，不应公开分享。

HTTP keep-alive 同 ID，下一请求更新路由，idle 清除目标/规则/leaf；UDP 只记录首合法包，并标记 `first_datagram`，关闭整条关联。无流量计数、全部断开、历史、分页、WebSocket 或 TUI。

## 资源、诊断与运行目录

配置/每个 provider source 为 16 MiB，上界探测不能把长文件截成合法前缀；完整 collection/provider/展开限制见 [兼容说明](../compat/mihomo-clash.md#配置资源上界)。超限在 revision 发布、listener/dial 前拒绝；config load/download/update 映射 `CONFIG_*_LIMIT_EXCEEDED`，完整 source 大小独立为 `CONFIG_*_TOO_LARGE`。malformed raw recovery 也不能绕过上界。已有 catalog 超出 1024 selections 属损坏，不是可忽略的用户 limit。

doctor 最多保留 256 条 errors/warnings 合计、每条 512 rendered bytes，错误优先并可替换末尾 warning；有效性独立于保留条数。超长消息使用原模板省略参数并追加 ` ... [truncated]`，数量或字节省略均以 `config_diagnostics_truncated` 明示。文本/JSON 同源输出多错误、warnings 与 migration hints；凭据不回显，终端控制字符清理。hints 保留原显式文件的 1 MiB 文本扫描规则（包括注释），不表示启用所提及的能力，unsupported 声明仍拒绝。加载失败不伪造语义诊断，语义错误保持 `CHECKS_FAILED`。上述详细诊断仅描述 doctor；其他配置加载命令可能只返回概括性错误。

`doctor` 含 `proxy_reachable/network_ok/config_ok/config_diagnostics_truncated`，文本冻结标签 `Config:/Daemon:/PID:/Port:/Connection:`。诊断会发起真实网络探测，不属于纯离线验证。`test/proxy test/profile test` 的目标、摘要和退出码见下节。

`zc.pid/zc.lock/zc.log/zc.daemon.json/zc.daemon.lock` 位于安全 runtime directory。`XDG_RUNTIME_DIR` 须为既有、绝对规范路径、当前 euid 所有、0700；未设置使用规范化 `$HOME/.local/state/zc/runtime`。不安全父路径、symlink、特殊文件 fail closed；文件 0600。运行日志当前文件 `zc.log` 与归档 `zc.log.1` 各最多 8 MiB，轮转受 `zc.log.lock` 保护，follow 会在安全重建后重开；非 follow 合并归档和当前文件的一致快照后取尾部。`zc.exit.json` 仅为异常退出诊断标记，不参与实例权威判断。文件保持 owner-only，测试必须使用临时 HOME/runtime。

### test 的可用性摘要与实际路径

`test`、`proxy test`、`profile test` 共用以下文本/JSON 语义。保留 `daemon_state/selected_proxies/ports/checks/targets`；文本逐项按并发探测完成顺序输出，最后输出摘要。任一目标失败都使 `connectivity` check 失败，返回 `ok:false`、`CHECKS_FAILED`、exit 1，并保留完整诊断 `data`。

`data.summary` 字段：

| `status` | 含义 | 整体结果 |
| --- | --- | --- |
| `all_succeeded` | 已执行目标全部成功 | `ok:true`，exit 0 |
| `partial` | 部分目标成功 | `ok:false`，exit 1 |
| `all_failed` | 已执行目标全部失败 | `ok:false`，exit 1 |
| `not_run` | 代理端口不可达，目标探测未执行 | `ok:false`，exit 1；端口 check 失败 |

`total/succeeded/failed` 分别为已执行、成功、失败目标数，`total = succeeded + failed`。端口不可达时三者均为 0，`targets:[]`；用 `not_run` 区分“未测”与“测过且全失败”。配置加载失败沿用原错误码，不伪造摘要。

例如只有一个目标成功时，摘要为 `{"status":"partial","total":7,"succeeded":1,"failed":6}`；文本为 `Summary: partially reachable (1/7 targets reachable)`。脚本须检查整体 `ok` / 退出码及摘要，按 `name` 识别逐项结果，不依赖完成顺序。

**实际路径**：每个 target 的 `actual_path` 为 `direct/proxy/reject/unknown`。已验证项额外提供 `proxy:{name,type}` 和 `route_evidence:{connection_id,request_index}`；`request_index` 从 0 开始，区分同一 HTTP keep-alive 连接中的不同请求。命名 direct 节点仍按 `type:Direct` 计入直连，REJECT 单独计数。这里证明的是运行时为该请求实际选定并尝试的 leaf；连接或 HTTP 结果仍由该项 `ok` 表达，选中代理不等于连接成功。

证据来自本次真实请求：CLI 从认证冻结快照取得现有 controller 的 secret 和实例身份，预约单次随机票据，在本地 HTTP 请求中携带逐跳追踪头；runtime 消费票据并保存随后实际路由使用的 leaf，CLI 再经鉴权接口读取。记录独立于活动连接，短请求结束后仍可查询；同目标并发、keep-alive 各请求使用不同票据。读端不重算路由、不查询瞬时连接列表后按域名匹配，也不以查询时的当前选择覆盖已记录 leaf。控制请求前后验证同一实例，重启后的旧身份拒绝；同实例切组不抹掉请求当时的证据。详见 [API 票据边界](../api/README.md#诊断请求票据)。

`selected_proxies_source:"prepared_config"` 继续说明 `selected_proxies` 来自本次准备配置，可能与该端口的运行实例不同；它与目标名、目标 IP、HTTP 状态均不参与实际路径归类。

**按路径计数**：`data.path_summary` 的 `direct/proxy/reject/unknown` 各含 `total/succeeded/failed`；四类之和等于整体摘要。文本逐项显示路径和 leaf，最后显示四类计数，`total:0` 显示 `not tested`。例如只有 DIRECT 成功、六个代理请求失败时：

```json
{
  "direct": {"total": 1, "succeeded": 1, "failed": 0},
  "proxy": {"total": 6, "succeeded": 0, "failed": 6},
  "reject": {"total": 0, "succeeded": 0, "failed": 0},
  "unknown": {"total": 0, "succeeded": 0, "failed": 0}
}
```

`proxy.total:0` 表示没有已证实走代理的样本，不能用 DIRECT 或 unknown 的成功数证明代理可用。路径未知不伪造为失败或 DIRECT，目标 HTTP 结果继续单独保留。

**取得证据的条件与提示**：支持运行新版 zc、认证运行快照可读、指定 mixed 端口匹配该实例、已配置 controller 和非空运行时 secret 的 HTTP forward 请求。托管 profile 已有 controller 时自动 secret 沿用既有生命周期；默认不需要用户复制 secret。端口选择仍为显式 `--port` 或 7899，若实例用了其他端口，应传入该实际端口。没有 controller 时不自动开监听器。

未知项包含 `path_reason/path_hint`，文本也显示同一提示：

| `path_reason` | 条件与操作 |
| --- | --- |
| `not_running` | 当前隔离状态中没有可验证运行实例；启动目标实例后重试 |
| `controller_required` | 冻结配置未启用 controller；配置显式 `external-controller` 后用 `zc restart -c <profile>` 重新准备，默认 restart 沿用旧快照 |
| `secret_required` / `unauthorized` | 缺少有效鉴权；托管 profile 显式重新准备，非托管配置设置非空 secret，并核对运行实例认证 |
| `port_mismatch` | `--port` 指向其他端口或外部代理；改用当前 zc 实例 mixed 端口，外部代理仅报告 HTTP 结果 |
| `instance_changed` | 采集期间实例身份变化；在稳定实例上重试 |
| `evidence_unavailable` | controller 不可达、旧版本不支持、票据过期/额度耗尽或响应校验失败；检查 controller 版本和连通性后重试 |
| `route_not_observed` | 请求结束时尚无实际路由记录，例如路由 DNS 未完成；结合运行日志排查 |
| `unsupported_scheme` | 当前票据只用于 HTTP forward；默认七项均属此范围，HTTPS 隧道不携带追踪票据 |

追踪票据不是 controller secret，单张只能消费一次，实例内最多 256 张，从预约起有效 120 秒；CLI 查询后尽力释放。长期 Bearer 只发往已有 loopback controller；mixed 入口剥离追踪头、拒绝重复头/CONNECT/追踪 trailer，CLI 同时使用 `Connection` 声明其逐跳性质，避免旧版 zc 或合规代理接管端口后将它转发到目标。旧/过期票据在目标拨号前拒绝并返回 502，计为失败。沿用既有可信本机 HTTP controller 边界，不增加对恶意本地监听器的加密身份认证。

**探测范围**：七个固定目标仍为 IP/Location、Google、YouTube、Netflix、OpenAI、GitHub、Cloudflare，使用既有 HTTP URL；Cloudflare 是 `http://1.1.1.1`。请求禁重定向，成功只表示按既有判定取得了完整的非 502 HTTP 响应，403、其他非 502 状态仍可计为连通。HTTP 重定向响应不证明最终 HTTPS 站点可用。全部目标成功也只证明本次目标连通，指定代理是否被测以实际路径计数为准，HTTPS/TLS、登录/下载、其他站点和持续可用性仍需相应证据；仅 DIRECT 成功尤其不足以证明代理可用。

**逐项证据**：成功保留 `ip`（IP/Location 缺 query 时 `unknown`，无 latency）或 `latency_ms`（其他目标）；失败保留 `reason` 并新增 `failure_stage`；取得 HTTP 响应头时额外提供数值 `http_status`（包括失败项）。阶段描述 CLI 自身观察，不等同于 daemon 内部故障阶段：

| `failure_stage` | 直接证据与边界 |
| --- | --- |
| `tls` | 客户端错误链含类型化 TLS 错误；证书校验失败明确报告，原因不推断为 DNS 污染 |
| `http` | 收到 HTTP 502；只报告响应码，不猜测 DNS、节点 TCP 或其他内部原因 |
| `http_body` | 已收到响应头，读取正文失败、超时或 IP/Location 正文超限 |
| `connection_setup` | 客户端报告连接准备失败，可能包含代理隧道准备；不等价于已定位某个 TCP 对端失败 |
| `request` | 请求超时或其他缺少更具体阶段证据的错误 |

文本失败行显示相同 `reason` 与阶段。错误不回显 URL、响应正文或底层原始错误。默认目标为 HTTP，通常不会在 CLI 侧进行目标 TLS；运行时代理自身的 TLS 故障也不能仅凭 HTTP 502 细分。

**兼容变化**：旧版“至少一个目标成功就 exit 0”改为全部成功才 exit 0；部分成功现在明确失败。JSON 新增 `summary`、`path_summary`、`selected_proxies_source` 及逐项路径/失败阶段证据字段，旧字段保留。原 502 的 `TCP connect failure` 和 IP/Location 统一的 `no response` 改为有证据的阶段原因。消费方应读取字段而非匹配旧错误文案；不改变默认目标、期限、403 等非 502 响应判定、provider 准备策略或 doctor gating。

### 稳定性日志

后台与前台实例均记录结构化生命周期、连接故障和资源摘要，详见[稳定性观测](../reliability/observability.md)。事件带 `timestamp_ms`、`level`、`event`、`pid` 和 `instance`；生命周期额外包含 `phase` 与有限 `error_kind`。ready 发布后的日志失败不撤销启动，最终证据尽力写入，不用缺少错误日志证明健康。

连接故障按 `ingress/dns/connect/tls/transfer/udp` 分类，首次记录后每 30 秒合并同类错误，退出补汇总；正常断连和策略拒绝不刷故障。独立线程记录初始、30 秒周期及最终 CPU/RSS 与连接计数；采样不可用时为 null，不阻止转发。新事件不包含原始错误、目标、请求内容或凭据。

panic 记录不含 payload/位置；未完成的退出标记在下次启动报告 `previous_exit_unknown`，不猜测强杀、断电等根因。损坏标记保留，不据此接管或停止进程。实例流程之前的配置准备、快照认证等失败并非全部写入 daemon 日志，仍以 CLI 错误输出为准。

`zc log --json` 保持既有 `{"line":"…"}` 包装；旧纯文本行与新 JSON 事件可共存。单个新事件最多 4 KiB，保留当前日志与一代归档，均保持 owner-only。这些能力不提供自动重启或长稳通过保证。

## JSON、输出流与退出码

- 成功：`{"ok":true,"command":"<path>","data":{...}}`，stdout 单行，exit 0。
- 失败：`{"ok":false,"command":"<path>","error":{"code":"…","message":"…","hint":"…"}}`，stdout 单行。诊断失败及可用的语义校验附带 data，不伪造 parser/I/O 的字段诊断。
- `log --json` 为 JSON Lines：每行 `{"line":"…"}`；`config dump --json` 为裸 JSON。除此之外每次一个最终 envelope，restart 中间诊断走 stderr。
- `serde_json` 序列化并对 CLI wire 非 ASCII 字符转义；解析后的字符串无损。可选 null 字段一般省略；`status.mixed_port` 的停止态 null 必须保留。字段顺序不是契约。
- 文本主输出到 stdout，进度/错误到 stderr；错误块包含 `error:/hint:/code:`，不打印 Rust panic/backtrace。`--no-color` 与 `NO_COLOR` 不得出现 ANSI。
- exit 0：成功、stopped status、already running/stopped、帮助/版本；exit 1：运行失败、检查失败、未知顶级命令；exit 2：裸命令、参数错误、未知子命令/帮助主题、非交互选择等用法错误。两种输出模式退出码相同。

帮助由 `src/cli.rs` 命令表与 clap 排版生成。裸 `help` 只在命令词后首位作为帮助标记；`--help/-h` 在参数中生效，不把后续参数值恰好为 `help` 当成执行请求。
