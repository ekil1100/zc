# 运行时稳定性观测

## 状态与使用范围

Rust daemon 已接入生命周期事件、连接故障分类与合并、资源摘要、panic 留痕、异常退出诊断标记和有界日志轮转。后台与 `start --foreground` 共用实现。

这套能力负责**留下排障证据**，不等于自动故障恢复、告警服务、完整连接列表或长稳验收。旧进程需升级并重新启动后才会生成这些事件。

```bash
# Show recent records without following.
zc log --no-follow -n 100

# Follow the current file and reopen after rotation.
zc log -f

# Emit JSON Lines; each line field contains the original log text.
zc log --json --no-follow -n 100

# Parse structured events with jq; skip legacy plain-text lines.
zc log --json --no-follow -n 100 | jq -r '.line | fromjson?'
```

非 follow 读取归档与当前文件的一致快照，再取尾部；follow 只跟随当前文件并在轮转后重开，不承诺慢消费者跨越多次轮转仍不丢历史。

## 事件与隐私

结构化事件带 `timestamp_ms`（Unix 毫秒；系统时间不可用时为 null）、`pid`、`instance`（实例 nonce）、`level`、`event`。实例之间的计数独立；重启时旧、新实例分别结束和开始。通用诊断写入者若尚未取得可信实例身份，超限轮转警告的 `instance` 为 null、`pid` 为实际写入进程，不从旧退出标记猜测身份。

| 事件 | 含义 |
| --- | --- |
| `daemon_starting` / `daemon_ready` | 进入实例启动流程 / 已发布 ready descriptor |
| `daemon_stopped` / `daemon_failed` | 观测到正常结束 / 实例流程失败；提供阶段、组件、操作、类型化原因与 OS errno |
| `connection_failed` | 某阶段、错误类别在本实例中的首次故障 |
| `connection_failure_summary` | 同类故障的合并增量 `count` 和累计 `total` |
| `runtime_summary` | 初始、每 30 秒及正常收尾时的连接计数和资源快照 |
| `runtime_panic` | 捕获到 panic；保留首个样本的源码文件名、行列和有界函数栈，省略 payload |
| `previous_exit_unknown` | 上次实例留下未完成标记，退出原因未知 |
| `exit_marker_*` | 诊断标记无效、不可用或持久化/清理不确定，不参与实例权威判断 |

不把原始错误字符串、请求正文、完整 URL、目标域名、节点名、配置路径、密码或订阅令牌写入这些事件。连接错误类别采用有限集合；致命错误另提供下面的类型化证据，未知原因明确标记。旧纯文本警告仍可与结构化事件共存。

ready 发布后的日志写入是尽力操作，不因日志锁竞争让已发布实例退出。首次日志锁初始化使用 1 秒启动预算，包含文件和目录同步；尚未绑定实例的启动/失败诊断写入也使用该预算。已绑定实例的后续日志写入锁预算保持 50ms。实例日志初始化超时、安全检查或同步失败仍拒绝启动；阻塞中的内核同步不提供硬实时截止保证。运行中写入失败不会在连接任务中同步重试、阻塞转发或生成无限递归日志。没有日志不能证明没有故障。

## 致命错误与 panic 排障

`daemon_failed` 保留以下安全字段，不调用任意错误的 `Display/Debug` 来生成日志：

| 字段 | 含义 |
| --- | --- |
| `phase` | 实例失败时的生命周期阶段；收尾发现错误时可以是 `shutdown` |
| `component` / `operation` | 固定代码操作边界，见下表；描述失败发生在哪里，不推断远端原因 |
| `cause` | `io`、`task_panic`、`instance_panic`、`instance_drop_panic`、`task_cancelled`、`selection_publication_failed` 或 `unclassified` |
| `error_kind` | 既有 I/O 类别；类型化 panic 为 `Panic`、任务取消为 `Cancelled`、选择发布失败为 `StateInvariant`；其余可能为 `Other` |
| `os_errno` | 错误链中首个 I/O 错误的原始 OS 错误号；合成 I/O 错误或没有 I/O 原因时为 null。数值依操作系统解释 |

| `component` / `operation` | 检查方向 |
| --- | --- |
| `mixed_listener` / `initialize_and_bind` | 出站初始化和 mixed listener 绑定；`AddrInUse` 时核对显式端口占用，不自动换端口 |
| `controller` / `bind` | 显式 controller 端口绑定；保留实际 I/O 类型与 errno |
| `mixed_listener` 或 `controller` / `run_listener` | 对应 listener 及其子任务；即使错误在收尾 join 时发现也保留组件。errno 为本平台 `EMFILE` 时检查进程文件描述符额度 |
| `runtime_owner` / `acquire_lifecycle_lock`、`validate_and_check_stop` | 实例所有权、运行目录、锁或停止请求检查；保留现场并核对目录与权限 |
| `configuration` / `parse_snapshot` | 冻结配置解析；检查此前 CLI 配置诊断 |
| `daemon` / `publish_readiness`、`drain_tasks`、`run_instance` | 就绪发布、任务收尾或实例流程；结合阶段、类型化原因及同实例 panic 事件检查 |
| `controller` / `publish_selection` | 选择状态发布已失败；核对运行目录、权限与状态一致性，保留现场 |
| `observability` / `spawn_reporter` | 观测线程创建失败；结合 errno 检查系统资源 |

这是**安全的类型投影，不是任意错误链的完整脱敏**。原始错误可能包含配置、URL、令牌或用户数据，日志整体省略其文本。尚未接入类型化原因的应用错误保留 `cause=unclassified`、组件和操作，不能据 `Other` 推断具体原因。`initialize_and_bind` 覆盖初始化和绑定两步，不能把该操作下所有错误都解释为端口冲突。监听任务的 panic 也可能发生在其子任务中，组件字段不细分具体连接。

`runtime_panic` 记录的是**本实例首个被 hook 捕获的 panic 样本**；它可能来自后来被捕获处理的任务，不单独证明整个进程已退出。结合 `daemon_failed` 和相同 `instance` 判断实例结果。

- `location` 为 `{file,line,column}`，没有位置时为 null。`file` 只取源码文件名，最多 96 个 ASCII 字节，只接受字母、数字、`_`、`.`、`-`；其他文件名用 `omitted`。省略源码目录和构建机器路径。
- `payload_policy=omitted`：字符串、超长字符串和任意对象 payload 都整体省略，不通过截断或关键词替换来声称安全，也不恢复默认 hook 的 stderr 输出。
- `backtrace` 来自发生 panic 的线程，主动捕获，与 `RUST_BACKTRACE` 设置无关。只保存标准库输出中的帧序号与函数符号行，限定字符集；省略源码路径行及其他文本。最多 16 帧、符号行合计 2048 字节，格式化的临时行最多 512 字节。达到上界或过滤不支持的符号时设置 `backtrace_truncated=true`。
- `backtrace_status` 为 `captured/unsupported/disabled`；`captured` 表示已捕获原生栈，符号解析仍受构建和平台影响，数组可能为空或包含未知符号。`version` 是构建包版本；排障时同时保留对应二进制/源码版本，文件名与行列按该版本解释。
- 函数符号和源码文件名属于构建元数据，仍可能透露代码结构；这些记录不是内存转储，不包含局部变量或请求正文。输出和暂存行有界，标准库内部栈捕获/符号解析的内存和耗时没有硬实时保证。
- 每个实例只捕获一个详细样本；后续 panic 仅累计到 `runtime_summary.panics`。事件 `count` 是写出时的累计数量；最终数量以最终摘要为准。hook 不主动写日志文件、不取得应用日志锁，reporter 尽力写出；首个样本写入失败后按既有 100ms 周期尝试，退出等待仍受原预算约束。

可以在重启后读取同一个运行目录的证据：

```bash
# Read fatal and panic evidence from the retained log window.
zc log --json --no-follow -n 1000 | jq -r '.line | fromjson? | select(.event == "daemon_failed" or .event == "runtime_panic")'
```

重启追加新实例事件，正常停止和退出标记清理都保留旧日志。证据位于 `zc.log` 或 `zc.log.1`，按下文轮转规则保留；没有独立的永久“最后一次崩溃”文件。高频重启或其他日志写入可以推进轮转并淘汰旧证据，需要长期保存时及时导出。

## 连接计数与故障分类

故障阶段固定为 `ingress/dns/connect/tls/transfer/udp`。`connection_failed` 与 `connection_failure_summary` 附加有限 `source` 字段，表示失败时正在执行的操作对象；它与 `stage` 一起解释，不代表已确定网络或服务端根因：

| `stage` | `source` | 观测边界 |
| --- | --- | --- |
| `dns` | `target` | 本地解析目标域名：地址规则分流、DIRECT 拨号或 Trojan UDP 目标解析 |
| `dns` | `proxy` | 本地解析代理节点入口域名，包括 SS/Trojan UDP 建立 |
| `connect` | `target` | DIRECT 目标 TCP 连接 |
| `connect` | `proxy` | 代理节点入口 TCP 连接；SS UDP 则为本地 UDP socket 建立/关联，成功不证明节点可达 |
| `tls` | `proxy` | zc 与 Trojan/AnyTLS 节点的 TLS 握手 |
| `connect` | `proxy_protocol` | TCP（以及需要时的 TLS）建立后，发送 SS 目标头、Trojan 请求或 AnyTLS 开流数据 |
| `tls` | `target` | absolute-form HTTPS 转发中，由 zc 主动执行的目标 TLS 握手 |
| 任意既有阶段 | `unspecified` | 该操作边界没有更细来源证据；普通入站、转发及 UDP 会话错误保留原分类 |

例如 `stage=connect, source=proxy, error_kind=TimedOut` 表示等待节点入口连接超时，区别于 `stage=dns, source=proxy` 的入口域名解析失败。超时保留当前操作的阶段和来源；每条连接独立维护，不因并发串台。原协议超时预算、回复码、路由和地址尝试策略保持不变。

`proxy_protocol` 只标识本地协议准备期间的失败。SS/Trojan/AnyTLS 写出准备数据后，服务端后续拒绝、协议截断等仍按实际发生的 `transfer/udp` 阶段记录，无法从这些错误统一推断远端 DNS、目标 TCP 或认证失败。DNS 返回可用格式的错误地址仍是解析成功；CONNECT/SOCKS 隧道中由客户端执行的目标 TLS（包括证书不匹配）也不属于 zc 的 TLS 握手观测。这里不提供 DNS 错答检测、公共 DNS 回退、额外重试、TLS 降级或自动切节点。

- `active_connections` 是当前 mixed TCP 连接任务数，包含 SOCKS UDP association 的控制连接；不等于独立 UDP socket 数或目标数。
- `total_connections` 是本实例累计接受的 mixed TCP 连接数；任务退出、取消或 panic 后释放活动计数。
- `failures` / `failures_by_stage` 是故障事件数，不是失败连接数。一条连接可以有多次 UDP 或其他操作失败。
- `rejections` 单独累计策略拒绝和不支持的 UDP 叶节点等准入拒绝，不算运行故障。
- 普通 EOF、reset、客户端断开及正常 idle 到期不刷故障；HTTP 长度、响应头或 chunk framing 截断（含读取中 reset）、SS 短 salt 和 obfs 截断响应仍计入转发故障。读取中的协议截断与写向已关闭客户端的普通错误分开处理；不能仅凭普通 reset 推断上游质量。SOCKS UDP 控制连接取消不计为 UDP transport 故障。
- UDP 丢弃非法数据包等原协议行为保持，不把所有静默丢包都宣称为已记录故障，也不把无响应 UDP 包等同于已证实的网络故障。

连接热路径只更新有限原子计数，不写磁盘。固定 6 个阶段 × 4 个来源 × 16 个错误类别，不按任意主机或错误文本建立无界 map。reporter 每 100ms 读取计数：相同 `(stage, source, error_kind)` 的首次故障单独记录，其余每 30 秒合并，退出时补最后增量；`count/total` 属于该组合，不把不同来源合并。`runtime_summary` 的 `failures/failures_by_stage` 继续累计所有来源，每次故障只计一次。统计总数不因限频丢失，但磁盘故障可能使记录缺失。panic 首次单独记录有界样本，累计数量保留在摘要中；栈捕获只发生在首个 panic 的异常路径。

## CPU 与内存

资源摘要在独立 reporter 线程采样，不阻塞连接任务：

| 字段 | 解释 |
| --- | --- |
| `uptime_ms` | 本实例 reporter 的单调时钟运行时间 |
| `cpu_time_ms` | 进程累计 CPU 时间，不是墙钟时间或即时 CPU 百分比 |
| `cpu_delta_ms` / `sample_elapsed_ms` | 两个有效相邻样本间 CPU 时间增量 / 单调时钟间隔 |
| `rss_bytes` / `rss_delta_bytes` | 常驻物理内存 / 相邻有效样本的变化量，不是 Rust 堆大小 |
| `resource_status` | `available` 或 `unavailable`；不可用时资源值为 null，不伪造零 |

粗略单核口径 CPU 使用率为 `100 × cpu_delta_ms / sample_elapsed_ms`，多线程时可超过 100%。首次采样没有增量；采样失败会打断连续增量。默认不设置“内存过高”阈值，也不据一次 RSS 增长断定泄漏；应观察重复负载后的趋势。

Linux/macOS 使用固定绝对路径 `/bin/ps`、当前进程 PID 和固定 `time/rss` 参数，清空子进程环境并固定 locale，不调用 shell。每次输出最多 1024 字节，采样取消预算 500ms，异常路径 kill/reap 子进程。`ps` 不存在、失败或不能解析时不影响代理服务。CPU 精度受系统 `ps` 输出量化限制，Linux 常见为秒级、macOS 常见为百分之一秒，短样本增量为零并不表示完全没有 CPU 消耗。这不是高精度 profiler 或正式性能基线。

日志文件维护每秒最多一次，资源采样每 30 秒一次；关闭时最多等待 2 秒完成最终证据。内核 I/O 卡死等极端情况不承诺硬实时返回或磁盘落盘成功。

## 退出与日志安全

- `zc.exit.json` 是 owner-only 诊断标记，写入和清理持有当前实例锁；不是 catalog、descriptor 或 PID 的替代权威，不据它停止、收养或恢复进程。
- 下次启动看到合法残留标记，记录 `previous_exit_unknown`；不能声称知道上次是强杀、断电、系统崩溃还是其他原因。第一次启用新版时，标记不存在也不证明旧版曾正常退出。
- 标记损坏或不可验证时保留原文件并发出诊断，不删除重建；此时该实例的异常退出检测可能不可用。
- 可捕获的主实例 future panic（poll 及析构）被转成脱敏的致命结果；任务 panic 也计数，任务 join 边界转换为固定错误，不把 `JoinError` 的 payload 传播到 CLI 或启动错误文件。先逐层回收 mixed 连接、API 请求和 Trojan UDP worker，再完成最终摘要、退出标记和 hook 收尾；实例锁与 lifecycle 锁保持到收尾边界。panic hook 整体省略用户 payload，首个样本保留有界位置与函数栈，结束后恢复旧 hook。日志收尾有等待预算，但不保证任意卡死的析构器有界退出；abort、双重 panic、强杀及断电没有进程内完整留痕保证。
- 最终事件写入成功后才尝试清理自有标记；文件系统持久化不确定、路径变化或收尾超时可能留下标记，所以“上次退出未知”不等于确定崩溃。
- 当前 `zc.log` 和单个归档 `zc.log.1` 各最多 8 MiB，单个新事件最多 4 KiB；共享 `zc.log.lock` 串行化写入、轮转和非 follow 快照读取。保持 owner-only、普通文件、单链接和路径安全检查。
- 外部或旧写入者把当前日志写到超限时，不复制无界内容，记录 `log_retention_exceeded` 后恢复有界轮转。只保留一代归档；下一次轮转会替换上一代，包括其中的致命错误和 panic 证据。重启本身不主动截断日志。

普通 append 沿用已有写入方式，没有逐事件文件 fsync；本能力验证的是成功写入后跨进程重启可读，不提供断电持久性保证。日志锁竞争、磁盘不可写、运行目录或实例锁身份变化、reporter 收尾超时都可能缺失证据；安全检查失败时不绕过 owner-only 校验另写不受控文件。强杀、abort、双重 panic 和断电可能只有旧退出标记，没有位置或堆栈。

## 使用限制

这套观测能力不代表四平台验证、24/72 小时长稳或正式资源开销基线已经通过。实例流程之前的 CLI 配置准备失败仍主要通过命令的错误输出报告，不能认为所有 CLI 失败都会写入 daemon 日志。
