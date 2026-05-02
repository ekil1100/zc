# 快速启动指南（3 分钟上手）

> 从零到可用，3 步搞定。

## 前置条件

- macOS 或 Linux
- bash 可用（大多数系统默认就有）

## 第 1 步：安装

```bash
bash scripts/install/oc-run.sh install --target-dir ~/.local/bin/zclash
```

**期望输出：**
```
INSTALL_RESULT=PASS
INSTALL_ACTION=install
```

**失败了？** 看 `INSTALL_FAILED_STEP` 和 `INSTALL_NEXT_STEP`，按提示操作：
- `mkdir` → 目录没权限，换个你能写的路径（比如 `/tmp/zclash-bin`）
- `arg-parse` → 参数不对，检查命令拼写

## 第 2 步：验证

```bash
bash scripts/install/oc-run.sh verify --target-dir ~/.local/bin/zclash
```

**期望输出：**
```
INSTALL_RESULT=PASS
INSTALL_ACTION=verify
```

**失败了？**
- `marker-missing` → 第 1 步没成功，回去重新 install
- `binary-missing` → 可执行文件丢了，重新 install
- `version-missing` → 版本文件丢了，重新 install

## 第 3 步：升级（可选，验证升级通道可用）

```bash
bash scripts/install/oc-run.sh upgrade --target-dir ~/.local/bin/zclash --version v0.2.0
```

**期望输出：**
```
INSTALL_RESULT=PASS
INSTALL_ACTION=upgrade
```

**失败了？**
- `version-missing` → 漏了 `--version` 参数
- `not-installed` → 还没安装，先跑第 1 步

## 出了问题？

1. **一键诊断**：`bash scripts/install/trial-healthcheck.sh --target-dir ~/.local/bin/zclash`
2. **回滚清理**：`bash scripts/install/oc-run.sh rollback --target-dir ~/.local/bin/zclash`
3. **提反馈**：复制 `docs/install/trial-feedback-template.md` 填写后发给开发者

## 全套回归（可选，验证安装链路完整性）

```bash
bash scripts/install/run-all-regression.sh
```

看到 `INSTALL_ALL_RESULT=PASS` 就说明一切正常。
