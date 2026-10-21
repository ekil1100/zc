# macOS User TrustSettings 授权边界

## 结论

普通 User trust setter 没有接收调用方密码或 AuthorizationRef 的公开参数。当前 GitHub macOS runner 上，setter 等待系统认证并超过 30 秒期限；完整九项原生验收仍未通过。只读源码与模拟测试不构成授权修复。

原始失败与历史对照见 [macos-native.md](macos-native.md)。探索性探针保留在 `target/macos-trust-fix/credential-probe/`，未加入正式测试入口、生产代码或发布门禁。

## 已排除的简单替代

Apple Security 源码固定到 `db15acbe6a7f257a859ad9a3bb86097bfe0679d9`。源码快照与 CI 系统二进制的差异仍需原生运行证据确认。

| 路径 | 来源与限制 |
| --- | --- |
| 预先执行 AuthorizationCreate | [TrustSettings.cpp:643–717](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_keychain/lib/TrustSettings.cpp#L643-L717)：setter 新建空环境 token，后续外部化的并非调用方已有对象。 |
| External setter / import | [SecTrustSettings.cpp:761–794](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_keychain/lib/SecTrustSettings.cpp#L761-L794)：private External setter 生成内存记录；public import 仍进入 flushToDisk，不能补上授权入口。 |
| 复用先前凭据 | [engine.m:400–430](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/authd/engine.m#L400-L430) 与 [1600–1621](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/authd/engine.m#L1600-L1621)：后续评估移除 context 中的用户名/密码，并重新检查凭据有效期。PreAuthorize 成功不证明最终认证完成。 |
| sudo / root 快捷路径 | [TrustSettings.cpp:430–444](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_keychain/lib/TrustSettings.cpp#L430-L444)：仅考虑 root、Admin、非空设置和指定 SIP 条件，明确排除 User。 |
| 新用户或仅 sudo -u | [session.c:134–138](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/authd/session.c#L134-L138)：session owner 来自 audit auid，不等同于 euid。创建身份本身也不会把凭据交给 setter。 |
| authdb allow | [rule.c:218–275](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/authd/rule.c#L218-L275)：User trust 使用硬编码 session-owner 认证规则。 |

公开 SDK 的 [SecTrustSettings.h](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/trust/headers/SecTrustSettings.h) 描述了 User 修改的图形登录认证要求。没有采用修改账户、读取现有账户密码、SIP/TCC 降级、直接编辑信任数据库或把 User 场景改成 Admin 的方案。

## 探针与验证

临时探针只调用 public Authorization/AuthSession API，比较有效凭据直接授权、同 token、外部化导入、新 token 的返回值；不写 trust/keychain。密码仅经 FD 输入，禁 UI、有限期限、回收 owned child，输出固定标签及数值状态，成功也只标记 `TRANSFER_ONLY`。

- `python3 target/macos-trust-fix/credential-probe/test-macos-trust-auth.py`：本机 15 项隔离测试通过；测试替换所有原生认证调用。
- 临时副本忽略 OSStatus 的负对照报红：`AssertionError: 0 != 1`。
- 原 helper 通过 public SDK 编译、链接；本机仅执行隔离测试与拒绝路径。
- 未取得真实有效密码的原生探针结果，因此这些程序作为探索工件留在 `target/`，不作为正式修复交付。

完整验收仍要求独占、可销毁 macOS runner 的正常登录身份能够完成 User/Admin 认证，并通过全部九项 first-use 场景、User deny 优先于 Admin trust 和严格清理。即使取得匹配 session-owner 的合法密码，凭据探针成功仍不等于普通 setter 写入成功。

当前缺少可完成正常认证的环境与该环境中的实测；不把部署此类环境描述为已经验证的代码修复。
