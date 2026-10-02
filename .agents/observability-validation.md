# 运行时观测历史验收记录

以下内容迁自 `docs/reliability/observability.md`，仅保留当时的验证结果，不代表当前版本重新通过验收。`target/` 路径是当时的本地工件引用，不保证仍可用。

历史部署状态：没有安装或重启现有生产实例。


验收入口：

```bash
cargo test --offline --locked --lib --test observability_lifecycle --test observability_connections
cargo test --offline --locked --test daemon --test daemon_races --test cli
cargo test --offline --locked --test runtime --test outbound --test dns --test udp --test socks_udp
cargo clippy --offline --locked --all-targets -- -D warnings
```

实际 CLI/socket 回归覆盖初始、周期、最终摘要，真实 SOCKS 活动连接和回收，强杀后下次启动检测、正常信号退出、损坏标记保留、限频合并、日志容量和归档权限、轮转一致读取、follow 重开、采样不可用、上游拒绝、TLS 拒绝/超时、HTTP 截断、UDP 故障、策略拒绝及脱敏。panic 与采样超时在隔离子进程中验证，没有新增生产测试开关。DNS 分类另有本地解析器与真实 Runtime 的回归，不通过修改本机 DNS 注入。

联合回归曾重复出现 `daemon_races::config_override_captures_instance_before_script_preparation` 的公开 `restart` 返回 `file metadata changed during capture`。已定位为 `stopped()` 读取 descriptor 与 daemon 正常退出删除同一 inode 交错，导致 `nlink: 1→0`。现在读端也持有已有 `zc.daemon.lock`；确定性真实 syscall 调度测试证明修复前清理可抢先删除、修复后清理等待读取完成。不降低文件安全检查、不增加重试或修改原测试断言。证据见 `target/reliability/restart-capture-{deterministic-red,deterministic-green,regression,clippy}.log`，细节见[文件捕获](reliability/read-capture.md#停止确认与退出清理的读取临界区)。这不自动关闭历史 Intel CI 的其他失败。

最终相关测试覆盖 138 项通过，真实五分钟 UDP idle 用例本轮仍忽略；全目标严格 Clippy、格式检查和 Release 构建通过。联合运行记录 `target/reliability/p0-acceptance.log` 中其余 123 项通过，日志测试的一项测试夹具端口竞争随后修复，完整 15 项生命周期套件通过于 `target/reliability/p0-lifecycle-final.log`。夹具沿用项目串行隔离规则，明确释放用于冲突测试的监听器，不修改生产端口冲突策略，也不删失败样本。

迭代检视前的本机 macOS arm64 Release 隔离短测：65 秒、66 次真实 CONNECT + 4 KiB echo 全部成功，最终活动连接、故障和 panic 均为零。RSS 从约 4.84 MiB 增至 6.08 MiB；两个 30 秒周期各消耗约 140ms 进程 CPU 时间，约为单核 0.47%。只是低负载短样本，不代表空闲、满速、SS/Trojan 开销或长期无泄漏；不包含独立 `ps` 子进程 CPU。原始事件、二进制 hash 与探针保留在 `target/reliability/p0-release-observe.{json,py}`。

后续迭代检视共 4 轮：前 3 轮修复冻结错误码、任务 panic 脱敏、嵌套任务回收顺序、HTTP/SS/obfs 截断漏记、UDP 控制取消误报及超限事件元数据；第 4 轮未发现新的可操作问题。SS 观测适配器仅跟踪锁定依赖的精确读单元阶段，不解密、不重写 AEAD framing；覆盖 salt/length 完成后等待必需数据及完整 payload 后普通 RST 的区别。最终相关测试 **175 项通过、1 项五分钟 UDP idle 忽略**，全目标严格 Clippy 和格式检查通过，记录于 `target/reliability/review-loop-final.log`。前述 138 项及 65 秒短测保留为检视前证据，不冒充检视后完整性能复测。

尚未执行本次候选的四平台原生门禁、24/72 小时长稳、实际生产部署或正式资源开销基线。实例流程之前的 CLI 配置准备失败仍主要通过命令的错误输出报告，不能声称所有 CLI 失败都写入 daemon 日志。P0 的运行时观测实现和本机定向验收已完成，不代表长期稳定性或迁移发布已经验收。
