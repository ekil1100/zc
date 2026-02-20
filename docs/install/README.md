# zc 安装指南

> 本文档整合所有安装方式，提供统一的安装入口。

## 快速选择安装方式

| 安装方式 | 适用场景 | 复杂度 |
|---------|---------|--------|
| [curl 一键安装](#curl-一键安装) | 快速体验，无需包管理器 | ⭐ 最简单 |
| [Homebrew](#homebrew-macoslinux) | macOS 用户，习惯包管理器 | ⭐⭐ 简单 |
| [Debian/Ubuntu](#debianubuntu) | Debian 系 Linux 服务器 | ⭐⭐ 简单 |
| [systemd 服务](#systemd-服务) | Linux 后台服务部署 | ⭐⭐⭐ 中等 |
| [源码构建](#源码构建) | 开发/定制/其他平台 | ⭐⭐⭐⭐ 复杂 |

---

## curl 一键安装

**推荐**用于快速体验或 CI/CD 环境。

```bash
curl -fsSL https://raw.githubusercontent.com/ekil1100/zclash/main/scripts/install-curl.sh | bash
```

**指定版本：**
```bash
curl -fsSL https://zclash.dev/install.sh | bash -s -- v1.0.0
```

**自定义目录：**
```bash
INSTALL_DIR=~/.local/bin curl -fsSL https://zclash.dev/install.sh | bash
```

👉 [详细 curl 安装文档](curl-install.md)

---

## Homebrew (macOS/Linux)

**推荐**用于 macOS 开发环境。

```bash
# 添加 tap 并安装
brew tap ekil1100/zclash https://github.com/ekil1100/zclash
brew install zclash
```

**升级：**
```bash
brew upgrade zclash
```

**卸载：**
```bash
brew uninstall zclash
brew untap ekil1100/zclash
```

👉 [详细 Homebrew 文档](homebrew.md)

---

## Debian/Ubuntu

**推荐**用于 Debian/Ubuntu 服务器部署。

```bash
# 下载 .deb 包
wget https://github.com/ekil1100/zclash/releases/download/v1.0.0/zclash_1.0.0_amd64.deb

# 安装
sudo dpkg -i zclash_1.0.0_amd64.deb

# 如缺少依赖
sudo apt-get install -f
```

**卸载：**
```bash
sudo dpkg -r zclash
```

👉 [详细 Debian 文档](debian.md)

---

## systemd 服务

**推荐**用于 Linux 后台持久化运行。

```bash
# 复制服务文件
sudo cp scripts/zclash.service /etc/systemd/system/
sudo systemctl daemon-reload

# 启动并设置开机自启
sudo systemctl enable --now zclash
```

**常用命令：**
```bash
sudo systemctl start zclash    # 启动
sudo systemctl stop zclash     # 停止
sudo systemctl restart zclash  # 重启
sudo systemctl status zclash   # 查看状态
sudo journalctl -u zclash -f   # 查看日志
```

👉 [详细 systemd 文档](systemd.md)

---

## 源码构建

**适用于：** 开发调试、非支持平台、定制功能。

### 依赖

- [Zig](https://ziglang.org/) 0.15.0+
- git

### 构建步骤

```bash
# 克隆仓库
git clone https://github.com/ekil1100/zclash.git
cd zclash

# 构建
zig build

# 安装到系统目录
sudo cp zig-out/bin/zc /usr/local/bin/
```

### 开发构建

```bash
# Debug 构建
zig build -Doptimize=Debug

# 运行测试
zig build test
```

---

## 安装后验证

无论使用哪种安装方式，都建议执行验证：

```bash
# 查看版本
zc --version

# 查看帮助
zc --help

# 健康检查
zc doctor

# 启动 TUI
zc tui
```

---

## 故障排查速查

### 命令未找到

```bash
# 检查 PATH
export PATH=$PATH:/usr/local/bin:~/.local/bin

# 或使用完整路径
/usr/local/bin/zc --help
```

### 权限不足

```bash
# 方案 1：使用 sudo
sudo zc start

# 方案 2：安装到用户目录
INSTALL_DIR=~/.local/bin curl -fsSL https://zclash.dev/install.sh | bash
```

### 配置文件问题

```bash
# 检查配置
zc doctor

# 使用示例配置
mkdir -p ~/.config/zc
cp testdata/config/minimal.yaml ~/.config/zc/config.yaml
```

👉 [详细故障排查与回滚指南](risk-rollback.md)

---

## 卸载

| 安装方式 | 卸载命令 |
|---------|---------|
| curl | `rm $(which zc)` |
| Homebrew | `brew uninstall zc && brew untap ekil1100/zclash` |
| Debian | `sudo dpkg -r zc` |
| 源码 | `rm $(which zc)` |

---

## 更多文档

- [快速启动指南（3分钟上手）](quick-start.md)
- [试用反馈模板](trial-feedback-template.md)
- [风险与回滚策略](risk-rollback.md)

---

## 旧版文档索引

以下文档保留用于历史参考，内容已整合到本文档：

- ~~P6-2A 一键安装最小方案契约~~ → 已整合到各安装方式章节
- ~~Beta 试用验收清单~~ → 使用 `run-beta-checklist.sh`
- ~~验收命令~~ → 见各安装方式的验证章节

---

*最后更新：2026-02-20*
