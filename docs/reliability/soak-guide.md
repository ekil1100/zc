# 长稳测试运行指南

## 前置条件

1. 可用的代理配置文件（含至少一个可连通的代理节点）
2. 构建完成：`zig build`
3. 持续运行环境（不会被中断的终端或 tmux 会话）

## 一键启动

### 24h 长稳
```bash
# 使用默认配置路径（~/.config/zc/config.yaml）
bash scripts/reliability/run-soak-real.sh 24

# 指定配置
bash scripts/reliability/run-soak-real.sh 24 --config /path/to/config.yaml
```

### 72h 长稳
```bash
bash scripts/reliability/run-soak-real.sh 72 --config /path/to/config.yaml
```

### 在 tmux 中运行（推荐）
```bash
tmux new-session -d -s soak 'bash scripts/reliability/run-soak-real.sh 24 --config ~/.config/zc/config.yaml'
tmux attach -t soak  # 查看进度
```

## 监控

- 每 5 分钟采样一次：进程存活 + 端口监听
- 实时日志：`docs/reliability/soak-logs/<run_id>.log`
- 指标流：`docs/reliability/soak-logs/<run_id>-metrics.jsonl`

## 产出

- 报告：`docs/perf/reports/history/<run_id>.json`
- 输出字段：`SOAK_RESULT=PASS|FAIL`、`SOAK_CRASHES`、`SOAK_SAMPLES`、`SOAK_PORT_FAILURES`

## 通过标准

- `SOAK_CRASHES=0`（零崩溃）
- `SOAK_PORT_FAILURES` < 总采样数的 5%

## 失败处理

- `config-missing`：提供 `--config` 路径
- `build`：检查 `zig build` 是否通过
- `start-failed`：运行 `zc doctor -c <config>` 检查配置
