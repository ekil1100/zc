# 当前用户服务与本地冷升级：本轮验证

## 本轮恢复修复：最终结论

继续 `ce8d41c` 上已有未暂存实现，保留原改动。三个独立审查问题已复现并修复，同时补齐安装中断/超时的命令组清理、逐阶段恢复证据与成功事务的冻结快照回收。**本轮最终定向 Rust 回归为 185 passed / 3 ignored / 0 failed**；`user_service` 为 **27 项通过**（本轮新增 10 项），`daemon` 新增 1 项。Justfile 15 项、本地安装脚本回归、格式与 all-targets 严格 Clippy 通过。

两适配器 × 6 个阶段 × SIGINT/SIGTERM/timeout 共 **36 个边界场景**，日志逐条记录：30 个恢复旧二进制与原调用；6 个新 daemon 已 ready 但管理器调用结果未返回的场景明确 `SERVICE_RECOVERY_FAILED`，保留备份并保持未知新实例存活。36 个场景都验证释放安装/发布锁后无迟到写入。**这是已通过的保守失败契约，未声称所有中断都能自动恢复。**

所有改动仍未暂存；未 commit/push，未真实服务注册/变更、未安装到用户 bin，未使用生产 7899。`override_spawn` 本轮未运行、未修改；下方上一轮失败记录仅作历史保留。本轮没有完整默认测试、Linux native manager、四平台、性能或长稳通过声明。

### 修复后独立复核

独立只读复核确认停止失败、Linux 路径准入和早期快照清理三项修复成立；另检查安装信号处理、未回收组长的进程组清理顺序及认证快照退休范围，未发现新的可操作问题。独立执行 5 项定向测试全部通过；没有将 36 个矩阵场景重新运行或重复计入。父任务随后通过真实开发二进制检查 `service --help`、`service start --help`，以及 `git diff --check`。原生管理器和历史间歇性测试的限制保持下文所述。

### 本轮修复内容与红绿证据

原始工件均在 `target/service-upgrade/`，不是仓库长期文档。已读取 reviewer 的 `/tmp/zc-service-review.zZ2pG4/probe.rs`，把对应公开行为纳入持久回归；没有运行其修复后会持续前台运行的裸 `--service-run` 等待路径。

| 范围 | 红态证据 | 最终行为与绿态 |
| --- | --- | --- |
| 停止失败 | `14-red-stop.log`：原 `allowed` 与 snapshot 引用被改写 | `14-green-stop.log`：stop/显式 restart × 无效停止/部分停止；恢复精确原注册，保留原端口与后续启动许可；已停止则报真实停止结果，显式 start 恢复 |
| Linux 路径 | `15-red-path.log`：先进入 prepare，返回缺失来源错误 | `15-green-path.log`：单/双引号、反斜杠在任何 prepare/状态创建前拒绝；空格/$/% 保留；macOS 引号/反斜杠 plist 路径真实 daemon 生命周期通过 |
| 早期运行快照 | `16-red-cleanup.log`：binary lease 拒绝遗留 `.snapshot` | `16-green-cleanup.log`、`21-cancellation.log`：lease/Evidence 失败、foreground/child 及 future cancellation 清理；其他 nonce 与损坏快照保留 |
| 冻结快照增长 | `17-red-snapshots.log`：一次显式 restart 已从 1 份增长到 3 份 | `17-green-snapshots.log`、最终回归：重复端口重配置＋真实托管 selection 变更＋安装，仅保留当前冻结快照；未知文件原样保留 |
| 进程组 | `18-red-process-group.log`：15 秒超时返回后 fork 子进程仍可写入 | `18-green-process-group.log`：超时及 future drop 杀死同组辅助进程，命令完成路径先终止残留组，再回收直接子进程；不使用 shell eval |
| OS 安装信号 | `19-red-install-signals-6.log`：SIGINT 直接杀死安装器，无恢复输出 | `19-green-install-signals.log`、最终回归：真正 `--local-install` 的 SIGINT/SIGTERM 返回明确中断原因与恢复结果，回收完成后才释放锁 |
| 全阶段中断 | `20-boundaries.log`：ready 屏障尚未等到真实 readiness，测试修正为观察真实新 daemon ready | `20-green-boundaries.log`；最终 `recovery-regression-final.log` 增强为字节不同且签名有效的真实旧二进制，证明 post-publish 确实恢复旧内容 |
| 变化实例 | `23-changed-instance.log` | 停止错误后管理器 PID 被替换：原注册精确恢复、两个实例均存活、status 拒绝不一致所有权，错误明确结果不明 |
| SIGKILL | `24-sigkill.log` | 保留 `.zc.recovery.*`；测试显式识别并终止遗留发布组后检查无迟到写入，作为人工恢复流程证据，不作为自动恢复 PASS |
| 清理结果不明 | `25-red-uncertain-cleanup.log`：错误地宣称 ROLLED_BACK | `25-green-uncertain-cleanup.log`：命令清理本身失败，明确 RECOVERY_FAILED，保留备份，停止后续自动发布/恢复 |

中间编写信号夹具曾因 macOS Bash 3 不提供 BASHPID 而提前退出；修改夹具后才取得真正信号红态。另有 XNU zombie-only group 的 EPERM：用主源确认后在已退出且仍未 reap 的组长及同用户辅助进程约束下处理。`19-red-install-signals.log` 至 `-5.log` 保留为这些中间失败，不当作信号缺陷的有效红态。

运行快照作用域 guard 置于 binary lease/Evidence 之前，实例锁持续至 guard 清理结束；快照删除前重新认证。服务快照回收只列举本次操作明确替换的原记录/捕获输入，在成功提交并复核当前注册后进行；不目录遍历清扫失败事务、未知 nonce 或坏状态。失败恢复保留需要的旧输入。

### 命令组与原生依据

- [systemd v255 config_parse_exec](https://github.com/systemd/systemd/blob/v255/src/core/load-fragment.c)：解码/展开后调用 `string_is_safe(path)`；[string_is_safe](https://github.com/systemd/systemd/blob/v255/src/basic/string-util.c) 拒绝单双引号、反斜杠、ASCII 控制字符和 DEL。解析前转义不改变这个最终路径限制。
- 本机 Darwin arm64，**native `plutil -lint` 已验证生成的复杂路径 plist**。环境未提供 `systemd-analyze`、Docker/Podman/VM CLI；Linux native parser 本轮未执行。Linux 环境中如有 `/usr/bin/systemd-analyze`，持久测试会执行 `verify --man=no --generators=no`，仅验证定义、不注册服务。两种 fake manager 的通过仍只证明适配器模型和真实 daemon，不冒充 native Linux parser/manager 证明。
- [XNU kern_sig.c / killpg1](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_sig.c)：group iteration 排除 zombie，空的可发送集合返回 EPERM。实现用 `waitid(WNOWAIT)` 保持组长未回收，避免 cleanup 的 PGID 被复用；同用户活辅助进程收到 SIGKILL，之后有界回收直接子进程。
- 主源读取副本在 `target/service-upgrade/native/`，没有执行真实 launchctl/systemctl mutation。外部管理器的已接收请求仍可能完成；恢复继续依赖管理器/daemon 共同身份，而非以客户端进程组退出推断服务一定停止。

安装器仅通过 `install_with_signals` 在安装进程中注册 SIGINT/SIGTERM，取消信号在 task-local scope 传递给命令执行器；不 drop 正在执行的安装 transaction。恢复使用独立未取消 scope，继续等待完成；其余 CLI 命令未接入该信号路径。库调用方必须 await `install` 完成，随意 drop 安装 future、进程崩溃/强杀及脱离进程组/提权钩子不提供异步恢复保证。SIGKILL 的 retained state 及人工核查步骤见[安装文档](../docs/install/README.md#安装中断与恢复)。更强的强杀保证需要独立、持有发布锁的监督进程和持久恢复日志，超出本轮局部修复范围。

### 最终定向 Rust 回归

```bash
ulimit -n 8192
cargo test --offline --locked --lib \
  --test user_service --test daemon --test daemon_races --test runtime \
  --test cli --test cli_managed --test profile_secret \
  --test observability_lifecycle --test fsutil --test service -- --nocapture
```

`recovery-regression-final.log`，exit 0：

| 套件 | passed | ignored |
| --- | ---: | ---: |
| lib | 19 | 0 |
| cli / cli_managed | 9 / 30 | 0 |
| daemon / daemon_races | 19 / 8 | 0 |
| runtime | 22 | 0 |
| profile_secret | 11 | 3 |
| observability_lifecycle | 16 | 0 |
| fsutil / service | 14 / 10 | 0 |
| user_service | 27 | 0 |
| 合计 | **185** | **3** |

隔离子进程、36 个矩阵子场景和 fsutil 子进程复测均包含在对应父测试，不重复计数。3 项 ignored 仍是显式历史二进制对照。

### 最终安装与静态检查

- `python3 scripts/ci/test-justfile.py`：**15 tests，exit 0**，`recovery-justfile-final.log`。
- `bash scripts/install/verify-local-dev-install.sh`：最终 **exit 0**，已有目标、独立竞争目标保留、正常替换、symlink 与缺失源保护通过；`recovery-installer-green.log`。
- 安装脚本首轮 `recovery-installer-final.log` 为 **exit 1**，原因 `running_race_target_was_terminated`：旧夹具从 publisher hook 派生“竞争目标”，实际仍是同一受清理命令组。改为测试驱动的独立 actor 在 hook 屏障启动目标，保留原存活/字节不变断言。此处修改的是竞争拓扑，不放宽“不停止外部实例”的要求；发布子进程完整清理另有真实 fork/信号/超时测试。
- `cargo fmt --all -- --check`：exit 0，`recovery-fmt-final.log`。
- `cargo clippy --offline --locked --all-targets -- -D warnings`：exit 0，`recovery-clippy-final.log`。
- `uvx ruff==0.16.8 format --check scripts/ci/test-justfile.py tests/support/service_manager.py` 与同范围 `check`：exit 0，`recovery-python-final.log`。
- `bash -n scripts/install/local-dev-install.sh scripts/install/verify-local-dev-install.sh`、`git diff --check`：exit 0。
- `git diff --quiet -- tests/override_spawn.rs` 与 `git diff --cached --exit-code`：均 exit 0；本轮未运行 override_spawn、没有暂存内容。

以下保留上一轮完整实现与历史验证，不替代以上当前修复结果。


## 上一轮实现结论（历史记录）

用户已批准的服务六命令与本地状态保持冷升级已实现，改动保持未暂存。一次完整定向 Rust 回归 **185 passed / 3 ignored**；随后补齐缺失 catalog 的严格拒绝，受影响范围 **74 passed / 3 ignored**，累计去重 **227 项通过、3 项忽略**，其中新增用户服务测试 17 项；Justfile 15 项契约、本地安装脚本回归、发布工作流契约、格式与严格 all-targets Clippy 通过。

**完整测试全绿仍未取得**：未修改的 `tests/override_spawn.rs` 首轮有 2 项失败，单独选择该套件复测有 6 项失败。保持原断言、期限及测试文件；没有独立旧 HEAD 基线证明这些失败的根因或与本轮改动的关系。

未操作真实用户服务、未安装到真实 HOME、未停止或重启生产实例，未 merge/commit/push。真实二进制发布仅发生在测试临时目录；没有完整性能、四平台或长稳通过结论。

## 范围与基线

- 验收契约：[service-upgrade-contract](service-upgrade-contract.md)，实现前已写入。
- 起始分支：`to-rust`；实际 HEAD：`ce8d41c406238794f5c7d7a55b9e7946361ee4b8`；工作区初始干净。
- 平台：Darwin arm64；`rustc 1.98.1 (48a229cea 2026-09-01)`；使用已有依赖及 `Cargo.lock`，未新增依赖。
- 公开契约：[CLI](../docs/cli/spec.md#当前用户服务)、[安装](../docs/install/README.md#可选的本地安装)、[错误码](../docs/api/error-codes.md#b3-service-与本地冷升级)。

## 实现与安全边界

- `src/user_service.rs` 统一注册、生成固定定义、平台命令、readiness、冷安装与恢复。管理器命令执行是唯一外部替换入口，生产没有环境变量启用假管理器的通道。
- 注册绑定 HOME、绝对二进制路径、runtime、随机服务身份和认证冻结快照。主进程读取注册并核对执行路径、环境及身份；环境本身不构成服务所有权。
- 服务/安装使用 `Store::load_existing` 验证已建立的 schema-2 authority；catalog 缺失时拒绝，即使兼容镜像完整也不重建。普通配置命令原有 legacy takeover 保持。
- 原生操作先核对操作系统账户 HOME，Linux bus 固定到当前 UID 的 user manager。临时 HOME 的真实 CLI 服务命令在账户校验时拒绝，未调用真实管理器变更。
- macOS 登录副本与当前加载分离；stop 使用 bootout，disable 只移除验证属于注册的登录副本。外部持久 disabled 与登录副本共存时，start 移除受控副本后 enable/bootstrap，保持实际自启动关闭。
- Linux enable/disable 不带 `--now`；固定前台 ExecStart 使用 systemd 的引用与替换语法，不是 shell。加载路径、drop-ins、已加载 ExecStart 及 MainPID 均核对。
- 状态四字段分别来自持久注册、管理器加载、实际 daemon 身份/readiness、自启动证据。单次管理器执行 15 秒，stdout/stderr 各 64 KiB；错误不回显管理器正文。readiness 独立等待最多 10 秒。
- 新服务 descriptor 使用可选 `service_id`；普通实例省略，原 canonical bytes 保持。服务命令与安装持有稳定操作锁，继续使用 launch/instance/PID/nonce 所有权；运行实例持有共享二进制锁，发布取得独占锁。实际停止通过管理器，不按猜测 PID 发信号。
- 安装先复制并检查候选，随后捕获实际已应用的配置与选择。首次/停止态保持停止，运行态通过管理器冷切换。失败尝试旧二进制和精确快照，恢复失败明确报告并保留 `.zc.recovery.*`。没有 plain start/default active 回退。
- 手动实例、其他安装/runtime、遗留目标进程、坏状态与外来定义保持拒绝；错误提供显式迁移入口。仅本地安装器新增自动冷激活，Release 独立安装器和 Homebrew 没有自动服务升级能力。

## 主源核查

本机读取 `man launchctl`、`man launchd.plist`，没有执行真实 launchctl/systemctl mutation：

- launchctl 的 bootstrap/bootout 控制加载；enable/disable 是跨重启持久状态，disabled job 无法 bootstrap；kickstart 是显式运行请求。
- launchd.plist 的 RunAtLoad 在加载时启动，KeepAlive 可触发重启，LaunchAgent 位于用户登录目录，进程应保持前台。

官方 systemd 主源：

1. [systemctl.xml](https://raw.githubusercontent.com/systemd/systemd/main/man/systemctl.xml)：enable 不隐式 start；disable 不隐式 stop；`--now` 才组合执行；disable 会按 unit 的安装关系移除链接。
2. [systemd.service.xml](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.service.xml)：显式管理器 stop 与 Restart 分开；ExecStart 使用 systemd 自身引用规则，`:` 前缀禁用环境替换，百分号仍按 specifier 规则处理。
3. [systemd.exec.xml](https://raw.githubusercontent.com/systemd/systemd/main/man/systemd.exec.xml)：执行环境与 Environment 设置。
4. [systemctl-show.c](https://raw.githubusercontent.com/systemd/systemd/main/src/systemctl/systemctl-show.c)：ExecStart 的当前官方文本形状为 `{ path=… ; argv[]=… ; ignore_errors=… ; … }`，argv 用空格连接；实现对已知完整路径/参数前缀核对，拒绝未知形状。不是宣称未来任意版本输出都兼容。

读取副本最初保存于 `/tmp/zc-launchctl-man.txt`、`/tmp/zc-launchd-plist-man.txt`、`/tmp/zc-systemctl.xml`、`/tmp/zc-systemd-service.xml`、`/tmp/zc-systemd-exec.xml`、`/tmp/zc-systemctl-show.c`；以上链接和语义记录长期保留在此，不以临时文件存在作为仓库证据。

## 红绿切片与独立测试

测试入口为公开 CLI/注入命令执行器及本地安装器。`tests/support/service_manager.py` 独立解析 plist/systemd 参数并启动真实临时二进制，永不调用原生 launchctl/systemctl；管理器成功与 daemon ready 分别观察。

| 切片 | 红态 | 绿态与证据 |
| --- | --- | --- |
| CLI | service 命令未知 | 组/动作帮助、严格参数；`01-red.log`、`01-green.log` |
| enable/disable | 模块尚未存在 | 首次注册、自启动不启动；`02-red.log`、`02-green.log` |
| 生命周期 | start 尚未实现 | 两平台真实 foreground daemon、start/stop/restart、删除来源后冻结复用；`03-red.log`、`03-green.log` |
| 手动所有权 | 普通 stop 绕过服务注册 | `SERVICE_OWNED`；`04-red.log`、`04-green.log` |
| 安装 | 安装协调入口尚未存在 | 首次/停止态/运行态、失败恢复；`05-red.log`、`05-green.log` |
| 后续登录 | stop 后持久激活闸门仍关闭，启用服务无法在后续登录启动 | 停止结束恢复登录可激活性；`07-red-login.log`、`07-green.log` |
| 迁移提示 | 拒绝手动实例后遗留空注册目录，安装返回候选错误而非迁移说明 | 在创建注册目录前完成手动所有权检查；`10-red-manual.log`、`10-green-manual.log` |
| launchd disabled | 清除外部 disabled 时错误打开实际自启动 | 保持关闭偏好再启动；`12-red-launchd.log`、`12-green-launchd.log` |
| 缺失 catalog | 注册服务的 status 经普通 Store.load 从镜像重建缺失 authority | 新严格读取拒绝且不重建，候选检查同样拒绝；`13-red-authority.log`、`13-green-authority.log` |

中间曾出现新增字段初始化遗漏、Clippy 提示，以及公开安装目录被误用 private-directory 校验导致的失败；均修复并重新运行，不计作通过。

最终新增 17 项涵盖：两适配器定义/命令、引用路径、六个 CLI 动作、后续登录、enable/disable 独立性、冻结来源与端口、托管 secret/已应用选择/active 变更、custom runtime、坏/缺失/外来状态保留、catalog 缺失时禁止镜像重建、管理器拒绝与不存在、无 daemon 的假成功、候选检查失败、真实新 binary 启动失败、发布失败、恢复失败及备份、手动迁移拒绝、其他安装目标拒绝、同 namespace 操作竞争、同一安装的其他 HOME 运行实例、输出上界和实际执行期限。

这些是回归测试数量，不将子进程复测或一个用例中的两个适配器再计为独立测试项。

## 最终命令与结果

原始输出在 `target/service-upgrade/`，属于本地运行工件。

### 1. 匹配改动的 Rust 回归

```bash
ulimit -n 8192
cargo test --offline --locked --lib \
  --test user_service --test daemon --test daemon_races \
  --test cli --test cli_managed --test fsutil --test profile_secret \
  --test runtime --test state_durability --test service \
  --test observability_lifecycle --test connections_cli
```

结果：**185 passed / 3 ignored / 0 failed**，exit 0；`regression-final.log`。

| 套件 | passed | ignored |
| --- | ---: | ---: |
| lib | 19 | 0 |
| cli / cli_managed | 9 / 30 | 0 |
| connections_cli | 7 | 0 |
| daemon / daemon_races | 18 / 8 | 0 |
| fsutil | 14 | 0 |
| observability_lifecycle | 16 | 0 |
| profile_secret | 11 | 3 |
| runtime / state_durability / service | 22 / 5 / 10 | 0 |
| user_service | 16 | 0 |

3 项忽略为已有显式历史二进制对照；fsutil 的两个子进程验证包含在父项中，不重复累加。

此后对缺失 catalog 补红绿测试，服务/安装使用严格 `Store::load_existing`，同时保留普通 `load` 的既有迁移语义。运行受影响范围：

```bash
ulimit -n 8192
cargo test --offline --locked --test user_service --test store \
  --test store_legacy --test state_durability --test profile_secret
```

`authority-final.log`：**74 passed / 3 ignored**，exit 0，分别为用户服务 17、store 23、store_legacy 18、state_durability 5、profile_secret 11。与上一表去重为 **227 项通过、3 项忽略**。其中跨 namespace 拒绝增加迁移提示；新启动尝试拒绝认领在调用前出现的管理器进程。最后再次运行 `cargo test --offline --locked --test user_service`，17 项通过（`service-final.log`）。格式及严格 Clippy 随后重新检查。

### 2. 安装与交付契约

```bash
python3 scripts/ci/test-justfile.py
bash scripts/install/verify-local-dev-install.sh
bash scripts/ci/test-release-workflow.sh
```

全部 exit 0：Justfile **15 tests**；本地发布、运行目标拒绝、发布前启动竞态、symlink 和缺失候选保留旧目标均 PASS；工作流契约 PASS。日志：`justfile-final.log`、`install-final.log`、`workflow-final.log`。本地安装回归现在使用真实 Rust 候选和临时 HOME/runtime；Justfile 的工具链替身仅证明 recipe 构建顺序、参数字边界及错误传播，服务恢复由真实二进制测试单独证明。

### 3. 格式与静态检查

```bash
cargo fmt --all -- --check
cargo clippy --offline --locked --all-targets -- -D warnings
uvx ruff==0.16.8 format --check scripts/ci/test-justfile.py tests/support/service_manager.py
uvx ruff==0.16.8 check scripts/ci/test-justfile.py tests/support/service_manager.py
bash -n scripts/install/local-dev-install.sh scripts/install/verify-local-dev-install.sh
git diff --check
```

全部通过，Clippy 日志为 `clippy-final.log`。

### 4. 保留的 override_spawn 失败

首轮命令：

```bash
ulimit -n 8192
cargo test --offline --locked --lib --test daemon --test daemon_races \
  --test runtime --test fsutil --test cli --test cli_managed \
  --test profile_secret --test override_spawn --test state_durability \
  -- --skip diagnostic_commands_are_real
```

`regression-01.log`：进入 override_spawn 前的套件通过；该套件 **6 passed / 2 failed**，Cargo 测试退出 101。失败项为 `real_spawn_control` 和 `retry_wait_and_real_child_share_one_execution_budget`；有原期限内真实子进程未运行/超时证据。此轮命令的末尾 tail 隐藏了 shell 的非零退出码，因此结果以 Cargo 明确失败及测试统计为准，未记为成功；其中 skip 没有匹配到实际用例，不能声称过滤了某项。

随后仅选择该套件复测（与 Clippy 并行发起；Cargo 自身仍串行取得构建锁）：

```bash
ulimit -n 8192
cargo test --offline --locked --test override_spawn
```

`override-spawn-recheck.log`：**2 passed / 6 failed**，exit 101。失败包括 `one_text_busy_then_executes_frozen_bytes`、`two_text_busy_then_executes_frozen_bytes`、共享预算项，随后 permission/persistent/real_spawn 项出现锁中毒。没有延长期限或修改测试来隐藏失败。`git diff --quiet -- tests/override_spawn.rs` 返回 0。根因、负载影响及旧 HEAD 独立重现仍未判定；不以文件未修改推导完全无关。

## 验收边界与后续证据

- 自动化已证明两种适配器的固定定义/命令模型，以及真实隔离 daemon readiness、冷发布和恢复；**未证明原生 launchd/systemd 登录会话中的完整行为**。真实注册、bootout/bootstrap、enable/disable、注销/再登录须在可销毁账户或机器单独验收。本轮按授权明确没有执行这些真实变更。
- systemctl/launchctl 的输出必须符合已核查的受限形状；未知形状拒绝而非猜测所有权。平台版本和原生输出差异仍需原生门禁。
- 普通后台配置、代理协议与数据面未重构；启动/安装增加锁与状态校验，本轮没有性能 PASS，也没有四平台、24/72 小时长稳或完整 Release 安装矩阵结论。
- 冷升级允许连接关闭。首次配置或显式 `-c` 才重读来源；普通服务启动继续冻结快照，离线新 active/head/selection 要明确重新准备。
- 手动实例自动停止与恢复属于更广范围，本轮保持拒绝。不同 runtime、不同安装路径、坏状态和无法证明的进程均不通过默认启动绕过。
- 保留 override_spawn 的未解决失败，完整默认测试全绿仍是未满足项；本次完成的是已批准功能与其匹配的隔离回归，不是完整发布批准。
