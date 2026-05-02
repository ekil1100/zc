# Debian/Ubuntu 安装指南

## 使用预构建包

### 下载 .deb 包

从 [GitHub Releases](https://github.com/ekil1100/zclash/releases) 下载对应架构的 .deb 包：

```bash
wget https://github.com/ekil1100/zclash/releases/download/v1.0.0/zclash_1.0.0_amd64.deb
```

### 安装

```bash
sudo dpkg -i zclash_1.0.0_amd64.deb

# 如果缺少依赖
sudo apt-get install -f
```

## 从源码构建

```bash
# 克隆仓库
git clone https://github.com/ekil1100/zclash.git
cd zclash

# 安装依赖
sudo apt-get install zig

# 构建 Debian 包
bash scripts/build-deb.sh

# 安装生成的包
sudo dpkg -i dist/zclash_1.0.0_amd64.deb
```

## 使用 systemd 服务

安装后自动配置 systemd 服务：

```bash
# 启动服务
sudo systemctl start zclash

# 开机自启
sudo systemctl enable zclash

# 查看状态
sudo systemctl status zclash

# 查看日志
sudo journalctl -u zclash -f
```

## 验证安装

```bash
zclash --help
zclash doctor
```

## 卸载

```bash
sudo dpkg -r zclash
```
