# 兼容性历史实现与验证记录

本文迁自整理前的 `docs/compat/mihomo-clash.md`（基线 `7a99142`），按主题保留实现背景、历史对照和测试证据。下文的“本轮”指原记录所处的实现阶段，不代表本次整理重新验证；现行支持范围以[对外兼容文档](../docs/compat/mihomo-clash.md)为准。

本文不是完整 mihomo 替代声明，也不是最终验收报告。实现及分阶段差异见 [Rust 迁移](migration/rust.md)，排期以[开发优先级](development-priorities.md)为准。

## 配置投影与出站支持

- `src/override_script.rs::runtime_source` 只投影已经校验的兼容字段给 `src/config.rs`；immutable source/materialization 的规范字节及内容摘要不能被运行时投影改写。
- 用户命名 `type: direct/reject` 节点：原记录为“已由独立变更支持，可作为命名叶节点及 select 成员；本轮不重复实现”。
- HTTP/SOCKS5 outbound、VMess/VLESS：原记录为“不支持；保留历史代码不构成启用”。
- mixed 资源边界：最多 1024 connection tasks，入站握手 10 秒；不同于原 Zig 的 128 workers / 5 秒，原记录仍要求资源评审。路由与出站准备另有 10 秒 deadline，TCP 转发空闲期限 15 分钟；退出取消并回收任务，不承诺排尽全部存量流量。

## AnyTLS 生命周期与互操作

中继通过 `IoStream::whole_close()` 的可选单向终态通知识别 AnyTLS；默认无通知的 DIRECT/SS/Trojan 仍使用原 TCP half-close 转发。公共 `runtime::transfer` 是 CONNECT/SOCKS 共用入口；直接把 AnyTLS 交给 Tokio 通用 `copy_bidirectional` 不具备这项终态处理。HTTP forward 同样在整流终态停止上传、排完响应，未完成请求体不得复用为下一请求；HTTPS 包裹层透传通知，但不放宽内层 TLS 截断检查。请求头和 CONNECT 已缓存前缀在等待更多输入前 flush，避免缓冲出站阻塞提前响应或 100-continue。

生命周期修复后的公共回归位于 `tests/anytls_lifecycle.rs`：真实 TCP/TLS 双向各约 16 MiB（无心跳对照、1/32 心跳）、容量 1 的迟到上传/下行排尽、FIN 后无入站 EOF、控制洪泛、取消、本地 shutdown 尾部及 mixed CONNECT/SOCKS/HTTP/HTTPS。macOS arm64 已连续运行 20 轮；不是性能或四平台门禁。

独立官方 `anytls-go v0.0.13` / `v0.0.5` 已在本机通过真实 mixed echo/server-first、HTTP forward、错密码与目标失败等用例；可信 OpenSSL fixture 另测单次认证写、默认/更新 padding 的实际 TLS record。版本、哈希、可选命令及未纳入默认 CI 的边界见 [E2E](reliability/e2e.md#anytls-可选独立互操作)。协议来源见 [研究](research/anytls.md)。未证明抗指纹效果、四平台或长稳。

## simple-obfs 与 UDP

HTTP 首帧、Content-Length、分片 response header 与同 read 尾部由 `src/simple_obfs.rs` 有界处理；协议 oracle 的故意错误请求（如 ContentLengthMismatch）是负向验收，不应解释成生产 obfs 故障。wire 依据见 [研究](research/shadowsocks-simple-obfs-udp.md)。

mixed SOCKS5 UDP ingress 只支持显式 `udp:true` 的 SS classic AEAD 或原生 Trojan 叶节点。DIRECT、group→DIRECT、REJECT、AnyTLS、非 `udp:true` leaf 结束 association，不提供 DIRECT UDP ingress；内部测试/transport helper 有直连 UDP 不代表公开入口支持。

Trojan UDP 的 domain 先按原域名匹配规则，再本地解析成 IP frame 兼容主流服务端；session 缓存最后一个 domain/port 结果。Rust 使用异步单一 worker 独占 stream、有界双向各 2-frame channel，满时丢包；不沿用 Zig 的 256 KiB I/O thread 描述。wire 依据见 [研究](research/trojan-udp.md)。实际 IPv6 可达性依赖服务端 egress；300 秒 idle 需单独真实等待验证，短测试不能替代。

## 规则、provider 与解析资源

**严格 CLI 基线**：缺失 `rules`、显式 `[]`、非空规则缺终态 MATCH 均补 `MATCH,REJECT`；重复/非尾部 MATCH 拒绝。原 `config.zig::load()` 已调用严格 `parseDocument()`，只有不用于 CLI 的 legacy `parse()` 在字段缺失时补 DIRECT。旧二进制 dump 与真实 loopback 路由均确认严格语义；Rust canonical bytes/hash 不因此改变。

unmanaged HTTP rule-provider 的缓存路径受来源根目录约束，比旧 Zig 接受任意绝对路径更严格；没有迁移旧 cwd/绝对路径 cache，也没有 curl fallback。HTTP 状态/候选/写入失败策略来自原 `syncRuleProviderFilesIfNeededWithLimits`、`downloadRuleProviderFileUsing` 和 `publishRuleProviderFile`，不是将所有失败统称 best-effort。现行路径要求见[rule-provider 与离线托管](../docs/compat/mihomo-clash.md#rule-provider-与离线托管)。

Rust YAML 按原 Zig 的“根节点之外最多 128 层”计数（最多 129 个 collection frame），block/flow 与 JSON-looking 文档共享此边界。复杂 YAML 使用受限 16 MiB 栈的解析线程，普通原生 JSON 快路径保留自身递归保护，超出该快路径的合法深度交给同样有界的 YAML parser。仍限制 events 1600000、nodes 524289、scalar 合计 16 MiB，禁 anchors/aliases/merge keys/duplicate keys；其他资源计数不宣称与 Zig 完全一致。

## 控制面与仍待验收的差异

托管 profile 自动 controller secret 使用 schema-2 snapshot overlay。完整校验、冻结鉴权及回退约束见 [CLI](../docs/cli/spec.md#托管-profile-的自动-controller-secret) 与 [迁移说明](migration/rust.md#自动-controller-secret-的状态兼容与回退)。

缺省 rules 的审计误判已由严格 parser/旧二进制证据纠正；unmanaged cache/refresh 和 YAML 深度边界已有定向回归。完整诊断精度及其余资源策略差异仍须对齐或明确审批；TLS/DNS 使用成熟 Rust 库也需要互操作与性能证据，而非源码相似性证明。四平台、性能和长稳结论由各自验收证据维护，不自动改变开发排期。

配置 migrator 是独立 lint 工具，其可识别字段/类型不代表运行时启用；迁移工具与运行时边界仍需独立回归。

## 诊断实现与验证边界

`test/proxy test/profile test` 按 `test_cli.zig::getIpGeoInfo` 对齐 IP/Location JSON：成功含 `ip`（无 query 时 `unknown`），不含 `latency_ms`；其他成功 target 含 latency。502 失败，403 等非 502 响应仍算连通；文本显示同一 IP/latency/reason，连接期限 5 秒、geo 总期限 90 秒、其余目标 5 秒。

新增公开 `doctor_diagnostics` / `diagnostic_target_probe` 接口仅供传入真实本地测试 probe target，不增加 CLI/env 开关，也不改变命令默认目标。

多错误汇总、支持范围内的 warnings 和 source-text migration hints 已补齐；errors/warnings 合计最多 256 条、每条 512 bytes，错误优先，省略必须显式标记。与旧 validator 的精确差异及直接证据见 [doctor 诊断验收](migration/rust.md#doctor-validator-诊断验收)。geo 文本的城市/地区附加信息及 curl 特有的底层错误细分未逐项复刻，不宣称所有诊断文字完全等价。

## README 历史表述冲突

清理前 README 写道：

> 内置 `DIRECT`/`REJECT` 字面量可用；用户命名的 `type: direct/reject` 节点仍待补齐，不能据此表宣称已迁移。

同期兼容页已写明用户命名节点可用。这次清理不重新判断运行时能力，README 改为引用兼容页，不保留任务进度口径；本次未重新执行对应运行时测试。
