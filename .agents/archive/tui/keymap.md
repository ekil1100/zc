# TUI Keymap & Interaction Draft（P3-2 初稿）

## 1) 全局键位（跨 Tab 一致）

- `?`：打开/关闭快捷键帮助
- `/`：进入搜索/过滤输入
- `g`：快速跳转（Overview/Proxies/Connections/Logs/Diagnose）
- `r`：刷新当前视图
- `Tab` / `Shift+Tab`：焦点切换
- `j/k` 或 `↑/↓`：列表移动
- `Enter`：确认/进入详情
- `Esc`：返回上一级
- `q`：退出弹窗（主程序退出需二次确认）

---

## 2) Tab 专用交互草案

## 2.1 Proxies（代理组切换）
- `s`：在当前组执行“选择代理”
- `t`：触发当前组延迟测试
- `f`：按组名/节点名过滤
- `Enter`：查看组内节点详情

### 代理组切换交互流（可实现草案）
1. 用户在 Proxies 选中某个 group，按 `s` 进入选择态；
2. 列表高亮可选节点，`j/k` 移动，`Enter` 提交切换；
3. 提交后进入短暂 `switching` 状态（spinner + group/proxy）；
4. 成功：状态条显示 `Switched: <group> -> <proxy> @ <time>`；
5. 失败：弹出结构化错误（code/message/hint），并提供“重试/返回”操作。

### 失败提示规范
- 组不存在：`PROXY_GROUP_NOT_FOUND`
- 节点不存在：`PROXY_NOT_FOUND`
- 无可选组：`PROXY_SELECT_GROUP_MISSING`
- 其它失败：`PROXY_SELECT_FAILED`

反馈要求：
- 切换成功：底部状态条显示 `group/proxy` 与生效时间
- 切换失败：显示结构化错误 + 建议动作

### 延迟对比展示规则（可实现草案）
- 采样窗口：默认最近 **3 次**探测结果（滚动窗口）；
- 刷新方式：`t` 手动触发 + 可选后台周期刷新（默认关闭）；
- 排序口径：按 `p50 latency` 升序，若相同按最新成功时间降序；
- 空值处理：
  - 未测：显示 `--`，排序置底；
  - 超时/失败：显示 `timeout`，排序置底（高于未测）；
- 展示字段：`node`, `p50`, `last`, `samples(3)`；
- 可读性约束：仅在组内展示，不跨组混排。

## 2.2 Connections（连接筛选）
- `/`：按目标地址过滤
- `i`：按 inbound 类型过滤
- `o`：按 outbound 类型过滤
- `c`：清空筛选条件（恢复全量）

### 连接筛选维度与流程
- 维度：
  1) 目标地址（target，支持关键字/后缀）
  2) 入站类型（inbound，如 mixed/http/socks）
  3) 出站类型（outbound，如 PROXY/DIRECT/节点名）

- 交互流程：
  1) 按 `/` 输入 target 过滤；
  2) 按 `i` 进入 inbound 过滤菜单；
  3) 按 `o` 进入 outbound 过滤菜单；
  4) 过滤条件可叠加；
  5) 按 `c` 一键清空所有筛选并恢复全量连接列表。

### 排序规则与冲突处理
- 默认排序：`start_at` 降序（最近连接在前）
- 可选排序键：
  - `T`：按目标地址（target）字典序
  - `D`：按连接时长（duration）降序
  - `B`：按流量（bytes_total）降序

- 多条件优先级（冲突处理）：
  1) 主排序键（用户最后一次选择）
  2) 次排序键：`start_at desc`
  3) 最终平局：`connection_id asc`

- 筛选与排序关系：
  - 先筛选后排序（pipeline 固定：filter -> sort -> render）
  - 清空筛选不影响当前排序键；再次按 `R`（重置视图）恢复默认排序。

反馈要求：
- 当前筛选条件常驻显示
- 空结果时显示“可执行建议”（例如清空筛选）
- 标题栏显示当前排序键与方向

## 2.3 Logs（日志过滤）
- `l`：切换日志级别过滤（all/debug/info/warn/error）
- `/`：关键字过滤
- `e`：仅错误日志（快捷设为 level=error）
- `a`：恢复全部（清空级别+关键字过滤）

### 日志过滤组合规则
- 支持“级别 + 关键字”组合过滤：
  - 固定 pipeline：`level -> keyword -> render`
- 级别集合：`all | debug | info | warn | error`
- 关键字匹配：大小写不敏感 contains

### 冲突优先级
1. 显式级别快捷键（`e`）优先于当前轮询级别（`l`）；
2. 关键字过滤永远在级别过滤之后执行；
3. 若级别为 `all`，则仅由关键字过滤决定结果；
4. 若关键字为空，退化为“仅级别过滤”。

### 清空与恢复全量流程（一步恢复）
1. 任意过滤状态下按 `a`；
2. 同时清空 level 与 keyword；
3. 立即恢复默认全量日志视图；
4. 底部状态条提示：`Logs reset to full stream`。

### 边界与空结果处理
- 若关键字为空字符串，视为“无关键字过滤”；
- 若级别为 `all` 且关键字为空，等价于全量；
- 无匹配结果时显示：
  - `No logs matched current filters`
  - 当前过滤条件回显（level/keyword）
  - 建议动作：`Press a to clear filters`。

### 用户操作示例（可映射实现/测试）
1. **组合过滤命中**
   - 操作：`l` 切到 `warn` -> `/` 输入 `timeout`
   - 预期：仅显示 warn 且包含 timeout 的日志

2. **空结果场景**
   - 操作：`l` 切到 `error` -> `/` 输入 `heartbeat-ok`
   - 预期：显示空结果提示 + `Press a to clear filters`

3. **一键恢复全量**
   - 操作：在任意过滤状态下按 `a`
   - 预期：恢复全量日志，状态条出现 `Logs reset to full stream`

反馈要求：
- 当前过滤器在标题栏可见（如 `level=warn keyword=timeout`）
- 日志滚动定位稳定，不因刷新丢失上下文

## 2.4 Diagnose（重载反馈）
- `R`：触发配置重载
- `v`：触发配置校验
- `p`：触发端口检测

### 重载状态流（P3-2.5A）
- 状态机：`idle -> running -> done | failed -> idle`
- 触发时机：
  - 用户按 `R` 后立即进入 `running`
  - 底层返回成功事件进入 `done`
  - 底层返回错误事件进入 `failed`
- 退出条件：
  - `done` 保留 2 秒后自动回到 `idle`
  - `failed` 保留到用户确认（`Enter`/`Esc`）后回到 `idle`

### 耗时与时间戳展示（P3-2.5B）
- 展示位置：
  1) 状态条（短摘要）
  2) 日志区（完整记录）
- 固定字段：
  - `action=reload`
  - `status=running|done|failed`
  - `cost_ms=<number>`
  - `at=<ISO8601>`
- 格式示例：
  - 状态条：`Reload done in 182ms @ 2026-02-11T09:28:10+08:00`
  - 日志区：`[reload] status=done cost_ms=182 at=2026-02-11T09:28:10+08:00`

### 失败提示与建议（P3-2.5C）
- 统一失败结构：`code/message/hint`
- 最小建议集（至少两类）：
  1) 配置错误类（`VALIDATION_*` / `CONFIG_*`）
     - hint: `run validate and fix config syntax/fields, then retry reload`
  2) 运行时错误类（`NETWORK_*` / `PROVIDER_*`）
     - hint: `check upstream/network health and retry reload`

反馈要求：
- 每个动作给出结果：成功/失败/耗时
- 失败时必须给 `下一步动作`（修复建议）

### 机器输出口径（与脚本实现对齐）
- `ROLLBACK_CHECK_RESULT=PASS|FAIL`
- `ROLLBACK_CHECK_STATUS=<running|done|failed|...>`
- `ROLLBACK_CHECK_COST_MS=<number>`
- `ROLLBACK_CHECK_REPORT=<path>`
- `ROLLBACK_CHECK_NEXT_STEP=<hint>`

### 验收命令（最小）
```bash
bash scripts/reliability/run-rollback-check.sh
```

---

## 3) 交互一致性约束

1. 同一按键在不同 Tab 不冲突；若局部重载必须明确提示。
2. 所有高风险动作（切换/重载）都需要可见反馈。
3. 搜索/过滤输入框的进入/退出行为在各 Tab 一致。

---

## 4) P3-2 实施顺序（建议）

1. 先做 Proxies：代理组切换 + 反馈（核心价值最高）
2. 再做 Connections：筛选体系（可观测效率提升）
3. 再做 Logs：过滤体系（排障效率提升）
4. 最后做 Diagnose：重载反馈闭环
