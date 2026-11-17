//! Native path conversion and portable virtual path utilities.

const Error = @import("../error.zig").Error;
const utf8 = @import("../text/utf8.zig");
pub const virtual = @import("virtual_path.zig");

/// Validate UTF-8 and write a terminated UTF-16 path into caller-owned storage.
pub fn utf16(input: []const u8, output: []u16) Error![:0]u16 {
    var from: usize = 0;
    var to: usize = 0;
    while (from < input.len) {
        const scalar = utf8.decode(input[from..]) catch return error.InvalidOptions;
        var code = scalar.value;
        if (code == 0) return error.InvalidOptions;
        if (code < 0x10000) {
            if (to + 1 >= output.len) return error.Capacity;
            output[to] = @intCast(code);
            to += 1;
        } else {
            if (to + 2 >= output.len) return error.Capacity;
            code -= 0x10000;
            output[to] = @intCast(0xd800 | (code >> 10));
            output[to + 1] = @intCast(0xdc00 | (code & 1023));
            to += 2;
        }
        from += scalar.length;
    }
    if (to >= output.len) return error.Capacity;
    output[to] = 0;
    return output[0..to :0];
}
