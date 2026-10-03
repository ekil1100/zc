# 通配 controller 实现与验证

范围：支持显式 `127.0.0.1:<port>` 和 `0.0.0.0:<port>`；通配监听要求非空运行时 secret，并对所有管理路由鉴权；本机 CLI 连接地址仍为 loopback。配置、catalog、descriptor 与 snapshot 的 schema 未改变。代理数据面和 mixed 绑定规则未修改。

## 红绿证据

- 新 HTTP API 测试先因 `external-controller must be explicit 127.0.0.1:<port>` 失败；放开解析、监听并增加全路由鉴权后通过。
- 旧配置迁移后的 CLI 测试先因 `RUNTIME_DESCRIPTOR_INVALID: invalid endpoint` 失败；区分监听和本机连接地址后通过。涵盖自动 secret、切组、切换 active 后使用原冻结凭据、默认 restart 和连接列表。
- doctor 新测试先报告 `Invalid external-controller (expected 127.0.0.1:PORT)`；共享地址解析规则后通过。
- 服务 enable 缺少 secret 测试复现“报错但已创建无效注册”；把鉴权前提检查移至实际配置准备后通过，launchd/systemd 两种管理器替身均覆盖。
- 首轮完整相关回归有一项既有日志测试失败：initial resource 日志后仍可能写入 daemon_ready，覆盖测试数据后读到迟到日志。定向重跑通过，随后等待两条启动日志均已落盘；保持原精确断言，daemon 全套 20 项通过。首轮失败保留在 `target/controller-wildcard/regression.log`。

## 验证环境与边界

使用 macOS arm64、Rust 1.98.1、Cargo.lock。初轮用现有 Rust 1.99 复现解析错误，随后安装 CI 同版本工具链进行正式回归。fmt、git diff --check 和 all-targets Clippy（-D warnings）通过。

Release 构建通过，见 `target/controller-wildcard/release-build.log`。`target/controller-wildcard/smoke.py` 仅在临时 HOME 和随机非 7899 端口启动 Release：loopback 与本机非 loopback IPv4 网卡访问均验证无认证 401、有认证 200，CLI status 获取运行状态成功，隔离实例已停止。此脚本的 UDP connect 只用于选择本机网卡地址，不向目标发送数据。

真实配置的临时副本中，剩余 3 份旧配置保持所有 source 字节和 active 不变，config list 完成迁移，--service-check 通过；未操作真实配置或服务。临时副本完成后删除，未保存配置内容、订阅 URL 或生产凭据。

未运行四平台原生、完整协议 E2E、性能或长稳门禁；服务测试使用管理器替身，不宣称已在真实 launchd/systemd 部署。未安装、提交或推送。

完整回归日志：`target/controller-wildcard/regression.log`、`target/controller-wildcard/regression-followup.log`；后者补齐未完成套件并重跑 daemon。最终去重汇总：217 passed / 0 failed / 3 ignored；历史二进制忽略项不计通过。用户服务全套 39 项通过，其中长超时测试覆盖两种管理器替身 × 六个阶段 × SIGINT/SIGTERM/timeout，共 36 个子场景。

## 各套件最终结果

| 套件 | 通过 | 失败 | 忽略 |
| --- | --- | --- | --- |
| lib | 20 | 0 | 0 |
| api | 12 | 0 | 0 |
| cli_managed | 30 | 0 | 0 |
| config_parity | 23 | 0 | 0 |
| connections_cli | 7 | 0 | 0 |
| daemon | 20 | 0 | 0 |
| diagnostics_validation | 16 | 0 | 0 |
| probe_cli | 5 | 0 | 0 |
| profile_secret | 12 | 0 | 3 |
| service | 10 | 0 | 0 |
| store | 23 | 0 | 0 |
| user_service | 39 | 0 | 0 |

完整格式与静态检查：`cargo +1.98.1 fmt --all -- --check`、`cargo +1.98.1 clippy --offline --locked --all-targets -- -D warnings`、`git diff --check`。
