# 性能测量记录

## 正式控制面记录

```bash
# 必须是干净工作区，未跟踪文件也算 dirty。
bash scripts/perf/run-control-plane-baseline.sh \
  --samples 9 --output target/perf/control-plane.json

# 相同记录器，由 eval 收集报告。
bash scripts/eval/run.sh --suite perf
```

记录器从经过逐文件校验的提交副本构建 Rust Release example
`examples/perf_runner.rs`，不使用调用者工作区中的旧二进制。

- 只记录事实：原始样本、中位数、nearest-rank p95、subject/harness commit、Rust 版本、机器信息。
- 返回成功不代表性能达标；目前没有正式阈值门禁。
- 保留 dirty worktree、异常 index flags、replacement refs、grafts、非 harness 改动等拒绝条件。
- subject 只能是 HEAD，或仅修改允许的测量 helper/文档的直接父提交；修改 Cargo 依赖或生产源码不属于 harness-only。
- 输出位于 `target/perf/` 或指定临时目录，不自动写入历史基线。
- 至少五组样本、一组预热；p95 是**各组平均操作耗时**的分位数，不是逐请求 p95。

### Rust helper 的测量边界

保留原 CLI 参数和 measurement envelope（`method`、`benchmarks[].samples`、汇总值、`checks`、`omitted`）；编译器字段改为 `rust_version`，优化模式为 `release`。

- `legacy_bounded_read`：仅在 helper 内保留旧截断式读取的参考算法，不是生产 fallback。
- `strict_bounded_read`：调用生产 `fsutil::read_regular`。
- `profile_publish_profiles_{1,100,1000}`：真实 `Store.publish` 与 `Store.get`，包含不可变 revision 和持久化 catalog CAS，并重新打开存储校验。

Rust 没有与 Zig `Authority.commit(compare_exchange_head)` 等价的公开低层接口；因此不沿用旧 `authority_commit_profiles_*` 名称，不把不同操作的数字相除宣称提速。未测的旧 CAS 操作及数据面指标列入 `omitted`。

## 迁移期间的探索性对比

```bash
python3 scripts/perf/compare-runtimes.py --build \
  --samples 7 --iterations 100 \
  --output target/perf/rust-zig-comparison.json
```

这个独立入口允许 dirty candidate，但**不是正式基线记录器的绕过选项**。它复制当前源文件到独立快照，分别构建 Rust Release 与原 Zig ReleaseFast，保留构建命令、逐文件 SHA-256、二进制 SHA-256、dirty 状态和原始样本。测试只使用临时 HOME/XDG、非 7899 端口和 loopback。

原 Zig 仅用于显式对照，不是 Rust 生产依赖，也不是默认 Cargo 测试依赖。
方法、实测结果及尚未解决的问题见 [迁移性能与可靠性记录](../../migration/performance.md)。

## 历史文件

| 路径 | 地位 |
| --- | --- |
| `history/*.json` | 仅供考古，不具备当前验收效力 |
| `baseline-v1.0.0.md` | 历史笔记 |

曾生成假 PASS 的占位性能入口和 latest 报告已移除，不得恢复为门禁。
历史清理仍可用 `bash scripts/perf/prune-history.sh 30`，不会生成新的权威基线。

## 尚未完成

- 固定机器的阈值策略与正式对比门禁。
- 独立的 parser/route 热路径、DNS、握手、RSS 测量。
- CI 性能门禁及 24h/72h 完整历史长稳验收。
