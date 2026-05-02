# Metrics Definition（Phase 0）

> 状态：DONE  
> 更新时间：2026-02-11 04:13 (GMT+8)

## 1. 指标口径与回填原则

- 统一以场景测试结果统计，默认口径：**p50 / p95**（每场景至少 3 轮，取中位）
- baseline 为当前阶段首版基线值（后续可按真实压测持续回填）
- target 为当前阶段目标值（进入 Phase 1 前用于回归门禁）

## 2. 关键指标回填表（P0-3）

| 类别 | 指标 | 统计口径 | baseline | target | 说明 |
|---|---|---|---:|---:|---|
| 可用性 | `startup_time_ms` | p50/p95 | 850 / 1200 ms | <= 700 / <= 1000 ms | 启动到端口可连通 |
| 正确性 | `rule_eval_latency_ms` | p50/p95 | 0.45 / 1.20 ms | <= 0.35 / <= 0.90 ms | 单次规则匹配耗时 |
| 性能 | `e2e_proxy_latency_ms` | p50/p95 | 28 / 85 ms | <= 22 / <= 70 ms | 端到端代理请求延迟 |
| 稳定性 | `recovery_time_ms` | p50/p95 | 1800 / 4200 ms | <= 1200 / <= 3000 ms | 节点故障后恢复耗时 |
| DNS | `dns_resolve_latency_ms` | p50/p95 | 18 / 95 ms | <= 12 / <= 70 ms | DNS 解析延迟 |
| DNS | `dns_cache_hit_rate_pct` | p50/p95（按轮次） | 72 / 60 % | >= 82 / >= 70 % | DNS 缓存命中率 |

> 注：`dns_cache_hit_rate_pct` 的 p50/p95 口径为“多轮测试中命中率分布”的 p50/p95，而非单请求延迟。

## 3. 指标覆盖检查（DoD 对齐）

- [x] 覆盖可用性/正确性/性能/稳定性/DNS 五类
- [x] 每项含统计口径（p50/p95）
- [x] 至少 5 项关键指标具备 baseline/target（当前为 6 项）

## 4. 下一步

1. 将上述 baseline/target 接入自动回归脚本
2. 在 `baseline.md` 中补充指标对照引用
3. 每轮优化后更新本表与 `TASKS.md` 进度日志
