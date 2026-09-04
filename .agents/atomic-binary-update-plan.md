# zc 原子二进制更新与显式重启实施计划

> **状态：** Proposed，当前优先实现方向
>
> **目标平台：** Linux / macOS，amd64 / arm64
>
> **定位：** 原子发布新二进制；运行中的daemon继续使用旧二进制；通过status明确要求用户重启
>
> **不是：** hot upgrade、seamless restart或连接无损切换
>
> **未来方向：** [优雅二进制替换方案](./hot-upgrade-plan.md)

---

## 1. 决策摘要

zc采用与Mihomo同一类的简单升级模型，但把重启从安装动作中明确拆开：

```text
verify release
    ↓
atomically replace installed executable
    ↓
running daemon keeps serving with its already-mapped old executable
    ↓
status: restart_required = true
    ↓
operator explicitly runs `zc restart`
    ↓
new daemon starts from the installed executable
```

Mihomo的`/upgrade`在替换后进入restart/exec；zc首版不自动执行这一步。原因是：

- 安装二进制不必立即打断现有连接；
- 用户能选择合适的维护时间；
- 安装成功与重启成功是两个可独立判断的事务；
- 不需要listener handoff、双进程协调或connection drain；
- 不会把冷重启伪装成优雅替换。

研究依据见[与Mihomo的行为对照](./mihomo-hot-upgrade-research.md)。

---

## 2. 用户可见保证

### 2.1 保证

1. 运行中更新只替换磁盘上的目标二进制，不向daemon发signal，不调用stop/start/reload。
2. 已运行daemon继续执行启动时映射的旧二进制，已有连接与新连接都继续由它处理。
3. 安装目标通过同目录atomic rename发布，读者只能看到完整old或完整new文件。
4. `zc status`同时显示installed与running二进制身份。
5. 两者不同，即使version string相同，也显示`restart_required: yes`。
6. 只有用户显式选择的cold action（`zc restart`、stop→start、`--apply restart`或外部supervisor restart）才激活新二进制。
7. 激活是冷重启，会关闭已有连接；CLI与文档必须明确说明。
8. 安装或身份判断失败不会静默stop/restart，也不会降级为其他升级路径。
9. 二进制回退必须由用户显式重新发布known-good版本；不自动切换binary。
10. 首个支持本合同的版本，以及未来合同不兼容升级，要求一次明确的stop/install/start。

### 2.2 不保证

- 安装后daemon立即运行新版本；
- 重启期间listener连续或连接无损；
- 把existing connection迁移到新进程；
- 外部supervisor不会因独立故障自动重启daemon；
- 跨不同用户、不同runtime namespace发现所有zc进程；
- Homebrew、Debian或其他package manager共享standalone安装合同；
- power loss后的绝对持久性；parent-directory sync结果单独报告；
- 旧版本与任意未来版本之间的控制协议兼容；
- 未经release tests验证的network/FUSE filesystem具有与local APFS/ext4同等的rename、lock或sync语义。

首版支持范围限定为owner-controlled standalone regular-file target与release tests覆盖的local filesystem。

---

## 3. 当前代码基线

当前实现与目标有以下差距：

- `install.sh`要求目标完全停止后才能替换，并用process scan再次确认；
- `scripts/install/local-dev-install.sh`同样拒绝运行中的目标；
- `just install`执行stop → replace → start，并在失败时尝试恢复backup；
- `src/runtime_descriptor.zig`当前schema v2不记录运行二进制身份或安装目标；
- `zc status`只显示daemon/config/runtime信息，不显示installed/running binary关系；
- `zc reload`在hot reload不可用时可以fallback到冷重启；如果binary pending，这会意外激活新版本；
- restart失败后的“previous daemon restored”只恢复previous invocation，并没有恢复旧binary，现有文案不准确；
- shell installer使用`mv -f`完成可见性切换，但没有统一的file sync、parent sync和readback分类；
- 当前release checksum验证archive，不等于解包后executable identity。

本计划直接替换这些行为，不保留旧installer状态机的兼容分支。

---

## 4. 冻结术语

| 术语 | 定义 |
| --- | --- |
| **ArtifactIdentity** | Executable bytes的SHA-256；二进制判等的唯一依据 |
| **archive_digest** | Release archive的SHA-256，只证明downloaded archive与release checksum一致 |
| **artifact_digest** | ArtifactIdentity的canonical `sha256:<64 lowercase hex>`表示 |
| **binary_target** | 本次standalone安装管理的canonical parent-dir FD + leaf `zc` |
| **binary management** | `standalone | external`；只有standalone target参与本计划的publication/activation lock |
| **installed binary** | 当前`binary_target`文件的artifact identity；version只是可选展示metadata |
| **running binary** | daemon启动时冻结的version、artifact identity、management与target snapshot |
| **binary relation** | `same | different | not_running | unknown` |
| **publication** | 把new artifact原子发布到`binary_target`，不改变daemon进程 |
| **activation** | 通过冷重启让daemon执行installed binary |
| **binary contract** | runtime descriptor、stop/restart身份和status字段的兼容合同编号 |

规则：

- Version只用于展示，不能证明两个binary相同；
- 同version、不同artifact digest仍然是`different`；
- Device/inode用于单次事务内验证，不作为跨安装的持久身份；
- `restart_required`从installed/running facts实时派生，不写pending marker；
- Target directory中的owner-only regular `.zc.install.lock`同时是stable advisory lock和standalone authority marker；
- 没有该marker的binary视为external，不在相邻目录创建lock，也不声称可由standalone publisher管理；
- 本计划不使用未来方案的`selected/serving/candidate/draining`状态模型。

---

## 5. 最小状态模型

```text
                       atomic publication
running A + installed A ───────────────────→ running A + installed B
      relation=same                              relation=different
 restart_required=false                       restart_required=true
                                                        │
                                                        │ explicit restart
                                                        ▼
                                              running B + installed B
                                                  relation=same
                                             restart_required=false
```

真值表：

| Runtime | Installed observation | Relation | restart_required |
| --- | --- | --- | --- |
| stopped + standalone authority | readable B | `not_running` | `false` |
| stopped + no authority/target | unknown | `unknown` | `null` |
| running A | exact A | `same` | `false` |
| running A | exact B | `different` | `true` |
| running A | same version、different digest | `different` | `true` |
| running identity或target无法可信读取 | unknown | `unknown` | `null` |

允许连续发布：

```text
running A, installed A
→ publish B
→ publish C
→ running A, installed C, restart_required=true
```

不增加pending transaction或历史链；当前事实始终只有running identity与target identity。

---

## 6. BinaryIdentity

新增一个小模块，例如`src/artifact_identity.zig`：

```zig
pub const ArtifactIdentity = struct {
    digest: [32]u8,
};

pub const ExecutableObservation = struct {
    identity: ArtifactIdentity,
    device: u64,
    inode: u64,
    size: u64,
};

pub fn inspectExecutableAt(parent: std.Io.Dir, leaf: []const u8) !ExecutableObservation;
pub fn observeProcessExecutable() !ExecutableObservation;
pub fn eql(a: ArtifactIdentity, b: ArtifactIdentity) bool;
```

职责：

- 固定canonical parent-dir FD，所有leaf操作使用no-follow `*at`形式；
- Leaf明确允许`absent | regular`，fresh install不要求target预先存在；
- 拒绝symlink、directory、special file及不安全ownership/mode；
- streaming SHA-256，不把整个binary读入内存；
- 输出canonical lowercase `sha256:<64 hex>`；
- 返回用于事务内readback的device/inode/size；
- Linux通过实际`/proc/self/exe` FD、macOS通过经native process contract tests验证的main-image vnode observation证明process executable；
- 对known vectors、empty/truncated/unreadable文件提供确定错误。

不新增独立`build_id`：artifact digest已经完整表达exact bytes，第二套身份只会制造冲突。
Version与binary contract不能从任意executable bytes安全推导：running metadata来自该进程的build options；
installed metadata只有在observing CLI已证明自己就是exact target，或publisher刚完成candidate self-check时才可填充，
其他情况为`null`。任何relation/restart decision都不得依赖这些展示metadata是否可得；publication compatibility
在rename前由正在执行的candidate publisher与running descriptor直接比较。

### 6.1 BinaryTargetGuard

`BinaryTargetGuard`是一次lifecycle operation唯一持有的guard，禁止nested reacquire：

- `shared`：standalone status取得后重读descriptor、hash一个opened target FD、再次验证PID+nonce；
- `exclusive`：standalone publish、start、foreground start、stop、restart/recovery及所有cold fallback；
- Private daemon child不自行acquire；parent把同一lock open-file-description传给child，直到ready后双方close；
- External/package-managed binary不创建或使用相邻guard；
- Bounded shared acquire失败时daemon health仍可返回，但binary relation必须为`unknown/null`；
- 所有cold restart调用统一复用已持有guard，不能绕过seam直接调用`replaceDaemonWithRollback()`。

Advisory lock只约束遵守合同的zc writers。Non-cooperating actor仍可修改文件；检测到这种情况时输出
tampered/unknown，不能扩大保证为系统级CAS。

### 6.2 Running identity何时冻结

Daemon的running identity必须在ready descriptor发布前冻结，不能在更新后通过可变target反推。

Start/restart/foreground startup遵循：

1. 从standalone authority marker取得一次exclusive `BinaryTargetGuard`；
2. 在guard内用actual process-executable FD/vnode与同一opened target FD比较device/inode并hash；
3. 计算target artifact digest并冻结management、version、digest、canonical target、binary contract；
4. 启动daemon并发布provisional descriptor；
5. Background child继承guard且不重复acquire；
6. Daemon ready后发布同一binary identity并close child ref；
7. Parent确认ready后close parent ref。

若调用者本身已经是被替换前启动的旧CLI，而locked target已经变成new binary，则拒绝：

```text
BINARY_ACTIVATION_TARGET_MISMATCH
```

提示用户从exact `binary_target`重新执行命令，禁止旧CLI启动错误版本。Linux/macOS的process executable
observation与guard inheritance都必须由native real-process tests证明；任一平台无法证明就不在该平台启用running publication。

---

## 7. RuntimeDescriptor v3

`src/runtime_descriptor.zig`直接升级到schema v3，不增加v2 decoder：

```json
{
  "schema_version": 3,
  "pid": 4123,
  "nonce": "...",
  "endpoint": "...",
  "identity": {"key":"profile","revision":"..."},
  "generation": 7,
  "ready": true,
  "invocation": {"foreground":false,"prepared":true,"config_path":"..."},
  "binary": {
    "management": "standalone",
    "target_path": "/home/me/.local/bin/zc",
    "version": "1.2.0",
    "artifact_digest": "sha256:...",
    "contract": 1
  }
}
```

约束：

- `binary`是required，不允许缺省；
- `management=standalone`必须由相邻owner-only regular authority/lock file证明；external只记录观察身份；
- `target_path`必须absolute、canonical、无NUL且有明确长度上限；
- digest必须是canonical lowercase编码；
- provisional→ready、generation更新与所有CAS重发必须原样保留binary；
- Descriptor只证明running process启动时的binary snapshot；
- PID仍与nonce共同验证runtime instance，digest不能代替process identity；
- Corrupt、v2、contract mismatch在running publication前fail closed。

### 7.1 首次bootstrap

当前running daemon只会写schema v2，因此首个v3版本不能安全执行running publication。

这是offline maintenance，而不是三个可并发执行的普通命令：

```text
disable or pause the external supervisor, if any
/path/to/old/zc stop
verify the daemon lifetime lock is free and no authenticated instance is live
install v3-capable zc and create the standalone authority/lock file
remove only proven-stale v2 descriptor artifacts
/path/to/new/zc start
```

Legacy binary不参与new target guard，因此bootstrap期间不得与legacy `start`并发。若daemon已经可靠stopped且无supervisor，
installer可以直接发布v3 binary。未来binary contract bump采用相同规则，不添加兼容层。

---

## 8. BinaryPublication

新增`src/binary_publication.zig`，对外只提供一个深接口：

```zig
pub fn publishSelf(
    allocator: std.mem.Allocator,
    target_path: []const u8,
) !PublishResult;
```

Extracted candidate通过不出现在help中的private command调用该接口；命令只接受target，不接受任意source executable path。
Publisher从自身process executable取得candidate bytes与build metadata。它统一standalone installer、local-dev install与
`just install`，shell不再自行实现process scan、backup、rename和rollback状态机。

### 8.1 Stable lock

- Fresh/stopped standalone install在验证owner-controlled canonical parent dir后创建owner-only `.zc.install.lock` regular file；
- Marker一旦创建永不unlink，同时证明该`parent/zc`由standalone合同管理；
- Running target没有该marker时视为external，publisher不得临时创建marker并接管；
- Shared/exclusive advisory guard串行化status与全部cooperating lifecycle mutations；
- 不再使用crash后可能遗留的mkdir lock；旧lock directory只给出actionable bootstrap error，不自动删除；
- Lock metadata只用于诊断，不用于抢锁；
- 固定锁顺序：binary-target guard → runtime transaction；
- Installer等待/失败时不stop daemon。

### 8.2 Publication顺序

```text
verify archive checksum
→ safely extract candidate
→ candidate --version self-check
→ calculate candidate artifact digest
→ open and freeze canonical parent-dir FD + leaf `zc`
→ acquire or create standalone target guard under the stopped/fresh rules
→ inspect target as absent|regular and inspect authenticated runtime
→ validate binary contract and exact target path
→ create same-directory O_EXCL stage
→ copy + chmod + file sync
→ hash/readback staged executable
→ final no-follow target/runtime recheck
→ atomic rename(stage, target)        # commit point
→ readback target artifact digest
→ sync parent directory
→ release lock
```

### 8.3 Running preflight

Running publication只在以下facts全部成立时允许：

- RuntimeDescriptor canonical且ready；
- PID+nonce仍匹配live daemon；
- Descriptor `binary.target_path` exact等于本次target；
- Running与candidate的binary contract相同；
- Existing owner-only regular authority/lock marker证明target是standalone-managed；
- Target leaf是absent或受支持regular file，且所有操作基于同一个parent-dir FD；
- 没有并发start/stop/restart/publication持exclusive guard。

不要求running digest等于当前target digest，因此A运行时允许B→C连续publication。

若daemon在其他target、descriptor为v2/corrupt、runtime lock held但process无法认证，rename前返回明确错误，target保持不变。

### 8.4 Commit与durability

Atomic rename是唯一publication commit point。Outcome不能只由稍后的readback反推历史：

| Transaction fact | Publication outcome |
| --- | --- |
| Candidate已与target相同，未rename | `already_installed` |
| Rename尚未成功 | `not_published` |
| Rename syscall成功 | `published` |
| Process在rename边界丢失、没有transaction-local fact | Observer只能报告current target，不能编造历史outcome |

Rename成功后另报`target_after = candidate | changed | unknown`。若readback不是candidate，说明non-cooperating
writer或外部tamper；publication历史仍是`published`，但整体命令以明确tampered/unknown错误结束，绝不降级成
`not_published`。

Parent-directory sync单独报告：

```text
sync: complete | uncertain
```

- Readback=candidate但parent sync失败：仍是published，输出warning与`sync: uncertain`；
- Old/new线性化保证只覆盖持有同一stable guard的writers；
- 不把sync failure或post-rename external write伪装成rollback；
- Rename后禁止trap反向rename、stop daemon或自动恢复backup；
- SIGKILL可能遗留未选中的stage，下次publication必须安全清理自己可证明的stale stage。

---

## 9. 安装流程

### 9.1 Daemon stopped

```text
publish B
→ daemon remains stopped
→ relation=not_running
→ restart_required=false
→ print exact `zc start` next step
```

Installer绝不猜测性start。

### 9.2 Daemon running

```text
running A
→ publish B
→ PID/nonce/listener/connections unchanged
→ old daemon continues accepting with A
→ relation=different
→ restart_required=true
→ print exact `zc restart` next step
```

Installer成功的文本示例：

```text
Result: published
Target: /home/me/.local/bin/zc
Installed: zc 1.2.0 sha256:...
Running: zc 1.1.0 sha256:... (pid 4123)
Daemon action: none
Restart required: yes
Apply: /home/me/.local/bin/zc restart
Sync: complete
```

若installed与running digest相同：

```text
Result: already_installed
Daemon action: none
Restart required: no
```

Progress写stderr；最终text或JSON result写stdout，保持单一结果。

### 9.3 Foreground/supervised daemon

Publication仍不signal进程。Status显示：

```text
Restart required: yes
Apply: restart through the process supervisor
```

`zc restart`继续拒绝foreground daemon。systemd/launchd/container何时重启不属于standalone installer事务。

---

## 10. Status与minimal API

### 10.1 `zc status --json`

在现有success envelope的`data`中增加required `binary`：

```json
{
  "binary": {
    "management": "standalone",
    "target_path": "/home/me/.local/bin/zc",
    "installed": {
      "version": "1.2.0",
      "artifact_digest": "sha256:...",
      "contract": 1
    },
    "running": {
      "version": "1.1.0",
      "artifact_digest": "sha256:...",
      "contract": 1
    },
    "relation": "different",
    "restart_required": true,
    "restart_method": "zc_restart"
  }
}
```

字段规则：

- Daemon running时，status始终观察descriptor冻结的`binary.target_path`，不把调用status的foreign CLI误当成installed target；
- Daemon stopped且没有descriptor时，只有当前CLI与相邻standalone authority marker可证明exact target时才返回`not_running`；否则`target_path=null`、`installed=null`、relation=`unknown`；
- `installed.version`与`installed.contract`允许为`null`；CLI只有在其process executable与本次opened target的device/inode仍相同时才能填充自己的build metadata，foreign/racing CLI不得猜值或执行target；
- `running=null`且daemon stopped时，relation=`not_running`、restart_required=`false`；
- 无法读取target或可信running identity时，relation=`unknown`、restart_required=`null`；
- Pending binary不是daemon health failure，`state=running`与exit 0保持不变；
- Digest完整输出，不截断；
- `restart_method`为`zc_restart | supervisor | manual | null`。

Standalone status使用bounded coherent observation：读descriptor hint → 取得shared guard → 重读并认证descriptor → 从一个
opened target FD计算digest → 输出前再次验证PID+nonce/descriptor generation。检测到变化则有限重试，超限只把binary
relation置为`unknown/null`，不把整个daemon health伪报为失败。Status返回后facts仍可能正常变化，不承诺永久快照。

### 10.2 Text status

固定追加：

```text
binary_target: /home/me/.local/bin/zc
binary_installed: zc 1.2.0 sha256:...
binary_running: zc 1.1.0 sha256:...
binary_relation: different
restart_required: yes
restart_action: /home/me/.local/bin/zc restart
```

Unknown必须打印`unknown`，不能猜成yes/no。

### 10.3 Minimal API

- `/version`增加running `artifact_digest`与binary contract；
- `/status`使用同一术语返回daemon观察到的running/installed relation；installed version/contract不可证明时返回`null`；
- API中的running identity来自启动时冻结值，不能从当前target反推；
- 无controller时CLI仍能从RuntimeDescriptor与target readback得到相同事实。

---

## 11. 命令交互

| 命令 | Pending binary时的行为 |
| --- | --- |
| `zc status` | 正常成功，显示`restart_required: yes` |
| `zc start` | 仍返回`already_running`；不得借机升级 |
| `zc stop` | 正常停止old daemon |
| `zc restart` | 显式cold activation；提前说明connections会关闭 |
| `zc reload` | 在任何restart fallback前返回`BINARY_RESTART_REQUIRED` |
| `zc config update --apply auto` | 若将fallback到restart则拒绝，提示显式restart |
| `zc config update --apply hot` | 只允许真实hot path；不可激活binary |
| `zc config update --apply restart` | 用户已显式选择cold activation，可以应用new binary |
| `zc config override <script>` / `--clear` | 当前auto-apply在尝试restart前必须经过同一fallback gate |
| Proxy/status/log只读操作 | 保持可用，不因pending binary被阻断 |

Pending binary不会全面锁死CLI；只阻止会隐式消费该更新的cold fallback。实现中冻结：

```text
ColdActivationIntent = explicit | fallback
```

所有调用`replaceDaemonWithRollback()`的路径必须经过一个集中seam并携带intent：

- `explicit`：`zc restart`、`config update --apply restart`及未来文档明确标注会cold restart的命令；
- `fallback`：`zc reload`、`--apply auto`、override set/clear等自动路径；
- Relation=`different|unknown`时fallback一律fail closed；
- Seam在持有exclusive guard后重新计算relation，禁止lock前检查后绕过。

---

## 12. 显式ColdActivation

显式cold-restart操作是publication之外的独立事务；`zc restart`和`config update --apply restart`共用同一seam：

1. 从RuntimeDescriptor取得target hint；
2. 取得一次exclusive `BinaryTargetGuard`；
3. 在guard内重读descriptor并冻结PID+nonce、invocation、config identity与installed digest；
4. 用actual process executable observation验证调用者来自同一opened target；
5. 输出cold restart warning；
6. 停止old PID+nonce并等待descriptor清理；
7. 从guard固定的target启动new daemon；
8. Private child继承guard且不reacquire，等待ready descriptor；
9. 验证new PID/nonce及running digest=installed digest；
10. Close parent/child guard refs，status自然回到`same`。

验收上明确允许listener空窗和existing connections中断。

### 12.1 Restart failure

现有`replaceDaemonWithRollback()`恢复的是previous invocation，而不是previous binary。实施时必须：

- 删除“previous daemon/binary restored”之类误导文案；
- 若new binary能够用previous invocation启动，返回稳定结果`invocation_recovered`、非零exit，并报告：

```text
Restart failed for the requested invocation; the previous invocation is running under the installed binary.
```

  此时必须验证`relation=same`、`restart_required=false`，因为binary已激活，只是requested invocation失败；
- 若恢复也失败，返回`BINARY_ACTIVATION_FAILED`，daemon保持stopped并给出日志与显式binary rollback步骤；
- 不自动重新发布旧binary；
- 不把invocation recovery称为binary rollback。

---

## 13. 显式Binary rollback

Publication不保留自动backup状态机。只有首个publisher-capable artifact及之后的known-good版本能执行同一
`publishSelf`合同：

```text
publish publisher-capable known-good version
→ inspect restart_required
→ explicitly restart when ready
```

Pre-v3/不含private publisher的artifact不能假装走此流程；回退到它必须先停止daemon，再使用该版本原有的
legacy/package reinstall方式，最后显式start。这一offline路径不具有running publication保证，也不新增独立helper
或任意source-FD接口。

两种publisher-capable情况：

### 13.1 尚未激活

```text
running A, installed B
→ publish A
→ running A, installed A
→ restart_required=false
```

无需重启，old daemon从未改变。

### 13.2 已激活但B无法运行

Daemon可能已经stopped：

```text
publish A
→ zc start
```

Installer输出必须给出exact命令，但不自动执行。

---

## 14. Error contract

| Error code | 语义 |
| --- | --- |
| `BINARY_PUBLISH_BUSY` | 另一个status/publisher/start/stop/restart lifecycle operation持有冲突guard |
| `BINARY_PUBLISH_TARGET_UNSUPPORTED` | Target是symlink、directory、special file或不安全ownership/mode |
| `BINARY_PUBLISH_RUNTIME_INCOMPATIBLE` | Live descriptor/schema/binary contract不兼容，需要cold bootstrap |
| `BINARY_PUBLISH_TARGET_MISMATCH` | Running daemon来自另一个target |
| `BINARY_PUBLISH_IDENTITY_UNKNOWN` | 无法认证live PID+nonce或binary identity |
| `BINARY_PUBLISH_PRECOMMIT_FAILED` | Rename前失败，target保持old |
| `BINARY_PUBLISH_OUTCOME_UNKNOWN` | Rename/readback后无法证明target是old还是candidate |
| `BINARY_RESTART_REQUIRED` | 某命令将隐式cold activate pending binary，要求显式restart |
| `BINARY_ACTIVATION_TARGET_MISMATCH` | 执行restart的CLI不是descriptor记录的target binary |
| `BINARY_ACTIVATION_INVOCATION_RECOVERED` | Requested invocation失败，但previous invocation已在installed binary下恢复；非零exit |
| `BINARY_ACTIVATION_FAILED` | Requested与previous invocation均未能在installed binary下运行 |

所有错误都必须包含：

- daemon是否仍运行；
- installed/running identities是否已知；
- publication是否发生；
- 下一条可复制命令；
- 是否会中断连接。

---

## 15. Packaging范围

### 15.1 Standalone与local development

首版只统一：

- `install.sh`；
- `scripts/install/local-dev-install.sh`；
- `just install`。

Shell只负责release解析、download、archive checksum与安全extract。实际publication调用candidate binary中的唯一Zig seam。

删除：

- Running target process scan作为publication authority；
- install前自动stop；
- install后自动start；
- shell backup/trap binary rollback；
- 三个入口各自实现的rename/verification分支。

### 15.2 Homebrew、Debian与supervisor

首版不接管：

- Homebrew Cellar/symlink publication；
- dpkg-owned target；
- systemd/launchd package lifecycle；
- container image更新。

Standalone publisher遇到symlink或不属于本合同的target时fail closed，并指向对应package manager命令。

---

## 16. TDD实施任务

每个Task是一个可独立验收的纵切面；先写红测，再实现最小代码。

### Task 0 — 冻结行为合同

- [ ] Status relation/restart_required真值表；
- [ ] Installer text/JSON snapshots；
- [ ] Error codes与next-step文案；
- [ ] 明确cold restart connection interruption；
- [ ] 记录status hashing与publication baseline。

**Acceptance：** 文档和BDD不使用hot/graceful/seamless描述本方案。

### Task 1 — ArtifactIdentity与RuntimeDescriptor v3

- [ ] Known-vector及streaming SHA-256 tests；
- [ ] Fixed parent-dir FD上的absent/regular/no-follow/ownership/mode tests；
- [ ] Linux/macOS actual process-executable observation contract tests；
- [ ] schema v3 required management/binary fields；
- [ ] canonical digest/path validation；
- [ ] provisional→ready/generation/CAS binary preservation；
- [ ] v2/corrupt/contract mismatch fail-closed tests。

**Acceptance：** Running identity在ready前冻结，此后不从可变target反推。

### Task 2 — Stopped publication纵切面

- [ ] Stable authority marker + shared/exclusive `BinaryTargetGuard`；
- [ ] Same-directory stage、`*at` operations、file sync、atomic rename、readback、parent sync；
- [ ] Fresh absent→A、A→B、B→B；
- [ ] Rename-local fact、target_after、precommit fault与postcommit sync-uncertain；
- [ ] Symlink/special/path race拒绝；
- [ ] SIGTERM/SIGKILL stale-stage recovery。

**Acceptance：** Stopped install不启动daemon；target永远是完整old/new。

### Task 3 — Running publication纵切面

- [ ] Authentic RuntimeDescriptor/PID+nonce preflight；
- [ ] Exact target与binary contract检查；
- [ ] A运行时发布B；
- [ ] A运行时B→C；
- [ ] Start/stop/restart/private child共用guard且无nested reacquire；
- [ ] Foreground/supervisor/external-management result；
- [ ] Legacy/corrupt/foreign target在rename前拒绝。

**Acceptance：** Publication后old PID、nonce、listener及连接不变，new connections仍由A处理。

### Task 4 — Status、API与隐式activation gate

- [ ] Text/JSON四态输出；
- [ ] `/version`与`/status`running identity；
- [ ] Same-version/different-digest；
- [ ] Target unreadable与bounded coherent observation race→unknown/null；
- [ ] `start`不激活；
- [ ] 集中`explicit|fallback` seam覆盖reload、update auto及override set/clear；
- [ ] Explicit`--apply restart`仍可执行。

**Acceptance：** Pending binary是健康可见状态，任何隐式cold path都被阻断。

### Task 5 — Explicit activation

- [ ] Restart caller-target identity验证；
- [ ] Exclusive guard覆盖stop→child ready，并把同一open-file-description传给child；
- [ ] Invocation/config/port/override保留；
- [ ] New PID/nonce/running digest验证；
- [ ] Foreground拒绝与supervisor hint；
- [ ] `invocation_recovered`非零结果区分invocation recovery与binary rollback。

**Acceptance：** 只有显式activation改变running digest；connection interruption在tests/output中明确。

### Task 6 — 统一installer与release gate

- [ ] `install.sh`调用唯一publisher；
- [ ] local-dev与`just install`删除stop/start/backup逻辑；
- [ ] First-bootstrap UX；
- [ ] Publisher-capable known-good与pre-v3 offline rollback分别提供UX；
- [ ] Linux/macOS amd64/arm64 real-process scenarios；
- [ ] Docs、CHANGELOG、CLI/API specs同步。

**Acceptance：** 三个入口产生相同publication语义；release gate不接受shell marker代替真实binary测试。

---

## 17. 测试矩阵

### 17.1 Identity与descriptor

- Empty/small/large executable hashing；
- Uppercase、truncated、non-hex digest拒绝；
- Same version、different executable digest；
- Path NUL/relative/noncanonical/too-long拒绝；
- Descriptor每次CAS更新保留binary fields；
- PID reuse由nonce拒绝。

### 17.2 Publication faults

```text
canonical parent/authority marker/guard acquire
candidate process-executable open/read
fresh target absent observation
stage create/write/chmod
stage file sync
staged digest readback
runtime preflight
final target lstat
atomic rename syscall result
published target_after readback / external tamper
parent directory sync
publisher TERM/KILL before/after rename
```

每个fault必须断言：

- target是完整old/new；
- running PID/nonce是否改变；
- daemon是否收到signal；
- transaction-local publication fact与current target_after是否分别准确；
- 没有自动stop/start/rollback。

### 17.3 Real-process scenario

使用动态端口，禁止7899：

1. 启动real binary A；
2. 建立long HTTP CONNECT、SOCKS TCP和SOCKS5 UDP association；
3. 发布real binary B；
4. 断言PID、nonce、listener identity不变；
5. 断言existing connections继续双向传输；
6. 断言new connection的`/version`仍为A；
7. 断言status relation=different、restart_required=true；
8. 执行`zc start`，断言仍为A；
9. 显式执行`zc restart`；
10. 断言old connections关闭、PID/nonce变化、running=B、relation=same。

另覆盖：

- A运行时A→B→C；
- A运行时发布exact A取消restart requirement；
- Same SemVer但different digest；
- Foreground与external-management behavior；
- Two concurrent publishers；
- Publisher与status/start/stop/restart/private child竞争；
- Target在preflight后被non-cooperating actor替换；
- RuntimeDescriptor corrupt、v2、ready=false、PID/nonce mismatch；
- Parent sync failure、post-rename tamper与observer-only unknown；
- Legacy bootstrap遇到supervisor/legacy concurrent start时拒绝；
- Requested invocation failure后的`invocation_recovered`结果；
- Override set/clear与所有auto fallback在different/unknown时不激活。

### 17.4 Performance

先测baseline再冻结阈值：

- Executable SHA-256 latency；
- `zc status`增加binary observation后的p50/p95；
- Publication总耗时与lock hold time；
- Daemon throughput/latency在publication前后差异；
- 100轮A/B publication的FD/stage leak。

Publication不得持runtime mutation lock执行download或archive extract。

---

## 18. 总体验收标准

只有全部满足，才能发布本功能：

1. Running install不调用stop/start/reload，不向daemon发signal。
2. Publication后old PID、nonce、listener和已有连接保持不变。
3. 对所有cooperating writers，disk target通过fixed-parent same-directory atomic rename只呈现完整old/new；external tamper明确可见。
4. Artifact判等只使用executable SHA-256，不使用version string替代。
5. RuntimeDescriptor在ready前冻结running target/version/digest/contract。
6. Standalone status在shared guard下给出coherent same/different/not_running/unknown与boolean/null restart_required；external不伪造authority。
7. Same-version different-digest稳定要求restart。
8. Pending binary时`zc start`不激活，隐式restart fallback被拒绝。
9. 只有用户显式选择的cold activation（restart、stop-start、`--apply restart`或supervisor restart）改变running identity。
10. Cold activation的connection interruption在CLI、docs和E2E中可见。
11. Precommit failure保持old target；postcommit不自动binary rollback。
12. Installer分别报告transaction-local publication、current target_after与directory-sync outcome。
13. Legacy/corrupt/foreign/external target runtime在rename前fail closed。
14. First-bootstrap和future contract bump都有offline stop/install/start步骤，并拒绝legacy/supervisor并发start。
15. Standalone、package-manager与supervisor ownership边界已写入用户文档。
16. Linux/macOS四目标actual executable/guard inheritance/real-process tests通过，且没有hidden fallback。
17. Publisher-capable与pre-v3 rollback边界明确，`invocation_recovered`不冒充binary rollback。
18. 现有[优雅二进制替换方案](./hot-upgrade-plan.md)保持独立，未为未来机制预埋candidate/listener/drain抽象。

---

## 19. 预计文件变化

### 新增

```text
src/artifact_identity.zig
src/artifact_identity_test.zig
src/binary_publication.zig
src/binary_publication_test.zig
src/binary_publication_process_test.zig
```

### 主要修改

```text
src/runtime_descriptor.zig
src/daemon.zig
src/main.zig
src/api/server.zig
src/cli/commands.zig
src/cli/output.zig
src/test_runner.zig
build.zig
install.sh
scripts/install/local-dev-install.sh
scripts/install/test-oneline-installer.sh
Justfile
```

### 用户文档

```text
README.md
CHANGELOG.md
docs/install/README.md
docs/cli/spec.md
docs/cli/ux-workflow.md
docs/api/README.md
docs/api/error-codes.md
docs/reliability/e2e.md
```

---

## 20. 与未来优雅替换方案的关系

本计划解决当前最小需求：

```text
safe publication + visible mismatch + explicit cold activation
```

未来[优雅二进制替换方案](./hot-upgrade-plan.md)解决的是不同需求：

```text
candidate process + inherited listener + admission cutover + old connection drain
```

两者共享的长期概念只有：

- Exact artifact identity；
- Installed与running事实分离；
- 明确的pre/post publication结果；
- 不隐藏fallback；
- 可观察的operator action。

本次不提前实现future方案的VersionStore、selected symlink、candidate、listener handoff、RuntimeRecord或drain registry。
未来真正实施优雅替换时，应按其计划执行一次明确cold bootstrap并替换activation路径，而不是在本计划上叠加兼容层。
