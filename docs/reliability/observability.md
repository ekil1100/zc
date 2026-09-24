# 运行时稳定性观测

## 状态与使用范围

Rust daemon 已接入生命周期事件、连接故障分类与合并、资源摘要、panic 留痕、异常退出诊断标记和有界日志轮转。后台与 `start --foreground` 共用实现；测试只使用隔离 HOME/runtime 和非生产端口。

这套能力负责**留下排障证据**，不等于自动故障恢复、告警服务、完整连接列表或长稳验收。没有安装或重启现有生产实例；旧进程必须在用户安排的部署窗口切换到新版后才会生成这些事件。

```bash
# 查看最近记录，不等待新日志。
zc log --no-follow -n 100

# 持续查看当前文件，轮转后重新打开。
zc log -f

# 保持既有 JSON Lines envelope，每行的 line 是日志原文。
zc log --json --no-follow -n 100

# 如果安装了 jq，可解析新增的结构化事件；旧文本行不会导致整条管道失败。
zc log --json --no-follow -n 100 | jq -r '.line | fromjson?'
```

非 follow 读取归档与当前文件的一致快照，再取尾部；follow 只跟随当前文件并在轮转后重开，不承诺慢消费者跨越多次轮转仍不丢历史。

## 事件与隐私

结构化事件带 `timestamp_ms`（Unix 毫秒；系统时间不可用时为 null）、`pid`、`instance`（实例 nonce）、`level`、`event`。实例之间的计数独立；重启时旧、新实例分别结束和开始。通用诊断写入者若尚未取得可信实例身份，超限轮转警告的 `instance` 为 null、`pid` 为实际写入进程，不从旧退出标记猜测身份。

| 事件 | 含义 |
| --- | --- |
| `daemon_starting` / `daemon_ready` | 进入实例启动流程 / 已发布 ready descriptor |
| `daemon_stopped` / `daemon_failed` | 观测到正常结束 / 实例流程失败；提供阶段与有限错误类别 |
| `connection_failed` | 某阶段、错误类别在本实例中的首次故障 |
| `connection_failure_summary` | 同类故障的合并增量 `count` 和累计 `total` |
| `runtime_summary` | 初始、每 30 秒及正常收尾时的连接计数和资源快照 |
| `runtime_panic` | 捕获到 panic；不记录 payload、位置或堆栈 |
| `previous_exit_unknown` | 上次实例留下未完成标记，退出原因未知 |
| `exit_marker_*` | 诊断标记无效、不可用或持久化/清理不确定，不参与实例权威判断 |

不把原始错误字符串、请求正文、完整 URL、目标域名、节点名、配置路径、密码或订阅令牌写入这些事件。错误类别采用有限集合；无法细分时为 `Other`，不猜测根因。旧纯文本警告仍可与结构化事件共存。

ready 发布后的日志写入是尽力操作，不因日志锁竞争让已发布实例退出。启动时无法建立日志写入通道仍报错；运行中写入失败不会在连接任务中同步重试、阻塞转发或生成无限递归日志。没有日志不能证明没有故障。

## 连接计数与故障分类

故障阶段固定为 `ingress/dns/connect/tls/transfer/udp`。DNS、上游拨号、TLS 握手及转发使用真实错误分类，超时保留当前操作阶段；每个连接独立记录阶段，不因并发串台。原协议超时预算、回复码、路由和重试策略不因观测而放宽。

- `active_connections` 是当前 mixed TCP 连接任务数，包含 SOCKS UDP association 的控制连接；不等于独立 UDP socket 数或目标数。
- `total_connections` 是本实例累计接受的 mixed TCP 连接数；任务退出、取消或 panic 后释放活动计数。
- `failures` / `failures_by_stage` 是故障事件数，不是失败连接数。一条连接可以有多次 UDP 或其他操作失败。
- `rejections` 单独累计策略拒绝和不支持的 UDP 叶节点等准入拒绝，不算运行故障。
- 普通 EOF、reset、客户端断开及正常 idle 到期不刷故障；HTTP 长度、响应头或 chunk framing 截断（含读取中 reset）、SS 短 salt 和 obfs 截断响应仍计入转发故障。读取中的协议截断与写向已关闭客户端的普通错误分开处理；不能仅凭普通 reset 推断上游质量。SOCKS UDP 控制连接取消不计为 UDP transport 故障。
- UDP 丢弃非法数据包等原协议行为保持，不把所有静默丢包都宣称为已记录故障，也不把无响应 UDP 包等同于已证实的网络故障。

连接热路径只更新有限原子计数，不写磁盘。固定 6 个阶段 × 16 个错误类别，不按任意主机或错误文本建立无界 map。reporter 每 100ms 读取计数：同类故障首条单独记录，其余每 30 秒合并，退出时补最后增量。统计总数不因限频丢失，但磁盘故障可能使记录缺失。panic 首次单独记录，累计数量保留在摘要中。

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
- 可捕获的主实例 future panic（poll 及析构）被转成脱敏的致命结果；任务 panic 也计数，任务 join 边界转换为固定错误，不把 `JoinError` 的 payload 传播到 CLI 或启动错误文件。先逐层回收 mixed 连接、API 请求和 Trojan UDP worker，再完成最终摘要、退出标记和 hook 收尾；实例锁与 lifecycle 锁保持到收尾边界。panic hook 不打印用户 payload，结束后恢复旧 hook。日志收尾有等待预算，但不保证任意卡死的析构器有界退出；abort、双重 panic、强杀及断电没有进程内完整留痕保证。
- 最终事件写入成功后才尝试清理自有标记；文件系统持久化不确定、路径变化或收尾超时可能留下标记，所以“上次退出未知”不等于确定崩溃。
- 当前 `zc.log` 和单个归档 `zc.log.1` 各最多 8 MiB，单个新事件最多 4 KiB；共享 `zc.log.lock` 串行化写入、轮转和非 follow 快照读取。保持 owner-only、普通文件、单链接和路径安全检查。
- 外部或旧写入者把当前日志写到超限时，不复制无界内容，记录 `log_retention_exceeded` 后恢复有界轮转。只保留一代归档，不保证无限历史。

## 验证与仍需跟踪的事项

验收入口：

```bash
cargo test --offline --locked --lib --test observability_lifecycle --test observability_connections
cargo test --offline --locked --test daemon --test daemon_races --test cli
cargo test --offline --locked --test runtime --test outbound --test dns --test udp --test socks_udp
cargo clippy --offline --locked --all-targets -- -D warnings
```

实际 CLI/socket 回归覆盖初始、周期、最终摘要，真实 SOCKS 活动连接和回收，强杀后下次启动检测、正常信号退出、损坏标记保留、限频合并、日志容量和归档权限、轮转一致读取、follow 重开、采样不可用、上游拒绝、TLS 拒绝/超时、HTTP 截断、UDP 故障、策略拒绝及脱敏。panic 与采样超时在隔离子进程中验证，没有新增生产测试开关。DNS 分类另有本地解析器与真实 Runtime 的回归，不通过修改本机 DNS 注入。

联合回归曾重复出现 `daemon_races::config_override_captures_instance_before_script_preparation` 的公开 `restart` 返回 `file metadata changed during capture`。已定位为 `stopped()` 读取 descriptor 与 daemon 正常退出删除同一 inode 交错，导致 `nlink: 1→0`。现在读端也持有已有 `zc.daemon.lock`；确定性真实 syscall 调度测试证明修复前清理可抢先删除、修复后清理等待读取完成。不降低文件安全检查、不增加重试或修改原测试断言。证据见 `target/reliability/restart-capture-{deterministic-red,deterministic-green,regression,clippy}.log`，细节见[文件捕获](read-capture.md#停止确认与退出清理的读取临界区)。这不自动关闭历史 Intel CI 的其他失败。

最终相关测试覆盖 138 项通过，真实五分钟 UDP idle 用例本轮仍忽略；全目标严格 Clippy、格式检查和 Release 构建通过。联合运行记录 `target/reliability/p0-acceptance.log` 中其余 123 项通过，日志测试的一项测试夹具端口竞争随后修复，完整 15 项生命周期套件通过于 `target/reliability/p0-lifecycle-final.log`。夹具沿用项目串行隔离规则，明确释放用于冲突测试的监听器，不修改生产端口冲突策略，也不删失败样本。

迭代检视前的本机 macOS arm64 Release 隔离短测：65 秒、66 次真实 CONNECT + 4 KiB echo 全部成功，最终活动连接、故障和 panic 均为零。RSS 从约 4.84 MiB 增至 6.08 MiB；两个 30 秒周期各消耗约 140ms 进程 CPU 时间，约为单核 0.47%。只是低负载短样本，不代表空闲、满速、SS/Trojan 开销或长期无泄漏；不包含独立 `ps` 子进程 CPU。原始事件、二进制 hash 与探针保留在 `target/reliability/p0-release-observe.{json,py}`。

后续迭代检视共 4 轮：前 3 轮修复冻结错误码、任务 panic 脱敏、嵌套任务回收顺序、HTTP/SS/obfs 截断漏记、UDP 控制取消误报及超限事件元数据；第 4 轮未发现新的可操作问题。SS 观测适配器仅跟踪锁定依赖的精确读单元阶段，不解密、不重写 AEAD framing；覆盖 salt/length 完成后等待必需数据及完整 payload 后普通 RST 的区别。最终相关测试 **175 项通过、1 项五分钟 UDP idle 忽略**，全目标严格 Clippy 和格式检查通过，记录于 `target/reliability/review-loop-final.log`。前述 138 项及 65 秒短测保留为检视前证据，不冒充检视后完整性能复测。

尚未执行本次候选的四平台原生门禁、24/72 小时长稳、实际生产部署或正式资源开销基线。实例流程之前的 CLI 配置准备失败仍主要通过命令的错误输出报告，不能声称所有 CLI 失败都写入 daemon 日志。P0 的运行时观测实现和本机定向验收已完成，不代表长期稳定性或迁移发布已经验收。
