# Rust 迁移：性能与可靠性工具验收

## 最新构建候选：`bdefd33` macOS 15 + 延迟 framework

**启动已有改善，性能门禁仍不放行。** 用户已批准最低 macOS 15；本轮使用该提交的干净源码快照，按已提交的默认 Release 构建，不添加临时链接开关。完整 snapshot manifest 包含 `.cargo/config.toml`；源码、输入快照及二进制前后 hash 不变。

```bash
python3 scripts/perf/compare-runtimes.py --build \
  --samples 7 --iterations 100 \
  --output target/perf/rust-macos15-bdefd33-clean.json
```

| 公共接口 | Rust 中位数 | Zig 中位数 | Rust / Zig |
| --- | ---: | ---: | ---: |
| config dump，100 条规则 | 3.469 ms | 2.952 ms | **1.175** |
| config dump，10000 条规则 | 25.904 ms | 49.725 ms | 0.521 |
| 新 CONNECT + 4 KiB echo，100 条规则 | 209.68 μs | 226.41 μs | 0.926 |
| 新 CONNECT + 4 KiB echo，10000 条规则 | 228.47 μs | 234.81 μs | 0.973 |
| 常驻隧道 64 KiB echo，100 条规则 | 78.17 μs | 77.55 μs | 1.008 |
| 常驻隧道 64 KiB echo，10000 条规则 | 77.82 μs | 78.49 μs | 0.991 |

小配置仍慢 **17.5% / 0.517 ms**；组均值 nearest-rank p95 为 Rust **4.809 ms** / Zig **4.658 ms**。七组样本全部保留，仍为 `exploratory-runtime-comparison` / `formal_baseline: false`，不代表正式性能、RSS/逐请求尾延迟、其他平台或长稳通过。

- snapshot manifest SHA-256：`bdc832db6c7c386a92b3d0b09cb4d8cd8a76927039790358be28eefbff990324`。
- Rust SHA-256：`9c7f3d26e3b357d4f44e251e187976f8bb0dbf0ea5b5af3544c9d25574259c5a`。
- Zig SHA-256：`d6639c053697b37ae755b2ba1ebd5823423bc75751a882833ae72b0bf0fa3338`。
- 首次构建曾因沿用 minOS 27 的 `mlua-sys`/`blake3` C 缓存而被 `-fatal_warnings` 拒绝。清理共享 release 缓存后重新从 clean commit 构建；没有关闭警告或修改最低版本。

### 同批次三方核验

为避免将历史批次差异误认为优化收益，另固定旧 `10d2bab` Rust/Zig 及新 `bdefd33` Rust 三个二进制，同时测量 `--version` 与完整 JSON dump；启动/结束 hash 一致。每项每端先预热三次，七组各二十个真实子进程，轮换并反转执行顺序、不筛掉慢样本；完整输出须相等，HOME/XDG 全隔离。

| 操作 | 原 Rust | 新 Rust | 同一 Zig | 新 Rust / 原 Rust | 新 Rust / Zig |
| --- | ---: | ---: | ---: | ---: | ---: |
| --version | 4.174 ms | 2.731 ms | 2.154 ms | 0.654 | 1.268 |
| config dump，100 条规则 | 4.766 ms | 3.214 ms | 2.767 ms | **0.674** | **1.161** |

本次构建调整的小配置同批下降 **32.6%**，但相对 Zig 仍慢 **16.1% / 0.446 ms**，与上面的阻塞结论一致。两种采样口径不得混算；三方探针只隔离整体构建调整，不单独归因于某个 linker 开关。脚本与全量样本：`target/perf/macos15-three-way.py`、`target/perf/macos15-three-way.json`（记录脚本、输入报告与三个二进制 hash）。

## 历史候选：`10d2bab` clean-commit 冻结复测

**性能门禁仍未放行。** 在提交 `10d2babb62b9406cbcd8cd76514d4dd1c32fef78` 的干净工作区，用默认 Release 参数从独立源快照构建 Rust 与 Zig；构建/运行期间源码和二进制 hash 均未变化。工具仍明确标记 `exploratory-runtime-comparison` / `formal_baseline: false`：clean commit 解决了来源绑定，不等于完成正式阈值、RSS、逐请求尾延迟或四平台性能验收。

```bash
python3 scripts/perf/compare-runtimes.py --build \
  --samples 7 --iterations 100 \
  --output target/perf/rust-clean-10d2bab.json
```

macOS arm64，同机同配置、交替顺序、全部七组原始样本保留；配置含表中 DOMAIN 规则数量加最终 MATCH。只用隔离 HOME/XDG 和非 7899 loopback 端口。

| 公共接口 | Rust 中位数 | Zig 中位数 | Rust / Zig |
| --- | ---: | ---: | ---: |
| config dump，100 条规则 | 4.455 ms | 2.964 ms | **1.503** |
| config dump，10000 条规则 | 26.651 ms | 50.444 ms | 0.528 |
| 新 CONNECT + 4 KiB echo，100 条规则 | 208.3 μs | 227.5 μs | 0.916 |
| 新 CONNECT + 4 KiB echo，10000 条规则 | 229.6 μs | 232.2 μs | 0.989 |
| 常驻隧道 64 KiB echo，100 条规则 | 78.08 μs | 77.52 μs | 1.007 |
| 常驻隧道 64 KiB echo，10000 条规则 | 78.37 μs | 78.03 μs | 1.004 |

小配置慢 **50.3% / 1.491 ms**，组均值 nearest-rank p95 为 Rust **5.737 ms** / Zig **4.955 ms**。万规则 stream 同口径 p95 为 Rust 79.94 μs / Zig 80.24 μs。不剔除慢样本，不将不同二进制/批次的差值归因于某个修复，也不将 loopback 中位数接近视为整体等价。

- 冻结完整 snapshot manifest SHA-256：`6128f7396dec98cf179994e0b13aa81a55dd380b64ad999271a8a7be3d5dbd04`。
- Rust binary SHA-256：`447e0a0b62367fd554d4e3b484c5074c9bcdf37bdc8232497ee0328f87b61ce0`。
- Zig binary SHA-256：`af42dd8624313699a50deec01ffa4935a78966912faa7f4e283820505711093d`。
- 原始报告含构建命令/日志、逐文件 hash、全部样本与前后 provenance；路径为 `target/perf/rust-clean-10d2bab.json`。
- 该历史候选没有采用 `-delay_framework`，当时没有提高最低 macOS 版本。后续批准与落地见本页最新候选及[延迟 framework 研究](../research/macos-framework-startup.md)；不能用旧探针收益宣布性能通过。
- 24/72h 长稳及完整 RSS/尾延迟仍未验收；下列短测绑定历史候选，不能冒充本提交的长稳证明。

## 历史候选：本机交付门禁后的复测

**功能门禁已通过，性能门禁仍未放行。** 本次使用同轮 beta gate 构建的 `target/release/zc`，复用先前相同 Zig ReleaseFast 对照二进制；没有修改构建参数或剔除慢样本。报告 `target/perf/rust-final-acceptance.json` 含前后源码/二进制哈希、全部原始样本及环境，测量期间工作区源码未变化。工作区仍 dirty；本次未使用 `--build` 创建独立源快照，不能作为 clean-commit 正式基线。

```bash
python3 scripts/perf/compare-runtimes.py \
  --rust target/release/zc \
  --zig target/perf/candidate-source-1789574874693073000/target/zig-reference/bin/zc \
  --samples 7 --iterations 100 \
  --output target/perf/rust-final-acceptance.json
```

| 公共接口 | Rust 中位数 | Zig 中位数 | Rust / Zig |
| --- | ---: | ---: | ---: |
| config dump，100 条规则 | 4.106 ms | 3.032 ms | **1.354** |
| config dump，10000 条规则 | 26.210 ms | 48.450 ms | 0.541 |
| 新 CONNECT + 4 KiB echo，100 条规则 | 210.2 μs | 229.5 μs | 0.916 |
| 新 CONNECT + 4 KiB echo，10000 条规则 | 231.1 μs | 238.2 μs | 0.970 |
| 常驻隧道 64 KiB echo，100 条规则 | 79.2 μs | 78.8 μs | 1.005 |
| 常驻隧道 64 KiB echo，10000 条规则 | 79.5 μs | 77.9 μs | 1.020 |

小配置仍退化 **35.4% / 1.074 ms**，不能直接合入性能门禁。组均值 nearest-rank p95：小配置 dump Rust 5.920 ms / Zig 5.040 ms；万规则 stream Rust 111.9 μs / Zig 80.3 μs。保留这些尾部样本，不把中位数相近写成整体等价，也不因本批次百分比小于前批次就声称新的优化收益。

- Rust SHA-256：`e0bb83117c1f0cb07a7cc299cb93e49135677fa489f2a792bc5bfc81dc3f95d3`。
- Zig SHA-256：`26210d394f7710fbf7ab4280d0216ba49feeed93edeb54416d9d758a1600f28b`。
- 最终当前候选 60 秒真实 soak 通过：61 次探测、零崩溃/失败，`target/reliability/final-soak.json`。
- 10 秒进程退出注入通过：11 次探测、零非注入崩溃/失败，`target/reliability/final-process-exit.json`；这不证明 DNS/代理故障自动恢复。
- 真正 300 秒 UDP idle（含无效流量不得延长生命期）另行通过；24/72h 长稳、全路径 RSS/尾延迟仍未验收。

以下保留历史候选与失败记录，其测试数和源码范围不代表最新候选；当前汇总结论以 [completion](completion.md) 为准。

## 上一批次：CLI parity performance

**命名 direct/reject 与完整文档尾部校验已修复；启动/解析优化有效，但小配置 dump 仍慢 39.0%，不能判定性能 PASS。** 以下数据来自 macOS arm64 的冻结 dirty candidate，不是 clean-commit 正式基线。旧批次记录保留在后文，不能混用候选或覆盖异常。

### 行为与安全边界

- `src/config.rs`：用户命名 `type: direct/reject` 不再要求远端 server/port/password；可以被规则、select 引用。精确保留名 `DIRECT/REJECT` 仍禁止声明；network/ws/grpc/plugin 不得被忽略。没有扩展 DIRECT UDP ingress。
- `src/override_script.rs::runtime_source`：只在类型校验后移除原 Zig 对该 native leaf 不使用的 metadata。SS 保留 cipher、TLS 能力拒绝与插件校验；Trojan 保留真实 SNI/证书验证语义；所有节点保留 transport/plugin gate。canonical materialization writer、provider digest 顺序及 immutable source 均未改写。
- 对照依据：`src/config.zig::parseProxy`、`src/runtime_capability.zig::assessProxy`、`src/proxy/outbound/manager.zig::connectToProxy`。真实 Zig/Rust 命名节点转发/拒绝结果为 `target/perf/cli-parity-named-oracle.json`；SS/Trojan inactive metadata 的原 Zig 托管准入为 `target/perf/cli-parity-native-metadata-oracle-green.json`。首次缺 port 的 fixture 拒绝记录另存，未算作产品缺陷。
- 新发现的真实尾部问题：`{"rules":["MATCH,DIRECT"]} {"rules":["MATCH,REJECT"]}` 原候选只读取前半段，原 Zig 拒绝。`target/perf/cli-parity-trailing-oracle.json` 保留对照。改用 YAML stream 入口并维持 `max_documents: 1`，不再抑制文档结束后的 malformed tail；Config 与真实 CLI dump/load 回归覆盖。
- 该批次 JSON 快路径复用同一有界 visitor，要求完整 EOF、mapping root、无 duplicate/merge key、深度最多 16、全文 collection entries 最多 262144、source 最多 16 MiB。后续已对齐原 Zig 根外 128 层并补充受限解析栈，详见当前迁移文档；这里保留当时的优化边界。该 entry 上限同时约束 nodes/events；JSON 解码 scalar bytes 不超过 source bytes。YAML anchors/aliases/tags 等原限制不放宽。
- 快路径有意只处理 ASCII（排除原始 DEL）且数值均可表示为 i64 的 JSON；其他输入仍由完整严格 YAML parser 处理。这样保留 literal Unicode 的 YAML 换行/字符准入，以及浮点、大整数解释，不把解析器切换变成 canonical 内容变更。标量对照回归覆盖转义控制字符、surrogate pair、DEL、NEL/LS、整数边界和浮点。
- `src/main.rs`：短 CLI 使用 current-thread Tokio；daemon/foreground 保持 multithread；同步 override worker 在创建 async runtime 前分流。未改生命周期 CAS、daemon lock 继承、worker 限制、下载重试或 TLS 实现。

主迁移/兼容文档先前的“命名节点未实现”条目由本节证据更新；本任务仅拥有本文件，`docs/migration/rust.md`、`docs/compat/mihomo-clash.md` 的汇总同步留给父任务。

### 定位证据

公开阶段探针为 `scripts/perf/parse-stages.rs`；原始七组样本、探针哈希及说明为 `target/perf/cli-parity-stages.json`。每阶段预热一组、七组×20 次；阶段互相包含，**不能相加冒充调用链总耗时**。

| 万规则阶段 | 优化前中位数 | 最终中位数 |
| --- | ---: | ---: |
| 原始 YAML document parse | 3.416 ms | 3.445 ms |
| 内部 JSON document parse | 3.470 ms | 0.248 ms |
| runtime projection | 4.415 ms | 1.169 ms |
| Config runtime parse（含构建） | 5.225 ms | 1.990 ms |
| Bundle capture | 7.051 ms | 6.941 ms |
| catalog admission | 13.242 ms | 6.750 ms |
| public JSON dump | 4.991 ms | 4.983 ms |

固定二进制、仅改变 `TOKIO_WORKER_THREADS` 的交替进程探针只显示小幅差异，记录为 `target/perf/cli-parity-thread-probe.json`。独立 runtime build/drop 探针测得 multithread 中位数约 0.1356 ms、current-thread 约 0.0021 ms，全部原始样本在 `target/perf/cli-parity-runtime-build.log`。因此线程池不是主要退化原因；万规则收益主要来自消除内部 JSON 的 YAML 重解析。未引入通用缓存，也未跳过 Bundle 的来源重复采样或托管 hash proof。

阶段探针使用相应冻结构建产出的 `libzc`，通过 `rustc --edition 2024 -O -C lto=thin` 链接；首个未加 LTO 的探针链接尝试遇到 Apple linker/LLVM bitcode 版本不匹配，补齐与 release 一致的 LTO 参数后成功，没有改生产构建参数。

### 相同 Zig Release 二进制的最终对照

- 改动前：`target/perf/cli-parity-before.json`；最终：`target/perf/cli-parity-final.json`。
- 中间批次 `target/perf/cli-parity-after.json` 也保留，但它重建的 Zig binary hash 不同，**不用于声称相同 oracle 二进制的最终对照**。最终通过 `target/perf/freeze-cli-final.py` 冻结当前源码，仅重建 Rust，并明确复用 before 的 Zig 文件。
- 两端均为 Release，锁定 Cargo.lock；每项预热一组、七组交替采样。CLI 每组 3 个独立进程；网络每组 100 次完整 echo。fixture 相同（100/10000 条不匹配 DOMAIN + 最终 MATCH），所有 HOME/XDG 隔离、显式非 7899 端口、只访问 loopback。
- 所有源文件清单、构建命令/日志及 hash、binary 前后 hash 均在报告。before/final 的冻结 snapshot 在构建及测量期间均未改变；报告明确标记 dirty candidate / `formal_baseline: false`。

| 公共接口 | 改动前 Rust | 最终 Rust | 最终 Zig | 最终 Rust / Zig |
| --- | ---: | ---: | ---: | ---: |
| config dump，100 条规则 | 5.112 ms | 4.134 ms | 2.973 ms | 1.390 |
| config dump，10000 条规则 | 34.379 ms | 25.283 ms | 49.236 ms | 0.514 |
| 新 CONNECT + 4 KiB echo，100 条规则 | 213.7 μs | 208.6 μs | 225.6 μs | 0.924 |
| 新 CONNECT + 4 KiB echo，10000 条规则 | 232.9 μs | 229.9 μs | 232.1 μs | 0.991 |
| 常驻隧道 64 KiB echo，100 条规则 | 79.0 μs | 76.9 μs | 79.2 μs | 0.971 |
| 常驻隧道 64 KiB echo，10000 条规则 | 78.2 μs | 76.9 μs | 77.0 μs | 0.998 |

Rust 相对本轮 before：小配置减少 **19.1%（0.978 ms）**，大配置减少 **26.5%（9.095 ms）**。但最终小配置相对相同 Zig 二进制仍增加 **39.0%（1.161 ms）**；剩余启动固定成本尚未完全定位，不能直接合入性能门禁。大配置及网络结果仅适用于此 ASCII 规则/loopback 场景，不代表 Unicode 配置、WAN 或极限吞吐结论。

未剔除慢样本：最终小配置 dump 的七组 nearest-rank p95（即最大组）为 Rust **5.385 ms**、Zig **4.868 ms**，高于各自中位数；原始样本完整保留。历史 2.438 ms stream 异常也仍在后文记录，不因本轮未出现而删除。

| provenance | SHA-256 |
| --- | --- |
| before 完整 snapshot manifest | `c59510f7069c3f074e74badc80d679476db097b70cd132a8a6759dea5f0df083` |
| final 完整 snapshot manifest | `908075c9294a3a1578d23da2f9bfcd499d7a994c08e3894ee6f05de292089fa9` |
| before Rust binary | `4d9774ef4774e7eee8d53194f6314a7c7272ad57b366a5397dac7e3887a85044` |
| final Rust binary | `53f84315eabea8907934d1924b378e4c0d48f7c48716c044a89d3bd667ffa080` |
| before/final 共用 Zig binary | `26210d394f7710fbf7ab4280d0216ba49feeed93edeb54416d9d758a1600f28b` |

### RED/GREEN 与验证

- Config 命名节点、CLI 真实命名节点（含 typed inactive metadata）、完整文档尾部、native 协议 metadata 投影均先观察 RED 再修复。`target/perf/cli-parity-*-red.log`、`*-green.log` 保留记录；尾部 RED 包含在 `cli-parity-json-before.log`。
- 初次命名 Runtime fixture 暴露 macOS accepted socket 继承 nonblocking，已仅在 fixture 明确切回 blocking；首次 REJECT 断言误写 403，按现有 Rust 502 行为修正，未改生产转发错误码。
- 最终定向集成测试 **125 项通过**：config 14、config_parity 20、cli 8、cli_managed 20、service 3、override_script 22、daemon 14、daemon_races 6、store_legacy 18。包括 immutable/canonical Zig golden、Lua worker 上限、daemon 竞争及旧数据 proof。日志：`target/perf/cli-parity-final-tests.log`。
- 严格 Clippy 通过：`cargo clippy --locked --lib --bin zc --test config --test config_parity --test cli --test cli_managed --test service -- -D warnings`；日志 `target/perf/cli-parity-final-clippy.log`。
- 未修改的 `scripts/e2e/run-core.sh` 完整 PASS；独立 Rust TCP E2E 全部 PASS（包含 SS 三种 cipher/alias 与 Trojan verified TLS、SNI/trust/password 负向用例）。日志 `target/perf/cli-parity-final-core.log`、`target/perf/cli-parity-final-tcp.log`。obfs 的 `ContentLengthMismatch` 仍是刻意 oracle 负向输入。
- 仅格式化新测试片段和 `src/main.rs`，没有 tree-wide rustfmt。拥有范围的 `git diff --check` 通过；全树检查另有范围外 `THIRD_PARTY_NOTICES.md` 上游许可证空白，不在此任务修改。
- 没有执行 commit/push/pull/reset、真实安装、真实 HOME 迁移或生产端口启动。未触碰生命周期 CAS、managed hash 算法、provider cache/refresh、缺省 rules canonical 语义；未声称四平台原生运行或长稳通过。

## 历史批次：工具迁移范围与结论

本次迁移 eval、性能 helper、Debian 打包入口和隔离可靠性探测；没有修改生产 Rust/Zig 逻辑，没有安装、提交、推送或修改原 core E2E 脚本。

工具能够实际分发到 Rust，但**不能宣称整体迁移验收通过**：本轮 correctness/interop 发现范围外失败，CLI 小配置性能退化和一个未稳定复现的尾部异常仍需保留。

## 工具契约

- `scripts/eval/run.sh`：correctness → `cargo build/test --locked`；interop → `just e2e`；contract 保留 migrator、安装器临时环境回归、S1、S2，不删除场景。
- eval 报告改放 `target/eval/<run_id>/`，环境编译器字段为 `rust_version`。
- `examples/eval_rule_matrix.rs`：冻结 YAML 输入、相同 `RULE_MATRIX_*` 输出和失败退出码。目标及 winning-rule 均通过生产 router 校验，不另写 matcher。
- 原 Zig `Engine.init` 不启用 DNS。Rust matrix 合成配置给 IP/GEOIP 规则加 `no-resolve`，保持该独立纯匹配场景；DNS 行为不在这里冒充已测。PROXY 使用仅供路由、绝不拨号的 SS 节点；DIRECT/REJECT 使用内建节点。
- `examples/perf_runner.rs`：Release-only；至少五组样本、一组预热、单调时钟、真实文件/存储操作；不同低层存储操作不冒名对比，详见 [报告说明](../perf/reports/README.md)。
- 正式 baseline 仍拒绝脏工作区。当前只验证了拒绝路径和 Rust helper；未把未提交源码伪装成正式 clean-commit baseline。
- `scripts/build-deb.sh` 从 Cargo.toml 取版本，构建 Rust Release；要求 Linux，不在 macOS 上伪造 amd64 包。此次仅验证临时目录里的打包流程契约，未实际安装或生成可发布的 Debian 包。

### 复验入口

```bash
bash scripts/eval/selfcheck.sh
cargo build --locked --release --example eval_rule_matrix --example perf_runner
python3 scripts/eval/test-rust-helpers.py
python3 scripts/eval/test-tooling-contracts.py
python3 scripts/reliability/test-runner.py
bash scripts/eval/run.sh --suite contract
```

Justfile 未在本任务内修改。父任务应将旧 recipe `zig-eval`、`zig-eval-selfcheck` 分别改名为 `eval`、`eval-selfcheck`：它们现在调用 Rust 工具，不再是 Zig oracle。直接脚本入口已可使用。

## 同机 Release 实测

权威性：**探索性 dirty candidate，非正式性能基线、非性能 PASS**。

- 原始记录：`target/perf/rust-zig-snapshot.json`。
- 候选来源：`f1f62524c32e106015408fdcd5efff2eb284505e` 上的未提交快照；不把 HEAD 当作已包含 Rust 迁移。
- 平台：macOS 27 arm64，10 核；rustc 1.98.1，Zig 0.16.0。
- Rust：Cargo release；Zig：原源码 `ReleaseFast`，独立 prefix。没有生产 Zig 调用/FFI fallback。
- 快照逐文件清单、构建日志/命令、测试前后源码/二进制哈希均在原始 JSON；构建及测量期间快照未变化。
- 快照清单 SHA-256：`00061c31432f3b2296f571b978934e47be174ec4fcce47a81395bc84466e03ec`。
- Rust binary SHA-256：`d7f037398d1baa38fd87e407ab45f7506ae88fa56c6aca353525b96a316e02de`。
- Zig binary SHA-256：`3f774599385f42069df4a82bdc3eaa6069e69def10725216176a7181fbcbf497`。

每项一组预热、七组采样，交替 Rust/Zig 顺序，使用 `perf_counter_ns`。配置为相同的 100/10,000 条不匹配 DOMAIN 规则加最终 MATCH；配置字节与哈希均记录。所有进程使用临时 HOME/XDG、显式非 7899 端口、独立 loopback echo 服务；结束时清理自己启动的进程。

| 公共接口 | Zig 中位数 | Rust 中位数 | Rust / Zig |
| --- | ---: | ---: | ---: |
| config dump，100 条规则 | 3.179 ms | 5.205 ms | 1.637 |
| config dump，10,000 条规则 | 57.701 ms | 66.736 ms | 1.157 |
| 新 CONNECT + 4 KiB echo，100 条规则 | 243.79 μs | 209.14 μs | 0.858 |
| 新 CONNECT + 4 KiB echo，10,000 条规则 | 288.51 μs | 268.37 μs | 0.930 |
| 常驻隧道 64 KiB echo，100 条规则 | 77.79 μs | 78.49 μs | 1.009 |
| 常驻隧道 64 KiB echo，10,000 条规则 | 85.72 μs | 87.76 μs | 1.024 |

CLI 每组 3 次，包含进程启动、加载/校验、序列化与输出捕获，**不是纯 parser benchmark**。网络每组 100 次，校验完整响应内容；Python 客户端/echo 服务和操作系统调度也包含在耗时内，不能据此推导引擎极限吞吐。

### 退化与尾部异常

小配置 CLI 增加约 2.03 ms（63.7%），10,000 条规则增加约 9.04 ms（15.7%）。这是真实的公共接口退化；尚未定位到允许修改的 config/parser 局部，所以没有猜测性优化或宣称可以直接合入。

100 条规则的 Rust 64 KiB stream 有一组均值 **2.438 ms/op**，其余六组约 73–115 μs/op；Zig 最大组均值 102.9 μs/op。原始异常样本保留，七组的 nearest-rank p95 因而为 2.438 ms，而不是中位数附近的数值。

针对该异常，用相同冻结二进制、相同配置另写独立 socket 探针（`target/perf/independent-stream-repro.py`），预热各 100 次，再交替运行各 7×100 次并记录逐操作耗时：

| 独立复现 | Zig | Rust |
| --- | ---: | ---: |
| 组均值中位数 | 80.32 μs | 79.51 μs |
| 最大组均值 | 135.96 μs | 85.15 μs |
| 逐操作 p95 | 145.13 μs | 96.38 μs |
| 最大单次 | 175.17 μs | 182.79 μs |

原始记录为 `target/perf/independent-stream-repro.json`。本次没有复现 2.438 ms 的组均值；**原因未定，不删除首轮异常，不将复测当作正式性能放行**。

## 有界真实可靠性测试

```bash
# 显式选择空闲端口；冲突时拒绝，不自动换端口。
bash scripts/reliability/run-soak-real.sh \
  --seconds 15 --interval 1 --port 29001 \
  --output target/reliability/short-soak.json

bash scripts/reliability/run-chaos-round.sh \
  --seconds 5 --interval 1 --port 29002 \
  --output target/reliability/process-exit.json

# 可以安排长时运行，但本次没有执行。
bash scripts/reliability/run-soak-real.sh 24 --port 29003
```

- 使用真正 Rust foreground 子进程、冻结的临时可执行文件、临时 HOME/全部 XDG 目录，不调用已安装 zc，不借用真实用户配置。
- 默认生成 loopback DIRECT 配置；每次样本真实建立 CONNECT 并验证 4 KiB echo，而不是只检查 PID 或 doctor 字符串。
- 可选 `--config` 先捕获并校验固定字节；要求自包含、loopback-only、无额外 controller。相对 provider 依赖不自动复制。
- 任意转发失败或进程退出都令本次结果失败。信号中断有界清理子进程；报告和日志放 `target/reliability/` 或指定临时目录，不自动写历史报告。
- `run-soak.sh` 已转向真实 runner；process-exit 场景实际 kill/reap 后由 harness 拉起自己的子进程，记录恢复时间。它不证明产品有自动故障恢复能力。
- `run-chaos-round.sh` 明确只覆盖进程退出，不再伪造 DNS/代理故障 PASS。
- `run-rollback-check.sh` 对未实现的阈值热重载回滚返回 ERROR/2，而不是原来的模拟 PASS。

实测：15 秒 soak，16 次真实转发探测，零崩溃、零失败；报告 `target/reliability/rust-port-soak-final.json`。进程退出场景 5 秒、6 次探测，恢复 185.60 ms，零非注入崩溃及转发失败；报告 `target/reliability/rust-port-process-exit.json`。

这些短测**不等于历史 24h/72h 长稳、DNS 扰动、代理 failover 或热重载回滚验收**；报告始终显式标记 `historical_soak_complete: false`。eval 的完整 reliability suite 仍未接入门禁。

## 验证结果与范围外阻塞

- selfcheck：44 项通过；helper 外部 CLI 测试：5 项通过；打包/正式记录器 dirty 拒绝测试：2 项通过；soak 外部测试：3 项通过。
- contract：migrator、临时安装器回归、S1、冻结 S2 全部通过。报告：`target/eval/rust-port-contract-1789571165/summary.json`。
- correctness：已证明真实调用 Cargo，结果 FAIL；当时 `tests/cli.rs` 四项失败，旧版本断言 `1.0.1-rust.1` 与 Cargo `1.0.1` 不符，另有 `mixed-port: 0` fixture 的拒绝。报告：`target/eval/rust-port-correctness-1789571346/summary.json`。
- interop：已证明实际运行 `just e2e` 和未修改的 core 脚本，结果 FAIL；managed-start 为 `unsafe file ownership or hard links`，日志另含 obfs `ContentLengthMismatch`。报告：`target/eval/rust-port-interop-1789571346/summary.json`。不能用之前批次的 FULL PASS 覆盖本次失败。
- 针对两个 example 的严格 clippy 被范围外 `src/override_script.rs:1917` 的 `collapsible_if` 阻塞；没有关闭 lint 或修改他人文件。
- 本记录绑定上面的具体候选与运行批次；共享树后续变更需由父任务重新统一验收。本任务没有改 Justfile/workflows/Cargo.toml，也没有删除 Zig oracle 源码。
