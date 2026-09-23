# 订阅配置待支持字段

## 当前决策

用户要求：合法订阅包含 zc 暂未实现的配置字段时，不应仅因此拒绝整份配置。当前明确放行以下七个顶层字段：接受并在运行时投影中忽略，保留原文件与 immutable revision 字节，不冒充已经实现。

详细行为和兼容边界见 [兼容说明](../docs/compat/mihomo-clash.md#接受但暂不执行的订阅字段)。不支持的出站协议、插件、策略组及错误规则仍拒绝，不回退 DIRECT；暂不扩大到所有未知字段或 override patch。

## 后续清单

- [ ] `dns`：自定义 DNS、fake-ip、enhanced-mode、nameserver-policy 等，按子功能逐步实现。
- [ ] `hosts`：配置内静态域名映射。
- [ ] `sniffer`：协议嗅探及目标覆盖。
- [ ] `profile`：store-selected/store-fake-ip 等选项；保留现有 zc 持久选择行为。
- [ ] `experimental`：逐项评估订阅实际使用的选项。
- [ ] `unified-delay`：统一延迟测量语义。
- [ ] `clash-for-android`：评估可移植选项；不因此承诺 Android 平台支持。

每项启用前补行为测试、更新兼容文档，并说明从“忽略”变成“生效”的行为变化。DNS/hosts 等字段生效可能改变路由结果，不能仅以配置解析成功作为验收。
