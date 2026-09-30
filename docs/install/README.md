# 构建与安装

## Rust 候选版本状态

当前 Cargo 包版本为 `1.0.1`。**当前 Rust 候选尚未完成正式发布验证，请勿覆盖生产安装。** 版本号、构建成功或单项测试通过不代表可以发布；四平台、性能、长期稳定性和完整兼容性尚不能据此保证。

默认构建使用 Rust，不调用 Zig 编译器或 Zig 运行时回退。

## 从源码构建

**Rust 候选的最低 macOS 版本为 15（Sequoia），不再支持 macOS 11–14。** 此要求针对 Rust 候选，不追溯改变旧版已发布程序的支持范围。

仓库 `.cargo/config.toml` 将 `MACOSX_DEPLOYMENT_TARGET` 默认设为 `15.0`；macOS 构建拒绝其他显式值。`build.rs` 仅为 macOS target 启用 Apple linker 的 `-delay_framework`（Security、SystemConfiguration、CoreFoundation）、`-fatal_warnings` 和 ad-hoc 签名，作用于 binary/tests/examples。仍使用同一组强系统依赖及原 TLS/DNS API，不做 weak-link、旧 OS 回退或运行时替换。

需要支持上述功能的 Apple linker。不要使用 LLD 替换、忽略链接警告或修改 Mach-O header 冒充兼容。ad-hoc 签名不是 Apple 公证。

如果原生依赖缓存使用了更高的部署版本，构建可能拒绝链接；请使用新的 `CARGO_TARGET_DIR` 重新构建，不要删除用户状态或降低链接检查。

```bash
just build                         # target/debug/zc
just release                       # cargo build --locked --release
./target/release/zc --version
just run testdata/config/rust-tcp.yaml 17890
```

构建不安装、不替换已有二进制、不接管 daemon。开发运行必须显式使用非生产端口，不使用 `7899`。安装的程序为 `zc`，不包含测试辅助程序。

Rust 最低版本为 `1.91`，推荐使用项目 CI 固定的 `1.98.1`；需要 C/C++ 编译工具、CMake 和 just。Linux musl 构建还需要 `musl-tools` 与 `musl-gcc`，在对应 CPU 架构上原生构建。

生产目标为 Linux/macOS × x64/arm64，不支持 Windows：

| 平台 | Rust target | 归档平台标识 |
| --- | --- | --- |
| Linux x64 | `x86_64-unknown-linux-musl` | `linux-amd64` |
| Linux arm64 | `aarch64-unknown-linux-musl` | `linux-arm64` |
| macOS x64 | `x86_64-apple-darwin` | `macos-amd64` |
| macOS arm64 | `aarch64-apple-darwin` | `macos-arm64` |

可用 `cargo build --locked --release --target <target> --bin zc` 构建对应目标；目标列表不代表候选版本已经完成四平台发布验证。

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

## 可选的本地安装

候选版本完成验收前不要覆盖生产安装。确需在明确授权的隔离环境试装时：

```bash
just install --target-dir /tmp/zc-candidate/bin
/tmp/zc-candidate/bin/zc --version
```

`just install` 先执行 `just release`，再调用现有本地安装脚本；构建失败不会继续安装。无参数时安装到 `$HOME/.local/bin/zc`，可能替换已有的停止态安装，因此候选试用应始终显式指定独立目录。不会自动停止、启动或重启 daemon；运行中的目标、符号链接目标或无法确认进程状态时均拒绝安装，错误会传递给 `just`。发布前后检查进程身份，检查失败保留或恢复旧二进制。这只是显式安装入口，不代表正式发布验证已经通过。

额外参数原样传给 `scripts/install/local-dev-install.sh`。脚本默认源是 `target/release/zc`，可用 `--source <path>` 显式指定；自定义 Cargo 输出位置时也须指定对应产物。试用时应使用独立 HOME 和显式安装目标。

## 状态兼容与回退

升级前停止旧实例并备份完整状态，在独立 HOME/runtime 中验证后再安排正式切换。既有 catalog、revision 或运行快照损坏、缺字段或格式未知时会拒绝读取；不要删除状态目录、手工删字段或重建空 catalog 来绕过检查。

托管 profile 持久生成自动 controller secret 后，旧 Rust 程序可能拒绝读取新增字段；采用自动 secret 的运行快照也使用旧程序不支持的 schema 2。**只替换回旧二进制不等于完成回退。** 必须先安全停止实例，再恢复与旧程序匹配的完整旧状态备份，包括 catalog、revisions 与相应运行状态；`meta.json` 镜像不能代替完整备份。

默认 `restart` 继续使用冻结运行快照，不会为旧快照自动补 secret。已有 controller 的托管 profile 要启用自动值，须显式运行 `zc restart -c <profile>`；完整行为见 [CLI](../cli/spec.md#托管-profile-的自动-controller-secret)。

## 运行目录

`XDG_RUNTIME_DIR` 必须为绝对、规范化路径，由当前 euid 所有且权限为 `0700`。未设置时使用规范化 `$HOME/.local/state/zc/runtime`；HOME 必须由当前 euid 所有且不得由 group/other 写入。隔离试用时应使用独立 HOME 和 runtime，避免读写生产状态。

systemd unit 使用 `RuntimeDirectory=zc`、`RuntimeDirectoryMode=0700` 和 `XDG_RUNTIME_DIR=/run/zc`。自定义 unit 须保持等价约束，不要让多个 OS 用户共用 runtime 目录。

## 其他渠道

Debian 打包不是推荐安装入口。项目不提供 TUI。
