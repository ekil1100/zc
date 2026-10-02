# v1.1.0-rc1 发布记录

## 已确认范围

用户在 main 合并后批准发布，并在 Linux-only 预发布方案上指定版本 `v1.1.0-rc1`。本次仅提供 Linux x64/arm64 静态 musl 归档、校验文件和安装脚本；标记为 GitHub prerelease，保持稳定版 Latest 与 Homebrew 不变。macOS 系统信任/首次使用、官方 AnyTLS 全套互操作补验、性能与 24/72 小时长稳继续保留验收边界。

## 门禁

- 仅此精确 tag 可采用 Linux 范围；其他 RC 和正式版保留完整 main CI 与四平台产物。
- tag 与 Cargo 版本一致；必须来自同一 SHA 的 main push `ci.yml`。
- Python 检查、两个 Linux 交付 job 及各必需步骤均完成且成功；核对 job 的 run ID 和 SHA。缺失、重复、跳过、取消、失败或执行中均拒绝。
- 分页收集 GitHub job 证据，门禁输出唯一发布矩阵；main CI 本身仍运行全部平台，保留 macOS 失败结果。
- 所有预发布跳过 Homebrew 更新；本次不标记 Latest。

## 本机检查

发布门禁 CLI 先红后绿，覆盖精确候选范围、其他版本完整门禁、提交/分支/事件/workflow/job 来源、缺失/重复/失败/跳过/执行中及必需步骤校验。独立检视未发现发布阻塞项。

检视发现可选 AnyTLS TLS record 检查写死旧版本；修复为从待测二进制 `--version` 提取预期 client 标识。新版本在原检查下失败，修复后独立 OpenSSL wire-shape 检查通过；未将其当作官方 Go 全套互操作通过。

`just delivery-test`、Ruff 格式/lint、Cargo 格式、`cargo check --offline --locked` 与 `zc --version` 通过。准备提交后，必须等对应源码的 Linux CI 成功再打 tag；发布及资产校验结果另行追加。
