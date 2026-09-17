# 文件捕获的 metadata 检查窗口

## 结论与边界

`src/fsutil.rs` 的有界读取必须验证**实际 capture 的 before metadata**，不能只依赖较早的 checked-open。打开时合法、读取前已 unlink/hardlink 或放宽权限的文件，即使读取期间 metadata 稳定，也必须拒绝。

修复复用普通文件、当前 euid、单链接校验；private state 禁止 `mode & 077`，cache 禁止 `mode & 022`，普通 source 不新增 private/cache 权限限制。读取后的 ctime、nlink、uid、mode、长度与 mtime 比较继续保留。复用本来就有的 metadata 采样，不额外增加 stat；不增加重试、不跳过完整性检查、不删除重建数据。

这不是任意文件系统并发的完整安全证明：检查完成后的修改仍可能发生；不承诺 ACL 检查或无限并发发布下的读取成功。

## 确定性红绿回归

`tests/fsutil.rs::read_capture` 只通过公开 `SecureDir::read/read_with_metadata/read_cache`、`read_regular/read_contained` 调用，在隔离临时目录中测试。

测试专用 `tests/support/read_capture_race.c` 在真实 metadata 系统接口返回前，保留其合法快照并对指定设备/inode 实施实际 unlink、hardlink 或 chmod；后续 metadata 与 read 不伪造。明确的注入 marker 必须出现，不命中平台 hook 不得算通过。同 API 的另一个 control inode 不受影响；0644 source 必须仍可读。

- unlink、hardlink 各覆盖五个公开读取入口；private 权限覆盖两个入口；cache group-write 覆盖一个入口，共 13 个非法交错场景。
- macOS arm64：原实现四个测试组均 RED；修复后全部 GREEN。
- shim 仅在测试临时目录编译和注入，需要 `cc` 与动态装载支持，不进入生产构建或发行包；没有 unsafe Rust 或新依赖。其他平台必须以实际 CI 运行确认，不能以编译通过代替。

```bash
cargo test --locked --test fsutil read_capture:: -- --nocapture --test-threads=1
```

原始 RED 与重复探针记录位于 `target/ci/35171024849/read-capture-*.log`；修复后 fsutil/store/legacy/durability/daemon/provider/service/managed CLI 九个相关集成 suite 通过，日志 `/tmp/zc-capture-regression.log`。这些结果不代替全量 E2E、性能或长稳验收。

## descriptor 并发测试的调度

[CI 35171024849](https://github.com/ekil1100/zc/actions/runs/35171024849) 的 Linux x64 记录了 descriptor capture 的 metadata 不稳定。`read_descriptor` 最多首次读取加三次重试，且当前路径复检失败也会立即拒绝；日志不能证明一定耗尽全部重试。

原测试让 500 次发布连续冲击 5000 次读取，却要求每次读取成功，超出了有界重试的保证。历史修正曾用零容量 channel 每批释放一次 publication，但 [CI 35231178121](https://github.com/ekil1100/zc/actions/runs/35231178121) 的 Linux x64 仍捕获 metadata 拒绝；**一次 publication 也不保证当前路径复检一定成功**。

Linux v6.8 的 ext4 rename 先减少旧目标 inode 的链接数，文件系统回调返回后 VFS 才 `d_move`；缓存命中的只读 open 可以看到旧 inode。因而 capture 已发现变化、guard 仍看到 `nlink=0` 是合法交错，不必耗尽重试。这是内核源码反例，不冒充本次 CI 的精确 trace。原日志及来源保存在 `target/ci/35231178121/descriptor-capture-diagnosis.md`。

**另一个尚未定位的公开接口失败**：[CI 35247844266 / `d22abd6`](https://github.com/ekil1100/zc/actions/runs/35247844266) 的 Intel `tests/cli_managed.rs::all_http_provider_wire_bytes_are_frozen_before_any_listener_opens` 在 `restart --json` 返回 `RESTART_FAILED: unsafe file ownership or hard links`。原始日志：`target/ci/35247844266/intel.log:999–1004`。没有对应 inode/UID/nlink trace，不能认定它就是同一 publication 窗口，也不能把错误当成成功、增加重试或放松完整性检查；公开 CLI 回归仍保持原断言。该问题与 UDP/TrustSettings 分开追踪。

当前 fixture 在真实 capture-before syscall 已取得合法快照后暂停，通知独立 writer 完成真实 `SecureDir::atomic_write` 并确认 durability receipt，再恢复读取。syscall 返回值不修改；旧句柄确实变成 `nlink=0`，现有 production retry 必须取得新的完整 descriptor。每轮递增合法 pid，使误接受旧字节也会失败。

保留 **500 次有 marker 证明的 capture/rename 重叠、5000 次顶层成功相等断言**、最终稳定读取和硬链接拒绝。错 inode 漏钩与畸形控制记录均须失败；marker 读取错误不得当成空记录通过。负向拒绝仍由前面的真实文件注入用例覆盖，不计入成功读次数。只改变测试调度与 fixture，没有增加生产重试、改变身份/metadata 检查或删掉并发窗口。
