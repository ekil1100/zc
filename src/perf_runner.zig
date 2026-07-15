const std = @import("std");
const builtin = @import("builtin");
const compat = @import("compat.zig");
const perf_stats = @import("perf_stats.zig");
const state_authority = @import("state_authority.zig");

const Options = struct {
    samples: usize = 9,
    iterations: u64 = 200,
    fixture_bytes: usize = 64 * 1024,
    subject_commit: []const u8 = "unknown",
    harness_commit: []const u8 = "unknown",
    machine: []const u8 = "unknown",
};

fn parseArgs(args: []const []const u8) !Options {
    var options: Options = .{};
    var seen_samples = false;
    var seen_iterations = false;
    var seen_fixture = false;
    var seen_subject = false;
    var seen_harness = false;
    var seen_machine = false;

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
        } else if (std.mem.eql(u8, arg, "--machine")) {
            if (seen_machine or i + 1 >= args.len) return error.InvalidArgument;
            seen_machine = true;
            i += 1;
            options.machine = args[i];
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

const ReadMode = enum { legacy, strict };

fn measureBoundedRead(allocator: std.mem.Allocator, path: []const u8, options: Options, mode: ReadMode) ![]perf_stats.Sample {
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
            const bytes = switch (mode) {
                .legacy => try compat.fileReadToEndAlloc(file, allocator, options.fixture_bytes),
                .strict => try compat.fileReadBoundedAlloc(file, allocator, options.fixture_bytes),
            };
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

fn revisionFromCounter(value: u128) state_authority.Revision {
    return .{ .bytes = @bitCast(value) };
}

fn measureAuthorityCommits(
    allocator: std.mem.Allocator,
    options: Options,
    profile_count: usize,
) ![]perf_stats.Sample {
    const dir_path = try std.fmt.allocPrint(allocator, ".zig-cache/perf/authority-{d}-{d}", .{ profile_count, compat.nanoTimestamp() });
    defer allocator.free(dir_path);
    defer std.Io.Dir.cwd().deleteTree(compat.io(), dir_path) catch {};
    const dir = try std.Io.Dir.cwd().createDirPathOpen(compat.io(), dir_path, .{});
    defer dir.close(compat.io());
    const authority = state_authority.Authority.init(allocator, dir);

    var counter: u128 = 1;
    var target_head: state_authority.Revision = undefined;
    var profile_index: usize = 0;
    while (profile_index < profile_count) : (profile_index += 1) {
        var key_buffer: [32]u8 = undefined;
        const key = if (profile_index == 0)
            "target"
        else
            try std.fmt.bufPrint(&key_buffer, "profile-{d}", .{profile_index});
        const revision = revisionFromCounter(counter);
        counter += 1;
        const outcome = try authority.commit(.{ .compare_exchange_head = .{
            .key = key,
            .expected = .missing,
            .next = revision,
        } });
        if (outcome != .committed) return error.UnexpectedCommitOutcome;
        if (profile_index == 0) target_head = revision;
    }

    const samples = try allocator.alloc(perf_stats.Sample, options.samples);
    errdefer allocator.free(samples);
    var sample_index: usize = 0;
    while (sample_index <= options.samples) : (sample_index += 1) {
        const started = std.Io.Timestamp.now(compat.io(), .awake).nanoseconds;
        var iteration: u64 = 0;
        while (iteration < options.iterations) : (iteration += 1) {
            const next = revisionFromCounter(counter);
            counter += 1;
            const outcome = try authority.commit(.{ .compare_exchange_head = .{
                .key = "target",
                .expected = .{ .revision = target_head },
                .next = next,
            } });
            switch (outcome) {
                .committed => target_head = next,
                else => return error.UnexpectedCommitOutcome,
            }
        }
        const finished = std.Io.Timestamp.now(compat.io(), .awake).nanoseconds;
        if (sample_index == 0) continue;
        const elapsed: u64 = @intCast(finished - started);
        samples[sample_index - 1] = .{
            .iterations = options.iterations,
            .elapsed_ns = elapsed,
            .ns_per_op = elapsed / options.iterations,
        };
    }

    var reopened = try authority.observe();
    defer reopened.deinit();
    if (reopened.profiles.count() != profile_count) return error.ProfileCountMismatch;
    if (!reopened.head("target").?.eql(target_head)) return error.HeadMismatch;
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

    const legacy_samples = try measureBoundedRead(allocator, fixture_path, options, .legacy);
    defer allocator.free(legacy_samples);
    const strict_samples = try measureBoundedRead(allocator, fixture_path, options, .strict);
    defer allocator.free(strict_samples);
    const authority_1_samples = try measureAuthorityCommits(allocator, options, 1);
    defer allocator.free(authority_1_samples);
    const authority_100_samples = try measureAuthorityCommits(allocator, options, 100);
    defer allocator.free(authority_100_samples);
    const authority_1000_samples = try measureAuthorityCommits(allocator, options, 1000);
    defer allocator.free(authority_1000_samples);

    const legacy_summary = try perf_stats.summarize(allocator, legacy_samples);
    const strict_summary = try perf_stats.summarize(allocator, strict_samples);
    const authority_1_summary = try perf_stats.summarize(allocator, authority_1_samples);
    const authority_100_summary = try perf_stats.summarize(allocator, authority_100_samples);
    const authority_1000_summary = try perf_stats.summarize(allocator, authority_1000_samples);

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
        cpu_model: []const u8,
        zig_version: []const u8,
        machine: []const u8,
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

    const benchmarks = [_]Benchmark{
        .{
            .name = "legacy_bounded_read",
            .samples = legacy_samples,
            .median_ns_per_op = legacy_summary.median_ns_per_op,
            .p95_ns_per_op = legacy_summary.p95_ns_per_op,
        },
        .{
            .name = "strict_bounded_read",
            .samples = strict_samples,
            .median_ns_per_op = strict_summary.median_ns_per_op,
            .p95_ns_per_op = strict_summary.p95_ns_per_op,
        },
        .{
            .name = "authority_commit_profiles_1",
            .samples = authority_1_samples,
            .median_ns_per_op = authority_1_summary.median_ns_per_op,
            .p95_ns_per_op = authority_1_summary.p95_ns_per_op,
        },
        .{
            .name = "authority_commit_profiles_100",
            .samples = authority_100_samples,
            .median_ns_per_op = authority_100_summary.median_ns_per_op,
            .p95_ns_per_op = authority_100_summary.p95_ns_per_op,
        },
        .{
            .name = "authority_commit_profiles_1000",
            .samples = authority_1000_samples,
            .median_ns_per_op = authority_1000_summary.median_ns_per_op,
            .p95_ns_per_op = authority_1000_summary.p95_ns_per_op,
        },
    };
    const omitted = [_][]const u8{
        "connection_admission",
        "connection_throughput",
        "connection_latency_p99",
        "active_flow_rss",
        "config_import",
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
            .cpu_model = builtin.cpu.model.name,
            .zig_version = builtin.zig_version_string,
            .machine = options.machine,
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
        "--machine",
        "ci-runner-1",
    };
    const options = try parseArgs(&args);
    try std.testing.expectEqual(@as(usize, 7), options.samples);
    try std.testing.expectEqual(@as(u64, 12), options.iterations);
    try std.testing.expectEqual(@as(usize, 4096), options.fixture_bytes);
    try std.testing.expectEqualStrings("abc123", options.subject_commit);
    try std.testing.expectEqualStrings("def456", options.harness_commit);
    try std.testing.expectEqualStrings("ci-runner-1", options.machine);
}

test "perf runner rejects fewer than five samples and unknown arguments" {
    const too_few = [_][]const u8{ "zc-perf", "--samples", "4" };
    try std.testing.expectError(error.NotEnoughSamples, parseArgs(&too_few));

    const unknown = [_][]const u8{ "zc-perf", "--fake" };
    try std.testing.expectError(error.InvalidArgument, parseArgs(&unknown));
}
