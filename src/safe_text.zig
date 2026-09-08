const std = @import("std");

pub const escape_expansion_factor_max: usize = 4;

pub fn isDisplaySafe(input_bytes: []const u8) bool {
    var view = std.unicode.Utf8View.init(input_bytes) catch return false;
    var iterator = view.iterator();
    for (0..input_bytes.len) |_| {
        const codepoint = iterator.nextCodepoint() orelse break;
        if (isTerminalControl(codepoint)) return false;
    }
    return true;
}

pub fn isDocumentDisplaySafe(input_bytes: []const u8) bool {
    var view = std.unicode.Utf8View.init(input_bytes) catch return false;
    var iterator = view.iterator();
    for (0..input_bytes.len) |_| {
        const codepoint = iterator.nextCodepoint() orelse break;
        if (codepoint == '\n') continue;
        if (isTerminalControl(codepoint)) return false;
    }
    return true;
}

pub fn escape(input_bytes: []const u8, output_bytes: []u8) []const u8 {
    const output_byte_count_min = std.math.mul(
        usize,
        input_bytes.len,
        escape_expansion_factor_max,
    ) catch @panic("safe text input is too large");
    std.debug.assert(output_bytes.len >= output_byte_count_min);
    var output_byte_count: usize = 0;
    var input_byte_index: usize = 0;
    for (0..input_bytes.len) |_| {
        if (input_byte_index == input_bytes.len) break;
        const byte = input_bytes[input_byte_index];
        if (byte < 0x80) {
            const escaped: []const u8 = switch (byte) {
                '\\' => "\\\\",
                '\n' => "\\n",
                '\r' => "\\r",
                '\t' => "\\t",
                0...8, 11, 12, 14...31, 127 => {
                    output_byte_count = appendByteEscape(
                        output_bytes,
                        output_byte_count,
                        byte,
                    );
                    input_byte_index += 1;
                    continue;
                },
                else => {
                    output_bytes[output_byte_count] = byte;
                    output_byte_count += 1;
                    input_byte_index += 1;
                    continue;
                },
            };
            @memcpy(
                output_bytes[output_byte_count..][0..escaped.len],
                escaped,
            );
            output_byte_count += escaped.len;
            input_byte_index += 1;
            continue;
        }

        const utf8_sequence_byte_count =
            std.unicode.utf8ByteSequenceLength(byte) catch {
                output_byte_count = appendByteEscape(
                    output_bytes,
                    output_byte_count,
                    byte,
                );
                input_byte_index += 1;
                continue;
            };
        if (input_byte_index + utf8_sequence_byte_count > input_bytes.len) {
            output_byte_count = appendByteEscape(
                output_bytes,
                output_byte_count,
                byte,
            );
            input_byte_index += 1;
            continue;
        }
        const utf8_sequence = input_bytes[input_byte_index..][0..utf8_sequence_byte_count];
        const codepoint = std.unicode.utf8Decode(utf8_sequence) catch {
            output_byte_count = appendByteEscape(
                output_bytes,
                output_byte_count,
                byte,
            );
            input_byte_index += 1;
            continue;
        };
        if (isTerminalControl(codepoint)) {
            const escaped = std.fmt.bufPrint(
                output_bytes[output_byte_count..],
                "\\u{{{x}}}",
                .{codepoint},
            ) catch unreachable;
            output_byte_count += escaped.len;
        } else {
            @memcpy(
                output_bytes[output_byte_count..][0..utf8_sequence.len],
                utf8_sequence,
            );
            output_byte_count += utf8_sequence.len;
        }
        input_byte_index += utf8_sequence_byte_count;
    }
    std.debug.assert(input_byte_index == input_bytes.len);
    return output_bytes[0..output_byte_count];
}

pub fn isTerminalControl(codepoint: u21) bool {
    if (codepoint <= 0x1f) return true;
    if (codepoint >= 0x7f) {
        if (codepoint <= 0x9f) return true;
    }
    if (codepoint == 0x061c) return true;
    if (codepoint == 0x200e) return true;
    if (codepoint == 0x200f) return true;
    if (codepoint >= 0x2028) {
        if (codepoint <= 0x202e) return true;
    }
    if (codepoint >= 0x2066) {
        if (codepoint <= 0x2069) return true;
    }
    return codepoint == 0xfeff;
}

fn appendByteEscape(
    output_bytes: []u8,
    output_byte_count: usize,
    byte: u8,
) usize {
    const hex = "0123456789abcdef";
    output_bytes[output_byte_count] = '\\';
    output_bytes[output_byte_count + 1] = 'x';
    output_bytes[output_byte_count + 2] = hex[byte >> 4];
    output_bytes[output_byte_count + 3] = hex[byte & 0x0f];
    return output_byte_count + 4;
}

test "safe display text rejects terminal formatting controls" {
    // Pass focused untrusted strings through the display seam and inspect the
    // rendered bytes.
    try std.testing.expect(isDisplaySafe("香港 edge"));
    try std.testing.expect(!isDisplaySafe("name\x1b[31m"));
    try std.testing.expect(!isDisplaySafe("name\xc2\x9b"));
    try std.testing.expect(!isDisplaySafe("safe\xe2\x80\xaespoof"));
}

test "safe document display permits lines but rejects terminal controls" {
    // Validate a multiline YAML-like document while allowing only line feeds
    // from the terminal-control range.
    try std.testing.expect(isDocumentDisplaySafe("a: 1\nb: 2\n"));
    try std.testing.expect(!isDocumentDisplaySafe("a: \x1b[31m\n"));
    try std.testing.expect(!isDocumentDisplaySafe("a: \xe2\x80\xae\n"));
    try std.testing.expect(!isDocumentDisplaySafe("a: \xff\n"));
}

test "safe text escaping keeps diagnostics on one visual line" {
    // Pass focused untrusted strings through the display seam and inspect the
    // rendered bytes.
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings(
        "name\\n\\x1b[31m bidi=\\u{202e}",
        escape("name\n\x1b[31m bidi=\xe2\x80\xae", &buffer),
    );
}
