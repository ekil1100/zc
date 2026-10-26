# GitHub 托管 macOS 的 User trust 认证：官方证据核查

## 后续决策

用户已批准将 macOS 原生系统信任/首次使用测试移出必过发布门禁，保留可选手动验证及本文的证据边界。下文为决策前的研究结论；授权问题仍未解决，但不再阻塞发布。详见 [开发优先级](../development-priorities.md)。

## 结论

- **受支持的非交互 User-domain 写入：本次核查未确认存在。** Apple 当前 API 文档明确描述 GUI 登录与认证提示；公开 setter 没有密码或调用方 AuthorizationRef 参数。GitHub 的免密 sudo 和签名证书导入文档均未提供这条授权链路。
- **GitHub 托管 runner 的受支持交互访问：无法判断。** 所查官方文档未给出供客户使用的 macOS 桌面连接、Loginwindow 登录或完成 SecurityAgent 提示的入口，也未找到明确禁止一切交互访问的声明。文档缺失只支持“尚未确认”，不支持“技术上绝无可能”。
- **用户现在无需提供机器或密码。** 可以先向 GitHub Support 确认托管 macOS 是否提供受支持的控制台/桌面认证方式，以及 User TrustSettings 的自动化方案。真正完成原生验收仍需可正常认证、独占、可销毁的 macOS 环境；该环境可以由托管服务或自托管提供，现有证据尚不足以指定必须由用户立即提供自有机器。

范围：已阅读 [已有授权研究](macos-trust-auth.md) 与 [原生门禁记录](macos-native.md)。本轮只读取官方网络资料并写研究文件，未执行 trust/keychain/account 修改、CI 或密码获取。英文引文保留官方原文。

## 1. Apple：User 与 Admin 的认证契约不同

来源：[SecTrustSettingsSetTrustSettings 当前官方文档](https://developer.apple.com/documentation/security/sectrustsettingssettrustsettings(_:_:_:))，章节 **Special Considerations**：

> When making changes to per-user trust settings, the user is prompted with an alert panel asking for authentication (user name and password or other credentials normally used for login). Therefore, it is not possible to modify per-user trust settings when not running in a GUI environment (that is, when the user is not logged in via the login window).

> When making changes to system-wide trust settings, the user is prompted with an alert panel asking for an administrator’s name and password unless the calling process is running as root, in which case no further authentication is needed. Note that this function might block while waiting for user input.

这直接支持 GUI/session 认证要求及等待用户输入的可能性；root 豁免的文字针对 system-wide 修改，不能移用于 User domain。也不能从这里推定每个 GitHub runner 都没有 GUI 登录会话。

[公开头文件声明](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/trust/headers/SecTrustSettings.h#L250-L261)：

```c
OSStatus SecTrustSettingsSetTrustSettings(
     SecCertificateRef          certRef,
     SecTrustSettingsDomain     domain,
     CFTypeRef __nullable     trustSettingsDictOrArray);
```

声明未提供密码、AuthorizationRef 或禁止 UI 的调用参数。这限定了直接传参方式，未证明所有会话凭据方案都不可行。

[Apple 固定版本实现](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_keychain/lib/TrustSettings.cpp#L643-L678) 创建自己的授权对象：

```c
AuthorizationCreate(NULL, kAuthorizationEmptyEnvironment,
			0, &authRef);
```

随后使用 `kAuthorizationFlagInteractionAllowed` 和 `kAuthorizationFlagPreAuthorize`，再外部化该对象。这与已有“单独预授权成功尚未证明 setter 最终授权成功”的结论一致。

同一实现的 [root 快捷分支](https://github.com/apple-oss-distributions/Security/blob/db15acbe6a7f257a859ad9a3bb86097bfe0679d9/OSX/libsecurity_keychain/lib/TrustSettings.cpp#L430-L444) 明写：

> /* caller must be root and adding non-null settings in admin domain */

> /* only permitted if SIP is disabled */

该分支仅涉及 Admin，并有额外条件。它是版本限定的机制证据，不代表当前各 macOS 镜像所有 Admin 操作的完整行为，也不构成修改 SIP 的建议。

## 2. GitHub：免密 sudo 只证明提权能力

来源：[GitHub-hosted runners reference — Administrative privileges](https://docs.github.com/en/actions/reference/runners/github-hosted-runners#administrative-privileges)：

> The Linux and macOS virtual machines both run using passwordless `sudo`. When you need to execute commands or install tools that require more privileges than the current user, you can use `sudo` without needing to provide a password.

该承诺解决 Unix 提权。它未承诺提供 runner 登录密码、session-owner 认证凭据或 User TrustSettings 的静默授权。Admin trust 即使成功，也只覆盖 Admin 场景；原门禁中的 User deny 及其对 Admin trust 的优先级仍需独立验证。

## 3. GitHub：签名 keychain 导入有文档，User trust 授权尚无对应证据

来源：[Installing an Apple certificate on macOS runners for Xcode development](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)：

> The signing process involves storing certificates and provisioning profiles, transferring them to the runner, importing them to the runner's keychain, and using them in your build.

> A new keychain will be created on the runner, so the password for the new keychain can be any new random string.

示例确实执行：

```sh
security import $CERTIFICATE_PATH -P "$P12_PASSWORD" -A -t cert -f pkcs12 -k $KEYCHAIN_PATH
security set-key-partition-list -S apple-tool:,apple: -k "$KEYCHAIN_PASSWORD" $KEYCHAIN_PATH
```

`P12_PASSWORD` 用于签名证书容器，`KEYCHAIN_PASSWORD` 用于新钥匙串；两者均没有被文档定义成 runner 登录密码。导入证书和设置签名密钥访问权限，证明的是签名工作流，不证明 `SecTrustSettingsSetTrustSettings` 的 User trust 写入已获授权。

## 4. 交互访问与官方支持的证据边界

核查了 GitHub 的 [runner 概述](https://docs.github.com/en/actions/concepts/runners/github-hosted-runners)、[权限参考](https://docs.github.com/en/actions/reference/runners/github-hosted-runners)、[自定义 runner](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/customize-runners)、[任务监控](https://docs.github.com/en/actions/how-tos/manage-runners/github-hosted-runners/view-current-jobs) 和 [larger runner 参考](https://docs.github.com/en/actions/reference/runners/larger-runners)。这些页面未给出上述受支持桌面认证入口；任务监控页面提供的是 job 状态查看。

“larger runner”或“自定义镜像”也尚未提供现成答案。[官方自定义镜像流程](https://docs.github.com/en/actions/how-tos/manage-runners/larger-runners/use-custom-images) 的平台范围原文为：

> The platform of the runner can be Linux x64, Linux ARM64, or Windows x64.

社区 SSH/tmate、VNC/隧道、模拟点击、重设账户密码等办法，即使有成功案例，也应分别验证会话身份、真实 setter 授权与服务支持范围。社区帖子或 Marketplace 上架本身不构成 GitHub/Apple 对此认证用途的官方支持承诺；本轮未执行或验证这些办法。终端连接能力也不自动证明满足 Apple 的 GUI 登录要求。

若需自行控制环境，GitHub 明确支持 [self-hosted runners](https://docs.github.com/en/actions/concepts/runners/self-hosted-runners)：

> A self-hosted runner is a system that you deploy and manage to execute jobs from GitHub Actions on GitHub.

> Can be physical, virtual, in a container, on-premises, or in a cloud.

这是自托管执行的产品支持，不保证任意自托管启动方式都具备 GUI/session-owner 认证能力。

## 剩余问题与验收条件

1. 向 GitHub Support 确认：指定 macOS 镜像/架构是否支持客户交互桌面访问和系统认证提示；若支持，取得正式操作文档及安全边界。也应询问是否有官方支持的非交互 User TrustSettings 流程。
2. 若有凭据或会话方案，仍须证明授权到达普通 setter 的最终服务端请求；单独 token 授权、keychain 导入或 Admin 成功均不足以替代。
3. 在批准的可销毁环境中，验证 User 新增、deny 更新、撤销及 Admin 对照，完整通过既有九项场景和严格清理。此前超时仍是门禁失败证据，本轮资料核查未改变这一状态。

**当前决策：保留授权阻塞，先确认服务支持入口；无需现在索取机器或密码。** 若托管服务支持范围无法满足验收，再选择受控的一次性自托管 macOS 环境。官方源码快照与当前镜像二进制之间仍存在版本不确定性；本轮没有新增运行时证据。
