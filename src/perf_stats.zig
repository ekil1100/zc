const std = @import("std");

pub const Sample = struct {
    iterations: u64,
    elapsed_ns: u64,
    ns_per_op: u64,
};

pub const Summary = struct {
    median_ns_per_op: u64,
    p95_ns_per_op: u64,
};

pub fn summarize(allocator: std.mem.Allocator, samples: []const Sample) !Summary {
    if (samples.len < 5) return error.NotEnoughSamples;

    const values = try allocator.alloc(u64, samples.len);
    defer allocator.free(values);
    for (samples, values) |sample, *value| value.* = sample.ns_per_op;
    std.mem.sort(u64, values, {}, std.sort.asc(u64));

    const median = if (values.len % 2 == 1)
        values[values.len / 2]
    else
        values[values.len / 2 - 1] +| ((values[values.len / 2] - values[values.len / 2 - 1]) / 2);
    const p95_rank = (values.len * 95 + 99) / 100;

    return .{
        .median_ns_per_op = median,
        .p95_ns_per_op = values[p95_rank - 1],
    };
}

test "perf summary uses median and nearest-rank p95" {
    const samples = [_]Sample{
        .{ .iterations = 1, .elapsed_ns = 90, .ns_per_op = 90 },
        .{ .iterations = 1, .elapsed_ns = 10, .ns_per_op = 10 },
        .{ .iterations = 1, .elapsed_ns = 50, .ns_per_op = 50 },
        .{ .iterations = 1, .elapsed_ns = 30, .ns_per_op = 30 },
        .{ .iterations = 1, .elapsed_ns = 70, .ns_per_op = 70 },
    };

    const summary = try summarize(std.testing.allocator, &samples);
    try std.testing.expectEqual(@as(u64, 50), summary.median_ns_per_op);
    try std.testing.expectEqual(@as(u64, 90), summary.p95_ns_per_op);
}

test "perf summary requires at least five samples" {
    const samples = [_]Sample{
        .{ .iterations = 1, .elapsed_ns = 1, .ns_per_op = 1 },
    };
    try std.testing.expectError(error.NotEnoughSamples, summarize(std.testing.allocator, &samples));
}
