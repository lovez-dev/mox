//! Native socket address layouts shared by backends, listeners and DNS.

const builtin = @import("builtin");
const Address = @import("../net/address.zig").Address;

pub const Native = Codec(builtin.os.tag);
pub const encode = Native.encode;
pub const decode = Native.decode;
pub const decodeSlice = Native.decodeSlice;
pub const family4 = Native.family4;
pub const family6 = Native.family6;

/// Select the ABI at compile time; this also permits testing each layout on one host.
pub fn Codec(comptime os: @TypeOf(builtin.os.tag)) type {
    return struct {
        const bsd = os == .macos or os == .freebsd;
        pub const family4: u16 = 2;
        pub const family6: u16 = switch (os) {
            .windows => 23,
            .linux => 10,
            .macos => 30,
            .freebsd => 28,
            else => @compileError("unsupported socket address ABI"),
        };

        pub fn encode(address: Address, storage: *[128]u8) u32 {
            @memset(storage, 0);
            const length: u8 = if (address.family == .ipv4) 16 else 28;
            const family: u16 = if (address.family == .ipv4) @This().family4 else @This().family6;
            if (bsd) {
                storage[0] = length;
                storage[1] = @intCast(family);
            } else {
                const native_family: *align(1) u16 = @ptrCast(storage);
                native_family.* = family;
            }
            // Ports are network order; scope identifiers are native order.
            storage[2] = @truncate(address.port >> 8);
            storage[3] = @truncate(address.port);
            if (address.family == .ipv4) {
                @memcpy(storage[4..8], address.bytes[0..4]);
            } else {
                @memcpy(storage[8..24], &address.bytes);
                const scope: *align(1) u32 = @ptrCast(&storage[24]);
                scope.* = address.scope;
            }
            return length;
        }

        /// Decode trusted kernel output in caller-owned sockaddr_storage.
        pub fn decode(storage: *const [128]u8) Address {
            return read(storage, readFamily(storage) == @This().family4);
        }

        /// Resolver records can contain other families or short address buffers.
        pub fn decodeSlice(storage: []const u8) ?Address {
            if (storage.len < 2) return null;
            const family = readFamily(storage);
            const ipv4 = family == @This().family4;
            if (!ipv4 and family != @This().family6) return null;
            if (storage.len < @as(usize, if (ipv4) 16 else 28)) return null;
            return read(storage, ipv4);
        }

        fn readFamily(storage: []const u8) u16 {
            if (bsd) return storage[1];
            const family: *align(1) const u16 = @ptrCast(storage.ptr);
            return family.*;
        }

        fn read(storage: []const u8, ipv4: bool) Address {
            var address: Address = .{ .family = if (ipv4) .ipv4 else .ipv6, .port = @as(u16, storage[2]) * 256 + storage[3] };
            if (ipv4) {
                @memcpy(address.bytes[0..4], storage[4..8]);
            } else {
                @memcpy(&address.bytes, storage[8..24]);
                const scope: *align(1) const u32 = @ptrCast(&storage[24]);
                address.scope = scope.*;
            }
            return address;
        }
    };
}
