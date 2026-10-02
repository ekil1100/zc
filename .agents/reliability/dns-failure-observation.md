# DNS 与出站分层故障观测验收

## 结论与范围

基线 `40f4031`，功能分支 `feat/dns-failure-observation`，分支提交 `5baa4e9`。本轮将已完成的日志分支 squash 合入 `to-rust`；`zc test` 实际路径识别仍在独立 worktree 实施，不包含于本次合并。未推送、安装、重启或修改生产实例。

保留原六阶段，在故障事件中增加固定四值 `source`：`target`、`proxy`、`proxy_protocol`、`unspecified`。区分目标与节点解析、直连与节点连接、节点 TLS 与 zc 主动执行的目标 TLS，以及代理协议本地准备。公开行为见 [运行时稳定性观测](../../docs/reliability/observability.md)。

计数有界为 6 阶段 × 4 来源 × 16 错误类别；按阶段、来源、错误类别分别限频合并，原阶段与总失败计数保持不变。日志不增加目标、节点名称、凭据或原始错误文本。

## 验证

分支先复现目标来源缺失、节点解析被标为目标的问题，再补实现。独立只读核查后补强 Trojan UDP 目标解析、协议准备及后续转发来源清理断言。分支原始工件位于其 `target/dns-observation/`。

父任务核查最终代码、文档及验收记录后，在主工作区 squash 暂存状态重新执行：

```sh
cargo test --offline --locked --lib \
  --test observability_connections --test observability_lifecycle \
  --test dns --test dns_routing --test outbound --test runtime \
  --test socks_udp --test connections --test anytls --test anytls_lifecycle
cargo fmt --all -- --check
cargo clippy --offline --locked --all-targets -- -D warnings
git diff --cached --check
```

结果：**161 项通过，0 项失败，1 项忽略**。忽略项为既有五分钟 UDP idle 场景。格式、严格 all-targets Clippy 与差异空白检查通过。本机 Rust 1.98.1、macOS arm64。

覆盖本地 loopback DNS 超时、目标/节点连接拒绝、分来源合并计数、内外层 TLS 超时、并发隔离、正常断连与取消、隐私和生命周期。协议准备失败由真实传输写失败及 Connector 状态切换分别验证，未新增真实 TLS 节点准备失败的完整端到端复现。

## 边界

- DNS 格式有效但地址错误仍视为解析成功；客户端在 CONNECT/SOCKS 隧道内执行的 TLS 校验由客户端诊断。
- 远端后续拒绝按实际 transfer/udp 阶段记录，不推断远端 DNS、认证或连接根因。
- 未增加 DNS 回退、重试、TLS 降级或自动节点切换。
- 未新增原生 TCP 丢包超时复现；四平台、性能及长稳门禁仍待独立验收。
