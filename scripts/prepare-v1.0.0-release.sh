#!/usr/bin/env bash
set -euo pipefail

# v1.0.0 发布准备脚本（等 Like 确认后执行）
# 用法：确认后执行 bash scripts/prepare-v1.0.0-release.sh

echo "=== zc v1.0.0 Release Preparation ==="
echo ""
echo "步骤 1: 确认当前在 main 分支且工作区干净"
if [[ $(git branch --show-current) != "main" ]]; then
  echo "❌ 错误：不在 main 分支"
  exit 1
fi

if [[ -n $(git status --porcelain) ]]; then
  echo "❌ 错误：工作区有未提交更改"
  git status --short
  exit 1
fi
echo "✅ 分支和工作区检查通过"
echo ""

echo "步骤 2: 运行完整验证"
if ! bash scripts/run-full-validation.sh; then
  echo "❌ 错误：完整验证未通过"
  exit 1
fi
echo "✅ 完整验证通过"
echo ""

echo "步骤 3: 打 v1.0.0 tag"
git tag v1.0.0
echo "✅ tag v1.0.0 已创建"
echo ""

echo "步骤 4: Push tag 到远端"
echo "执行: git push origin v1.0.0"
read -p "确认执行? (yes/no): " confirm
if [[ "$confirm" == "yes" ]]; then
  git push origin v1.0.0
  echo "✅ tag 已推送"
else
  echo "⚠️ 已取消 push，本地 tag 保留"
  exit 0
fi
echo ""

echo "步骤 5: 监控 release workflow"
echo "请访问: https://github.com/ekil1100/zc/actions"
echo "等待 release workflow 完成..."
echo ""

echo "步骤 6: 验证 release 产物"
echo "检查: https://github.com/ekil1100/zc/releases/tag/v1.0.0"
echo "预期产物:"
echo "  - zc-v1.0.0-linux-amd64.tar.gz"
echo "  - zc-v1.0.0-linux-arm64.tar.gz"
echo "  - zc-v1.0.0-macos-amd64.tar.gz"
echo "  - zc-v1.0.0-macos-arm64.tar.gz"
echo "  - 每个归档对应的 .tar.gz.sha256"
echo "  - install.sh"
echo ""

echo "步骤 7: 更新 README 下载链接（如有必要）"
echo "确认 release 成功后，README 已包含正确下载链接"
echo ""

echo "=== 完成 ==="
