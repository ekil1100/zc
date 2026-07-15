const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const perf_stats = @import("perf_stats.zig");

const Options = struct {
    samples: usize = 9,
    iterations: u64 = 200,
    fixture_bytes: usize = 64 * 1024,
    subject_commit: []const u8 = "unknown",
    harness_commit: []const u8 = "unknown",
};

fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{};
    var seen_samples = false;
    var seen_iterations = false;
    var seen_fixture = false;
    var seen_subject = false;
    var seen_harness = false;

    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--samples")) {
            if (seen_samples or i + 1 >= args.len) return error.InvalidArgument;
            seen_samples = true;
            i += 1;
            options.samples = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--iterations")) {
            if (seen_iterations or i + 1 >= args.len) return error.InvalidArgument;
            seen_iterations = true;
            i += 1;
            options.iterations = std.fmt.parseInt(u64, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--fixture-bytes")) {
            if (seen_fixture or i + 1 >= args.len) return error.InvalidArgument;
            seen_fixture = true;
            i += 1;
            options.fixture_bytes = std.fmt.parseInt(usize, args[i], 10) catch return error.InvalidArgument;
        } else if (std.mem.eql(u8, arg, "--subject-commit")) {
            if (seen_subject or i + 1 >= args.len) return error.InvalidArgument;
            seen_subject = true;
            i += 1;
            options.subject_commit = args[i];
        } else if (std.mem.eql(u8, arg, "--harness-commit")) {
            if (seen_harness or i + 1 >= args.len) return error.InvalidArgument;
            seen_harness = true;
            i += 1;
            options.harness_commit = args[i];
        } else {
            return error.InvalidArgument;
        }
    }

    if (options.samples < 5) return error.NotEnoughSamples;
    if (options.iterations == 0) return error.InvalidArgument;
    if (options.fixture_bytes == 0 or options.fixture_bytes > 16 * 1024 * 1024) return error.InvalidArgument;
    return options;
}

fn collectArgs(allocator: std.mem.Allocator, raw_args: std.process.Args) ![]const []const u8 {
    var it = try std.process.Args.Iterator.initAllocator(raw_args, allocator);
    defer it.deinit();

    var args = std.ArrayList([]const u8).empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    while (it.next()) |arg| try args.append(allocator, try allocator.dupe(u8, arg));
    return args.toOwnedSlice(allocator);
}

fn freeArgs(allocator: std.mem.Allocator, args: []const []const u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

fn writeFixture(path: []const u8, size: usize) !void {
    const file = try std.Io.Dir.cwd().createFile(compat.io(), path, .{});
    defer file.close(compat.io());

    var block: [4096]u8 = undefined;
    for (&block, 0..) |*byte, index| byte.* = @intCast(index % 251);
    var remaining = size;
    while (remaining > 0) {
        const n = @min(remaining, block.len);
        try compat.fileWriteAll(file, block[0..n]);
        remaining -= n;
    }
    try file.sync(compat.io());
}

fn measureLegacyBoundedRead(allocator: std.mem.Allocator, path: []const u8, options: Options) ![]perf_stats.Sample {
    const samples = try allocator.alloc(perf_stats.Sample, options.samples);
    errdefer allocator.free(samples);

    var sample_index: usize = 0;
    while (sample_index <= options.samples) : (sample_index += 1) {
        const started = std.Io.Timestamp.now(compat.io(), .awake).nanoseconds;
        var checksum: usize = 0;
        var iteration: u64 = 0;
        while (iteration < options.iterations) : (iteration += 1) {
            const file = try compat.fs.cwd().openFile(path, .{});
            defer file.close(compat.io());
            const bytes = try compat.fileReadToEndAlloc(file, allocator, options.fixture_bytes);
            defer allocator.free(bytes);
            if (bytes.len != options.fixture_bytes) return error.ShortRead;
            checksum +%= bytes[0];
            checksum +%= bytes[bytes.len - 1];
        }
        std.mem.doNotOptimizeAway(checksum);
        const finished = std.Io.Timestamp.now(compat.io(), .awake).nanoseconds;
        if (sample_index == 0) continue; // warmup

        const elapsed: u64 = @intCast(finished - started);
        samples[sample_index - 1] = .{
            .iterations = options.iterations,
            .elapsed_ns = elapsed,
            .ns_per_op = elapsed / options.iterations,
        };
    }
    return samples;
}

pub fn main(init: std.process.Init) !void {
    compat.setIo(init.io);
    compat.setEnvironMap(init.environ_map);
    if (builtin.mode != .ReleaseFast) return error.ReleaseFastRequired;

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = try collectArgs(allocator, init.minimal.args);
    defer freeArgs(allocator, args);
    const options = try parseArgs(args);

    try compat.fs.cwd().makePath(".zig-cache/perf");
    const fixture_path = try std.fmt.allocPrint(allocator, ".zig-cache/perf/legacy-read-{d}.bin", .{compat.nanoTimestamp()});
    defer allocator.free(fixture_path);
    defer std.Io.Dir.cwd().deleteFile(compat.io(), fixture_path) catch {};
    try writeFixture(fixture_path, options.fixture_bytes);

    const samples = try measureLegacyBoundedRead(allocator, fixture_path, options);
    defer allocator.free(samples);
    const summary = try perf_stats.summarize(allocator, samples);

    const Benchmark = struct {
        name: []const u8,
        samples: []const perf_stats.Sample,
        median_ns_per_op: u64,
        p95_ns_per_op: u64,
    };
    const Provenance = struct {
        subject_commit: []const u8,
        harness_commit: []const u8,
        optimize: []const u8,
        os: []const u8,
        arch: []const u8,
    };
    const Method = struct {
        warmup_runs: u8,
        sample_count: usize,
        iterations_per_sample: u64,
        fixture_bytes: usize,
    };
    const Report = struct {
        schema_version: u8,
        kind: []const u8,
        status: []const u8,
        provenance: Provenance,
        method: Method,
        benchmarks: []const Benchmark,
        checks: struct { fixture_bytes_match: bool },
        omitted: []const []const u8,
    };

    const benchmarks = [_]Benchmark{.{
        .name = "legacy_bounded_read",
        .samples = samples,
        .median_ns_per_op = summary.median_ns_per_op,
        .p95_ns_per_op = summary.p95_ns_per_op,
    }};
    const omitted = [_][]const u8{
        "connection_admission",
        "connection_throughput",
        "connection_latency_p99",
        "active_flow_rss",
        "config_import",
        "authority_commit",
    };
    const report: Report = .{
        .schema_version = 1,
        .kind = "measurement",
        .status = "measured",
        .provenance = .{
            .subject_commit = options.subject_commit,
            .harness_commit = options.harness_commit,
            .optimize = @tagName(builtin.mode),
            .os = @tagName(builtin.os.tag),
            .arch = @tagName(builtin.cpu.arch),
        },
        .method = .{
            .warmup_runs = 1,
            .sample_count = options.samples,
            .iterations_per_sample = options.iterations,
            .fixture_bytes = options.fixture_bytes,
        },
        .benchmarks = &benchmarks,
        .checks = .{ .fixture_bytes_match = true },
        .omitted = &omitted,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(compat.io(), &stdout_buffer);
    try std.json.Stringify.value(report, .{}, &stdout_writer.interface);
    try stdout_writer.interface.writeByte('\n');
    try stdout_writer.interface.flush();
}

test "perf runner parses an explicit truthful measurement contract" {
    const args = [_][]const u8{
        "zc-perf",
        "--samples",
        "7",
        "--iterations",
        "12",
        "--fixture-bytes",
        "4096",
        "--subject-commit",
        "abc123",
        "--harness-commit",
        "def456",
    };
    const options = try parseArgs(&args);
    try std.testing.expectEqual(@as(usize, 7), options.samples);
    try std.testing.expectEqual(@as(u64, 12), options.iterations);
    try std.testing.expectEqual(@as(usize, 4096), options.fixture_bytes);
    try std.testing.expectEqualStrings("abc123", options.subject_commit);
    try std.testing.expectEqualStrings("def456", options.harness_commit);
}

test "perf runner rejects fewer than five samples and unknown arguments" {
    const too_few = [_][]const u8{ "zc-perf", "--samples", "4" };
    try std.testing.expectError(error.NotEnoughSamples, parseArgs(&too_few));

    const unknown = [_][]const u8{ "zc-perf", "--fake" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&unknown));
}
