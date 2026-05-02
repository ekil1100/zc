# zc v1.0 Roadmap — code-first factual revision

> 生成时间：2026-05-02
> 最近更新：2026-05-03
> 原则：抛弃此前基于 `ROADMAP.md` / `TASKS.md` 的“已完成”结论，本版先按代码与本机验证结果重新判断。
> 范围：当前 v1.0 cleanup 工作区。

---

## 0. 本次事实检查结论

当前代码**仍不应直接 GA tag**。本轮 cleanup 已完成 Zig 0.16.0 工具链对齐、TUI de-scope、旧根目录 roadmap/tasks 移除和主要文档重整；剩余阻塞项集中在：

1. **配置层声明支持的部分代理类型未实现出站连接**：`http` / `socks5` 可被 parser 和 validator 接受，但 `OutboundManager.connectToProxy()` 对它们走 `NotImplemented`。
2. **CLI `test --json` 不生效**：入口识别 `--json`，但仍调用文本输出的 `test_cli.testProxy()`。
3. **API v1 仍是最小 REST 子集**：实际只有 `/`, `/version`, `/proxies`, `/rules`, `PUT /proxies/<group>`；当前文档只能承诺 minimal API，不能宣传 runtime / profiles / connections / metrics / WebSocket 事件流。
4. **日志系统未真正统一接入**：`src/logger.zig` 存在，但 `src/` 内仍有大量 `std.debug.print`。

因此，v1.0 roadmap 现在应聚焦：**关闭 HTTP/SOCKS5 outbound 策略与 `zc test --json` 两个 P0，再做最终 smoke gate 和 GA tag 判断。**

---

## 1. 本次验证命令与结果

### 环境与构建

```bash
zig version
# 0.16.0

cat build.zig.zon
# .version = "1.0.0-rc3"
# .minimum_zig_version = "0.16.0"
```

结果：本机是 Zig 0.16.0；包版本为 `1.0.0-rc3`；`build.zig.zon` 的 minimum zig 已对齐为 `0.16.0`。

### Zig 测试与 ReleaseFast 构建

```bash
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
# 63/63 tests passed

env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast --summary all
# succeeded
```

结果：当前代码在本机 Zig 0.16.0 下可构建、单测通过。

### 迁移与安装回归

```bash
bash tools/config-migrator/run-all.sh
# MIGRATOR_ALL_RESULT=PASS
# MIGRATOR_REGRESSION_SUMMARY=PASS total=29 failed_rules=0 failed_samples=0

bash scripts/install/run-all-regression.sh
# INSTALL_ALL_RESULT=PASS

bash scripts/run-full-validation.sh
# VALIDATION_RESULT=PASS
# VALIDATION_PASS=3/3
```

结果：脚本层 full validation 通过。

### CLI smoke

```bash
./zig-out/bin/zc --help
# zc v1.0.0-rc3

./zig-out/bin/zc status --json
# ok=true, state=stopped

./zig-out/bin/zc doctor --json
# ok=true, config_ok=true, daemon_running=false

./zig-out/bin/zc start --port 29001 -c testdata/config/minimal.yaml --json
./zig-out/bin/zc status --json
./zig-out/bin/zc stop --json
# start/status/stop 成功
```

结果：daemon 基础生命周期在非生产端口 smoke 通过。

### 发现的 CLI 契约问题

```bash
./zig-out/bin/zc test -c testdata/config/minimal.yaml --json
```

实际输出仍为文本报告，而非 JSON。代码路径：`src/main.zig` 的 `test` 分支无论 `json_output` 如何，最终都调用 `test_cli.testProxy()`。

---

## 2. 当前代码事实快照

### 2.1 CLI

代码入口：`src/main.zig`

已实现命令：

- `help`
- `tui`（已决定从 v1.0 范围砍掉；当前只是代码事实，后续需要移除）
- `start [-c <config>] [--port <port>]`
- `stop`
- `restart [-c <config>]`
- `status`
- `log [-n <lines>] [-f|--no-follow]`
- `config list|ls|download|update|use|dump|override`
- `proxy list|ls|select|test`
- `profile list|ls|select|test`
- `test [-c <config>]`
- `doctor [-c <config>]`
- `diag doctor [-c <config>]`

事实判断：

- `start/status/stop/doctor/proxy list` 的 JSON 路径存在且本机 smoke 可用。
- `test --json` 目前不符合 JSON 契约。
- `status --json` 在刚启动 daemon 后 `uptime_seconds` 和 `active_config` 仍可能为 `null`，需要决定这是允许语义还是缺陷。

### 2.2 配置解析与校验

代码入口：

- `src/config.zig`
- `src/config_validator.zig`

实际解析的核心字段：

- `port`
- `socks-port`
- `mixed-port`
- `allow-lan`
- `bind-address`
- `mode`
- `log-level`
- `external-controller`
- `proxies`
- `proxy-groups`
- `rule-providers`
- `rules`

实际支持的 proxy type enum：

- `direct`
- `reject`
- `http`
- `socks5`
- `ss`
- `vmess`
- `trojan`
- `vless`

实际支持的 proxy group type：

- `select`
- `url-test`
- `fallback`
- `load-balance`
- `relay`

实际支持的 rule type：

- `DOMAIN`
- `DOMAIN-SUFFIX`
- `DOMAIN-KEYWORD`
- `IP-CIDR`
- `IP-CIDR6`
- `GEOIP`
- `RULE-SET`
- `SRC-IP-CIDR`
- `DST-PORT`
- `SRC-PORT`
- `PROCESS-NAME`
- `MATCH`

重要差距：

- `dns:` 配置段没有被 `Config` 解析为运行时 DNS 配置；`src/dns/client.zig` 有 DNS client，但未形成完整 mihomo DNS 配置兼容。
- `redir-port` / `tproxy-port` 字段在 `Config` struct 中存在，但 parser 当前没有读取它们，运行时也没有对应 listener。
- validator 允许/校验的部分内容和运行时能力不完全一致。

### 2.3 入站 / 出站代理能力

入站：

- HTTP inbound：`src/proxy/http.zig`
- SOCKS5 inbound：`src/proxy/socks5.zig`
- mixed inbound：`src/proxy/mixed.zig`

运行时默认行为：

- `loadRuntimeConfig()` 会默认统一走 `mixed-port`。
- `zc start --port <n>` 会覆盖本次 daemon mixed port。
- `port` / `socks-port` 会在默认 runtime selection 中被清零。

出站：`src/proxy/outbound/manager.zig`

实际 `connectToProxy()` 已实现：

- `direct`
- `reject`
- `ss`
- `vmess`
- `trojan`
- `vless`

实际未实现但可被配置接受：

- `http`
- `socks5`

协议细节限制：

- Shadowsocks：`src/crypto/aead.zig` 实际只解析 `aes-128-gcm` / `aes-256-gcm` / `chacha20-poly1305` / `chacha20-ietf-poly1305`。validator 中列出的 CFB / rc4-md5 / none 等并非真实可用。
- VMess：当前 client 是最小 TCP 握手实现；`tls` / `ws-opts` 等配置字段未传入 VMess client。
- VLESS：文件注释明确是“最小可用版本，仅 TCP”；`tls` / ws / reality / grpc 等主流变体未实现。
- Trojan：实现 TLS + CONNECT；没有看到 Trojan WS / gRPC 等传输变体。
- HTTP / SOCKS5 出站未实现，是 1.0 兼容性硬缺口。

### 2.4 规则引擎

代码入口：`src/rule/engine.zig`

已具备：

- domain exact / suffix / keyword
- IP-CIDR / IP-CIDR6
- GEOIP 简化 lookup
- RULE-SET 展开后参与运行时规则
- DST/SRC port range 数据结构
- PROCESS-NAME / SRC-IP-CIDR 数据结构
- MATCH final

限制：

- HTTP CONNECT / HTTP forward 路径使用 `engine.match(host, true)`，没有传 `target_port`，因此 `DST-PORT` 对 HTTP/mixed HTTP 路径不生效。
- `PROCESS-NAME`、`SRC-IP-CIDR`、`SRC-PORT` 依赖上下文，但 proxy 调用处大多没有填这些上下文字段。
- rule engine 中仍有大量 debug prints，会污染运行日志与性能测量。
- IPv6 GEOIP 有 TODO。

### 2.5 API

代码入口：`src/api/server.zig`

实际 endpoint：

- `GET /`
- `GET /version`
- `GET /proxies`
- `GET /rules`
- `PUT /proxies/<group_name>`，body 里提取 `name`

限制：

- 没有 `/runtime`、`/profiles`、`/connections`、`/metrics` 实现。
- 没有 WebSocket 事件流。
- HTTP parser 是手写最小实现，一次 read 4096 bytes，未覆盖通用 HTTP server 边界。
- 错误结构是 `{"error":"..."}`，并非 CLI 中的 `code/message/hint` 结构。

### 2.6 TUI（v1.0 已砍，需清理）

代码入口：`src/tui.zig`

事实判断：

- 当前代码仍存在 terminal raw mode / alternate screen / mouse / tab state / render loop。
- `src/main.zig` 仍导入 `tui.zig`，并暴露 `zc tui` 命令与 help 文案。
- 有状态结构、日志高亮、代理组展示与选择相关逻辑。
- 连接列表、速度、延迟等数据更多是 TUI 本地状态；未看到完整 runtime metrics 采集链路。

v1.0 决策：

- **砍掉 TUI 功能，不作为 v1.0 发布能力。**
- 需要清理对应代码，而不是仅在文档中标 unsupported。
- 清理范围至少包括：`src/tui.zig`、`src/main.zig` 的 import/command dispatch/help 文案、TUI 相关 docs/README 入口、测试或 roadmap 中的 TUI 承诺。

### 2.7 日志

代码入口：`src/logger.zig`

事实判断：

- `Logger` 类型存在，支持 level、console/file 输出。
- 但 `src/` 中仍大量直接使用 `std.debug.print`，本次统计约 467 处。
- 还没有日志轮转、结构化 JSON 日志、统一 request/connection trace id。

### 2.8 CI / Release

代码入口：

- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`
- `build.zig.zon`
- `AGENTS.md`

事实：

- `AGENTS.md`：要求 Zig `0.16.0+`，CI 使用 `0.16.0`。
- `ci.yml`：实际 setup zig `0.16.0`。
- `release.yml`：实际 setup zig `0.16.0`。
- `build.zig.zon`：`minimum_zig_version = "0.16.0"`。

判断：P0-1 已完成代码与工作流层面的对齐；最终仍需由 GitHub Actions 实际 release job 验证。

---

## 3. 重新定义 v1.0 目标

v1.0 不应承诺“完整 mihomo/c 替代”。基于当前代码，建议 v1.0 目标收敛为：

> zc v1.0 是一个以 mixed inbound 为默认入口、支持核心规则匹配与主流加密代理出站的 Zig 代理运行时；提供稳定 CLI、最小 API、可验证安装链路、可回归构建测试，并对不支持的 mihomo/c 能力给出明确诊断和迁移提示。

### v1.0 必须承诺的能力

- 默认 mixed inbound 可启动、停止、重启、查看状态。
- 不发布 TUI；v1.0 只承诺 CLI + minimal API + daemon runtime。
- `zc start --port <port>` 非生产端口开发入口稳定。
- DIRECT / REJECT / Shadowsocks AEAD / VMess TCP / Trojan TLS / VLESS TCP 的边界清晰。
- 规则：DOMAIN / DOMAIN-SUFFIX / DOMAIN-KEYWORD / IP-CIDR / IP-CIDR6 / RULE-SET / MATCH 稳定可用。
- 配置解析失败、端口冲突、provider 下载失败有可操作错误。
- `doctor --json` 可作为最小诊断包。
- install / verify / upgrade / rollback 脚本回归通过。
- CI / release workflow 与本地 Zig 版本一致。

### v1.0 不应承诺或必须明确标注 experimental/unsupported 的能力

- TUI 交互界面（v1.0 已砍，代码也要清理）。
- 完整 API v1 资源模型与 WebSocket 事件流。
- TUN / redir / tproxy。
- 完整 mihomo DNS 行为，包括 fake-ip、enhanced-mode、nameserver-policy 等。
- HTTP / SOCKS5 出站，除非 v1.0 前补实现。
- VMess/VLESS 的 TLS/WS/Reality/gRPC 等完整传输生态，除非 v1.0 前补实现。
- 完整日志系统、日志轮转、结构化日志。

---

## 4. v1.0 发布阻塞项（P0）

### P0-1：修正 CI / Release Zig 版本链路

范围：

- `.github/workflows/ci.yml`
- `.github/workflows/release.yml`
- `build.zig.zon`
- README / docs 中 Zig 版本说明

验收标准：

- CI workflow 使用 Zig `0.16.0`。
- Release workflow 使用 Zig `0.16.0`。
- `build.zig.zon` minimum zig 与当前支持策略一致，至少不低于 `0.16.0`。
- 本地执行：

  ```bash
  env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
  env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast --summary all
  bash scripts/run-full-validation.sh
  ```

- workflow 中不再出现 `0.15.2`。

### P0-2：修正“配置可接受但出站未实现”的协议声明

必须二选一：

A. v1.0 前实现 HTTP / SOCKS5 outbound；或  
B. parser / validator / docs / migrator 明确把 HTTP / SOCKS5 outbound 标为 unsupported，避免用户配置通过但运行时报 `NotImplemented`。

建议：v1.0 走 B，1.1 再做 A。因为 HTTP/SOCKS5 outbound 看似简单，但需要认证、CONNECT、UDP、错误映射和回归。

验收标准：

- `zc test` / `doctor` / config validation 能提前暴露 unsupported outbound，而不是运行时连接时才失败。
- README 的代理协议兼容表与代码一致。
- migrator 对 http/socks5 outbound 给出明确 warning/error 和 next-step。
- 新增回归测试覆盖 `http` / `socks5` outbound 配置的行为。

### P0-3：修正 CLI JSON 契约：`zc test --json`

范围：

- `src/main.zig`
- `src/test_cli.zig`
- `docs/cli/spec.md`
- tests

验收标准：

- `zc test --json` 输出合法 JSON。
- JSON 包含：`ok`、`action=test`、`ports`、`checks`、`errors/warnings`、`next_step`。
- 文本输出保持原行为。
- 新增 CLI 行为测试。

### P0-4：TUI de-scope 与代码清理

决策：v1.0 砍掉 TUI，不发布 `zc tui`。

范围：

- 删除或隔离 `src/tui.zig`，确保 v1.0 默认构建不编译 TUI 代码。
- 移除 `src/main.zig` 中的 `tui` import、`zc tui` command dispatch、help 文案和示例。
- 清理 README / docs / ROADMAP / TASKS 中把 TUI 作为 v1.0 能力的描述。
- 同步纳入历史无用文档清理：旧 TUI 草稿、过期 1.0 候选清单、与当前发布口径不一致的 skill/agent 辅助说明、历史乐观 roadmap 结论。
- 如果保留未来 TUI 方向，只能放到 v1.1+ backlog，不能出现在 v1.0 help 和用户文档中。

验收标准：

- `./zig-out/bin/zc --help` 不再出现 `tui`。
- `zc tui` 返回明确的 unknown command 或不再存在该入口。
- `grep -R "@import(\"tui.zig\")\|zc tui\|Start TUI" -n src README.md docs AGENTS.md` 不再命中 v1.0 用户可见承诺；如历史记录需要保留，必须位于 `docs/archive/` 并明确标注非当前承诺。
- `zig build test --summary all` 通过。
- `zig build -Doptimize=ReleaseFast --summary all` 通过。

### P0-5：历史无用文档清理与归档

目标：v1.0 发布前，只保留与当前 code-first 结论一致、用户可执行、用户可验证的文档。

范围：

- 删除或归档根目录旧 `ROADMAP.md` / `TASKS.md`：它们不再作为 canonical 计划源；当前 1.0 计划以 `.agents/zc-v1.0-roadmap.md` 为事实检查与执行依据，后续可发布为 `docs/roadmap/v1.0.md` 或 `docs/README.md` 索引入口。
- 重整 `docs/` 信息架构，只保留与 v1.0 发布相关、用户可执行、用户可验证的文档。
- 清理或归档 `docs/tui/`、旧交互草稿、过期 keymap/interaction 文档。
- 清理 `docs/roadmap/`、`docs/benchmark/`、`docs/compat/`、`docs/install/` 中与当前 v1.0 范围冲突的旧描述。
- 清理历史生成的无用 agent 文档、草稿、临时结论；如保留，必须移动到 archive 并标注“历史记录，不代表当前 v1.0 承诺”。
- 清理与当前任务无关或误触发的 skill 相关说明/痕迹，避免把 agent 操作过程暴露为产品文档承诺。
- 保留真正有价值的事实检查、验收命令和发布 gate；删除重复、过期、不可验证内容。

建议整理后的 `docs/` 结构：

```text
docs/
  README.md                 # 文档总入口：v1.0 能力、限制、下一步
  cli/                      # CLI 使用与 JSON 契约
  config/                   # 配置字段、override、兼容限制
  compat/                   # mihomo/clash 迁移边界与 migrator 规则
  install/                  # install/verify/upgrade/rollback
  api/                      # minimal API 实际 endpoint，不再宣传完整 API v1
  reliability/              # smoke/soak/release gate
  archive/                  # 历史草稿；不代表当前 v1.0 承诺
```

根目录建议只保留：

- `README.md`：用户入口
- `AGENTS.md`：协作规则，但需更新为“计划以 `.agents/zc-v1.0-roadmap.md` / `docs/roadmap/v1.0.md` 为准”
- `CHANGELOG.md`：发布记录
- 删除或归档：`ROADMAP.md`、`TASKS.md`、其他已过期 agent/Claude 草稿文档

验收标准：

- README 是唯一用户入口，指向的 docs 均与 v1.0 范围一致。
- 根目录 `ROADMAP.md` / `TASKS.md` 已删除或移动到 `docs/archive/`，且不再被 `AGENTS.md` 声明为 canonical。
- `docs/README.md` 存在并能解释当前文档结构；过期文档只允许存在于 `docs/archive/`。
- `grep -R "zc tui\|TUI\|GA-ready\|ready for GA\|完整 API v1\|WebSocket 事件流" -n README.md docs AGENTS.md` 的命中要么清零，要么全部位于明确 archive/历史上下文。
- `grep -R "ROADMAP.md\|TASKS.md" -n README.md docs AGENTS.md .agents/zc-v1.0-roadmap.md` 不再把旧根目录文件描述为当前 canonical 计划源。
- 文档清理后重新跑 `bash scripts/run-full-validation.sh`，确认脚本文档引用未断。

### P0-6：发布前最终 smoke gate

范围：

- 本机命令
- CI workflow
- release dry-run 或 tag 前脚本

验收标准：

```bash
git status --short --branch
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast --summary all
bash tools/config-migrator/run-all.sh
bash scripts/install/run-all-regression.sh
bash scripts/run-full-validation.sh
./zig-out/bin/zc start --port 29001 -c testdata/config/minimal.yaml --json
./zig-out/bin/zc status --json
./zig-out/bin/zc stop --json
```

全部通过后，才允许进入 tag 确认。

---

## 5. v1.0 应收敛项（P1）

这些不一定阻止发布，但应在 v1.0 roadmap 中明确取舍。

### P1-1：API v1 降级为 “minimal API”，或补齐资源模型

建议：v1.0 文档中把当前 API 标为 minimal / experimental，不承诺完整 API v1。

验收标准：

- README / docs 明确列出实际 endpoint。
- OpenAPI 与代码实际 endpoint 一致。
- 错误结构是否采用 `code/message/hint` 做出明确决定。

### P1-2：规则上下文一致性

问题：rule engine 支持 `DST-PORT` / `SRC-*` / `PROCESS-NAME`，但 proxy 调用没有完整上下文。

v1.0 建议：

- 必须保证 `DST-PORT` 至少在 mixed SOCKS 与 HTTP CONNECT/forward 路径一致可用；或文档标明限制。
- `PROCESS-NAME` 可标为 unsupported / best-effort。

验收标准：

- 新增 `DST-PORT` 走 mixed HTTP CONNECT 的回归测试。
- 文档说明 `SRC-IP-CIDR` / `SRC-PORT` / `PROCESS-NAME` 当前可用范围。

### P1-3：状态输出字段可信度

问题：daemon running 后 `status --json` 中 `uptime_seconds` / `active_config` 可能为 `null`。

验收标准：

- running 状态下 `pid` 必须非空。
- `uptime_seconds` 要么可靠给出，要么文档明确平台限制。
- `active_config` 要么写入 runtime meta，要么从 schema 移除/标 optional。

### P1-4：日志噪声与性能门禁

问题：大量 `std.debug.print` 分布在热路径，包括 rule engine、SS、mixed relay。

v1.0 建议：

- 不要求完整日志系统，但必须降低热路径无条件 debug 输出。

验收标准：

- ReleaseFast 下默认 info 运行不输出 per-packet/per-match debug。
- 关键 debug 通过 log level 控制。
- 至少 rule engine / mixed / shadowsocks 热路径完成收口。

---

## 6. v1.1 延后项（P2）

以下建议从 v1.0 剥离，进入 v1.1 或后续：

- 完整 API v1 + WebSocket event stream。
- HTTP / SOCKS5 outbound 完整实现，如果 v1.0 选择先标 unsupported。
- VMess / VLESS 的 TLS / WS / Reality / gRPC 支持。
- mihomo DNS 完整兼容：`dns:` section、fake-ip、enhanced-mode、nameserver-policy。
- TUN / redir / tproxy。
- 统一 logger、日志轮转、JSON logs、trace id。
- TUI 如未来恢复，按 v1.1+ 新功能重新设计，不继承当前未收口实现。

---

## 7. 新版 v1.0 roadmap

### RC4：发布链路修复与能力声明对齐

目标：确保 tag 后 CI/CD 不会因为工具链或声明不一致失败。

任务：

1. P0-1 修正 CI / release / package Zig 版本。
2. P0-2 对齐 outbound 协议声明：HTTP/SOCKS5 outbound 实现或明确 unsupported。
3. P0-3 补 `zc test --json`。
4. P0-4 砍掉 TUI 并清理对应代码 / help / docs。
5. P0-5 清理或归档历史无用文档，包括删除/归档旧 `ROADMAP.md` / `TASKS.md`、重整 `docs/` 信息架构、清理过期 TUI 草稿、旧 GA-ready 结论和无关 skill/agent 辅助说明。
6. 更新 README 的代理协议兼容性表。
7. 更新 `AGENTS.md`：移除旧 `ROADMAP.md` / `TASKS.md` 作为 canonical 的流程要求，改为当前 v1.0 roadmap / docs 结构。

退出标准：

- 本地 full validation 通过。
- workflow grep 不再出现 `0.15.2`。
- 协议兼容声明和代码行为一致。

### RC5：运行时一致性与低噪声

目标：让核心运行时语义可信。

任务：

1. `DST-PORT` 在 mixed HTTP CONNECT/forward 路径补齐 `target_port`。
2. running 状态下 `status --json` 字段语义收敛。
3. 热路径 debug print 降噪。
4. API 文档降级为 minimal API 或补齐实际 OpenAPI。

退出标准：

- 新增规则上下文回归测试通过。
- `zc start/status/doctor/test/proxy list --json` 行为可回归。
- ReleaseFast smoke 无明显热路径噪声。

### GA：v1.0.0 tag

前置条件：

```bash
git status --short --branch
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast --summary all
bash scripts/run-full-validation.sh
./zig-out/bin/zc start --port 29001 -c testdata/config/minimal.yaml --json
./zig-out/bin/zc status --json
./zig-out/bin/zc stop --json
```

发布动作：

```bash
git tag v1.0.0
git push origin v1.0.0
```

发布后验证：

- GitHub Actions release job 使用 Zig 0.16.0。
- Linux amd64 / macOS arm64 artifact 生成。
- release asset SHA256 存在。
- Homebrew tap 更新成功或失败时有可操作 next-step。
- 安装脚本能从 release artifact 完成 install / verify。

---

## 8. 建议立即执行的下一步

按风险排序：

1. **决定 HTTP/SOCKS5 outbound 策略**：实现还是标 unsupported；建议先标 unsupported，并同步 validator / doctor / migrator / README。
2. **补 `zc test --json`**：这是 CLI 契约破口，范围相对小。
3. **复跑最终 smoke gate**：确认构建、install、migrator、full validation、daemon start/status/stop 均通过。
4. **等待 GitHub Actions 验证 release job**：P0-1 本地配置已对齐，但 tag 前仍需确认远端 release 构建实际通过。

---

## 9. 当前最终判断

当前 main 分支：

- ✅ Zig 0.16 本地构建通过
- ✅ 单测 63/63 通过
- ✅ full validation 通过
- ✅ 非生产端口 daemon start/status/stop smoke 通过
- ✅ CI / release workflow Zig 版本已对齐到 0.16.0
- ✅ TUI 已从 v1.0 代码入口、help 和 active docs 中移除
- ✅ 旧 `ROADMAP.md` / `TASKS.md` 和过期 TUI/API/install 草稿已删除或归档
- ❌ 部分配置可接受但运行时未实现
- ❌ `zc test --json` 不符合 JSON 契约
- ✅ API 已按 minimal API 口径进入 active docs；旧完整 OpenAPI 草案归档

结论：

> **暂不建议立即打 `v1.0.0` tag。先关闭 HTTP/SOCKS5 outbound 策略与 `zc test --json` 两个 P0，再进入最终 GA gate。**
