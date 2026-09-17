# macOS Framework 延迟初始化可行性

## 结论

**可行，但有部署条件：使用支持 `-delay_framework` 的 Apple linker，最低部署版本设为 macOS 15.0，现有 Rust 单二进制可延迟 Security / SystemConfiguration / CoreFoundation 的初始化，无须新增依赖、unsafe、FFI shim 或改写 TLS/DNS 实现。** 本机 macOS 27 arm64 的安全 Rust API 探针及真实 `main.rs + libzc.rlib` 重链接均成功；x86_64 完成独立重链接和代码检查，未执行。[1][2][3]

**不是无条件的生产放行：**

- 基线 Mach-O 的最低版本是 **11.0**。本机 linker 对最低版本 11/14 明确警告并忽略 delay-init；15 才生成延迟标记。若必须维持同一产物支持 macOS 11–14，目前没有经本任务证明、受支持的仅链接参数方案。不能偷偷抬高最低版本，也不能修改 Mach-O 最低版本来冒充向后兼容。
- 延迟的是 **初始化、ObjC 通知和相关首次使用工作**，不是不映射 Framework：依赖依然是非 weak 的 `LC_LOAD_DYLIB`。真实候选 image 记录仍为 546 条，而 version 的 initializer trace 从 388 降至 7。不能拿 `otool -L` 仍列出 Framework 或 image 数未减判断失败。[2]
- 本轮同组重链接对照：dump-100 **4.069 → 3.510 ms**，version **3.480 → 2.907 ms**。有实际收益，但不能用本轮数字改写原性能验收，更不能宣称已消除旧报告全部 1.4 ms 或关闭门禁。
- 未枚举真实 User/Admin/System trust，未做旧 OS / Intel 原生执行、全量 clean Cargo rebuild、长稳或正式性能门禁。原安全实现未换；“源码路径保留”不等于上述环境的执行验收。

## 范围、来源与工件

2026-09-17；完整阅读了 [`diagnosis-cli-cost/REPORT.md`](../../target/perf/diagnosis-cli-cost/REPORT.md)、仓库 `AGENTS.md` 和已有 `docs/research/` 记录。沿用“结论—来源—实现选择—验证—限制”的研究文档约定。

本轮仅新增本文；全部探针、下载的原始资料、日志、冻结副本位于：

```text
target/perf/diagnosis-lazy-framework/
```

下文称此目录为 `P`。没有修改生产源码、Cargo、CI、Git index；没有 pull/commit/push/install/sudo、系统设置变更、daemon 启动或 7899 监听。本文没有 staging，交由父任务决定是否纳入提交。运行探针使用 `P/home`、`P/tmp`、隔离 XDG；只读当前系统 DNS 配置以及 loopback 临时端口，不访问真实用户 keychain。读取本机工具链和缓存 crate 源码不等于运行其用户 trust 枚举。

| 输入/工具 | 冻结证据 |
| --- | --- |
| 原 `target/release/zc` | SHA-256 `e0bb83117c1f0cb07a7cc299cb93e49135677fa489f2a792bc5bfc81dc3f95d3`，开始/结束一致 |
| arm64 `libzc.rlib` | `50106aeb3eab1d44fbd22d3ce94a3b6b1722c781332ae7087c37508f0f77b1b3`，与前轮报告一致 |
| Rust / LLVM | Rust 1.98.1 / LLVM 22.1.8 |
| 系统 | macOS 27.0，26A428，arm64 |
| linker / SDK | Apple `ld-27037.1` / macOS 27 SDK |
| 冻结与命令 | `relink-inputs.json`、`relink-commands.json`、`x86_64-relink-corrected-command.json`、`artifact-sha256.json` |

arm64 候选 SHA：eager `6e26a608518d7024145aeccc75225b385e65230194e3d0ba38c9eb8a2e9e894b`；delay `b96c6dec2028dab854d5a72d4b79907871f03d541a171d8763ba9ce4095ab77c`。这是冻结 release 库与真实入口重链接的证据，不是假称从 clean commit 完成 Cargo 构建。x86_64 使用已有 `target/cross-verification/` 缓存，输入哈希另记，不能冒充与 arm64 同源候选的跨架构复现。

## 原始资料：实际支持什么

### 1. 正确选项是 `-delay_framework`

本机 `xcrun ld -help` 返回 `unknown options: -help`，已保留失败；**本机 `man ld`** 和 Apple 官方 dyld 仓库的 `ld.1` 明确记录：

```text
-delay_framework name
-delay_library path_to_dylib
-delay-lx
```

含义为 delay initialized，不是 weak import。[1] 不采用未经确认的 `-delayed_framework` 拼写。

SDK `usr/include/mach-o/loader.h:713–732` 定义 `dylib_use_command`、`DYLIB_USE_DELAYED_INIT = 0x08`、marker `0x1a741800`，并注明 **First supported in macOS 15, iOS 18**。实际 load command 的路径 offset 是 28，不是旧格式的 24；命令本身仍为 `LC_LOAD_DYLIB`。官方 dyld 根据 marker 和结构大小解码独立 flags。[3] SDK 原文冻结为 `P/sources/sdk-loader.h`；公开 xnu HEAD 的旧 `loader.h` 尚无这段定义，不能用它否定本机 SDK，也不能把它当新格式的证据。

旧 `-lazy_framework` 不解决本问题：Apple ld64 源码明确降为 regular link，LLVM LLD 的选项定义也明确它是 deprecated alias。[4][5] 本机无 API 的 `entry-lazy` 最终甚至只剩 libSystem；这只说明无引用输入的处理，**不是成功延迟真实 Framework 的证据**。`-weak_framework` 允许依赖缺失，不保证推迟初始化；本轮 weak 的启动成本与 eager 接近。[1]

核查的 LLVM Mach-O Driver / Options / MachO.h 没有实现上述新 delay 选项/格式，不能把本机 Apple linker 的能力归给 Rust 所用 LLVM 或假定 `rust-lld` 同样支持。官方 ld64 开源快照是 **ld64-957.1**，不是本机新 linker 的完整实现；对新 linker 的具体指令行为，下文使用本机反汇编作为直接证据，不虚构公开源码实现。[4][5]

### 2. loader 与 linker 各负责一半

官方 dyld `recursiveMarkNonDelayed` 说明：[2]

1. delayed images 已经加载和绑定；shared-cache images 的这部分工作很轻。
2. 只有所有到达路径都允许延迟，才不运行其 initializers、不通知 ObjC。
3. 任意普通依赖路径、部分 weak-def/flat lookup 动态引用、interposing 等都可能使依赖图恢复 eager。
4. **激活方式是 `dlopen()` 对应 image**；激活后再递归初始化其普通依赖。re-export 与 delay-init 的非法组合被取消延迟。[2][6]

这段源码单独看，并不能证明普通函数调用会自动激活。决定性补证是本机 linker 在未改 Rust 调用点的情况下生成：

- `__TEXT,__delay_stubs`：函数调用入口；
- `__TEXT,__delay_helper`：Framework 激活 helper，以及数据 GOT 访问 helper；
- `_dlopenHelper$CoreFoundation` / `$Security` / `$SystemConfiguration` 和完成标志。

例如 arm64 的 `_kCFAllocatorDefault$loadHelper_x8` 先 `ldar` 检查完成标志，未完成则调用 `_dlopenHelper$CoreFoundation`；后者保存整数/向量寄存器，使用 Framework 路径调用 `dlopen`，返回后 `stlr` 发布完成，再恢复寄存器。x86_64 数据 helper 检查标志、调用 helper，完成后用 `xchg` 发布。证据为 `api-delay.helper-only.asm`、`zc-delay.helper.asm`、`zc-x86_64-delay.inspect`。

因此正确方案是 **让官方 linker 生成激活代码**，不是在应用里增加 `libloading`/`dlopen`。后者需要另外承担 unsafe 调用、生命周期和错误策略，没有必要且不符合本任务约束。

### 3. 非 lazy 符号、全局地址与初始化时序

现有 binding 不只调用函数，还读取 `kCFAllocatorDefault/Null`、`kCFBooleanFalse`、CF dictionary/array callbacks、`kSCDynamicStoreUseSessionKeys`。`nm -u`、`dyld_info -imports -fixups` 和 helper 反汇编确认这些符号仍在，普通 GOT 数据访问也得到保护；**不能只检查 PLT/函数 stub**。

但不是所有地址使用形式都可重写。合成 dylib 探针在两种架构上均验证：

```c
static int *volatile pointer = &initialized_value;
static int (*volatile function_pointer)(void) = sentinel;
```

与 delayed dylib 链接时被拒绝：`ptr64 use ... cannot be delayed`，退出 1。普通函数调用、运行时读取全局变量可以生成 helper。不得为了通过链接删除错误、改成 weak，或假定未来 binding 新增静态表也安全。当前 arm64 和缓存 x86_64 的完整 zc 链接图未遇到此错误。

### 4. 并发、构造器与缺失依赖

官方 `dlopen` 路径持有递归 API lock，执行延迟图划分和 initializers；初始化期间虽然释放 loader 写锁，仍保留 API lock。`beginInitializers` 负责图遍历的已访问状态。[7] linker 完成标志不是自行取代 loader 锁的 OnceLock：多个首次调用可同时进入 helper，仍由 dyld 串行化初始化。

合成 sentinel dylib 的 constructor 睡眠 20 ms、计数一次、将全局值设为 42。arm64 16 线程同步首次调用，20 个新进程均仅打印一次 `SENTINEL_INIT 1`，且位于 `MAIN_ENTERED` 和 `SENTINEL_OK` 之间；全局变量先于函数使用的独立进程也通过。真实安全 Rust 探针另有 12 线程同步首次 CF/SC/Security 使用，每线程 10 次；CF initializer 日志只有一次。

**缺失依赖保持 fail-closed**：将非 weak delayed sentinel 可执行文件复制到没有其 `@rpath` dylib 的目录，即使选择不调用 API，也在进入 main 前因 `Library not loaded` 退出（SIGABRT，-6）。这是强依赖已在启动时解析的直接验证，不会降级成空 roots、DIRECT 或替换 DNS。

限制：未破坏系统 shared cache 模拟真实 Framework 缺失；linker helper 的反汇编没有检查 `dlopen` 返回值，不能声称存在应用级可恢复错误处理。当前保证依赖于启动时已经成功加载/绑定的非 weak image；不采用可被替换的外部插件、运行期卸载或环境注入作为生产方案。任意 loader 故障、构造器重入、第三方 interposing 的全部组合未被本轮穷举。

## 可执行探针与结果

### 第一层：相同 Framework 依赖，无 API

`entry.c` 的第一条语句调用 `mach_absolute_time`。Python 父进程通过 ctypes 使用同一时钟并换算 timebase。每变体预热 4 次，7 组 × 30 次，轮转并反转顺序，保留全部样本；下表是组均值的中位数。计时不启用 DYLD verbose。

| 变体 | launch→main ms | 总计 ms |
| --- | ---: | ---: |
| libSystem only | 1.642 | 1.865 |
| Security + SystemConfiguration + CoreFoundation eager | 2.316 | 2.593 |
| 同三项 delay-init | 1.822 | 2.054 |
| 同三项 weak | 2.293 | 2.568 |

本轮 eager→delay 的 pre-main 差额约 **0.494 ms**。绝对成本与旧诊断有明显漂移；本机缓存/调度未锁定，不把旧 1.410 ms 和本轮差额强行相减分账，也不外推所有 OS。

### 第二层：实际 binding 首次使用

`api.rs` 使用 `#![forbid(unsafe_code)]`，直接复用缓存的成熟依赖：

| 模式，每项独立进程 | eager / delay 结果 |
| --- | --- |
| none | 均成功；delay 仅 5 条 main 前 initializer，eager 为 386 |
| CFString + CFDictionary 分配/读取 | 均成功 |
| SCDynamicStore creation + 当前 `State:/Network/Global/DNS` 字典 | 均成功，不打印网络配置内容 |
| Hickory `read_system_conf()` | 均成功；保留 DNS/search 解析路径 |
| Security `SecCertificate::from_der` + DER roundtrip | 均成功；只解析仓库 fixture，不读取 trust/keychain |
| `SSL_CERT_FILE` 单证书 fixture | 均成功 |
| `SSL_CERT_DIR` 独立目录单证书 fixture | 均成功，不设置 FILE，不走 native 枚举 |
| 12 线程首次 CF/SC/Security | 均成功 |

Rust 的首句另记录 `SystemTime` 时间戳和 `MAIN_ENTERED`；pre-main 单调时钟定量以 C 探针为准，不把 wall clock 混入该表。delay 的 CF 首次调用之后 initializer 总数升至 386；CF、SC、Security 所在传递图会一起激活，**不是承诺三个 Framework 可彼此独立初始化**。

原始 `api-results.json` 的 roots 首轮失败来自探针没有创建空目录，而非 linker；创建目录后 `roots-corrected-results.json` 和 trace 通过。失败原文保留。

### 第三层：真实 zc 调用链，而不是空程序

`build-relinks.py` 冻结真实 `src/main.rs` 与既有 `libzc.rlib`；eager/delay 都使用 Rust 1.98.1、thin LTO、codegen-units=1、最低 macOS 15、禁止 unsafe，差别仅三个 linker 参数。生产 `target/release/zc` 从未被覆盖。

| 公开命令 | 重链接 eager ms | 重链接 delay ms | 冻结原基线 ms |
| --- | ---: | ---: | ---: |
| `--version` | 3.480 | 2.907 | 3.525 |
| `--help` | 3.457 | 2.910 | 3.566 |
| `config dump ... --no-override --json`，100 DOMAIN + MATCH | 4.069 | 3.510 | 4.159 |

同一隔离 HOME、相同绝对 fixture；各命令每变体 210 个正式样本。version/help 完整字节等价；dump 完整 JSON value 等价；全部 exit code 为 0。原始样本在 `measurements.json`，没有删除慢样本，也没有运行或引入 Zig 回退。

真实 imports 继续包含 `SecTrustSettingsCopyCertificates`、`SecTrustSettingsCopyTrustSettings`、`SCDynamicStoreCreateWithOptions`、`SCDynamicStoreCopyValue` 和上述 CF 全局符号。version 的 eager/delay 日志分别为 388/7 条 initializer、均 546 条 image 记录。

`tests/outbound.rs` 原文件通过 `rustc --test` 和相同 delay flags 独立链接，以下各用一个新进程 `--exact` 运行，均通过：

- `trojan_tls_sends_fixed_wire_request_and_preserves_half_close`
- `trojan_default_rejects_untrusted_certificate_without_sending_request`
- `verified_trojan_ip_requires_explicit_dns_sni_without_dialing`
- `trojan_explicit_sni_rejects_ip_and_root_dot_before_dialing`
- `trojan_skip_identity_still_rejects_invalid_tls12_and_tls13_signatures`
- `ip_policy_pins_trojan_destination_but_preserves_tls_sni`

验证使用 loopback `:0`，仅提供独立无关 CA 的 `SSL_CERT_FILE` 和空 `SSL_CERT_DIR`，从而不触发真实用户 trust 枚举。无关 CA 保证“未信任服务端”测试没有偶然把服务端 fixture 加入根。

保留的失败记录：首个无关 CA 生成命令的空 OpenSSL config 被本机 LibreSSL 拒绝，导致两个需要根的测试报 `no usable system TLS trust roots`；补齐隔离 config 后仅重跑这两个失败项通过，其他已通过项未重复。x86_64 首次重链接遗漏 host proc-macro 搜索目录，补 `-L dependency=target/cross-verification/release/deps` 后成功。这些是探针环境修正，不是生产修复。

## 部署范围与最小 build seam

### 经证明的范围

| 目标 | 本轮证据 | 边界 |
| --- | --- | --- |
| macOS arm64，min 15 | 完整 zc 重链接、API/并发/相关 TLS 测试、27 上执行 | 15/26 等其他 OS 尚未执行 |
| macOS x86_64，min 15 | C 函数/数据 helpers、完整缓存 zc 重链接，三个 delay 标记 | 无 Intel 执行；不安装 Rosetta |
| macOS arm64/x86_64，min 11/14 | C 链接均警告并忽略 delay；Rust 默认 arm64 min 11 同样忽略 | 不能声称获得延迟收益 |
| Linux | 不应用这些选项 | 本任务不改变 Linux 构建/运行路径 |

最低 **运行 OS 15** 来自 SDK 格式契约与本机 linker 行为；最低 **构建 linker 版本** 只确认本机 `ld-27037.1`，不能因为格式在 15 引入就推定 Xcode 16 的 linker 已支持自动生成所有 helpers。旧 linker / LLD 应使构建检查失败，不能静默丢弃选项后宣称已修复性能。

`LC_LOAD_DYLIB` 的新编码沿用旧命令号，旧 loader 理论上可能按普通依赖解释额外 flags，但这**不是**最低版本 15 产物受支持地运行在 11–14 的承诺。本轮没有发现可保留 min 11、又由此 linker 生成 delay helpers 的受支持开关。若说“兼容回退”，只能指 OS loader 在可支持的格式/依赖图上选择 eager 初始化，绝不指另一个程序、Zig、PEM-only、resolv.conf 或关闭校验的运行时替代。生产最低版本政策需父任务明确。

### 最小 seam：最终链接，不是 TLS/DNS Module

在接受部署范围后，最小候选构建参数为：

```bash
MACOSX_DEPLOYMENT_TARGET=15.0 \
RUSTFLAGS='-C link-arg=-Wl,-delay_framework,Security,-delay_framework,SystemConfiguration,-delay_framework,CoreFoundation' \
CARGO_TARGET_DIR="$PWD/target/perf/diagnosis-lazy-framework/cargo-release" \
cargo build --offline --locked --release --bin zc
```

这是后续完整 Cargo 验收命令，**本轮未执行完整重建**。现有 rlib 保留的 `-framework` 元数据不必删除；本机重链接已验证追加 delay flags 后三项实际变为 delay-init。参数应仅用于 macOS target，不把 Apple flags 传给 Linux。

若以后需要固化到项目，可用已有构建配置；仓库当前没有 `build.rs` 时，一个仅判断 `CARGO_CFG_TARGET_OS == "macos"` 的 build script 输出 `cargo::rustc-link-arg=-Wl,...` 也是 Cargo 支持的 seam。[8] 部署版本仍须在构建环境明确设置，不能将 `cargo::rustc-env` 当成 linker 最低版本配置。应断言最终 load commands 的三个 delay flags、minOS 和无弱化符号，而不只检查 exit code。本文不新增该文件，不改变最低版本政策。

### 不需要或不接受的依赖改造

已读本机准确版本的 feature 和 binding：CoreFoundation 0.9/0.10、core-foundation-sys 0.8.7 的 `link` feature 只控制 native linkage，不提供首次激活；SystemConfiguration 0.7 / sys 0.6 没有 lazy-loading feature；Security 3.7 / sys 2.17 的 feature 主要控制平台 API 可用范围；libloading 0.9 的指定库 `new/open/get` 是 unsafe。[9]

本方案不更换这些依赖。rustls-native-certs 0.8.4 继续在环境变量分支以外按 **User → Admin → System** 合并 TrustSettings、保留 deny/TrustRoot/TrustAsRoot 规则；Hickory 0.26.3 继续读取 SCDynamicStore 的 ServerAddresses/SearchDomains，zc 继续使用 hosts、nameserver 校验及无公共 DNS fallback 的原路径。[10][11] 不以子进程导出 roots、PEM-only、手扫 keychain、resolv.conf 或“弱链接时当无配置”替代。

## 合入前仍需的回归与安全门禁

1. **构建契约**：锁定有能力的 Apple linker；arm64/x86_64 原生 release + tests 检查 minOS、delay flags、imports、helpers、codesign；未知选项、忽略延迟、`ptr64 cannot be delayed` 必须阻止候选被当作优化成功。15 最低 OS 和当前 OS 都要执行，不只构建。
2. **首次使用而非已预热测试**：新进程分别先读 CF 全局、先 SC、先 Security；并发 TLS + DNS；带初始化等待/重入的 constructor sentinel；确保没有新增 init-before-main 引用把图重新拉回 eager。
3. **信任根语义**：在独立测试用户/VM 内设置 User/Admin/System 冲突、deny 与空设置，验证原优先级和拒绝规则；FILE/DIR 有效、空、缺失、错误、组合分支与凭据不泄漏。真实用户 HOME 不可替代该 fixture。
4. **TLS/DNS**：继续原链/名称/SNI/TLS 1.2/1.3 签名负测和可信链正测；SystemConfiguration DNS/search 与 hosts、无 DNS/无 nameserver 拒绝、IPv4/IPv6、取消和并发边界。此次 FILE 分支测试不会覆盖 native trust 枚举。
5. **fail-closed**：持续保留缺失非 weak 依赖的子进程死亡测试；不得引入 weak、忽略 roots 错误后放行或 DIRECT fallback。构造器时机推迟是用户可观察变化，真实首次网络操作耗时、超时和并发安全必须纳入验收。
6. **正式性能**：同一个冻结候选重新跑现有差分门禁，包含真实首次 TLS/DNS 及 warm 数据面、RSS/tail、CLI dump/help/version；不得从本轮探索性 0.56 ms 推导全门禁 PASS，更不能放宽阈值。

## 复现命令与资料索引

已执行的关键命令/入口：

```bash
P="$PWD/target/perf/diagnosis-lazy-framework"
xcrun ld -v
xcrun ld -help                         # Recorded failure; use man ld.
MANPAGER=cat man ld
xcrun clang -O2 "$P/entry.c" \
  -Wl,-delay_framework,Security,-delay_framework,SystemConfiguration,-delay_framework,CoreFoundation \
  -o "$P/bin/entry-delay"
python3 "$P/build-relinks.py"
xcrun otool -l "$P/bin/zc-delay"
nm -u "$P/bin/zc-delay"
xcrun dyld_info -imports -fixups "$P/bin/zc-delay"
xcrun dyld_info -section __TEXT __delay_helper "$P/bin/zc-delay"
python3 "$P/check-sentinel.py"
python3 "$P/measure.py"
```

这些命令写入探针目录；冻结后的工件不应原地覆盖。要重建，复制探针到新的隔离目录并调整路径。`api.rs` 的 extern 路径见 `build-api.sh`；真实 outbound test 链接命令见 `outbound-build-command.json`。运行 test/API 时必须显式设置隔离 HOME、TMPDIR、XDG 和 fixture SSL_CERT_FILE/DIR；**不要直接在真实 HOME 下运行 trust 相关模式**。

原始资料快照位于 `P/sources/`；引用固定提交，Rust 在线文档为本次读取快照：

1. [Apple dyld-1378 的 ld 手册：delay_library / delay_framework](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/doc/man/man1/ld.1#L143-L213)；本机 `ld-man.txt`、`ld-help.txt`、`toolchain.txt`。
2. [dyld RuntimeState：延迟图与首次 dlopen 激活](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/dyld/DyldRuntimeState.cpp#L503-L632)。
3. [dyld 新 flags 解码](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/mach_o/UnsafeHeader.cpp#L1355-L1377)、[结构定义](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/mach_o/UnsafeHeader.h#L89-L103)；最低版本以本机 Apple SDK `sdk-loader.h:713–732` 的明确注释及 `entry-{arm64,x86_64}-{11.0,14.0,15.0}.build.log/.otool` 为直接证据，不能使用开源结构注释中的旧 offset 值代替实际 sizeof。
4. [Apple ld64-957.1：旧 lazy_framework 降级为 regular link](https://github.com/apple-oss-distributions/ld64/blob/f60a74eaa2c99585de1dc0f2820e7a9f8aaf522c/src/ld/Options.cpp#L3025-L3031)。
5. [LLVM Mach-O Options：deprecated lazy_framework](https://github.com/llvm/llvm-project/blob/739def2b4c571a48c62de25d16601be108fcdaff/lld/MachO/Options.td#L1123-L1135)、[Driver](https://github.com/llvm/llvm-project/blob/739def2b4c571a48c62de25d16601be108fcdaff/lld/MachO/Driver.cpp)。
6. [dyld：re-export 与 delay 的处理](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/dyld/JustInTimeLoader.cpp#L470-L479)、[initializer 遍历](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/dyld/Loader.cpp#L2625-L2703)。
7. [dyld dlopen API lock](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/dyld/DyldAPIs.cpp#L1367-L1384)、[持锁执行 initializers](https://github.com/apple-oss-distributions/dyld/blob/fd8d0c4d52320ebf64db34f3cb280310d905c5ae/dyld/DyldAPIs.cpp#L1671-L1703)。
8. [Rust `-C link-arg`](https://doc.rust-lang.org/rustc/codegen-options/index.html#link-arg)、[Cargo `rustc-link-arg`](https://doc.rust-lang.org/cargo/reference/build-scripts.html#rustc-link-arg)、[Rust native link modifiers](https://doc.rust-lang.org/reference/items/external-blocks.html#linking-modifiers)。
9. 对应发布版本的上游源码：[core-foundation-sys](https://docs.rs/crate/core-foundation-sys/0.8.7/source/src/lib.rs)、[system-configuration](https://docs.rs/crate/system-configuration/0.7.0/source/Cargo.toml)、[security-framework](https://docs.rs/crate/security-framework/3.7.0/source/Cargo.toml)、[libloading Unix API](https://docs.rs/libloading/0.9.0/libloading/os/unix/struct.Library.html)。本轮实际读取本机 registry 的上述准确版本，而非推测 Cargo feature 含义。
10. [rustls-native-certs 0.8.4：macOS trust 合并](https://docs.rs/crate/rustls-native-certs/0.8.4/source/src/macos.rs)、[环境变量入口](https://docs.rs/crate/rustls-native-certs/0.8.4/source/src/lib.rs)、[security-framework TrustSettings](https://docs.rs/crate/security-framework/3.7.0/source/src/trust_settings.rs)。
11. [Hickory 0.26.3 SystemConfiguration 实现](https://docs.rs/crate/hickory-resolver/0.26.3/source/src/system_conf/apple.rs)；仓库 [`src/dns.rs`](../../src/dns.rs)、[`src/outbound.rs`](../../src/outbound.rs)、[`tests/outbound.rs`](../../tests/outbound.rs)。
