# systemd 服务管理指南

## 快速开始

### 安装服务文件

```bash
# 复制服务文件
sudo cp scripts/zclash.service /etc/systemd/system/

# 重新加载 systemd
sudo systemctl daemon-reload
```

### 服务管理命令

```bash
# 启动服务
sudo systemctl start zclash

# 停止服务
sudo systemctl stop zclash

# 重启服务
sudo systemctl restart zclash

# 开机自启
sudo systemctl enable zclash

# 禁用开机自启
sudo systemctl disable zclash

# 查看状态
sudo systemctl status zclash
```

## 查看日志

```bash
# 实时日志
sudo journalctl -u zclash -f

# 最近 100 行
sudo journalctl -u zclash -n 100

# 今天日志
sudo journalctl -u zclash --since today
```

## 配置文件

服务默认使用 `/etc/zclash/config.yaml`，可修改服务文件中的路径：

```ini
[Service]
ExecStart=/usr/local/bin/zclash start -c /path/to/config.yaml
```

修改后重载：

```bash
sudo systemctl daemon-reload
sudo systemctl restart zclash
```

## 故障排查

### 服务无法启动

```bash
# 检查配置
zclash doctor

# 查看详细错误
sudo journalctl -u zclash -n 50 --no-pager
```

### 权限问题

确保配置文件可读：

```bash
sudo chmod 644 /etc/zclash/config.yaml
```
