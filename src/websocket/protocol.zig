//! RFC 6455 wire validation, independent of sockets and connection lifetime.

const std = @import("std");
const types = @import("../types.zig");
pub const max_message = 1024 * 1024;
pub const max_queue = 4 * 1024 * 1024;
pub const Error = error{ ProtocolError, MessageTooLarge, InvalidUtf8 };
pub const Frame = struct {
    opcode: types.WsOpcode,
    final: bool,
    payload: []u8,
    consumed: usize,
    mask: [4]u8,
};

/// Validates lengths before waiting for payload. Does not mutate partial input.
pub fn parse(input: []u8) Error!?Frame {
    return parseWithLimit(input, max_message);
}

pub fn parseWithLimit(input: []u8, limit: usize) Error!?Frame {
    if (input.len < 2) return null;
    const first = input[0];
    const opcode: types.WsOpcode = @fromBackingInt(first & 0xf);
    const final = first & 0x80 != 0;
    if (first & 0x70 != 0 or input[1] & 0x80 == 0) return error.ProtocolError;
    switch (opcode) {
        .continuation, .text, .binary, .close, .ping, .pong => {},
        else => return error.ProtocolError,
    }
    const control = first & 8 != 0;
    var length: u64 = input[1] & 0x7f;
    if (control and (!final or length > 125)) return error.ProtocolError;
    var header_len: usize = 2;
    if (length == 126) {
        if (input.len < 4) return null;
        length = std.mem.readInt(u16, input[2..4], .big);
        if (length < 126) return error.ProtocolError;
        header_len = 4;
    } else if (length == 127) {
        if (input.len < 10) return null;
        length = std.mem.readInt(u64, input[2..10], .big);
        if (length < 65536 or length >> 63 != 0) return error.ProtocolError;
        header_len = 10;
    }
    if (length > limit or length > std.math.maxInt(usize) - 14) return error.MessageTooLarge;
    const size: usize = @intCast(length);
    if (input.len < header_len + 4 or input.len - header_len - 4 < size) return null;
    return .{ .opcode = opcode, .final = final, .payload = input[header_len + 4 ..][0..size], .consumed = header_len + 4 + size, .mask = input[header_len..][0..4].* };
}

/// Reject invalid prefixes immediately while retaining incomplete code points across fragments.
pub const Utf8 = struct {
    remaining: u3 = 0,
    low: u8 = 0x80,
    high: u8 = 0xbf,

    pub fn feed(self: *Utf8, bytes: []const u8) bool {
        for (bytes) |byte| {
            if (self.remaining != 0) {
                if (byte < self.low or byte > self.high) return false;
                self.remaining -= 1;
                self.low = 0x80;
                self.high = 0xbf;
            } else switch (byte) {
                0...0x7f => {},
                0xc2...0xdf => self.remaining = 1,
                0xe0 => {
                    self.remaining = 2;
                    self.low = 0xa0;
                },
                0xe1...0xec, 0xee...0xef => self.remaining = 2,
                0xed => {
                    self.remaining = 2;
                    self.high = 0x9f;
                },
                0xf0 => {
                    self.remaining = 3;
                    self.low = 0x90;
                },
                0xf1...0xf3 => self.remaining = 3,
                0xf4 => {
                    self.remaining = 3;
                    self.high = 0x8f;
                },
                else => return false,
            }
        }
        return true;
    }
};

pub fn unmask(frame: Frame) void {
    for (frame.payload, 0..) |*byte, i| byte.* ^= frame.mask[i % 4];
}

pub fn validCloseCode(code: u16) bool {
    return switch (code) {
        1000...1003, 1007...1014, 3000...4999 => true,
        else => false,
    };
}

pub fn validateClose(payload: []const u8) Error!void {
    if (payload.len == 1 or payload.len > 125) return error.ProtocolError;
    if (payload.len >= 2) {
        if (!validCloseCode(std.mem.readInt(u16, payload[0..2], .big))) return error.ProtocolError;
        if (!std.unicode.utf8ValidateSlice(payload[2..])) return error.InvalidUtf8;
    }
}

pub fn header(out: *[10]u8, opcode: types.WsOpcode, length: usize) []const u8 {
    out[0] = 0x80 | @backingInt(opcode);
    if (length < 126) {
        out[1] = @intCast(length);
        return out[0..2];
    }
    if (length < 65536) {
        out[1] = 126;
        std.mem.writeInt(u16, out[2..4], @intCast(length), .big);
        return out[0..4];
    }
    out[1] = 127;
    std.mem.writeInt(u64, out[2..10], length, .big);
    return out;
}

test "frame validation rejects masking RSV opcode and noncanonical lengths early" {
    const cases = [_][]const u8{
        &.{ 0x81, 0x00 },       &.{ 0xc1, 0x80 },                               &.{ 0x83, 0x80 },
        &.{ 0x09, 0x80 },       &.{ 0x89, 0xfe },                               &.{ 0x88, 0xff },
        &.{ 0x81, 0xfe, 0, 1 }, &.{ 0x82, 0xff, 0, 0, 0, 0, 0, 0, 0xff, 0xff }, &.{ 0x82, 0xff, 0x80, 0, 0, 0, 0, 1, 0, 0 },
    };
    var buffer: [64]u8 = undefined;
    for (cases) |wire| {
        @memcpy(buffer[0..wire.len], wire);
        try std.testing.expectError(error.ProtocolError, parse(buffer[0..wire.len]));
    }
    const huge = [_]u8{ 0x82, 0xff, 0, 0, 0, 0, 0, 0x10, 0, 1 };
    @memcpy(buffer[0..huge.len], &huge);
    try std.testing.expectError(error.MessageTooLarge, parse(buffer[0..huge.len]));
}

test "masked frame remains unchanged until complete and unmask preserves trailing frame" {
    var wire = [_]u8{ 0x81, 0x82, 1, 2, 3, 4, 'h' ^ 1, 'i' ^ 2, 0x88, 0x80, 1, 2, 3, 4 };
    const before = wire;
    for (0..8) |n| try std.testing.expect((try parse(wire[0..n])) == null);
    try std.testing.expectEqualSlices(u8, &before, &wire);
    const frame = (try parse(&wire)).?;
    try std.testing.expectEqual(@as(usize, 8), frame.consumed);
    unmask(frame);
    try std.testing.expectEqualStrings("hi", frame.payload);
    try std.testing.expectEqualSlices(u8, before[8..], wire[8..]);
}

test "close status and reason validation" {
    try validateClose("");
    try validateClose(&.{ 0x03, 0xe8 });
    try validateClose(&.{ 0x0b, 0xb8 });
    for ([_]u16{ 0, 999, 1004, 1005, 1006, 1015, 2000, 2999, 5000 }) |code| {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, code, .big);
        try std.testing.expectError(error.ProtocolError, validateClose(&bytes));
    }
    try std.testing.expectError(error.ProtocolError, validateClose("a"));
    try std.testing.expectError(error.InvalidUtf8, validateClose(&.{ 0x03, 0xe8, 0xff }));
}
