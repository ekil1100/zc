# zc install and validation

This page documents the current v1.0 install scripts that exist in this repository.

> v1.0 仍处于 release-candidate cleanup。Homebrew Tap 可用于安装 rc 版本，但不代表 `v1.0.0` GA gate 已关闭。

## Homebrew Tap

macOS 或 Linux amd64 用户可以从项目 Tap 安装当前 release candidate：

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

发布工作流会为 macOS arm64、macOS amd64 和 Linux amd64 生成二进制归档，并在 GitHub Release 成功后更新 `ekil1100/homebrew-tap` 中的 formula。

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
```

The aggregate gate should end with:

```text
INSTALL_ALL_RESULT=PASS
```

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

Homebrew Tap 是当前唯一文档化的 release-candidate 二进制安装入口。只有相关发布链路验证完成后，才增加以下公开安装方式：

- GitHub Release tarball installer;
- Debian package;
- curl installer.

过时的历史打包说明位于 `docs/archive/install/`，不属于当前用户指南。

## No TUI in v1.0

Do not use or document the removed TUI command for v1.0. Related historical docs are archived.
