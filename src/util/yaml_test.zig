const std = @import("std");
const testing = std.testing;
const yaml = @import("yaml.zig");

test "YAML parse string" {
    const allocator = testing.allocator;

    const content = "hello: world";
    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    try testing.expect(doc == .map);
    try testing.expect(doc.map.contains("hello"));

    const value = doc.map.get("hello").?;
    try testing.expect(value == .string);
    try testing.expectEqualStrings("world", value.string);
}

test "YAML parse integer" {
    const allocator = testing.allocator;

    const content = "port: 7890";
    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    const value = doc.map.get("port").?;
    try testing.expect(value == .integer);
    try testing.expectEqual(@as(i64, 7890), value.integer);
}

test "YAML parse boolean" {
    const allocator = testing.allocator;

    const content = "enable: true\ndisable: false";
    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    const enable = doc.map.get("enable").?;
    try testing.expect(enable == .boolean);
    try testing.expect(enable.boolean);

    const disable = doc.map.get("disable").?;
    try testing.expect(!disable.boolean);
}

test "YAML parse array" {
    const allocator = testing.allocator;

    const content =
        \\- item1
        \\- item2
        \\- item3
    ;

    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    try testing.expect(doc == .array);
    try testing.expectEqual(@as(usize, 3), doc.array.items.len);
    try testing.expectEqualStrings("item1", doc.array.items[0].string);
}

test "YAML duplicate key does not leak" {
    // testing.allocator fails the test if any allocation leaks.
    // The earlier key string and value must be freed when overwritten.
    const allocator = testing.allocator;

    const content =
        \\port: 7890
        \\port: 1080
        \\name: first-name
        \\name: second-name
    ;

    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    // Last value wins.
    try testing.expectEqual(@as(i64, 1080), doc.map.get("port").?.integer);
    try testing.expectEqualStrings("second-name", doc.map.get("name").?.string);
}

test "YAML duplicate key with nested map value does not leak" {
    // The previously stored value may itself own nested allocations
    // (string/array/map) that must be released on overwrite.
    const allocator = testing.allocator;

    const content =
        \\dup:
        \\  host: localhost
        \\  tags:
        \\    - a
        \\    - b
        \\dup:
        \\  host: remote
    ;

    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    const dup = doc.map.get("dup").?;
    try testing.expect(dup == .map);
    try testing.expectEqualStrings("remote", dup.map.get("host").?.string);
}

test "YAML empty key does not leak" {
    // A line beginning with ':' yields a zero-length key; the duped empty
    // string must be freed on the break path rather than leaked.
    const allocator = testing.allocator;

    const content =
        \\name: value
        \\: orphan
    ;

    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    try testing.expectEqualStrings("value", doc.map.get("name").?.string);
}

test "YAML strict document rejects duplicate and malformed content" {
    const allocator = testing.allocator;

    try testing.expectError(error.DuplicateKey, yaml.parseDocument(allocator,
        \\port: 7890
        \\port: 1080
    ));
    try testing.expectError(error.DuplicateKey, yaml.parseDocument(allocator,
        \\provider:
        \\  path: first
        \\  path: second
    ));
    try testing.expectError(error.DuplicateKey, yaml.parseDocument(allocator,
        \\"port": 7890
        \\port: 1080
    ));
    try testing.expectError(error.InvalidYamlDocument, yaml.parseDocument(allocator,
        \\port: 7890
        \\not-a-mapping
    ));
    try testing.expectError(error.InvalidYamlDocument, yaml.parseDocument(allocator,
        \\name: "unterminated
    ));
    try testing.expectError(error.InvalidYamlDocument, yaml.parseDocument(allocator,
        \\provider: {path: rules.yaml
    ));
}

test "YAML strict document distinguishes null from quoted strings" {
    const allocator = testing.allocator;
    const content =
        "\xEF\xBB\xBF" ++
        \\missing: null
        \\short: ~
        \\upper: NULL
        \\quoted: "null"
        \\quoted_bool: "true"
        \\quoted_int: '42'
        \\quoted_hash: "https://example.test/rules#v1"
        \\unicode_escape: "a\u003Ab"
        \\single_escape: 'Alice''s'
        \\quoted_escape: "say \"hi\""
        \\plain_hash: https://example.test/rules#v1
        \\apostrophe: Alice's node
        \\Alice's key: accepted
        \\empty:
        \\# trailing comment
        ;

    var doc = try yaml.parseDocument(allocator, content);
    defer doc.deinit(allocator);

    try testing.expect(doc.map.get("missing").? == .null);
    try testing.expect(doc.map.get("short").? == .null);
    try testing.expect(doc.map.get("upper").? == .null);
    try testing.expect(doc.map.get("empty").? == .null);
    try testing.expectEqualStrings("null", doc.map.get("quoted").?.string);
    try testing.expectEqualStrings("true", doc.map.get("quoted_bool").?.string);
    try testing.expectEqualStrings("42", doc.map.get("quoted_int").?.string);
    try testing.expectEqualStrings(
        "https://example.test/rules#v1",
        doc.map.get("quoted_hash").?.string,
    );
    try testing.expectEqualStrings("a:b", doc.map.get("unicode_escape").?.string);
    try testing.expectEqualStrings("Alice's", doc.map.get("single_escape").?.string);
    try testing.expectEqualStrings("say \"hi\"", doc.map.get("quoted_escape").?.string);
    try testing.expectEqualStrings(
        "https://example.test/rules#v1",
        doc.map.get("plain_hash").?.string,
    );
    try testing.expectEqualStrings("Alice's node", doc.map.get("apostrophe").?.string);
    try testing.expectEqualStrings("accepted", doc.map.get("Alice's key").?.string);
}

test "YAML strict document handles CRLF while legacy comments remain unchanged" {
    const allocator = testing.allocator;
    var strict = try yaml.parseDocument(allocator, "\r\nport: 7890\r\n\r\nname: node # comment\r\n");
    defer strict.deinit(allocator);
    try testing.expectEqual(@as(i64, 7890), strict.map.get("port").?.integer);
    try testing.expectEqualStrings("node", strict.map.get("name").?.string);

    var legacy = try yaml.parse(allocator, "name: Alice's node # comment\n");
    defer legacy.deinit(allocator);
    try testing.expectEqualStrings("Alice's node", legacy.map.get("name").?.string);
}

test "YAML strict inline maps reject duplicates and preserve scalar types" {
    const allocator = testing.allocator;
    try testing.expectError(error.DuplicateKey, yaml.parseDocument(allocator,
        \\items:
        \\  - {name: first, name: second}
    ));
    try testing.expectError(error.DuplicateKey, yaml.parseDocument(allocator,
        \\items:
        \\  - {outer: {name: first, name: second}}
    ));
    try testing.expectError(error.InvalidYamlDocument, yaml.parseDocument(allocator,
        \\items:
        \\  - {name: first} trailing-garbage
    ));
    try testing.expectError(error.InvalidYamlDocument, yaml.parseDocument(allocator,
        \\items:
        \\  - {outer: {name value}}
    ));

    var profile_doc = try yaml.parseDocument(allocator,
        \\---
        \\profile: {store-selected: true, name: "a\"b", names: [DIRECT, "Proxy, One"], missing: NULL}
        \\empty: []
        \\...
    );
    defer profile_doc.deinit(allocator);
    const profile = profile_doc.map.get("profile").?.map;
    try testing.expect(profile.get("store-selected").?.boolean);
    try testing.expectEqualStrings("a\"b", profile.get("name").?.string);
    try testing.expect(profile.get("missing").? == .null);
    try testing.expectEqualStrings("DIRECT", profile.get("names").?.array.items[0].string);
    try testing.expectEqualStrings("Proxy, One", profile.get("names").?.array.items[1].string);
    try testing.expectEqual(@as(usize, 0), profile_doc.map.get("empty").?.array.items.len);

    var root_flow = try yaml.parseDocument(allocator, "{\"a:b\": 1, mixed-port: 7890}\n");
    defer root_flow.deinit(allocator);
    try testing.expectEqual(@as(i64, 1), root_flow.map.get("a:b").?.integer);
    try testing.expectEqual(@as(i64, 7890), root_flow.map.get("mixed-port").?.integer);
    try testing.expectError(error.InvalidYamlDocument, yaml.parseDocument(
        allocator,
        "{\"junk: 1, mixed-port: 7890}\n",
    ));
    try testing.expectError(error.InvalidYamlDocument, yaml.parseDocument(
        allocator,
        "{local: {type: file, extension: one missing-comma: two}}\n",
    ));

    var spaced_sequence = try yaml.parseDocument(allocator,
        \\rules:
        \\  - DOMAIN,one.test,DIRECT
        \\# a comment between entries
        \\
        \\  - MATCH,DIRECT
    );
    defer spaced_sequence.deinit(allocator);
    try testing.expectEqual(@as(usize, 2), spaced_sequence.map.get("rules").?.array.items.len);

    var doc = try yaml.parseDocument(allocator,
        \\items:
        \\  - {missing: null, quoted: "null", enabled: "true"}
    );
    defer doc.deinit(allocator);
    const item = doc.map.get("items").?.array.items[0].map;
    try testing.expect(item.get("missing").? == .null);
    try testing.expectEqualStrings("null", item.get("quoted").?.string);
    try testing.expectEqualStrings("true", item.get("enabled").?.string);
}

test "YAML strict accepts 128 flow levels and rejects 129" {
    const allocator = testing.allocator;
    const build = struct {
        fn source(allocator_: std.mem.Allocator, depth: usize) ![]u8 {
            var bytes = std.ArrayList(u8).empty;
            errdefer bytes.deinit(allocator_);
            try bytes.appendSlice(allocator_, "root: ");
            for (0..depth) |_| try bytes.appendSlice(allocator_, "{x: ");
            try bytes.appendSlice(allocator_, "value");
            for (0..depth) |_| try bytes.append(allocator_, '}');
            try bytes.append(allocator_, '\n');
            return bytes.toOwnedSlice(allocator_);
        }
    }.source;

    const accepted_source = try build(allocator, 128);
    defer allocator.free(accepted_source);
    var accepted = try yaml.parseDocument(allocator, accepted_source);
    accepted.deinit(allocator);

    const rejected_source = try build(allocator, 129);
    defer allocator.free(rejected_source);
    try testing.expectError(
        error.YamlNestingTooDeep,
        yaml.parseDocument(allocator, rejected_source),
    );
}

test "YAML strict rejects over-indented sequence items and excessive nesting" {
    const allocator = testing.allocator;
    try testing.expectError(error.InvalidYamlDocument, yaml.parseDocument(allocator,
        \\rules:
        \\  - DOMAIN,one.test,DIRECT
        \\    - DOMAIN,two.test,REJECT
    ));

    var source = std.ArrayList(u8).empty;
    defer source.deinit(allocator);
    try source.appendSlice(allocator, "root: ");
    for (0..140) |_| try source.appendSlice(allocator, "{x: ");
    try source.appendSlice(allocator, "value");
    for (0..140) |_| try source.append(allocator, '}');
    try source.append(allocator, '\n');
    try testing.expectError(error.YamlNestingTooDeep, yaml.parseDocument(allocator, source.items));
}

test "YAML legacy parsing enforces the nesting limit" {
    const allocator = testing.allocator;
    var source = std.ArrayList(u8).empty;
    defer source.deinit(allocator);
    for (0..140) |depth| {
        for (0..depth * 2) |_| try source.append(allocator, ' ');
        try source.appendSlice(allocator, "key:\n");
    }
    for (0..280) |_| try source.append(allocator, ' ');
    try source.appendSlice(allocator, "leaf: value\n");
    try testing.expectError(
        error.YamlNestingTooDeep,
        yaml.parse(allocator, source.items),
    );
}

test "YAML parse nested map" {
    const allocator = testing.allocator;

    const content =
        \\server:
        \\  host: localhost
        \\  port: 8080
    ;

    var doc = try yaml.parse(allocator, content);
    defer doc.deinit(allocator);

    const server = doc.map.get("server").?;
    try testing.expect(server == .map);
    try testing.expectEqualStrings("localhost", server.map.get("host").?.string);
}
