//! Exercise exported memory helpers with independent byte patterns and guard regions.

const mox_io = @import("mox_io");
const testing = @import("std").testing;

const memory = mox_io.runtime.memory;
const lengths = [_]usize{ 0, 1, 2, 7, 15, 16, 17, 31, 32, 63, 64, 65, 127, 128, 129, 255, 256, 257, 4095, 4096, 4097 };

fn pattern(index: usize) u8 {
    return @truncate(index *% 37 +% 11);
}

fn initialize(buffer: []u8) void {
    for (buffer, 0..) |*byte, index| byte.* = pattern(index);
}

test "runtime memory helpers preserve boundaries, overlap and return pointers" {
    var source: [8192]u8 = undefined;
    var target: [8192]u8 = undefined;
    initialize(&source);
    for (lengths) |length| {
        for ([_]usize{ 0, 1, 7, 31 }) |offset| {
            _ = memory.memset(&target, 0xdd, target.len);
            try testing.expect(memory.memcpy(target[offset..].ptr, source[offset + 3 ..].ptr, length) == target[offset..].ptr);
            for (target, 0..) |byte, index| {
                const expected = if (index >= offset and index - offset < length) pattern(index + 3) else @as(u8, 0xdd);
                try testing.expect(byte == expected);
            }
            for ([_]c_int{ -1, 0, 0x1234, -256 }) |value| {
                initialize(&target);
                try testing.expect(memory.memset(target[offset..].ptr, value, length) == target[offset..].ptr);
                for (target, 0..) |byte, index| {
                    const expected = if (index >= offset and index - offset < length) @as(u8, @truncate(@as(u32, @bitCast(value)))) else pattern(index);
                    try testing.expect(byte == expected);
                }
            }
        }
        for ([_][2]usize{ .{ 64, 65 }, .{ 65, 64 }, .{ 64, 64 }, .{ 0, 4098 }, .{ 4098, 0 } }) |offsets| {
            initialize(&target);
            const input = offsets[0];
            const output = offsets[1];
            // Large non-overlapping cases still remain inside the guard array.
            if (@max(input, output) + length > target.len) continue;
            try testing.expect(memory.memmove(target[output..].ptr, target[input..].ptr, length) == target[output..].ptr);
            for (target, 0..) |byte, index| {
                const expected = if (index >= output and index - output < length) pattern(input + index - output) else pattern(index);
                try testing.expect(byte == expected);
            }
            // A backward move must restore the direction flag before a subsequent copy.
            _ = memory.memcpy(target[0..].ptr, source[0..].ptr, 32);
            try testing.expect(mox_io.mem.bytes.equal(target[0..32], source[0..32]));
        }
    }
    const unused: [*]u8 = @ptrFromInt(1);
    try testing.expect(memory.memcpy(unused, unused, 0) == unused);
    try testing.expect(memory.memmove(unused, unused, 0) == unused);
    try testing.expect(memory.memset(unused, 0, 0) == unused);
}
