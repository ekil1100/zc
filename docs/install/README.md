# zc install and validation

This page documents the current v1.0 install scripts that exist in this repository.

> v1.0 is still in release-candidate cleanup. Public release artifact URLs are intentionally not documented here until the release workflow is aligned and `v1.0.0` is tagged.

## Local install flow

The maintained install workflow is script-based:

```bash
# Install a local shim/marker into a target directory
bash scripts/install/oc-run.sh install --target-dir /tmp/zc-install

# Verify installed files
bash scripts/install/oc-run.sh verify --target-dir /tmp/zc-install

# Upgrade requires an explicit version
bash scripts/install/oc-run.sh upgrade --target-dir /tmp/zc-install --version v1.0.0-rc3

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

## After v1.0.0 is tagged

Only after release workflow validation should this page grow public install methods such as:

- GitHub Release tarball install;
- Homebrew formula;
- Debian package;
- curl installer.

Until then, stale historical packaging notes live in `docs/archive/install/` and are not current user guidance.

## No TUI in v1.0

Do not use or document the removed TUI command for v1.0. Related historical docs are archived.
