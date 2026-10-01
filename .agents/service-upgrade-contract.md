# 用户服务与冷升级验收契约

## 授权与范围

用户已确认公开 CLI 和本地安装器两个测试入口。基线：`to-rust`，`ce8d41c406238794f5c7d7a55b9e7946361ee4b8`，开始时工作区干净。新增 `src/user_service.rs`，保留 `src/service.rs` 的配置准备职责。

仅当前用户服务：macOS 登录 LaunchAgent、Linux `systemd --user`。不使用提权、系统服务、自动 linger 或登录前运行。不操作本机真实服务或生产端口，不安装、提交、推送。

## 可验证行为

1. `zc service start/stop/restart/enable/disable/status` 支持文本与 JSON、组帮助、严格参数检查。
2. 首次 start 注册并启动；首次 enable 注册并设置登录自启动，保持停止。start/restart/enable 接受显式配置与端口。普通重复命令复用注册的冻结配置与端口；变更运行中的配置只允许显式 restart。
3. stop 保留自启动偏好；restart 保留偏好；disable 保持当前运行。registered、loaded、running、enabled 分开报告。running 必须有管理器进程与认证 daemon 身份/readiness 的共同证据。
4. 一位用户一份注册，绑定绝对安装路径、HOME、runtime 和随机服务身份。路径参数逐项传递，不使用 shell eval；配置凭据只存在私有认证快照。注册、定义与快照缺失、损坏、外来内容拒绝，保留原始文件。
5. 手动实例不被服务接管。迁移明确提示先确认并用原方式停止，再显式 `service start -c <config> --port <port>`。注册 runtime 的普通生命周期命令在已有服务所有权下拒绝并指向 service 命令；其他手动行为保留。
6. 服务与安装操作串行，共用既有安全文件锁和 launch/instance 所有权；停止前核对捕获的实例，发布期间阻止协作启动，绝不按猜测 PID 停止。
7. `just install` 先构建、校验候选，再停止确认属于目标安装的服务。停止通过管理器；保留运行/停止、自启动、runtime、冻结输入和实际选择。首次安装与停止态升级保持停止；运行态才恢复。
8. 使用原安全 staging/rename 发布。发布或启动失败尝试恢复旧二进制与精确旧快照，恢复失败明确报告并保留恢复工件。手动运行目标维持安全拒绝，给出迁移说明；不使用默认 active/plain start 恢复。
9. 升级是冷切换，连接可能关闭。原生平台、性能、四平台及长稳均须独立证据。

## 平台依据与实现约束

- 本机 `man launchctl`：bootstrap/bootout 控制加载；enable/disable 的状态跨重启持久，disabled 服务无法 bootstrap；kickstart 显式启动。
- 本机 `man launchd.plist`：LaunchAgents 在登录加载，进程保持前台；RunAtLoad 在加载时启动；KeepAlive 可导致重新启动。
- https://raw.githubusercontent.com/systemd/systemd/main/man/systemctl.xml ：enable 不隐式 start，disable 不隐式 stop，使用 `--now` 才组合执行；本实现不用 `--now`。
- https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.service.xml ：管理器 stop 不触发 Restart；ExecStart 使用自身的引用/替换规则，非 shell。
- macOS 私有定义始终保留，登录目录副本表达自启动；disable 只移除逐字节验证属于注册的登录副本。stop 使用 bootout，保留登录副本。已由外部禁用的注册在显式启动/enable 时通过 launchctl enable 恢复可加载性。
- 不承诺崩溃自动重启；采用无自动重启的前台任务，避免在升级失败时产生重启风暴。
- 管理器命令固定绝对路径、有界时间与输出、脱敏错误；区分 absent 与 manager unavailable/access denied。真实适配器校验操作系统账户 HOME，临时 HOME 测试只能使用显式注入的测试执行器，环境变量不提供生产绕过入口。

## 验证顺序

逐个垂直切片先红后绿：公开命令/独立自启动语义 → 真实隔离 daemon readiness 与所有权 → 本地安装发布和失败恢复。测试仅临时 HOME/runtime 和显式非 7899 端口。两种管理器的定义与调用用独立执行器验证；真实 daemon 与发布用真实隔离二进制验证。最后执行相关回归、格式与 all-targets 严格 Clippy；记录实际命令、结果和未覆盖边界。既有 override_spawn 间歇失败如出现据实记录，保持其断言与超时不变。

## 本轮修复验收补充

延续 HEAD `ce8d41c` 的未暂存实现，不回滚已有改动。新增验收：

- 停止命令无效失败与部分停止错误分别验证；原注册字节、启动许可、显式变更前冻结端口恢复，变化实例保持不被停止；部分停止保留真实停止结果并提示显式 start。
- Linux resolved executable 的引号/反斜杠准入先于 prepare 和 durable service state；空格/$/% 保留。引用 systemd v255 `config_parse_exec`/`string_is_safe`；有 native parser 时仅解析生成定义，不注册服务。
- 运行时快照在 binary lease 与 Evidence 初始化失败、future cancellation 路径清理；只删除认证的本实例输入，保留服务冻结状态、其他 nonce 与坏文件。
- 成功重配置、运行选择变化与安装捕获保持当前冻结快照有界；仅清理事务明确替换且认证的文件，失败恢复工件保留。
- 两适配器各覆盖 pre-stop、post-stop、pre/post-publish、readiness-pending/ready × SIGINT/SIGTERM/15 秒 timeout。通过真实独立进程组、真实 daemon 和临时二进制发布验证锁释放后无迟到写入。
- 安装独立信号入口等待命令终止/回收后恢复。未知新启动 PID 明确恢复失败；SIGKILL 仅证明保留工件和人工清理流程，不承诺自动恢复。自脱离/提权钩子不在命令组保证内。
- 本轮不执行或重写 `override_spawn`，不操作真实 manager mutation、不安装到用户 bin、不触及生产 7899、不提交/推送。
