# zc 无缝运行代际切换实施方案

> **状态：** Proposed
> **位置：** 仅放在 `.agents/`，实现前不提升为用户文档
> **创建日期：** 2026-08-17
> **基线：** `main@24a15d2`
> **目标平台：** Linux / macOS，amd64 / arm64，Zig 0.16.0
> **配套研究：** `.agents/hot-upgrade-research.md`
> **执行要求：** 先测后改；每个任务有硬验收；一个 commit 只完成一个逻辑变更

## 1. 结论

zc 不应继续把更新建模为“覆盖 `$PATH` 中的二进制，然后停止旧 daemon、启动新 daemon”。
目标模型是一次**运行代际替换事务**：旧代际与候选代际短暂并存，复用同一个内核监听
socket；候选代际接管新连接后，旧代际只服务已经接收的连接，直到连接归零或到达有界
drain deadline。

本方案选择：

- **旧/新进程点对点 handoff**，不引入永久 supervisor；
- 通过 owner-only `AF_UNIX` 控制通道和 `SCM_RIGHTS` 传递 listener FD；
- 传递当前 daemon 的同一个 `flock` FD，不做 unlock/relock；
- 用单一权威 runtime state 的 CAS 完成 active 代际切换；
- 用不可变版本目录和原子 symlink 切换发布二进制；
- `reload` 与 binary upgrade 复用同一个 graceful replacement 模块；
- 不使用 `SO_REUSEPORT` 作为正确性基础，不做进程内代码热补丁。

第一个可用版本先实现“同二进制、同监听集合”的 graceful reload；确认端到端成立后，再接
版本化安装器。这样先得到一个能运行、能回滚、能证明无监听空窗的最小纵切面，再扩展
binary upgrade。

---

## 2. 目标与非目标

### 2.1 目标

1. **新连接无监听空窗**
   - 对监听指纹完全相同的替换，旧代际停止 `accept` 到新代际开始 `accept` 期间，至少有
     一个进程持有同一个 listening socket；内核 accept queue 不被销毁。
   - 在规定的场景负载和 backlog 内，更新期间 TCP connect failure 必须为 0。

2. **已有连接连续**
   - 已被旧代际接收的 HTTP CONNECT、SOCKS5、mixed、Shadowsocks/Trojan/AnyTLS outbound
     relay 与 SOCKS5 UDP association 继续由旧代际服务。
   - 不尝试把已建立连接的用户态状态迁移到新进程。

3. **失败不影响旧流量**
   - candidate 配置解析、能力校验、FD 校验、线程创建、runtime publication 或健康确认失败
     时，旧代际恢复或继续接收新连接。
   - 在 `finalize` 之前允许确定性 rollback；之后不再声称可自动 rollback。

4. **唯一 active authority**
   - 任意时刻最多一个 active 代际。
   - MVP 最多一个 candidate 和一个 draining 代际；有未完成 drain 时拒绝第二次替换。

5. **配置和二进制共用同一原语**
   - 配置 reload：candidate executable 与 active 相同，prepared config 不同。
   - 二进制 upgrade：candidate executable 不同，prepared config 可以相同或由新版本重新加载。

6. **状态可观察、错误可操作**
   - `status`、minimal API、日志和 JSON 输出使用相同的 active / replacing / draining 概念。
   - 所有拒绝都给出明确 code、失败阶段、旧代际是否仍 active、下一步命令。

7. **跨平台行为一致**
   - Linux/macOS 四个 release target 使用同一事务语义。
   - 平台能力不足时 fail closed，不静默降级为 stop/start。

### 2.2 非目标

- 不迁移已经建立的 TCP/TLS/AnyTLS 会话到 candidate 进程。
- 不保证 bind address、端口、listener 类型或 socket option 改变时无缝。
- MVP 不支持 foreground / systemd supervised daemon 的内部自替换；由 supervisor 管理时明确拒绝。
- 不支持 Windows。
- 不做 `dlopen` 插件、内存 patch、函数表热替换。
- 不在 MVP 中允许多个 draining 代际堆叠。
- 不用全局 `ps`/`pgrep` 扫描重新收养未知 daemon。
- 不为旧 runtime descriptor、旧安装布局或旧 handoff protocol 增加长期兼容层。
- 不自动把 graceful replacement 失败降级成会断连接的 cold restart。

---

## 3. 当前实现基线

| 现状 | 代码位置 | 影响 |
| --- | --- | --- |
| `reloadDaemon()` 固定返回 `HotReloadUnsupported` | `src/daemon.zig` | 当前所谓 reload 实际走 restart fallback |
| `replaceDaemonWithOps()` 先 stop old，再 start target | `src/daemon.zig` | 监听端口必然存在空窗，旧连接被进程退出切断 |
| mixed/HTTP/SOCKS/API 各自在 accept 线程内部 bind | `src/proxy/*.zig`、`src/api/server.zig` | 主 runtime 无法统一暂停、传递和验证 listener |
| listener 只启用 `SO_REUSEADDR`，显式禁用 `SO_REUSEPORT` | `src/compat.zig` | 正确阻止双实例，但新进程无法自行 bind 同端口 |
| listener 与多数 connection worker detached | `src/main.zig`、`src/proxy/*.zig` | 无法 join；process exit 是当前唯一回收点 |
| stop request 在主循环调用 `std.process.exit()` | `src/main.zig` | 不运行 defers，不 drain 连接和 manager/pool |
| mixed 有局部 `ConnectionLimiter`；API 有局部 active count；plain SOCKS/HTTP 未统一 | 对应 listener 文件 | 无全 runtime drain barrier；HTTP listener 还会同步处理长连接 |
| runtime descriptor 只表达单 pid/nonce/ready | `src/runtime_descriptor.zig` | 无法表达 candidate 与 draining 代际 |
| pid file、lock、descriptor 同时存在 | `src/daemon.zig`、`src/runtime_dir.zig` | 多份 authority 容易出现错位和清理竞态 |
| prepared config 已经不可变、带完整 runtime metadata | `src/daemon.zig` | 可直接作为 candidate 的冻结输入 |
| daemon lock 已支持 FD 继承并校验 inode | `src/daemon.zig` | 可扩展为跨进程 FD transfer，不必重新抢锁 |
| startup 已有 listener readiness、descriptor ready=false→true、nonce/CAS | `src/main.zig`、`src/runtime_descriptor.zig` | 可复用为 replacement 两阶段 publication |
| selection 已有 desired generation barrier 与 CAS | `src/main.zig`、`src/proxy/outbound/manager.zig` | candidate cutover 前可复用最终 desired reconcile |
| installer 原子 rename 单一 regular-file target，运行时拒绝替换 | `install.sh`、`scripts/install/local-dev-install.sh` | 避免覆盖事故，但不能让旧/新版本同时可靠存在 |

因此这不是安装脚本的 rename 顺序问题。缺失的是 listener 所有权、可取消 accept、连接
lifetime barrier、跨进程 FD handoff 和多代际 authority。

---

## 4. 统一术语

这些是 runtime 实现术语，不改变项目已有的
`profile / proxy / proxy-group / rule / connection / runtime / health` 领域词汇。

| 术语 | 含义 |
| --- | --- |
| **Runtime Generation / 运行代际** | 一个进程内不可变的 executable identity、prepared config、Engine、OutboundManager 和 listener/connection runtime |
| **Active Generation / active 代际** | 唯一允许接收新流量、唯一可接受控制面 mutation 的运行代际 |
| **Candidate Generation / candidate 代际** | 已加载并准备线程，但 accept gate 尚未提交的候选代际 |
| **Draining Generation / draining 代际** | 已停止接收新连接，只服务既有 connection 的旧代际 |
| **Runtime Epoch / runtime epoch** | runtime state 每次 CAS mutation 单调递增的版本；不与 selection generation 混用 |
| **Selection Generation / selection generation** | 现有持久化选择世代，只属于 active profile 的 desired/applied 状态 |
| **Listener Fingerprint / listener 指纹** | role、address family、bind address、port、socket type、必要 socket options 的规范化身份 |
| **Replacement Transaction / 替换事务** | 从 candidate admission 到 finalize/rollback 的单次有 nonce 的状态机 |
| **Quiesce** | 停止 accept/control mutation，等待 acceptor 确认退出；不关闭既有 connection |
| **Cutover** | runtime authority 从 old active CAS 到 candidate active 的瞬间 |
| **Finalize** | 安装指针与 candidate 均确认稳定后，放弃 rollback，允许 old 退出 |
| **Drain** | old quiesce 后只保留既有 lease；finalize 后开始有界等待其归零的过程 |

代码和 schema 中禁止新增无修饰的 `generation` 字段；必须使用 `runtime_epoch` 或
`selection_generation`。

---

## 5. 对“无缝”的精确定义

### 5.1 保证范围

当且仅当 old 与 candidate 的 listener 指纹集合完全一致时：

- listener FD 从 old 复制到 candidate，二者引用同一内核 listening socket；
- 从 old 开始 quiesce 到 candidate acceptor ready，socket 始终打开；
- 已排队但尚未 `accept` 的连接保留在同一个 accept queue；
- old 已接收的连接继续由 old 处理；candidate 只处理 cutover 后接收的连接；
- cutover pause 必须有 deadline，MVP 目标为 **250 ms 内**；超时立即 rollback；
- 更新本身不得产生 `ECONNREFUSED`、listener disappearance 或端口被第三方抢占。

这不等价于无限负载下绝对零失败。若外部连接速率在 250 ms 内填满固定 backlog，内核仍可
拒绝连接；场景门禁必须声明连接速率和 backlog，不能把过载与更新正确性混为一谈。

### 5.2 Drain policy

MVP 使用有界 policy：

- data-plane drain deadline：默认 **15 分钟**，与当前 relay idle reap 尺度一致；
- control-plane request drain deadline：**2 秒**；
- 到期仍存活的连接被计数、记录并由 old 进程退出强制关闭；
- `status` 显示 remaining connections 和 deadline；
- drain 中拒绝新 replacement，避免旧进程无限堆积；
- 测试通过注入 clock/deadline 使用毫秒级 deadline，不真实等待 15 分钟。

因此对外承诺应写成：**新连接无监听空窗；既有连接在 drain deadline 内允许完成。**
不能宣传“任何无限长连接永不受影响”。

### 5.3 明确不兼容的变更

以下任一变化使 hot replacement 返回 `REPLACE_LISTENER_INCOMPATIBLE`：

- mixed ↔ split HTTP/SOCKS listener 形态变化；
- bind address、address family 或 port 变化；
- controller 增删或 controller port 变化；
- 影响 listener 的 socket option/fingerprint 变化；
- listener count 超过固定上界。

用户必须显式执行 `zc restart`。不能在 `reload` 或 installer 中静默 cold fallback。

---

## 6. 方案比较与决策

### 6.1 仅原子覆盖二进制：拒绝

原子 rename 只影响未来 `exec`，不会替换运行进程。旧 daemon 继续执行旧 inode，而 PATH 中
CLI 已经变成新版本；runtime schema、路径和 lifecycle 语义一旦变化就会错位。

### 6.2 原地 `execve`：拒绝

listener FD 可以保留，但所有用户态 connection、TLS 状态、relay buffer、outbound pool 和
selection runtime 都会消失，无法保住既有连接。

### 6.3 `SO_REUSEPORT` 双 bind：拒绝作为主方案

优点是实现快；缺点是：

- 内核会在 old/new listener 间分配流量，cutover ownership 不确定；
- old 保留 listener 供 rollback 时仍可能收到新连接；
- Linux/macOS 语义和调度细节不同；
- 放宽了当前“第二个 active listener 必须失败”的安全不变量；
- accept queue 与 socket option 不是一个共享对象，故障验证更复杂。

可以在未来作为明确的 platform adapter 研究，但不能成为默认正确性路径。

### 6.4 永久 master/supervisor：MVP 不选

永久 socket owner 能简化 worker replacement，但引入一个始终运行、也需要升级的控制进程和
长期稳定的 master/worker protocol。对当前单 daemon 架构过重。若 Task 0 证明 macOS/Linux
FD transfer 或共享 flock 不满足不变量，再重新评估这一方案；不并行实现两套路径。

### 6.5 systemd socket activation：可选 adapter，非默认

Linux supervised 部署可让 systemd 持有 listener，但 standalone macOS/Linux 仍需内建方案，
且 socket activation 本身不会保留被停止 worker 的既有连接。后续可复用 `ListenerSet.adopt`
接 systemd adapter，不纳入 MVP。

### 6.6 进程内 RCU config swap：后续优化

RCU/refcount config generation 可以降低 config reload 的双进程开销，但只解决配置，不解决
binary upgrade；同时 Engine、Manager、selection、pool 和连接 borrow 的 lifetime 重构更深。
先用 process generation 统一解决两类问题。若后续数据证明进程 replacement 太慢，再在同一个
`RuntimeGeneration` seam 内增加 in-process adapter。

### 6.7 选择 FD handoff

该方案让复杂度集中在一个 replacement seam，调用者只表达 candidate，而不用知道 socket
transfer、lock ownership、descriptor CAS、rollback 和 drain。NGINX 与 Envoy 的共同模式也是
“新进程完整初始化 → listener handoff/继承 → old drain”，不是连接迁移。

---

## 7. 目标架构

```text
                         owner-only runtime directory
                    ┌──────────────────────────────────┐
                    │ runtime-state.json (CAS authority)│
                    │ zc.lock (shared flock description)│
                    │ replacement request / Unix socket │
                    └──────────────────────────────────┘
                               ▲               ▲
                               │               │
                  control + FD │               │ state CAS
                               │               │
┌──────────────────────┐       │       ┌──────────────────────┐
│ old active generation│───────┘       │ candidate generation │
│ executable A         │ SCM_RIGHTS    │ executable A or B    │
│ listener fd(s)       │──────────────▶│ same listener fd(s)   │
│ accepted connections │ lock fd       │ accept gate closed   │
└──────────────────────┘               └──────────────────────┘
          │                                      │
          │ quiesce                              │ activate
          ▼                                      ▼
┌──────────────────────┐               ┌──────────────────────┐
│ old draining         │               │ new active           │
│ no new accepts       │               │ all new accepts      │
│ old connections only │               │ new connections only │
└──────────────────────┘               └──────────────────────┘
```

不新增永久中间进程。替换结束后只剩 candidate/new active；old 在 drain 完成后退出。

---

## 8. 深模块与 seam

### 8.1 `RuntimeGeneration` 模块

**建议文件：** `src/runtime_generation.zig`

**接口职责：** 用少量方法管理一个完整运行代际，调用者不直接拼装 Config、Engine、Manager、
API owner、listener thread 和 connection lifetime。

概念接口：

```zig
pub const RuntimeGeneration = struct {
    pub fn prepare(options: PrepareOptions) !RuntimeGeneration;
    pub fn arm(self: *RuntimeGeneration, source: ListenerSource) !void;
    pub fn activate(self: *RuntimeGeneration) !void;
    pub fn quiesce(self: *RuntimeGeneration) !QuiescedGeneration;
};

pub const QuiescedGeneration = struct {
    pub fn resume(self: *QuiescedGeneration) !void;
    pub fn finalize(self: *QuiescedGeneration, policy: DrainPolicy) DrainHandle;
};
```

接口不冻结为最终签名，但必须保持以下不变量：

- `prepare` 不 bind、不 accept、不 publication；失败无外部副作用；
- `arm` 后 acceptor 已创建但 gate 关闭；
- `activate` 只能调用一次；成功返回时 expected listeners 都能 accept；
- `quiesce` 先停止控制面 mutation，再停止并 join acceptor，然后返回可 `resume` 或
  `finalize` 的 typestate；它不能在 cutover 前封死 connection admission 或同步等完长连接；
- `resume` 只用于 finalize 前 rollback，使用原 ListenerSet 重启 accept/control；
- `finalize` 是不可逆点：调用 `ConnectionRegistry.beginDrain()` 并返回 `DrainHandle`；
- `DrainHandle.wait()` 等待 connection lease；finalize 前即使连接已归零，也要保留 old listener
  和 generation 以支持 rollback；
- `deinit` 只能发生在 acceptor 已 join 且 connection registry 为 0 时；
- 强制 deadline 路径不伪装成 clean drain。

**隐藏的 implementation：** config load、capability validation、desired selection reconcile、Engine、
OutboundManager、AnyTLS pool、API server lifetime、listener workers、connection registry、日志上下文。

### 8.2 `ListenerSet` 模块

**建议文件：** `src/listener_set.zig`

存在两个真实 adapter，因此这个 seam 是必要的：

- `FreshListenerSource`：普通 cold start 时创建 socket；
- `TransferredListenerSource`：replacement 时接收并验证 old 的 socket。

概念接口：

```zig
pub const ListenerSet = struct {
    pub fn open(plan: ListenerPlan, source: ListenerSource) !ListenerSet;
    pub fn serve(self: *ListenerSet, runtime: ServeRuntime) !Acceptors;
    pub fn send(self: *const ListenerSet, channel: *HandoffChannel) !void;
};
```

模块内部负责：

- listener role：`mixed | http | socks | controller`；
- 固定 listener 上界：split proxy + controller 时最多 3 个；加 lock FD 后一次最多传 4 个 FD；
- listener fingerprint 规范化和 exact-set comparison；
- received FD 的 `fstat`、`SO_TYPE`、`SO_ACCEPTCONN`、`getsockname`、重复 FD/role 校验；
- CLOEXEC、nonblocking 和 write-safety policy；
- `poll(listener, notifier)` 驱动的可取消 accept loop；
- quiesce notifier、acceptor ACK 和 join；
- 绝不从 foreign thread 直接 close 一个阻塞在 `accept` 的 FD。

protocol-specific 模块改为处理已接收 connection，不再自己 bind：

```text
mixed/http/socks/api: bind + accept + lifetime
                    ↓
ListenerSet: bind/adopt + accept + control
protocol modules: accepted connection handling only
```

### 8.3 `ConnectionRegistry` 模块

**建议文件：** `src/connection_registry.zig`

统一替换：

- mixed 的局部 `ConnectionLimiter`；
- API 的局部 `active_connections`；
- SOCKS/HTTP 未跟踪的 detached worker。

概念接口：

```zig
pub const ConnectionRegistry = struct {
    pub fn tryAcquire(self: *ConnectionRegistry, kind: Kind) ?Lease;
    pub fn beginDrain(self: *ConnectionRegistry) void;
    pub fn wait(self: *ConnectionRegistry, deadline_ms: i64) DrainResult;
};
```

硬不变量：

- admission 上界仍为现有 TCP 128、UDP association 64；
- `beginDrain` 后新 acquire 必须失败，且只能在 replacement `finalize` 时调用；
- acceptor join 发生在 `beginDrain` 之前，避免“最后一个 accept”遗漏，同时保留finalize前
  rollback所需的`resume`能力；
- Lease release 必须是 worker 对 generation 最后一次访问；registry 归零后没有线程再借用
  Config/Engine/Manager/API；
- worker 可以 detached，但只有满足上一条才能用 active count 作为 join barrier；更优先改成可 join 的
  bounded worker ownership；
- plain HTTP CONNECT 必须移出 listener thread，否则一个长连接会阻塞后续 accept 和 quiesce；
- UDP association 由 control TCP lease 覆盖，并保留独立 UDP count 上界。

### 8.4 `HandoffProtocol` 模块

**建议文件：** `src/handoff_protocol.zig`

外部 seam 只支持 Unix domain socket；内部测试 seam 有真实 socketpair adapter，不创建通用 transport
框架。

协议要求：

- exact `protocol_version`；版本不一致返回 `REPLACE_PROTOCOL_MISMATCH`，无兼容 fallback；
- 128-bit transaction nonce；
- canonical bounded frame，单 frame 最大 64 KiB；
- metadata frame 与 FD bundle 分离；FD bundle 使用 `sendmsg/recvmsg`，一个 marker byte 携带
  ancillary data；
- 接收 FD 数必须与 metadata 完全相等，extra/missing/truncated ancillary data 全部拒绝并关闭；
- 所有 read/write/phase wait 使用 monotonic absolute deadline 和固定重试上界；
- peer euid 必须等于当前 euid；Linux 使用 peer credentials，macOS 使用平台等价检查；
- runtime dir、socket node 和 request file 必须 owner-only、no-follow、canonical；
- candidate pid、nonce、self executable device/inode/build id 与 request 一致；
- channel EOF 在 finalize 前触发 rollback 或明确的恢复判定。

### 8.5 `ReplacementCoordinator` 模块

**建议文件：** `src/replacement_coordinator.zig`

这是调用者使用的主要深模块：

```zig
pub fn replace(options: ReplaceOptions) !ReplaceResult;
```

`ReplaceOptions` 只表达：candidate executable identity、prepared config、expected active nonce、
drain policy、是否需要 install pointer commit。内部隐藏：

- admission 和并发替换拒绝；
- candidate process launch/setsid/log wiring；
- handoff channel；
- FD/lock transfer；
- old quiesce、新 activate；
- runtime CAS；
- readiness/stability；
- rollback；
- drain/finalize；
- cleanup。

`reload`、`config update --apply hot` 和 installer 都必须调用该接口，不得各自复制状态机。

---

## 9. Runtime authority 重构

### 9.1 单一权威状态

移除 `zc.pid` 作为 authority。新的规则：

- `zc.lock`：证明本环境存在一个 active/candidate/draining 集合，并阻止无关 cold start；
- `runtime-state.json`：唯一记录 active identity、replacement phase、candidate/draining；
- active PID 只从 runtime state 读取；
- lock held 但 state 缺失/损坏时报告 `lock_held_runtime_untracked`，不猜测、不收养；
- state 存在但 lock 未持有时视为 stale state，只在安全 CAS/identity 验证后清理。

不继续维护 pid file 与 descriptor 两份事实。`status.paths.pid_file` 及相关旧路径直接删除，相关
文档和测试同步修改。

### 9.2 建议 schema

示意结构：

```json
{
  "schema_version": 3,
  "runtime_epoch": 42,
  "active": {
    "pid": 1234,
    "nonce": "...",
    "build_id": "v1.1.0+commit",
    "executable": { "device": 1, "inode": 2 },
    "ready": true,
    "identity": { "key": "default", "revision": "..." },
    "selection_generation": 9,
    "invocation": {},
    "listeners": []
  },
  "replacement": null,
  "draining": null
}
```

replacement 存在时包含：

```json
{
  "transaction": "128-bit nonce",
  "phase": "preparing|armed|quiesced|cutover|stabilizing|finalizing|rolling_back",
  "candidate": {},
  "started_at": "RFC3339"
}
```

draining 包含 old descriptor、quiesced_at、可空的 drain deadline、是否已 finalize，以及 last
observed connection counts。磁盘 schema 只记录恢复所需事实；高频 active count 不每次落盘，
由 old/new IPC status 提供。

### 9.3 CAS 规则

- 每次 state mutation 都要求 exact `runtime_epoch` 和 expected active nonce；
- successful mutation 将 `runtime_epoch + 1`，checked overflow fail closed；
- selection mutation 只允许更新 active 的 `selection_generation`，必须完整保留 replacement/draining；
- replacement cutover 同时替换 active 并写入 draining，不能分两次 publication；
- rollback 同时恢复old active，并在candidate已有连接时把candidate原子改写为reverse-draining；
  没有连接时才直接移除candidate，任何路径都不能留下双active；
- old drain 完成只可删除与自身 nonce 完全匹配的 draining entry，绝不能删除 new active；
- `ready=true` 只能从同一 active nonce 的 `ready=false` 单向提升；rollback 使用另一次明确 CAS，
  不允许 readiness 静默回退。

### 9.4 Daemon lock handoff

Zig 0.16.0 `std.Io.File.lock` 在 POSIX Threaded adapter 中使用 `flock`。MVP 传递同一个打开文件
描述的 duplicate：

- old 与 candidate 暂时都持有 lock FD；
- candidate 不调用 unlock，只设置自己的 received descriptor 为 CLOEXEC；
- old close 后 candidate 的 duplicate 继续维持 lock；
- rollback 时 candidate close，old 仍维持 lock；
- 不存在 unlock/relock 窗口，第三个 daemon 无法抢占；
- canonical lock file inode 在整个事务中不得被 replace。

Task 0 必须用真实进程证明该行为在 Linux/macOS release target 成立，不能只依赖推论。

---

## 10. Replacement 状态机

### 10.1 正常路径

| 阶段 | Authority | Old 行为 | Candidate 行为 | 失败处理 |
| --- | --- | --- | --- | --- |
| `steady` | old active/ready | 正常 accept/mutation | 不存在 | — |
| `admission` | old active/ready | 不变 | CLI 校验 candidate 与 exact active nonce | 不改 runtime |
| `preparing` | old active/ready + replacement | 正常服务 | 加载 prepared config、能力校验、恢复 desired selection，不 bind | abort candidate |
| `handoff` | old active/ready + replacement | 认证 peer，发送 listener + lock FD，继续 accept | 接收并逐个验证 FD | abort candidate，old 不变 |
| `armed` | old active/ready + candidate armed | 正常 accept | acceptor threads 已启动但 gate closed | abort candidate |
| `control_quiesce` | old active/ready | 禁止新 control mutation；等待旧 API request ≤2s | gate closed | old 恢复 control |
| `listener_quiesce` | old active/ready | notifier 停 accept，join acceptors，仍持 listener FD | gate closed | old resume accept/control |
| `cutover` | candidate active/ready=false；old draining(unfinalized) | 不 accept，尚未seal registry，保留 listener 供 rollback，继续旧 data connections | authority 已切换，尚未声明 ready | CAS 失败则 old resume |
| `activate` | candidate active/ready=false | 不 accept | 打开 gate，所有 acceptor ACK | 反向 CAS + old resume |
| `stabilizing` | candidate active/ready=true；old draining | 保留 rollback 能力 | final desired reconcile；内部 health/stability wait | rollback |
| `publish_pointer` | 同上 | 等待 | binary upgrade 时 installer 原子切 current symlink | pointer 失败则 rollback |
| `finalize` | candidate active/ready=true；old draining(finalized) | 放弃 rollback，seal registry并开始bounded drain deadline | 正常服务新连接 | finalize 后不自动回滚 |
| `retire` | candidate active/ready=true | connection=0 或 deadline 后退出，CAS 删除 draining | 正常服务 | forced count 可观察 |
| `steady` | candidate active/ready=true | 不存在 | 唯一 daemon | — |

### 10.2 Cutover 顺序不变量

1. Candidate acceptor 必须先 armed 并 ACK gate closed。
2. Old acceptor quiesce/join 后，才允许 runtime active CAS。
3. CAS 后 candidate 才打开 gate。
4. Candidate acceptor 全部 ACK 后，才把 active `ready` 提升为 true。
5. 从 old quiesce 到 candidate ACK 的总时间超过 250 ms，必须 rollback。
6. Old 在 finalize 前始终保留 listener FD；“不 accept”不等于 close。
7. Finalize 前 candidate 失败，old 必须能够用原 FD resume accept。

该顺序允许短暂排队延迟，但没有 socket close/rebind 空窗。

### 10.3 Rollback 路径

#### Cutover 前

- Candidate 关闭 received FD 和 lock duplicate；
- 删除 transaction request/socket/prepared candidate snapshot；
- runtime state CAS 回 `steady(old)`；
- old 未 quiesce则完全不动，已 quiesce则 resume accept/control；
- installer target 不切换。

#### Cutover 后、finalize 前

1. Candidate 先 quiesce 自己的 acceptor；
2. CAS：active candidate → old ready=false；移除old的draining身份，并在candidate已有连接时将其
   写为reverse-draining；
3. Old resume listener 和 control；
4. Old ACK 后提升 old ready=true；
5. Candidate 若已接收连接，则作为reverse-draining generation保留这些连接到归零/deadline；没有
   connection才立即退出；
6. 若 binary pointer 已切 candidate，installer 原子切回 old version；
7. 返回 `REPLACE_FAILED_ROLLED_BACK`，不能输出成功。若candidate是crash而非可控rollback，其
   已接收连接无法保留，结果必须标记continuity degraded。

#### Finalize 后

不再自动回滚。Candidate crash 按普通 daemon crash 处理。保留一个永久等待 rollback 的 old 进程会
破坏 bounded resource 不变量，因此 finalize 是明确不可逆点。

### 10.4 Coordinator 异常退出

Candidate/old 不能无限等待 installer/CLI：

- 每阶段有 monotonic deadline；
- finalization 前 control channel EOF 进入 recovery；
- binary upgrade 检查原子 current symlink 的 exact executable identity：
  - 指向 candidate：继续 finalize；
  - 指向 old：rollback；
  - missing/第三个 identity：candidate 继续 accept，old 保留 rollback FD，state 标记
    `operator_intervention`，拒绝新 replacement，不猜测；
- config reload 无 install pointer，coordinator EOF 默认 rollback。

### 10.5 进程 crash

| Crash 点 | 预期 |
| --- | --- |
| Candidate 在 cutover 前 crash | old 一直 active；清理 transaction |
| Candidate 在 cutover 后、finalize 前 crash | old CAS rollback并resume；candidate已接收连接随crash丢失，明确标记continuity degraded |
| Old 在 candidate ready 前 crash | candidate 关闭 handoff；按普通 cold recovery重新 bind/start，不伪造 graceful success |
| Old 在 cutover 后 crash | candidate 已持 listener/lock；继续 ready/finalize；old 既有连接因 crash 已丢失，结果不得标记 full continuity |
| Candidate 在 finalize 后 crash | runtime health 报 stopped/stale；由显式 start/supervisor恢复 |
| 两者都 crash | 最后一个 lock FD 关闭；后续 start 清理 stale state并正常 bind |

---

## 11. Listener 与 accept loop 重构

### 11.1 Listener creation 移出 protocol 模块

`mixed.startWithReady`、`http.startWithReady`、`socks5.startWithReady` 和
`ApiServer.startWithAcceptGate` 不再调用 `listenReuseAddr`。它们改为接受已经验证的 listener
handle/accepted connection source。

`compat.net.ReuseAddrListener` 增加：

- 从 raw FD 构造的受控入口，仅供 `ListenerSet`；
- `duplicate`/identity validation 所需 helper；
- poll-ready nonblocking accept；
- `getsockname`/`SO_TYPE`/`SO_ACCEPTCONN` 查询；
- Unix FD send/receive 放在独立 handoff helper，而非 net 高层 wrapper。

### 11.2 Acceptor control

每个 acceptor 使用：

```text
poll([listener_fd, control_notifier_fd], absolute_deadline)
```

control event：

- `activate`：从 armed gate 进入 accepting；
- `quiesce`：停止调用 accept，发 ACK，线程正常返回；
- `abort`：candidate 未提交时退出；
- `shutdown`：fatal/explicit stop。

不使用每 1 ms sleep polling，不依赖 signal handler，不从其他线程 close 阻塞 FD。

### 11.3 Connection ownership

- accept 成功后先拿 `ConnectionRegistry.Lease`，失败则关闭 connection；
- task 对 Config/Engine/Manager 的 borrow 由 Lease 覆盖；
- task cleanup 顺序必须保证 Lease release 是最后一个 generation 访问；
- listener/worker task allocation 失败只影响该 connection，不能杀 daemon；
- old quiesce 后不再产生新 Lease；
- registry=0 后才允许 manager/api/config deinit。

### 11.4 Fatal listener error

当前 committed listener fatal 会直接 `process.exit`。重构后：

- fatal error 上报 `RuntimeGeneration` event loop；
- active generation 将 `ready=false`、停止其他 listener、更新 health；
- replacement 中 candidate fatal 触发 rollback；
- normal active fatal 可按现有 fail-fast policy 退出，但必须由 owner event loop统一执行清理；
- detached thread 不得自行删除 runtime state或直接输出 lifecycle envelope。

---

## 12. Control plane 与 selection 一致性

数据连接可以在 old drain；控制面不能同时有两个 writable owner。

Cutover 前执行：

1. old `control_available=false`，新 mutation 返回 503/typed unavailable；
2. 获取/等待 old `selection_apply_lock` 和所有 active API request，deadline 2s；
3. candidate 从 authoritative state 再次加载 desired selection；
4. 复用现有 `FinalDesiredGuard` 与 `reconcileRuntimeDesired`；
5. runtime state CAS active nonce；
6. candidate controller accept gate 打开；
7. candidate `control_available=true`。

任何 selection mutation 都必须 CAS active nonce + runtime epoch + selection generation。旧 controller
连接即使在 cutover 后继续发送请求，也只能得到 stale-active 拒绝，不能改 old manager 后冒充已应用。

`GET /status`：

- active controller 返回自己的内存 selections/config；
- CLI 用 runtime state 定位 active endpoint；
- draining controller 不再接收新请求；
- status 获取失败时只显示 descriptor facts，不从 durable active profile猜 daemon 内存。

---

## 13. 配置 reload 语义

### 13.1 统一行为

`zc reload`：

- active daemon 不存在：返回明确 no-op，不声称 `hot_applied`；
- managed background daemon + exact listener set：执行 same-binary graceful replacement；
- foreground/supervised：返回 `REPLACE_SUPERVISED`；
- listener fingerprint 改变：返回 `REPLACE_LISTENER_INCOMPATIBLE`；
- transition/drain 已存在：返回 `REPLACE_IN_PROGRESS`；
- candidate 任一步失败：old 保持 active，返回 rollback/failure facts。

### 13.2 简化 apply mode

当前 `auto|hot|restart` 中 `hot` 实际不可用，`auto` 会静默 fallback。目标行为直接移除过时路径：

- `hot`：只允许 graceful replacement，失败不 fallback；
- `restart`：明确的 cold stop/start，可能中断 connection；
- 删除 `auto` 与 `restart_fallback` token；
- `config update` 默认 `hot`；需要 cold behavior 必须显式 `--apply restart`；
- JSON 结果区分 `applied=false`、`graceful_applied`、`restart_applied`。

这是用户可感知变化，落地时同步更新 `docs/cli/spec.md`、`docs/cli/ux-workflow.md`、
`docs/reliability/e2e.md`。

### 13.3 Prepared config

继续复用现有 authenticated immutable prepared snapshot：

- Candidate 只从 snapshot 加载，不在 handoff 中重新读取可变源文件；
- candidate 仍执行配置语法、能力、资源和进程内listener冲突校验，但对将被handoff的exact endpoint
  不运行普通`checkPortAvailable`；端口正在被old占用是预期状态，正确性由listener指纹和received FD
  校验证明；
- binary candidate 使用自己的 parser/capability gate读取 snapshot；新版本拒绝即在 cutover 前失败；
- snapshot 只在 active/candidate/draining 都不引用后删除；
- replacement state 保存 exact snapshot identity，不提供 cwd/source fallback。

---

## 14. Binary install / upgrade

### 14.1 版本化布局

Standalone installer 目标布局：

```text
$ZC_INSTALL_DIR/
  zc -> .zc/versions/v1.1.0-<sha256>/zc
  .zc/
    versions/
      v1.1.0-<sha256>/zc
      v1.1.1-<sha256>/zc
    install.lock/
    install-state.json
```

规则：

- `.zc` owner-only；candidate binary 是 regular file、no symlink、owner 正确、group/other 不可写；
- version directory 名由 immutable tag + verified archive digest 导出；
- candidate 先 checksum、archive、codesign（macOS）、`--version` 和内部 self-check；
- `$ZC_INSTALL_DIR/zc` 是 installer 管理的 symlink；临时 symlink 与目标同目录，使用 atomic rename；
- 不覆盖运行中 executable inode；
- old version 在 draining 结束前不得 GC；
- descriptor 存 device/inode/build id，不以可变逻辑路径判断进程版本。

### 14.2 Running upgrade 正常流程

1. Installer 取得 install lock；
2. 下载、校验并发布 immutable candidate version directory；
3. 读取 authoritative runtime state；
4. 若 stopped：原子切 symlink，完成；不擅自启动；
5. 若 managed background active：直接执行 candidate binary 的内部 handoff entry；
6. Candidate 用 active prepared config 完成 replacement 到 ready=true；
7. Installer 验证 active executable identity 正是 candidate；
8. 原子切 `$ZC_INSTALL_DIR/zc` symlink；
9. 重读 symlink和 runtime state，二者都指向 candidate；
10. 发送 finalize；old drain；
11. 写最终 install state，释放锁；
12. old retired 后 GC 无引用版本。

### 14.3 Installer rollback

- Candidate ready 前：target symlink 未改，删除 candidate 或留作 cache，old 不变；
- Candidate ready 后、symlink 切换失败：请求 runtime rollback，确认 old ready，再失败退出；
- symlink 已切 candidate、finalize 前 candidate 失败：切回 old symlink，然后 runtime rollback；
- runtime rollback 失败：保留两个 version，输出 exact active/pointer identity 和人工处理步骤；
- trap/signal 不删除 descriptor 仍引用的版本；
- 禁止“status 看起来 running 就算成功”，必须匹配 active nonce、PID、build id、device/inode。

### 14.4 Bootstrap 与 protocol compatibility

现有发布版不理解 handoff protocol，因此引入该能力的第一个版本必须 cold install：

- running legacy daemon 时 installer 明确返回 `INSTALL_HANDOFF_UNSUPPORTED`；
- 用户先 `zc stop`，再执行新 installer；
- 安装后直接采用唯一的 versioned layout，不长期维护 regular-file layout分支；
- 后续版本要求 exact handoff protocol version；不匹配时 fail closed并要求显式 cold upgrade；
- 不自动 fallback，因为自动 stop/start 会违背用户对无缝升级的预期。

### 14.5 Homebrew

MVP 只保证 standalone installer。Homebrew 仍文档化为 supervisor/cold upgrade，直到有独立验收证明
Cellar cleanup、symlink切换和 post-upgrade hook 能满足同样事务。不能因为 standalone 已完成就宣称
Homebrew 无缝。

---

## 15. CLI、minimal API 与日志

### 15.1 `status`

保持 `state=running|stopped` 的高层概念，新增而不重复 active facts：

```json
{
  "state": "running",
  "pid": 2002,
  "nonce": "...",
  "build_id": "v1.1.1+...",
  "runtime_epoch": 42,
  "active_config": "default",
  "selection_generation": 9,
  "replacement": null,
  "draining": {
    "pid": 1001,
    "build_id": "v1.1.0+...",
    "connections": { "tcp": 3, "udp": 1, "api": 0 },
    "deadline_seconds": 712
  }
}
```

要求：

- `pid` 永远是 active PID；
- replacement phase 单独展示，不把 candidate PID冒充 active；
- draining 状态不可从 profile/config猜测；优先 old IPC，失联时标记 unavailable；
- 删除 pid file path；保留 lock/runtime state/log paths；
- text 和 JSON 使用同一结构化 snapshot。

### 15.2 `start` / `stop` / `restart` 与replacement并发

- `start` 只看RuntimeState active + lock；candidate/draining存在时仍视为已有runtime，不能启动第三实例；
- `stop` 在pre-finalize replacement中先abort candidate并恢复/确认old authority，再停止old；
- `stop` 在finalized draining中同时定向通知active和draining nonce，不能只停active后留下old进程；
- `restart` 是显式cold操作：若有replacement/drain先返回`REPLACE_IN_PROGRESS`，不隐式强杀；用户可
  先`zc stop`再`zc start`；
- lifecycle request都绑定exact nonce/runtime epoch；PID复用或代际变化必须返回conflict而不是杀错进程；
- foreground runtime继续由supervisor语义处理，不进入内部handoff。

### 15.3 Lifecycle 输出

- stdout：一个最终 envelope/最终文本结果；
- stderr：prepare/handoff/quiesce/cutover/drain 进度；
- success 必须包含 old/new PID、build id、replacement result、是否 forced drain；
- `zero_listener_gap=true` 只在 exact FD handoff 成功时输出；
- old crash 或 forced connection close 时不得输出 full continuity。

### 15.4 建议错误码

| Code | 含义 | 下一步 |
| --- | --- | --- |
| `REPLACE_IN_PROGRESS` | candidate/drain 已存在 | `zc status`，等待或显式 stop |
| `REPLACE_SUPERVISED` | foreground/supervisor-owned | 使用 supervisor rolling restart |
| `REPLACE_PROTOCOL_MISMATCH` | old/new handoff version 不同 | 显式 cold upgrade |
| `REPLACE_LISTENER_INCOMPATIBLE` | listener 指纹变化 | `zc restart` |
| `REPLACE_CANDIDATE_FAILED` | cutover 前 candidate 失败 | 修复配置/二进制后重试；old 仍 active |
| `REPLACE_FAILED_ROLLED_BACK` | cutover 后失败且已恢复 old | 检查日志后重试 |
| `REPLACE_ROLLBACK_FAILED` | old 未能恢复 | 立即 `zc status`，按输出 identity处理 |
| `REPLACE_DRAIN_FORCED` | deadline 到期仍有连接 | 检查连接类型/时长；replacement 已完成 |
| `INSTALL_HANDOFF_UNSUPPORTED` | 当前 running daemon 无协议能力 | stop 后 cold install |
| `INSTALL_POINTER_MISMATCH` | runtime active 与 symlink不一致 | 不清理任何版本，按 identity修复 |

### 15.5 日志与指标

每次 transaction 统一带：

- transaction nonce、runtime epoch；
- old/new pid、nonce、build id；
- phase 和 phase latency；
- listener fingerprints；
- quiesce pause；
- connection counts by kind；
- drain duration、forced count；
- rollback phase/reason；
- installer pointer before/after identity。

不得记录 bearer secret、proxy credential、prepared config body或完整敏感路径参数。

---

## 16. 故障矩阵

| 注入点 | 必须观察到的结果 |
| --- | --- |
| Candidate config parse/capability fail | old PID/nonce/traffic不变；无 listener/descriptor publication |
| Candidate OOM during generation prepare | old 不变；candidate无资源泄漏 |
| Unix peer auth fail | 不发送任何 FD；old 不变 |
| Ancillary truncated/extra/missing FD | candidate关闭全部已收 FD；old 不变 |
| Received listener role/address/type不匹配 | candidate拒绝；old 不变 |
| Lock inode/FD验证失败 | candidate拒绝；第三进程仍无法获取 lock |
| Candidate acceptor spawn fail | old尚未 quiesce；直接 abort |
| Old control quiesce timeout | old恢复control；candidate abort |
| Old acceptor quiesce timeout | old resume；不做 active CAS |
| Runtime CAS conflict | old resume；candidate abort；不得覆盖第三状态 |
| Candidate activate/ACK timeout | 反向 CAS，old resume |
| Final desired reconcile conflict | rollback；selection authority不倒退 |
| Candidate status/stability fail | rollback；installer symlink仍old；candidate可控时reverse-drain其已接收连接 |
| Symlink rename/fsync fail | runtime rollback；保留所有 version |
| Installer SIGTERM/SIGKILL | old/new按pointer identity和deadline收敛；不删除被引用binary |
| Candidate crash before finalize | old自动恢复accept，runtime active回old |
| Old crash before finalize | candidate继续服务新连接，但结果标记continuity degraded |
| Drain deadline | active candidate不受影响；old forced count可见并退出 |
| Old retire CAS撞上新state | 只重试/报告，绝不删除active candidate |
| 第二个 reload/upgrade | `REPLACE_IN_PROGRESS`，不创建第二candidate |

---

## 17. 测试与证据策略

### 17.1 Task 0 平台 spike（先于产品重构）

在 Linux/macOS 真实进程测试以下不变量：

1. `SCM_RIGHTS` 传递 listening socket 后，receiver 能从同一 accept queue 接收连接；
2. sender quiesce但不close时，receiver accept无重新bind；
3. 传递 flock FD 后 sender close，receiver仍维持lock，第三进程 acquisition失败；
4. receiver close后、sender仍持有时 lock不释放；最后一个duplicate关闭后才释放；
5. wrong/truncated ancillary data被完整关闭，无FD leak；
6. macOS codesigned candidate通过同样路径。

任一 release target失败则停止本方案实现，重新评估永久 socket owner；不得边做边增加
`SO_REUSEPORT` fallback。

### 17.2 Unit tests

- `RuntimeState` canonical encode/decode、schema严格字段、CAS/epoch overflow、非法phase；
- replacement 状态转换表的所有合法/非法边；
- `ListenerFingerprint` canonicalization 和 exact-set diff；
- adopted FD验证：非socket、connected socket、UDP、not-listening、wrong address、duplicate role；
- `ConnectionRegistry` admission上界、drain拒绝新lease、最后release唤醒、deadline；
- lease lifetime与FailingAllocator每个allocation seam，无partial owner；
- handoff frame长度、protocol version、nonce、FD count、peer mismatch；
- pointer identity比较，不用路径字符串冒充inode匹配；
- old retire只删除matching draining nonce；
- selection CAS在cutover冲突后重试到new active。

### 17.3 Process integration tests

所有测试使用隔离 HOME/XDG_RUNTIME_DIR 和显式非7899端口：

1. **Continuous connect**：更新前后持续建立mixed SOCKS和HTTP连接，failure count=0；
2. **Long-lived TCP**：更新前建立CONNECT tunnel，cutover后继续双向传输；关闭后old退出；
3. **UDP association**：更新前建立SOCKS5 UDP association，cutover后仍round-trip；新association由new处理；
4. **Controller ownership**：old quiesce后mutation被拒，new ready后selection成功且generation单调；
5. **Config exactness**：new connections使用candidate规则，old connections保持old处理上下文；
6. **Rollback faults**：故障矩阵每个pre-finalize注入点证明old PID/traffic恢复；
7. **Kill matrix**：在每个phase SIGKILL old/candidate/coordinator，状态最终可解释且无双active；
8. **Drain deadline**：持有连接超过测试deadline，old forced退出并报告exact count；
9. **No stacking**：drain中第二次replace fail closed；
10. **Lock exclusion**：replacement全程第三个`zc start`不能成功；
11. **Prepared cleanup**：candidate abort、rollback、retire后只保留仍被引用snapshot；
12. **Build identity**：A/B两个test build证明cutover后status和新连接来自B，old connection仍在A。

### 17.4 Installer tests

扩展现有 `scripts/install/test-oneline-installer.sh` 与 regression：

- stopped first install/versioned symlink；
- running handoff success；
- candidate self-check/checksum/codesign fail；
- symlink publication race；
- signal at每个install phase；
- active/pointer identity mismatch fail closed；
- rollback保留old版本；
- drain前GC拒绝、retire后GC；
- legacy running daemon返回unsupported而非cold fallback；
- custom install dir和空格路径；
- Linux static binary、macOS Mach-O四平台资产不回归。

### 17.5 Scenario / soak / chaos

新增真实而非simulated入口，例如：

```text
scripts/reliability/run-hot-upgrade.sh
```

场景：

- 100轮same-binary reload，16个持续clients；
- 20轮A↔B binary handoff；
- 每轮随机phase fault/kill；
- 记录connect failure、reset、cutover pause、drain、FD/thread/process count；
- 最终无old process、无prepared/request/socket leak、lock可重新获取；
- 缺少平台工具/网络能力是error，不是skip/pass。

### 17.6 性能门禁

先记录main baseline，再设阈值，不凭空发明数字：

- 稳态每connection新增一次registry acquire/release的CPU成本；
- connect throughput和p50/p95/p99 latency；
- cutover pause distribution；
- candidate准备时间、memory peak；
- drain期间old+new总memory和FD；
- 100轮后resource slope必须为0。

硬正确性门禁可以立即固定：connect failure=0、unexpected reset=0、双active=0、leak=0。
性能阈值在Task 0取得至少30个baseline sample后写回本计划，再开始相关hot-path改动。

---

## 18. 分阶段任务

每个任务先新增会失败的测试，确认red，再实现green。除Task 0 spike外，一个任务一个Conventional
Commit；实现分支最终按仓库规范squash + fast-forward集成。

### Task 0 — 冻结契约与平台能力 spike

**范围：** 测试/研究，不改默认daemon行为。

- [ ] 写真实process fixture验证SCM_RIGHTS listener + flock FD语义；
- [ ] Linux/macOS都运行；
- [ ] 记录baseline connect/perf/resource样本；
- [ ] 冻结listener fingerprint字段和protocol v1 bounded layout；
- [ ] 把验证结果写入`.agents/` evidence note。

**Acceptance：**

- [ ] sender/receiver handoff期间连续connect failure=0；
- [ ] 第三进程全程无法取得lock；
- [ ] 最后一个lock FD关闭后能重新acquire；
- [ ] malformed ancillary tests无FD leak；
- [ ] 四release targets至少由CI matrix覆盖编译，Linux/macOS各有真实运行证据。

**Commit：** `test(runtime): prove listener and lock fd handoff`

### Task 1 — RuntimeState v3 单一authority

- [ ] 先写schema/CAS/concurrency tests；
- [ ] 引入active/replacement/draining/runtime_epoch；
- [ ] selection字段改为`selection_generation`；
- [ ] stop/status/start只从runtime state取active PID；
- [ ] 删除pid file读写与旧descriptor schema，不保留dual authority；
- [ ] 保持现有cold start/stop/restart端到端可用。

**Acceptance：**

- [ ] `zig build test -Dcpu=baseline`；
- [ ] 并发CAS只提交一个winner；
- [ ] lock-held missing/corrupt state fail closed；
- [ ] start/status/stop process tests通过；
- [ ] 仓库active docs/test不再引用pid file。

**Commit：** `refactor(runtime): make runtime state the sole daemon authority`

### Task 2 — ConnectionRegistry 与worker lifetime

- [ ] 先写lease/drain/OOM tests；
- [ ] 统一mixed/API/SOCKS/HTTP计数与上界；
- [ ] plain HTTP改为bounded connection task；
- [ ] 确保registry归零后无generation borrow；
- [ ] 默认行为仍是cold lifecycle，不接handoff。

**Acceptance：**

- [ ] TCP 128、UDP 64边界exact/max+1不变；
- [ ] drain后新acquire全部失败；
- [ ] 最后lease释放唤醒waiter；
- [ ] HTTP/SOCKS/mixed/API真实并发tests通过；
- [ ] ThreadSanitizer不可用时用高迭代race test补证据，不宣称TSAN覆盖。

**Commit：** `refactor(runtime): unify connection lifetime tracking`

### Task 3 — ListenerSet fresh adapter + 可取消accept

- [ ] 先写listener ownership/quiesce tests；
- [ ] bind从protocol模块移入ListenerSet；
- [ ] acceptor改poll+notifier并可join；
- [ ] protocol模块只处理accepted connection；
- [ ] fatal listener event回到generation owner；
- [ ] cold start/restart行为不变。

**Acceptance：**

- [ ] quiesce在deadline内停止acceptor且listener FD仍open；
- [ ] resume/重新serve后queued connection可接收；
- [ ] 不存在foreign-thread close阻塞accept路径；
- [ ] `zig build test`和现有`zig build e2e`相关listener场景通过。

**Commit：** `refactor(runtime): centralize listener ownership`

### Task 4 — 正常unwind与graceful drain foundation

- [ ] `runProxy`改为generation owner event loop；
- [ ] listener threads不再process-lifetime detached；
- [ ] API owner可在registry归零后正常deinit；
- [ ] internal retire走quiesce→drain→normal return；
- [ ] explicit stop语义单独保持清晰，不与replacement drain混淆。

**Acceptance：**

- [ ] 既有长连接在internal retire期间继续传输；
- [ ] connection close后old process自行退出；
- [ ] deadline路径报告forced count；
- [ ] clean drain运行defers，无DebugAllocator leak；
- [ ] AnyTLS pool/UDP worker teardown不hang。

**Commit：** `feat(runtime): add bounded graceful drain`

### Task 5 — HandoffProtocol 与 transferred listener adapter

- [ ] 先写socketpair/credential/frame/FD validation tests；
- [ ] 实现owner-only request/channel；
- [ ] 实现SCM_RIGHTS listener+lock bundle；
- [ ] 实现TransferredListenerSource；
- [ ] candidate internal entry仅能由valid transaction启动；
- [ ] 不接public reload。

**Acceptance：**

- [ ] exact listener set可在第二进程adopt；
- [ ] wrong peer/version/nonce/fd全部fail closed；
- [ ] 每个失败路径关闭所有received FD；
- [ ] lock在old/candidate间无释放窗口；
- [ ] fuzz/bounded malformed frame无panic/无限loop。

**Commit：** `feat(runtime): transfer listeners between generations`

### Task 6 — ReplacementCoordinator 最小纵切面

- [ ] 先加same-binary mixed+controller process BDD；
- [ ] 实现prepare→handoff→quiesce→cutover→activate→finalize→drain；
- [ ] 实现cutover前与cutover后rollback；
- [ ] 复用prepared config/startup readiness/final desired guard；
- [ ] 限制一个candidate+一个draining；
- [ ] 暂不改installer。

**Acceptance：**

- [ ] continuous connect failure=0；
- [ ] old long-lived TCP/UDP跨cutover可用；
- [ ] new connection使用candidate config；
- [ ] 每个pre-finalizefault恢复old active；
- [ ] replacement期间第三`start`失败；
- [ ] drain结束只剩new PID，runtime state steady。

**Commit：** `feat(runtime): replace daemon generations gracefully`

### Task 7 — CLI reload/config apply接入

- [ ] `zc reload`调用ReplacementCoordinator；
- [ ] `config update`删除auto/fallback，默认hot；
- [ ] restart保留显式cold语义；
- [ ] foreground/listener-incompatible/in-progress错误可操作；
- [ ] text/JSON/minimal API/status统一。

**Acceptance：**

- [ ] CLI BDD覆盖help、exit code、envelope和stderr progress；
- [ ] hot失败绝不调用cold replacement；
- [ ] daemon stopped不伪报hot applied；
- [ ] selection race/status active PID tests通过；
- [ ] 更新`docs/cli/*`、`docs/reliability/e2e.md`。

**Commit：** `feat(cli): make reload a graceful generation switch`

### Task 8 — Binary build identity 与versioned installer

- [ ] 增加compile-time build id和self executable identity；
- [ ] installer使用immutable version directory+managed symlink；
- [ ] stopped install先完成；
- [ ] running install调用candidate handoff；
- [ ] pointer commit/finalize/rollback/GC；
- [ ] legacy running daemonfail closed，不cold fallback。

**Acceptance：**

- [ ] A→B升级期间continuous connect failure=0；
- [ ] old连接继续由A处理，新连接/status为B；
- [ ] symlink failure恢复A runtime和pointer；
- [ ] signal matrix不删引用中的version；
- [ ] installer全regression、one-line E2E、四平台asset gate通过；
- [ ] 更新`docs/install/README.md`。

**Commit：** `feat(install): hand off running daemons across versions`

### Task 9 — Kill matrix、chaos、soak与性能门禁

- [ ] 实现真实hot-upgrade reliability scenario；
- [ ] old/candidate/coordinator每phase kill；
- [ ] 100轮reload与A/B轮换；
- [ ] FD/thread/process/memory slope；
- [ ] 把Task 0阈值接入gate；
- [ ] 纳入full validation/release gate，缺能力fail closed。

**Acceptance：**

- [ ] correctness/contract/interop/reliability全部green；
- [ ] 100轮connect failure/reset/double-active/leak均为0；
- [ ] cutover pause满足已冻结阈值；
- [ ] steady-state性能不越门禁；
- [ ] release docs明确平台、drain和不兼容listener限制。

**Commit：** `test(runtime): gate graceful upgrades under faults and load`

---

## 19. 预计文件变化

### 新增

```text
src/runtime_generation.zig
src/runtime_generation_test.zig
src/listener_set.zig
src/listener_set_test.zig
src/connection_registry.zig
src/connection_registry_test.zig
src/handoff_protocol.zig
src/handoff_protocol_test.zig
src/replacement_coordinator.zig
src/replacement_coordinator_test.zig
scripts/reliability/run-hot-upgrade.sh
```

文件是否拆分test按现有build/test组织最终决定；模块seam不应因文件数量反向变浅。

### 主要修改

```text
src/main.zig
src/daemon.zig
src/runtime_descriptor.zig        # 直接替换为唯一RuntimeState authority，文件名可随后重命名
src/runtime_dir.zig
src/compat.zig
src/proxy/mixed.zig
src/proxy/http.zig
src/proxy/socks5.zig
src/proxy/socks5_udp.zig
src/api/server.zig
src/proxy/outbound/manager.zig    # 仅处理必要lifetime/selection seam
install.sh
scripts/install/local-dev-install.sh
scripts/install/*regression*.sh
build.zig
```

### 用户可感知后必须同步

```text
docs/install/README.md
docs/cli/spec.md
docs/cli/ux-workflow.md
docs/reliability/e2e.md
docs/roadmap/v1.0.md              # 若仍描述旧reload语义则更新
README.md                         # 仅更新公开命令/保证，不复制内部设计
CHANGELOG.md
```

---

## 20. 风险与对应控制

| 风险 | 控制 |
| --- | --- |
| 多线程daemon内fork不安全 | Candidate由CLI/installer在独立进程路径启动；old不在fork child里分配/执行复杂代码 |
| SCM_RIGHTS平台差异 | Task 0真实Linux/macOS spike；exact protocol；无fallback |
| Shared flock误unlock | 只duplicate/close，从不调用unlock；pair assertions+第三进程probe |
| Acceptor quiesce竞态 | poll+notifier、join ACK、fixed state machine；不foreign close |
| Registry归零后worker仍借用manager | Lease release强制为最后generation access；专门lifetime tests |
| Old API在cutover后写selection | 先control quiesce+selection lock，mutation CAS active nonce/epoch |
| Candidate已active但install pointer未切 | finalization window由transaction表达；pointer identity决定恢复 |
| 长连接让old常驻 | 15分钟bounded drain；拒绝stacking；status和forced count |
| 双进程memory峰值 | 最多active+candidate/draining各一；记录peak并设gate |
| Listener option未来变化 | 指纹不等即拒绝hot；不偷偷沿用旧option并声称已更新 |
| Homebrew清理old Cellar | 不纳入MVP保证；保持cold docs直到有独立adapter证据 |
| 旧版本首次无法handoff | 明确一次cold bootstrap；不自动stop/start |
| Runtime state过度复杂 | 单ReplacementCoordinator写状态；其他caller只能用小接口；状态转换表可执行测试 |

---

## 21. 总体验收标准

全部满足才可以对外称“无缝更新”：

1. 同listener指纹的reload/binary upgrade全程没有socket close/rebind空窗。
2. 规定负载下continuous TCP connect failure与unexpected reset均为0。
3. 更新前建立的HTTP CONNECT、SOCKS5 TCP和UDP association在drain deadline内继续工作。
4. 更新后新连接只由candidate处理，并能从status/build id/config行为证明。
5. Candidate在finalize前任一故障都保持或恢复old active；失败命令不输出成功；可控rollback会
   reverse-drain candidate 已接收连接，进程crash则明确标记continuity degraded。
6. 任意时刻最多一个active、一个candidate、一个draining；第二replacement fail closed。
7. Daemon lock在handoff全程不释放，第三start不能成功。
8. RuntimeState是唯一PID/phase authority；无pid file双写、无全局进程收养。
9. Installer不覆盖运行inode；active runtime与current symlink identity一致后才finalize。
10. Old drain完成后进程、FD、thread、prepared snapshot、request/socket和旧版本均按引用精确清理。
11. 100轮fault/load soak无资源增长、无双active、无不可解释state。
12. Linux/macOS amd64/arm64构建通过，Linux/macOS至少各有真实handoff运行证据。
13. steady-state与cutover性能不越Task 0冻结的门禁。
14. CLI/minimal API/docs对active/replacing/draining、deadline和不兼容listener限制描述一致。
15. `zc reload`/hot apply从不静默fallback为cold restart。

---

## 22. 实施前最后检查

开始Task 1前必须确认：

- [ ] Task 0四项核心FD/lock不变量已有真实证据；
- [ ] 性能baseline和场景负载已冻结；
- [ ] protocol v1、listener fingerprint、15分钟drain policy已评审；
- [ ] 接受删除pid file和`auto/restart_fallback`旧路径；
- [ ] 接受首个handoff-capable版本需要一次cold bootstrap；
- [ ] standalone为MVP，Homebrew不宣称无缝；
- [ ] 每个任务按red→green、小commit、可回滚执行。

未满足这些条件时，不进入产品代码修改。
