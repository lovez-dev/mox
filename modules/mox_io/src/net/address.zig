//! Portable IPv4 and IPv6 endpoint values and address constructors.

pub const Address = struct {
    family: Family = .ipv4,
    port: u16 = 0,
    bytes: [16]u8 = @splat(0),
    scope: u32 = 0,

    pub const Family = enum { ipv4, ipv6 };

    pub fn ipv4(bytes: [4]u8, port: u16) Address {
        var result: Address = .{ .port = port };
        @memcpy(result.bytes[0..4], &bytes);
        return result;
    }

    pub fn loopback(port: u16) Address {
        return ipv4(.{ 127, 0, 0, 1 }, port);
    }

    pub fn ipv6(bytes: [16]u8, port: u16, scope: u32) Address {
        return .{ .family = .ipv6, .port = port, .bytes = bytes, .scope = scope };
    }
};
