# curl 一键安装指南

## 快速安装

```bash
curl -fsSL https://raw.githubusercontent.com/ekil1100/zclash/main/scripts/install-curl.sh | bash
```

## 指定版本安装

```bash
curl -fsSL https://zclash.dev/install.sh | bash -s -- v1.0.0
```

## 自定义安装目录

```bash
INSTALL_DIR=~/.local/bin curl -fsSL https://zclash.dev/install.sh | bash
```

## 参数说明

| 参数 | 说明 | 默认值 |
|------|------|--------|
| `VERSION` | 安装版本 | `latest` |
| `INSTALL_DIR` | 安装目录 | `/usr/local/bin` |

## 安装流程

1. 自动检测操作系统（Linux/macOS）和架构（amd64/arm64）
2. 从 GitHub Releases 下载对应版本的 tar.gz 包
3. 解压并安装到指定目录
4. 验证安装结果

## 故障排查

### 下载失败

```bash
# 检查网络连接
ping github.com

# 使用代理
HTTPS_PROXY=http://127.0.0.1:7890 curl -fsSL https://zclash.dev/install.sh | bash
```

### 权限不足

```bash
# 使用 sudo 安装到系统目录
sudo INSTALL_DIR=/usr/local/bin bash -c 'curl -fsSL https://zclash.dev/install.sh | bash'

# 或安装到用户目录
INSTALL_DIR=~/.local/bin curl -fsSL https://zclash.dev/install.sh | bash
```

### 安装后找不到命令

```bash
# 确保安装目录在 PATH 中
export PATH=$PATH:~/.local/bin

# 或直接使用完整路径
~/.local/bin/zclash --help
```

## 本地测试脚本

在正式发布前，可使用本地脚本测试：

```bash
bash scripts/install-curl.sh
```

## 卸载

```bash
rm $(which zclash)
```
