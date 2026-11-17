//! Native socket address ABI checks independent of the host operating system.

const testing = @import("std").testing;
const mox_io = @import("mox_io");

const codec = mox_io.os.socket_address;
const Address = mox_io.net.Address;

test "socket address layouts preserve native family and network port" {
    inline for (.{ .linux, .windows, .macos, .freebsd }) |os| {
        const C = codec.Codec(os);
        var storage: [128]u8 = undefined;
        const length = C.encode(Address.ipv4(.{ 192, 0, 2, 1 }, 0xabcd), &storage);
        try testing.expectEqual(@as(u32, 16), length);
        if (os == .macos or os == .freebsd) {
            try testing.expectEqualSlices(u8, &.{ 16, 2 }, storage[0..2]);
        } else {
            try testing.expectEqualSlices(u8, &@as([2]u8, @bitCast(@as(u16, 2))), storage[0..2]);
        }
        try testing.expectEqualSlices(u8, &.{ 0xab, 0xcd, 192, 0, 2, 1 }, storage[2..8]);
        try testing.expectEqualDeep(Address.ipv4(.{ 192, 0, 2, 1 }, 0xabcd), C.decodeSlice(storage[0..16]).?);
        try testing.expect(C.decodeSlice(storage[0..15]) == null);
    }
}

test "socket address IPv6 scope and resolver record validation" {
    inline for (.{ .linux, .windows, .macos, .freebsd }) |os| {
        const C = codec.Codec(os);
        var storage: [128]u8 = undefined;
        const address = Address.ipv6(.{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 6, 7, 8 }, 443, 0x01020304);
        try testing.expectEqual(@as(u32, 28), C.encode(address, &storage));
        const expected_family: u16 = switch (os) {
            .linux => 10,
            .windows => 23,
            .macos => 30,
            .freebsd => 28,
            else => unreachable,
        };
        if (os == .macos or os == .freebsd) {
            try testing.expectEqualSlices(u8, &.{ 28, @intCast(expected_family) }, storage[0..2]);
        } else {
            try testing.expectEqualSlices(u8, &@as([2]u8, @bitCast(expected_family)), storage[0..2]);
        }
        try testing.expectEqualSlices(u8, &.{ 1, 0xbb }, storage[2..4]);
        try testing.expectEqualSlices(u8, &@as([4]u8, @bitCast(@as(u32, 0x01020304))), storage[24..28]);
        try testing.expectEqualDeep(address, C.decode(&storage));
        try testing.expectEqualDeep(address, C.decodeSlice(storage[0..28]).?);
        try testing.expect(C.decodeSlice(storage[0..27]) == null);
        storage[0] = 0;
        storage[1] = 0;
        try testing.expect(C.decodeSlice(&storage) == null);
        try testing.expect(C.decodeSlice(storage[0..1]) == null);
    }
}
