const std = @import("std");
const compat = @import("compat.zig");
const override = @import("override.zig");
const config = @import("config.zig");
pub fn main(init: std.process.Init) !void {
    compat.setIo(init.io);
    compat.setEnvironMap(init.environ_map);
    const a = init.arena.allocator();
    const args = try init.minimal.args.toSlice(a);
    const source = try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], a, .limited(16 * 1024 * 1024));
    const output = if (std.mem.eql(u8, args[1], "materialize")) blk: {
        const patch = try std.Io.Dir.cwd().readFileAlloc(init.io, args[3], a, .limited(1024 * 1024));
        break :blk try override.materializeSource(a, source, patch);
    } else blk: {
        var cfg = try config.parseCatalogDocument(a, source);
        break :blk if (std.mem.eql(u8, args[1], "json")) try override.dumpConfigJson(a, &cfg) else if (std.mem.eql(u8, args[1], "public")) try override.dumpConfigYaml(a, &cfg) else try override.dumpRuntimeConfigYaml(a, &cfg);
    };
    try std.Io.File.stdout().writeStreamingAll(init.io, output);
}
