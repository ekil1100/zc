# zc test 可用性与实际路径验收

## 结论

功能分支 `feat/test-availability`，基线 `40f4031`，分支提交 `9094757`。在已有分层故障日志提交 `0186ef8` 上 squash 集成；唯一冲突位于 HTTP 请求准备处，保留日志的 `FailureContext` 及本轮请求票据关联。未推送、安装、重启或修改生产实例。

- 全部目标成功才 exit 0；部分成功、全部失败均保留逐项结果并 exit 1；端口不可达标为未执行。
- 有效 controller 的新版受管实例通过鉴权、实例绑定、单次消费的请求票据，取得该次 HTTP forward 实际选定的 DIRECT、代理或 REJECT leaf。
- 按 direct/proxy/reject/unknown 分别统计成功与失败；配置选择仅标为准备配置来源，不冒充实际出站。
- 默认目标仍为 HTTP，沿用完整非 502 响应视为连通的规则；目标 HTTP 成功、路径证据与 HTTPS 业务可用性分别解释。

公共接口与使用边界见 [CLI](../../docs/cli/spec.md#test-的可用性摘要与实际路径)、[API](../../docs/api/README.md#诊断请求票据)。

## 证据机制与边界

复用冻结 controller secret 与实例身份；长期 Bearer 仅发送到既有 loopback controller，不创建端口。每张票据绑定目标，运行时消费后记录实际 Route，查询不重新选组；证据独立于活动连接，短连接删除、同连接下一请求及并发同目标均不会覆盖归属。

票据限 256 张、预约起 120 秒有效，标识含实例 nonce、96 位随机数及 checked 发行序号。重放、错目标、旧实例或过期请求在拨号前拒绝。追踪头在入口剥离，同时由 CLI 声明为逐跳字段；CONNECT 和追踪 trailer 拒绝，HTTPS 隧道不附票据。沿用可信本机 HTTP 控制面的边界。

缺 controller、鉴权失败、外部端口、旧接口、实例变化或未取得路由时明确为 unknown 并附原因和提示。记录 leaf 证明选择/尝试，成功与失败由目标结果单独表示。

## 分支验证

分支原始记录位于其 `target/test-availability/validation.md`：139 项回归通过，另独立通过真实 120 秒到期测试；最后变更后 18 项 CLI 与 4 项快速运行时用例再次通过。原始红绿覆盖 1/7 错报成功、追踪头泄漏、票据拒绝被误算成功及诊断错误码映射。

## 合并验证

父任务检查关键实现及文档，解决局部冲突后，在主工作区执行：

```sh
cargo test --offline --locked --lib \
  --test runtime --test api --test connections --test connections_cli \
  --test profile_secret --test anytls_lifecycle --test anytls_chunked \
  --test diagnostics --test diagnostics_validation --test cli \
  --test test_availability --test probe_api --test probe_runtime \
  --test probe_cli --test probe_boundary \
  --test observability_connections --test observability_lifecycle
cargo fmt --all -- --check
cargo clippy --offline --locked --all-targets -- -D warnings
git diff --cached --check
```

结果：**187 项通过，0 项失败，4 项忽略**。三项忽略需要历史二进制，一项为分支已经独立通过的真实 120 秒到期用例，本次未重复。格式、严格 all-targets Clippy 及差异空白检查通过。包含测试辅助子进程入口，内部断言不额外累加。日志：`target/test-availability-merge/regression.log`。

覆盖真实 runtime 的 DIRECT 1 成功/代理 6 失败、代理成功/直连失败、公开 CLI 七项目标经本地 SS、短连接/keep-alive/并发归属、切组与重启、鉴权与额度、头/trailer 隔离，以及原连接管理、分层故障、生命周期和正常转发。全部使用隔离状态、loopback 与非生产端口，未依赖外网。

本轮为 macOS arm64、Rust 1.98.1 定向验证；未新增性能、四平台、生产冒烟或长稳通过结论。
