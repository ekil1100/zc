# state proven repairs 交接

## 结果

仅修改 `src/store.rs`、`src/override_script.rs`、三个归属测试文件，新增 `tests/state_durability.rs` 和 `tests/{fixtures,support}/state_*`。未修改原 Zig、fsutil、service、cli、config、核心 E2E 脚本；未执行 Git 写操作、安装或监听生产端口。

六项缺陷均先复现失败，再修复归属模块：

| 缺陷 | 修复与证据 |
| --- | --- |
| 已存在 revision 重试绕过目录 fsync | 验证 orphan 后再次 `revisions.sync()`，成功之前禁止 authority commit。真实 DYLD fsync/F_FULLFSYNC 注入：首次 rename 后失败；第二次重试重新注入仍不得生成 authority；第三次无故障成功。 |
| takeover 丢失 durability receipt | `commit` 在可见 rename 后同步失败时置 Store 内存标记；`load` 返回的 Snapshot 携带标记，后续同 Store 读取仍保留。无 rollback。真实 authority fsync 注入确认 sequence=1、active/head 可读且标记为 true。 |
| schema1 override 字节证明不一致 | 按 `override.zig` effective/public/runtime writer 实现字段顺序、严格类型、默认值、规则规范化、转义、obfs、provider、原 Zig provider HashMap 顺序。未放松 content/head 校验，也无 Zig 执行回退。 |
| 无效物化进入 raw plugin recovery | recovery 仅在 `materialized == None` 时允许。无效 obfs override 和 nil patch 携带无效原始插件均拒绝接管，authority/profiles 不生成。 |
| 发布保留失效选择 | 在 authority commit 前按新 bundle 的实际 group/member 过滤，同一事务修改 head、选择和 generation；删除/恢复 group 后均为 generation=2、selections=[]。 |
| deferred HTTP RULE-SET 离线准入 | 删除空 payload 占位。引用远端 RULE-SET 的 catalog capture/publication/activation 拒绝；未引用的声明仍可离线准入。新增明确的 unmanaged capture API，真实 loopback HTTP fetch 后才得到运行 Config。 |

## API 变化及父任务必须接线的地方

### 1. durability

新增：

- `Snapshot::durability_uncertain: bool`
- `Store::durability_uncertain() -> bool`

标记仅保留在同一个 Store reader 生命周期中，不是持久化 catalog 字段；没有推断另一进程历史 fsync 的能力。`Receipt` 仍保留原始 `io::Error`。

父任务修改 `src/cli.rs`：

- `health_data` 的 JSON 标记改为 `store.durability_uncertain() || receipt.is_some_and(|r| r.durability_error.is_some())`。
- `config list`、`config override` 查询/无变化成功路径凡已有 snapshot，不再写死 false，改用 `snapshot.durability_uncertain`。
- 真正缺失 store 的空结果仍可报告 false。

**当前 CLI 尚未接线；不能宣称 fsync 故障时 CLI 已正确报告。**

### 2. canonical config 与 runtime 入口

新增 `override_script::runtime_source(source: &[u8]) -> Result<String>`。它解析类型、将 Zig 不影响当前运行时的兼容字段投影到 Rust parser，处理 `allow-lan=false` 时忽略 bind-address 的原语义。不修改 immutable source/materialized 字节，不用于 hash。

Store 的 offline 验证及 `runtime_config_with_assets` 已使用此入口。

父任务在 `src/service.rs` 的 `prepare_loaded` / `prepared_config` 两个 `Config::parse_with_assets` 调用前应用：

```rust
let runtime_source = override_script::runtime_source(source.as_bytes())?;
let config = Config::parse_with_assets(&runtime_source, &assets)?;
```

`prepared_config` 对应使用 `prepared.source.as_bytes()`。保留原始 `Prepared.source`；不要用 runtime 投影替换 catalog/hash 输入。如果父任务选择直接在 config 模块实现完整 Zig 兼容模型，应统一这一个语义入口，避免重复投影。

**当前 service 尚未接线，canonical override 运行启动仍可能被旧 RawConfig 的 deny_unknown_fields 拒绝；本任务不声称最终 E2E 已通过。**

原 Config 还有任务前即存在的范围差异，例如 named direct/reject proxy、部分 Zig 仅保留不执行的协议元数据。本任务保证这些字段的 materialization/dump 字节，不宣称扩展了归属外的 runtime 协议支持。

### 3. unmanaged HTTP

新增 `Bundle::capture_for_runtime(path) -> Result<Bundle>`：只捕获有界原始输入及本地 assets，不发网络请求、不返回 executable Config，不做 catalog 准入。必须真实 fetch 后调用 `runtime_config_with_assets`。即使拿到此 Bundle，`Store::publish` 仍重新执行完整 catalog 门禁，不能绕过离线限制。

父任务在 `src/service.rs::load` 的**仅非托管文件分支**中，将 `Bundle::capture(&path)` 改为 `Bundle::capture_for_runtime(&path)`，移除该分支提前调用 `catalog_ready()` 的门禁，交由 `prepare_loaded` 在 fetch 后做最终完整 Config 验证。托管分支、legacy takeover 和 publish/activate 不变。

**未接线前，未托管远端 RULE-SET 的最终 CLI 路径仍会被旧 service 调用点阻断；真实 HTTP 获取及非空规则展开已在公开 Bundle API 测试通过。**

## 验证

隔离环境采用 `/tmp/test-zc-state.7ysFBc/env.sh`，HOME/TMPDIR/XDG_RUNTIME_DIR/CARGO_TARGET_DIR 均指向审阅临时目录。

```sh
cargo test --test store --test store_legacy --test override_script --test state_durability
```

结果：`store` 18、`store_legacy` 18、`override_script` 22、`state_durability` 4，共 **62 tests PASS**（含子进程入口）；日志 `/tmp/test-zc-state.7ysFBc/state-owned-final.log`。

仅对归属 Rust 文件执行 rustfmt；未运行 cargo fmt --all。

默认测试不需要 Zig。真实 fsync 注入目前限 macOS，子进程编译 `tests/support/state_io_fault.c` 并加载 DYLD shim；Linux 尚无等价注入验证，不伪造 durability 结果。

## 外部原始复现

修复前重新运行原审阅 `reproduce_contracts_canonical.py`、`reproduce_schema_one.py`、`reproduce_selection.py`，仅替换临时 case 目录名，保留两套原始二进制及原断言。

- before：`/tmp/test-zc-state.7ysFBc/state-recheck-before`、`state-selection-before`、`state-schema-before`。
- after：`state-recheck-after`、`state-selection-after`：无效 override/远端引用均与 Zig 一致拒绝；两次 group 更新的 generations/selections 与 Zig 一致。
- schema1：在**同一个** `state-schema-before` canonical path 上恢复原 source/script/meta/schema1 后，Zig 与新 Rust 各连续接管两次；head 均保持 `e0b071e162848573f3fc428163d17434`，sequence 均从 7 变为 8。
- 原审阅 golden head `5109ae8cab8fed6a1f8b277cfd767d37` 与 digest `49bd9dc5364a2ea3c235d6ac8ab3f4e4b32ad888885b5c7ce778a1ea8ac8bffa` 也已纳入默认测试。path 是 frozen invocation 元数据的一部分，不能任意替换后还期待相同 head。

## Golden 来源与重生成

`tests/support/state_dump_probe.zig` 只用于人工 oracle 比较。将其复制到隔离的原 Zig `src/` 快照旁编译，不在生产或 cargo test 调用 Zig。接口：

```sh
state-dump-probe materialize SOURCE PATCH
state-dump-probe public SOURCE
state-dump-probe runtime SOURCE
state-dump-probe json SOURCE
```

已用 Zig 0.16.0 实际生成 `tests/fixtures/state_*`：

- minimal/full：物化 bytes；effective 输入的 public YAML；minimal runtime YAML。
- provider：22 个声明，覆盖冲突、扩容、长 key、Unicode key；provider patch 替换顺序；物化及 public bytes。
- transport：ws/grpc、VLESS、empty relay 的 public bytes（可 dump 不等于可物化/运行）。
- runtime_source：full effective 中将 RULE-SET 改为已展开的 DOMAIN-SUFFIX，生成 runtime bytes。
- full_public.json：原 full source 的 Zig JSON 输出，测试比较完整结构（不要求 JSON object 字段排列一致）。
- minimal_manifest/override.sh：直接复制原审阅真实 Zig revision 证据。

原 Zig 反证：`legacy_catalog_bootstrap_test.zig` 的 referenced HTTP 拒绝测试（约381行）和 unused HTTP 接受测试；`catalog_commands.zig::filterSelections` 及 override 发布；`revision_store.zig` 的已存在 revision 重试目录同步。之前两个声称 referenced HTTP 可离线激活的 Rust 测试已按这些反证纠正，未降低原 E2E 或修改核心脚本。

父任务应将最终用户行为/API 接线同步写入归属外的 `docs/`，再运行整体门禁。
