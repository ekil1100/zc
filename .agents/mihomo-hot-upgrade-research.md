# Mihomo Alpha 热重载与升级源码笔记

## 口径与更正

上一版把无关的 main 分支/Python 项目当成 Mihomo Go core，所得结论全部撤回。本笔记只核验 `/tmp/mihomo-core-alpha`，其 `HEAD` 为 [`dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4`](https://github.com/MetaCubeX/mihomo/commit/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4)（Alpha），以下结论均限于这个固定源码树。

## 1. 进程内配置 hot reload

**答：有，但它是同一进程内的分阶段原地更新，不是配置代际的整体原子交换。**

- `SIGHUP` 在主循环中重新调用 `hub.Parse`；文件启动时会重读配置路径，非空 base64/stdin 启动时则复用启动时保存的 bytes（[`main.go#L145-L168`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/main.go#L145-L168)、[`main.go#L239-L251`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/main.go#L239-L251)）。解析成功后，`hub.ApplyConfig` 重建 controller route，并以 `force=true` 调用 executor（[`hub/hub.go#L54-L105`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/hub/hub.go#L54-L105)）。
- `PUT /configs` 也完整解析后在进程内 apply；只有 query 精确为 `force=true` 才强制更新默认 listeners，且此路径不调用 `hub.ApplyConfig`，所以不重建 external controller（[`hub/route/configs.go#L391-L440`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/hub/route/configs.go#L391-L440)）。
- executor 用 mutex 串行化 apply，但过程是 `Suspend → 依次替换 proxies/rules/DNS/listeners/providers → Running`，没有复合配置指针交换或 apply 失败回滚（[`hub/executor/executor.go#L83-L123`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/hub/executor/executor.go#L83-L123)、[`tunnel/tunnel.go#L205-L247`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/tunnel/tunnel.go#L205-L247)）。

**Listener 行为：** custom inbound 每次做 diff；配置相同则保留，变化时先 `Close` 再 `Listen`，新建失败不会恢复旧 listener（[`listener/listener.go#L627-L653`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/listener/listener.go#L627-L653)）。默认 listeners 仅在 `force=true` 时进入 `ReCreate*`，TUN 不受 `force` 限制（[`hub/executor/executor.go#L186-L212`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/hub/executor/executor.go#L186-L212)）；例如 HTTP 地址相同会保留，变化则 close-before-open（[`listener/listener.go#L107-L138`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/listener/listener.go#L107-L138)）。SIGHUP 的 external controller 重建是异步的，并同样先 `Close` 再 `Listen`，因此源码不提供同一 socket/accept queue 连续性保证（[`hub/route/server.go#L92-L99`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/hub/route/server.go#L92-L99)、[`hub/route/server.go#L162-L187`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/hub/route/server.go#L162-L187)）。

**已有连接：**不能概括为“reload 必然无中断”。普通 TCP 只在 handler 入口检查 `Suspend`，已经进入 relay 的连接不会再检查该状态（[`tunnel/tunnel.go#L502-L510`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/tunnel/tunnel.go#L502-L510)、[`tunnel/tunnel.go#L615-L624`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/tunnel/tunnel.go#L615-L624)）；标准 outbound wrapper 还让既有连接持有旧 adapter 引用（[`adapter/outbound/base.go#L356-L399`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/adapter/outbound/base.go#L356-L399)）。既有 UDP NAT entry 会复用原 sender/PacketConn，但 `Suspend` 窗口到达的每个 UDP packet 会被丢弃（[`tunnel/tunnel.go#L420-L499`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/tunnel/tunnel.go#L420-L499)）。明确例外是成功执行 `proxySetProvider.Initial` 会关闭 provider chain 命中的 tracked TCP/UDP 连接（[`adapter/provider/provider.go#L152-L176`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/adapter/provider/provider.go#L152-L176)）；listener 的 `Close` 影响也依实现而异——普通 HTTP 只关闭 accepting listener、已 accept 连接在独立 goroutine 中运行（[`listener/http/server.go#L20-L40`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/listener/http/server.go#L20-L40)、[`listener/http/server.go#L127-L149`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/listener/http/server.go#L127-L149)），TUIC/TUN 的关闭范围则更大（[`listener/tuic/server.go#L213-L228`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/listener/tuic/server.go#L213-L228)、[`listener/sing_tun/server.go#L668-L685`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/listener/sing_tun/server.go#L668-L685)）。

## 2. Restart

**答：`POST /restart` 是进程自重启，不是 graceful generation replacement。** Handler 先回复并 flush，再后台调用 `restartExecutable`；非 Windows 以 `syscall.Exec` 原位替换进程映像，Windows 启动子进程后不等待 readiness 就让父进程退出（[`hub/route/restart.go#L18-L67`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/hub/route/restart.go#L18-L67)）。重启前的 `executor.Shutdown` 只做 listener cleanup、iptables/fake-IP 状态清理；其中 listener cleanup 只关闭 TUN，没有 tracked-connection drain、controller shutdown 或等待归零（[`hub/executor/executor.go#L532-L538`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/hub/executor/executor.go#L532-L538)、[`listener/listener.go#L720-L729`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/listener/listener.go#L720-L729)）。因此源码不支持“listener 无空窗”或“已有 relay 保留”的承诺。

## 3. Binary `/upgrade`

**答：core `/upgrade` 是“下载并覆写当前 executable，然后复用 `/restart` 路径”。** 非 embed 模式的 `POST /upgrade` 同步执行 `CoreUpdater.Update`，成功回复后调用同一个 `restartExecutable`（[`hub/route/upgrade.go#L15-L53`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/hub/route/upgrade.go#L15-L53)）。更新器依次 download、unpack、backup、copy replacement（[`component/updater/update_core.go#L123-L170`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/component/updater/update_core.go#L123-L170)）；replacement 对当前路径使用 `O_TRUNC` 写入，失败时甚至删除目标再创建，不是 immutable-version + atomic pointer publication（[`component/updater/update_core.go#L417-L473`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/component/updater/update_core.go#L417-L473)）。

在该 commit 的 updater 源码中搜索产物级 `sha256/checksum`、signature verification、`rollback/restore`、`fsync/Sync` 和 new-to-current atomic `Rename` 均无实现命中；`meta-backup` 只有写入路径，没有自动恢复消费者。Darwin 路径虽会做 ad-hoc `codesign`，但失败只记 warning（[`component/updater/update_core.go#L465-L469`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/component/updater/update_core.go#L465-L469)）。这是**当前源码树的负向证据**，不否定 HTTPS 校验、仓库外发布流程或其他历史版本。连接与 listener 语义随后等同上一节的硬重启，源码没有额外 handoff/drain。

## 4. zc 风格零监听空窗的多进程 generation handoff

**答：在这个固定树中未发现。** 在含 1,022 个 tracked files 的源码树中搜索 `SCM_RIGHTS`、`UnixRights`、`ParseUnixRights`、`ExtraFiles`、`FileListener/FilePacketConn`、`LISTEN_FDS/sd_listen`、listener/socket handoff、process/worker generation、connection drain、readiness ACK 等机制均无对应实现。唯一直接 `Recvmsg` 调用以 `oob=nil` 读取普通 UDP payload，不是 FD 传递（[`common/net/packet/packet_posix.go#L18-L40`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/common/net/packet/packet_posix.go#L18-L40)）。Unix 的 `SO_REUSEPORT` 只出现在 UDP reuse helper；例如 SOCKS UDP 是先 `ListenPacket`，再对已经创建的 socket 调 helper，并未形成 TCP listener 或进程代际交接（[`common/sockopt/reuse_unix.go#L9-L21`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/common/sockopt/reuse_unix.go#L9-L21)、[`listener/socks/udp.go#L42-L56`](https://github.com/MetaCubeX/mihomo/blob/dd26c52463d8e6cbb6bc33ad9e2b4a488824e6f4/listener/socks/udp.go#L42-L56)）。这些搜索只能说明 **Alpha 该 SHA 的 tracked source tree**，不是对 Mihomo 全部历史、仓库外 wrapper 或未 vendored 依赖的证明。

## 与当前 zc Proposed 计划对照

当前[`hot-upgrade-plan.md`](./hot-upgrade-plan.md)已重新聚焦于**优雅binary replacement**，仍是
Proposed而非现有行为：

| 维度 | Mihomo Alpha 该SHA | zc Proposed |
| --- | --- | --- |
| binary artifact | 覆写当前executable | immutable content-addressed versions + atomic selected pointer |
| candidate readiness | 更新后直接走restart/exec | old仍服务时spawn candidate，完成cold-start等价初始化并发送`ARMED` |
| listener | restart路径没有handoff | candidate继承old同一个listener/open file description，不rebind |
| 新连接cutover | process image替换/parent退出 | old acceptor quiesce后selected commit，candidate才`ACTIVE` |
| 已有连接 | restart无tracked drain | old process继续服务existing TCP/UDP，显式15分钟deadline |
| failure | 没有完整自动恢复合同 | precommit保old；postcommit只向selected candidate恢复；无hidden cold fallback |
| observability | 无old/new generation状态 | status显示selected/serving/candidate/draining/deadline/continuity |

因此Mihomo的配置reload仍是独立参考，但其`/upgrade`不能作为zc优雅版本替换的依据。zc选择更接近
NGINX/HAProxy/Envoy的old/new overlap、exact listener reuse和old connection drain。
