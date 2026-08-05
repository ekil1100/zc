# zc install and validation

This page documents the current v1.0 install scripts that exist in this repository.

> v1.0 仍处于 release-candidate cleanup。Standalone installer 与 Homebrew Tap 可用于安装 rc 版本，但不代表 `v1.0.0` GA gate 已关闭。

## Standalone one-line installer

推荐入口不依赖 Homebrew，也不会调用 `sudo`：

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/ekil1100/zc/main/install.sh | sh
```

默认安装到 `${XDG_BIN_HOME:-$HOME/.local/bin}/zc`。Linux 使用静态 musl ELF；macOS
提供 standalone Mach-O，只依赖系统库。发布矩阵覆盖 Linux/macOS 的 amd64 与 arm64。

可固定版本或目录：

```bash
curl --proto '=https' --tlsv1.2 -fsSL \
  https://raw.githubusercontent.com/ekil1100/zc/main/install.sh \
  | ZC_VERSION=v1.0.0-rc6 ZC_INSTALL_DIR="$HOME/bin" sh
```

installer 先把 `latest` 解析为 immutable tag，再下载版本化归档及对应 `.sha256`；缺少
checksum、摘要不匹配、归档异常或 `zc --version` 自检失败都会保留旧二进制并非零退出。
最终替换使用目标目录内的临时文件、单安装器锁、旧二进制备份和原子 rename。installer
在发布前后都会检查目标状态；若 daemon 在检查与 rename 之间启动，新二进制会检测到
running 并原子恢复旧二进制。现有 `zc` 无法明确报告 stopped 时同样拒绝覆盖。先执行
`zc stop` 并确认状态。异常断电可能遗留
`.zc.install.lock`；只有确认其 `owner` PID 已不存在且没有安装进程后才能手动删除。

安装阶段需要系统已有的 POSIX `sh`、`curl`、`tar`、`awk`、`mktemp`，以及
`sha256sum`、`shasum` 或 `openssl` 之一；安装后的 `zc` 不需要这些工具。

## Homebrew Tap

macOS 或 Linux 的 amd64/arm64 用户可以从项目 Tap 安装当前 release candidate：

```bash
brew install ekil1100/tap/zc
zc --version
```

升级时使用同一个 fully qualified formula，避免与其他 Tap 的同名 formula 混淆。release candidate 之间可能迁移 runtime 路径，因此必须先用当前（旧）二进制停止 daemon，确认停止后再替换：

```bash
zc stop
zc status --json  # must report data.state == "stopped"
brew upgrade ekil1100/tap/zc
zc start          # only if it was running before the upgrade
```

如果 daemon 由 systemd 或其他 supervisor 管理，应通过 supervisor 先停止、升级，再启动；不要在替换后才调用新二进制的 `restart`。

发布工作流会为 macOS arm64/amd64 和 Linux arm64/amd64 生成二进制归档；Linux
归档必须通过 static linkage gate。GitHub Release 成功后会更新
`ekil1100/homebrew-tap` 中的 formula。

## Local install flow

The shortest local install flow is:

```bash
just install
```

This builds `zig-out/bin/zc` with `-Doptimize=ReleaseFast` and installs it to `~/.local/bin/zc` through `scripts/install/local-dev-install.sh`. `just install` binds lifecycle checks to the exact target `$HOME/.local/bin/zc`: it detects a running daemon with that old binary, verifies the tracked process was launched from that exact target path, stops it before replacement, verifies it stopped, then starts it with the new target binary. Success requires a changed PID and an executable device/inode matching the newly installed target, so `already_running` cannot accept a respawned old inode. If replacement or startup verification fails, an EXIT rollback restores the retained old binary and attempts to restart it. Automatic restart is limited to the default managed prepared invocation; foreground, explicit source, CLI port, and one-shot override invocations must be preserved manually through their supervisor. The lower-level `local-dev-install.sh` only replaces the binary and must not be used directly while a daemon is running.

The underlying maintained install workflow is script-based:

```bash
# Install a local shim/marker into a target directory
bash scripts/install/oc-run.sh install --target-dir /tmp/zc-install

# Verify installed files
bash scripts/install/oc-run.sh verify --target-dir /tmp/zc-install

# Upgrade requires an explicit version
bash scripts/install/oc-run.sh upgrade --target-dir /tmp/zc-install --version v1.0.0-rc6

# Optional rollback cleanup
bash scripts/install/oc-run.sh rollback --target-dir /tmp/zc-install
```

Expected behavior:

- every command prints machine-readable `INSTALL_*` fields;
- failures include `INSTALL_FAILED_STEP` and `INSTALL_NEXT_STEP`;
- rollback removes the install marker/version/shim produced by the local scripts.

## Runtime directory

直接运行时，已设置的 `XDG_RUNTIME_DIR` 必须是绝对、规范化路径，由当前 euid 所有且权限为 `0700`。未设置时 zc 使用规范化 `$HOME/.local/state/zc/runtime`；`HOME` 必须由当前 euid 所有且不得由 group/other 写入，zc 创建的后续目录收敛为 owner-only。zc 不再使用共享 `/tmp/zc.pid`、`/tmp/zc.lock` 或 `/tmp/zc.log`。

仓库中的 systemd unit 使用 `RuntimeDirectory=zc`、`RuntimeDirectoryMode=0700` 与 `XDG_RUNTIME_DIR=/run/zc`。自定义 unit 必须保持等价约束；不要把多个 OS 用户指向同一个 runtime directory。

## Regression gates

Run these before changing install behavior:

```bash
bash scripts/install/verify-install-flow.sh
bash scripts/install/verify-install-env.sh
bash scripts/install/verify-install-path-matrix.sh
bash scripts/install/verify-rollback-flow.sh
bash scripts/install/run-all-regression.sh
bash scripts/install/test-oneline-installer.sh
```

常规 install regression 应以 `INSTALL_ALL_RESULT=PASS` 结束。One-line installer E2E 只在
pull request、version tag 或显式本地执行时运行，并以 `INSTALLER_E2E_RESULT=PASS` 结束。

## Release validation

The full project gate includes install regression:

```bash
bash scripts/run-full-validation.sh
```

Expected output:

```text
VALIDATION_RESULT=PASS
```

## Other packaging channels

Standalone `install.sh` 是 Linux/macOS 的首选入口，Homebrew Tap 是可选入口。Debian
package 仍处于发布链路验证阶段，不作为当前推荐安装方式。

过时的历史打包说明位于 `docs/archive/install/`，不属于当前用户指南。

## No TUI in v1.0

Do not use or document the removed TUI command for v1.0. Related historical docs are archived.
