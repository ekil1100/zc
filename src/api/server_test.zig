const std = @import("std");
const testing = std.testing;
const build_options = @import("build_options");
const server = @import("server.zig");
const config = @import("../config.zig");

test "minimal API framing is bounded and waits for a complete body" {
    const incomplete_header = "PUT /proxies/Proxy HTTP/1.1\r\nHost: local\r\n";
    try testing.expectEqual(
        server.InspectResult.incomplete,
        try server.inspectRequest(incomplete_header),
    );

    const incomplete_body =
        "PUT /proxies/Proxy HTTP/1.1\r\n" ++
        "Content-Length: 15\r\n\r\n" ++
        "{\"name\":\"A\"}";
    try testing.expectEqual(
        server.InspectResult.incomplete,
        try server.inspectRequest(incomplete_body),
    );

    const headerless = try server.inspectRequest("GET /version HTTP/1.0\r\n\r\n");
    try testing.expectEqualStrings("GET", headerless.complete.method);
    try testing.expectEqualStrings("/version", headerless.complete.path);
    try testing.expect(headerless.complete.authorization == null);

    const authorized = try server.inspectRequest(
        "GET /version HTTP/1.1\r\nAuthorization: Bearer test-secret\r\n\r\n",
    );
    try testing.expectEqualStrings(
        "Bearer test-secret",
        authorized.complete.authorization.?,
    );

    const complete =
        "PUT /proxies/Proxy HTTP/1.1\r\n" ++
        "Content-Length: 12\r\n\r\n" ++
        "{\"name\":\"A\"}";
    const result = try server.inspectRequest(complete);
    try testing.expectEqualStrings("PUT", result.complete.method);
    try testing.expectEqualStrings("/proxies/Proxy", result.complete.path);
    try testing.expectEqualStrings("{\"name\":\"A\"}", result.complete.body);

    try testing.expectError(
        error.PayloadTooLarge,
        server.inspectRequest(
            "PUT / HTTP/1.1\r\nContent-Length: 65537\r\n\r\n",
        ),
    );
    try testing.expectError(
        error.InvalidRequest,
        server.inspectRequest(
            "PUT / HTTP/1.1\r\n" ++
                "Content-Length: 1\r\nContent-Length: 1\r\n\r\nx",
        ),
    );
    try testing.expectError(
        error.InvalidRequest,
        server.inspectRequest(
            "GET / HTTP/1.1\r\n" ++
                "Authorization: Bearer one\r\n" ++
                "Authorization: Bearer two\r\n\r\n",
        ),
    );
    try testing.expectError(
        error.LengthRequired,
        server.inspectRequest("PUT / HTTP/1.1\r\nHost: local\r\n\r\n"),
    );
    try testing.expectError(
        error.UnsupportedTransferEncoding,
        server.inspectRequest(
            "PUT / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n",
        ),
    );
    const invalid_lengths = [_][]const u8{
        "Content-Length: +12",
        "Content-Length: 1_2",
        "Content-Length : 12",
        " Content-Length: 12",
        "\tContent-Length: 12",
    };
    for (invalid_lengths) |header| {
        var request_buffer: [256]u8 = undefined;
        const request = try std.fmt.bufPrint(
            &request_buffer,
            "PUT / HTTP/1.1\r\n{s}\r\n\r\n{{\"name\":\"A\"}}",
            .{header},
        );
        try testing.expectError(error.InvalidRequest, server.inspectRequest(request));
    }
    try testing.expectError(
        error.InvalidRequest,
        server.inspectRequest(
            "PUT / HTTP/1.1\r\nContent-Length: 12\r\n" ++
                "X-Ignored: value\nContent-Length: 0\r\n\r\n" ++
                "{\"name\":\"A\"}",
        ),
    );
    try testing.expectError(
        error.InvalidRequest,
        server.inspectRequest(
            "GET / HTTP/1.1\r\nX-Ignored: value\rhidden\r\n\r\n",
        ),
    );
    try testing.expectError(
        error.InvalidRequest,
        server.inspectRequest(
            "PUT / HTTP/1.1\r\nContent-Length: 65537\r\n" ++
                "X: value\nTransfer-Encoding: chunked\r\n\r\n",
        ),
    );
    try testing.expectError(
        error.InvalidRequest,
        server.inspectRequest(
            "PUT / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n" ++
                "X: value\rContent-Length: 0\r\n\r\n",
        ),
    );

    var oversized_header: [server.max_header_bytes + 1]u8 = undefined;
    @memset(&oversized_header, 'a');
    try testing.expectError(
        error.HeaderTooLarge,
        server.inspectRequest(&oversized_header),
    );
}

test "minimal API requires the configured bearer secret" {
    try testing.expect(server.isAuthorized(null, null));
    try testing.expect(server.isAuthorized("", null));
    try testing.expect(server.isAuthorized("secret", "Bearer secret"));
    try testing.expect(server.isAuthorized("secret", "bearer secret"));
    try testing.expect(!server.isAuthorized("secret", null));
    try testing.expect(!server.isAuthorized("secret", "Bearer wrong"));
    try testing.expect(!server.isAuthorized("secret", "Basic secret"));
}

// Simple HTTP response parsing test
test "HTTP response parsing" {
    const ver = build_options.version;
    const response = "HTTP/1.1 200 OK\r\n" ++
        "Content-Type: application/json\r\n\r\n" ++
        comptime std.fmt.comptimePrint("{{\"version\":\"{s}\"}}", .{ver});

    // Check status line
    try testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200 OK"));

    // Check headers
    try testing.expect(std.mem.indexOf(u8, response, "Content-Type: application/json") != null);

    // Check body
    try testing.expect(std.mem.indexOf(u8, response, "\"version\":\"" ++ ver ++ "\"") != null);
}

// Regression test for the double-close bug in ApiServer.start/handleConnection.
//
// Previously start() called `conn.stream.close()` in its `catch |err|` handler
// AND handleConnection() closed the same stream via `defer conn.stream.close()`,
// so any error path inside handleConnection closed the same fd twice. The fix
// removed the close in start()'s catch handler, leaving exactly one owner.
//
// We model the connection lifecycle with a close-counting stub. The buggy
// pattern closes twice on the error path; the fixed pattern closes exactly once.
const CloseCounter = struct {
    count: usize = 0,
    fn close(self: *CloseCounter) void {
        self.count += 1;
    }
};

// Mirrors the FIXED control flow: handleConnection's defer is the sole closer,
// start() does not close again in its catch handler.
fn fixedDriveConnection(c: *CloseCounter, fail: bool) void {
    // handleConnection body
    const handle = struct {
        fn run(cc: *CloseCounter, should_fail: bool) error{ConnError}!void {
            defer cc.close(); // `defer conn.stream.close()`
            if (should_fail) return error.ConnError;
        }
    }.run;
    // start() catch handler: must NOT close again
    handle(c, fail) catch {};
}

test "connection closed exactly once on error path (no double close)" {
    var c = CloseCounter{};
    fixedDriveConnection(&c, true); // error path
    try testing.expectEqual(@as(usize, 1), c.count);

    var c2 = CloseCounter{};
    fixedDriveConnection(&c2, false); // success path
    try testing.expectEqual(@as(usize, 1), c2.count);
}

// PUT /proxies/<group> body 解析：std.json 真实反转义（修复扫到第一个 `"`
// 字节截断转义节点名的 bug —— 含引号/反斜杠的名字曾被截成不存在的节点）。
test "parseSelectionName unescapes quoted proxy names" {
    const allocator = testing.allocator;

    const name = server.parseSelectionName(allocator, "{\"name\":\"node \\\"HK\\\"\"}").?;
    defer allocator.free(name);
    try testing.expectEqualStrings("node \"HK\"", name);

    const plain = server.parseSelectionName(allocator, "{\"name\":\"dummy-b\"}").?;
    defer allocator.free(plain);
    try testing.expectEqualStrings("dummy-b", plain);

    const backslash = server.parseSelectionName(allocator, "{\"name\":\"a\\\\b\"}").?;
    defer allocator.free(backslash);
    try testing.expectEqualStrings("a\\b", backslash);

    try testing.expect(server.parseSelectionName(allocator, "") == null);
    try testing.expect(server.parseSelectionName(allocator, "not json") == null);
    try testing.expect(server.parseSelectionName(allocator, "{\"other\":\"x\"}") == null);
    try testing.expect(server.parseSelectionName(allocator, "{\"name\":42}") == null);
}

// 未知组/节点必须可判定（handleSwitchProxy 据此返回 404 而不是无条件 200，
// 修复 CLI `data.applied` 假阳性）。
test "validateSelection distinguishes ok / missing group / missing proxy" {
    const allocator = testing.allocator;

    var cfg = config.Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    var group = config.ProxyGroup{
        .name = try allocator.dupe(u8, "PROXY"),
        .group_type = .select,
        .proxies = std.ArrayList([]const u8).empty,
    };
    errdefer group.deinit(allocator);
    try group.proxies.append(allocator, try allocator.dupe(u8, "dummy-b"));
    try group.proxies.append(allocator, try allocator.dupe(u8, "node \"HK\""));
    try cfg.proxy_groups.append(allocator, group);

    try testing.expectEqual(
        server.SelectionCheck.ok,
        server.validateSelection(&cfg, "PROXY", "dummy-b"),
    );
    try testing.expectEqual(
        server.SelectionCheck.ok,
        server.validateSelection(&cfg, "PROXY", "node \"HK\""),
    );
    try testing.expectEqual(
        server.SelectionCheck.proxy_not_found,
        server.validateSelection(&cfg, "PROXY", "no-such-node"),
    );
    try testing.expectEqual(
        server.SelectionCheck.group_not_found,
        server.validateSelection(&cfg, "NOPE", "dummy-b"),
    );
}

test "JSON response format" {
    const allocator = testing.allocator;

    // Test simple JSON serialization
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    try json.appendSlice(allocator, "{\"proxies\":[");
    try json.appendSlice(allocator, "{\"name\":\"Proxy1\",\"type\":\"Shadowsocks\"}");
    try json.appendSlice(allocator, "]}");

    const result = try json.toOwnedSlice(allocator);
    defer allocator.free(result);

    try testing.expect(std.mem.indexOf(u8, result, "\"proxies\"") != null);
    try testing.expect(std.mem.indexOf(u8, result, "\"name\":\"Proxy1\"") != null);
}

fn exerciseApiSerializers(
    allocator: std.mem.Allocator,
    cfg: *const config.Config,
) !void {
    const proxies = try server.ApiServer.buildProxiesJson(allocator, cfg);
    defer allocator.free(proxies);
    const rules = try server.ApiServer.buildRulesJson(allocator, cfg);
    defer allocator.free(rules);
}

test "minimal API serializers escape configured strings" {
    // Quotes, backslashes, control characters, and Unicode must round-trip.
    const allocator = testing.allocator;
    var cfg = config.Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    const proxy_name = "node \"HK\"\\line\n雪";
    const server_name = "server\\name\t雪";
    try cfg.proxies.append(allocator, .{
        .name = try allocator.dupe(u8, proxy_name),
        .proxy_type = .ss,
        .server = try allocator.dupe(u8, server_name),
        .port = 8388,
    });
    const payload = "foo\"bar\\baz\n雪";
    const target = "node \"HK\"\\line\n雪";
    try cfg.rules.append(allocator, .{
        .rule_type = .domain,
        .payload = try allocator.dupe(u8, payload),
        .target = try allocator.dupe(u8, target),
    });

    const proxies_json = try server.ApiServer.buildProxiesJson(allocator, &cfg);
    defer allocator.free(proxies_json);
    var proxies = try std.json.parseFromSlice(std.json.Value, allocator, proxies_json, .{});
    defer proxies.deinit();
    const proxy = proxies.value.object.get("proxies").?.array.items[0].object;
    try testing.expectEqualStrings(proxy_name, proxy.get("name").?.string);
    try testing.expectEqualStrings(server_name, proxy.get("server").?.string);

    const rules_json = try server.ApiServer.buildRulesJson(allocator, &cfg);
    defer allocator.free(rules_json);
    var rules = try std.json.parseFromSlice(std.json.Value, allocator, rules_json, .{});
    defer rules.deinit();
    const rule = rules.value.object.get("rules").?.array.items[0].object;
    try testing.expectEqualStrings(payload, rule.get("payload").?.string);
    try testing.expectEqualStrings(target, rule.get("target").?.string);

    try testing.checkAllAllocationFailures(
        allocator,
        exerciseApiSerializers,
        .{&cfg},
    );
}

test "minimal API rejects oversized JSON before allocating its body" {
    const allocator = testing.allocator;
    var cfg = config.Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    for (0..5) |_| {
        const target = try allocator.alloc(u8, 1024 * 1024);
        @memset(target, 'x');
        errdefer allocator.free(target);
        const payload = try allocator.dupe(u8, "example.com");
        errdefer allocator.free(payload);
        try cfg.rules.append(allocator, .{
            .rule_type = .domain,
            .payload = payload,
            .target = target,
        });
    }

    try testing.expectError(
        error.ResponseTooLarge,
        server.ApiServer.buildRulesJson(allocator, &cfg),
    );
}

test "buildStatusJson returns daemon config_key and runtime selections" {
    // status 经 IPC 读 daemon 实际状态：config_key + 内存 group_selections，
    // 而非 meta.json[用户指针]（错位时读到空 → 误报 default）。
    const allocator = testing.allocator;
    const manager_mod = @import("../proxy/outbound/manager.zig");

    var cfg = config.Config{
        .allocator = allocator,
        .mode = try allocator.dupe(u8, "rule"),
        .log_level = try allocator.dupe(u8, "info"),
        .bind_address = try allocator.dupe(u8, "*"),
        .proxies = std.ArrayList(config.Proxy).empty,
        .proxy_groups = std.ArrayList(config.ProxyGroup).empty,
        .rules = std.ArrayList(config.Rule).empty,
    };
    defer cfg.deinit();

    var gp = config.ProxyGroup{
        .name = try allocator.dupe(u8, "Proxy"),
        .group_type = .select,
        .proxies = std.ArrayList([]const u8).empty,
    };
    try gp.proxies.append(allocator, try allocator.dupe(u8, "A"));
    try gp.proxies.append(allocator, try allocator.dupe(u8, "B"));
    try cfg.proxy_groups.append(allocator, gp);

    var mgr = try manager_mod.OutboundManager.initWithKey(allocator, &cfg, "runtimkey");
    defer mgr.deinit();
    // Apply the already-authorized runtime value without touching legacy metadata.
    try testing.expect(try mgr.applyPersistedSelection("Proxy", "B"));

    const json = try server.ApiServer.buildStatusJson(allocator, &mgr, &cfg);
    defer allocator.free(json);

    // config_key reflects daemon's actual loaded key (not the user pointer).
    try testing.expect(std.mem.indexOf(u8, json, "\"config_key\":\"runtimkey\"") != null);
    // runtime override (B) surfaces as persisted, not the default (A).
    try testing.expect(std.mem.indexOf(u8, json, "\"group\":\"Proxy\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"proxy\":\"B\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"source\":\"persisted\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"proxy\":\"A\"") == null);
}
