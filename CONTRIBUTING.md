# Contributing to zc

感谢你对 zc 的兴趣！以下是参与项目的方式。

## 问题反馈

### Bug 报告

如果你发现了 bug，请通过以下方式报告：

1. **Feishu 群组**（推荐）- 直接发送问题描述
2. **GitHub Issues** - 创建 Issue 并提供以下信息：
   - zc 版本 (`zc --version`)
   - 操作系统和架构
   - 复现步骤
   - 期望行为 vs 实际行为
   - 相关日志（脱敏后）

### 功能建议

欢迎提出功能建议！请描述：
- 使用场景
- 期望的行为
- 可能的实现方式（可选）

## 开发贡献

### 开发环境

```bash
# 克隆仓库
git clone https://github.com/ekil1100/zclash.git
cd zclash

# 安装依赖
# - Zig 0.15.0+
# - git

# 构建
zig build

# 运行测试
zig build test
```

### 提交前格式检查

当前默认开发路径是 Rust，工具链和构建要求以 `AGENTS.md`、`Cargo.toml` 及 `Justfile` 为准。使用 `pre-commit` 管理 hook，配置位于随 Git 同步的 `.pre-commit-config.yaml`。安装工具后，每个新克隆启用一次：

```bash
uv tool install pre-commit
just hooks-install
```

`git commit` 会由 `pre-commit` 暂时收起已跟踪文件中未暂存的修改，执行 Rust 格式检查 `cargo fmt --all -- --check`，对提交中的 Python 脚本执行 Ruff 格式检查，再恢复原修改；格式不合格就阻止提交。hook 不自动格式化或重新暂存文件；即使工作区已经修好、暂存区仍是未格式化版本，也不能通过。失败后执行：

```bash
just fmt         # Rust
just python-fmt  # Python
# 检查差异后重新暂存需要提交的文件，再提交。
```

hook 需要 Cargo 和 rustfmt（缺少时可运行 `rustup component add rustfmt`）。它只做格式检查，不替代测试或 Clippy。`pre-commit run --all-files` 可手动检查，`just hooks-test` 在临时仓库验证实际提交及部分暂存行为，需预先安装 `pre-commit`；CI 现有格式门禁不依赖安装 Git hook。

若配置过 `core.hooksPath`，须先确认原 hook 的用途并迁移，再运行 `pre-commit install`；安装器不会静默覆盖该设置。不要盲目移除他人的 hook 配置。

### Python 脚本检查

`ruff.toml` 统一管理 `scripts/`、`examples/support/` 和 `tests/fixtures/` 下的 Python 脚本，固定 Ruff 版本为 `0.16.8`，基础规则检查未定义变量、未使用导入及常见语法问题。格式化目标为 Python 3.9，避免无意提高通用脚本的解释器要求；许可证生成器仍按其既有要求使用 Python 3.11 或更新版本。

```bash
just python-fmt    # 使用 uvx 调用固定版本，统一排版
just python-check  # 只检查格式和基础静态错误
```

上述命令需要 `uv`，不会创建 Python 应用环境或给 zc 运行时添加依赖。pre-commit 会自动管理固定版本的 Ruff 环境，首次运行需要下载；hook 仅做格式检查，Python 静态检查放在本地 `just python-check` 和 CI 中，Clippy 仍由 `just check` 和 CI 执行。

### 代码规范

- **提交信息**: 使用 conventional commits 格式
  - `feat: 新功能`
  - `fix: 修复`
  - `docs: 文档`
  - `test: 测试`
  - `refactor: 重构`

- **代码风格**: 遵循项目现有风格
  - 使用 `zig fmt` 格式化
  - 函数和变量使用 snake_case
  - 类型使用 PascalCase

### 提交 PR

1. Fork 仓库并创建分支 (`git checkout -b feature/amazing-feature`)
2. 提交更改 (`git commit -m 'feat: add amazing feature'`)
3. 推送到分支 (`git push origin feature/amazing-feature`)
4. 创建 Pull Request

### PR 检查清单

- [ ] 代码通过 `zig build test`
- [ ] 新功能包含测试
- [ ] 文档已更新（如需要）
- [ ] 提交信息符合规范

## 文档贡献

文档改进同样受欢迎！

- 发现文档错误？直接提 Issue 或 PR
- 希望添加示例？提交到 `docs/examples/`
- 翻译文档？请联系维护者

## 测试贡献

### 配置文件样本

如果你有特殊的配置场景，欢迎提交样本：
- 放置到 `testdata/config/`
- 脱敏（替换真实服务器/密码）
- 在 PR 中说明测试场景

### 回归测试

运行回归测试套件：

```bash
# 配置迁移器回归
bash tools/config-migrator/run-all.sh

# 安装流程回归
bash scripts/install/run-all-regression.sh

# Beta 验收清单
bash scripts/install/run-beta-checklist.sh
```

## 安全报告

如果你发现了安全问题，请：
- **不要**在公开 Issue 中报告
- 直接联系维护者（Feishu 私信）

## 行为准则

- 尊重他人，保持友善
- 接受建设性批评
- 关注对社区最有利的事情

## 许可证

通过贡献代码，你同意你的贡献将在项目许可证下发布。

## 联系方式

- Feishu 群组：zc 开发群
- GitHub Issues：https://github.com/ekil1100/zclash/issues

---

感谢你的贡献！🎉
