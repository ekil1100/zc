# Linux CI：日志锁初始化与 AnyTLS 收尾

## 范围与基线

本轮从 `30667c6` 继续，目标是修复阻止 Linux 原生测试继续执行的两组失败；不合并 main、不安装生产二进制、不访问生产 7899。Linux 环境来自仓库 GitHub Actions 的 Ubuntu x64 / arm64 runner，测试运行 host GNU 二进制，musl 是后续独立交付构建目标。

- `6b6e567` 的 [CI 36917340256](https://github.com/ekil1100/zc/actions/runs/36917340256)：x64 的 API／观测测试出现日志锁创建超时和缺少启动错误文件；arm64 的 AnyTLS 取消写恢复测试在 peer 读取正文时 reset。
- `30667c6` 的 [CI 36919364582](https://github.com/ekil1100/zc/actions/runs/36919364582)：两个 Linux runner 均再次记录 AnyTLS 接收截断；原 `override_spawn` 修复不覆盖此路径。

## 日志锁初始化

修复提交 `ad291e4`。

`Evidence::start()` 的第一条日志原本直接使用 50ms 写入锁预算。新 runtime 的 `zc.log.lock` 首次创建包含文件及目录同步，可能在尝试实际加锁前耗尽期限。对锁文件同步定点增加 75ms 延迟可确定性复现；预先建锁的同条件对照通过。一个父测试先读启动错误文件、后检查子进程退出码，导致初始化错误被 ENOENT 掩盖。

启动阶段现在先按既有启动锁量级使用 1 秒初始化预算，热日志锁仍为 50ms；文件、目录同步及安全检查保留，内核阻塞 I/O 不承诺硬实时截止。子进程退出断言移到读取 startup 记录之前。

新增 `cold_log_initialization_preserves_lock_contract` 通过真实 `Evidence::start()` 和限定临时路径的 native shim 验证 11 个场景：冷启动、预建锁、初始化过期、文件／目录同步 EIO、启动／热路径真实锁竞争，以及 symlink、hardlink、非法权限拒绝。先红后绿，保持其他断言和期限。原始本机工件在 `target/observability-init/`。

## AnyTLS 正常关闭

修复提交 `83e60c0`。

原 shutdown 排空 PSH/FIN、完成 TLS 写侧 shutdown 后立即释放 socket。TLS 1.3 tickets 等未读输入可使 TCP 关闭产生 reset，对端尚未读完的已接受正文被截断。无取消写的对照也能复现；保留 socket 或读掉未读 TLS 后再关闭可消除本机样本中的失败。

修复把正常关闭与取消释放分开：从第一次 shutdown poll 起共用 5 秒总期限，最多排空 1 MiB 明文；排空上传 Pending 时也读取接收侧，避免双向背压互等。保留已组装 PSH 尾部，应用 read 随后保持 Pending，直到写侧与对端 TLS/TCP EOF 都完成才发布成功 whole-close。超时、超限和 reset 返回错误，无后台任务，取消 Drop 仍直接释放。

独立检视另发现并通过端到端红测确认：

1. tokio-rustls 0.26.5 可能在同一 poll 先读明文、再遇到 reset 时返回明文并丢掉错误；后继 TCP EOF 会被误当普通关闭。AnyTLS 专用的 TCP adapter 锁存终止性读错误，避免转换成成功 EOF；Trojan/SS 路径不变。
2. 只在写完后读取会在双方先写后读时互等。768 KiB 合法下行与背压上传的用例验证同时推进；对端先 EOF 也不能取消尚未完成的 PSH/FIN/TLS flush。

本机证据：38 项 AnyTLS 回归、39 项关联回归通过；五个重点关闭用例各 20 次通过。两个边界及提前 EOF 的 mutation 均有红绿证据。最终独立复核重跑 14 项通过，无残留 finding。工件在 `target/anytls-close-fix/`、`target/anytls-close-edge/`。

## Linux 原生验证进展

[CI 36927626114 / `83e60c0`](https://github.com/ekil1100/zc/actions/runs/36927626114)：

- x64 / arm64 的 lib 各 **20 项通过**，包括新日志锁初始化测试。
- 两平台 AnyTLS 各 **13 项通过**，包含原失败的取消写恢复与无取消立即关闭回归。
- 后续生命周期套件各 **13 passed / 6 failed**，失败表现为背压／HTTP 转发超时，其中包含既有测试。不能把前两组已通过扩大为 Linux 总门禁通过。

独立诊断分支 `ci/linux-anytls-diagnostics` 的 [CI 36928394728](https://github.com/ekil1100/zc/actions/runs/36928394728) 对照结果：

| 条件 | 原心跳背压测试 | 双向背压关闭 | 背压关闭总期限 |
| --- | --- | --- | --- |
| 原样测试环境 | 超时 | 超时 | 超时 |
| 旧产品代码 `30667c6`，原样测试环境 | 同样超时 | 未运行 | 未运行 |
| 同样 16 KiB buffer，改在 listen 前设置 | 通过 | 通过 | 通过 |
| accept 后改设 256 KiB 接收 buffer（仅诊断） | 通过 | 通过 | 通过 |

根因在测试建连顺序：accept 后缩小 Linux 接收窗口会产生与预期不同的窗口更新行为。正式修复仅将相同的 16 KiB 收发 buffer 提前到 `TcpSocket` 的 listen 前设置，供全部生命周期 peer 共用；HTTP/HTTPS 场景的应用客户端也在 connect 前设置原来的 16 KiB 接收 buffer，本地 ingress listener 不改。Linux [tcp(7)](https://man7.org/linux/man-pages/man7/tcp.7.html) 也要求在 listen/connect 前设置 socket buffer。各变体均保留原期限、payload 与完整性断言，未采用增大 buffer 的诊断变体。修正后的本机生命周期 19 项、格式与定向 Clippy 通过；`a0cedbb` 的 [CI 36929343148](https://github.com/ekil1100/zc/actions/runs/36929343148) 中 arm64 生命周期套件改善为 18 passed / 1 failed；剩余 HTTP/HTTPS 超时来自应用客户端仍在 connect 后缩小接收 buffer，已按同一原则修正，期限与 2 MiB 响应断言保留。完整 Linux CI 待后续记录。

诊断只是定位证据，不是整个 Linux 验收通过。所有变体日志保留于 `target/linux-ci-fixes/socket-diagnostics/`。

### 日志轮转测试的 inode 复用

`2a6658e` 的 [CI 36929886457](https://github.com/ekil1100/zc/actions/runs/36929886457) 在 arm64 上完整通过 AnyTLS 生命周期 19 项；随后 `tests/daemon.rs::unsafe_runtime_paths_are_rejected_and_logs_are_bounded` 因新旧日志 inode 编号相同失败。轮转先原子替换超大日志为告警、再归档并创建新日志，原 inode 已释放，Linux 可以复用其编号；单独记录编号不足以证明文件未替换。

测试改为持有旧日志的打开句柄直到断言完成，阻止编号复用，同时新增旧文件长度保持 `8 MiB + 1` 的断言，验证采用替换而非原地截断。原 inode 差异、日志上限、0600 权限及 3 秒期限断言均保留，生产轮转逻辑不改。原始失败日志：`target/linux-ci-fixes/2a6658e-linux-arm64.log`。

### 完整套件收集与安装来源硬链接

`8918753` 开启 `just test --no-fail-fast`，保持测试集合、断言和失败退出码，一次收齐全部 Rust 套件。[CI 36930700322](https://github.com/ekil1100/zc/actions/runs/36930700322) 中 Linux x64/arm64 均通过原日志锁/API、AnyTLS 13 项、AnyTLS 生命周期 19 项及 daemon 19 项；剩余为 UDP 拒绝场景 1 项、服务安装 11 项。相关日志：`target/linux-ci-fixes/8918753-linux-{x64,arm64}.log`。工作流的 Python 契约最初仍要求裸 `just test`，已同步为完整命令，`just delivery-test` 的 70 项 Python 测试及 shell 契约通过。

服务安装通过通用严格读取器捕获 Cargo 来源，它要求 `nlink=1`。独立 [Linux 诊断 36934363820](https://github.com/ekil1100/zc/actions/runs/36934363820) 证实两平台的 `target/debug/zc` 均为当前 UID 所有、0755、`nlink=2`，与 deps 目录产物共享 inode。独立复制的单链接来源安装成功，增加硬链接后确定性失败；这同样影响实际 Cargo 本地安装入口。

修复为安装来源专用有界捕获：允许当前用户所有、稳定且至少一个链接的普通来源文件；保留 no-follow、nonblocking、256 MiB 上限、捕获前校验及前后 ctime/nlink/uid/mode/len/mtime 比较。后续独立私有候选、自检、目标与恢复保护不变，通用严格读取、cache、锁和已安装目标仍要求单链接。父会话复核全部原读取调用点继续使用严格策略。

本机红绿及回归：新增硬链接来源成功且目标独立、既有硬链接目标拒绝；fsutil 18、user_service 36、provider_cache 17、store 23 项通过，定向 Clippy、格式与 diff 检查通过。原始证据：`target/linux-ci-fixes/install-source-{red,green,target-green,fsutil,user-service,strict-read-regression,commands}.log`。Linux 修复后结果待后续记录。

### Linux UDP 错误就绪

[诊断 36934988048](https://github.com/ekil1100/zc/actions/runs/36934988048) 在两种 Linux 架构上同时取得 syscall 与 loopback 抓包：入站 11 bytes 被接收，SS 40 bytes 成功发往已关闭端口，内核立即返回 ICMP port unreachable，进程却始终未对上游 fd 调用 recv。独立 Python connected UDP 对照正常返回 `ConnectionRefused`。问题不在上游未关闭或内核不报告错误。

锁定依赖中，Shadowsocks 1.25 的通用 datagram 接口调用 Tokio `poll_recv`，Tokio 1.53.1 的轮询读路径只等待 `READABLE | READ_CLOSED`；Linux 的独立 `ERROR` 事件被遗漏。其异步 `UdpSocket::recv` 已显式包含 `Interest::ERROR`，两条路径行为不同。

修复在 SS 接收循环并行等待同一个已注册 socket 的 `Interest::ERROR`，使用 `SO_ERROR` 取得原始 I/O 错误；若错误被其他操作取走，返回 `WouldBlock` 清除旧就绪标记，避免空转。轻量共享适配器继续使用原库 codec；不增加 fd、后台 worker、轮询定时器或超时。原坏包丢弃、报文上界、64 关联上限及取消释放语义保持。

新增 session 级回归覆盖取消接收后真实 UDP 拒绝；原 observability 测试保留控制连接 EOF、一次 `ConnectionRefused`、活动数归零及隐私断言。本机 UDP/SOCKS UDP/连接观测共 54 项通过，另有 1 项原五分钟 idle 用例继续标记 ignored，定向 Clippy 通过；Linux 修复后结果待记录。诊断工件位于 `target/linux-ci-fixes/udp-syscall-diagnostics/`，本机日志为 `udp-error-readiness-local.log`。

同一完整 CI 的 macOS Intel 另暴露锁身份测试的首次 fsync 消耗 30ms 预算。仅在该夹具获取锁前持久创建空锁文件，保留原 30ms 加锁期限、替换后身份拒绝及 dirfd 路径替换断言；本机原用例通过。

## 验证边界

- 格式、严格 Clippy、本机定向回归及独立 OpenSSL record-shape 检查通过。
- 固定官方 Go 两版本互操作入口本次在执行前因缓存 fixture SHA256 不匹配而拒绝；没有修改固定哈希或执行未校验候选。该门禁本轮尚无通过结论。
- Linux 完整回归及后续产物／安装测试仍待通过；macOS 系统信任授权、四平台完整验收、性能和长稳边界保持原记录。
