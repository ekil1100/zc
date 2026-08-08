# zc v1.0 Roadmap — code-first factual revision

> 生成时间：2026-05-02
> 最近更新：2026-08-08
> 原则：抛弃此前基于 `ROADMAP.md` / `TASKS.md` 的“已完成”结论，本版先按代码与本机验证结果重新判断。
> 范围：当前 v1.0 cleanup 工作区。

---

## 0. 本次事实检查结论

当前代码**仍不应直接 GA tag**。本轮 cleanup 已完成 Zig 0.16.0 工具链对齐、TUI de-scope、旧根目录 roadmap/tasks 移除和主要文档重整；剩余阻塞项集中在：

1. **配置准入与已验证运行能力必须持续一致**：`http` / `socks5` 未实现；VMess/VLESS wire/transport 未通过标准互操作；AnyTLS 生命周期与资源上界仍有安全阻断项。Shadowsocks simple-obfs HTTP 已于 2026-08-06 开放；classic AEAD UDP 已于 2026-08-08 通过独立 wire、真实 mixed socket、资源、生命周期与固定版本互操作门禁后精确开放。
2. ~~**CLI `test --json` 不生效**~~（已解决：全 CLI 输出契约对齐落地，`test --json` 走统一 envelope + `CHECKS_FAILED` 语义，见 `docs/cli/spec.md`）。
3. **API v1 冻结为有界 minimal REST 子集**：实际只有 `/`, `/version`, `/proxies`, `/rules`, `PUT /proxies/<group>`；连接数、header/body/response 大小和读写期限均有固定上界。当前文档只能承诺 minimal API，不能宣传 runtime / profiles / connections / metrics / WebSocket 事件流。
4. **日志系统未真正统一接入**：`src/logger.zig` 存在，但 `src/` 内仍有大量 `std.debug.print`。
5. **代理选择与 managed config 命令族已接 Authority**：CLI durable-first、daemon 启动恢复 desired state，并通过 exact revision runtime descriptor 发现实际 controller endpoint；legacy mirror 仅为派生兼容面。
6. **minimal controller 端点已冻结**：v1 只接受显式 `127.0.0.1:<port>`，必须绑定精确配置端口；冲突时启动失败，不自动漂移或静默关闭控制面。
7. **生命周期路径已按用户隔离并具备 instance-bound restart rollback**：pid/lock/log/runtime descriptor 统一位于经 owner/mode/no-follow 校验的 `XDG_RUNTIME_DIR`；未设置时使用规范化 `$HOME/.local/state/zc/runtime`。后台启动只消费 parent 发布的 owner-only HMAC snapshot；restart 在 stop 前完成 preparation，并以 PID/nonce 恢复 exact old snapshot。

因此，v1.0 roadmap 现在应聚焦：**保持统一 capability gate 与已验证的 Shadowsocks TCP/UDP 边界；完成 P0-6 的 revisioned config identity、可靠代理选择和本地 config import；修复剩余安全审计阻断项后，再做最终 smoke gate 和 GA tag 判断。**

---

## 1. 本次验证命令与结果

### 环境与构建

```bash
zig version
# 0.16.0

cat build.zig.zon
# .version = "1.0.0-rc6"
# .minimum_zig_version = "0.16.0"
```

结果：2026-07-20 本机是 Zig 0.16.0；包版本为 `1.0.0-rc6`；`build.zig.zon` 的 minimum zig 已对齐为 `0.16.0`。

### Zig 测试与 ReleaseFast 构建

```bash
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
# 666/666 tests passed (0 skipped)

env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast --summary all
# 4/4 steps succeeded
```

结果：2026-07-20 当前代码在本机 Zig 0.16.0 下可构建，666/666 测试通过（0 skipped）；默认 `zig build test` 已包含 StateAuthority schema-2 typed mutations、ConfigBundle、RevisionStore、legacy bootstrap/mirror、exact loader 与 runtime descriptor 安全边界测试。

### Shadowsocks UDP capability gate（2026-08-08，Darwin arm64）

在 capability-enable 当前树上执行：

```bash
zig build test --summary all
# 20/20 steps succeeded; 1059/1059 tests passed

zig build test -Doptimize=ReleaseFast --summary all
# 20/20 steps succeeded; 1059/1059 tests passed

zig build e2e --summary all
# 15/15 steps succeeded; 46/46 oracle tests passed; CORE_E2E_RESULT=PASS

zig build e2e-release -Doptimize=ReleaseFast --summary all
# 15/15 steps succeeded; 46/46 oracle tests passed; CORE_E2E_RESULT=PASS

zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast
zig build -Dtarget=aarch64-linux-musl -Doptimize=ReleaseFast
zig build -Dtarget=x86_64-macos -Doptimize=ReleaseFast
# all passed

prefix=/tmp/zc-ss-udp-linux-x86_64-release
rm -rf "$prefix"
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseFast \
  --prefix "$prefix"
find "$prefix" -mindepth 1 -print | LC_ALL=C sort
# /tmp/zc-ss-udp-linux-x86_64-release/bin
# /tmp/zc-ss-udp-linux-x86_64-release/bin/zc
file "$prefix/bin/zc"
# ELF 64-bit LSB executable, x86-64, version 1 (SYSV), statically linked, with debug_info, not stripped
find "$prefix" -type f ! -path "$prefix/bin/zc" -print | wc -l
# 0
find "$prefix" -type l -print | wc -l
# 0

bash tools/config-migrator/run-regression.sh
# MIGRATOR_REGRESSION_SUMMARY=PASS total=29 failed_rules=0 failed_samples=0

bash scripts/install/run-all-regression.sh
# INSTALL_ALL_RESULT=PASS

bash scripts/run-full-validation.sh
# VALIDATION_RESULT=PASS
# VALIDATION_PASS=3/3
```

真实 E2E 明确输出 `E2E_SS_UDP_RESPONSE_DROP_RECOVERY`、`E2E_SS_UDP_INDEPENDENT_THREE_CIPHER_ADDRESS_MAX`、`E2E_SS_UDP_MALFORMED_PIN_AND_CONTROL_LIFECYCLE`、`E2E_SS_UDP_NO_DIRECT_OR_LEAF_FALLBACK`、`E2E_SS_UDP_SIMPLE_OBFS_TCP_BYPASS`、`E2E_SS_UDP_SHADOWSOCKS_RUST_V1_24_0_THREE_CIPHER` 与 `E2E_SS_UDP_CAPACITY_64_PLUS_1_RELEASE` 全部 `PASS`。ReleaseFast Linux x86_64 install prefix 仅包含 statically linked `bin/zc`；oracle/vector generator 未安装。

### 迁移、安装与完整回归（2026-07-20）

本轮 release-candidate 准备已重新执行以下 gate：

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

结果：2026-07-20 migrator 29/29 samples、install regression 与 full validation 3/3 均通过。

### CLI smoke

```bash
./zig-out/bin/zc --version
# zc 1.0.0-rc6

# 在隔离 HOME / XDG_RUNTIME_DIR 下执行
./zig-out/bin/zc start --port 29001 -c testdata/config/minimal.yaml --json
./zig-out/bin/zc status --json
./zig-out/bin/zc stop --json
# SMOKE_RESULT=PASS
```

结果：2026-07-20 在隔离状态目录中完成 29001 start/status/stop smoke，未干扰当前机器的 tracked daemon 或生产保留端口。该结果只支持发布 `v1.0.0-rc6`，不关闭 P0-2、P0-6 或 `v1.0.0` GA gate。

### 已关闭的 CLI 契约问题

`zc test --json` 已走统一 JSON envelope、`CHECKS_FAILED` 和非零退出语义；当前契约见 `docs/cli/spec.md`。

---

## 2. 当前代码事实快照

### 2.1 CLI

代码入口：`src/main.zig`

已实现命令：

- `help` / `version`
- `start|up [-c <config>] [--port <port>] [--foreground]`
- `stop|down`
- `restart [-c <config>]`
- `reload`
- `status`
- `log [-n <lines>] [-f|--no-follow]`
- `config list|ls|download|update|use|delete|dump|override`
- `proxy list|ls|select|test`
- `profile list|ls|select|test`
- `test [-c <config>]`
- `doctor [-c <config>]`
- `diag doctor [-c <config>]`

事实判断：

- `start/status/stop/doctor/proxy list` 的 JSON 路径存在且本机 smoke 可用。
- `test --json` 已符合 JSON 契约（统一 envelope、stdout、`CHECKS_FAILED` + 非零退出）。
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
- `anytls`

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

`connectToProxy()` 中存在代码路径：

- `direct`
- `reject`
- `ss`
- `vmess`
- `trojan`
- `vless`
- `anytls`

但“存在代码路径”不等于 v1.0 支持。v1.0 capability gate 只允许：

- `direct`
- `reject`
- Shadowsocks AEAD：`aes-128-gcm` / `aes-256-gcm` / `chacha20-poly1305` / `chacha20-ietf-poly1305`，支持 plain/simple-obfs HTTP TCP，以及 `udp:true` 节点经 mixed SOCKS5 UDP ASSOCIATE 的 classic AEAD UDP
- Trojan TCP/TLS

以下类型在 v1.0 必须由 validator/doctor/runtime 一致地提前拒绝：

- `http`
- `socks5`
- `vmess`
- `vless`
- `anytls`

协议细节限制：

- Shadowsocks：`src/crypto/aead.zig` 实际只解析 `aes-128-gcm` / `aes-256-gcm` / `chacha20-poly1305` / `chacha20-ietf-poly1305`。simple-obfs 仅开放 HTTP 且只包装 TCP；classic UDP 直接使用同一 server endpoint。TLS、通用外部 plugin、AEAD-2022、standalone SOCKS UDP 与 fragmentation 明确拒绝。validator 中列出的 CFB / rc4-md5 / none 等并非真实可用。
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

### 2.6 TUI（v1.0 已完成 de-scope）

事实判断：

- 当前 `src/main.zig` / `src/cli/commands.zig` 不再暴露 `zc tui`。
- v1.0 active docs 不再承诺 TUI；历史资料只允许位于 `docs/archive/`。
- TUI 不参与本计划，也不得因 selection/connection tracking 工作重新引入。

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

判断：P0-1 已完成代码与工作流层面的对齐；2026-07-20 GitHub Actions 已通过 `v1.0.0-rc6` 三平台 release 实际验证。

---

## 3. 重新定义 v1.0 目标

v1.0 不应承诺“完整 mihomo/c 替代”。基于当前代码，建议 v1.0 目标收敛为：

> zc v1.0 是一个以 mixed inbound 为默认入口、支持核心规则匹配与主流加密代理出站的 Zig 代理运行时；提供稳定 CLI、最小 API、可验证安装链路、可回归构建测试，并对不支持的 mihomo/c 能力给出明确诊断和迁移提示。

### v1.0 必须承诺的能力

- 默认 mixed inbound 可启动、停止、重启、查看状态。
- 不发布 TUI；v1.0 只承诺 CLI + minimal API + daemon runtime。
- `zc start --port <port>` 非生产端口开发入口稳定。
- DIRECT / REJECT / Shadowsocks AEAD TCP（plain 或经验证的 simple-obfs HTTP）、mixed SOCKS5 上的 classic Shadowsocks AEAD UDP 与 Trojan TCP/TLS 边界清晰；未验证的 transport/协议仍在 bind/dial 前 fail closed。
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
- HTTP / SOCKS5 / VMess / VLESS / AnyTLS 出站；只有固定版本的独立互操作、资源上界和生命周期测试全部通过后，才能逐个重新启用。
- 完整日志系统、日志轮转、结构化日志。

---

## 4. v1.0 发布阻塞项（P0）

### P0-1：修正 CI / Release Zig 版本链路 — Done

状态：代码、CI/release workflow 与 package minimum 已统一到 Zig 0.16.0；保留以下 DoD 作为发布回归。

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

### P0-2：统一 v1 capability gate — verified Shadowsocks expansion done

Shadowsocks 三阶段扩展已按顺序完成：

1. ~~完成内置 simple-obfs HTTP 流式 transport~~（done）；
2. ~~通过独立互操作后，仅开放 `plugin: obfs|obfs-local` + 显式 `mode: http` + 合法 host~~（done）；
3. ~~完成经典 Shadowsocks AEAD UDP 与 mixed SOCKS5 UDP ASSOCIATE~~（done）。

`mode: tls`、通用 SIP003 外部插件、AEAD-2022、UDP fragmentation、HTTP/SOCKS5/VMess/VLESS/AnyTLS outbound 仍不在本次范围，必须在 bind/dial 前 hard reject。协议代码保留不构成支持声明。

HTTP capability 的公开测试 seam 使用真实 ReleaseSafe zc 和真实 socket：配置经过公开 CLI preflight，TCP 分别通过 mixed HTTP/SOCKS5 到 test-only 独立 obfs oracle，再转发固定 `shadowsocks-rust v1.24.0` 与 origin。oracle 不导入生产 config/SS/obfs 模块，独立校验 GET/Host/Upgrade/Connection/Key/Content-Length，并覆盖分片响应 header 与 same-write tail。TLS/unknown/missing/CRLF 负例在 bind/dial 前失败且 oracle counter 不增长。

UDP capability 的公开 seam 使用独立 Node crypto literal-vector generator、只导入 Zig `std`/`builtin` 的 test-only UDP oracle、真实 ReleaseSafe zc mixed SOCKS5 UDP ASSOCIATE、dual-stack echo 与固定 `shadowsocks-rust v1.24.0 -U`。三算法及配置 alias 完成 IPv4/domain/IPv6 双向互通，并覆盖 bad tag、截短 salt/tag、RSV/FRAG/ATYP/长度、65507/max+1、client IP/source port pin、control close、64+1 capacity、`udp:false` REP 07、DIRECT/非 UDP leaf teardown 和 simple-obfs TCP-only bypass。研究依据见 `docs/research/shadowsocks-simple-obfs-udp.md`。

验收标准：

- simple-obfs HTTP 首次请求与首次响应 header 支持任意 TCP 切分，8 KiB 上限，header 后同 read 的 Shadowsocks bytes 不丢失；后续 bytes 为 raw stream；host 拒绝空值、CR/LF/NUL 和超过 255 bytes。
- capability 仅接受 `obfs` / `obfs-local`、显式 `mode: http` 与合法 host；`tls`、未知 mode/plugin 不得回退为裸 Shadowsocks。
- **UDP wire seam**：Shadowsocks UDP 使用独立 2017 datagram AEAD wire；每包 CSPRNG salt、HKDF-SHA1 `ss-subkey`、零 nonce、空 AAD，认证失败静默丢弃，不复用 TCP chunk framing。实际算法为 AES-128-GCM、AES-256-GCM、ChaCha20-IETF-Poly1305；`chacha20-poly1305` 仅为同一 wire 的配置 alias。
- **UDP association seam**：仅 mixed ingress 支持 SOCKS5 UDP ASSOCIATE；全局最多 64 个 association，300 秒 awake-clock idle，单个 wire datagram 最多 65507 bytes。association 绑定 control TCP 与客户端 IP，并由首个完全合法的数据报锁定 UDP source port；control close 立即清理；RSV 非零、FRAG 非零、坏 ATYP/长度均丢弃。
- **UDP ownership seam**：relay 不设置应用层 datagram queue，数据面不得每包分配；kernel socket queue 是唯一排队点。首个合法目标只选择一次 proxy；DIRECT、group→DIRECT 与不支持 UDP 的 leaf 都必须 teardown，绝不 fallback。
- simple-obfs 只包装 TCP；UDP 直接发往同一 Shadowsocks server UDP endpoint。AEAD-2022、standalone `socks-port` UDP、Trojan/AnyTLS UDP 与 fragmentation 均保持关闭。
- capability 已在独立 literal vectors、真实 mixed socket、固定 `shadowsocks-rust v1.24.0 -U` 三算法互操作、错误 tag/RSV/FRAG/超限/关闭/64+1 生命周期门禁全部通过后，以独立变更开放。
- `zc test` / `doctor` / config validation 使用同一 capability 结论；runtime manager 保留第二道 fail-closed 防线。
- README、compat matrix、错误码与代码一致；E2E 同时覆盖四个 Shadowsocks cipher 配置名、两个 obfs HTTP alias、独立 TCP/UDP wire attestation、固定外部实现、bind/dial 前负例及 UDP 生命周期/资源边界。

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

后续扩展（已完成）：全 CLI 输出契约对齐已落地 —— 全命令 stdout 统一 `{"ok","command","data"|"error"}` envelope、退出码 0/1/2 统一、生成式帮助、`zc reload`/`up`/`down`/`version`/`--foreground`/`--no-color`、`test`/`doctor` 失败 `CHECKS_FAILED` + 非零退出、移除 ps/pgrep 全局 daemon 发现（D12）。契约见 `docs/cli/spec.md`，验收记录见 `docs/cli/ux-workflow.md`，事实基线见 `.agents/cli-ux-baseline.md`。该项不解除其余 GA gate（P0-2 outbound 策略与最终 smoke gate 仍未关闭）。

### P0-4：TUI de-scope 与代码清理 — Done

状态：`zc tui` 已从当前代码入口、生成式 help 和 active docs 移除；以下范围与验收保留为回归记录。

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

### P0-5：历史无用文档清理与归档 — Done

状态：旧根目录 roadmap/tasks 和 TUI/完整 API 草案已删除或归档，当前入口已收敛；以下清单保留为回归记录。

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

### P0-6：revisioned config identity、可靠代理选择与本地 config import

状态：**In Progress；durable `proxy select`、`config load <path>` 与其余 managed CLI writer cutover 已实现，最终 fault/crash、ReleaseFast 与 smoke 门禁尚未完成**。

目标：

- durable desired selection 成为唯一权威状态，daemon runtime 通过 generation 对账；
- 配置 identity 从不稳定的 key/path 推导升级为 `managed key + revision`；
- `proxy select` 明确区分 persisted、runtime applied 和连接关闭结果；
- 新增 CLI-only `zc config load <path>`，把本地完整配置及 source root 内依赖复制为托管 immutable bundle 并设为 active；
- 所有 transport 接入 owner-safe flow tracking 后，才开放显式 `--close-connections`；
- 不新增 TUI、配置上传 API、`profile import` 或隐式 reload/restart。

冻结契约、分批实施、回滚点、测试矩阵与性能门禁见：

- [`.agents/proxy-selection-config-import-plan.md`](proxy-selection-config-import-plan.md)

当前内部证据：

- Batch 1 transactional authority：`b940f5d`，hardening `9492bbf` / `f06de95` / `f21fa8d`；
- Batch 2 managed parser/offline provider：`d4e2d84`；
- Batch 2 descriptor-based ConfigBundle/resolver：`65337fc`；
- Batch 3 exact catalog / immutable RevisionStore / legacy bootstrap / frozen override / derived mirror：`052610f`–`01646d1`；
- Batch 4 shadow exact loader / tracked runtime descriptor seams：`041578b`–`ee690e7`；
- Batch 5 typed mutation、catalog coordinator/commands、downloaded writer 与 revisioned override writer：`0684a88`、`90e21b7`、`b81227c`、`ad4ce7f`、`1c2eb78`、`aabd81e`、`cdf7497`、`62d8a1e`、`f2eb2b4`；
- 当前 755/755 tests passed（0 skipped）；最新 catalog/lifecycle hardening 后的 ReleaseFast 跨目标复验待完成；
- `main`/daemon/proxy CLI 已接 durable selection、startup restore、exact runtime descriptor 与完整 managed config 命令族；`load/list/download/update/use/delete/dump/override` 以 catalog v2 为唯一 authority，legacy `meta.json` / `configs/` 只由 mirror 刷新。subscription update 使用读取 URL 时的 exact revision 做 CAS，persistent override 以 frozen immutable revision 发布。

关键验收：

- CLI → daemon → manager → durable state → restart 的选择回归通过；
- daemon 启动在开放监听前完成 desired/runtime 对账；
- 离线、其他 key、旧 revision、identity unverified、apply failed 均有稳定 exit/JSON 语义；
- desired/runtime/selected/resolved 可同时观测，旧字段仅作兼容投影；
- `config load` 导入后设为 active 但不 apply；active key 只推进 catalog identity，旧 runtime 不自动切换；
- 主配置 16 MiB 边界、bundle containment、symlink、离线验证、remote provider 零网络和 fault atomicity 有自动化证据；
- `--close-connections` 精确覆盖旧 generation 的 TCP/UDP/逻辑 flow，不误关共享物理连接，恢复时不重放；
- 默认连接路径、flow registry、close storm 和控制面事务通过真实 ReleaseFast 性能门禁。

文档策略：规划阶段只更新 roadmap；`docs/cli/spec.md`、minimal API 和错误码当前契约必须等行为测试通过后在同一逻辑 commit 更新。

### P0-7：发布前最终 smoke gate

范围：

- 本机命令
- CI workflow
- release dry-run 或 tag 前脚本
- standalone/static release artifact 与根目录 `install.sh`
- 只在 pull request 与 version tag 执行的真实进程/网络 E2E

验收标准：

```bash
git status --short --branch
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast --summary all
bash tools/config-migrator/run-all.sh
bash scripts/install/run-all-regression.sh
bash scripts/install/test-oneline-installer.sh
bash scripts/run-full-validation.sh
zig build e2e
./zig-out/bin/zc start --port 29001 -c testdata/config/minimal.yaml --json
./zig-out/bin/zc status --json
./zig-out/bin/zc stop --json
```

`install.sh` 必须从版本化 GitHub Release 下载 Linux/macOS amd64/arm64 standalone
归档，严格校验 SHA-256，并在校验、自检或安装失败时保留旧二进制。Linux 发布物必须
是静态 musl ELF。E2E 只通过 `zc` CLI、mixed HTTP/SOCKS5 与 minimal API 公共接口
验证 catalog、DIRECT/REJECT、四个 Shadowsocks 配置名、Trojan TLS 和 daemon
reload/stop；普通 `main` push 不重复运行该门禁。

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
- HTTP / SOCKS5 / VMess / VLESS / AnyTLS 出站逐协议重新实现与启用；每项都必须独立通过 wire、互操作、资源和生命周期门禁。
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
2. P0-2 落地统一 capability gate：v1.0 只允许 direct/reject/SS AEAD/Trojan，其余协议 fail closed。
3. P0-3 补 `zc test --json`。
4. P0-4 砍掉 TUI 并清理对应代码 / help / docs。
5. P0-5 清理或归档历史无用文档，包括删除/归档旧 `ROADMAP.md` / `TASKS.md`、重整 `docs/` 信息架构、清理过期 TUI 草稿、旧 GA-ready 结论和无关 skill/agent 辅助说明。
6. 更新 README 的代理协议兼容性表。
7. 更新 `AGENTS.md`：移除旧 `ROADMAP.md` / `TASKS.md` 作为 canonical 的流程要求，改为当前 v1.0 roadmap / docs 结构。

退出标准：

- 本地 full validation 通过。
- workflow grep 不再出现 `0.15.2`。
- 协议兼容声明和代码行为一致。

### RC5：配置 identity、选择一致性与本地导入

目标：先让 managed config 与代理选择状态可信，再开放本地导入和显式连接关闭。

任务：

1. 按 P0-6 计划建立 transactional authority、immutable config revision 与 legacy rollback mirror。
2. 所有 managed config reader/writer 切换到 exact identity，tracked daemon 发布实际 endpoint 与 revision。
3. 落地 CLI-only `config import`，默认不 active、不 apply。
4. `proxy select` 改为 durable-first generation commit，并统一 CLI/minimal API/status adapter。
5. route snapshot、FlowRegistry 和全 transport owner-safe cancellation 通过后，才开放 `--close-connections`。
6. `DST-PORT` 在 mixed HTTP CONNECT/forward 路径补齐 `target_port`。
7. 热路径 debug print 降噪。

退出标准：

- P0-6 验收矩阵、崩溃恢复与性能门禁全部通过。
- `zc start/status/doctor/test/proxy list --json` 行为可回归。
- ReleaseFast smoke 无明显热路径噪声或关键路径性能回退。

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

### `v1.0.0-rc6` 发布证据（2026-07-20）

- [`main` CI run 29732970476](https://github.com/ekil1100/zc/actions/runs/29732970476) 通过 build、666 tests、migrator、install regression 与 full validation；
- [CD run 29733083750](https://github.com/ekil1100/zc/actions/runs/29733083750) 通过 tag/package/binary version 校验、Linux amd64、macOS arm64/amd64 构建测试、GitHub Release 发布和自动 Tap 更新；
- [`v1.0.0-rc6` Release](https://github.com/ekil1100/zc/releases/tag/v1.0.0-rc6) 正确标记为 prerelease，包含 3 个归档及 3 个可移植 SHA-256 文件；
- `ekil1100/homebrew-tap` commit `fbc5463a` 写入归档实际 SHA-256；
- 本机从 rc5 升级到 rc6 后，`brew style`、`brew audit --strict --online`、`brew livecheck`、`brew test`、release 下载 checksum 与 `zc --version` 均通过。

该证据验证的是 RC 发布链路，不关闭 P0-2、P0-6 或 `v1.0.0` GA gate。

---

## 8. 建议立即执行的下一步

按风险排序：

1. **保持精确 capability gate**：simple-obfs HTTP 与 classic Shadowsocks UDP 已由 validator/doctor、manager 和独立 E2E 共同开放；TLS/unknown/missing/CRLF、AEAD-2022、standalone SOCKS UDP、fragmentation 与其他协议 UDP 仍 fail closed，不得扩散到 TLS/plugin launcher。
2. **完成 P0-6 最终门禁**：managed writer cutover 已完成；下一步补齐 fault/crash 回归、复跑 ReleaseFast 跨目标与 selection/config smoke。
3. ~~**补 `zc test --json`**~~：已完成（连同全 CLI 输出契约对齐一起落地）。
4. **复跑最终 smoke gate**：P0-2 与 P0-6 均关闭后，确认构建、install、migrator、full validation、daemon start/status/stop 均通过。
5. ~~**等待 GitHub Actions 验证 release job**~~：`v1.0.0-rc6` 已通过三平台 release 与 Homebrew Tap 实际验证；GA 前仍需在 P0-2、P0-6 关闭后重跑最终 gate。

---

## 9. 当前最终判断

当前 main 分支：

- ✅ Zig 0.16 本地构建通过
- ✅ 2026-07-20 单测 666/666 通过（0 skipped；包含 Linux path-only directory 权限回归与跨宽度 WebSocket 长度边界）
- ✅ 2026-07-20 migrator 29/29、install regression 与 full validation 3/3 通过
- ✅ 2026-07-20 在隔离 HOME / XDG_RUNTIME_DIR 下完成 29001 daemon start/status/stop smoke
- ✅ CI / release workflow Zig 版本已对齐到 0.16.0，`v1.0.0-rc6` 三平台 CD 与 Homebrew Tap 发布已通过
- ✅ TUI 已从 v1.0 代码入口、help 和 active docs 中移除
- ✅ 旧 `ROADMAP.md` / `TASKS.md` 和过期 TUI/API/install 草稿已删除或归档
- ✅ v1 capability gate 已在 validator/doctor/runtime 与兼容性文档统一落地；2026-08-06 精确开放 simple-obfs HTTP，2026-08-08 精确开放 classic Shadowsocks AEAD UDP；TLS/generic plugin、AEAD-2022 与其他 UDP 范围仍拒绝
- ✅ simple-obfs HTTP 已通过真实 zc + mixed HTTP/SOCKS5 + 独立 oracle + shadowsocks-rust v1.24.0 + origin 的 socket 互操作，覆盖分片 header、same-write tail 与零 dial 负例
- ✅ classic Shadowsocks UDP 已通过独立三算法 vectors、真实 mixed SOCKS5、dual-stack echo、`shadowsocks-rust v1.24.0 -U`、错误包、65507、control close 与 64+1 资源门禁
- ✅ `proxy select` durable/runtime identity、daemon startup restore、tracked controller discovery 与完整 managed config 命令族已进入 production path；legacy mirror 不再是 writer authority
- ✅ `zc test --json` 符合 JSON 契约（全 CLI 输出契约对齐已落地，见 `docs/cli/spec.md` / `docs/cli/ux-workflow.md`）
- ✅ API 已按 minimal API 口径进入 active docs；旧完整 OpenAPI 草案归档

结论：

> **暂不建议立即打 `v1.0.0` tag。先完成剩余安全审计修复、P0-6 fault/crash 与 ReleaseFast 门禁，再进入最终 GA gate。**
