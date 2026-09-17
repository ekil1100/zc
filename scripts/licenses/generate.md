# 依赖声明生成说明

## 使用

需要 Python 3.11+、Cargo，以及已缓存的锁定版本 crates.io 源包和 `.crate` 归档。不安装工具、不构建或运行项目、不调用 Zig，也不修改 Cargo 输入文件。

```sh
PYTHONDONTWRITEBYTECODE=1 python3.11 scripts/licenses/generate.test.py
python3.11 scripts/licenses/generate.py
python3.11 scripts/licenses/generate.py --check
```

生成器运行 `cargo metadata --locked --offline --format-version 1`，缓存不足时失败；不自动联网补齐依赖。`--check` 不写文件，产物过期、源包校验失败、包级许可正文缺失或出现未审核许可标识时返回非零。已知覆盖限制每次均以 `REVIEW` 输出，详见产物中的中文说明；它们不是完整合规认证。

## 文件与来源

- `THIRD_PARTY_NOTICES.md`：发行时可独立阅读的完整正文、版权与来源索引；相同 UTF-8 原文按 SHA-256 去重，保持原语言、内容和换行。
- `license-report.json`：锁文件及 manifest 哈希、版本、依赖来源、归档校验和、features、源文件路径及文本哈希、排除项、自动检查发现与人工审核限制。
- `upstream-report.json`：发布包未携带的上游许可证快照。每条记录含包版本、`.cargo_vcs_info.json` 提交、官方仓库原始文件 URL、SHA-256 和全文。首次从这些 URL 获取，后续生成离线使用；更新依赖时不得仅修改版本字段，必须重新核对官方源码。
- `zig-notice.template.md`：原有 Zig TLS 派生源码声明，完整保留至源码删除决策。
- `generate.test.py`：生成器单元测试，不依赖 Zig、网络或真实 HOME。

声明由本地发布源包提取。生成前校验 `.crate` 与 `Cargo.lock` 校验和一致，并逐个比对实际使用的许可文件、原生源码、manifest 与 VCS 元数据和归档内容。补充文件与 VCS 精确提交绑定，同时验证 URL、正文哈希。生成途中 Cargo 输入变化会失败。产物不包含本机路径、时间戳或 Cargo 版本，避免环境差异影响内容。

## 选择范围

沿根包 normal/build 依赖边递归，排除仅 dev 边可达的包；不按本机目标过滤，因此覆盖跨平台发布依赖。Cargo metadata 的 feature 合并以及构建工具可导致保守多收录，不能据此认定每个包实际链接进二进制。当前 `mlua-sys/build/find_vendored.rs` 的 `lua54` 分支选择 `lua-src` 内 Lua 5.4.9；保留其他随包源码声明以免遗漏。

递归收录 LICENSE/LICENCE/COPYING/NOTICE/COPYRIGHT/AUTHORS/PATENTS/UNLICENSE、独立 `license_file`、隐藏 `.licenses/` 等目录，以及 C、汇编、Perl 源码中包含版权、许可或公有领域标识的注释。AWS-LC 聚合许可和 Fiat 许可、Lua 头文件完整版权段、LuaJIT、ring/BoringSSL 等原生声明均在范围内。

不使用许可证模板替代具体作者的版权声明，不把所有 MIT 包合成一个无作者的通用模板。不自动选择/求解整个 SPDX 表达式；标识清单只是防止新许可静默进入。所有备选原文可以一起收录，但不意味着发行者选择了全部许可。`r-efi` 的 `AUTHORS` 包含完整 MIT 授权；AWS-LC 明示选择 Jitter Entropy 的 BSD 分支。

## 更新与限制

依赖变化后重新生成并审阅 JSON 差异。快照更新应读取新包的 `.cargo_vcs_info.json`，从其官方仓库对应精确提交重新获取许可原文并记录哈希；不使用主分支或其他版本的许可补洞。当前快照来源均为 GitHub 官方项目的 `raw.githubusercontent.com/<owner>/<repo>/<commit>/<path>`。生成器不会悄悄忽略旧版未使用快照。

AWS-LC 聚合 LICENSE 引用的部分独立许可证不在 crate 中；现有聚合正文和原生版权注释已收录，但缺失文件与聚合正文的一致性仍需上游/人工复核。源码注释扫描不是通用许可证识别器；Rust 内嵌代码、工具链、系统库和最终链接清单仍需发行审核。具体限制同时嵌入发行声明，避免 JSON 未随包分发时丢失提示。
