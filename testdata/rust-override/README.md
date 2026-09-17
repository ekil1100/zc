# Rust override 物化交接

## 范围与行为依据

实现位于 `src/override_script.rs`；公开边界测试位于 `tests/override_script.rs`。

行为依据：

- `src/override.zig`（完整 Lua wrapper、参数、替换、dump）
- `src/override_materialization.zig`（冻结脚本及 patch 各 1 MiB、effective source 16 MiB）
- `docs/cli/spec.md`
- `docs/config/override.md`
- `docs/config/examples/override-loyalsoldier-rules.lua`

该版本 Zig wrapper 的上下文是 `input.command/config_path/script_path/args`，不存在 `context.helpers.*`。本实现没有虚构该接口。Lua 使用 vendored Lua 5.4，不依赖外部 lua/luajit；除原有 table/nil 外，也按迁移任务要求允许返回 YAML 字符串。不增加其它解释器或下载配置自动执行路径。

## 调用接口

- `OverrideArg::parse("key=value")`：只按首个 `=` 分割；key 两端仅裁空格/tab，值原样保留。
- `CliOptions::parse(&argv)`：argv 包括命令名，读取三种 override 参数，忽略其它 CLI 参数；`forward_args()` 可转发。
- `Invocation { command, config_path, script_path, timeout_ms, args }`：无 config path 用空字符串。`args` 保留重复项和顺序，Lua map 后值覆盖前值。
- `evaluate(script_bytes, &invocation)`：无外部 IO 的同步测试接口。仅捕获 `io.write`/`print`，提供 `os.getenv`；不是生产执行入口。
- `execute(&invocation).await`：显式选中文件，捕获后执行，返回 `ExecutedOverride`。
- `execute_bytes(&Script { name, bytes }, &invocation).await`：从 frozen script 重新执行，不要求原始文件仍存在。
- `merge(source, patch)` / `materialize_source(source, patch)`：纯数据层替换，不执行脚本，不解析 provider 内容，不承担完整 runtime capability gate。
- `ExecutedOverride::materialize(source, validate)`：合并后调用一次离线验证回调；包括空 patch。验证失败不返回可发布结果。调用方应在回调中完成配置能力验证；有 provider 时传入已捕获 assets，不能绕过 store 的最终准入验证。
- `dump_config_yaml` / `dump_config_json`：裸文档，敏感字段脱敏，转义终端控制字符，canonicalize `plugin_opts` 为 `plugin-opts`。
- `dump_runtime_config_yaml`：保留秘密、移除 provider 声明。必须传入已展开的配置；发现 `RULE-SET` 会拒绝，不能用移除声明来绕过 provider 准备。

数据层采用共享 `config::parse_document` 的 UTF-8、重复键、标签、全局 entry/depth 等限制；source 及 effective YAML 至多 16 MiB，patch 至多 1 MiB。另检查 4096 nodes、1024 groups、5120 mixed entries、每组 5122 members、4096 providers、262144 rules。provider 原始/normalized aggregate、展开后的 rule payload 及协议语义由配置层验证。

支持 patch key 精确为：`port`、`socks-port`、`mixed-port`、`allow-lan`、`bind-address`、`mode`、`log-level`、`external-controller`、`proxies`、`proxy-groups`、`rule-providers`、`rules`。集合整体替换，不递归合并。`external-controller: null` 删除字段，字符串 `"null"` 保留。与 Zig 的 `moveProxies` 一致：source 的 mixed proxies 中的 groups 会保留到独立 group 列表；仅修改 `proxies` 不会把 patch 内的 group 声明当作 group replacement。

原 source 不修改；空白 patch 的 effective bytes 与 source 完全一致。非空 patch 采用稳定顺序序列化；配置默认值仍由配置解析器负责，不在数据层生成另一套默认值。

## 冻结结果转换给 store

`Materialization` 不定义磁盘格式；转换为 store 自己的类型：

| 物化字段 | store 用途 |
|---|---|
| `source_bytes` | bundle 原始 source |
| `effective_yaml` | bundle 有效配置，不脱敏 |
| `script.name` | `FrozenOverride.script_name` |
| `script.bytes` | `FrozenOverride.script_bytes` |
| `invocation.command` | `FrozenOverride.command` |
| `invocation.config_path` | 空字符串映射 `None`，其它映射 `Some` |
| `invocation.timeout_ms` | `FrozenOverride.timeout_ms` |
| `invocation.args` | 按原顺序映射为 store `Param { key, value }` |
| `patch_bytes` | `FrozenOverride.patch_bytes` |

effective bytes 和脚本证据包含秘密，只能交给 owner-only revision/snapshot 写入器。该模块不写 catalog，不自动激活、不自动 reload。

非 Lua 脚本从随机、exclusive-create、0700 临时文件执行，结束后删除；这样运行字节与 frozen bytes 一致，不会再次执行已经变化的原路径。`ZC_OVERRIDE_SCRIPT_PATH` 保留 invocation 的逻辑路径；脚本进程的 `$0` 是临时执行路径。原始非 Lua 文件必须具有 executable 位，且所有原始脚本必须是 regular file。直接执行 `execute_bytes` 是调用方明确授权执行已捕获字节的入口。

## CLI 必须补上的 worker 分派

在 clap、daemon 及其它命令副作用之前检查首参数 `__override-worker`（常量 `WORKER_ARGUMENT`）：

1. 调用 `override_script::worker_main()`。
2. 成功直接退出 0；不输出 CLI envelope。
3. 失败将错误写到 stderr 并退出非零，不能继续常规命令分派。

父进程 Lua 路径固定为 `current_exe() __override-worker`。stdin 是 `WorkerRequest { script: Vec<u8>, invocation }` 的 JSON，至多 8 MiB；stdout 是原始 YAML，不是 JSON envelope。`WorkerRequest::decode` 是公开的有界协议检查入口。

worker 中允许标准 Lua `io`/`os`，因此不能把 `worker_main` 或其求值路径搬到 daemon 内的线程。父进程并行写 stdin、读取 stdout/stderr，两个输出分别限 1 MiB；deadline 为 1–60000 ms，默认 5000。失败、超时或输出超限时，Unix 下杀整个进程组并 wait/reap 主进程；没有无限阻塞线程替代方案。取消 future 时也会发送 kill，后续 reaping 由 Tokio child 管理。

Lua 内另有 64 MiB allocator 上限、指令 hook、deadline、表深度/entry/string 限制，拒绝 cycle、稀疏或混合键表及非法 UTF-8。纯 `evaluate` 的 hook 不能作为所有 Lua C 库调用的硬 wall-clock 保证；硬期限只能由独立进程父端提供。这里的隔离是生命周期/资源隔离，不是针对恶意显式脚本的 OS 权限沙箱。

环境先清空，再设置 `ZC_OVERRIDE_COMMAND/CONFIG_PATH/SCRIPT_PATH/TIMEOUT_MS/ARG_COUNT/ARG_n_KEY/ARG_n_VALUE/ARG_<SANITIZED>/ARGS`；不继承 HOME 或调用者的私密环境。legacy `ARGS` 仍为分号拼接；逐项参数和 Lua `input.args` 保留值中的分号、等号、换行和空字符串。

## 验证记录与待接入项

已保留 RED 证据：最初公开函数缺失导致编译失败；后续新增 mixed-proxy 保留及非 executable 拒绝测试实际失败，再实现通过。外部脚本首轮 RED 曾被其它 agent 尚未补齐的 `UdpSession::trojan` 编译错误阻断，没有修改该文件。

当前公开测试覆盖 17 个场景：参数、集合替换、非法 patch、Lua 结果、超时/内存/cycle/输出、文档示例、冻结证据、capability 回调、资源边界、脱敏/runtime dump、JSON worker 错误、真实可执行脚本/环境、stdout/stderr 溢出、Unix 进程组终止与主进程回收。全部 filesystem 测试使用真实临时目录，没有 HOME 状态或生产端口。

验证命令：

```sh
cargo test --test override_script
cargo clippy --lib --test override_script -- -W clippy::all
rustfmt --edition 2024 --check src/override_script.rs tests/override_script.rs
```

交接时 `src/main.rs` 尚未分派 `__override-worker`，因此没有 Lua `execute` → 真实 zc worker 的端到端 GREEN 证据。父任务接入后需补 Lua table/YAML/nil、`io.write` 与返回值组合、阻塞 `io.read`/`os.execute`、无限循环、stdout/stderr 超限及 worker 错误的真实子进程测试。不要改为在 daemon 内直接调用 `evaluate`。
