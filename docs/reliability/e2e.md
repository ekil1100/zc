# End-to-end release gate

`zig build e2e --summary all` 从真实 `zc` ReleaseSafe 二进制出发，只通过公开 CLI、
mixed HTTP/SOCKS5、minimal API 和 TCP/TLS wire 验证行为。测试把 `zc` 当作独立进程；
本地 origin helper 只复用跨平台 socket compatibility，不调用配置、路由或协议实现。门禁
不存在 warning-as-pass 或 skip-as-pass 分支。

## Coverage

门禁在隔离的 canonical `HOME` / `XDG_RUNTIME_DIR` 中验证：

- one-line installer 的 explicit/latest 版本、四平台资产映射、SHA-256、原子替换与失败保留；
- `config load`、managed identity、`start/status` 与 durable `proxy select`；
- mixed HTTP 与 SOCKS5 的真实 payload round-trip；
- DIRECT、REJECT 与错误密码负路径；
- `aes-128-gcm`、`aes-256-gcm`、`chacha20-poly1305`、
  `chacha20-ietf-poly1305` 对独立 Shadowsocks 服务端的互操作；
- Trojan TCP/TLS 对独立服务端的互操作；
- controller Bearer 鉴权与 unmanaged selection；
- reload preparation 失败时旧 daemon 继续转发，恢复后 reload 成功；
- stop 后 runtime prepared snapshot 被精确清理。

## Standalone fixtures

生产 `zc` 不引入运行时依赖。协议互操作门禁仅在测试期间下载两个固定版本的 standalone
fixture，并在执行前验证仓库内固定的 SHA-256：

- `shadowsocks-rust` `v1.24.0`；
- `trojan-go` `v0.10.6`。

Linux fixture 必须由 `file` 识别为 statically linked。它们只绑定 loopback，不进入
release archive。`testdata/e2e/trojan-key.pem` 是公开的测试私钥，不能用于任何部署。

## Scheduling

E2E 有意不挂到普通 `zig build test`：

- pull request：`.github/workflows/ci.yml` 的独立 `e2e` job；
- version tag：`.github/workflows/release.yml` 的 Linux amd64 release-artifact E2E step；
- ordinary `main` push：不重复执行；
- 本地：开发者显式运行 `zig build e2e --summary all`。

发布 workflow 在 Linux amd64 上直接对将被打包的 `x86_64-linux-musl` static zc 执行
该门禁；任一 E2E 或四平台 release matrix 失败都会阻止 publish。
