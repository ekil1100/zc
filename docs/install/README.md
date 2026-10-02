# 构建与安装

## Rust 候选版本状态

当前 Cargo 包版本为 `1.1.0-rc1`，发布范围为 **Linux x64 / arm64 预发布版**。请使用独立目录与测试配置试用，保留生产安装。该候选仅在同一提交的 main CI 中 Python 检查及两个 Linux 完整交付任务通过后发布；macOS、当前候选的官方 AnyTLS 互操作补验、性能和 24/72 小时长稳仍待验收。

本次预发布提供 Linux 静态 musl 归档、SHA-256 校验文件与安装脚本；不提供 macOS 归档、不更新 Homebrew，也不替换 GitHub Latest 稳定版本。此范围仅适用于 `v1.1.0-rc1`，其他候选与正式版本仍要求完整 main CI 和四平台发布流程。

发布后可在 Linux 上显式安装到独立目录：

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://github.com/ekil1100/zc/releases/download/v1.1.0-rc1/install.sh \
  | ZC_VERSION=v1.1.0-rc1 ZC_INSTALL_DIR="$HOME/.local/opt/zc-rc/bin" sh
"$HOME/.local/opt/zc-rc/bin/zc" --version
```

运行试用实例时仍需隔离 HOME/runtime，并显式使用非生产端口；独立二进制目录本身不隔离运行状态。

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

对通过 `zc service` 注册、且已确认属于当前安装路径及 HOME/runtime 的运行服务，独立安装器自动通过管理器停止、发布并恢复原冻结调用；这是冷升级，现有连接可能中断。首次安装或原本停止的服务保持停止。

手动启动或归属未知的运行实例需要先用原方式停止；安装器保留旧程序并拒绝自动停止或覆盖。安装目标是符号链接、注册或快照损坏、存在其他 runtime 的遗留进程，或无法检查进程身份时，同样拒绝替换。即使 `zc status` 报告 stopped，旧 inode 的遗留进程仍会阻止替换。无法追踪的实例须先核对 PID、路径和端口，再显式停止。异常断电留下的 `.zc.install.lock` 只能在确认其 owner PID 和安装进程均已不存在后手动删除。

安装阶段需要 POSIX sh、`/bin/bash`（检查进程组与内嵌发布器）、curl、tar、awk、mktemp 和 sha256sum/shasum/openssl 之一。Linux 进程检查需要 `/proc` 和 readlink，macOS 需要 lsof；这些不是安装后代理运行时的依赖。

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

`just install` 先执行 `just release`，再调用本地安装脚本。安装器把候选复制到目标目录内的私有临时文件，执行版本、冻结状态兼容检查，macOS Mach-O 还检查签名；全部成功后才考虑停止服务。构建、候选检查失败保持旧二进制与运行实例。

无参数目标为 `$HOME/.local/bin/zc`；候选试用仍应显式指定独立 HOME、runtime 和安装目录。首次安装保持停止；停止态升级保持停止。对通过 `zc service` 注册、且安装路径/HOME/runtime 与调用环境一致的运行实例，安装器通过服务管理器停止，使用已有 staging/rename 发布，再恢复原冻结调用。保留自启动偏好、认证配置、端口、runtime 和已应用节点选择，不使用 plain `zc start` 或当前 active profile 恢复。

发布或启动失败时尝试恢复旧二进制与精确旧调用。恢复成功仍非零退出并报 `SERVICE_INSTALL_ROLLED_BACK`；恢复失败报 `SERVICE_RECOVERY_FAILED`，保留目标目录的 `.zc.recovery.*` 和服务状态供核查。若原本停止，恢复过程也保持停止。目录中的 `.zc.install.guard/.zc.binary.lock` 为稳定锁，正常安装后保留；临时候选及成功事务的备份会清理。异常中断或恢复失败需要先核对状态和保留工件，再决定恢复，勿盲删状态或直接用默认配置启动。

### 安装中断与恢复

本地安装入口单独处理 SIGINT（Ctrl-C）和 SIGTERM，其他 CLI 命令的信号行为保持原样。接收中断后暂停推进升级，终止正在执行的管理器/检查/发布命令进程组，等待直接子进程退出并回收，再执行恢复；恢复期间继续等待收尾。每次外部命令最多 15 秒，清理的直接子进程回收另限 1 秒，readiness 最多 10 秒；这不是整个安装事务的总期限。

中断仍非零退出：进入事务前可报 `SERVICE_INSTALL_INTERRUPTED`；恢复成功报 `SERVICE_INSTALL_ROLLED_BACK`，原因明确含 `SERVICE_INSTALL_INTERRUPTED`；恢复失败报 `SERVICE_RECOVERY_FAILED` 并保留工件。停止前中断且原实例身份仍一致时保持其 PID；已停止才恢复原调用。若新实例已经出现，但管理器结果丢失、尚未捕获本次启动 PID，安装器保留备份并报恢复失败，不通过猜测停止该实例。先检查服务和管理器，再决定显式 stop/restart。命令组终止或直接子进程回收本身失败时，保留恢复工件并停止后续自动发布/恢复，先处理遗留命令进程。

命令组清理覆盖同用户、留在该进程组的发布脚本与辅助进程；受信任的自定义发布钩子应前台完成，保持用户身份和进程组。自行 `setsid`/后台脱离或提权的钩子不在此保证内。管理器启动的 daemon 由管理器独立托管，其停止仍走服务身份核对。

**SIGKILL、断电及进程崩溃需要人工核查**，进程无法自行执行恢复；SIGKILL 还可能留下独立发布进程组。不要立即重跑安装或仅凭锁已释放就覆盖目标：

1. 保留安装目录里的 `.zc.recovery.*`、`.zc.candidate.*`、`zc.tmp.*`、`zc.backup.*`，以及完整服务目录和 runtime；稳定 `.zc.install.guard/.zc.binary.lock` 保持原 inode。
2. 用 `ps -axo pid,ppid,pgid,command` 核对本次安装及发布脚本的实际路径、参数和进程组；确认并结束遗留发布组，等待其退出，再检查目标。只操作已核对的本次安装进程，勿按名称批量终止。
3. 使用原 HOME/runtime 和注册安装路径检查 `zc service status --json`，同时检查用户管理器的 PID/状态；若 binary 无法执行，先保留文件并由管理器核对、停止明确属于此注册的任务。身份不符或状态损坏时保留现场，先解决证据缺口。
4. 对照升级前记录/备份确认正确的 `.zc.recovery.*` 二进制及完整冻结状态。在已确认服务和发布进程都停止、没有并发安装后，以同目录 staging/rename 恢复已验证旧二进制；恢复完整状态时遵守下方格式兼容约束。最后显式 `zc service start` 使用冻结调用，检查端口、选择和自启动偏好，再清理已确认无用的工件。

这些工件提供恢复输入，未提供自动 SIGKILL 恢复日志或通用一键回退。必要输入缺失、格式不兼容或无法证明进程归属时，继续保留现场而非按 active/default 配置启动。

手动启动的目标维持安全拒绝，并提示显式迁移：先确认原 namespace 和调用参数，用原方式停止，再运行 `zc service start -c <config> --port <port>`。符号链接/外来目标、坏注册/快照、其他 runtime 的遗留进程、竞争中的新实例或无法检查进程时同样拒绝替换。安装器不会自动停止这些实例。

这是**自动保持状态的冷升级**，连接可能关闭，不提供热升级承诺。`just install` 与独立 Release 安装器使用同一套服务升级事务；Homebrew 仍由包管理器管理，不属于该自动服务升级入口。用户服务定义和命令见 [CLI](../cli/spec.md#当前用户服务)。

额外参数原样传给 `scripts/install/local-dev-install.sh`。脚本默认源是 `target/release/zc`，可用 `--source <path>` 显式指定；自定义 Cargo 输出位置时也须指定对应产物。试用时应使用独立 HOME 和显式安装目标。

安装来源须为当前用户所有、最多 256 MiB 的普通文件；允许 Cargo 构建产物这类已有多个硬链接的来源。安装器通过安全文件句柄有界捕获字节，读取前验证所有权和至少一个链接，读取期间的链接数、所有者、权限、长度或修改/变更时间变化均导致拒绝。捕获后在目标目录独立创建私有候选，再验证与发布；来源及其硬链接别名保持原字节，安装结果为独立、单链接文件。此许可仅适用于安装来源，既有安装目标、恢复备份及私有状态继续要求单链接。

独立 Release 安装器先完成下载、校验和版本自检，再确认候选支持 `zc-release-install-v1`。版本与安装契约检查各限 15 秒；检查期间收到 SIGINT/SIGTERM 时取消检查，终止检查进程组并回收直接子进程后退出，保持旧目标且不进入发布。该清理覆盖留在检查进程组中的子进程；自行脱离进程组的程序以及 SIGKILL、断电仍需人工核查。支持的候选使用与 `just install` 相同的服务升级事务：保留运行/停止状态、登录自启、配置、端口和已应用选择；中断时等待恢复完成后再清理下载文件。不支持该契约的旧版候选在停止或替换前拒绝，并提示显式停止、备份完整状态后手动回退。不支持的候选不会退回旧的强制覆盖流程。

## 状态兼容与回退

升级前停止旧实例并备份完整状态，在独立 HOME/runtime 中验证后再安排正式切换。既有 catalog、revision 或运行快照损坏、缺字段或格式未知时会拒绝读取；不要删除状态目录、手工删字段或重建空 catalog 来绕过检查。

托管 profile 持久生成自动 controller secret 后，旧 Rust 程序可能拒绝读取新增字段；采用自动 secret 的运行快照也使用旧程序不支持的 schema 2。**只替换回旧二进制不等于完成回退。** 必须先安全停止实例，再恢复与旧程序匹配的完整旧状态备份，包括 catalog、revisions 与相应运行状态；`meta.json` 镜像不能代替完整备份。

默认 `restart` 继续使用冻结运行快照，不会为旧快照自动补 secret。已有 controller 的托管 profile 要启用自动值，须显式运行 `zc restart -c <profile>`；完整行为见 [CLI](../cli/spec.md#托管-profile-的自动-controller-secret)。

## 运行目录

`XDG_RUNTIME_DIR` 必须为绝对、规范化路径，由当前 euid 所有且权限为 `0700`。未设置时使用规范化 `$HOME/.local/state/zc/runtime`；HOME 必须由当前 euid 所有且不得由 group/other 写入。隔离试用时应使用独立 HOME 和 runtime，避免读写生产状态。

`zc service` 使用登录用户的管理器，注册时固定 zc 的 HOME/runtime，并在生成的定义中显式传入；Linux 管理器自身的 bus 路径独立于该 runtime。无需 `/run/zc`、系统级 `RuntimeDirectory`、sudo 或 linger。自定义 supervisor 须保持等价的文件权限和单实例约束，不要让多个 OS 用户共用 runtime 目录。

## 其他渠道

Debian 打包不是推荐安装入口。项目不提供 TUI。
