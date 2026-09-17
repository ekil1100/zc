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

原测试让 500 次发布连续冲击 5000 次读取，却要求每次读取成功，超出了有界重试的保证。现在用零容量 channel 每批释放一次 publication，再执行十次读取；下一次 publication 须等待上一批读取结束，读写仍可重叠。保留全部 500 次写、5000 次成功断言及静态 hardlink 拒绝，并加强为完整 descriptor 相等与最终稳定读取检查。不将任何读取错误当作通过。

该调度不保证 rename 恰好命中 metadata 捕获窗口；确定性交错由上面的真实文件注入测试负责。生产读取重试和身份校验未因调整测试而放宽。
