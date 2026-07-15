const std = @import("std");

pub const YamlValue = union(enum) {
    null,
    boolean: bool,
    integer: i64,
    string: []const u8,
    array: std.ArrayList(YamlValue),
    map: std.StringHashMap(YamlValue),

    pub fn deinit(self: *YamlValue, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .string => |s| allocator.free(s),
            .array => |*arr| {
                for (arr.items) |*item| item.deinit(allocator);
                arr.deinit(allocator);
            },
            .map => |*m| {
                var it = m.iterator();
                while (it.next()) |e| {
                    allocator.free(e.key_ptr.*);
                    e.value_ptr.deinit(allocator);
                }
                m.deinit();
            },
            else => {},
        }
    }
};

fn deinitMapEntries(allocator: std.mem.Allocator, map: *std.StringHashMap(YamlValue)) void {
    var it = map.iterator();
    while (it.next()) |entry| {
        allocator.free(entry.key_ptr.*);
        entry.value_ptr.deinit(allocator);
    }
    map.deinit();
}

fn decodeStrictQuoted(allocator: std.mem.Allocator, quoted: []const u8) ![]u8 {
    if (quoted.len < 2 or quoted[0] != quoted[quoted.len - 1] or
        (quoted[0] != '"' and quoted[0] != '\''))
    {
        return error.InvalidYamlDocument;
    }
    const quote = quoted[0];
    const content = quoted[1 .. quoted.len - 1];
    var decoded = std.ArrayList(u8).empty;
    errdefer decoded.deinit(allocator);

    var index: usize = 0;
    while (index < content.len) {
        const byte = content[index];
        if (quote == '\'') {
            if (byte == '\'') {
                if (index + 1 >= content.len or content[index + 1] != '\'') {
                    return error.InvalidYamlDocument;
                }
                try decoded.append(allocator, '\'');
                index += 2;
                continue;
            }
            try decoded.append(allocator, byte);
            index += 1;
            continue;
        }

        if (byte != '\\') {
            try decoded.append(allocator, byte);
            index += 1;
            continue;
        }
        if (index + 1 >= content.len) return error.InvalidYamlDocument;
        index += 1;
        const escape = content[index];
        index += 1;
        switch (escape) {
            '0' => try decoded.append(allocator, 0),
            'a' => try decoded.append(allocator, 0x07),
            'b' => try decoded.append(allocator, 0x08),
            't' => try decoded.append(allocator, '\t'),
            'n' => try decoded.append(allocator, '\n'),
            'v' => try decoded.append(allocator, 0x0b),
            'f' => try decoded.append(allocator, 0x0c),
            'r' => try decoded.append(allocator, '\r'),
            'e' => try decoded.append(allocator, 0x1b),
            ' ', '"', '/', '\\' => try decoded.append(allocator, escape),
            'N' => try appendCodepoint(allocator, &decoded, 0x85),
            '_' => try appendCodepoint(allocator, &decoded, 0xa0),
            'L' => try appendCodepoint(allocator, &decoded, 0x2028),
            'P' => try appendCodepoint(allocator, &decoded, 0x2029),
            'x' => {
                const codepoint = try parseHexCodepoint(content, &index, 2);
                try appendCodepoint(allocator, &decoded, codepoint);
            },
            'u' => {
                var codepoint = try parseHexCodepoint(content, &index, 4);
                if (codepoint >= 0xd800 and codepoint <= 0xdbff) {
                    if (index + 2 > content.len or content[index] != '\\' or content[index + 1] != 'u') {
                        return error.InvalidYamlDocument;
                    }
                    index += 2;
                    const low = try parseHexCodepoint(content, &index, 4);
                    if (low < 0xdc00 or low > 0xdfff) return error.InvalidYamlDocument;
                    codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (low - 0xdc00);
                } else if (codepoint >= 0xdc00 and codepoint <= 0xdfff) {
                    return error.InvalidYamlDocument;
                }
                try appendCodepoint(allocator, &decoded, codepoint);
            },
            'U' => {
                const codepoint = try parseHexCodepoint(content, &index, 8);
                try appendCodepoint(allocator, &decoded, codepoint);
            },
            else => return error.InvalidYamlDocument,
        }
    }
    return decoded.toOwnedSlice(allocator);
}

fn parseHexCodepoint(content: []const u8, index: *usize, digits: usize) !u32 {
    if (index.* + digits > content.len) return error.InvalidYamlDocument;
    const value = std.fmt.parseInt(u32, content[index.* .. index.* + digits], 16) catch
        return error.InvalidYamlDocument;
    index.* += digits;
    return value;
}

fn appendCodepoint(
    allocator: std.mem.Allocator,
    output: *std.ArrayList(u8),
    codepoint: u32,
) !void {
    if (codepoint > std.math.maxInt(u21)) return error.InvalidYamlDocument;
    var buffer: [4]u8 = undefined;
    const length = std.unicode.utf8Encode(@intCast(codepoint), &buffer) catch
        return error.InvalidYamlDocument;
    try output.appendSlice(allocator, buffer[0..length]);
}

fn consumeFlowQuote(source: []const u8, index: *usize, quote: *?u8) !bool {
    const byte = source[index.*];
    if (quote.*) |active| {
        if (active == '"' and byte == '\\') {
            if (index.* + 1 >= source.len) return error.InvalidYamlDocument;
            index.* += 2;
            return true;
        }
        if (active == '\'' and byte == '\'' and index.* + 1 < source.len and
            source[index.* + 1] == '\'')
        {
            index.* += 2;
            return true;
        }
        if (byte == active) quote.* = null;
        index.* += 1;
        return true;
    }
    if (byte == '"' or byte == '\'') {
        quote.* = byte;
        index.* += 1;
        return true;
    }
    return false;
}

fn isFlowMappingIndicator(source: []const u8, position: usize) bool {
    if (source[position] != ':') return false;
    const next = position + 1;
    return next >= source.len or source[next] == ' ' or source[next] == '\t' or
        source[next] == '\r' or source[next] == '\n';
}

const max_nesting_depth: usize = 128;

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize = 0,
    strict: bool = false,
    depth: usize = 0,

    fn getIndentAt(self: *Parser, at: usize) usize {
        var i = at;
        var c: usize = 0;
        while (i < self.source.len) {
            if (self.source[i] == ' ') {
                c += 1;
                i += 1;
            } else if (self.source[i] == '\t') {
                c += 4;
                i += 1;
            } else break;
        }
        return c;
    }

    fn skipLine(self: *Parser) void {
        while (self.pos < self.source.len and self.source[self.pos] != '\n') self.pos += 1;
        if (self.pos < self.source.len) self.pos += 1;
    }

    fn skipTriviaLines(self: *Parser) void {
        while (self.pos < self.source.len) {
            const line_start = self.pos;
            const indent = self.getIndentAt(line_start);
            const content_pos = line_start + indent;
            if (content_pos >= self.source.len) return;
            const blank = self.source[content_pos] == '\n' or
                (self.source[content_pos] == '\r' and content_pos + 1 < self.source.len and
                    self.source[content_pos + 1] == '\n');
            if (!blank and self.source[content_pos] != '#') return;
            self.pos = line_start;
            self.skipLine();
        }
    }

    fn peekKey(self: *Parser) bool {
        const saved = self.pos;
        defer self.pos = saved;
        if (!self.strict) {
            while (self.pos < self.source.len) {
                const c = self.source[self.pos];
                if (c == ':') return true;
                if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
                self.pos += 1;
            }
            return false;
        }

        var quote: ?u8 = null;
        while (self.pos < self.source.len) : (self.pos += 1) {
            const c = self.source[self.pos];
            if (c == '\n' or c == '\r' or (c == '#' and quote == null)) return false;
            if (quote) |active| {
                if (c == active) quote = null;
                continue;
            }
            if ((c == '"' or c == '\'') and self.pos == saved) {
                quote = c;
            } else if (c == ':' and self.isBlockMappingColon(self.pos)) {
                return true;
            }
        }
        return false;
    }

    fn parseKey(self: *Parser) ![]const u8 {
        const start = self.pos;
        if (!self.strict) {
            while (self.pos < self.source.len) {
                const c = self.source[self.pos];
                if (c == ':' or c == ' ' or c == '\t' or c == '\n') break;
                self.pos += 1;
            }
            return self.allocator.dupe(u8, std.mem.trim(u8, self.source[start..self.pos], " \t"));
        }

        var quote: ?u8 = null;
        while (self.pos < self.source.len) : (self.pos += 1) {
            const c = self.source[self.pos];
            if (c == '\n' or c == '\r' or (c == '#' and quote == null)) {
                return error.InvalidYamlDocument;
            }
            if (quote) |active| {
                if (c == active) quote = null;
                continue;
            }
            if ((c == '"' or c == '\'') and self.pos == start) {
                quote = c;
            } else if (c == ':' and self.isBlockMappingColon(self.pos)) {
                break;
            }
        }
        if (quote != null or self.pos >= self.source.len or self.source[self.pos] != ':') {
            return error.InvalidYamlDocument;
        }
        const key = std.mem.trim(u8, self.source[start..self.pos], " \t");
        if (key.len >= 2 and ((key[0] == '"' and key[key.len - 1] == '"') or
            (key[0] == '\'' and key[key.len - 1] == '\'')))
        {
            return decodeStrictQuoted(self.allocator, key);
        }
        if (key.len != 0 and (key[0] == '"' or key[0] == '\'')) {
            return error.InvalidYamlDocument;
        }
        return self.allocator.dupe(u8, key);
    }

    fn isBlockMappingColon(self: *const Parser, position: usize) bool {
        const next = position + 1;
        return next >= self.source.len or self.source[next] == ' ' or
            self.source[next] == '\t' or self.source[next] == '\r' or
            self.source[next] == '\n';
    }

    fn parseScalar(self: *Parser) !YamlValue {
        const start = self.pos;

        if (self.strict and self.pos < self.source.len and
            (self.source[self.pos] == '"' or self.source[self.pos] == '\''))
        {
            const quote = self.source[self.pos];
            self.pos += 1;
            var value_end: ?usize = null;
            while (self.pos < self.source.len and self.source[self.pos] != '\n') {
                if (quote == '"' and self.source[self.pos] == '\\' and self.pos + 1 < self.source.len) {
                    self.pos += 2;
                    continue;
                }
                if (self.source[self.pos] == quote) {
                    if (quote == '\'' and self.pos + 1 < self.source.len and self.source[self.pos + 1] == '\'') {
                        self.pos += 2;
                        continue;
                    }
                    value_end = self.pos;
                    self.pos += 1;
                    break;
                }
                self.pos += 1;
            }
            const end = value_end orelse return error.InvalidYamlDocument;
            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t' or self.source[self.pos] == '\r'))
            {
                self.pos += 1;
            }
            if (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '#') {
                return error.InvalidYamlDocument;
            }
            return .{ .string = try decodeStrictQuoted(self.allocator, self.source[start .. end + 1]) };
        }

        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n') break;
            if (c == '#') {
                if (!self.strict or self.pos == start or
                    self.source[self.pos - 1] == ' ' or self.source[self.pos - 1] == '\t')
                {
                    break;
                }
            }
            self.pos += 1;
        }

        var str = std.mem.trim(u8, self.source[start..self.pos], if (self.strict) " \t\r" else " \t");
        if (str.len == 0) return .null;

        const quoted = str.len >= 2 and ((str[0] == '"' and str[str.len - 1] == '"') or
            (str[0] == '\'' and str[str.len - 1] == '\''));
        if (quoted) str = str[1 .. str.len - 1];

        if (self.strict and (str[0] == '{' or str[0] == '[')) return error.InvalidYamlDocument;
        if (self.strict and (std.mem.eql(u8, str, "null") or
            std.mem.eql(u8, str, "Null") or
            std.mem.eql(u8, str, "NULL") or
            std.mem.eql(u8, str, "~")))
        {
            return .null;
        }
        if (std.mem.eql(u8, str, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, str, "false")) return .{ .boolean = false };
        if (std.fmt.parseInt(i64, str, 10)) |n| {
            return .{ .integer = n };
        } else |_| {}
        return .{ .string = try self.allocator.dupe(u8, str) };
    }

    fn parseMap(self: *Parser, base: usize, allow_deeper_keys: bool) anyerror!YamlValue {
        var m = std.StringHashMap(YamlValue).init(self.allocator);
        errdefer deinitMapEntries(self.allocator, &m);
        var first = true;

        while (self.pos < self.source.len) {
            // Find line start
            var line_start = self.pos;
            while (line_start > 0 and self.source[line_start - 1] != '\n') {
                line_start -= 1;
            }

            const indent = self.getIndentAt(line_start);

            if (first) {
                if (indent != base) {
                    self.pos = line_start;
                    break;
                }
            } else {
                if (indent < base) {
                    self.pos = line_start;
                    break;
                }
                if (!allow_deeper_keys and indent > base) {
                    self.pos = line_start;
                    break;
                }
                const content_pos = line_start + indent;
                if (content_pos < self.source.len and self.source[content_pos] == '-') {
                    self.pos = line_start;
                    break;
                }
            }

            self.pos = line_start + indent;
            if (self.pos >= self.source.len) break;
            if (self.strict) {
                const line_end = std.mem.indexOfScalarPos(u8, self.source, self.pos, '\n') orelse self.source.len;
                const line = std.mem.trim(u8, self.source[self.pos..line_end], " \t\r");
                if (std.mem.eql(u8, line, "...")) {
                    self.pos = line_start;
                    break;
                }
            }
            if (self.source[self.pos] == '\n' or
                (self.strict and self.source[self.pos] == '\r' and self.pos + 1 < self.source.len and
                    self.source[self.pos + 1] == '\n'))
            {
                self.pos = line_start;
                self.skipLine();
                continue;
            }
            if (self.source[self.pos] == '#') {
                self.pos = line_start;
                self.skipLine();
                continue;
            }

            // Skip dash if present (array item marker)
            if (self.source[self.pos] == '-') {
                self.pos += 1;
                while (self.pos < self.source.len and
                    (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.pos += 1;
            }

            const key = try self.parseKey();
            var key_owned = true;
            errdefer if (key_owned) self.allocator.free(key);
            if (key.len == 0) {
                self.allocator.free(key);
                key_owned = false;
                if (self.strict) return error.InvalidYamlDocument;
                break;
            }

            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.pos += 1;

            if (self.pos >= self.source.len or self.source[self.pos] != ':') {
                self.allocator.free(key);
                key_owned = false;
                if (self.strict) return error.InvalidYamlDocument;
                break;
            }
            self.pos += 1;

            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.pos += 1;

            var val: YamlValue = .null;
            var val_owned = true;
            errdefer if (val_owned) val.deinit(self.allocator);
            if (self.pos >= self.source.len or self.source[self.pos] == '\n' or
                self.source[self.pos] == '#' or
                (self.strict and self.source[self.pos] == '\r' and self.pos + 1 < self.source.len and
                    self.source[self.pos + 1] == '\n'))
            {
                if (self.pos < self.source.len) self.skipLine();
                if (self.strict) self.skipTriviaLines();

                if (self.pos < self.source.len) {
                    const next_line_start = self.pos;
                    const next_indent = self.getIndentAt(next_line_start);

                    if (next_indent > indent) {
                        if (self.strict and self.depth >= max_nesting_depth) {
                            return error.YamlNestingTooDeep;
                        }
                        if (self.strict) self.depth += 1;
                        defer if (self.strict) {
                            self.depth -= 1;
                        };
                        val = try self.parseValue(next_indent);
                    }
                }
            } else if (self.strict and
                (self.source[self.pos] == '{' or self.source[self.pos] == '['))
            {
                val = if (self.source[self.pos] == '{')
                    try self.parseInlineMap()
                else
                    try self.parseInlineSequence();
                try self.requireOnlyLineTail();
                self.skipLine();
            } else {
                val = try self.parseScalar();
                self.skipLine();
            }
            const gop = try m.getOrPut(key);
            if (gop.found_existing) {
                if (self.strict) return error.DuplicateKey;
                self.allocator.free(key);
                key_owned = false;
                gop.value_ptr.deinit(self.allocator);
            } else {
                key_owned = false;
            }
            gop.value_ptr.* = val;
            val_owned = false;
            first = false;
        }
        return YamlValue{ .map = m };
    }

    fn parseArray(self: *Parser, base: usize) anyerror!YamlValue {
        var arr = std.ArrayList(YamlValue).empty;
        errdefer {
            for (arr.items) |*item| item.deinit(self.allocator);
            arr.deinit(self.allocator);
        }

        while (self.pos < self.source.len) {
            const line_start = self.pos;
            const indent = self.getIndentAt(line_start);
            const content_pos = line_start + indent;
            if (content_pos >= self.source.len) break;
            if (self.strict and (self.source[content_pos] == '\n' or
                (self.source[content_pos] == '\r' and content_pos + 1 < self.source.len and
                    self.source[content_pos + 1] == '\n') or
                self.source[content_pos] == '#'))
            {
                self.pos = line_start;
                self.skipLine();
                continue;
            }

            if (indent < base) {
                self.pos = line_start;
                break;
            }
            if (self.strict and indent > base) return error.InvalidYamlDocument;

            if (self.source[content_pos] != '-') {
                self.pos = line_start;
                break;
            }

            self.pos = content_pos + 1;
            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.pos += 1;

            // Check for an inline collection.
            if (self.pos < self.source.len and
                (self.source[self.pos] == '{' or (self.strict and self.source[self.pos] == '[')))
            {
                if (self.strict and self.depth >= max_nesting_depth) {
                    return error.YamlNestingTooDeep;
                }
                if (self.strict) self.depth += 1;
                defer if (self.strict) {
                    self.depth -= 1;
                };
                var item = if (self.source[self.pos] == '{')
                    try self.parseInlineMap()
                else
                    try self.parseInlineSequence();
                arr.append(self.allocator, item) catch |err| {
                    item.deinit(self.allocator);
                    return err;
                };
                if (self.strict) try self.requireOnlyLineTail();
                self.skipLine();
                continue;
            }

            // Check if this is a map item or scalar.
            // Important: ':' inside quoted strings (e.g. "Traffic: 49GB")
            // must NOT be treated as key/value separator.
            const is_map = blk: {
                const saved = self.pos;
                defer self.pos = saved;

                var in_single = false;
                var in_double = false;

                while (self.pos < self.source.len) {
                    const ch = self.source[self.pos];

                    if (ch == '\n' or ch == '\r') break;

                    if (ch == '\'' and !in_double) {
                        in_single = !in_single;
                        self.pos += 1;
                        continue;
                    }
                    if (ch == '"' and !in_single) {
                        in_double = !in_double;
                        self.pos += 1;
                        continue;
                    }

                    if (!in_single and !in_double and ch == ':') {
                        const next = self.pos + 1;
                        if (next >= self.source.len or
                            self.source[next] == ' ' or
                            self.source[next] == '\t' or
                            self.source[next] == '\n' or
                            self.source[next] == '\r')
                        {
                            break :blk true;
                        }
                    }

                    self.pos += 1;
                }

                break :blk false;
            };

            if (is_map) {
                if (self.strict and self.depth >= max_nesting_depth) {
                    return error.YamlNestingTooDeep;
                }
                if (self.strict) self.depth += 1;
                defer if (self.strict) {
                    self.depth -= 1;
                };
                var item = try self.parseMap(base, true);
                arr.append(self.allocator, item) catch |err| {
                    item.deinit(self.allocator);
                    return err;
                };
                // parseMap() already positions at the next unread line
                continue;
            }

            var item = try self.parseScalar();
            arr.append(self.allocator, item) catch |err| {
                item.deinit(self.allocator);
                return err;
            };
            self.skipLine();
        }

        return YamlValue{ .array = arr };
    }

    fn parseInlineSequence(self: *Parser) anyerror!YamlValue {
        if (self.pos >= self.source.len or self.source[self.pos] != '[') {
            return error.InvalidYamlDocument;
        }
        self.pos += 1;
        var values = std.ArrayList(YamlValue).empty;
        errdefer {
            for (values.items) |*value| value.deinit(self.allocator);
            values.deinit(self.allocator);
        }
        var closed = false;

        while (self.pos < self.source.len) {
            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t'))
            {
                self.pos += 1;
            }
            if (self.pos < self.source.len and self.source[self.pos] == ']') {
                self.pos += 1;
                closed = true;
                break;
            }

            const value_start = self.pos;
            var quote: ?u8 = null;
            var brace_depth: usize = 0;
            var bracket_depth: usize = 0;
            while (self.pos < self.source.len) {
                const c = self.source[self.pos];
                if (try consumeFlowQuote(self.source, &self.pos, &quote)) continue;
                if (c == '{') {
                    brace_depth += 1;
                } else if (c == '}') {
                    if (brace_depth == 0) return error.InvalidYamlDocument;
                    brace_depth -= 1;
                } else if (c == '[') {
                    bracket_depth += 1;
                } else if (c == ']') {
                    if (bracket_depth == 0 and brace_depth == 0) break;
                    if (bracket_depth == 0) return error.InvalidYamlDocument;
                    bracket_depth -= 1;
                } else if (c == ',' and brace_depth == 0 and bracket_depth == 0) {
                    break;
                } else if (brace_depth == 0 and bracket_depth == 0 and
                    isFlowMappingIndicator(self.source, self.pos))
                {
                    return error.InvalidYamlDocument;
                } else if (c == '\n' or c == '\r') {
                    return error.InvalidYamlDocument;
                }
                self.pos += 1;
            }
            if (quote != null or brace_depth != 0 or bracket_depth != 0) {
                return error.InvalidYamlDocument;
            }
            const text = std.mem.trim(u8, self.source[value_start..self.pos], " \t");
            if (text.len == 0) return error.InvalidYamlDocument;
            var value = try self.parseInlineValue(text);
            values.append(self.allocator, value) catch |err| {
                value.deinit(self.allocator);
                return err;
            };

            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t'))
            {
                self.pos += 1;
            }
            if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
            } else if (self.pos >= self.source.len or self.source[self.pos] != ']') {
                return error.InvalidYamlDocument;
            }
        }
        if (!closed) return error.InvalidYamlDocument;
        return .{ .array = values };
    }

    fn parseInlineMap(self: *Parser) anyerror!YamlValue {
        var m = std.StringHashMap(YamlValue).init(self.allocator);
        errdefer deinitMapEntries(self.allocator, &m);
        var closed = false;

        // Expect '{' at current position
        if (self.pos >= self.source.len or self.source[self.pos] != '{') {
            return YamlValue{ .map = m };
        }
        self.pos += 1; // skip '{'

        while (self.pos < self.source.len) {
            // Skip whitespace
            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t'))
            {
                self.pos += 1;
            }

            // Check for end of map
            if (self.pos < self.source.len and self.source[self.pos] == '}') {
                self.pos += 1;
                closed = true;
                break;
            }

            // Parse a key through a colon outside quotes.
            const key_start = self.pos;
            var key_quote: ?u8 = null;
            while (self.pos < self.source.len) {
                const byte = self.source[self.pos];
                if (try consumeFlowQuote(self.source, &self.pos, &key_quote)) continue;
                if (byte == ':') break;
                if (byte == '}' or byte == '\n' or byte == '\r') {
                    if (self.strict) return error.InvalidYamlDocument;
                    break;
                }
                self.pos += 1;
            }

            if (key_quote != null or self.pos >= self.source.len or self.source[self.pos] != ':') {
                if (self.strict) return error.InvalidYamlDocument;
                break;
            }

            var key = std.mem.trim(u8, self.source[key_start..self.pos], " \t");
            const key_quoted = key.len >= 2 and
                ((key[0] == '"' and key[key.len - 1] == '"') or
                    (key[0] == '\'' and key[key.len - 1] == '\''));
            const key_copy = if (self.strict and key_quoted)
                try decodeStrictQuoted(self.allocator, key)
            else blk: {
                if (key_quoted) key = key[1 .. key.len - 1];
                break :blk try self.allocator.dupe(u8, key);
            };
            var key_owned = true;
            errdefer if (key_owned) self.allocator.free(key_copy);

            self.pos += 1; // skip ':'

            // Skip whitespace after colon
            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t'))
            {
                self.pos += 1;
            }

            // Parse value
            const val_start = self.pos;
            var brace_depth: usize = 0;
            var bracket_depth: usize = 0;
            var value_quote: ?u8 = null;
            while (self.pos < self.source.len) {
                const c = self.source[self.pos];
                if (try consumeFlowQuote(self.source, &self.pos, &value_quote)) continue;
                if (c == '{') {
                    brace_depth += 1;
                } else if (c == '}') {
                    if (brace_depth == 0 and bracket_depth == 0) break;
                    if (brace_depth == 0) return error.InvalidYamlDocument;
                    brace_depth -= 1;
                } else if (c == '[') {
                    bracket_depth += 1;
                } else if (c == ']') {
                    if (bracket_depth == 0) return error.InvalidYamlDocument;
                    bracket_depth -= 1;
                } else if (c == ',' and brace_depth == 0 and bracket_depth == 0) {
                    break;
                } else if (brace_depth == 0 and bracket_depth == 0 and
                    isFlowMappingIndicator(self.source, self.pos))
                {
                    return error.InvalidYamlDocument;
                } else if (c == '\n' or c == '\r') {
                    break;
                }
                self.pos += 1;
            }
            if (self.strict and (value_quote != null or brace_depth != 0 or bracket_depth != 0)) {
                return error.InvalidYamlDocument;
            }

            var val_str = std.mem.trim(u8, self.source[val_start..self.pos], " \t");
            // Keep quotes for strict scalar typing; legacy parsing retains its
            // historical coercion of quoted booleans and integers.
            if (!self.strict and val_str.len >= 2 and
                ((val_str[0] == '"' and val_str[val_str.len - 1] == '"') or
                    (val_str[0] == '\'' and val_str[val_str.len - 1] == '\'')))
            {
                val_str = val_str[1 .. val_str.len - 1];
            }

            var val = try self.parseInlineValue(val_str);
            const gop = m.getOrPut(key_copy) catch |err| {
                val.deinit(self.allocator);
                return err;
            };
            if (gop.found_existing) {
                if (self.strict) {
                    self.allocator.free(key_copy);
                    key_owned = false;
                    val.deinit(self.allocator);
                    return error.DuplicateKey;
                }
                self.allocator.free(key_copy);
                key_owned = false;
                gop.value_ptr.deinit(self.allocator);
            } else {
                key_owned = false;
            }
            gop.value_ptr.* = val;

            if (self.strict) {
                while (self.pos < self.source.len and
                    (self.source[self.pos] == ' ' or self.source[self.pos] == '\t'))
                {
                    self.pos += 1;
                }
                if (self.pos < self.source.len and self.source[self.pos] == ',') {
                    self.pos += 1;
                } else if (self.pos >= self.source.len or self.source[self.pos] != '}') {
                    return error.InvalidYamlDocument;
                }
            } else if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
            }
        }

        if (self.strict and !closed) return error.InvalidYamlDocument;
        return YamlValue{ .map = m };
    }

    fn parseInlineValue(self: *Parser, str: []const u8) anyerror!YamlValue {
        const scalar = std.mem.trim(u8, str, " \t");
        if (scalar.len == 0) return .null;
        const quoted = scalar.len >= 2 and
            ((scalar[0] == '"' and scalar[scalar.len - 1] == '"') or
                (scalar[0] == '\'' and scalar[scalar.len - 1] == '\''));
        if (self.strict and (scalar[0] == '"' or scalar[0] == '\'') and !quoted) {
            return error.InvalidYamlDocument;
        }
        if (self.strict and quoted) {
            return .{ .string = try decodeStrictQuoted(self.allocator, scalar) };
        }
        if (self.strict and (std.mem.eql(u8, scalar, "null") or
            std.mem.eql(u8, scalar, "Null") or
            std.mem.eql(u8, scalar, "NULL") or
            std.mem.eql(u8, scalar, "~")))
        {
            return .null;
        }
        if (std.mem.eql(u8, scalar, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, scalar, "false")) return .{ .boolean = false };
        if (std.fmt.parseInt(i64, scalar, 10)) |n| {
            return .{ .integer = n };
        } else |_| {}

        const trimmed = scalar;
        if (trimmed.len > 1 and trimmed[0] == '[') {
            if (self.strict and self.depth >= max_nesting_depth) {
                return error.YamlNestingTooDeep;
            }
            var nested = Parser{
                .allocator = self.allocator,
                .source = trimmed,
                .strict = self.strict,
                .depth = if (self.strict) self.depth + 1 else self.depth,
            };
            var value = try nested.parseInlineSequence();
            errdefer value.deinit(self.allocator);
            if (self.strict and nested.pos != trimmed.len) return error.InvalidYamlDocument;
            return value;
        }

        // Check if it's a nested inline map (starts with {)
        if (trimmed.len > 1 and trimmed[0] == '{') {
            if (self.strict and self.depth >= max_nesting_depth) {
                return error.YamlNestingTooDeep;
            }
            if (self.strict) self.depth += 1;
            defer if (self.strict) {
                self.depth -= 1;
            };
            if (self.strict and trimmed[trimmed.len - 1] != '}') {
                return error.InvalidYamlDocument;
            }
            // Recursively parse the nested inline map.
            var m = std.StringHashMap(YamlValue).init(self.allocator);
            errdefer deinitMapEntries(self.allocator, &m);

            // Skip the opening brace
            var i: usize = 1;
            while (i < trimmed.len) {
                // Skip whitespace
                while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
                if (i >= trimmed.len or trimmed[i] == '}') break;

                // Parse a key through the required colon.
                const key_start = i;
                var key_quote: ?u8 = null;
                while (i < trimmed.len) {
                    const c = trimmed[i];
                    if (try consumeFlowQuote(trimmed, &i, &key_quote)) continue;
                    if (c == ':') break;
                    if (c == ',' or c == '}' or c == '\n' or c == '\r') {
                        if (self.strict) return error.InvalidYamlDocument;
                        break;
                    }
                    i += 1;
                }
                if (key_quote != null or i >= trimmed.len or trimmed[i] != ':') {
                    if (self.strict) return error.InvalidYamlDocument;
                    break;
                }
                var key = std.mem.trim(u8, trimmed[key_start..i], " \t");
                const key_quoted = key.len >= 2 and
                    ((key[0] == '"' and key[key.len - 1] == '"') or
                        (key[0] == '\'' and key[key.len - 1] == '\''));
                if (!key_quoted and key.len == 0) return error.InvalidYamlDocument;

                i += 1;
                while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;

                // Parse a value without treating quoted commas/braces as syntax.
                const val_start = i;
                var brace_depth: usize = 0;
                var bracket_depth: usize = 0;
                var value_quote: ?u8 = null;
                while (i < trimmed.len) {
                    const c = trimmed[i];
                    if (try consumeFlowQuote(trimmed, &i, &value_quote)) continue;
                    if (c == '{') {
                        brace_depth += 1;
                    } else if (c == '}') {
                        if (brace_depth == 0 and bracket_depth == 0) break;
                        if (brace_depth == 0) return error.InvalidYamlDocument;
                        brace_depth -= 1;
                    } else if (c == '[') {
                        bracket_depth += 1;
                    } else if (c == ']') {
                        if (bracket_depth == 0) return error.InvalidYamlDocument;
                        bracket_depth -= 1;
                    } else if (c == ',' and brace_depth == 0 and bracket_depth == 0) {
                        break;
                    } else if (brace_depth == 0 and bracket_depth == 0 and
                        isFlowMappingIndicator(trimmed, i))
                    {
                        return error.InvalidYamlDocument;
                    }
                    i += 1;
                }
                if (self.strict and (value_quote != null or brace_depth != 0 or bracket_depth != 0)) {
                    return error.InvalidYamlDocument;
                }
                var val_str = std.mem.trim(u8, trimmed[val_start..i], " \t");

                if (!self.strict and val_str.len >= 2 and
                    ((val_str[0] == '"' and val_str[val_str.len - 1] == '"') or
                        (val_str[0] == '\'' and val_str[val_str.len - 1] == '\'')))
                {
                    val_str = val_str[1 .. val_str.len - 1];
                }

                const key_copy = if (self.strict and key_quoted)
                    try decodeStrictQuoted(self.allocator, key)
                else blk: {
                    if (key_quoted) key = key[1 .. key.len - 1];
                    break :blk try self.allocator.dupe(u8, key);
                };
                var key_owned = true;
                errdefer if (key_owned) self.allocator.free(key_copy);
                var value = try self.parseInlineValue(val_str);
                const gop = m.getOrPut(key_copy) catch |err| {
                    value.deinit(self.allocator);
                    return err;
                };
                if (gop.found_existing) {
                    if (self.strict) {
                        value.deinit(self.allocator);
                        return error.DuplicateKey;
                    }
                    self.allocator.free(key_copy);
                    key_owned = false;
                    gop.value_ptr.deinit(self.allocator);
                } else {
                    key_owned = false;
                }
                gop.value_ptr.* = value;

                if (self.strict) {
                    while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
                    if (i < trimmed.len and trimmed[i] == ',') {
                        i += 1;
                    } else if (i >= trimmed.len or trimmed[i] != '}') {
                        return error.InvalidYamlDocument;
                    }
                } else if (i < trimmed.len and trimmed[i] == ',') {
                    i += 1;
                }
            }
            return YamlValue{ .map = m };
        }

        return .{ .string = try self.allocator.dupe(u8, scalar) };
    }

    fn parseValue(self: *Parser, base: usize) anyerror!YamlValue {
        while (self.pos < self.source.len) {
            const line_start = self.pos;
            const indent = self.getIndentAt(line_start);
            const content_pos = line_start + indent;

            if (content_pos >= self.source.len) return .null;
            if (self.source[content_pos] == '\n') {
                self.pos = content_pos + 1;
                continue;
            }
            if (self.source[content_pos] == '\r' and
                content_pos + 1 < self.source.len and self.source[content_pos + 1] == '\n')
            {
                self.pos = content_pos + 2;
                continue;
            }
            if (self.source[content_pos] == '#') {
                self.pos = content_pos;
                self.skipLine();
                continue;
            }

            if (indent < base) {
                self.pos = line_start;
                return .null;
            }

            self.pos = line_start;

            if (self.strict and
                (self.source[content_pos] == '{' or self.source[content_pos] == '['))
            {
                self.pos = content_pos;
                var value = if (self.source[content_pos] == '{')
                    try self.parseInlineMap()
                else
                    try self.parseInlineSequence();
                errdefer value.deinit(self.allocator);
                try self.requireOnlyLineTail();
                self.skipLine();
                return value;
            }
            if (self.source[content_pos] == '-') return self.parseArray(base);

            self.pos = content_pos;
            if (self.peekKey()) return self.parseMap(base, false);
            return self.parseScalar();
        }
        return .null;
    }

    fn requireOnlyLineTail(self: *Parser) !void {
        while (self.pos < self.source.len and
            (self.source[self.pos] == ' ' or self.source[self.pos] == '\t' or self.source[self.pos] == '\r'))
        {
            self.pos += 1;
        }
        if (self.pos < self.source.len and self.source[self.pos] != '\n' and self.source[self.pos] != '#') {
            return error.InvalidYamlDocument;
        }
    }

    fn requireOnlyTrailingTrivia(self: *Parser) !void {
        var document_ended = false;
        while (self.pos < self.source.len) {
            const line_end = std.mem.indexOfScalarPos(u8, self.source, self.pos, '\n') orelse self.source.len;
            const line = std.mem.trim(u8, self.source[self.pos..line_end], " \t\r");
            if (std.mem.eql(u8, line, "...") and !document_ended) {
                document_ended = true;
            } else if (line.len != 0 and line[0] != '#') {
                return error.InvalidYamlDocument;
            }
            self.pos = if (line_end < self.source.len) line_end + 1 else line_end;
        }
    }
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !YamlValue {
    var p = Parser{ .allocator = allocator, .source = src };
    return try p.parseValue(0);
}

/// Parses the subset of YAML understood by zc as one complete document.
/// Unlike `parse`, this entry point rejects duplicate keys and ignored tails.
pub fn parseDocument(allocator: std.mem.Allocator, src: []const u8) !YamlValue {
    const without_bom = if (std.mem.startsWith(u8, src, "\xEF\xBB\xBF")) src[3..] else src;
    const content = stripDocumentStart(without_bom);
    var p = Parser{ .allocator = allocator, .source = content, .strict = true };
    var value = try p.parseValue(0);
    errdefer value.deinit(allocator);
    try p.requireOnlyTrailingTrivia();
    return value;
}

fn stripDocumentStart(source: []const u8) []const u8 {
    var position: usize = 0;
    while (position < source.len) {
        const line_end = std.mem.indexOfScalarPos(u8, source, position, '\n') orelse source.len;
        const line = std.mem.trim(u8, source[position..line_end], " \t\r");
        if (std.mem.eql(u8, line, "---")) {
            return if (line_end < source.len) source[line_end + 1 ..] else source[source.len..];
        }
        if (line.len != 0 and line[0] != '#') return source;
        position = if (line_end < source.len) line_end + 1 else line_end;
    }
    return source;
}
