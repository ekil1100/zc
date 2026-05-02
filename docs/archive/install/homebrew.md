# Homebrew 安装指南

## 快速安装

```bash
# 添加 tap 并安装
brew tap ekil1100/zclash https://github.com/ekil1100/zclash
brew install zclash

# 或使用本地 formula
brew install --formula homebrew-zclash/zclash.rb
```

## 从源码构建（开发版）

```bash
git clone https://github.com/ekil1100/zclash.git
cd zclash
brew install zig  # 如果未安装
zig build
sudo cp zig-out/bin/zclash /usr/local/bin/
```

## 验证安装

```bash
zclash --help
zclash doctor
```

## 启动服务

```bash
# 前台启动 TUI
zclash tui

# 后台启动服务
zclash start

# 查看状态
zclash status
```

## 故障排查

### 命令未找到

```bash
# 确保 /usr/local/bin 在 PATH 中
export PATH=$PATH:/usr/local/bin

# 或直接使用
/usr/local/bin/zclash
```

### 升级

```bash
brew upgrade zclash
```

### 卸载

```bash
brew uninstall zclash
brew untap ekil1100/zclash
```
