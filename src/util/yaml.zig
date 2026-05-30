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

const Parser = struct {
    allocator: std.mem.Allocator,
    source: []const u8,
    pos: usize = 0,

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

    fn peekKey(self: *Parser) bool {
        const s = self.pos;
        defer self.pos = s;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ':') return true;
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r') break;
            self.pos += 1;
        }
        return false;
    }

    fn parseKey(self: *Parser) ![]const u8 {
        const s = self.pos;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == ':' or c == ' ' or c == '\t' or c == '\n') break;
            self.pos += 1;
        }
        return try self.allocator.dupe(u8, std.mem.trim(u8, self.source[s..self.pos], " \t"));
    }

    fn parseScalar(self: *Parser) !YamlValue {
        const s = self.pos;
        while (self.pos < self.source.len) {
            const c = self.source[self.pos];
            if (c == '\n' or c == '#') break;
            self.pos += 1;
        }

        var str = std.mem.trim(u8, self.source[s..self.pos], " \t");
        if (str.len == 0) return .null;

        // Remove matching quotes for quoted scalars
        if (str.len >= 2 and ((str[0] == '"' and str[str.len - 1] == '"') or
            (str[0] == '\'' and str[str.len - 1] == '\'')))
        {
            str = str[1 .. str.len - 1];
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
            if (self.source[self.pos] == '\n') {
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
            if (key.len == 0) {
                self.allocator.free(key);
                break;
            }

            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.pos += 1;

            if (self.pos >= self.source.len or self.source[self.pos] != ':') {
                self.allocator.free(key);
                break;
            }
            self.pos += 1;

            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.pos += 1;

            var val: YamlValue = .null;
            if (self.pos >= self.source.len or self.source[self.pos] == '\n' or self.source[self.pos] == '#') {
                if (self.pos < self.source.len) self.skipLine();

                if (self.pos < self.source.len) {
                    const next_line_start = self.pos;
                    const next_indent = self.getIndentAt(next_line_start);

                    if (next_indent > indent) {
                        val = try self.parseValue(next_indent);
                    }
                }
            } else {
                val = try self.parseScalar();
                self.skipLine();
            }
            const gop = try m.getOrPut(key);
            if (gop.found_existing) {
                // Duplicate key: free the newly-duped key and the previously
                // stored value before overwriting, to avoid leaking them.
                self.allocator.free(key);
                gop.value_ptr.deinit(self.allocator);
            }
            gop.value_ptr.* = val;
            first = false;
        }
        return YamlValue{ .map = m };
    }

    fn parseArray(self: *Parser, base: usize) anyerror!YamlValue {
        var arr = std.ArrayList(YamlValue).empty;

        while (self.pos < self.source.len) {
            const line_start = self.pos;
            const indent = self.getIndentAt(line_start);

            if (indent < base) {
                self.pos = line_start;
                break;
            }

            const content_pos = line_start + indent;
            if (content_pos >= self.source.len or self.source[content_pos] != '-') {
                self.pos = line_start;
                break;
            }

            self.pos = content_pos + 1;
            while (self.pos < self.source.len and
                (self.source[self.pos] == ' ' or self.source[self.pos] == '\t')) self.pos += 1;

            // Check for inline map format: {key: value, ...}
            if (self.pos < self.source.len and self.source[self.pos] == '{') {
                const item = try self.parseInlineMap();
                try arr.append(self.allocator, item);
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
                const item = try self.parseMap(base, true);
                try arr.append(self.allocator, item);
                // parseMap() already positions at the next unread line
                continue;
            }

            const item = try self.parseScalar();
            try arr.append(self.allocator, item);
            self.skipLine();
        }

        return YamlValue{ .array = arr };
    }

    fn parseInlineMap(self: *Parser) anyerror!YamlValue {
        var m = std.StringHashMap(YamlValue).init(self.allocator);

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
                break;
            }

            // Parse key
            const key_start = self.pos;
            while (self.pos < self.source.len and
                self.source[self.pos] != ':' and
                self.source[self.pos] != '}' and
                self.source[self.pos] != '\n')
            {
                self.pos += 1;
            }

            if (self.pos >= self.source.len or self.source[self.pos] != ':') {
                break; // malformed
            }

            var key = std.mem.trim(u8, self.source[key_start..self.pos], " \t");
            // Remove quotes if present
            if (key.len >= 2 and ((key[0] == '"' and key[key.len - 1] == '"') or
                (key[0] == '\'' and key[key.len - 1] == '\'')))
            {
                key = key[1 .. key.len - 1];
            }
            const key_copy = try self.allocator.dupe(u8, key);

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
            var in_single_quote = false;
            var in_double_quote = false;
            while (self.pos < self.source.len) {
                const c = self.source[self.pos];

                if (!in_double_quote and c == '\'') {
                    in_single_quote = !in_single_quote;
                    self.pos += 1;
                    continue;
                }
                if (!in_single_quote and c == '"') {
                    in_double_quote = !in_double_quote;
                    self.pos += 1;
                    continue;
                }

                if (!in_single_quote and !in_double_quote) {
                    if (c == '{') {
                        brace_depth += 1;
                    } else if (c == '}') {
                        if (brace_depth == 0) break;
                        brace_depth -= 1;
                    } else if (c == ',' and brace_depth == 0) {
                        break;
                    } else if (c == '\n') {
                        break;
                    }
                }

                self.pos += 1;
            }

            var val_str = std.mem.trim(u8, self.source[val_start..self.pos], " \t");
            // Remove quotes if present
            if (val_str.len >= 2 and ((val_str[0] == '"' and val_str[val_str.len - 1] == '"') or
                (val_str[0] == '\'' and val_str[val_str.len - 1] == '\'')))
            {
                val_str = val_str[1 .. val_str.len - 1];
            }

            const val = try self.parseInlineValue(val_str);
            try m.put(key_copy, val);

            // Skip comma if present
            if (self.pos < self.source.len and self.source[self.pos] == ',') {
                self.pos += 1;
            }
        }

        return YamlValue{ .map = m };
    }

    fn parseInlineValue(self: *Parser, str: []const u8) anyerror!YamlValue {
        if (str.len == 0) return .null;
        if (std.mem.eql(u8, str, "true")) return .{ .boolean = true };
        if (std.mem.eql(u8, str, "false")) return .{ .boolean = false };
        if (std.fmt.parseInt(i64, str, 10)) |n| {
            return .{ .integer = n };
        } else |_| {}

        // Check if it's a nested inline map (starts with {)
        const trimmed = std.mem.trim(u8, str, " \t");
        if (trimmed.len > 1 and trimmed[0] == '{') {
            // Recursively parse the nested inline map
            // We need to create a sub-parser or pass the substring
            // For simplicity, let's create a simple inline map parser for this case
            var m = std.StringHashMap(YamlValue).init(self.allocator);
            errdefer m.deinit();

            // Skip the opening brace
            var i: usize = 1;
            while (i < trimmed.len) {
                // Skip whitespace
                while (i < trimmed.len and (trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
                if (i >= trimmed.len or trimmed[i] == '}') break;

                // Parse key
                const key_start = i;
                while (i < trimmed.len and trimmed[i] != ':' and trimmed[i] != ' ' and trimmed[i] != '\t') i += 1;
                if (i >= trimmed.len) break;
                const key = std.mem.trim(u8, trimmed[key_start..i], " \t");

                // Skip colon and whitespace
                while (i < trimmed.len and (trimmed[i] == ':' or trimmed[i] == ' ' or trimmed[i] == '\t')) i += 1;
                if (i >= trimmed.len) break;

                // Parse value
                const val_start = i;
                var brace_depth: usize = 0;
                while (i < trimmed.len) {
                    const c = trimmed[i];
                    if (c == '{') {
                        brace_depth += 1;
                    } else if (c == '}') {
                        if (brace_depth == 0) break;
                        brace_depth -= 1;
                    } else if (c == ',' and brace_depth == 0) {
                        break;
                    }
                    i += 1;
                }
                var val_str = std.mem.trim(u8, trimmed[val_start..i], " \t");

                // Remove quotes if present
                if (val_str.len >= 2 and ((val_str[0] == '"' and val_str[val_str.len - 1] == '"') or
                    (val_str[0] == '\'' and val_str[val_str.len - 1] == '\'')))
                {
                    val_str = val_str[1 .. val_str.len - 1];
                }

                try m.put(try self.allocator.dupe(u8, key), try self.parseInlineValue(val_str));

                // Skip comma
                if (i < trimmed.len and trimmed[i] == ',') i += 1;
            }
            return YamlValue{ .map = m };
        }

        return .{ .string = try self.allocator.dupe(u8, str) };
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

            if (self.source[content_pos] == '-') return self.parseArray(base);

            self.pos = content_pos;
            if (self.peekKey()) return self.parseMap(base, false);
            return self.parseScalar();
        }
        return .null;
    }
};

pub fn parse(allocator: std.mem.Allocator, src: []const u8) !YamlValue {
    var p = Parser{ .allocator = allocator, .source = src };
    return try p.parseValue(0);
}
