# zc 无缝升级一手资料与代码事实

> **状态：** Research note
> **创建日期：** 2026-08-17
> **用途：** 为 `.agents/hot-upgrade-plan.md` 提供事实依据；不等同于最终设计决策
> **基线：** `main@24a15d2`

## 1. 研究范围

本笔记只记录三类内容：

1. 当前 zc 源码已经存在的行为和约束；
2. 上游产品或操作系统官方文档明确描述的机制；
3. 从前两类事实推导出的设计结论。

第三类会明确标记为“设计推论”，避免把建议写成已经实现的事实。

## 2. zc 当前源码事实

### 2.1 Reload 目前不是 hot reload

- `src/daemon.zig` 的 `reloadDaemon()` 直接返回 `error.HotReloadUnsupported`。
- `src/main.zig` 的 `reloadOrRestartPrepared()` 在 `.auto` 下捕获 reload 错误，然后调用
  `replaceRunningDaemonWithPrepared()`。
- `replaceRunningDaemonWithPrepared()` 最终调用 `daemon.replaceDaemonWithRollback()`。
- `src/daemon.zig` 的 `replaceDaemonWithOps()` 先调用 old `stop`，再调用 target `start`；启动失败
  才尝试重新启动 old。

**结论：** 当前 reload 可以在 candidate preparation 失败时保住 old，但正常替换仍是 stop-first，
不是 old/new overlap。

### 2.2 Listener 不能在两个 active 进程中重新 bind

以下入口都在自己的 accept loop 内调用 `compat.net.listenReuseAddr()`：

- `src/proxy/mixed.zig::startWithReady()`；
- `src/proxy/http.zig::startWithReady()`；
- `src/proxy/socks5.zig::startWithReady()`；
- `src/api/server.zig::startWithAcceptGate()`。

`src/compat.zig::listenReuseAddr()`：

- 创建 IPv4 TCP socket；
- 只设置 `SO_REUSEADDR`；
- 明确不设置 `SO_REUSEPORT`；
- 第二个 active listener bind 同一地址时返回 `error.AddressInUse`；
- listener 创建后设置 CLOEXEC。

源码注释明确说明该选择是为了允许 restart 后越过 TIME_WAIT，同时避免 macOS 上两个 daemon
静默共享同一端口。

**结论：** Candidate 不能通过普通 bind 在 old 仍 active 时接管同一端口；要么共享 old 的
listener FD，要么改变现有端口排他语义。

### 2.3 当前没有统一 graceful drain

- `src/main.zig::runProxy()` 在观察到 stop request 后调用 `std.process.exit()`。
- `std.process.exit()` 不运行当前栈上的 defers。
- Listener thread 与多数 connection thread 使用 `detach()`。
- `ApiServerOwner` 注释明确说明 transfer 到 process lifetime 后，当前唯一回收点是 process exit。
- mixed 有局部 `ConnectionLimiter`，记录 TCP active 与 UDP association active；API 有自己的
  `active_connections`；plain SOCKS/HTTP 没有共享 runtime-level registry。
- plain HTTP listener 在 accept loop 线程同步调用 `handleConnection()`，长 CONNECT 会占用该
  listener thread。

**结论：** 当前 runtime 不知道所有被借用的 Config/Engine/OutboundManager 生命周期何时结束，
也不能先停止 accept、再等待全部 connection worker 归零后正常 deinit。

### 2.4 已有可复用的 replacement 基础

当前代码已经有：

- authenticated immutable prepared config snapshot：`publishPreparedConfig()` /
  `readPreparedConfig()`；
- daemon lock FD 继承和 canonical lock inode 校验：`adoptInheritedDaemonLock()` /
  `validateInheritedDaemonLockIdentity()`；
- startup nonce、ready=false reservation、listener readiness、ready promotion；
- runtime descriptor atomic file publication与expected nonce/state CAS；
- owner-only canonical runtime directory；
- per-instance stop request；
- desired selection generation、selection barrier、final desired guard；
- restart preparation 在停止 old 前完成，candidate preparation 失败不会先中断 old。

**结论：** 无缝替换不需要重写配置authority或selection模型，但需要扩展runtime state以表达
active/candidate/draining，并把listener/connection ownership提到统一模块。

### 2.5 Runtime authority 当前由多份文件共同表达

- `zc.pid` 记录一个 PID；
- `zc.lock` 表示 daemon 集合是否存活；
- `zc.daemon.json` 记录 PID、nonce、ready、endpoint、identity、selection generation 和 invocation；
- status/stop/start在不同路径同时检查这些信息；
- descriptor schema v2只允许一个实例。

**结论：** old/new合法重叠后，单PID文件无法完整表达状态。继续双写PID和descriptor会增加
切换/清理竞态；计划应选择一个唯一authority。

### 2.6 Installer 当前主动拒绝运行中替换

`install.sh` 与 `scripts/install/local-dev-install.sh`：

- 当前target必须是regular file，symlink被拒绝；
- publication前后检查status和executable identity；
- 只要存在执行目标logical/physical path的进程就拒绝替换；
- 使用同目录临时文件、backup和atomic rename；
- publication/self-check失败恢复old target。

`docs/install/README.md` 明确要求 standalone/Homebrew 升级前先stop daemon。

**结论：** 当前installer的fail-closed行为是为了避免“old inode仍运行、新CLI已发布”的状态。
若要支持running upgrade，应先引入不可变版本路径和runtime handoff，不能只删除这些检查。

## 3. 成熟产品官方机制

### 3.1 NGINX on-the-fly executable upgrade

NGINX 官方控制文档描述：

1. 先把新 executable 放到旧路径；
2. 给 old master 发送 `USR2`；
3. old master 重命名 PID 文件并启动 new executable；
4. old/new workers 会同时继续接受请求；
5. 给 old master 发送 `WINCH`，让 old workers graceful shutdown；
6. old master暂时保留listen sockets，因此new版本不可接受时可重新启动old workers；
7. 成功后再给old master发送`QUIT`完成退出。

官方文档：<https://nginx.org/en/docs/control.html#upgrade>

**一手资料结论：** NGINX 的binary upgrade不是原地exec，也不是先杀old；它让old/new重叠，
保留listener和rollback窗口，再drain old workers。

### 3.2 Envoy hot restart

Envoy 官方文档描述：

- new process先完整初始化，包括configuration、service discovery和health checks；
- old/new通过Unix domain socket RPC通信；
- new向old请求listener socket copies；
- new开始监听后通知old进入drain；
- existing connections不会迁移到new process，而是在old process内完成或在deadline后终止；
- parent shutdown deadline应大于drain deadline；
- listener socket options不能在该hot restart中任意改变，部分变化需要full restart；
- feature不支持Windows。

官方文档：
<https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/hot_restart>

**一手资料结论：** Envoy把“新连接接管”和“旧连接完成”分离。其无缝含义是listener handoff +
old drain，而不是连接状态迁移。

### 3.3 systemd socket activation

systemd官方文档说明：

- `.socket` unit独立创建并持有listening socket；
- matching `.service` 启动时由service manager传入socket FD；
- daemon通过socket activation接口发现收到的FD；
- socket lifetime不必与单次service process lifetime相同。

官方文档：

- <https://www.freedesktop.org/software/systemd/man/latest/systemd.socket.html>
- <https://www.freedesktop.org/software/systemd/man/latest/sd_listen_fds.html>

**一手资料结论：** 把listener ownership放到worker之外可以避免restart时销毁accept queue。

**限制性推论：** systemd socket activation本身只保住listening socket/queued connections；如果
直接杀掉old service，old已接受的connections仍会断。因此zc若使用该adapter，仍需要old worker
drain或rolling worker overlap。

## 4. 操作系统FD与lock事实

### 4.1 Linux `SCM_RIGHTS`

Linux `unix(7)` 说明，`SCM_RIGHTS` 传递的不是简单数字，而是在receiver进程中安装一个引用同一
open file description的新file descriptor；语义上类似把FD duplicate到另一个进程。

来源：<https://man7.org/linux/man-pages/man7/unix.7.html>

### 4.2 Linux `flock`

Linux `flock(2)` 说明，`flock` lock关联open file table entry/open file description；由`fork`或
`dup`产生的duplicate引用同一lock，任意这些FD都可用于修改lock，只有全部相关FD关闭或明确
unlock后lock才释放。

来源：<https://man7.org/linux/man-pages/man2/flock.2.html>

### 4.3 macOS

Apple/BSD man pages提供Unix-domain ancillary message和`flock`接口；但跨版本zc所需的
“SCM_RIGHTS received duplicate维持同一flock”组合必须在真实macOS进程测试中确认，不能仅
用Linux文档外推。

参考：

- <https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/sendmsg.2.html>
- <https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/recvmsg.2.html>
- <https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/flock.2.html>

### 4.4 Zig 0.16.0 本地标准库

当前本机Zig 0.16.0的`std.Io.File.lock/tryLock`在POSIX Threaded adapter中调用
`posix.system.flock`：

- `std/Io/File.zig` 定义高层接口；
- `std/Io/Threaded.zig::fileLock/fileTryLock/fileUnlock` 使用 `LOCK.EX/SH/UN`。

该事实说明当前zc daemon lock在目标平台走`flock`语义，但实现仍必须有真实process contract
test，避免把本机standard-library实现当成所有release target的永久保证。

## 5. 设计推论

以下均是设计选择，不是当前实现事实：

1. **共享listener FD优于重新bind。** 它保留同一socket和accept queue，也维持当前端口排他性。
2. **同一个flock FD应被duplicate/transfer而不是unlock/relock。** 这样没有第三进程抢占窗口；
   代码必须禁止任一共享者显式unlock。
3. **Candidate必须先完整prepare再quiesce old。** 这把大多数失败留在old仍正常服务的阶段。
4. **Old必须在finalize前保留listener FD。** Candidate失败时old才能resume accept而不用rebind。
5. **Accepted connection不迁移。** Old connection worker持有old generation，candidate只处理new。
6. **Listener option/endpoint变化必须拒绝hot path。** 共享旧FD意味着旧socket属性仍生效；声称新
   option已应用会是假成功。
7. **需要统一connection lifetime barrier。** 只有acceptor已join且registry归零后，old才可安全
   deinit Config/Engine/Manager。
8. **需要单一runtime authority。** Active/candidate/draining和CAS epoch应在一个原子state中，
   不再依赖单PID文件表达多代际。
9. **Installer应发布不可变version path并原子切pointer。** 这让old/new executable identity都可
   验证，并使runtime rollback和binary pointer rollback可以组成两阶段事务。
10. **首个支持handoff的版本仍需一次cold bootstrap。** 已发布old daemon不理解未来protocol；
    installer必须明确拒绝running fallback，而不是偷偷stop/start。

## 6. 研究结论

官方模式与zc代码约束共同指向同一方案：

```text
candidate full prepare
→ transfer exact listener + lock FD
→ old quiesce accept/control
→ atomic active authority cutover
→ candidate accept/readiness
→ finalize
→ old drain accepted connections
```

实现风险主要不在download/rename，而在：

- listener ownership从protocol线程上移；
- acceptor确定性quiesce；
- connection lifetime和normal unwind；
- selection/control mutation只属于active代际；
- runtime state CAS和installer pointer的两阶段提交；
- Linux/macOS真实FD/lock合同测试。

详细接口、状态机、任务和验收见 `.agents/hot-upgrade-plan.md`。
