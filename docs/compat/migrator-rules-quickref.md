# 迁移规则速查表

> 快速查找 mihomo/clash → zc 配置迁移规则

## 规则总览（R1-R21）

| 规则 | 级别 | 一句话说明 | 示例配置 | 修复建议 |
|------|------|-----------|----------|----------|
| R1 PORT_TYPE_INT | warn | 端口值为字符串，应转为整数 | `port: "7890"` | `port: 7890` |
| R2 LOG_LEVEL_ENUM | error | log-level 值不在枚举范围内 | `log-level: verbose` | `log-level: info` |
| R3 PROXY_GROUP_TYPE_CHECK | error | 代理组类型无效 | `type: urll-test` | `type: url-test` |
| R4 DNS_FIELD_CHECK | warn/error | DNS 字段缺失或配置错误 | `nameserver: []` | 添加有效 DNS |
| R5 DNS_NAMESERVER_FORMAT | warn | nameserver 为纯 IP 缺协议 | `8.8.8.8` | `udp://8.8.8.8` |
| R6 PROXY_GROUP_EMPTY_PROXIES | error | 代理组无节点 | `proxies: []` | 添加代理节点 |
| R7 TUN_ENABLE_CHECK | warn | tun 模式不支持 | `tun: {enable: true}` | 移除或忽略 |
| R8 EXTERNAL_CONTROLLER_FORMAT | warn | 控制器地址格式错误 | `"9090"` | `127.0.0.1:9090` |
| R9 ALLOW_LAN_BIND_CONFLICT | warn | allow-lan=false 但 bind-address 非本地 | `allow-lan: false` + `bind-address: 0.0.0.0` | 改为 `bind-address: 127.0.0.1` |
| R10 RULE_PROVIDER_REF_CHECK | error | 规则集引用不存在 | `RULE-SET,missing,DIRECT` | 添加 rule-provider 定义 |
| R11 PROXY_NODE_FIELDS_CHECK | error | 代理节点缺少必填字段 | `name:` 缺失 | 补充 name/server/port |
| R12 SS_CIPHER_ENUM_CHECK | error | SS 加密方式不支持 | `cipher: aes-256-cbc` | `cipher: aes-256-gcm` |
| R13 VMESS_UUID_FORMAT_CHECK | error | VMess UUID 格式无效 | `uuid: not-valid` | 使用标准 UUID v4 |
| R14 MIXED_PORT_CONFLICT_CHECK | warn | mixed-port 与 port/socks-port 同时配置 | `mixed-port: 7890` + `port: 7891` | 移除 port/socks-port |
| R15 MODE_ENUM_CHECK | error | mode 值无效 | `mode: auto` | `mode: rule` |
| R16 PROXY_NAME_UNIQUENESS_CHECK | error | 代理名称重复 | 两个 `name: "node1"` | 改为唯一名称 |
| R17 PORT_RANGE_CHECK | error | 端口超出范围 | `port: 99999` | `port: 1-65535` |
| R18 SS_PROTOCOL_CHECK | warn | SS 协议变体识别 | `type: ss-plugin` | 确认支持（已支持） |
| R19 VMESS_ALTERID_RANGE_CHECK | error | VMess alterId 超出范围 | `alterId: 99999` | `alterId: 0-65535` |
| R20 TROJAN_FIELDS_CHECK | error/warn | Trojan 节点缺少字段 | 缺 `password` | 添加 password/sni |
| R24 YAML_SYNTAX_CHECK | error | YAML 语法错误（缩进、冒号等） | `mixed-port 7890` | `mixed-port: 7890` |
| R25 SUBSCRIPTION_URL_CHECK | warn | 订阅 URL 协议不正确 | `subscription-url: "ftp://..."` | `https://...` |
| R26 WS_OPTS_FORMAT_CHECK | warn | WebSocket path 格式错误 | `path: ws` | `path: /ws` |
| R27 TLS_SNI_CHECK | warn | TLS 开启但未配置 SNI | `tls: true` 缺 `sni` | 添加 `sni: server.com` |

## 快速修复命令

```bash
# 运行所有检查
bash tools/config-migrator/run.sh lint config.yaml

# 查看完整回归测试
bash tools/config-migrator/run-all.sh
```

## 级别说明

- **error**: 会导致配置无法正常工作，必须修复
- **warn**: 可能工作但建议修复，或会被忽略的配置

## 新增规则（R21-R29）

| 规则 | 级别 | 一句话说明 | 示例配置 | 修复建议 |
|------|------|-----------|----------|----------|
| R21 RULES_FORMAT_CHECK | error | 规则格式错误 | `DOMAIN,google` | `DOMAIN,google.com,PROXY` |
| R22 VLESS_FIELDS_CHECK | error/warn | VLESS 节点缺少字段 | 缺 `uuid` | 添加 uuid/sni |
| R23 PROXY_GROUP_REF_CHECK | error | 代理组引用不存在 | `proxies: [missing]` | 添加 proxy 定义 |
| R28 UNSUPPORTED_PROXY_TYPE_CHECK | error | 代理类型不支持 | `type: snell` | 更换为 ss/vmess/trojan/vless/anytls |
| R29 PORT_CONFLICT_CHECK | warn | 不同代理使用相同端口 | node1:8388, node2:8388 | 使用不同端口 |
| R30 DUPLICATE_KEY_CHECK | warn | 配置项重复定义 | `port: 7890` 出现两次 | 删除重复项 |
| R31 DNS_INVALID_CHECK | error | DNS 服务器无效 | `nameserver: [localhost]` | 使用 8.8.8.8 或 1.1.1.1 |
