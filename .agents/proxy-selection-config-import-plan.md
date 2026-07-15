# proxy selection 可靠性与本地 config import 实施计划

> 状态：Planned（尚未实现）
> 制定日期：2026-07-14
> 基线提交：`70f8c30`
> 工具链：Zig `0.16.0`
> 事实源：本计划是 `.agents/zc-v1.0-roadmap.md` 中 P0-6 的执行细化；公开状态以 `docs/roadmap/v1.0.md` 为准。

## 1. 目标

本计划同时解决两个用户问题：

1. `proxy select` 选择后没有真正生效，且修复后反复回归；
2. 新增 `zc config import <path>`，把本地 Clash/mihomo 配置安全导入 zc 托管配置库。

两项工作共用一个前提：配置必须有稳定、可验证的 identity，持久状态和 runtime 状态不能再由 CLI、daemon、`meta.json` 分别解释。

本计划不做 TUI，不扩展完整 REST API，不实现配置热替换，也不把 `profile` 重新定义为配置档案。

## 2. 当前事实与基线

### 2.1 实施进度

| Batch | 状态 | Commit / 证据 |
|---|---|---|
| Batch 0 — 计划与基线 | Done | `2bd2567` |
| Batch 1 — baseline harness | Done | `85880d8` |
| Batch 1 — transactional authority | Done | `b940f5d`, hardening `9492bbf` |
| Batch 2+ | Pending | 下一步：ConfigBundle shadow capture/resolver |

Batch 1 authority 尚未接入 `main/config/meta/daemon/manager/API` 生产路径。当前真实 measurement 保存在忽略目录 `.zig-cache/perf/`，不覆盖 tracked placeholder report：

- `70f8c30` + harness：`legacy_bounded_read` median `28,852 ns/op`，p95 `32,493 ns/op`；
- `b940f5d`：legacy median `30,795 ns/op`，strict median `30,577 ns/op`；
- `b940f5d` authority commit median：1 profile `154,275 ns/op`、100 profiles `187,162 ns/op`、1000 profiles `535,435 ns/op`；
- connection admission、flow RSS、config import 仍明确 omitted，不构造假值。

### 2.2 当前验证

2026-07-15 本机验证：

```bash
zig version
# 0.16.0

env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
# 533/534 tests passed (1 skipped)
```

已确认的现状：

- CLI 通过配置中的 `external-controller` 通知 daemon；daemon 不可达时仍可能显示选择成功。
- daemon 先改内存，再 best-effort 写 `meta.json`；持久化错误会被吞掉。
- `status`、`proxy list`、picker、`test` 读取的状态来源不同。
- 显式外部 `-c` 可能错误回退到 `meta.active`，导致选择写入其他配置。
- controller 端口发生 fallback 后，CLI 仍可能连接旧端口。
- 没有 CLI → daemon → manager → durable state → restart 的完整选择回归。
- TCP 代理组最终解析为内建 `DIRECT` / `REJECT` 时存在数据面缺口。
- 当前没有 `config import`；`config dump -c`、`start -c` 和 `config download` 不能替代本地托管导入。
- 当前配置主文件读取上限为 1 MiB；本地 rule-provider 文件上限为 8 MiB。

## 3. 冻结的产品契约

### 3.1 `proxy select`

命令目标形态：

```bash
zc proxy select \
  [-c|--config <managed-key>] \
  [-g <group>] \
  [-p <proxy>] \
  [--close-connections] \
  [--close-timeout <duration>] \
  [--json]
```

冻结语义：

- durable desired selection 是权威状态。
- 每次被接受的选择都递增 selection generation；重复选择同一节点也递增。
- 配置 identity 为 `managed key + config revision`。
- revision 覆盖主 YAML、本地 bundle 依赖和 persisted override；远程 provider 响应内容不参与 revision。
- CLI 只操作托管配置 key；外部路径必须先 `config import`。
- CLI 只使用 tracked daemon descriptor，不再从用户配置的 `external-controller` 猜测 zc daemon。
- daemon 启动时先加载配置、校验 desired、完成 runtime 对账，再开放代理监听端口。
- 只允许手动选择 `select` 类型组；CLI 与 minimal API 行为一致。
- 默认只影响新连接。
- 状态同时表达 desired/runtime，以及嵌套组的 selected/resolved。
- 旧 `applied` 暂时保留，定义为 `runtime_applied` 的 deprecated alias。
- `proxy list` 的旧 `groups[].now` 继续投影 desired；旧 `status.selected_proxies` 保持历史兼容投影并标记 deprecated。

退出语义：

| 场景 | durable desired | runtime apply | exit |
|---|---:|---:|---:|
| daemon 离线 | 成功 | 未尝试 | 0 |
| daemon 运行其他 key | 成功 | 跳过 | 0 |
| 同 key、daemon 运行旧 revision | 成功 | 跳过，提示 reload | 0 |
| tracked daemon identity 无法验证 | 成功 | 跳过 | 1 |
| matching daemon apply 失败 | 成功 | 失败 | 1 |
| durable commit 失败 | 失败 | 禁止尝试 | 1 |
| apply 成功但显式连接关闭不完整 | 成功 | 成功 | 1 |

选择提交顺序：

1. 在跨进程事务中解析 exact identity；
2. 校验 group/member；
3. 原子提交 desired + 新 generation；
4. 发现并验证 tracked daemon；
5. matching daemon 原子发布 runtime generation；
6. 如显式请求，再关闭切换边界前的匹配连接；
7. 返回 durable、runtime 和 close 的分别结果。

runtime apply 或连接关闭失败不回滚 durable desired。daemon 自动恢复只对账 selection，不重放 `--close-connections`。

### 3.2 `--close-connections`

- 只关闭 runtime selection 切换边界前已经存在的 flow。
- flow 必须属于同一 exact config revision，generation 旧于新 selection，且不可变 route chain 包含目标组。
- 覆盖 TCP flow、UDP 五元组 flow 和 AnyTLS/UoT 等逻辑 stream。
- 不关闭其他组共享的物理 tunnel/session。
- TCP 与 UDP 同时处理。
- 重复选择相同节点时，只要显式传入该 flag，仍执行关闭。
- 默认同步等待 5 秒，可用 `--close-timeout` 调整。
- timeout 后安全取消请求继续有效；命令返回部分失败，不跨线程强制 `close(fd)`。
- 自然结束的 flow 计入 `already_gone`，视为成功。
- 输出至少区分 `matched`、`closed`、`already_gone`、`failed`、`timed_out`、`residual`。
- 所有 transport 的 owner-safe cancellation 接入并通过门禁前，不得让 parser/help 接受该 flag。

### 3.3 legacy minimal API

现有请求继续兼容：

```http
PUT /proxies/<group>
Content-Type: application/json

{"name":"<proxy>"}
```

- daemon 把旧请求绑定到自己正在运行的 exact identity。
- daemon 原子分配 generation、持久化 desired，再应用 runtime。
- 旧请求默认不关闭连接。
- 旧读取单值字段表示当前 runtime 实际 resolved 状态；新增字段分别表达 desired、selected、resolved。
- 旧 body 的响应兼容矩阵保持：成功 `200`，缺失/非法 `name` 为 `400`，未知组或节点为 `404`，成功 body 继续包含 `ok/group/proxy`。
- 扩展请求可增加 `close_connections: bool` 与 `close_timeout_ms: u32`；省略时分别为 `false` 和 `5000`，未知扩展字段继续忽略。close intent 只属于当前请求，不进入 durable state，也不被 reconcile 重放。
- 扩展冲突使用 `409`；扩展字段格式、非 select 组或 timeout 范围错误使用 `422`；持久化/内部应用失败使用 `500`；连接关闭等待超时使用 `504`。
- 非 2xx body 仍必须返回已经发生的 durable/runtime/close 部分结果。

### 3.4 `config import`

目标命令：

```bash
zc config import <path> \
  [-n|--name <key>] \
  [--force] \
  [--strict] \
  [--json]
```

冻结语义：

- 仅提供 CLI，不增加配置上传 API，不增加 `profile import`。
- 只接受本地路径；URL 继续使用 `config download`，不支持 stdin。
- 输入是可作为独立配置文档解释的完整 Clash/mihomo YAML，不做代理片段合并。
- 主配置文件上限统一为 16 MiB；所有后续 managed loader 使用相同边界。
- 任意扩展名都可按内容解析；默认 key 剥离 `.yaml` / `.yml`，其他扩展名保留。
- `--name` 与默认 key 支持安全 UTF-8；以 UTF-8 原始字节、区分大小写作为 catalog identity，最大 255 bytes；拒绝空值、无效 UTF-8、控制字符、路径分隔符、`.`、`..`。磁盘目录不直接使用 key，而使用固定长度 opaque storage id，避免 NAME_MAX、大小写不敏感文件系统和 Unicode 等价形式碰撞。
- 允许输入 symlink，但最终目标必须是普通文件；source root 取最终目标文件的父目录。
- 本地依赖复制为独立 bundle；依赖解析后的真实路径必须位于 source root 内。
- 依赖 symlink 仅在最终普通文件仍位于 source root 内时允许；目录、FIFO、设备文件拒绝。
- 远程 provider 只做声明与引用静态校验，import 阶段网络请求数必须为 0。
- 保存原始 YAML 字节、注释、字段顺序和相对依赖树，不用 zc 重新序列化覆盖源文档。
- 普通导入以及 force-inactive 只加入托管库，不 active、不 apply；输出明确提示 `config use`。
- 重名默认拒绝；`--force` 才能创建新 immutable revision 并推进 key 的 head。
- force 不继承旧 subscription URL、URL 参数、override 或 selections。
- force-active 是唯一 active 例外：若该 key 原本 active，则 active 原子推进到新 revision；runtime 继续运行旧 revision，绝不自动 reload/restart，结果明确返回新的 active identity 与 `applied:false`。
- force 的 key 若不是 active，不改变当前 active。
- warning 默认不阻止；`--strict` 把 warning 升级为失败。
- 明知会导致核心运行失败的不支持能力是 error；可安全忽略/降级的差异是 warning；完全未知扩展字段保留并忽略。
- JSON 成功与失败都返回结构化 findings；文本 warning 写 stderr。
- 任意失败都不能留下可见 head、active 或 metadata 半成品。

工程安全上限在实施前通过 fixture 校准，初始建议为：本地主 YAML 16 MiB、单个本地 rule-provider 延续 8 MiB、单 bundle 聚合 64 MiB、最多 1024 个本地依赖。若主流 fixture 证明不足，必须在 RED 测试前更新本计划，而不是实现中静默放宽。

## 4. 深模块与 seam

### 4.1 `SelectionState` Module

外部 Interface 建议保持三个入口：

```zig
pub fn commit(request: CommitRequest) !CommitReceipt;
pub fn observe(target: ConfigTarget) !SelectionView;
pub fn reconcile(runtime: *RuntimeHandle) !ReconcileReceipt;
```

Interface 隐藏：

- authority 锁和 durable write；
- exact revision 解析；
- group/member 校验；
- generation/CAS；
- tracked daemon discovery；
- stale generation 拒绝；
- desired/runtime drift 计算；
- legacy API 投影。

`reconcile` 永远不接受 close 参数，防止恢复路径重放连接关闭。

### 4.2 `ConfigImport` Module

外部 Interface 只有一个业务入口：

```zig
pub fn importLocal(request: ImportRequest) !ImportReceipt;
```

Interface 不出现 activate/apply/restart/API upload 参数。实现隐藏：

- source/symlink/regular-file 校验；
- source-root containment；
- bundle capture；
- 大小预算；
- 离线 parse/validate；
- immutable revision publish；
- head/active CAS；
- force metadata reset；
- fault cleanup。

### 4.3 私有内部 seam

| Seam | Production Adapter | Test Adapter |
|---|---|---|
| Durable authority | filesystem + process lock + atomic rename | memory + fault injection |
| Bundle capture | descriptor-based filesystem reader | temporary tree / mutation simulator |
| Runtime control | tracked daemon descriptor + local IPC | in-process fake daemon |
| Runtime selection | immutable manager snapshot | deterministic fake runtime |
| Flow registry | daemon-owned registry + owner notifier | deterministic flow registry |
| Remote provider | runtime downloader/cache | deny-network/fake provider |

这些 seam 不暴露给 CLI/API caller。CLI、HTTP 和 status 只负责参数解析与结果渲染。

## 5. 数据模型与持久布局

### 5.1 核心类型

```text
ConfigIdentity = { key, revision }
ConfigCatalog  = { heads[key] -> revision, active: ?ConfigIdentity }
RevisionState  = {
  source metadata,
  override,
  desired selections,
  selection generation
}
RuntimeState   = {
  daemon instance,
  ConfigIdentity,
  applied generation,
  runtime selections
}
```

revision 是 opaque incarnation，不直接等同于用户 key。manifest 另外保存内容 digest，用于完整性校验。相同内容的 force 仍可产生新 incarnation，避免 ABA。

persisted override 不能只按脚本路径或脚本字节重复执行：创建 revision 时复制脚本/参数，执行一次并物化 effective patch；manifest 同时记录脚本输入与物化结果 digest，runtime 只读取该 revision 的物化结果。`config update` 或 `config override` 需要重新物化时必须创建新 revision，保证同一 identity 重启后得到同一 effective config。

### 5.2 建议布局

```text
$ZC_CONFIG_DIR/
  state-v2.json
  profiles/
    <storage-id>/            # fixed-length digest of exact UTF-8 key bytes
      revisions/
        <revision>/
          source.yaml
          manifest.json       # logical-path -> immutable asset 映射
          bundle/...
          effective/
            override.yaml     # persisted override 的物化结果
  meta.json                 # 迁移期 legacy mirror
  configs/<key>.yaml        # 迁移期 legacy head mirror

$XDG_RUNTIME_DIR/zc/
  daemon.json               # pid, nonce, endpoint, exact identity, generation
```

`state-v2.json` catalog 保存 exact `key -> storage-id` 映射；storage id 由 key 原始 UTF-8 bytes 的固定长度 digest 稳定生成。创建时必须检查已有映射，若 digest 已绑定其他 key 则 fail closed，不做自动改名。大小写不同或 Unicode 等价但 byte 不同的 key 具有不同 catalog identity 和 storage id。

发布顺序：

1. 在同一文件系统写 staging revision；
2. 写入并校验 manifest；
3. flush 后原子发布 immutable revision；
4. authority 加锁、重读、CAS 更新 head/active/state；
5. temp + fsync + rename + parent fsync 提交 `state-v2.json`；
6. 最后刷新可重建的 legacy mirror。

managed loader 通过 manifest resolver 把 YAML 中的逻辑相对/绝对 provider path 映射到 revision 内的 immutable asset；它不得回读 source root。原始 `source.yaml` 保持字节不变，runtime materialized view 与 remote provider cache 位于独立可控层，remote refresh 不得修改 immutable revision。

revision 已发布但 authority 未引用时只是可回收 orphan，不得造成半提交。首期不做 revision GC。`state-v2.json` 是唯一提交点；legacy mirror 允许滞后且必须可从 v2 重建。回滚旧二进制前必须停止 daemon、取得全局锁、执行并校验 legacy export/repair，再切换 reader；不承诺崩溃窗口中的在线原子回滚。

## 6. 验收矩阵

| ID | 行为 | 必须有的证据 |
|---|---|---|
| S1 | daemon 离线选择可持久并在下次启动恢复 | binary integration + restart |
| S2 | durable write 失败时 runtime 不变 | fault-injection test |
| S3 | matching runtime apply 失败返回部分失败 | CLI/API behavior test |
| S4 | key/revision mismatch 不误应用 | integration test |
| S5 | identity unverified 持久成功但 exit 1 | CLI behavior test |
| S6 | daemon listener 在 reconcile 完成后才开放 | startup scenario test |
| S7 | generation 单调，旧 apply 不能覆盖新 apply | deterministic concurrency test |
| S8 | desired/runtime/selected/resolved 同时可观测 | JSON contract test |
| S9 | 只允许 select 组 | CLI/API parity test |
| S10 | 嵌套组及 DIRECT/REJECT 数据面正确 | manager integration test |
| I1 | import 默认 stored、不 active、不 apply | binary integration test |
| I2 | force active key → active new/runtime old | real daemon scenario test |
| I3 | force 清 source/override/selections metadata | authority test |
| I4 | 16 MiB 成功、16 MiB+1 失败 | boundary test |
| I5 | 本地 bundle containment/symlink/特殊文件 | filesystem tests |
| I6 | remote provider import 网络请求为 0 | deny-network test |
| I7 | warning/strict/JSON findings | CLI BDD |
| I8 | 任一 publish 故障只见完整旧/新状态 | crash/fault matrix |
| F1 | route chain 来自单一 immutable generation | race test |
| F2 | TCP/UDP/逻辑 stream 精确匹配 | protocol scenarios |
| F3 | 不误关其他 revision/组/共享 tunnel | isolation test |
| F4 | already_gone 单列且成功 | flow state-machine test |
| F5 | timeout 后取消继续但命令部分失败 | deadline test |
| F6 | 恢复 reconcile 不重放 close | crash recovery test |
| F7 | 所有 owner 恰好关闭一次，无 fd ABA/UAF | stress + sanitizer-equivalent checks |

## 7. 分批实施

每个批次先 RED、再 GREEN、再最窄回归；一个 commit 只做一个逻辑变更。高风险切换保留 legacy mirror 和明确回滚点。

### Batch 0 — 计划与基线 — Done (`2bd2567`)

目标：把冻结契约写入 canonical/public roadmap，但不把未实现能力写入当前 CLI/API spec。

文件：

- `.agents/proxy-selection-config-import-plan.md`
- `.agents/zc-v1.0-roadmap.md`
- `docs/roadmap/v1.0.md`
- `docs/README.md`

验收：

- 公开文档明确标记 Planned / Not available。
- `docs/cli/spec.md` 与 `docs/api/README.md` 仍只描述当前实现。
- 当前 514 pass / 1 skip 基线有记录。

建议 commit：`docs(roadmap): plan reliable selection and config import`

回滚：纯文档 revert。

### Batch 1 — 真实 baseline harness 与 Durable authority 事务内核 — Done (`85880d8`, `b940f5d`, `9492bbf`)

先在任何生产路径改动前新增可复现的 ReleaseFast benchmark harness，并在 `70f8c30` 上归档原始样本、机器/OS、Zig 版本、重复次数和统计方法：

- config load/import-size 基线；
- selection/meta control-plane 基线；
- connection admission、吞吐、p99 和 active-flow RSS 基线。

建议先提交：`test(perf): establish config and flow baselines`。

随后先写 authority 测试：

- revision/identity 编解码；
- 跨进程锁与 expected-head CAS；
- corrupt/truncated state fail closed；
- temp write、sync、rename、parent sync 故障矩阵；
- 并发两个 writer 只能一个成功。

实现：

- 新增 `src/state_authority.zig`；
- typed mutation，不提供 `load mutable → caller save`；
- memory/fault-injecting adapters；
- filesystem adapter 使用 atomic replace。

本批不接生产 caller。

建议第二个 commit：`feat(state): add transactional config authority`

回滚：删除未接线模块。

### Batch 2 — 安全 ConfigBundle 捕获与 resolver（shadow-only）

任何生产 revision 出现前，先建立能完整捕获主 YAML、本地依赖和 override materialization 的 bundle 能力。

先写测试：

- 主 YAML 16 MiB / 16 MiB+1；
- 完整文档解析，拒绝截断尾部；
- symlink 最终指向普通文件可接受；
- dependency canonical target 必须位于 source root；
- 拒绝 path escape、目录、FIFO、设备；
- capture 期间文件变化检测；
- local provider 离线解析；
- remote provider hit-count 固定 0；
- aggregate budget 与文件数边界；
- manifest logical-path resolver 在删除/篡改 source tree 后仍只读取 immutable asset；
- remote refresh 只写 revision 外 cache，不修改 bundle digest；
- persisted override 物化结果在同一 revision 的多次 load/restart 中一致。

实现：

- 新增 `src/config_bundle.zig`；
- descriptor-based capture，读取后再次验证 stat/digest；
- 保留 `source.yaml` 原始 bytes，manifest 建立逻辑路径到 immutable asset 的映射；
- runtime materialized view 通过 resolver 读取 bundle，不回读 source root；
- persisted override 在 revision 构建时执行并物化，runtime 不重复执行；
- managed-only 静态 validator；
- 网络 adapter 注入 deny-network。

本批只 shadow-build bundle 并比较现有 loader 结果，不发布 revision、不切 reader/writer。

建议 commit：`feat(config): capture and resolve immutable bundles offline`

回滚：模块尚未对外暴露，可直接 revert。

### Batch 3 — Legacy 迁移与 exact config identity

先写测试：

- `meta.json + configs/*.yaml` 通过 Batch 2 capture 幂等迁移；
- 本地依赖变化会产生不同 revision；
- active key 映射 exact revision；
- override 脚本、参数和物化结果纳入 revision manifest；
- selections 映射为 desired generation；
- 损坏/缺文件不可 `catch empty`；
- legacy mirror 可从 v2 重建；
- 每个 crash window 重开只见完整旧/新 v2 state。

实现：

- `meta.zig` 降为 legacy codec/migrator；
- immutable revisions + `state-v2.json`；
- legacy 文件保留；
- mirror 是可重建导出物，不是第二提交点；
- 首期禁止 GC。

建议 commit：`feat(state): migrate managed bundles to exact revisions`

回滚：停止 daemon、取得全局锁、从 v2 导出并校验 legacy mirror，再停用 v2 reader；旧文件与 revisions 保留。

### Batch 4 — Managed loader 与 tracked runtime identity

先写测试：

- managed key 返回 `LoadedConfig{config, origin, identity}`；
- managed loader 仅经 manifest resolver 读取 local assets；
- unmanaged path 返回 identity null，绝不回退 active；
- same key/different revision 可区分；
- tracked descriptor 包含 pid、nonce、actual endpoint、identity、generation；
- controller 端口 fallback 后 CLI 仍能发现正确 tracked endpoint。

实现：

- loader 不再二次猜 config key；
- daemon 启动时固定 exact identity；
- 新增 daemon-owned runtime descriptor；
- `external-controller` 继续服务 minimal API，但不再承担 CLI discovery。

建议拆成两个 commit：

1. `refactor(config): load exact managed bundle identities`
2. `feat(daemon): publish tracked runtime identity`

回滚：descriptor reader 可独立关闭；回滚 managed reader 前先执行并校验 legacy export。

### Batch 5 — 全部 managed writer 切换 Authority

先写测试：

- `list/use/download/update/delete/override` 通过 typed mutation；
- download/update 与 override 统一调用 bundle builder，不会产生不完整 revision；
- update 创建新 revision并保留仍有效 selections；
- 失效 selection 被删除；
- local dependency 或 override materialized output 变化必定创建新 revision；
- override set/clear 创建新 revision；
- 任一失败保留旧 head/active；
- legacy mirror 可在锁内重建并校验。

实现：

- 删除直接 truncate managed YAML 的写路径；
- 删除正常流程中的 `meta.load/save` writer；
- config use 指向 exact head；
- runtime cache 与 immutable revision 分离。

建议按命令族拆 commit：

1. `refactor(config): route catalog and use through authority`
2. `refactor(config): publish download and update as bundles`
3. `refactor(config): revision override and delete mutations`

门禁：

```bash
rg -n 'meta\.(load|save)|createFileAbsolute.*config|persistSelections' src
```

每个命中都必须有明确的 legacy/test 理由。

### Batch 6 — ConfigImport Module 与 CLI

先写 Module 测试：

- create-only；
- duplicate conflict；
- force 清 metadata；
- active key 推进到新 revision；
- inactive key 不改 active；
- runtime adapter 调用次数为 0；
- publish 每个故障点无可见半成品。

再写 CLI BDD：

- help、参数缺失、重复/未知 flag、额外 positional；
- basename、`.yaml/.yml`、任意扩展名、UTF-8 byte identity 与 255-byte 上限；
- opaque storage id 在 macOS/Linux 上避免大小写和 Unicode 文件名碰撞；
- `--strict` 与结构化 findings；
- text/JSON stdout/stderr；
- 独立 HOME/XDG；
- 普通/force-inactive 成功明确 `active:false` / `applied:false`；force-active 返回新的 active identity 与 `applied:false`。

实现：

- 新增 `src/config_import.zig`；
- `src/cli/commands.zig` 和 `src/main.zig` 只做 adapter；
- 不增加 HTTP endpoint；
- 不增加 `profile import`。

行为测试通过后同步：

- `docs/cli/spec.md`
- `docs/api/error-codes.md`
- 新增 `docs/config/import.md`
- `docs/README.md`

建议拆 commit：

1. `feat(config): add inert local import transactions`
2. `feat(cli): expose config import`

CLI 行为 commit 必须包含对应 current-contract 文档，不能提前宣传。

### Batch 7 — SelectionState durable-first

先写测试：

- commit 失败 runtime 不变；
- accepted command generation 单调；
- same value 仍推进 generation；
- stale generation/revision apply 被拒绝；
- active R2/runtime R1 分别展示；
- startup reconcile 在 listener 之前完成；
- 自动 reconcile 不携带 close intent；
- invalid desired 被清理并记录 warning。

实现：

- `runtime_selection.zig` 收敛为 `commit/observe/reconcile` Interface；
- `OutboundManager` 只接受 immutable committed snapshot；
- 删除 manager 的 meta persistence 与错误吞噬；
- 修复组最终解析到 `DIRECT` / `REJECT` 的 TCP 路径；
- 明确循环组错误，不再依赖固定递归次数后报 `ProxyNotFound`。

建议拆 commit：

1. `feat(selection): commit desired generations durably`
2. `refactor(runtime): apply immutable selection snapshots`
3. `fix(outbound): resolve builtin group targets consistently`

### Batch 8 — CLI、minimal API 与 status 统一 adapter

先写 BDD：

- CLI → daemon → manager → authority → restart 全链；
- 离线、其他 key、旧 revision、identity unverified、apply failed；
- 只允许 select 组；
- interactive 与 `-p` 走同一 commit；
- success 文案只在 durable commit 后输出；
- legacy PUT 持久化 desired；
- legacy body 保持 200/400/404 与 `ok/group/proxy`；扩展冲突/参数分别覆盖 409/422，持久化失败覆盖 500；
- desired/runtime/selected/resolved 与 deprecated 字段投影。

实现：

- 删除 `proxy_cli.notifyDaemon` 的 raw discovery 编排；
- `api/server.zig` 删除重复 selection domain validation；
- status 不再用 daemon 快照覆盖 desired；
- API JSON 全部使用 `std.json`。

本批先交付可靠选择，不开放 `--close-connections`。

行为通过后同步：

- `docs/cli/spec.md`
- `docs/cli/ux-workflow.md`
- `docs/api/README.md`
- `docs/api/error-codes.md`
- `docs/compat/mihomo-clash.md`
- daemon/status 相关文档。

建议 commit：`fix(selection): make proxy choice durable and revision-aware`

### Batch 9 — Immutable route resolution 与 FlowRegistry

先写测试：

- 嵌套 group path 与 resolved leaf；
- TCP/UDP 路由结果一致；
- 一个 flow 的 route chain 来自单一 generation；
- exact identity + old generation + group path 精确匹配；
- 其他 revision、新 generation、DIRECT bypass 不匹配；
- flow 状态机幂等；
- apply/register 竞态无 old-generation escape。

实现：

- route resolution 一次返回 immutable `RoutePlan`；
- flow 记录 interned group IDs，不复制字符串；
- 短 gate 内完成 snapshot acquire / flow bind / generation publish；
- 磁盘、DNS、dial、TLS、关闭和等待均在 gate 外；
- 默认路径不新增 per-flow fd。

建议 commit：`feat(runtime): track flows by immutable route generation`

回滚：public close 尚未开放，可撤回 registry；durable selection 保留。

### Batch 10 — 全 transport owner-safe cancellation

按 transport 逐个 RED/GREEN：

1. mixed HTTP CONNECT；
2. mixed SOCKS CONNECT；
3. HTTP forward / 独立 HTTP handler；
4. HTTPS/TLS blocking pump；
5. SOCKS5 UDP flow；
6. UoT logical flow；
7. AnyTLS multiplexed stream。

统一规则：

- 控制线程只 request cancel/wake；
- raw fd 跨线程只可安全 `shutdown`，owner 恰好一次 close；
- shared physical session 不因单个 logical flow 被误关；
- cancel 与 activate/dial/finish 竞态有 deterministic tests；
- 无 UAF、double-close、fd ABA、线程/ref 泄漏。

每个 transport 一个逻辑 commit，不得做单次 big-bang。

### Batch 11 — 公开 `--close-connections`

先写 CLI/API/status BDD：

- 默认无 close；
- same-value + close；
- TCP+UDP；
- nested route chain；
- matched/closed/already_gone/failed/timed_out/residual；
- 默认 5 秒和自定义 duration；
- API 可选 `close_connections` / `close_timeout_ms` 的默认值、未知字段与瞬时 intent；
- timeout HTTP 504、CLI exit 1；
- daemon offline/other revision 不重放 close；
- 三个崩溃窗口恢复只收敛 selection。

全部 transport gate 通过后才修改 parser/help。

建议 commit：`feat(selection): add transient connection closing`

### Batch 12 — 性能、可靠性与发布收尾

新增真实 benchmark：

- authority：1/100/1000 profiles，1/8/32 并发 selection commits；
- import：4 KiB、16 MiB、多 asset、100/1000 profiles；
- flow registry：1k/10k/100k flows，0/1/50/100% affected；
- mixed 长连接、UDP pps、AnyTLS pool cancel；
- Linux/macOS 原子发布、symlink containment、crash reopen。

完整验证：

```bash
git status --short --branch
zig version
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build test --summary all
env ZIG_GLOBAL_CACHE_DIR=/tmp/zig-cache zig build -Doptimize=ReleaseFast --summary all
bash tools/config-migrator/run-all.sh
bash scripts/install/run-all-regression.sh
bash scripts/run-full-validation.sh
./zig-out/bin/zc start --port 29001 -c testdata/config/minimal.yaml --json
./zig-out/bin/zc status --json
./zig-out/bin/zc stop --json
```

完成后执行 `iterative-review-fix`，最多 5 轮；只修有依据的问题。证据齐全后才把 canonical/public roadmap 从 Planned 改为 Done。

## 8. 性能门禁

Batch 1 在任何生产改动前建立同机 ReleaseFast baseline；Batch 2-11 每个受影响批次都运行 before/after gate，Batch 12 只做最终复验。默认门禁：

- 无 close 的正常连接建立吞吐中位数劣化不超过 5%。
- 正常连接建立 p99 劣化不超过 10%。
- route/registry 热路径禁止磁盘 I/O和网络 I/O。
- 不允许新增 per-flow fd。
- 100k active flows 的额外 RSS 必须线性增长，并在基线报告中给出 bytes/flow；若超过预设预算，必须先优化或重新评审。
- 10k 匹配 flow 必须能在默认 5 秒内完成或给出真实 residual；matched 数不能冒充 closed 数。
- old-generation escape 必须为 0。
- close storm 后 fd、thread、AnyTLS ref/session 无泄漏。
- authority/import 控制面 benchmark 使用至少 5 次样本，报告 median/p95；不得用环境变量占位值伪造 PASS。

性能劣化不能通过放宽脚本或减少样本绕过。阈值确需修改时，先更新本计划并记录原因。

## 9. 错误码与结果字段计划

### 9.1 `config import`

计划新增稳定错误码：

- `CONFIG_IMPORT_PATH_REQUIRED`
- `CONFIG_IMPORT_NAME_REQUIRED`
- `CONFIG_IMPORT_ARGUMENT_INVALID`
- `CONFIG_IMPORT_NOT_REGULAR`
- `CONFIG_IMPORT_TOO_LARGE`
- `CONFIG_IMPORT_PATH_ESCAPE`
- `CONFIG_IMPORT_CONFLICT`
- `CONFIG_IMPORT_VALIDATION_FAILED`
- `CONFIG_IMPORT_FAILED`

### 9.2 `proxy select`

计划新增或细化：

- `PROXY_CONFIG_UNMANAGED`
- `PROXY_SELECTION_PERSIST_FAILED`
- `PROXY_RUNTIME_IDENTITY_UNVERIFIED`
- `PROXY_RUNTIME_APPLY_FAILED`
- `PROXY_CLOSE_TIMEOUT`
- `PROXY_CLOSE_PARTIAL`

计划结果字段：

```text
config: { key, revision }
group
proxy
generation
persisted
runtime_state
runtime_applied
applied                 # deprecated alias
selected
resolved
close: {
  requested,
  matched,
  closed,
  already_gone,
  failed,
  timed_out,
  residual,
  timeout_ms
}
```

最终字段在 Batch 0 后保持冻结；若实现发现必须调整，先改计划和契约测试，不能直接改代码输出。

## 10. 文档同步策略

规划阶段只修改 roadmap 和本计划，绝不把未实现行为写入当前契约。

行为落地的同一 commit 才同步：

- `docs/cli/spec.md`
- `docs/api/README.md`
- `docs/api/error-codes.md`
- `docs/config/import.md`
- `docs/compat/mihomo-clash.md`
- daemon/status/default runtime 相关文档
- `docs/README.md`
- `.agents/zc-v1.0-roadmap.md`
- `docs/roadmap/v1.0.md`

## 11. 回滚与迁移原则

- 新 state schema 上线初期保留 legacy 文件和可读 mirror。
- immutable revision 首期不 GC。
- `state-v2.json` 是唯一权威提交点；legacy mirror 是可重建导出物，不承诺与每个 v2 crash window 在线原子一致。
- 回滚旧 reader 前必须停止 daemon、取得全局锁、从 v2 导出并校验完整 legacy mirror，再执行独立 revert。
- 不做长期 dual-write；迁移期 mirror 只有一个新 authority writer。
- rollback 后再次升级必须重新校验/迁移，不能静默信任陈旧 v2 state。
- close 功能可通过移除 parser/help/API 字段单独关闭，不影响 durable selection。
- config import adapter 可单独撤回；已发布 immutable revision 保留为 orphan，不在失败事务中递归删除。

## 12. 完成定义

只有同时满足以下条件才可关闭 P0-6：

- 本计划全部验收矩阵有自动化证据。
- `proxy select` 完整链路和 restart 回归通过。
- daemon 启动前对账，没有默认节点流量窗口。
- desired/runtime/selected/resolved 状态可观测且不互相覆盖。
- config import 的 bundle、force、strict、16 MiB 和零网络行为通过。
- close-connections 覆盖所有 transport，且无误关/UAF/double-close/fd ABA。
- 性能门禁与可靠性故障注入通过。
- CLI/API 文档只声明已实现行为，错误码和字段与测试一致。
- `iterative-review-fix` 完成且无剩余有依据 finding。
- 全量 Zig 0.16、ReleaseFast、migrator、install、full validation、29001 smoke 通过。
- 每个逻辑变更均为可独立回滚的 Conventional Commit。
