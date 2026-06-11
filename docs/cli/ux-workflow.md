# CLI UX 对齐工作流 — 验收标准

> 生成时间：2026-06-11；完成：2026-06-12
> 状态：**全部批次（1-5）完成**，代码已落地；本文件保留为决策/验收记录
> 事实基线：[`.agents/cli-ux-baseline.md`](../../.agents/cli-ux-baseline.md)（全命令契约矩阵、缺口清单、消费者清单）
> 目标：CLI 直觉、错误可操作、`--json` 对 agent 友好 —— 对齐 AGENTS.md 的产品原则。
> 实现后的对外契约见 [`spec.md`](spec.md)。

## 1. 目标契约（Target contract）

### JSON 模式（`--json`，全命令支持）

- 成功：`{"ok":true,"command":"<path>","data":{...}}`，单行，**stdout**，exit 0。
- 失败：`{"ok":false,"command":"<path>","error":{"code":"...","message":"...","hint":"..."}}`，**stdout**，exit ≠ 0。诊断类命令（`test` / `doctor`）失败时可附带 `"data"`（逐项检查结果）。
- 每次调用 stdout 上**恰好一个** JSON 文档；流式命令（`zc log --json`）使用 JSON Lines（每行一个事件对象）。
- 全部经 `std.json` 序列化（真实转义），禁止手拼 JSON 字符串。
- 唯一例外：`zc config dump` 输出裸文档（YAML / `--json` 时裸 JSON 对象，不包 envelope），可直接 `| yq` / `| jq`；失败仍走 envelope。

### 文本模式

- 主输出 **stdout**；诊断/进度 **stderr**。
- 颜色：仅 TTY 且未设 `NO_COLOR`、未传 `--no-color` 时启用。
- 交互（`proxy select` 选择器）仅在 stdin 为 TTY 时进入；非 TTY 且缺 `-g`/`-p` 时报错退出（**禁止**静默选第一个节点）。

### 退出码与帮助

- 成功 = 0；任何失败/用法错误/未知（子）命令 ≠ 0。JSON 模式与文本模式退出码一致。
- `--help`/`-h`/`help` 对**每个**命令有效，输出到 **stdout**，exit 0；`zc start --help` 绝不能启动 daemon。
- `zc`（无参数）与未知命令：用法到 stderr，exit ≠ 0（`--json` 时 envelope 到 stdout）。
- `zc --version` / `zc version`：版本到 stdout，exit 0。
- 帮助文本由命令表生成，禁止手写重复；`help` 仅在参数首位识别（值为 "help" 的参数可用）。

### 命令表与别名

- `src/cli/output.zig`：Output 上下文（模式、流路由、envelope、JSONL、颜色）。
- 声明式命令表驱动 dispatch 与生成帮助；proxy/profile 共享同一 handler（按命令路径渲染文案，消除复制粘贴）。
- 别名（写入生成帮助）：`config ls` / `proxy ls`（保留）、`zc up` → `start`、`zc down` → `stop`。

## 2. 已定决策

| # | 决策 | 来源 |
|---|---|---|
| D1 | `zc start` 保持 fork-and-exit；新增 `--foreground`（容器/systemd 用）；同步更新 `zclash.service`、`build-deb.sh`、podman e2e | 维护者 |
| D2 | `config dump` 裸文档（唯一 envelope 例外） | 维护者 |
| D3 | `test`/`doctor` 检查失败 ⇒ `ok:false` + `error.code=CHECKS_FAILED` + `data`（逐项结果）+ exit ≠ 0；JSON 与文本跑**相同探测**（行为一致） | 维护者 |
| D4 | 别名只加 `up`/`down`，保留 `ls` 家族 | 维护者 |
| D5 | `zc status` 停止态仍 exit 0（状态在 `data.state`） | 默认 |
| D6 | `zc restart --json` 收敛为**单个**最终 envelope；中间步骤文本走 stderr | 默认 |
| D7 | `already_running`/`already_stopped` 仍为成功（`ok:true`，exit 0） | 默认 |
| D8 | `config use` 不自动 apply，文本模式提示下一步；`data` 注明 `applied:false` | 默认 |
| D9 | 新增 `zc reload`：热重载当前配置（`daemon.reloadOrRestart`，restart 兜底）；podman e2e 已引用 | 默认 |
| D10 | `profile` 保持 `proxy` 的别名组（不在本工作流中重命名/废弃），文案按命令路径渲染 | 默认 |
| D11 | 未知 flag / 缺值 flag ⇒ 用法错误 exit ≠ 0（终结 `hasFlag` 全 argv 扫描） | 默认 |
| D12 | 移除 ps/pgrep 全局 daemon 发现：`status`/`stop` 只信任本环境 pid/lock 文件，绝不收养并杀掉其他 HOME/XDG 环境（如生产实例）的 daemon；pid 文件丢失时按 `lock_held_pid_untracked`/端口占用报告，不再自动接管 | 验证中发现的危险行为，维护者隔离要求 |

## 3. 冻结词汇（不可变更）

- 错误码字符串（`docs/api/error-codes.md` + integration tests 中已断言的全部 `*_FAILED` / `*_UNKNOWN` 等）。
- `state` 取值：`running` / `stopped` / `selected` 等；`detail` 取值：`already_running`、`already_stopped`、`stale_pid_file`、`lock_held_pid_untracked`。
- JSON 字段名：`action`、`state`、`pid`、`uptime_seconds`、`active_config`、`selected_proxies`、`paths`、`daemon_state`、`proxy_reachable`、`group`、`proxy`、`source`。
- doctor 文本标签：`Config:`、`Daemon:`、`PID:`、`Port:`、`Connection:`；健康输出含 `OK`/`valid`。
- 字段**顺序**不再保证：测试改为解析 JSON 后断言（淘汰子串顺序断言）。

## 4. 实施批次与验收标准

每批保持 `zig build test` 全绿、独立 commit（Conventional Commits）、同 commit 更新受影响测试与文档。消费者影响明细见基线报告第 3 节。

### Batch 1 — 输出基础设施 + 全局表面 ✅ 完成

> 结果：`src/cli/output.zig` + `src/cli/commands.zig` 落地；帮助 stdout/exit 0、`zc --version`、未知命令非零、`up`/`down` 别名全部生效。

新建 `src/cli/output.zig`（TDD）与命令表骨架；接入 `zc`（裸）、`help`、`--version`、未知命令路径、`up`/`down` 别名；删除死代码 `printProfileListJson`。

验收：
- `zig build test` 通过；
- `zc --help >out 2>err`：帮助在 `out`，`err` 为空，exit 0；帮助含 `Usage`（兼容 e2e grep）；
- `zc --version` stdout 输出版本，exit 0（解除 Containerfile:23 阻塞）；
- `zc nope`：用法 stderr，exit ≠ 0；`zc nope --json | jq -e '.ok==false'` 在 stdout 可解析；
- `zc up --help` 显示 start 帮助，不启动 daemon。

### Batch 2 — 生命周期：start/stop/restart/status/log/reload ✅ 完成

> 结果：生命周期全量走 Output（payload stdout）；双重打印修复；`--foreground`/`reload` 新增；`restart` 单 envelope；`log --json` = JSON Lines；D12 移除 ps/pgrep 全局 daemon 发现。
> 收尾补强（最终批次）：生命周期命令补齐 D11 —— start/restart 参数错误从 exit 1 改为 exit 2，start/restart/stop/status/reload/log/doctor 不再静默忽略未知/多余参数（新增 `STOP/STATUS/RELOAD/LOG_ARGUMENT_INVALID`、`DIAG_DOCTOR_ARGUMENT_INVALID`）。

经 Output 重路由；修双重打印；`start --foreground`；`restart` 单 envelope；`log --json` = JSON Lines、`log --help` 生效；新增 `reload`；`runtime_selection.zig` 改 `std.json`。

验收：
- `zc status --json | jq -e '.ok and .command=="status"'`；
- 失败路径恰好一行 JSON、exit ≠ 0、无 Zig stack trace；
- `zc start --help`/`zc log --help` 只打印帮助；
- `just install` 全程可用（Justfile 改 `| jq -r .data.state`，删除 `2>&1` workaround 注释）；
- `zclash.service` / `build-deb.sh` / podman e2e 改用 `--foreground` 后通过。

### Batch 3 — config 树 ✅ 完成

> 结果：config 全子命令统一 envelope/帮助/退出码；用法错误 exit 2；`dump` 裸文档走 stdout 可管道（D2）；`use` 不自动 apply 并提示 `zc reload`（D8）。

list/download/update/use/dump/override + 裸/未知路径全量 `--json`、统一 `--help`、用法错误 exit ≠ 0、修 `-d` flag、`std.json` 化；`dump` 走裸文档且 stdout 可管道。

验收：
- `zc config dump > f` 捕获完整 payload；`zc config dump --json | jq .` 通过；
- `zc config nope` exit ≠ 0；`zc config list --json | jq -e '.ok'` 通过；
- `config update` 不再混排文本与嵌套 JSON。

### Batch 4 — proxy/profile：list/select/test 去重 ✅ 完成

> 结果：proxy/profile 共享 handler（D10）；JSON select 真正通知 daemon（`data.applied`）；非 TTY 无 `-p` 报 `PROXY_SELECT_NOT_INTERACTIVE`；`-g` 只匹配 select 组；名称全量 `std.json` 转义。

共享 handler；JSON 模式 select 真正调用 `notifyDaemon`（修无操作假成功）；统一 `-g` 匹配语义；非 TTY 无参 select 报错；JSON 错误 exit ≠ 0；全部名称转义；修 type 回退 bug。

验收：
- `zc proxy list --json | jq .` 通过（含特殊字符节点名）；
- `zc proxy select -g 不存在 --json`：单 envelope，exit ≠ 0；
- `echo | zc proxy select` 不再改写 daemon 选择；
- select 后 `zc status --json` 反映新节点（JSON/文本行为一致）。

### Batch 5 — test/doctor/diag + 文档/脚本收尾 ✅ 完成

> 结果：`CHECKS_FAILED` + `data.checks` 语义落地（test/doctor/diag doctor，两种模式同探测、失败 exit 1）；`DIAG_SUBCOMMAND_MISSING`/`UNKNOWN` 区分；doctor 字符串转义；spec/error-codes/README/compat/roadmap/脚本全部同步。

`CHECKS_FAILED` 语义（D3）；两种模式探测一致；config-load 失败两种模式都有 envelope/报错；doctor 字符串转义；`diag` 缺参/未知子命令区分错误码；同步 `docs/cli/spec.md`、`docs/api/error-codes.md`、`docs/compat/mihomo-clash.md`、`README.md`、roadmap、`run-soak-real.sh`、podman e2e。

验收：
- `zc doctor --json | jq -e '.data.proxy_reachable!=null'` 自 stdout 通过（修复 soak 脚本静默失效）；
- 探测失败时 `zc test --json` exit ≠ 0 且 `ok:false`；
- `bash scripts/run-full-validation.sh` 通过；README/roadmap 中的 smoke 序列逐条复跑通过。

## 5. 完成定义

全部批次合入 `main`、`docs/cli/spec.md` 重写为新契约、基线报告中"消费者破坏清单"逐项勾销、`scripts/run-full-validation.sh` 与 e2e-podman 全绿。

## 6. 已知 follow-up（不在本工作流范围内）

- **API server 手拼 JSON / 转义缺口**：`PUT /proxies/<group>` 的 body 解析已改用 `std.json`（修复旧 `extractJsonString` 扫到第一个 `"` 字节截断转义名的 bug），但 `src/api/server.zig` 的 `GET /proxies` / `GET /rules` 响应仍手拼 JSON 且不转义名称 —— 含 `"`/`\` 的节点/规则名会产生非法 JSON；URL path 中的组名也未做百分号解码（含空格/特殊字符的组名无法经 API 选择）。CLI 侧（`zc proxy select` 的 PUT body）已全量 `std.json` 序列化，不受影响。
- API 错误响应仍为 `{"error":"…"}` 简单格式，未对齐 CLI 的 `{ok,command,error}` envelope（见 `docs/api/error-codes.md` 第 7 节）。
