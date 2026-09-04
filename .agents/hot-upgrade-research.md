# zc 优雅二进制替换一手资料与设计依据

> **状态：** Accepted research basis
> **zc 基线：** `355262eba78455b9b1e3c7c7b0ff0365ded98459`
> **研究目标：** 运行中的zc更新为新binary时，保留listener与已有连接，失败可判定且不隐藏cold fallback
> **目标平台：** Linux / macOS，amd64 / arm64
> **对应方案：** `.agents/hot-upgrade-plan.md`

## 1. 结论

zc应采用窄化的 **NGINX/HAProxy式old→candidate process replacement**：

1. Installer先发布immutable candidate artifact，不覆盖running executable；
2. Old daemon直接spawn candidate，并把同一个listener、daemon/install locks和私有bootstrap/drain socket继承给child；
3. Candidate用old正在运行的exact prepared invocation完成cold-start等价初始化，但不accept；
4. Old确认acceptor已quiesce；
5. 原子切换selected-version pointer；
6. Candidate开始accept，old只服务已经建立的连接；
7. Old连接自然结束或到达显式drain deadline后退出。

采用该方向的原因：

- 与成熟proxy一致：candidate先完整准备、listener不rebind、established connections不迁移而是drain；
- Old本来就是candidate parent，直接spawn inheritance比命名FD broker+`SCM_RIGHTS`更小；owner-only lifecycle socket只承载begin/observe/status/stop，不传FD；
- Immutable artifact + atomic selected pointer给installer和runtime一个明确、可检查的持久决策；
- Candidate失败发生在old仍accept时，不需要先停止服务再赌new能启动；
- 不依赖Linux-only systemd，也不要求macOS用户安装launchd plist。

这不是“永不出错”的绝对保证。它不能覆盖host crash、kernel/OOM kill、backlog耗尽、外部`SIGKILL`或
磁盘损坏；它能把正常upgrade协议内的失败变成明确的precommit abort或postcommit forward recovery。

---

## 2. 当前zc事实

### 2.1 Standalone installer安全，但拒绝running replacement

`install.sh`当前已经具备：

- GitHub Release immutable tag解析；
- archive SHA-256验证（当前release只发布archive checksum，不是executable digest）；
- binary size、regular-file、version self-check；
- install lock；
- same-directory staging与atomic rename；
- publish失败时恢复旧binary。

但它会调用旧binary的`status --json`并扫描executable identity；只要target仍被进程执行，就直接拒绝
replace。最终layout是单个`${ZC_INSTALL_DIR}/zc` regular file，也明确拒绝symlink target。

**结论：** 下载与artifact验证可复用；single-file publication必须替换为immutable versions + selected
pointer，running拒绝必须替换为显式handoff，而不是删除安全检查。

### 2.2 `just install`是cold transaction

`Justfile::install`当前流程为：

```text
build
→ verify old runtime/identity
→ copy old binary backup
→ zc stop
→ replace target
→ zc start
→ verify new PID and executable inode
→ failure: restore old binary and attempt old start
```

它能避免“新CLI已安装、old inode仍running”的假成功，也能处理new startup failure，但stop-first必然关闭
现有连接并产生listener空窗。

### 2.3 Runtime尚不具备process handoff seam

- Mixed listener在`src/proxy/mixed.zig::startWithReady`内部bind，accept loop blocking；
- API listener在`src/api/server.zig::startWithReady`内部bind；
- Main把listener threads和connection workers detach；
- Worker直接借用Config、Engine和`*OutboundManager`；
- Stop request最终`std.process.exit()`，没有connection drain；
- `zc.pid`、daemon lock和runtime descriptor都按单active process设计；
- Mixed limiter当前是每process TCP 128 / UDP 64；
- Prepared snapshot load仍可能补做provider preparation，不是完全self-contained。

**结论：** Listener ownership、accept quiesce、connection registry、child bootstrap和runtime authority是
binary replacement前置条件。进程内Config generation swap不能替代这些工作。

---

## 3. 成熟方案对照

### 3.1 NGINX：parent exec new binary，old master保留回退能力

官方binary upgrade流程：替换executable后向old master发送`USR2`；old master重命名PID文件并启动new
executable。Old master不关闭listen sockets；若new不可接受，可让old重新启动workers并关闭new；成功后
再`QUIT` old master。

- 官方流程：<https://nginx.org/en/docs/control.html#upgrade>
- 固定源码：NGINX `release-1.28.0`，commit
  [`481d28cb4e04c8096b9b6134856891dc52ecc68f`](https://github.com/nginx/nginx/tree/481d28cb4e04c8096b9b6134856891dc52ecc68f)
- `ngx_exec_new_binary()`把listener FD numbers写入`NGINX`环境并exec new binary：
  [`src/core/nginx.c`](https://github.com/nginx/nginx/blob/481d28cb4e04c8096b9b6134856891dc52ecc68f/src/core/nginx.c)
- New binary解析这些numbers并调用`ngx_set_inherited_sockets()`恢复listener metadata：同上文件
- New child退出时old master恢复PID文件并可restart old workers：
  [`src/os/unix/ngx_process_cycle.c`](https://github.com/nginx/nginx/blob/481d28cb4e04c8096b9b6134856891dc52ecc68f/src/os/unix/ngx_process_cycle.c)

**zc采用：** parent直接spawn、exact listener inheritance、old connections留在old、old保留precommit
recovery能力。

**zc不照搬：** NGINX流程主要由operator用signals推进，缺少machine-verifiable readiness ACK。zc自动化
installer必须增加private`ARMED/ACTIVATE/ACTIVE`handshake、deadline和identity verification。

### 3.2 HAProxy：完整启动new，再soft-stop old；可取回old listeners

HAProxy 3.2 management guide说明：

- `-x <unix_socket>`从old process取回listening sockets并复用，而不是重新bind；master-worker mode通过
  internal socketpair自动使用该能力；
- `-sf`在new boot completion后向old发送`SIGUSR1`；old停止listen但继续处理existing connections；
- 普通pause/rebind路径在高负载下仍可能出现毫秒级失败窗口，说明“graceful”不能等同于任意rebind都无损；
- `hard-stop-after`为soft-stop提供最大存活时间，避免TCP长连接让old process永久残留。

固定资料：HAProxy `v3.2.0`，commit
[`e134140d282c006417945d78e7964cc8fa14586a`](https://github.com/haproxy/haproxy/tree/e134140d282c006417945d78e7964cc8fa14586a)：

- [`doc/management.txt`](https://github.com/haproxy/haproxy/blob/e134140d282c006417945d78e7964cc8fa14586a/doc/management.txt)
- [`doc/configuration.txt`](https://github.com/haproxy/haproxy/blob/e134140d282c006417945d78e7964cc8fa14586a/doc/configuration.txt)

**zc采用：** fully prepared candidate、复用exact listener、old soft drain、显式hard deadline。

**zc不照搬：** Old就是candidate的parent，因此不需要对任意peer开放stats socket或通用`SCM_RIGHTS`
retrieval interface；也不使用HAProxy普通rebind fallback。

### 3.3 Envoy：full initialization、compatibility version和bounded drain

Envoy hot restart官方说明：

- New process先完成configuration、initial service discovery和health checking；
- New从old取得listen sockets并开始listen，然后让old drain；
- Existing connections不传给new，只能在old完成或deadline后关闭；
- `--drain-time-s`与`--parent-shutdown-time-s`分别控制drain和parent shutdown；
- `--hot-restart-version`输出opaque compatibility version，供new/old在handoff前比较；
- Hot restart不支持修改listener socket options，仍使用old socket options。

固定资料：Envoy `v1.39.0`，commit
[`8eea3285d6bdb89f8ea34632cfe7ce1608a8f374`](https://github.com/envoyproxy/envoy/tree/8eea3285d6bdb89f8ea34632cfe7ce1608a8f374)：

- [`hot_restart.rst`](https://github.com/envoyproxy/envoy/blob/8eea3285d6bdb89f8ea34632cfe7ce1608a8f374/docs/root/intro/arch_overview/operations/hot_restart.rst)
- 官方CLI文档：<https://www.envoyproxy.io/docs/envoy/latest/operations/cli.html#cmdoption-hot-restart-version>

**zc采用：** binary handoff protocol version、cold-start等价candidate readiness、listener option exactness、
bounded old drain。

**zc不照搬：** 不迁移stats/shared memory，不引入restart epoch family、counter merge或多代并存；同时最多
active+candidate或active+draining两代。

### 3.4 systemd / launchd：外部manager长期持有listener

Systemd socket activation由manager创建listener，并把FD duplicates交给service；`Accept=no`时传递的是
listening sockets themselves。`FlushPending=no`允许pending connections在service restart后继续处理。

固定资料：systemd `v258`，commit
[`781d9d0789379d1ea1f2ecefb804d41e9c8b6c38`](https://github.com/systemd/systemd/tree/781d9d0789379d1ea1f2ecefb804d41e9c8b6c38)：

- [`man/sd_listen_fds.xml`](https://github.com/systemd/systemd/blob/781d9d0789379d1ea1f2ecefb804d41e9c8b6c38/man/sd_listen_fds.xml)
- [`man/systemd.socket.xml`](https://github.com/systemd/systemd/blob/781d9d0789379d1ea1f2ecefb804d41e9c8b6c38/man/systemd.socket.xml)

Apple同样建议daemon通过launchd声明Sockets；launchd预注册socket/FD并在启动daemon时交给它：
<https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/BPSystemStartup/Chapters/CreatingLaunchdJobs.html>

**为什么不作为zc standalone主方案：** systemd仅Linux；launchd integration要求plist和不同lifecycle；它们能
保留listener/backlog，但普通service restart仍不能让old process继续服务established connections。它们适合作为
未来supervisor adapters，不应成为standalone update的隐式依赖。

### 3.5 POSIX child FD mapping

POSIX `posix_spawn_file_actions_adddup2()`允许parent在spawn时把指定FD映射到child FD table：
<https://pubs.opengroup.org/onlinepubs/9699919799/functions/posix_spawn_file_actions_adddup2.html>。

Linux `flock(2)`说明lock关联open file description；`fork`/`dup`得到的FD引用同一个lock，且lock跨
`execve`保留：<https://www.man7.org/linux/man-pages/man2/flock.2.html>。

这为“old直接spawn candidate，继承listener与daemon lock”提供了正确方向，但macOS语义、Zig 0.16
spawn adapter、CLOEXEC和真实lock exclusivity仍必须由四架构process contract tests证明，不能只靠文档假设。

---

## 4. 被拒绝的方案

| 方案 | 拒绝原因 |
| --- | --- |
| stop → overwrite → start | 安装可回滚，但已有连接必断且存在listener空窗；不满足目标 |
| 单进程`execve` | 用户态Config/Engine/connection state全部消失；无法drain established connections |
| `SO_REUSEPORT`启动第二listener | 不是同一个accept queue；平台与负载分配语义不同，rollback与排他性更难证明 |
| close old listener后让new rebind | 引入bind race、端口抢占与`ECONNREFUSED`窗口 |
| systemd-only socket activation | Linux-only，且单纯restart不保留old established connections |
| launchd-only lifecycle | macOS-only，改变standalone invocation与installer模型 |
| 通用`SCM_RIGHTS` handoff framework | Old直接spawn child时不需要peer discovery和通用FD transport；增加攻击面与状态 |
| 永久master/launcher process | 新增常驻故障域；当前只需upgrade时old临时担任coordinator |
| 自动cold fallback | 把连接中断伪装成成功，违背可见、可判定目标 |
| Postcommit自动切回old | Candidate可能已经接收连接；反向切换制造第二次中断与split-brain风险 |
| 传递established connection | 需要迁移协议/TLS/relay用户态状态，复杂度和收益不匹配；成熟proxy也选择old drain |

---

## 5. 可迁移的成熟不变量

1. Candidate必须在old停止admission前完成cold-start等价初始化。
2. Binary replacement必须复用同一个kernel listener，而不是兼容性rebind。
3. Established connections属于old process，不迁移。
4. Old停止accept后必须有可观测connection drain与hard deadline。
5. Listener socket options在handoff中保持old实际值；任何预期差异fail closed。
6. New/old必须在cutover前验证binary handoff compatibility。
7. 必须把precommit abort与postcommit forward recovery分开。
8. Installer、runtime和status必须能识别actual binary digest/device/inode，不能只相信version string。
9. Overlap资源峰值必须按两代process计算并设门禁。
10. 用户必须看见candidate、serving、draining、deadline与degraded结果；不能用“reload成功”掩盖cold restart。

---

## 6. 对zc方案的直接推论

- Standalone安装布局改为content-addressed immutable artifacts + atomic selected symlink；
- Selected symlink readback是唯一selection decision；parent-directory sync单独报告durable/uncertain；runtime record只是可重建projection；
- Old daemon是单次replacement coordinator，不新增永久master；owner-only lifecycle socket是installer/CLI的可达入口；
- FD transport使用private parent-child spawn manifest，不公开通用RPC；
- Old在pointer仍指向自己时可以abort/resume；pointer指向candidate后只能forward，不自动rollback；
- Candidate只加载old的exact prepared invocation，binary replacement不夹带config update；
- Archive digest只作下载provenance，解包后另算artifact digest并用于version/selected/runtime identity；
- 首个支持新layout/protocol的版本需要一次明确cold bootstrap；
- MVP支持standalone managed background + one mixed + no controller + no AnyTLS；unsupported mode在任何pointer mutation前拒绝；
- 成功返回只等待candidate ACTIVE，不等待old drain完成；status持续展示draining事实；
- 默认hard drain duration采用15分钟；pointer decision时以boot monotonic clock计算deadline；只有old terminal message存在时才记录exact forced count，否则显示unavailable/degraded。

详细状态机、接口、失败矩阵与任务见`.agents/hot-upgrade-plan.md`。
