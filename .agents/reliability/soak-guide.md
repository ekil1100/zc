# Rust 长稳测试运行指南

当前入口 `scripts/reliability/run-soak-real.sh` 调用 Python runner `soak.py`，构建 `target/release/zc`，在临时 HOME/XDG 目录运行自己拥有的 foreground 子进程，使用真实 loopback HTTP CONNECT echo 探针。**短测不是 24/72h 长稳，历史 Zig 证据不能直接套用。**

## 前置条件

- Rust/Cargo 与原生构建工具、Python 3；runner 自动 `cargo build --locked --release`。
- 显式非生产端口，拒绝 0、7899 或已占用端口，不换端口、不停止其他实例。
- 可持续运行的宿主。默认生成隔离 DIRECT 测试配置，不读取 `~/.config/zc/config.yaml`。
- 可选 `--config` 必须是有效、无 controller 的 loopback-only 配置，且允许访问测试 echo；runner 冻结 source，不代表自动捕获任意外部 provider 依赖。

## 运行

```bash
# Short scenario smoke; not a long-soak acceptance result.
bash scripts/reliability/run-soak-real.sh --seconds 30 --interval 5 --port 29001

# Actual elapsed-duration runs.
bash scripts/reliability/run-soak-real.sh 24 --port 29001
bash scripts/reliability/run-soak-real.sh 72 --port 29001

# Explicit isolated fixture and output location.
bash scripts/reliability/run-soak-real.sh 24 --port 29001 \
  --config /path/to/loopback-config.yaml --output target/reliability/soak-24h.json
```

默认每 300 秒采样进程存活与真实 payload round-trip，不只是端口 open。报告和同名 `.log` 默认写入 `target/reliability/`；探索运行禁止直接写 `docs/`。报告保留源码/二进制/config 哈希、commit、工作区状态和遗漏场景。

## 判定与证据

本 runner PASS 要求完整请求时长、零崩溃、零探针失败；输出 `SOAK_RESULT`、`SOAK_REPORT`、`SOAK_CRASHES`、`SOAK_SAMPLES`、`SOAK_PORT_FAILURES`。中断、启动/探针失败均保留失败报告并清理自己拥有的进程。

`--scenario process-exit` 注入子进程退出并由 **harness** 重启、验证恢复时间，不是 zc 自动故障转移能力。DNS timeout、上游 failover、热重载回滚和历史性能阈值仍列为 omitted，报告 `formal_baseline:false`、`historical_soak_complete:false` 不能被改写为完整历史门禁通过。

正式 24/72h 验收还需 [原可靠性场景](chaos-tests.md) 的流量、扰动与性能证据，并由最终验收记录确认。切勿把 `--seconds` 短测或单一 DIRECT echo 当作完整代理长稳。

## 失败处理

- 参数/端口错误：选择明确的空闲非生产端口，不修改现有生产实例。
- 构建错误：检查锁定依赖与 C/C++ 工具链，不改用 Zig 回退。
- 配置/启动错误：检视报告和隔离日志，修正 fixture；不删除真实状态目录。
- 中断：保存 elapsed duration 与失败原因，重新运行，不能累计成未中断的完成记录。
