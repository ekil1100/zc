# 内部开发文档

本目录保存开发计划、设计研究、实现与验收记录、历史材料；面向用户的安装、使用与兼容文档位于 [docs](../docs/README.md)。

## 先读哪个

| 问题 | 入口 | 权威范围 |
| --- | --- | --- |
| 下一步做什么？ | [开发优先级](development-priorities.md) | 用户已确认的排序与进度；唯一排期入口 |
| 实现在哪里、迁移有哪些约束？ | [Rust 迁移](migration/rust.md) | 模块、数据兼容、实现和分阶段验证记录 |
| 是否具备完整发布证据？ | [迁移验收](migration/completion.md) | 候选与平台证据、发布缺口，不决定开发顺序 |
| 性能测了什么？ | [迁移性能记录](migration/performance.md)、[报告入口](perf/reports/README.md) | 测量来源与限制，不要求追平 Zig |
| 如何验证协议与稳定性？ | [E2E](reliability/e2e.md)、[长稳](reliability/soak-guide.md)、[平台诊断](reliability/platform-diagnostics.md) | 测试方法与故障证据 |
| 如何记录安装验证？ | [安装验收记录](install-validation.md)、[证据归档](install/evidence/README.md) | 安装回归与工件维护 |

## 专题与历史

- 协议研究：`research/`；AnyTLS 复用设计：`anytls/`。
- 故障定位和平台测试：`reliability/`；观测闭环记录：[observability-validation](observability-validation.md)；[TCP 代理 DNS 错地址修复](reliability/dns-routing-fix.md)；[Linux 日志锁与 AnyTLS 回归](reliability/linux-ci-regressions.md)。
- 协议与配置历史验证：[compat-validation](compat-validation.md)。
- 已批准用户服务与冷升级：[验收契约](service-upgrade-contract.md)、[本轮验证](service-upgrade-validation.md)。
- 热升级等候选方案：本目录下 `*-plan.md`、`*-research.md`；存在方案不等于已批准执行，也不改变开发优先级。
- 原路线图：`roadmap/`；CLI 历史决策：`cli/ux-workflow.md`；更早的方案与报告：`archive/`。其中历史完成标记不能作为当前候选的验收证据。

## 维护边界

- 排期变更只更新开发优先级；发布证据不足不自动变成当前 P0。
- 验收记录注明候选、平台、场景与未验证范围；旧失败、原始样本和历史结论保留，过时的决策明确标记为已替代。
- 文档中 `target/`、`/tmp/` 的工件路径可能只在原执行环境存在，不代表仓库已保存对应工件。
- 当前性能方向是 Rust 自身的 CPU/内存基线及实际瓶颈；历史 Rust/Zig 对照仍作为证据保留，其旧放行判断不恢复为现行排期要求。
