# zc install and validation

This page documents the current v1.0 install scripts that exist in this repository.

> v1.0 仍处于 release-candidate cleanup。Homebrew Tap 可用于安装 rc 版本，但不代表 `v1.0.0` GA gate 已关闭。

## Homebrew Tap

macOS 或 Linux amd64 用户可以从项目 Tap 安装当前 release candidate：

```bash
brew install ekil1100/tap/zc
zc --version
```

升级时使用同一个 fully qualified formula，避免与其他 Tap 的同名 formula 混淆：

```bash
brew upgrade ekil1100/tap/zc
```

发布工作流会为 macOS arm64、macOS amd64 和 Linux amd64 生成二进制归档，并在 GitHub Release 成功后更新 `ekil1100/homebrew-tap` 中的 formula。

## Local install flow

The shortest local install flow is:

```bash
just install
```

This builds `zig-out/bin/zc` with `-Doptimize=ReleaseFast` and installs it to `~/.local/bin/zc` through `scripts/install/local-dev-install.sh`. It replaces the local binary only; it does not stop or restart an already running daemon.

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
