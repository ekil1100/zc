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
