# 构建、安装与交付验证

## Rust 候选版本状态

当前 Cargo 包版本为 `1.0.1`。版本号、构建成功或单项测试通过**不代表迁移验收完成或可以发布**；候选版本仍需完成原有协议、CLI、daemon、安装与四平台发布门禁。是否发布由维护者根据完整证据决定。本文不作性能或完整兼容性声明。

默认构建、E2E 和验证入口已经使用 Rust，不调用 Zig 编译器或 Zig 运行时回退。原 Zig 源码与 `zig-*` 参考任务暂时保留，供迁移对照，不能用来替代 Rust 门禁。

## 从源码构建

**Rust 候选的最低 macOS 版本为 15（Sequoia），不再支持 macOS 11–14。** 用户已明确批准这个兼容性变更；它不表示性能和迁移验收已经放行。旧版 Zig Release 的历史支持范围不由本次修改追溯改变。

仓库 `.cargo/config.toml` 将 `MACOSX_DEPLOYMENT_TARGET` 默认设为 `15.0`；macOS 构建拒绝其他显式值。`build.rs` 仅为 macOS target 启用 Apple linker 的 `-delay_framework`（Security、SystemConfiguration、CoreFoundation）、`-fatal_warnings` 和 ad-hoc 签名，作用于 binary/tests/examples。仍使用同一组强系统依赖及原 TLS/DNS API，不做 weak-link、旧 OS 回退或运行时替换。

需要支持上述功能的 Apple linker；本机 Xcode 27 已实测，CI/Release 固定选择镜像中存在的 `/Applications/Xcode_26.3.app/Contents/Developer` 并以实际链接/产物检查决定是否通过，不把版本号本身当能力证明。未知选项、忽略延迟或部署版本冲突必须失败。不要使用 LLD 替换，也不要忽略警告或修改 Mach-O header 冒充兼容。

如果已有原生依赖缓存按宿主 SDK 27 构建，新增检查会拒绝把它们链接进 min15 产物。应使用新 `CARGO_TARGET_DIR`；本轮也验证了仅清理受影响的生成缓存 `cargo clean --locked -p mlua-sys -p blake3` 后重新构建。不要删除用户状态或降低链接检查。

```bash
just build                         # target/debug/zc
just release                       # cargo build --locked --release
./target/release/zc --version
just run testdata/config/rust-tcp.yaml 17890
```

构建不安装、不替换已有二进制、不接管 daemon。开发运行必须显式使用非生产端口，不使用 `7899`。生产程序只有 `zc`；`examples/` 下的三个程序仅用于测试，不打包、不安装。

CI 固定 Rust `1.98.1`，需要 rustfmt、Clippy、C/C++ 编译工具、CMake、Python 3、just。E2E 另需 Node.js 24、curl、tar、unzip、file、SHA-256 工具以及可用的 IPv4/IPv6 loopback、非 loopback IPv4 接口和 DNS。静态 fixture 下载需要访问 GitHub；原 core harness 还使用 `127-0-0-1.sslip.io`。Linux 构建安装 `musl-tools`，在对应 CPU 的原生 runner 上用 `musl-gcc`，不通过 Zig 或架构回退编译。

发布矩阵配置为：

| 平台 | Rust target | 归档平台标识 |
| --- | --- | --- |
| Linux x64 | `x86_64-unknown-linux-musl` | `linux-amd64` |
| Linux arm64 | `aarch64-unknown-linux-musl` | `linux-arm64` |
| macOS x64 | `x86_64-apple-darwin` | `macos-amd64` |
| macOS arm64 | `aarch64-apple-darwin` | `macos-arm64` |

每个目标使用 `cargo build --locked --release --target <target> --bin zc`。Linux 产物必须通过静态 ELF 检查。macOS 产物必须通过 `scripts/ci/verify-macos-artifact.py` 的 min15/强延迟/原生 imports/helpers 检查、`codesign --verify --strict` 和 `scripts/ci/test-macos-launch.py` 的短命令冷启动检查。ad-hoc 签名不是 Apple 公证。CI 增加 macOS 15 arm64，与 15 Intel、较新 arm64 系统一起验证；最新已通过的具体提交及尚未完成门禁见[迁移验收](../migration/completion.md)。

## 已发布版本的独立安装器

以下入口安装 **GitHub Release 实际提供的版本**，不构建或验证当前 Rust 候选：

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/ekil1100/zc/main/install.sh | sh
```

无需 Homebrew 或 `sudo`，默认目标为 `${XDG_BIN_HOME:-$HOME/.local/bin}/zc`。目录尚未在 `PATH` 中时，安装器会提示：

```bash
export PATH="${XDG_BIN_HOME:-$HOME/.local/bin}:$PATH"
```

可显式指定已发布版本和目录：

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/ekil1100/zc/main/install.sh \
  | ZC_VERSION=v1.0.1 ZC_INSTALL_DIR="$HOME/bin" sh
```

新的 macOS Rust 归档要求系统 15+；生成的 Homebrew formula 声明 `macos: :sequoia`。独立安装器仍先对下载产物执行版本自检，不兼容产物不能替换原程序。

归档和校验格式保持不变：`zc-v<version>-<os>-<arch>.tar.gz`、同名 `.tar.gz.sha256`，归档内同名目录包含 `zc`、README、LICENSE 和 THIRD_PARTY_NOTICES。Homebrew 消费同样的四种归档。

安装器先将 `latest` 解析为不可变 tag，再下载版本化归档及 SHA-256 文件。校验文件缺失、摘要不匹配、异常归档或 `zc --version` 自检失败都会保留旧程序并非零退出。替换使用目标目录内的临时文件、单安装器锁、旧二进制备份和原子 rename；发布后检查失败会恢复备份。

安装目标是 symlink、仍有可见进程执行该目标、无法确认 stopped 或无法检查进程身份时，拒绝覆盖。即使 runtime 路径已经变化、`zc status` 报告 stopped，旧 inode 的遗留进程仍会阻止替换。先用旧程序或 supervisor 停止实例；无法追踪的实例须先核对 PID、路径和端口，再显式停止。异常断电留下的 `.zc.install.lock` 只能在确认其 owner PID 和安装进程均已不存在后手动删除。

安装阶段需要 POSIX sh、curl、tar、awk、mktemp 和 sha256sum/shasum/openssl 之一。Linux 进程检查需要 `/proc` 和 readlink，macOS 需要 lsof；这些不是安装后代理运行时的依赖。

## Homebrew

```bash
brew install ekil1100/tap/zc
zc --version
```

升级前必须用旧二进制停止 daemon，确认状态后再替换；由 supervisor 管理时通过 supervisor 停止与恢复：

```bash
zc stop
zc status --json                    # Must report data.state == "stopped".
brew upgrade ekil1100/tap/zc
```

保留原配置、显式端口、override 和 supervisor 参数，再决定是否恢复运行。默认端口行为见相关运行文档；需要保留配置中的非默认端口时，应显式传入 `--port`。

发布工作流只接受版本与 Cargo 一致、对应 commit 已通过 main CI 的 tag；随后构建四平台归档、检查链接及版本、发布 Release，最后更新 Tap。单独本地构建不会触发发布或 Tap 更新。

## 可选的本地安装

候选版本完成验收前不要覆盖生产安装。确需在明确授权的隔离环境试装时：

```bash
just release
bash scripts/install/local-dev-install.sh --target-dir /tmp/zc-candidate/bin
```

脚本默认源是 `target/release/zc`，可用 `--source <path>` 显式指定。未指定目标目录时写入 `$HOME/.local/bin`；不要在测试中省略隔离 HOME 或显式目标。脚本不自动停止或重启 daemon，拒绝 symlink 和正在运行的目标，发布前后检查进程身份，检查失败保留或恢复旧二进制。

历史安装流程脚本仍有独立回归，用于校验 `INSTALL_*` 输出、版本要求和 marker/shim 回滚，不等同于真实 release 安装或 Rust 协议验收。

## 运行目录

`XDG_RUNTIME_DIR` 必须为绝对、规范化路径，由当前 euid 所有且权限为 `0700`。未设置时使用规范化 `$HOME/.local/state/zc/runtime`；HOME 必须由当前 euid 所有且不得由 group/other 写入。测试使用临时 HOME 和 runtime，不读写真实用户状态。

systemd unit 使用 `RuntimeDirectory=zc`、`RuntimeDirectoryMode=0700` 和 `XDG_RUNTIME_DIR=/run/zc`。自定义 unit 须保持等价约束，不要让多个 OS 用户共用 runtime 目录。

## 验证入口

```bash
just delivery-test                  # Task runner and release workflow contracts.
just helper-test                    # Helper process/socket behavior and crypto vectors.
just test                           # Rust public interface tests.
just e2e                            # Unchanged core harness, then Rust TCP harness.
just install-test                   # Temporary-directory installer regressions.
just validate                       # Formatting, lint, tests, E2E, installer, release build.
bash scripts/run-beta-gate.sh
bash scripts/run-full-validation.sh
```

`just e2e` 构建 `target/debug/examples/e2e_origin`、`e2e_obfs_oracle`、`e2e_ss_udp_oracle`，下载并校验固定版本 shadowsocks-rust `v1.24.0` 和 trojan-go `v0.10.6` 到 `target/e2e-fixtures`，随后原样调用 `scripts/e2e/run-core.sh`，再调用已有 `run-rust-tcp.py`。为满足 macOS runtime 路径约束，后者的临时目录入口先规范化。

SS UDP helper 的 socket、地址编码和 SOCKS 探针由独立 Rust 测试程序实现；加密使用嵌入的 Node/OpenSSL worker，不导入生产 `zc` 或 shadowsocks codec。worker 启动先验证独立生成的三密码字面 golden frame、坏 tag、截断、最大包和恢复路径。obfs helper 仅在请求精确校验、原始 TCP 转发及双向半关闭完成后输出 verified 证明。

安装回归在临时目录内实际测试替换、checksum、自检失败、锁、信号回滚、启动竞态、symlink 和运行中目标拒绝；不安装到真实 HOME，不自动接管生产 daemon。CI 另外使用 release 产物执行 core/TCP E2E 和安装器 smoke；原有默认端口测试仅保留在隔离 Linux CI，本地不得运行。

只有对应命令实际零退出并输出 `CORE_E2E_RESULT=PASS`、`INSTALLER_E2E_RESULT=PASS`、`BETA_GATE_RESULT=PASS` 或 `VALIDATION_RESULT=PASS`，才能记录相应门禁通过；不应根据部分 marker 推断全套通过。300 秒 UDP idle 测试仍需显式执行，默认 Rust 测试不会运行该 ignored 场景。

## 其他渠道

Debian 打包仍不是推荐入口，历史说明位于 `docs/archive/install/`。项目不提供 TUI。
